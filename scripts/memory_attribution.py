"""Bounded, owned-process memory attribution; never a performance-gate pass.

Run via run_performance_checks.py memory with explicit frozen Release products.
Native inspection perturbs the process. CPU/GPU gates are deliberately not run.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal
import os
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
ORDERED_PUBLICATION_MODES = (ORDERED_PUBLICATION_MODE, DIRECT_TOOL_PLOT_MODE, UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE)
CANVAS_CLOCK_MODES = ("runtime-canvas-clock", "runtime-stream-canvas-clock") + ORDERED_PUBLICATION_MODES
NEXT_RUNTIME_MODES = ("runtime-shared-preparation", "runtime-stable-decoration-hosts", "runtime-stream-writes", "runtime-next-optimized") + CANVAS_CLOCK_MODES
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
RETAINED_TWINKLE_MODES = ("native-gpu-retained-twinkles", "native-gpu-optimized") + RUNTIME_MODES
RETAINED_TWINKLE_FIELDS = ("hosts_created", "hosts_destroyed", "live_hosts", "peak_hosts",
                          "instances_created", "instances_destroyed", "live_instances", "peak_instances", "animation_starts")
GRADIENT_ABLATION_MODES = ("no-gradients", "no-gradients-or-blur")
MAX_ARTIFACT_BYTES = 16 * 1024 * 1024
DEADLINE_SECONDS = 90
CATEGORY_FIELDS = ("dirty", "swapped", "clean", "reclaimable", "wired", "regions")
SIZE_PATTERN = r"(?:\d+(?:\.\d+)?)(?:[KMGT])?"
NATIVE_ERROR = re.compile(r"(?im)^\s*(?:error\b|warning\b|(?:footprint|vmmap|heap):\s*(?:error|failed|cannot|unable)|"
                          r"(?:failed|unable|cannot) (?:to |inspect|read|access)|permission denied|operation not permitted)")


def unsigned(value, name):
    return number(value, name, integer=True)


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


def runtime_feature_contract(value, mode):
    if mode not in RUNTIME_MODES and not any(field in value for field in RUNTIME_FLAGS + NEXT_RUNTIME_FLAGS + ("canvas_frame_clock", "ordered_chart_publication", "direct_tool_plot", "ungrouped_native_canvas", "arrival_effects_enabled")):
        return None
    extras = {}
    promoted_normal = mode == "normal" and value.get("unpromised_stream_body_writes") is True
    if mode in NEXT_RUNTIME_MODES or any(field in value for field in NEXT_RUNTIME_FLAGS):
        expected = {"shared_chart_preparation": mode in ("runtime-shared-preparation", "runtime-next-optimized"),
                    "stable_decoration_hosts": mode in ("runtime-stable-decoration-hosts", "runtime-next-optimized"),
                    "unpromised_stream_body_writes": promoted_normal or mode in ("runtime-stream-writes", "runtime-next-optimized", "runtime-stream-canvas-clock") + ORDERED_PUBLICATION_MODES}
        for field, enabled in expected.items():
            require(type(value.get(field)) is bool and value[field] is enabled,
                    f"Graphics {field} does not match the requested runtime control")
        extras = {field: value[field] for field in NEXT_RUNTIME_FLAGS}
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
    if mode in (DIRECT_TOOL_PLOT_MODE, UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE) or "direct_tool_plot" in value:
        require(type(value.get("direct_tool_plot")) is bool and value["direct_tool_plot"] is (mode == DIRECT_TOOL_PLOT_MODE),
                "Graphics direct_tool_plot does not match the requested runtime control")
        extras["direct_tool_plot"] = value["direct_tool_plot"]
    if mode in (UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE) or "ungrouped_native_canvas" in value:
        require(type(value.get("ungrouped_native_canvas")) is bool and value["ungrouped_native_canvas"] is (mode == UNGROUPED_CANVAS_MODE),
                "Graphics ungrouped_native_canvas does not match the requested runtime control")
        extras["ungrouped_native_canvas"] = value["ungrouped_native_canvas"]
    if mode == NO_ARRIVAL_MODE or "arrival_effects_enabled" in value:
        expected = mode not in (NO_ARRIVAL_MODE, "runtime-no-lifecycle")
        require(type(value.get("arrival_effects_enabled")) is bool and value["arrival_effects_enabled"] is expected,
                "Graphics arrival_effects_enabled does not match the requested runtime control")
        extras["arrival_effects_enabled"] = value["arrival_effects_enabled"]
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
    # Keep the requested mode acknowledgment while applying the complete
    # combined contract to newer production binaries that identify this backend.
    native_normal = mode == "normal" and "native_gpu_backend" in value
    contract = "native-gpu-optimized" if native_normal or mode in RUNTIME_MODES else mode
    runtime_features = runtime_feature_contract(value, mode)
    if mode == NO_ARRIVAL_MODE or "arrival_effects_enabled" in value or "suppressed_arrival_effects" in snapshot:
        require("arrival_effects_enabled" in value or contract not in NATIVE_GPU_MODES,
                "Arrival suppression counter lacks feature metadata")
        suppressed = unsigned(snapshot.get("suppressed_arrival_effects"), "suppressed_arrival_effects")
        if mode == NO_ARRIVAL_MODE:
            if completed_visible_workload:
                require(suppressed > 0, "No-arrival mode did not suppress arrival effects")
        else:
            require(suppressed == 0, "Baseline mode unexpectedly suppressed arrival effects")
    if (mode in (UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE) or "ungrouped_native_canvas" in value
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
    if (mode in (DIRECT_TOOL_PLOT_MODE, UNGROUPED_CANVAS_MODE, NO_ARRIVAL_MODE) or "direct_tool_plot" in value
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
            # which can precede all completion animation. The no-arrival mode
            # proves positive ticks in the authenticated runtime tail instead.
            if completed_visible_workload and mode != NO_ARRIVAL_MODE:
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
        expected_backend = "swiftui-canvas" if mode == UNGROUPED_CANVAS_MODE else "swiftui-canvas-drawing-group"
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
        if completed_visible_workload:
            require(native_gpu_draws > 0 and roles["static_chart"]["draws"] > 0,
                    "Completed visible workload did not execute native GPU static-chart drawing")
    return {"available": True, "counters": value,
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
