"""Validate the performance gate without building or running FluxLLM.

Run: python3 -m unittest discover -s scripts -p 'test_performance_checks.py' -v
"""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

import run_performance_checks as perf


def scenario(cycles=3):
    return {"ui": "closed", "history": "populated", "activity": "ordinary",
            "duration_seconds": 65, "cycles": cycles, "settle_seconds": 10}


def measurement(cycles=3):
    phases = []
    for cycle in range(1, cycles + 1):
        for name, elapsed in (("workload", 65), ("settled", 10)):
            phases.append({"name": name, "cycle": cycle, "elapsed_seconds": elapsed,
                           "cpu_seconds": elapsed / 10,
                           "physical_footprint_start_bytes": 1000,
                           "physical_footprint_end_bytes": 1000 + cycle * 100,
                           "physical_footprint_peak_bytes": 2000 + cycle * 100,
                           "gpu_seconds": elapsed / 20, "gpu_unavailable_reason": None,
                           "disk_write_bytes": 100, "interrupt_wakeups": 10})
    return {"schema_version": 1, "scenario": scenario(cycles),
            "environment": {"os": "testOS", "hardware": "testMachine",
                            "build_configuration": "release", "display": "testDisplay",
                            "gpu_method": "test-attributed-counter", "fixture_sha256": perf.workload_fingerprint()},
            "phases": phases, "validation": {"passed": True, "requests": 2 * cycles,
                                              "chunks": 65 * 40 * 2 * cycles, "tool_calls": 2 * cycles,
                                              "tool_results": 2 * cycles,
                                              "session_history_verified": True, "history_files_absent": True}}


def budget(result=None):
    result = result or measurement()
    return {"schema_version": 1, "environment": copy.deepcopy(result["environment"]),
            "gpu_attribution": {"method": "test-attributed-counter", "evidence": "reviewed test capture"},
            "cases": {perf.case_key(result["scenario"]): {
                "scenario": copy.deepcopy(result["scenario"]),
                "limits": {"cpu_percent": 10, "peak_footprint_bytes": 2300,
                           "retained_growth_bytes": 200, "gpu_percent": 5}}}}


def fixture_command(source=None):
    return [sys.executable, "-u", "-c", source or (
        "import json,time; print(json.dumps({'base_url':'http://127.0.0.1:9999'}),flush=True); time.sleep(60)")]


def result_command(result=None, suffix=""):
    result = result or measurement()
    source = (
        "import json,os,pathlib,sys\n"
        "assert os.environ['FLUXLLM_PERF_ENABLED']=='1'\n"
        "assert os.environ['FLUXLLM_PERF_UPSTREAM']=='http://127.0.0.1:9999'\n"
        "assert pathlib.Path.cwd()==pathlib.Path(os.environ['FLUXLLM_PERF_TMPDIR'])\n"
        f"result=json.loads({json.dumps(result)!r})\n"
        "result['scenario']=json.loads(os.environ['FLUXLLM_PERF_SCENARIO'])\n"
        "pathlib.Path(os.environ['FLUXLLM_PERF_RESULT']).write_text(json.dumps(result))\n"
        "print('measurement finished',flush=True)\n" + suffix)
    return [sys.executable, "-c", source]


class SchemaTests(unittest.TestCase):
    def test_complete_result_is_valid_and_computes_exact_limits(self):
        result = perf.validate_result(measurement(), scenario())
        limits = perf.validate_budget(budget())
        self.assertEqual(perf.check_result(result, limits), [])
        metrics = perf.derive_metrics(result)
        self.assertEqual(metrics["cpu_percent"], 10)
        self.assertEqual(metrics["gpu_percent"], 5)
        self.assertEqual(metrics["peak_footprint_bytes"], 2300)
        self.assertEqual(metrics["retained_growth_bytes"], 200)
        self.assertEqual(metrics["disk_write_bytes"], 600)
        self.assertEqual(metrics["interrupt_wakeups"], 60)

    def test_settling_cpu_and_gpu_work_are_gated(self):
        result = measurement()
        result["phases"][-1].update(cpu_seconds=8, gpu_seconds=6)
        failures = perf.check_result(result, budget())
        self.assertTrue(any("cpu_percent" in failure and "80" in failure for failure in failures))
        self.assertTrue(any("gpu_percent" in failure and "60" in failure for failure in failures))

    def test_every_resource_limit_fails_independently(self):
        for field in perf.LIMIT_FIELDS:
            with self.subTest(field=field):
                limits = budget()
                limits["cases"][perf.case_key(scenario())]["limits"][field] -= 1
                failures = perf.check_result(measurement(), limits)
                self.assertEqual(len(failures), 1)
                self.assertIn(field, failures[0])

    def test_missing_gpu_is_valid_baseline_but_cannot_pass_check(self):
        result = measurement()
        result["phases"][2].update(gpu_seconds=None, gpu_unavailable_reason="Driver has no attributed counter")
        perf.validate_result(result, scenario())
        self.assertIsNone(perf.derive_metrics(result)["gpu_percent"])
        failures = perf.check_result(result, budget())
        self.assertEqual(len(failures), 1)
        self.assertIn("Driver has no attributed counter", failures[0])

    def test_missing_gpu_requires_a_reason(self):
        result = measurement()
        result["phases"][0]["gpu_seconds"] = None
        with self.assertRaisesRegex(perf.InvalidResult, "explain unavailable GPU"):
            perf.validate_result(result, scenario())

    def test_missing_optional_counters_remain_unknown(self):
        result = measurement()
        result["phases"][0].update(disk_write_bytes=None, interrupt_wakeups=None)
        perf.validate_result(result, scenario())
        metrics = perf.derive_metrics(result)
        self.assertIsNone(metrics["disk_write_bytes"])
        self.assertIsNone(metrics["interrupt_wakeups"])

    def test_one_cycle_cannot_supply_retained_growth_gate(self):
        result = measurement(cycles=1)
        self.assertIsNone(perf.derive_metrics(result)["retained_growth_bytes"])
        failures = perf.check_result(result, budget(result))
        self.assertTrue(any("at least three cycles" in failure for failure in failures))

    def test_memory_reclamation_does_not_count_as_negative_growth(self):
        result = measurement()
        result["phases"][3]["physical_footprint_end_bytes"] = 1000
        result["phases"][-1]["physical_footprint_end_bytes"] = 1000
        self.assertEqual(perf.derive_metrics(result)["retained_growth_bytes"], 0)

    def test_retained_growth_captures_rise_after_earlier_memory_reclamation(self):
        result = measurement()
        for phase, footprint in zip(result["phases"][1::2], (1000, 700, 900)):
            phase["physical_footprint_end_bytes"] = footprint
        self.assertEqual(perf.derive_metrics(result)["retained_growth_bytes"], 200)

    def test_retained_growth_captures_intermediate_high_before_final_release(self):
        result = measurement()
        for phase, footprint in zip(result["phases"][1::2], (1000, 1500, 1000)):
            phase["physical_footprint_end_bytes"] = footprint
        self.assertEqual(perf.derive_metrics(result)["retained_growth_bytes"], 500)

    def test_two_cycles_cannot_supply_retained_growth_gate(self):
        self.assertIsNone(perf.derive_metrics(measurement(cycles=2))["retained_growth_bytes"])
        with self.assertRaisesRegex(perf.InvalidResult, "at least three cycles"):
            perf.validate_budget(budget(measurement(cycles=2)))

    def test_environment_and_scenario_must_match_exactly(self):
        for target, field, value in (("environment", "display", "otherDisplay"),
                                     ("environment", "extra", "new context"),
                                     ("scenario", "duration_seconds", 66)):
            with self.subTest(target=target, field=field):
                result = measurement()
                result[target][field] = value
                failures = perf.check_result(result, budget())
                self.assertTrue(any("differs" in failure for failure in failures))

    def test_correctness_cannot_be_skipped_or_truthy(self):
        for validation in ({}, {"passed": False}, {"passed": 1}, {"passed": "true"}, None):
            with self.subTest(validation=validation):
                result = measurement()
                result["validation"] = validation
                with self.assertRaisesRegex(perf.InvalidResult, "correctness"):
                    perf.validate_result(result, scenario())

    def test_passed_flag_cannot_replace_exact_workload_and_reload_evidence(self):
        for field, value in (("requests", 0), ("chunks", 0), ("tool_calls", 0),
                             ("tool_results", 0), ("session_history_verified", False), ("history_files_absent", 1)):
            with self.subTest(field=field):
                result = measurement()
                result["validation"][field] = value
                with self.assertRaises(perf.InvalidResult):
                    perf.validate_result(result, scenario())

    def test_no_history_file_evidence_cannot_be_missing_false_or_truthy(self):
        for value in (None, False, 1, "true"):
            with self.subTest(value=value):
                result = measurement()
                if value is None:
                    result["validation"].pop("history_files_absent")
                else:
                    result["validation"]["history_files_absent"] = value
                with self.assertRaisesRegex(perf.InvalidResult, "history_files_absent"):
                    perf.validate_result(result, scenario())

    def test_manifest_counts_for_idle_and_high_rate(self):
        for activity, rate, requests in (("idle", 0, 0), ("high-rate", 200, 6)):
            with self.subTest(activity=activity):
                result = measurement()
                result["scenario"]["activity"] = activity
                result["validation"].update(requests=requests, chunks=65 * rate * requests,
                                            tool_calls=requests, tool_results=requests)
                perf.validate_result(result, result["scenario"])

    def test_nonfinite_negative_boolean_and_fractional_counters_are_rejected(self):
        for field, value in (("cpu_seconds", float("nan")), ("cpu_seconds", float("inf")),
                             ("cpu_seconds", -1), ("gpu_seconds", True),
                             ("physical_footprint_peak_bytes", 2300.5),
                             ("physical_footprint_start_bytes", 0), ("interrupt_wakeups", -1)):
            with self.subTest(field=field, value=value):
                result = measurement()
                result["phases"][0][field] = value
                with self.assertRaises(perf.InvalidResult):
                    perf.validate_result(result, scenario())

    def test_incomplete_reordered_or_short_phases_are_rejected(self):
        alterations = (
            lambda phases: phases.pop(),
            lambda phases: phases.reverse(),
            lambda phases: phases[0].update(elapsed_seconds=1),
            lambda phases: phases[1].update(elapsed_seconds=1),
            lambda phases: phases[0].update(cycle=True),
            lambda phases: phases[0].update(physical_footprint_peak_bytes=1000),
        )
        for change in alterations:
            with self.subTest(change=change):
                result = measurement()
                change(result["phases"])
                with self.assertRaises(perf.InvalidResult):
                    perf.validate_result(result, scenario())

    def test_result_cannot_substitute_a_cheaper_scenario(self):
        result = measurement()
        result["scenario"]["activity"] = "idle"
        with self.assertRaisesRegex(perf.InvalidResult, "differs from requested"):
            perf.validate_result(result, scenario())

    def test_overlong_workload_and_settled_phases_cannot_dilute_resource_cost(self):
        for phase_index, duration in ((0, 65), (1, 10)):
            with self.subTest(phase=phase_index):
                result = measurement()
                result["phases"][phase_index]["elapsed_seconds"] = duration + 5
                perf.validate_result(result, scenario())
                result["phases"][phase_index]["elapsed_seconds"] = duration + 5.001
                with self.assertRaisesRegex(perf.InvalidResult, "exceeded.*more than 5 seconds"):
                    perf.validate_result(result, scenario())

    def test_scenario_rejects_values_beyond_the_swift_harness_bounds(self):
        for field, value in (("duration_seconds", 601), ("cycles", 21), ("settle_seconds", 121)):
            with self.subTest(field=field):
                value_to_check = scenario()
                value_to_check[field] = value
                with self.assertRaises(perf.InvalidResult):
                    perf.validate_scenario(value_to_check)

    def test_workload_identity_changes_only_when_a_fixture_source_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative_path in perf.WORKLOAD_SOURCES:
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(relative_path)
            original = perf.workload_fingerprint(root)
            self.assertRegex(original, r"^[0-9a-f]{64}$")
            production = root / "Sources" / "App.swift"
            production.parent.mkdir(exist_ok=True)
            production.write_text("production optimization")
            self.assertEqual(perf.workload_fingerprint(root), original)
            (root / perf.WORKLOAD_SOURCES[0]).write_text("changed synthetic workload")
            self.assertNotEqual(perf.workload_fingerprint(root), original)

    def test_budgets_require_all_limits_and_reviewed_gpu_attribution(self):
        for mutation in (
            lambda value: value["environment"].update(build_configuration="debug"),
            lambda value: value["environment"].update(fixture_sha256="bad hash"),
            lambda value: value["environment"].pop("fixture_sha256"),
            lambda value: value.pop("gpu_attribution"),
            lambda value: value["gpu_attribution"].update(evidence=""),
            lambda value: value["gpu_attribution"].update(method="whole-device"),
            lambda value: value["cases"][perf.case_key(scenario())]["limits"].pop("gpu_percent"),
            lambda value: value["cases"][perf.case_key(scenario())]["limits"].update(cpu_percentage=10),
        ):
            with self.subTest(mutation=mutation):
                value = budget()
                mutation(value)
                with self.assertRaises(perf.InvalidResult):
                    perf.validate_budget(value)

    def test_strict_json_rejects_duplicate_keys_and_nonfinite_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "invalid.json"
            for content in ('{"cpu":1,"cpu":2}', '{"cpu":NaN}', '{"cpu":Infinity}'):
                with self.subTest(content=content):
                    path.write_text(content)
                    with self.assertRaises(perf.InvalidResult):
                        perf.load_json(path)


class ProcessTests(unittest.TestCase):
    def test_isolation_environment_and_log_preservation(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "run"
            run = perf.execute_case(result_command(), scenario(), directory, 5, fixture_command())
            self.assertEqual(run["failures"], [])
            self.assertEqual(run["exit_code"], 0)
            self.assertEqual(run["metrics"]["retained_growth_bytes"], 200)
            self.assertIn("measurement finished", (directory / "process.log").read_text())
            self.assertTrue((directory / "fixture.log").exists())
            self.assertEqual(perf.load_json(directory / "scenario.json"), scenario())

    def test_child_cannot_override_runner_workload_identity(self):
        result = measurement()
        result["environment"]["fixture_sha256"] = "0" * 64
        with tempfile.TemporaryDirectory() as temporary:
            run = perf.execute_case(result_command(result), scenario(), Path(temporary) / "run", 5, fixture_command())
            self.assertEqual(run["failures"], [])
            self.assertEqual(run["result"]["environment"]["fixture_sha256"], perf.workload_fingerprint())
            self.assertNotEqual(run["result"]["environment"]["fixture_sha256"], result["environment"]["fixture_sha256"])

    def test_valid_result_cannot_hide_failing_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = perf.execute_case(result_command(suffix="sys.exit(7)"), scenario(),
                                    Path(temporary) / "run", 5, fixture_command())
            self.assertEqual(run["exit_code"], 7)
            self.assertTrue(any("did not exit successfully" in failure for failure in run["failures"]))

    def test_success_without_result_cannot_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            run = perf.execute_case([sys.executable, "-c", "pass"], scenario(),
                                    Path(temporary) / "run", 5, fixture_command())
            self.assertTrue(any("Invalid measurement result" in failure for failure in run["failures"]))

    def test_timeout_preserves_logs_and_result_but_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "run"
            run = perf.execute_case(result_command(suffix="import time; time.sleep(60)"), scenario(),
                                    directory, 0.5, fixture_command())
            self.assertTrue(any("timed out" in failure for failure in run["failures"]))
            self.assertIn("measurement finished", (directory / "process.log").read_text())
            self.assertIn("result", run)

    @unittest.skipUnless(os.name == "posix", "Process-group cleanup uses POSIX signals")
    def test_timeout_stops_child_descendants(self):
        descendant = ("import pathlib,signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); "
                      "f=pathlib.Path('heartbeat').open('ab',buffering=0)\n"
                      "while True: f.write(b'.'); time.sleep(0.02)")
        parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{descendant!r}]); time.sleep(60)"
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "run"
            run = perf.execute_case([sys.executable, "-c", parent], scenario(), directory, 0.5, fixture_command())
            self.assertTrue(any("timed out" in failure for failure in run["failures"]))
            size = (directory / "heartbeat").stat().st_size
            time.sleep(0.1)
            self.assertEqual((directory / "heartbeat").stat().st_size, size)

    def test_fixture_startup_failure_preserves_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with self.assertRaises(perf.InvalidResult):
                perf.launch_fixture(directory, fixture_command("print('not JSON',flush=True)"))
            self.assertEqual((directory / "fixture.log").read_text().strip(), "not JSON")

    def test_fixture_startup_timeout_is_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(perf.InvalidResult, "timed out"):
                perf.launch_fixture(Path(temporary), fixture_command("import time; time.sleep(60)"), timeout=0.1)


class CLITests(unittest.TestCase):
    def test_defaults_cover_all_cases_and_multiple_cycles(self):
        args = perf.arguments(["baseline", "--command", sys.executable])
        self.assertIsNone(args.case)
        self.assertEqual(len(perf.UIS) * len(perf.HISTORIES) * len(perf.ACTIVITIES), 18)
        self.assertEqual(args.cycles, 3)

    def test_repeated_case_selection_and_command_preserve_literal_arguments(self):
        literal = "$(touch unwanted); * ' \""
        args = perf.arguments(["baseline", "--case", "closed/populated/ordinary", "--case", "visible/fresh/idle",
                               "--command", sys.executable, "-c", literal])
        self.assertEqual(len(args.case), 2)
        self.assertEqual(args.command[-1], literal)

    def test_invalid_cli_values_are_rejected(self):
        for arguments in (("--duration", "64"), ("--duration", "nan"), ("--settle", "4"),
                          ("--cycles", "0"), ("--repetitions", "0"), ("--timeout", "inf"),
                          ("--case", "closed/fresh/bad"), ("--duration", "601"),
                          ("--cycles", "21"), ("--settle", "121")):
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    perf.arguments(["baseline", *arguments, "--command", sys.executable])

    def test_check_requires_budget_and_baseline_cannot_take_one(self):
        for arguments in (["check", "--command", sys.executable],
                          ["baseline", "--budget", "budget.json", "--command", sys.executable]):
            with self.subTest(arguments=arguments), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    perf.arguments(arguments)

    def test_baseline_is_explicitly_not_a_regression_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "artifacts"
            fake_run = {"result": measurement(), "metrics": perf.derive_metrics(measurement()), "failures": [], "exit_code": 0}
            with mock.patch.object(perf, "execute_case", return_value=fake_run), contextlib.redirect_stdout(io.StringIO()) as stdout:
                code = perf.main(["baseline", "--case", "closed/populated/ordinary", "--output-dir", str(output),
                                  "--command", sys.executable])
            self.assertEqual(code, 0)
            report = perf.load_json(output / "report.json")
            self.assertEqual(report["status"], "baseline_recorded")
            self.assertIsNone(report["regression_passed"])
            self.assertIn("NOT a regression pass", stdout.getvalue())

    def test_check_rejects_missing_scenario_before_starting_any_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "budget.json"
            perf.write_json(path, budget())
            with mock.patch.object(perf, "execute_case") as execute, contextlib.redirect_stderr(io.StringIO()):
                code = perf.main(["check", "--budget", str(path), "--case", "visible/fresh/idle", "--command", sys.executable])
            self.assertEqual(code, 1)
            execute.assert_not_called()

    def test_changed_workload_cannot_reuse_an_old_budget(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "budget.json"
            frozen = budget()
            frozen["environment"]["fixture_sha256"] = "0" * 64
            perf.write_json(path, frozen)
            with mock.patch.object(perf, "execute_case") as execute, contextlib.redirect_stderr(io.StringIO()) as stderr:
                code = perf.main(["check", "--budget", str(path), "--case", "closed/populated/ordinary", "--command", sys.executable])
            self.assertEqual(code, 1)
            self.assertIn("Fixture/probe sources differ", stderr.getvalue())
            execute.assert_not_called()

    def test_check_records_pass_only_after_every_required_metric_passes(self):
        for gpu_available in (True, False):
            with self.subTest(gpu_available=gpu_available), tempfile.TemporaryDirectory() as temporary:
                result = measurement()
                if not gpu_available:
                    result["phases"][-1].update(gpu_seconds=None, gpu_unavailable_reason="No counter")
                path = Path(temporary) / "budget.json"
                perf.write_json(path, budget())
                output = Path(temporary) / "artifacts"
                fake_run = {"result": result, "metrics": perf.derive_metrics(result), "failures": [], "exit_code": 0}
                with mock.patch.object(perf, "execute_case", return_value=fake_run), contextlib.redirect_stdout(io.StringIO()):
                    code = perf.main(["check", "--budget", str(path), "--case", "closed/populated/ordinary",
                                      "--output-dir", str(output), "--command", sys.executable])
                self.assertEqual(code, 0 if gpu_available else 1)
                report = perf.load_json(output / "report.json")
                self.assertEqual(report["regression_passed"], gpu_available)
                self.assertEqual(report["status"], "passed" if gpu_available else "failed")

    def test_environment_changes_between_repetitions_fail_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            runs = [{"result": measurement(), "failures": [], "exit_code": 0} for _ in range(2)]
            runs[1]["result"]["environment"]["display"] = "changedDisplay"
            output = Path(temporary) / "artifacts"
            with mock.patch.object(perf, "execute_case", side_effect=runs), contextlib.redirect_stdout(io.StringIO()):
                code = perf.main(["baseline", "--case", "closed/populated/ordinary", "--repetitions", "2",
                                  "--output-dir", str(output), "--command", sys.executable])
            self.assertEqual(code, 1)
            report = perf.load_json(output / "report.json")
            self.assertTrue(any("Environment changed between runs" in failure for failure in report["failures"]))

    def test_artifacts_cannot_be_written_in_repository(self):
        with mock.patch.object(perf, "execute_case") as execute, contextlib.redirect_stderr(io.StringIO()):
            code = perf.main(["baseline", "--output-dir", str(perf.REPO_ROOT / "perf-output"), "--command", sys.executable])
        self.assertEqual(code, 1)
        execute.assert_not_called()

    def test_existing_artifacts_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_text("previous evidence")
            with contextlib.redirect_stderr(io.StringIO()):
                code = perf.main(["baseline", "--output-dir", temporary, "--command", sys.executable])
            self.assertEqual(code, 1)
            self.assertEqual(path.read_text(), "previous evidence")


if __name__ == "__main__":
    unittest.main()
