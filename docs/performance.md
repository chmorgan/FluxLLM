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
invalidate that bounded cache. Closing the final chart consumer releases the
rebuildable request/tool ordering indexes and the tool-owner query cache. Raw
samples, request records, tool events, accounting totals, and retention policies
remain unchanged; reopening rebuilds indexes on demand. Prepared tool histories
retain one canonical bucket buffer with segment ranges. Drawing traverses that
buffer directly, preserving gaps, pending evidence, markers, and inspection
values without retaining a second flattened copy of the buckets.

Rail decoration ticks do not rebuild the static bars and
pause between visible effects; hidden surfaces release their hosts and caches.
Explicit dashboard opening attaches its host before ordering the native window
front. This avoids the large first-use allocation and writes reproduced when a
host is inserted into an already visible empty window. Native visibility still
controls host release after an unsuccessful presentation or later occlusion.
Production chart surfaces render through SwiftUI `Canvas.drawingGroup`, coalesce
scalar presentation updates, and retain twinkle animations in Core Animation
shape layers. Production also uses incremental history ordering, optimized chart
preparation, ordered chart publication, the Canvas frame clock, and unpromised
eligible stream-body writes.
The explicit ImageRenderer controls remain available for comparing
the earlier rendering path. Complete application measurements still enforce
CPU, memory, GPU, and write budgets across first window opening and subsequent
UI rendering; selecting the improved path is not a performance-gate pass.

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

**Optional CPU work counters.**

Each existing kernel sample may include `cpu_work_counters` from
`proc_pid_rusage/RUSAGE_INFO_V4`. Schema version 1 records unsigned 64-bit
`instructions` and `cycles` in `count` units, plus `qos_time_raw` for `default`,
`maintenance`, `background`, `utility`, `legacy`, `user_initiated`, and
`user_interactive`. QoS units are explicitly `unspecified_kernel_units`; the
runner does not convert them to seconds. Integers and interval deltas retain
full UInt64 precision, including values above 2^53.

The optional diagnostic requires the existing authenticated ready/final process
identity and unique, exact control or final kernel boundaries. Runtime reports
use the acknowledged before-traffic and completion-end samples, not interpolated
phase edges. The diagnostic subtracts
cumulative integers without interpolating them. The complete group must have
identical schema/units, all required fields, and nondecreasing counters throughout
the capture. A malformed, partial, mixed, or regressing group produces
`invalid_diagnostic`; an entirely absent group in an older product is
`unavailable`. Neither changes independently valid CPU/resource gate results.

For an interval with positive measured CPU time, both instruction and cycle
deltas must be positive and at least one QoS bucket must advance before the
combined diagnostic is available. Unsupported all-zero counters remain
unavailable, with their exact deltas preserved; zero nondefault QoS buckets are
valid. An idle interval with zero CPU time may retain usable zero deltas only
when positive cumulative instruction/cycle and QoS evidence elsewhere in the run
establishes that those counters are populated. An entirely zero run remains
unavailable, including idle captures.
`instructions_per_cycle` is reported only when both hardware deltas are positive.
These raw counters do not establish GHz, performance/efficiency-core placement,
or a thermal cause. They never normalize the 5% CPU target, add a polling or
calibration stage, or imply a performance-gate pass. Adding this instrumentation
changes its hash: freeze new product provenance and preserve older baselines;
do not retrofit these fields into existing captures.

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

## Memory attribution diagnostics

Use the separate memory command with frozen Release products and their matching
provenance. It performs no build:

```sh
python3 scripts/run_performance_checks.py memory \
  --app-binary /absolute/products/FluxLLMApp \
  --test-bundle /absolute/products/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/products/FluxLLMResourceCollector \
  --provenance /absolute/products/provenance.json \
  --graphics-mode normal
```

The runner verifies product, source, provenance, and resource-bundle hashes. Each
invocation has its own hard **90-second deadline**, including validation, native
inspection, workload, and cleanup; eight seconds are reserved for cleanup. It
launches an owned populated-history process and inspects never-opened,
dashboard-only, both-visible idle, both-visible streaming, and both-closed
states. Streaming lasts 25 seconds with two requests at 200 fragments per second
each. A final checkpoint follows five additional seconds of closed-window
settling. PID and process birth identity, native visibility, fixture correctness,
and final accounting are verified.

Choose one diagnostic mode per invocation with `--graphics-mode`:

| Mode | Controlled difference |
| --- | --- |
| `normal` (default) | Production native GPU Canvas rendering, coalesced scalar presentation, and retained twinkles; older frozen binaries retain their original behavior. |
| `direct-host` | Attach the dashboard host without the initial placeholder, at a fixed diagnostic viewport. |
| `empty-drawing` | Keep the native canvas and renderer lifecycle but use an empty drawing closure. |
| `no-renderer` | Keep native canvas layout but skip renderer creation and drawing. |
| `bitmap-destination` | Render through a bounded temporary CPU bitmap before copying into the native destination. |
| `bitmap-layer-destination` | Keep ImageRenderer, gradients, and blur, render into a bounded RGBA bitmap, and assign the finished image directly to `CALayer.contents`. |
| `bitmap-layer-bgra` | Use the same layer destination and drawing workload, changing only the bitmap format to BGRA. |
| `bitmap-layer-no-decorations` | Use the RGBA layer destination while omitting the animated request-rail decoration surface. |
| `native-gpu-canvas` | Draw through SwiftUI `Canvas.drawingGroup`, bypassing ImageRenderer and the app's CPU bitmap/layer-image path. |
| `native-gpu-coalesced-scalars` | Keep the native GPU Canvas backend and coalesce scalar presentation updates. |
| `native-gpu-retained-twinkles` | Keep the native GPU Canvas backend and submit twinkle animations through retained Core Animation shape layers. |
| `native-gpu-optimized` | Combine scalar presentation coalescing and retained twinkles with the native GPU Canvas backend. |
| `no-blur` | Keep the renderer and drawing geometry while skipping the main-series Gaussian blur. |
| `cpu-glow` | Use a bounded CPU raster glow in place of the filtered series-glow pass. |
| `no-gradients` | Substitute solid fills for the three chart gradient operations, preserving geometry and animation. |
| `no-gradients-or-blur` | Make the same gradient substitutions and also skip the filtered main-series glow. |

Both gradient controls require valid substitution counters throughout the capture
and a positive count after the visible workload. They affect the three Canvas
gradient operations; SwiftUI surface and rim gradients remain unchanged.

The three layer-destination controls use the same frozen app binary and bound
each bitmap buffer to 32 MiB while retaining
one current layer image per chart surface. They never copy that image into the
native window drawing context. The runner requires zero bitmap failures and
zero native draw callbacks throughout the capture, positive chart draws and
image presentations after the visible workload, presentations equal to summed
role draw counts, reconciled role/image byte
counters, and zero retained image bytes at closed checkpoints. ImageRenderer
must still be created for drawn roles. These requested image and scratch-buffer
bytes describe owned CPU data, not measured GPU allocation.

The two newer controls must acknowledge their pixel format, Device RGB color
space, and whether rail decorations are enabled. `bitmap-layer-bgra` requires
`bgra8-premultiplied-first`; the other layer controls use
`rgba8-premultiplied-last`. Only `bitmap-layer-no-decorations` may report
decorations disabled, and every counter for its `rail_decorations` role must
remain zero, including creation, update, draw, renderer, and image counters.
The original layer mode accepts older frozen products without format metadata;
any metadata they do expose must match that mode.

The four native GPU controls use the same frozen binary and fixtures. They keep
the chart drawing operations and use SwiftUI's drawing group without custom
Metal shaders. The runner requires `native_gpu_backend` to identify
`swiftui-canvas-drawing-group`, actual Canvas callback counts equal to summed role
draws, positive static-chart drawing after the workload, zero ImageRenderer and
CPU bitmap/layer-image accounting, and released canvas/geometry counters at
closed checkpoints. Callback counts prove drawing occurred; they do not prove
GPU execution or measure its duration.

Each newer native GPU mode must acknowledge exact Boolean values for
`scalar_presentation_coalesced` and `retained_twinkles_enabled`. The original
`native-gpu-canvas` mode accepts older frozen products without these flags, but
checks any supplied flag. Coalesced modes also require a positive
`scalar_presentation_publications` count after the visible workload, proving
that changed presentation values were published. Other modes require that count
to remain zero when exposed.

Current `normal` captures identify the native GPU backend and must satisfy the
full `native-gpu-optimized` contract, including both enabled flags and actual
publication/animation evidence. Once a run acknowledges this backend, every
later graphics snapshot must retain that metadata; dropping it or reverting to
renderer/bitmap counters fails validation. The report records the selected
normal rendering contract. Older frozen `normal` binaries without this marker
retain legacy validation, or explicitly unavailable graphics counters if they
predate instrumentation. They cannot claim native drawing or enabled
optimizations without the backend marker.

Retained modes must identify `core-animation-shape-layers` and expose host,
instance, and submitted-animation counters. Created minus destroyed counts must
equal live counts, peak counts must be consistent, live instances must not exceed
twice the live host count, and closed checkpoints must have zero live hosts and
instances. Visible work must create instances and submit animations. Modes
without retained twinkles reject any such activity when counters are exposed.
These counters prove layer-animation submission, not GPU execution.

The runtime driver also accepts frozen experimental builds that identify
`direct_retained_twinkle_delivery`. Their optional
`retained_twinkle_direct_updates` and `twinkle_state_publications` counters must
prove positive direct delivery without state publications during an authenticated
steady interval. Missing instrumentation reports unavailable evidence. This
contract permits reproducing an experiment; it does not select that delivery path
in production or establish a CPU improvement.

Select any native GPU mode through the existing automated
`run_performance_checks.py memory --graphics-mode MODE --no-native-inspection`
command, supplying the frozen product paths shown above. The runner applies the
same populated fixture, 25-second traffic sequence, visibility checkpoints, and
shutdown checks for each mode; no manual load generation or UI sequence is
needed. The separate scalar and retained modes isolate each change, while
`native-gpu-optimized` measures their combination.

Compare these controls' CPU using `--no-native-inspection`. Measure GPU execution
separately through the bounded, calibrated Instruments provider; neither the
backend name nor a low CPU reading establishes GPU usage. Memory remains a
reported diagnostic in this CPU experiment. The global strict peak-footprint
budget remains below 64,000,000 bytes, and these modes grant no performance pass.

Optionally add `--no-popover-animation` independently of the graphics mode to
disable native popover animation for this diagnostic. The runner verifies the
disabled setting at ready and in every snapshot; missing or mismatched evidence
fails the experiment. Without this flag, the app's default is retained and older
products report an unavailable animation setting instead of an assumed value.

The alternative modes isolate allocation causes; `normal` follows the frozen
binary's production behavior. Native memory inspection also perturbs runtime. Run them separately from
CPU/GPU gates and other native workloads. A successful diagnostic is never a
regression pass and does not alter the normal CPU, memory, GPU, or write limits
above. Exit zero means `diagnostic_captured`; failed validation, incomplete native
reports, or timeout produces `diagnostic_incomplete` and a nonzero exit.

For a comparison without native memory profilers, add `--no-native-inspection`
to each invocation. The same fixture, commands, waits, and kernel checkpoints
remain; `footprint`, `vmmap`, and `heap` stages are explicitly skipped and their
categories remain unavailable. After clean process exit, validated fixture work,
and final memory accounting, the report includes average CPU and maximum rolling
one-second CPU for the authenticated kernel interval from `04-before-traffic`
to `06-after-traffic`. This interval includes fixture start and completion/drain
overhead in both compared runs and excludes startup. Counter continuity,
sampling gaps, PID/birth identity, ready/final events, and exact kernel boundaries
are checked before computing CPU. Captures with native inspection explicitly
report this CPU comparison as unavailable. Neither variant evaluates CPU/GPU
gates; both retain the 90-second deadline.

To compare the three layer controls, run them serially with
`--no-native-inspection`, the same frozen app/test/collector/provenance paths,
and a new output directory per mode. Each invocation applies the same automated
25-second high-rate workload and lifecycle; no manual load or PID selection is
needed. Compare CPU only among these unprofiled captures, then use a separate
native-inspection capture when allocation categories are needed.

Results use a unique ignored `.performance-results/memory-*` directory, or a new
directory supplied with `--output-dir`. Existing artifacts are never overwritten.
Keep `memory-report.json`, `SUMMARY.md`, raw `footprint` JSON/text, `vmmap` text,
selected `heap` text, collector JSONL/stderr, and configuration/storage records.
The report retains parsed category/allocation tables, exact inspection commands,
identity checks, graphics counters, and workload validation; `in-progress.json`
preserves intermediate evidence.

Treat the memory ledgers separately. Footprint categories partition charged dirty
bytes, which already include swapped bytes. `vmmap` reports rounded binary sizes;
`heap` reports exact allocated bytes. Live heap, allocator fragmentation, and
physical footprint are different quantities and must not be added together.

Graphics counters describe canvas/renderer lifecycle and requested pixel areas,
dimensions, scale, temporary bitmap bytes, and retained layer image bytes,
grouped by drawing role. Requested
backing sizes are **not measured GPU allocations or GPU utilization**. Missing
counters remain unavailable, never zero; older frozen products can run in normal
mode without them, while alternate modes require matching mode/counter evidence.
Use native category tables and authenticated kernel footprint for memory
attribution, and the separately calibrated process GPU provider for GPU work.

## Isolated drawing attribution

Use the `drawing` command to identify which drawing operation activates expensive
graphics resources before changing the chart backend:

```sh
python3 scripts/run_performance_checks.py drawing \
  --probe-binary /absolute/products/FluxLLMDrawingProbe \
  --collector-binary /absolute/products/FluxLLMResourceCollector
```

This command uses prebuilt Release products and has a hard **180-second deadline**
for its serial cases, inspections, and cleanup. Each case runs in a fresh owned
process with one 664-by-357-point native window. All backends except the explicitly
unhosted control use the same minimal SwiftUI host.
It starts no model traffic, history, popover, or application monitoring. The
default cases compare an empty drawing and one fixed line through the explicit
`ChartCanvas`, that same line through a plain on-screen `Canvas`, and the line
drawn directly into the native `CGContext`. This probe calls the ImageRenderer
wrapper directly, bypassing the application's `ChartDrawingSurface` backend
selector, so production backend changes do not change its renderer identity.

The runner records the blank visible baseline, first drawing, settled drawing,
100 requested redraws at 30 Hz, post-redraw idle, and released content. Native visibility, dimensions,
draw callbacks, owned PID and birth identity, and clean process exit must validate.
Kernel physical footprint and lifetime peak are collected externally; native
`footprint` and `vmmap` reports identify allocation categories. These diagnostics
are separate from the CPU/GPU regression gate and never imply that its limits pass.

Use repeatable `--case BACKEND:PRIMITIVE` arguments for the next controlled
comparison. Backends are `image-renderer`, `canvas`, `core-graphics`,
`core-graphics-unhosted`, and `bitmap-layer`. The unhosted control attaches the
native drawing view directly to the window. The bitmap control draws into a
bounded CPU bitmap and assigns its image directly to `CALayer.contents`; it never
paints that image into the native window drawing context. Per-buffer allocation
is capped at 32 MiB, and requested buffer counters are not actual GPU memory.
The runner rejects bitmap failures or a fallback to native window drawing.

Add `--no-native-inspection --settle-seconds 3` to compare the same operations
using only external kernel counters and explicit three-second idle intervals.
This control separates idle reclamation from the possible effects of `footprint`
and `vmmap`. The settling option accepts one through five seconds and applies
after the first draw, repeated draws, and close; actual wait durations are saved.

Drawing primitives are `empty`, `line`, `solid-fill`, `linear-gradient`, `radial-gradient`, `text`,
`clipped-line`, `layer-line`, `with-cg-line`, and `chart-path`. Test the smallest
reproducer first, then add one operation at a time. Keep first-use, repeated-draw,
and released memory separate; do not infer a leak or API-wide cost from one peak.
Results and source/product identities are written to a new ignored artifact
directory; previous captures are never overwritten.

## Runtime CPU attribution

Profile the visible application with reviewed, prebuilt products:

```sh
python3 scripts/run_performance_checks.py runtime profile \
  --app-binary /absolute/products/FluxLLMApp \
  --test-bundle /absolute/products/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/products/FluxLLMResourceCollector \
  --provenance /absolute/products/provenance.json
```

The default profile mode is `normal`; `--graphics-mode` selects
`native-gpu-optimized` or a runtime control below. Time Profiler samples perturb
execution, so profile results provide CPU attribution, not CPU acceptance.
Trace export and analysis share the command's hard **300-second deadline**.
The command never builds products or automatically retries a failed capture.
A profile case has a 120-second budget, including a bounded 30-second trace-save
allowance. After profiler readiness, a profile-only guard verifies visible idle
windows across at least 0.5 seconds before traffic starts; it does not alter the
comparison workload or its measured interval. Export analysis accepts both nested
backtraces and frames directly inside a tagged backtrace. Both forms retain strict
schema, frame-shape, identity, and timing validation; malformed or mixed forms
remain invalid evidence.
Sampled CPU is cross-checked against the kernel counters for each phase. A
difference greater than both 20% of kernel CPU and 0.5 percentage points leaves
attribution pending, retaining the raw weights and rankings without rescaling
them. Complete recording alone does not establish accurate CPU attribution.

Use direct thread counters when statistical samples do not reconcile:

```sh
python3 scripts/run_performance_checks.py runtime threads \
  --app-binary /absolute/products/FluxLLMApp \
  --test-bundle /absolute/products/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/products/FluxLLMResourceCollector \
  --provenance /absolute/products/provenance.json
```

This command runs the same visible 25-second, two-stream, 200 Hz workload with
the thread observer **off/on/off**, within the existing 300-second deadline.
The middle case registers the actual main and sole NIO event-loop thread IDs
once, then reads their cumulative user/system CPU externally during the existing
250 ms collector sampling loop. Ordinary launches and the surrounding controls
do not register or collect thread counters. The diagnostic rejects a future
multi-loop proxy until every event-loop identity can be accounted for.

Before launching the instrumented app, the collector calibrates external thread
reads against `CLOCK_THREAD_CPUTIME_ID`, `getrusage`, and process CPU in an owned
helper with continuous, bursty, and idle work. It also checks rejection of a dead
thread and records the CPU cost of 200 observer reads. Run this calibration and
malformed-registration/conversion checks independently with
`FluxLLMResourceCollector --thread-cpu-self-test`; its deadline is ten seconds.

Each pair of thread reads is enclosed by process CPU counters and Mach timestamps.
The analyzer validates process birth, stable registered IDs, raw conversions,
counter monotonicity, calibration, sampling coverage, visibility, and clean exit.
It retains the counter precision and sequential-read uncertainty in explicit
CPU bounds, and rejects intervals wider than 0.1 CPU percentage point. The API
encodes microsecond thread times in nanoseconds; see Apple's
[fill_taskthreadinfo implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c).

`SUMMARY.md` and `runtime-report.json` contain main-thread, NIO-thread, and other
process CPU for actual read endpoints wholly inside each runtime phase. The
other-process value is a bounded residual, including unregistered worker threads.
No interpolation assigns thread CPU to the exact rolling one-second peak.
Existing whole-process rolling CPU remains separate. The middle case is diagnostic
and cannot pass CPU acceptance, even when attribution succeeds. Failed attribution
leaves the command `analysis_pending` and preserves raw process measurements.
The off/on/off process comparison reports observer disturbance and reference
drift; a calibration pass does not imply that instrumentation has zero overhead.

Separate networking work with scoped CPU counters:

```sh
python3 scripts/run_performance_checks.py runtime nio \
  --app-binary /absolute/products/FluxLLMApp \
  --test-bundle /absolute/products/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/products/FluxLLMResourceCollector \
  --provenance /absolute/products/provenance.json
```

This uses the same workload, visibility checks, off/on/off comparison, and
300-second deadline, with up to 70 seconds per case for startup, measurement,
and cleanup. Only the middle case enables both external thread counters
and app-side NIO scopes. Each measured invocation reads the calling thread's
CPU clock; counters accumulate on the event loop without per-invocation locks.
Control snapshots collect them on that same loop before returning immutable
results to the UI thread. Ordinary launches omit the scoped diagnostics.

The report separates framing, JSON decoding, token/tool interpretation, relay
updates, forwarding, and scheduled relay delivery. The upstream read callback
includes synchronous HTTP decoding and its child handlers. Forwarding includes
the small-body coalescer and synchronous downstream pipeline work. The coalescer
scope wraps the complete body-write call, including encoding and flushing; it
does not isolate buffer-copy CPU. These nested measurements are shown separately
and must not be added to their parents.
Deferred socket operations and other event-loop work remain in the thread's
unassigned CPU instead of being attributed to a synchronous forwarding scope.

Intervals use actual control-snapshot endpoints and retain clock-read bounds.
Scoped totals reconcile against the same thread's CPU clock and independently
bracketing external thread counters. Startup calibration records empty-scope and
clock-read costs without subtracting them from results; matched controls expose
the combined observer effect. Invalid counters or attribution leave raw captures
available but cannot produce CPU acceptance or an exact rolling one-second
per-stage attribution. `SUMMARY.md` contains the review tables.

Use an unprofiled comparison to measure a candidate against the same frozen binary:

```sh
python3 scripts/run_performance_checks.py runtime compare \
  --app-binary /absolute/products/FluxLLMApp \
  --test-bundle /absolute/products/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/products/FluxLLMResourceCollector \
  --provenance /absolute/products/provenance.json \
  --baseline-mode runtime-optimized --controls normal
```

This runs `runtime-optimized`, the preserved history/preparation default, before
and after production `normal`. Production enables both history/preparation
optimizations plus `ordered_chart_publication`, `unpromised_stream_body_writes`,
and `canvas_frame_clock`;
`shared_chart_preparation` and `stable_decoration_hosts` remain disabled.
Without selection flags, the default sequence is `native-gpu-optimized`,
`runtime-optimized`, then `native-gpu-optimized` again.
`--controls` accepts one through three distinct controls, for at most five
cases within the same 300-second deadline. For example,
`--controls runtime-history-order runtime-chart-preparation runtime-optimized`
compares the history and preparation optimizations separately and together against
`native-gpu-optimized`.

| Runtime control | Behavior |
|---|---|
| `runtime-history-order` | Maintain history ordering incrementally. |
| `runtime-chart-preparation` | Use the optimized chart preparation path. |
| `runtime-optimized` | Preserve the previous production default: history ordering and chart preparation optimizations, without stream-write or Canvas-clock changes. |
| `runtime-no-lifecycle` | Enable both optimizations and remove arrival/completion effects; active retained twinkles remain enabled. |
| `runtime-shared-preparation` | Share immutable metadata after resolving corrected records across chart consumers, and preserve ordered publication inputs where applicable. |
| `runtime-stable-decoration-hosts` | Keep Canvas and retained twinkle owners stable during active episodes, suppressing inactive drawing without restarting animation clocks. |
| `runtime-stream-writes` | Omit individual body-write promises for eligible ordinary responses, retaining existing immediate flushes and failure cancellation. |
| `runtime-next-optimized` | Combine shared preparation, stable decoration hosts, and the body-write promise experiment. |
| `runtime-canvas-clock` | Keep both history and preparation optimizations and drive rail drawing with a dedicated Canvas frame clock. |
| `runtime-stream-canvas-clock` | Preserve the stream-write and Canvas-clock default before ordered publication, keeping both history and preparation optimizations. |
| `runtime-ordered-publication` | Combine ordered single-interval chart publication, stream writes, Canvas clock, and both history/preparation optimizations; matches current production feature selection. |
| `runtime-direct-tool-plot` | Build request-tool plot geometry directly on top of current production behavior. |
| `runtime-ungrouped-canvas` | Omit `drawingGroup` around native Canvas surfaces while retaining current production behavior elsewhere. |
| `runtime-no-arrival-effects` | Suppress request-arrival effects while preserving completion effects and active retained twinkles. |
| `runtime-held-static-chart` | Hold the first usable static chart drawing while continuing 1 Hz preparation, streaming, and all animation roles; diagnostic only, never CPU acceptance eligible. |
| `runtime-metal-arrival-bursts` | Render arrival bursts and glints with a Metal shader, preserving completion effects and retained twinkles. |
| `runtime-compact-tool-paths` | Enable tool-path compaction on top of current production behavior. |
| `runtime-deferred-tool-geometry` | Construct request-tool paths on their first access from a render callback, preserving 1 Hz chart publication. |
| `runtime-deferred-tool-geometry-2hz` | Use the same deferred construction with chart publication increased to 2 Hz. |

The shared-preparation, stable-host, stream-write, and combined controls include
the existing history and preparation optimizations. Compare individual candidates
against the preserved previous default with
`--baseline-mode runtime-optimized --controls runtime-shared-preparation runtime-stable-decoration-hosts runtime-stream-writes`,
then use a separate comparison with
`--baseline-mode runtime-optimized --controls runtime-next-optimized` for their combination.
These selections keep the same five-case maximum and 300-second command deadline.

To compare an implementation change across two frozen builds, use `runtime
compare --baseline-mode normal` with the candidate's usual product arguments and
`--reference-app-binary`, `--reference-test-bundle`, and `--reference-provenance`.
This runs reference/candidate/reference in the same graphics mode and preserves
the 25-second traffic workload, completion tail, visibility checks, and 300-second
deadline. These three frozen-version cases each allow up to 70 seconds for
startup, measurement, and cleanup, matching the three-case NIO diagnostic.
Other unprofiled controls and thread diagnostics retain 54-second case allowances;
the workload and resource limits are unchanged. Both versions must use identical
common collector bytes, measurement sources, and fixture identity. Reference
arguments cannot be combined with
`--controls` or profiling. Each version's provenance and binary identity remain
separate; drifted reference runs leave the comparison inconclusive.

The two Canvas-clock controls remain available for isolated comparisons with
`canvas_frame_clock = true` and shared preparation and stable decoration hosts
disabled. Only `runtime-stream-canvas-clock` also enables
`unpromised_stream_body_writes`. Compare them with
`--baseline-mode runtime-optimized --controls runtime-canvas-clock runtime-stream-canvas-clock`.
The **5% runtime CPU** and **1% GPU** limits remain unchanged; production selection
does not establish a complete resource-gate pass.

Production `normal` now enables `ordered_chart_publication` alongside its
history/preparation, unpromised stream-write, and Canvas-clock paths; shared
preparation and stable decoration hosts remain disabled. The
`runtime-ordered-publication` control preserves this selection, and
shared-preparation controls also enable ordered publication. Older frozen
`normal` captures may omit the ordered flag or report false. A true ordered flag
in `normal` requires acknowledgment of the complete current production selection.

`runtime-direct-tool-plot` is a separate experiment that inherits those production
paths and enables `direct_tool_plot`. Shared preparation and stable decoration
hosts remain disabled; `normal` keeps `direct_tool_plot = false`. Compare the
candidate with `--baseline-mode normal --controls runtime-direct-tool-plot`.
All workload, visibility, clock, deadline, and resource-budget checks still apply.

`runtime-ungrouped-canvas` isolates the cost of `drawingGroup` with
`ungrouped_native_canvas = true`. It inherits production's ordered publication,
stream-write, Canvas-clock, and history/preparation paths; direct tool plotting,
shared preparation, and stable decoration hosts remain disabled. Compare it with
`--baseline-mode normal --controls runtime-ungrouped-canvas`. Production `normal`
keeps `ungrouped_native_canvas = false`; no measured benefit is established yet.
The backend acknowledgment is exactly `swiftui-canvas` for this experiment and
`swiftui-canvas-drawing-group` for grouped native rendering.
Existing path, drawing-fidelity, visibility, clock, budget, and deadline checks
remain in force.

`runtime-no-arrival-effects` inherits production's ordered publication,
stream-write, Canvas-clock, and history/preparation paths, with grouped Canvas
and legacy tool plotting. Shared preparation and stable decoration hosts remain
disabled. It keeps `lifecycle_effects_enabled = true` and sets
`arrival_effects_enabled = false`; compare it with
`--baseline-mode normal --controls runtime-no-arrival-effects`. Production
`normal` continues to show arrival effects; this diagnostic makes no CPU-gain claim.

`runtime-held-static-chart` isolates static chart drawing and publication into
Canvas from chart preparation. Run `runtime compare --baseline-mode normal
--controls runtime-held-static-chart` with the same frozen product arguments.
The control retains the first usable drawing; incoming data and prepared chart
snapshots continue at 1 Hz, while arrival/completion effects and active twinkles
remain live. The report requires initial static draws, continued preparations
and held publication attempts, and zero static redraws, applied updates, hold
resets, or host lifecycle changes during traffic and completion. Size or drawing
environment changes safely reset the retained drawing and invalidate the causal
comparison. Hidden hosts release retained closures. Because the displayed static
data deliberately stops changing, raw CPU differences are diagnostic evidence
only: target evaluation and CPU acceptance remain disabled for this mode.


`runtime-metal-arrival-bursts` is an opt-in experiment inheriting current
`normal` at 1 Hz chart publication, with deferred geometry and compact tool paths
disabled. It draws arrival bursts and glints in the existing order; retained
twinkles remain active and completion uses the original Canvas clock/drawing
path. Compare the same binary with `runtime compare --baseline-mode normal
--controls runtime-metal-arrival-bursts` and the existing required product paths,
which runs normal/candidate/normal. The visible idle Metal host may prewarm
without starting an active frame clock; that clock stops when the burst ends.
Production remains unchanged and no performance gain is established.

Run the automated native shader qualification against the same already-built
Release test bundle from the repository root; this command performs no build:

```sh
FLUXLLM_METAL_ARRIVAL_FIDELITY=1 \
FLUXLLM_METAL_ARRIVAL_FIDELITY_OUTPUT="$PWD/.performance-results/metal-arrival-fidelity-r1" \
  /usr/bin/xcrun xctest \
  -XCTest FluxLLMTests.MetalArrivalBurstRendererTests \
  /absolute/products/FluxLLMPackageTests.xctest
```

`MetalArrivalBurstRendererTests` runs readback calibration, resource-lifetime
checks, and a **68-case** comparison against independent Canvas rendering. The
matrix covers burst families and ages, colors, 1×/2× scale, overlapping draw
order, clipped glints, mixed burst/glint order, and inactive boundaries. Every
pixel's absolute difference must be at most **2 byte values in each RGBA
channel**; averages cannot hide a larger difference. The explicit output path
must stay inside ignored `.performance-results`. Each native gate creates a
unique subdirectory containing its JSON result and image evidence, without
overwriting earlier captures. Missing Metal hardware records `unavailable` and
skips the native test; a skip or successful test-process exit alone does not
qualify the shader. Read the gate results, including calibration and all 68
fidelity cases.

Shader qualification establishes offscreen rendering fidelity and the tested
resource behavior. It does not establish live app CPU or GPU consumption. Use
the normal/candidate/normal runtime comparison above for unprofiled CPU and the
existing calibrated GPU trace runner separately, with its 300-second bound.
App frame/submission counters prove submitted work and are not GPU utilization;
the 5% CPU and 1% GPU limits remain unchanged.

`runtime-compact-tool-paths` is opt-in and inherits every current `normal` feature,
changing only `compact_tool_paths_enabled` to `true`; production `normal` keeps
it `false`. Use the existing `runtime compare` command with
`--baseline-mode normal --controls runtime-compact-tool-paths` for a same-binary
normal/candidate/normal comparison. The 300-second deadline, fixed workload,
publication cadence, 5% CPU limit, and separate 1% GPU limit remain unchanged.
This experiment has no established performance gain and is not promoted.


`runtime-deferred-tool-geometry` is opt-in and inherits all current `normal`
features, including `compact_tool_paths_enabled = false`. This candidate and
its separately scoped `runtime-deferred-tool-geometry-2hz` variant set
`deferred_tool_geometry_enabled = true`: request-tool path construction is
deferred until the first access from a render callback. Compare the same frozen
binary with `--baseline-mode normal --controls runtime-deferred-tool-geometry`
using the existing `runtime compare` command. The normal/candidate/normal order,
fixed workload, publication cadence, 300-second deadline, and CPU/GPU budgets
remain unchanged. No performance gain or production promotion is established.


`runtime-deferred-tool-geometry-2hz` changes only the deferred candidate's chart
publication interval to 0.5 seconds. `MetricsStore` samples at 2 Hz, while chart
publication remains **1 Hz per window** in production `normal` and the original
deferred candidate. Only the new control publishes charts at **2 Hz per window**;
the 30 FPS animation clock is a separate cadence. Production behavior is unchanged,
and no gain is established for either deferred control.

For four cases—normal, deferred at 1 Hz, deferred at 2 Hz, normal—use the existing
`runtime compare` invocation with:

```text
--baseline-mode normal --controls runtime-deferred-tool-geometry runtime-deferred-tool-geometry-2hz
```

This remains within the existing five-case maximum and 300-second deadline. The
fixed streaming workload and CPU/GPU budgets are unchanged. Actual preparation
and static-chart draw deltas are reported for each case; the 2 Hz control does
not reuse hardcoded draw counts from the 1 Hz workload.

The stream-write control keeps promises on response heads and ends, and on
`HEAD`/`CONNECT` bodies. Its body fast path requires an active downstream channel
and an installed lifecycle observer on the same event loop. Downstream errors,
inactivity, or output closure cancel the relay before upstream closure; existing
forwarding cadence and the close-future fallback remain in place.
This contract covers the proxy-owned standard NIO pipeline. A future custom
outbound handler that reports rejection only through a promise would need that
promise or explicit lifecycle error handling. As before, a parsed terminal record
can complete accounting before a later asynchronous delivery failure.

Every case uses the same exact 25-second, two-stream fixture with 10,000 content
chunks, followed by three seconds of visible completion. Native dashboard and
popover visibility, token progression, and owned PID/birth identity are checked
at one-second intervals. Product hashes and measurement sources must remain
unchanged. Missing visibility, stalled progress, changed identity, incomplete
forwarding, invalid counters, or an unfinished trace/export produce an incomplete
diagnostic rather than a usable comparison.

The performance session assigns deterministic synthetic request IDs in namespace
7 from the fixture's `perf_index` (`cycle * 32 + ordinal`) and uses a fixed twinkle
RNG seed. Real clocks remain unchanged. Comparisons require acknowledgment of
`synthetic_request_identity.policy = 'fixture-index-v1'` and
`synthetic_animation_policy = 'fixture-index-and-fixed-twinkle-seed-v1'`, exactly
two request IDs matching the fixture, zero invalid requests, and stable snapshot
metadata. These controls make the visual workload comparable across cases.

Unprofiled reports show CPU averaged across the whole contiguous runtime and its
maximum rolling one-second CPU, normalized to one core. An explicit CPU
`within_limit` result compares that maximum with **5%**; it covers visible traffic
and completion, not startup or the full resource gate. Memory is reported only.
The calibrated GPU and filesystem-write gates remain separate, and normal strict
budgets are unchanged. Arrival, steady, completion, and whole-runtime windows are
also retained separately; overlapping windows must not be summed.

A comparison is inconclusive if either baseline mean or maximum drifts by more
than both 20% of the larger baseline value and 0.5 percentage points. Work counters
must also prove the selected path ran: optimized preparation must account for all
chart preparations, with a positive count; warmed incremental history must perform
no full order rebuilds and must record positive tool and completed-record
insertions. Comparisons require the complete feature/counter contract in every
case. Candidate flags must match the selected mode and remain stable. Shared
preparation must cover every chart preparation with positive, bounded normalization
builds; `streamed_bodies_without_promises` must record actual body fast-path
writes, rather than parsed NDJSON records.
Shared-preparation and unpromised-write counters must remain zero when those
paths are disabled; stable-host mode requires native decoration-host creation
evidence. Canvas-clock controls require positive top-level
`rail_frame_clock_ticks` and zero `rail_timeline_content_updates`; nonclock modes
must report zero clock ticks whenever that counter is supplied. Older frozen
products may omit the new clock flag and counters, but any supplied evidence is
validated. Clock candidates must also produce at least 80% as many native rail
decoration draws as frame ticks, rounded down with a two-frame boundary allowance
and a minimum of one draw. Reports retain both counts; they do not establish
pixel-for-pixel visual equality. Authenticated checkpoints strictly inside the
fixed fixture's +5s to +20s steady phase must show both requests active and zero
additional clock ticks, after arrival effects have ended and before completion.
The two closed checkpoints, five seconds apart, must also show no additional
ticks. The completion endpoint itself is not assumed animation-free.
Existing drawing, twinkle lifecycle, visibility, and closed-resource
checks still apply; selecting a flag alone is
insufficient evidence that a candidate ran.

The arrival-effects control requires the boolean `arrival_effects_enabled` flag
and a nonnegative integer top-level `suppressed_arrival_effects` counter, with a
positive workload delta. Every other mode requires zero suppressions when
instrumented, including `runtime-no-lifecycle`, which disables the whole lifecycle.
The arrival flag is false only for these two controls and true for all other modes.
Older frozen products may omit the entire group; supplied evidence must be complete
and valid. The new control must prove zero arrival frame ticks and rail-decoration
draws, plus positive completion ticks and draws. Whole-runtime, steady, closed,
visibility, fidelity, CPU/GPU limits, and deadline checks remain unchanged.
Existing authenticated checkpoints bracket the full two-second arrival phase;
the counter interval may extend into the following effect-free gap. Completion
evidence uses checkpoints from the acknowledged end of both streams inside the
three-second completion phase. Counter values are never interpolated.
The traffic acknowledgment may correctly contain zero frame ticks in this mode;
generic snapshot validation defers tick positivity to the required whole-runtime
and authenticated completion-phase proofs.


Metal-arrival graphics metadata requires `metal_arrival_bursts_enabled = true`
and `arrival_backend = 'metal-shader'` for this candidate; other instrumented
native modes require `false` and `'canvas'`. Older modes may omit the entire new
group. The three top-level UInt64 counters `metal_arrival_frames`,
`metal_arrival_submissions`, and `metal_arrival_failures` must be complete when
present; other modes require all three to remain zero. They are separate from
native Canvas role draw counts. Frames count drawable callbacks eligible for an active burst;
submissions count successfully encoded and committed command buffers. Valid
candidate evidence requires equal, positive frame/submission deltas and zero
failures both across the whole runtime and the authenticated checkpoint superset
of arrival. Authenticated completion must retain positive original Canvas clock
and draw activity. These counters prove submitted work, not GPU execution or
allocation counts. Separate GPU-provider calibration and the 1% GPU limit remain
unchanged, as do the 5% CPU limit, physical-footprint limit below 64,000,000 bytes,
fixed workload, and 300-second command bound.

Ordered publication, including current `normal`, requires a positive workload
delta in top-level
`ordered_chart_publication_queries`, counting actual single-interval ordered
queries, and zero delta in `chart_publication_full_sorts`, counting fallback-sort
attempts. Instrumented nonordered modes must report zero ordered-query counts
and a positive full-sort delta during this fixed workload. Ordered shared modes
use the same query/sort proof when instrumented. Earlier fallback sorts outside
the measured interval are allowed. Other older frozen modes may omit the entire
new flag/counter group; supplied evidence must be complete and valid.

Direct-tool-plot instrumentation must supply the boolean `direct_tool_plot` flag
and both nonnegative integer counters, `direct_tool_plot_builds` and
`legacy_tool_plot_builds`. They count actual request-tool geometry builds. The
direct control requires a positive direct-build delta and zero legacy-build delta
during the fixed workload. Instrumented nondirect modes require zero total direct
builds and a positive legacy-build delta. Older frozen products may omit the
entire group; partial or incorrectly typed evidence is rejected.

Ungrouped-Canvas instrumentation requires the boolean `ungrouped_native_canvas`
flag and nonnegative integer counters `ungrouped_native_canvas_draws` and
`grouped_native_canvas_draws`, counted at accepted native Canvas draw callbacks.
The candidate requires a positive ungrouped-draw delta and zero grouped-draw
delta. Instrumented native baselines require zero ungrouped draws and a positive
grouped-draw delta. The two deltas must sum to the native GPU draw delta and the
verified sum of role draw deltas. The new mode requires this complete group;
older modes may omit the entire group, but partial or incorrectly typed evidence
is rejected.


Tool-path compaction records actual construction work in the top-level unsigned
integer counters `tool_path_input_points` and `tool_path_output_points`. When
supplied, both counters are required and must be valid and nondecreasing. The
candidate requires positive input-point work and an output-point delta smaller
than its input-point delta; instrumented `normal` requires equal input/output
deltas. These counts prove the selected construction path executed; they do not
establish a CPU or GPU improvement. Older frozen products may omit the entire
flag/counter group; supplied partial evidence is rejected.


Deferred-geometry execution uses the existing `legacy_tool_plot_builds`,
`tool_path_input_points`, and `tool_path_output_points` counters at actual path
construction. The candidate must show positive construction work and equal
input/output point deltas: neither deferred control compacts paths. Both deferred
modes require `deferred_tool_geometry_enabled = true`; supplied flags in all other
modes must be `false`. Older frozen products in other modes may omit the new flag.
Actual construction evidence supplements the unchanged workload, cadence,
visibility, and closed-state checks; selecting the mode alone is insufficient.


Native graphics diagnostics acknowledge publication cadence with numeric
`chart_publication_interval_seconds`: exactly `0.5` is required for
`runtime-deferred-tool-geometry-2hz`; other modes report `1.0` when the field is
present. Older frozen products in other modes may omit this metadata. The new
2 Hz mode requires it, alongside the same deferred-construction flag and actual
construction proof as its 1 Hz counterpart.

Non-native memory diagnostics export the same top-level counters without native
feature flags. Complete typed fallback counts for full sorts, legacy tool plots,
and Timeline updates are allowed. Unsupported fast-path and native-draw counters
must remain zero; no runtime feature contract is inferred from these counters.

A frozen older `normal` profile may omit that metadata and records it as
unavailable; supplied flags are validated, and new runtime controls always
require the full contract. Older frozen profiles without the synthetic identity
and animation policies remain attribution-only, with full visual-comparison
evidence unavailable.

Each command writes `runtime-report.json`, `SUMMARY.md`, per-case raw evidence,
and a hashed measurement-source capsule to a unique ignored
`.performance-results/runtime-*` directory. Profiles also preserve their trace
and exported attribution. `--output-dir` may select a new directory; existing
artifacts are never overwritten. Consult the authoritative JSON status before
using any partially written artifacts.


## Arrival episode diagnostics

Run the automated first/repeated-arrival diagnostic with frozen Release products:

```sh
python3 scripts/run_performance_checks.py arrivals \
  --app-binary /absolute/products/FluxLLMApp \
  --test-bundle /absolute/products/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/products/FluxLLMResourceCollector \
  --provenance /absolute/products/provenance.json \
  --output-dir .performance-results/arrivals-candidate
```

`--output-dir` is optional; the four product/provenance arguments are required.
The command runs four fixed cases serially within **300 seconds**, without
retries or an expanding matrix:

| Order | Rendering | Detailed timing | CPU comparison |
|---|---|---|---|
| 1: normal-before | Production `normal` | Forced off | Eligible |
| 2: Metal untimed | `runtime-metal-arrival-bursts` | Forced off | Eligible |
| 3: normal-after | Production `normal` | Forced off | Eligible |
| 4: Metal timed | `runtime-metal-arrival-bursts` | Enabled | Ineligible |

Each case owns a fresh app process and keeps its dashboard and popover visible
through three episodes in that same process. Every episode runs two streams at
200 Hz for five seconds, followed by at least three seconds of completion and
at least one second of verified quiet before another episode may begin. Episodes
do not overlap. Fixture cycles are fixed at `15000`, `15001`, and `15002`.
Each introduces two new synthetic request IDs, giving cumulative unique counts
of **2, 4, and 6**. Compare corresponding episode ordinals across cases: their
identities and fixture work match. History, colors, and shapes change between
ordinals, so first-versus-repeat differences do not isolate a pure cold-start
cost.

Arrival CPU covers the actual source first-write timestamp through **+2 seconds**.
Full-case CPU separately covers the acknowledged boundary before episode one
through the final completion endpoint, including all intervening gaps. These
intervals answer different questions and are reported separately. The runner
preserves owned PID/birth authentication, native visibility, exact fixture work
and per-fragment timing, source capsules and product identity, and clean final
exit checks. Missing evidence leaves the affected result incomplete.

Only the fourth case sets `FLUXLLM_PERF_ARRIVAL_TIMING=1`; the other three force
it to `0`, regardless of the inherited environment. Timed results are always
ineligible for acceptance. The fifteen timing scopes record calling-thread CPU
and wall durations sampled sequentially, plus setup/resource counters. Every
scope is inclusive and totals can overlap: do not sum them or subtract nested
totals. `metal_frame_callback` covers the full draw callback; completion work
on the main actor can include the final clear-drawable submission.
`metal_descriptor_upload` measures CPU shared-buffer allocation/copy, and
`canvas_arrival_draw` measures Canvas command construction. These scopes are
not exhaustive process-CPU attribution and do not cover driver work outside the
callbacks. Submitted work and timings do not measure GPU execution or GPU
transfer; the separate calibrated GPU provider remains necessary. This diagnostic
does not establish a full resource gate pass or change the **5% CPU**, **1% GPU**,
or **less than 64,000,000-byte physical-footprint** limits.

For whole-process CPU attribution, add `--profile`. Select `normal` to profile
the production renderer:

```sh
python3 scripts/run_performance_checks.py arrivals --profile --graphics-mode normal \
  --app-binary /absolute/products/FluxLLMApp \
  --test-bundle /absolute/products/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/products/FluxLLMResourceCollector \
  --provenance /absolute/products/provenance.json \
  --output-dir .performance-results/arrivals-profile
```

This records **one replay of the selected renderer** with exactly the same three episodes, request
identities, history, cadence, native visibility checks, and final accounting as
the comparison. Detailed timing is forced off. Time Profiler attaches only to
the runner-owned app after PID/birth authentication; it records all app threads.
Omitting `--graphics-mode` retains the Metal-arrival default; explicit
`runtime-metal-arrival-bursts` selects the same behavior. The selected mode is
recorded in the report. The app's first visible idle state precedes the first episode. Recording uses
the existing readiness signal and guard, a 45-second native recording ceiling,
and an explicit stop after the final quiet interval. A 120-second case budget
includes bounded recorder startup, save, and owned-process cleanup. Capture,
two bounded exports, analysis, and artifact publication share the same
**300-second command deadline**, without retries or builds.

The eight analysis windows are fixed:

| Window | Definition |
|---|---|
| Three arrivals | Each episode's actual first source write through +2 seconds |
| Three busiest seconds | The maximum rolling one-second kernel CPU interval inside each arrival |
| Steady reference | Episode three's first source write +2 through +4 seconds |
| Whole replay | Before episode one through episode three's completion endpoint, including gaps |

The busiest windows are selected from kernel counters, independently of sampled
stacks. Selection metadata and paired Mach clock bridges are retained. The
analyzer reports sampled self CPU, CPU including synchronous callees, thread
totals, call-tree context, and kernel CPU over identical intervals. Parent and
child execution rows overlap and must not be summed; asynchronous ancestors
are not inferred. The single steady reference is contiguous, not pooled across
episodes, and the eight windows overlap.

All profiled CPU values are diagnostic and ineligible for acceptance. Material
sample/kernel disagreement or wholly missing symbols yields `analysis_pending`
and a nonzero exit while preserving the unscaled raw evidence. Trace, exports,
owned-process reports, source capsule, and full `cpu-attribution.json` remain
alongside the review tables in `SUMMARY.md`. Missing visibility, stream work,
recording, clock, identity, or clean-exit evidence leaves the run incomplete.
Use the unprofiled four-case replay to validate an optimization; profiling does
not measure GPU execution or establish a performance-gate pass.

To compare an implementation change using frozen products, provide all three
reference arguments. The collector remains the single explicitly supplied
common collector:

```sh
python3 scripts/run_performance_checks.py arrivals \
  --app-binary /absolute/candidate/FluxLLMApp \
  --test-bundle /absolute/candidate/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/common/FluxLLMResourceCollector \
  --provenance /absolute/candidate/provenance.json \
  --reference-app-binary /absolute/reference/FluxLLMApp \
  --reference-test-bundle /absolute/reference/FluxLLMPackageTests.xctest \
  --reference-provenance /absolute/reference/provenance.json \
  --graphics-mode runtime-metal-arrival-bursts \
  --output-dir .performance-results/arrivals-version-comparison
```

This runs exactly **reference-before / candidate / reference-after**, with
detailed timing off in all three cases. Each uses the same three-episode replay
and a 65-second case allowance inside the shared 300-second command deadline.
`--graphics-mode` selects `runtime-metal-arrival-bursts` by default or `normal`
for all three cases; it is valid with reference products or `--profile`. Reference
comparison cannot be combined with `--profile`, and partial reference arguments
are rejected before capture. Omitting reference arguments preserves the existing
four-case comparison or single profiling invocation.

Both frozen versions must validate against the same measurement identity,
populated fixture manifest, and common collector. Before each case and at
finalization, the runner checks its measurement source capsule and both versions'
binary, test-bundle, provenance, and resource-bundle hashes. The report records
each case's product role and both product manifests. The existing drift check
compares only the two reference cases; candidate CPU does not determine whether
the reference bracket is stable. CPU targets, native visibility, exact work,
quiet/closed cancellation, and clean-exit checks remain unchanged. GPU execution
still requires its separate measurement invocation.

## Short matched GPU comparison

Compare two frozen Release products with the same renderer in one calibrated
Instruments recording:

```sh
python3 scripts/run_performance_checks.py gpu-compare \
  --reference-products /absolute/reference-products \
  --candidate-products /absolute/candidate-products \
  --graphics-mode normal \
  --output-dir .performance-results/gpu-version-comparison
```

If Instruments cannot finalize a combined recording within the deadline, use
`--capture-case reference` and `--capture-case candidate` in separate invocations
with separate output directories. These keep the same eight-second workload,
calibration, process ownership, completion, and exit checks while recording one
app replay per trace. A qualified single capture reports `capture_available=true`
and `comparison_available=false`: its measurements are independently captured,
not a same-trace comparison. Missing or failed evidence remains unavailable.

Each products directory supplies `FluxLLMApp`, `FluxLLMPackageTests.xctest`,
`FluxLLMResourceCollector`, resource bundles, and reviewed `provenance.json`.
`runtime-metal-arrival-bursts` or `runtime-metal-full-chart` may replace `normal`.
Use `--reference-mode normal --candidate-mode runtime-metal-full-chart` to
compare different renderers across the frozen products. Each omitted per-product
mode defaults to `--graphics-mode`. No build is performed.

If reviewed external measurement scripts changed since the products were frozen,
`--rebind-measurement` preserves a separate provenance binding in the report
directory. It verifies the original products and collector before rebinding;
the original provenance and binaries remain unchanged.

Each app runs the same populated dashboard workload: two concurrent streams at
200 chunks per second for eight seconds, then at least three seconds of visible
completion. Expected work is 3,200 chunks, 6,434 output tokens, 46 prompt tokens,
two requests, two tool calls, and two results. Native visibility, exact forwarding
and accounting, process ownership, paired clocks, calibration, loss diagnostics,
GPU command completion, and clean exit must qualify before comparing GPU values.
CPU collected under Instruments is diagnostic only and cannot satisfy the CPU
gate; use the separate unprofiled arrival comparison for CPU.

| Stage | Absolute cutoff from command start |
|---|---:|
| Stop recording | 80 seconds |
| Finalize and save recording | 190 seconds |
| Export table of contents | 200 seconds |
| Export required tables | 255 seconds |
| Evaluate GPU execution | 290 seconds |
| Cleanup and report | 300 seconds |

These are deadlines, not expected durations. A missed stage leaves an incomplete
result and its raw evidence; it cannot consume the entire remaining budget and
silently omit later validation. This shorter GPU workload is separately identified
and must not be pooled with the ordinary 25-second CPU workload or earlier GPU
captures. The 1% maximum rolling one-second GPU target remains unchanged.

GPU ownership uses the union of raw submission-ID candidates. Instruments can
join the same driver ID to commands from several processes; its modeled owner
alone is insufficient to resolve that ambiguity. Each physical execution is
counted once per hardware channel. Ambiguous execution contributes to compatible
processes' upper bounds and never their lower bounds; unknown ownership remains
possible for every process. Both calibration bounds must agree with the independent
Metal control. Command inventories and completion fences remain separate required
evidence. Possible execution after process exit stays in the lifetime upper bound
without extending the registered percentage denominator. Reports preserve these
bounds instead of substituting a guessed owner or zero.

## Persistent full-chart Metal candidate

`runtime-metal-full-chart` replaces the chart's static Canvas, rail decoration
Canvas, and cursor Canvas with one persistent `MTKView`. SwiftUI retains labels,
axes, controls, inspection, selection, and accessibility. Immutable scenes retain
series fills, strokes, glows, endpoints, tool traces, and request bars between
publications. Cursor movement updates a separate buffer. The geometry cache skips
unused SwiftUI `Path` construction in this mode only.

Arrival particles and glints evaluate time in shaders. Completion lightning
uses a GPU compute pass over immutable channel descriptors, followed by a render
pass; its initial and delayed bursts use the same retained particle descriptors.
Native scheduling retains the existing receipt lifetimes, twinkle sequence,
30 Hz animation rate, and 1 Hz chart publication rate. It pauses in idle gaps and
releases native rendering resources when hidden, detached, minimized, or closed.
The static renderer batches primitives into one draw call, with bounded retained
scene versions and buffers. GPU completion releases leases without a successful
frame publishing a SwiftUI state update.

Run the unprofiled current/candidate/current comparison using frozen Release
products and reviewed provenance:

```sh
python3 scripts/run_performance_checks.py runtime compare \
  --baseline-mode normal --candidate-mode runtime-metal-full-chart \
  --app-binary /absolute/candidate-products/FluxLLMApp \
  --test-bundle /absolute/candidate-products/FluxLLMPackageTests.xctest \
  --collector-binary /absolute/candidate-products/FluxLLMResourceCollector \
  --provenance /absolute/candidate-products/provenance.json \
  --reference-app-binary /absolute/reference-products/FluxLLMApp \
  --reference-test-bundle /absolute/reference-products/FluxLLMPackageTests.xctest \
  --reference-provenance /absolute/reference-products/provenance.json \
  --output-dir .performance-results/full-chart-cpu

python3 scripts/run_performance_checks.py gpu-compare \
  --reference-products /absolute/reference-products \
  --candidate-products /absolute/candidate-products \
  --reference-mode normal --candidate-mode runtime-metal-full-chart \
  --output-dir .performance-results/full-chart-gpu
```

The CPU workload remains two concurrent 200 Hz streams for 25 seconds. GPU uses
the separately identified eight-second workload above; traced CPU cannot pass
the CPU target. Both commands have a 300-second ceiling. The full-chart contract
requires actual static, arrival, completion, and twinkle submissions in the
corresponding phases, zero Canvas/bitmap/frame-clock work, no skipped frames or
renderer failures, and closed-window inactivity/resource release. A fallback to
Canvas invalidates the candidate instead of producing a misleading low result.

The independent static-chart fidelity test compares original Canvas cubic paths,
blur, gradients, dashes, and clips with the retained Metal renderer at 1× and 2×,
after asymmetric pixel/readback calibration. Enable it with
`FLUXLLM_FULL_METAL_FIDELITY=1` and an explicit
`FLUXLLM_FULL_METAL_FIDELITY_OUTPUT=.performance-results/<new-directory>`, then
run `swift test -c release --filter MetalFullChartFidelityTests`. It preserves all
Canvas, Metal, and difference PNGs and JSON metrics before asserting the existing
maximum difference of 2 per channel. Animated effects and text are outside this
static pixel test; separate functional tests verify effect timing and visible
GPU output without claiming pixel equivalence.

Measurements are preserved even when independent visual qualification is still
pending or fails. The candidate is opt-in: measured CPU/GPU differences do not
establish pixel equivalence or grant production promotion. Strict fidelity and
frame delivery remain separate evidence from resource consumption.

### Cached Metal chart with retained glints

`runtime-metal-cached-chart` is a separate experimental control. It retains a
private GPU texture containing the static chart, refreshing it when the scene,
revision, drawable dimensions, or backing scale changes. Animation frames copy
that texture before drawing transient effects and the cursor. The copy uses a
texture render pass, with no CPU pixel readback. Texture generations and in-flight
leases remain bounded and are released when the native host is hidden or closed.

During ordinary streaming, glints use the existing retained Core Animation
shapes. Their spawn/expiry deadlines update those shapes without starting the
Metal display clock or redrawing the chart. While lifecycle effects or a cursor
overlap, the host retains Metal glints to preserve the original drawing order;
retained glints resume at their original age afterward. Data publication remains
1 Hz and transient Metal animation remains 30 Hz.

Use `--candidate-mode runtime-metal-cached-chart` in the frozen CPU comparison
above. Run separate reference/candidate/reference commands with `--baseline-mode
normal` and `--baseline-mode runtime-metal-full-chart` and their corresponding
frozen reference products. Each command retains the 300-second ceiling. For the
independent short GPU capture, use `--candidate-mode runtime-metal-cached-chart
--capture-case candidate`. Original baseline and prior GPU captures retain their
own identities and timestamps; they are not relabeled as fresh paired controls.

The automated contract requires positive cached compositions and retained glint
animations, fewer static rasterizations than compositions, no steady Metal
animation clock or shader glint frames, submissions bounded by actual scene and
surface invalidations,
and complete inactivity/resource release after close. Offscreen tests compare
cached output with direct Metal output at 1× and 2× and exercise invalidation and
resource lifetime. Equality to direct Metal does not resolve that renderer's
separate strict Canvas fidelity requirement or permit production promotion.
Scene counters classify publication, axis-scale, layout, appearance and rail
changes; unclassified revisions reject the run. Prepared-history counts alone
cannot bound rasterization because axis-scale hysteresis can change geometry
without another history preparation. The 1 Hz preparation and exact-work checks
remain independent of these cache-invalidation counters.

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
