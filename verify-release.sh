#!/bin/bash
# Verify the distributable itself, including the signed app after ZIP extraction.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile


class VerificationError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def run(*args, capture=False):
    result = subprocess.run(args, stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None, text=True)
    if result.returncode:
        detail = (result.stderr or "").strip() if capture else ""
        raise VerificationError(f"{args[0]} failed ({result.returncode}). {detail}".strip())
    return result.stdout.strip() if capture else None


def regular_file(path):
    require(path.is_file() and not path.is_symlink(), f"Missing regular file: {path}")


def export_extraction(extracted, destination):
    # RENAME_EXCL refuses every existing destination, including an empty
    # directory created after preflight. Both paths share a parent filesystem.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(extracted), os.fsencode(destination), 0x00000004):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def canonical(parts):
    # APFS/HFS volumes may fold case and Unicode normalization during extraction.
    return tuple(unicodedata.normalize("NFC", part).casefold() for part in parts)


def safe_parts(name, *, directory=False):
    require(name and not any(ord(character) < 32 for character in name),
            "Archive paths must not contain empty names or control characters.")
    require("\\" not in name and ":" not in name,
            f"Unsafe archive path: {name!r}")
    parts = (name[:-1] if directory else name).split("/")
    require(all(part not in ("", ".", "..") for part in parts),
            f"Unsafe archive path: {name!r}")
    return parts


def inspect_archive(archive):
    entries = {}
    links = {}
    with zipfile.ZipFile(archive) as bundle:
        for item in bundle.infolist():
            require(item.orig_filename == item.filename, "Archive filename contains a NUL byte.")
            parts = safe_parts(item.filename, directory=item.is_dir())
            require(parts[0] in ("FluxLLM.app", "__MACOSX"),
                    f"Unexpected archive root: {parts[0]}")
            key = canonical(parts)
            require(key not in entries, f"Duplicate archive path: {item.filename}")
            require(not item.flag_bits & 1, "Encrypted archive entries are not supported.")
            kind = stat.S_IFMT(item.external_attr >> 16)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK),
                    f"Archive contains a special file: {item.filename}")
            require((kind != stat.S_IFDIR or item.is_dir()) and
                    (not item.is_dir() or kind in (0, stat.S_IFDIR)),
                    f"Archive entry type disagrees with its path: {item.filename}")
            entries[key] = "directory" if item.is_dir() else "symlink" if kind == stat.S_IFLNK else "file"
            if kind == stat.S_IFLNK:
                require(parts[0] == "FluxLLM.app" and item.file_size <= 4096,
                        f"Unsafe archive symlink: {item.filename}")
                target = bundle.read(item).decode("utf-8")
                # Framework links such as Versions/Current are supported. Parent
                # traversals are deliberately disallowed, even when lexical
                # normalization might appear to keep a link inside the bundle.
                target_parts = safe_parts(target)
                links[key] = key[:-1] + canonical(target_parts)
        require(entries, "Archive is empty.")
        require(entries.get(("fluxllm.app",), "directory") == "directory",
                "Archive app root must be a directory.")
        for key in entries:
            for length in range(1, len(key)):
                ancestor = key[:length]
                require(ancestor not in entries or entries[ancestor] == "directory",
                        "Archive contains an entry nested beneath a file or symlink.")
        # Ensure all link chains stay inside the app, terminate, and resolve to
        # actual files/directories. Implicit directories are valid ZIP content.
        all_paths = set(entries)
        for key in entries:
            all_paths.update(key[:length] for length in range(1, len(key)))
        for original, target in links.items():
            visited = {original}
            while True:
                require(target and target[0] == "fluxllm.app", "Archive symlink escapes the app.")
                found = next((target[:length] for length in range(1, len(target) + 1)
                              if target[:length] in links), None)
                if found is None:
                    require(target in all_paths, "Archive contains a dangling symlink.")
                    break
                require(found not in visited, "Archive contains a symlink cycle.")
                visited.add(found)
                target = links[found] + target[len(found):]
        require(bundle.testzip() is None, "Archive failed its internal CRC check.")


def verify(script_dir, args):
    require(re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.tag),
            "Tag must be a plain X.Y.Z version, with no v prefix or leading zeroes.")
    for tool in ("git", "uname", "ditto", "lipo", "codesign", "xcrun", "spctl"):
        require(shutil.which(tool), f"Required tool is unavailable: {tool}")
    require(run("uname", "-s", capture=True) == "Darwin", "Archive verification requires macOS.")
    extract_to = None
    if args.extract_to:
        requested = Path(os.path.abspath(os.path.expanduser(args.extract_to)))
        require(requested.name, "Extraction destination must be a new directory.")
        parent = requested.parent.resolve(strict=True)
        require(parent.is_dir(), f"Extraction destination parent is not a directory: {parent}")
        extract_to = parent / requested.name
        require(not os.path.lexists(extract_to), f"Extraction destination already exists: {extract_to}")
    repo = Path(run("git", "-C", str(script_dir), "rev-parse", "--show-toplevel", capture=True))
    reference = f"refs/tags/{args.tag}^{{commit}}"
    commit = run("git", "-C", str(repo), "rev-parse", "--verify", reference, capture=True)
    release_dir = Path(args.release_dir).expanduser().resolve() if args.release_dir else repo / ".build/releases" / args.tag
    archive_name = f"FluxLLM-{args.tag}.zip"
    archive = release_dir / archive_name
    manifest = release_dir / "SHA256SUMS"
    info = release_dir / "release-info.txt"
    for path in (archive, manifest, info):
        regular_file(path)
    checksum_line = manifest.read_text(encoding="utf-8")
    match = re.fullmatch(r"([0-9A-Fa-f]{64}) [ *]" + re.escape(archive_name) + r"\n?", checksum_line)
    require(match, f"SHA256SUMS must contain exactly one checksum for {archive_name}.")
    metadata = {}
    for line in info.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition(": ")
        require(separator and key not in metadata, "Malformed or duplicate release-info.txt metadata.")
        metadata[key] = value
    expected = {"Tag": args.tag, "Version": args.tag, "Commit": commit, "Architecture": "arm64",
                "Release title": f"FluxLLM {args.tag}", "Archive": archive_name}
    require(metadata == expected, "release-info.txt does not match the requested tag, commit, or archive.")
    with tempfile.TemporaryDirectory(prefix="fluxllm-verify-", dir=extract_to.parent if extract_to else None) as temporary:
        snapshot = Path(temporary) / archive_name
        # Verify and extract one immutable local snapshot of the archive.
        digest = hashlib.sha256()
        with archive.open("rb") as source, snapshot.open("wb") as destination:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
                destination.write(block)
        require(digest.hexdigest() == match.group(1).lower(), "Archive SHA-256 checksum mismatch.")
        inspect_archive(snapshot)
        extracted = Path(temporary) / "extracted"
        extracted.mkdir()
        run("ditto", "-x", "-k", str(snapshot), str(extracted))
        app = extracted / "FluxLLM.app"
        require(app.is_dir() and not app.is_symlink(), "Archive is missing FluxLLM.app.")
        # Validate actual volume semantics too: case-sensitive volumes may not
        # resolve a link that matched a case-folded archive path in preflight.
        for directory, directories, files in os.walk(app, followlinks=False):
            for name in directories + files:
                path = Path(directory) / name
                if path.is_symlink():
                    try:
                        target = path.resolve(strict=True)
                    except (OSError, RuntimeError) as error:
                        raise VerificationError(f"Extracted app contains an invalid symlink: {path}") from error
                    require(target.is_relative_to(app.resolve()), "Extracted symlink escapes the app.")
        plist_path = app / "Contents/Info.plist"
        executable = app / "Contents/MacOS/FluxLLMApp"
        license_path = app / "Contents/Resources/LICENSE"
        for path in (plist_path, executable, license_path):
            regular_file(path)
            require(path.resolve().is_relative_to(app.resolve()), "Bundle file escapes the extracted app.")
        with plist_path.open("rb") as source:
            plist = plistlib.load(source)
        require(isinstance(plist, dict), "Archived Info.plist must contain a dictionary.")
        for key, value in {"CFBundleShortVersionString": args.tag, "CFBundleVersion": args.tag,
                           "FluxLLMReleaseTag": args.tag, "FluxLLMCommitSHA": commit,
                           "CFBundleIdentifier": "com.cmorgan.FluxLLM",
                           "CFBundleExecutable": "FluxLLMApp"}.items():
            require(plist.get(key) == value, f"Archived app metadata mismatch: {key}.")
        require(os.access(executable, os.X_OK), "Archived app executable lacks execute permission.")
        require((app / "Contents/Resources/FluxLLM_FluxLLM.bundle").is_dir(),
                "Archived app is missing its SwiftPM resource bundle.")
        tagged_license = subprocess.check_output(["git", "-C", str(repo), "show", f"refs/tags/{args.tag}:LICENSE"])
        require(license_path.read_bytes() == tagged_license, "Archived LICENSE differs from the tagged source.")
        require(run("lipo", "-archs", str(executable), capture=True) == "arm64",
                "Archived app must contain exactly the arm64 architecture.")
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
        run("xcrun", "stapler", "validate", str(app))
        run("spctl", "--assess", "--type", "execute", "--verbose=2", str(app))
        require(run("git", "-C", str(repo), "rev-parse", "--verify", reference, capture=True) == commit,
                "Release tag changed during archive verification.")
        if extract_to:
            export_extraction(extracted, extract_to)
    print(f"Verified archive: {archive}\nTag: {args.tag}\nCommit: {commit}")
    if extract_to:
        print(f"Verified app: {extract_to / 'FluxLLM.app'}")


parser = argparse.ArgumentParser(description="Verify a release ZIP's checksum, tagged provenance, bundle, signature, notarization staple, and Gatekeeper assessment.")
parser.add_argument("tag", metavar="TAG", help="plain X.Y.Z Git tag")
parser.add_argument("--release-dir", metavar="DIR", help="artifact directory (default: .build/releases/TAG)")
parser.add_argument("--extract-to", metavar="DIR", help="keep the verified app in a new directory; parent must exist")
script_dir = Path(sys.argv.pop(1))
args = parser.parse_args()
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
try:
    verify(script_dir, args)
except (VerificationError, OSError, ValueError, UnicodeError, zipfile.BadZipFile, plistlib.InvalidFileException,
        subprocess.CalledProcessError) as error:
    sys.exit(f"Release verification failed: {error}")
PY
