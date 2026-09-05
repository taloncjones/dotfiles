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
assert_blocks "blocks emoji" "codex: Add hook ${ROBOT}"

if rg -q 'rg not found' "$HOOK"; then
    pass "mentions missing rg visibly"
else
    fail "mentions missing rg visibly"
fi

# --- Strip cases: exit 0, matching lines removed, everything else kept ------

# The blank line that preceded the stripped trailer survives, so the expected
# text ends with one empty line. The last argument is the stripped-line count
# the hook must report on stderr.
assert_strips "T1 strips agent co-author trailer" "${BODY_MSG}

Co-Authored-By: ${CLAUDE_NAME} <noreply@example.com>" "${BODY_MSG}
" 1

assert_strips "T2 strips session URL trailer, mixed-case key" "${BODY_MSG}

${CLAUDE_UPPER}-session: https://example.invalid/code/session_01ABC" "${BODY_MSG}
" 1

assert_strips "T3 strips session URL trailer with another agent key" "${BODY_MSG}

${CODEX_NAME}-Session: https://example.invalid/s/1" "${BODY_MSG}
" 1

assert_strips "T4 strips generated-with footer with emoji prefix, mixed case" "${BODY_MSG}

${ROBOT} generated WITH [${CLAUDE_NAME} Code](https://example.invalid/code)" "${BODY_MSG}
" 1

assert_strips "T5 strips all three kinds, keeps human trailer and blank lines" "${BODY_MSG}

Co-Authored-By: ${CLAUDE_NAME} <noreply@example.com>
Reviewed-by: Jane Doe <jane@example.com>
${CLAUDE_NAME}-Session: https://example.invalid/code/session_01ABC

${ROBOT} Generated with [${CLAUDE_NAME} Code](https://example.invalid/code)" "${BODY_MSG}

Reviewed-by: Jane Doe <jane@example.com>
" 3

assert_strips "T11 strips lowercase co-author key and name" "${BODY_MSG}

co-authored-by: ${CLAUDE_LOWER} <noreply@example.com>" "${BODY_MSG}
" 1

assert_strips "T12 strips co-author with leading whitespace" "${BODY_MSG}

    Co-Authored-By: ${CLAUDE_NAME} <noreply@example.com>" "${BODY_MSG}
" 1

assert_strips "T13 strips generated-by with the ai token" "${BODY_MSG}

Generated by A""I" "${BODY_MSG}
" 1

assert_strips "T14 strips claude-session with a non-URL value" "${BODY_MSG}

${CLAUDE_NAME}-Session: local run, no link" "${BODY_MSG}
" 1

assert_strips "T15 accepted collision: body line starting generated with codex" "${BODY_MSG}

Generated with ${CODEX_NAME}, this change rewrites the parser." "${BODY_MSG}
" 1

assert_strips "T16 accepted collision: human co-author containing an agent token" "${BODY_MSG}

Co-Authored-By: ${CLAUDE_NAME} Martin <cm@example.com>" "${BODY_MSG}
" 1

# T21: no trailing newline on the stripped last line; output ends with the
# previous line plus LF.
printf '%s' "${BODY_MSG}

Co-Authored-By: ${CLAUDE_NAME} <noreply@example.com>" >"$MSG"
printf '%s\n' "${BODY_MSG}
" >"$EXPECTED"
printf 'commit-msg: stripped 1 agent attribution line(s).\n' >"$EXPECTED_ERR"
if "$HOOK" "$MSG" >"$OUT" 2>"$ERR" && cmp -s "$MSG" "$EXPECTED" && cmp -s "$ERR" "$EXPECTED_ERR"; then
    pass "T21 strips an unterminated final agent line"
else
    fail "T21 strips an unterminated final agent line"
fi

# --- Pass-through cases: exit 0, byte-identical, empty stderr --------------

assert_passthrough "T6 leaves a clean multi-paragraph message untouched" "codex: Add hook

First paragraph.


Second paragraph after a double blank line.

Reviewed-by: Jane Doe <jane@example.com>
Signed-off-by: Jane Doe <jane@example.com>"

assert_passthrough "T7 keeps a human co-author" "${BODY_MSG}

Co-Authored-By: Jane Doe <jane@example.com>"

assert_passthrough "T17a keeps generated-by when ai is inside a word" "${BODY_MSG}

Generated by Gaia's scheduler."

assert_passthrough "T18 keeps an inline agent mention" "${BODY_MSG}
Documents the ${CODEX_NAME}-plan-review skill."

assert_passthrough "T22 keeps a session key with a non-URL value" "${BODY_MSG}

Session-Notes: see wiki"

# --- Block cases: exit non-zero ---------------------------------------------

# The strip rule needs a non-alphanumeric byte after "ai"; the existing block
# rule has no boundary and rejects the line. Both facts are asserted here.
assert_blocks "T17b does not strip Aiden, block rule still rejects it" "${BODY_MSG}

Generated with Aiden's help on the parser."

assert_blocks_leaving "T19 mixed offense: trailer stripped, subject still blocked" "codex: Generated with ${CODEX_NAME}

Co-Authored-By: ${CLAUDE_NAME} <noreply@example.com>" "codex: Generated with ${CODEX_NAME}
"

# --- Summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
