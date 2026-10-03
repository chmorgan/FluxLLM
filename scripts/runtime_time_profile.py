"""Bounded Time Profiler exports and offline, phase-specific CPU attribution.

All percentages here are statistical estimates from a profiled process. They
never establish an unprofiled CPU, GPU, memory, or filesystem regression pass.
The caller authenticates the recording's owned process and recording issues.
"""
from bisect import bisect_right
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import xml.etree.ElementTree as ET

import app_performance as app

MAX_TOC_BYTES = 2 * 1024 * 1024
MAX_PROFILE_BYTES = 64 * 1024 * 1024
MAX_LOG_BYTES = 2 * 1024 * 1024
MAX_XML_ELEMENTS = 1_000_000
MAX_ROWS = 250_000
MAX_STACK_DEPTH = 512
MAX_PHASES = 8
MAX_KERNEL_SAMPLES = 20_000
MAX_CALL_TREE_NODES = 20_000
CALL_TREE_RANK_LIMIT = 40
SAMPLE_KERNEL_RELATIVE_LIMIT = .20
SAMPLE_KERNEL_ABSOLUTE_LIMIT = .5
SAMPLE_KERNEL_POLICY = (
    "Quantitative attribution is pending if sampled mean CPU differs from the "
    "same-window kernel mean by more than 20% of kernel CPU AND 0.5 CPU "
    "percentage points. This is a diagnostic quality check, not a CPU budget."
)
SCHEMA_COLUMNS = {
    "time": "sample-time", "thread": "thread", "process": "process",
    "core": "core", "thread-state": "thread-state", "weight": "weight",
    "stack": "tagged-backtrace",
}
QUERIES = (
    ("SwiftUI graph transactions", "GraphHost.flushTransactions"),
    ("Native hosting layout", "NSHostingView.layout"),
    ("Core Animation transactions", "CA::Transaction::commit"),
    ("Metrics sampling/publication", "MetricsStore.sample("),
    ("NIO event loop", "MultiThreadedEventLoopGroup.runTheLoop"),
    ("Dashboard prepared charts", "DashboardView.preparedCharts"),
    ("Prepared chart allocation/initialization", "PreparedDashboardCharts.__allocating_init"),
    ("Tool history normalization", "ToolActivityHistory.normalizedEvents"),
    ("Chart geometry preparation", "LuminousChartGeometryCache.Frame.init"),
    ("Display history preparation", "ChartDisplayHistory.init"),
    ("Chart presentation publication", "MetricsStore.publishChartPresentationIfDue"),
    ("Tool history query", "UsageHistory.toolEvents("),
    ("Request lane history query", "UsageHistory.requestLanes("),
    ("Tool order comparator", "closure #1 in UsageHistory.prepareToolOrder"),
    ("Completed order comparator", "in UsageHistory.prepareCompletedOrder"),
    ("Generic collection sorting", "MutableCollection<>.sort(by:)"),
    ("Retained twinkles", "RetainedRequestRailTwinkles"),
    ("Dashboard scalar body", "DashboardScalarContent.body"),
    ("ImageRenderer rendering", "ImageRenderer._render"),
    ("CA image preparation", "CA::Render::prepare_image"),
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, label):
    require(type(value) in (int, float) and math.isfinite(value), f"Invalid {label}")
    return value


def integer(value, label, minimum=0):
    require(type(value) is int and value >= minimum, f"Invalid {label}")
    return value


def xml_integer(value, label, minimum=0):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]+", value) is not None,
            f"Invalid XML {label}")
    return integer(int(value), label, minimum)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def read_xml(path, maximum):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), "XML artifact must be a regular file")
    require(0 < path.stat().st_size <= maximum, "XML artifact exceeds its size bound or is empty")
    with path.open("rb") as source:
        payload = source.read(maximum + 1)
    require(len(payload) <= maximum, "XML artifact grew beyond its size bound")
    try:
        decoded = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("XML export must use UTF-8") from error
    require("<!DOCTYPE" not in decoded.upper() and "<!ENTITY" not in decoded.upper(),
            "XML entity/doctype declarations are not accepted")
    try:
        root = ET.fromstring(payload)
    except ET.ParseError as error:
        raise ValueError(f"Malformed Time Profiler XML: {error}") from error
    require(sum(1 for _ in root.iter()) <= MAX_XML_ELEMENTS, "XML element count exceeds its bound")
    return root


def epoch_ns(value):
    require(isinstance(value, str), "Missing trace start/end date")
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError as error:
        raise ValueError("Invalid trace start/end date") from error
    require(parsed.tzinfo is not None, "Trace dates must include their time zone")
    delta = parsed.astimezone(timezone.utc) - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return (delta.days * 86400 + delta.seconds) * 1_000_000_000 + delta.microseconds * 1000


def validate_toc(path, owned_pid):
    integer(owned_pid, "owned PID", 1)
    root = read_xml(path, MAX_TOC_BYTES)
    require(root.tag == "trace-toc", "Unexpected Time Profiler TOC root")
    runs = root.findall("run")
    require(len(runs) == 1 and runs[0].get("number") == "1", "Expected exactly run 1")
    run = runs[0]
    targets = run.findall("info/target/process")
    require(len(targets) == 1 and xml_integer(targets[0].get("pid"), "target PID", 1) == owned_pid,
            "TOC target does not match the owned PID")
    require(run.findtext("info/summary/template-name") == "Time Profiler", "Wrong trace template")
    tables = run.findall("data/table[@schema='time-profile']")
    require(len(tables) == 1, "Expected exactly one time-profile schema in TOC")
    try:
        duration = float(run.findtext("info/summary/duration", ""))
    except ValueError as error:
        raise ValueError("Invalid trace duration") from error
    require(math.isfinite(duration) and 0 < duration <= 300, "Trace duration exceeds the bounded run")
    start_date, end_date = (run.findtext(f"info/summary/{kind}-date") for kind in ("start", "end"))
    start_ns, end_ns = epoch_ns(start_date), epoch_ns(end_date)
    require(all(re.search(r"T[0-9:]+\.[0-9]{3,6}(?:Z|[+-][0-9:]+)$", value) for value in (start_date, end_date)),
            "TOC dates require millisecond-or-better precision")
    require(end_ns > start_ns and abs((end_ns - start_ns) / 1e9 - duration) <= .002,
            "TOC duration disagrees with its dates")
    return {"process_id": owned_pid, "duration_seconds": duration, "start_date": start_date,
            "end_date": end_date, "start_epoch_ns": start_ns,
            "template": "Time Profiler", "end_reason": run.findtext("info/summary/end-reason")}


def parse_running_samples(path, owned_pid):
    """Resolve typed XML references and retain Running samples of the owned PID."""
    root = read_xml(path, MAX_PROFILE_BYTES)
    require(root.tag == "trace-query-result", "Unexpected table export root")
    nodes = root.findall("node")
    require(len(nodes) == 1, "Expected exactly one exported table")
    node = nodes[0]
    schemas = node.findall("schema")
    require(len(schemas) == 1 and schemas[0].get("name") == "time-profile", "Wrong exported schema")
    columns = schemas[0].findall("col")
    actual = [(col.findtext("mnemonic"), col.findtext("engineering-type")) for col in columns]
    require(actual == list(SCHEMA_COLUMNS.items()),
            "Unsupported time-profile column schema")
    ids = {}
    for element in node.iter():
        if "id" in element.attrib:
            key = element.get("id")
            require(key and key not in ids, "Duplicate or empty XML reference ID")
            ids[key] = element

    def resolve(element):
        require(element is not None, "Missing required table value")
        tag, seen = element.tag, set()
        while "ref" in element.attrib:
            key = element.get("ref")
            require(key not in seen and key in ids, "Cyclic or missing XML reference")
            require(set(element.attrib) == {"ref"} and len(element) == 0,
                    "Reference node also contains a value")
            seen.add(key)
            element = ids[key]
            require(element.tag == tag, "XML reference changes the value type")
        return element

    # Reject dangling references even when they are in a non-Running row.
    for element in node.iter():
        if "ref" in element.attrib:
            resolve(element)
    rows = node.findall("row")
    require(0 < len(rows) <= MAX_ROWS, "Export row count is empty or exceeds its bound")
    selected, states, stack_schemas, weight_formats = [], Counter(), Counter(), {}
    sample_identities = set()
    for row in rows:
        for tag in ("sample-time", "thread", "process", "thread-state", "weight"):
            require(len(row.findall(tag)) == 1, f"Missing or duplicate row {tag}")
        require(len(row.findall("tagged-backtrace")) <= 1, "Duplicate row backtrace")
        process = resolve(row.find("process"))
        pid = xml_integer(resolve(process.find("pid")).text, "row PID", 1)
        require(pid == owned_pid, "Export includes a process other than the owned PID")
        state = resolve(row.find("thread-state")).text
        require(isinstance(state, str) and state, "Missing thread state")
        states[state] += 1
        if state != "Running":
            continue
        require(all(child.tag in (*SCHEMA_COLUMNS.values(), "sentinel") for child in row),
                "Unrecognized Running row schema")
        sentinels = row.findall("sentinel")
        require(len(sentinels) <= 1 and not (sentinels and row.find("tagged-backtrace") is not None)
                and all(not sentinel.attrib and len(sentinel) == 0 for sentinel in sentinels),
                "Malformed missing-backtrace sentinel")
        weight_element = resolve(row.find("weight"))
        weight = xml_integer(weight_element.text, "sample weight", 1)
        formatted = weight_element.get("fmt", "")
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)\s*(ns|µs|μs|us|ms|s)", formatted)
        require(match is not None, "Unrecognized formatted sample weight")
        factor = {"ns": 1, "µs": 1000, "μs": 1000, "us": 1000, "ms": 1_000_000, "s": 1_000_000_000}[match[2]]
        digits = len(match[1].partition(".")[2])
        tolerance = Decimal(factor) * Decimal(10) ** -digits / 2
        require(abs(Decimal(weight) - Decimal(match[1]) * factor) <= tolerance,
                "Sample weight encoding is not nanoseconds")
        weight_formats[str(weight)] = formatted
        timestamp = xml_integer(resolve(row.find("sample-time")).text, "sample time")
        thread = resolve(row.find("thread"))
        tid = xml_integer(resolve(thread.find("tid")).text, "thread ID", 1)
        identity = (timestamp, tid)
        require(identity not in sample_identities, "Duplicate Running sample for one thread/time")
        sample_identities.add(identity)
        thread_process = resolve(thread.find("process"))
        require(xml_integer(resolve(thread_process.find("pid")).text, "thread PID", 1) == owned_pid,
                "Thread process disagrees with row process")
        tagged = row.find("tagged-backtrace")
        if tagged is None:
            # Instruments can emit a sentinel instead of a backtrace. Keep its
            # CPU weight in the denominator, without inventing attribution.
            frames = []
            stack_schemas["missing"] += 1
        else:
            stack = resolve(tagged)
            nested = stack.findall("backtrace")
            if nested:
                require(len(nested) == 1 and len(stack) == 1,
                        "Unrecognized or mixed tagged-backtrace schema")
                stack = resolve(nested[0])
                stack_schemas["nested-backtrace"] += 1
            else:
                stack_schemas["direct-frames"] += 1
            require(len(stack) > 0 and all(child.tag == "frame" for child in stack),
                    "Unrecognized or empty backtrace frame schema")
            frames = [resolve(frame) for frame in stack]
        require(len(frames) <= MAX_STACK_DEPTH, "Backtrace exceeds bounded stack depth")
        for frame in frames:
            require(bool(frame.get("name")) or re.fullmatch(r"0x[0-9a-fA-F]+", frame.get("addr", "")) is not None,
                    "Incomplete backtrace frame lacks both symbol and address")
            require(all(child.tag in ("binary", "source") for child in frame)
                    and len(frame.findall("binary")) <= 1 and len(frame.findall("source")) <= 1,
                    "Unrecognized backtrace frame structure")
        names = [frame.get("name") or "<unknown>" for frame in frames]
        require(all(len(name) <= 16_384 for name in names), "Symbol name exceeds its size bound")
        selected.append({"time_ns": timestamp, "weight_ns": weight, "thread_id": tid,
                         "thread": thread.get("fmt"), "frames": names})
    require(selected, "No Running samples for the owned PID")
    return selected, {"row_count": len(rows), "running_sample_count": len(selected),
                      "target_states": dict(states), "stack_schemas": dict(stack_schemas),
                      "weight_formats_nanoseconds": weight_formats}


def clock_mapping(toc, anchor):
    before = integer(anchor.get("monotonic_before_ns"), "anchor before", 1)
    after = integer(anchor.get("monotonic_after_ns"), "anchor after", 1)
    wall = integer(anchor.get("wall_time_ns"), "anchor wall time", 1)
    require(0 <= after - before <= 2_000_000, "Wall/monotonic anchor is too uncertain")
    bridges = [anchor.get("mach_clock_start"), anchor.get("mach_clock_end")]
    require(all(isinstance(bridge, dict) for bridge in bridges), "Both paired Mach bridges are required")
    for bridge in bridges:
        ticks = integer(bridge.get("mach_ticks"), "Mach ticks", 1)
        numer = integer(bridge.get("numer"), "Mach numerator", 1)
        denom = integer(bridge.get("denom"), "Mach denominator", 1)
        mono = number(bridge.get("monotonic_seconds"), "Mach bridge monotonic time")
        offset = number(bridge.get("absolute_minus_monotonic_seconds"), "Mach bridge offset")
        uncertainty = number(bridge.get("uncertainty_seconds"), "Mach bridge uncertainty")
        require(0 <= uncertainty <= .001, "Mach bridge is too uncertain")
        require(abs(ticks * numer / denom / 1e9 - mono - offset) <= 1e-8,
                "Mach bridge ticks disagree with its offset")
    first, last = bridges
    require(first["numer"] == last["numer"] and first["denom"] == last["denom"], "Mach timebase changed")
    require(first["monotonic_seconds"] < last["monotonic_seconds"], "Mach bridges are out of order")
    drift = abs(first["absolute_minus_monotonic_seconds"] - last["absolute_minus_monotonic_seconds"])
    require(drift <= .001, "Mach/Python clock bridge drift exceeds one millisecond")
    origin_ns = (Decimal(before + after) / 2 + toc["start_epoch_ns"] - wall)
    return {"trace_origin_python_monotonic_seconds": float(origin_ns / Decimal(1_000_000_000)),
            "python_to_mach_offset_seconds": (first["absolute_minus_monotonic_seconds"] + last["absolute_minus_monotonic_seconds"]) / 2,
            "bridge_drift_seconds": drift,
            "mapping_uncertainty_seconds": .001 + (after - before) / 2e9 + drift / 2 + max(b["uncertainty_seconds"] for b in bridges),
            "anchor": anchor, "trace_duration_seconds": toc["duration_seconds"],
            "collector_clock_warning": "Collector monotonic epoch is not Python's; kernel windows use paired Mach time."}


def validate_kernel_samples(samples, owned_pid, mapping):
    require(isinstance(samples, list) and 2 <= len(samples) <= MAX_KERNEL_SAMPLES,
            "Missing or excessive kernel samples")
    identities = set()
    converted = []
    for sample in samples:
        require(sample.get("process_id") == owned_pid, "Kernel sample has wrong PID")
        identities.add(integer(sample.get("birth_time_us"), "kernel process birth", 1))
        ticks = integer(sample.get("mach_absolute_ticks"), "sample Mach ticks", 1)
        numer = integer(sample.get("mach_timebase_numer"), "sample Mach numerator", 1)
        denom = integer(sample.get("mach_timebase_denom"), "sample Mach denominator", 1)
        bridge = mapping["anchor"]["mach_clock_start"]
        require((numer, denom) == (bridge["numer"], bridge["denom"]), "Kernel sample timebase differs from bridge")
        absolute = number(sample.get("mach_absolute_seconds"), "sample Mach seconds")
        require(abs(ticks * numer / denom / 1e9 - absolute) <= 1e-8, "Kernel sample Mach fields disagree")
        uncertainty = number(sample.get("clock_read_uncertainty_seconds"), "kernel clock uncertainty")
        require(0 <= uncertainty <= .001, "Kernel clock sample is too uncertain")
        number(sample.get("monotonic_seconds"), "collector time")
        require(number(sample.get("cpu_seconds"), "kernel CPU") >= 0, "Negative kernel CPU")
        converted.append({**sample, "monotonic_seconds": absolute})
    require(len(identities) == 1, "Kernel process identity changed")
    for raw_left, raw_right, left, right in zip(samples, samples[1:], converted, converted[1:]):
        require(0 < right["monotonic_seconds"] - left["monotonic_seconds"] <= .75,
                "Kernel samples are out of order or contain a gap")
        require(raw_left["monotonic_seconds"] < raw_right["monotonic_seconds"], "Collector samples are out of order")
        require(left["cpu_seconds"] <= right["cpu_seconds"], "Kernel CPU counter regressed")
    return converted, next(iter(identities))


def symbol_quality(rows):
    unknown = lambda name: bool(re.fullmatch(r"0x[0-9a-fA-F]+|<unknown>|<deduplicated_symbol>", name))
    return {
        "missing_stack_weight_ns": sum(r["weight_ns"] for r in rows if not r["frames"]),
        "unknown_leaf_weight_ns": sum(r["weight_ns"] for r in rows if r["frames"] and unknown(r["frames"][0])),
        "any_unknown_frame_weight_ns": sum(r["weight_ns"] for r in rows if any(map(unknown, r["frames"]))),
        "all_unknown_frames_weight_ns": sum(r["weight_ns"] for r in rows if r["frames"] and all(map(unknown, r["frames"]))),
    }


def worst_one_second_window(samples, start, end):
    """Select the earliest exact maximum of the linear kernel CPU counter.

    Samples must already have authenticated, increasing timestamps and CPU
    counters. As in app.cpu_interval_metrics, extrema occur at counter
    breakpoints or breakpoints shifted by one second, including both edges.
    """
    require(number(end, "selection end") - number(start, "selection start") >= 1,
            "Worst-second selection needs a complete second")
    start, end = Decimal(str(start)), Decimal(str(end))
    times = [Decimal(str(sample["monotonic_seconds"])) for sample in samples]
    values = [Decimal(str(sample["cpu_seconds"])) for sample in samples]
    require(times and times[0] <= start < end <= times[-1], "Selection lacks kernel coverage")
    require(all(a < b for a, b in zip(times, times[1:]))
            and all(a <= b for a, b in zip(values, values[1:])), "Selection counters are not monotonic")

    def counter(timestamp):
        index = bisect_right(times, timestamp) - 1
        if times[index] == timestamp or index == len(times) - 1:
            return values[index]
        fraction = (timestamp - times[index]) / (times[index + 1] - times[index])
        return values[index] + fraction * (values[index + 1] - values[index])

    candidates = {start + 1, end}
    candidates.update(timestamp for timestamp in times if start + 1 <= timestamp <= end)
    candidates.update(timestamp + 1 for timestamp in times if start + 1 <= timestamp + 1 <= end)
    right = max(sorted(candidates), key=lambda point: counter(point) - counter(point - 1))
    peak = float(100 * (counter(right) - counter(right - 1)))
    reference = app.cpu_interval_metrics(samples, float(start), float(end))["rolling_1s_percent"]
    require(math.isclose(peak, reference, rel_tol=1e-10, abs_tol=1e-8),
            "Selected worst second disagrees with the CPU interval metric")
    return {"start_monotonic_seconds": float(right - 1), "end_monotonic_seconds": float(right),
            "selection": {"source": "same-process profiled kernel CPU counter",
                          "rolling_1s_percent": peak, "acceptance_eligible": False,
                          "tie_policy": "earliest complete one-second interval",
                          "candidate_policy": "all linear-counter breakpoints and one-second shifted breakpoints"}}


def arrival_profile_windows(report):
    """Bind eight diagnostic windows to the validated three-episode replay."""
    runtime, identity = report["runtime"], report["owned_identity"]
    require(runtime.get("profiled") is True, "Arrival attribution requires a profiled replay")
    anchor = {"monotonic_before_ns": 1, "monotonic_after_ns": 1, "wall_time_ns": 1,
              **{name: runtime[name] for name in ("mach_clock_start", "mach_clock_end")}}
    mapping = clock_mapping({"start_epoch_ns": 1, "duration_seconds": 1}, anchor)
    samples, birth = validate_kernel_samples(report["samples"], identity["process_id"], mapping)
    require(birth == identity["birth_time_us"], "Arrival profile kernel process birth differs")
    offset = mapping["python_to_mach_offset_seconds"]
    episodes, original = report["episodes"], report["phase_windows"]
    require(isinstance(episodes, list) and len(episodes) == 3, "Arrival profile needs exactly three episodes")
    result = {}
    for ordinal, episode in enumerate(episodes, 1):
        require(episode.get("ordinal") == ordinal, "Arrival profile episode order differs")
        streams = episode["fixture_status"]["timing"]["streams"]
        require(isinstance(streams, list) and len(streams) == 2, "Arrival profile requires both stream timings")
        began = min(number(stream.get("first_write_started_monotonic_seconds"), "arrival source start") for stream in streams)
        terminal = min(number(stream.get("terminal_write_started_monotonic_seconds"), "arrival terminal start") for stream in streams)
        require(began + 4 < terminal, "Arrival profile lacks complete steady traffic")
        name = f"episode-{ordinal}-arrival"
        window = original[name]
        require(window.get("start_monotonic_seconds") == began
                and window.get("end_monotonic_seconds") == began + 2,
                "Arrival profile window differs from exact two-second source interval")
        result[name] = {"start_monotonic_seconds": began, "end_monotonic_seconds": began + 2}
        selected = worst_one_second_window(samples, began + offset, began + 2 + offset)
        selected["start_monotonic_seconds"] -= offset
        selected["end_monotonic_seconds"] -= offset
        result[f"{name}-worst-1s"] = selected
    result["episode-3-steady"] = {"start_monotonic_seconds": began + 2, "end_monotonic_seconds": began + 4}
    whole = original["whole_replay"]
    left, right = (number(whole.get(key), "whole replay boundary") for key in ("start_monotonic_seconds", "end_monotonic_seconds"))
    require(all(left <= window["start_monotonic_seconds"] < window["end_monotonic_seconds"] <= right
                for window in result.values()), "Arrival profile phases extend outside the whole replay")
    require(runtime["mach_clock_start"]["monotonic_seconds"] <= left < right
            <= runtime["mach_clock_end"]["monotonic_seconds"], "Arrival profile is outside paired Mach bridges")
    result["whole_replay"] = {"start_monotonic_seconds": left, "end_monotonic_seconds": right}
    return result


def call_tree(rows, elapsed):
    """Bounded caller context; recursion keeps distinct nodes, never extra CPU."""
    nodes = [{"node_id": 0, "parent_id": None, "symbol": "<all owned-process threads>",
              "inclusive_weight_ns": 0, "self_weight_ns": 0, "sample_count": 0}]
    lookup, overflow = {}, 0
    for row in rows:
        path = list(reversed(row["frames"])) or ["<missing stack>"]
        parent, missing = 0, None
        for index, symbol in enumerate(path):
            child = lookup.get((parent, symbol))
            if child is None:
                missing = index
                break
            parent = child
        # Reserve one node for CPU whose stack cannot fit the bounded tree.
        if missing is not None and len(nodes) + len(path) - missing > MAX_CALL_TREE_NODES - 1:
            overflow += row["weight_ns"]
            path = ["<unexpanded stack: call-tree node limit>"]
        parent = 0
        nodes[0]["inclusive_weight_ns"] += row["weight_ns"]
        nodes[0]["sample_count"] += 1
        for symbol in path:
            key = (parent, symbol)
            if key not in lookup:
                lookup[key] = len(nodes)
                nodes.append({"node_id": len(nodes), "parent_id": parent, "symbol": symbol,
                              "inclusive_weight_ns": 0, "self_weight_ns": 0, "sample_count": 0})
            parent = lookup[key]
            nodes[parent]["inclusive_weight_ns"] += row["weight_ns"]
            nodes[parent]["sample_count"] += 1
        nodes[parent]["self_weight_ns"] += row["weight_ns"]
    top_inclusive = sorted(nodes[1:], key=lambda node: (-node["inclusive_weight_ns"], node["node_id"]))[:CALL_TREE_RANK_LIMIT]
    top_self = sorted((node for node in nodes[1:] if node["self_weight_ns"]),
                      key=lambda node: (-node["self_weight_ns"], node["node_id"]))[:CALL_TREE_RANK_LIMIT]
    selected = {0}
    for node in top_inclusive + top_self:
        current = node["node_id"]
        while current not in selected:
            selected.add(current)
            current = nodes[current]["parent_id"]
    output = []
    for index in sorted(selected):
        node = dict(nodes[index])
        for kind in ("inclusive", "self"):
            weight = node[f"{kind}_weight_ns"]
            node[f"{kind}_cpu_ms"] = weight / 1e6
            node[f"{kind}_cpu_percent_one_core"] = weight / 1e9 / elapsed * 100
        output.append(node)
    return {"nodes": output, "top_inclusive_node_ids": [node["node_id"] for node in top_inclusive],
            "top_self_node_ids": [node["node_id"] for node in top_self],
            "total_node_count": len(nodes), "omitted_node_count": len(nodes) - len(output),
            "unexpanded_stack_weight_ns": overflow,
            "semantics": "Root-to-leaf caller context across all app threads; inclusive includes descendants. Parent and child rows overlap."}


def sampling_resolution(rows, elapsed):
    weights = [row["weight_ns"] for row in rows]
    total = sum(weights)
    effective = total * total / sum(weight * weight for weight in weights)
    return {"sample_count": len(rows), "effective_weighted_sample_count": effective,
            "largest_sample_cpu_percentage_points": max(weights) / 1e9 / elapsed * 100,
            "one_sample_fraction_of_sampled_cpu_percent": max(weights) / total * 100,
            "independent_poisson_relative_standard_error_reference": 1 / math.sqrt(effective),
            "warning": "Count-based resolution diagnostic, not a confidence interval or quality threshold. Samples may be correlated; one-second rankings can be noisy."}


def analyze_exports(toc_path, profile_path, owned_pid, phase_windows, clock_anchor, samples):
    toc = validate_toc(toc_path, owned_pid)
    rows, quality = parse_running_samples(profile_path, owned_pid)
    require(all(r["time_ns"] <= (toc["duration_seconds"] + .005) * 1e9 for r in rows),
            "Running sample lies outside trace duration")
    mapping = clock_mapping(toc, clock_anchor)
    kernel_samples, birth = validate_kernel_samples(samples, owned_pid, mapping)
    mapping["trace_mapping_uncertainty_seconds"] = mapping["mapping_uncertainty_seconds"]
    mapping["kernel_clock_uncertainty_seconds"] = max(sample["clock_read_uncertainty_seconds"] for sample in samples)
    mapping["mapping_uncertainty_seconds"] += mapping["kernel_clock_uncertainty_seconds"]
    require(isinstance(phase_windows, dict) and 0 < len(phase_windows) <= MAX_PHASES, "Invalid phase count")
    phases = []
    for name, window in phase_windows.items():
        require(isinstance(name, str) and 0 < len(name) <= 100 and isinstance(window, dict), "Invalid phase definition")
        start = number(window.get("start_monotonic_seconds"), "phase start")
        end = number(window.get("end_monotonic_seconds"), "phase end")
        require(start < end, "Phase has no positive duration")
        require(clock_anchor["mach_clock_start"]["monotonic_seconds"] <= start < end <= clock_anchor["mach_clock_end"]["monotonic_seconds"],
                "Phase is not bracketed by Mach bridges")
        relative = [start - mapping["trace_origin_python_monotonic_seconds"], end - mapping["trace_origin_python_monotonic_seconds"]]
        uncertainty = mapping["mapping_uncertainty_seconds"]
        require(uncertainty <= relative[0] < relative[1] <= toc["duration_seconds"] - uncertainty,
                "Phase is not contained within the trace with clock uncertainty")
        require(min(r["time_ns"] for r in rows) < relative[0] * 1e9 and max(r["time_ns"] for r in rows) > relative[1] * 1e9,
                "Running samples do not bracket the phase")
        selected = [r for r in rows if relative[0] * 1e9 <= r["time_ns"] < relative[1] * 1e9]
        require(selected, "Phase contains no Running samples; attribution unavailable")
        elapsed, total = end - start, sum(r["weight_ns"] for r in selected)
        def summary(label, subset):
            weight = sum(r["weight_ns"] for r in subset)
            return {"execution": label, "sample_count": len(subset), "weight_ns": weight,
                    "cpu_ms": weight / 1e6, "cpu_percent_one_core": weight / 1e9 / elapsed * 100,
                    "sampled_app_cpu_share_percent": weight / total * 100}
        inclusive = [summary(label, [r for r in selected if any(query in f for f in r["frames"])]) for label, query in QUERIES]
        symbol_weights, leaf_weights, symbol_counts, leaf_counts = Counter(), Counter(), Counter(), Counter()
        for row in selected:
            for symbol in set(row["frames"]):
                symbol_weights[symbol] += row["weight_ns"]
                symbol_counts[symbol] += 1
            leaf = row["frames"][0] if row["frames"] else "<missing stack>"
            leaf_weights[leaf] += row["weight_ns"]
            leaf_counts[leaf] += 1
        def ranked(weights, counts):
            return [{"symbol": symbol, "sample_count": counts[symbol], "weight_ns": ns,
                     "cpu_ms": ns / 1e6, "cpu_percent_one_core": ns / 1e9 / elapsed * 100}
                    for symbol, ns in weights.most_common(40)]
        offset = mapping["python_to_mach_offset_seconds"]
        kernel = app.cpu_interval_metrics(kernel_samples, start + offset, end + offset)
        kernel["average_cpu_percent"] = kernel["cpu_seconds"] / elapsed * 100
        kernel["acceptance_eligible"] = False
        sampled_percent = total / 1e9 / elapsed * 100
        absolute_difference = abs(sampled_percent - kernel["average_cpu_percent"])
        relative_difference = (absolute_difference / kernel["average_cpu_percent"]
                               if kernel["average_cpu_percent"] else None)
        significant_mismatch = (absolute_difference > SAMPLE_KERNEL_ABSOLUTE_LIMIT
                                and (relative_difference is None or relative_difference > SAMPLE_KERNEL_RELATIVE_LIMIT))
        agreement = {"within_tolerance": not significant_mismatch,
                     "absolute_difference_percentage_points": absolute_difference,
                     "relative_difference_of_kernel": relative_difference,
                     "kernel_counter_is_zero": kernel["cpu_seconds"] == 0,
                     "policy": SAMPLE_KERNEL_POLICY}
        touching = [r for r in rows if min(abs(r["time_ns"] / 1e9 - edge) for edge in relative) <= uncertainty]
        shifted = [sum(r["weight_ns"] for r in rows if (relative[0] + shift) * 1e9 <= r["time_ns"] < (relative[1] + shift) * 1e9) / 1e6
                   for shift in (-uncertainty, uncertainty)]
        edge_coverage = (min(r["time_ns"] for r in rows) <= (relative[0] - uncertainty) * 1e9
                         and max(r["time_ns"] for r in rows) >= (relative[1] + uncertainty) * 1e9)
        threads = sorted({r["thread_id"] for r in selected})
        phases.append({"phase": name, "elapsed_seconds": elapsed,
                       "window_python_monotonic_seconds": [start, end],
                       "window_selection": window.get("selection"),
                       "window_trace_relative_seconds": relative, "window_mach_absolute_seconds": [start + offset, end + offset],
                       "total": summary("All owned-process threads", selected), "inclusive": inclusive,
                       "top_inclusive_symbols": ranked(symbol_weights, symbol_counts), "top_leaf_symbols": ranked(leaf_weights, leaf_counts),
                       "call_tree": call_tree(selected, elapsed),
                       "sampling_resolution": sampling_resolution(selected, elapsed),
                       "thread_totals": [{"thread_id": tid,
                           "thread_names": sorted({r["thread"] for r in selected if r["thread_id"] == tid and r["thread"]}),
                           **summary(f"Thread {tid}", [r for r in selected if r["thread_id"] == tid])} for tid in threads],
                       "kernel_cpu_same_window": kernel,
                       "sample_kernel_agreement": agreement,
                       "sampled_minus_kernel_percent_of_kernel": ((total / 1e9 / kernel["cpu_seconds"] - 1) * 100 if kernel["cpu_seconds"] else None),
                       "quality": symbol_quality(selected), "threads": threads,
                       "edge_uncertainty": {"seconds": uncertainty, "touching_sample_count": len(touching),
                                            "running_samples_bracket_full_uncertainty": edge_coverage,
                                            "touching_sample_weight_ms": sum(r["weight_ns"] for r in touching) / 1e6,
                                            "sampled_total_ms_at_minus_plus_uncertainty": shifted}})
    all_missing = all(p["quality"]["missing_stack_weight_ns"] + p["quality"]["all_unknown_frames_weight_ns"] == p["total"]["weight_ns"] for p in phases)
    mismatched_phases = [phase["phase"] for phase in phases if not phase["sample_kernel_agreement"]["within_tolerance"]]
    unbracketed_phases = [phase["phase"] for phase in phases if not phase["edge_uncertainty"]["running_samples_bracket_full_uncertainty"]]
    usable = not all_missing and not mismatched_phases and not unbracketed_phases
    return {"status": "profiled_phase_attribution_available" if usable else "analysis_pending",
            "regression_passed": False, "process_id": owned_pid, "birth_time_us": birth,
            "analysis_quality": {"quantitative_attribution_usable": usable,
                                 "sample_kernel_mismatch_phases": mismatched_phases,
                                 "clock_uncertainty_unbracketed_phases": unbracketed_phases,
                                 "all_selected_symbols_missing": all_missing,
                                 "policy": SAMPLE_KERNEL_POLICY},
            "clock": mapping, "recording": toc, "recording_quality": quality, "phases": phases,
            "evidence": {str(Path(p)): digest(p) for p in (toc_path, profile_path, Path(__file__))},
            "limitations": [
                "Profiled statistical samples only; no unprofiled CPU, GPU, memory or write acceptance.",
                "Running sample weights are nanoseconds; 100% CPU means one core. Never rescaled to kernel counters.",
                "Inclusive symbols count each sample once despite recursion. Parent/child rows overlap and must not be added.",
                "Call-tree nodes retain recursive caller context; self CPU excludes descendants. Ranked nodes and their ancestors are retained, with explicit omitted-node and unexpanded-stack counts.",
                "Leaf symbols exclude synchronous descendants; absent asynchronous ancestors receive no attribution.",
                "Per-phase sample resolution is descriptive, not a confidence interval. Short-window rankings can vary substantially between captures.",
                "Unknown and compiler-deduplicated symbols remain explicit in the quality counters.",
                "Kernel counters are interpolated within the identical profiled interval, not independent acceptance measurements.",
                "Material sample/kernel disagreement makes analysis pending; raw weights and rankings remain unscaled and are not reliable absolute CPU attribution.",
                "TOC dates have finite precision. Mapping assumes no wall-clock step between the paired anchor and trace start.",
                "Running samples must bracket the whole mapping-uncertainty range at both phase edges, or quantitative attribution remains pending.",
                "Named phases may omit intermediate traffic; retain the whole contiguous runtime phase separately.",
                "The caller must validate recording loss diagnostics and owned-process birth/clean-exit evidence.",
            ]}


def bounded_export(trace_path, output_path, selector, deadline):
    """Run one owned export, with time, XML and log bounds; never overwrite."""
    output_path = Path(output_path)
    log_path = output_path.with_suffix(".export.log")
    require(not output_path.exists() and not log_path.exists(), "Refusing to overwrite export evidence")
    require(selector in ("toc", "time-profile"), "Unsupported export selector")
    bound = MAX_TOC_BYTES if selector == "toc" else MAX_PROFILE_BYTES
    command = ["/usr/bin/xcrun", "xctrace", "export", "--input", str(trace_path), "--output", str(output_path)]
    command += ["--toc"] if selector == "toc" else ["--xpath", '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]']
    started = time.monotonic()
    end = started + deadline.remaining(45)
    process = None
    try:
        with log_path.open("xb") as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            while process.poll() is None:
                require(log_path.stat().st_size <= MAX_LOG_BYTES, "Export log exceeds its bound")
                require(not output_path.exists() or output_path.stat().st_size <= bound, "Export XML exceeds its bound")
                remaining = min(end - time.monotonic(), deadline.remaining())
                if remaining <= 0:
                    raise TimeoutError("Time Profiler export exceeded its deadline")
                try:
                    process.wait(timeout=min(.1, remaining))
                except subprocess.TimeoutExpired:
                    pass
            require(process.returncode == 0, f"Time Profiler export failed with exit {process.returncode}")
        require(log_path.stat().st_size <= MAX_LOG_BYTES, "Export log exceeds its bound")
        require(output_path.is_file() and 0 < output_path.stat().st_size <= bound, "Missing or excessive export output")
    finally:
        if process is not None and process.poll() is None:
            try:
                require(os.getpgid(process.pid) == process.pid, "Exporter no longer owns its process group")
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                # The exporter can exit between poll(), getpgid(), and killpg().
                # Reap our child without replacing the original export error.
                pass
            process.wait(timeout=2)
    return {"command": command, "exit_code": process.returncode, "elapsed_seconds": time.monotonic() - started,
            "output": str(output_path), "output_sha256": digest(output_path),
            "log": str(log_path), "log_sha256": digest(log_path)}


def analyze_trace(trace_path, output_dir, owned_pid, phase_windows, clock_anchor, samples, deadline):
    """Export exactly two tables, analyze them, and persist attributed evidence."""
    output = Path(output_dir)
    output.mkdir(parents=True, exist_ok=True)
    toc, profile, destination = output / "toc.xml", output / "time-profile.xml", output / "cpu-attribution.json"
    require(not destination.exists(), "Refusing to overwrite attribution evidence")
    exports = [bounded_export(trace_path, toc, "toc", deadline),
               bounded_export(trace_path, profile, "time-profile", deadline)]
    with deadline.interrupt_at(min(deadline.end, time.monotonic() + deadline.remaining(30))):
        report = analyze_exports(toc, profile, owned_pid, phase_windows, clock_anchor, samples)
        report["exports"] = exports
        app.write_json(destination, report)
    return report
