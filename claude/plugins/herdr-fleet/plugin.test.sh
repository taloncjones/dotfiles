#!/bin/sh
# Runs the herdr-fleet mod's validate and test suites; skips without claude.
cd "$(dirname "$0")/../../.." || exit 2
PLUGIN=claude/plugins/herdr-fleet

if ! command -v claude >/dev/null 2>&1; then
    echo "[INFO] skip: claude not on PATH"
    exit 0
fi

claude plugin validate "$PLUGIN" || { echo "FAIL: plugin validate" >&2; exit 1; }
out=$(claude plugin test "$PLUGIN" 2>&1)
rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || { echo "FAIL: plugin test" >&2; exit 1; }
