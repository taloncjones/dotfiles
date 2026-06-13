#!/bin/sh
set -e

HOOK=git/hooks/commit-msg
TMP="${TMPDIR:-/tmp}/commit-msg-test.$$"
PASS=0
FAIL=0
CODEX_NAME="Co""dex"
CLAUDE_NAME="Cl""aude"

cleanup() {
    rm -f "$TMP"
}
trap cleanup EXIT

run_commit_msg() {
    message="$1"
    printf '%s\n' "$message" >"$TMP"
    "$HOOK" "$TMP" >/tmp/commit-msg-test.out 2>/tmp/commit-msg-test.err
}

assert_blocks() {
    label="$1"
    message="$2"
    if run_commit_msg "$message"; then
        printf 'FAIL  %s\n' "$label" >&2
        FAIL=$((FAIL + 1))
    else
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    fi
}

assert_allows() {
    label="$1"
    message="$2"
    if run_commit_msg "$message"; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_allows "allows conventional message" "codex: Add hook parity"
assert_allows "allows claude scope" "claude: Update hooks"
assert_allows "allows legitimate tool names" "codex: Document ${CLAUDE_NAME}-plan-review skill"
assert_blocks "blocks generated attribution" "codex: Generated with ${CODEX_NAME}"
assert_blocks "blocks AI coauthor" "codex: Add hook

Co-authored-by: ${CLAUDE_NAME} <noreply@example.com>"
assert_blocks "blocks emoji" "$(printf 'codex: Add hook \360\237\230\200')"

if rg -q 'rg not found' "$HOOK"; then
    printf 'PASS  %s\n' "mentions missing rg visibly"
    PASS=$((PASS + 1))
else
    printf 'FAIL  %s\n' "mentions missing rg visibly" >&2
    FAIL=$((FAIL + 1))
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
