# Commit-msg Agent Attribution Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the global `commit-msg` git hook so agent-injected attribution lines (agent `Co-Authored-By` trailers, session-URL trailers, `Generated with|by <agent>` footers) are removed from the commit message instead of blocking it, with every other line kept byte-for-byte.

**Architecture:** A new strip pass runs at the top of the existing `git/hooks/commit-msg`, before the unchanged rg-based block checks. It uses only `bash`, `awk`, `grep`, `sed`, `cat`, `mktemp`, `mv`, `rm`, so it works in containers without `rg`. Line 1 is never touched; the rewrite is atomic (temp file plus `mv`) and happens only when at least one line matched. The existing test suite is rewritten around a per-process temp dir and byte-comparison helpers, then grown case by case; failure paths are forced with PATH shims, not filesystem permissions, so they behave the same as root and as a user.

**Tech Stack:** bash 3.2+ (hook), POSIX sh (test), BSD and GNU awk/sed/grep, `cmp`.

**Spec:** `docs/specs/2026-09-05-commit-msg-trailer-strip-spec.md` (branch-only; read it first, every rule and test number below refers to it).

**Verification contract:** `claude/contracts/td-2026-09-04-strip-agent-attribution-trailers-with-a-commit-msg-contract.json` (tracked; the orchestrator runs it after implementation). The mapping table at the end of this plan pairs each acceptance criterion with its contract command.

## Global Constraints

- No emojis in code, comments, commit messages, or file content, except the
  emoji byte sequences that test fixtures build with `printf` octal escapes.
- No AI attribution anywhere. Test fixtures and contract commands build agent
  names from string parts (`"Cl""aude"`, `printf 'Cl%sude' a`) so no file
  contains a literal attribution string. The PreToolUse Bash hook blocks
  command text containing attribution phrases: never put a fixture string in
  a Bash command; run the test file instead.
- Commit format: `<scope>: <summary>` (imperative, under 75 chars). Scope for
  this work is `git` (hook and test) or `docs` (README).
- Shell scripts: `#!/usr/bin/env bash` for the hook. The test keeps
  `#!/bin/sh` and runs as `sh git/hooks/commit-msg.test.sh` (recorded
  exception: every suite in `bin/dotfiles-tests` runs under `sh`).
- Regexes in the hook are POSIX ERE with bracket classes only: no `\b`, no
  `\s`, no `\d`. They must behave identically under macOS awk (bwk 20200816)
  and GNU awk.
- `rg` is a hard requirement of the test suite (the block-rule cases need it;
  the Brewfile and CI install ripgrep). The suite exits 2 without it rather
  than reporting success; the strip pass itself never needs `rg`.
- The spec and this plan are branch-only. `docs/specs/` and `docs/plans/` are
  gitignored and `git/hooks/public-safety.test.sh` fails while they are
  tracked. Do not un-ignore them. Remove them with a deletion commit before
  merge (Task 6); never drop the commit that also carries the contract.
- Never merge, push, or open a PR from this plan's tasks.

---

## File Structure

- Modify: `git/hooks/commit-msg` (54 lines today). Gains the strip pass
  between the early exits and the `rg` check. Existing block logic is kept
  verbatim.
- Rewrite: `git/hooks/commit-msg.test.sh`. Per-process temp dir, byte-compare
  helpers, existing six cases preserved, new cases T1-T23 appended in the
  order below.
- Modify: `README.md` section "Global Git Hooks" (lines 334-352 today): reword
  the no-op sentence to name `post-checkout`, add the `commit-msg` entry.
- Already committed with this plan (no task edits it):
  `claude/contracts/td-2026-09-04-strip-agent-attribution-trailers-with-a-commit-msg-contract.json`.

No other file changes. `bin/dotfiles-tests` already lists the suite.

---

### Task 1: Rebuild the test harness (no behavior change)

**Files:**
- Rewrite: `git/hooks/commit-msg.test.sh`

**Interfaces:**
- Consumes: `git/hooks/commit-msg` as it exists today.
- Produces: helpers `run_hook`, `assert_strips`, `assert_passthrough`,
  `assert_blocks`, `assert_blocks_leaving`, and the fixture variables
  `CLAUDE_NAME`, `CLAUDE_UPPER`, `CLAUDE_LOWER`, `CODEX_NAME`, `ROBOT`,
  `BODY_MSG`, `WORK`, `MSG`, `EXPECTED`, `EXPECTED_ERR`, `OUT`, `ERR`.
  Tasks 2 and 3 append cases that use exactly these names.

- [ ] **Step 1: Record the baseline**

Run: `sh git/hooks/commit-msg.test.sh`
Expected: `7 passed, 0 failed` (six message cases plus the `rg not found`
source check). Note the count.

- [ ] **Step 2: Replace the test file with the new harness**

Write `git/hooks/commit-msg.test.sh` with exactly this content:

```sh
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
```

- [ ] **Step 3: Run the rebuilt suite against the unchanged hook**

Run: `sh git/hooks/commit-msg.test.sh`
Expected: `7 passed, 0 failed`. Same count as the baseline; the harness
changed, the policy did not.

- [ ] **Step 4: Confirm no fixed /tmp paths remain**

Run: `grep -n '/tmp/commit-msg-test' git/hooks/commit-msg.test.sh`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add git/hooks/commit-msg.test.sh
git commit -m "git: Rebuild commit-msg test harness around a per-run temp dir"
```

---

### Task 2: Strip pass with message-shape cases

**Files:**
- Modify: `git/hooks/commit-msg` (insert between the message-file early
  exit and the `command -v rg` check)
- Modify: `git/hooks/commit-msg.test.sh` (replace the "blocks AI coauthor"
  case; append strip, pass-through, and block cases before the Summary
  section)

**Interfaces:**
- Consumes: Task 1 helpers and fixture variables.
- Produces: in the hook, shell variables `re_coauthor`, `re_session`,
  `re_footer`, functions `count_agent_lines <file>` (prints the number of
  matching lines from line 2 onward) and `write_without_agent_lines <in>
  <out>`, and the stderr line `commit-msg: stripped N agent attribution
  line(s).` Task 3 adds the tool check in front of these and relies on the
  exact failure strings `commit-msg: cannot create a temp file in` and
  `commit-msg: failed to replace`.

- [ ] **Step 1: Replace the co-author block case and append the new cases**

In `git/hooks/commit-msg.test.sh`, delete the three-line
`assert_blocks "blocks AI coauthor" ...` call. Then insert the following
block immediately before the `# --- Summary` line:

```sh
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
```

- [ ] **Step 2: Run the suite to see the new cases fail**

Run: `sh git/hooks/commit-msg.test.sh`
Expected: FAIL lines for T1, T2, T3, T4, T5, T11, T12, T13, T14, T15, T16,
T21, and T19 (the hook currently blocks instead of stripping, or ignores
session lines). T6, T7, T17a, T17b, T18, T22 and the existing cases pass.
Non-zero exit.

- [ ] **Step 3: Add the strip pass to the hook**

In `git/hooks/commit-msg`, replace the header comment and insert the strip
pass so the top of the file reads exactly as follows, down to and including
the existing `command -v rg` check (the rest of the file, from
`message="$(cat "$message_file")"` on, stays verbatim):

```bash
#!/usr/bin/env bash
set -euo pipefail

# Global commit-msg guard for portable commit message policy.
#
# Two layers, in order:
#   1. Strip pass (no rg needed): removes agent attribution lines that tools
#      inject -- agent Co-Authored-By trailers, session-URL trailers, and
#      "Generated with|by <agent>" footers -- from line 2 onward. Every other
#      line is written back byte-for-byte; a message with nothing to strip is
#      not rewritten at all.
#   2. Block checks (rg): reject what cannot be safely edited -- inline
#      attribution in the subject or body, and emojis.
# Squash-merge messages come from the PR body, which no git hook sees; the
# PR-side opt-out lives in claude/settings.json.tmpl (attribution.pr).

if [[ "${DOTFILES_SKIP_COMMIT_MSG_GUARD:-0}" == "1" ]]; then
  exit 0
fi

message_file="${1:-}"
if [[ -z "$message_file" || ! -f "$message_file" ]]; then
  exit 0
fi

# --- Strip pass --------------------------------------------------------------

# Lowercase POSIX ERE, matched against tolower($0) so BSD and GNU awk agree on
# case-insensitivity. Bracket classes only: no \b, no \s.
agent_tokens='(claude|anthropic|copilot|chatgpt|gpt|codex)'
re_coauthor="^[[:space:]]*co-authored-by:.*${agent_tokens}"
re_session='^[[:space:]]*(claude-session:|[a-z-]*session[a-z-]*:[[:space:]]*https?://)'
re_footer='^[^[:alnum:]]*generated[[:space:]]+(with|by)[^[:alnum:]]*(claude|anthropic|copilot|chatgpt|gpt|codex|ai)([^[:alnum:]]|$)'

# Line 1 (the subject) is never stripped. LC_ALL=C makes emoji bytes count as
# non-alphanumeric for the footer prefix.
count_agent_lines() {
  LC_ALL=C awk -v re_co="$re_coauthor" -v re_se="$re_session" -v re_fo="$re_footer" '
    NR == 1 { next }
    { line = tolower($0) }
    line ~ re_co || line ~ re_se || line ~ re_fo { n++ }
    END { print n + 0 }
  ' "$1"
}

write_without_agent_lines() {
  LC_ALL=C awk -v re_co="$re_coauthor" -v re_se="$re_session" -v re_fo="$re_footer" '
    NR == 1 { print; next }
    { line = tolower($0) }
    line ~ re_co || line ~ re_se || line ~ re_fo { next }
    { print }
  ' "$1" > "$2"
}

strip_tmp=""
cleanup_strip_tmp() {
  if [[ -n "$strip_tmp" ]]; then
    rm -f "$strip_tmp"
  fi
}
trap cleanup_strip_tmp EXIT

agent_lines="$(count_agent_lines "$message_file")"
if [[ "$agent_lines" -gt 0 ]]; then
  message_dir="${message_file%/*}"
  if [[ "$message_dir" == "$message_file" ]]; then
    message_dir="."
  fi
  if ! strip_tmp="$(mktemp "${message_dir}/.commit-msg.XXXXXX")"; then
    printf 'commit-msg: cannot create a temp file in %s; refusing to commit unchecked.\n' "$message_dir" >&2
    exit 1
  fi
  if ! write_without_agent_lines "$message_file" "$strip_tmp"; then
    printf 'commit-msg: failed to write the stripped message; refusing to commit unchecked.\n' >&2
    exit 1
  fi
  if ! mv -f "$strip_tmp" "$message_file"; then
    printf 'commit-msg: failed to replace %s; refusing to commit unchecked.\n' "$message_file" >&2
    exit 1
  fi
  strip_tmp=""
  printf 'commit-msg: stripped %s agent attribution line(s).\n' "$agent_lines" >&2
fi

# --- Block checks (unchanged) ------------------------------------------------

if ! command -v rg >/dev/null 2>&1; then
  printf 'commit-msg: rg not found; skipping attribution and emoji checks.\n' >&2
  exit 0
fi
```

Notes for the implementer:

- `re_footer` is single-quoted on purpose: it contains `$` for end of line.
- `awk -v` performs escape processing on its value; the patterns contain no
  backslashes, so they pass through unchanged.
- The `if ! strip_tmp="$(mktemp ...)"` form is what makes `set -e` safe here:
  the assignment's exit status is `mktemp`'s, and on failure `strip_tmp` is
  empty so the trap has nothing to remove. When `mv` fails, `strip_tmp` is
  still set, so the trap removes the temp file on exit.
- Do not add a tool-presence loop yet; Task 3 does that with its own test.

- [ ] **Step 4: Run the suite to see everything pass**

Run: `sh git/hooks/commit-msg.test.sh`
Expected: `25 passed, 0 failed` (6 existing-policy assertions after the
co-author block case moved under T1, plus 12 strip assertions: T1, T2, T3,
T4, T5, T11, T12, T13, T14, T15, T16, T21; 5 pass-through: T6, T7, T17a,
T18, T22; 2 block: T17b, T19). If the count differs, list the PASS/FAIL
lines and reconcile before moving on.

- [ ] **Step 5: Syntax-check the hook and confirm it is executable**

Run: `bash -n git/hooks/commit-msg && test -x git/hooks/commit-msg && echo ok`
Expected: `ok`.

- [ ] **Step 6: Commit**

```bash
git add git/hooks/commit-msg git/hooks/commit-msg.test.sh
git commit -m "git: Strip agent attribution lines in the commit-msg hook"
```

---

### Task 3: Tool check and forced-failure cases

**Files:**
- Modify: `git/hooks/commit-msg` (insert the tool check at the top of the
  strip pass)
- Modify: `git/hooks/commit-msg.test.sh` (append T9, T20, T10, T23 before
  the Summary section)

**Interfaces:**
- Consumes: Task 2 strip pass and its failure strings; Task 1 helpers and
  `WORK`, `MSG`, `EXPECTED`, `OUT`, `ERR`, `BODY_MSG`, `CLAUDE_NAME`,
  `pass`, `fail`.
- Produces: stderr line `commit-msg: <tool> not found; refusing to commit
  unchecked.` for each of `awk grep sed cat mktemp mv rm`; test helpers
  `link_tools DIR TOOL...` and `write_failing_shim DIR NAME`.

- [ ] **Step 1: Append the environment cases**

Insert immediately before the `# --- Summary` line in
`git/hooks/commit-msg.test.sh`:

```sh
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
```

- [ ] **Step 2: Run the suite; the seven T20 cases must fail, the rest pass**

Run: `sh git/hooks/commit-msg.test.sh`
Expected: seven `FAIL  T20 refuses when <tool> is missing` lines (bash
aborts on the missing tool with its own error, not the `commit-msg:` line);
T9, T10, T23 PASS; total `28 passed, 7 failed`, non-zero exit.

- [ ] **Step 3: Add the tool check to the hook**

In `git/hooks/commit-msg`, insert this block directly after the
`# --- Strip pass ---` header comment line and before the
`agent_tokens=` assignment:

```bash
for tool in awk grep sed cat mktemp mv rm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'commit-msg: %s not found; refusing to commit unchecked.\n' "$tool" >&2
    exit 1
  fi
done

```

- [ ] **Step 4: Run the suite to see everything pass**

Run: `sh git/hooks/commit-msg.test.sh`
Expected: `35 passed, 0 failed` (25 from Task 2, plus T9, seven T20, T10,
T23). No SKIP lines exist in this suite.

- [ ] **Step 5: Run the suite twice concurrently to prove there is no shared scratch path**

Run:

```bash
a="$(mktemp)"; b="$(mktemp)"
sh git/hooks/commit-msg.test.sh >"$a" 2>&1 & p1=$!
sh git/hooks/commit-msg.test.sh >"$b" 2>&1 & p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
tail -1 "$a" "$b"; echo "exit codes: $r1 $r2"; rm -f "$a" "$b"
```

Expected: both tails read `35 passed, 0 failed` and the last line is
`exit codes: 0 0`.

- [ ] **Step 6: Commit**

```bash
git add git/hooks/commit-msg git/hooks/commit-msg.test.sh
git commit -m "git: Fail closed when commit-msg strip tools are missing"
```

---

### Task 4: README entry for the commit-msg hook

**Files:**
- Modify: `README.md` section "Global Git Hooks" (starts at the line
  `### Global Git Hooks`)

**Interfaces:**
- Consumes: the final hook behavior from Tasks 2 and 3.
- Produces: a `commit-msg` entry starting with a line `**\`commit-msg\`**`
  and ending where the `**\`post-checkout\`**` entry begins. The contract
  extracts exactly that span and requires it to mention `Strip`, `Block`,
  `attribution.pr`, `DOTFILES_SKIP_COMMIT_MSG_GUARD`, and `squash`, and
  requires the sentence `The \`post-checkout\` hook is a no-op` elsewhere in
  the file.

- [ ] **Step 1: Reword the no-op sentence**

Replace this paragraph:

```markdown
`.gitconfig` sets `core.hooksPath` to `~/.config/git/hooks`, which the installer
symlinks to `git/hooks/` in this repo. The hook is a no-op for repos that do not
use `.todos/` or `.planning/`, so it is safe to leave globally enabled.
```

with:

```markdown
`.gitconfig` sets `core.hooksPath` to `~/.config/git/hooks`, which the installer
symlinks to `git/hooks/` in this repo. Two hooks live there. The `post-checkout` hook is a no-op
for repos that do not use `.todos/` or `.planning/`, and `commit-msg` only edits or
rejects agent attribution, so both are safe to leave globally enabled.
```

- [ ] **Step 2: Add the commit-msg entry**

Insert the following block directly after the reworded paragraph and before
the existing `**\`post-checkout\`**` entry:

```markdown
**`commit-msg`** — runs on every commit before the message is recorded. Two
layers, in order:

- **Strip** (no `rg` needed): removes agent attribution lines from line 2 onward
  and writes every other line back byte-for-byte: `Co-Authored-By` trailers
  naming an agent (Claude, Anthropic, Copilot, ChatGPT, GPT, Codex); session
  trailers (`Claude-Session:` with any value, or any `*Session*:` key whose value
  is a URL); and `Generated with|by <agent>` footer lines, emoji prefix included.
  A message with nothing to strip is not rewritten. When it strips, the hook
  prints `commit-msg: stripped N agent attribution line(s).` on stderr. A missing
  `awk`/`grep`/`sed`/`mktemp` fails closed (the commit is refused).
- **Block** (needs `rg`; warns and skips without it): rejects inline attribution
  in the subject or body and emojis, as before.

`DOTFILES_SKIP_COMMIT_MSG_GUARD=1` bypasses both layers. The hook cannot reach a
squash merge: GitHub composes that message from the PR body, so the guard for PR
descriptions is the `attribution.pr = ""` opt-out in `claude/settings.json.tmpl`
(with `attribution.commit = ""` and `attribution.sessionUrl = false` as the first
line of defense for commits). Keep those set; the hook is the backstop for
sessions where `settings.json` did not load.

```

- [ ] **Step 3: Verify the section the contract will extract**

Run:

```bash
awk '/^\*\*`commit-msg`\*\*/{p=1;next} /^\*\*`post-checkout`\*\*/{p=0} p' README.md > /tmp/cm-section.$$ && for w in Strip Block attribution.pr DOTFILES_SKIP_COMMIT_MSG_GUARD squash; do grep -c "$w" /tmp/cm-section.$$; done; grep -c 'The `post-checkout` hook is a no-op' README.md; rm -f /tmp/cm-section.$$
```

Expected: six lines, each `1` or more.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: Document the commit-msg strip layer and PR-side opt-out"
```

---

### Task 5: Verify against the contract and the wider suite

**Files:**
- Read only: `claude/contracts/td-2026-09-04-strip-agent-attribution-trailers-with-a-commit-msg-contract.json`

- [ ] **Step 1: Validate and run the contract with the repo-local verifier**

Run from the worktree root (the repo copy of the verifier is used so the
result does not depend on which `~/.claude` symlink this machine has):

```bash
python3 claude/hooks/herdr_orch_core.py verify-contract --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 --task-id td-2026-09-04-strip-agent-attribution-trailers-with-a-commit-msg --worktree "$PWD" --contract claude/contracts/td-2026-09-04-strip-agent-attribution-trailers-with-a-commit-msg-contract.json --allow-unpinned
```

Expected: one `ok <name> exit=0` line per command and a final
`PASS 12 commands`.

- [ ] **Step 2: Run the full suite and account for the one known failure**

Run: `bin/dotfiles-tests; echo "exit=$?"`
Expected: `1 failed`, and the failing suite is
`git/hooks/public-safety.test.sh` with exactly one FAIL line,
`no tracked planning artifacts`, caused by the branch-only spec and plan.
Every other suite reports `[OK]`. If `claude/hooks/claude-hooks.test.sh`
reports settings drift instead, that is machine state, not this change:
rerun it alone as `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh`
and expect `0 failed`. Any other failure is a regression to fix before
continuing.

- [ ] **Step 3: Confirm the hook is what a real commit runs**

Run: `git config --get core.hooksPath; readlink "$HOME/.config/git/hooks"`
Expected: `~/.config/git/hooks` and a path ending in `/git/hooks` inside a
dotfiles checkout. If the symlink points at the main checkout rather than
this worktree, that is expected: the hook file is identical once merged, and
the suite above exercised the worktree copy directly.

---

### Task 6: Branch gate (human-run at merge time)

No code changes to the hook. These are the steps the merger runs; they are
recorded here so the mapping table below has a human-verify target.

- [ ] **Step 1: Remove the branch-only artifacts with a deletion commit**

Do not drop or rewrite earlier commits: the commit that added the plan also
added the tracked contract. Delete only the two files:

```bash
git rm -q docs/specs/2026-09-05-commit-msg-trailer-strip-spec.md docs/plans/2026-09-05-commit-msg-trailer-strip-plan.md
git commit -m "docs: Drop branch-only trailer-strip spec and plan before merge"
```

- [ ] **Step 2: Confirm the contract survived and the tree is public-safe**

Run: `git ls-files --error-unmatch claude/contracts/td-2026-09-04-strip-agent-attribution-trailers-with-a-commit-msg-contract.json && ! git ls-files 'docs/specs/**' 'docs/plans/**' | grep -q . && sh git/hooks/public-safety.test.sh`
Expected: the contract path is printed, then the public-safety suite ends
with `0 failed`.

- [ ] **Step 3: Run the full suite on the merge candidate**

Run: `bin/dotfiles-tests`
Expected: `0 failed` (acceptance criterion AC13).

- [ ] **Step 4: Check the PR description**

Confirm the PR body carries no attribution footer. The `attribution.pr = ""`
opt-out is the only guard there (see README); a git hook never sees the PR
body.

---

## Acceptance criteria to contract commands

Contract file:
`claude/contracts/td-2026-09-04-strip-agent-attribution-trailers-with-a-commit-msg-contract.json`.
Commands run via `sh -c` from the worktree root. Fixture agent names are
built with `printf 'Cl%sude' a` and `printf 'Co%sex' d` so the contract
contains no literal attribution string. `rg` is required by
`commit-msg-suite`, `clean-message-byte-identical`,
`subject-attribution-still-blocked`, and `mixed-offense-strips-then-blocks`;
none of them skips when it is absent, they fail.

| Criterion | Contract command | Notes |
|-----------|------------------|-------|
| AC1 suite passes (T1-T23) | `commit-msg-suite` | `sh git/hooks/commit-msg.test.sh`; exits 2 without `rg` |
| AC2 agent co-author stripped, exact notice | `strips-agent-coauthor-line` | independent of the suite: builds the message, runs the hook, `cmp`s the file and the one-line stderr |
| AC3 session trailers stripped | `strips-session-url-trailer` | `Claude-Session:` URL case with exact stderr; the non-URL and other-key cases are suite-only (T3, T14) |
| AC4 generated-with footer stripped | `strips-generated-with-footer` | emoji prefix built from octal escapes; exact stderr |
| AC5 other lines survive, count matches | `strips-agent-coauthor-line`, `commit-msg-suite` | T5 in the suite is the full multi-line check with count 3 |
| AC6 clean message byte-identical, empty stderr | `clean-message-byte-identical` | requires `rg` (the block layer prints without it) |
| AC7 human co-author survives | `clean-message-byte-identical` | fixture includes `Co-Authored-By: Jane Doe` |
| AC8 subject untouched, mixed offense strips then blocks | `subject-attribution-still-blocked`, `mixed-offense-strips-then-blocks` | require `rg` |
| AC9 strip works without `rg` | `strips-without-rg-on-path` | PATH limited to the eight required tools |
| AC10 fail closed | `missing-tool-fails-closed`, `mktemp-failure-fails-closed` | PATH shims; deterministic as root or user. The `mv` case (T23) and the per-tool loop (T20) are suite-only |
| AC11 accepted collisions | `commit-msg-suite` | T15, T16 |
| AC12 README | `readme-documents-commit-msg-hook` | extracts the `commit-msg` entry span and checks its five required terms plus the reworded no-op sentence |
| AC13 full suite green at merge | human-verify (Task 6) | `public-safety.test.sh` cannot pass while the branch-only spec/plan are tracked, so the full-suite run belongs at the branch gate after the deletion commit |
| hook parses and is executable | `hook-bash-syntax-and-executable` | guards a truncated or non-executable hook file |

Falsifiability check: reverting the hook to its pre-task content fails
`strips-agent-coauthor-line`, `strips-session-url-trailer`,
`strips-generated-with-footer`, `mixed-offense-strips-then-blocks`,
`strips-without-rg-on-path`, `missing-tool-fails-closed`,
`mktemp-failure-fails-closed`, and the suite. Removing the README entry
fails `readme-documents-commit-msg-hook`.

## Self-review record

- Spec coverage: G1-G5 map to Tasks 2-4; every T-case in the spec appears
  in Task 1 (existing), Task 2 (T1-T8, T11-T19, T21, T22), or Task 3 (T9,
  T10, T20, T23). AC13 is human-verify by design.
- Placeholders: none; every step carries its content.
- Name consistency: `count_agent_lines`, `write_without_agent_lines`,
  `strip_tmp`, `cleanup_strip_tmp`, `re_coauthor`, `re_session`,
  `re_footer` are used identically in Tasks 2 and 3; test helper names in
  Task 1 match every later call; the failure strings Task 3 greps for are
  the ones Task 2 prints.
- Counts in "Expected" lines were confirmed by assembling the hook and test
  from this plan's code blocks in a scratch directory and running them, and
  by running the contract against that scratch copy (PASS 12 commands). The
  contract also fails against the pre-task hook on
  `strips-agent-coauthor-line`, which is the falsifiability proof.
- Codex plan review (one round) findings folded in: no success-skip on
  missing `rg`; per-tool missing-tool loop; `mktemp` and `mv` failures forced
  with PATH shims instead of directory permissions; exact stderr on every
  strip case and in the contract; concurrency step propagates both exit
  codes; Task 5 runs the repo-local verifier and the full suite; Task 6 is a
  deletion commit that keeps the contract; README check is scoped to the
  entry's span. Kept as-is: the merge gate remains human (repo operating
  principle), with the deterministic checks listed under Task 6.
