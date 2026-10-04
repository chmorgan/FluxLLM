"""One held native dashboard usage receipt; all other presentation remains live."""
import copy
import hashlib
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

import memory_attribution as memory
import runtime_attribution as runtime
import runtime_gpu_comparison as gpu
from test_runtime_attribution import options
from test_runtime_frozen_scalars import OWNER_IDS, scalar_report
from test_runtime_gpu_comparison import qualified_comparison


EPOCH = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
BASE_USAGE = {"input_tokens": 100, "unknown_input_requests": 0, "output_tokens": 100,
              "output_is_estimated": False, "tool_calls": 2, "requests": 10,
              "active_requests": 0, "is_partial": False}


def bind_receipt(owner, entry):
    envelope = {"schema": "dashboard-held-usage-v1", "owner": owner, "epoch": entry["epoch"],
                "scope": entry["scope"], "values": entry["values"], "frames": entry["frames"]}
    entry["capture_payload_json"] = json.dumps(envelope, sort_keys=True, separators=(",", ":"))
    entry["capture_identity"] = hashlib.sha256(entry["capture_payload_json"].encode()).hexdigest()


def add_held_usage_metadata(snapshot, mode, *, captured=False, closed=False):
    value = snapshot["graphics_diagnostics"]
    value.update(mode=mode, held_usage_enabled=mode == memory.HELD_USAGE_MODE,
                 frozen_scalar_presentation_enabled=False,
                 scalar_instrumentation_enabled=mode in ("normal", memory.HELD_USAGE_MODE))
    raw = {"enabled": mode == memory.HELD_USAGE_MODE, "monitoring_epoch": EPOCH,
           "captures": int(captured), "releases": int(captured and closed),
           "current_owners": int(captured and not closed), "peak_owners": int(captured), "owners": {}}
    scalar = value["scalar_presentation"]
    for entry in scalar["presentation_owners"].values():
        entry["presented_values"] = {}
        if entry["role"] == "dashboard":
            entry["current_frames"]["statistics-row"] = {"x": 20, "y": 300, "width": 600, "height": 100}
    if captured and not closed:
        entry = {"role": "dashboard", "epoch": EPOCH, "scope": "sinceLaunch", "values": copy.deepcopy(BASE_USAGE),
                 "frames": copy.deepcopy(scalar["presentation_owners"][OWNER_IDS[0]]["current_frames"])}
        bind_receipt(OWNER_IDS[0], entry)
        raw["owners"][OWNER_IDS[0]] = entry
    value["held_usage"] = raw
    return snapshot


def held_report(mode=memory.HELD_USAGE_MODE):
    report = scalar_report("normal")
    report["workload"] = {"validated_work": copy.deepcopy(runtime.WORK)}
    progress = (0, 100, 1000, 6000, 10017, 10017, 10017)
    for index, point in enumerate(report["runtime"]["checkpoints"] + report["checkpoints"]):
        snapshot = point["snapshot"]
        closed = not snapshot["dashboard_visible"]
        add_held_usage_metadata(snapshot, mode, captured=mode == memory.HELD_USAGE_MODE, closed=closed)
        for entry in snapshot["graphics_diagnostics"]["scalar_presentation"]["presentation_owners"].values():
            active = snapshot["active_requests"] == 2
            labels = {"header": {"status": "Active" if active else "Idle", "model": "synthetic-model",
                                 "activity": "2 requests in flight" if active else None},
                      "metrics": {"rate": "400.0" if active else "0.0", "gpu": "—"}}
            if entry["role"] == "popover":
                labels["compact_details"] = {"response": "—" if index == 0 else
                                              ("~" if active else "") + f"{progress[index]:,}"}
            else:
                usage = copy.deepcopy(BASE_USAGE)
                if mode == "normal":
                    usage.update(output_tokens=100 + progress[index] * 2,
                                 active_requests=2 if active else 0, requests=10 if index == 0 else 12)
                labels["dashboard_usage"] = {"scope": "sinceLaunch", "values": usage}
            entry["presented_values"] = labels
    if mode == memory.HELD_USAGE_MODE:
        first = report["runtime"]["checkpoints"][0]["snapshot"]
        receipt = first["graphics_diagnostics"]["held_usage"]["owners"][OWNER_IDS[0]]
        ack = {"type": "ack", "command": "freeze_usage", "command_id": "runner-7", "status": "ok",
               "collector_control_before_seconds": 98, "collector_control_after_seconds": 99,
               "held_usage_capture": {"frozen": True, "owner": OWNER_IDS[0], "epoch": EPOCH,
                                      "capture_identity": receipt["capture_identity"]}, "snapshot": copy.deepcopy(first)}
        report["runtime"]["usage_freeze_acknowledgment"] = ack
        report["commands"] = [{"command": "freeze_usage", "response": ack}]
    return report


def held_rows():
    rows = []
    for mode in ("normal", memory.HELD_USAGE_MODE, "normal"):
        report = held_report(mode)
        rows.append({"mode": mode, "scalar_presentation_work": runtime.validate_scalar_presentation_checkpoints(report, mode),
                     "held_usage_work": runtime.validate_held_usage_checkpoints(report, mode)})
    return rows


class HeldUsageMetadataTests(unittest.TestCase):
    def test_exactly_one_dashboard_receipt_is_distinct_from_two_live_scalar_owners(self):
        snapshot = held_report()["runtime"]["checkpoints"][0]["snapshot"]
        held = memory.held_usage_contract(snapshot, memory.HELD_USAGE_MODE, require_held=True)
        scalar = memory.scalar_presentation_contract(snapshot, memory.HELD_USAGE_MODE)
        self.assertEqual(set(held["owners"]), {OWNER_IDS[0]})
        self.assertEqual(set(scalar["presentation_owners"]), set(OWNER_IDS))
        self.assertFalse(scalar["frozen_owners"])
        self.assertFalse(held["acceptance_eligible"])

    def test_old_normal_metadata_absent_is_optional_but_partial_present_fails(self):
        old = scalar_report("normal")["runtime"]["checkpoints"][0]["snapshot"]
        self.assertIsNone(memory.held_usage_contract(old, "normal"))
        for field in ("held_usage", "held_usage_enabled"):
            snapshot = held_report("normal")["runtime"]["checkpoints"][0]["snapshot"]
            del snapshot["graphics_diagnostics"][field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                memory.held_usage_contract(snapshot, "normal")

    def test_namespace_inventory_flags_and_unsigned_counters_fail_closed(self):
        for field in ("enabled", "monitoring_epoch", "owners") + memory.HELD_USAGE_COUNTERS + memory.HELD_USAGE_GAUGES:
            for invalid in ("missing", None, True, -1, 1.0, "1", 2**64):
                snapshot = held_report()["runtime"]["checkpoints"][0]["snapshot"]
                raw = snapshot["graphics_diagnostics"]["held_usage"]
                if invalid == "missing":
                    del raw[field]
                else:
                    raw[field] = invalid
                if field == "enabled" and invalid is True:
                    continue
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    memory.held_usage_contract(snapshot, memory.HELD_USAGE_MODE, require_held=True)

    def test_complete_usage_count_and_flag_inventory_is_typed(self):
        for field in memory.HELD_USAGE_VALUE_COUNTS + memory.HELD_USAGE_VALUE_FLAGS:
            for invalid in ("missing", None, -1, 1.0, "1", 2**64):
                if field == "input_tokens" and invalid is None:
                    continue
                snapshot = held_report()["runtime"]["checkpoints"][0]["snapshot"]
                entry = snapshot["graphics_diagnostics"]["held_usage"]["owners"][OWNER_IDS[0]]
                if invalid == "missing":
                    del entry["values"][field]
                else:
                    entry["values"][field] = invalid
                bind_receipt(OWNER_IDS[0], entry)
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    memory.held_usage_contract(snapshot, memory.HELD_USAGE_MODE)

    def test_stale_epoch_wrong_owner_role_scope_and_missing_capture_fields_are_rejected(self):
        for fault in ("epoch", "owner", "role", "scope", "missing", "two"):
            snapshot = held_report()["runtime"]["checkpoints"][0]["snapshot"]
            raw = snapshot["graphics_diagnostics"]["held_usage"]
            entry = raw["owners"][OWNER_IDS[0]]
            if fault == "epoch": entry["epoch"] = OWNER_IDS[1]
            elif fault == "owner": raw["owners"]["invalid"] = raw["owners"].pop(OWNER_IDS[0])
            elif fault == "role": entry["role"] = "popover"
            elif fault == "scope": entry["scope"] = "wrong"
            elif fault == "missing": del entry["capture_payload_json"]
            else: raw["owners"][OWNER_IDS[1]] = copy.deepcopy(entry)
            if fault not in ("owner", "missing"): bind_receipt(OWNER_IDS[0], entry)
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                memory.held_usage_contract(snapshot, memory.HELD_USAGE_MODE, require_held=True)

    def test_capture_fingerprint_binds_exact_payload_and_rejects_duplicate_json_fields(self):
        for fault in ("identity", "payload", "forged", "duplicate", "boolean-coordinate", "oversized"):
            snapshot = held_report()["runtime"]["checkpoints"][0]["snapshot"]
            entry = snapshot["graphics_diagnostics"]["held_usage"]["owners"][OWNER_IDS[0]]
            if fault == "identity": entry["capture_identity"] = "a" * 64
            elif fault == "payload": entry["capture_payload_json"] = "{"
            elif fault == "oversized": entry["capture_payload_json"] = " " * 8193
            else:
                payload = json.loads(entry["capture_payload_json"])
                if fault == "forged": payload["values"]["output_tokens"] += 1
                elif fault == "boolean-coordinate": payload["frames"]["statistics-row"]["x"] = True
                text = json.dumps(payload, sort_keys=True)
                if fault == "duplicate": text = text.replace('"schema":', '"schema":"dashboard-held-usage-v1","schema":', 1)
                entry["capture_payload_json"] = text
                entry["capture_identity"] = hashlib.sha256(text.encode()).hexdigest()
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                memory.held_usage_contract(snapshot, memory.HELD_USAGE_MODE)

    def test_missing_empty_nonfinite_overflowing_and_unbounded_capture_frames_are_rejected(self):
        for fault in ("missing", "empty", "nan", "overflow", "inventory"):
            snapshot = held_report()["runtime"]["checkpoints"][0]["snapshot"]
            entry = snapshot["graphics_diagnostics"]["held_usage"]["owners"][OWNER_IDS[0]]
            if fault == "missing": del entry["frames"]["statistics-row"]
            elif fault == "empty": entry["frames"]["statistics-row"]["height"] = 0
            elif fault == "nan": entry["frames"]["statistics-row"]["width"] = float("nan")
            elif fault == "overflow": entry["frames"]["statistics-row"].update(x=1.7e308, width=1.7e308)
            else:
                for index in range(20): entry["frames"][f"extra-{index}"] = copy.deepcopy(entry["frames"]["statistics-row"])
            bind_receipt(OWNER_IDS[0], entry)
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                memory.held_usage_contract(snapshot, memory.HELD_USAGE_MODE)


class HeldUsageRuntimeTests(unittest.TestCase):
    def test_held_usage_proves_live_compact_unrelated_fields_geometry_and_quiet_release(self):
        for mode in ("normal", memory.HELD_USAGE_MODE):
            work = runtime.validate_held_usage_checkpoints(held_report(mode), mode)
            self.assertEqual(work["enabled"], mode == memory.HELD_USAGE_MODE)
            self.assertEqual(work["live_compact_response_final_count"], 10017)
            self.assertEqual(work["live_compact_response_steady_counts"], [1000, 6000])
            self.assertTrue(work["live_unrelated_headers_and_rates_verified"])
            self.assertEqual(work["closed_current_owners"], 0)

    def test_every_interior_receipt_owner_epoch_fingerprint_and_value_is_immutable(self):
        for fault in ("missing", "epoch", "owner", "identity", "value", "frame", "counter"):
            report = held_report()
            raw = report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["held_usage"]
            entry = raw["owners"][OWNER_IDS[0]]
            if fault == "missing": raw["owners"] = {}
            elif fault == "epoch": raw["monitoring_epoch"] = entry["epoch"] = OWNER_IDS[1]
            elif fault == "owner": raw["owners"][OWNER_IDS[1]] = raw["owners"].pop(OWNER_IDS[0])
            elif fault == "identity": entry["capture_identity"] = "a" * 64
            elif fault == "value": entry["values"]["output_tokens"] += 1
            elif fault == "frame": entry["frames"]["statistics-row"]["height"] += 1
            else: raw["captures"] = 0
            if fault in ("epoch", "value", "frame"): bind_receipt(OWNER_IDS[0], entry)
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_held_usage_checkpoints(report, memory.HELD_USAGE_MODE)

    def test_ack_requires_one_successful_idle_capture_before_measured_boundary(self):
        for fault in ("missing", "repeat", "failed", "late", "owner", "epoch", "fingerprint", "hidden", "active"):
            report = held_report()
            ack = report["runtime"]["usage_freeze_acknowledgment"]
            if fault == "missing": report["commands"] = []
            elif fault == "repeat": report["commands"].append(copy.deepcopy(report["commands"][0]))
            elif fault == "failed": ack["status"] = "error"
            elif fault == "late": ack["collector_control_after_seconds"] = 101
            elif fault == "owner": ack["held_usage_capture"]["owner"] = OWNER_IDS[1]
            elif fault == "epoch": ack["held_usage_capture"]["epoch"] = OWNER_IDS[1]
            elif fault == "fingerprint": ack["held_usage_capture"]["capture_identity"] = "a" * 64
            elif fault == "hidden": ack["snapshot"]["popover_visible"] = False
            else: ack["snapshot"]["active_requests"] = 2
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_held_usage_checkpoints(report, memory.HELD_USAGE_MODE)

    def test_actual_rendered_usage_must_be_held_and_compact_headers_and_rates_must_be_live(self):
        for fault in ("held-values", "scope", "response-flat", "response-regressed", "response-final", "status", "activity", "rate", "missing"):
            report = held_report()
            owners = report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["scalar_presentation"]["presentation_owners"]
            dashboard, compact = (owners[owner]["presented_values"] for owner in OWNER_IDS)
            if fault == "held-values": dashboard["dashboard_usage"]["values"]["output_tokens"] += 1
            elif fault == "scope": dashboard["dashboard_usage"]["scope"] = "today"
            elif fault == "response-flat": compact["compact_details"]["response"] = "~1,000"
            elif fault == "response-regressed": compact["compact_details"]["response"] = "~999"
            elif fault == "response-final":
                report["runtime"]["checkpoints"][-1]["snapshot"]["graphics_diagnostics"]["scalar_presentation"]["presentation_owners"][OWNER_IDS[1]]["presented_values"]["compact_details"]["response"] = "10,016"
            elif fault == "status": compact["header"]["status"] = "Idle"
            elif fault == "activity": dashboard["header"]["activity"] = None
            elif fault == "rate": dashboard["metrics"]["rate"] = "0.0"
            else: del compact["compact_details"]
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_held_usage_checkpoints(report, memory.HELD_USAGE_MODE)

    def test_normal_control_cannot_hold_usage_or_issue_any_freeze_command(self):
        for fault in ("held", "command", "values"):
            report = held_report("normal")
            if fault == "held": report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["held_usage"]["captures"] = 1
            elif fault == "command": report["commands"] = held_report()["commands"]
            else:
                for point in report["runtime"]["checkpoints"]:
                    point["snapshot"]["graphics_diagnostics"]["scalar_presentation"]["presentation_owners"][OWNER_IDS[0]]["presented_values"]["dashboard_usage"]["values"] = copy.deepcopy(BASE_USAGE)
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_held_usage_checkpoints(report, "normal")

    def test_chart_cadence_effects_and_geometry_still_use_full_normal_proof(self):
        for fault in ("chart", "canvas", "draws", "arrival", "glints", "completion", "hidden"):
            report = held_report()
            point = report["runtime"]["checkpoints"][3]
            snapshot = point["snapshot"]
            value = snapshot["graphics_diagnostics"]
            if fault == "chart": value["scalar_presentation"]["presentation_owners"][OWNER_IDS[1]]["current_frames"]["main-activity-plot"]["x"] += 1
            elif fault == "canvas": value["native_canvas_frames"]["2"]["scale"] += 1
            elif fault == "draws":
                for item in report["runtime"]["checkpoints"]: item["snapshot"]["graphics_diagnostics"]["native_canvas_draws"]["2"] = 0
            elif fault == "arrival": report["runtime"]["checkpoints"][1]["snapshot"]["rail_frame_clock_ticks"] = 0
            elif fault == "glints": value["retained_twinkles"]["animation_starts"] = 4
            elif fault == "completion": report["runtime"]["checkpoints"][5]["snapshot"]["rail_frame_clock_ticks"] = 41
            else: snapshot["dashboard_visible"] = False
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_held_usage_checkpoints(report, memory.HELD_USAGE_MODE)

    def test_window_origins_are_report_only_but_captured_usage_bounds_cannot_move(self):
        report = held_report()
        current = report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["scalar_presentation"]["presentation_owners"][OWNER_IDS[0]]["current_frames"]
        current["native-window"]["x"] += 25
        current["gpu-value"] = {"x": 500, "y": 50, "width": 40, "height": 40}
        self.assertTrue(runtime.validate_held_usage_checkpoints(report, memory.HELD_USAGE_MODE)["held_dashboard_usage_verified"])
        current["statistics-row"]["y"] += 1
        with self.assertRaises(ValueError): runtime.validate_held_usage_checkpoints(report, memory.HELD_USAGE_MODE)

    def test_closed_owner_leaks_nonrelease_growth_missing_or_short_interval_are_rejected(self):
        for fault in ("owners", "release", "growth", "missing", "short"):
            report = held_report()
            last = report["checkpoints"][-1]
            raw = last["snapshot"]["graphics_diagnostics"]["held_usage"]
            if fault == "owners": raw["owners"] = copy.deepcopy(report["runtime"]["checkpoints"][0]["snapshot"]["graphics_diagnostics"]["held_usage"]["owners"])
            elif fault == "release": raw["releases"] = 0
            elif fault == "growth": raw["captures"] += 1
            elif fault == "missing": report["checkpoints"].pop()
            else: last["resource_sample"]["mach_absolute_seconds"] -= 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_held_usage_checkpoints(report, memory.HELD_USAGE_MODE)

    def test_matrix_is_normal_held_normal_only_and_products_remain_identical(self):
        self.assertEqual(runtime.selected_cases(options(baseline_mode="normal", controls=[memory.HELD_USAGE_MODE])),
                         [("baseline-before", "normal"), (memory.HELD_USAGE_MODE, memory.HELD_USAGE_MODE), ("baseline-after", "normal")])
        for args in (options(baseline_mode="native-gpu-optimized", controls=[memory.HELD_USAGE_MODE]),
                     options(baseline_mode="normal", controls=[memory.HELD_USAGE_MODE, memory.FROZEN_SCALARS_MODE]),
                     options(operation="profile", graphics_mode=memory.HELD_USAGE_MODE),
                     options(baseline_mode=memory.HELD_USAGE_MODE, controls=["normal"])):
            with self.subTest(args=args), self.assertRaises(ValueError): runtime.selected_cases(args)
        product = {"files": {name: {"sha256": "a" * 64} for name in ("app", "tests", "collector")},
                   "provenance": {"provenance_file_sha256": "b" * 64}}
        runtime.validate_scalar_comparison_products({"reference": product, "candidate": copy.deepcopy(product)})
        for key in ("app", "tests", "collector"):
            changed = copy.deepcopy(product)
            changed["files"][key]["sha256"] = "c" * 64
            with self.subTest(key=key), self.assertRaises(ValueError):
                runtime.validate_scalar_comparison_products({"reference": product, "candidate": changed})

    def test_comparison_requires_every_held_and_geometry_proof(self):
        rows = held_rows()
        self.assertFalse(runtime.validate_scalar_geometry_comparison(rows)["acceptance_eligible"])
        for field in ("held_usage_work", "scalar_presentation_work"):
            changed = copy.deepcopy(rows)
            del changed[1][field]
            with self.subTest(field=field), self.assertRaises(ValueError): runtime.validate_scalar_geometry_comparison(changed)
        rows[1]["scalar_presentation_work"]["critical_frames_by_role"]["dashboard"]["activity-chart"]["height"] += 1
        with self.assertRaises(ValueError): runtime.validate_scalar_geometry_comparison(rows)

    def test_begin_runtime_freezes_usage_only_in_held_mode_before_measured_boundary(self):
        for mode in ("normal", memory.HELD_USAGE_MODE):
            diagnostic = object.__new__(runtime.RuntimeDiagnostic)
            diagnostic.graphics_mode, diagnostic.runtime, diagnostic.profile_enabled = mode, {}, False
            ack = held_report()["runtime"]["usage_freeze_acknowledgment"]
            diagnostic.command, diagnostic.runtime_checkpoint = Mock(return_value=ack), Mock()
            with patch.object(runtime, "_mach_clock", return_value={"absolute_minus_monotonic_seconds": 900}): diagnostic.begin_runtime()
            diagnostic.runtime_checkpoint.assert_called_once_with("before-traffic")
            if mode == memory.HELD_USAGE_MODE: diagnostic.command.assert_called_once_with("freeze_usage")
            else: diagnostic.command.assert_not_called()

    def test_old_normal_runtime_never_requires_or_invents_held_metadata(self):
        self.assertIsNone(runtime.validate_held_usage_checkpoints(scalar_report("normal"), "normal"))


class HeldUsageGPUAndAcceptanceTests(unittest.TestCase):
    def test_cpu_memory_and_calibrated_gpu_are_always_ineligible_for_held_mode(self):
        self.assertFalse(runtime.cpu_acceptance_eligible(memory.HELD_USAGE_MODE))
        diagnostic = memory.MemoryDiagnostic(Path("/unused"), memory.MemoryDeadline(), memory.HELD_USAGE_MODE)
        self.assertFalse(diagnostic.report["cpu_acceptance_eligible"])
        result = qualified_comparison()
        for row, proof in zip(result["rows"], held_rows()[:2]): row.update(proof)
        gpu.qualify_result(result)
        row = result["rows"][1]
        self.assertFalse(row["gpu_acceptance_eligible"])
        self.assertFalse(row["promotion_eligible"])
        self.assertFalse(row["gpu_target"]["runtime"]["evaluated"])
        self.assertIsNone(row["gpu_target"]["runtime"]["within_limit"])
        self.assertTrue(row["gpu_target"]["runtime"]["observed_within_limit"])
        self.assertFalse(result["regression_passed"])

    def test_gpu_pair_requires_normal_held_geometry_and_complete_live_proof(self):
        for fault in ("matrix", "single", "missing", "geometry", "flat"):
            result = qualified_comparison()
            for row, proof in zip(result["rows"], held_rows()[:2]): row.update(proof)
            if fault == "matrix": result["rows"][0]["mode"] = memory.FROZEN_SCALARS_MODE
            elif fault == "single": result["capture_case"] = "candidate"
            elif fault == "missing": del result["rows"][1]["held_usage_work"]
            elif fault == "geometry": result["rows"][1]["scalar_presentation_work"]["native_chart_geometry"][0]["scale"] += 1
            else: result["rows"][1]["held_usage_work"]["live_compact_response_steady_counts"] = [1000, 1000]
            with self.subTest(fault=fault), self.assertRaises(ValueError): gpu.qualify_result(result)


if __name__ == "__main__":
    unittest.main()
