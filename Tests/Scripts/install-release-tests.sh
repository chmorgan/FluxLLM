#!/bin/bash
# Disposable app fixtures; verification, application lifecycle, and launch are mocked.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$REPO_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_ROOT = Path(sys.argv.pop(1))
VERSION = "1.2.3"
BUNDLE_ID = "com.cmorgan.FluxLLM"
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["INSTALL_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": tool, "args": args}) + "\n")
state_path = Path(os.environ["INSTALL_TEST_STATE"])
state = json.loads(state_path.read_text())
if tool == "uname" and args == ["-s"]:
    print(os.environ.get("INSTALL_TEST_PLATFORM", "Darwin"))
elif tool == "lipo" and len(args) == 2 and args[0] == "-archs":
    print("arm64")
elif tool == "codesign" and args[:-1] == ["--verify", "--deep", "--strict", "--verbose=2"]:
    pass
elif tool == "xcrun" and args[:-1] == ["stapler", "validate"]:
    pass
elif tool == "spctl" and args[:-1] == ["--assess", "--type", "execute", "--verbose=2"]:
    pass
elif tool == "osascript" and args[:3] == ["-l", "JavaScript", "-e"]:
    action = args[4:]
    if action == ["list"]:
        if os.environ.get("INSTALL_TEST_LIFECYCLE_FAIL"):
            sys.exit(40)
        if os.environ.get("INSTALL_TEST_MALFORMED_STATE"):
            print("not JSON")
        else:
            print(json.dumps(state["apps"]))
            if state.get("launched") and os.environ.get("INSTALL_TEST_EARLY_EXIT"):
                state["apps"] = []
                state_path.write_text(json.dumps(state))
    elif len(action) == 2 and action[0] == "terminate":
        pid = int(action[1])
        if os.environ.get("INSTALL_TEST_EXIT_DURING_QUIT"):
            state["apps"] = [app for app in state["apps"] if app["pid"] != pid]
            state_path.write_text(json.dumps(state))
            print("false")
        elif os.environ.get("INSTALL_TEST_REFUSE_TERMINATE"):
            print("false")
        else:
            if not os.environ.get("INSTALL_TEST_KEEP_RUNNING"):
                state["apps"] = [app for app in state["apps"] if app["pid"] != pid]
                state_path.write_text(json.dumps(state))
            print("true")
    else:
        sys.exit("Unexpected lifecycle call: " + repr(action))
elif tool == "open" and len(args) == 2 and args[0] == "-n":
    if os.environ.get("INSTALL_TEST_OPEN_FAIL"):
        sys.exit(40)
    target = args[1]
    if os.environ.get("INSTALL_TEST_WRONG_PATH"):
        target = str(Path(target).parent / "Elsewhere.app")
    if not os.environ.get("INSTALL_TEST_NO_APP"):
        state["apps"].append({"pid": 12345, "path": target})
    state["launched"] = True
    state_path.write_text(json.dumps(state))
    if os.environ.get("INSTALL_TEST_OPEN_FAIL_AFTER_LAUNCH"):
        sys.exit(40)
else:
    sys.exit("Unexpected installer tool call: " + tool + repr(args))
'''

VERIFIER = r'''#!/bin/bash
set -euo pipefail
exec python3 - "$@" <<'VERIFY'
import argparse
import json
import os
from pathlib import Path
import plistlib
import sys
parser = argparse.ArgumentParser()
parser.add_argument("tag")
parser.add_argument("--release-dir")
parser.add_argument("--extract-to", required=True)
args = parser.parse_args()
with open(os.environ["INSTALL_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": "verifier", "args": sys.argv[1:]}) + "\n")
if os.environ.get("INSTALL_TEST_VERIFY_FAIL"):
    sys.exit("Verification fixture rejected archive")
destination = Path(args.extract_to)
destination.mkdir()
app = destination / "FluxLLM.app"
(app / "Contents/MacOS").mkdir(parents=True)
(app / "Contents/Resources").mkdir()
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.cmorgan.FluxLLM", "CFBundleExecutable": "FluxLLMApp",
    "CFBundleShortVersionString": args.tag, "CFBundleVersion": args.tag,
}))
(app / "Contents/MacOS/FluxLLMApp").write_bytes(b"verified executable bytes")
(app / "Contents/MacOS/FluxLLMApp").chmod(0o755)
(app / "Contents/Resources/verified.txt").write_text("The verifier exported this exact app.\n")
(app / "Contents/Resources/VerifiedLink").symlink_to("verified.txt")
VERIFY
'''


class InstallReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fluxllm-install-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / "source repo"
        self.repo.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.install_dir = self.root / "custom Applications"
        self.target = self.install_dir / "FluxLLM.app"
        self.mockbin = self.root / "mockbin"
        self.mockbin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"apps": []}))
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("INSTALL_TEST_")}
        self.env.update(PATH=f"{self.mockbin}:{os.environ['PATH']}", HOME=str(self.home),
                        INSTALL_TEST_LOG=str(self.log), INSTALL_TEST_STATE=str(self.state))
        (self.mockbin / "mock").write_text(MOCK)
        (self.mockbin / "mock").chmod(0o755)
        for tool in ("uname", "osascript", "open", "lipo", "codesign", "xcrun", "spctl"):
            (self.mockbin / tool).symlink_to("mock")
        source = (SOURCE_ROOT / "install-release.sh").read_text()
        # Keep production wait behavior, with shorter deadlines only in the disposable copy.
        source = source.replace("LAUNCH_TIMEOUT = 10.0", "LAUNCH_TIMEOUT = 0.8")
        source = source.replace("QUIT_TIMEOUT = 15.0", "QUIT_TIMEOUT = 0.8")
        source = source.replace("STARTUP_GRACE = 3.0", "STARTUP_GRACE = 0.2")
        source = source.replace("POLL_INTERVAL = 0.25", "POLL_INTERVAL = 0.05")
        (self.repo / "install-release.sh").write_text(source)
        (self.repo / "install-release.sh").chmod(0o755)
        (self.repo / "verify-release.sh").write_text(VERIFIER)
        (self.repo / "verify-release.sh").chmod(0o755)

    def install(self, *extra, tag=VERSION, env=None, launch=False, default=False):
        command = [str(self.repo / "install-release.sh"), tag]
        if not default:
            command += ["--install-dir", str(self.install_dir)]
        if not launch:
            command += ["--no-launch"]
        return subprocess.run(command + list(extra), cwd=self.root, env=dict(self.env, **(env or {})),
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)

    def calls(self, tool):
        return [entry for line in self.log.read_text().splitlines()
                if (entry := json.loads(line))["tool"] == tool] if self.log.exists() else []

    def existing_app(self, bundle_id=BUNDLE_ID):
        (self.target / "Contents/Resources").mkdir(parents=True)
        (self.target / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": bundle_id}))
        (self.target / "Contents/Resources/previous.txt").write_text("Previous installation\n")

    def running_app(self, path=None, pid=2468):
        self.state.write_text(json.dumps({"apps": [{"pid": pid, "path": str(path or self.target)}]}))

    def assert_installed(self, target=None):
        target = target or self.target
        self.assertEqual((target / "Contents/MacOS/FluxLLMApp").read_bytes(), b"verified executable bytes")
        self.assertTrue(os.access(target / "Contents/MacOS/FluxLLMApp", os.X_OK))
        self.assertEqual((target / "Contents/Resources/verified.txt").read_text(),
                         "The verifier exported this exact app.\n")
        link = target / "Contents/Resources/VerifiedLink"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "verified.txt")

    def assert_previous_restored(self):
        self.assertEqual((self.target / "Contents/Resources/previous.txt").read_text(), "Previous installation\n")
        self.assertFalse((self.target / "Contents/Resources/verified.txt").exists())

    def rejected(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_installs_exact_verified_export_without_launch(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_installed()
        self.assertFalse(self.calls("open"))
        calls = self.calls("verifier")
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["args"][0], VERSION)
        exported = Path(calls[0]["args"][calls[0]["args"].index("--extract-to") + 1])
        self.assertTrue(exported.is_absolute())
        self.assertFalse(exported.exists())

    def test_default_install_directory_is_users_applications(self):
        result = self.install(default=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_installed(self.home / "Applications/FluxLLM.app")
        self.assertFalse(self.target.exists())

    def test_real_verifier_exports_archive_for_installation(self):
        shutil.copyfile(SOURCE_ROOT / "verify-release.sh", self.repo / "verify-release.sh")
        (self.repo / "LICENSE").write_text("Fixture MIT License\n")

        def git(*args):
            return subprocess.check_output(["git", *args], cwd=self.repo, env=self.env,
                                           text=True, stderr=subprocess.STDOUT).strip()

        git("init", "-q")
        git("config", "user.name", "Installation Test")
        git("config", "user.email", "install@example.invalid")
        git("add", "LICENSE")
        git("commit", "-qm", "Tagged installation fixture")
        git("tag", VERSION)
        commit = git("rev-parse", "HEAD")
        app = self.root / "archive source/FluxLLM.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources/FluxLLM_FluxLLM.bundle").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": BUNDLE_ID, "CFBundleExecutable": "FluxLLMApp",
            "CFBundleShortVersionString": VERSION, "CFBundleVersion": VERSION,
            "FluxLLMReleaseTag": VERSION, "FluxLLMCommitSHA": commit,
        }))
        (app / "Contents/MacOS/FluxLLMApp").write_bytes(b"verified executable bytes")
        (app / "Contents/MacOS/FluxLLMApp").chmod(0o755)
        (app / "Contents/Resources/verified.txt").write_text("The verifier exported this exact app.\n")
        (app / "Contents/Resources/VerifiedLink").symlink_to("verified.txt")
        shutil.copyfile(self.repo / "LICENSE", app / "Contents/Resources/LICENSE")
        release_dir = self.repo / ".build/releases" / VERSION
        release_dir.mkdir(parents=True)
        archive = release_dir / f"FluxLLM-{VERSION}.zip"
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)],
                       check=True, env=self.env)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        (release_dir / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
        (release_dir / "release-info.txt").write_text(
            f"Tag: {VERSION}\nVersion: {VERSION}\nCommit: {commit}\nArchitecture: arm64\n"
            f"Release title: FluxLLM {VERSION}\nArchive: {archive.name}\n")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_installed()
        self.assertEqual((self.target / "Contents/Resources/LICENSE").read_bytes(), (self.repo / "LICENSE").read_bytes())
        for tool in ("lipo", "codesign", "xcrun", "spctl"):
            calls = self.calls(tool)
            self.assertEqual(len(calls), 1)
            checked = Path(calls[0]["args"][-1])
            self.assertTrue(checked.is_relative_to(self.install_dir))
            self.assertFalse(checked.exists())
        self.assertFalse(self.calls("open"))

    def test_custom_release_directory_is_forwarded(self):
        release_dir = self.root / "local release files"
        release_dir.mkdir()
        # This ZIP is intentionally unusable: only the verifier's checked export is installed.
        (release_dir / f"FluxLLM-{VERSION}.zip").write_text("not a ZIP")
        result = self.install("--release-dir", str(release_dir))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_installed()
        args = self.calls("verifier")[0]["args"]
        self.assertEqual(args[args.index("--release-dir") + 1], str(release_dir))

    def test_invalid_tags_fail_before_verification(self):
        for tag in ("v1.2.3", "01.2.3", "1.2", "1.2.3-rc1", "../1.2.3"):
            with self.subTest(tag=tag):
                self.rejected(self.install(tag=tag))
        self.assertFalse(self.calls("verifier"))
        self.assertFalse(self.target.exists())

    def test_verifier_failure_preserves_previous_installation_and_running_app(self):
        self.existing_app()
        self.running_app()
        result = self.install(env={"INSTALL_TEST_VERIFY_FAIL": "1"})
        self.rejected(result)
        self.assert_previous_restored()
        self.assertFalse(self.calls("open"))
        self.assertFalse([call for call in self.calls("osascript") if "terminate" in call["args"][4:]])

    def test_successful_replacement_retains_backup(self):
        self.existing_app()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_installed()
        backups = list(self.install_dir.glob(".fluxllm-backup-*/FluxLLM.app"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "Contents/Resources/previous.txt").is_file())
        self.assertIn(str(backups[0]), result.stdout)

    def test_running_app_quits_gracefully_before_replacement(self):
        self.existing_app()
        self.running_app()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_installed()
        actions = [call["args"][4:] for call in self.calls("osascript")]
        self.assertIn(["terminate", "2468"], actions)
        self.assertEqual(json.loads(self.state.read_text())["apps"], [])

    def test_refused_quit_preserves_previous_installation(self):
        self.existing_app()
        self.running_app()
        self.rejected(self.install(env={"INSTALL_TEST_REFUSE_TERMINATE": "1"}))
        self.assert_previous_restored()
        self.assertFalse(self.calls("open"))

    def test_app_exiting_before_quit_request_is_not_an_error(self):
        self.existing_app()
        self.running_app()
        result = self.install(env={"INSTALL_TEST_EXIT_DURING_QUIT": "1"})
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_installed()
        self.assertEqual(json.loads(self.state.read_text())["apps"], [])

    def test_shutdown_timeout_preserves_previous_installation(self):
        self.existing_app()
        self.running_app()
        self.rejected(self.install(env={"INSTALL_TEST_KEEP_RUNNING": "1"}))
        self.assert_previous_restored()
        self.assertFalse(self.calls("open"))

    def test_installed_application_is_launched_at_exact_path(self):
        result = self.install(launch=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_installed()
        self.assertEqual([call["args"] for call in self.calls("open")], [["-n", str(self.target)]])
        self.assertEqual(json.loads(self.state.read_text())["apps"], [{"pid": 12345, "path": str(self.target)}])

    def test_launch_error_restores_previous_installation(self):
        self.existing_app()
        self.rejected(self.install(launch=True, env={"INSTALL_TEST_OPEN_FAIL": "1"}))
        self.assert_previous_restored()

    def test_partial_launch_is_stopped_before_rollback(self):
        self.existing_app()
        self.rejected(self.install(launch=True, env={"INSTALL_TEST_OPEN_FAIL_AFTER_LAUNCH": "1"}))
        self.assert_previous_restored()
        self.assertEqual(json.loads(self.state.read_text())["apps"], [])
        actions = [call["args"][4:] for call in self.calls("osascript")]
        self.assertIn(["terminate", "12345"], actions)

    def test_refused_rollback_quit_keeps_running_app_and_backup(self):
        self.existing_app()
        result = self.install(launch=True, env={"INSTALL_TEST_OPEN_FAIL_AFTER_LAUNCH": "1",
                                               "INSTALL_TEST_REFUSE_TERMINATE": "1"})
        self.rejected(result)
        self.assert_installed()
        backups = list(self.install_dir.glob(".fluxllm-backup-*/FluxLLM.app"))
        self.assertEqual(len(backups), 1)
        self.assertTrue((backups[0] / "Contents/Resources/previous.txt").is_file())
        self.assertIn(str(backups[0]), result.stdout)
        self.assertIn("rollback could not finish", result.stdout)

    def test_launch_error_without_previous_installation_removes_failed_install(self):
        self.rejected(self.install(launch=True, env={"INSTALL_TEST_OPEN_FAIL": "1"}))
        self.assertFalse(self.target.exists())

    def test_startup_timeout_restores_previous_installation(self):
        self.existing_app()
        self.rejected(self.install(launch=True, env={"INSTALL_TEST_NO_APP": "1"}))
        self.assert_previous_restored()

    def test_other_path_does_not_satisfy_launch_check(self):
        self.existing_app()
        self.rejected(self.install(launch=True, env={"INSTALL_TEST_WRONG_PATH": "1"}))
        self.assert_previous_restored()

    def test_early_exit_restores_previous_installation(self):
        self.existing_app()
        self.rejected(self.install(launch=True, env={"INSTALL_TEST_EARLY_EXIT": "1"}))
        self.assert_previous_restored()

    def test_existing_app_symlink_is_rejected_without_touching_target(self):
        outside = self.root / "untouched.app"
        outside.mkdir()
        (outside / "keep.txt").write_text("untouched")
        self.install_dir.mkdir()
        self.target.symlink_to(outside)
        self.rejected(self.install())
        self.assertTrue(self.target.is_symlink())
        self.assertEqual((outside / "keep.txt").read_text(), "untouched")

    def test_concurrent_install_lock_is_preserved_and_stops_install(self):
        self.existing_app()
        lock = self.install_dir / ".fluxllm-install.lock"
        lock.mkdir()
        marker = lock / "owner.txt"
        marker.write_text("another installer")
        self.rejected(self.install())
        self.assert_previous_restored()
        self.assertEqual(marker.read_text(), "another installer")
        self.assertFalse(self.calls("verifier"))

    def test_existing_regular_file_is_rejected(self):
        self.install_dir.mkdir()
        self.target.write_text("keep me")
        self.rejected(self.install())
        self.assertEqual(self.target.read_text(), "keep me")

    def test_different_bundle_identifier_is_rejected(self):
        self.existing_app(bundle_id="invalid.someone.else")
        self.rejected(self.install())
        self.assert_previous_restored()

    def test_unreadable_existing_bundle_metadata_is_rejected(self):
        self.existing_app()
        (self.target / "Contents/Info.plist").write_bytes(b"not a plist")
        self.rejected(self.install())
        self.assert_previous_restored()

    def test_lifecycle_error_preserves_previous_installation(self):
        self.existing_app()
        self.rejected(self.install(env={"INSTALL_TEST_LIFECYCLE_FAIL": "1"}))
        self.assert_previous_restored()

    def test_malformed_lifecycle_response_preserves_previous_installation(self):
        self.existing_app()
        self.rejected(self.install(env={"INSTALL_TEST_MALFORMED_STATE": "1"}))
        self.assert_previous_restored()

    def test_requires_macos(self):
        self.rejected(self.install(env={"INSTALL_TEST_PLATFORM": "Linux"}))
        self.assertFalse(self.calls("verifier"))
        self.assertFalse(self.target.exists())


unittest.main()
PY
