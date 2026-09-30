"""Fast checks for the actual-app performance runner; no builds or app launch."""

import contextlib
import copy
import io
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

import app_performance as app
from performance_fixture import StreamTiming, TIMING_POLICY


def samples():
    return [{"type": "sample", "process_id": 123, "birth_time_us": 456,
             "monotonic_seconds": index / 4, "cpu_seconds": index / 400,
             "gpu_seconds": index / 4000, "physical_footprint_bytes": 1000000,
             "lifetime_peak_footprint_bytes": 1000000, "physical_write_bytes": 0,
             "logical_write_bytes": 0, "trace_coverage": True}
            for index in range(13)]


def budget():
    return app.load_json(app.BUDGET_PATH)


def fixture_evidence(stage):
    expected = app.expected_work(stage)
    acknowledgement = {"run_id": "test-run", "running": True, "expected_requests": 2,
                       "expected_request_indices": [32, 33], "expected_chunks": expected["chunks"],
                       "expected_output_tokens": expected["output_tokens"], "expected_prompt_tokens": expected["prompt_tokens"]}
    streams = []
    rate = 40 if stage["activity"] == "ordinary" else 200
    chunks = expected["chunks"] // 2
    for index in acknowledgement["expected_request_indices"]:
        timing = StreamTiming(index, chunks, rate, stage["seconds"], 100)
        for chunk in range(chunks + 1):
            due = 100 + (stage["seconds"] if chunk == chunks else chunk / rate)
            timing.observed(chunk, due, due)
        streams.append(timing.snapshot())
    status = {"run_id": acknowledgement["run_id"], "running": False, "error": None, "forwarding_verified": True,
              "completed_requests": 2, "received_chunks": expected["chunks"], "tool_calls": 2, "tool_results": 2,
              "timing": dict(TIMING_POLICY, streams=streams)}
    return acknowledgement, status


class ResourceGateTests(unittest.TestCase):
    def test_one_second_cpu_window_preserves_fractional_accounting(self):
        metrics, failures, invalid = app.evaluate_resources(samples(), budget()["limits"], [])
        self.assertAlmostEqual(metrics["cpu_rolling_1s_percent"], 1)
        self.assertAlmostEqual(metrics["gpu_percent"], 0.1)
        self.assertEqual(failures, [])
        self.assertEqual(invalid, [])

    def test_irregular_samples_interpolate_window_boundary(self):
        points = [{"monotonic_seconds": timestamp, "cpu_seconds": timestamp * 0.03}
                  for timestamp in (0, 0.28, 0.53, 0.8, 1.08, 1.4, 1.65)]
        self.assertAlmostEqual(app.rolling_percent(points, "cpu_seconds"), 3)

    def test_burst_is_not_hidden_by_low_lifetime_average(self):
        points = samples()
        for point in points[5:]:
            point["cpu_seconds"] += 0.08
        _, failures, invalid = app.evaluate_resources(points, budget()["limits"], [])
        self.assertTrue(any("CPU" in failure for failure in failures))
        self.assertEqual(invalid, [])

    def test_memory_limit_is_strictly_below_64_million_bytes(self):
        points = samples()
        for point in points:
            point["lifetime_peak_footprint_bytes"] = 64000000
        _, failures, _ = app.evaluate_resources(points, budget()["limits"], [])
        self.assertTrue(any("footprint" in failure for failure in failures))

    def test_one_percent_gpu_limit_is_independent_of_cpu(self):
        points = samples()
        for point in points:
            point["gpu_seconds"] = point["monotonic_seconds"] * 0.02
        _, failures, invalid = app.evaluate_resources(points, budget()["limits"], [])
        self.assertTrue(any("GPU" in failure for failure in failures))
        self.assertEqual(invalid, [])

    def test_cached_gpu_samples_are_not_counted_as_fast_bursts(self):
        points = samples()
        for index, point in enumerate(points):
            point.update(gpu_sampled=index % 4 == 0, gpu_sample_monotonic_seconds=index // 4,
                         gpu_seconds=(index // 4) * 0.005)
        metrics, failures, invalid = app.evaluate_resources(points, budget()["limits"], [])
        self.assertAlmostEqual(metrics["gpu_percent"], 0.5)
        self.assertEqual(failures, [])
        self.assertEqual(invalid, [])

    def test_missing_gpu_and_trace_never_pass_as_zero(self):
        points = samples()
        points[4].update(gpu_seconds=None, trace_coverage=False)
        _, _, invalid = app.evaluate_resources(points, budget()["limits"], [])
        self.assertTrue(any("GPU" in error for error in invalid))
        self.assertTrue(any("trace coverage" in error for error in invalid))

    def test_counter_reset_wrong_pid_and_infinite_time_are_invalid(self):
        for changes in ({"cpu_seconds": -1}, {"process_id": 999}, {"monotonic_seconds": float("inf")},
                        {"physical_write_bytes": -1}, {"cpu_seconds": None}):
            with self.subTest(changes=changes):
                points = samples()
                points[4].update(changes)
                self.assertTrue(app.validate_samples(points))

    def test_initial_and_off_interval_writes_are_counted(self):
        points = samples()
        for index, point in enumerate(points):
            point["logical_write_bytes"] = 7 + (20 if index >= 6 else 0)
        metrics, failures, _ = app.evaluate_resources(points, budget()["limits"], [])
        self.assertEqual(metrics["logical_write_bytes_logging_off"], 27)
        self.assertTrue(any("logical_write" in failure for failure in failures))

    def test_exact_verified_on_interval_does_not_exempt_other_periods(self):
        points = samples()
        for index, point in enumerate(points):
            point["physical_write_bytes"] = (20 if index >= 6 else 0) + (5 if index >= 10 else 0)
        metrics, _, _ = app.evaluate_resources(points, budget()["limits"], [(1, 2)])
        self.assertEqual(metrics["physical_write_bytes_logging_off"], 5)

    def test_trace_writes_must_match_both_logging_path_and_interval(self):
        events = [{"type": "file_io", "is_write": True, "monotonic_seconds": 1.5,
                   "timestamp_attribution": True, "timestamp_uncertainty_seconds": 0.01, "path": path, "operation": "write"}
                  for path in ("/tmp/log.jsonl", "/tmp/history.json")]
        failures, invalid = app.evaluate_file_events(events, [(1, 2)], ["/tmp/log.jsonl"])
        self.assertEqual(len(failures), 1)
        self.assertIn("history.json", failures[0])
        self.assertEqual(invalid, [])

    def test_trace_write_without_time_or_path_attribution_is_invalid(self):
        events = [{"type": "file_io", "is_write": True, "operation": "write"}]
        self.assertTrue(app.evaluate_file_events(events, [(1, 2)], ["/tmp/log"])[1])
        self.assertTrue(app.evaluate_file_events(events, [], [])[0])

    def test_long_sampling_gaps_cannot_smear_a_cpu_burst_into_a_pass(self):
        points = [samples()[0], dict(samples()[-1], monotonic_seconds=20, cpu_seconds=1)]
        self.assertTrue(any("sampling gap" in problem for problem in app.validate_samples(points)))

    def test_timestamp_uncertainty_cannot_hide_an_off_interval_write(self):
        event = {"type": "file_io", "is_write": True, "monotonic_seconds": 1.001,
                 "timestamp_attribution": True, "timestamp_uncertainty_seconds": 0.01,
                 "path": "/tmp/log", "operation": "write"}
        self.assertTrue(app.evaluate_file_events([event], [(1, 2)], ["/tmp/log"])[0])


class ProtocolTests(unittest.TestCase):
    def test_explicit_visibility_failure_keeps_remaining_ui_commands_running(self):
        collector = mock.Mock()
        collector.command.side_effect = [
            {"command": "show_dashboard", "status": "error", "reason": "Dashboard did not become visible"},
            {"command": "show_popover", "status": "ok"}]
        invalid = []
        app.visible(collector, True, invalid)
        self.assertEqual(collector.command.call_count, 2)
        self.assertEqual(len(invalid), 1)
        self.assertIn("coverage is incomplete", invalid[0])

    def test_visibility_continuation_does_not_swallow_transport_or_other_errors(self):
        collector = mock.Mock()
        collector.command.side_effect = TimeoutError("transport failed")
        with self.assertRaises(TimeoutError):
            app.visible(collector, True, [])
        collector.command.side_effect = None
        collector.command.return_value = {"command": "show_dashboard", "status": "error", "reason": "unrelated failure"}
        with self.assertRaises(app.InvalidResult):
            app.visible(collector, True, [])

    def test_logging_whitelist_is_exact_and_anchored_to_the_owned_uuid(self):
        with tempfile.TemporaryDirectory() as temporary:
            storage = {"root": temporary, "run_id": "00000000-0000-0000-0000-000000000001"}
            directory = Path(temporary).resolve() / storage["run_id"] / "Diagnostics"
            expected = [str(directory), *(str(directory / name) for name in
                                         ("diagnostics.jsonl", "diagnostics.1.jsonl", "diagnostics.2.jsonl"))]
            response = {"logging_destination": str(directory / "diagnostics.jsonl"), "logging_destinations": expected}
            self.assertEqual(app.validated_logging_destinations(response, storage), sorted(expected))
            for unexpected in (str(directory.parent / "History"), str(directory / "other.jsonl"), "/tmp/diagnostics.jsonl"):
                with self.subTest(unexpected=unexpected), self.assertRaises(app.InvalidResult):
                    app.validated_logging_destinations(dict(response, logging_destinations=expected[:3] + [unexpected]), storage)

    def test_invalid_logger_destinations_grant_no_write_interval(self):
        collector = mock.Mock()
        collector.storage = {"root": "/tmp", "run_id": "owned-uuid"}
        collector.command.return_value = {"status": "ok", "logging_enabled": True,
                                          "collector_control_before_seconds": 1,
                                          "logging_destination": "/tmp/other/log.jsonl",
                                          "logging_destinations": ["/tmp/other/log.jsonl"]}
        case = {"invalid": [], "logging_transitions": [], "logging_destinations": []}
        self.assertIsNone(app.set_logging(collector, True, case, None))
        self.assertTrue(case["invalid"])
        self.assertEqual(case["logging_destinations"], [])

    def test_both_history_modes_launch_with_an_empty_external_directory(self):
        for history in ("fresh", "populated"):
            with self.subTest(history=history), tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                artifacts, storage = directory / "artifacts", directory / "storage"
                artifacts.mkdir()
                storage.mkdir()
                process = mock.Mock()
                process.stdout, process.stdin = io.BytesIO(), io.BytesIO()
                process.poll.return_value = 0
                with mock.patch.object(app.tempfile, "mkdtemp", return_value=str(storage)), \
                        mock.patch.object(app.subprocess, "Popen", return_value=process) as launch, \
                        mock.patch.object(app, "stop_process_group"):
                    collector = app.Collector(Path("/collector"), Path("/app"),
                                              {"history": history, "upstream_url": "http://127.0.0.1:123"},
                                              {}, artifacts, app.Deadline(5))
                    try:
                        self.assertEqual(launch.call_count, 1)
                        self.assertEqual(launch.call_args.args[0][1], "--app")
                        self.assertEqual(list((storage / collector.storage["run_id"]).iterdir()), [])
                        self.assertFalse((artifacts / "seed.log").exists())
                    finally:
                        collector.close()

    def test_chart_assertion_failure_preserves_emitted_measurements(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            result = {"configuration": "release", "equivalentOutputs": True,
                      "budgetStatus": "enforced", "cases": [{"cpuSeconds": 0.03} for _ in range(6)]}
            app.write_json(directory / "chart.json", result)
            with mock.patch.object(app, "execute_logged", return_value={"exit_code": 1}):
                measured = app.run_chart(Path("/tests"), directory, app.Deadline(5))
            self.assertEqual(measured["result"], result)
            self.assertTrue(measured["failures"])
            self.assertEqual(measured["invalid"], [])

    def test_chart_success_without_result_is_incomplete(self):
        with tempfile.TemporaryDirectory() as temporary:
            with mock.patch.object(app, "execute_logged", return_value={"exit_code": 0}):
                measured = app.run_chart(Path("/tests"), Path(temporary), app.Deadline(5))
            self.assertTrue(measured["invalid"])

    def test_malformed_oversized_duplicate_and_nonfinite_records_are_rejected(self):
        for raw in (b"not-json", b"[]", b'{"type":"sample","type":"error"}',
                    b'{"type":"sample","cpu_seconds":NaN}', b" " * (app.MAX_RECORD_BYTES + 1)):
            with self.subTest(raw=raw[:40]), self.assertRaises(app.InvalidResult):
                app.strict_record(raw)

    def test_approved_workload_totals_180_seconds_and_has_one_logging_stream(self):
        value = app.validate_budget(budget())
        self.assertEqual(sum(stage["seconds"] for case in value["cases"] for stage in case["stages"]), 180)
        expected = app.expected_work({"activity": "ordinary", "seconds": 30})
        self.assertEqual(expected["requests"], 2)
        self.assertEqual(expected["chunks"], 2400)

    def test_budget_cannot_silently_loosen_limits_or_drop_cases(self):
        for change in (lambda value: value["limits"].update(gpu_percent=None),
                       lambda value: value["limits"].update(cpu_rolling_1s_percent=6),
                       lambda value: value["limits"].update(lifetime_footprint_bytes=64000001),
                       lambda value: value["cases"].pop(),
                       lambda value: value["cases"][1]["stages"][-1].update(open_close_cycles=0)):
            with self.subTest(change=change), self.assertRaises(app.InvalidResult):
                value = budget()
                change(value)
                app.validate_budget(value)

    def test_workload_cannot_pass_with_dropped_chunks_tools_or_tokens(self):
        stage = {"activity": "ordinary", "seconds": 10}
        expected = app.expected_work(stage)
        before = {field: 0 for field in expected}
        after = dict(expected)
        acknowledgement, status = fixture_evidence(stage)
        self.assertEqual(app.validate_workload(stage, status, before, after, acknowledgement), expected)
        for field in ("requests", "output_tokens", "prompt_tokens", "tool_calls", "tool_results"):
            with self.subTest(field=field), self.assertRaises(app.InvalidResult):
                changed = dict(after)
                changed[field] -= 1
                app.validate_workload(stage, status, before, changed, acknowledgement)
        status["received_chunks"] -= 1
        with self.assertRaises(app.InvalidResult):
            app.validate_workload(stage, status, before, after, acknowledgement)

    def test_timing_requires_current_workload_complete_streams_and_fixed_policy(self):
        stage = {"activity": "high-rate", "seconds": 1}
        changes = (
            lambda value: value.update(run_id="previous-run"),
            lambda value: value.pop("timing"),
            lambda value: value["timing"].update(maximum_lateness_seconds=0.5),
            lambda value: value["timing"]["streams"].pop(),
            lambda value: value["timing"]["streams"][1].update(request_index=32),
            lambda value: value["timing"]["streams"][0].update(records_observed=200),
            lambda value: value["timing"]["streams"][0].update(rate_hz=40),
            lambda value: value["timing"]["streams"][0].update(duration_seconds=0.9))
        acknowledgement, original = fixture_evidence(stage)
        app.validate_fixture_timing(stage, original, acknowledgement)
        for change in changes:
            with self.subTest(change=change), self.assertRaises(app.InvalidResult):
                status = copy.deepcopy(original)
                change(status)
                app.validate_fixture_timing(stage, status, acknowledgement)

    def test_timing_recomputes_bad_maxima_and_rejects_invalid_numbers(self):
        stage = {"activity": "ordinary", "seconds": 1}
        for field, value in (("maximum_start_lateness_seconds", 0.051),
                             ("maximum_finish_lateness_seconds", 0.051),
                             ("maximum_earliness_seconds", 0.001),
                             ("maximum_flush_seconds", 0.06),
                             ("terminal_flush_finished_monotonic_seconds", None),
                             ("maximum_finish_lateness_seconds", float("nan")),
                             ("maximum_finish_lateness_seconds", float("inf")),
                             ("maximum_finish_lateness_seconds", True),
                             ("maximum_finish_lateness_seconds", -1)):
            with self.subTest(field=field, value=value), self.assertRaises(app.InvalidResult):
                acknowledgement, status = fixture_evidence(stage)
                status["timing"]["streams"][0].update({field: value, "timing_passed": True})
                app.validate_fixture_timing(stage, status, acknowledgement)

    def test_timing_recomputes_endpoint_duration_and_concurrent_skew(self):
        stage = {"activity": "ordinary", "seconds": 1}
        for change in ("early-terminal", "stretched-terminal", "skew", "reversed"):
            with self.subTest(change=change), self.assertRaises(app.InvalidResult):
                acknowledgement, status = fixture_evidence(stage)
                stream = status["timing"]["streams"][0]
                if change == "skew":
                    for field in tuple(stream):
                        if field.endswith("monotonic_seconds"):
                            stream[field] += 0.051
                elif change == "reversed":
                    stream["first_write_started_monotonic_seconds"] = 101
                else:
                    offset = -0.01 if change == "early-terminal" else 0.051
                    stream["terminal_write_started_monotonic_seconds"] += offset
                    stream["terminal_flush_finished_monotonic_seconds"] += offset
                app.validate_fixture_timing(stage, status, acknowledgement)

    def test_timing_accepts_exact_policy_boundaries(self):
        stage = {"activity": "high-rate", "seconds": 1}
        acknowledgement, status = fixture_evidence(stage)
        stream = status["timing"]["streams"][0]
        stream["terminal_write_started_monotonic_seconds"] += 0.05
        stream["terminal_flush_finished_monotonic_seconds"] += 0.05
        stream["maximum_start_lateness_seconds"] = 0.05
        stream["maximum_finish_lateness_seconds"] = 0.05
        app.validate_fixture_timing(stage, status, acknowledgement)

    def test_completed_but_buffered_stream_is_invalid(self):
        stage = {"activity": "ordinary", "seconds": 10}
        with self.assertRaisesRegex(app.InvalidResult, "incremental forwarding"):
            app.validate_workload(stage, {"running": False, "error": None, "forwarding_verified": False}, {}, {})

    def test_fixture_start_accepts_202_and_other_endpoints_require_200(self):
        for endpoint, status in (("/control/start", 202), ("/control/status", 200)):
            with self.subTest(endpoint=endpoint), mock.patch.object(app, "HTTPConnection") as connection:
                response = connection.return_value.getresponse.return_value
                response.status = status
                response.read.return_value = b'{"running":true}'
                value = app.fixture_request("http://127.0.0.1:123", endpoint, app.Deadline(5), {} if status == 202 else None)
                self.assertIs(value["running"], True)

    def test_fixture_start_manifest_cannot_reduce_the_workload(self):
        stage = {"activity": "ordinary", "seconds": 30}
        expected = app.expected_work(stage)
        acknowledgement, _ = fixture_evidence(stage)
        app.validate_fixture_start(stage, acknowledgement)
        acknowledgement["expected_requests"] = 1
        with self.assertRaises(app.InvalidResult):
            app.validate_fixture_start(stage, acknowledgement)

    def test_visible_ui_and_counters_cannot_disappear_without_invalidating_run(self):
        before = {"status_updates": 1, "chart_preparations": 1, "canvas_draws": 1, "chart_publication_id": "first"}
        after = dict(before, dashboard_visible=False, popover_visible=False)
        _, invalid = app.presentation_checks(before, after, {"ui": "visible"}, {"activity": "ordinary"})
        self.assertTrue(any("dashboard_visible" in item for item in invalid))
        self.assertTrue(any("stopped advancing" in item for item in invalid))

    def test_hidden_rendering_is_reported_without_dropping_remaining_measurements(self):
        before = {"status_updates": 1, "chart_preparations": 1, "canvas_draws": 1}
        after = dict(before, status_updates=3, chart_preparations=5, canvas_draws=2,
                     dashboard_visible=False, popover_visible=False)
        failures, invalid = app.presentation_checks(before, after, {"ui": "closed"}, {"activity": "ordinary"})
        self.assertEqual(len(failures), 2)
        self.assertEqual(invalid, [])

    def test_deadline_bounds_every_wait_and_cannot_be_extended(self):
        clock = mock.Mock(return_value=10)
        deadline = app.Deadline(300, clock)
        self.assertEqual(deadline.remaining(500), 300)
        clock.return_value = 309
        self.assertEqual(deadline.remaining(5), 1)
        clock.return_value = 310
        with self.assertRaises(TimeoutError):
            deadline.remaining()

    def test_baseline_junit_never_looks_green(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "junit.xml"
            app.write_junit({"mode": "baseline", "cases": [], "failures": [], "invalid": []}, path)
            tree = ET.parse(path)
            self.assertEqual(tree.getroot().get("errors"), "1")
            self.assertIsNotNone(tree.find("testcase/error"))

    def test_primary_check_runs_all_cases_when_gpu_capability_is_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "check-new"
            products = {"app": Path("/fake/app"), "collector": Path("/fake/collector"), "tests": Path("/fake/tests")}
            capabilities = {key: {"available": key != "gpu"} for key in
                            ("cpu", "physical_footprint", "physical_writes", "logical_writes", "gpu", "trace_coverage")}
            capabilities["environment"] = {"os": "test", "hardware": "test", "display": "test", "build_configuration": "release"}

            def run_case(case, *_args):
                return {"name": case["name"], "metrics": {}, "failures": [], "invalid": ["GPU unavailable"]}

            with contextlib.ExitStack() as stack:
                stack.enter_context(mock.patch.object(app, "build_products", return_value=(products, {}, {})))
                stack.enter_context(mock.patch.object(app, "preflight", return_value={"capabilities": capabilities, "execution": {"exit_code": 0}}))
                stack.enter_context(mock.patch.object(app, "launch_fixture", return_value=(mock.Mock(), "http://127.0.0.1:123")))
                measured = stack.enter_context(mock.patch.object(app, "run_case", side_effect=run_case))
                stack.enter_context(mock.patch.object(app, "run_chart", return_value={"passed": True}))
                stack.enter_context(mock.patch.object(app, "stop_process_group"))
                stack.enter_context(mock.patch.object(app.platform, "system", return_value="Darwin"))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                code = app.run(["check", "--output-dir", str(output)])
            self.assertEqual(measured.call_count, 4)
            self.assertEqual(code, 1)
            report = app.load_json(output / "report.json")
            self.assertEqual(report["status"], "incomplete")
            self.assertIs(report["regression_passed"], False)

    def test_preflight_timeout_preserves_stderr_and_continues_uncalibrated(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            executable = directory / "collector"

            def launch(command, **options):
                process = mock.Mock()
                if "--preflight" in command:
                    options["stderr"].write(b"calibration diagnostic\n")
                    process.wait.side_effect = subprocess.TimeoutExpired(command, 0.2)
                else:
                    options["stdout"].write(b'{"type":"self_test","passed":true,"cpu":{"available":true}}\n')
                    process.wait.return_value = 0
                return process

            with mock.patch.object(app.subprocess, "Popen", side_effect=launch), mock.patch.object(app, "stop_process_group"):
                result = app.preflight(executable, directory, app.Deadline(5), timeout=0.2)
            self.assertTrue(result["execution"]["timed_out"])
            self.assertEqual(result["execution"]["exit_code"], None)
            self.assertIn("calibration diagnostic", (directory / "preflight-stderr.log").read_text())
            self.assertTrue(any("timed out" in reason for reason in result["invalid"]))
            self.assertTrue(result["capabilities"]["cpu"]["available"])
            self.assertFalse(result["capabilities"]["gpu"]["available"])
            self.assertFalse(result["capabilities"]["gpu"]["live_counter_available"])
            self.assertFalse(result["capabilities"]["gpu"]["full_lifetime_coverage"])
            self.assertTrue(any("GPU full-lifetime coverage" in reason for reason in result["invalid"]))
            self.assertTrue((directory / "preflight-execution.json").exists())
            self.assertTrue((directory / "preflight.json").exists())

    def test_live_gpu_calibration_without_terminal_coverage_is_incomplete_at_preflight(self):
        with tempfile.TemporaryDirectory() as temporary:
            capabilities = {"type": "capabilities", "gpu": {
                "available": True, "live_counter_available": True, "full_lifetime_coverage": False,
                "full_lifetime_unavailable_code": "finalized_terminal_accounting_unsupported",
                "full_lifetime_unavailable_reason": "No validated finalized process-exit accounting"}}
            def launch(command, **options):
                options["stdout"].write(json.dumps(capabilities).encode() + b"\n")
                process = mock.Mock()
                process.wait.return_value = 0
                return process
            with mock.patch.object(app.subprocess, "Popen", side_effect=launch), mock.patch.object(app, "stop_process_group"):
                result = app.preflight(Path("/collector"), Path(temporary), app.Deadline(5))
            self.assertTrue(result["capabilities"]["gpu"]["live_counter_available"])
            self.assertTrue(any("finalized_terminal_accounting_unsupported" in reason for reason in result["invalid"]))
            self.assertTrue(any("process-exit accounting" in reason for reason in result["invalid"]))


class CleanupTests(unittest.TestCase):
    def collector(self, source, seconds=5):
        collector = app.Collector.__new__(app.Collector)
        collector.deadline = app.Deadline(seconds, cleanup_reserve=min(3, seconds / 2))
        collector.samples, collector.events, collector.cleanup_errors = [], [], []
        collector.incoming = queue.Queue()
        collector.exited, collector.app_pid, collector.app_birth_time_us = False, None, None
        collector.raw, collector.stderr = io.BytesIO(), io.BytesIO()
        collector.process = subprocess.Popen([sys.executable, "-u", "-c", source],
                                             stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                             stderr=subprocess.DEVNULL, start_new_session=True)
        collector.reader = threading.Thread(target=collector._read, daemon=True)
        collector.reader.start()
        return collector

    def test_cleanup_preserves_final_sample_and_delayed_exit_after_trace_drain(self):
        final = dict(samples()[-1], phase="final", physical_footprint_bytes=0)
        exited = {"type": "exited", "status": 137, "trace_coverage": False, "final_sample": final}
        source = (f"import time; print({json.dumps(final)!r},flush=True); "
                  f"time.sleep(1.05); print({json.dumps(exited)!r},flush=True)")
        collector = self.collector(source)
        collector.close()
        self.assertTrue(collector.exited)
        self.assertEqual(collector.samples, [final])
        self.assertEqual(collector.events[-1]["status"], 137)
        self.assertEqual(collector.cleanup_errors, [])

    def test_cleanup_applies_records_queued_before_collector_already_exited(self):
        final = dict(samples()[-1], phase="final", physical_footprint_bytes=0)
        exited = {"type": "exited", "status": 0, "trace_coverage": True, "final_sample": final}
        collector = self.collector(f"print({json.dumps(exited)!r},flush=True)")
        collector.process.wait(timeout=3)
        collector.reader.join(timeout=1)
        collector.close()
        self.assertTrue(collector.exited)
        self.assertEqual(collector.samples, [final])

    def test_cleanup_cannot_extend_the_hard_deadline_for_a_stalled_collector(self):
        collector = self.collector("import time; time.sleep(60)", seconds=0.4)
        started = time.monotonic()
        collector.close()
        self.assertLess(time.monotonic() - started, 0.8)
        self.assertIsNotNone(collector.process.poll())
        self.assertFalse(collector.exited)
        self.assertTrue(any("unavailable after bounded cleanup" in error for error in collector.cleanup_errors))


if __name__ == "__main__":
    unittest.main()
