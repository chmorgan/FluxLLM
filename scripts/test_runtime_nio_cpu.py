"""Offline synthetic cumulative NIO scope accounting and failure checks."""
import copy
import unittest

import performance_fixture as fixture
import runtime_nio_cpu as nio
from test_runtime_thread_cpu import report_fixture as thread_fixture


def calibration():
    return {"available": True, "clock": "CLOCK_THREAD_CPUTIME_ID", "iterations": 1000,
            "pair_cpu_ns": 100_000, "pair_wall_ns": 110_000,
            "empty_scope_cpu_ns": 200_000, "empty_scope_wall_ns": 220_000,
            "empty_scope_measured_ns": 90_000}


def report_fixture():
    report = thread_fixture()
    report["workload"].update(specification={"activity": "high-rate", "seconds": 25},
        fixture_start={"expected_request_indices": [480000, 480001], "expected_chunks": 10000},
        fixture_status={"timing": {"streams": [{"records_observed": 5001}, {"records_observed": 5001}]}})
    payload = sum(len(fixture.encoded(fixture.record(index, chunk, 5000, 25)))
                  for index in (480000, 480001) for chunk in range(5001))
    registration = {"schema_version": 1, "process_id": 123, "roles": {"main": 7, "nio": 8}}
    def snapshot(timestamp, sequence):
        progress = max(0, min(1, (timestamp - 100.45) / 7))
        records = round(progress * 10002)
        body_bytes, payload_bytes = round(progress * (payload + 10002)), round(progress * payload)
        values = {name: {key: 0 for key in nio.FIELDS} for name in nio.METRICS}
        for name, cost in (("upstream_read", 1200), ("forwarding", 200), ("coalescer", 100),
                           ("framing", 100), ("json_decode", 200), ("interpretation", 100), ("relay_update", 100)):
            values[name].update(calls=records, cpu_ns=records * cost)
        for name in ("forwarding", "coalescer", "framing"):
            values[name]["bytes"] = body_bytes
        for name in ("framing", "json_decode", "interpretation", "relay_update"):
            values[name]["records"] = records
        values["json_decode"]["bytes"] = payload_bytes
        values["forwarding"]["bodies"] = records
        values["forwarding"]["ends"] = 2 if progress == 1 else 0
        values["framing"]["bodies"] = records
        values["framing"]["ends"] = values["forwarding"]["ends"]
        values["framing"]["calls"] += values["framing"]["ends"]
        values["upstream_read_complete"].update(calls=records, cpu_ns=records * 10)
        values["relay_scheduled"].update(calls=round(progress * 100), cpu_ns=round(progress * 100) * 100)
        own_cpu = 500_000_000 + round((timestamp - 100) * 20_000_000)
        return {"thread_cpu_registration": copy.deepcopy(registration), "dashboard_visible": True,
                "popover_visible": True, "nio_cpu": {"schema_version": 1, "available": True,
                "process_id": 123, "thread_id": 8, "sequence": sequence,
                "capture_begin_mach_ticks": round((timestamp + 10) * 1e9),
                "capture_end_mach_ticks": round((timestamp + 10) * 1e9) + 1000,
                "thread_cpu_before_ns": own_cpu, "thread_cpu_after_ns": own_cpu + 100,
                "clock_reads": 4004 + 2 * (sequence + sum(value["calls"] for value in values.values())),
                "calibration": calibration(), "metrics": values}}
    ready = next(event["event"] for event in report["events"] if event.get("type") == "app_event")
    ready["snapshot"] = snapshot(100.26, 1)
    points, extra = [], []
    for sequence, timestamp in enumerate((100.45, 101.3, 102.3, 103.3, 104.3, 105.3, 106.3, 107.45), 2):
        snap = snapshot(timestamp, sequence)
        extra.append({"type": "app_event", "event": {"type": "ack", "snapshot": copy.deepcopy(snap)}})
        sample = next(sample for sample in report["samples"] if sample["mach_absolute_seconds"] > timestamp + 10.001)
        snap["runner_collector_sample_monotonic_seconds"] = sample["monotonic_seconds"]
        label = "before-traffic" if sequence == 2 else "completion-end" if sequence == 9 else "during-traffic"
        points.append({"snapshot": snap, "resource_sample": sample, "label": label})
    report["events"][-1:-1] = extra
    report["runtime"]["checkpoints"] = points
    return report


class NIOCPUAccountingTests(unittest.TestCase):
    def setUp(self):
        self.report = report_fixture()

    def assert_invalid(self, report=None):
        result = nio.analyze_report(report or self.report, required=True)
        self.assertFalse(result["available"], result)
        self.assertEqual(result["status"], "invalid", result)
        self.assertFalse(result["acceptance_eligible"])
        self.assertTrue(result["errors"])
        return result

    def mutate_capture(self, index, mutation):
        point = self.report["runtime"]["checkpoints"][index]
        value = point["snapshot"]["nio_cpu"]
        mutation(value)
        original = next(event["event"]["snapshot"] for event in self.report["events"]
                        if event.get("type") == "app_event" and event.get("event", {}).get("type") == "ack"
                        and event["event"]["snapshot"]["nio_cpu"]["sequence"] == index + 2)
        original["nio_cpu"] = copy.deepcopy(value)

    def test_actual_boundaries_independent_clock_and_exact_bytes(self):
        result = nio.analyze_report(self.report, required=True)
        self.assertTrue(result["available"], result)
        self.assertEqual(result["exact_work"]["records"], 10002)
        self.assertEqual(result["exact_work"]["body_bytes"], 2056770)
        self.assertEqual(result["exact_work"]["json_payload_bytes"], 2046768)
        self.assertIn("superset", result["intervals"]["arrival"]["scope"])
        self.assertEqual(result["intervals"]["arrival"]["start_checkpoint"]["label"], "before-traffic")
        steady = result["intervals"]["steady"]
        self.assertAlmostEqual(steady["actual_window"]["elapsed_seconds_bounds"]["lower"], .999999)
        self.assertTrue(steady["external_thread_check"]["consistent"])
        self.assertLess(steady["external_thread_check"]["cpu_ns_bounds"]["lower"], 20_000_000)
        self.assertGreater(steady["external_thread_check"]["cpu_ns_bounds"]["upper"], 20_000_000)
        self.assertFalse(result["rolling_1s_attribution"]["available"])
        self.assertFalse(result["acceptance_eligible"])
        self.assertIn("nested", "\n".join(nio.render_summary(result)))

    def test_nested_scopes_are_not_double_counted(self):
        result = nio.analyze_report(self.report, required=True)
        whole = result["intervals"]["whole_contiguous_runtime"]
        self.assertEqual(whole["disjoint_top_level_cpu_ns"], sum(whole["metrics"][name]["cpu_ns"] for name in nio.TOP_LEVEL))
        self.assertEqual(whole["unassigned_thread"]["cpu_ns_bounds"]["lower"],
                         whole["whole_thread"]["cpu_ns_bounds"]["lower"] - whole["disjoint_top_level_cpu_ns"])

    def test_missing_optional_and_required_are_distinct(self):
        for point in self.report["runtime"]["checkpoints"]:
            del point["snapshot"]["nio_cpu"]
        self.assertEqual(nio.analyze_report(self.report)["status"], "unavailable")
        self.assert_invalid()

    def test_snapshot_mutation_or_missing_event_fails_closed(self):
        self.report["runtime"]["checkpoints"][3]["snapshot"]["nio_cpu"]["clock_reads"] += 1
        self.assert_invalid()
        self.report = report_fixture()
        del self.report["events"][4]
        self.assert_invalid()

    def test_registration_clock_and_calibration_failures(self):
        mutations = (lambda value: value.update(available=False), lambda value: value.update(process_id=124),
                     lambda value: value.update(thread_id=7), lambda value: value.update(schema_version=True),
                     lambda value: value.update(capture_end_mach_ticks=value["capture_begin_mach_ticks"] - 1),
                     lambda value: value.update(thread_cpu_before_ns=value["thread_cpu_after_ns"] + 1),
                     lambda value: value["calibration"].update(clock="sampled"),
                     lambda value: value.update(sequence=1), lambda value: value.update(clock_reads=0))
        for mutation in mutations:
            self.report = report_fixture()
            self.mutate_capture(3, mutation)
            self.assert_invalid()

    def test_negative_backward_and_nesting_violation_counters(self):
        mutations = (lambda value: value["metrics"]["json_decode"].update(calls=-1),
                     lambda value: value["metrics"]["json_decode"].update(cpu_ns=0),
                     lambda value: value["metrics"]["json_decode"].update(cpu_ns=1 << 64),
                     lambda value: value["metrics"]["coalescer"].update(cpu_ns=50_000_000),
                     lambda value: value["metrics"]["forwarding"].update(cpu_ns=50_000_000))
        for mutation in mutations:
            self.report = report_fixture()
            self.mutate_capture(3, mutation)
            self.assert_invalid()

    def test_exact_count_or_bytes_mismatch_fails(self):
        for metric, field in (("framing", "records"), ("json_decode", "records"), ("forwarding", "bytes"),
                              ("coalescer", "bytes"), ("json_decode", "bytes"), ("forwarding", "ends"),
                              ("forwarding", "bodies")):
            self.report = report_fixture()
            self.mutate_capture(7, lambda value: value["metrics"][metric].update({field: value["metrics"][metric][field] + 1}))
            self.assert_invalid()

    def test_independent_external_delta_disagreement_fails(self):
        for index in range(len(self.report["runtime"]["checkpoints"])):
            self.mutate_capture(index, lambda value: value.update(
                thread_cpu_before_ns=value["thread_cpu_before_ns"] * 2,
                thread_cpu_after_ns=value["thread_cpu_after_ns"] * 2))
        result = self.assert_invalid()
        self.assertIn("independently calibrated", result["errors"][0])

    def test_internal_cpu_oversubscription_fails(self):
        self.mutate_capture(7, lambda value: value["metrics"]["relay_scheduled"].update(cpu_ns=200_000_000))
        result = self.assert_invalid()
        self.assertIn("exceed same-thread", result["errors"][0])

    def test_missing_external_thread_evidence_is_not_zero(self):
        self.report["samples"][14]["thread_cpu"]["available"] = False
        self.assert_invalid()

    def test_reordered_or_wrong_process_checkpoint_is_invalid(self):
        self.report["runtime"]["checkpoints"][3]["resource_sample"] = self.report["samples"][2]
        self.assert_invalid()

    def test_calibration_costs_are_reported_without_subtraction(self):
        result = nio.analyze_report(self.report, required=True)
        self.assertEqual(result["calibration"], calibration())
        self.assertIn("never subtracted", result["inclusion"]["calibration"])
        self.assertEqual(result["intervals"]["whole_contiguous_runtime"]["metrics"]["coalescer"]["cpu_ns"], 1000200)


if __name__ == "__main__":
    unittest.main()
