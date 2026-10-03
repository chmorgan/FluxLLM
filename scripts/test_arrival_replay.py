"""Offline contracts for repeated arrival diagnostics; never launch native tools."""
import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

import arrival_replay as replay
from performance_fixture import StreamTiming, TIMING_POLICY
from test_app_performance import cpu_events
from test_memory_diagnostic import drawn_native_gpu_graphics


METRICS = (
    "profile_preparation", "profile_create", "metal_elements", "metal_descriptor_update",
    "metal_descriptor_upload", "metal_surface_setup", "metal_first_drawable",
    "metal_later_drawable", "metal_frame_callback", "metal_frame_encode", "metal_frame_submit",
    "metal_completion_callback", "metal_completion_main_actor", "metal_clear", "canvas_arrival_draw",
)
FIELDS = ("calls", "cpu_ns", "wall_ns", "max_cpu_ns", "max_wall_ns", "clock_failures", "rejected_tokens")
UINT64_MAX = (1 << 64) - 1
INDICES = (480000, 480001, 480032, 480033, 480064, 480065)


def timing_snapshot(timed=True):
    return {"arrival_diagnostics": {
        "schema_version": 1, "enabled": timed, "measurement_thread_cpu": True,
        "cpu_clock": "CLOCK_THREAD_CPUTIME_ID", "wall_clock": "monotonic_uptime",
        "metrics": {name: dict.fromkeys(FIELDS, 0) for name in METRICS},
    }}


def request_id(index):
    return str(uuid.UUID(bytes=bytes.fromhex("5245534600000007") + index.to_bytes(8, "big"))).upper()


def identity_snapshot(indices=()):
    return {"synthetic_request_identity": {
        "policy": "fixture-index-v1", "invalid_requests": 0,
        "requests": [{"index": index, "id": request_id(index)} for index in indices],
    }, "synthetic_animation_policy": "fixture-index-and-fixed-twinkle-seed-v1"}


def replay_report(mode="normal", timed=False):
    """Three disjoint episodes, real fixture timing validation, paired kernel clocks."""
    snapshot = drawn_native_gpu_graphics(replay.memory.METAL_ARRIVAL_MODE)
    snapshot["graphics_diagnostics"].update(mode=mode, metal_arrival_bursts_enabled=mode != "normal",
                                            arrival_backend="canvas" if mode == "normal" else "metal-shader")
    snapshot.update(dict.fromkeys(replay.runtime.COUNTERS + replay.memory.METAL_ARRIVAL_COUNTERS, 0))
    snapshot.update(requests=0, output_tokens=0, prompt_tokens=0, tool_calls=0, tool_results=0,
                    active_requests=0, partial_output_tokens=0, dashboard_visible=True, popover_visible=True,
                    rail_frame_clock_ticks=0)
    snapshot["graphics_diagnostics"]["retained_twinkles"].update(instances_destroyed=2, live_instances=0)
    snapshot.update(timing_snapshot(timed))
    snapshot.update(identity_snapshot())
    samples = [{"type": "sample", "phase": "periodic", "process_id": 123, "birth_time_us": 456,
                "monotonic_seconds": 97 + index / 4, "mach_absolute_seconds": 997 + index / 4,
                "mach_absolute_ticks": 997_000_000_000 + index * 250_000_000,
                "mach_timebase_numer": 1, "mach_timebase_denom": 1,
                "clock_read_uncertainty_seconds": 0.000001, "cpu_seconds": (97 + index / 4) * .02,
                "physical_footprint_bytes": 32_000_000, "lifetime_peak_footprint_bytes": 32_000_000,
                "physical_write_bytes": 0, "logical_write_bytes": 0, "interrupt_wakeups": index,
                "package_idle_wakeups": index} for index in range(155)]
    samples[0]["phase"], samples[-1]["phase"] = "baseline", "final"
    samples[1].update(phase="control_boundary", command_id="collector-handshake")
    by_time = {sample["monotonic_seconds"]: sample for sample in samples}
    bridge = lambda ts: {"monotonic_seconds": ts, "mach_ticks": int((ts + 900) * 1e9),
                         "numer": 1, "denom": 1, "absolute_minus_monotonic_seconds": 900,
                         "uncertainty_seconds": .000001}
    report = {"errors": [], "episodes": [], "owned_identity": {"process_id": 123, "birth_time_us": 456},
              "memory_validation": {"problems": []}, "ready": {"snapshot": copy.deepcopy(snapshot)},
              "runtime": {"profiled": timed, "checkpoints": [],
                          "mach_clock_start": bridge(97), "mach_clock_end": bridge(135.5)},
              "samples": samples, "events": [{"type": "exited", "status": 0, "final_sample": samples[-1]}],
              "checkpoints": []}

    def record(label, timestamp, tracking=True):
        saved = copy.deepcopy(snapshot)
        saved["runner_collector_sample_monotonic_seconds"] = timestamp
        by_time[timestamp]["phase"] = "control_boundary"
        point = {"label": label, "snapshot": saved, "resource_sample": by_time[timestamp]}
        if tracking:
            report["runtime"]["checkpoints"].append(point)
        report["checkpoints"].append(point)
        return saved

    def drawn_work(arrival):
        for field in ("chart_preparations", "optimized_chart_preparations", "ordered_chart_publication_queries",
                      "legacy_tool_plot_builds", "history_tool_order_insertions", "history_completed_order_insertions"):
            snapshot[field] += 2
        snapshot["tool_path_input_points"] += 100
        snapshot["tool_path_output_points"] += 100
        snapshot["streamed_bodies_without_promises"] += 1001
        graphics = snapshot["graphics_diagnostics"]
        graphics["roles"]["static_chart"]["draws"] += 2
        if arrival and mode != "normal":
            snapshot["metal_arrival_frames"] += 20
            snapshot["metal_arrival_submissions"] += 20
        else:
            snapshot["rail_frame_clock_ticks"] += 20
            role = graphics["roles"]["rail_decorations"]
            role.update(created=role["created"] + 1, destroyed=role["destroyed"] + 1, peak_live=1)
            role["draws"] += 20
            graphics["peak_live_canvases"] = 2
        snapshot["grouped_native_canvas_draws"] = graphics["native_gpu_canvas_draws"] = sum(
            role["draws"] for role in graphics["roles"].values())
        if timed:
            for name in METRICS:
                if name == "canvas_arrival_draw":
                    continue
                row = snapshot["arrival_diagnostics"]["metrics"][name]
                row.update(calls=row["calls"] + 1, cpu_ns=row["cpu_ns"] + 1000,
                           wall_ns=row["wall_ns"] + 2000, max_cpu_ns=1000, max_wall_ns=2000)

    record("initial-quiet-start", 98)
    record("initial-quiet-end", 99.25)
    for ordinal, cycle in enumerate((15000, 15001, 15002), 1):
        start = 100 + (ordinal - 1) * 11
        indices = [cycle * 32, cycle * 32 + 1]
        before = record(f"episode-{ordinal}-before", start)
        ack = {"running": True, "run_id": f"episode-{ordinal}", "expected_requests": 2,
               "expected_chunks": 2000, "expected_output_tokens": 4034, "expected_prompt_tokens": 46,
               "expected_request_indices": indices}
        streams = []
        for index in indices:
            timing = StreamTiming(index, 1000, 200, 5, start + .1)
            for chunk in range(1001):
                sent = start + .1 + chunk / 200
                timing.observed(chunk, sent, sent)
            streams.append(timing.snapshot())
        status = {"running": False, "run_id": ack["run_id"], "error": None, "forwarding_verified": True,
                  "completed_requests": 2, "received_chunks": 2000, "tool_calls": 2, "tool_results": 2,
                  "timing": dict(TIMING_POLICY, streams=streams)}
        snapshot.update(identity_snapshot(INDICES[:2 * ordinal]))
        snapshot.update(active_requests=2, partial_output_tokens=100)
        drawn_work(arrival=True)
        for offset in (1, 2, 3, 4, 5):
            record(f"episode-{ordinal}-active-{offset}", start + offset)
        snapshot.update(active_requests=0, partial_output_tokens=0)
        for field, amount in {"requests": 2, "output_tokens": 4034, "prompt_tokens": 46,
                              "tool_calls": 2, "tool_results": 2}.items():
            snapshot[field] += amount
        after = record(f"episode-{ordinal}-after", start + 5.25)
        drawn_work(arrival=False)
        for offset in (6.25, 7.25, 8.25):
            record(f"episode-{ordinal}-completion-{offset}", start + offset)
        complete = record(f"episode-{ordinal}-completion-end", start + 9.5)
        quiet_end = record(f"episode-{ordinal}-quiet-end", start + 10.75)
        report["episodes"].append({"ordinal": ordinal, "cycle": cycle, "specification": {"activity": "high-rate", "seconds": 5},
            "before": before, "after": after, "completion_end": complete, "quiet_start": complete,
            "quiet_end": quiet_end, "fixture_start": ack, "fixture_status": status})
    snapshot.update(dashboard_visible=False, popover_visible=False)
    record("closed-start", 133, tracking=False)
    record("closed-final", 134.25, tracking=False)
    report["events"] = cpu_events(samples)
    return report


class ArrivalTimingContractTests(unittest.TestCase):
    def test_complete_enabled_and_disabled_zero_snapshots_are_valid(self):
        for timed in (True, False):
            snapshot = timing_snapshot(timed)
            with self.subTest(timed=timed):
                self.assertEqual(replay.validate_timing(snapshot, timed), snapshot["arrival_diagnostics"])

    def test_missing_or_partial_metric_evidence_is_rejected(self):
        malformed = [{}, {"arrival_diagnostics": None}, {"arrival_diagnostics": []}]
        for key in timing_snapshot()["arrival_diagnostics"]:
            changed = timing_snapshot()
            del changed["arrival_diagnostics"][key]
            malformed.append(changed)
        for name in METRICS:
            changed = timing_snapshot()
            del changed["arrival_diagnostics"]["metrics"][name]
            malformed.append(changed)
        for field in FIELDS:
            changed = timing_snapshot()
            del changed["arrival_diagnostics"]["metrics"]["profile_create"][field]
            malformed.append(changed)
        changed = timing_snapshot()
        changed["arrival_diagnostics"]["metrics"]["unrecognized_scope"] = dict.fromkeys(FIELDS, 0)
        malformed.append(changed)
        for invalid in (None, [], "metrics"):
            changed = timing_snapshot()
            changed["arrival_diagnostics"]["metrics"] = invalid
            malformed.append(changed)
            changed = timing_snapshot()
            changed["arrival_diagnostics"]["metrics"]["profile_create"] = invalid
            malformed.append(changed)
        for index, snapshot in enumerate(malformed):
            with self.subTest(case=index), self.assertRaises(ValueError):
                replay.validate_timing(snapshot, True)

    def test_clock_and_enable_metadata_cannot_be_coerced_or_substituted(self):
        mutations = {
            "schema_version": (True, 1.0, "1", 2),
            "enabled": (1, "true", False),
            "measurement_thread_cpu": (1, "true", False),
            "cpu_clock": ("CLOCK_PROCESS_CPUTIME_ID", None),
            "wall_clock": ("wall_clock", None),
        }
        for field, values in mutations.items():
            for value in values:
                changed = timing_snapshot()
                changed["arrival_diagnostics"][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    replay.validate_timing(changed, True)

    def test_all_counter_fields_require_uint64_without_boolean_or_float_coercion(self):
        for field in FIELDS:
            for value in (None, True, False, -1, 1.0, "1", UINT64_MAX + 1):
                changed = timing_snapshot()
                changed["arrival_diagnostics"]["metrics"]["metal_frame_encode"][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    replay.validate_timing(changed, True)

    def test_large_integer_values_are_preserved_exactly(self):
        for count in ((1 << 53) + 1, UINT64_MAX):
            snapshot = timing_snapshot()
            metric = snapshot["arrival_diagnostics"]["metrics"]["profile_create"]
            metric.update({field: count for field in FIELDS if field not in ("clock_failures", "rejected_tokens")})
            with self.subTest(count=count):
                result = replay.validate_timing(snapshot, True)
                self.assertEqual(result["metrics"]["profile_create"], metric)
                self.assertIs(type(result["metrics"]["profile_create"]["cpu_ns"]), int)

    def test_any_clock_failure_or_rejected_token_invalidates_timing(self):
        for name in METRICS:
            for field in ("clock_failures", "rejected_tokens"):
                changed = timing_snapshot()
                changed["arrival_diagnostics"]["metrics"][name][field] = 1
                with self.subTest(metric=name, field=field), self.assertRaises(ValueError):
                    replay.validate_timing(changed, True)

    def test_disabled_timing_cannot_hide_collected_work(self):
        for field in FIELDS:
            changed = timing_snapshot(False)
            changed["arrival_diagnostics"]["metrics"]["canvas_arrival_draw"][field] = 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                replay.validate_timing(changed, False)
        with self.assertRaises(ValueError):
            replay.validate_timing(timing_snapshot(True), False)

    def test_delta_preserves_cumulative_maxima_instead_of_subtracting_them(self):
        before = timing_snapshot()
        before["arrival_diagnostics"]["metrics"]["profile_create"].update(
            calls=4, cpu_ns=400, wall_ns=800, max_cpu_ns=200, max_wall_ns=400)
        after = copy.deepcopy(before)
        after["arrival_diagnostics"]["metrics"]["profile_create"].update(calls=6, cpu_ns=480, wall_ns=990)
        result = replay.timing_delta(before, after, True)
        self.assertEqual(result["metrics"]["profile_create"], {
            "calls": 2, "cpu_ns": 80, "wall_ns": 190, "clock_failures": 0, "rejected_tokens": 0,
        })
        self.assertEqual(result["cumulative_max_after"]["profile_create"], {"max_cpu_ns": 200, "max_wall_ns": 400})
        self.assertNotIn("max_cpu_ns", result["metrics"]["profile_create"])
        self.assertNotIn("max_wall_ns", result["metrics"]["profile_create"])

    def test_counter_or_cumulative_max_regression_is_rejected(self):
        before = timing_snapshot()
        before["arrival_diagnostics"]["metrics"]["metal_frame_submit"].update(
            calls=10, cpu_ns=1000, wall_ns=2000, max_cpu_ns=100, max_wall_ns=200)
        for field in ("calls", "cpu_ns", "wall_ns", "max_cpu_ns", "max_wall_ns"):
            after = copy.deepcopy(before)
            after["arrival_diagnostics"]["metrics"]["metal_frame_submit"][field] -= 1
            with self.subTest(field=field), self.assertRaises(ValueError):
                replay.timing_delta(before, after, True)

    def test_disabled_delta_stays_zero_and_inputs_are_not_mutated(self):
        before, after = timing_snapshot(False), timing_snapshot(False)
        saved = copy.deepcopy((before, after))
        result = replay.timing_delta(before, after, False)
        self.assertEqual((before, after), saved)
        self.assertEqual(set(result["metrics"]), set(METRICS))
        self.assertTrue(all(value == 0 for metric in result["metrics"].values() for value in metric.values()))
        self.assertTrue(all(value == 0 for metric in result["cumulative_max_after"].values() for value in metric.values()))


class ReplayIdentityContractTests(unittest.TestCase):
    def test_registry_can_grow_across_three_episodes_without_reusing_indices(self):
        for count in (0, 1, 2, 4, 6):
            with self.subTest(count=count):
                self.assertEqual(replay.validate_identities(identity_snapshot(INDICES[:count]), INDICES), list(INDICES[:count]))

    def test_unknown_duplicate_or_reordered_requests_are_rejected(self):
        snapshots = [identity_snapshot((INDICES[0], INDICES[0])), identity_snapshot(INDICES[:2][::-1]),
                     identity_snapshot((INDICES[0], 480099))]
        for snapshot in snapshots:
            with self.subTest(snapshot=snapshot), self.assertRaises(ValueError):
                replay.validate_identities(snapshot, INDICES)

    def test_valid_uuid_with_changed_namespace_or_index_is_rejected(self):
        for identifier in (request_id(INDICES[0] + 1), request_id(INDICES[0]).replace("0000-0007", "0000-0008"),
                           "not-a-uuid", None):
            snapshot = identity_snapshot(INDICES[:1])
            snapshot["synthetic_request_identity"]["requests"][0]["id"] = identifier
            with self.subTest(identifier=identifier), self.assertRaises(ValueError):
                replay.validate_identities(snapshot, INDICES)

    def test_index_types_and_invalid_request_counts_are_strict(self):
        for value in (True, 480000.0, "480000", -1, 32_000_033):
            snapshot = identity_snapshot(INDICES[:1])
            snapshot["synthetic_request_identity"]["requests"][0]["index"] = value
            with self.subTest(index=value), self.assertRaises(ValueError):
                replay.validate_identities(snapshot, INDICES)
        for value in (None, True, 0.0, "0", 1, -1):
            snapshot = identity_snapshot()
            snapshot["synthetic_request_identity"]["invalid_requests"] = value
            with self.subTest(invalid_requests=value), self.assertRaises(ValueError):
                replay.validate_identities(snapshot, INDICES)

    def test_missing_identity_evidence_and_wrong_policy_are_rejected(self):
        snapshots = [{}, {"synthetic_request_identity": None}]
        for field in ("policy", "invalid_requests", "requests"):
            snapshot = identity_snapshot()
            del snapshot["synthetic_request_identity"][field]
            snapshots.append(snapshot)
        snapshot = identity_snapshot()
        snapshot["synthetic_request_identity"]["policy"] = "random-uuid"
        snapshots.append(snapshot)
        for snapshot in snapshots:
            with self.subTest(snapshot=snapshot), self.assertRaises(ValueError):
                replay.validate_identities(snapshot, INDICES)

    def test_request_rows_cannot_be_missing_fields_or_nonobjects(self):
        for rows in (None, {}, "requests", [None], [{}], [{"index": INDICES[0]}],
                     [{"id": request_id(INDICES[0])}]):
            snapshot = identity_snapshot()
            snapshot["synthetic_request_identity"]["requests"] = rows
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                replay.validate_identities(snapshot, INDICES)


class ReplayEvidenceTests(unittest.TestCase):
    def test_three_complete_episodes_keep_identity_growth_and_actual_cpu_windows(self):
        for mode, timed in (("normal", False), (replay.memory.METAL_ARRIVAL_MODE, False),
                            (replay.memory.METAL_ARRIVAL_MODE, True)):
            with self.subTest(mode=mode, timed=timed):
                result = replay.validate_replay(replay_report(mode, timed), mode, timed)
                self.assertFalse(result["regression_passed"])
                self.assertEqual(result["cpu_acceptance_eligible"], not timed)
                self.assertEqual(len(result["phase_cpu"]), 7)
                for metric in result["phase_cpu"].values():
                    self.assertAlmostEqual(metric["average_cpu_percent"], 2.0)
                    self.assertEqual(metric["acceptance_eligible"], not timed)
                for target in result["cpu_targets"].values():
                    self.assertEqual(target["evaluated"], not timed)
                    self.assertEqual(target["within_limit"], None if timed else True)
                self.assertEqual([len(episode["after"]["synthetic_request_identity"]["requests"])
                                  for episode in result["episodes"]], [2, 4, 6])

    def test_missing_metal_arrival_work_cannot_pass_using_completion_canvas_work(self):
        mode = replay.memory.METAL_ARRIVAL_MODE
        report = replay_report(mode)
        for point in report["checkpoints"]:
            point["snapshot"].update(metal_arrival_frames=0, metal_arrival_submissions=0)
        with self.assertRaisesRegex(ValueError, "Arrival phase did not submit Metal"):
            replay.validate_replay(report, mode, False)

    def test_hidden_windows_changed_identity_and_missing_progress_are_rejected(self):
        for fault in ("hidden", "changed-id", "lost-progress"):
            report = replay_report()
            snapshot = next(point["snapshot"] for point in report["runtime"]["checkpoints"]
                            if point["label"] == "episode-2-active-3")
            if fault == "hidden":
                snapshot["popover_visible"] = False
            elif fault == "changed-id":
                snapshot["synthetic_request_identity"]["requests"][0]["id"] = request_id(123)
            else:
                snapshot["partial_output_tokens"] = 0
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                replay.validate_replay(report, "normal", False)

    def test_fixture_timing_failure_and_inexact_forwarding_totals_are_rejected(self):
        for fault in ("late-source", "output-total", "reused-cycle"):
            report = replay_report()
            episode = report["episodes"][1]
            if fault == "late-source":
                episode["fixture_status"]["timing"]["streams"][0]["maximum_finish_lateness_seconds"] = .051
            elif fault == "output-total":
                episode["after"]["output_tokens"] += 1
            else:
                episode["cycle"] = report["episodes"][0]["cycle"]
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                replay.validate_replay(report, "normal", False)

    def test_invalid_kernel_clock_is_rejected_by_real_phase_cpu_validation(self):
        report = replay_report()
        report["samples"][20]["mach_absolute_ticks"] += 1_000_000_000
        with self.assertRaisesRegex(ValueError, "Mach fields disagree"):
            replay.validate_replay(report, "normal", False)

    def test_missing_final_exit_or_quiet_cancellation_proof_is_rejected(self):
        for fault in ("exit", "initial-quiet", "closed", "active-quiet"):
            report = replay_report()
            if fault == "exit":
                report["events"][-1]["status"] = 9
            elif fault == "initial-quiet":
                report["runtime"]["checkpoints"][0]["label"] = "missing-initial-quiet"
            elif fault == "closed":
                report["checkpoints"][-1]["snapshot"]["dashboard_visible"] = True
            else:
                report["episodes"][0]["quiet_end"]["rail_frame_clock_ticks"] += 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                replay.validate_replay(report, "normal", False)

    def test_timed_report_requires_executed_scopes_and_does_not_accept_quiet_callbacks(self):
        mode = replay.memory.METAL_ARRIVAL_MODE
        for fault in ("missing-scope", "quiet-callback"):
            report = replay_report(mode, True)
            if fault == "missing-scope":
                for snapshot in [report["ready"]["snapshot"]] + [point["snapshot"] for point in report["checkpoints"]]:
                    snapshot["arrival_diagnostics"]["metrics"]["metal_frame_callback"] = dict.fromkeys(FIELDS, 0)
            else:
                row = report["episodes"][-1]["quiet_end"]["arrival_diagnostics"]["metrics"]["metal_frame_callback"]
                row.update(calls=row["calls"] + 1, cpu_ns=row["cpu_ns"] + 1000, wall_ns=row["wall_ns"] + 2000)
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                replay.validate_replay(report, mode, True)


class ReplayIsolationTests(unittest.TestCase):
    def arguments(self, output):
        return ["--app-binary", "/missing/app", "--test-bundle", "/missing/tests",
                "--collector-binary", "/missing/collector", "--provenance", "/missing/provenance",
                "--output-dir", str(output)]

    def test_fixed_case_order_keeps_timing_outside_unprofiled_bracket(self):
        self.assertEqual(replay.CASES, (("normal-before", "normal", False),
            ("metal-arrivals", "runtime-metal-arrival-bursts", False), ("normal-after", "normal", False),
            ("metal-arrivals-timed", "runtime-metal-arrival-bursts", True)))
        self.assertEqual((replay.MAX_SECONDS, replay.CASE_SECONDS, replay.EPISODE_SECONDS), (300, 65, 5))
        self.assertEqual(replay.CYCLES, (15000, 15001, 15002))

    def test_timing_environment_restores_prior_value_or_absence_after_failure(self):
        for prior in (None, "1", "custom-value"):
            for timed in (False, True):
                with self.subTest(prior=prior, timed=timed), patch.dict(os.environ, {"UNRELATED": "kept"}, clear=True):
                    if prior is not None:
                        os.environ[replay.TIMING_ENV] = prior
                    with self.assertRaisesRegex(RuntimeError, "scripted"):
                        with replay.timing_environment(timed):
                            self.assertEqual(os.environ[replay.TIMING_ENV], "1" if timed else "0")
                            self.assertEqual(os.environ["UNRELATED"], "kept")
                            raise RuntimeError("scripted")
                    self.assertEqual(os.environ.get(replay.TIMING_ENV), prior)
                    self.assertEqual(replay.TIMING_ENV in os.environ, prior is not None)

    def test_collector_constructor_receives_only_its_case_timing_selection(self):
        diagnostic = replay.ArrivalDiagnostic.__new__(replay.ArrivalDiagnostic)
        diagnostic.timed = False
        observed = []
        def fail(*args, **kwargs):
            observed.append((os.environ.get(replay.TIMING_ENV), kwargs["owner"]))
            raise RuntimeError("constructor failed")
        with patch.dict(os.environ, {replay.TIMING_ENV: "1"}), patch.object(replay.runtime, "RuntimeCollector", side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, "constructor failed"):
                diagnostic.create_collector("collector", "app")
            self.assertEqual(os.environ[replay.TIMING_ENV], "1")
        self.assertEqual(observed, [("0", diagnostic)])

    def test_source_identity_adds_driver_without_discarding_common_sources(self):
        common = {"memory_attribution.py": "memory-hash", "runtime_attribution.py": "runtime-hash"}
        with patch.object(replay.runtime, "runtime_source_identity", return_value=common):
            sources = replay.source_identity()
        self.assertEqual({key: sources[key] for key in common}, common)
        self.assertEqual(sources["arrival_replay.py"], replay.app.path_hash(Path(replay.__file__)))
        self.assertNotIn("arrival_replay.py", common)

    def test_existing_output_evidence_is_never_overwritten_or_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "existing"
            output.mkdir()
            evidence = output / "arrival-report.json"
            evidence.write_bytes(b"immutable earlier evidence\n")
            with patch.object(replay.sys, "platform", "darwin"), \
                    patch.object(replay.memory, "validate_products") as products, \
                    patch.object(replay, "capture_case") as capture, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(replay.run(self.arguments(output)), 1)
            self.assertEqual(evidence.read_bytes(), b"immutable earlier evidence\n")
            self.assertEqual(list(output.iterdir()), [evidence])
            products.assert_not_called()
            capture.assert_not_called()

    def test_late_validation_failure_revokes_cpu_eligibility_and_hides_summary_values(self):
        diagnostic = SimpleNamespace(report={"errors": [], "workload_cpu": {"available": True}},
                                     perform=lambda *args: None, cleanup=lambda: None)
        deadline = SimpleNamespace(end=1000, cleanup_reserve=8,
                                   interrupt_at=lambda end: contextlib.nullcontext())

        def reject_after_cpu_validation(report, mode, timed, *, profile=False):
            report["cpu_acceptance_eligible"] = True
            report["phase_cpu"] = {"whole_replay": {"average_cpu_percent": 99.125,
                "rolling_1s_percent": 101.25, "acceptance_eligible": True}}
            report["cpu_targets"] = {"whole_replay": {"evaluated": True, "within_limit": True}}
            raise ValueError("late visibility evidence failure")

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "failed-case"
            with patch.object(replay, "ArrivalDiagnostic", return_value=diagnostic), \
                    patch.object(replay, "validate_replay", side_effect=reject_after_cpu_validation):
                result = replay.capture_case(output, "normal", False, {}, {}, {}, deadline)
            self.assertEqual(result["status"], "diagnostic_incomplete")
            self.assertFalse(result["cpu_acceptance_eligible"])
            self.assertFalse(result["workload_cpu"]["acceptance_eligible"])
            self.assertFalse(result["phase_cpu"]["whole_replay"]["acceptance_eligible"])
            self.assertEqual(result["cpu_targets"]["whole_replay"], {"evaluated": False, "within_limit": None})
            self.assertEqual(result["errors"], ["late visibility evidence failure"])
            self.assertEqual(json.loads((output / "arrival-case.json").read_text()), result)
            rendered = replay.summary({"status": "diagnostic_incomplete", "cases": [
                dict(result, label="normal-before", timed=False)]})
            self.assertIn("unavailable", rendered)
            self.assertIn("unqualified", rendered)
            self.assertNotIn("99.1250%", rendered)
            self.assertNotIn("101.2500%", rendered)


class ArrivalProfileContractTests(unittest.TestCase):
    def profiled_report(self, mode=replay.memory.METAL_ARRIVAL_MODE):
        report = replay_report(mode)
        report["runtime"].update(profiled=True, profiler_status="captured",
                                 owned_identity=copy.deepcopy(report["owned_identity"]))
        return report

    def test_profile_is_explicit_and_default_comparison_remains_available(self):
        arguments = ReplayIsolationTests().arguments(Path("/tmp/arrival-profile-option"))
        self.assertFalse(replay.parser().parse_args(arguments).profile)
        self.assertTrue(replay.parser().parse_args(arguments + ["--profile"]).profile)

    def test_profiled_kernel_cpu_cannot_establish_acceptance_even_below_target(self):
        result = replay.validate_replay(self.profiled_report(), replay.memory.METAL_ARRIVAL_MODE,
                                        False, profile=True)
        self.assertFalse(result["regression_passed"])
        self.assertFalse(result["cpu_acceptance_eligible"])
        self.assertEqual(len(result["phase_cpu"]), 7)
        for metrics in result["phase_cpu"].values():
            self.assertAlmostEqual(metrics["average_cpu_percent"], 2.0)
            self.assertFalse(metrics["acceptance_eligible"])
        for target in result["cpu_targets"].values():
            self.assertFalse(target["evaluated"])
            self.assertIsNone(target["within_limit"])

    def test_production_profile_validates_canvas_work_without_enabling_cpu_acceptance(self):
        result = replay.validate_replay(self.profiled_report("normal"), "normal", False, profile=True)
        self.assertFalse(result["cpu_acceptance_eligible"])
        self.assertTrue(all(not metrics["acceptance_eligible"] for metrics in result["phase_cpu"].values()))
        self.assertTrue(all(not target["evaluated"] and target["within_limit"] is None
                            for target in result["cpu_targets"].values()))
        for episode in result["episodes"]:
            self.assertEqual(episode["after"]["metal_arrival_submissions"], 0)
            self.assertGreater(episode["after"]["rail_frame_clock_ticks"], episode["before"]["rail_frame_clock_ticks"])

    def test_profile_requires_finalized_trace_and_owned_kernel_identity(self):
        for fault in ("missing-status", "recording", "failed", "changed-pid", "changed-birth", "trace-identity"):
            report = self.profiled_report()
            if fault == "missing-status":
                del report["runtime"]["profiler_status"]
            elif fault in ("recording", "failed"):
                report["runtime"]["profiler_status"] = fault
            elif fault == "changed-pid":
                report["samples"][20]["process_id"] += 1
            elif fault == "changed-birth":
                report["samples"][20]["birth_time_us"] += 1
            else:
                report["runtime"]["owned_identity"]["birth_time_us"] += 1
            with self.subTest(fault=fault), self.assertRaises(ValueError):
                replay.validate_replay(report, replay.memory.METAL_ARRIVAL_MODE, False, profile=True)

    def test_profile_cannot_be_combined_with_scoped_timing_or_mislabeled_as_unprofiled(self):
        report = self.profiled_report()
        with self.assertRaises(ValueError):
            replay.validate_replay(report, replay.memory.METAL_ARRIVAL_MODE, True, profile=True)
        report["runtime"]["profiled"] = False
        with self.assertRaises(ValueError):
            replay.validate_replay(report, replay.memory.METAL_ARRIVAL_MODE, False, profile=True)

    def test_profiler_attachment_rejects_changed_identity_or_insufficient_save_budget(self):
        for fault in ("birth", "process-group", "deadline"):
            diagnostic = replay.ArrivalDiagnostic.__new__(replay.ArrivalDiagnostic)
            diagnostic.verify_identity = lambda: None
            diagnostic.identity = {"process_id": 123, "birth_time_us": 456}
            diagnostic.deadline = SimpleNamespace(remaining=lambda: 1 if fault == "deadline" else 300)
            with self.subTest(fault=fault), \
                    patch.object(replay.runtime, "_birth_time", return_value=789 if fault == "birth" else 456), \
                    patch.object(replay.runtime.os, "getpgid", return_value=789 if fault == "process-group" else 123), \
                    patch.object(replay.runtime, "_Notice") as notice, \
                    patch.object(replay.runtime.subprocess, "Popen") as process:
                with self.assertRaises(ValueError):
                    diagnostic.begin_profile()
                notice.assert_not_called()
                process.assert_not_called()

    def run_offline(self, *, profile=True, graphics_mode=None, attribution_status="profiled_phase_attribution_available",
                    attribution_usable=None, analysis_error=None, budget=300):
        """Exercise orchestration and persisted outcomes without launching any process."""
        captures = []
        phase_windows = {"arrival": {"start_monotonic_seconds": 100.1, "end_monotonic_seconds": 102.1}}
        attribution = {
            "status": attribution_status, "regression_passed": False, "process_id": 123, "birth_time_us": 456,
            "phases": [], "analysis_quality": {
                "quantitative_attribution_usable": attribution_status == "profiled_phase_attribution_available",
                "sample_kernel_mismatch_phases": [] if attribution_status == "profiled_phase_attribution_available" else ["arrival"],
                "all_selected_symbols_missing": False,
            },
        }
        if attribution_usable is not None:
            attribution["analysis_quality"]["quantitative_attribution_usable"] = attribution_usable

        def bounded_deadline(seconds, cleanup_reserve=15):
            return SimpleNamespace(end=replay.time.monotonic() + seconds, cleanup_reserve=cleanup_reserve,
                                   requested_seconds=seconds, remaining=lambda: min(seconds, budget),
                                   interrupt_at=lambda end: contextlib.nullcontext())

        def capture(output, mode, timed, paths, provenance, identity, deadline, *, profile=False):
            captures.append((output.name, mode, timed, profile, deadline.requested_seconds))
            result = replay_report(mode, timed)
            if profile:
                result["runtime"].update(profiled=True, profiler_status="captured",
                                         owned_identity=copy.deepcopy(result["owned_identity"]),
                                         clock_anchor={"synthetic_anchor": True})
            replay.validate_replay(result, mode, timed, profile=profile)
            result["status"] = "diagnostic_captured"
            output.mkdir()
            replay.write_json(output / "arrival-case.json", result)
            return result

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "capture"
            arguments = ReplayIsolationTests().arguments(output) + (["--profile"] if profile else [])
            if graphics_mode is not None:
                arguments += ["--graphics-mode", graphics_mode]
            args = replay.parser().parse_args(arguments)
            with patch.object(replay.sys, "platform", "darwin"), \
                    patch.object(replay, "source_identity", return_value={}), \
                    patch.object(replay.memory, "validate_products", return_value=({}, {}, {})), \
                    patch.object(replay.runtime, "RuntimeDeadline", side_effect=bounded_deadline), \
                    patch.object(replay, "capture_case", side_effect=capture), \
                    patch.object(replay.time_profile, "arrival_profile_windows", return_value=phase_windows) as windows, \
                    patch.object(replay.time_profile, "analyze_trace", return_value=attribution, side_effect=analysis_error) as analyze, \
                    contextlib.redirect_stdout(io.StringIO()):
                exit_code = replay._run(args, bounded_deadline(300))
            report = json.loads((output / "arrival-report.json").read_text())
            evidence = {path.parent.name: json.loads(path.read_text()) for path in output.glob("*/arrival-case.json")}
        return exit_code, report, evidence, captures, windows, analyze

    def test_single_profile_case_uses_bounded_capture_and_owned_analysis_evidence(self):
        code, report, evidence, captures, windows, analyze = self.run_offline()
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "diagnostic_captured")
        self.assertFalse(report["regression_passed"])
        self.assertEqual(captures, [("metal-arrivals-profile", replay.memory.METAL_ARRIVAL_MODE,
                                     False, True, replay.runtime.PROFILE_SECONDS)])
        self.assertEqual(report["operation"], "profile")
        self.assertNotIn("baseline_drift", report)
        self.assertTrue(report["native_capture_complete"])
        self.assertEqual(report["attribution_status"], "profiled_phase_attribution_available")
        self.assertFalse(report["cases"][0]["cpu_acceptance_eligible"])
        windows.assert_called_once()
        analyze.assert_called_once()
        self.assertEqual(windows.call_args.args[0]["owned_identity"], {"process_id": 123, "birth_time_us": 456})
        self.assertEqual(analyze.call_args.args[2], 123)
        self.assertEqual(analyze.call_args.args[3], {"arrival": {
            "start_monotonic_seconds": 100.1, "end_monotonic_seconds": 102.1}})
        self.assertEqual(analyze.call_args.args[-1].requested_seconds, 300)
        self.assertEqual(len(evidence), 1)
        self.assertTrue(all(not metric["acceptance_eligible"] for metric in evidence["metal-arrivals-profile"]["phase_cpu"].values()))
        rendered = replay.summary(report)
        self.assertIn("No CPU target is evaluated", rendered)
        self.assertIn("not evaluated", rendered)

    def test_profile_routes_explicit_production_and_metal_modes_without_changing_analysis(self):
        for mode, label in (("normal", "normal-profile"),
                            (replay.memory.METAL_ARRIVAL_MODE, "metal-arrivals-profile")):
            with self.subTest(mode=mode):
                code, report, evidence, captures, windows, analyze = self.run_offline(graphics_mode=mode)
                self.assertEqual(code, 0)
                self.assertEqual(report["graphics_mode"], mode)
                self.assertEqual(captures, [(label, mode, False, True, replay.runtime.PROFILE_SECONDS)])
                self.assertEqual(report["cases"][0]["mode"], mode)
                self.assertFalse(report["cases"][0]["cpu_acceptance_eligible"])
                self.assertEqual(set(evidence), {label})
                self.assertFalse(evidence[label]["cpu_acceptance_eligible"])
                windows.assert_called_once()
                analyze.assert_called_once()
                self.assertEqual(analyze.call_args.args[3], report["profile_phase_windows"])
                self.assertEqual(analyze.call_args.args[-1].requested_seconds, 300)

    def test_profile_rejects_unsupported_rendering_modes_before_capture(self):
        arguments = ReplayIsolationTests().arguments(Path("/tmp/arrival-profile-invalid-mode"))
        with patch.object(replay, "capture_case") as capture, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                replay.run(arguments + ["--profile", "--graphics-mode", "runtime-no-lifecycle"])
        capture.assert_not_called()

    def test_sample_kernel_mismatch_preserves_raw_capture_but_returns_pending(self):
        code, report, evidence, captures, windows, analyze = self.run_offline(attribution_status="analysis_pending")
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "analysis_pending")
        self.assertEqual(report["attribution_status"], "analysis_pending")
        self.assertTrue(report["native_capture_complete"])
        self.assertFalse(report["regression_passed"])
        self.assertEqual(report["attribution"]["analysis_quality"]["sample_kernel_mismatch_phases"], ["arrival"])
        self.assertEqual(evidence["metal-arrivals-profile"]["status"], "diagnostic_captured")
        self.assertFalse(report["cases"][0]["cpu_acceptance_eligible"])
        self.assertEqual(len(captures), 1)
        self.assertIn("Quantitative attribution is pending", replay.summary(report))

    def test_unknown_or_contradictory_analysis_completion_cannot_qualify_a_capture(self):
        for status, usable in (("unexpected-status", False), ("profiled_phase_attribution_available", False),
                               ("analysis_pending", True)):
            with self.subTest(status=status, usable=usable):
                code, report, evidence, captures, windows, analyze = self.run_offline(
                    attribution_status=status, attribution_usable=usable)
                self.assertEqual(code, 1)
                self.assertEqual(report["status"], "diagnostic_incomplete")
                self.assertFalse(report["regression_passed"])
                self.assertFalse(report["cases"][0]["cpu_acceptance_eligible"])
                self.assertTrue(report["errors"])
                self.assertEqual(len(captures), 1)

    def test_missing_or_malformed_trace_fails_without_repeating_native_capture(self):
        for error in (FileNotFoundError("missing trace export"), ValueError("malformed trace export"),
                      TimeoutError("bounded export deadline")):
            with self.subTest(error=str(error)):
                code, report, evidence, captures, windows, analyze = self.run_offline(analysis_error=error)
                self.assertEqual(code, 1)
                self.assertEqual(report["status"], "diagnostic_incomplete")
                self.assertFalse(report["regression_passed"])
                self.assertTrue(any(str(error) in value for value in report["errors"]))
                self.assertEqual(len(captures), 1)
                self.assertEqual(evidence["metal-arrivals-profile"]["status"], "diagnostic_captured")
                self.assertFalse(report["cases"][0]["cpu_acceptance_eligible"])

    def test_default_comparison_preserves_control_bracket_without_attaching_profiler(self):
        code, report, evidence, captures, windows, analyze = self.run_offline(profile=False)
        self.assertEqual(code, 0)
        self.assertEqual(report["operation"], "compare")
        self.assertEqual(report["status"], "diagnostic_captured")
        self.assertEqual([(label, mode, timed) for label, mode, timed, _, _ in captures], list(replay.CASES))
        self.assertTrue(all(not profiled and seconds == replay.CASE_SECONDS for _, _, _, profiled, seconds in captures))
        self.assertEqual([case["cpu_acceptance_eligible"] for case in report["cases"]], [True, True, True, False])
        self.assertTrue(report["baseline_drift"]["comparison_conclusive"])
        self.assertEqual(len(evidence), 4)
        windows.assert_not_called()
        analyze.assert_not_called()

    def test_insufficient_profile_budget_prevents_capture_and_analysis(self):
        code, report, evidence, captures, windows, analyze = self.run_offline(budget=20)
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "diagnostic_incomplete")
        self.assertEqual(captures, [])
        self.assertEqual(evidence, {})
        windows.assert_not_called()
        analyze.assert_not_called()


class ArrivalVersionComparisonTests(unittest.TestCase):
    REFERENCE_OPTIONS = ("--reference-app-binary", "--reference-test-bundle", "--reference-provenance")

    def test_incomplete_reference_options_and_incompatible_modes_never_launch_capture(self):
        selections = [list(range(3))[:count] for count in (1, 2)]
        selections.extend(([1], [2], [0, 2], [1, 2]))
        scenarios = [([argument for index in selected for argument in
                       (self.REFERENCE_OPTIONS[index], "/missing/reference")], "partial") for selected in selections]
        scenarios.append(([argument for option in self.REFERENCE_OPTIONS for argument in (option, "/missing/reference")]
                          + ["--profile"], "profile"))
        scenarios.append((["--graphics-mode", "normal"], "mode-without-reference"))
        for extras, label in scenarios:
            with self.subTest(label=label, extras=extras), tempfile.TemporaryDirectory() as directory:
                arguments = ReplayIsolationTests().arguments(Path(directory) / "output") + extras
                with patch.object(replay.sys, "platform", "darwin"), \
                        patch.object(replay.memory, "validate_products") as products, \
                        patch.object(replay, "capture_case") as capture, \
                        contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    try:
                        code = replay.run(arguments)
                    except SystemExit as error:
                        code = error.code
                self.assertNotEqual(code, 0)
                products.assert_not_called()
                capture.assert_not_called()

    def compare_offline(self, *, mode=None, invalid_product=None, mismatched_identity=False,
                        mismatched_fixture=False, mutate_after=None):
        """Use distinct real artifact hashes and mocked native captures only."""
        captures, validated = [], []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            collector = root / "collector"
            collector.write_text("common collector")
            products = {}
            for role in ("candidate", "reference"):
                folder = root / role
                folder.mkdir()
                paths = {"app": folder / "app", "tests": folder / "tests", "collector": collector}
                paths["app"].write_text(role + " app")
                paths["tests"].write_text(role + " tests")
                bundle = folder / "Resources.bundle"
                bundle.mkdir()
                (bundle / "resource").write_text("shared resources")
                provenance = {"resource_bundle_sha256": {bundle.name: replay.app.path_hash(bundle)},
                              "fixture_equivalence_sha256": {"populated": "different-fixture" if role == "reference"
                                  and mismatched_fixture else "shared-populated-fixture"}}
                provenance_path = folder / "provenance.json"
                provenance["provenance_file"] = str(provenance_path)
                provenance_path.write_text(json.dumps(provenance))
                products[role] = {"paths": paths, "provenance": provenance, "provenance_path": provenance_path,
                                  "identity": {"sha256": "shared-measurement-identity"}, "bundle": bundle}
            if mismatched_identity:
                products["reference"]["identity"]["sha256"] = "different-measurement-identity"

            def validate(args):
                role = args.app_binary.parent.name
                selected = products[role]
                validated.append({"role": role, "app": str(args.app_binary), "tests": str(args.test_bundle),
                                  "collector": str(args.collector_binary), "provenance": str(args.provenance)})
                if role == invalid_product:
                    raise ValueError("strict provenance rejected " + role)
                self.assertEqual(args.app_binary, selected["paths"]["app"])
                self.assertEqual(args.test_bundle, selected["paths"]["tests"])
                self.assertEqual(args.collector_binary, collector)
                self.assertEqual(args.provenance, selected["provenance_path"])
                return selected["paths"], selected["provenance"], selected["identity"]

            def deadline(seconds, cleanup_reserve=15):
                return SimpleNamespace(end=replay.time.monotonic() + seconds, cleanup_reserve=cleanup_reserve,
                    requested_seconds=seconds, remaining=lambda: seconds,
                    interrupt_at=lambda end: contextlib.nullcontext())

            def capture(output, mode, timed, paths, provenance, identity, budget, *, profile=False):
                role = paths["app"].parent.name
                self.assertIs(paths, products[role]["paths"])
                self.assertIs(provenance, products[role]["provenance"])
                self.assertIs(identity, products[role]["identity"])
                captures.append({"label": output.name, "role": role, "mode": mode, "timed": timed,
                                 "profiled": profile, "seconds": budget.requested_seconds})
                result = replay_report(mode, timed)
                if role == "candidate":
                    # Candidate differs sharply, so drift must use reference endpoints.
                    for sample in result["samples"]:
                        sample["cpu_seconds"] *= 10
                replay.validate_replay(result, mode, timed, profile=profile)
                result["status"] = "diagnostic_captured"
                output.mkdir()
                replay.write_json(output / "arrival-case.json", result)
                if len(captures) == 1 and mutate_after:
                    selected = products[mutate_after[0]]
                    target = (selected["provenance_path"] if mutate_after[1] == "provenance" else
                              selected["bundle"] / "resource" if mutate_after[1] == "resource" else
                              selected["paths"][mutate_after[1]])
                    target.write_text("changed during comparison")
                return result

            output = root / "output"
            arguments = ["--app-binary", str(products["candidate"]["paths"]["app"]),
                         "--test-bundle", str(products["candidate"]["paths"]["tests"]),
                         "--collector-binary", str(collector),
                         "--provenance", str(products["candidate"]["provenance_path"]),
                         "--output-dir", str(output),
                         "--reference-app-binary", str(products["reference"]["paths"]["app"]),
                         "--reference-test-bundle", str(products["reference"]["paths"]["tests"]),
                         "--reference-provenance", str(products["reference"]["provenance_path"])]
            if mode:
                arguments += ["--graphics-mode", mode]
            args = replay.parser().parse_args(arguments)
            with patch.object(replay.sys, "platform", "darwin"), \
                    patch.object(replay, "source_identity", return_value={}), \
                    patch.object(replay.memory, "validate_products", side_effect=validate), \
                    patch.object(replay.runtime, "RuntimeDeadline", side_effect=deadline), \
                    patch.object(replay, "capture_case", side_effect=capture), \
                    patch.object(replay.time_profile, "analyze_trace") as analyze, \
                    contextlib.redirect_stdout(io.StringIO()):
                code = replay._run(args, deadline(300))
            report = json.loads((output / "arrival-report.json").read_text())
            analyze.assert_not_called()
        return code, report, captures, validated

    def test_same_mode_comparison_selects_reference_candidate_reference_and_reference_drift(self):
        for mode in (None, "normal", replay.memory.METAL_ARRIVAL_MODE):
            with self.subTest(mode=mode):
                code, report, captures, validated = self.compare_offline(mode=mode)
                self.assertEqual(code, 0)
                self.assertEqual(report["operation"], "version-compare")
                self.assertEqual(report["status"], "diagnostic_captured")
                self.assertFalse(report["regression_passed"])
                self.assertEqual([row["role"] for row in validated], ["candidate", "reference"])
                self.assertEqual([(row["label"], row["role"]) for row in captures], [
                    ("reference-before", "reference"), ("candidate", "candidate"), ("reference-after", "reference")])
                self.assertTrue(all(row["mode"] == (mode or replay.memory.METAL_ARRIVAL_MODE) for row in captures))
                self.assertTrue(all(not row["timed"] and not row["profiled"] and row["seconds"] == 65 for row in captures))
                self.assertTrue(all(case["cpu_acceptance_eligible"] for case in report["cases"]))
                self.assertEqual([case["product_role"] for case in report["cases"]], ["reference", "candidate", "reference"])
                self.assertEqual(set(report["products"]), {"candidate", "reference"})
                first, second = (report["products"][role]["files"] for role in ("candidate", "reference"))
                self.assertNotEqual(first["app"]["sha256"], second["app"]["sha256"])
                self.assertEqual(first["collector"], second["collector"])
                self.assertIn("provenance", first)
                self.assertIn("resource:Resources.bundle", second)
                self.assertAlmostEqual(report["cases"][1]["phase_cpu"]["whole_replay"]["average_cpu_percent"], 20)
                self.assertTrue(report["baseline_drift"]["comparison_conclusive"])

    def test_both_product_sets_must_pass_strict_validation_before_any_capture(self):
        for role in ("candidate", "reference"):
            with self.subTest(role=role):
                code, report, captures, validated = self.compare_offline(invalid_product=role)
                self.assertEqual(code, 1)
                self.assertEqual(report["status"], "diagnostic_incomplete")
                self.assertEqual(captures, [])
                self.assertTrue(any("strict provenance rejected " + role in error for error in report["errors"]))

    def test_different_measurement_identity_cannot_be_compared(self):
        code, report, captures, validated = self.compare_offline(mismatched_identity=True)
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "diagnostic_incomplete")
        self.assertEqual(captures, [])

    def test_different_populated_fixture_cannot_be_compared(self):
        code, report, captures, validated = self.compare_offline(mismatched_fixture=True)
        self.assertEqual(code, 1)
        self.assertEqual(report["status"], "diagnostic_incomplete")
        self.assertEqual(captures, [])

    def test_changed_reference_candidate_or_shared_artifacts_prevent_further_capture(self):
        for role, field in (("reference", "app"), ("candidate", "app"), ("reference", "tests"),
                            ("candidate", "collector"), ("reference", "provenance"), ("candidate", "resource")):
            with self.subTest(role=role, field=field):
                code, report, captures, validated = self.compare_offline(mutate_after=(role, field))
                self.assertEqual(code, 1)
                self.assertEqual(report["status"], "diagnostic_incomplete")
                self.assertEqual(len(captures), 1)
                self.assertTrue(report["errors"])


if __name__ == "__main__":
    unittest.main()
