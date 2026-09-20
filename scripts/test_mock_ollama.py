"""Run with: python3 -m unittest discover -s scripts -p 'test_mock_ollama.py' -v"""

from contextlib import contextmanager
from http.client import HTTPConnection, IncompleteRead
import json
import threading
import unittest

from mock_ollama import DEFAULT_MODEL, FixtureConfig, create_server


@contextmanager
def running_fixture(before_chunk=None, **config):
    server = create_server(port=0, config=FixtureConfig(pace=0, quiet=True, **config), before_chunk=before_chunk)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
    thread.start()
    connection = HTTPConnection(*server.server_address, timeout=3)
    try:
        yield server, connection
    finally:
        connection.close()
        server.stopping.set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


def post(connection, path, body):
    connection.request("POST", path, json.dumps(body), {"Content-Type": "application/json"})
    return connection.getresponse()


class MockOllamaTests(unittest.TestCase):
    def test_read_only_discovery_and_readiness_routes(self):
        with running_fixture() as (_, connection):
            connection.request("GET", "/api/version")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read())["version"], "0.0.0-fluxllm-fixture")
            for _ in range(2):
                connection.request("GET", "/api/ps")
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                models = json.loads(response.read())["models"]
                self.assertEqual(len(models), 1)
                self.assertEqual(models[0]["model"], DEFAULT_MODEL)
                self.assertEqual(models[0]["details"]["family"], "fixture")
                self.assertIn("expires_at", models[0])
                self.assertEqual(models[0]["size_vram"], models[0]["size"])

    def test_tags_lists_models_and_unknown_route_is_json_404(self):
        with running_fixture() as (_, connection):
            connection.request("GET", "/api/tags")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            models = json.loads(response.read())["models"]
            self.assertEqual([model["name"] for model in models], [DEFAULT_MODEL, "fixture-small:latest"])
            connection.request("GET", "/missing")
            response = connection.getresponse()
            self.assertEqual(response.status, 404)
            self.assertIn("error", json.loads(response.read()))

    def test_generate_delivers_first_record_before_remaining_records_are_released(self):
        gate_reached = threading.Event()
        release = threading.Event()

        def before_chunk(index):
            if index == 1:
                gate_reached.set()
                release.wait()

        with running_fixture(before_chunk=before_chunk, chunks=4) as (_, connection):
            try:
                response = post(connection, "/api/generate", {"model": "custom-model", "prompt": "hello"})
                self.assertEqual(response.status, 200)
                self.assertEqual(response.getheader("Content-Type"), "application/x-ndjson")
                self.assertTrue(gate_reached.wait(timeout=3))
                first = json.loads(response.readline())
                self.assertFalse(release.is_set())
                self.assertEqual(first["model"], "custom-model")
                self.assertEqual(first["response"], "FluxLLM")
                self.assertFalse(first["done"])
                self.assertNotIn("eval_count", first)
            finally:
                release.set()
            records = [first] + [json.loads(line) for line in response.read().splitlines()]
            self.assertEqual(len(records), 5)
            for record in records[:-1]:
                self.assertNotIn("eval_count", record)
                self.assertNotIn("eval_duration", record)
            final = records[-1]
            self.assertTrue(final["done"])
            self.assertEqual(final["eval_count"], 8)
            self.assertEqual(final["prompt_eval_count"], 12)
            self.assertEqual(final["eval_count"] * 1e9 / final["eval_duration"], 50)

    def test_chat_handles_utf8_records_split_across_one_byte_http_chunks(self):
        with running_fixture(chunks=16, fragment_bytes=1) as (_, connection):
            response = post(connection, "/api/chat", {"model": "fixture-small:latest", "messages": [{"role": "user", "content": "hello"}]})
            records = [json.loads(line) for line in response.read().splitlines()]
            content = "".join(record["message"]["content"] for record in records)
            self.assertIn("café", content)
            self.assertIn("✓", content)
            self.assertTrue(records[-1]["done"])
            self.assertEqual(records[-1]["message"], {"role": "assistant", "content": ""})
            self.assertTrue(all("response" not in record for record in records))

    def test_nonstreaming_generate_and_chat_return_complete_text_and_stats(self):
        for endpoint, content_key in (("generate", "response"), ("chat", "message")):
            with self.subTest(endpoint=endpoint), running_fixture(chunks=2) as (_, connection):
                response = post(connection, "/api/" + endpoint, {"stream": False})
                self.assertEqual(response.getheader("Content-Type"), "application/json")
                result = json.loads(response.read())
                text = result[content_key] if content_key == "response" else result[content_key]["content"]
                self.assertEqual(text, "FluxLLM keeps")
                self.assertEqual(result["eval_count"], 4)
                self.assertEqual(result["eval_duration"], 80_000_000)
                self.assertTrue(result["done"])

    def test_http_error_supports_query_and_generate_or_chat_prompt_markers(self):
        cases = (
            ("/api/generate?scenario=http-error", {"stream": False}),
            ("/api/generate", {"prompt": "please [http-error]"}),
            ("/api/chat", {"messages": [{"content": "please [http-error]"}]}),
        )
        for path, body in cases:
            with self.subTest(path=path, body=body), running_fixture() as (_, connection):
                response = post(connection, path, body)
                self.assertEqual(response.status, 503)
                self.assertIn("unavailable", json.loads(response.read())["error"])

    def test_query_scenario_overrides_prompt_and_config(self):
        with running_fixture(chunks=1, scenario="abort") as (_, connection):
            response = post(connection, "/api/generate?scenario=success", {"prompt": "[http-error]"})
            records = [json.loads(line) for line in response.read().splitlines()]
            self.assertTrue(records[-1]["done"])

    def test_stream_error_ends_http_with_error_record_and_no_success_stats(self):
        with running_fixture(chunks=8) as (_, connection):
            response = post(connection, "/api/generate?scenario=stream-error", {})
            self.assertEqual(response.status, 200)
            records = [json.loads(line) for line in response.read().splitlines()]
            self.assertEqual(len(records), 4)
            self.assertIn("error", records[-1])
            self.assertFalse(any(record.get("done") for record in records))
            self.assertTrue(all("eval_count" not in record for record in records))

    def test_abort_delivers_content_then_closes_without_http_terminal_chunk(self):
        gate_reached = threading.Event()
        release = threading.Event()

        def before_chunk(index):
            if index == 1:
                gate_reached.set()
                release.wait()

        with running_fixture(before_chunk=before_chunk, chunks=8) as (_, connection):
            try:
                response = post(connection, "/api/chat", {"messages": [{"content": "[abort]"}]})
                self.assertEqual(response.status, 200)
                self.assertTrue(gate_reached.wait(timeout=3))
                first = json.loads(response.readline())
                self.assertEqual(first["message"]["content"], "FluxLLM")
                self.assertFalse(first["done"])
            finally:
                release.set()
            with self.assertRaises(IncompleteRead) as raised:
                response.read()
            remaining = [json.loads(line) for line in raised.exception.partial.splitlines()]
            self.assertEqual(len(remaining), 2)
            self.assertTrue(all(record["done"] is False for record in remaining))

    def test_invalid_request_returns_json_error(self):
        cases = (
            ("/api/generate", b"not json"),
            ("/api/generate", b"[]"),
            ("/api/generate", b'{"stream":"false"}'),
            ("/api/generate", b'{"model":17}'),
            ("/api/generate?scenario=missing", b"{}"),
            ("/api/generate?scenario=abort", b'{"stream":false}'),
        )
        for path, body in cases:
            with self.subTest(path=path, body=body), running_fixture() as (_, connection):
                connection.request("POST", path, body)
                response = connection.getresponse()
                self.assertEqual(response.status, 400)
                self.assertIn("error", json.loads(response.read()))

    def test_config_rejects_invalid_pacing_and_sizes(self):
        for config in ({"pace": -1}, {"pace": float("nan")}, {"pace": float("inf")}, {"chunks": 0}, {"fragment_bytes": -1}):
            with self.subTest(config=config), self.assertRaises(ValueError):
                FixtureConfig(**config)


if __name__ == "__main__":
    unittest.main()
