# Automated performance regression checks

Run the actual Release application through a fixed synthetic workload:

```sh
python3 scripts/run_performance_checks.py check
```

The command builds the application, collector, and optimized tests; calibrates
measurement; launches an isolated backend and fresh application processes;
operates the native windows; applies HTTP streaming load; checks correctness;
and writes JSON/JUnit results. It requires no manual window interaction or trace
inspection. The default GPU provider is a bounded coarse `powermetrics` capability
probe; process GPU decoding and calibration are not yet validated, so it currently
reports incomplete GPU coverage while retaining CPU, memory, and I/O results. It
does not silently fall back to a heavy Metal recording. Build time is reported separately. The performance stage has a hard
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
fixed. The common version-2 fixture restores the same retained raw state through
a measurement-only bulk initialization seam. This avoids replaying an artificial
hour of historical publications before the workload. Construction, production
history loading, first publication, and live ingestion remain inside the app's
measured lifetime. Fresh and populated equivalence manifests verify the actual
samples, lanes, tool events, hourly totals, and archive observations. Current
code uses session memory; reconstructed pre-optimization code retains its
original history files and persistence behavior. Adapter hashes are recorded
separately from the common measurement policy.

Native AppKit actions open, close, and restore the real windows at fixed sizes.
Both measured variants declare the performance-only policy
`popover_lifecycle_policy: explicit-performance-commands-v2`. Under this policy,
explicit harness show/close commands control the native popover's lifetime;
incidental desktop focus changes cannot dismiss a requested visible interval.
The harness first waits for native activation, a ready status-item anchor, and
the previous popover's native `didClose` callback, then makes one show attempt.
Readiness and resulting visibility share a single
four-second deadline. Failures preserve the actual before/final readiness
state, mark UI coverage incomplete, and allow the remaining resource workload
to continue. Transport and unrelated protocol failures still invalidate the case.
Normal application launches retain transient popover behavior. Native hosting,
rendering, visibility checks, and presentation demand use their ordinary paths.
Ready events, every snapshot, binary provenance, and comparison identity must
agree on this policy. The runner verifies visibility and ongoing telemetry/rendering
rather than assuming an action acknowledgment proves the complete UI workload ran.
A covered or missing visible window invalidates that scenario. A populated app
that cannot become ready within 20 seconds also fails setup; its resource samples
are retained, but the report does not claim the scheduled load completed.

## Runtime work covered by the regression suite

Backend polling reuses a client-owned ephemeral HTTP session. Each request keeps
its own response limit, cancellation, and completion state. GPU polling reads
only the device's `PerformanceStatistics` property at the existing cadence.

Stream framing scans incoming bytes incrementally and decodes each JSON record
once. Token and tool accounting borrow the same Foundation dictionaries without
converting the whole record into Swift dictionaries. The proxy forwards bytes immediately. Ordinary accounting snapshots are
constructed at most every 50 ms per request, with one scheduled quiet-tail flush;
first output, tools, and terminal outcomes bypass that delay. The shared UI inbox
still coalesces ordinary updates, so those updates can take up to 100 ms across
both stages. Their timestamps remain the original record-receipt timestamps.

Visible chart consumers request their actual live or pinned intervals. Raw
queries retain complete averaging bins and predecessor observations, and request
queries use the completed-time index plus active requests. Geometry caches hold
one publication at one size and scale. Scalar readings update separately from
chart preparation. Activity indicators publish only when request membership or
output availability changes; raw token accounting continues at its normal cadence.
The retained tool-owner query advances its cached interval boundaries instead of
rescanning the retained day on every chart publication. Insertions and pruning
invalidate that bounded cache. Rail decoration ticks do not rebuild the static bars and
pause between visible effects; hidden surfaces release their hosts and caches.
Explicit dashboard opening attaches its host before ordering the native window
front. This avoids the large first-use allocation and writes reproduced when a
host is inserted into an already visible empty window. Native visibility still
controls host release after an unsuccessful presentation or later occlusion.
Chart canvases render their existing drawing operations through `ImageRenderer`
into an AppKit Core Graphics context. Each native view creates its renderer on
first drawing and releases it with the view's content. Isolated renderer probes
motivate this path; complete application measurements still enforce CPU, memory,
and write budgets across first window opening and subsequent UI rendering.

## Measurements and limits

The checked-in policy is `scripts/performance_budget.json`.

| Measurement | Source and limit |
| --- | --- |
| CPU | Kernel cumulative user + system CPU time, sampled approximately every 250 ms. **Startup ≤50% of one CPU core until ready; normal operation ≤5% afterward.** Phase windows exclude CPU work from the other phase. |
| Memory | Physical footprint plus the kernel lifetime high-water mark, strictly **less than 64,000,000 bytes**. Startup, history ingestion, and first dashboard opening count. |
| GPU | Calibrated process-owned GPU execution seconds / elapsed seconds, at most **1%**. This is not whole-device utilization or Activity Monitor Energy Impact. |
| Disk writes | Physical and logical write counters plus attributed filesystem traces. **Zero while logging is disabled**; enabled logging may write only its configured destination. |
| Chart preparation | Every measured fresh 256-lane full-hour publication must use at most **15 ms CPU**. Full-hour preparation must stay within **2×** equivalent aligned-minute preparation. |
| Hidden presentation | No new chart preparation or Canvas drawing while the corresponding surface is hidden. Monitoring and streaming continue. |

The collector starts observation before resuming the app and verifies PID plus
process birth identity. It preserves raw samples and obtains final process
accounting before reaping the child. CPU time units are calibrated against
`getrusage`; no processor-count division or observer-cost subtraction is used.
The ready acknowledgment has a paired resource sample that ends startup and
starts normal operation without an unmeasured gap. CPU windows are evaluated
within their own phase; short phases and boundary portions remain measured using
their actual elapsed duration. Readiness cannot be delayed to exempt later
normal workload, and failed or missing readiness leaves phase coverage incomplete.
Missing samples, invalid intervals, changed identities, and incomplete final
accounting prevent a complete pass. A transient current-footprint reading above
its paired lifetime peak is retained as an anomaly. It is resolved only when the
authenticated final kernel peak covers every earlier current/peak reading and
all raw peaks remain nondecreasing. Missing final evidence, malformed values,
and counter regressions leave memory coverage incomplete; the runner never
constructs a replacement peak from current readings.

The default `powermetrics` adapter requests one self-limiting 250 ms sample of
`tasks` with `--show-process-gpu`, sample-normalized output and plist formatting.
It runs directly when already privileged, otherwise through `sudo -n`; it never
prompts for credentials. Its probe is bounded to three seconds and the overall
performance deadline. Raw output, stderr, launch status and timing metadata are
saved under `gpu-sampling/`. The measured FluxLLM process is never launched as
root. No password is stored and no persistent sudo rule is installed.

**Current limitation:** secure administrator probes have not yet produced observed
plist data on the reference host. Consequently, the adapter has no validated
schema decoder, GPU unit conversion, or process/exit calibration. Even successful
probe output does not become a GPU value. GPU bounds remain null, not zero, and
the full gate remains incomplete. A separately and explicitly authorized secure
macOS prompt can obtain diagnostic data; it is not opened by unattended tests.
A denied or unavailable authorization does not discard independently valid CPU,
memory, or physical/logical write counters.

Before enabling coarse GPU measurements, validate the real output against idle,
busy and unrelated-process Metal controls, then verify PID plus process birth,
counter units, timestamp alignment, sampling gaps and process termination.
The provider must establish whether first/last records include startup and queued
work after exit. Workload-window measurements and final lifecycle coverage remain
separate; absence of a process row cannot silently mean zero activity. The 1%
limit remains unchanged, and the report must identify sampling uncertainty rather
than presenting an unvalidated device counter as process utilization.

The detailed Instruments provider remains an explicit diagnostic option:

```sh
python3 scripts/run_performance_checks.py check --gpu-provider instruments
```

It records process-attributed GPU execution using the minimal Blank+GPU template
and an owned inert sentinel, calibrated with two separate Metal helpers. Its
maximum rolling one-second execution upper bound includes unresolved recorded
intervals; loss, malformed events, ambiguous identity, or incomplete terminal
accounting cannot pass. Full-length captures on the reference host have exceeded
the 300-second deadline while stopping/saving, so this is not the default or an
automatic fallback. WindowServer and device-wide utilization are never substituted
for FluxLLM's own GPU consumption. Compare only results with the same validated
provider and metric semantics.

Filesystem evidence comes from a separate bounded `fs_usage` observer for each
app process, with proof writes before launch and after exit/drain. It checks
direct app writes and isolated preference paths, including delegated writes.
The observer runs directly when already privileged, otherwise through
`sudo -n /usr/bin/fs_usage`; noninteractive authorization must already exist.
Missing authorization leaves write coverage incomplete while preserving
independently valid CPU, memory, and GPU evidence. Unknown formats, dropped
records, and ambiguous attribution also invalidate complete write coverage.
Logging boundaries use acknowledged enable/disable transactions and the writer's
drain barrier in the collector's clock domain. Only the four exact logger
destinations are permitted during those intervals. GPU windows are separately
normalized through paired collector/Mach clock readings.

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

The `baseline` command measures the selected code; running it on optimized code
does not recreate the original baseline. A reconstructed reference can use
explicit reviewed Release binaries while sharing the current runner and collector:

```sh
python3 scripts/run_performance_checks.py baseline \
  --app-binary /absolute/baseline/FluxLLMApp \
  --test-bundle /absolute/baseline/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/current/FluxLLMResourceCollector \
  --provenance /absolute/baseline/provenance.json
```

Provenance schema 1 pins the production commit, Release configuration, reviewed
instrumentation and adapter hashes, app/test binary hashes, fixture schema 2,
logging capability, the exact popover lifecycle policy, and any legacy
history-seeder executable/hash. Optional
`fixture_equivalence_sha256` maps `fresh` and `populated` to expected manifests.
Reconstructed pre-optimization binaries are accepted only in baseline mode.
Original binaries and reports remain unchanged; corrected instrumentation and
new captures are identified separately.

Diagnostic logging did not exist in the original application. Its reconstructed
reference still runs the continuous 30-second traffic, but the requested on
segment is explicitly not applicable. Only the two off segments can be compared
against current logging transitions; no toggle or drain acknowledgment is
fabricated. The final off comparison begins after the verified disable/drain
acknowledgment, excluding the logging-on tail. Actual window durations accompany
the normalized GPU percentages. Current code must complete the full off/on/off
protocol.

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
Manual dispatch can select an available Apple Silicon XLarge runner and an
explicit GPU provider. The default coarse probe uses only existing noninteractive
authorization; CI never opens a secure prompt. Hosted runner GPU sampling, display
availability and filesystem authorization are capabilities to prove, not assumed
guarantees. Until the coarse schema/calibration is implemented and validated, GPU
coverage cannot pass even on an authorized host. Automated calibration, native UI
checks and final accounting remain required; hardware acceleration alone proves
none of these. Collection and analysis must fit the same 300-second deadline. The workflow's job
timeout also allows for the separate build.

Normal Swift, Python, and release-script checks remain independent of the
five-minute performance stage. The fast Python harness checks run with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_*performance*.py'
```

A short successful run establishes coverage of the fixed regression workload. It
does not establish absence of leaks that require hours to develop.
