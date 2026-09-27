# FluxLLM

## Origin

I wanted to see what ollama was going on my MacBook and couldn't find a status bar app that I liked. Here is the product of lots of AI prompts to tweak the look and feel and operation to what I thought would be a neat looking tool. I hope you enjoy it as much as I do.

If there is something you'd like tweaked or fixed feel free to open issues or PRs.

## Features

A macOS 15+ menu bar app for monitoring LLM inference with Ollama, vLLM,
Rapid-MLX, and llama.cpp. Shows token throughput, activity history, and this
Mac’s total GPU utilization.

Choose a backend in Settings. For Ollama, point clients using `/api/chat` or
`/api/generate` at `http://127.0.0.1:11435`; the default upstream is
`localhost:11434`. Other backends are monitored directly through their metrics
or status endpoints.

The dashboard's **Usage** row shows Ollama input/output tokens, tool calls, and
requests. Choose **Since launch**, **Selected period**, or **Today**; totals are
kept separately from the chart. `~` marks estimated output and `+` marks a known
input subtotal when some requests have not reported input usage.

Use the **History** menu for ranges through **24h**, or enter custom dates.
Drag across the chart to zoom, use the arrow buttons to move through history,
and select **Live** to follow new activity again. Double-click a request rail
or use its **Fit request** context menu to frame that request.

FluxLLM saves 24 hours of chart history and up to 30 days of bounded request
usage locally. Recent charts retain detailed samples; older history uses
minute averages. Saved usage contains counts, timing, model names, and tool
names—not prompt text, response text, tool arguments, or result contents.
History is separated by backend endpoint. Other backends continue to show
their server-reported token totals.

See [DESIGN.md](DESIGN.md) for architecture, measurement semantics, and limitations.

## Releases

[package-release.sh](package-release.sh) builds a tagged version, signs and
notarizes it, verifies the final ZIP, and generates release notes for Apple
Silicon on macOS 15+. Run packaging on an Apple Silicon Mac with Xcode tools,
Python 3.9+, and a full clone with its tags. Publishing uses the GitHub CLI
(`gh`), authenticated for `chmorgan/fluxllm`.

### One-time setup

Install your Developer ID Application certificate and its private key in
Keychain. The script selects your sole valid Developer ID Application identity
and uses the `fluxllm` notarization profile. If several identities are available,
it lists them so you can select one with `--signing-identity`.

On first use, enter your Apple Developer account email and an app-specific
password when prompted. Credentials are saved in Keychain for future releases.

To create a password, sign in at [account.apple.com](https://account.apple.com)
and select **Sign-In and Security → App-Specific Passwords → Generate an
app-specific password**.

### 1. Tag and package

Review and commit all release changes, including tooling, dependency pins, and
`LICENSE`. From that commit on `main`, run these commands in the same terminal,
choosing an unused `MAJOR.MINOR.PATCH` version without a `v` prefix:

```sh
release_tag=0.1.1
git push origin main
git tag -a "$release_tag" -m "FluxLLM $release_tag"
git push origin "refs/tags/$release_tag"
./package-release.sh "$release_tag"
release_dir="$PWD/.build/releases/$release_tag"
```

The script must match its copy in the tag. It builds that commit in isolation
and derives the app version and archive name from the tag. Before reporting
`Release ready`, it verifies the archive checksum, contents, version, commit,
architecture, signature, stapled notarization, and Gatekeeper acceptance.
Existing output directories are never overwritten; retry with `--output-dir`
pointing to a new directory under `.build/` or outside the repository, and update
`release_dir` accordingly.

Commit tooling changes before creating a new tag so its script matches the one
you invoke. Never move a published release tag.

### 2. Install and try the packaged app

```sh
./install-release.sh "$release_tag"
```

The installer verifies the archive, gracefully quits any running FluxLLM, and
installs the verified app at `~/Applications/FluxLLM.app` without `sudo`. It
keeps a backup of the previous installation, launches the installed app, and
checks that it stays running briefly. If installation or startup fails, it
restores the previous installation when safe and reports any recovery steps.

If packaging used a custom output directory, add `--release-dir "$release_dir"`.
Use `--install-dir DIR` for another installation folder, or `--no-launch` to
install without launching or checking startup. You can try the app from its
menu bar icon; the automatic startup check does not exercise backend
monitoring, the proxy, or other UI features.

Release notes are generated automatically; editing
`$release_dir/release-notes.md` is optional. They start with commit subjects from
the previous release tag to the current tag, or the full history for the first
release. The previous tag is the highest lower `MAJOR.MINOR.PATCH` version
reachable from the current tag.

**`release-notes.md` is a local, untracked file under the ignored
`.build/releases/<tag>/` directory. Do not commit it.** Publishing reads this
file and preserves your edits. Keep `build.log` and `notarization.json` locally
too.

### 3. Stage and publish

Create or update a draft test release:

```sh
./publish-release.sh "$release_tag"
```

The script verifies the archive and remote tag, uploads the ZIP, checksum, and
release metadata, then downloads the assets to verify their contents. Review
the draft's notes and files, then publish:

```sh
./publish-release.sh "$release_tag" --publish
```

Both commands default to a prerelease. Add `--stable` to both for a stable
release. If packaging used a custom output directory, add
`--release-dir "$release_dir"` to both commands. Published releases cannot be
modified by this script; use a new version for subsequent changes.

To rerun archive verification independently:

```sh
./verify-release.sh "$release_tag" --release-dir "$release_dir"
```

Packaging generates notes automatically. To generate a missing notes file
separately, run `./generate-release-notes.sh "$release_tag"`. Use
`--previous-tag <version>` to choose a different earlier ancestor tag, or
`--output <file>` for another ignored or external destination. Existing notes
are never overwritten.

<details>
<summary>Optional signing and profile overrides</summary>

Use `--signing-identity` with a full Developer ID Application name or its
40-character SHA-1 fingerprint, and `--notary-profile` for another Keychain
profile:

```sh
./package-release.sh "$release_tag" \
  --signing-identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile another-profile
```

For unattended packaging, create the selected profile interactively on that
machine first, for example with `xcrun notarytool store-credentials fluxllm`.
A missing profile without an interactive terminal stops before building and
prints the setup command.

</details>

Homebrew installation instructions will be added once the first release and
cask are available and verified.
