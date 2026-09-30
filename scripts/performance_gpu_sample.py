"""Bounded coarse GPU capability probe; measurement decoding is not validated yet.

This adapter deliberately reports unavailable GPU values until real powermetrics
output establishes counter units, process attribution, and lifecycle coverage.
It never falls back to a detailed Metal recording or prompts for credentials.
"""

import ctypes
import json
import math
import os
from pathlib import Path
import subprocess
import time


PROVIDER = "powermetrics per-process GPU sampling (not yet validated)"
SCHEMA_REASON = "No observed powermetrics schema, GPU units, attribution, and calibration have been validated"


def _clock_pair():
    """Pair Mach time with Python's monotonic clock without assuming an epoch."""
    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    library.mach_absolute_time.restype = ctypes.c_uint64
    info = Timebase()
    if library.mach_timebase_info(ctypes.byref(info)) != 0 or not info.denom:
        raise ValueError("Mach clock timebase is unavailable")
    before = time.monotonic()
    ticks = library.mach_absolute_time()
    after = time.monotonic()
    return {"absolute_minus_monotonic_seconds": ticks * info.numer / info.denom / 1e9 - (before + after) / 2,
            "uncertainty_seconds": (after - before) / 2}


def _finite(value, name):
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(f"Invalid {name}")
    return value


class PowermetricsSession:
    """TraceSession-compatible unavailable provider with auditable preflight.

    Only a single self-limiting sample is requested. A successful probe does not
    establish measurement capability: no decoder or Metal calibration is
    installed until actual output has been reviewed and tested.
    """

    def __init__(self, output, deadline):
        self.output = Path(output) / "gpu-sampling"
        self.output.mkdir(parents=True, exist_ok=False)
        self.deadline = _finite(deadline, "performance deadline")
        self.invalid = []
        self.processes = {}
        self.windows = {}
        self.exits = {}
        self.clock_start = None
        self.start_result = None
        self.result = None
        self.process = None
        self.raw = self.output / "probe.plist"
        self.stderr = self.output / "probe.stderr"

    def _remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Performance deadline expired before coarse GPU capability probe")
        return remaining

    def _cleanup_probe(self):
        if self.process is None or self.process.poll() is not None:
            return
        # Signal only the subprocess we launched. Never kill a PID found by name.
        try:
            self.process.terminate()
            self.process.wait(timeout=max(.001, min(.2, self.deadline - time.monotonic())))
        except subprocess.TimeoutExpired:
            try:
                self.process.kill()
                self.process.wait(timeout=max(.001, min(.2, self.deadline - time.monotonic())))
            except (OSError, subprocess.TimeoutExpired) as error:
                self.invalid.append(f"Coarse GPU probe cleanup was not confirmed: {type(error).__name__}")
        except OSError as error:
            self.invalid.append(f"Coarse GPU probe cleanup was not confirmed: {type(error).__name__}")

    def _probe(self):
        timeout = min(3.0, self._remaining())
        command = ["/usr/bin/powermetrics", "--samplers", "tasks", "--show-process-gpu",
                   "--show-process-samp-norm", "--format", "plist", "--sample-rate", "250",
                   "--sample-count", "1", "--buffer-size", "0"]
        authorization = "already-root" if os.geteuid() == 0 else "sudo-n"
        if authorization == "sudo-n":
            command = ["/usr/bin/sudo", "-n", *command]
        metadata = {"command": command, "authorization": authorization, "sample_count": 1,
                    "sample_interval_ms": 250, "timeout_seconds": timeout,
                    "start_monotonic_seconds": time.monotonic(),
                    "exit_code": None, "timed_out": False, "raw_bytes": 0}
        try:
            with self.raw.open("wb") as out, self.stderr.open("wb") as err:
                self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                                                start_new_session=True)
                try:
                    metadata["exit_code"] = self.process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    metadata["timed_out"] = True
        finally:
            self._cleanup_probe()
            metadata["end_monotonic_seconds"] = time.monotonic()
            metadata["raw_bytes"] = self.raw.stat().st_size if self.raw.exists() else 0
            (self.output / "probe.json").write_text(json.dumps(metadata, indent=2) + "\n")
        return metadata

    def start(self):
        if self.start_result is not None:
            return self.start_result
        evidence = {}
        try:
            self._remaining()
            self.clock_start = _clock_pair()
            if self.clock_start["uncertainty_seconds"] > .001:
                self.invalid.append("Coarse GPU clock bridge uncertainty exceeds 1 ms")
            evidence = self._probe()
            if evidence.get("timed_out"):
                self.invalid.append("Bounded powermetrics capability probe timed out")
            elif evidence.get("exit_code") != 0:
                self.invalid.append("Powermetrics probe failed or noninteractive authorization is unavailable; see probe.stderr. "
                                    "A separately authorized secure macOS probe is needed; no prompt was opened")
            elif not evidence.get("raw_bytes"):
                self.invalid.append("Powermetrics probe produced no raw samples")
        except (OSError, ValueError, subprocess.SubprocessError, TimeoutError) as error:
            self.invalid.append(f"Coarse GPU capability probe: {error}")
        self.invalid.append(SCHEMA_REASON)
        self.start_result = {"provider": PROVIDER, "available": False, "implementation_status": "capability_probe_only",
                             "unavailable_code": "powermetrics_not_validated", "invalid": list(self.invalid),
                             "probe": evidence, "clock_start": self.clock_start,
                             "secure_prompt_opened": False,
                             "artifacts": {"raw_probe": str(self.raw), "probe_stderr": str(self.stderr)}}
        (self.output / "start.json").write_text(json.dumps(self.start_result, indent=2) + "\n")
        return self.start_result

    def calibrate(self, collector):
        # Running a known load without a validated decoder cannot calibrate it.
        return {"valid": False, "pending_trace_export": False, "performed": False,
                "invalid": [SCHEMA_REASON], "references": []}

    def monotonic_from_mach_seconds(self, value):
        _finite(value, "collector Mach timestamp")
        if self.clock_start is None:
            raise ValueError("Coarse GPU clock bridge is unavailable")
        return value - self.clock_start["absolute_minus_monotonic_seconds"]

    def register_process(self, pid, birth_time_us, baseline_monotonic):
        if type(pid) is not int or pid <= 0 or type(birth_time_us) is not int or birth_time_us <= 0:
            raise ValueError("GPU process registration requires PID and birth identity")
        _finite(baseline_monotonic, "process baseline timestamp")
        prior = self.processes.get(pid)
        if prior is not None and prior["birth_time_us"] != birth_time_us:
            raise ValueError("GPU process PID was reused")
        self.processes[pid] = {"birth_time_us": birth_time_us, "baseline_monotonic_seconds": baseline_monotonic}

    def add_window(self, name, pid, birth_time_us, start, end):
        _finite(start, "GPU window start")
        _finite(end, "GPU window end")
        if not isinstance(name, str) or not name or name in self.windows or start >= end:
            raise ValueError("Invalid or duplicate GPU window")
        if self.processes.get(pid, {}).get("birth_time_us") != birth_time_us:
            raise ValueError("GPU window process identity is not registered")
        if start < self.processes[pid]["baseline_monotonic_seconds"]:
            raise ValueError("GPU window begins before the registered process")
        self.windows[name] = {"process_id": pid, "birth_time_us": birth_time_us,
                              "start_monotonic_seconds": start, "end_monotonic_seconds": end}

    def register_exit(self, pid, birth_time_us, final_sample_time, trace_drain_end, status):
        _finite(final_sample_time, "final process timestamp")
        _finite(trace_drain_end, "process drain timestamp")
        if self.processes.get(pid, {}).get("birth_time_us") != birth_time_us:
            raise ValueError("GPU exit process identity is not registered")
        if trace_drain_end < final_sample_time:
            raise ValueError("GPU exit drain precedes final sample")
        if final_sample_time < self.processes[pid]["baseline_monotonic_seconds"]:
            raise ValueError("GPU exit precedes process baseline")
        self.exits[pid] = {"birth_time_us": birth_time_us, "final_sample_monotonic_seconds": final_sample_time,
                           "trace_drain_end_monotonic_seconds": trace_drain_end, "status": status}

    def finish(self):
        if self.result is not None:
            return self.result
        self._cleanup_probe()
        if self.start_result is None:
            self.invalid.append("Coarse GPU capability probe was not started")
        if SCHEMA_REASON not in self.invalid:
            self.invalid.append(SCHEMA_REASON)
        windows = {}
        terminal = {}
        for name, window in self.windows.items():
            row = dict(window, coverage_complete=False, invalid=list(self.invalid), attribution_exact=False,
                       gpu_execution_seconds=None, gpu_percent=None, gpu_rolling_1s_percent=None)
            for metric in ("gpu_execution_seconds", "gpu_percent", "gpu_rolling_1s_percent"):
                row[metric + "_lower_bound"] = None
                row[metric + "_upper_bound"] = None
            windows[name] = row
            terminal[name] = {"complete": False, "reason": "Terminated-process GPU accounting has not been validated",
                              "invalid": ["No calibrated GPU accounting covers process exit or outstanding work"],
                              "exit": self.exits.get(window["process_id"])}
        self.result = {"provider": PROVIDER, "valid": False, "invalid": list(self.invalid),
                       "implementation_status": "capability_probe_only", "recording_complete": False,
                       "calibration": self.calibrate(None), "windows": windows, "final_exit_coverage": terminal,
                       "lost_events": None, "process_identities": [], "tables": {},
                       "artifacts": {"raw_probe": str(self.raw), "probe_stderr": str(self.stderr),
                                     "probe_metadata": str(self.output / "probe.json")}}
        (self.output / "gpu-report.json").write_text(json.dumps(self.result, indent=2, allow_nan=False) + "\n")
        return self.result
