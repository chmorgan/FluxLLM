#!/bin/bash
# Exercise release control flow in disposable repositories. Every build, signing,
# notarization, and Gatekeeper command is replaced with a local test double.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$REPO_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pty
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


SOURCE_ROOT = Path(sys.argv.pop(1))
RELEASE_SCRIPT = SOURCE_ROOT / "package-release.sh"
RELEASE_HELPERS = ("verify-release.sh", "generate-release-notes.sh")
VERSION = "1.2.3"
IDENTITY = "Developer ID Application: Release Test (TESTTEAM01)"
PROFILE = "release-test-profile"
DEFAULT_PROFILE = "fluxllm"
FINGERPRINT = "0123456789ABCDEF0123456789ABCDEF01234567"
SECOND_FINGERPRINT = "89ABCDEF0123456789ABCDEF0123456789ABCDEF"
SECOND_IDENTITY = "Developer ID Application: Another Release Test (OTHERTEAM1)"


def identity_listing(*candidates):
    return "\n".join(
        [f'  {number}) {fingerprint} "{name}"' for number, (fingerprint, name) in enumerate(candidates, 1)]
        + [f"     {len(candidates)} valid identities found", ""]
    )

# Unknown commands fail closed: these mocks never forward to the real tool.
MOCK_TOOL = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import sys

tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["RELEASE_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": tool, "args": args, "cwd": os.getcwd(),
                          "stdin_isatty": sys.stdin.isatty(),
                          "output_exists": Path(os.environ["RELEASE_TEST_OUTPUT_DIR"]).exists()
                          if "RELEASE_TEST_OUTPUT_DIR" in os.environ else None}) + "\n")
failure = os.environ.get("RELEASE_TEST_FAIL", "")
if tool == "uname":
    print(os.environ.get("RELEASE_TEST_MACHINE", "arm64") if "-m" in args
          else os.environ.get("RELEASE_TEST_PLATFORM", "Darwin"))
elif tool == "security":
    if args != ["find-identity", "-v", "-p", "codesigning"]:
        sys.exit("Unexpected security invocation: " + repr(args))
    if failure == "security":
        sys.exit("Mock security lookup failed")
    print(os.environ["RELEASE_TEST_IDENTITIES"], end="")
elif tool == "lipo":
    if not args or args[0] != "-archs":
        sys.exit("Unexpected lipo invocation: " + repr(args))
    print(os.environ.get("RELEASE_TEST_BINARY_ARCH", "arm64"))
elif tool == "xcrun":
    if len(args) == 2 and args[0] == "--find" and args[1] in ("notarytool", "stapler"):
        if failure == "notarytool-unavailable" and args[1] == "notarytool":
            sys.exit(46)
        print(Path(sys.argv[0]).parent / args[1])
    elif args and args[0] in ("notarytool", "stapler"):
        target = str(Path(sys.argv[0]).parent / args[0])
        os.execv(target, [target] + args[1:])
    else:
        sys.exit("Unexpected xcrun invocation: " + repr(args))
elif tool == "notarytool":
    mode = os.environ.get("RELEASE_TEST_NOTARY_PREFLIGHT", "valid")
    state = Path(os.environ["RELEASE_TEST_NOTARY_STATE"])
    if args and args[0] == "history":
        if len(args) != 5 or args[1] != "--keychain-profile" or args[3:] != ["--output-format", "json"]:
            sys.exit("Unexpected history invocation: " + repr(args))
        # Real account history must never reach the packaging terminal or build log.
        print(json.dumps({"history": ["PRIVATE-NOTARIZATION-HISTORY-MARKER"]}))
        if mode in ("missing", "recheck-failure") and not state.exists():
            sys.exit("Error: No Keychain password item found for profile: " + args[2])
        if mode == "recheck-failure" and state.exists():
            sys.exit("Mock validation failed after storing credentials")
        if mode == "auth":
            sys.exit("HTTP status code: 401. Invalid credentials")
        if mode == "network":
            sys.exit("Mock notarization service connection failed")
    elif args and args[0] == "store-credentials":
        if len(args) not in (3, 5) or "--validate" not in args:
            sys.exit("Unexpected credential storage invocation: " + repr(args))
        if len(args) == 5 and "--team-id" not in args:
            sys.exit("Unexpected credential storage team arguments: " + repr(args))
        if not sys.stdin.isatty():
            sys.exit("Credential storage needs a terminal")
        print("Mock Apple ID and app-specific password prompt")
        if failure == "credential-store":
            sys.exit("Mock credential storage failed")
        state.write_text("stored\n")
    elif args and args[0] == "submit":
        if failure == "notary-command":
            sys.exit(42)
        print(json.dumps({"id": "test-submission-id", "status": "Invalid" if failure == "notary-status" else "Accepted"}))
    else:
        sys.exit("Unexpected notarytool invocation: " + repr(args))
elif tool == "stapler":
    if not args or args[0] not in ("staple", "validate"):
        sys.exit("Unexpected stapler invocation: " + repr(args))
    if failure == "staple" and args[0] == "staple":
        sys.exit(43)
    if args[0] == "staple":
        (Path(args[-1]) / "Contents" / "test-notarization-ticket").write_text("stapled\n")
elif tool == "codesign":
    if "--sign" in args:
        if failure == "sign":
            sys.exit(44)
        app = Path(args[-1])
        if not (app / "Contents" / "Info.plist").is_file():
            sys.exit("Signing target is not the expected app")
        with (app / "Contents" / "Info.plist").open("rb") as file:
            plist = plistlib.load(file)
        if plist.get("CFBundleShortVersionString") != os.environ["RELEASE_TEST_EXPECTED_TAG"]:
            sys.exit("App version was not stamped before signing")
        if plist.get("FluxLLMCommitSHA") != os.environ["RELEASE_TEST_EXPECTED_COMMIT"]:
            sys.exit("Source provenance was not stamped before signing")
        if not (app / "Contents" / "Resources" / "LICENSE").is_file():
            sys.exit("License was not bundled before signing")
    elif "--verify" not in args and "--display" not in args and "-d" not in args:
        sys.exit("Unexpected codesign invocation: " + repr(args))
elif tool == "spctl":
    if "--assess" not in args and "-a" not in args:
        sys.exit("Unexpected spctl invocation: " + repr(args))
elif tool in ("swift", "xcodebuild"):
    sys.exit("Forbidden real-tool path reached in fixture: " + tool)
else:
    sys.exit("Unexpected mock tool: " + tool)
'''

FAKE_BUILD = r'''#!/bin/bash
set -euo pipefail
if [[ "$*" != "--release --bundle" ]]; then
    echo "Unexpected fixture build arguments: $*" >&2
    exit 90
fi
python3 - <<'BUILD'
import json
import os
from pathlib import Path
import shutil

with open(os.environ["RELEASE_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": "fixture-build", "args": ["--release", "--bundle"], "cwd": os.getcwd()}) + "\n")
if os.environ.get("RELEASE_TEST_FAIL") == "build":
    raise SystemExit(45)
app = Path(".build/release/FluxLLM.app")
(app / "Contents/MacOS").mkdir(parents=True)
(app / "Contents/Resources/FluxLLM_FluxLLM.bundle").mkdir(parents=True)
shutil.copyfile("Resources/Info.plist", app / "Contents/Info.plist")
shutil.copyfile("Sources/release-marker.txt", app / "Contents/MacOS/FluxLLMApp")
(app / "Contents/MacOS/FluxLLMApp").chmod(0o755)
mode = os.environ.get("RELEASE_TEST_MUTATE", "")
if mode:
    target = Path("Package.resolved" if mode == "dependencies" else "Sources/release-marker.txt")
    with target.open("a") as file:
        file.write("\nchanged during build\n")
BUILD
'''


class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="fluxllm-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        # Isolate any legacy configuration from the developer's real home directory.
        self.home = self.root / "home"
        self.home.mkdir()
        # Spaces exercise quoting of worktree, credential, and output paths.
        self.repo = self.root / "source repo"
        self.repo.mkdir()
        self.log = self.root / "tool-log.jsonl"
        self.mockbin = self.root / "mockbin"
        self.mockbin.mkdir()
        (self.mockbin / "mock-tool").write_text(MOCK_TOOL)
        (self.mockbin / "mock-tool").chmod(0o755)
        for tool in ("uname", "lipo", "xcrun", "notarytool", "stapler", "codesign", "spctl", "swift", "security", "xcodebuild"):
            (self.mockbin / tool).symlink_to("mock-tool")
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("RELEASE_TEST_")}
        self.env.update({
            "PATH": str(self.mockbin) + os.pathsep + os.environ["PATH"],
            "RELEASE_TEST_LOG": str(self.log),
            "RELEASE_TEST_NOTARY_STATE": str(self.root / "stored-notary-profile"),
            "RELEASE_TEST_IDENTITIES": identity_listing((FINGERPRINT, IDENTITY)),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "HOME": str(self.home),
        })
        for name in ("SIGNING_IDENTITY", "NOTARY_PROFILE", "FLUXLLM_RELEASE_CONFIG", "FLUXLLM_SIGNING_IDENTITY", "FLUXLLM_NOTARY_PROFILE", "DEVELOPER_ID_APPLICATION", "APPLE_ID", "APPLE_PASSWORD", "RELEASE_TEST_FAIL", "RELEASE_TEST_MUTATE"):
            self.env.pop(name, None)
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release-test@example.invalid")
        (self.repo / "Resources").mkdir()
        (self.repo / "Sources").mkdir()
        shutil.copyfile(RELEASE_SCRIPT, self.repo / "package-release.sh")
        (self.repo / "package-release.sh").chmod(0o755)
        for helper in RELEASE_HELPERS:
            shutil.copyfile(SOURCE_ROOT / helper, self.repo / helper)
            (self.repo / helper).chmod(0o755)
        (self.repo / "build-dev.sh").write_text(FAKE_BUILD)
        (self.repo / "build-dev.sh").chmod(0o755)
        (self.repo / ".gitignore").write_text(".build/\n")
        (self.repo / "Package.resolved").write_text('{"pins": [], "version": 3}\n')
        (self.repo / "Package.swift").write_text("// A fixture: no Swift compiler is invoked.\n")
        (self.repo / "Sources/release-marker.txt").write_text("tagged-source\n")
        shutil.copyfile(SOURCE_ROOT / "Resources/Info.plist", self.repo / "Resources/Info.plist")
        shutil.copyfile(SOURCE_ROOT / "Resources/FluxLLM.entitlements", self.repo / "Resources/FluxLLM.entitlements")
        shutil.copyfile(SOURCE_ROOT / "LICENSE", self.repo / "LICENSE")
        self.git("add", ".")
        self.git("commit", "-qm", "Release fixture")
        self.git("tag", VERSION)
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.env["RELEASE_TEST_EXPECTED_TAG"] = VERSION
        self.env["RELEASE_TEST_EXPECTED_COMMIT"] = self.commit
        self.output = self.root / "release output"

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, env=self.env, text=True, stderr=subprocess.STDOUT)

    def retag_fixture(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "Change tagged release fixture")
        self.git("tag", "-f", VERSION)
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.env["RELEASE_TEST_EXPECTED_COMMIT"] = self.commit

    def run_release(self, tag=VERSION, *, output=True, extra=(), env=None, identity=IDENTITY, profile=PROFILE, interactive=False):
        command = [str(self.repo / "package-release.sh"), tag]
        if identity is not None:
            command += ["--signing-identity", identity]
        if profile is not None:
            command += ["--notary-profile", profile]
        if output:
            command += ["--output-dir", str(self.output)]
        command += list(extra)
        release_env = dict(self.env, **(env or {}))
        release_env["RELEASE_TEST_OUTPUT_DIR"] = str(self.output if output else self.repo / ".build/releases" / tag)
        master = slave = None
        try:
            if interactive:
                master, slave = pty.openpty()
            result = subprocess.run(command, cwd=self.root, env=release_env, text=True,
                                    stdin=slave if interactive else subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        finally:
            if master is not None:
                os.close(master)
                os.close(slave)
        self.last_output = result.stdout
        return result

    def calls(self, tool):
        if not self.log.exists():
            return []
        return [entry for line in self.log.read_text().splitlines()
                if (entry := json.loads(line))["tool"] == tool]

    def notary_calls(self, command):
        return [call for call in self.calls("notarytool") if call["args"][0] == command]

    def assert_failed_before_signing(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls("codesign"), [], result.stdout)
        self.assertEqual(self.notary_calls("submit"), [], result.stdout)

    def assert_failed_before_building(self, result):
        self.assert_failed_before_signing(result)
        self.assertEqual(self.calls("fixture-build"), [], result.stdout)

    def assert_received_settings(self, result, identity, profile):
        self.assertEqual(result.returncode, 0, result.stdout)
        signs = [call["args"] for call in self.calls("codesign") if "--sign" in call["args"]]
        self.assertTrue(signs, result.stdout)
        for args in signs:
            self.assertEqual(args[args.index("--sign") + 1], identity)
        submissions = self.notary_calls("submit")
        self.assertEqual(len(submissions), 1, result.stdout)
        args = submissions[0]["args"]
        self.assertEqual(args[args.index("--keychain-profile") + 1], profile)
        if identity.startswith("Developer ID Application: "):
            self.assertEqual(self.calls("security"), [], result.stdout)

    def assert_identity_lookup(self):
        self.assertEqual([call["args"] for call in self.calls("security")],
                         [["find-identity", "-v", "-p", "codesigning"]], self.last_output)

    def assert_worktree_cleaned(self):
        worktrees = [line for line in self.git("worktree", "list", "--porcelain").splitlines() if line.startswith("worktree ")]
        self.assertEqual(len(worktrees), 1, self.last_output)

    def assert_notary_preflight_stopped_release(self, result):
        self.assert_failed_before_building(result)
        self.assertFalse(self.output.exists(), result.stdout)
        self.assertNotIn("PRIVATE-NOTARIZATION-HISTORY-MARKER", result.stdout)
        self.assert_worktree_cleaned()

    def assert_notary_setup(self, result, profile, team):
        self.assertEqual(result.returncode, 0, result.stdout)
        history = self.notary_calls("history")
        self.assertEqual(len(history), 2, result.stdout)
        for call in history:
            self.assertEqual(call["args"], ["history", "--keychain-profile", profile, "--output-format", "json"])
            self.assertFalse(call["output_exists"], result.stdout)
        stores = self.notary_calls("store-credentials")
        self.assertEqual(len(stores), 1, result.stdout)
        args = stores[0]["args"]
        self.assertEqual(args[:2], ["store-credentials", profile])
        self.assertIn("--validate", args)
        if team is None:
            self.assertNotIn("--team-id", args)
        else:
            self.assertEqual(args[args.index("--team-id") + 1], team)
        self.assertTrue(stores[0]["stdin_isatty"], result.stdout)
        self.assertFalse(stores[0]["output_exists"], result.stdout)
        events = [json.loads(line) for line in self.log.read_text().splitlines()]
        meaningful = [(call["tool"], call["args"][0]) for call in events
                      if call["tool"] in ("notarytool", "fixture-build")]
        self.assertEqual(meaningful[:4], [("notarytool", "history"), ("notarytool", "store-credentials"),
                                         ("notarytool", "history"), ("fixture-build", "--release")])
        self.assertNotIn("PRIVATE-NOTARIZATION-HISTORY-MARKER", result.stdout)
        self.assertNotIn("PRIVATE-NOTARIZATION-HISTORY-MARKER", (self.output / "build.log").read_text())
        self.assertNotIn("Mock Apple ID and app-specific password prompt", (self.output / "build.log").read_text())

    def test_valid_notary_profile_is_checked_before_build_without_setup(self):
        result = self.run_release()
        self.assert_received_settings(result, IDENTITY, PROFILE)
        self.assertEqual([call["args"] for call in self.notary_calls("history")],
                         [["history", "--keychain-profile", PROFILE, "--output-format", "json"]])
        self.assertFalse(self.notary_calls("history")[0]["output_exists"], result.stdout)
        self.assertEqual(self.notary_calls("store-credentials"), [], result.stdout)
        events = [json.loads(line) for line in self.log.read_text().splitlines()]
        history_index = next(index for index, call in enumerate(events)
                             if call["tool"] == "notarytool" and call["args"][0] == "history")
        build_index = next(index for index, call in enumerate(events) if call["tool"] == "fixture-build")
        self.assertLess(history_index, build_index)
        self.assertNotIn("PRIVATE-NOTARIZATION-HISTORY-MARKER", result.stdout)
        self.assertNotIn("PRIVATE-NOTARIZATION-HISTORY-MARKER", (self.output / "build.log").read_text())

    def test_first_use_sets_up_default_profile_and_auto_detected_team(self):
        result = self.run_release(identity=None, profile=None, interactive=True,
                                  env={"RELEASE_TEST_NOTARY_PREFLIGHT": "missing"})
        self.assert_notary_setup(result, DEFAULT_PROFILE, "TESTTEAM01")
        self.assert_received_settings(result, FINGERPRINT, DEFAULT_PROFILE)
        self.assert_identity_lookup()

    def test_first_use_uses_cli_profile_and_explicit_identity_team(self):
        result = self.run_release(profile="profile with spaces", interactive=True,
                                  env={"RELEASE_TEST_NOTARY_PREFLIGHT": "missing"})
        self.assert_notary_setup(result, "profile with spaces", "TESTTEAM01")
        self.assert_received_settings(result, IDENTITY, "profile with spaces")

    def test_first_use_uses_selected_fingerprint_team(self):
        listing = identity_listing((FINGERPRINT, IDENTITY), (SECOND_FINGERPRINT, SECOND_IDENTITY))
        result = self.run_release(identity=SECOND_FINGERPRINT.lower(), interactive=True,
                                  env={"RELEASE_TEST_NOTARY_PREFLIGHT": "missing",
                                       "RELEASE_TEST_IDENTITIES": listing})
        self.assert_notary_setup(result, PROFILE, "OTHERTEAM1")
        self.assert_received_settings(result, SECOND_FINGERPRINT, PROFILE)
        self.assert_identity_lookup()

    def test_first_use_leaves_unknown_team_for_notarytool_prompt(self):
        identity = "Developer ID Application: Release Test (not-a-team)"
        result = self.run_release(identity=identity, interactive=True,
                                  env={"RELEASE_TEST_NOTARY_PREFLIGHT": "missing"})
        self.assert_notary_setup(result, PROFILE, None)
        self.assert_received_settings(result, identity, PROFILE)

    def test_missing_notary_profile_without_terminal_stops_before_build(self):
        result = self.run_release(env={"RELEASE_TEST_NOTARY_PREFLIGHT": "missing"})
        self.assert_notary_preflight_stopped_release(result)
        self.assertEqual(len(self.notary_calls("history")), 1, result.stdout)
        self.assertEqual(self.notary_calls("store-credentials"), [], result.stdout)
        self.assertIn("terminal", result.stdout.lower())
        self.assertIn("store-credentials", result.stdout)
        self.assertIn(PROFILE, result.stdout)

    def test_notary_authentication_or_network_errors_do_not_trigger_setup(self):
        for mode in ("auth", "network"):
            with self.subTest(mode=mode):
                self.log.unlink(missing_ok=True)
                result = self.run_release(interactive=True, env={"RELEASE_TEST_NOTARY_PREFLIGHT": mode})
                self.assert_notary_preflight_stopped_release(result)
                self.assertEqual(len(self.notary_calls("history")), 1, result.stdout)
                self.assertEqual(self.notary_calls("store-credentials"), [], result.stdout)
                self.assertRegex(result.stdout, r"401|connection failed")

    def test_notary_credential_storage_failure_stops_before_build(self):
        result = self.run_release(interactive=True, env={"RELEASE_TEST_NOTARY_PREFLIGHT": "missing",
                                                        "RELEASE_TEST_FAIL": "credential-store"})
        self.assert_notary_preflight_stopped_release(result)
        self.assertEqual(len(self.notary_calls("store-credentials")), 1, result.stdout)
        self.assertEqual(len(self.notary_calls("history")), 1, result.stdout)
        self.assertIn("Mock credential storage failed", result.stdout)

    def test_notary_recheck_failure_stops_before_build(self):
        result = self.run_release(interactive=True, env={"RELEASE_TEST_NOTARY_PREFLIGHT": "recheck-failure"})
        self.assert_notary_preflight_stopped_release(result)
        self.assertEqual(len(self.notary_calls("store-credentials")), 1, result.stdout)
        self.assertEqual(len(self.notary_calls("history")), 2, result.stdout)
        self.assertIn("Mock validation failed after storing credentials", result.stdout)

    def assert_artifact(self, output):
        archive = output / f"FluxLLM-{VERSION}.zip"
        self.assertTrue(archive.is_file(), self.last_output)
        with zipfile.ZipFile(archive) as file:
            plist = plistlib.loads(file.read("FluxLLM.app/Contents/Info.plist"))
            self.assertEqual(plist["CFBundleShortVersionString"], VERSION)
            self.assertEqual(plist["CFBundleVersion"], VERSION)
            self.assertEqual(plist["FluxLLMReleaseTag"], VERSION)
            self.assertEqual(plist["FluxLLMCommitSHA"], self.commit)
            self.assertEqual(file.read("FluxLLM.app/Contents/MacOS/FluxLLMApp"), b"tagged-source\n")
            self.assertEqual(file.read("FluxLLM.app/Contents/test-notarization-ticket"), b"stapled\n")
            self.assertEqual(file.read("FluxLLM.app/Contents/Resources/LICENSE"), (self.repo / "LICENSE").read_bytes())
        metadata = "\n".join(path.read_text() for path in output.iterdir() if path.is_file() and path.suffix != ".zip")
        self.assertIn(VERSION, metadata)
        self.assertIn(self.commit, metadata)
        self.assertIn(hashlib.sha256(archive.read_bytes()).hexdigest(), metadata)
        notes = output / "release-notes.md"
        self.assertTrue(notes.is_file(), self.last_output)
        self.assertIn(f"FluxLLM {VERSION}", notes.read_text())
        self.assertIn("Release fixture", notes.read_text())

    def assert_final_archive_verified(self):
        verifies = [call for call in self.calls("codesign") if "--verify" in call["args"]]
        self.assertEqual(len(verifies), 3, self.last_output)
        staged_app = verifies[0]["args"][-1]
        extracted_app = verifies[-1]["args"][-1]
        self.assertNotEqual(extracted_app, staged_app, self.last_output)
        self.assertEqual(Path(extracted_app).name, "FluxLLM.app", self.last_output)
        self.assertIn(extracted_app, [call["args"][-1] for call in self.calls("stapler")
                                     if call["args"][0] == "validate"], self.last_output)
        self.assertIn(extracted_app, [call["args"][-1] for call in self.calls("spctl")], self.last_output)
        self.assertFalse(Path(extracted_app).exists(), "Verifier should clean its extracted app")

    def test_help_does_not_build_or_sign(self):
        result = subprocess.run([str(self.repo / "package-release.sh"), "--help"], cwd=self.root,
                                env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Usage:   ./package-release.sh TAG [options]", result.stdout)
        self.assertIn("README.md", result.stdout)
        self.assertEqual(self.calls("fixture-build"), [])
        self.assertEqual(self.calls("codesign"), [])
        self.assertEqual(self.calls("security"), [])
        self.assertEqual(self.calls("notarytool"), [])

    def test_legacy_default_config_is_ignored(self):
        config = self.home / ".config/fluxllm/release.env"
        config.parent.mkdir(parents=True)
        config.write_text(
            "FLUXLLM_SIGNING_IDENTITY='Developer ID Application: Old File Identity (FILETEAM)'\n"
            "FLUXLLM_NOTARY_PROFILE='old-file-profile'\n"
        )
        result = self.run_release(identity=None, profile=None)
        self.assert_received_settings(result, FINGERPRINT, DEFAULT_PROFILE)
        self.assert_identity_lookup()

    def test_legacy_environment_settings_are_ignored(self):
        config = self.root / "obsolete configuration.env"
        config.write_text("not valid configuration\n")
        result = self.run_release(identity=None, profile=None, env={
            "FLUXLLM_RELEASE_CONFIG": str(config),
            "FLUXLLM_SIGNING_IDENTITY": "Developer ID Application: Old Environment Identity (ENVTEAM)",
            "FLUXLLM_NOTARY_PROFILE": "old-environment-profile",
        })
        self.assert_received_settings(result, FINGERPRINT, DEFAULT_PROFILE)
        self.assert_identity_lookup()

    def test_missing_identity_reports_certificate_setup(self):
        result = self.run_release(identity=None, profile=None,
                                  env={"RELEASE_TEST_IDENTITIES": identity_listing()})
        self.assert_failed_before_building(result)
        self.assert_identity_lookup()
        self.assertIn("Developer ID Application", result.stdout)
        self.assertRegex(result.stdout.lower(), r"install|unlock")

    def test_unspecified_notary_profile_uses_fluxllm(self):
        result = self.run_release(profile=None)
        self.assert_received_settings(result, IDENTITY, DEFAULT_PROFILE)

    def test_empty_cli_settings_do_not_fall_back_to_defaults(self):
        for option in ("--signing-identity", "--notary-profile"):
            with self.subTest(option=option):
                result = self.run_release(identity=None, profile=None, extra=(option, ""))
                self.assert_failed_before_building(result)
                self.assertIn(option, result.stdout)
                self.assertEqual(self.calls("security"), [], result.stdout)

    def test_tag_only_invocation_selects_identity_fingerprint_and_default_profile(self):
        result = self.run_release(identity=None, profile=None, output=False)
        self.assert_received_settings(result, FINGERPRINT, DEFAULT_PROFILE)
        self.assert_identity_lookup()
        self.assertIn(IDENTITY, result.stdout)
        self.assertIn(FINGERPRINT, result.stdout)
        self.assert_artifact(self.repo / ".build/releases" / VERSION)

    def test_auto_identity_combines_with_cli_profile(self):
        result = self.run_release(identity=None, profile="custom profile")
        self.assert_received_settings(result, FINGERPRINT, "custom profile")
        self.assert_identity_lookup()

    def test_duplicate_identity_fingerprints_are_one_candidate(self):
        listing = identity_listing((FINGERPRINT, IDENTITY), (FINGERPRINT.lower(), IDENTITY))
        result = self.run_release(identity=None, env={"RELEASE_TEST_IDENTITIES": listing})
        self.assert_received_settings(result, FINGERPRINT, PROFILE)
        self.assert_identity_lookup()

    def test_only_valid_developer_application_identities_are_candidates(self):
        listing = identity_listing((FINGERPRINT, IDENTITY)) + "\n".join([
            f'  2) {SECOND_FINGERPRINT} "Apple Development: Development Test (TESTTEAM)"',
            f'  3) {SECOND_FINGERPRINT} "Developer ID Installer: Installer Test (TESTTEAM)"',
            f'  4) {SECOND_FINGERPRINT} "{SECOND_IDENTITY}" (CSSMERR_TP_CERT_REVOKED)',
            f'  5) {SECOND_FINGERPRINT} "{SECOND_IDENTITY}" (CSSMERR_TP_CERT_EXPIRED)',
        ])
        result = self.run_release(identity=None, env={"RELEASE_TEST_IDENTITIES": listing})
        self.assert_received_settings(result, FINGERPRINT, PROFILE)
        self.assert_identity_lookup()

    def test_malformed_or_annotated_candidates_cannot_be_selected(self):
        listing = "\n".join([
            f'  1) {FINGERPRINT} "{IDENTITY}" (CSSMERR_TP_CERT_REVOKED)',
            f'  2) {FINGERPRINT} "{IDENTITY}" (CSSMERR_TP_CERT_EXPIRED)',
            f'  3) {FINGERPRINT} "{IDENTITY}" unexpected annotation',
            f'  4) {FINGERPRINT[:-1]} "{IDENTITY}"',
            f'  5) {FINGERPRINT}0 "{IDENTITY}"',
            f'  6) {"Z" * 40} "{IDENTITY}"',
            f'  7) {FINGERPRINT} {IDENTITY}',
            f'prefix 8) {FINGERPRINT} "{IDENTITY}"',
            f'  {FINGERPRINT} "{IDENTITY}"',
            '     0 valid identities found',
        ])
        result = self.run_release(identity=None, env={"RELEASE_TEST_IDENTITIES": listing})
        self.assert_failed_before_building(result)
        self.assert_identity_lookup()
        self.assertIn("Developer ID Application", result.stdout)

    def test_multiple_identities_require_explicit_selection(self):
        listing = identity_listing((FINGERPRINT, IDENTITY), (SECOND_FINGERPRINT, SECOND_IDENTITY))
        result = self.run_release(identity=None, env={"RELEASE_TEST_IDENTITIES": listing})
        self.assert_failed_before_building(result)
        self.assert_identity_lookup()
        for candidate in (FINGERPRINT, IDENTITY, SECOND_FINGERPRINT, SECOND_IDENTITY, "--signing-identity"):
            self.assertIn(candidate, result.stdout)

    def test_distinct_fingerprints_with_same_name_are_ambiguous(self):
        listing = identity_listing((FINGERPRINT, IDENTITY), (SECOND_FINGERPRINT, IDENTITY))
        result = self.run_release(identity=None, env={"RELEASE_TEST_IDENTITIES": listing})
        self.assert_failed_before_building(result)
        self.assert_identity_lookup()
        self.assertIn(FINGERPRINT, result.stdout)
        self.assertIn(SECOND_FINGERPRINT, result.stdout)

    def test_explicit_fingerprint_selects_one_valid_identity(self):
        listing = identity_listing((FINGERPRINT, IDENTITY), (SECOND_FINGERPRINT, IDENTITY))
        result = self.run_release(identity=SECOND_FINGERPRINT.lower(),
                                  env={"RELEASE_TEST_IDENTITIES": listing})
        self.assert_received_settings(result, SECOND_FINGERPRINT, PROFILE)
        self.assert_identity_lookup()

    def test_explicit_unknown_fingerprint_is_rejected(self):
        result = self.run_release(identity=SECOND_FINGERPRINT)
        self.assert_failed_before_building(result)
        self.assert_identity_lookup()
        self.assertIn("SHA-1", result.stdout)
        self.assertIn("Developer ID Application", result.stdout)

    def test_explicit_non_developer_application_fingerprint_is_rejected(self):
        listing = identity_listing((SECOND_FINGERPRINT, "Apple Development: Development Test (TESTTEAM)"))
        result = self.run_release(identity=SECOND_FINGERPRINT, env={"RELEASE_TEST_IDENTITIES": listing})
        self.assert_failed_before_building(result)
        self.assert_identity_lookup()
        self.assertIn("Developer ID Application", result.stdout)

    def test_explicit_revoked_fingerprint_is_rejected(self):
        listing = f'  1) {FINGERPRINT} "{IDENTITY}" (CSSMERR_TP_CERT_REVOKED)\n'
        result = self.run_release(identity=FINGERPRINT, env={"RELEASE_TEST_IDENTITIES": listing})
        self.assert_failed_before_building(result)
        self.assert_identity_lookup()

    def test_explicit_name_bypasses_failing_identity_lookup(self):
        result = self.run_release(env={"RELEASE_TEST_FAIL": "security"})
        self.assert_received_settings(result, IDENTITY, PROFILE)

    def test_identity_lookup_failure_stops_before_building(self):
        result = self.run_release(identity=None, env={"RELEASE_TEST_FAIL": "security"})
        self.assert_failed_before_building(result)
        self.assert_identity_lookup()
        self.assertIn("Mock security lookup failed", result.stdout)

    def test_missing_tag_does_not_access_keychain(self):
        result = self.run_release(tag="9.8.7", identity=None, profile=None)
        self.assert_failed_before_building(result)
        self.assertEqual(self.calls("security"), [], result.stdout)
        self.assertEqual(self.calls("notarytool"), [], result.stdout)

    def test_mismatched_script_does_not_access_keychain(self):
        with (self.repo / "package-release.sh").open("a") as file:
            file.write("\n# uncommitted release tooling change\n")
        result = self.run_release(identity=None, profile=None)
        self.assert_failed_before_building(result)
        self.assertEqual(self.calls("security"), [], result.stdout)
        self.assertEqual(self.calls("notarytool"), [], result.stdout)

    def test_unsupported_platform_does_not_access_keychain(self):
        for env in ({"RELEASE_TEST_PLATFORM": "Linux"}, {"RELEASE_TEST_MACHINE": "x86_64"}):
            with self.subTest(env=env):
                result = self.run_release(identity=None, profile=None, env=env)
                self.assert_failed_before_building(result)
                self.assertEqual(self.calls("security"), [], result.stdout)

    def test_missing_required_tool_does_not_access_keychain(self):
        result = self.run_release(identity=None, profile=None, env={"RELEASE_TEST_FAIL": "notarytool-unavailable"})
        self.assert_failed_before_building(result)
        self.assertEqual(self.calls("security"), [], result.stdout)

    def test_tagged_source_isolated_and_metadata_matches_tag(self):
        # A newer committed HEAD, local source edits, and old bundle must all be ignored.
        (self.repo / "Sources/release-marker.txt").write_text("newer-commit\n")
        self.git("add", "Sources/release-marker.txt")
        self.git("commit", "-qm", "Changes after release tag")
        (self.repo / "Sources/release-marker.txt").write_text("uncommitted-source\n")
        stale = self.repo / ".build/release/FluxLLM.app/Contents/MacOS"
        stale.mkdir(parents=True)
        (stale / "FluxLLMApp").write_text("stale-local-build\n")
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_artifact(self.output)
        self.assertEqual((self.repo / "Sources/release-marker.txt").read_text(), "uncommitted-source\n")
        self.assertEqual((stale / "FluxLLMApp").read_text(), "stale-local-build\n")
        self.assertNotEqual(Path(self.calls("fixture-build")[0]["cwd"]), self.repo)
        signs = [call for call in self.calls("codesign") if "--sign" in call["args"]]
        self.assertTrue(signs, result.stdout)
        self.assertIn("runtime", signs[-1]["args"])
        self.assertIn("--timestamp", signs[-1]["args"])
        self.assertIn(IDENTITY, signs[-1]["args"])
        notary_args = self.notary_calls("submit")[0]["args"]
        self.assertIn("--wait", notary_args)
        self.assertIn("release-test-profile", notary_args)
        self.assert_final_archive_verified()
        self.assert_worktree_cleaned()

    def test_helpers_run_from_the_tagged_checkout(self):
        for helper in RELEASE_HELPERS:
            (self.repo / helper).write_text("#!/bin/bash\necho 'Uncommitted helper was used' >&2\nexit 98\n")
        result = self.run_release()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_artifact(self.output)
        self.assert_final_archive_verified()
        self.assertNotIn("Uncommitted helper was used", result.stdout)
        self.assert_worktree_cleaned()

    def test_missing_tagged_helpers_fail_before_building(self):
        for helper in RELEASE_HELPERS:
            with self.subTest(helper=helper):
                (self.repo / helper).unlink()
                self.retag_fixture()
                result = self.run_release(identity=None, profile=None)
                self.assert_failed_before_building(result)
                self.assertIn(helper, result.stdout)
                self.assertEqual(self.calls("security"), [], result.stdout)
                shutil.copyfile(SOURCE_ROOT / helper, self.repo / helper)
                (self.repo / helper).chmod(0o755)

    def test_shallow_history_fails_before_building(self):
        shallow_file = self.repo / ".git/shallow"
        shallow_file.write_text(self.commit + "\n")
        result = self.run_release(identity=None, profile=None)
        self.assert_failed_before_building(result)
        self.assertRegex(result.stdout.lower(), r"shallow|full.*history")
        self.assertEqual(self.calls("security"), [], result.stdout)

    def test_archive_verification_failure_blocks_release_ready_and_notes(self):
        (self.repo / "verify-release.sh").write_text("#!/bin/bash\necho 'Fixture archive verification failed' >&2\nexit 96\n")
        self.retag_fixture()
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Fixture archive verification failed", result.stdout)
        self.assertNotIn("Release ready:", result.stdout)
        self.assertFalse((self.output / "release-notes.md").exists())
        self.assert_worktree_cleaned()

    def test_note_generation_failure_blocks_release_ready(self):
        (self.repo / "generate-release-notes.sh").write_text(
            "#!/bin/bash\n"
            "for arg in \"$@\"; do [[ \"$arg\" == --check-output ]] && exit 0; done\n"
            "echo 'Fixture note generation failed' >&2\nexit 97\n"
        )
        self.retag_fixture()
        result = self.run_release()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Fixture note generation failed", result.stdout)
        self.assertNotIn("Release ready:", result.stdout)
        self.assertFalse((self.output / "release-notes.md").exists())
        self.assert_final_archive_verified()
        self.assert_worktree_cleaned()

    def test_unignored_output_inside_repository_fails_before_building(self):
        self.output = self.repo / "unignored release output"
        result = self.run_release()
        self.assert_failed_before_building(result)
        self.assertIn("ignored", result.stdout.lower())
        self.assertFalse((self.output / f"FluxLLM-{VERSION}.zip").exists())
        self.assertFalse((self.output / "release-notes.md").exists())
        self.assert_worktree_cleaned()

    def test_default_output_is_under_source_repository(self):
        # An annotated tag must resolve to the same source commit as a lightweight tag.
        self.git("tag", "-d", VERSION)
        self.git("tag", "-a", VERSION, "-m", "Annotated release fixture")
        result = self.run_release(output=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assert_artifact(self.repo / ".build/releases" / VERSION)
        self.assert_worktree_cleaned()

    def test_invalid_or_missing_tags_fail_before_building(self):
        self.git("branch", "2.3.4")
        for tag in ("v1.2.3", "1.2.3-beta", "01.2.3", "1.02.3", "1.2.03", "1.2", "1.2.3.4", "2.3.4", "9.8.7", "HEAD"):
            with self.subTest(tag=tag):
                self.assert_failed_before_signing(self.run_release(tag))
                self.assertEqual(self.calls("fixture-build"), [])

    def test_script_must_match_script_in_tag(self):
        with (self.repo / "package-release.sh").open("a") as file:
            file.write("\n# uncommitted release tooling change\n")
        self.assert_failed_before_signing(self.run_release())
        self.assertEqual(self.calls("fixture-build"), [])

    def test_development_signing_identity_is_rejected(self):
        self.assert_failed_before_signing(self.run_release(identity="Apple Development: Release Test (TESTTEAM)"))
        self.assertEqual(self.calls("fixture-build"), [])

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("do not replace\n")
        self.assert_failed_before_signing(self.run_release())
        self.assertEqual(sentinel.read_text(), "do not replace\n")
        self.assertEqual(self.calls("fixture-build"), [])
        self.assertEqual(self.calls("notarytool"), [])

    def test_changed_dependency_pins_block_signing(self):
        self.assert_failed_before_signing(self.run_release(env={"RELEASE_TEST_MUTATE": "dependencies"}))
        self.assert_worktree_cleaned()

    def test_changed_tracked_source_blocks_signing(self):
        self.assert_failed_before_signing(self.run_release(env={"RELEASE_TEST_MUTATE": "source"}))
        self.assert_worktree_cleaned()

    def test_build_failure_is_not_hidden_by_log_pipeline(self):
        self.assert_failed_before_signing(self.run_release(env={"RELEASE_TEST_FAIL": "build"}))
        self.assert_worktree_cleaned()

    def test_unexpected_binary_architecture_blocks_signing(self):
        self.assert_failed_before_signing(self.run_release(env={"RELEASE_TEST_BINARY_ARCH": "x86_64"}))
        self.assert_worktree_cleaned()

    def test_signing_failure_blocks_notarization(self):
        result = self.run_release(env={"RELEASE_TEST_FAIL": "sign"})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.notary_calls("submit"), [])
        self.assertFalse((self.output / f"FluxLLM-{VERSION}.zip").exists())
        self.assert_worktree_cleaned()

    def test_notarization_command_failure_blocks_stapling(self):
        result = self.run_release(env={"RELEASE_TEST_FAIL": "notary-command"})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls("stapler"), [])
        self.assertFalse((self.output / f"FluxLLM-{VERSION}.zip").exists())
        self.assert_worktree_cleaned()

    def test_notarization_rejection_blocks_stapling(self):
        result = self.run_release(env={"RELEASE_TEST_FAIL": "notary-status"})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls("stapler"), [])
        self.assertFalse((self.output / f"FluxLLM-{VERSION}.zip").exists())
        self.assert_worktree_cleaned()

    def test_stapling_failure_blocks_final_archive(self):
        result = self.run_release(env={"RELEASE_TEST_FAIL": "staple"})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.output / f"FluxLLM-{VERSION}.zip").exists())
        self.assert_worktree_cleaned()


if not RELEASE_SCRIPT.is_file():
    sys.exit(f"Release script not found: {RELEASE_SCRIPT}")
unittest.main(verbosity=2)
PY
