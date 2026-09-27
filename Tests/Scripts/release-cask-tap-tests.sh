#!/bin/bash
# Local Git fixtures only: no builds, credentials, Homebrew installs, or network access.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$REPO_ROOT" <<'PY'
import ast
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SOURCE_ROOT = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("release_cask_tap", SOURCE_ROOT / "scripts/release_cask_tap.py")
tap = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = tap
spec.loader.exec_module(tap)
REAL_RUN = subprocess.run


class ReleaseCaskTapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fluxllm-tap-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "source repo"
        self.remote = self.root / "remote.git"
        self.repo.mkdir()
        self.env = mock.patch.dict(os.environ, {
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_NAME": "Tap Test",
            "GIT_AUTHOR_EMAIL": "tap@example.invalid", "GIT_COMMITTER_NAME": "Tap Test",
            "GIT_COMMITTER_EMAIL": "tap@example.invalid",
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Tap Test")
        self.git("config", "user.email", "tap@example.invalid")
        (self.repo / "README.md").write_text("Source repository\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "Initial source")
        self.git("init", "-q", "--bare", str(self.remote))
        self.git("symbolic-ref", "HEAD", "refs/heads/main", repo=self.remote)
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-q", "-u", "origin", "main")
        self.remote_patch = mock.patch.object(tap, "REMOTE_URL", str(self.remote))
        self.remote_patch.start()
        self.addCleanup(self.remote_patch.stop)

    def git(self, *args, repo=None, check=True):
        return REAL_RUN(["git", "-C", str(repo or self.repo), *args],
                        text=True, capture_output=True, check=check)

    def cask(self, tag, pinned=False, checksum="a" * 64, literal_url=True):
        token = "fluxllm@" + tag if pinned else "fluxllm"
        url = (f"https://github.com/chmorgan/fluxllm/releases/download/{tag}/FluxLLM-{tag}.zip"
               if literal_url else
               "https://github.com/chmorgan/fluxllm/releases/download/#{version}/FluxLLM-#{version}.zip")
        lines = [f'cask "{token}" do', f'  version "{tag}"', f'  sha256 "{checksum}"',
                 "", f'  url "{url}"', '  name "FluxLLM"',
                 '  desc "Menu bar monitor and proxy for local language models"',
                 '  homepage "https://github.com/chmorgan/fluxllm"', ""]
        if pinned:
            lines += ["  livecheck do", '    skip "This cask installs a fixed release"', "  end", ""]
        lines += ["  depends_on arch: :arm64", "  depends_on macos: :sequoia", "",
                  '  app "FluxLLM.app"', "", "  caveats <<~EOS",
                  "    Install only one FluxLLM cask at a time. Uninstall the current cask before switching versions.",
                  "  EOS", "end", ""]
        return "\n".join(lines)

    def release(self, tag="1.2.3", checksum="a" * 64):
        directory = self.root / "release artifacts" / tag / "Casks"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "fluxllm.rb").write_text(self.cask(tag, checksum=checksum))
        (directory / f"fluxllm@{tag}.rb").write_text(self.cask(tag, pinned=True, checksum=checksum))
        if self.git("rev-parse", "--verify", f"refs/tags/{tag}", check=False).returncode:
            self.git("tag", tag)
            self.git("push", "-q", "origin", f"refs/tags/{tag}")
        return directory

    def update(self, tag="1.2.3", stable=True, cask_dir=None):
        return tap.update_tap(self.repo, tag, cask_dir or self.release(tag), stable)

    def remote_file(self, path):
        return self.git("show", f"main:{path}", repo=self.remote).stdout

    def remote_head(self):
        return self.git("rev-parse", "main", repo=self.remote).stdout.strip()

    def remote_paths(self):
        return self.git("ls-tree", "-r", "--name-only", "main", repo=self.remote).stdout.splitlines()

    def remote_edit(self, files, message="Existing tap changes"):
        checkout = self.root / "remote editor"
        if checkout.exists():
            shutil.rmtree(checkout)
        self.git("clone", "-q", str(self.remote), str(checkout))
        self.git("config", "user.name", "Tap Test", repo=checkout)
        self.git("config", "user.email", "tap@example.invalid", repo=checkout)
        for path, content in files.items():
            destination = checkout / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(content)
        self.git("add", ".", repo=checkout)
        self.git("commit", "-q", "-m", message, repo=checkout)
        self.git("push", "-q", "origin", "main", repo=checkout)
        return checkout

    def rejected(self, tag="1.2.3", stable=True, cask_dir=None):
        before = self.remote_head()
        with self.assertRaises(tap.TapUpdateError):
            self.update(tag=tag, stable=stable, cask_dir=cask_dir)
        self.assertEqual(self.remote_head(), before)

    def test_stable_publishes_both_casks_in_one_commit(self):
        before = self.remote_head()
        result = self.update()
        self.assertTrue(result["updated"])
        self.assertEqual(result["commit"], self.remote_head())
        self.assertEqual(self.git("rev-parse", "main^", repo=self.remote).stdout.strip(), before)
        self.assertEqual(self.remote_file("Casks/fluxllm.rb"), self.cask("1.2.3"))
        self.assertEqual(self.remote_file("Casks/fluxllm@1.2.3.rb"), self.cask("1.2.3", pinned=True))
        changed = self.git("diff-tree", "--no-commit-id", "--name-only", "-r", "main", repo=self.remote).stdout.splitlines()
        self.assertEqual(changed, ["Casks/fluxllm.rb", "Casks/fluxllm@1.2.3.rb"])
        self.assertNotIn("\\n", self.git("show", "-s", "--format=%B", "main", repo=self.remote).stdout)

    def test_actual_generator_output_is_accepted_by_tap_helper(self):
        # Exercise the real pure renderer without running the generator's CLI,
        # Apple verifier, or any external tools. Keep this separate from the
        # hand-written cask fixtures so format drift cannot pass unnoticed.
        script = (SOURCE_ROOT / "generate-release-casks.sh").read_text()
        source = script.split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        tree = ast.parse(source)
        definitions = [node for node in tree.body
                       if (isinstance(node, ast.FunctionDef) and node.name == "render")
                       or (isinstance(node, ast.Assign)
                           and any(isinstance(target, ast.Name) and target.id == "PROJECT_URL"
                                   for target in node.targets))]
        self.assertEqual(len(definitions), 2)
        namespace = {}
        exec(compile(ast.Module(body=definitions, type_ignores=[]), "generator-render", "exec"), namespace)
        directory = self.release()
        for exact, filename in ((False, "fluxllm.rb"), (True, "fluxllm@1.2.3.rb")):
            (directory / filename).write_bytes(namespace["render"]("1.2.3", "a" * 64, exact=exact))
        result = self.update(cask_dir=directory)
        self.assertTrue(result["updated"])
        for path in directory.iterdir():
            self.assertEqual(self.remote_file("Casks/" + path.name), path.read_text())

    def test_prerelease_only_publishes_exact_version(self):
        self.update(stable=False)
        self.assertIn("Casks/fluxllm@1.2.3.rb", self.remote_paths())
        self.assertNotIn("Casks/fluxllm.rb", self.remote_paths())

    def test_newer_stable_advances_current_and_preserves_old_pin(self):
        self.update("1.2.3")
        old_pin = self.remote_file("Casks/fluxllm@1.2.3.rb")
        self.update("1.10.0")
        self.assertIn('version "1.10.0"', self.remote_file("Casks/fluxllm.rb"))
        self.assertEqual(self.remote_file("Casks/fluxllm@1.2.3.rb"), old_pin)

    def test_older_stable_adds_pin_without_downgrading_current(self):
        self.update("1.10.0")
        current = self.remote_file("Casks/fluxllm.rb")
        self.update("1.2.3")
        self.assertEqual(self.remote_file("Casks/fluxllm.rb"), current)
        self.assertIn("Casks/fluxllm@1.2.3.rb", self.remote_paths())

    def test_newer_prerelease_preserves_stable_current(self):
        self.update("1.2.3")
        current = self.remote_file("Casks/fluxllm.rb")
        self.update("2.0.0", stable=False)
        self.assertEqual(self.remote_file("Casks/fluxllm.rb"), current)
        self.assertIn("Casks/fluxllm@2.0.0.rb", self.remote_paths())

    def test_completed_update_is_noop(self):
        self.update()
        before = self.remote_head()
        result = self.update()
        self.assertFalse(result["updated"])
        self.assertIsNone(result["commit"])
        self.assertEqual(self.remote_head(), before)

    def test_completed_prerelease_is_noop(self):
        self.update(stable=False)
        before = self.remote_head()
        result = self.update(stable=False)
        self.assertFalse(result["updated"])
        self.assertEqual(self.remote_head(), before)

    def test_prerelease_can_later_become_current_without_rewriting_pin(self):
        self.update(stable=False)
        pin = self.remote_file("Casks/fluxllm@1.2.3.rb")
        self.assertTrue(self.update()["updated"])
        self.assertEqual(self.remote_file("Casks/fluxllm@1.2.3.rb"), pin)
        self.assertIn("Casks/fluxllm.rb", self.remote_paths())

    def test_existing_pin_checksum_conflict_is_rejected(self):
        self.remote_edit({"Casks/fluxllm@1.2.3.rb": self.cask("1.2.3", pinned=True, checksum="b" * 64)})
        self.rejected()

    def test_existing_pin_version_conflict_is_rejected(self):
        cask = self.cask("1.2.3", pinned=True).replace('version "1.2.3"', 'version "1.2.2"')
        self.remote_edit({"Casks/fluxllm@1.2.3.rb": cask})
        self.rejected()

    def test_existing_pin_url_conflict_is_rejected(self):
        cask = self.cask("1.2.3", pinned=True).replace("chmorgan/fluxllm/releases", "another/project/releases")
        self.remote_edit({"Casks/fluxllm@1.2.3.rb": cask})
        self.rejected()

    def test_existing_same_version_current_checksum_conflict_is_rejected(self):
        self.remote_edit({"Casks/fluxllm.rb": self.cask("1.2.3", checksum="b" * 64)})
        self.rejected()

    def test_existing_pin_comments_and_spacing_are_preserved(self):
        existing = "# Kept by a tap maintainer\n" + self.cask("1.2.3", pinned=True).replace("  version", "    version")
        self.remote_edit({"Casks/fluxllm@1.2.3.rb": existing})
        self.update()
        self.assertEqual(self.remote_file("Casks/fluxllm@1.2.3.rb"), existing)

    def test_existing_pin_with_conditional_url_override_is_rejected(self):
        existing = self.cask("1.2.3", pinned=True).replace(
            '  app "FluxLLM.app"',
            '  on_arm do\n    url("https://example.invalid/different.zip")\n  end\n\n  app "FluxLLM.app"')
        self.remote_edit({"Casks/fluxllm@1.2.3.rb": existing})
        self.rejected()
        self.assertEqual(self.remote_file("Casks/fluxllm@1.2.3.rb"), existing)

    def test_existing_current_with_conditional_url_override_is_rejected(self):
        existing = self.cask("1.2.3").replace(
            '  app "FluxLLM.app"',
            '  on_arm do\n    url("https://example.invalid/different.zip")\n  end\n\n  app "FluxLLM.app"')
        self.remote_edit({"Casks/fluxllm.rb": existing})
        self.rejected()
        self.assertEqual(self.remote_file("Casks/fluxllm.rb"), existing)

    def test_existing_pin_with_dynamic_version_override_is_rejected(self):
        existing = self.cask("1.2.3", pinned=True).replace(
            '  version "1.2.3"', '  version "1.2.3"\n  version ENV["FLUXLLM_VERSION"]')
        self.remote_edit({"Casks/fluxllm@1.2.3.rb": existing})
        self.rejected()

    def test_interpolated_url_pin_is_rejected_without_evaluating_ruby(self):
        existing = self.cask("1.2.3", pinned=True, literal_url=False)
        self.remote_edit({"Casks/fluxllm@1.2.3.rb": existing})
        self.rejected()

    def test_unrelated_working_staged_local_commits_and_tags_are_untouched(self):
        (self.repo / "local-only.txt").write_text("Never publish this\n")
        self.git("add", "local-only.txt")
        self.git("commit", "-q", "-m", "Unpublished source work")
        self.git("tag", "local-only-tag")
        (self.repo / "README.md").write_text("Staged edit\n")
        self.git("add", "README.md")
        (self.repo / "README.md").write_text("Unstaged edit\n")
        (self.repo / "untracked.txt").write_text("Untracked edit\n")
        release = self.release()
        before = {key: self.git(*args).stdout for key, args in {
            "head": ("rev-parse", "HEAD"), "status": ("status", "--porcelain"),
            "staged": ("diff", "--cached"), "unstaged": ("diff",),
            "tags": ("show-ref", "--tags"),
        }.items()}
        self.update(cask_dir=release)
        for key, args in {"head": ("rev-parse", "HEAD"), "status": ("status", "--porcelain"),
                          "staged": ("diff", "--cached"), "unstaged": ("diff",),
                          "tags": ("show-ref", "--tags")}.items():
            self.assertEqual(self.git(*args).stdout, before[key], key)
        self.assertNotIn("local-only.txt", self.remote_paths())
        self.assertNotIn("untracked.txt", self.remote_paths())
        self.assertNotEqual(self.git("show-ref", "--verify", "refs/tags/local-only-tag", repo=self.remote, check=False).returncode, 0)

    def test_commit_uses_the_source_repository_git_identity(self):
        self.git("config", "user.name", "Release Maintainer")
        self.git("config", "user.email", "maintainer@example.invalid")
        self.update()
        author = self.git("show", "-s", "--format=%an <%ae>", "main", repo=self.remote).stdout.strip()
        self.assertEqual(author, "Release Maintainer <maintainer@example.invalid>")

    def test_missing_git_identity_fails_before_push(self):
        release = self.release()
        for field in ("name", "email"):
            with self.subTest(field=field):
                self.git("config", "user." + field, "")
                self.rejected(cask_dir=release)
                self.git("config", "user." + field, "Tap Test" if field == "name" else "tap@example.invalid")

    def test_noop_does_not_require_git_identity(self):
        self.update()
        self.git("config", "user.name", "")
        self.git("config", "user.email", "")
        result = self.update()
        self.assertFalse(result["updated"])

    def test_inherited_alternate_git_index_is_ignored(self):
        release = self.release()
        original_index = (self.repo / ".git/index").read_bytes()
        alternate_index = self.root / "alternate-index"
        with mock.patch.dict(os.environ, {"GIT_INDEX_FILE": str(alternate_index)}):
            self.update(cask_dir=release)
        self.assertFalse(alternate_index.exists())
        self.assertEqual((self.repo / ".git/index").read_bytes(), original_index)

    def test_push_rejection_can_be_retried(self):
        release = self.release()
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        self.rejected(cask_dir=release)
        hook.unlink()
        self.assertTrue(self.update(cask_dir=release)["updated"])

    def test_non_fast_forward_never_force_pushes_over_competing_commit(self):
        release = self.release()
        raced = []
        pushes = []

        def racing_run(command, *args, **kwargs):
            if isinstance(command, (list, tuple)) and "push" in command:
                pushes.append(list(command))
                if not raced:
                    self.remote_edit({"another-release.txt": "Concurrent maintainer work\n"}, "Concurrent remote change")
                    raced.append(self.remote_head())
            return REAL_RUN(command, *args, **kwargs)

        with mock.patch.object(subprocess, "run", side_effect=racing_run):
            try:
                self.update(cask_dir=release)
            except tap.TapUpdateError:
                pass
        self.assertTrue(raced, "Did not intercept a Git push")
        self.assertTrue(pushes)
        for push in pushes:
            self.assertFalse(any(str(arg).startswith(("--force", "+")) or arg == "-f" for arg in push), push)
        self.assertEqual(self.remote_file("another-release.txt"), "Concurrent maintainer work\n")
        self.assertEqual(self.git("merge-base", "--is-ancestor", raced[0], "main", repo=self.remote, check=False).returncode, 0)
        self.update(cask_dir=release)
        self.assertIn("Casks/fluxllm@1.2.3.rb", self.remote_paths())

    def test_invalid_tags_are_rejected_without_remote_changes(self):
        directory = self.release()
        for tag in ("v1.2.3", "01.2.3", "1.2", "../1.2.3", "1.2.3\n", "1.2.3-rc1"):
            with self.subTest(tag=tag):
                self.rejected(tag=tag, cask_dir=directory)

    def test_missing_generated_cask_is_rejected(self):
        directory = self.release()
        (directory / "fluxllm@1.2.3.rb").unlink()
        self.rejected(cask_dir=directory)

    def test_generated_cask_symlink_is_rejected(self):
        directory = self.release()
        target = self.root / "outside.rb"
        target.write_text(self.cask("1.2.3", pinned=True))
        pinned = directory / "fluxllm@1.2.3.rb"
        pinned.unlink()
        pinned.symlink_to(target)
        self.rejected(cask_dir=directory)

    def test_generated_cask_directory_symlink_is_rejected(self):
        directory = self.release()
        link = self.root / "linked-casks"
        link.symlink_to(directory, target_is_directory=True)
        self.rejected(cask_dir=link)

    def test_generated_cask_wrong_token_is_rejected(self):
        directory = self.release()
        path = directory / "fluxllm@1.2.3.rb"
        path.write_text(path.read_text().replace('cask "fluxllm@1.2.3"', 'cask "unrelated"'))
        self.rejected(cask_dir=directory)

    def test_generated_executable_ruby_is_rejected_without_running_it(self):
        directory = self.release()
        marker = self.root / "unexpected-ruby-execution"
        path = directory / "fluxllm@1.2.3.rb"
        path.write_text(path.read_text() + f'File.write("{marker}", "executed")\n')
        self.rejected(cask_dir=directory)
        self.assertFalse(marker.exists())

    def test_invalid_stable_status_is_rejected(self):
        directory = self.release()
        for stable in (None, "false", "true", 0, 1):
            with self.subTest(stable=stable):
                self.rejected(stable=stable, cask_dir=directory)

    def test_generated_cask_checksum_mismatch_is_rejected(self):
        directory = self.release()
        (directory / "fluxllm.rb").write_text(self.cask("1.2.3", checksum="b" * 64))
        self.rejected(cask_dir=directory)

    def test_generated_cask_url_outside_release_is_rejected(self):
        directory = self.release()
        for path in directory.iterdir():
            path.write_text(path.read_text().replace("https://github.com/chmorgan/fluxllm/releases", "https://example.invalid/releases"))
        self.rejected(cask_dir=directory)

    def test_remote_casks_symlink_is_rejected(self):
        checkout = self.remote_edit({"existing.txt": "Keep me\n"})
        (checkout / "Casks").symlink_to(".", target_is_directory=True)
        self.git("add", "Casks", repo=checkout)
        self.git("commit", "-q", "-m", "Unsafe cask directory", repo=checkout)
        self.git("push", "-q", "origin", "main", repo=checkout)
        self.rejected()

    def test_remote_cask_symlink_is_rejected(self):
        checkout = self.remote_edit({"existing.rb": self.cask("1.2.3", pinned=True)})
        (checkout / "Casks").mkdir()
        (checkout / "Casks/fluxllm@1.2.3.rb").symlink_to("../existing.rb")
        self.git("add", "Casks", repo=checkout)
        self.git("commit", "-q", "-m", "Unsafe pinned cask", repo=checkout)
        self.git("push", "-q", "origin", "main", repo=checkout)
        self.rejected()

    def test_remote_casks_regular_file_is_rejected(self):
        self.remote_edit({"Casks": "Not a directory\n"})
        self.rejected()

    def test_remote_current_unknown_version_is_rejected(self):
        self.remote_edit({"Casks/fluxllm.rb": self.cask("1.2.3").replace('version "1.2.3"', 'version :latest')})
        self.rejected()


unittest.main(verbosity=2)
PY
