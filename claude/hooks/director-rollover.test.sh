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
unset HERDR_ENV CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_SESSION_ID HERDR_PANE_ID HERDR_ROLLOVER_TOKEN
TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || TMPDIR=""
[ -n "$TMPDIR" ] || TMPDIR=/tmp
TMPDIR=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMPDIR")
export TMPDIR
PASS=0
FAIL=0
REPO_ROOT=$(pwd)
export REPO_ROOT

# An armed-pane `gh`: any check that is not itself testing the unarmed gate
# prepends this to PATH so the new director_rollover armed check passes
# through to the behavior under test.
ARMED_GH_BIN="$TMPDIR/rollover-armed-gh.$$"
mkdir -p "$ARMED_GH_BIN"
printf '#!/bin/sh\n# gh_post_shim.py\nexit 0\n' > "$ARMED_GH_BIN/gh"
chmod +x "$ARMED_GH_BIN/gh"
export ARMED_GH_BIN

# check LABEL -- runs a sh snippet on stdin in a fresh fixture: a git repo
# with a fake origin (FX_REPO, FX_SLUG), temp config/coordination roots, and
# CORE pointing at the core CLI. Exit 0 pass, non-zero fail.
check() {
    label="$1"
    body=$(cat)  # read the snippet before any fixture command can touch stdin
    FX=$(mktemp -d); export FX
    FX_SOCKS="/tmp/cc-socks-9$(python3 -c 'import random; print("%09d" % random.randrange(10**9))')"
    export FX_SOCKS
    mkdir -m 700 "$FX_SOCKS"
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
    rm -rf "$FX" "$FX_SOCKS"
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
SOCK=$FX_SOCKS/$$.sock
: > "$SOCK"
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

check "pid_start: process_start_id, _valid_owner, _owner_metadata, _adoptable matrix" <<'SH'
python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_coordination as co
me = co.process_start_id(os.getpid())
assert isinstance(me, str) and me and me == co.process_start_id(os.getpid()), me
assert co.process_start_id(1) not in (None, me)
assert co.process_start_id(99999999) is None
assert co.process_start_id(0) is None and co.process_start_id("1") is None
base = {"session_id": "a", "host": "h", "pid": 42, "fence": 3, "heartbeat_ts": time.time()}
assert co._valid_owner(base) and co._valid_owner(dict(base, pid_start="ps:x"))
for bad in (5, "", "x" * 129, None):
    assert not co._valid_owner(dict(base, pid_start=bad)), bad
    assert not co._valid_pid_start(bad), bad
assert co._owner_metadata(dict(base, pid_start="ps:x"))["pid_start"] == "ps:x"
assert "pid_start" not in co._owner_metadata(base)
assert "pid_start" not in co._observation(dict(base, pid_start="ps:x"))
old = {"session_id": "a", "pid": 42, "runtime": "claude", "thread_id": None, "account_id": "acct",
       "control_tier": "launcher", "heartbeat_ts": time.time(), "fence": 3, "pid_start": "ps:a"}
tx = object.__new__(co.OwnerTransaction)
tx.account_id = "acct"
assert tx._adoptable(old, 42, "claude", None, "ps:a")
assert not tx._adoptable(old, 42, "claude", None, "ps:b")
assert not tx._adoptable(old, 42, "claude", None, None)
legacy = {k: v for k, v in old.items() if k != "pid_start"}
assert tx._adoptable(legacy, 42, "claude", None)
assert tx._adoptable(legacy, 42, "claude", None, None)
PY
SH

check "pid_start: a fresh claim records the claimant's start identity" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK" >/dev/null
python3 - "$$" <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
import herdr_coordination as co
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    cur = dict(tx.current)
assert cur["pid"] == int(sys.argv[1]), cur
assert cur["pid_start"] == co.process_start_id(int(sys.argv[1])), cur
PY
SH

check "recycled start identity: resume-owner refuses (exit 3); claim-owner takes over (pid-recycled)" <<'SH'
SOCK=$FX_SOCKS/$$.sock
: > "$SOCK"
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
python3 - "$$" <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
import herdr_coordination as co
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
live = co.process_start_id(int(sys.argv[1]))
assert isinstance(live, str), live
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    tx.current = dict(tx.current, pid_start=live.split(":", 1)[0] + ":forged-earlier-process")
    tx._owner_write(tx.current)
PY
$CORE resume-owner --repo-path "$FX_REPO" --session 33333333-3333-4333-8333-333333333333 \
    --messaging-socket "$SOCK" > "$FX/resume" 2>&1 && rc=0 || rc=$?
test "$rc" = 3
test ! -s "$FX/resume"
out=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ --messaging-socket "$SOCK" 2>"$FX/err") && rc=0 || rc=$?
test "$rc" = 0
test "$out" -eq $((F1 + 1))
grep -q '^\[INFO\] lease holder gone (pid-recycled)' "$FX/err"
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
grep '"event":"takeover"' "$RD/rollover.jsonl" | grep -q '"reason":"pid-recycled"'
SH

check "liveness: an unconfirmed holder identity with its socket gone is taken over (socket-missing)" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket "$FX_SOCKS/$OLD.sock")
python3 - <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    tx.current = {k: v for k, v in tx.current.items() if k != "pid_start"}
    tx._owner_write(tx.current)
PY
out=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ --messaging-socket "$FX_SOCKS/$$.sock" 2>"$FX/err") && rc=0 || rc=$?
kill $OLD
test "$rc" = 0
test "$out" -eq $((F1 + 1))
grep -q '^\[INFO\] lease holder gone (socket-missing)' "$FX/err"
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
grep '"event":"takeover"' "$RD/rollover.jsonl" | grep -q '"reason":"socket-missing"'
SH

check "liveness: a start identity under the other probe scheme is unconfirmed, not recycled (BUSY)" <<'SH'
sleep 60 & OLD=$!
: > "$FX_SOCKS/$OLD.sock"
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket "$FX_SOCKS/$OLD.sock")
python3 - "$OLD" <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
import herdr_coordination as co
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
live = co.process_start_id(int(sys.argv[1]))
assert isinstance(live, str), live
other = "linux:forged-boot:1" if live.startswith("ps:") else "ps:Thu Jan  1 00:00:00 1970"
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    tx.current = dict(tx.current, pid_start=other)
    tx._owner_write(tx.current)
PY
out=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ --messaging-socket "$FX_SOCKS/$$.sock" 2>"$FX/err") && rc=0 || rc=$?
kill $OLD
test "$rc" = 1
test "$out" = BUSY
if grep -q 'lease holder gone' "$FX/err"; then exit 1; fi
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
SH

check "liveness: same-process adoption of a legacy record without its socket is not a takeover" <<'SH'
SOCK=$FX_SOCKS/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
test ! -e "$SOCK"
python3 - <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    tx.current = {k: v for k, v in tx.current.items() if k != "pid_start"}
    tx._owner_write(tx.current)
PY
F2=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ --messaging-socket "$SOCK" 2>"$FX/err")
test "$F2" -eq $((F1 + 1))
if grep -q 'lease holder gone' "$FX/err"; then exit 1; fi
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
test ! -e "$RD/rollover.jsonl"
SH

check "adopt: a legacy record without pid_start still adopts by pid and gains pid_start" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
python3 - <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    tx.current = {k: v for k, v in tx.current.items() if k != "pid_start"}
    tx._owner_write(tx.current)
PY
F2=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ --messaging-socket "$SOCK")
test "$F2" -eq $((F1 + 1))
python3 - <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    assert isinstance(tx.current.get("pid_start"), str), tx.current
PY
SH

check "resume-owner: a legacy record without pid_start still resumes and gains pid_start" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
python3 - <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    tx.current = {k: v for k, v in tx.current.items() if k != "pid_start"}
    tx._owner_write(tx.current)
PY
$CORE resume-owner --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket "$SOCK" > "$FX/info"
grep -qxF "repo_slug=$FX_SLUG session=22222222-2222-4222-8222-222222222222 fence=$((F1 + 1))" "$FX/info"
python3 - <<'PY'
import argparse, os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
c.select_payload(argparse.Namespace(repo_path=os.environ["FX_REPO"], runtime="claude",
                                    personal=False, repo_slug=os.environ["FX_SLUG"]))
with c.owner_transaction(c.repo_dir(os.environ["FX_SLUG"])) as tx:
    assert isinstance(tx.current.get("pid_start"), str), tx.current
PY
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

# Fixture: write a rollover-pending marker.
# Args: path token pane from_session from_fence ttl_secs.
WRITE_MARKER="$TMPDIR/rollover-write-marker.$$.py"
cat > "$WRITE_MARKER" <<'PY'
import json, sys, time
path, token, pane, sess, fence, ttl = sys.argv[1:7]
now = time.time()
json.dump({"v": 1, "token": token, "pane": pane, "from_session": sess,
           "from_fence": int(fence), "from_pane": "w9:p1", "carry": "",
           "created_ts": now, "expires_ts": now + float(ttl)}, open(path, "w"))
PY
export WRITE_MARKER
T=0123456789abcdef0123456789abcdef; export T

check "handover: new pane adopts through the marker" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
test -d "$RD"
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
F2=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock)
kill $OLD
test "$F2" -eq $((F1 + 1))
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --fence "$F2"
test ! -e "$RD/rollover-pending.json"
python3 - "$RD" "$$" "$T" "$F1" <<'PY'
import hashlib, json, sys
rd, pid, token, f1 = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
owner = json.load(open(rd + "/owner.json"))
assert owner["pid"] == pid and owner["messaging_socket"] == f"/tmp/cc-socks/{pid}.sock", owner
assert owner["session_id"] == "22222222-2222-4222-8222-222222222222", owner
raw = open(rd + "/rollover.jsonl").read()
assert token not in raw
lines = [json.loads(l) for l in raw.splitlines()]
assert len(lines) == 1, lines
a = lines[0]
assert a["v"] == 2 and a["event"] == "adopted", a
assert a["handover"] == hashlib.sha256(token.encode()).hexdigest()[:16], a
assert (a["from_session"], a["from_fence"]) == ("11111111-1111-4111-8111-111111111111", f1), a
assert (a["session"], a["fence"], a["pane"]) == ("22222222-2222-4222-8222-222222222222", f1 + 1, "w9:p2"), a
PY
SH

check "handover declines: wrong token (other hex, then non-hex) -> BUSY" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
for BAD in ffffffffffffffffffffffffffffffff 'é-not-hex'; do
    out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN="$BAD" $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
        --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
        --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
    test "$rc" = 1; test "$out" = BUSY
    ! grep -q Traceback "$FX/err"
done
kill $OLD
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
test -e "$RD/rollover-pending.json"
test ! -e "$RD/rollover.jsonl"
SH

check "handover declines: wrong pane -> BUSY" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
out=$(HERDR_PANE_ID=w9:p3 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
kill $OLD
test "$rc" = 1; test "$out" = BUSY
! grep -q Traceback "$FX/err"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
test -e "$RD/rollover-pending.json"
test ! -e "$RD/rollover.jsonl"
SH

check "handover declines: expired marker -> BUSY" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" -1
out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
kill $OLD
test "$rc" = 1; test "$out" = BUSY
! grep -q Traceback "$FX/err"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
test -e "$RD/rollover-pending.json"
test ! -e "$RD/rollover.jsonl"
SH

check "handover declines: marker from_fence differs from the lease -> BUSY" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$((F1 + 1))" 60
out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
kill $OLD
test "$rc" = 1; test "$out" = BUSY
! grep -q Traceback "$FX/err"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
test -e "$RD/rollover-pending.json"
test ! -e "$RD/rollover.jsonl"
SH

check "handover declines: marker from_session differs from the lease -> BUSY" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 33333333-3333-4333-8333-333333333333 "$F1" 60
out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
kill $OLD
test "$rc" = 1; test "$out" = BUSY
! grep -q Traceback "$FX/err"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
test -e "$RD/rollover-pending.json"
test ! -e "$RD/rollover.jsonl"
SH

check "handover declines: no marker -> BUSY" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
kill $OLD
test "$rc" = 1; test "$out" = BUSY
! grep -q Traceback "$FX/err"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
test ! -e "$RD/rollover.jsonl"
SH

check "handover declines: malformed marker (not JSON, bad token, bool fence) -> BUSY" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
for BODY in 'not json' \
    '{"v":1,"token":"XYZ","pane":"w9:p2","from_session":"11111111-1111-4111-8111-111111111111","from_fence":1,"from_pane":"w9:p1","carry":"","created_ts":1,"expires_ts":9999999999}' \
    "{\"v\":1,\"token\":\"$T\",\"pane\":\"w9:p2\",\"from_session\":\"11111111-1111-4111-8111-111111111111\",\"from_fence\":true,\"from_pane\":\"w9:p1\",\"carry\":\"\",\"created_ts\":1,\"expires_ts\":9999999999}"; do
    printf '%s' "$BODY" > "$RD/rollover-pending.json"
    out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
        --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
        --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
    test "$rc" = 1; test "$out" = BUSY
    ! grep -q Traceback "$FX/err"
done
kill $OLD
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
test -e "$RD/rollover-pending.json"
test ! -e "$RD/rollover.jsonl"
SH

check "handover declines: consumed marker cannot adopt twice" <<'SH'
sleep 60 & OLD=$!
sleep 60 & NEW=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
F2=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $NEW \
    --messaging-socket /tmp/cc-socks/$NEW.sock)
test "$F2" -eq $((F1 + 1))
out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 33333333-3333-4333-8333-333333333333 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
kill $OLD $NEW
test "$rc" = 1; test "$out" = BUSY
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --fence "$F2"
test "$(grep -c '"event":"adopted"' "$RD/rollover.jsonl")" = 1
SH

check "claim-owner without the variables is unchanged (BUSY)" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
out=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock 2>"$FX/err") && rc=0 || rc=$?
kill $OLD
test "$rc" = 1; test "$out" = BUSY
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
test -e "$RD/rollover-pending.json"
test ! -e "$RD/rollover.jsonl"
SH

check "liveness: a live handover marker reserves a dead holder's lease for its successor" <<'SH'
DEAD=$(python3 -c 'import subprocess; p = subprocess.Popen(["true"]); p.wait(); print(p.pid)')
: > "$FX_SOCKS/$DEAD.sock"
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid "$DEAD" --messaging-socket "$FX_SOCKS/$DEAD.sock")
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
out=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 33333333-3333-4333-8333-333333333333 --host h --pid $$ \
    --messaging-socket "$FX_SOCKS/$$.sock" 2>"$FX/err") && rc=0 || rc=$?
test "$rc" = 1; test "$out" = BUSY
if grep -q 'lease holder gone' "$FX/err"; then exit 1; fi
test ! -e "$RD/rollover.jsonl"
F2=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket "$FX_SOCKS/$$.sock" 2>"$FX/err")
test "$F2" -eq $((F1 + 1))
if grep -q 'lease holder gone' "$FX/err"; then exit 1; fi
test "$(grep -c '"event":"adopted"' "$RD/rollover.jsonl")" = 1
test "$(grep -c '"event":"takeover"' "$RD/rollover.jsonl")" = 0
SH

check "token set, no marker: same-process adoption still adopts" <<'SH'
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
F2=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock)
test "$F2" -eq $((F1 + 1))
test -z "$(find "$FX" -name rollover.jsonl)"
SH

check "token set, no marker: stale lease is taken over" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
F2=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock --stale-secs 0)
kill $OLD
test "$F2" -eq $((F1 + 1))
SH

check "handover_adoptable matrix: session/fence, new session, runtime, thread, account, tier" <<'SH'
python3 - <<'PY'
import os, sys, time
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_coordination as co
old = {"session_id": "a", "pid": 42, "runtime": "claude", "thread_id": None,
       "account_id": "acct", "control_tier": "launcher", "heartbeat_ts": time.time(), "fence": 3}
tx = object.__new__(co.OwnerTransaction)
tx.account_id = "acct"
assert tx.handover_adoptable(old, ("a", 3), "b", "claude", None)
assert not tx.handover_adoptable(old, None, "b", "claude", None)
assert not tx.handover_adoptable(None, ("a", 3), "b", "claude", None)
assert not tx.handover_adoptable(old, ("a", 4), "b", "claude", None)
assert not tx.handover_adoptable(old, ("z", 3), "b", "claude", None)
assert not tx.handover_adoptable(old, ("a", 3), "a", "claude", None)
assert not tx.handover_adoptable(old, ("a", 3), "b", "codex", "t")
assert not tx.handover_adoptable(dict(old, runtime="codex", thread_id="t"), ("a", 3), "b", "claude", None)
assert not tx.handover_adoptable(old, ("a", 3), "b", "claude", "t")
assert not tx.handover_adoptable(dict(old, account_id="other"), ("a", 3), "b", "claude", None)
assert not tx.handover_adoptable(dict(old, control_tier="lead"), ("a", 3), "b", "claude", None)
PY
SH

# Scripted herdr for the handover checks; logs every call to $FX/herdr.log.
# pane split: $FX/fail.split makes it fail; saves the --env token to
#   $FX/token; runs $FX/on-split if present; replies pane w9:p2.
# pane run: $FX/fail.run makes it fail; runs $FX/on-run if present, then
#   $FX/fail.run.after makes it fail.
# anything else: ok.
HANDOVER_STUB="$TMPDIR/rollover-handover-stub.$$"
cat > "$HANDOVER_STUB" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$FX/herdr.log"
case "$1 $2" in
  "pane split")
    [ -e "$FX/fail.split" ] && { echo boom >&2; exit 7; }
    for a in "$@"; do case "$a" in HERDR_ROLLOVER_TOKEN=*) printf '%s' "${a#HERDR_ROLLOVER_TOKEN=}" > "$FX/token" ;; esac; done
    [ -e "$FX/on-split" ] && sh "$FX/on-split" >> "$FX/hook.log" 2>&1
    printf '{"id":"x","result":{"pane":{"pane_id":"w9:p2"}}}\n' ;;
  "pane run")
    [ -e "$FX/fail.run" ] && { echo boom >&2; exit 7; }
    [ -e "$FX/on-run" ] && sh "$FX/on-run" >> "$FX/hook.log" 2>&1
    [ -e "$FX/fail.run.after" ] && { echo boom >&2; exit 7; }
    printf '{"id":"x","result":{"type":"ok"}}\n' ;;
  *) printf '{"id":"x","result":{"type":"ok"}}\n' ;;
esac
STUB
chmod +x "$HANDOVER_STUB"
export HANDOVER_STUB

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

check "rollover: hands over to a new pane on ack, kills its watch, never types into a pane" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
sleep 60 & NEW=$!
python3 -c 'import time; time.sleep(60)' herdr_orch_core.py watch --repo-slug "$FX_SLUG" --since-epoch 1 & W=$!
cat > "$FX/on-run" <<EOF
HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=\$(cat "$FX/token") $CORE adopt-rollover --repo-path "$FX_REPO" \
    --session 22222222-2222-4222-8222-222222222222 --messaging-socket /tmp/cc-socks/$NEW.sock
EOF
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$$.sock \
    $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --carry "hold merges" \
    --ack-secs 20 --poll-secs 0.1 > "$FX/o" && rc=0 || rc=$?
wait $W && wrc=0 || wrc=$?
kill $NEW
test "$rc" = 0
test "$wrc" = 143
grep -qxF "rollover: handed over to pane w9:p2 (session 22222222-2222-4222-8222-222222222222, fence $((F + 1)))" "$FX/o"
grep -qxF "watch: stopped (pids $W)" "$FX/o"
grep -qxF 'Close this pane now, as your last tool call: herdr pane close w9:p1' "$FX/o"
grep -q '^\[INFO\] herdr director rollover: lease handed over' "$FX/hook.log"
grep -qxF 'carried: hold merges' "$FX/hook.log"
REAL_REPO=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$FX_REPO")
grep -q "^pane split w9:p1 --direction right --cwd $REAL_REPO --env HERDR_ROLLOVER_TOKEN=" "$FX/herdr.log"
grep -qxF "pane run w9:p2 director 'resume director'" "$FX/herdr.log"
! grep -q 'send-text\|send-keys\|pane close' "$FX/herdr.log"
TOKEN=$(cat "$FX/token")
! grep -q "$TOKEN" "$FX/o"
LOG=$(find "$FX" -name rollover.jsonl)
! grep -q "$TOKEN" "$LOG"
grep -q '"event":"adopted"' "$LOG"
grep -q '"event":"handed-over"' "$LOG"
test -z "$(find "$FX" -name rollover-pending.json)"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --fence $((F + 1))
SH

check "rollover: no ack within the bound keeps the lease, removes the marker, closes the new pane" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$$.sock \
    $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 1 --poll-secs 0.1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
grep -qxF "rollover: no ack from pane w9:p2 within 1 s; this session keeps the lease (fence $F)" "$FX/o"
test "$(tail -n 1 "$FX/herdr.log")" = "pane close w9:p2"
test -z "$(find "$FX" -name rollover-pending.json)"
grep -q '"event":"handover-failed".*"reason":"no-ack"' "$(find "$FX" -name rollover.jsonl)"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F"
SH

check "rollover: an ack whose adoption never landed keeps the lease and closes the pane" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
cat > "$FX/on-run" <<EOF
python3 -c '
import hashlib, json, sys
tok = open(sys.argv[1]).read()
line = {"v": 2, "ts": "x", "event": "adopted", "handover": hashlib.sha256(tok.encode()).hexdigest()[:16],
        "from_session": "11111111-1111-4111-8111-111111111111", "from_fence": int(sys.argv[3]),
        "session": "22222222-2222-4222-8222-222222222222", "fence": int(sys.argv[3]) + 1, "pane": "w9:p2"}
open(sys.argv[2], "a").write(json.dumps(line) + "\n")
' "$FX/token" "$RD/rollover.jsonl" "$F"
EOF
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 5 --poll-secs 0.1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
grep -q 'this session keeps the lease' "$FX/o"
test "$(tail -n 1 "$FX/herdr.log")" = "pane close w9:p2"
grep -q '"reason":"adoption-incomplete"' "$RD/rollover.jsonl"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F"
SH

check "rollover: split failure writes no marker and keeps the lease" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"; : > "$FX/fail.split"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
grep -qxF 'rollover: pane split failed; this session keeps the lease' "$FX/o"
test -z "$(find "$FX" -name rollover-pending.json)"
! grep -q 'pane close' "$FX/herdr.log"
grep -q '"reason":"split-failed"' "$(find "$FX" -name rollover.jsonl)"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F"
SH

check "rollover: pane run failure removes the marker and closes the new pane" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"; : > "$FX/fail.run"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
grep -qxF 'rollover: could not start director in pane w9:p2; this session keeps the lease' "$FX/o"
test "$(tail -n 1 "$FX/herdr.log")" = "pane close w9:p2"
test -z "$(find "$FX" -name rollover-pending.json)"
grep -q '"reason":"run-failed"' "$(find "$FX" -name rollover.jsonl)"
SH

check "rollover: pane run fails after the new pane adopted -> handed over, pane left open" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"; : > "$FX/fail.run.after"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
sleep 60 & NEW=$!
cat > "$FX/on-run" <<EOF
HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=\$(cat "$FX/token") $CORE adopt-rollover --repo-path "$FX_REPO" \
    --session 22222222-2222-4222-8222-222222222222 --messaging-socket /tmp/cc-socks/$NEW.sock
EOF
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$$.sock \
    $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 20 --poll-secs 0.1 > "$FX/o" && rc=0 || rc=$?
kill $NEW
test "$rc" = 0
grep -qxF "rollover: handed over to pane w9:p2 (session 22222222-2222-4222-8222-222222222222, fence $((F + 1)))" "$FX/o"
! grep -q 'keeps the lease' "$FX/o"
! grep -q 'pane close' "$FX/herdr.log"
test -z "$(find "$FX" -name rollover-pending.json)"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 22222222-2222-4222-8222-222222222222 --fence $((F + 1))
SH

check "rollover: fence lost between split and marker closes the new pane, writes no marker" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
cat > "$FX/on-split" <<EOF
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 33333333-3333-4333-8333-333333333333 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock
EOF
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
grep -qxF 'owner: stale-fence' "$FX/o"
test "$(tail -n 1 "$FX/herdr.log")" = "pane close w9:p2"
! grep -q '^pane run' "$FX/herdr.log"
test -z "$(find "$FX" -name rollover-pending.json)"
SH

check "rollover: lease moved without an ack -> lease-moved, pane left open" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
cat > "$FX/on-run" <<EOF
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 33333333-3333-4333-8333-333333333333 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock
EOF
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 1 --poll-secs 0.1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
grep -qxF 'rollover: lease moved without a handover ack; run the section-1 preflight' "$FX/o"
! grep -q 'keeps the lease' "$FX/o"
! grep -q 'pane close' "$FX/herdr.log"
test -z "$(find "$FX" -name rollover-pending.json)"
grep -q '"reason":"lease-moved"' "$(find "$FX" -name rollover.jsonl)"
SH

check "rollover: an unexpired own marker refuses with no herdr call" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p5 11111111-1111-4111-8111-111111111111 "$F" 60
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
grep -qxF 'rollover: rollover in progress for pane w9:p5' "$FX/o"
test ! -e "$FX/herdr.log"
test -e "$RD/rollover-pending.json"
SH

check "rollover: an expired own marker closes its pane, is removed, and the rollover proceeds" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p5 11111111-1111-4111-8111-111111111111 "$F" -1
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --ack-secs 1 --poll-secs 0.1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
test "$(head -n 1 "$FX/herdr.log")" = "pane close w9:p5"
grep -q '^pane split w9:p1 ' "$FX/herdr.log"
grep -q '"reason":"expired".*"to_pane":"w9:p5"' "$RD/rollover.jsonl"
grep -q '"reason":"no-ack"' "$RD/rollover.jsonl"
SH

check "rollover: a stale fence after a completed handover reports handed over" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE claim-owner --repo-path "$FX_REPO" --runtime claude \
    --repo-slug "$FX_SLUG" --session 22222222-2222-4222-8222-222222222222 --host h --pid $$ \
    --messaging-socket /tmp/cc-socks/$$.sock >/dev/null
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$OLD.sock \
    $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1" > "$FX/o" && rc=0 || rc=$?
kill $OLD
test "$rc" = 0
grep -qxF "rollover: handed over to pane w9:p2 (session 22222222-2222-4222-8222-222222222222, fence $((F1 + 1)))" "$FX/o"
grep -qxF 'watch: none found' "$FX/o"
grep -qxF 'Close this pane now, as your last tool call: herdr pane close w9:p1' "$FX/o"
test ! -e "$FX/herdr.log"
SH

check "rollover: a retry after /clear closes the superseded marker's pane and proceeds" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p5 11111111-1111-4111-8111-111111111111 "$F" 60
F2=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 33333333-3333-4333-8333-333333333333 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 33333333-3333-4333-8333-333333333333 --fence "$F2" --ack-secs 1 --poll-secs 0.1 > "$FX/o" && rc=0 || rc=$?
test "$rc" = 1
test "$(head -n 1 "$FX/herdr.log")" = "pane close w9:p5"
grep -q '^pane split w9:p1 ' "$FX/herdr.log"
grep -q '"reason":"superseded".*"to_pane":"w9:p5"' "$RD/rollover.jsonl"
grep -qxF "rollover: no ack from pane w9:p2 within 1 s; this session keeps the lease (fence $F2)" "$FX/o"
SH

check "rollover: a stale fence with an ack whose adoption never landed reports stale-fence" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
printf '{"v":2,"ts":"x","event":"adopted","handover":"0000000000000000","from_session":"11111111-1111-4111-8111-111111111111","from_fence":%s,"session":"22222222-2222-4222-8222-222222222222","fence":%s,"pane":"w9:p2"}\n' "$F" "$((F + 1))" >> "$RD/rollover.jsonl"
F2=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
test "$F2" -gt "$F"
out=$(PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F") && rc=0 || rc=$?
test "$rc" = 1
test "$out" = "owner: stale-fence"
test ! -e "$FX/herdr.log"
SH

check "rollover: --carry over the limit exits 2 before any herdr call" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
BIG=$(python3 -c 'print("x" * 4001)')
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F" --carry "$BIG" 2>/dev/null && rc=0 || rc=$?
test "$rc" = 2
test ! -e "$FX/herdr.log"
SH

check "rollover_launch: personal scope adds --personal" <<'SH'
python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["REPO_ROOT"] + "/claude/hooks")
import herdr_orch_core as c
assert c.rollover_launch("personal") == "director --personal 'resume director'"
assert c.rollover_launch("work") == "director 'resume director'"
PY
SH

check "hook: silent on every gate failure" <<'SH'
export PATH="$ARMED_GH_BIN:$PATH"
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
export PATH="$ARMED_GH_BIN:$PATH"
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
! grep -q 'auto-resume:' "$FX/h"
SH

check "hook: silent when the lease pid is not an ancestor" <<'SH'
export PATH="$ARMED_GH_BIN:$PATH"
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
export PATH="$ARMED_GH_BIN:$PATH"
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

check "hook: unarmed pane (plain gh on PATH) warns before any lease gate -- case unarmed" <<'SH'
mkdir -p "$FX/plaingh"
printf '#!/bin/sh\nexit 0\n' > "$FX/plaingh/gh"
chmod +x "$FX/plaingh/gh"
SOCK=/tmp/cc-socks/$$.sock
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK")
printf '{"hook_event_name":"SessionStart","source":"startup","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | PATH="$FX/plaingh:$PATH" HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" \
    python3 "$REPO_ROOT/claude/hooks/director_rollover.py" > "$FX/h" && rc=0 || rc=$?
test "$rc" = 0
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]
assert d.startswith("[WARNING]"), d
assert "unarmed" in d, d
' "$FX/h"
# no lease gate ran: the fixture claim is untouched
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
SH

check "hook: armed pane (gh shim on PATH) skips the unarmed warning -- case unarmed" <<'SH'
SOCK=/tmp/cc-socks/$$.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK" >/dev/null
out=$(printf '{"hook_event_name":"SessionStart","source":"startup","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | PATH="$ARMED_GH_BIN:$PATH" HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" \
    python3 "$REPO_ROOT/claude/hooks/director_rollover.py")
test -z "$out"
SH

check "hook: pr_post_guard import failure exits 0 silently -- case unarmed" <<'SH'
mkdir -p "$FX/noguard"
cp "$REPO_ROOT/claude/hooks/director_rollover.py" "$FX/noguard/"
out=$(printf '{"hook_event_name":"SessionStart","source":"startup","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | HERDR_ENV=1 python3 "$FX/noguard/director_rollover.py")
test -z "$out"
SH

check "adopt-rollover: exit 0 prints the handover INFO block with carried notes" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
python3 - "$RD/rollover-pending.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["carry"] = "ask the human about PR 12\n\nhold merges"
json.dump(m, open(p, "w"))
PY
HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE adopt-rollover --repo-path "$FX_REPO" \
    --session 22222222-2222-4222-8222-222222222222 --messaging-socket /tmp/cc-socks/$$.sock > "$FX/info" && rc=0 || rc=$?
kill $OLD
test "$rc" = 0
grep -qxF '[INFO] herdr director rollover: lease handed over from session 11111111-1111-4111-8111-111111111111 (pane w9:p1).' "$FX/info"
grep -qxF "repo_slug=$FX_SLUG session=22222222-2222-4222-8222-222222222222 fence=$((F1 + 1))" "$FX/info"
test "$(grep -c '^carried: ' "$FX/info")" = 2
grep -qxF 'carried: ask the human about PR 12' "$FX/info"
grep -qxF 'carried: hold merges' "$FX/info"
grep -q '^watch: none found' "$FX/info"
grep -q '^Next: load the herdr-orchestration skill' "$FX/info"
SH

check "adopt-rollover: exit 3 silent without the variables, without a marker, for another pane's marker, or for an expired marker" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
out=$($CORE adopt-rollover --repo-path "$FX_REPO" --session 22222222-2222-4222-8222-222222222222 \
    --messaging-socket /tmp/cc-socks/$$.sock) && rc=0 || rc=$?
test "$rc" = 3; test -z "$out"
out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE adopt-rollover --repo-path "$FX_REPO" \
    --session 22222222-2222-4222-8222-222222222222 --messaging-socket /tmp/cc-socks/$$.sock) && rc=0 || rc=$?
test "$rc" = 3; test -z "$out"
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p5 11111111-1111-4111-8111-111111111111 "$F1" 60
out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE adopt-rollover --repo-path "$FX_REPO" \
    --session 22222222-2222-4222-8222-222222222222 --messaging-socket /tmp/cc-socks/$$.sock) && rc=0 || rc=$?
test "$rc" = 3; test -z "$out"
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" -1
out=$(HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T $CORE adopt-rollover --repo-path "$FX_REPO" \
    --session 22222222-2222-4222-8222-222222222222 --messaging-socket /tmp/cc-socks/$$.sock) && rc=0 || rc=$?
kill $OLD
test "$rc" = 3; test -z "$out"
test -e "$RD/rollover-pending.json"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
SH

check "adopt-rollover: exit 1 WARNING when this pane's marker refuses the token" <<'SH'
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=ffffffffffffffffffffffffffffffff $CORE adopt-rollover --repo-path "$FX_REPO" \
    --session 22222222-2222-4222-8222-222222222222 --messaging-socket /tmp/cc-socks/$$.sock > "$FX/info" && rc=0 || rc=$?
kill $OLD
test "$rc" = 1
head -n 1 "$FX/info" | grep -qxF '[WARNING] herdr director rollover: lease NOT re-established (BUSY).'
SH

check "hook: startup in a handed-over pane adopts and emits the INFO block" <<'SH'
export PATH="$ARMED_GH_BIN:$PATH"
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
printf '{"hook_event_name":"SessionStart","source":"startup","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | HERDR_ENV=1 HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$$.sock \
    python3 "$REPO_ROOT/claude/hooks/director_rollover.py" > "$FX/h" && rc=0 || rc=$?
kill $OLD
test "$rc" = 0
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]
assert d.startswith("[INFO] herdr director rollover: lease handed over from session 11111111-1111-4111-8111-111111111111 (pane w9:p1)."), d
assert ("fence=%d" % (int(sys.argv[2]) + 1)) in d, d
' "$FX/h" "$F1"
test ! -e "$RD/rollover-pending.json"
SH

check "hook: startup handover is silent for a non-director and without HERDR_ENV" <<'SH'
export PATH="$ARMED_GH_BIN:$PATH"
sleep 60 & OLD=$!
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 11111111-1111-4111-8111-111111111111 "$F1" 60
p() { printf '{"hook_event_name":"SessionStart","source":"startup","agent_type":"%s","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$1" "$FX_REPO"; }
test -z "$(p worker | HERDR_ENV=1 HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$$.sock python3 "$REPO_ROOT/claude/hooks/director_rollover.py")"
test -z "$(p director | HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$$.sock python3 "$REPO_ROOT/claude/hooks/director_rollover.py")"
kill $OLD
test -e "$RD/rollover-pending.json"
$CORE check-fence --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --fence "$F1"
SH

check "statusline: records host context fill for a herdr session only; meter unchanged" <<'SH'
unset CLAUDE_CODE_AUTO_COMPACT_WINDOW
node - <<'JS'
const fs = require("fs"), path = require("path");
const sl = require(process.env.REPO_ROOT + "/claude/statusline.js");
const dir = process.env.FX + "/cfg";
const sid = "11111111-1111-4111-8111-111111111111";
const data = { session_id: sid, context_window: { remaining_percentage: 60, total_tokens: 1000000 } };
// (60 - 16.5) / 83.5 = 52.1% usable left -> 48% used, the meter's own figure.
if (sl.usedPercent(60, 1000000) !== 48) throw new Error("used " + sl.usedPercent(60, 1000000));
if (!sl.buildContextMeter(60, 1000000).includes(" 48%")) throw new Error("meter changed");
sl.recordContext(data, { HERDR_ENV: "1", CLAUDE_CONFIG_DIR: dir }, 1700000000123);
const rec = JSON.parse(fs.readFileSync(path.join(dir, "herdr-orch/context", sid + ".json"), "utf8"));
if (rec.v !== 1 || rec.session_id !== sid || rec.used_pct !== 48 || rec.ts !== 1700000000)
  throw new Error(JSON.stringify(rec));
sl.recordContext(data, { CLAUDE_CONFIG_DIR: dir + "-off" }, 1);
if (fs.existsSync(dir + "-off")) throw new Error("wrote without HERDR_ENV");
sl.recordContext({ ...data, session_id: "../escape" }, { HERDR_ENV: "1", CLAUDE_CONFIG_DIR: dir }, 1);
if (fs.readdirSync(path.join(dir, "herdr-orch/context")).length !== 1) throw new Error("bad id written");
JS
SH

check "hook: executable, python3 shebang, registered on startup|resume|clear|compact" <<'SH'
test -x "$REPO_ROOT/claude/hooks/director_rollover.py"
head -n 1 "$REPO_ROOT/claude/hooks/director_rollover.py" | grep -qxF '#!/usr/bin/env python3'
python3 - <<'PY'
import json, os
t = json.load(open(os.environ["REPO_ROOT"] + "/claude/settings.json.tmpl"))
hits = [e for e in t["hooks"]["SessionStart"]
        if any(h.get("command") == "~/.claude/hooks/director_rollover.py" for h in e["hooks"])]
assert len(hits) == 1 and hits[0]["matcher"] == "startup|resume|clear|compact", hits
PY
SH

# Decisions log: shared fixture lines for the checks below are inlined per
# check on purpose (each reads top to bottom).

check "decisions: note-decision appends one line and decisions prints it" <<'SH'
S1=11111111-1111-4111-8111-111111111111
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $$)
A="--repo-path $FX_REPO --runtime claude --repo-slug $FX_SLUG --session $S1 --fence $F"
out=$($CORE note-decision $A --task some-task --text "  fix N1 only  ")
printf '%s\n' "$out" | grep -Eqx 'decision: [0-9a-f]{12}'
LOG=$(find "$FX" -name decisions.jsonl -type f)
test -n "$LOG"
python3 - "$LOG" <<'PY'
import json, sys
rec = json.loads(open(sys.argv[1]).read().splitlines()[-1])
assert set(rec) == {"v", "ts", "id", "event", "task", "source", "batch", "text", "session", "fence"}, rec
assert rec["event"] == "decision" and rec["task"] == "some-task" and rec["source"] == "owner", rec
assert rec["batch"] is None and rec["text"] == "fix N1 only", rec
PY
$CORE note-decision $A --repo-wide --text "ship serially" >/dev/null
b=$($CORE decisions --repo-path "$FX_REPO")
printf '%s\n' "$b" | head -n 1 | grep -q '^\[INFO\] herdr decisions:'
printf '%s\n' "$b" | grep -Eq -- '^- [0-9]{4}-[0-9]{2}-[0-9]{2} some-task: fix N1 only \[[0-9a-f]{12}\]$'
printf '%s\n' "$b" | grep -Eq -- '^- [0-9]{4}-[0-9]{2}-[0-9]{2} repo: ship serially \[[0-9a-f]{12}\]$'
SH

check "decisions: stale fence refuses note-decision and retire-decision, nothing appended" <<'SH'
S1=11111111-1111-4111-8111-111111111111
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $$)
A="--repo-path $FX_REPO --runtime claude --repo-slug $FX_SLUG --session $S1"
id=$($CORE note-decision $A --fence "$F" --repo-wide --text keep)
id=${id#decision: }
LOG=$(find "$FX" -name decisions.jsonl -type f)
n=$(wc -l < "$LOG")
if $CORE note-decision $A --fence $((F + 7)) --repo-wide --text stale >/dev/null 2>&1; then exit 1; fi
if $CORE retire-decision $A --fence $((F + 7)) --id "$id" >/dev/null 2>&1; then exit 1; fi
if $CORE note-decision $A --session 33333333-3333-4333-8333-333333333333 --fence "$F" --repo-wide --text x >/dev/null 2>&1; then exit 1; fi
test "$(wc -l < "$LOG")" -eq "$n"
SH

check "decisions: note-decision input validation refuses bad text, scope flags and task id" <<'SH'
S1=11111111-1111-4111-8111-111111111111
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $$)
A="--repo-path $FX_REPO --runtime claude --repo-slug $FX_SLUG --session $S1 --fence $F"
if $CORE note-decision $A --repo-wide --text "   " >/dev/null 2>&1; then exit 1; fi
if $CORE note-decision $A --repo-wide --text "$(python3 -c 'print("x" * 501)')" >/dev/null 2>&1; then exit 1; fi
if $CORE note-decision $A --repo-wide --text "$(printf 'a\nb')" >/dev/null 2>&1; then exit 1; fi
if $CORE note-decision $A --repo-wide --text "$(printf 'a\rb')" >/dev/null 2>&1; then exit 1; fi
if $CORE note-decision $A --repo-wide --task t1 --text y >/dev/null 2>&1; then exit 1; fi
if $CORE note-decision $A --text y >/dev/null 2>&1; then exit 1; fi
if $CORE note-decision $A --task ../x --text y >/dev/null 2>&1; then exit 1; fi
test -z "$(find "$FX" -name decisions.jsonl -type f)"
$CORE note-decision $A --repo-wide --text "$(python3 -c 'print("x" * 500)')" >/dev/null
$CORE note-decision $A --task never-recorded --text ok >/dev/null
test "$(wc -l < "$(find "$FX" -name decisions.jsonl -type f)")" -eq 2
SH

check "decisions: retire-decision hides the entry, repeats are no-ops, unknown id refused" <<'SH'
S1=11111111-1111-4111-8111-111111111111
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $$)
A="--repo-path $FX_REPO --runtime claude --repo-slug $FX_SLUG --session $S1 --fence $F"
id=$($CORE note-decision $A --repo-wide --text "retry in 10 minutes")
id=${id#decision: }
$CORE decisions --repo-path "$FX_REPO" | grep -q 'retry in 10 minutes'
test "$($CORE retire-decision $A --id "$id")" = "retired: $id"
test -z "$($CORE decisions --repo-path "$FX_REPO")"
LOG=$(find "$FX" -name decisions.jsonl -type f)
n=$(wc -l < "$LOG")
test "$($CORE retire-decision $A --id "$id")" = "decision: $id already retired"
if $CORE retire-decision $A --id 000000000000 >/dev/null 2>&1; then exit 1; fi
test "$(wc -l < "$LOG")" -eq "$n"
SH

check "decisions: terminal and archived task entries drop, unknown-task and repo-wide stay" <<'SH'
S1=11111111-1111-4111-8111-111111111111
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $$)
A="--repo-path $FX_REPO --runtime claude --repo-slug $FX_SLUG --session $S1 --fence $F"
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
for t in t-open t-failed t-abandoned t-merged t-archived t-unknown; do
    $CORE note-decision $A --task $t --text "note for $t" >/dev/null
done
$CORE note-decision $A --repo-wide --text "note for repo" >/dev/null
mkdir -p "$RD/tasks" "$RD/archive/2026-09/tasks"
printf '{"status":"implementing"}' > "$RD/tasks/t-open.json"
printf '{"status":"failed"}' > "$RD/tasks/t-failed.json"
printf '{"status":"abandoned"}' > "$RD/tasks/t-abandoned.json"
printf '{"status":"merged"}' > "$RD/tasks/t-merged.json"
printf '{"status":"merged"}' > "$RD/archive/2026-09/tasks/t-archived.json"
printf 'not json\n[1]\n{"v":2,"event":"decision","text":"other version","ts":"2026-10-07T00:00:00Z"}\n' >> "$(find "$FX" -name decisions.jsonl -type f)"
b=$($CORE decisions --repo-path "$FX_REPO")
for t in t-open t-unknown repo; do printf '%s\n' "$b" | grep -q "note for $t "; done
for t in t-failed t-abandoned t-merged t-archived; do ! printf '%s\n' "$b" | grep -q "note for $t "; done
! printf '%s\n' "$b" | grep -q 'other version'
SH

check "decisions: rollover carry lands in the log, latest batch only, --no-carry hides it" <<'SH'
cp "$HANDOVER_STUB" "$FX/bin/herdr"
S1=11111111-1111-4111-8111-111111111111
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $$ --messaging-socket /tmp/cc-socks/$$.sock)
roll() {
    PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$$.sock \
        $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" --session $S1 --fence "$F" \
        --carry "$1" --ack-secs 1 --poll-secs 0.1 >/dev/null || true
}
roll "$(printf 'first note\nsecond note')"
LOG=$(find "$FX" -name decisions.jsonl -type f)
python3 - "$LOG" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
assert [r["event"] for r in recs] == ["carry-batch", "decision", "decision"], recs
assert recs[1]["batch"] == recs[2]["batch"] == recs[0]["batch"], recs
assert recs[1]["source"] == "carry" and recs[1]["task"] is None, recs
PY
b=$($CORE decisions --repo-path "$FX_REPO")
printf '%s\n' "$b" | grep -Eq -- 'carried: first note \['
printf '%s\n' "$b" | grep -Eq -- 'carried: second note \['
test -z "$($CORE decisions --repo-path "$FX_REPO" --no-carry)"
roll "later note"
b=$($CORE decisions --repo-path "$FX_REPO")
! printf '%s\n' "$b" | grep -q 'first note'
printf '%s\n' "$b" | grep -qF 'carried: later note ['
roll ""
test -z "$($CORE decisions --repo-path "$FX_REPO")"
long=$(python3 -c 'print("".join(chr(97 + i % 26) for i in range(1200)))')
roll "$long"
python3 - "$LOG" "$long" <<'PY'
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
batch = [r for r in recs if r["event"] == "carry-batch"][-1]["batch"]
chunks = [r["text"] for r in recs if r["event"] == "decision" and r["batch"] == batch]
assert len(chunks) == 3, chunks
assert chunks[1].startswith("(cont.) ") and chunks[2].startswith("(cont.) "), chunks
assert chunks[0] + chunks[1][8:] + chunks[2][8:] == sys.argv[2]
PY
SH

check "decisions: block capped at 3000 chars with omission line, --all prints every entry" <<'SH'
S1=11111111-1111-4111-8111-111111111111
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $$)
A="--repo-path $FX_REPO --runtime claude --repo-slug $FX_SLUG --session $S1 --fence $F"
T=$(python3 -c 'print("x" * 390)')
i=0
while [ $i -lt 30 ]; do $CORE note-decision $A --repo-wide --text "n$i $T" >/dev/null; i=$((i + 1)); done
b=$($CORE decisions --repo-path "$FX_REPO")
test "$(printf '%s' "$b" | wc -c)" -le 3000
printf '%s\n' "$b" | tail -n 1 | grep -Eq '^\([0-9]+ older omitted; full list: python3 ~/\.claude/hooks/herdr_orch_core\.py decisions --repo-path .+ --all\)$'
printf '%s\n' "$b" | grep -q ' repo: n29 '
! printf '%s\n' "$b" | grep -q ' repo: n0 '
test "$($CORE decisions --repo-path "$FX_REPO" --all | grep -c ' repo: n[0-9]* ')" -eq 30
SH

check "hook: decisions block injected on startup, resume, clear and compact" <<'SH'
export PATH="$ARMED_GH_BIN:$PATH"
H="python3 $REPO_ROOT/claude/hooks/director_rollover.py"
SOCK=/tmp/cc-socks/$$.sock
S1=11111111-1111-4111-8111-111111111111
F=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $$ --messaging-socket "$SOCK")
p() { printf '{"hook_event_name":"SessionStart","source":"%s","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$1" "$FX_REPO"; }
test -z "$(p startup | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
test -z "$(p resume | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H)"
$CORE note-decision --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --fence "$F" --repo-wide --text "serial shipping" >/dev/null
ctx() { python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'; }
for src in startup resume; do
    p $src | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H | ctx > "$FX/c.$src"
    head -n 1 "$FX/c.$src" | grep -q '^\[INFO\] herdr decisions:'
    grep -q 'repo: serial shipping \[' "$FX/c.$src"
done
p clear | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H | ctx > "$FX/c.clear"
head -n 1 "$FX/c.clear" | grep -q '^\[INFO\] herdr director rollover'
grep -q '^\[INFO\] herdr decisions:' "$FX/c.clear"
grep -q 'repo: serial shipping \[' "$FX/c.clear"
p compact | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET=$SOCK $H | ctx > "$FX/c.compact"
grep -q 'repo: serial shipping \[' "$FX/c.compact"
SH

check "hook: decisions after adopt-rollover omit carry already printed as carried lines" <<'SH'
export PATH="$ARMED_GH_BIN:$PATH"
cp "$HANDOVER_STUB" "$FX/bin/herdr"
sleep 60 & OLD=$!
S1=11111111-1111-4111-8111-111111111111
F1=$($CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --host h --pid $OLD --messaging-socket /tmp/cc-socks/$OLD.sock)
$CORE note-decision --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" --session $S1 --fence "$F1" --repo-wide --text "owner standing rule" >/dev/null
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
# The rollover verb writes the carry entries and the marker; the marker is then
# rewritten for the token this check holds.
PATH="$FX/bin:$PATH" HERDR_PANE_ID=w9:p1 CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$OLD.sock \
    $CORE rollover --repo-path "$FX_REPO" --repo-slug "$FX_SLUG" --session $S1 --fence "$F1" \
    --carry "carry note one" --ack-secs 1 --poll-secs 0.1 >/dev/null || true
python3 "$WRITE_MARKER" "$RD/rollover-pending.json" "$T" w9:p2 $S1 "$F1" 60
python3 - "$RD/rollover-pending.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m["carry"] = "carry note one"
json.dump(m, open(p, "w"))
PY
printf '{"hook_event_name":"SessionStart","source":"startup","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | HERDR_ENV=1 HERDR_PANE_ID=w9:p2 HERDR_ROLLOVER_TOKEN=$T CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/$$.sock \
    python3 "$REPO_ROOT/claude/hooks/director_rollover.py" > "$FX/h"
kill $OLD
python3 - "$FX/h" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]
assert c.startswith("[INFO] herdr director rollover: lease handed over"), c
assert c.count("carry note one") == 1, c
assert "carried: carry note one" in c, c
assert "[INFO] herdr decisions:" in c and "repo: owner standing rule [" in c, c
PY
SH

check "hook: decisions verb failure adds the one-line warning and keeps the lease block" <<'SH'
export PATH="$ARMED_GH_BIN:$PATH"
SOCK=/tmp/cc-socks/$$.sock
$CORE claim-owner --repo-path "$FX_REPO" --runtime claude --repo-slug "$FX_SLUG" \
    --session 11111111-1111-4111-8111-111111111111 --host h --pid $$ --messaging-socket "$SOCK" >/dev/null
RD=$(dirname "$(find "$FX" -path "$FX/coord" -prune -o -name owner.json -print | head -1)")
mkdir "$RD/decisions.jsonl"
printf '{"hook_event_name":"SessionStart","source":"clear","agent_type":"director","session_id":"22222222-2222-4222-8222-222222222222","cwd":"%s"}' "$FX_REPO" \
  | HERDR_ENV=1 CLAUDE_CODE_MESSAGING_SOCKET="$SOCK" python3 "$REPO_ROOT/claude/hooks/director_rollover.py" > "$FX/h" && rc=0 || rc=$?
test "$rc" = 0
python3 - "$FX/h" "$FX_REPO" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))["hookSpecificOutput"]["additionalContext"]
assert c.startswith("[INFO] herdr director rollover"), c
last = c.splitlines()[-1]
assert last.startswith("[WARNING] herdr decisions: not loaded; run python3 ~/.claude/hooks/herdr_orch_core.py decisions --repo-path "), last
PY
SH

check "decisions: director.md and the skill document the decisions log and compact instructions" <<'SH'
D="$REPO_ROOT/claude/agents/director.md"
S="$REPO_ROOT/claude/skills/herdr-orchestration/SKILL.md"
python3 - "$D" "$S" "$REPO_ROOT/claude/skills/herdr-orchestration/references/state-layout.md" <<'PY'
import sys
d, s, layout = (open(p).read() for p in sys.argv[1:4])
assert "\n# Compact instructions\n" in d, "heading"
sec = d.split("\n# Compact instructions\n", 1)[1].lower()
for w in ("lease", "fence", "open question", "in-flight", "note-decision"):
    assert w in sec, w
assert "note-decision" in d and "[INFO] herdr decisions" in d
body = s.split("### Decisions log", 1)[1].split("\n## ", 1)[0]
for w in ("note-decision", "retire-decision", "AskUserQuestion", "--repo-wide", "--all", "older omitted"):
    assert w in body, w
assert "decisions.jsonl" in layout
PY
SH

rm -f "$WRITE_MARKER" "$HANDOVER_STUB"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
