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
# The gate is a work-repo rule: run from a fixture home so the result does
# not depend on the machine, with payload cwd outside ~/Git/personal.
mkdir -p "$FIX/home/work" "$FIX/home/Git/personal/repo"
git init -q "$FIX/home/Git/personal/repo"
git -C "$FIX/home/Git/personal/repo" remote add origin https://github.com/me/repo.git
HOME="$FIX/home"
export HOME
unset CLAUDE_PERSONAL_ONLY
WORK_CWD="$FIX/home/work"
PERSONAL_CWD="$FIX/home/Git/personal/repo"
# The hook honors a go only when `gh` on its PATH is the shim that spends it.
PATH="$(pwd)/bin/herdr-shims:$PATH"
export PATH
# Drafts bind to a session: never inherit the live pane's session or pid.
# Drafts bind to a session: never inherit the live pane's session or pid.
CLAUDE_CODE_SESSION_ID=s1
export CLAUDE_CODE_SESSION_ID
unset CLAUDE_PID

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
    PB_SID="$1" PB_CMD="$2" PB_CWD="${PB_CWD:-$WORK_CWD}" python3 - <<'PY'
import json, os
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "session_id": os.environ["PB_SID"],
    "cwd": os.environ["PB_CWD"],
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

# --- G: the go is a phrase anywhere in a typed prompt ---------------------

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

case_gate g3b
expect_rc "G3b post all inside a sentence is a go" 0 "$(payload_u s1 'looks fine, ok post all')"
expect_file "G3b marker written" "$GATE/s1.json" present
expect_rc "G3b post allowed" 0 "$(payload_b s1 'gh pr comment 5 --body-file m.md')"

case_gate g3c
expect_rc "G3c Post it mid-sentence is a go" 0 "$(payload_u s1 'Merge order is fine. Post it and continue.')"
expect_file "G3c marker written" "$GATE/s1.json" present

case_gate g3d
expect_rc "G3d edit the pr body mid-sentence is a body go" 0 "$(payload_u s1 'then edit the pr body with the new counts')"
expect_rc "G3d body edit allowed" 0 "$(payload_b s1 'gh pr edit 5 --body-file b.md')"

case_gate g3e
expect_rc "G3e postit without a boundary is not a go" 0 "$(payload_u s1 'compostit')"
expect_file "G3e no marker minted" "$GATE/s1.json" absent

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
expect_rc "P1 second post passes the hook (the shim spends the go)" 0 "$(payload_b s1 'gh pr comment 5 --body-file m.md')"
expect_file "P1 hook claims nothing" "$GATE/s1.post-used" absent
: >"$GATE/s1.post-used"
expect_rc "P1c post denied once the shim has spent the go" 2 "$(payload_b s1 'gh pr comment 5 --body-file m.md')"

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
expect_rc "B2 second edit passes the hook (the shim spends the go)" 0 "$(payload_b s1 'gh pr edit 5 --body-file b.md')"
: >"$GATE/s1.body-used"
expect_rc "B2c edit denied once the shim has spent the go" 2 "$(payload_b s1 'gh pr edit 5 --body-file b.md')"

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

# --- V: round-3 blocker and minors, and the redesign's default-deny -------

case_gate v1
cont_line=$(printf 'gh api -X POST \\\nrepos/o/r/pulls/5/comments/9/replies -f body=x')
expect_rc "V1 backslash line continuation is denied with no go" 2 "$(payload_b s1 "$cont_line")"
case_gate v1b
expect_rc "V1b mint post" 0 "$(payload_u s1 'post it')"
expect_rc "V1b same continuation allowed after typed go" 0 "$(payload_b s1 "$cont_line")"

case_gate v2
expect_rc "V2 env assignment ahead of a flagged wrapper is still denied with no go" 2 "$(payload_b s1 'FOO=1 sudo -u me gh pr comment 5 --body x')"

case_gate v3
expect_rc "V3 a mid-word # in an argument does not defeat the post gate" 2 "$(payload_b s1 'gh pr comment 5 --body abc#hidden')"

case_gate v4
expect_rc "V4a timeout-wrapped gh pr comment is denied with no go" 2 "$(payload_b s1 'timeout 5 gh pr comment 5 --body x')"
expect_rc "V4a mint post" 0 "$(payload_u s1 'post it')"
expect_rc "V4a timeout-wrapped gh pr comment passes after a typed go" 0 "$(payload_b s1 'timeout 5 gh pr comment 5 --body x')"
case_gate v4b
expect_rc "V4b stdbuf-wrapped gh pr comment is denied with no go" 2 "$(payload_b s1 'stdbuf -oL gh pr comment 5 --body x')"

case_gate v5
expect_rc "V5 ANSI-C \$'...' quoting is denied outright, no go" 2 "$(payload_b s1 "gh pr comment 5 --body \$'hi'")"
expect_rc "V5 mint post" 0 "$(payload_u s1 'post it')"
expect_rc "V5 ANSI-C quoted post passes after a typed go" 0 "$(payload_b s1 "gh pr comment 5 --body \$'hi'")"

# --- U: a gh call outside the read and gated tables passes as a write ------

case_gate u1
expect_rc "U1 unknown gh subcommand passes the hook as a plain write" 0 "$(payload_b s1 'gh foo bar')"
case_gate u1b
expect_rc "U1b mint post" 0 "$(payload_u s1 'post it')"
expect_rc "U1b unknown gh subcommand passes the hook after a typed go" 0 "$(payload_b s1 'gh foo bar')"

case_gate u2
expect_rc "U2 api POST to an ungated path passes the hook as a plain write" 0 "$(payload_b s1 'gh api -X POST repos/o/r/labels -f name=x')"
case_gate u2b
expect_rc "U2b mint post" 0 "$(payload_u s1 'post it')"
expect_rc "U2b api POST to an ungated path passes the hook after a typed go" 0 "$(payload_b s1 'gh api -X POST repos/o/r/labels -f name=x')"

# --- W: every allowed read and known write form -----------------------------

case_gate w1
expect_rc "W1 pr checks" 0 "$(payload_b s1 'gh pr checks 5')"
expect_rc "W1 pr diff" 0 "$(payload_b s1 'gh pr diff 5')"
expect_rc "W1 pr status" 0 "$(payload_b s1 'gh pr status')"
expect_rc "W1 pr list" 0 "$(payload_b s1 'gh pr list')"
expect_rc "W1 run view" 0 "$(payload_b s1 'gh run view 123')"
expect_rc "W1 run list" 0 "$(payload_b s1 'gh run list')"
expect_rc "W1 run watch" 0 "$(payload_b s1 'gh run watch 123')"
expect_rc "W1 issue view" 0 "$(payload_b s1 'gh issue view 5')"
expect_rc "W1 issue list" 0 "$(payload_b s1 'gh issue list')"
expect_rc "W1 repo view" 0 "$(payload_b s1 'gh repo view')"
expect_rc "W1 search prs" 0 "$(payload_b s1 'gh search prs --author=@me --state=open')"
expect_rc "W1 auth status" 0 "$(payload_b s1 'gh auth status')"

case_gate w2
expect_rc "W2 pr merge is a known non-comment write" 0 "$(payload_b s1 'gh pr merge --squash --match-head-commit abc123')"

# --- X: an internal error on a gh-mentioning command fails closed ----------

case_gate x1
X1_RC=$(HOOK="$HOOK" GATE="$GATE" python3 - <<'PY'
import importlib.util, io, json, os, sys
sys.path.insert(0, "claude/hooks")
os.environ["HERDR_ENV"] = "1"
os.environ["DOTFILES_POST_GATE_DIR"] = os.environ["GATE"]
spec = importlib.util.spec_from_file_location("g_forced", os.environ["HOOK"])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def boom(command, depth=0, cwd=""):
    raise RuntimeError("forced")


g.classify = boom
payload = {
    "hook_event_name": "PreToolUse",
    "session_id": "s1",
    "tool_name": "Bash",
    "tool_input": {"command": "gh pr comment 5 --body x"},
}
sys.stdin = io.StringIO(json.dumps(payload))
print(g.main())
PY
)
if [ "$X1_RC" = 0 ]; then
    printf 'PASS  X1 forced classify() exception fails open (the shim still gates)\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  X1 forced classify() exception fails open (the shim still gates) (got %s)\n' "$X1_RC" >&2; FAIL=$((FAIL + 1))
fi

case_gate x2
X2_RC=$(HOOK="$HOOK" GATE="$GATE" python3 - <<'PY'
import importlib.util, io, json, os, sys
sys.path.insert(0, "claude/hooks")
os.environ.pop("HERDR_ENV", None)
os.environ["DOTFILES_POST_GATE_DIR"] = os.environ["GATE"]
spec = importlib.util.spec_from_file_location("g_forced2", os.environ["HOOK"])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def boom(command, depth=0, cwd=""):
    raise RuntimeError("forced")


g.classify = boom
payload = {
    "hook_event_name": "PreToolUse",
    "session_id": "s1",
    "tool_name": "Bash",
    "tool_input": {"command": "gh pr comment 5 --body x"},
}
sys.stdin = io.StringIO(json.dumps(payload))
print(g.main())
PY
)
if [ "$X2_RC" = 0 ]; then
    printf 'PASS  X2 forced classify() exception outside herdr still exits 0\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  X2 forced classify() exception outside herdr still exits 0 (got %s)\n' "$X2_RC" >&2; FAIL=$((FAIL + 1))
fi

# --- H: second-layer rules for the exec-time gh shim -----------------------

# A PATH with python3 but no shim: the unarmed session case.
mkdir -p "$FIX/py"
ln -s "$(command -v python3)" "$FIX/py/python3"

case_gate h1
expect_rc "H1 mint post" 0 "$(payload_u s1 'post it')"
payload_b s1 'gh pr comment 5 --body x' | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>"$FIX/err"
rc=$?
if [ "$rc" = 2 ] && grep -q 'Relaunch' "$FIX/err"; then
    printf 'PASS  H1 go not honored when gh on PATH is not the shim\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 go not honored when gh on PATH is not the shim (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi
payload_b s1 'gh pr view 5' | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then
    printf 'PASS  H1 reads are denied too when the shim is not armed\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 reads are denied too when the shim is not armed (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi
payload_b s1 'g""h pr comment 5 --body x' | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then
    printf 'PASS  H1 quote-split gh is denied too when the shim is not armed\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 quote-split gh is denied too when the shim is not armed (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi
unarmed_heredoc='bash <<EOF
gh pr comment 5 --body x
EOF'
payload_b s1 "$unarmed_heredoc" | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then
    printf 'PASS  H1 gh in a heredoc is denied too when the shim is not armed\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 gh in a heredoc is denied too when the shim is not armed (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi
payload_b s1 'ls -l' | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ]; then
    printf 'PASS  H1 commands without gh pass when the shim is not armed\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 commands without gh pass when the shim is not armed (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi

case_gate h2
expect_rc "H2 mint post" 0 "$(payload_u s1 'post it')"
expect_rc "H2 path-qualified gh denied even with a go" 2 "$(payload_b s1 '/opt/homebrew/bin/gh pr view 5')"
expect_rc "H2 path-qualified gh inside bash -c denied" 2 "$(payload_b s1 "bash -c '/opt/homebrew/bin/gh pr view 5'")"
expect_rc "H2 path-qualified gh behind timeout denied" 2 "$(payload_b s1 'timeout 5 /opt/homebrew/bin/gh pr comment 5 --body x')"
expect_rc "H2 path-qualified gh in an eval script denied" 2 "$(payload_b s1 "eval '/opt/homebrew/bin/gh pr comment 5 --body x'")"
expect_rc "H2 shell behind a runner is checked" 2 "$(payload_b s1 "timeout 60 bash -c '/opt/homebrew/bin/gh pr comment 5 --body x'")"
expect_rc "H2 login sh behind a runner denied" 2 "$(payload_b s1 "timeout 60 sh -lc 'gh pr comment 5 --body x'")"
expect_rc "H2 pane text behind a flagged env denied" 2 "$(payload_b s1 "env -u FOO herdr pane run w1:p3 'gh pr comment 5 --body x'")"
expect_rc "H2 backtick-built gh path denied" 2 "$(payload_b s1 '`brew --prefix`/bin/gh pr comment 5 --body x')"
expect_rc "H2 substituted path-qualified gh denied" 2 "$(payload_b s1 '$(brew --prefix)/bin/gh pr view 5')"
expect_rc "H2 login sh denied even with a go" 2 "$(payload_b s1 "sh -lc 'gh pr comment 5 --body x'")"
expect_rc "H2 login dash denied" 2 "$(payload_b s1 'dash -l -c true')"
expect_rc "H2 sh --login denied" 2 "$(payload_b s1 'sh --login -c true')"
expect_rc "H2 bash --posix login denied" 2 "$(payload_b s1 'bash --posix -l -c true')"
expect_rc "H2 zsh --emulate login denied" 2 "$(payload_b s1 'zsh --emulate sh -l -c true')"
expect_rc "H2 interactive login bash denied" 2 "$(payload_b s1 "bash -lic 'gh pr comment 5 --body x'")"
expect_rc "H2 split interactive login bash flags denied" 2 "$(payload_b s1 'bash -l -i -c true')"
expect_rc "H2 gh sent to another pane denied" 2 "$(payload_b s1 "herdr pane run w1:p3 'gh pr view 5'")"
expect_rc "H2 quote-split gh sent to another pane denied" 2 "$(payload_b s1 "herdr pane send-text w1:p3 'g\"\"h pr comment 5 --body x'")"

case_gate h3
expect_rc "H3 login bash passes (BASH_ENV anchors it)" 0 "$(payload_b s1 "bash -lc 'gh pr view 5'")"
expect_rc "H3 login zsh passes (.zprofile anchors it)" 0 "$(payload_b s1 "zsh -lc 'gh pr view 5'")"
expect_rc "H3 timeout wrapper passes (the shim gates at exec)" 0 "$(payload_b s1 'timeout 60 gh run watch 1')"
expect_rc "H3 repo clone passes" 0 "$(payload_b s1 'gh repo clone o/r')"
expect_rc "H3 ANSI-C elsewhere in the command passes" 0 "$(payload_b s1 "echo \$'a' && gh pr view 5")"
expect_rc "H3 git add of the shim path passes" 0 "$(payload_b s1 'git add bin/herdr-shims/gh')"
expect_rc "H3 a runner in front of git add passes" 0 "$(payload_b s1 'env -u HERDR_ENV git add bin/herdr-shims/gh')"
expect_rc "H3 a runner in front of cat passes" 0 "$(payload_b s1 'timeout 5 cat bin/herdr-shims/gh')"
expect_rc "H3 a backtick in single quotes passes" 0 "$(payload_b s1 "git commit -m 'run \`/opt/homebrew/bin/gh\` by hand'")"
expect_rc "H3 sh -c with an -l argument passes" 0 "$(payload_b s1 "sh -c 'ls -l'")"
expect_rc "H3 other text sent to a pane passes" 0 "$(payload_b s1 "herdr pane run w1:p3 'ls -l'")"
expect_rc "H3 a gh-named task id sent to a pane passes" 0 "$(payload_b s1 "herdr pane run w1:p3 'python3 core.py run-mech --task-id 2026-09-25-fix-gh-shim'")"
expect_rc "H3 help on an alias stays unknown and passes the hook" 0 "$(payload_b s1 'gh c 5 --help')"

# --- PA: gh api argv is split the way gh splits it --------------------------

# expect_class LABEL WANT ARG... -> classify_gh verdict for one gh argv
expect_class() {
    label="$1"; want="$2"; shift 2
    got=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import pr_post_guard; print(pr_post_guard.classify_gh(sys.argv[2:]))' "$(dirname "$HOOK")" "$@")
    if [ "$got" = "$want" ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (want %s got %s)\n' "$label" "$want" "$got" >&2; FAIL=$((FAIL + 1))
    fi
}

expect_class "PA1 clustered -iX DELETE is a delete" delete api -iX DELETE repos/o/r/issues/comments/1
expect_class "PA2 clustered -if field is a post" post api -ifbody=x repos/o/r/issues/1/comments
expect_class "PA3 clustered -iF graphql query file is a post" post api graphql -iF query=@m.graphql
expect_class "PA4 -X=GET is a read" read api -X=GET repos/o/r/issues/1
expect_class "PA5 an unknown short flag is a plain write" write api -Z repos/o/r/issues/1
expect_class "PA6 a value flag takes a dash-led next arg; fields still post" post api -t -iXGET repos/o/r/issues/1/comments -f body=hi
expect_class "PA7 -q taking -iXGET keeps the DELETE" delete api -X DELETE -q -iXGET repos/o/r/issues/comments/1
expect_class "PA8 plain -X DELETE is still a delete" delete api -X DELETE repos/o/r/issues/comments/1
expect_class "PA9 a paginated read is still a read" read api repos/o/r/issues/1/comments --paginate

case_gate pa10
expect_rc "PA10 the hook denies a clustered delete without a go" 2 "$(payload_b s1 'gh api -iX DELETE repos/o/r/issues/comments/1')"

# --- C: classifier entries and the pid map the gh shim reads ---------------

case_gate c1
expect_rc "C1 help on a gated subcommand is a read" 0 "$(payload_b s1 'gh pr comment 5 --help')"
expect_rc "C1 graphql query from a file is gated" 2 "$(payload_b s1 'gh api graphql -F query=@m.graphql')"
expect_rc "C1 graphql query from stdin is gated" 2 "$(payload_b s1 'gh api graphql --input -')"

case_gate h4
expect_rc "H4 prompt writes the pid map" 0 "$(payload_u s1 'thanks')"
if [ "$(cat "$GATE"/pid-*.sid 2>/dev/null)" = s1 ] && [ "$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$GATE"/pid-*.sid)" = 0o600 ]; then
    printf 'PASS  H4 pid map holds the session id, mode 0600\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H4 pid map holds the session id, mode 0600\n' >&2; FAIL=$((FAIL + 1))
fi

case_gate h5
: >"$GATE"
expect_rc "H5 an unwritable gate dir never blocks a prompt" 0 "$(payload_u s1 'thanks')"

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

# --- P: personal repositories post without a go -------------------------

case_gate p1
NOSHIM_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'herdr-shims' | paste -sd: -)
P1_PAYLOAD=$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 1 --body x')
printf '%s' "$P1_PAYLOAD" | PATH="$NOSHIM_PATH" python3 "$HOOK" >"$FIX/out" 2>"$FIX/err"
p1rc=$?
if [ "$p1rc" = 0 ]; then
    printf 'PASS  P1 personal unarmed comment passes\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  P1 personal unarmed comment (rc=%s)\n' "$p1rc" >&2; FAIL=$((FAIL + 1))
fi
expect_rc "P2 personal armed pr comment no go" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 1 --body x')"
expect_rc "P3 personal armed pr edit body no go" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr edit 1 --body x')"
expect_rc "P4 work armed pr comment no go" 2 "$(payload_b s1 'gh pr comment 1 --body x')"
expect_rc "P5 work armed pr edit body no go" 2 "$(payload_b s1 'gh pr edit 1 --body x')"

# --- V1x: options before the subcommand pair and other spellings stay gated --

case_gate v1x
expect_class "V1x-1 -R between the subcommand words is a post" post pr -R o/r comment 5 --body x
expect_class "V1x-2 an unknown flag before the pair is skipped" post --paginate pr comment 5 --body x
expect_class "V1x-3 attached close comment -cbye is a post" post pr close 5 -cbye
expect_class "V1x-4 --comment=bye on issue close is a post" post issue close 5 --comment=bye
expect_class "V1x-5 a close without a comment is a plain write" write pr close 5 --delete-branch
expect_class "V1x-6 a query string on a body path is still a body edit" body api -X PATCH "repos/o/r/pulls/5?x=1" -f body=x
expect_class "V1x-7 a fragment on a comment path is still a post" post api "repos/o/r/issues/5/comments#top" -f body=x
expect_class "V1x-8 a query string on a comment delete is still a delete" delete api -X DELETE "repos/o/r/issues/comments/9?x=1"
expect_rc "V1x-9 hook denies -R between the words with no go" 2 "$(payload_b s1 'gh pr -R o/r comment 5 --body x')"
expect_rc "V1x-10 hook denies attached close comment with no go" 2 "$(payload_b s1 'gh pr close 5 -cbye')"
expect_rc "V1x-11 hook denies a query-string body edit with no go" 2 "$(payload_b s1 'gh api -X PATCH repos/o/r/pulls/5?x=1 -f body=x')"

# --- V2x: a negation or question is not a go -------------------------------

for text in 'never post it' 'Do not ever post it.' "you don't need to post it" 'did you post it?' 'no post it' 'not now, post all later? never post all'; do
    case_gate v2x
    rm -rf "$GATE"
    expect_rc "V2x [$text] mints nothing" 0 "$(payload_u s1 "$text")"
    expect_file "V2x [$text] no marker" "$GATE/s1.json" absent
done
case_gate v2y
expect_rc "V2y a later plain sentence still mints" 0 "$(payload_u s1 'Did you post it? Post it now.')"
expect_file "V2y marker written" "$GATE/s1.json" present
case_gate v2z
expect_rc "V2z negation in an earlier sentence does not block a later go" 0 "$(payload_u s1 "I don't like it. Ok, post all")"
expect_file "V2z marker written" "$GATE/s1.json" present

# --- T: the personal exemption follows the post target, not the cwd --------

case_gate t1
expect_rc "T1 personal cwd, -R to a work repo needs a go" 2 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 5 -R work-org/repo --body x')"
expect_rc "T1 personal cwd, --repo= to a work repo needs a go" 2 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 5 --repo=work-org/repo --body x')"
expect_rc "T1 personal cwd, api path to a work repo needs a go" 2 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh api repos/work-org/repo/issues/5/comments -f body=x')"
GH_REPO=work-org/repo
export GH_REPO
expect_rc "T1 personal cwd, GH_REPO on a work repo needs a go" 2 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 5 --body x')"
unset GH_REPO
expect_rc "T1 personal cwd, -R to its own origin needs none" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 5 -R me/repo --body x')"
expect_rc "T1 personal cwd, api path to its own origin needs none" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh api repos/me/repo/issues/5/comments -f body=x')"
expect_rc "T1 personal cwd, no target needs none" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 5 --body x')"
expect_rc "T1 work cwd, -R to the personal login still needs a go" 2 "$(payload_b s1 'gh pr comment 5 -R me/repo --body x')"

# --- AU/MN/GR/PB: pure helpers the gh shim decides with --------------------

# expect_py LABEL WANT CODE -> stdout of CODE run with pr_post_guard as g
expect_py() {
    label="$1"; want="$2"; code="$3"
    got=$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import pr_post_guard as g; $code" "$(dirname "$HOOK")" 2>&1)
    if [ "$got" = "$want" ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (want %s got %s)\n' "$label" "$want" "$got" >&2; FAIL=$((FAIL + 1))
    fi
}

expect_py "AU1 a reply is gated even on an own PR" gated 'print(g.audience("reply", True, ("text", "hi")))'
expect_py "AU2 a comment on another author PR is gated" gated 'print(g.audience("post", False, ("text", "hi")))'
expect_py "AU3 an own-PR edit with no body is maintenance" maintenance 'print(g.audience("body", True, ("none", None)))'
expect_py "AU4 an own-PR edit with an unreadable body is gated" gated 'print(g.audience("body", True, ("unreadable", None)))'
expect_py "AU5 an own-PR edit that mentions someone is gated" gated 'print(g.audience("body", True, ("text", "see @rev")))'
expect_py "AU6 an own-PR body edit is maintenance" maintenance 'print(g.audience("body", True, ("text", "new counts")))'
expect_py "AU7 an own-PR comment with no body is gated" gated 'print(g.audience("post", True, ("none", None)))'
expect_py "AU8 an APPROVE marker on an own PR is green" green 'print(g.audience("post", True, ("text", "<!-- co-review: sha=" + "a" * 40 + " base=" + "b" * 40 + " base_ref=main verdict=APPROVE round=1 -->\nVerdict: APPROVE")))'
expect_py "AU9 a CHANGES marker on an own PR is gated" gated 'print(g.audience("post", True, ("text", "<!-- co-review: sha=" + "a" * 40 + " base=" + "b" * 40 + " base_ref=main verdict=CHANGES round=2 -->\nVerdict: CHANGES")))'
expect_py "AU10 a truncated marker on an own PR is gated" gated 'print(g.audience("post", True, ("text", "<!-- co-review: sha=abc")))'
expect_py "AU11 a free comment on an own PR is own-comment" own-comment 'print(g.audience("post", True, ("text", "bench: 12/12 passed")))'

expect_py "MN1 an at-login mentions a person" True 'print(g.mentions_person("thanks @rev"))'
expect_py "MN2 an email address does not" False 'print(g.mentions_person("mail a@b.com"))'
expect_py "MN3 an inline code span does not" False 'print(g.mentions_person("use `@dataclass` here"))'
expect_py "MN4 a fenced code block does not" False 'print(g.mentions_person("```\n@x\n```\nok"))'
expect_py "MN5 a parenthesised mention does" True 'print(g.mentions_person("(@rev)"))'

expect_py "GR1 post it" it 'print(",".join(sorted(g.go_request("post it"))))'
expect_py "GR2 post all and a hash in one prompt" 1a2b3c4d,all 'print(",".join(sorted(g.go_request("post all and post 1A2B3C4D"))))'
expect_py "GR3 edit the pr body is not a go" "" 'print(",".join(sorted(g.go_request("then edit the pr body"))))'
expect_py "GR4 a negated post all is not a go" "" 'print(",".join(sorted(g.go_request("never post all"))))'
expect_py "GR5 a backticked post it is not a go" "" 'print(",".join(sorted(g.go_request("Type `post it` now."))))'

expect_py "PB1 a stdin body file is unreadable" "unreadable None" 'print(*g.post_body(["pr", "comment", "5", "--body-file", "-"], "."))'
expect_py "PB2 a --body value is the text" "text hi" 'print(*g.post_body(["pr", "comment", "5", "-b", "hi"], "."))'
expect_py "PB3 a gh api body field is the text" "text x" 'print(*g.post_body(["api", "repos/o/r/issues/5/comments", "-f", "body=x"], "."))'

# --- DH/DR/DS: draft hash, registration and state files ---------------------

DH1_OUT=$(HOOK="$HOOK" FIX="$FIX" python3 - <<'PY'
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.environ["HOOK"]))
import pr_post_guard as g
d = os.path.join(os.environ["FIX"], "dh1")
os.makedirs(d)
subprocess.run(["git", "init", "-q", d], check=True)
subprocess.run(["git", "-C", d, "remote", "add", "origin", "https://github.com/o/r.git"], check=True)
with open(os.path.join(d, "r.md"), "w") as f:
    f.write("reply one")
argv = ["pr", "review", "5", "-c", "-F", "r.md"]
first = g.draft_hash(argv, d)
same = first == g.draft_hash(argv, d)
with open(os.path.join(d, "r.md"), "w") as f:
    f.write("reply two")
byte = first != g.draft_hash(argv, d)
with open(os.path.join(d, "r.md"), "w") as f:
    f.write("reply one")
token = first != g.draft_hash(["pr", "review", "6", "-c", "-F", "r.md"], d)
os.environ["GH_REPO"] = "o/other"
repo = first != g.draft_hash(argv, d)
del os.environ["GH_REPO"]
subprocess.run(["git", "-C", d, "remote", "set-url", "origin", "https://github.com/x/r.git"], check=True)
origin = first != g.draft_hash(argv, d)
print(len(first), same, byte, token, repo, origin)
PY
)
if [ "$DH1_OUT" = "8 True True True True True" ]; then
    printf 'PASS  DH1 draft_hash is stable and binds body bytes, argv, GH_REPO and origin\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DH1 draft_hash binding (got %s)\n' "$DH1_OUT" >&2; FAIL=$((FAIL + 1))
fi

expect_py "DH2 a stdin or editor body has no draft hash" "None None" 'print(g.draft_hash(["pr", "comment", "5", "--body-file", "-"], "."), g.draft_hash(["pr", "comment", "5", "-e"], "."))'

case_gate dr1
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>"$FIX/err"; rc=$?
h=$(sed -n '1s/^draft \([0-9a-f]\{8\}\): gh pr review 5 -c -b hi$/\1/p' "$FIX/out")
if [ "$rc" = 0 ] && [ -n "$h" ] && [ "$(sed -n 2p "$FIX/out")" = hi ] \
    && python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); sys.exit(0 if r["batch"] == "initial" and r["v"] == 2 else 1)' "$GATE/s1.draft-$h.pending"; then
    printf 'PASS  DR1 draft prints its hash and body and records a pending draft\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR1 draft registration (rc=%s out=%s err=%s)\n' "$rc" "$(cat "$FIX/out")" "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
fi
mv "$GATE/s1.draft-$h.pending" "$GATE/s1.draft-$h.approved"
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
if [ "$(cat "$FIX/out")" = "draft $h already approved" ] && [ ! -e "$GATE/s1.draft-$h.pending" ] && [ -e "$GATE/s1.draft-$h.approved" ]; then
    printf 'PASS  DR2 re-showing an approved draft leaves the approval alone\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR2 re-showing an approved draft (out=%s)\n' "$(cat "$FIX/out")" >&2; FAIL=$((FAIL + 1))
fi

case_gate dr3
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
h=$(sed -n '1s/^draft \([0-9a-f]\{8\}\).*/\1/p' "$FIX/out")
mv "$GATE/s1.draft-$h.pending" "$GATE/s1.draft-$h.dismissed"
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >/dev/null 2>&1
if [ -e "$GATE/s1.draft-$h.pending" ] && [ ! -e "$GATE/s1.draft-$h.dismissed" ]; then
    printf 'PASS  DR3 re-showing a dismissed draft makes it pending again\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR3 re-showing a dismissed draft\n' >&2; FAIL=$((FAIL + 1))
fi

case_gate dr4
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID python3 "$HOOK" draft -- gh pr review 5 -c -b hi >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ ! -e "$GATE" ]; then
    printf 'PASS  DR4 draft without a session id refuses\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR4 draft without a session id (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi

case_gate dr5
printf 'x' | python3 "$HOOK" draft -- gh pr comment 5 --body-file - >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ ! -e "$GATE" ]; then
    printf 'PASS  DR5 draft of a stdin body refuses\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR5 draft of a stdin body (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi

case_gate dr6
mkdir -p "$GATE"
printf 'b1' >"$GATE/s1.batch"
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
h=$(sed -n '1s/^draft \([0-9a-f]\{8\}\).*/\1/p' "$FIX/out")
if python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1]))["batch"] == "b1" else 1)' "$GATE/s1.draft-$h.pending"; then
    printf 'PASS  DR6 a draft is stamped with the current batch\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR6 batch stamp\n' >&2; FAIL=$((FAIL + 1))
fi

case_gate dr7
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
h=$(sed -n '1s/^draft \([0-9a-f]\{8\}\).*/\1/p' "$FIX/out")
mv "$GATE/s1.draft-$h.pending" "$GATE/s1.draft-$h.spent"
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
if grep -q "^\[WARNING\] draft $h already ran once; read the PR first: a duplicate is possible$" "$FIX/out" && [ -e "$GATE/s1.draft-$h.pending" ]; then
    printf 'PASS  DR7 re-showing a spent draft warns that a duplicate is possible\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR7 duplicate warning (out=%s)\n' "$(cat "$FIX/out")" >&2; FAIL=$((FAIL + 1))
fi

case_gate ds1
DS1_OUT=$(HOOK="$HOOK" GATE="$GATE" python3 - <<'PY'
import json, os, sys
from pathlib import Path
sys.path.insert(0, os.path.dirname(os.environ["HOOK"]))
import pr_post_guard as g
d = Path(os.environ["GATE"])
d.mkdir()
(d / "s1.draft-aaaaaaaa.pending").write_text(json.dumps({"v": 2, "batch": "x", "created": 1, "argv": []}))
(d / "s1.draft-bbbbbbbb.pending").write_text(json.dumps({"v": 2, "batch": "y", "created": 2, "argv": []}))
g.approve_drafts(d, "s1", {"all"}, "x")
print(sorted(p.name for p in d.iterdir()))
PY
)
if [ "$DS1_OUT" = "['s1.draft-aaaaaaaa.approved', 's1.draft-bbbbbbbb.dismissed']" ]; then
    printf 'PASS  DS1 post all approves only the closing batch and dismisses the rest\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DS1 batch-scoped approval (got %s)\n' "$DS1_OUT" >&2; FAIL=$((FAIL + 1))
fi

case_gate ds2
mkdir -p "$GATE"
: >"$GATE/s1.draft-cccccccc.approved"
expect_py "DS2 an approved draft spends exactly once" "True False" "from pathlib import Path; d = Path('$GATE'); print(g.spend_draft(d, 's1', 'cccccccc'), g.spend_draft(d, 's1', 'cccccccc'))"

case_gate ds3
mkdir -p "$GATE"
: >"$GATE/s1.draft-eeeeeeee.approved"
python3 -c 'import os, sys, time; old = time.time() - 2 * 86400; os.utime(sys.argv[1], (old, old))' "$GATE/s1.draft-eeeeeeee.approved"
expect_py "DS3 a late spend survives the next prune" "True True" "import time; from pathlib import Path; d = Path('$GATE'); ok = g.spend_draft(d, 's1', 'eeeeeeee'); g.prune(d, time.time()); print(ok, (d / 's1.draft-eeeeeeee.spent').exists())"

case_gate ds4
mkdir -p "$GATE"
printf '{"v":2,"batch":"initial","created":1,"argv":[]}' >"$GATE/s1.draft-ffffffff.pending"
python3 -c 'import os, sys, time; old = time.time() - 2 * 86400; os.utime(sys.argv[1], (old, old))' "$GATE/s1.draft-ffffffff.pending"
expect_py "DS4 an old draft approved now survives the next prune" "True" "import time; from pathlib import Path; d = Path('$GATE'); g.approve_drafts(d, 's1', {'ffffffff'}, 'x'); g.prune(d, time.time()); print((d / 's1.draft-ffffffff.approved').exists())"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
