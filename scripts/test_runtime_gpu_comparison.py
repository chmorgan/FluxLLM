"""Offline contracts for bounded GPU comparisons; never launch a native tool."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import Mock, patch

import runtime_gpu_comparison as gpu


def short_runtime_report():
    samples = []
    for index in range(61):
        timestamp = 99.5 + index / 4
        samples.append({
            "type": "sample", "phase": "periodic", "process_id": 123, "birth_time_us": 456,
            "monotonic_seconds": timestamp, "mach_absolute_seconds": timestamp + 900,
            "mach_absolute_ticks": int((timestamp + 900) * 1e9),
            "mach_timebase_numer": 1, "mach_timebase_denom": 1,
            "clock_read_uncertainty_seconds": .0000001, "cpu_seconds": timestamp * .02,
            "physical_footprint_bytes": 32_000_000, "lifetime_peak_footprint_bytes": 32_000_000,
            "physical_write_bytes": 0, "logical_write_bytes": 0,
            "interrupt_wakeups": index, "package_idle_wakeups": index,
        })
    samples[0]["phase"], samples[-1]["phase"] = "baseline", "final"
    by_time = {sample["monotonic_seconds"]: sample for sample in samples}

    def point(label, timestamp, active):
        sample = by_time[timestamp]
        return {"label": label, "python_monotonic_seconds": timestamp,
                "resource_sample": sample, "snapshot": {
                    "runner_collector_sample_monotonic_seconds": timestamp,
                    "dashboard_visible": True, "popover_visible": True,
                    "active_requests": active, "partial_output_tokens": 100 if active else 0}}

    def bridge(timestamp):
        return {"monotonic_seconds": timestamp, "mach_ticks": int((timestamp + 900) * 1e9),
                "numer": 1, "denom": 1, "absolute_minus_monotonic_seconds": 900,
                "uncertainty_seconds": .0000001}

    points = [point("before-traffic", 100, 0)]
    points += [point("during-traffic-" + str(index), 100 + index, 2) for index in range(1, 9)]
    points += [point("completion-begin", 108.25, 0), point("completion-1", 109.25, 0),
               point("completion-2", 110.25, 0), point("completion-end", 111.5, 0)]
    windows = {
        "arrival": {"start_monotonic_seconds": 100.1, "end_monotonic_seconds": 102.1},
        "steady": {"start_monotonic_seconds": 103.1, "end_monotonic_seconds": 107.1},
        "completion": {"start_monotonic_seconds": 108.12, "end_monotonic_seconds": 111.12},
        "whole_contiguous_runtime": {"start_monotonic_seconds": 100, "end_monotonic_seconds": 111.5},
    }
    return {"errors": [], "owned_identity": {"process_id": 123, "birth_time_us": 456},
            "samples": samples, "events": [{"type": "exited", "status": 0, "final_sample": samples[-1]}],
            "runtime": {"profiled": True, "checkpoints": points,
                        "mach_clock_start": bridge(99.5), "mach_clock_end": bridge(114.5)},
            "workload": {"fixture_status": {"timing": {"streams": [
                {"first_write_started_monotonic_seconds": 100.1, "terminal_write_started_monotonic_seconds": 108.1,
                 "terminal_flush_finished_monotonic_seconds": 108.105},
                {"first_write_started_monotonic_seconds": 100.12, "terminal_write_started_monotonic_seconds": 108.12,
                 "terminal_flush_finished_monotonic_seconds": 108.125},
            ]}}}, "phase_windows": windows}


def qualified_comparison():
    rows, windows, exits = [], {}, {}
    for label in ("reference", "candidate"):
        rows.append({"label": label, "workload_window_name": label + "/workload",
                     "lifetime_window_name": label + "/lifetime"})
        for suffix in ("workload", "lifetime"):
            name = label + "/" + suffix
            windows[name] = {"coverage_complete": True, "attribution_exact": True,
                             "gpu_percent": .1, "gpu_rolling_1s_percent": .5}
            exits[name] = {"complete": True}
    return {"errors": [], "rows": rows, "regression_passed": False, "cpu_acceptance_eligible": True,
            "gpu_trace": {"valid": True, "recording_complete": True, "lost_events": False,
                          "calibration": {"valid": True}, "capture_scope": {"validated": True},
                          "windows": windows, "final_exit_coverage": exits}}


class ShortGPUWorkloadTests(unittest.TestCase):
    def test_fixed_workload_is_two_eight_second_200_hz_streams(self):
        self.assertEqual(gpu.STAGE, {"activity": "high-rate", "seconds": 8})
        self.assertEqual(gpu.WORK, {"chunks": 3200, "output_tokens": 6434, "prompt_tokens": 46,
                                    "requests": 2, "tool_calls": 2, "tool_results": 2})
        self.assertEqual(gpu.app.expected_work(gpu.STAGE), gpu.WORK)
        self.assertEqual(gpu.MAX_SECONDS, 300)
        self.assertEqual(gpu.PHASE_SECONDS, {"record": 80, "finalize": 190, "toc": 200,
                                           "export": 255, "evaluate": 290})

    def test_phases_follow_source_writes_and_latest_completion_with_owned_boundaries(self):
        report = short_runtime_report()
        result = gpu.phase_windows(report)
        self.assertEqual(result, report["phase_windows"])
        self.assertEqual(result["completion"]["start_monotonic_seconds"], 108.12)
        self.assertEqual(result["steady"]["end_monotonic_seconds"]
                         - result["steady"]["start_monotonic_seconds"], 4)

    def test_hidden_windows_wrong_identity_or_missing_boundaries_are_rejected(self):
        for fault in ("hidden-dashboard", "hidden-popover", "pid", "birth", "missing-sample", "duplicate-sample",
                      "start-label", "end-label", "coverage-gap"):
            report = short_runtime_report()
            point = report["runtime"]["checkpoints"][4]
            if fault.startswith("hidden-"):
                point["snapshot"][fault.removeprefix("hidden-") + "_visible"] = False
            elif fault in ("pid", "birth"):
                point["resource_sample"]["process_id" if fault == "pid" else "birth_time_us"] += 1
            elif fault == "missing-sample":
                report["samples"].remove(point["resource_sample"])
            elif fault == "duplicate-sample":
                report["samples"].append(copy.deepcopy(point["resource_sample"]))
            elif fault == "start-label":
                report["runtime"]["checkpoints"][0]["label"] = "missing-start"
            elif fault == "end-label":
                report["runtime"]["checkpoints"][-1]["label"] = "missing-end"
            else:
                del report["runtime"]["checkpoints"][2:5]
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                gpu.phase_windows(report)


class GPUVisualIdentityTests(unittest.TestCase):
    def report(self):
        def snapshot(indices):
            return {"synthetic_animation_policy": "fixture-index-and-fixed-twinkle-seed-v1",
                    "synthetic_request_identity": {"policy": "fixture-index-v1", "invalid_requests": 0,
                        "requests": [{"index": index, "id": str(uuid.UUID(bytes=bytes(
                            [0x52, 0x45, 0x53, 0x46, 0, 0, 0, 7]) + index.to_bytes(8, "big"))).upper()}
                            for index in indices]}}
        initial, first, completed = snapshot(()), snapshot(gpu.REQUEST_INDICES[:1]), snapshot(gpu.REQUEST_INDICES)
        return {"ready": {"snapshot": copy.deepcopy(initial)},
                "workload": {"before": copy.deepcopy(initial), "after": copy.deepcopy(completed),
                    "fixture_start": {"expected_request_indices": list(gpu.REQUEST_INDICES)},
                    "fixture_status": {"timing": {"streams": [{"request_index": index} for index in gpu.REQUEST_INDICES]}}},
                "runtime": {"checkpoints": [{"snapshot": initial}, {"snapshot": first}, {"snapshot": completed}]},
                "checkpoints": [{"label": "visible-idle", "snapshot": copy.deepcopy(initial)},
                                {"label": "closed-start", "snapshot": copy.deepcopy(completed)},
                                {"label": "closed-end", "snapshot": copy.deepcopy(completed)}],
                "events": [{"type": "app_event", "event": {"snapshot": copy.deepcopy(completed)}}]}

    def test_visual_contract_binds_exact_cycle_and_preserves_closed_identities(self):
        result = gpu.validate_visual_identity(self.report())
        self.assertEqual(gpu.REQUEST_INDICES, (480000, 480001))
        self.assertEqual(result["fixture_cycle"], 15000)
        self.assertTrue(result["visual_comparison_eligible"])
        self.assertEqual([row["index"] for row in result["requests"]], [480000, 480001])
        self.assertIn("runtime_attribution.py", gpu.source_identity())

    def test_altered_identity_animation_policy_or_lifecycle_is_rejected(self):
        for fault in ("uuid", "animation", "event-animation", "before", "closed", "indices", "invalid"):
            report = self.report()
            if fault == "uuid":
                report["runtime"]["checkpoints"][1]["snapshot"]["synthetic_request_identity"]["requests"][0]["id"] = "changed"
            elif fault == "animation":
                report["checkpoints"][1]["snapshot"]["synthetic_animation_policy"] = "random"
            elif fault == "event-animation":
                report["events"][0]["event"]["snapshot"]["synthetic_animation_policy"] = "random"
            elif fault == "before":
                report["runtime"]["checkpoints"][0]["snapshot"] = copy.deepcopy(report["workload"]["after"])
            elif fault == "closed":
                report["checkpoints"][-1]["snapshot"]["synthetic_request_identity"]["requests"][0]["id"] = "changed"
            elif fault == "indices":
                report["workload"]["fixture_start"]["expected_request_indices"] = [15000, 15001]
            else:
                report["ready"]["snapshot"]["synthetic_request_identity"]["invalid_requests"] = 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                gpu.validate_visual_identity(report)


class GPUArrivalFidelityTests(unittest.TestCase):
    def report(self, late=False):
        def point(label, timestamp, ticks, frames, active=0, visible=True):
            return {"label": label, "time": timestamp, "snapshot": {
                "active_requests": active, "dashboard_visible": visible, "popover_visible": visible,
                "rail_frame_clock_ticks": ticks, "rail_timeline_content_updates": 0,
                "metal_arrival_frames": frames, "metal_arrival_submissions": frames, "metal_arrival_failures": 0,
                "graphics_diagnostics": {"roles": {"rail_decorations": {"draws": ticks}}}}}
        early_frames = 0 if late else 5
        return {"runtime_work": {"features": {"canvas_frame_clock": True}},
            "phase_windows": {"steady": {"start_monotonic_seconds": 3, "end_monotonic_seconds": 7}},
            "runtime": {"checkpoints": [point("before-traffic", 0, 0, 0),
                point("steady-1", 4, 10, early_frames, 2), point("steady-2", 6, 10, early_frames, 2),
                point("completion-begin", 8.1, 10, early_frames), point("completion-end", 11.2, 20, 5)]},
            "checkpoints": [point("closed-start", 12.5, 20, 5, visible=False),
                            point("closed-end", 14.6, 20, 5, visible=False)]}

    def test_metal_arrivals_must_execute_before_steady_even_if_completion_has_positive_frames(self):
        with patch.object(gpu, "snapshot_time", side_effect=lambda report, point: point["time"]):
            result = gpu.validate_short_clock_work(self.report(), gpu.memory.METAL_ARRIVAL_MODE)
            self.assertEqual(result["steady_deltas"]["metal_arrival_frames"], 0)
            with self.assertRaisesRegex(ValueError, "before steady traffic"):
                gpu.validate_short_clock_work(self.report(late=True), gpu.memory.METAL_ARRIVAL_MODE)

    def test_imprecise_or_drifting_bridges_and_incomplete_stream_windows_are_rejected(self):
        for fault in ("uncertainty", "drift", "one-stream", "short-stream", "late-terminal", "early-start"):
            report = short_runtime_report()
            streams = report["workload"]["fixture_status"]["timing"]["streams"]
            if fault == "uncertainty":
                report["runtime"]["mach_clock_start"]["uncertainty_seconds"] = .000002
            elif fault == "drift":
                report["runtime"]["mach_clock_end"]["absolute_minus_monotonic_seconds"] += .000002
            elif fault == "one-stream":
                streams.pop()
            elif fault == "short-stream":
                for stream in streams:
                    stream["terminal_write_started_monotonic_seconds"] = 107
            elif fault == "late-terminal":
                streams[-1]["terminal_write_started_monotonic_seconds"] = 109
            else:
                streams[0]["first_write_started_monotonic_seconds"] = 99
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                gpu.phase_windows(report)


class GPUWindowRegistrationTests(unittest.TestCase):
    def trace(self):
        return SimpleNamespace(ready_monotonic=99,
            monotonic_from_mach_seconds=lambda value: value - 900,
            register_process=Mock(), register_exit=Mock(), add_window=Mock())

    def test_registration_preserves_lifetime_and_runtime_as_distinct_owned_windows(self):
        trace, report = self.trace(), short_runtime_report()
        result = gpu.register_report(trace, report, "reference", 115)
        trace.register_process.assert_called_once_with(123, 456, 99.5)
        trace.register_exit.assert_called_once_with(123, 456, 114.5, 115, 0)
        self.assertEqual(trace.add_window.call_args_list[0].args, ("reference/lifetime", 123, 456, 99.5, 114.5))
        self.assertEqual(trace.add_window.call_args_list[1].args, ("reference/workload", 123, 456, 100, 111.5))
        self.assertEqual(result["workload_window_name"], "reference/workload")
        self.assertEqual(result["lifetime_window_name"], "reference/lifetime")
        self.assertEqual((result["process_id"], result["birth_time_us"]), (123, 456))

    def test_registration_rejects_unowned_unbracketed_or_unreconciled_clock_evidence(self):
        for fault in ("pid", "birth", "uncertainty", "recording-ready", "driver-exit", "changed-phase"):
            trace, report, exited = self.trace(), short_runtime_report(), 115
            if fault in ("pid", "birth"):
                report["samples"][2]["process_id" if fault == "pid" else "birth_time_us"] += 1
            elif fault == "uncertainty":
                report["samples"][0]["clock_read_uncertainty_seconds"] = .002
            elif fault == "recording-ready":
                trace.ready_monotonic = 100
            elif fault == "driver-exit":
                exited = 114
            else:
                report["phase_windows"]["whole_contiguous_runtime"]["end_monotonic_seconds"] -= 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                gpu.register_report(trace, report, "reference", exited)


class GPUQualificationTests(unittest.TestCase):
    def test_single_product_gpu_is_available_without_claiming_a_paired_comparison(self):
        for label in ("reference", "candidate"):
            result = qualified_comparison()
            result["capture_case"] = label
            result["rows"] = [row for row in result["rows"] if row["label"] == label]
            with self.subTest(label=label):
                gpu.qualify_result(result)
                self.assertTrue(result["capture_available"])
                self.assertEqual(result["status"], "gpu_capture_complete")
                self.assertFalse(result["comparison_available"])
                self.assertFalse(result["cpu_acceptance_eligible"])
                self.assertTrue(result["rows"][0]["gpu_target"]["runtime"]["evaluated"])
                self.assertFalse(result["regression_passed"])

    def test_single_product_missing_extra_wrong_or_duplicate_rows_are_rejected(self):
        for selected in ("reference", "candidate"):
            for fault in ("missing", "wrong", "extra", "duplicate", "missing-exit", "uncalibrated"):
                result = qualified_comparison()
                result["capture_case"] = selected
                chosen = next(row for row in result["rows"] if row["label"] == selected)
                other = next(row for row in result["rows"] if row["label"] != selected)
                result["rows"] = {"missing": [], "wrong": [other], "extra": [chosen, other],
                                  "duplicate": [chosen, copy.deepcopy(chosen)]}.get(fault, [chosen])
                if fault == "missing-exit":
                    result["gpu_trace"]["final_exit_coverage"][selected + "/lifetime"]["complete"] = False
                elif fault == "uncalibrated":
                    result["gpu_trace"]["calibration"]["valid"] = False
                with self.subTest(selected=selected, fault=fault):
                    gpu.qualify_result(result)
                    self.assertFalse(result["capture_available"])
                    self.assertFalse(result["comparison_available"])
                    self.assertEqual(result["status"], "gpu_capture_incomplete")
                    self.assertTrue(result["errors"])

    def test_complete_calibrated_pair_is_comparable_but_never_cpu_acceptance(self):
        result = qualified_comparison()
        gpu.qualify_result(result)
        self.assertTrue(result["comparison_available"])
        self.assertFalse(result["cpu_acceptance_eligible"])
        self.assertFalse(result["regression_passed"])
        for row in result["rows"]:
            self.assertTrue(row["gpu_window_available"])
            self.assertTrue(row["gpu_lifetime_available"])
            self.assertTrue(row["gpu_target"]["runtime"]["evaluated"])
            self.assertTrue(row["gpu_target"]["runtime"]["within_limit"])

    def test_absent_invalid_lost_or_uncalibrated_provider_never_fabricates_zero_gpu(self):
        for fault in ("missing", "invalid", "incomplete", "lost-events", "calibration", "scope"):
            result = qualified_comparison()
            provider = result["gpu_trace"]
            if fault == "missing":
                del result["gpu_trace"]
            elif fault == "invalid":
                provider["valid"] = False
            elif fault == "incomplete":
                provider["recording_complete"] = False
            elif fault == "lost-events":
                provider["lost_events"] = True
            elif fault == "calibration":
                provider["calibration"]["valid"] = False
            else:
                provider["capture_scope"]["validated"] = False
            with self.subTest(fault=fault):
                gpu.qualify_result(result)
                self.assertFalse(result["comparison_available"])
                self.assertFalse(result["cpu_acceptance_eligible"])
                for row in result["rows"]:
                    self.assertFalse(row["gpu_window_available"])
                    self.assertFalse(row["gpu_target"]["runtime"]["evaluated"])
                    self.assertIsNone(row["gpu_target"]["runtime"]["within_limit"])

    def test_missing_window_exit_or_lifetime_coverage_disqualifies_the_comparison(self):
        for fault in ("missing-window", "workload-coverage", "lifetime-coverage", "workload-exit", "lifetime-exit", "error", "missing-case"):
            result = qualified_comparison()
            provider = result["gpu_trace"]
            if fault == "missing-window":
                del provider["windows"]["candidate/workload"]
            elif fault in ("workload-coverage", "lifetime-coverage"):
                suffix = fault.removesuffix("-coverage")
                provider["windows"]["candidate/" + suffix]["coverage_complete"] = False
            elif fault in ("workload-exit", "lifetime-exit"):
                suffix = fault.removesuffix("-exit")
                provider["final_exit_coverage"]["candidate/" + suffix]["complete"] = False
            elif fault == "error":
                result["errors"].append("Source identity changed")
            else:
                result["rows"].pop()
            with self.subTest(fault=fault):
                gpu.qualify_result(result)
                self.assertFalse(result["comparison_available"])
                self.assertFalse(result["cpu_acceptance_eligible"])

    def test_valid_above_budget_gpu_remains_measured_and_reports_a_failed_target(self):
        result = qualified_comparison()
        result["gpu_trace"]["windows"]["candidate/workload"]["gpu_rolling_1s_percent"] = 1.01
        gpu.qualify_result(result)
        self.assertTrue(result["comparison_available"])
        self.assertTrue(result["rows"][1]["gpu_target"]["runtime"]["evaluated"])
        self.assertFalse(result["rows"][1]["gpu_target"]["runtime"]["within_limit"])
        self.assertFalse(result["cpu_acceptance_eligible"])

    def test_interval_attribution_uses_conservative_upper_bound_for_target(self):
        for upper, within in ((.9, True), (1.01, False)):
            result = qualified_comparison()
            window = result["gpu_trace"]["windows"]["candidate/workload"]
            window.update(attribution_exact=False, gpu_rolling_1s_percent_lower_bound=.4,
                          gpu_rolling_1s_percent_upper_bound=upper)
            with self.subTest(upper=upper):
                gpu.qualify_result(result)
                self.assertTrue(result["comparison_available"])
                self.assertEqual(result["rows"][1]["gpu_target"]["runtime"]["within_limit"], within)


class GPUCaptureCleanupTests(unittest.TestCase):
    def test_capture_and_cleanup_failures_preserve_evidence_and_revoke_all_cpu_acceptance(self):
        for failure in ("perform", "cleanup", "both"):
            report = {"errors": [], "runtime": {"profiled": False, "cpu_comparison_available": True},
                "cpu_gate_evaluated": True, "cpu_acceptance_eligible": True, "phase_cpu_comparison_available": True,
                "workload_cpu": {"available": True, "acceptance_eligible": True, "within_limit": True},
                "runtime_cpu_target": {"evaluated": True, "within_limit": True},
                "phase_cpu": {"whole_contiguous_runtime": {"acceptance_eligible": True}}}
            diagnostic = SimpleNamespace(report=report, collector=None,
                perform=Mock(side_effect=ValueError("scripted capture failure") if failure in ("perform", "both") else None),
                cleanup=Mock(side_effect=ValueError("scripted cleanup failure") if failure in ("cleanup", "both") else None))
            deadline = SimpleNamespace(end=1000, cleanup_reserve=8, interrupt_at=lambda end: contextlib.nullcontext())
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory, \
                    patch.object(gpu, "ShortGPUDiagnostic", return_value=diagnostic):
                output = Path(directory) / "case"
                result = gpu.capture_case(output, "normal", {}, {}, {}, deadline)
                diagnostic.perform.assert_called_once()
                diagnostic.cleanup.assert_called_once()
                self.assertEqual(result["status"], "diagnostic_incomplete")
                self.assertFalse(result["cpu_gate_evaluated"])
                self.assertFalse(result["cpu_acceptance_eligible"])
                self.assertFalse(result["phase_cpu_comparison_available"])
                self.assertFalse(result["runtime"]["cpu_comparison_available"])
                self.assertFalse(result["runtime_cpu_target"]["evaluated"])
                self.assertIsNone(result["runtime_cpu_target"]["within_limit"])
                self.assertFalse(result["workload_cpu"]["available"])
                self.assertFalse(result["gpu_perturbed_kernel_cpu"]["acceptance_eligible"])
                self.assertFalse(result["phase_cpu"]["whole_contiguous_runtime"]["acceptance_eligible"])
                self.assertEqual(json.loads((output / "runtime-case.json").read_text()), result)
                self.assertEqual(json.loads((output / "in-progress.json").read_text()), result)
                self.assertTrue(any("scripted" in error for error in result["errors"]))


class GPUProductBindingTests(unittest.TestCase):
    def products(self, root):
        root = root.resolve()
        directory, output = root / "products", root / "capture"
        directory.mkdir()
        output.mkdir()
        paths = {"app": directory / "FluxLLMApp", "tests": directory / "FluxLLMPackageTests.xctest",
                 "collector": directory / "FluxLLMResourceCollector"}
        for label, path in paths.items():
            path.write_text("frozen " + label)
        raw = {"instrumentation_sha256": "original-measurement",
               "common_collector": {"sha256": gpu.app.path_hash(paths["collector"])}}
        original = directory / "provenance.json"
        original.write_text(json.dumps(raw, indent=2) + "\n")
        return directory, output, paths, original

    def test_stale_measurement_requires_explicit_binding_without_changing_originals(self):
        with tempfile.TemporaryDirectory() as directory:
            products, output, paths, original = self.products(Path(directory))
            saved = {path: path.read_bytes() for path in [original, *paths.values()]}
            with patch.object(gpu.app, "measurement_identity", return_value={"sha256": "current-measurement"}), \
                    patch.object(gpu.app, "validated_provenance") as validate_original, \
                    patch.object(gpu.memory, "validate_products") as validate_bound:
                with self.assertRaisesRegex(ValueError, "rebind-measurement"):
                    gpu.load_products(products, output, "reference")
            validate_original.assert_not_called()
            validate_bound.assert_not_called()
            self.assertEqual(list(output.iterdir()), [])
            self.assertEqual({path: path.read_bytes() for path in saved}, saved)


    def test_explicit_binding_validates_original_then_pins_derived_provenance_and_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            products, output, paths, original = self.products(Path(directory))
            saved = {path: path.read_bytes() for path in [original, *paths.values()]}
            original_hash = gpu.app.path_hash(original)
            identity = {"sha256": "current-measurement"}
            sources = {"runtime_gpu_comparison.py": "current-driver"}
            validated_paths = []

            def validate(args):
                validated_paths.append(args.provenance)
                bound = json.loads(args.provenance.read_text())
                bound["provenance_file"] = str(args.provenance)
                return paths, bound, identity

            with patch.object(gpu.app, "measurement_identity", return_value=identity), \
                    patch.object(gpu, "source_identity", return_value=sources), \
                    patch.object(gpu.app, "validated_provenance") as validate_original, \
                    patch.object(gpu.memory, "validate_products", side_effect=validate):
                result = gpu.load_products(products, output, "reference", rebind_measurement=True)
            validate_original.assert_called_once_with(original, paths, "check", "original-measurement")
            bound_path = output / "reference-measurement-provenance.json"
            self.assertEqual(validated_paths, [bound_path])
            bound = json.loads(bound_path.read_text())
            self.assertEqual(bound["instrumentation_sha256"], identity["sha256"])
            self.assertEqual(bound["original_provenance_file"], str(original))
            self.assertEqual(bound["original_provenance_sha256"], original_hash)
            self.assertEqual(bound["external_measurement_binding"], {
                "kind": "short-gpu-comparison", "original_instrumentation_sha256": "original-measurement",
                "measurement_identity": identity, "runtime_source_identity": sources,
                "production_products_rebuilt": False})
            self.assertEqual(result["files"]["original_provenance_file"]["sha256"], original_hash)
            self.assertEqual(result["files"]["provenance_file"]["sha256"], gpu.app.path_hash(bound_path))
            self.assertEqual({path: path.read_bytes() for path in saved}, saved)


class GPUProductModeRoutingTests(unittest.TestCase):
    def run_modes(self, options):
        seen = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            products = {}
            for label in ("reference", "candidate"):
                folder = root / label
                folder.mkdir()
                paths = {name: folder / name for name in ("app", "tests", "collector")}
                for name, path in paths.items():
                    path.write_text("common collector" if name == "collector" else label + " " + name)
                provenance = {"fixture_equivalence_sha256": {"populated": "same-populated-fixture"}}
                products[label] = {"paths": paths, "provenance": provenance, "identity": {"sha256": "common-measurement"},
                                   "files": gpu.product_identity(paths, provenance)}

            def capture(output, mode, paths, provenance, identity, deadline):
                label = paths["app"].parent.name
                seen.append((label, mode))
                result = {"status": "diagnostic_captured", "errors": [], "workload": {"validated_work": gpu.WORK},
                          "visual_work": {"visual_comparison_eligible": True, "requests": [{"index": 480000}]},
                          "runtime_work": {"features": {}, "deltas": {}}}
                output.mkdir()
                gpu.write_json(output / "runtime-case.json", result)
                return result

            def register(trace, case, label, ended):
                return {"workload_window_name": label + "/workload", "lifetime_window_name": label + "/lifetime"}

            trace = SimpleNamespace(invalid=[], start=Mock(return_value={}), calibrate=Mock(return_value={}),
                                    finish=Mock(return_value=qualified_comparison()["gpu_trace"]))
            output = root / "output"
            arguments = ["--reference-products", str(root / "reference"), "--candidate-products", str(root / "candidate"),
                         "--output-dir", str(output), *options]
            with patch.object(gpu.sys, "platform", "darwin"), \
                    patch.object(gpu, "source_identity", return_value={}), \
                    patch.object(gpu, "load_products", side_effect=lambda directory, output, label, **kwargs: products[label]), \
                    patch.object(gpu, "TraceSession", return_value=trace), \
                    patch.object(gpu, "capture_case", side_effect=capture), \
                    patch.object(gpu, "register_report", side_effect=register), contextlib.redirect_stdout(io.StringIO()):
                code = gpu.run(arguments)
            report = json.loads((output / "gpu-comparison.json").read_text())
            trace.start.assert_called_once()
            trace.finish.assert_called_once()
        return code, report, seen

    def test_default_and_explicit_per_product_modes_reach_the_selected_frozen_apps(self):
        cases = (([], ["normal", "normal"]),
                 (["--graphics-mode", "runtime-metal-arrival-bursts"], ["runtime-metal-arrival-bursts"] * 2),
                 (["--graphics-mode", "runtime-metal-arrival-bursts", "--reference-mode", "normal",
                   "--candidate-mode", "runtime-metal-full-chart"], ["normal", "runtime-metal-full-chart"]))
        for arguments, modes in cases:
            with self.subTest(arguments=arguments):
                code, report, seen = self.run_modes(arguments)
                self.assertEqual(code, 0)
                self.assertEqual(seen, list(zip(("reference", "candidate"), modes)))
                self.assertEqual([row["mode"] for row in report["rows"]], modes)
                self.assertTrue(report["comparison_available"])
                self.assertFalse(report["cpu_acceptance_eligible"])
                self.assertFalse(report["regression_passed"])

    def test_single_case_selection_launches_only_selected_product_with_same_workload_and_limits(self):
        for selected, mode in (("reference", "normal"), ("candidate", "runtime-metal-full-chart")):
            with self.subTest(selected=selected):
                code, report, seen = self.run_modes(["--capture-case", selected,
                    "--reference-mode", "normal", "--candidate-mode", "runtime-metal-full-chart"])
                self.assertEqual(code, 0)
                self.assertEqual(seen, [(selected, mode)])
                self.assertEqual(report["capture_case"], selected)
                self.assertEqual(report["kind"], "short-independent-process-gpu-capture")
                self.assertEqual(report["status"], "gpu_capture_complete")
                self.assertTrue(report["capture_available"])
                self.assertFalse(report["comparison_available"])
                self.assertFalse(report["cpu_acceptance_eligible"])
                self.assertFalse(report["regression_passed"])
                self.assertEqual(report["deadline_seconds"], 300)
                self.assertEqual(report["workload_specification"], {"activity": "high-rate", "seconds": 8})
                self.assertEqual(report["expected_work"], gpu.WORK)
                self.assertEqual(set(report["products"]), {"reference", "candidate"})
                self.assertEqual([row["label"] for row in report["attempts"]], [selected])


if __name__ == "__main__":
    unittest.main()
