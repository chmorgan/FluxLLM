# Automated performance regression checks

Run the actual Release application through a fixed synthetic workload:

```sh
python3 scripts/run_performance_checks.py check
```

The command builds the application, collector, and optimized tests; calibrates
measurement; launches an isolated backend and fresh application processes;
operates the native windows; applies HTTP streaming load; checks correctness;
and writes JSON/JUnit results. It requires no manual window interaction or trace
inspection. Build time is reported separately. The performance stage has a hard
300-second deadline, including calibration, fixture preparation, app startup and
shutdown, workload, and chart checks. Exceeding the deadline cannot pass.

## Fixed workload

| Fresh application process | Real-time sequence | Duration |
| --- | --- | ---: |
| Populated history, closed dashboard | Open/close dashboard; 35 s ordinary streaming; 35 s high-rate streaming; 5 s settled | 75 s |
| Populated history, visible dashboard | 15 s ordinary; 15 s high-rate; 15 s idle with three close/reopen cycles | 45 s |
| Fresh history, never opened | 10 s idle; 10 s ordinary; 10 s high-rate | 30 s |
| Logging transitions | Continuous ordinary streaming: 10 s off, 10 s on, 10 s off | 30 s |

The total real-time workload is 180 seconds. The remaining allowance covers
calibration, setup/ingestion, lifecycle acknowledgments, chart preparation, and
cleanup. This replaces the previous combinatorial matrix. Short deterministic
unit tests cover additional lifecycle, retention, correction, and failure cases;
the default performance gate does not require a long soak.

The external synthetic Ollama server reports a loaded model and implements the
monitoring endpoints. Two independent HTTP clients send chat requests through
FluxLLM's production proxy. Ordinary streams emit 40 fragments per second per
request; high-rate streams emit 200. No real model download or inference is
required. The fixture verifies exact forwarded content, progressive delivery,
tool calls/results, duplicate suppression, and final token corrections. The
runner also verifies source timing for both concurrent streams. Every fragment,
including the terminal record, must begin writing and finish flushing no more
than 50 ms after its absolute deadline; emissions more than 1 microsecond early
are invalid. First-flush times across streams and first-to-terminal durations
must agree with the schedule within 50 ms. This fixed allowance covers bounded
scheduler jitter and catch-up within two ordinary-rate or ten high-rate slots;
larger delays, stretches, or bursts invalidate the workload. The fixture retains
per-stream timing extrema, endpoint timestamps, counts, and bounded violation
details. The policy is versioned and does not adapt to a slow machine.

The populated fixture retains approximately 19,000 historical requests, 38,000
tool events, 7,201 raw samples per series, four older archive hours, and 256 recent
request lanes. Its identities, relative timestamps, and expected totals are
fixed. The app constructs retained session history through the ordinary in-memory
ingestion APIs. Construction and live ingestion count toward the app's measured
lifetime. No history files are created or restored. Pre-optimization baselines
retain their original persistence behavior and identify that implementation in
their source and binary hashes.

Native AppKit actions open, close, and restore the real windows at fixed sizes.
The runner verifies visibility and ongoing telemetry/rendering rather than
assuming that an action acknowledgment proves the complete UI workload ran.
A covered or missing visible window invalidates that scenario. A populated app
that cannot become ready within 20 seconds also fails setup; its resource samples
are retained, but the report does not claim the scheduled load completed.

## Measurements and limits

The checked-in policy is `scripts/performance_budget.json`.

| Measurement | Source and limit |
| --- | --- |
| CPU | Kernel cumulative user + system CPU time, sampled approximately every 250 ms. Every evaluated rolling one-second window must be at most **5% of one CPU core**. |
| Memory | Physical footprint plus the kernel lifetime high-water mark, strictly **less than 64,000,000 bytes**. Startup, history ingestion, and first dashboard opening count. |
| GPU | Calibrated process-owned GPU execution seconds / elapsed seconds, at most **1%**. This is not whole-device utilization or Activity Monitor Energy Impact. |
| Disk writes | Physical and logical write counters plus attributed filesystem traces. **Zero while logging is disabled**; enabled logging may write only its configured destination. |
| Chart preparation | Every measured fresh 256-lane full-hour publication must use at most **15 ms CPU**. Full-hour preparation must stay within **2×** equivalent aligned-minute preparation. |
| Hidden presentation | No new chart preparation or Canvas drawing while the corresponding surface is hidden. Monitoring and streaming continue. |

The collector starts observation before resuming the app and verifies PID plus
process birth identity. It preserves raw samples and obtains final process
accounting before reaping the child. CPU time units are calibrated against
`getrusage`; no processor-count division or observer-cost subtraction is used.
Missing samples, invalid intervals, changed identities, and incomplete final
accounting prevent a complete pass.

GPU calibration runs a controlled Metal helper with idle, active, and unrelated
process phases. The provider must respond to real GPU work and correctly support
explicit zero readings. Native self-task counters, when supported and validated,
are emitted over a dedicated pipe; that small read cost remains charged to the
app. An independently calibrated IOKit provider may be used where supported.
An absent process, field, or driver client is not an assumed zero. Provider and
coverage information are included in the report, including any final sample gap.
WindowServer activity is separate from process-owned GPU accounting.

GPU preflight reports live-counter calibration separately from full-lifetime
coverage. A calibrated live counter remains useful for diagnostics, but neither
current provider exposes validated finalized accounting for process exit and
outstanding GPU work. Therefore `full_lifetime_coverage` is false with code
`finalized_terminal_accounting_unsupported`, and the automated run cannot achieve
a complete pass. A final app self-sample or retained IOKit client is not treated
as proof of terminal coverage. Missing coverage is reported as incomplete; it is
never replaced with zero or an adjusted threshold.

Filesystem tracing uses noninteractive privileged `fs_usage` and an observed
proof write to establish readiness. It checks direct app writes and matching
isolated preference paths, including delegated writes. Unknown formats, dropped
records, ambiguous attribution, or unavailable authorization invalidate complete
write coverage. FluxLLM itself runs without elevated privileges. Logging
boundaries use acknowledged enable/disable transactions and the writer's drain
barrier; they do not grant a general exemption for unrelated writes.

## Baselines and comparison artifacts

Record the same workload before changing production behavior:

```sh
python3 scripts/run_performance_checks.py baseline
```

Reports default to unique timestamped directories under `.performance-results/`,
which is ignored by Git. Existing directories are never overwritten. Each run
preserves raw measurements, operation and fixture logs, correctness outcomes,
binary hashes, workload identity, machine/display configuration, and measurement
provider details. Keep both the failing baseline and subsequent checks.

Only compatible workload/environment/provider records should be compared.
Production binary hashes are expected to differ across optimizations. A baseline
is evidence, not a performance pass; neither recording nor comparing one changes
the checked-in limits. Report status distinguishes resource regressions from
invalid or incomplete measurements.

The original XCTest-host reproduction remains available through the legacy
`--command` runner interface for investigating prior results. Its CPU/memory
include XCTest overhead and its old phases exclude setup; it must not be compared
as if it measured the complete actual-app lifetime. Earlier reports are preserved
locally under `.performance-results/legacy-baseline-2026-09-29/` when available.

## Environment and CI

The full suite requires macOS, the Swift/Xcode toolchain, Python 3, and a usable
logged-in graphical session. It automatically checks GPU support and
noninteractive filesystem-tracing authorization. Missing capabilities return a
nonzero incomplete result while retaining the measurements that were available.
Do not run other build or benchmark workloads on the same machine concurrently.

`.github/workflows/performance.yml` invokes the same command on a GitHub-hosted
macOS runner and preserves artifacts even when limits or capabilities fail.
Manual dispatch can select an available Apple Silicon XLarge runner to evaluate
GPU support. Automated calibration and UI/tracing checks remain required;
hardware acceleration alone does not prove counter availability or resolve the
current terminal GPU coverage limitation. The workflow's job timeout also allows
for the separate build.

Normal Swift, Python, and release-script checks remain independent of the
five-minute performance stage. The fast Python harness checks run with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*performance*.py'
```

A short successful run establishes coverage of the fixed regression workload. It
does not establish absence of leaks that require hours to develop.
