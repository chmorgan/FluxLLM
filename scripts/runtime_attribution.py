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
# Three-case diagnostics have additional startup/cleanup margin inside MAX_SECONDS.
THREE_CASE_SECONDS = 70
NIO_CASE_SECONDS = THREE_CASE_SECONDS
PROFILE_SECONDS = 120
PROFILE_SAVE_SECONDS = 30
PROFILE_POST_SAVE_SECONDS = 18
WORK = {"chunks": 10000, "output_tokens": 20034, "prompt_tokens": 46,
        "requests": 2, "tool_calls": 2, "tool_results": 2}
COUNTERS = ("optimized_chart_preparations", "history_tool_order_builds", "history_completed_order_builds",
            "history_tool_order_insertions", "history_completed_order_insertions", "chart_preparations")
TOOL_TRACE_COUNTERS = ("unique_tool_trace_builds", "reused_tool_trace_builds")
BASELINES = ("native-gpu-optimized", "runtime-optimized", "normal", memory.ORDERED_PUBLICATION_MODE)


def cpu_acceptance_eligible(mode, *, profile=False):
    return not profile and mode not in (memory.HELD_STATIC_CHART_MODE, *memory.METAL_CHART_MODES)


def held_static_chart_work(before, after, mode):
    """Prove a drawing-only ablation while full-rate preparation still executes."""
    if mode != memory.HELD_STATIC_CHART_MODE:
        return None
    first = memory.held_static_chart_counts(before.get("graphics_diagnostics", {}), mode)["static_chart"]
    last = memory.held_static_chart_counts(after.get("graphics_diagnostics", {}), mode)["static_chart"]
    for snapshot in (before, after):
        require(memory.chart_publication_interval(snapshot.get("graphics_diagnostics", {}), mode) == 1.0,
                "Held static drawing must preserve one-second chart publication")
        require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True,
                "Held static drawing requires both visible native windows")
    require(all(last[field] >= first[field] for field in memory.HELD_STATIC_CHART_COUNTERS),
            "Held static chart drawing counter moved backwards")
    delta = {field: last[field] - first[field] for field in memory.HELD_STATIC_CHART_COUNTERS}
    before_role, after_role = (snapshot["graphics_diagnostics"]["roles"]["static_chart"] for snapshot in (before, after))
    require(first["drawing_updates_applied"] > 0 and memory.unsigned(before_role.get("draws"), "held.initial_draws") > 0,
            "Held static chart lacks an applied and drawn frame before traffic")
    for field in ("draws", "created", "destroyed"):
        require(memory.unsigned(after_role.get(field), "held.after." + field)
                == memory.unsigned(before_role.get(field), "held.before." + field),
                "Held static chart redrew or changed its host during the workload")
    require(delta["drawing_updates_applied"] == delta["drawing_hold_resets"] == 0,
            "Held static chart applied an update or reset during the workload")
    require(delta["drawing_update_attempts"] == delta["drawing_updates_held"] > 0,
            "Held static chart did not hold positive drawing update attempts")
    times = [memory.number(snapshot.get("runner_collector_sample_monotonic_seconds"), "held.boundary")
             for snapshot in (before, after)]
    require(times[1] > times[0], "Held static chart lacks ordered authenticated runtime boundaries")
    preparation_delta = (memory.unsigned(after.get("chart_preparations"), "held.after.chart_preparations")
                         - memory.unsigned(before.get("chart_preparations"), "held.before.chart_preparations"))
    # Two endpoint ticks of allowance cover publication scheduling and the
    # asynchronously acknowledged control boundaries, without permitting a
    # stopped or substantially reduced chart-preparation cadence.
    minimum = max(1, math.floor(times[1] - times[0]) - 2)
    require(preparation_delta >= minimum,
            "Held static chart did not preserve one-second chart preparation work")
    return {"available": True, "acceptance_eligible": False, "drawing_only_control": True,
            "initial_static_draws": before_role["draws"], "static_draws_delta": 0, "deltas": delta,
            "chart_preparations_delta": preparation_delta, "minimum_chart_preparations": minimum,
            "chart_publication_interval_seconds": 1.0}


def validate_held_static_chart_checkpoints(report, mode):
    if mode != memory.HELD_STATIC_CHART_MODE:
        return None
    points = report["runtime"]["checkpoints"]
    require(len(points) >= 2, "Held static chart lacks runtime checkpoints")
    snapshots = [point["snapshot"] for point in points]
    initial = snapshots[0]
    result = held_static_chart_work(initial, snapshots[-1], mode)
    initial_role = initial["graphics_diagnostics"]["roles"]["static_chart"]
    previous = memory.held_static_chart_counts(initial["graphics_diagnostics"], mode)["static_chart"]
    for snapshot in snapshots[1:]:
        role = snapshot["graphics_diagnostics"]["roles"]["static_chart"]
        counters = memory.held_static_chart_counts(snapshot["graphics_diagnostics"], mode)["static_chart"]
        require(all(counters[field] >= previous[field] for field in memory.HELD_STATIC_CHART_COUNTERS),
                "Held static drawing counters moved backwards at an interior checkpoint")
        require(all(role.get(field) == initial_role.get(field) for field in
                    ("draws", "created", "destroyed", "drawing_updates_applied", "drawing_hold_resets")),
                "Held static chart changed drawing or host state at an interior checkpoint")
        previous = counters
    return result


def validate_steady_twinkle_delivery(report, mode):
    """Authenticate native delivery during effect-free steady streaming only."""
    points = report["runtime"]["checkpoints"]
    contracts = [memory.twinkle_delivery_contract(point["snapshot"], mode) for point in points]
    if all(contract is None for contract in contracts):
        return {"available": False, "reason": "Frozen product predates direct retained twinkle delivery counters"}
    require(contracts and all(contract is not None for contract in contracts),
            "Twinkle delivery instrumentation changed or disappeared during runtime")
    enabled = contracts[0]["enabled"]
    require(all(contract["enabled"] == enabled for contract in contracts), "Twinkle delivery backend changed during runtime")
    for first, last in zip(contracts, contracts[1:]):
        require(all(last["counters"][field] >= first["counters"][field] for field in memory.TWINKLE_DELIVERY_COUNTERS),
                "Twinkle delivery counters moved backwards during runtime")
    if not enabled:
        return {"available": True, "enabled": False, "reason": "This mode does not use retained twinkles"}
    clocks = report["runtime"]
    offset = sum(clocks[name]["absolute_minus_monotonic_seconds"] for name in ("mach_clock_start", "mach_clock_end")) / 2
    window = report["phase_windows"]["steady"]
    interior = []
    for point, contract in zip(points, contracts):
        snapshot, sample = point["snapshot"], point["resource_sample"]
        matches = [row for row in report["samples"]
                   if row["monotonic_seconds"] == snapshot.get("runner_collector_sample_monotonic_seconds")]
        require(len(matches) == 1 and matches[0] == sample
                and sample["process_id"] == report["owned_identity"]["process_id"]
                and sample["birth_time_us"] == report["owned_identity"]["birth_time_us"],
                "Twinkle delivery checkpoint lacks its authenticated kernel boundary")
        timestamp = sample["mach_absolute_seconds"] - offset
        if window["start_monotonic_seconds"] < timestamp < window["end_monotonic_seconds"]:
            require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True
                    and snapshot.get("active_requests") == 2,
                    "Steady twinkle delivery requires both visible windows and two active streams")
            interior.append((point, contract, timestamp))
    require(len(interior) >= 2 and interior[-1][2] - interior[0][2] >= 2,
            "Steady twinkle delivery lacks two seconds of authenticated interior checkpoints")
    first, last = interior[0], interior[-1]
    delta = {field: last[1]["counters"][field] - first[1]["counters"][field]
             for field in memory.TWINKLE_DELIVERY_COUNTERS}
    require(delta["retained_twinkle_direct_updates"] > 0,
            "Steady retained twinkles did not execute native direct deliveries")
    require(delta["twinkle_state_publications"] == 0,
            "Steady retained twinkles still published SwiftUI state")
    return {"available": True, "enabled": True, "start_checkpoint": first[0]["label"], "end_checkpoint": last[0]["label"],
            "start_monotonic_seconds": first[2], "end_monotonic_seconds": last[2],
            "start_resource_sample": first[0]["resource_sample"], "end_resource_sample": last[0]["resource_sample"],
            "deltas": delta, "scope": "Authenticated visible two-stream checkpoints strictly inside the steady phase; no CPU qualification change"}


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
    names = {"runtime_attribution.py", "runtime_time_profile.py", "runtime_thread_cpu.py", "runtime_nio_cpu.py", "memory_attribution.py", "app_performance.py",
             "run_performance_checks.py", "performance_fixture.py", "performance_gpu_sample.py"}
    names.update(path.name for path in Path(__file__).parent.glob("performance_trace*.py"))
    return {name: app.path_hash(Path(__file__).with_name(name)) for name in sorted(names)}


def runtime_product_identity(paths, provenance):
    """Pin validated executables, bundles, and the exact provenance file."""
    files = dict(paths)
    if provenance.get("provenance_file"):
        files["provenance"] = Path(provenance["provenance_file"])
    for name in provenance.get("resource_bundle_sha256", {}):
        files["resource:" + name] = paths["app"].parent / name
    return {name: {"path": str(path), "sha256": app.path_hash(path)} for name, path in files.items()}


def validate_runtime_work(before, after, mode, *, required=True):
    instrumented_tool_traces = any(field in snapshot for snapshot in (before, after) for field in TOOL_TRACE_COUNTERS)
    flags = memory.runtime_feature_contract(after.get("graphics_diagnostics", {}), mode)
    initial = memory.runtime_feature_contract(before.get("graphics_diagnostics", {}), mode)
    if flags is None and not required and mode == "normal" and not instrumented_tool_traces:
        return {"available": False, "reason": "Frozen normal predates runtime-control counters"}
    require(flags is not None and set(memory.RUNTIME_FLAGS) <= set(flags) and flags == initial,
            "Runtime workload lacks a stable complete feature contract")
    publication_interval = memory.chart_publication_interval(after.get("graphics_diagnostics", {}), mode)
    require(publication_interval == memory.chart_publication_interval(before.get("graphics_diagnostics", {}), mode),
            "Runtime chart publication interval metadata changed or disappeared")
    metal_first = memory.metal_arrival_contract(before, mode)
    metal_last = memory.metal_arrival_contract(after, mode)
    require((metal_first is None) == (metal_last is None)
            and (metal_first is None or metal_first["arrival_backend"] == metal_last["arrival_backend"]),
            "Runtime arrival backend metadata changed or disappeared")
    delta = {}
    full_first = memory.metal_full_chart_contract(before, mode)
    full_last = memory.metal_full_chart_contract(after, mode)
    require((full_first is None) == (full_last is None), "Full Metal chart instrumentation changed during runtime")
    full_delta = None
    if mode in memory.METAL_CHART_MODES:
        full_counters = memory.METAL_FULL_CHART_COUNTERS + (memory.METAL_CACHE_COUNTERS
                        if mode == memory.METAL_CACHED_CHART_MODE else ())
        full_delta = {field: full_last["counters"][field] - full_first["counters"][field]
                      for field in full_counters}
        require(all(count >= 0 for count in full_delta.values()), "Full Metal chart work counters moved backwards")
        required_metal_work = ("geometry_uploads", "submissions", "static_frames", "arrival_frames", "completion_frames")
        if mode == memory.METAL_FULL_CHART_MODE:
            required_metal_work += ("twinkle_frames",)
        require(all(full_delta[field] > 0 for field in required_metal_work),
                "Full Metal chart runtime did not submit all static and animation work")
    if metal_first is not None:
        for field in memory.METAL_ARRIVAL_COUNTERS:
            first, last = metal_first["counters"][field], metal_last["counters"][field]
            require(last >= first, f"Runtime {field} counter moved backwards")
            delta[field] = last - first
        if mode == memory.METAL_ARRIVAL_MODE:
            require(delta["metal_arrival_frames"] == delta["metal_arrival_submissions"] > 0,
                    "Runtime Metal arrival path did not submit rendered frames")
    for field in COUNTERS:
        first = memory.unsigned(before.get(field), f"runtime.before.{field}")
        last = memory.unsigned(after.get(field), f"runtime.after.{field}")
        require(last >= first, f"Runtime {field} counter moved backwards")
        delta[field] = last - first
    require(delta["chart_preparations"] > 0, "Runtime workload did not prepare charts")
    if mode == memory.METAL_CACHED_CHART_MODE:
        require(0 < full_delta["static_rasterizations"] < full_delta["static_cache_composites"],
                "Cached Metal runtime did not reuse rendered static pixels")
        allowance = max(full_first["counters"]["live_hosts"], full_last["counters"]["live_hosts"])
        require(full_delta["scene_unclassified_revisions"] == 0,
                "Cached Metal runtime has unclassified static scene revisions")
        require(sum(full_delta[field] for field in memory.METAL_SCENE_REVISION_CAUSES)
                >= full_delta["static_scene_revisions"],
                "Cached Metal runtime scene revisions lack explicit invalidation causes")
        require(full_delta["static_rasterizations"] <= full_delta["static_scene_revisions"]
                + full_delta["static_surface_invalidations"] + allowance,
                "Cached Metal rasterization exceeds recorded scene and surface invalidations plus boundary updates")
    if (mode in (memory.COMPACT_TOOL_PATHS_MODE,) + memory.DEFERRED_TOOL_GEOMETRY_MODES or "compact_tool_paths_enabled" in flags
            or any(field in snapshot for snapshot in (before, after) for field in memory.TOOL_PATH_POINT_COUNTERS)):
        require("compact_tool_paths_enabled" in flags, "Tool-path point counters lack feature metadata")
        first, last = memory.tool_path_point_counts(before), memory.tool_path_point_counts(after)
        for field in memory.TOOL_PATH_POINT_COUNTERS:
            require(last[field] >= first[field], f"Runtime {field} counter moved backwards")
            delta[field] = last[field] - first[field]
        if flags["compact_tool_paths_enabled"]:
            require(0 < delta["tool_path_output_points"] < delta["tool_path_input_points"],
                    "Compact tool paths did not execute positive vertex reduction during runtime")
        else:
            require(first["tool_path_output_points"] == first["tool_path_input_points"]
                    and last["tool_path_output_points"] == last["tool_path_input_points"],
                    "Noncompact tool paths changed the input vertex count")
            if mode in ("normal", memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES:
                require(delta["tool_path_input_points"] > 0, "Noncompact tool paths did not execute vertex construction")
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
            if mode in memory.METAL_CHART_MODES:
                require(delta["grouped_native_canvas_draws"] == 0, "Full Metal chart executed grouped Canvas callbacks")
            else:
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
    if instrumented_tool_traces:
        require(all(field in delta for field in memory.DIRECT_TOOL_PLOT_COUNTERS),
                "Shared tool trace counters lack matching tool-plot build counters")
        for field in TOOL_TRACE_COUNTERS:
            first, last = before.get(field), after.get(field)
            require(all(type(value) is int and 0 <= value <= 2**64 - 1 for value in (first, last)),
                    f"Runtime {field} requires UInt64 counters in both snapshots")
            require(last >= first, f"Runtime {field} counter moved backwards")
            delta[field] = last - first
        require(sum(delta[field] for field in TOOL_TRACE_COUNTERS)
                == sum(delta[field] for field in memory.DIRECT_TOOL_PLOT_COUNTERS),
                "Unique and reused tool trace builds do not reconcile with tool-plot builds")
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
    held_work = held_static_chart_work(before, after, mode)
    if held_work is None and mode not in memory.METAL_CHART_MODES:
        require(delta["static_chart_draws"] > 0, "Runtime static charts did not redraw")
    if flags.get("canvas_frame_clock", False):
        minimum_draws = max(1, math.floor(.8 * delta["rail_frame_clock_ticks"]) - 2)
        require(delta["rail_decorations_draws"] >= minimum_draws,
                "Canvas frame ticks did not produce sufficient native decoration draws")
    if not flags["lifecycle_effects_enabled"]:
        require(delta["rail_decorations_draws"] == 0, "No-lifecycle control still drew lifecycle decorations")
    return {"available": True, "features": flags, "deltas": delta,
            **({"metal_full_chart_deltas": full_delta, "promotion_eligible": False,
                "promotion_reason": "Experimental renderer requires independent visual fidelity qualification"}
               if full_delta is not None else {}),
            **({"held_static_chart_work": held_work} if held_work is not None else {}),
            **({"arrival_backend": metal_last["arrival_backend"]} if metal_last is not None else {}),
            **({"chart_publication_interval_seconds": publication_interval} if publication_interval is not None else {})}


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


def validate_metal_full_chart_work(report, mode, *,
                                  closed_labels=("07-both-closed-after-probe", "08-closed-after-five-more-seconds"),
                                  minimum_closed_seconds=5, boundary=None):
    """Keep workload, native visibility, phase, and cancellation proofs for Metal."""
    if mode not in memory.METAL_CHART_MODES:
        return None
    cached = mode == memory.METAL_CACHED_CHART_MODE
    cumulative = memory.METAL_FULL_CHART_COUNTERS + (memory.METAL_CACHE_COUNTERS if cached else ())
    points = report["runtime"]["checkpoints"]
    require(len(points) >= 2, "Full Metal chart lacks runtime checkpoints")
    if boundary is None:
        clocks = report["runtime"]
        offset = sum(clocks[name]["absolute_minus_monotonic_seconds"] for name in ("mach_clock_start", "mach_clock_end")) / 2

        def boundary(point):
            snapshot, sample = point["snapshot"], point["resource_sample"]
            matches = [row for row in report["samples"]
                       if row["monotonic_seconds"] == snapshot.get("runner_collector_sample_monotonic_seconds")]
            require(len(matches) == 1 and matches[0] == sample
                    and all(sample.get(field) == report["owned_identity"][field]
                            for field in ("process_id", "birth_time_us")),
                    "Full Metal chart checkpoint lacks its authenticated kernel boundary")
            return sample["mach_absolute_seconds"] - offset

    initial_flags = memory.runtime_feature_contract(points[0]["snapshot"]["graphics_diagnostics"], mode)
    closed = []
    for label in closed_labels:
        matches = [point for point in report["checkpoints"] if point["label"] == label]
        require(len(matches) == 1, "Full Metal chart closed checkpoints are missing or duplicated")
        closed.append(matches[0])
    all_points = points + closed
    rows = []
    for index, point in enumerate(all_points):
        snapshot = point["snapshot"]
        is_closed = index >= len(points)
        require(snapshot.get("dashboard_visible") is (not is_closed)
                and snapshot.get("popover_visible") is (not is_closed),
                "Full Metal chart checkpoint lost native window visibility")
        if is_closed:
            require(snapshot.get("active_requests") == 0, "Full Metal chart closed checkpoint is not idle")
        require(memory.runtime_feature_contract(snapshot["graphics_diagnostics"], mode) == initial_flags,
                "Full Metal chart features changed between checkpoints")
        counts = memory.metal_full_chart_contract(snapshot, mode, expected_closed=is_closed)["counters"]
        rows.append((point, boundary(point), counts))
    for first, last in zip(rows, rows[1:]):
        require(last[1] > first[1], "Full Metal chart checkpoints are not ordered")
        require(all(last[2][field] >= first[2][field] for field in cumulative),
                "Full Metal chart counters moved backwards between checkpoints")
        if cached:
            first_twinkles = first[0]["snapshot"]["graphics_diagnostics"]["retained_twinkles"]
            last_twinkles = last[0]["snapshot"]["graphics_diagnostics"]["retained_twinkles"]
            require(all(last_twinkles[field] >= first_twinkles[field] for field in
                        ("hosts_created", "hosts_destroyed", "instances_created", "instances_destroyed", "animation_starts")),
                    "Cached Metal retained twinkle counters moved backwards")
    runtime_rows = rows[:len(points)]
    arrival, steady, completion = (report["phase_windows"][name] for name in ("arrival", "steady", "completion"))
    arrival_end = [row for row in runtime_rows
                   if arrival["end_monotonic_seconds"] <= row[1] < steady["start_monotonic_seconds"]]
    require(runtime_rows[0][1] <= arrival["start_monotonic_seconds"] and arrival_end,
            "Full Metal chart arrival work lacks bracketing checkpoints")
    steady_rows = [row for row in runtime_rows
                   if steady["start_monotonic_seconds"] < row[1] < steady["end_monotonic_seconds"]]
    require(len(steady_rows) >= 2 and all(row[0]["snapshot"].get("active_requests") == 2 for row in steady_rows),
            "Full Metal chart steady phase lacks two active streams and interior checkpoints")
    completion_start = [row for row in runtime_rows if row[0]["label"] == "completion-begin"]
    require(len(completion_start) == 1
            and completion["start_monotonic_seconds"] <= completion_start[0][1] < completion["end_monotonic_seconds"],
            "Full Metal chart completion work lacks its authenticated start checkpoint")
    completion_rows = [row for row in runtime_rows
                       if completion_start[0][1] <= row[1] <= completion["end_monotonic_seconds"]]
    require(len(completion_rows) >= 2 and all(row[0]["snapshot"].get("active_requests") == 0 for row in completion_rows),
            "Full Metal chart completion lacks idle interior checkpoints")

    def delta(first, last):
        return {field: last[2][field] - first[2][field] for field in cumulative}

    arrival_delta = delta(runtime_rows[0], arrival_end[0])
    steady_delta = delta(steady_rows[0], steady_rows[-1])
    completion_delta = delta(completion_rows[0], completion_rows[-1])
    require(arrival_delta["arrival_frames"] > 0 and arrival_delta["static_frames"] > 0,
            "Full Metal chart did not submit arrivals before steady traffic")
    require(steady_delta["static_frames"] > 0 and (cached or steady_delta["twinkle_frames"] > 0)
            and steady_delta["geometry_uploads"] > 0,
            "Full Metal chart steady phase did not update charts and animate twinkles")
    require(steady_delta["arrival_frames"] == steady_delta["completion_frames"] == 0,
            "Full Metal chart lifecycle effects continued through the steady phase")
    require(completion_delta["completion_frames"] > 0, "Full Metal chart did not preserve completion animation")
    require(rows[-1][1] - rows[-2][1] >= minimum_closed_seconds,
            "Full Metal chart closed observation is too short")
    closed_delta = delta(rows[-2], rows[-1])
    require(all(count == 0 for count in closed_delta.values()), "Full Metal chart continued work after windows closed")
    cached_work = {}
    if cached:
        first, last = steady_rows[0], steady_rows[-1]
        preparations = memory.unsigned(last[0]["snapshot"].get("chart_preparations"), "steady.last.chart_preparations") - memory.unsigned(
            first[0]["snapshot"].get("chart_preparations"), "steady.first.chart_preparations")
        allowance = max(first[2]["live_hosts"], last[2]["live_hosts"])
        invalidations = steady_delta["static_scene_revisions"] + steady_delta["static_surface_invalidations"]
        require(preparations > 0 and 0 < steady_delta["static_rasterizations"] <= invalidations + allowance,
                "Cached Metal steady rasterization exceeds recorded scene and surface invalidations")
        require(steady_delta["static_cache_composites"] <= invalidations + allowance
                and steady_delta["submissions"] <= invalidations + allowance,
                "Cached Metal steady frame submissions exceed invalidation-driven redraws")
        require(steady_delta["scene_unclassified_revisions"] == 0
                and sum(steady_delta[field] for field in memory.METAL_SCENE_REVISION_CAUSES)
                >= steady_delta["static_scene_revisions"],
                "Cached Metal steady scene revisions lack explicit invalidation causes")
        require(steady_delta["twinkle_frames"] == steady_delta["effect_clock_ticks"] == 0,
                "Cached Metal continued shader glints or its effects clock during steady traffic")
        retained = {}
        for field in ("instances_created", "animation_starts"):
            retained[field] = (last[0]["snapshot"]["graphics_diagnostics"]["retained_twinkles"][field]
                               - first[0]["snapshot"]["graphics_diagnostics"]["retained_twinkles"][field])
        require(all(value > 0 for value in retained.values()),
                "Cached Metal steady phase did not execute retained Core Animation glints")
        first_closed = rows[-2][0]["snapshot"]["graphics_diagnostics"]["retained_twinkles"]
        last_closed = rows[-1][0]["snapshot"]["graphics_diagnostics"]["retained_twinkles"]
        require(first_closed == last_closed, "Cached Metal retained glints continued work after windows closed")
        cached_work = {"cache_publication_proof": {"steady_chart_preparations": preparations,
                      "steady_static_scene_revisions": steady_delta["static_scene_revisions"],
                      "steady_static_surface_invalidations": steady_delta["static_surface_invalidations"],
                      "steady_scene_revision_causes": {field: steady_delta[field] for field in memory.METAL_SCENE_REVISION_CAUSES},
                      "per_host_boundary_allowance": allowance, "steady_retained_twinkle_deltas": retained,
                      "steady_effect_clock_stopped": True,
                      "scope": "Explicit scene/surface invalidation causes, independent chart preparations, and at most one boundary redraw per live host"}}
    return {"available": True, "arrival_deltas": arrival_delta, "steady_deltas": steady_delta,
            "completion_deltas": completion_delta, "closed_deltas": closed_delta,
            **cached_work,
            "frame_delivery_qualified": rows[-1][2]["frames_skipped"] == 0,
            "scope": "Authenticated visible workload and closed cancellation; submitted work does not measure GPU utilization"}


def validate_canvas_clock_work(report, mode):
    """Use existing authenticated checkpoints; never infer idle from a tail deadline."""
    if mode in memory.METAL_CHART_MODES:
        return validate_metal_full_chart_work(report, mode)
    points = report["runtime"]["checkpoints"]
    flags = memory.runtime_feature_contract(points[0]["snapshot"].get("graphics_diagnostics", {}), mode) or {}
    metal_initial = memory.metal_arrival_contract(points[0]["snapshot"], mode)
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
        metal = memory.metal_arrival_contract(snapshot, mode)
        require((metal_initial is None) == (metal is None)
                and (metal is None or metal_initial["arrival_backend"] == metal["arrival_backend"]),
                "Arrival backend metadata changed during phase checkpoints")
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
        if metal_initial is not None:
            require(all(last["snapshot"][field] >= first["snapshot"][field] for field in memory.METAL_ARRIVAL_COUNTERS),
                    "Metal arrival counters moved backwards during runtime")
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
    if mode == memory.METAL_ARRIVAL_MODE:
        for field in memory.METAL_ARRIVAL_COUNTERS:
            delta[field] = last["snapshot"][field] - first["snapshot"][field]
        require(all(delta[field] == 0 for field in memory.METAL_ARRIVAL_COUNTERS),
                "Metal arrival renderer continued work during effect-free steady traffic")
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
        if mode == memory.METAL_ARRIVAL_MODE:
            require(all(points[-1]["snapshot"][field] <= closed[0][0]["snapshot"][field]
                        == closed[1][0]["snapshot"][field] for field in memory.METAL_ARRIVAL_COUNTERS),
                    "Metal arrival renderer continued work after both windows closed")
            result["closed"]["metal_arrival_deltas"] = dict.fromkeys(memory.METAL_ARRIVAL_COUNTERS, 0)
    if mode in (memory.NO_ARRIVAL_MODE, memory.METAL_ARRIVAL_MODE):
        arrival = report["phase_windows"]["arrival"]
        ends = [(point, timestamp) for point, timestamp in zip(points, timestamps)
                if arrival["end_monotonic_seconds"] <= timestamp < window["start_monotonic_seconds"]]
        require(timestamps[0] <= arrival["start_monotonic_seconds"] and ends
                and ends[0][0]["snapshot"].get("active_requests") == 2,
                "Arrival drawing evidence does not bracket the complete arrival phase")

        def effect_delta(first, last):
            def draws(point):
                return memory.unsigned(point["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"].get("draws"),
                                       "graphics.rail_decorations.draws")
            return {"rail_frame_clock_ticks": last["snapshot"]["rail_frame_clock_ticks"] - first["snapshot"]["rail_frame_clock_ticks"],
                    "rail_decorations_draws": draws(last) - draws(first)}

        arrival_delta = effect_delta(points[0], ends[0][0])
        if mode == memory.NO_ARRIVAL_MODE:
            suppressed_first = memory.unsigned(points[0]["snapshot"].get("suppressed_arrival_effects"), "arrival.start.suppressed_arrival_effects")
            suppressed_last = memory.unsigned(ends[0][0]["snapshot"].get("suppressed_arrival_effects"), "arrival.end.suppressed_arrival_effects")
            arrival_delta["suppressed_arrival_effects"] = suppressed_last - suppressed_first
            require(arrival_delta["rail_frame_clock_ticks"] == arrival_delta["rail_decorations_draws"] == 0
                    and arrival_delta["suppressed_arrival_effects"] > 0,
                    "No-arrival control did not suppress arrival drawing and clock work")
        else:
            arrival_delta.update({field: ends[0][0]["snapshot"][field] - points[0]["snapshot"][field]
                                  for field in memory.METAL_ARRIVAL_COUNTERS})
            require(arrival_delta["metal_arrival_frames"] == arrival_delta["metal_arrival_submissions"] > 0
                    and arrival_delta["metal_arrival_failures"] == 0,
                    "Metal arrival phase did not submit rendered frames")
        completion = report["phase_windows"]["completion"]
        began = [(point, timestamp) for point, timestamp in zip(points, timestamps) if point["label"] == "completion-begin"]
        require(len(began) == 1 and completion["start_monotonic_seconds"] <= began[0][1] < completion["end_monotonic_seconds"],
                "Arrival control lacks an authenticated completion-start checkpoint inside the phase")
        completed = [(point, timestamp) for point, timestamp in zip(points, timestamps)
                     if began[0][1] <= timestamp <= completion["end_monotonic_seconds"]]
        require(len(completed) >= 2 and all(point["snapshot"].get("active_requests") == 0 for point, _ in completed),
                "Arrival control lacks interior completion drawing checkpoints")
        completion_delta = effect_delta(completed[0][0], completed[-1][0])
        require(completion_delta["rail_frame_clock_ticks"] > 0 and completion_delta["rail_decorations_draws"] > 0,
                "Arrival control did not preserve completion drawing and clock work")
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
                        "acceptance_eligible": cpu_acceptance_eligible(report.get("graphics_mode"),
                            profile=report["runtime"].get("profiled", False)) and not report.get("thread_cpu_requested", False) and not report.get("nio_cpu_requested", False)}
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


@contextmanager
def thread_cpu_environment(enabled, nio_cpu=False):
    previous = os.environ.pop("FLUXLLM_PERF_THREAD_CPU", None)
    previous_nio = os.environ.pop("FLUXLLM_PERF_NIO_CPU", None)
    try:
        if enabled or nio_cpu:
            os.environ["FLUXLLM_PERF_THREAD_CPU"] = "1"
        if nio_cpu:
            os.environ["FLUXLLM_PERF_NIO_CPU"] = "1"
        yield
    finally:
        os.environ.pop("FLUXLLM_PERF_THREAD_CPU", None)
        os.environ.pop("FLUXLLM_PERF_NIO_CPU", None)
        if previous_nio is not None:
            os.environ["FLUXLLM_PERF_NIO_CPU"] = previous_nio
        if previous is not None:
            os.environ["FLUXLLM_PERF_THREAD_CPU"] = previous


def capture_case(output, mode, paths, provenance, identity, deadline, *, profile=False, thread_cpu=False, nio_cpu=False):
    thread_cpu = thread_cpu or nio_cpu
    output.mkdir()
    diagnostic = RuntimeDiagnostic(output, deadline, mode, profile=profile)
    if thread_cpu:
        diagnostic.runtime["cpu_comparison_available"] = False
        diagnostic.report.update(thread_cpu_requested=True, cpu_acceptance_eligible=False, cpu_gate_evaluated=False)
    if nio_cpu:
        diagnostic.report["nio_cpu_requested"] = True
    try:
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve), thread_cpu_environment(thread_cpu, nio_cpu):
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
        report["steady_twinkle_delivery"] = validate_steady_twinkle_delivery(report, mode)
        held_work = validate_held_static_chart_checkpoints(report, mode)
        if held_work is not None:
            report["held_static_chart_work"] = held_work
        report["phase_cpu"] = phase_cpu(report, report["phase_windows"])
        report["runtime_cpu_work_counters"] = runtime_work_counter_diagnostic(report, profile=profile)
        report["phase_cpu_comparison_available"] = not profile and not thread_cpu
        eligible = cpu_acceptance_eligible(mode, profile=profile) and not thread_cpu
        report["cpu_acceptance_eligible"] = eligible
        report["runtime_cpu_target"] = {"evaluated": eligible, "acceptance_eligible": eligible, "limit_percent": 5.0,
            "within_limit": report["phase_cpu"]["whole_contiguous_runtime"]["rolling_1s_percent"] <= 5 if eligible else None,
            "scope": "Contiguous visible traffic and completion only; separate from full resource gate"}
        if mode in (memory.HELD_STATIC_CHART_MODE, *memory.METAL_CHART_MODES):
            report["runtime_cpu_target"]["reason"] = ("Experimental Metal chart needs independent visual and frame-delivery qualification"
                if mode in memory.METAL_CHART_MODES else "Held static chart drawing is a diagnostic ablation, not production rendering")
            report["runtime_cpu_target"]["observed_within_limit"] = report["phase_cpu"]["whole_contiguous_runtime"]["rolling_1s_percent"] <= 5
            report["cpu_gate_evaluated"] = False
            report.setdefault("workload_cpu", {}).update(acceptance_eligible=False, gate_evaluated=False, within_limit=None)
            for metrics in report["phase_cpu"].values():
                metrics["acceptance_eligible"] = False
        if thread_cpu:
            report["runtime_cpu_target"]["reason"] = "Direct thread counter collection is an instrumented diagnostic"
            report["cpu_gate_evaluated"] = False
            report.setdefault("workload_cpu", {}).update(acceptance_eligible=False, gate_evaluated=False, within_limit=None)
            for metrics in report["phase_cpu"].values():
                metrics["acceptance_eligible"] = False
            from runtime_thread_cpu import analyze_report
            report["thread_cpu_analysis"] = analyze_report(report, required=True)
        if nio_cpu:
            from runtime_nio_cpu import analyze_report as analyze_nio_report
            try:
                report["nio_cpu_analysis"] = analyze_nio_report(report, required=True)
            except (ValueError, KeyError, TypeError, OverflowError) as error:
                report["nio_cpu_analysis"] = {"available": False, "status": "invalid",
                    "acceptance_eligible": False, "errors": [str(error)]}
        if profile:
            require(report["runtime"]["profiler_status"] == "captured", "Time Profiler capture is incomplete")
        report["status"] = "diagnostic_captured"
    except (OSError, ValueError, KeyError, TypeError) as error:
        report["errors"].append(str(error))
        report["status"] = "diagnostic_incomplete"
    write_json(output / "runtime-case.json", report)
    return report


def runtime_work_counter_diagnostic(report, *, profile=False):
    """Separate raw diagnostic evidence over exact runtime checkpoint samples."""
    points = report.get("runtime", {}).get("checkpoints", [])
    first = points[0].get("snapshot", {}) if points else {}
    last = points[-1].get("snapshot", {}) if points else {}
    return app.cpu_work_counter_diagnostic(report.get("samples", []), report.get("events", []),
        first.get("runner_collector_sample_monotonic_seconds"),
        last.get("runner_collector_sample_monotonic_seconds")) | {
            "interval_scope": "Exact acknowledged before-traffic through completion-end kernel checkpoint boundaries; these control timestamps may differ from interpolated CPU phase-window edges",
            "profiled": profile, "acceptance_eligible": False}


def selected_cases(args):
    references = reference_arguments(args)
    if any(value is not None for value in references):
        require(all(value is not None for value in references),
                "Frozen reference comparison requires all three reference product/provenance arguments")
        require(args.operation == "compare", "Frozen reference comparison cannot run with Time Profiler")
        require(args.controls is None, "Frozen reference comparison cannot be combined with graphics controls")
        return [("reference-before", args.baseline_mode),
                ("candidate", getattr(args, "candidate_mode", None) or args.baseline_mode), ("reference-after", args.baseline_mode)]
    require(getattr(args, "candidate_mode", None) is None, "Candidate mode requires a frozen reference comparison")
    if args.operation == "profile":
        return [("profile", args.graphics_mode)]
    if args.operation in ("threads", "nio"):
        require(args.controls is None, "CPU accounting cannot combine graphics controls")
        return [(label, args.graphics_mode) for label in ("observer-before", args.operation, "observer-after")]
    controls = args.controls or ["runtime-optimized"]
    require(1 <= len(controls) <= 3 and len(set(controls)) == len(controls), "Select one to three distinct runtime controls")
    return [("baseline-before", args.baseline_mode), *[(mode, mode) for mode in controls], ("baseline-after", args.baseline_mode)]


def reference_arguments(args):
    return tuple(getattr(args, name, None) for name in ("reference_app_binary", "reference_test_bundle", "reference_provenance"))


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
        evidence = "profiled attribution only" if report["operation"] == "profile" else (
            "instrumented NIO scopes and thread counters" if case.get("nio_cpu_analysis") else
            "instrumented direct thread counters" if case.get("thread_cpu_analysis") else "unprofiled kernel counters")
        lines.append(f"| {case['label']} | {evidence} | "
                     f"{fmt('average_cpu_percent')} | {fmt('rolling_1s_percent')} | {outcome} | {peak / 1e6 if peak is not None else 'unavailable'} |")
    lines += ["", "Whole runtime includes fixture start/end and the three-second visible completion tail. Arrival, steady, completion, and whole-runtime windows are stored separately; selected phase windows must not be summed. GPU and filesystem-write gates are separate."]
    if report["operation"] == "profile" and report.get("native_capture_complete"):
        lines += ["", "Native capture: complete. Attribution analysis: `" + report.get("attribution_status", "incomplete") + "`."]
        if report.get("analysis_pending_reasons"):
            lines += ["Quantitative CPU attribution is unavailable; raw sample weights and rankings are retained without rescaling.", "",
                      *["- " + reason for reason in report["analysis_pending_reasons"]]]
    if report["operation"] == "threads" and report.get("thread_cpu_analysis"):
        from runtime_thread_cpu import render_summary
        lines += [""] + render_summary(report["thread_cpu_analysis"])
    if report["operation"] == "nio" and report.get("nio_cpu_analysis"):
        from runtime_nio_cpu import render_summary
        lines += [""] + render_summary(report["nio_cpu_analysis"])
    if "baseline_drift" in report:
        lines += ["", "Comparison conclusive: " + str(report["baseline_drift"]["comparison_conclusive"]).lower() + ". " + report["baseline_drift"]["policy"]]
    if report["errors"]:
        lines += ["", *["- " + error.replace("\n", " ") for error in report["errors"]]]
    return "\n".join(lines) + "\n"


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("operation", choices=("profile", "compare", "threads", "nio"))
    for name in ("app-binary", "test-bundle", "collector-binary", "provenance"):
        result.add_argument("--" + name, required=True, type=Path)
    for name in ("reference-app-binary", "reference-test-bundle", "reference-provenance"):
        result.add_argument("--" + name, type=Path,
                            help="Compare frozen versions in reference/candidate/reference order using --baseline-mode")
    result.add_argument("--graphics-mode", choices=BASELINES + memory.RUNTIME_MODES, default="normal")
    result.add_argument("--baseline-mode", choices=BASELINES + memory.METAL_CHART_MODES, default="native-gpu-optimized")
    result.add_argument("--candidate-mode", choices=BASELINES + memory.RUNTIME_MODES,
                        help="Candidate-only rendering mode for a frozen reference/candidate/reference comparison")
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
    references = reference_arguments(args)
    version_compare = any(value is not None for value in references)
    output = (args.output_dir or app.ROOT / ".performance-results" /
              ("runtime-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S-") + secrets.token_hex(4))).resolve()
    output_created = False
    report = {"kind": "runtime-cpu-version-comparison" if version_compare else "runtime-cpu-attribution",
              "operation": "version-compare" if version_compare else args.operation, "status": "diagnostic_incomplete",
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
            products = {"candidate": {"paths": paths, "provenance": provenance, "identity": identity}}
            if version_compare:
                reference_args = argparse.Namespace(**vars(args))
                reference_args.app_binary, reference_args.test_bundle, reference_args.provenance = references
                reference_paths, reference_provenance, reference_identity = memory.validate_products(reference_args)
                require(reference_identity == identity, "Frozen versions have different common measurement identities")
                fixture = provenance.get("fixture_equivalence_sha256", {}).get("populated")
                require(isinstance(fixture, str) and fixture
                        == reference_provenance.get("fixture_equivalence_sha256", {}).get("populated"),
                        "Frozen versions have different populated fixture identities")
                require(reference_paths["collector"] == paths["collector"],
                        "Frozen versions require the same common collector")
                products["reference"] = {"paths": reference_paths, "provenance": reference_provenance, "identity": reference_identity}
                report["graphics_mode"] = args.baseline_mode
                report["product_graphics_modes"] = {"reference": args.baseline_mode,
                                                    "candidate": args.candidate_mode or args.baseline_mode}
            for product in products.values():
                product["files"] = runtime_product_identity(product["paths"], product["provenance"])
            report["products"] = {role: {"files": product["files"], "production_provenance": product["provenance"],
                                        "measurement_identity": product["identity"]} for role, product in products.items()}
        for label, mode in cases:
            seconds = (PROFILE_SECONDS if args.operation == "profile" else
                       THREE_CASE_SECONDS if version_compare or args.operation == "nio" else CASE_SECONDS)
            require(deadline.remaining() >= seconds + 3, "Insufficient remaining time for a complete runtime case")
            require(runtime_source_identity() == sources, "Runtime measurement sources changed during the comparison")
            require(all(runtime_product_identity(product["paths"], product["provenance"]) == product["files"]
                        for product in products.values()),
                    "Frozen products changed during runtime comparison")
            role = "reference" if version_compare and label != "candidate" else "candidate"
            paths, provenance, identity = (products[role][key] for key in ("paths", "provenance", "identity"))
            print(f"Runtime case {len(report['cases']) + 1}/{len(cases)}: {label} ({mode}); remaining {deadline.remaining():.1f}s", flush=True)
            case_deadline = RuntimeDeadline(seconds, cleanup_reserve=8)
            directory = output / label
            capture_options = {"profile": args.operation == "profile"}
            if args.operation in ("threads", "nio") and label == args.operation:
                capture_options["thread_cpu"] = True
                if args.operation == "nio":
                    capture_options["nio_cpu"] = True
            case = capture_case(directory, mode, paths, provenance, identity, case_deadline, **capture_options)
            row = {"label": label, "mode": mode, "product_role": role, "status": case["status"], "report_path": str(directory / "runtime-case.json"),
                   "report_sha256": app.path_hash(directory / "runtime-case.json"), "workload_cpu": case.get("workload_cpu"),
                   "phase_cpu": case.get("phase_cpu"), "runtime_work": case.get("runtime_work"),
                   "runtime_cpu_work_counters": case.get("runtime_cpu_work_counters"),
                   "steady_twinkle_delivery": case.get("steady_twinkle_delivery"),
                   "thread_cpu_analysis": case.get("thread_cpu_analysis"),
                   "nio_cpu_analysis": case.get("nio_cpu_analysis"),
                   "visual_work": case.get("visual_work"),
                   "runtime_cpu_target": case.get("runtime_cpu_target"),
                   "peak_footprint_bytes": (case.get("samples") or [{}])[-1].get("lifetime_peak_footprint_bytes")}
            report["cases"].append(row)
            require(runtime_source_identity() == sources, "Runtime measurement sources changed during the capture")
            require(all(runtime_product_identity(product["paths"], product["provenance"]) == product["files"]
                        for product in products.values()), "Frozen products changed during the runtime capture")
            whole = (row.get("phase_cpu") or {}).get("whole_contiguous_runtime", {})
            print(f"  {case['status']}: whole-runtime CPU mean={whole.get('average_cpu_percent', 'unavailable')}%, max={whole.get('rolling_1s_percent', 'unavailable')}%" +
                  (" (profiled attribution only)" if args.operation == "profile" else ""), flush=True)
            write_json(output / "runtime-report.json", report)
            require(case["status"] == "diagnostic_captured", f"Runtime case {label} is incomplete: {case['errors']}")
            if args.operation in ("threads", "nio") and label == args.operation:
                report["native_capture_complete"] = True
                report["thread_cpu_analysis"] = case["thread_cpu_analysis"]
                analysis_key = "nio_cpu_analysis" if args.operation == "nio" else "thread_cpu_analysis"
                report[analysis_key] = case[analysis_key]
                report["attribution_status"] = case[analysis_key]["status"]
                if not case[analysis_key].get("available"):
                    report["analysis_pending_reasons"] = case[analysis_key].get("errors") or ["CPU accounting is unavailable"]
            if args.operation in ("compare", "threads", "nio"):
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
        if args.operation in ("compare", "threads", "nio"):
            report["baseline_drift"] = baseline_drift(report["cases"])
        if args.operation in ("threads", "nio"):
            before, measured, after = [case["phase_cpu"]["whole_contiguous_runtime"] for case in report["cases"]]
            report["observer_comparison"] = {
                "acceptance_eligible": False, "reference_drift": report["baseline_drift"],
                "metrics": {key: {"before": before[key], "instrumented": measured[key], "after": after[key],
                    "instrumented_minus_reference_min": measured[key] - min(before[key], after[key]),
                    "instrumented_minus_reference_max": measured[key] - max(before[key], after[key])}
                    for key in ("average_cpu_percent", "rolling_1s_percent")},
                "scope": "Adjacent same-binary observer-off/on/off; drift and differences reported without claiming zero observer disturbance"}
        require(runtime_source_identity() == sources, "Runtime measurement sources changed before finalization")
        require(all(runtime_product_identity(product["paths"], product["provenance"]) == product["files"]
                    for product in products.values()), "Frozen products changed before runtime finalization")
        require(time.monotonic() < deadline.end - 1, "Runtime attribution exceeded its 300-second deadline")
        pending = (args.operation == "profile" and report.get("attribution_status") == "analysis_pending"
                   or args.operation == "threads" and not report.get("thread_cpu_analysis", {}).get("available")
                   or args.operation == "nio" and not report.get("nio_cpu_analysis", {}).get("available"))
        report["status"] = "analysis_pending" if pending else "diagnostic_captured"
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
