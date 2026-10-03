"""Native twinkle work proof uses authenticated steady kernel boundaries."""
import copy
import unittest

import memory_attribution as memory
import runtime_attribution as runtime
from test_runtime_attribution import clock_work_report
from test_memory_diagnostic import graphics


MODE = "runtime-canvas-clock"


def delivery_report():
    report = clock_work_report(MODE)
    for index, point in enumerate(report["runtime"]["checkpoints"]):
        snapshot = point["snapshot"]
        snapshot["graphics_diagnostics"]["direct_retained_twinkle_delivery"] = True
        snapshot.update(retained_twinkle_direct_updates=index * 2, twinkle_state_publications=0)
    return report


class TwinkleDeliveryTests(unittest.TestCase):
    def test_positive_direct_delivery_and_zero_state_use_exact_steady_boundaries(self):
        report = delivery_report()
        result = runtime.validate_steady_twinkle_delivery(report, MODE)
        self.assertTrue(result["available"])
        self.assertTrue(result["enabled"])
        self.assertEqual((result["start_checkpoint"], result["end_checkpoint"]), ("during-6", "during-19"))
        self.assertEqual((result["start_monotonic_seconds"], result["end_monotonic_seconds"]), (106, 119))
        self.assertEqual(result["deltas"], {"retained_twinkle_direct_updates": 2, "twinkle_state_publications": 0})
        self.assertEqual(result["start_resource_sample"], report["runtime"]["checkpoints"][1]["resource_sample"])

    def test_old_reference_is_explicitly_unavailable_never_zero(self):
        result = runtime.validate_steady_twinkle_delivery(clock_work_report(MODE), MODE)
        self.assertFalse(result["available"])
        self.assertNotIn("deltas", result)
        self.assertIn("predates", result["reason"])

    def test_instrumented_counters_require_complete_uint64_values(self):
        for field in memory.TWINKLE_DELIVERY_COUNTERS:
            for bad in (None, True, -1, 2**64):
                report = delivery_report()
                report["runtime"]["checkpoints"][1]["snapshot"][field] = bad
                with self.subTest(field=field, bad=bad), self.assertRaises(ValueError):
                    runtime.validate_steady_twinkle_delivery(report, MODE)

    def test_counter_or_backend_disappearance_is_invalid(self):
        for mutation in ("metadata", "all"):
            report = delivery_report()
            snapshot = report["runtime"]["checkpoints"][1]["snapshot"]
            del snapshot["graphics_diagnostics"]["direct_retained_twinkle_delivery"]
            if mutation == "all":
                for field in memory.TWINKLE_DELIVERY_COUNTERS:
                    del snapshot[field]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                runtime.validate_steady_twinkle_delivery(report, MODE)

    def test_regressing_counters_are_rejected_even_outside_steady(self):
        for field in memory.TWINKLE_DELIVERY_COUNTERS:
            report = delivery_report()
            points = report["runtime"]["checkpoints"]
            points[0]["snapshot"][field] = 100
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "moved backwards"):
                runtime.validate_steady_twinkle_delivery(report, MODE)

    def test_missing_actual_direct_deliveries_is_rejected(self):
        report = delivery_report()
        for point in report["runtime"]["checkpoints"]:
            point["snapshot"]["retained_twinkle_direct_updates"] = 0
        with self.assertRaisesRegex(ValueError, "did not execute native"):
            runtime.validate_steady_twinkle_delivery(report, MODE)

    def test_steady_swiftui_publication_is_rejected_but_lifecycle_publication_is_allowed(self):
        report = delivery_report()
        points = report["runtime"]["checkpoints"]
        points[-1]["snapshot"]["twinkle_state_publications"] = 1
        self.assertTrue(runtime.validate_steady_twinkle_delivery(report, MODE)["available"])
        points[-2]["snapshot"]["twinkle_state_publications"] = 1
        with self.assertRaisesRegex(ValueError, "still published SwiftUI"):
            runtime.validate_steady_twinkle_delivery(report, MODE)

    def test_short_or_edge_only_steady_interval_cannot_claim_delivery(self):
        report = delivery_report()
        report["phase_windows"]["steady"] = {"start_monotonic_seconds": 106, "end_monotonic_seconds": 119}
        with self.assertRaisesRegex(ValueError, "two seconds"):
            runtime.validate_steady_twinkle_delivery(report, MODE)
        report = delivery_report()
        report["runtime"]["checkpoints"][2]["resource_sample"]["mach_absolute_seconds"] = 1007
        with self.assertRaisesRegex(ValueError, "two seconds"):
            runtime.validate_steady_twinkle_delivery(report, MODE)

    def test_visibility_active_work_and_resource_identity_are_required(self):
        for failure in ("hidden", "idle", "unpaired", "identity"):
            report = delivery_report()
            point = report["runtime"]["checkpoints"][1]
            if failure == "hidden":
                point["snapshot"]["dashboard_visible"] = False
            elif failure == "idle":
                point["snapshot"]["active_requests"] = 0
            elif failure == "unpaired":
                point["resource_sample"] = copy.deepcopy(point["resource_sample"])
                point["resource_sample"]["mach_absolute_seconds"] += 1
            else:
                point["resource_sample"]["birth_time_us"] += 1
            with self.subTest(failure=failure), self.assertRaises(ValueError):
                runtime.validate_steady_twinkle_delivery(report, MODE)

    def test_nonretained_metadata_requires_zero_direct_delivery(self):
        snapshot = graphics("empty-drawing")
        snapshot["graphics_diagnostics"]["direct_retained_twinkle_delivery"] = False
        snapshot.update(retained_twinkle_direct_updates=0, twinkle_state_publications=3)
        self.assertFalse(memory.twinkle_delivery_contract(snapshot, "empty-drawing")["enabled"])
        snapshot["retained_twinkle_direct_updates"] = 1
        with self.assertRaisesRegex(ValueError, "Nonretained"):
            memory.twinkle_delivery_contract(snapshot, "empty-drawing")


if __name__ == "__main__":
    unittest.main()
