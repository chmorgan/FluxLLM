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
    fields = ("created", "destroyed", "live", "peak_live", "updates", "renderer_creations", "renderer_updates",
              "renderer_destructions", "live_renderers", "peak_live_renderers", "draws", "skipped_draws",
              "current_pixel_area", "peak_pixel_area", "current_bitmap_bytes", "peak_bitmap_bytes",
              "max_width_points", "max_height_points", "max_scale")
    return {"graphics_diagnostics": {
        "enabled": True, "mode": mode, "invalid_events": 0, "cpu_glow_fallbacks": 0,
        "gradient_substitutions": 0,
        **({"layer_bitmap_presentations": 0, "layer_bitmap_failures": 0, "layer_bitmap_native_draws": 0,
            "current_layer_image_bytes": 0, "peak_layer_image_bytes": 0} if mode == "bitmap-layer-destination" else {}),
        "live_canvases": 0, "peak_live_canvases": 0, "live_renderers": 0, "peak_live_renderers": 0,
        "current_pixel_area": 0, "peak_pixel_area": 0, "current_bitmap_bytes": 0, "peak_bitmap_bytes": 0,
        "roles": {role: dict.fromkeys(fields + (("current_layer_image_bytes", "peak_layer_image_bytes")
                                               if mode == "bitmap-layer-destination" else ()), 0)
                  for role in ("static_chart", "cursor", "rail_bars", "rail_decorations")}}}


def drawn_layer_graphics():
    snapshot = graphics("bitmap-layer-destination")
    value = snapshot["graphics_diagnostics"]
    value.update(layer_bitmap_presentations=3, live_canvases=1, peak_live_canvases=1,
                 live_renderers=1, peak_live_renderers=1, current_layer_image_bytes=400, peak_layer_image_bytes=400)
    value["roles"]["static_chart"].update(created=1, live=1, peak_live=1, renderer_creations=1,
        live_renderers=1, peak_live_renderers=1, draws=3, current_layer_image_bytes=400, peak_layer_image_bytes=400)
    return snapshot


class GraphicsTests(unittest.TestCase):
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
