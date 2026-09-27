#!/bin/bash
# Stage or publish verified FluxLLM artifacts through the GitHub CLI.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import hashlib
import importlib.util
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


def require_public_repository():
    repository = gh_json("api", API)
    if not isinstance(repository, dict) or repository.get("private") is not False:
        raise ReleaseError("Public Homebrew downloads require a public chmorgan/fluxllm repository. "
                           "Authenticated private-repository downloads are not configured.")


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
    if type(release.get("id")) is not int or release["id"] <= 0:
        raise ReleaseError("GitHub returned an invalid release ID.")
    names = [asset["name"] for asset in release.get("assets", [])]
    if len(names) != len(set(names)) or set(names) - set(assets):
        raise ReleaseError("Draft contains unexpected or duplicate assets; review them on GitHub first.")
    return release


def refresh_draft(release, tag, assets):
    refreshed = require_draft(gh_json("api", f"{API}/releases/{release['id']}"), tag, assets)
    if refreshed["id"] != release["id"]:
        raise ReleaseError("GitHub release identity changed; retry after investigating.")
    return refreshed


def published_fingerprint(release, tag, assets):
    if (not isinstance(release, dict) or release.get("tag_name") != tag or
            release.get("draft") is not False or type(release.get("prerelease")) is not bool):
        raise ReleaseError("Expected the published GitHub release and its actual release status.")
    if type(release.get("id")) is not int or release["id"] <= 0:
        raise ReleaseError("GitHub returned an invalid release ID.")
    items = release.get("assets")
    if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
        raise ReleaseError("GitHub returned invalid published asset metadata.")
    names = [item.get("name") for item in items]
    if any(not isinstance(name, str) for name in names) or sorted(names) != sorted(assets):
        raise ReleaseError("Published release must contain exactly the ZIP, SHA256SUMS, and release-info.txt.")
    identities = []
    for item in items:
        if (type(item.get("id")) is not int or item["id"] <= 0 or
                type(item.get("size")) is not int or item["size"] < 0 or
                item.get("state") != "uploaded"):
            raise ReleaseError("GitHub returned invalid published asset identity, size, or upload state.")
        checksum = item.get("digest")
        if checksum is not None and not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", str(checksum)):
            raise ReleaseError("GitHub returned an invalid published asset digest.")
        identities.append((item["name"], item["id"], item["size"], checksum, item.get("updated_at")))
    if len({item[1] for item in identities}) != len(identities):
        raise ReleaseError("GitHub returned duplicate published asset IDs.")
    return release["id"], release["prerelease"], sorted(identities)


def download_asset(asset, destination):
    # Address the checked asset ID, not the mutable release tag or asset name.
    env = dict(os.environ, GH_HOST="github.com", GH_PROMPT_DISABLED="1")
    with destination.open("xb") as output:
        result = subprocess.run(
            ["gh", "api", f"{API}/releases/assets/{asset['id']}",
             "--header", "Accept: application/octet-stream"],
            cwd=SCRIPT_DIR, env=env, stdout=output, stderr=subprocess.PIPE)
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ReleaseError(f"GitHub asset download failed: {asset['name']}" +
                           (f": {detail}" if detail else "."))
    if destination.stat().st_size != asset["size"]:
        raise ReleaseError(f"Downloaded asset size differs from GitHub metadata: {asset['name']}")
    if asset.get("digest") and digest(destination).hex() != asset["digest"].split(":", 1)[1].lower():
        raise ReleaseError(f"Downloaded asset checksum differs from GitHub metadata: {asset['name']}")


def verify_published_release(repo_dir, tag, commit, release, assets, downloaded, local=None):
    before = published_fingerprint(release, tag, assets)
    refreshed = gh_json("api", f"{API}/releases/{release['id']}")
    if published_fingerprint(refreshed, tag, assets) != before:
        raise ReleaseError("Published release changed before verification; retry after investigating.")
    downloaded.mkdir()
    print(f"Verifying published FluxLLM {tag}…", flush=True)
    for asset in refreshed["assets"]:
        download_asset(asset, downloaded / asset["name"])
    run("bash", repo_dir / "verify-release.sh", tag, "--release-dir", downloaded, capture=False)
    if local is not None:
        for name in assets:
            if digest(downloaded / name) != digest(local / name):
                raise ReleaseError(f"Published asset differs from the supplied local file: {name}. "
                                   "Published releases are never overwritten.")
    check_tag(tag, commit)
    final = gh_json("api", f"{API}/releases/{release['id']}")
    if published_fingerprint(final, tag, assets) != before:
        raise ReleaseError("Published release changed during verification; retry after investigating.")
    return final


def pending_tap_error(tag, error):
    retry = shlex.join(["./publish-release.sh", *sys.argv[1:]])
    return ReleaseError(f"FluxLLM {tag} is published, but the Homebrew tap update is pending.\n"
                        f"{error}\nRetry: {retry}")


def after_published_verification(repo_dir, tag, commit, snapshot, release):
    # Keep publication and tap updates separate: a failed Git push must never
    # replace, retract, or otherwise change an already verified release.
    try:
        require_public_repository()
        assets = [f"FluxLLM-{tag}.zip", "SHA256SUMS", "release-info.txt"]
        before = published_fingerprint(release, tag, assets)
        casks = snapshot.parent / "Casks"
        run("bash", repo_dir / "generate-release-casks.sh", tag,
            "--release-dir", snapshot, "--output-dir", casks, capture=False)
        check_tag(tag, commit)
        final = gh_json("api", f"{API}/releases/{release['id']}")
        if published_fingerprint(final, tag, assets) != before:
            raise ReleaseError("Published release changed during cask generation; investigate before retrying.")
        require_public_repository()
        # Load our sibling helper without creating __pycache__ in the checkout.
        sys.dont_write_bytecode = True
        spec = importlib.util.spec_from_file_location("release_cask_tap", repo_dir / "scripts/release_cask_tap.py")
        helper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(helper)
        helper.update_tap(repo_dir, tag, casks, stable=not final["prerelease"])
    except Exception as error:
        raise pending_tap_error(tag, error) from error


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
        description="Stage, publish, or verify a FluxLLM release on GitHub.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Notes:\n"
               "  - Reads RELEASE_DIR/release-notes.md; generates it if missing.\n"
               "  - Preserves your edits to existing release notes.\n"
               "  - Uploads only the ZIP, SHA256SUMS, and release-info.txt.\n"
               "  - Verifies uploaded files before publishing.\n"
               "  - Never modifies published releases.\n"
               "  - Reruns verify published assets without requiring local files or notes.\n"
               "  - Existing local files must match; partial release directories are rejected.\n"
               "  - --publish also commits and pushes casks to main; reruns finish pending updates.\n"
               "  - Newer stable releases advance the current cask; prereleases add only the exact version.\n"
               "  - Public GitHub downloads are required; drafts never update the tap.\n"
               "  - Requires authenticated gh, Python 3.9+, and macOS verification tools.")
    parser.add_argument("tag", metavar="TAG", help="existing plain MAJOR.MINOR.PATCH tag, without v")
    parser.add_argument("--release-dir", metavar="DIR", help="existing local artifacts to compare or upload (default: .build/releases/TAG)")
    parser.add_argument("--publish", action="store_true", help="publish a verified draft; safely resume an existing publication")
    parser.add_argument("--stable", action="store_true", help="use stable for drafts (default: prerelease); preserve published status")
    args = parser.parse_args()
    tag = args.tag
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ReleaseError("Tag must be plain MAJOR.MINOR.PATCH, without a v prefix or suffix.")
    repo_dir = Path(run("git", "rev-parse", "--show-toplevel").strip())
    commit = run("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}").strip()
    release_dir = Path(args.release_dir).expanduser().absolute() if args.release_dir else repo_dir / ".build/releases" / tag
    if release_dir.is_symlink():
        raise ReleaseError(f"Release directory must not be a symlink: {release_dir}")
    release_dir = release_dir.resolve()
    assets = [f"FluxLLM-{tag}.zip", "SHA256SUMS", "release-info.txt"]

    def missing_release_directory():
        package_command = ["./package-release.sh", tag]
        if args.release_dir:
            package_command += ["--output-dir", str(release_dir)]
        raise ReleaseError(
            f"Release directory does not exist: {release_dir}\n"
            f"Package the release first. From {repo_dir}, run:\n"
            f"  {shlex.join(package_command)}\n"
            "Retry publishing after packaging reports Release ready.")
    if release_dir.exists() and not release_dir.is_dir():
        raise ReleaseError(f"Release path is not a directory: {release_dir}")
    if args.release_dir and not release_dir.exists():
        missing_release_directory()
    if release_dir.exists():
        for name in assets:
            regular_file(release_dir / name)
    notes = release_dir / "release-notes.md"
    prerelease = "--prerelease=" + ("false" if args.stable else "true")

    # Upload a fixed snapshot of precisely the files that passed verification.
    with tempfile.TemporaryDirectory(prefix="fluxllm-publish-") as temporary:
        snapshot = Path(temporary) / "verified"
        snapshot.mkdir()
        local = None
        if release_dir.exists():
            for name in assets:
                shutil.copyfile(release_dir / name, snapshot / name)
            local = snapshot
        check_tag(tag, commit)
        release = find_release(tag)
        if release is not None and release.get("draft") is False:
            downloaded = Path(temporary) / "published"
            try:
                release = verify_published_release(repo_dir, tag, commit, release, assets, downloaded, local)
            except Exception as error:
                if args.publish:
                    raise pending_tap_error(tag, error) from error
                raise
            if args.publish:
                after_published_verification(repo_dir, tag, commit, downloaded, release)
            kind = "prerelease" if release["prerelease"] else "stable release"
            print(f"Published {kind} verified: https://github.com/{REPO}/releases/tag/{tag}")
            return
        if local is None:
            missing_release_directory()
        require_public_repository()
        print(f"Verifying FluxLLM {tag} before upload…", flush=True)
        run("bash", repo_dir / "verify-release.sh", tag, "--release-dir", snapshot, capture=False)
        if not notes.exists() and not notes.is_symlink():
            run("bash", repo_dir / "generate-release-notes.sh", tag, "--output", notes, capture=False)
        regular_file(notes)
        if not notes.read_text(encoding="utf-8").strip():
            raise ReleaseError("Release notes are empty. Edit release-notes.md before publishing.")
        shutil.copyfile(notes, snapshot / notes.name)

        check_tag(tag, commit)
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
            try:
                published = gh_json("api", f"{API}/releases/{release['id']}")
                if published.get("id") != release["id"]:
                    raise ReleaseError("Published release identity changed.")
                release = verify_published_release(
                    repo_dir, tag, commit, published, assets, Path(temporary) / "published", snapshot)
            except (ReleaseError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
                raise pending_tap_error(
                    tag, "The release was published, but final verification failed. "
                    "Rerun the same command to verify it without replacing assets. " + str(error)) from error
            after_published_verification(repo_dir, tag, commit, Path(temporary) / "published", release)
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
