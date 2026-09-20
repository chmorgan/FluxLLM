#!/bin/bash
set -e

# FluxLLM is an SPM-only project (no .xcodeproj), so this script drives the
# Swift toolchain directly rather than xcodebuild.
#
# Formatting is enforced with Apple's swift-format (invoked via xcrun, since it
# is not on PATH by default). The configuration lives in ./.swift-format.
#
# Flags:
#     --release       Build the release configuration.
#     --test          Run the test suite (default; implies a build).
#     --no-test       Build without running the test suite.
#     --bundle        Build, assemble a .app bundle, and ad-hoc sign it (no launch).
#     --run           Build, assemble + sign the .app bundle, and open it.
#     --format        Fix formatting in place, then continue.
#     --format-check  Lint formatting only (fail on drift), then exit.
#     --no-format     Skip the formatting check.
#
# Default (no format flags): lint formatting and FAIL the build on any drift,
# which keeps the tree consistent so targeted edits stay reliable.
# Tests run by default and must pass before bundling or launching the app.
#
# The bundle is required to see the menu bar icon: a bare SPM executable launched
# from a terminal runs as a "BackgroundOnly" process with no WindowServer session,
# so MenuBarExtra has nothing to attach to. Assembling a .app with an Info.plist
# (LSUIElement) and launching via `open` gives it a real GUI session.

FORMAT_MODE="check"     # check | fix | off
CONFIG="debug"
RUN_TESTS=true
BUILD_BUNDLE=false
DO_OPEN=false

# Parse flags
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --release) CONFIG="release" ;;
        --test) RUN_TESTS=true ;;
        --no-test) RUN_TESTS=false ;;
        --bundle) BUILD_BUNDLE=true ;;
        --run) BUILD_BUNDLE=true; DO_OPEN=true ;;
        --format) FORMAT_MODE="fix" ;;
        --format-check) FORMAT_MODE="lint-only" ;;
        --no-format) FORMAT_MODE="off" ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# --- Formatting -------------------------------------------------------------
run_format_fix() {
    echo "=== Formatting (fix in place) ==="
    xcrun swift-format format --in-place --configuration ./.swift-format --recursive Sources Tests
}

run_format_check() {
    echo "=== Formatting (check) ==="
    if ! xcrun swift-format lint --strict --configuration ./.swift-format --recursive Sources Tests; then
        echo "Formatting check failed. Run './build-dev.sh --format' to fix, or './build-dev.sh --no-format' to skip."
        exit 1
    fi
    echo "Formatting OK."
}

case "$FORMAT_MODE" in
    fix) run_format_fix ;;
    lint-only) run_format_check; echo "=== Done ==="; exit 0 ;;
    check) run_format_check ;;
    off) : ;;
esac

# --- Cleanup ----------------------------------------------------------------
# Kill every running instance of the app bundle before launching, so `open`
# starts a fresh process instead of re-activating an old one. Match by the
# bundle executable path (not just the proxy port), because an orphan instance
# that lost the port race may hold no port at all. The pattern is specific
# enough not to match this script or the transient `open` process.
stop_existing() {
    local pids survivors
    # The first renamed launch must also retire the previous product, which may
    # still own the Ollama client port. Match only these app-bundle executables.
    local app_pattern='/(FluxLLM\.app/Contents/MacOS/FluxLLMApp|OllamaFlux\.app/Contents/MacOS/OllamaFluxApp)([[:space:]]|$)'
    pids=$(pgrep -f "$app_pattern" 2>/dev/null || true)
    if [ -z "$pids" ]; then
        return 0
    fi
    echo "=== Stopping existing FluxLLM instance(s): $pids ==="
    kill $pids 2>/dev/null || true
    sleep 1
    survivors=$(pgrep -f "$app_pattern" 2>/dev/null || true)
    if [ -n "$survivors" ]; then
        echo "Force-killing survivors: $survivors"
        kill -9 $survivors 2>/dev/null || true
        sleep 1
    fi
}

# --- Build / test -----------------------------------------------------------
echo "=== Building FluxLLM ($CONFIG) ==="

if [ "$RUN_TESTS" = true ]; then
    swift test -c "$CONFIG"
else
    swift build -c "$CONFIG"
fi

# --- Bundle assembly --------------------------------------------------------
# Assemble a minimal .app bundle so the menu bar app can launch as a real GUI
# process. The binary is copied verbatim from the SPM build; only an Info.plist
# (LSUIElement + bundle metadata) and an ad-hoc signature are added. Ad-hoc
# signing with no hardened runtime / sandbox keeps localhost network I/O working.
if [ "$BUILD_BUNDLE" = true ]; then
    echo "=== Bundling FluxLLM.app ($CONFIG) ==="
    BIN=".build/$CONFIG/FluxLLMApp"
    BUNDLE=".build/$CONFIG/FluxLLM.app"
    if [ ! -f "$BIN" ]; then
        echo "Error: build binary not found at $BIN"
        exit 1
    fi
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
    cp "$BIN" "$BUNDLE/Contents/MacOS/FluxLLMApp"
    cp "Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
    # Keep the SwiftPM resource bundle inside the app so moving it does not
    # depend on the original development directory for its status artwork.
    if [ ! -d "${BIN%/*}/FluxLLM_FluxLLM.bundle" ]; then
        echo "Missing FluxLLM branding resource bundle beside $BIN" >&2
        exit 1
    fi
    ditto "${BIN%/*}/FluxLLM_FluxLLM.bundle" \
        "$BUNDLE/Contents/Resources/FluxLLM_FluxLLM.bundle"
    cp "Sources/FluxLLM/Resources/Branding/FluxLLM.icns" \
        "$BUNDLE/Contents/Resources/FluxLLM.icns"
    codesign --force --sign - "$BUNDLE"
    echo "Bundle ready: $BUNDLE"
    if [ "$DO_OPEN" = true ]; then
        stop_existing
        echo "Launching: open $BUNDLE"
        open "$BUNDLE"
    fi
fi

echo "=== Done ==="
if [ "$CONFIG" = "release" ]; then
    echo "Binary: .build/release/FluxLLMApp"
    echo "Run (bare): swift run FluxLLMApp"
fi
if [ "$BUILD_BUNDLE" = true ] && [ "$DO_OPEN" != true ]; then
    echo "Bundle: .build/$CONFIG/FluxLLM.app"
    echo "Launch: open .build/$CONFIG/FluxLLM.app"
fi
