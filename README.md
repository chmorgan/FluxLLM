# FluxLLM

## Origin

I wanted to see what ollama was going on my MacBook and couldn't find a status bar app that I liked. Here is the product of lots of AI prompts to tweak the look and feel and operation to what I thought would be a neat looking tool. I hope you enjoy it as much as I do.

If there is something you'd like tweaked or fixed feel free to open issues or PRs.

## Features

A macOS 15+ menu bar app for monitoring LLM inference with Ollama, vLLM,
Rapid-MLX, and llama.cpp. Shows token throughput, activity history, and this
Mac’s total GPU utilization.

Choose a backend in Settings. For Ollama, point clients using `/api/chat` or
`/api/generate` at `http://127.0.0.1:11435`; the default upstream is
`localhost:11434`. Other backends are monitored directly through their metrics
or status endpoints.

The dashboard's **Usage** row shows Ollama input/output tokens, tool calls, and
requests. Choose **Since launch**, **Selected period**, or **Today**; totals are
kept separately from the chart. `~` marks estimated output and `+` marks a known
input subtotal when some requests have not reported input usage.

Use the **History** menu for ranges through **24h**, or enter custom dates.
Drag across the chart to zoom, use the arrow buttons to move through history,
and select **Live** to follow new activity again. Double-click a request rail
or use its **Fit request** context menu to frame that request.

FluxLLM saves 24 hours of chart history and up to 30 days of bounded request
usage locally. Recent charts retain detailed samples; older history uses
minute averages. Saved usage contains counts, timing, model names, and tool
names—not prompt text, response text, tool arguments, or result contents.
History is separated by backend endpoint. Other backends continue to show
their server-reported token totals.

See [DESIGN.md](DESIGN.md) for architecture, measurement semantics, and limitations.
