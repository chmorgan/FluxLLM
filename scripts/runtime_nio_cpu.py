"""Cumulative NIO scope CPU at authenticated, actual event-loop checkpoints.

Nested scopes are never added twice. CLOCK_THREAD_CPUTIME_ID deltas are checked
against independently calibrated kernel thread reads surrounding each endpoint;
acknowledgement timestamps are not substituted for event-loop capture times.
"""
from decimal import Decimal

import runtime_thread_cpu as threads
from run_performance_checks import require

METRICS = ("upstream_read", "upstream_read_complete", "forwarding", "coalescer", "framing",
           "json_decode", "interpretation", "relay_update", "relay_scheduled")
FIELDS = ("calls", "cpu_ns", "bytes", "records", "bodies", "ends")
TOP_LEVEL = ("upstream_read", "upstream_read_complete", "relay_scheduled")
READ_CHILDREN = ("forwarding", "framing", "json_decode", "interpretation", "relay_update")
MAX_EXTERNAL_ENDPOINT_SECONDS = .5
MAX_SNAPSHOT_SECONDS = .01
CLOCK_ROUNDING_NS = 2


def _calibration(value):
    require(isinstance(value, dict) and value.get("available") is True
            and value.get("clock") == "CLOCK_THREAD_CPUTIME_ID"
            and type(value.get("iterations")) is int and value["iterations"] == 1000,
            "NIO clock and empty-scope calibration is missing or changed")
    for key in ("pair_cpu_ns", "pair_wall_ns", "empty_scope_cpu_ns", "empty_scope_wall_ns", "empty_scope_measured_ns"):
        threads._uint(value.get(key), "NIO calibration " + key, 1 if "wall" in key else 0)
    require(value["pair_cpu_ns"] > 0 and value["empty_scope_cpu_ns"] > 0,
            "NIO calibration has no positive CPU work")
    require(value["pair_cpu_ns"] <= value["pair_wall_ns"] + 1000
            and value["empty_scope_cpu_ns"] <= value["empty_scope_wall_ns"] + 1000
            and value["empty_scope_measured_ns"] <= value["empty_scope_cpu_ns"] + 1000,
            "NIO calibration CPU exceeds its enclosing clock interval")
    return value


def _capture(value, identity, role, timebase, calibration):
    require(isinstance(value, dict) and value.get("available") is True and value.get("error") is None,
            "NIO scope checkpoint is missing or unavailable")
    require(type(value.get("schema_version")) is int and value["schema_version"] == 1,
            "NIO scope schema changed")
    require(threads._uint(value.get("process_id"), "NIO process", 1) == identity
            and threads._uint(value.get("thread_id"), "NIO thread", 1) == role,
            "NIO scope checkpoint does not identify the registered event-loop thread")
    require(_calibration(value.get("calibration")) == calibration, "NIO scope calibration changed between snapshots")
    result = {key: threads._uint(value.get(key), "NIO " + key, 1 if key in (
              "sequence", "capture_begin_mach_ticks", "capture_end_mach_ticks") else 0)
              for key in ("sequence", "capture_begin_mach_ticks", "capture_end_mach_ticks",
                          "thread_cpu_before_ns", "thread_cpu_after_ns", "clock_reads")}
    begin, end = result["capture_begin_mach_ticks"], result["capture_end_mach_ticks"]
    factor = Decimal(timebase[0]) / timebase[1] / 1_000_000_000
    require(begin < end and Decimal(end - begin) * factor <= Decimal(str(MAX_SNAPSHOT_SECONDS)),
            "NIO snapshot Mach bracket is reversed or exceeds ten milliseconds")
    require(result["thread_cpu_before_ns"] <= result["thread_cpu_after_ns"],
            "NIO snapshot CPU bracket moved backwards")
    require(result["thread_cpu_after_ns"] - result["thread_cpu_before_ns"] <= float(Decimal(end - begin) * factor) * 1e9 + CLOCK_ROUNDING_NS,
            "NIO snapshot CPU bracket exceeds elapsed time")
    raw = value.get("metrics")
    require(isinstance(raw, dict) and set(raw) == set(METRICS), "NIO metric set changed")
    result["metrics"] = {}
    for name in METRICS:
        require(isinstance(raw[name], dict) and set(raw[name]) == set(FIELDS), "NIO metric field set changed")
        result["metrics"][name] = {key: threads._uint(raw[name].get(key), name + "." + key) for key in FIELDS}
    result.update(begin=float(Decimal(begin) * factor), end=float(Decimal(end) * factor))
    return result


def _deltas(first, last):
    return {name: {key: last["metrics"][name][key] - first["metrics"][name][key] for key in FIELDS}
            for name in METRICS}


def _nesting(values):
    require(values["coalescer"]["cpu_ns"] <= values["forwarding"]["cpu_ns"],
            "Nested coalescer CPU exceeds forwarding CPU")
    require(sum(values[name]["cpu_ns"] for name in READ_CHILDREN) <= values["upstream_read"]["cpu_ns"] + values["upstream_read_complete"]["cpu_ns"],
            "Disjoint synchronous read scopes exceed their enclosing upstream callbacks")


def _external_endpoint(point, rows):
    before = [row for row in rows if row["end"] <= point["begin"]]
    after = [row for row in rows if row["begin"] >= point["end"]]
    require(before and after, "NIO checkpoint lacks independent thread reads on both sides")
    left, right = before[-1], after[0]
    require(point["begin"] - left["end"] <= MAX_EXTERNAL_ENDPOINT_SECONDS
            and right["begin"] - point["end"] <= MAX_EXTERNAL_ENDPOINT_SECONDS,
            "NIO checkpoint external thread brackets exceed half a second")
    def cpu(row):
        return sum(row["roles"]["nio"][key] for key in ("user_cpu_ns", "system_cpu_ns"))
    return {"before_sample_index": left["sample_index"], "after_sample_index": right["sample_index"],
            "before_cpu_ns": cpu(left), "after_cpu_ns": cpu(right),
            "before_end_mach_seconds": left["end"], "after_begin_mach_seconds": right["begin"],
            "maximum_endpoint_gap_seconds": max(point["begin"] - left["end"], right["begin"] - point["end"])}


def _interval(first, last, external, window, scope, offset, uncertainty):
    minimum = last["begin"] - first["end"]
    maximum = last["end"] - first["begin"]
    require(minimum >= .5, "NIO checkpoint interval is shorter than half a second")
    lower = last["thread_cpu_before_ns"] - first["thread_cpu_after_ns"]
    upper = last["thread_cpu_after_ns"] - first["thread_cpu_before_ns"]
    require(0 <= lower <= upper, "NIO thread CPU interval moved backwards")
    values = _deltas(first, last)
    require(all(value >= 0 for counters in values.values() for value in counters.values()),
            "NIO scoped cumulative counters moved backwards")
    _nesting(values)
    top = sum(values[name]["cpu_ns"] for name in TOP_LEVEL)
    require(top <= lower + CLOCK_ROUNDING_NS, "Disjoint NIO scopes exceed same-thread CPU interval")
    ext_first, ext_last = external[first["sequence"]], external[last["sequence"]]
    ext_lower = max(0, ext_last["before_cpu_ns"] - ext_first["after_cpu_ns"] - threads.ROLE_ROUNDING_NS)
    ext_upper = ext_last["after_cpu_ns"] - ext_first["before_cpu_ns"] + threads.ROLE_ROUNDING_NS
    require(ext_lower <= lower + CLOCK_ROUNDING_NS and upper <= ext_upper + CLOCK_ROUNDING_NS,
            "Own-thread CPU delta disagrees with independently calibrated external thread brackets")
    def metrics(low, high):
        low, high = max(0, low), max(0, high)
        return {"cpu_ns_bounds": {"lower": low, "upper": high},
                "average_cpu_percent_bounds": {"lower": 100 * low / 1e9 / maximum,
                                               "upper": 100 * high / 1e9 / minimum}}
    whole = metrics(lower, upper)
    require(whole["average_cpu_percent_bounds"]["upper"] - whole["average_cpu_percent_bounds"]["lower"] <= .1,
            "NIO own-thread endpoint uncertainty exceeds 0.1 CPU percentage point")
    for value in values.values():
        value.update(metrics(value["cpu_ns"], value["cpu_ns"]))
    return {"available": True, "acceptance_eligible": False, "scope": scope, "requested_window": window,
            "start_checkpoint": {"sequence": first["sequence"], "label": first["label"]},
            "end_checkpoint": {"sequence": last["sequence"], "label": last["label"]},
            "actual_window": {"elapsed_seconds_bounds": {"lower": minimum, "upper": maximum},
                "start_python_monotonic_seconds_bounds": {"lower": first["begin"] - offset - uncertainty,
                                                           "upper": first["end"] - offset + uncertainty},
                "end_python_monotonic_seconds_bounds": {"lower": last["begin"] - offset - uncertainty,
                                                         "upper": last["end"] - offset + uncertainty}},
            "metrics": values, "whole_thread": whole, "disjoint_top_level_cpu_ns": top,
            "unassigned_thread": metrics(lower - top, upper - top),
            "upstream_callbacks_unassigned_cpu_ns": values["upstream_read"]["cpu_ns"] + values["upstream_read_complete"]["cpu_ns"] - sum(values[name]["cpu_ns"] for name in READ_CHILDREN),
            "external_thread_check": {"start": ext_first, "end": ext_last, **metrics(ext_lower, ext_upper),
                "rounding_allowance_ns": threads.ROLE_ROUNDING_NS, "consistent": True,
                "scope": "Kernel reads bracket actual NIO captures; uncertainty is retained, not subtracted"},
            "clock_reads_delta": last["clock_reads"] - first["clock_reads"]}


def _workload_counts(report, whole):
    import performance_fixture as fixture
    workload = report["workload"]
    indices = workload["fixture_start"]["expected_request_indices"]
    streams = workload["fixture_status"]["timing"]["streams"]
    require(len(indices) == len(streams) == 2 and len(set(indices)) == 2,
            "NIO exact accounting requires two authenticated fixture streams")
    duration = workload["specification"]["seconds"]
    require(duration == 25 and workload["fixture_start"]["expected_chunks"] == 10000,
            "NIO scope workload differs from the fixed 25-second fixture")
    chunks = 5000
    require(all(stream["records_observed"] == chunks + 1 for stream in streams),
            "NIO fixture lacks all content and terminal records")
    payload = sum(len(fixture.encoded(fixture.record(index, chunk, chunks, duration)))
                  for index in indices for chunk in range(chunks + 1))
    records = (chunks + 1) * len(indices)
    body = payload + records
    values = whole["metrics"]
    require(values["framing"]["records"] == values["json_decode"]["calls"] == values["json_decode"]["records"]
            == values["interpretation"]["calls"] == values["interpretation"]["records"]
            == values["relay_update"]["records"] == records,
            "NIO parsed/decoded/interpreted/relay records differ from exact forwarded fixture records")
    require(values["forwarding"]["bytes"] == values["coalescer"]["bytes"]
            == values["framing"]["bytes"] == body and values["json_decode"]["bytes"] == payload,
            "NIO body or JSON payload byte totals differ from authentic fixture encoding")
    require(values["forwarding"]["bodies"] == values["coalescer"]["calls"] == values["framing"]["bodies"]
            and values["forwarding"]["ends"] == values["framing"]["ends"] == len(indices)
            and values["framing"]["calls"] == values["framing"]["bodies"] + values["framing"]["ends"],
            "NIO body forwarding/framing counts or terminal ends disagree")
    return {"validated": True, "records": records, "body_bytes": body, "json_payload_bytes": payload,
            "body_callbacks": values["forwarding"]["bodies"], "ends": len(indices),
            "scope": "Whole before-traffic to completion-end checkpoints; body callbacks may differ from records due to TCP segmentation"}


def analyze_report(report, required=False):
    result = {"status": "unavailable", "available": False, "required": required, "errors": [],
              "acceptance_eligible": False, "rolling_1s_attribution": {"available": False,
                  "reason": "Cumulative scopes use actual checkpoint endpoints; no interpolation creates exact per-stage rolling one-second peaks"},
              "inclusion": {"disjoint_top_level": TOP_LEVEL, "disjoint_children_of_upstream_callbacks": READ_CHILDREN,
                  "coalescer": "Nested in forwarding, including synchronous encoder/write/flush; do not add again",
                  "unassigned_thread": "Whole NIO thread minus upstream_read, upstream_read_complete, relay_scheduled; includes event-loop/deferred writes, other callbacks, control snapshots and instrumentation",
                  "upstream_read": "Raw upstream channel reads before HTTP decoding, including synchronous decoder and downstream callbacks; bytes include HTTP wire framing",
                  "calibration": "Clock and empty-scope costs are reported, never subtracted"}}
    try:
        points = report.get("runtime", {}).get("checkpoints", [])
        present = any("nio_cpu" in point.get("snapshot", {}) for point in points)
        if not present:
            require(not required, "Required NIO scope instrumentation is missing")
            return result | {"reason": "Frozen app does not export optional NIO scopes"}
        direct = threads.analyze_report(report, required=True)
        require(direct.get("available") is True, "Independent thread accounting failed: " + "; ".join(direct.get("errors", [])))
        roles, ready = threads._registration(report)
        runtime = report["runtime"]
        bridges = runtime["mach_clock_start"], runtime["mach_clock_end"]
        offset = sum(bridge["absolute_minus_monotonic_seconds"] for bridge in bridges) / 2
        uncertainty = abs(bridges[0]["absolute_minus_monotonic_seconds"] - bridges[1]["absolute_minus_monotonic_seconds"]) / 2 + max(bridge["uncertainty_seconds"] for bridge in bridges)
        timebase = (bridges[0]["numer"], bridges[0]["denom"])
        _, compact = threads._calibration(report["events"], timebase)
        events = [envelope["event"] for envelope in report["events"]
                  if envelope.get("type") == "app_event" and isinstance(envelope.get("event"), dict)
                  and "snapshot" in envelope["event"]]
        require(events and events[0].get("type") == "ready", "NIO scopes lack their ready snapshot")
        calibration = _calibration(events[0]["snapshot"].get("nio_cpu", {}).get("calibration"))
        captures, previous = {}, None
        for event in events:
            value = event["snapshot"].get("nio_cpu")
            captured = _capture(value, ready["process_id"], roles["nio"], timebase, calibration)
            if previous:
                require(previous["sequence"] < captured["sequence"]
                        and previous["end"] <= captured["begin"]
                        and previous["thread_cpu_after_ns"] <= captured["thread_cpu_before_ns"]
                        and previous["clock_reads"] <= captured["clock_reads"],
                        "NIO capture sequence, clock, or CPU counters moved backwards")
                delta = _deltas(previous, captured)
                require(all(value >= 0 for counters in delta.values() for value in counters.values()),
                        "NIO metric counters moved backwards between acknowledged captures")
                _nesting(delta)
                expected_reads = 2 * (sum(value["calls"] for value in delta.values())
                                      + captured["sequence"] - previous["sequence"])
                require(captured["clock_reads"] - previous["clock_reads"] == expected_reads,
                        "NIO clock reads disagree with complete scope and snapshot counts")
            captures[captured["sequence"]] = (captured, event["snapshot"])
            previous = captured
        selected = []
        for point in points:
            snapshot = point["snapshot"]
            sequence = snapshot.get("nio_cpu", {}).get("sequence")
            require(type(sequence) is int and sequence in captures, "Runtime NIO checkpoint is absent from original app events")
            captured, authentic = captures[sequence]
            require(all(snapshot.get(key) == value for key, value in authentic.items())
                    and set(snapshot) <= set(authentic) | {"runner_collector_sample_monotonic_seconds"},
                    "Runtime NIO checkpoint differs from authenticated app snapshot")
            require(snapshot.get("dashboard_visible") is True and snapshot.get("popover_visible") is True,
                    "NIO runtime windows are not both visible")
            sample = point["resource_sample"]
            matches = [value for value in report["samples"] if value.get("monotonic_seconds") == snapshot.get("runner_collector_sample_monotonic_seconds")]
            require(len(matches) == 1 and matches[0] == sample
                    and sample["process_id"] == ready["process_id"] and sample["birth_time_us"] == ready["birth_time_us"],
                    "NIO runtime checkpoint lacks its authenticated process boundary")
            require(captured["end"] <= sample["mach_absolute_seconds"], "NIO snapshot occurs after its acknowledged process boundary")
            require(not selected or selected[-1]["sequence"] < sequence, "Runtime NIO checkpoints are reordered")
            selected.append(captured | {"label": point["label"]})
        require(len(selected) >= 2 and selected[0]["label"] == "before-traffic" and selected[-1]["label"] == "completion-end",
                "NIO workload checkpoint endpoints are incomplete")
        rows = []
        for index, sample in enumerate(report["samples"][:-1]):
            if isinstance(sample.get("thread_cpu"), dict) and sample["thread_cpu"].get("available") is True:
                row = threads._row(sample, report["samples"][index + 1], index, roles, compact, timebase,
                                   (ready["process_id"], ready["birth_time_us"]))
                if rows:
                    require(rows[-1]["end"] <= row["begin"] and all(rows[-1]["roles"]["nio"][key] <= row["roles"]["nio"][key]
                            for key in ("user_cpu_ns", "system_cpu_ns")), "External NIO counter sequence moved backwards")
                rows.append(row)
        external = {point["sequence"]: _external_endpoint(point, rows) for point in selected}
        intervals = {}
        windows = report["phase_windows"]
        for name, window in windows.items():
            if name == "whole_contiguous_runtime":
                first, last = selected[0], selected[-1]
                scope = "Actual before-traffic to completion-end NIO captures; these precede acknowledged phase edges"
            else:
                start, end = window["start_monotonic_seconds"], window["end_monotonic_seconds"]
                interior = [point for point in selected if point["begin"] - offset - uncertainty >= start
                            and point["end"] - offset + uncertainty <= end]
                if name == "arrival":
                    before = [point for point in selected if point["end"] - offset + uncertainty <= start]
                    after = [point for point in selected if point["begin"] - offset - uncertainty >= end]
                    require(before and after, "Arrival lacks a checkpoint superset")
                    first, last = before[-1], after[0]
                    scope = "Actual checkpoint superset of arrival, not the exact requested two-second phase"
                else:
                    require(len(interior) >= 2, name + " lacks two fully interior NIO checkpoints")
                    first, last = interior[0], interior[-1]
                    scope = "Actual fully interior NIO checkpoints; requested phase edges are not interpolated"
            intervals[name] = _interval(first, last, external, window, scope, offset, uncertainty)
        result.update(calibration=calibration, registration={"process_id": ready["process_id"], "thread_id": roles["nio"]},
                      intervals=intervals, external_endpoint_maximum_gap_seconds=MAX_EXTERNAL_ENDPOINT_SECONDS,
                      exact_work=_workload_counts(report, intervals["whole_contiguous_runtime"]))
        return result | {"status": "available", "available": True}
    except (ValueError, KeyError, TypeError, OverflowError, StopIteration) as error:
        return result | {"status": "invalid", "available": False, "errors": [str(error)]}


def render_summary(analysis):
    lines = ["", "NIO scoped CPU accounting", ""]
    if not analysis.get("available"):
        return lines + ["Unavailable: " + ("; ".join(analysis.get("errors", [])) or analysis.get("reason", "Unknown"))]
    def percent(value):
        bounds = value["average_cpu_percent_bounds"]
        return f"{bounds['lower']:.3f}–{bounds['upper']:.3f}%"
    lines += ["| Interval | Actual seconds | Whole NIO CPU | Read callback | Read-complete | Relay timer | Unassigned NIO |",
              "|---|---:|---:|---:|---:|---:|---:|"]
    for name, interval in analysis["intervals"].items():
        elapsed = interval["actual_window"]["elapsed_seconds_bounds"]
        values = interval["metrics"]
        lines.append(f"| {name} | {elapsed['lower']:.4f}–{elapsed['upper']:.4f} | {percent(interval['whole_thread'])} | "
                     + " | ".join(percent(values[metric]) for metric in TOP_LEVEL) + f" | {percent(interval['unassigned_thread'])} |")
    lines += ["", "| Steady scope | CPU | Calls | Bytes | Records | Inclusion |", "|---|---:|---:|---:|---:|---|"]
    for name, value in analysis["intervals"]["steady"]["metrics"].items():
        inclusion = "top-level" if name in TOP_LEVEL else "nested in forwarding" if name == "coalescer" else "inside upstream callbacks"
        lines.append(f"| {name} | {percent(value)} | {value['calls']} | {value['bytes']} | {value['records']} | {inclusion} |")
    return lines + ["", "Arrival is a checkpoint superset; steady and completion use actual interior endpoints. "
                    "Top-level scopes are disjoint; upstream callback children and coalescer are nested and must not be added again. "
                    "Whole NIO deltas reconcile against explicitly bounded external kernel reads. Clock/empty-scope costs "
                    "remain in measured CPU. No per-stage rolling peak or CPU acceptance is claimed."]
