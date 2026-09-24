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

# --- Subject length ---------------------------------------------------------

# "codex: " is 7 bytes, so these subjects are exactly 74 and 75 bytes.
SUBJ74="codex: $(awk 'BEGIN { while (i++ < 67) printf "a" }')"
SUBJ75="codex: $(awk 'BEGIN { while (i++ < 68) printf "a" }')"

assert_passthrough "L1 passes a 74-character subject" "$SUBJ74"

# L2: exit status exactly 1 and stderr exactly the length line.
printf '%s\n' "$SUBJ75" >"$EXPECTED"
printf '%s\n' 'commit-msg: subject is 75 characters; keep it under 75.' >"$EXPECTED_ERR"
if run_hook "$SUBJ75"; then status=0; else status=$?; fi
if [ "$status" -eq 1 ] && cmp -s "$MSG" "$EXPECTED" && cmp -s "$ERR" "$EXPECTED_ERR"; then
    pass "L2 rejects a 75-character subject and reports its length"
else
    fail "L2 rejects a 75-character subject and reports its length"
fi

assert_passthrough "L3 ignores trailing whitespace on the subject" "$SUBJ74   "

# L9: the strip notice comes first, then the length line; the file keeps
# the stripped text.
printf '%s\n' "$SUBJ75
" >"$EXPECTED"
printf '%s\n' 'commit-msg: stripped 1 agent attribution line(s).' 'commit-msg: subject is 75 characters; keep it under 75.' >"$EXPECTED_ERR"
if run_hook "$SUBJ75

Co-Authored-By: ${CLAUDE_NAME} <noreply@example.com>"; then status=0; else status=$?; fi
if [ "$status" -eq 1 ] && cmp -s "$MSG" "$EXPECTED" && cmp -s "$ERR" "$EXPECTED_ERR"; then
    pass "L9 strips a trailer, then rejects the long subject"
else
    fail "L9 strips a trailer, then rejects the long subject"
fi
# L4: one case per git-generated subject form the hook exempts.
while IFS= read -r prefix; do
    assert_passthrough "L4 exempts a generated subject: $prefix" "$prefix $SUBJ74"
done <<'EOF'
Merge branch '
Merge branches '
Merge remote-tracking branch '
Merge remote-tracking branches '
Merge tag '
Merge tags '
Merge commit '
Merge commits '
Merge pull request #1 from
Merge https://example.invalid/
Merge ../
Revert "
Reapply "
fixup!
squash!
amend!
EOF
assert_blocks "L7 rejects a long subject that only starts with Merge" "Merge parsers $SUBJ74"

# --- Wider trailer net ------------------------------------------------------

# Na: a co-author naming each token in agent-tokens, capitalized as tools
# write them. Reading the file keeps agent names out of this script.
while read -r token; do
    name="$(printf '%s' "$token" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }')"
    assert_strips "Na strips a co-author naming token $token" "${BODY_MSG}

Co-Authored-By: ${name} Agent <agent@example.com>" "${BODY_MSG}
" 1
done <git/hooks/agent-tokens

assert_strips "Nb strips a co-author with a no-reply mailbox" "${BODY_MSG}

Co-Authored-By: Build Helper <no-reply@example.com>" "${BODY_MSG}
" 1

assert_strips "Nc strips a co-author with a bot address" "${BODY_MSG}

Co-Authored-By: helper <12345+helper[bot]@users.noreply.github.com>" "${BODY_MSG}
" 1

assert_strips "Nd1 strips a generated-with trailer key with any value" "${BODY_MSG}

Generated-with: some tool 1.2" "${BODY_MSG}
" 1

assert_strips "Nd2 strips a generated-by trailer key, mixed case" "${BODY_MSG}

Generated-By: anything at all" "${BODY_MSG}
" 1

assert_strips "Ne strips a bare session trailer key" "${BODY_MSG}

Session: 01ABC" "${BODY_MSG}
" 1

CURSOR_NAME="Cur""sor"
assert_strips "Nf strips an agent session key for a new token" "${BODY_MSG}

${CURSOR_NAME}-Session: local run" "${BODY_MSG}
" 1

GEMINI_NAME="Gem""ini"
assert_strips "Ng strips a generated-with footer naming a new token" "${BODY_MSG}

Generated with ${GEMINI_NAME}" "${BODY_MSG}
" 1

assert_passthrough "P1 keeps a human co-author with a GitHub noreply address" "${BODY_MSG}

Co-Authored-By: Jane Doe <12345+jane@users.noreply.github.com>"

assert_passthrough "P2 keeps a human co-author whose surname contains a token" "${BODY_MSG}

Co-Authored-By: Jane Raider <jane@example.com>"

DEVIN_NAME="Dev""in"
assert_strips "C1 accepted collision: human co-author named like a token" "${BODY_MSG}

Co-Authored-By: ${DEVIN_NAME} Smith <ds@example.com>" "${BODY_MSG}
" 1

assert_blocks "C2 accepted collision: surname starting with a token is refused" "${BODY_MSG}

Co-Authored-By: Jane ${DEVIN_NAME}e <jd@example.com>"

assert_blocks "C3 refuses a co-author with a token glued to another word" "${BODY_MSG}

Co-Authored-By: ${CLAUDE_NAME}Bot <bot@example.com>"

# --- Environment cases ------------------------------------------------------
# Failure paths are forced with PATH shims (a tool that always exits 1), not
# filesystem permissions, so they behave identically as root and as a user.

AGENT_MSG="${BODY_MSG}

Co-Authored-By: ${CLAUDE_NAME} <noreply@example.com>"
STRIPPED_MSG="${BODY_MSG}
"

# link_tools DIR TOOL...: populate DIR with symlinks to the real tools, so a
# hook run with PATH=DIR sees exactly that tool set.
link_tools() {
    dir="$1"
    shift
    mkdir -p "$dir"
    for tool in "$@"; do
        ln -s "$(command -v "$tool")" "$dir/$tool"
    done
}

# write_failing_shim DIR NAME: a NAME on PATH that always exits 1.
write_failing_shim() {
    printf '#!/bin/sh\nexit 1\n' >"$1/$2"
    chmod 755 "$1/$2"
}

# T9: rg absent. The strip pass must still run and the block checks must
# report the missing rg.
TOOLS="$WORK/tools"
link_tools "$TOOLS" bash awk grep sed cat mktemp mv rm
printf '%s\n' "$AGENT_MSG" >"$MSG"
printf '%s\n' "$STRIPPED_MSG" >"$EXPECTED"
if PATH="$TOOLS" "$HOOK" "$MSG" >"$OUT" 2>"$ERR" && cmp -s "$MSG" "$EXPECTED" && grep -q 'rg not found' "$ERR"; then
    pass "T9 strips without rg on PATH"
else
    fail "T9 strips without rg on PATH"
fi

# T20: each required strip-pass tool missing in turn; the hook must refuse
# with the named tool, and the file must be untouched.
for missing in awk grep sed cat mktemp mv rm; do
    dir="$WORK/no-$missing"
    mkdir "$dir"
    for tool in bash awk grep sed cat mktemp mv rm; do
        [ "$tool" = "$missing" ] || ln -s "$(command -v "$tool")" "$dir/$tool"
    done
    printf '%s\n' "$AGENT_MSG" >"$MSG"
    cp "$MSG" "$EXPECTED"
    if PATH="$dir" "$HOOK" "$MSG" >"$OUT" 2>"$ERR"; then
        fail "T20 refuses when $missing is missing"
    elif cmp -s "$MSG" "$EXPECTED" && grep -q "commit-msg: $missing not found" "$ERR"; then
        pass "T20 refuses when $missing is missing"
    else
        fail "T20 refuses when $missing is missing"
    fi
done

# T10: mktemp fails. Exit non-zero, commit-msg: line on stderr, original
# untouched, no temp residue next to it.
MKTEMP_FAIL="$WORK/mktemp-fail"
link_tools "$MKTEMP_FAIL" bash awk grep sed cat mv rm
write_failing_shim "$MKTEMP_FAIL" mktemp
DIR10="$WORK/t10"
mkdir "$DIR10"
printf '%s\n' "$AGENT_MSG" >"$DIR10/msg"
cp "$DIR10/msg" "$EXPECTED"
if PATH="$MKTEMP_FAIL" "$HOOK" "$DIR10/msg" >"$OUT" 2>"$ERR"; then
    fail "T10 fails closed when mktemp fails"
elif cmp -s "$DIR10/msg" "$EXPECTED" && grep -q 'commit-msg: cannot create a temp file' "$ERR" && [ "$(ls -A "$DIR10")" = "msg" ]; then
    pass "T10 fails closed when mktemp fails"
else
    fail "T10 fails closed when mktemp fails"
fi

# T23: mv fails after the temp file was written. Same guarantees, and the
# EXIT trap must have removed the temp file.
MV_FAIL="$WORK/mv-fail"
link_tools "$MV_FAIL" bash awk grep sed cat mktemp rm
write_failing_shim "$MV_FAIL" mv
DIR23="$WORK/t23"
mkdir "$DIR23"
printf '%s\n' "$AGENT_MSG" >"$DIR23/msg"
cp "$DIR23/msg" "$EXPECTED"
if PATH="$MV_FAIL" "$HOOK" "$DIR23/msg" >"$OUT" 2>"$ERR"; then
    fail "T23 fails closed when mv fails and leaves no temp file"
elif cmp -s "$DIR23/msg" "$EXPECTED" && grep -q 'commit-msg: failed to replace' "$ERR" && [ "$(ls -A "$DIR23")" = "msg" ]; then
    pass "T23 fails closed when mv fails and leaves no temp file"
else
    fail "T23 fails closed when mv fails and leaves no temp file"
fi

# L8: the length check needs no rg, so it still rejects with rg absent.
printf '%s\n' "$SUBJ75" >"$MSG"
cp "$MSG" "$EXPECTED"
if PATH="$TOOLS" "$HOOK" "$MSG" >"$OUT" 2>"$ERR"; then
    fail "L8 rejects a 75-character subject without rg on PATH"
elif cmp -s "$MSG" "$EXPECTED" && grep -q 'subject is 75 characters' "$ERR"; then
    pass "L8 rejects a 75-character subject without rg on PATH"
else
    fail "L8 rejects a 75-character subject without rg on PATH"
fi

# K1/K2: the token file is missing or holds an invalid line. The hook is
# copied so the fixture never touches the real agent-tokens.
for case in missing empty invalid crlf; do
    dir="$WORK/tokens-$case"
    mkdir "$dir"
    cp "$HOOK" "$dir/commit-msg"
    if [ "$case" = empty ]; then
        : >"$dir/agent-tokens"
    elif [ "$case" = invalid ]; then
        printf 'valid\nNot A Token\n' >"$dir/agent-tokens"
    elif [ "$case" = crlf ]; then
        printf 'valid\r\n' >"$dir/agent-tokens"
    fi
    printf '%s\n' "$AGENT_MSG" >"$MSG"
    cp "$MSG" "$EXPECTED"
    if "$dir/commit-msg" "$MSG" >"$OUT" 2>"$ERR"; then
        fail "K refuses when agent-tokens is $case"
    elif cmp -s "$MSG" "$EXPECTED" && grep -q 'agent-tokens is missing, empty, or invalid' "$ERR"; then
        pass "K refuses when agent-tokens is $case"
    else
        fail "K refuses when agent-tokens is $case"
    fi
done

# --- Summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
