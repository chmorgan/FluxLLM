#!/bin/sh
# Install one dispatcher without changing Git configuration or unrelated hooks.
set -eu

repository=$(git rev-parse --show-toplevel)
cd "$repository"
if configured=$(git config --get core.hooksPath); then
    printf '%s\n' "Refusing to replace custom core.hooksPath: $configured" >&2
    exit 1
else
    status=$?
    if [ "$status" -ne 1 ]; then
        printf '%s\n' "Could not inspect core.hooksPath." >&2
        exit 1
    fi
fi

if [ ! -x .githooks/pre-commit ] || [ ! -f scripts/check-swift-format.py ]; then
    printf '%s\n' "Tracked formatting hook/checker is missing or not executable." >&2
    exit 1
fi
hook=$(git rev-parse --git-path hooks/pre-commit)
mkdir -p "$(dirname "$hook")"
temporary=$(mktemp "${hook}.tmp.XXXXXX")
trap 'rm -f "$temporary"' EXIT HUP INT TERM
cat > "$temporary" <<'HOOK'
#!/bin/sh
# FluxLLM managed pre-commit dispatcher; installed by scripts/install-git-hooks.sh.
set -eu
repository=$(git rev-parse --show-toplevel)
exec "$repository/.githooks/pre-commit" "$@"
HOOK
if [ -L "$hook" ] || { [ -e "$hook" ] && ! cmp -s "$temporary" "$hook"; }; then
    printf '%s\n' "Refusing to replace existing unowned pre-commit hook: $hook" >&2
    exit 1
fi
if [ -e "$hook" ] && [ -x "$hook" ]; then
    printf '%s\n' "FluxLLM pre-commit hook is already installed."
    exit 0
fi
chmod +x "$temporary"
mv "$temporary" "$hook"
printf '%s\n' "Installed FluxLLM pre-commit hook: $hook"
