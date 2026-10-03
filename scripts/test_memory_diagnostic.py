"""Memory diagnostic orchestration tests; never launch an app/native profiler."""

import contextlib
import copy
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import memory_attribution as memory
from run_performance_checks import InvalidResult


def graphics(mode="normal"):
    if mode == memory.METAL_FULL_CHART_MODE:
        snapshot = graphics(memory.METAL_ARRIVAL_MODE)
        snapshot["graphics_diagnostics"].update(mode=mode, metal_full_chart_enabled=True,
            metal_full_chart=dict.fromkeys(memory.METAL_FULL_CHART_FIELDS, 0),
            native_gpu_backend="metal-persistent-chart", arrival_backend="metal-full-chart-shader",
            metal_arrival_bursts_enabled=False, canvas_frame_clock=False,
            retained_twinkles_enabled=False)
        del snapshot["graphics_diagnostics"]["retained_twinkle_backend"]
        return snapshot
    if mode == memory.HELD_STATIC_CHART_MODE:
        snapshot = graphics(memory.METAL_ARRIVAL_MODE)
        value = snapshot["graphics_diagnostics"]
        value.update(mode=mode, holds_static_chart_drawing=True,
                     metal_arrival_bursts_enabled=False, arrival_backend="canvas")
        for role in value["roles"].values():
            role.update(dict.fromkeys(memory.HELD_STATIC_CHART_COUNTERS, 0))
        return snapshot
    fields = ("created", "destroyed", "live", "peak_live", "updates", "renderer_creations", "renderer_updates",
              "renderer_destructions", "live_renderers", "peak_live_renderers", "draws", "skipped_draws",
              "current_pixel_area", "peak_pixel_area", "current_bitmap_bytes", "peak_bitmap_bytes",
              "max_width_points", "max_height_points", "max_scale")
    return {**({"shared_chart_normalization_builds": 0, "shared_chart_preparations": 0, "streamed_bodies_without_promises": 0, "chart_preparations": 0}
               if mode in memory.NEXT_RUNTIME_MODES else {}),
            **(dict.fromkeys(memory.METAL_ARRIVAL_COUNTERS, 0) if mode == memory.METAL_ARRIVAL_MODE else {}),
            **(dict.fromkeys(memory.CANVAS_CLOCK_COUNTERS, 0) if mode in memory.CANVAS_CLOCK_MODES else {}),
            **(dict.fromkeys(memory.ORDERED_PUBLICATION_COUNTERS, 0) if mode in memory.ORDERED_PUBLICATION_MODES else {}),
            **(dict.fromkeys(memory.DIRECT_TOOL_PLOT_COUNTERS, 0) if mode in (memory.DIRECT_TOOL_PLOT_MODE, memory.UNGROUPED_CANVAS_MODE, memory.NO_ARRIVAL_MODE, memory.COMPACT_TOOL_PATHS_MODE, memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES else {}),
            **(dict.fromkeys(memory.NATIVE_CANVAS_GROUP_COUNTERS, 0) if mode in (memory.UNGROUPED_CANVAS_MODE, memory.NO_ARRIVAL_MODE, memory.COMPACT_TOOL_PATHS_MODE, memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES else {}),
            **(dict.fromkeys(memory.TOOL_PATH_POINT_COUNTERS, 0) if mode in (memory.COMPACT_TOOL_PATHS_MODE, memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES else {}),
            **({"suppressed_arrival_effects": 0} if mode in (memory.NO_ARRIVAL_MODE, memory.COMPACT_TOOL_PATHS_MODE, memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES else {}), "graphics_diagnostics": {
        "enabled": True, "mode": mode, "invalid_events": 0, "cpu_glow_fallbacks": 0,
        "gradient_substitutions": 0,
        **({"shared_chart_preparation": mode in ("runtime-shared-preparation", "runtime-next-optimized"),
            "stable_decoration_hosts": mode in ("runtime-stable-decoration-hosts", "runtime-next-optimized"),
            "unpromised_stream_body_writes": mode in ("runtime-stream-writes", "runtime-next-optimized", "runtime-stream-canvas-clock") + memory.ORDERED_PUBLICATION_MODES}
           if mode in memory.NEXT_RUNTIME_MODES else {}),
        **({"canvas_frame_clock": True} if mode in memory.CANVAS_CLOCK_MODES else {}),
        **({"ordered_chart_publication": True} if mode in memory.ORDERED_PUBLICATION_MODES else {}),
        **({"direct_tool_plot": mode == memory.DIRECT_TOOL_PLOT_MODE} if mode in (memory.DIRECT_TOOL_PLOT_MODE, memory.UNGROUPED_CANVAS_MODE, memory.NO_ARRIVAL_MODE, memory.COMPACT_TOOL_PATHS_MODE, memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES else {}),
        **({"ungrouped_native_canvas": mode == memory.UNGROUPED_CANVAS_MODE} if mode in (memory.UNGROUPED_CANVAS_MODE, memory.NO_ARRIVAL_MODE, memory.COMPACT_TOOL_PATHS_MODE, memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES else {}),
        **({"arrival_effects_enabled": mode != memory.NO_ARRIVAL_MODE} if mode in (memory.NO_ARRIVAL_MODE, memory.COMPACT_TOOL_PATHS_MODE, memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES else {}),
        **({"compact_tool_paths_enabled": mode == memory.COMPACT_TOOL_PATHS_MODE} if mode in (memory.COMPACT_TOOL_PATHS_MODE, memory.METAL_ARRIVAL_MODE) + memory.DEFERRED_TOOL_GEOMETRY_MODES else {}),
        **({"deferred_tool_geometry_enabled": mode in memory.DEFERRED_TOOL_GEOMETRY_MODES}
           if mode in memory.DEFERRED_TOOL_GEOMETRY_MODES + (memory.METAL_ARRIVAL_MODE,) else {}),
        **({"metal_arrival_bursts_enabled": True, "arrival_backend": "metal-shader", "chart_publication_interval_seconds": 1.0}
           if mode == memory.METAL_ARRIVAL_MODE else {}),
        **({"chart_publication_interval_seconds": .5} if mode == memory.DEFERRED_TOOL_GEOMETRY_2HZ_MODE else {}),
        **({"incremental_history_ordering": mode in ("runtime-history-order", "runtime-optimized", "runtime-no-lifecycle") + memory.NEXT_RUNTIME_MODES,
            "optimized_chart_preparation": mode in ("runtime-chart-preparation", "runtime-optimized", "runtime-no-lifecycle") + memory.NEXT_RUNTIME_MODES,
            "lifecycle_effects_enabled": mode != "runtime-no-lifecycle"} if mode in memory.RUNTIME_MODES else {}),
        **({"native_gpu_backend": "swiftui-canvas" if mode == memory.UNGROUPED_CANVAS_MODE else "swiftui-canvas-drawing-group", "native_gpu_canvas_draws": 0}
           if mode in memory.NATIVE_GPU_MODES else {}),
        **({"scalar_presentation_coalesced": mode in memory.COALESCED_SCALAR_MODES,
            "retained_twinkles_enabled": mode in memory.RETAINED_TWINKLE_MODES}
           if mode in memory.NATIVE_GPU_MODES and mode != "native-gpu-canvas" else {}),
        **({"scalar_presentation_publications": 0} if mode in memory.COALESCED_SCALAR_MODES else {}),
        **({"retained_twinkle_backend": "core-animation-shape-layers",
            "retained_twinkles": dict.fromkeys(memory.RETAINED_TWINKLE_FIELDS, 0)}
           if mode in memory.RETAINED_TWINKLE_MODES else {}),
        **({"layer_bitmap_presentations": 0, "layer_bitmap_failures": 0, "layer_bitmap_native_draws": 0,
            "current_layer_image_bytes": 0, "peak_layer_image_bytes": 0} if mode in memory.LAYER_DESTINATION_MODES else {}),
        **({"layer_bitmap_pixel_format": "bgra8-premultiplied-first" if mode == "bitmap-layer-bgra" else "rgba8-premultiplied-last",
            "layer_bitmap_color_space": "device-rgb", "rail_decorations_enabled": mode != "bitmap-layer-no-decorations"}
           if mode in memory.LAYER_DESTINATION_MODES and mode != "bitmap-layer-destination" else {}),
        "live_canvases": 0, "peak_live_canvases": 0, "live_renderers": 0, "peak_live_renderers": 0,
        "current_pixel_area": 0, "peak_pixel_area": 0, "current_bitmap_bytes": 0, "peak_bitmap_bytes": 0,
        "roles": {role: dict.fromkeys(fields + (("current_layer_image_bytes", "peak_layer_image_bytes")
                                               if mode in memory.LAYER_DESTINATION_MODES else ()), 0)
                  for role in ("static_chart", "cursor", "rail_bars", "rail_decorations")}}}


def drawn_layer_graphics(mode="bitmap-layer-destination"):
    snapshot = graphics(mode)
    value = snapshot["graphics_diagnostics"]
    value.update(layer_bitmap_presentations=3, live_canvases=1, peak_live_canvases=1,
                 live_renderers=1, peak_live_renderers=1, current_layer_image_bytes=400, peak_layer_image_bytes=400)
    value["roles"]["static_chart"].update(created=1, live=1, peak_live=1, renderer_creations=1,
        live_renderers=1, peak_live_renderers=1, draws=3, current_layer_image_bytes=400, peak_layer_image_bytes=400)
    return snapshot


def drawn_native_gpu_graphics(mode="native-gpu-canvas"):
    if mode == memory.METAL_FULL_CHART_MODE:
        snapshot = graphics(mode)
        snapshot.update(streamed_bodies_without_promises=3, ordered_chart_publication_queries=3,
                        legacy_tool_plot_builds=3, tool_path_input_points=30, tool_path_output_points=30)
        snapshot["graphics_diagnostics"]["scalar_presentation_publications"] = 3
        snapshot["graphics_diagnostics"]["metal_full_chart"].update(hosts_created=2, live_hosts=2, peak_hosts=2,
            geometry_uploads=2, submissions=3, static_frames=3, arrival_frames=1, completion_frames=1,
            twinkle_frames=2, current_buffer_bytes=512, peak_buffer_bytes=512)
        return snapshot
    snapshot = graphics(mode)
    value = snapshot["graphics_diagnostics"]
    value.update(native_gpu_canvas_draws=3, live_canvases=1, peak_live_canvases=1,
                 current_pixel_area=400, peak_pixel_area=400)
    value["roles"]["static_chart"].update(created=1, live=1, peak_live=1, draws=3,
        current_pixel_area=400, peak_pixel_area=400, max_width_points=10, max_height_points=10, max_scale=2)
    if mode in ("runtime-shared-preparation", "runtime-next-optimized"):
        snapshot.update(shared_chart_normalization_builds=1, shared_chart_preparations=3, chart_preparations=3)
    if mode in ("runtime-stream-writes", "runtime-next-optimized", "runtime-stream-canvas-clock") + memory.ORDERED_PUBLICATION_MODES:
        snapshot["streamed_bodies_without_promises"] = 3
    if mode in memory.ORDERED_PUBLICATION_MODES:
        snapshot["ordered_chart_publication_queries"] = 3
    if mode == memory.DIRECT_TOOL_PLOT_MODE:
        snapshot["direct_tool_plot_builds"] = 3
    if mode == memory.UNGROUPED_CANVAS_MODE:
        snapshot.update(ungrouped_native_canvas_draws=3, legacy_tool_plot_builds=3)
    if mode == memory.NO_ARRIVAL_MODE:
        snapshot.update(grouped_native_canvas_draws=3, legacy_tool_plot_builds=3, suppressed_arrival_effects=2)
    if mode == memory.COMPACT_TOOL_PATHS_MODE:
        snapshot.update(grouped_native_canvas_draws=3, legacy_tool_plot_builds=3,
                        tool_path_input_points=30, tool_path_output_points=10)
    if mode in memory.DEFERRED_TOOL_GEOMETRY_MODES + (memory.METAL_ARRIVAL_MODE, memory.HELD_STATIC_CHART_MODE):
        snapshot.update(grouped_native_canvas_draws=3, legacy_tool_plot_builds=3,
                        tool_path_input_points=30, tool_path_output_points=30)
    if mode == memory.METAL_ARRIVAL_MODE:
        snapshot.update(metal_arrival_frames=3, metal_arrival_submissions=3)
    if mode == memory.HELD_STATIC_CHART_MODE:
        value["roles"]["static_chart"].update(drawing_update_attempts=3, drawing_updates_applied=3)
    if mode in memory.CANVAS_CLOCK_MODES:
        snapshot["rail_frame_clock_ticks"] = 3
    if mode in ("runtime-stable-decoration-hosts", "runtime-next-optimized"):
        value.update(live_canvases=2, peak_live_canvases=2)
        value["roles"]["rail_decorations"].update(created=1, live=1, peak_live=1)
    if mode in memory.COALESCED_SCALAR_MODES:
        value["scalar_presentation_publications"] = 2
    if mode in memory.RETAINED_TWINKLE_MODES:
        value["retained_twinkles"].update(hosts_created=1, live_hosts=1, peak_hosts=1,
                                          instances_created=2, live_instances=2, peak_instances=2, animation_starts=2)
    return snapshot


def native_normal_graphics(*, drawn=False):
    snapshot = drawn_native_gpu_graphics("native-gpu-optimized") if drawn else graphics("native-gpu-optimized")
    snapshot["graphics_diagnostics"]["mode"] = "normal"
    return snapshot


class MetalArrivalGraphicsTests(unittest.TestCase):
    def test_candidate_keeps_normal_paths_and_proves_metal_without_early_canvas_ticks(self):
        mode = memory.METAL_ARRIVAL_MODE
        snapshot = drawn_native_gpu_graphics(mode)
        snapshot["rail_frame_clock_ticks"] = 0  # Completion Canvas has not started at the traffic acknowledgment.
        result = memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
        self.assertEqual(result["arrival_backend"], "metal-shader")
        self.assertEqual(result["chart_publication_interval_seconds"], 1.0)
        flags = result["runtime_feature_contract"]
        self.assertTrue(flags["arrival_effects_enabled"] and flags["lifecycle_effects_enabled"])
        self.assertTrue(flags["ordered_chart_publication"] and flags["canvas_frame_clock"])
        self.assertFalse(flags["deferred_tool_geometry_enabled"] or flags["compact_tool_paths_enabled"])
        self.assertTrue(all(type(value) is bool for value in flags.values()))
        self.assertNotIn("arrival_backend", flags)

    def test_required_metadata_rejects_missing_fallback_or_mistyped_values(self):
        mode = memory.METAL_ARRIVAL_MODE
        changes = ({"metal_arrival_bursts_enabled": None}, {"metal_arrival_bursts_enabled": False},
                   {"metal_arrival_bursts_enabled": 1}, {"arrival_backend": None}, {"arrival_backend": "canvas"},
                   {"deferred_tool_geometry_enabled": True}, {"compact_tool_paths_enabled": True},
                   {"chart_publication_interval_seconds": None}, {"chart_publication_interval_seconds": .5})
        for change in changes:
            snapshot = drawn_native_gpu_graphics(mode)
            snapshot["graphics_diagnostics"].update(change)
            with self.subTest(change=change), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode)

    def test_complete_uint64_counters_require_successful_matching_submissions(self):
        mode = memory.METAL_ARRIVAL_MODE
        for field in memory.METAL_ARRIVAL_COUNTERS:
            for invalid in (None, True, -1, 1.0, 2**64):
                snapshot = drawn_native_gpu_graphics(mode)
                if invalid is None:
                    del snapshot[field]
                else:
                    snapshot[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)
        for frames, submissions, failures in ((3, 2, 0), (2, 3, 0), (3, 3, 1), (0, 0, 0)):
            snapshot = drawn_native_gpu_graphics(mode)
            snapshot.update(metal_arrival_frames=frames, metal_arrival_submissions=submissions, metal_arrival_failures=failures)
            with self.subTest(frames=frames, submissions=submissions, failures=failures), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode, completed_visible_workload=True)

    def test_frozen_absence_and_nonnative_zero_counters_remain_compatible(self):
        self.assertTrue(memory.validate_graphics(native_normal_graphics(), "normal")["available"])
        snapshot = graphics("empty-drawing")
        snapshot.update(dict.fromkeys(memory.METAL_ARRIVAL_COUNTERS, 0))
        self.assertTrue(memory.validate_graphics(snapshot, "empty-drawing")["available"])
        for field in memory.METAL_ARRIVAL_COUNTERS:
            changed = copy.deepcopy(snapshot)
            changed[field] = 1
            with self.subTest(field=field), self.assertRaises(InvalidResult):
                memory.validate_graphics(changed, "empty-drawing")
        del snapshot["metal_arrival_frames"]
        with self.assertRaises(InvalidResult):
            memory.validate_graphics(snapshot, "empty-drawing")

    def test_instrumented_normal_requires_canvas_backend_complete_zero_group_and_stability(self):
        snapshot = drawn_native_gpu_graphics(memory.METAL_ARRIVAL_MODE)
        snapshot["graphics_diagnostics"].update(mode="normal", metal_arrival_bursts_enabled=False, arrival_backend="canvas")
        snapshot.update(dict.fromkeys(memory.METAL_ARRIVAL_COUNTERS, 0))
        diagnostic = memory.MemoryDiagnostic(Path("/unused"), memory.MemoryDeadline(), "normal")
        self.assertEqual(diagnostic.validate_graphics_snapshot(snapshot)["arrival_backend"], "canvas")
        self.assertEqual(diagnostic.report["arrival_backend"], "canvas")
        for change in ({"arrival_backend": "metal-shader"}, {"metal_arrival_bursts_enabled": True}):
            changed = copy.deepcopy(snapshot)
            changed["graphics_diagnostics"].update(change)
            with self.subTest(change=change), self.assertRaises(InvalidResult):
                diagnostic.validate_graphics_snapshot(changed)
        for field in memory.METAL_ARRIVAL_COUNTERS:
            del snapshot[field]
        for field in ("metal_arrival_bursts_enabled", "arrival_backend"):
            del snapshot["graphics_diagnostics"][field]
        with self.assertRaisesRegex(InvalidResult, "Arrival backend metadata changed or disappeared"):
            diagnostic.validate_graphics_snapshot(snapshot)


class ChartPublicationCadenceTests(unittest.TestCase):
    def test_two_hz_has_same_boolean_features_and_separate_numeric_cadence(self):
        first = memory.validate_graphics(drawn_native_gpu_graphics(memory.DEFERRED_TOOL_GEOMETRY_MODE),
                                         memory.DEFERRED_TOOL_GEOMETRY_MODE, completed_visible_workload=True)
        second = memory.validate_graphics(drawn_native_gpu_graphics(memory.DEFERRED_TOOL_GEOMETRY_2HZ_MODE),
                                          memory.DEFERRED_TOOL_GEOMETRY_2HZ_MODE, completed_visible_workload=True)
        self.assertEqual(first["runtime_feature_contract"], second["runtime_feature_contract"])
        self.assertTrue(all(type(value) is bool for value in second["runtime_feature_contract"].values()))
        self.assertEqual(second["chart_publication_interval_seconds"], .5)

    def test_two_hz_requires_exact_numeric_interval(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_2HZ_MODE
        for invalid in (None, True, False, 1, "0.5", 0, .25, float("nan"), float("inf"), -float("inf")):
            snapshot = drawn_native_gpu_graphics(mode)
            snapshot["graphics_diagnostics"]["chart_publication_interval_seconds"] = invalid
            with self.subTest(invalid=invalid), self.assertRaisesRegex(InvalidResult, "publication_interval"):
                memory.validate_graphics(snapshot, mode)
        snapshot = drawn_native_gpu_graphics(mode)
        del snapshot["graphics_diagnostics"]["chart_publication_interval_seconds"]
        with self.assertRaisesRegex(InvalidResult, "publication_interval"):
            memory.validate_graphics(snapshot, mode)

    def test_legacy_absence_is_allowed_but_supplied_old_mode_interval_is_one_second(self):
        for mode in ("normal", memory.DEFERRED_TOOL_GEOMETRY_MODE):
            snapshot = native_normal_graphics() if mode == "normal" else drawn_native_gpu_graphics(mode)
            self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])
            for interval in (1, 1.0):
                snapshot["graphics_diagnostics"]["chart_publication_interval_seconds"] = interval
                self.assertEqual(memory.validate_graphics(snapshot, mode)["chart_publication_interval_seconds"], 1)
            for invalid in (None, True, .5, "1", float("nan"), float("inf")):
                snapshot["graphics_diagnostics"]["chart_publication_interval_seconds"] = invalid
                with self.subTest(mode=mode, invalid=invalid), self.assertRaisesRegex(InvalidResult, "publication_interval"):
                    memory.validate_graphics(snapshot, mode)

    def test_capture_pins_cadence_presence_and_value(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_MODE
        for initially_present in (False, True):
            diagnostic = memory.MemoryDiagnostic(Path("/unused"), memory.MemoryDeadline(), mode)
            snapshot = drawn_native_gpu_graphics(mode)
            if initially_present:
                snapshot["graphics_diagnostics"]["chart_publication_interval_seconds"] = 1.0
            diagnostic.validate_graphics_snapshot(snapshot)
            diagnostic.validate_graphics_snapshot(snapshot)
            if initially_present:
                self.assertEqual(diagnostic.report["chart_publication_interval_seconds"], 1.0)
                del snapshot["graphics_diagnostics"]["chart_publication_interval_seconds"]
            else:
                snapshot["graphics_diagnostics"]["chart_publication_interval_seconds"] = 1.0
            with self.subTest(initially_present=initially_present), self.assertRaisesRegex(InvalidResult, "changed or disappeared"):
                diagnostic.validate_graphics_snapshot(snapshot)


class DeferredToolGeometryGraphicsTests(unittest.TestCase):
    def test_candidate_inherits_current_normal_without_compaction(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_MODE
        snapshot = drawn_native_gpu_graphics(mode)
        flags = memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["runtime_feature_contract"]
        self.assertTrue(all(flags[field] for field in memory.RUNTIME_FLAGS +
                            ("unpromised_stream_body_writes", "canvas_frame_clock", "ordered_chart_publication",
                             "arrival_effects_enabled", "deferred_tool_geometry_enabled")))
        self.assertTrue(all(flags[field] is False for field in
                            ("shared_chart_preparation", "stable_decoration_hosts", "direct_tool_plot",
                             "ungrouped_native_canvas", "compact_tool_paths_enabled")))
        for field in flags:
            changed = copy.deepcopy(snapshot)
            changed["graphics_diagnostics"][field] = not flags[field]
            with self.subTest(field=field), self.assertRaises(InvalidResult):
                memory.validate_graphics(changed, mode)

    def test_deferred_flag_is_required_typed_and_forbidden_on_other_modes(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_MODE
        for invalid in (None, False, 0, "true"):
            snapshot = drawn_native_gpu_graphics(mode)
            if invalid is None:
                del snapshot["graphics_diagnostics"]["deferred_tool_geometry_enabled"]
            else:
                snapshot["graphics_diagnostics"]["deferred_tool_geometry_enabled"] = invalid
            with self.subTest(invalid=invalid), self.assertRaisesRegex(InvalidResult, "deferred_tool_geometry_enabled"):
                memory.validate_graphics(snapshot, mode)
        snapshot = drawn_native_gpu_graphics(mode)
        snapshot["graphics_diagnostics"].update(mode="normal", deferred_tool_geometry_enabled=False)
        self.assertTrue(memory.validate_graphics(snapshot, "normal")["available"])
        del snapshot["graphics_diagnostics"]["deferred_tool_geometry_enabled"]
        self.assertTrue(memory.validate_graphics(snapshot, "normal")["available"])
        snapshot["graphics_diagnostics"]["deferred_tool_geometry_enabled"] = True
        with self.assertRaisesRegex(InvalidResult, "deferred_tool_geometry_enabled"):
            memory.validate_graphics(snapshot, "normal")

    def test_deferred_paths_keep_complete_equal_vertex_counts(self):
        mode = memory.DEFERRED_TOOL_GEOMETRY_MODE
        for field in memory.TOOL_PATH_POINT_COUNTERS:
            snapshot = drawn_native_gpu_graphics(mode)
            del snapshot[field]
            with self.subTest(missing=field), self.assertRaisesRegex(InvalidResult, "complete UInt64"):
                memory.validate_graphics(snapshot, mode)
        snapshot = drawn_native_gpu_graphics(mode)
        snapshot["tool_path_output_points"] -= 1
        with self.assertRaisesRegex(InvalidResult, "Noncompact"):
            memory.validate_graphics(snapshot, mode)


class CompactToolPathGraphicsTests(unittest.TestCase):
    def test_candidate_is_current_normal_plus_only_compact_path_flag(self):
        snapshot = drawn_native_gpu_graphics(memory.COMPACT_TOOL_PATHS_MODE)
        result = memory.validate_graphics(snapshot, memory.COMPACT_TOOL_PATHS_MODE, completed_visible_workload=True)
        flags = result["runtime_feature_contract"]
        self.assertTrue(all(flags[field] for field in memory.RUNTIME_FLAGS +
                            ("unpromised_stream_body_writes", "canvas_frame_clock", "ordered_chart_publication",
                             "arrival_effects_enabled", "compact_tool_paths_enabled")))
        self.assertTrue(all(flags[field] is False for field in
                            ("shared_chart_preparation", "stable_decoration_hosts", "direct_tool_plot", "ungrouped_native_canvas")))
        for field in flags:
            changed = copy.deepcopy(snapshot)
            changed["graphics_diagnostics"][field] = not flags[field]
            with self.subTest(field=field), self.assertRaises(InvalidResult):
                memory.validate_graphics(changed, memory.COMPACT_TOOL_PATHS_MODE)

    def test_candidate_requires_complete_typed_points_and_real_reduction(self):
        mode = memory.COMPACT_TOOL_PATHS_MODE
        for field in memory.TOOL_PATH_POINT_COUNTERS:
            for invalid in (None, True, -1, 1.0, 2**64):
                snapshot = drawn_native_gpu_graphics(mode)
                snapshot[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)
        for input_count, output_count in ((0, 0), (30, 30), (30, 0), (30, 31)):
            snapshot = drawn_native_gpu_graphics(mode)
            snapshot.update(tool_path_input_points=input_count, tool_path_output_points=output_count)
            with self.subTest(input=input_count, output=output_count), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
        snapshot = drawn_native_gpu_graphics(mode)
        del snapshot["graphics_diagnostics"]["compact_tool_paths_enabled"]
        with self.assertRaisesRegex(InvalidResult, "compact_tool_paths_enabled"):
            memory.validate_graphics(snapshot, mode)

    def test_old_absent_group_and_nonnative_complete_fallback_are_compatible(self):
        for mode, snapshot in (("normal", native_normal_graphics()), ("empty-drawing", graphics("empty-drawing"))):
            self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])
        snapshot = graphics("empty-drawing")
        snapshot.update(tool_path_input_points=2**53 + 1, tool_path_output_points=2**53 + 1)
        self.assertTrue(memory.validate_graphics(snapshot, "empty-drawing")["available"])
        snapshot["tool_path_output_points"] -= 1
        with self.assertRaisesRegex(InvalidResult, "Noncompact"):
            memory.validate_graphics(snapshot, "empty-drawing")
        del snapshot["tool_path_output_points"]
        with self.assertRaisesRegex(InvalidResult, "complete UInt64"):
            memory.validate_graphics(snapshot, "empty-drawing")

    def test_normal_requires_equal_points_and_cannot_acknowledge_candidate(self):
        snapshot = drawn_native_gpu_graphics(memory.COMPACT_TOOL_PATHS_MODE)
        snapshot["graphics_diagnostics"].update(mode="normal", compact_tool_paths_enabled=False)
        snapshot["tool_path_output_points"] = snapshot["tool_path_input_points"]
        self.assertTrue(memory.validate_graphics(snapshot, "normal", completed_visible_workload=True)["available"])
        changed = copy.deepcopy(snapshot)
        changed["tool_path_output_points"] -= 1
        with self.assertRaisesRegex(InvalidResult, "Noncompact"):
            memory.validate_graphics(changed, "normal")
        snapshot["graphics_diagnostics"]["compact_tool_paths_enabled"] = True
        with self.assertRaisesRegex(InvalidResult, "compact_tool_paths_enabled"):
            memory.validate_graphics(snapshot, "normal")


class GraphicsTests(unittest.TestCase):
    def test_runtime_modes_require_exact_feature_contract_and_native_work(self):
        for mode in memory.RUNTIME_MODES:
            snapshot = drawn_native_gpu_graphics(mode)
            self.assertIsNotNone(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["runtime_feature_contract"])
            for field in memory.RUNTIME_FLAGS:
                for replacement in (None, 0, not snapshot["graphics_diagnostics"][field]):
                    changed = copy.deepcopy(snapshot)
                    if replacement is None:
                        del changed["graphics_diagnostics"][field]
                    else:
                        changed["graphics_diagnostics"][field] = replacement
                    with self.subTest(mode=mode, field=field, replacement=replacement), self.assertRaises(InvalidResult):
                        memory.validate_graphics(changed, mode)
            if mode == memory.METAL_FULL_CHART_MODE:
                snapshot["graphics_diagnostics"]["metal_full_chart"]["twinkle_frames"] = 0
            else:
                snapshot["graphics_diagnostics"]["retained_twinkles"]["animation_starts"] = 0
            with self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode, completed_visible_workload=True)

    def test_normal_runtime_contract_preserves_old_and_promoted_paths_but_cannot_disappear(self):
        self.assertIsNone(memory.runtime_feature_contract({}, "normal"))
        for enabled in (False, True):
            snapshot = native_normal_graphics()
            snapshot["graphics_diagnostics"].update(incremental_history_ordering=enabled,
                optimized_chart_preparation=enabled, lifecycle_effects_enabled=True)
            diagnostic = memory.MemoryDiagnostic(Path("/unused"), memory.MemoryDeadline(), "normal")
            diagnostic.validate_graphics_snapshot(snapshot)
            for field in memory.RUNTIME_FLAGS:
                changed = copy.deepcopy(snapshot)
                del changed["graphics_diagnostics"][field]
                with self.subTest(enabled=enabled, missing=field), self.assertRaises(InvalidResult):
                    diagnostic.validate_graphics_snapshot(changed)
            changed = copy.deepcopy(snapshot)
            for field in memory.RUNTIME_FLAGS:
                del changed["graphics_diagnostics"][field]
            with self.assertRaisesRegex(InvalidResult, "changed or disappeared"):
                diagnostic.validate_graphics_snapshot(changed)
            changed = copy.deepcopy(snapshot)
            changed["graphics_diagnostics"].update(incremental_history_ordering=not enabled,
                optimized_chart_preparation=not enabled)
            with self.assertRaisesRegex(InvalidResult, "changed or disappeared"):
                diagnostic.validate_graphics_snapshot(changed)


    def test_normal_preserves_old_renderer_snapshots_and_validates_new_combined_contract(self):
        legacy = graphics()
        value = legacy["graphics_diagnostics"]
        value.update(live_canvases=1, peak_live_canvases=1, live_renderers=1, peak_live_renderers=1)
        value["roles"]["static_chart"].update(created=1, live=1, peak_live=1, renderer_creations=1,
                                               live_renderers=1, peak_live_renderers=1, draws=3)
        result = memory.validate_graphics(legacy, "normal", completed_visible_workload=True)
        self.assertEqual(result["normal_rendering_contract"], "legacy")
        self.assertFalse(memory.validate_graphics({}, "normal")["available"])
        for drawn in (False, True):
            snapshot = native_normal_graphics(drawn=drawn)
            result = memory.validate_graphics(snapshot, "normal", completed_visible_workload=drawn)
            self.assertEqual(result["normal_rendering_contract"], "native-gpu-optimized")
            self.assertEqual(result["counters"]["mode"], "normal")

    def test_native_normal_requires_every_combined_metadata_and_execution_field(self):
        fields = ("native_gpu_backend", "native_gpu_canvas_draws", "scalar_presentation_coalesced",
                  "scalar_presentation_publications", "retained_twinkles_enabled",
                  "retained_twinkle_backend", "retained_twinkles")
        for field in fields:
            snapshot = native_normal_graphics(drawn=True)
            del snapshot["graphics_diagnostics"][field]
            with self.subTest(missing=field), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, "normal", completed_visible_workload=True)
        changes = (
            {"native_gpu_backend": "image-renderer"}, {"native_gpu_backend": None},
            {"scalar_presentation_coalesced": False}, {"retained_twinkles_enabled": False},
            {"scalar_presentation_publications": 0}, {"native_gpu_canvas_draws": 0},
            {"retained_twinkle_backend": "canvas"},
        )
        for change in changes:
            snapshot = native_normal_graphics(drawn=True)
            snapshot["graphics_diagnostics"].update(change)
            with self.subTest(change=change), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, "normal", completed_visible_workload=True)
        snapshot = native_normal_graphics(drawn=True)
        snapshot["graphics_diagnostics"]["retained_twinkles"]["animation_starts"] = 0
        with self.assertRaisesRegex(InvalidResult, "did not submit"):
            memory.validate_graphics(snapshot, "normal", completed_visible_workload=True)

    def test_unmarked_legacy_normal_cannot_claim_new_rendering_or_optimization_activity(self):
        for change in ({"native_gpu_canvas_draws": 1}, {"native_gpu_canvas_draws": True},
                       {"scalar_presentation_coalesced": True}, {"scalar_presentation_coalesced": 0},
                       {"retained_twinkles_enabled": True}, {"retained_twinkles_enabled": 0},
                       {"retained_twinkle_backend": "core-animation-shape-layers"}):
            snapshot = graphics()
            snapshot["graphics_diagnostics"].update(change)
            with self.subTest(change=change), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, "normal")
        snapshot = graphics()
        snapshot["graphics_diagnostics"].update(native_gpu_canvas_draws=0, scalar_presentation_coalesced=False,
                                                retained_twinkles_enabled=False)
        self.assertEqual(memory.validate_graphics(snapshot, "normal")["normal_rendering_contract"], "legacy")

    def test_native_normal_rejects_fallback_and_requires_release_when_closed(self):
        for field in ("live_renderers", "peak_bitmap_bytes", "peak_layer_image_bytes", "layer_bitmap_presentations"):
            snapshot = native_normal_graphics(drawn=True)
            snapshot["graphics_diagnostics"][field] = 1
            with self.subTest(field=field), self.assertRaisesRegex(InvalidResult, "fallback"):
                memory.validate_graphics(snapshot, "normal")
        snapshot = native_normal_graphics(drawn=True)
        with self.assertRaisesRegex(InvalidResult, "closed checkpoint"):
            memory.validate_graphics(snapshot, "normal", expected_closed=True)
        value = snapshot["graphics_diagnostics"]
        value["live_canvases"] = value["current_pixel_area"] = 0
        value["roles"]["static_chart"].update(destroyed=1, live=0, current_pixel_area=0)
        with self.assertRaisesRegex(InvalidResult, "Retained twinkle resources remain live"):
            memory.validate_graphics(snapshot, "normal", expected_closed=True)
        value["retained_twinkles"].update(hosts_destroyed=1, live_hosts=0, instances_destroyed=2, live_instances=0)
        self.assertTrue(memory.validate_graphics(snapshot, "normal", expected_closed=True)["available"])

    def test_normal_run_latches_native_contract_and_rejects_disappearance_in_later_snapshots(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal")
            self.assertFalse(diagnostic.require_native_normal)
            diagnostic.validate_graphics_snapshot(native_normal_graphics())
            self.assertTrue(diagnostic.require_native_normal)
            self.assertEqual(diagnostic.report["normal_rendering_contract"], "native-gpu-optimized")
            for snapshot in (graphics(), {}):
                with self.subTest(snapshot=snapshot), self.assertRaisesRegex(InvalidResult, "disappeared"):
                    diagnostic.validate_control_snapshot(snapshot)
                diagnostic.collector = mock.Mock()
                diagnostic.collector.command.return_value = {"status": "ok", "snapshot": snapshot}
                with mock.patch.object(diagnostic, "verify_identity"), self.assertRaisesRegex(InvalidResult, "disappeared"):
                    diagnostic.command("show_dashboard")
            self.assertTrue(diagnostic.validate_graphics_snapshot(native_normal_graphics(drawn=True),
                                                                 completed_visible_workload=True)["available"])
            self.assertEqual(diagnostic.report["normal_rendering_contract"], "native-gpu-optimized")

    def test_legacy_normal_run_does_not_assume_new_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal")
            diagnostic.validate_graphics_snapshot({})
            self.assertEqual(diagnostic.report["normal_rendering_contract"], "unavailable")
            diagnostic.validate_graphics_snapshot(graphics())
            self.assertEqual(diagnostic.report["normal_rendering_contract"], "legacy")
            self.assertFalse(diagnostic.require_native_normal)

    def test_coalesced_modes_require_actual_integer_publications_and_other_modes_reject_them(self):
        for mode in memory.GRAPHICS_MODES:
            snapshot = drawn_native_gpu_graphics(mode) if mode in memory.NATIVE_GPU_MODES else graphics(mode)
            snapshot["graphics_diagnostics"]["scalar_presentation_publications"] = 0
            self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])
            if mode in memory.COALESCED_SCALAR_MODES:
                with self.subTest(mode=mode, zero_publications=True), self.assertRaisesRegex(InvalidResult, "did not publish"):
                    memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
                del snapshot["graphics_diagnostics"]["scalar_presentation_publications"]
                with self.subTest(mode=mode, missing=True), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)
            else:
                snapshot["graphics_diagnostics"]["scalar_presentation_publications"] = 1
                with self.subTest(mode=mode, unexpected_publication=True), self.assertRaisesRegex(InvalidResult, "outside a coalesced-scalar mode"):
                    memory.validate_graphics(snapshot, mode)
            for wrong in (None, True, -1, 1.0, "1"):
                snapshot["graphics_diagnostics"]["scalar_presentation_publications"] = wrong
                with self.subTest(mode=mode, invalid=wrong), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)

    def test_native_gpu_optimization_flags_are_exact_and_only_baseline_allows_omission(self):
        for mode in memory.NATIVE_GPU_MODES:
            expected = {"scalar_presentation_coalesced": mode in memory.COALESCED_SCALAR_MODES,
                        "retained_twinkles_enabled": mode in memory.RETAINED_TWINKLE_MODES}
            snapshot = drawn_native_gpu_graphics(mode)
            snapshot["graphics_diagnostics"].update(expected)
            self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])
            for field, correct in expected.items():
                missing = copy.deepcopy(snapshot)
                del missing["graphics_diagnostics"][field]
                if mode == "native-gpu-canvas":
                    self.assertTrue(memory.validate_graphics(missing, mode)["available"])
                else:
                    with self.subTest(mode=mode, field=field, missing=True), self.assertRaisesRegex(InvalidResult, field):
                        memory.validate_graphics(missing, mode)
                for wrong in (None, 0, 1, "false", not correct):
                    invalid = copy.deepcopy(snapshot)
                    invalid["graphics_diagnostics"][field] = wrong
                    with self.subTest(mode=mode, field=field, wrong=wrong), self.assertRaisesRegex(InvalidResult, field):
                        memory.validate_graphics(invalid, mode)

    def test_all_native_gpu_variants_keep_canvas_backend_draw_and_fallback_requirements(self):
        changes = (
            lambda value: value.update(native_gpu_backend="image-renderer"),
            lambda value: value.update(native_gpu_canvas_draws=2),
            lambda value: value.update(peak_bitmap_bytes=1),
            lambda value: value.update(peak_layer_image_bytes=1),
            lambda value: value["roles"]["static_chart"].update(renderer_creations=1),
        )
        for mode in memory.NATIVE_GPU_MODES:
            self.assertTrue(memory.validate_graphics(drawn_native_gpu_graphics(mode), mode, completed_visible_workload=True)["available"])
            for change in changes:
                snapshot = drawn_native_gpu_graphics(mode)
                change(snapshot["graphics_diagnostics"])
                with self.subTest(mode=mode, change=change), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)

    def test_retained_twinkles_require_exact_backend_and_complete_integer_counters(self):
        for mode in memory.RETAINED_TWINKLE_MODES:
            for wrong in (None, True, "canvas", "core-animation"):
                snapshot = graphics(mode)
                snapshot["graphics_diagnostics"]["retained_twinkle_backend"] = wrong
                with self.subTest(mode=mode, backend=wrong), self.assertRaisesRegex(InvalidResult, "shape-layer backend"):
                    memory.validate_graphics(snapshot, mode)
            for container in (None, "missing", []):
                snapshot = graphics(mode)
                if container == "missing":
                    del snapshot["graphics_diagnostics"]["retained_twinkles"]
                else:
                    snapshot["graphics_diagnostics"]["retained_twinkles"] = container
                with self.subTest(mode=mode, counters=container), self.assertRaisesRegex(InvalidResult, "counters are missing"):
                    memory.validate_graphics(snapshot, mode)
            for field in memory.RETAINED_TWINKLE_FIELDS:
                for wrong in (None, True, -1, 0.0, "0"):
                    snapshot = graphics(mode)
                    snapshot["graphics_diagnostics"]["retained_twinkles"][field] = wrong
                    with self.subTest(mode=mode, field=field, wrong=wrong), self.assertRaises(InvalidResult):
                        memory.validate_graphics(snapshot, mode)
                snapshot = graphics(mode)
                del snapshot["graphics_diagnostics"]["retained_twinkles"][field]
                with self.subTest(mode=mode, field=field, missing=True), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)

    def test_retained_twinkle_lifecycle_and_two_instance_bound_reject_impossible_evidence(self):
        changes = (
            {"hosts_destroyed": 1}, {"instances_destroyed": 1},
            {"peak_hosts": 0}, {"peak_instances": 1},
            {"peak_hosts": 2}, {"peak_instances": 3},
            {"instances_created": 3, "live_instances": 3, "peak_instances": 3},
            {"instances_created": 3, "instances_destroyed": 1, "peak_instances": 3},
            {"hosts_destroyed": 1, "live_hosts": 0},
        )
        for mode in memory.RETAINED_TWINKLE_MODES:
            for change in changes:
                snapshot = drawn_native_gpu_graphics(mode)
                snapshot["graphics_diagnostics"]["retained_twinkles"].update(change)
                with self.subTest(mode=mode, change=change), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)
            snapshot = drawn_native_gpu_graphics(mode)
            value = snapshot["graphics_diagnostics"]
            value["live_canvases"] = value["current_pixel_area"] = 0
            for role in value["roles"].values():
                role.update(destroyed=role["created"], live=0, current_pixel_area=0)
            with self.subTest(mode=mode), self.assertRaisesRegex(InvalidResult, "Retained twinkle resources remain live"):
                memory.validate_graphics(snapshot, mode, expected_closed=True)
            value["retained_twinkles"].update(hosts_destroyed=1, live_hosts=0, instances_destroyed=2, live_instances=0)
            self.assertTrue(memory.validate_graphics(snapshot, mode, expected_closed=True, completed_visible_workload=True)["available"])

    def test_retained_modes_must_create_instances_and_submit_animations_during_visible_work(self):
        for mode in memory.RETAINED_TWINKLE_MODES:
            snapshot = drawn_native_gpu_graphics(mode)
            snapshot["graphics_diagnostics"]["retained_twinkles"]["animation_starts"] = 0
            with self.subTest(mode=mode, zero_animation_starts=True), self.assertRaisesRegex(InvalidResult, "did not submit"):
                memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
            snapshot["graphics_diagnostics"]["retained_twinkles"] = dict.fromkeys(memory.RETAINED_TWINKLE_FIELDS, 0)
            self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])
            with self.subTest(mode=mode, zero_instances=True), self.assertRaisesRegex(InvalidResult, "did not submit"):
                memory.validate_graphics(snapshot, mode, completed_visible_workload=True)

    def test_nonretained_modes_reject_any_retained_activity_when_counters_are_exposed(self):
        for mode in set(memory.GRAPHICS_MODES) - set(memory.RETAINED_TWINKLE_MODES):
            snapshot = graphics(mode)
            snapshot["graphics_diagnostics"]["retained_twinkles"] = dict.fromkeys(memory.RETAINED_TWINKLE_FIELDS, 0)
            self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])
            for field in memory.RETAINED_TWINKLE_FIELDS:
                invalid = copy.deepcopy(snapshot)
                invalid["graphics_diagnostics"]["retained_twinkles"][field] = 1
                with self.subTest(mode=mode, field=field), self.assertRaisesRegex(InvalidResult, "outside a retained-twinkle mode"):
                    memory.validate_graphics(invalid, mode)

    def test_retained_evidence_is_checked_in_command_and_control_snapshots(self):
        for mode in memory.RETAINED_TWINKLE_MODES:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), mode)
                snapshot = drawn_native_gpu_graphics(mode)
                snapshot["graphics_diagnostics"]["retained_twinkles"]["hosts_destroyed"] = 1
                diagnostic.collector = mock.Mock()
                diagnostic.collector.command.return_value = {"status": "ok", "snapshot": snapshot}
                with mock.patch.object(diagnostic, "verify_identity"), self.assertRaises(InvalidResult):
                    diagnostic.command("show_dashboard")
                with self.assertRaises(InvalidResult):
                    diagnostic.validate_control_snapshot(snapshot)

    def test_native_gpu_requires_exact_backend_and_integer_callback_evidence(self):
        mode = "native-gpu-canvas"
        self.assertTrue(memory.validate_graphics(graphics(mode), mode)["available"])
        for field, invalid_values in (
                ("native_gpu_backend", (None, True, "metal", "swiftui-canvas", "bitmap-layer-destination")),
                ("native_gpu_canvas_draws", (None, True, -1, 0.0, "0"))):
            for invalid in invalid_values:
                snapshot = graphics(mode)
                snapshot["graphics_diagnostics"][field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)
            snapshot = graphics(mode)
            del snapshot["graphics_diagnostics"][field]
            with self.subTest(field=field, missing=True), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode)

    def test_native_gpu_callback_count_must_match_role_draws_and_execute_static_chart(self):
        mode = "native-gpu-canvas"
        self.assertTrue(memory.validate_graphics(drawn_native_gpu_graphics(), mode, completed_visible_workload=True)["available"])
        for count in (0, 2, 4):
            snapshot = drawn_native_gpu_graphics()
            snapshot["graphics_diagnostics"]["native_gpu_canvas_draws"] = count
            with self.subTest(count=count), self.assertRaisesRegex(InvalidResult, "callbacks do not reconcile"):
                memory.validate_graphics(snapshot, mode)
        snapshot = drawn_native_gpu_graphics()
        value = snapshot["graphics_diagnostics"]
        value["roles"]["static_chart"]["draws"] = 0
        value["roles"]["rail_decorations"]["draws"] = 3
        with self.assertRaisesRegex(InvalidResult, "static-chart drawing"):
            memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
        with self.assertRaisesRegex(InvalidResult, "static-chart drawing"):
            memory.validate_graphics(graphics(mode), mode, completed_visible_workload=True)

    def test_native_gpu_rejects_any_renderer_or_cpu_bitmap_fallback_history(self):
        mode = "native-gpu-canvas"
        global_fields = ("live_renderers", "peak_live_renderers", "current_bitmap_bytes", "peak_bitmap_bytes",
                         "current_layer_image_bytes", "peak_layer_image_bytes", "layer_bitmap_presentations",
                         "layer_bitmap_failures", "layer_bitmap_native_draws")
        role_fields = ("renderer_creations", "renderer_updates", "renderer_destructions", "live_renderers",
                       "peak_live_renderers", "current_bitmap_bytes", "peak_bitmap_bytes",
                       "current_layer_image_bytes", "peak_layer_image_bytes")
        for role in (None, "static_chart", "cursor", "rail_bars", "rail_decorations"):
            for field in global_fields if role is None else role_fields:
                snapshot = drawn_native_gpu_graphics()
                counters = snapshot["graphics_diagnostics"]
                if role is not None:
                    counters = counters["roles"][role]
                for invalid in (1, True, "0"):
                    counters[field] = invalid
                    with self.subTest(role=role, field=field, invalid=invalid), self.assertRaises(InvalidResult):
                        memory.validate_graphics(snapshot, mode)
                counters[field] = 0
                self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])

    def test_native_gpu_closed_state_requires_released_canvases_and_geometry(self):
        mode = "native-gpu-canvas"
        snapshot = drawn_native_gpu_graphics()
        with self.assertRaisesRegex(InvalidResult, "closed checkpoint"):
            memory.validate_graphics(snapshot, mode, expected_closed=True)
        value = snapshot["graphics_diagnostics"]
        value["live_canvases"] = 0
        value["roles"]["static_chart"].update(destroyed=1, live=0)
        with self.assertRaisesRegex(InvalidResult, "retains pixel area"):
            memory.validate_graphics(snapshot, mode)
        value["current_pixel_area"] = value["roles"]["static_chart"]["current_pixel_area"] = 0
        self.assertTrue(memory.validate_graphics(snapshot, mode, expected_closed=True)["available"])
        value["roles"]["static_chart"]["max_scale"] = float("nan")
        with self.assertRaises(InvalidResult):
            memory.validate_graphics(snapshot, mode)

    def test_native_gpu_requirements_do_not_change_normal_or_frozen_layer_evidence(self):
        self.assertTrue(memory.validate_graphics(graphics(), "normal")["available"])
        self.assertTrue(memory.validate_graphics(drawn_layer_graphics(), "bitmap-layer-destination")["available"])
        self.assertFalse(memory.validate_graphics({}, "normal")["available"])

    def test_native_gpu_backend_drift_is_rejected_in_command_and_control_snapshots(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "native-gpu-canvas")
            snapshot = drawn_native_gpu_graphics()
            snapshot["graphics_diagnostics"]["native_gpu_backend"] = "image-renderer"
            diagnostic.collector = mock.Mock()
            diagnostic.collector.command.return_value = {"status": "ok", "snapshot": snapshot}
            with mock.patch.object(diagnostic, "verify_identity"), self.assertRaises(InvalidResult):
                diagnostic.command("show_dashboard")
            with self.assertRaises(InvalidResult):
                diagnostic.validate_control_snapshot(snapshot)

    def test_layer_variants_require_exact_metadata_and_original_mode_accepts_legacy_omission(self):
        for mode in memory.LAYER_DESTINATION_MODES:
            expected = {
                "layer_bitmap_pixel_format": "bgra8-premultiplied-first" if mode == "bitmap-layer-bgra" else "rgba8-premultiplied-last",
                "layer_bitmap_color_space": "device-rgb",
                "rail_decorations_enabled": mode != "bitmap-layer-no-decorations",
            }
            snapshot = drawn_layer_graphics(mode)
            snapshot["graphics_diagnostics"].update(expected)
            self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])
            for field, correct in expected.items():
                missing = copy.deepcopy(snapshot)
                del missing["graphics_diagnostics"][field]
                if mode == "bitmap-layer-destination":
                    self.assertTrue(memory.validate_graphics(missing, mode)["available"])
                else:
                    with self.subTest(mode=mode, missing=field), self.assertRaisesRegex(InvalidResult, field):
                        memory.validate_graphics(missing, mode)
                for wrong in (None, 0, 1, "wrong", not correct if type(correct) is bool else False):
                    invalid = copy.deepcopy(snapshot)
                    invalid["graphics_diagnostics"][field] = wrong
                    with self.subTest(mode=mode, field=field, wrong=wrong), self.assertRaisesRegex(InvalidResult, field):
                        memory.validate_graphics(invalid, mode)
            swapped = copy.deepcopy(snapshot)
            swapped["graphics_diagnostics"]["layer_bitmap_pixel_format"] = (
                "rgba8-premultiplied-last" if mode == "bitmap-layer-bgra" else "bgra8-premultiplied-first")
            with self.subTest(mode=mode, swapped_pixel_format=True), self.assertRaisesRegex(InvalidResult, "pixel_format"):
                memory.validate_graphics(swapped, mode)

    def test_all_layer_variants_reject_missing_or_inconsistent_image_and_frame_evidence(self):
        changes = (
            lambda value: value.pop("layer_bitmap_presentations"),
            lambda value: value.update(layer_bitmap_presentations=2),
            lambda value: value.update(layer_bitmap_failures=1),
            lambda value: value.update(layer_bitmap_native_draws=1),
            lambda value: value.update(current_layer_image_bytes=399),
            lambda value: value.update(peak_layer_image_bytes=401),
            lambda value: value["roles"]["static_chart"].pop("peak_layer_image_bytes"),
            lambda value: value["roles"]["static_chart"].update(current_layer_image_bytes=True),
            lambda value: value["roles"]["static_chart"].update(renderer_creations=0),
        )
        for mode in memory.LAYER_DESTINATION_MODES:
            self.assertTrue(memory.validate_graphics(graphics(mode), mode)["available"])
            self.assertTrue(memory.validate_graphics(drawn_layer_graphics(mode), mode, completed_visible_workload=True)["available"])
            with self.subTest(mode=mode, empty_workload=True), self.assertRaisesRegex(InvalidResult, "did not present"):
                memory.validate_graphics(graphics(mode), mode, completed_visible_workload=True)
            with self.subTest(mode=mode, retained_when_closed=True), self.assertRaisesRegex(InvalidResult, "retains layer image"):
                memory.validate_graphics(drawn_layer_graphics(mode), mode, expected_closed=True)
            for change in changes:
                snapshot = drawn_layer_graphics(mode)
                change(snapshot["graphics_diagnostics"])
                with self.subTest(mode=mode, change=change), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode, completed_visible_workload=True)

    def test_no_decorations_rejects_every_role_counter_even_if_lifecycle_would_otherwise_reconcile(self):
        mode = "bitmap-layer-no-decorations"
        for field in graphics(mode)["graphics_diagnostics"]["roles"]["rail_decorations"]:
            snapshot = drawn_layer_graphics(mode)
            snapshot["graphics_diagnostics"]["roles"]["rail_decorations"][field] = 1
            with self.subTest(field=field), self.assertRaisesRegex(InvalidResult, "Rail decoration work"):
                memory.validate_graphics(snapshot, mode)
        snapshot = drawn_layer_graphics(mode)
        # Even a created-and-destroyed surface with no remaining allocation is leakage.
        snapshot["graphics_diagnostics"]["roles"]["rail_decorations"].update(created=1, destroyed=1, peak_live=1)
        snapshot["graphics_diagnostics"]["peak_live_canvases"] = 2
        with self.assertRaisesRegex(InvalidResult, "Rail decoration work"):
            memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
        for control in ("bitmap-layer-destination", "bitmap-layer-bgra"):
            snapshot = drawn_layer_graphics(control)
            snapshot["graphics_diagnostics"]["roles"]["rail_decorations"]["updates"] = 1
            self.assertTrue(memory.validate_graphics(snapshot, control)["available"])

    def test_layer_destination_requires_all_new_fields_without_breaking_old_modes(self):
        for mode in memory.GRAPHICS_MODES:
            self.assertTrue(memory.validate_graphics(graphics(mode), mode)["available"])
        for field in ("layer_bitmap_presentations", "layer_bitmap_failures", "layer_bitmap_native_draws",
                      "current_layer_image_bytes", "peak_layer_image_bytes"):
            for invalid in (None, True, -1, 0.0, "0"):
                snapshot = graphics("bitmap-layer-destination")
                snapshot["graphics_diagnostics"][field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, "bitmap-layer-destination")
            snapshot = graphics("bitmap-layer-destination")
            del snapshot["graphics_diagnostics"][field]
            with self.subTest(field=field, invalid="missing"), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, "bitmap-layer-destination")
        for role in graphics()["graphics_diagnostics"]["roles"]:
            for field in ("current_layer_image_bytes", "peak_layer_image_bytes"):
                snapshot = graphics("bitmap-layer-destination")
                del snapshot["graphics_diagnostics"]["roles"][role][field]
                with self.subTest(role=role, field=field), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, "bitmap-layer-destination")

    def test_layer_destination_rejects_failure_or_native_drawing_in_control_snapshots(self):
        for field in ("layer_bitmap_failures", "layer_bitmap_native_draws"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "bitmap-layer-destination")
                snapshot = graphics("bitmap-layer-destination")
                snapshot["graphics_diagnostics"][field] = 1
                diagnostic.collector = mock.Mock()
                diagnostic.collector.command.return_value = {"status": "ok", "snapshot": snapshot}
                with mock.patch.object(diagnostic, "verify_identity"), self.assertRaises(InvalidResult):
                    diagnostic.command("show_dashboard")
                with self.assertRaises(InvalidResult):
                    diagnostic.validate_control_snapshot(snapshot)

    def test_layer_destination_requires_visible_work_and_image_lifecycle_evidence(self):
        mode = "bitmap-layer-destination"
        with self.assertRaisesRegex(InvalidResult, "did not present"):
            memory.validate_graphics(graphics(mode), mode, completed_visible_workload=True)
        self.assertTrue(memory.validate_graphics(drawn_layer_graphics(), mode, completed_visible_workload=True)["available"])
        for change in (lambda value: value.update(layer_bitmap_presentations=0),
                       lambda value: value["roles"]["static_chart"].update(draws=0),
                       lambda value: value["roles"]["rail_decorations"].update(draws=1),
                       lambda value: value.update(current_layer_image_bytes=399),
                       lambda value: value.update(peak_layer_image_bytes=401)):
            snapshot = drawn_layer_graphics()
            change(snapshot["graphics_diagnostics"])
            with self.subTest(change=change), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
        snapshot = drawn_layer_graphics()
        with self.assertRaisesRegex(InvalidResult, "retains layer image"):
            memory.validate_graphics(snapshot, mode, expected_closed=True)
        value = snapshot["graphics_diagnostics"]
        value.update(live_canvases=0, live_renderers=0)
        value["roles"]["static_chart"].update(destroyed=1, live=0, renderer_destructions=1, live_renderers=0)
        with self.assertRaisesRegex(InvalidResult, "retains layer image"):
            memory.validate_graphics(snapshot, mode)
        value["current_layer_image_bytes"] = value["roles"]["static_chart"]["current_layer_image_bytes"] = 0
        self.assertTrue(memory.validate_graphics(snapshot, mode, expected_closed=True)["available"])

    def test_layer_image_global_peak_can_be_between_role_peak_and_sum(self):
        snapshot = graphics("bitmap-layer-destination")
        value = snapshot["graphics_diagnostics"]
        for role in value["roles"].values():
            role["peak_layer_image_bytes"] = 100
        value["peak_layer_image_bytes"] = 150
        self.assertTrue(memory.validate_graphics(snapshot, "bitmap-layer-destination")["available"])
        value["peak_layer_image_bytes"] = 99
        with self.assertRaisesRegex(InvalidResult, "below a role peak"):
            memory.validate_graphics(snapshot, "bitmap-layer-destination")

    def test_layer_presentations_must_match_all_draws_before_workload_completes(self):
        for count in (0, 2, 4):
            snapshot = drawn_layer_graphics()
            snapshot["graphics_diagnostics"]["layer_bitmap_presentations"] = count
            with self.subTest(count=count), self.assertRaisesRegex(InvalidResult, "presentations do not reconcile"):
                memory.validate_graphics(snapshot, "bitmap-layer-destination")
        snapshot = drawn_layer_graphics()
        snapshot["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = 1
        with self.assertRaisesRegex(InvalidResult, "presentations do not reconcile"):
            memory.validate_graphics(snapshot, "bitmap-layer-destination")
        snapshot["graphics_diagnostics"]["layer_bitmap_presentations"] = 4
        self.assertTrue(memory.validate_graphics(snapshot, "bitmap-layer-destination")["available"])

    def test_popover_animation_flag_requires_explicit_false_and_preserves_legacy_default(self):
        for snapshot in ({}, {"popover_animations_enabled": True}, {"popover_animations_enabled": 0}):
            with self.subTest(snapshot=snapshot), self.assertRaises(InvalidResult):
                memory.validate_popover_animation(snapshot, True)
        self.assertEqual(memory.validate_popover_animation({"popover_animations_enabled": False}, True),
                         {"available": True, "popover_animations_enabled": False})
        self.assertFalse(memory.validate_popover_animation({}, False)["available"])
        for actual in (True, False):
            self.assertIs(memory.validate_popover_animation({"popover_animations_enabled": actual}, False)["popover_animations_enabled"], actual)

    def test_animation_cli_default_omits_config_override_and_flag_passes_false(self):
        arguments = ["--app-binary", "app", "--test-bundle", "tests", "--collector-binary", "collector", "--provenance", "provenance"]
        self.assertFalse(memory.parser().parse_args(arguments).no_popover_animation)
        self.assertTrue(memory.parser().parse_args(arguments + ["--no-popover-animation"]).no_popover_animation)
        for requested in (False, True):
            with self.subTest(requested=requested), tempfile.TemporaryDirectory() as directory:
                diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal", requested)
                with mock.patch.object(memory.app, "path_hash", return_value="hash"), \
                        mock.patch.object(memory.app, "launch_fixture", return_value=(mock.Mock(), "http://127.0.0.1:9999")), \
                        mock.patch.object(memory.app, "Collector", side_effect=InvalidResult("stop before launch")) as collector:
                    with self.assertRaisesRegex(InvalidResult, "stop before launch"):
                        diagnostic.perform({"app": Path("app"), "collector": Path("collector")}, {}, {})
                config = collector.call_args.args[2]
                self.assertEqual("popover_animations_enabled" in config, requested)
                if requested:
                    self.assertIs(config["popover_animations_enabled"], False)
                self.assertIs(diagnostic.report["no_popover_animation_requested"], requested)

    def test_cpu_glow_requires_proof_that_no_framework_fallback_occurred(self):
        for value in (None, True, -1, 1):
            snapshot = graphics("cpu-glow")
            snapshot["graphics_diagnostics"]["cpu_glow_fallbacks"] = value
            with self.subTest(value=value), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, "cpu-glow")

    def test_old_normal_app_explicitly_has_unavailable_counters(self):
        result = memory.validate_graphics({}, "normal")
        self.assertFalse(result["available"])
        self.assertIn("does not expose", result["reason"])
        self.assertNotIn("counters", result)

    def test_gradient_controls_require_exact_nonnegative_integer_evidence(self):
        for mode in memory.GRADIENT_ABLATION_MODES:
            snapshot = graphics(mode)
            del snapshot["graphics_diagnostics"]["gradient_substitutions"]
            with self.subTest(mode=mode, value="missing"), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, mode)
            for value in (None, False, True, -1, 0.0, 1.5, "1"):
                snapshot["graphics_diagnostics"]["gradient_substitutions"] = value
                with self.subTest(mode=mode, value=value), self.assertRaises(InvalidResult):
                    memory.validate_graphics(snapshot, mode)
            for value in (0, 1, 250):
                snapshot["graphics_diagnostics"]["gradient_substitutions"] = value
                self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])

    def test_gradient_controls_must_execute_before_visible_workload_can_complete(self):
        for mode in memory.GRADIENT_ABLATION_MODES:
            snapshot = graphics(mode)
            self.assertTrue(memory.validate_graphics(snapshot, mode)["available"])
            with self.subTest(mode=mode), self.assertRaisesRegex(InvalidResult, "did not execute"):
                memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
            snapshot["graphics_diagnostics"]["gradient_substitutions"] = 1
            self.assertTrue(memory.validate_graphics(snapshot, mode, completed_visible_workload=True)["available"])

    def test_older_normal_graphics_counters_need_no_gradient_field(self):
        snapshot = graphics()
        del snapshot["graphics_diagnostics"]["gradient_substitutions"]
        self.assertTrue(memory.validate_graphics(snapshot, "normal", completed_visible_workload=True)["available"])
        self.assertFalse(memory.validate_graphics({}, "normal", completed_visible_workload=True)["available"])

    def test_command_acknowledgments_and_control_snapshots_check_gradient_evidence(self):
        for mode in memory.GRADIENT_ABLATION_MODES:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), mode)
                snapshot = graphics(mode)
                del snapshot["graphics_diagnostics"]["gradient_substitutions"]
                diagnostic.collector = mock.Mock()
                diagnostic.collector.command.return_value = {"status": "ok", "snapshot": snapshot}
                with mock.patch.object(diagnostic, "verify_identity"), self.assertRaises(InvalidResult):
                    diagnostic.command("show_dashboard")
                with self.assertRaises(InvalidResult):
                    diagnostic.validate_control_snapshot(snapshot)

    def test_missing_alternate_or_null_normal_counters_rejected(self):
        for mode in memory.GRAPHICS_MODES[1:]:
            with self.subTest(mode=mode), self.assertRaises(InvalidResult):
                memory.validate_graphics({}, mode)
        with self.assertRaises(InvalidResult):
            memory.validate_graphics({"graphics_diagnostics": None}, "normal")

    def test_all_modes_require_exact_acknowledgment(self):
        for mode in memory.GRAPHICS_MODES:
            with self.subTest(mode=mode):
                self.assertTrue(memory.validate_graphics(graphics(mode), mode)["available"])
        with self.assertRaises(InvalidResult):
            memory.validate_graphics(graphics("normal"), "direct-host")

    def test_invalid_lifecycle_counts_and_dimensions_fail(self):
        for field, value in (("destroyed", 1), ("live", True), ("max_scale", float("nan")), ("draws", -1)):
            snapshot = graphics()
            snapshot["graphics_diagnostics"]["roles"]["cursor"][field] = value
            with self.subTest(field=field), self.assertRaises(InvalidResult):
                memory.validate_graphics(snapshot, "normal")

    def test_global_peaks_need_not_equal_sum_of_role_peaks(self):
        snapshot = graphics()
        for role in snapshot["graphics_diagnostics"]["roles"].values():
            role.update(created=1, destroyed=1, peak_live=1)
        snapshot["graphics_diagnostics"]["peak_live_canvases"] = 2
        self.assertTrue(memory.validate_graphics(snapshot, "normal")["available"])
        snapshot["graphics_diagnostics"]["live_canvases"] = 1
        with self.assertRaisesRegex(InvalidResult, "total mismatch"):
            memory.validate_graphics(snapshot, "normal")


class WorkloadCPUAndInspectionTests(unittest.TestCase):
    def evidence(self):
        points = [{"type": "sample", "process_id": 17, "birth_time_us": 123,
                   "monotonic_seconds": index / 4,
                   "cpu_seconds": 3 + index / 100 + (0.2 if index >= 8 else 0),
                   "physical_footprint_bytes": 1000000, "lifetime_peak_footprint_bytes": 1000000,
                   "phase": "baseline" if index == 0 else "final" if index == 16
                            else "control_boundary" if index in (1, 4, 12) else "periodic",
                   **({"command_id": "collector-handshake"} if index == 1 else {})}
                  for index in range(17)]
        events = [{"type": "launched", "pid": 17, "birth_time_us": 123}]
        for point in points:
            events.append(point)
            if point.get("command_id") == "collector-handshake":
                events.append({"type": "app_event", "monotonic_seconds": point["monotonic_seconds"],
                               "event": {"type": "ready", "command_id": "collector-handshake", "protocol_version": 1}})
        events.append({"type": "exited", "status": 0, "final_sample": points[-1]})
        workload = {"validated": True, "before": {"runner_collector_sample_monotonic_seconds": 1},
                    "after": {"runner_collector_sample_monotonic_seconds": 3}}
        return points, events, workload, {"process_id": 17, "birth_time_us": 123}, {"problems": []}

    def test_cpu_uses_exact_workload_boundaries_preserving_bursts_without_counting_startup(self):
        result = memory.workload_cpu_diagnostic(*self.evidence())
        self.assertTrue(result["available"])
        self.assertFalse(result["gate_evaluated"])
        self.assertEqual(result["elapsed_seconds"], 2)
        self.assertAlmostEqual(result["cpu_seconds"], 0.28)
        self.assertAlmostEqual(result["average_cpu_percent"], 14)
        self.assertAlmostEqual(result["rolling_1s_percent"], 24)
        self.assertIn("completion/drain overhead", result["interval"])

    def test_cpu_rejects_invalid_timeline_counters_identity_boundaries_and_completion(self):
        changes = (
            lambda points, events, workload, identity, validation: points[5].update(cpu_seconds=None),
            lambda points, events, workload, identity, validation: points[5].update(cpu_seconds=0),
            lambda points, events, workload, identity, validation: points[5].update(monotonic_seconds=0),
            lambda points, events, workload, identity, validation: points[5].update(process_id=18),
            lambda points, events, workload, identity, validation: events[-1].update(status=1),
            lambda points, events, workload, identity, validation: events[-1].update(final_sample={}),
            lambda points, events, workload, identity, validation: events.pop(3),
            lambda points, events, workload, identity, validation: workload.update(validated=False),
            lambda points, events, workload, identity, validation: workload["before"].update(runner_collector_sample_monotonic_seconds=0),
            lambda points, events, workload, identity, validation: workload["after"].update(runner_collector_sample_monotonic_seconds=2.9),
            lambda points, events, workload, identity, validation: workload["after"].update(runner_collector_sample_monotonic_seconds=2.75),
            lambda points, events, workload, identity, validation: identity.update(birth_time_us=999),
            lambda points, events, workload, identity, validation: validation.update(problems=["bad final accounting"]),
        )
        for change in changes:
            evidence = self.evidence()
            change(*evidence)
            with self.subTest(change=change), self.assertRaises(InvalidResult):
                memory.workload_cpu_diagnostic(*evidence)
        evidence = self.evidence()
        del evidence[0][6:9]
        with self.assertRaisesRegex(InvalidResult, "sampling gap"):
            memory.workload_cpu_diagnostic(*evidence)

    def test_no_inspection_preserves_both_checkpoints_without_native_tools_or_zero_categories(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal", no_native_inspection=True)
            with mock.patch.object(diagnostic, "checkpoint") as checkpoint, mock.patch.object(diagnostic, "inspect_tool") as inspect:
                diagnostic.probe("streaming", True, True, 2, heap=True)
            self.assertEqual(checkpoint.call_args_list, [mock.call("streaming-before-probe", True, True, 2),
                                                        mock.call("streaming-after-probe", True, True, 2)])
            inspect.assert_not_called()
            self.assertFalse(diagnostic.report["native_inspection_enabled"])
            self.assertEqual(diagnostic.report["probes"], [])
            self.assertEqual(diagnostic.report["inspection_stages"][0]["status"], "skipped")
            self.assertFalse(diagnostic.report["workload_cpu"]["available"])

    def test_default_inspection_has_no_cpu_claim_even_after_clean_final_accounting(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal")
            points, events, workload, identity, _ = self.evidence()
            events.insert(-1, {"type": "app_event", "event": {"type": "stopped", "status": "ok"}})
            diagnostic.identity = identity
            diagnostic.report["workload"] = workload
            diagnostic.collector = mock.Mock(samples=points, events=events, storage={}, cleanup_errors=[])
            with mock.patch.object(memory, "workload_cpu_diagnostic") as cpu:
                diagnostic.cleanup()
            cpu.assert_not_called()
            self.assertEqual(diagnostic.report["errors"], [])
            self.assertFalse(diagnostic.report["workload_cpu"]["available"])
            self.assertIn("Native inspection perturbs", diagnostic.report["workload_cpu"]["reason"])

    def test_optional_work_counter_failure_does_not_invalidate_clean_workload_cpu(self):
        for malformed in (False, True):
            with self.subTest(malformed=malformed), tempfile.TemporaryDirectory() as directory:
                diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal", no_native_inspection=True)
                points, events, workload, identity, _ = self.evidence()
                expected_cpu = memory.workload_cpu_diagnostic(points, events, workload, identity, {"problems": []})
                if malformed:
                    for point in points:
                        point["cpu_work_counters"] = {"instructions": 1}
                events.insert(-1, {"type": "app_event", "event": {"type": "stopped", "status": "ok"}})
                diagnostic.identity = identity
                diagnostic.report["workload"] = workload
                diagnostic.collector = mock.Mock(samples=points, events=events, storage={}, cleanup_errors=[])
                diagnostic.cleanup()
                self.assertEqual(diagnostic.report["workload_cpu"], expected_cpu)
                self.assertEqual(diagnostic.report["errors"], [])
                optional = diagnostic.report["workload_cpu_work_counters"]
                self.assertEqual(optional["status"], "invalid_diagnostic" if malformed else "unavailable")
                self.assertFalse(optional["gate_evaluated"])

    def test_unavailable_workload_cpu_skips_optional_boundary_lookup_and_preserves_reason(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal", no_native_inspection=True)
            points, events, workload, identity, _ = self.evidence()
            events.insert(-1, {"type": "app_event", "event": {"type": "stopped", "status": "ok"}})
            diagnostic.identity = identity
            diagnostic.report["workload"] = workload
            diagnostic.collector = mock.Mock(samples=points, events=events, storage={}, cleanup_errors=[])
            unavailable = {"available": False, "gate_evaluated": False, "reason": "Original CPU qualification reason"}
            with mock.patch.object(memory, "workload_cpu_diagnostic", return_value=unavailable), \
                    mock.patch.object(memory.app, "cpu_work_counter_diagnostic") as work_counters:
                diagnostic.cleanup()
            work_counters.assert_not_called()
            self.assertEqual(diagnostic.report["workload_cpu"], unavailable)
            self.assertEqual(diagnostic.report["workload_cpu_work_counters"]["reason"], unavailable["reason"])
            self.assertEqual(diagnostic.report["errors"], [])

    def test_summary_keeps_valid_counter_family_when_other_family_is_unavailable(self):
        for unavailable_family in ("hardware", "qos"):
            with self.subTest(unavailable_family=unavailable_family), tempfile.TemporaryDirectory() as directory:
                diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal", no_native_inspection=True)
                points, events, *_ = self.evidence()
                for index, point in enumerate(points):
                    point["cpu_work_counters"] = dict(memory.app.CPU_WORK_METADATA,
                        instructions=index * 11 if unavailable_family != "hardware" else 0,
                        cycles=index * 7 if unavailable_family != "hardware" else 0,
                        qos_time_raw={key: index * 13 if key == "default" and unavailable_family != "qos" else 0
                                      for key in memory.app.CPU_WORK_QOS_BUCKETS})
                diagnostic.report["workload_cpu_work_counters"] = memory.app.cpu_work_counter_diagnostic(points, events, 1, 3)
                self.assertFalse(diagnostic.report["workload_cpu_work_counters"]["available"])
                summary = memory.summary_markdown(diagnostic.report)
                if unavailable_family == "qos":
                    self.assertIn("| Instructions | 88 | available |", summary)
                    self.assertIn("| Cycles | 56 | available |", summary)
                    self.assertIn("| QoS default (raw) | 0 | unavailable / unverified |", summary)
                else:
                    self.assertIn("| Instructions | 0 | unavailable / unverified |", summary)
                    self.assertIn("| Cycles | 0 | unavailable / unverified |", summary)
                    self.assertIn("| QoS default (raw) | 104 | available |", summary)
                self.assertIn("Raw zeros marked unverified do not establish zero work", summary)

    def test_no_inspection_final_validation_publishes_cpu_and_rejects_bad_final_graphics(self):
        for bad_graphics in (False, True):
            with self.subTest(bad_graphics=bad_graphics), tempfile.TemporaryDirectory() as directory:
                diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "bitmap-layer-destination",
                                                     no_native_inspection=True)
                points, events, workload, identity, _ = self.evidence()
                snapshot = graphics("bitmap-layer-destination")
                snapshot["graphics_diagnostics"]["layer_bitmap_native_draws"] = int(bad_graphics)
                events.insert(-1, {"type": "app_event", "event": {"type": "stopped", "status": "ok", "snapshot": snapshot}})
                diagnostic.identity = identity
                diagnostic.report["workload"] = workload
                diagnostic.collector = mock.Mock(samples=points, events=events, storage={}, cleanup_errors=[])
                diagnostic.cleanup()
                self.assertEqual(diagnostic.report["workload_cpu"]["available"], not bad_graphics)
                self.assertEqual(bool(diagnostic.report["errors"]), bad_graphics)

    def test_final_event_replay_cannot_silently_drop_acknowledged_normal_native_contract(self):
        for disappeared in (False, True):
            with self.subTest(disappeared=disappeared), tempfile.TemporaryDirectory() as directory:
                diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal", no_native_inspection=True)
                diagnostic.validate_graphics_snapshot(native_normal_graphics())
                points, events, workload, identity, _ = self.evidence()
                events.insert(-1, {"type": "app_event", "event": {
                    "type": "ack", "snapshot": {} if disappeared else native_normal_graphics()}})
                events.insert(-1, {"type": "app_event", "event": {"type": "stopped", "status": "ok"}})
                diagnostic.identity = identity
                diagnostic.report["workload"] = workload
                diagnostic.collector = mock.Mock(samples=points, events=events, storage={}, cleanup_errors=[])
                diagnostic.cleanup()
                self.assertEqual(diagnostic.report["workload_cpu"]["available"], not disappeared)
                self.assertEqual(bool(diagnostic.report["errors"]), disappeared)
                if disappeared:
                    self.assertIn("disappeared", diagnostic.report["workload_cpu"]["reason"])

    def test_inspection_flag_is_opt_in(self):
        arguments = ["--app-binary", "app", "--test-bundle", "tests", "--collector-binary", "collector", "--provenance", "provenance"]
        self.assertFalse(memory.parser().parse_args(arguments).no_native_inspection)
        self.assertTrue(memory.parser().parse_args(arguments + ["--no-native-inspection"]).no_native_inspection)


class IdentityTests(unittest.TestCase):
    def test_post_ready_snapshot_is_also_checked_for_animation_drift(self):
        collector = mock.Mock(samples=[], events=[])
        collector.snapshot.return_value = {"popover_animations_enabled": True}
        with mock.patch.object(memory.app, "authenticated_cpu_ready") as authenticate, self.assertRaises(InvalidResult):
            memory.authenticate_ready(collector, lambda snapshot: memory.validate_popover_animation(snapshot, True))
        authenticate.assert_not_called()

    def test_ready_requests_following_sample_before_authentication(self):
        collector = mock.Mock(samples=[], events=[])
        def snapshot():
            collector.samples.append({"post_ready": True})
        collector.snapshot.side_effect = snapshot
        def authenticate(samples, events):
            self.assertEqual(samples, [{"post_ready": True}])
            return {"process_id": 17, "birth_time_us": 123}
        with mock.patch.object(memory.app, "authenticated_cpu_ready", side_effect=authenticate):
            self.assertEqual(memory.authenticate_ready(collector)["process_id"], 17)
        collector.snapshot.assert_called_once_with()

    def test_pid_birth_and_group_are_verified_before_inspection(self):
        collector = mock.Mock(app_pid=17, app_birth_time_us=123, exited=False)
        identity = {"process_id": 17, "birth_time_us": 123}
        with mock.patch.object(memory.os, "getpgid", return_value=17):
            memory.verify_owned(collector, identity, lambda pid: 123)
            for reader in (lambda pid: 456,):
                with self.assertRaises(InvalidResult):
                    memory.verify_owned(collector, identity, reader)
        with mock.patch.object(memory.os, "getpgid", return_value=18), self.assertRaises(InvalidResult):
            memory.verify_owned(collector, identity, lambda pid: 123)
        collector.exited = True
        with self.assertRaises(InvalidResult):
            memory.verify_owned(collector, identity, lambda pid: 123)

    def test_intermediate_identity_and_order_are_checked_without_cpu_gap_gate(self):
        identity = {"process_id": 17, "birth_time_us": 123}
        samples = [dict(identity, monotonic_seconds=0, phase="baseline"),
                   dict(identity, monotonic_seconds=5, phase="periodic"),
                   dict(identity, monotonic_seconds=10, phase="final")]
        memory.validate_sample_identities(samples, identity)
        for changes in ({"process_id": 99}, {"birth_time_us": True}, {"monotonic_seconds": 11}, {"monotonic_seconds": float("inf")}):
            invalid = copy.deepcopy(samples)
            invalid[1].update(changes)
            with self.subTest(changes=changes), self.assertRaises(InvalidResult):
                memory.validate_sample_identities(invalid, identity)


class DeadlineAndCleanupTests(unittest.TestCase):
    def test_90_second_deadline_reserves_eight_seconds(self):
        now = [10]
        deadline = memory.MemoryDeadline(clock=lambda: now[0])
        self.assertEqual(deadline.end, 100)
        self.assertEqual(deadline.remaining(), 82)
        self.assertEqual(deadline.remaining(12), 12)
        now[0] = 92
        with self.assertRaises(TimeoutError):
            deadline.remaining()
        with self.assertRaises(InvalidResult):
            memory.MemoryDeadline(91)

    def test_alarm_is_removed_after_exception(self):
        deadline = memory.MemoryDeadline(clock=lambda: 10)
        with mock.patch.object(memory.signal, "getsignal", return_value="prior"), \
                mock.patch.object(memory.signal, "signal") as handler, \
                mock.patch.object(memory.signal, "setitimer", return_value=(0, 0)) as timer:
            with self.assertRaisesRegex(RuntimeError, "fixture"):
                with deadline.interrupt_at(92):
                    raise RuntimeError("fixture")
        timer.assert_any_call(memory.signal.ITIMER_REAL, 82)
        timer.assert_any_call(memory.signal.ITIMER_REAL, 0)
        handler.assert_any_call(memory.signal.SIGALRM, "prior")

    def diagnostic(self, directory, deadline=None):
        value = memory.MemoryDiagnostic(Path(directory), deadline or memory.MemoryDeadline(), "normal")
        value.collector = mock.Mock(samples=[], events=[], storage={}, cleanup_errors=[],
                                    app_pid=17, app_birth_time_us=123, exited=False)
        value.fixture = mock.Mock(name="fixture")
        value.active_probe = mock.Mock(name="native")
        return value

    def test_collector_timeout_does_not_skip_fixture_or_inspector(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = self.diagnostic(directory)
            diagnostic.collector.close.side_effect = TimeoutError("collector stalled")
            order = []
            with mock.patch.object(memory, "stop_owned_child", side_effect=lambda child, deadline: order.append(child)), \
                    mock.patch.object(diagnostic, "emergency_collector_cleanup") as emergency:
                diagnostic.cleanup()
            self.assertEqual(order, [diagnostic.active_probe, diagnostic.fixture])
            emergency.assert_called_once()
            self.assertTrue(any("collector stalled" in item for item in diagnostic.report["errors"]))

    def test_exhausted_deadline_still_attempts_each_owned_child(self):
        with tempfile.TemporaryDirectory() as directory:
            deadline = memory.MemoryDeadline(clock=lambda: 100)
            deadline.end = 99
            diagnostic = self.diagnostic(directory, deadline)
            calls = []
            with mock.patch.object(memory, "stop_owned_child", side_effect=lambda child, deadline: calls.append(child)), \
                    mock.patch.object(diagnostic, "emergency_collector_cleanup") as emergency:
                diagnostic.cleanup()
            self.assertEqual(calls, [diagnostic.active_probe, diagnostic.fixture])
            diagnostic.collector.close.assert_not_called()
            emergency.assert_called_once()

    def test_first_cleanup_failure_preserves_later_attempts(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = self.diagnostic(directory)
            with mock.patch.object(memory, "stop_owned_child", side_effect=[OSError("denied"), None]) as stop:
                diagnostic.cleanup()
            self.assertEqual(stop.call_count, 2)
            diagnostic.collector.close.assert_called_once()
            self.assertTrue(any("native inspector cleanup failed" in item for item in diagnostic.report["errors"]))

    def test_emergency_app_kill_is_blocked_on_identity_failure_but_collector_reaped(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = self.diagnostic(directory)
            with mock.patch.object(memory, "verify_owned", side_effect=InvalidResult("wrong birth")), \
                    mock.patch.object(memory.os, "killpg") as kill, mock.patch.object(memory, "stop_owned_child") as stop:
                diagnostic.emergency_collector_cleanup()
            kill.assert_not_called()
            stop.assert_called_once_with(diagnostic.collector.process, diagnostic.deadline)

    def test_owned_child_kill_still_occurs_after_deadline_without_unbounded_wait(self):
        deadline = memory.MemoryDeadline(clock=lambda: 100)
        deadline.end = 99
        process = mock.Mock(pid=17)
        process.poll.return_value = None
        with mock.patch.object(memory.os, "getpgid", return_value=17), mock.patch.object(memory.os, "killpg") as kill:
            memory.stop_owned_child(process, deadline)
        kill.assert_called_once_with(17, memory.signal.SIGKILL)
        process.wait.assert_called_once_with(timeout=0.001)


class ProbeAndRoutingTests(unittest.TestCase):
    def report_to_finalize(self):
        return {"caveat": "Diagnostic", "status": "diagnostic_captured", "graphics_mode": "normal",
                "errors": [], "checkpoints": [], "probes": [], "regression_passed": False}

    def test_summary_write_error_or_deadline_cannot_leave_captured_status(self):
        for error in (OSError("disk full"), TimeoutError("deadline")):
            with self.subTest(error=error), tempfile.TemporaryDirectory() as directory, \
                    contextlib.redirect_stderr(io.StringIO()):
                output = Path(directory)
                report = self.report_to_finalize()
                write_text = Path.write_text
                def fail_summary(path, *args, **kwargs):
                    if path.name == "SUMMARY.md":
                        raise error
                    return write_text(path, *args, **kwargs)
                with mock.patch.object(Path, "write_text", new=fail_summary):
                    memory.finalize_report(output, report, memory.MemoryDeadline())
                saved = memory.load_json(output / "memory-report.json")
                self.assertEqual(saved["status"], "diagnostic_incomplete")
                self.assertTrue(saved["finalization_pending"])
                self.assertEqual(report["status"], "diagnostic_incomplete")

    def test_final_json_failure_leaves_incomplete_report_and_neutral_summary(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stderr(io.StringIO()):
            output = Path(directory)
            report = self.report_to_finalize()
            write = memory.write_json
            def fail_completion(path, value):
                if value["status"] == "diagnostic_captured":
                    raise OSError("final commit failed")
                write(path, value)
            with mock.patch.object(memory, "write_json", side_effect=fail_completion):
                memory.finalize_report(output, report, memory.MemoryDeadline())
            self.assertEqual(memory.load_json(output / "memory-report.json")["status"], "diagnostic_incomplete")
            self.assertNotIn("diagnostic_captured", (output / "SUMMARY.md").read_text())
            self.assertEqual(report["status"], "diagnostic_incomplete")

    def test_successful_finalization_commits_capture_after_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            report = self.report_to_finalize()
            memory.finalize_report(output, report, memory.MemoryDeadline())
            saved = memory.load_json(output / "memory-report.json")
            self.assertEqual(saved["status"], "diagnostic_captured")
            self.assertNotIn("finalization_pending", saved)
            self.assertIn("memory-report.json", (output / "SUMMARY.md").read_text())

    def test_summary_only_reports_missing_category_as_zero_for_valid_complete_ledger(self):
        report = {"caveat": "Diagnostic", "status": "diagnostic_captured", "graphics_mode": "normal", "errors": [],
                  "checkpoints": [{"label": "idle-after-probe", "resource_sample": {}}],
                  "probes": [{"label": "idle", "tool": "footprint", "valid": True,
                              "parsed": {"physical_footprint_bytes": 1_000_000, "groups": {"malloc": {"dirty": 1_000_000}}}}]}
        self.assertIn("| 1.000 | 0.000 | 1.000 |", memory.summary_markdown(report))
        report["probes"] = [{"label": "idle", "tool": "footprint", "valid": False, "errors": ["wrong PID"]}]
        self.assertNotIn("0.000", memory.summary_markdown(report))
        self.assertIn("unavailable | unavailable | unavailable", memory.summary_markdown(report))

    def test_tool_timeout_preserves_raw_output_and_does_not_parse_it_as_success(self):
        with tempfile.TemporaryDirectory() as directory:
            now = [0]
            diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(clock=lambda: now[0]), "normal")
            diagnostic.identity = {"process_id": 17, "birth_time_us": 123}
            diagnostic.collector = mock.Mock(exited=False)
            diagnostic.collector.receive.side_effect = lambda *args: now.__setitem__(0, 13)
            process = mock.Mock(returncode=-9)
            process.poll.return_value = None
            with mock.patch.object(diagnostic, "verify_identity"), mock.patch.object(memory.time, "monotonic", side_effect=lambda: now[0]), \
                    mock.patch.object(memory.subprocess, "Popen", return_value=process), \
                    mock.patch.object(memory, "stop_owned_child") as stop, mock.patch.object(memory, "parse_probe") as parse:
                diagnostic.inspect_tool("probe", "vmmap")
            stop.assert_called_once_with(process, diagnostic.deadline)
            parse.assert_not_called()
            self.assertFalse(diagnostic.report["probes"][0]["valid"])
            self.assertTrue((Path(directory) / "probe-vmmap.txt").exists())
            self.assertTrue(any("bounded inspection time" in item for item in diagnostic.report["errors"]))

    def test_failed_reap_retains_handle_for_final_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            diagnostic = memory.MemoryDiagnostic(Path(directory), memory.MemoryDeadline(), "normal")
            diagnostic.identity = {"process_id": 17, "birth_time_us": 123}
            process = mock.Mock(returncode=0)
            process.poll.return_value = 0
            with mock.patch.object(diagnostic, "verify_identity"), mock.patch.object(memory.subprocess, "Popen", return_value=process), \
                    mock.patch.object(memory, "stop_owned_child", side_effect=subprocess.TimeoutExpired("vmmap", 1)):
                with self.assertRaises(subprocess.TimeoutExpired):
                    diagnostic.inspect_tool("probe", "vmmap")
            self.assertIs(diagnostic.active_probe, process)

    def test_output_directory_is_never_reused(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stderr(io.StringIO()), \
                mock.patch.object(memory, "validate_products") as products:
            result = memory.run(["--app-binary", "app", "--test-bundle", "tests", "--collector-binary", "collector",
                                 "--provenance", "provenance", "--output-dir", directory])
            self.assertEqual(result, 1)
            products.assert_not_called()

    def test_missing_provenance_finishes_incomplete_with_artifacts_without_launch(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()), \
                mock.patch.object(memory.sys, "platform", "darwin"), \
                mock.patch.object(memory, "validate_products", side_effect=InvalidResult("changed binary")), \
                mock.patch.object(memory.app, "launch_fixture") as fixture:
            output = Path(directory) / "result"
            result = memory.run(["--app-binary", "app", "--test-bundle", "tests", "--collector-binary", "collector",
                                 "--provenance", "provenance", "--output-dir", str(output)])
            report = memory.load_json(output / "memory-report.json")
            self.assertEqual(result, 1)
            self.assertEqual(report["status"], "diagnostic_incomplete")
            self.assertFalse(report["regression_passed"])
            self.assertFalse(report["cpu_gate_evaluated"])
            self.assertIn("changed binary", report["errors"])
            fixture.assert_not_called()


if __name__ == "__main__":
    unittest.main()
