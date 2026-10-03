"""Offline command-level checks for opt-in scoped NIO CPU diagnostics."""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import runtime_attribution as runtime


def analysis_result(available=True):
    return {
        "available": available,
        "status": "available" if available else "unavailable",
        "acceptance_eligible": False,
        "errors": [] if available else ["Thread totals exceed same-window process CPU"],
        "intervals": {},
    }


class NIOCaptureQualificationTests(unittest.TestCase):
    def capture(self, directory, analysis):
        window = {"start_monotonic_seconds": 100, "end_monotonic_seconds": 129}
        report = {
            "errors": [],
            "graphics_mode": "normal",
            "cpu_gate_evaluated": False,
            "workload_cpu": {"available": True, "gate_evaluated": False},
            "workload": {"validated": True, "validated_work": runtime.WORK,
                         "specification": {}, "fixture_status": {}, "fixture_start": {},
                         "before": {}, "after": {}},
            "runtime": {"profiled": False, "cpu_comparison_available": True,
                        "checkpoints": [{"label": "before-traffic", "snapshot": {}},
                                        {"label": "completion-end", "snapshot": {}}]},
        }
        diagnostic = Mock(report=report, runtime=report["runtime"])
        observed_environment = []
        diagnostic.perform.side_effect = lambda *_: observed_environment.append(
            os.environ.get("FLUXLLM_PERF_THREAD_CPU"))
        phase = {"whole_contiguous_runtime": {"average_cpu_percent": 2.0,
                 "rolling_1s_percent": 4.0, "acceptance_eligible": True}}
        replacements = {
            "RuntimeDiagnostic": diagnostic,
            "phase_windows": {"whole_contiguous_runtime": window},
            "validate_visual_work": {"available": True},
            "validate_runtime_work": {"available": True},
            "validate_canvas_clock_work": {"available": False},
            "validate_steady_twinkle_delivery": {"available": False},
            "validate_held_static_chart_checkpoints": None,
            "phase_cpu": phase,
            "runtime_work_counter_diagnostic": {"available": False},
        }
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.dict(os.environ, {"FLUXLLM_PERF_THREAD_CPU": "inherited"}))
            for name, result in replacements.items():
                stack.enter_context(patch.object(runtime, name, return_value=result))
            stack.enter_context(patch.object(runtime.app, "validate_workload", return_value=runtime.WORK))
            stack.enter_context(patch("runtime_thread_cpu.analyze_report", return_value=analysis_result()))
            analyze = stack.enter_context(patch("runtime_nio_cpu.analyze_report", side_effect=analysis))
            captured = runtime.capture_case(Path(directory) / "case", "normal", {}, {}, {},
                                           runtime.RuntimeDeadline(), nio_cpu=True)
            self.assertEqual(os.environ["FLUXLLM_PERF_THREAD_CPU"], "inherited")
        self.assertEqual(observed_environment, ["1"])
        diagnostic.cleanup.assert_called_once()
        analyze.assert_called_once_with(captured, required=True)
        return captured

    def assert_instrumented(self, report):
        self.assertFalse(report["cpu_acceptance_eligible"])
        self.assertFalse(report["cpu_gate_evaluated"])
        self.assertFalse(report["phase_cpu_comparison_available"])
        self.assertFalse(report["runtime"]["cpu_comparison_available"])
        self.assertFalse(report["runtime_cpu_target"]["evaluated"])
        self.assertFalse(report["runtime_cpu_target"]["acceptance_eligible"])
        self.assertIsNone(report["runtime_cpu_target"]["within_limit"])
        self.assertFalse(report["workload_cpu"]["acceptance_eligible"])
        self.assertFalse(report["workload_cpu"]["gate_evaluated"])
        self.assertIsNone(report["workload_cpu"]["within_limit"])
        for phase in report["phase_cpu"].values():
            self.assertFalse(phase["acceptance_eligible"])

    def test_low_cpu_nio_remain_diagnostic_before_and_after_analysis(self):
        def analyze(report, *, required):
            self.assertTrue(required)
            self.assert_instrumented(report)
            return analysis_result()
        with tempfile.TemporaryDirectory() as directory:
            report = self.capture(directory, analyze)
        self.assertEqual(report["status"], "diagnostic_captured")
        self.assertEqual(report["nio_cpu_analysis"], analysis_result())
        self.assert_instrumented(report)

    def test_analyzer_failure_keeps_raw_cpu_diagnostic_and_restores_environment(self):
        def analyze(report, *, required):
            self.assert_instrumented(report)
            raise ValueError("Thread identity changed at a kernel boundary")
        with tempfile.TemporaryDirectory() as directory:
            report = self.capture(directory, analyze)
            saved = json.loads((Path(directory) / "case" / "runtime-case.json").read_text())
        self.assertEqual(report["status"], "diagnostic_captured")
        self.assertIn("Thread identity changed at a kernel boundary", report["nio_cpu_analysis"]["errors"])
        self.assert_instrumented(report)
        self.assertEqual(saved, report)

    def test_capture_failure_restores_environment_and_still_attempts_cleanup(self):
        report = {"errors": [], "runtime": {"cpu_comparison_available": True}}
        diagnostic = Mock(report=report, runtime=report["runtime"])
        def fail(*_):
            self.assertEqual(os.environ.get("FLUXLLM_PERF_THREAD_CPU"), "1")
            raise TimeoutError("Owned collector readiness timed out")
        diagnostic.perform.side_effect = fail
        with tempfile.TemporaryDirectory() as directory, \
                patch.dict(os.environ, {"FLUXLLM_PERF_THREAD_CPU": "prior"}), \
                patch.object(runtime, "RuntimeDiagnostic", return_value=diagnostic):
            captured = runtime.capture_case(Path(directory) / "case", "normal", {}, {}, {},
                                           runtime.RuntimeDeadline(), nio_cpu=True)
            self.assertEqual(os.environ["FLUXLLM_PERF_THREAD_CPU"], "prior")
        diagnostic.cleanup.assert_called_once()
        self.assertEqual(captured["status"], "diagnostic_incomplete")
        self.assertIn("Owned collector readiness timed out", captured["errors"])
        self.assertFalse(captured["cpu_acceptance_eligible"])
        self.assertFalse(captured["cpu_gate_evaluated"])
        self.assertFalse(captured["runtime"]["cpu_comparison_available"])


class NIOCommandStatusTests(unittest.TestCase):
    def run_nio(self, directory, analysis, *, capture_error=None):
        output = Path(directory) / "output"
        captured = {
            "status": "diagnostic_captured",
            "errors": [],
            "owned_identity": {"process_id": 1234},
            "runtime": {"profiled": False, "cpu_comparison_available": False},
            "phase_cpu": {"whole_contiguous_runtime": {"average_cpu_percent": 2.0,
                          "rolling_1s_percent": 4.0, "acceptance_eligible": False}},
            "runtime_cpu_target": {"evaluated": False, "acceptance_eligible": False,
                                   "within_limit": None},
            "nio_cpu_analysis": copy.deepcopy(analysis),
            "thread_cpu_analysis": analysis_result(),
            "visual_work": {"available": True, "request_ids": ["first", "second"]},
        }
        def capture(path, *_args, **kwargs):
            path.mkdir()
            case = copy.deepcopy(captured)
            if not kwargs.get("nio_cpu"):
                del case["nio_cpu_analysis"]
                del case["thread_cpu_analysis"]
                case["runtime"]["cpu_comparison_available"] = True
                case["phase_cpu"]["whole_contiguous_runtime"]["acceptance_eligible"] = True
                case["runtime_cpu_target"].update(evaluated=True, acceptance_eligible=True, within_limit=True)
            elif capture_error:
                case.update(status="diagnostic_incomplete", errors=[capture_error])
            runtime.write_json(path / "runtime-case.json", case)
            return case
        args = ["nio", "--app-binary", "/app", "--test-bundle", "/tests",
                "--collector-binary", "/collector", "--provenance", "/provenance",
                "--output-dir", str(output)]
        with patch.object(runtime.sys, "platform", "darwin"), \
                patch.object(runtime, "runtime_source_identity", return_value={}), \
                patch.object(runtime.memory, "validate_products", return_value=({}, {}, {})), \
                patch.object(runtime, "capture_case", side_effect=capture) as capture_mock, \
                patch.object(runtime, "RuntimeDeadline", wraps=runtime.RuntimeDeadline) as deadline_mock, \
                patch("runtime_nio_cpu.render_summary", return_value=["NIO diagnostics", *analysis["errors"]]), \
                contextlib.redirect_stdout(io.StringIO()):
            code = runtime.run(args)
        calls = capture_mock.call_args_list
        labels = ["observer-before", "nio"] + ([] if capture_error else ["observer-after"])
        self.assertEqual([call.args[0].name for call in calls], labels)
        self.assertTrue(all(call.args[1] == "normal" for call in calls))
        self.assertEqual([bool(call.kwargs.get("nio_cpu")) for call in calls],
                         [False, True] + ([] if capture_error else [False]))
        self.assertTrue(all(call.kwargs.get("profile") is False for call in calls))
        per_case_deadlines = [call for call in deadline_mock.call_args_list if call.args]
        self.assertEqual(len(per_case_deadlines), len(calls))
        self.assertTrue(all(call.args == (70,) and call.kwargs == {"cleanup_reserve": 8}
                            for call in per_case_deadlines))
        return code, json.loads((output / "runtime-report.json").read_text()), (output / "SUMMARY.md").read_text()

    def test_complete_nio_analysis_propagates_without_cpu_acceptance(self):
        analysis = analysis_result()
        with tempfile.TemporaryDirectory() as directory:
            code, report, summary = self.run_nio(directory, analysis)
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "diagnostic_captured")
        self.assertTrue(report["native_capture_complete"])
        self.assertEqual(report["nio_cpu_analysis"], analysis)
        self.assertEqual(report["cases"][1]["nio_cpu_analysis"], analysis)
        self.assertEqual(report["attribution_status"], analysis["status"])
        self.assertFalse(report["regression_passed"])
        self.assertNotIn("analysis_pending_reasons", report)
        self.assertIn("not evaluated", summary)
        self.assertIn("instrumented", summary.lower())
        thread_rows = [line for line in summary.splitlines() if line.startswith("| nio |")]
        self.assertEqual(len(thread_rows), 1)
        self.assertIn("instrumented", thread_rows[0].lower())
        self.assertNotIn("unprofiled kernel counters", thread_rows[0])

    def test_failed_reconciliation_preserves_complete_capture_but_exits_nonzero(self):
        analysis = analysis_result(False)
        with tempfile.TemporaryDirectory() as directory:
            code, report, summary = self.run_nio(directory, analysis)
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "analysis_pending")
        self.assertTrue(report["native_capture_complete"])
        self.assertEqual(report["cases"][1]["status"], "diagnostic_captured")
        self.assertEqual(report["nio_cpu_analysis"], analysis)
        self.assertEqual(report["analysis_pending_reasons"], analysis["errors"])
        self.assertFalse(report["regression_passed"])
        self.assertEqual(report["errors"], [])
        self.assertIn("analysis_pending", summary)
        self.assertIn(analysis["errors"][0], summary)

    def test_native_capture_failure_is_not_promoted_by_available_analysis(self):
        with tempfile.TemporaryDirectory() as directory:
            code, report, summary = self.run_nio(directory, analysis_result(),
                                                    capture_error="Measured window became hidden")
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "diagnostic_incomplete")
        self.assertFalse(report.get("native_capture_complete", False))
        self.assertFalse(report["regression_passed"])
        self.assertTrue(any("Measured window became hidden" in error for error in report["errors"]))
        self.assertEqual(report["cases"][1]["status"], "diagnostic_incomplete")
        self.assertIn("Measured window became hidden", summary)


class NIOEnvironmentAndSelectionTests(unittest.TestCase):
    def test_nio_flag_is_removed_for_every_non_nio_case_and_restored(self):
        for thread_enabled, nio_enabled, expected in ((False, False, (None, None)),
                                                       (True, False, ("1", None)),
                                                       (False, True, ("1", "1"))):
            with patch.dict(os.environ, {"FLUXLLM_PERF_THREAD_CPU": "prior-thread",
                                         "FLUXLLM_PERF_NIO_CPU": "prior-nio"}):
                with runtime.thread_cpu_environment(thread_enabled, nio_enabled):
                    self.assertEqual((os.environ.get("FLUXLLM_PERF_THREAD_CPU"),
                                      os.environ.get("FLUXLLM_PERF_NIO_CPU")), expected)
                self.assertEqual(os.environ["FLUXLLM_PERF_THREAD_CPU"], "prior-thread")
                self.assertEqual(os.environ["FLUXLLM_PERF_NIO_CPU"], "prior-nio")

    def test_environment_restores_both_flags_after_exception(self):
        with patch.dict(os.environ, {"FLUXLLM_PERF_THREAD_CPU": "prior-thread",
                                     "FLUXLLM_PERF_NIO_CPU": "prior-nio"}):
            with self.assertRaisesRegex(ValueError, "capture failed"):
                with runtime.thread_cpu_environment(True, True):
                    raise ValueError("capture failed")
            self.assertEqual(os.environ["FLUXLLM_PERF_THREAD_CPU"], "prior-thread")
            self.assertEqual(os.environ["FLUXLLM_PERF_NIO_CPU"], "prior-nio")

    def test_command_selects_fixed_off_on_off_and_rejects_controls(self):
        args = runtime.parser().parse_args(["nio", "--app-binary", "/app", "--test-bundle", "/tests",
            "--collector-binary", "/collector", "--provenance", "/provenance"])
        self.assertEqual(runtime.selected_cases(args), [("observer-before", "normal"),
                                                        ("nio", "normal"), ("observer-after", "normal")])
        self.assertEqual(runtime.MAX_SECONDS, 300)
        self.assertEqual(runtime.NIO_CASE_SECONDS, 70)
        self.assertEqual(runtime.CASE_SECONDS, 54)
        self.assertEqual(runtime.PROFILE_SECONDS, 120)
        self.assertLess(3 * runtime.NIO_CASE_SECONDS + 15, runtime.MAX_SECONDS)
        args.controls = ["runtime-optimized"]
        with self.assertRaisesRegex(ValueError, "cannot combine graphics controls"):
            runtime.selected_cases(args)

    def test_source_capsule_includes_new_analyzer(self):
        self.assertIn("runtime_nio_cpu.py", runtime.runtime_source_identity())


if __name__ == "__main__":
    unittest.main()
