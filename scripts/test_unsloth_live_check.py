"""The live checker is deliberately read-only and saves no inference content."""

from io import BytesIO
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

import unsloth_live_check as live


class FakeResponse(BytesIO):
    def __init__(self, status, data):
        super().__init__(data)
        self.status = status


class UnslothLiveCheckTests(unittest.TestCase):
    def test_endpoint_validation_rejects_credentials_redirect_targets_and_query(self):
        for url in ("https://127.0.0.1:8888", "http://localhost:8888", "http://example.test:8888",
                    "http://user:key@127.0.0.1:8888", "http://127.0.0.1:8888/?key=secret",
                    "http://127.0.0.1:8888/#secret", "http://127.0.0.1:8888/api", "http://127.0.0.1"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                live.endpoint(url)
        self.assertEqual(live.endpoint("http://127.0.0.1:8888/"), "http://127.0.0.1:8888")

    def test_metrics_parser_exports_only_known_finite_nonnegative_numeric_values(self):
        payload = b'''# secret api-key and user prompt
llamacpp:tokens_predicted_total{prompt="private"} 8
llamacpp:prompt_tokens_total 12
llamacpp:requests_processing 1
llamacpp:requests_deferred 0
llamacpp:predicted_tokens_seconds 10
llamacpp:unknown_key{reply="private"} 999
llamacpp:gpu_percent NaN
llamacpp:tokens_predicted_total -1
'''
        parsed = live.numeric_metrics(payload)
        self.assertEqual(parsed, {"tokens_predicted_total": 8, "prompt_tokens_total": 12,
                                  "requests_processing": 1, "requests_deferred": 0,
                                  "predicted_tokens_seconds": 10})
        self.assertNotIn("private", json.dumps(parsed))
        self.assertNotIn("secret", json.dumps(parsed))

    def test_probe_requests_are_bounded_gets_and_never_include_auth_or_inference(self):
        requests = []

        def open_request(request, timeout):
            requests.append(request)
            self.assertLessEqual(timeout, 5)
            path = urlsplit(request.full_url).path
            if path == "/metrics":
                return FakeResponse(200, b"llamacpp:requests_processing 0\nllamacpp:tokens_predicted_total 4\n")
            if path == "/props":
                return FakeResponse(200, json.dumps({"endpoint_metrics": True, "total_slots": 1,
                    "model_alias": "/private/model.gguf", "prompt": "private user prompt", "api_key": "secret"}).encode())
            return FakeResponse(200, b'{"status":"ok","reply":"secret reply"}')

        with patch.object(live, "open_read_only", side_effect=open_request), patch.object(live.time, "sleep"):
            report = live.probe("http://127.0.0.1:8888", "http://127.0.0.1:54234", samples=3, interval=1)
        self.assertEqual(len(requests), 6)  # Studio health, worker health/props, three metrics polls.
        self.assertTrue(all(r.get_method() == "GET" and r.data is None for r in requests))
        self.assertTrue(all("Authorization" not in r.headers for r in requests))
        self.assertTrue(all("autoload=false" in r.full_url for r in requests if ":54234/" in r.full_url))
        self.assertEqual(report["worker"]["props"]["endpoint_metrics"], True)
        self.assertTrue(report["worker"]["metrics_compatible"])
        self.assertEqual(len(report["samples"]), 3)
        serialized = json.dumps(report)
        for private in ("secret", "private user prompt", "/private/model.gguf"):
            self.assertNotIn(private, serialized)

    def test_numeric_series_overflow_stays_unavailable_instead_of_reporting_infinity(self):
        self.assertEqual(live.numeric_metrics(b"llamacpp:tokens_predicted_total 1e308\n"
                                              b"llamacpp:tokens_predicted_total 1e308\n"
                                              b"llamacpp:tokens_predicted_total 4\n"), {})

    def test_missing_metrics_auth_and_oversized_responses_remain_unavailable(self):
        for status in (401, 403, 404, 503):
            with self.subTest(status=status), patch.object(live, "open_read_only", return_value=FakeResponse(status, b'secret')):
                result = live.read_endpoint("http://127.0.0.1:54234", "metrics", timeout=1)
            self.assertEqual(result, {"http_status": status, "available": False})
        with patch.object(live, "open_read_only", return_value=FakeResponse(200, b'x' * (live.MAX_RESPONSE_BYTES + 1))):
            self.assertEqual(live.read_endpoint("http://127.0.0.1:54234", "metrics", timeout=1),
                             {"http_status": 200, "available": False, "error": "response_too_large"})

    def test_unloaded_studio_is_a_valid_report_without_worker_requests(self):
        with patch.object(live, "open_read_only", return_value=FakeResponse(200, b'{}')) as opened:
            report = live.probe("http://127.0.0.1:8888", None, samples=1, interval=1)
        self.assertEqual(opened.call_count, 1)
        self.assertIsNone(report["worker"])
        self.assertEqual(report["samples"], [])
        self.assertEqual(report["mode"], "read_only_compatibility")

    def test_redirects_are_not_followed(self):
        self.assertIsNone(live.NoRedirect().redirect_request(None, None, 302, "Found", {}, "http://example.test"))

    def test_probe_limits_total_operations_and_measurement_rate(self):
        for options in ({"samples": 0}, {"samples": 61}, {"interval": 0.5}, {"interval": 6}, {"timeout": 6}):
            with self.subTest(options=options), self.assertRaises(ValueError), patch.object(live, "open_read_only") as opened:
                live.probe("http://127.0.0.1:8888", "http://127.0.0.1:54234", **options)
            opened.assert_not_called()

    def test_report_uses_a_new_ignored_directory_and_preserves_existing_evidence(self):
        with patch.object(live, "open_read_only", return_value=FakeResponse(200, b'{}')):
            report = live.probe("http://127.0.0.1:8888", None, samples=1)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            output = root / ".performance-results" / "live-check"
            with patch.object(live, "__file__", str(root / "scripts" / "unsloth_live_check.py")):
                saved = live.save_report(report, output)
                self.assertEqual(saved, output)
                original = (output / "compatibility.json").read_bytes()
                self.assertEqual(json.loads(original), report)
                self.assertTrue((output / "RESULTS.md").read_text().startswith("| Check | Result |"))
                with self.assertRaises(FileExistsError):
                    live.save_report(report, output)
                self.assertEqual((output / "compatibility.json").read_bytes(), original)
                with self.assertRaises(ValueError):
                    live.save_report(report, root / "tracked-results")


if __name__ == "__main__":
    unittest.main()
