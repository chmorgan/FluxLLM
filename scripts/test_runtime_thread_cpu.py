"""Direct kernel thread accounting fixtures; no app launch or profiler."""
import copy
import unittest

import runtime_thread_cpu as thread_cpu
from test_app_performance import cpu_events


def calibration():
    return {"available": True, "source": thread_cpu.SOURCE, "raw_unit": "nanoseconds", "conversion_numer": 1,
            "conversion_denom": 1}


def full_calibration():
    return calibration() | {"reference": "CLOCK_THREAD_CPUTIME_ID/getrusage/owned-process-rusage",
        "process_id": 122, "birth_time_us": 400, "thread_id": 6, "timebase": {"numer": 1, "denom": 1},
        "tolerance_relative": .05, "tolerance_absolute_ns": 2_000_000,
        "external_owned_child": True, "dead_thread_rejected": True,
        "observer_overhead": {"read_count": 200, "cpu_ns": 200_000, "wall_ns": 300_000},
        "elapsed_seconds": .6,
        "phases": [{"name": name, "passed": True, "thread_raw_delta": cpu,
                    "thread_clock_delta_ns": cpu, "getrusage_delta_ns": cpu,
                    "process_cpu_delta_ns": cpu, "measured_thread_cpu_ns": cpu, "wall_seconds": wall}
                   for name, cpu, wall in (("continuous", 80_000_000, .08),
                                           ("bursty", 40_000_000, .1), ("idle", 100_000, .05))]}


def report_fixture():
    samples = []
    for index in range(33):
        elapsed = index / 4
        cpu_ns = index * 17_500_000
        sample = {"type": "sample", "process_id": 123, "birth_time_us": 456,
                  "monotonic_seconds": 500 + elapsed, "cpu_seconds": cpu_ns / 1e9,
                  "user_cpu_ticks": cpu_ns, "system_cpu_ticks": 0,
                  "mach_absolute_ticks": int((110 + elapsed) * 1e9),
                  "mach_absolute_seconds": 110 + elapsed, "mach_timebase_numer": 1,
                  "mach_timebase_denom": 1, "clock_read_uncertainty_seconds": .0000001,
                  "phase": "baseline" if index == 0 else "control_boundary" if index == 1 else "final" if index == 32 else "periodic",
                  **({"command_id": "collector-handshake"} if index == 1 else {})}
        if 1 <= index < 32:
            sample["thread_cpu"] = {
                "schema_version": 1, "available": True, "source": thread_cpu.SOURCE,
                "process_id": 123, "birth_time_us": 456, "timebase": {"numer": 1, "denom": 1},
                "read_begin_mach_ticks": sample["mach_absolute_ticks"] + 100_000,
                "read_end_mach_ticks": sample["mach_absolute_ticks"] + 200_000,
                "process_cpu_before_ns": cpu_ns + 1000, "process_cpu_after_ns": cpu_ns + 3000,
                "observer_cpu_ns": 2000, "calibration": calibration(),
                "threads": [{"role": role, "thread_id": identifier,
                             "user_cpu_ns": index * user, "system_cpu_ns": index * system,
                             "user_cpu_raw": index * user, "system_cpu_raw": index * system}
                            for role, identifier, user, system in (("main", 7, 8_000_000, 2_000_000),
                                                                   ("nio", 8, 4_000_000, 1_000_000))]}
        samples.append(sample)
    events = [{"type": "thread_cpu_calibration", "calibration": full_calibration()}, *cpu_events(samples)]
    ready = next(event["event"] for event in events if event.get("type") == "app_event")
    ready["snapshot"] = {"thread_cpu_registration": {"schema_version": 1, "process_id": 123,
                                                       "roles": {"main": 7, "nio": 8}}}
    def bridge(mono):
        return {"mach_ticks": int((mono + 10) * 1e9), "numer": 1, "denom": 1,
                "monotonic_seconds": mono, "uncertainty_seconds": .0000001,
                "absolute_minus_monotonic_seconds": 10}
    return {"samples": samples, "events": events, "errors": [], "workload": {"validated": True},
            "owned_identity": {"process_id": 123, "birth_time_us": 456},
            "runtime": {"mach_clock_start": bridge(100), "mach_clock_end": bridge(108)},
            "phase_windows": {name: {"start_monotonic_seconds": start, "end_monotonic_seconds": end}
                              for name, start, end in (("arrival", 101, 103), ("steady", 103, 105),
                                                      ("completion", 105, 107), ("whole_contiguous_runtime", 100.5, 107.5))}}


class DirectThreadCPUTests(unittest.TestCase):
    def assert_invalid(self, report):
        result = thread_cpu.analyze_report(report)
        self.assertEqual(result["status"], "invalid", result)
        self.assertFalse(result["available"])
        self.assertFalse(result["acceptance_eligible"])
        self.assertTrue(result["errors"])
        return result

    def test_kernel_deltas_roles_process_and_residual_are_disjoint(self):
        report = report_fixture()
        result = thread_cpu.analyze_report(report, required=True)
        self.assertEqual(result["status"], "available", result)
        steady = result["intervals"]["steady"]
        self.assertEqual(steady["roles"]["main"]["user_cpu_ns"], 56_000_000)
        self.assertEqual(steady["roles"]["main"]["system_cpu_ns"], 14_000_000)
        self.assertEqual(steady["roles"]["nio"]["cpu_ns"], 35_000_000)
        for label, percent in (("main", 4), ("nio", 2)):
            bounds = steady["roles"][label]["average_cpu_percent_bounds"]
            self.assertLess(bounds["lower"], percent)
            self.assertGreater(bounds["upper"], percent)
        for label, percent in (("process", 7), ("residual", 1)):
            bounds = steady[label]["average_cpu_percent_bounds"]
            self.assertLess(bounds["lower"], percent)
            self.assertGreater(bounds["upper"], percent)
        self.assertFalse(result["rolling_1s_attribution"]["available"])
        self.assertFalse(result["acceptance_eligible"])

    def test_records_actual_interior_scope_without_interpolating_phase_edges(self):
        result = thread_cpu.analyze_report(report_fixture())
        steady = result["intervals"]["steady"]
        self.assertEqual(steady["sample_indices"], {"start": 12, "end": 19})
        self.assertEqual(steady["requested_window"]["start_monotonic_seconds"], 103)
        self.assertGreater(steady["actual_window"]["start_python_monotonic_seconds_bounds"]["lower"], 103)
        self.assertLess(steady["actual_window"]["end_python_monotonic_seconds_bounds"]["upper"], 105)

    def test_legacy_is_unavailable_unless_requested_measurement_requires_it(self):
        report = report_fixture()
        for sample in report["samples"]:
            sample.pop("thread_cpu", None)
        result = thread_cpu.analyze_report(report)
        self.assertEqual(result["status"], "unavailable")
        self.assertNotIn("intervals", result)
        self.assert_invalid_required(report)

    def assert_invalid_required(self, report):
        result = thread_cpu.analyze_report(report, required=True)
        self.assertEqual(result["status"], "invalid", result)
        self.assertTrue(result["errors"])

    def test_missing_group_inside_measurement_is_not_legacy(self):
        for value in (None, {}, "missing"):
            report = report_fixture()
            if value == "missing":
                del report["samples"][14]["thread_cpu"]
            else:
                report["samples"][14]["thread_cpu"] = value
            with self.subTest(value=value):
                self.assert_invalid(report)

    def test_unavailable_or_failed_calibration_is_not_zero_cpu(self):
        for failure in ("read", "calibration", "conversion", "unit"):
            report = report_fixture()
            group = report["samples"][14]["thread_cpu"]
            if failure == "read":
                group.clear()
                group.update(available=False, reason="thread exited")
            elif failure == "calibration":
                group["calibration"]["available"] = False
            elif failure == "conversion":
                group["calibration"]["conversion_numer"] = 2
            else:
                group["calibration"]["raw_unit"] = "unknown"
            with self.subTest(failure=failure):
                self.assert_invalid(report)

    def test_strict_identity_registration_schema_and_roles(self):
        mutations = (lambda g: g.update(schema_version=True), lambda g: g.update(source="sample estimates"),
                     lambda g: g.update(process_id=999), lambda g: g.update(birth_time_us=457),
                     lambda g: g["threads"][1].update(thread_id=7),
                     lambda g: g["threads"][1].update(thread_id=9),
                     lambda g: g["threads"][1].update(role="worker"), lambda g: g["threads"].pop())
        for mutate in mutations:
            report = report_fixture()
            mutate(report["samples"][14]["thread_cpu"])
            self.assert_invalid(report)
        for mutation in ("missing", "duplicate", "wrong-pid", "wrong-schema"):
            report = report_fixture()
            ready = next(event["event"] for event in report["events"] if event.get("type") == "app_event")
            registration = ready["snapshot"]["thread_cpu_registration"]
            if mutation == "missing":
                del ready["snapshot"]["thread_cpu_registration"]
            elif mutation == "duplicate":
                registration["roles"]["nio"] = 7
            elif mutation == "wrong-pid":
                registration["process_id"] = 999
            else:
                registration["schema_version"] = True
            with self.subTest(registration=mutation):
                self.assert_invalid(report)

    def test_uint64_counters_raw_conversion_and_regression(self):
        for key in ("user_cpu_ns", "system_cpu_ns", "user_cpu_raw", "system_cpu_raw", "thread_id"):
            for bad in (True, -1, 1 << 64, 1.5, None):
                report = report_fixture()
                report["samples"][14]["thread_cpu"]["threads"][0][key] = bad
                with self.subTest(key=key, bad=bad):
                    self.assert_invalid(report)
        report = report_fixture()
        group = report["samples"][14]["thread_cpu"]["threads"][0]
        group["user_cpu_ns"] = group["user_cpu_raw"] = 0
        self.assert_invalid(report)

    def test_brackets_timebase_and_process_counters_cannot_be_forged(self):
        for mutation in ("reversed", "outside", "too-wide", "timebase", "process-before", "process-after", "process-regress", "outer-cpu", "outer-identity"):
            report = report_fixture()
            sample = report["samples"][14]
            group = sample["thread_cpu"]
            if mutation == "reversed":
                group["read_begin_mach_ticks"] = group["read_end_mach_ticks"] + 1
            elif mutation == "outside":
                group["read_begin_mach_ticks"] = sample["mach_absolute_ticks"] - 1
            elif mutation == "too-wide":
                group["read_end_mach_ticks"] += 100_000_000
            elif mutation == "timebase":
                group["timebase"]["numer"] = 2
            elif mutation == "process-before":
                group["process_cpu_before_ns"] = 0
            elif mutation == "process-after":
                group["process_cpu_after_ns"] += 100_000_000
            elif mutation == "process-regress":
                group["process_cpu_after_ns"] = group["process_cpu_before_ns"] - 1
            elif mutation == "outer-cpu":
                sample["cpu_seconds"] += .1
            else:
                sample["process_id"] = 999
            with self.subTest(mutation=mutation):
                self.assert_invalid(report)

    def test_tracked_thread_cpu_cannot_exceed_process_cpu(self):
        report = report_fixture()
        for sample in report["samples"]:
            if "thread_cpu" in sample:
                row = sample["thread_cpu"]["threads"][0]
                row["user_cpu_ns"] *= 3
                row["user_cpu_raw"] *= 3
        self.assert_invalid(report)

    def test_bad_ready_exit_or_clock_bridge_cannot_qualify(self):
        for mutation in ("ready", "exit", "clock"):
            report = report_fixture()
            if mutation == "ready":
                report["events"] = [event for event in report["events"] if event.get("type") != "app_event"]
            elif mutation == "exit":
                report["events"][-1]["status"] = 1
            else:
                report["runtime"]["mach_clock_end"]["absolute_minus_monotonic_seconds"] += 1
            with self.subTest(mutation=mutation):
                self.assert_invalid(report)

    def test_narrow_phase_and_large_endpoint_uncertainty_are_unqualified(self):
        report = report_fixture()
        report["phase_windows"]["arrival"]["end_monotonic_seconds"] = 101.2
        self.assert_invalid(report)
        report = report_fixture()
        for index in (12, 19):
            report["samples"][index]["thread_cpu"]["process_cpu_after_ns"] += 3_000_000
        self.assert_invalid(report)

    def test_failure_after_runtime_is_reported_without_inventing_runtime_failure(self):
        report = report_fixture()
        group = report["samples"][31]["thread_cpu"]
        group.clear()
        group.update(available=False, reason="registered NIO thread already shut down")
        result = thread_cpu.analyze_report(report)
        self.assertEqual(result["status"], "available", result)
        self.assertEqual(result["outside_runtime_failures"][0]["sample_index"], 31)

    def test_analysis_does_not_mutate_the_case_or_independent_cpu_result(self):
        report = report_fixture()
        report["phase_cpu"] = {"existing": "untouched"}
        before = copy.deepcopy(report)
        thread_cpu.analyze_report(report)
        self.assertEqual(report, before)

    def test_microsecond_counter_quantization_is_kept_in_role_and_residual_bounds(self):
        report = report_fixture()
        row = report["samples"][19]["thread_cpu"]["threads"][0]
        row["user_cpu_ns"] += 999
        row["user_cpu_raw"] += 999
        result = thread_cpu.analyze_report(report)
        self.assertTrue(result["available"], result)
        self.assertEqual(result["thread_counter_resolution_ns"], 1000)
        steady = result["intervals"]["steady"]
        self.assertLess(steady["roles"]["main"]["average_cpu_percent_bounds"]["lower"], 4)
        self.assertGreater(steady["roles"]["main"]["average_cpu_percent_bounds"]["upper"], 4)
        self.assertLess(steady["residual"]["average_cpu_percent_bounds"]["lower"], 1)
        self.assertGreater(steady["residual"]["average_cpu_percent_bounds"]["upper"], 1)

    def test_later_app_snapshot_cannot_reassign_or_omit_registered_threads(self):
        for mutation in ("changed", "missing"):
            report = report_fixture()
            original = next(event for event in report["events"] if event.get("type") == "app_event")
            later = copy.deepcopy(original)
            later["event"]["type"] = "snapshot"
            if mutation == "changed":
                later["event"]["snapshot"]["thread_cpu_registration"]["roles"]["nio"] = 9
            else:
                del later["event"]["snapshot"]["thread_cpu_registration"]
            report["events"].insert(-1, later)
            self.assert_invalid(report)

    def test_calibration_requires_independent_positive_and_dead_thread_proof(self):
        for failure in ("missing", "duplicate", "position", "zero", "disagreement", "not-external", "dead-thread", "idle-busy", "tolerance", "conversion", "identity", "timebase"):
            report = report_fixture()
            proof = report["events"][0]["calibration"]
            if failure == "missing":
                report["events"].pop(0)
            elif failure == "duplicate":
                report["events"].insert(0, copy.deepcopy(report["events"][0]))
            elif failure == "position":
                report["events"].append(report["events"].pop(0))
            elif failure == "zero":
                proof["phases"][0]["thread_clock_delta_ns"] = 0
            elif failure == "disagreement":
                proof["phases"][1]["getrusage_delta_ns"] *= 3
            elif failure == "not-external":
                proof["external_owned_child"] = False
            elif failure == "dead-thread":
                proof["dead_thread_rejected"] = False
            elif failure == "idle-busy":
                proof["phases"][2]["thread_clock_delta_ns"] = 10_000_000
            elif failure == "tolerance":
                proof["tolerance_relative"] = 1
            elif failure == "conversion":
                proof["conversion_numer"] = 2
            elif failure == "identity":
                proof["process_id"] = True
            else:
                proof["timebase"]["numer"] = 2
            with self.subTest(failure=failure):
                self.assert_invalid(report)


if __name__ == "__main__":
    unittest.main()
