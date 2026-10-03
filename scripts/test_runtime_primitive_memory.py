"""Independent native-overlay and delivery evidence fixtures; no native execution."""
import copy
import unittest

import memory_attribution as memory
from test_memory_diagnostic import drawn_native_gpu_graphics


MODE = "runtime-metal-primitive-effects"
COMBINED = "runtime-efficient-effects"
FIELDS = ("hosts_created", "hosts_destroyed", "live_hosts", "peak_hosts", "descriptor_uploads", "submissions", "clears",
          "arrival_frames", "completion_frames", "twinkle_frames", "frames_skipped", "failures", "fallbacks",
          "current_buffer_bytes", "peak_buffer_bytes")
TELEMETRY_FIELDS = ("compact_states_enqueued", "snapshots_materialized", "batches_applied", "events_applied", "projection_refreshes")
SCALE_FIELDS = ("resolutions", "scale_changes", "cache_hits")


def primitive_snapshot(mode=MODE, *, closed=False, **counts):
    snapshot = drawn_native_gpu_graphics(memory.ORDERED_PUBLICATION_MODE)
    value = snapshot["graphics_diagnostics"]
    value.update(mode=mode, chart_publication_interval_seconds=1.0,
        metal_primitive_effects_enabled=mode in (MODE, COMBINED),
        batched_telemetry_delivery_enabled=mode in ("runtime-telemetry-batch", COMBINED),
        atomic_chart_scale_enabled=mode in ("runtime-atomic-chart-scale", COMBINED),
        arrival_backend="metal-primitive-effects" if mode in (MODE, COMBINED) else "canvas",
        metal_arrival_bursts_enabled=False, metal_full_chart_enabled=False,
        metal_static_cache_enabled=False, metal_full_chart=dict.fromkeys(memory.METAL_FULL_CHART_FIELDS, 0),
        direct_tool_plot=False, ungrouped_native_canvas=False, arrival_effects_enabled=True,
        compact_tool_paths_enabled=False, deferred_tool_geometry_enabled=False, holds_static_chart_drawing=False,
        metal_primitive_effects=dict.fromkeys(FIELDS, 0),
        batched_telemetry=dict.fromkeys(TELEMETRY_FIELDS, 0), atomic_chart_scale=dict.fromkeys(SCALE_FIELDS, 0))
    snapshot.update(dict.fromkeys(memory.METAL_ARRIVAL_COUNTERS, 0))
    snapshot.update(grouped_native_canvas_draws=value["native_gpu_canvas_draws"], ungrouped_native_canvas_draws=0,
        direct_tool_plot_builds=0, legacy_tool_plot_builds=3, tool_path_input_points=30, tool_path_output_points=30,
        suppressed_arrival_effects=0, dashboard_visible=not closed, popover_visible=not closed)
    if mode in (MODE, COMBINED):
        snapshot["rail_frame_clock_ticks"] = 0
        value["metal_primitive_effects"].update(hosts_created=2, hosts_destroyed=2 if closed else 0,
            live_hosts=0 if closed else 2, peak_hosts=2, descriptor_uploads=4, submissions=20, clears=2,
            arrival_frames=10, completion_frames=4, twinkle_frames=12,
            current_buffer_bytes=0 if closed else 4096, peak_buffer_bytes=4096)
        value["metal_primitive_effects"].update(counts)
    if mode in ("runtime-telemetry-batch", COMBINED):
        value["batched_telemetry"].update(compact_states_enqueued=100, snapshots_materialized=25,
            batches_applied=10, events_applied=40, projection_refreshes=10)
    if mode in ("runtime-atomic-chart-scale", COMBINED):
        value["atomic_chart_scale"].update(resolutions=4, scale_changes=1, cache_hits=0)
    if closed:
        for role in value["roles"].values():
            role["destroyed"] = role["created"]
            role["live"] = role["current_pixel_area"] = 0
        value["live_canvases"] = value["current_pixel_area"] = 0
        retained = value["retained_twinkles"]
        retained.update(hosts_destroyed=retained["hosts_created"], live_hosts=0,
            instances_destroyed=retained["instances_created"], live_instances=0)
    return snapshot


class PrimitiveMetalSnapshotTests(unittest.TestCase):
    def test_complete_overlay_with_static_canvas_and_retained_glints_is_accepted(self):
        self.assertEqual(set(memory.METAL_PRIMITIVE_EFFECTS_FIELDS), set(FIELDS))
        for mode in (MODE, COMBINED):
            snapshot = primitive_snapshot(mode)
            result = memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
            self.assertTrue(result["metal_primitive_effects"]["enabled"])
            self.assertGreater(result["counters"]["roles"]["static_chart"]["draws"], 0)
            self.assertEqual(result["counters"]["roles"]["rail_decorations"]["draws"], 0)
            self.assertEqual(result["arrival_backend"], "metal-primitive-effects")
            self.assertTrue(result["runtime_feature_contract"]["canvas_frame_clock"])
            memory.validate_graphics(primitive_snapshot(mode, closed=True), mode, expected_closed=True)

    def test_every_counter_is_complete_uint64(self):
        for field in FIELDS:
            for invalid in (None, True, -1, 1.0, "1", 2**64, "missing"):
                snapshot = primitive_snapshot()
                counts = snapshot["graphics_diagnostics"]["metal_primitive_effects"]
                if invalid == "missing":
                    del counts[field]
                else:
                    counts[field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(ValueError):
                    memory.metal_primitive_effects_contract(snapshot, MODE)

    def test_backend_and_enable_metadata_are_required(self):
        for field, values in {"metal_primitive_effects_enabled": (None, False, 1),
                              "native_gpu_backend": (None, "metal-persistent-chart"),
                              "arrival_backend": (None, "canvas"),
                              "metal_primitive_effects": (None, [])}.items():
            for invalid in values:
                snapshot = primitive_snapshot()
                snapshot["graphics_diagnostics"][field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    memory.metal_primitive_effects_contract(snapshot, MODE)

    def test_lifetime_frame_bounds_and_quality_failures_are_rejected(self):
        changes = ({"hosts_destroyed": 3}, {"live_hosts": 1}, {"peak_hosts": 3}, {"peak_hosts": 0},
                   {"current_buffer_bytes": 4097}, {"live_hosts": 0, "hosts_destroyed": 2},
                   {"clears": 21}, {"arrival_frames": 21}, {"completion_frames": 21},
                   {"twinkle_frames": 21}, {"frames_skipped": 1}, {"failures": 1}, {"fallbacks": 1})
        for change in changes:
            with self.subTest(change=change), self.assertRaises(ValueError):
                memory.metal_primitive_effects_contract(primitive_snapshot(**change), MODE)
        for field in ("descriptor_uploads", "submissions", "arrival_frames", "peak_buffer_bytes"):
            with self.subTest(missing_work=field), self.assertRaises(ValueError):
                memory.metal_primitive_effects_contract(primitive_snapshot(**{field: 0}), MODE,
                    completed_visible_workload=True)
        with self.assertRaises(ValueError):
            memory.metal_primitive_effects_contract(primitive_snapshot(), MODE, expected_closed=True)

    def test_network_completion_ack_can_precede_completion_and_overlap_frames(self):
        snapshot = primitive_snapshot(completion_frames=0, twinkle_frames=0)
        self.assertTrue(memory.validate_graphics(snapshot, MODE, completed_visible_workload=True)["available"])

    def test_legacy_decoration_and_static_chart_fallbacks_are_rejected(self):
        for field in ("draws", "skipped_draws"):
            snapshot = primitive_snapshot()
            snapshot["graphics_diagnostics"]["roles"]["rail_decorations"][field] = 1
            with self.subTest(decoration=field), self.assertRaises(ValueError):
                memory.validate_graphics(snapshot, MODE)
        snapshot = primitive_snapshot()
        snapshot["graphics_diagnostics"]["metal_full_chart"]["submissions"] = 1
        with self.assertRaisesRegex(ValueError, "Non-Metal chart"):
            memory.validate_graphics(snapshot, MODE)
        snapshot = primitive_snapshot()
        del snapshot["graphics_diagnostics"]["metal_full_chart_enabled"]
        del snapshot["graphics_diagnostics"]["metal_full_chart"]
        with self.assertRaisesRegex(ValueError, "inactive full-chart Metal evidence"):
            memory.metal_primitive_effects_contract(snapshot, MODE)

    def test_historical_absence_is_supported_and_other_new_modes_cannot_execute_overlay(self):
        self.assertIsNone(memory.metal_primitive_effects_contract({}, "normal"))
        for mode in ("runtime-telemetry-batch", "runtime-atomic-chart-scale"):
            snapshot = primitive_snapshot(mode)
            self.assertFalse(memory.metal_primitive_effects_contract(snapshot, mode)["enabled"])
            for field in FIELDS:
                changed = copy.deepcopy(snapshot)
                changed["graphics_diagnostics"]["metal_primitive_effects"][field] = 1
                with self.subTest(mode=mode, field=field), self.assertRaises(ValueError):
                    memory.metal_primitive_effects_contract(changed, mode)


class DeliveryMechanismContractTests(unittest.TestCase):
    def test_each_mode_acknowledges_exact_features_and_normal_rendering(self):
        for mode in memory.NEW_RUNTIME_MODES:
            result = memory.validate_graphics(primitive_snapshot(mode), mode, completed_visible_workload=True)
            flags = result["runtime_feature_contract"]
            self.assertIs(flags["metal_primitive_effects_enabled"], mode in (MODE, COMBINED))
            self.assertIs(flags["batched_telemetry_delivery_enabled"], mode in ("runtime-telemetry-batch", COMBINED))
            self.assertIs(flags["atomic_chart_scale_enabled"], mode in ("runtime-atomic-chart-scale", COMBINED))
            self.assertTrue(flags["incremental_history_ordering"] and flags["optimized_chart_preparation"]
                and flags["lifecycle_effects_enabled"] and flags["ordered_chart_publication"]
                and flags["unpromised_stream_body_writes"])
            self.assertFalse(flags["shared_chart_preparation"] or flags["stable_decoration_hosts"])
            self.assertEqual(result["chart_publication_interval_seconds"], 1.0)

    def test_all_new_feature_flags_are_typed_and_exact(self):
        for mode in memory.NEW_RUNTIME_MODES:
            for field in memory.NEW_RUNTIME_FLAGS:
                for invalid in (None, 0, 1, "true", "missing", not primitive_snapshot(mode)["graphics_diagnostics"][field]):
                    snapshot = primitive_snapshot(mode)
                    if invalid == "missing":
                        del snapshot["graphics_diagnostics"][field]
                    else:
                        snapshot["graphics_diagnostics"][field] = invalid
                    with self.subTest(mode=mode, field=field, invalid=invalid), self.assertRaises(ValueError):
                        memory.runtime_feature_contract(snapshot["graphics_diagnostics"], mode)

    def test_mechanism_groups_are_complete_typed_and_inactive_zero(self):
        specs = (("batched_telemetry", "runtime-telemetry-batch", TELEMETRY_FIELDS, memory.batched_telemetry_contract),
                 ("atomic_chart_scale", "runtime-atomic-chart-scale", SCALE_FIELDS, memory.atomic_chart_scale_contract))
        for namespace, mode, fields, validate in specs:
            self.assertIsNone(validate({}, "normal"))
            for field in fields:
                for invalid in (None, True, -1, 1.0, 2**64, "missing"):
                    snapshot = primitive_snapshot(mode)
                    counts = snapshot["graphics_diagnostics"][namespace]
                    if invalid == "missing":
                        del counts[field]
                    else:
                        counts[field] = invalid
                    with self.subTest(namespace=namespace, field=field, invalid=invalid), self.assertRaises(ValueError):
                        validate(snapshot, mode)
                inactive = primitive_snapshot()
                inactive["graphics_diagnostics"][namespace][field] = 1
                with self.subTest(inactive=namespace, field=field), self.assertRaises(ValueError):
                    validate(inactive, MODE)

    def test_mechanisms_require_positive_executed_work_with_valid_crosscounter_bounds(self):
        for field in TELEMETRY_FIELDS:
            snapshot = primitive_snapshot("runtime-telemetry-batch")
            snapshot["graphics_diagnostics"]["batched_telemetry"][field] = 0
            with self.subTest(telemetry=field), self.assertRaises(ValueError):
                memory.batched_telemetry_contract(snapshot, "runtime-telemetry-batch", completed_visible_workload=True)
        for change in ({"snapshots_materialized": 101}, {"projection_refreshes": 11},
                       {"projection_refreshes": 9}, {"events_applied": 9}):
            snapshot = primitive_snapshot("runtime-telemetry-batch")
            snapshot["graphics_diagnostics"]["batched_telemetry"].update(change)
            with self.subTest(telemetry=change), self.assertRaises(ValueError):
                memory.batched_telemetry_contract(snapshot, "runtime-telemetry-batch")
        for change in ({"resolutions": 0}, {"scale_changes": 5}):
            snapshot = primitive_snapshot("runtime-atomic-chart-scale")
            snapshot["graphics_diagnostics"]["atomic_chart_scale"].update(change)
            with self.subTest(scale=change), self.assertRaises(ValueError):
                memory.atomic_chart_scale_contract(snapshot, "runtime-atomic-chart-scale", completed_visible_workload=True)
        # A fixed chart or one resolution per body does not manufacture cache hits.
        snapshot = primitive_snapshot("runtime-atomic-chart-scale")
        snapshot["graphics_diagnostics"]["atomic_chart_scale"].update(scale_changes=0, cache_hits=0)
        self.assertTrue(memory.atomic_chart_scale_contract(snapshot, "runtime-atomic-chart-scale",
            completed_visible_workload=True)["enabled"])


if __name__ == "__main__":
    unittest.main()
