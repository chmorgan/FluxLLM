#!/usr/bin/env python3
"""Run prebuilt FluxLLM resource tests in isolated processes; never build the app.

Baseline mode records evidence, not a passing regression result. Check mode
requires a separately reviewed budget for the exact environment and workload.
Use absolute paths for command arguments: each child runs in its own directory.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlparse


SCHEMA_VERSION = 1
UIS = ("never-opened", "visible", "closed")
HISTORIES = ("fresh", "populated")
ACTIVITIES = ("idle", "ordinary", "high-rate")
ENVIRONMENT_FIELDS = ("os", "hardware", "build_configuration", "display", "gpu_method", "fixture_sha256")
LIMIT_FIELDS = ("cpu_percent", "peak_footprint_bytes", "retained_growth_bytes", "gpu_percent")
MAX_PHASE_OVERRUN_SECONDS = 5
REPO_ROOT = Path(__file__).resolve().parent.parent
WORKLOAD_SOURCES = (
    "scripts/performance_fixture.py",
    "Tests/FluxLLMTests/ResourceUsageRegressionTests.swift",
    "Tests/FluxLLMTests/Fixtures/ResourceHistoryFixture.swift",
    "Tests/FluxLLMTests/Fixtures/ProcessResourceProbe.swift",
    "Sources/FluxLLMPerformanceSupport/PerformanceHistoryFixture.swift",
)


class InvalidResult(ValueError):
    """An input cannot safely be used as performance evidence."""


def require(condition, message):
    if not condition:
        raise InvalidResult(message)


def number(value, label, minimum=0, integer=False, maximum=None):
    require(type(value) in (int, float) and math.isfinite(value), f"{label} must be a finite number")
    require(value >= minimum, f"{label} must be >= {minimum}")
    if maximum is not None:
        require(value <= maximum, f"{label} must be <= {maximum}")
    if integer:
        require(type(value) is int, f"{label} must be an integer")
    return value


def workload_fingerprint(root=REPO_ROOT):
    """Identify fixture/probe sources, while allowing production optimization."""
    digest = hashlib.sha256()
    for relative_path in WORKLOAD_SOURCES:
        digest.update(relative_path.encode("utf-8"))
        digest.update(b"\0")
        digest.update((root / relative_path).read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def load_json(path):
    # The default JSON reader accepts NaN and duplicate keys. Both hide mistakes.
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"Duplicate JSON key: {key}")
            result[key] = value
        return result

    def constant(value):
        raise InvalidResult(f"Invalid JSON number: {value}")

    with Path(path).open(encoding="utf-8") as source:
        return json.load(source, object_pairs_hook=pairs, parse_constant=constant)


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def case_key(scenario):
    return "/".join(scenario[field] for field in ("ui", "history", "activity"))


def validate_scenario(scenario):
    require(isinstance(scenario, dict), "scenario must be an object")
    required = {"ui", "history", "activity", "duration_seconds", "cycles", "settle_seconds"}
    require(set(scenario) == required, f"scenario must contain exactly {sorted(required)}")
    for field, choices in (("ui", UIS), ("history", HISTORIES), ("activity", ACTIVITIES)):
        require(scenario[field] in choices, f"scenario.{field} must be one of {choices}")
    number(scenario["duration_seconds"], "scenario.duration_seconds", minimum=65, maximum=600)
    number(scenario["cycles"], "scenario.cycles", minimum=1, maximum=20, integer=True)
    number(scenario["settle_seconds"], "scenario.settle_seconds", minimum=5, maximum=120)
    return scenario


def validate_environment(environment):
    require(isinstance(environment, dict), "environment must be an object")
    for field in ENVIRONMENT_FIELDS:
        require(isinstance(environment.get(field), str) and environment[field].strip(),
                f"environment.{field} must be a nonempty string")
    require(re.fullmatch(r"[0-9a-f]{64}", environment["fixture_sha256"]) is not None,
            "environment.fixture_sha256 must be a lowercase 64-digit SHA256")
    return environment


def validate_result(result, expected_scenario):
    require(isinstance(result, dict), "result must be an object")
    require(type(result.get("schema_version")) is int and result["schema_version"] == SCHEMA_VERSION,
            "Unsupported result schema_version")
    scenario = validate_scenario(result.get("scenario"))
    require(scenario == expected_scenario, "Result scenario differs from requested scenario")
    validate_environment(result.get("environment"))
    validation = result.get("validation")
    require(isinstance(validation, dict) and validation.get("passed") is True,
            "Workload correctness validation did not pass")
    requests = 0 if scenario["activity"] == "idle" else 2 * scenario["cycles"]
    rate = 40 if scenario["activity"] == "ordinary" else 200
    expected = {"requests": requests, "tool_calls": requests, "tool_results": requests,
                "chunks": requests * math.floor(scenario["duration_seconds"] * rate)}
    for field, count in expected.items():
        number(validation.get(field), f"validation.{field}", integer=True)
        require(validation[field] == count, f"validation.{field} must equal the expected workload count {count}")
    for field in ("session_history_verified", "history_files_absent"):
        require(validation.get(field) is True, f"validation.{field} must verify the in-memory history policy")
    phases = result.get("phases")
    require(isinstance(phases, list), "phases must be an array")
    expected_phases = [(name, cycle) for cycle in range(1, scenario["cycles"] + 1)
                       for name in ("workload", "settled")]
    require(len(phases) == len(expected_phases), "Expected workload and settled phases for every cycle")
    for index, (phase, expected) in enumerate(zip(phases, expected_phases)):
        label = f"phases[{index}]"
        require(isinstance(phase, dict), f"{label} must be an object")
        require(type(phase.get("cycle")) is int and (phase.get("name"), phase["cycle"]) == expected,
                f"{label} expected {expected[0]} cycle {expected[1]}")
        elapsed = number(phase.get("elapsed_seconds"), f"{label}.elapsed_seconds", minimum=0.001)
        minimum = scenario["duration_seconds"] if expected[0] == "workload" else scenario["settle_seconds"]
        require(elapsed >= minimum - 0.25, f"{label} is shorter than the requested measurement period")
        require(elapsed <= minimum + MAX_PHASE_OVERRUN_SECONDS,
                f"{label} exceeded the requested measurement period by more than {MAX_PHASE_OVERRUN_SECONDS} seconds")
        number(phase.get("cpu_seconds"), f"{label}.cpu_seconds")
        for field in ("physical_footprint_start_bytes", "physical_footprint_end_bytes", "physical_footprint_peak_bytes"):
            number(phase.get(field), f"{label}.{field}", minimum=1, integer=True)
        require(phase["physical_footprint_peak_bytes"] >= max(phase["physical_footprint_start_bytes"], phase["physical_footprint_end_bytes"]),
                f"{label} peak footprint is smaller than a phase endpoint")
        require("gpu_seconds" in phase, f"{label}.gpu_seconds is missing")
        if phase["gpu_seconds"] is None:
            require(isinstance(phase.get("gpu_unavailable_reason"), str) and phase["gpu_unavailable_reason"].strip(),
                    f"{label} must explain unavailable GPU measurement")
        else:
            number(phase["gpu_seconds"], f"{label}.gpu_seconds")
            require(phase.get("gpu_unavailable_reason") is None,
                    f"{label} has both GPU data and an unavailable reason")
        for field in ("disk_write_bytes", "interrupt_wakeups"):
            require(field in phase, f"{label}.{field} is missing (use null when unavailable)")
            if phase[field] is not None:
                number(phase[field], f"{label}.{field}", integer=True)
        for field in ("observer_cpu_seconds", "observer_elapsed_seconds"):
            if field in phase:
                number(phase[field], f"{label}.{field}")
    return result


def derive_metrics(result):
    phases = result["phases"]
    settled = [phase for phase in phases if phase["name"] == "settled"]
    gpu_available = all(phase["gpu_seconds"] is not None for phase in phases)
    retained_growth = None
    if len(settled) >= 3:
        minimum = settled[0]["physical_footprint_end_bytes"]
        retained_growth = 0
        for phase in settled[1:]:
            footprint = phase["physical_footprint_end_bytes"]
            retained_growth = max(retained_growth, footprint - minimum)
            minimum = min(minimum, footprint)
    return {
        # Gate the worst complete phase, including post-generation work.
        "cpu_percent": max(100 * phase["cpu_seconds"] / phase["elapsed_seconds"] for phase in phases),
        "peak_footprint_bytes": max(phase["physical_footprint_peak_bytes"] for phase in phases),
        "retained_growth_bytes": retained_growth,
        "gpu_percent": max(100 * phase["gpu_seconds"] / phase["elapsed_seconds"] for phase in phases) if gpu_available else None,
        "cpu_seconds": sum(phase["cpu_seconds"] for phase in phases),
        "disk_write_bytes": sum(phase["disk_write_bytes"] for phase in phases) if all(phase["disk_write_bytes"] is not None for phase in phases) else None,
        "interrupt_wakeups": sum(phase["interrupt_wakeups"] for phase in phases) if all(phase["interrupt_wakeups"] is not None for phase in phases) else None,
        "gpu_unavailable_reasons": sorted({phase["gpu_unavailable_reason"] for phase in phases if phase["gpu_seconds"] is None}),
    }


def validate_budget(budget):
    require(isinstance(budget, dict), "budget must be an object")
    require(type(budget.get("schema_version")) is int and budget["schema_version"] == SCHEMA_VERSION,
            "Unsupported budget schema_version")
    validate_environment(budget.get("environment"))
    require(budget["environment"]["build_configuration"] == "release",
            "Frozen resource budgets require a release build")
    attribution = budget.get("gpu_attribution")
    require(isinstance(attribution, dict), "budget.gpu_attribution must document reviewed attribution evidence")
    for field in ("method", "evidence"):
        require(isinstance(attribution.get(field), str) and attribution[field].strip(),
                f"budget.gpu_attribution.{field} must be a nonempty string")
    require(attribution["method"] == budget["environment"]["gpu_method"],
            "GPU attribution method differs from budget environment.gpu_method")
    require(isinstance(budget.get("cases"), dict) and budget["cases"], "budget.cases must be a nonempty object")
    for key, entry in budget["cases"].items():
        require(isinstance(entry, dict), f"Budget case {key} must be an object")
        scenario = validate_scenario(entry.get("scenario"))
        require(scenario["cycles"] >= 3, f"Budget case {key} requires at least three cycles for retained memory growth")
        require(key == case_key(scenario), f"Budget case {key} does not match its scenario")
        limits = entry.get("limits")
        require(isinstance(limits, dict) and set(limits) == set(LIMIT_FIELDS),
                f"Budget case {key} requires exactly these limits: {', '.join(LIMIT_FIELDS)}")
        for field, value in limits.items():
            number(value, f"Budget {key}.{field}", integer=field.endswith("_bytes"))
    return budget


def check_result(result, budget):
    failures = []
    if result["environment"] != budget["environment"]:
        failures.append("Environment differs from the frozen budget")
    entry = budget["cases"].get(case_key(result["scenario"]))
    if entry is None:
        return failures + ["No budget exists for this case"]
    if entry["scenario"] != result["scenario"]:
        failures.append("Scenario differs from the frozen budget")
    metrics = derive_metrics(result)
    for metric, limit in entry["limits"].items():
        value = metrics[metric]
        if value is None:
            reason = "; ".join(metrics["gpu_unavailable_reasons"]) if metric == "gpu_percent" else "at least three cycles are required"
            failures.append(f"Required measurement {metric} is unavailable: {reason}")
        elif value > limit:
            failures.append(f"{metric}: measured {value:g}, exceeds limit {limit:g}")
    return failures


def stop_process_group(process, grace=2):
    """Reap the child and terminate descendants even if their parent has exited."""
    def signal_group(signum):
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass
        except PermissionError as error:
            # macOS sandboxing can report EPERM, rather than ESRCH, after
            # an exiting process group disappears. Allow the short kernel
            # transition to a reapable child before interpreting it as denial.
            if process.poll() is None:
                try:
                    process.wait(timeout=0.05)
                except subprocess.TimeoutExpired:
                    raise error from None

    if os.name == "posix":
        signal_group(signal.SIGTERM)
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
        signal_group(signal.SIGKILL)
    else:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            process.kill()
    process.wait()


def launch_fixture(directory, command=None, timeout=10):
    command = command or [sys.executable, str(Path(__file__).resolve().with_name("performance_fixture.py")), "--port", "0"]
    log_path = directory / "fixture.log"
    with log_path.open("wb") as log:
        process = subprocess.Popen(command, cwd=directory, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True)
    try:
        deadline = time.monotonic() + timeout
        line = b""
        with log_path.open("rb") as log:
            while b"\n" not in line:
                line += log.read(65536)
                require(len(line) <= 65536, "Fixture readiness line exceeded 64 KiB")
                if b"\n" in line:
                    break
                require(process.poll() is None, "Fixture exited before announcing readiness; see fixture.log")
                require(time.monotonic() < deadline, "Fixture readiness timed out; see fixture.log")
                time.sleep(0.02)
        try:
            ready = json.loads(line.split(b"\n", 1)[0])
        except ValueError as error:
            raise InvalidResult(f"Invalid fixture readiness JSON: {error}") from error
        require(isinstance(ready, dict) and isinstance(ready.get("base_url"), str),
                "Fixture must announce JSON with a base_url")
        url = urlparse(ready["base_url"])
        require(url.scheme == "http" and url.hostname in ("127.0.0.1", "localhost", "::1") and url.port,
                "Fixture base_url must use a loopback HTTP address")
        return process, ready["base_url"]
    except BaseException:
        stop_process_group(process)
        raise


def execute_case(command, scenario, directory, timeout, fixture_command=None, fixture_sha256=None):
    directory = directory.resolve()
    directory.mkdir(parents=True, exist_ok=False)
    result_path = directory / "result.json"
    environment = os.environ.copy()
    environment.update({
        "FLUXLLM_PERF_ENABLED": "1",
        "FLUXLLM_PERF_SCENARIO": json.dumps(scenario, separators=(",", ":")),
        "FLUXLLM_PERF_RESULT": str(result_path),
        "FLUXLLM_PERF_TMPDIR": str(directory),
    })
    write_json(directory / "scenario.json", scenario)
    run = {"directory": str(directory), "command": command, "failures": []}
    fixture, upstream = launch_fixture(directory, fixture_command)
    environment["FLUXLLM_PERF_UPSTREAM"] = upstream
    try:
        with (directory / "process.log").open("wb") as log:
            process = subprocess.Popen(command, cwd=directory, env=environment,
                                       stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                run["exit_code"] = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                run["failures"].append(f"Command timed out after {timeout:g} seconds")
                run["exit_code"] = None
            finally:
                stop_process_group(process)
        if fixture.poll() is not None:
            run["failures"].append("Synthetic backend exited during measurement; see fixture.log")
    finally:
        stop_process_group(fixture)
    if run["exit_code"] != 0:
        run["failures"].append(f"Command did not exit successfully: {run['exit_code']}")
    try:
        result = load_json(result_path)
        require(isinstance(result, dict) and isinstance(result.get("environment"), dict),
                "Result must include an environment object")
        # Identity comes from the runner's sources, never a child-supplied claim.
        result["environment"]["fixture_sha256"] = fixture_sha256 or workload_fingerprint()
        result = validate_result(result, scenario)
        run["result"] = result
        run["metrics"] = derive_metrics(result)
    except (OSError, ValueError) as error:
        run["failures"].append(f"Invalid measurement result: {error}")
    return run


def parse_case(value):
    parts = value.split("/")
    if len(parts) != 3 or parts[0] not in UIS or parts[1] not in HISTORIES or parts[2] not in ACTIVITIES:
        raise argparse.ArgumentTypeError("case must be UI/HISTORY/ACTIVITY, e.g. closed/populated/ordinary")
    return tuple(parts)


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("baseline", "check"))
    parser.add_argument("--case", type=parse_case, action="append", help="Repeat to select cases; default is all 18")
    parser.add_argument("--duration", type=float, default=65, help="Measured workload seconds per cycle (minimum 65)")
    parser.add_argument("--cycles", type=int, default=3, help="Cycles per process; memory growth checks need at least three")
    parser.add_argument("--settle", type=float, default=10, help="Measured settling seconds per cycle (minimum 5)")
    parser.add_argument("--repetitions", type=int, default=1, help="Fresh process repetitions for every case")
    parser.add_argument("--timeout", type=float, help="Per-process timeout; default workload + settle + 120 seconds")
    parser.add_argument("--output-dir", type=Path, help="New/empty artifact directory outside the repository; default is a temporary directory")
    parser.add_argument("--budget", type=Path, help="Reviewed budget JSON (required in check mode)")
    parser.add_argument("--command", nargs=argparse.REMAINDER, required=True,
                        help="Prebuilt executable and arguments; executed directly without a shell")
    args = parser.parse_args(argv)
    try:
        number(args.duration, "--duration", minimum=65, maximum=600)
        number(args.cycles, "--cycles", minimum=1, maximum=20, integer=True)
        number(args.settle, "--settle", minimum=5, maximum=120)
        number(args.repetitions, "--repetitions", minimum=1, integer=True)
        if args.timeout is not None:
            number(args.timeout, "--timeout", minimum=0.001)
        require(bool(args.command), "--command requires a prebuilt executable")
        require((args.mode == "check") == (args.budget is not None), "Supply --budget only in check mode; it is required there")
    except InvalidResult as error:
        parser.error(str(error))
    return args


def legacy_main(argv=None):
    args = arguments(argv)
    report = None
    output = None
    try:
        budget = validate_budget(load_json(args.budget)) if args.budget else None
        fixture_sha256 = workload_fingerprint()
        if budget:
            require(budget["environment"]["fixture_sha256"] == fixture_sha256,
                    "Fixture/probe sources differ from the frozen budget fixture_sha256")
        cases = list(dict.fromkeys(args.case or itertools.product(UIS, HISTORIES, ACTIVITIES)))
        scenarios = [{"ui": ui, "history": history, "activity": activity,
                      "duration_seconds": args.duration, "cycles": args.cycles,
                      "settle_seconds": args.settle} for ui, history, activity in cases]
        if budget:
            for scenario in scenarios:
                entry = budget["cases"].get(case_key(scenario))
                require(entry is not None, f"No frozen budget for {case_key(scenario)}")
                require(entry["scenario"] == scenario, f"Scenario differs from frozen budget: {case_key(scenario)}")
            require(args.cycles >= 3, "Check mode requires at least three cycles for retained memory growth")
        executable = shutil.which(args.command[0])
        require(executable is not None, f"Executable not found: {args.command[0]}")
        command = [str(Path(executable).resolve()), *args.command[1:]]
        output = args.output_dir.expanduser().resolve() if args.output_dir else Path(tempfile.mkdtemp(prefix="fluxllm-performance-"))
        require(output != REPO_ROOT and REPO_ROOT not in output.parents, "Artifacts must be outside the repository")
        require(not output.exists() or (output.is_dir() and not any(output.iterdir())), "Output directory must be new or empty")
        output.mkdir(parents=True, exist_ok=True)
        report = {"schema_version": SCHEMA_VERSION, "mode": args.mode,
                  "created_at": datetime.now(timezone.utc).isoformat(),
                  "status": "running", "regression_passed": None,
                  "command": command,
                  "diagnostic_launcher_sha256": hashlib.sha256(Path(command[0]).read_bytes()).hexdigest(),
                  "workload_identity": {"fixture_sha256": fixture_sha256, "sources": list(WORKLOAD_SOURCES),
                                        "algorithm": "SHA256 of each relative path (UTF-8), NUL, contents, NUL, in listed order"},
                  "budget": budget, "cases": {}, "failures": []}
        print(f"Artifacts: {output}", flush=True)
        environment = None
        timeout = args.timeout or args.cycles * (args.duration + args.settle) + 120
        for scenario in scenarios:
            key = case_key(scenario)
            runs = report["cases"].setdefault(key, {"scenario": scenario, "runs": []})["runs"]
            for repetition in range(1, args.repetitions + 1):
                print(f"{args.mode}: {key} repetition {repetition}/{args.repetitions}", flush=True)
                directory = output / key.replace("/", "--") / f"run-{repetition:02d}"
                run = execute_case(command, scenario, directory, timeout, fixture_sha256=fixture_sha256)
                runs.append(run)
                if "result" in run:
                    current_environment = run["result"]["environment"]
                    if environment is None:
                        environment = current_environment
                        report["environment"] = environment
                    elif current_environment != environment:
                        run["failures"].append("Environment changed between runs")
                    if budget:
                        run["failures"].extend(check_result(run["result"], budget))
                for failure in run["failures"]:
                    report["failures"].append(f"{key} repetition {repetition}: {failure}")
                    print(f"  FAILED: {failure}", flush=True)
                write_json(output / "report.json", report)
        failed = bool(report["failures"])
        report["status"] = "failed" if failed else ("passed" if budget else "baseline_recorded")
        report["regression_passed"] = not failed if budget else None
        write_json(output / "report.json", report)
        if not failed and not budget:
            print("Baseline recorded only. No resource budget was checked; this is NOT a regression pass.")
        else:
            print("Resource checks passed." if not failed else "Performance run failed; see report.json and process logs.")
        return 1 if failed else 0
    except (OSError, ValueError, KeyboardInterrupt) as error:
        if report is not None:
            report["status"] = "interrupted" if isinstance(error, KeyboardInterrupt) else "failed"
            report["regression_passed"] = False if args.mode == "check" else None
            report["failures"].append(str(error) or "Interrupted")
            write_json(output / "report.json", report)
        print(f"Performance run could not complete: {error or 'Interrupted'}", file=sys.stderr)
        return 130 if isinstance(error, KeyboardInterrupt) else 1


def interrupted(_signal, _frame):
    raise KeyboardInterrupt


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv and argv[0] == "gpu-compare":
        from runtime_gpu_comparison import run
        return run(argv[1:])
    if argv and argv[0] == "arrivals":
        from arrival_replay import run
        return run(argv[1:])
    if argv and argv[0] == "runtime":
        from runtime_attribution import run
        return run(argv[1:])
    if argv and argv[0] == "drawing":
        from drawing_attribution import run
        return run(argv[1:])
    if argv and argv[0] == "memory":
        from memory_attribution import run
        return run(argv[1:])
    if "--command" in argv:
        return legacy_main(argv)
    from app_performance import run
    return run(argv)


if __name__ == "__main__":
    # Let the same cleanup path handle a controller terminating this runner.
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
