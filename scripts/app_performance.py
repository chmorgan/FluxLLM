"""Automatic Release-app performance reproduction and fail-closed resource gate.

The 300-second deadline starts after compilation and includes calibration,
four fresh app lifetimes, fixture traffic, chart measurement, and teardown.
"""

import argparse
from collections import deque
from datetime import datetime, timezone
import hashlib
from http.client import HTTPConnection
import json
import math
import os
from pathlib import Path
import platform
import queue
import secrets
import subprocess
import sys
import threading
import tempfile
import time
from urllib.parse import urlparse
import xml.etree.ElementTree as ET
import uuid

from run_performance_checks import InvalidResult, launch_fixture, load_json, number, require, stop_process_group, write_json


ROOT = Path(__file__).resolve().parent.parent
BUDGET_PATH = Path(__file__).with_name("performance_budget.json")
MAX_RECORD_BYTES = 1024 * 1024
MAX_SAMPLE_GAP_SECONDS = 0.75
REQUIRED_COUNTERS = ("cpu_seconds", "physical_write_bytes", "logical_write_bytes", "gpu_seconds")


class Deadline:
    def __init__(self, seconds, clock=time.monotonic, cleanup_reserve=0):
        self.clock = clock
        self.end = clock() + seconds
        self.cleanup_reserve = cleanup_reserve

    def remaining(self, maximum=None):
        remaining = self.end - self.clock() - self.cleanup_reserve
        if remaining <= 0:
            raise TimeoutError("The 300-second performance deadline expired")
        return min(remaining, maximum) if maximum is not None else remaining


def strict_record(raw):
    require(len(raw) <= MAX_RECORD_BYTES, "Collector record exceeds 1 MiB")
    def constant(value):
        raise InvalidResult(f"Invalid JSON number {value}")

    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"Duplicate collector field: {key}")
            result[key] = value
        return result

    try:
        value = json.loads(raw, parse_constant=constant, object_pairs_hook=pairs)
    except (UnicodeError, ValueError) as error:
        raise InvalidResult(f"Malformed collector record: {error}") from error
    require(isinstance(value, dict) and isinstance(value.get("type"), str), "Collector record must have a type")
    return value


def validate_budget(value):
    require(isinstance(value, dict) and type(value.get("schema_version")) is int and value["schema_version"] == 2, "Expected app budget schema_version 2")
    require(type(value.get("workload_version")) is int and value["workload_version"] == 1, "Unsupported app workload version")
    require(value.get("performance_deadline_seconds") == 300, "Performance deadline must be 300 seconds")
    limits = value.get("limits")
    require(isinstance(limits, dict), "Budget must contain limits")
    expected = {"cpu_rolling_1s_percent": 5.0, "lifetime_footprint_bytes": 64000000,
                "physical_write_bytes_logging_off": 0, "logical_write_bytes_logging_off": 0}
    for name, limit in expected.items():
        number(limits.get(name), name)
        require(limits.get(name) == limit, f"The approved {name} limit is {limit}")
    number(limits.get("gpu_percent"), "gpu_percent")
    require(limits.get("gpu_percent") == 1.0, "The approved GPU ceiling is 1% execution/wall time")
    require(value.get("requirements") == {"complete_filesystem_write_coverage": True, "gpu_counter_required": True},
            "GPU and complete filesystem-write coverage are required")
    expected_shapes = (("populated-closed", "populated", "closed", (35, 35, 5)),
                       ("populated-visible", "populated", "visible", (15, 15, 15)),
                       ("fresh-never-opened", "fresh", "never-opened", (10, 10, 10)),
                       ("logging-transitions", "fresh", "never-opened", (10, 10, 10)))
    require(isinstance(value.get("cases"), list) and len(value["cases"]) == 4, "Exactly four fresh-process cases are required")
    for case, shape in zip(value["cases"], expected_shapes):
        require((case.get("name"), case.get("history"), case.get("ui"), tuple(stage.get("seconds") for stage in case.get("stages", []))) == shape,
                "The fixed 180-second workload schedule changed")
    require([stage["activity"] for stage in value["cases"][0]["stages"]] == ["ordinary", "high-rate", "idle"], "Closed-case activity schedule changed")
    require([stage["activity"] for stage in value["cases"][1]["stages"]] == ["ordinary", "high-rate", "idle"], "Visible-case activity schedule changed")
    require(value["cases"][1]["stages"][-1].get("open_close_cycles") == 3, "Three open/close cycles are required")
    require([stage["activity"] for stage in value["cases"][2]["stages"]] == ["idle", "ordinary", "high-rate"], "Never-opened activity schedule changed")
    require([(stage["activity"], stage.get("logging_enabled")) for stage in value["cases"][3]["stages"]] ==
            [("ordinary", False), ("ordinary", True), ("ordinary", False)], "Logging schedule must be off/on/off ordinary traffic")
    return value


def validate_samples(samples):
    problems = []
    if len(samples) < 2:
        return ["Fewer than two resource samples were collected"]
    identity = None
    previous = None
    for sample in samples:
        try:
            number(sample.get("monotonic_seconds"), "sample.monotonic_seconds")
            number(sample.get("physical_footprint_bytes"), "sample.physical_footprint_bytes", integer=True)
            number(sample.get("lifetime_peak_footprint_bytes"), "sample.lifetime_peak_footprint_bytes", minimum=1, integer=True)
            require(sample["lifetime_peak_footprint_bytes"] >= sample["physical_footprint_bytes"], "Lifetime footprint peak is below current footprint")
            current_identity = (sample.get("process_id"), sample.get("birth_time_us"))
            require(all(type(value) is int and value > 0 for value in current_identity), "Sample process identity is missing")
            if identity is None:
                identity = current_identity
            require(identity == current_identity, "Resource samples switched process identity")
            for counter in REQUIRED_COUNTERS:
                value = sample.get(counter)
                if value is not None:
                    number(value, f"sample.{counter}")
                elif counter == "cpu_seconds":
                    raise InvalidResult("CPU accounting is unavailable")
            if previous:
                require(sample["monotonic_seconds"] > previous["monotonic_seconds"], "Sample timestamps are not strictly increasing")
                require(sample["monotonic_seconds"] - previous["monotonic_seconds"] <= MAX_SAMPLE_GAP_SECONDS,
                        "Resource sampling gap exceeds 0.75 seconds; one-second CPU peaks cannot be established")
                for counter in REQUIRED_COUNTERS:
                    old, new = previous.get(counter), sample.get(counter)
                    if old is not None and new is not None:
                        require(new >= old, f"Cumulative {counter} moved backwards")
                require(sample["lifetime_peak_footprint_bytes"] >= previous["lifetime_peak_footprint_bytes"], "Lifetime footprint peak moved backwards")
            previous = sample
        except (InvalidResult, TypeError, KeyError) as error:
            problems.append(str(error))
    return sorted(set(problems))


def rolling_percent(samples, field):
    """Use one-second counter deltas with interpolation at the left boundary."""
    if any(sample.get(field) is None for sample in samples):
        return None
    points = deque()
    maximum = None
    for sample in samples:
        point = (sample["monotonic_seconds"], sample[field])
        points.append(point)
        boundary = point[0] - 1.0
        while len(points) >= 2 and points[1][0] <= boundary:
            points.popleft()
        if points[0][0] > boundary or len(points) < 2:
            continue
        before, after = points[0], points[1]
        fraction = (boundary - before[0]) / (after[0] - before[0])
        start = before[1] + fraction * (after[1] - before[1])
        value = max(0, 100 * (point[1] - start))
        maximum = value if maximum is None else max(maximum, value)
    return maximum


def evaluate_resources(samples, limits, logging_intervals):
    invalid = validate_samples(samples)
    failures = []
    metrics = {}
    if invalid:
        return metrics, failures, invalid
    metrics["cpu_rolling_1s_percent"] = rolling_percent(samples, "cpu_seconds")
    gpu_samples = []
    for sample in samples:
        if sample.get("gpu_sampled", True):
            point = dict(sample)
            point["monotonic_seconds"] = sample.get("gpu_sample_monotonic_seconds", sample["monotonic_seconds"])
            if type(point["monotonic_seconds"]) not in (int, float) or not math.isfinite(point["monotonic_seconds"]):
                invalid.append("GPU sample timestamp is unavailable")
                continue
            if not gpu_samples or point["monotonic_seconds"] > gpu_samples[-1]["monotonic_seconds"]:
                gpu_samples.append(point)
    metrics["gpu_percent"] = rolling_percent(gpu_samples, "gpu_seconds") if gpu_samples else None
    metrics["lifetime_footprint_bytes"] = max(sample["lifetime_peak_footprint_bytes"] for sample in samples)
    if metrics["cpu_rolling_1s_percent"] is None:
        invalid.append("No complete one-second CPU window is available")
    elif metrics["cpu_rolling_1s_percent"] > limits["cpu_rolling_1s_percent"]:
        failures.append(f"Rolling one-second CPU {metrics['cpu_rolling_1s_percent']:.3f}% exceeds 5%")
    if metrics["lifetime_footprint_bytes"] >= limits["lifetime_footprint_bytes"]:
        failures.append(f"Lifetime physical footprint {metrics['lifetime_footprint_bytes']} must be below 64000000 bytes")
    if metrics["gpu_percent"] is None or any(sample.get("gpu_seconds") is None for sample in samples):
        invalid.append("Required attributable GPU accounting is unavailable")
    if limits["gpu_percent"] is None:
        invalid.append("The required GPU ceiling has not been defined")
    elif metrics["gpu_percent"] is not None and metrics["gpu_percent"] > limits["gpu_percent"]:
        failures.append(f"GPU {metrics['gpu_percent']:.3f}% exceeds {limits['gpu_percent']}%")
    if not all(sample.get("trace_coverage") is True for sample in samples):
        invalid.append("Complete filesystem-write trace coverage is unavailable")
    for counter, metric in (("physical_write_bytes", "physical_write_bytes_logging_off"),
                            ("logical_write_bytes", "logical_write_bytes_logging_off")):
        if any(sample.get(counter) is None for sample in samples):
            metrics[metric] = None
            invalid.append(f"Required {counter} accounting is unavailable")
            continue
        total = samples[0][counter]
        for before, after in zip(samples, samples[1:]):
            # Only fully acknowledged on-intervals permit writes. A straddling
            # interval is conservatively off; there are no transition exemptions.
            authorized = any(start <= before["monotonic_seconds"] and after["monotonic_seconds"] <= end
                             for start, end in logging_intervals)
            if not authorized:
                total += after[counter] - before[counter]
        metrics[metric] = total
        if total > limits[metric]:
            failures.append(f"{metric} was {total}, expected zero")
    return metrics, failures, sorted(set(invalid))


def evaluate_file_events(events, logging_intervals, destinations):
    failures, invalid = [], []
    for event in events:
        if event.get("type") != "file_io" or event.get("is_write") is not True:
            continue
        if not logging_intervals:
            failures.append(f"Filesystem write while logging was off: {event.get('operation', 'unknown operation')}")
            continue
        timestamp = event.get("monotonic_seconds")
        path = event.get("path")
        uncertainty = event.get("timestamp_uncertainty_seconds")
        if (event.get("timestamp_attribution") is not True or type(timestamp) not in (int, float)
                or not math.isfinite(timestamp) or not isinstance(path, str)
                or type(uncertainty) not in (int, float) or not math.isfinite(uncertainty) or uncertainty < 0):
            invalid.append("A filesystem write lacks a fully attributed timestamp or destination")
            continue
        authorized = any(start <= timestamp - uncertainty and timestamp + uncertainty <= end for start, end in logging_intervals) and path in destinations
        if not authorized:
            failures.append(f"Filesystem write outside an authorized logging destination/interval: {path}")
    return sorted(set(failures)), sorted(set(invalid))


def expected_work(stage):
    if stage["activity"] == "idle":
        return {"requests": 0, "chunks": 0, "output_tokens": 0, "prompt_tokens": 0, "tool_calls": 0, "tool_results": 0}
    chunks = math.floor(stage["seconds"] * (40 if stage["activity"] == "ordinary" else 200))
    return {"requests": 2, "chunks": chunks * 2, "output_tokens": (chunks * 2 + 17) * 2,
            "prompt_tokens": 46, "tool_calls": 2, "tool_results": 2}


def validate_fixture_start(stage, acknowledgement):
    expected = expected_work(stage)
    require(acknowledgement.get("running") is True and isinstance(acknowledgement.get("run_id"), str)
            and acknowledgement["run_id"], "Fixture did not acknowledge a running workload")
    for field, key in (("expected_requests", "requests"), ("expected_chunks", "chunks"),
                       ("expected_output_tokens", "output_tokens"), ("expected_prompt_tokens", "prompt_tokens")):
        require(type(acknowledgement.get(field)) is int and acknowledgement[field] == expected[key],
                f"Fixture acknowledgement {field} differs from the fixed workload")


def validate_workload(stage, status, before, after):
    expected = expected_work(stage)
    require(isinstance(before, dict) and isinstance(after, dict), "App snapshots are required")
    if stage["activity"] != "idle":
        require(status.get("running") is False and status.get("error") is None, "Synthetic network workload did not complete cleanly")
        require(status.get("forwarding_verified") is True, "Exact incremental forwarding was not verified")
        for field, expected_field in (("completed_requests", "requests"), ("received_chunks", "chunks"),
                                      ("tool_calls", "tool_calls"), ("tool_results", "tool_results")):
            require(type(status.get(field)) is int and status[field] == expected[expected_field], f"Fixture {field} differs from expected work")
    for field in ("requests", "output_tokens", "prompt_tokens", "tool_calls", "tool_results"):
        require(type(before.get(field)) is int and type(after.get(field)) is int, f"App snapshot {field} is missing")
        require(after[field] - before[field] == expected[field], f"App {field} delta differs from expected work")
    return expected


def presentation_checks(before, after, specification, stage):
    failures, invalid = [], []
    expected_visible = specification["ui"] == "visible" and not stage.get("open_close_cycles")
    for field in ("dashboard_visible", "popover_visible"):
        if after.get(field) is not expected_visible:
            invalid.append(f"Native {field} does not match the requested UI lifecycle")
    for field in ("status_updates", "chart_preparations", "canvas_draws"):
        if type(before.get(field)) is not int or type(after.get(field)) is not int or after[field] < before[field]:
            invalid.append(f"Presentation counter {field} is unavailable or moved backwards")
            continue
        delta = after[field] - before[field]
        if field == "status_updates" and stage["activity"] != "idle" and delta == 0:
            invalid.append("Menu-bar status did not update during generation")
        if field in ("chart_preparations", "canvas_draws"):
            if specification["ui"] == "visible" and delta == 0:
                invalid.append(f"Visible {field} did not advance")
            elif specification["ui"] != "visible" and delta > 0:
                failures.append(f"Hidden {field} increased by {delta}")
    if expected_visible and before.get("chart_publication_id") == after.get("chart_publication_id"):
        invalid.append("Visible chart publications stopped advancing")
    return failures, invalid


class Collector:
    def __init__(self, executable, app, configuration, gpu_capability, directory, deadline):
        self.deadline = deadline
        self.executable = executable
        self.directory = directory
        self.samples = []
        self.events = []
        self.incoming = queue.Queue()
        self.next_id = 0
        self.exited = False
        self.app_pid = None
        self.app_birth_time_us = None
        self.cleanup_errors = []
        storage_root = Path(tempfile.mkdtemp(prefix="fluxllm-performance-"))
        run_id = str(uuid.uuid4()).upper()
        run_directory = storage_root / run_id
        run_directory.mkdir()
        self.storage = {"root": str(storage_root), "run_id": run_id}
        write_json(directory / "storage.json", self.storage)
        self.raw = (directory / "collector.jsonl").open("wb")
        self.stderr = (directory / "collector-stderr.log").open("wb")
        environment = os.environ.copy()
        environment["FLUXLLM_PERFORMANCE_CONFIGURATION"] = json.dumps(configuration, separators=(",", ":"))
        environment["FLUXLLM_PERFORMANCE_GPU_CAPABILITY_JSON"] = json.dumps(gpu_capability, separators=(",", ":"))
        environment["FLUXLLM_PERFORMANCE_STORAGE_ROOT"] = str(storage_root)
        environment["FLUXLLM_PERFORMANCE_RUN_ID"] = run_id
        self.process = subprocess.Popen([str(executable), "--app", str(app), "--deadline", str(math.ceil(deadline.remaining()))],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                        env=environment, cwd=directory, start_new_session=True)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            while True:
                line = self.process.stdout.readline(MAX_RECORD_BYTES + 1)
                if not line:
                    break
                self.raw.write(line)
                self.raw.flush()
                self.incoming.put(strict_record(line))
        except BaseException as error:
            self.incoming.put(error)
        finally:
            self.incoming.put(None)

    def receive(self, maximum=0.25, cleanup=False):
        timeout = (min(maximum, self.deadline.end - time.monotonic()) if cleanup
                   else self.deadline.remaining(maximum))
        if timeout <= 0:
            raise TimeoutError("The hard performance deadline expired during process cleanup")
        try:
            event = self.incoming.get(timeout=timeout)
        except queue.Empty:
            return None
        if isinstance(event, BaseException):
            raise event
        if event is None:
            if not self.exited:
                raise InvalidResult("Collector stream ended without an exited record")
            return None
        self.events.append(event)
        if event["type"] == "sample":
            self.samples.append(event)
        elif event["type"] == "launched":
            self.app_pid = event.get("pid")
            self.app_birth_time_us = event.get("birth_time_us")
        elif event["type"] == "exited":
            self.exited = True
            final = event.get("final_sample")
            if isinstance(final, dict) and (not self.samples or final.get("monotonic_seconds") != self.samples[-1].get("monotonic_seconds")):
                self.samples.append(final)
        elif event["type"] == "error":
            raise InvalidResult(event.get("message", "Collector reported an error"))
        return event

    def command(self, name, timeout=10, **fields):
        self.next_id += 1
        identifier = f"runner-{self.next_id}"
        payload = {"command": name, "command_id": identifier, **fields}
        self.process.stdin.write(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
        self.process.stdin.flush()
        limit = min(self.deadline.end, time.monotonic() + timeout)
        while time.monotonic() < limit:
            event = self.receive(min(0.25, max(0.001, limit - time.monotonic())))
            if event and event["type"] == "app_event":
                response = event.get("event", {})
                if response.get("command_id") == identifier:
                    require(response.get("type") != "error", f"App command {name} failed: {response}")
                    boundaries = [sample["monotonic_seconds"] for sample in self.samples if sample.get("command_id") == identifier]
                    if len(boundaries) >= 2:
                        response["collector_control_before_seconds"] = boundaries[0]
                        response["collector_control_after_seconds"] = boundaries[-1]
                    return response
            require(not self.exited, f"App exited while waiting for {name}")
        raise TimeoutError(f"App did not acknowledge {name} within {timeout} seconds")

    def ready(self):
        end = min(self.deadline.end, time.monotonic() + 20)
        while time.monotonic() < end:
            event = self.receive()
            if event and event["type"] == "app_event" and event.get("event", {}).get("type") == "ready":
                return event["event"]
            require(not self.exited, "App exited before its control handshake")
        raise TimeoutError("App did not complete its control handshake within 20 seconds")

    def wait_until(self, end):
        while time.monotonic() < end:
            self.receive(min(0.25, max(0.001, end - time.monotonic())))
            require(not self.exited, "App exited during the workload")

    def snapshot(self):
        response = self.command("snapshot")
        snapshot = response.get("snapshot")
        require(isinstance(snapshot, dict), "Snapshot response did not contain counters")
        return snapshot

    def finish(self):
        if self.process.poll() is None and not self.exited:
            self.command("shutdown", timeout=5)
            end = min(self.deadline.end, time.monotonic() + 5)
            while not self.exited and time.monotonic() < end:
                self.receive()
        require(self.exited, "No final exited record was collected")
        exit_events = [event for event in self.events if event["type"] == "exited"]
        require(exit_events[-1].get("status") == 0, f"App did not exit cleanly: {exit_events[-1].get('status')}")

    def close(self):
        remaining = max(0, self.deadline.end - time.monotonic())
        if not self.exited and type(self.app_pid) is int and type(self.app_birth_time_us) is int:
            try:
                result = subprocess.run([str(self.executable), "--terminate-owned", str(self.app_pid),
                                         "--birth-time-us", str(self.app_birth_time_us)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                        timeout=max(0.01, min(2, remaining)), check=False)
                if result.returncode != 0:
                    self.cleanup_errors.append("Identity-verified app process-group cleanup failed")
            except (OSError, subprocess.SubprocessError) as error:
                self.cleanup_errors.append(f"Identity-verified app cleanup could not finish: {error}")
        # The collector reads the zombie's final accounting, then drains trace
        # events for one second. Keep reading while it completes that protocol,
        # including when the reader already queued records before process exit.
        drain_end = min(self.deadline.end - 0.05, time.monotonic() + 1.75)
        while not self.exited and time.monotonic() < drain_end:
            if self.process.poll() is not None and self.incoming.empty():
                break
            try:
                self.receive(min(0.25, max(0.001, drain_end - time.monotonic())), cleanup=True)
            except (OSError, ValueError, TimeoutError) as error:
                self.cleanup_errors.append(f"Final collector drain failed: {error}")
                if self.process.poll() is not None and self.incoming.empty():
                    break
        if not self.exited:
            self.cleanup_errors.append("Collector final exit/trace record was unavailable after bounded cleanup")
        stop_process_group(self.process, grace=min(0.5, max(0, self.deadline.end - time.monotonic())))
        if self.process.stdin:
            self.process.stdin.close()
        self.reader.join(timeout=min(1, max(0, self.deadline.end - time.monotonic())))
        while not self.incoming.empty():
            try:
                self.receive(0.001, cleanup=True)
            except (OSError, ValueError, TimeoutError) as error:
                self.cleanup_errors.append(f"Final queued collector record could not be applied: {error}")
                if time.monotonic() >= self.deadline.end:
                    break
        if self.process.stdout:
            self.process.stdout.close()
        self.raw.close()
        self.stderr.close()


def fixture_request(base_url, endpoint, deadline, body=None):
    url = urlparse(base_url)
    require(url.scheme == "http" and url.hostname == "127.0.0.1" and url.port, "Fixture must use numeric IPv4 loopback")
    connection = HTTPConnection(url.hostname, url.port, timeout=deadline.remaining(5))
    try:
        payload = None if body is None else json.dumps(body)
        connection.request("GET" if body is None else "POST", endpoint, payload,
                           {} if body is None else {"Content-Type": "application/json"})
        response = connection.getresponse()
        data = response.read(MAX_RECORD_BYTES + 1)
        expected_status = 202 if endpoint == "/control/start" else 200
        require(response.status == expected_status and len(data) <= MAX_RECORD_BYTES, f"Fixture {endpoint} failed with HTTP {response.status}")
        value = json.loads(data)
        require(isinstance(value, dict), "Fixture response must be an object")
        return value
    finally:
        connection.close()


def visible(collector, show, invalid=None):
    visibility_errors = {"show_dashboard": "Dashboard did not become visible",
                         "show_popover": "Popover did not become visible",
                         "close_dashboard": "Dashboard did not close",
                         "close_popover": "Popover did not close"}
    for command in (("show_dashboard", "show_popover") if show else ("close_popover", "close_dashboard")):
        response = collector.command(command)
        if (invalid is not None and response.get("status") == "error" and response.get("command") == command
                and response.get("reason") == visibility_errors[command]):
            invalid.append(f"UI lifecycle coverage is incomplete: {response['reason']}")
            continue
        require(response.get("status", "ok") == "ok", f"UI command {command} was not applied")


def validated_logging_destinations(response, storage):
    run_directory = Path(storage["root"]).resolve() / storage["run_id"]
    directory = run_directory / "Diagnostics"
    expected = {str(directory), *(str(directory / name) for name in
                                 ("diagnostics.jsonl", "diagnostics.1.jsonl", "diagnostics.2.jsonl"))}
    destinations = response.get("logging_destinations")
    require(isinstance(destinations, list) and len(destinations) == 4
            and all(isinstance(path, str) and Path(path).is_absolute() for path in destinations),
            "Logging enable did not identify all four exact owned destinations")
    canonical = {str(Path(path).resolve()) for path in destinations}
    require(canonical == expected, "Logging destinations escape the fixed owned Diagnostics paths")
    primary = response.get("logging_destination")
    require(isinstance(primary, str) and Path(primary).is_absolute()
            and str(Path(primary).resolve()) == str(directory / "diagnostics.jsonl"),
            "The primary logging destination is not the owned diagnostics.jsonl file")
    return sorted(expected)


def set_logging(collector, enabled, case, open_interval):
    response = collector.command("set_logging", enabled=enabled)
    # A trustworthy boundary comes from collector accounting, not wall-clock
    # receipt time or a guessed grace period for delayed file writes.
    boundary = response.get("collector_control_before_seconds" if enabled else "collector_control_after_seconds")
    accepted = (response.get("status") == "ok" and response.get("logging_enabled") is enabled
                and (enabled or response.get("drained") is True) and type(boundary) in (int, float))
    case["logging_transitions"].append(response)
    if not accepted:
        case["invalid"].append(f"Logging {'enable' if enabled else 'disable/drain'} was not verified: {response.get('reason', response.get('status'))}")
        return open_interval
    if enabled:
        try:
            destinations = validated_logging_destinations(response, collector.storage)
        except (OSError, ValueError, KeyError) as error:
            case["invalid"].append(str(error))
            return open_interval
        case["logging_destinations"] = destinations
        return boundary
    if open_interval is not None:
        case["logging_intervals"].append((open_interval, boundary))
    return None


def completed_status(collector, upstream, deadline):
    completion_deadline = min(deadline.end, time.monotonic() + 5)
    while True:
        status = fixture_request(upstream, "/control/status", deadline)
        if not status.get("running"):
            return status
        require(time.monotonic() < completion_deadline, "Synthetic stream did not finish on schedule")
        collector.wait_until(min(completion_deadline, time.monotonic() + 0.1))


def run_continuous_logging(collector, specification, case, proxy_url, upstream, deadline, cycle):
    whole = {"activity": "ordinary", "seconds": 30}
    initial = collector.snapshot()
    started = time.monotonic()
    acknowledgement = fixture_request(upstream, "/control/start", deadline, {
        "proxy_url": proxy_url, "duration_seconds": 30, "rate_hz": 40, "concurrency": 2, "cycle": cycle})
    case["continuous_fixture_start"] = acknowledgement
    validate_fixture_start(whole, acknowledgement)
    open_interval = None
    for index, stage in enumerate(specification["stages"]):
        if index:
            open_interval = set_logging(collector, stage["logging_enabled"], case, open_interval)
        before = collector.snapshot()
        stage_result = {"specification": stage, "before": before, "continuous_stream": True}
        case["stages"].append(stage_result)
        collector.wait_until(started + index * 10 + 2)
        progress = collector.snapshot()
        require(progress.get("active_requests", 0) > 0 and progress.get("partial_output_tokens", 0) > before.get("partial_output_tokens", 0),
                "Continuous streaming telemetry stopped during the logging transition")
        stage_result["live_progress"] = progress
        collector.wait_until(started + (index + 1) * 10)
        if index < 2:
            after = collector.snapshot()
            require(after.get("active_requests", 0) > 0, "Logging transition interrupted the active streams")
            stage_result.update(after=after, validated_work={"live_progress_verified": True})
        else:
            status = completed_status(collector, upstream, deadline)
            after = collector.snapshot()
            stage_result.update(after=after, fixture_status=status)
            stage_result["validated_work"] = validate_workload(whole, status, initial, after)
        failures, invalid = presentation_checks(before, after, specification, stage)
        case["failures"].extend(failures)
        case["invalid"].extend(invalid)
    require(open_interval is None, "Logging was not acknowledged off and drained before the final interval")


def run_case(specification, collector_path, app_path, upstream, gpu_capability, directory, deadline, limits, cycle_start):
    directory.mkdir()
    case = {"name": specification["name"], "specification": specification, "stages": [],
            "logging_transitions": [], "logging_intervals": [], "logging_destinations": [], "failures": [], "invalid": []}
    configuration = {"upstream_url": upstream, "history": specification["history"], "protocol_version": 1,
                     "logging_enabled": False}
    write_json(directory / "configuration.json", configuration)
    collector = None
    open_interval = None
    try:
        collector = Collector(collector_path, app_path, configuration, gpu_capability, directory, deadline)
        ready = collector.ready()
        require(ready.get("type") == "ready" and ready.get("protocol_version") == 1, "App control handshake is incompatible")
        require(isinstance(ready.get("snapshot"), dict), "Ready event is missing the seeded counter baseline")
        proxy_url = ready.get("proxy_url")
        parsed = urlparse(proxy_url or "")
        require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port, "App proxy is not on numeric loopback")
        case["ready"] = ready
        seed = ready["snapshot"]
        require(seed.get("history_verified") is True and seed.get("history") == specification["history"],
                "The requested retained-history fixture was not verified")
        if specification["history"] == "populated":
            require((seed.get("seed_persistent_requests"), seed.get("seed_raw_requests"), seed.get("seed_tool_events")) == (19000, 256, 38512),
                    "Populated retained-history dimensions changed")
        open_interval = set_logging(collector, False, case, open_interval)
        if specification["ui"] in ("closed", "visible"):
            visible(collector, True, case["invalid"])
            if specification["ui"] == "closed":
                visible(collector, False, case["invalid"])
        if specification["name"] == "logging-transitions":
            run_continuous_logging(collector, specification, case, proxy_url, upstream, deadline, cycle_start)
        for stage_index, stage in enumerate([] if specification["name"] == "logging-transitions" else specification["stages"]):
            if "logging_enabled" in stage:
                open_interval = set_logging(collector, stage["logging_enabled"], case, open_interval)
            before = collector.snapshot()
            stage_result = {"specification": stage, "before": before}
            case["stages"].append(stage_result)
            started = time.monotonic()
            stage_end = started + stage["seconds"]
            if stage["activity"] != "idle":
                acknowledgement = fixture_request(upstream, "/control/start", deadline, {
                    "proxy_url": proxy_url, "duration_seconds": stage["seconds"],
                    "rate_hz": 40 if stage["activity"] == "ordinary" else 200,
                    "concurrency": 2, "cycle": cycle_start + stage_index})
                stage_result["fixture_start"] = acknowledgement
                validate_fixture_start(stage, acknowledgement)
                collector.wait_until(started + min(2, stage["seconds"] / 2))
                progress = collector.snapshot()
                stage_result["live_progress"] = progress
                require(progress.get("active_requests", 0) > 0 and progress.get("partial_output_tokens", 0) > 0,
                        "Live telemetry did not advance while network streams were active")
            if stage.get("open_close_cycles"):
                for cycle in range(stage["open_close_cycles"]):
                    visible(collector, True, case["invalid"])
                    collector.wait_until(started + (cycle + 0.5) * stage["seconds"] / stage["open_close_cycles"])
                    visible(collector, False, case["invalid"])
                    collector.wait_until(started + (cycle + 1) * stage["seconds"] / stage["open_close_cycles"])
            else:
                collector.wait_until(stage_end)
            status = {}
            if stage["activity"] != "idle":
                status = completed_status(collector, upstream, deadline)
            after = collector.snapshot()
            stage_result.update(after=after, fixture_status=status, elapsed_seconds=time.monotonic() - started)
            stage_result["validated_work"] = validate_workload(stage, status, before, after)
            failures, invalid = presentation_checks(before, after, specification, stage)
            case["failures"].extend(failures)
            case["invalid"].extend(invalid)
        if open_interval is not None:
            open_interval = set_logging(collector, False, case, open_interval)
        collector.finish()
    except (OSError, ValueError, TimeoutError) as error:
        case["invalid"].append(str(error))
    finally:
        if collector:
            try:
                collector.close()
            except OSError as error:
                case["invalid"].append(f"Process cleanup failed: {error}")
            case["samples"] = collector.samples
            case["events"] = collector.events
            case["storage"] = collector.storage
            case["invalid"].extend(collector.cleanup_errors)
            launched = next((event for event in collector.events if event["type"] == "launched"), {})
            case["environment"] = launched.get("environment", {})
            exits = [event for event in collector.events if event["type"] == "exited"]
            stopped = [event.get("event", {}) for event in collector.events
                       if event["type"] == "app_event" and event.get("event", {}).get("type") == "stopped"]
            if not stopped or stopped[-1].get("status") != "ok":
                case["invalid"].append("App shutdown/drain barrier did not complete successfully"
                                       + (f": {stopped[-1].get('error', 'unspecified error')}" if stopped else ""))
            if exits and exits[-1].get("status") != 0:
                case["invalid"].append(f"App terminated with exit status {exits[-1].get('status')}")
            if not exits or exits[-1].get("trace_coverage") is not True:
                case["invalid"].append("Final filesystem-write trace coverage was not complete through exit and drain")
            if exits and "gpu_final_self_sample_received" in exits[-1]:
                if exits[-1].get("gpu_final_self_sample_received") is not True:
                    case["invalid"].append("The final attributed GPU self-sample was not received")
                if exits[-1].get("gpu_exit_tail_measured") is not True:
                    case["invalid"].append("GPU activity between the final self-sample and actual process exit is unmeasured")
            metrics, failures, invalid = evaluate_resources(collector.samples, limits, case["logging_intervals"])
            case["metrics"] = metrics
            case["failures"].extend(failures)
            case["invalid"].extend(invalid)
            failures, invalid = evaluate_file_events(collector.events, case["logging_intervals"], case["logging_destinations"])
            case["failures"].extend(failures)
            case["invalid"].extend(invalid)
        else:
            case["samples"] = []
            case["metrics"] = {}
        if len(case["stages"]) != len(specification["stages"]) or any("validated_work" not in stage for stage in case["stages"]):
            case["invalid"].append("The complete fixed workload was not validated")
        case["invalid"] = sorted(set(case["invalid"]))
        write_json(directory / "result.json", case)
    return case


def execute_logged(command, output, timeout, environment=None):
    started = time.monotonic()
    with output.open("wb") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            exit_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            exit_code = None
        finally:
            stop_process_group(process, grace=0)
    return {"command": command, "exit_code": exit_code, "elapsed_seconds": time.monotonic() - started,
            "log": str(output)}


def path_hash(path):
    digest = hashlib.sha256()
    if path.is_file():
        digest.update(path.read_bytes())
    else:
        for child in sorted(path.rglob("*")):
            if child.is_file():
                digest.update(str(child.relative_to(path)).encode())
                digest.update(b"\0")
                digest.update(child.read_bytes())
                digest.update(b"\0")
    return digest.hexdigest()


def measurement_identity():
    sources = {Path(__file__), Path(__file__).with_name("run_performance_checks.py"),
               Path(__file__).with_name("performance_fixture.py"), BUDGET_PATH,
               ROOT / "Tests/FluxLLMTests/ChartPreparationPerformanceTests.swift",
               ROOT / "Tests/FluxLLMTests/Fixtures/ChartPerformanceFixture.swift"}
    sources.update(ROOT.glob("Sources/FluxLLMResourceCollector/**/*.swift"))
    sources.update(ROOT.glob("Sources/FluxLLM/Performance/**/*.swift"))
    sources.update(ROOT.glob("Sources/FluxLLMApp/*Performance*.swift"))
    sources = sorted(path for path in sources if path.is_file())
    manifest = {str(path.relative_to(ROOT)): path_hash(path) for path in sources}
    digest = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"sha256": digest, "sources": manifest}


def build_products(output, timeout):
    build = execute_logged(["swift", "build", "-c", "release", "--build-tests", "-Xswiftc", "-enable-testing"],
                           output / "build.log", timeout)
    write_json(output / "build.json", build)
    require(build["exit_code"] == 0, "Release build failed; see build.log")
    located = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT,
                             capture_output=True, text=True, timeout=30, check=False)
    require(located.returncode == 0, f"Could not locate newly built Release products: {located.stderr.strip()}")
    directory = Path(located.stdout.strip()).resolve()
    paths = {"app": directory / "FluxLLMApp", "collector": directory / "FluxLLMResourceCollector",
             "tests": directory / "FluxLLMPackageTests.xctest"}
    for kind, path in paths.items():
        require(path.exists(), f"The successful build did not produce {kind}: {path}")
    hashes = {kind: {"path": str(path), "sha256": path_hash(path)} for kind, path in paths.items()}
    return paths, hashes, build


def preflight(collector, directory, deadline, timeout=25):
    def capture(arguments, name, timeout):
        command = [str(collector), *arguments]
        stdout_path, stderr_path = directory / f"{name}.jsonl", directory / f"{name}-stderr.log"
        started = time.monotonic()
        timed_out = False
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            process = subprocess.Popen(command, cwd=ROOT, stdout=stdout, stderr=stderr, start_new_session=True)
            try:
                exit_code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out, exit_code = True, None
            finally:
                stop_process_group(process, grace=0)
        execution = {"command": command, "exit_code": exit_code, "timed_out": timed_out,
                     "timeout_seconds": timeout, "elapsed_seconds": time.monotonic() - started,
                     "stdout": str(stdout_path), "stderr": str(stderr_path),
                     "stdout_bytes": stdout_path.stat().st_size, "stderr_bytes": stderr_path.stat().st_size}
        write_json(directory / f"{name}-execution.json", execution)
        records, errors = [], []
        for line in stdout_path.read_bytes().splitlines():
            if line.strip():
                try:
                    records.append(strict_record(line))
                except InvalidResult as error:
                    errors.append(str(error))
        if timed_out:
            errors.append(f"Collector {name} timed out after {timeout:g} seconds; stdout and stderr were preserved separately")
        elif exit_code != 0:
            errors.append(f"Collector {name} exited with status {exit_code}; see {stderr_path.name}")
        return execution, records, errors

    run, records, errors = capture(["--preflight"], "preflight", deadline.remaining(timeout))
    capabilities = next((record for record in records if record["type"] == "capabilities"), None)
    result = {"execution": run, "records": records, "invalid": errors}
    if capabilities is None:
        errors.append("Collector preflight did not describe its capabilities; continuing with explicitly uncalibrated diagnostics")
        fallback, fallback_records, fallback_errors = capture(["--self-test"], "preflight-self-test", deadline.remaining(5))
        result["fallback"] = {"execution": fallback, "records": fallback_records}
        errors.extend(fallback_errors)
        proof = next((record for record in fallback_records if record.get("type") == "self_test" and record.get("passed") is True), {})
        reason = "Full automatic preflight did not complete"
        capabilities = {"type": "capabilities", "environment": {},
                        **{field: {"available": False, "reason": reason}
                           for field in ("cpu", "physical_footprint", "physical_writes", "logical_writes", "trace_coverage")},
                        "gpu": {"available": False, "provider": "uncalibrated", "reason": reason, "calibration": None}}
        if proof.get("cpu", {}).get("available") is True:
            capabilities["cpu"] = proof["cpu"]
    result["capabilities"] = capabilities
    write_json(directory / "preflight.json", result)
    return result


def run_chart(tests, directory, deadline):
    environment = os.environ.copy()
    path = directory / "chart.json"
    environment.update(FLUXLLM_PERF_CHART="1", FLUXLLM_PERF_CHART_RESULT=str(path))
    result = execute_logged(["xcrun", "xctest", "-XCTest",
                             "FluxLLMTests.ChartPreparationPerformanceTests/testFreshChartPublicationsReportCPUAndWallCost", str(tests)],
                            directory / "chart.log", deadline.remaining(), environment)
    measured = {"execution": result, "failures": [], "invalid": []}
    if result["exit_code"] is None:
        measured["invalid"].append("Release chart reproduction timed out; see chart.log")
    elif result["exit_code"] != 0:
        measured["failures"].append(f"Release chart reproduction failed with exit status {result['exit_code']}; see chart.log")
    try:
        report = load_json(path)
        measured["result"] = report
        # Preserve emitted measurements even when XCTest subsequently reports
        # a budget assertion failure. An empty/skipped run still cannot pass.
        require(isinstance(report, dict) and report.get("configuration") == "release", "Chart measurement did not report a Release result")
        require(report.get("equivalentOutputs") is True and isinstance(report.get("cases"), list) and len(report["cases"]) == 6,
                "Chart measurement did not validate all six paired cases")
    except (OSError, ValueError) as error:
        measured["invalid"].append(f"Chart result is incomplete: {error}")
    return measured


def comparison_key(report):
    capabilities = report.get("preflight", {}).get("capabilities", {})
    environment = report.get("environment") or capabilities.get("environment")
    if (not isinstance(environment, dict) or environment.get("display_available") == "false"
            or any(not environment.get(field) for field in ("os", "hardware", "display", "build_configuration"))):
        return None
    provider_fields = ("provider", "method", "counter", "counter_key", "api", "schema_version", "available", "validated")
    providers = {kind: {field: capability[field] for field in provider_fields if field in capability}
                 for kind, capability in capabilities.items() if isinstance(capability, dict) and kind != "environment"}
    return {"measurement_sha256": report["measurement_identity"]["sha256"], "environment": environment,
            "providers": providers, "limits": report["budget"]["limits"]}


def compare_baseline(report, parent):
    key = comparison_key(report)
    if key is None:
        return {"status": "unavailable", "reason": "Measurement environment is incomplete"}
    for path in sorted(parent.glob("baseline-*/report.json"), reverse=True):
        try:
            baseline = load_json(path)
            if path.parent == Path(report["artifact_directory"]) or baseline.get("mode") != "baseline" or comparison_key(baseline) != key:
                continue
            if len(baseline.get("cases", [])) != 4:
                continue
            changes = {}
            for current, earlier in zip(report["cases"], baseline["cases"]):
                require(current["name"] == earlier["name"], "Baseline case order differs")
                changes[current["name"]] = {metric: value - earlier["metrics"][metric]
                                             for metric, value in current.get("metrics", {}).items()
                                             if type(value) in (int, float) and type(earlier.get("metrics", {}).get(metric)) in (int, float)}
            return {"status": "compared", "baseline": str(path), "metric_deltas": changes,
                    "note": "Baseline comparison is diagnostic; frozen absolute limits still decide the gate."}
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return {"status": "unavailable", "reason": "No prior baseline matches workload, providers, hardware, OS, and display"}


def write_junit(report, path):
    checks = [("runner", report.get("failures", []), report.get("invalid", []))]
    checks.extend((case["name"], case.get("failures", []), case.get("invalid", [])) for case in report.get("cases", []))
    if report["mode"] == "baseline":
        checks.append(("baseline-is-not-a-pass", [], ["Baseline records measurements without granting a regression pass"]))
    suite = ET.Element("testsuite", name="FluxLLM resource regression", tests=str(len(checks)),
                       failures=str(sum(bool(failures) for _, failures, _ in checks)),
                       errors=str(sum(bool(invalid) for _, _, invalid in checks)))
    for name, failures, invalid in checks:
        case = ET.SubElement(suite, "testcase", name=name, classname="FluxLLM.Performance")
        if failures:
            ET.SubElement(case, "failure", message="Resource budget exceeded").text = "\n".join(failures)
        if invalid:
            ET.SubElement(case, "error", message="Required evidence is incomplete").text = "\n".join(invalid)
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def freeze_artifacts(directory):
    for path in directory.rglob("*"):
        if path.is_file():
            path.chmod(0o444)
    for path in sorted((path for path in directory.rglob("*") if path.is_dir()), reverse=True):
        path.chmod(0o555)
    directory.chmod(0o555)


def run(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("check", "baseline"))
    parser.add_argument("--output-dir", type=Path, help="New artifact directory; defaults to a unique untracked .performance-results directory")
    parser.add_argument("--budget", type=Path, default=BUDGET_PATH)
    parser.add_argument("--build-timeout", type=float, default=900, help="Release build limit, separate from the fixed 300-second performance deadline")
    args = parser.parse_args(argv)
    report = {"schema_version": 2, "mode": args.mode, "status": "running", "regression_passed": False,
              "created_at": datetime.now(timezone.utc).isoformat(), "cases": [], "failures": [], "invalid": []}
    output = None
    fixture = None
    deadline = None
    try:
        number(args.build_timeout, "--build-timeout", minimum=1, maximum=3600)
        report["budget"] = validate_budget(load_json(args.budget))
        suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + "-" + secrets.token_hex(3)
        output = args.output_dir.expanduser().resolve() if args.output_dir else ROOT / ".performance-results" / f"{args.mode}-{suffix}"
        require(not output.exists(), "Artifact directory already exists; evidence is never overwritten")
        output.mkdir(parents=True)
        report["artifact_directory"] = str(output)
        report["measurement_identity"] = measurement_identity()
        print(f"Artifacts: {output}\nBuilding the Release app, collector, and tests…", flush=True)
        paths, hashes, build = build_products(output, args.build_timeout)
        report.update(binary_identity=hashes, build=build)
        require(measurement_identity() == report["measurement_identity"], "Measurement sources changed during the Release build")
        require(platform.system() == "Darwin", "Actual-app resource measurement requires macOS")
        started = time.monotonic()
        deadline = Deadline(300, cleanup_reserve=3)
        print("Starting the 300-second performance stage (180 seconds of scheduled workloads).", flush=True)
        report["preflight"] = preflight(paths["collector"], output, deadline)
        report["invalid"].extend(report["preflight"].get("invalid", []))
        if report["preflight"]["execution"]["exit_code"] != 0:
            report["invalid"].append("Collector preflight did not exit successfully")
        capabilities = report["preflight"]["capabilities"]
        environment = capabilities.get("environment", {})
        if environment.get("build_configuration") != "release":
            report["invalid"].append("Collector did not identify a Release environment")
        for field in ("cpu", "physical_footprint", "physical_writes", "logical_writes", "gpu", "trace_coverage"):
            if capabilities.get(field, {}).get("available") is not True:
                report["invalid"].append(f"Required {field} capability is unavailable: {capabilities.get(field, {}).get('reason', 'unspecified')}")
        fixture, upstream = launch_fixture(output, timeout=deadline.remaining(10))
        for index, case in enumerate(report["budget"]["cases"]):
            deadline.remaining()
            print(f"Measuring {case['name']}…", flush=True)
            measured = run_case(case, paths["collector"], paths["app"], upstream, capabilities.get("gpu", {}),
                                output / case["name"], deadline, report["budget"]["limits"], index * 10)
            report["cases"].append(measured)
            case_environment = measured.get("environment")
            if case_environment:
                if report.get("environment") is None:
                    report["environment"] = case_environment
                elif report["environment"] != case_environment:
                    report["invalid"].append("The actual app measurement environment changed between fresh processes")
                if environment and environment != case_environment:
                    report["invalid"].append("The actual app environment differs from preflight")
            metrics = measured.get("metrics", {})
            print(f"  CPU={metrics.get('cpu_rolling_1s_percent', 'unavailable')}% "
                  f"GPU={metrics.get('gpu_percent', 'unavailable')}% "
                  f"peak={metrics.get('lifetime_footprint_bytes', 'unavailable')} bytes; "
                  f"{len(measured['failures'])} failures, {len(measured['invalid'])} incomplete checks", flush=True)
            write_json(output / "report.json", report)
        print("Measuring fresh chart publications within the remaining deadline…", flush=True)
        report["chart"] = run_chart(paths["tests"], output, deadline)
        report["failures"].extend(report["chart"].get("failures", []))
        report["invalid"].extend(report["chart"].get("invalid", []))
        require(measurement_identity() == report["measurement_identity"], "Measurement sources changed during the performance stage")
        report["performance_elapsed_seconds"] = time.monotonic() - started
        deadline.remaining()
    except (OSError, ValueError, subprocess.SubprocessError, TimeoutError, KeyboardInterrupt) as error:
        report["invalid"].append(str(error) or "Interrupted")
    finally:
        if fixture:
            try:
                stop_process_group(fixture, grace=0)
            except OSError as error:
                report["invalid"].append(f"Fixture cleanup failed: {error}")
        if deadline:
            report["performance_elapsed_seconds"] = time.monotonic() - (deadline.end - 300)
            if report["performance_elapsed_seconds"] > 300:
                report["invalid"].append("The performance stage exceeded its hard 300-second deadline")
        if len(report["cases"]) != 4:
            report["invalid"].append("All four fresh-process cases were not completed")
        failures = bool(report["failures"] or any(case.get("failures") for case in report["cases"]))
        invalid = bool(report["invalid"] or any(case.get("invalid") for case in report["cases"]))
        report["status"] = "incomplete" if invalid else ("failed" if failures else ("baseline_recorded" if args.mode == "baseline" else "passed"))
        report["regression_passed"] = args.mode == "check" and not failures and not invalid
        if output:
            report["comparison"] = compare_baseline(report, output.parent) if "budget" in report and "measurement_identity" in report else {"status": "unavailable"}
            write_json(output / "report.json", report)
            write_junit(report, output / "junit.xml")
            freeze_artifacts(output)
        print(f"Performance result: {report['status']}. " + ("Baseline evidence is never a regression pass." if args.mode == "baseline" else ""), flush=True)
    return 0 if report["regression_passed"] else 1
