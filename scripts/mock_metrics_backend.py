#!/usr/bin/env python3
"""Paced, synthetic vLLM, Rapid-MLX, llama.cpp, and Unsloth monitoring fixtures.

The client sends OpenAI-compatible requests directly to this server. FluxLLM
only reads its metrics/status endpoints. No proxy or real model is involved.
"""

import argparse
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from socketserver import TCPServer
import threading
from urllib.parse import urlsplit


BACKENDS = ("vllm", "rapid-mlx", "llama.cpp", "unsloth")
TOKENS_PER_CHUNK = 2
PROMPT_TOKENS = 12
FRAGMENTS = ("Synthetic", " FluxLLM", " fixture", " output", " for", " live", " charts", ". ")
MAX_REQUEST_BYTES = 1 << 20


@dataclass(frozen=True)
class FixtureConfig:
    backend: str = "vllm"
    pace: float = 0.2
    chunks: int = 80
    ready: bool = True
    metrics_enabled: bool = True
    quiet: bool = False

    def __post_init__(self):
        if self.backend not in BACKENDS:
            raise ValueError("unknown backend: " + self.backend)
        if not math.isfinite(self.pace) or not 0 <= self.pace <= 60:
            raise ValueError("pace must be between 0 and 60 seconds")
        if not 1 <= self.chunks <= 10000:
            raise ValueError("chunks must be between 1 and 10000")

    @property
    def model(self):
        return "Fixture/" + self.backend + "-synthetic"

    @property
    def reported_rate(self):
        # Synthetic decode duration is pace per fragment, with a 1 ms minimum
        # for fast tests. A fragment represents exactly two fixture tokens.
        return TOKENS_PER_CHUNK / max(self.pace, 0.001)


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, config, before_chunk=None):
        self.config = config
        self.before_chunk = before_chunk
        self.stopping = threading.Event()
        self.lock = threading.Lock()
        self.sequence = 0
        self.requests = {}
        self.output_tokens = 0
        self.prompt_tokens = 0
        self.completed_output_tokens = 0
        self.completed_prompt_tokens = 0
        self.completed_requests = 0
        self.loaded = config.ready
        self.model = config.model
        self.metrics_enabled = config.metrics_enabled
        self.metrics_status = 200
        super().__init__(address, FixtureHandler)

    def server_bind(self):
        # HTTPServer adds a reverse-hostname lookup that can block on CI.
        # This fixture only needs its bound address and allocated port.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def begin(self, expected_model):
        with self.lock:
            if not self.loaded or self.model != expected_model:
                raise ValueError("fixture worker changed before request started")
            self.sequence += 1
            request_id = "fixture-{}".format(self.sequence)
            self.requests[request_id] = 0
            self.prompt_tokens += PROMPT_TOKENS
            return request_id

    def emit(self, request_id):
        with self.lock:
            self.requests[request_id] += TOKENS_PER_CHUNK
            self.output_tokens += TOKENS_PER_CHUNK

    def finish(self, request_id):
        with self.lock:
            self.completed_output_tokens += self.requests.pop(request_id)
            self.completed_prompt_tokens += PROMPT_TOKENS
            self.completed_requests += 1

    def reset(self):
        with self.lock:
            if self.requests:
                return False
            self.output_tokens = self.prompt_tokens = 0
            self.completed_output_tokens = self.completed_prompt_tokens = 0
            self.completed_requests = 0
            return True

    def snapshot(self):
        with self.lock:
            return {
                "running": len(self.requests),
                "requests": [{"request_id": key, "status": "running", "generated_tokens": value}
                             for key, value in sorted(self.requests.items())],
                "output": self.output_tokens,
                "prompt": self.prompt_tokens,
                "completed_output": self.completed_output_tokens,
                "completed_prompt": self.completed_prompt_tokens,
                "completed_requests": self.completed_requests,
                "loaded": self.loaded,
                "model": self.model,
                "metrics_enabled": self.metrics_enabled,
                "metrics_status": self.metrics_status,
            }

    def set_state(self, changes):
        """Explicit external fixture control; metrics scrapes never mutate state.

        A model load/unload has fresh counters, matching a new llama.cpp worker.
        Reject every state change during a stream so no request spans identities.
        """
        allowed = {"loaded", "model", "metrics_enabled", "metrics_status"}
        if not isinstance(changes, dict) or not changes or set(changes) - allowed:
            raise ValueError("provide loaded, model, metrics_enabled, or metrics_status")
        for name in ("loaded", "metrics_enabled"):
            if name in changes and type(changes[name]) is not bool:
                raise ValueError(name + " must be true or false")
        if "model" in changes and (not isinstance(changes["model"], str)
                                   or not 1 <= len(changes["model"]) <= 256
                                   or any(ord(c) < 32 or c in '\\"' for c in changes["model"])):
            raise ValueError("model must be a nonempty bounded printable identifier")
        if "metrics_status" in changes and (type(changes["metrics_status"]) is not int
                                              or changes["metrics_status"] not in (200, 401, 403, 404, 503)):
            raise ValueError("metrics_status must be 200, 401, 403, 404, or 503")
        with self.lock:
            if self.requests:
                return False
            new_loaded = changes.get("loaded", self.loaded)
            new_model = changes.get("model", self.model)
            if new_loaded != self.loaded or new_model != self.model:
                self.output_tokens = self.prompt_tokens = 0
                self.completed_output_tokens = self.completed_prompt_tokens = 0
                self.completed_requests = 0
            self.loaded, self.model = new_loaded, new_model
            self.metrics_enabled = changes.get("metrics_enabled", self.metrics_enabled)
            self.metrics_status = changes.get("metrics_status", self.metrics_status)
            return True

    def server_close(self):
        self.stopping.set()
        super().server_close()


def create_server(host="127.0.0.1", port=8000, config=None, before_chunk=None):
    """Return an unstarted server; port 0 allocates an available test port.

    before_chunk(request_id, index) may block a stream for deterministic tests.
    Release gates before shutdown. The caller owns shutdown and server_close.
    """
    return FixtureServer((host, port), config or FixtureConfig(), before_chunk)


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FluxLLMMetricsFixture/1"

    def log_message(self, format_string, *args):
        if not self.server.config.quiet:
            super().log_message(format_string, *args)

    def send_body(self, status, body, content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send_json(self, status, value):
        self.send_body(status, json_bytes(value))

    def do_GET(self):
        endpoint = urlsplit(self.path).path
        config = self.server.config
        state = self.server.snapshot()
        if endpoint == "/health":
            self.send_json(200 if state["loaded"] else 503, {"status": "ok" if state["loaded"] else "loading", "fixture": True})
        elif endpoint == "/v1/models":
            self.send_json(200, {"object": "list", "data": [{"id": state["model"], "object": "model", "created": 0,
                                                          "owned_by": "FluxLLM synthetic fixture"}] if state["loaded"] else []})
        elif endpoint == "/metrics" and state["metrics_enabled"]:
            status = state["metrics_status"] if state["loaded"] else 503
            if status == 200:
                self.send_body(200, self.metrics(state).encode("utf-8"), "text/plain; version=0.0.4; charset=utf-8")
            else:
                self.send_json(status, {"error": "synthetic monitoring endpoint unavailable", "fixture": True})
        elif endpoint == "/v1/status" and config.backend == "rapid-mlx":
            self.send_json(200, {
                "status": "not_loaded" if not state["loaded"] else "generating" if state["running"] else "idle",
                "model": state["model"], "num_running": state["running"], "num_waiting": 0,
                "requests": state["requests"],
                # Intentionally persists after completion, like the server's
                # reported average. The client must gate it on activity.
                "generation_tps": config.reported_rate if state["output"] else 0,
                "total_completion_tokens": state["completed_output"],
                "total_prompt_tokens": state["completed_prompt"],
                "fixture": True,
            })
        elif endpoint == "/props" and config.backend in ("llama.cpp", "unsloth"):
            self.send_json(200, {
                "default_generation_settings": {}, "total_slots": 4,
                "model_alias": state["model"], "endpoint_metrics": state["metrics_enabled"],
                "build_info": "0.0.0-fluxllm-fixture", "fixture": True,
            })
        elif endpoint == "/fixture/status":
            self.send_json(200, state)
        else:
            self.send_json(404, {"error": "fixture route not found"})

    def metrics(self, state):
        config = self.server.config
        lines = ["# Synthetic FluxLLM fixture metrics; not real inference or GPU load."]
        if config.backend == "vllm":
            metrics = {
                "generation_tokens_total": state["output"], "prompt_tokens_total": state["prompt"],
                "num_requests_running": state["running"], "num_requests_waiting": 0,
            }
            labels = '{model_name="' + state["model"] + '",engine="0"}'
            for name, value in metrics.items():
                lines += ["# TYPE vllm:{} {}".format(name, "counter" if name.endswith("_total") else "gauge"),
                          "vllm:{}{} {}".format(name, labels, value)]
        elif config.backend == "rapid-mlx":
            lines += ['# TYPE rapid_mlx_build_info gauge',
                      'rapid_mlx_build_info{version="0.0.0-fluxllm-fixture"} 1',
                      "rapid_mlx_completion_tokens_total {}".format(state["completed_output"])]
        else:
            metrics = {
                "tokens_predicted_total": state["completed_output"],
                "prompt_tokens_total": state["completed_prompt"],
                "predicted_tokens_seconds": config.reported_rate if state["output"] else 0,
                "requests_processing": state["running"], "requests_deferred": 0,
            }
            for name, value in metrics.items():
                lines += ["# TYPE llamacpp:{} {}".format(name, "counter" if name.endswith("_total") else "gauge"),
                          "llamacpp:{} {}".format(name, value)]
        return "\n".join(lines) + "\n"

    def do_POST(self):
        endpoint = urlsplit(self.path).path
        if endpoint == "/fixture/state":
            try:
                changes = self.read_request_json()
                changed = self.server.set_state(changes)
            except (ValueError, UnicodeDecodeError) as error:
                self.send_json(400, {"error": str(error)})
                return
            if changed:
                self.send_json(200, {"fixture": True, "state": self.server.snapshot()})
            else:
                self.send_json(409, {"error": "fixture state change requires no running requests"})
            return
        if endpoint == "/fixture/reset":
            # Explicit test-only control: a GET or a metrics scrape never resets
            # counters, and an in-flight request cannot cross a reset boundary.
            if self.server.reset():
                self.send_json(200, {"fixture": True, "reset": True})
            else:
                self.send_json(409, {"error": "fixture reset requires no running requests"})
            return
        if endpoint != "/v1/chat/completions":
            self.send_json(404, {"error": "fixture route not found"})
            return
        try:
            body = self.read_request_json()
            if not isinstance(body, dict):
                raise ValueError("request body must be a JSON object")
            stream = body.get("stream", False)
            if not isinstance(stream, bool):
                raise ValueError("stream must be true or false")
            state = self.server.snapshot()
            if body.get("model", state["model"]) != state["model"]:
                raise ValueError("use fixture model " + state["model"])
        except (ValueError, UnicodeDecodeError) as error:
            self.send_json(400, {"error": str(error)})
            return
        if not state["loaded"]:
            self.send_json(503, {"error": "fixture model is not ready"})
            return
        self.generate(stream, state["model"])

    def read_request_json(self):
        if self.headers.get("Transfer-Encoding"):
            raise ValueError("fixture expects a Content-Length request body")
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= MAX_REQUEST_BYTES:
            raise ValueError("request body must be between 1 byte and 1 MiB")
        return json.loads(self.rfile.read(length))

    def generate(self, stream, model):
        config = self.server.config
        try:
            request_id = self.server.begin(model)
        except ValueError as error:
            self.send_json(503, {"error": str(error)})
            return
        fragments = []
        if stream:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
        try:
            for index in range(config.chunks):
                if self.server.before_chunk is not None:
                    self.server.before_chunk(request_id, index)
                if self.server.stopping.is_set():
                    return
                fragment = FRAGMENTS[index % len(FRAGMENTS)]
                fragments.append(fragment)
                self.server.emit(request_id)
                if stream:
                    self.send_event(self.chunk(request_id, {"content": fragment}, model))
                if self.server.stopping.wait(config.pace):
                    return
            usage = {"prompt_tokens": PROMPT_TOKENS, "completion_tokens": config.chunks * TOKENS_PER_CHUNK,
                     "total_tokens": PROMPT_TOKENS + config.chunks * TOKENS_PER_CHUNK}
            # Publish completed counters before the terminal event/response so
            # a client that has received EOF can immediately observe idle state.
            self.server.finish(request_id)
            request_id_finished = request_id
            request_id = None
            if stream:
                self.send_event(self.chunk(request_id_finished, {}, model, finish_reason="stop"))
                self.send_event({"id": request_id_finished, "object": "chat.completion.chunk", "created": 0,
                                 "model": model, "choices": [], "usage": usage})
                self.send_event("[DONE]")
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            else:
                self.send_json(200, {"id": request_id_finished, "object": "chat.completion", "created": 0,
                                     "model": model, "choices": [{"index": 0, "message": {
                                         "role": "assistant", "content": "".join(fragments)}, "finish_reason": "stop"}],
                                     "usage": usage})
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if request_id is not None:
                self.server.finish(request_id)

    def chunk(self, request_id, delta, model, finish_reason=None):
        return {"id": request_id, "object": "chat.completion.chunk", "created": 0,
                "model": model,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish_reason}]}

    def send_event(self, value):
        payload = b"data: " + (value.encode("ascii") if isinstance(value, str) else json_bytes(value)) + b"\n\n"
        self.wfile.write(format(len(payload), "x").encode("ascii") + b"\r\n" + payload + b"\r\n")
        self.wfile.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog="""Manual POC (native monitoring, no proxy):
  python3 scripts/mock_metrics_backend.py --backend vllm --port 8000
  In FluxLLM Settings, select vLLM at http://127.0.0.1:8000, or Automatic.
  curl -N http://127.0.0.1:8000/v1/chat/completions -H 'Content-Type: application/json' \\
    -d '{"model":"Fixture/vllm-synthetic","messages":[{"role":"user","content":"hello"}],"stream":true}'

Use --backend rapid-mlx (model Fixture/rapid-mlx-synthetic) or
--backend llama.cpp --port 8080 (model Fixture/llama.cpp-synthetic).
Use --backend unsloth --port 0 for an external synthetic Unsloth llama.cpp
worker on a dynamically allocated port (model Fixture/unsloth-synthetic).
Each fragment represents two SYNTHETIC tokens. vLLM counters advance during
generation. llama.cpp and Rapid-MLX totals advance at completion; their reported
average persists after completion, and activity must be read separately.
Default: 80 fragments at 0.2 s intervals (16 s, synthetic rate 10 tokens/s).
GET /health and /v1/models are common; backend-specific metrics/status/props
match FluxLLM discovery. POST /fixture/reset clears idle counters, or returns
409 while running. --not-ready exercises unloaded Rapid-MLX; --no-metrics
exercises llama.cpp without --metrics. These are synthetic local fixtures.
GET /fixture/status observes fixture state. POST /fixture/state explicitly
sets loaded, model, metrics_enabled or metrics_status (200/401/403/404/503).
Changes require idle streams; load/unload/model changes reset worker counters.
Ctrl-C stops the fixture; all handler threads stop with the process.
""")
    parser.add_argument("--backend", choices=BACKENDS, default="vllm")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000, help="0 allocates a free port (default: 8000)")
    parser.add_argument("--pace", type=float, default=0.2)
    parser.add_argument("--chunks", type=int, default=80)
    parser.add_argument("--not-ready", action="store_true")
    parser.add_argument("--no-metrics", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)
    try:
        if not 0 <= args.port <= 65535:
            raise ValueError("port must be between 0 and 65535")
        config = FixtureConfig(args.backend, args.pace, args.chunks, not args.not_ready, not args.no_metrics, args.quiet)
        server = create_server(args.host, args.port, config)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print("Synthetic {} fixture listening on http://{}:{}; model {} (Ctrl-C to stop)".format(
        config.backend, *server.server_address, config.model), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
