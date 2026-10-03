"""Independent native effects phase and transaction proofs; no native capture."""
import unittest

import memory_attribution as memory
import runtime_attribution as runtime
import runtime_gpu_comparison as gpu
from test_runtime_attribution import workload_snapshots
from test_runtime_full_chart import full_runtime_report
from test_runtime_gpu_comparison import qualified_comparison
from test_runtime_primitive_memory import primitive_snapshot, MODE, COMBINED


def primitive_runtime_report(mode=MODE):
    report = full_runtime_report()
    rows = report["runtime"]["checkpoints"] + report["checkpoints"]
    submissions = (0, 18, 20, 20, 21, 40, 60, 62, 62)
    uploads = (0, 2, 3, 3, 4, 5, 6, 6, 6)
    arrivals = (0, 15, 15, 15, 15, 15, 15, 15, 15)
    completions = (0, 0, 0, 0, 0, 20, 40, 40, 40)
    twinkles = (0, 4, 5, 5, 6, 20, 25, 25, 25)
    clears = (0, 2, 2, 2, 2, 3, 4, 4, 4)
    retained = (0, 2, 4, 20, 28, 28, 30, 30, 30)
    for index, point in enumerate(rows):
        old = point["snapshot"]
        closed = not old["dashboard_visible"]
        snapshot = primitive_snapshot(mode, closed=closed, descriptor_uploads=uploads[index],
            submissions=submissions[index], arrival_frames=arrivals[index], completion_frames=completions[index],
            twinkle_frames=twinkles[index], clears=clears[index])
        snapshot.update(active_requests=old["active_requests"],
                        runner_collector_sample_monotonic_seconds=old["runner_collector_sample_monotonic_seconds"],
                        chart_preparations=index * 2)
        value = snapshot["graphics_diagnostics"]
        value["roles"]["static_chart"]["draws"] = index * 2 + 3
        live = 0 if closed else min(2, retained[index])
        value["retained_twinkles"].update(instances_created=retained[index], instances_destroyed=retained[index] - live,
            live_instances=live, peak_instances=min(2, retained[index]), animation_starts=retained[index])
        point["snapshot"] = snapshot
    return report


def mechanism_snapshots(mode):
    before, after = primitive_snapshot(mode), primitive_snapshot(mode)
    for namespace, _flag, enabled_modes, fields in runtime.TRANSACTION_MECHANISMS:
        before["graphics_diagnostics"][namespace] = dict.fromkeys(fields, 0)
        if mode not in enabled_modes:
            after["graphics_diagnostics"][namespace] = dict.fromkeys(fields, 0)
    return before, after


class PrimitiveEffectsPhaseTests(unittest.TestCase):
    def test_real_arrivals_completions_retained_steady_and_closed_quiet(self):
        for mode in (MODE, COMBINED):
            result = runtime.validate_canvas_clock_work(primitive_runtime_report(mode), mode)
            self.assertGreater(result["arrival_deltas"]["arrival_frames"], 0)
            self.assertGreater(result["completion_deltas"]["completion_frames"], 0)
            self.assertGreater(result["steady_retained_twinkle_deltas"]["animation_starts"], 0)
            self.assertTrue(all(value == 0 for value in result["steady_deltas"].values()))
            self.assertTrue(all(value == 0 for value in result["closed_deltas"].values()))
            self.assertFalse(result["full_static_chart_composition"])
            self.assertFalse(result["promotion_eligible"])
            self.assertFalse(runtime.cpu_acceptance_eligible(mode))
            self.assertTrue(result["lifecycle_glint_overlap_exercised"])
            self.assertGreater(result["lifecycle_glint_overlap_frames"], 0)
            self.assertTrue(result["dedicated_lifecycle_glint_overlap_evidence_required"])

    def test_zero_overlap_is_reported_unexercised_without_qualifying_that_path(self):
        for mode in (MODE, COMBINED):
            report = primitive_runtime_report(mode)
            for point in report["runtime"]["checkpoints"] + report["checkpoints"]:
                point["snapshot"]["graphics_diagnostics"]["metal_primitive_effects"]["twinkle_frames"] = 0
            result = runtime.validate_canvas_clock_work(report, mode)
            self.assertFalse(result["lifecycle_glint_overlap_exercised"])
            self.assertEqual(result["lifecycle_glint_overlap_frames"], 0)
            self.assertTrue(result["dedicated_lifecycle_glint_overlap_evidence_required"])
            self.assertFalse(result["promotion_eligible"])
            self.assertGreater(result["arrival_deltas"]["arrival_frames"], 0)
            self.assertGreater(result["completion_deltas"]["completion_frames"], 0)
            self.assertGreater(result["steady_retained_twinkle_deltas"]["animation_starts"], 0)

    def test_overlap_counter_remains_required_unsigned_and_monotonic(self):
        for mode in (MODE, COMBINED):
            for invalid in ("missing", None, True, -1, 1.0, "1", 2**64, "regression"):
                report = primitive_runtime_report(mode)
                counts = report["runtime"]["checkpoints"][3]["snapshot"]["graphics_diagnostics"]["metal_primitive_effects"]
                if invalid == "missing":
                    del counts["twinkle_frames"]
                elif invalid == "regression":
                    counts["twinkle_frames"] = 3  # The previous checkpoint recorded five.
                else:
                    counts["twinkle_frames"] = invalid
                with self.subTest(mode=mode, invalid=invalid), self.assertRaises(ValueError):
                    runtime.validate_canvas_clock_work(report, mode)

    def test_gpu_reuses_same_proofs_with_its_short_closed_observation(self):
        report = primitive_runtime_report()
        report["checkpoints"][0]["label"], report["checkpoints"][1]["label"] = "closed-start", "closed-end"
        result = gpu.validate_short_clock_work(report, MODE)
        self.assertGreater(result["completion_deltas"]["completion_frames"], 0)
        self.assertTrue(result["frame_delivery_qualified"])

    def test_short_gpu_zero_overlap_preserves_explicit_coverage_gap(self):
        for mode in (MODE, COMBINED):
            report = primitive_runtime_report(mode)
            report["checkpoints"][0]["label"], report["checkpoints"][1]["label"] = "closed-start", "closed-end"
            for point in report["runtime"]["checkpoints"] + report["checkpoints"]:
                point["snapshot"]["graphics_diagnostics"]["metal_primitive_effects"]["twinkle_frames"] = 0
            result = gpu.validate_short_clock_work(report, mode)
            self.assertFalse(result["lifecycle_glint_overlap_exercised"])
            self.assertEqual(result["lifecycle_glint_overlap_frames"], 0)
            self.assertTrue(result["dedicated_lifecycle_glint_overlap_evidence_required"])
            self.assertFalse(result["promotion_eligible"])
            self.assertGreater(result["arrival_deltas"]["arrival_frames"], 0)
            self.assertGreater(result["completion_deltas"]["completion_frames"], 0)

    def test_native_steady_work_cannot_masquerade_as_gpu_savings(self):
        for field in memory.METAL_PRIMITIVE_EFFECTS_COUNTERS:
            if field in ("hosts_created", "hosts_destroyed", "frames_skipped", "failures", "fallbacks"):
                continue
            report = primitive_runtime_report()
            for point in report["runtime"]["checkpoints"][3:] + report["checkpoints"]:
                point["snapshot"]["graphics_diagnostics"]["metal_primitive_effects"][field] += 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_missing_phase_work_and_retained_glints_are_rejected(self):
        for field in ("arrival_frames", "completion_frames", "retained"):
            report = primitive_runtime_report()
            for point in report["runtime"]["checkpoints"] + report["checkpoints"]:
                if field == "retained":
                    point["snapshot"]["graphics_diagnostics"]["retained_twinkles"]["animation_starts"] = 0
                else:
                    point["snapshot"]["graphics_diagnostics"]["metal_primitive_effects"][field] = 0
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_late_arrivals_do_not_satisfy_arrival_phase(self):
        report = primitive_runtime_report()
        for point in report["runtime"]["checkpoints"][:5]:
            point["snapshot"]["graphics_diagnostics"]["metal_primitive_effects"]["arrival_frames"] = 0
        with self.assertRaisesRegex(ValueError, "arrivals did not submit"):
            runtime.validate_canvas_clock_work(report, MODE)

    def test_visibility_identity_regression_and_legacy_rendering_are_rejected(self):
        for fault in ("hidden", "pid", "birth", "unpaired", "regression", "clock", "timeline", "canvas", "full-static"):
            report = primitive_runtime_report()
            point = report["runtime"]["checkpoints"][3]
            snapshot = point["snapshot"]
            if fault == "hidden":
                snapshot["dashboard_visible"] = False
            elif fault in ("pid", "birth"):
                point["resource_sample"]["process_id" if fault == "pid" else "birth_time_us"] += 1
            elif fault == "unpaired":
                report["samples"].remove(point["resource_sample"])
            elif fault == "regression":
                snapshot["graphics_diagnostics"]["metal_primitive_effects"]["descriptor_uploads"] = 0
            elif fault in ("clock", "timeline"):
                snapshot["rail_frame_clock_ticks" if fault == "clock" else "rail_timeline_content_updates"] = 1
            elif fault == "canvas":
                snapshot["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] = 1
            else:
                snapshot["graphics_diagnostics"]["metal_full_chart"]["submissions"] = 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_static_chart_cannot_stop_to_claim_native_effect_savings(self):
        for fault in ("preparations", "draws"):
            report = primitive_runtime_report()
            first, last = report["runtime"]["checkpoints"][2:4]
            if fault == "preparations":
                last["snapshot"]["chart_preparations"] = first["snapshot"]["chart_preparations"]
            else:
                last["snapshot"]["graphics_diagnostics"]["roles"]["static_chart"]["draws"] = first["snapshot"][
                    "graphics_diagnostics"]["roles"]["static_chart"]["draws"]
            with self.subTest(fault=fault), self.assertRaisesRegex(ValueError, "steady static chart"):
                runtime.validate_canvas_clock_work(report, MODE)

    def test_closed_resource_leaks_growth_or_missing_interval_are_rejected(self):
        for fault in ("buffer", "host", "submission", "retained", "short", "missing"):
            report = primitive_runtime_report()
            last = report["checkpoints"][-1]
            counts = last["snapshot"]["graphics_diagnostics"]["metal_primitive_effects"]
            if fault == "buffer":
                counts["current_buffer_bytes"] = 1
            elif fault == "host":
                counts.update(hosts_destroyed=1, live_hosts=1)
            elif fault == "submission":
                counts["submissions"] += 1
            elif fault == "retained":
                last["snapshot"]["graphics_diagnostics"]["retained_twinkles"]["animation_starts"] += 1
            elif fault == "short":
                last["resource_sample"]["mach_absolute_seconds"] -= 3
            else:
                report["checkpoints"].pop()
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_canvas_clock_work(report, MODE)


class TransactionRuntimeProofTests(unittest.TestCase):
    def test_complete_runtime_contracts_include_executed_mechanisms_and_renderer_evidence(self):
        for mode in memory.NEW_RUNTIME_MODES:
            before, after = workload_snapshots(mode)
            result = runtime.validate_runtime_work(before, after, mode)
            self.assertTrue(result["available"])
            self.assertGreater(result["deltas"]["static_chart_draws"], 0)
            self.assertIn("transaction_mechanisms", result)
            if mode in (MODE, COMBINED):
                self.assertFalse(result["promotion_eligible"])
                self.assertEqual(result["deltas"]["rail_frame_clock_ticks"], 0)
                self.assertEqual(result["deltas"]["rail_decorations_draws"], 0)
                self.assertGreater(result["metal_primitive_effects_deltas"]["completion_frames"], 0)
                self.assertTrue(result["lifecycle_glint_overlap_exercised"])
                self.assertGreater(result["lifecycle_glint_overlap_frames"], 0)
                self.assertTrue(result["dedicated_lifecycle_glint_overlap_evidence_required"])

    def test_whole_runtime_rejects_legacy_clock_and_canvas_fallback(self):
        for fault in ("clock", "canvas"):
            before, after = workload_snapshots(MODE)
            if fault == "clock":
                after["rail_frame_clock_ticks"] += 1
            else:
                after["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"] += 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                runtime.validate_runtime_work(before, after, MODE)

    def test_whole_runtime_zero_overlap_remains_diagnostic_and_requires_separate_evidence(self):
        for mode in (MODE, COMBINED):
            before, after = workload_snapshots(mode)
            after["graphics_diagnostics"]["metal_primitive_effects"]["twinkle_frames"] = before[
                "graphics_diagnostics"]["metal_primitive_effects"]["twinkle_frames"]
            result = runtime.validate_runtime_work(before, after, mode)
            self.assertFalse(result["lifecycle_glint_overlap_exercised"])
            self.assertEqual(result["lifecycle_glint_overlap_frames"], 0)
            self.assertTrue(result["dedicated_lifecycle_glint_overlap_evidence_required"])
            self.assertFalse(result["promotion_eligible"])
            self.assertFalse(runtime.cpu_acceptance_eligible(mode))

    def test_whole_runtime_still_requires_arrivals_completions_and_complete_overlap_counter(self):
        for mode in (MODE, COMBINED):
            for field in ("arrival_frames", "completion_frames"):
                before, after = workload_snapshots(mode)
                after["graphics_diagnostics"]["metal_primitive_effects"][field] = before[
                    "graphics_diagnostics"]["metal_primitive_effects"][field]
                with self.subTest(mode=mode, absent_work=field), self.assertRaises(ValueError):
                    runtime.validate_runtime_work(before, after, mode)
            for invalid in ("missing", None, True, -1, 1.0, "1", 2**64, "regression"):
                before, after = workload_snapshots(mode)
                counts = after["graphics_diagnostics"]["metal_primitive_effects"]
                if invalid == "missing":
                    del counts["twinkle_frames"]
                elif invalid == "regression":
                    counts["twinkle_frames"] = before["graphics_diagnostics"]["metal_primitive_effects"]["twinkle_frames"] - 1
                else:
                    counts["twinkle_frames"] = invalid
                with self.subTest(mode=mode, invalid=invalid), self.assertRaises(ValueError):
                    runtime.validate_runtime_work(before, after, mode)

    def test_standalone_and_combined_modes_execute_only_their_mechanisms(self):
        for mode in memory.NEW_RUNTIME_MODES:
            before, after = mechanism_snapshots(mode)
            result = runtime.transaction_mechanism_work(before, after, mode)
            self.assertIs(result["batched_telemetry"]["enabled"], mode in memory.BATCHED_TELEMETRY_MODES)
            self.assertIs(result["atomic_chart_scale"]["enabled"], mode in memory.ATOMIC_CHART_SCALE_MODES)
        for mode in (memory.TELEMETRY_BATCH_MODE, memory.ATOMIC_CHART_SCALE_MODE):
            self.assertTrue(runtime.cpu_acceptance_eligible(mode))

    def test_atomic_scales_need_no_artificial_cache_read_or_axis_change(self):
        before, after = mechanism_snapshots(memory.ATOMIC_CHART_SCALE_MODE)
        after["graphics_diagnostics"]["atomic_chart_scale"].update(cache_hits=0, scale_changes=0)
        self.assertTrue(runtime.transaction_mechanism_work(before, after, memory.ATOMIC_CHART_SCALE_MODE)["atomic_chart_scale"]["enabled"])

    def test_frozen_absent_mechanisms_remain_compatible(self):
        self.assertEqual(runtime.transaction_mechanism_work({}, {}, "normal"), {})

    def test_candidates_require_positive_delivery_and_bounded_snapshot_projection_work(self):
        for field in memory.BATCHED_TELEMETRY_COUNTERS:
            before, after = mechanism_snapshots(memory.TELEMETRY_BATCH_MODE)
            after["graphics_diagnostics"]["batched_telemetry"][field] = 0
            with self.subTest(field=field), self.assertRaises(ValueError):
                runtime.transaction_mechanism_work(before, after, memory.TELEMETRY_BATCH_MODE)
        for changes in ({"snapshots_materialized": 101}, {"projection_refreshes": 11}):
            before, after = mechanism_snapshots(memory.TELEMETRY_BATCH_MODE)
            after["graphics_diagnostics"]["batched_telemetry"].update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                runtime.transaction_mechanism_work(before, after, memory.TELEMETRY_BATCH_MODE)

    def test_missing_mistyped_regressing_or_inactive_counters_are_rejected(self):
        for mode in (memory.TELEMETRY_BATCH_MODE, memory.ATOMIC_CHART_SCALE_MODE):
            for namespace, _flag, _modes, fields in runtime.TRANSACTION_MECHANISMS:
                for field in fields:
                    for invalid in (None, True, -1, 1.0, "1", 2**64):
                        before, after = mechanism_snapshots(mode)
                        after["graphics_diagnostics"][namespace][field] = invalid
                        with self.subTest(mode=mode, namespace=namespace, field=field, invalid=invalid), self.assertRaises(ValueError):
                            runtime.transaction_mechanism_work(before, after, mode)
            before, after = mechanism_snapshots(mode)
            namespace = "batched_telemetry" if mode == memory.TELEMETRY_BATCH_MODE else "atomic_chart_scale"
            field = "compact_states_enqueued" if mode == memory.TELEMETRY_BATCH_MODE else "resolutions"
            before["graphics_diagnostics"][namespace][field] = after["graphics_diagnostics"][namespace][field] + 1
            with self.assertRaisesRegex(ValueError, "moved backwards"):
                runtime.transaction_mechanism_work(before, after, mode)


class ExperimentalGPUQualificationTests(unittest.TestCase):
    def test_primitive_and_combined_gpu_diagnostics_do_not_claim_promotion(self):
        for mode in (MODE, COMBINED):
            result = qualified_comparison()
            result["rows"][1]["mode"] = mode
            gpu.qualify_result(result)
            self.assertFalse(result["rows"][1]["promotion_eligible"])
            self.assertFalse(result["rows"][1]["cpu_acceptance_eligible"])
            self.assertIn(mode, gpu.MODES)
        self.assertTrue(set(memory.NEW_RUNTIME_MODES) <= set(gpu.MODES))


if __name__ == "__main__":
    unittest.main()
