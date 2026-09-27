#!/bin/bash
# Disposable Git/ZIP fixtures; Apple verification tools are fail-closed mocks.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$REPO_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile


SOURCE_ROOT = Path(sys.argv.pop(1))
VERSION = "1.2.3"
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["VERIFY_TEST_LOG"], "a") as log:
    log.write(json.dumps({"tool": tool, "args": args}) + "\n")
if os.environ.get("VERIFY_TEST_FAIL") == tool:
    sys.exit(40)
if tool == "uname" and args == ["-s"]:
    print(os.environ.get("VERIFY_TEST_PLATFORM", "Darwin"))
elif tool == "lipo" and len(args) == 2 and args[0] == "-archs":
    print(os.environ.get("VERIFY_TEST_ARCH", "arm64"))
elif tool == "codesign" and args[:-1] == ["--verify", "--deep", "--strict", "--verbose=2"]:
    pass
elif tool == "xcrun" and args[:-1] == ["stapler", "validate"]:
    pass
elif tool == "spctl" and args[:-1] == ["--assess", "--type", "execute", "--verbose=2"]:
    if os.environ.get("VERIFY_TEST_MUTATE_ARCHIVE"):
        Path(os.environ["VERIFY_TEST_MUTATE_ARCHIVE"]).write_bytes(b"archive changed after verification")
    if os.environ.get("VERIFY_TEST_CREATE_DESTINATION"):
        Path(os.environ["VERIFY_TEST_CREATE_DESTINATION"]).mkdir()
    if os.environ.get("VERIFY_TEST_RECORD_INODE"):
        Path(os.environ["VERIFY_TEST_RECORD_INODE"]).write_text(str(Path(args[-1]).stat().st_ino))
else:
    sys.exit("Unexpected verifier tool call: " + tool + repr(args))
'''


class VerifyReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fluxllm-verify-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.repo = self.root / "source repo"
        self.repo.mkdir()
        self.mockbin = self.root / "mockbin"
        self.mockbin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.env = dict(os.environ, PATH=f"{self.mockbin}:{os.environ['PATH']}", VERIFY_TEST_LOG=str(self.log))
        self.env.pop("VERIFY_TEST_FAIL", None)
        self.env.pop("VERIFY_TEST_ARCH", None)
        self.env.pop("VERIFY_TEST_PLATFORM", None)
        self.env.pop("VERIFY_TEST_MUTATE_ARCHIVE", None)
        self.env.pop("VERIFY_TEST_CREATE_DESTINATION", None)
        self.env.pop("VERIFY_TEST_RECORD_INODE", None)
        (self.mockbin / "mock").write_text(MOCK)
        (self.mockbin / "mock").chmod(0o755)
        for tool in ("uname", "lipo", "codesign", "xcrun", "spctl"):
            (self.mockbin / tool).symlink_to("mock")
        self.git("init", "-q")
        self.git("config", "user.name", "Archive Test")
        self.git("config", "user.email", "archive@example.invalid")
        shutil.copyfile(SOURCE_ROOT / "verify-release.sh", self.repo / "verify-release.sh")
        (self.repo / "verify-release.sh").chmod(0o755)
        (self.repo / "LICENSE").write_text("Fixture MIT License\n")
        (self.repo / ".gitignore").write_text(".build/\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Verification fixture")
        self.git("tag", VERSION)
        self.commit = self.git("rev-parse", "HEAD").strip()
        self.release_dir = self.repo / ".build/releases" / VERSION
        self.release_dir.mkdir(parents=True)
        self.archive = self.release_dir / f"FluxLLM-{VERSION}.zip"
        self.app = self.root / "staging/FluxLLM.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Resources/FluxLLM_FluxLLM.bundle").mkdir(parents=True)
        self.executable = self.app / "Contents/MacOS/FluxLLMApp"
        self.executable.write_bytes(b"fixture executable")
        self.executable.chmod(0o755)
        shutil.copyfile(self.repo / "LICENSE", self.app / "Contents/Resources/LICENSE")
        self.plist = {
            "CFBundleIdentifier": "com.cmorgan.FluxLLM", "CFBundleExecutable": "FluxLLMApp",
            "CFBundleShortVersionString": VERSION, "CFBundleVersion": VERSION,
            "FluxLLMReleaseTag": VERSION, "FluxLLMCommitSHA": self.commit,
        }
        self.write_plist()
        self.info = self.release_dir / "release-info.txt"
        self.info.write_text(f"Tag: {VERSION}\nVersion: {VERSION}\nCommit: {self.commit}\n"
                             f"Architecture: arm64\nRelease title: FluxLLM {VERSION}\nArchive: {self.archive.name}\n")
        self.make_archive()

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.repo, env=self.env, text=True, stderr=subprocess.STDOUT)

    def write_plist(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.plist))

    def make_archive(self):
        if self.archive.exists():
            self.archive.unlink()
        # Exercise the same ZIP writer and metadata preservation as packaging.
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(self.app), str(self.archive)], check=True)
        self.checksum()

    def checksum(self):
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.release_dir / "SHA256SUMS").write_text(f"{digest}  {self.archive.name}\n")

    def add_entry(self, name, data=b"unexpected", mode=stat.S_IFREG | 0o644):
        with zipfile.ZipFile(self.archive, "a") as archive:
            item = zipfile.ZipInfo(name)
            item.create_system = 3
            item.external_attr = mode << 16
            archive.writestr(item, data)
        self.checksum()

    def verify(self, *extra, tag=VERSION, env=None, default=False):
        command = [str(self.repo / "verify-release.sh"), tag]
        if not default:
            command += ["--release-dir", str(self.release_dir)]
        result = subprocess.run(command + list(extra), cwd=self.root, env=dict(self.env, **(env or {})),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.last_output = result.stdout
        return result

    def calls(self, tool):
        return [entry for line in self.log.read_text().splitlines()
                if (entry := json.loads(line))["tool"] == tool] if self.log.exists() else []

    def rejected(self, result, message=None):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        if message:
            self.assertIn(message, result.stdout)

    def test_valid_archive_checks_extracted_app_and_cleans_up(self):
        result = self.verify(default=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        for tool in ("lipo", "codesign", "xcrun", "spctl"):
            calls = self.calls(tool)
            self.assertEqual(len(calls), 1, result.stdout)
            app_path = Path(calls[0]["args"][-1])
            self.assertNotIn(str(self.app), str(app_path))
            self.assertIn("/extracted/FluxLLM.app", str(app_path))
            self.assertFalse(app_path.exists())
        self.assertIn(self.commit, result.stdout)

    def test_invalid_tag(self):
        for tag in ("v1.2.3", "01.2.3", "1.2", "1.2.3-rc1", "../1.2.3"):
            with self.subTest(tag=tag):
                self.rejected(self.verify(tag=tag), "plain X.Y.Z")

    def test_export_retains_the_verified_app_and_permissions(self):
        destination = self.root / "verified app"
        inode_record = self.root / "verified-inode"
        (self.app / "Contents/Resources/LicenseLink").symlink_to("LICENSE")
        self.make_archive()
        result = self.verify("--extract-to", str(destination),
                             env={"VERIFY_TEST_RECORD_INODE": str(inode_record)})
        self.assertEqual(result.returncode, 0, result.stdout)
        app = destination / "FluxLLM.app"
        self.assertEqual(app.stat().st_ino, int(inode_record.read_text()))
        self.assertEqual((app / "Contents/MacOS/FluxLLMApp").read_bytes(), self.executable.read_bytes())
        self.assertTrue(os.access(app / "Contents/MacOS/FluxLLMApp", os.X_OK))
        link = app / "Contents/Resources/LicenseLink"
        self.assertTrue(link.is_symlink())
        self.assertEqual(os.readlink(link), "LICENSE")
        self.assertEqual(plistlib.loads((app / "Contents/Info.plist").read_bytes()), self.plist)
        self.assertIn(str(app), result.stdout)
        self.assertEqual(list(self.root.glob("fluxllm-verify-*")), [])

    def test_export_uses_snapshot_after_original_archive_changes(self):
        destination = self.root / "verified"
        result = self.verify("--extract-to", str(destination),
                             env={"VERIFY_TEST_MUTATE_ARCHIVE": str(self.archive)})
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.archive.read_bytes(), b"archive changed after verification")
        self.assertEqual((destination / "FluxLLM.app/Contents/MacOS/FluxLLMApp").read_bytes(),
                         self.executable.read_bytes())

    def test_failed_verification_never_exports(self):
        destination = self.root / "verified"
        self.rejected(self.verify("--extract-to", str(destination), env={"VERIFY_TEST_FAIL": "spctl"}))
        self.assertFalse(os.path.lexists(destination))
        self.assertEqual(list(self.root.glob("fluxllm-verify-*")), [])

    def test_export_refuses_existing_files_directories_and_symlinks(self):
        destinations = [self.root / name for name in ("file", "directory", "link", "dangling")]
        destinations[0].write_text("preserved")
        destinations[1].mkdir()
        destinations[2].symlink_to(destinations[1], target_is_directory=True)
        destinations[3].symlink_to(self.root / "missing")
        for destination in destinations:
            with self.subTest(destination=destination):
                self.rejected(self.verify("--extract-to", str(destination)), "already exists")
                self.assertTrue(os.path.lexists(destination))
        self.assertEqual(destinations[0].read_text(), "preserved")
        self.assertEqual(list(destinations[1].iterdir()), [])
        self.assertTrue(destinations[2].is_symlink())
        self.assertTrue(destinations[3].is_symlink())
        self.assertFalse(self.calls("codesign"))

    def test_export_does_not_clobber_concurrent_empty_destination(self):
        destination = self.root / "verified"
        result = self.verify("--extract-to", str(destination),
                             env={"VERIFY_TEST_CREATE_DESTINATION": str(destination)})
        self.rejected(result, "File exists")
        self.assertEqual(list(destination.iterdir()), [])
        self.assertEqual(list(self.root.glob("fluxllm-verify-*")), [])

    def test_export_requires_existing_parent(self):
        destination = self.root / "missing/verified"
        self.rejected(self.verify("--extract-to", str(destination)))
        self.assertFalse(destination.parent.exists())
        self.assertFalse(self.calls("codesign"))

    def test_missing_tag(self):
        self.rejected(self.verify(tag="9.9.9"))

    def test_checksum_mismatch(self):
        with self.archive.open("ab") as archive:
            archive.write(b"tampered")
        self.rejected(self.verify(), "checksum mismatch")
        self.assertFalse(self.calls("codesign"))

    def test_corrupt_zip_with_matching_checksum(self):
        self.archive.write_bytes(b"This is not a ZIP file.")
        self.checksum()
        self.rejected(self.verify(), "not a zip file")
        self.assertFalse(self.calls("codesign"))

    def test_manifest_rejects_other_paths_and_extra_entries(self):
        manifest = self.release_dir / "SHA256SUMS"
        original = manifest.read_text()
        for text in (original.replace(self.archive.name, "../" + self.archive.name), original + original,
                     original.replace(self.archive.name, "/tmp/" + self.archive.name)):
            with self.subTest(manifest=text):
                manifest.write_text(text)
                self.rejected(self.verify(), "exactly one checksum")

    def test_release_provenance_mismatch(self):
        self.info.write_text(self.info.read_text().replace(self.commit, "0" * 40))
        self.rejected(self.verify(), "release-info.txt")

    def test_duplicate_metadata(self):
        with self.info.open("a") as info:
            info.write(f"Tag: {VERSION}\n")
        self.rejected(self.verify(), "duplicate")

    def test_version_and_commit_mismatch(self):
        for key in ("CFBundleVersion", "CFBundleShortVersionString", "FluxLLMReleaseTag", "FluxLLMCommitSHA", "CFBundleIdentifier"):
            with self.subTest(key=key):
                previous = self.plist[key]
                self.plist[key] = "wrong"
                self.write_plist()
                self.make_archive()
                self.rejected(self.verify(), key)
                self.plist[key] = previous

    def test_tagged_license_mismatch(self):
        (self.app / "Contents/Resources/LICENSE").write_text("wrong license")
        self.make_archive()
        self.rejected(self.verify(), "LICENSE differs")

    def test_missing_resources(self):
        (self.app / "Contents/Resources/FluxLLM_FluxLLM.bundle").rmdir()
        self.make_archive()
        self.rejected(self.verify(), "resource bundle")

    def test_missing_executable_permission(self):
        self.executable.chmod(0o644)
        self.make_archive()
        self.rejected(self.verify(), "execute permission")

    def test_wrong_architecture(self):
        self.rejected(self.verify(env={"VERIFY_TEST_ARCH": "x86_64 arm64"}), "exactly the arm64")

    def test_verification_tools_fail_closed(self):
        for tool in ("codesign", "xcrun", "spctl"):
            with self.subTest(tool=tool):
                self.rejected(self.verify(env={"VERIFY_TEST_FAIL": tool}), tool + " failed")

    def test_requires_macos(self):
        self.rejected(self.verify(env={"VERIFY_TEST_PLATFORM": "Linux"}), "requires macOS")

    def test_traversal_and_absolute_paths(self):
        for name in ("FluxLLM.app/../escape", "/tmp/escape", "FluxLLM.app\\escape", "other.app/file", "FluxLLM.app/./escape"):
            with self.subTest(name=name):
                self.make_archive()
                self.add_entry(name)
                self.rejected(self.verify())
                self.assertFalse(self.calls("codesign"))

    def test_symlink_escape(self):
        self.add_entry("FluxLLM.app/Contents/escape", b"../../../outside", stat.S_IFLNK | 0o777)
        self.rejected(self.verify(), "Unsafe archive path")

    def test_symlink_ancestor_injection(self):
        self.add_entry("FluxLLM.app/link", b"Contents", stat.S_IFLNK | 0o777)
        self.add_entry("FluxLLM.app/link/injected")
        self.rejected(self.verify(), "nested beneath")

    def test_safe_internal_symlink(self):
        (self.app / "Contents/Resources/LicenseLink").symlink_to("LICENSE")
        self.make_archive()
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_safe_internal_symlink_chain(self):
        (self.app / "Contents/Resources/LicenseLink").symlink_to("LICENSE")
        (self.app / "Contents/Resources/OtherLink").symlink_to("LicenseLink")
        self.make_archive()
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_framework_directory_symlinks(self):
        framework = self.app / "Contents/Frameworks/Test.framework"
        version = framework / "Versions/A"
        version.mkdir(parents=True)
        (version / "Test").write_bytes(b"fixture framework")
        (framework / "Versions/Current").symlink_to("A")
        (framework / "Test").symlink_to("Versions/Current/Test")
        self.make_archive()
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_symlink_cycle(self):
        self.add_entry("FluxLLM.app/link-a", b"link-b", stat.S_IFLNK | 0o777)
        self.add_entry("FluxLLM.app/link-b", b"link-a", stat.S_IFLNK | 0o777)
        self.rejected(self.verify(), "symlink cycle")

    def test_dangling_symlink(self):
        self.add_entry("FluxLLM.app/link", b"missing", stat.S_IFLNK | 0o777)
        self.rejected(self.verify(), "dangling symlink")

    def test_case_collision(self):
        self.add_entry("FluxLLM.app/Contents/info.plist")
        self.rejected(self.verify(), "Duplicate archive path")

    def test_unicode_collision(self):
        self.add_entry("FluxLLM.app/Contents/caf\u00e9")
        self.add_entry("FluxLLM.app/Contents/cafe\u0301")
        self.rejected(self.verify(), "Duplicate archive path")

    def test_special_file(self):
        self.add_entry("FluxLLM.app/fifo", b"", stat.S_IFIFO | 0o600)
        self.rejected(self.verify(), "special file")

    def test_app_root_must_be_directory(self):
        self.archive.unlink()
        self.add_entry("FluxLLM.app")
        self.rejected(self.verify(), "app root must be a directory")

    def test_metadata_symlink(self):
        self.add_entry("__MACOSX/link", b"FluxLLM.app", stat.S_IFLNK | 0o777)
        self.rejected(self.verify(), "Unsafe archive symlink")

    def test_artifact_symlink(self):
        original = self.archive.with_suffix(".original")
        self.archive.rename(original)
        self.archive.symlink_to(original)
        self.rejected(self.verify(), "Missing regular file")


unittest.main()
PY
