"""Authenticate independent metric bodies, including older frozen controls."""
import copy
import unittest

import memory_attribution as memory
import runtime_attribution as runtime
from test_runtime_held_usage import held_report


def snapshot():
    return copy.deepcopy(held_report("normal")["runtime"]["checkpoints"][0]["snapshot"])


def add_metrics(value, rate=1, gpu=1):
    scalar = value["graphics_diagnostics"]["scalar_presentation"]
    for entry in scalar["presentation_owners"].values():
        entry["metric_body_updates"] = {"rate": rate, "gpu": gpu}
    count = len(scalar["presentation_owners"])
    scalar["metric_body_updates"] = {"rate": rate * count, "gpu": gpu * count}
    return value


class MetricChildContractTests(unittest.TestCase):
    def test_older_control_has_unavailable_child_counts_not_zero(self):
        value = snapshot()
        contract = memory.scalar_presentation_contract(value, "normal")
        self.assertIsNone(contract["metric_body_updates"])
        self.assertIsNone(runtime.scalar_presentation_work(value, value, "normal")["metric_body_update_deltas"])

    def test_new_complete_owner_counts_and_runtime_deltas_are_authenticated(self):
        before, after = add_metrics(snapshot()), add_metrics(snapshot(), rate=4, gpu=2)
        self.assertEqual(memory.scalar_presentation_contract(before, "normal")["metric_body_updates"],
                         {"rate": 2, "gpu": 2})
        self.assertEqual(runtime.scalar_presentation_work(before, after, "normal")["metric_body_update_deltas"],
                         {"rate": 6, "gpu": 2})

    def test_every_child_counter_requires_complete_unsigned_inventory(self):
        for field in memory.SCALAR_METRICS:
            for bad in (None, True, -1, 1.0, "1", 2**64, "missing"):
                value = add_metrics(snapshot())
                raw = value["graphics_diagnostics"]["scalar_presentation"]["metric_body_updates"]
                if bad == "missing": del raw[field]
                else: raw[field] = bad
                with self.subTest(field=field, bad=bad), self.assertRaises(ValueError):
                    memory.scalar_presentation_contract(value, "normal")
        value = add_metrics(snapshot())
        value["graphics_diagnostics"]["scalar_presentation"]["metric_body_updates"]["other"] = 0
        with self.assertRaises(ValueError): memory.scalar_presentation_contract(value, "normal")

    def test_partial_owner_or_aggregate_metadata_cannot_claim_isolation(self):
        for missing in ("aggregate", "owner", "field"):
            value = add_metrics(snapshot())
            raw = value["graphics_diagnostics"]["scalar_presentation"]
            owner = next(iter(raw["presentation_owners"].values()))
            if missing == "aggregate": del raw["metric_body_updates"]
            elif missing == "owner": del owner["metric_body_updates"]
            else: del owner["metric_body_updates"]["rate"]
            with self.subTest(missing=missing), self.assertRaises(ValueError):
                memory.scalar_presentation_contract(value, "normal")

    def test_owner_counts_must_fit_within_aggregate_and_cannot_move_backwards(self):
        value = add_metrics(snapshot())
        raw = value["graphics_diagnostics"]["scalar_presentation"]
        next(iter(raw["presentation_owners"].values()))["metric_body_updates"]["rate"] += 1
        with self.assertRaises(ValueError): memory.scalar_presentation_contract(value, "normal")
        before, after = add_metrics(snapshot(), rate=4), add_metrics(snapshot(), rate=3)
        with self.assertRaises(ValueError): runtime.scalar_presentation_work(before, after, "normal")
        first = memory.scalar_presentation_contract(before, "normal")
        last = copy.deepcopy(first)
        next(iter(last["presentation_owners"].values()))["metric_body_updates"]["rate"] -= 1
        with self.assertRaises(ValueError): runtime.validate_metric_child_progress(first, last)

    def test_instrumentation_cannot_appear_or_disappear_within_one_lifetime(self):
        for before, after in ((snapshot(), add_metrics(snapshot())), (add_metrics(snapshot()), snapshot())):
            with self.assertRaises(ValueError): runtime.scalar_presentation_work(before, after, "normal")


if __name__ == "__main__": unittest.main()
