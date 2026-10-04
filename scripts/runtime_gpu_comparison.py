"""A bounded, same-trace GPU comparison of frozen Release products.

The short replay is a GPU diagnostic, not the ordinary CPU acceptance protocol.
Every run preserves source/product bindings and partial evidence on failure.
"""

import argparse
from datetime import datetime, timezone
import math
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import time

import app_performance as app
import memory_attribution as memory
import runtime_attribution as runtime
from performance_trace import TraceSession
from run_performance_checks import interrupted, load_json, require, write_json


MAX_SECONDS = 300
PHASE_SECONDS = {"record": 80, "finalize": 190, "toc": 200, "export": 255, "evaluate": 290}
CASE_SECONDS = 27
CYCLE = 15000
REQUEST_INDICES = (CYCLE * 32, CYCLE * 32 + 1)
STAGE = {"activity": "high-rate", "seconds": 8}
WORK = {"chunks": 3200, "output_tokens": 6434, "prompt_tokens": 46,
        "requests": 2, "tool_calls": 2, "tool_results": 2}
MODES = ("normal", memory.METAL_ARRIVAL_MODE, *memory.METAL_CHART_MODES, *memory.NEW_RUNTIME_MODES, *memory.REUSE_RUNTIME_MODES, memory.FROZEN_SCALARS_MODE)
ERRORS = (OSError, ValueError, KeyError, TypeError, TimeoutError, subprocess.SubprocessError)


def source_identity():
    return runtime.runtime_source_identity() | {Path(__file__).name: app.path_hash(Path(__file__))}


def product_identity(paths, provenance):
    files = dict(paths)
    for field in ("provenance_file", "original_provenance_file"):
        if provenance.get(field):
            files[field] = Path(provenance[field])
    for name in provenance.get("resource_bundle_sha256", {}):
        files["resource:" + name] = paths["app"].parent / name
    return {name: {"path": str(path), "sha256": app.path_hash(path)} for name, path in files.items()}


def load_products(directory, output, label, *, rebind_measurement=False):
    """Bind a new external measurement without modifying original provenance."""
    directory = directory.resolve()
    paths = {"app": directory / "FluxLLMApp", "tests": directory / "FluxLLMPackageTests.xctest",
             "collector": directory / "FluxLLMResourceCollector"}
    original = directory / "provenance.json"
    raw = load_json(original)
    identity = app.measurement_identity()
    provenance_path = original
    if raw.get("instrumentation_sha256") != identity["sha256"]:
        require(rebind_measurement,
                "Frozen measurement sources differ; use --rebind-measurement to preserve and explicitly bind the new external measurement")
        mode = "baseline" if raw.get("kind") == "reconstructed-pre-optimization" else "check"
        app.validated_provenance(original, paths, mode, raw.get("instrumentation_sha256"))
        require(app.path_hash(paths["collector"]) == raw.get("common_collector", {}).get("sha256"),
                "Cannot rebind a changed frozen collector")
        bound = dict(raw)
        bound.update(instrumentation_sha256=identity["sha256"],
                     original_provenance_file=str(original), original_provenance_sha256=app.path_hash(original),
                     external_measurement_binding={"kind": "short-gpu-comparison", "original_instrumentation_sha256": raw["instrumentation_sha256"],
                                                   "measurement_identity": identity, "runtime_source_identity": source_identity(),
                                                   "production_products_rebuilt": False})
        provenance_path = output / (label + "-measurement-provenance.json")
        write_json(provenance_path, bound)
    args = argparse.Namespace(app_binary=paths["app"], test_bundle=paths["tests"], collector_binary=paths["collector"],
                              provenance=provenance_path)
    paths, provenance, identity = memory.validate_products(args)
    return {"paths": paths, "provenance": provenance, "identity": identity, "files": product_identity(paths, provenance)}


def snapshot_time(report, point):
    snapshot, sample = point["snapshot"], point["resource_sample"]
    matches = [row for row in report["samples"]
               if row.get("monotonic_seconds") == snapshot.get("runner_collector_sample_monotonic_seconds")]
    require(len(matches) == 1 and matches[0] == sample, "GPU checkpoint lacks its unique paired kernel boundary")
    require(all(sample.get(field) == report["owned_identity"][field] for field in ("process_id", "birth_time_us")),
            "GPU checkpoint process identity differs")
    clocks = report["runtime"]
    offsets = [clocks[key]["absolute_minus_monotonic_seconds"] for key in ("mach_clock_start", "mach_clock_end")]
    require(all(math.isfinite(value) for value in offsets)
            and all(0 <= clocks[key]["uncertainty_seconds"] <= .000001 for key in ("mach_clock_start", "mach_clock_end"))
            and abs(offsets[0] - offsets[1]) <= .000001, "GPU Mach clock bridge is imprecise or drifted")
    return sample["mach_absolute_seconds"] - sum(offsets) / 2


def phase_windows(report):
    points = report["runtime"]["checkpoints"]
    require(points and points[0]["label"] == "before-traffic" and points[-1]["label"] == "completion-end",
            "GPU runtime phase endpoints are incomplete")
    gaps = [last["python_monotonic_seconds"] - first["python_monotonic_seconds"] for first, last in zip(points, points[1:])]
    require(all(0 < gap <= 2 for gap in gaps), "GPU visibility checkpoint coverage has a gap")
    timestamps = [snapshot_time(report, point) for point in points]
    require(all(first < last for first, last in zip(timestamps, timestamps[1:])), "GPU kernel checkpoints are not ordered")
    require(all(point["snapshot"].get("dashboard_visible") is True and point["snapshot"].get("popover_visible") is True
                for point in points), "GPU runtime windows were not both natively visible")
    streams = report["workload"]["fixture_status"]["timing"]["streams"]
    require(len(streams) == 2, "GPU workload requires both timed streams")
    first = min(stream["first_write_started_monotonic_seconds"] for stream in streams)
    earliest_terminal = min(stream["terminal_write_started_monotonic_seconds"] for stream in streams)
    terminal = max(stream["terminal_write_started_monotonic_seconds"] for stream in streams)
    left, right = timestamps[0], timestamps[-1]
    require(left < first < first + 7 < earliest_terminal <= terminal < terminal + 3 <= right,
            "GPU capture does not contain arrival, steady traffic, and three seconds after both completions")
    completion = [index for index, point in enumerate(points) if point["label"] == "completion-begin"]
    require(len(completion) == 1 and terminal <= timestamps[completion[0]] < terminal + 3,
            "GPU completion acknowledgment does not bracket the completed streams")
    require(points[0]["snapshot"].get("active_requests") == 0
            and all(point["snapshot"].get("active_requests") == 0 for point in points[completion[0]:]),
            "GPU initial or completed state still has active streams")
    return {name: {"start_monotonic_seconds": start, "end_monotonic_seconds": end} for name, start, end in (
        ("arrival", first, first + 2), ("steady", first + 3, first + 7),
        ("completion", terminal, terminal + 3), ("whole_contiguous_runtime", left, right))}


def validate_short_clock_work(report, mode):
    """Check the same rendering contracts over the explicitly shorter windows."""
    if mode in memory.METAL_CHART_MODES:
        return runtime.validate_metal_full_chart_work(report, mode,
            closed_labels=("closed-start", "closed-end"), minimum_closed_seconds=2,
            boundary=lambda point: snapshot_time(report, point))
    if mode in memory.PRIMITIVE_EFFECTS_MODES:
        return runtime.validate_metal_primitive_effects_work(report, mode,
            closed_labels=("closed-start", "closed-end"), minimum_closed_seconds=2,
            boundary=lambda point: snapshot_time(report, point))
    points = report["runtime"]["checkpoints"]
    flags = report["runtime_work"]["features"]
    window = report["phase_windows"]["steady"]
    steady = [point for point in points if window["start_monotonic_seconds"] < snapshot_time(report, point)
              < window["end_monotonic_seconds"]]
    require(len(steady) >= 2 and all(point["snapshot"].get("active_requests") == 2 for point in steady),
            "Short GPU steady phase lacks interior active-stream checkpoints")
    counters = list(memory.CANVAS_CLOCK_COUNTERS)
    if mode == memory.METAL_ARRIVAL_MODE:
        counters += list(memory.METAL_ARRIVAL_COUNTERS)
    for first, last in zip(points, points[1:]):
        require(all(memory.unsigned(last["snapshot"].get(field), field) >= memory.unsigned(first["snapshot"].get(field), field)
                    for field in counters), "GPU rendering counters moved backwards")
    delta = {field: steady[-1]["snapshot"][field] - steady[0]["snapshot"][field] for field in counters}
    if flags.get("canvas_frame_clock"):
        require(delta["rail_frame_clock_ticks"] == 0, "Canvas clock continued during effect-free short steady traffic")
    if mode == memory.METAL_ARRIVAL_MODE:
        require(all(delta[field] == 0 for field in memory.METAL_ARRIVAL_COUNTERS), "Metal arrival work continued during steady traffic")
        arrival_delta = {field: steady[0]["snapshot"][field] - points[0]["snapshot"][field]
                         for field in memory.METAL_ARRIVAL_COUNTERS}
        require(arrival_delta["metal_arrival_frames"] == arrival_delta["metal_arrival_submissions"] > 0
                and arrival_delta["metal_arrival_failures"] == 0,
                "Short GPU Metal arrivals did not submit rendered frames before steady traffic")
    completion = next(point for point in points if point["label"] == "completion-begin")
    if flags.get("canvas_frame_clock"):
        require(points[-1]["snapshot"]["rail_frame_clock_ticks"] > completion["snapshot"]["rail_frame_clock_ticks"]
                and points[-1]["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"]
                    > completion["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"],
                "Short GPU replay did not preserve completion animation drawing")
    closed = []
    for label in ("closed-start", "closed-end"):
        matches = [point for point in report["checkpoints"] if point["label"] == label]
        require(len(matches) == 1, "Short GPU closed checkpoints are missing or duplicated")
        closed.append(matches[0])
    require(snapshot_time(report, closed[-1]) - snapshot_time(report, closed[0]) >= 2,
            "Short GPU closed observation is shorter than two seconds")
    require(all(point["snapshot"].get("dashboard_visible") is False and point["snapshot"].get("popover_visible") is False
                and point["snapshot"].get("active_requests") == 0 for point in closed), "GPU closed state is not idle")
    quiet = (["rail_frame_clock_ticks"] if flags.get("canvas_frame_clock") else [])
    if mode == memory.METAL_ARRIVAL_MODE:
        quiet += list(memory.METAL_ARRIVAL_COUNTERS)
    require(all(points[-1]["snapshot"][field] <= closed[0]["snapshot"][field] == closed[-1]["snapshot"][field]
                for field in quiet), "GPU animation work continued after windows closed")
    reuse_work = runtime.validate_reuse_cache_phase_work(report, mode,
        closed_labels=("closed-start", "closed-end"), minimum_closed_seconds=2,
        boundary=lambda point: snapshot_time(report, point))
    return {"steady_deltas": delta, "closed_deltas": dict.fromkeys(quiet, 0),
            **({"reuse_caches": reuse_work} if reuse_work is not None else {}),
            "scope": "Two completed streams; no inference about cancellation of active network requests"}


def validate_visual_identity(report):
    """Pin the acknowledged workload to this protocol's fixed visual identities."""
    workload = report["workload"]
    require(workload["fixture_start"].get("expected_request_indices") == list(REQUEST_INDICES),
            "Short GPU fixture request indices differ from the fixed cycle")
    # The shared validator additionally checks every runtime/event snapshot,
    # monotonic identity retention, exact UUIDs, and fixed animation seeding.
    return runtime.validate_visual_work(report, required=True) | {"fixture_cycle": CYCLE}


class ShortGPUDiagnostic(runtime.RuntimeDiagnostic):
    def __init__(self, output, deadline, mode):
        super().__init__(output, deadline, mode, profile=False)
        self.runtime.update(profiled=True, profiler_status="external-gpu-trace", cpu_comparison_available=False)
        self.report.update(kind="short-gpu-runtime-diagnostic", externally_gpu_traced=True, cpu_acceptance_eligible=False,
                           phase_cpu_comparison_available=False,
                           runtime_cpu_target={"evaluated": False, "within_limit": None, "limit_percent": 5})

    def runtime_checkpoint(self, label):
        self.verify_identity()
        snapshot = self.collector.snapshot()
        self.verify_identity()
        matches = [sample for sample in self.collector.samples
                   if sample.get("monotonic_seconds") == snapshot.get("runner_collector_sample_monotonic_seconds")]
        require(len(matches) == 1 and all(matches[0].get(key) == self.identity[key] for key in ("process_id", "birth_time_us")),
                "GPU runtime checkpoint lacks an owned kernel boundary")
        now = time.monotonic()
        point = {"label": label, "python_monotonic_seconds": now, "snapshot": snapshot, "resource_sample": matches[0]}
        self.runtime["checkpoints"].append(point)
        self.save()
        require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True,
                "GPU runtime windows are not both natively visible")
        self.validate_control_snapshot(snapshot)
        began = self.report.get("workload", {}).get("started_monotonic_seconds")
        if self.completing:
            require(snapshot.get("active_requests") == 0, "Completed GPU streams remain active")
        elif began is not None and 1 < now - began < STAGE["seconds"] - .25:
            require(snapshot.get("active_requests") == 2 and snapshot.get("partial_output_tokens", 0) > 0,
                    "Short GPU traffic lost both active streams")
            previous = self.runtime["checkpoints"][-2]
            if now - previous["python_monotonic_seconds"] >= .5 and previous["snapshot"].get("active_requests") == 2:
                require(snapshot["output_tokens"] > previous["snapshot"]["output_tokens"], "GPU traffic token accounting stopped")
        self.next_checkpoint = now + 1
        return point

    def perform(self, paths, provenance, identity):
        self.report.update(production_provenance=provenance, measurement_identity=identity,
                           binary_identity={name: {"path": str(path), "sha256": app.path_hash(path)} for name, path in paths.items()})
        self.fixture, upstream = app.launch_fixture(self.output, timeout=self.deadline.remaining(5))
        directory = self.output / "owned-app"
        directory.mkdir()
        configuration = {"upstream_url": upstream, "history": "populated", "protocol_version": 1,
                         "logging_enabled": False, "fixture_ending_at_epoch": time.time(), "graphics_mode": self.graphics_mode}
        write_json(directory / "configuration.json", configuration)
        self.collector = self.create_collector(paths["collector"], paths["app"], configuration, {}, directory, self.deadline,
                            {"external_trace": True, "provenance": provenance, "fixture_schema_version": 2})
        ready = self.collector.ready()
        self.report["ready"] = ready
        seed = ready.get("snapshot", {})
        require(ready.get("fixture_schema_version") == 2 and isinstance(ready.get("fixture_equivalence_sha256"), str)
                and ready["fixture_equivalence_sha256"] == provenance.get("fixture_equivalence_sha256", {}).get("populated"),
                "Short GPU populated fixture differs from provenance")
        require(seed.get("history_verified") is True and seed.get("history") == "populated"
                and (seed.get("seed_persistent_requests"), seed.get("seed_raw_requests"), seed.get("seed_tool_events")) == (19000, 256, 38512),
                "Short GPU populated history dimensions differ")
        self.validate_control_snapshot(seed)
        self.identity = memory.authenticate_ready(self.collector, self.validate_control_snapshot)
        self.report["owned_identity"] = self.identity
        logging = self.command("set_logging", enabled=False)
        require(logging.get("logging_enabled") is False and logging.get("drained") is True, "GPU logging did not disable and drain")
        self.command("show_dashboard")
        self.command("show_popover")
        self.collector.wait_until(time.monotonic() + 2)
        self.checkpoint("visible-idle", True, True, 0)
        self.begin_runtime()
        before = self.runtime["checkpoints"][-1]["snapshot"]
        began = time.monotonic()
        acknowledgment = app.fixture_request(upstream, "/control/start", self.deadline, {
            "proxy_url": ready["proxy_url"], "duration_seconds": STAGE["seconds"], "rate_hz": 200, "concurrency": 2, "cycle": CYCLE})
        app.validate_fixture_start(STAGE, acknowledgment)
        self.report["workload"] = {"specification": dict(STAGE), "fixture_start": acknowledgment, "before": before,
                                   "started_monotonic_seconds": began, "validated": False}
        self.save()
        self.collector.wait_until(began + STAGE["seconds"])
        status = app.completed_status(self.collector, upstream, self.deadline)
        self.completing = True
        after = self.runtime_checkpoint("completion-begin")["snapshot"]
        work = app.validate_workload(STAGE, status, before, after, acknowledgment)
        require(work == WORK, "Short GPU fixture work differs")
        self.report["workload"].update(fixture_status=status, after=after, validated_work=work, validated=True,
                                      graphics_validation=self.validate_graphics_snapshot(after, completed_visible_workload=True))
        self.collector.wait_until(time.monotonic() + 3.01)
        self.runtime_checkpoint("completion-end")
        self.tracking = False
        self.command("close_popover")
        self.command("close_dashboard")
        self.collector.wait_until(time.monotonic() + 1)
        self.checkpoint("closed-start", False, False, 0)
        self.collector.wait_until(time.monotonic() + 2.01)
        self.checkpoint("closed-end", False, False, 0)
        self.runtime["mach_clock_end"] = runtime._mach_clock()
        self.collector.finish()

    def cleanup(self):
        try:
            super().cleanup()
        finally:
            exclude_cpu_acceptance(self.report)


def exclude_cpu_acceptance(report):
    report.update(cpu_gate_evaluated=False, cpu_acceptance_eligible=False, phase_cpu_comparison_available=False)
    report.setdefault("runtime", {}).update(cpu_comparison_available=False, profiled=True)
    raw = report.get("workload_cpu")
    if raw is not None and raw.get("available"):
        raw.update(acceptance_eligible=False, gate_evaluated=False, within_limit=None)
        report["gpu_perturbed_kernel_cpu"] = raw
    report["workload_cpu"] = {"available": False, "gate_evaluated": False, "acceptance_eligible": False,
                              "reason": "GPU recording perturbs execution; use the separate unprofiled CPU protocol"}
    report["workload_cpu_work_counters"] = {"available": False, "gate_evaluated": False, "acceptance_eligible": False,
                                            "reason": "External GPU trace; no CPU comparison"}
    report["runtime_cpu_target"] = {"evaluated": False, "within_limit": None, "limit_percent": 5}
    for metrics in report.get("phase_cpu", {}).values():
        metrics["acceptance_eligible"] = False


def validate_report(report, mode):
    require(not report["errors"] and report.get("workload", {}).get("validated"), "Short GPU app capture is incomplete")
    require(report["graphics_mode"] == mode and report["native_inspection_enabled"] is False
            and report["probes"] == [] and report["no_popover_animation_requested"] is False,
            "Short GPU app mode, inspectors, or animation policy differ")
    require(report["memory_validation"]["problems"] == [], "GPU memory/exit accounting is invalid")
    workload = report["workload"]
    require(workload["specification"] == STAGE and workload["validated_work"] == WORK
            and app.validate_workload(STAGE, workload["fixture_status"], workload["before"], workload["after"], workload["fixture_start"]) == WORK,
            "Short GPU workload does not match the eight-second fixture")
    memory.validate_sample_identities(report["samples"], report["owned_identity"])
    exits = [event for event in report["events"] if event.get("type") == "exited"]
    require(len(exits) == 1 and exits[0].get("status") == 0 and exits[0].get("final_sample") == report["samples"][-1]
            and report["samples"][-1].get("phase") == "final", "GPU final owned exit is incomplete")
    points = report["runtime"]["checkpoints"]
    report["phase_windows"] = phase_windows(report)
    report["visual_work"] = validate_visual_identity(report)
    report["runtime_work"] = runtime.validate_runtime_work(points[0]["snapshot"], points[-1]["snapshot"], mode)
    report["canvas_clock_work"] = validate_short_clock_work(report, mode)
    scalar_work = runtime.validate_scalar_presentation_checkpoints(report, mode,
        closed_labels=("closed-start", "closed-end"), minimum_closed_seconds=2,
        boundary=lambda point: snapshot_time(report, point))
    if scalar_work is not None:
        report["scalar_presentation_work"] = scalar_work
    # Reuse strict Mach/sample validation; these traced CPU values are diagnostics only.
    report["phase_cpu"] = runtime.phase_cpu(report, report["phase_windows"])
    for point in report["checkpoints"]:
        require(all(point["snapshot"].get(key) == value for key, value in point["expected_state"].items()),
                "GPU native checkpoint visibility/activity changed")
        snapshot_time(report, point)
    for point in points + report["checkpoints"]:
        memory.validate_graphics(point["snapshot"], mode, require_native_normal=True)
        memory.validate_popover_animation(point["snapshot"], False)
        require(memory.runtime_feature_contract(point["snapshot"]["graphics_diagnostics"], mode) == report["runtime_work"]["features"],
                "GPU rendering feature contract changed")
    require((mode in memory.METAL_CHART_MODES or workload["after"]["canvas_draws"] > workload["before"]["canvas_draws"])
            and workload["after"]["chart_preparations"] > workload["before"]["chart_preparations"],
            "GPU visible rendering/preparation did not advance")
    exclude_cpu_acceptance(report)


def capture_case(output, mode, paths, provenance, identity, deadline):
    output.mkdir()
    diagnostic = ShortGPUDiagnostic(output, deadline, mode)
    try:
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
            diagnostic.perform(paths, provenance, identity)
    except ERRORS + (KeyboardInterrupt,) as error:
        diagnostic.report["errors"].append(str(error) or "Interrupted")
    finally:
        try:
            with deadline.interrupt_at(deadline.end - .5):
                diagnostic.cleanup()
        except ERRORS + (KeyboardInterrupt,) as error:
            diagnostic.report["errors"].append("GPU app cleanup: " + (str(error) or "Interrupted"))
            # A deadline may expire before cleanup's context is entered. Still
            # attempt each owned child independently, including the fixture.
            for label, action in (
                    ("fixture", lambda: memory.stop_owned_child(diagnostic.fixture, deadline)
                     if getattr(diagnostic, "fixture", None) is not None else None),
                    ("collector", lambda: diagnostic.emergency_collector_cleanup()
                     if getattr(diagnostic, "collector", None) is not None else None)):
                try:
                    action()
                except ERRORS + (KeyboardInterrupt,) as cleanup_error:
                    diagnostic.report["errors"].append(label + " emergency cleanup: " + (str(cleanup_error) or "Interrupted"))
    report = diagnostic.report
    try:
        validate_report(report, mode)
        report["status"] = "diagnostic_captured"
    except ERRORS as error:
        report["errors"].append(str(error))
        report["status"] = "diagnostic_incomplete"
    exclude_cpu_acceptance(report)
    for name in ("runtime-case.json", "in-progress.json"):
        write_json(output / name, report)
    return report


def register_report(trace, report, label, driver_exited_at):
    samples = report["samples"]
    memory.validate_sample_identities(samples, report["owned_identity"])
    pid, birth = report["owned_identity"]["process_id"], report["owned_identity"]["birth_time_us"]
    def clock(sample):
        uncertainty = sample.get("clock_read_uncertainty_seconds")
        require(type(uncertainty) in (int, float) and math.isfinite(uncertainty) and 0 <= uncertainty <= .001,
                "Missing or imprecise collector Mach clock bridge")
        return trace.monotonic_from_mach_seconds(sample["mach_absolute_seconds"])
    start, end = clock(samples[0]), clock(samples[-1])
    require(trace.ready_monotonic <= start < end <= driver_exited_at, "GPU lifetime is outside ready recording or verified exit")
    points = {point["label"]: point for point in report["runtime"]["checkpoints"]}
    first, last = points["before-traffic"]["resource_sample"], points["completion-end"]["resource_sample"]
    require(first in samples and last in samples, "GPU window lacks paired owned kernel boundaries")
    left, right = clock(first), clock(last)
    require(start <= left < right <= end, "GPU runtime is outside app lifetime")
    expected = report["phase_windows"]["whole_contiguous_runtime"]
    require(abs(snapshot_time(report, points["before-traffic"]) - expected["start_monotonic_seconds"]) <= .000001
            and abs(snapshot_time(report, points["completion-end"]) - expected["end_monotonic_seconds"]) <= .000001,
            "GPU boundaries differ from the authenticated runtime definition")
    trace.register_process(pid, birth, start)
    trace.register_exit(pid, birth, end, driver_exited_at, 0)
    trace.add_window(label + "/lifetime", pid, birth, start, end)
    trace.add_window(label + "/workload", pid, birth, left, right)
    return {"process_id": pid, "birth_time_us": birth, "workload_window_name": label + "/workload",
            "lifetime_window_name": label + "/lifetime", "gpu_window_seconds": [left, right], "elapsed_seconds": right - left,
            "driver_exited_monotonic_seconds": driver_exited_at}


def qualify_result(result):
    selected = result.get("capture_case", "both")
    require(selected in ("both", "reference", "candidate"), "Unknown GPU capture selection")
    expected_labels = ["reference", "candidate"] if selected == "both" else [selected]
    gpu = result.get("gpu_trace", {})
    provider_valid = (gpu.get("valid") is True and gpu.get("recording_complete") is True and gpu.get("lost_events") is False
                      and gpu.get("calibration", {}).get("valid") is True and gpu.get("capture_scope", {}).get("validated") is True)
    for row in result["rows"]:
        workload = gpu.get("windows", {}).get(row["workload_window_name"], {})
        lifetime = gpu.get("windows", {}).get(row["lifetime_window_name"], {})
        terminal = gpu.get("final_exit_coverage", {}).get(row["workload_window_name"], {})
        lifetime_terminal = gpu.get("final_exit_coverage", {}).get(row["lifetime_window_name"], {})
        available = provider_valid and workload.get("coverage_complete") is True and terminal.get("complete") is True
        life_available = provider_valid and lifetime.get("coverage_complete") is True and lifetime_terminal.get("complete") is True
        row.update(gpu_window=workload, gpu_lifetime_window=lifetime, gpu_terminal=terminal, gpu_lifetime_terminal=lifetime_terminal,
                   gpu_window_available=available, gpu_lifetime_available=life_available, cpu_acceptance_eligible=False)
        def target(window, valid):
            key = "gpu_rolling_1s_percent" if window.get("attribution_exact") is True else "gpu_rolling_1s_percent_upper_bound"
            upper = window.get(key)
            require(not valid or (type(upper) in (int, float) and math.isfinite(upper) and upper >= 0),
                    "Qualified GPU metric lacks a finite conservative maximum")
            return {"evaluated": valid, "limit_percent": 1, "within_limit": upper <= 1 if valid else None}
        row["gpu_target"] = {"runtime": target(workload, available), "lifetime": target(lifetime, life_available)}
        if row.get("mode") in (*memory.METAL_CHART_MODES, *memory.PRIMITIVE_EFFECTS_MODES):
            row.update(promotion_eligible=False,
                       promotion_reason="Experimental renderer requires independent visual and frame-delivery qualification")
        if row.get("mode") == memory.FROZEN_SCALARS_MODE:
            row.update(promotion_eligible=False, gpu_acceptance_eligible=False,
                       promotion_reason="Frozen scalar presentation is a diagnostic ablation, not live production presentation")
            for name, window, available_window in (("runtime", workload, available), ("lifetime", lifetime, life_available)):
                observed = row["gpu_target"][name]["within_limit"]
                row["gpu_target"][name].update(evaluated=False, acceptance_eligible=False, within_limit=None,
                    observed_within_limit=observed if available_window else None,
                    reason="Frozen scalar presentation is a diagnostic ablation")
        if not available or not life_available:
            result["errors"].append(row["label"] + ": GPU window or owned exit/command-completion proof incomplete")
    if not provider_valid:
        result["errors"].append("GPU provider calibration/ownership/clock/loss validation incomplete: " + "; ".join(gpu.get("invalid", [])))
    result["cpu_acceptance_eligible"] = False
    result["cpu_comparison_available"] = False
    if [row["label"] for row in result["rows"]] != expected_labels:
        result["errors"].append("GPU capture rows do not exactly match the requested products: " + ", ".join(expected_labels))
    result["capture_available"] = (not result["errors"] and len(result["rows"]) == len(expected_labels)
                                   and all(row["gpu_window_available"] and row["gpu_lifetime_available"] for row in result["rows"]))
    result["comparison_available"] = selected == "both" and result["capture_available"]
    prefix = "gpu_comparison" if selected == "both" else "gpu_capture"
    result["status"] = prefix + ("_complete" if result["capture_available"] else "_incomplete")


def write_report(output, report):
    write_json(output / "gpu-comparison.json", report)
    def metric(row, key, lifetime=False):
        prefix = "gpu_lifetime" if lifetime else "gpu"
        if not row.get(prefix + "_available" if lifetime else "gpu_window_available"):
            return "unavailable"
        value = row[prefix + "_window" if lifetime else "gpu_window"]
        if value.get("attribution_exact") is True:
            return f"{value[key]:.4f}%"
        return f"{value[key + '_lower_bound']:.4f}–{value[key + '_upper_bound']:.4f}%"
    single = report.get("capture_case", "both") != "both"
    scope = ("One eight-second, 200 Hz × two-stream replay and three seconds of visible completion, in a calibrated trace. "
             "This independently captured product is not a paired comparison; comparison availability remains false."
             if single else "Two matching eight-second, 200 Hz × two-stream replays and three seconds of visible completion, in one calibrated trace.")
    lines = ["# Short process GPU " + ("capture" if single else "comparison"), "", f"Status: `{report['status']}`. {scope}", "",
             "| Product | Renderer mode | Runtime GPU mean | Runtime GPU max 1s | Lifetime GPU max 1s | Runtime ≤1% |", "|---|---|---:|---:|---:|---|"]
    for row in report["rows"]:
        target = row.get("gpu_target", {}).get("runtime", {})
        result = ("pass" if target.get("within_limit") else "miss") if target.get("evaluated") else "unavailable"
        lines.append(f"| {row['label']} | {row.get('mode', report.get('graphics_mode', 'unavailable'))} | {metric(row, 'gpu_percent')} | {metric(row, 'gpu_rolling_1s_percent')} | {metric(row, 'gpu_rolling_1s_percent', True)} | {result} |")
    lines += ["", "GPU percentages are owned-process additive execution time divided by elapsed time, not device utilization. CPU values are perturbed diagnostics and cannot establish CPU acceptance. This short protocol must not be pooled with the ordinary 25-second CPU workload or older GPU runs.", "",
              "| Phase | Absolute deadline from invocation |", "|---|---:|"]
    lines += [f"| {name} | {seconds}s |" for name, seconds in PHASE_SECONDS.items()]
    lines += ["| cleanup/report | 300s |", "", "Missing coverage remains unavailable. Original products and provenance are immutable; any external measurement rebinding is preserved separately.", ""]
    if report["errors"]:
        lines += ["| Error |", "|---|"] + ["| " + str(error).replace("|", "/").replace("\n", " ") + " |" for error in report["errors"]]
    lines += ["", "[Exact sources, product bindings, workload, validation and trace evidence](gpu-comparison.json).", ""]
    (output / "gpu-comparison.md").write_text("\n".join(lines))


def parser():
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--reference-products", type=Path, required=True)
    value.add_argument("--candidate-products", type=Path, required=True)
    value.add_argument("--capture-case", choices=("both", "reference", "candidate"), default="both",
                       help="Record both products together, or one product in an independent calibrated trace")
    value.add_argument("--graphics-mode", choices=MODES, default="normal")
    value.add_argument("--reference-mode", choices=MODES,
                       help="Reference product mode; defaults to --graphics-mode")
    value.add_argument("--candidate-mode", choices=MODES,
                       help="Candidate product mode; defaults to --graphics-mode")
    value.add_argument("--output-dir", type=Path)
    value.add_argument("--rebind-measurement", action="store_true",
                       help="Preserve original provenance and explicitly bind current external measurement sources")
    return value


def run(argv=None):
    args = parser().parse_args(argv)
    selected_labels = ("reference", "candidate") if args.capture_case == "both" else (args.capture_case,)
    incomplete_status = "gpu_comparison_incomplete" if args.capture_case == "both" else "gpu_capture_incomplete"
    modes = {label: getattr(args, label + "_mode") or args.graphics_mode for label in ("reference", "candidate")}
    deadline = runtime.RuntimeDeadline(MAX_SECONDS, cleanup_reserve=0)
    started = deadline.end - MAX_SECONDS
    output = (args.output_dir or app.ROOT / ".performance-results" /
              ("gpu-comparison-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S-") + secrets.token_hex(4))).resolve()
    report = {"kind": "short-matched-process-gpu-comparison" if args.capture_case == "both" else "short-independent-process-gpu-capture",
              "schema_version": 1, "status": incomplete_status, "capture_case": args.capture_case,
              "capture_scope": "same-trace paired products" if args.capture_case == "both" else "single product; separate captures are not a paired comparison",
              "regression_passed": False, "deadline_seconds": MAX_SECONDS, "phase_budget_seconds": PHASE_SECONDS,
              "graphics_mode": args.graphics_mode, "product_graphics_modes": modes, "rows": [], "attempts": [], "errors": [],
              "capture_available": False, "comparison_available": False, "cpu_acceptance_eligible": False, "cpu_comparison_available": False,
              "workload_specification": STAGE, "expected_work": WORK}
    created, trace, products, sources = False, None, {}, None
    try:
        require(sys.platform == "darwin", "Native GPU comparison requires macOS")
        require(not output.exists(), "Never overwrite GPU comparison artifacts")
        require(app.ROOT not in output.parents or app.ROOT / ".performance-results" in output.parents,
                "In-repository GPU artifacts must remain ignored")
        output.mkdir(parents=True)
        created = True
        sources = source_identity()
        report["runtime_source_identity"] = sources
        capsule = output / "measurement-source"
        capsule.mkdir()
        for name, digest in sources.items():
            shutil.copyfile(Path(__file__).with_name(name), capsule / name)
            require(app.path_hash(capsule / name) == digest, "GPU measurement source changed during copy")
        with deadline.interrupt_at(started + PHASE_SECONDS["record"]):
            for label in ("reference", "candidate"):
                products[label] = load_products(getattr(args, label + "_products"), output, label,
                                                rebind_measurement=args.rebind_measurement)
            reference, candidate = products["reference"], products["candidate"]
            require(reference["identity"] == candidate["identity"], "GPU products have different common measurement identities")
            require(reference["files"]["collector"]["sha256"] == candidate["files"]["collector"]["sha256"],
                    "GPU products must use identical frozen collector bytes")
            require(reference["provenance"]["fixture_equivalence_sha256"]["populated"] == candidate["provenance"]["fixture_equivalence_sha256"]["populated"],
                    "GPU products have different populated fixture identities")
            report["products"] = {label: {"files": product["files"], "production_provenance": product["provenance"],
                                         "measurement_identity": product["identity"]} for label, product in products.items()}
            write_report(output, report)
            trace = TraceSession(output, deadline.end, phase_deadlines={name: started + seconds for name, seconds in PHASE_SECONDS.items()},
                                 record_limit_seconds=PHASE_SECONDS["record"])
            report["trace_start"] = trace.start()
            report["calibration_setup"] = trace.calibrate(candidate["paths"]["collector"])
            require(not trace.invalid, "GPU calibration setup failed: " + "; ".join(trace.invalid))
            for ordinal, label in enumerate(selected_labels):
                require(time.monotonic() + CASE_SECONDS * (len(selected_labels) - ordinal) <= started + PHASE_SECONDS["record"],
                        "Insufficient recording budget for the requested GPU workloads and owned cleanup")
                require(source_identity() == sources and all(product_identity(value["paths"], value["provenance"]) == value["files"]
                                                            for value in products.values()), "GPU sources or frozen products changed before capture")
                product = products[label]
                attempt = {"label": label, "started_monotonic_seconds": time.monotonic(), "status": "running"}
                report["attempts"].append(attempt)
                write_report(output, report)
                case_deadline = runtime.RuntimeDeadline(CASE_SECONDS, cleanup_reserve=5)
                case = capture_case(output / label, modes[label], product["paths"], product["provenance"], product["identity"], case_deadline)
                ended = time.monotonic()
                path = output / label / "runtime-case.json"
                attempt.update(ended_monotonic_seconds=ended, elapsed_seconds=ended - attempt["started_monotonic_seconds"],
                               report_path=str(path), report_sha256=app.path_hash(path), status=case["status"])
                require(source_identity() == sources and all(product_identity(value["paths"], value["provenance"]) == value["files"]
                                                            for value in products.values()), "GPU sources or frozen products changed during capture")
                require(case["status"] == "diagnostic_captured", label + " short GPU replay is incomplete; see preserved report")
                row = {"label": label, "mode": modes[label], "report_path": str(path), "report_sha256": app.path_hash(path),
                       "validated_work": case["workload"]["validated_work"], "visual_work": case["visual_work"],
                       "runtime_work": case["runtime_work"], **register_report(trace, case, label, ended)}
                report["rows"].append(row)
                write_report(output, report)
    except ERRORS + (KeyboardInterrupt,) as error:
        report["errors"].append(str(error) or "Interrupted")
    finally:
        if trace is not None:
            try:
                report["gpu_trace"] = trace.finish()
            except ERRORS + (KeyboardInterrupt,) as error:
                report["errors"].append("GPU finalization failed: " + (str(error) or "Interrupted"))
        if created:
            try:
                with deadline.interrupt_at(deadline.end - 1):
                    if sources is not None:
                        require(source_identity() == sources, "GPU measurement sources changed before finalization")
                    require(all(product_identity(value["paths"], value["provenance"]) == value["files"] for value in products.values()),
                            "GPU frozen products changed before finalization")
                    qualify_result(report)
            except ERRORS as error:
                report["errors"].append(str(error))
                report.update(status=incomplete_status, capture_available=False, comparison_available=False)
            report["elapsed_seconds"] = time.monotonic() - started
            if report["elapsed_seconds"] > MAX_SECONDS:
                report["errors"].append("GPU comparison exceeded the shared 300-second deadline")
                report.update(status=incomplete_status, capture_available=False, comparison_available=False)
            write_report(output, report)
    print(f"{report['status']}: {output}", flush=True)
    return 0 if report["capture_available"] else 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(run())
