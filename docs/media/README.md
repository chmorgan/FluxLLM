# FluxLLM preview media

Native captures of the running local FluxLLM app on **2026-09-28**. The app
reported version **0.1.0**. They show real Ollama activity using
`qwen3.8:27b-mlx-bf16`.

| File | View |
| --- | --- |
| [live-monitoring.gif](live-monitoring.gif) | Live request activity and throughput; 20 seconds at 8 frames per second. |
| [dashboard.png](dashboard.png) | Throughput, total system GPU utilization, request timelines, tool activity, and usage. |
| [history.png](history.png) | A 30-minute activity history. |
| [settings.png](settings.png) | Backend connections and menu-bar preferences. |

Local source checkout at capture time:
`89323cd8d0e287da7101fdd9936824d98dc39986`.

The window title bars were cropped from the native captures, and the GIF was
resized to 865 pixels wide. Playback preserves the capture cadence; readings
were not fabricated or altered. Raw captures and temporary capture tooling
remain outside the repository in `/tmp/fluxllm-capture/`.
