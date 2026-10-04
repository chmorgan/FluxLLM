#!/bin/bash
# Disposable products; every signing and platform tool is a local test double.
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
COMMIT = "0123456789abcdef0123456789abcdef01234567"
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import plistlib
import sys

tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ["PREVIEW_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": tool, "args": args}) + "\n")
failure = os.environ.get("PREVIEW_TEST_FAIL")
if tool == "uname" and args in (["-s"], ["-m"]):
    print(os.environ.get("PREVIEW_TEST_PLATFORM", "Darwin") if args == ["-s"] else "arm64")
elif tool == "lipo" and len(args) == 2 and args[0] == "-archs":
    key = "PREVIEW_TEST_LIBRARY_ARCHITECTURE" if Path(args[1]).suffix == ".dylib" else "PREVIEW_TEST_ARCHITECTURE"
    print(os.environ.get(key, "arm64"))
elif tool == "codesign" and args[:-1] == ["--force", "--sign", "-"]:
    target = Path(args[-1])
    if target.is_file() and target.suffix == ".dylib":
        if failure == "library-sign": sys.exit("Fixture runtime library signing failed")
        target.write_bytes(target.read_bytes() + b"\nfixture-library-signature")
        if failure == "change-runtime-input":
            Path(os.environ["PREVIEW_TEST_PRODUCTS"], target.name).write_bytes(b"changed immutable runtime")
        sys.exit(0)
    if failure == "sign": sys.exit("Fixture signing failed")
    app = target
    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if metadata.get("FluxLLMCommitSHA") != os.environ["PREVIEW_TEST_COMMIT"]:
        sys.exit("Commit was not stamped before signing")
    declared = json.loads(Path(os.environ["PREVIEW_TEST_PRODUCTS"], "provenance.json").read_text()).get("runtime_library_sha256", {})
    for name in declared:
        if not (app / "Contents/MacOS" / name).read_bytes().endswith(b"\nfixture-library-signature"):
            sys.exit("Runtime library was not signed before its app")
    executable = app / "Contents/MacOS/FluxLLMApp"
    executable.write_bytes(executable.read_bytes() + b"\nfixture-signature")
    (app / "Contents/fixture-signature").write_text("signed\n")
    if failure == "change-resources":
        (app / "Contents/Resources/FluxLLM.icns").write_bytes(b"changed icon")
    if failure == "change-input":
        Path(os.environ["PREVIEW_TEST_PRODUCTS"], "FluxLLMApp").write_bytes(b"changed immutable input")
    if failure == "change-library-after-app":
        (app / "Contents/MacOS" / next(iter(declared))).write_bytes(b"changed signed runtime")
elif tool == "codesign" and args[:-1] == ["--verify", "--deep", "--strict", "--verbose=2"]:
    target = Path(args[-1])
    if target.is_file() and target.suffix == ".dylib":
        if failure == "library-verify": sys.exit("Fixture runtime signature verification failed")
        if not target.read_bytes().endswith(b"\nfixture-library-signature"): sys.exit("Fixture runtime was not signed")
        sys.exit(0)
    if failure == "verify": sys.exit("Fixture signature verification failed")
    if not (target / "Contents/fixture-signature").is_file(): sys.exit("Fixture app was not signed")
else:
    sys.exit("Forbidden or unexpected tool call: " + tool + repr(args))
'''


def path_hash(path):
    checksum = hashlib.sha256()
    if path.is_file():
        checksum.update(path.read_bytes())
    else:
        for child in sorted(path.rglob("*")):
            if child.is_file():
                checksum.update(str(child.relative_to(path)).encode())
                checksum.update(b"\0")
                checksum.update(child.read_bytes())
                checksum.update(b"\0")
    return checksum.hexdigest()


class PackagePreviewTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fluxllm-preview-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / "source repo"
        (self.repo / "Resources").mkdir(parents=True)
        self.script = self.repo / "package-preview.sh"
        shutil.copy2(SOURCE_ROOT / "package-preview.sh", self.script)
        self.plist = self.repo / "Resources/Info.plist"
        shutil.copy2(SOURCE_ROOT / "Resources/Info.plist", self.plist)
        self.products = self.root / "native products"
        self.products.mkdir()
        self.binary = self.products / "FluxLLMApp"
        self.binary.write_bytes(b"fixture Release executable")
        self.binary.chmod(0o755)
        self.branding = self.products / "FluxLLM_FluxLLM.bundle"
        assets = self.branding / "Contents/Resources/Branding"
        assets.mkdir(parents=True)
        self.icon = assets / "FluxLLM.icns"
        self.icon.write_bytes(b"fixture icon")
        (assets / "menu artwork.png").write_bytes(b"fixture branding artwork")
        (self.products / "FluxLLMResourceCollector").write_bytes(b"must not ship collector")
        (self.products / "FluxLLMDrawingProbe").write_bytes(b"must not ship drawing probe")
        (self.products / "FluxLLMPackageTests.xctest").mkdir()
        self.provenance = {
            "schema_version": 1, "production_commit": COMMIT, "worktree_is_dirty": False,
            "build_configuration": "release", "source_tree_sha256": "fixture source tree hash",
            "binary_sha256": {"app": path_hash(self.binary)},
            "resource_bundle_sha256": {self.branding.name: path_hash(self.branding)},
        }
        self.manifest = {"git_head": COMMIT, "sha256": self.provenance["source_tree_sha256"], "files": {
            "Resources/Info.plist": {"sha256": path_hash(self.plist)},
            "Sources/FluxLLM/Resources/Branding/FluxLLM.icns": {"sha256": path_hash(self.icon)},
        }}
        self.write_metadata()
        self.output = self.root / "preview output"
        self.mockbin = self.root / "mockbin"
        self.mockbin.mkdir()
        mock = self.mockbin / "mock"
        mock.write_text(MOCK)
        mock.chmod(0o755)
        for tool in ("uname", "lipo", "codesign", "swift", "xcodebuild", "open", "osascript", "git",
                     "kill", "pkill", "killall", "notarytool", "stapler", "security", "spctl", "brew", "launchctl"):
            (self.mockbin / tool).symlink_to("mock")
        self.log = self.root / "calls.jsonl"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("PREVIEW_TEST_")}
        self.env.update(PATH=str(self.mockbin) + os.pathsep + os.environ["PATH"],
                        PREVIEW_TEST_LOG=str(self.log), PREVIEW_TEST_COMMIT=COMMIT,
                        PREVIEW_TEST_PRODUCTS=str(self.products))

    def write_metadata(self):
        (self.products / "provenance.json").write_text(json.dumps(self.provenance))
        (self.products / "source-tree-manifest.json").write_text(json.dumps(self.manifest))

    def add_runtime(self, name="libswiftCompatibilitySpan.dylib"):
        source = self.products / name
        source.write_bytes(b"fixture runtime library " + name.encode())
        self.provenance.setdefault("runtime_library_sha256", {})[name] = path_hash(source)
        self.write_metadata()
        return source

    def run_preview(self, *, commit=COMMIT, output=None, env=None):
        return subprocess.run(["/bin/bash", str(self.script), "--products", str(self.products), "--commit", commit,
                               "--output", str(output or self.output)], cwd=self.repo, env=env or self.env,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_rejected(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertFalse((self.output / "preview-info.json").exists())

    def test_packages_only_the_proven_inputs_without_building_or_touching_installed_apps(self):
        installed = self.root / "Applications/FluxLLM.app/Contents/MacOS"
        installed.mkdir(parents=True)
        marker = installed / "FluxLLMApp"
        marker.write_bytes(b"existing desktop app, including user PID 23307")
        original = {str(path): path.read_bytes() for path in self.products.rglob("*") if path.is_file()}
        result = self.run_preview()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.output / f"FluxLLM-Preview-{COMMIT[:12]}.app"
        metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(metadata["FluxLLMCommitSHA"], COMMIT)
        self.assertEqual(metadata["CFBundleIdentifier"], "com.cmorgan.FluxLLM")
        self.assertTrue(metadata["LSUIElement"])
        self.assertEqual([p.name for p in (app / "Contents/MacOS").iterdir()], ["FluxLLMApp"])
        self.assertEqual({p.name for p in (app / "Contents/Resources").iterdir()}, {"FluxLLM_FluxLLM.bundle", "FluxLLM.icns"})
        info = json.loads((self.output / "preview-info.json").read_text())
        self.assertEqual(info["copied_app_sha256_before_signing"], self.provenance["binary_sha256"]["app"])
        self.assertEqual(info["input_binary_sha256_key"], "app")
        self.assertNotEqual(info["packaged_app_sha256_after_signing"], info["input_app_sha256"])
        self.assertEqual(info["branding_sha256"], path_hash(self.branding))
        self.assertFalse(info["notarized"])
        self.assertFalse(info["built"] or info["launched"] or info["installed"])
        self.assertEqual(info["runtime_libraries"], {})
        self.assertEqual(original, {str(path): path.read_bytes() for path in self.products.rglob("*") if path.is_file()})
        self.assertEqual(marker.read_bytes(), b"existing desktop app, including user PID 23307")
        self.assertEqual([call["tool"] for call in self.calls()], ["uname", "uname", "lipo", "codesign", "codesign"])

    def test_separated_products_package_the_desktop_binary_using_its_own_hash(self):
        performance = self.products / "FluxLLMPerformanceApp"
        performance.write_bytes(b"different benchmark executable, must not ship")
        performance.chmod(0o755)
        self.provenance["performance_executable"] = performance.name
        self.provenance["binary_sha256"]["desktop_app"] = path_hash(self.binary)
        self.provenance["binary_sha256"]["app"] = path_hash(performance)
        self.write_metadata()
        result = self.run_preview()
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.output / f"FluxLLM-Preview-{COMMIT[:12]}.app"
        packaged = app / "Contents/MacOS/FluxLLMApp"
        self.assertEqual(packaged.read_bytes(), self.binary.read_bytes() + b"\nfixture-signature")
        self.assertEqual([path.name for path in packaged.parent.iterdir()], ["FluxLLMApp"])
        info = json.loads((self.output / "preview-info.json").read_text())
        self.assertEqual(info["input_binary_sha256_key"], "desktop_app")
        self.assertEqual(info["performance_executable"], "FluxLLMPerformanceApp")
        self.assertEqual(info["input_app_sha256"], self.provenance["binary_sha256"]["desktop_app"])
        self.assertNotEqual(info["input_app_sha256"], self.provenance["binary_sha256"]["app"])

    def test_separated_products_cannot_fall_back_to_the_benchmark_hash(self):
        self.provenance["performance_executable"] = "FluxLLMPerformanceApp"
        self.write_metadata()
        self.assert_rejected(self.run_preview(), "must declare a full desktop_app")
        self.assertFalse(self.output.exists())

    def test_explicit_legacy_performance_name_keeps_the_app_hash(self):
        self.provenance["performance_executable"] = "FluxLLMApp"
        self.provenance["binary_sha256"]["desktop_app"] = "0" * 64
        self.write_metadata()
        result = self.run_preview()
        self.assertEqual(result.returncode, 0, result.stderr)
        info = json.loads((self.output / "preview-info.json").read_text())
        self.assertEqual(info["input_binary_sha256_key"], "app")

    def test_unknown_performance_executable_is_rejected(self):
        self.provenance["performance_executable"] = "UnknownApp"
        self.write_metadata()
        self.assert_rejected(self.run_preview(), "Unknown performance executable")
        self.assertFalse(self.output.exists())

    def test_declared_runtimes_are_copied_beside_the_app_and_signed_first(self):
        libraries = [self.add_runtime(), self.add_runtime("libHelper.dylib")]
        original = {source.name: source.read_bytes() for source in libraries}
        result = self.run_preview(env=dict(self.env, PREVIEW_TEST_LIBRARY_ARCHITECTURE="x86_64 arm64 arm64e"))
        self.assertEqual(result.returncode, 0, result.stderr)
        app = self.output / f"FluxLLM-Preview-{COMMIT[:12]}.app"
        self.assertEqual({p.name for p in (app / "Contents/MacOS").iterdir()}, {"FluxLLMApp", *original})
        info = json.loads((self.output / "preview-info.json").read_text())
        self.assertEqual(set(info["runtime_libraries"]), set(original))
        for source in libraries:
            signed = app / "Contents/MacOS" / source.name
            entry = info["runtime_libraries"][source.name]
            self.assertEqual(entry["input_sha256"], path_hash(source))
            self.assertEqual(entry["copied_sha256_before_signing"], path_hash(source))
            self.assertEqual(entry["packaged_sha256_after_signing"], path_hash(signed))
            self.assertNotEqual(entry["packaged_sha256_after_signing"], entry["input_sha256"])
            self.assertEqual(source.read_bytes(), original[source.name])
        signing = [Path(call["args"][-1]).name for call in self.calls() if call["tool"] == "codesign" and "--sign" in call["args"]]
        self.assertEqual(signing, ["libHelper.dylib", "libswiftCompatibilitySpan.dylib", app.name])
        self.assertTrue(all(call["tool"] in {"uname", "lipo", "codesign"} for call in self.calls()))

    def test_runtime_inventory_requires_safe_library_basenames_and_full_hashes(self):
        variants = (None, [], {"../libOutside.dylib": "0" * 64}, {"/tmp/libOutside.dylib": "0" * 64},
                    {"libFolder/nested.dylib": "0" * 64}, {"FluxLLMApp": "0" * 64},
                    {"libExample.dylib": "short"}, {"libExample.dylib": 123})
        for value in variants:
            with self.subTest(value=value):
                self.provenance["runtime_library_sha256"] = value
                self.write_metadata()
                self.assert_rejected(self.run_preview(), "library")
                self.assertFalse(self.output.exists())

    def test_runtime_missing_hash_mismatch_and_symlink_are_rejected(self):
        name = "libswiftCompatibilitySpan.dylib"
        self.provenance["runtime_library_sha256"] = {name: "0" * 64}
        self.write_metadata()
        self.assert_rejected(self.run_preview(), "regular file inside products")
        source = self.products / name
        source.write_bytes(b"wrong runtime")
        self.assert_rejected(self.run_preview(), "Runtime library hash differs")
        source.unlink()
        source.symlink_to(self.binary)
        self.assert_rejected(self.run_preview(), "regular file inside products")
        self.assertFalse(self.output.exists())

    def test_runtime_architecture_must_cover_the_app_slices(self):
        self.add_runtime()
        self.assert_rejected(self.run_preview(env=dict(self.env, PREVIEW_TEST_LIBRARY_ARCHITECTURE="x86_64")),
                             "lacks the executable's supported architectures")
        self.assertFalse(self.output.exists())

    def test_runtime_sign_verify_and_post_sign_changes_do_not_publish_ready_metadata(self):
        self.add_runtime()
        variants = (("library-sign", "codesign failed"), ("library-verify", "codesign failed"),
                    ("change-library-after-app", "App signing changed its signed runtime library"),
                    ("change-runtime-input", "Immutable runtime library changed"))
        for failure, message in variants:
            with self.subTest(failure=failure):
                output = self.root / failure
                result = self.run_preview(output=output, env=dict(self.env, PREVIEW_TEST_FAIL=failure))
                self.assert_rejected(result, message)
                self.assertFalse((output / "preview-info.json").exists())

    def test_existing_output_and_its_app_are_never_overwritten_or_deleted(self):
        existing = self.output / "FluxLLM.app"
        existing.mkdir(parents=True)
        marker = existing / "keep.txt"
        marker.write_text("keep existing app")
        self.assert_rejected(self.run_preview(), "Output already exists")
        self.assertEqual(marker.read_text(), "keep existing app")
        self.assertEqual(self.calls(), [])

    def test_broken_output_symlink_is_never_replaced(self):
        self.output.symlink_to(self.root / "absent target")
        self.assert_rejected(self.run_preview(), "Output already exists")
        self.assertTrue(self.output.is_symlink())

    def test_output_cannot_modify_input_products_or_an_existing_app(self):
        for output in (self.products / "new preview", self.root / "FluxLLM.app/new preview"):
            with self.subTest(output=output):
                self.assertNotEqual(self.run_preview(output=output).returncode, 0)
                self.assertFalse(output.exists())

    def test_full_commit_and_clean_release_provenance_are_required(self):
        self.assert_rejected(self.run_preview(commit="0123456"), "full lowercase")
        variants = ({"production_commit": "f" * 40}, {"worktree_is_dirty": True}, {"build_configuration": "debug"})
        original = dict(self.provenance)
        for values in variants:
            with self.subTest(values=values):
                self.provenance = dict(original, **values)
                self.write_metadata()
                self.assert_rejected(self.run_preview(), "requested clean Release commit")
                self.assertFalse(self.output.exists())

    def test_app_and_branding_hash_mismatches_are_rejected_before_signing(self):
        self.binary.write_bytes(b"unproven executable")
        self.assert_rejected(self.run_preview(), "differ from the input Release provenance")
        self.assertFalse(self.output.exists())
        self.binary.write_bytes(b"fixture Release executable")
        (self.branding / "unexpected.txt").write_text("changed resource")
        self.assert_rejected(self.run_preview(), "differ from the input Release provenance")
        self.assertFalse(any(call["tool"] == "codesign" for call in self.calls()))

    def test_plist_and_icon_must_match_the_input_source_inventory(self):
        self.plist.write_bytes(plistlib.dumps({"unrelated": True}))
        self.assert_rejected(self.run_preview(), "Info.plist template differs")
        shutil.copy2(SOURCE_ROOT / "Resources/Info.plist", self.plist)
        self.icon.write_bytes(b"unproven icon")
        self.provenance["resource_bundle_sha256"][self.branding.name] = path_hash(self.branding)
        self.write_metadata()
        self.assert_rejected(self.run_preview(), "Bundled icon differs")
        self.assertFalse(self.output.exists())

    def test_symlink_resources_are_rejected(self):
        (self.branding / "external-link").symlink_to(self.binary)
        self.assert_rejected(self.run_preview(), "must not contain symlinks")
        self.assertFalse(self.output.exists())

    def test_non_macos_and_wrong_architecture_are_rejected(self):
        self.assert_rejected(self.run_preview(env=dict(self.env, PREVIEW_TEST_PLATFORM="Linux")), "requires macOS")
        self.assert_rejected(self.run_preview(env=dict(self.env, PREVIEW_TEST_ARCHITECTURE="x86_64")), "supported slice")
        self.assertFalse(self.output.exists())

    def test_signing_and_verification_failures_never_publish_ready_metadata(self):
        for failure in ("sign", "verify"):
            with self.subTest(failure=failure):
                output = self.root / ("failed-" + failure)
                result = self.run_preview(output=output, env=dict(self.env, PREVIEW_TEST_FAIL=failure))
                self.assert_rejected(result, "codesign failed")
                self.assertTrue(output.exists())
                self.assertFalse((output / "preview-info.json").exists())

    def test_changed_signed_resources_and_changed_inputs_are_detected(self):
        for failure, message in (("change-resources", "Signing changed"), ("change-input", "Immutable input products changed")):
            with self.subTest(failure=failure):
                output = self.root / failure
                self.assert_rejected(self.run_preview(output=output, env=dict(self.env, PREVIEW_TEST_FAIL=failure)), message)
                self.assertFalse((output / "preview-info.json").exists())


unittest.main()
PY
