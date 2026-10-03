"""One bounded Instruments trace for reproducible GPU workload measurements.

GPU values come from process-attributed execution intervals, never device-wide
utilization or an absent self counter. Raw XML remains an audit artifact.
"""

from bisect import bisect_right
from collections import defaultdict
from contextlib import contextmanager
import ctypes
import json
import math
import os
import platform
from pathlib import Path
import queue
import re
import signal
import sqlite3
import subprocess
import threading
import time
import uuid
import xml.etree.ElementTree as ET
import zlib

from performance_trace_xml import read_table


PROVIDER = "Instruments GPU instrument process execution intervals"
GPU_SCHEMA = "metal-gpu-intervals"
GPU_COLUMNS = ("start", "duration", "state", "process", "gpu", "channel-name",
               "gpu-submission-id", "cmdbuffer-id", "encoder-id")
CORE_SCHEMAS = (GPU_SCHEMA, "metal-gpu-execution-points", "time-info", "process-info",
                "metal-gpu-submission-to-command-buffer-id")
TERMINAL_SCHEMAS = ("metal-command-buffer-completed", "metal-command-buffer-frame-assignment")


class TraceError(ValueError):
    pass


def read_run_issues(trace):
    """Read Instruments' completed-run diagnostic store without modifying it.

    In the installed Instruments version, type0/type1 are errors/warnings and
    type2 is informational. The trace's issue accumulator persists kernel loss
    and analysis stream-drop warnings here, including loss of whole event pairs.
    Unknown schemas or issue kinds are not interpreted as a clean recording.
    """
    path = Path(trace) / "Trace1.run" / "RunIssues.storedata"
    result = {"available": False, "lost_events": None, "issues": [], "invalid": [], "path": str(path),
              "method": "Completed Instruments run issue accumulator; kernel loss and stream-horizon warnings",
              "schema_stability": "Private Instruments schema validated against this installed version; unknown forms fail closed"}
    required = {"ZCOUNT", "ZRELATIVETIMESTAMP", "ZSUBTYPE", "ZTYPE", "ZMESSAGE", "ZPARENT"}
    try:
        with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=.1) as database:
            columns = {row[1] for row in database.execute('PRAGMA table_info("ZISSUE")')}
            result["issue_columns"] = sorted(columns)
            if not required.issubset(columns):
                raise TraceError("Instruments run-issue schema is unavailable or changed")
            if database.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise TraceError("Instruments run-issue store is incomplete or corrupt")
            rows = database.execute("SELECT ZCOUNT,ZRELATIVETIMESTAMP,ZSUBTYPE,ZTYPE,ZMESSAGE,ZPARENT FROM ZISSUE").fetchall()
        lost = False
        for count, timestamp, subtype, kind, message, parent in rows:
            issue = {"count": count, "trace_timestamp_ns": timestamp, "subtype": subtype,
                     "type": kind, "message": message, "parent": parent}
            result["issues"].append(issue)
            if kind not in (0, 1, 2) or not isinstance(message, str) or type(count) is not int or count < 0:
                result["invalid"].append("Unrecognized Instruments run issue")
            elif kind in (0, 1):
                result["invalid"].append(f"Instruments recording issue: {message}")
            if isinstance(message, str) and re.search(r"lost|dropped|overflow", message, re.I):
                lost = True
                if kind == 2:
                    result["invalid"].append(f"Instruments loss diagnostic: {message}")
        result["available"] = True
        result["lost_events"] = lost if not any("Unrecognized" in item for item in result["invalid"]) else None
    except (OSError, sqlite3.Error, TraceError) as error:
        result["invalid"].append(str(error))
    return result


def _integer(text):
    if not isinstance(text, str) or not re.fullmatch(r"[0-9]+", text.strip()):
        raise TraceError(f"Expected a nonnegative raw integer, got {text!r}")
    return int(text)


def _check_deadline(deadline):
    if deadline is not None and time.monotonic() >= deadline:
        raise TimeoutError("Performance deadline expired during GPU trace parsing/evaluation")


def export_schema_index(trace, toc, output):
    """Index schemas from this actual trace when joined XML omits later headers.

    This is an explicitly version-checked private archive format, not an Apple
    public API. Column counts are checked again while reading exported rows.
    """
    schemas = {}
    for file in (Path(trace) / "corespace/run1/core/stores").glob("*/schema.xml"):
        data = file.read_bytes()
        try:
            node = ET.fromstring(zlib.decompress(data))
        except (ET.ParseError, zlib.error):
            try:
                node = ET.fromstring(data)
            except ET.ParseError:
                continue
        name = node.get("name")
        columns = {column.get("mnemonic"): column.get("engineeringType") for column in node.findall("column")}
        if name and columns and None not in columns:
            if name in schemas and schemas[name] != columns:
                raise TraceError(f"Trace has conflicting {name} archive schemas")
            schemas[name] = columns
    tree = ET.parse(toc).getroot()
    tables = {str(index): table.get("schema") for index, table in enumerate(tree.findall("./run/data/table"), 1)}
    metadata = {"schemas": schemas, "tables": tables,
                "method": "TOC table order and the completed trace's embedded column schemas"}
    Path(str(output) + ".schema.json").write_text(json.dumps(metadata, indent=2) + "\n")
    return metadata


def parse_gpu_intervals(table, *, deadline=None):
    result = {"intervals": [], "invalid": list(table.get("invalid", [])),
              "duplicates": 0, "unattributed": []}
    missing = set(GPU_COLUMNS) - set(table.get("columns", {}))
    if missing:
        result["invalid"].append(f"GPU interval columns missing: {', '.join(sorted(missing))}")
        return result
    seen = set()
    for index, row in enumerate(table["rows"]):
        if index % 4096 == 0:
            _check_deadline(deadline)
        try:
            state = row["state"]["text"]
            if state == "Idle":
                continue
            if state != "Active":
                raise TraceError(f"Unknown GPU interval state {state!r}")
            start = _integer(row["start"]["text"])
            duration = _integer(row["duration"]["text"])
            if duration <= 0:
                raise TraceError("GPU execution interval has no positive duration")
            pid = row["process"].get("pid")
            value = {"start_ns": start, "end_ns": start + duration, "pid": pid,
                     "gpu": row["gpu"]["text"], "channel": row["channel-name"]["text"],
                     "submission_id": _integer(row["gpu-submission-id"]["text"]),
                     "command_buffer_id": _integer(row["cmdbuffer-id"]["text"]),
                     "encoder_id": _integer(row["encoder-id"]["text"])}
            if not value["gpu"] or not value["channel"]:
                raise TraceError("GPU interval has no device/channel identity")
            key = tuple(value.values())
            if key in seen:
                result["duplicates"] += 1
                continue
            seen.add(key)
            if type(pid) is not int or pid <= 0:
                result["unattributed"].append(value)
                continue
            result["intervals"].append(value)
        except (TraceError, KeyError, TypeError) as error:
            result["invalid"].append(str(error))
    return result


def _union(intervals):
    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return sum(end - start for start, end in merged)


def _rolling_peak(intervals, start, end):
    """Exact continuous maximum, not values at a periodic sampling grid."""
    second = 1_000_000_000
    if end - start < second:
        return None
    events = defaultdict(int)
    for left, right in intervals:
        events[left] += 1
        events[right] -= 1
    times = sorted(events)
    integral = []
    rates = []
    total = rate = 0
    previous = start
    for timestamp in times:
        total += (timestamp - previous) * rate
        integral.append(total)
        rate += events[timestamp]
        rates.append(rate)
        previous = timestamp

    def area(timestamp):
        index = bisect_right(times, timestamp) - 1
        return 0 if index < 0 else integral[index] + rates[index] * (timestamp - times[index])

    candidates = {start + second, end}
    for timestamp in times:
        candidates.add(timestamp)
        candidates.add(timestamp + second)
    maximum = max(area(t) - area(t - second) for t in candidates if start + second <= t <= end)
    return maximum / second * 100


def interval_metrics(intervals, pid, start_ns, end_ns):
    if type(pid) is not int or pid <= 0 or end_ns <= start_ns:
        raise TraceError("Invalid GPU process/window")
    clipped = []
    by_gpu = defaultdict(list)
    for interval in intervals:
        if interval["pid"] != pid:
            continue
        left, right = max(start_ns, interval["start_ns"]), min(end_ns, interval["end_ns"])
        if right > left:
            clipped.append((left, right))
            by_gpu[interval["gpu"]].append((left, right))
    execution = sum(right - left for left, right in clipped)
    busy = sum(_union(values) for values in by_gpu.values())
    duration = end_ns - start_ns
    return {"gpu_execution_seconds": execution / 1e9, "gpu_percent": execution / duration * 100,
            "gpu_busy_union_seconds": busy / 1e9, "gpu_busy_union_percent": busy / duration * 100,
            "gpu_rolling_1s_percent": _rolling_peak(clipped, start_ns, end_ns),
            "interval_count": len(clipped)}


def bounded_interval_metrics(intervals, unresolved, pid, start_ns, end_ns):
    """Conservative process bounds when recorded execution has unknown ownership.

    Every unresolved interval is assigned to the measured process in the upper
    bound. Concurrent execution remains additive; a union would understate it.
    Missing execution events are not bounded by this function and must invalidate
    capture coverage separately.
    """
    lower = interval_metrics(intervals, pid, start_ns, end_ns)
    unknown = [item for item in unresolved if item["start_ns"] < end_ns and item["end_ns"] > start_ns
               and (item.get("candidate_pids") is None or pid in item["candidate_pids"])]
    upper = interval_metrics([*intervals, *({**item, "pid": pid} for item in unknown)], pid, start_ns, end_ns)
    exact = not unknown
    result = {**lower, "attribution_exact": exact, "unattributed_interval_count": len(unknown),
              "attribution_method": "Exact process attribution" if exact else
              "Conservative bounds: every unresolved execution with unknown or compatible candidate ownership is assigned to this process in the upper bound"}
    for field in ("gpu_execution_seconds", "gpu_percent", "gpu_rolling_1s_percent",
                  "gpu_busy_union_seconds", "gpu_busy_union_percent"):
        result[field + "_lower_bound"] = lower[field]
        result[field + "_upper_bound"] = upper[field]
        result[field] = lower[field] if exact else None
    return result


def reconcile_submission_ownership(parsed, rows, *, deadline=None):
    """Bound raw SID aliases instead of trusting Instruments' modeled owner join.

    IOGPU exports SID and SID+1 alternatives for each command. Another process can
    own the same raw SID; the modeled command/encoder is itself a join result and
    cannot disambiguate it. Keep each physical execution once, with all candidate
    owners, regardless of which modeled owner Instruments happened to select.
    """
    owners = defaultdict(set)
    composite = defaultdict(set)
    submitted = defaultdict(set)
    submitted_identities = defaultdict(set)
    commands = defaultdict(set)
    identities = defaultdict(set)
    invalid = []
    for index, row in enumerate(rows):
        if index % 4096 == 0:
            _check_deadline(deadline)
        try:
            pid = _integer(row["pid"]["text"])
            if row.get("process", {}).get("pid") not in (None, pid):
                raise TraceError("GPU submission PID conflicts with its process identity")
            sid = _integer(row["gpu-submission-id"]["text"])
            command = _integer(row["cmdbuffer-id"]["text"])
            encoder = _integer(row["encoder-id"]["text"])
            owners[sid].add(pid)
            composite[(sid, command, encoder)].add(pid)
            identities[sid].add((pid, command, encoder))
            submitted[pid].add(sid)
            submitted_identities[pid].add((pid, sid, command, encoder))
            commands[pid].add(command)
        except (TraceError, KeyError) as error:
            invalid.append(f"GPU submission identity: {error}")
    physical = defaultdict(list)
    conflicts = []
    for index, item in enumerate([*parsed["intervals"], *parsed.get("unattributed", [])]):
        if index % 4096 == 0:
            _check_deadline(deadline)
        exact = composite[(item["submission_id"], item["command_buffer_id"], item["encoder_id"])]
        raw_owners = owners[item["submission_id"]]
        if item["pid"] and item["pid"] > 0:
            if ((exact and item["pid"] not in exact) or (raw_owners and item["pid"] not in raw_owners)
                    or (len(raw_owners) == 1 and not exact and (item["command_buffer_id"] or item["encoder_id"]))):
                conflicts.append({"pids": exact | raw_owners | {item["pid"]}, "interval": item})
        key = tuple(item[name] for name in ("start_ns", "end_ns", "gpu", "channel", "submission_id"))
        physical[key].append(item)
    intervals, unresolved, physical_intervals = [], [], []
    for items in physical.values():
        item = items[0]
        sid = item["submission_id"]
        candidates = owners[sid]
        modeled_pids = {value["pid"] for value in items if value["pid"] and value["pid"] > 0}
        # Unknown/mismatched composite rows are retained as genuinely unknown,
        # even when another joined row happens to carry a known owner.
        unknown = not candidates or any(not composite[(sid, value["command_buffer_id"], value["encoder_id"])]
                      and (value["command_buffer_id"] or value["encoder_id"])
                      and not value["pid"] for value in items)
        possible = candidates | modeled_pids
        if len(possible) == 1 and 0 not in possible and not unknown:
            value = {**item, "pid": next(iter(possible)),
                     "command_identity_certain": len(identities[sid]) == 1}
            intervals.append(value)
        else:
            value = {**item, "pid": None,
                     "candidate_pids": sorted(possible) if possible and 0 not in possible and not unknown else None,
                     "command_identity_certain": False}
            unresolved.append(value)
        physical_intervals.append(value)
    return {"intervals": intervals, "unresolved": unresolved, "physical_intervals": physical_intervals, "owners": owners,
            "submitted": submitted, "submitted_identities": submitted_identities,
            "commands": commands, "conflicts": conflicts, "invalid": invalid}


def command_buffer_completion_proof(frames, completions, submissions, intervals, process_ids, *, unresolved=(), deadline=None):
    """Close committed Metal work, not every candidate driver submission ID.

    Instruments' IOGPU model deliberately emits SID and SID+1 alternatives.
    Neither candidate is required to execute, but every observed execution must
    still pass the independent raw-pair/loss checks. A completion fence means
    execution terminated; it does not assert successful rendering.
    """
    invalid = [*frames.get("invalid", []), *completions.get("invalid", [])]
    owners, commits, completion_times = defaultdict(set), defaultdict(set), defaultdict(set)
    issues = defaultdict(list)
    candidates = defaultdict(set)
    execution_commits = defaultdict(set)
    execution_ends = defaultdict(int)
    certain_process_ends = defaultdict(int)
    executed_candidates = defaultdict(set)

    def identity(row):
        pid = _integer(row["pid"]["text"])
        if row.get("process", {}).get("pid") not in (None, pid):
            raise TraceError("Command-buffer PID conflicts with its process identity")
        return pid, (_integer(row["cmdbuffer-id"]["text"]), _integer(row["commit-id"]["text"]))

    for index, row in enumerate(frames["rows"]):
        if index % 2048 == 0:
            _check_deadline(deadline)
        try:
            pid, key = identity(row)
            kind = row["type-name"]["text"]
            if kind == "MetalFx":
                # Instruments emits synthetic effect scopes in this table;
                # their IDs are not committed Metal command buffers.
                continue
            created, committed = _integer(row["timestamp"]["text"]), _integer(row["commit-time"]["text"])
            owners[key].add(pid)
            commits[(pid, key)].add(committed)
            if pid in process_ids and (kind not in ("Command Buffer", "IO Command Buffer") or
                                       key[0] == 0 or committed <= 0 or committed < created):
                issues[pid].append("Owned command-buffer creation/commit inventory is invalid")
        except (TraceError, KeyError) as error:
            invalid.append(f"Command-buffer inventory: {error}")
    for index, row in enumerate(submissions):
        if index % 2048 == 0:
            _check_deadline(deadline)
        try:
            pid, key = identity(row)
            sid, encoder = _integer(row["gpu-submission-id"]["text"]), _integer(row["encoder-id"]["text"])
            kind = _integer(row["submission-type"]["text"])
            owners[key].add(pid)
            if pid in process_ids:
                candidates[(pid, key)].add((sid, encoder))
                if key[0] == 0 or kind != 0:
                    issues[pid].append("Owned non-Metal or command-ID-zero work has no established completion fence")
                if (pid, key) not in commits:
                    issues[pid].append("Owned GPU mapping has no committed command-buffer inventory")
            execution_commits[(pid, sid, key[0], encoder)].add(key)
        except (TraceError, KeyError) as error:
            invalid.append(f"Command-buffer mapping: {error}")
    for index, row in enumerate(completions["rows"]):
        if index % 2048 == 0:
            _check_deadline(deadline)
        try:
            key = (_integer(row["cmdbuffer-id"]["text"]), _integer(row["commit-id"]["text"]))
            completion_times[key].add(_integer(row["timestamp"]["text"]))
        except (TraceError, KeyError) as error:
            invalid.append(f"Command-buffer completion: {error}")
    for index, item in enumerate(intervals):
        if index % 2048 == 0:
            _check_deadline(deadline)
        pid = item["pid"]
        if pid not in process_ids:
            continue
        certain_process_ends[pid] = max(certain_process_ends[pid], item["end_ns"])
        if not item.get("command_identity_certain", True):
            continue
        mapped = execution_commits[(pid, item["submission_id"], item["command_buffer_id"], item["encoder_id"])]
        if item["command_buffer_id"] == 0 or len(mapped) != 1:
            issues[pid].append("Owned GPU execution has no unique command/commit completion identity")
            continue
        key = next(iter(mapped))
        execution_ends[(pid, key)] = max(execution_ends[(pid, key)], item["end_ns"])
        executed_candidates[(pid, key)].add((item["submission_id"], item["encoder_id"]))
    results = {}
    for pid in process_ids:
        pending, closed, retired_candidates = [], [], 0
        ambiguous_sids = {item["submission_id"] for item in unresolved
                          if item.get("candidate_pids") is None or pid in item["candidate_pids"]}
        ambiguous_sids.update(item["submission_id"] for item in intervals
                              if item["pid"] == pid and not item.get("command_identity_certain", True))
        for (owner, key), times in commits.items():
            if owner != pid:
                continue
            if owners[key] != {pid} or len(times) != 1:
                issues[pid].append("Command/commit identity is reused or shared across process lifetimes")
                pending.append((key[0], key[1]))
                continue
            committed = next(iter(times))
            end = execution_ends[(pid, key)]
            fences = sorted(completion_times[key])
            # An early completion is evidence of a reused/mismatched identity,
            # not a reason to select a later event and silently accept it.
            if len(fences) != 1 or fences[0] < max(committed, end):
                issues[pid].append("Owned command buffer lacks a completion after commit and observed GPU execution")
                pending.append((key[0], key[1]))
                continue
            closed.append({"command_buffer_id": key[0], "commit_id": key[1],
                           "commit_ns": committed, "completion_ns": fences[0]})
            retired_candidates += sum(candidate not in executed_candidates[(pid, key)] and candidate[0] not in ambiguous_sids
                                      for candidate in candidates[(pid, key)])
        latest_completion = max((row["completion_ns"] for row in closed), default=0)
        if certain_process_ends[pid] > latest_completion:
            issues[pid].append("Certain process GPU execution extends beyond every verified completion fence")
        errors = sorted(set([*invalid, *issues[pid]]))
        results[pid] = {"complete": not errors, "invalid": errors,
                        "ambiguous_execution_interval_count": sum(
                            item.get("candidate_pids") is None or pid in item["candidate_pids"] for item in unresolved),
                        "committed_command_count": sum(owner == pid for owner, _ in commits),
                        "completed_command_count": len(closed), "pending_commands": pending,
                        "retired_nonexecuting_candidate_count": retired_candidates,
                        "latest_completion_ns": latest_completion,
                        "latest_commit_ns": max((next(iter(times)) for (owner, _), times in commits.items() if owner == pid and len(times) == 1), default=0)}
    return {"processes": results, "invalid": sorted(set(invalid)),
            "method": "Independent process command/commit inventory and unique completion fences; only unambiguous execution identities constrain individual fences, and ambiguous execution remains in GPU upper bounds"}


def calibration_bounds(measured, expected):
    """Every possible attribution must agree with the independent Metal control."""
    lower = measured["gpu_execution_seconds_lower_bound"]
    upper = measured["gpu_execution_seconds_upper_bound"]
    if not all(isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
               for value in (lower, upper, expected)) or not 0 <= lower <= upper or expected < 0:
        return False
    return (.8 * expected <= lower <= upper <= 1.2 * expected) if expected else upper <= .002


def _mach_clock():
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_absolute_time.restype = ctypes.c_uint64
    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    info = Timebase()
    if system.mach_timebase_info(ctypes.byref(info)) != 0 or info.denom == 0:
        raise TraceError("Cannot read Mach timebase")
    before = time.monotonic_ns()
    ticks = system.mach_absolute_time()
    after = time.monotonic_ns()
    return {"mach_ticks": ticks, "numer": info.numer, "denom": info.denom,
            "monotonic_seconds": (before + after) / 2e9,
            "uncertainty_seconds": (after - before) / 2e9,
            "absolute_minus_monotonic_seconds": ticks * info.numer / info.denom / 1e9 - (before + after) / 2e9}


def _birth_time(pid):
    class BSDInfo(ctypes.Structure):
        _fields_ = [(name, ctypes.c_uint32) for name in (
            "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "rfu")]
        _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
        _fields_ += [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tdev", "tpgid", "nice")]
        _fields_ += [("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]
    info = BSDInfo()
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    size = ctypes.sizeof(info)
    if library.proc_pidinfo(pid, 3, 0, ctypes.byref(info), size) != size or info.pid != pid:
        raise TraceError(f"Cannot verify process identity for PID {pid}")
    return info.start_sec * 1_000_000 + info.start_usec


class _Notice:
    def __init__(self):
        self.library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        self.token = ctypes.c_int()
        self.name = f"dev.fluxllm.performance.trace.{uuid.uuid4()}"
        if self.library.notify_register_check(self.name.encode(), ctypes.byref(self.token)) != 0:
            raise TraceError("Cannot register Instruments start notification")
        self.ready()  # notify_check's initial state is not a recording event.

    def ready(self):
        changed = ctypes.c_int()
        if self.library.notify_check(self.token, ctypes.byref(changed)) != 0:
            raise TraceError("Cannot read Instruments start notification")
        return bool(changed.value)

    def close(self):
        self.library.notify_cancel(self.token)


class _Worker:
    def __init__(self, executable, deadline, directory, label):
        self.deadline = deadline
        self.log = (directory / f"calibration-{label}.jsonl").open("w")
        self.process = subprocess.Popen([str(executable), "--gpu-calibration-worker"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                        bufsize=1, start_new_session=True)
        self.pid = self.process.pid
        try:
            self.birth = _birth_time(self.pid)
        except Exception:
            self.process.kill()
            self.process.wait(timeout=.5)
            self.log.close()
            raise
        self.lines = queue.Queue()
        def read():
            for line in self.process.stdout:
                self.lines.put(line)
            self.lines.put(None)
        self.thread = threading.Thread(target=read, daemon=True)
        self.thread.start()
        try:
            self.reply("ready")
        except Exception:
            self.close()
            raise

    def reply(self, event):
        try:
            line = self.lines.get(timeout=max(.001, min(5, self.deadline - time.monotonic())))
        except queue.Empty as error:
            raise TraceError("GPU trace calibration helper timed out") from error
        if line is None or len(line) > 8192:
            raise TraceError("GPU trace calibration helper ended unexpectedly")
        self.log.write(line)
        self.log.flush()
        value = json.loads(line)
        if value.get("event") != event or value.get("error"):
            raise TraceError(f"GPU calibration reply failed: {value}")
        if _birth_time(self.pid) != self.birth:
            raise TraceError("GPU calibration helper identity changed")
        return value

    def command(self, command, **values):
        self.process.stdin.write(json.dumps({"command": command, **values}) + "\n")
        self.process.stdin.flush()

    def close(self):
        if self.process.poll() is None:
            try:
                self.command("stop")
                self.process.wait(timeout=min(.5, max(.001, self.deadline - time.monotonic())))
            except (OSError, subprocess.TimeoutExpired):
                if self.process.poll() is None and _birth_time(self.pid) == self.birth:
                    self.process.kill()
                self.process.wait(timeout=.5)
        self.log.close()
        return {"status": self.process.returncode, "final_sample_monotonic_seconds": time.monotonic()}


class _Sentinel:
    """An inert owned attachment target; GPU records remain process-attributed globally."""
    def __init__(self, deadline):
        self.deadline = deadline
        self.process = subprocess.Popen(["/bin/sleep", str(max(1, math.ceil(deadline - time.monotonic()) + 5))],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            self.birth = _birth_time(self.process.pid)
        except Exception:
            self.process.kill()
            self.process.wait(timeout=.5)
            raise

    def verify(self):
        if self.process.poll() is not None or _birth_time(self.process.pid) != self.birth:
            raise TraceError("The owned GPU trace attachment target exited or changed identity")

    def close(self):
        if self.process.poll() is None:
            self.verify()
            self.process.terminate()
            try:
                self.process.wait(timeout=max(.001, min(.25, self.deadline - time.monotonic())))
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=.25)


class TraceSession:
    """Synchronous start/finalize, independent of the measured app processes."""
    def __init__(self, output, deadline, *, phase_deadlines=None, record_limit_seconds=None):
        self.deadline = float(deadline)
        self.phase_deadlines = dict(phase_deadlines or {})
        names = ("record", "finalize", "toc", "export", "evaluate")
        if set(self.phase_deadlines) - set(names):
            raise TraceError("Unknown GPU trace phase deadline")
        ordered = [self.phase_deadlines[name] for name in names if name in self.phase_deadlines]
        if (not math.isfinite(self.deadline) or any(type(value) not in (int, float)
                or not math.isfinite(value) or value > self.deadline for value in ordered)
                or ordered != sorted(ordered)):
            raise TraceError("GPU trace phase deadlines must be finite, ordered, and within the overall deadline")
        if record_limit_seconds is not None and (type(record_limit_seconds) not in (int, float)
                or not math.isfinite(record_limit_seconds) or record_limit_seconds < 1):
            raise TraceError("GPU recording limit must be at least one finite second")
        self.record_limit_seconds = record_limit_seconds
        self.phases = {}
        self._active_phase = None
        self.output = Path(output) / "system-trace"
        self.output.mkdir(parents=True, exist_ok=False)
        self.trace = self.output / "performance.trace"
        self.xml = self.output / "tables.xml"
        self.toc = self.output / "toc.xml"
        self.process = None
        self.sentinel = None
        self.log = None
        self.invalid = []
        self.processes = {}
        self.windows = {}
        self.exits = {}
        self.references = []
        self.clock_mapping = {}
        self.schemas = [*CORE_SCHEMAS, *TERMINAL_SCHEMAS]
        self.result = None

    def _phase_deadline(self, name=None):
        deadline = getattr(self, "deadline", None)
        phase = name if name is not None else getattr(self, "_active_phase", None)
        return getattr(self, "phase_deadlines", {}).get(phase, deadline)

    def _remaining(self, cap=None):
        remaining = self._phase_deadline() - time.monotonic()
        if remaining <= 0:
            phase = getattr(self, "_active_phase", None)
            raise TraceError(f"Performance deadline expired during trace {phase or 'collection/export'}")
        return min(remaining, cap) if cap is not None else remaining

    def _begin_phase(self, name, *, check=True):
        if not hasattr(self, "phases"):
            self.phases = {}
        self._active_phase = name
        self.phases[name] = {"started_monotonic_seconds": time.monotonic(),
                             "deadline_monotonic_seconds": self._phase_deadline(name), "status": "running"}
        if check:
            self._remaining()

    def _end_phase(self, name, error=None):
        phase = self.phases[name]
        ended = time.monotonic()
        expired = ended >= phase["deadline_monotonic_seconds"]
        phase.update(ended_monotonic_seconds=ended,
                     elapsed_seconds=max(0, ended - phase["started_monotonic_seconds"]),
                     status="deadline_exceeded" if expired or isinstance(error, subprocess.TimeoutExpired)
                     else "failed" if error is not None else "complete")
        if error is not None:
            phase["error"] = str(error)
        return expired

    @contextmanager
    def _phase(self, name):
        previous = getattr(self, "_active_phase", None)
        try:
            self._begin_phase(name)
            yield
            self._remaining()
        except BaseException as error:
            self._end_phase(name, error)
            raise
        else:
            self._end_phase(name)
        finally:
            self._active_phase = previous

    def monotonic_from_mach_seconds(self, value):
        """Convert a collector's paired Mach anchor to the runner clock domain."""
        if type(value) not in (int, float) or not math.isfinite(value):
            raise TraceError("Missing or invalid collector Mach clock anchor")
        return value - self.clock_start["absolute_minus_monotonic_seconds"]

    def start(self):
        notice = None
        try:
            self._begin_phase("record")
            self.clock_start = _mach_clock()
            xctrace = Path(subprocess.check_output(["xcrun", "--find", "xctrace"], text=True,
                                                   timeout=self._remaining(3)).strip())
            template = xctrace.parent.parent.parent.parent / "Applications/Instruments.app/Contents/Packages/Base.instrdst/Contents/Templates/Blank.tracetemplate"
            if not template.is_file():
                raise TraceError("The installed minimal Instruments template is unavailable")
            # The full Metal template enables expensive CPU/display/resource
            # tracks that are unnecessary for process GPU measurements.
            notice = _Notice()
            self.sentinel = _Sentinel(self.deadline)
            record_limit = getattr(self, "record_limit_seconds", None)
            if record_limit is None:
                record_limit = max(1, int(self._remaining() - 15))
            if getattr(self, "record_limit_seconds", None) is not None or "record" in self.phase_deadlines:
                record_limit = int(min(record_limit, self._remaining()))
                if record_limit < 1:
                    raise TraceError("Less than one second remains in the GPU recording budget")
            command = [str(xctrace), "record", "--template", str(template), "--attach", str(self.sentinel.process.pid),
                       "--no-prompt", "--notify-tracing-started", notice.name,
                       "--time-limit", f"{record_limit}s", "--output", str(self.trace)]
            command.extend(["--instrument", "GPU"])
            self.log = (self.output / "record.log").open("w")
            self.process = subprocess.Popen(command, stdout=self.log, stderr=subprocess.STDOUT, start_new_session=True)
            ready_deadline = min(self._phase_deadline("record"), time.monotonic() + 15)
            while time.monotonic() < ready_deadline:
                if self.process.poll() is not None:
                    raise TraceError("Instruments exited before recording readiness; see record.log")
                if notice.ready():
                    self.sentinel.verify()
                    self._remaining()
                    self.ready_monotonic = time.monotonic()
                    result = {"provider": PROVIDER, "ready_monotonic_seconds": self.ready_monotonic,
                              "clock_start": self.clock_start, "command": command,
                              "attachment_target": {"pid": self.sentinel.process.pid, "birth_time_us": self.sentinel.birth},
                              "phase_deadlines": self.phase_deadlines,
                              "capture_scope": "Global GPU execution; attached to an owned inert sentinel. Separate future-born helper PIDs validate global attribution each run.",
                              "artifacts": {"trace": str(self.trace)}}
                    (self.output / "start.json").write_text(json.dumps(result, indent=2) + "\n")
                    return result
                time.sleep(.01)
            raise TraceError("Instruments did not announce recording readiness within 15 seconds")
        except Exception as error:
            self._end_phase("record", error)
            try:
                if self.process is not None and self.process.poll() is None:
                    self.process.kill()
                    self.process.wait(timeout=.25)
            except (OSError, subprocess.TimeoutExpired) as cleanup_error:
                self.invalid.append(f"Recorder startup cleanup: {cleanup_error}")
            if self.sentinel is not None:
                try:
                    self.sentinel.close()
                except (TraceError, OSError, subprocess.TimeoutExpired) as cleanup_error:
                    self.invalid.append(f"GPU trace attachment startup cleanup: {cleanup_error}")
            if self.log is not None and not self.log.closed:
                try:
                    self.log.close()
                except OSError as cleanup_error:
                    self.invalid.append(f"GPU trace log startup cleanup: {cleanup_error}")
            raise
        finally:
            if notice is not None:
                notice.close()

    def register_process(self, pid, birth_time_us, baseline_monotonic):
        if type(pid) is not int or pid <= 0 or type(birth_time_us) is not int or birth_time_us <= 0:
            raise TraceError("Trace process registration requires PID and birth time")
        if pid in self.processes and self.processes[pid]["birth_time_us"] != birth_time_us:
            raise TraceError("A trace PID was reused; process attribution is ambiguous")
        self.processes[pid] = {"birth_time_us": birth_time_us, "baseline_monotonic_seconds": baseline_monotonic}

    def add_window(self, name, pid, birth_time_us, start, end):
        if name in self.windows or not isinstance(name, str) or not name or not all(math.isfinite(v) for v in (start, end)) or end <= start:
            raise TraceError("Invalid or duplicate trace measurement window")
        if self.processes.get(pid, {}).get("birth_time_us") != birth_time_us:
            raise TraceError("Window process identity is not registered")
        self.windows[name] = {"process_id": pid, "birth_time_us": birth_time_us,
                              "start_monotonic_seconds": start, "end_monotonic_seconds": end}

    def register_exit(self, pid, birth_time_us, final_sample_time, trace_drain_end, status):
        if self.processes.get(pid, {}).get("birth_time_us") != birth_time_us:
            raise TraceError("Exit process identity is not registered")
        if not all(math.isfinite(value) for value in (final_sample_time, trace_drain_end)) or trace_drain_end < final_sample_time:
            raise TraceError("Invalid exit/drain timestamps")
        self.exits[pid] = {"birth_time_us": birth_time_us, "final_sample_monotonic_seconds": final_sample_time,
                           "trace_drain_end_monotonic_seconds": trace_drain_end, "status": status}

    def calibrate(self, collector):
        workers = []
        calibration_deadline = min(self._phase_deadline("record"), time.monotonic() + 8)
        try:
            self._remaining()
            for label in ("target", "unrelated"):
                worker = _Worker(collector, calibration_deadline, self.output, label)
                workers.append(worker)
                self.register_process(worker.pid, worker.birth, time.monotonic())
            first, second = workers
            start = time.monotonic()
            time.sleep(min(1, self._remaining()))
            end = time.monotonic()
            self.references.append({"kind": "idle", "pid": first.pid, "birth": first.birth, "start": start, "end": end, "metal_seconds": 0})
            for index, worker in enumerate(workers):
                start = time.monotonic()
                worker.command("work", seconds=1)
                reply = worker.reply("completed")
                self._remaining()
                end = time.monotonic()
                metal = reply.get("gpu_seconds")
                if type(metal) not in (int, float) or not math.isfinite(metal) or metal < .05:
                    raise TraceError("Calibration helper returned insufficient completed GPU timing")
                self.references.append({"kind": "target" if index == 0 else "unrelated", "pid": worker.pid,
                                        "birth": worker.birth, "start": start, "end": end, "metal_seconds": metal})
                if index == 1:
                    self.references.append({"kind": "attribution", "pid": first.pid, "birth": first.birth,
                                            "start": start, "end": end, "metal_seconds": 0})
            return {"pending_trace_export": True, "references": self.references}
        except (TraceError, OSError, ValueError) as error:
            self.invalid.append(f"GPU trace calibration: {error}")
            return {"pending_trace_export": False, "invalid": [str(error)]}
        finally:
            for worker in workers:
                try:
                    terminal = worker.close()
                    self.register_exit(worker.pid, worker.birth, terminal["final_sample_monotonic_seconds"],
                                       time.monotonic(), terminal["status"])
                except (ValueError, KeyError, OSError, subprocess.TimeoutExpired) as error:
                    self.invalid.append(f"GPU trace calibration helper {worker.pid} cleanup: {error}")
            (self.output / "calibration-references.json").write_text(json.dumps(
                {"references": self.references, "exits": self.exits, "invalid": self.invalid}, indent=2) + "\n")

    def _run_export(self, arguments, label):
        with (self.output / f"{label}.log").open("w") as log:
            completed = subprocess.run(["xcrun", "xctrace", "export", "--input", str(self.trace), *arguments],
                                       stdout=log, stderr=subprocess.STDOUT, timeout=self._remaining(), check=False)
        if completed.returncode != 0:
            raise TraceError(f"Instruments {label} failed; see {label}.log")

    def export_table(self, schema):
        if schema not in self.exported_schemas:
            raise TraceError(f"Table {schema} was not exported in the shared trace")
        return self.xml

    def finish(self):
        if self.result is not None:
            return self.result
        result = {"provider": PROVIDER, "valid": False, "invalid": self.invalid,
                  "calibration": {}, "windows": {}, "final_exit_coverage": {},
                  "recording_complete": False, "lost_events": None, "tables": {},
                  "phases": getattr(self, "phases", {}),
                  "artifacts": {"trace": str(self.trace), "xml": str(self.xml), "toc": str(self.toc)}}
        self.result = result
        try:
            if self.process is None:
                raise TraceError("Trace recording was not started")
            if self.sentinel is not None:
                self.sentinel.verify()
            if self.process.poll() is None:
                self.stop_requested_monotonic = time.monotonic()
                self.process.send_signal(signal.SIGINT)
            else:
                self.stop_requested_monotonic = time.monotonic()
                self.invalid.append("Trace recording ended before controlled finalization")
            if getattr(self, "phases", {}).get("record", {}).get("status") == "running":
                if self._end_phase("record"):
                    self.invalid.append("GPU recording exceeded its phase deadline")
            with self._phase("finalize"):
                self.process.wait(timeout=self._remaining())
                self.log.close()
                if self.process.returncode != 0:
                    raise TraceError(f"Instruments recording exited with status {self.process.returncode}")
                result["recording_complete"] = True
                result["recording_issues"] = read_run_issues(self.trace)
                result["lost_events"] = result["recording_issues"]["lost_events"]
                self.invalid.extend(result["recording_issues"]["invalid"])
                self.clock_end = _mach_clock()
                log = (self.output / "record.log").read_text(errors="replace")
                warnings = [line for line in log.splitlines() if re.search(r"lost|dropped|overflow|incomplete|error|failed", line, re.I)]
                self.invalid.extend(f"Trace diagnostic: {line}" for line in warnings)
                if any(re.search(r"lost|dropped|overflow", line, re.I) for line in warnings):
                    result["lost_events"] = True
            with self._phase("toc"):
                self._run_export(["--toc", "--output", str(self.toc)], "export-toc")
                toc = ET.parse(self.toc).getroot()
                available = {table.get("schema") for table in toc.findall(".//table")}
                if "metal-command-buffer-error" in available:
                    self.schemas.append("metal-command-buffer-error")
                self.exported_schemas = sorted(set(self.schemas) & available)
                missing = set(CORE_SCHEMAS) - available
                self.invalid.extend(f"Required trace schema is absent: {schema}" for schema in sorted(missing))
            with self._phase("export"):
                clauses = " or ".join(f'@schema="{name}"' for name in self.exported_schemas)
                self._run_export(["--xpath", f"/trace-toc/run[@number=\"1\"]/data/table[{clauses}]", "--output", str(self.xml)], "export-tables")
                export_schema_index(self.trace, self.toc, self.xml)
                result["exported_schemas"] = self.exported_schemas
                result["tables"] = {schema: str(self.xml) for schema in self.exported_schemas}
            with self._phase("evaluate"):
                self._evaluate(toc, result)
        except (ValueError, KeyError, OSError, subprocess.TimeoutExpired, ET.ParseError) as error:
            self.invalid.append(str(error))
        finally:
            if getattr(self, "phases", {}).get("record", {}).get("status") == "running":
                self._end_phase("record", TraceError("Recording did not reach controlled finalization"))
            self._begin_phase("cleanup", check=False)
            cleanup_errors_before = len(self.invalid)
            try:
                if self.process is not None and self.process.poll() is None:
                    self.process.kill()
                    self.process.wait(timeout=max(.001, min(.5, self.deadline - time.monotonic())))
            except (OSError, subprocess.TimeoutExpired) as error:
                self.invalid.append(f"Instruments recorder cleanup: {error}")
            if self.log is not None and not self.log.closed:
                try:
                    self.log.close()
                except OSError as error:
                    self.invalid.append(f"Instruments log cleanup: {error}")
            if self.sentinel is not None:
                try:
                    self.sentinel.close()
                except (TraceError, OSError, subprocess.TimeoutExpired) as error:
                    self.invalid.append(f"GPU trace attachment cleanup: {error}")
            cleanup_error = (TraceError("; ".join(self.invalid[cleanup_errors_before:]))
                             if len(self.invalid) > cleanup_errors_before else None)
            if self._end_phase("cleanup", cleanup_error):
                self.invalid.append("GPU trace cleanup exceeded the overall deadline")
        result["valid"] = not self.invalid
        (self.output / "trace-report.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
        return result

    def _evaluate(self, toc, result):
        deadline = self._phase_deadline("evaluate")
        _check_deadline(deadline)
        result["parser"] = {"implementation": "stdlib.xml.etree.ElementTree", "python_version": platform.python_version(),
                            "element_tree_version": ET.VERSION, "selection": {}}

        def table(schema):
            value = read_table(self.xml, schema, deadline=deadline, process_ids=frozenset(self.processes))
            if "selection" in value:
                result["parser"]["selection"][schema] = value["selection"]
            return value

        clock = table("time-info")
        self.invalid.extend(clock["invalid"])
        if not clock["rows"]:
            raise TraceError("Trace has no exact clock origin")
        row = clock["rows"][0]
        components = row["timebase"].get("components", [])
        if len(components) != 2 or components[1] == 0:
            raise TraceError("Invalid trace Mach timebase")
        numer, denom = components
        epoch = _integer(row["mach-absolute-time"]["text"]) * numer / denom / 1e9
        origin = epoch - self.clock_start["absolute_minus_monotonic_seconds"]
        drift = abs(self.clock_end["absolute_minus_monotonic_seconds"] - self.clock_start["absolute_minus_monotonic_seconds"])
        uncertainty = max(self.clock_start["uncertainty_seconds"], self.clock_end["uncertainty_seconds"]) + drift
        if uncertainty > .001:
            self.invalid.append("Trace/monotonic clock correspondence changed by more than1ms")
        duration = float(toc.findtext("./run/info/summary/duration", "nan"))
        if not math.isfinite(duration) or duration <= 0:
            raise TraceError("Trace recording duration is unavailable")
        self.clock_mapping = {"trace_origin_monotonic_seconds": origin, "trace_duration_seconds": duration,
                              "uncertainty_seconds": uncertainty, "timebase_numer": numer, "timebase_denom": denom,
                              "trace_origin_mach_ticks": _integer(row["mach-absolute-time"]["text"])}
        result["clock_mapping"] = self.clock_mapping
        result["tool"] = {"instruments_version": toc.findtext("./run/info/summary/instruments-version"),
                          "template": toc.findtext("./run/info/summary/template-name"),
                          "recording_mode": toc.findtext("./run/info/summary/recording-mode")}
        parsed = parse_gpu_intervals(table(GPU_SCHEMA), deadline=deadline)
        self.invalid.extend(parsed["invalid"])
        result["duplicate_rows"] = parsed["duplicates"]
        result["unattributed_interval_count"] = len(parsed["unattributed"])
        processes = table("process-info")
        self.invalid.extend(processes["invalid"])
        process_ids = defaultdict(set)
        process_cells = defaultdict(set)
        process_times = defaultdict(list)
        invalid_identity_pids = set()
        for index, row in enumerate(processes["rows"]):
            if index % 4096 == 0:
                _check_deadline(deadline)
            pid = _integer(row["pid"]["text"])
            process_ids[pid].add(row["unique-id"]["text"])
            process_cells[pid].add(row["process"]["id"])
            process_times[pid].append(_integer(row["timestamp"]["text"]))
            if not row["unique-id"]["text"] or not row["process"]["id"] or row["process"].get("pid") not in (None, pid):
                invalid_identity_pids.add(pid)
        result["process_identities"] = [
            {"pid": pid, "birth_time_us": registration["birth_time_us"],
             "trace_process_id": next(iter(process_cells[pid])) if len(process_cells[pid]) == 1 else None,
             "trace_unique_id": next(iter(process_ids[pid])) if len(process_ids[pid]) == 1 else None,
             "trace_process_timestamps_ns": sorted(process_times[pid]),
             "identity_verified": len(process_ids[pid]) == 1 and len(process_cells[pid]) == 1 and pid not in invalid_identity_pids,
             "verification_method": "Collector kernel-verified PID/birth and one unreused trace process identity for that PID"}
            for pid, registration in self.processes.items()]
        submissions = table("metal-gpu-submission-to-command-buffer-id")
        self.invalid.extend(submissions["invalid"])
        ownership = reconcile_submission_ownership(parsed, submissions["rows"], deadline=deadline)
        self.invalid.extend(ownership["invalid"])
        parsed["intervals"] = ownership["intervals"]
        unresolved = ownership["unresolved"]
        submitted, submission_commands = ownership["submitted"], ownership["commands"]
        result["resolved_unattributed_interval_count"] = max(0, len(parsed["unattributed"]) - len(unresolved))
        result["ambiguous_execution_interval_count"] = len(unresolved)
        result["ownership_method"] = "Raw SID candidate-owner union; modeled command/encoder joins cannot disambiguate SID aliases"
        execution = table("metal-gpu-execution-points")
        self.invalid.extend(execution["invalid"])
        result["execution_points"] = len(execution["rows"])
        result["loss_validation"] = self._execution_coverage(execution,
            {"intervals": ownership["physical_intervals"], "unattributed": []}, origin, duration, ownership["owners"])
        self.invalid.extend(result["loss_validation"]["invalid"])
        for conflict in ownership["conflicts"]:
            item = conflict["interval"]
            for pid in conflict["pids"].intersection(self.processes):
                result["loss_validation"]["process_issues"].append({"pid": pid,
                    "start_ns": item["start_ns"], "end_ns": item["end_ns"],
                    "message": "A GPU command/encoder identity conflicts with its modeled process"})
        command_errors = table("metal-command-buffer-error") if "metal-command-buffer-error" in self.exported_schemas else {"rows": [], "invalid": []}
        self.invalid.extend(command_errors["invalid"])
        errored_commands = {_integer(error["cmdbuffer-id"]["text"]) for error in command_errors["rows"]}
        intervals_by_pid = defaultdict(list)
        for index, item in enumerate(parsed["intervals"]):
            if index % 4096 == 0:
                _check_deadline(deadline)
            intervals_by_pid[item["pid"]].append(item)

        completion_proof = command_buffer_completion_proof(
            table("metal-command-buffer-frame-assignment"), table("metal-command-buffer-completed"),
            submissions["rows"], parsed["intervals"], self.processes, unresolved=unresolved, deadline=deadline)
        result["terminal_command_proof"] = completion_proof

        def metrics(pid, start, end):
            _check_deadline(deadline)
            return bounded_interval_metrics(intervals_by_pid[pid], unresolved, pid,
                round((start - origin) * 1e9), round((end - origin) * 1e9))

        evidence = []
        calibration_errors = []
        for reference in self.references:
            measured = metrics(reference["pid"], reference["start"], reference["end"])
            actual = measured["gpu_execution_seconds"]
            expected = reference["metal_seconds"]
            passed = calibration_bounds(measured, expected)
            left, right = round((reference["start"] - origin) * 1e9), round((reference["end"] - origin) * 1e9)
            reference_errors = []
            if reference["start"] < origin or reference["end"] > origin + duration:
                reference_errors.append("The calibration window is outside the complete recording")
            if len(process_ids[reference["pid"]]) != 1 or len(process_cells[reference["pid"]]) != 1 or reference["pid"] in invalid_identity_pids:
                reference_errors.append("The calibration process identity is absent or ambiguous")
            reference_errors.extend(issue["message"] for issue in result["loss_validation"]["process_issues"]
                if issue["pid"] == reference["pid"] and issue["start_ns"] < right and issue["end_ns"] > left)
            if any(start < right and end > left for start, end in result["loss_validation"]["unattributed_pairs"]):
                reference_errors.append("An unresolved execution gap overlaps the calibration window")
            passed = passed and not reference_errors
            evidence.append({**reference, "trace_execution_seconds": actual,
                             "trace_execution_seconds_lower_bound": measured["gpu_execution_seconds_lower_bound"],
                             "trace_execution_seconds_upper_bound": measured["gpu_execution_seconds_upper_bound"],
                             "attribution_exact": measured["attribution_exact"], "passed": passed,
                             "invalid": sorted(set(reference_errors))})
            if not passed:
                calibration_errors.append(f"{reference['kind']} GPU trace calibration failed: trace bounds="
                    f"[{measured['gpu_execution_seconds_lower_bound']}, {measured['gpu_execution_seconds_upper_bound']}]s Metal={expected}s")
                calibration_errors.extend(reference_errors)
        if {row["kind"] for row in self.references} != {"idle", "target", "unrelated", "attribution"}:
            calibration_errors.append("GPU trace calibration did not cover idle, target work, and unrelated work")
        result["calibration"] = {"valid": not calibration_errors, "invalid": calibration_errors, "evidence": evidence,
                                  "maximum_relative_error": .20, "maximum_idle_seconds": .002}
        self.invalid.extend(calibration_errors)
        active_helpers = {reference["pid"] for reference in self.references if reference["kind"] in ("target", "unrelated")}
        control_errors = []
        if len(active_helpers) != 2:
            control_errors.append("Terminal inventory requires two distinct active helper processes")
        for pid in active_helpers:
            proof = completion_proof["processes"].get(pid, {})
            if not proof.get("complete") or proof.get("committed_command_count", 0) == 0:
                control_errors.append(f"Active helper {pid} lacks a complete nonempty command/commit/completion inventory")
            if any(issue["pid"] == pid for issue in result["loss_validation"]["process_issues"]):
                control_errors.append(f"Active helper {pid} has incomplete raw execution coverage")
        target = toc.find("./run/info/target/process")
        target_pid = int(target.get("pid", "0")) if target is not None else 0
        target_kind = target.get("type") if target is not None else None
        scope_valid = target_kind == "attached" and target_pid > 0 and target_pid not in active_helpers
        sentinel = getattr(self, "sentinel", None)
        if sentinel is not None and target_pid != sentinel.process.pid:
            scope_valid = False
        if not scope_valid:
            control_errors.append("Attached-target global GPU coverage was not validated with separate helper PIDs")
            self.invalid.append(control_errors[-1])
        result["capture_scope"] = {"mode": "owned_inert_attachment_with_global_gpu_events", "target_pid": target_pid,
            "validated": scope_valid and result["calibration"]["valid"], "calibration_process_ids": sorted(active_helpers)}
        result["terminal_inventory_controls"] = {"valid": not control_errors and result["calibration"]["valid"],
            "invalid": control_errors, "basis": "Two separate future-born active helpers must have verified nonempty command inventories, completion fences and raw execution coverage before empty app inventory can represent idle"}
        for name, window in self.windows.items():
            _check_deadline(deadline)
            pid = window["process_id"]
            start, end = window["start_monotonic_seconds"], window["end_monotonic_seconds"]
            invalid = list(self.invalid)
            if len(process_ids[pid]) != 1 or len(process_cells[pid]) != 1 or pid in invalid_identity_pids:
                invalid.append("Trace process identity is absent or reused")
            if start < origin or end > origin + duration:
                invalid.append("The trace does not cover the complete requested workload window")
            start_ns, end_ns = round((start - origin) * 1e9), round((end - origin) * 1e9)
            if any(left < end_ns and right > start_ns for left, right in result["loss_validation"]["unattributed_pairs"]):
                invalid.append("An unattributed raw GPU execution pair overlaps this window")
            invalid.extend(issue["message"] for issue in result["loss_validation"]["process_issues"]
                           if issue["pid"] == pid and issue["start_ns"] < end_ns and issue["end_ns"] > start_ns)
            values = bounded_interval_metrics(intervals_by_pid[pid], unresolved, pid, start_ns, end_ns)
            result["windows"][name] = {**window, **values, "coverage_complete": not invalid, "invalid": invalid,
                                       "clock_uncertainty_seconds": uncertainty}
            exit_record = self.exits.get(pid)
            proof = completion_proof["processes"][pid]
            final_invalid = [*invalid, *proof["invalid"]]
            final_invalid.extend(issue["message"] for issue in result["loss_validation"]["process_issues"]
                                 if issue["pid"] == pid and issue["message"] not in final_invalid)
            if not result["terminal_inventory_controls"]["valid"]:
                final_invalid.append("Same-run active controls did not establish terminal command-inventory coverage")
            if exit_record is None:
                final_invalid.append("No verified process exit was registered")
            elif exit_record["status"] != 0:
                final_invalid.append("The measured process did not exit successfully")
            elif exit_record["trace_drain_end_monotonic_seconds"] > origin + duration:
                final_invalid.append("Trace ended before the registered exit drain completed")
            if submission_commands[pid].intersection(errored_commands):
                final_invalid.append("An owned GPU command buffer reported an execution error")
            if result["lost_events"] is not False:
                final_invalid.append("Definitive trace loss metadata is not yet established")
            owned_intervals = intervals_by_pid[pid]
            last_owned_end = max((origin + item["end_ns"] / 1e9 for item in owned_intervals), default=None)
            latest_completion = origin + proof["latest_completion_ns"] / 1e9
            if latest_completion > origin + duration:
                final_invalid.append("An owned completion fence lies beyond the recording boundary")
            quiescence = None
            tail_values = None
            ambiguity_accounting_end = None
            # CPU completion fences cannot establish the ownership of an
            # ambiguous raw execution. Preserve the recorded possible tail.
            compatible_ambiguity = [item for item in unresolved
                if item.get("candidate_pids") is None or pid in item["candidate_pids"]]
            if exit_record is not None:
                # The collector's final sample is taken only after waitid has
                # verified the child is a zombie, so it bounds kernel exit above.
                exit_time = exit_record["final_sample_monotonic_seconds"]
                if origin + proof["latest_commit_ns"] / 1e9 > exit_time + uncertainty:
                    final_invalid.append("Owned command commit occurs after the verified process exit")
                quiescence = max(exit_time, latest_completion) + uncertainty
                ambiguity_accounting_end = max(quiescence,
                    exit_record["trace_drain_end_monotonic_seconds"],
                    max((origin + item["end_ns"] / 1e9 for item in compatible_ambiguity), default=quiescence)
                    ) if compatible_ambiguity else quiescence
                if ambiguity_accounting_end > origin + duration:
                    final_invalid.append("Trace ended before process exit and all owned command completions were covered")
                else:
                    exit_ns = round((exit_time - origin) * 1e9)
                    quiet_ns = round((ambiguity_accounting_end - origin) * 1e9)
                    if any(left < quiet_ns and right > start_ns for left, right in result["loss_validation"]["unattributed_pairs"]):
                        final_invalid.append("An unresolved raw execution gap overlaps the process lifetime or completion tail")
                    if quiet_ns > exit_ns:
                        tail_values = bounded_interval_metrics(owned_intervals, unresolved, pid, exit_ns, quiet_ns)
                    if name.endswith("/lifetime") and not final_invalid and ambiguity_accounting_end > end:
                        values = bounded_interval_metrics(owned_intervals, unresolved, pid, start_ns, quiet_ns)
                        # Late ambiguous work widens the execution numerator,
                        # never the denominator: extending both could lower an
                        # alleged upper bound merely by adding unrelated work.
                        for percent, seconds in (("gpu_percent", "gpu_execution_seconds"),
                                                 ("gpu_busy_union_percent", "gpu_busy_union_seconds")):
                            for suffix in ("_lower_bound", "_upper_bound"):
                                values[percent + suffix] = values[seconds + suffix] / (end - start) * 100
                            values[percent] = values[percent + "_lower_bound"] if values["attribution_exact"] else None
                        result["windows"][name].update(values)
                        result["windows"][name]["gpu_accounting_end_monotonic_seconds"] = ambiguity_accounting_end
                        result["windows"][name]["gpu_accounting_duration_seconds"] = end - start
                        result["windows"][name]["gpu_execution_coverage_duration_seconds"] = ambiguity_accounting_end - start
                        result["windows"][name]["gpu_percent_denominator"] = "Fixed registered window duration; possible queued/ambiguous tail only increases execution numerator"
            final_invalid = sorted(set(final_invalid))
            result["final_exit_coverage"][name] = {
                "complete": not final_invalid, "invalid": final_invalid,
                "reason": "; ".join(final_invalid) if final_invalid else None,
                "exit": exit_record, "submitted_candidate_count": len(submitted[pid]),
                "command_completion_proof": proof,
                "quiescence_upper_bound_monotonic_seconds": quiescence,
                "anonymous_execution_after_quiescence_excluded": not final_invalid and not compatible_ambiguity,
                "ambiguous_execution_interval_count": len(compatible_ambiguity),
                "ambiguous_execution_accounting_end_monotonic_seconds": ambiguity_accounting_end,
                "last_owned_execution_end_monotonic_seconds": last_owned_end,
                "post_exit_execution_bounds": tail_values,
                "pending_command_count": len(proof["pending_commands"])}
        _check_deadline(deadline)

    def _execution_coverage(self, table, parsed, origin, duration, submission_owners=None):
        """Cross-check every raw execution pair against modeled execution.

        Submission numbers can collide across PIDs. Exact modeled interval time
        and command identity resolve ownership first; a bare submission number is
        used only to conservatively identify potential owners of missing records.
        Anonymous complete modeled execution is bounded separately. Missing raw
        boundaries or missing modeled execution remain invalid, never finite zero.
        """
        invalid, process_issues = [], []
        deadline = self._phase_deadline("evaluate")

        def process_issue(pids, start, end, message):
            for pid in pids:
                if pid in self.processes:
                    process_issues.append({"pid": pid, "start_ns": start, "end_ns": end, "message": message})

        owners = defaultdict(set)
        for submission, pids in (submission_owners or {}).items():
            owners[submission].update(pids)
        modeled = defaultdict(list)
        for index, item in enumerate([*parsed["intervals"], *parsed.get("unattributed", [])]):
            if index % 4096 == 0:
                _check_deadline(deadline)
            key = (item["submission_id"], item["start_ns"], item["end_ns"])
            # A resolved interval can also be in the original anonymous list.
            if item not in modeled[key]:
                modeled[key].append(item)
            if item["pid"] and item["pid"] > 0:
                owners[item["submission_id"]].add(item["pid"])
        open_points, pairs, incomplete, seen = {}, set(), [], set()
        for index, row in enumerate(table["rows"]):
            if index % 4096 == 0:
                _check_deadline(deadline)
            try:
                timestamp = _integer(row["timestamp"]["text"])
                submission = _integer(row["gpu-submission-id"]["text"])
                channel = _integer(row["channel-id"]["text"])
                function = _integer(row["function"]["text"])
                point = (channel, submission, timestamp, function)
                if point in seen:
                    continue
                seen.add(point)
                key = (channel, submission)
                if function == 1:
                    if key in open_points:
                        incomplete.append((submission, open_points[key], timestamp))
                    open_points[key] = timestamp
                elif function == 2:
                    if key in open_points:
                        start = open_points.pop(key)
                        if timestamp <= start:
                            raise TraceError("GPU execution boundary is not after its start")
                        pairs.add((channel, submission, start, timestamp))
                    else:
                        incomplete.append((submission, 0, timestamp))
                else:
                    raise TraceError(f"Unknown GPU execution function {function}")
            except (TraceError, KeyError) as error:
                invalid.append(str(error))
        incomplete.extend((submission, timestamp, round(duration * 1e9)) for (_, submission), timestamp in open_points.items())
        pair_keys = {(submission, start, end) for _, submission, start, end in pairs}
        for item in parsed["intervals"]:
            if item["pid"] in self.processes and (item["submission_id"], item["start_ns"], item["end_ns"]) not in pair_keys:
                process_issue([item["pid"]], item["start_ns"], item["end_ns"],
                              "An owned GPU interval has no matching complete execution-point pair")
        unattributed_pairs = []
        for key, items in modeled.items():
            if key not in pair_keys and not any(item["pid"] and item["pid"] > 0 for item in items):
                unattributed_pairs.append((key[1], key[2]))
        for _, submission, start, end in pairs:
            if (submission, start, end) in modeled:
                continue
            if owners[submission].intersection(self.processes):
                process_issue(owners[submission], start, end,
                              "An owned raw GPU execution pair is missing its modeled interval")
            if not owners[submission] or 0 in owners[submission]:
                unattributed_pairs.append((start, end))
        for submission, start, end in incomplete:
            if owners[submission].intersection(self.processes):
                process_issue(owners[submission], start, end,
                              "An owned GPU submission has a missing execution boundary")
            if not owners[submission] or 0 in owners[submission]:
                unattributed_pairs.append((start, end))
        # Two different hardware channels with identical submission/time must
        # retain two modeled executions; otherwise the additive total is lost.
        pair_counts = defaultdict(int)
        for _, submission, start, end in pairs:
            pair_counts[(submission, start, end)] += 1
        for key, count in pair_counts.items():
            represented = {(item["gpu"], item["channel"]) for item in modeled[key]}
            if represented and len(represented) != count:
                pids = {item["pid"] for item in modeled[key] if item["pid"]}
                if pids.intersection(self.processes):
                    process_issue(pids, key[1], key[2], "GPU execution channel multiplicity is missing from the modeled intervals")
                else:
                    unattributed_pairs.append((key[1], key[2]))
        return {"invalid": sorted(set(invalid)), "complete_pairs": len(pairs), "unpaired_points": len(incomplete),
                "process_issues": process_issues,
                "completed_submission_ids": sorted({submission for _, submission, _, _ in pairs}),
                "completed_modeled_identities": sorted({(item["pid"], item["submission_id"], item["command_buffer_id"], item["encoder_id"])
                    for item in parsed["intervals"] if item["pid"] in self.processes and
                    (item["submission_id"], item["start_ns"], item["end_ns"]) in pair_keys}),
                "unattributed_pairs": sorted(set(unattributed_pairs)),
                "recording_diagnostics_checked": True,
                "method": "Recording diagnostics plus raw execution-start/end pairing and modeled interval identity cross-check"}
