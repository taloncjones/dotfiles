#!/bin/sh
# gh-shim.test.sh -- hermetic exec-time tests for the herdr gh shim
# (bin/herdr-shims/gh -> gh_post_shim.py) and its PATH anchor.
#
# A fake "real gh" logs its argv; DOTFILES_REAL_GH points the shim at it.
# HOME, GH_CONFIG_DIR and cwd are throwaway and token variables are unset, so
# an accidental real gh can neither authenticate nor find a repo. Every
# shape runs through a real shell, after quoting and substitution.
set -u

PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

REPO=$(pwd)
SHIMS="$REPO/bin/herdr-shims"
HOOK="$REPO/claude/hooks/pr_post_guard.py"
PASS=0
FAIL=0

T=$(mktemp -d /tmp/gh-shim-test.XXXXXX)
[ -n "$T" ] && [ -d "$T" ] || { printf 'FAIL  cannot create the fixture root\n' >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/fake" "$T/home" "$T/ghc" "$T/work" "$T/zdot"
cat >"$T/fake/gh" <<'FAKE'
#!/bin/sh
# The shim's ownership reads before a delete are answered here and logged
# apart, so FAKE_LOG still counts only the commands the shim execs. A read
# made with a TTY-forcing env gets colored junk, as real gh would print.
case "$*" in
    "pr view "*"--json author"*|"pr view --json author"*)
        printf '%s\n' "$*" >>"$FAKE_GETLOG"
        [ "${FAKE_PR_RC:-0}" = 0 ] || exit "$FAKE_PR_RC"
        printf '{"author":{"login":"%s"},"url":"https://%s/o/r/pull/5"}\n' "$FAKE_PR_AUTHOR" "${FAKE_PR_HOST:-github.com}"
        exit 0
        ;;
    "api user"*|"api repos/"*"/comments/"*)
        printf '%s\n' "$*" >>"$FAKE_GETLOG"
        if [ -n "${GH_FORCE_TTY:-}${CLICOLOR_FORCE:-}" ] || [ "${NO_COLOR:-}" != 1 ]; then
            printf '\033[1;38m{\033[m\n'
            exit 0
        fi
        case "$*" in
            "api user"*) printf '{"login":"me"}\n' ;;
            *) printf '%s\n' "$FAKE_COMMENT" ;;
        esac
        exit "${FAKE_GET_RC:-0}"
        ;;
esac
printf '%s\n' "$*" >>"$FAKE_LOG"
[ -n "${FAKE_STDIN:-}" ] && cat >"$FAKE_STDIN"
[ -n "${FAKE_OUT:-}" ] && printf '%s\n' "$FAKE_OUT"
exit "${FAKE_RC:-0}"
FAKE
chmod +x "$T/fake/gh"
printf '. "%s"\n' "$SHIMS/path.sh" >"$T/zdot/.zprofile"
printf 'gh pr comment 5 --body x\n' >"$T/work/post.sh"
printf 'query { viewer { login } }\n' >"$T/work/m.graphql"
printf '{"query":"mutation { x }"}\n' >"$T/work/m.json"

unset CLAUDE_PERSONAL_ONLY GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN FAKE_STDIN FAKE_OUT FAKE_RC
# A stray real gh could neither authenticate nor reach github.com.
export HOME="$T/home" GH_CONFIG_DIR="$T/ghc" GH_HOST=gh-shim-test.invalid ZDOTDIR="$T/zdot"
export BASH_ENV="$SHIMS/path.sh"
export DOTFILES_REAL_GH="$T/fake/gh" CLAUDE_CODE_SESSION_ID=s1 HERDR_ENV=1
export FAKE_LOG="$T/log"
# The shim reads a post target's author; FAKE_PR_AUTHOR=me marks it our own.
export FAKE_PR_AUTHOR=rev
unset CLAUDE_PID FAKE_PR_RC FAKE_PR_HOST
MARK='<!-- co-review: sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb base_ref=main verdict=CHANGES round=1 -->'
export FAKE_GETLOG="$T/getlog" FAKE_COMMENT="{\"user\":{\"login\":\"me\"},\"body\":\"$MARK\\nVerdict: CHANGES\"}"
unset GH_FORCE_TTY CLICOLOR_FORCE
export PATH="$SHIMS:$T/fake:/usr/bin:/bin"
cd "$T/work" || exit 1
# Without the launcher, login-shell shapes below would reach the real gh.
[ -x "$SHIMS/gh" ] || { printf 'FAIL  %s/gh is missing; no case runs without the shim\n' "$SHIMS" >&2; exit 1; }
ZSH=$(command -v zsh)
BASH=$(command -v bash)

N=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# fresh_gate: new empty gate dir and fake log for the next case
fresh_gate() {
    N=$((N + 1))
    export DOTFILES_POST_GATE_DIR="$T/gate-$N"
    : >"$FAKE_LOG"
}

# approve HASH: the real hook's PostToolUse handler answers "Post draft HASH"
# for s1, with the draft's registered text in the option preview
approve() {
    AP_HASH="$1" python3 - <<'PY' | python3 "$HOOK" >/dev/null 2>&1
import json, os
d, h = os.environ["DOTFILES_POST_GATE_DIR"], os.environ["AP_HASH"]
try:
    text = json.load(open(os.path.join(d, f"s1.draft-{h}.pending"))).get("text") or ""
except (OSError, ValueError, AttributeError):
    text = ""
q, label = "Post this draft?", f"Post draft {h}"
qs = [{"question": q, "multiSelect": False,
       "options": [{"label": label, "description": "posts it", "preview": text},
                   {"label": f"Skip draft {h}", "description": "skips it"}]}]
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "AskUserQuestion",
                  "tool_input": {"questions": qs}, "tool_response": {"questions": qs, "answers": {q: label}}}))
PY
}

# typed TEXT: the real hook's UserPromptSubmit handler sees a typed message from s1
typed() {
    TY_TEXT="$1" python3 -c 'import json, os; print(json.dumps({"hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": os.environ["TY_TEXT"]}))' \
        | python3 "$HOOK" >/dev/null 2>&1
}

# draft ARG...: register a draft of `gh ARG...` for s1 from the cwd; prints its hash
draft() {
    python3 "$HOOK" draft -- gh "$@" 2>/dev/null | sed -n '1s/^draft \([0-9a-f]\{8\}\).*/\1/p'
}

log_lines() { wc -l <"$FAKE_LOG" | tr -d ' '; }

# --- S: shim behavior on a plain `gh` --------------------------------------

fresh_gate
FAKE_OUT=hello FAKE_RC=3 gh pr view 5 --json comments >"$T/out" 2>"$T/err"
rc=$?
if [ "$rc" = 3 ] && [ "$(cat "$T/out")" = hello ] && [ "$(cat "$FAKE_LOG")" = "pr view 5 --json comments" ]; then
    pass "S1 read passes argv, stdout and exit status through"
else
    fail "S1 read passes argv, stdout and exit status through (rc=$rc out=$(cat "$T/out") log=$(cat "$FAKE_LOG"))"
fi

fresh_gate
mkdir -p "$HOME/Git/personal/repo"
git init -q "$HOME/Git/personal/repo"
git -C "$HOME/Git/personal/repo" remote add origin https://github.com/me/repo.git
(cd "$HOME/Git/personal/repo" && gh pr comment 5 --body x >/dev/null 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$FAKE_LOG")" = "pr comment 5 --body x" ]; then
    pass "S1b personal repository posts without a go"
else
    fail "S1b personal repository posts without a go (rc=$rc log=$(cat "$FAKE_LOG"))"
fi

fresh_gate
(cd "$HOME/Git/personal/repo" && gh pr comment 5 -R work-org/repo --body x >/dev/null 2>&1); rc1=$?
(cd "$HOME/Git/personal/repo" && GH_REPO=work-org/repo gh pr comment 5 --body x >/dev/null 2>&1); rc2=$?
(cd "$HOME/Git/personal/repo" && gh pr comment 5 -R me/repo --body x >/dev/null 2>&1); rc3=$?
if [ "$rc1$rc2$rc3" = 110 ] && [ "$(cat "$FAKE_LOG")" = "pr comment 5 -R me/repo --body x" ]; then
    pass "S1c personal cwd posting to a work repo needs a go; its own origin needs none"
else
    fail "S1c personal cwd target keying (rc=$rc1$rc2$rc3 log=$(cat "$FAKE_LOG"))"
fi

fresh_gate
printf 'body-from-stdin' | FAKE_STDIN="$T/stdin" gh api -X POST repos/o/r/labels --input - >/dev/null 2>&1
if [ "$(cat "$T/stdin" 2>/dev/null)" = body-from-stdin ]; then
    pass "S2 a plain write passes stdin through"
else
    fail "S2 a plain write passes stdin through"
fi

fresh_gate
gh repo delete o/r --yes >/dev/null 2>"$T/err"; rc1=$?
gh extension install o/gh-x >/dev/null 2>>"$T/err"; rc2=$?
if [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$(log_lines)" = 2 ]; then
    pass "S3 subcommands outside the tables pass through as plain writes"
else
    fail "S3 subcommands outside the tables pass through (rc=$rc1/$rc2 log=$(log_lines))"
fi

fresh_gate
gh pr comment 5 --body x >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q "owner's go" "$T/err"; then
    pass "S4 post without a go is denied"
else
    fail "S4 post without a go is denied (rc=$rc log=$(log_lines))"
fi

fresh_gate
h=$(draft pr comment 5 --body x)
approve "$h"
gh pr comment 5 --body x >/dev/null 2>&1; rc1=$?
gh pr comment 5 --body x >/dev/null 2>"$T/err"; rc2=$?
if [ -n "$h" ] && [ "$rc1" = 0 ] && [ "$rc2" = 1 ] && [ "$(log_lines)" = 1 ] && [ -e "$DOTFILES_POST_GATE_DIR/s1.draft-$h.spent" ] && grep -q 'duplicate is possible' "$T/err"; then
    pass "S5 an approved draft execs exactly once and a rerun warns"
else
    fail "S5 an approved draft execs exactly once (h=$h rc=$rc1/$rc2 log=$(log_lines))"
fi

fresh_gate
: >"$T/err"
gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>>"$T/err"; rc1=$?
gh api --method DELETE repos/o/r/issues/comments/8 >/dev/null 2>>"$T/err"; rc2=$?
gh api -X DELETE repos/o/r/issues/comments/7 >/dev/null 2>>"$T/err"; rc3=$?
if [ "$rc1$rc2$rc3" = 000 ] && [ "$(log_lines)" = 3 ] && grep -q 'gh shim: \[INFO\] own marker delete' "$T/err"; then
    pass "S6 own-marker deletes run with no go and print a notice"
else
    fail "S6 own-marker deletes run with no go (rc=$rc1$rc2$rc3 log=$(log_lines))"
fi

fresh_gate
printf 'new counts\n' >b.md
FAKE_PR_AUTHOR=me gh pr edit 5 --body-file b.md >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 0 ] && [ "$(log_lines)" = 1 ] && grep -q 'self-maintenance' "$T/err"; then
    pass "S7 an own-PR body edit runs with no go"
else
    fail "S7 an own-PR body edit (rc=$rc log=$(log_lines))"
fi

# --- O: a delete removes only this account's own co-review marker ----------

fresh_gate
FAKE_COMMENT="{\"user\":{\"login\":\"rev\"},\"body\":\"$MARK\"}" \
    gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q 'own co-review marker' "$T/err"; then
    pass "O1 delete of another author's comment is refused"
else
    fail "O1 delete of another author's comment is refused (rc=$rc log=$(log_lines))"
fi

fresh_gate
FAKE_COMMENT='{"user":{"login":"me"},"body":"thanks, fixed"}' \
    gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "O2 delete of our own non-marker comment is refused"
else
    fail "O2 delete of our own non-marker comment is refused (rc=$rc log=$(log_lines))"
fi

fresh_gate
FAKE_COMMENT='not json' gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc1=$?
FAKE_GET_RC=1 gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc2=$?
if [ "$rc1$rc2" = 11 ] && [ "$(log_lines)" = 0 ]; then
    pass "O3 an unreadable or failed ownership read refuses the delete"
else
    fail "O3 an unreadable or failed ownership read refuses the delete (rc=$rc1$rc2 log=$(log_lines))"
fi

fresh_gate
: >"$FAKE_GETLOG"
gh api --hostname h.example -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ "$(log_lines)" = 1 ] \
    && grep -qx 'api repos/o/r/issues/comments/9 --hostname h.example' "$FAKE_GETLOG" \
    && grep -qx 'api user --hostname h.example' "$FAKE_GETLOG"; then
    pass "O4 ownership reads carry the delete's --hostname"
else
    fail "O4 ownership reads carry the delete's --hostname (rc=$rc log=$(log_lines) get=$(cat "$FAKE_GETLOG"))"
fi

fresh_gate
: >"$FAKE_GETLOG"
GH_FORCE_TTY=1 CLICOLOR_FORCE=1 GH_PAGER=less \
    gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ "$(log_lines)" = 1 ] && [ -s "$FAKE_GETLOG" ]; then
    pass "O5 ownership reads pin a plain output env"
else
    fail "O5 ownership reads pin a plain output env (rc=$rc log=$(log_lines))"
fi
fresh_gate
FAKE_COMMENT="{\"user\":{\"login\":\"rev\"},\"body\":\"$MARK\"}" \
    gh api -iX DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "O6 a clustered -iX DELETE of another author's comment is refused"
else
    fail "O6 a clustered -iX DELETE of another author's comment is refused (rc=$rc log=$(log_lines))"
fi

fresh_gate
typed "edit the pr body"
gh pr edit 5 --body-file b.md >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "S8 a typed edit the pr body approves nothing and another author's PR edit is refused"
else
    fail "S8 edit the pr body (rc=$rc log=$(log_lines))"
fi

fresh_gate
h=$(draft pr review 5 -c -b x)
approve "$h"
CLAUDE_CODE_SESSION_ID=s2 gh pr review 5 -c -b x >/dev/null 2>&1; rc1=$?
env -u CLAUDE_CODE_SESSION_ID gh pr review 5 -c -b x >/dev/null 2>&1; rc2=$?
env -u CLAUDE_CODE_SESSION_ID gh pr view 5 >/dev/null 2>&1; rc3=$?
if [ "$rc1$rc2$rc3" = 110 ] && [ "$(log_lines)" = 1 ]; then
    pass "S9 go is bound to CLAUDE_CODE_SESSION_ID; reads need none"
else
    fail "S9 go is bound to CLAUDE_CODE_SESSION_ID (rc=$rc1$rc2$rc3 log=$(log_lines))"
fi

fresh_gate
h=$(draft pr comment 5 --body --help)
approve "$h"
gh pr comment 5 --help >/dev/null 2>&1; rc1=$?
gh pr comment 5 --body --help >/dev/null 2>&1; rc2=$?
gh pr comment 5 --body --help >/dev/null 2>&1; rc3=$?
if [ "$rc1$rc2$rc3" = 001 ] && [ "$(log_lines)" = 2 ]; then
    pass "S11 --help is a read; --body --help is a post"
else
    fail "S11 help (rc=$rc1$rc2$rc3 log=$(log_lines))"
fi

fresh_gate
gh api graphql -F query=@m.graphql >/dev/null 2>&1; rc1=$?
printf '{}' | gh api graphql --input - >/dev/null 2>&1; rc2=$?
gh alias set c 'pr comment' >/dev/null 2>&1; rc3=$?
gh c 5 --body x >/dev/null 2>&1; rc4=$?
gh c 5 --help >/dev/null 2>&1; rc6=$?
gh status >/dev/null 2>&1; rc5=$?
if [ "$rc1$rc2$rc3$rc4$rc6$rc5" = 110000 ] && [ "$(log_lines)" = 4 ]; then
    pass "S12 graphql from a file or stdin is gated; aliases pass as plain writes"
else
    fail "S12 graphql and aliases (rc=$rc1$rc2$rc3$rc4$rc6$rc5 log=$(cat "$FAKE_LOG"))"
fi

fresh_gate
h=$(draft pr review 5 -c -b x)
approve "$h"
map=$(ls "$DOTFILES_POST_GATE_DIR" | sed -n 's/^pid-\([0-9]*\)\.sid$/\1/p')
CLAUDE_PID="$map" CLAUDE_CODE_SESSION_ID=stale gh pr review 5 -c -b x >/dev/null 2>&1; rc1=$?
CLAUDE_PID="$map" CLAUDE_CODE_SESSION_ID=stale gh pr review 5 -c -b x >/dev/null 2>&1; rc2=$?
if [ -n "$map" ] && [ "$rc1$rc2" = 01 ] && [ "$(log_lines)" = 1 ]; then
    pass "S13 the hook's pid map binds the go past a stale session id"
else
    fail "S13 pid map binding (map=$map rc=$rc1$rc2 log=$(log_lines))"
fi

fresh_gate
h=$(draft pr review 5 -c -b x)
approve "$h"
: >"$T/not-a-dir"
DOTFILES_POST_GATE_DIR="$T/not-a-dir" gh pr review 5 -c -b x >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "S10 an unusable gate dir fails closed"
else
    fail "S10 an unusable gate dir fails closed (rc=$rc log=$(log_lines))"
fi

# --- N: audience classes at exec -------------------------------------------

APPROVE_MARK='<!-- co-review: sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa base=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb base_ref=main verdict=APPROVE round=2 -->'
printf '%s\nVerdict: APPROVE\n' "$APPROVE_MARK" >approve.md
printf '%s\nVerdict: CHANGES\nB1: bug\n' "$MARK" >changes.md
printf 'bench: 12/12 passed\n' >plain.md
printf 'thanks @rev, fixed\n' >mention.md

fresh_gate
FAKE_PR_AUTHOR=me gh pr comment 5 --body-file approve.md >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 0 ] && [ "$(log_lines)" = 1 ] && grep -q 'gh shim: \[INFO\] green evidence on PR 5' "$T/err"; then
    pass "N1 an APPROVE marker on an own PR posts with no go and a notice"
else
    fail "N1 APPROVE marker on an own PR (rc=$rc log=$(log_lines) err=$(cat "$T/err"))"
fi

fresh_gate
FAKE_PR_AUTHOR=me gh pr comment 5 --body-file changes.md >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q 'non-APPROVE co-review marker' "$T/err"; then
    pass "N2 a CHANGES marker on an own PR needs a go"
else
    fail "N2 CHANGES marker on an own PR (rc=$rc log=$(log_lines))"
fi

fresh_gate
gh pr comment 5 --body-file plain.md >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q 'did not author' "$T/err"; then
    pass "N3 a comment on another author's PR needs a go"
else
    fail "N3 comment on another author's PR (rc=$rc log=$(log_lines))"
fi

fresh_gate
FAKE_PR_AUTHOR=me gh pr comment 5 --body-file mention.md >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q '@mentions' "$T/err"; then
    pass "N4 an own-PR comment that mentions someone needs a go"
else
    fail "N4 own-PR comment with a mention (rc=$rc log=$(log_lines))"
fi

fresh_gate
: >"$FAKE_GETLOG"
gh api -X POST repos/o/r/pulls/5/comments/9/replies -f body=x >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && ! grep -q 'pr view' "$FAKE_GETLOG"; then
    pass "N5 a thread reply is refused with no ownership read"
else
    fail "N5 thread reply (rc=$rc log=$(log_lines) get=$(cat "$FAKE_GETLOG"))"
fi

fresh_gate
: >"$FAKE_GETLOG"
FAKE_PR_AUTHOR=me gh pr edit 5 --title t >/dev/null 2>&1; rc1=$?
FAKE_PR_AUTHOR=me gh pr edit 5 --title u >/dev/null 2>&1; rc2=$?
if [ "$rc1$rc2" = 00 ] && [ "$(log_lines)" = 2 ] && [ "$(grep -c '^pr view 5 --json author' "$FAKE_GETLOG")" = 1 ]; then
    pass "N6 the PR author is read once per session and cached"
else
    fail "N6 author cache (rc=$rc1$rc2 log=$(log_lines) get=$(cat "$FAKE_GETLOG"))"
fi

fresh_gate
FAKE_PR_AUTHOR=me FAKE_PR_RC=1 gh pr edit 5 --title t >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "N7 a failed author read refuses"
else
    fail "N7 failed author read (rc=$rc log=$(log_lines))"
fi

fresh_gate
h1=$(draft pr review 5 -c -b one)
h2=$(draft pr review 5 -c -b two)
N8_H1="$h1" N8_H2="$h2" python3 - <<'PY' | python3 "$HOOK" >/dev/null 2>&1
import json, os
qs = [{"question": f"Post reply {n}?", "multiSelect": False,
       "options": [{"label": f"Post draft {h}", "description": "posts it", "preview": n},
                   {"label": f"Skip draft {h}", "description": "skips it"}]}
      for n, h in (("one", os.environ["N8_H1"]), ("two", os.environ["N8_H2"]))]
answers = {q["question"]: q["options"][0]["label"] for q in qs}
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "AskUserQuestion",
                  "tool_input": {"questions": qs}, "tool_response": {"questions": qs, "answers": answers}}))
PY
sh -c 'gh pr review 5 -c -b one && gh pr review 5 -c -b two' >/dev/null 2>&1; rc=$?
if [ -n "$h1" ] && [ -n "$h2" ] && [ "$rc" = 0 ] && [ "$(log_lines)" = 2 ]; then
    pass "N8 one two-question answer covers two drafts in one call"
else
    fail "N8 two-question answer (h=$h1/$h2 rc=$rc log=$(log_lines))"
fi

fresh_gate
h=$(draft pr review 5 -c -b x)
approve "$h"
typed "thanks, and what about the other PR"
gh pr review 5 -c -b x >/dev/null 2>&1; rc=$?
if [ -n "$h" ] && [ "$rc" = 0 ] && [ "$(log_lines)" = 1 ]; then
    pass "N9 a later non-go message keeps an unspent approval"
else
    fail "N9 approval kept (rc=$rc log=$(log_lines))"
fi

fresh_gate
printf 'first text\n' >r.md
h=$(draft pr review 5 -c -F r.md)
approve "$h"
printf 'changed text\n' >r.md
gh pr review 5 -c -F r.md >/dev/null 2>&1; rc=$?
if [ -n "$h" ] && [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "N10 a body changed after approval is refused"
else
    fail "N10 changed body (rc=$rc log=$(log_lines))"
fi

fresh_gate
h=$(draft pr review 5 -c -b x)
typed "post it"
typed "post $h"
gh pr review 5 -c -b x >/dev/null 2>&1; rc=$?
if [ -n "$h" ] && [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "N11 a typed phrase never releases a draft"
else
    fail "N11 typed phrase (rc=$rc log=$(log_lines))"
fi

fresh_gate
h=$(draft pr review 5 -c -b x)
approve "$h"
AP_HASH="$h" python3 - <<'PY' | python3 "$HOOK" >/dev/null 2>&1
import json, os
h = os.environ["AP_HASH"]; q = "Skip this draft?"; label = f"Skip draft {h}"
qs = [{"question": q, "multiSelect": False, "options": [{"label": label, "description": "skips it"}, {"label": "Hold", "description": "waits"}]}]
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "AskUserQuestion", "tool_input": {"questions": qs}, "tool_response": {"questions": qs, "answers": {q: label}}}))
PY
gh pr review 5 -c -b x >/dev/null 2>&1; rc=$?
if [ -n "$h" ] && [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && [ -e "$DOTFILES_POST_GATE_DIR/s1.draft-$h.dismissed" ]; then
    pass "N12 a skip answer withdraws an unspent approval"
else
    fail "N12 withdrawn approval (rc=$rc log=$(log_lines))"
fi

fresh_gate
gh pr review 5 -c -b x >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && grep -q 'AskUserQuestion' "$T/err" && grep -q 'Post draft <hash>' "$T/err" \
    && grep -q 'update --ai' "$T/err" && ! grep -qi 'post it' "$T/err"; then
    pass "N13 the refusal names the prompt and the upgrade fix"
else
    fail "N13 refusal text (rc=$rc err=$(cat "$T/err"))"
fi

fresh_gate
FAKE_PR_AUTHOR=me gh pr comment 5 --body-file plain.md >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 0 ] && [ "$(log_lines)" = 1 ] && grep -q 'gh shim: \[INFO\] own-PR comment on PR 5' "$T/err"; then
    pass "N11 a free comment on an own PR posts with a notice"
else
    fail "N11 own-PR comment (rc=$rc log=$(log_lines))"
fi

fresh_gate
printf 'x' | FAKE_PR_AUTHOR=me gh pr comment 5 --body-file - >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q 'cannot read' "$T/err"; then
    pass "N12 a stdin body is refused as unreadable"
else
    fail "N12 stdin body (rc=$rc log=$(log_lines))"
fi

fresh_gate
: >"$FAKE_GETLOG"
mkdir -p "$T/wrepo"
git init -q "$T/wrepo"
git -C "$T/wrepo" remote add origin https://github.com/o/a.git
(cd "$T/wrepo" && FAKE_PR_AUTHOR=me gh pr edit 5 --title t >/dev/null 2>&1); rc1=$?
git -C "$T/wrepo" remote set-url origin https://github.com/o/b.git
(cd "$T/wrepo" && FAKE_PR_AUTHOR=me gh pr edit 5 --title t >/dev/null 2>&1); rc2=$?
if [ "$rc1$rc2" = 00 ] && [ "$(grep -c '^pr view 5 --json author' "$FAKE_GETLOG")" = 2 ]; then
    pass "N13 a changed origin in the same cwd reads the author again"
else
    fail "N13 origin change (rc=$rc1$rc2 get=$(cat "$FAKE_GETLOG"))"
fi

fresh_gate
: >"$FAKE_GETLOG"
FAKE_PR_AUTHOR=me FAKE_PR_HOST=ghe.example gh api --hostname ghe.example -X POST repos/o/r/issues/5/comments -f body=x >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qx 'pr view 5 --json author,url -R ghe.example/o/r' "$FAKE_GETLOG" \
    && grep -qx 'api user --hostname ghe.example' "$FAKE_GETLOG"; then
    pass "N14 an api --hostname post reads the author and login on that host"
else
    fail "N14 host threading (rc=$rc get=$(cat "$FAKE_GETLOG"))"
fi

fresh_gate
: >"$FAKE_GETLOG"
FAKE_PR_AUTHOR=me gh api -X POST https://ghe.example/api/v3/repos/o/r/issues/5/comments -f body=x >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && ! grep -q 'pr view' "$FAKE_GETLOG"; then
    pass "N15 a full-URL api post is never own and needs a go"
else
    fail "N15 full-URL endpoint (rc=$rc log=$(log_lines) get=$(cat "$FAKE_GETLOG"))"
fi

# --- L: real gh lookup ------------------------------------------------------

mkdir -p "$T/shimcopy" "$T/pyonly"
cp "$SHIMS/gh" "$T/shimcopy/gh"
ln -s "$(command -v python3)" "$T/pyonly/python3"
ln -s "$(command -v sh)" "$T/pyonly/sh"
fresh_gate
env -u DOTFILES_REAL_GH PATH="$SHIMS:$SHIMS:$T/shimcopy:$T/fake:/usr/bin:/bin" \
    perl -e 'alarm 10; exec @ARGV' gh pr view 7 >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$FAKE_LOG")" = "pr view 7" ]; then
    pass "L1 PATH walk skips every shim dir and reaches the real gh"
else
    fail "L1 PATH walk skips every shim dir and reaches the real gh (rc=$rc log=$(cat "$FAKE_LOG"))"
fi

fresh_gate
DOTFILES_REAL_GH="$SHIMS/gh" gh pr view 7 >/dev/null 2>&1; rc1=$?
env -u DOTFILES_REAL_GH PATH="$SHIMS:$T/shimcopy:$T/pyonly" "$SHIMS/gh" pr view 7 >/dev/null 2>"$T/err"; rc2=$?
if [ "$rc1" = 127 ] && [ "$rc2" = 127 ] && [ "$(cat "$T/err")" = "gh shim: real gh not found on PATH" ] && [ "$(log_lines)" = 0 ]; then
    pass "L2 a self-pointing override or no real gh exits 127"
else
    fail "L2 a self-pointing override or no real gh exits 127 (rc=$rc1/$rc2)"
fi

# --- A: PATH anchor ---------------------------------------------------------

want="$SHIMS:/a:/b"
got_bash=$(PATH="/a:$SHIMS:/b:$SHIMS" /bin/sh -c '. "$0"; . "$0"; printf %s "$PATH"' "$SHIMS/path.sh" 2>&1)
got_zsh=$(PATH="/a:$SHIMS:/b:$SHIMS" "$ZSH" -f -c '. "$1"; . "$1"; printf %s "$PATH"' x "$SHIMS/path.sh" 2>&1)
if [ "$got_bash" = "$want" ] && [ "$got_zsh" = "$want" ]; then
    pass "A1 anchor puts the shim dir first once, keeps order, is idempotent (sh, zsh)"
else
    fail "A1 anchor (sh=$got_bash zsh=$got_zsh)"
fi

leak=$(PATH="/usr/bin:/bin:$SHIMS" "$BASH" -eu -c 'x=keep; before=$(set | grep -c "^_dotfiles_" || true); . "$0"; after=$(set | grep -c "^_dotfiles_" || true); echo "$before$after$x"' "$SHIMS/path.sh" 2>&1)
quiet=$(PATH="/a" "$BASH" -eu -c '. "$0"; printf %s "$PATH"' "$SHIMS/path.sh" 2>&1)
if [ "$leak" = 00keep ] && [ "$quiet" = /a ]; then
    pass "A2 anchor leaks no variables, is set -eu safe, and is inert when unarmed"
else
    fail "A2 anchor (leak=$leak unarmed=$quiet)"
fi

got_bl=$(PATH="/usr/bin:/bin:$SHIMS" bash -lc 'command -v gh' 2>/dev/null)
got_zl=$(PATH="/usr/bin:/bin:$SHIMS" zsh -lc 'command -v gh' 2>/dev/null)
if [ "$got_bl" = "$SHIMS/gh" ] && [ "$got_zl" = "$SHIMS/gh" ]; then
    pass "A3 login bash (BASH_ENV) and login zsh (.zprofile) resolve the shim"
else
    fail "A3 login shells resolve the shim (bash=$got_bl zsh=$got_zl)"
fi

# Startup files come through symlinks in a temp ZDOTDIR: they resolve the
# repo through their own path, and compinit writes its dump here, not into zsh/.
mkdir -p "$T/zrepo"
for f in .zshenv .zprofile .zshrc; do ln -s "$REPO/zsh/$f" "$T/zrepo/$f"; done
got_zl=$(ZDOTDIR="$T/zrepo" PATH="/usr/bin:/bin:$SHIMS" "$ZSH" -lc 'command -v gh' 2>/dev/null | tail -1)
got_core=$(env -i HOME="$T/home" GH_CONFIG_DIR="$T/ghc" GH_HOST=gh-shim-test.invalid PATH="$SHIMS:/usr/bin:/bin" ZDOTDIR="$T/zrepo" "$ZSH" -lc 'command -v gh' 2>/dev/null | tail -1)
got_off=$(env -u BASH_ENV ZDOTDIR="$T/zrepo" HERDR_ENV=1 PATH="$T/fake:/usr/bin:/bin" \
    "$ZSH" -ic 'print -r -- "$(command -v gh)|${BASH_ENV:-}"' 2>/dev/null | tail -1)
if [ "$got_zl" = "$SHIMS/gh" ] && [ "$got_core" = "$SHIMS/gh" ] && [ "$got_off" = "$T/fake/gh|" ]; then
    pass "A4 repo .zprofile re-anchors an armed login zsh; an unarmed herdr shell is untouched"
else
    fail "A4 startup files (armed login=$got_zl core-env login=$got_core unarmed=$got_off)"
fi

# --- B: bypass matrix -- rounds 1-4 plus siblings ----------------------------

NL='
'
# bypass SHELL CMD ARGV: denied with no approval; after the owner approves a
# draft of ARGV (the argv the shim sees), exactly one run.
bypass() {
    fresh_gate
    h=$(draft $3)
    $1 -c "$2" >/dev/null 2>"$T/err" </dev/null
    if [ -z "$h" ] || [ -s "$FAKE_LOG" ] || ! grep -q 'gh shim' "$T/err"; then
        fail "B [$1] no go: $2 (hash=$h log=$(log_lines))"
        return
    fi
    approve "$h"
    $1 -c "$2" >/dev/null 2>&1 </dev/null
    first=$(log_lines)
    $1 -c "$2" >/dev/null 2>&1 </dev/null
    second=$(log_lines)
    if [ "$first" = 1 ] && [ "$second" = 1 ]; then
        pass "B [$1] $2"
    else
        fail "B [$1] go: $2 (first=$first second=$second)"
    fi
}

C='pr comment 5 --body x'
R='api -X POST repos/o/r/pulls/5/comments/9/replies -f body=x'
for sh in bash "zsh -f"; do
    bypass "$sh" "if gh pr comment 5 --body x; then :; fi" "$C"
    bypass "$sh" "while gh pr comment 5 --body x; do break; done" "$C"
    bypass "$sh" "true # note${NL}gh pr comment 5 --body x" "$C"
    bypass "$sh" "true # it's${NL}gh pr comment 5 --body x" "$C"
    bypass "$sh" "(gh pr comment 5 --body x)" "$C"
    bypass "$sh" "true;${NL}gh pr comment 5 --body x" "$C"
    bypass "$sh" "gh api -X POST \\${NL}repos/o/r/pulls/5/comments/9/replies -f body=x" "$R"
    bypass "$sh" "FOO=1 nice gh pr comment 5 --body x" "$C"
    bypass "$sh" "\$'gh' pr comment 5 --body x" "$C"
    bypass "$sh" "cat >/dev/null <<EOF${NL}hi${NL}EOF${NL}gh pr comment 5 --body x" "$C"
    bypass "$sh" "\`gh pr comment 5 --body x\`" "$C"
    bypass "$sh" "\$(gh pr comment 5 --body x)" "$C"
    bypass "$sh" "g\\h pr comment 5 --body x" "$C"
    bypass "$sh" "g\"\"h pr comment 5 --body x" "$C"
    bypass "$sh" "g''h pr comment 5 --body x" "$C"
    bypass "$sh" "bash -lc 'gh pr comment 5 --body x'" "$C"
    bypass "$sh" "\`which gh\` pr comment 5 --body x" "$C"
    bypass "$sh" "g\\h api -X POST repos/o/r/pulls/5/comments/9/replies -f body=x" "$R"
    bypass "$sh" "zsh -lc 'gh pr comment 5 --body x'" "$C"
    bypass "$sh" "bash --login -c 'gh pr comment 5 --body x'" "$C"
    bypass "$sh" "eval 'gh pr comment 5 --body x'" "$C"
    bypass "$sh" "echo 5 | xargs gh pr comment --body x" 'pr comment --body x 5'
    bypass "$sh" "f() { gh pr comment 5 --body x; }; f" "$C"
    bypass "$sh" "command gh pr comment 5 --body x" "$C"
    bypass "$sh" "\\gh pr comment 5 --body x" "$C"
    bypass "$sh" "env gh pr comment 5 --body x" "$C"
    bypass "$sh" "sh ./post.sh" "$C"
    bypass "$sh" "python3 -c 'import subprocess; subprocess.run([\"gh\",\"pr\",\"comment\",\"5\",\"--body\",\"x\"])'" "$C"
    bypass "$sh" "env -u HERDR_ENV bash -lc 'gh pr comment 5 --body x'" "$C"
    bypass "$sh" "gh api graphql -F query=@m.graphql" 'api graphql -F query=@m.graphql'
    bypass "$sh" "gh api graphql --input m.json" 'api graphql --input m.json'
done

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
