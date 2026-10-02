"""Deterministic synthetic visual-work evidence; no native captures."""
import copy
import unittest

import runtime_attribution as runtime


IDS = [{"index": 480000, "id": "52455346-0000-0007-0000-000000075300"},
       {"index": 480001, "id": "52455346-0000-0007-0000-000000075301"}]


def snapshot(count):
    return {"synthetic_request_identity": {"policy": "fixture-index-v1", "invalid_requests": 0,
                                          "requests": copy.deepcopy(IDS[:count])},
            "synthetic_animation_policy": "fixture-index-and-fixed-twinkle-seed-v1"}


def report():
    return {"runtime": {"checkpoints": [{"snapshot": snapshot(count)} for count in (0, 1, 2, 2)]},
            "ready": {"snapshot": snapshot(0)}, "checkpoints": [{"snapshot": snapshot(2)}],
            "events": [{"type": "app_event", "event": {"snapshot": snapshot(2)}}],
            "workload": {"fixture_start": {"expected_request_indices": [480000, 480001]},
                         "fixture_status": {"timing": {"streams": [{"request_index": 480001}, {"request_index": 480000}]}}}}


class VisualWorkTests(unittest.TestCase):
    def test_exact_namespace_seven_fixture_ids_are_authenticated(self):
        result = runtime.validate_visual_work(report(), required=True)
        self.assertTrue(result["available"])
        self.assertTrue(result["visual_comparison_eligible"])
        self.assertEqual(result["requests"], IDS)
        self.assertEqual(result["invalid_requests"], 0)

    def test_legacy_profile_is_explicitly_unavailable_but_compare_rejects(self):
        old = {"runtime": {"checkpoints": [{"snapshot": {}}, {"snapshot": {}}]}, "workload": {}}
        result = runtime.validate_visual_work(old, required=False)
        self.assertFalse(result["available"])
        self.assertFalse(result["visual_comparison_eligible"])
        with self.assertRaises((ValueError, KeyError)):
            runtime.validate_visual_work(old, required=True)

    def test_wrong_or_missing_policy_anywhere_fails_even_optional_profile(self):
        for location in ("runtime", "ready", "checkpoint", "event"):
            for field in ("synthetic_request_identity", "synthetic_animation_policy"):
                value = report()
                target = {"runtime": value["runtime"]["checkpoints"][1]["snapshot"],
                          "ready": value["ready"]["snapshot"], "checkpoint": value["checkpoints"][0]["snapshot"],
                          "event": value["events"][0]["event"]["snapshot"]}[location]
                del target[field]
                with self.subTest(location=location, field=field), self.assertRaises(ValueError):
                    runtime.validate_visual_work(value, required=False)
        value = report()
        value["runtime"]["checkpoints"][1]["snapshot"]["synthetic_animation_policy"] = "random"
        with self.assertRaisesRegex(ValueError, "animation seeding"):
            runtime.validate_visual_work(value, required=True)

    def test_invalid_or_fallback_identity_cannot_claim_reproducibility(self):
        for invalid in (1, True, -1, None):
            value = report()
            value["runtime"]["checkpoints"][2]["snapshot"]["synthetic_request_identity"]["invalid_requests"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                runtime.validate_visual_work(value, required=True)
        for field, invalid in (("id", "52455346-0000-0008-0000-000000075300"), ("index", 480002), ("index", True)):
            value = report()
            value["runtime"]["checkpoints"][1]["snapshot"]["synthetic_request_identity"]["requests"][0][field] = invalid
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_visual_work(value, required=True)

    def test_sorted_distinct_requests_and_zero_before_two_after_required(self):
        for kind in ("duplicate", "unsorted", "already-active", "missing-final", "disappeared"):
            value = report()
            points = value["runtime"]["checkpoints"]
            if kind == "duplicate":
                points[2]["snapshot"]["synthetic_request_identity"]["requests"] = [IDS[0], IDS[0]]
            elif kind == "unsorted":
                points[2]["snapshot"]["synthetic_request_identity"]["requests"].reverse()
            elif kind == "already-active":
                points[0]["snapshot"] = snapshot(1)
            elif kind == "missing-final":
                points[-1]["snapshot"] = snapshot(1)
            else:
                points[2]["snapshot"] = snapshot(0)
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                runtime.validate_visual_work(value, required=True)

    def test_acknowledged_indices_must_match_source_timing(self):
        for kind in ("stream", "ack", "duplicate", "bool", "large"):
            value = report()
            if kind == "stream":
                value["workload"]["fixture_status"]["timing"]["streams"][0]["request_index"] = 480002
            else:
                value["workload"]["fixture_start"]["expected_request_indices"] = {
                    "ack": [480000, 480002], "duplicate": [480000, 480000], "bool": [480000, True],
                    "large": [480000, 32_000_033]}[kind]
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                runtime.validate_visual_work(value, required=True)


if __name__ == "__main__":
    unittest.main()
