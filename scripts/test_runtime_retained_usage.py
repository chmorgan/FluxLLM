"""Opt-in retained live usage proofs without native operations."""
import copy
import unittest
from unittest.mock import Mock, patch

import memory_attribution as memory
import runtime_attribution as runtime
import runtime_gpu_comparison as gpu
from test_runtime_attribution import options
from test_runtime_frozen_scalars import OWNER_IDS, scalar_report
from test_runtime_held_usage import BASE_USAGE, EPOCH, add_held_usage_metadata, held_report
from test_runtime_gpu_comparison import qualified_comparison


def applied_fields(values):
    input_value = "—" if values["input_tokens"] is None else f"{values['input_tokens']:,}" + ("+" if values["unknown_input_requests"] else "")
    input_help = (f"Input usage is unavailable for {values['unknown_input_requests']} requests. A + marks the known subtotal."
                  if values["unknown_input_requests"] else "Input tokens reported by the backend.")
    badge = "Partial history" if values["is_partial"] else f"{values['active_requests']} active" if values["active_requests"] else ""
    return {"input": {"value": input_value, "help": input_help},
            "output": {"value": ("~" if values["output_is_estimated"] else "") + f"{values['output_tokens']:,}", "help": ""},
            "tools": {"value": f"{values['tool_calls']:,}", "help": "Observed calls, excluding submitted results; this does not measure execution success."},
            "requests": {"value": f"{values['requests']:,}", "help": ""}, "badge": {"value": badge, "help": ""}}


def add_retained_metadata(snapshot, mode, *, present=False, closed=False, applies=5, skips=0):
    value = snapshot["graphics_diagnostics"]
    add_held_usage_metadata(snapshot, mode, closed=closed)
    value.update(retained_usage_fields=mode == memory.RETAINED_USAGE_MODE,
                 scalar_instrumentation_enabled=mode in ("normal", memory.RETAINED_USAGE_MODE))
    enabled = mode == memory.RETAINED_USAGE_MODE
    raw = dict.fromkeys(memory.RETAINED_USAGE_COUNTERS + memory.RETAINED_USAGE_GAUGES, 0)
    raw.update(enabled=enabled, owners={})
    if enabled and present:
        raw.update(hosts_created=5, hosts_destroyed=5 if closed else 0, current_owners=0 if closed else 1,
                   peak_owners=1, value_apply_attempts=applies + skips, value_applies=applies, value_apply_skips=skips)
        if not closed:
            raw["owners"][OWNER_IDS[0]] = {"role": "dashboard", "epoch": EPOCH, "scope": "sinceLaunch",
                                           "values": copy.deepcopy(BASE_USAGE), "fields": applied_fields(BASE_USAGE)}
    value["retained_usage"] = raw
    return snapshot


def retained_report(mode=memory.RETAINED_USAGE_MODE):
    report = held_report("normal")
    for index, point in enumerate(report["runtime"]["checkpoints"] + report["checkpoints"]):
        snapshot = point["snapshot"]
        existing = copy.deepcopy(snapshot["graphics_diagnostics"]["scalar_presentation"]["presentation_owners"])
        closed = not snapshot["dashboard_visible"]
        add_retained_metadata(snapshot, mode, present=True, closed=closed,
                              applies=5 + min(index, 6) * 3, skips=min(index, 6) * 2)
        snapshot["graphics_diagnostics"]["scalar_presentation"]["presentation_owners"] = existing
        for entry in existing.values():
            if entry["role"] != "dashboard": continue
            usage = entry["presented_values"]["dashboard_usage"]["values"]
            usage["output_is_estimated"] = snapshot["active_requests"] == 2
            if index >= 4:
                usage.update(input_tokens=146, tool_calls=4)
            if mode == memory.RETAINED_USAGE_MODE:
                owner = snapshot["graphics_diagnostics"]["retained_usage"]["owners"][OWNER_IDS[0]]
                owner["values"], owner["fields"] = copy.deepcopy(usage), applied_fields(usage)
    return report


def retained_rows(count=3):
    rows = []
    for mode in ("normal", memory.RETAINED_USAGE_MODE, "normal")[:count]:
        report = retained_report(mode)
        rows.append({"mode": mode, "scalar_presentation_work": runtime.validate_scalar_presentation_checkpoints(report, mode),
                     "retained_usage_work": runtime.validate_retained_usage_checkpoints(report, mode)})
    return rows


class RetainedUsageContractTests(unittest.TestCase):
    def test_one_owner_five_applied_hosts_are_live_and_candidate_cpu_is_eligible(self):
        snapshot = retained_report()["runtime"]["checkpoints"][0]["snapshot"]
        value = memory.retained_usage_contract(snapshot, memory.RETAINED_USAGE_MODE, require_live=True)
        self.assertEqual(len(value["owners"]), 1)
        self.assertEqual(value["counters"]["hosts_created"] - value["counters"]["hosts_destroyed"], 5)
        self.assertTrue(runtime.cpu_acceptance_eligible(memory.RETAINED_USAGE_MODE))
        self.assertTrue(value["acceptance_eligible"])
        self.assertFalse(value["promotion_eligible"])

    def test_legacy_normal_and_frozen_metadata_remain_optional_but_partial_retained_fails(self):
        for mode in ("normal", memory.FROZEN_SCALARS_MODE):
            self.assertIsNone(memory.retained_usage_contract(scalar_report(mode)["runtime"]["checkpoints"][0]["snapshot"], mode))
        for field in ("retained_usage_fields", "retained_usage"):
            snapshot = retained_report("normal")["runtime"]["checkpoints"][0]["snapshot"]
            del snapshot["graphics_diagnostics"][field]
            with self.subTest(field=field), self.assertRaises(ValueError): memory.retained_usage_contract(snapshot, "normal")

    def test_candidate_flag_and_every_unsigned_counter_are_complete(self):
        for field in memory.RETAINED_USAGE_COUNTERS + memory.RETAINED_USAGE_GAUGES:
            for invalid in ("missing", None, True, -1, 1.0, "1", 2**64):
                snapshot = retained_report()["runtime"]["checkpoints"][0]["snapshot"]
                raw = snapshot["graphics_diagnostics"]["retained_usage"]
                if invalid == "missing": del raw[field]
                else: raw[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    memory.retained_usage_contract(snapshot, memory.RETAINED_USAGE_MODE)
        for invalid in (None, False, 1, "true"):
            snapshot = retained_report()["runtime"]["checkpoints"][0]["snapshot"]
            snapshot["graphics_diagnostics"]["retained_usage_fields"] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(ValueError): memory.retained_usage_contract(snapshot, memory.RETAINED_USAGE_MODE)

    def test_host_lifetimes_apply_reconciliation_and_inactive_work_fail_closed(self):
        for fault in ("hosts", "owners", "peak", "attempts", "normal"):
            mode = "normal" if fault == "normal" else memory.RETAINED_USAGE_MODE
            snapshot = retained_report(mode)["runtime"]["checkpoints"][0]["snapshot"]
            raw = snapshot["graphics_diagnostics"]["retained_usage"]
            if fault == "hosts": raw["hosts_created"] = 4
            elif fault == "owners": raw["current_owners"] = 0
            elif fault == "peak": raw["peak_owners"] = 2
            elif fault == "attempts": raw["value_apply_attempts"] += 1
            else: raw["value_applies"] = raw["value_apply_attempts"] = 1
            with self.subTest(fault=fault), self.assertRaises(ValueError): memory.retained_usage_contract(snapshot, mode)

    def test_owner_epoch_role_scope_field_inventory_and_values_are_authenticated(self):
        for fault in ("owner", "epoch", "role", "scope", "field", "field-shape", "value", "unknown", "bounded"):
            snapshot = retained_report()["runtime"]["checkpoints"][0]["snapshot"]
            raw = snapshot["graphics_diagnostics"]["retained_usage"]
            entry = raw["owners"][OWNER_IDS[0]]
            if fault == "owner": raw["owners"]["bad"] = raw["owners"].pop(OWNER_IDS[0])
            elif fault == "epoch": entry["epoch"] = OWNER_IDS[1]
            elif fault == "role": entry["role"] = "popover"
            elif fault == "scope": entry["scope"] = "invalid"
            elif fault == "field": del entry["fields"]["badge"]
            elif fault == "field-shape": del entry["fields"]["input"]["help"]
            elif fault == "value": entry["values"]["requests"] = True
            elif fault == "unknown": entry["extra"] = 1
            else: entry["fields"]["input"]["value"] = "x" * 4097
            with self.subTest(fault=fault), self.assertRaises(ValueError): memory.retained_usage_contract(snapshot, memory.RETAINED_USAGE_MODE)

    def test_input_estimate_partial_active_and_help_display_semantics_match(self):
        for changes in ({"input_tokens": None}, {"unknown_input_requests": 2}, {"output_is_estimated": True},
                        {"is_partial": True, "active_requests": 2}, {"active_requests": 2}):
            values = BASE_USAGE | changes
            runtime.validate_retained_applied_fields({"values": values, "fields": applied_fields(values)})
        for field in memory.RETAINED_USAGE_FIELDS:
            entry = {"values": copy.deepcopy(BASE_USAGE), "fields": applied_fields(BASE_USAGE)}
            entry["fields"][field]["value"] = "wrong"
            with self.subTest(field=field), self.assertRaises(ValueError): runtime.validate_retained_applied_fields(entry)
        entry = {"values": copy.deepcopy(BASE_USAGE), "fields": applied_fields(BASE_USAGE)}
        entry["fields"]["tools"]["help"] = "wrong"
        with self.assertRaises(ValueError): runtime.validate_retained_applied_fields(entry)

    def test_only_exact_pending_owner_is_allowed_during_warmup_and_never_measured(self):
        snapshot = retained_report()["runtime"]["checkpoints"][0]["snapshot"]
        raw = snapshot["graphics_diagnostics"]["retained_usage"]
        raw.update(hosts_created=1, value_apply_attempts=0, value_applies=0, value_apply_skips=0)
        raw["owners"][OWNER_IDS[0]].update(epoch=None, scope=None, values={}, fields={})
        self.assertTrue(memory.retained_usage_contract(snapshot, memory.RETAINED_USAGE_MODE)["enabled"])
        with self.assertRaises(ValueError): memory.retained_usage_contract(snapshot, memory.RETAINED_USAGE_MODE, require_live=True)
        raw["owners"][OWNER_IDS[0]]["fields"] = {"input": {"value": "100", "help": ""}}
        with self.assertRaises(ValueError): memory.retained_usage_contract(snapshot, memory.RETAINED_USAGE_MODE)


class RetainedUsageRuntimeTests(unittest.TestCase):
    def test_live_callback_values_geometry_cadence_and_quiet_cleanup_pass(self):
        for mode in ("normal", memory.RETAINED_USAGE_MODE):
            work = runtime.validate_retained_usage_checkpoints(retained_report(mode), mode)
            self.assertTrue(work["acceptance_eligible"])
            self.assertTrue(work["live_unrelated_fields_verified"])
            self.assertEqual(work["closed_live_hosts"], 0)
            self.assertEqual(work["live_compact_response_final_count"], 10017)
            if mode == memory.RETAINED_USAGE_MODE:
                self.assertTrue(work["actually_applied_usage_verified"])
                self.assertEqual(work["counter_deltas"]["hosts_destroyed"], 5)
                self.assertGreater(work["counter_deltas"]["value_applies"], 0)

    def test_interior_owner_epoch_recreation_missing_or_regressing_counter_fails(self):
        for fault in ("owner", "epoch", "recreate", "missing", "counter"):
            report = retained_report()
            value = report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]
            raw = value["retained_usage"]
            if fault == "owner": raw["owners"][OWNER_IDS[1]] = raw["owners"].pop(OWNER_IDS[0])
            elif fault == "epoch": raw["owners"][OWNER_IDS[0]]["epoch"] = value["held_usage"]["monitoring_epoch"] = OWNER_IDS[1]
            elif fault == "recreate": raw["hosts_created"] += 5; raw["hosts_destroyed"] += 5
            elif fault == "missing": del value["retained_usage"]
            else: raw["value_applies"] = 4; raw["value_apply_attempts"] = 4 + raw["value_apply_skips"]
            with self.subTest(fault=fault), self.assertRaises(ValueError): runtime.validate_retained_usage_checkpoints(report, memory.RETAINED_USAGE_MODE)

    def test_applied_labels_are_verified_against_actual_display_and_exact_final_accounting(self):
        for fault in ("label", "witness", "active", "final-input", "final-tools", "final-requests", "estimate", "flat-applies"):
            report = retained_report()
            index = 6 if fault.startswith("final-") or fault == "estimate" else 3
            value = report["runtime"]["checkpoints"][index]["snapshot"]["graphics_diagnostics"]
            entry = value["retained_usage"]["owners"][OWNER_IDS[0]]
            witness = value["scalar_presentation"]["presentation_owners"][OWNER_IDS[0]]["presented_values"]["dashboard_usage"]["values"]
            if fault == "label": entry["fields"]["output"]["value"] = "999"
            elif fault == "witness": witness["output_tokens"] += 1
            elif fault == "flat-applies":
                for point in report["runtime"]["checkpoints"]:
                    raw = point["snapshot"]["graphics_diagnostics"]["retained_usage"]
                    raw["value_applies"] = 5; raw["value_apply_attempts"] = 5 + raw["value_apply_skips"]
            else:
                field = {"active": "active_requests", "final-input": "input_tokens", "final-tools": "tool_calls",
                         "final-requests": "requests", "estimate": "output_is_estimated"}[fault]
                entry["values"][field] = True if fault == "estimate" else 0 if fault == "active" else entry["values"][field] - 1
                witness[field] = entry["values"][field]
                entry["fields"] = applied_fields(entry["values"])
            with self.subTest(fault=fault), self.assertRaises(ValueError): runtime.validate_retained_usage_checkpoints(report, memory.RETAINED_USAGE_MODE)

    def test_compact_unrelated_headers_rates_chart_geometry_and_per_chart_cadence_remain_live(self):
        for fault in ("compact", "header", "rate", "geometry", "cadence", "glints"):
            report = retained_report()
            value = report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]
            owner = value["scalar_presentation"]["presentation_owners"][OWNER_IDS[1]]
            if fault == "compact": owner["presented_values"]["compact_details"]["response"] = "~1000"
            elif fault == "header": owner["presented_values"]["header"]["status"] = "Idle"
            elif fault == "rate": owner["presented_values"]["metrics"]["rate"] = "0.0"
            elif fault == "geometry": value["native_canvas_frames"]["1"]["scale"] += 1
            elif fault == "cadence":
                for point in report["runtime"]["checkpoints"]: point["snapshot"]["graphics_diagnostics"]["native_canvas_draws"]["2"] = 0
            else: value["retained_twinkles"]["animation_starts"] = 4
            with self.subTest(fault=fault), self.assertRaises(ValueError): runtime.validate_retained_usage_checkpoints(report, memory.RETAINED_USAGE_MODE)

    def test_closed_leaks_missing_release_growth_missing_checkpoint_or_short_quiet_period_fail(self):
        for fault in ("owner", "release", "growth", "missing", "short"):
            report = retained_report()
            last = report["checkpoints"][-1]
            raw = last["snapshot"]["graphics_diagnostics"]["retained_usage"]
            if fault == "owner": raw["owners"] = copy.deepcopy(report["runtime"]["checkpoints"][0]["snapshot"]["graphics_diagnostics"]["retained_usage"]["owners"])
            elif fault == "release": raw["hosts_destroyed"] = 4
            elif fault == "growth": raw["value_applies"] += 1; raw["value_apply_attempts"] += 1
            elif fault == "missing": report["checkpoints"].pop()
            else: last["resource_sample"]["mach_absolute_seconds"] -= 1
            with self.subTest(fault=fault), self.assertRaises(ValueError): runtime.validate_retained_usage_checkpoints(report, memory.RETAINED_USAGE_MODE)

    def test_cpu_matrix_requires_one_normal_retained_normal_same_product_bracket(self):
        self.assertEqual(runtime.selected_cases(options(baseline_mode="normal", controls=[memory.RETAINED_USAGE_MODE]))[1],
                         (memory.RETAINED_USAGE_MODE, memory.RETAINED_USAGE_MODE))
        for args in (options(baseline_mode="native-gpu-optimized", controls=[memory.RETAINED_USAGE_MODE]),
                     options(baseline_mode="normal", controls=[memory.RETAINED_USAGE_MODE, memory.HELD_USAGE_MODE]),
                     options(baseline_mode=memory.RETAINED_USAGE_MODE, controls=["normal"])):
            with self.subTest(args=args), self.assertRaises(ValueError): runtime.selected_cases(args)
        self.assertTrue(runtime.validate_scalar_geometry_comparison(retained_rows())["acceptance_eligible"])
        for field in ("retained_usage_work", "scalar_presentation_work"):
            rows = retained_rows(); del rows[1][field]
            with self.subTest(field=field), self.assertRaises(ValueError): runtime.validate_scalar_geometry_comparison(rows)

    def test_candidate_never_sends_a_freeze_command(self):
        diagnostic = object.__new__(runtime.RuntimeDiagnostic)
        diagnostic.graphics_mode, diagnostic.runtime, diagnostic.profile_enabled = memory.RETAINED_USAGE_MODE, {}, False
        diagnostic.command, diagnostic.runtime_checkpoint = Mock(), Mock()
        with patch.object(runtime, "_mach_clock", return_value={"absolute_minus_monotonic_seconds": 900}): diagnostic.begin_runtime()
        diagnostic.command.assert_not_called()
        diagnostic.runtime_checkpoint.assert_called_once_with("before-traffic")


class RetainedUsageGPUQualificationTests(unittest.TestCase):
    def test_calibrated_candidate_gpu_evaluates_one_percent_without_promoting_or_traced_cpu(self):
        result = qualified_comparison()
        for row, proof in zip(result["rows"], retained_rows(2)): row.update(proof)
        gpu.qualify_result(result)
        candidate = result["rows"][1]
        self.assertTrue(candidate["gpu_acceptance_eligible"])
        self.assertTrue(candidate["gpu_target"]["runtime"]["evaluated"])
        self.assertEqual(candidate["gpu_target"]["runtime"]["limit_percent"], 1)
        self.assertFalse(candidate["promotion_eligible"])
        self.assertFalse(candidate["cpu_acceptance_eligible"])
        self.assertFalse(result["regression_passed"])

    def test_missing_gpu_calibration_stays_unavailable_and_cannot_pass(self):
        result = qualified_comparison()
        for row, proof in zip(result["rows"], retained_rows(2)): row.update(proof)
        result["gpu_trace"]["calibration"]["valid"] = False
        gpu.qualify_result(result)
        candidate = result["rows"][1]
        self.assertFalse(candidate["gpu_acceptance_eligible"])
        self.assertFalse(candidate["gpu_target"]["runtime"]["evaluated"])
        self.assertIsNone(candidate["gpu_target"]["runtime"]["within_limit"])

    def test_gpu_pair_geometry_and_actual_apply_proof_are_mandatory(self):
        for fault in ("mode", "single", "missing", "applies", "geometry", "absent-geometry", "normal-counter", "receipt-field"):
            result = qualified_comparison()
            for row, proof in zip(result["rows"], retained_rows(2)): row.update(proof)
            if fault == "mode": result["rows"][0]["mode"] = memory.HELD_USAGE_MODE
            elif fault == "single": result["capture_case"] = "candidate"
            elif fault == "missing": del result["rows"][1]["retained_usage_work"]
            elif fault == "applies": result["rows"][1]["retained_usage_work"]["counter_deltas"]["value_applies"] = 0
            elif fault == "absent-geometry":
                for row in result["rows"]: row["scalar_presentation_work"] = None
            elif fault == "normal-counter": del result["rows"][0]["retained_usage_work"]["counter_deltas"]["hosts_destroyed"]
            elif fault == "receipt-field": del result["rows"][1]["retained_usage_work"]["monitoring_epoch"]
            else: result["rows"][1]["scalar_presentation_work"]["native_chart_geometry"][0]["width"] += 1
            with self.subTest(fault=fault), self.assertRaises(ValueError): gpu.qualify_result(result)


if __name__ == "__main__":
    unittest.main()
