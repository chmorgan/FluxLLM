#!/bin/bash
# Stage or publish verified FluxLLM artifacts through the GitHub CLI.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile


REPO = "chmorgan/fluxllm"
API = "repos/" + REPO
SCRIPT_DIR = Path(sys.argv.pop(1))


class ReleaseError(Exception):
    pass


def run(*args, capture=True):
    env = dict(os.environ, GH_HOST="github.com", GH_PROMPT_DISABLED="1")
    result = subprocess.run([str(arg) for arg in args], cwd=SCRIPT_DIR, env=env,
                            text=True, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        detail = (result.stderr or result.stdout or "").strip()
        raise ReleaseError(f"{args[0]} failed (exit {result.returncode})" +
                           (f": {detail}" if detail else "."))
    return result.stdout


def gh_json(*args):
    try:
        return json.loads(run("gh", *args))
    except json.JSONDecodeError as error:
        raise ReleaseError("GitHub CLI returned invalid JSON.") from error


def remote_commit(tag):
    obj = gh_json("api", f"{API}/git/ref/tags/{tag}")["object"]
    for _ in range(16):
        sha = obj.get("sha", "")
        if not re.fullmatch(r"[0-9a-fA-F]{40}", sha):
            raise ReleaseError("Remote tag contains an invalid Git object ID.")
        if obj.get("type") == "commit":
            return sha.lower()
        if obj.get("type") != "tag":
            raise ReleaseError("Remote tag does not point to a commit.")
        obj = gh_json("api", f"{API}/git/tags/{sha}")["object"]
    raise ReleaseError("Remote tag has too many nested annotations.")


def check_tag(tag, commit):
    local = run("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}").strip()
    if local != commit or remote_commit(tag) != commit:
        raise ReleaseError("Local and GitHub tags must still point to the packaged commit. "
                           "Push the correct tag; never move an existing release tag.")


def find_release(tag):
    pages = gh_json("api", "--paginate", "--slurp", f"{API}/releases")
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ReleaseError("GitHub returned an unexpected release list.")
    matches = [release for page in pages for release in page if release.get("tag_name") == tag]
    if len(matches) > 1:
        raise ReleaseError("Multiple GitHub releases use this tag; resolve them first.")
    return matches[0] if matches else None


def require_draft(release, tag, assets):
    if not release or release.get("tag_name") != tag or release.get("draft") is not True:
        raise ReleaseError("Refusing to modify a published release. Use a new version for changes.")
    if type(release.get("id")) is not int:
        raise ReleaseError("GitHub returned an invalid release ID.")
    names = [asset["name"] for asset in release.get("assets", [])]
    if len(names) != len(set(names)) or set(names) - set(assets):
        raise ReleaseError("Draft contains unexpected or duplicate assets; review them on GitHub first.")
    return release


def refresh_draft(release, tag, assets):
    return require_draft(gh_json("api", f"{API}/releases/{release['id']}"), tag, assets)


def regular_file(path):
    if path.is_symlink():
        raise ReleaseError(f"Expected a regular file, not a symlink: {path}")
    if not path.exists():
        raise ReleaseError(f"Required file is missing: {path}")
    if not path.is_file():
        raise ReleaseError(f"Expected a regular file: {path}")


def digest(path):
    regular_file(path)
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.digest()


def main():
    parser = argparse.ArgumentParser(
        prog="./publish-release.sh",
        description="Create or update a verified draft prerelease for chmorgan/fluxllm.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Notes:\n"
               "  - Reads RELEASE_DIR/release-notes.md; generates it if missing.\n"
               "  - Preserves your edits to existing release notes.\n"
               "  - Uploads only the ZIP, SHA256SUMS, and release-info.txt.\n"
               "  - Verifies uploaded files before publishing.\n"
               "  - Never modifies published releases.\n"
               "  - Requires authenticated gh, Python 3.9+, and macOS verification tools.")
    parser.add_argument("tag", metavar="TAG", help="existing plain MAJOR.MINOR.PATCH tag, without v")
    parser.add_argument("--release-dir", metavar="DIR", help="default: .build/releases/TAG")
    parser.add_argument("--publish", action="store_true", help="publish after staging and verifying the draft")
    parser.add_argument("--stable", action="store_true", help="mark as stable (default: prerelease)")
    args = parser.parse_args()
    tag = args.tag
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ReleaseError("Tag must be plain MAJOR.MINOR.PATCH, without a v prefix or suffix.")
    repo_dir = Path(run("git", "rev-parse", "--show-toplevel").strip())
    commit = run("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}").strip()
    release_dir = Path(args.release_dir).resolve() if args.release_dir else repo_dir / ".build/releases" / tag
    if not release_dir.exists():
        package_command = ["./package-release.sh", tag]
        if args.release_dir:
            package_command += ["--output-dir", str(release_dir)]
        raise ReleaseError(
            f"Release directory does not exist: {release_dir}\n"
            f"Package the release first. From {repo_dir}, run:\n"
            f"  {shlex.join(package_command)}\n"
            "Retry publishing after packaging reports Release ready.")
    if not release_dir.is_dir():
        raise ReleaseError(f"Release path is not a directory: {release_dir}")
    assets = [f"FluxLLM-{tag}.zip", "SHA256SUMS", "release-info.txt"]
    notes = release_dir / "release-notes.md"
    prerelease = "--prerelease=" + ("false" if args.stable else "true")

    # Upload a fixed snapshot of precisely the files that passed verification.
    with tempfile.TemporaryDirectory(prefix="fluxllm-publish-") as temporary:
        snapshot = Path(temporary) / "verified"
        snapshot.mkdir()
        for name in assets:
            regular_file(release_dir / name)
            shutil.copyfile(release_dir / name, snapshot / name)
        print(f"Verifying FluxLLM {tag} before upload…", flush=True)
        run("bash", repo_dir / "verify-release.sh", tag, "--release-dir", snapshot, capture=False)
        if not notes.exists() and not notes.is_symlink():
            run("bash", repo_dir / "generate-release-notes.sh", tag, "--output", notes, capture=False)
        regular_file(notes)
        if not notes.read_text(encoding="utf-8").strip():
            raise ReleaseError("Release notes are empty. Edit release-notes.md before publishing.")
        shutil.copyfile(notes, snapshot / notes.name)

        check_tag(tag, commit)
        release = find_release(tag)
        metadata = ["--repo", REPO, "--title", f"FluxLLM {tag}", prerelease,
                    "--notes-file", str(snapshot / notes.name)]
        if release is None:
            print("Creating a draft release…", flush=True)
            run("gh", "release", "create", tag, *[snapshot / name for name in assets],
                "--verify-tag", "--draft", *metadata)
            release = require_draft(find_release(tag), tag, assets)
        else:
            release = require_draft(release, tag, assets)
            refresh_draft(release, tag, assets)
            print("Updating the existing draft release…", flush=True)
            run("gh", "release", "upload", tag, *[snapshot / name for name in assets],
                "--repo", REPO, "--clobber")
            refresh_draft(release, tag, assets)
            run("gh", "release", "edit", tag, *metadata)

        # Compare all uploaded assets, including provenance and checksums, to the
        # verified snapshot. A failed transfer leaves a draft for a safe retry.
        refresh_draft(release, tag, assets)
        downloaded = Path(temporary) / "downloaded"
        downloaded.mkdir()
        patterns = [part for name in assets for part in ("--pattern", name)]
        run("gh", "release", "download", tag, "--repo", REPO, "--dir", downloaded, *patterns)
        for name in assets:
            if digest(downloaded / name) != digest(snapshot / name):
                raise ReleaseError(f"Uploaded asset differs from the verified local file: {name}. "
                                   "The release remains a draft; retry after investigating.")
        check_tag(tag, commit)
        refresh_draft(release, tag, assets)
        if args.publish:
            run("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--verify-tag", prerelease)
        info = gh_json("release", "view", tag, "--repo", REPO, "--json", "url")
        print(("Published" if args.publish else "Draft ready") + f": {info['url']}")
        if not args.publish:
            print(f"Review the draft, then run ./publish-release.sh {tag} --publish" +
                  (" --stable" if args.stable else "") +
                  (" with the same --release-dir." if args.release_dir else "."))


try:
    main()
except (ReleaseError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
    print(f"Error: {error}", file=sys.stderr)
    sys.exit(1)
PY
