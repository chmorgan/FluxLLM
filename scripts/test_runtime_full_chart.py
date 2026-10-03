"""Independent full-chart Metal evidence fixtures; no native execution."""
import copy
import unittest

import memory_attribution as memory
import runtime_attribution as runtime


MODE = "runtime-metal-full-chart"
FIELDS = ("hosts_created", "hosts_destroyed", "live_hosts", "peak_hosts", "geometry_uploads", "submissions",
          "failures", "frames_skipped", "static_frames", "arrival_frames", "completion_frames", "twinkle_frames",
          "current_buffer_bytes", "peak_buffer_bytes")
ROLE_FIELDS = ("created", "destroyed", "live", "peak_live", "updates", "renderer_creations", "renderer_updates",
               "renderer_destructions", "live_renderers", "peak_live_renderers", "draws", "skipped_draws",
               "current_pixel_area", "peak_pixel_area", "current_bitmap_bytes", "peak_bitmap_bytes")
LEGACY_FIELDS = ("rail_frame_clock_ticks", "rail_timeline_content_updates", "grouped_native_canvas_draws",
                 "ungrouped_native_canvas_draws", "metal_arrival_frames", "metal_arrival_submissions", "metal_arrival_failures")


def full_snapshot(*, closed=False, **counts):
    state = dict.fromkeys(FIELDS, 0)
    state.update(hosts_created=2, hosts_destroyed=2 if closed else 0, live_hosts=0 if closed else 2,
                 peak_hosts=2, geometry_uploads=4, submissions=20, static_frames=5, arrival_frames=10,
                 completion_frames=4, twinkle_frames=12, current_buffer_bytes=0 if closed else 4096,
                 peak_buffer_bytes=4096)
    state.update(counts)
    graphics = {"enabled": True, "mode": MODE, "metal_full_chart_enabled": True,
                "native_gpu_backend": "metal-persistent-chart", "arrival_backend": "metal-full-chart-shader",
                "incremental_history_ordering": True, "optimized_chart_preparation": True, "lifecycle_effects_enabled": True,
                "shared_chart_preparation": False, "stable_decoration_hosts": False, "unpromised_stream_body_writes": True,
                "canvas_frame_clock": False, "ordered_chart_publication": True, "direct_tool_plot": False,
                "ungrouped_native_canvas": False, "arrival_effects_enabled": True, "compact_tool_paths_enabled": False,
                "deferred_tool_geometry_enabled": False, "metal_arrival_bursts_enabled": False, "holds_static_chart_drawing": False,
                "metal_full_chart": state,
                "roles": {role: dict.fromkeys(ROLE_FIELDS, 0)
                          for role in ("static_chart", "cursor", "rail_bars", "rail_decorations")}}
    return {**dict.fromkeys(LEGACY_FIELDS, 0), "graphics_diagnostics": graphics,
            "dashboard_visible": not closed, "popover_visible": not closed, "active_requests": 0}


def full_runtime_report():
    samples, points, closed = [], [], []

    def point(label, timestamp, static, arrivals, completions, twinkles, submissions, uploads, *, hidden=False, active=0):
        snapshot = full_snapshot(closed=hidden, static_frames=static, arrival_frames=arrivals,
            completion_frames=completions, twinkle_frames=twinkles, submissions=submissions, geometry_uploads=uploads)
        snapshot.update(active_requests=active, runner_collector_sample_monotonic_seconds=timestamp)
        sample = {"monotonic_seconds": timestamp, "mach_absolute_seconds": timestamp + 900,
                  "process_id": 123, "birth_time_us": 456}
        samples.append(sample)
        return {"label": label, "python_monotonic_seconds": timestamp, "snapshot": snapshot, "resource_sample": sample}

    points.append(point("before-traffic", 100, 1, 0, 0, 0, 1, 1))
    points.append(point("after-arrival", 102.5, 3, 10, 0, 10, 15, 2, active=2))
    points.append(point("steady-first", 106, 10, 10, 0, 20, 30, 5, active=2))
    points.append(point("steady-last", 119, 20, 10, 0, 100, 110, 18, active=2))
    points.append(point("completion-begin", 125.25, 27, 10, 0, 120, 145, 24))
    points.append(point("during-completion", 127, 28, 10, 5, 123, 155, 25))
    points.append(point("completion-end", 129, 30, 10, 10, 130, 170, 26))
    closed.append(point("07-both-closed-after-probe", 132, 30, 10, 10, 130, 170, 26, hidden=True))
    closed.append(point("08-closed-after-five-more-seconds", 137.25, 30, 10, 10, 130, 170, 26, hidden=True))
    return {"owned_identity": {"process_id": 123, "birth_time_us": 456}, "samples": samples,
            "runtime": {"checkpoints": points, "mach_clock_start": {"absolute_minus_monotonic_seconds": 900, "uncertainty_seconds": 0},
                        "mach_clock_end": {"absolute_minus_monotonic_seconds": 900, "uncertainty_seconds": 0}},
            "checkpoints": closed, "phase_windows": {
                "arrival": {"start_monotonic_seconds": 100.1, "end_monotonic_seconds": 102.1},
                "steady": {"start_monotonic_seconds": 105, "end_monotonic_seconds": 120},
                "completion": {"start_monotonic_seconds": 125.1, "end_monotonic_seconds": 128.1},
                "whole_contiguous_runtime": {"start_monotonic_seconds": 100, "end_monotonic_seconds": 129}}}


class FullMetalSnapshotTests(unittest.TestCase):
    def test_complete_executed_and_closed_lifecycles_are_accepted(self):
        self.assertEqual(set(memory.METAL_FULL_CHART_FIELDS), set(FIELDS))
        self.assertTrue(memory.metal_full_chart_contract(full_snapshot(), MODE, completed_visible_workload=True)["enabled"])
        result = memory.metal_full_chart_contract(full_snapshot(closed=True), MODE, expected_closed=True)
        self.assertEqual(result["counters"]["current_buffer_bytes"], 0)

    def test_every_counter_is_required_and_uint64(self):
        for field in FIELDS:
            for invalid in (None, True, -1, 1.0, "1", 2**64, "missing"):
                snapshot = full_snapshot()
                counts = snapshot["graphics_diagnostics"]["metal_full_chart"]
                if invalid == "missing":
                    del counts[field]
                else:
                    counts[field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(ValueError):
                    memory.metal_full_chart_contract(snapshot, MODE)

    def test_metadata_missing_or_substituted_backend_is_rejected(self):
        for field, values in {"metal_full_chart_enabled": (None, False, 1),
                              "native_gpu_backend": (None, "swiftui-canvas-drawing-group"),
                              "arrival_backend": (None, "metal-shader"), "metal_full_chart": (None, [])}.items():
            for invalid in values:
                snapshot = full_snapshot()
                snapshot["graphics_diagnostics"][field] = invalid
                with self.subTest(field=field, value=invalid), self.assertRaises(ValueError):
                    memory.metal_full_chart_contract(snapshot, MODE)

    def test_lifecycle_failures_missing_submissions_and_live_closed_resources_are_rejected(self):
        faults = ({"hosts_destroyed": 3}, {"live_hosts": 1}, {"peak_hosts": 3}, {"failures": 1},
                  {"current_buffer_bytes": 4097}, {"arrival_frames": 21})
        for changes in faults:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                memory.metal_full_chart_contract(full_snapshot(**changes), MODE)
        for field in ("geometry_uploads", "submissions", "static_frames", "arrival_frames", "twinkle_frames", "peak_buffer_bytes"):
            with self.subTest(missing_work=field), self.assertRaises(ValueError):
                memory.metal_full_chart_contract(full_snapshot(**{field: 0}), MODE, completed_visible_workload=True)
        with self.assertRaises(ValueError):
            memory.metal_full_chart_contract(full_snapshot(), MODE, expected_closed=True)

    def test_canvas_renderer_bitmap_and_legacy_clock_fallbacks_are_rejected(self):
        for field in LEGACY_FIELDS:
            snapshot = full_snapshot()
            snapshot[field] = 1
            with self.subTest(legacy=field), self.assertRaises(ValueError):
                memory.metal_full_chart_contract(snapshot, MODE)
        for field in ("native_gpu_canvas_draws", "live_canvases", "peak_live_canvases", "live_renderers",
                      "peak_live_renderers", "current_bitmap_bytes", "peak_bitmap_bytes", "current_layer_image_bytes",
                      "peak_layer_image_bytes", "layer_bitmap_presentations", "layer_bitmap_failures", "layer_bitmap_native_draws"):
            snapshot = full_snapshot()
            snapshot["graphics_diagnostics"][field] = 1
            with self.subTest(graphics=field), self.assertRaises(ValueError):
                memory.metal_full_chart_contract(snapshot, MODE)
        for role in ("static_chart", "cursor", "rail_bars", "rail_decorations"):
            snapshot = full_snapshot()
            snapshot["graphics_diagnostics"]["roles"][role]["draws"] = 1
            with self.subTest(role=role), self.assertRaises(ValueError):
                memory.metal_full_chart_contract(snapshot, MODE)

    def test_skipped_frames_are_quality_evidence_and_do_not_masquerade_as_renderer_failure(self):
        result = memory.metal_full_chart_contract(full_snapshot(frames_skipped=3), MODE, completed_visible_workload=True)
        self.assertFalse(result["frame_delivery_qualified"])
        self.assertEqual(result["counters"]["frames_skipped"], 3)
        self.assertEqual(result["counters"]["failures"], 0)

    def test_normal_old_evidence_is_supported_but_cannot_claim_full_metal_work(self):
        self.assertIsNone(memory.metal_full_chart_contract({}, "normal"))
        snapshot = full_snapshot()
        snapshot["graphics_diagnostics"].update(metal_full_chart_enabled=False, metal_full_chart=dict.fromkeys(FIELDS, 0))
        self.assertFalse(memory.metal_full_chart_contract(snapshot, "normal")["enabled"])
        snapshot["graphics_diagnostics"]["metal_full_chart"]["submissions"] = 1
        with self.assertRaises(ValueError):
            memory.metal_full_chart_contract(snapshot, "normal")


class FullMetalRuntimeTests(unittest.TestCase):
    def test_executed_arrival_steady_twinkle_completion_and_closed_quiet_are_accepted(self):
        result = runtime.validate_metal_full_chart_work(full_runtime_report(), MODE)
        self.assertIsInstance(result, dict)

    def test_opt_in_full_renderer_metrics_do_not_establish_cpu_acceptance(self):
        self.assertFalse(runtime.cpu_acceptance_eligible(MODE))
        self.assertTrue(runtime.cpu_acceptance_eligible("normal"))

    def test_short_gpu_can_supply_its_authenticated_boundary_and_closed_labels(self):
        report = full_runtime_report()
        report["checkpoints"][0]["label"], report["checkpoints"][1]["label"] = "closed-start", "closed-end"
        result = runtime.validate_metal_full_chart_work(report, MODE, closed_labels=("closed-start", "closed-end"),
            minimum_closed_seconds=2, boundary=lambda point: point["resource_sample"]["monotonic_seconds"])
        self.assertTrue(result["available"])
        self.assertTrue(all(value == 0 for value in result["closed_deltas"].values()))

    def test_hidden_changed_identity_and_counter_regressions_are_rejected(self):
        for fault in ("hidden", "pid", "birth", "regression"):
            report = full_runtime_report()
            point = report["runtime"]["checkpoints"][3]
            if fault == "hidden":
                point["snapshot"]["dashboard_visible"] = False
            elif fault in ("pid", "birth"):
                point["resource_sample"]["process_id" if fault == "pid" else "birth_time_us"] += 1
            else:
                point["snapshot"]["graphics_diagnostics"]["metal_full_chart"]["geometry_uploads"] = 0
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_metal_full_chart_work(report, MODE)

    def test_late_arrival_or_missing_completion_cannot_be_substituted_by_other_submissions(self):
        for field in ("arrival_frames", "completion_frames", "twinkle_frames", "static_frames"):
            report = full_runtime_report()
            for point in report["runtime"]["checkpoints"]:
                point["snapshot"]["graphics_diagnostics"]["metal_full_chart"][field] = 0
            if field == "arrival_frames":
                # Arrival work appears only during completion; total submissions stay positive.
                for point in report["runtime"]["checkpoints"][-2:]:
                    point["snapshot"]["graphics_diagnostics"]["metal_full_chart"][field] = 10
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_metal_full_chart_work(report, MODE)

    def test_closed_growth_retained_resources_or_missing_observation_is_rejected(self):
        for fault in ("submissions", "geometry_uploads", "live-hosts", "missing", "short"):
            report = full_runtime_report()
            last = report["checkpoints"][-1]
            if fault in ("submissions", "geometry_uploads"):
                last["snapshot"]["graphics_diagnostics"]["metal_full_chart"][fault] += 1
            elif fault == "live-hosts":
                last["snapshot"]["graphics_diagnostics"]["metal_full_chart"].update(hosts_destroyed=1, live_hosts=1)
            elif fault == "missing":
                report["checkpoints"].pop()
            else:
                last["resource_sample"]["mach_absolute_seconds"] = 1033
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_metal_full_chart_work(report, MODE)


if __name__ == "__main__":
    unittest.main()
