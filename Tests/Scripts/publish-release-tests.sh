#!/bin/bash
# Exercise GitHub publishing in disposable repos with local, fail-closed mocks.
# No GitHub request, app build, signing command, or Keychain access is performed.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$REPO_ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_ROOT = Path(sys.argv.pop(1))
VERSION = "1.2.3"
REPOSITORY = "chmorgan/fluxllm"
ASSETS = (f"FluxLLM-{VERSION}.zip", "SHA256SUMS", "release-info.txt")

MOCK_GH = r'''#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
if os.environ.get("GH_HOST") != "github.com" or os.environ.get("GH_PROMPT_DISABLED") != "1":
    sys.exit("Expected explicit GitHub host and disabled interactive prompts")
state_path = Path(os.environ["PUBLISH_TEST_STATE"])
state = json.loads(state_path.read_text())
with open(os.environ["PUBLISH_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": "gh", "args": args}) + "\n")

def save():
    state_path.write_text(json.dumps(state))

def fail(operation):
    if os.environ.get("PUBLISH_TEST_FAIL") == operation:
        sys.exit("Mock " + operation + " failure")

def option(name, default=None):
    for index, arg in enumerate(args):
        if arg == name:
            return args[index + 1]
        if arg.startswith(name + "="):
            return arg.split("=", 1)[1]
    return default

def bool_option(name, default):
    value = option(name)
    if name in args and (args.index(name) == len(args) - 1 or args[args.index(name) + 1].startswith("--")):
        return True
    if value is None:
        return default
    if value not in ("true", "false"):
        # gh also accepts the ordinary boolean flag before a positional value.
        return name in args
    return value == "true"

def release():
    item = state.get("release")
    if item is None:
        sys.exit("No mock release exists")
    return item

def capture_assets():
    asset_dir = Path(os.environ["PUBLISH_TEST_REMOTE_ASSETS"])
    asset_dir.mkdir(exist_ok=True)
    for arg in args[3:]:
        path = Path(arg)
        if path.name in state["assets"] and path.is_file():
            shutil.copyfile(path, asset_dir / path.name)
    state["release"]["assets"] = [
        {"name": path.name, "id": 1000 + index, "size": path.stat().st_size,
         "state": "uploaded", "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()}
        for index, path in enumerate(sorted(asset_dir.iterdir()))]

if args and args[0] == "api":
    endpoints = [arg for arg in args[1:] if arg.startswith("repos/")]
    if len(endpoints) != 1:
        sys.exit("Unexpected API invocation: " + repr(args))
    endpoint = endpoints[0]
    if endpoint == "repos/chmorgan/fluxllm":
        fail("visibility")
        state["visibility_reads"] = state.get("visibility_reads", 0) + 1
        result = state.get("repository", {"private": False})
        if state.get("private_after_read") and state["visibility_reads"] > state["private_after_read"]:
            result = {"private": True}
        save()
        print(json.dumps(result))
        sys.exit(0)
    prefix = "repos/chmorgan/fluxllm/"
    if not endpoint.startswith(prefix):
        sys.exit("Unexpected repository: " + endpoint)
    endpoint = endpoint[len(prefix):]
    if endpoint == "releases":
        fail("list")
        entries = [state["release"]] if state.get("release") else []
        print(json.dumps([entries] if "--slurp" in args else entries))
    elif endpoint.startswith("git/ref/tags/"):
        fail("remote-tag")
        if endpoint != "git/ref/tags/" + state["tag"]:
            sys.exit("Unexpected tag: " + endpoint)
        state["ref_reads"] = state.get("ref_reads", 0) + 1
        changed = state.get("change_tag_after")
        sha = "f" * 40 if changed and state["ref_reads"] > changed else state["remote_commit"]
        if state.get("annotated"):
            result = {"object": {"type": "tag", "sha": "a" * 40}}
        else:
            result = {"object": {"type": "commit", "sha": sha}}
        save()
        print(json.dumps(result))
    elif endpoint == "git/tags/" + "a" * 40 and state.get("annotated"):
        print(json.dumps({"object": {"type": "commit", "sha": state["remote_commit"]}}))
    elif endpoint.startswith("releases/assets/"):
        fail("download-published")
        if option("--header") != "Accept: application/octet-stream":
            sys.exit("Expected binary asset Accept header")
        asset_id = int(endpoint.rsplit("/", 1)[1])
        asset = next(item for item in release()["assets"] if item["id"] == asset_id)
        data = (Path(os.environ["PUBLISH_TEST_REMOTE_ASSETS"]) / asset["name"]).read_bytes()
        if os.environ.get("PUBLISH_TEST_CORRUPT_PUBLISHED"):
            data = b"x" * len(data)
        sys.stdout.buffer.write(data)
    elif endpoint.startswith("releases/"):
        fail("refresh")
        item = release()
        if endpoint != "releases/" + str(item["id"]):
            sys.exit("Unexpected release ID: " + endpoint)
        state["draft_reads"] = state.get("draft_reads", 0) + 1
        changed = state.get("publish_after_read")
        if changed and state["draft_reads"] >= changed:
            item["draft"] = False
        changes = state.get("release_changes_after_read")
        if changes and state["draft_reads"] >= changes[0]:
            item.update(changes[1])
        save()
        print(json.dumps(item))
    else:
        sys.exit("Unexpected API endpoint: " + endpoint)
elif args[:2] == ["release", "create"]:
    fail("create")
    if state.get("release"):
        sys.exit("Release already exists")
    if option("--repo") != "chmorgan/fluxllm":
        sys.exit("Missing expected explicit repository")
    state["release"] = {
        "id": 123, "tag_name": args[2], "draft": bool_option("--draft", False),
        "prerelease": bool_option("--prerelease", False),
        "html_url": "https://github.com/chmorgan/fluxllm/releases/tag/test-draft",
        "name": option("--title"), "body": Path(option("--notes-file")).read_text(),
    }
    capture_assets()
    save()
    print(state["release"]["html_url"])
elif args[:2] == ["release", "edit"]:
    fail("edit")
    item = release()
    if not item["draft"]:
        sys.exit("Forbidden mutation of published mock release")
    item["draft"] = bool_option("--draft", item["draft"])
    item["prerelease"] = bool_option("--prerelease", item["prerelease"])
    if option("--notes-file"):
        item["body"] = Path(option("--notes-file")).read_text()
    save()
elif args[:2] == ["release", "upload"]:
    fail("upload")
    if not release()["draft"]:
        sys.exit("Forbidden upload to published mock release")
    capture_assets()
    save()
elif args[:2] == ["release", "download"]:
    fail("download")
    target = Path(option("--dir"))
    target.mkdir(exist_ok=True, parents=True)
    patterns = [args[index + 1] for index, arg in enumerate(args) if arg == "--pattern"]
    patterns += [arg.split("=", 1)[1] for arg in args if arg.startswith("--pattern=")]
    if sorted(patterns) != sorted(state["assets"]):
        sys.exit("Unexpected asset selection: " + repr(patterns))
    for name in patterns:
        shutil.copyfile(Path(os.environ["PUBLISH_TEST_REMOTE_ASSETS"]) / name, target / name)
    if os.environ.get("PUBLISH_TEST_CORRUPT_DOWNLOAD"):
        (target / state["assets"][0]).write_bytes(b"corrupted remote archive")
elif args[:2] == ["release", "view"]:
    fail("view")
    if option("--json") != "url":
        sys.exit("Unexpected release view fields: " + repr(args))
    print(json.dumps({"url": release()["html_url"]}))
else:
    sys.exit("Unexpected gh invocation: " + repr(args))
'''

MOCK_VERIFY = r'''#!/bin/bash
set -euo pipefail
python3 - "$@" <<'VERIFY'
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
with open(os.environ["PUBLISH_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": "verify", "args": args}) + "\n")
if os.environ.get("PUBLISH_TEST_FAIL") == "verify":
    sys.exit("Mock archive verification failed")
if args[:2] != ["1.2.3", "--release-dir"] or len(args) != 3:
    sys.exit("Unexpected verification invocation: " + repr(args))
directory = Path(args[2])
for name in ("FluxLLM-1.2.3.zip", "SHA256SUMS", "release-info.txt"):
    if not (directory / name).is_file():
        sys.exit("Missing verification input: " + name)
if os.environ.get("PUBLISH_TEST_CHANGE_LOCAL_AFTER_VERIFY"):
    Path(os.environ["PUBLISH_TEST_CHANGE_LOCAL_AFTER_VERIFY"]).write_bytes(b"edited after snapshot")
VERIFY
'''

MOCK_NOTES = r'''#!/bin/bash
set -euo pipefail
python3 - "$@" <<'NOTES'
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
with open(os.environ["PUBLISH_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": "notes", "args": args}) + "\n")
if args[:2] != ["1.2.3", "--output"] or len(args) != 3:
    sys.exit("Unexpected notes invocation: " + repr(args))
if os.environ.get("PUBLISH_TEST_FAIL") == "notes":
    sys.exit("Mock notes generation failed")
with Path(args[2]).open("x") as file:
    file.write("# FluxLLM 1.2.3\n\nGenerated fixture notes.\n")
NOTES
'''

MOCK_CASKS = r'''#!/bin/bash
set -euo pipefail
python3 - "$@" <<'CASKS'
import json
import os
from pathlib import Path
import sys
args = sys.argv[1:]
with open(os.environ["PUBLISH_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": "casks", "args": args}) + "\n")
if len(args) != 5 or args[:2] != ["1.2.3", "--release-dir"] or args[3] != "--output-dir":
    sys.exit("Unexpected cask generation invocation: " + repr(args))
if os.environ.get("PUBLISH_TEST_FAIL") == "casks":
    sys.exit("Mock cask generation failure")
source = Path(args[2])
for name in ("FluxLLM-1.2.3.zip", "SHA256SUMS", "release-info.txt"):
    if not (source / name).is_file():
        sys.exit("Missing verified artifact for cask generation")
state_path = Path(os.environ["PUBLISH_TEST_STATE"])
state = json.loads(state_path.read_text())
if state.get("change_after_casks"):
    state["release"].update(state["change_after_casks"])
if state.get("change_tag_after_casks"):
    state["remote_commit"] = "f" * 40
state_path.write_text(json.dumps(state))
output = Path(args[4])
output.mkdir()
for name in ("fluxllm.rb", "fluxllm@1.2.3.rb"):
    (output / name).write_text("generated fixture: " + name + "\n")
CASKS
'''

MOCK_TAP = r'''import json
import os
from pathlib import Path

def update_tap(source_repo, tag, cask_dir, stable):
    with open(os.environ["PUBLISH_TEST_LOG"], "a") as log:
        log.write(json.dumps({"tool": "tap", "repo": str(source_repo), "tag": tag,
                              "casks": str(cask_dir), "stable": stable}) + "\n")
    if tag != "1.2.3" or type(stable) is not bool:
        raise RuntimeError("Unexpected tap invocation")
    for name in ("fluxllm.rb", "fluxllm@1.2.3.rb"):
        if (Path(cask_dir) / name).read_text() != "generated fixture: " + name + "\n":
            raise RuntimeError("Expected generated cask bytes")
    if os.environ.get("PUBLISH_TEST_FAIL") == "tap":
        raise RuntimeError("Mock tap push failure")
    state_path = Path(os.environ["PUBLISH_TEST_STATE"])
    state = json.loads(state_path.read_text())
    desired = {"tag": tag, "stable": stable}
    updated = state.get("tap") != desired
    if updated:
        state["tap"] = desired
        state["tap_commits"] = state.get("tap_commits", 0) + 1
        state_path.write_text(json.dumps(state))
    return {"updated": updated, "commit": "a" * 40 if updated else None}
'''


class PublishReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fluxllm-publish-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "source repo"
        self.repo.mkdir()
        self.mockbin = self.root / "mockbin"
        self.mockbin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.state_file = self.root / "state.json"
        self.remote_assets = self.root / "remote assets"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("PUBLISH_TEST_")}
        self.env.update({
            "PATH": str(self.mockbin) + os.pathsep + os.environ["PATH"],
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "PUBLISH_TEST_LOG": str(self.log), "PUBLISH_TEST_STATE": str(self.state_file),
            "PUBLISH_TEST_REMOTE_ASSETS": str(self.remote_assets),
        })
        shutil.copyfile(SOURCE_ROOT / "publish-release.sh", self.repo / "publish-release.sh")
        for name, content in (("verify-release.sh", MOCK_VERIFY), ("generate-release-notes.sh", MOCK_NOTES),
                              ("generate-release-casks.sh", MOCK_CASKS)):
            (self.repo / name).write_text(content)
            (self.repo / name).chmod(0o755)
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts/release_cask_tap.py").write_text(MOCK_TAP)
        (self.mockbin / "gh").write_text(MOCK_GH)
        (self.mockbin / "gh").chmod(0o755)
        (self.repo / ".gitignore").write_text(".build/\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Fixture release")
        self.git("tag", VERSION)
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.state_file.write_text(json.dumps({
            "tag": VERSION, "remote_commit": self.commit,
            "assets": list(ASSETS), "release": None,
        }))
        self.release_dir = self.repo / ".build/releases" / VERSION
        self.release_dir.mkdir(parents=True)
        for name in ASSETS:
            (self.release_dir / name).write_bytes(("Fixture content for " + name + "\n").encode())
        self.notes = self.release_dir / "release-notes.md"
        self.notes.write_text("# FluxLLM 1.2.3\n\nCarefully edited notes.\n")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)

    def run_script(self, *args, success=True):
        result = subprocess.run(["bash", str(self.repo / "publish-release.sh"), *args],
                                cwd=self.root, env=self.env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def state(self):
        return json.loads(self.state_file.read_text())

    def update_state(self, **changes):
        state = self.state()
        state.update(changes)
        self.state_file.write_text(json.dumps(state))

    def calls(self, tool=None):
        entries = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        return [entry for entry in entries if tool is None or entry["tool"] == tool]

    def mutations(self):
        return [call for call in self.calls("gh")
                if call["args"][:2] in (["release", "create"], ["release", "edit"], ["release", "upload"])]

    def assert_not_published(self):
        item = self.state().get("release")
        self.assertTrue(item is None or item["draft"])
        for call in self.mutations():
            self.assertNotIn("--draft=false", call["args"])

    def existing_draft(self, **changes):
        item = {"id": 123, "tag_name": VERSION, "draft": True, "prerelease": True,
                "html_url": "https://github.com/chmorgan/fluxllm/releases/tag/test-draft",
                "name": "FluxLLM 1.2.3", "body": "Old notes"}
        item.update(changes)
        self.update_state(release=item)
        self.remote_assets.mkdir(exist_ok=True)
        for name in ASSETS:
            (self.remote_assets / name).write_text("previous asset content")

    def existing_published(self, **changes):
        import hashlib
        self.existing_draft(draft=False)
        for name in ASSETS:
            shutil.copyfile(self.release_dir / name, self.remote_assets / name)
        item = self.state()["release"]
        item["assets"] = [
            {"name": name, "id": 1000 + index, "state": "uploaded",
             "size": (self.remote_assets / name).stat().st_size,
             "digest": "sha256:" + hashlib.sha256((self.remote_assets / name).read_bytes()).hexdigest()}
            for index, name in enumerate(ASSETS)]
        item.update(changes)
        self.update_state(release=item)

    def test_default_creates_verified_draft_prerelease(self):
        result = self.run_script(VERSION)
        item = self.state()["release"]
        self.assertTrue(item["draft"])
        self.assertTrue(item["prerelease"])
        self.assertEqual(item["name"], "FluxLLM " + VERSION)
        self.assertEqual(item["body"], self.notes.read_text())
        self.assertIn(item["html_url"], result.stdout)
        self.assertTrue(self.calls("verify"))
        self.assertFalse(self.calls("notes"))
        self.assertFalse(self.calls("casks"))
        self.assertFalse(self.calls("tap"))
        self.assertEqual(sorted(path.name for path in self.remote_assets.iterdir()), sorted(ASSETS))
        self.assertTrue(any(call["args"][:2] == ["release", "download"] for call in self.calls("gh")))
        first_mutation = self.calls().index(self.mutations()[0])
        self.assertLess(self.calls().index(self.calls("verify")[0]), first_mutation)

    def test_publish_uploads_and_checks_assets_before_making_release_public(self):
        self.run_script(VERSION, "--publish")
        self.assertFalse(self.state()["release"]["draft"])
        self.assertTrue(self.state()["release"]["prerelease"])
        calls = self.calls("gh")
        create = next(call for call in calls if call["args"][:2] == ["release", "create"])
        self.assertIn("--draft", create["args"])
        download_index = next(index for index, call in enumerate(calls) if call["args"][:2] == ["release", "download"])
        publish_index = next(index for index, call in enumerate(calls) if "--draft=false" in call["args"])
        self.assertLess(download_index, publish_index)
        self.assertGreaterEqual(self.state()["ref_reads"], 2)

    def test_stable_release_can_be_staged(self):
        self.run_script(VERSION, "--stable")
        self.assertTrue(self.state()["release"]["draft"])
        self.assertFalse(self.state()["release"]["prerelease"])

    def test_stable_release_can_be_published(self):
        self.run_script(VERSION, "--stable", "--publish")
        self.assertFalse(self.state()["release"]["draft"])
        self.assertFalse(self.state()["release"]["prerelease"])
        self.assertEqual(len(self.calls("tap")), 1)
        self.assertTrue(self.calls("tap")[0]["stable"])

    def test_published_prerelease_updates_only_exact_cask_after_verification(self):
        self.run_script(VERSION, "--publish")
        self.assertEqual(len(self.calls("casks")), 1)
        self.assertEqual(len(self.calls("tap")), 1)
        self.assertFalse(self.calls("tap")[0]["stable"])
        calls = self.calls()
        published = next(index for index, item in enumerate(calls) if "--draft=false" in item.get("args", []))
        last_verify = max(index for index, item in enumerate(calls) if item["tool"] == "verify")
        casks = next(index for index, item in enumerate(calls) if item["tool"] == "casks")
        tap = next(index for index, item in enumerate(calls) if item["tool"] == "tap")
        self.assertLess(published, last_verify)
        self.assertLess(last_verify, casks)
        self.assertLess(casks, tap)
        self.assertEqual(Path(self.calls("verify")[-1]["args"][2]), Path(self.calls("casks")[0]["args"][2]))
        self.assertFalse((self.repo / "scripts/__pycache__").exists())

    def test_published_retry_finishes_tap_without_another_release_mutation(self):
        self.existing_published(prerelease=False)
        shutil.rmtree(self.release_dir)
        self.run_script(VERSION, "--publish")
        self.run_script(VERSION, "--publish")
        self.assertFalse(self.mutations())
        self.assertEqual(self.state()["tap_commits"], 1)
        self.assertEqual(len(self.calls("tap")), 2)
        self.assertTrue(all(item["stable"] for item in self.calls("tap")))

    def test_private_repository_blocks_draft_and_publication_mutations(self):
        self.update_state(repository={"private": True})
        for flags in ((), ("--publish",)):
            with self.subTest(flags=flags):
                result = self.run_script(VERSION, *flags, success=False)
                self.assertIn("public chmorgan/fluxllm repository", result.stderr)
        self.assertFalse(self.mutations())
        self.assertFalse(self.calls("casks"))
        self.assertFalse(self.calls("tap"))

    def test_malformed_repository_visibility_blocks_mutations(self):
        for repository in ({}, {"private": 0}, {"private": "false"}, []):
            with self.subTest(repository=repository):
                self.update_state(repository=repository)
                self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())
        self.assertFalse(self.calls("tap"))

    def test_visibility_api_failure_blocks_mutations(self):
        self.env["PUBLISH_TEST_FAIL"] = "visibility"
        self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())

    def test_private_published_release_reports_pending_tap(self):
        self.existing_published()
        self.update_state(repository={"private": True})
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("is published, but the Homebrew tap update is pending", result.stderr)
        self.assertIn("./publish-release.sh " + VERSION + " --publish", result.stderr)
        self.assertFalse(self.calls("casks"))
        self.assertFalse(self.calls("tap"))
        self.assertFalse(self.mutations())

    def test_visibility_rechecked_before_updating_tap_after_publication(self):
        self.update_state(private_after_read=1)
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.state()["release"]["draft"])
        self.assertIn("Homebrew tap update is pending", result.stderr)
        self.assertFalse(self.calls("casks"))
        self.assertFalse(self.calls("tap"))

    def test_visibility_changed_during_cask_generation_never_updates_tap(self):
        self.existing_published()
        self.update_state(private_after_read=1)
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("Homebrew tap update is pending", result.stderr)
        self.assertTrue(self.calls("casks"))
        self.assertFalse(self.calls("tap"))
        self.assertFalse(self.mutations())

    def test_cask_generation_failure_preserves_published_release_and_can_resume(self):
        self.env["PUBLISH_TEST_FAIL"] = "casks"
        result = self.run_script(VERSION, "--publish", success=False)
        release = self.state()["release"]
        self.assertFalse(release["draft"])
        self.assertIn("Homebrew tap update is pending", result.stderr)
        self.assertFalse(self.calls("tap"))
        mutation_count = len(self.mutations())
        del self.env["PUBLISH_TEST_FAIL"]
        self.run_script(VERSION, "--publish")
        self.assertEqual(self.state()["release"], release)
        self.assertEqual(len(self.mutations()), mutation_count)
        self.assertEqual(self.state()["tap_commits"], 1)

    def test_tap_failure_preserves_release_and_quotes_complete_retry_command(self):
        self.existing_published()
        custom = self.root / "release output's $(touch unexpected)"
        shutil.move(str(self.release_dir), str(custom))
        self.env["PUBLISH_TEST_FAIL"] = "tap"
        result = self.run_script(VERSION, "--publish", "--release-dir", str(custom), success=False)
        self.assertIn("Homebrew tap update is pending", result.stderr)
        retry = next(line.removeprefix("Retry: ") for line in result.stderr.splitlines() if line.startswith("Retry: "))
        self.assertEqual(shlex.split(retry), ["./publish-release.sh", VERSION, "--publish", "--release-dir", str(custom)])
        self.assertFalse(self.mutations())
        self.assertNotIn("tap_commits", self.state())

    def test_missing_tap_helper_reports_pending_tap(self):
        self.existing_published()
        (self.repo / "scripts/release_cask_tap.py").unlink()
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("Homebrew tap update is pending", result.stderr)
        self.assertFalse(self.calls("tap"))
        self.assertFalse(self.mutations())

    def test_release_changed_during_cask_generation_never_updates_tap(self):
        self.existing_published()
        self.update_state(change_after_casks={"prerelease": False})
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("changed during cask generation", result.stderr)
        self.assertIn("Homebrew tap update is pending", result.stderr)
        self.assertFalse(self.calls("tap"))
        self.assertFalse(self.mutations())

    def test_tag_changed_during_cask_generation_never_updates_tap(self):
        self.existing_published()
        self.update_state(change_tag_after_casks=True)
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("Homebrew tap update is pending", result.stderr)
        self.assertFalse(self.calls("tap"))
        self.assertFalse(self.mutations())

    def test_existing_draft_updates_assets_and_notes(self):
        self.existing_draft()
        self.run_script(VERSION)
        self.assertFalse(any(call["args"][:2] == ["release", "create"] for call in self.calls("gh")))
        self.assertTrue(any(call["args"][:2] == ["release", "upload"] for call in self.calls("gh")))
        self.assertEqual(self.state()["release"]["body"], self.notes.read_text())
        for name in ASSETS:
            self.assertEqual((self.remote_assets / name).read_bytes(), (self.release_dir / name).read_bytes())

    def test_existing_published_release_is_immutable(self):
        self.existing_published()
        before = self.state()["release"]
        result = self.run_script(VERSION, "--publish")
        self.assertIn("Published prerelease verified", result.stdout)
        self.assertEqual(self.state()["release"], before)
        self.assertFalse(self.mutations())

    def test_published_retry_recovers_without_local_artifacts_or_notes(self):
        self.existing_published(prerelease=False)
        shutil.rmtree(self.release_dir)
        result = self.run_script(VERSION, "--publish")
        self.assertIn("Published stable release verified", result.stdout)
        self.assertFalse(self.release_dir.exists())
        self.assertFalse(self.calls("notes"))
        self.assertEqual(len(self.calls("verify")), 1)
        self.assertFalse(self.mutations())
        verified = Path(self.calls("verify")[0]["args"][2])
        self.assertFalse(verified.exists())

    def test_published_verification_without_publish_is_read_only(self):
        self.existing_published()
        self.run_script(VERSION)
        self.assertFalse(self.mutations())
        self.assertEqual(len(self.calls("verify")), 1)
        self.assertFalse(self.calls("casks"))
        self.assertFalse(self.calls("tap"))

    def test_published_prerelease_preserved_with_stable_flag(self):
        self.existing_published()
        result = self.run_script(VERSION, "--publish", "--stable")
        self.assertIn("Published prerelease verified", result.stdout)
        self.assertTrue(self.state()["release"]["prerelease"])
        self.assertFalse(self.calls("tap")[0]["stable"])
        self.assertFalse(self.mutations())

    def test_published_retry_does_not_require_or_modify_notes(self):
        self.existing_published()
        self.notes.unlink()
        self.run_script(VERSION, "--publish")
        self.assertFalse(self.notes.exists())
        self.assertFalse(self.calls("notes"))

    def test_published_retry_rejects_different_local_artifacts(self):
        self.existing_published()
        (self.release_dir / ASSETS[0]).write_bytes(b"different local archive")
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("differs from the supplied local file", result.stderr)
        self.assertFalse(self.mutations())

    def test_published_retry_rejects_partial_local_directory(self):
        self.existing_published()
        (self.release_dir / ASSETS[0]).unlink()
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("Required file is missing", result.stderr)
        self.assertFalse(self.mutations())

    def test_published_retry_rejects_explicit_missing_directory(self):
        self.existing_published()
        result = self.run_script(VERSION, "--publish", "--release-dir", str(self.root / "missing"), success=False)
        self.assertIn("Release directory does not exist", result.stderr)
        self.assertFalse(self.calls())

    def test_published_retry_rejects_dangling_default_directory_symlink(self):
        self.existing_published()
        shutil.rmtree(self.release_dir)
        self.release_dir.symlink_to(self.root / "missing")
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("must not be a symlink", result.stderr)
        self.assertFalse(self.calls())

    def test_published_retry_rejects_missing_or_extra_assets(self):
        self.existing_published()
        assets = self.state()["release"]["assets"]
        for changed in (assets[:-1], assets + [dict(assets[0], name="unexpected.zip")]):
            with self.subTest(assets=changed):
                item = self.state()["release"]
                item["assets"] = changed
                self.update_state(release=item)
                self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())

    def test_published_retry_rejects_invalid_release_metadata(self):
        self.existing_published()
        initial = self.state()["release"]
        for changes in ({"id": True}, {"id": -1}, {"prerelease": None}, {"assets": None}):
            with self.subTest(changes=changes):
                self.update_state(release=dict(initial, **changes))
                self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())

    def test_published_retry_rejects_invalid_asset_metadata(self):
        self.existing_published()
        initial = self.state()["release"]
        for changes in ({"id": True}, {"id": -1}, {"id": 1001}, {"size": "10"},
                        {"state": "new"}, {"digest": "invalid"}):
            with self.subTest(changes=changes):
                item = json.loads(json.dumps(initial))
                item["assets"][0].update(changes)
                self.update_state(release=item)
                self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())

    def test_published_retry_rejects_corrupted_download(self):
        self.existing_published()
        self.env["PUBLISH_TEST_CORRUPT_PUBLISHED"] = "1"
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("checksum differs from GitHub metadata", result.stderr)
        self.assertFalse(self.calls("verify"))
        self.assertFalse(self.mutations())

    def test_published_retry_accepts_legacy_assets_without_github_digest(self):
        self.existing_published()
        item = self.state()["release"]
        for asset in item["assets"]:
            asset.pop("digest")
        self.update_state(release=item)
        self.run_script(VERSION, "--publish")
        self.assertTrue(self.calls("verify"))
        self.assertFalse(self.mutations())

    def test_published_retry_verifier_failure_is_not_success(self):
        self.existing_published()
        self.env["PUBLISH_TEST_FAIL"] = "verify"
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertIn("Homebrew tap update is pending", result.stderr)
        self.assertIn("Retry: ./publish-release.sh " + VERSION + " --publish", result.stderr)
        self.assertFalse(self.calls("tap"))
        self.assertFalse(self.mutations())

    def test_published_retry_download_failure_is_not_success(self):
        self.existing_published()
        self.env["PUBLISH_TEST_FAIL"] = "download-published"
        self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())

    def test_failure_after_publication_explains_safe_retry(self):
        self.env["PUBLISH_TEST_FAIL"] = "download-published"
        result = self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.state()["release"]["draft"])
        self.assertIn("release was published, but final verification failed", result.stderr)
        self.assertIn("Rerun the same command", result.stderr)
        self.assertIn("Homebrew tap update is pending", result.stderr)
        self.assertFalse(self.calls("tap"))

    def test_published_retry_rechecks_remote_tag(self):
        self.existing_published()
        self.update_state(change_tag_after=1)
        self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())

    def test_published_retry_rejects_release_changed_during_verification(self):
        self.existing_published()
        initial = self.state()["release"]
        changed_assets = json.loads(json.dumps(initial["assets"]))
        changed_assets[0]["id"] += 10
        for changes in ({"id": 456}, {"prerelease": False}, {"draft": True},
                        {"assets": changed_assets}):
            with self.subTest(changes=changes):
                self.update_state(release=initial, draft_reads=0, release_changes_after_read=[2, changes])
                result = self.run_script(VERSION, "--publish", success=False)
                self.assertNotIn("Published prerelease verified", result.stdout)
        self.assertFalse(self.mutations())

    def test_unexpected_draft_assets_are_not_overwritten_or_published(self):
        self.existing_draft(assets=[{"name": "unexpected-secret.txt"}])
        self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())

    def test_duplicate_draft_assets_are_rejected(self):
        self.existing_draft(assets=[{"name": ASSETS[0]}, {"name": ASSETS[0]}])
        self.run_script(VERSION, success=False)
        self.assertFalse(self.mutations())

    def test_remote_tag_mismatch_blocks_all_github_mutations(self):
        self.update_state(remote_commit="b" * 40)
        self.run_script(VERSION, "--publish", success=False)
        self.assertFalse(self.mutations())

    def test_annotated_remote_tag_is_resolved(self):
        self.update_state(annotated=True)
        self.run_script(VERSION)
        self.assertTrue(any("repos/chmorgan/fluxllm/git/tags/" + "a" * 40 in call["args"] for call in self.calls("gh")))

    def test_changed_remote_tag_blocks_publication(self):
        self.update_state(change_tag_after=1)
        self.run_script(VERSION, "--publish", success=False)
        self.assert_not_published()

    def test_draft_becoming_published_blocks_update(self):
        self.existing_draft()
        self.update_state(publish_after_read=1)
        self.run_script(VERSION, success=False)
        self.assertFalse(self.mutations())

    def test_existing_notes_are_preserved_exactly(self):
        content = "# My curated release\n\nLiteral `$HOME` and apostrophes aren't shell commands.\n"
        self.notes.write_text(content)
        self.run_script(VERSION)
        self.assertEqual(self.notes.read_text(), content)
        self.assertEqual(self.state()["release"]["body"], content)
        self.assertFalse(self.calls("notes"))

    def test_missing_notes_are_generated(self):
        self.notes.unlink()
        self.run_script(VERSION)
        self.assertEqual(len(self.calls("notes")), 1)
        self.assertIn("Generated fixture notes", self.notes.read_text())
        self.assertEqual(self.state()["release"]["body"], self.notes.read_text())

    def test_notes_generation_failure_blocks_mutations(self):
        self.notes.unlink()
        self.env["PUBLISH_TEST_FAIL"] = "notes"
        self.run_script(VERSION, success=False)
        self.assertFalse(self.mutations())

    def test_empty_notes_are_rejected(self):
        self.notes.write_text("  \n")
        self.run_script(VERSION, success=False)
        self.assertFalse(self.mutations())

    def test_symlink_notes_are_rejected(self):
        target = self.root / "external notes.md"
        target.write_text("External notes")
        self.notes.unlink()
        self.notes.symlink_to(target)
        self.run_script(VERSION, success=False)
        self.assertFalse(self.mutations())

    def test_missing_default_release_directory_explains_packaging_first(self):
        shutil.rmtree(self.release_dir)
        result = self.run_script(VERSION, success=False)
        self.assertIn("Release directory does not exist", result.stderr)
        self.assertIn("./package-release.sh " + VERSION, result.stderr)
        self.assertIn("Release ready", result.stderr)
        self.assertFalse(self.release_dir.exists())
        self.assertFalse(self.mutations())

    def test_missing_custom_release_directory_suggests_shell_quoted_packaging_command(self):
        custom = self.root / "release output's $(touch unexpected); [draft]"
        result = self.run_script(VERSION, "--release-dir", str(custom), success=False)
        self.assertIn("Release directory does not exist", result.stderr)
        command = next(line[line.index("./package-release.sh"):].strip()
                       for line in result.stderr.splitlines() if "./package-release.sh" in line)
        self.assertEqual(shlex.split(command),
                         ["./package-release.sh", VERSION, "--output-dir", str(custom.resolve())])
        self.assertIn("Release ready", result.stderr)
        self.assertFalse(custom.exists())
        self.assertFalse(self.calls())

    def test_release_path_that_is_a_file_is_reported_as_not_a_directory(self):
        custom = self.root / "release file"
        custom.write_text("This is not a release directory.\n")
        result = self.run_script(VERSION, "--release-dir", str(custom), success=False)
        self.assertIn("not a directory", result.stderr)
        self.assertNotIn("does not exist", result.stderr)
        self.assertEqual(custom.read_text(), "This is not a release directory.\n")
        self.assertFalse(self.calls())

    def test_missing_asset_is_reported_as_missing(self):
        (self.release_dir / ASSETS[0]).unlink()
        result = self.run_script(VERSION, success=False)
        self.assertIn("Required file is missing", result.stderr)
        self.assertNotIn("symlink", result.stderr)
        self.assertFalse(self.calls())

    def test_symlink_asset_is_rejected(self):
        target = self.root / "external archive.zip"
        target.write_bytes(b"outside fixture")
        (self.release_dir / ASSETS[0]).unlink()
        (self.release_dir / ASSETS[0]).symlink_to(target)
        result = self.run_script(VERSION, success=False)
        self.assertIn("symlink", result.stderr)
        self.assertNotIn("Required file is missing", result.stderr)
        self.assertFalse(self.calls())

    def test_local_archive_verification_failure_blocks_mutations(self):
        self.env["PUBLISH_TEST_FAIL"] = "verify"
        self.run_script(VERSION, success=False)
        self.assertFalse(self.mutations())

    def test_publishing_uses_the_verified_snapshot_despite_later_local_edits(self):
        archive = self.release_dir / ASSETS[0]
        verified_bytes = archive.read_bytes()
        self.env["PUBLISH_TEST_CHANGE_LOCAL_AFTER_VERIFY"] = str(archive)
        self.run_script(VERSION, "--publish")
        self.assertNotEqual(archive.read_bytes(), verified_bytes)
        self.assertEqual((self.remote_assets / ASSETS[0]).read_bytes(), verified_bytes)

    def test_inherited_github_host_does_not_redirect_publication(self):
        self.env["GH_HOST"] = "enterprise.example.invalid"
        self.env["GH_PROMPT_DISABLED"] = "0"
        self.run_script(VERSION)

    def test_create_failure_does_not_attempt_publication(self):
        self.env["PUBLISH_TEST_FAIL"] = "create"
        self.run_script(VERSION, "--publish", success=False)
        self.assert_not_published()
        self.assertFalse(any(call["args"][:2] == ["release", "edit"] for call in self.calls("gh")))

    def test_github_listing_failure_does_not_create_a_release(self):
        self.env["PUBLISH_TEST_FAIL"] = "list"
        self.run_script(VERSION, success=False)
        self.assertFalse(self.mutations())

    def test_draft_upload_failure_does_not_publish(self):
        self.existing_draft()
        self.env["PUBLISH_TEST_FAIL"] = "upload"
        self.run_script(VERSION, "--publish", success=False)
        self.assert_not_published()

    def test_download_failure_does_not_publish(self):
        self.env["PUBLISH_TEST_FAIL"] = "download"
        self.run_script(VERSION, "--publish", success=False)
        self.assert_not_published()

    def test_downloaded_archive_mismatch_does_not_publish(self):
        self.env["PUBLISH_TEST_CORRUPT_DOWNLOAD"] = "1"
        self.run_script(VERSION, "--publish", success=False)
        self.assert_not_published()

    def test_custom_release_directory_with_spaces(self):
        custom = self.root / "custom release directory"
        shutil.move(str(self.release_dir), str(custom))
        self.run_script(VERSION, "--release-dir", str(custom))
        self.assertEqual(self.state()["release"]["body"], (custom / "release-notes.md").read_text())

    def test_invalid_tag_forms_are_rejected(self):
        for tag in ("v1.2.3", "01.2.3", "1.2", "1.2.3-beta", "../1.2.3"):
            with self.subTest(tag=tag):
                self.run_script(tag, success=False)
        self.assertFalse(self.mutations())

    def test_missing_local_tag_is_rejected(self):
        self.git("tag", "-d", VERSION)
        self.run_script(VERSION, success=False)
        self.assertFalse(self.mutations())

    def test_unknown_arguments_are_rejected(self):
        self.run_script(VERSION, "--surprise", success=False)
        self.assertFalse(self.mutations())


unittest.main(verbosity=2)
PY
