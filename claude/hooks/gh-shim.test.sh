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

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN FAKE_STDIN FAKE_OUT FAKE_RC
# A stray real gh could neither authenticate nor reach github.com.
export HOME="$T/home" GH_CONFIG_DIR="$T/ghc" GH_HOST=gh-shim-test.invalid ZDOTDIR="$T/zdot"
export BASH_ENV="$SHIMS/path.sh"
export DOTFILES_REAL_GH="$T/fake/gh" CLAUDE_CODE_SESSION_ID=s1 HERDR_ENV=1
export FAKE_LOG="$T/log"
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

# mint PHRASE: the real hook's UserPromptSubmit handler mints the go for s1
mint() {
    printf '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"%s"}' "$1" \
        | python3 "$HOOK" >/dev/null 2>&1
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
mint "post it"
printf 'body-from-stdin' | FAKE_STDIN="$T/stdin" gh pr comment 5 --body-file - >/dev/null 2>&1
if [ "$(cat "$T/stdin" 2>/dev/null)" = body-from-stdin ]; then
    pass "S2 allowed post passes stdin through"
else
    fail "S2 allowed post passes stdin through"
fi

fresh_gate
mint "post it"
gh repo delete o/r --yes >/dev/null 2>"$T/err"; rc1=$?
gh extension install o/gh-x >/dev/null 2>>"$T/err"; rc2=$?
if [ "$rc1" = 1 ] && [ "$rc2" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q 'gh shim' "$T/err"; then
    pass "S3 unknown subcommands are denied even with a go"
else
    fail "S3 unknown subcommands are denied even with a go (rc=$rc1/$rc2 log=$(log_lines))"
fi

fresh_gate
gh pr comment 5 --body x >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q 'typed go' "$T/err"; then
    pass "S4 post without a go is denied"
else
    fail "S4 post without a go is denied (rc=$rc log=$(log_lines))"
fi

fresh_gate
mint "post it"
gh pr comment 5 --body x >/dev/null 2>&1; rc1=$?
gh pr comment 5 --body x >/dev/null 2>&1; rc2=$?
if [ "$rc1" = 0 ] && [ "$rc2" = 1 ] && [ "$(log_lines)" = 1 ] && [ -e "$DOTFILES_POST_GATE_DIR/s1.post-used" ]; then
    pass "S5 a post go execs exactly one post"
else
    fail "S5 a post go execs exactly one post (rc=$rc1/$rc2 log=$(log_lines))"
fi

fresh_gate
mint "post it"
gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc1=$?
gh api --method DELETE repos/o/r/issues/comments/8 >/dev/null 2>&1; rc2=$?
gh pr comment 5 --body x >/dev/null 2>&1; rc3=$?
gh api -X DELETE repos/o/r/issues/comments/7 >/dev/null 2>&1; rc4=$?
if [ "$rc1$rc2$rc3$rc4" = 0000 ] && [ "$(log_lines)" = 4 ]; then
    pass "S6 own-marker deletes run freely under a live post go, before and after the post"
else
    fail "S6 own-marker deletes run freely under a live post go, before and after the post (rc=$rc1$rc2$rc3$rc4 log=$(log_lines))"
fi

fresh_gate
gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "S7 delete without a go is denied"
else
    fail "S7 delete without a go is denied (rc=$rc)"
fi

# --- O: a delete removes only this account's own co-review marker ----------

fresh_gate
mint "post it"
FAKE_COMMENT="{\"user\":{\"login\":\"rev\"},\"body\":\"$MARK\"}" \
    gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>"$T/err"; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ] && grep -q 'own co-review marker' "$T/err"; then
    pass "O1 delete of another author's comment is refused"
else
    fail "O1 delete of another author's comment is refused (rc=$rc log=$(log_lines))"
fi

fresh_gate
mint "post it"
FAKE_COMMENT='{"user":{"login":"me"},"body":"thanks, fixed"}' \
    gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "O2 delete of our own non-marker comment is refused"
else
    fail "O2 delete of our own non-marker comment is refused (rc=$rc log=$(log_lines))"
fi

fresh_gate
mint "post it"
FAKE_COMMENT='not json' gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc1=$?
FAKE_GET_RC=1 gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc2=$?
if [ "$rc1$rc2" = 11 ] && [ "$(log_lines)" = 0 ]; then
    pass "O3 an unreadable or failed ownership read refuses the delete"
else
    fail "O3 an unreadable or failed ownership read refuses the delete (rc=$rc1$rc2 log=$(log_lines))"
fi

fresh_gate
: >"$FAKE_GETLOG"
mint "post it"
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
mint "post it"
GH_FORCE_TTY=1 CLICOLOR_FORCE=1 GH_PAGER=less \
    gh api -X DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ "$(log_lines)" = 1 ] && [ -s "$FAKE_GETLOG" ]; then
    pass "O5 ownership reads pin a plain output env"
else
    fail "O5 ownership reads pin a plain output env (rc=$rc log=$(log_lines))"
fi
fresh_gate
mint "post it"
FAKE_COMMENT="{\"user\":{\"login\":\"rev\"},\"body\":\"$MARK\"}" \
    gh api -iX DELETE repos/o/r/issues/comments/9 >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "O6 a clustered -iX DELETE of another author's comment is refused"
else
    fail "O6 a clustered -iX DELETE of another author's comment is refused (rc=$rc log=$(log_lines))"
fi

fresh_gate
mint "post it"
gh pr edit 5 --body-file b.md >/dev/null 2>&1; rc1=$?
mint "edit the pr body"
gh pr edit 5 --body-file b.md >/dev/null 2>&1; rc2=$?
gh pr edit 5 --body-file b.md >/dev/null 2>&1; rc3=$?
gh pr comment 5 --body x >/dev/null 2>&1; rc4=$?
if [ "$rc1$rc2$rc3$rc4" = 1011 ] && [ "$(log_lines)" = 1 ]; then
    pass "S8 body edit needs its own go and runs once"
else
    fail "S8 body edit needs its own go and runs once (rc=$rc1$rc2$rc3$rc4 log=$(log_lines))"
fi

fresh_gate
mint "post it"
CLAUDE_CODE_SESSION_ID=s2 gh pr comment 5 --body x >/dev/null 2>&1; rc1=$?
env -u CLAUDE_CODE_SESSION_ID gh pr comment 5 --body x >/dev/null 2>&1; rc2=$?
env -u CLAUDE_CODE_SESSION_ID gh pr view 5 >/dev/null 2>&1; rc3=$?
if [ "$rc1$rc2$rc3" = 110 ] && [ "$(log_lines)" = 1 ]; then
    pass "S9 go is bound to CLAUDE_CODE_SESSION_ID; reads need none"
else
    fail "S9 go is bound to CLAUDE_CODE_SESSION_ID (rc=$rc1$rc2$rc3 log=$(log_lines))"
fi

fresh_gate
mint "post it"
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
if [ "$rc1$rc2$rc3$rc4$rc6$rc5" = 111110 ] && [ "$(cat "$FAKE_LOG")" = status ]; then
    pass "S12 graphql from a file or stdin is gated; aliases stay unknown"
else
    fail "S12 graphql and aliases (rc=$rc1$rc2$rc3$rc4$rc5 log=$(cat "$FAKE_LOG"))"
fi

fresh_gate
mint "post it"
map=$(ls "$DOTFILES_POST_GATE_DIR" | sed -n 's/^pid-\([0-9]*\)\.sid$/\1/p')
CLAUDE_PID="$map" CLAUDE_CODE_SESSION_ID=stale gh pr comment 5 --body x >/dev/null 2>&1; rc1=$?
CLAUDE_PID="$map" CLAUDE_CODE_SESSION_ID=stale gh pr comment 5 --body x >/dev/null 2>&1; rc2=$?
if [ -n "$map" ] && [ "$rc1$rc2" = 01 ] && [ "$(log_lines)" = 1 ]; then
    pass "S13 the hook's pid map binds the go past a stale session id"
else
    fail "S13 pid map binding (map=$map rc=$rc1$rc2 log=$(log_lines))"
fi

fresh_gate
mint "post it"
: >"$T/not-a-dir"
DOTFILES_POST_GATE_DIR="$T/not-a-dir" gh pr comment 5 --body x >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ "$(log_lines)" = 0 ]; then
    pass "S10 an unusable gate dir fails closed"
else
    fail "S10 an unusable gate dir fails closed (rc=$rc log=$(log_lines))"
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
# bypass SHELL CMD KIND: denied with no go; after one go, exactly one run
# (a delete runs again under the same go).
bypass() {
    fresh_gate
    $1 -c "$2" >/dev/null 2>"$T/err" </dev/null
    if [ -s "$FAKE_LOG" ] || ! grep -q 'gh shim' "$T/err"; then
        fail "B [$1] no go: $2 (log=$(log_lines))"
        return
    fi
    mint "post it"
    $1 -c "$2" >/dev/null 2>&1 </dev/null
    first=$(log_lines)
    $1 -c "$2" >/dev/null 2>&1 </dev/null
    second=$(log_lines)
    want=1
    [ "$3" = delete ] && want=2
    if [ "$first" = 1 ] && [ "$second" = "$want" ]; then
        pass "B [$1] $2"
    else
        fail "B [$1] go: $2 (first=$first second=$second)"
    fi
}

for sh in bash "zsh -f"; do
    bypass "$sh" "if gh pr comment 5 --body x; then :; fi" post
    bypass "$sh" "while gh pr comment 5 --body x; do break; done" post
    bypass "$sh" "true # note${NL}gh pr comment 5 --body x" post
    bypass "$sh" "true # it's${NL}gh pr comment 5 --body x" post
    bypass "$sh" "(gh pr comment 5 --body x)" post
    bypass "$sh" "true;${NL}gh pr comment 5 --body x" post
    bypass "$sh" "gh api -X POST \\${NL}repos/o/r/pulls/5/comments/9/replies -f body=x" post
    bypass "$sh" "FOO=1 nice gh pr comment 5 --body x" post
    bypass "$sh" "\$'gh' pr comment 5 --body x" post
    bypass "$sh" "cat >/dev/null <<EOF${NL}hi${NL}EOF${NL}gh pr comment 5 --body x" post
    bypass "$sh" "\`gh pr comment 5 --body x\`" post
    bypass "$sh" "\$(gh pr comment 5 --body x)" post
    bypass "$sh" "g\\h pr comment 5 --body x" post
    bypass "$sh" "g\"\"h pr comment 5 --body x" post
    bypass "$sh" "g''h pr comment 5 --body x" post
    bypass "$sh" "bash -lc 'gh pr comment 5 --body x'" post
    bypass "$sh" "\`which gh\` pr comment 5 --body x" post
    bypass "$sh" "g\\h api -X DELETE repos/o/r/issues/comments/9" delete
    bypass "$sh" "zsh -lc 'gh pr comment 5 --body x'" post
    bypass "$sh" "bash --login -c 'gh pr comment 5 --body x'" post
    bypass "$sh" "eval 'gh pr comment 5 --body x'" post
    bypass "$sh" "echo 5 | xargs gh pr comment --body x" post
    bypass "$sh" "f() { gh pr comment 5 --body x; }; f" post
    bypass "$sh" "command gh pr comment 5 --body x" post
    bypass "$sh" "\\gh pr comment 5 --body x" post
    bypass "$sh" "env gh pr comment 5 --body x" post
    bypass "$sh" "sh ./post.sh" post
    bypass "$sh" "python3 -c 'import subprocess; subprocess.run([\"gh\",\"pr\",\"comment\",\"5\",\"--body\",\"x\"])'" post
    bypass "$sh" "env -u HERDR_ENV bash -lc 'gh pr comment 5 --body x'" post
    bypass "$sh" "gh api graphql -F query=@m.graphql" post
    bypass "$sh" "gh api graphql --input m.json" post
done

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
