"""Authenticated frozen scalar ablation proofs; no native operations."""
import copy
import unittest
from unittest.mock import Mock, patch

import memory_attribution as memory
import runtime_attribution as runtime
import runtime_gpu_comparison as gpu
from test_runtime_full_chart import full_runtime_report
from test_runtime_gpu_comparison import qualified_comparison
from test_runtime_attribution import options


OWNER_IDS = ("00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002")


def add_scalar_metadata(snapshot, mode, *, frozen=False, present=False, closed=False, updates=0):
    value = snapshot["graphics_diagnostics"]
    value.update(mode=mode, frozen_scalar_presentation_enabled=mode == memory.FROZEN_SCALARS_MODE,
                 scalar_instrumentation_enabled=mode in ("normal", memory.FROZEN_SCALARS_MODE),
                 native_canvas_frames={}, native_canvas_draws={})
    raw = dict.fromkeys(memory.SCALAR_PRESENTATION_COUNTERS + memory.SCALAR_PRESENTATION_GAUGES, 0)
    raw.update(leaf_body_updates=dict.fromkeys(memory.SCALAR_LEAVES, updates * 2), frozen_owners={}, presentation_owners={})
    raw.update(layout_size_calls=updates, layout_place_calls=updates, layout_child_measurements=updates * 5)
    if frozen:
        raw.update(freezes_captured=2, freezes_released=2 if closed else 0,
                   current_frozen_owners=0 if closed else 2, peak_frozen_owners=2)
    if present and not closed:
        for index, role in enumerate(("dashboard", "popover")):
            frames = {name: {"x": 100, "y": 80, "width": 640, "height": 200}
                      for name in runtime.SCALAR_CRITICAL_FRAMES[role]}
            raw["presentation_owners"][OWNER_IDS[index]] = {"role": role, "current_frames": copy.deepcopy(frames),
                                                           "leaf_body_updates": dict.fromkeys(memory.SCALAR_LEAVES, updates)}
            if frozen:
                raw["frozen_owners"][OWNER_IDS[index]] = {"role": role, "capture_identity": str(index + 1) * 64,
                                                       "frames": copy.deepcopy(frames)}
        value["native_canvas_frames"] = {"1": {"role": "static_chart", "width": 640, "height": 200, "scale": 2},
                                         "2": {"role": "static_chart", "width": 640, "height": 200, "scale": 2}}
        value["native_canvas_draws"] = {"1": 1, "2": 1}
    value["scalar_presentation"] = raw
    return snapshot


def scalar_report(mode=memory.FROZEN_SCALARS_MODE):
    from test_memory_diagnostic import drawn_native_gpu_graphics
    report = full_runtime_report()
    rows = report["runtime"]["checkpoints"] + report["checkpoints"]
    ticks = (0, 40, 40, 40, 41, 100, 150, 150, 150)
    retained = (0, 2, 4, 20, 28, 28, 30, 30, 30)
    for index, point in enumerate(rows):
        old = point["snapshot"]
        closed = not old["dashboard_visible"]
        snapshot = drawn_native_gpu_graphics(memory.ORDERED_PUBLICATION_MODE)
        snapshot.update(dashboard_visible=not closed, popover_visible=not closed, active_requests=old["active_requests"],
            runner_collector_sample_monotonic_seconds=old["runner_collector_sample_monotonic_seconds"],
            chart_preparations=min(index, 6) * 2 + 3, rail_frame_clock_ticks=ticks[index])
        value = snapshot["graphics_diagnostics"]
        value.update(chart_publication_interval_seconds=1,
            metal_primitive_effects_enabled=False, batched_telemetry_delivery_enabled=False, atomic_chart_scale_enabled=False,
            completed_lane_cache_enabled=False, rail_geometry_cache_enabled=False, rail_geometry_cache_used=False)
        for namespace, _flag, _modes, counters, _maximum in memory.REUSE_CACHE_SPECS:
            value[namespace] = dict.fromkeys(counters + memory.REUSE_CACHE_GAUGES, 0)
        value["rail_geometry_cache"].update(current_caches=0, peak_caches=0, max_entries_per_cache=24)
        value["roles"]["static_chart"]["draws"] = min(index, 6) * 2 + 3
        value["roles"]["rail_decorations"]["draws"] = ticks[index]
        value["native_gpu_canvas_draws"] = snapshot["grouped_native_canvas_draws"] = sum(
            role["draws"] for role in value["roles"].values())
        live = 0 if closed else min(2, retained[index])
        value["retained_twinkles"].update(hosts_created=2, hosts_destroyed=2 if closed else 0, live_hosts=0 if closed else 2,
            peak_hosts=2, instances_created=retained[index], instances_destroyed=retained[index] - live,
            live_instances=live, peak_instances=min(2, retained[index]), animation_starts=retained[index])
        add_scalar_metadata(snapshot, mode, frozen=mode == memory.FROZEN_SCALARS_MODE, present=True,
                            closed=closed, updates=min(index, 7) + 2)
        if not closed:
            value["native_canvas_draws"] = {"1": int(point["resource_sample"]["monotonic_seconds"] - 100),
                                            "2": int(point["resource_sample"]["monotonic_seconds"] - 100)}
        point["snapshot"] = snapshot
    if mode == memory.FROZEN_SCALARS_MODE:
        ack = {"type": "ack", "command": "freeze_scalars", "command_id": "runner-7", "status": "ok",
               "collector_control_before_seconds": 98, "collector_control_after_seconds": 99,
               "snapshot": copy.deepcopy(rows[0]["snapshot"])}
        report["runtime"]["scalar_freeze_acknowledgment"] = ack
        report["commands"] = [{"command": "freeze_scalars", "response": ack}]
    else:
        report["commands"] = []
    return report


class ScalarMetadataTests(unittest.TestCase):
    def test_warmup_pending_frames_normal_and_complete_frozen_metadata(self):
        from test_memory_diagnostic import graphics
        self.assertTrue(memory.scalar_presentation_contract(graphics(memory.FROZEN_SCALARS_MODE), memory.FROZEN_SCALARS_MODE)["enabled"])
        self.assertFalse(memory.scalar_presentation_contract(scalar_report("normal")["runtime"]["checkpoints"][0]["snapshot"], "normal")["enabled"])
        value = memory.scalar_presentation_contract(scalar_report()["runtime"]["checkpoints"][0]["snapshot"],
                                                   memory.FROZEN_SCALARS_MODE, require_frozen=True)
        self.assertEqual(value["counters"]["current_frozen_owners"], 2)
        self.assertFalse(value["acceptance_eligible"])

    def test_old_normal_omits_new_metadata_without_inventing_zero(self):
        from test_memory_diagnostic import drawn_native_gpu_graphics
        old = drawn_native_gpu_graphics(memory.ORDERED_PUBLICATION_MODE)
        old["graphics_diagnostics"]["mode"] = "normal"
        self.assertIsNone(memory.scalar_presentation_contract(old, "normal"))

    def test_missing_mistyped_false_or_incomplete_metadata_fails_closed(self):
        for field in ("frozen_scalar_presentation_enabled", "scalar_instrumentation_enabled", "scalar_presentation", "native_canvas_frames", "native_canvas_draws"):
            for invalid in ("missing", None, False, 1):
                snapshot = scalar_report()["runtime"]["checkpoints"][0]["snapshot"]
                value = snapshot["graphics_diagnostics"]
                if invalid == "missing":
                    del value[field]
                else:
                    value[field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(ValueError):
                    memory.scalar_presentation_contract(snapshot, memory.FROZEN_SCALARS_MODE, require_frozen=True)

    def test_every_counter_and_leaf_requires_uint64(self):
        fields = memory.SCALAR_PRESENTATION_COUNTERS + memory.SCALAR_PRESENTATION_GAUGES
        for field in fields + memory.SCALAR_LEAVES:
            for invalid in ("missing", None, True, -1, 1.0, "1", 2**64):
                snapshot = scalar_report()["runtime"]["checkpoints"][0]["snapshot"]
                raw = snapshot["graphics_diagnostics"]["scalar_presentation"]
                counts = raw if field in fields else raw["leaf_body_updates"]
                if invalid == "missing":
                    del counts[field]
                else:
                    counts[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    memory.scalar_presentation_contract(snapshot, memory.FROZEN_SCALARS_MODE)

    def test_invalid_owner_capture_frame_or_body_sum_is_rejected(self):
        for fault in ("owner", "role", "identity", "duplicate", "frame", "nan", "overflow", "body", "released"):
            snapshot = scalar_report()["runtime"]["checkpoints"][0]["snapshot"]
            raw = snapshot["graphics_diagnostics"]["scalar_presentation"]
            frozen = raw["frozen_owners"][OWNER_IDS[0]]
            if fault == "owner":
                raw["frozen_owners"]["invalid"] = raw["frozen_owners"].pop(OWNER_IDS[0])
            elif fault == "role":
                frozen["role"] = None
            elif fault == "identity":
                frozen["capture_identity"] = "1"
            elif fault == "duplicate":
                raw["frozen_owners"][OWNER_IDS[1]]["role"] = "dashboard"
            elif fault in ("frame", "nan", "overflow"):
                frozen["frames"]["activity-chart"].update(width=0 if fault == "frame" else float("nan") if fault == "nan" else 1.7e308)
                if fault == "overflow":
                    frozen["frames"]["activity-chart"]["x"] = 1.7e308
            elif fault == "body":
                raw["presentation_owners"][OWNER_IDS[0]]["leaf_body_updates"]["header"] = 100
            else:
                raw["freezes_released"] = 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                memory.scalar_presentation_contract(snapshot, memory.FROZEN_SCALARS_MODE, require_frozen=True)


class ScalarPhaseTests(unittest.TestCase):
    def test_comparison_matrix_is_rejected_before_capture_unless_normal_frozen_normal(self):
        self.assertEqual(runtime.selected_cases(options(baseline_mode="normal", controls=[memory.FROZEN_SCALARS_MODE])),
            [("baseline-before", "normal"), (memory.FROZEN_SCALARS_MODE, memory.FROZEN_SCALARS_MODE), ("baseline-after", "normal")])
        for args in (options(baseline_mode="native-gpu-optimized", controls=[memory.FROZEN_SCALARS_MODE]),
                     options(baseline_mode="normal", controls=[memory.FROZEN_SCALARS_MODE, memory.REUSE_CACHES_MODE]),
                     options(baseline_mode=memory.FROZEN_SCALARS_MODE, controls=["normal"])):
            with self.subTest(args=args), self.assertRaisesRegex(ValueError, "Scalar ablation"):
                runtime.selected_cases(args)
        self.assertEqual(runtime.selected_cases(options(operation="profile", graphics_mode=memory.FROZEN_SCALARS_MODE)),
                         [("profile", memory.FROZEN_SCALARS_MODE)])

    def test_explicit_reference_scalar_ablation_requires_identical_products_and_provenance(self):
        candidate = {"files": {name: {"sha256": "a" * 64} for name in ("app", "tests", "collector")},
                     "provenance": {"provenance_file_sha256": "b" * 64}}
        products = {"candidate": candidate, "reference": copy.deepcopy(candidate)}
        runtime.validate_scalar_comparison_products(products)
        for name in ("app", "tests", "collector", "provenance"):
            changed = copy.deepcopy(products)
            if name == "provenance":
                changed["reference"]["provenance"]["provenance_file_sha256"] = "c" * 64
            else:
                changed["reference"]["files"][name]["sha256"] = "c" * 64
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "identical frozen"):
                runtime.validate_scalar_comparison_products(changed)

    def test_every_interior_snapshot_holds_scalars_and_chart_geometry(self):
        for mode in ("normal", memory.FROZEN_SCALARS_MODE):
            result = runtime.validate_scalar_presentation_checkpoints(scalar_report(mode), mode)
            self.assertGreater(result["arrival_deltas"]["rail_decorations_draws"], 0)
            self.assertGreater(result["completion_deltas"]["rail_decorations_draws"], 0)
            self.assertGreater(result["steady_retained_twinkle_animation_starts"], 0)
            self.assertEqual(result["closed_current_frozen_owners"], 0)
            self.assertEqual(result["enabled"], mode == memory.FROZEN_SCALARS_MODE)

    def test_interior_identity_frame_owner_or_counter_changes_are_rejected(self):
        for fault in ("identity", "captured-frame", "live-frame", "native-frame", "missing-frame", "counter", "owner-body", "hidden", "kernel"):
            report = scalar_report()
            point = report["runtime"]["checkpoints"][3]
            snapshot = point["snapshot"]
            value = snapshot["graphics_diagnostics"]
            raw = value["scalar_presentation"]
            if fault == "identity":
                raw["frozen_owners"][OWNER_IDS[0]]["capture_identity"] = "a" * 64
            elif fault == "captured-frame":
                raw["frozen_owners"][OWNER_IDS[0]]["frames"]["activity-chart"]["width"] += 1
            elif fault == "live-frame":
                raw["presentation_owners"][OWNER_IDS[0]]["current_frames"]["activity-chart"]["width"] += 1
            elif fault == "native-frame":
                value["native_canvas_frames"]["1"]["height"] += 1
            elif fault == "missing-frame":
                del raw["presentation_owners"][OWNER_IDS[0]]["current_frames"]["native-window"]
            elif fault == "counter":
                raw["layout_size_calls"] = 0
            elif fault == "owner-body":
                raw["presentation_owners"][OWNER_IDS[0]]["leaf_body_updates"]["metrics"] = 0
            elif fault == "hidden":
                snapshot["popover_visible"] = False
            else:
                point["resource_sample"]["process_id"] += 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_scalar_presentation_checkpoints(report, memory.FROZEN_SCALARS_MODE)

    def test_freeze_ack_must_be_once_successful_and_before_runtime(self):
        for fault in ("missing", "repeat", "failed", "late", "identity", "hidden"):
            report = scalar_report()
            ack = report["runtime"]["scalar_freeze_acknowledgment"]
            if fault == "missing":
                report["commands"] = []
            elif fault == "repeat":
                report["commands"].append(copy.deepcopy(report["commands"][0]))
            elif fault == "failed":
                ack["status"] = "error"
            elif fault == "late":
                ack["collector_control_after_seconds"] = 101
            elif fault == "identity":
                ack["snapshot"]["graphics_diagnostics"]["scalar_presentation"]["frozen_owners"][OWNER_IDS[0]]["capture_identity"] = "a" * 64
            else:
                ack["snapshot"]["dashboard_visible"] = False
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_scalar_presentation_checkpoints(report, memory.FROZEN_SCALARS_MODE)

    def test_normal_statistics_intrinsics_may_change_but_chart_bounds_may_not(self):
        report = scalar_report("normal")
        raw = report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["scalar_presentation"]
        raw["presentation_owners"][OWNER_IDS[0]]["current_frames"]["statistics-row"] = {"x": 0, "y": 0, "width": 120, "height": 20}
        self.assertIsNotNone(runtime.validate_scalar_presentation_checkpoints(report, "normal"))
        raw["presentation_owners"][OWNER_IDS[0]]["current_frames"]["activity-chart"]["height"] += 1
        with self.assertRaisesRegex(ValueError, "geometry changed"):
            runtime.validate_scalar_presentation_checkpoints(report, "normal")

    def test_closed_leaks_growth_missing_or_short_observation_are_rejected(self):
        for fault in ("owners", "growth", "peak", "missing", "short"):
            report = scalar_report()
            last = report["checkpoints"][-1]
            raw = last["snapshot"]["graphics_diagnostics"]["scalar_presentation"]
            if fault == "owners":
                raw["presentation_owners"][OWNER_IDS[0]] = copy.deepcopy(report["runtime"]["checkpoints"][0]["snapshot"]["graphics_diagnostics"]["scalar_presentation"]["presentation_owners"][OWNER_IDS[0]])
            elif fault == "growth":
                raw["layout_size_calls"] += 1
            elif fault == "peak":
                raw["peak_frozen_owners"] = 0
            elif fault == "missing":
                report["checkpoints"].pop()
            else:
                last["resource_sample"]["mach_absolute_seconds"] -= 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_scalar_presentation_checkpoints(report, memory.FROZEN_SCALARS_MODE)

    def test_live_native_origin_shift_is_reported_while_local_chart_and_window_size_stay_fixed(self):
        report = scalar_report()
        raw = report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["scalar_presentation"]
        current = raw["presentation_owners"][OWNER_IDS[1]]["current_frames"]
        current["native-window"]["x"] += 30
        result = runtime.validate_scalar_presentation_checkpoints(report, memory.FROZEN_SCALARS_MODE)
        self.assertEqual(result["native_window_origins"][3]["by_role"]["popover"]["x"], 130)
        current["native-window"]["width"] += 1
        with self.assertRaises(ValueError):
            runtime.validate_scalar_presentation_checkpoints(report, memory.FROZEN_SCALARS_MODE)
        current["native-window"]["width"] -= 1
        current["main-activity-plot"]["x"] += 1
        with self.assertRaises(ValueError):
            runtime.validate_scalar_presentation_checkpoints(report, memory.FROZEN_SCALARS_MODE)

    def test_each_chart_requires_complete_monotonic_full_rate_drawing(self):
        for fault in ("missing", "flat", "regression", "invalid", "slow"):
            report = scalar_report()
            if fault == "missing":
                del report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["native_canvas_draws"]["2"]
            elif fault == "flat":
                for point in report["runtime"]["checkpoints"]:
                    point["snapshot"]["graphics_diagnostics"]["native_canvas_draws"]["2"] = 0
            elif fault == "regression":
                report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["native_canvas_draws"]["2"] = 0
            elif fault == "invalid":
                report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["native_canvas_draws"]["2"] = True
            else:
                for point in report["runtime"]["checkpoints"]:
                    point["snapshot"]["graphics_diagnostics"]["native_canvas_draws"]["2"] //= 2
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_scalar_presentation_checkpoints(report, memory.FROZEN_SCALARS_MODE)

    def test_cross_bracket_geometry_is_matched_without_matching_owner_uuid(self):
        cases = [{"mode": mode, "scalar_presentation_work": runtime.validate_scalar_presentation_checkpoints(scalar_report(mode), mode)}
                 for mode in ("normal", memory.FROZEN_SCALARS_MODE, "normal")]
        self.assertFalse(runtime.validate_scalar_geometry_comparison(cases)["acceptance_eligible"])
        cases[1]["scalar_presentation_work"]["critical_frames_by_role"]["dashboard"]["activity-chart"]["height"] += 1
        with self.assertRaisesRegex(ValueError, "geometry"):
            runtime.validate_scalar_geometry_comparison(cases)

    def test_ablation_is_always_ineligible_for_cpu_gpu_or_promotion(self):
        self.assertFalse(runtime.cpu_acceptance_eligible(memory.FROZEN_SCALARS_MODE))
        self.assertFalse(runtime.cpu_acceptance_eligible(memory.FROZEN_SCALARS_MODE, profile=True))
        result = qualified_comparison()
        result["rows"][1]["mode"] = memory.FROZEN_SCALARS_MODE
        gpu.qualify_result(result)
        row = result["rows"][1]
        self.assertFalse(row["gpu_acceptance_eligible"])
        self.assertFalse(row["promotion_eligible"])
        self.assertFalse(row["gpu_target"]["runtime"]["evaluated"])
        self.assertIsNone(row["gpu_target"]["runtime"]["within_limit"])

    def test_begin_runtime_freezes_only_new_mode_before_measured_boundary(self):
        for mode in ("normal", memory.FROZEN_SCALARS_MODE):
            diagnostic = object.__new__(runtime.RuntimeDiagnostic)
            diagnostic.graphics_mode = mode
            diagnostic.runtime = {}
            diagnostic.profile_enabled = False
            acknowledgment = scalar_report()["runtime"]["scalar_freeze_acknowledgment"]
            diagnostic.command = Mock(return_value=acknowledgment)
            diagnostic.runtime_checkpoint = Mock()
            with patch.object(runtime, "_mach_clock", return_value={"absolute_minus_monotonic_seconds": 900}):
                diagnostic.begin_runtime()
            diagnostic.runtime_checkpoint.assert_called_once_with("before-traffic")
            if mode == memory.FROZEN_SCALARS_MODE:
                diagnostic.command.assert_called_once_with("freeze_scalars")
                self.assertEqual(diagnostic.runtime["scalar_freeze_acknowledgment"], acknowledgment)
            else:
                diagnostic.command.assert_not_called()


if __name__ == "__main__":
    unittest.main()
