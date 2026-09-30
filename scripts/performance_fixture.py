#!/usr/bin/env python3
"""External synthetic Ollama and incremental load driver for resource checks.

The first stdout line is JSON containing base_url. All traffic and control stay
on loopback. Keep this process outside the measured FluxLLM process tree.
"""

import argparse
from dataclasses import dataclass
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import math
import signal
import threading
import time
from urllib.parse import urlsplit
import uuid


MODEL = "performance-fixture:latest"
CREATED_AT = "2026-01-01T00:00:00Z"
MAX_BODY_BYTES = 65536
MAX_RECORD_BYTES = 16384
MAX_CHUNKS = 1_000_000
TIMING_POLICY = {
    "schema_version": 1,
    "policy": "absolute-deadlines-50ms-v1",
    "maximum_lateness_seconds": 0.05,
    "maximum_stream_skew_seconds": 0.05,
    "early_epsilon_seconds": 0.000001,
}
MAX_TIMING_VIOLATIONS = 8


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def integer(value, name, minimum, maximum):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be an integer between {minimum} and {maximum}")
    return value


def number(value, name, minimum, maximum):
    if type(value) not in (int, float) or not math.isfinite(value) or not minimum <= value <= maximum:
        raise ValueError(f"{name} must be a finite number between {minimum} and {maximum}")
    return value


def proxy_address(value):
    """Use numeric loopback only: no DNS, credentials, redirects, or URL paths."""
    if not isinstance(value, str):
        raise ValueError("proxy_url must be an HTTP loopback URL")
    try:
        parts = urlsplit(value)
        address = ipaddress.ip_address(parts.hostname or "")
        port = parts.port
        if (parts.scheme != "http" or not address.is_loopback or port is None
                or not 1 <= port <= 65535 or parts.username is not None
                or parts.password is not None or parts.path not in ("", "/")
                or parts.query or parts.fragment):
            raise ValueError()
    except ValueError:
        raise ValueError("proxy_url must be an HTTP numeric loopback URL with an explicit port") from None
    return str(address), port


@dataclass(frozen=True)
class Workload:
    host: str
    port: int
    duration: float
    rate: float
    concurrency: int
    cycle: int
    chunks: int

    @classmethod
    def from_body(cls, body):
        host, port = proxy_address(body.get("proxy_url"))
        duration = number(body.get("duration_seconds"), "duration_seconds", 0.05, 3600)
        rate = number(body.get("rate_hz"), "rate_hz", 1, 1000)
        concurrency = integer(body.get("concurrency", 2), "concurrency", 1, 32)
        cycle = integer(body.get("cycle", 0), "cycle", 0, 1_000_000)
        chunks = max(1, math.floor(duration * rate))
        integer(chunks, "duration_seconds * rate_hz", 1, MAX_CHUNKS)
        return cls(host, port, duration, rate, concurrency, cycle, chunks)


def content(request_index, chunk_index):
    return f"request-{request_index}:chunk-{chunk_index} café ✓ "


def record(request_index, chunk_index, chunks, duration):
    done = chunk_index == chunks
    message = {"role": "assistant", "content": "" if done else content(request_index, chunk_index)}
    if chunk_index == 0 or done:
        # Repeating this identified call in the terminal record tests deduping.
        message["tool_calls"] = [{
            "id": f"call-{request_index}", "type": "function",
            "function": {"index": 0, "name": "fixture_lookup", "arguments": {"index": request_index}},
        }]
    value = {
        "model": MODEL, "created_at": CREATED_AT, "done": done,
        "perf_index": request_index, "perf_chunk": chunk_index, "message": message,
    }
    if done:
        value.update(
            done_reason="stop", eval_count=2 * chunks + 17, prompt_eval_count=23,
            eval_duration=max(1, round(duration * 1_000_000_000)),
            prompt_eval_duration=10_000_000, load_duration=5_000_000,
            total_duration=max(1, round(duration * 1_000_000_000)) + 15_000_000,
        )
    return value


def idle_status():
    return {
        "run_id": None, "running": False, "completed_requests": 0,
        "expected_requests": 0, "expected_output_tokens": 0,
        "expected_prompt_tokens": 0, "tool_calls": 0, "tool_results": 0,
        "received_chunks": 0, "expected_chunks": 0,
        "forwarding_verified": False, "error": None,
        "timing": dict(TIMING_POLICY, streams=[]),
    }


class StreamTiming:
    """Inspect every actual send while retaining bounded evidence per stream."""

    def __init__(self, index, chunks, rate, duration, started):
        self.last_flush_finished = started
        self.value = {
            "request_index": index, "rate_hz": rate, "duration_seconds": duration,
            "expected_content_fragments": chunks, "records_observed": 0,
            "source_started_monotonic_seconds": started,
            "first_write_started_monotonic_seconds": None,
            "first_flush_finished_monotonic_seconds": None,
            "terminal_write_started_monotonic_seconds": None,
            "terminal_flush_finished_monotonic_seconds": None,
            "maximum_start_lateness_seconds": 0.0,
            "maximum_finish_lateness_seconds": 0.0,
            "maximum_earliness_seconds": 0.0,
            "maximum_flush_seconds": 0.0,
            "violation_count": 0, "violations": [],
        }

    def violation(self, index, message, write_started, flush_finished, due):
        self.value["violation_count"] += 1
        if len(self.value["violations"]) < MAX_TIMING_VIOLATIONS:
            self.value["violations"].append({
                "record_index": index, "reason": message,
                "planned_monotonic_seconds": due,
                "write_started_monotonic_seconds": write_started,
                "flush_finished_monotonic_seconds": flush_finished,
            })

    def observed(self, index, write_started, flush_finished):
        value = self.value
        terminal = index == value["expected_content_fragments"]
        due = value["source_started_monotonic_seconds"] + (
            value["duration_seconds"] if terminal else index / value["rate_hz"])
        if (index != value["records_observed"] or flush_finished < write_started
                or write_started < self.last_flush_finished):
            self.violation(index, "Record sequence or write clock moved backwards", write_started, flush_finished, due)
        self.last_flush_finished = flush_finished
        value["records_observed"] += 1
        if index == 0:
            value["first_write_started_monotonic_seconds"] = write_started
            value["first_flush_finished_monotonic_seconds"] = flush_finished
        if terminal:
            value["terminal_write_started_monotonic_seconds"] = write_started
            value["terminal_flush_finished_monotonic_seconds"] = flush_finished
        value["maximum_start_lateness_seconds"] = max(value["maximum_start_lateness_seconds"], write_started - due)
        value["maximum_finish_lateness_seconds"] = max(value["maximum_finish_lateness_seconds"], flush_finished - due)
        value["maximum_earliness_seconds"] = max(value["maximum_earliness_seconds"], due - write_started, due - flush_finished)
        value["maximum_flush_seconds"] = max(value["maximum_flush_seconds"], flush_finished - write_started)
        if (write_started - due > TIMING_POLICY["maximum_lateness_seconds"] + 1e-9
                or flush_finished - due > TIMING_POLICY["maximum_lateness_seconds"] + 1e-9):
            self.violation(index, "Fragment exceeded its absolute deadline by more than 50 ms", write_started, flush_finished, due)
        if min(write_started, flush_finished) < due - TIMING_POLICY["early_epsilon_seconds"]:
            self.violation(index, "Fragment was emitted before its planned deadline", write_started, flush_finished, due)
        if terminal and value["first_flush_finished_monotonic_seconds"] is not None:
            elapsed = flush_finished - value["first_flush_finished_monotonic_seconds"]
            if abs(elapsed - value["duration_seconds"]) > TIMING_POLICY["maximum_lateness_seconds"] + 1e-9:
                self.violation(index, "Observed stream duration differs by more than 50 ms", write_started, flush_finished, due)

    def snapshot(self):
        return self.value | {"violations": list(self.value["violations"])}


class SourceProgress:
    """Source milestones are observed locally, outside the measured process."""

    def __init__(self):
        self.lock = threading.Lock()
        self.latest = -1
        self.timing = None

    def emitted(self, index):
        with self.lock:
            self.latest = index

    def snapshot(self):
        with self.lock:
            return self.latest

    def finished(self, timing):
        with self.lock:
            self.timing = timing

    def timing_snapshot(self):
        with self.lock:
            return self.timing


class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port=0):
        self.stopping = threading.Event()
        self.lock = threading.Lock()
        self.status = idle_status()
        self.source_completions = {}
        self.connections = set()
        self.workers = []
        super().__init__(("127.0.0.1", port), FixtureHandler)

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server_address[1]}"

    def snapshot(self):
        with self.lock:
            return dict(self.status)

    def start_workload(self, workload):
        with self.lock:
            if self.status["running"]:
                raise RuntimeError("a workload is already running")
            run_id = uuid.uuid4().hex
            self.status = idle_status() | {
                "run_id": run_id, "running": True,
                "expected_requests": workload.concurrency,
                "expected_output_tokens": (2 * workload.chunks + 17) * workload.concurrency,
                "expected_prompt_tokens": 23 * workload.concurrency,
                "expected_chunks": workload.chunks * workload.concurrency,
                "expected_request_indices": [workload.cycle * 32 + ordinal for ordinal in range(workload.concurrency)],
            }
            self.source_completions = {}
            self.workers = []
            for ordinal in range(workload.concurrency):
                index = workload.cycle * 32 + ordinal
                progress = SourceProgress()
                self.source_completions[(run_id, index)] = progress
                thread = threading.Thread(
                    target=self.drive, args=(workload, run_id, index, progress), daemon=True)
                self.workers.append(thread)
            acknowledgement = dict(self.status)
            threads = list(self.workers)
        for thread in threads:
            thread.start()
        return acknowledgement

    def drive(self, workload, run_id, index, source_progress):
        connection = HTTPConnection(workload.host, workload.port, timeout=workload.duration + 15)
        received = 0
        error = None
        succeeded = False
        with self.lock:
            self.connections.add(connection)
        try:
            body = {
                "model": MODEL, "stream": True, "perf_chunks": workload.chunks,
                "perf_rate_hz": workload.rate, "perf_duration_seconds": workload.duration,
                "perf_index": index, "perf_run_id": run_id,
                "messages": [
                    {"role": "user", "content": f"synthetic workload {index}"},
                    {"role": "tool", "tool_name": "fixture_lookup",
                     "tool_call_id": f"result-{index}", "content": f"synthetic result {index}"},
                ],
            }
            connection.request("POST", "/api/chat", encoded(body), {"Content-Type": "application/json"})
            response = connection.getresponse()
            if response.status != 200:
                raise ValueError(f"proxy returned HTTP {response.status}")
            checkpoints = {
                max(1, math.floor(workload.chunks * fraction))
                for fraction in (0.25, 0.5, 0.75)
            }
            # Allow scheduling variability of 20% of the stream (at least two
            # records). A prompt first chunk followed by buffering the rest
            # must not look like sustained forwarding. No control HTTP traffic
            # or exact millisecond deadlines are added to the workload.
            allowed_lag = max(2, math.ceil(workload.chunks * 0.2))
            for chunk_index in range(workload.chunks + 1):
                if self.stopping.is_set():
                    raise ValueError("fixture stopped during workload")
                line = response.readline(MAX_RECORD_BYTES + 1)
                # Capture this before parsing to avoid attributing parsing delay
                # to the target process's streaming behavior.
                source_index = source_progress.snapshot() if chunk_index == 0 or chunk_index in checkpoints else None
                if len(line) > MAX_RECORD_BYTES or not line.endswith(b"\n"):
                    raise ValueError("missing, truncated, or oversized NDJSON record")
                value = json.loads(line)
                if value != record(index, chunk_index, workload.chunks, workload.duration):
                    raise ValueError(f"forwarded record {chunk_index} differs from source")
                if chunk_index == 0 and source_index >= workload.chunks:
                    raise ValueError("first content arrived only after upstream completion (buffered forwarding)")
                if chunk_index in checkpoints and chunk_index < workload.chunks:
                    latest_allowed = min(workload.chunks - 1, chunk_index + allowed_lag)
                    if source_index > latest_allowed:
                        raise ValueError(
                            "progressive forwarding checkpoint missed "
                            f"(received={chunk_index}, source={source_index}, limit={latest_allowed})")
                if chunk_index < workload.chunks:
                    received += 1
            if response.read(1):
                raise ValueError("unexpected bytes after terminal record")
            if source_progress.snapshot() < workload.chunks:
                raise ValueError("proxy did not forward this fixture's stream")
            succeeded = True
        except Exception as caught:
            # HTTP protocol exceptions are not all OSError subclasses. Keep the
            # error in status so a failed worker can never silently pass a run.
            error = f"request {index}: {type(caught).__name__}: {caught}"
        finally:
            connection.close()
            with self.lock:
                self.connections.discard(connection)
                self.status["received_chunks"] += received
                if succeeded:
                    self.status["completed_requests"] += 1
                    self.status["tool_calls"] += 1
                    self.status["tool_results"] += 1
                if error and self.status["error"] is None:
                    self.status["error"] = error
                timing = source_progress.timing_snapshot()
                if timing is not None:
                    self.status["timing"]["streams"].append(timing)
                if succeeded and (timing is None or timing["records_observed"] != workload.chunks + 1
                                  or timing["violation_count"]):
                    self.status["error"] = self.status["error"] or f"request {index}: source emission timing is incomplete or outside the fixed 50 ms policy"
                self.source_completions.pop((run_id, index), None)
                if not self.source_completions:
                    self.status["running"] = False
                    starts = [item["first_flush_finished_monotonic_seconds"] for item in self.status["timing"]["streams"]]
                    if len(starts) == workload.concurrency and all(item is not None for item in starts):
                        if max(starts) - min(starts) > TIMING_POLICY["maximum_stream_skew_seconds"] + 1e-9:
                            self.status["error"] = self.status["error"] or "Concurrent source streams started more than 50 ms apart"
                    self.status["forwarding_verified"] = (
                        self.status["error"] is None
                        and self.status["completed_requests"] == workload.concurrency
                        and self.status["received_chunks"] == self.status["expected_chunks"])

    def server_close(self):
        self.stopping.set()
        with self.lock:
            connections = list(self.connections)
        for connection in connections:
            connection.close()
        super().server_close()


class FixtureHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FluxLLMPerformanceFixture/1"
    timeout = 10

    def log_message(self, *_):
        pass

    def send_json(self, status, value):
        payload = encoded(value)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        try:
            self.wfile.write(payload)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path == "/control/status":
            self.send_json(200, self.server.snapshot())
        elif self.path == "/api/version":
            self.send_json(200, {"version": "0.0.0-fluxllm-performance-fixture"})
        elif self.path in ("/api/ps", "/api/tags"):
            self.send_json(200, {"models": [{
                "name": MODEL, "model": MODEL, "modified_at": CREATED_AT,
                "size": 4_000_000_000, "size_vram": 4_000_000_000,
                "digest": "0" * 64, "expires_at": "2099-01-01T00:00:00Z",
                "details": {"format": "gguf", "family": "fixture", "parameter_size": "synthetic", "quantization_level": "Q4_0"},
            }]})
        else:
            self.send_json(404, {"error": "unknown fixture route"})

    def read_body(self):
        if self.headers.get("Transfer-Encoding"):
            raise ValueError("fixture requires Content-Length")
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 < length <= MAX_BODY_BYTES:
            raise ValueError("request body must be between 1 byte and 64 KiB")
        payload = self.rfile.read(length)
        if len(payload) != length:
            raise ValueError("truncated request body")
        value = json.loads(payload)
        if not isinstance(value, dict):
            raise ValueError("request body must be a JSON object")
        return value

    def do_POST(self):
        if self.path not in ("/control/start", "/api/chat"):
            self.send_json(404, {"error": "unknown fixture route"})
            return
        try:
            body = self.read_body()
            if self.path == "/control/start":
                self.send_json(202, self.server.start_workload(Workload.from_body(body)))
                return
            chunks = integer(body.get("perf_chunks"), "perf_chunks", 1, MAX_CHUNKS)
            rate = number(body.get("perf_rate_hz"), "perf_rate_hz", 1, 1000)
            duration = number(body.get("perf_duration_seconds", chunks / rate), "perf_duration_seconds", 0.001, 3600)
            index = integer(body.get("perf_index"), "perf_index", 0, 32_000_032)
            if body.get("stream", True) is not True:
                raise ValueError("performance fixture requires streaming")
            run_id = body.get("perf_run_id", "manual")
            if not isinstance(run_id, str) or not 1 <= len(run_id) <= 64:
                raise ValueError("perf_run_id must be a short string")
        except RuntimeError as error:
            self.send_json(409, {"error": str(error)})
            return
        except (ValueError, UnicodeDecodeError, OSError) as error:
            self.send_json(400, {"error": str(error)})
            return
        self.send_stream(index, chunks, rate, duration, run_id)

    def send_stream(self, index, chunks, rate, duration, run_id):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        started = time.monotonic()
        timing = StreamTiming(index, chunks, rate, duration, started)
        with self.server.lock:
            progress = self.server.source_completions.get((run_id, index))
        try:
            for chunk_index in range(chunks + 1):
                due = started + (duration if chunk_index == chunks else chunk_index / rate)
                if self.server.stopping.wait(max(0, due - time.monotonic())):
                    return
                if progress is not None:
                    progress.emitted(chunk_index)
                payload = encoded(record(index, chunk_index, chunks, duration)) + b"\n"
                write_started = time.monotonic()
                self.wfile.write(f"{len(payload):x}\r\n".encode("ascii") + payload + b"\r\n")
                self.wfile.flush()
                timing.observed(chunk_index, write_started, time.monotonic())
            # Publish before the HTTP terminator: drive() cannot finish its
            # final read until the complete timing evidence is available.
            if progress is not None:
                progress.finished(timing.snapshot())
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def create_server(port=0):
    return FixtureServer(port)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=0, help="loopback port, default 0 selects a free port")
    arguments = parser.parse_args(argv)
    if not 0 <= arguments.port <= 65535:
        parser.error("port must be between 0 and 65535")
    server = create_server(arguments.port)

    def stop(*_):
        server.stopping.set()
        # shutdown must run outside serve_forever's thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(json.dumps({"base_url": server.base_url}), flush=True)
    try:
        server.serve_forever(poll_interval=0.05)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
