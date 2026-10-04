"""Bounded, owned-process memory attribution; never a performance-gate pass.

Run via run_performance_checks.py memory with explicit frozen Release products.
Native inspection perturbs the process. CPU/GPU gates are deliberately not run.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import os
import math
from pathlib import Path
import re
import secrets
import signal
import subprocess
import sys
import time

import app_performance as app
from run_performance_checks import interrupted, load_json, number, require, write_json


GRAPHICS_MODES = ("normal", "direct-host", "empty-drawing", "no-renderer", "bitmap-destination", "bitmap-layer-destination",
                  "bitmap-layer-bgra", "bitmap-layer-no-decorations", "native-gpu-canvas", "native-gpu-coalesced-scalars",
                  "native-gpu-retained-twinkles", "native-gpu-optimized", "no-blur", "cpu-glow", "no-gradients", "no-gradients-or-blur")
ORDERED_PUBLICATION_MODE = "runtime-ordered-publication"
ORDERED_PUBLICATION_COUNTERS = ("ordered_chart_publication_queries", "chart_publication_full_sorts")
DIRECT_TOOL_PLOT_MODE = "runtime-direct-tool-plot"
DIRECT_TOOL_PLOT_COUNTERS = ("direct_tool_plot_builds", "legacy_tool_plot_builds")
UNGROUPED_CANVAS_MODE = "runtime-ungrouped-canvas"
NATIVE_CANVAS_GROUP_COUNTERS = ("ungrouped_native_canvas_draws", "grouped_native_canvas_draws")
NO_ARRIVAL_MODE = "runtime-no-arrival-effects"
HELD_STATIC_CHART_MODE = "runtime-held-static-chart"
FROZEN_SCALARS_MODE = "runtime-frozen-scalars"
HELD_USAGE_MODE = "runtime-held-usage"
RETAINED_USAGE_MODE = "runtime-retained-usage"
RETAINED_USAGE_COUNTERS = ("hosts_created", "hosts_destroyed", "value_apply_attempts", "value_applies", "value_apply_skips")
RETAINED_USAGE_GAUGES = ("current_owners", "peak_owners")
RETAINED_USAGE_FIELDS = ("input", "output", "tools", "requests", "badge")
HELD_USAGE_COUNTERS = ("captures", "releases")
HELD_USAGE_GAUGES = ("current_owners", "peak_owners")
HELD_USAGE_VALUE_COUNTS = ("input_tokens", "unknown_input_requests", "output_tokens", "tool_calls", "requests", "active_requests")
HELD_USAGE_VALUE_FLAGS = ("output_is_estimated", "is_partial")
SCALAR_LEAVES = ("header", "metrics", "details", "card_footer", "app_footer")
SCALAR_PRESENTATION_COUNTERS = ("layout_size_calls", "layout_place_calls", "layout_child_measurements",
                                "freezes_captured", "freezes_released")
SCALAR_PRESENTATION_GAUGES = ("current_frozen_owners", "peak_frozen_owners")
HELD_STATIC_CHART_COUNTERS = ("drawing_update_attempts", "drawing_updates_applied", "drawing_updates_held", "drawing_hold_resets")
METAL_ARRIVAL_MODE = "runtime-metal-arrival-bursts"
METAL_ARRIVAL_COUNTERS = ("metal_arrival_frames", "metal_arrival_submissions", "metal_arrival_failures")
METAL_FULL_CHART_MODE = "runtime-metal-full-chart"
METAL_CACHED_CHART_MODE = "runtime-metal-cached-chart"
METAL_CHART_MODES = (METAL_FULL_CHART_MODE, METAL_CACHED_CHART_MODE)
METAL_PRIMITIVE_EFFECTS_MODE = "runtime-metal-primitive-effects"
TELEMETRY_BATCH_MODE = "runtime-telemetry-batch"
ATOMIC_CHART_SCALE_MODE = "runtime-atomic-chart-scale"
EFFICIENT_EFFECTS_MODE = "runtime-efficient-effects"
PRIMITIVE_EFFECTS_MODES = (METAL_PRIMITIVE_EFFECTS_MODE, EFFICIENT_EFFECTS_MODE)
BATCHED_TELEMETRY_MODES = (TELEMETRY_BATCH_MODE, EFFICIENT_EFFECTS_MODE)
ATOMIC_CHART_SCALE_MODES = (ATOMIC_CHART_SCALE_MODE, EFFICIENT_EFFECTS_MODE)
NEW_RUNTIME_MODES = (METAL_PRIMITIVE_EFFECTS_MODE, TELEMETRY_BATCH_MODE, ATOMIC_CHART_SCALE_MODE, EFFICIENT_EFFECTS_MODE)
EFFICIENT_RUNTIME_MODES = NEW_RUNTIME_MODES
COMPLETED_LANE_CACHE_MODE = "runtime-completed-lane-cache"
CACHED_RAIL_GEOMETRY_MODE = "runtime-cached-rail-geometry"
REUSE_CACHES_MODE = "runtime-reuse-caches"
REUSE_RUNTIME_MODES = (COMPLETED_LANE_CACHE_MODE, CACHED_RAIL_GEOMETRY_MODE, REUSE_CACHES_MODE)
COMPLETED_LANE_CACHE_MODES = (COMPLETED_LANE_CACHE_MODE, REUSE_CACHES_MODE)
CACHED_RAIL_GEOMETRY_MODES = (CACHED_RAIL_GEOMETRY_MODE, REUSE_CACHES_MODE)
REUSE_RUNTIME_FLAGS = ("completed_lane_cache_enabled", "rail_geometry_cache_enabled")
COMPLETED_LANE_CACHE_COUNTERS = ("builds", "hits", "visited_records")
CACHED_RAIL_GEOMETRY_COUNTERS = ("builds", "hits")
REUSE_CACHE_GAUGES = ("current_entries", "peak_entries")
REUSE_CACHE_SPECS = (
    ("completed_lane_cache", "completed_lane_cache_enabled", COMPLETED_LANE_CACHE_MODES,
     COMPLETED_LANE_CACHE_COUNTERS, 20_000),
    ("rail_geometry_cache", "rail_geometry_cache_enabled", CACHED_RAIL_GEOMETRY_MODES,
     CACHED_RAIL_GEOMETRY_COUNTERS, 48),
)
NEW_RUNTIME_FLAGS = ("metal_primitive_effects_enabled", "batched_telemetry_delivery_enabled", "atomic_chart_scale_enabled")
METAL_PRIMITIVE_EFFECTS_COUNTERS = ("hosts_created", "hosts_destroyed", "descriptor_uploads", "submissions", "clears",
                                   "arrival_frames", "completion_frames", "twinkle_frames", "frames_skipped", "failures", "fallbacks")
METAL_PRIMITIVE_EFFECTS_FIELDS = METAL_PRIMITIVE_EFFECTS_COUNTERS + ("live_hosts", "peak_hosts", "current_buffer_bytes", "peak_buffer_bytes")
BATCHED_TELEMETRY_COUNTERS = ("compact_states_enqueued", "snapshots_materialized", "batches_applied", "events_applied", "projection_refreshes")
ATOMIC_CHART_SCALE_COUNTERS = ("resolutions", "scale_changes", "cache_hits")
BATCHED_TELEMETRY_FIELDS = BATCHED_TELEMETRY_COUNTERS
ATOMIC_CHART_SCALE_FIELDS = ATOMIC_CHART_SCALE_COUNTERS
METAL_SCENE_REVISION_CAUSES = ("scene_initial_revisions", "scene_publication_revisions", "scene_scale_revisions",
                             "scene_layout_revisions", "scene_appearance_revisions", "scene_rail_revisions",
                             "scene_unclassified_revisions")
METAL_CACHE_COUNTERS = ("static_rasterizations", "static_cache_composites", "effect_clock_ticks",
                        "static_scene_revisions", "static_surface_invalidations") + METAL_SCENE_REVISION_CAUSES
METAL_CACHE_FIELDS = METAL_CACHE_COUNTERS + ("current_texture_bytes", "peak_texture_bytes")
METAL_FULL_CHART_COUNTERS = ("hosts_created", "hosts_destroyed", "geometry_uploads", "submissions", "failures",
                           "frames_skipped", "static_frames", "arrival_frames", "completion_frames", "twinkle_frames")
METAL_FULL_CHART_FIELDS = METAL_FULL_CHART_COUNTERS + ("live_hosts", "peak_hosts", "current_buffer_bytes", "peak_buffer_bytes")
COMPACT_TOOL_PATHS_MODE = "runtime-compact-tool-paths"
DEFERRED_TOOL_GEOMETRY_MODE = "runtime-deferred-tool-geometry"
DEFERRED_TOOL_GEOMETRY_2HZ_MODE = "runtime-deferred-tool-geometry-2hz"
DEFERRED_TOOL_GEOMETRY_MODES = (DEFERRED_TOOL_GEOMETRY_MODE, DEFERRED_TOOL_GEOMETRY_2HZ_MODE)
TOOL_PATH_POINT_COUNTERS = ("tool_path_input_points", "tool_path_output_points")
ORDERED_PUBLICATION_MODES = (ORDERED_PUBLICATION_MODE, DIRECT_TOOL_PLOT_MODE, UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE, COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE, *METAL_CHART_MODES, HELD_STATIC_CHART_MODE, FROZEN_SCALARS_MODE, HELD_USAGE_MODE, RETAINED_USAGE_MODE) + DEFERRED_TOOL_GEOMETRY_MODES + NEW_RUNTIME_MODES + REUSE_RUNTIME_MODES
CANVAS_CLOCK_MODES = ("runtime-canvas-clock", "runtime-stream-canvas-clock") + tuple(mode for mode in ORDERED_PUBLICATION_MODES if mode not in METAL_CHART_MODES)
NEXT_RUNTIME_MODES = ("runtime-shared-preparation", "runtime-stable-decoration-hosts", "runtime-stream-writes", "runtime-next-optimized", *METAL_CHART_MODES) + CANVAS_CLOCK_MODES
RUNTIME_MODES = ("runtime-no-lifecycle", "runtime-history-order", "runtime-chart-preparation", "runtime-optimized") + NEXT_RUNTIME_MODES
GRAPHICS_MODES += RUNTIME_MODES
RUNTIME_FLAGS = ("incremental_history_ordering", "optimized_chart_preparation", "lifecycle_effects_enabled")
NEXT_RUNTIME_FLAGS = ("shared_chart_preparation", "stable_decoration_hosts", "unpromised_stream_body_writes")
SHARED_PREPARATION_COUNTERS = ("shared_chart_normalization_builds", "shared_chart_preparations")
NEXT_RUNTIME_COUNTERS = SHARED_PREPARATION_COUNTERS + ("streamed_bodies_without_promises",)
CANVAS_CLOCK_COUNTERS = ("rail_frame_clock_ticks", "rail_timeline_content_updates")
LAYER_DESTINATION_MODES = ("bitmap-layer-destination", "bitmap-layer-bgra", "bitmap-layer-no-decorations")
NATIVE_GPU_MODES = ("native-gpu-canvas", "native-gpu-coalesced-scalars", "native-gpu-retained-twinkles", "native-gpu-optimized") + RUNTIME_MODES
COALESCED_SCALAR_MODES = ("native-gpu-coalesced-scalars", "native-gpu-optimized") + RUNTIME_MODES
RETAINED_TWINKLE_MODES = ("native-gpu-retained-twinkles", "native-gpu-optimized") + tuple(mode for mode in RUNTIME_MODES if mode != METAL_FULL_CHART_MODE)
RETAINED_TWINKLE_FIELDS = ("hosts_created", "hosts_destroyed", "live_hosts", "peak_hosts",
                          "instances_created", "instances_destroyed", "live_instances", "peak_instances", "animation_starts")
TWINKLE_DELIVERY_COUNTERS = ("retained_twinkle_direct_updates", "twinkle_state_publications")
GRADIENT_ABLATION_MODES = ("no-gradients", "no-gradients-or-blur")
MAX_ARTIFACT_BYTES = 16 * 1024 * 1024
DEADLINE_SECONDS = 90
CATEGORY_FIELDS = ("dirty", "swapped", "clean", "reclaimable", "wired", "regions")
SIZE_PATTERN = r"(?:\d+(?:\.\d+)?)(?:[KMGT])?"
NATIVE_ERROR = re.compile(r"(?im)^\s*(?:error\b|warning\b|(?:footprint|vmmap|heap):\s*(?:error|failed|cannot|unable)|"
                          r"(?:failed|unable|cannot) (?:to |inspect|read|access)|permission denied|operation not permitted)")


def unsigned(value, name):
    return number(value, name, integer=True)


def finite_numeric(value):
    return (type(value) in (int, float) and -sys.float_info.max <= value <= sys.float_info.max
            and math.isfinite(value))


def footprint_group(name):
    """Disjoint labels over one footprint ledger, not additional allocations."""
    if name == "Owned physical footprint (unmapped) (graphics)":
        return "graphics_unmapped"
    if name.startswith("IOAccelerator"):
        return "ioaccelerator"
    if name == "IOSurface":
        return "iosurface"
    if name == "CoreAnimation":
        return "core_animation"
    if name in ("CG Image", "CG Raster Data", "CoreGraphics", "CoreUI Image Data", "Image IO"):
        return "image_data"
    if name.startswith("Malloc"):
        return "malloc"
    if name == "Owned physical footprint (unmapped)":
        return "other_unmapped"
    return "other_categories"


def parse_footprint(value, pid):
    require(isinstance(value, dict), "footprint JSON must be an object")
    require(value.get("unit") == "byte" and type(value.get("bytes per unit")) is int
            and value["bytes per unit"] == 1, "footprint must report exact byte units")
    for field in ("errors", "warnings"):
        require(value.get(field) == [], f"footprint {field} are missing or nonempty: {value.get(field)}")
    processes = value.get("processes")
    require(isinstance(processes, list) and len(processes) == 1 and isinstance(processes[0], dict),
            "footprint must describe exactly one process")
    process = processes[0]
    require(type(process.get("pid")) is int and process["pid"] == pid, "footprint process PID mismatch")
    footprint = unsigned(process.get("footprint"), "footprint bytes")
    auxiliary = process.get("auxiliary")
    require(isinstance(auxiliary, dict), "footprint auxiliary ledger is missing")
    require(unsigned(auxiliary.get("phys_footprint"), "auxiliary footprint") == footprint
            and unsigned(value.get("total footprint"), "total footprint") == footprint,
            "footprint process, auxiliary, and total ledgers disagree")
    peak = unsigned(auxiliary.get("phys_footprint_peak"), "footprint peak")
    require(peak >= footprint, "footprint peak is below current footprint")
    categories = process.get("categories")
    require(isinstance(categories, dict) and categories, "footprint categories are missing")
    groups = {}
    for name, counters in categories.items():
        require(isinstance(name, str) and name and isinstance(counters, dict), "Invalid footprint category")
        group = groups.setdefault(footprint_group(name), {field: 0 for field in CATEGORY_FIELDS})
        for field in CATEGORY_FIELDS:
            group[field] += unsigned(counters.get(field), f"footprint {name}.{field}")
    # footprint(1): Dirty includes (Swapped). Wired and reclaimable overlap
    # other columns and must not be added to the physical-footprint ledger.
    require(sum(group["dirty"] for group in groups.values()) == footprint,
            "footprint category dirty bytes do not reconcile with the physical footprint")
    return {"process_id": pid, "physical_footprint_bytes": footprint, "lifetime_peak_bytes": peak,
            "groups": groups, "categories": categories,
            "accounting": "Exact bytes; dirty includes swapped. Groups partition dirty; wired/reclaimable are not additive."}


def display_size(token):
    require(isinstance(token, str) and re.fullmatch(SIZE_PATTERN, token), f"Unsupported native size: {token!r}")
    suffix = token[-1] if token[-1].isalpha() else ""
    numeric = token[:-1] if suffix else token
    factor = 1024 ** ("KMGT".index(suffix) + 1) if suffix else 1
    require(suffix or "." not in numeric, "A native byte count without a suffix must be an integer")
    precision = len(numeric.split(".")[1]) if "." in numeric else 0
    return {"display": token, "bytes_approximate": float(Decimal(numeric) * factor),
            "display_resolution_bytes": float(Decimal(10) ** -precision * factor), "exact": not bool(suffix)}


def native_header(text, pid, tool):
    require(isinstance(text, str) and text and not NATIVE_ERROR.search(text), f"{tool} reported an error or warning")
    identities = re.findall(r"^Process:\s+[^\n]*\[(\d+)\]\s*$", text, re.MULTILINE)
    require(identities == [str(pid)], f"{tool} requires one matching primary Process PID")
    require(re.findall(r"^Analysis Tool:\s*(\S+)\s*$", text, re.MULTILINE) == [f"/usr/bin/{tool}"],
            f"Unexpected {tool} analysis tool")
    result = {}
    for label, key in (("Physical footprint", "physical_footprint"), ("Physical footprint (peak)", "lifetime_peak")):
        values = re.findall(r"^" + re.escape(label) + r":\s*(\S+)\s*$", text, re.MULTILINE)
        require(len(values) == 1, f"{tool} is missing a unique {label}")
        result[key] = display_size(values[0])
    return result


def parse_vmmap(text, pid):
    summary = native_header(text, pid, "vmmap")
    headers = list(re.finditer(r"^REGION TYPE\s+SIZE\s+SIZE\s+SIZE\s+SIZE\s+SIZE\s+SIZE\s+SIZE\s+COUNT[^\n]*$",
                               text, re.MULTILINE))
    require(len(headers) == 1, "vmmap region table header is missing or ambiguous")
    tail = text[headers[0].end():]
    rows, total = [], None
    pattern = re.compile(r"^(.+?)\s+" + (r"(" + SIZE_PATTERN + r")\s+") * 7 +
                         r"(\d+)(?:\s+(?:see MALLOC ZONE table below|reserved VM address space \(unallocated\)))?\s*$")
    for line in tail.splitlines():
        stripped = line.strip()
        if not stripped or set(stripped) <= {"=", " "}:
            continue
        if total is not None:
            break  # The malloc-zone table and minus-reserved total are separate ledgers.
        match = pattern.fullmatch(stripped)
        require(match is not None, f"Malformed vmmap region row: {stripped[:160]}")
        name, *values, regions = match.groups()
        row = {"name": name, "regions": int(regions)}
        row.update({field: display_size(value) for field, value in zip(
            ("virtual", "resident", "dirty", "swapped", "volatile", "nonvolatile", "empty"), values)})
        if name == "TOTAL":
            total = row
        else:
            rows.append(row)
    require(rows and total is not None, "vmmap region table is incomplete")
    require(sum(row["regions"] for row in rows) == total["regions"], "vmmap region counts do not reconcile (possibly truncated)")
    return {"process_id": pid, **summary, "regions": rows, "region_total": total,
            "accounting": "Rounded binary sizes. Region dirty excludes swapped; region totals are not the physical-footprint ledger."}


def heap_group(description):
    if description.strip() == "non-object":
        return "non_object"
    if any(name in description for name in ("SwiftUI", "AttributeGraph")):
        return "ui_type_references"
    if any(name in description for name in ("Metal", "AGX", "QuartzCore", "CoreAnimation", "IOSurface")):
        return "graphics_type_references"
    if "FluxLLM." in description:
        return "app_type_references"
    return "other_allocations"


def parse_heap(text, pid):
    summary = native_header(text, pid, "heap")
    require(re.findall(r"^Process (\d+):\s*\d+ zones\s*$", text, re.MULTILINE) == [str(pid)],
            "heap zone header PID mismatch or missing")
    totals = re.findall(r"^All zones:\s*(\d+) nodes \((\d+) bytes\)\s*$", text, re.MULTILINE)
    require(len(totals) == 1, "heap allocation total is missing or ambiguous")
    count, allocated = map(int, totals[0])
    headers = list(re.finditer(r"^\s*COUNT\s+BYTES\s+AVG\s+CLASS_NAME\s+TYPE\s+BINARY\s*$", text, re.MULTILINE))
    require(len(headers) == 1, "heap allocation table header is missing or ambiguous")
    rows, groups = [], {}
    for line in text[headers[0].end():].splitlines():
        if not line.strip() or set(line.strip()) <= {"=", " "}:
            continue
        match = re.fullmatch(r"\s*(\d+)\s+(\d+)\s+(\d+(?:\.\d+)?)\s+(.*?)\s*", line)
        require(match is not None, f"Malformed heap allocation row: {line[:160]}")
        nodes, size, average, description = match.groups()
        row = {"count": int(nodes), "bytes": int(size), "average_display": average,
               "description": description}
        rows.append(row)
        group = groups.setdefault(heap_group(description), {"count": 0, "bytes": 0})
        group["count"] += row["count"]
        group["bytes"] += row["bytes"]
    require(rows and sum(row["count"] for row in rows) == count and sum(row["bytes"] for row in rows) == allocated,
            "heap allocation table does not reconcile with All zones (possibly truncated)")
    return {"process_id": pid, **summary, "allocation_count": count, "allocated_bytes": allocated,
            "groups": groups, "allocations": rows,
            "accounting": "Exact allocated bytes, not physical footprint. Groups classify native type-name references, not causal ownership. Descriptions retain ambiguous native class/type/binary columns."}


class MemoryDeadline:
    def __init__(self, seconds=DEADLINE_SECONDS, clock=time.monotonic):
        require(type(seconds) in (int, float) and 8 < seconds <= DEADLINE_SECONDS, "Memory deadline must be at most 90 seconds")
        self.clock = clock
        self.end = clock() + seconds
        self.cleanup_reserve = 8

    def remaining(self, maximum=None):
        remaining = self.end - self.clock() - self.cleanup_reserve
        if remaining <= 0:
            raise TimeoutError("The 90-second memory diagnostic deadline reached its cleanup reserve")
        return min(remaining, maximum) if maximum is not None else remaining

    @contextmanager
    def interrupt_at(self, end):
        """Bound even file parsing and synchronous helper calls on the main thread."""
        def expired(_signal, _frame):
            raise TimeoutError("The 90-second memory diagnostic deadline expired")
        duration = end - self.clock()
        require(duration > 0, "No time remains in the memory diagnostic deadline")
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


def stop_owned_child(process, deadline):
    """Only a child launched in its own session by this diagnostic is accepted."""
    try:
        if process.poll() is None:
            require(os.getpgid(process.pid) == process.pid, "Diagnostic child no longer owns its process group")
            os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        if process.poll() is None:
            raise
    process.wait(timeout=max(0.001, min(1, deadline.end - deadline.clock())))


def verify_owned(collector, identity, birth_reader=None):
    if birth_reader is None:
        from performance_trace import _birth_time
        birth_reader = _birth_time
    pid, birth = identity["process_id"], identity["birth_time_us"]
    require(type(pid) is int and type(birth) is int and pid > 0 and birth > 0,
            "Memory inspection requires an authenticated PID and birth time")
    require(pid == collector.app_pid and birth == collector.app_birth_time_us and not collector.exited
            and birth_reader(pid) == birth and os.getpgid(pid) == pid, "Owned app identity changed")


def authenticate_ready(collector, snapshot_validator=None):
    # The ready record needs a following kernel sample to authenticate the
    # boundary. The first saved probe failed before this explicit snapshot.
    snapshot = collector.snapshot()
    if snapshot_validator is not None:
        snapshot_validator(snapshot)
    return app.authenticated_cpu_ready(collector.samples, collector.events)


def validate_sample_identities(samples, identity):
    require(isinstance(samples, list) and len(samples) >= 2, "Memory diagnostics require a complete collector sample sequence")
    previous = None
    for sample in samples:
        require(isinstance(sample, dict) and all(type(sample.get(field)) is int and sample[field] == identity[field]
                for field in ("process_id", "birth_time_us")), "Memory sample identity changed")
        timestamp = number(sample.get("monotonic_seconds"), "Memory sample timestamp")
        require(previous is None or timestamp > previous, "Memory sample timestamps are not strictly increasing")
        previous = timestamp
    require(samples[0].get("phase") == "baseline" and samples[-1].get("phase") == "final",
            "Memory samples do not include the complete baseline-to-final lifetime")


def validate_products(args):
    paths = {"app": args.app_binary.resolve(), "tests": args.test_bundle.resolve(),
             "collector": args.collector_binary.resolve()}
    for key, path in paths.items():
        require(path.exists(), f"Explicit {key} product is missing: {path}")
        if key != "tests":
            require(path.is_file() and os.access(path, os.X_OK), f"Explicit {key} must be executable")
    identity = app.measurement_identity()
    raw = load_json(args.provenance)
    require(isinstance(raw, dict), "Explicit provenance must be an object")
    mode = "baseline" if raw.get("kind") == "reconstructed-pre-optimization" else "check"
    provenance = app.validated_provenance(args.provenance, paths, mode, identity["sha256"])
    if getattr(args, "graphics_mode", None) is not None:
        app.validate_graphics_mode(provenance, args.graphics_mode)
    require(app.path_hash(paths["collector"]) == provenance.get("common_collector", {}).get("sha256"),
            "Explicit common collector does not match provenance")
    bundles = provenance.get("resource_bundle_sha256")
    require(isinstance(bundles, dict) and bundles, "Frozen products require resource-bundle hashes")
    for name, expected in bundles.items():
        require(isinstance(name, str) and Path(name).name == name and name.endswith(".bundle"), "Invalid resource bundle path")
        bundle = paths["app"].parent / name
        require(bundle.is_dir() and app.path_hash(bundle) == expected, f"Resource bundle differs from provenance: {name}")
    return paths, provenance, identity


def read_native(path):
    require(path.is_file() and 0 < path.stat().st_size <= MAX_ARTIFACT_BYTES, f"Native report missing, empty, or over 16 MiB: {path}")
    return path.read_text(encoding="utf-8", errors="strict")


def parse_probe(tool, output, json_output, pid):
    text = read_native(output)
    require(not NATIVE_ERROR.search(text), f"{tool} reported an error or warning")
    if tool == "footprint":
        read_native(json_output)  # Check the size before strict JSON decoding.
        return parse_footprint(load_json(json_output), pid)
    return {"vmmap": parse_vmmap, "heap": parse_heap}[tool](text, pid)


def validate_retained_twinkles(value, mode, *, completed_visible_workload=False, expected_closed=False):
    retained = mode in RETAINED_TWINKLE_MODES
    if not retained and "retained_twinkles" not in value:
        return
    counters = value.get("retained_twinkles")
    require(isinstance(counters, dict), "Retained twinkle lifecycle counters are missing")
    for field in RETAINED_TWINKLE_FIELDS:
        unsigned(counters.get(field), f"graphics.retained_twinkles.{field}")
    if not retained:
        require(all(counters[field] == 0 for field in RETAINED_TWINKLE_FIELDS),
                "Retained twinkle activity occurred outside a retained-twinkle mode")
        return
    require(value.get("retained_twinkle_backend") == "core-animation-shape-layers",
            "App did not acknowledge the retained twinkle shape-layer backend")
    for kind in ("hosts", "instances"):
        created, destroyed = counters[f"{kind}_created"], counters[f"{kind}_destroyed"]
        current, peak = counters[f"live_{kind}"], counters[f"peak_{kind}"]
        require(created - destroyed == current, f"Retained twinkle {kind} lifecycle counters do not reconcile")
        require(current <= peak <= created and (created == 0 or peak > 0),
                f"Retained twinkle {kind} peak is inconsistent")
    require(counters["live_instances"] <= 2 * counters["live_hosts"]
            and counters["peak_instances"] <= 2 * counters["peak_hosts"],
            "Retained twinkle instances exceed two per host")
    if completed_visible_workload:
        require(counters["instances_created"] > 0 and counters["animation_starts"] > 0,
                "Completed visible workload did not submit retained twinkle animations")
    if expected_closed:
        require(counters["live_hosts"] == 0 and counters["live_instances"] == 0,
                "Retained twinkle resources remain live at a closed checkpoint")


def twinkle_delivery_contract(snapshot, mode):
    value = snapshot.get("graphics_diagnostics", {})
    field = "direct_retained_twinkle_delivery"
    if field not in value and not any(name in snapshot for name in TWINKLE_DELIVERY_COUNTERS):
        return None
    expected = mode in RETAINED_TWINKLE_MODES or mode == "normal" and "native_gpu_backend" in value
    require(type(value.get(field)) is bool and value[field] is expected,
            "Direct retained twinkle delivery counters lack matching backend metadata")
    counters = {name: snapshot.get(name) for name in TWINKLE_DELIVERY_COUNTERS}
    for name, count in counters.items():
        require(type(count) is int and 0 <= count <= 2**64 - 1,
                f"{name} must be a complete UInt64 twinkle delivery counter")
    if not expected:
        require(counters["retained_twinkle_direct_updates"] == 0,
                "Nonretained backend executed direct twinkle delivery")
    return {"enabled": expected, "counters": counters}


def runtime_feature_contract(value, mode):
    if mode not in RUNTIME_MODES and not any(field in value for field in RUNTIME_FLAGS + NEXT_RUNTIME_FLAGS + NEW_RUNTIME_FLAGS + REUSE_RUNTIME_FLAGS + ("canvas_frame_clock", "ordered_chart_publication", "direct_tool_plot", "ungrouped_native_canvas", "arrival_effects_enabled", "compact_tool_paths_enabled", "deferred_tool_geometry_enabled", "metal_arrival_bursts_enabled", "holds_static_chart_drawing", "frozen_scalar_presentation_enabled")):
        return None
    extras = {}
    for field, enabled_modes in zip(NEW_RUNTIME_FLAGS, (PRIMITIVE_EFFECTS_MODES, BATCHED_TELEMETRY_MODES, ATOMIC_CHART_SCALE_MODES)):
        if mode in NEW_RUNTIME_MODES + REUSE_RUNTIME_MODES + (FROZEN_SCALARS_MODE, HELD_USAGE_MODE, RETAINED_USAGE_MODE) or field in value:
            require(type(value.get(field)) is bool and value[field] is (mode in enabled_modes),
                    f"Graphics {field} does not match the requested runtime control")
            extras[field] = value[field]
    for field, enabled_modes in zip(REUSE_RUNTIME_FLAGS, (COMPLETED_LANE_CACHE_MODES, CACHED_RAIL_GEOMETRY_MODES)):
        if mode in REUSE_RUNTIME_MODES + (FROZEN_SCALARS_MODE, HELD_USAGE_MODE, RETAINED_USAGE_MODE) or field in value:
            require(type(value.get(field)) is bool and value[field] is (mode in enabled_modes),
                    f"Graphics {field} does not match the requested runtime control")
            extras[field] = value[field]
    if mode == FROZEN_SCALARS_MODE or "frozen_scalar_presentation_enabled" in value:
        require(type(value.get("frozen_scalar_presentation_enabled")) is bool
                and value["frozen_scalar_presentation_enabled"] is (mode == FROZEN_SCALARS_MODE),
                "Graphics frozen_scalar_presentation_enabled does not match the requested runtime control")
        extras["frozen_scalar_presentation_enabled"] = value["frozen_scalar_presentation_enabled"]
    if mode == HELD_USAGE_MODE or "held_usage_enabled" in value:
        require(type(value.get("held_usage_enabled")) is bool and value["held_usage_enabled"] is (mode == HELD_USAGE_MODE),
                "Graphics held_usage_enabled does not match the requested runtime control")
        extras["held_usage_enabled"] = value["held_usage_enabled"]
    if mode == RETAINED_USAGE_MODE or "retained_usage_fields" in value:
        require(type(value.get("retained_usage_fields")) is bool and value["retained_usage_fields"] is (mode == RETAINED_USAGE_MODE),
                "Graphics retained_usage_fields does not match the requested runtime control")
        extras["retained_usage_fields"] = value["retained_usage_fields"]
    if mode in METAL_CHART_MODES or "metal_full_chart_enabled" in value:
        require(type(value.get("metal_full_chart_enabled")) is bool
                and value["metal_full_chart_enabled"] is (mode in METAL_CHART_MODES),
                "Graphics metal_full_chart_enabled does not match the requested runtime control")
        extras["metal_full_chart_enabled"] = value["metal_full_chart_enabled"]
    if mode == METAL_CACHED_CHART_MODE or "metal_static_cache_enabled" in value:
        require(type(value.get("metal_static_cache_enabled")) is bool
                and value["metal_static_cache_enabled"] is (mode == METAL_CACHED_CHART_MODE),
                "Graphics metal_static_cache_enabled does not match the requested runtime control")
        extras["metal_static_cache_enabled"] = value["metal_static_cache_enabled"]
    promoted_normal = mode == "normal" and value.get("unpromised_stream_body_writes") is True
    if mode in NEXT_RUNTIME_MODES or any(field in value for field in NEXT_RUNTIME_FLAGS):
        expected = {"shared_chart_preparation": mode in ("runtime-shared-preparation", "runtime-next-optimized"),
                    "stable_decoration_hosts": mode in ("runtime-stable-decoration-hosts", "runtime-next-optimized"),
                    "unpromised_stream_body_writes": promoted_normal or mode in ("runtime-stream-writes", "runtime-next-optimized", "runtime-stream-canvas-clock") + ORDERED_PUBLICATION_MODES}
        for field, enabled in expected.items():
            require(type(value.get(field)) is bool and value[field] is enabled,
                    f"Graphics {field} does not match the requested runtime control")
        extras.update({field: value[field] for field in NEXT_RUNTIME_FLAGS})
    if promoted_normal or mode in CANVAS_CLOCK_MODES or "canvas_frame_clock" in value:
        require(type(value.get("canvas_frame_clock")) is bool and value["canvas_frame_clock"] is (promoted_normal or mode in CANVAS_CLOCK_MODES),
                "Graphics canvas_frame_clock does not match the requested runtime control")
        extras["canvas_frame_clock"] = value["canvas_frame_clock"]
    if mode in ORDERED_PUBLICATION_MODES or "ordered_chart_publication" in value:
        expected = (mode in ORDERED_PUBLICATION_MODES or extras.get("shared_chart_preparation", False)
                    or mode == "normal" and value.get("ordered_chart_publication") is True)
        require(type(value.get("ordered_chart_publication")) is bool and value["ordered_chart_publication"] is expected,
                "Graphics ordered_chart_publication does not match the requested runtime control")
        extras["ordered_chart_publication"] = value["ordered_chart_publication"]
    if mode in (DIRECT_TOOL_PLOT_MODE, UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE, COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE) + DEFERRED_TOOL_GEOMETRY_MODES or "direct_tool_plot" in value:
        require(type(value.get("direct_tool_plot")) is bool and value["direct_tool_plot"] is (mode == DIRECT_TOOL_PLOT_MODE),
                "Graphics direct_tool_plot does not match the requested runtime control")
        extras["direct_tool_plot"] = value["direct_tool_plot"]
    if mode in (UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE, COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE) + DEFERRED_TOOL_GEOMETRY_MODES or "ungrouped_native_canvas" in value:
        require(type(value.get("ungrouped_native_canvas")) is bool and value["ungrouped_native_canvas"] is (mode == UNGROUPED_CANVAS_MODE),
                "Graphics ungrouped_native_canvas does not match the requested runtime control")
        extras["ungrouped_native_canvas"] = value["ungrouped_native_canvas"]
    if mode in (NO_ARRIVAL_MODE, COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE) + DEFERRED_TOOL_GEOMETRY_MODES or "arrival_effects_enabled" in value:
        expected = mode not in (NO_ARRIVAL_MODE, "runtime-no-lifecycle")
        require(type(value.get("arrival_effects_enabled")) is bool and value["arrival_effects_enabled"] is expected,
                "Graphics arrival_effects_enabled does not match the requested runtime control")
        extras["arrival_effects_enabled"] = value["arrival_effects_enabled"]
    if mode in (COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE) + DEFERRED_TOOL_GEOMETRY_MODES or "compact_tool_paths_enabled" in value:
        require(type(value.get("compact_tool_paths_enabled")) is bool
                and value["compact_tool_paths_enabled"] is (mode == COMPACT_TOOL_PATHS_MODE),
                "Graphics compact_tool_paths_enabled does not match the requested runtime control")
        extras["compact_tool_paths_enabled"] = value["compact_tool_paths_enabled"]
    if mode in DEFERRED_TOOL_GEOMETRY_MODES + (METAL_ARRIVAL_MODE,) or "deferred_tool_geometry_enabled" in value:
        require(type(value.get("deferred_tool_geometry_enabled")) is bool
                and value["deferred_tool_geometry_enabled"] is (mode in DEFERRED_TOOL_GEOMETRY_MODES),
                "Graphics deferred_tool_geometry_enabled does not match the requested runtime control")
        extras["deferred_tool_geometry_enabled"] = value["deferred_tool_geometry_enabled"]
    if mode == METAL_ARRIVAL_MODE or "metal_arrival_bursts_enabled" in value:
        require(type(value.get("metal_arrival_bursts_enabled")) is bool
                and value["metal_arrival_bursts_enabled"] is (mode == METAL_ARRIVAL_MODE),
                "Graphics metal_arrival_bursts_enabled does not match the requested runtime control")
        extras["metal_arrival_bursts_enabled"] = value["metal_arrival_bursts_enabled"]
    if mode == HELD_STATIC_CHART_MODE or "holds_static_chart_drawing" in value:
        require(type(value.get("holds_static_chart_drawing")) is bool
                and value["holds_static_chart_drawing"] is (mode == HELD_STATIC_CHART_MODE),
                "Graphics holds_static_chart_drawing does not match the requested runtime control")
        extras["holds_static_chart_drawing"] = value["holds_static_chart_drawing"]
    if mode == "normal":
        require(all(type(value.get(field)) is bool for field in RUNTIME_FLAGS), "Normal runtime feature metadata is incomplete")
        flags = {field: value[field] for field in RUNTIME_FLAGS}
        require(flags["lifecycle_effects_enabled"] and flags["incremental_history_ordering"] == flags["optimized_chart_preparation"],
                "Normal runtime feature metadata does not identify the baseline or combined production path")
        if promoted_normal:
            require(flags["incremental_history_ordering"] and flags["optimized_chart_preparation"],
                    "Promoted normal stream/clock path requires both history and preparation optimizations")
        if extras.get("ordered_chart_publication", False):
            require(promoted_normal and extras.get("canvas_frame_clock") is True
                    and flags["incremental_history_ordering"] and flags["optimized_chart_preparation"],
                    "Promoted normal ordered publication requires stream writes, Canvas clock, history and preparation optimizations")
        return flags | extras
    expected = {"incremental_history_ordering": mode in ("runtime-history-order", "runtime-optimized", "runtime-no-lifecycle") + NEXT_RUNTIME_MODES,
                "optimized_chart_preparation": mode in ("runtime-chart-preparation", "runtime-optimized", "runtime-no-lifecycle") + NEXT_RUNTIME_MODES,
                "lifecycle_effects_enabled": mode != "runtime-no-lifecycle"}
    for field, enabled in expected.items():
        if mode in RUNTIME_MODES or field in value:
            require(type(value.get(field)) is bool and value[field] is enabled,
                    f"Graphics {field} does not match the requested runtime control")
    return {field: value[field] for field in RUNTIME_FLAGS if field in value} | extras


def tool_path_point_counts(snapshot):
    counts = {field: snapshot.get(field) for field in TOOL_PATH_POINT_COUNTERS}
    for field, count in counts.items():
        require(type(count) is int and 0 <= count <= 2**64 - 1, f"{field} must be a complete UInt64 tool-path counter")
    require(counts["tool_path_output_points"] <= counts["tool_path_input_points"],
            "Tool-path output points exceed input points")
    return counts


def chart_publication_interval(value, mode):
    field = "chart_publication_interval_seconds"
    if field not in value and mode not in (DEFERRED_TOOL_GEOMETRY_2HZ_MODE, METAL_ARRIVAL_MODE, *METAL_CHART_MODES, HELD_STATIC_CHART_MODE, FROZEN_SCALARS_MODE, HELD_USAGE_MODE, RETAINED_USAGE_MODE, *NEW_RUNTIME_MODES, *REUSE_RUNTIME_MODES):
        return None
    interval = value.get(field)
    expected = .5 if mode == DEFERRED_TOOL_GEOMETRY_2HZ_MODE else 1.0
    # Exact equality to finite protocol constants also rejects NaN/infinity and
    # huge integers without converting them to float; bool must not equal 1.
    require(type(interval) in (int, float) and interval == expected,
            "Graphics chart_publication_interval_seconds does not match the requested cadence")
    return interval


def held_static_chart_counts(value, mode):
    """Optional on old products; complete and internally consistent once present."""
    roles = value.get("roles", {})
    require(isinstance(roles, dict), "Static chart drawing roles must be an object")
    supplied = any(field in role for role in roles.values() if isinstance(role, dict)
                   for field in HELD_STATIC_CHART_COUNTERS)
    if not supplied and mode != HELD_STATIC_CHART_MODE:
        return None
    require(type(value.get("holds_static_chart_drawing")) is bool
            and value["holds_static_chart_drawing"] is (mode == HELD_STATIC_CHART_MODE),
            "Static chart drawing counters lack matching hold metadata")
    require(isinstance(roles, dict) and set(roles) == {"static_chart", "cursor", "rail_bars", "rail_decorations"},
            "Static chart drawing counters lack complete roles")
    counters = {}
    for name, role in roles.items():
        require(isinstance(role, dict), f"Invalid static chart drawing role {name}")
        counts = {field: role.get(field) for field in HELD_STATIC_CHART_COUNTERS}
        for field, count in counts.items():
            require(type(count) is int and 0 <= count <= 2**64 - 1,
                    f"graphics.{name}.{field} must be a complete UInt64 drawing counter")
        require(counts["drawing_update_attempts"] == counts["drawing_updates_applied"] + counts["drawing_updates_held"],
                f"Static chart drawing update counters do not reconcile for {name}")
        if mode != HELD_STATIC_CHART_MODE or name != "static_chart":
            require(counts["drawing_updates_held"] == counts["drawing_hold_resets"] == 0,
                    f"Unexpected held static drawing activity for {name}")
        counters[name] = counts
    return counters


def metal_arrival_contract(snapshot, mode, *, completed_visible_workload=False):
    value = snapshot.get("graphics_diagnostics", {})
    metadata = ("metal_arrival_bursts_enabled", "arrival_backend")
    supplied = any(field in value for field in metadata) or any(field in snapshot for field in METAL_ARRIVAL_COUNTERS)
    if not supplied and mode != METAL_ARRIVAL_MODE:
        return None
    native = mode in NATIVE_GPU_MODES or mode == "normal" and "native_gpu_backend" in value
    enabled = mode == METAL_ARRIVAL_MODE
    backend = None
    if native or any(field in value for field in metadata):
        require(type(value.get("metal_arrival_bursts_enabled")) is bool
                and value["metal_arrival_bursts_enabled"] is enabled,
                "Metal arrival counters lack matching enabled metadata")
        backend = ("metal-full-chart-shader" if mode in METAL_CHART_MODES else
                   "metal-primitive-effects" if mode in PRIMITIVE_EFFECTS_MODES else
                   "metal-shader" if enabled else "canvas")
        require(value.get("arrival_backend") == backend, "Arrival backend does not match the requested mode")
    counters = {field: snapshot.get(field) for field in METAL_ARRIVAL_COUNTERS}
    for field, count in counters.items():
        require(type(count) is int and 0 <= count <= 2**64 - 1,
                f"{field} must be a complete UInt64 Metal arrival counter")
    require(counters["metal_arrival_failures"] == 0, "Metal arrival renderer reported failures")
    if enabled:
        require(counters["metal_arrival_frames"] == counters["metal_arrival_submissions"],
                "Metal arrival frames do not reconcile with committed submissions")
        if completed_visible_workload:
            require(counters["metal_arrival_submissions"] > 0, "Metal arrival workload did not submit rendered frames")
    else:
        require(all(count == 0 for count in counters.values()), "Non-Metal arrival mode executed Metal work")
    return {"arrival_backend": backend, "counters": counters}


def metal_full_chart_contract(snapshot, mode, *, completed_visible_workload=False, expected_closed=False):
    """Retained Metal work and lifetime evidence, not measured GPU consumption."""
    value = snapshot.get("graphics_diagnostics", {})
    enabled = mode in METAL_CHART_MODES
    if not enabled and not any(field in value for field in ("metal_full_chart_enabled", "metal_full_chart")):
        return None
    require(type(value.get("metal_full_chart_enabled")) is bool and value["metal_full_chart_enabled"] is enabled,
            "Full Metal chart counters lack matching enabled metadata")
    counts = value.get("metal_full_chart")
    require(isinstance(counts, dict), "Full Metal chart counters are missing")
    for field in METAL_FULL_CHART_FIELDS:
        require(type(counts.get(field)) is int and 0 <= counts[field] <= 2**64 - 1,
                f"graphics.metal_full_chart.{field} must be a complete UInt64 counter")
    cached = mode == METAL_CACHED_CHART_MODE
    cache_supplied = cached or any(field in counts for field in METAL_CACHE_FIELDS)
    if cached or "metal_static_cache_enabled" in value:
        require(type(value.get("metal_static_cache_enabled")) is bool
                and value["metal_static_cache_enabled"] is cached,
                "Metal static cache counters lack matching enabled metadata")
    if cache_supplied:
        for field in METAL_CACHE_FIELDS:
            require(type(counts.get(field)) is int and 0 <= counts[field] <= 2**64 - 1,
                    f"graphics.metal_full_chart.{field} must be a complete UInt64 counter")
        if not cached:
            require(all(counts[field] == 0 for field in METAL_CACHE_FIELDS if field != "effect_clock_ticks"),
                    "Uncached mode executed cached Metal chart work")
            require(enabled or counts["effect_clock_ticks"] == 0,
                    "Non-Metal chart mode executed a Metal effects clock")
        else:
            require(all(counts[field] <= counts["static_scene_revisions"] for field in METAL_SCENE_REVISION_CAUSES)
                    and sum(counts[field] for field in METAL_SCENE_REVISION_CAUSES) >= counts["static_scene_revisions"],
                    "Cached Metal scene revisions lack complete bounded invalidation causes")
            require(counts["static_rasterizations"] <= counts["static_cache_composites"] == counts["static_frames"],
                    "Cached Metal static rasterizations and composites do not reconcile")
            require(counts["current_texture_bytes"] <= counts["peak_texture_bytes"]
                    and (counts["live_hosts"] > 0 or counts["current_texture_bytes"] == 0),
                    "Cached Metal texture lifetime does not reconcile")
            require(counts["frames_skipped"] == 0, "Cached Metal chart skipped submitted frame work")
    if not enabled:
        require(all(counts[field] == 0 for field in METAL_FULL_CHART_FIELDS),
                "Non-Metal chart mode executed full Metal chart work")
        return {"enabled": False, "counters": counts}
    require(value.get("native_gpu_backend") == "metal-persistent-chart"
            and value.get("arrival_backend") == "metal-full-chart-shader",
            "Full Metal chart backend metadata differs")
    require(counts["hosts_created"] - counts["hosts_destroyed"] == counts["live_hosts"]
            and counts["live_hosts"] <= counts["peak_hosts"] <= counts["hosts_created"]
            and (counts["hosts_created"] == 0 or counts["peak_hosts"] > 0),
            "Full Metal chart host lifecycle does not reconcile")
    require(counts["current_buffer_bytes"] <= counts["peak_buffer_bytes"]
            and (counts["live_hosts"] > 0 or counts["current_buffer_bytes"] == 0),
            "Full Metal chart retained buffer lifetime does not reconcile")
    require(counts["failures"] == 0, "Full Metal chart renderer reported failures")
    require(all(counts[field] <= counts["submissions"] for field in
                ("static_frames", "arrival_frames", "completion_frames", "twinkle_frames")),
            "Full Metal chart effect frames exceed submitted work")
    for field in ("native_gpu_canvas_draws", "live_canvases", "peak_live_canvases", "live_renderers",
                  "peak_live_renderers", "current_bitmap_bytes", "peak_bitmap_bytes", "current_layer_image_bytes",
                  "peak_layer_image_bytes", "layer_bitmap_presentations", "layer_bitmap_failures", "layer_bitmap_native_draws"):
        require(unsigned(value.get(field, 0), "graphics." + field) == 0,
                "Full Metal chart used Canvas, ImageRenderer, or bitmap fallback: " + field)
    for field in CANVAS_CLOCK_COUNTERS + NATIVE_CANVAS_GROUP_COUNTERS + METAL_ARRIVAL_COUNTERS:
        require(type(snapshot.get(field)) is int and snapshot[field] == 0,
                "Full Metal chart executed legacy drawing or clock work: " + field)
    roles = value.get("roles")
    require(isinstance(roles, dict) and set(roles) == {"static_chart", "cursor", "rail_bars", "rail_decorations"},
            "Full Metal chart legacy role evidence is incomplete")
    require(all(type(role) is dict and all(type(count) in (int, float) and count == 0 for count in role.values())
                for role in roles.values()), "Full Metal chart created or drew a legacy Canvas role")
    if completed_visible_workload:
        require(counts["geometry_uploads"] > 0 and counts["submissions"] > 0 and counts["static_frames"] > 0
                and counts["arrival_frames"] > 0 and (cached or counts["twinkle_frames"] > 0),
                "Full Metal chart workload lacks positive static, arrival, or twinkle submissions")
        require(counts["peak_buffer_bytes"] > 0, "Full Metal chart workload lacks retained geometry allocations")
        if cached:
            require(0 < counts["static_rasterizations"] < counts["static_cache_composites"]
                    and counts["peak_texture_bytes"] > 0,
                    "Cached Metal workload did not reuse a populated rendered texture")
    if cached:
        validate_retained_twinkles(value, mode, completed_visible_workload=completed_visible_workload,
                                  expected_closed=expected_closed)
    if expected_closed:
        require(counts["live_hosts"] == counts["current_buffer_bytes"] == 0,
                "Full Metal chart resources remain live after windows closed")
        if cached:
            require(counts["current_texture_bytes"] == 0,
                    "Cached Metal texture resources remain live after windows closed")
    return {"enabled": True, "counters": counts,
            "frame_delivery_qualified": counts["frames_skipped"] == 0,
            **({"static_cache_enabled": True,
                "texture_scope": "Retained static render-target allocations; excludes drawables and physical GPU memory"}
               if cached else {}),
            "buffer_scope": "Retained geometry and descriptor allocations; excludes drawable textures and physical GPU memory"}


def metal_primitive_effects_contract(snapshot, mode, *, completed_visible_workload=False, expected_closed=False):
    """Bounded native overlay lifetime evidence; static chart pixels remain Canvas work."""
    value = snapshot.get("graphics_diagnostics", {})
    enabled = mode in PRIMITIVE_EFFECTS_MODES
    if not enabled and not any(field in value for field in ("metal_primitive_effects_enabled", "metal_primitive_effects")):
        return None
    require(type(value.get("metal_primitive_effects_enabled")) is bool
            and value["metal_primitive_effects_enabled"] is enabled,
            "Primitive Metal effects counters lack matching enabled metadata")
    counts = value.get("metal_primitive_effects")
    require(isinstance(counts, dict), "Primitive Metal effects counters are missing")
    for field in METAL_PRIMITIVE_EFFECTS_FIELDS:
        require(type(counts.get(field)) is int and 0 <= counts[field] <= 2**64 - 1,
                f"graphics.metal_primitive_effects.{field} must be a complete UInt64 counter")
    if not enabled:
        require(all(counts[field] == 0 for field in METAL_PRIMITIVE_EFFECTS_FIELDS),
                "Nonprimitive mode executed primitive Metal effects work")
        return {"enabled": False, "counters": counts}
    require(value.get("native_gpu_backend") == "swiftui-canvas-drawing-group"
            and value.get("arrival_backend") == "metal-primitive-effects",
            "Primitive Metal effects backend metadata differs")
    full_chart = metal_full_chart_contract(snapshot, mode)
    require(full_chart is not None and full_chart["enabled"] is False,
            "Primitive Metal effects lack complete inactive full-chart Metal evidence")
    require(counts["hosts_created"] - counts["hosts_destroyed"] == counts["live_hosts"]
            and counts["live_hosts"] <= counts["peak_hosts"] <= counts["hosts_created"]
            and (counts["hosts_created"] == 0 or counts["peak_hosts"] > 0),
            "Primitive Metal effects host lifecycle does not reconcile")
    require(counts["current_buffer_bytes"] <= counts["peak_buffer_bytes"]
            and (counts["live_hosts"] > 0 or counts["current_buffer_bytes"] == 0),
            "Primitive Metal effects retained buffer lifetime does not reconcile")
    require(counts["frames_skipped"] == counts["failures"] == counts["fallbacks"] == 0,
            "Primitive Metal effects reported skipped frames, failures, or fallback drawing")
    require(all(counts[field] <= counts["submissions"] for field in
                ("clears", "arrival_frames", "completion_frames", "twinkle_frames")),
            "Primitive Metal effects frames exceed submitted work")
    roles = value.get("roles")
    require(isinstance(roles, dict), "Primitive Metal effects legacy role evidence is incomplete")
    decoration = roles.get("rail_decorations")
    require(isinstance(decoration, dict), "Primitive Metal effects decoration role evidence is missing")
    require(type(decoration.get("draws")) is int and decoration["draws"] == 0
            and type(decoration.get("skipped_draws")) is int and decoration["skipped_draws"] == 0,
            "Primitive Metal effects executed legacy Canvas decoration drawing")
    if completed_visible_workload:
        # The network completion acknowledgment precedes the animation tail.
        # Completion frames are proven by runtime phase windows. Synchronized
        # traffic need not exercise overlapping glints; runtime reports that
        # coverage separately from the required dedicated fidelity evidence.
        require(counts["descriptor_uploads"] > 0 and counts["submissions"] > 0
                and counts["arrival_frames"] > 0 and counts["peak_buffer_bytes"] > 0,
                "Primitive Metal effects workload lacks positive arrival submissions or retained descriptors")
    if expected_closed:
        require(counts["live_hosts"] == counts["current_buffer_bytes"] == 0,
                "Primitive Metal effects resources remain live after windows closed")
    return {"enabled": True, "counters": counts, "frame_delivery_qualified": True,
            "buffer_scope": "Retained primitive and descriptor allocations; excludes drawable textures and physical GPU memory"}


def runtime_mechanism_contract(snapshot, mode, namespace, flag, enabled_modes, fields, *, completed_visible_workload=False):
    """New products prove each delivery mechanism; historical absent metadata stays optional."""
    value = snapshot.get("graphics_diagnostics", {})
    enabled = mode in enabled_modes
    if mode not in NEW_RUNTIME_MODES and flag not in value and namespace not in value:
        return None
    require(type(value.get(flag)) is bool and value[flag] is enabled,
            f"Graphics {namespace} counters lack matching enabled metadata")
    counts = value.get(namespace)
    require(isinstance(counts, dict), f"Graphics {namespace} counters are missing")
    for field in fields:
        require(type(counts.get(field)) is int and 0 <= counts[field] <= 2**64 - 1,
                f"graphics.{namespace}.{field} must be a complete UInt64 counter")
    if not enabled:
        require(all(counts[field] == 0 for field in fields), f"Inactive {namespace} mode executed mechanism work")
    elif completed_visible_workload:
        positive = fields if namespace == "batched_telemetry" else ("resolutions",)
        require(all(counts[field] > 0 for field in positive),
                f"Completed visible workload lacks positive {namespace} mechanism evidence")
    return {"enabled": enabled, "counters": counts}


def batched_telemetry_contract(snapshot, mode, *, completed_visible_workload=False):
    result = runtime_mechanism_contract(snapshot, mode, "batched_telemetry", "batched_telemetry_delivery_enabled",
        BATCHED_TELEMETRY_MODES, BATCHED_TELEMETRY_COUNTERS, completed_visible_workload=completed_visible_workload)
    if result is not None:
        counts = result["counters"]
        require(counts["snapshots_materialized"] <= counts["compact_states_enqueued"]
                and counts["projection_refreshes"] == counts["batches_applied"]
                and counts["events_applied"] >= counts["batches_applied"],
                "Batched telemetry materialization or projection counters do not reconcile")
    return result


def atomic_chart_scale_contract(snapshot, mode, *, completed_visible_workload=False):
    result = runtime_mechanism_contract(snapshot, mode, "atomic_chart_scale", "atomic_chart_scale_enabled",
        ATOMIC_CHART_SCALE_MODES, ATOMIC_CHART_SCALE_COUNTERS, completed_visible_workload=completed_visible_workload)
    if result is not None:
        require(result["counters"]["scale_changes"] <= result["counters"]["resolutions"],
                "Atomic chart scale changes exceed resolutions")
    return result


def reuse_cache_contract(snapshot, mode, *, completed_visible_workload=False, expected_closed=False):
    """Bounded executed reuse, separate from semantic parity and resource use."""
    value = snapshot.get("graphics_diagnostics", {})
    supplied = any(flag in value or namespace in value for namespace, flag, *_ in REUSE_CACHE_SPECS)
    if mode not in REUSE_RUNTIME_MODES and not supplied:
        return None
    result = {}
    for namespace, flag, enabled_modes, counters, maximum in REUSE_CACHE_SPECS:
        enabled = mode in enabled_modes
        require(type(value.get(flag)) is bool and value[flag] is enabled,
                f"Graphics {namespace} counters lack matching enabled metadata")
        raw = value.get(namespace)
        require(isinstance(raw, dict), f"Graphics {namespace} counters are missing")
        fields = counters + REUSE_CACHE_GAUGES + (("current_caches", "peak_caches", "max_entries_per_cache")
                                                 if namespace == "rail_geometry_cache" else ())
        counts = {field: raw.get(field) for field in fields}
        for field, count in counts.items():
            require(type(count) is int and 0 <= count <= 2**64 - 1,
                    f"graphics.{namespace}.{field} must be a complete UInt64 counter")
        require(counts["current_entries"] <= counts["peak_entries"] <= maximum,
                f"{namespace} entries exceed the bounded cache capacity")
        if namespace == "rail_geometry_cache":
            require(counts["max_entries_per_cache"] == 24, "Rail geometry cache capacity changed")
            require(counts["current_caches"] <= counts["peak_caches"] <= 2
                    and counts["current_caches"] <= counts["current_entries"] <= 24 * counts["current_caches"]
                    and counts["peak_caches"] <= counts["peak_entries"] <= 24 * counts["peak_caches"],
                    "Rail geometry cache owner accounting is incomplete or exceeds both fixed visible chart instances")
            require(type(value.get("rail_geometry_cache_used")) is bool
                    and value["rail_geometry_cache_used"] is (counts["builds"] > 0),
                    "Rail geometry cache used metadata does not match executed builds")
        if not enabled:
            inactive = counters + REUSE_CACHE_GAUGES + (("current_caches", "peak_caches") if namespace == "rail_geometry_cache" else ())
            require(all(counts[field] == 0 for field in inactive),
                    f"Inactive {namespace} mode executed cache work")
        elif completed_visible_workload:
            require(all(counts[field] > 0 for field in counters) and counts["peak_entries"] > 0,
                    f"Completed visible workload lacks positive {namespace} reuse evidence")
        if expected_closed:
            require(counts["current_entries"] == 0, f"{namespace} entries remain live after windows closed")
        result[namespace] = {"enabled": enabled, "counters": counts}
    return result


def scalar_presentation_contract(snapshot, mode, *, require_frozen=False, expected_closed=False):
    """Authenticate the scalar ablation without treating held UI as a gate pass."""
    value = snapshot.get("graphics_diagnostics", {})
    fields = ("frozen_scalar_presentation_enabled", "scalar_instrumentation_enabled", "scalar_presentation")
    if mode not in (FROZEN_SCALARS_MODE, HELD_USAGE_MODE, RETAINED_USAGE_MODE) and not any(field in value for field in fields):
        return None
    enabled, instrumented = mode == FROZEN_SCALARS_MODE, mode in ("normal", FROZEN_SCALARS_MODE, HELD_USAGE_MODE, RETAINED_USAGE_MODE)
    for field, expected in zip(fields[:2], (enabled, instrumented)):
        require(type(value.get(field)) is bool and value[field] is expected,
                f"Graphics {field} does not match the requested scalar diagnostic")
    raw = value.get("scalar_presentation")
    require(isinstance(raw, dict), "Scalar presentation diagnostic counters are missing")
    counts = {}
    for field in SCALAR_PRESENTATION_COUNTERS + SCALAR_PRESENTATION_GAUGES:
        count = raw.get(field)
        require(type(count) is int and 0 <= count <= 2**64 - 1,
                f"scalar_presentation.{field} must be a complete UInt64 counter")
        counts[field] = count

    def leaf_counts(values, label):
        require(isinstance(values, dict) and set(values) == set(SCALAR_LEAVES), f"{label} requires all five scalar leaf counters")
        require(all(type(count) is int and 0 <= count <= 2**64 - 1 for count in values.values()),
                f"{label} must contain complete UInt64 counters")
        return values

    leaves = leaf_counts(raw.get("leaf_body_updates"), "scalar_presentation.leaf_body_updates")

    def frames(values, label):
        require(isinstance(values, dict) and len(values) <= 16, f"{label} frame inventory is invalid")
        for name, rect in values.items():
            require(isinstance(name, str) and 0 < len(name.encode()) <= 64 and isinstance(rect, dict)
                    and set(rect) == {"x", "y", "width", "height"}, f"{label} frame is missing or malformed")
            require(all(finite_numeric(rect[field]) for field in rect)
                    and rect["width"] > 0 and rect["height"] > 0
                    and math.isfinite(float(rect["x"]) + float(rect["width"]))
                    and math.isfinite(float(rect["y"]) + float(rect["height"])), f"{label} frame must be finite and positive")
        return values

    frozen, owners = raw.get("frozen_owners"), raw.get("presentation_owners")
    for name, entries in (("frozen_owners", frozen), ("presentation_owners", owners)):
        require(isinstance(entries, dict) and len(entries) <= 2, f"Scalar {name} owner inventory is invalid")
        roles = []
        for owner, entry in entries.items():
            require(isinstance(owner, str) and re.fullmatch(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}", owner)
                    and isinstance(entry, dict), f"Scalar {name} owner identity is invalid")
            role = entry.get("role")
            require(role in ("dashboard", "popover") or name == "presentation_owners" and role is None,
                    f"Scalar {name} owner role is invalid")
            if role is not None:
                roles.append(role)
            if name == "frozen_owners":
                require(isinstance(entry.get("capture_identity"), str)
                        and re.fullmatch(r"[0-9a-f]{64}", entry["capture_identity"]),
                        "Frozen scalar capture identity is incomplete")
                require(bool(frames(entry.get("frames"), "Frozen scalar captured")), "Frozen scalar capture lacks native frames")
            else:
                frames(entry.get("current_frames"), "Scalar current")
                leaf_counts(entry.get("leaf_body_updates"), "Scalar owner leaf_body_updates")
                if "presented_values" in entry or mode in (HELD_USAGE_MODE, RETAINED_USAGE_MODE):
                    presented_scalar_values(entry.get("presented_values"))
        require(len(roles) == len(set(roles)), f"Scalar {name} owner roles are duplicated")
    require(counts["freezes_captured"] >= counts["freezes_released"]
            and counts["freezes_captured"] - counts["freezes_released"] == counts["current_frozen_owners"] == len(frozen)
            and counts["current_frozen_owners"] <= counts["peak_frozen_owners"] <= counts["freezes_captured"] <= 2,
            "Frozen scalar owner capture/release counters do not reconcile")
    require(set(frozen) <= set(owners), "Frozen scalar owners lack live presentation ownership")
    for owner, entry in frozen.items():
        require(entry["role"] == owners[owner]["role"], "Frozen scalar owner role differs from live presentation")
    require(all(sum(entry["leaf_body_updates"][leaf] for entry in owners.values()) <= leaves[leaf] for leaf in SCALAR_LEAVES),
            "Scalar owner body updates exceed aggregate counters")
    if not enabled:
        require(not frozen and all(counts[field] == 0 for field in
                    ("freezes_captured", "freezes_released") + SCALAR_PRESENTATION_GAUGES),
                "Non-frozen mode held scalar presentation")
    if not instrumented:
        require(not owners and all(count == 0 for count in counts.values()) and all(count == 0 for count in leaves.values()),
                "Inactive scalar instrumentation executed work")
    native = value.get("native_canvas_frames")
    native_draws = value.get("native_canvas_draws")
    require(isinstance(native, dict) and len(native) <= 2, "Scalar diagnostic native chart frame inventory is incomplete")
    require(isinstance(native_draws, dict) and set(native_draws) == set(native)
            and all(type(count) is int and 0 <= count <= 2**64 - 1 for count in native_draws.values()),
            "Scalar diagnostic per-chart drawing counters are incomplete or invalid")
    for identity, frame in native.items():
        require(isinstance(identity, str) and re.fullmatch(r"[1-9][0-9]{0,19}", identity)
                and int(identity) <= 2**64 - 1 and isinstance(frame, dict) and frame.get("role") == "static_chart"
                and set(frame) == {"role", "width", "height", "scale"}, "Scalar diagnostic native chart identity is invalid")
        require(all(finite_numeric(frame[field]) and frame[field] >= 0
                    for field in ("width", "height", "scale")), "Scalar diagnostic native chart geometry is invalid")
    if require_frozen:
        require(enabled and counts["freezes_captured"] == counts["current_frozen_owners"] == 2
                and counts["freezes_released"] == 0 and len(owners) == 2
                and {entry["role"] for entry in frozen.values()} == {"dashboard", "popover"},
                "Runtime scalar ablation requires exactly two captured visible owners")
    if expected_closed:
        require(not owners and not frozen and not native and counts["current_frozen_owners"] == 0,
                "Scalar diagnostic owners or native charts remain live after closing")
    return {"enabled": enabled, "instrumented": instrumented, "counters": counts,
            "leaf_body_updates": leaves, "frozen_owners": frozen, "presentation_owners": owners,
            "native_canvas_frames": native, "native_canvas_draws": native_draws,
            "acceptance_eligible": mode not in (FROZEN_SCALARS_MODE, HELD_USAGE_MODE)}


def presented_scalar_values(values):
    require(isinstance(values, dict) and set(values) <= {"header", "metrics", "compact_details", "dashboard_usage"},
            "Rendered scalar leaf inventory is invalid")
    for leaf, fields in values.items():
        inventory = {"header": {"status", "model", "activity"}, "metrics": {"rate", "gpu"},
                     "compact_details": {"response"}, "dashboard_usage": {"scope", "values"}}[leaf]
        require(isinstance(fields, dict) and set(fields) == inventory, "Rendered scalar leaf values are incomplete")
        if leaf == "dashboard_usage":
            require(fields["scope"] in ("sinceLaunch", "selectedPeriod", "today"), "Rendered usage scope is invalid")
            usage_presentation_values(fields["values"], "Rendered dashboard")
        else:
            for field, text in fields.items():
                require(leaf == "header" and field == "activity" and text is None
                        or isinstance(text, str) and 0 < len(text.encode()) <= 1024,
                        "Rendered scalar labels are missing or exceed their bound")
    return values


def usage_presentation_values(values, label):
    require(isinstance(values, dict) and set(values) == set(HELD_USAGE_VALUE_COUNTS + HELD_USAGE_VALUE_FLAGS),
            f"{label} usage value inventory is incomplete")
    for field in HELD_USAGE_VALUE_COUNTS:
        require(field == "input_tokens" and values[field] is None
                or type(values[field]) is int and 0 <= values[field] <= 2**64 - 1,
                f"{label}.{field} must be an unsigned count (input may be unavailable)")
    require(all(type(values[field]) is bool for field in HELD_USAGE_VALUE_FLAGS),
            f"{label} usage flags must be complete booleans")
    require(values["active_requests"] <= values["requests"], f"{label} active usage exceeds requests")
    return values


def captured_json_equal(left, right):
    """JSON number representation may differ; booleans must never equal counts."""
    if isinstance(left, dict) and isinstance(right, dict):
        return set(left) == set(right) and all(captured_json_equal(left[key], right[key]) for key in left)
    if type(left) is bool or type(right) is bool:
        return type(left) is type(right) and left == right
    if type(left) in (int, float) and type(right) in (int, float):
        return finite_numeric(left) and finite_numeric(right) and left == right
    return type(left) is type(right) and left == right


def held_usage_contract(snapshot, mode, *, require_held=False, expected_closed=False):
    """One dashboard usage receipt; this does not freeze either complete window."""
    value = snapshot.get("graphics_diagnostics", {})
    if mode != HELD_USAGE_MODE and not any(field in value for field in ("held_usage_enabled", "held_usage")):
        return None
    enabled = mode == HELD_USAGE_MODE
    require(type(value.get("held_usage_enabled")) is bool and value["held_usage_enabled"] is enabled,
            "Graphics held_usage_enabled does not match the requested diagnostic")
    raw = value.get("held_usage")
    require(isinstance(raw, dict) and set(raw) == set(("enabled", "monitoring_epoch", "owners")
            + HELD_USAGE_COUNTERS + HELD_USAGE_GAUGES) and type(raw["enabled"]) is bool and raw["enabled"] is enabled,
            "Held usage namespace is incomplete or its enabled flag differs")
    counts = {field: unsigned(raw.get(field), "held_usage." + field)
              for field in HELD_USAGE_COUNTERS + HELD_USAGE_GAUGES}
    uuid_pattern = r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}"
    epoch = raw["monitoring_epoch"]
    require(epoch is None or isinstance(epoch, str) and re.fullmatch(uuid_pattern, epoch),
            "Held usage live monitoring epoch is invalid")
    owners = raw["owners"]
    require(isinstance(owners, dict) and len(owners) <= 1, "Held usage may retain only one dashboard owner")
    for owner, entry in owners.items():
        require(isinstance(owner, str) and re.fullmatch(uuid_pattern, owner) and isinstance(entry, dict)
                and set(entry) == {"role", "epoch", "capture_identity", "capture_payload_json", "scope", "values", "frames"}
                and entry["role"] == "dashboard", "Held usage dashboard receipt is incomplete")
        require(isinstance(entry["epoch"], str) and re.fullmatch(uuid_pattern, entry["epoch"])
                and entry["epoch"] == epoch, "Held usage receipt belongs to a stale monitoring epoch")
        require(entry["scope"] in ("sinceLaunch", "selectedPeriod", "today"), "Held usage scope is invalid")
        usage_presentation_values(entry["values"], "Held dashboard")
        frames = entry["frames"]
        required_frames = {"activity-chart", "main-activity-plot", "request-rail-band", "statistics-row", "native-window"}
        require(isinstance(frames, dict) and 0 < len(frames) <= 16 and required_frames <= set(frames),
                "Held usage capture lacks a bounded complete native frame inventory")
        for name, rect in frames.items():
            require(isinstance(name, str) and 0 < len(name.encode()) <= 64 and isinstance(rect, dict)
                    and set(rect) == {"x", "y", "width", "height"}
                    and all(finite_numeric(rect[field]) for field in rect)
                    and rect["width"] > 0 and rect["height"] > 0
                    and math.isfinite(float(rect["x"]) + float(rect["width"]))
                    and math.isfinite(float(rect["y"]) + float(rect["height"])),
                    "Held usage captured frame is malformed, nonfinite, or empty")
        identity, payload = entry["capture_identity"], entry["capture_payload_json"]
        require(isinstance(identity, str) and re.fullmatch(r"[0-9a-f]{64}", identity)
                and isinstance(payload, str) and 0 < len(payload.encode()) <= 8192
                and hashlib.sha256(payload.encode()).hexdigest() == identity,
                "Held usage fingerprint does not bind its captured payload")
        def unique_fields(pairs):
            require(len({key for key, _value in pairs}) == len(pairs), "Held usage payload repeats a JSON field")
            return dict(pairs)
        try:
            envelope = json.loads(payload, object_pairs_hook=unique_fields,
                                  parse_constant=lambda _value: (_ for _ in ()).throw(ValueError("Nonfinite JSON")))
        except (ValueError, TypeError) as error:
            raise ValueError("Held usage captured payload is invalid JSON") from error
        require(isinstance(envelope, dict), "Held usage fingerprint envelope is invalid")
        usage_presentation_values(envelope.get("values"), "Held usage fingerprint")
        require(captured_json_equal(envelope, {"schema": "dashboard-held-usage-v1", "owner": owner, "epoch": entry["epoch"],
                            "scope": entry["scope"], "values": entry["values"], "frames": frames}),
                "Held usage fingerprint payload differs from the native receipt")
    require(counts["captures"] >= counts["releases"]
            and counts["captures"] - counts["releases"] == counts["current_owners"] == len(owners)
            and counts["current_owners"] <= counts["peak_owners"] <= counts["captures"] <= 1,
            "Held usage owner capture/release counters do not reconcile")
    if not enabled:
        require(not owners and all(count == 0 for count in counts.values()), "Normal control retained held usage")
    if require_held:
        require(enabled and counts["captures"] == counts["current_owners"] == counts["peak_owners"] == 1
                and counts["releases"] == 0, "Runtime held usage requires one immutable dashboard capture")
    if expected_closed:
        require(not owners and counts["current_owners"] == 0, "Held usage owner remains after closing")
    return {"enabled": enabled, "monitoring_epoch": epoch, "counters": counts, "owners": owners,
            "acceptance_eligible": not enabled}


def retained_usage_contract(snapshot, mode, *, require_live=False, expected_closed=False):
    value = snapshot.get("graphics_diagnostics", {})
    if mode != RETAINED_USAGE_MODE and not any(field in value for field in ("retained_usage_fields", "retained_usage")):
        return None
    enabled = mode == RETAINED_USAGE_MODE
    require(type(value.get("retained_usage_fields")) is bool and value["retained_usage_fields"] is enabled,
            "Graphics retained_usage_fields does not match the requested runtime control")
    raw = value.get("retained_usage")
    require(isinstance(raw, dict) and set(raw) == set(("enabled", "owners") + RETAINED_USAGE_COUNTERS + RETAINED_USAGE_GAUGES)
            and type(raw["enabled"]) is bool and raw["enabled"] is enabled, "Retained usage namespace is incomplete")
    counts = {field: raw.get(field) for field in RETAINED_USAGE_COUNTERS + RETAINED_USAGE_GAUGES}
    require(all(type(count) is int and 0 <= count <= 2**64 - 1 for count in counts.values()),
            "Retained usage requires complete UInt64 counters")
    owners = raw["owners"]
    require(isinstance(owners, dict) and len(owners) <= 1, "Retained usage owner inventory exceeds its dashboard bound")
    require(counts["hosts_created"] >= counts["hosts_destroyed"]
            and (counts["hosts_created"] == counts["hosts_destroyed"] if not owners else
                 1 <= counts["hosts_created"] - counts["hosts_destroyed"] <= len(RETAINED_USAGE_FIELDS))
            and counts["current_owners"] == len(owners) <= counts["peak_owners"] <= 1
            and counts["value_apply_attempts"] == counts["value_applies"] + counts["value_apply_skips"],
            "Retained usage host lifetime or apply counters do not reconcile")
    current_epoch = None
    if owners:
        held = held_usage_contract(snapshot, mode)
        require(held is not None and held["monitoring_epoch"] is not None,
                "Retained usage lacks the actual live monitoring epoch witness")
        current_epoch = held["monitoring_epoch"]
    for owner, entry in owners.items():
        require(isinstance(owner, str) and re.fullmatch(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}", owner)
                and isinstance(entry, dict) and set(entry) == {"role", "epoch", "scope", "values", "fields"}
                and entry["role"] == "dashboard", "Retained usage owner identity or role is invalid")
        pending = entry["epoch"] is None and entry["scope"] is None and entry["values"] == {} and entry["fields"] == {}
        if pending:
            require(not require_live and not expected_closed, "Measured retained usage owner has not applied all fields")
            continue
        require(entry["epoch"] == current_epoch
                and counts["hosts_created"] - counts["hosts_destroyed"] == len(RETAINED_USAGE_FIELDS),
                "Retained usage owner monitoring epoch or complete host inventory is invalid")
        require(entry["scope"] in ("sinceLaunch", "selectedPeriod", "today"), "Retained usage scope is invalid")
        usage_presentation_values(entry["values"], "Retained applied dashboard")
        fields = entry["fields"]
        require(isinstance(fields, dict) and set(fields) == set(RETAINED_USAGE_FIELDS),
                "Retained usage lacks all five actually applied value hosts")
        for field in fields.values():
            require(isinstance(field, dict) and set(field) == {"value", "help"}
                    and all(isinstance(text, str) and len(text.encode()) <= 4096 for text in field.values()),
                    "Retained applied host labels/help are incomplete or exceed their bound")
    if not enabled:
        require(not owners and all(count == 0 for count in counts.values()), "Inactive mode executed retained usage work")
    if require_live:
        require(enabled and len(owners) == counts["current_owners"] == counts["peak_owners"] == 1
                and counts["value_applies"] >= len(RETAINED_USAGE_FIELDS),
                "Retained usage did not create and apply all five live dashboard fields")
    if expected_closed:
        require(not owners and counts["current_owners"] == 0, "Retained usage hosts remain live after closing")
    return {"enabled": enabled, "counters": counts, "owners": owners,
            "monitoring_epoch": current_epoch, "acceptance_eligible": True,
            "promotion_eligible": False if enabled else None}


def validate_graphics(snapshot, mode, *, completed_visible_workload=False, expected_closed=False,
                      require_native_normal=False):
    value = snapshot.get("graphics_diagnostics")
    if mode == "normal" and require_native_normal:
        require(isinstance(value, dict) and "native_gpu_backend" in value,
                "Normal native GPU rendering metadata disappeared after it was acknowledged")
    if "graphics_diagnostics" not in snapshot and mode == "normal":
        return {"available": False, "reason": "This frozen app does not expose graphics diagnostic counters; native and kernel memory evidence remain separate."}
    require(isinstance(value, dict) and value.get("enabled") is True and value.get("mode") == mode,
            "App did not acknowledge the requested graphics diagnostic mode")
    require(unsigned(value.get("invalid_events"), "graphics.invalid_events") == 0,
            "Graphics diagnostic counters reported invalid lifecycle events")
    publication_interval = chart_publication_interval(value, mode)
    # Keep the requested mode acknowledgment while applying the complete
    # combined contract to newer production binaries that identify this backend.
    native_normal = mode == "normal" and "native_gpu_backend" in value
    contract = "native-gpu-optimized" if native_normal or mode in RUNTIME_MODES and mode not in METAL_CHART_MODES else mode
    runtime_features = runtime_feature_contract(value, mode)
    held_static_chart_counts(value, mode)
    twinkle_delivery_contract(snapshot, mode)
    metal_arrival = metal_arrival_contract(snapshot, mode, completed_visible_workload=completed_visible_workload)
    full_chart = metal_full_chart_contract(snapshot, mode, completed_visible_workload=completed_visible_workload,
                                          expected_closed=expected_closed)
    primitive_effects = metal_primitive_effects_contract(snapshot, mode,
        completed_visible_workload=completed_visible_workload, expected_closed=expected_closed)
    batched_telemetry = batched_telemetry_contract(snapshot, mode, completed_visible_workload=completed_visible_workload)
    atomic_chart_scale = atomic_chart_scale_contract(snapshot, mode, completed_visible_workload=completed_visible_workload)
    reuse_caches = reuse_cache_contract(snapshot, mode, completed_visible_workload=completed_visible_workload,
                                       expected_closed=expected_closed)
    scalar_presentation = scalar_presentation_contract(snapshot, mode,
        require_frozen=completed_visible_workload and mode == FROZEN_SCALARS_MODE and not expected_closed,
        expected_closed=expected_closed)
    held_usage = held_usage_contract(snapshot, mode,
        require_held=completed_visible_workload and mode == HELD_USAGE_MODE and not expected_closed,
        expected_closed=expected_closed)
    retained_usage = retained_usage_contract(snapshot, mode,
        require_live=completed_visible_workload and mode == RETAINED_USAGE_MODE and not expected_closed,
        expected_closed=expected_closed)
    if completed_visible_workload and mode == FROZEN_SCALARS_MODE:
        require(scalar_presentation["counters"]["freezes_captured"] == 2,
                "Completed scalar diagnostic never captured both visible owners")
    if (mode in (COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE) + DEFERRED_TOOL_GEOMETRY_MODES or "compact_tool_paths_enabled" in value
            or any(field in snapshot for field in TOOL_PATH_POINT_COUNTERS)):
        require("compact_tool_paths_enabled" in value or contract not in NATIVE_GPU_MODES,
                "Tool-path point counters lack feature metadata")
        points = tool_path_point_counts(snapshot)
        if (runtime_features or {}).get("compact_tool_paths_enabled", False):
            if completed_visible_workload:
                require(0 < points["tool_path_output_points"] < points["tool_path_input_points"],
                        "Compact tool paths did not execute positive vertex reduction")
        else:
            require(points["tool_path_output_points"] == points["tool_path_input_points"],
                    "Noncompact tool paths changed the input vertex count")
    if mode in (NO_ARRIVAL_MODE, COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE) + DEFERRED_TOOL_GEOMETRY_MODES or "arrival_effects_enabled" in value or "suppressed_arrival_effects" in snapshot:
        require("arrival_effects_enabled" in value or contract not in NATIVE_GPU_MODES,
                "Arrival suppression counter lacks feature metadata")
        suppressed = unsigned(snapshot.get("suppressed_arrival_effects"), "suppressed_arrival_effects")
        if mode == NO_ARRIVAL_MODE:
            if completed_visible_workload:
                require(suppressed > 0, "No-arrival mode did not suppress arrival effects")
        else:
            require(suppressed == 0, "Baseline mode unexpectedly suppressed arrival effects")
    if (mode in (UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE, COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE) + DEFERRED_TOOL_GEOMETRY_MODES or "ungrouped_native_canvas" in value
            or any(field in snapshot for field in NATIVE_CANVAS_GROUP_COUNTERS)):
        require("ungrouped_native_canvas" in value or contract not in NATIVE_GPU_MODES,
                "Native Canvas grouping counters lack feature metadata")
        grouping = {field: unsigned(snapshot.get(field), field) for field in NATIVE_CANVAS_GROUP_COUNTERS}
        if contract in NATIVE_GPU_MODES:
            callbacks = unsigned(value.get("native_gpu_canvas_draws"), "graphics.native_gpu_canvas_draws")
        else:
            callbacks = 0
        require(sum(grouping.values()) == callbacks, "Native Canvas grouping counters do not reconcile with native callbacks")
        if (runtime_features or {}).get("ungrouped_native_canvas", False):
            if completed_visible_workload:
                require(grouping["ungrouped_native_canvas_draws"] > 0, "Ungrouped native Canvas did not execute drawing callbacks")
        else:
            require(grouping["ungrouped_native_canvas_draws"] == 0, "Grouped native Canvas mode executed ungrouped callbacks")
    if (mode in (DIRECT_TOOL_PLOT_MODE, UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE, COMPACT_TOOL_PATHS_MODE, METAL_ARRIVAL_MODE) + DEFERRED_TOOL_GEOMETRY_MODES or "direct_tool_plot" in value
            or any(field in snapshot for field in DIRECT_TOOL_PLOT_COUNTERS)):
        require("direct_tool_plot" in value or contract not in NATIVE_GPU_MODES,
                "Tool-plot counters lack feature metadata")
        tool_plot = {field: unsigned(snapshot.get(field), field) for field in DIRECT_TOOL_PLOT_COUNTERS}
        if (runtime_features or {}).get("direct_tool_plot", False):
            if completed_visible_workload:
                require(tool_plot["direct_tool_plot_builds"] > 0, "Direct tool plot did not execute geometry builds")
        else:
            require(tool_plot["direct_tool_plot_builds"] == 0, "Legacy tool-plot mode executed direct geometry builds")
    if (mode in ORDERED_PUBLICATION_MODES or "ordered_chart_publication" in value
            or any(field in snapshot for field in ORDERED_PUBLICATION_COUNTERS)):
        require("ordered_chart_publication" in value or contract not in NATIVE_GPU_MODES,
                "Ordered-publication counters lack feature metadata")
        ordered = {field: unsigned(snapshot.get(field), field) for field in ORDERED_PUBLICATION_COUNTERS}
        if (runtime_features or {}).get("ordered_chart_publication", False):
            if completed_visible_workload:
                require(ordered["ordered_chart_publication_queries"] > 0, "Ordered chart publication did not execute queries")
        else:
            require(ordered["ordered_chart_publication_queries"] == 0, "Nonordered mode executed ordered publication queries")
    if (mode in CANVAS_CLOCK_MODES or "canvas_frame_clock" in value
            or any(field in snapshot for field in CANVAS_CLOCK_COUNTERS)):
        clock = {field: unsigned(snapshot.get(field), field) for field in CANVAS_CLOCK_COUNTERS}
        if (runtime_features or {}).get("canvas_frame_clock", False):
            require(clock["rail_timeline_content_updates"] == 0, "Canvas frame-clock mode updated Timeline content")
            # This flag also validates the network-completion acknowledgment,
            # which can precede all completion animation. Controls without
            # Canvas arrivals prove positive ticks in the runtime tail instead.
            if completed_visible_workload and mode not in (NO_ARRIVAL_MODE, METAL_ARRIVAL_MODE, *PRIMITIVE_EFFECTS_MODES):
                require(clock["rail_frame_clock_ticks"] > 0, "Canvas frame-clock mode did not execute frame ticks")
        else:
            require(clock["rail_frame_clock_ticks"] == 0, "Nonclock mode executed Canvas frame ticks")
    if (mode in NEXT_RUNTIME_MODES or (runtime_features and any(field in runtime_features for field in NEXT_RUNTIME_FLAGS))
            or any(field in snapshot for field in SHARED_PREPARATION_COUNTERS)):
        shared = {field: unsigned(snapshot.get(field), field) for field in SHARED_PREPARATION_COUNTERS}
        if not (runtime_features or {}).get("shared_chart_preparation", False):
            require(not any(shared.values()), "Nonshared mode executed shared chart preparation")
        elif completed_visible_workload:
            total = unsigned(snapshot.get("chart_preparations"), "chart_preparations")
            require(0 < shared["shared_chart_normalization_builds"] <= shared["shared_chart_preparations"] == total,
                    "Shared chart preparation lacks complete executed work")
    if (mode in NEXT_RUNTIME_MODES or (runtime_features and any(field in runtime_features for field in NEXT_RUNTIME_FLAGS))
            or "streamed_bodies_without_promises" in snapshot):
        bodies = unsigned(snapshot.get("streamed_bodies_without_promises"), "streamed_bodies_without_promises")
        if not (runtime_features or {}).get("unpromised_stream_body_writes", False):
            require(bodies == 0, "Promised-write mode executed unpromised stream body writes")
        elif completed_visible_workload:
            require(bodies > 0, "Unpromised-write mode did not execute stream body writes")
    if completed_visible_workload and (runtime_features or {}).get("stable_decoration_hosts"):
        require(unsigned(value.get("roles", {}).get("rail_decorations", {}).get("created"), "stable decoration hosts created") > 0,
                "Stable decoration-host mode did not create a decoration host")
    if mode == "normal" and not native_normal:
        for field in ("scalar_presentation_coalesced", "retained_twinkles_enabled"):
            if field in value:
                require(value[field] is False,
                        f"Normal {field} requires native GPU backend metadata")
        if "native_gpu_canvas_draws" in value:
            require(unsigned(value["native_gpu_canvas_draws"], "graphics.native_gpu_canvas_draws") == 0,
                    "Normal native GPU draw activity requires backend metadata")
        require("retained_twinkle_backend" not in value,
                "Normal retained twinkle backend requires native GPU backend metadata")
    coalesced_scalars = contract in COALESCED_SCALAR_MODES
    if coalesced_scalars or "scalar_presentation_publications" in value:
        publications = unsigned(value.get("scalar_presentation_publications"), "graphics.scalar_presentation_publications")
        if coalesced_scalars and completed_visible_workload:
            require(publications > 0, "Completed visible workload did not publish coalesced scalar presentation values")
        elif not coalesced_scalars:
            require(publications == 0, "Coalesced scalar publications occurred outside a coalesced-scalar mode")
    if mode == "cpu-glow":
        require(unsigned(value.get("cpu_glow_fallbacks"), "graphics.cpu_glow_fallbacks") == 0,
                "CPU glow used the framework-blur fallback; the comparison is invalid")
    if mode in GRADIENT_ABLATION_MODES:
        substitutions = unsigned(value.get("gradient_substitutions"), "graphics.gradient_substitutions")
        if completed_visible_workload:
            require(substitutions > 0,
                    "Completed visible workload did not execute any gradient substitutions; the comparison is invalid")
    roles = value.get("roles")
    require(isinstance(roles, dict) and set(roles) == {"static_chart", "cursor", "rail_bars", "rail_decorations"},
            "Graphics diagnostic roles are incomplete")
    fields = ("created", "destroyed", "live", "peak_live", "updates", "renderer_creations", "renderer_updates",
              "renderer_destructions", "live_renderers", "peak_live_renderers", "draws", "skipped_draws",
              "current_pixel_area", "peak_pixel_area", "current_bitmap_bytes", "peak_bitmap_bytes")
    native_gpu = contract in NATIVE_GPU_MODES
    if native_gpu:
        for field, expected in (("scalar_presentation_coalesced", contract in COALESCED_SCALAR_MODES),
                                ("retained_twinkles_enabled", contract in RETAINED_TWINKLE_MODES)):
            if contract != "native-gpu-canvas" or field in value:
                require(type(value.get(field)) is bool and value[field] is expected,
                        f"Graphics {field} does not match the requested native GPU control")
        expected_backend = ("metal-persistent-chart" if mode in METAL_CHART_MODES else
                            "swiftui-canvas" if mode == UNGROUPED_CANVAS_MODE else "swiftui-canvas-drawing-group")
        require(value.get("native_gpu_backend") == expected_backend,
                "App did not acknowledge the requested native GPU Canvas backend")
        native_gpu_draws = unsigned(value.get("native_gpu_canvas_draws"), "graphics.native_gpu_canvas_draws")
        for field in ("live_renderers", "peak_live_renderers", "current_bitmap_bytes", "peak_bitmap_bytes",
                      "current_layer_image_bytes", "peak_layer_image_bytes", "layer_bitmap_presentations",
                      "layer_bitmap_failures", "layer_bitmap_native_draws"):
            if field in value:
                require(unsigned(value[field], f"graphics.{field}") == 0,
                        f"Native GPU Canvas used a renderer or CPU bitmap fallback: {field}")
        if expected_closed:
            require(value.get("live_canvases") == 0 and value.get("current_pixel_area") == 0,
                    "Native GPU Canvas resources remain live at a closed checkpoint")
    validate_retained_twinkles(value, contract, completed_visible_workload=completed_visible_workload,
                              expected_closed=expected_closed)
    layer_destination = mode in LAYER_DESTINATION_MODES
    if layer_destination:
        metadata = {
            "layer_bitmap_pixel_format": "bgra8-premultiplied-first" if mode == "bitmap-layer-bgra" else "rgba8-premultiplied-last",
            "layer_bitmap_color_space": "device-rgb",
            "rail_decorations_enabled": mode != "bitmap-layer-no-decorations",
        }
        for field, expected in metadata.items():
            # Original frozen layer-destination products predate this metadata.
            if mode != "bitmap-layer-destination" or field in value:
                require(type(value.get(field)) is type(expected) and value[field] == expected,
                        f"Graphics {field} does not match the requested layer destination control")
        fields += ("current_layer_image_bytes", "peak_layer_image_bytes")
        presentations = unsigned(value.get("layer_bitmap_presentations"), "graphics.layer_bitmap_presentations")
        for field in ("layer_bitmap_failures", "layer_bitmap_native_draws"):
            require(unsigned(value.get(field), f"graphics.{field}") == 0,
                    f"Layer bitmap destination reported {field}; the comparison is invalid")
    for name, role in roles.items():
        require(isinstance(role, dict), f"Invalid graphics role {name}")
        for field in fields:
            unsigned(role.get(field), f"graphics.{name}.{field}")
        for field in ("max_width_points", "max_height_points", "max_scale"):
            number(role.get(field), f"graphics.{name}.{field}")
        if native_gpu:
            for field in ("renderer_creations", "renderer_updates", "renderer_destructions", "live_renderers",
                          "peak_live_renderers", "current_bitmap_bytes", "peak_bitmap_bytes",
                          "current_layer_image_bytes", "peak_layer_image_bytes"):
                if field in role:
                    require(unsigned(role[field], f"graphics.{name}.{field}") == 0,
                            f"Native GPU Canvas {name} used a renderer or CPU bitmap fallback: {field}")
            if role["live"] == 0:
                require(role["current_pixel_area"] == 0,
                        f"Native GPU Canvas {name} retains pixel area after destruction")
        if mode == "bitmap-layer-no-decorations" and name == "rail_decorations":
            require(all(type(counter) in (int, float) and counter == 0 for counter in role.values()),
                    "Rail decoration work occurred in the no-decorations control")
        require(role["created"] - role["destroyed"] == role["live"]
                and role["renderer_creations"] - role["renderer_destructions"] == role["live_renderers"],
                f"Graphics {name} lifecycle counters do not reconcile")
        for current, peak in (("live", "peak_live"), ("live_renderers", "peak_live_renderers"),
                              ("current_pixel_area", "peak_pixel_area"), ("current_bitmap_bytes", "peak_bitmap_bytes")):
            require(role[peak] >= role[current], f"Graphics {name} peak is below current {current}")
        if layer_destination:
            require(role["peak_layer_image_bytes"] >= role["current_layer_image_bytes"],
                    f"Graphics {name} layer image peak is below current bytes")
            if role["live"] == 0 or expected_closed:
                require(role["current_layer_image_bytes"] == 0,
                        f"Graphics {name} retains layer image bytes after its surface closed")
            if completed_visible_workload and role["draws"] > 0:
                require(role["renderer_creations"] > 0 and role["peak_layer_image_bytes"] > 0,
                        f"Graphics {name} drawing lacks renderer or layer image evidence")
    totals = (
            ("live_canvases", "live", "peak_live_canvases", "peak_live"),
            ("live_renderers", "live_renderers", "peak_live_renderers", "peak_live_renderers"),
            ("current_pixel_area", "current_pixel_area", "peak_pixel_area", "peak_pixel_area"),
            ("current_bitmap_bytes", "current_bitmap_bytes", "peak_bitmap_bytes", "peak_bitmap_bytes"))
    if layer_destination:
        totals += (("current_layer_image_bytes", "current_layer_image_bytes", "peak_layer_image_bytes", "peak_layer_image_bytes"),)
    for global_current, local_current, global_peak, local_peak in totals:
        current = unsigned(value.get(global_current), f"graphics.{global_current}")
        peak = unsigned(value.get(global_peak), f"graphics.{global_peak}")
        require(current == sum(role[local_current] for role in roles.values()), f"Graphics {global_current} total mismatch")
        require(current <= peak <= sum(role[local_peak] for role in roles.values()), f"Graphics {global_peak} is inconsistent")
        if layer_destination and global_peak == "peak_layer_image_bytes":
            require(peak >= max(role[local_peak] for role in roles.values()),
                    "Graphics layer image peak is below a role peak")
    if layer_destination:
        require(presentations == sum(role["draws"] for role in roles.values()),
                "Layer bitmap presentations do not reconcile with drawn role frames")
        if completed_visible_workload:
            require(presentations > 0 and roles["static_chart"]["draws"] > 0
                    and value["peak_layer_image_bytes"] > 0,
                    "Completed visible workload did not present a drawn chart layer image; the comparison is invalid")
    if native_gpu:
        require(native_gpu_draws == sum(role["draws"] for role in roles.values()),
                "Native GPU Canvas callbacks do not reconcile with drawn role frames")
        if completed_visible_workload and mode not in METAL_CHART_MODES:
            require(native_gpu_draws > 0 and roles["static_chart"]["draws"] > 0,
                    "Completed visible workload did not execute native GPU static-chart drawing")
    return {"available": True, "counters": value,
            **({"metal_full_chart": full_chart} if full_chart is not None else {}),
            **({"metal_primitive_effects": primitive_effects} if primitive_effects is not None else {}),
            **({"batched_telemetry": batched_telemetry} if batched_telemetry is not None else {}),
            **({"atomic_chart_scale": atomic_chart_scale} if atomic_chart_scale is not None else {}),
            **({"reuse_caches": reuse_caches} if reuse_caches is not None else {}),
            **({"scalar_presentation": scalar_presentation} if scalar_presentation is not None else {}),
            **({"held_usage": held_usage} if held_usage is not None else {}),
            **({"retained_usage": retained_usage} if retained_usage is not None else {}),
            **({"arrival_backend": metal_arrival["arrival_backend"]} if metal_arrival and metal_arrival["arrival_backend"] is not None else {}),
            **({"chart_publication_interval_seconds": publication_interval} if publication_interval is not None else {}),
            **({"runtime_feature_contract": runtime_features} if runtime_features is not None else {}),
            **({"normal_rendering_contract": "native-gpu-optimized" if native_normal else "legacy"}
               if mode == "normal" else {})}


def workload_cpu_diagnostic(samples, events, workload, identity, memory_validation):
    """CPU attribution only after complete owned-process and memory validation."""
    require(workload.get("validated") is True, "CPU workload did not complete its fixture validation")
    require(memory_validation.get("problems") == [], "CPU comparison lacks valid final memory accounting")
    problems = app.sample_validation_problems(samples)
    require(not problems["shared"] and not problems["cpu_seconds"],
            "CPU comparison has invalid samples: " + "; ".join(problems["shared"] + problems["cpu_seconds"]))
    ready = app.authenticated_cpu_ready(samples, events)
    require(all(ready[key] == identity[key] for key in ("process_id", "birth_time_us")),
            "CPU comparison differs from the owned process identity")
    exits = [event for event in events if event.get("type") == "exited"]
    require(len(exits) == 1 and type(exits[0].get("status")) is int and exits[0]["status"] == 0
            and exits[0].get("final_sample") == samples[-1] and samples[-1].get("phase") == "final",
            "CPU comparison lacks a clean authenticated final sample")
    boundaries = []
    for label in ("before", "after"):
        timestamp = number(workload.get(label, {}).get("runner_collector_sample_monotonic_seconds"),
                           f"CPU workload {label} boundary")
        matches = [sample for sample in samples if sample["monotonic_seconds"] == timestamp]
        require(len(matches) == 1 and matches[0].get("phase") == "control_boundary",
                f"CPU workload {label} boundary has no unique kernel control sample")
        boundaries.append(timestamp)
    require(ready["monotonic_seconds"] <= boundaries[0] < boundaries[1],
            "CPU workload boundaries do not follow authenticated readiness")
    metrics = app.cpu_interval_metrics(samples, *boundaries)
    return {"available": True, "gate_evaluated": False, "source": "owned process cumulative kernel CPU counter",
            "start_monotonic_seconds": boundaries[0], "end_monotonic_seconds": boundaries[1],
            "interval": "04-before-traffic through 06-after-traffic; includes fixture start and completion/drain overhead",
            "ready_boundary": ready, **metrics,
            "average_cpu_percent": 100 * metrics["cpu_seconds"] / metrics["elapsed_seconds"]}


def validate_popover_animation(snapshot, no_animation):
    if "popover_animations_enabled" not in snapshot:
        require(not no_animation, "App did not acknowledge disabled popover animations")
        return {"available": False, "reason": "This frozen app does not expose its native popover animation setting."}
    actual = snapshot["popover_animations_enabled"]
    require(type(actual) is bool, "Native popover animation setting must be a Boolean")
    require(not no_animation or actual is False, "App did not disable native popover animations as requested")
    return {"available": True, "popover_animations_enabled": actual}


class MemoryDiagnostic:
    def __init__(self, output, deadline, graphics_mode, no_popover_animation=False, no_native_inspection=False):
        self.output, self.deadline, self.graphics_mode = output, deadline, graphics_mode
        self.no_popover_animation = no_popover_animation
        self.no_native_inspection = no_native_inspection
        self.require_native_normal = False
        self.runtime_feature_contract = None
        self.arrival_backend_checked = False
        self.arrival_backend = None
        self.publication_interval_checked = False
        self.chart_publication_interval_seconds = None
        self.collector = self.fixture = self.active_probe = None
        self.identity = None
        self.report = {"schema_version": 1, "kind": "memory-attribution-diagnostic", "status": "running",
                       "regression_passed": False, "comparable_to_regression_cases": False,
                       "cpu_gate_evaluated": False, "gpu_gate_evaluated": False,
                       "graphics_mode": graphics_mode, "deadline_seconds": DEADLINE_SECONDS,
                       "no_popover_animation_requested": no_popover_animation,
                       "native_inspection_enabled": not no_native_inspection,
                       "workload_cpu": {"available": False, "gate_evaluated": False,
                                        "reason": "Awaiting validated workload and final accounting" if no_native_inspection
                                        else "Native inspection perturbs runtime; CPU comparison is unavailable"},
                       "workload_cpu_work_counters": {"available": False, "status": "unavailable", "gate_evaluated": False,
                                        "reason": "Awaiting validated unprofiled workload and final accounting"},
                       "errors": [], "checkpoints": [], "probes": [], "inspection_stages": [], "commands": [],
                       "driver_sha256": app.path_hash(Path(__file__)),
                       "caveat": "Native VM/heap inspection and graphics modes perturb runtime. These are attribution diagnostics, not CPU/GPU or regression passes. Pixel/bitmap requests are not measured GPU allocations."}
        if graphics_mode in (HELD_STATIC_CHART_MODE, FROZEN_SCALARS_MODE, HELD_USAGE_MODE):
            self.report.update(cpu_acceptance_eligible=False,
                runtime_cpu_target={"evaluated": False, "within_limit": None, "acceptance_eligible": False,
                    "reason": "Held drawing or scalar presentation is a diagnostic ablation, not production rendering"})

    def save(self):
        write_json(self.output / "in-progress.json", self.report)

    def verify_identity(self):
        verify_owned(self.collector, self.identity)

    def checkpoint(self, label, dashboard, popover, active):
        self.verify_identity()
        snapshot = self.collector.snapshot()
        self.verify_identity()
        timestamp = snapshot.get("runner_collector_sample_monotonic_seconds")
        matches = [sample for sample in self.collector.samples if sample.get("monotonic_seconds") == timestamp]
        require(type(timestamp) in (int, float) and len(matches) == 1, "Snapshot lacks one authenticated collector boundary")
        sample = matches[0]
        require(sample.get("process_id") == self.identity["process_id"]
                and sample.get("birth_time_us") == self.identity["birth_time_us"], "Snapshot resource identity differs")
        entry = {"label": label, "snapshot": snapshot, "resource_sample": sample,
                 "python_monotonic_seconds": time.monotonic(),
                 "expected_state": {"dashboard_visible": dashboard, "popover_visible": popover, "active_requests": active}}
        self.report["checkpoints"].append(entry)
        self.save()  # Preserve actual UI/counter evidence even when the assertion fails.
        require(snapshot.get("dashboard_visible") is dashboard and snapshot.get("popover_visible") is popover,
                f"Wrong native UI state at {label}: dashboard={snapshot.get('dashboard_visible')}, popover={snapshot.get('popover_visible')}")
        require(type(snapshot.get("active_requests")) is int and snapshot["active_requests"] == active,
                f"Wrong active stream count at {label}: {snapshot.get('active_requests')}")
        entry["graphics_validation"] = self.validate_graphics_snapshot(snapshot,
                                                                       expected_closed=not dashboard and not popover)
        entry["popover_animation_validation"] = validate_popover_animation(snapshot, self.no_popover_animation)
        self.save()
        return snapshot

    def command(self, name, **fields):
        self.verify_identity()
        response = self.collector.command(name, **fields)
        self.report["commands"].append({"command": name, **fields, "response": response})
        self.save()
        require(response.get("status") == "ok", f"App command {name} failed: {response}")
        if "snapshot" in response:
            self.validate_control_snapshot(response["snapshot"])
        return response

    def validate_graphics_snapshot(self, snapshot, *, completed_visible_workload=False, expected_closed=False):
        result = validate_graphics(snapshot, self.graphics_mode, completed_visible_workload=completed_visible_workload,
                                   expected_closed=expected_closed, require_native_normal=self.require_native_normal)
        backend = result.get("arrival_backend")
        if self.arrival_backend_checked:
            require(backend == self.arrival_backend, "Arrival backend metadata changed or disappeared during the capture")
        else:
            self.arrival_backend_checked = True
            self.arrival_backend = backend
            if backend is not None:
                self.report["arrival_backend"] = backend
        interval = result.get("chart_publication_interval_seconds")
        if self.publication_interval_checked:
            require(interval == self.chart_publication_interval_seconds,
                    "Chart publication interval metadata changed or disappeared during the capture")
        else:
            self.publication_interval_checked = True
            self.chart_publication_interval_seconds = interval
            if interval is not None:
                self.report["chart_publication_interval_seconds"] = interval
        contract = result.get("runtime_feature_contract")
        if self.runtime_feature_contract is not None:
            require(contract == self.runtime_feature_contract, "Runtime feature metadata changed or disappeared during the capture")
        elif contract is not None:
            self.runtime_feature_contract = contract
            self.report["runtime_feature_contract"] = contract
        if self.graphics_mode == "normal":
            contract = result.get("normal_rendering_contract", "unavailable")
            self.report["normal_rendering_contract"] = contract
            if contract == "native-gpu-optimized":
                self.require_native_normal = True
        return result

    def validate_control_snapshot(self, snapshot):
        self.validate_graphics_snapshot(snapshot)
        validate_popover_animation(snapshot, self.no_popover_animation)

    def create_collector(self, *args, **kwargs):
        """A local extension point for bounded diagnostic collectors."""
        return app.Collector(*args, **kwargs)

    def inspect_tool(self, label, tool):
        self.verify_identity()
        pid = self.identity["process_id"]
        output = self.output / f"{label}-{tool}.txt"
        json_output = self.output / f"{label}-footprint.json"
        commands = {
            "footprint": ["/usr/bin/footprint", "--pid", str(pid), "--format", "bytes", "--swapped", "--wired", "--json", str(json_output)],
            "vmmap": ["/usr/bin/vmmap", "-summary", "-sortBySize", str(pid)],
            "heap": ["/usr/bin/heap", "-s", "--noContent", str(pid)]}
        item = {"label": label, "tool": tool, "command": commands[tool], "output": str(output),
                "process_id": pid, "birth_time_us": self.identity["birth_time_us"],
                "started_monotonic_seconds": time.monotonic(), "valid": False, "errors": []}
        if tool == "footprint":
            item["json_output"] = str(json_output)
        self.report["probes"].append(item)
        limit = time.monotonic() + self.deadline.remaining(12)
        try:
            with output.open("wb") as handle:
                try:
                    self.active_probe = subprocess.Popen(commands[tool], stdout=handle, stderr=subprocess.STDOUT,
                                                         start_new_session=True)
                except OSError as error:
                    item["errors"].append(f"Cannot start {tool}: {error}")
                if self.active_probe is not None:
                    while self.active_probe.poll() is None:
                        if time.monotonic() >= limit:
                            item["errors"].append(f"{tool} exceeded its bounded inspection time")
                            break
                        if output.stat().st_size > MAX_ARTIFACT_BYTES or (json_output.exists() and json_output.stat().st_size > MAX_ARTIFACT_BYTES):
                            item["errors"].append(f"{tool} output exceeded 16 MiB")
                            break
                        self.collector.receive(min(0.1, max(0.001, limit - time.monotonic())))
                        require(not self.collector.exited, "App exited during native memory inspection")
        finally:
            if self.active_probe is not None:
                stop_owned_child(self.active_probe, self.deadline)
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
                item["parsed"] = parse_probe(tool, output, json_output, pid)
                item["valid"] = True
            except (OSError, ValueError, KeyError, TypeError) as error:
                item["errors"].append(str(error))
        self.report["errors"].extend(f"{label}/{tool}: {error}" for error in item["errors"])
        self.save()

    def probe(self, label, dashboard, popover, active, heap=False):
        self.checkpoint(label + "-before-probe", dashboard, popover, active)
        self.report["inspection_stages"].append({"label": label,
            "status": "skipped" if self.no_native_inspection else "requested",
            "reason": "--no-native-inspection preserves kernel checkpoints without native profilers" if self.no_native_inspection else None})
        self.save()
        if not self.no_native_inspection:
            for tool in ("footprint", "vmmap", "heap") if heap else ("footprint", "vmmap"):
                self.inspect_tool(label, tool)
        self.checkpoint(label + "-after-probe", dashboard, popover, active)

    def perform(self, paths, provenance, identity):
        self.report.update(production_provenance=provenance, measurement_identity=identity,
                           binary_identity={key: {"path": str(path), "sha256": app.path_hash(path)} for key, path in paths.items()})
        self.fixture, upstream = app.launch_fixture(self.output, timeout=self.deadline.remaining(5))
        directory = self.output / "owned-app"
        directory.mkdir()
        configuration = {"upstream_url": upstream, "history": "populated", "protocol_version": 1,
                         "logging_enabled": False, "fixture_ending_at_epoch": time.time(), "graphics_mode": self.graphics_mode}
        if self.no_popover_animation:
            configuration["popover_animations_enabled"] = False
        write_json(directory / "configuration.json", configuration)
        self.collector = self.create_collector(paths["collector"], paths["app"], configuration, {}, directory, self.deadline,
                                       {"external_trace": True, "provenance": provenance, "fixture_schema_version": 2})
        ready = self.collector.ready()
        self.report["ready"] = ready
        self.save()
        seed = ready.get("snapshot", {})
        require(ready.get("fixture_schema_version") == 2
                and ready.get("fixture_equivalence_sha256") == provenance.get("fixture_equivalence_sha256", {}).get("populated")
                and isinstance(ready.get("fixture_equivalence_sha256"), str), "Populated fixture differs from frozen provenance")
        require(seed.get("history_verified") is True and seed.get("history") == "populated"
                and (seed.get("seed_persistent_requests"), seed.get("seed_raw_requests"), seed.get("seed_tool_events")) == (19000, 256, 38512),
                "Populated history dimensions were not verified")
        self.report["ready_graphics_validation"] = self.validate_graphics_snapshot(seed)
        self.report["ready_popover_animation_validation"] = validate_popover_animation(seed, self.no_popover_animation)
        self.identity = authenticate_ready(self.collector, self.validate_control_snapshot)
        self.report["owned_identity"] = self.identity
        logging = self.command("set_logging", enabled=False)
        require(logging.get("logging_enabled") is False and logging.get("drained") is True, "Logging did not disable and drain")
        self.collector.wait_until(time.monotonic() + 1)
        self.probe("01-populated-never-opened", False, False, 0, heap=True)
        self.command("show_dashboard")
        self.collector.wait_until(time.monotonic() + 2)
        self.probe("02-dashboard-only", True, False, 0)
        self.command("show_popover")
        self.collector.wait_until(time.monotonic() + 2)
        self.probe("03-both-visible-idle", True, True, 0, heap=True)

        stage = {"activity": "high-rate", "seconds": 25}
        before = self.checkpoint("04-before-traffic", True, True, 0)
        began = time.monotonic()
        acknowledgment = app.fixture_request(upstream, "/control/start", self.deadline, {
            "proxy_url": ready["proxy_url"], "duration_seconds": 25, "rate_hz": 200, "concurrency": 2, "cycle": 15000})
        app.validate_fixture_start(stage, acknowledgment)
        self.report["workload"] = {"specification": stage, "fixture_start": acknowledgment, "before": before,
                                   "started_monotonic_seconds": began, "validated": False}
        self.save()
        self.collector.wait_until(began + 8)
        self.probe("05-both-visible-streaming", True, True, 2)
        self.collector.wait_until(began + 25)
        status = app.completed_status(self.collector, upstream, self.deadline)
        after = self.checkpoint("06-after-traffic", True, True, 0)
        self.report["workload"].update(fixture_status=status, after=after)
        self.save()
        work = app.validate_workload(stage, status, before, after, acknowledgment)
        graphics = self.validate_graphics_snapshot(after, completed_visible_workload=True)
        self.report["workload"].update(validated_work=work, graphics_validation=graphics, validated=True)
        self.command("close_popover")
        self.command("close_dashboard")
        self.collector.wait_until(time.monotonic() + 2)
        self.probe("07-both-closed", False, False, 0, heap=True)
        self.collector.wait_until(time.monotonic() + 5)
        self.checkpoint("08-closed-after-five-more-seconds", False, False, 0)
        self.collector.finish()

    def cleanup(self):
        # Each owned child gets an independent cleanup attempt. A failed native
        # tool or collector drain must not bypass fixture/process-group cleanup.
        for label, action in (
                ("native inspector", lambda: stop_owned_child(self.active_probe, self.deadline) if self.active_probe else None),
                ("fixture", lambda: stop_owned_child(self.fixture, self.deadline) if self.fixture else None),
                ("collector", lambda: self.collector.close() if self.collector else None)):
            try:
                if label == "collector" and self.collector is not None:
                    with self.deadline.interrupt_at(min(self.deadline.end - 0.75, self.deadline.clock() + 5.5)):
                        action()
                else:
                    # Always attempt a nonblocking kill, even after another
                    # cleanup action has consumed its time allocation.
                    action()
            except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
                self.report["errors"].append(f"{label} cleanup failed: {error}")
                if label == "collector" and self.collector is not None:
                    self.emergency_collector_cleanup()
        if self.collector is not None:
            self.report.update(samples=self.collector.samples, events=self.collector.events, storage=self.collector.storage)
            self.report["errors"].extend(self.collector.cleanup_errors)
            try:
                exits = [event for event in self.collector.events if event.get("type") == "exited"]
                require(len(exits) == 1 and exits[0].get("status") == 0 and self.collector.samples
                        and exits[0].get("final_sample") == self.collector.samples[-1], "Missing clean authenticated final exit")
                final = exits[0]
                require(self.identity is not None and final["final_sample"].get("process_id") == self.identity["process_id"]
                        and final["final_sample"].get("birth_time_us") == self.identity["birth_time_us"], "Final exit identity differs")
                validate_sample_identities(self.collector.samples, self.identity)
                for envelope in self.collector.events:
                    event = envelope.get("event", {}) if envelope.get("type") == "app_event" else {}
                    if "snapshot" in event:
                        self.validate_control_snapshot(event["snapshot"])
                stopped = [event.get("event", {}) for event in self.collector.events
                           if event.get("type") == "app_event" and event.get("event", {}).get("type") == "stopped"]
                require(len(stopped) == 1 and stopped[0].get("status") == "ok", "App shutdown/drain was not acknowledged")
                with self.deadline.interrupt_at(self.deadline.end - 0.25):
                    self.report["memory_validation"] = app.memory_evidence(self.collector.samples, final)
                self.report["errors"].extend(self.report["memory_validation"]["problems"])
                if self.no_native_inspection:
                    self.report["workload_cpu"] = workload_cpu_diagnostic(
                        self.collector.samples, self.collector.events, self.report.get("workload", {}),
                        self.identity, self.report["memory_validation"])
                    if self.graphics_mode in (HELD_STATIC_CHART_MODE, FROZEN_SCALARS_MODE, HELD_USAGE_MODE):
                        self.report["workload_cpu"].update(acceptance_eligible=False, within_limit=None)
                    cpu = self.report["workload_cpu"]
                    if cpu.get("available"):
                        self.report["workload_cpu_work_counters"] = app.cpu_work_counter_diagnostic(
                            self.collector.samples, self.collector.events,
                            cpu["start_monotonic_seconds"], cpu["end_monotonic_seconds"])
                    else:
                        self.report["workload_cpu_work_counters"] = {"available": False, "status": "unavailable",
                            "gate_evaluated": False, "reason": cpu.get("reason", "Workload CPU boundaries are unavailable")}
            except (ValueError, KeyError, TypeError, TimeoutError) as error:
                self.report["errors"].append(str(error))
                if self.no_native_inspection:
                    self.report["workload_cpu"] = {"available": False, "gate_evaluated": False, "reason": str(error)}

    def emergency_collector_cleanup(self):
        """Do not orphan the app if a collector protocol/cleanup call fails."""
        try:
            if not self.collector.exited:
                identity = {"process_id": self.collector.app_pid, "birth_time_us": self.collector.app_birth_time_us}
                verify_owned(self.collector, identity)
                os.killpg(identity["process_id"], signal.SIGKILL)
        except (OSError, ValueError) as error:
            self.report["errors"].append(f"Emergency app identity/cleanup could not be confirmed: {error}")
        try:
            stop_owned_child(self.collector.process, self.deadline)
        except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
            self.report["errors"].append(f"Emergency collector cleanup failed: {error}")


def summary_markdown(report):
    lines = ["# Memory attribution diagnostic", "", report["caveat"], "",
             f"Completion status: see [memory-report.json](memory-report.json). Graphics mode: `{report['graphics_mode']}`. No regression pass is implied.", "",
             "| Checkpoint | Collector current / lifetime peak (MB) | Footprint (MB) | Graphics unmapped (MB) | Malloc dirty (MB) | Heap allocated (MB) |",
             "|---|---:|---:|---:|---:|---:|"]
    def megabytes(value):
        return f"{value / 1_000_000:.3f}" if type(value) in (int, float) else "unavailable"
    for checkpoint in report["checkpoints"]:
        label = checkpoint["label"]
        if not label.endswith("-after-probe"):
            continue
        label = label.removesuffix("-after-probe")
        probes = {item["tool"]: item for item in report["probes"] if item["label"] == label}
        footprint = probes.get("footprint", {}).get("parsed", {})
        heap = probes.get("heap", {}).get("parsed", {})
        groups = footprint.get("groups", {})
        sample = checkpoint["resource_sample"]
        native = lambda field: megabytes(footprint.get(field))
        # A successfully reconciled complete ledger measures absent categories
        # as zero. A missing/invalid entire tool report remains unavailable.
        group_bytes = lambda name: megabytes(groups.get(name, {}).get("dirty", 0)) if footprint else "unavailable"
        lines.append(f"| {label} | {megabytes(sample.get('physical_footprint_bytes'))} / {megabytes(sample.get('lifetime_peak_footprint_bytes'))} | "
                     f"{native('physical_footprint_bytes')} | {group_bytes('graphics_unmapped')} | "
                     f"{group_bytes('malloc')} | {megabytes(heap.get('allocated_bytes'))} |")
    lines.extend(["", "Decimal MB. Tool snapshots occur at different times. Footprint dirty includes swapped; heap/VM values must not be added to footprint.", "",
                  "Raw native reports, collector samples, graphics role counters, exact commands, identity checks, and fixture validation are in memory-report.json and adjacent artifacts."])
    cpu = report.get("workload_cpu", {})
    if cpu.get("available"):
        lines.extend(["", "| Workload CPU diagnostic | Value |", "|---|---:|",
                      f"| Average CPU | {cpu['average_cpu_percent']:.3f}% |",
                      f"| Maximum rolling one-second CPU | {cpu['rolling_1s_percent']:.3f}% |",
                      f"| Interval | {cpu['elapsed_seconds']:.3f} seconds |", "",
                      cpu["interval"] + ". No CPU gate is evaluated."])
    elif cpu:
        lines.extend(["", "Workload CPU unavailable: " + cpu.get("reason", "Missing evidence") + "."])
    work = report.get("workload_cpu_work_counters", {})
    if "deltas" in work:
        hardware_status = "available" if work.get("hardware_counter_status") == "available" else "unavailable / unverified"
        qos_status = "available" if work.get("qos_counter_status") == "available" else "unavailable / unverified"
        ratio = work.get("instructions_per_cycle")
        lines.extend(["", "| Optional raw CPU work diagnostic | Value | Status |", "|---|---:|---|",
                      f"| Instructions | {work['deltas']['instructions']} | {hardware_status} |",
                      f"| Cycles | {work['deltas']['cycles']} | {hardware_status} |",
                      f"| Instructions / cycle | {ratio if ratio is not None else 'unavailable'} | {hardware_status if ratio is not None else 'no positive counter ratio'} |"])
        for bucket, value in work["deltas"]["qos_time_raw"].items():
            lines.append(f"| QoS {bucket} (raw) | {value} | {qos_status} |")
        lines.extend(["", "QoS values use unspecified kernel units. Raw zeros marked unverified do not establish zero work. Hardware and QoS availability are independent; these counters do not identify frequency, core type, or a cause, and do not change CPU acceptance."])
        if work.get("reason"):
            lines.extend(["", work["reason"] + "."])
    elif work:
        lines.extend(["", "Optional CPU work diagnostics: " + work.get("status", "unavailable") + ". "
                      + work.get("reason", "; ".join(work.get("errors", [])))])
    if report["errors"]:
        lines.extend(["", "Unavailable or invalid evidence:", ""])
        lines.extend("- " + error.replace("\n", " ") for error in report["errors"])
    return "\n".join(lines) + "\n"


def finalize_report(output, report, deadline):
    """Commit completion only after every artifact is written successfully."""
    pending = dict(report, status="diagnostic_incomplete", finalization_pending=True,
                   errors=[*report["errors"], "Memory report finalization has not completed"])
    try:
        with deadline.interrupt_at(deadline.end):
            # If either later write fails, the authoritative report already
            # says incomplete. The summary never asserts completion itself.
            write_json(output / "memory-report.json", pending)
            (output / "SUMMARY.md").write_text(summary_markdown(report), encoding="utf-8")
            write_json(output / "memory-report.json", report)
    except (OSError, ValueError, TimeoutError) as error:
        report["status"] = "diagnostic_incomplete"
        report["errors"].append(f"Final memory report could not be completed: {error}")
        print(report["errors"][-1], file=sys.stderr)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--app-binary", required=True, type=Path)
    result.add_argument("--test-bundle", required=True, type=Path)
    result.add_argument("--collector-binary", required=True, type=Path)
    result.add_argument("--provenance", required=True, type=Path)
    result.add_argument("--graphics-mode", choices=GRAPHICS_MODES, default="normal")
    result.add_argument("--no-popover-animation", action="store_true",
                        help="Diagnostic only: disable native popover animation and verify the app acknowledgment")
    result.add_argument("--no-native-inspection", action="store_true",
                        help="Skip footprint/vmmap/heap; preserve kernel checkpoints and measure workload CPU after final validation")
    result.add_argument("--output-dir", type=Path, help="New, nonexisting artifact directory; default .performance-results/memory-UTC-unique")
    return result


def run(argv=None):
    args = parser().parse_args(argv)
    output = (args.output_dir or app.ROOT / ".performance-results" /
              ("memory-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ-") + secrets.token_hex(3))).resolve()
    try:
        require(not output.exists(), "Never overwrite memory diagnostic artifacts")
        require(app.ROOT not in output.parents or app.ROOT / ".performance-results" in output.parents,
                "In-repository memory artifacts must be inside ignored .performance-results")
        require(sys.platform == "darwin", "Native memory attribution requires macOS")
        output.mkdir(parents=True)
    except (OSError, ValueError) as error:
        print(f"Memory diagnostic could not start: {error}", file=sys.stderr)
        return 1
    started = time.monotonic()
    deadline = MemoryDeadline()
    diagnostic = MemoryDiagnostic(output, deadline, args.graphics_mode, args.no_popover_animation, args.no_native_inspection)
    try:
        with deadline.interrupt_at(deadline.end - deadline.cleanup_reserve):
            paths, provenance, identity = validate_products(args)
            diagnostic.perform(paths, provenance, identity)
    except (OSError, ValueError, KeyError, TypeError, TimeoutError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        diagnostic.report["errors"].append(str(error) or "Interrupted")
    finally:
        diagnostic.cleanup()
        report = diagnostic.report
        report["elapsed_seconds"] = time.monotonic() - started
        if report["elapsed_seconds"] > DEADLINE_SECONDS:
            report["errors"].append("Memory diagnostic exceeded its hard 90-second deadline")
        report["status"] = "diagnostic_captured" if not report["errors"] and report.get("workload", {}).get("validated") else "diagnostic_incomplete"
        finalize_report(output, report, deadline)
        print(f"Memory diagnostic: {report['status']}. Artifacts: {output}", flush=True)
    return 0 if report["status"] == "diagnostic_captured" else 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    raise SystemExit(run())
