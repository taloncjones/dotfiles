#!/bin/sh
# handoff_notice.py: SessionStart notice of saved handoffs for the cwd repo.
# Hermetic: temp HOME, temp state dir, fixture git repo, no network.
set -u
cd "$(dirname "$0")/../.." || exit 1
PASS=0
FAIL=0
HOOK=claude/hooks/handoff_notice.py
HELPER=claude/skills/handoff/scripts/handoff.py
if command -v uv >/dev/null 2>&1; then
    PY="uv run --python >=3.11 --no-project --offline --no-cache python"
else
    PY=python3
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/handoff-notice.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export DOTFILES_HANDOFF_STATE_DIR="$TMP/state"
unset CLAUDE_CONFIG_DIR CLAUDE_PERSONAL_ONLY XDG_STATE_HOME
REPO="$HOME/Git/personal/fixture"
mkdir -p "$REPO"
git -C "$REPO" init -q -b trunk
git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m fixture

run_hook() {
    printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$1" | $PY "$HOOK"
}

silent() {
    label=$1; out=$2; rc=$3
    if [ "$rc" = 0 ] && [ -z "$out" ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s): %s\n' "$label" "$rc" "$out" >&2; FAIL=$((FAIL + 1))
    fi
}

contains() {
    label=$1; out=$2; rc=$3; shift 3
    ok=1
    [ "$rc" = 0 ] || ok=0
    for needle in "$@"; do
        printf '%s' "$out" | grep -qF -- "$needle" || ok=0
    done
    if [ "$ok" = 1 ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s)\n%s\n' "$label" "$rc" "$out" >&2; FAIL=$((FAIL + 1))
    fi
}

lacks() {
    label=$1; out=$2; rc=$3; needle=$4
    if [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s)\n%s\n' "$label" "$rc" "$out" >&2; FAIL=$((FAIL + 1))
    fi
}

# SessionStart output must be a JSON envelope; only additionalContext reaches
# the model's context. Bare stdout is never folded in.
envelope_ok() {
    label=$1; out=$2
    if printf '%s' "$out" | $PY -c 'import json,sys; h=json.load(sys.stdin)["hookSpecificOutput"]; sys.exit(0 if h["hookEventName"]=="SessionStart" and isinstance(h["additionalContext"],str) else 1)' 2>/dev/null; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n%s\n' "$label" "$out" >&2; FAIL=$((FAIL + 1))
    fi
}

context() {
    printf '%s' "$1" | $PY -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}

# 1. No records: silent, exit 0.
out=$(run_hook "$REPO"); rc=$?
silent "no records prints nothing" "$out" "$rc"

# 2. Two records: one line each plus the kickoff hint.
printf 'working: fix the flaky login test.\nNext: rerun it.\n' > "$TMP/brief-a.txt"
printf 'assigned: write the release notes.\n' > "$TMP/brief-b.txt"
$PY "$HELPER" save --repo "$REPO" --runtime claude --task fix-login \
    --brief-file "$TMP/brief-a.txt" --role lead >/dev/null
$PY "$HELPER" save --repo "$REPO" --runtime claude --task release-notes \
    --brief-file "$TMP/brief-b.txt" --role worker --parent fix-login >/dev/null
out=$(run_hook "$REPO"); rc=$?
envelope_ok "two records emit a SessionStart envelope" "$out"
ctx=$(context "$out")
contains "two records list task, role, summary, hint" "$ctx" "$rc" \
    "fix-login [lead]" "working: fix the flaky login test." \
    "release-notes [worker of fix-login]" "assigned: write the release notes." \
    "Run /kickoff <task> to resume one."

# 3. cwd outside any repository: silent, exit 0.
mkdir -p "$TMP/plain"
out=$(run_hook "$TMP/plain"); rc=$?
silent "non-repository cwd prints nothing" "$out" "$rc"

# 4. Hook copied beside no skills tree: missing helper exits 0 silently.
mkdir -p "$TMP/fixture/hooks"
cp "$HOOK" "$TMP/fixture/hooks/handoff_notice.py"
out=$(printf '{"cwd":"%s"}' "$REPO" | $PY "$TMP/fixture/hooks/handoff_notice.py"); rc=$?
silent "missing helper exits 0 silently" "$out" "$rc"

# 5. Malformed stdin: exit 0.
out=$(printf 'not json' | $PY "$HOOK"); rc=$?
[ "$rc" = 0 ] && { printf 'PASS  malformed payload exits 0\n'; PASS=$((PASS + 1)); } \
    || { printf 'FAIL  malformed payload exits 0 (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1)); }

# 6. Overflow: 12 ready records show the 10 newest and an omitted count.
i=1
while [ "$i" -le 10 ]; do
    printf 'assigned: filler %s.\n' "$i" > "$TMP/brief-f.txt"
    $PY "$HELPER" save --repo "$REPO" --runtime claude --task "filler-$i" \
        --brief-file "$TMP/brief-f.txt" >/dev/null
    i=$((i + 1))
done
out=$(run_hook "$REPO"); rc=$?
ctx=$(context "$out")
shown=$(printf '%s\n' "$ctx" | grep -c '^  [a-z0-9-]* \[')
if [ "$rc" = 0 ] && [ "$shown" = 10 ] \
    && printf '%s' "$ctx" | grep -qF 'and 2 more' \
    && printf '%s' "$ctx" | grep -qF 'filler-10 [no role]' \
    && ! printf '%s' "$ctx" | grep -qF 'fix-login ['; then
    printf 'PASS  overflow shows ten newest and omitted count\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  overflow shows ten newest and omitted count (rc=%s shown=%s)\n%s\n' "$rc" "$shown" "$out" >&2
    FAIL=$((FAIL + 1))
fi

# 7-10 use a second fixture repository so earlier records do not interfere.
REPO2="$HOME/Git/personal/fixture-two"
mkdir -p "$REPO2"
git -C "$REPO2" init -q -b trunk
git -C "$REPO2" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m fixture

save2() {
    printf '%s\n' "$2" > "$TMP/brief-2.txt"
    $PY "$HELPER" save --repo "$REPO2" --runtime claude --task "$1" \
        --brief-file "$TMP/brief-2.txt"
}

record_path() {
    $PY -c 'import json,sys; print(json.load(sys.stdin)["record_path"])'
}

# Shift a record's created_at by $2 hours (naive when $3 is "naive") and
# re-pin the pointer digest.
backdate() {
    $PY -c '
import hashlib, json, os, sys
from datetime import datetime, timedelta, timezone
path, hours = sys.argv[1], float(sys.argv[2])
record = json.load(open(path))
stamp = datetime.now(timezone.utc) + timedelta(hours=hours)
if sys.argv[3:] == ["naive"]:
    stamp = stamp.replace(tzinfo=None)
record["created_at"] = stamp.isoformat()
data = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode()
open(path, "wb").write(data)
pointer_path = os.path.join(os.path.dirname(path), "current.json")
pointer = json.load(open(pointer_path))
pointer["record_sha256"] = hashlib.sha256(data).hexdigest()
open(pointer_path, "w").write(json.dumps(pointer, sort_keys=True, separators=(",", ":")) + "\n")
' "$@"
}

# 7. A done: record older than 72 hours is hidden behind one count line;
#    a fresh done: record and an old working: record stay listed.
backdate "$(save2 fresh-done 'done: fresh hand-off.' | record_path)" -1
backdate "$(save2 old-done 'done: old hand-off.' | record_path)" -96
backdate "$(save2 old-work 'working: old but active.' | record_path)" -96
out=$(run_hook "$REPO2"); rc=$?
ctx=$(context "$out")
contains "fresh done and old working stay listed with a hidden count" "$ctx" "$rc" \
    "fresh-done [no role]" "old-work [no role]" \
    "1 finished more than 3 days ago hidden; retire them with the handoff helper"
lacks "done record older than 72 hours is not listed" "$ctx" "$rc" "old-done ["

# 8. A future-dated done: record (clock skew) is not stale.
backdate "$(save2 future-done 'done: clock skew.' | record_path)" 24
out=$(run_hook "$REPO2"); rc=$?
ctx=$(context "$out")
contains "future-dated done record stays listed" "$ctx" "$rc" "future-done [no role]"
backdate "$(save2 naive-done 'done: naive stamp.' | record_path)" -96 naive
out=$(run_hook "$REPO2"); rc=$?
ctx=$(context "$out")
contains "naive-timestamp done record stays listed" "$ctx" "$rc" "naive-done [no role]"

# 9. A retired task never reaches the notice.
$PY "$HELPER" retire --repo "$REPO2" --runtime claude --task fresh-done >/dev/null
out=$(run_hook "$REPO2"); rc=$?
ctx=$(context "$out")
lacks "retired task is not listed" "$ctx" "$rc" "fresh-done ["
contains "live tasks remain after a retire" "$ctx" "$rc" "old-work [no role]"

# 10. The cap and overflow count cover visible tasks only; the hidden line
#     follows the overflow line. REPO2 has 3 visible (old-work,
#     future-done, naive-done) and 1 stale record; 8 more make 11 visible.
i=1
while [ "$i" -le 8 ]; do
    save2 "visible-$i" "assigned: visible $i." >/dev/null
    i=$((i + 1))
done
out=$(run_hook "$REPO2"); rc=$?
ctx=$(context "$out")
shown=$(printf '%s\n' "$ctx" | grep -c '^  [a-z0-9-]* \[')
hidden_line=$(printf '%s\n' "$ctx" | tail -2 | head -1)
if [ "$rc" = 0 ] && [ "$shown" = 10 ] \
    && printf '%s' "$ctx" | grep -qF '  and 1 more' \
    && printf '%s' "$hidden_line" | grep -qF '1 finished more than 3 days ago hidden'; then
    printf 'PASS  overflow counts visible tasks and hidden line follows\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  overflow counts visible tasks and hidden line follows (rc=%s shown=%s)\n%s\n' "$rc" "$shown" "$ctx" >&2
    FAIL=$((FAIL + 1))
fi

# 11. A repository whose only task is retired prints nothing.
REPO3="$HOME/Git/personal/fixture-three"
mkdir -p "$REPO3"
git -C "$REPO3" init -q -b trunk
git -C "$REPO3" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m fixture
printf 'done: only task.\n' > "$TMP/brief-3.txt"
$PY "$HELPER" save --repo "$REPO3" --runtime claude --task only \
    --brief-file "$TMP/brief-3.txt" >/dev/null
$PY "$HELPER" retire --repo "$REPO3" --runtime claude --task only >/dev/null
out=$(run_hook "$REPO3"); rc=$?
silent "only retired tasks prints nothing" "$out" "$rc"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
