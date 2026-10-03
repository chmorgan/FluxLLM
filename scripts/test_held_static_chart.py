"""Held drawing is a causal diagnostic, never a successful CPU optimization."""
import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import arrival_replay
import memory_attribution as memory
import runtime_attribution as runtime
from test_memory_diagnostic import drawn_native_gpu_graphics, graphics
from test_runtime_attribution import workload_snapshots
from test_runtime_clocks import phase_report


MODE = memory.HELD_STATIC_CHART_MODE


class HeldStaticContractTests(unittest.TestCase):
    def test_mode_keeps_production_rendering_and_cadence_contract(self):
        snapshot = drawn_native_gpu_graphics(MODE)
        result = memory.validate_graphics(snapshot, MODE, completed_visible_workload=True)
        features = result["runtime_feature_contract"]
        self.assertTrue(features["holds_static_chart_drawing"])
        for field in ("arrival_effects_enabled", "lifecycle_effects_enabled", "optimized_chart_preparation",
                      "incremental_history_ordering", "unpromised_stream_body_writes", "canvas_frame_clock"):
            self.assertTrue(features[field])
        self.assertFalse(features["metal_arrival_bursts_enabled"])
        self.assertEqual(result["chart_publication_interval_seconds"], 1)

    def test_flag_and_cadence_are_mandatory_exact_metadata(self):
        for field, invalid in (("holds_static_chart_drawing", False), ("holds_static_chart_drawing", 1),
                               ("chart_publication_interval_seconds", None),
                               ("chart_publication_interval_seconds", .5),
                               ("chart_publication_interval_seconds", True)):
            snapshot = drawn_native_gpu_graphics(MODE)
            if invalid is None:
                del snapshot["graphics_diagnostics"][field]
            else:
                snapshot["graphics_diagnostics"][field] = invalid
            with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                memory.validate_graphics(snapshot, MODE)

    def test_role_counters_are_complete_uint64_and_reconciled(self):
        for field in memory.HELD_STATIC_CHART_COUNTERS:
            for invalid in (None, True, -1, 2**64):
                snapshot = drawn_native_gpu_graphics(MODE)
                snapshot["graphics_diagnostics"]["roles"]["static_chart"][field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    memory.validate_graphics(snapshot, MODE)
        snapshot = drawn_native_gpu_graphics(MODE)
        snapshot["graphics_diagnostics"]["roles"]["static_chart"]["drawing_update_attempts"] += 1
        with self.assertRaisesRegex(ValueError, "do not reconcile"):
            memory.validate_graphics(snapshot, MODE)

    def test_non_static_roles_and_normal_cannot_hold_updates(self):
        for role in ("cursor", "rail_bars", "rail_decorations"):
            snapshot = drawn_native_gpu_graphics(MODE)
            snapshot["graphics_diagnostics"]["roles"][role].update(drawing_updates_held=1, drawing_update_attempts=1)
            with self.subTest(role=role), self.assertRaisesRegex(ValueError, "Unexpected held"):
                memory.validate_graphics(snapshot, MODE)
        value = drawn_native_gpu_graphics(MODE)["graphics_diagnostics"]
        value["holds_static_chart_drawing"] = False
        value["roles"]["static_chart"].update(drawing_updates_held=1, drawing_update_attempts=4)
        with self.assertRaisesRegex(ValueError, "Unexpected held"):
            memory.held_static_chart_counts(value, "normal")

    def test_older_normal_products_remain_supported(self):
        value = drawn_native_gpu_graphics()["graphics_diagnostics"]
        self.assertIsNone(memory.held_static_chart_counts(value, "normal"))

    def test_non_native_modes_accept_complete_zero_counters_with_false_metadata(self):
        for mode in ("direct-host", "empty-drawing", "no-renderer", "no-blur"):
            snapshot = graphics(mode)
            value = snapshot["graphics_diagnostics"]
            value["holds_static_chart_drawing"] = False
            for role in value["roles"].values():
                role.update(dict.fromkeys(memory.HELD_STATIC_CHART_COUNTERS, 0))
            with self.subTest(mode=mode):
                result = memory.validate_graphics(snapshot, mode)
                self.assertFalse(result["runtime_feature_contract"]["holds_static_chart_drawing"])


class HeldStaticWorkTests(unittest.TestCase):
    def test_valid_diagnostic_preserves_preparation_animation_and_streaming(self):
        before, after = workload_snapshots(MODE)
        result = runtime.validate_runtime_work(before, after, MODE)
        self.assertEqual(result["deltas"]["static_chart_draws"], 0)
        self.assertGreater(result["deltas"]["legacy_tool_plot_builds"], 0)
        for field in ("chart_preparations", "optimized_chart_preparations", "rail_frame_clock_ticks",
                      "streamed_bodies_without_promises", "history_tool_order_insertions"):
            self.assertGreater(result["deltas"][field], 0)
        held = result["held_static_chart_work"]
        self.assertTrue(held["drawing_only_control"])
        self.assertFalse(held["acceptance_eligible"])

    def test_redraw_replacement_or_reset_rejects_diagnostic(self):
        for field in ("draws", "created", "destroyed", "drawing_updates_applied", "drawing_hold_resets"):
            before, after = workload_snapshots(MODE)
            role = after["graphics_diagnostics"]["roles"]["static_chart"]
            role[field] += 1
            if field == "drawing_updates_applied":
                role["drawing_update_attempts"] += 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.held_static_chart_work(before, after, MODE)

    def test_initial_applied_draw_and_positive_held_attempts_required(self):
        for failure in ("undrawn", "unapplied", "no_updates"):
            before, after = workload_snapshots(MODE)
            for snapshot in (before, after):
                role = snapshot["graphics_diagnostics"]["roles"]["static_chart"]
                if failure == "undrawn":
                    role["draws"] = 0
                elif failure == "unapplied":
                    role["drawing_update_attempts"] -= role["drawing_updates_applied"]
                    role["drawing_updates_applied"] = 0
            if failure == "no_updates":
                after["graphics_diagnostics"]["roles"]["static_chart"] = copy.deepcopy(
                    before["graphics_diagnostics"]["roles"]["static_chart"])
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                runtime.held_static_chart_work(before, after, MODE)

    def test_preparation_cannot_be_frozen_or_slowed_with_drawing(self):
        before, after = workload_snapshots(MODE)
        after["runner_collector_sample_monotonic_seconds"] = 129
        with self.assertRaisesRegex(ValueError, "one-second chart preparation"):
            runtime.held_static_chart_work(before, after, MODE)
        after["chart_preparations"] = before["chart_preparations"] + 27
        self.assertEqual(runtime.held_static_chart_work(before, after, MODE)["minimum_chart_preparations"], 27)

    def test_hidden_windows_and_missing_boundary_rejected(self):
        for field, invalid in (("dashboard_visible", False), ("popover_visible", False),
                               ("runner_collector_sample_monotonic_seconds", None),
                               ("runner_collector_sample_monotonic_seconds", 100)):
            before, after = workload_snapshots(MODE)
            after[field] = invalid
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.held_static_chart_work(before, after, MODE)

    def test_interior_counter_reset_cannot_be_hidden_by_matching_endpoints(self):
        before, after = workload_snapshots(MODE)
        middle = copy.deepcopy(before)
        middle["graphics_diagnostics"]["roles"]["static_chart"]["draws"] += 1
        report = {"runtime": {"checkpoints": [{"snapshot": point} for point in (before, middle, after)]}}
        with self.assertRaisesRegex(ValueError, "interior checkpoint"):
            runtime.validate_held_static_chart_checkpoints(report, MODE)


class HeldStaticEligibilityTests(unittest.TestCase):
    def test_low_raw_cpu_is_available_but_never_acceptance_eligible(self):
        report = phase_report() | {"graphics_mode": MODE}
        result = runtime.phase_cpu(report, {"steady": {"start_monotonic_seconds": 102, "end_monotonic_seconds": 104}})
        self.assertAlmostEqual(result["steady"]["average_cpu_percent"], 1)
        self.assertFalse(result["steady"]["acceptance_eligible"])
        self.assertFalse(runtime.cpu_acceptance_eligible(MODE))
        self.assertTrue(runtime.cpu_acceptance_eligible("normal"))
        self.assertFalse(runtime.cpu_acceptance_eligible("normal", profile=True))

    def test_runtime_capture_keeps_raw_comparison_but_disables_every_target(self):
        before, after = workload_snapshots(MODE)
        report = {"graphics_mode": MODE, "errors": [], "workload": {"validated": True,
            "validated_work": runtime.WORK, "specification": {}, "fixture_status": {}, "fixture_start": {},
            "before": before, "after": after}, "runtime": {"checkpoints": [
                {"label": "before-traffic", "snapshot": before}, {"label": "completion-end", "snapshot": after}]}}
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(runtime, "RuntimeDiagnostic", return_value=Mock(report=report)), \
                patch.object(runtime.app, "validate_workload", return_value=runtime.WORK), \
                patch.object(runtime, "phase_windows", return_value={"whole_contiguous_runtime": {}}), \
                patch.object(runtime, "validate_visual_work", return_value={"available": True}), \
                patch.object(runtime, "validate_canvas_clock_work", return_value={"available": True}), \
                patch.object(runtime, "phase_cpu", return_value={"whole_contiguous_runtime": {
                    "average_cpu_percent": 1, "rolling_1s_percent": 2, "acceptance_eligible": True}}):
            result = runtime.capture_case(Path(directory) / "case", MODE, {}, {}, {}, runtime.RuntimeDeadline())
        self.assertEqual(result["status"], "diagnostic_captured")
        self.assertTrue(result["phase_cpu_comparison_available"])
        self.assertFalse(result["cpu_acceptance_eligible"])
        self.assertFalse(result["phase_cpu"]["whole_contiguous_runtime"]["acceptance_eligible"])
        self.assertFalse(result["runtime_cpu_target"]["evaluated"])
        self.assertIsNone(result["runtime_cpu_target"]["within_limit"])
        self.assertFalse(result["workload_cpu"]["acceptance_eligible"])
        self.assertIsNone(result["workload_cpu"]["within_limit"])

    def test_arrivals_explicitly_reject_drawing_ablation(self):
        with self.assertRaisesRegex(ValueError, "runtime diagnostic"):
            arrival_replay.validate_replay({}, MODE, False)


if __name__ == "__main__":
    unittest.main()
