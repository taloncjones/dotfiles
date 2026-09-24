#!/bin/sh
# pr-post-guard.test.sh -- hermetic payload tests for pr_post_guard.py.
#
# Every case runs the hook with a throwaway DOTFILES_POST_GATE_DIR under
# mktemp, no live Claude session, and no real state root. HERDR_ENV=1 is set
# explicitly per case (except M1, which unsets it) rather than inherited.
set -u

PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HOOK=${PR_POST_GUARD_HOOK:-claude/hooks/pr_post_guard.py}
PASS=0
FAIL=0

FIX=$(mktemp -d /tmp/pr-post-guard.XXXXXX)
[ -n "$FIX" ] && [ -d "$FIX" ] || { printf 'FAIL  cannot create the fixture root\n' >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

export HERDR_ENV=1

case_gate() {
    GATE="$FIX/gate-$1"
    export DOTFILES_POST_GATE_DIR="$GATE"
}

# payload_u SID PROMPT -> UserPromptSubmit JSON on stdout
payload_u() {
    PU_SID="$1" PU_PROMPT="$2" python3 - <<'PY'
import json, os
print(json.dumps({
    "hook_event_name": "UserPromptSubmit",
    "session_id": os.environ["PU_SID"],
    "prompt": os.environ["PU_PROMPT"],
}))
PY
}

# payload_b SID COMMAND -> PreToolUse Bash JSON on stdout
payload_b() {
    PB_SID="$1" PB_CMD="$2" python3 - <<'PY'
import json, os
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "session_id": os.environ["PB_SID"],
    "tool_name": "Bash",
    "tool_input": {"command": os.environ["PB_CMD"]},
}))
PY
}

expect_rc() {
    label="$1"; want="$2"; payload="$3"
    printf '%s' "$payload" | python3 "$HOOK" >"$FIX/out" 2>"$FIX/err"
    rc=$?
    if [ "$rc" = "$want" ]; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (want rc=%s got rc=%s err=%s)\n' "$label" "$want" "$rc" "$(cat "$FIX/err")" >&2
        FAIL=$((FAIL + 1))
    fi
}

expect_file() {
    label="$1"; path="$2"; want="$3"
    if [ "$want" = present ] && [ -e "$path" ]; then
        ok=1
    elif [ "$want" = absent ] && [ ! -e "$path" ]; then
        ok=1
    else
        ok=0
    fi
    if [ "$ok" = 1 ]; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (want %s at %s)\n' "$label" "$want" "$path" >&2
        FAIL=$((FAIL + 1))
    fi
}

# --- G: the go must be a whole message -----------------------------------

case_gate g1
expect_rc "G1 prompt post it" 0 "$(payload_u s1 'post it')"
expect_file "G1 marker written" "$GATE/s1.json" present
expect_rc "G1 post allowed" 0 "$(payload_b s1 'gh pr comment 5 --body-file m.md')"

case_gate g2
expect_rc "G2 recommended-option prompt is not a go" 0 "$(payload_u s1 'Yes, post it (Recommended)')"
expect_file "G2 no marker minted" "$GATE/s1.json" absent
expect_rc "G2 post denied" 2 "$(payload_b s1 'gh pr comment 5 --body x')"

case_gate g3
expect_rc "G3 negated prompt is not a go" 0 "$(payload_u s1 'do not post it yet')"
expect_rc "G3 post denied" 2 "$(payload_b s1 'gh pr comment 5 --body x')"

case_gate g4
brief='Summary line one.
Type `post it` to post the marker.
Thanks.'
expect_rc "G4 brief mentioning the go is not a go" 0 "$(payload_u s1 "$brief")"
expect_rc "G4 post denied" 2 "$(payload_b s1 'gh pr comment 5 --body x')"

# --- P: the go lives one turn, is per session, and expires ---------------

case_gate p1
expect_rc "P1 mint (with trailing period)" 0 "$(payload_u s1 'Post it.')"
expect_rc "P1 first post allowed" 0 "$(payload_b s1 'gh pr comment 5 --body-file m.md')"
expect_rc "P1 second post denied" 2 "$(payload_b s1 'gh pr comment 5 --body-file m.md')"

case_gate p2
expect_rc "P2 mint" 0 "$(payload_u s1 'post it')"
expect_rc "P2 next prompt clears the go" 0 "$(payload_u s1 'thanks')"
expect_file "P2 marker removed" "$GATE/s1.json" absent
expect_rc "P2 post denied" 2 "$(payload_b s1 'gh pr comment 5 --body x')"

case_gate p3
expect_rc "P3 mint under s1" 0 "$(payload_u s1 'post it')"
expect_rc "P3 post under s2 denied" 2 "$(payload_b s2 'gh pr comment 5 --body x')"

case_gate p4
mkdir -p "$GATE"
printf '{"v":1,"kind":"post","expires_epoch":1}' >"$GATE/s1.json"
expect_rc "P4 expired marker denies" 2 "$(payload_b s1 'gh pr comment 5 --body x')"

case_gate p5
expect_rc "P5 mint" 0 "$(payload_u s1 'post it')"
expect_rc "P5 chained double post in one command denied" 2 "$(payload_b s1 'gh pr comment 5 --body a && gh pr comment 5 --body b')"

# --- D: supersede deletes need the post go, but not their own claim ------

case_gate d1
expect_rc "D1 delete without go denied" 2 "$(payload_b s1 'gh api -X DELETE repos/o/r/issues/comments/9')"

case_gate d2
expect_rc "D2 mint" 0 "$(payload_u s1 'post it')"
expect_rc "D2 post" 0 "$(payload_b s1 'gh pr comment 5 --body-file m.md')"
expect_rc "D2 delete via -X DELETE" 0 "$(payload_b s1 'gh api -X DELETE repos/o/r/issues/comments/9')"
expect_rc "D2 delete via --method DELETE" 0 "$(payload_b s1 'gh api --method DELETE repos/o/r/issues/comments/8')"

case_gate d3
expect_rc "D3 mint" 0 "$(payload_u s1 'post it')"
expect_rc "D3 post" 0 "$(payload_b s1 'gh pr comment 5 --body-file m.md')"
expect_rc "D3 loop delete allowed" 0 "$(payload_b s1 'for id in 1 2; do gh api -X DELETE repos/o/r/issues/comments/$id; done')"

# --- B: a body edit needs its own go, not the post go ---------------------

case_gate b1
expect_rc "B1 mint post" 0 "$(payload_u s1 'post it')"
expect_rc "B1 body edit denied under a post go" 2 "$(payload_b s1 'gh pr edit 5 --body-file b.md')"

case_gate b2
expect_rc "B2 mint body" 0 "$(payload_u s1 'edit the pr body')"
expect_rc "B2 first edit allowed" 0 "$(payload_b s1 'gh pr edit 5 --body-file b.md')"
expect_rc "B2 second edit denied" 2 "$(payload_b s1 'gh pr edit 5 --body-file b.md')"

case_gate b3
expect_rc "B3 mint body" 0 "$(payload_u s1 'edit the pr body')"
expect_rc "B3 post denied under a body go" 2 "$(payload_b s1 'gh pr comment 5 --body x')"

case_gate b4
expect_rc "B4 mint body" 0 "$(payload_u s1 'edit the pr body')"
expect_rc "B4 chained double body edit in one command denied" 2 "$(payload_b s1 'gh pr edit 5 --body-file a.md ; gh pr edit 5 --body-file b.md')"

# --- R: reads and non-posting gh calls are always allowed -----------------

case_gate r1
expect_rc "R1 pr view" 0 "$(payload_b s1 'gh pr view 5 --json comments')"

case_gate r2
expect_rc "R2 api GET comments paginate slurp" 0 "$(payload_b s1 'gh api repos/o/r/issues/5/comments --paginate --slurp')"
expect_rc "R2 api user jq" 0 "$(payload_b s1 'gh api user --jq .login')"
expect_rc "R2 api explicit GET with field" 0 "$(payload_b s1 'gh api -X GET search/issues -f q=x')"

case_gate r3
expect_rc "R3 pr create" 0 "$(payload_b s1 'gh pr create --title t --body b')"
expect_rc "R3 pr checks" 0 "$(payload_b s1 'gh pr checks 5')"

# --- FP: ordinary work must never be misread as a post --------------------

case_gate fp1
expect_rc "FP1 commit message mentions gh pr comment" 0 "$(payload_b s1 'git commit -m "co-review: handle gh pr comment"')"

case_gate fp2
expect_rc "FP2 command substitution around a GET" 0 "$(payload_b s1 'X=$(gh api repos/o/r/issues/5/comments)')"

case_gate fp3
heredoc='git commit -F - <<'"'"'EOF'"'"'
gh pr comment 5 --body x
EOF'
expect_rc "FP3 heredoc body line is not parsed as a command" 0 "$(payload_b s1 "$heredoc")"

case_gate fp4
expect_rc "FP4 plain words that happen to include comment/review" 0 "$(payload_b s1 'echo high through right comment review')"

case_gate fp5
expect_rc "FP5 graphql read query" 0 "$(payload_b s1 "gh api graphql -f query='query { viewer { login } }'")"

# --- FN: classification must not miss these shapes -------------------------

case_gate fn1
expect_rc "FN1 reply endpoint" 2 "$(payload_b s1 'gh api -X POST repos/o/r/pulls/5/comments/9/replies -f body=x')"

case_gate fn2
expect_rc "FN2 reaction endpoint" 2 "$(payload_b s1 'gh api repos/o/r/issues/comments/9/reactions -f content=+1')"

case_gate fn3
expect_rc "FN3 issue body PATCH" 2 "$(payload_b s1 'gh api -X PATCH repos/o/r/issues/5 -f body=x')"

case_gate fn4
expect_rc "FN4 attached -XPOST" 2 "$(payload_b s1 'gh api -XPOST repos/o/r/issues/5/comments --input c.json')"

case_gate fn5
expect_rc "FN5 lowercase --method post" 2 "$(payload_b s1 'gh api --method post repos/o/r/issues/5/comments --input c.json')"

case_gate fn6
expect_rc "FN6 path-invoked gh" 2 "$(payload_b s1 '/opt/homebrew/bin/gh pr comment 5 -b x')"

case_gate fn7
expect_rc "FN7a command gh" 2 "$(payload_b s1 'command gh pr comment 5 -b x')"
expect_rc "FN7b gh -R" 2 "$(payload_b s1 'gh -R o/r pr comment 5 -b x')"

case_gate fn8
expect_rc "FN8a pr close -c" 2 "$(payload_b s1 'gh pr close 5 -c bye')"
expect_rc "FN8b issue close --comment" 2 "$(payload_b s1 'gh issue close 5 --comment bye')"

case_gate fn9
expect_rc "FN9a sh -c post" 2 "$(payload_b s1 "sh -c 'gh pr comment 5 --body x'")"
expect_rc "FN9b bash -c delete" 2 "$(payload_b s1 "bash -c 'gh api -X DELETE repos/o/r/issues/comments/9'")"

case_gate fn10
expect_rc "FN10 graphql mutation" 2 "$(payload_b s1 "gh api graphql -f query='mutation { addComment(input:{}) { clientMutationId } }'")"

case_gate fn11
expect_rc "FN11a pr review" 2 "$(payload_b s1 'gh pr review 5 --approve')"
expect_rc "FN11b issue comment" 2 "$(payload_b s1 'gh issue comment 5 -b x')"

case_gate fn12
expect_rc "FN12a env -i gh pr comment denied with no go" 2 "$(payload_b s1 'env -i gh pr comment 5 --body x')"
expect_rc "FN12b sudo -u me gh pr comment denied with no go" 2 "$(payload_b s1 'sudo -u me gh pr comment 5 --body x')"
expect_rc "FN12c nice -n 5 gh pr edit denied with no go" 2 "$(payload_b s1 'nice -n 5 gh pr edit 5 --body-file b.md')"
expect_rc "FN12d env -i gh api DELETE comment denied with no go" 2 "$(payload_b s1 'env -i gh api -X DELETE repos/o/r/issues/comments/1')"
expect_rc "FN12e mint post" 0 "$(payload_u s1 'post it')"
expect_rc "FN12f env -i gh pr comment allowed once after typed go" 0 "$(payload_b s1 'env -i gh pr comment 5 --body x')"

case_gate fn13
expect_rc "FN13a if-wrapped gh pr comment denied with no go" 2 "$(payload_b s1 'if gh pr comment 5 --body-file m.md; then echo ok; fi')"
expect_rc "FN13b while-wrapped gh pr comment denied with no go" 2 "$(payload_b s1 'while ! gh pr comment 5 -b x; do :; done')"
expect_rc "FN13c until-wrapped gh pr comment denied with no go" 2 "$(payload_b s1 'until gh pr comment 5 -b x; do :; done')"

case_gate fn14
trailing_comment='cd /repo  # go to repo
gh pr comment 5 --body-file m.md'
expect_rc "FN14 gh pr comment on the line after a trailing # comment is denied with no go" 2 "$(payload_b s1 "$trailing_comment")"

case_gate fn15
apostrophe_comment="# don't post yet
gh pr comment 5 --body-file m.md"
expect_rc "FN15 an apostrophe inside a # comment does not desync the tokenizer" 2 "$(payload_b s1 "$apostrophe_comment")"

case_gate fn16
paren_line='(cd /repo)
gh pr comment 5 --body-file m.md'
expect_rc "FN16 gh pr comment on the line after a lone ) is denied with no go" 2 "$(payload_b s1 "$paren_line")"

case_gate fn17
subst_line='PR=$(gh pr view --json number -q .number)
gh pr comment "$PR" --body-file m.md'
expect_rc "FN17 gh pr comment on the line after a command substitution is denied with no go" 2 "$(payload_b s1 "$subst_line")"

# --- M: gate mechanics ------------------------------------------------------

case_gate m1
env -u HERDR_ENV sh -c '
    export DOTFILES_POST_GATE_DIR="'"$GATE"'"
    payload="{\"hook_event_name\": \"UserPromptSubmit\", \"session_id\": \"s1\", \"prompt\": \"post it\"}"
    printf "%s" "$payload" | python3 "'"$HOOK"'" >/dev/null 2>&1
    echo $?
' >"$FIX/m1-u-rc"
if [ "$(cat "$FIX/m1-u-rc")" = 0 ]; then
    printf 'PASS  M1 prompt inert outside herdr\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  M1 prompt inert outside herdr (rc=%s)\n' "$(cat "$FIX/m1-u-rc")" >&2; FAIL=$((FAIL + 1))
fi
env -u HERDR_ENV sh -c '
    export DOTFILES_POST_GATE_DIR="'"$GATE"'"
    payload="{\"hook_event_name\": \"PreToolUse\", \"session_id\": \"s1\", \"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"gh pr comment 5 --body x\"}}"
    printf "%s" "$payload" | python3 "'"$HOOK"'" >/dev/null 2>&1
    echo $?
' >"$FIX/m1-b-rc"
if [ "$(cat "$FIX/m1-b-rc")" = 0 ]; then
    printf 'PASS  M1 post inert outside herdr\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  M1 post inert outside herdr (rc=%s)\n' "$(cat "$FIX/m1-b-rc")" >&2; FAIL=$((FAIL + 1))
fi
expect_file "M1 gate dir never created" "$GATE" absent

case_gate m2
expect_rc "M2 bad sid prompt is a no-op" 0 "$(payload_u '../x' 'post it')"
expect_file "M2 no file escapes the gate dir" "$FIX/x.json" absent
expect_rc "M2 bad sid post denied" 2 "$(payload_b '../x' 'gh pr comment 5 --body x')"
mkdir -p "$GATE"
printf '{' >"$GATE/s9.json"
expect_rc "M2 corrupt marker denies" 2 "$(payload_b s9 'gh pr comment 5 --body x')"

case_gate m3
expect_rc "M3 mint" 0 "$(payload_u s1 'post it')"
modes=$(python3 -c "
import os, stat, sys
d, f = sys.argv[1], sys.argv[2]
print(oct(stat.S_IMODE(os.stat(d).st_mode)), oct(stat.S_IMODE(os.stat(f).st_mode)))
" "$GATE" "$GATE/s1.json")
if [ "$modes" = "0o700 0o600" ]; then
    printf 'PASS  M3 marker file modes\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  M3 marker file modes (got %s)\n' "$modes" >&2; FAIL=$((FAIL + 1))
fi
: >"$GATE/old.json"
python3 -c "
import os, sys, time
p = sys.argv[1]
old = time.time() - 2 * 86400
os.utime(p, (old, old))
" "$GATE/old.json"
expect_rc "M3 mint again prunes old files" 0 "$(payload_u s1 'post it')"
expect_file "M3 old marker pruned" "$GATE/old.json" absent

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
