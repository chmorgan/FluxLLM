#!/usr/bin/env python3
"""A deterministic, paced Ollama HTTP fixture using only the Python standard library.

Run ``python3 scripts/mock_ollama.py --help`` for manual POC scenarios.
Tests can import ``create_server`` and supply a ``before_chunk`` event gate.
"""

import argparse
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import threading
from typing import Callable, Optional
from urllib.parse import parse_qs, urlsplit


SCENARIOS = ("success", "http-error", "stream-error", "abort")
CREATED_AT = "2026-01-01T00:00:00Z"
DEFAULT_MODEL = "fixture-model:latest"
FRAGMENTS = (
    "FluxLLM", " keeps", " a", " compact", " view", " of", " local",
    " generation", " while", " you", " work", " at", " the", " café", ".", " ✓\n",
)
MAX_REQUEST_BYTES = 1 << 20


@dataclass(frozen=True)
class FixtureConfig:
    pace: float = 0.2
    chunks: int = 32
    scenario: str = "success"
    fragment_bytes: int = 0
    quiet: bool = False

    def __post_init__(self):
        if not math.isfinite(self.pace) or not 0 <= self.pace <= 60:
            raise ValueError("pace must be between 0 and 60 seconds")
        if not 1 <= self.chunks <= 10000:
            raise ValueError("chunks must be between 1 and 10000")
        if self.scenario not in SCENARIOS:
            raise ValueError("unknown scenario: " + self.scenario)
        if self.fragment_bytes < 0:
            raise ValueError("fragment-bytes must be nonnegative")


class FixtureServer(ThreadingHTTPServer):
    """Importable server; bind port 0 for an OS-assigned port in tests.

    ``before_chunk(index)`` runs before each NDJSON record, including the final
    record. A test can block index 1 with an Event after the first line flushes.
    Release any external gate before shutting down the server.
    """

    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, config, before_chunk=None):
        self.config = config
        self.before_chunk = before_chunk
        self.stopping = threading.Event()
        super().__init__(address, FixtureHandler)

    def server_close(self):
        self.stopping.set()
        super().server_close()


def create_server(
    host: str = "127.0.0.1",
    port: int = 11499,
    config: Optional[FixtureConfig] = None,
    before_chunk: Optional[Callable[[int], None]] = None,
) -> FixtureServer:
    """Bind and return a server; the caller owns serve_forever/shutdown/close."""
    return FixtureServer((host, port), config or FixtureConfig(), before_chunk)


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def generation_record(model, endpoint, content, done, chunks):
    record = {"model": model, "created_at": CREATED_AT, "done": done}
    if endpoint == "/api/chat":
        record["message"] = {"role": "assistant", "content": content}
    else:
        record["response"] = content
    if done:
        # Deliberately independent of network pacing: reconciliation is visible
        # in the UI. These synthetic final stats always yield 50 tokens/second.
        duration = chunks * 40_000_000
        record.update(
            done_reason="stop",
            total_duration=duration + 145_000_000,
            load_duration=25_000_000,
            prompt_eval_count=12,
            prompt_eval_duration=120_000_000,
            eval_count=chunks * 2,
            eval_duration=duration,
        )
    return record


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FluxLLMFixture/1"

    def log_message(self, format_string, *args):
        if not self.server.config.quiet:
            super().log_message(format_string, *args)

    def send_json(self, status, value):
        body = json_bytes(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        endpoint = urlsplit(self.path).path
        if endpoint == "/api/version":
            self.send_json(200, {"version": "0.0.0-fluxllm-fixture"})
            return
        if endpoint not in ("/api/tags", "/api/ps"):
            self.send_json(404, {"error": "fixture route not found"})
            return
        models = []
        for name, size in ((DEFAULT_MODEL, 4_000_000_000), ("fixture-small:latest", 1_000_000_000)):
            models.append({
                "name": name, "model": name, "modified_at": CREATED_AT,
                "size": size, "digest": "0" * 64,
                "details": {"format": "gguf", "family": "fixture", "parameter_size": "synthetic", "quantization_level": "Q4_0"},
            })
        if endpoint == "/api/ps":
            # A loaded model is not an active generation. This intentionally
            # advertises the fixture model even while the fixture is idle.
            models = [dict(models[0], expires_at="2099-01-01T00:00:00Z", size_vram=4_000_000_000)]
        self.send_json(200, {"models": models})

    def do_POST(self):
        endpoint = urlsplit(self.path).path
        if endpoint not in ("/api/generate", "/api/chat"):
            self.send_json(404, {"error": "fixture route not found"})
            return
        if self.headers.get("Transfer-Encoding"):
            self.send_json(400, {"error": "fixture expects a Content-Length request body"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 < length <= MAX_REQUEST_BYTES:
                raise ValueError("request body must be between 1 byte and 1 MiB")
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("request body must be a JSON object")
            stream = body.get("stream", True)
            if not isinstance(stream, bool):
                raise ValueError("stream must be true or false")
            model = body.get("model", DEFAULT_MODEL)
            if not isinstance(model, str) or not model:
                raise ValueError("model must be a nonempty string")
            scenario = self.scenario_for(body)
            if not stream and scenario in ("stream-error", "abort"):
                raise ValueError("stream-error and abort scenarios require stream: true")
        except (ValueError, UnicodeDecodeError) as error:
            self.send_json(400, {"error": str(error)})
            return

        if scenario == "http-error":
            self.send_json(503, {"error": "fixture: simulated upstream unavailable"})
            return
        fragments = [FRAGMENTS[index % len(FRAGMENTS)] for index in range(self.server.config.chunks)]
        if not stream:
            if not self.server.stopping.wait(self.server.config.pace * len(fragments)):
                self.send_json(200, generation_record(model, endpoint, "".join(fragments), True, len(fragments)))
            return
        self.send_stream(model, endpoint, fragments, scenario)

    def scenario_for(self, body):
        values = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        if "scenario" in values:
            scenario = values["scenario"][-1]
        else:
            texts = [body.get("prompt", "")]
            messages = body.get("messages", [])
            if isinstance(messages, list):
                texts.extend(message.get("content", "") for message in messages if isinstance(message, dict))
            prompt = " ".join(text for text in texts if isinstance(text, str))
            scenario = next((name for name in SCENARIOS if "[" + name + "]" in prompt), self.server.config.scenario)
        if scenario not in SCENARIOS:
            raise ValueError("scenario must be one of: " + ", ".join(SCENARIOS))
        return scenario

    def send_stream(self, model, endpoint, fragments, scenario):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            emitted = fragments if scenario == "success" else fragments[:3]
            for index, content in enumerate(emitted):
                if index and self.server.stopping.wait(self.server.config.pace):
                    return
                self.send_record(index, generation_record(model, endpoint, content, False, len(fragments)))
            if self.server.stopping.wait(self.server.config.pace):
                return
            if scenario == "abort":
                # Close without an HTTP terminal chunk or a done record, so
                # clients can distinguish a broken stream from normal EOF.
                return
            if scenario == "stream-error":
                record = {"error": "fixture: simulated generation failure"}
            else:
                record = generation_record(model, endpoint, "", True, len(fragments))
            self.send_record(len(emitted), record)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Cancellation by curl/the proxy is expected during manual testing.
            pass

    def send_record(self, index, record):
        if self.server.before_chunk is not None:
            self.server.before_chunk(index)
        payload = json_bytes(record) + b"\n"
        size = self.server.config.fragment_bytes or len(payload)
        for offset in range(0, len(payload), size):
            part = payload[offset:offset + size]
            self.wfile.write(format(len(part), "x").encode("ascii") + b"\r\n" + part + b"\r\n")
            self.wfile.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""Manual POC setup:
  Set FluxLLM upstream to 127.0.0.1:11499; keep its proxy at port 11435.
  Send requests THROUGH port 11435 to drive the menu-bar graph.

  curl -N http://127.0.0.1:11435/api/generate -H 'Content-Type: application/json' \\
    -d '{"model":"fixture-model:latest","prompt":"hello"}'
  curl -N http://127.0.0.1:11435/api/chat -H 'Content-Type: application/json' \\
    -d '{"model":"fixture-small:latest","messages":[{"role":"user","content":"hello"}]}'

Scenarios (query string takes precedence over prompt markers and CLI default):
  ?scenario=success      Normal paced content, then deterministic final stats.
  ?scenario=http-error   HTTP 503 JSON response, also with stream: false.
  ?scenario=stream-error Three content records, then an NDJSON error record.
  ?scenario=abort        Three content records, then truncated HTTP body.
  Prompt/chat content markers: [success], [http-error], [stream-error], [abort].
  stream-error and abort require streaming. At most --chunks records precede errors.
  Add "stream":false to a JSON request for an ordinary nonstreaming response.
  GET /api/version identifies this as a fixture; /api/tags lists two synthetic
  models; /api/ps lists the loaded fixture model. These routes are read-only.
  Any requested model name is echoed in generation responses.

Final stats: eval_count = 2 * --chunks; eval_duration = --chunks * 40,000,000 ns;
prompt_eval_count = 12; authoritative rate = 50 tokens/s regardless of --pace.
Intermediate records contain text and done:false, with no token counts.
The default successful stream lasts about 6.4 seconds. Ctrl-C stops the fixture.
""",
    )
    parser.add_argument("--host", default="127.0.0.1", help="bind address (default: loopback 127.0.0.1)")
    parser.add_argument("--port", type=int, default=11499, help="listen port; 0 selects a free port (default: 11499)")
    parser.add_argument("--pace", type=float, default=0.2, metavar="SECONDS", help="delay between records; 0 to 60 seconds (default: 0.2)")
    parser.add_argument("--chunks", type=int, default=32, help="content records per successful request, 1 to 10000 (default: 32)")
    parser.add_argument("--scenario", choices=SCENARIOS, default="success", help="default scenario (default: success)")
    parser.add_argument("--fragment-bytes", type=int, default=0, metavar="N", help="split each NDJSON record into N-byte HTTP chunks; 1 exercises UTF-8 splits (default: unsplit)")
    parser.add_argument("--quiet", action="store_true", help="omit per-request access logs")
    args = parser.parse_args(argv)
    try:
        config = FixtureConfig(args.pace, args.chunks, args.scenario, args.fragment_bytes, args.quiet)
        if not 0 <= args.port <= 65535:
            raise ValueError("port must be between 0 and 65535")
        server = create_server(args.host, args.port, config)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print("Ollama fixture listening on http://{}:{} (Ctrl-C to stop)".format(*server.server_address), flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
