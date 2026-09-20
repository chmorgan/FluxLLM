"""Run: python3 -m unittest discover -s scripts -p 'test_mock*.py' -v"""

from contextlib import contextmanager
from http.client import HTTPConnection
import json
import threading
import unittest
from unittest.mock import patch

from mock_metrics_backend import BACKENDS, FixtureConfig, create_server


@contextmanager
def running_fixture(before_chunk=None, **options):
    config = FixtureConfig(**dict({"pace": 0, "chunks": 4, "quiet": True}, **options))
    server = create_server(port=0, config=config, before_chunk=before_chunk)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.stopping.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        if thread.is_alive():
            raise AssertionError("fixture serve_forever thread did not stop")


def request(server, method, path, body=None):
    connection = HTTPConnection(*server.server_address, timeout=3)
    try:
        connection.request(method, path, None if body is None else json.dumps(body), {"Content-Type": "application/json"})
        response = connection.getresponse()
        return response.status, response.read().decode("utf-8")
    finally:
        connection.close()


def get_json(server, path):
    status, body = request(server, "GET", path)
    if status != 200:
        raise AssertionError((status, body))
    return json.loads(body)


def metrics(server):
    status, body = request(server, "GET", "/metrics")
    if status != 200:
        raise AssertionError((status, body))
    return {line.split(" ", 1)[0].split("{", 1)[0]: float(line.rsplit(" ", 1)[1])
            for line in body.splitlines() if line and not line.startswith("#")}


def open_stream(server):
    connection = HTTPConnection(*server.server_address, timeout=3)
    connection.request("POST", "/v1/chat/completions", json.dumps({
        "model": server.config.model, "messages": [{"role": "user", "content": "hello"}], "stream": True,
    }), {"Content-Type": "application/json"})
    return connection, connection.getresponse()


def events(payload):
    return [line[6:] if line == "data: [DONE]" else json.loads(line[6:])
            for line in payload.splitlines() if line.startswith("data: ")]


class MockMetricsBackendTests(unittest.TestCase):
    def test_loopback_startup_does_not_require_reverse_lookup(self):
        with patch("socket.gethostbyaddr", side_effect=AssertionError("Reverse lookup is forbidden")) as lookup:
            for backend in BACKENDS:
                with self.subTest(backend=backend), running_fixture(backend=backend) as server:
                    self.assertEqual(server.server_name, "127.0.0.1")
                    self.assertEqual(server.server_port, server.server_address[1])
                    self.assertGreater(server.server_port, 0)
                    self.assertEqual(get_json(server, "/health")["status"], "ok")
            lookup.assert_not_called()

    def test_discovery_fingerprints_are_backend_specific_and_read_only(self):
        for backend in BACKENDS:
            with self.subTest(backend=backend), running_fixture(backend=backend) as server:
                model = get_json(server, "/v1/models")["data"][0]
                self.assertEqual(model["id"], "Fixture/" + backend + "-synthetic")
                self.assertIn("fixture", model["owned_by"])
                self.assertEqual(get_json(server, "/health")["status"], "ok")
                values = metrics(server)
                if backend == "vllm":
                    self.assertEqual(values["vllm:generation_tokens_total"], 0)
                    self.assertEqual(values["vllm:num_requests_running"], 0)
                elif backend == "rapid-mlx":
                    self.assertEqual(values["rapid_mlx_build_info"], 1)
                    status = get_json(server, "/v1/status")
                    self.assertEqual(status["status"], "idle")
                    self.assertEqual(status["requests"], [])
                else:
                    self.assertEqual(values["llamacpp:tokens_predicted_total"], 0)
                    props = get_json(server, "/props")
                    self.assertTrue(props["endpoint_metrics"])
                    self.assertEqual(props["model_alias"], model["id"])
                    self.assertIsInstance(props["default_generation_settings"], dict)
                    self.assertEqual(props["total_slots"], 4)
                self.assertEqual(request(server, "GET", "/api/version")[0], 404)
                self.assertEqual(server.snapshot()["output"], 0)
                self.assertEqual(server.snapshot()["completed_requests"], 0)

    def test_direct_stream_updates_live_metrics_then_finishes_idle_with_usage(self):
        for backend in BACKENDS:
            gate_reached, release = threading.Event(), threading.Event()

            def before_chunk(_, index):
                if index == 1:
                    gate_reached.set()
                    release.wait()

            with self.subTest(backend=backend), running_fixture(backend=backend, before_chunk=before_chunk) as server:
                connection, response = open_stream(server)
                try:
                    self.assertEqual(response.status, 200)
                    self.assertEqual(response.getheader("Content-Type"), "text/event-stream")
                    self.assertTrue(gate_reached.wait(timeout=3))
                    first_line = response.readline().decode("utf-8")
                    self.assertEqual(events(first_line)[0]["choices"][0]["delta"]["content"], "Synthetic")
                    self.assertFalse(release.is_set())
                    values = metrics(server)
                    if backend == "vllm":
                        self.assertEqual(values["vllm:generation_tokens_total"], 2)
                        self.assertEqual(values["vllm:prompt_tokens_total"], 12)
                        self.assertEqual(values["vllm:num_requests_running"], 1)
                    elif backend == "rapid-mlx":
                        status = get_json(server, "/v1/status")
                        self.assertEqual(status["status"], "generating")
                        self.assertEqual(status["num_running"], 1)
                        self.assertEqual(status["requests"][0]["generated_tokens"], 2)
                        self.assertEqual(status["total_completion_tokens"], 0)
                        self.assertGreater(status["generation_tps"], 0)
                    else:
                        self.assertEqual(values["llamacpp:requests_processing"], 1)
                        self.assertEqual(values["llamacpp:tokens_predicted_total"], 0)
                        self.assertGreater(values["llamacpp:predicted_tokens_seconds"], 0)
                    self.assertEqual(request(server, "POST", "/fixture/reset", {})[0], 409)
                finally:
                    release.set()
                try:
                    stream = events(first_line + response.read().decode("utf-8"))
                    self.assertEqual(len(stream), 7)  # Four deltas, finish, usage, DONE.
                    self.assertEqual(stream[-1], "[DONE]")
                    self.assertEqual(stream[-2]["usage"], {"prompt_tokens": 12, "completion_tokens": 8, "total_tokens": 20})
                    self.assertEqual(stream[-3]["choices"][0]["finish_reason"], "stop")
                    self.assertEqual(server.snapshot()["running"], 0)
                    self.assertEqual(server.snapshot()["completed_output"], 8)
                    values = metrics(server)
                    if backend == "vllm":
                        self.assertEqual(values["vllm:num_requests_running"], 0)
                        self.assertEqual(values["vllm:generation_tokens_total"], 8)
                    elif backend == "rapid-mlx":
                        status = get_json(server, "/v1/status")
                        self.assertEqual(status["status"], "idle")
                        self.assertEqual(status["num_running"], 0)
                        self.assertEqual(status["total_completion_tokens"], 8)
                        self.assertGreater(status["generation_tps"], 0)
                    else:
                        self.assertEqual(values["llamacpp:requests_processing"], 0)
                        self.assertEqual(values["llamacpp:tokens_predicted_total"], 8)
                        self.assertGreater(values["llamacpp:predicted_tokens_seconds"], 0)
                finally:
                    connection.close()

    def test_two_direct_streams_are_aggregated_while_metrics_remain_responsive(self):
        release = threading.Event()
        gates = {"fixture-1": threading.Event(), "fixture-2": threading.Event()}

        def before_chunk(request_id, index):
            if index == 1:
                gates[request_id].set()
                release.wait()

        with running_fixture(before_chunk=before_chunk) as server:
            streams = []
            try:
                streams.append(open_stream(server))
                streams.append(open_stream(server))
                self.assertTrue(all(gate.wait(timeout=3) for gate in gates.values()))
                for _, response in streams:
                    self.assertEqual(response.status, 200)
                values = metrics(server)
                self.assertEqual(values["vllm:num_requests_running"], 2)
                self.assertEqual(values["vllm:generation_tokens_total"], 4)
                self.assertEqual(values["vllm:prompt_tokens_total"], 24)
            finally:
                release.set()
                for connection, response in streams:
                    response.read()
                    connection.close()
            values = metrics(server)
            self.assertEqual(values["vllm:num_requests_running"], 0)
            self.assertEqual(values["vllm:generation_tokens_total"], 16)

    def test_nonstreaming_response_and_explicit_idle_counter_reset(self):
        for backend in BACKENDS:
            with self.subTest(backend=backend), running_fixture(backend=backend, chunks=2) as server:
                status, body = request(server, "POST", "/v1/chat/completions", {"stream": False})
                self.assertEqual(status, 200)
                result = json.loads(body)
                self.assertEqual(result["choices"][0]["message"]["content"], "Synthetic FluxLLM")
                self.assertEqual(result["usage"]["completion_tokens"], 4)
                self.assertEqual(request(server, "GET", "/fixture/reset")[0], 404)
                self.assertEqual(server.snapshot()["completed_output"], 4)
                self.assertEqual(request(server, "POST", "/fixture/reset", {})[0], 200)
                self.assertEqual(server.snapshot()["output"], 0)
                self.assertEqual(server.snapshot()["completed_output"], 0)
                self.assertEqual(server.snapshot()["completed_requests"], 0)

    def test_rapid_unloaded_and_llama_metrics_disabled_states(self):
        with running_fixture(backend="rapid-mlx", ready=False) as server:
            self.assertEqual(get_json(server, "/v1/status")["status"], "not_loaded")
            self.assertEqual(request(server, "GET", "/health")[0], 503)
            self.assertEqual(request(server, "POST", "/v1/chat/completions", {"stream": True})[0], 503)
            self.assertEqual(server.snapshot()["output"], 0)
        with running_fixture(backend="llama.cpp", metrics_enabled=False) as server:
            self.assertFalse(get_json(server, "/props")["endpoint_metrics"])
            self.assertEqual(request(server, "GET", "/metrics")[0], 404)
            self.assertEqual(request(server, "GET", "/health")[0], 200)

    def test_invalid_request_and_config_leave_state_unchanged(self):
        with running_fixture() as server:
            for body in ([], {"stream": "true"}, {"model": "real-model"}):
                with self.subTest(body=body):
                    self.assertEqual(request(server, "POST", "/v1/chat/completions", body)[0], 400)
                    self.assertEqual(server.snapshot()["output"], 0)
            self.assertEqual(request(server, "POST", "/unknown", {})[0], 404)
        for config in ({"backend": "ollama"}, {"pace": -1}, {"pace": float("nan")}, {"pace": float("inf")}, {"chunks": 0}):
            with self.subTest(config=config), self.assertRaises(ValueError):
                FixtureConfig(**config)


if __name__ == "__main__":
    unittest.main()
