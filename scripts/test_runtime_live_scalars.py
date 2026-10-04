"""Live scalar version comparisons preserve geometry and resource eligibility."""
import unittest

import memory_attribution as memory
import runtime_attribution as runtime
import runtime_gpu_comparison as gpu
from test_runtime_frozen_scalars import scalar_report
from test_runtime_gpu_comparison import qualified_comparison


def live_rows(count=3):
    result = []
    for index in range(count):
        work = runtime.validate_scalar_presentation_checkpoints(scalar_report("normal"), "normal")
        work["leaf_body_update_deltas"] = dict.fromkeys(memory.SCALAR_LEAVES, 20 if index != 1 else 5)
        result.append({"label": ("reference-before", "candidate", "reference-after")[index],
                       "mode": "normal", "scalar_presentation_work": work})
    return result


class LiveScalarCPUComparisonTests(unittest.TestCase):
    def test_normal_versions_match_geometry_and_remain_cpu_eligible(self):
        rows = live_rows()
        result = runtime.validate_scalar_geometry_comparison(rows)
        self.assertTrue(result["available"])
        self.assertTrue(result["matching_critical_frames"])
        self.assertTrue(result["acceptance_eligible"])
        self.assertTrue(runtime.cpu_acceptance_eligible("normal"))
        self.assertEqual(rows[1]["scalar_presentation_work"]["leaf_body_update_deltas"]["metrics"], 5)

    def test_all_legacy_normal_metadata_absent_remains_optional(self):
        for rows in ([{"mode": "normal"}] * 3, [{"mode": "normal", "scalar_presentation_work": None}] * 3):
            self.assertIsNone(runtime.validate_scalar_geometry_comparison(rows))

    def test_partial_and_malformed_present_metadata_fail_closed(self):
        for invalid in (None, {}, False, [], "invalid"):
            rows = live_rows()
            rows[1]["scalar_presentation_work"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                runtime.validate_scalar_geometry_comparison(rows)
        for field in ("enabled", "critical_frames_by_role", "native_chart_geometry"):
            rows = live_rows()
            del rows[1]["scalar_presentation_work"][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_scalar_geometry_comparison(rows)

    def test_each_local_chart_window_size_and_backing_dimension_is_matched(self):
        for role, name, field in (("dashboard", "activity-chart", "width"),
                                  ("dashboard", "main-activity-plot", "x"),
                                  ("dashboard", "request-rail-band", "y"),
                                  ("popover", "main-activity-plot", "height"),
                                  ("popover", "native-window", "width")):
            rows = live_rows()
            rows[1]["scalar_presentation_work"]["critical_frames_by_role"][role][name][field] += 1
            with self.subTest(role=role, name=name, field=field), self.assertRaisesRegex(ValueError, "geometry"):
                runtime.validate_scalar_geometry_comparison(rows)
        for field in ("width", "height", "scale"):
            rows = live_rows()
            rows[-1]["scalar_presentation_work"]["native_chart_geometry"][0][field] += 1
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "geometry"):
                runtime.validate_scalar_geometry_comparison(rows)

    def test_missing_invalid_frames_and_falsely_held_normal_are_rejected(self):
        for fault in ("role", "anchor", "nan", "bool", "zero", "one-chart", "held"):
            rows = live_rows()
            work = rows[1]["scalar_presentation_work"]
            if fault == "role":
                del work["critical_frames_by_role"]["popover"]
            elif fault == "anchor":
                del work["critical_frames_by_role"]["dashboard"]["request-rail-band"]
            elif fault == "nan":
                work["critical_frames_by_role"]["dashboard"]["main-activity-plot"]["width"] = float("nan")
            elif fault == "bool":
                work["native_chart_geometry"][0]["scale"] = True
            elif fault == "zero":
                work["native_chart_geometry"][0]["width"] = 0
            elif fault == "one-chart":
                work["native_chart_geometry"].pop()
            else:
                work["enabled"] = True
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_scalar_geometry_comparison(rows)

    def test_matching_overflowing_local_extents_are_still_invalid(self):
        rows = live_rows()
        for row in rows:
            row["scalar_presentation_work"]["critical_frames_by_role"]["dashboard"]["main-activity-plot"].update(
                x=1.7e308, width=1.7e308)
        with self.assertRaisesRegex(ValueError, "malformed"):
            runtime.validate_scalar_geometry_comparison(rows)

    def test_window_origin_and_counter_savings_are_reported_without_changing_geometry(self):
        rows = live_rows()
        rows[1]["scalar_presentation_work"]["native_window_origins"][0]["by_role"]["popover"]["x"] += 100
        rows[1]["scalar_presentation_work"]["native_chart_geometry"].reverse()
        self.assertTrue(runtime.validate_scalar_geometry_comparison(rows)["matching_critical_frames"])
        self.assertEqual(rows[1]["scalar_presentation_work"]["native_window_origins"][0]["by_role"]["popover"]["x"], 200)

    def test_frozen_ablation_remains_ineligible_and_cannot_omit_its_proof(self):
        rows = live_rows()
        rows[1]["mode"] = memory.FROZEN_SCALARS_MODE
        rows[1]["scalar_presentation_work"] = runtime.validate_scalar_presentation_checkpoints(
            scalar_report(), memory.FROZEN_SCALARS_MODE)
        self.assertFalse(runtime.validate_scalar_geometry_comparison(rows)["acceptance_eligible"])
        rows[1]["scalar_presentation_work"] = None
        with self.assertRaisesRegex(ValueError, "mandatory"):
            runtime.validate_scalar_geometry_comparison(rows)


class LiveScalarGPUComparisonTests(unittest.TestCase):
    def report(self):
        result = qualified_comparison()
        for row, proof in zip(result["rows"], live_rows(2)):
            row.update(mode="normal", scalar_presentation_work=proof["scalar_presentation_work"])
        return result

    def test_calibrated_normal_pair_keeps_gpu_target_and_scalar_evidence(self):
        result = self.report()
        gpu.qualify_result(result)
        self.assertTrue(result["comparison_available"])
        self.assertTrue(result["scalar_geometry_comparison"]["matching_critical_frames"])
        self.assertTrue(result["rows"][1]["gpu_target"]["runtime"]["evaluated"])
        self.assertEqual(result["rows"][1]["gpu_target"]["runtime"]["limit_percent"], 1)
        self.assertEqual(result["rows"][1]["scalar_presentation_work"]["leaf_body_update_deltas"]["metrics"], 5)
        self.assertFalse(result["cpu_acceptance_eligible"])

    def test_old_all_absent_gpu_metadata_is_optional(self):
        result = qualified_comparison()
        for row in result["rows"]:
            row["mode"] = "normal"
        gpu.qualify_result(result)
        self.assertTrue(result["comparison_available"])
        self.assertNotIn("scalar_geometry_comparison", result)

    def test_partial_or_mismatched_paired_geometry_fails_closed(self):
        for fault in ("missing", "partial", "chart", "window", "backing"):
            result = self.report()
            row = result["rows"][1]
            if fault == "missing":
                del row["scalar_presentation_work"]
            elif fault == "partial":
                row["scalar_presentation_work"] = {}
            elif fault == "chart":
                row["scalar_presentation_work"]["critical_frames_by_role"]["popover"]["main-activity-plot"]["x"] += 1
            elif fault == "window":
                row["scalar_presentation_work"]["critical_frames_by_role"]["dashboard"]["native-window"]["height"] += 1
            else:
                row["scalar_presentation_work"]["native_chart_geometry"][0]["scale"] += 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                gpu.qualify_result(result)

    def test_single_gpu_capture_does_not_claim_a_paired_geometry_comparison(self):
        result = self.report()
        result.update(capture_case="candidate", rows=[result["rows"][1]])
        gpu.qualify_result(result)
        self.assertTrue(result["capture_available"])
        self.assertFalse(result["comparison_available"])
        self.assertNotIn("scalar_geometry_comparison", result)


if __name__ == "__main__":
    unittest.main()
