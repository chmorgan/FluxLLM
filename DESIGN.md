# FluxLLM design

FluxLLM is a Swift 6, macOS 15+ menu-bar app for observing LLM inference. It shows backend throughput and this
Mac's total GPU utilization in a compact popover or a persistent dashboard. Settings owns connection setup and
diagnostics.

## Ownership and data flow

The executable creates one `AppSettings`, `MetricsStore`, `MonitoringCoordinator`,
`LaunchAtLoginController`, and AppKit `MenuBarController`. SwiftUI renders their state; it does not own listeners.

```text
Native backend HTTP metrics ── BackendSample ───────────┐
Client → Ollama proxy → Ollama                         │
           └─ observed response → GenerationEvent ─────┼→ MetricsStore → UI
macOS GPU utilization ──────── GPUActivitySample ───────┘
```

The coordinator owns one selected backend session and its collectors. Applying settings cancels the previous
session; epoch checks reject delayed results. Observable state changes run on the main actor. Ordered proxy
events pass through a coalescing inbox: cumulative progress may replace older pending progress, while lifecycle
transitions and tool events retain order. Forwarded response bytes are independent of telemetry delivery.

Launch at login is opt-in and uses `SMAppService.mainApp`. macOS owns its state; no separate preference is
persisted. The General toggle applies immediately, independently of connection preferences. Pending
approval remains requested but is clearly identified as unable to launch until allowed in System Settings.
Status refreshes whenever Settings opens or the app becomes active. Login launches reuse the normal quiet
menu-bar startup path. Registration changes are serialized, and failures show the actual system status.

## Backends and selection

| Backend | Default upstream | Throughput source |
|---|---|---|
| Ollama | `http://localhost:11434` | Observed native `/api/chat` and `/api/generate` responses |
| vLLM | `http://127.0.0.1:8000` | `/metrics` generated-token counter deltas over monotonic elapsed time |
| Rapid-MLX | `http://127.0.0.1:8000` | `/v1/status` server-reported average |
| llama.cpp | `http://127.0.0.1:8080` | `/slots` decoded-token counter deltas; `/metrics` throughput gauge fallback |
| Unsloth | Studio at `http://127.0.0.1:8888` | Managed local GGUF worker's llama.cpp collector |

Native collectors observe direct client traffic without a proxy or Prometheus installation. vLLM needs two valid
scrapes; resets, changed series, or gaps reset the baseline. llama.cpp requires `--metrics`; router mode
requires a model selection and uses `autoload=false`. Native token totals are server totals.

Discovery probes configured endpoints and these loopback defaults using bounded, read-only requests.
Backend-specific responses establish identity; a port or generic OpenAI-compatible model list does not. Automatic selection
retains its previous detected choice or selects a sole detection; unresolved choices go to Settings. Manual
selection remains in effect for the current launch. Scan Again does not restart collection.

Unsloth discovery verifies its managed Studio launch, worker ancestry, PID birth identity, and native
listening sockets. The configured Studio address stays stable while the worker's port changes. Cached
libproc inspection avoids spawning process-list helpers or scanning unrelated sockets on each poll.
The native llama.cpp collector supplies live throughput when the worker's `/slots` endpoint is enabled,
with the server-reported average as a fallback when slots are disabled or unavailable. Token totals remain
server totals. Active slot/task identities supply passive request lanes, with first-seen starts and
sampled observation endings. Missing polls expire identities independently of aggregate activity;
worker/source epochs and decoded-counter resets keep reused identities separate. The in-memory
tracker retains at most 256 lanes for one hour without adding authoritative usage records.
An explicitly supplied, session-only worker API key authorizes metrics, properties, and slots
GETs only after local worker verification. Worker authentication failures remain explicit during
discovery, and changing the supplied key invalidates worker capabilities and throughput baselines.
Worker credentials are kept separate from Studio credentials and never sent to other backends.
An explicitly supplied, session-only Studio sign-in token enables bounded authenticated GETs to
`/api/inference/monitor`. The adapter retains only scalar identity, timing, status, usage, and rate
metadata from its at-most-50 retained entries. Disabled or unavailable history falls back to slots;
an omitted monitor entry cannot establish completion. Neither endpoint exposes structured tool
activity, and no Studio event-stream listener is attached. Remote Studio and non-GGUF/training
backends are outside this adapter's scope.

App settings read existing saved preferences at startup for compatibility. Changes to backend selection,
endpoints, menu-bar preferences, and automatic-selection memory apply only to the current launch. They do not
write preferences or migrate a legacy preferences domain. Diagnostic logging starts disabled each launch.
The macOS-owned launch-at-login registration remains independent of these session preferences.

Ollama clients must target the loopback proxy, normally `http://127.0.0.1:11435`. Only routed native generation
traffic is measured. The proxy starts whenever Ollama is selected; persisted `autoStartProxy` is legacy state.
It uses HTTP upstream, one request per connection, and a 1 MiB request-body limit. Streaming response bodies
forward incrementally. It is not a general OpenAI-compatible gateway. Authentication configuration is not
implemented.

## Measurement and freshness

Ollama live counts estimate tokens by counting nonempty parsed text/thinking deltas, not TCP reads or tokenizer
tokens. The rate divides that count by elapsed time since the first text. Valid final usage replaces the newest
request's count; its completed-request average is `eval_count × 1,000,000,000 / eval_duration`. Non-streaming
usage appears at completion. Final averages are not live activity.

llama.cpp and Unsloth live throughput sums per-slot decoded-token count changes over monotonic elapsed
time, combining concurrent requests. Active collection adds one bounded, read-only `/slots` request per
poll; idle polling adds none. Startup, new requests, counter resets, and outages require fresh baselines
so counts cannot bridge unrelated requests or gaps. Verified Unsloth worker changes also clear slot and
capability state. Direct llama.cpp workers without a process-start metric require a session reset after
a same-address restart.

Native request hover averages divide the decoded-count increase by the time between the first and
latest valid counter observations. Initial counts are excluded because generation may predate
collection. The average is marked approximate and remains unavailable until two valid observations
span positive time. Missing counts do not extend its window; idle detection, expiry, and repeated
terminal monitor rows retain the last measured average. Slot resets restart observation; Studio
usage corrections rebaseline the counter window while preserving the request identity.

Healthy slot counter baselines are explicitly unmeasured: numeric displays show zero, while raw
throughput remains unavailable until a measurable interval. The latest successful slot snapshot supplies
current running activity, so a request finishing between `/metrics` and `/slots` reads clears its running
count.

Backend and GPU polling normally occur every second; failed backend polls back off to 30 seconds, and unresolved
discovery retries every five seconds. History samples every half-second. Numeric throughput publishes once
per second; coherent chart snapshots publish once per second while a chart surface is visible, with immediate
clearing/reset transitions. Ollama's numeric estimate waits for one second of output: healthy loading and
warmup display zero while raw post-output history can already contain estimates. Help and metadata preserve measurement basis despite plain numeric labels.

Slot-derived llama.cpp and Unsloth numeric throughput uses a three-second time-weighted average, refreshed
once per second. Poll measurements and chart samples retain raw rates. Smoothing resets on session, model,
measurement-basis, idle, error, or warmup transitions, preventing old worker or request speeds from carrying
into a new baseline. Errors and stale data remain visible; displaying zero during healthy warmup does not
create a measured raw rate.

Health, request output, native activity counts, and GPU readings have separate freshness evidence, generally
expiring after five seconds. Successful health polling cannot refresh stale output rates. Outstanding observed
requests remain Active through health failures. Native positive counts mean Active, both zero means Idle,
and incomplete counts without positive evidence mean Unknown. GPU use never determines request activity.

## Concurrent Ollama requests and tools

Each open request contributes its fresh live rate to an aggregate sum and retains its own rail identity.
Completion removes it from that sum. The newest-started request still owns model, usage, final average, and
display availability for the live presentation. Consequently, its loading, warmup, completion, or stale state can zero or hide the
aggregate reading even while an older request streams; loading/staleness can also override sampled throughput.
This is a current concurrency limitation.

Finished rails retain final per-request output usage when reported, including corrections to live estimates.
Failure or cancellation without a final snapshot retains the latest count and its estimate status. Request
inspection describes the whole request rather than historical cursor-time counts; its average includes
loading and waiting time, unlike Ollama's evaluation-only completed-request rate.

The dashboard Usage row aggregates independently of the chart, scoped to the selected endpoint. Since launch
includes all monitored requests in this process, including active estimates, and survives collection restarts.
Selected period attributes a request's full usage to its completion time; adjacent intervals are half-open
so boundary completions cannot count twice. Today uses the local calendar day and includes completions observed
in this launch and active requests started today. Tool calls use their event timestamps for both period scopes.
Missing input usage remains unknown; a known subtotal carries `+` when other requests have unknown input. Estimated output
carries `~`. Duplicate request and tool events are deduplicated; final usage replaces estimates rather than
being added to them. Server-native counters retain their separate server-total labels and semantics.

Native response tool calls are discrete events deduplicated by explicit call ID or function index. Anonymous
calls remain separate. Trailing tool-role messages record **Tool results submitted**, not execution or duration.
All retained requests can contribute tool events. Telemetry retains names and identifiers, not argument/result
content. Tool rates divide calls by observed bucket duration; missing exposure does not become an invented rate.

## System GPU scope

The GPU loop starts after initial discovery and then runs independently, including with no backend selected. It
reads IOKit driver utilization counters for this Mac, including other applications, even when inference is
remote. Unique devices contribute equally to a normalized 0–100% average; devices are not weighted by computing
power. Missing, invalid, or conflicting device readings make the whole metric unavailable. A measured zero
remains valid.

These driver fields are not a stable OS API, so hardware support varies. The separate process-GPU diagnostic
collector measures execution-time ratios, which may exceed 100%; it is not the default dashboard metric.

## Presentation and history

FluxLLM starts in the menu bar without opening a window or showing a Dock icon. Opening the dashboard
shows the app in the Dock and Cmd-Tab until the dashboard closes; minimizing or hiding it keeps that entry.
A Dock click restores the existing dashboard, including from its minimized state. Closing the dashboard
returns to menu-bar-only operation while monitoring continues. Settings and the popover do not change this policy.

The status item combines optional branding and tokens/s with labeled T/G meters. T uses a recent raw throughput
peak; G uses 0–100%. One activity card combines cyan generated throughput on an adaptive scale and purple System
GPU on a fixed scale. Ollama adds an amber tool track with its own calls/min scale.

The popover shows the last minute. The resizable dashboard adapts its layout and scrolls below its readable
content floor. Its range menu offers Auto, 1m, 5m, 15m, 30m, 1h, 6h, 24h, and Custom. Relative presets follow
live collection; custom ranges, drag-to-zoom, request fitting, and arrow navigation pin the view while
collection continues. Live resumes a moving window of the selected duration. Request fitting is available
through a rail's double-click and context menu. Windows are bounded to the retained last 24 hours. Auto growth
uses held chart-publication time. Epoch-aligned chart means adapt to the visible duration, shared by drawing,
scaling, and inspection. Unavailable observations are excluded from
means. Generated/tool gaps draw through a presentation-only zero baseline; GPU sensor gaps remain gaps.

Five stable reusable request rails and a sixth overflow row occupy a reserved dashboard band. Identity colors
and row assignments survive publications and range changes. The popover omits rails. Region-specific hover cards
show smoothed graph values, tool buckets, a request summary, or bounded overflow names. Request cards use two lines:
model and state, then full request duration, average output tokens/s, and output tokens. The average divides
the retained output count by that duration, including loading and waiting; active requests use chart
publication time and ended requests use their finish time, independently of cursor position. Final usage
replaces stream estimates, and estimated counts and averages carry a `~` prefix. Decorative lifecycle effects
use a separate clock, pause when hidden, and respect accessibility settings; they do not alter measurements.

Raw histories use bounded rings retaining one hour with at most 7,201 samples each. Insertion, expiry, and
same-timestamp replacement do not shift the retained hour or copy the last presentation snapshot. An
independent in-memory archive keeps 24 hours of minute means weighted by sample count, with explicit collection
gaps and source boundaries. Its bounded rings retain segment flags and expire old prefixes without rebuilding
all retained buckets. Archived means cannot be expanded into finer samples when zooming. Whole archived buckets overlapping the raw buffer are omitted
to avoid double counting, leaving at most a minute of missing coverage at the boundary. Tool observations
retain their actual continuous spans for exposure-based rates. Archived means never imply a fresh live rate.

Recent tool events are capped at 10,000, trimming corresponding observation coverage if exceeded. The separate
usage ledger retains up to 20,000 request records and 50,000 tool events for 30 days. Detail eviction does not
reduce Since launch counters; incomplete period history is labeled. Charts prioritize active requests, then
the newest completed requests up to 256 displayed records, with an omitted-count notice in busy periods.
Per-request tool charts are prepared only for rendered requests. Live lifecycle state continues updating while
the viewport is pinned; historical views suppress animation.

All history belongs to the current application session. A new launch starts empty; there are no history
readers, writers, save timers, migrations, or shutdown flushes. Existing files under
Application Support/FluxLLM/History are ignored and left untouched, including corrupt or unsupported files.
Source keys include backend kind, endpoint without credentials/query, and configured model. Request history
holds counts, timing, model/tool names, and identifiers, with no prompt, response, argument, or result contents.

The usage ledger shares metadata through reference-counted interned slots, releasing names when retained
records expire. Exact since-launch totals are updated incrementally. Complete-hour aggregates accelerate
period queries; exact completion and tool-event timestamps handle interval edges, preserving half-open
boundaries and later authoritative corrections. Retained timestamp indices are rebuilt only when membership
changes. Existing record and event caps remain explicit: selected-period queries mark missing detail as partial
while since-launch counters survive eviction.

Native dashboard and popover hosts request chart presentation only while visible. Closing, minimizing, or
occluding a surface releases its host and prepared charts while collection continues. The last consumer
closing releases the store's presentation arrays; reopening immediately prepares the latest retained data.
Navigation and request identities survive this suspension. The status meter queries an inclusive recent peak
directly from the raw ring; it does not materialize the retained hour to calculate that scalar.

Tests compare optimized accounting and archives with reference histories, exercise wraparound and retention,
and verify that new sessions start empty and legacy paths are untouched. The synthetic resource fixture uses
the same in-memory ingestion paths and validates that optimization does not discard its required history.

## Diagnostic logging and resource limits

Diagnostic logging is separate from usage and chart history and is disabled by default. Disabled logging does
not construct records, encode data, create directories, or schedule file work. Opt-in logs contain fixed event
categories, backend kind, request identifiers, timing, and numeric counts; they exclude prompt and response
text, tool arguments, and result contents. They are never loaded to restore dashboard history.

One serial writer has a 128 KiB queue limit including its in-flight batch, writes batches no larger than
16 KiB, and rotates at most three files of 1 MiB each. Overflow drops diagnostic records and increments an
in-memory dropped count instead of blocking telemetry or growing the queue. File errors are surfaced in
Settings. Logging preference changes are session-only, so the next launch starts with logging disabled.

The resource regression acceptance limits are CPU at most 5% of one core, lifetime physical footprint strictly
below 64,000,000 bytes, process GPU execution time at most 1% of elapsed time, and zero app-attributed disk writes
with diagnostic logging disabled. Chart preparation has a 15 ms limit per publication. These are acceptance
limits, not a claim that every build meets them. The process GPU check is separate from the dashboard's
whole-Mac utilization reading. See [performance checks](docs/performance.md) for the workload, measurement
coverage, and validation protocol.

## Source map

- [Backends](Sources/FluxLLM/Backends), [OllamaProxy](Sources/FluxLLM/OllamaProxy),
  [GPU](Sources/FluxLLM/GPU): acquisition and lifecycle.
- [Telemetry](Sources/FluxLLM/Telemetry): contracts, settings, state, retention.
- [System](Sources/FluxLLM/System): macOS login-item registration and status.
- [UI](Sources/FluxLLM/UI): AppKit hosting, charts, rails, inspection, Settings.
- [Tests](Tests/FluxLLMTests) and [scripts](scripts): regression tests and local fixtures.
- [Branding](Resources/Branding/README.md): artwork sources and reproduction.
  The [signal-rail HTML fixture](design/fluxllm/previews/request-signal-rails.html)
  supplies the reference palette checked by tests.
