#!/bin/sh
# commit-msg.test.sh -- behavioral tests for the global commit-msg hook.
#
# Agent names are built from string parts (CLAUDE_NAME, CODEX_NAME) so this
# file never contains a literal attribution string: the repo's own guards scan
# tracked content and command text for those. Every scratch file lives in one
# per-process directory so concurrent runs cannot collide.
#
# rg is required: the block-rule cases need it, and a silent skip would report
# success without testing anything. The Brewfile and CI install ripgrep. T9
# proves the strip pass itself still runs when rg is absent.

set -e

HOOK=git/hooks/commit-msg
if [ ! -f "$HOOK" ]; then
    echo "FAIL: $HOOK not found (run from repo root)" >&2
    exit 2
fi
if ! command -v rg >/dev/null 2>&1; then
    echo "FAIL: rg not installed; the block-rule cases need it (brew install ripgrep)" >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/commit-msg-test.XXXXXX")"
MSG="$WORK/msg"
EXPECTED="$WORK/expected"
EXPECTED_ERR="$WORK/expected_err"
OUT="$WORK/out"
ERR="$WORK/err"
PASS=0
FAIL=0

CODEX_NAME="Co""dex"
CLAUDE_NAME="Cl""aude"
CLAUDE_UPPER="$(printf '%s' "$CLAUDE_NAME" | tr a-z A-Z)"
CLAUDE_LOWER="$(printf '%s' "$CLAUDE_NAME" | tr A-Z a-z)"
# U+1F916, the robot emoji that prefixes the generated-with footer.
ROBOT="$(printf '\360\237\244\226')"
BODY_MSG="codex: Add hook

Body paragraph."

cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() {
    printf 'PASS  %s\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf 'FAIL  %s\n' "$1" >&2
    FAIL=$((FAIL + 1))
}

# Write $1 (plus a final newline) to MSG and run the hook on it.
run_hook() {
    printf '%s\n' "$1" >"$MSG"
    "$HOOK" "$MSG" >"$OUT" 2>"$ERR"
}

# label, input, expected, count: exit 0, MSG equals expected (plus final
# newline), and stderr is exactly the strip notice for count lines.
assert_strips() {
    printf '%s\n' "$3" >"$EXPECTED"
    printf 'commit-msg: stripped %s agent attribution line(s).\n' "$4" >"$EXPECTED_ERR"
    if run_hook "$2" && cmp -s "$MSG" "$EXPECTED" && cmp -s "$ERR" "$EXPECTED_ERR"; then
        pass "$1"
    else
        fail "$1"
    fi
}

# label, input: exit 0, MSG byte-identical to input, nothing on stderr.
assert_passthrough() {
    printf '%s\n' "$2" >"$EXPECTED"
    if run_hook "$2" && cmp -s "$MSG" "$EXPECTED" && [ ! -s "$ERR" ]; then
        pass "$1"
    else
        fail "$1"
    fi
}

# label, input: exit non-zero and MSG byte-identical to input.
assert_blocks() {
    printf '%s\n' "$2" >"$EXPECTED"
    if run_hook "$2"; then
        fail "$1"
    elif cmp -s "$MSG" "$EXPECTED"; then
        pass "$1"
    else
        fail "$1"
    fi
}

# label, input, expected: exit non-zero and MSG equals expected.
assert_blocks_leaving() {
    printf '%s\n' "$3" >"$EXPECTED"
    if run_hook "$2"; then
        fail "$1"
    elif cmp -s "$MSG" "$EXPECTED"; then
        pass "$1"
    else
        fail "$1"
    fi
}

# --- Existing policy -------------------------------------------------------

assert_passthrough "allows conventional message" "codex: Add hook parity"
assert_passthrough "allows claude scope" "claude: Update hooks"
assert_passthrough "allows legitimate tool names" "codex: Document ${CLAUDE_NAME}-plan-review skill"
assert_blocks "T8 blocks generated attribution in subject, file unchanged" "codex: Generated with ${CODEX_NAME}"
assert_blocks "blocks AI coauthor" "codex: Add hook

Co-authored-by: ${CLAUDE_NAME} <noreply@example.com>"
assert_blocks "blocks emoji" "codex: Add hook ${ROBOT}"

if rg -q 'rg not found' "$HOOK"; then
    pass "mentions missing rg visibly"
else
    fail "mentions missing rg visibly"
fi

# --- Summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
