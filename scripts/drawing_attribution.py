"""Fresh-process drawing attribution; measured memory, never a resource-gate pass.

Run through run_performance_checks.py drawing with explicit Release products.
Each case uses the same native window and applies deterministic drawing commands.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import time

import app_performance as app
import memory_attribution as memory
from run_performance_checks import interrupted, load_json, number, require, write_json


BACKENDS = ("image-renderer", "canvas", "core-graphics", "core-graphics-unhosted", "bitmap-layer")
PRIMITIVES = ("empty", "line", "solid-fill", "linear-gradient", "radial-gradient", "text", "clipped-line",
              "layer-line", "with-cg-line", "chart-path")
DEFAULT_CASES = ("canvas:empty", "canvas:line", "core-graphics:line")
DEADLINE_SECONDS = 180
REDRAW_COUNT = 100
MAX_ARTIFACT_BYTES = 16 * 1024 * 1024
MAX_REQUESTED_BITMAP_BYTES = 32 * 1024 * 1024
BITMAP_FIELDS = ("bitmap_update_layer_calls", "bitmap_unexpected_native_draw_calls", "bitmap_failures",
                 "bitmap_current_requested_scratch_bytes", "bitmap_peak_requested_scratch_bytes",
                 "bitmap_current_requested_image_bytes", "bitmap_peak_requested_image_bytes", "bitmap_images_created")


def parse_case(value):
    parts = value.split(":")
    if len(parts) != 2 or parts[0] not in BACKENDS or parts[1] not in PRIMITIVES:
        raise argparse.ArgumentTypeError("Drawing cases must be BACKEND:PRIMITIVE using supported names")
    return value


def parse_settle_seconds(value):
    try:
        seconds = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("Settling time must be between 1 and 5 seconds") from error
    if not 1 <= seconds <= 5:
        raise argparse.ArgumentTypeError("Settling time must be between 1 and 5 seconds")
    return seconds


class DrawingDeadline:
    def __init__(self, seconds=DEADLINE_SECONDS, clock=time.monotonic):
        require(type(seconds) in (int, float) and 10 < seconds <= DEADLINE_SECONDS,
                "Drawing diagnostic deadline must be at most 180 seconds")
        self.clock = clock
        self.end = clock() + seconds
        self.cleanup_reserve = 10

    def remaining(self, maximum=None):
        left = self.end - self.clock() - self.cleanup_reserve
        if left <= 0:
            raise TimeoutError("The 180-second drawing diagnostic reached its cleanup reserve")
        return min(left, maximum) if maximum is not None else left

    @contextmanager
    def interrupt_at(self, end):
        def expired(_signal, _frame):
            raise TimeoutError("The 180-second drawing diagnostic deadline expired")
        duration = end - self.clock()
        require(duration > 0, "No time remains in the drawing diagnostic deadline")
        previous = signal.getsignal(signal.SIGALRM)
        signal.signal(signal.SIGALRM, expired)
        old_timer = signal.setitimer(signal.ITIMER_REAL, duration)
        try:
            yield
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
            if old_timer[0]:
                signal.setitimer(signal.ITIMER_REAL, *old_timer)


def validate_snapshot(snapshot, case, previous=None, closed=False):
    backend, primitive = case.split(":")
    require(isinstance(snapshot, dict) and type(snapshot.get("schema_version")) is int
            and snapshot["schema_version"] == 1, "Missing or incompatible drawing snapshot")
    require(snapshot.get("backend") == backend and snapshot.get("primitive") == primitive,
            "Drawing snapshot case identity differs from the requested case")
    require(snapshot.get("uses_swiftui_host") is (backend != "core-graphics-unhosted"),
            "Drawing backend did not acknowledge the expected SwiftUI hosting configuration")
    require(snapshot.get("closed") is closed and snapshot.get("window_visible") is (not closed),
            "Drawing window visibility/closed state was not confirmed by the native window")
    number(snapshot.get("window_number"), "drawing.window_number", integer=True, minimum=0 if closed else 1)
    require(type(snapshot.get("draw_enabled")) is bool, "Drawing enabled acknowledgment must be Boolean")
    for field in ("draw_calls", "nonempty_draw_calls", "requested_frames", "revision",
                  "acknowledged_revision", "acknowledged_frames", "duplicate_draw_calls"):
        number(snapshot.get(field), "drawing." + field, integer=True)
    require(snapshot["draw_calls"] >= 1, "Native backend did not draw its initial empty frame")
    require(snapshot["requested_frames"] == snapshot["revision"] == snapshot["acknowledged_revision"]
            == snapshot["acknowledged_frames"], "A requested drawing revision was not acknowledged")
    require(snapshot["nonempty_draw_calls"] <= snapshot["draw_calls"], "Nonempty draw count exceeds callback count")
    if primitive == "empty":
        require(snapshot["nonempty_draw_calls"] == 0, "Empty drawing control executed a nonempty operation")
    for field in ("content_width_points", "content_height_points", "backing_scale"):
        number(snapshot.get(field), "drawing." + field, minimum=0.01)
    require(snapshot["content_width_points"] == 664 and snapshot["content_height_points"] == 357,
            "Drawing window geometry differs from the controlled 664 by 357 point viewport")
    if previous is not None:
        for field in ("content_width_points", "content_height_points", "backing_scale"):
            require(snapshot[field] == previous[field], "Drawing geometry or backing scale changed during the case")
        for field in ("draw_calls", "nonempty_draw_calls", "requested_frames", "revision",
                      "acknowledged_revision", "acknowledged_frames", "duplicate_draw_calls"):
            require(snapshot[field] >= previous[field], "Drawing callback/request counter moved backwards")
        require(snapshot["window_number"] == previous["window_number"], "Drawing window identity changed")
    graphics = memory.validate_graphics(snapshot, "normal")
    require(graphics["available"], "Drawing probe requires graphics lifecycle counters")
    counters = graphics["counters"]
    if backend != "image-renderer":
        require(counters["peak_live_renderers"] == 0
                and all(role["renderer_creations"] == 0 for role in counters["roles"].values()),
                "A comparison backend unexpectedly created an ImageRenderer")
    elif not closed:
        require(counters["live_renderers"] >= 1, "ImageRenderer backend did not instantiate the production wrapper")
    if closed:
        require(snapshot["draw_enabled"] is False and snapshot.get("released_window_live") is False
                and snapshot.get("released_host_live") is False and snapshot.get("released_content_live") is False,
                "Native drawing window, host, or content view was not released")
        require(counters["live_canvases"] == 0 and counters["live_renderers"] == 0,
                "Drawing content remains owned after releasing the window")
    validate_backend_storage(snapshot, backend, previous)
    return snapshot


def validate_backend_storage(snapshot, backend, previous=None):
    """Validate requested CPU buffers; these counters do not measure GPU memory."""
    for field in BITMAP_FIELDS:
        number(snapshot.get(field), "drawing." + field, integer=True)
    require(snapshot["bitmap_failures"] == 0 and snapshot["bitmap_unexpected_native_draw_calls"] == 0,
            "Bitmap drawing failed or unexpectedly used NSView.draw instead of updateLayer")
    if backend != "bitmap-layer":
        require(all(snapshot[field] == 0 for field in BITMAP_FIELDS),
                "A non-bitmap backend unexpectedly allocated bitmap storage or used bitmap callbacks")
        return
    require(snapshot["bitmap_update_layer_calls"] == snapshot["draw_calls"]
            == 1 + snapshot["acknowledged_frames"] + snapshot["duplicate_draw_calls"],
            "Bitmap updateLayer and acknowledged draw callback counts do not reconcile")
    for buffer in ("scratch", "image"):
        current, peak = (snapshot[f"bitmap_{phase}_requested_{buffer}_bytes"] for phase in ("current", "peak"))
        require(current <= peak <= MAX_REQUESTED_BITMAP_BYTES,
                "Requested bitmap buffer exceeds its 32 MiB bound or its recorded peak")
        if snapshot["closed"]:
            require(current == 0, "Requested bitmap storage remained live after close")
    if snapshot["requested_frames"] == 0:
        require(snapshot["bitmap_images_created"] == 0
                and all(snapshot[field] == 0 for field in BITMAP_FIELDS if "bytes" in field),
                "Bitmap image storage was allocated before the initial drawing boundary")
    else:
        require(snapshot["requested_frames"] <= snapshot["bitmap_images_created"] < snapshot["draw_calls"],
                "Bitmap image creation count does not cover every requested frame")
        require(snapshot["bitmap_peak_requested_scratch_bytes"] > 0
                and snapshot["bitmap_peak_requested_image_bytes"] > 0,
                "Bitmap drawing did not acknowledge its bounded CPU buffers")
        if not snapshot["closed"]:
            require(snapshot["bitmap_current_requested_image_bytes"] > 0,
                    "Bitmap drawing did not retain the current layer image")
    if previous is not None:
        for field in ("bitmap_update_layer_calls", "bitmap_images_created", "bitmap_peak_requested_scratch_bytes",
                      "bitmap_peak_requested_image_bytes"):
            require(snapshot[field] >= previous[field], "Bitmap callback, allocation, or peak counter moved backwards")


def validate_draw_progress(before, after, count, case):
    require(after["draw_enabled"] is True, "Probe did not enable drawing")
    require(after["requested_frames"] - before["requested_frames"] == count,
            "Probe did not acknowledge exactly the requested frame count")
    require(after["draw_calls"] - before["draw_calls"] >= count,
            "Drawing callbacks did not advance for every requested frame")
    if not case.endswith(":empty"):
        require(after["nonempty_draw_calls"] - before["nonempty_draw_calls"] >= count,
                "Nonempty primitive did not execute for every requested frame")


def validate_command_state(before, after, command):
    if before is None or command not in ("snapshot", "close", "shutdown"):
        return
    require(after["requested_frames"] == before["requested_frames"],
            f"Drawing revisions advanced during the {command} command")
    if command == "snapshot":
        require(after["draw_enabled"] is before["draw_enabled"],
                "A snapshot command changed whether drawing was enabled")


def boundary_sample(collector, response, identity):
    stamp = response.get("collector_control_after_seconds")
    require(type(stamp) in (int, float), "Drawing acknowledgment lacks its kernel boundary")
    matches = [sample for sample in collector.samples if sample.get("monotonic_seconds") == stamp]
    require(len(matches) == 1, "Drawing acknowledgment lacks one unique kernel boundary")
    sample = matches[0]
    require(all(type(sample.get(key)) is int and sample[key] == identity[key]
                for key in ("process_id", "birth_time_us")), "Drawing boundary process identity differs")
    return sample


def source_provenance(paths, output, deadline):
    """Record exact inputs, without claiming a build/source association we cannot prove."""
    sources = [app.ROOT / "Package.swift", *app.ROOT.glob("Sources/**/*.swift"),
               *app.ROOT.glob("scripts/*.py")]
    manifest = {str(path.relative_to(app.ROOT)): app.path_hash(path)
                for path in sorted(sources) if path.is_file()}
    def git(*args):
        return subprocess.run(["git", *args], cwd=app.ROOT, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, check=True, timeout=deadline.remaining(5)).stdout
    revision = git("rev-parse", "HEAD").decode().strip()
    status = git("status", "--porcelain=v1", "--untracked-files=all").decode()
    patch = git("diff", "HEAD", "--binary")
    (output / "source-worktree.patch").write_bytes(patch)
    (output / "source-status.txt").write_text(status, encoding="utf-8")
    return {"schema_version": 1, "git_revision": revision, "worktree_dirty": bool(status),
            "worktree_patch_sha256": hashlib.sha256(patch).hexdigest(), "source_manifest": manifest,
            "source_manifest_sha256": hashlib.sha256(json.dumps(manifest, sort_keys=True,
                                                                   separators=(",", ":")).encode()).hexdigest(),
            "binaries": {key: {"path": str(path), "sha256": app.path_hash(path)} for key, path in paths.items()},
            "source_build_association": "Current source and explicit binary identities are recorded separately; the driver does not infer which source built an arbitrary binary."}


def validate_products(args):
    paths = {"probe": args.probe_binary.resolve(), "collector": args.collector_binary.resolve()}
    for name, path in paths.items():
        require(path.is_file() and os.access(path, os.X_OK), f"Explicit {name} binary is missing or not executable: {path}")
    return paths


class DrawingCase:
    def __init__(self, output, deadline, case, no_native_inspection=False, settle_seconds=1):
        self.output, self.deadline, self.case = output, deadline, case
        number(settle_seconds, "drawing settling seconds", minimum=1)
        require(settle_seconds <= 5, "Drawing settling time exceeds 5 seconds")
        require(type(no_native_inspection) is bool, "Native inspection selection must be Boolean")
        self.no_native_inspection, self.settle_seconds = no_native_inspection, settle_seconds
        self.collector = self.active_probe = self.identity = None
        self.previous = None
        self.report = {"case": case, "status": "running", "errors": [], "commands": [],
                       "checkpoints": [], "probes": [], "inspection_stages": [], "settling_waits": [],
                       "native_inspection_enabled": not no_native_inspection, "settle_seconds": settle_seconds,
                       "workload_validated": False}

    def save(self):
        write_json(self.output / "in-progress.json", self.report)

    def verify_identity(self):
        memory.verify_owned(self.collector, self.identity)

    def ready(self):
        end = time.monotonic() + self.deadline.remaining(15)
        while time.monotonic() < end:
            envelope = self.collector.receive(min(0.25, max(0.001, end - time.monotonic())))
            if envelope and envelope.get("type") == "app_event" and envelope.get("event", {}).get("type") == "ready":
                ready = envelope["event"]
                require(type(ready.get("protocol_version")) is int and ready["protocol_version"] == 1
                        and ready.get("command_id") == "collector-handshake", "Invalid drawing handshake")
                self.report["ready"] = ready
                self.save()
                snapshot = validate_snapshot(ready.get("drawing_snapshot"), self.case)
                require(snapshot["draw_enabled"] is False and snapshot["requested_frames"] == 0
                        and snapshot["nonempty_draw_calls"] == 0, "Drawing began before the measured baseline")
                self.previous = snapshot
                # The subsequent snapshot supplies a kernel sample after ready,
                # allowing the collector handshake to be authenticated.
                response = self.collector.command("snapshot")
                self.report["commands"].append({"command": "snapshot", "response": response})
                require(response.get("type") == "ack" and response.get("status") == "ok"
                        and response.get("command") == "snapshot", "Drawing baseline snapshot command failed")
                self.identity = app.authenticated_cpu_ready(self.collector.samples, self.collector.events)
                self.report["owned_identity"] = self.identity
                self.checkpoint("ready", response)
                return
            require(not self.collector.exited, "Drawing probe exited before ready")
        raise TimeoutError("Drawing probe did not become ready within 15 seconds")

    def command(self, name, **fields):
        self.verify_identity()
        response = self.collector.command(name, timeout=self.deadline.remaining(10), **fields)
        self.report["commands"].append({"command": name, **fields, "response": response})
        self.save()
        require(response.get("type") == "ack" and response.get("status") == "ok" and response.get("command") == name,
                f"Drawing command {name} was not acknowledged: {response}")
        self.verify_identity()
        return response

    def checkpoint(self, label, response=None, closed=False):
        if response is None:
            response = self.command("snapshot")
        self.verify_identity()
        entry = {"label": label, "snapshot": response.get("drawing_snapshot"),
                 "python_monotonic_seconds": time.monotonic(), "response": response}
        self.report["checkpoints"].append(entry)
        self.save()
        snapshot = validate_snapshot(entry["snapshot"], self.case, self.previous, closed)
        validate_command_state(self.previous, snapshot, response.get("command"))
        entry["resource_sample"] = boundary_sample(self.collector, response, self.identity)
        self.previous = snapshot
        self.save()
        return snapshot

    def inspect_tool(self, label, tool):
        self.verify_identity()
        pid = self.identity["process_id"]
        output = self.output / f"{label}-{tool}.txt"
        json_output = self.output / f"{label}-footprint.json"
        commands = {"footprint": ["/usr/bin/footprint", "--pid", str(pid), "--format", "bytes", "--swapped", "--wired", "--json", str(json_output)],
                    "vmmap": ["/usr/bin/vmmap", "-summary", "-sortBySize", str(pid)]}
        item = {"label": label, "tool": tool, "command": commands[tool], "output": str(output),
                "process_id": pid, "birth_time_us": self.identity["birth_time_us"],
                "started_monotonic_seconds": time.monotonic(), "valid": False, "errors": []}
        if tool == "footprint":
            item["json_output"] = str(json_output)
        self.report["probes"].append(item)
        end = time.monotonic() + self.deadline.remaining(8)
        try:
            with output.open("wb") as handle:
                self.active_probe = subprocess.Popen(commands[tool], stdout=handle, stderr=subprocess.STDOUT,
                                                     start_new_session=True)
                while self.active_probe.poll() is None:
                    require(time.monotonic() < end, f"{tool} exceeded its 8-second inspection limit")
                    require(output.stat().st_size <= MAX_ARTIFACT_BYTES
                            and (not json_output.exists() or json_output.stat().st_size <= MAX_ARTIFACT_BYTES),
                            f"{tool} output exceeded 16 MiB")
                    self.collector.receive(min(0.1, max(0.001, end - time.monotonic())))
                    require(not self.collector.exited, "Drawing probe exited during native inspection")
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
            item["errors"].append(str(error))
        finally:
            if self.active_probe is not None:
                memory.stop_owned_child(self.active_probe, self.deadline)
                item["exit_code"] = self.active_probe.returncode
                self.active_probe = None
            item["ended_monotonic_seconds"] = time.monotonic()
            item["output_bytes"] = output.stat().st_size if output.exists() else 0
            self.save()
        self.verify_identity()
        item["identity_verified_after"] = True
        if item.get("exit_code") != 0:
            item["errors"].append(f"{tool} exit status: {item.get('exit_code')}")
        if not item["errors"]:
            try:
                item["parsed"] = memory.parse_probe(tool, output, json_output, pid)
                item["valid"] = True
            except (OSError, ValueError, KeyError, TypeError) as error:
                item["errors"].append(str(error))
        self.report["errors"].extend(f"{label}/{tool}: {error}" for error in item["errors"])
        self.save()

    def inspect_stage(self, label, vmmap=False, closed=False):
        entry = {"label": label, "native_inspection_enabled": not self.no_native_inspection,
                 "status": "skipped" if self.no_native_inspection else "running",
                 "started_monotonic_seconds": time.monotonic()}
        self.report["inspection_stages"].append(entry)
        self.checkpoint(label + "-before-inspection", closed=closed)
        if not self.no_native_inspection:
            for tool in ("footprint", "vmmap") if vmmap else ("footprint",):
                self.inspect_tool(label, tool)
            entry["status"] = "completed"
        self.checkpoint(label + "-after-inspection", closed=closed)
        entry["ended_monotonic_seconds"] = time.monotonic()
        entry["elapsed_seconds"] = entry["ended_monotonic_seconds"] - entry["started_monotonic_seconds"]
        self.save()

    def settle(self, label, closed=False):
        started = time.monotonic()
        entry = {"label": label, "requested_seconds": self.settle_seconds,
                 "started_monotonic_seconds": started, "completed": False}
        self.report["settling_waits"].append(entry)
        self.save()
        self.collector.wait_until(started + self.settle_seconds)
        entry["ended_monotonic_seconds"] = time.monotonic()
        entry["elapsed_seconds"] = entry["ended_monotonic_seconds"] - started
        require(entry["elapsed_seconds"] >= self.settle_seconds, "Drawing settling wait ended prematurely")
        entry["completed"] = True
        self.checkpoint(label, closed=closed)

    def perform(self, paths):
        backend, primitive = self.case.split(":")
        configuration = {"protocol_version": 1, "history": "fresh",
                         "drawing_backend": backend, "drawing_primitive": primitive}
        write_json(self.output / "configuration.json", configuration)
        # external_trace suppresses embedded resource tracing; it does not claim
        # GPU instrumentation exists. This diagnostic evaluates no GPU budget.
        self.collector = app.Collector(paths["collector"], paths["probe"], configuration, {}, self.output,
                                       self.deadline, {"external_trace": True, "provenance": {}})
        self.ready()
        self.inspect_stage("baseline", vmmap=True)
        before = self.previous
        after = self.checkpoint("first-draw", self.command("draw_once"))
        validate_draw_progress(before, after, 1, self.case)
        self.settle("settled")
        self.inspect_stage("settled", vmmap=True)
        before = self.previous
        after = self.checkpoint("repeated", self.command("redraw", count=REDRAW_COUNT))
        validate_draw_progress(before, after, REDRAW_COUNT, self.case)
        self.inspect_stage("repeated")
        self.settle("post-redraw-idle")
        self.checkpoint("close", self.command("close"), closed=True)
        self.settle("released", closed=True)
        self.inspect_stage("released", vmmap=True, closed=True)
        self.report["workload_validated"] = True
        self.save()
        self.collector.finish()

    def emergency_cleanup(self):
        try:
            if not self.collector.exited:
                identity = {"process_id": self.collector.app_pid, "birth_time_us": self.collector.app_birth_time_us}
                memory.verify_owned(self.collector, identity)
                os.killpg(identity["process_id"], signal.SIGKILL)
        except (OSError, ValueError, TypeError) as error:
            self.report["errors"].append(f"Emergency drawing process cleanup could not be authenticated: {error}")
        try:
            memory.stop_owned_child(self.collector.process, self.deadline)
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
            self.report["errors"].append(f"Emergency collector cleanup failed: {error}")

    def cleanup(self):
        if self.active_probe is not None:
            try:
                memory.stop_owned_child(self.active_probe, self.deadline)
            except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
                self.report["errors"].append(f"Native inspector cleanup failed: {error}")
        if self.collector is None:
            return
        try:
            with self.deadline.interrupt_at(min(self.deadline.end - 1, self.deadline.clock() + 6)):
                self.collector.close()
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
            self.report["errors"].append(f"Collector cleanup failed: {error}")
            self.emergency_cleanup()
        self.report.update(samples=self.collector.samples, events=self.collector.events, storage=self.collector.storage)
        self.report["errors"].extend(self.collector.cleanup_errors)
        try:
            validate_final_evidence(self.report, self.identity, self.case)
        except (ValueError, KeyError, TypeError) as error:
            self.report["errors"].append(str(error))


def validate_final_evidence(report, identity, case):
    require(identity is not None, "Drawing process identity was never authenticated")
    samples, events = report["samples"], report["events"]
    memory.validate_sample_identities(samples, identity)
    exits = [event for event in events if event.get("type") == "exited"]
    require(len(exits) == 1 and type(exits[0].get("status")) is int and exits[0]["status"] == 0
            and exits[0].get("final_sample") == samples[-1], "Missing clean authenticated drawing final exit")
    stopped = [event["event"] for event in events if event.get("type") == "app_event"
               and event.get("event", {}).get("type") == "stopped"]
    require(len(stopped) == 1 and stopped[0].get("status") == "ok", "Drawing shutdown was not acknowledged")
    checkpoints = report.get("checkpoints", [])
    previous = checkpoints[-1].get("snapshot") if checkpoints else None
    validate_snapshot(stopped[0].get("drawing_snapshot"), case, previous, closed=True)
    validate_command_state(previous, stopped[0]["drawing_snapshot"], "shutdown")
    evidence = app.memory_evidence(samples, exits[0])
    require(not evidence["problems"], "Invalid drawing kernel memory evidence: " + "; ".join(evidence["problems"]))
    report["memory_validation"] = evidence
    report["memory_summary"] = {
        "baseline": samples[0], "final": samples[-1],
        "maximum_current_sample": max(samples, key=lambda sample: sample["physical_footprint_bytes"]),
        "lifetime_peak_footprint_bytes": samples[-1]["lifetime_peak_footprint_bytes"]}


def validate_comparison_geometry(cases):
    geometries = []
    for case in cases:
        ready = [item for item in case["checkpoints"] if item["label"] == "ready"]
        require(len(ready) == 1, "Each drawing case requires exactly one ready checkpoint")
        snapshot = ready[0]["snapshot"]
        geometries.append(tuple(snapshot[field] for field in ("content_width_points", "content_height_points", "backing_scale")))
    require(len(set(geometries)) == 1, "Drawing comparison cases used different window geometry or display scale")


def summary_markdown(report):
    lines = ["# Drawing attribution diagnostic", "", report["caveat"], "",
             "Completion status is recorded in [drawing-report.json](drawing-report.json). No resource-gate pass is implied.", "",
             f"Native inspection: {'disabled (kernel samples only)' if report.get('no_native_inspection') else 'enabled'}. "
             f"Settling waits: {report.get('settle_seconds', 1)} seconds after first draw, repeated draws, and close.", "",
             "| Case | Validated | Stage | Kernel current / lifetime peak (MB) | Native footprint (MB) | Graphics unmapped (MB) | Malloc dirty (MB) |",
             "|---|---|---|---:|---:|---:|---:|"]
    def mb(value):
        return f"{value / 1_000_000:.3f}" if type(value) in (int, float) else "unavailable"
    for case in report["cases"]:
        for checkpoint in case["checkpoints"]:
            stage = checkpoint["label"]
            if stage not in ("ready", "first-draw", "settled", "repeated", "post-redraw-idle", "released"):
                continue
            sample = checkpoint.get("resource_sample", {})
            native_stage = "baseline" if stage == "ready" else stage
            probes = [probe for probe in case["probes"] if probe["label"] == native_stage
                      and probe["tool"] == "footprint" and probe["valid"]]
            native = probes[0]["parsed"] if len(probes) == 1 else {}
            groups = native.get("groups", {})
            group = lambda name: mb(groups.get(name, {}).get("dirty", 0)) if native else "unavailable"
            valid = "yes" if case["status"] == "diagnostic_captured" else "NO — excluded"
            lines.append(f"| {case['case']} | {valid} | {stage} | {mb(sample.get('physical_footprint_bytes'))} / "
                         f"{mb(sample.get('lifetime_peak_footprint_bytes'))} | {mb(native.get('physical_footprint_bytes'))} | "
                         f"{group('graphics_unmapped')} | {group('malloc')} |")
    lines.extend(["", "Decimal MB. Native inspections occur after their named kernel checkpoint and perturb the process. "
                  "Dirty already includes swapped; VM categories are not additional footprint. "
                  "Graphics diagnostic pixel counts describe requests, not measured GPU allocations."])
    errors = [*report["errors"], *(f"{case['case']}: {error}" for case in report["cases"] for error in case["errors"])]
    if errors:
        lines.extend(["", "Invalid or unavailable evidence:", "", *("- " + error.replace("\n", " ") for error in errors)])
    return "\n".join(lines) + "\n"


def finalize(output, report, deadline):
    pending = dict(report, status="diagnostic_incomplete", finalization_pending=True,
                   errors=[*report["errors"], "Drawing report finalization has not completed"])
    try:
        with deadline.interrupt_at(deadline.end):
            write_json(output / "drawing-report.json", pending)
            (output / "SUMMARY.md").write_text(summary_markdown(report), encoding="utf-8")
            write_json(output / "drawing-report.json", report)
    except (OSError, ValueError, TimeoutError) as error:
        report["status"] = "diagnostic_incomplete"
        report["errors"].append(f"Final drawing report could not be completed: {error}")
        print(report["errors"][-1], file=sys.stderr)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--probe-binary", required=True, type=Path)
    result.add_argument("--collector-binary", required=True, type=Path)
    result.add_argument("--output-dir", type=Path, help="New artifact directory; never overwritten")
    result.add_argument("--case", action="append", type=parse_case, dest="cases", metavar="BACKEND:PRIMITIVE")
    result.add_argument("--no-native-inspection", action="store_true",
                        help="Collect kernel samples without launching footprint or vmmap")
    result.add_argument("--settle-seconds", type=parse_settle_seconds, default=1,
                        help="Settling time after first draw, repeated draws, and close (1 to 5 seconds; default 1)")
    return result


def run(argv=None):
    args = parser().parse_args(argv)
    cases = args.cases or list(DEFAULT_CASES)
    output = (args.output_dir or app.ROOT / ".performance-results" /
              ("drawing-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ-") + secrets.token_hex(3))).resolve()
    try:
        require(len(cases) == len(set(cases)), "Duplicate drawing cases are not allowed; use a separate run to repeat a measurement")
        require(1 <= len(cases) <= 12, "Choose between one and twelve drawing cases per bounded run")
        require(not output.exists(), "Never overwrite drawing diagnostic artifacts")
        require(app.ROOT not in output.parents or app.ROOT / ".performance-results" in output.parents,
                "In-repository drawing artifacts must be inside ignored .performance-results")
        require(sys.platform == "darwin", "Native drawing attribution requires macOS")
        paths = validate_products(args)
        output.mkdir(parents=True)
    except (OSError, ValueError) as error:
        print(f"Drawing diagnostic could not start: {error}", file=sys.stderr)
        return 1
    started = time.monotonic()
    deadline = DrawingDeadline()
    report = {"schema_version": 1, "kind": "drawing-attribution-diagnostic", "status": "running",
              "deadline_seconds": DEADLINE_SECONDS, "requested_cases": cases, "cases": [], "errors": [],
              "regression_passed": False, "cpu_gate_evaluated": False, "gpu_gate_evaluated": False,
              "disk_gate_evaluated": False, "gpu_measurement": {"available": False, "reason": "This drawing diagnostic collects kernel memory and native VM ledgers; no GPU instrumentation is enabled."},
              "argv": list(sys.argv[1:] if argv is None else argv), "redraw_count": REDRAW_COUNT,
              "no_native_inspection": args.no_native_inspection, "settle_seconds": args.settle_seconds,
              "caveat": "Fresh isolated processes, fixed windows, and synthetic drawing operations identify memory costs. "
                        "Native inspections perturb the process; these results are not full FluxLLM workload or CPU/GPU regression passes."}
    try:
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
            report["provenance"] = source_provenance(paths, output, deadline)
        for index, case in enumerate(cases):
            directory = output / f"{index + 1:02d}-{case.replace(':', '-')}"
            directory.mkdir()
            diagnostic = DrawingCase(directory, deadline, case, args.no_native_inspection, args.settle_seconds)
            report["cases"].append(diagnostic.report)
            try:
                with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
                    diagnostic.perform(paths)
            except (OSError, ValueError, KeyError, TypeError, TimeoutError, subprocess.SubprocessError, KeyboardInterrupt) as error:
                diagnostic.report["errors"].append(str(error) or "Interrupted")
            finally:
                diagnostic.cleanup()
                diagnostic.report["status"] = ("diagnostic_captured" if not diagnostic.report["errors"]
                                                and diagnostic.report["workload_validated"] else "diagnostic_incomplete")
                diagnostic.save()
            if diagnostic.report["status"] != "diagnostic_captured":
                # An invalid process must not contaminate later comparisons or
                # continue consuming the shared hard deadline.
                break
    except (OSError, ValueError, KeyError, TypeError, TimeoutError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        report["errors"].append(str(error) or "Interrupted")
    report["elapsed_seconds"] = time.monotonic() - started
    if report["elapsed_seconds"] > DEADLINE_SECONDS:
        report["errors"].append("Drawing diagnostic exceeded its hard 180-second deadline")
    complete = len(report["cases"]) == len(cases) and all(case["status"] == "diagnostic_captured" for case in report["cases"])
    if complete:
        try:
            validate_comparison_geometry(report["cases"])
        except (ValueError, KeyError, TypeError) as error:
            report["errors"].append(str(error))
    report["status"] = "diagnostic_captured" if complete and not report["errors"] else "diagnostic_incomplete"
    finalize(output, report, deadline)
    print(f"Drawing diagnostic: {report['status']}. Artifacts: {output}", flush=True)
    return 0 if report["status"] == "diagnostic_captured" else 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(run())
