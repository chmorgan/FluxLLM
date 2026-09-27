#!/bin/bash
# Build and package a tagged FluxLLM release. Compatible with macOS Bash 3.2.
set -euo pipefail

usage() {
    cat <<'USAGE'
Build a signed, notarized macOS release from a Git tag.

Usage:   ./package-release.sh TAG [options]
Example: ./package-release.sh 0.1.1

TAG must exist as X.Y.Z (no v prefix).
The script must match its committed copy in that tag.

Options:
  --output-dir DIR       Output folder (default: .build/releases/TAG)
  --signing-identity ID  Developer ID name or SHA-1 (default: automatic)
  --notary-profile NAME  Keychain profile (default: fluxllm)
  -h, --help             Show help

First run prompts for missing notarization credentials.
Existing output folders are never overwritten.

Requires: Apple Silicon Mac, Xcode, Python 3.9+, Developer ID certificate.
Details:  README.md → Releases
USAGE
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

# Select the actual certificate fingerprint, not its potentially duplicated
# display name. Even with -v, security may list entries with error annotations;
# only complete, unannotated Developer ID Application records are eligible.
select_keychain_identity() {
    local identities line fingerprint name existing duplicate selected=-1
    local candidate_count=0 index
    local -a fingerprints names
    fingerprints=()
    names=()
    local identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Developer ID Application: [^"]+)"[[:space:]]*$'
    if ! identities="$(security find-identity -v -p codesigning)"; then
        fail "Could not read signing identities from Keychain. Check Keychain access and try again."
    fi
    while IFS= read -r line; do
        [[ "$line" =~ $identity_pattern ]] || continue
        fingerprint="${BASH_REMATCH[1]}"
        name="${BASH_REMATCH[2]}"
        fingerprint="$(printf '%s' "$fingerprint" | tr '[:lower:]' '[:upper:]')"
        duplicate=false
        for ((index=0; index<candidate_count; index++)); do
            if [[ "${fingerprints[index]}" == "$fingerprint" ]]; then
                duplicate=true
                break
            fi
        done
        [[ "$duplicate" == false ]] || continue
        fingerprints[candidate_count]="$fingerprint"
        names[candidate_count]="$name"
        candidate_count=$((candidate_count + 1))
    done <<< "$identities"

    if [[ -n "$signing_identity" ]]; then
        fingerprint="$(printf '%s' "$signing_identity" | tr '[:lower:]' '[:upper:]')"
        for ((index=0; index<candidate_count; index++)); do
            if [[ "${fingerprints[index]}" == "$fingerprint" ]]; then
                selected=$index
                break
            fi
        done
        [[ $selected -ge 0 ]] || fail "The selected SHA-1 does not match a valid Developer ID Application identity in Keychain. See --help."
    elif [[ $candidate_count -eq 1 ]]; then
        selected=0
    elif [[ $candidate_count -eq 0 ]]; then
        fail "No valid Developer ID Application identity found. Install its certificate and private key, and unlock the Keychain. See --help."
    else
        printf 'Multiple valid Developer ID Application identities are available:\n' >&2
        for ((index=0; index<candidate_count; index++)); do
            printf '  %s  %s\n' "${fingerprints[index]}" "${names[index]}" >&2
        done
        fail "Choose a name or SHA-1 using --signing-identity. See --help."
    fi
    signing_identity_name="${names[selected]}"
    signing_identity="${fingerprints[selected]}"
    printf 'Using signing identity: %s [%s]\n' "${names[selected]}" "$signing_identity"
}

# Authentication for Apple's notary service is separate from code signing.
# Check it before creating output or building. Only a missing profile triggers
# first-use setup; network/authentication failures must not overwrite a profile.
ensure_notary_profile() {
    local diagnostic team_pattern=' \(([A-Z0-9]{10})\)$'
    local -a setup_command
    setup_command=(xcrun notarytool store-credentials "$notary_profile")
    if [[ "$signing_identity_name" =~ $team_pattern ]]; then
        setup_command+=(--team-id "${BASH_REMATCH[1]}")
    fi
    setup_command+=(--validate)

    printf 'Validating notarization profile: %s\n' "$notary_profile"
    # Capture only stderr. Submission history is not needed and must not enter
    # terminal output or build logs. Redirection order here is intentional.
    if diagnostic="$(xcrun notarytool history --keychain-profile "$notary_profile" --output-format json 2>&1 >/dev/null)"; then
        return 0
    fi
    if [[ "$diagnostic" != *'No Keychain password item found for profile:'* ]]; then
        printf '%s\n' "$diagnostic" >&2
        fail "Could not validate notarization profile '$notary_profile'. Check your credentials and network connection; no build was started."
    fi
    if [[ ! -t 0 ]]; then
        printf 'Notarization profile %s is missing. Run packaging in an interactive terminal for automatic setup, or set up this profile once:\n' "$notary_profile" >&2
        printf '  ' >&2
        printf '%q ' "${setup_command[@]}" >&2
        printf '\n' >&2
        fail "Notarization setup requires terminal input; no build was started."
    fi

    printf 'Notarization profile %s is missing. Starting Apple credential setup.\n' "$notary_profile"
    printf '%s\n' \
        'At "Developer Apple ID", enter the email address you use for' \
        'your Apple Developer account, for example developer@example.com.' \
        '' \
        'Then enter your app-specific password.' \
        'If you do not have one yet:' \
        '  1. Sign in at https://account.apple.com' \
        '  2. Open Sign-In and Security > App-Specific Passwords.' \
        '  3. Choose "Generate an app-specific password".' \
        '' \
        'These credentials are saved in Keychain for future releases.'
    # Delegate secret input directly to notarytool: no shell read, command-line
    # password, captured prompt output, or tee into a release log.
    if ! "${setup_command[@]}"; then
        fail "Notarization credential setup did not complete; no build was started. Rerun packaging to try again."
    fi
    if ! diagnostic="$(xcrun notarytool history --keychain-profile "$notary_profile" --output-format json 2>&1 >/dev/null)"; then
        printf '%s\n' "$diagnostic" >&2
        fail "The saved notarization profile could not be validated; no build was started. Check your credentials and network connection."
    fi
    printf 'Notarization credentials saved and verified.\n'
}

release_tag=""
signing_identity=""
signing_identity_name=""
notary_profile="fluxllm"
output_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --signing-identity|--notary-profile|--output-dir)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || fail "$1 requires a value."
            case "$1" in
                --signing-identity) signing_identity="$2" ;;
                --notary-profile) notary_profile="$2" ;;
                --output-dir) output_dir="$2" ;;
            esac
            shift 2
            ;;
        -*) fail "Unknown option: $1. See --help." ;;
        *)
            [[ -z "$release_tag" ]] || fail "Supply exactly one release tag."
            release_tag="$1"
            shift
            ;;
    esac
done

tag_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$release_tag" =~ $tag_pattern ]] || fail "Tag must be plain MAJOR.MINOR.PATCH (for example 0.1.0), without a v prefix or suffix."

fingerprint_pattern='^[[:xdigit:]]{40}$'
if [[ -n "$signing_identity" && "$signing_identity" != "Developer ID Application: "?* && ! "$signing_identity" =~ $fingerprint_pattern ]]; then
    fail "--signing-identity must be a Developer ID Application name or certificate SHA-1. See --help."
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script_path="$script_dir/$(basename "${BASH_SOURCE[0]}")"
repo_dir="$(git -C "$script_dir" rev-parse --show-toplevel)" || fail "Run this script from a FluxLLM Git checkout."
tag_ref="refs/tags/$release_tag"
git -C "$repo_dir" show-ref --verify --quiet "$tag_ref" || fail "No exact Git tag named $release_tag exists locally."
release_commit="$(git -C "$repo_dir" rev-parse --verify "${tag_ref}^{commit}")" || fail "Tag $release_tag does not point to a commit."

# Use only packaging logic that belongs to this release. A newer or edited
# script must not silently build an older tag using different release rules.
if ! git -C "$repo_dir" show "$release_commit:package-release.sh" | cmp -s "$script_path" -; then
    fail "package-release.sh must match the copy committed in tag $release_tag. Commit the release tooling before tagging, or use the script from that tag."
fi
for source_file in build-dev.sh Package.resolved Resources/Info.plist LICENSE verify-release.sh generate-release-notes.sh; do
    git -C "$repo_dir" cat-file -e "$release_commit:$source_file" || fail "Tag $release_tag is missing $source_file."
done
[[ "$(git -C "$repo_dir" rev-parse --is-shallow-repository)" == false ]] || fail "Release notes require full Git history. Fetch the complete history and release tags before packaging."

[[ "$(uname -s)" == Darwin ]] || fail "Release packaging requires macOS."
[[ "$(uname -m)" == arm64 ]] || fail "This release workflow requires an Apple Silicon Mac running natively (arm64)."
for tool in bash python3 git cmp ditto plutil codesign xcrun spctl lipo shasum tee; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool is unavailable: $tool."
done
xcrun --find notarytool >/dev/null || fail "Install/select Xcode with notarytool available."
xcrun --find stapler >/dev/null || fail "Install/select Xcode with stapler available."

if [[ -z "$signing_identity" || "$signing_identity" =~ $fingerprint_pattern ]]; then
    command -v security >/dev/null 2>&1 || fail "Required tool is unavailable: security."
    select_keychain_identity
else
    signing_identity_name="$signing_identity"
fi

if [[ -z "$output_dir" ]]; then
    output_dir="$repo_dir/.build/releases/$release_tag"
elif [[ "$output_dir" != /* ]]; then
    output_dir="$PWD/$output_dir"
fi
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || fail "Output already exists: $output_dir. Refusing to overwrite a release."
ensure_notary_profile
mkdir -p "$(dirname "$output_dir")"
output_dir="$(cd "$(dirname "$output_dir")" && pwd -P)/$(basename "$output_dir")"
# mkdir is also the reservation against another packager targeting this path.
mkdir "$output_dir" || fail "Could not reserve output directory: $output_dir."

temp_dir=""
worktree_dir=""
worktree_added=false
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$worktree_added" == true ]]; then
        if ! git -C "$repo_dir" worktree remove --force "$worktree_dir"; then
            printf 'Warning: temporary worktree could not be removed: %s\n' "$worktree_dir" >&2
            temp_dir=""
        fi
    fi
    if [[ -n "$temp_dir" ]]; then
        rm -rf "$temp_dir"
    fi
    if [[ $result -ne 0 ]]; then
        printf 'Release packaging failed. Logs, if produced, are in: %s\n' "$output_dir" >&2
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

archive_name="FluxLLM-$release_tag.zip"
{
    printf 'Tag: %s\n' "$release_tag"
    printf 'Version: %s\n' "$release_tag"
    printf 'Commit: %s\n' "$release_commit"
    printf 'Architecture: arm64\n'
    printf 'Release title: FluxLLM %s\n' "$release_tag"
    printf 'Archive: %s\n' "$archive_name"
} > "$output_dir/release-info.txt"

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/fluxllm-release.XXXXXX")"
worktree_dir="$temp_dir/source"
git -C "$repo_dir" worktree add --detach "$worktree_dir" "$release_commit"
worktree_added=true
# Validate the eventual notes destination before spending time building or
# notarizing. The tagged generator enforces that notes stay ignored/untracked.
bash "$worktree_dir/generate-release-notes.sh" "$release_tag" --output "$output_dir/release-notes.md" --check-output

printf 'Building tag %s at %s in a fresh checkout.\n' "$release_tag" "$release_commit"
(
    cd "$worktree_dir"
    bash ./build-dev.sh --release --bundle
) 2>&1 | tee "$output_dir/build.log"

# SwiftPM honors the tagged lockfile. Fail rather than distribute anything
# built after dependency resolution or other tooling changed tracked inputs.
if ! git -C "$worktree_dir" diff --quiet "$release_commit" --; then
    git -C "$worktree_dir" diff --stat "$release_commit" -- >&2
    fail "The build changed tracked inputs (including Package.resolved). Commit those changes and create a new release tag."
fi
[[ "$(git -C "$worktree_dir" rev-parse HEAD)" == "$release_commit" ]] || fail "The build changed the source checkout's commit."

built_app="$worktree_dir/.build/release/FluxLLM.app"
[[ -d "$built_app" ]] || fail "The tagged build did not produce .build/release/FluxLLM.app."
staging_dir="$temp_dir/staging"
mkdir "$staging_dir"
app_bundle="$staging_dir/FluxLLM.app"
ditto "$built_app" "$app_bundle"
app_plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/FluxLLMApp"
[[ -f "$app_plist" && -f "$executable" ]] || fail "The generated app is missing its executable or Info.plist."
[[ "$(lipo -archs "$executable")" == arm64 ]] || fail "The generated app must contain exactly the arm64 architecture."

# Stamp only the generated bundle; the tracked plist stays development metadata.
# All metadata and resources must be final before Developer ID signing.
plutil -replace CFBundleShortVersionString -string "$release_tag" "$app_plist"
plutil -replace CFBundleVersion -string "$release_tag" "$app_plist"
plutil -replace FluxLLMReleaseTag -string "$release_tag" "$app_plist"
plutil -replace FluxLLMCommitSHA -string "$release_commit" "$app_plist"
mkdir -p "$app_bundle/Contents/Resources"
cp "$worktree_dir/LICENSE" "$app_bundle/Contents/Resources/LICENSE"
plutil -lint "$app_plist"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$app_plist")" == "$release_tag" ]] || fail "App version stamping failed."
[[ "$(plutil -extract CFBundleVersion raw -o - "$app_plist")" == "$release_tag" ]] || fail "App build version stamping failed."

# This app has no embedded code requiring separate signing or runtime exceptions.
# Do not inherit the unused development entitlements' JIT/memory exceptions.
printf 'Signing FluxLLM %s.\n' "$release_tag"
codesign --force --sign "$signing_identity" --options runtime --timestamp "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"

submission_zip="$temp_dir/notarization.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$submission_zip"
printf 'Submitting FluxLLM %s for notarization.\n' "$release_tag"
if ! xcrun notarytool submit "$submission_zip" \
    --keychain-profile "$notary_profile" --wait --output-format json \
    > "$output_dir/notarization.json"; then
    fail "Notarization submission failed. See $output_dir/notarization.json and the tool's error output."
fi
notary_status="$(plutil -extract status raw -o - "$output_dir/notarization.json")" || fail "Notarization did not return a readable status."
[[ "$notary_status" == Accepted ]] || fail "Notarization status is $notary_status, not Accepted. See $output_dir/notarization.json."

xcrun stapler staple "$app_bundle"
xcrun stapler validate "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"
spctl --assess --type execute --verbose=2 "$app_bundle"

# A tag is a movable reference. Detect a change during this run and always keep
# the resolved commit in the signed app and the release's provenance file.
[[ "$(git -C "$repo_dir" rev-parse --verify "${tag_ref}^{commit}")" == "$release_commit" ]] || fail "Tag $release_tag changed while packaging."

# Re-create the archive after stapling; a ZIP itself cannot carry a staple.
final_zip="$temp_dir/$archive_name"
ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$final_zip"
(
    cd "$temp_dir"
    shasum -a 256 "$archive_name" > SHA256SUMS
)
mv "$final_zip" "$temp_dir/SHA256SUMS" "$output_dir/"
# Use the helper versions committed in the release, just like the build script.
# Verification extracts the final ZIP, so it checks exactly what users download.
bash "$worktree_dir/verify-release.sh" "$release_tag" --release-dir "$output_dir"
bash "$worktree_dir/generate-release-notes.sh" "$release_tag" --output "$output_dir/release-notes.md"
printf 'Release ready: %s/%s\n' "$output_dir" "$archive_name"
printf 'Checksum and source provenance: %s\n' "$output_dir"
printf 'Edit release notes before publishing: %s/release-notes.md\n' "$output_dir"
