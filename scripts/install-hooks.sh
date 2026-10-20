#!/bin/bash
# Install a pre-commit hook that runs `swift test` + `swiftlint` before
# every commit. Gives you poor-man's CI until GitHub's macOS 26 runners
# ship. Pairs cleanly with .github/workflows/ci.yml once that's usable.
#
# Usage: run once from the repo root:
#   ./scripts/install-hooks.sh
#
# To skip the hook for a single commit (emergencies only):
#   git commit --no-verify

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_PATH="$REPO_ROOT/.git/hooks/pre-commit"

cat > "$HOOK_PATH" << 'HOOK'
#!/bin/bash
# Katib pre-commit — fail fast on broken tests or lint errors.
# Bypass with: git commit --no-verify

set -e

# Only run if Swift sources are part of this commit. Pure doc/config
# commits should go through unblocked.
if ! git diff --cached --name-only | grep -qE '\.swift$|Package\.swift|\.yml$|\.json$'; then
    exit 0
fi

echo "→ pre-commit: swift test"
# Gate on the exit code. Grepping the tail for "0 failures" broke once
# swift-testing started printing its own summary after the XCTest one.
if ! swift test >/dev/null 2>&1; then
    echo "✗ pre-commit: tests failed (re-run 'swift test' to see output)"
    echo "  bypass with: git commit --no-verify"
    exit 1
fi

echo "→ pre-commit: swiftlint"
if command -v swiftlint >/dev/null 2>&1; then
    # Run in default mode (not --strict) so only ERROR-severity violations
    # block the commit. Warnings show in output but don't fail.
    if ! swiftlint lint --quiet; then
        echo "✗ pre-commit: swiftlint errors above"
        echo "  bypass with: git commit --no-verify"
        exit 1
    fi
else
    echo "  (swiftlint not installed — skipping lint step)"
fi

echo "✓ pre-commit: green"
HOOK

chmod +x "$HOOK_PATH"
echo "Installed pre-commit hook at $HOOK_PATH"
echo ""
echo "It runs 'swift test' + 'swiftlint' on any commit touching Swift or"
echo "Package files. Bypass with 'git commit --no-verify' in emergencies."
