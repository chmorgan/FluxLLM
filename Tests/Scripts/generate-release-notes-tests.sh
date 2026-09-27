#!/bin/bash
# Local Git fixtures only: no builds, credentials, or network access.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$REPO_ROOT" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_ROOT = Path(sys.argv.pop(1))


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fluxllm-notes-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "source repo"
        self.repo.mkdir()
        self.env = dict(os.environ)
        self.env.update({"GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        self.git("init", "-q")
        self.git("config", "user.name", "Release Notes Test")
        self.git("config", "user.email", "release-notes@example.invalid")
        shutil.copyfile(SOURCE_ROOT / "generate-release-notes.sh", self.repo / "generate-release-notes.sh")
        (self.repo / ".gitignore").write_text(".build/\n")
        self.git("add", ".")
        self.git("commit", "-q", "-m", "Initial source")

    def git(self, *arguments, repo=None, check=True):
        return subprocess.run(["git", "-C", str(repo or self.repo), *arguments], env=self.env,
                              text=True, capture_output=True, check=check)

    def commit(self, subject):
        self.git("commit", "-q", "--allow-empty", "-m", subject)
        return self.git("rev-parse", "--short", "HEAD").stdout.strip()

    def tag(self, name, *arguments):
        self.git("tag", *arguments, name)

    def run_script(self, *arguments, success=True, cwd=None):
        result = subprocess.run(["bash", str(self.repo / "generate-release-notes.sh"), *arguments],
                                cwd=cwd or self.repo, env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def notes(self, tag="1.0.0"):
        return (self.repo / ".build" / "releases" / tag / "release-notes.md").read_text()

    def test_initial_history_and_default_ignored_location(self):
        commit = self.commit("Ship first release")
        self.tag("1.0.0")
        self.run_script("1.0.0", cwd=self.root)
        notes = self.notes()
        self.assertIn("# FluxLLM 1.0.0", notes)
        self.assertIn("Apple Silicon Macs running macOS 15 or later", notes)
        self.assertIn("Initial source", notes)
        self.assertIn("Ship first release (`" + commit + "`)", notes)
        self.assertIn("/commits/1.0.0", notes)
        self.assertIn("intentionally untracked", notes)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_range_excludes_previous_tag_and_later_work(self):
        self.commit("Already released")
        self.tag("0.9.0")
        first = self.commit("First new change")
        second = self.commit("Second new change")
        self.tag("1.0.0")
        self.commit("Not released yet")
        self.run_script("1.0.0")
        notes = self.notes()
        self.assertNotIn("Already released", notes)
        self.assertNotIn("Not released yet", notes)
        self.assertLess(notes.index(first), notes.index(second))
        self.assertIn("/compare/0.9.0...1.0.0", notes)

    def test_numeric_version_order(self):
        self.tag("0.9.0")
        self.commit("Included in 0.10")
        self.tag("0.10.0")
        self.commit("New release change")
        self.tag("1.0.0")
        self.run_script("1.0.0")
        self.assertIn("/compare/0.10.0...1.0.0", self.notes())
        self.assertNotIn("Included in 0.10", self.notes())

    def test_higher_version_ancestor_is_not_previous(self):
        self.tag("2.0.0")
        self.commit("Smaller version release")
        self.tag("1.0.0")
        self.run_script("1.0.0")
        self.assertIn("Initial source", self.notes())
        self.assertIn("/commits/1.0.0", self.notes())

    def test_unrelated_lower_tag_is_ignored(self):
        self.tag("0.8.0")
        branch = self.git("rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
        self.git("checkout", "-q", "-b", "unrelated")
        self.commit("Other branch work")
        self.tag("0.9.0")
        self.git("checkout", "-q", branch)
        self.commit("Release branch work")
        self.tag("1.0.0")
        self.run_script("1.0.0")
        self.assertIn("/compare/0.8.0...1.0.0", self.notes())
        self.assertNotIn("Other branch work", self.notes())

    def test_annotated_previous_and_target_tags(self):
        self.tag("0.9.0", "-a", "-m", "Previous release")
        self.commit("New version")
        self.tag("1.0.0", "-a", "-m", "Current release")
        self.run_script("1.0.0")
        self.assertIn("/compare/0.9.0...1.0.0", self.notes())

    def test_explicit_previous_override(self):
        self.tag("0.8.0")
        self.commit("Include older change")
        self.tag("0.9.0")
        self.commit("Newest change")
        self.tag("1.0.0")
        self.run_script("1.0.0", "--previous-tag", "0.8.0")
        self.assertIn("Include older change", self.notes())
        self.assertIn("/compare/0.8.0...1.0.0", self.notes())

    def test_previous_must_be_lower(self):
        self.tag("1.0.0")
        self.tag("2.0.0")
        for previous in ("1.0.0", "2.0.0"):
            with self.subTest(previous=previous):
                result = self.run_script("1.0.0", "--previous-tag", previous, success=False)
                self.assertIn("lower version", result.stderr)

    def test_explicit_previous_must_be_ancestor(self):
        self.tag("1.0.0")
        self.commit("Later source")
        self.tag("0.9.0")
        result = self.run_script("1.0.0", "--previous-tag", "0.9.0", success=False)
        self.assertIn("must be an ancestor", result.stderr)

    def test_same_commit_previous_tag_has_no_changes(self):
        self.tag("0.9.0")
        self.tag("1.0.0")
        self.run_script("1.0.0")
        self.assertIn("No commits since 0.9.0.", self.notes())

    def test_nonstable_tags_are_ignored(self):
        for tag in ("v0.9.0", "0.9.0-rc1", "00.9.0"):
            self.tag(tag)
        self.commit("Stable release")
        self.tag("1.0.0")
        self.run_script("1.0.0")
        self.assertIn("/commits/1.0.0", self.notes())

    def test_previous_tag_on_a_tree_is_ignored(self):
        self.git("tag", "0.9.0", "HEAD^{tree}")
        self.tag("1.0.0")
        self.run_script("1.0.0")
        self.assertIn("/commits/1.0.0", self.notes())

    def test_target_tag_on_a_tree_is_rejected(self):
        self.git("tag", "1.0.0", "HEAD^{tree}")
        result = self.run_script("1.0.0", success=False)
        self.assertIn("does not point to a commit", result.stderr)

    def test_invalid_tags_fail(self):
        for tag in ("v1.0.0", "1.0", "01.0.0", "1.0.0-rc1", "1.0.0+build", "HEAD", "1.0.0\n"):
            with self.subTest(tag=tag):
                result = self.run_script(tag, success=False)
                self.assertIn("plain MAJOR.MINOR.PATCH", result.stderr)

    def test_invalid_previous_tag_fails(self):
        self.tag("1.0.0")
        result = self.run_script("1.0.0", "--previous-tag", "v0.9.0", success=False)
        self.assertIn("plain MAJOR.MINOR.PATCH", result.stderr)

    def test_missing_target_tag_fails(self):
        result = self.run_script("1.0.0", success=False)
        self.assertIn("does not exist", result.stderr)

    def test_missing_previous_tag_fails(self):
        self.tag("1.0.0")
        result = self.run_script("1.0.0", "--previous-tag", "0.9.0", success=False)
        self.assertIn("does not exist", result.stderr)

    def test_existing_notes_preserve_edits(self):
        self.tag("1.0.0")
        self.run_script("1.0.0")
        output = self.repo / ".build/releases/1.0.0/release-notes.md"
        output.write_text("Human edited notes\n")
        result = self.run_script("1.0.0", success=False)
        self.assertIn("already exist", result.stderr)
        self.assertEqual(output.read_text(), "Human edited notes\n")

    def test_custom_external_output_with_spaces(self):
        self.tag("1.0.0")
        output = self.root / "release drafts" / "notes.md"
        self.run_script("1.0.0", "--output", str(output))
        self.assertIn("# FluxLLM 1.0.0", output.read_text())

    def test_check_output_default_does_not_create_directories(self):
        self.tag("1.0.0")
        result = self.run_script("1.0.0", "--check-output")
        self.assertIn("destination is valid", result.stdout)
        self.assertFalse((self.repo / ".build").exists())

    def test_check_output_external_does_not_create_directories(self):
        self.tag("1.0.0")
        output = self.root / "release drafts" / "notes.md"
        result = self.run_script("1.0.0", "--output", str(output), "--check-output")
        self.assertIn("destination is valid", result.stdout)
        self.assertFalse(output.parent.exists())

    def test_check_output_existing_notes_are_rejected(self):
        self.tag("1.0.0")
        output = self.root / "notes.md"
        output.write_text("Human edited notes\n")
        result = self.run_script("1.0.0", "--output", str(output), "--check-output", success=False)
        self.assertIn("already exist", result.stderr)
        self.assertEqual(output.read_text(), "Human edited notes\n")

    def test_check_output_unignored_repository_path_is_rejected(self):
        self.tag("1.0.0")
        result = self.run_script("1.0.0", "--output", "notes/draft.md", "--check-output", success=False)
        self.assertIn("ignored, untracked", result.stderr)
        self.assertFalse((self.repo / "notes").exists())

    def test_check_output_still_validates_tags(self):
        result = self.run_script("1.0.0", "--check-output", success=False)
        self.assertIn("does not exist", result.stderr)
        self.assertFalse((self.repo / ".build").exists())

    def test_relative_output_is_relative_to_current_directory(self):
        self.tag("1.0.0")
        self.run_script("1.0.0", "--output", "drafts/notes.md", cwd=self.root)
        self.assertTrue((self.root / "drafts/notes.md").is_file())

    def test_unignored_repo_output_is_rejected(self):
        self.tag("1.0.0")
        result = self.run_script("1.0.0", "--output", "release-notes.md", success=False)
        self.assertIn("ignored, untracked", result.stderr)
        self.assertFalse((self.repo / "release-notes.md").exists())

    def test_deleted_tracked_output_is_rejected(self):
        path = self.repo / "tracked-notes.md"
        path.write_text("Tracked content\n")
        self.git("add", "tracked-notes.md")
        self.git("commit", "-q", "-m", "Track notes")
        self.tag("1.0.0")
        path.unlink()
        result = self.run_script("1.0.0", "--output", str(path), success=False)
        self.assertIn("tracked path", result.stderr)
        self.assertFalse(path.exists())

    def test_existing_symlink_is_not_replaced_or_followed(self):
        self.tag("1.0.0")
        target = self.root / "must-not-be-created.md"
        output = self.root / "notes-link.md"
        output.symlink_to(target)
        self.run_script("1.0.0", "--output", str(output), success=False)
        self.assertTrue(output.is_symlink())
        self.assertFalse(target.exists())

    def test_output_through_symlink_into_unignored_repo_is_rejected(self):
        self.tag("1.0.0")
        (self.root / "source-link").symlink_to(self.repo)
        result = self.run_script("1.0.0", "--output", str(self.root / "source-link" / "notes.md"), success=False)
        self.assertIn("ignored, untracked", result.stderr)
        self.assertFalse((self.repo / "notes.md").exists())

    def test_shallow_repository_is_rejected(self):
        self.tag("0.9.0")
        self.commit("Newest commit")
        self.tag("1.0.0")
        shallow = self.root / "shallow"
        self.git("clone", "-q", "--depth", "1", self.repo.as_uri(), str(shallow))
        self.repo = shallow
        result = self.run_script("1.0.0", success=False)
        self.assertIn("complete Git history", result.stderr)

    def test_commit_subjects_are_literal_escaped_text(self):
        self.commit('Fix [link](https://example.invalid) *bold* <script> & `code` $(touch NEVER)')
        self.tag("1.0.0")
        self.run_script("1.0.0")
        notes = self.notes()
        self.assertIn(r"\[link\]\(https://example.invalid\)", notes)
        self.assertIn(r"\*bold\* &lt;script&gt; &amp; \`code\`", notes)
        self.assertIn(r"$\(touch NEVER\)", notes)
        self.assertFalse((self.repo / "NEVER").exists())

    def test_help_does_not_require_a_git_repository(self):
        detached = self.root / "detached"
        detached.mkdir()
        shutil.copyfile(self.repo / "generate-release-notes.sh", detached / "generate-release-notes.sh")
        self.repo = detached
        result = self.run_script("--help")
        self.assertIn("numerically highest lower", result.stdout)
        self.assertIn("never overwritten", result.stdout)
        self.assertIn("ignored/untracked", result.stdout)


unittest.main(verbosity=2)
PY
