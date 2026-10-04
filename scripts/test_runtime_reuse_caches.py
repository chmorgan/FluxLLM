"""Independent cache proof fixtures; never launch a native capture or change load."""
import copy
import unittest

import memory_attribution as memory
import runtime_attribution as runtime
import runtime_gpu_comparison as gpu
from test_memory_diagnostic import drawn_native_gpu_graphics
from test_runtime_attribution import workload_snapshots
from test_runtime_full_chart import full_runtime_report


def cache_report(mode=memory.REUSE_CACHES_MODE):
    report = full_runtime_report()
    rows = report["runtime"]["checkpoints"] + report["checkpoints"]
    ticks = (0, 40, 40, 40, 41, 100, 150, 150, 150)
    retained = (0, 2, 4, 20, 28, 28, 30, 30, 30)
    for index, point in enumerate(rows):
        old = point["snapshot"]
        hidden = not old["dashboard_visible"]
        snapshot = drawn_native_gpu_graphics(mode)
        snapshot.update(dashboard_visible=not hidden, popover_visible=not hidden,
                        active_requests=old["active_requests"], chart_preparations=index * 2 + 3,
                        runner_collector_sample_monotonic_seconds=old["runner_collector_sample_monotonic_seconds"],
                        rail_frame_clock_ticks=ticks[index])
        value = snapshot["graphics_diagnostics"]
        value["roles"]["static_chart"]["draws"] = index * 2 + 3
        value["roles"]["rail_decorations"]["draws"] = ticks[index]
        value["native_gpu_canvas_draws"] = snapshot["grouped_native_canvas_draws"] = sum(
            role["draws"] for role in value["roles"].values())
        live = 0 if hidden else min(2, retained[index])
        value["retained_twinkles"].update(hosts_created=2, hosts_destroyed=2 if hidden else 0,
            live_hosts=0 if hidden else 2, peak_hosts=2, instances_created=retained[index],
            instances_destroyed=retained[index] - live, live_instances=live,
            peak_instances=min(2, retained[index]), animation_starts=retained[index])
        if mode in memory.COMPLETED_LANE_CACHE_MODES:
            value["completed_lane_cache"].update(builds=min(3, index + 1), hits=min(20, index * 3 + 2),
                visited_records=min(3, index + 1) * 240, current_entries=0 if hidden else 240, peak_entries=240)
        if mode in memory.CACHED_RAIL_GEOMETRY_MODES:
            builds = 0 if index == 0 else 2 if index < 5 else 4
            value["rail_geometry_cache"].update(builds=builds, hits=0 if index == 0 else 40 if index < 5 else 80,
                current_entries=2 if index in (1, 4, 5) else 0, peak_entries=0 if index == 0 else 2,
                current_caches=2 if index in (1, 4, 5) else 0, peak_caches=0 if index == 0 else 2)
            value["rail_geometry_cache_used"] = builds > 0
        point["snapshot"] = snapshot
    return report


class ReuseMetadataTests(unittest.TestCase):
    def test_exact_independent_flags_and_normal_rendering_cadence(self):
        for mode in memory.REUSE_RUNTIME_MODES:
            snapshot = drawn_native_gpu_graphics(mode)
            result = memory.validate_graphics(snapshot, mode, completed_visible_workload=True)
            flags = result["runtime_feature_contract"]
            self.assertEqual(flags["completed_lane_cache_enabled"], mode in memory.COMPLETED_LANE_CACHE_MODES)
            self.assertEqual(flags["rail_geometry_cache_enabled"], mode in memory.CACHED_RAIL_GEOMETRY_MODES)
            self.assertTrue(flags["lifecycle_effects_enabled"] and flags["arrival_effects_enabled"])
            self.assertTrue(flags["canvas_frame_clock"] and flags["ordered_chart_publication"])
            self.assertFalse(flags["metal_primitive_effects_enabled"] or flags["batched_telemetry_delivery_enabled"]
                             or flags["atomic_chart_scale_enabled"])
            self.assertEqual(result["chart_publication_interval_seconds"], 1)
            self.assertTrue(runtime.cpu_acceptance_eligible(mode))
            self.assertFalse(runtime.cpu_acceptance_eligible(mode, profile=True))

    def test_old_frozen_normal_missing_metadata_remains_optional(self):
        snapshot = drawn_native_gpu_graphics(memory.ORDERED_PUBLICATION_MODE)
        snapshot["graphics_diagnostics"]["mode"] = "normal"
        self.assertIsNone(memory.reuse_cache_contract(snapshot, "normal"))
        self.assertIsNone(runtime.reuse_cache_mechanism_work(snapshot, copy.deepcopy(snapshot), "normal"))

    def test_every_candidate_counter_is_complete_uint64(self):
        for namespace, _flag, _modes, counters, _maximum in memory.REUSE_CACHE_SPECS:
            fields = counters + memory.REUSE_CACHE_GAUGES
            if namespace == "rail_geometry_cache":
                fields += ("current_caches", "peak_caches", "max_entries_per_cache")
            for field in fields:
                for invalid in ("missing", None, True, -1, 1.0, "1", 2**64):
                    snapshot = drawn_native_gpu_graphics(memory.REUSE_CACHES_MODE)
                    raw = snapshot["graphics_diagnostics"][namespace]
                    if invalid == "missing":
                        del raw[field]
                    else:
                        raw[field] = invalid
                    with self.subTest(namespace=namespace, field=field, value=invalid), self.assertRaises(ValueError):
                        memory.reuse_cache_contract(snapshot, memory.REUSE_CACHES_MODE)

    def test_partial_metadata_wrong_mode_and_false_used_flag_are_rejected(self):
        for field in memory.REUSE_RUNTIME_FLAGS + ("rail_geometry_cache_used",):
            for invalid in ("missing", None, 1, False):
                snapshot = drawn_native_gpu_graphics(memory.REUSE_CACHES_MODE)
                value = snapshot["graphics_diagnostics"]
                if invalid == "missing":
                    del value[field]
                else:
                    value[field] = invalid
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    memory.reuse_cache_contract(snapshot, memory.REUSE_CACHES_MODE)

    def test_nonselected_cache_cannot_execute_work(self):
        for mode, namespace in ((memory.COMPLETED_LANE_CACHE_MODE, "rail_geometry_cache"),
                                (memory.CACHED_RAIL_GEOMETRY_MODE, "completed_lane_cache")):
            snapshot = drawn_native_gpu_graphics(mode)
            snapshot["graphics_diagnostics"][namespace]["hits"] = 1
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                memory.reuse_cache_contract(snapshot, mode)

    def test_bounds_and_owner_gauges_reject_underreported_or_leaking_cache(self):
        faults = (("completed_lane_cache", {"current_entries": 20_001, "peak_entries": 20_001}),
                  ("rail_geometry_cache", {"current_entries": 25, "peak_entries": 25}),
                  ("rail_geometry_cache", {"current_entries": 0, "current_caches": 1}),
                  ("rail_geometry_cache", {"current_entries": 1, "current_caches": 0}),
                  ("rail_geometry_cache", {"current_caches": 3, "peak_caches": 3}),
                  ("rail_geometry_cache", {"max_entries_per_cache": 25}))
        for namespace, changes in faults:
            snapshot = drawn_native_gpu_graphics(memory.REUSE_CACHES_MODE)
            snapshot["graphics_diagnostics"][namespace].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                memory.reuse_cache_contract(snapshot, memory.REUSE_CACHES_MODE)

    def test_current_entries_may_decrease_but_cumulative_work_must_not(self):
        before, after = workload_snapshots(memory.REUSE_CACHES_MODE)
        after["graphics_diagnostics"]["completed_lane_cache"]["current_entries"] = 120
        result = runtime.reuse_cache_mechanism_work(before, after, memory.REUSE_CACHES_MODE)
        self.assertEqual(result["completed_lane_cache"]["current_entries"], 120)
        for namespace, _flag, _modes, counters, _max in memory.REUSE_CACHE_SPECS:
            for field in counters + ("peak_entries",):
                left, right = workload_snapshots(memory.REUSE_CACHES_MODE)
                right["graphics_diagnostics"][namespace][field] = left["graphics_diagnostics"][namespace][field] - 1
                with self.subTest(namespace=namespace, field=field), self.assertRaises(ValueError):
                    runtime.reuse_cache_mechanism_work(left, right, memory.REUSE_CACHES_MODE)

    def test_zero_executed_reuse_is_rejected(self):
        for mode in memory.REUSE_RUNTIME_MODES:
            before, after = workload_snapshots(mode)
            for namespace, _flag, modes, counters, _max in memory.REUSE_CACHE_SPECS:
                if mode not in modes:
                    continue
                for field in counters:
                    altered = copy.deepcopy(after)
                    altered["graphics_diagnostics"][namespace][field] = before["graphics_diagnostics"][namespace][field]
                    with self.subTest(mode=mode, field=field), self.assertRaisesRegex(ValueError, "execute builds and reuse"):
                        runtime.reuse_cache_mechanism_work(before, altered, mode)


class ReusePhaseTests(unittest.TestCase):
    def test_real_arrivals_completion_retained_glints_and_closed_cleanup(self):
        for mode in memory.REUSE_RUNTIME_MODES:
            report = cache_report(mode)
            result = runtime.validate_canvas_clock_work(report, mode)["reuse_caches"]
            self.assertGreater(result["arrival_deltas"]["rail_decorations_draws"], 0)
            self.assertGreater(result["completion_deltas"]["rail_decorations_draws"], 0)
            self.assertGreater(result["steady_retained_twinkle_animation_starts"], 0)
            self.assertTrue(result["semantic_parity_required"])
            self.assertEqual(result["closed_current_entries"], {"completed_lane_cache": 0, "rail_geometry_cache": 0})

    def test_short_gpu_reuses_same_proof_and_keeps_cpu_ineligible(self):
        report = cache_report()
        report["runtime_work"] = {"features": memory.runtime_feature_contract(
            report["runtime"]["checkpoints"][0]["snapshot"]["graphics_diagnostics"], memory.REUSE_CACHES_MODE)}
        report["checkpoints"][0]["label"], report["checkpoints"][1]["label"] = "closed-start", "closed-end"
        result = gpu.validate_short_clock_work(report, memory.REUSE_CACHES_MODE)
        self.assertGreater(result["reuse_caches"]["completion_deltas"]["rail_decorations_draws"], 0)
        self.assertEqual(gpu.MAX_SECONDS, 300)
        self.assertIn(memory.REUSE_CACHES_MODE, gpu.MODES)

    def test_phase_work_retained_glints_and_visibility_cannot_be_suppressed(self):
        for fault in ("arrival", "completion", "glints", "hidden"):
            report = cache_report()
            if fault == "arrival":
                report["runtime"]["checkpoints"][1]["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = 0
            elif fault == "completion":
                for point in report["runtime"]["checkpoints"][5:]:
                    point["snapshot"]["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = 41
            elif fault == "glints":
                report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["retained_twinkles"]["animation_starts"] = 4
            else:
                report["runtime"]["checkpoints"][3]["snapshot"]["dashboard_visible"] = False
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_reuse_cache_phase_work(report, memory.REUSE_CACHES_MODE)

    def test_closed_entries_work_growth_or_missing_cleanup_are_rejected(self):
        for fault in ("lane", "rail", "growth", "missing", "short"):
            report = cache_report()
            last = report["checkpoints"][-1]
            if fault == "lane":
                last["snapshot"]["graphics_diagnostics"]["completed_lane_cache"]["current_entries"] = 1
            elif fault == "rail":
                last["snapshot"]["graphics_diagnostics"]["rail_geometry_cache"].update(current_entries=1, current_caches=1)
            elif fault == "growth":
                last["snapshot"]["graphics_diagnostics"]["completed_lane_cache"]["hits"] += 1
            elif fault == "missing":
                report["checkpoints"].pop()
            else:
                last["resource_sample"]["mach_absolute_seconds"] -= 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_reuse_cache_phase_work(report, memory.REUSE_CACHES_MODE)

    def test_intermediate_cumulative_regression_is_rejected(self):
        report = cache_report()
        report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["completed_lane_cache"]["hits"] = 0
        with self.assertRaisesRegex(ValueError, "moved backwards"):
            runtime.validate_reuse_cache_phase_work(report, memory.REUSE_CACHES_MODE)


if __name__ == "__main__":
    unittest.main()
