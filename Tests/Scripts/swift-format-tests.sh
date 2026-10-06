#!/bin/bash
# Exercise the real checker and hooks in disposable repositories; no Xcode/build.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
exec python3 - "$REPO_ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE_ROOT = Path(sys.argv.pop(1))
MOCK = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if args[:3] != ["swift-format", "lint", "--strict"]:
    sys.exit("Unexpected formatter invocation: " + repr(args))
if args[3] != "--configuration":
    sys.exit("Explicit configuration is required")
configuration = json.loads(Path(args[4]).read_bytes())
paths = args[5:]
if paths == ["--assume-filename", "Empty.swift", "-"]:
    paths = []
    if sys.stdin.buffer.read() != b"":
        sys.exit("Expected empty configuration-validation input")
files = {path: Path(path).read_text() for path in paths}
with open(os.environ["FORMAT_TEST_LOG"], "a") as log:
    log.write(json.dumps({"configuration": configuration, "files": files}) + "\n")
if configuration.get("reject_all") or any("BAD_FORMAT" in content for content in files.values()):
    sys.exit("Fixture formatting violation")
'''


class SwiftFormattingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="fluxllm-format-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / "source repo"
        self.repo.mkdir()
        self.mockbin = self.root / "mockbin"
        self.mockbin.mkdir()
        (self.mockbin / "xcrun").write_text(MOCK)
        (self.mockbin / "xcrun").chmod(0o755)
        self.log = self.root / "formatter-calls.jsonl"
        self.env = dict(os.environ, PATH=str(self.mockbin) + os.pathsep + os.environ["PATH"],
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_OPTIONAL_LOCKS="0",
                        FORMAT_TEST_LOG=str(self.log))
        # Keep outer repository/index variables out of the disposable repositories.
        for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
            self.env.pop(key, None)
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Formatting Fixture")
        self.git("config", "user.email", "format@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.autocrlf", "false")
        for relative in ("scripts/check-swift-format.py", "scripts/install-git-hooks.sh", ".githooks/pre-commit"):
            destination = self.repo / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE_ROOT / relative, destination)
        self.write(".swift-format", '{"reject_all": false}\n')
        self.write("Sources/Good.swift", "let good = 1\n")
        self.write("Tests/Good Tests.swift", "let test = 1\n")
        self.git("add", ".")

    def command(self, arguments, *, cwd=None, input=None, env=None):
        return subprocess.run(arguments, cwd=cwd or self.repo, env=env or self.env, input=input,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def git(self, *arguments, input=None, cwd=None):
        result = self.command(["git", *arguments], input=input, cwd=cwd)
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
        return result.stdout

    def write(self, relative, contents):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    def commit_initial(self):
        self.git("commit", "-m", "Initial fixture")

    def check(self, mode="staged", *, env=None, cwd=None):
        return self.command([sys.executable, str(self.repo / "scripts/check-swift-format.py"), "--" + mode],
                            env=env, cwd=cwd)

    def install(self, *, cwd=None):
        directory = cwd or self.repo
        return self.command(["/bin/sh", str(directory / "scripts/install-git-hooks.sh")], cwd=directory)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_passes(self, result):
        self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))

    def assert_rejected(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout.decode("utf-8", "replace"))
        self.assertIn(message, result.stderr.decode("utf-8", "replace"))

    def state(self):
        paths = {str(path.relative_to(self.repo)): (path.read_bytes(), path.stat().st_mode)
                 for path in self.repo.rglob("*") if path.is_file() and ".git" not in path.relative_to(self.repo).parts}
        return (self.repo / ".git/index").read_bytes(), paths

    def test_initial_commit_checks_every_staged_swift_file(self):
        self.assert_passes(self.check())
        self.assertEqual(set(self.calls()[0]["files"]), {"Sources/Good.swift", "Tests/Good Tests.swift"})

    def test_rejects_bad_staged_bytes_even_when_worktree_is_fixed_and_changes_nothing(self):
        self.commit_initial()
        self.write("Sources/Good.swift", "BAD_FORMAT staged\n")
        self.git("add", "Sources/Good.swift")
        self.write("Sources/Good.swift", "let fixed = 2\n")
        before = self.state()
        self.assert_rejected(self.check(), "formatting check failed")
        self.assertEqual(self.calls()[0]["files"], {"Sources/Good.swift": "BAD_FORMAT staged\n"})
        self.assertEqual(self.state(), before)

    def test_accepts_good_staged_bytes_with_bad_unstaged_edits(self):
        self.commit_initial()
        self.write("Sources/Good.swift", "let staged = 2\n")
        self.git("add", "Sources/Good.swift")
        self.write("Sources/Good.swift", "BAD_FORMAT unstaged\n")
        before = self.state()
        self.assert_passes(self.check())
        self.assertEqual(self.calls()[0]["files"], {"Sources/Good.swift": "let staged = 2\n"})
        self.assertEqual(self.state(), before)

    def test_staged_configuration_rechecks_all_indexed_files_using_staged_config(self):
        self.commit_initial()
        self.write(".swift-format", '{"reject_all": true}\n')
        self.git("add", ".swift-format")
        self.write(".swift-format", '{"reject_all": false}\n')
        self.assert_rejected(self.check(), "formatting check failed")
        self.assertTrue(self.calls()[0]["configuration"]["reject_all"])
        self.assertEqual(set(self.calls()[0]["files"]), {"Sources/Good.swift", "Tests/Good Tests.swift"})

    def test_all_checks_index_with_no_staged_changes_and_ignores_worktree_edits(self):
        self.commit_initial()
        self.write("Sources/Good.swift", "BAD_FORMAT unstaged\n")
        self.write("Sources/New.swift", "BAD_FORMAT untracked\n")
        self.write(".swift-format", '{"reject_all": true}\n')
        self.assert_passes(self.check("all"))
        self.assertEqual(self.calls()[0]["configuration"], {"reject_all": False})
        self.assertEqual(self.calls()[0]["files"]["Sources/Good.swift"], "let good = 1\n")
        self.assertNotIn("Sources/New.swift", self.calls()[0]["files"])

    def test_worktree_checks_new_files_and_current_bytes_but_not_ignored_files(self):
        self.commit_initial()
        self.write(".gitignore", "Sources/Ignored.swift\n")
        self.write("Sources/Ignored.swift", "BAD_FORMAT ignored\n")
        self.write("Sources/New.swift", "BAD_FORMAT new\n")
        self.write("Sources/Good.swift", "let current = 2\n")
        (self.repo / "Tests/Good Tests.swift").unlink()
        before = self.state()
        self.assert_rejected(self.check("worktree"), "formatting check failed")
        self.assertEqual(self.calls()[0]["files"], {"Sources/Good.swift": "let current = 2\n",
                                                  "Sources/New.swift": "BAD_FORMAT new\n"})
        self.assertEqual(self.state(), before)

    def test_worktree_uses_current_configuration(self):
        self.write(".swift-format", '{"reject_all": true}\n')
        self.assert_rejected(self.check("worktree"), "formatting check failed")
        self.assertTrue(self.calls()[0]["configuration"]["reject_all"])

    def test_paths_with_spaces_tabs_and_newlines_survive_renames_and_deletions(self):
        self.commit_initial()
        self.git("rm", "Sources/Good.swift")
        new_name = "Sources/new name\twith\nnewline.swift"
        self.write(new_name, "BAD_FORMAT renamed\n")
        self.git("add", "--", new_name)
        self.assert_rejected(self.check(), "formatting check failed")
        self.assertEqual(self.calls()[0]["files"], {new_name: "BAD_FORMAT renamed\n"})

    def test_only_deletions_or_unrelated_changes_skip_formatter(self):
        self.commit_initial()
        self.git("rm", "Sources/Good.swift")
        self.write("README.md", "Documentation\n")
        self.git("add", "README.md")
        self.assert_passes(self.check())
        self.assertEqual(self.calls(), [])

    def test_deleted_and_malformed_configuration_fail_closed(self):
        self.commit_initial()
        self.git("rm", ".swift-format")
        self.assert_rejected(self.check(), "index must contain")
        self.write(".swift-format", "invalid JSON\n")
        self.git("add", ".swift-format")
        self.assert_rejected(self.check(), "Invalid .swift-format JSON")
        self.assertEqual(self.calls(), [])

    def test_configuration_with_no_swift_files_still_checks_tool(self):
        self.git("rm", "-f", "Sources/Good.swift", "Tests/Good Tests.swift")
        self.assert_passes(self.check())
        self.assertEqual(self.calls()[0]["files"], {})

    def test_missing_formatter_fails_closed(self):
        isolated = self.root / "isolated-tools"
        isolated.mkdir()
        (isolated / "git").symlink_to(shutil.which("git"))
        environment = dict(self.env, PATH=str(isolated))
        self.assert_rejected(self.check(env=environment), "Cannot execute xcrun swift-format")
        self.assertEqual(self.calls(), [])

    def test_unmerged_source_and_configuration_fail_before_formatter(self):
        self.commit_initial()
        object_id = self.git("hash-object", "-w", "--stdin", input=b"let conflict = 1\n").strip().decode()
        for path in ("Sources/Good.swift", ".swift-format"):
            with self.subTest(path=path):
                self.git("update-index", "--force-remove", "--", path)
                entry = f"100644 {object_id} 1\t{path}\n100644 {object_id} 2\t{path}\n"
                self.git("update-index", "--index-info", input=entry.encode())
                self.assert_rejected(self.check(), "Unmerged formatting input")
                self.git("update-index", "--force-remove", "--", path)
        self.assertEqual(self.calls(), [])

    def test_indexed_symlink_source_and_config_are_rejected(self):
        self.commit_initial()
        (self.repo / "Sources/Link.swift").symlink_to("Good.swift")
        self.git("add", "Sources/Link.swift")
        self.assert_rejected(self.check(), "must be a regular file")
        self.git("rm", "-f", "Sources/Link.swift")
        (self.repo / ".swift-format").unlink()
        (self.repo / ".swift-format").symlink_to("Sources/Good.swift")
        self.git("add", ".swift-format")
        self.assert_rejected(self.check(), "must be a regular file")
        self.assertEqual(self.calls(), [])

    def test_worktree_symlink_ancestor_and_untracked_symlinks_are_rejected(self):
        self.commit_initial()
        (self.repo / "Sources/Link.swift").symlink_to("Good.swift")
        self.assert_rejected(self.check("worktree"), "cannot traverse a symlink")
        (self.repo / "Sources/Link.swift").unlink()
        (self.repo / "Sources").rename(self.root / "external-sources")
        (self.repo / "Sources").symlink_to(self.root / "external-sources", target_is_directory=True)
        self.assert_rejected(self.check("worktree"), "cannot traverse a symlink")
        self.assertEqual(self.calls(), [])

    def test_missing_indexed_blob_fails_closed(self):
        self.git("update-index", "--cacheinfo", "100644," + "1" * 40 + ",Sources/Good.swift")
        self.assert_rejected(self.check("all"), "Cannot read indexed blob")
        self.assertEqual(self.calls(), [])

    def test_checker_can_run_from_nested_directory(self):
        self.assert_passes(self.check(cwd=self.repo / "Sources"))
        self.assertIn("Sources/Good.swift", self.calls()[0]["files"])

    def test_install_is_idempotent_and_preserves_other_hooks_and_git_config(self):
        hooks = self.repo / ".git/hooks"
        other = hooks / "post-commit"
        other.write_bytes(b"existing unrelated hook\n")
        configuration = (self.repo / ".git/config").read_bytes()
        self.assert_passes(self.install())
        hook = hooks / "pre-commit"
        original = (hook.read_bytes(), hook.stat().st_mode, hook.stat().st_mtime_ns)
        self.assert_passes(self.install())
        self.assertEqual((hook.read_bytes(), hook.stat().st_mode, hook.stat().st_mtime_ns), original)
        self.assertEqual(other.read_bytes(), b"existing unrelated hook\n")
        self.assertEqual((self.repo / ".git/config").read_bytes(), configuration)

    def test_install_refuses_existing_hook_symlink_and_custom_hooks_path(self):
        hook = self.repo / ".git/hooks/pre-commit"
        hook.write_bytes(b"#!/bin/sh\necho user hook\n")
        original = hook.read_bytes()
        self.assert_rejected(self.install(), "unowned pre-commit")
        self.assertEqual(hook.read_bytes(), original)
        hook.unlink()
        target = self.root / "external-hook"
        target.write_bytes(original)
        hook.symlink_to(target)
        self.assert_rejected(self.install(), "unowned pre-commit")
        self.assertTrue(hook.is_symlink())
        self.assertEqual(target.read_bytes(), original)
        hook.unlink()
        self.git("config", "core.hooksPath", "custom hooks")
        configuration = (self.repo / ".git/config").read_bytes()
        self.assert_rejected(self.install(), "custom core.hooksPath")
        self.assertEqual((self.repo / ".git/config").read_bytes(), configuration)
        self.assertFalse((self.repo / "custom hooks").exists())
        self.assertFalse(hook.exists())

    def test_installed_hook_rejects_actual_commit_using_staged_bytes(self):
        self.commit_initial()
        self.assert_passes(self.install())
        head = self.git("rev-parse", "HEAD")
        self.write("Sources/Good.swift", "BAD_FORMAT staged\n")
        self.git("add", "Sources/Good.swift")
        self.write("Sources/Good.swift", "let unstagedFix = 2\n")
        staged = self.git("show", ":Sources/Good.swift")
        result = self.command(["git", "commit", "-m", "Must be rejected"])
        self.assert_rejected(result, "formatting check failed")
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.git("show", ":Sources/Good.swift"), staged)
        self.assertEqual((self.repo / "Sources/Good.swift").read_text(), "let unstagedFix = 2\n")
        self.git("add", "Sources/Good.swift")
        self.write("Sources/Good.swift", "BAD_FORMAT later unstaged edit\n")
        self.git("commit", "-m", "Valid staged bytes")
        self.assertEqual(self.git("show", "HEAD:Sources/Good.swift"), b"let unstagedFix = 2\n")
        self.assertEqual((self.repo / "Sources/Good.swift").read_text(), "BAD_FORMAT later unstaged edit\n")

    def test_linked_worktree_installs_in_common_hooks_and_checks_its_own_index(self):
        self.commit_initial()
        linked = self.root / "linked worktree"
        self.git("worktree", "add", "-b", "linked", str(linked))
        self.assert_passes(self.install(cwd=linked))
        self.assertTrue((self.repo / ".git/hooks/pre-commit").is_file())
        (linked / "Sources/Good.swift").write_text("BAD_FORMAT linked\n")
        self.git("add", "Sources/Good.swift", cwd=linked)
        head = self.git("rev-parse", "HEAD", cwd=linked)
        result = self.command(["git", "commit", "-m", "Rejected linked change"], cwd=linked)
        self.assert_rejected(result, "formatting check failed")
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=linked), head)
        self.assertEqual(self.git("show", ":Sources/Good.swift"), b"let good = 1\n")


unittest.main(verbosity=2)
PY
