"""Automatic Release-app performance reproduction and fail-closed resource gate.

The 300-second deadline starts after compilation and includes calibration,
four fresh app lifetimes, fixture traffic, chart measurement, and teardown.
"""

import argparse
from bisect import bisect_right
from collections import deque
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
from http.client import HTTPConnection
import json
import math
import os
from pathlib import Path
import platform
import queue
import re
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
from performance_fixture import TIMING_POLICY


ROOT = Path(__file__).resolve().parent.parent
BUDGET_PATH = Path(__file__).with_name("performance_budget.json")
MAX_RECORD_BYTES = 1024 * 1024
MAX_SAMPLE_GAP_SECONDS = 0.75
CPU_POLICY = "authenticated-ready-startup-v1"
POPOVER_LIFECYCLE_POLICY = "explicit-performance-commands-v2"
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
    require(type(value.get("fixture_schema_version")) is int and value["fixture_schema_version"] == 2,
            "The shared fixture schema must be version 2")
    require(value.get("cpu_policy") == CPU_POLICY, "CPU policy must authenticate startup through the ready boundary")
    require(value.get("performance_deadline_seconds") == 300, "Performance deadline must be 300 seconds")
    limits = value.get("limits")
    require(isinstance(limits, dict), "Budget must contain limits")
    expected = {"cpu_rolling_1s_percent": 5.0, "cpu_startup_rolling_1s_percent": 50.0,
                "cpu_startup_short_allowance_seconds": 0.5, "lifetime_footprint_bytes": 64000000,
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


def memory_evidence(samples, final_exit=None):
    """Resolve read-order skew only with the child's actual final kernel peak."""
    problems, anomalies, peaks, footprints = [], [], [], []
    previous_peak = None
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict):
            problems.append("Resource sample is not an object")
            continue
        current = peak = None
        try:
            current = number(sample.get("physical_footprint_bytes"), "sample.physical_footprint_bytes", integer=True)
            footprints.append(current)
        except InvalidResult as error:
            problems.append(str(error))
        try:
            peak = number(sample.get("lifetime_peak_footprint_bytes"), "sample.lifetime_peak_footprint_bytes", minimum=1, integer=True)
            peaks.append(peak)
            if previous_peak is not None and peak < previous_peak:
                problems.append("Lifetime footprint peak moved backwards")
            # Every numeric raw peak participates, including incoherent pairs.
            previous_peak = peak
        except InvalidResult as error:
            problems.append(str(error))
        if current is not None and peak is not None and current > peak:
            anomalies.append({"sample_index": index, "monotonic_seconds": sample.get("monotonic_seconds"),
                              "physical_footprint_bytes": current, "lifetime_peak_footprint_bytes": peak,
                              "difference_bytes": current - peak})
    resolved = None
    prerequisites = shared_sample_problems(samples)
    if anomalies and not problems and not prerequisites and len(peaks) == len(samples) and len(footprints) == len(samples):
        final = samples[-1]
        authenticated = (isinstance(final_exit, dict) and final_exit.get("type") == "exited"
                         and type(final_exit.get("status")) is int
                         and final_exit.get("final_sample") == final and final.get("phase") == "final"
                         and all(sample.get("phase") != "final" for sample in samples[:-1])
                         and all((sample.get("process_id"), sample.get("birth_time_us")) ==
                                 (final.get("process_id"), final.get("birth_time_us")) for sample in samples)
                         and all(type(final.get(key)) is int and final[key] > 0 for key in ("process_id", "birth_time_us")))
        if authenticated and peaks[-1] >= max(footprints + peaks):
            resolved = {"sample_index": len(samples) - 1, "monotonic_seconds": final["monotonic_seconds"],
                        "process_id": final["process_id"], "birth_time_us": final["birth_time_us"],
                        "lifetime_peak_footprint_bytes": peaks[-1], "source": "exited.final_sample"}
    if anomalies and resolved is None:
        problems.append("Lifetime footprint peak is below current footprint")
    return {"problems": sorted(set(problems)), "read_order_anomalies": anomalies,
            "resolved_by_final_sample": resolved, "resolution_prerequisite_problems": prerequisites}


def shared_sample_problems(samples):
    problems = []
    if len(samples) < 2:
        problems.append("Fewer than two resource samples were collected")
        return problems
    identity = None
    previous = None
    for sample in samples:
        try:
            require(isinstance(sample, dict), "Resource sample is not an object")
            number(sample.get("monotonic_seconds"), "sample.monotonic_seconds")
            current_identity = (sample.get("process_id"), sample.get("birth_time_us"))
            require(all(type(value) is int and value > 0 for value in current_identity), "Sample process identity is missing")
            if identity is None:
                identity = current_identity
            require(identity == current_identity, "Resource samples switched process identity")
            if previous:
                require(sample["monotonic_seconds"] > previous["monotonic_seconds"], "Sample timestamps are not strictly increasing")
                require(sample["monotonic_seconds"] - previous["monotonic_seconds"] <= MAX_SAMPLE_GAP_SECONDS,
                        "Resource sampling gap exceeds 0.75 seconds; one-second CPU peaks cannot be established")
            previous = sample
        except (InvalidResult, TypeError, KeyError) as error:
            problems.append(str(error))
    return problems


def sample_validation_problems(samples, final_exit=None):
    """Keep independent counter faults from discarding valid diagnostics."""
    problems = {group: [] for group in ("shared", "memory", *REQUIRED_COUNTERS)}
    problems["shared"] = shared_sample_problems(samples)
    if problems["shared"]:
        return problems
    problems["memory"] = memory_evidence(samples, final_exit)["problems"]
    for counter in REQUIRED_COUNTERS:
        previous_value = None
        for sample in samples:
            try:
                value = sample.get(counter)
                require(value is not None, f"Required {counter} accounting is unavailable")
                number(value, f"sample.{counter}")
                if previous_value is not None:
                    require(value >= previous_value, f"Cumulative {counter} moved backwards")
                previous_value = value
            except InvalidResult as error:
                problems[counter].append(str(error))
    return problems


def validate_samples(samples):
    return sorted({problem for group in sample_validation_problems(samples).values() for problem in group})


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


def authenticated_cpu_ready(samples, events):
    """Bind startup's end to the collector's unique kernel handshake sample."""
    require(not shared_sample_problems(samples), "CPU ready boundary lacks a valid sample identity/timeline")
    require(isinstance(events, list) and all(isinstance(event, dict) for event in events),
            "CPU ready boundary requires the complete collector event stream")
    launched = [(index, event) for index, event in enumerate(events) if event.get("type") == "launched"]
    ready = [(index, event) for index, event in enumerate(events)
             if event.get("type") == "app_event" and isinstance(event.get("event"), dict)
             and event["event"].get("type") == "ready"]
    require(len(launched) == 1 and len(ready) == 1, "CPU accounting requires exactly one launched identity and one ready event")
    identity = (samples[0]["process_id"], samples[0]["birth_time_us"])
    launch_index, launch = launched[0]
    require(all(type(launch.get(key)) is int for key in ("pid", "birth_time_us"))
            and (launch.get("pid"), launch.get("birth_time_us")) == identity,
            "CPU ready boundary launched identity does not match the sampled process")
    require(samples[0].get("phase") == "baseline"
            and sum(sample.get("phase") == "baseline" for sample in samples) == 1,
            "CPU accounting requires exactly one initial pre-resume baseline sample")
    boundaries = [(index, sample) for index, sample in enumerate(samples)
                  if sample.get("command_id") == "collector-handshake"]
    require(len(boundaries) == 1, "CPU accounting requires exactly one collector-handshake kernel boundary")
    sample_index, boundary = boundaries[0]
    ready_index, envelope = ready[0]
    event = envelope["event"]
    require(type(event.get("protocol_version")) is int and event["protocol_version"] == 1
            and event.get("command_id") == "collector-handshake",
            "CPU ready event has an incompatible protocol or handshake identity")
    for evidence in (event, envelope):
        for key, expected in (("process_id", identity[0]), ("pid", identity[0]), ("birth_time_us", identity[1])):
            require(key not in evidence or (type(evidence[key]) is int and evidence[key] == expected),
                    "CPU ready event declares the wrong process identity")
    require(0 < sample_index < len(samples) - 1 and boundary.get("phase") == "control_boundary",
            "CPU ready boundary must separate startup and operational samples")
    require(launch_index < ready_index - 1 and events[ready_index - 1] == boundary,
            "CPU ready event does not immediately follow its authenticated kernel boundary")
    require(sum(item == boundary for item in events) == 1,
            "CPU ready kernel boundary appears more than once in the event stream")
    baseline_events = [index for index, item in enumerate(events) if item == samples[0]]
    require(len(baseline_events) == 1 and launch_index < baseline_events[0] < ready_index - 1,
            "CPU pre-resume baseline is absent, duplicated, or out of order")
    delivered = number(envelope.get("monotonic_seconds"), "CPU ready envelope timestamp")
    require(boundary["monotonic_seconds"] <= delivered <= samples[sample_index + 1]["monotonic_seconds"],
            "CPU ready delivery timestamp is outside its collector sample interval")
    return {"policy": CPU_POLICY, "sample_index": sample_index, "process_id": identity[0], "birth_time_us": identity[1],
            "monotonic_seconds": boundary["monotonic_seconds"], "cpu_seconds": boundary["cpu_seconds"],
            "source": "collector-handshake kernel sample immediately before ready"}


def cpu_interval_metrics(samples, start, end, include_initial=False):
    """Exact extrema of the piecewise-linear counter, including clipped edges."""
    require(samples[0]["monotonic_seconds"] <= start < end <= samples[-1]["monotonic_seconds"],
            "CPU interval is outside the measured process lifetime")
    # Decimal arithmetic preserves the emitted counter/timestamp precision and
    # avoids subtraction roundoff turning an exact threshold into a failure.
    start, end = Decimal(str(start)), Decimal(str(end))
    times = [Decimal(str(sample["monotonic_seconds"])) for sample in samples]
    values = [Decimal(str(number(sample.get("cpu_seconds"), "sample.cpu_seconds"))) for sample in samples]
    def counter(timestamp):
        index = bisect_right(times, timestamp) - 1
        if index == len(times) - 1 or times[index] == timestamp:
            return values[index]
        fraction = (timestamp - times[index]) / (times[index + 1] - times[index])
        return values[index] + fraction * (values[index + 1] - values[index])
    candidates = {end, min(start + 1, end)}
    candidates.update(timestamp for timestamp in times if start < timestamp <= end)
    candidates.update(timestamp + 1 for timestamp in times if start < timestamp + 1 <= end)
    peak = Decimal(0)
    for right in candidates:
        left = max(start, right - 1)
        beginning = Decimal(0) if include_initial and left == start else counter(left)
        peak = max(peak, counter(right) - beginning)
    beginning = Decimal(0) if include_initial else counter(start)
    return {"elapsed_seconds": float(end - start), "cpu_seconds": float(counter(end) - beginning),
            "rolling_1s_percent": float(100 * peak),
            "short_interval": end - start < 1,
            "window_semantics": "maximum one-second CPU delta, clipped at phase edges without discarding CPU"}


def cpu_accounting(samples, events, limits):
    metrics = {"cpu_rolling_1s_percent": None, "cpu_startup_rolling_1s_percent": None,
               "cpu_lifetime_rolling_1s_percent": None}
    result = {"policy": CPU_POLICY, "metrics": metrics, "failures": [], "invalid": []}
    problems = sample_validation_problems(samples)
    if problems["shared"] or problems["cpu_seconds"]:
        result["invalid"] = problems["shared"] + problems["cpu_seconds"]
        return result
    start, end = samples[0]["monotonic_seconds"], samples[-1]["monotonic_seconds"]
    lifetime = cpu_interval_metrics(samples, start, end, include_initial=True)
    metrics["cpu_lifetime_rolling_1s_percent"] = lifetime["rolling_1s_percent"]
    result["lifetime_diagnostic"] = lifetime
    try:
        ready = authenticated_cpu_ready(samples, events)
        exited = [event for event in events if event.get("type") == "exited"]
        require(len(exited) == 1 and type(exited[0].get("status")) is int
                and exited[0].get("final_sample") == samples[-1] and samples[-1].get("phase") == "final",
                "CPU operational coverage lacks the authenticated final exit sample")
        split = ready["monotonic_seconds"]
        startup = cpu_interval_metrics(samples, start, split, include_initial=True)
        operational = cpu_interval_metrics(samples, split, end)
        result.update(ready_boundary=ready, startup=startup, operational=operational)
        metrics.update(cpu_startup_rolling_1s_percent=startup["rolling_1s_percent"],
                       cpu_rolling_1s_percent=operational["rolling_1s_percent"],
                       cpu_startup_seconds=startup["cpu_seconds"], cpu_operational_seconds=operational["cpu_seconds"])
        if startup["short_interval"]:
            if startup["cpu_seconds"] > limits["cpu_startup_short_allowance_seconds"]:
                result["failures"].append(f"Startup CPU {startup['cpu_seconds']:.6f} seconds exceeds the 0.5 CPU-second short-startup allowance")
        elif startup["rolling_1s_percent"] > limits["cpu_startup_rolling_1s_percent"]:
            result["failures"].append(f"Startup rolling one-second CPU {startup['rolling_1s_percent']:.3f}% exceeds 50%")
        if operational["rolling_1s_percent"] > limits["cpu_rolling_1s_percent"]:
            result["failures"].append(f"Operational rolling one-second CPU {operational['rolling_1s_percent']:.3f}% exceeds 5%")
    except (InvalidResult, KeyError, TypeError) as error:
        result["invalid"].append(str(error))
    return result


def operational_stage_cpu(samples, stage, ready, limits):
    """Stage diagnostics inherit the process's operational phase; never restart startup."""
    result = {"policy": CPU_POLICY, "phase": "operational", "limit_percent": limits["cpu_rolling_1s_percent"], "invalid": []}
    try:
        begin = number(stage.get("before", {}).get("runner_collector_sample_monotonic_seconds"), "CPU stage start boundary")
        end = number(stage.get("after", {}).get("runner_collector_sample_monotonic_seconds"), "CPU stage end boundary")
        require(begin >= ready["monotonic_seconds"], "CPU stage starts before authenticated readiness")
        require(begin in {point["monotonic_seconds"] for point in samples}
                and end in {point["monotonic_seconds"] for point in samples}, "CPU stage boundary has no kernel sample")
        result.update(cpu_interval_metrics(samples, begin, end))
        result["within_limit"] = result["rolling_1s_percent"] <= result["limit_percent"]
    except (InvalidResult, KeyError, TypeError) as error:
        result["invalid"].append(str(error))
    return result


def record_operational_stage_cpu(case, samples, ready, limits):
    for index, stage in enumerate(case["stages"]):
        evidence = operational_stage_cpu(samples, stage, ready, limits)
        stage["cpu_accounting"] = evidence
        case["invalid"].extend(f"Operational CPU stage-{index}: {reason}" for reason in evidence["invalid"])


def evaluate_resources(samples, limits, logging_intervals, external_trace=False, final_exit=None, events=None):
    problems = sample_validation_problems(samples, final_exit)
    invalid = sorted({problem for name, group in problems.items()
                      if not (external_trace and name == "gpu_seconds") for problem in group})
    failures = []
    metrics = {}
    if problems["shared"]:
        return metrics, failures, invalid
    cpu = cpu_accounting(samples, events, limits)
    metrics.update(cpu["metrics"])
    failures.extend(cpu["failures"])
    invalid.extend(cpu["invalid"])
    gpu_samples = []
    gpu_time_invalid = False
    for sample in [] if problems["gpu_seconds"] else samples:
        if sample.get("gpu_sampled", True):
            point = dict(sample)
            point["monotonic_seconds"] = sample.get("gpu_sample_monotonic_seconds", sample["monotonic_seconds"])
            if type(point["monotonic_seconds"]) not in (int, float) or not math.isfinite(point["monotonic_seconds"]):
                if not external_trace:
                    invalid.append("GPU sample timestamp is unavailable")
                gpu_time_invalid = True
                continue
            if not gpu_samples or point["monotonic_seconds"] > gpu_samples[-1]["monotonic_seconds"]:
                gpu_samples.append(point)
    metrics["gpu_percent"] = rolling_percent(gpu_samples, "gpu_seconds") if gpu_samples and not gpu_time_invalid else None
    metrics["lifetime_footprint_bytes"] = None if problems["memory"] else max(sample["lifetime_peak_footprint_bytes"] for sample in samples)
    if problems["memory"]:
        footprints = [sample.get("physical_footprint_bytes") for sample in samples]
        if all(type(value) is int and value >= 0 for value in footprints):
            # This is observed evidence only, never a replacement for the
            # invalid kernel lifetime high-water mark or permission to pass.
            metrics["observed_footprint_lower_bound_bytes"] = max(footprints)
            if max(footprints) >= limits["lifetime_footprint_bytes"]:
                failures.append(f"Observed physical footprint {max(footprints)} must be below 64000000 bytes")
    if metrics["lifetime_footprint_bytes"] is not None and metrics["lifetime_footprint_bytes"] >= limits["lifetime_footprint_bytes"]:
        failures.append(f"Lifetime physical footprint {metrics['lifetime_footprint_bytes']} must be below 64000000 bytes")
    if not external_trace and (metrics["gpu_percent"] is None or any(sample.get("gpu_seconds") is None for sample in samples)):
        invalid.append("Required attributable GPU accounting is unavailable")
    if not external_trace and limits["gpu_percent"] is None:
        invalid.append("The required GPU ceiling has not been defined")
    elif not external_trace and metrics["gpu_percent"] is not None and metrics["gpu_percent"] > limits["gpu_percent"]:
        failures.append(f"GPU {metrics['gpu_percent']:.3f}% exceeds {limits['gpu_percent']}%")
    if external_trace:
        metrics["native_gpu_diagnostic_percent"] = metrics.pop("gpu_percent")
        metrics["gpu_percent"] = None
    if not all(sample.get("trace_coverage") is True for sample in samples):
        invalid.append("Complete filesystem-write trace coverage is unavailable")
    for counter, metric in (("physical_write_bytes", "physical_write_bytes_logging_off"),
                            ("logical_write_bytes", "logical_write_bytes_logging_off")):
        if problems[counter]:
            metrics[metric] = None
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
    indices = acknowledgement.get("expected_request_indices")
    require(isinstance(indices, list) and len(indices) == expected["requests"]
            and all(type(index) is int and index >= 0 for index in indices) and len(set(indices)) == len(indices),
            "Fixture acknowledgement does not identify every concurrent stream")


def validate_fixture_timing(stage, status, acknowledgement):
    require(isinstance(acknowledgement, dict) and status.get("run_id") == acknowledgement.get("run_id")
            and isinstance(status.get("run_id"), str) and status["run_id"], "Fixture timing belongs to a different workload")
    timing = status.get("timing")
    require(isinstance(timing, dict) and all(timing.get(key) == value and type(timing.get(key)) is type(value)
                                           for key, value in TIMING_POLICY.items()), "Fixture timing policy is missing or changed")
    streams = timing.get("streams")
    indices = acknowledgement.get("expected_request_indices")
    require(isinstance(streams, list) and len(streams) == 2 and isinstance(indices, list) and len(indices) == 2
            and all(type(index) is int and index >= 0 for index in indices) and len(set(indices)) == 2,
            "Timing evidence for both concurrent source streams is required")
    actual_indices = [item.get("request_index") if isinstance(item, dict) else None for item in streams]
    require(all(type(index) is int for index in actual_indices) and len(set(actual_indices)) == 2
            and sorted(actual_indices) == sorted(indices), "Fixture timing stream identities differ from the acknowledged workload")
    rate = 40 if stage["activity"] == "ordinary" else 200
    chunks = math.floor(stage["seconds"] * rate)
    lateness = TIMING_POLICY["maximum_lateness_seconds"]
    epsilon = TIMING_POLICY["early_epsilon_seconds"]
    first_flushes = []
    for stream in streams:
        require(type(stream.get("rate_hz")) in (int, float) and stream["rate_hz"] == rate
                and type(stream.get("duration_seconds")) in (int, float) and stream["duration_seconds"] == stage["seconds"],
                "Fixture timing rate or duration differs from the fixed workload")
        for field, expected in (("expected_content_fragments", chunks), ("records_observed", chunks + 1)):
            require(type(stream.get(field)) is int and stream[field] == expected, f"Fixture timing {field} is incomplete")
        fields = ("source_started_monotonic_seconds", "first_write_started_monotonic_seconds",
                  "first_flush_finished_monotonic_seconds", "terminal_write_started_monotonic_seconds",
                  "terminal_flush_finished_monotonic_seconds", "maximum_start_lateness_seconds",
                  "maximum_finish_lateness_seconds", "maximum_earliness_seconds", "maximum_flush_seconds")
        values = {field: number(stream.get(field), f"Fixture timing {field}") for field in fields}
        origin, first_start, first_finish, terminal_start, terminal_finish = [values[field] for field in fields[:5]]
        require(origin - epsilon <= first_start <= first_finish <= terminal_start <= terminal_finish,
                "Fixture timing timestamps are out of order")
        require(values["maximum_start_lateness_seconds"] <= values["maximum_finish_lateness_seconds"] <= lateness + 1e-9,
                "A source fragment write or flush exceeded its absolute deadline by more than 50 ms")
        require(values["maximum_earliness_seconds"] <= epsilon, "A source fragment was emitted before its planned deadline")
        require(values["maximum_flush_seconds"] <= lateness + epsilon,
                "A source fragment flush blocked beyond the timing policy")
        for due, started, finished in ((origin, first_start, first_finish),
                                       (origin + stage["seconds"], terminal_start, terminal_finish)):
            require(started - due <= values["maximum_start_lateness_seconds"] + 1e-9
                    and finished - due <= values["maximum_finish_lateness_seconds"] + 1e-9
                    and due - started <= values["maximum_earliness_seconds"] + 1e-9
                    and finished - started <= values["maximum_flush_seconds"] + 1e-9,
                    "Fixture timing extrema disagree with observed endpoint timestamps")
        require(abs(terminal_finish - first_finish - stage["seconds"]) <= lateness + 1e-9,
                "Observed source stream duration differs by more than 50 ms")
        require(type(stream.get("violation_count")) is int and stream["violation_count"] == 0
                and stream.get("violations") == [], "Source stream timing recorded a violation")
        first_flushes.append(first_finish)
    require(max(first_flushes) - min(first_flushes) <= TIMING_POLICY["maximum_stream_skew_seconds"] + 1e-9,
            "Concurrent source streams started more than 50 ms apart")


def validate_workload(stage, status, before, after, acknowledgement=None):
    expected = expected_work(stage)
    require(isinstance(before, dict) and isinstance(after, dict), "App snapshots are required")
    if stage["activity"] != "idle":
        require(status.get("running") is False and status.get("error") is None, "Synthetic network workload did not complete cleanly")
        require(status.get("forwarding_verified") is True, "Exact incremental forwarding was not verified")
        validate_fixture_timing(stage, status, acknowledgement)
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


def validate_popover_policy(evidence, context):
    require(isinstance(evidence, dict) and evidence.get("popover_lifecycle_policy") == POPOVER_LIFECYCLE_POLICY,
            f"{context} does not declare the required popover lifecycle policy {POPOVER_LIFECYCLE_POLICY}")


class Collector:
    def __init__(self, executable, app, configuration, gpu_capability, directory, deadline, measurement=None):
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
        prepare_history(configuration, run_directory, (measurement or {}).get("provenance", {}), directory, deadline)
        self.raw = (directory / "collector.jsonl").open("wb")
        self.stderr = (directory / "collector-stderr.log").open("wb")
        environment = os.environ.copy()
        environment["FLUXLLM_PERFORMANCE_CONFIGURATION"] = json.dumps(configuration, separators=(",", ":"))
        environment["FLUXLLM_PERFORMANCE_GPU_CAPABILITY_JSON"] = json.dumps(gpu_capability, separators=(",", ":"))
        environment["FLUXLLM_PERFORMANCE_STORAGE_ROOT"] = str(storage_root)
        environment["FLUXLLM_PERFORMANCE_RUN_ID"] = run_id
        if (measurement or {}).get("external_trace"):
            environment["FLUXLLM_PERFORMANCE_EXTERNAL_TRACE"] = "1"
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
                    if "snapshot" in response:
                        validate_popover_policy(response["snapshot"], f"App {name} acknowledgment snapshot")
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
                ready = event["event"]
                validate_popover_policy(ready, "App ready event")
                validate_popover_policy(ready.get("snapshot"), "App ready snapshot")
                return ready
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
        validate_popover_policy(snapshot, "App snapshot")
        boundary = response.get("collector_control_after_seconds")
        if type(boundary) in (int, float) and math.isfinite(boundary):
            snapshot = dict(snapshot, runner_collector_sample_monotonic_seconds=boundary)
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
    visibility_errors = {"show_dashboard": {"Dashboard did not become visible"},
                         "show_popover": {"Popover native anchor did not become ready", "Popover did not become visible"},
                         "close_dashboard": {"Dashboard did not close"},
                         "close_popover": {"Popover did not close"}}
    for command in (("show_dashboard", "show_popover") if show else ("close_popover", "close_dashboard")):
        response = collector.command(command)
        if (invalid is not None and response.get("status") == "error" and response.get("command") == command
                and response.get("reason") in visibility_errors[command]):
            diagnostics = {key: response[key] for key in
                           ("ui_failure_phase", "popover_readiness_before_show", "popover_readiness") if key in response}
            detail = "; diagnostics: " + json.dumps(diagnostics, sort_keys=True, separators=(",", ":")) if diagnostics else ""
            invalid.append(f"UI lifecycle coverage is incomplete: {response['reason']}{detail}")
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
    response["runner_verified"] = accepted
    case["logging_transitions"].append(response)
    if not accepted:
        case["invalid"].append(f"Logging {'enable' if enabled else 'disable/drain'} was not verified: {response.get('reason', response.get('status'))}")
        return open_interval
    if enabled:
        try:
            destinations = validated_logging_destinations(response, collector.storage)
        except (OSError, ValueError, KeyError) as error:
            response["runner_verified"] = False
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
        logging_supported = case.get("logging_supported", True)
        if index and logging_supported:
            open_interval = set_logging(collector, stage["logging_enabled"], case, open_interval)
        before = collector.snapshot()
        stage_result = {"specification": stage, "before": before, "continuous_stream": True,
                        "measurement_start_monotonic_seconds": started + index * 10,
                        "logging_transition_status": "supported" if logging_supported else "not-applicable",
                        "comparison_scope": "logging-on" if stage["logging_enabled"] else "logging-off"}
        if not logging_supported and stage["logging_enabled"]:
            stage_result["comparison_scope"] = "not-applicable"
            stage_result["not_applicable_reason"] = "Diagnostic logging did not exist in the pre-optimization application"
        if not stage["logging_enabled"] and logging_supported:
            transition = case.get("logging_transitions", [{}])[-1]
            if transition.get("runner_verified") is True and transition.get("logging_enabled") is False:
                stage_result["verified_off_start_collector_seconds"] = transition["collector_control_after_seconds"]
            else:
                stage_result["comparison_scope"] = "unverified-logging-off"
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
            stage_result["validated_work"] = validate_workload(whole, status, initial, after, acknowledgement)
        stage_result["measurement_end_monotonic_seconds"] = started + (index + 1) * 10 if index < 2 else time.monotonic()
        failures, invalid = presentation_checks(before, after, specification, stage)
        case["failures"].extend(failures)
        case["invalid"].extend(invalid)
    require(open_interval is None, "Logging was not acknowledged off and drained before the final interval")


def run_case(specification, collector_path, app_path, upstream, gpu_capability, directory, deadline, limits, cycle_start, measurement=None):
    directory.mkdir()
    measurement = measurement or {}
    external_trace = measurement.get("external_trace", False)
    case = {"name": specification["name"], "specification": specification, "stages": [],
            "logging_transitions": [], "logging_intervals": [], "logging_destinations": [], "failures": [], "invalid": []}
    configuration = {"upstream_url": upstream, "history": specification["history"], "protocol_version": 1,
                     "logging_enabled": False, "fixture_ending_at_epoch": time.time()}
    write_json(directory / "configuration.json", configuration)
    collector = None
    open_interval = None
    try:
        collector = Collector(collector_path, app_path, configuration, gpu_capability, directory, deadline, measurement)
        ready = collector.ready()
        require(ready.get("type") == "ready" and ready.get("protocol_version") == 1, "App control handshake is incompatible")
        require(isinstance(ready.get("snapshot"), dict), "Ready event is missing the seeded counter baseline")
        validate_popover_policy(ready, "App ready event")
        validate_popover_policy(ready["snapshot"], "App ready snapshot")
        proxy_url = ready.get("proxy_url")
        parsed = urlparse(proxy_url or "")
        require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port, "App proxy is not on numeric loopback")
        case["ready"] = ready
        if measurement.get("fixture_schema_version") is not None:
            require(ready.get("fixture_schema_version") == measurement["fixture_schema_version"],
                    "App fixture schema differs from the common workload")
            require(isinstance(ready.get("fixture_equivalence_sha256"), str)
                    and re.fullmatch(r"[0-9a-f]{64}", ready["fixture_equivalence_sha256"]),
                    "App did not identify its common fixture equivalence manifest")
            expected_fixture = measurement.get("provenance", {}).get("fixture_equivalence_sha256", {}).get(specification["history"])
            require(expected_fixture is None or ready["fixture_equivalence_sha256"] == expected_fixture,
                    "App fixture equivalence manifest differs from binary provenance")
        provenance = measurement.get("provenance", {})
        old_logging_absent = provenance.get("kind") == "reconstructed-pre-optimization" and provenance.get("logging_supported") is False
        if old_logging_absent:
            require(ready.get("logging_supported") is False, "Baseline logging capability differs from its reviewed provenance")
            case["logging_supported"] = False
            case["logging_not_applicable_reason"] = "Diagnostic logging did not exist in the pre-optimization application"
        else:
            case["logging_supported"] = True
        seed = ready["snapshot"]
        require(seed.get("history_verified") is True and seed.get("history") == specification["history"],
                "The requested retained-history fixture was not verified")
        if specification["history"] == "populated":
            require((seed.get("seed_persistent_requests"), seed.get("seed_raw_requests"), seed.get("seed_tool_events")) == (19000, 256, 38512),
                    "Populated retained-history dimensions changed")
        if case["logging_supported"]:
            open_interval = set_logging(collector, False, case, open_interval)
        if specification["ui"] in ("closed", "visible"):
            visible(collector, True, case["invalid"])
            if specification["ui"] == "closed":
                visible(collector, False, case["invalid"])
        if specification["name"] == "logging-transitions":
            run_continuous_logging(collector, specification, case, proxy_url, upstream, deadline, cycle_start)
        for stage_index, stage in enumerate([] if specification["name"] == "logging-transitions" else specification["stages"]):
            if "logging_enabled" in stage and case["logging_supported"]:
                open_interval = set_logging(collector, stage["logging_enabled"], case, open_interval)
            before = collector.snapshot()
            stage_result = {"specification": stage, "before": before}
            case["stages"].append(stage_result)
            started = time.monotonic()
            stage_result["measurement_start_monotonic_seconds"] = started
            stage_end = started + stage["seconds"]
            acknowledgement = None
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
            stage_result["measurement_end_monotonic_seconds"] = time.monotonic()
            stage_result.update(after=after, fixture_status=status, elapsed_seconds=time.monotonic() - started)
            stage_result["validated_work"] = validate_workload(stage, status, before, after, acknowledgement)
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
            case["trace_drain_end_monotonic_seconds"] = time.monotonic()
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
            if not external_trace and exits and "gpu_final_self_sample_received" in exits[-1]:
                if exits[-1].get("gpu_final_self_sample_received") is not True:
                    case["invalid"].append("The final attributed GPU self-sample was not received")
                if exits[-1].get("gpu_exit_tail_measured") is not True:
                    case["invalid"].append("GPU activity between the final self-sample and actual process exit is unmeasured")
            final_exit = exits[-1] if exits else None
            case["memory_validation"] = memory_evidence(collector.samples, final_exit)
            case["cpu_accounting"] = cpu_accounting(collector.samples, collector.events, limits)
            if case["cpu_accounting"].get("ready_boundary"):
                record_operational_stage_cpu(case, collector.samples, case["cpu_accounting"]["ready_boundary"], limits)
            metrics, failures, invalid = evaluate_resources(collector.samples, limits, case["logging_intervals"],
                                                            external_trace=external_trace, final_exit=final_exit, events=collector.events)
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
        case["workload_validated"] = len(case["stages"]) == len(specification["stages"]) and all("validated_work" in stage for stage in case["stages"])
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
    sources.update(ROOT.glob("scripts/performance_trace*.py"))
    sources.add(Path(__file__).with_name("performance_gpu_sample.py"))
    sources = sorted(path for path in sources if path.is_file())
    manifest = {str(path.relative_to(ROOT)): path_hash(path) for path in sources}
    digest = hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    return {"sha256": digest, "sources": manifest}


def adapter_identity():
    paths = [*ROOT.glob("Sources/FluxLLM/Performance/**/*.swift"),
             *ROOT.glob("Sources/FluxLLMApp/*Performance*.swift")]
    manifest = {str(path.relative_to(ROOT)): path_hash(path) for path in sorted(paths) if path.is_file()}
    return {"sha256": hashlib.sha256(json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
            "sources": manifest}


def validated_provenance(path, paths, mode, measurement_sha256):
    value = load_json(path)
    require(isinstance(value, dict) and value.get("schema_version") == 1, "Explicit binaries require provenance schema_version 1")
    require(value.get("kind") in ("reconstructed-pre-optimization", "current"), "Unknown binary provenance kind")
    require(value.get("build_configuration") == "release", "Explicit binary provenance must identify a Release build")
    require(isinstance(value.get("production_commit"), str) and re.fullmatch(r"[0-9a-f]{40}", value["production_commit"]),
            "Provenance must pin a complete production commit")
    for field in ("instrumentation_sha256", "adapter_sha256"):
        require(isinstance(value.get(field), str) and re.fullmatch(r"[0-9a-f]{64}", value[field]),
                f"Provenance requires a reviewed {field}")
    require(value["instrumentation_sha256"] == measurement_sha256,
            "Provenance common instrumentation hash differs from the pinned measurement sources")
    manifests = value.get("fixture_equivalence_sha256", {})
    require(isinstance(manifests, dict) and set(manifests).issubset({"fresh", "populated"})
            and all(isinstance(item, str) and re.fullmatch(r"[0-9a-f]{64}", item) for item in manifests.values()),
            "Fixture equivalence provenance must map history modes to SHA256 manifests")
    require(value.get("fixture_schema_version") == 2 and type(value.get("logging_supported")) is bool,
            "Provenance must identify the common fixture and logging capability")
    validate_popover_policy(value, "Binary provenance")
    if value["kind"] == "reconstructed-pre-optimization":
        require(mode == "baseline", "Reconstructed pre-optimization binaries may only record baselines")
    else:
        require(value["logging_supported"], "Current binary provenance must support the complete logging workload")
    hashes = value.get("binary_sha256")
    require(isinstance(hashes, dict), "Provenance is missing binary hashes")
    for key in ("app", "tests"):
        require(hashes.get(key) == path_hash(paths[key]), f"Explicit {key} binary does not match provenance")
    preparation = value.get("history_preparation", {"kind": "in-app"})
    require(isinstance(preparation, dict) and preparation.get("kind") in ("in-app", "legacy-files"),
            "Unsupported baseline history preparation")
    if preparation["kind"] == "legacy-files":
        helper = Path(preparation.get("executable", "")).expanduser()
        require(helper.is_absolute() and helper.is_file() and os.access(helper, os.X_OK), "Legacy history seeder must be an explicit executable")
        require(preparation.get("sha256") == path_hash(helper), "Legacy history seeder differs from provenance")
    return value | {"provenance_file": str(path.resolve()), "provenance_file_sha256": path_hash(path)}


def prepare_history(configuration, run_directory, provenance, output, deadline):
    preparation = provenance.get("history_preparation", {})
    if configuration["history"] != "populated" or preparation.get("kind") != "legacy-files":
        return
    helper = Path(preparation["executable"])
    require(path_hash(helper) == preparation["sha256"], "Legacy history seeder changed after provenance validation")
    execution = execute_logged([str(helper), "--seed-history", str(run_directory / "History"),
                                "--source", f"ollama|{configuration['upstream_url']}|",
                                "--ending-at-epoch", str(configuration["fixture_ending_at_epoch"])], output / "history-seed.log", deadline.remaining(20))
    write_json(output / "history-seed.json", execution)
    require(execution["exit_code"] == 0, "Legacy baseline history preparation failed; see history-seed.log")


def make_trace_session(output, deadline, provider="powermetrics"):
    if provider == "instruments":
        from performance_trace import TraceSession
        return TraceSession(output, deadline.end)
    require(provider == "powermetrics", "Unsupported GPU measurement provider")
    from performance_gpu_sample import PowermetricsSession
    return PowermetricsSession(output, deadline.end)


def register_case_trace(trace, case):
    samples = case.get("samples", [])
    require(not sample_validation_problems(samples)["shared"], "Trace windows lack a valid owned process identity and timeline")
    first, last = samples[0], samples[-1]
    pid, birth = first["process_id"], first["birth_time_us"]
    def trace_time(sample):
        number(sample.get("clock_read_uncertainty_seconds"), "Collector paired clock uncertainty", maximum=0.001)
        return trace.monotonic_from_mach_seconds(number(sample.get("mach_absolute_seconds"), "Collector Mach timestamp"))
    start, end = trace_time(first), trace_time(last)
    case.update(process_id=pid, birth_time_us=birth, launch_monotonic_seconds=start,
                end_monotonic_seconds=end, trace_windows={})
    case["trace_clock_uncertainty_seconds"] = max(number(sample.get("clock_read_uncertainty_seconds"), "Collector clock uncertainty") for sample in samples)
    require(case["trace_clock_uncertainty_seconds"] <= 0.001, "Collector clock bridge uncertainty exceeds 1 ms")
    by_time = {sample["monotonic_seconds"]: sample for sample in samples}
    case["trace_logging_intervals"] = []
    for begin, finish in case.get("logging_intervals", []):
        require(begin in by_time and finish in by_time, "Logging boundary has no paired collector clock evidence")
        case["trace_logging_intervals"].append([trace_time(by_time[begin]), trace_time(by_time[finish])])
    trace.register_process(pid, birth, start)
    def window(role, begin, finish):
        require(type(begin) in (int, float) and type(finish) in (int, float)
                and math.isfinite(begin) and math.isfinite(finish) and start <= begin < finish <= end,
                f"Trace {role} window is outside the measured app lifetime")
        name = f"{case['name']}/{role}"
        trace.add_window(name, pid, birth, begin, finish)
        case["trace_windows"][role] = name
    window("lifetime", start, end)
    exits = [event for event in case.get("events", []) if event.get("type") == "exited"]
    if exits and last.get("phase") == "final":
        trace.register_exit(pid, birth, end, case["trace_drain_end_monotonic_seconds"], exits[-1].get("status"))
    for index, stage in enumerate(case.get("stages", [])):
        if "measurement_start_monotonic_seconds" in stage and "measurement_end_monotonic_seconds" in stage:
            window(f"stage-{index}", stage["measurement_start_monotonic_seconds"], stage["measurement_end_monotonic_seconds"])
            if stage.get("comparison_scope") == "logging-off":
                begin = stage["measurement_start_monotonic_seconds"]
                boundary = stage.get("verified_off_start_collector_seconds")
                if case.get("logging_supported") is not False:
                    require(boundary in by_time, "Verified logging-off boundary lacks paired clock evidence")
                    begin = max(begin, trace_time(by_time[boundary]))
                window(f"off-stage-{index}", begin, stage["measurement_end_monotonic_seconds"])
    stages = case.get("stages", [])
    if stages and case.get("workload_validated"):
        window("workload", stages[0]["measurement_start_monotonic_seconds"], stages[-1]["measurement_end_monotonic_seconds"])


GPU_BOUND_METRICS = ("gpu_execution_seconds", "gpu_percent", "gpu_rolling_1s_percent")


def gpu_bounds(window):
    bounds = {}
    for metric in GPU_BOUND_METRICS:
        low = number(window.get(metric + "_lower_bound"), f"Trace {metric} lower bound")
        high = number(window.get(metric + "_upper_bound"), f"Trace {metric} upper bound")
        require(low <= high, f"Trace {metric} bounds are inverted")
        bounds[metric] = {"lower_bound": low, "upper_bound": high}
    return bounds


def gpu_delta_bounds(current, baseline):
    """A difference of bounded measurements is itself a bounded interval."""
    return {metric: {"lower_bound": current[metric]["lower_bound"] - baseline[metric]["upper_bound"],
                     "upper_bound": current[metric]["upper_bound"] - baseline[metric]["lower_bound"]}
            for metric in GPU_BOUND_METRICS}


def apply_trace_results(report, result):
    """Gate trace evidence independently of unavailable legacy live counters."""
    require(isinstance(result, dict), "Shared trace did not return a structured report")
    report["trace"] = result
    report["invalid"].extend(f"Shared trace: {item}" for item in result.get("invalid", []))
    if result.get("valid") is not True:
        report["invalid"].append("Shared trace capture, clock mapping, or calibration is incomplete")
    windows = result.get("windows", {})
    require(isinstance(windows, dict), "Shared trace windows are missing")
    for case in report["cases"]:
        case["gpu_trace"] = {role: windows.get(name) for role, name in case.get("trace_windows", {}).items()}
        case.setdefault("metrics", {})["gpu_percent"] = None
        lifetime = case["gpu_trace"].get("lifetime")
        if (result.get("valid") is not True or result.get("calibration", {}).get("valid") is not True
                or not isinstance(lifetime, dict) or lifetime.get("coverage_complete") is not True):
            case["invalid"].append("Required process-owned GPU trace lifetime window is incomplete")
        else:
            try:
                require(lifetime.get("process_id") == case.get("process_id")
                        and lifetime.get("birth_time_us") == case.get("birth_time_us"),
                        "GPU trace result does not identify the measured app process")
                require(lifetime.get("start_monotonic_seconds") == case.get("launch_monotonic_seconds")
                        and lifetime.get("end_monotonic_seconds") == case.get("end_monotonic_seconds"),
                        "GPU trace result does not cover the requested lifetime endpoints")
                bounds = gpu_bounds(lifetime)
                case["gpu_bounds"] = bounds
                low = bounds["gpu_rolling_1s_percent"]["lower_bound"]
                gpu = bounds["gpu_rolling_1s_percent"]["upper_bound"]
                case["metrics"].update(gpu_percent=gpu, gpu_percent_lower_bound=low, gpu_percent_upper_bound=gpu,
                                       gpu_execution_seconds_lower_bound=bounds["gpu_execution_seconds"]["lower_bound"],
                                       gpu_execution_seconds_upper_bound=bounds["gpu_execution_seconds"]["upper_bound"])
                case["gpu_metric_semantics"] = {
                    "gpu_percent": "Conservative rolling one-second upper bound used for the budget gate",
                    "unresolved_execution": "Every unresolved recorded execution interval in this window is included in the upper bound"}
                if gpu > report["budget"]["limits"]["gpu_percent"]:
                    case["failures"].append(f"GPU rolling one-second upper bound {gpu:.3f}% exceeds 1.0%")
            except InvalidResult as error:
                case["invalid"].append(str(error))
        for role, window in case["gpu_trace"].items():
            if isinstance(window, dict):
                case["invalid"].extend(f"GPU {role}: {item}" for item in window.get("invalid", []))
        exit_coverage = result.get("final_exit_coverage", {})
        final = exit_coverage.get(case.get("trace_windows", {}).get("lifetime"), exit_coverage.get(case["name"], {}))
        case["gpu_final_exit_coverage"] = final
        if final.get("complete") is not True:
            case["invalid"].append("Finalized GPU process-exit/outstanding-work coverage is incomplete: "
                                   + str(final.get("reason", "No terminal coverage proof was supplied")))
        for index, stage in enumerate(case.get("stages", [])):
            stage["gpu_trace"] = case["gpu_trace"].get(f"stage-{index}")
            stage["off_gpu_trace"] = case["gpu_trace"].get(f"off-stage-{index}")
    # Native filesystem proof remains independently enforced by run_case.
    # Missing authorization must not erase otherwise valid GPU values.
    for case in report["cases"]:
        case["filesystem_trace"] = {"provider": "fs_usage", "events": "collector.jsonl"}
        case["invalid"] = sorted(set(case["invalid"]))


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


def resolve_products(args, output, measurement_sha256):
    explicit_app = args.app_binary is not None or args.test_bundle is not None or args.provenance is not None
    if explicit_app:
        require(args.app_binary is not None and args.test_bundle is not None and args.provenance is not None,
                "Explicit app/test binaries require --app-binary, --test-bundle, and --provenance together")
    if explicit_app and args.collector_binary is not None:
        paths = {"app": args.app_binary.expanduser().resolve(), "tests": args.test_bundle.expanduser().resolve(),
                 "collector": args.collector_binary.expanduser().resolve()}
        build = {"status": "explicit-prebuilt-products", "elapsed_seconds": 0,
                 "note": "Build provenance is supplied separately; no binary is inferred from a stale build directory."}
    else:
        paths, _, build = build_products(output, args.build_timeout)
        if explicit_app:
            paths.update(app=args.app_binary.expanduser().resolve(), tests=args.test_bundle.expanduser().resolve())
        if args.collector_binary is not None:
            paths["collector"] = args.collector_binary.expanduser().resolve()
    for key, path in paths.items():
        require(path.exists() and (path.is_dir() if key == "tests" else path.is_file() and os.access(path, os.X_OK)),
                f"Explicit {key} product is missing or unusable: {path}")
    hashes = {key: {"path": str(path), "sha256": path_hash(path)} for key, path in paths.items()}
    if explicit_app:
        provenance = validated_provenance(args.provenance.expanduser().resolve(), paths, args.mode, measurement_sha256)
    else:
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, timeout=5, check=False)
        provenance = {"schema_version": 1, "kind": "current", "production_commit": revision.stdout.strip(),
                      "build_configuration": "release", "instrumentation_sha256": measurement_sha256,
                      "adapter_sha256": adapter_identity()["sha256"],
                      "logging_supported": True, "history_preparation": {"kind": "in-app"}, "fixture_schema_version": 2,
                      "popover_lifecycle_policy": POPOVER_LIFECYCLE_POLICY}
    return paths, hashes, build, provenance


def preflight(collector, directory, deadline, timeout=25, external_trace=False):
    def capture(arguments, name, timeout):
        command = [str(collector), *arguments]
        stdout_path, stderr_path = directory / f"{name}.jsonl", directory / f"{name}-stderr.log"
        started = time.monotonic()
        timed_out = False
        with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
            environment = os.environ.copy()
            if external_trace:
                environment["FLUXLLM_PERFORMANCE_EXTERNAL_TRACE"] = "1"
            process = subprocess.Popen(command, cwd=ROOT, stdout=stdout, stderr=stderr, start_new_session=True, env=environment)
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
                        "gpu": {"available": False, "live_counter_available": False,
                                "full_lifetime_coverage": False, "full_lifetime_unavailable_code": "preflight_incomplete",
                                "full_lifetime_unavailable_reason": reason,
                                "provider": "uncalibrated", "reason": reason, "calibration": None}}
        if proof.get("cpu", {}).get("available") is True:
            capabilities["cpu"] = proof["cpu"]
    result["capabilities"] = capabilities
    gpu = capabilities.get("gpu", {})
    if not external_trace and gpu.get("full_lifetime_coverage") is not True:
        errors.append("GPU full-lifetime coverage is unavailable: "
                      + str(gpu.get("full_lifetime_unavailable_reason") or "Finalized terminal GPU accounting was not demonstrated")
                      + f" (code: {gpu.get('full_lifetime_unavailable_code', 'missing_coverage_evidence')})")
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
    if report.get("budget", {}).get("cpu_policy") != CPU_POLICY:
        return None
    popover_policy = report.get("production_provenance", {}).get("popover_lifecycle_policy")
    if popover_policy != POPOVER_LIFECYCLE_POLICY:
        return None
    collector_sha256 = report.get("binary_identity", {}).get("collector", {}).get("sha256")
    if not isinstance(collector_sha256, str) or re.fullmatch(r"[0-9a-f]{64}", collector_sha256) is None:
        return None
    provider_fields = ("provider", "method", "counter", "counter_key", "api", "schema_version", "available", "validated",
                       "live_counter_available", "full_lifetime_coverage", "full_lifetime_unavailable_code")
    providers = {kind: {field: capability[field] for field in provider_fields if field in capability}
                 for kind, capability in capabilities.items()
                 if isinstance(capability, dict) and kind not in ("environment", "gpu", "trace_coverage")}
    providers["shared_trace"] = report.get("trace", {}).get("provider")
    providers["filesystem"] = report.get("filesystem_provider", "fs_usage")
    return {"measurement_sha256": report["measurement_identity"]["sha256"], "collector_sha256": collector_sha256,
            "environment": environment, "popover_lifecycle_policy": popover_policy, "cpu_policy": CPU_POLICY,
            "providers": providers, "limits": report["budget"]["limits"]}


def compare_baseline(report, parent):
    key = comparison_key(report)
    if key is None:
        return {"status": "unavailable", "reason": "Measurement environment, collector binary identity, or popover lifecycle policy is incomplete"}
    for path in sorted(parent.glob("baseline-*/report.json"), reverse=True):
        try:
            baseline = load_json(path)
            if path.parent == Path(report["artifact_directory"]) or baseline.get("mode") != "baseline" or comparison_key(baseline) != key:
                continue
            if len(baseline.get("cases", [])) != 4:
                continue
            changes, excluded, off_changes, gpu_changes = {}, {}, {}, {}
            for current, earlier in zip(report["cases"], baseline["cases"]):
                require(current["name"] == earlier["name"], "Baseline case order differs")
                name = current["name"]
                if any(case.get("ready", {}).get("popover_lifecycle_policy") != POPOVER_LIFECYCLE_POLICY
                       or case.get("ready", {}).get("snapshot", {}).get("popover_lifecycle_policy") != POPOVER_LIFECYCLE_POLICY
                       for case in (current, earlier)):
                    excluded[name] = "The common explicit popover lifecycle policy was not verified in both app handshakes"
                    continue
                current_fixture = current.get("ready", {}).get("fixture_equivalence_sha256")
                old_fixture = earlier.get("ready", {}).get("fixture_equivalence_sha256")
                if not current.get("workload_validated") or not earlier.get("workload_validated"):
                    excluded[name] = "The complete workload was not validated in both runs"
                    continue
                if not current_fixture or current_fixture != old_fixture:
                    excluded[name] = "Retained fixture equivalence manifests differ or are missing"
                    continue
                presentation_markers = ("UI lifecycle coverage", "Native dashboard_visible", "Native popover_visible", "Visible ")
                if any(any(marker in issue for marker in presentation_markers)
                       for case in (current, earlier) for issue in case.get("invalid", [])):
                    excluded[name] = "The requested native presentation workload was not completed in both runs"
                    continue
                if name == "logging-transitions" and current.get("logging_supported") != earlier.get("logging_supported"):
                    off_changes[name] = {}
                    for index in (0, 2):
                        now = current["stages"][index].get("off_gpu_trace") or {}
                        before = earlier["stages"][index].get("off_gpu_trace") or {}
                        if now.get("coverage_complete") is True and before.get("coverage_complete") is True:
                            off_changes[name][f"stage-{index}"] = gpu_delta_bounds(gpu_bounds(now), gpu_bounds(before))
                            # Different verified off durations permit rate comparisons, not absolute work deltas.
                            off_changes[name][f"stage-{index}"].pop("gpu_execution_seconds")
                            off_changes[name][f"stage-{index}"]["current_window_seconds"] = now.get("end_monotonic_seconds", 0) - now.get("start_monotonic_seconds", 0)
                            off_changes[name][f"stage-{index}"]["baseline_window_seconds"] = before.get("end_monotonic_seconds", 0) - before.get("start_monotonic_seconds", 0)
                    excluded[name] = "Whole-lifetime/on comparison is N/A: diagnostic logging did not exist in the original application"
                    continue
                if current.get("gpu_bounds") and earlier.get("gpu_bounds"):
                    gpu_changes[name] = gpu_delta_bounds(current["gpu_bounds"], earlier["gpu_bounds"])
                changes[current["name"]] = {metric: value - earlier["metrics"][metric]
                                             for metric, value in current.get("metrics", {}).items()
                                             if not metric.startswith("gpu_") and metric != "native_gpu_diagnostic_percent"
                                             if type(value) in (int, float) and type(earlier.get("metrics", {}).get(metric)) in (int, float)}
            return {"status": "compared" if changes or gpu_changes or any(off_changes.values()) else "unavailable", "baseline": str(path),
                    "metric_deltas": changes, "gpu_delta_bounds": gpu_changes, "logging_off_gpu_delta_bounds": off_changes, "excluded": excluded,
                    "baseline_provenance": baseline.get("production_provenance"),
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
    parser.add_argument("--gpu-provider", choices=("powermetrics", "instruments"), default="powermetrics",
                        help="Coarse GPU capability probe (default), or explicit detailed Instruments diagnostic")
    parser.add_argument("--build-timeout", type=float, default=900, help="Release build limit, separate from the fixed 300-second performance deadline")
    parser.add_argument("--app-binary", type=Path, help="Explicit app executable, with --test-bundle and --provenance")
    parser.add_argument("--test-bundle", type=Path, help="Explicit Release XCTest bundle for the selected production revision")
    parser.add_argument("--collector-binary", type=Path, help="Explicit current collector; avoids a build when app/test binaries are also supplied")
    parser.add_argument("--provenance", type=Path, help="Reviewed JSON provenance and hashes for explicit app/test binaries")
    args = parser.parse_args(argv)
    report = {"schema_version": 2, "mode": args.mode, "status": "running", "regression_passed": False,
              "created_at": datetime.now(timezone.utc).isoformat(), "cases": [], "failures": [], "invalid": [],
              "filesystem_provider": "fs_usage", "gpu_provider": args.gpu_provider}
    output = None
    fixture = None
    deadline = None
    trace = None
    trace_finished = False
    def finish_trace():
        nonlocal trace_finished
        if trace_finished:
            return
        trace_finished = True
        if deadline:
            deadline.cleanup_reserve = 3
        try:
            result = trace.finish() if trace is not None else {
                "valid": False, "invalid": ["GPU measurement provider was not started"], "windows": {}, "final_exit_coverage": {}}
            apply_trace_results(report, result)
        except (ImportError, OSError, ValueError, TypeError, subprocess.SubprocessError, TimeoutError) as error:
            report["invalid"].append(f"Shared trace finalization failed: {error}")
        if output:
            for case in report["cases"]:
                (output / case["name"]).mkdir(exist_ok=True)
                write_json(output / case["name"] / "result.json", case)
    try:
        number(args.build_timeout, "--build-timeout", minimum=1, maximum=3600)
        report["budget"] = validate_budget(load_json(args.budget))
        suffix = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ") + "-" + secrets.token_hex(3)
        output = args.output_dir.expanduser().resolve() if args.output_dir else ROOT / ".performance-results" / f"{args.mode}-{suffix}"
        require(not output.exists(), "Artifact directory already exists; evidence is never overwritten")
        output.mkdir(parents=True)
        report["artifact_directory"] = str(output)
        report["measurement_identity"] = measurement_identity()
        report["adapter_identity"] = adapter_identity()
        print(f"Artifacts: {output}\nPreparing Release app, collector, and test binaries…", flush=True)
        paths, hashes, build, provenance = resolve_products(args, output, report["measurement_identity"]["sha256"])
        report.update(binary_identity=hashes, build=build, production_provenance=provenance)
        require(measurement_identity() == report["measurement_identity"], "Measurement sources changed during the Release build")
        require(platform.system() == "Darwin", "Actual-app resource measurement requires macOS")
        started = time.monotonic()
        deadline = Deadline(300, cleanup_reserve=30)
        print("Starting the 300-second performance stage (180 seconds of scheduled workloads).", flush=True)
        try:
            trace = make_trace_session(output, deadline, args.gpu_provider)
            report["trace_start"] = trace.start()
            report["trace_calibration_setup"] = trace.calibrate(paths["collector"])
        except (ImportError, OSError, ValueError, subprocess.SubprocessError, TimeoutError) as error:
            report["invalid"].append(f"Shared trace setup failed: {error}")
        report["preflight"] = preflight(paths["collector"], output, deadline, external_trace=True)
        report["invalid"].extend(report["preflight"].get("invalid", []))
        if report["preflight"]["execution"]["exit_code"] != 0:
            report["invalid"].append("Collector preflight did not exit successfully")
        capabilities = report["preflight"]["capabilities"]
        environment = capabilities.get("environment", {})
        if environment.get("build_configuration") != "release":
            report["invalid"].append("Collector did not identify a Release environment")
        for field in ("cpu", "physical_footprint", "physical_writes", "logical_writes"):
            if capabilities.get(field, {}).get("available") is not True:
                report["invalid"].append(f"Required {field} capability is unavailable: {capabilities.get(field, {}).get('reason', 'unspecified')}")
        if capabilities.get("trace_coverage", {}).get("available") is not True:
            report["invalid"].append("Required fs_usage filesystem coverage is unavailable: "
                                     + str(capabilities.get("trace_coverage", {}).get("reason", "unspecified")))
        fixture, upstream = launch_fixture(output, timeout=deadline.remaining(10))
        measurement = {"external_trace": True, "filesystem_provider": "fs_usage",
                       "fixture_schema_version": 2, "provenance": provenance}
        for index, case in enumerate(report["budget"]["cases"]):
            deadline.remaining()
            print(f"Measuring {case['name']}…", flush=True)
            measured = run_case(case, paths["collector"], paths["app"], upstream, capabilities.get("gpu", {}),
                                output / case["name"], deadline, report["budget"]["limits"], index * 10, measurement)
            report["cases"].append(measured)
            if trace is not None:
                try:
                    register_case_trace(trace, measured)
                except (OSError, ValueError, KeyError, TypeError) as error:
                    measured["invalid"].append(f"Shared trace process/window registration failed: {error}")
            case_environment = measured.get("environment")
            if case_environment:
                if report.get("environment") is None:
                    report["environment"] = case_environment
                elif report["environment"] != case_environment:
                    report["invalid"].append("The actual app measurement environment changed between fresh processes")
                if environment and environment != case_environment:
                    report["invalid"].append("The actual app environment differs from preflight")
            metrics = measured.get("metrics", {})
            print(f"  CPU operational={metrics.get('cpu_rolling_1s_percent', 'unavailable')}% "
                  f"startup={metrics.get('cpu_startup_rolling_1s_percent', 'unavailable')}% "
                  f"lifetime diagnostic={metrics.get('cpu_lifetime_rolling_1s_percent', 'unavailable')}% "
                  f"GPU={metrics.get('gpu_percent', 'unavailable')}% "
                  f"peak={metrics.get('lifetime_footprint_bytes', 'unavailable')} bytes; "
                  f"{len(measured['failures'])} failures, {len(measured['invalid'])} incomplete checks", flush=True)
            write_json(output / "report.json", report)
        print("Finalizing GPU measurement evidence…", flush=True)
        finish_trace()
        for case in report["cases"]:
            bounds = case.get("gpu_bounds", {}).get("gpu_rolling_1s_percent")
            value = f"{bounds['lower_bound']:.6f}..{bounds['upper_bound']:.6f}% (upper bound gated)" if bounds else "unavailable"
            print(f"  {case['name']}: GPU rolling one-second {value}", flush=True)
        print("Measuring fresh chart publications within the remaining deadline…", flush=True)
        report["chart"] = run_chart(paths["tests"], output, deadline)
        report["failures"].extend(report["chart"].get("failures", []))
        report["invalid"].extend(report["chart"].get("invalid", []))
        require(measurement_identity() == report["measurement_identity"], "Measurement sources changed during the performance stage")
        require(adapter_identity() == report["adapter_identity"], "App adapter sources changed during the performance stage")
        for key, path in paths.items():
            require(path_hash(path) == hashes[key]["sha256"], f"Measured {key} binary changed during the performance stage")
        report["performance_elapsed_seconds"] = time.monotonic() - started
        deadline.remaining()
    except (OSError, ValueError, subprocess.SubprocessError, TimeoutError, KeyboardInterrupt) as error:
        report["invalid"].append(str(error) or "Interrupted")
    finally:
        if deadline and not trace_finished:
            finish_trace()
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
