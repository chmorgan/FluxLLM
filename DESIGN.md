# FluxLLM design

FluxLLM is a Swift 6, macOS 15+ menu-bar app for observing LLM inference. It shows backend throughput and this
Mac's total GPU utilization in a compact popover or a persistent dashboard. Settings owns connection setup and
diagnostics.

## Ownership and data flow

The executable creates one `AppSettings`, `MetricsStore`, `MonitoringCoordinator`, and AppKit
`MenuBarController`. SwiftUI renders their state; it does not own listeners.

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

## Backends and selection

| Backend | Default upstream | Throughput source |
|---|---|---|
| Ollama | `http://localhost:11434` | Observed native `/api/chat` and `/api/generate` responses |
| vLLM | `http://127.0.0.1:8000` | `/metrics` generated-token counter deltas over monotonic elapsed time |
| Rapid-MLX | `http://127.0.0.1:8000` | `/v1/status` server-reported average |
| llama.cpp | `http://127.0.0.1:8080` | `/metrics` server-reported throughput gauge |

Native collectors observe direct client traffic without a proxy or Prometheus installation. vLLM needs two valid
scrapes; resets, changed series, or gaps reset the baseline. llama.cpp requires `--metrics`; router mode
requires a model selection and uses `autoload=false`. Native token totals are server totals.

Discovery probes saved endpoints and these loopback defaults using bounded, read-only requests. Backend-specific
responses establish identity; a port or generic OpenAI-compatible model list does not. Automatic selection
retains its previous detected choice or selects a sole detection; unresolved choices go to Settings. Manual
selection persists. Scan Again does not restart collection.

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

Backend and GPU polling normally occur every second; failed backend polls back off to 30 seconds, and unresolved
discovery retries every five seconds. History samples every half-second. Numeric throughput and coherent chart
snapshots publish once per second, with immediate clearing/reset transitions. Ollama's numeric estimate waits
for one second of output: healthy loading and warmup display zero while raw post-output history can already
contain estimates. Help and metadata preserve measurement basis despite plain numeric labels.

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
so boundary completions cannot count twice. Today uses the local calendar day, including saved completions and
active requests started today. Tool calls use their event timestamps for both period scopes. Missing input
usage remains unknown; a known subtotal carries `+` when other requests have unknown input. Estimated output
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

Raw histories retain one hour with at most 7,201 samples each. An independent archive keeps 24 hours of minute
means weighted by sample count, with explicit collection gaps and source boundaries. Archived means cannot
be expanded into finer samples when zooming. Whole archived buckets overlapping the raw buffer are omitted
to avoid double counting, leaving at most a minute of missing coverage at the boundary. Tool observations
retain their actual continuous spans for exposure-based rates. Archived means never imply a fresh live rate.

Recent tool events are capped at 10,000, trimming corresponding observation coverage if exceeded. The separate
usage ledger retains up to 20,000 request records and 50,000 tool events for 30 days. Detail eviction does not
reduce Since launch counters; incomplete period history is labeled. Charts prioritize active requests, then
the newest completed requests up to 256 displayed records, with an omitted-count notice in busy periods.
Per-request tool charts are prepared only for rendered requests. Live lifecycle state continues updating while
the viewport is pinned; historical views suppress animation.

The app restores history from Application Support/FluxLLM/History and writes atomic snapshots off the main
actor (usage at most once per second; chart archive every 30 seconds), flushing on orderly shutdown. Source
keys include backend kind, endpoint without credentials/query, and configured model. Corrupt or unsupported
files remain untouched and expose a storage status; collection continues in memory. Request history stores
counts, timing, model/tool names, and identifiers, with no prompt, response, argument, or result contents.
Ordinary tests use memory-only stores; persistence tests use isolated temporary directories.

## Source map

- [Backends](Sources/FluxLLM/Backends), [OllamaProxy](Sources/FluxLLM/OllamaProxy),
  [GPU](Sources/FluxLLM/GPU): acquisition and lifecycle.
- [Telemetry](Sources/FluxLLM/Telemetry): contracts, settings, state, retention.
- [UI](Sources/FluxLLM/UI): AppKit hosting, charts, rails, inspection, Settings.
- [Tests](Tests/FluxLLMTests) and [scripts](scripts): regression tests and local fixtures.
- [Branding](Resources/Branding/README.md): artwork sources and reproduction.
  The [signal-rail HTML fixture](design/fluxllm/previews/request-signal-rails.html)
  supplies the reference palette checked by tests.
