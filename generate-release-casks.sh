#!/bin/bash
# Generate casks from the same release snapshot that passes archive verification.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


SCRIPT_DIR = Path(sys.argv.pop(1))
PROJECT_URL = "https://github.com/chmorgan/fluxllm"
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")


class GenerationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise GenerationError(message)


def git(*args, cwd=SCRIPT_DIR, check=True):
    result = subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True)
    require(not check or result.returncode == 0,
            result.stderr.strip() or "Git command failed: " + " ".join(args))
    return result


def regular_input(path):
    # Do not follow a symlink substituted after preflight. The open file remains
    # the source even if the pathname is subsequently replaced.
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(stat.S_ISREG(os.fstat(descriptor).st_mode), f"Expected a regular file: {path}")
        source = os.fdopen(descriptor, "rb")
    except BaseException:
        os.close(descriptor)
        raise
    return source


def destination_directory(path):
    path = Path(os.path.abspath(path.expanduser()))
    require(not path.is_symlink(), f"Output directory must not be a symlink: {path}")
    require(not os.path.lexists(path) or path.is_dir(), f"Output path is not a directory: {path}")
    return path.resolve()


def check_destination(path, content):
    ancestor = path.parent
    while not ancestor.exists():
        ancestor = ancestor.parent
    result = git("rev-parse", "--show-toplevel", cwd=ancestor, check=False)
    if result.returncode == 0:
        repo = Path(result.stdout.strip()).resolve()
        relative = str(path.relative_to(repo))
        tracked = git("ls-files", "--error-unmatch", "--", relative, cwd=repo, check=False)
        require(tracked.returncode != 0, f"Generated casks must not use a tracked path: {path}")
        ignored = git("check-ignore", "--quiet", "--", relative, cwd=repo, check=False)
        require(ignored.returncode == 0,
                "Generated casks inside a repository must use ignored, untracked paths; "
                "use the release directory or an external --output-dir.")
    if os.path.lexists(path):
        require(not path.is_symlink() and path.is_file(), f"Expected a regular output file: {path}")
        with regular_input(path) as existing:
            require(existing.read() == content, f"Existing cask differs; it was not overwritten: {path}")
        return True
    return False


def render(tag, checksum, *, exact):
    token = "fluxllm@" + tag if exact else "fluxllm"
    lines = [
        f'cask "{token}" do',
        f'  version "{tag}"',
        f'  sha256 "{checksum}"',
        "",
        f'  url "{PROJECT_URL}/releases/download/{tag}/FluxLLM-{tag}.zip"',
        '  name "FluxLLM"',
        '  desc "Menu bar monitor and proxy for local language models"',
        f'  homepage "{PROJECT_URL}"',
        "",
    ]
    if exact:
        lines.extend([
            "  livecheck do",
            '    skip "This cask installs a fixed release"',
            "  end",
            "",
        ])
    lines.extend([
        "  depends_on arch: :arm64",
        '  depends_on macos: :sequoia',
        "",
        '  app "FluxLLM.app"',
        "",
        "  caveats <<~EOS",
        "    Install only one FluxLLM cask at a time. Uninstall the current cask before switching versions.",
        "  EOS",
        "end",
        "",
    ])
    return "\n".join(lines).encode("utf-8")


def generate(args):
    require(VERSION.fullmatch(args.tag), "Tag must be plain X.Y.Z, without a v prefix or leading zeroes.")
    repo = Path(git("rev-parse", "--show-toplevel").stdout.strip()).resolve()
    reference = f"refs/tags/{args.tag}^{{commit}}"
    commit = git("rev-parse", "--verify", reference).stdout.strip()
    release_dir = Path(args.release_dir).expanduser().resolve() if args.release_dir else repo / ".build/releases" / args.tag
    require(release_dir.is_dir(), f"Release directory is missing: {release_dir}. Run ./package-release.sh {args.tag} first.")
    output_dir = destination_directory(Path(args.output_dir) if args.output_dir else release_dir / "Casks")
    archive_name = f"FluxLLM-{args.tag}.zip"
    with tempfile.TemporaryDirectory(prefix="fluxllm-casks-") as temporary:
        snapshot = Path(temporary)
        for name in (archive_name, "SHA256SUMS", "release-info.txt"):
            with regular_input(release_dir / name) as source, (snapshot / name).open("xb") as destination:
                shutil.copyfileobj(source, destination)
        # Both the verifier and cask rendering consume this private snapshot;
        # nothing reads the original artifacts again after this point.
        verification = subprocess.run(["bash", str(SCRIPT_DIR / "verify-release.sh"), args.tag,
                                       "--release-dir", str(snapshot)])
        require(verification.returncode == 0, "Release archive verification failed; no casks were generated.")
        checksum = hashlib.sha256()
        with (snapshot / archive_name).open("rb") as archive:
            for block in iter(lambda: archive.read(1024 * 1024), b""):
                checksum.update(block)
        outputs = [(output_dir / "fluxllm.rb", render(args.tag, checksum.hexdigest(), exact=False)),
                   (output_dir / f"fluxllm@{args.tag}.rb", render(args.tag, checksum.hexdigest(), exact=True))]
        existing = [(path, content, check_destination(path, content)) for path, content in outputs]
        require(git("rev-parse", "--verify", reference).stdout.strip() == commit,
                "Release tag changed during cask generation.")
        output_dir.mkdir(parents=True, exist_ok=True)
        published = []
        try:
            # Stage complete bytes first and publish with exclusive hard links.
            # An unexpected existing file is never replaced, including races.
            with tempfile.TemporaryDirectory(prefix=".fluxllm-casks-", dir=output_dir) as staging:
                for path, content, present in existing:
                    if present:
                        continue
                    staged = Path(staging) / path.name
                    staged.write_bytes(content)
                    staged.chmod(0o644)
                    os.link(staged, path)
                    published.append((path, staged.stat().st_ino))
        except BaseException:
            for path, inode in published:
                if not path.is_symlink() and path.stat().st_ino == inode:
                    path.unlink()
            raise
    for path, _, present in existing:
        print(("Already generated: " if present else "Generated cask: ") + str(path))


parser = argparse.ArgumentParser(
    prog="./generate-release-casks.sh",
    description="Verify a release and generate current and exact-version Homebrew casks.",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog="- Identical existing casks are kept; conflicting files are never overwritten.\n"
           "- Repository output paths must be ignored and untracked.\n"
           "- Requires macOS and the same verification tools as verify-release.sh.",
)
parser.add_argument("tag", metavar="TAG", help="existing plain X.Y.Z Git tag")
parser.add_argument("--release-dir", metavar="DIR", help="artifact directory (default: .build/releases/TAG)")
parser.add_argument("--output-dir", metavar="DIR", help="cask directory (default: RELEASE_DIR/Casks)")
try:
    generate(parser.parse_args())
except (GenerationError, OSError, ValueError, subprocess.CalledProcessError) as error:
    sys.exit(f"Cask generation failed: {error}")
PY
