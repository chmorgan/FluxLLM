#!/bin/bash
# Package already-built, provenance-bound Release products for local desktop use.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys


class PreviewError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PreviewError(message)


def path_hash(path):
    """Use the same file/tree hash definition as the native product provenance."""
    require(path.exists() and not path.is_symlink(), f"Missing regular source: {path}")
    checksum = hashlib.sha256()
    if path.is_file():
        checksum.update(path.read_bytes())
    else:
        for child in sorted(path.rglob("*")):
            require(not child.is_symlink(), f"Source resources must not contain symlinks: {child}")
            if child.is_file():
                checksum.update(str(child.relative_to(path)).encode())
                checksum.update(b"\0")
                checksum.update(child.read_bytes())
                checksum.update(b"\0")
    return checksum.hexdigest()


def run(*args):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    require(result.returncode == 0, f"{args[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout.strip()


def package(script_dir, args):
    require(re.fullmatch(r"[0-9a-f]{40}", args.commit), "--commit must be a full lowercase 40-character commit SHA.")
    products = args.products.expanduser().resolve()
    output_arg = args.output.expanduser().absolute()
    require(not os.path.lexists(output_arg), f"Output already exists; nothing was changed: {output_arg}")
    output = output_arg.resolve()
    require(not any(parent.suffix.lower() == ".app" for parent in (output, *output.parents)),
            "Output must not be inside an existing app or use an .app directory itself.")
    require(not output.is_relative_to(products) and not products.is_relative_to(output),
            "Output and immutable input products must be separate directories.")
    require(products.is_dir(), f"Products directory is missing: {products}")
    for tool in ("uname", "lipo", "codesign"):
        require(shutil.which(tool), f"Required packaging tool is unavailable: {tool}")
    require(run("uname", "-s") == "Darwin", "Local preview signing requires macOS.")
    machine = run("uname", "-m")
    require(machine in ("arm64", "x86_64"), "Unsupported Mac architecture.")

    provenance_path = products / "provenance.json"
    manifest_path = products / "source-tree-manifest.json"
    provenance_sha, manifest_sha = path_hash(provenance_path), path_hash(manifest_path)
    provenance, manifest = json.loads(provenance_path.read_text()), json.loads(manifest_path.read_text())
    require(provenance.get("schema_version") == 1 and provenance.get("production_commit") == args.commit
            and provenance.get("worktree_is_dirty") is False and provenance.get("build_configuration") == "release"
            and manifest.get("git_head") == args.commit
            and provenance.get("source_tree_sha256") == manifest.get("sha256"),
            "Products must identify the requested clean Release commit and its source inventory.")
    binary = products / "FluxLLMApp"
    branding = products / "FluxLLM_FluxLLM.bundle"
    binary_sha, branding_sha = path_hash(binary), path_hash(branding)
    require(binary.is_file() and os.access(binary, os.X_OK) and branding.is_dir(), "Release app or branding resources are incomplete.")
    performance_executable = provenance.get("performance_executable", "FluxLLMApp")
    require(performance_executable in ("FluxLLMApp", "FluxLLMPerformanceApp"), "Unknown performance executable in input provenance.")
    binary_hash_key = "desktop_app" if performance_executable == "FluxLLMPerformanceApp" else "app"
    expected_binary_sha = provenance.get("binary_sha256", {}).get(binary_hash_key)
    if binary_hash_key == "desktop_app":
        require(isinstance(expected_binary_sha, str) and re.fullmatch(r"[0-9a-f]{64}", expected_binary_sha),
                "Separated performance products must declare a full desktop_app SHA-256 hash for FluxLLMApp.")
    require(binary_sha == expected_binary_sha
            and branding_sha == provenance.get("resource_bundle_sha256", {}).get("FluxLLM_FluxLLM.bundle"),
            "App or branding bytes differ from the input Release provenance.")
    architectures = run("lipo", "-archs", str(binary)).split()
    require(architectures and set(architectures) <= {"arm64", "x86_64"} and machine in architectures,
            "Release executable does not contain a supported slice for this Mac.")
    runtime_hashes = provenance.get("runtime_library_sha256", {})
    require(isinstance(runtime_hashes, dict), "runtime_library_sha256 must be a map of library basenames to SHA-256 hashes.")
    runtime_libraries = {}
    for name, expected in runtime_hashes.items():
        require(isinstance(name, str) and re.fullmatch(r"lib[A-Za-z0-9_+.-]+\.dylib", name)
                and isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected),
                "Runtime library entries must use lib*.dylib basenames and full lowercase SHA-256 hashes.")
        source = products / name
        require(source.is_file() and not source.is_symlink(), f"Runtime library must be a regular file inside products: {name}")
        require(path_hash(source) == expected, f"Runtime library hash differs from input provenance: {name}")
        library_architectures = run("lipo", "-archs", str(source)).split()
        require(library_architectures and set(library_architectures) <= {"arm64", "arm64e", "x86_64"}
                and set(architectures) <= set(library_architectures),
                f"Runtime library lacks the executable's supported architectures: {name}")
        runtime_libraries[name] = {"source": str(source), "input_sha256": expected, "architectures": library_architectures,
                                   "signature": "ad-hoc"}

    plist_source = script_dir / "Resources/Info.plist"
    require(path_hash(plist_source) == manifest.get("files", {}).get("Resources/Info.plist", {}).get("sha256"),
            "Info.plist template differs from the input commit's source inventory.")
    metadata = plistlib.loads(plist_source.read_bytes())
    require(metadata.get("CFBundleIdentifier") == "com.cmorgan.FluxLLM"
            and metadata.get("CFBundleExecutable") == "FluxLLMApp" and metadata.get("LSUIElement") is True,
            "Info.plist is not the normal FluxLLM menu-bar app template.")
    icons = [path for path in branding.rglob("FluxLLM.icns") if path.is_file()]
    require(len(icons) == 1, "Expected exactly one FluxLLM app icon in the branding bundle.")
    icon = icons[0]
    icon_sha = path_hash(icon)
    require(icon_sha == manifest.get("files", {}).get("Sources/FluxLLM/Resources/Branding/FluxLLM.icns", {}).get("sha256"),
            "Bundled icon differs from the input commit's source inventory.")

    # Reserve a new destination; no pre-existing directory or app is removed.
    output.mkdir(parents=True, exist_ok=False)
    app = output / f"FluxLLM-Preview-{args.commit[:12]}.app"
    executable = app / "Contents/MacOS/FluxLLMApp"
    resources = app / "Contents/Resources"
    executable.parent.mkdir(parents=True)
    resources.mkdir()
    shutil.copy2(binary, executable)
    shutil.copytree(branding, resources / branding.name)
    shutil.copy2(icon, resources / "FluxLLM.icns")
    plist = app / "Contents/Info.plist"
    shutil.copy2(plist_source, plist)
    metadata["FluxLLMCommitSHA"] = args.commit
    plist.write_bytes(plistlib.dumps(metadata))
    require(path_hash(executable) == binary_sha and path_hash(resources / branding.name) == branding_sha
            and path_hash(resources / "FluxLLM.icns") == icon_sha, "Copied executable or resources differ from the verified inputs.")
    # @loader_path resolves these declared libraries beside the app executable.
    for name, library in sorted(runtime_libraries.items()):
        destination = executable.parent / name
        shutil.copy2(products / name, destination)
        require(path_hash(destination) == library["input_sha256"], f"Copied runtime library differs from its verified input: {name}")
        library["copied_sha256_before_signing"] = path_hash(destination)
        run("codesign", "--force", "--sign", "-", str(destination))
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(destination))
        library["packaged_sha256_after_signing"] = path_hash(destination)
    run("codesign", "--force", "--sign", "-", str(app))
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(app))
    for name, library in runtime_libraries.items():
        destination = executable.parent / name
        require(path_hash(destination) == library["packaged_sha256_after_signing"], f"App signing changed its signed runtime library: {name}")
        require(path_hash(products / name) == library["input_sha256"], f"Immutable runtime library changed during packaging: {name}")
        run("codesign", "--verify", "--deep", "--strict", "--verbose=2", str(destination))
    require(path_hash(resources / branding.name) == branding_sha and path_hash(resources / "FluxLLM.icns") == icon_sha
            and plistlib.loads(plist.read_bytes()) == metadata, "Signing changed the preview resources or metadata.")
    require(path_hash(binary) == binary_sha and path_hash(branding) == branding_sha
            and path_hash(provenance_path) == provenance_sha and path_hash(manifest_path) == manifest_sha,
            "Immutable input products changed during packaging.")
    info = {"schema_version": 1, "status": "preview_ready", "commit": args.commit, "configuration": "release",
            "app": str(app), "input_products": str(products), "architectures": architectures,
            "input_provenance_sha256": provenance_sha, "input_source_manifest_sha256": manifest_sha,
            "input_binary_sha256_key": binary_hash_key, "performance_executable": performance_executable,
            "input_app_sha256": binary_sha, "copied_app_sha256_before_signing": binary_sha,
            "packaged_app_sha256_after_signing": path_hash(executable), "branding_sha256": branding_sha, "icon_sha256": icon_sha,
            "runtime_libraries": runtime_libraries,
            "info_plist_sha256": path_hash(plist), "signature": "ad-hoc", "notarized": False,
            "built": False, "launched": False, "installed": False,
            "qualification": "Already-built Release executable, declared runtime libraries and resources copied from their clean source provenance. Ad-hoc signing may change executable/library signature bytes; before/after hashes are separate. No diagnostic arguments or configuration are created; no app is stopped, launched or installed."}
    (output / "preview-info.json").write_text(json.dumps(info, indent=2, sort_keys=True) + "\n")
    print(f"Preview ready: {app}\nCommit: {args.commit}\nMetadata: {output / 'preview-info.json'}")
    print("Ad-hoc signed for local testing; not notarized. Existing FluxLLM apps were left untouched.")


script_dir = Path(sys.argv.pop(1))
parser = argparse.ArgumentParser(description="Package provenance-bound, already-built Release products as a local preview; never build, launch or install.")
parser.add_argument("--products", type=Path, required=True, metavar="DIR", help="native products with clean Release provenance.json and source-tree-manifest.json")
parser.add_argument("--commit", required=True, metavar="FULL_SHA", help="full source commit recorded by those products")
parser.add_argument("--output", type=Path, required=True, metavar="DIR", help="new output directory; existing paths are never overwritten")
args = parser.parse_args()
try:
    package(script_dir, args)
except (PreviewError, OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
    sys.exit(f"Preview packaging failed: {error}\nAny new partial output is retained; retry with a new output directory.")
PY
