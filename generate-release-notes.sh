#!/bin/bash
# Generate an editable release-notes draft using only local Git history.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import html
import os
from pathlib import Path
import re
import subprocess
import sys


SCRIPT_DIR = Path(sys.argv.pop(1))
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
PROJECT_URL = "https://github.com/chmorgan/fluxllm"


def fail(message):
    raise SystemExit("Error: " + message)


def git(*args, cwd=SCRIPT_DIR, check=True):
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if check and result.returncode:
        fail(result.stderr.strip() or "Git command failed: " + " ".join(args))
    return result


def version(tag):
    if not VERSION.fullmatch(tag):
        fail("Tag must be plain MAJOR.MINOR.PATCH without leading zeroes or a v prefix: " + tag)
    return tuple(int(part) for part in tag.split("."))


def tag_commit(tag):
    result = git("rev-parse", "--verify", "refs/tags/" + tag + "^{commit}", check=False)
    if result.returncode:
        fail("Release tag does not exist or does not point to a commit: " + tag)
    return result.stdout.strip()


def is_ancestor(older, newer):
    result = git("merge-base", "--is-ancestor", older, newer, check=False)
    if result.returncode not in (0, 1):
        fail(result.stderr.strip() or "Could not check tag ancestry.")
    return result.returncode == 0


def markdown_text(subject):
    # Commit subjects are data, including shell syntax and Markdown/HTML.
    subject = "".join(character if character.isprintable() else " " for character in subject)
    subject = html.escape(subject, quote=False)
    return re.sub(r"([\\`*_{}\[\]()#!|~])", r"\\\1", subject)


def check_output(output):
    if os.path.lexists(output):
        fail("Release notes already exist; edit that file or choose another --output: " + str(output))
    output = output.resolve()
    ancestor = output.parent
    while not ancestor.exists():
        ancestor = ancestor.parent
    result = git("rev-parse", "--show-toplevel", cwd=ancestor, check=False)
    if result.returncode == 0:
        repository = Path(result.stdout.strip()).resolve()
        relative = str(output.relative_to(repository))
        tracked = git("ls-files", "--error-unmatch", "--", relative, cwd=repository, check=False)
        if tracked.returncode == 0:
            fail("Release notes must not use a tracked path: " + str(output))
        ignored = git("check-ignore", "--quiet", "--", relative, cwd=repository, check=False)
        if ignored.returncode != 0:
            fail("Release notes inside a repository must use an ignored, untracked path; use .build/releases/TAG/release-notes.md or an external --output.")
    return output


parser = argparse.ArgumentParser(
    prog="./generate-release-notes.sh",
    description="Generate an editable, ignored/untracked release-notes draft from local Git history. No build or network access is needed.",
    epilog="Without --previous-tag, select the numerically highest lower MAJOR.MINOR.PATCH tag whose commit is an ancestor of TAG (including the same commit). If none exists, include all history through TAG. Shallow repositories are rejected. Existing files are never overwritten. Edit the generated notes before publishing; do not commit them.",
)
parser.add_argument("tag", metavar="TAG", help="existing plain MAJOR.MINOR.PATCH release tag")
parser.add_argument("--previous-tag", metavar="TAG", help="use this lower-version ancestor tag instead of automatic selection")
parser.add_argument("--output", metavar="FILE", help="draft path (default: REPOSITORY/.build/releases/TAG/release-notes.md); repository paths must be ignored and untracked")
parser.add_argument("--check-output", action="store_true", help="validate tags, history, and destination without creating directories or notes")
args = parser.parse_args()

target_version = version(args.tag)
repo = Path(git("rev-parse", "--show-toplevel").stdout.strip()).resolve()
if git("rev-parse", "--is-shallow-repository").stdout.strip() != "false":
    fail("A complete Git history is required; fetch the full history and release tags before generating notes.")
target_commit = tag_commit(args.tag)
previous_tag = args.previous_tag
previous_commit = None
if previous_tag is not None:
    if version(previous_tag) >= target_version:
        fail("--previous-tag must have a lower version than the release tag.")
    previous_commit = tag_commit(previous_tag)
    if not is_ancestor(previous_commit, target_commit):
        fail("--previous-tag must be an ancestor of the release tag.")
else:
    candidates = []
    for tag in git("tag", "--list").stdout.splitlines():
        if VERSION.fullmatch(tag) and version(tag) < target_version:
            candidates.append(tag)
    for tag in sorted(candidates, key=version, reverse=True):
        result = git("rev-parse", "--verify", "refs/tags/" + tag + "^{commit}", check=False)
        if result.returncode:
            continue  # Tags on trees or blobs cannot be release ancestors.
        commit = result.stdout.strip()
        if is_ancestor(commit, target_commit):
            previous_tag, previous_commit = tag, commit
            break

output = check_output(Path(args.output) if args.output else repo / ".build" / "releases" / args.tag / "release-notes.md")
if args.check_output:
    print("Release notes destination is valid: " + str(output))
    raise SystemExit(0)
revision = previous_commit + ".." + target_commit if previous_commit else target_commit
log = git("log", "--reverse", "--format=%h%x00%s%x00", revision, "--").stdout
records = log.split("\0")
changes = []
for index in range(0, len(records) - 1, 2):
    commit, subject = records[index].strip(), records[index + 1]
    changes.append("- " + markdown_text(subject) + " (`" + commit + "`)")

lines = [
    "# FluxLLM " + args.tag,
    "",
    "For Apple Silicon Macs running macOS 15 or later.",
    "",
    "<!-- Generated draft: edit these notes before publishing. This file is intentionally untracked. -->",
    "",
    "## Changes",
    "",
]
lines.extend(changes or ["- No commits since " + previous_tag + "."])
lines.extend(["", "[Full changelog](" + PROJECT_URL + "/compare/" + previous_tag + "..." + args.tag + ")" if previous_tag else "[Initial release history](" + PROJECT_URL + "/commits/" + args.tag + ")", ""])
output.parent.mkdir(parents=True, exist_ok=True)
try:
    # Exclusive creation preserves an editor's notes even if another process
    # created the destination after the initial existence check.
    with output.open("x", encoding="utf-8") as notes:
        notes.write("\n".join(lines))
except FileExistsError:
    fail("Release notes already exist; they were not overwritten: " + str(output))
print("Created editable release notes: " + str(output))
print("History: " + (previous_tag + ".." + args.tag if previous_tag else "initial history through " + args.tag))
PY
