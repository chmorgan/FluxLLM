"""Direct, calibrated thread CPU diagnostics with explicit endpoint bounds.

The observer reads registered threads outside the app. These cumulative kernel
counters avoid profiler sampling, but sequential reads are not simultaneous:
process reads surround every thread read, and all derived residuals retain that
uncertainty. No interpolation invents per-thread CPU at a phase boundary.
"""
from decimal import Decimal
import math

import app_performance as app
from run_performance_checks import require
from runtime_time_profile import clock_mapping, validate_kernel_samples


SOURCE = "proc_pidinfo/PROC_PIDTHREADID64INFO"
ROLES = ("main", "nio")
CALIBRATION_KEYS = ("available", "source", "raw_unit", "conversion_numer", "conversion_denom")
MAX_READ_SECONDS = .01
MAX_INTERVAL_UNCERTAINTY_PERCENT = .1
THREAD_COUNTER_RESOLUTION_NS = 1000
# PROC_PIDTHREADID64INFO encodes nanoseconds but exports microsecond-granularity
# user/system fields. Allow one microsecond plus integer conversion rounding per
# cumulative field; do not mistake the encoding for nanosecond precision.
# XNU fill_taskthreadinfo converts basic_info.*.microseconds with NSEC_PER_USEC:
# https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c
FIELD_ROUNDING_NS = THREAD_COUNTER_RESOLUTION_NS + 1
ROLE_ROUNDING_NS = FIELD_ROUNDING_NS * 2 * 2
ROUNDING_NS = ROLE_ROUNDING_NS * len(ROLES)


def _uint(value, label, minimum=0, maximum=2**64 - 1):
    require(type(value) is int and minimum <= value <= maximum, f"Invalid UInt64 {label}")
    return value


def _number(value, label, minimum=0):
    require(type(value) in (int, float) and math.isfinite(value) and value >= minimum,
            f"Invalid finite number {label}")
    return value


def _calibration(events, timebase):
    matches = [(index, event.get("calibration")) for index, event in enumerate(events)
               if event.get("type") == "thread_cpu_calibration"]
    launches = [index for index, event in enumerate(events) if event.get("type") == "launched"]
    require(len(matches) == 1 and len(launches) == 1 and matches[0][0] < launches[0],
            "Thread calibration must occur exactly once before the owned app launch")
    proof = matches[0][1]
    require(isinstance(proof, dict) and proof.get("available") is True and proof.get("source") == SOURCE,
            "Direct thread CPU calibration is unavailable")
    require(proof.get("reference") == "CLOCK_THREAD_CPUTIME_ID/getrusage/owned-process-rusage"
            and proof.get("external_owned_child") is True and proof.get("dead_thread_rejected") is True,
            "Thread calibration lacks independent external-child and dead-thread proof")
    for key in ("process_id", "birth_time_us", "thread_id"):
        _uint(proof.get(key), "calibration helper " + key, 1)
    require(proof.get("timebase") == {"numer": timebase[0], "denom": timebase[1]}
            and all(type(proof["timebase"][key]) is int for key in ("numer", "denom")),
            "Calibration helper timebase differs from the measured app")
    require(type(proof.get("tolerance_relative")) is float and proof["tolerance_relative"] == .05
            and type(proof.get("tolerance_absolute_ns")) is int and proof["tolerance_absolute_ns"] == 2_000_000,
            "Thread calibration tolerance changed")
    numer = _uint(proof.get("conversion_numer"), "calibration numerator", 1, 2**32 - 1)
    denom = _uint(proof.get("conversion_denom"), "calibration denominator", 1, 2**32 - 1)
    require((proof.get("raw_unit") == "nanoseconds" and (numer, denom) == (1, 1))
            or (proof.get("raw_unit") == "mach_ticks" and (numer, denom) == timebase),
            "Thread calibration raw units do not match the measured conversion")
    phases = proof.get("phases")
    require(isinstance(phases, list) and len(phases) == 3 and all(isinstance(phase, dict) for phase in phases)
            and {phase.get("name") for phase in phases} == {"continuous", "bursty", "idle"},
            "Thread calibration requires continuous, bursty, and idle phases")
    for phase in phases:
        require(phase.get("passed") is True, "A thread calibration phase failed")
        raw = _uint(phase.get("thread_raw_delta"), "calibration raw delta")
        measured = _uint(phase.get("measured_thread_cpu_ns"), "calibration measured CPU")
        require(abs(measured - raw * numer // denom) <= 1, "Calibration raw conversion disagrees")
        wall = _number(phase.get("wall_seconds"), "calibration wall seconds")
        require(0 < wall < 10, "Calibration phase exceeds its bounded duration")
        for key in ("thread_clock_delta_ns", "getrusage_delta_ns", "process_cpu_delta_ns"):
            reference = _uint(phase.get(key), "calibration " + key)
            require(abs(measured - reference) <= max(2_000_000, reference * .05),
                    "Calibrated thread CPU disagrees with an independent reference")
        reference = phase["thread_clock_delta_ns"]
        require((phase["name"] == "continuous" and reference >= 50_000_000)
                or (phase["name"] == "bursty" and reference >= 30_000_000)
                or (phase["name"] == "idle" and reference < 5_000_000 and measured < 5_000_000),
                "Thread calibration lacks positive active or quiet idle evidence")
    overhead = proof.get("observer_overhead")
    require(isinstance(overhead, dict) and _uint(overhead.get("read_count"), "observer read count") == 200,
            "Thread calibration observer overhead sample count changed")
    _uint(overhead.get("cpu_ns"), "observer CPU")
    _uint(overhead.get("wall_ns"), "observer wall", 1)
    require(0 < _number(proof.get("elapsed_seconds"), "calibration elapsed") <= 10,
            "Thread calibration exceeds its bounded duration")
    return proof, {key: proof[key] for key in CALIBRATION_KEYS}


def _registration(report):
    events, samples = report["events"], report["samples"]
    ready = app.authenticated_cpu_ready(samples, events)
    require((ready["process_id"], ready["birth_time_us"]) ==
            (report["owned_identity"]["process_id"], report["owned_identity"]["birth_time_us"]),
            "Registered thread CPU process differs from the owned process")
    event = next(event["event"] for event in events if event.get("type") == "app_event"
                 and event.get("event", {}).get("type") == "ready")
    registration = event.get("snapshot", {}).get("thread_cpu_registration")
    require(isinstance(registration, dict) and type(registration.get("schema_version")) is int
            and registration["schema_version"] == 1 and type(registration.get("process_id")) is int
            and registration["process_id"] == ready["process_id"],
            "Ready event lacks the authenticated thread CPU registration")
    roles = registration.get("roles")
    require(isinstance(roles, dict) and set(roles) == set(ROLES), "Thread registration role set changed")
    roles = {role: _uint(roles[role], "registered " + role + " thread", 1) for role in ROLES}
    require(len(set(roles.values())) == len(ROLES), "Main and NIO registrations reuse a thread ID")
    seen_ready = False
    for envelope in events:
        if envelope.get("type") != "app_event" or not isinstance(envelope.get("event"), dict):
            continue
        app_event = envelope["event"]
        seen_ready = seen_ready or app_event.get("type") == "ready"
        if seen_ready and "snapshot" in app_event:
            require(isinstance(app_event["snapshot"], dict)
                    and app_event["snapshot"].get("thread_cpu_registration") == registration,
                    "App snapshot changed or omitted the immutable thread registration")
    exits = [event for event in events if event.get("type") == "exited"]
    require(len(exits) == 1 and type(exits[0].get("status")) is int and exits[0]["status"] == 0
            and exits[0].get("final_sample") == samples[-1] and samples[-1].get("phase") == "final",
            "Direct thread CPU requires an authenticated clean owned-process exit")
    return roles, ready


def _row(sample, following, index, roles, compact, timebase, identity):
    group = sample.get("thread_cpu")
    require(isinstance(group, dict) and group.get("available") is True,
            f"Thread CPU sample {index} is missing or unavailable")
    require(type(group.get("schema_version")) is int and group["schema_version"] == 1
            and group.get("source") == SOURCE, "Thread CPU schema or source changed")
    require(type(group.get("process_id")) is int and type(group.get("birth_time_us")) is int
            and (group["process_id"], group["birth_time_us"]) == identity,
            "Thread CPU sample process identity differs")
    require(group.get("timebase") == {"numer": timebase[0], "denom": timebase[1]}
            and all(type(group["timebase"][key]) is int for key in ("numer", "denom")),
            "Thread CPU timebase differs from authenticated process samples")
    supplied = group.get("calibration")
    require(isinstance(supplied, dict) and supplied == compact
            and all(type(supplied[key]) is type(compact[key]) for key in compact),
            "Thread CPU calibration changed or disappeared during collection")
    begin = _uint(group.get("read_begin_mach_ticks"), "thread read begin", 1)
    end = _uint(group.get("read_end_mach_ticks"), "thread read end", 1)
    factor = Decimal(timebase[0]) / timebase[1] / 1_000_000_000
    require(sample["mach_absolute_ticks"] <= begin < end <= following["mach_absolute_ticks"],
            "Thread CPU read bracket is outside adjacent authenticated process samples")
    require(Decimal(end - begin) * factor <= Decimal(str(MAX_READ_SECONDS)),
            "Thread CPU read bracket exceeds the ten-millisecond quality limit")
    before = _uint(group.get("process_cpu_before_ns"), "local process before CPU")
    after = _uint(group.get("process_cpu_after_ns"), "local process after CPU")
    require(before <= after, "Local process CPU counter moved backwards")
    outer = Decimal(str(sample["cpu_seconds"])) * 1_000_000_000
    next_outer = Decimal(str(following["cpu_seconds"])) * 1_000_000_000
    require(outer - 2 <= before <= after <= next_outer + 2,
            "Local process CPU bracket disagrees with adjacent process kernel counters")
    observer = _uint(group.get("observer_cpu_ns"), "observer CPU")
    threads = group.get("threads")
    require(isinstance(threads, list) and len(threads) == len(ROLES)
            and all(isinstance(thread, dict) for thread in threads)
            and {thread.get("role") for thread in threads} == set(ROLES), "Thread CPU role set changed")
    values = {}
    for thread in threads:
        role = thread["role"]
        require(_uint(thread.get("thread_id"), "thread ID", 1) == roles[role],
                "Thread CPU identity differs from explicit ready registration")
        values[role] = {key: _uint(thread.get(key), role + "." + key)
                        for key in ("user_cpu_ns", "system_cpu_ns", "user_cpu_raw", "system_cpu_raw")}
        for prefix in ("user", "system"):
            expected = values[role][prefix + "_cpu_raw"] * compact["conversion_numer"] // compact["conversion_denom"]
            require(abs(values[role][prefix + "_cpu_ns"] - expected) <= 1,
                    "Thread CPU raw conversion disagrees with calibrated units")
    tracked = sum(values[role][key] for role in ROLES for key in ("user_cpu_ns", "system_cpu_ns"))
    require(tracked <= after + ROUNDING_NS, "Registered thread CPU exceeds cumulative process CPU")
    return {"sample_index": index, "begin": float(Decimal(begin) * factor), "end": float(Decimal(end) * factor),
            "process_before": before, "process_after": after, "roles": values, "observer_cpu_ns": observer}


def _bounds(lower, upper):
    return {"lower": lower, "upper": upper}


def _interval(rows, window, offset, uncertainty):
    start, end = (_number(window.get(key), "phase " + key) for key in
                  ("start_monotonic_seconds", "end_monotonic_seconds"))
    require(start < end, "Thread CPU phase has no positive duration")
    interior = [row for row in rows if row["begin"] - offset - uncertainty >= start
                and row["end"] - offset + uncertainty <= end]
    require(len(interior) >= 2, "Thread CPU phase lacks two fully interior counter readings")
    first, last = interior[0], interior[-1]
    minimum_elapsed = last["begin"] - first["end"]
    maximum_elapsed = last["end"] - first["begin"]
    require(minimum_elapsed >= .5, "Thread CPU interior interval is shorter than half a second")

    def metrics(lower, upper):
        require(upper >= -ROUNDING_NS, "Registered thread deltas exceed the enclosing process CPU")
        lower, upper = max(0, lower), max(0, upper)
        percentages = _bounds(100 * lower / 1e9 / maximum_elapsed, 100 * upper / 1e9 / minimum_elapsed)
        require(percentages["upper"] - percentages["lower"] <= MAX_INTERVAL_UNCERTAINTY_PERCENT,
                "Thread CPU endpoint uncertainty exceeds 0.1 CPU percentage point")
        return {"cpu_ns_bounds": _bounds(lower, upper), "average_cpu_percent_bounds": percentages}

    roles, tracked = {}, 0
    for role in ROLES:
        delta = {key: last["roles"][role][key] - first["roles"][role][key]
                 for key in ("user_cpu_ns", "system_cpu_ns")}
        total = sum(delta.values())
        tracked += total
        roles[role] = delta | {"cpu_ns": total} | metrics(total - ROLE_ROUNDING_NS, total + ROLE_ROUNDING_NS)
    lower = last["process_before"] - first["process_after"]
    upper = last["process_after"] - first["process_before"]
    require(lower >= 0 and upper >= lower, "Process CPU interval bounds moved backwards")
    return {"requested_window": dict(window), "sample_indices": {"start": first["sample_index"], "end": last["sample_index"]},
            "scope": "Actual fully interior native read endpoints; phase edges are not interpolated",
            "actual_window": {
                "start_python_monotonic_seconds_bounds": _bounds(first["begin"] - offset - uncertainty, first["end"] - offset + uncertainty),
                "end_python_monotonic_seconds_bounds": _bounds(last["begin"] - offset - uncertainty, last["end"] - offset + uncertainty),
                "elapsed_seconds_bounds": _bounds(minimum_elapsed, maximum_elapsed)},
            "roles": roles, "tracked_cpu_ns": tracked,
            "process": metrics(lower - 2, upper + 2),
            "residual": metrics(lower - tracked - ROUNDING_NS, upper - tracked + ROUNDING_NS),
            "observer_read_cpu_ns": sum(row["observer_cpu_ns"] for row in interior),
            "observer_scope": "External collector CPU for these reads; excluded from app process CPU",
            "acceptance_eligible": False}


def analyze_report(report, required=False):
    """Optional diagnostics never change the independent process CPU result."""
    result = {"status": "unavailable", "available": False, "required": required, "errors": [],
              "source": SOURCE, "acceptance_eligible": False,
              "rolling_1s_attribution": {"available": False,
                  "reason": "Direct thread intervals retain actual read endpoints; no interpolation attributes an exact rolling one-second peak"}}
    try:
        samples = report.get("samples", [])
        present = [isinstance(sample, dict) and "thread_cpu" in sample for sample in samples]
        if not any(present):
            require(not required, "Required direct thread CPU instrumentation is missing")
            return result | {"reason": "Frozen collector does not export optional direct thread CPU counters"}
        require(report.get("workload", {}).get("validated") is True and not report.get("errors"),
                "Direct thread CPU requires a completed, validated runtime workload")
        roles, ready = _registration(report)
        runtime = report["runtime"]
        anchor = {"monotonic_before_ns": 1, "monotonic_after_ns": 1, "wall_time_ns": 1,
                  **{name: runtime[name] for name in ("mach_clock_start", "mach_clock_end")}}
        mapping = clock_mapping({"start_epoch_ns": 1, "duration_seconds": 1}, anchor)
        converted, birth = validate_kernel_samples(samples, ready["process_id"], mapping)
        require(birth == ready["birth_time_us"], "Thread CPU kernel process birth differs")
        bridges = runtime["mach_clock_start"], runtime["mach_clock_end"]
        require(mapping["bridge_drift_seconds"] <= .000001
                and all(bridge["uncertainty_seconds"] <= .000001 for bridge in bridges),
                "Thread CPU paired Mach bridge is too uncertain")
        uncertainty = mapping["bridge_drift_seconds"] / 2 + max(bridge["uncertainty_seconds"] for bridge in bridges)
        offset = mapping["python_to_mach_offset_seconds"]
        timebase = (bridges[0]["numer"], bridges[0]["denom"])
        proof, compact = _calibration(report["events"], timebase)
        windows = report.get("phase_windows")
        require(isinstance(windows, dict) and windows and len(windows) <= 8,
                "Thread CPU needs bounded authenticated runtime phase windows")
        left = min(_number(window.get("start_monotonic_seconds"), "phase start") for window in windows.values())
        right = max(_number(window.get("end_monotonic_seconds"), "phase end") for window in windows.values())
        require(bridges[0]["monotonic_seconds"] <= left < right <= bridges[1]["monotonic_seconds"],
                "Thread CPU phases are outside paired Mach bridges")
        rows, outside = [], []
        for index, sample in enumerate(samples):
            timestamp = converted[index]["monotonic_seconds"] - offset
            if left <= timestamp <= right:
                require(index >= ready["sample_index"] and index + 1 < len(samples)
                        and sample.get("phase") != "final", "Thread CPU interval includes startup or exited process samples")
                row = _row(sample, samples[index + 1], index, roles, compact, timebase,
                           (ready["process_id"], ready["birth_time_us"]))
                if rows:
                    previous = rows[-1]
                    require(previous["end"] <= row["begin"] and previous["process_after"] <= row["process_before"],
                            "Direct thread CPU read sequence or process counters moved backwards")
                    require(all(previous["roles"][role][key] <= row["roles"][role][key]
                                for role in ROLES for key in row["roles"][role]),
                            "Cumulative registered thread CPU counter moved backwards")
                rows.append(row)
            elif "thread_cpu" in sample and (not isinstance(sample["thread_cpu"], dict)
                                             or sample["thread_cpu"].get("available") is not True):
                outside.append({"sample_index": index, "reason": sample["thread_cpu"].get("reason")
                                if isinstance(sample["thread_cpu"], dict) else "Malformed group outside runtime"})
        require(rows, "No direct thread CPU readings cover the runtime")
        result.update(calibration=proof, registration=roles, outside_runtime_failures=outside,
                      rounding_allowance_ns=ROUNDING_NS, thread_counter_resolution_ns=THREAD_COUNTER_RESOLUTION_NS,
                      maximum_interval_uncertainty_cpu_percent=MAX_INTERVAL_UNCERTAINTY_PERCENT,
                      intervals={})
        for name, window in windows.items():
            result["intervals"][name] = _interval(rows, window, offset, uncertainty)
        return result | {"status": "available", "available": True}
    except (ValueError, KeyError, TypeError, OverflowError, StopIteration) as error:
        return result | {"status": "invalid", "available": False, "errors": [str(error)]}


def render_summary(analysis):
    """Compact review table; independent CPU target results remain elsewhere."""
    lines = ["", "Direct thread CPU accounting", "",
             "| Interval | Actual seconds | Main CPU | NIO CPU | Other process CPU | Process CPU |",
             "|---|---:|---:|---:|---:|---:|"]
    if not analysis.get("available"):
        reason = "; ".join(analysis.get("errors", [])) or analysis.get("reason", "Unavailable")
        return lines + [f"| {analysis.get('status', 'unavailable')} | — | — | — | — | — |", "", reason]
    def percentage(metrics):
        bounds = metrics["average_cpu_percent_bounds"]
        return f"{bounds['lower']:.3f}–{bounds['upper']:.3f}%"
    for name, interval in analysis["intervals"].items():
        elapsed = interval["actual_window"]["elapsed_seconds_bounds"]
        lines.append(f"| {name} | {elapsed['lower']:.4f}–{elapsed['upper']:.4f} | "
                     f"{percentage(interval['roles']['main'])} | {percentage(interval['roles']['nio'])} | "
                     f"{percentage(interval['residual'])} | {percentage(interval['process'])} |")
    return lines + ["", "Bounds retain sequential kernel-read uncertainty. Intervals use actual interior endpoints; "
                    "they do not attribute the exact rolling one-second peak. Main, NIO, and residual are disjoint. "
                    "Instrumentation is diagnostic and does not establish CPU acceptance."]
