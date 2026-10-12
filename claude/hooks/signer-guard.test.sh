#!/bin/sh
# signer-guard.test.sh -- hermetic payload tests for signer_guard.py. The
# hook runs with a fixture HOME holding a fake 1Password log directory and
# fixture repos under one mktemp root with local signing config.
set -u

PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HOOK=${SIGNER_GUARD_HOOK:-claude/hooks/signer_guard.py}
PASS=0
FAIL=0

FIX=$(mktemp -d /tmp/signer-guard.XXXXXX)
[ -n "$FIX" ] && [ -d "$FIX" ] || { printf 'FAIL  cannot create the fixture root\n' >&2; exit 1; }
trap 'chmod -R u+rwx "$FIX" 2>/dev/null; rm -rf "$FIX"' EXIT

LOGREL="Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/logs"
OPSIGN=/Applications/1Password.app/Contents/MacOS/op-ssh-sign
LOCKED_LINE='INFO  2026-10-12T17:30:33.558+00:00 w(ThreadId(10)) [1P:app/op-app/src/app/backend/lock.rs:248] Lock state changed: Locked'
UNLOCKED_LINE='INFO  2026-10-12T17:30:34.558+00:00 w(ThreadId(10)) [1P:app/op-app/src/app/backend/lock.rs:248] Lock state changed: Unlocked'
NOISE='INFO  2026-10-12T17:31:00.316+00:00 ThreadId(1) [swift] DeviceUnlockMonitor.swift:244: Device is locked, skipping wake-based unlock'

g() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"
}

# mkhome NAME -> $FIX/NAME with an empty log directory
mkhome() { mkdir -p "$FIX/$1/$LOGREL"; }

# logfile NAME FILE LINE... -> newline-terminated lines
logfile() {
    f="$FIX/$1/$LOGREL/$2"; shift 2
    : > "$f"
    for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}

# mkrepo NAME PROGRAM GPGSIGN PUSHURL (empty arguments are left unset)
mkrepo() {
    r="$FIX/$1"
    g init -q "$r"
    g -C "$r" config gpg.format ssh
    [ -n "$2" ] && g -C "$r" config gpg.ssh.program "$2"
    [ -n "$3" ] && g -C "$r" config commit.gpgsign "$3"
    g -C "$r" remote add origin https://github.com/o/r.git
    [ -n "$4" ] && g -C "$r" remote set-url --push origin "$4"
    return 0
}

# run HOME-NAME CWD COMMAND -> sets RC and ERR
run() {
    payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[2]}, "cwd": sys.argv[1]}))' "$2" "$3")
    ERR=$(printf '%s' "$payload" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME="$FIX/$1" "$HOOK" 2>&1 >/dev/null)
    RC=$?
}

check() {
    if [ "$RC" = "$2" ]; then
        printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s want %s) %s\n' "$1" "$RC" "$2" "$ERR" >&2; FAIL=$((FAIL + 1))
    fi
}

mkhome locked;     logfile locked 1Password_rCURRENT.log "$NOISE" "$UNLOCKED_LINE" "$NOISE" "$LOCKED_LINE" "$NOISE"
mkhome unlocked;   logfile unlocked 1Password_rCURRENT.log "$LOCKED_LINE" "$NOISE" "$UNLOCKED_LINE"
mkdir -p "$FIX/nolog"
mkhome noline;     logfile noline 1Password_rCURRENT.log "$NOISE"
mkhome rotlocked;  logfile rotlocked 1Password_rCURRENT.log "$NOISE"
logfile rotlocked 1Password_r05157.log "$LOCKED_LINE"
logfile rotlocked 1Password_r05156.log "$UNLOCKED_LINE"
mkhome rotunlocked; logfile rotunlocked 1Password_rCURRENT.log "$NOISE"
logfile rotunlocked 1Password_r05157.log "$UNLOCKED_LINE"
logfile rotunlocked 1Password_r00999.log "$LOCKED_LINE"
mkhome tailunlock; logfile tailunlock 1Password_rCURRENT.log "$LOCKED_LINE"
printf '%s' "$UNLOCKED_LINE" >> "$FIX/tailunlock/$LOGREL/1Password_rCURRENT.log"
mkhome taillock;   logfile taillock 1Password_rCURRENT.log "$UNLOCKED_LINE"
printf '%s' "$LOCKED_LINE" | cut -c1-120 >> "$FIX/taillock/$LOGREL/1Password_rCURRENT.log"
mkhome cap;        logfile cap 1Password_rCURRENT.log "$NOISE"
logfile cap 1Password_r00010.log "$NOISE"
logfile cap 1Password_r00009.log "$NOISE"
logfile cap 1Password_r00008.log "$NOISE"
logfile cap 1Password_r00007.log "$LOCKED_LINE"
mkhome unreadable; logfile unreadable 1Password_rCURRENT.log "$UNLOCKED_LINE"
logfile unreadable 1Password_r00010.log "$LOCKED_LINE"
chmod 000 "$FIX/unreadable/$LOGREL/1Password_rCURRENT.log"

mkrepo signed "$OPSIGN" true git@github.com:o/r.git
mkrepo envsign /opt/x/bin/op-env-sign true git@github.com:o/r.git
mkrepo unsigned "$OPSIGN" "" git@github.com:o/r.git
mkrepo httpsrepo "$OPSIGN" true ""
mkrepo mixed "$OPSIGN" true https://github.com/o/r.git
g -C "$FIX/mixed" remote set-url --add --push origin git@github.com:o/r.git
S="$FIX/signed"

run locked "$S" 'git commit -m "x"'
check "locked commit denies" 2
low=$(printf '%s' "$ERR" | tr 'A-Z' 'a-z')
for needle in 1password unlock staged blocked_on_human dotfiles_allow_locked_signer=1 gpgsign --no-gpg-sign; do
    case "$low" in
        *"$needle"*) printf 'PASS  refusal names %s\n' "$needle"; PASS=$((PASS + 1)) ;;
        *) printf 'FAIL  refusal lacks %s\n' "$needle" >&2; FAIL=$((FAIL + 1)) ;;
    esac
done
case "$ERR" in
    *lock.rs*|*ThreadId*) printf 'FAIL  refusal echoes log content\n' >&2; FAIL=$((FAIL + 1)) ;;
    *) printf 'PASS  refusal does not echo log content\n'; PASS=$((PASS + 1)) ;;
esac

run unlocked "$S" 'git commit -m "x"';          check "unlocked commit allows" 0
run nolog "$S" 'git commit -m "x"';             check "missing log allows" 0
run noline "$S" 'git commit -m "x"';            check "log without lock line allows" 0
run rotlocked "$S" 'git commit -m "x"';         check "newest rotated Locked denies" 2
run rotunlocked "$S" 'git commit -m "x"';       check "numeric newest rotated Unlocked allows" 0
run tailunlock "$S" 'git commit -m "x"';        check "unterminated Unlocked tail keeps Locked" 2
run taillock "$S" 'git commit -m "x"';          check "truncated Locked tail keeps Unlocked" 0
run cap "$S" 'git commit -m "x"';               check "lock line beyond three rotated files allows" 0
run unreadable "$S" 'git commit -m "x"';        check "unreadable CURRENT falls through to rotated Locked" 2
run locked "$FIX/envsign" 'git commit -m "x"';  check "op-env signer allows" 0
run locked "$FIX/unsigned" 'git commit -m "x"'; check "signing off allows" 0
run locked "$S" 'git -c commit.gpgsign=false commit -m "x"'; check "-c gpgsign=false bypass denies" 2
run locked "$S" 'git commit --no-gpg-sign -m "x"';           check "--no-gpg-sign bypass denies" 2
run locked "$FIX/unsigned" "git -C $S commit -m x";          check "git -C signed repo denies" 2
run locked "$S" "git -C $FIX/envsign commit -m x";           check "git -C op-env repo allows" 0

for verb in "merge origin/main" "rebase origin/main" "cherry-pick abc123" "revert HEAD" "am 0001.patch" "pull"; do
    run locked "$S" "git $verb"; check "locked $verb denies" 2
done
run locked "$S" 'git merge --ff-only origin/main'; check "merge --ff-only allows" 0
run locked "$S" 'git pull --ff-only';              check "pull --ff-only allows" 0
run locked "$S" 'git add -A && git commit -qm "x"'; check "compound add && commit denies" 2
run locked "$S" 'git status --short';              check "git status allows" 0
run locked "$S" 'echo "git commit -m x"';          check "echo of git commit allows" 0

run locked "$S" 'git push -u origin HEAD';         check "ssh push denies" 2
run locked "$S" 'git push';                        check "bare push denies" 2
run unlocked "$S" 'git push -u origin HEAD';       check "unlocked push allows" 0
run locked "$FIX/httpsrepo" 'git push -u origin HEAD'; check "https push allows" 0
run locked "$FIX/mixed" 'git push origin HEAD';    check "second push URL over ssh denies" 2
run locked "$S" 'git push https://github.com/o/r.git HEAD'; check "explicit https URL allows" 0
run locked "$FIX/httpsrepo" 'git push git@github.com:o/r.git HEAD'; check "explicit scp-like URL denies" 2
run locked "$S" 'git push -o ci.skip origin HEAD'; check "push -o value is not the remote" 2

run locked "$S" 'DOTFILES_ALLOW_LOCKED_SIGNER=1 git commit -m "x"'; check "override prefix allows" 0
run locked "$S" 'DOTFILES_ALLOW_LOCKED_SIGNER=1 true && git commit -m "x"'; check "override on another segment denies" 2

payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": "git commit -m x"}, "cwd": sys.argv[1]}))' "$S")
printf '%s' "$payload" | DOTFILES_ALLOW_LOCKED_SIGNER=1 GIT_CONFIG_GLOBAL=/dev/null HOME="$FIX/locked" "$HOOK" >/dev/null 2>&1
RC=$?; ERR=; check "exported override variable has no effect" 2
printf '%s' "$payload" | GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gpg.ssh.program GIT_CONFIG_VALUE_0=/opt/x/bin/op-env-sign \
    GIT_CONFIG_GLOBAL=/dev/null HOME="$FIX/locked" "$HOOK" >/dev/null 2>&1
RC=$?; ERR=; check "inherited GIT_CONFIG_COUNT op-env signer allows" 0

cx=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "exec_command", "tool_input": {"cmd": "git commit -m x", "workdir": sys.argv[1]}}))' "$S")
printf '%s' "$cx" | GIT_CONFIG_GLOBAL=/dev/null HOME="$FIX/locked" "$HOOK" >/dev/null 2>&1
RC=$?; ERR=; check "codex exec_command denies" 2
cn=$(python3 -c 'import json,sys; print(json.dumps({"tool_name": "shell", "tool_input": {"args": {"command": "git commit -m x", "workdir": sys.argv[1]}}}))' "$S")
printf '%s' "$cn" | GIT_CONFIG_GLOBAL=/dev/null HOME="$FIX/locked" "$HOOK" >/dev/null 2>&1
RC=$?; ERR=; check "codex shell nested args denies" 2
printf 'not json' | HOME="$FIX/locked" "$HOOK" >/dev/null 2>&1
RC=$?; ERR=; check "malformed payload allows" 0
printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | HOME="$FIX/locked" "$HOOK" >/dev/null 2>&1
RC=$?; ERR=; check "Read tool allows" 0

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
