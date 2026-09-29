#!/bin/sh
# herdr_pending_notice.py: SessionStart notice of herdr tasks awaiting a director.
# Hermetic: temp HOME, fixture git repositories, no network, no herdr.
set -u
cd "$(dirname "$0")/../.." || exit 1
unset CLAUDE_CONFIG_DIR CLAUDE_PERSONAL_ONLY XDG_STATE_HOME WORKFLOW_PERSONAL_ACCOUNT
unset CLAUDE_WORK_CONFIG_DIR CLAUDE_WORK_TREE CODEX_HOME
unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID HERDR_ACCOUNT_ID HERDR_PERSONAL
PASS=0
FAIL=0
HOOK="$PWD/claude/hooks/herdr_pending_notice.py"
# Resolve the interpreter once, before HOME moves, so no run writes under HOME.
if command -v uv >/dev/null 2>&1; then
    PY=$(uv run --python '>=3.11' --no-project --offline --no-cache python -c 'import sys; print(sys.executable)')
else
    PY=python3
fi
A40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B40=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C40=cccccccccccccccccccccccccccccccccccccccc

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pending-notice.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export HERDR_COORDINATION_ROOT="$TMP/coord"
mkdir -p "$HOME" "$TMP/plain"

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n%s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

run_hook() {
    printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$1" | $PY "$HOOK"
}

context() {
    printf '%s' "$1" | $PY -c 'import json,sys; h=json.load(sys.stdin)["hookSpecificOutput"]; assert h["hookEventName"]=="SessionStart"; print(h["additionalContext"])'
}

snapshot() {
    $PY - "$HOME" <<'PYEOF'
import os, sys
rows = []
for base, dirs, files in os.walk(sys.argv[1]):
    for name in dirs + files:
        st = os.lstat(os.path.join(base, name))
        rows.append("%s %d %d" % (os.path.join(base, name), st.st_size, st.st_mtime_ns))
print("\n".join(sorted(rows)))
PYEOF
}

# The account payload dir the core selects for a repository.
repo_state() {
    $PY - "$1" <<'PYEOF'
import sys, types
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as c
cwd = sys.argv[1]
slug = c._context_slug(c.repository_context(cwd))
c.select_payload(types.SimpleNamespace(repo_path=cwd, runtime="claude", personal=False, repo_slug=slug))
print(c.repo_dir(slug))
PYEOF
}

REPO="$HOME/Git/personal/alpha"
mkdir -p "$REPO"
git -C "$REPO" init -q -b trunk
git -C "$REPO" remote add origin https://example.invalid/org/alpha.git
git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m fixture
RD=$(repo_state "$REPO")
WANT='[INFO] herdr: 2 tasks await the director (oldest t-old since 2026-09-07); run director in a herdr pane'

# 1. No herdr state for the repository: silent.
out=$(run_hook "$REPO"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "no state prints nothing"; else fail "no state prints nothing" "rc=$rc $out"; fi

# 2. Two reviewed, unparked tasks and no owner record: one line naming the older.
mkdir -p "$RD/tasks"
printf '{"task_id":"t-new","status":"reviewed","review_head_sha":"%s"}\n' "$A40" > "$RD/tasks/t-new.json"
printf '{"ts":"2026-09-20T10:00:00Z"}\n' > "$RD/tasks/t-new.review.json"
printf '{"task_id":"t-old","status":"reviewed","review_head_sha":"%s"}\n' "$B40" > "$RD/tasks/t-old.json"
printf '{"ts":"2026-09-07T10:00:00Z"}\n' > "$RD/tasks/t-old.review.json"
before=$(snapshot)
out=$(run_hook "$REPO"); rc=$?
after=$(snapshot)
got=$(context "$out")
if [ "$rc" = 0 ] && [ "$got" = "$WANT" ]; then pass "absent owner prints the two-task line"; else fail "absent owner prints the two-task line" "rc=$rc $out"; fi

# 3. That run wrote nothing under HOME.
if [ "$before" = "$after" ]; then pass "hook run writes nothing"; else fail "hook run writes nothing" "files under HOME changed"; fi

# 4. A live owner lease: silent.
printf '{"heartbeat_ts": %s}\n' "$(( $(date +%s) - 10 ))" > "$RD/owner.json"
out=$(run_hook "$REPO"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "live lease prints nothing"; else fail "live lease prints nothing" "rc=$rc $out"; fi

# 5. A stale owner lease: the line again.
printf '{"heartbeat_ts": %s}\n' "$(( $(date +%s) - 1000 ))" > "$RD/owner.json"
out=$(run_hook "$REPO"); rc=$?
got=$(context "$out")
if [ "$rc" = 0 ] && [ "$got" = "$WANT" ]; then pass "stale lease prints the line"; else fail "stale lease prints the line" "rc=$rc $out"; fi

# 6. Both tasks parked at their reviewed head: nothing pending, silent.
printf '{"task_id":"t-new","status":"reviewed","review_head_sha":"%s","ship_parked_head":"%s"}\n' "$A40" "$A40" > "$RD/tasks/t-new.json"
printf '{"task_id":"t-old","status":"reviewed","review_head_sha":"%s","ship_parked_head":"%s"}\n' "$B40" "$B40" > "$RD/tasks/t-old.json"
out=$(run_hook "$REPO"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "nothing pending prints nothing"; else fail "nothing pending prints nothing" "rc=$rc $out"; fi

# 7. One task with no sidecar and no timestamps: singular, no date.
printf '{"task_id":"t-solo","status":"reviewed","review_head_sha":"%s"}\n' "$C40" > "$RD/tasks/t-solo.json"
out=$(run_hook "$REPO"); rc=$?
got=$(context "$out")
want1='[INFO] herdr: 1 task awaits the director (oldest t-solo); run director in a herdr pane'
if [ "$rc" = 0 ] && [ "$got" = "$want1" ]; then pass "one undated task prints the singular line"; else fail "one undated task prints the singular line" "rc=$rc $out"; fi

# 8. cwd outside any repository: silent.
out=$(run_hook "$TMP/plain"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "non-repository cwd prints nothing"; else fail "non-repository cwd prints nothing" "rc=$rc $out"; fi

# 9. Malformed stdin from a non-repository process cwd: silent.
out=$(cd "$TMP/plain" && printf 'not json' | $PY "$HOOK"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "malformed payload prints nothing"; else fail "malformed payload prints nothing" "rc=$rc $out"; fi

# 10. Hook copied beside no core module: silent.
mkdir -p "$TMP/lonely"
cp "$HOOK" "$TMP/lonely/herdr_pending_notice.py"
out=$(printf '{"cwd":"%s"}' "$REPO" | $PY "$TMP/lonely/herdr_pending_notice.py"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "missing core prints nothing"; else fail "missing core prints nothing" "rc=$rc $out"; fi

# 11. The pending task list survives a live lease flip back: still silent when live.
printf '{"heartbeat_ts": %s}\n' "$(date +%s)" > "$RD/owner.json"
out=$(run_hook "$REPO"); rc=$?
if [ "$rc" = 0 ] && [ -z "$out" ]; then pass "fresh heartbeat silences a pending task"; else fail "fresh heartbeat silences a pending task" "rc=$rc $out"; fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
