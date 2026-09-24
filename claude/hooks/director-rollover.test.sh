#!/bin/sh
# director-rollover.test.sh - same-process lease adoption, resume-owner,
# rollover, and the director_rollover SessionStart hook. Hermetic: temp HOME,
# temp config and coordination roots, fixture repos, a PATH stub for herdr.
set -u
cd "$(dirname "$0")/../.." || exit 1
unset WORKFLOW_PERSONAL_ACCOUNT HERDR_PERSONAL CLAUDE_PERSONAL_ONLY
unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR CODEX_HOME XDG_STATE_HOME
# Never inherit the running session's identity: a gate case that means
# "variable absent" must really lack it, even when run inside a director.
unset HERDR_ENV CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_SESSION_ID HERDR_PANE_ID
TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || TMPDIR=""
[ -n "$TMPDIR" ] || TMPDIR=/tmp
TMPDIR=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMPDIR")
export TMPDIR
PASS=0
FAIL=0
REPO_ROOT=$(pwd)
export REPO_ROOT

# check LABEL -- runs a sh snippet on stdin in a fresh fixture: a git repo
# with a fake origin (FX_REPO, FX_SLUG), temp config/coordination roots, and
# CORE pointing at the core CLI. Exit 0 pass, non-zero fail.
check() {
    label="$1"
    body=$(cat)  # read the snippet before any fixture command can touch stdin
    FX=$(mktemp -d); export FX
    HERDR_COORDINATION_ROOT="$FX/coord"; export HERDR_COORDINATION_ROOT
    CLAUDE_CONFIG_DIR="$FX/config"; export CLAUDE_CONFIG_DIR
    HOME="$FX/home"; export HOME
    mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR" "$FX/bin"
    FX_REPO="$FX/repo"; export FX_REPO
    git init -q "$FX_REPO"
    git -C "$FX_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
    git -C "$FX_REPO" remote add origin "git@example.invalid:org/rollover-$$.git"
    FX_SLUG=$(python3 -c '
import sys
sys.path.insert(0, sys.argv[2] + "/claude/hooks")
import herdr_orch_core as c
from workflow_context import repository_context
ctx = repository_context(sys.argv[1])
print(c.repo_slug(c.context_git(ctx["root"], "remote", "get-url", "origin"), ctx["common_dir"]))
' "$FX_REPO" "$REPO_ROOT"); export FX_SLUG
    CORE="python3 $REPO_ROOT/claude/hooks/herdr_orch_core.py"; export CORE
    if printf '%s\n' "$body" | sh -e - > "$FX/out" 2>&1; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2; sed 's/^/      /' "$FX/out" >&2
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$FX"
}

check "adopt: same pid, caller is a descendant, fresh lease -> new session, fence +1" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
F2=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ --messaging-socket "$SOCK")
test "$F2" -eq $((F1 + 1))
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --fence "$F2"
if $CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"; then exit 1; fi
SH

check "adopt refused: lease pid is a live non-ancestor (forged pid and socket) -> BUSY" <<'SH'
sleep 60 & SIB=$!
SOCK=/tmp/cc-socks/$SIB.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $SIB --messaging-socket "$SOCK" >/dev/null
out=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid $SIB --messaging-socket "$SOCK") && rc=0 || rc=$?
kill $SIB
test "$rc" = 1
test "$out" = BUSY
SH

check "adopt refused: different pid -> BUSY" <<'SH'
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock >/dev/null
out=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid 1 --messaging-socket /tmp/cc-socks/1.sock) && rc=0 || rc=$?
test "$rc" = 1
test "$out" = BUSY
SH

check "adopt refused: no messaging socket -> BUSY" <<'SH'
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock >/dev/null
out=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid $$) && rc=0 || rc=$?
test "$rc" = 1
test "$out" = BUSY
SH

check "adopt refused: ps missing or failing fails closed -> BUSY, no traceback" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK" >/dev/null
PY=$(command -v python3); GIT=$(command -v git); SHELL_BIN=$(command -v sh)
mkdir -p "$FX/nops" "$FX/badps"
for d in nops badps; do ln -s "$PY" "$FX/$d/python3"; ln -s "$GIT" "$FX/$d/git"; ln -s "$SHELL_BIN" "$FX/$d/sh"; done
# A ps that prints the target pid but fails: a missing returncode check would adopt.
printf '#!/bin/sh\necho %s\nexit 1\n' "$$" > "$FX/badps/ps"; chmod +x "$FX/badps/ps"
# `; true` keeps sh from exec-ing python, so the direct parent is NOT $$ and
# _is_ancestor has to call ps to reach it.
for d in nops badps; do
    out=$(PATH="$FX/$d" "$FX/$d/sh" -c '"$0" "$1" claim-owner --repo-path "$2" --runtime claude --repo-slug "$3" --session 22222222-2222-4222-8222-222222222222 --host h --pid "$4" --messaging-socket "$5"; true' \
        "$FX/$d/python3" "$REPO_ROOT/claude/hooks/herdr_orch_core.py" "$FX_REPO" "$FX_SLUG" "$$" "$SOCK" 2>"$FX/err-$d")
    test "$out" = BUSY
    if grep -q Traceback "$FX/err-$d"; then exit 1; fi
done
SH

# If the nops/badps runs fail for a reason other than adoption (account
# selection needing another binary on the restricted PATH), symlink that
# binary into both directories too; never add a working ps.

check "adopt refused: codex runtime lease is never adopted" <<'SH'
python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_coordination as co
old = {"session_id": "a", "pid": 42, "runtime": "codex", "thread_id": "t",
       "account_id": "acct", "control_tier": "launcher", "heartbeat_ts": time.time(), "fence": 3}
tx = object.__new__(co.OwnerTransaction)
tx.account_id = "acct"
assert not tx._adoptable(old, 42, "codex", "t")
assert not tx._adoptable(dict(old, runtime="claude", thread_id=None, account_id="other"), 42, "claude", None)
assert not tx._adoptable(dict(old, runtime="claude", thread_id=None, control_tier="lead"), 42, "claude", None)
assert not tx._adoptable(dict(old, runtime="claude", thread_id=None), None, "claude", None)
assert not tx._adoptable(dict(old, runtime="claude", thread_id=None), True, "claude", None)
assert tx._adoptable(dict(old, runtime="claude", thread_id=None), 42, "claude", None)
PY
SH

check "same-session re-claim is unchanged" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
F2=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
test -n "$F2"
test "$F2" -ge "$F1"
SH

check "resume-owner: adopts after /clear and prints INFO with the new fence" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
$CORE resume-owner --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket "$SOCK" > "$FX/info"
grep -q '^\[INFO\] herdr director rollover: lease re-established in place\.$' "$FX/info"
grep -qxF "repo_slug=$FX_SLUG session=22222222-2222-4222-8222-222222222222 fence=$((F1 + 1))" "$FX/info"
grep -q '^watch: none found' "$FX/info"
grep -q '^Next: load the herdr-orchestration skill' "$FX/info"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --fence $((F1 + 1))
SH

check "resume-owner: reports a live watch that descends from the socket pid, ignores another slug" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK" >/dev/null
python3 -c 'import time; time.sleep(60)' herdr_orch_core.py watch --repo-slug "${FX_SLUG}x" & OTHER=$!
sleep 1
$CORE resume-owner --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket "$SOCK" > "$FX/info1"
python3 -c 'import time; time.sleep(60)' herdr_orch_core.py watch --repo-slug "$FX_SLUG" --since-epoch 1 & W=$!
sleep 1
$CORE resume-owner --repo-path "$FX_REPO" --session 33333333-3333-4333-8333-333333333333 \
    --messaging-socket "$SOCK" > "$FX/info2" && rc=0 || rc=$?
kill $OTHER $W
grep -q '^watch: none found' "$FX/info1"
test "$rc" = 0
grep -q "^watch: live (pids $W); do not arm another" "$FX/info2"
grep -q 'watch-pids --repo-slug' "$FX/info2"
SH

check "resume-owner lists every live watch; watch-pids matches and ignores another slug" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK" >/dev/null
python3 -c 'import time; time.sleep(60)' herdr_orch_core.py watch --repo-slug "$FX_SLUG" & W1=$!
python3 -c 'import time; time.sleep(60)' herdr_orch_core.py watch --repo-slug "$FX_SLUG" & W2=$!
python3 -c 'import time; time.sleep(60)' herdr_orch_core.py watch --repo-slug "${FX_SLUG}x" & OTHER=$!
# Same slug but outside this process tree: the subshell exits, so the watch is
# reparented away from $$ and must not be listed.
( python3 -c 'import time; time.sleep(60)' herdr_orch_core.py watch --repo-slug "$FX_SLUG" & echo $! > "$FX/orphan.pid" )
sleep 1
$CORE resume-owner --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket "$SOCK" > "$FX/info"
$CORE watch-pids --repo-slug "$FX_SLUG" --messaging-socket "$SOCK" > "$FX/pids"
$CORE watch-pids --repo-slug "${FX_SLUG}y" --messaging-socket "$SOCK" > "$FX/none"
kill $W1 $W2 $OTHER "$(cat "$FX/orphan.pid")"
LO=$W1; HI=$W2; if [ "$W2" -lt "$W1" ]; then LO=$W2; HI=$W1; fi
grep -q "^watch: live (pids $LO,$HI); do not arm another" "$FX/info"
test "$(cat "$FX/pids" | tr '\n' ' ')" = "$LO $HI "
test ! -s "$FX/none"
# the watch-pids scan itself (a descendant naming --repo-slug) is never listed
# a shell wrapper carrying the watch text (as a Monitor's zsh -c does) is not a watch
sh -c 'sleep 30; : herdr_orch_core.py watch --repo-slug '"$FX_SLUG" & WRAP=$!
sleep 1
$CORE watch-pids --repo-slug "$FX_SLUG" --messaging-socket "$SOCK" > "$FX/pids2"
kill $WRAP
if grep -qx "$WRAP" "$FX/pids2"; then exit 1; fi
test "$(wc -l < "$FX/pids" | tr -d ' ')" = 2
SH

check "resume-owner: exit 3, silent, no write when another pid holds the lease" <<'SH'
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid 1 --messaging-socket /tmp/cc-socks/1.sock)
out=$($CORE resume-owner --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket /tmp/cc-socks/$$.sock) && rc=0 || rc=$?
test "$rc" = 3
test -z "$out"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
SH

check "resume-owner: exit 3 and silent with no lease, and claims nothing" <<'SH'
out=$($CORE resume-owner --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket /tmp/cc-socks/$$.sock) && rc=0 || rc=$?
test "$rc" = 3
test -z "$out"
if $CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --fence 1; then exit 1; fi
SH

check "resume-owner: exit 3 on an invalid socket or a non-repo path" <<'SH'
out=$($CORE resume-owner --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket /nope/1.sock) && rc=0 || rc=$?
test "$rc" = 3
test -z "$out"
mkdir -p "$FX/plain"
out=$($CORE resume-owner --repo-path "$FX/plain" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket /tmp/cc-socks/$$.sock 2>/dev/null) && rc=0 || rc=$?
test "$rc" = 3
test -z "$out"
SH

check "resume: a stale lease under the same pid and account is re-claimed" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
# stale_secs=0 makes the existing lease stale without editing any record; the
# python process's parent is this shell ($$), so ancestry holds.
python3 - "$FX_REPO" "$FX_SLUG" "$F1" "$$" <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
repo, slug, f1, pid = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
c.select_payload(argparse.Namespace(repo_path=repo, repo_slug=slug, runtime="claude", personal=False))
sel = c._PAYLOAD_SELECTION.get()
fence = c.claim_owner(c.repo_dir(slug), "22222222-2222-4222-8222-222222222222", "h", pid,
                      stale_secs=0, messaging_socket="/tmp/cc-socks/%d.sock" % pid,
                      context=sel["context"], expected_slug=slug, runtime="claude",
                      scope=sel["scope"], require_pid=pid)
assert fence == f1 + 1, fence
PY
SH

check "resume eligibility: pid, ancestry, account, runtime, thread, tier all required" <<'SH'
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
cur = {"pid": 42, "account_id": "a", "runtime": "claude", "thread_id": None,
       "control_tier": "launcher", "session_id": "s", "fence": 3, "heartbeat_ts": 0}
ok = c._resume_eligible
assert ok(cur, 42, 42, "a")
assert not ok(None, 42, 42, "a")
assert not ok(cur, 43, 43, "a")
assert not ok(cur, 42, None, "a")                       # ancestry not proven
assert not ok(dict(cur, account_id="b"), 42, 42, "a")   # stale lease from another account
assert not ok(dict(cur, runtime="codex"), 42, 42, "a")
assert not ok(dict(cur, thread_id="t"), 42, 42, "a")
assert not ok(dict(cur, control_tier="lead"), 42, 42, "a")
PY
SH

check "resume-owner: exit 3, silent, no write when the lease pid is not an ancestor" <<'SH'
sleep 60 & SIB=$!
SOCK=/tmp/cc-socks/$SIB.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $SIB --messaging-socket "$SOCK")
out=$($CORE resume-owner --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket "$SOCK") && rc=0 || rc=$?
kill $SIB
test "$rc" = 3
test -z "$out"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
SH

# Scripted herdr for the rollover delivery checks: sends log to $FX/herdr.log,
# fail N times per verb ($FX/fail.<verb>, optional $FX/garbage.<verb> for a
# malformed-JSON reply), and `pane read` shows $FX/screen.before until a
# send-keys lands, then $FX/screen.after.
ROLLOVER_STUB="$TMPDIR/rollover-herdr-stub.$$"
cat > "$ROLLOVER_STUB" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FX/herdr.log"
if [ "$1 $2" = "pane read" ]; then
    if [ -e "$FX/entered" ]; then cat "$FX/screen.after"; else cat "$FX/screen.before"; fi
    exit 0
fi
n=$(grep -c "^pane $2 " "$FX/herdr.log")
fails=$(cat "$FX/fail.$2" 2>/dev/null || echo 0)
if [ "$n" -le "$fails" ]; then
    if [ -e "$FX/garbage.$2" ]; then
        [ "$2" = send-keys ] && : > "$FX/entered"
        printf 'not json\n'; exit 0
    fi
    echo boom >&2; exit 7
fi
[ "$2" = send-keys ] && : > "$FX/entered"
printf '{"id":"x","result":{"type":"ok"}}\n'
STUB
chmod +x "$ROLLOVER_STUB"
SCREENS="$TMPDIR/rollover-screens.$$"; mkdir -p "$SCREENS"
python3 - "$SCREENS" <<'PY'
import sys
d, rule = sys.argv[1], "─" * 40
meter = "  " + "█" * 4 + "░" * 6 + " 42% │ Opus"
def w(name, *lines):
    open(f"{d}/{name}", "w").write("\n".join(lines) + "\n")
w("typed", "history", rule, "❯ /clear", rule, meter)
w("empty", "history", rule, "❯", rule, meter)
w("history-only", "❯ /clear", "done", rule, "❯", rule, meter)
w("partial", "history", rule, "❯ /cl", rule, meter)
PY
export ROLLOVER_STUB SCREENS

check "rollover: sends /clear then enter to HERDR_PANE_ID" <<'SH'
cat > "$FX/bin/herdr" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FX/herdr.log"
printf '{"id":"x","result":{"type":"ok"}}\n'
STUB
chmod +x "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" > "$FX/o"
grep -qxF 'rollover: queued /clear for pane w9:p1; end this turn now' "$FX/o"
test "$(wc -l < "$FX/herdr.log" | tr -d ' ')" = 3
test "$(sed -n 1p "$FX/herdr.log")" = "pane send-text w9:p1 /clear"
test "$(sed -n 2p "$FX/herdr.log")" = "pane send-keys w9:p1 enter"
test "$(sed -n 3p "$FX/herdr.log")" = "pane read w9:p1 --source detection --lines 40"
SH

check "rollover: send-text replies malformed JSON but /clear is in the input -> no resend" <<'SH'
cp "$ROLLOVER_STUB" "$FX/bin/herdr"; cp "$SCREENS/typed" "$FX/screen.before"; cp "$SCREENS/empty" "$FX/screen.after"
echo 1 > "$FX/fail.send-text"; : > "$FX/garbage.send-text"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" > "$FX/o"
grep -qxF 'rollover: queued /clear for pane w9:p1; end this turn now' "$FX/o"
test "$(grep -c '^pane send-text ' "$FX/herdr.log")" = 1
test "$(grep -c '^pane send-keys ' "$FX/herdr.log")" = 1
SH

check "rollover: send-text failed and the input is empty (history has /clear) -> one resend" <<'SH'
cp "$ROLLOVER_STUB" "$FX/bin/herdr"; cp "$SCREENS/history-only" "$FX/screen.before"; cp "$SCREENS/empty" "$FX/screen.after"
echo 1 > "$FX/fail.send-text"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" > "$FX/o"
grep -qxF 'rollover: queued /clear for pane w9:p1; end this turn now' "$FX/o"
test "$(grep -c '^pane send-text ' "$FX/herdr.log")" = 2
SH

check "rollover: send-text failed with partial input -> stop, no resend, no Enter" <<'SH'
cp "$ROLLOVER_STUB" "$FX/bin/herdr"; cp "$SCREENS/partial" "$FX/screen.before"; cp "$SCREENS/empty" "$FX/screen.after"
echo 1 > "$FX/fail.send-text"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
rc=0; PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" 2> "$FX/e" || rc=$?
test "$rc" = 1
grep -q 'delivery unknown' "$FX/e"
test "$(grep -c '^pane send-text ' "$FX/herdr.log")" = 1
test "$(grep -c '^pane send-keys ' "$FX/herdr.log")" = 0
SH

check "rollover: Enter failed once with /clear still typed -> one retry" <<'SH'
cp "$ROLLOVER_STUB" "$FX/bin/herdr"; cp "$SCREENS/typed" "$FX/screen.before"; cp "$SCREENS/empty" "$FX/screen.after"
echo 1 > "$FX/fail.send-keys"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" > "$FX/o"
grep -qxF 'rollover: queued /clear for pane w9:p1; end this turn now' "$FX/o"
test "$(grep -c '^pane send-keys ' "$FX/herdr.log")" = 2
SH

check "rollover: Enter failing twice with /clear still typed -> stop, delivery unknown" <<'SH'
cp "$ROLLOVER_STUB" "$FX/bin/herdr"; cp "$SCREENS/typed" "$FX/screen.before"; cp "$SCREENS/empty" "$FX/screen.after"
echo 2 > "$FX/fail.send-keys"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
rc=0; PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" 2> "$FX/e" || rc=$?
test "$rc" = 1
grep -q 'delivery unknown' "$FX/e"
test "$(grep -c '^pane send-keys ' "$FX/herdr.log")" = 2
test "$(grep -c '^pane read ' "$FX/herdr.log")" = 1
SH

check "rollover: /clear still typed after Enter -> exit 1 with the press-Enter message" <<'SH'
cp "$ROLLOVER_STUB" "$FX/bin/herdr"; cp "$SCREENS/typed" "$FX/screen.before"; cp "$SCREENS/typed" "$FX/screen.after"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
rc=0; PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" 2> "$FX/e" || rc=$?
test "$rc" = 1
grep -qF 'rollover: /clear typed but not submitted in pane w9:p1; press Enter there' "$FX/e"
SH

check "rollover: stale fence sends nothing" <<'SH'
cat > "$FX/bin/herdr" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FX/herdr.log"
printf '{"id":"x","result":{"type":"ok"}}\n'
STUB
chmod +x "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
out=$(PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence $((F + 5))) && rc=0 || rc=$?
test "$rc" = 1
test "$out" = "owner: stale-fence"
test ! -e "$FX/herdr.log"
SH

check "rollover: outside a herdr pane exits 2 and sends nothing" <<'SH'
cat > "$FX/bin/herdr" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FX/herdr.log"
printf '{"id":"x","result":{"type":"ok"}}\n'
STUB
chmod +x "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
(unset HERDR_PANE_ID; PATH="$FX/bin:$PATH" $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" 2>/dev/null) && rc=0 || rc=$?
test "$rc" = 2
test ! -e "$FX/herdr.log"
SH

check "rollover: Enter failing after /clear was typed exits 1 with the delivery-unknown message" <<'SH'
cat > "$FX/bin/herdr" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FX/herdr.log"
case "$2" in send-keys) echo boom >&2; exit 7 ;; esac
printf '{"id":"x","result":{"type":"ok"}}\n'
STUB
chmod +x "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" 2> "$FX/e" && rc=0 || rc=$?
test "$rc" = 1
grep -q 'delivery unknown' "$FX/e"
grep -q 'do not re-run rollover' "$FX/e"
test "$(grep -c 'send-text' "$FX/herdr.log")" = 1
SH

check "hook: silent on every gate failure" <<'SH'
H="python3 $REPO_ROOT/claude/hooks/director_rollover.py"
SID=22222222-2222-4222-8222-222222222222
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
p() { printf '{"hook_event_name":"SessionStart","source":"%s","agent_type":"%s","session_id":"%s","cwd":"%s"}' "$1" "$2" "$3" "$FX_REPO"; }
test -z "$(p startup director $SID | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
test -z "$(p clear director $SID | CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
test -z "$(p clear worker $SID | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
test -z "$(p clear director not-a-uuid | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
test -z "$(p clear director $SID | HERDR_ENV=1 $H)"
test -z "$(printf 'not json' | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
test -z "$(p clear director $SID | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/1.sock $H)"
test -z "$(printf '{"hook_event_name":"Stop","source":"clear","agent_type":"director","session_id":"%s","cwd":"%s"}' $SID "$FX_REPO" | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
test -z "$(printf '{"hook_event_name":"SessionStart","source":"clear","agent_type":"director","session_id":"%s"}' $SID | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
test -z "$(p resume director $SID | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
# no gate case above may have re-claimed the fixture lease
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
SH

check "hook: clear in the owning director wraps the INFO block and re-claims" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
printf '{"hook_event_name":"SessionStart","source":"clear","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" python3 "$REPO_ROOT/claude/hooks/director_rollover.py" > "$FX/h" && rc=0 || rc=$?
test "$rc" = 0
python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))["hookSpecificOutput"]
assert d["hookEventName"] == "SessionStart"
assert d["additionalContext"].startswith("[INFO] herdr director rollover"), d
assert re.search(r"fence=%d$" % (int(sys.argv[2]) + 1), d["additionalContext"], re.M), d
' "$FX/h" "$F1"
SH

check "hook: silent when the lease pid is not an ancestor" <<'SH'
sleep 60 & SIB=$!
SOCK=/tmp/cc-socks/$SIB.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $SIB --messaging-socket "$SOCK" >/dev/null
printf '{"hook_event_name":"SessionStart","source":"compact","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" python3 "$REPO_ROOT/claude/hooks/director_rollover.py" > "$FX/h" && rc=0 || rc=$?
kill $SIB
test "$rc" = 0
test ! -s "$FX/h"
SH

check "hook: a failing claim wraps the WARNING block and still exits 0" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK" >/dev/null
: > "$FX/not-a-dir"
printf '{"hook_event_name":"SessionStart","source":"clear","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | HERDR_COORDINATION_ROOT="$FX/not-a-dir" HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" \
    python3 "$REPO_ROOT/claude/hooks/director_rollover.py" > "$FX/h" && rc=0 || rc=$?
test "$rc" = 0
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]
assert d.startswith("[WARNING] herdr director rollover: lease NOT re-established ("), d
' "$FX/h"
SH

check "hook: executable, python3 shebang, registered on clear|compact" <<'SH'
test -x "$REPO_ROOT/claude/hooks/director_rollover.py"
head -n 1 "$REPO_ROOT/claude/hooks/director_rollover.py" | grep -qxF '#!/usr/bin/env python3'
python3 - <<'PY'
import json, os
t = json.load(open(os.environ["REPO_ROOT"] + "/claude/settings.json.tmpl"))
hits = [e for e in t["hooks"]["SessionStart"]
        if any(h.get("command") == "~/.claude/hooks/director_rollover.py" for h in e["hooks"])]
assert len(hits) == 1 and hits[0]["matcher"] == "clear|compact", hits
PY
SH

rm -f "$ROLLOVER_STUB"; rm -rf "$SCREENS"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
