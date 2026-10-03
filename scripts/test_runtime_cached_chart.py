"""Independent cached-Metal workload contracts; never execute native captures."""
import copy
import unittest

import memory_attribution as memory
import runtime_attribution as runtime
import runtime_gpu_comparison as gpu
from test_runtime_full_chart import full_snapshot, full_runtime_report, MODE as FULL_MODE
from test_runtime_attribution import workload_snapshots

MODE = "runtime-metal-cached-chart"
CACHE_FIELDS = ("static_rasterizations", "static_cache_composites", "effect_clock_ticks",
                "current_texture_bytes", "peak_texture_bytes", "static_scene_revisions", "static_surface_invalidations",
                "scene_initial_revisions", "scene_publication_revisions", "scene_scale_revisions", "scene_layout_revisions",
                "scene_appearance_revisions", "scene_rail_revisions", "scene_unclassified_revisions")


def cached_snapshot(*, closed=False, **counts):
    snapshot = full_snapshot(closed=closed, **counts)
    value = snapshot["graphics_diagnostics"]
    value.update(mode=MODE, metal_static_cache_enabled=True, retained_twinkles_enabled=True,
                 retained_twinkle_backend="core-animation-shape-layers")
    value["metal_full_chart"].update(dict.fromkeys(CACHE_FIELDS, 0))
    value["metal_full_chart"].update(static_rasterizations=2, static_cache_composites=value["metal_full_chart"]["static_frames"],
        effect_clock_ticks=4, current_texture_bytes=0 if closed else 16384, peak_texture_bytes=16384,
        static_scene_revisions=2, scene_initial_revisions=2)
    value["retained_twinkles"] = dict(hosts_created=2, hosts_destroyed=2 if closed else 0,
        live_hosts=0 if closed else 2, peak_hosts=2, instances_created=4, instances_destroyed=4 if closed else 2,
        live_instances=0 if closed else 2, peak_instances=2, animation_starts=4)
    return snapshot


def cached_runtime_report():
    report = full_runtime_report()
    rows = report["runtime"]["checkpoints"] + report["checkpoints"]
    composites = (1, 15, 18, 28, 35, 45, 55, 55, 55)
    rasters = (1, 3, 10, 20, 27, 28, 30, 30, 30)
    effects = (0, 12, 12, 12, 12, 22, 32, 32, 32)
    twinkles = (0, 10, 10, 10, 10, 13, 20, 20, 20)
    retained = (0, 2, 4, 14, 20, 22, 22, 22, 22)
    for index, point in enumerate(rows):
        old = point["snapshot"]
        closed = not old["dashboard_visible"]
        snapshot = cached_snapshot(closed=closed, **old["graphics_diagnostics"]["metal_full_chart"])
        snapshot.update({key: old[key] for key in ("active_requests", "runner_collector_sample_monotonic_seconds")})
        snapshot["chart_preparations"] = rasters[index]
        counts = snapshot["graphics_diagnostics"]["metal_full_chart"]
        counts.update(static_frames=composites[index], static_cache_composites=composites[index],
                      static_rasterizations=rasters[index], submissions=composites[index],
                      static_scene_revisions=rasters[index], scene_initial_revisions=1,
                      scene_publication_revisions=rasters[index] - 1,
                      twinkle_frames=twinkles[index], effect_clock_ticks=effects[index])
        live = 0 if closed else min(2, retained[index])
        snapshot["graphics_diagnostics"]["retained_twinkles"].update(instances_created=retained[index],
            instances_destroyed=retained[index] - live, live_instances=live,
            peak_instances=min(2, retained[index]), animation_starts=retained[index])
        point["snapshot"] = snapshot
    return report


class CachedMetalSnapshotTests(unittest.TestCase):
    def test_cached_rendering_requires_real_texture_reuse_and_retained_animations(self):
        result = memory.metal_full_chart_contract(cached_snapshot(), MODE, completed_visible_workload=True)
        self.assertTrue(result["static_cache_enabled"])
        self.assertEqual(set(CACHE_FIELDS), set(memory.METAL_CACHE_FIELDS))
        memory.metal_full_chart_contract(cached_snapshot(closed=True), MODE, expected_closed=True)

    def test_optional_new_fields_do_not_invalidate_frozen_old_full_renderer(self):
        snapshot = full_snapshot()
        self.assertNotIn("metal_static_cache_enabled", snapshot["graphics_diagnostics"])
        self.assertTrue(memory.metal_full_chart_contract(snapshot, FULL_MODE)["enabled"])
        snapshot["graphics_diagnostics"].update(metal_static_cache_enabled=False)
        snapshot["graphics_diagnostics"]["metal_full_chart"].update(dict.fromkeys(CACHE_FIELDS, 0))
        snapshot["graphics_diagnostics"]["metal_full_chart"]["effect_clock_ticks"] = 1
        self.assertTrue(memory.metal_full_chart_contract(snapshot, FULL_MODE)["enabled"])

    def test_all_new_counters_and_boolean_are_required_without_type_coercion(self):
        for field in CACHE_FIELDS:
            for invalid in (None, True, -1, 1.0, "1", 2**64, "missing"):
                snapshot = cached_snapshot()
                values = snapshot["graphics_diagnostics"]["metal_full_chart"]
                if invalid == "missing":
                    del values[field]
                else:
                    values[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    memory.metal_full_chart_contract(snapshot, MODE)
        for invalid in (None, False, 1):
            snapshot = cached_snapshot()
            snapshot["graphics_diagnostics"]["metal_static_cache_enabled"] = invalid
            with self.subTest(flag=invalid), self.assertRaises(ValueError):
                memory.metal_full_chart_contract(snapshot, MODE)

    def test_cache_lifetime_counts_and_frame_failures_cannot_masquerade_as_savings(self):
        for change in ({"static_rasterizations": 6}, {"static_cache_composites": 4},
                       {"current_texture_bytes": 16385}, {"peak_texture_bytes": 0},
                       {"frames_skipped": 1}, {"failures": 1}):
            snapshot = cached_snapshot()
            snapshot["graphics_diagnostics"]["metal_full_chart"].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                memory.metal_full_chart_contract(snapshot, MODE, completed_visible_workload=True)
        snapshot = cached_snapshot(closed=True)
        snapshot["graphics_diagnostics"]["metal_full_chart"]["current_texture_bytes"] = 1
        with self.assertRaises(ValueError):
            memory.metal_full_chart_contract(snapshot, MODE, expected_closed=True)

    def test_cache_work_is_rejected_in_uncached_modes(self):
        for field in CACHE_FIELDS:
            if field == "effect_clock_ticks":
                continue
            snapshot = full_snapshot()
            snapshot["graphics_diagnostics"].update(metal_static_cache_enabled=False)
            snapshot["graphics_diagnostics"]["metal_full_chart"].update(dict.fromkeys(CACHE_FIELDS, 0))
            snapshot["graphics_diagnostics"]["metal_full_chart"][field] = 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                memory.metal_full_chart_contract(snapshot, FULL_MODE)

    def test_missing_retained_animations_is_rejected_even_if_shader_twinkles_exist(self):
        snapshot = cached_snapshot()
        snapshot["graphics_diagnostics"]["retained_twinkles"]["animation_starts"] = 0
        with self.assertRaises(ValueError):
            memory.metal_full_chart_contract(snapshot, MODE, completed_visible_workload=True)


class CachedMetalRuntimeTests(unittest.TestCase):
    def test_cached_workload_proves_static_publications_and_quiet_steady_effect_clock(self):
        report = cached_runtime_report()
        result = runtime.validate_canvas_clock_work(report, MODE)
        proof = result["cache_publication_proof"]
        self.assertTrue(proof["steady_effect_clock_stopped"])
        self.assertEqual(proof["steady_chart_preparations"], 10)
        self.assertEqual(proof["steady_static_scene_revisions"], 10)
        self.assertEqual(result["steady_deltas"]["effect_clock_ticks"], 0)
        self.assertEqual(result["steady_deltas"]["twinkle_frames"], 0)
        self.assertGreater(result["arrival_deltas"]["twinkle_frames"], 0)
        self.assertTrue(all(value == 0 for value in result["closed_deltas"].values()))
        self.assertFalse(runtime.cpu_acceptance_eligible(MODE))

    def test_gpu_runs_identical_contract_with_its_short_checkpoint_labels(self):
        report = cached_runtime_report()
        report["checkpoints"][0]["label"], report["checkpoints"][1]["label"] = "closed-start", "closed-end"
        self.assertTrue(gpu.validate_short_clock_work(report, MODE)["cache_publication_proof"]["steady_effect_clock_stopped"])

    def test_still_running_metal_clock_or_shader_twinkles_are_rejected(self):
        for field in ("effect_clock_ticks", "twinkle_frames"):
            report = cached_runtime_report()
            for point in report["runtime"]["checkpoints"][3:] + report["checkpoints"]:
                point["snapshot"]["graphics_diagnostics"]["metal_full_chart"][field] += 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_redraws_at_animation_rate_are_rejected_even_with_quiet_clock_metadata(self):
        for fields in (("static_rasterizations",), ("static_frames", "static_cache_composites", "submissions")):
            report = cached_runtime_report()
            for point in report["runtime"]["checkpoints"][3:] + report["checkpoints"]:
                for field in fields:
                    point["snapshot"]["graphics_diagnostics"]["metal_full_chart"][field] += 4
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_scale_changes_without_new_prepared_publications_are_explicit_valid_invalidations(self):
        report = cached_runtime_report()
        for point in report["runtime"]["checkpoints"][3:] + report["checkpoints"]:
            counts = point["snapshot"]["graphics_diagnostics"]["metal_full_chart"]
            for field in ("static_frames", "static_cache_composites", "submissions", "static_rasterizations",
                          "static_scene_revisions", "scene_scale_revisions"):
                counts[field] += 4
        result = runtime.validate_canvas_clock_work(report, MODE)
        self.assertEqual(result["cache_publication_proof"]["steady_chart_preparations"], 10)
        self.assertEqual(result["steady_deltas"]["static_rasterizations"], 14)
        self.assertEqual(result["cache_publication_proof"]["steady_scene_revision_causes"]["scene_scale_revisions"], 4)

    def test_unclassified_revisions_and_unexplained_revision_counts_are_rejected(self):
        for fault in ("unclassified", "missing-cause"):
            report = cached_runtime_report()
            for point in report["runtime"]["checkpoints"][3:] + report["checkpoints"]:
                counts = point["snapshot"]["graphics_diagnostics"]["metal_full_chart"]
                counts["static_scene_revisions"] += 1
                if fault == "unclassified":
                    counts["scene_unclassified_revisions"] += 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_overlapping_causes_are_valid_but_no_single_cause_can_exceed_revisions(self):
        snapshot = cached_snapshot()
        values = snapshot["graphics_diagnostics"]["metal_full_chart"]
        values["scene_scale_revisions"] = values["scene_publication_revisions"] = 2
        self.assertTrue(memory.metal_full_chart_contract(snapshot, MODE)["enabled"])
        values["scene_scale_revisions"] += 1
        with self.assertRaises(ValueError):
            memory.metal_full_chart_contract(snapshot, MODE)

    def test_no_new_retained_glints_in_steady_phase_is_rejected(self):
        for field in ("instances_created", "animation_starts"):
            report = cached_runtime_report()
            first, last = report["runtime"]["checkpoints"][2:4]
            values = last["snapshot"]["graphics_diagnostics"]["retained_twinkles"]
            values[field] = first["snapshot"]["graphics_diagnostics"]["retained_twinkles"][field]
            if field == "instances_created":
                values["instances_destroyed"] = values[field] - values["live_instances"]
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_resource_leaks_closed_work_and_missing_visibility_are_rejected(self):
        for fault in ("texture", "animation", "effect_clock", "visibility", "preparations"):
            report = cached_runtime_report()
            point = report["checkpoints"][-1]
            if fault == "texture":
                point["snapshot"]["graphics_diagnostics"]["metal_full_chart"]["current_texture_bytes"] = 1
            elif fault == "animation":
                point["snapshot"]["graphics_diagnostics"]["retained_twinkles"]["animation_starts"] += 1
            elif fault == "effect_clock":
                point["snapshot"]["graphics_diagnostics"]["metal_full_chart"]["effect_clock_ticks"] += 1
            elif fault == "visibility":
                report["runtime"]["checkpoints"][3]["snapshot"]["dashboard_visible"] = False
            else:
                del report["runtime"]["checkpoints"][3]["snapshot"]["chart_preparations"]
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_full_runtime_delta_rejects_per_frame_rasterization(self):
        before, after = workload_snapshots(MODE)
        result = runtime.validate_runtime_work(before, after, MODE)
        self.assertFalse(result["promotion_eligible"])
        counts = after["graphics_diagnostics"]["metal_full_chart"]
        counts.update(static_rasterizations=counts["static_rasterizations"] + 10,
                      static_cache_composites=100, static_frames=100, submissions=100)
        with self.assertRaises(ValueError):
            runtime.validate_runtime_work(before, after, MODE)

    def test_full_runtime_accepts_recorded_scale_revisions_without_extra_chart_preparations(self):
        before, after = workload_snapshots(MODE)
        counts = after["graphics_diagnostics"]["metal_full_chart"]
        for field in ("static_frames", "static_cache_composites", "submissions", "static_rasterizations",
                      "static_scene_revisions", "scene_scale_revisions"):
            counts[field] += 4
        result = runtime.validate_runtime_work(before, after, MODE)
        self.assertEqual(result["deltas"]["chart_preparations"], 2)
        self.assertEqual(result["metal_full_chart_deltas"]["static_rasterizations"], 5)
        counts["scene_scale_revisions"] -= 1
        counts["scene_unclassified_revisions"] += 1
        with self.assertRaisesRegex(ValueError, "unclassified"):
            runtime.validate_runtime_work(before, after, MODE)


if __name__ == "__main__":
    unittest.main()
