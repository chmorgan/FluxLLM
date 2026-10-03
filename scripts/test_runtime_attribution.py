"""Mocked runtime comparison contracts; no app, recorder, or fixture launch."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import memory_attribution as memory
import runtime_attribution as runtime
from test_memory_diagnostic import drawn_native_gpu_graphics


def workload_snapshots(mode):
    before = drawn_native_gpu_graphics(mode)
    value = before["graphics_diagnostics"]
    if mode not in memory.RUNTIME_MODES:
        value.update(incremental_history_ordering=False, optimized_chart_preparation=False,
                     lifecycle_effects_enabled=True)
    for field in runtime.COUNTERS:
        before[field] = 10
    after = copy.deepcopy(before)
    after["chart_preparations"] += 2
    if mode == memory.NO_ARRIVAL_MODE:
        after["suppressed_arrival_effects"] += 2
    if mode == memory.METAL_ARRIVAL_MODE:
        after["metal_arrival_frames"] += 2
        after["metal_arrival_submissions"] += 2
    if mode == memory.COMPACT_TOOL_PATHS_MODE:
        after["tool_path_input_points"] += 100
        after["tool_path_output_points"] += 30
    if mode in memory.DEFERRED_TOOL_GEOMETRY_MODES + (memory.METAL_ARRIVAL_MODE,):
        after["tool_path_input_points"] += 100
        after["tool_path_output_points"] += 100
    if value.get("ordered_chart_publication"):
        after["ordered_chart_publication_queries"] += 2
    if value.get("direct_tool_plot"):
        after["direct_tool_plot_builds"] += 2
    elif "direct_tool_plot" in value:
        after["legacy_tool_plot_builds"] += 2
    if value.get("canvas_frame_clock"):
        after["rail_frame_clock_ticks"] += 2
    if value.get("shared_chart_preparation"):
        after["shared_chart_preparations"] += 2
        after["shared_chart_normalization_builds"] += 1
    if value.get("unpromised_stream_body_writes"):
        after["streamed_bodies_without_promises"] += 2
    if value["optimized_chart_preparation"]:
        after["optimized_chart_preparations"] += 2
    if value["incremental_history_ordering"]:
        after["history_tool_order_insertions"] += 2
        after["history_completed_order_insertions"] += 2
    else:
        after["history_tool_order_builds"] += 1
        after["history_completed_order_builds"] += 1
    if mode == memory.HELD_STATIC_CHART_MODE:
        before.update(dashboard_visible=True, popover_visible=True, runner_collector_sample_monotonic_seconds=100)
        after.update(dashboard_visible=True, popover_visible=True, runner_collector_sample_monotonic_seconds=103)
        after["graphics_diagnostics"]["roles"]["static_chart"]["drawing_update_attempts"] += 2
        after["graphics_diagnostics"]["roles"]["static_chart"]["drawing_updates_held"] += 2
    else:
        after["graphics_diagnostics"]["roles"]["static_chart"]["draws"] += 2
    if value["lifecycle_effects_enabled"]:
        after["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] += 1
    if "ungrouped_native_canvas" in value:
        total = sum(role["draws"] for role in after["graphics_diagnostics"]["roles"].values())
        field = "ungrouped_native_canvas_draws" if value["ungrouped_native_canvas"] else "grouped_native_canvas_draws"
        after["graphics_diagnostics"]["native_gpu_canvas_draws"] = after[field] = total
    return before, after


def clock_work_report(mode="runtime-canvas-clock"):
    before, after = workload_snapshots(mode)
    samples = []
    def point(label, elapsed, snapshot, active, visible=True):
        snapshot = copy.deepcopy(snapshot)
        sample = {"monotonic_seconds": 100 + elapsed, "mach_absolute_seconds": 1000 + elapsed,
                  "process_id": 123, "birth_time_us": 456}
        samples.append(sample)
        snapshot.update(runner_collector_sample_monotonic_seconds=sample["monotonic_seconds"],
                        dashboard_visible=visible, popover_visible=visible, active_requests=active)
        snapshot["canvas_draws"] = snapshot["graphics_diagnostics"]["native_gpu_canvas_draws"] = sum(
            role["draws"] for role in snapshot["graphics_diagnostics"]["roles"].values())
        return {"label": label, "snapshot": snapshot, "resource_sample": sample}
    steady = copy.deepcopy(before)
    points = [point("before-traffic", 0, before, 0)]
    if mode in (memory.NO_ARRIVAL_MODE, memory.METAL_ARRIVAL_MODE):
        if mode == memory.NO_ARRIVAL_MODE:
            steady["suppressed_arrival_effects"] = after["suppressed_arrival_effects"]
        else:
            steady.update({field: after[field] for field in memory.METAL_ARRIVAL_COUNTERS})
        points.append(point("after-arrival", 2.5, steady, 2))
    else:
        steady["rail_frame_clock_ticks"] += 1
    points += [point("during-6", 6, steady, 2), point("during-19", 19, steady, 2)]
    if mode in (memory.NO_ARRIVAL_MODE, memory.METAL_ARRIVAL_MODE):
        points += [point("completion-begin", 25.1, steady, 0), point("during-completion", 27, after, 0)]
    points.append(point("completion-end", 29, after, 0))
    closed = [point("07-both-closed-after-probe", 32, after, 0, False),
              point("08-closed-after-five-more-seconds", 37, after, 0, False)]
    return {"runtime": {"checkpoints": points, "mach_clock_start": {"absolute_minus_monotonic_seconds": 900},
                        "mach_clock_end": {"absolute_minus_monotonic_seconds": 900}},
            "checkpoints": closed, "samples": samples, "owned_identity": {"process_id": 123, "birth_time_us": 456},
            "phase_windows": {"arrival": {"start_monotonic_seconds": 100.1, "end_monotonic_seconds": 102.1},
                              "steady": {"start_monotonic_seconds": 105, "end_monotonic_seconds": 120},
                              "completion": {"start_monotonic_seconds": 125, "end_monotonic_seconds": 128},
                              "whole_contiguous_runtime": {"start_monotonic_seconds": 100, "end_monotonic_seconds": 129}}}


def options(**kwargs):
    return SimpleNamespace(**({"operation": "compare", "graphics_mode": "normal",
                              "baseline_mode": "native-gpu-optimized", "controls": None} | kwargs))


def case(label, average=3.25, peak=4.75):
    return {"label": label, "peak_footprint_bytes": 50_000_000,
            "phase_cpu": {"whole_contiguous_runtime": {
                "average_cpu_percent": average, "rolling_1s_percent": peak}},
            "runtime_cpu_target": {"evaluated": True, "within_limit": peak <= 5},
            "workload_cpu": {"available": True, "average_cpu_percent": 99.123,
                             "rolling_1s_percent": 98.765}}


class CaseSelectionTests(unittest.TestCase):
    def test_default_compare_brackets_combined_control(self):
        self.assertEqual(runtime.selected_cases(options()), [
            ("baseline-before", "native-gpu-optimized"),
            ("runtime-optimized", "runtime-optimized"),
            ("baseline-after", "native-gpu-optimized")])

    def test_profile_selects_one_requested_mode(self):
        self.assertEqual(runtime.selected_cases(options(operation="profile")), [("profile", "normal")])
        self.assertEqual(runtime.selected_cases(options(operation="profile", graphics_mode="runtime-history-order")),
                         [("profile", "runtime-history-order")])

    def test_three_distinct_controls_preserve_order_and_baseline(self):
        controls = ["runtime-history-order", "runtime-chart-preparation", "runtime-no-lifecycle"]
        self.assertEqual(runtime.selected_cases(options(controls=controls, baseline_mode="normal")),
                         [("baseline-before", "normal"), *[(mode, mode) for mode in controls], ("baseline-after", "normal")])

    def test_normal_control_exercises_the_production_default_between_baselines(self):
        args = runtime.parser().parse_args(["compare", "--app-binary", "/app", "--test-bundle", "/tests",
            "--collector-binary", "/collector", "--provenance", "/provenance", "--controls", "normal"])
        self.assertEqual(runtime.selected_cases(args), [("baseline-before", "native-gpu-optimized"),
            ("normal", "normal"), ("baseline-after", "native-gpu-optimized")])
        with self.assertRaisesRegex(ValueError, "distinct runtime controls"):
            runtime.selected_cases(options(controls=["normal", "normal"]))

    def test_more_than_three_or_duplicate_controls_rejected(self):
        for controls in (list(memory.RUNTIME_MODES), ["runtime-optimized", "runtime-optimized"]):
            with self.subTest(controls=controls), self.assertRaisesRegex(ValueError, "distinct runtime controls"):
                runtime.selected_cases(options(controls=controls))


class RuntimeWorkTests(unittest.TestCase):
    def test_baseline_and_each_control_execute_expected_paths(self):
        for mode in ("native-gpu-optimized", *memory.RUNTIME_MODES):
            with self.subTest(mode=mode):
                before, after = workload_snapshots(mode)
                result = runtime.validate_runtime_work(before, after, mode)
                self.assertTrue(result["available"])
                self.assertEqual(result["deltas"]["chart_preparations"], 2)
                self.assertEqual(result["deltas"]["static_chart_draws"], 0 if mode == memory.HELD_STATIC_CHART_MODE else 2)
                self.assertEqual(result["features"], {field: after["graphics_diagnostics"][field] for field in memory.RUNTIME_FLAGS + memory.NEXT_RUNTIME_FLAGS + ("canvas_frame_clock", "ordered_chart_publication", "direct_tool_plot", "ungrouped_native_canvas", "arrival_effects_enabled", "compact_tool_paths_enabled", "deferred_tool_geometry_enabled", "metal_arrival_bursts_enabled", "holds_static_chart_drawing") if field in after["graphics_diagnostics"]})

    def test_chart_preparation_requires_complete_optimized_coverage(self):
        for delta in (0, 1, 3):
            before, after = workload_snapshots("runtime-chart-preparation")
            after["optimized_chart_preparations"] = before["optimized_chart_preparations"] + delta
            with self.subTest(delta=delta), self.assertRaisesRegex(ValueError, "cover every"):
                runtime.validate_runtime_work(before, after, "runtime-chart-preparation")

    def test_baseline_rejects_optimized_preparation(self):
        before, after = workload_snapshots("native-gpu-optimized")
        after["optimized_chart_preparations"] += 1
        with self.assertRaisesRegex(ValueError, "Baseline executed optimized"):
            runtime.validate_runtime_work(before, after, "native-gpu-optimized")

    def test_incremental_order_rejects_full_builds_for_each_order(self):
        for field in ("history_tool_order_builds", "history_completed_order_builds"):
            before, after = workload_snapshots("runtime-history-order")
            after[field] += 1
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "rebuilt a full"):
                runtime.validate_runtime_work(before, after, "runtime-history-order")

    def test_incremental_order_requires_both_insertion_paths(self):
        for field in ("history_tool_order_insertions", "history_completed_order_insertions"):
            before, after = workload_snapshots("runtime-history-order")
            after[field] = before[field]
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "tool and completed-request insertion"):
                runtime.validate_runtime_work(before, after, "runtime-history-order")

    def test_baseline_rejects_both_incremental_insertion_paths(self):
        for field in ("history_tool_order_insertions", "history_completed_order_insertions"):
            before, after = workload_snapshots("native-gpu-optimized")
            after[field] += 1
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Baseline executed incremental"):
                runtime.validate_runtime_work(before, after, "native-gpu-optimized")

    def test_no_lifecycle_changes_only_lifecycle_from_optimized(self):
        optimized = runtime.validate_runtime_work(*workload_snapshots("runtime-optimized"), "runtime-optimized")
        no_lifecycle = runtime.validate_runtime_work(*workload_snapshots("runtime-no-lifecycle"), "runtime-no-lifecycle")
        self.assertEqual(no_lifecycle["features"], optimized["features"] | {"lifecycle_effects_enabled": False})
        self.assertEqual(no_lifecycle["deltas"]["optimized_chart_preparations"], 2)
        self.assertEqual(no_lifecycle["deltas"]["history_tool_order_insertions"], 2)
        self.assertEqual(no_lifecycle["deltas"]["history_completed_order_insertions"], 2)

    def test_no_lifecycle_rejects_decoration_drawing(self):
        before, after = workload_snapshots("runtime-no-lifecycle")
        after["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] += 1
        with self.assertRaisesRegex(ValueError, "still drew lifecycle"):
            runtime.validate_runtime_work(before, after, "runtime-no-lifecycle")

    def test_unchanged_chart_or_static_draws_cannot_claim_execution(self):
        before, after = workload_snapshots("runtime-optimized")
        after["chart_preparations"] = before["chart_preparations"]
        with self.assertRaisesRegex(ValueError, "did not prepare"):
            runtime.validate_runtime_work(before, after, "runtime-optimized")
        before, after = workload_snapshots("runtime-optimized")
        after["graphics_diagnostics"]["roles"]["static_chart"]["draws"] = before["graphics_diagnostics"]["roles"]["static_chart"]["draws"]
        with self.assertRaisesRegex(ValueError, "did not redraw"):
            runtime.validate_runtime_work(before, after, "runtime-optimized")

    def test_counters_must_be_unsigned_present_and_monotonic(self):
        for field in runtime.COUNTERS:
            for invalid in (None, True, -1, 9):
                before, after = workload_snapshots("runtime-optimized")
                after[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    runtime.validate_runtime_work(before, after, "runtime-optimized")

    def test_feature_contract_cannot_change_or_be_incomplete(self):
        for field in memory.RUNTIME_FLAGS:
            before, after = workload_snapshots("runtime-optimized")
            del after["graphics_diagnostics"][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, after, "runtime-optimized")
        before, after = workload_snapshots("runtime-optimized")
        before["graphics_diagnostics"]["mode"] = after["graphics_diagnostics"]["mode"] = "normal"
        before["graphics_diagnostics"].update(incremental_history_ordering=False, optimized_chart_preparation=False)
        with self.assertRaisesRegex(ValueError, "stable complete"):
            runtime.validate_runtime_work(before, after, "normal")

    def test_legacy_normal_allowed_only_for_optional_profile_diagnostics(self):
        before = drawn_native_gpu_graphics("native-gpu-optimized")
        after = copy.deepcopy(before)
        self.assertFalse(runtime.validate_runtime_work(before, after, "normal", required=False)["available"])
        with self.assertRaisesRegex(ValueError, "stable complete"):
            runtime.validate_runtime_work(before, after, "normal")

    def test_both_drawing_counters_cannot_regress(self):
        for role in ("static_chart", "rail_decorations"):
            before, after = workload_snapshots("runtime-optimized")
            before["graphics_diagnostics"]["roles"][role]["draws"] = 10
            after["graphics_diagnostics"]["roles"][role]["draws"] = 9
            with self.subTest(role=role), self.assertRaisesRegex(ValueError, "drawing counter moved backwards"):
                runtime.validate_runtime_work(before, after, "runtime-optimized")


class MetalArrivalWorkTests(unittest.TestCase):
    def test_work_proof_keeps_canvas_counts_separate_and_positive_completion_required(self):
        mode = memory.METAL_ARRIVAL_MODE
        before, after = workload_snapshots(mode)
        work = runtime.validate_runtime_work(before, after, mode)
        self.assertEqual(work["arrival_backend"], "metal-shader")
        self.assertEqual(work["deltas"]["metal_arrival_frames"], 2)
        self.assertEqual(work["deltas"]["metal_arrival_submissions"], 2)
        self.assertEqual(work["deltas"]["metal_arrival_failures"], 0)
        self.assertEqual(work["deltas"]["grouped_native_canvas_draws"], 3)
        for field in ("metal_arrival_frames", "metal_arrival_submissions"):
            after[field] = before[field]
        with self.assertRaisesRegex(ValueError, "did not submit rendered frames"):
            runtime.validate_runtime_work(before, after, mode)
        before, after = workload_snapshots(mode)
        after["rail_frame_clock_ticks"] = before["rail_frame_clock_ticks"]
        with self.assertRaisesRegex(ValueError, "did not execute frame ticks"):
            runtime.validate_runtime_work(before, after, mode)

    def test_metadata_and_counters_cannot_disappear_or_move_backwards(self):
        mode = memory.METAL_ARRIVAL_MODE
        for fault in ("backend", "flag", "counter", "decreasing", "failure"):
            before, after = workload_snapshots(mode)
            if fault == "backend":
                after["graphics_diagnostics"]["arrival_backend"] = "canvas"
            elif fault == "flag":
                del after["graphics_diagnostics"]["metal_arrival_bursts_enabled"]
            elif fault == "counter":
                del after["metal_arrival_frames"]
            elif fault == "decreasing":
                after["metal_arrival_frames"] = after["metal_arrival_submissions"] = 1
            else:
                after["metal_arrival_failures"] = 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, after, mode)

    def test_phase_proof_requires_real_arrival_submission_and_canvas_completion(self):
        mode = memory.METAL_ARRIVAL_MODE
        report = clock_work_report(mode)
        proof = runtime.validate_canvas_clock_work(report, mode)
        self.assertEqual(proof["arrival_effects"]["arrival"]["deltas"]["metal_arrival_submissions"], 2)
        self.assertGreater(proof["arrival_effects"]["completion"]["deltas"]["rail_frame_clock_ticks"], 0)
        self.assertGreater(proof["arrival_effects"]["completion"]["deltas"]["rail_decorations_draws"], 0)
        self.assertEqual(proof["steady"]["deltas"]["metal_arrival_frames"], 0)
        self.assertEqual(proof["closed"]["metal_arrival_deltas"]["metal_arrival_submissions"], 0)

    def test_late_submission_idle_activity_and_missing_phase_proof_are_rejected(self):
        mode = memory.METAL_ARRIVAL_MODE
        for fault in ("late", "steady", "closed", "arrival-boundary", "completion-clock", "completion-draw", "backend"):
            report = clock_work_report(mode)
            points = report["runtime"]["checkpoints"]
            by_label = {point["label"]: point for point in points}
            if fault == "late":
                for point in points[1:5]:
                    for field in memory.METAL_ARRIVAL_COUNTERS:
                        point["snapshot"][field] = points[0]["snapshot"][field]
            elif fault in ("steady", "closed"):
                affected = points[3:] + report["checkpoints"] if fault == "steady" else report["checkpoints"][1:]
                for point in affected:
                    point["snapshot"]["metal_arrival_frames"] += 1
                    point["snapshot"]["metal_arrival_submissions"] += 1
            elif fault == "arrival-boundary":
                points.remove(by_label["after-arrival"])
            elif fault == "completion-clock":
                by_label["completion-begin"]["snapshot"]["rail_frame_clock_ticks"] = by_label["during-completion"]["snapshot"]["rail_frame_clock_ticks"]
            elif fault == "completion-draw":
                by_label["during-completion"]["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = 0
            else:
                by_label["after-arrival"]["snapshot"]["graphics_diagnostics"]["arrival_backend"] = "canvas"
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, mode)

    def test_normal_bracket_accepts_new_control_without_changing_limits(self):
        mode = memory.METAL_ARRIVAL_MODE
        args = runtime.parser().parse_args(["compare", "--app-binary", "/app", "--test-bundle", "/tests",
            "--collector-binary", "/collector", "--provenance", "/provenance", "--baseline-mode", "normal", "--controls", mode])
        self.assertEqual(runtime.selected_cases(args), [("baseline-before", "normal"), (mode, mode), ("baseline-after", "normal")])
        self.assertEqual(runtime.MAX_SECONDS, 300)


class NoArrivalWorkTests(unittest.TestCase):
    def test_zero_traffic_ticks_do_not_satisfy_whole_runtime_completion_work(self):
        before, completion = workload_snapshots(memory.NO_ARRIVAL_MODE)
        before["rail_frame_clock_ticks"] = 0
        completion["rail_frame_clock_ticks"] = 58
        completion["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = 59
        total = sum(role["draws"] for role in completion["graphics_diagnostics"]["roles"].values())
        completion["graphics_diagnostics"]["native_gpu_canvas_draws"] = completion["grouped_native_canvas_draws"] = total
        self.assertTrue(runtime.validate_runtime_work(before, completion, memory.NO_ARRIVAL_MODE)["available"])
        traffic_ack = copy.deepcopy(completion)
        traffic_ack["rail_frame_clock_ticks"] = 0
        traffic_ack["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = 0
        total = sum(role["draws"] for role in traffic_ack["graphics_diagnostics"]["roles"].values())
        traffic_ack["graphics_diagnostics"]["native_gpu_canvas_draws"] = traffic_ack["grouped_native_canvas_draws"] = total
        self.assertTrue(memory.validate_graphics(traffic_ack, memory.NO_ARRIVAL_MODE, completed_visible_workload=True)["available"])
        with self.assertRaisesRegex(ValueError, "did not execute frame ticks"):
            runtime.validate_runtime_work(before, traffic_ack, memory.NO_ARRIVAL_MODE)

    def test_no_arrival_work_proves_suppression_and_preserves_other_production_paths(self):
        before, after = workload_snapshots(memory.NO_ARRIVAL_MODE)
        work = runtime.validate_runtime_work(before, after, memory.NO_ARRIVAL_MODE)
        self.assertGreater(work["deltas"]["suppressed_arrival_effects"], 0)
        self.assertFalse(work["features"]["arrival_effects_enabled"])
        self.assertTrue(work["features"]["lifecycle_effects_enabled"])
        self.assertEqual(work["deltas"]["ungrouped_native_canvas_draws"], 0)
        self.assertGreater(work["deltas"]["grouped_native_canvas_draws"], 0)
        self.assertEqual(work["deltas"]["direct_tool_plot_builds"], 0)
        self.assertGreater(work["deltas"]["legacy_tool_plot_builds"], 0)
        for invalid in (None, True, -1, before["suppressed_arrival_effects"]):
            changed = copy.deepcopy(after)
            changed["suppressed_arrival_effects"] = invalid
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, changed, memory.NO_ARRIVAL_MODE)

    def test_baseline_and_whole_lifecycle_control_require_zero_suppression_if_instrumented(self):
        for mode in (memory.ORDERED_PUBLICATION_MODE, "runtime-no-lifecycle"):
            before, after = workload_snapshots(mode)
            self.assertTrue(runtime.validate_runtime_work(before, after, mode)["available"])
            for snapshot in (before, after):
                snapshot["graphics_diagnostics"]["arrival_effects_enabled"] = mode != "runtime-no-lifecycle"
                snapshot["suppressed_arrival_effects"] = 0
            self.assertTrue(runtime.validate_runtime_work(before, after, mode)["available"])
            after["suppressed_arrival_effects"] = 1
            with self.assertRaisesRegex(ValueError, "unexpectedly suppressed"):
                runtime.validate_runtime_work(before, after, mode)
            for snapshot in (before, after):
                del snapshot["graphics_diagnostics"]["arrival_effects_enabled"]
            with self.assertRaisesRegex(ValueError, "lacks feature metadata"):
                runtime.validate_runtime_work(before, after, mode)

    def test_phase_proof_brackets_arrival_and_preserves_measured_completion_activity(self):
        report = clock_work_report(memory.NO_ARRIVAL_MODE)
        proof = runtime.validate_canvas_clock_work(report, memory.NO_ARRIVAL_MODE)["arrival_effects"]
        self.assertEqual(proof["arrival"]["deltas"]["rail_frame_clock_ticks"], 0)
        self.assertEqual(proof["arrival"]["deltas"]["rail_decorations_draws"], 0)
        self.assertGreater(proof["arrival"]["deltas"]["suppressed_arrival_effects"], 0)
        self.assertLessEqual(proof["arrival"]["start_monotonic_seconds"], report["phase_windows"]["arrival"]["start_monotonic_seconds"])
        self.assertGreaterEqual(proof["arrival"]["end_monotonic_seconds"], report["phase_windows"]["arrival"]["end_monotonic_seconds"])
        self.assertGreater(proof["completion"]["deltas"]["rail_frame_clock_ticks"], 0)
        self.assertGreater(proof["completion"]["deltas"]["rail_decorations_draws"], 0)

    def test_global_activity_cannot_substitute_for_zero_arrival_and_positive_completion_proof(self):
        for mutation in ("arrival-clock", "arrival-draw", "suppression", "completion-clock", "completion-draw",
                         "arrival-boundary", "completion-boundary"):
            report = clock_work_report(memory.NO_ARRIVAL_MODE)
            points = report["runtime"]["checkpoints"]
            by_label = {point["label"]: point for point in points}
            if mutation == "arrival-clock":
                for point in points[1:] + report["checkpoints"]:
                    point["snapshot"]["rail_frame_clock_ticks"] += 1
            elif mutation == "arrival-draw":
                by_label["after-arrival"]["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] += 1
            elif mutation == "suppression":
                by_label["after-arrival"]["snapshot"]["suppressed_arrival_effects"] = points[0]["snapshot"]["suppressed_arrival_effects"]
            elif mutation == "completion-clock":
                by_label["completion-begin"]["snapshot"]["rail_frame_clock_ticks"] = by_label["during-completion"]["snapshot"]["rail_frame_clock_ticks"]
            elif mutation == "completion-draw":
                by_label["during-completion"]["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = 0
            elif mutation == "arrival-boundary":
                points.remove(by_label["after-arrival"])
            else:
                points.remove(by_label["during-completion"])
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, memory.NO_ARRIVAL_MODE)


class NativeCanvasGroupingWorkTests(unittest.TestCase):
    def test_ungrouped_callbacks_cover_role_draws_and_keep_existing_paths(self):
        mode = memory.UNGROUPED_CANVAS_MODE
        before, after = workload_snapshots(mode)
        work = runtime.validate_runtime_work(before, after, mode)
        self.assertEqual(work["deltas"]["ungrouped_native_canvas_draws"], 3)
        self.assertEqual(work["deltas"]["grouped_native_canvas_draws"], 0)
        self.assertFalse(work["features"]["direct_tool_plot"])
        self.assertEqual(work["deltas"]["direct_tool_plot_builds"], 0)
        self.assertGreater(work["deltas"]["legacy_tool_plot_builds"], 0)
        self.assertTrue(work["features"]["ordered_chart_publication"] and work["features"]["canvas_frame_clock"])

    def test_mixed_callbacks_counter_only_proof_and_missing_fields_are_rejected(self):
        mode = memory.UNGROUPED_CANVAS_MODE
        for field in memory.NATIVE_CANVAS_GROUP_COUNTERS:
            for invalid in (None, True, -1):
                before, after = workload_snapshots(mode)
                after[field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(ValueError):
                    runtime.validate_runtime_work(before, after, mode)
        for mutation in ("mixed", "native-total", "role-total", "metadata"):
            before, after = workload_snapshots(mode)
            if mutation == "mixed":
                after["ungrouped_native_canvas_draws"] -= 1
                after["grouped_native_canvas_draws"] += 1
            elif mutation == "native-total":
                after["ungrouped_native_canvas_draws"] += 1
            elif mutation == "role-total":
                after["ungrouped_native_canvas_draws"] += 1
                after["graphics_diagnostics"]["native_gpu_canvas_draws"] += 1
            else:
                del after["graphics_diagnostics"]["ungrouped_native_canvas"]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, after, mode)

    def test_grouped_normal_requires_real_callbacks_and_rejects_partial_new_evidence(self):
        before, after = workload_snapshots(memory.ORDERED_PUBLICATION_MODE)
        for snapshot in (before, after):
            value = snapshot["graphics_diagnostics"]
            value.update(mode="normal", ungrouped_native_canvas=False)
            count = sum(role["draws"] for role in value["roles"].values())
            value["native_gpu_canvas_draws"] = count
            snapshot.update(ungrouped_native_canvas_draws=0, grouped_native_canvas_draws=count)
        self.assertEqual(runtime.validate_runtime_work(before, after, "normal")["deltas"]["grouped_native_canvas_draws"], 3)
        changed = copy.deepcopy(after)
        changed["ungrouped_native_canvas_draws"] += 1
        changed["grouped_native_canvas_draws"] -= 1
        with self.assertRaisesRegex(ValueError, "Grouped native Canvas mode"):
            runtime.validate_runtime_work(before, changed, "normal")
        for snapshot in (before, after):
            del snapshot["graphics_diagnostics"]["ungrouped_native_canvas"]
        with self.assertRaisesRegex(ValueError, "lack feature metadata"):
            runtime.validate_runtime_work(before, after, "normal")
        for snapshot in (before, after):
            for field in memory.NATIVE_CANVAS_GROUP_COUNTERS:
                del snapshot[field]
        self.assertTrue(runtime.validate_runtime_work(before, after, "normal")["available"])


class DeferredToolGeometryCadenceWorkTests(unittest.TestCase):
    def test_two_hz_reports_real_preparations_queries_and_draws_without_one_hz_count_gate(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_2HZ_MODE
        before, after = workload_snapshots(mode)
        for field in ("chart_preparations", "optimized_chart_preparations", "ordered_chart_publication_queries"):
            after[field] += 2
        after["graphics_diagnostics"]["roles"]["static_chart"]["draws"] += 2
        after["graphics_diagnostics"]["native_gpu_canvas_draws"] += 2
        after["grouped_native_canvas_draws"] += 2
        result = runtime.validate_runtime_work(before, after, mode)
        self.assertEqual(result["chart_publication_interval_seconds"], .5)
        self.assertNotIn("chart_publication_interval_seconds", result["features"])
        for field in ("chart_preparations", "optimized_chart_preparations", "ordered_chart_publication_queries", "static_chart_draws"):
            self.assertEqual(result["deltas"][field], 4)
        self.assertEqual(result["deltas"]["tool_path_input_points"], result["deltas"]["tool_path_output_points"])

    def test_two_hz_rejects_missing_or_wrong_interval_at_either_boundary(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_2HZ_MODE
        for boundary in (0, 1):
            for invalid in (None, True, 1.0, float("nan"), float("inf")):
                snapshots = workload_snapshots(mode)
                value = snapshots[boundary]["graphics_diagnostics"]
                if invalid is None:
                    del value["chart_publication_interval_seconds"]
                else:
                    value["chart_publication_interval_seconds"] = invalid
                with self.subTest(boundary=boundary, invalid=invalid), self.assertRaisesRegex(ValueError, "publication_interval"):
                    runtime.validate_runtime_work(*snapshots, mode)

    def test_legacy_pair_may_omit_cadence_but_mixed_presence_is_invalid(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_MODE
        before, after = workload_snapshots(mode)
        self.assertNotIn("chart_publication_interval_seconds", runtime.validate_runtime_work(before, after, mode))
        after["graphics_diagnostics"]["chart_publication_interval_seconds"] = 1.0
        with self.assertRaisesRegex(ValueError, "interval metadata changed"):
            runtime.validate_runtime_work(before, after, mode)
        before["graphics_diagnostics"]["chart_publication_interval_seconds"] = 1.0
        self.assertEqual(runtime.validate_runtime_work(before, after, mode)["chart_publication_interval_seconds"], 1.0)

    def test_four_case_cli_is_bracketed_without_changing_global_deadline(self):
        controls = list(memory.DEFERRED_TOOL_GEOMETRY_MODES)
        arguments = ["compare", "--app-binary", "/app", "--test-bundle", "/tests", "--collector-binary", "/collector",
                     "--provenance", "/provenance", "--baseline-mode", "normal", "--controls", *controls]
        self.assertEqual(runtime.selected_cases(runtime.parser().parse_args(arguments)), [
            ("baseline-before", "normal"), *[(mode, mode) for mode in controls], ("baseline-after", "normal")])
        self.assertEqual(runtime.MAX_SECONDS, 300)


class DeferredToolGeometryWorkTests(unittest.TestCase):
    def test_candidate_uses_actual_positive_uncompacted_construction_and_preserves_cadence(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_MODE
        before, after = workload_snapshots(mode)
        candidate = runtime.validate_runtime_work(before, after, mode)
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"].update(mode="normal", deferred_tool_geometry_enabled=False)
        baseline = runtime.validate_runtime_work(before, after, "normal")
        self.assertEqual(candidate["features"], baseline["features"] | {"deferred_tool_geometry_enabled": True})
        self.assertEqual(candidate["deltas"], baseline["deltas"])
        self.assertEqual(candidate["deltas"]["tool_path_input_points"], 100)
        self.assertEqual(candidate["deltas"]["tool_path_output_points"], 100)
        self.assertEqual(candidate["deltas"]["legacy_tool_plot_builds"], 2)
        self.assertEqual(candidate["deltas"]["static_chart_draws"], 2)

    def test_zero_construction_missing_flag_and_compaction_cannot_claim_deferred_work(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_MODE
        for fault in ("zero-points", "zero-builds", "missing-flag", "compaction", "partial-pair"):
            before, after = workload_snapshots(mode)
            if fault == "zero-points":
                after.update({field: before[field] for field in memory.TOOL_PATH_POINT_COUNTERS})
            elif fault == "zero-builds":
                after["legacy_tool_plot_builds"] = before["legacy_tool_plot_builds"]
            elif fault == "missing-flag":
                del after["graphics_diagnostics"]["deferred_tool_geometry_enabled"]
            elif fault == "compaction":
                after["tool_path_output_points"] -= 1
            else:
                del after["tool_path_output_points"]
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, after, mode)

    def test_deferred_comparison_brackets_normal_and_old_normal_may_omit_only_new_flag(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_MODE
        arguments = ["compare", "--app-binary", "/app", "--test-bundle", "/tests", "--collector-binary", "/collector",
                     "--provenance", "/provenance", "--baseline-mode", "normal", "--controls", mode]
        self.assertEqual(runtime.selected_cases(runtime.parser().parse_args(arguments)), [
            ("baseline-before", "normal"), (mode, mode), ("baseline-after", "normal")])
        before, after = workload_snapshots(mode)
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"]["mode"] = "normal"
            del snapshot["graphics_diagnostics"]["deferred_tool_geometry_enabled"]
        self.assertTrue(runtime.validate_runtime_work(before, after, "normal")["available"])


class CompactToolPathWorkTests(unittest.TestCase):
    def baseline(self):
        before, after = workload_snapshots(memory.COMPACT_TOOL_PATHS_MODE)
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"].update(mode="normal", compact_tool_paths_enabled=False)
            snapshot["tool_path_output_points"] = snapshot["tool_path_input_points"]
        return before, after

    def test_control_requires_runtime_reduction_and_normal_requires_equal_construction(self):
        candidate = runtime.validate_runtime_work(*workload_snapshots(memory.COMPACT_TOOL_PATHS_MODE), memory.COMPACT_TOOL_PATHS_MODE)
        baseline = runtime.validate_runtime_work(*self.baseline(), "normal")
        self.assertEqual((candidate["deltas"]["tool_path_input_points"], candidate["deltas"]["tool_path_output_points"]), (100, 30))
        self.assertEqual((baseline["deltas"]["tool_path_input_points"], baseline["deltas"]["tool_path_output_points"]), (100, 100))
        self.assertEqual(candidate["features"], baseline["features"] | {"compact_tool_paths_enabled": True})
        arguments = ["compare", "--app-binary", "/app", "--test-bundle", "/tests", "--collector-binary", "/collector",
                     "--provenance", "/provenance", "--baseline-mode", "normal", "--controls", memory.COMPACT_TOOL_PATHS_MODE]
        self.assertEqual(runtime.selected_cases(runtime.parser().parse_args(arguments)), [
            ("baseline-before", "normal"), (memory.COMPACT_TOOL_PATHS_MODE, memory.COMPACT_TOOL_PATHS_MODE), ("baseline-after", "normal")])

    def test_prior_reduction_cannot_substitute_for_current_work_and_counters_cannot_regress(self):
        mode = memory.COMPACT_TOOL_PATHS_MODE
        for input_delta, output_delta in ((0, 0), (100, 0), (100, 100), (100, 101), (-1, 1), (100, -1)):
            before, after = workload_snapshots(mode)
            after["tool_path_input_points"] = before["tool_path_input_points"] + input_delta
            after["tool_path_output_points"] = before["tool_path_output_points"] + output_delta
            with self.subTest(input_delta=input_delta, output_delta=output_delta), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, after, mode)
        for field in memory.TOOL_PATH_POINT_COUNTERS:
            before, after = workload_snapshots(mode)
            del after[field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, after, mode)

    def test_baseline_rejects_vertex_change_zero_work_or_partial_acknowledgment(self):
        for fault in ("reduction", "zero", "flag", "pair"):
            before, after = self.baseline()
            if fault == "reduction":
                after["tool_path_output_points"] -= 1
            elif fault == "zero":
                after.update({field: before[field] for field in memory.TOOL_PATH_POINT_COUNTERS})
            elif fault == "flag":
                for snapshot in (before, after):
                    del snapshot["graphics_diagnostics"]["compact_tool_paths_enabled"]
            else:
                del after["tool_path_output_points"]
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, after, "normal")
        before, after = self.baseline()
        for snapshot in (before, after):
            del snapshot["graphics_diagnostics"]["compact_tool_paths_enabled"]
            for field in memory.TOOL_PATH_POINT_COUNTERS:
                del snapshot[field]
        self.assertTrue(runtime.validate_runtime_work(before, after, "normal")["available"])


class DirectToolPlotWorkTests(unittest.TestCase):
    def test_fixed_workload_requires_positive_direct_and_no_legacy_build_delta(self):
        mode = memory.DIRECT_TOOL_PLOT_MODE
        before, after = workload_snapshots(mode)
        work = runtime.validate_runtime_work(before, after, mode)
        self.assertEqual(work["deltas"]["direct_tool_plot_builds"], 2)
        self.assertEqual(work["deltas"]["legacy_tool_plot_builds"], 0)
        self.assertTrue(all(work["features"][field] for field in ("direct_tool_plot", "ordered_chart_publication",
                                                                "canvas_frame_clock", "unpromised_stream_body_writes")))
        for direct, legacy in ((0, 0), (2, 1)):
            changed = copy.deepcopy(after)
            changed["direct_tool_plot_builds"] = before["direct_tool_plot_builds"] + direct
            changed["legacy_tool_plot_builds"] = before["legacy_tool_plot_builds"] + legacy
            with self.subTest(direct=direct, legacy=legacy), self.assertRaisesRegex(ValueError, "without legacy fallback"):
                runtime.validate_runtime_work(before, changed, mode)
        before["legacy_tool_plot_builds"] = after["legacy_tool_plot_builds"] = 7
        self.assertTrue(runtime.validate_runtime_work(before, after, mode)["available"])

    def test_new_candidate_rejects_missing_or_invalid_group_and_changed_metadata(self):
        mode = memory.DIRECT_TOOL_PLOT_MODE
        for field in memory.DIRECT_TOOL_PLOT_COUNTERS:
            for invalid in (None, True, -1):
                before, after = workload_snapshots(mode)
                after[field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(ValueError):
                    runtime.validate_runtime_work(before, after, mode)
        before, after = workload_snapshots(mode)
        del after["graphics_diagnostics"]["direct_tool_plot"]
        with self.assertRaises(ValueError):
            runtime.validate_runtime_work(before, after, mode)

    def test_instrumented_normal_uses_legacy_builder_and_preserves_frozen_compatibility(self):
        before, after = workload_snapshots(memory.ORDERED_PUBLICATION_MODE)
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"]["mode"] = "normal"
        self.assertTrue(runtime.validate_runtime_work(before, after, "normal")["available"])
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"]["direct_tool_plot"] = False
            snapshot.update(direct_tool_plot_builds=0, legacy_tool_plot_builds=0)
        with self.assertRaisesRegex(ValueError, "did not execute legacy"):
            runtime.validate_runtime_work(before, after, "normal")
        after["legacy_tool_plot_builds"] = 2
        self.assertTrue(runtime.validate_runtime_work(before, after, "normal")["available"])
        after["direct_tool_plot_builds"] = 1
        with self.assertRaisesRegex(ValueError, "Legacy tool-plot"):
            runtime.validate_runtime_work(before, after, "normal")
        after["direct_tool_plot_builds"] = 0
        del after["graphics_diagnostics"]["direct_tool_plot"]
        with self.assertRaisesRegex(ValueError, "stable complete"):
            runtime.validate_runtime_work(before, after, "normal")
        del before["graphics_diagnostics"]["direct_tool_plot"]
        with self.assertRaisesRegex(ValueError, "lack feature metadata"):
            runtime.validate_runtime_work(before, after, "normal")

    def test_ordered_baseline_and_direct_control_keep_bounded_three_case_sequence(self):
        args = runtime.parser().parse_args(["compare", "--app-binary", "/app", "--test-bundle", "/tests",
            "--collector-binary", "/collector", "--provenance", "/provenance", "--baseline-mode",
            memory.ORDERED_PUBLICATION_MODE, "--controls", memory.DIRECT_TOOL_PLOT_MODE])
        self.assertEqual(runtime.selected_cases(args), [("baseline-before", memory.ORDERED_PUBLICATION_MODE),
            (memory.DIRECT_TOOL_PLOT_MODE, memory.DIRECT_TOOL_PLOT_MODE), ("baseline-after", memory.ORDERED_PUBLICATION_MODE)])


class SharedToolTraceWorkTests(unittest.TestCase):
    def snapshots(self, mode=memory.METAL_ARRIVAL_MODE, unique=1, reused=1):
        before, after = workload_snapshots(mode)
        before.update(unique_tool_trace_builds=20, reused_tool_trace_builds=30)
        after.update(unique_tool_trace_builds=20 + unique, reused_tool_trace_builds=30 + reused)
        return before, after

    def test_unique_and_reused_deltas_reconcile_for_direct_and_legacy_builders(self):
        for mode in (memory.DIRECT_TOOL_PLOT_MODE, memory.METAL_ARRIVAL_MODE):
            for unique, reused in ((2, 0), (1, 1), (0, 2)):
                with self.subTest(mode=mode, unique=unique, reused=reused):
                    result = runtime.validate_runtime_work(*self.snapshots(mode, unique, reused), mode)
                    self.assertEqual(result["deltas"]["unique_tool_trace_builds"], unique)
                    self.assertEqual(result["deltas"]["reused_tool_trace_builds"], reused)
                    self.assertEqual(result["deltas"]["direct_tool_plot_builds"]
                                     + result["deltas"]["legacy_tool_plot_builds"], unique + reused)

    def test_frozen_snapshots_without_both_optional_counters_remain_supported(self):
        mode = memory.METAL_ARRIVAL_MODE
        result = runtime.validate_runtime_work(*workload_snapshots(mode), mode)
        self.assertTrue(result["available"])
        self.assertNotIn("unique_tool_trace_builds", result["deltas"])
        self.assertNotIn("reused_tool_trace_builds", result["deltas"])

    def test_partial_counter_groups_in_either_snapshot_are_rejected(self):
        for index in (0, 1):
            for fields in (("unique_tool_trace_builds",), ("reused_tool_trace_builds",), runtime.TOOL_TRACE_COUNTERS):
                snapshots = self.snapshots()
                for field in fields:
                    del snapshots[index][field]
                with self.subTest(snapshot=index, missing=fields), self.assertRaises(ValueError):
                    runtime.validate_runtime_work(*snapshots, memory.METAL_ARRIVAL_MODE)

    def test_counter_values_require_uint64_without_coercion(self):
        for index in (0, 1):
            for field in runtime.TOOL_TRACE_COUNTERS:
                for invalid in (None, True, False, -1, 1.0, "1", 2**64):
                    snapshots = self.snapshots()
                    snapshots[index][field] = invalid
                    with self.subTest(snapshot=index, field=field, value=invalid), self.assertRaises(ValueError):
                        runtime.validate_runtime_work(*snapshots, memory.METAL_ARRIVAL_MODE)

    def test_regressions_or_totals_differing_from_tool_plot_work_are_rejected(self):
        for field in runtime.TOOL_TRACE_COUNTERS:
            before, after = self.snapshots()
            after[field] = before[field] - 1
            with self.subTest(regressed=field), self.assertRaisesRegex(ValueError, "moved backwards"):
                runtime.validate_runtime_work(before, after, memory.METAL_ARRIVAL_MODE)
        for unique, reused in ((0, 0), (1, 0), (2, 1)):
            with self.subTest(unique=unique, reused=reused), self.assertRaisesRegex(ValueError, "do not reconcile"):
                runtime.validate_runtime_work(*self.snapshots(unique=unique, reused=reused), memory.METAL_ARRIVAL_MODE)

    def test_large_counter_values_preserve_exact_small_deltas(self):
        before, after = self.snapshots()
        for field in runtime.TOOL_TRACE_COUNTERS:
            before[field], after[field] = 2**64 - 2, 2**64 - 1
        result = runtime.validate_runtime_work(before, after, memory.METAL_ARRIVAL_MODE)
        self.assertEqual([result["deltas"][field] for field in runtime.TOOL_TRACE_COUNTERS], [1, 1])

    def test_new_trace_evidence_cannot_bypass_validation_as_an_unsupported_frozen_baseline(self):
        before = drawn_native_gpu_graphics("native-gpu-optimized")
        after = copy.deepcopy(before)
        self.assertFalse(runtime.validate_runtime_work(before, after, "normal", required=False)["available"])
        after["unique_tool_trace_builds"] = 1
        with self.assertRaises(ValueError):
            runtime.validate_runtime_work(before, after, "normal", required=False)


class NextRuntimeWorkTests(unittest.TestCase):
    def test_promoted_normal_proves_ordered_queries_and_no_workload_full_sorts(self):
        before, after = workload_snapshots(memory.ORDERED_PUBLICATION_MODE)
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"]["mode"] = "normal"
        work = runtime.validate_runtime_work(before, after, "normal")
        self.assertTrue(work["features"]["ordered_chart_publication"])
        self.assertEqual(work["deltas"]["ordered_chart_publication_queries"], 2)
        self.assertEqual(work["deltas"]["chart_publication_full_sorts"], 0)
        for field, amount in (("ordered_chart_publication_queries", 0), ("chart_publication_full_sorts", 1)):
            changed = copy.deepcopy(after)
            changed[field] = before[field] + amount
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "without fallback"):
                runtime.validate_runtime_work(before, changed, "normal")
        changed = copy.deepcopy(after)
        changed["graphics_diagnostics"]["ordered_chart_publication"] = False
        with self.assertRaisesRegex(ValueError, "stable complete"):
            runtime.validate_runtime_work(before, changed, "normal")

    def test_ordered_publication_executes_queries_without_workload_fallback_sorts(self):
        mode = memory.ORDERED_PUBLICATION_MODE
        before, after = workload_snapshots(mode)
        self.assertEqual(runtime.validate_runtime_work(before, after, mode)["deltas"]["ordered_chart_publication_queries"], 2)
        for field in memory.ORDERED_PUBLICATION_COUNTERS:
            for invalid in (None, True, -1):
                changed = copy.deepcopy(after)
                changed[field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(ValueError):
                    runtime.validate_runtime_work(before, changed, mode)
        for queries, sorts in ((0, 0), (2, 1)):
            changed = copy.deepcopy(after)
            changed["ordered_chart_publication_queries"] = before["ordered_chart_publication_queries"] + queries
            changed["chart_publication_full_sorts"] = before["chart_publication_full_sorts"] + sorts
            with self.subTest(queries=queries, sorts=sorts), self.assertRaisesRegex(ValueError, "without fallback"):
                runtime.validate_runtime_work(before, changed, mode)
        # Earlier fallback work is outside the measured workload, not a reason
        # to reject the fixed-window proof or require globally impossible zeros.
        before["chart_publication_full_sorts"] = after["chart_publication_full_sorts"] = 12
        self.assertTrue(runtime.validate_runtime_work(before, after, mode)["available"])

    def test_instrumented_baseline_requires_full_sorts_and_no_ordered_queries(self):
        before, after = workload_snapshots("runtime-optimized")
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"]["ordered_chart_publication"] = False
            snapshot.update(ordered_chart_publication_queries=0, chart_publication_full_sorts=0)
        with self.assertRaisesRegex(ValueError, "did not execute fallback"):
            runtime.validate_runtime_work(before, after, "runtime-optimized")
        after["chart_publication_full_sorts"] = 2
        self.assertTrue(runtime.validate_runtime_work(before, after, "runtime-optimized")["available"])
        after["ordered_chart_publication_queries"] = 1
        with self.assertRaisesRegex(ValueError, "Nonordered"):
            runtime.validate_runtime_work(before, after, "runtime-optimized")

    def test_legacy_shared_ordered_fields_optional_but_new_evidence_is_complete_and_stable(self):
        for mode in ("runtime-shared-preparation", "runtime-next-optimized"):
            before, after = workload_snapshots(mode)
            self.assertTrue(runtime.validate_runtime_work(before, after, mode)["available"])
            for snapshot in (before, after):
                snapshot["graphics_diagnostics"]["ordered_chart_publication"] = True
                snapshot.update(ordered_chart_publication_queries=0, chart_publication_full_sorts=0)
            after["ordered_chart_publication_queries"] = 2
            self.assertTrue(runtime.validate_runtime_work(before, after, mode)["available"])
            del after["graphics_diagnostics"]["ordered_chart_publication"]
            with self.assertRaisesRegex(ValueError, "stable complete"):
                runtime.validate_runtime_work(before, after, mode)
            del before["graphics_diagnostics"]["ordered_chart_publication"]
            with self.assertRaisesRegex(ValueError, "lack feature metadata"):
                runtime.validate_runtime_work(before, after, mode)

    def test_promoted_normal_requires_executed_stream_clock_and_rendered_work(self):
        before, after = workload_snapshots("runtime-stream-canvas-clock")
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"]["mode"] = "normal"
        result = runtime.validate_runtime_work(before, after, "normal")
        self.assertTrue(result["features"]["unpromised_stream_body_writes"])
        self.assertTrue(result["features"]["canvas_frame_clock"])
        for field in ("streamed_bodies_without_promises", "rail_frame_clock_ticks"):
            changed = copy.deepcopy(after)
            changed[field] = before[field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, changed, "normal")
        changed = copy.deepcopy(after)
        changed["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = before["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"]
        with self.assertRaisesRegex(ValueError, "sufficient native decoration draws"):
            runtime.validate_runtime_work(before, changed, "normal")
        changed = copy.deepcopy(after)
        changed["graphics_diagnostics"].update(unpromised_stream_body_writes=False, canvas_frame_clock=False)
        with self.assertRaisesRegex(ValueError, "stable complete"):
            runtime.validate_runtime_work(before, changed, "normal")

    def test_canvas_clock_controls_select_isolated_paths(self):
        for mode in memory.CANVAS_CLOCK_MODES:
            work = runtime.validate_runtime_work(*workload_snapshots(mode), mode)
            self.assertTrue(work["features"]["canvas_frame_clock"])
            self.assertFalse(work["features"]["shared_chart_preparation"])
            self.assertFalse(work["features"]["stable_decoration_hosts"])
            self.assertEqual(work["features"]["unpromised_stream_body_writes"], mode != "runtime-canvas-clock")
            args = runtime.parser().parse_args(["compare", "--app-binary", "/app", "--test-bundle", "/tests",
                "--collector-binary", "/collector", "--provenance", "/provenance", "--controls", mode])
            self.assertEqual(runtime.selected_cases(args)[1], (mode, mode))

    def test_canvas_clock_work_rejects_absence_fallback_and_unrendered_ticks(self):
        for mode in memory.CANVAS_CLOCK_MODES:
            for field in memory.CANVAS_CLOCK_COUNTERS:
                for invalid in (None, True, -1):
                    before, after = workload_snapshots(mode)
                    after[field] = invalid
                    with self.subTest(mode=mode, field=field, invalid=invalid), self.assertRaises(ValueError):
                        runtime.validate_runtime_work(before, after, mode)
            for ticks, timeline, draws in ((0, 0, 1), (20, 0, 0), (20, 0, 13), (20, 1, 20)):
                before, after = workload_snapshots(mode)
                after["rail_frame_clock_ticks"] = before["rail_frame_clock_ticks"] + ticks
                after["rail_timeline_content_updates"] = timeline
                after["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = before["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] + draws
                with self.subTest(mode=mode, ticks=ticks, timeline=timeline, draws=draws), self.assertRaises(ValueError):
                    runtime.validate_runtime_work(before, after, mode)
            before, after = workload_snapshots(mode)
            after["rail_frame_clock_ticks"] = before["rail_frame_clock_ticks"] + 20
            after["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] += 13
            if "ungrouped_native_canvas" in after["graphics_diagnostics"]:
                total = sum(role["draws"] for role in after["graphics_diagnostics"]["roles"].values())
                field = "ungrouped_native_canvas_draws" if after["graphics_diagnostics"]["ungrouped_native_canvas"] else "grouped_native_canvas_draws"
                after["graphics_diagnostics"]["native_gpu_canvas_draws"] = after[field] = total
            self.assertTrue(runtime.validate_runtime_work(before, after, mode)["available"])

    def test_legacy_clock_counters_optional_but_contract_cannot_disappear(self):
        before, after = workload_snapshots("runtime-optimized")
        self.assertTrue(runtime.validate_runtime_work(before, after, "runtime-optimized")["available"])
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"]["canvas_frame_clock"] = False
            snapshot.update(rail_frame_clock_ticks=0, rail_timeline_content_updates=5)
        self.assertTrue(runtime.validate_runtime_work(before, after, "runtime-optimized")["available"])
        after["rail_frame_clock_ticks"] = 1
        with self.assertRaisesRegex(ValueError, "Nonclock"):
            runtime.validate_runtime_work(before, after, "runtime-optimized")
        after["rail_frame_clock_ticks"] = 0
        del after["graphics_diagnostics"]["canvas_frame_clock"]
        with self.assertRaisesRegex(ValueError, "stable complete"):
            runtime.validate_runtime_work(before, after, "runtime-optimized")

    def test_old_optimized_mode_can_be_the_preserved_baseline(self):
        args = runtime.parser().parse_args(["compare", "--app-binary", "/app", "--test-bundle", "/tests",
            "--collector-binary", "/collector", "--provenance", "/provenance", "--baseline-mode", "runtime-optimized",
            "--controls", "runtime-shared-preparation", "runtime-stable-decoration-hosts", "runtime-next-optimized"])
        cases = runtime.selected_cases(args)
        self.assertEqual(len(cases), 5)
        self.assertEqual(cases[0][1], "runtime-optimized")

    def test_shared_work_requires_complete_positive_bounded_execution(self):
        for build_delta, preparation_delta in ((0, 2), (3, 2), (1, 1), (1, 3)):
            before, after = workload_snapshots("runtime-shared-preparation")
            after["shared_chart_normalization_builds"] = before["shared_chart_normalization_builds"] + build_delta
            after["shared_chart_preparations"] = before["shared_chart_preparations"] + preparation_delta
            with self.subTest(builds=build_delta, preparations=preparation_delta), self.assertRaisesRegex(ValueError, "Shared normalization"):
                runtime.validate_runtime_work(before, after, "runtime-shared-preparation")

    def test_new_modes_require_shared_counter_schema_and_old_modes_may_omit(self):
        for mode in memory.NEXT_RUNTIME_MODES:
            for field in memory.NEXT_RUNTIME_COUNTERS:
                for invalid in (None, True, -1):
                    before, after = workload_snapshots(mode)
                    after[field] = invalid
                    with self.subTest(mode=mode, field=field, invalid=invalid), self.assertRaises(ValueError):
                        runtime.validate_runtime_work(before, after, mode)
        before, after = workload_snapshots("runtime-optimized")
        self.assertTrue(runtime.validate_runtime_work(before, after, "runtime-optimized")["available"])
        for snapshot in (before, after):
            snapshot["graphics_diagnostics"].update(shared_chart_preparation=False, stable_decoration_hosts=False, unpromised_stream_body_writes=False)
        with self.assertRaises(ValueError):
            runtime.validate_runtime_work(before, after, "runtime-optimized")
        for snapshot in (before, after):
            snapshot.update(dict.fromkeys(memory.NEXT_RUNTIME_COUNTERS, 0))
        self.assertTrue(runtime.validate_runtime_work(before, after, "runtime-optimized")["available"])
        before["shared_chart_preparations"] = after["shared_chart_preparations"] = 1
        with self.assertRaisesRegex(ValueError, "Nonshared"):
            runtime.validate_runtime_work(before, after, "runtime-optimized")

    def test_stable_host_requires_creation_but_inactive_zero_frame_is_valid(self):
        before, after = workload_snapshots("runtime-stable-decoration-hosts")
        role = after["graphics_diagnostics"]["roles"]["rail_decorations"]
        role["draws"] = before["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"]
        self.assertEqual(role["current_pixel_area"], 0)
        self.assertTrue(runtime.validate_runtime_work(before, after, "runtime-stable-decoration-hosts")["available"])
        role["created"] = 0
        with self.assertRaisesRegex(ValueError, "did not create"):
            runtime.validate_runtime_work(before, after, "runtime-stable-decoration-hosts")

    def test_stream_write_candidate_requires_execution_without_assuming_http_fragment_count(self):
        before, after = workload_snapshots("runtime-stream-writes")
        for amount in (1, 10001):
            after["streamed_bodies_without_promises"] = before["streamed_bodies_without_promises"] + amount
            self.assertEqual(runtime.validate_runtime_work(before, after, "runtime-stream-writes")["deltas"]["streamed_bodies_without_promises"], amount)
        after["streamed_bodies_without_promises"] = before["streamed_bodies_without_promises"]
        with self.assertRaisesRegex(ValueError, "did not execute"):
            runtime.validate_runtime_work(before, after, "runtime-stream-writes")
        before, after = workload_snapshots("runtime-shared-preparation")
        before["streamed_bodies_without_promises"] = after["streamed_bodies_without_promises"] = 1
        with self.assertRaisesRegex(ValueError, "Promised-write"):
            runtime.validate_runtime_work(before, after, "runtime-shared-preparation")

    def test_extra_metadata_cannot_change_or_disappear(self):
        before, after = workload_snapshots("runtime-next-optimized")
        del after["graphics_diagnostics"]["stable_decoration_hosts"]
        with self.assertRaises(ValueError):
            runtime.validate_runtime_work(before, after, "runtime-next-optimized")


class CanvasClockPhaseTests(unittest.TestCase):
    def test_promoted_normal_requires_zero_steady_and_closed_ticks(self):
        report = clock_work_report(memory.ORDERED_PUBLICATION_MODE)
        for point in report["runtime"]["checkpoints"] + report["checkpoints"]:
            point["snapshot"]["graphics_diagnostics"]["mode"] = "normal"
        proof = runtime.validate_canvas_clock_work(report, "normal")
        self.assertEqual(proof["steady"]["deltas"]["rail_frame_clock_ticks"], 0)
        self.assertEqual(proof["closed"]["rail_frame_clock_ticks_delta"], 0)
        for phase, index in (("runtime", 2), ("closed", 1)):
            changed = copy.deepcopy(report)
            points = changed["runtime"]["checkpoints"] if phase == "runtime" else changed["checkpoints"]
            points[index]["snapshot"]["rail_frame_clock_ticks"] += 1
            with self.subTest(phase=phase), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(changed, "normal")

    def test_steady_and_closed_proof_uses_authenticated_interior_checkpoints(self):
        for mode in memory.CANVAS_CLOCK_MODES:
            report = clock_work_report(mode)
            proof = runtime.validate_canvas_clock_work(report, mode)
            self.assertEqual(proof["steady"]["start_monotonic_seconds"], 106)
            self.assertEqual(proof["steady"]["end_monotonic_seconds"], 119)
            self.assertEqual(proof["steady"]["deltas"]["rail_frame_clock_ticks"], 0)
            self.assertEqual(proof["closed"]["rail_frame_clock_ticks_delta"], 0)
            # A late completion tick before closing is allowed; neither the
            # three-second tail nor a pending final effect is assumed idle.
            report["runtime"]["checkpoints"][-1]["snapshot"]["rail_frame_clock_ticks"] += 1
            for point in report["checkpoints"]:
                point["snapshot"]["rail_frame_clock_ticks"] += 1
            self.assertTrue(runtime.validate_canvas_clock_work(report, mode)["available"])

    def test_steady_ticks_closed_ticks_and_lost_activity_are_rejected(self):
        for target, field, value in (("steady", "rail_frame_clock_ticks", 5),
                                     ("steady", "active_requests", 1),
                                     ("closed", "rail_frame_clock_ticks", 6),
                                     ("closed", "dashboard_visible", True),
                                     ("steady", "rail_timeline_content_updates", 1)):
            report = clock_work_report()
            point = report["runtime"]["checkpoints"][2] if target == "steady" else report["checkpoints"][1]
            point["snapshot"][field] = value
            with self.subTest(target=target, field=field), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, "runtime-canvas-clock")

    def test_phase_and_closed_evidence_cannot_be_missing_or_unauthenticated(self):
        for mutation in (lambda report: report["runtime"]["checkpoints"].pop(2),
                         lambda report: report["checkpoints"].pop(),
                         lambda report: report["checkpoints"][1]["snapshot"].update(runner_collector_sample_monotonic_seconds=-1),
                         lambda report: report["runtime"]["checkpoints"][1]["snapshot"].pop("rail_frame_clock_ticks")):
            report = clock_work_report()
            mutation(report)
            with self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, "runtime-canvas-clock")

    def test_legacy_frozen_capture_does_not_require_clock_phase_evidence(self):
        before, after = workload_snapshots("runtime-optimized")
        report = {"runtime": {"checkpoints": [{"snapshot": before}, {"snapshot": after}]}}
        self.assertFalse(runtime.validate_canvas_clock_work(report, "runtime-optimized")["available"])


class ProfileReadinessGuardTests(unittest.TestCase):
    def test_profile_guard_pumps_half_second_and_validates_visible_idle_windows(self):
        now = [10.0]
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = runtime.RuntimeDiagnostic(Path(directory), runtime.RuntimeDeadline(120), "normal", profile=True)
            diagnostic.collector = Mock()
            diagnostic.collector.snapshot.return_value = {"dashboard_visible": True, "popover_visible": True, "active_requests": 0}
            diagnostic.collector.wait_until.side_effect = lambda end: now.__setitem__(0, end)
            with patch.object(runtime.time, "monotonic", side_effect=lambda: now[0]), \
                    patch.object(diagnostic, "verify_identity") as identity, \
                    patch.object(diagnostic, "validate_control_snapshot") as validate, patch.object(diagnostic, "save"):
                diagnostic.profile_readiness_guard()
            diagnostic.collector.wait_until.assert_called_once_with(10.5)
            self.assertEqual(identity.call_count, 4)
            self.assertEqual(validate.call_count, 2)
            self.assertEqual(diagnostic.runtime["pre_workload_profile_guard"]["end_monotonic_seconds"], 10.5)
            self.assertEqual(diagnostic.runtime["checkpoints"], [])

    def test_hidden_guard_window_fails_before_traffic(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = runtime.RuntimeDiagnostic(Path(directory), runtime.RuntimeDeadline(120), "normal", profile=True)
            diagnostic.collector = Mock()
            diagnostic.collector.snapshot.return_value = {"dashboard_visible": False, "popover_visible": True, "active_requests": 0}
            with patch.object(diagnostic, "verify_identity"), self.assertRaisesRegex(ValueError, "guard lost"):
                diagnostic.profile_readiness_guard()
            diagnostic.collector.wait_until.assert_not_called()

    def test_guard_is_profile_only_before_first_measured_checkpoint(self):
        for profile in (False, True):
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as directory:
                diagnostic = runtime.RuntimeDiagnostic(Path(directory), runtime.RuntimeDeadline(120), "normal", profile=profile)
                order = []
                with patch.object(runtime, "_mach_clock", return_value={}), \
                        patch.object(diagnostic, "begin_profile", side_effect=lambda: order.append("ready")), \
                        patch.object(diagnostic, "profile_readiness_guard", side_effect=lambda: order.append("guard")), \
                        patch.object(diagnostic, "runtime_checkpoint", side_effect=lambda label: order.append(label)):
                    diagnostic.begin_runtime()
                self.assertEqual(order, (["ready", "guard"] if profile else []) + ["before-traffic"])


class CompletionCounterIntervalTests(unittest.TestCase):
    def capture(self, directory, before, traffic_after, completion_after):
        window = {"start_monotonic_seconds": 100, "end_monotonic_seconds": 129}
        report = {"errors": [], "workload": {"validated": True, "validated_work": runtime.WORK,
            "specification": {}, "fixture_status": {}, "fixture_start": {},
            "before": before, "after": traffic_after},
            "runtime": {"checkpoints": [{"label": "before-traffic", "snapshot": before},
                {"label": "completion-end", "snapshot": completion_after}]}}
        diagnostic = Mock(report=report)
        with patch.object(runtime, "RuntimeDiagnostic", return_value=diagnostic), \
                patch.object(runtime.app, "validate_workload", return_value=runtime.WORK), \
                patch.object(runtime, "phase_windows", return_value={"whole_contiguous_runtime": window}), \
                patch.object(runtime, "validate_visual_work", return_value={"available": True}), \
                patch.object(runtime, "phase_cpu", return_value={"whole_contiguous_runtime": {"rolling_1s_percent": 4}}):
            return runtime.capture_case(Path(directory) / "case", "runtime-optimized", {}, {}, {}, runtime.RuntimeDeadline())

    def test_deferred_history_rebuild_and_preparation_fallback_are_rejected(self):
        for field in ("history_completed_order_builds", "history_tool_order_builds", "chart_preparations"):
            before, traffic_after = workload_snapshots("runtime-optimized")
            completion_after = copy.deepcopy(traffic_after)
            completion_after[field] += 1
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                report = self.capture(directory, before, traffic_after, completion_after)
                self.assertEqual(report["status"], "diagnostic_incomplete")
                self.assertTrue(report["errors"])

    def test_work_evidence_includes_tail_and_labels_the_shared_cpu_interval(self):
        before, traffic_after = workload_snapshots("runtime-optimized")
        completion_after = copy.deepcopy(traffic_after)
        completion_after["chart_preparations"] += 3
        completion_after["optimized_chart_preparations"] += 3
        completion_after["history_completed_order_insertions"] += 2
        with tempfile.TemporaryDirectory() as directory:
            report = self.capture(directory, before, traffic_after, completion_after)
        self.assertEqual(report["status"], "diagnostic_captured")
        work = report["runtime_work"]
        self.assertEqual(work["deltas"]["chart_preparations"], 5)
        self.assertEqual(work["deltas"]["history_completed_order_insertions"], 4)
        self.assertEqual(work["interval"], {"scope": "whole_contiguous_runtime", "start_checkpoint": "before-traffic",
            "end_checkpoint": "completion-end", "start_monotonic_seconds": 100, "end_monotonic_seconds": 129})


class OptionalRuntimeWorkCounterTests(unittest.TestCase):
    def report(self):
        from test_memory_diagnostic import WorkloadCPUAndInspectionTests
        points, events, workload, identity, _ = WorkloadCPUAndInspectionTests().evidence()
        for index, point in enumerate(points):
            point["cpu_work_counters"] = dict(runtime.app.CPU_WORK_METADATA,
                instructions=2**53 + index * 3, cycles=2**53 + index * 4,
                qos_time_raw={key: index * 2 if key == "default" else 0 for key in runtime.app.CPU_WORK_QOS_BUCKETS})
        workload["after"]["runner_collector_sample_monotonic_seconds"] = 2
        return {"samples": points, "events": events, "owned_identity": identity, "workload": workload,
                "runtime": {"checkpoints": [
                    {"label": "before-traffic", "snapshot": {"runner_collector_sample_monotonic_seconds": 1}},
                    {"label": "completion-end", "snapshot": {"runner_collector_sample_monotonic_seconds": 3}}]}}

    def test_counter_interval_uses_exact_completion_checkpoint_not_traffic_ack_or_interpolated_phases(self):
        for profile in (False, True):
            report = self.report()
            report["phase_windows"] = {"whole_contiguous_runtime": {"start_monotonic_seconds": 1.1, "end_monotonic_seconds": 2.9}}
            result = runtime.runtime_work_counter_diagnostic(report, profile=profile)
            self.assertTrue(result["available"])
            self.assertEqual((result["start_monotonic_seconds"], result["end_monotonic_seconds"]), (1, 3))
            self.assertEqual(result["deltas"]["instructions"], 24)
            self.assertEqual(result["deltas"]["cycles"], 32)
            self.assertEqual(result["deltas"]["qos_time_raw"]["default"], 16)
            self.assertEqual(result["profiled"], profile)
            self.assertFalse(result["acceptance_eligible"])
            self.assertIn("Exact acknowledged", result["interval_scope"])
            self.assertIn("differ from interpolated CPU phase-window edges", result["interval_scope"])

    def test_missing_or_interpolated_counter_boundary_is_only_an_invalid_optional_diagnostic(self):
        for boundary in (None, 2.9):
            report = self.report()
            report["runtime"]["checkpoints"][-1]["snapshot"]["runner_collector_sample_monotonic_seconds"] = boundary
            result = runtime.runtime_work_counter_diagnostic(report)
            self.assertEqual(result["status"], "invalid_diagnostic")
            self.assertFalse(result["available"])


class ProfilerFinalizationTests(unittest.TestCase):
    def diagnostic(self, directory, now, seconds=120):
        diagnostic = runtime.RuntimeDiagnostic(Path(directory),
            runtime.RuntimeDeadline(seconds, cleanup_reserve=8, clock=lambda: now[0]), "normal", profile=True)
        diagnostic.recorder = Mock(returncode=0)
        diagnostic.collector = Mock(exited=False)
        diagnostic.collector.receive.side_effect = lambda _timeout: now.__setitem__(0, now[0] + .5)
        diagnostic.runtime["profiler_status"] = "recording"
        diagnostic.save = Mock()
        diagnostic.trace.mkdir()
        return diagnostic

    def test_save_can_finish_after_ten_seconds_without_retry(self):
        now = [10.0]
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = self.diagnostic(directory, now)
            diagnostic.recorder.poll.side_effect = lambda: 0 if now[0] >= 25 else None
            with patch.object(runtime.time, "monotonic", side_effect=lambda: now[0]), \
                    patch.object(runtime, "read_run_issues", return_value={"available": True, "lost_events": False, "invalid": []}), \
                    patch.object(runtime.memory, "stop_owned_child") as stop:
                diagnostic.finish_profile()
                diagnostic.finish_profile(emergency=True)
            self.assertEqual(diagnostic.runtime["profiler_status"], "captured")
            self.assertEqual(now[0], 25)
            diagnostic.recorder.send_signal.assert_called_once_with(runtime.signal.SIGINT)
            stop.assert_not_called()

    def test_save_timeout_preserves_app_shutdown_reserve_and_never_retries(self):
        for seconds, expected_end in ((120, 40), (32, 16)):
            now = [10.0]
            with self.subTest(seconds=seconds), tempfile.TemporaryDirectory() as directory:
                diagnostic = self.diagnostic(directory, now, seconds)
                diagnostic.recorder.poll.return_value = None
                with patch.object(runtime.time, "monotonic", side_effect=lambda: now[0]), \
                        patch.object(runtime.memory, "stop_owned_child") as stop:
                    with self.assertRaisesRegex(TimeoutError, "bounded 30-second"):
                        diagnostic.finish_profile()
                    calls = diagnostic.collector.receive.call_count
                    diagnostic.finish_profile(emergency=True)
                self.assertEqual(now[0], expected_end)
                self.assertEqual(diagnostic.collector.receive.call_count, calls)
                self.assertEqual(diagnostic.runtime["profiler_status"], "failed")
                stop.assert_called_once_with(diagnostic.recorder, diagnostic.deadline)

    def test_emergency_cleanup_aborts_profiler_without_save_wait(self):
        now = [10.0]
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = self.diagnostic(directory, now)
            diagnostic.recorder.poll.return_value = None
            with patch.object(runtime.memory, "stop_owned_child") as stop:
                diagnostic.finish_profile(emergency=True)
            self.assertEqual(diagnostic.runtime["profiler_status"], "failed")
            diagnostic.collector.receive.assert_not_called()
            diagnostic.recorder.send_signal.assert_not_called()
            stop.assert_called_once()

    def test_owned_app_cleanup_runs_despite_profiler_and_graceful_shutdown_failures(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = runtime.RuntimeDiagnostic(Path(directory), runtime.RuntimeDeadline(120), "normal", profile=True)
            diagnostic.collector = Mock(exited=False)
            diagnostic.collector.finish.side_effect = TimeoutError("app shutdown timed out")
            with patch.object(diagnostic, "finish_profile", side_effect=OSError("recorder cleanup failed")), \
                    patch.object(runtime.memory.MemoryDiagnostic, "cleanup") as cleanup:
                diagnostic.cleanup()
            diagnostic.collector.finish.assert_called_once()
            cleanup.assert_called_once()
            self.assertTrue(any("recorder cleanup failed" in error for error in diagnostic.report["errors"]))
            self.assertTrue(any("app shutdown timed out" in error for error in diagnostic.report["errors"]))
            self.assertFalse(diagnostic.report["workload_cpu"]["available"])

    def test_profile_case_stays_bounded_within_outer_deadline(self):
        self.assertEqual(runtime.PROFILE_SECONDS, 120)
        self.assertLess(runtime.PROFILE_SECONDS + 2 * 45 + 30, runtime.MAX_SECONDS)


class ProfileAnalysisStatusTests(unittest.TestCase):
    def analysis(self, directory, *, mismatch):
        import runtime_time_profile as profile
        from test_runtime_time_profile import PID, anchor, kernel_samples, table_xml, toc_xml
        toc, table = Path(directory) / "toc.xml", Path(directory) / "table.xml"
        toc.write_text(toc_xml())
        table.write_text(table_xml().replace('fmt="1.00 ms">1000000', 'fmt="100.00 ms">100000000') if mismatch else table_xml())
        samples = kernel_samples()
        if mismatch:
            for sample in samples:
                sample["cpu_seconds"] *= 50
        return profile.analyze_exports(toc, table, PID,
            {"arrival": {"start_monotonic_seconds": 102, "end_monotonic_seconds": 104}}, anchor(), samples)

    def run_profile(self, directory, attribution):
        output = Path(directory) / "output"
        captured = {"status": "diagnostic_captured", "errors": [], "owned_identity": {"process_id": 1234},
            "runtime": {"clock_anchor": {}, "mach_clock_start": {}, "mach_clock_end": {}},
            "phase_windows": {}, "samples": [], "phase_cpu": {},
            "runtime_cpu_target": {"evaluated": False, "within_limit": None}}
        def capture(path, *_args, **_kwargs):
            path.mkdir()
            runtime.write_json(path / "runtime-case.json", captured)
            return copy.deepcopy(captured)
        args = ["profile", "--app-binary", "/app", "--test-bundle", "/tests",
                "--collector-binary", "/collector", "--provenance", "/provenance", "--output-dir", str(output)]
        with patch.object(runtime.sys, "platform", "darwin"), \
                patch.object(runtime, "runtime_source_identity", return_value={}), \
                patch.object(runtime.memory, "validate_products", return_value=({}, {}, {})), \
                patch.object(runtime, "capture_case", side_effect=capture), \
                patch("runtime_time_profile.analyze_trace", return_value=attribution), \
                contextlib.redirect_stdout(io.StringIO()):
            code = runtime.run(args)
        return code, json.loads((output / "runtime-report.json").read_text()), (output / "SUMMARY.md").read_text()

    def test_real_sample_kernel_mismatch_stays_pending_while_native_capture_is_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            attribution = self.analysis(directory, mismatch=True)
            code, report, summary = self.run_profile(directory, attribution)
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "analysis_pending")
        self.assertTrue(report["native_capture_complete"])
        self.assertEqual(report["cases"][0]["status"], "diagnostic_captured")
        self.assertEqual(report["attribution"], attribution)
        self.assertEqual(report["errors"], [])
        self.assertIn("arrival", report["analysis_pending_reasons"][0])
        self.assertIn("analysis_pending", summary)
        self.assertIn("Quantitative CPU attribution is unavailable", summary)
        self.assertNotIn("10.000%", summary)
        self.assertEqual(report["attribution"]["phases"][0]["total"]["weight_ns"], 200_000_000)

    def test_healthy_analysis_completes_without_claiming_unprofiled_cpu_acceptance(self):
        with tempfile.TemporaryDirectory() as directory:
            attribution = self.analysis(directory, mismatch=False)
            code, report, summary = self.run_profile(directory, attribution)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "diagnostic_captured")
        self.assertTrue(report["native_capture_complete"])
        self.assertEqual(report["attribution_status"], "profiled_phase_attribution_available")
        self.assertEqual(report["attribution"], attribution)
        self.assertNotIn("analysis_pending_reasons", report)
        self.assertIn("not evaluated", summary)
        self.assertFalse(report["regression_passed"])

    def test_conflicting_status_and_quality_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            attribution = self.analysis(directory, mismatch=False)
            attribution["analysis_quality"]["quantitative_attribution_usable"] = False
            code, report, _ = self.run_profile(directory, attribution)
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "diagnostic_incomplete")
        self.assertTrue(report["native_capture_complete"])
        self.assertEqual(report["attribution"], attribution)
        self.assertTrue(any("quality disagree" in error for error in report["errors"]))


class ComparisonReportingTests(unittest.TestCase):
    def test_drift_requires_both_absolute_and_relative_thresholds(self):
        for left, right, conclusive in ((2, 2.5, True), (2, 2.5001, False), (4, 4.8, True), (.2, .5, True), (0, 0, True)):
            with self.subTest(left=left, right=right):
                result = runtime.baseline_drift([case("before", left, 5), case("after", right, 5)])
                self.assertEqual(result["comparison_conclusive"], conclusive)

    def test_rolling_peak_drift_is_independent_of_mean(self):
        result = runtime.baseline_drift([case("before", 3, 4), case("after", 3, 6)])
        self.assertFalse(result["comparison_conclusive"])
        self.assertFalse(result["checks"]["average_cpu_percent"]["drifted"])
        self.assertTrue(result["checks"]["rolling_1s_percent"]["drifted"])

    def test_summary_uses_whole_runtime_including_tail_not_workload(self):
        text = runtime.summary({"operation": "compare", "status": "diagnostic_captured", "cases": [case("control")], "errors": []})
        self.assertIn("3.250%", text)
        self.assertIn("4.750%", text)
        self.assertNotIn("99.123%", text)
        self.assertNotIn("98.765%", text)
        self.assertIn("three-second", text)

    def test_profile_summary_never_presents_profiled_cpu_as_acceptance(self):
        selected = case("profile")
        selected["runtime_cpu_target"] = {"evaluated": False, "within_limit": None}
        text = runtime.summary({"operation": "profile", "status": "diagnostic_captured", "cases": [selected], "errors": []})
        self.assertIn("profiled attribution only", text)
        self.assertIn("not evaluated", text)
        self.assertNotIn("3.250%", text)
        self.assertNotIn("4.750%", text)

    def test_existing_output_preserved_before_product_validation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "existing"
            output.mkdir()
            evidence = output / "runtime-report.json"
            evidence.write_bytes(b"prior immutable evidence\n")
            args = ["compare", "--app-binary", "/missing/app", "--test-bundle", "/missing/tests",
                    "--collector-binary", "/missing/collector", "--provenance", "/missing/provenance.json",
                    "--output-dir", str(output)]
            with patch.object(runtime.sys, "platform", "darwin"), patch.object(runtime.memory, "validate_products") as products, patch.object(runtime, "capture_case") as capture, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(runtime.run(args), 1)
            self.assertEqual(evidence.read_bytes(), b"prior immutable evidence\n")
            self.assertEqual(list(output.iterdir()), [evidence])
            products.assert_not_called()
            capture.assert_not_called()


if __name__ == "__main__":
    unittest.main()
