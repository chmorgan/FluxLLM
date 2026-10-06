#!/usr/bin/env python3
"""Bounded read-only Unsloth Studio / native llama.cpp compatibility probe.

No inference, model loading, logging changes, authentication, or raw response
capture. CPU/GPU measurements belong to the separate native performance run.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


MAX_RESPONSE_BYTES = 2 * 1024 * 1024
METRIC_NAMES = ("tokens_predicted_total", "prompt_tokens_total", "predicted_tokens_seconds",
                "requests_processing", "requests_deferred")
METRIC_PATTERN = re.compile(r"^llamacpp:([a-z_]+)(?:\{[^\n]*\})?\s+([^\s]+)(?:\s+\d+)?\s*$")


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def endpoint(value):
    try:
        url = urlsplit(value)
        valid = (url.scheme == "http" and url.hostname == "127.0.0.1" and url.port is not None
                 and 1 <= url.port <= 65535 and url.username is None and url.password is None
                 and url.path in ("", "/") and not url.query and not url.fragment)
    except ValueError:
        valid = False
    if not valid:
        raise ValueError("use an explicit numeric loopback root, such as http://127.0.0.1:8888")
    return "http://127.0.0.1:" + str(url.port)


def open_read_only(request, timeout):
    # Disable redirects and ambient proxy routing for these explicit local roots.
    from urllib.request import ProxyHandler
    return build_opener(ProxyHandler({}), NoRedirect()).open(request, timeout=timeout)


def numeric_metrics(data):
    values = {}
    overflowed = set()
    for line in data.decode("utf-8", errors="replace").splitlines():
        match = METRIC_PATTERN.fullmatch(line)
        if match is None or match.group(1) not in METRIC_NAMES:
            continue
        try:
            value = float(match.group(2))
        except ValueError:
            continue
        if math.isfinite(value) and value >= 0:
            # Labels and all unknown metric names are intentionally discarded.
            name = match.group(1)
            if name in overflowed:
                continue
            total = values.get(name, 0) + value
            if math.isfinite(total):
                values[name] = total
            else:
                values.pop(name, None)
                overflowed.add(name)
    return values


def read_endpoint(base, path, timeout=3, worker=True):
    request = Request(endpoint(base) + "/" + path + ("?autoload=false" if worker else ""),
                      headers={"Accept": "text/plain, application/json"}, method="GET")
    try:
        with open_read_only(request, timeout) as response:
            status = response.status
            if status != 200:
                return {"http_status": status, "available": False}
            data = response.read(MAX_RESPONSE_BYTES + 1)
            if len(data) > MAX_RESPONSE_BYTES:
                return {"http_status": status, "available": False, "error": "response_too_large"}
    except HTTPError as error:
        error.close()
        return {"http_status": error.code, "available": False}
    except (URLError, TimeoutError, OSError):
        return {"http_status": None, "available": False, "error": "connection_unavailable"}
    result = {"http_status": status, "available": True}
    if path == "metrics":
        result["values"] = numeric_metrics(data)
    elif path == "props":
        try:
            props = json.loads(data)
        except (ValueError, UnicodeDecodeError):
            props = {}
        if isinstance(props, dict):
            if type(props.get("endpoint_metrics")) is bool:
                result["endpoint_metrics"] = props["endpoint_metrics"]
            if type(props.get("total_slots")) is int and props["total_slots"] >= 0:
                result["total_slots"] = props["total_slots"]
            if isinstance(props.get("model_alias"), str):
                result["model_identity_sha256"] = hashlib.sha256(props["model_alias"].encode()).hexdigest()
    return result


def probe(studio, worker, samples=10, interval=1, timeout=3):
    studio = endpoint(studio)
    worker = endpoint(worker) if worker is not None else None
    if type(samples) is not int or not 1 <= samples <= 60:
        raise ValueError("samples must be between 1 and 60")
    if not math.isfinite(interval) or not 1 <= interval <= 5:
        raise ValueError("interval must be between 1 and 5 seconds")
    if not math.isfinite(timeout) or not 0 < timeout <= 5:
        raise ValueError("timeout must be between 0 and 5 seconds")
    started = time.monotonic()
    report = {"schema_version": 1, "mode": "read_only_compatibility",
              "captured_at_utc": datetime.now(timezone.utc).isoformat(),
              "studio": {"endpoint": studio, "health": read_endpoint(studio, "api/health", timeout, worker=False)},
              "worker": None, "samples": [], "requested_samples": samples, "interval_seconds": interval,
              "cpu_percent": None, "gpu_percent": None,
              "resource_measurement": "Requires separate native app CPU/GPU capture"}
    if worker is None:
        return report
    report["worker"] = {"endpoint": worker, "health": read_endpoint(worker, "health", timeout),
                        "props": read_endpoint(worker, "props", timeout)}
    for index in range(samples):
        if index:
            # Bound request rate to at most one metrics GET per second, including
            # when a previous response was slow (no catch-up scrape bursts).
            time.sleep(interval)
        sample = read_endpoint(worker, "metrics", timeout)
        sample["elapsed_seconds"] = round(time.monotonic() - started, 6)
        report["samples"].append(sample)
    report["worker"]["metrics_compatible"] = all(
        s["available"] and "requests_processing" in s.get("values", {})
        and "tokens_predicted_total" in s.get("values", {}) for s in report["samples"])
    return report


def save_report(report, output):
    output = Path(output).resolve()
    root = Path(__file__).resolve().parent.parent / ".performance-results"
    if root not in output.parents:
        raise ValueError("output must be a new directory under ignored .performance-results")
    output.mkdir(parents=True, exist_ok=False)
    (output / "compatibility.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    rows = ["| Check | Result |", "| --- | --- |",
            "| Studio health HTTP | {} |".format(report["studio"]["health"]["http_status"]),
            "| Worker | {} |".format("Explicit endpoint" if report["worker"] else "Not supplied / unloaded"),
            "| Metrics compatible | {} |".format(report["worker"]["metrics_compatible"] if report["worker"] else "Unavailable"),
            "| CPU / GPU | Unavailable here; requires native performance capture |", "",
            "| Sample | Elapsed s | HTTP | Active | Queued | Decode average tok/s | Output total | Prompt total |",
            "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for index, sample in enumerate(report["samples"]):
        values = sample.get("values", {})
        rows.append("| {} | {} | {} | {} | {} | {} | {} | {} |".format(index + 1, sample["elapsed_seconds"],
                    sample["http_status"], *(values.get(name, "Unavailable") for name in
                    ("requests_processing", "requests_deferred", "predicted_tokens_seconds",
                     "tokens_predicted_total", "prompt_tokens_total"))))
    (output / "RESULTS.md").write_text("\n".join(rows) + "\n")
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--studio", required=True, help="Explicit local Studio root, e.g. http://127.0.0.1:8888")
    parser.add_argument("--worker", help="Explicit observed native worker root, e.g. http://127.0.0.1:54234")
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--timeout", type=float, default=3)
    parser.add_argument("--output", required=True, help="New ignored .performance-results directory")
    args = parser.parse_args(argv)
    try:
        report = probe(args.studio, args.worker, args.samples, args.interval, args.timeout)
        output = save_report(report, args.output)
    except (ValueError, FileExistsError) as error:
        parser.error(str(error))
    print("Read-only compatibility summary: " + str(output / "RESULTS.md"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
