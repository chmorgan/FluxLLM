"""Bounded current-runtime CPU attribution and same-binary controlled comparisons.

No builds, automatic retries, native memory inspectors, or performance-gate pass.
Time Profiler estimates and unprofiled kernel CPU comparisons remain separate.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import os
import math
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import time
import uuid

import app_performance as app
import memory_attribution as memory
from performance_trace import _Notice, _birth_time, _mach_clock, read_run_issues
from run_performance_checks import require, write_json


MAX_SECONDS = 300
CASE_SECONDS = 54
PROFILE_SECONDS = 120
PROFILE_SAVE_SECONDS = 30
PROFILE_POST_SAVE_SECONDS = 18
WORK = {"chunks": 10000, "output_tokens": 20034, "prompt_tokens": 46,
        "requests": 2, "tool_calls": 2, "tool_results": 2}
COUNTERS = ("optimized_chart_preparations", "history_tool_order_builds", "history_completed_order_builds",
            "history_tool_order_insertions", "history_completed_order_insertions", "chart_preparations")
BASELINES = ("native-gpu-optimized", "runtime-optimized", "normal", memory.ORDERED_PUBLICATION_MODE)


class RuntimeDeadline(memory.MemoryDeadline):
    def __init__(self, seconds=MAX_SECONDS, cleanup_reserve=15, clock=time.monotonic):
        self.clock, self.end, self.cleanup_reserve = clock, clock() + seconds, cleanup_reserve

    @contextmanager
    def interrupt_at(self, end):
        """Nested case/export alarms preserve the absolute outer deadline."""
        duration = end - self.clock()
        require(duration > 0, "No runtime attribution time remains")
        previous = signal.getsignal(signal.SIGALRM)
        def expired(_signal, _frame):
            raise TimeoutError("Runtime attribution exceeded its bounded deadline")
        signal.signal(signal.SIGALRM, expired)
        started = self.clock()
        old_timer = signal.setitimer(signal.ITIMER_REAL, duration)
        if old_timer[0] and old_timer[0] < duration:
            signal.setitimer(signal.ITIMER_REAL, old_timer[0])
        try:
            yield
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
            if old_timer[0]:
                signal.setitimer(signal.ITIMER_REAL, max(.000001, old_timer[0] - (self.clock() - started)), old_timer[1])

    def remaining(self, maximum=None):
        remaining = self.end - self.clock() - self.cleanup_reserve
        if remaining <= 0:
            raise TimeoutError("Runtime attribution reached its 300-second cleanup reserve")
        return min(remaining, maximum) if maximum is not None else remaining


def runtime_source_identity():
    names = {"runtime_attribution.py", "runtime_time_profile.py", "memory_attribution.py", "app_performance.py",
             "run_performance_checks.py", "performance_fixture.py", "performance_gpu_sample.py"}
    names.update(path.name for path in Path(__file__).parent.glob("performance_trace*.py"))
    return {name: app.path_hash(Path(__file__).with_name(name)) for name in sorted(names)}


def validate_runtime_work(before, after, mode, *, required=True):
    flags = memory.runtime_feature_contract(after.get("graphics_diagnostics", {}), mode)
    initial = memory.runtime_feature_contract(before.get("graphics_diagnostics", {}), mode)
    if flags is None and not required and mode == "normal":
        return {"available": False, "reason": "Frozen normal predates runtime-control counters"}
    require(flags is not None and set(memory.RUNTIME_FLAGS) <= set(flags) and flags == initial,
            "Runtime workload lacks a stable complete feature contract")
    delta = {}
    for field in COUNTERS:
        first = memory.unsigned(before.get(field), f"runtime.before.{field}")
        last = memory.unsigned(after.get(field), f"runtime.after.{field}")
        require(last >= first, f"Runtime {field} counter moved backwards")
        delta[field] = last - first
    require(delta["chart_preparations"] > 0, "Runtime workload did not prepare charts")
    if mode == memory.NO_ARRIVAL_MODE or "arrival_effects_enabled" in flags or any("suppressed_arrival_effects" in snapshot for snapshot in (before, after)):
        require("arrival_effects_enabled" in flags, "Arrival suppression counter lacks feature metadata")
        first = memory.unsigned(before.get("suppressed_arrival_effects"), "runtime.before.suppressed_arrival_effects")
        last = memory.unsigned(after.get("suppressed_arrival_effects"), "runtime.after.suppressed_arrival_effects")
        require(last >= first, "Runtime suppressed_arrival_effects counter moved backwards")
        delta["suppressed_arrival_effects"] = last - first
        if mode == memory.NO_ARRIVAL_MODE:
            require(delta["suppressed_arrival_effects"] > 0, "No-arrival mode did not suppress arrival effects during the workload")
        else:
            require(first == last == 0, "Baseline mode unexpectedly suppressed arrival effects")
    if (mode in (memory.UNGROUPED_CANVAS_MODE, memory.NO_ARRIVAL_MODE) or "ungrouped_native_canvas" in flags
            or any(field in snapshot for snapshot in (before, after) for field in memory.NATIVE_CANVAS_GROUP_COUNTERS)):
        require("ungrouped_native_canvas" in flags, "Native Canvas grouping counters lack feature metadata")
        callback_counts = []
        for snapshot in (before, after):
            value = snapshot["graphics_diagnostics"]
            callbacks = memory.unsigned(value.get("native_gpu_canvas_draws"), "graphics.native_gpu_canvas_draws")
            require(set(value["roles"]) == {"static_chart", "cursor", "rail_bars", "rail_decorations"}
                    and callbacks == sum(memory.unsigned(role.get("draws"), "graphics.role.draws") for role in value["roles"].values()),
                    "Native Canvas callbacks do not reconcile with drawn role frames")
            require(callbacks == sum(memory.unsigned(snapshot.get(field), field) for field in memory.NATIVE_CANVAS_GROUP_COUNTERS),
                    "Native Canvas grouping counters do not reconcile with native callbacks")
            callback_counts.append(callbacks)
        for field in memory.NATIVE_CANVAS_GROUP_COUNTERS:
            first, last = before[field], after[field]
            require(last >= first, f"Runtime {field} counter moved backwards")
            delta[field] = last - first
        require(sum(delta[field] for field in memory.NATIVE_CANVAS_GROUP_COUNTERS) == callback_counts[1] - callback_counts[0],
                "Native Canvas grouping deltas do not reconcile with callback work")
        if flags["ungrouped_native_canvas"]:
            require(delta["ungrouped_native_canvas_draws"] > 0 and delta["grouped_native_canvas_draws"] == 0,
                    "Ungrouped native Canvas did not execute callbacks without grouped fallback")
        else:
            require(before["ungrouped_native_canvas_draws"] == after["ungrouped_native_canvas_draws"] == 0,
                    "Grouped native Canvas mode executed ungrouped callbacks")
            require(delta["grouped_native_canvas_draws"] > 0, "Baseline native Canvas did not execute grouped callbacks")
    if (mode in (memory.DIRECT_TOOL_PLOT_MODE, memory.UNGROUPED_CANVAS_MODE, memory.NO_ARRIVAL_MODE) or "direct_tool_plot" in flags
            or any(field in snapshot for snapshot in (before, after) for field in memory.DIRECT_TOOL_PLOT_COUNTERS)):
        require("direct_tool_plot" in flags, "Tool-plot counters lack feature metadata")
        for field in memory.DIRECT_TOOL_PLOT_COUNTERS:
            first = memory.unsigned(before.get(field), f"runtime.before.{field}")
            last = memory.unsigned(after.get(field), f"runtime.after.{field}")
            require(last >= first, f"Runtime {field} counter moved backwards")
            delta[field] = last - first
        if flags["direct_tool_plot"]:
            require(delta["direct_tool_plot_builds"] > 0 and delta["legacy_tool_plot_builds"] == 0,
                    "Direct tool plot did not execute geometry builds without legacy fallback")
        else:
            require(before["direct_tool_plot_builds"] == after["direct_tool_plot_builds"] == 0,
                    "Legacy tool-plot mode executed direct geometry builds")
            require(delta["legacy_tool_plot_builds"] > 0, "Baseline tool plot did not execute legacy geometry builds")
    if (mode in memory.ORDERED_PUBLICATION_MODES or "ordered_chart_publication" in flags
            or any(field in snapshot for snapshot in (before, after) for field in memory.ORDERED_PUBLICATION_COUNTERS)):
        require("ordered_chart_publication" in flags, "Ordered-publication counters lack feature metadata")
        for field in memory.ORDERED_PUBLICATION_COUNTERS:
            first = memory.unsigned(before.get(field), f"runtime.before.{field}")
            last = memory.unsigned(after.get(field), f"runtime.after.{field}")
            require(last >= first, f"Runtime {field} counter moved backwards")
            delta[field] = last - first
        if flags["ordered_chart_publication"]:
            require(delta["ordered_chart_publication_queries"] > 0 and delta["chart_publication_full_sorts"] == 0,
                    "Ordered chart publication did not execute queries without fallback full sorts")
        else:
            require(before["ordered_chart_publication_queries"] == after["ordered_chart_publication_queries"] == 0,
                    "Nonordered mode executed ordered publication queries")
            require(delta["chart_publication_full_sorts"] > 0, "Baseline chart publication did not execute fallback full sorts")
    if (mode in memory.CANVAS_CLOCK_MODES or "canvas_frame_clock" in flags
            or any(field in snapshot for snapshot in (before, after) for field in memory.CANVAS_CLOCK_COUNTERS)):
        for field in memory.CANVAS_CLOCK_COUNTERS:
            first = memory.unsigned(before.get(field), f"runtime.before.{field}")
            last = memory.unsigned(after.get(field), f"runtime.after.{field}")
            require(last >= first, f"Runtime {field} counter moved backwards")
            delta[field] = last - first
        if flags.get("canvas_frame_clock", False):
            require(delta["rail_frame_clock_ticks"] > 0, "Canvas frame-clock path did not execute frame ticks")
            require(before["rail_timeline_content_updates"] == after["rail_timeline_content_updates"] == 0,
                    "Canvas frame-clock mode updated Timeline content")
        else:
            require(before["rail_frame_clock_ticks"] == after["rail_frame_clock_ticks"] == 0,
                    "Nonclock mode executed Canvas frame ticks")
    instrumented_shared = (mode in memory.NEXT_RUNTIME_MODES or any(field in flags for field in memory.NEXT_RUNTIME_FLAGS)
                           or any(field in snapshot for snapshot in (before, after) for field in memory.SHARED_PREPARATION_COUNTERS))
    if instrumented_shared:
        for field in memory.SHARED_PREPARATION_COUNTERS:
            first = memory.unsigned(before.get(field), f"runtime.before.{field}")
            last = memory.unsigned(after.get(field), f"runtime.after.{field}")
            require(last >= first, f"Runtime {field} counter moved backwards")
            delta[field] = last - first
        if flags.get("shared_chart_preparation", False):
            require(0 < delta["shared_chart_normalization_builds"] <= delta["shared_chart_preparations"] == delta["chart_preparations"],
                    "Shared normalization did not cover every chart preparation with bounded positive builds")
        else:
            require(all(before[field] == after[field] == 0 for field in memory.SHARED_PREPARATION_COUNTERS),
                    "Nonshared mode executed shared chart preparation")
    instrumented_writes = (mode in memory.NEXT_RUNTIME_MODES or any(field in flags for field in memory.NEXT_RUNTIME_FLAGS)
                           or any("streamed_bodies_without_promises" in snapshot for snapshot in (before, after)))
    if instrumented_writes:
        field = "streamed_bodies_without_promises"
        first = memory.unsigned(before.get(field), f"runtime.before.{field}")
        last = memory.unsigned(after.get(field), f"runtime.after.{field}")
        require(last >= first, "Unpromised stream body-write counter moved backwards")
        delta[field] = last - first
        if flags.get("unpromised_stream_body_writes", False):
            require(delta[field] > 0, "Unpromised stream body-write path did not execute")
        else:
            require(first == last == 0, "Promised-write mode executed unpromised stream body writes")
    if flags.get("stable_decoration_hosts", False):
        require(memory.unsigned(after["graphics_diagnostics"]["roles"]["rail_decorations"].get("created"),
                                "stable decoration hosts created") > 0,
                "Stable decoration-host mode did not create a decoration host")
    if flags["optimized_chart_preparation"]:
        require(delta["optimized_chart_preparations"] == delta["chart_preparations"],
                "Optimized preparation did not cover every prepared chart")
    else:
        require(delta["optimized_chart_preparations"] == 0, "Baseline executed optimized chart preparation")
    if flags["incremental_history_ordering"]:
        require(delta["history_tool_order_builds"] == delta["history_completed_order_builds"] == 0,
                "Warmed incremental history rebuilt a full retained ordering during traffic")
        require(delta["history_tool_order_insertions"] > 0 and delta["history_completed_order_insertions"] > 0,
                "Incremental history did not execute tool and completed-request insertion paths")
    else:
        require(delta["history_tool_order_insertions"] == delta["history_completed_order_insertions"] == 0,
                "Baseline executed incremental history insertion paths")
    for role in ("static_chart", "rail_decorations"):
        first = before["graphics_diagnostics"]["roles"][role]["draws"]
        last = after["graphics_diagnostics"]["roles"][role]["draws"]
        require(last >= first, f"Runtime {role} drawing counter moved backwards")
        delta[role + "_draws"] = last - first
    require(delta["static_chart_draws"] > 0, "Runtime static charts did not redraw")
    if flags.get("canvas_frame_clock", False):
        minimum_draws = max(1, math.floor(.8 * delta["rail_frame_clock_ticks"]) - 2)
        require(delta["rail_decorations_draws"] >= minimum_draws,
                "Canvas frame ticks did not produce sufficient native decoration draws")
    if not flags["lifecycle_effects_enabled"]:
        require(delta["rail_decorations_draws"] == 0, "No-lifecycle control still drew lifecycle decorations")
    return {"available": True, "features": flags, "deltas": delta}


def validate_visual_work(report, *, required):
    """Authenticate deterministic effect selection without changing its clocks."""
    points = report["runtime"]["checkpoints"]
    snapshots = [point["snapshot"] for point in points]
    extra = [report.get("ready", {}).get("snapshot")]
    extra += [entry.get("snapshot") for entry in report.get("checkpoints", [])]
    extra += [entry.get("event", {}).get("snapshot") for entry in report.get("events", [])
              if entry.get("type") == "app_event"]
    snapshots += [snapshot for snapshot in extra if isinstance(snapshot, dict)]
    fields = ("synthetic_request_identity", "synthetic_animation_policy")
    if not required and all(not any(field in snapshot for field in fields) for snapshot in snapshots):
        return {"available": False, "visual_comparison_eligible": False,
                "reason": "Frozen profile predates deterministic request identities and twinkle seeding"}
    acknowledgement = report["workload"]["fixture_start"]
    indices = acknowledgement.get("expected_request_indices")
    streams = report["workload"]["fixture_status"].get("timing", {}).get("streams", [])
    require(isinstance(indices, list) and len(indices) == 2
            and all(type(index) is int and 0 <= index <= 32_000_032 for index in indices)
            and len(set(indices)) == 2
            and sorted(stream.get("request_index") for stream in streams) == sorted(indices),
            "Synthetic visual identities lack both acknowledged fixture streams")
    expected = {index: str(uuid.UUID(bytes=bytes([0x52, 0x45, 0x53, 0x46, 0, 0, 0, 7])
                                    + index.to_bytes(8, "big"))).upper() for index in indices}
    def requests(snapshot):
        value = snapshot.get("synthetic_request_identity")
        require(isinstance(value, dict) and value.get("policy") == "fixture-index-v1"
                and type(value.get("invalid_requests")) is int and value["invalid_requests"] == 0,
                "Synthetic request identity policy is missing, changed, or recorded invalid requests")
        require(snapshot.get("synthetic_animation_policy") == "fixture-index-and-fixed-twinkle-seed-v1",
                "Synthetic animation seeding policy is missing or changed")
        rows = value.get("requests")
        require(isinstance(rows, list) and len(rows) <= 2
                and all(isinstance(row, dict) and type(row.get("index")) is int
                        and row["index"] in expected and row.get("id") == expected[row["index"]] for row in rows),
                "Synthetic request UUID does not match the fixture index")
        actual = [row["index"] for row in rows]
        require(actual == sorted(set(actual)), "Synthetic request identities are duplicated or unsorted")
        return set(actual)
    for snapshot in snapshots:
        requests(snapshot)
    require(not requests(points[0]["snapshot"]), "Synthetic workload already had live request identities before traffic")
    previous = set()
    for point in points:
        current = requests(point["snapshot"])
        require(previous <= current, "Synthetic request identity disappeared during runtime")
        previous = current
    require(previous == set(indices), "Synthetic workload did not record both expected request identities")
    return {"available": True, "visual_comparison_eligible": True,
            "identity_policy": "fixture-index-v1", "animation_policy": "fixture-index-and-fixed-twinkle-seed-v1",
            "requests": [{"index": index, "id": expected[index]} for index in sorted(indices)],
            "invalid_requests": 0, "real_time_clocks_preserved": True}


def validate_canvas_clock_work(report, mode):
    """Use existing authenticated checkpoints; never infer idle from a tail deadline."""
    points = report["runtime"]["checkpoints"]
    flags = memory.runtime_feature_contract(points[0]["snapshot"].get("graphics_diagnostics", {}), mode) or {}
    if (mode not in memory.CANVAS_CLOCK_MODES and "canvas_frame_clock" not in flags
            and not any(field in point["snapshot"] for point in points for field in memory.CANVAS_CLOCK_COUNTERS)):
        return {"available": False, "reason": "Frozen product predates rail frame-clock counters"}
    clock_enabled = flags.get("canvas_frame_clock", False)
    clocks = report["runtime"]
    offset = sum(clocks[name]["absolute_minus_monotonic_seconds"] for name in ("mach_clock_start", "mach_clock_end")) / 2

    def boundary(point):
        snapshot, sample = point["snapshot"], point["resource_sample"]
        matches = [row for row in report["samples"]
                   if row["monotonic_seconds"] == snapshot.get("runner_collector_sample_monotonic_seconds")]
        require(len(matches) == 1 and matches[0] == sample
                and sample["process_id"] == report["owned_identity"]["process_id"]
                and sample["birth_time_us"] == report["owned_identity"]["birth_time_us"],
                "Frame-clock checkpoint lacks its authenticated kernel boundary")
        require(memory.runtime_feature_contract(snapshot.get("graphics_diagnostics", {}), mode) == flags,
                "Frame-clock feature metadata changed during the capture")
        for field in memory.CANVAS_CLOCK_COUNTERS:
            memory.unsigned(snapshot.get(field), field)
        if clock_enabled:
            require(snapshot["rail_timeline_content_updates"] == 0, "Canvas frame-clock mode updated Timeline content")
        else:
            require(snapshot["rail_frame_clock_ticks"] == 0, "Nonclock mode executed Canvas frame ticks")
        return sample["mach_absolute_seconds"] - offset

    timestamps = [boundary(point) for point in points]
    for first, last in zip(points, points[1:]):
        require(all(last["snapshot"][field] >= first["snapshot"][field] for field in memory.CANVAS_CLOCK_COUNTERS),
                "Frame-clock counters moved backwards during runtime")
    window = report["phase_windows"]["steady"]
    steady = [(point, timestamp) for point, timestamp in zip(points, timestamps)
              if window["start_monotonic_seconds"] < timestamp < window["end_monotonic_seconds"]]
    require(len(steady) >= 2 and all(point["snapshot"].get("active_requests") == 2 for point, _ in steady),
            "Frame-clock steady evidence lacks both active requests and interior checkpoints")
    first, last = steady[0][0], steady[-1][0]
    delta = {field: last["snapshot"][field] - first["snapshot"][field] for field in memory.CANVAS_CLOCK_COUNTERS}
    if clock_enabled:
        # This exact fixture has only two simultaneous arrivals (0.8s effects)
        # and no completion before 25s. The +5s..+20s interior excludes both.
        require(delta["rail_frame_clock_ticks"] == 0, "Canvas frame clock continued ticking during effect-free steady traffic")
    result = {"available": True, "steady": {"start_checkpoint": first["label"], "end_checkpoint": last["label"],
        "start_monotonic_seconds": steady[0][1], "end_monotonic_seconds": steady[-1][1], "deltas": delta,
        "scope": "Interior of the fixed fixture's +5s..+20s steady phase; arrival/completion effects absent"}}
    if clock_enabled:
        closed = []
        for label in ("07-both-closed-after-probe", "08-closed-after-five-more-seconds"):
            matches = [point for point in report["checkpoints"] if point["label"] == label]
            require(len(matches) == 1, "Frame-clock closed cancellation checkpoints are incomplete")
            point = matches[0]
            timestamp = boundary(point)
            snapshot = point["snapshot"]
            require(snapshot.get("dashboard_visible") is False and snapshot.get("popover_visible") is False
                    and snapshot.get("active_requests") == 0, "Frame-clock cancellation checkpoint is not closed and idle")
            closed.append((point, timestamp))
        require(closed[1][1] - closed[0][1] >= 5, "Frame-clock closed cancellation interval is shorter than five seconds")
        require(closed[0][0]["snapshot"]["rail_frame_clock_ticks"] >= points[-1]["snapshot"]["rail_frame_clock_ticks"]
                and closed[0][0]["snapshot"]["rail_frame_clock_ticks"] == closed[1][0]["snapshot"]["rail_frame_clock_ticks"],
                "Canvas frame clock continued ticking after both windows closed")
        result["closed"] = {"start_checkpoint": closed[0][0]["label"], "end_checkpoint": closed[1][0]["label"],
            "start_monotonic_seconds": closed[0][1], "end_monotonic_seconds": closed[1][1], "rail_frame_clock_ticks_delta": 0}
    if mode == memory.NO_ARRIVAL_MODE:
        arrival = report["phase_windows"]["arrival"]
        ends = [(point, timestamp) for point, timestamp in zip(points, timestamps)
                if arrival["end_monotonic_seconds"] <= timestamp < window["start_monotonic_seconds"]]
        require(timestamps[0] <= arrival["start_monotonic_seconds"] and ends
                and ends[0][0]["snapshot"].get("active_requests") == 2,
                "No-arrival drawing evidence does not bracket the complete arrival phase")

        def effect_delta(first, last):
            def draws(point):
                return memory.unsigned(point["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"].get("draws"),
                                       "graphics.rail_decorations.draws")
            return {"rail_frame_clock_ticks": last["snapshot"]["rail_frame_clock_ticks"] - first["snapshot"]["rail_frame_clock_ticks"],
                    "rail_decorations_draws": draws(last) - draws(first)}

        arrival_delta = effect_delta(points[0], ends[0][0])
        suppressed_first = memory.unsigned(points[0]["snapshot"].get("suppressed_arrival_effects"), "arrival.start.suppressed_arrival_effects")
        suppressed_last = memory.unsigned(ends[0][0]["snapshot"].get("suppressed_arrival_effects"), "arrival.end.suppressed_arrival_effects")
        arrival_delta["suppressed_arrival_effects"] = suppressed_last - suppressed_first
        require(arrival_delta["rail_frame_clock_ticks"] == arrival_delta["rail_decorations_draws"] == 0
                and arrival_delta["suppressed_arrival_effects"] > 0,
                "No-arrival control did not suppress arrival drawing and clock work")
        completion = report["phase_windows"]["completion"]
        began = [(point, timestamp) for point, timestamp in zip(points, timestamps) if point["label"] == "completion-begin"]
        require(len(began) == 1 and completion["start_monotonic_seconds"] <= began[0][1] < completion["end_monotonic_seconds"],
                "No-arrival control lacks an authenticated completion-start checkpoint inside the phase")
        completed = [(point, timestamp) for point, timestamp in zip(points, timestamps)
                     if began[0][1] <= timestamp <= completion["end_monotonic_seconds"]]
        require(len(completed) >= 2 and all(point["snapshot"].get("active_requests") == 0 for point, _ in completed),
                "No-arrival control lacks interior completion drawing checkpoints")
        completion_delta = effect_delta(completed[0][0], completed[-1][0])
        require(completion_delta["rail_frame_clock_ticks"] > 0 and completion_delta["rail_decorations_draws"] > 0,
                "No-arrival control did not preserve completion drawing and clock work")
        result["arrival_effects"] = {
            "arrival": {"start_checkpoint": points[0]["label"], "end_checkpoint": ends[0][0]["label"],
                "start_monotonic_seconds": timestamps[0], "end_monotonic_seconds": ends[0][1], "deltas": arrival_delta,
                "scope": "Authenticated checkpoint superset of the complete first-output through +2s arrival phase"},
            "completion": {"start_checkpoint": completed[0][0]["label"], "end_checkpoint": completed[-1][0]["label"],
                "start_monotonic_seconds": completed[0][1], "end_monotonic_seconds": completed[-1][1], "deltas": completion_delta,
                "scope": "Authenticated checkpoint interval inside the three-second completion phase"}}
    return result


def phase_windows(report):
    runtime = report["runtime"]
    points = runtime["checkpoints"]
    require(points and points[0]["label"] == "before-traffic" and points[-1]["label"] == "completion-end",
            "Runtime phase endpoints are incomplete")
    gaps = [b["python_monotonic_seconds"] - a["python_monotonic_seconds"] for a, b in zip(points, points[1:])]
    require(all(0 < gap <= 2 for gap in gaps), "Runtime visibility checkpoint coverage has a gap")
    for point in points:
        snapshot, sample = point["snapshot"], point["resource_sample"]
        require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True,
                "Runtime checkpoint visibility is incomplete")
        require(sample.get("process_id") == report["owned_identity"]["process_id"]
                and sample.get("birth_time_us") == report["owned_identity"]["birth_time_us"], "Runtime checkpoint process identity differs")
        matches = [value for value in report["samples"] if value["monotonic_seconds"] == snapshot.get("runner_collector_sample_monotonic_seconds")]
        require(len(matches) == 1 and matches[0] == sample, "Runtime checkpoint lacks its exact unique kernel boundary")
    clocks = runtime["mach_clock_start"], runtime["mach_clock_end"]
    offsets = [clock["absolute_minus_monotonic_seconds"] for clock in clocks]
    require(all(0 <= clock["uncertainty_seconds"] <= .000001 for clock in clocks)
            and abs(offsets[0] - offsets[1]) <= .000001, "Runtime Mach clock bridge is imprecise or drifted")
    offset = sum(offsets) / 2
    streams = report["workload"]["fixture_status"]["timing"]["streams"]
    require(len(streams) == 2, "Runtime workload lacks both stream timing records")
    first = min(stream["first_write_started_monotonic_seconds"] for stream in streams)
    terminal = min(stream["terminal_write_started_monotonic_seconds"] for stream in streams)
    left = points[0]["resource_sample"]["mach_absolute_seconds"] - offset
    right = points[-1]["resource_sample"]["mach_absolute_seconds"] - offset
    require(left < first < first + 20 < terminal < terminal + 3 <= right,
            "Runtime capture does not contain arrival, steady traffic, and three seconds of completion")
    return {name: {"start_monotonic_seconds": start, "end_monotonic_seconds": end} for name, start, end in (
        ("arrival", first, first + 2), ("steady", first + 5, first + 20),
        ("completion", terminal, terminal + 3), ("whole_contiguous_runtime", left, right))}


def phase_cpu(report, windows):
    problems = app.sample_validation_problems(report["samples"])
    require(not problems["shared"] and not problems["cpu_seconds"], "Runtime phase CPU samples are invalid")
    clock = report["runtime"]
    offset = sum(clock[name]["absolute_minus_monotonic_seconds"] for name in ("mach_clock_start", "mach_clock_end")) / 2
    from runtime_time_profile import clock_mapping, validate_kernel_samples
    # The dummy wall origin is used only to reuse paired-clock validation; no
    # trace timestamp enters an unprofiled measurement.
    anchor = {"monotonic_before_ns": 1, "monotonic_after_ns": 1, "wall_time_ns": 1,
              **{name: clock[name] for name in ("mach_clock_start", "mach_clock_end")}}
    mapping = clock_mapping({"start_epoch_ns": 1, "duration_seconds": 1}, anchor)
    samples, birth = validate_kernel_samples(report["samples"], report["owned_identity"]["process_id"], mapping)
    require(birth == report["owned_identity"]["birth_time_us"], "Runtime kernel samples differ from owned process birth")
    result = {}
    for name, window in windows.items():
        require(clock["mach_clock_start"]["monotonic_seconds"] <= window["start_monotonic_seconds"]
                < window["end_monotonic_seconds"] <= clock["mach_clock_end"]["monotonic_seconds"],
                "Runtime phase is outside its paired Mach clock bridges")
        metrics = app.cpu_interval_metrics(samples, window["start_monotonic_seconds"] + offset,
                                           window["end_monotonic_seconds"] + offset)
        result[name] = {**metrics, "average_cpu_percent": 100 * metrics["cpu_seconds"] / metrics["elapsed_seconds"],
                        "acceptance_eligible": not report["runtime"].get("profiled", False)}
    return result


class RuntimeCollector(app.Collector):
    def __init__(self, *args, owner, **kwargs):
        self.owner = owner
        super().__init__(*args, **kwargs)

    def wait_until(self, end):
        while time.monotonic() < end:
            self.receive(min(.1, max(.001, end - time.monotonic())))
            require(not self.exited, "Owned app exited during runtime attribution")
            self.owner.poll_runtime()


class RuntimeDiagnostic(memory.MemoryDiagnostic):
    def __init__(self, *args, profile=False, **kwargs):
        super().__init__(*args, no_native_inspection=True, **kwargs)
        self.profile_enabled = profile
        self.recorder = self.record_log = None
        self.tracking = False
        self.completing = False
        self.next_checkpoint = None
        self.runtime = {"profiled": profile, "checkpoints": [], "profiler_status": "not-started",
                        "cpu_comparison_available": not profile}
        self.report["runtime"] = self.runtime
        self.trace = self.output / "cpu.trace"

    def create_collector(self, *args, **kwargs):
        return RuntimeCollector(*args, owner=self, **kwargs)

    def runtime_checkpoint(self, label):
        self.verify_identity()
        snapshot = self.collector.snapshot()
        self.verify_identity()
        matches = [s for s in self.collector.samples if s["monotonic_seconds"] == snapshot.get("runner_collector_sample_monotonic_seconds")]
        require(len(matches) == 1 and matches[0]["process_id"] == self.identity["process_id"]
                and matches[0]["birth_time_us"] == self.identity["birth_time_us"], "Runtime checkpoint lacks an owned kernel boundary")
        now = time.monotonic()
        point = {"label": label, "python_monotonic_seconds": now, "snapshot": snapshot, "resource_sample": matches[0]}
        self.runtime["checkpoints"].append(point)
        self.save()
        require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True,
                "Runtime windows are not both natively visible")
        self.validate_control_snapshot(snapshot)
        began = self.report.get("workload", {}).get("started_monotonic_seconds")
        if self.completing:
            require(snapshot.get("active_requests") == 0, "Completed runtime streams remain active")
        elif began is not None and 1 < now - began < 24:
            require(snapshot.get("active_requests") == 2 and snapshot.get("partial_output_tokens", 0) > 0,
                    "Steady runtime checkpoint lost both active streams")
            if len(self.runtime["checkpoints"]) > 1:
                previous = self.runtime["checkpoints"][-2]
                if now - previous["python_monotonic_seconds"] >= .5 and previous["snapshot"].get("active_requests") == 2:
                    require(snapshot["output_tokens"] > previous["snapshot"]["output_tokens"], "Runtime token accounting stopped")
        self.next_checkpoint = now + 1
        return point

    def poll_runtime(self):
        if self.profile_enabled and self.runtime["profiler_status"] == "recording":
            require(self.recorder.poll() is None, "Profiler stopped before completion capture")
        if self.tracking and time.monotonic() >= self.next_checkpoint:
            self.runtime_checkpoint("completion" if self.completing else "during-traffic")

    def begin_runtime(self):
        self.runtime["mach_clock_start"] = _mach_clock()
        if self.profile_enabled:
            self.begin_profile()
            self.profile_readiness_guard()
        self.tracking = True
        self.runtime_checkpoint("before-traffic")

    def profile_readiness_guard(self):
        """Collect pre-window Running samples while preserving native visibility."""
        guard = {"minimum_seconds": .5, "snapshots": []}
        self.runtime["pre_workload_profile_guard"] = guard
        for boundary in ("before", "after"):
            self.verify_identity()
            snapshot = self.collector.snapshot()
            self.verify_identity()
            require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True
                    and snapshot.get("active_requests") == 0, "Profile readiness guard lost visible idle windows")
            self.validate_control_snapshot(snapshot)
            guard["snapshots"].append({"boundary": boundary, "snapshot": snapshot})
            if boundary == "before":
                guard["start_monotonic_seconds"] = time.monotonic()
                self.collector.wait_until(guard["start_monotonic_seconds"] + .5)
        guard["end_monotonic_seconds"] = time.monotonic()
        self.save()

    def begin_profile(self):
        self.verify_identity()
        pid, birth = self.identity["process_id"], self.identity["birth_time_us"]
        require(_birth_time(pid) == birth and os.getpgid(pid) == pid, "Owned app identity changed before profile attachment")
        require(self.deadline.remaining() >= PROFILE_SAVE_SECONDS + 63, "Insufficient bounded profile and cleanup time")
        notice = _Notice()
        command = ["/usr/bin/xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(pid),
                   "--time-limit", "45s", "--notify-tracing-started", notice.name, "--output", str(self.trace), "--no-prompt"]
        before = time.monotonic_ns()
        wall = time.time_ns()
        after = time.monotonic_ns()
        self.runtime.update(record_command=command, owned_identity=self.identity,
                            clock_anchor={"monotonic_before_ns": before, "wall_time_ns": wall, "monotonic_after_ns": after})
        try:
            self.record_log = (self.output / "cpu-record.log").open("wb")
            self.recorder = subprocess.Popen(command, stdout=self.record_log, stderr=subprocess.STDOUT, start_new_session=True)
            self.runtime.update(profiler_status="starting", recorder_pid=self.recorder.pid)
            self.save()
            end = min(self.deadline.end - 8, time.monotonic() + 15)
            while time.monotonic() < end:
                require(self.recorder.poll() is None, "Profiler exited before readiness")
                if notice.ready():
                    self.runtime.update(profiler_status="recording", ready_python_monotonic_seconds=time.monotonic())
                    return
                self.collector.receive(.025)
            raise TimeoutError("Profiler readiness exceeded fifteen seconds")
        finally:
            notice.close()

    def finish_profile(self, emergency=False):
        if self.recorder is None or self.runtime["profiler_status"] in ("captured", "failed"):
            return
        try:
            require(not emergency, "Profiler capture interrupted; aborting without another save wait")
            require(self.recorder.poll() is None, "Profiler stopped before explicit completion")
            self.runtime["stop_python_monotonic_seconds"] = time.monotonic()
            self.runtime["profiler_status"] = "stopping"
            self.recorder.send_signal(signal.SIGINT)
            end = min(self.deadline.end - self.deadline.cleanup_reserve - PROFILE_POST_SAVE_SECONDS,
                      time.monotonic() + PROFILE_SAVE_SECONDS)
            self.runtime["save_deadline_monotonic_seconds"] = end
            while self.recorder.poll() is None and time.monotonic() < end:
                self.collector.receive(.1)
            if self.recorder.poll() is None:
                raise TimeoutError("Profiler did not finalize within the bounded 30-second save allowance")
            self.runtime["profiler_exit_code"] = self.recorder.returncode
            require(self.recorder.returncode == 0 and not emergency, "Profiler failed or required emergency cleanup")
            issues = read_run_issues(self.trace)
            self.runtime["recording_issues"] = issues
            require(issues["available"] and issues["lost_events"] is False and not issues["invalid"],
                    "Profiler recording is incomplete or lost events")
            require(self.trace.is_dir(), "Profiler did not finalize a trace directory")
            self.runtime["profiler_status"] = "captured"
        except (OSError, ValueError, TimeoutError) as error:
            self.runtime["profiler_status"] = "failed"
            self.report["errors"].append(str(error))
            if not emergency:
                raise
        finally:
            if self.recorder.poll() is None:
                try:
                    memory.stop_owned_child(self.recorder, self.deadline)
                except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
                    self.runtime["profiler_status"] = "failed"
                    self.report["errors"].append("Profiler cleanup: " + str(error))
            if self.record_log is not None:
                self.record_log.close()
                self.record_log = None
            self.save()

    def checkpoint(self, label, dashboard, popover, active):
        if label == "04-before-traffic":
            self.begin_runtime()
        snapshot = super().checkpoint(label, dashboard, popover, active)
        if label == "06-after-traffic":
            self.completing = True
            self.runtime_checkpoint("completion-begin")
            self.collector.wait_until(time.monotonic() + 3.01)
            self.runtime_checkpoint("completion-end")
            self.tracking = False
            self.runtime["mach_clock_end"] = _mach_clock()
            if self.profile_enabled:
                # Keep the recorded endpoint fixed, then collect a short guard
                # so Running samples can bracket that endpoint during analysis.
                self.collector.wait_until(time.monotonic() + .3)
                self.finish_profile()
        return snapshot

    def cleanup(self):
        try:
            self.finish_profile(emergency=True)
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
            self.report["errors"].append("Profiler cleanup: " + str(error))
        finally:
            try:
                # An aborted profile never reached perform()'s normal shutdown.
                # Attempt the same graceful protocol, preserving time for the
                # existing identity-checked forced cleanup if it cannot finish.
                if self.profile_enabled and self.collector is not None and not self.collector.exited:
                    end = min(self.deadline.end - 4.5, time.monotonic() + 5)
                    if end > time.monotonic():
                        try:
                            with self.deadline.interrupt_at(end):
                                self.collector.finish()
                        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
                            self.report["errors"].append("Profile app shutdown: " + str(error))
            finally:
                try:
                    super().cleanup()
                finally:
                    if self.record_log is not None:
                        self.record_log.close()
                        self.record_log = None
                    if self.profile_enabled:
                        self.report["profiled_kernel_cpu"] = self.report.get("workload_cpu")
                        self.report["workload_cpu"] = {"available": False, "gate_evaluated": False,
                            "reason": "Time Profiler perturbs execution; kernel values are attribution cross-checks only"}


def capture_case(output, mode, paths, provenance, identity, deadline, *, profile=False):
    output.mkdir()
    diagnostic = RuntimeDiagnostic(output, deadline, mode, profile=profile)
    try:
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
            diagnostic.perform(paths, provenance, identity)
    except (OSError, ValueError, KeyError, TypeError, TimeoutError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        diagnostic.report["errors"].append(str(error) or "Interrupted")
    finally:
        try:
            with deadline.interrupt_at(deadline.end - .5):
                diagnostic.cleanup()
        except (OSError, ValueError, KeyError, TypeError, TimeoutError, subprocess.SubprocessError, KeyboardInterrupt) as error:
            diagnostic.report["errors"].append("Runtime cleanup: " + (str(error) or "Interrupted"))
    report = diagnostic.report
    try:
        require(not report["errors"] and report.get("workload", {}).get("validated"), "Runtime app capture is incomplete")
        workload = report["workload"]
        require(workload["validated_work"] == WORK and app.validate_workload(
            workload["specification"], workload["fixture_status"], workload["before"], workload["after"], workload["fixture_start"]) == WORK,
            "Runtime workload differs from the fixed two-stream 25-second fixture")
        report["phase_windows"] = phase_windows(report)
        report["visual_work"] = validate_visual_work(report, required=not profile or mode in memory.RUNTIME_MODES)
        points = report["runtime"]["checkpoints"]
        report["runtime_work"] = validate_runtime_work(points[0]["snapshot"], points[-1]["snapshot"], mode, required=not profile)
        report["runtime_work"]["interval"] = {
            "scope": "whole_contiguous_runtime", "start_checkpoint": points[0]["label"],
            "end_checkpoint": points[-1]["label"], **report["phase_windows"]["whole_contiguous_runtime"]}
        report["canvas_clock_work"] = validate_canvas_clock_work(report, mode)
        report["phase_cpu"] = phase_cpu(report, report["phase_windows"])
        report["phase_cpu_comparison_available"] = not profile
        report["runtime_cpu_target"] = {"evaluated": not profile, "limit_percent": 5.0,
            "within_limit": report["phase_cpu"]["whole_contiguous_runtime"]["rolling_1s_percent"] <= 5 if not profile else None,
            "scope": "Contiguous visible traffic and completion only; separate from full resource gate"}
        if profile:
            require(report["runtime"]["profiler_status"] == "captured", "Time Profiler capture is incomplete")
        report["status"] = "diagnostic_captured"
    except (OSError, ValueError, KeyError, TypeError) as error:
        report["errors"].append(str(error))
        report["status"] = "diagnostic_incomplete"
    write_json(output / "runtime-case.json", report)
    return report


def selected_cases(args):
    if args.operation == "profile":
        return [("profile", args.graphics_mode)]
    controls = args.controls or ["runtime-optimized"]
    require(1 <= len(controls) <= 3 and len(set(controls)) == len(controls), "Select one to three distinct runtime controls")
    return [("baseline-before", args.baseline_mode), *[(mode, mode) for mode in controls], ("baseline-after", args.baseline_mode)]


def baseline_drift(cases):
    before, after = cases[0]["phase_cpu"]["whole_contiguous_runtime"], cases[-1]["phase_cpu"]["whole_contiguous_runtime"]
    checks = {}
    for key in ("average_cpu_percent", "rolling_1s_percent"):
        absolute = abs(after[key] - before[key])
        relative = absolute / max(before[key], after[key]) if max(before[key], after[key]) else 0
        checks[key] = {"absolute_percentage_points": absolute, "relative_difference": relative,
                       "drifted": absolute > .5 and relative > .2}
    return {"comparison_conclusive": not any(value["drifted"] for value in checks.values()),
            "policy": "Inconclusive if either baseline mean or maximum differs by more than 20% AND 0.5 percentage points",
            "checks": checks}


def summary(report):
    lines = ["# Runtime CPU attribution", "", f"Status: `{report['status']}`. No full performance-gate pass is implied.", "",
             "| Case | CPU evidence | Whole runtime mean | Whole runtime max rolling 1s | CPU ≤5% | Peak footprint (MB) |",
             "|---|---|---:|---:|---|---:|"]
    for case in report["cases"]:
        cpu = (case.get("phase_cpu") or {}).get("whole_contiguous_runtime", {})
        eligible = report["operation"] != "profile" and bool(cpu)
        fmt = lambda key: f"{cpu[key]:.3f}%" if eligible else "unavailable"
        peak = case.get("peak_footprint_bytes")
        target = case.get("runtime_cpu_target") or {}
        outcome = str(target.get("within_limit")).lower() if target.get("evaluated") else "not evaluated"
        lines.append(f"| {case['label']} | {'profiled attribution only' if report['operation'] == 'profile' else 'unprofiled kernel counters'} | "
                     f"{fmt('average_cpu_percent')} | {fmt('rolling_1s_percent')} | {outcome} | {peak / 1e6 if peak is not None else 'unavailable'} |")
    lines += ["", "Whole runtime includes fixture start/end and the three-second visible completion tail. Arrival, steady, completion, and whole-runtime windows are stored separately; selected phase windows must not be summed. GPU and filesystem-write gates are separate."]
    if report["operation"] == "profile" and report.get("native_capture_complete"):
        lines += ["", "Native capture: complete. Attribution analysis: `" + report.get("attribution_status", "incomplete") + "`."]
        if report.get("analysis_pending_reasons"):
            lines += ["Quantitative CPU attribution is unavailable; raw sample weights and rankings are retained without rescaling.", "",
                      *["- " + reason for reason in report["analysis_pending_reasons"]]]
    if "baseline_drift" in report:
        lines += ["", "Comparison conclusive: " + str(report["baseline_drift"]["comparison_conclusive"]).lower() + ". " + report["baseline_drift"]["policy"]]
    if report["errors"]:
        lines += ["", *["- " + error.replace("\n", " ") for error in report["errors"]]]
    return "\n".join(lines) + "\n"


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("operation", choices=("profile", "compare"))
    for name in ("app-binary", "test-bundle", "collector-binary", "provenance"):
        result.add_argument("--" + name, required=True, type=Path)
    result.add_argument("--graphics-mode", choices=BASELINES + memory.RUNTIME_MODES, default="normal")
    result.add_argument("--baseline-mode", choices=BASELINES, default="native-gpu-optimized")
    result.add_argument("--controls", nargs="+", choices=memory.RUNTIME_MODES + ("normal",))
    result.add_argument("--output-dir", type=Path)
    return result


def run(argv=None):
    args = parser().parse_args(argv)
    deadline = RuntimeDeadline()
    try:
        with deadline.interrupt_at(deadline.end):
            return _run(args, deadline)
    except TimeoutError as error:
        print(str(error), flush=True)
        return 1


def _run(args, deadline):
    output = (args.output_dir or app.ROOT / ".performance-results" /
              ("runtime-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S-") + secrets.token_hex(4))).resolve()
    output_created = False
    report = {"kind": "runtime-cpu-attribution", "operation": args.operation, "status": "diagnostic_incomplete",
              "deadline_seconds": MAX_SECONDS, "regression_passed": False, "cases": [], "errors": []}
    try:
        cases = selected_cases(args)
        require(sys.platform == "darwin", "Runtime attribution requires macOS")
        require(not output.exists(), "Never overwrite runtime attribution artifacts")
        require(app.ROOT not in output.parents or app.ROOT / ".performance-results" in output.parents,
                "In-repository runtime artifacts must remain ignored")
        output.mkdir(parents=True)
        output_created = True
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
            sources = runtime_source_identity()
        report["runtime_source_identity"] = sources
        capsule = output / "measurement-source"
        capsule.mkdir()
        for name in sources:
            shutil.copyfile(Path(__file__).with_name(name), capsule / name)
            require(app.path_hash(capsule / name) == sources[name], "Runtime source changed while archiving its capsule")
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
            paths, provenance, identity = memory.validate_products(args)
            report.update(binary_identity={name: app.path_hash(path) for name, path in paths.items()}, measurement_identity=identity)
        for label, mode in cases:
            seconds = PROFILE_SECONDS if args.operation == "profile" else CASE_SECONDS
            require(deadline.remaining() >= seconds + 3, "Insufficient remaining time for a complete runtime case")
            require(runtime_source_identity() == sources, "Runtime measurement sources changed during the comparison")
            require(all(app.path_hash(path) == report["binary_identity"][name] for name, path in paths.items()),
                    "Frozen products changed during runtime comparison")
            print(f"Runtime case {len(report['cases']) + 1}/{len(cases)}: {label} ({mode}); remaining {deadline.remaining():.1f}s", flush=True)
            case_deadline = RuntimeDeadline(seconds, cleanup_reserve=8)
            directory = output / label
            case = capture_case(directory, mode, paths, provenance, identity, case_deadline, profile=args.operation == "profile")
            row = {"label": label, "mode": mode, "status": case["status"], "report_path": str(directory / "runtime-case.json"),
                   "report_sha256": app.path_hash(directory / "runtime-case.json"), "workload_cpu": case.get("workload_cpu"),
                   "phase_cpu": case.get("phase_cpu"), "runtime_work": case.get("runtime_work"),
                   "visual_work": case.get("visual_work"),
                   "runtime_cpu_target": case.get("runtime_cpu_target"),
                   "peak_footprint_bytes": (case.get("samples") or [{}])[-1].get("lifetime_peak_footprint_bytes")}
            report["cases"].append(row)
            whole = (row.get("phase_cpu") or {}).get("whole_contiguous_runtime", {})
            print(f"  {case['status']}: whole-runtime CPU mean={whole.get('average_cpu_percent', 'unavailable')}%, max={whole.get('rolling_1s_percent', 'unavailable')}%" +
                  (" (profiled attribution only)" if args.operation == "profile" else ""), flush=True)
            write_json(output / "runtime-report.json", report)
            require(case["status"] == "diagnostic_captured", f"Runtime case {label} is incomplete: {case['errors']}")
            if args.operation == "compare":
                require(row["visual_work"] == report["cases"][0]["visual_work"],
                        "Runtime comparison cases did not execute identical deterministic visual requests")
            if args.operation == "profile":
                report["native_capture_complete"] = True
                from runtime_time_profile import analyze_trace
                runtime = case["runtime"]
                anchor = runtime["clock_anchor"] | {name: runtime[name] for name in ("mach_clock_start", "mach_clock_end")}
                with deadline.interrupt_at(deadline.end - 5):
                    report["attribution"] = analyze_trace(directory / "cpu.trace", directory, case["owned_identity"]["process_id"],
                        case["phase_windows"], anchor, case["samples"], deadline)
                attribution = report["attribution"]
                report["attribution_status"] = attribution.get("status")
                require(attribution.get("status") in ("analysis_pending", "profiled_phase_attribution_available"),
                        "Time Profiler analysis returned an unknown completion status")
                quality = attribution.get("analysis_quality", {})
                require(type(quality.get("quantitative_attribution_usable")) is bool
                        and quality["quantitative_attribution_usable"] == (attribution["status"] == "profiled_phase_attribution_available"),
                        "Time Profiler analysis status and quantitative quality disagree")
                if attribution["status"] == "analysis_pending":
                    reasons = []
                    if quality.get("sample_kernel_mismatch_phases"):
                        reasons.append("Sampled CPU and same-window kernel CPU disagree beyond the diagnostic tolerance in: "
                                       + ", ".join(quality["sample_kernel_mismatch_phases"]) + ".")
                    if quality.get("all_selected_symbols_missing"):
                        reasons.append("All selected samples lack usable symbols.")
                    report["analysis_pending_reasons"] = reasons or ["Time Profiler quantitative attribution quality is unavailable."]
        if args.operation == "compare":
            report["baseline_drift"] = baseline_drift(report["cases"])
        require(runtime_source_identity() == sources, "Runtime measurement sources changed before finalization")
        require(time.monotonic() < deadline.end - 1, "Runtime attribution exceeded its 300-second deadline")
        report["status"] = ("analysis_pending" if args.operation == "profile"
                            and report.get("attribution_status") == "analysis_pending" else "diagnostic_captured")
    except (OSError, ValueError, KeyError, TypeError, TimeoutError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        report["errors"].append(str(error) or "Interrupted")
    if output_created:
        try:
            with deadline.interrupt_at(deadline.end):
                report["elapsed_seconds"] = MAX_SECONDS - (deadline.end - time.monotonic())
                # Publish captured status only after the review table is durable.
                desired_status = report["status"]
                report["status"] = "diagnostic_incomplete"
                write_json(output / "runtime-report.json", report)
                report["status"] = desired_status
                (output / "SUMMARY.md").write_text(summary(report), encoding="utf-8")
                write_json(output / "runtime-report.json", report)
        except (OSError, ValueError, TimeoutError) as error:
            report["status"] = "diagnostic_incomplete"
            report["errors"].append("Artifact finalization: " + str(error))
    print(f"Runtime attribution: {report['status']}. Artifacts: {output}", flush=True)
    return 0 if report["status"] == "diagnostic_captured" else 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, memory.interrupted)
    raise SystemExit(run())
