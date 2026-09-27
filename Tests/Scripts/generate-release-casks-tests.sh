#!/bin/bash
# Test cask generation using disposable Git repositories and a fail-closed
# verifier fixture. No app build, signing, Keychain access, or network is used.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$REPO_ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_ROOT = Path(sys.argv.pop(1))
TAG = "1.2.3"
ARCHIVE = f"FluxLLM-{TAG}.zip"
ARTIFACTS = (ARCHIVE, "SHA256SUMS", "release-info.txt")
MOCK_VERIFIER = r'''#!/bin/bash
exec python3 - "$@" <<'VERIFY'
import hashlib, json, os, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
if len(args) != 3 or args[1] != "--release-dir":
    sys.exit("Unexpected verifier arguments: " + repr(args))
tag, _, snapshot = args
snapshot = Path(snapshot)
source = Path(os.environ["CASK_TEST_SOURCE"])
with open(os.environ["CASK_TEST_LOG"], "a") as log:
    log.write(json.dumps({"args": args, "files": sorted(p.name for p in snapshot.iterdir())}) + "\n")
if source == snapshot or source in snapshot.parents:
    sys.exit("Verifier did not receive an independent snapshot")
if os.environ.get("CASK_TEST_FAIL"):
    sys.exit("Mock archive verification failed")
archive_name = f"FluxLLM-{tag}.zip"
checksum = hashlib.sha256((snapshot / archive_name).read_bytes()).hexdigest()
if (snapshot / "SHA256SUMS").read_text() != f"{checksum}  {archive_name}\n":
    sys.exit("Mock checksum mismatch")
commit = subprocess.check_output(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], text=True).strip()
expected = (f"Tag: {tag}\nVersion: {tag}\nCommit: {commit}\nArchitecture: arm64\n"
            f"Release title: FluxLLM {tag}\nArchive: {archive_name}\n")
if (snapshot / "release-info.txt").read_text() != expected:
    sys.exit("Mock provenance mismatch")
if os.environ.get("CASK_TEST_MUTATE_SOURCE"):
    for name in (archive_name, "SHA256SUMS", "release-info.txt"):
        (source / name).write_text("modified after snapshot\n")
if os.environ.get("CASK_TEST_MOVE_TAG"):
    subprocess.run(["git", "tag", "-f", tag, "HEAD~1"], check=True, stdout=subprocess.DEVNULL)
if os.environ.get("CASK_TEST_OUTPUT_RACE"):
    directory = Path(os.environ["CASK_TEST_OUTPUT_RACE"])
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"fluxllm@{tag}.rb").write_text("another generator won\n")
VERIFY
'''


class GeneratorTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fluxllm-cask-tests-")
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.release = self.repo / ".build/releases" / TAG
        self.release.mkdir(parents=True)
        self.output = self.release / "Casks"
        self.env = dict(os.environ, CASK_TEST_SOURCE=str(self.release), CASK_TEST_LOG=str(self.root / "verify.jsonl"))
        for key in list(self.env):
            if key.startswith("CASK_TEST_") and key not in ("CASK_TEST_SOURCE", "CASK_TEST_LOG"):
                del self.env[key]
        shutil.copy2(SOURCE_ROOT / "generate-release-casks.sh", self.repo)
        (self.repo / "verify-release.sh").write_text(MOCK_VERIFIER)
        (self.repo / ".gitignore").write_text(".build/\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Cask Test")
        self.git("config", "user.email", "cask-test@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Add fixtures")
        (self.repo / "LICENSE").write_text("test license\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Add release")
        self.commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("tag", TAG)
        self.archive_bytes = b"immutable verified archive fixture\x00\x01"
        self.checksum = hashlib.sha256(self.archive_bytes).hexdigest()
        (self.release / ARCHIVE).write_bytes(self.archive_bytes)
        (self.release / "SHA256SUMS").write_text(f"{self.checksum}  {ARCHIVE}\n")
        (self.release / "release-info.txt").write_text(
            f"Tag: {TAG}\nVersion: {TAG}\nCommit: {self.commit}\nArchitecture: arm64\n"
            f"Release title: FluxLLM {TAG}\nArchive: {ARCHIVE}\n")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], text=True, capture_output=True, check=True)

    def generate(self, *args, tag=TAG, env=None):
        return subprocess.run([str(self.repo / "generate-release-casks.sh"), tag, *args],
                              cwd=self.repo, text=True, capture_output=True, env=env or self.env)

    def succeeds(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def fails(self, result, diagnostic):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(diagnostic, result.stderr)

    def log(self):
        path = self.root / "verify.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_default_generates_both_casks(self):
        self.succeeds(self.generate())
        self.assertEqual(sorted(p.name for p in self.output.iterdir()), ["fluxllm.rb", f"fluxllm@{TAG}.rb"])
        for token in ("fluxllm", f"fluxllm@{TAG}"):
            text = (self.output / f"{token}.rb").read_text()
            self.assertTrue(text.startswith(f'cask "{token}" do\n'))
            self.assertIn(f'  version "{TAG}"\n', text)
            self.assertIn(f'  sha256 "{self.checksum}"\n', text)
            self.assertIn(f'  url "https://github.com/chmorgan/fluxllm/releases/download/{TAG}/{ARCHIVE}"\n', text)
            self.assertIn('  depends_on arch: :arm64\n', text)
            self.assertIn('  depends_on macos: :sequoia\n', text)
            self.assertIn('  app "FluxLLM.app"\n', text)
            self.assertIn("Uninstall the current cask before switching versions.", text)
            self.assertEqual("  livecheck do\n" in text, "@" in token)
            self.assertNotIn("token", text.lower())
            self.assertNotIn("password", text.lower())
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertEqual(len(self.log()), 1)
        self.assertEqual(self.log()[0]["files"], sorted(ARTIFACTS))
        self.assertFalse(Path(self.log()[0]["args"][2]).exists())

    def test_idempotent_does_not_rewrite(self):
        self.succeeds(self.generate())
        original = {p.name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in self.output.iterdir()}
        self.succeeds(self.generate())
        self.assertEqual(original, {p.name: (p.read_bytes(), p.stat().st_ino, p.stat().st_mtime_ns) for p in self.output.iterdir()})
        self.assertEqual(len(self.log()), 2)

    def test_can_restore_one_missing_identical_cask(self):
        self.succeeds(self.generate())
        (self.output / f"fluxllm@{TAG}.rb").unlink()
        self.succeeds(self.generate())
        self.assertTrue((self.output / f"fluxllm@{TAG}.rb").is_file())

    def test_external_output(self):
        output = self.root / "external casks"
        self.succeeds(self.generate("--output-dir", str(output)))
        self.assertTrue((output / "fluxllm.rb").is_file())
        self.assertFalse(self.output.exists())

    def test_custom_release_directory(self):
        release = self.root / "external release"
        self.release.rename(release)
        env = dict(self.env, CASK_TEST_SOURCE=str(release))
        self.succeeds(self.generate("--release-dir", str(release), env=env))
        self.assertTrue((release / "Casks/fluxllm.rb").exists())

    def test_source_changes_after_snapshot_do_not_change_cask(self):
        self.succeeds(self.generate(env=dict(self.env, CASK_TEST_MUTATE_SOURCE="1")))
        self.assertEqual((self.release / ARCHIVE).read_text(), "modified after snapshot\n")
        self.assertIn(self.checksum, (self.output / "fluxllm.rb").read_text())
        self.assertEqual(self.log()[0]["files"], sorted(ARTIFACTS))

    def test_invalid_tag(self):
        for tag in ("v1.2.3", "1.2", "01.2.3", "1.2.3-rc1", "../1.2.3"):
            with self.subTest(tag=tag):
                self.fails(self.generate(tag=tag), "Tag must be plain")
        self.assertFalse(self.log())
        self.assertFalse(self.output.exists())

    def test_missing_tag(self):
        self.fails(self.generate(tag="9.9.9"), "Cask generation failed")
        self.assertFalse(self.log())

    def test_missing_release_directory_suggests_packaging(self):
        shutil.rmtree(self.release)
        self.fails(self.generate(), f"Run ./package-release.sh {TAG} first")
        self.assertFalse(self.output.exists())

    def test_missing_artifacts(self):
        for name in ARTIFACTS:
            with self.subTest(name=name):
                path = self.release / name
                path.rename(self.release / "saved")
                self.fails(self.generate(), "Cask generation failed")
                (self.release / "saved").rename(path)
        self.assertFalse(self.log())
        self.assertFalse(self.output.exists())

    def test_symlink_artifacts_rejected(self):
        for name in ARTIFACTS:
            with self.subTest(name=name):
                path = self.release / name
                saved = self.release / "saved"
                path.rename(saved)
                path.symlink_to(saved)
                self.fails(self.generate(), "Cask generation failed")
                path.unlink()
                saved.rename(path)
        self.assertFalse(self.log())

    def test_directory_artifact_rejected(self):
        path = self.release / ARCHIVE
        path.unlink()
        path.mkdir()
        self.fails(self.generate(), "Cask generation failed")
        self.assertFalse(self.log())

    def test_fifo_artifact_rejected_without_blocking(self):
        path = self.release / ARCHIVE
        path.unlink()
        os.mkfifo(path)
        self.fails(self.generate(), "Expected a regular file")
        self.assertFalse(self.log())

    def test_verifier_failure_creates_no_output(self):
        self.fails(self.generate(env=dict(self.env, CASK_TEST_FAIL="1")), "Release archive verification failed")
        self.assertFalse(self.output.exists())

    def test_checksum_mismatch(self):
        (self.release / ARCHIVE).write_bytes(b"tampered")
        self.fails(self.generate(), "Mock checksum mismatch")
        self.assertFalse(self.output.exists())

    def test_provenance_mismatch(self):
        (self.release / "release-info.txt").write_text("Tag: 9.9.9\n")
        self.fails(self.generate(), "Mock provenance mismatch")
        self.assertFalse(self.output.exists())

    def test_tag_change_during_verification(self):
        self.fails(self.generate(env=dict(self.env, CASK_TEST_MOVE_TAG="1")), "Release tag changed")
        self.assertFalse(self.output.exists())

    def test_conflicting_current_cask(self):
        self.output.mkdir()
        path = self.output / "fluxllm.rb"
        path.write_text("keep current\n")
        self.fails(self.generate(), "Existing cask differs")
        self.assertEqual(path.read_text(), "keep current\n")
        self.assertFalse((self.output / f"fluxllm@{TAG}.rb").exists())

    def test_conflicting_exact_cask_preflights_both_before_writing(self):
        self.output.mkdir()
        path = self.output / f"fluxllm@{TAG}.rb"
        path.write_text("keep exact\n")
        self.fails(self.generate(), "Existing cask differs")
        self.assertEqual(path.read_text(), "keep exact\n")
        self.assertFalse((self.output / "fluxllm.rb").exists())

    def test_output_symlink_rejected(self):
        self.output.mkdir()
        outside = self.root / "outside"
        outside.write_text("do not change\n")
        (self.output / "fluxllm.rb").symlink_to(outside)
        self.fails(self.generate(), "Expected a regular output file")
        self.assertEqual(outside.read_text(), "do not change\n")
        self.assertFalse((self.output / f"fluxllm@{TAG}.rb").exists())

    def test_dangling_output_symlink_rejected(self):
        self.output.mkdir()
        (self.output / f"fluxllm@{TAG}.rb").symlink_to(self.root / "absent")
        self.fails(self.generate(), "Expected a regular output file")
        self.assertFalse((self.output / "fluxllm.rb").exists())

    def test_output_directory_symlink_rejected(self):
        outside = self.root / "outside"
        outside.mkdir()
        self.output.symlink_to(outside)
        self.fails(self.generate(), "Output directory must not be a symlink")
        self.assertEqual(list(outside.iterdir()), [])

    def test_output_directory_is_file_rejected(self):
        self.output.write_text("keep file\n")
        self.fails(self.generate(), "Output path is not a directory")
        self.assertEqual(self.output.read_text(), "keep file\n")

    def test_output_file_is_directory_rejected(self):
        (self.output / "fluxllm.rb").mkdir(parents=True)
        self.fails(self.generate(), "Expected a regular output file")
        self.assertFalse((self.output / f"fluxllm@{TAG}.rb").exists())

    def test_unignored_repository_output_rejected(self):
        output = self.repo / "Casks"
        self.fails(self.generate("--output-dir", str(output)), "ignored, untracked")
        self.assertFalse(output.exists())

    def test_tracked_output_rejected_even_if_identical(self):
        self.succeeds(self.generate())
        self.git("add", "-f", str(self.output / "fluxllm.rb"))
        self.fails(self.generate(), "must not use a tracked path")

    def test_output_created_during_verification_is_not_overwritten(self):
        self.fails(self.generate(env=dict(self.env, CASK_TEST_OUTPUT_RACE=str(self.output))), "Existing cask differs")
        self.assertEqual((self.output / f"fluxllm@{TAG}.rb").read_text(), "another generator won\n")
        self.assertFalse((self.output / "fluxllm.rb").exists())

    @unittest.skipUnless(shutil.which("brew"), "Homebrew is unavailable; fixture tests still run")
    def test_homebrew_loads_generated_casks_without_installing(self):
        self.succeeds(self.generate())
        cache = self.root / "brew-cache"
        temporary = self.root / "brew-temp"
        cache.mkdir()
        temporary.mkdir()
        env = dict(self.env, HOMEBREW_NO_AUTO_UPDATE="1", HOMEBREW_NO_ANALYTICS="1",
                   HOMEBREW_NO_INSTALL_FROM_API="1", HOMEBREW_NO_BOOTSNAP="1", HOMEBREW_DEVELOPER="1",
                   HOMEBREW_CACHE=str(cache), HOMEBREW_TEMP=str(temporary))
        # Load through Homebrew's real DSL without installing, downloading, or
        # depending on a globally registered tap. Audit no longer accepts paths.
        ruby = r'''require "cask/cask_loader"
expected_checksum = ARGV.shift
ARGV.each do |path|
  cask = Cask::CaskLoader::FromContentLoader.new(File.read(path)).load(config: nil)
  abort "Token mismatch" unless cask.token == File.basename(path, ".rb")
  abort "Version mismatch" unless cask.version.to_s == "1.2.3"
  abort "Architecture mismatch" unless cask.depends_on[:arch] == [{ type: :arm, bits: 64 }]
  abort "macOS requirement mismatch" unless cask.depends_on[:macos].version.to_s == "15"
  abort "Checksum mismatch" unless cask.sha256.to_s == expected_checksum
  abort "URL mismatch" unless cask.url.to_s == "https://github.com/chmorgan/fluxllm/releases/download/1.2.3/FluxLLM-1.2.3.zip"
  puts "Loaded #{cask.token}"
end
'''
        result = subprocess.run([shutil.which("brew"), "ruby", "-e", ruby, "--", self.checksum,
                                 str(self.output / "fluxllm.rb"), str(self.output / f"fluxllm@{TAG}.rb")],
                                env=env, capture_output=True, text=True, timeout=60)
        self.succeeds(result)
        self.assertIn("Loaded fluxllm@1.2.3", result.stdout)

    def test_help_concise(self):
        result = self.generate(tag="--help")
        self.succeeds(result)
        self.assertIn("--output-dir", result.stdout)
        self.assertIn("- Identical existing casks", result.stdout)
        self.assertFalse(self.log())
        self.assertLess(len(result.stdout.splitlines()), 25)


if __name__ == "__main__":
    unittest.main(verbosity=2)
PY
