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
from types import SimpleNamespace
import xml.etree.ElementTree as ET

import app_performance as app
from performance_fixture import StreamTiming, TIMING_POLICY


def samples():
    return [{"type": "sample", "process_id": 123, "birth_time_us": 456,
             "monotonic_seconds": index / 4, "cpu_seconds": index / 400,
             "gpu_seconds": index / 4000, "physical_footprint_bytes": 1000000,
             "lifetime_peak_footprint_bytes": 1000000, "physical_write_bytes": 0,
             "logical_write_bytes": 0, "trace_coverage": True,
             "phase": "baseline" if index == 0 else "control_boundary" if index == 1 else "final" if index == 12 else "periodic",
             **({"command_id": "collector-handshake"} if index == 1 else {})}
            for index in range(13)]


def cpu_events(points):
    if not points:
        return []
    events = [{"type": "launched", "pid": points[0]["process_id"], "birth_time_us": points[0]["birth_time_us"]}]
    for point in points:
        events.append(point)
        if point.get("command_id") == "collector-handshake":
            events.append({"type": "app_event", "monotonic_seconds": point["monotonic_seconds"],
                           "event": {"type": "ready", "command_id": "collector-handshake", "protocol_version": 1}})
    events.append({"type": "exited", "status": 0, "final_sample": points[-1]})
    return events


def evaluate_resources(points, limits, intervals, **kwargs):
    return app.evaluate_resources(points, limits, intervals, events=cpu_events(points), **kwargs)


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


class GPUProviderSelectionTests(unittest.TestCase):
    def test_default_never_constructs_detailed_trace(self):
        from performance_gpu_sample import PowermetricsSession
        with tempfile.TemporaryDirectory() as directory, mock.patch(
                "performance_trace.TraceSession", side_effect=AssertionError("Heavy trace selected implicitly")):
            provider = app.make_trace_session(Path(directory), app.Deadline(5))
            self.assertIsInstance(provider, PowermetricsSession)
            self.assertIsNone(provider.process)

    def test_detailed_trace_requires_explicit_selection(self):
        with tempfile.TemporaryDirectory() as directory, mock.patch("performance_trace.TraceSession") as detailed:
            deadline = app.Deadline(5)
            self.assertIs(app.make_trace_session(Path(directory), deadline, "instruments"), detailed.return_value)
            detailed.assert_called_once_with(Path(directory), deadline.end)
        with self.assertRaises(app.InvalidResult):
            app.make_trace_session(Path("unused"), app.Deadline(5), "unknown")


class ResourceGateTests(unittest.TestCase):
    def test_external_gpu_trace_keeps_independent_fs_usage_coverage_required(self):
        points = samples()
        for point in points:
            point.update(gpu_seconds=None, trace_coverage=False)
        metrics, failures, invalid = evaluate_resources(points, budget()["limits"], [], external_trace=True)
        self.assertAlmostEqual(metrics["cpu_rolling_1s_percent"], 1)
        self.assertIsNone(metrics["gpu_percent"])
        self.assertIsNone(metrics["native_gpu_diagnostic_percent"])
        self.assertEqual(failures, [])
        self.assertEqual(invalid, ["Complete filesystem-write trace coverage is unavailable"])

    def test_one_second_cpu_window_preserves_fractional_accounting(self):
        metrics, failures, invalid = evaluate_resources(samples(), budget()["limits"], [])
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
        _, failures, invalid = evaluate_resources(points, budget()["limits"], [])
        self.assertTrue(any("CPU" in failure for failure in failures))
        self.assertEqual(invalid, [])

    def test_memory_limit_is_strictly_below_64_million_bytes(self):
        points = samples()
        for point in points:
            point["lifetime_peak_footprint_bytes"] = 64000000
        _, failures, _ = evaluate_resources(points, budget()["limits"], [])
        self.assertTrue(any("footprint" in failure for failure in failures))

    def test_one_percent_gpu_limit_is_independent_of_cpu(self):
        points = samples()
        for point in points:
            point["gpu_seconds"] = point["monotonic_seconds"] * 0.02
        _, failures, invalid = evaluate_resources(points, budget()["limits"], [])
        self.assertTrue(any("GPU" in failure for failure in failures))
        self.assertEqual(invalid, [])

    def test_cached_gpu_samples_are_not_counted_as_fast_bursts(self):
        points = samples()
        for index, point in enumerate(points):
            point.update(gpu_sampled=index % 4 == 0, gpu_sample_monotonic_seconds=index // 4,
                         gpu_seconds=(index // 4) * 0.005)
        metrics, failures, invalid = evaluate_resources(points, budget()["limits"], [])
        self.assertAlmostEqual(metrics["gpu_percent"], 0.5)
        self.assertEqual(failures, [])
        self.assertEqual(invalid, [])

    def test_missing_gpu_and_trace_never_pass_as_zero(self):
        points = samples()
        points[4].update(gpu_seconds=None, trace_coverage=False)
        _, _, invalid = evaluate_resources(points, budget()["limits"], [])
        self.assertTrue(any("GPU" in error for error in invalid))
        self.assertTrue(any("trace coverage" in error for error in invalid))

    def test_counter_reset_wrong_pid_and_infinite_time_are_invalid(self):
        for changes in ({"cpu_seconds": -1}, {"process_id": 999}, {"monotonic_seconds": float("inf")},
                        {"physical_write_bytes": -1}, {"cpu_seconds": None}):
            with self.subTest(changes=changes):
                points = samples()
                points[4].update(changes)
                self.assertTrue(app.validate_samples(points))

    def test_invalid_memory_keeps_independent_cpu_and_write_failures(self):
        for peak in (999999, None, True):
            with self.subTest(peak=peak):
                points = samples()
                for index, point in enumerate(points):
                    point.update(cpu_seconds=index * 0.025, physical_write_bytes=index, logical_write_bytes=index * 2)
                points[4]["lifetime_peak_footprint_bytes"] = peak
                original = copy.deepcopy(points)
                metrics, failures, invalid = evaluate_resources(points, budget()["limits"], [])
                self.assertIsNone(metrics["lifetime_footprint_bytes"])
                self.assertEqual(metrics["observed_footprint_lower_bound_bytes"], 1000000)
                self.assertAlmostEqual(metrics["cpu_rolling_1s_percent"], 10)
                self.assertAlmostEqual(metrics["gpu_percent"], 0.1)
                self.assertEqual(metrics["physical_write_bytes_logging_off"], 12)
                self.assertEqual(metrics["logical_write_bytes_logging_off"], 24)
                self.assertTrue(any("CPU" in item for item in failures))
                self.assertTrue(any("physical_write" in item for item in failures))
                self.assertTrue(any("logical_write" in item for item in failures))
                self.assertTrue(invalid)
                self.assertEqual(points, original)

    def test_backwards_memory_peak_cannot_pass_or_hide_other_metrics(self):
        points = samples()
        for point in points:
            point["physical_footprint_bytes"] = 500000
        points[4]["lifetime_peak_footprint_bytes"] = 900000
        metrics, _, invalid = evaluate_resources(points, budget()["limits"], [])
        self.assertIsNone(metrics["lifetime_footprint_bytes"])
        self.assertAlmostEqual(metrics["cpu_rolling_1s_percent"], 1)
        self.assertIn("Lifetime footprint peak moved backwards", invalid)

    def test_observed_memory_overrun_fails_without_fabricating_lifetime_peak(self):
        points = samples()
        points[4]["physical_footprint_bytes"] = 64000000
        metrics, failures, invalid = evaluate_resources(points, budget()["limits"], [])
        self.assertIsNone(metrics["lifetime_footprint_bytes"])
        self.assertEqual(metrics["observed_footprint_lower_bound_bytes"], 64000000)
        self.assertTrue(any("Observed physical footprint" in item for item in failures))
        self.assertIn("Lifetime footprint peak is below current footprint", invalid)

    def resolved_memory_samples(self):
        points = samples()
        points[4]["physical_footprint_bytes"] = 1016384
        points[-1].update(phase="final", physical_footprint_bytes=0, lifetime_peak_footprint_bytes=1016384)
        return points, {"type": "exited", "status": 0, "final_sample": copy.deepcopy(points[-1])}

    def test_final_kernel_peak_resolves_only_transient_read_order_skew(self):
        points, exited = self.resolved_memory_samples()
        original = copy.deepcopy(points)
        metrics, failures, invalid = evaluate_resources(points, budget()["limits"], [], final_exit=exited)
        evidence = app.memory_evidence(points, exited)
        self.assertEqual(metrics["lifetime_footprint_bytes"], 1016384)
        self.assertEqual(failures, [])
        self.assertEqual(invalid, [])
        self.assertEqual(evidence["read_order_anomalies"], [{
            "sample_index": 4, "monotonic_seconds": 1.0, "physical_footprint_bytes": 1016384,
            "lifetime_peak_footprint_bytes": 1000000, "difference_bytes": 16384}])
        self.assertEqual(evidence["resolved_by_final_sample"]["source"], "exited.final_sample")
        self.assertEqual(points, original)
        self.assertEqual(exited["final_sample"], original[-1])

    def test_memory_resolution_rejects_missing_spoofed_or_insufficient_final_evidence(self):
        for change in ("missing", "spoofed", "wrong_identity", "wrong_phase", "insufficient", "malformed", "regression", "missing_time", "malformed_time", "boolean_identity"):
            with self.subTest(change=change):
                points, exited = self.resolved_memory_samples()
                if change == "missing":
                    exited = None
                elif change == "spoofed":
                    exited["final_sample"]["lifetime_peak_footprint_bytes"] += 1
                elif change == "wrong_identity":
                    points[-1]["process_id"] = 999
                    exited["final_sample"] = copy.deepcopy(points[-1])
                elif change == "wrong_phase":
                    points[-1]["phase"] = "periodic"
                    exited["final_sample"] = copy.deepcopy(points[-1])
                elif change == "insufficient":
                    points[-1]["lifetime_peak_footprint_bytes"] = 1016383
                    exited["final_sample"] = copy.deepcopy(points[-1])
                elif change == "malformed":
                    points[5]["lifetime_peak_footprint_bytes"] = True
                elif change == "regression":
                    # A skewed record's peak must not be skipped by monotonic validation.
                    points[4]["lifetime_peak_footprint_bytes"] = 1000001
                elif change == "missing_time":
                    points[-1].pop("monotonic_seconds")
                    exited["final_sample"] = copy.deepcopy(points[-1])
                elif change == "malformed_time":
                    points[-1]["monotonic_seconds"] = float("inf")
                    exited["final_sample"] = copy.deepcopy(points[-1])
                elif change == "boolean_identity":
                    points[4]["process_id"] = True
                metrics, _, invalid = evaluate_resources(points, budget()["limits"], [], final_exit=exited)
                self.assertIsNone(metrics.get("lifetime_footprint_bytes"))
                self.assertTrue(invalid)
                self.assertIsNone(app.memory_evidence(points, exited)["resolved_by_final_sample"])

    def test_resolved_final_memory_overrun_and_independent_counter_failures_still_fail(self):
        points, exited = self.resolved_memory_samples()
        points[-1]["lifetime_peak_footprint_bytes"] = 64000000
        for index, point in enumerate(points):
            point.update(cpu_seconds=index * 0.025, physical_write_bytes=index, logical_write_bytes=index * 2)
        exited["final_sample"] = copy.deepcopy(points[-1])
        metrics, failures, invalid = evaluate_resources(points, budget()["limits"], [], final_exit=exited)
        self.assertEqual(metrics["lifetime_footprint_bytes"], 64000000)
        self.assertTrue(any("Lifetime physical footprint" in item for item in failures))
        self.assertTrue(any("CPU" in item for item in failures))
        self.assertTrue(any("physical_write" in item for item in failures))
        self.assertTrue(any("logical_write" in item for item in failures))
        self.assertEqual(invalid, [])

    def test_single_bad_counter_suppresses_only_its_metric(self):
        mapping = {"cpu_seconds": "cpu_rolling_1s_percent", "gpu_seconds": "gpu_percent",
                   "physical_write_bytes": "physical_write_bytes_logging_off",
                   "logical_write_bytes": "logical_write_bytes_logging_off"}
        for counter, metric in mapping.items():
            for value in (None, 0, float("inf"), True):
                with self.subTest(counter=counter, value=value):
                    points = samples()
                    for index, point in enumerate(points):
                        point.update(physical_write_bytes=7 + index, logical_write_bytes=9 + index)
                    points[4][counter] = value
                    metrics, failures, invalid = evaluate_resources(points, budget()["limits"], [])
                    self.assertIsNone(metrics[metric])
                    self.assertEqual(metrics["lifetime_footprint_bytes"], 1000000)
                    for other in set(mapping.values()) - {metric}:
                        self.assertIsNotNone(metrics[other])
                    self.assertTrue(any("write_bytes" in item for item in failures))
                    self.assertTrue(invalid)

    def test_identity_time_and_sample_gap_faults_still_suppress_all_metrics(self):
        for changes in ({"process_id": 999}, {"birth_time_us": 0}, {"monotonic_seconds": float("inf")},
                        {"monotonic_seconds": 0.75}, {"monotonic_seconds": 5}):
            with self.subTest(changes=changes):
                points = samples()
                points[4].update(changes)
                metrics, failures, invalid = evaluate_resources(points, budget()["limits"], [])
                self.assertEqual(metrics, {})
                self.assertEqual(failures, [])
                self.assertTrue(invalid)

    def test_bad_gpu_timestamp_keeps_other_metrics_and_cannot_smooth_into_a_pass(self):
        points = samples()
        points[4]["gpu_sample_monotonic_seconds"] = float("nan")
        metrics, _, invalid = evaluate_resources(points, budget()["limits"], [])
        self.assertIsNone(metrics["gpu_percent"])
        self.assertAlmostEqual(metrics["cpu_rolling_1s_percent"], 1)
        self.assertEqual(metrics["physical_write_bytes_logging_off"], 0)
        self.assertIn("GPU sample timestamp is unavailable", invalid)

    def test_initial_and_off_interval_writes_are_counted(self):
        points = samples()
        for index, point in enumerate(points):
            point["logical_write_bytes"] = 7 + (20 if index >= 6 else 0)
        metrics, failures, _ = evaluate_resources(points, budget()["limits"], [])
        self.assertEqual(metrics["logical_write_bytes_logging_off"], 27)
        self.assertTrue(any("logical_write" in failure for failure in failures))

    def test_exact_verified_on_interval_does_not_exempt_other_periods(self):
        points = samples()
        for index, point in enumerate(points):
            point["physical_write_bytes"] = (20 if index >= 6 else 0) + (5 if index >= 10 else 0)
        metrics, _, _ = evaluate_resources(points, budget()["limits"], [(1, 2)])
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


class StartupCPUAccountingTests(unittest.TestCase):
    def points(self, function, ready=1.0, end=3.0, times=None):
        times = times or sorted({index / 4 for index in range(round(end * 4) + 1)} | {ready, end})
        result = []
        for index, timestamp in enumerate(times):
            point = dict(samples()[0], monotonic_seconds=timestamp, cpu_seconds=round(function(timestamp), 12),
                         phase="baseline" if index == 0 else "final" if index == len(times) - 1 else
                         "control_boundary" if timestamp == ready else "periodic")
            if timestamp == ready:
                point["command_id"] = "collector-handshake"
            result.append(point)
        return result

    def test_startup_fifty_percent_and_operational_five_percent_are_separate(self):
        points = self.points(lambda t: min(t, 1) * .5 + max(0, t - 1) * .04)
        evidence = app.cpu_accounting(points, cpu_events(points), budget()["limits"])
        self.assertEqual(evidence["invalid"], [])
        self.assertEqual(evidence["failures"], [])
        self.assertAlmostEqual(evidence["metrics"]["cpu_startup_rolling_1s_percent"], 50)
        self.assertAlmostEqual(evidence["metrics"]["cpu_rolling_1s_percent"], 4)
        self.assertAlmostEqual(evidence["metrics"]["cpu_lifetime_rolling_1s_percent"], 50)
        points = self.points(lambda t: min(t, 1) * .501)
        self.assertTrue(any("Startup" in item for item in app.cpu_accounting(points, cpu_events(points), budget()["limits"])["failures"]))

    def test_exact_operational_threshold_passes_and_next_measurable_increment_fails(self):
        for rate, failed in ((.05, False), (.050000001, True)):
            with self.subTest(rate=rate):
                points = self.points(lambda t: max(t - 1, 0) * rate)
                evidence = app.cpu_accounting(points, cpu_events(points), budget()["limits"])
                self.assertAlmostEqual(evidence["metrics"]["cpu_rolling_1s_percent"], rate * 100, places=8)
                self.assertEqual(bool(evidence["failures"]), failed)

    def test_short_startup_uses_half_cpu_second_allowance_including_initial_count(self):
        for cpu, failed in ((.5, False), (.500001, True)):
            with self.subTest(cpu=cpu):
                points = self.points(lambda t: .1 + min(t / .5, 1) * (cpu - .1), ready=.5)
                evidence = app.cpu_accounting(points, cpu_events(points), budget()["limits"])
                self.assertEqual(evidence["startup"]["elapsed_seconds"], .5)
                self.assertAlmostEqual(evidence["startup"]["cpu_seconds"], cpu)
                self.assertEqual(bool(evidence["failures"]), failed)
                self.assertEqual(evidence["metrics"]["cpu_rolling_1s_percent"], 0)

    def test_ready_crossing_work_is_conserved_and_post_ready_burst_cannot_hide(self):
        for operational, failed in ((.04, False), (.051, True)):
            with self.subTest(operational=operational):
                points = self.points(lambda t: min(t / .5, 1) * .4 + min(max(t - .5, 0) / .25, 1) * operational, ready=.5)
                evidence = app.cpu_accounting(points, cpu_events(points), budget()["limits"])
                self.assertEqual(evidence["invalid"], [])
                self.assertAlmostEqual(evidence["startup"]["cpu_seconds"] + evidence["operational"]["cpu_seconds"], points[-1]["cpu_seconds"])
                self.assertAlmostEqual(evidence["operational"]["rolling_1s_percent"], operational * 100)
                self.assertEqual(bool(evidence["failures"]), failed)

    def test_late_ui_stage_is_operational_and_does_not_restart_startup(self):
        points = self.points(lambda t: .1 * min(t, 1) + .06 * min(max(t - 2, 0) / .25, 1))
        ready = app.authenticated_cpu_ready(points, cpu_events(points))
        stage = {"before": {"runner_collector_sample_monotonic_seconds": 2.0},
                 "after": {"runner_collector_sample_monotonic_seconds": 2.5}}
        evidence = app.operational_stage_cpu(points, stage, ready, budget()["limits"])
        self.assertEqual(evidence["phase"], "operational")
        self.assertEqual(evidence["limit_percent"], 5)
        self.assertAlmostEqual(evidence["rolling_1s_percent"], 6)
        self.assertFalse(evidence["within_limit"])
        self.assertTrue(any("Operational" in item for item in app.cpu_accounting(points, cpu_events(points), budget()["limits"])["failures"]))

    def test_missing_or_pre_ready_stage_marker_invalidates_the_case(self):
        points = self.points(lambda t: t * .01)
        ready = app.authenticated_cpu_ready(points, cpu_events(points))
        for start in (None, .75):
            with self.subTest(start=start):
                stage = {"before": {"runner_collector_sample_monotonic_seconds": start},
                         "after": {"runner_collector_sample_monotonic_seconds": 2.5}}
                case = {"stages": [stage], "invalid": []}
                app.record_operational_stage_cpu(case, points, ready, budget()["limits"])
                self.assertTrue(stage["cpu_accounting"]["invalid"])
                self.assertTrue(any("Operational CPU stage-0" in reason for reason in case["invalid"]))

    def test_shifted_sample_breakpoint_is_included_in_exact_rolling_maximum(self):
        times = [0, .25, .5, .75, 1, 1.3, 1.6, 1.8, 2.1, 2.4, 2.7, 3]
        values = [0, 0, 0, 0, 0, 0, .03, .07, .10, .115, .115, .115]
        points = self.points(lambda t: values[times.index(t)], times=times)
        evidence = app.cpu_accounting(points, cpu_events(points), budget()["limits"])
        self.assertAlmostEqual(evidence["metrics"]["cpu_rolling_1s_percent"], 11)
        self.assertLess(app.rolling_percent(points, "cpu_seconds"), 11)

    def test_missing_duplicate_or_spoofed_ready_never_grants_startup_allowance(self):
        for fault in ("missing", "duplicate", "duplicate_boundary", "wrong_launch", "wrong_ready", "wrong_protocol", "wrong_boundary", "reordered", "missing_final"):
            with self.subTest(fault=fault):
                points = self.points(lambda t: t * .01)
                events = copy.deepcopy(cpu_events(points))
                ready = next(event for event in events if event.get("type") == "app_event")
                if fault == "missing":
                    events.remove(ready)
                elif fault == "duplicate":
                    events.append(copy.deepcopy(ready))
                elif fault == "duplicate_boundary":
                    events.append(copy.deepcopy(events[events.index(ready) - 1]))
                elif fault == "wrong_launch":
                    events[0]["pid"] = 999
                elif fault == "wrong_ready":
                    ready["event"]["process_id"] = 999
                elif fault == "wrong_protocol":
                    ready["event"]["protocol_version"] = True
                elif fault == "wrong_boundary":
                    events[events.index(ready) - 1]["birth_time_us"] = 999
                elif fault == "reordered":
                    events.insert(events.index(ready), {"type": "diagnostic"})
                elif fault == "missing_final":
                    events.pop()
                evidence = app.cpu_accounting(points, events, budget()["limits"])
                self.assertTrue(evidence["invalid"])
                self.assertIsNone(evidence["metrics"]["cpu_rolling_1s_percent"])
                self.assertIsNotNone(evidence["metrics"]["cpu_lifetime_rolling_1s_percent"])

    def test_absent_cpu_boundary_keeps_other_resource_metrics_available(self):
        points = self.points(lambda t: t * .01)
        metrics, failures, invalid = app.evaluate_resources(points, budget()["limits"], [], events=[])
        self.assertIsNone(metrics["cpu_rolling_1s_percent"])
        self.assertEqual(metrics["lifetime_footprint_bytes"], 1000000)
        self.assertEqual(metrics["logical_write_bytes_logging_off"], 0)
        self.assertTrue(any("ready event" in item for item in invalid))


class CPUWorkCounterDiagnosticTests(unittest.TestCase):
    QOS = ("default", "maintenance", "background", "utility", "legacy", "user_initiated", "user_interactive")

    def points(self, *, idle=False):
        result = samples()
        for index, point in enumerate(result):
            if idle:
                point["cpu_seconds"] = 0
            if index in (4, 8):
                point.update(phase="control_boundary", command_id="work-before" if index == 4 else "work-after")
            point["cpu_work_counters"] = {
                "schema_version": 1, "source": "proc_pid_rusage/RUSAGE_INFO_V4",
                "instructions": 1000 + index * 101, "cycles": 2000 + index * 73,
                "instructions_unit": "count", "cycles_unit": "count",
                "qos_time_unit": "unspecified_kernel_units",
                "qos_time_raw": {name: index * 37 if name == "default" else 0 for name in self.QOS},
            }
        return result

    def diagnostic(self, points, *, events=None, start=1.0, end=2.0):
        return app.cpu_work_counter_diagnostic(points, cpu_events(points) if events is None else events, start, end)

    def assert_invalid(self, result):
        self.assertFalse(result["available"])
        self.assertEqual(result["status"], "invalid_diagnostic")
        self.assertFalse(result["gate_evaluated"])
        self.assertIsInstance(result["errors"], list)
        self.assertTrue(result["errors"])

    def test_exact_control_boundaries_and_nondefault_zero_qos_buckets_are_valid(self):
        result = self.diagnostic(self.points())
        self.assertTrue(result["available"])
        self.assertEqual(result["status"], "available")
        self.assertEqual(result["errors"], [])
        self.assertFalse(result["gate_evaluated"])
        self.assertEqual(result["hardware_counter_status"], "available")
        self.assertEqual(result["qos_counter_status"], "available")
        self.assertEqual(result["deltas"], {"instructions": 404, "cycles": 292,
            "qos_time_raw": {name: 148 if name == "default" else 0 for name in self.QOS}})
        self.assertAlmostEqual(result["instructions_per_cycle"], 404 / 292)
        self.assertEqual(result["qos_time_unit"], "unspecified_kernel_units")

    def test_deltas_larger_than_double_integer_precision_remain_exact(self):
        points = self.points()
        for index, point in enumerate(points):
            value = point["cpu_work_counters"]
            value["instructions"] = 7 + index * ((1 << 53) + 1)
            value["cycles"] = 11 + index * ((1 << 53) + 3)
            value["qos_time_raw"]["default"] = 13 + index * ((1 << 53) + 5)
        result = self.diagnostic(points)
        self.assertTrue(result["available"])
        self.assertEqual(result["deltas"]["instructions"], 4 * ((1 << 53) + 1))
        self.assertEqual(result["deltas"]["cycles"], 4 * ((1 << 53) + 3))
        self.assertEqual(result["deltas"]["qos_time_raw"]["default"], 4 * ((1 << 53) + 5))
        self.assertIs(type(result["deltas"]["instructions"]), int)
        self.assertIs(type(result["deltas"]["cycles"]), int)

    def test_uint64_maximum_is_accepted_without_float_rounding(self):
        points = self.points()
        for index, point in enumerate(points):
            point["cpu_work_counters"]["instructions"] = (1 << 64) - 1 - (12 - index) * 17
        result = self.diagnostic(points)
        self.assertTrue(result["available"])
        self.assertEqual(result["deltas"]["instructions"], 68)

    def test_idle_zero_deltas_require_positive_cumulative_support_evidence(self):
        points = self.points(idle=True)
        for point in points:
            value = point["cpu_work_counters"]
            value.update(instructions=101, cycles=73,
                         qos_time_raw={name: 37 if name == "default" else 0 for name in self.QOS})
        result = self.diagnostic(points)
        self.assertTrue(result["available"])
        self.assertEqual(result["status"], "available")
        self.assertEqual(result["deltas"], {"instructions": 0, "cycles": 0, "qos_time_raw": dict.fromkeys(self.QOS, 0)})
        self.assertIsNone(result["instructions_per_cycle"])

    def test_entirely_zero_idle_run_is_unavailable_not_verified_zero(self):
        points = self.points(idle=True)
        for point in points:
            point["cpu_work_counters"].update(instructions=0, cycles=0, qos_time_raw=dict.fromkeys(self.QOS, 0))
        result = self.diagnostic(points)
        self.assertFalse(result["available"])
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(result["hardware_counter_status"], "unavailable")
        self.assertEqual(result["qos_counter_status"], "unavailable")
        self.assertEqual(result["deltas"], {"instructions": 0, "cycles": 0, "qos_time_raw": dict.fromkeys(self.QOS, 0)})
        self.assertIsNone(result["instructions_per_cycle"])

    def test_idle_hardware_and_qos_support_are_independent(self):
        for unsupported in ("hardware", "qos"):
            points = self.points(idle=True)
            for point in points:
                value = point["cpu_work_counters"]
                value.update(instructions=0 if unsupported == "hardware" else 101,
                             cycles=0 if unsupported == "hardware" else 73,
                             qos_time_raw={name: 37 if name == "default" and unsupported != "qos" else 0 for name in self.QOS})
            result = self.diagnostic(points)
            with self.subTest(unsupported=unsupported):
                self.assertFalse(result["available"])
                self.assertEqual(result["status"], "unavailable")
                self.assertEqual(result["hardware_counter_status"], "unavailable" if unsupported == "hardware" else "available")
                self.assertEqual(result["qos_counter_status"], "unavailable" if unsupported == "qos" else "available")

    def test_active_cpu_requires_both_positive_hardware_deltas(self):
        for field in ("instructions", "cycles"):
            points = self.points()
            for point in points:
                point["cpu_work_counters"][field] = 99
            result = self.diagnostic(points)
            with self.subTest(field=field):
                self.assertFalse(result["available"])
                self.assertEqual(result["status"], "unavailable")
                self.assertEqual(result["hardware_counter_status"], "unavailable")
                self.assertEqual(result["qos_counter_status"], "available")
                self.assertEqual(result["deltas"][field], 0)
                self.assertIsNone(result["instructions_per_cycle"])
                self.assertFalse(result["gate_evaluated"])

    def test_active_cpu_with_zero_qos_preserves_hardware_deltas(self):
        points = self.points()
        for point in points:
            point["cpu_work_counters"]["qos_time_raw"] = dict.fromkeys(self.QOS, 0)
        result = self.diagnostic(points)
        self.assertFalse(result["available"])
        self.assertEqual(result["status"], "unavailable")
        self.assertEqual(result["hardware_counter_status"], "available")
        self.assertEqual(result["qos_counter_status"], "unavailable")
        self.assertEqual(result["deltas"]["instructions"], 404)
        self.assertEqual(result["deltas"]["cycles"], 292)
        self.assertEqual(result["deltas"]["qos_time_raw"], dict.fromkeys(self.QOS, 0))
        self.assertAlmostEqual(result["instructions_per_cycle"], 404 / 292)

    def test_legacy_samples_with_no_group_are_unavailable(self):
        points = self.points()
        for point in points:
            del point["cpu_work_counters"]
        result = self.diagnostic(points)
        self.assertFalse(result["available"])
        self.assertEqual(result["status"], "unavailable")
        self.assertFalse(result["gate_evaluated"])
        self.assertIsInstance(result["errors"], list)

    def test_mixed_absent_null_or_partial_groups_are_invalid_not_legacy(self):
        for fault in ("absent", "null", "partial", "all-null", "extra-key"):
            points = self.points()
            if fault == "absent":
                del points[5]["cpu_work_counters"]
            elif fault == "null":
                points[5]["cpu_work_counters"] = None
            elif fault == "partial":
                del points[5]["cpu_work_counters"]["cycles"]
            elif fault == "all-null":
                for point in points:
                    point["cpu_work_counters"] = None
            else:
                points[5]["cpu_work_counters"]["unknown"] = 0
            with self.subTest(fault=fault):
                self.assert_invalid(self.diagnostic(points))

    def test_counter_types_ranges_and_qos_shape_are_strict(self):
        for field in ("instructions", "cycles", "default"):
            for invalid in (True, -1, 1 << 64, 1.0, "1", None):
                points = self.points()
                target = points[5]["cpu_work_counters"]
                if field == "default":
                    target = target["qos_time_raw"]
                target[field] = invalid
                with self.subTest(field=field, invalid=invalid):
                    self.assert_invalid(self.diagnostic(points))
        for qos in (None, [], {"default": 1}, dict.fromkeys(self.QOS + ("unknown",), 1)):
            points = self.points()
            points[5]["cpu_work_counters"]["qos_time_raw"] = qos
            with self.subTest(qos=qos):
                self.assert_invalid(self.diagnostic(points))

    def test_schema_source_and_units_are_not_inferred(self):
        faults = (("schema_version", True), ("schema_version", 2), ("source", "getrusage"),
                  ("instructions_unit", "nanoseconds"), ("cycles_unit", "GHz"),
                  ("qos_time_unit", "nanoseconds"))
        for field, invalid in faults:
            points = self.points()
            points[5]["cpu_work_counters"][field] = invalid
            with self.subTest(field=field, invalid=invalid):
                self.assert_invalid(self.diagnostic(points))

    def test_decreasing_counters_inside_or_outside_selected_window_are_invalid(self):
        for index in (6, 12):
            for field in ("instructions", "cycles", "default"):
                points = self.points()
                previous = points[index - 1]["cpu_work_counters"]
                target = points[index]["cpu_work_counters"]
                if field == "default":
                    previous, target = previous["qos_time_raw"], target["qos_time_raw"]
                target[field] = previous[field] - 1
                with self.subTest(index=index, field=field):
                    self.assert_invalid(self.diagnostic(points))

    def test_final_sample_is_an_exact_allowed_end_boundary(self):
        result = self.diagnostic(self.points(), end=3.0)
        self.assertTrue(result["available"])
        self.assertEqual(result["deltas"]["instructions"], 808)
        self.assertEqual(result["deltas"]["cycles"], 584)

    def test_interpolated_periodic_pre_ready_and_reversed_boundaries_are_invalid(self):
        for start, end in ((1.125, 2), (1, 2.125), (.5, 2), (1, 1.5), (0, 2), (2, 1), (1, 1),
                           (10**400, 2), (1, 10**400), (float("nan"), 2), (1, float("inf"))):
            with self.subTest(start=start, end=end):
                self.assert_invalid(self.diagnostic(self.points(), start=start, end=end))

    def test_missing_duplicate_or_wrong_process_authentication_is_invalid(self):
        faults = ("no-ready", "duplicate-ready", "wrong-launch", "wrong-birth", "no-final", "failed-exit",
                  "wrong-final", "duplicate-boundary", "missing-boundary", "wrong-boundary-phase")
        for fault in faults:
            points = self.points()
            if fault == "wrong-birth":
                points[5]["birth_time_us"] = 999
            if fault == "wrong-boundary-phase":
                points[4]["phase"] = "periodic"
            events = copy.deepcopy(cpu_events(points))
            ready = next(event for event in events if event.get("type") == "app_event")
            if fault == "no-ready":
                events.remove(ready)
            elif fault == "duplicate-ready":
                events.append(copy.deepcopy(ready))
            elif fault == "wrong-launch":
                events[0]["pid"] = 999
            elif fault == "no-final":
                events.pop()
            elif fault == "failed-exit":
                events[-1]["status"] = 137
            elif fault == "wrong-final":
                events[-1]["final_sample"]["cpu_seconds"] += 1
            elif fault == "duplicate-boundary":
                events.append(copy.deepcopy(points[4]))
            elif fault == "missing-boundary":
                events.remove(points[4])
            with self.subTest(fault=fault):
                self.assert_invalid(self.diagnostic(points, events=events))

    def test_bad_optional_group_never_changes_resource_gate_results(self):
        points = self.points()
        expected = evaluate_resources(points, budget()["limits"], [])
        for invalid in (None, {}, {"instructions": True}):
            broken = copy.deepcopy(points)
            broken[5]["cpu_work_counters"] = invalid
            self.assert_invalid(self.diagnostic(broken))
            self.assertEqual(evaluate_resources(broken, budget()["limits"], []), expected)


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

    def test_popover_readiness_and_one_show_failures_preserve_actual_diagnostics_and_continue(self):
        for phase, reason in (("popover_readiness", "Popover native anchor did not become ready"),
                              ("popover_visibility", "Popover did not become visible")):
            with self.subTest(phase=phase):
                before = {"app_active": False, "anchor_window_visible": False, "ready": False}
                final = dict(before, app_active=True)
                collector = mock.Mock()
                collector.command.side_effect = [
                    {"command": "show_dashboard", "status": "ok"},
                    {"command": "show_popover", "status": "error", "reason": reason,
                     "ui_failure_phase": phase, "popover_readiness_before_show": before, "popover_readiness": final}]
                invalid = []
                app.visible(collector, True, invalid)
                self.assertEqual(collector.command.call_args_list, [mock.call("show_dashboard"), mock.call("show_popover")])
                self.assertEqual(len(invalid), 1)
                self.assertTrue(invalid[0].startswith("UI lifecycle coverage is incomplete: " + reason))
                recorded = json.loads(invalid[0].split("; diagnostics: ", 1)[1])
                self.assertEqual(recorded, {"ui_failure_phase": phase,
                                           "popover_readiness_before_show": before, "popover_readiness": final})

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
                       lambda value: value["limits"].update(cpu_startup_rolling_1s_percent=51),
                       lambda value: value["limits"].update(cpu_startup_short_allowance_seconds=0.6),
                       lambda value: value.pop("cpu_policy"),
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
                hashes = {key: {"path": str(path), "sha256": "a" * 64} for key, path in products.items()}
                resolver = stack.enter_context(mock.patch.object(app, "resolve_products", return_value=(products, hashes, {}, {"kind": "current"})))
                stack.enter_context(mock.patch.object(app, "path_hash", return_value="a" * 64))
                trace = mock.Mock()
                trace.start.return_value = {"provider": "test"}
                trace.calibrate.return_value = {"pending_trace_export": True}
                trace.finish.return_value = {"valid": False, "invalid": ["No capture"], "windows": {}, "final_exit_coverage": {}}
                stack.enter_context(mock.patch.object(app, "make_trace_session", return_value=trace))
                stack.enter_context(mock.patch.object(app, "preflight", return_value={"capabilities": capabilities, "execution": {"exit_code": 0}}))
                stack.enter_context(mock.patch.object(app, "launch_fixture", return_value=(mock.Mock(), "http://127.0.0.1:123")))
                measured = stack.enter_context(mock.patch.object(app, "run_case", side_effect=run_case))
                stack.enter_context(mock.patch.object(app, "run_chart", return_value={"passed": True}))
                stack.enter_context(mock.patch.object(app, "stop_process_group"))
                stack.enter_context(mock.patch.object(app.platform, "system", return_value="Darwin"))
                stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                code = app.run(["check", "--output-dir", str(output)])
            self.assertEqual(measured.call_count, 4)
            trace.start.assert_called_once()
            trace.calibrate.assert_called_once_with(products["collector"])
            trace.finish.assert_called_once()
            self.assertEqual(code, 1)
            report = app.load_json(output / "report.json")
            self.assertEqual(report["status"], "incomplete")
            self.assertIs(report["regression_passed"], False)
            self.assertEqual(resolver.call_args.args[2], report["measurement_identity"]["sha256"])

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


class SharedTraceTests(unittest.TestCase):
    def report(self):
        case = {"name": "fresh-never-opened", "metrics": {}, "failures": [], "invalid": [], "stages": [],
                "process_id": 123, "birth_time_us": 456, "launch_monotonic_seconds": 10,
                "end_monotonic_seconds": 13, "trace_windows": {"lifetime": "fresh-never-opened/lifetime"}}
        return {"cases": [case], "invalid": [], "budget": budget()}

    def result(self):
        name = "fresh-never-opened/lifetime"
        return {"valid": True, "invalid": [], "provider": "test", "calibration": {"valid": True},
                "windows": {name: {"process_id": 123, "birth_time_us": 456,
                                   "start_monotonic_seconds": 10, "end_monotonic_seconds": 13,
                                   "coverage_complete": True, "invalid": [], "attribution_exact": True,
                                   **{metric + suffix: 0 for metric in app.GPU_BOUND_METRICS
                                      for suffix in ("_lower_bound", "_upper_bound")}}},
                "final_exit_coverage": {name: {"complete": True}}}

    def apply(self, report, result):
        app.apply_trace_results(report, result)

    def test_empty_owned_window_is_zero_only_with_calibration_and_complete_capture(self):
        report, result = self.report(), self.result()
        self.apply(report, result)
        self.assertEqual(report["cases"][0]["metrics"]["gpu_percent"], 0)
        self.assertEqual(report["cases"][0]["invalid"], [])
        for change in (lambda value: value.update(valid=False),
                       lambda value: value["calibration"].update(valid=False),
                       lambda value: value["windows"]["fresh-never-opened/lifetime"].update(coverage_complete=False),
                       lambda value: value["windows"].clear()):
            with self.subTest(change=change):
                report, result = self.report(), self.result()
                change(result)
                self.apply(report, result)
                self.assertIsNone(report["cases"][0]["metrics"]["gpu_percent"])
                self.assertTrue(report["cases"][0]["invalid"])

    def test_native_filesystem_failure_does_not_erase_independent_gpu_measurements(self):
        report, result = self.report(), self.result()
        report["invalid"].append("Required fs_usage filesystem coverage is unavailable: authorization missing")
        report["cases"][0]["invalid"].append("Final filesystem-write trace coverage was not complete through exit and drain")
        self.apply(report, result)
        self.assertEqual(report["cases"][0]["metrics"]["gpu_percent"], 0)
        self.assertTrue(any("filesystem" in item for item in report["cases"][0]["invalid"]))
        self.assertTrue(report["invalid"])
        self.assertEqual(report["cases"][0]["filesystem_trace"]["provider"], "fs_usage")

    def test_workload_gpu_can_be_valid_while_exit_coverage_remains_incomplete(self):
        report, result = self.report(), self.result()
        result["final_exit_coverage"] = {}
        self.apply(report, result)
        self.assertEqual(report["cases"][0]["metrics"]["gpu_percent"], 0)
        self.assertTrue(any("process-exit" in item for item in report["cases"][0]["invalid"]))

    def test_trace_process_identity_endpoint_and_gpu_limit_are_enforced(self):
        for change in ({"process_id": 999}, {"end_monotonic_seconds": 12}, {"gpu_rolling_1s_percent_upper_bound": None}, {"gpu_percent_lower_bound": 1}):
            with self.subTest(change=change):
                report, result = self.report(), self.result()
                result["windows"]["fresh-never-opened/lifetime"].update(change)
                self.apply(report, result)
                self.assertIsNone(report["cases"][0]["metrics"]["gpu_percent"])
                self.assertTrue(report["cases"][0]["invalid"])
        report, result = self.report(), self.result()
        result["windows"]["fresh-never-opened/lifetime"]["gpu_rolling_1s_percent_upper_bound"] = 1.001
        self.apply(report, result)
        self.assertTrue(report["cases"][0]["failures"])

    def test_unresolved_execution_uses_positive_upper_bound_instead_of_exact_zero(self):
        report, result = self.report(), self.result()
        window = result["windows"]["fresh-never-opened/lifetime"]
        window.update(attribution_exact=False, gpu_execution_seconds=None,
                      gpu_rolling_1s_percent=None, gpu_percent=None,
                      gpu_execution_seconds_upper_bound=0.00005,
                      gpu_rolling_1s_percent_upper_bound=0.005, gpu_percent_upper_bound=0.002)
        self.apply(report, result)
        case = report["cases"][0]
        self.assertEqual(case["metrics"]["gpu_percent"], 0.005)
        self.assertEqual(case["metrics"]["gpu_percent_lower_bound"], 0)
        self.assertEqual(case["gpu_bounds"]["gpu_execution_seconds"], {"lower_bound": 0, "upper_bound": 0.00005})
        self.assertIn("upper bound", case["gpu_metric_semantics"]["gpu_percent"])
        self.assertEqual(case["invalid"], [])

    def test_one_incomplete_window_does_not_hide_another_cases_gpu_bounds(self):
        report, result = self.report(), self.result()
        other = copy.deepcopy(report["cases"][0])
        other.update(name="other", trace_windows={"lifetime": "other/lifetime"})
        report["cases"].append(other)
        result["windows"]["other/lifetime"] = dict(result["windows"]["fresh-never-opened/lifetime"],
                                                  coverage_complete=False, invalid=["Missing owned process"])
        self.apply(report, result)
        self.assertEqual(report["cases"][0]["metrics"]["gpu_percent"], 0)
        self.assertEqual(report["cases"][0]["invalid"], [])
        self.assertIsNone(other["metrics"]["gpu_percent"])
        self.assertTrue(other["invalid"])

    def test_collector_clock_is_normalized_for_trace_and_logging_boundaries(self):
        points = samples()
        for point in points:
            offset = point["monotonic_seconds"]
            point.update(monotonic_seconds=1000 + offset, mach_absolute_seconds=100 + offset,
                         clock_read_uncertainty_seconds=0.00001)
        points[-1]["phase"] = "final"
        case = {"name": "case", "samples": points, "events": [{"type": "exited", "status": 0}],
                "logging_intervals": [[1001, 1002]], "trace_drain_end_monotonic_seconds": 14,
                "stages": [{"measurement_start_monotonic_seconds": 10.3, "measurement_end_monotonic_seconds": 12.8}],
                "workload_validated": True}
        trace = mock.Mock()
        trace.monotonic_from_mach_seconds.side_effect = lambda value: value - 90
        app.register_case_trace(trace, case)
        trace.register_process.assert_called_once_with(123, 456, 10)
        trace.register_exit.assert_called_once_with(123, 456, 13, 14, 0)
        self.assertEqual(case["trace_logging_intervals"], [[11, 12]])
        self.assertEqual(case["logging_intervals"], [[1001, 1002]])
        self.assertEqual(case["launch_monotonic_seconds"], 10)
        trace.add_window.assert_any_call("case/lifetime", 123, 456, 10, 13)
        points[0].pop("mach_absolute_seconds")
        with self.assertRaises(app.InvalidResult):
            app.register_case_trace(trace, case)

    def test_final_logging_off_comparison_excludes_delayed_disable_drain_tail(self):
        points = []
        for index in range(121):
            point = dict(samples()[0], monotonic_seconds=1000 + index / 4, mach_absolute_seconds=100 + index / 4,
                         cpu_seconds=index / 400, gpu_seconds=index / 4000, clock_read_uncertainty_seconds=0.00001)
            points.append(point)
        points[-1]["phase"] = "final"
        case = {"name": "logging-transitions", "samples": points, "events": [{"type": "exited", "status": 0}],
                "logging_supported": True, "logging_intervals": [[1010, 1020.5]], "trace_drain_end_monotonic_seconds": 41,
                "workload_validated": True, "stages": [
                    {"measurement_start_monotonic_seconds": 10 + index * 10, "measurement_end_monotonic_seconds": 20 + index * 10}
                    for index in range(3)]}
        case["stages"][2].update(comparison_scope="logging-off", verified_off_start_collector_seconds=1020.5)
        trace = mock.Mock()
        trace.monotonic_from_mach_seconds.side_effect = lambda value: value - 90
        app.register_case_trace(trace, case)
        trace.add_window.assert_any_call("logging-transitions/stage-2", 123, 456, 30, 40)
        trace.add_window.assert_any_call("logging-transitions/off-stage-2", 123, 456, 30.5, 40)


class BaselineProductTests(unittest.TestCase):
    def products(self, root):
        paths = {"app": root / "app", "collector": root / "collector", "tests": root / "tests.xctest"}
        for key in ("app", "collector"):
            paths[key].write_bytes(key.encode())
            paths[key].chmod(0o755)
        paths["tests"].mkdir()
        (paths["tests"] / "test-binary").write_bytes(b"tests")
        value = {"schema_version": 1, "kind": "reconstructed-pre-optimization", "build_configuration": "release",
                 "production_commit": "a" * 40, "instrumentation_sha256": "b" * 64, "adapter_sha256": "c" * 64,
                 "fixture_schema_version": 2, "logging_supported": False, "history_preparation": {"kind": "in-app"},
                 "popover_lifecycle_policy": app.POPOVER_LIFECYCLE_POLICY,
                 "binary_sha256": {key: app.path_hash(paths[key]) for key in ("app", "tests")}}
        provenance = root / "provenance.json"
        app.write_json(provenance, value)
        return paths, provenance

    def test_explicit_baseline_products_are_hashed_and_never_built_implicitly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths, provenance = self.products(root)
            args = SimpleNamespace(app_binary=paths["app"], test_bundle=paths["tests"], collector_binary=paths["collector"],
                                   provenance=provenance, mode="baseline", build_timeout=5)
            with mock.patch.object(app, "build_products") as build:
                resolved, hashes, build_result, identity = app.resolve_products(args, root, "b" * 64)
            build.assert_not_called()
            self.assertEqual(resolved, {key: path.resolve() for key, path in paths.items()})
            self.assertEqual(hashes["app"]["sha256"], app.path_hash(paths["app"]))
            self.assertEqual(identity["kind"], "reconstructed-pre-optimization")
            self.assertEqual(build_result["status"], "explicit-prebuilt-products")
            with self.assertRaises(app.InvalidResult):
                app.validated_provenance(provenance, paths, "check", "b" * 64)
            paths["app"].write_bytes(b"different")
            with self.assertRaises(app.InvalidResult):
                app.validated_provenance(provenance, paths, "baseline", "b" * 64)

    def test_explicit_provenance_rejects_a_different_common_instrumentation_hash(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths, provenance = self.products(root)
            with self.assertRaisesRegex(app.InvalidResult, "pinned measurement sources"):
                app.validated_provenance(provenance, paths, "baseline", "d" * 64)
            # Variant adapter hashes remain independent of the common instrumentation.
            value = app.load_json(provenance)
            value["adapter_sha256"] = "e" * 64
            app.write_json(provenance, value)
            validated = app.validated_provenance(provenance, paths, "baseline", "b" * 64)
            self.assertEqual(validated["adapter_sha256"], "e" * 64)
            value.pop("popover_lifecycle_policy")
            app.write_json(provenance, value)
            with self.assertRaisesRegex(app.InvalidResult, "Binary provenance.*popover lifecycle policy"):
                app.validated_provenance(provenance, paths, "baseline", "b" * 64)

    def test_comparison_requires_identical_valid_collector_binary_hash(self):
        report = {"environment": {"os": "test", "hardware": "test", "display": "test", "build_configuration": "release"},
                  "measurement_identity": {"sha256": "a" * 64}, "budget": budget(),
                  "binary_identity": {"collector": {"sha256": "b" * 64}, "app": {"sha256": "c" * 64}},
                  "production_provenance": {"adapter_sha256": "d" * 64, "popover_lifecycle_policy": app.POPOVER_LIFECYCLE_POLICY}}
        reference = app.comparison_key(report)
        self.assertEqual(reference["popover_lifecycle_policy"], app.POPOVER_LIFECYCLE_POLICY)
        self.assertEqual(reference["cpu_policy"], app.CPU_POLICY)
        report["budget"].pop("cpu_policy")
        self.assertIsNone(app.comparison_key(report))
        report["budget"]["cpu_policy"] = app.CPU_POLICY
        for value in (None, "transient"):
            report["production_provenance"]["popover_lifecycle_policy"] = value
            self.assertIsNone(app.comparison_key(report))
        report["production_provenance"]["popover_lifecycle_policy"] = app.POPOVER_LIFECYCLE_POLICY
        report["binary_identity"]["app"]["sha256"] = "e" * 64
        report["production_provenance"]["adapter_sha256"] = "f" * 64
        self.assertEqual(app.comparison_key(report), reference)
        report["binary_identity"]["collector"]["sha256"] = "1" * 64
        self.assertNotEqual(app.comparison_key(report), reference)
        for missing in (None, "", "invalid"):
            report["binary_identity"]["collector"]["sha256"] = missing
            self.assertIsNone(app.comparison_key(report))

    def test_legacy_seeding_uses_the_exact_app_fixture_epoch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            helper = root / "helper"
            helper.write_bytes(b"helper")
            provenance = {"history_preparation": {"kind": "legacy-files", "executable": str(helper), "sha256": app.path_hash(helper)}}
            configuration = {"history": "populated", "upstream_url": "http://127.0.0.1:123", "fixture_ending_at_epoch": 1234.567}
            with mock.patch.object(app, "execute_logged", return_value={"exit_code": 0}) as execute:
                app.prepare_history(configuration, root / "UUID", provenance, root, app.Deadline(5))
            command = execute.call_args.args[0]
            self.assertEqual(command[-2:], ["--ending-at-epoch", "1234.567"])
            self.assertIn("ollama|http://127.0.0.1:123|", command)

    def test_shared_measurement_identity_excludes_variant_app_adapters(self):
        identity = app.measurement_identity()
        self.assertTrue(any("performance_trace.py" in name for name in identity["sources"]))
        self.assertFalse(any(name.startswith("Sources/FluxLLM/Performance/") for name in identity["sources"]))
        self.assertTrue(any("PerformanceHistoryFixture.swift" in name for name in app.adapter_identity()["sources"]))

    def test_original_logging_absence_never_fabricates_toggles_or_skips_traffic(self):
        specification = budget()["cases"][3]
        expected = app.expected_work({"activity": "ordinary", "seconds": 30})
        acknowledgement, status = fixture_evidence({"activity": "ordinary", "seconds": 30})
        clock, calls = [100.0], [0]
        collector = mock.Mock()
        collector.wait_until.side_effect = lambda end: clock.__setitem__(0, end)
        def snapshot():
            calls[0] += 1
            return {**({key: 0 for key in expected} if clock[0] < 130 else expected),
                    "active_requests": 2 if clock[0] < 130 else 0, "partial_output_tokens": calls[0]}
        collector.snapshot.side_effect = snapshot
        case = {"logging_supported": False, "stages": [], "failures": [], "invalid": []}
        with mock.patch.object(app.time, "monotonic", side_effect=lambda: clock[0]), \
                mock.patch.object(app, "fixture_request", return_value=acknowledgement), \
                mock.patch.object(app, "completed_status", return_value=status), \
                mock.patch.object(app, "presentation_checks", return_value=([], [])):
            app.run_continuous_logging(collector, specification, case, "http://127.0.0.1:123", "http://127.0.0.1:456", app.Deadline(50), 0)
        collector.command.assert_not_called()
        self.assertEqual(case["stages"][-1]["validated_work"], expected)
        self.assertEqual([stage["comparison_scope"] for stage in case["stages"]], ["logging-off", "not-applicable", "logging-off"])

    def test_baseline_comparison_requires_equivalent_fixtures_and_compares_only_logging_off(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline_directory = root / "baseline-original"
            baseline_directory.mkdir()
            environment = {"os": "test", "hardware": "test", "display": "test", "build_configuration": "release"}
            cases = [{"name": item["name"], "workload_validated": True, "logging_supported": True,
                      "ready": {"fixture_equivalence_sha256": "e" * 64, "popover_lifecycle_policy": app.POPOVER_LIFECYCLE_POLICY,
                                "snapshot": {"popover_lifecycle_policy": app.POPOVER_LIFECYCLE_POLICY}},
                      "invalid": [], "metrics": {"gpu_percent": 0.2},
                      "gpu_bounds": {metric: {"lower_bound": 0.1, "upper_bound": 0.2} for metric in app.GPU_BOUND_METRICS},
                      "stages": [{"off_gpu_trace": {"coverage_complete": True,
                                                     **{metric + suffix: value for metric in app.GPU_BOUND_METRICS
                                                        for suffix, value in (("_lower_bound", 0.1), ("_upper_bound", 0.2))},
                                                     "start_monotonic_seconds": 10, "end_monotonic_seconds": 20}} for _ in range(3)]}
                     for item in budget()["cases"]]
            current = {"mode": "check", "artifact_directory": str(root / "check-current"), "cases": cases,
                       "environment": environment, "measurement_identity": {"sha256": "d" * 64}, "budget": budget(),
                       "trace": {"provider": "test"}, "preflight": {"capabilities": {}},
                       "binary_identity": {"collector": {"sha256": "c" * 64}},
                       "production_provenance": {"popover_lifecycle_policy": app.POPOVER_LIFECYCLE_POLICY}}
            baseline = copy.deepcopy(current)
            baseline.update(mode="baseline", artifact_directory=str(baseline_directory))
            baseline["cases"][0]["ready"]["fixture_equivalence_sha256"] = "f" * 64
            baseline["cases"][3]["logging_supported"] = False
            for stage in baseline["cases"][3]["stages"]:
                stage["off_gpu_trace"].update(gpu_percent_lower_bound=0.3, gpu_percent_upper_bound=0.4)
            app.write_json(baseline_directory / "report.json", baseline)
            comparison = app.compare_baseline(current, root)
            self.assertIn("populated-closed", comparison["excluded"])
            self.assertNotIn("logging-transitions", comparison["metric_deltas"])
            self.assertEqual(set(comparison["logging_off_gpu_delta_bounds"]["logging-transitions"]), {"stage-0", "stage-2"})
            change = comparison["logging_off_gpu_delta_bounds"]["logging-transitions"]["stage-0"]["gpu_percent"]
            self.assertAlmostEqual(change["lower_bound"], -0.3)
            self.assertAlmostEqual(change["upper_bound"], -0.1)
            self.assertNotIn("gpu_percent", comparison["metric_deltas"]["fresh-never-opened"])
            self.assertEqual(comparison["gpu_delta_bounds"]["fresh-never-opened"]["gpu_percent"],
                             {"lower_bound": -0.1, "upper_bound": 0.1})
            baseline["cases"][2]["ready"]["snapshot"].pop("popover_lifecycle_policy")
            app.write_json(baseline_directory / "report.json", baseline)
            changed = app.compare_baseline(current, root)
            self.assertIn("popover lifecycle policy", changed["excluded"]["fresh-never-opened"])
            self.assertNotIn("fresh-never-opened", changed["metric_deltas"])


class PopoverPolicyTests(unittest.TestCase):
    def test_policy_requires_the_exact_version_for_ready_snapshots_and_provenance(self):
        self.assertEqual(app.POPOVER_LIFECYCLE_POLICY, "explicit-performance-commands-v2")
        app.validate_popover_policy({"popover_lifecycle_policy": app.POPOVER_LIFECYCLE_POLICY}, "test")
        for value in (None, {}, {"popover_lifecycle_policy": "transient"},
                      {"popover_lifecycle_policy": "explicit-performance-commands-v1"}, {"popover_lifecycle_policy": True}):
            with self.subTest(value=value), self.assertRaisesRegex(app.InvalidResult, "popover lifecycle policy"):
                app.validate_popover_policy(value, "test")

    def test_snapshot_rejects_policy_drift_even_when_counters_are_present(self):
        collector = app.Collector.__new__(app.Collector)
        collector.command = mock.Mock(return_value={"snapshot": {"requests": 5}})
        with self.assertRaisesRegex(app.InvalidResult, "popover lifecycle policy"):
            collector.snapshot()
        expected = {"requests": 5, "popover_lifecycle_policy": app.POPOVER_LIFECYCLE_POLICY}
        collector.command.return_value = {"snapshot": expected}
        self.assertEqual(collector.snapshot(), expected)

    def test_command_acknowledgments_reject_snapshot_policy_drift(self):
        collector = app.Collector.__new__(app.Collector)
        collector.deadline = app.Deadline(5)
        collector.next_id, collector.samples, collector.exited = 0, [], False
        collector.process = SimpleNamespace(stdin=io.BytesIO())
        response = {"type": "ack", "command_id": "runner-1", "snapshot": {"requests": 1}}
        collector.receive = mock.Mock(return_value={"type": "app_event", "event": response})
        with self.assertRaisesRegex(app.InvalidResult, "acknowledgment snapshot.*popover lifecycle policy"):
            collector.command("show_popover")

    def test_ready_rejects_a_mismatched_nested_snapshot(self):
        collector = app.Collector.__new__(app.Collector)
        collector.deadline = app.Deadline(5)
        collector.exited = False
        ready = {"type": "ready", "popover_lifecycle_policy": app.POPOVER_LIFECYCLE_POLICY,
                 "snapshot": {"popover_lifecycle_policy": "transient"}}
        collector.receive = mock.Mock(return_value={"type": "app_event", "event": ready})
        with self.assertRaisesRegex(app.InvalidResult, "App ready snapshot"):
            collector.ready()
        ready["snapshot"]["popover_lifecycle_policy"] = app.POPOVER_LIFECYCLE_POLICY
        self.assertEqual(collector.ready(), ready)


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
