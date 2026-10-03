#!/usr/bin/env python3
"""Bounded, matched-episode arrival diagnostics; no build or native profiler."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import sys
import time
import uuid

import app_performance as app
import memory_attribution as memory
import runtime_attribution as runtime
from run_performance_checks import require, write_json

MAX_SECONDS = 300
CASE_SECONDS = 65
EPISODE_SECONDS = 5
CYCLES = (15000, 15001, 15002)
CASES = (("normal-before", "normal", False), ("metal-arrivals", memory.METAL_ARRIVAL_MODE, False),
         ("normal-after", "normal", False), ("metal-arrivals-timed", memory.METAL_ARRIVAL_MODE, True))
TIMING_ENV = "FLUXLLM_PERF_ARRIVAL_TIMING"
METRICS = ("profile_preparation", "profile_create", "metal_elements", "metal_descriptor_update",
           "metal_descriptor_upload", "metal_surface_setup", "metal_first_drawable", "metal_later_drawable",
           "metal_frame_callback", "metal_frame_encode", "metal_frame_submit", "metal_completion_callback", "metal_completion_main_actor",
           "metal_clear", "canvas_arrival_draw")
TIMING_FIELDS = ("calls", "cpu_ns", "wall_ns", "max_cpu_ns", "max_wall_ns", "clock_failures", "rejected_tokens")
DELTA_FIELDS = ("calls", "cpu_ns", "wall_ns", "clock_failures", "rejected_tokens")
QUIET_FIELDS = ("rail_frame_clock_ticks",) + memory.METAL_ARRIVAL_COUNTERS
STAGE = {"activity": "high-rate", "seconds": EPISODE_SECONDS}
WORK = app.expected_work(STAGE)
ERRORS = (OSError, ValueError, KeyError, TypeError, OverflowError, TimeoutError, subprocess.SubprocessError)


def validate_timing(snapshot, timed):
    value = snapshot.get("arrival_diagnostics")
    require(isinstance(value, dict), "Arrival timing metadata is missing")
    expected = {"schema_version": 1, "measurement_thread_cpu": True, "cpu_clock": "CLOCK_THREAD_CPUTIME_ID",
                "wall_clock": "monotonic_uptime", "enabled": timed}
    require(all(type(value.get(key)) is type(wanted) and value[key] == wanted for key, wanted in expected.items()),
            "Arrival timing schema, clocks, or enabled state differ")
    metrics = value.get("metrics")
    require(isinstance(metrics, dict) and set(metrics) == set(METRICS), "Arrival timing metric set is incomplete")
    for name, row in metrics.items():
        require(isinstance(row, dict) and set(row) == set(TIMING_FIELDS), f"Arrival timing {name} fields are incomplete")
        require(all(type(number) is int and 0 <= number <= 2**64 - 1 for number in row.values()),
                f"Arrival timing {name} counters must be UInt64")
        require(row["clock_failures"] == row["rejected_tokens"] == 0, f"Arrival timing {name} reported clock/token failures")
        require(row["max_cpu_ns"] <= row["cpu_ns"] and row["max_wall_ns"] <= row["wall_ns"],
                f"Arrival timing {name} maxima exceed cumulative totals")
        require(row["calls"] > 0 or all(row[field] == 0 for field in TIMING_FIELDS),
                f"Arrival timing {name} has time without completed calls")
        require(timed or all(number == 0 for number in row.values()), "Disabled arrival timing recorded work")
    return value


def timing_delta(before, after, timed):
    first, last = validate_timing(before, timed)["metrics"], validate_timing(after, timed)["metrics"]
    require(all(last[name][field] >= first[name][field] for name in METRICS for field in TIMING_FIELDS),
            "Arrival timing counters moved backwards")
    return {"metrics": {name: {field: last[name][field] - first[name][field] for field in DELTA_FIELDS} for name in METRICS},
            "cumulative_max_after": {name: {field: last[name][field] for field in ("max_cpu_ns", "max_wall_ns")} for name in METRICS},
            "scope": "Exact acknowledged snapshot interval; cumulative maxima are not per-interval maxima. Nested scopes must not be summed."}


def validate_identities(snapshot, allowed_indices):
    value = snapshot.get("synthetic_request_identity", {})
    require(isinstance(value, dict), "Arrival request identity group is missing or malformed")
    require(value.get("policy") == "fixture-index-v1" and type(value.get("invalid_requests")) is int
            and value["invalid_requests"] == 0, "Arrival request identity policy is missing or invalid")
    require(snapshot.get("synthetic_animation_policy") == "fixture-index-and-fixed-twinkle-seed-v1",
            "Arrival animation policy differs")
    rows = value.get("requests")
    require(isinstance(rows, list), "Arrival request identities are missing")
    actual = []
    for row in rows:
        require(isinstance(row, dict) and type(row.get("index")) is int and row["index"] in allowed_indices,
                "Arrival identity has an unexpected fixture index")
        index = row["index"]
        expected = str(uuid.UUID(bytes=bytes([0x52, 0x45, 0x53, 0x46, 0, 0, 0, 7]) + index.to_bytes(8, "big"))).upper()
        require(row.get("id") == expected, "Arrival request UUID does not match its fixture index")
        actual.append(index)
    require(actual == sorted(set(actual)), "Arrival request identities are duplicated or unsorted")
    return actual


@contextmanager
def timing_environment(timed):
    previous = os.environ.get(TIMING_ENV)
    os.environ[TIMING_ENV] = "1" if timed else "0"
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop(TIMING_ENV, None)
        else:
            os.environ[TIMING_ENV] = previous


def source_identity():
    return runtime.runtime_source_identity() | {Path(__file__).name: app.path_hash(Path(__file__))}


def snapshot_time(report, snapshot):
    matches = [sample for sample in report["samples"]
               if sample.get("monotonic_seconds") == snapshot.get("runner_collector_sample_monotonic_seconds")]
    require(len(matches) == 1, "Arrival snapshot lacks one authenticated kernel boundary")
    sample = matches[0]
    require(all(sample.get(key) == report["owned_identity"][key] for key in ("process_id", "birth_time_us")),
            "Arrival snapshot identity differs from the owned process")
    clocks = report["runtime"]
    offset = sum(clocks[name]["absolute_minus_monotonic_seconds"] for name in ("mach_clock_start", "mach_clock_end")) / 2
    return sample["mach_absolute_seconds"] - offset


def validate_quiet(first, last):
    for snapshot in (first, last):
        require(snapshot.get("active_requests") == 0, "Arrival quiet checkpoint still has active requests")
        graphics = snapshot["graphics_diagnostics"]
        require(graphics["roles"]["rail_decorations"]["live"] == 0
                and graphics["retained_twinkles"]["live_instances"] == 0,
                "Arrival quiet checkpoint retains active effects")
    for field in QUIET_FIELDS:
        require(type(first.get(field)) is int and type(last.get(field)) is int and first[field] == last[field],
                f"Arrival effects continued during quiet interval: {field}")


def validate_replay(report, mode, timed):
    require(not report["errors"] and len(report["episodes"]) == 3, "Arrival replay capture is incomplete")
    require(report.get("memory_validation", {}).get("problems") == [], "Arrival replay final accounting is invalid")
    memory.validate_sample_identities(report["samples"], report["owned_identity"])
    ready = app.authenticated_cpu_ready(report["samples"], report["events"])
    require(all(ready[key] == report["owned_identity"][key] for key in ("process_id", "birth_time_us")),
            "Arrival replay readiness differs from its owned identity")
    exits = [event for event in report["events"] if event.get("type") == "exited"]
    require(len(exits) == 1 and type(exits[0].get("status")) is int and exits[0]["status"] == 0
            and exits[0].get("final_sample") == report["samples"][-1] and report["samples"][-1].get("phase") == "final",
            "Arrival replay lacks a clean authenticated final exit")
    points = report["runtime"]["checkpoints"]
    require(len(points) >= 2, "Arrival replay lacks native visibility checkpoints")
    times = [snapshot_time(report, point["snapshot"]) for point in points]
    require(all(0 < right - left <= 2 for left, right in zip(times, times[1:])), "Arrival visibility coverage has a gap")
    all_indices = [cycle * 32 + ordinal for cycle in CYCLES for ordinal in (0, 1)]
    previous = []
    snapshots = [report["ready"]["snapshot"]] + [point["snapshot"] for point in points]
    contracts = []
    for index, snapshot in enumerate(snapshots):
        validate_timing(snapshot, timed)
        if index:
            timing_delta(snapshots[index - 1], snapshot, timed)
        graphics = memory.validate_graphics(snapshot, mode)
        contracts.append((graphics.get("runtime_feature_contract"), graphics.get("arrival_backend"),
                          graphics.get("chart_publication_interval_seconds")))
        actual = validate_identities(snapshot, all_indices)
        require(set(previous) <= set(actual), "Arrival identities disappeared during the replay")
        previous = actual
    require(all(contract == contracts[0] for contract in contracts), "Arrival graphics feature/backend/cadence metadata changed")
    require(validate_identities(report["ready"]["snapshot"], all_indices) == [] and previous == all_indices,
            "Arrival replay did not execute six unique requests")
    for envelope in report["events"]:
        event = envelope.get("event", {}) if envelope.get("type") == "app_event" else {}
        if isinstance(event.get("snapshot"), dict):
            validate_identities(event["snapshot"], all_indices)
    for point in points:
        snapshot = point["snapshot"]
        require(point.get("resource_sample") in report["samples"]
                and point["resource_sample"].get("monotonic_seconds") == snapshot.get("runner_collector_sample_monotonic_seconds"),
                "Arrival visibility checkpoint resource sample differs from its snapshot boundary")
        require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True,
                "Arrival replay windows were not both visible")
        require(type(snapshot.get("active_requests")) is int and 0 <= snapshot["active_requests"] <= 2,
                "Arrival replay active request count is invalid")
    initial_start = next((point["snapshot"] for point in points if point["label"] == "initial-quiet-start"), None)
    initial_end = next((point["snapshot"] for point in points if point["label"] == "initial-quiet-end"), None)
    require(initial_start is not None and initial_end is not None
            and snapshot_time(report, initial_end) - snapshot_time(report, initial_start) >= 1,
            "First arrival lacks a complete quiet interval")
    validate_quiet(initial_start, initial_end)
    windows = {}
    for ordinal, episode in enumerate(report["episodes"], 1):
        require(episode["ordinal"] == ordinal and episode["cycle"] == CYCLES[ordinal - 1]
                and episode["specification"] == STAGE, "Arrival episode order or workload changed")
        before, after, completion = (episode[key] for key in ("before", "after", "completion_end"))
        if ordinal > 1:
            require(snapshot_time(report, report["episodes"][ordinal - 2]["quiet_end"]) <= snapshot_time(report, before),
                    "Arrival episodes overlap their preceding quiet proof")
        acknowledgment, status = episode["fixture_start"], episode["fixture_status"]
        app.validate_fixture_start(STAGE, acknowledgment)
        require(app.validate_workload(STAGE, status, before, after, acknowledgment) == WORK, "Arrival episode work differs")
        expected_indices = [episode["cycle"] * 32 + offset for offset in (0, 1)]
        require(acknowledgment["expected_request_indices"] == expected_indices, "Arrival episode fixture identities changed")
        require(validate_identities(before, all_indices) == all_indices[:2 * (ordinal - 1)]
                and validate_identities(after, all_indices) == all_indices[:2 * ordinal],
                "Arrival episode did not add exactly its two unique identities")
        streams = status["timing"]["streams"]
        began = min(stream["first_write_started_monotonic_seconds"] for stream in streams)
        terminal = max(stream["terminal_flush_finished_monotonic_seconds"] for stream in streams)
        end = snapshot_time(report, completion)
        require(snapshot_time(report, before) < began < began + 2 < terminal
                and terminal + 3 <= end, "Arrival episode lacks its complete arrival and completion windows")
        relevant = [(point, timestamp) for point, timestamp in zip(points, times)
                    if began + 2 <= timestamp < terminal]
        require(relevant and relevant[0][0]["snapshot"].get("active_requests") == 2,
                "Arrival episode lacks active post-arrival evidence")
        arrival_end = relevant[0][0]["snapshot"]
        for point, timestamp in zip(points, times):
            if began + 1 < timestamp < began + 4:
                require(point["snapshot"].get("active_requests") == 2 and point["snapshot"].get("partial_output_tokens", 0) > 0,
                        "Arrival episode lost active stream progress")
        if mode == memory.METAL_ARRIVAL_MODE:
            first, last = memory.metal_arrival_contract(before, mode), memory.metal_arrival_contract(arrival_end, mode)
            require(last["counters"]["metal_arrival_submissions"] > first["counters"]["metal_arrival_submissions"],
                    "Arrival phase did not submit Metal frames")
        else:
            require(arrival_end["rail_frame_clock_ticks"] > before["rail_frame_clock_ticks"]
                    and arrival_end["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"]
                    > before["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"], "Arrival phase did not draw Canvas effects")
        require(completion["rail_frame_clock_ticks"] > after["rail_frame_clock_ticks"]
                and completion["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"]
                > after["graphics_diagnostics"]["roles"]["rail_decorations"]["draws"], "Arrival episode did not preserve completion drawing")
        quiet_first, quiet_last = episode["quiet_start"], episode["quiet_end"]
        require(snapshot_time(report, quiet_last) - snapshot_time(report, quiet_first) >= 1,
                "Arrival quiet proof is shorter than one second")
        validate_quiet(quiet_first, quiet_last)
        episode["runtime_work"] = runtime.validate_runtime_work(before, completion, mode)
        episode["timing"] = {"arrival": timing_delta(before, arrival_end, timed),
                             "whole_episode": timing_delta(before, completion, timed),
                             "quiet": timing_delta(quiet_first, quiet_last, timed)}
        if timed:
            require(episode["timing"]["quiet"]["metrics"]["metal_frame_callback"]["calls"] == 0,
                    "Timed Metal draw callbacks continued during a quiet interval")
        episode["work_counters"] = app.cpu_work_counter_diagnostic(report["samples"], report["events"],
            before["runner_collector_sample_monotonic_seconds"], completion["runner_collector_sample_monotonic_seconds"]) | {
            "interval_scope": "Exact before-episode through completion-end control boundaries; not the interpolated two-second CPU window",
            "acceptance_eligible": False}
        windows[f"episode-{ordinal}-arrival"] = {"start_monotonic_seconds": began, "end_monotonic_seconds": began + 2}
        windows[f"episode-{ordinal}-whole"] = {"start_monotonic_seconds": snapshot_time(report, before), "end_monotonic_seconds": end}
    first, last = report["episodes"][0]["before"], report["episodes"][-1]["completion_end"]
    windows["whole_replay"] = {"start_monotonic_seconds": snapshot_time(report, first), "end_monotonic_seconds": snapshot_time(report, last)}
    report["phase_windows"] = windows
    report["phase_cpu"] = runtime.phase_cpu(report, windows)
    for metrics in report["phase_cpu"].values():
        metrics["acceptance_eligible"] = not timed
    report["timing_setup"] = timing_delta(report["ready"]["snapshot"], first, timed)
    report["timing_lifetime"] = timing_delta(report["ready"]["snapshot"], report["checkpoints"][-1]["snapshot"], timed)
    if timed:
        for name in ("profile_preparation", "profile_create", "metal_surface_setup", "metal_first_drawable",
                     "metal_descriptor_update", "metal_descriptor_upload", "metal_frame_callback", "metal_frame_encode", "metal_frame_submit"):
            require(report["timing_lifetime"]["metrics"][name]["calls"] > 0, f"Timed Metal replay did not execute {name}")
    closed = [next((point["snapshot"] for point in report["checkpoints"] if point["label"] == label), None)
              for label in ("closed-start", "closed-final")]
    require(all(isinstance(snapshot, dict) and snapshot.get("dashboard_visible") is False
                and snapshot.get("popover_visible") is False for snapshot in closed), "Arrival replay lacks both closed checkpoints")
    require(snapshot_time(report, closed[1]) - snapshot_time(report, closed[0]) >= 1,
            "Arrival closed cancellation proof is shorter than one second")
    validate_quiet(*closed)
    report["timing_closed"] = timing_delta(*closed, timed)
    if timed:
        require(report["timing_closed"]["metrics"]["metal_frame_callback"]["calls"] == 0,
                "Timed Metal draw callbacks continued after both windows closed")
    report["cpu_acceptance_eligible"] = not timed
    report["cpu_targets"] = {name: {"evaluated": not timed, "limit_percent": 5.0,
        "within_limit": metrics["rolling_1s_percent"] <= 5.0 if not timed else None,
        "scope": "Arrival diagnostic interval only; not the full resource gate"}
        for name, metrics in report["phase_cpu"].items() if name.endswith("-arrival") or name == "whole_replay"}
    report["regression_passed"] = False
    return report


class ArrivalDiagnostic(memory.MemoryDiagnostic):
    def __init__(self, output, deadline, mode, timed):
        self.timed = timed
        super().__init__(output, deadline, mode, no_native_inspection=True)
        self.tracking = False
        self.next_checkpoint = None
        self.traffic_start = self.traffic_end = None
        self.report.update(kind="arrival-replay-case", timing_enabled=timed, episodes=[],
                           runtime={"profiled": timed, "checkpoints": []})
        self.report["base_driver_sha256"] = self.report["driver_sha256"]
        self.report["driver_sha256"] = app.path_hash(Path(__file__))

    def create_collector(self, *args, **kwargs):
        with timing_environment(self.timed):
            return runtime.RuntimeCollector(*args, owner=self, **kwargs)

    def validate_control_snapshot(self, snapshot):
        super().validate_control_snapshot(snapshot)
        validate_timing(snapshot, self.timed)

    def record(self, label, active=None):
        self.verify_identity()
        snapshot = self.collector.snapshot()
        self.verify_identity()
        matches = [sample for sample in self.collector.samples
                   if sample.get("monotonic_seconds") == snapshot.get("runner_collector_sample_monotonic_seconds")]
        require(len(matches) == 1 and all(matches[0].get(key) == self.identity[key] for key in ("process_id", "birth_time_us")),
                "Arrival checkpoint lacks an owned kernel boundary")
        point = {"label": label, "snapshot": snapshot, "resource_sample": matches[0], "python_monotonic_seconds": time.monotonic()}
        self.report["checkpoints"].append(point)
        if self.tracking:
            self.report["runtime"]["checkpoints"].append(point)
        self.save()
        require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True,
                "Arrival replay windows are not both natively visible")
        require(type(snapshot.get("active_requests")) is int and 0 <= snapshot["active_requests"] <= 2,
                "Arrival checkpoint active request count is invalid")
        require(active is None or snapshot.get("active_requests") == active, "Arrival checkpoint has the wrong active stream count")
        self.validate_control_snapshot(snapshot)
        return snapshot

    def poll_runtime(self):
        now = time.monotonic()
        if not self.tracking or self.next_checkpoint is None or now < self.next_checkpoint:
            return
        active = None if self.traffic_start is not None else 0
        if self.traffic_start is not None and self.traffic_start + 1 < now < self.traffic_end - .25:
            active = 2
        self.next_checkpoint = now + 1
        snapshot = self.record("visibility-progress", active)
        if active == 2:
            require(snapshot.get("partial_output_tokens", 0) > 0, "Arrival traffic did not advance token output")

    def perform(self, paths, provenance, identity):
        self.report.update(production_provenance=provenance, measurement_identity=identity,
            binary_identity={key: {"path": str(path), "sha256": app.path_hash(path)} for key, path in paths.items()})
        self.fixture, upstream = app.launch_fixture(self.output, timeout=self.deadline.remaining(5))
        directory = self.output / "owned-app"
        directory.mkdir()
        configuration = {"upstream_url": upstream, "history": "populated", "protocol_version": 1,
                         "logging_enabled": False, "fixture_ending_at_epoch": time.time(), "graphics_mode": self.graphics_mode}
        write_json(directory / "configuration.json", configuration)
        self.collector = self.create_collector(paths["collector"], paths["app"], configuration, {}, directory, self.deadline,
            {"external_trace": True, "provenance": provenance, "fixture_schema_version": 2})
        ready = self.collector.ready()
        self.report["ready"] = ready
        seed = ready.get("snapshot", {})
        require(ready.get("fixture_schema_version") == 2
                and ready.get("fixture_equivalence_sha256") == provenance.get("fixture_equivalence_sha256", {}).get("populated")
                and isinstance(ready.get("fixture_equivalence_sha256"), str), "Arrival populated fixture differs from provenance")
        require(seed.get("history_verified") is True and seed.get("history") == "populated"
                and (seed.get("seed_persistent_requests"), seed.get("seed_raw_requests"), seed.get("seed_tool_events")) == (19000, 256, 38512),
                "Arrival populated history dimensions differ")
        self.validate_control_snapshot(seed)
        self.identity = memory.authenticate_ready(self.collector, self.validate_control_snapshot)
        self.report["owned_identity"] = self.identity
        logging = self.command("set_logging", enabled=False)
        require(logging.get("logging_enabled") is False and logging.get("drained") is True, "Arrival logging did not disable and drain")
        self.command("show_dashboard")
        self.command("show_popover")
        self.tracking = True
        self.report["runtime"]["mach_clock_start"] = runtime._mach_clock()
        self.next_checkpoint = time.monotonic() + 1
        initial = self.record("initial-quiet-start", 0)
        self.collector.wait_until(time.monotonic() + 1.1)
        validate_quiet(initial, self.record("initial-quiet-end", 0))
        for ordinal, cycle in enumerate(CYCLES, 1):
            episode = {"ordinal": ordinal, "cycle": cycle, "specification": dict(STAGE), "validated": False}
            self.report["episodes"].append(episode)
            episode["before"] = self.record(f"episode-{ordinal}-before", 0)
            self.traffic_start = time.monotonic()
            self.traffic_end = self.traffic_start + EPISODE_SECONDS
            episode["fixture_start"] = app.fixture_request(upstream, "/control/start", self.deadline, {
                "proxy_url": ready["proxy_url"], "duration_seconds": EPISODE_SECONDS,
                "rate_hz": 200, "concurrency": 2, "cycle": cycle})
            app.validate_fixture_start(STAGE, episode["fixture_start"])
            self.save()
            self.collector.wait_until(self.traffic_end)
            episode["fixture_status"] = app.completed_status(self.collector, upstream, self.deadline)
            episode["after"] = self.record(f"episode-{ordinal}-traffic-end", 0)
            self.traffic_start = self.traffic_end = None
            episode["validated_work"] = app.validate_workload(STAGE, episode["fixture_status"], episode["before"],
                                                              episode["after"], episode["fixture_start"])
            episode["validated"] = True
            self.report["workload"] = episode  # Inherited final accounting validates this explicitly labeled last episode.
            self.collector.wait_until(time.monotonic() + 4.01)
            episode["completion_end"] = self.record(f"episode-{ordinal}-completion-end", 0)
            episode["quiet_start"] = episode["completion_end"]
            self.collector.wait_until(time.monotonic() + 1.1)
            episode["quiet_end"] = self.record(f"episode-{ordinal}-quiet-end", 0)
            validate_quiet(episode["quiet_start"], episode["quiet_end"])
            self.save()
        self.tracking = False
        self.command("close_popover")
        self.command("close_dashboard")
        self.collector.wait_until(time.monotonic() + 1)
        self.checkpoint("closed-start", False, False, 0)
        self.collector.wait_until(time.monotonic() + 1.1)
        self.checkpoint("closed-final", False, False, 0)
        self.report["runtime"]["mach_clock_end"] = runtime._mach_clock()
        self.collector.finish()


def capture_case(output, mode, timed, paths, provenance, identity, deadline):
    output.mkdir()
    diagnostic = ArrivalDiagnostic(output, deadline, mode, timed)
    try:
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
            diagnostic.perform(paths, provenance, identity)
    except ERRORS + (KeyboardInterrupt,) as error:
        diagnostic.report["errors"].append(str(error) or "Interrupted")
    finally:
        try:
            with deadline.interrupt_at(deadline.end - .5):
                diagnostic.cleanup()
        except ERRORS + (KeyboardInterrupt,) as error:
            diagnostic.report["errors"].append("Arrival cleanup: " + (str(error) or "Interrupted"))
    report = diagnostic.report
    if report.get("workload_cpu", {}).get("available"):
        report["workload_cpu"].update(interval="Episode3 before-traffic through its traffic acknowledgment; five-second fixture plus start/drain overhead, excludes completion and inter-episode gaps",
                                      acceptance_eligible=not timed, gate_evaluated=False)
    if timed:
        report["timed_last_episode_cpu"] = report.get("workload_cpu")
        if report["timed_last_episode_cpu"] is not None:
            report["timed_last_episode_cpu"]["acceptance_eligible"] = False
            report["timed_last_episode_cpu"]["within_limit"] = None
        report["workload_cpu"] = {"available": False, "gate_evaluated": False, "reason": "Scoped arrival timing perturbs execution"}
    try:
        validate_replay(report, mode, timed)
        report["status"] = "diagnostic_captured"
    except ERRORS as error:
        report["errors"].append(str(error))
        report["status"] = "diagnostic_incomplete"
        report["cpu_acceptance_eligible"] = False
        if isinstance(report.get("workload_cpu"), dict):
            report["workload_cpu"]["acceptance_eligible"] = False
        for metrics in report.get("phase_cpu", {}).values():
            metrics["acceptance_eligible"] = False
        for target in report.get("cpu_targets", {}).values():
            target.update(evaluated=False, within_limit=None)
    write_json(output / "arrival-case.json", report)
    return report


def summary(report):
    lines = ["# Matched arrival episodes", "", f"Status: {report['status']}. No full resource gate is evaluated.", "",
             "| Case | Episode | First2s mean CPU | First2s max1s CPU | Arrival ≤5% | Whole replay mean / max CPU | Replay ≤5% | Timing |",
             "|---|---:|---:|---:|---|---:|---|---|"]
    for case in report["cases"]:
        phases = (case.get("phase_cpu") or {}) if case.get("status") == "diagnostic_captured" else {}
        whole = phases.get("whole_replay", {})
        def cpu(value, key):
            return f"{value[key]:.4f}%" if key in value else "unavailable"
        def target(name):
            if case.get("status") != "diagnostic_captured":
                return "unqualified"
            value = (case.get("cpu_targets") or {}).get(name, {})
            return str(value["within_limit"]).lower() if value.get("evaluated") is True else "not evaluated"
        for ordinal in range(1, 4):
            arrival = phases.get(f"episode-{ordinal}-arrival", {})
            lines.append(f"| {case['label']} | {ordinal} | {cpu(arrival, 'average_cpu_percent')} | {cpu(arrival, 'rolling_1s_percent')} | "
                         f"{target(f'episode-{ordinal}-arrival')} | {cpu(whole, 'average_cpu_percent')} / {cpu(whole, 'rolling_1s_percent')} | "
                         f"{target('whole_replay')} | {'unqualified capture' if case.get('status') != 'diagnostic_captured' else 'perturbed; ineligible' if case['timed'] else 'off'} |")
    lines += ["", "Compare matching episode ordinals across cases. Histories, effect seeds, colors, and shapes change across ordinals; first-minus-repeat is not an isolated first-use cost.",
              "Whole replay includes the gaps between episodes; first2s starts at the fixture's first source write. Timing scopes can overlap and must not be summed. GPU execution is unmeasured."]
    for case in report["cases"]:
        if not case["timed"]:
            continue
        lines += ["", "| Timed acknowledged interval | Inclusive scope | Calls | Calling-thread CPU ms | Wall ms | Cumulative max CPU ms | Cumulative max wall ms |",
                  "|---|---|---:|---:|---:|---:|---:|"]
        stages = [("visible setup", case.get("timing_setup"))]
        for episode in case.get("episode_timings", []):
            stages.extend((f"episode{episode['ordinal']} {name}", episode["timing"].get(name)) for name in ("arrival", "whole_episode"))
        for label, stage in stages:
            if not stage:
                continue
            for metric in METRICS:
                values = stage["metrics"][metric]
                maxima = stage["cumulative_max_after"][metric]
                lines.append(f"| {label} | {metric} | {values['calls']} | {values['cpu_ns']/1e6:.6f} | {values['wall_ns']/1e6:.6f} | "
                             f"{maxima['max_cpu_ns']/1e6:.6f} | {maxima['max_wall_ns']/1e6:.6f} |")
        lines += ["", "All timing scopes are inclusive/nonadditive and cover only their calling threads. Cumulative maxima are not episode maxima. "
                  "Arrival timing spans exact acknowledged checkpoints around the2s CPU window. Descriptor upload measures CPU shared-buffer allocation/copy; Canvas arrival draw measures command construction. Driver work outside measured scopes is not attributed."]
    if "baseline_drift" in report:
        lines += ["", "Baseline drift: " + ("within existing tolerance" if report["baseline_drift"]["comparison_conclusive"] else "INCONCLUSIVE comparison")]
    lines += ["", *report.get("errors", [])]
    return "\n".join(lines) + "\n"


def parser():
    value = argparse.ArgumentParser(description=__doc__)
    for name in ("app-binary", "test-bundle", "collector-binary", "provenance"):
        value.add_argument("--" + name, type=Path, required=True)
    value.add_argument("--output-dir", type=Path)
    return value


def _run(args, deadline):
    started = time.monotonic()
    output = (args.output_dir or app.ROOT / ".performance-results" /
              ("arrival-replay-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S-") + secrets.token_hex(4))).resolve()
    report = {"kind": "matched-arrival-replay", "status": "diagnostic_incomplete", "deadline_seconds": MAX_SECONDS,
              "regression_passed": False, "cases": [], "errors": []}
    created = False
    try:
        require(sys.platform == "darwin", "Arrival replay requires macOS")
        require(not output.exists(), "Never overwrite arrival replay artifacts")
        require(app.ROOT not in output.parents or app.ROOT / ".performance-results" in output.parents,
                "In-repository arrival artifacts must remain ignored")
        output.mkdir(parents=True)
        created = True
        sources = source_identity()
        report["arrival_source_identity"] = sources
        capsule = output / "measurement-source"
        capsule.mkdir()
        for name, digest in sources.items():
            shutil.copyfile(Path(__file__).with_name(name), capsule / name)
            require(app.path_hash(capsule / name) == digest, "Arrival source changed while archiving")
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
            paths, provenance, identity = memory.validate_products(args)
            report.update(binary_identity={name: app.path_hash(path) for name, path in paths.items()}, measurement_identity=identity)
        for label, mode, timed in CASES:
            require(deadline.remaining() >= CASE_SECONDS + 3, "Insufficient budget for a complete arrival replay case")
            require(source_identity() == sources and all(app.path_hash(path) == report["binary_identity"][name] for name, path in paths.items()),
                    "Arrival sources or frozen products changed")
            print(f"Arrival replay {len(report['cases']) + 1}/4: {label}; timing={'on' if timed else 'off'}; remaining {deadline.remaining():.1f}s", flush=True)
            with deadline.interrupt_at(deadline.end - 1):
                case = capture_case(output / label, mode, timed, paths, provenance, identity,
                                    runtime.RuntimeDeadline(CASE_SECONDS, cleanup_reserve=8))
            path = output / label / "arrival-case.json"
            row = {"label": label, "mode": mode, "timed": timed, "status": case["status"], "phase_cpu": case.get("phase_cpu"),
                   "report_path": str(path), "report_sha256": app.path_hash(path),
                   "cpu_acceptance_eligible": case["status"] == "diagnostic_captured" and not timed,
                   "cpu_targets": case.get("cpu_targets"), "timing_setup": case.get("timing_setup"),
                   "episode_timings": [{"ordinal": episode["ordinal"], "timing": episode["timing"]}
                                       for episode in case["episodes"] if "timing" in episode]}
            report["cases"].append(row)
            write_json(output / "arrival-report.json", report)
            require(case["status"] == "diagnostic_captured", f"Arrival case {label} is incomplete: {case['errors']}")
        drift = {}
        for phase in ("whole_replay", "episode-1-arrival", "episode-2-arrival", "episode-3-arrival"):
            bracket = [{"phase_cpu": {"whole_contiguous_runtime": report["cases"][index]["phase_cpu"][phase]}} for index in (0, 2)]
            drift[phase] = runtime.baseline_drift(bracket)
        report["baseline_drift"] = {"comparison_conclusive": all(value["comparison_conclusive"] for value in drift.values()), "phases": drift}
        require(source_identity() == sources and all(app.path_hash(path) == report["binary_identity"][name] for name, path in paths.items()),
                "Arrival measurement sources or frozen products changed before finalization")
        require(time.monotonic() < deadline.end - 1, "Arrival replay exceeded its deadline")
        report["status"] = "diagnostic_captured"
    except ERRORS + (KeyboardInterrupt,) as error:
        report["errors"].append(str(error) or "Interrupted")
    finally:
        report["elapsed_seconds"] = time.monotonic() - started
        if created:
            try:
                with deadline.interrupt_at(deadline.end):
                    desired = report["status"]
                    report["status"] = "diagnostic_incomplete"
                    write_json(output / "arrival-report.json", report)
                    report["status"] = desired
                    (output / "SUMMARY.md").write_text(summary(report))
                    write_json(output / "arrival-report.json", report)
            except ERRORS as error:
                report["status"] = "diagnostic_incomplete"
                report["errors"].append("Arrival artifact finalization: " + str(error))
    print(f"Arrival replay: {report['status']}; {output}", flush=True)
    return 0 if report["status"] == "diagnostic_captured" else 1


def run(argv=None):
    args = parser().parse_args(argv)
    deadline = runtime.RuntimeDeadline(MAX_SECONDS)
    try:
        with deadline.interrupt_at(deadline.end):
            return _run(args, deadline)
    except TimeoutError as error:
        print(str(error), flush=True)
        return 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, memory.interrupted)
    raise SystemExit(run())
