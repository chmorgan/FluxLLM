"""Publish generated casks without changing the caller's checkout or release tags."""

import os
from pathlib import Path
import re
import subprocess
import tempfile


REMOTE_URL = "https://github.com/chmorgan/fluxllm.git"
BRANCH = "main"
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
DOWNLOAD_ROOT = "https://github.com/chmorgan/fluxllm/releases/download"


class TapUpdateError(Exception):
    """The release is usable, but its Homebrew tap update could not be completed."""


def git(cwd, *args, check=True):
    # Git state inherited from a caller (including an alternate index) must not
    # leak into the isolated clone. Authenticate through gh without reading or
    # writing a token in this script, its arguments, or the clone's config.
    config_files = {"GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM"}
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_") or key in config_files}
    env.update(GIT_TERMINAL_PROMPT="0", GH_HOST="github.com", GH_PROMPT_DISABLED="1")
    command = ["git", "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
               "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
               "-c", "push.followTags=false", *[str(arg) for arg in args]]
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise TapUpdateError(f"Git tap update failed (exit {result.returncode}): {detail}")
    return result


def regular_file(path):
    if path.is_symlink() or not path.is_file():
        raise TapUpdateError(f"Expected a regular cask file, not a missing file or symlink: {path}")
    if path.stat().st_size > 65536:
        raise TapUpdateError(f"Cask file is unexpectedly large: {path}")


def read_cask(path, token, generated=False):
    """Read literal metadata only; never execute a cask's Ruby code.

    Historical casks can retain comments and other harmless formatting, but
    must use the same small declarative format as generated casks. Ignoring an
    extra Ruby expression could miss a later override of literal metadata.
    This parser deliberately does not attempt to interpret arbitrary Ruby.
    """
    regular_file(path)
    content = path.read_text(encoding="utf-8")
    fields = {}
    patterns = {
        "token": r'\s*cask\s+"([^"\n]*)"\s+do\s*',
        "version": r'\s*version\s+"([^"\n]*)"\s*',
        "sha256": r'\s*sha256\s+"([^"\n]*)"\s*',
        "url": r'\s*url\s+"([^"\n]*)"\s*',
        "app": r'\s*app\s+"([^"\n]*)"\s*',
    }
    for key, pattern in patterns.items():
        matches = [match.group(1) for line in content.splitlines()
                   if (match := re.fullmatch(pattern, line))]
        if len(matches) != 1:
            raise TapUpdateError(f"Cask must declare exactly one literal {key}: {path}")
        fields[key] = matches[0]
    version = fields["version"]
    if not re.fullmatch(VERSION, version):
        raise TapUpdateError(f"Cask has an invalid release version: {path}")
    expected_url = f"{DOWNLOAD_ROOT}/{version}/FluxLLM-{version}.zip"
    if (fields["token"] != token or fields["app"] != "FluxLLM.app" or
            fields["url"] != expected_url or not re.fullmatch(r"[0-9a-f]{64}", fields["sha256"])):
        raise TapUpdateError(f"Cask has unexpected token, archive URL, app, or checksum: {path}")
    validate_cask_structure(content, path, fields, generated=generated)
    return fields, content


def validate_cask_structure(content, path, fields, generated):
    # Allow formatting differences, but only the generator's declarative Ruby.
    # In particular, do not copy interpolated expressions or executable hooks.
    lines = [line.strip() for line in content.splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    expected = [f'cask "{fields["token"]}" do', f'version "{fields["version"]}"',
                f'sha256 "{fields["sha256"]}"', f'url "{fields["url"]}"',
                'name "FluxLLM"', 'desc "Menu bar monitor and proxy for local language models"',
                'homepage "https://github.com/chmorgan/fluxllm"']
    if fields["token"] != "fluxllm":
        expected += ['livecheck do', 'skip "This cask installs a fixed release"', 'end']
    expected += ['depends_on arch: :arm64', 'depends_on macos: :sequoia',
                 'app "FluxLLM.app"', 'caveats <<~EOS',
                 'Install only one FluxLLM cask at a time. Uninstall the current cask before switching versions.',
                 'EOS', 'end']
    if lines != expected:
        kind = "Generated" if generated else "Existing"
        raise TapUpdateError(f"{kind} cask contains unsupported Ruby or platform requirements: {path}")


def version_key(version):
    return tuple(int(part) for part in version.split("."))


def same_release(left, right):
    return all(left[key] == right[key] for key in ("version", "sha256", "url"))


def update_tap(source_repo, tag, cask_dir, stable):
    """Commit generated casks to remote main after published assets were verified.

    The caller must establish that the release is published and its artifacts
    and tag are verified. This helper never publishes or edits a GitHub release.
    A fresh temporary clone ensures unrelated staged/working changes and local
    commits are neither touched nor accidentally pushed.
    """
    if not isinstance(tag, str) or not re.fullmatch(VERSION, tag):
        raise TapUpdateError("Tap version must be plain MAJOR.MINOR.PATCH.")
    if type(stable) is not bool:
        raise TapUpdateError("Tap update requires the published release's stable status.")
    source_repo, cask_dir = Path(source_repo), Path(cask_dir)
    if cask_dir.is_symlink() or not cask_dir.is_dir():
        raise TapUpdateError(f"Expected a real generated cask directory: {cask_dir}")
    pinned_name = f"fluxllm@{tag}.rb"
    pinned, pinned_text = read_cask(cask_dir / pinned_name, f"fluxllm@{tag}", generated=True)
    current, current_text = read_cask(cask_dir / "fluxllm.rb", "fluxllm", generated=True)
    if pinned["version"] != tag or not same_release(pinned, current):
        raise TapUpdateError("Generated current and version-specific casks must select the requested release.")

    with tempfile.TemporaryDirectory(prefix="fluxllm-tap-") as temporary:
        temporary = Path(temporary)
        checkout = temporary / "checkout"
        print(f"Checking Homebrew casks on {BRANCH} for FluxLLM {tag}…", flush=True)
        git(temporary, "clone", "--quiet", "--no-tags", "--single-branch", "--branch", BRANCH,
            "--", REMOTE_URL, checkout)
        casks = checkout / "Casks"
        if casks.is_symlink() or (casks.exists() and not casks.is_dir()):
            raise TapUpdateError("Remote Casks path must be a directory, not a symlink or file.")
        casks.mkdir(exist_ok=True)
        pinned_path, current_path = casks / pinned_name, casks / "fluxllm.rb"
        updates = {}
        if pinned_path.exists() or pinned_path.is_symlink():
            previous, _ = read_cask(pinned_path, f"fluxllm@{tag}")
            if not same_release(previous, pinned):
                raise TapUpdateError(f"Immutable cask Casks/{pinned_name} conflicts with the verified release. "
                                     "Do not overwrite historical release metadata.")
        else:
            updates[pinned_name] = pinned_text
        if stable:
            if current_path.exists() or current_path.is_symlink():
                previous, _ = read_cask(current_path, "fluxllm")
                if previous["version"] == tag and not same_release(previous, current):
                    raise TapUpdateError("Current cask already selects this version with different release metadata.")
                if version_key(previous["version"]) < version_key(tag):
                    updates["fluxllm.rb"] = current_text
            else:
                updates["fluxllm.rb"] = current_text
        if not updates:
            print(f"Homebrew tap already contains FluxLLM {tag}; no commit needed.", flush=True)
            return {"updated": False, "commit": None}

        identity = {}
        for key in ("name", "email"):
            result = git(source_repo, "config", "--get", f"user.{key}", check=False)
            value = result.stdout.strip()
            if result.returncode or not value or "\n" in value or "\r" in value:
                raise TapUpdateError(f"Set git config user.{key} before publishing the Homebrew tap.")
            identity[key] = value
        for name, content in updates.items():
            (casks / name).write_text(content, encoding="utf-8")
        changed_paths = sorted(f"Casks/{name}" for name in updates)
        git(checkout, "add", "--", *changed_paths)
        staged = git(checkout, "diff", "--cached", "--name-only").stdout.splitlines()
        if sorted(staged) != changed_paths:
            raise TapUpdateError("Tap commit does not contain exactly the intended cask files.")
        message = f"Update Homebrew casks for FluxLLM {tag}\n"
        message_file = temporary / "commit-message.txt"
        message_file.write_text(message, encoding="utf-8")
        git(checkout, "-c", f"user.name={identity['name']}", "-c", f"user.email={identity['email']}",
            "commit", "--quiet", "--no-verify", "-F", message_file)
        actual_message = git(checkout, "show", "-s", "--format=%B", "HEAD").stdout
        if actual_message.strip() != message.strip():
            raise TapUpdateError("Tap commit message did not match the intended message; nothing was pushed.")
        commit = git(checkout, "rev-parse", "HEAD").stdout.strip()
        push = git(checkout, "push", "origin", f"HEAD:refs/heads/{BRANCH}", check=False)
        if push.returncode:
            detail = (push.stderr or push.stdout).strip()
            raise TapUpdateError(
                f"Release is published, but the Homebrew tap push failed: {detail}\n"
                f"Fix GitHub access or branch protection if needed, then rerun "
                f"./publish-release.sh {tag} --publish. "
                "The retry reads the latest main and never force-pushes.")
        print(f"Updated Homebrew tap on {BRANCH}: {commit}", flush=True)
        return {"updated": True, "commit": commit}
