"""Validate exported GPU trace parsing and accounting without running GPU work.

Run: python3 -m unittest discover -s scripts -p 'test_performance_trace.py' -v
"""

import copy
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape, quoteattr

import performance_trace as trace


SCHEMA = "metal-gpu-intervals"
NS = 1_000_000_000
COLUMNS = {
    "start": "start-time",
    "duration": "duration",
    "state": "gpu-state",
    "process": "process",
    "gpu": "metal-device-name",
    "channel-name": "gpu-channel-name",
    "gpu-submission-id": "uint64",
    "cmdbuffer-id": "metal-command-buffer-id",
    "encoder-id": "metal-command-buffer-id",
}


def cell(text="", *, fmt=None, pid=None, identifier=None):
    return {"text": str(text), "fmt": str(text) if fmt is None else fmt,
            "pid": pid, "id": identifier}


def row(start=0, duration=100, *, pid=123, gpu="Test GPU", channel="Compute",
        state="Active", submission="17", command="19", encoder="23"):
    return {
        "start": cell(start), "duration": cell(duration), "state": cell(state),
        "process": cell("", fmt="FluxLLMApp (123)", pid=pid),
        "gpu": cell(gpu), "channel-name": cell(channel),
        "gpu-submission-id": cell(submission), "cmdbuffer-id": cell(command),
        "encoder-id": cell(encoder),
    }


def table(*rows):
    return {"schema": SCHEMA, "columns": dict(COLUMNS), "rows": list(rows), "invalid": []}


def interval(start, end, *, pid=123, gpu="Test GPU", channel="Compute", submission="17"):
    return {"start_ns": start, "end_ns": end, "pid": pid, "gpu": gpu,
            "channel": channel, "submission_id": submission,
            "command_buffer_id": "19", "encoder_id": "23"}


def exported_xml(rows, *, columns=None, attributes="", schema=SCHEMA):
    """The same schema/row layout as xctrace, with tiny synthetic values."""
    columns = COLUMNS if columns is None else columns
    metadata = "".join(
        f"<col><mnemonic>{escape(name)}</mnemonic><name>{escape(name)}</name>"
        f"<engineering-type>{escape(kind)}</engineering-type></col>"
        for name, kind in columns.items())
    return ("<?xml version='1.0'?><trace-query-result><node xpath='/trace-toc/run/data/table'>"
            f"<schema name={quoteattr(schema)} {attributes}>{metadata}</schema>"
            + "".join(f"<row>{content}</row>" for content in rows)
            + "</node></trace-query-result>")


def exported_row(*, start="0", duration="100", process=None, state="Active"):
    process = ("<process id='p1' fmt='FluxLLMApp (999)'><pid id='pid1'>123</pid>"
               "<device-session>session</device-session></process>"
               if process is None else process)
    return (f"<start-time>{escape(start)}</start-time><duration>{escape(duration)}</duration>"
            f"<gpu-state>{escape(state)}</gpu-state>{process}"
            "<metal-device-name>Test GPU</metal-device-name><gpu-channel-name>Compute</gpu-channel-name>"
            "<uint64>17</uint64><metal-command-buffer-id>19</metal-command-buffer-id>"
            "<metal-command-buffer-id>23</metal-command-buffer-id>")


class TracePhaseBudgetTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.now = 100.0
        self.clock = patch.object(trace.time, "monotonic", side_effect=lambda: self.now)
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.budgets = dict(record=180, finalize=290, toc=300, export=355, evaluate=390)

    def session(self, **kwargs):
        return trace.TraceSession(self.directory.name, 400, **kwargs)

    def ready_session(self):
        session = self.session(phase_deadlines=self.budgets, record_limit_seconds=80)
        session._begin_phase("record")
        session.process = Mock(returncode=None)
        session.process.poll.side_effect = lambda: session.process.returncode
        session.sentinel = Mock()
        session.log = (session.output / "record.log").open("w")

        def wait(**kwargs):
            session.process.returncode = 0
            return 0

        session.process.wait.side_effect = wait
        return session

    def test_default_budget_remains_overall_deadline(self):
        session = self.session()
        self.assertEqual(session._remaining(), 300)
        self.assertEqual(session._phase_deadline("evaluate"), 400)
        with session._phase("finalize"):
            self.assertEqual(session._remaining(), 300)
        self.assertEqual(session.phases["finalize"]["status"], "complete")

    def test_invalid_phase_budgets_rejected_before_artifact_directory_creation(self):
        for budgets in ({"unknown": 200}, {"record": 300, "finalize": 200},
                        {"evaluate": 401}, {"record": float("nan")}, {"record": True}):
            with self.subTest(budgets=budgets), self.assertRaises(trace.TraceError):
                self.session(phase_deadlines=budgets)
        self.assertFalse((Path(self.directory.name) / "system-trace").exists())

    def test_expired_phase_does_not_execute_body_or_consume_next_budget(self):
        session = self.session(phase_deadlines=self.budgets)
        self.now = 300
        body = Mock()
        with self.assertRaisesRegex(trace.TraceError, "trace toc"):
            with session._phase("toc"):
                body()
        body.assert_not_called()
        self.assertEqual(session.phases["toc"]["status"], "deadline_exceeded")
        self.assertEqual(session._phase_deadline("export"), 355)

    def test_readiness_and_record_guard_use_record_deadline(self):
        session = self.session(phase_deadlines={"record": 108}, record_limit_seconds=80)
        notice, sentinel, process = Mock(name="notice"), Mock(), Mock()
        notice.name = "fake-notice"
        notice.ready.return_value = True
        sentinel.process.pid = 123
        sentinel.birth = 456
        process.poll.return_value = None
        with patch.object(trace, "_mach_clock", return_value={}), \
                patch.object(trace.subprocess, "check_output", return_value="/Xcode/a/b/c/xctrace"), \
                patch.object(Path, "is_file", return_value=True), \
                patch.object(trace, "_Notice", return_value=notice), \
                patch.object(trace, "_Sentinel", return_value=sentinel), \
                patch.object(trace.subprocess, "Popen", return_value=process) as popen:
            session.start()
        command = popen.call_args.args[0]
        self.assertEqual(command[command.index("--time-limit") + 1], "8s")
        self.assertEqual(session.phases["record"]["deadline_monotonic_seconds"], 108)
        session.log.close()

    def test_startup_failure_records_phase_and_closes_owned_handles(self):
        session = self.session(phase_deadlines=self.budgets)
        with patch.object(trace, "_mach_clock", side_effect=trace.TraceError("clock unavailable")):
            with self.assertRaisesRegex(trace.TraceError, "clock unavailable"):
                session.start()
        self.assertEqual(session.phases["record"]["status"], "failed")
        result = session.finish()
        self.assertFalse(result["valid"])
        self.assertEqual(result["phases"]["cleanup"]["status"], "complete")

    def test_finish_uses_separate_absolute_deadlines_and_records_phases(self):
        session = self.ready_session()
        self.now = 150
        timeouts = []

        def wait(**kwargs):
            timeouts.append(("finalize", kwargs["timeout"]))
            self.now = 280
            session.process.returncode = 0
            return 0

        def export(command, **kwargs):
            toc = "--toc" in command
            timeouts.append(("toc" if toc else "export", kwargs["timeout"]))
            destination = Path(command[command.index("--output") + 1])
            destination.write_text("<trace-toc>" + "".join(
                f'<table schema="{schema}"/>' for schema in trace.CORE_SCHEMAS) + "</trace-toc>")
            self.now = 295 if toc else 350
            return Mock(returncode=0)

        def evaluate(toc, result):
            timeouts.append(("evaluate", session._remaining()))
            self.now = 385

        session.process.wait.side_effect = wait
        with patch.object(trace, "read_run_issues", return_value={"lost_events": False, "invalid": []}), \
                patch.object(trace, "_mach_clock", return_value={}), \
                patch.object(trace.subprocess, "run", side_effect=export), \
                patch.object(trace, "export_schema_index"), \
                patch.object(session, "_evaluate", side_effect=evaluate):
            result = session.finish()
        self.assertTrue(result["valid"], result["invalid"])
        self.assertEqual(timeouts, [("finalize", 140), ("toc", 20), ("export", 60), ("evaluate", 40)])
        self.assertEqual(set(result["phases"]), {*self.budgets, "cleanup"})
        self.assertTrue(all(phase["status"] == "complete" for phase in result["phases"].values()))
        self.assertEqual(result["phases"]["cleanup"]["deadline_monotonic_seconds"], 400)
        session.sentinel.close.assert_called_once()
        session.process.kill.assert_not_called()
        self.assertEqual(json.loads((session.output / "trace-report.json").read_text()), result)

    def test_finalize_timeout_stops_pipeline_and_cleans_up_with_global_budget(self):
        session = self.ready_session()
        self.now = 150

        def wait(**kwargs):
            if session.process.wait.call_count == 1:
                self.now = 290
                raise trace.subprocess.TimeoutExpired("xctrace record", kwargs["timeout"])
            session.process.returncode = -9
            return -9

        session.process.wait.side_effect = wait
        with patch.object(session, "_run_export") as export:
            result = session.finish()
        self.assertFalse(result["valid"])
        self.assertFalse(result["recording_complete"])
        self.assertEqual(result["phases"]["finalize"]["status"], "deadline_exceeded")
        self.assertEqual(result["phases"]["cleanup"]["status"], "complete")
        self.assertEqual(session.process.wait.call_args_list[-1].kwargs["timeout"], .5)
        export.assert_not_called()
        session.process.kill.assert_called_once()
        session.sentinel.close.assert_called_once()
        self.assertTrue(session.log.closed)
        self.assertTrue((session.output / "trace-report.json").is_file())

    def test_record_deadline_overrun_invalidates_result(self):
        session = self.ready_session()
        self.now = 181
        with patch.object(trace, "read_run_issues", side_effect=trace.TraceError("fixture stop")):
            result = session.finish()
        self.assertIn("GPU recording exceeded its phase deadline", result["invalid"])
        self.assertEqual(result["phases"]["record"]["status"], "deadline_exceeded")
        self.assertFalse(result["valid"])

    def test_toc_timeout_preserves_partial_artifacts_and_stops_later_phases(self):
        session = self.ready_session()
        self.now = 150

        def export(command, **kwargs):
            session.toc.write_text("partial TOC")
            self.now = 300
            raise trace.subprocess.TimeoutExpired(command, kwargs["timeout"])

        with patch.object(trace, "read_run_issues", return_value={"lost_events": False, "invalid": []}), \
                patch.object(trace, "_mach_clock", return_value={}), \
                patch.object(trace.subprocess, "run", side_effect=export), \
                patch.object(session, "_evaluate") as evaluate:
            result = session.finish()
        self.assertFalse(result["valid"])
        self.assertTrue(result["recording_complete"])
        self.assertEqual(result["phases"]["toc"]["status"], "deadline_exceeded")
        self.assertNotIn("export", result["phases"])
        self.assertEqual(session.toc.read_text(), "partial TOC")
        self.assertTrue((session.output / "export-toc.log").is_file())
        evaluate.assert_not_called()
        session.sentinel.close.assert_called_once()

    def test_cleanup_failure_still_closes_remaining_owned_handles(self):
        session = self.ready_session()
        session.process.wait.side_effect = trace.subprocess.TimeoutExpired("xctrace record", 140)
        session.process.kill.side_effect = OSError("owned recorder cleanup failed")
        result = session.finish()
        self.assertFalse(result["valid"])
        self.assertEqual(result["phases"]["cleanup"]["status"], "failed")
        self.assertTrue(session.log.closed)
        session.sentinel.close.assert_called_once()
        self.assertTrue((session.output / "trace-report.json").is_file())

    def test_calibration_inherits_record_deadline(self):
        session = self.session(phase_deadlines={"record": 103})
        session._begin_phase("record")
        workers = [Mock(pid=1, birth=11), Mock(pid=2, birth=22)]
        for worker in workers:
            worker.reply.return_value = {"gpu_seconds": .1}
            worker.close.return_value = {"final_sample_monotonic_seconds": 100, "status": 0}
        with patch.object(trace, "_Worker", side_effect=workers) as worker_type, \
                patch.object(trace.time, "sleep"):
            result = session.calibrate("collector")
        self.assertTrue(result["pending_trace_export"])
        self.assertEqual([call.args[1] for call in worker_type.call_args_list], [103, 103])
        for worker in workers:
            worker.close.assert_called_once()

    def test_calibration_cleanup_failure_does_not_skip_second_owned_worker(self):
        session = self.session(phase_deadlines=self.budgets)
        session._begin_phase("record")
        workers = [Mock(pid=1, birth=11), Mock(pid=2, birth=22)]
        for worker in workers:
            worker.reply.return_value = {"gpu_seconds": .1}
            worker.close.return_value = {"final_sample_monotonic_seconds": 100, "status": 0}
        workers[0].close.side_effect = trace.TraceError("helper identity changed")
        with patch.object(trace, "_Worker", side_effect=workers), patch.object(trace.time, "sleep"):
            session.calibrate("collector")
        for worker in workers:
            worker.close.assert_called_once()
        self.assertNotIn(1, session.exits)
        self.assertEqual(session.exits[2]["status"], 0)
        self.assertEqual(session.invalid, ["GPU trace calibration helper 1 cleanup: helper identity changed"])
        artifact = json.loads((session.output / "calibration-references.json").read_text())
        self.assertEqual(artifact["invalid"], session.invalid)
        self.assertEqual(artifact["exits"]["2"], session.exits[2])

    def test_evaluation_and_execution_coverage_honor_earlier_phase_deadline(self):
        session = self.session(phase_deadlines=self.budgets)
        self.now = 391
        with patch.object(trace, "read_table") as read:
            with self.assertRaisesRegex(TimeoutError, "deadline"):
                session._evaluate(ET.fromstring("<trace-toc/>"), {})
        read.assert_not_called()
        with self.assertRaisesRegex(TimeoutError, "deadline"):
            session._execution_coverage(TraceCoverageTests.points((100, 17, 1)), {"intervals": []}, 0, 1)


class TraceCoverageTests(unittest.TestCase):
    def setUp(self):
        self.session = object.__new__(trace.TraceSession)
        self.session.processes = {123: {"birth_time_us": 12345}}

    @staticmethod
    def points(*values):
        return {"rows": [{"timestamp": cell(timestamp), "gpu-submission-id": cell(submission),
                          "channel-id": cell(9), "function": cell(function)}
                         for timestamp, submission, function in values]}

    def test_missing_owned_modeled_interval_is_not_valid_zero(self):
        parsed = {"intervals": []}
        result = self.session._execution_coverage(
            self.points((100, 17, 1), (200, 17, 2)), parsed, 0, 1, {17: {123}})
        self.assertEqual(result["invalid"], [])
        self.assertEqual(result["process_issues"][0]["pid"], 123)
        self.assertEqual(result["process_issues"][0]["message"], "An owned raw GPU execution pair is missing its modeled interval")

    def test_complete_owned_pair_matches_model(self):
        parsed = {"intervals": [interval(100, 200, submission=17)]}
        result = self.session._execution_coverage(
            self.points((100, 17, 1), (200, 17, 2)), parsed, 0, 1, {17: {123}})
        self.assertEqual(result["invalid"], [])
        self.assertEqual(result["completed_submission_ids"], [17])

    def test_unknown_raw_pair_preserves_ambiguous_time_window(self):
        result = self.session._execution_coverage(
            self.points((100, 17, 1), (200, 17, 2)), {"intervals": []}, 0, 1, {})
        self.assertEqual(result["unattributed_pairs"], [(100, 200)])

    def test_owned_missing_end_is_incomplete(self):
        result = self.session._execution_coverage(
            self.points((100, 17, 1)), {"intervals": []}, 0, 1, {17: {123}})
        self.assertEqual(result["invalid"], [])
        self.assertEqual(result["process_issues"][0]["pid"], 123)
        self.assertEqual(result["process_issues"][0]["message"], "An owned GPU submission has a missing execution boundary")

    def test_missing_owned_pair_does_not_invalidate_other_registered_pid(self):
        self.session.processes[456] = {"birth_time_us": 45678}
        result = self.session._execution_coverage(
            self.points((100, 17, 1)), {"intervals": []}, 0, 1, {17: {123}})
        self.assertEqual(result["invalid"], [])
        self.assertEqual({issue["pid"] for issue in result["process_issues"]}, {123})

    def test_unrelated_complete_pair_does_not_poison_owned_window(self):
        result = self.session._execution_coverage(
            self.points((100, 17, 1), (200, 17, 2)), {"intervals": []}, 0, 1, {17: {999}})
        self.assertEqual(result["invalid"], [])
        self.assertEqual(result["unattributed_pairs"], [])

    def test_mach_anchor_maps_to_runner_monotonic_without_wall_time(self):
        self.session.clock_start = {"absolute_minus_monotonic_seconds": 100.125}
        self.assertAlmostEqual(self.session.monotonic_from_mach_seconds(102.375), 2.25)
        with self.assertRaises(ValueError):
            self.session.monotonic_from_mach_seconds(float("nan"))

    def test_reused_submission_number_does_not_override_exact_modeled_process(self):
        result = self.session._execution_coverage(
            self.points((100, 17, 1), (200, 17, 2)),
            {"intervals": [interval(100, 200, submission=17)]}, 0, 1, {17: {123, 999}})
        self.assertEqual(result["process_issues"], [])
        self.assertEqual(result["completed_modeled_identities"], [(123, 17, "19", "23")])

    def test_anonymous_modeled_complete_execution_can_be_bounded(self):
        result = self.session._execution_coverage(
            self.points((100, 17, 1), (200, 17, 2)),
            {"intervals": [], "unattributed": [interval(100, 200, submission=17, pid=None)]}, 0, 1, {})
        self.assertEqual(result["unattributed_pairs"], [])
        self.assertEqual(result["invalid"], [])

    def test_unknown_missing_boundary_cannot_be_bounded(self):
        result = self.session._execution_coverage(
            self.points((100, 17, 1)), {"intervals": []}, 0, 1, {})
        self.assertEqual(result["unattributed_pairs"], [(100, NS)])

    def test_zero_owner_mixed_with_known_owners_keeps_missing_execution_globally_unavailable(self):
        self.session.processes[456] = {"birth_time_us": 45678}
        for owners in ({0, 999}, {0, 123}):
            for points, expected in ((self.points((100, 17, 1), (200, 17, 2)), (100, 200)),
                                     (self.points((100, 17, 1)), (100, NS))):
                with self.subTest(owners=owners, expected=expected):
                    result = self.session._execution_coverage(points, {"intervals": []}, 0, 1, {17: owners})
                    self.assertIn(expected, result["unattributed_pairs"])

    def test_anonymous_modeled_execution_missing_both_raw_boundaries_is_invalid(self):
        result = self.session._execution_coverage(
            self.points(), {"intervals": [], "unattributed": [interval(100, 200, submission=17, pid=None)]}, 0, 1, {})
        self.assertEqual(result["unattributed_pairs"], [(100, 200)])

    def test_missing_raw_channel_cannot_hide_behind_an_identical_other_channel(self):
        result = self.session._execution_coverage(self.points((100, 17, 1), (200, 17, 2)),
            {"intervals": [interval(100, 200, submission=17), interval(100, 200, submission=17, channel="Vertex")]}, 0, 1, {17: {123}})
        self.assertTrue(result["process_issues"])

    def test_unknown_function_is_not_ignored(self):
        result = self.session._execution_coverage(
            self.points((100, 17, 99)), {"intervals": []}, 0, 1, {})
        self.assertTrue(result["invalid"])

    def test_completed_submission_of_other_pid_does_not_complete_owned_identity(self):
        result = self.session._execution_coverage(
            self.points((100, 17, 1), (200, 17, 2)),
            {"intervals": [interval(100, 200, submission=17, pid=999)]}, 0, 1, {17: {123, 999}})
        self.assertEqual(result["completed_modeled_identities"], [])


class BoundedAttributionTests(unittest.TestCase):
    def test_unknown_execution_can_cross_limit_even_when_known_work_passes(self):
        result = trace.bounded_interval_metrics([interval(0, 6_000_000)],
            [interval(10_000_000, 16_000_000, pid=None)], 123, 0, NS)
        self.assertEqual(result["gpu_rolling_1s_percent_lower_bound"], .6)
        self.assertEqual(result["gpu_rolling_1s_percent_upper_bound"], 1.2)
        self.assertFalse(result["attribution_exact"])
        self.assertIsNone(result["gpu_rolling_1s_percent"])

    def test_concurrent_unresolved_execution_remains_additive(self):
        result = trace.bounded_interval_metrics([interval(0, 6_000_000)],
            [interval(0, 6_000_000, pid=None, channel="Vertex")], 123, 0, NS)
        self.assertEqual(result["gpu_rolling_1s_percent_upper_bound"], 1.2)
        self.assertEqual(result["gpu_busy_union_seconds_upper_bound"], .006)

    def test_known_zero_with_unknown_work_is_not_reported_as_exact_zero(self):
        result = trace.bounded_interval_metrics([], [interval(0, 5_000, pid=None)], 123, 0, NS)
        self.assertEqual(result["gpu_execution_seconds_lower_bound"], 0)
        self.assertGreater(result["gpu_execution_seconds_upper_bound"], 0)
        self.assertIsNone(result["gpu_execution_seconds"])
        self.assertIsNone(result["gpu_percent"])

    def test_known_unrelated_process_is_excluded_from_both_bounds(self):
        result = trace.bounded_interval_metrics([interval(0, NS, pid=999)], [], 123, 0, NS)
        self.assertTrue(result["attribution_exact"])
        self.assertEqual(result["gpu_rolling_1s_percent_upper_bound"], 0)

    def test_unknown_work_outside_window_does_not_make_attribution_inexact(self):
        result = trace.bounded_interval_metrics([], [interval(NS, 2 * NS, pid=None)], 123, 0, NS)
        self.assertTrue(result["attribution_exact"])
        self.assertEqual(result["gpu_execution_seconds"], 0)

    def test_rolling_upper_bound_finds_peak_across_shifted_window(self):
        result = trace.bounded_interval_metrics([interval(900_000_000, 906_000_000)],
            [interval(1_100_000_000, 1_106_000_000, pid=None)], 123, 0, 2 * NS)
        self.assertEqual(result["gpu_rolling_1s_percent_upper_bound"], 1.2)


class SubmissionOwnershipTests(unittest.TestCase):
    @staticmethod
    def submission(pid, sid, command, encoder):
        return {"pid": cell(pid), "gpu-submission-id": cell(sid),
                "cmdbuffer-id": cell(command), "encoder-id": cell(encoder),
                "commit-id": cell(0), "submission-type": cell(0)}

    def test_modeled_command_encoder_cannot_resolve_a_raw_sid_with_multiple_process_owners(self):
        parsed = trace.parse_gpu_intervals(table(row(pid=123, submission=17, command=19, encoder=23)))
        result = trace.reconcile_submission_ownership(parsed, [
            self.submission(999, 17, 111, 222), self.submission(123, 17, 19, 23)])
        self.assertEqual(result["conflicts"], [])
        self.assertEqual(result["intervals"], [])
        self.assertEqual(len(result["unresolved"]), 1)
        self.assertIsNone(result["unresolved"][0]["pid"])
        self.assertEqual(result["unresolved"][0]["candidate_pids"], [123, 999])

    def test_alias_join_copies_preserve_one_physical_interval_and_no_false_lower_bound(self):
        parsed = trace.parse_gpu_intervals(table(
            row(start=100, duration=200, pid=123, submission=17, command=19, encoder=23),
            row(start=100, duration=200, pid=999, submission=17, command=111, encoder=222),
            row(start=100, duration=200, pid=None, submission=17, command=19, encoder=23)))
        result = trace.reconcile_submission_ownership(parsed, [
            self.submission(123, 17, 19, 23), self.submission(999, 17, 111, 222)])
        self.assertEqual(result["intervals"], [])
        self.assertEqual(len(result["unresolved"]), 1)
        self.assertEqual(len(result["physical_intervals"]), 1)
        for pid in (123, 999):
            metrics = trace.bounded_interval_metrics(result["intervals"], result["unresolved"], pid, 0, NS)
            self.assertEqual(metrics["gpu_execution_seconds_lower_bound"], 0)
            self.assertEqual(metrics["gpu_execution_seconds_upper_bound"], 200 / NS)

    def test_candidate_owner_bounds_exclude_other_processes_but_unknown_owners_remain_global(self):
        known_candidates = {**interval(0, 5_000_000, pid=None), "candidate_pids": [123, 999]}
        unknown = {**interval(5_000_000, 7_000_000, pid=None), "candidate_pids": None}
        exact = trace.bounded_interval_metrics([], [known_candidates], 456, 0, NS)
        self.assertTrue(exact["attribution_exact"])
        self.assertEqual(exact["gpu_execution_seconds"], 0)
        bounded = trace.bounded_interval_metrics([], [known_candidates, unknown], 456, 0, NS)
        self.assertFalse(bounded["attribution_exact"])
        self.assertEqual(bounded["gpu_execution_seconds_upper_bound"], .002)
        owned = trace.bounded_interval_metrics([], [known_candidates, unknown], 123, 0, NS)
        self.assertEqual(owned["gpu_execution_seconds_upper_bound"], .007)

    def test_distinct_physical_channels_or_time_ranges_remain_additive_under_aliases(self):
        parsed = trace.parse_gpu_intervals(table(row(start=0, duration=5_000_000, channel="Compute"),
            row(start=0, duration=5_000_000, channel="Fragment"), row(start=5_000_000, duration=2_000_000)))
        result = trace.reconcile_submission_ownership(parsed, [
            self.submission(123, 17, 19, 23), self.submission(999, 17, 111, 222)])
        self.assertEqual(len(result["physical_intervals"]), 3)
        metrics = trace.bounded_interval_metrics(result["intervals"], result["unresolved"], 123, 0, NS)
        self.assertEqual(metrics["gpu_execution_seconds_upper_bound"], .012)
        self.assertEqual(metrics["gpu_busy_union_seconds_upper_bound"], .007)

    def test_unknown_submission_owner_cannot_narrow_an_alias_upper_bound(self):
        parsed = trace.parse_gpu_intervals(table(row()))
        result = trace.reconcile_submission_ownership(parsed, [
            self.submission(123, 17, 19, 23), self.submission(0, 17, 111, 222)])
        self.assertEqual(result["intervals"], [])
        self.assertIsNone(result["unresolved"][0]["candidate_pids"])
        metrics = trace.bounded_interval_metrics(result["intervals"], result["unresolved"], 456, 0, NS)
        self.assertGreater(metrics["gpu_execution_seconds_upper_bound"], 0)

    def test_modeled_owner_outside_every_raw_candidate_preserves_a_conflict(self):
        parsed = trace.parse_gpu_intervals(table(row(pid=456)))
        result = trace.reconcile_submission_ownership(parsed, [
            self.submission(123, 17, 19, 23), self.submission(999, 17, 111, 222)])
        self.assertEqual(result["intervals"], [])
        self.assertTrue(result["conflicts"])
        self.assertTrue({123, 456, 999} <= set().union(*(item["pids"] for item in result["conflicts"])))

    def test_physical_dedup_cannot_erase_an_unmapped_positive_command_copy(self):
        values = [row(pid=123, command=19, encoder=23), row(pid=123, command=99, encoder=100)]
        for ordered in (values, list(reversed(values))):
            with self.subTest(commands=[value["cmdbuffer-id"]["text"] for value in ordered]):
                result = trace.reconcile_submission_ownership(trace.parse_gpu_intervals(table(*ordered)),
                    [self.submission(123, 17, 19, 23)])
                self.assertTrue(result["conflicts"] or result["invalid"],
                                "A malformed modeled command must not disappear when another copy resolves")

    def test_mismatching_command_identity_is_not_guessed_from_submission_number(self):
        parsed = trace.parse_gpu_intervals(table(row(pid=None, submission=17, command=19, encoder=23)))
        result = trace.reconcile_submission_ownership(parsed, [self.submission(999, 17, 111, 222)])
        self.assertEqual(result["intervals"], [])
        self.assertEqual(len(result["unresolved"]), 1)

    def test_missing_command_identity_can_use_unique_submission_owner(self):
        parsed = trace.parse_gpu_intervals(table(row(pid=None, submission=17, command=0, encoder=0)))
        result = trace.reconcile_submission_ownership(parsed, [self.submission(999, 17, 111, 222)])
        self.assertEqual(result["intervals"][0]["pid"], 999)

    def test_known_composite_conflict_is_retained_as_invalid_evidence(self):
        parsed = trace.parse_gpu_intervals(table(row(pid=123, submission=17, command=19, encoder=23)))
        result = trace.reconcile_submission_ownership(parsed, [self.submission(999, 17, 19, 23)])
        self.assertEqual(len(result["conflicts"]), 1)

    def test_submission_numeric_pid_must_match_nested_process_pid(self):
        submission = self.submission(123, 17, 19, 23)
        submission["process"] = cell(pid=999)
        result = trace.reconcile_submission_ownership({"intervals": [], "unattributed": []}, [submission])
        self.assertTrue(result["invalid"])

    def test_resolved_duplicate_is_not_counted_twice(self):
        parsed = trace.parse_gpu_intervals(table(row(pid=123), row(pid=None)))
        result = trace.reconcile_submission_ownership(parsed, [self.submission(123, 17, 19, 23)])
        self.assertEqual(len(result["intervals"]), 1)
        self.assertEqual(result["unresolved"], [])

    def test_conflicting_anonymous_composite_is_not_erased_by_unrelated_known_row(self):
        parsed = trace.parse_gpu_intervals(table(row(pid=999), row(pid=None, command=99, encoder=100)))
        result = trace.reconcile_submission_ownership(parsed, [self.submission(999, 17, 19, 23)])
        metrics = trace.bounded_interval_metrics(result["intervals"], result["unresolved"], 123, 0, NS)
        self.assertFalse(metrics["attribution_exact"])
        self.assertGreater(metrics["gpu_execution_seconds_upper_bound"], 0)


def command_frame(pid=123, command=19, committed=5_000_000, *, commit=0, created=1, kind="Command Buffer"):
    return {"pid": cell(pid), "process": cell(pid=pid), "cmdbuffer-id": cell(command),
            "commit-id": cell(commit), "timestamp": cell(created), "commit-time": cell(committed),
            "type-name": cell(kind)}


def command_completion(command=19, timestamp=21_000_000, *, commit=0):
    return {"cmdbuffer-id": cell(command), "commit-id": cell(commit), "timestamp": cell(timestamp)}


class CommandCompletionProofTests(unittest.TestCase):
    def proof(self, frames=None, completions=None, submissions=None, intervals=None):
        frames = [command_frame()] if frames is None else frames
        completions = [command_completion()] if completions is None else completions
        submissions = [SubmissionOwnershipTests.submission(123, 17, 19, 23),
                       SubmissionOwnershipTests.submission(123, 18, 19, 23)] if submissions is None else submissions
        intervals = trace.parse_gpu_intervals(table(row(start=10_000_000, duration=10_000_000)))["intervals"] if intervals is None else intervals
        return trace.command_buffer_completion_proof({"rows": frames}, {"rows": completions}, submissions, intervals, {123})["processes"][123]

    def test_completion_retires_unused_alternate_submission_candidate(self):
        result = self.proof()
        self.assertTrue(result["complete"])
        self.assertEqual(result["retired_nonexecuting_candidate_count"], 1)

    def test_both_candidate_executions_remain_counted(self):
        values = trace.parse_gpu_intervals(table(row(start=10_000_000, duration=5_000_000),
            row(start=15_000_000, duration=5_000_000, submission=18)))["intervals"]
        result = self.proof(intervals=values)
        self.assertTrue(result["complete"])
        self.assertEqual(result["retired_nonexecuting_candidate_count"], 0)
        self.assertEqual(trace.interval_metrics(values, 123, 0, NS)["gpu_execution_seconds"], .01)

    def test_missing_completion_is_pending_even_with_a_paired_execution(self):
        self.assertFalse(self.proof(completions=[])["complete"])

    def test_commit_zero_timestamp_is_not_committed_work(self):
        self.assertFalse(self.proof(frames=[command_frame(committed=0, created=0)])["complete"])

    def test_completion_before_observed_execution_end_is_invalid(self):
        self.assertFalse(self.proof(completions=[command_completion(timestamp=15_000_000)])["complete"])

    def test_multiple_completion_times_are_ambiguous_but_exact_duplicates_are_safe(self):
        self.assertFalse(self.proof(completions=[command_completion(), command_completion(timestamp=100_000_000)])["complete"])
        self.assertTrue(self.proof(completions=[command_completion(), command_completion()])["complete"])

    def test_cross_pid_command_identity_collision_is_invalid(self):
        self.assertFalse(self.proof(frames=[command_frame(), command_frame(pid=999)])["complete"])

    def test_multiple_commit_times_for_same_command_commit_identity_are_invalid(self):
        self.assertFalse(self.proof(frames=[command_frame(), command_frame(committed=6_000_000)])["complete"])

    def test_missing_committed_inventory_is_not_retired_by_a_completion(self):
        self.assertFalse(self.proof(frames=[])["complete"])

    def test_unmapped_or_nonmetal_owned_work_prevents_terminal_proof(self):
        submission = SubmissionOwnershipTests.submission(123, 17, 0, 0)
        submission["submission-type"] = cell(2)
        self.assertFalse(self.proof(submissions=[submission])["complete"])

    def test_synthetic_metalfx_scope_is_not_an_unfinished_command_buffer(self):
        self.assertTrue(self.proof(frames=[command_frame(), command_frame(command=888, kind="MetalFx")])["complete"])

    def test_metal4_commit_ids_keep_reused_command_buffers_separate(self):
        frames = [command_frame(commit=1), command_frame(committed=30_000_000, commit=2)]
        completions = [command_completion(commit=1), command_completion(timestamp=50_000_000, commit=2)]
        submissions = [SubmissionOwnershipTests.submission(123, 17, 19, 23)]
        submissions[0]["commit-id"] = cell(1)
        result = self.proof(frames=frames, completions=completions, submissions=submissions)
        self.assertTrue(result["complete"])
        self.assertEqual(result["completed_command_count"], 2)

    def test_ambiguous_execution_after_fence_is_preserved_without_assigning_it_to_that_command(self):
        ambiguous = {**trace.parse_gpu_intervals(table(row(start=30_000_000, duration=5_000_000)))["intervals"][0],
                     "pid": None, "candidate_pids": [123, 999]}
        submissions = [SubmissionOwnershipTests.submission(123, 17, 19, 23),
                       SubmissionOwnershipTests.submission(999, 17, 111, 222)]
        proof = trace.command_buffer_completion_proof({"rows": [command_frame()]},
            {"rows": [command_completion()]}, submissions, [], {123}, unresolved=[ambiguous])["processes"][123]
        self.assertTrue(proof["complete"])
        self.assertEqual(proof["completed_command_count"], 1)
        self.assertEqual(proof["ambiguous_execution_interval_count"], 1)
        metrics = trace.bounded_interval_metrics([], [ambiguous], 123, 0, NS)
        self.assertEqual(metrics["gpu_execution_seconds_upper_bound"], .005)
        self.assertEqual(metrics["gpu_execution_seconds_lower_bound"], 0)

    def test_certain_process_with_ambiguous_command_cannot_execute_after_all_its_fences(self):
        submissions = [SubmissionOwnershipTests.submission(123, 17, 19, 23),
                       SubmissionOwnershipTests.submission(123, 17, 20, 24)]
        frames = [command_frame(command=19), command_frame(command=20, committed=10_000_000)]
        completions = [command_completion(command=19), command_completion(command=20, timestamp=41_000_000)]
        for start, complete in ((30_000_000, True), (42_000_000, False)):
            with self.subTest(start=start):
                ownership = trace.reconcile_submission_ownership(
                    trace.parse_gpu_intervals(table(row(start=start, duration=5_000_000))), submissions)
                self.assertEqual(len(ownership["intervals"]), 1)
                self.assertFalse(ownership["intervals"][0]["command_identity_certain"])
                result = trace.command_buffer_completion_proof({"rows": frames}, {"rows": completions},
                    submissions, ownership["intervals"], {123})["processes"][123]
                self.assertEqual(result["complete"], complete)
                self.assertEqual(result["retired_nonexecuting_candidate_count"], 0)


class CalibrationBoundsTests(unittest.TestCase):
    def measured(self, lower, upper):
        return {"attribution_exact": lower == upper, "gpu_execution_seconds": lower if lower == upper else None,
                "gpu_execution_seconds_lower_bound": lower, "gpu_execution_seconds_upper_bound": upper}

    def test_both_bounds_must_agree_with_expected_execution_not_merely_contain_it(self):
        for lower, upper, passed in ((.009, .011, True), (.01, .01, True),
                                      (.0079, .01, False), (.01, .0121, False), (0, .02, False)):
            with self.subTest(lower=lower, upper=upper):
                self.assertEqual(trace.calibration_bounds(self.measured(lower, upper), .01), passed)

    def test_idle_and_unrelated_controls_use_the_upper_execution_bound(self):
        for upper, passed in ((0, True), (.0019, True), (.002, True), (.0021, False)):
            with self.subTest(upper=upper):
                self.assertEqual(trace.calibration_bounds(self.measured(0, upper), 0), passed)


class SentinelLifecycleTests(unittest.TestCase):
    def test_only_owned_verified_sleep_process_is_terminated(self):
        process = Mock(pid=456)
        process.poll.return_value = None
        with patch.object(trace.subprocess, "Popen", return_value=process) as spawn, patch.object(trace, "_birth_time", return_value=12345):
            sentinel = trace._Sentinel(trace.time.monotonic() + 10)
            sentinel.close()
        self.assertEqual(spawn.call_args.args[0][0], "/bin/sleep")
        self.assertTrue(spawn.call_args.kwargs["start_new_session"])
        process.terminate.assert_called_once()
        process.kill.assert_not_called()

    def test_identity_change_is_never_killed(self):
        process = Mock(pid=456)
        process.poll.return_value = None
        with patch.object(trace.subprocess, "Popen", return_value=process), patch.object(trace, "_birth_time", side_effect=[12345, 67890]):
            sentinel = trace._Sentinel(trace.time.monotonic() + 10)
            with self.assertRaises(trace.TraceError):
                sentinel.close()
        process.terminate.assert_not_called()
        process.kill.assert_not_called()

    def test_initial_identity_failure_reaps_the_owned_child(self):
        process = Mock(pid=456)
        with patch.object(trace.subprocess, "Popen", return_value=process), patch.object(trace, "_birth_time", side_effect=trace.TraceError("unavailable")):
            with self.assertRaises(trace.TraceError):
                trace._Sentinel(trace.time.monotonic() + 10)
        process.kill.assert_called_once()
        process.wait.assert_called_once()


class TerminalCoverageTests(unittest.TestCase):
    def evaluate(self, *, anonymous=None, missing_process_identity=False, empty_app=False,
                 missing_helper_inventory=False, completion_ns=21_000_000, missing_raw_end=False,
                 ambiguous=None, demote_target=False):
        session = object.__new__(trace.TraceSession)
        session.invalid = []
        session.xml = Path("unused.xml")
        session.clock_start = session.clock_end = {"absolute_minus_monotonic_seconds": 0, "uncertainty_seconds": 0}
        session.processes = {pid: {"birth_time_us": pid * 100} for pid in (123, 345, 456)}
        session.windows = {"case/lifetime": {"process_id": 123, "birth_time_us": 12300,
            "start_monotonic_seconds": 0, "end_monotonic_seconds": 1.1}}
        session.exits = {123: {"status": 0, "final_sample_monotonic_seconds": 1.1, "trace_drain_end_monotonic_seconds": 1.2}}
        session.references = [
            {"kind": "idle", "pid": 345, "start": .05, "end": .09, "metal_seconds": 0},
            {"kind": "target", "pid": 345, "start": .09, "end": .12, "metal_seconds": .01},
            {"kind": "unrelated", "pid": 456, "start": .19, "end": .22, "metal_seconds": .01},
            {"kind": "attribution", "pid": 345, "start": .19, "end": .22, "metal_seconds": 0}]
        session.exported_schemas = [*trace.CORE_SCHEMAS, *trace.TERMINAL_SCHEMAS]
        gpu, points, mappings, frames, completions = table(), TraceCoverageTests.points(), [], [], []
        for pid, sid, command, encoder, start in ((123, 17, 19, 23, 10_000_000),
                (345, 18, 20, 24, 100_000_000), (456, 19, 21, 25, 200_000_000)):
            if pid == 123 and empty_app:
                continue
            gpu["rows"].append(row(start=start, duration=10_000_000, pid=pid, submission=sid, command=command, encoder=encoder))
            points["rows"].extend(TraceCoverageTests.points((start, sid, 1), (start + 10_000_000, sid, 2))["rows"])
            mappings.append(SubmissionOwnershipTests.submission(pid, sid, command, encoder))
            if not (pid == 345 and missing_helper_inventory):
                frames.append(command_frame(pid, command, start - 5_000_000))
            completions.append(command_completion(command, completion_ns if pid == 123 else start + 11_000_000))
        if missing_raw_end:
            points["rows"] = [value for value in points["rows"] if not (value["gpu-submission-id"]["text"] == "17" and value["function"]["text"] == "2")]
        if anonymous:
            left, right = anonymous
            gpu["rows"].append(row(start=left, duration=right-left, pid=None, submission=99, command=0, encoder=0))
            points["rows"].extend(TraceCoverageTests.points((left, 99, 1), (right, 99, 2))["rows"])
        if ambiguous:
            owner, left, right = ambiguous
            command, encoder = {123: (19, 23), 345: (20, 24), 456: (21, 25)}[owner]
            mappings += [SubmissionOwnershipTests.submission(owner, 88, command, encoder),
                         SubmissionOwnershipTests.submission(999, 88, 888, 889)]
            gpu["rows"].append(row(start=left, duration=right-left, pid=999, submission=88, command=888, encoder=889))
            points["rows"].extend(TraceCoverageTests.points((left, 88, 1), (right, 88, 2))["rows"])
        if demote_target:
            mappings.append(SubmissionOwnershipTests.submission(999, 18, 888, 889))
        processes = [{"pid": cell(pid), "unique-id": cell(str(pid)), "process": cell(pid=pid, identifier=f"p{pid}"), "timestamp": cell(0)} for pid in (123, 345, 456)]
        if missing_process_identity:
            processes[0]["unique-id"] = cell("")
            processes[0]["process"]["id"] = None
        tables = {
            "time-info": {"rows": [{"timebase": {"components": [1, 1]}, "mach-absolute-time": cell(0)}]},
            "process-info": {"rows": processes}, trace.GPU_SCHEMA: gpu,
            "metal-gpu-submission-to-command-buffer-id": {"rows": mappings}, "metal-gpu-execution-points": points,
            "metal-command-buffer-frame-assignment": {"rows": frames}, "metal-command-buffer-completed": {"rows": completions}}
        for value in tables.values():
            value.setdefault("invalid", [])
        toc = ET.fromstring('<trace-toc><run><info><target><process type="attached" pid="999"/></target><summary><duration>2</duration></summary></info></run></trace-toc>')
        result = {"lost_events": False, "windows": {}, "final_exit_coverage": {}}
        with patch.object(trace, "read_table", side_effect=lambda _, schema, **kw: tables[schema]):
            session._evaluate(toc, result)
        return result

    def test_verified_exit_completed_owned_execution_has_terminal_coverage(self):
        result = self.evaluate()
        self.assertTrue(result["windows"]["case/lifetime"]["coverage_complete"])
        self.assertTrue(result["final_exit_coverage"]["case/lifetime"]["complete"])

    def test_unknown_after_completion_remains_possible_owned_execution(self):
        result = self.evaluate(anonymous=(1_500_000_000, 1_500_005_000))
        self.assertTrue(result["final_exit_coverage"]["case/lifetime"]["complete"])
        window = result["windows"]["case/lifetime"]
        self.assertGreaterEqual(window["gpu_accounting_end_monotonic_seconds"], 1.500005)
        self.assertAlmostEqual(window["gpu_execution_seconds_upper_bound"], .010005)
        self.assertFalse(result["final_exit_coverage"]["case/lifetime"]["anonymous_execution_after_quiescence_excluded"])

    def test_unknown_tail_before_completion_is_bounded_and_included_in_lifetime_gate(self):
        result = self.evaluate(anonymous=(1_150_000_000, 1_250_000_000), completion_ns=1_300_000_000)
        self.assertTrue(result["final_exit_coverage"]["case/lifetime"]["complete"])
        window = result["windows"]["case/lifetime"]
        self.assertEqual(window["gpu_accounting_end_monotonic_seconds"], 1.3)
        self.assertGreater(window["gpu_rolling_1s_percent_upper_bound"], 1)
        self.assertFalse(window["attribution_exact"])

    def test_empty_app_inventory_requires_both_active_controls(self):
        good = self.evaluate(empty_app=True)
        self.assertTrue(good["final_exit_coverage"]["case/lifetime"]["complete"])
        missing = self.evaluate(empty_app=True, missing_helper_inventory=True)
        self.assertTrue(missing["windows"]["case/lifetime"]["coverage_complete"])
        self.assertFalse(missing["final_exit_coverage"]["case/lifetime"]["complete"])

    def test_missing_raw_endpoint_remains_invalid_despite_completion_fence(self):
        result = self.evaluate(missing_raw_end=True)
        self.assertFalse(result["windows"]["case/lifetime"]["coverage_complete"])
        self.assertFalse(result["final_exit_coverage"]["case/lifetime"]["complete"])

    def test_missing_process_identity_cannot_be_called_verified(self):
        result = self.evaluate(missing_process_identity=True)
        self.assertFalse(result["process_identities"][0]["identity_verified"])
        self.assertFalse(result["windows"]["case/lifetime"]["coverage_complete"])

    def test_possible_owned_alias_after_exit_contributes_to_upper_without_false_quiescence_exclusion(self):
        result = self.evaluate(ambiguous=(123, 1_500_000_000, 1_550_000_000))
        window, final = result["windows"]["case/lifetime"], result["final_exit_coverage"]["case/lifetime"]
        self.assertTrue(result["terminal_command_proof"]["processes"][123]["complete"])
        self.assertFalse(final["anonymous_execution_after_quiescence_excluded"])
        self.assertGreaterEqual(window["gpu_accounting_end_monotonic_seconds"], 1.55)
        self.assertEqual(window["gpu_execution_seconds_lower_bound"], .01)
        self.assertAlmostEqual(window["gpu_execution_seconds_upper_bound"], .06)
        self.assertAlmostEqual(window["gpu_percent_upper_bound"], .06 / 1.1 * 100)
        self.assertAlmostEqual(window["gpu_accounting_duration_seconds"], 1.1)
        self.assertGreater(final["post_exit_execution_bounds"]["gpu_execution_seconds_upper_bound"], 0)

    def test_ambiguous_calibration_keeps_both_bounds_and_does_not_contaminate_unrelated_app(self):
        result = self.evaluate(ambiguous=(345, 105_000_000, 106_000_000))
        calibration = result["calibration"]
        target = next(value for value in calibration["evidence"] if value["kind"] == "target")
        self.assertTrue(calibration["valid"])
        self.assertIsNone(target["trace_execution_seconds"])
        self.assertEqual(target["trace_execution_seconds_lower_bound"], .01)
        self.assertAlmostEqual(target["trace_execution_seconds_upper_bound"], .011)
        self.assertTrue(result["windows"]["case/lifetime"]["attribution_exact"])
        self.assertEqual(result["windows"]["case/lifetime"]["gpu_execution_seconds"], .01)

    def test_calibration_fails_if_either_nonzero_bound_or_idle_upper_exceeds_tolerance(self):
        for arguments in ({"ambiguous": (345, 104_000_000, 107_000_000)},
                          {"ambiguous": (345, 60_000_000, 63_000_000)}, {"demote_target": True}):
            with self.subTest(arguments=arguments):
                result = self.evaluate(**arguments)
                self.assertFalse(result["calibration"]["valid"])
                self.assertFalse(result["windows"]["case/lifetime"]["coverage_complete"])


class TraceRunIssueTests(unittest.TestCase):
    def make_store(self, directory, rows=()):
        path = Path(directory) / "Trace1.run" / "RunIssues.storedata"
        path.parent.mkdir()
        with sqlite3.connect(path) as database:
            database.execute("CREATE TABLE ZISSUE (ZCOUNT INTEGER,ZRELATIVETIMESTAMP INTEGER,ZSUBTYPE INTEGER,ZTYPE INTEGER,ZMESSAGE TEXT,ZPARENT INTEGER)")
            database.executemany("INSERT INTO ZISSUE VALUES (?,?,?,?,?,?)", rows)
        return path

    def test_known_informational_group_does_not_indicate_loss(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_store(directory, [(1, 0, 0, 2, "Data stream: Time Mapping", None)])
            result = trace.read_run_issues(directory)
        self.assertTrue(result["available"])
        self.assertIs(result["lost_events"], False)
        self.assertEqual(result["invalid"], [])

    def test_kernel_lost_event_warning_invalidates_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_store(directory, [(1, 10, 7, 1, "Lost events were detected. Data rate might be too high.", None)])
            result = trace.read_run_issues(directory)
        self.assertIs(result["lost_events"], True)
        self.assertTrue(result["invalid"])

    def test_processing_overflow_warning_invalidates_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_store(directory, [(1, 20, 9, 1, "Immediate recording data was dropped.", None)])
            result = trace.read_run_issues(directory)
        self.assertIs(result["lost_events"], True)
        self.assertTrue(result["invalid"])

    def test_unknown_issue_type_is_not_a_clean_recording(self):
        with tempfile.TemporaryDirectory() as directory:
            self.make_store(directory, [(1, 0, 0, 99, "Future issue", None)])
            result = trace.read_run_issues(directory)
        self.assertIsNone(result["lost_events"])
        self.assertTrue(result["invalid"])

    def test_missing_database_is_not_no_loss(self):
        with tempfile.TemporaryDirectory() as directory:
            result = trace.read_run_issues(directory)
        self.assertFalse(result["available"])
        self.assertIsNone(result["lost_events"])
        self.assertTrue(result["invalid"])

    def test_corrupt_database_is_not_no_loss(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.make_store(directory)
            path.write_bytes(b"truncated recording")
            result = trace.read_run_issues(directory)
        self.assertFalse(result["available"])
        self.assertIsNone(result["lost_events"])
        self.assertTrue(result["invalid"])

    def test_changed_issue_schema_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.make_store(directory)
            with sqlite3.connect(path) as database:
                database.execute("DROP TABLE ZISSUE")
                database.execute("CREATE TABLE ZISSUE (new_schema TEXT)")
            result = trace.read_run_issues(directory)
        self.assertFalse(result["available"])
        self.assertTrue(result["invalid"])


class ExportedTableTests(unittest.TestCase):
    def read_xml(self, source, schema=SCHEMA):
        with tempfile.TemporaryDirectory() as directory:
            location = Path(directory) / "tiny-trace.xml"
            location.write_text(source, encoding="utf-8")
            return trace.read_table(location, schema)

    def test_reads_column_metadata_and_nested_pid_without_trusting_display_name(self):
        result = self.read_xml(exported_xml([exported_row()]))
        self.assertEqual(result["invalid"], [])
        self.assertEqual(result["schema"], SCHEMA)
        self.assertEqual(result["columns"], COLUMNS)
        self.assertEqual(result["rows"][0]["process"]["pid"], 123)
        self.assertEqual(result["rows"][0]["process"]["fmt"], "FluxLLMApp (999)")
        self.assertEqual(result["rows"][0]["start"]["text"], "0")

    def test_resolves_process_defined_inside_an_earlier_nested_label(self):
        columns = {"label": "formatted-label", **COLUMNS}
        nested = ("<formatted-label id='label1' fmt='FluxLLMApp (123)'>"
                  "<process id='p1' fmt='FluxLLMApp (123)'><pid id='pid1'>123</pid>"
                  "<device-session id='s1'>session</device-session></process></formatted-label>")
        first = nested + exported_row(process="<process ref='p1'/>")
        second = "<formatted-label ref='label1'/>" + exported_row(
            start="100", process="<process ref='p1'/>")
        result = self.read_xml(exported_xml([first, second], columns=columns))
        self.assertEqual(result["invalid"], [])
        self.assertEqual([item["process"]["pid"] for item in result["rows"]], [123, 123])
        self.assertEqual(result["rows"][1]["process"]["id"], "p1")

    def test_resolves_a_nested_pid_reference(self):
        first = exported_row()
        second = exported_row(start="100", process=(
            "<process id='p2' fmt='Renamed Process (999)'><pid ref='pid1'/>"
            "<device-session>session</device-session></process>"))
        result = self.read_xml(exported_xml([first, second]))
        self.assertEqual(result["invalid"], [])
        self.assertEqual(result["rows"][1]["process"]["pid"], 123)

    def test_resolves_scalar_references_with_raw_values_and_formatted_units(self):
        first = exported_row().replace("<duration>100</duration>",
                                       "<duration id='d1' fmt='100 ns'>100</duration>")
        second = exported_row(start="100", process="<process ref='p1'/>").replace(
            "<duration>100</duration>", "<duration ref='d1'/>")
        result = self.read_xml(exported_xml([first, second]))
        self.assertEqual(result["invalid"], [])
        self.assertEqual(result["rows"][1]["duration"]["text"], "100")
        self.assertEqual(result["rows"][1]["duration"]["fmt"], "100 ns")

    def test_formatted_process_name_without_nested_pid_stays_unattributed(self):
        result = self.read_xml(exported_xml([
            exported_row(process="<process fmt='FluxLLMApp (123)'/>")]))
        self.assertIsNone(result["rows"][0]["process"]["pid"])

    def test_missing_reference_is_invalid(self):
        result = self.read_xml(exported_xml([exported_row(process="<process ref='missing'/>")]))
        self.assertTrue(result["invalid"])

    def test_reference_cycle_is_invalid(self):
        first = exported_row(process="<process id='p1' ref='p2'/>")
        second = exported_row(process="<process id='p2' ref='p1'/>")
        result = self.read_xml(exported_xml([first, second]))
        self.assertTrue(result["invalid"])

    def test_missing_row_cell_is_invalid(self):
        broken = exported_row().replace("<metal-command-buffer-id>23</metal-command-buffer-id>", "")
        self.assertTrue(self.read_xml(exported_xml([broken]))["invalid"])

    def test_extra_row_cell_is_invalid(self):
        self.assertTrue(self.read_xml(exported_xml([exported_row() + "<uint64>99</uint64>"]))["invalid"])

    def test_missing_schema_is_invalid(self):
        result = self.read_xml(exported_xml([exported_row()], schema="unrelated-table"))
        self.assertTrue(result["invalid"])

    def test_malformed_xml_is_invalid(self):
        self.assertTrue(self.read_xml("<trace-query-result><node>")["invalid"])


class GPUIntervalParsingTests(unittest.TestCase):
    def test_uses_raw_integer_nanoseconds_without_reapplying_mach_timebase(self):
        source = row(start=299_171_458, duration=16_083)
        source["duration"]["fmt"] = "16.08 µs"
        result = trace.parse_gpu_intervals(table(source))
        self.assertEqual(result["invalid"], [])
        self.assertEqual(result["intervals"][0]["start_ns"], 299_171_458)
        self.assertEqual(result["intervals"][0]["end_ns"], 299_187_541)
        self.assertEqual(result["intervals"][0]["pid"], 123)

    def test_ignores_idle_but_rejects_unknown_state(self):
        result = trace.parse_gpu_intervals(table(row(state="Idle"), row(state="Future GPU State")))
        self.assertEqual(result["intervals"], [])
        self.assertTrue(result["invalid"])
        idle = trace.parse_gpu_intervals(table(row(state="Idle")))
        self.assertEqual(idle["intervals"], [])
        self.assertEqual(idle["invalid"], [])

    def test_missing_required_column_is_invalid(self):
        for missing in COLUMNS:
            with self.subTest(column=missing):
                source = table(row())
                del source["columns"][missing]
                del source["rows"][0][missing]
                self.assertTrue(trace.parse_gpu_intervals(source)["invalid"])

    def test_preserves_xml_read_failures(self):
        source = table(row())
        source["invalid"] = ["Unresolved XML reference"]
        self.assertTrue(trace.parse_gpu_intervals(source)["invalid"])

    def test_rejects_fractional_or_nonfinite_nanoseconds(self):
        for field in ["start", "duration"]:
            for value in ["1.5", "NaN", "Infinity", "1e9", ""]:
                with self.subTest(field=field, value=value):
                    source = row()
                    source[field] = cell(value)
                    result = trace.parse_gpu_intervals(table(source))
                    self.assertTrue(result["invalid"])
                    self.assertEqual(result["intervals"], [])

    def test_rejects_negative_start_and_nonpositive_duration(self):
        for source in [row(start=-1), row(duration=-1), row(duration=0)]:
            with self.subTest(source=source):
                result = trace.parse_gpu_intervals(table(source))
                self.assertTrue(result["invalid"])
                self.assertEqual(result["intervals"], [])

    def test_missing_pid_is_unattributed_and_never_pid_zero(self):
        result = trace.parse_gpu_intervals(table(row(pid=None)))
        self.assertEqual(result["intervals"], [])
        self.assertEqual(len(result["unattributed"]), 1)

    def test_exact_duplicate_rows_count_once(self):
        original = row()
        result = trace.parse_gpu_intervals(table(original, copy.deepcopy(original)))
        self.assertEqual(result["invalid"], [])
        self.assertEqual(len(result["intervals"]), 1)
        self.assertEqual(result["duplicates"], 1)

    def test_distinct_execution_identity_or_times_are_not_duplicates(self):
        result = trace.parse_gpu_intervals(table(
            row(), row(submission="18"), row(channel="Fragment"), row(pid=456),
            row(gpu="Other GPU"), row(command="20"), row(encoder="24"),
            row(start=1), row(duration=101)))
        self.assertEqual(result["invalid"], [])
        self.assertEqual(len(result["intervals"]), 9)
        self.assertEqual(result["duplicates"], 0)

    def test_target_pid_attribute_does_not_override_row_process_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            location = Path(directory) / "targeted.xml"
            location.write_text(exported_xml([
                exported_row(duration="100000000"),
                exported_row(duration="900000000", process=(
                    "<process id='other'><pid>456</pid></process>")),
            ], attributes="target-pid='123'"), encoding="utf-8")
            parsed = trace.parse_gpu_intervals(trace.read_table(location, SCHEMA))
        self.assertEqual(parsed["invalid"], [])
        self.assertEqual({item["pid"] for item in parsed["intervals"]}, {123, 456})
        metrics = trace.interval_metrics(parsed["intervals"], 123, 0, NS)
        self.assertAlmostEqual(metrics["gpu_execution_seconds"], 0.1)
        self.assertAlmostEqual(metrics["gpu_percent"], 10)


class GPUIntervalMetricsTests(unittest.TestCase):
    def test_parallel_channels_accumulate_but_busy_union_does_not_double_count(self):
        result = trace.interval_metrics([
            interval(0, 800_000_000),
            interval(200_000_000, NS, channel="Fragment", submission="18"),
        ], 123, 0, NS)
        self.assertAlmostEqual(result["gpu_execution_seconds"], 1.6)
        self.assertAlmostEqual(result["gpu_percent"], 160)
        self.assertAlmostEqual(result["gpu_busy_union_seconds"], 1)
        self.assertAlmostEqual(result["gpu_busy_union_percent"], 100)
        self.assertAlmostEqual(result["gpu_rolling_1s_percent"], 160)

    def test_unions_each_gpu_separately(self):
        result = trace.interval_metrics([
            interval(0, 700_000_000, gpu="GPU A"),
            interval(300_000_000, NS, gpu="GPU B"),
        ], 123, 0, NS)
        self.assertAlmostEqual(result["gpu_busy_union_seconds"], 1.4)
        self.assertAlmostEqual(result["gpu_busy_union_percent"], 140)

    def test_clips_both_window_boundaries_and_excludes_other_pids(self):
        result = trace.interval_metrics([
            interval(0, 750_000_000),
            interval(1_250_000_000, 2 * NS, submission="18"),
            interval(0, 3 * NS, pid=456),
            interval(2 * NS, 3 * NS, submission="19"),
        ], 123, 500_000_000, 1_500_000_000)
        self.assertAlmostEqual(result["gpu_execution_seconds"], 0.5)
        self.assertAlmostEqual(result["gpu_percent"], 50)
        self.assertAlmostEqual(result["gpu_busy_union_seconds"], 0.5)
        self.assertAlmostEqual(result["gpu_rolling_1s_percent"], 50)

    def test_finds_exact_rolling_peak_between_periodic_sampling_boundaries(self):
        result = trace.interval_metrics([
            interval(350_000_000, 750_000_000),
            interval(1_050_000_000, 1_450_000_000, submission="18"),
        ], 123, 0, 2 * NS)
        self.assertAlmostEqual(result["gpu_percent"], 40)
        # [0.35, 1.35] and [0.45, 1.45] each contain 0.70 GPU seconds;
        # quarter-second or integer-second windows miss this maximum.
        self.assertAlmostEqual(result["gpu_rolling_1s_percent"], 70)

    def test_exact_rolling_peak_is_independent_of_trace_clock_origin(self):
        origin = 7_000_000_007
        result = trace.interval_metrics([
            interval(origin + 350_000_000, origin + 750_000_000),
            interval(origin + 1_050_000_000, origin + 1_450_000_000, submission="18"),
        ], 123, origin, origin + 2 * NS)
        self.assertAlmostEqual(result["gpu_rolling_1s_percent"], 70)

    def test_short_window_has_no_fabricated_one_second_peak(self):
        result = trace.interval_metrics([interval(0, 100_000_000)], 123, 0, 500_000_000)
        self.assertAlmostEqual(result["gpu_percent"], 20)
        self.assertIsNone(result["gpu_rolling_1s_percent"])

    def test_touching_intervals_do_not_overlap_or_leave_artificial_gaps(self):
        result = trace.interval_metrics([
            interval(0, 500_000_000), interval(500_000_000, NS, submission="18"),
        ], 123, 0, NS)
        self.assertAlmostEqual(result["gpu_execution_seconds"], 1)
        self.assertAlmostEqual(result["gpu_busy_union_seconds"], 1)

    def test_outside_window_has_zero_measured_overlap(self):
        result = trace.interval_metrics([
            interval(0, NS), interval(2 * NS, 3 * NS, submission="18"),
        ], 123, NS, 2 * NS)
        self.assertEqual(result["gpu_execution_seconds"], 0)
        self.assertEqual(result["gpu_busy_union_seconds"], 0)
        self.assertEqual(result["gpu_rolling_1s_percent"], 0)

    def test_invalid_target_or_window_is_rejected(self):
        for pid, start, end in [(0, 0, NS), (-1, 0, NS), (123, NS, NS), (123, NS, 0)]:
            with self.subTest(pid=pid, start=start, end=end):
                with self.assertRaises(ValueError):
                    trace.interval_metrics([], pid, start, end)


if __name__ == "__main__":
    unittest.main()
