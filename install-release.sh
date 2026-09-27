#!/bin/bash
# Install the verified release archive and check that the installed app starts.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
exec python3 - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


BUNDLE_ID = "com.cmorgan.FluxLLM"
QUIT_TIMEOUT = 15.0
LAUNCH_TIMEOUT = 10.0
STARTUP_GRACE = 3.0
POLL_INTERVAL = 0.25

# AppKit sends the normal quit request, allowing FluxLLM's asynchronous shutdown
# to finish without UI scripting or forced process kills.
APP_CONTROL = r'''
ObjC.import("AppKit");
function run(args) {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.cmorgan.FluxLLM");
    const result = [];
    for (let i = 0; i < apps.count; i++) {
        const app = apps.objectAtIndex(i);
        if (args[0] === "terminate" && app.processIdentifier === Number(args[1])) {
            return app.terminate ? "true" : "false";
        }
        result.push({pid: app.processIdentifier, path: ObjC.unwrap(app.bundleURL.path)});
    }
    if (args[0] === "terminate") return "true";
    if (args[0] === "list") return JSON.stringify(result);
    throw new Error("Unknown app control operation");
}
'''


class InstallError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise InstallError(message)


def run(*args, capture=False, timeout=None):
    result = subprocess.run(args, text=True, timeout=timeout,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        detail = (result.stderr or "").strip() if capture else ""
        raise InstallError(f"{args[0]} failed ({result.returncode}). {detail}".strip())
    return result.stdout.strip() if capture else None


def rename_exclusive(source, destination):
    # Both paths are in the installation directory, on the same filesystem.
    # RENAME_EXCL also protects against destinations appearing after preflight.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def running_apps(path=None):
    data = json.loads(run("osascript", "-l", "JavaScript", "-e", APP_CONTROL, "list",
                          capture=True, timeout=10))
    require(isinstance(data, list), "Could not read running FluxLLM applications.")
    for app in data:
        require(isinstance(app, dict) and isinstance(app.get("pid"), int)
                and app["pid"] > 0 and isinstance(app.get("path"), str)
                and Path(app["path"]).is_absolute(), "Invalid running application information.")
    return [app for app in data if path is None or Path(app["path"]).resolve() == path]


def quit_apps(path=None):
    deadline = time.monotonic() + QUIT_TIMEOUT
    requested = set()
    while True:
        apps = running_apps(path)
        if not apps:
            return
        for app in apps:
            if app["pid"] not in requested:
                accepted = run("osascript", "-l", "JavaScript", "-e", APP_CONTROL,
                               "terminate", str(app["pid"]), capture=True, timeout=10)
                require(accepted == "true" or
                        (accepted == "false" and not any(item["pid"] == app["pid"] for item in running_apps(path))),
                        "FluxLLM refused to quit. Quit it normally and retry.")
                requested.add(app["pid"])
        require(time.monotonic() < deadline,
                "FluxLLM did not finish quitting. Quit it normally and retry; it was not force-killed.")
        time.sleep(POLL_INTERVAL)


def check_startup(target):
    deadline = time.monotonic() + LAUNCH_TIMEOUT
    started = None
    pid = None
    while True:
        apps = running_apps(target)
        if pid is not None:
            require(any(app["pid"] == pid for app in apps),
                    "The installed FluxLLM app exited during its startup check.")
            if time.monotonic() - started >= STARTUP_GRACE:
                return
        elif apps:
            pid = apps[0]["pid"]
            started = time.monotonic()
        else:
            require(time.monotonic() < deadline,
                    f"The installed FluxLLM app did not start at {target}.")
        time.sleep(POLL_INTERVAL)


def validate_existing(target):
    require(not target.is_symlink(), f"Refusing to replace a symlink: {target}")
    if target.exists():
        require(target.is_dir(), f"Expected an app directory: {target}")
        plist_path = target / "Contents/Info.plist"
        require(plist_path.is_file() and not plist_path.is_symlink(),
                f"Existing app has no regular Info.plist: {target}")
        with plist_path.open("rb") as source:
            metadata = plistlib.load(source)
        require(isinstance(metadata, dict) and metadata.get("CFBundleIdentifier") == BUNDLE_ID,
                f"Refusing to replace an app with a different bundle identifier: {target}")


def install(script_dir, args):
    require(re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", args.tag),
            "Tag must be a plain X.Y.Z version, with no v prefix or leading zeroes.")
    for tool in ("uname", "bash", "osascript", "open"):
        require(shutil.which(tool), f"Required tool is unavailable: {tool}")
    require(run("uname", "-s", capture=True) == "Darwin", "Release installation requires macOS.")
    install_dir = Path(args.install_dir).expanduser().resolve()
    target = install_dir / "FluxLLM.app"
    validate_existing(target)
    install_dir.mkdir(parents=True, exist_ok=True)
    lock = install_dir / ".fluxllm-install.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise InstallError(f"Another installation may be running. If none is running, remove {lock} and retry.")
    try:
        with tempfile.TemporaryDirectory(prefix=".fluxllm-install-", dir=install_dir) as temporary:
            staging = Path(temporary)
            verified = staging / "verified"
            command = ["bash", str(script_dir / "verify-release.sh"), args.tag,
                       "--extract-to", str(verified)]
            if args.release_dir:
                command += ["--release-dir", args.release_dir]
            run(*command)
            app = verified / "FluxLLM.app"
            require(app.is_dir() and not app.is_symlink(), "Verifier did not export FluxLLM.app.")
            print("Quitting running FluxLLM applications before installation.", flush=True)
            quit_apps()
            validate_existing(target)
            backup_dir = None
            backup = None
            installed = None
            try:
                if target.exists():
                    backup_dir = Path(tempfile.mkdtemp(prefix=".fluxllm-backup-", dir=install_dir))
                    backup = backup_dir / "FluxLLM.app"
                    rename_exclusive(target, backup)
                # Record paths/inodes before moving anything so an interrupt
                # immediately after rename still leaves rollback enough state.
                installed = app.stat()
                rename_exclusive(app, target)
                if not args.no_launch:
                    run("open", "-n", str(target), timeout=15)
                    check_startup(target)
            except BaseException as error:
                try:
                    if installed is not None and os.path.lexists(target):
                        current = target.stat()
                        require(not target.is_symlink() and
                                (current.st_dev, current.st_ino) == (installed.st_dev, installed.st_ino),
                                "Installed app changed during rollback; leaving it in place.")
                        quit_apps(target)
                        rename_exclusive(target, staging / "failed.app")
                    if backup is not None and backup.exists():
                        rename_exclusive(backup, target)
                        print(f"Restored previous installation: {target}", file=sys.stderr)
                except BaseException as recovery_error:
                    recovery = f"Previous app is saved at {backup}." if backup else "No previous installation was replaced."
                    raise InstallError(f"{error}\nAutomatic rollback could not finish: {recovery_error}\n"
                                       f"{recovery} Quit FluxLLM before restoring it manually.") from error
                raise
            finally:
                if backup_dir is not None and not any(backup_dir.iterdir()):
                    backup_dir.rmdir()
            print(f"Installed FluxLLM {args.tag}: {target}")
            if backup is not None:
                print(f"Previous app saved at: {backup}")
            if args.no_launch:
                print("Launch and startup check skipped (--no-launch).")
            else:
                print(f"Startup check passed: the installed app stayed running for {STARTUP_GRACE:g} seconds.")
                print("You can now try the menu bar app. Backend and proxy behavior are not checked by this script.")
    finally:
        lock.rmdir()


parser = argparse.ArgumentParser(
    prog="install-release.sh",
    description="Verify, install, and launch a packaged FluxLLM release.",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog="""Behavior:
  - Installs the verified ZIP's app; no build or sudo required.
  - Quits FluxLLM normally and saves the previous installation for rollback.
  - Checks startup at the installed path; restores the old app on failure when safe.
  - Does not test backend monitoring or proxy requests.""")
parser.add_argument("tag", metavar="TAG", help="plain X.Y.Z Git tag")
parser.add_argument("--release-dir", metavar="DIR", help="artifacts (default: .build/releases/TAG)")
parser.add_argument("--install-dir", metavar="DIR", default="~/Applications",
                    help="destination folder (default: ~/Applications)")
parser.add_argument("--no-launch", action="store_true", help="install without launching or checking startup")
script_dir = Path(sys.argv.pop(1))
args = parser.parse_args()
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
try:
    install(script_dir, args)
except (InstallError, OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
    sys.exit(f"Release installation failed: {error}")
except KeyboardInterrupt:
    sys.exit("Release installation interrupted.")
PY
