"""Run: PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_performance_fixture.py' -v"""

from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest

from performance_fixture import MAX_BODY_BYTES, MODEL, create_server, encoded, proxy_address, record


@contextmanager
def running_server(server=None):
    server = server or create_server()
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        if hasattr(server, "stopping"):
            server.stopping.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


def request(server, path, body=None):
    connection = HTTPConnection(*server.server_address, timeout=3)
    try:
        connection.request("GET" if body is None else "POST", path,
                           None if body is None else encoded(body), {"Content-Type": "application/json"})
        response = connection.getresponse()
        return response.status, json.loads(response.read())
    finally:
        connection.close()


def workload(server, **overrides):
    return {"proxy_url": server.base_url, "duration_seconds": 0.1,
            "rate_hz": 40, "concurrency": 2, "cycle": 0} | overrides


def await_result(server):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        status, value = request(server, "/control/status")
        if not value["running"]:
            return value
        time.sleep(0.005)
    raise AssertionError("workload did not finish in five seconds")


class PerformanceFixtureTests(unittest.TestCase):
    def test_discovery_and_idle_status(self):
        with running_server() as server:
            self.assertEqual(request(server, "/api/version")[1]["version"], "0.0.0-fluxllm-performance-fixture")
            self.assertEqual(request(server, "/api/ps")[1]["models"][0]["model"], MODEL)
            value = request(server, "/control/status")[1]
            self.assertFalse(value["running"])
            self.assertFalse(value["forwarding_verified"])
            self.assertIsNone(value["error"])

    def test_incremental_streaming_counts_and_sequential_cycles(self):
        with running_server() as server:
            run_ids = set()
            for cycle, rate in enumerate((40, 200)):
                status, started = request(server, "/control/start", workload(server, cycle=cycle, rate_hz=rate))
                self.assertEqual(status, 202)
                self.assertTrue(started["running"])
                run_ids.add(started["run_id"])
                result = await_result(server)
                chunks = int(0.1 * rate)
                self.assertIsNone(result["error"])
                self.assertTrue(result["forwarding_verified"])
                self.assertEqual(result["completed_requests"], 2)
                self.assertEqual(result["received_chunks"], chunks * 2)
                self.assertEqual(result["expected_chunks"], chunks * 2)
                self.assertEqual(result["expected_output_tokens"], (2 * chunks + 17) * 2)
                self.assertEqual(result["expected_prompt_tokens"], 46)
                self.assertEqual(result["tool_calls"], 2)
                self.assertEqual(result["tool_results"], 2)
            self.assertEqual(len(run_ids), 2)

    def test_record_has_repeated_identified_tool_and_authoritative_counts(self):
        first = record(9, 0, 4, 0.1)
        final = record(9, 4, 4, 0.1)
        self.assertEqual(first["message"]["tool_calls"], final["message"]["tool_calls"])
        self.assertNotIn("eval_count", first)
        self.assertEqual(final["eval_count"], 25)
        self.assertEqual(final["prompt_eval_count"], 23)

    def test_concurrent_control_start_is_rejected(self):
        with running_server() as server:
            self.assertEqual(request(server, "/control/start", workload(server, duration_seconds=0.2))[0], 202)
            self.assertEqual(request(server, "/control/start", workload(server))[0], 409)
            self.assertTrue(await_result(server)["forwarding_verified"])

    def test_rejects_nonlocal_or_ambiguous_proxy_urls(self):
        invalid = ("http://example.com:1234", "http://localhost:1234", "http://192.168.1.1:1234",
                   "https://127.0.0.1:1234", "http://127.0.0.1", "http://u:p@127.0.0.1:1",
                   "http://127.0.0.1:1234/path", "http://127.0.0.1:1234?x=1", "http://127.0.0.1:0")
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                proxy_address(value)
        self.assertEqual(proxy_address("http://127.0.0.1:1234"), ("127.0.0.1", 1234))
        self.assertEqual(proxy_address("http://[::1]:1234/"), ("::1", 1234))

    def test_rejects_invalid_workload_fields_and_oversized_bodies(self):
        with running_server() as server:
            for override in ({"duration_seconds": float("nan")}, {"rate_hz": True},
                             {"concurrency": 0}, {"cycle": -1}, {"duration_seconds": 0},
                             {"duration_seconds": 3600, "rate_hz": 1000}):
                with self.subTest(override=override):
                    self.assertEqual(request(server, "/control/start", workload(server, **override))[0], 400)
            self.assertEqual(request(server, "/control/start", {"oversized": "x" * MAX_BODY_BYTES})[0], 400)
            for body in ({"perf_chunks": True, "perf_rate_hz": 40, "perf_index": 0},
                         {"perf_chunks": 2, "perf_rate_hz": 0, "perf_index": 0},
                         {"perf_chunks": 2, "perf_rate_hz": 40, "perf_index": -1}):
                self.assertEqual(request(server, "/api/chat", body)[0], 400)

    def test_buffered_or_corrupted_forwarding_cannot_pass(self):
        for corrupt in (False, True):
            with self.subTest(corrupt=corrupt), running_server() as upstream:
                class BadProxy(BaseHTTPRequestHandler):
                    def log_message(self, *_):
                        pass

                    def do_POST(self):
                        payload = self.rfile.read(int(self.headers["Content-Length"]))
                        connection = HTTPConnection(*upstream.server_address, timeout=3)
                        try:
                            connection.request("POST", "/api/chat", payload, {"Content-Type": "application/json"})
                            response = connection.getresponse()
                            buffered = response.read()
                        finally:
                            connection.close()
                        if corrupt:
                            buffered = buffered.replace(b"caf", b"bad")
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(buffered)))
                        self.end_headers()
                        self.wfile.write(buffered)

                with running_server(ThreadingHTTPServer(("127.0.0.1", 0), BadProxy)) as proxy:
                    url = f"http://127.0.0.1:{proxy.server_address[1]}"
                    self.assertEqual(request(upstream, "/control/start", workload(upstream, proxy_url=url))[0], 202)
                    result = await_result(upstream)
                    self.assertFalse(result["forwarding_verified"])
                    self.assertEqual(result["completed_requests"], 0)
                    self.assertIn("differs from source" if corrupt else "buffered forwarding", result["error"])

    def test_incremental_forwarding_with_wrong_final_counts_cannot_pass(self):
        with running_server() as upstream:
            class WrongCountsProxy(BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def do_POST(self):
                    payload = self.rfile.read(int(self.headers["Content-Length"]))
                    connection = HTTPConnection(*upstream.server_address, timeout=3)
                    try:
                        connection.request("POST", "/api/chat", payload, {"Content-Type": "application/json"})
                        response = connection.getresponse()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/x-ndjson")
                        self.send_header("Connection", "close")
                        self.end_headers()
                        while line := response.readline():
                            value = json.loads(line)
                            if value["done"]:
                                value["eval_count"] += 1
                            self.wfile.write(encoded(value) + b"\n")
                            self.wfile.flush()
                    finally:
                        connection.close()

            with running_server(ThreadingHTTPServer(("127.0.0.1", 0), WrongCountsProxy)) as proxy:
                url = f"http://127.0.0.1:{proxy.server_address[1]}"
                request(upstream, "/control/start", workload(upstream, proxy_url=url))
                result = await_result(upstream)
                self.assertFalse(result["forwarding_verified"])
                self.assertEqual(result["completed_requests"], 0)
                self.assertEqual(result["received_chunks"], result["expected_chunks"])
                self.assertIn("forwarded record 4 differs from source", result["error"])

    def test_first_chunk_then_buffering_cannot_pass_progressive_checkpoints(self):
        # Both a full remainder buffer and a large midstream batch must fail,
        # even though their first content arrived promptly and bytes are exact.
        for release_fraction in (1, 0.75):
            with self.subTest(release_fraction=release_fraction), running_server() as upstream:
                class DelayedProxy(BaseHTTPRequestHandler):
                    def log_message(self, *_):
                        pass

                    def do_POST(self):
                        payload = self.rfile.read(int(self.headers["Content-Length"]))
                        chunks = json.loads(payload)["perf_chunks"]
                        connection = HTTPConnection(*upstream.server_address, timeout=3)
                        try:
                            connection.request("POST", "/api/chat", payload, {"Content-Type": "application/json"})
                            response = connection.getresponse()
                            self.send_response(200)
                            self.send_header("Content-Type", "application/x-ndjson")
                            self.send_header("Connection", "close")
                            self.end_headers()
                            self.wfile.write(response.readline())
                            self.wfile.flush()
                            buffered = bytearray()
                            for chunk_index in range(1, chunks + 1):
                                buffered.extend(response.readline())
                                if chunk_index >= int(chunks * release_fraction):
                                    self.wfile.write(buffered)
                                    self.wfile.flush()
                                    buffered.clear()
                        except OSError:
                            # The fixture is expected to reject and disconnect.
                            pass
                        finally:
                            connection.close()

                with running_server(ThreadingHTTPServer(("127.0.0.1", 0), DelayedProxy)) as proxy:
                    url = f"http://127.0.0.1:{proxy.server_address[1]}"
                    request(upstream, "/control/start", workload(
                        upstream, proxy_url=url, duration_seconds=0.2, rate_hz=200))
                    result = await_result(upstream)
                    self.assertFalse(result["forwarding_verified"])
                    self.assertEqual(result["completed_requests"], 0)
                    self.assertGreaterEqual(result["received_chunks"], 2)
                    self.assertLess(result["received_chunks"], result["expected_chunks"])
                    self.assertIn("progressive forwarding checkpoint missed", result["error"])

    def test_cli_outputs_json_and_terminates_cleanly(self):
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).with_name("performance_fixture.py")), "--port", "0"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env=os.environ | {"PYTHONDONTWRITEBYTECODE": "1"})
        try:
            ready = json.loads(process.stdout.readline())
            self.assertTrue(ready["base_url"].startswith("http://127.0.0.1:"))
            process.terminate()
            stdout, stderr = process.communicate(timeout=3)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(stdout, "")
            self.assertEqual(stderr, "")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()


if __name__ == "__main__":
    unittest.main()
