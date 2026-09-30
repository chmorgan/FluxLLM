# Synthetic resource regression checks

These checks reproduce monitoring overhead before any optimization. They exercise
production FluxLLM components without loading a real model. Baseline collection is
**not a passing performance test**. Resource limits must be reviewed and frozen
after demonstrating the current problem, before changing production code.

## What runs

`ResourceUsageRegressionTests.testSyntheticAppResourceUsage` creates a production
proxy, HTTP backend client, monitoring coordinator, metrics store, menu-bar
controller, and retained SwiftUI hosts. It uses a unique defaults suite, ephemeral
loopback ports, and a temporary history directory. Discovery is restricted to the
fixture endpoint; the test does not reconfigure or send requests to an installed
Ollama or FluxLLM instance.

The external Python fixture is both the mock upstream and the streaming client.
Its CPU and memory are outside the measured test-host process. It verifies every
forwarded record, final counts, and progressive delivery at 25%, 50%, and 75% of
the stream. A first fragment followed by a buffered response cannot pass. The
Swift host also checks live token/TPS progress, overlapping requests, call/result
events, retained history sizes, and durable totals after reloading the files.

The matrix contains 18 cases:

| Dimension | Values |
| --- | --- |
| UI | `never-opened`, `visible`, `closed` |
| History | `fresh`, `populated` |
| Activity | `idle`, `ordinary`, `high-rate` |

`closed` opens and closes both the popover and dashboard before every cycle,
retaining the actual production hosts. `visible` exercises the popover and leaves
the dashboard visible. Visibility is checked throughout measurement; covering or
minimizing the dashboard invalidates a visible run. These cases require a logged-in
desktop. The test host runs the native AppKit application event loop and waits for
popover animation completion during setup. The native actions are invoked through
their existing Objective-C selectors; a renamed action or missing retained host
fails the fixture.

Ordinary and high-rate workloads contain two overlapping chat requests at 40 and
200 fragments/second **per request**, respectively. Each request includes one
submitted tool result, one response tool call, and a repeated terminal tool call
that must deduplicate. Final output tokens are `2 * floor(duration * rate) + 17`
per request; input tokens are 23. They deliberately differ from live estimates.

Populated history contains 19,000 completed requests and 38,000 tool events across
seven days, four older archive hours, and 7,201 raw half-second samples for each
series. The raw hour includes another 256 completed requests and 512 tool events.
The test verifies initial totals before measurement so losing history cannot
produce an apparently better performance result. Setup, restoration, UI
transitions, and forced final persistence are outside measured phases.

Each cycle has a workload phase (65 seconds by default) and a settled phase (10
seconds). Production 500 ms sampling, one-second backend/GPU polling, and normal
persistence timers run throughout. The 65-second phase crosses two archive-write
deadlines; the test does not force writes to imitate their timers. Three cycles
are the default and the minimum for the retained-growth gate. The full matrix is
at least 67.5 minutes plus setup; start with the reported closed-window case.
After all measured phases, files are reloaded **before** shutdown or a forced
flush. Completed request totals and tool results must already be durable after
the settled period. Idle cases do not require an unchanged usage file to be
rewritten. Each archived series must include measured samples newer than setup
and no older than the 30-second write cadence plus one 60-second bucket and five
seconds of scheduling slack. Seeded archive data cannot satisfy this check.
Final shutdown durability is checked separately after the explicit flush; these
reloads and their extra memory stay outside every measured phase.
Phases delayed more than five seconds past their requested duration are invalid.
This prevents a late final sample from diluting CPU or GPU cost with extra idle
time after the fixed workload has finished.

## Measurements and limits

| Measurement | Source and interpretation |
| --- | --- |
| CPU | Process user + system CPU seconds; gate the worst workload or settled phase as a percentage of wall time. Multicore use may exceed 100%. |
| Physical memory | `proc_pid_rusage` physical footprint, sampled about once per second; phase endpoints and sampled peak, augmented by any new kernel lifetime high-water mark. |
| Retained growth | Maximum increase from an earlier settled-phase minimum across repeated cycles. Absolute peak also has its own limit. |
| GPU | Process-owned IOKit GPU execution counters, restricted to the test host PID and birth identity. Execution seconds divided by wall time can exceed 100% across concurrent queues. |
| Writes/wakeups | Kernel cumulative physical/logical write and wakeup counters, reported as diagnostics. These are not counts of JSON saves or write syscalls. |

GPU execution time is **not** whole-device utilization, GPU occupancy, or energy.
The existing application System GPU chart cannot attribute cost to FluxLLM.
The probe uses driver-specific counters and must be validated against a process
trace on the target Mac/OS before a GPU budget can be accepted. Missing or unstable
counters remain unavailable. A required GPU gate fails if any measured phase is
unavailable; there is no zero or whole-system fallback. Rendering charged to
WindowServer is outside this process metric. Cross-check overall rendering and
energy with [Apple's Metal profiling tools](https://developer.apple.com/metal/tools/).

The observer runs inside the test host and contributes CPU/memory. Reports expose
its cumulative read-window CPU and elapsed time. Those windows also contain
concurrent app work, so their CPU must **not** be subtracted. Validate observer
overhead and compare matched runs using the same probe. The test host also has
XCTest/runtime overhead; this is a stable synthetic comparison, not an exact
measurement of the shipping application. Corroborate improvements in the app.

Sampled memory can miss a brief peak below the process's setup high-water mark.
The report preserves the kernel lifetime peak, which includes setup, separately.
Use an allocation/VM trace when investigating transient spikes. Retained caches
may be legitimate; freeze tolerances from repeated measurements instead of
requiring memory to return immediately to its launch value.

## Build and run

Build and run the Swift tests with the normal project workflow, then prepare a
release `.xctest` bundle for resource measurements. Pass its absolute path to the
runner, which does not build anything. Ordinary Swift test runs execute the small
chart correctness checks and skip both long performance entry points unless their
environment flags are set.

Prepare the optimized test bundle with testable imports enabled:

```sh
swift build -c release --build-tests -Xswiftc -enable-testing
```

After a release test bundle is available, start with the primary reproduction:

```sh
python3 scripts/run_performance_checks.py baseline \
  --case closed/populated/ordinary --repetitions 3 \
  --output-dir /tmp/fluxllm-performance-before \
  --command xcrun xctest \
  -XCTest FluxLLMTests.ResourceUsageRegressionTests/testSyntheticAppResourceUsage \
  /absolute/path/to/FluxLLMPackageTests.xctest
```

Use an absolute test-bundle path: the test command runs in its isolated artifact
directory. The output directory must be new/empty and outside the repository.
Omit `--case` to run all 18 cases; repeat it to select several. `--cycles` defaults
to 3; `--duration` supports 65–600 seconds; `--settle` supports 5–120 seconds.
Longer runs, more cycles (up to 20), and repetitions can investigate slow growth.
A one-cycle baseline is allowed for diagnostics but cannot establish a memory
growth pass. Do not run other test suites concurrently with these measurements.

Use the same Mac, OS, display resolution/scaling/refresh, and release configuration
for comparisons. Keep other GPU-heavy applications quiet and the visible dashboard
unobscured. The runner preserves `report.json`, per-run `result.json`, scenarios,
fixture logs, and test logs. It terminates both process groups on completion,
failure, timeout, or interruption. The default timeout includes 120 seconds for
setup; raise `--timeout` if initial fixture preparation needs more time.

## Freeze a failing budget before optimization

1. Inspect baseline correctness and repeated measurements. Confirm the synthetic
   profile reproduces the costly production paths. A failed setup or unavailable
   counter is not proof of the energy issue.
2. Choose explicit limits for CPU percentage, absolute peak footprint, retained
   growth, and GPU execution percentage. Demonstrate the relevant current metrics
   exceed those limits. Record the GPU attribution trace/evidence.
3. Save the reviewed budget. Copy the exact `environment` and `scenario` objects
   from the report. The runner includes a SHA256 of the workload/measurement
   sources in the environment; changing those files invalidates a frozen budget.
   Production source is deliberately excluded so optimizations can be compared.
4. Run `check` with that budget on the unchanged implementation to establish the
   failing resource test, then use the same budget and workload after fixes.

Budget structure (placeholders are intentionally not executable limits):

```text
{
  "schema_version": 1,
  "environment": <exact environment object from the release baseline report>,
  "gpu_attribution": {
    "method": <same value as environment.gpu_method>,
    "evidence": <description/path of reviewed process attribution trace>
  },
  "cases": {
    "closed/populated/ordinary": {
      "scenario": <exact scenario object from the report>,
      "limits": {
        "cpu_percent": <reviewed numeric limit>,
        "peak_footprint_bytes": <reviewed integer limit>,
        "retained_growth_bytes": <reviewed integer limit>,
        "gpu_percent": <reviewed numeric limit>
      }
    }
  }
}
```

Then replace `baseline` with `check --budget /absolute/path/to/budget.json` in the
run command and choose a different artifact directory. Check mode rejects missing
budgets, debug configurations, incompatible environments/workloads, insufficient
cycles, incomplete correctness manifests, and unavailable required metrics. Each
repetition must pass; results are not averaged to hide a failed run. Baseline mode
never creates limits automatically and never reports a regression pass.

The workload fingerprint describes the source files supplied to the runner. Build
the tests again after changing them; it cannot prove a stale bundle includes those
sources. The report records the test bundle path and a diagnostic launcher hash
(often `xcrun`), not a claimed identity of the linked production binary.

## Focused chart reproduction

`ChartPreparationPerformanceTests` includes ordinary correctness tests for fresh
publications, cache reuse, missing observations, and whole-bucket boundaries.
Its opt-in benchmark prepares 30 fresh publications for 1, 33, and 256 request
lanes, comparing full-hour raw history against equivalent visible-minute input.
The shorter input includes complete left-edge bucket contributors (121–125
points), preventing different output from being mistaken for an optimization.

```sh
FLUXLLM_PERF_CHART=1 FLUXLLM_PERF_CHART_RESULT=/tmp/fluxllm-chart-before.json \
  xcrun xctest \
  -XCTest FluxLLMTests.ChartPreparationPerformanceTests/testFreshChartPublicationsReportCPUAndWallCost \
  /absolute/path/to/FluxLLMPackageTests.xctest
```

The JSON includes per-publication CPU/wall time, actual input counts, output
checksums, and correctness results. It is explicitly unbudgeted characterization,
used to explain resource failures; the whole-app resource runner is the gate.

Python harness checks (no Swift build):

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_performance_*.py'
```

These tests verify the fixture, progressive forwarding checks, budget validation,
and runner isolation/cleanup. CI includes them in its Python test job. Passing
them does not establish a FluxLLM resource baseline. Keep production optimization
blocked until the Swift reproducer has run and the current failure has been
demonstrated.
