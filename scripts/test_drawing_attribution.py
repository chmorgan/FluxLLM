"""Drawing attribution validation and failure tests; no app or native tools run."""

import argparse
import contextlib
import copy
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import drawing_attribution as drawing
from run_performance_checks import InvalidResult, load_json


def graphics(backend="image-renderer", closed=False):
    fields = ("created", "destroyed", "live", "peak_live", "updates", "renderer_creations", "renderer_updates",
              "renderer_destructions", "live_renderers", "peak_live_renderers", "draws", "skipped_draws",
              "current_pixel_area", "peak_pixel_area", "current_bitmap_bytes", "peak_bitmap_bytes",
              "max_width_points", "max_height_points", "max_scale")
    roles = {role: dict.fromkeys(fields, 0) for role in ("static_chart", "cursor", "rail_bars", "rail_decorations")}
    exists = backend == "image-renderer"
    if exists:
        roles["static_chart"].update(created=1, destroyed=int(closed), live=int(not closed), peak_live=1,
                                     renderer_creations=1, renderer_destructions=int(closed),
                                     live_renderers=int(not closed), peak_live_renderers=1)
    return {"enabled": True, "mode": "normal", "invalid_events": 0, "cpu_glow_fallbacks": 0,
            "live_canvases": int(exists and not closed), "peak_live_canvases": int(exists),
            "live_renderers": int(exists and not closed), "peak_live_renderers": int(exists),
            "current_pixel_area": 0, "peak_pixel_area": 0, "current_bitmap_bytes": 0, "peak_bitmap_bytes": 0,
            "roles": roles}


def snapshot(case="image-renderer:line", frames=0, closed=False):
    backend, primitive = case.split(":")
    bitmap_bytes = 664 * 2 * 357 * 2 * 4 if backend == "bitmap-layer" and frames else 0
    return {"schema_version": 1, "backend": backend, "primitive": primitive,
            "uses_swiftui_host": backend != "core-graphics-unhosted",
            "window_visible": not closed, "window_number": 18, "draw_enabled": frames > 0 and not closed,
            "draw_calls": 1 + frames, "nonempty_draw_calls": frames if primitive != "empty" else 0,
            "requested_frames": frames, "revision": frames, "acknowledged_revision": frames,
            "acknowledged_frames": frames, "duplicate_draw_calls": 0,
            "content_width_points": 664, "content_height_points": 357, "backing_scale": 2,
            "graphics_diagnostics": graphics(backend, closed), "closed": closed,
            "released_window_live": False, "released_host_live": False, "released_content_live": False,
            "bitmap_update_layer_calls": 1 + frames if backend == "bitmap-layer" else 0,
            "bitmap_unexpected_native_draw_calls": 0, "bitmap_failures": 0,
            "bitmap_current_requested_scratch_bytes": 0, "bitmap_peak_requested_scratch_bytes": bitmap_bytes,
            "bitmap_current_requested_image_bytes": 0 if closed else bitmap_bytes,
            "bitmap_peak_requested_image_bytes": bitmap_bytes,
            "bitmap_images_created": frames if backend == "bitmap-layer" else 0}


def sample(stamp, phase="periodic", current=100, peak=200):
    return {"type": "sample", "monotonic_seconds": stamp, "phase": phase,
            "process_id": 17, "birth_time_us": 123, "physical_footprint_bytes": current,
            "lifetime_peak_footprint_bytes": peak, "cpu_seconds": stamp / 100}


def final_report(case="image-renderer:line"):
    samples = [sample(0, "baseline"), sample(.2), sample(.4, "final")]
    end = snapshot(case, frames=101, closed=True)
    return {"samples": samples, "events": [
        {"type": "app_event", "event": {"type": "stopped", "status": "ok", "drawing_snapshot": end}},
        {"type": "exited", "status": 0, "final_sample": samples[-1]}],
        "checkpoints": [{"label": "released", "snapshot": copy.deepcopy(end)}]}


class ValidationTests(unittest.TestCase):
    def test_supported_and_malformed_cases(self):
        for backend in drawing.BACKENDS:
            for primitive in drawing.PRIMITIVES:
                value = backend + ":" + primitive
                self.assertEqual(drawing.parse_case(value), value)
        for value in ("", "line", "metal:line", "canvas:wrong", "canvas:line:extra"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                drawing.parse_case(value)

    def test_repeated_case_flag_preserves_order(self):
        args = drawing.parser().parse_args(["--probe-binary", "/probe", "--collector-binary", "/collector",
                                           "--case", "canvas:line", "--case", "core-graphics:text"])
        self.assertEqual(args.cases, ["canvas:line", "core-graphics:text"])

    def test_observer_control_and_settling_cli_are_bounded(self):
        base = ["--probe-binary", "/probe", "--collector-binary", "/collector"]
        args = drawing.parser().parse_args(base)
        self.assertFalse(args.no_native_inspection)
        self.assertEqual(args.settle_seconds, 1)
        args = drawing.parser().parse_args(base + ["--no-native-inspection", "--settle-seconds", "3"])
        self.assertTrue(args.no_native_inspection)
        self.assertEqual(args.settle_seconds, 3)
        for invalid in ("0", ".9", "5.1", "nan", "inf", "no"):
            with self.subTest(invalid=invalid), self.assertRaises(argparse.ArgumentTypeError):
                drawing.parse_settle_seconds(invalid)

    def test_snapshot_close_and_shutdown_cannot_advance_requested_frames(self):
        before = snapshot(frames=1)
        for command in ("snapshot", "close", "shutdown"):
            after = snapshot(frames=2, closed=command != "snapshot")
            with self.subTest(command=command), self.assertRaises(InvalidResult):
                drawing.validate_command_state(before, after, command)
        duplicate = dict(before, draw_calls=before["draw_calls"] + 1)
        drawing.validate_command_state(before, duplicate, "snapshot")
        with self.assertRaises(InvalidResult):
            drawing.validate_command_state(before, dict(before, draw_enabled=False), "snapshot")

    def test_all_backends_and_empty_control_validate(self):
        for backend in drawing.BACKENDS:
            for primitive in ("empty", "line"):
                case = backend + ":" + primitive
                before = snapshot(case)
                self.assertEqual(drawing.validate_snapshot(before, case), before)
                after = snapshot(case, frames=1)
                drawing.validate_snapshot(after, case, before)
                drawing.validate_draw_progress(before, after, 1, case)
                drawing.validate_snapshot(snapshot(case, frames=1, closed=True), case, after, closed=True)

    def test_missing_wrong_case_or_schema_rejected(self):
        for value in (None, {}, dict(snapshot(), schema_version=True), dict(snapshot(), backend="canvas"),
                      dict(snapshot(), primitive="empty")):
            with self.subTest(value=value), self.assertRaises(InvalidResult):
                drawing.validate_snapshot(value, "image-renderer:line")

    def test_visibility_must_be_native_exact_boolean(self):
        for value in (None, False, 1, "true"):
            with self.subTest(value=value), self.assertRaises(InvalidResult):
                drawing.validate_snapshot(dict(snapshot(), window_visible=value), "image-renderer:line")

    def test_geometry_window_identity_and_monotonic_counters(self):
        for field, value in (("content_width_points", 663), ("content_height_points", 358),
                             ("backing_scale", 1), ("window_number", 19), ("draw_calls", 0),
                             ("requested_frames", -1), ("acknowledged_revision", 0)):
            after = snapshot(frames=1)
            after[field] = value
            with self.subTest(field=field), self.assertRaises(InvalidResult):
                drawing.validate_snapshot(after, "image-renderer:line", snapshot())

    def test_missing_revision_proof_or_invalid_counter_types_rejected(self):
        for field in ("requested_frames", "revision", "acknowledged_revision", "acknowledged_frames"):
            for value in (None, True, -1):
                value_snapshot = snapshot(frames=1)
                value_snapshot[field] = value
                with self.subTest(field=field, value=value), self.assertRaises(InvalidResult):
                    drawing.validate_snapshot(value_snapshot, "image-renderer:line")

    def test_comparison_backend_cannot_create_renderer(self):
        for backend in ("canvas", "core-graphics"):
            value = snapshot(backend + ":line")
            value["graphics_diagnostics"] = graphics()
            with self.subTest(backend=backend), self.assertRaises(InvalidResult):
                drawing.validate_snapshot(value, backend + ":line")
        value = snapshot()
        value["graphics_diagnostics"] = graphics("canvas")
        with self.assertRaises(InvalidResult):
            drawing.validate_snapshot(value, "image-renderer:line")

    def test_closed_resources_and_disabled_drawing_required(self):
        for field in ("released_window_live", "released_host_live", "released_content_live", "draw_enabled", "window_visible"):
            value = snapshot(frames=101, closed=True)
            value[field] = True
            with self.subTest(field=field), self.assertRaises(InvalidResult):
                drawing.validate_snapshot(value, "image-renderer:line", closed=True)
        value = snapshot(frames=101, closed=True)
        value["graphics_diagnostics"] = graphics()
        with self.assertRaises(InvalidResult):
            drawing.validate_snapshot(value, "image-renderer:line", closed=True)

    def test_actual_hosting_and_bitmap_control_counters_are_required(self):
        for backend in drawing.BACKENDS:
            value = snapshot(backend + ":line")
            value["uses_swiftui_host"] = not value["uses_swiftui_host"]
            with self.subTest(backend=backend), self.assertRaises(InvalidResult):
                drawing.validate_snapshot(value, backend + ":line")
        for field in drawing.BITMAP_FIELDS:
            value = snapshot("core-graphics-unhosted:line")
            value[field] = 1
            with self.subTest(field=field), self.assertRaises(InvalidResult):
                drawing.validate_snapshot(value, "core-graphics-unhosted:line")

    def test_bitmap_storage_initial_bound_callbacks_and_release_are_verified(self):
        for frames, closed, field, wrong in (
                (0, False, "bitmap_images_created", 1),
                (0, False, "bitmap_peak_requested_image_bytes", 1),
                (1, False, "bitmap_update_layer_calls", 1),
                (1, False, "bitmap_unexpected_native_draw_calls", 1),
                (1, False, "bitmap_failures", 1),
                (1, False, "bitmap_images_created", 0),
                (1, False, "bitmap_current_requested_image_bytes", 0),
                (1, False, "bitmap_peak_requested_scratch_bytes", drawing.MAX_REQUESTED_BITMAP_BYTES + 1),
                (1, False, "bitmap_peak_requested_image_bytes", drawing.MAX_REQUESTED_BITMAP_BYTES + 1),
                (1, True, "bitmap_current_requested_image_bytes", 1),
                (1, True, "bitmap_current_requested_scratch_bytes", 1)):
            value = snapshot("bitmap-layer:line", frames=frames, closed=closed)
            value[field] = wrong
            with self.subTest(field=field, frames=frames, closed=closed), self.assertRaises(InvalidResult):
                drawing.validate_snapshot(value, "bitmap-layer:line", closed=closed)
    def test_draw_progress_requires_every_nonempty_frame(self):
        before, after = snapshot(frames=1), snapshot(frames=101)
        drawing.validate_draw_progress(before, after, 100, "image-renderer:line")
        for field, value in (("draw_enabled", False), ("requested_frames", 100),
                             ("draw_calls", 101), ("nonempty_draw_calls", 100)):
            with self.subTest(field=field), self.assertRaises(InvalidResult):
                drawing.validate_draw_progress(before, dict(after, **{field: value}), 100, "image-renderer:line")
        empty = snapshot("image-renderer:empty", frames=1)
        empty["nonempty_draw_calls"] = 1
        with self.assertRaises(InvalidResult):
            drawing.validate_snapshot(empty, "image-renderer:empty")

    def test_matrix_rejects_different_display_scale(self):
        cases = [{"checkpoints": [{"label": "ready", "snapshot": snapshot()}]} for _ in range(2)]
        drawing.validate_comparison_geometry(cases)
        cases[1]["checkpoints"][0]["snapshot"]["backing_scale"] = 1
        with self.assertRaises(InvalidResult):
            drawing.validate_comparison_geometry(cases)

    def test_boundary_requires_unique_sample_and_owned_identity(self):
        collector = mock.Mock(samples=[sample(1)])
        response = {"collector_control_after_seconds": 1}
        identity = {"process_id": 17, "birth_time_us": 123}
        self.assertEqual(drawing.boundary_sample(collector, response, identity), collector.samples[0])
        for samples in ([], [sample(2)], [sample(1), sample(1)], [dict(sample(1), process_id=99)],
                        [dict(sample(1), birth_time_us=999)]):
            collector.samples = samples
            with self.subTest(samples=samples), self.assertRaises(InvalidResult):
                drawing.boundary_sample(collector, response, identity)


class FinalEvidenceTests(unittest.TestCase):
    def test_final_memory_summary_preserves_first_maximum_and_final_samples(self):
        report = final_report()
        drawing.validate_final_evidence(report, {"process_id": 17, "birth_time_us": 123}, "image-renderer:line")
        self.assertEqual(report["memory_summary"]["baseline"], report["samples"][0])
        self.assertEqual(report["memory_summary"]["final"], report["samples"][-1])
        self.assertEqual(report["memory_summary"]["lifetime_peak_footprint_bytes"], 200)

    def test_missing_or_nonzero_exit_is_rejected(self):
        for mutation in (lambda r: r["events"].pop(), lambda r: r["events"][-1].update(status=1),
                         lambda r: r["events"][-1].update(status=False),
                         lambda r: r["events"][-1].update(final_sample={})):
            report = final_report()
            mutation(report)
            with self.assertRaises(InvalidResult):
                drawing.validate_final_evidence(report, {"process_id": 17, "birth_time_us": 123}, "image-renderer:line")

    def test_missing_or_regressing_stopped_snapshot_is_rejected(self):
        for mutation in (lambda r: r["events"].pop(0),
                         lambda r: r["events"][0]["event"].update(drawing_snapshot={}),
                         lambda r: r["events"][0]["event"]["drawing_snapshot"].update(draw_calls=1)):
            report = final_report()
            mutation(report)
            with self.assertRaises(InvalidResult):
                drawing.validate_final_evidence(report, {"process_id": 17, "birth_time_us": 123}, "image-renderer:line")

    def test_intermediate_pid_timestamp_or_peak_fault_is_rejected(self):
        for mutation in (lambda r: r["samples"][1].update(process_id=99),
                         lambda r: r["samples"][1].update(birth_time_us=456),
                         lambda r: r["samples"][1].update(monotonic_seconds=0),
                         lambda r: r["samples"][1].update(lifetime_peak_footprint_bytes=201)):
            report = final_report()
            mutation(report)
            with self.assertRaises(InvalidResult):
                drawing.validate_final_evidence(report, {"process_id": 17, "birth_time_us": 123}, "image-renderer:line")


class OrchestrationTests(unittest.TestCase):
    def test_deadline_reserves_cleanup(self):
        deadline = drawing.DrawingDeadline(clock=lambda: 100)
        self.assertEqual(deadline.end, 280)
        self.assertEqual(deadline.remaining(), 170)
        self.assertEqual(deadline.remaining(8), 8)
        deadline.clock = lambda: 271
        with self.assertRaises(TimeoutError):
            deadline.remaining()

    def test_case_configuration_uses_no_gpu_or_history_fixture(self):
        with tempfile.TemporaryDirectory() as directory:
            case = drawing.DrawingCase(Path(directory), drawing.DrawingDeadline(), "canvas:line")
            with mock.patch.object(drawing.app, "Collector", side_effect=InvalidResult("stop before launch")) as collector:
                with self.assertRaisesRegex(InvalidResult, "stop before launch"):
                    case.perform({"probe": Path("probe"), "collector": Path("collector")})
            config = collector.call_args.args[2]
            self.assertEqual(config, {"protocol_version": 1, "history": "fresh",
                                      "drawing_backend": "canvas", "drawing_primitive": "line"})
            self.assertEqual(collector.call_args.args[3], {})
            self.assertEqual(collector.call_args.args[-1], {"external_trace": True, "provenance": {}})

    def test_observer_free_stages_keep_both_kernel_checkpoints_without_native_tools(self):
        with tempfile.TemporaryDirectory() as directory:
            case = drawing.DrawingCase(Path(directory), drawing.DrawingDeadline(), "bitmap-layer:line",
                                       no_native_inspection=True, settle_seconds=3)
            with mock.patch.object(case, "checkpoint") as checkpoint, mock.patch.object(case, "inspect_tool") as inspect:
                case.inspect_stage("baseline", vmmap=True)
            inspect.assert_not_called()
            self.assertEqual(checkpoint.call_args_list, [mock.call("baseline-before-inspection", closed=False),
                                                        mock.call("baseline-after-inspection", closed=False)])
            self.assertEqual(case.report["probes"], [])
            self.assertFalse(case.report["native_inspection_enabled"])
            self.assertEqual(case.report["inspection_stages"][0]["status"], "skipped")

    def test_settling_records_requested_and_actual_wait_then_kernel_checkpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            case = drawing.DrawingCase(Path(directory), drawing.DrawingDeadline(), "core-graphics-unhosted:line",
                                       no_native_inspection=True, settle_seconds=3)
            case.collector = mock.Mock()
            with mock.patch.object(drawing.time, "monotonic", side_effect=[10, 13.25]), \
                    mock.patch.object(case, "checkpoint") as checkpoint:
                case.settle("post-redraw-idle")
            case.collector.wait_until.assert_called_once_with(13)
            checkpoint.assert_called_once_with("post-redraw-idle", closed=False)
            self.assertEqual(case.report["settling_waits"], [{"label": "post-redraw-idle", "requested_seconds": 3,
                "started_monotonic_seconds": 10, "ended_monotonic_seconds": 13.25,
                "elapsed_seconds": 3.25, "completed": True}])

    def test_failed_collector_cleanup_attempts_emergency_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            case = drawing.DrawingCase(Path(directory), drawing.DrawingDeadline(), "canvas:line")
            case.collector = mock.Mock(samples=[], events=[], storage={}, cleanup_errors=[])
            case.collector.close.side_effect = TimeoutError("blocked close")
            with mock.patch.object(case, "emergency_cleanup") as emergency:
                case.cleanup()
            emergency.assert_called_once_with()
            self.assertTrue(any("blocked close" in error for error in case.report["errors"]))

    def test_native_tool_authenticates_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            case = drawing.DrawingCase(Path(directory), drawing.DrawingDeadline(), "canvas:line")
            with mock.patch.object(case, "verify_identity", side_effect=InvalidResult("identity changed")), \
                    mock.patch.object(drawing.subprocess, "Popen") as process:
                with self.assertRaisesRegex(InvalidResult, "identity changed"):
                    case.inspect_tool("baseline", "footprint")
            process.assert_not_called()

    def test_invalid_native_report_is_preserved_and_marks_case_failed(self):
        with tempfile.TemporaryDirectory() as directory:
            case = drawing.DrawingCase(Path(directory), drawing.DrawingDeadline(), "canvas:line")
            case.identity = {"process_id": 17, "birth_time_us": 123}
            process = mock.Mock(returncode=0)
            process.poll.return_value = 0
            with mock.patch.object(case, "verify_identity") as verify, \
                    mock.patch.object(drawing.subprocess, "Popen", return_value=process), \
                    mock.patch.object(drawing.memory, "stop_owned_child"), \
                    mock.patch.object(drawing.memory, "parse_probe", side_effect=InvalidResult("invalid ledger")):
                case.inspect_tool("baseline", "footprint")
            self.assertEqual(verify.call_count, 2)
            self.assertFalse(case.report["probes"][0]["valid"])
            self.assertTrue(Path(directory, "baseline-footprint.txt").exists())
            self.assertIn("invalid ledger", case.report["errors"][0])

    def test_summary_marks_incomplete_cases_and_missing_native_values(self):
        report = {"caveat": "Diagnostic only", "errors": [], "cases": [{
            "case": "canvas:line", "status": "diagnostic_incomplete", "errors": ["invisible"], "probes": [],
            "checkpoints": [{"label": "ready", "resource_sample": sample(1)}]}]}
        text = drawing.summary_markdown(report)
        self.assertIn("NO — excluded", text)
        self.assertIn("unavailable", text)
        self.assertIn("invisible", text)

    def test_failed_summary_write_cannot_leave_completed_authoritative_report(self):
        with tempfile.TemporaryDirectory() as directory:
            report = {"status": "diagnostic_captured", "errors": []}
            with mock.patch.object(drawing, "summary_markdown", side_effect=ValueError("summary failed")), \
                    contextlib.redirect_stderr(io.StringIO()):
                drawing.finalize(Path(directory), report, drawing.DrawingDeadline())
            self.assertEqual(load_json(Path(directory) / "drawing-report.json")["status"], "diagnostic_incomplete")
            self.assertEqual(report["status"], "diagnostic_incomplete")

    def test_duplicate_cases_existing_output_and_tracked_output_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            base = ["--probe-binary", "missing", "--collector-binary", "missing", "--output-dir", directory]
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(drawing.run(base), 1)
                self.assertEqual(drawing.run(base + ["--case", "canvas:line", "--case", "canvas:line"]), 1)
                self.assertEqual(drawing.run([*base[:-1], str(drawing.app.ROOT / "drawing-should-not-exist")]), 1)

    def test_first_failed_case_stops_matrix_and_preserves_incomplete_report(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "result"
            def failure(case, _paths):
                raise InvalidResult("native window invisible")
            with mock.patch.object(drawing.sys, "platform", "darwin"), \
                    mock.patch.object(drawing, "validate_products", return_value={}), \
                    mock.patch.object(drawing, "source_provenance", return_value={}), \
                    mock.patch.object(drawing.DrawingCase, "perform", failure), \
                    contextlib.redirect_stdout(io.StringIO()):
                result = drawing.run(["--probe-binary", "probe", "--collector-binary", "collector", "--output-dir", str(output)])
            self.assertEqual(result, 1)
            report = load_json(output / "drawing-report.json")
            self.assertEqual(report["status"], "diagnostic_incomplete")
            self.assertEqual(len(report["cases"]), 1)
            self.assertIn("native window invisible", report["cases"][0]["errors"])


if __name__ == "__main__":
    unittest.main()
