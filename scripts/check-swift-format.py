#!/usr/bin/env python3
"""Lint a read-only Swift snapshot with the configuration from the same snapshot.

--staged checks changed index blobs, including partially staged files. Changing
the staged configuration rechecks every indexed Swift file. --all checks the
whole index (the CI checkout); --worktree also includes unignored new files and
uses current file contents, for the development build script.
"""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tempfile


CONFIGURATION = ".swift-format"
REGULAR_MODES = {"100644", "100755"}


class CheckError(Exception):
    """The requested snapshot cannot be checked safely."""


def git(root, *arguments, input=None):
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    try:
        result = subprocess.run(
            ["git", *arguments], cwd=root, env=environment, input=input,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
    except OSError as error:
        raise CheckError(f"Cannot execute Git: {error}") from error
    if result.returncode:
        raise CheckError(result.stderr.decode("utf-8", "replace").strip() or "Git command failed")
    return result.stdout


def repository_root():
    output = git(None, "rev-parse", "--show-toplevel")
    if not output.endswith(b"\n"):
        raise CheckError("Git did not return a repository root")
    return Path(os.fsdecode(output[:-1]))


def swift_path(path):
    return path.startswith(("Sources/", "Tests/")) and path.endswith(".swift")


def relevant_path(path):
    return path == CONFIGURATION or swift_path(path)


def nul_paths(output):
    if output and not output.endswith(b"\0"):
        raise CheckError("Git returned an incomplete path list")
    return [os.fsdecode(path) for path in output.split(b"\0") if path]


def index_entries(root):
    entries = {}
    for record in git(root, "ls-files", "--stage", "-z").split(b"\0"):
        if not record:
            continue
        metadata, separator, raw_path = record.partition(b"\t")
        if not separator:
            raise CheckError("Git returned an invalid index entry")
        mode, object_id, stage = metadata.decode("ascii").split()
        path = os.fsdecode(raw_path)
        if not relevant_path(path):
            continue
        if stage != "0":
            raise CheckError(f"Unmerged formatting input: {path!r}")
        if mode not in REGULAR_MODES:
            raise CheckError(f"Formatting input must be a regular file: {path!r} (mode {mode})")
        entries[path] = object_id
    return entries


def read_blobs(root, entries, paths):
    object_ids = list(dict.fromkeys(entries[path] for path in paths))
    output = git(root, "cat-file", "--batch", input="".join(oid + "\n" for oid in object_ids).encode("ascii"))
    blobs = {}
    offset = 0
    for object_id in object_ids:
        end = output.find(b"\n", offset)
        header = output[offset:end].split() if end != -1 else []
        if len(header) != 3 or header[:2] != [object_id.encode("ascii"), b"blob"]:
            raise CheckError(f"Cannot read indexed blob {object_id}")
        try:
            size = int(header[2])
        except ValueError as error:
            raise CheckError("Git returned an invalid blob size") from error
        offset = end + 1
        if size < 0 or output[offset + size:offset + size + 1] != b"\n":
            raise CheckError("Git returned an incomplete blob")
        blobs[object_id] = output[offset:offset + size]
        offset += size + 1
    if offset != len(output):
        raise CheckError("Git returned unexpected blob data")
    return {path: blobs[entries[path]] for path in paths}


def read_worktree_file(root, path, *, allow_missing=False):
    relative = PurePosixPath(path)
    if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
        raise CheckError(f"Invalid formatting input path: {path!r}")
    current = root
    for index, part in enumerate(relative.parts):
        current = current / part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            if allow_missing:
                return None
            raise CheckError(f"Missing formatting input: {path!r}") from None
        if stat.S_ISLNK(mode):
            raise CheckError(f"Formatting input cannot traverse a symlink: {path!r}")
        expected = stat.S_ISREG(mode) if index == len(relative.parts) - 1 else stat.S_ISDIR(mode)
        if not expected:
            raise CheckError(f"Formatting input is not a regular file: {path!r}")
    return current.read_bytes()


def snapshot(root, mode):
    entries = index_entries(root)
    if mode == "worktree":
        paths = {path for path in entries if swift_path(path)}
        paths.update(path for path in nul_paths(git(root, "ls-files", "--others", "--exclude-standard", "-z"))
                     if swift_path(path))
        contents = {CONFIGURATION: read_worktree_file(root, CONFIGURATION)}
        for path in sorted(paths):
            content = read_worktree_file(root, path, allow_missing=True)
            if content is not None:
                contents[path] = content
        return contents
    if mode == "staged":
        changed = set(nul_paths(git(root, "diff", "--cached", "--name-only", "--no-renames",
                                   "--no-ext-diff", "--no-textconv", "-z")))
        paths = {path for path in changed if swift_path(path) and path in entries}
        if CONFIGURATION in changed:
            paths = {path for path in entries if swift_path(path)}
        elif not paths:
            return {}
    else:
        paths = {path for path in entries if swift_path(path)}
    if CONFIGURATION not in entries:
        raise CheckError("The index must contain a regular .swift-format configuration")
    return read_blobs(root, entries, sorted(paths | {CONFIGURATION}))


def check(contents):
    if not contents:
        print("No staged Swift or formatter configuration changes.")
        return 0
    try:
        configuration = json.loads(contents[CONFIGURATION])
    except (UnicodeDecodeError, ValueError) as error:
        raise CheckError(f"Invalid .swift-format JSON: {error}") from error
    if not isinstance(configuration, dict):
        raise CheckError(".swift-format must contain a JSON object")
    paths = sorted(path for path in contents if swift_path(path))
    # An empty Swift tree still validates its configuration and tool availability.
    with tempfile.TemporaryDirectory(prefix="fluxllm-swift-format-") as temporary:
        root = Path(temporary)
        for path, content in contents.items():
            destination = root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(content)
        arguments = ["xcrun", "swift-format", "lint", "--strict", "--configuration", str(root / CONFIGURATION)]
        if not paths:
            arguments.extend(["--assume-filename", "Empty.swift", "-"])
        print(f"Checking {len(paths)} Swift file(s).", flush=True)
        try:
            result = subprocess.run(arguments + paths, cwd=root, input=b"" if not paths else None)
        except OSError as error:
            raise CheckError(f"Cannot execute xcrun swift-format: {error}") from error
    if result.returncode:
        print("Swift formatting check failed; format the affected files and stage the intended changes.",
              file=sys.stderr)
        return 1
    print("Swift formatting OK.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    for mode in ("staged", "all", "worktree"):
        modes.add_argument("--" + mode, action="store_const", const=mode, dest="mode")
    arguments = parser.parse_args()
    try:
        return check(snapshot(repository_root(), arguments.mode))
    except (CheckError, OSError, ValueError) as error:
        print(f"Swift formatting check could not run: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
