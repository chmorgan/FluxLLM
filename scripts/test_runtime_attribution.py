"""Mocked runtime comparison contracts; no app, recorder, or fixture launch."""
import contextlib
import copy
import io
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
    if value["optimized_chart_preparation"]:
        after["optimized_chart_preparations"] += 2
    if value["incremental_history_ordering"]:
        after["history_tool_order_insertions"] += 2
        after["history_completed_order_insertions"] += 2
    else:
        after["history_tool_order_builds"] += 1
        after["history_completed_order_builds"] += 1
    after["graphics_diagnostics"]["roles"]["static_chart"]["draws"] += 2
    if value["lifecycle_effects_enabled"]:
        after["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] += 1
    return before, after


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
                self.assertEqual(result["deltas"]["static_chart_draws"], 2)
                self.assertEqual(result["features"], {field: after["graphics_diagnostics"][field] for field in memory.RUNTIME_FLAGS})

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
