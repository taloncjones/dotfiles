#!/bin/sh
# herdr-orch-archive.test.sh - archive-task and status --archived. Temp state
# roots and canned herdr polls only: no network, no herdr, no ~/.claude.
set -e
unset WORKFLOW_PERSONAL_ACCOUNT HERDR_PERSONAL CLAUDE_PERSONAL_ONLY
unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR CODEX_HOME XDG_STATE_HOME
unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID HERDR_ACCOUNT_ID
# Physical temp root, derived as herdr-orch.test.sh does, so the core's
# no-follow state traversal sees real directories.
TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || TMPDIR=""
[ -n "$TMPDIR" ] || TMPDIR=$(mktemp -d -u 2>/dev/null | sed 's:/[^/]*$::')
[ -n "$TMPDIR" ] || TMPDIR=/tmp
TMPDIR=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMPDIR")
export TMPDIR
PASS=0
FAIL=0

# manifest DIR: "<sha256> <relative path>" per file, sorted by path; a
# symlink prints "link:<target>". owner.json and drop-ack.json are skipped:
# fence and check-in calls rewrite them.
HELPERS=$(mktemp -d)
cat > "$HELPERS/manifest.py" <<'PY'
import hashlib, os, sys
root = sys.argv[1]
rows = []
for dirpath, dirnames, filenames in os.walk(root):
    links = [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]
    for name in filenames + links:
        if name in ("owner.json", "drop-ack.json"):
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root)
        if os.path.islink(path):
            rows.append(f"link:{os.readlink(path)} {rel}")
        else:
            with open(path, "rb") as fh:
                rows.append(f"{hashlib.sha256(fh.read()).hexdigest()} {rel}")
rows.sort(key=lambda row: row.split(" ", 1)[1])
print("\n".join(rows))
PY
MANIFEST="python3 $HELPERS/manifest.py"; export MANIFEST

# Entry paths of task T1 and workspace w9A in a manifest line.
T1_ENTRIES=' (artifacts/T1/|workspaces/w9A\.|tasks/T1\.)'; export T1_ENTRIES

check() {
    label="$1"
    HERDR_COORDINATION_ROOT=$(mktemp -d); export HERDR_COORDINATION_ROOT
    if sh -e -; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2; FAIL=$((FAIL + 1))
    fi
}

check "archives a merged task byte for byte" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks/findings" "$RD/workspaces" "$RD/artifacts/T1/run-1"
printf '{"task_id":"T1","status":"merged","worktree":"%s/gone","workers":[{"workspace_id":"w9A","pane_id":"w9A:p1","worktree":"%s/gone"}]}' "$root" "$root" > "$RD/tasks/T1.json"
printf 'done\n' > "$RD/tasks/T1.done.json"
printf 'LESSON: [T1 plan] keep it\n' > "$RD/tasks/T1.lessons.md"
printf 'ship\n' > "$RD/tasks/T1.ship.md"
printf 'spec\n' > "$RD/artifacts/T1/run-1/spec-a.md"
printf '{"repo_slug":"slug-x","role":"impl","task_id":"T1"}' > "$RD/workspaces/w9A.json"
printf '{"event":"stopped"}\n' > "$RD/workspaces/w9A.events.jsonl"
printf '{"v":2}' > "$RD/workspaces/w9A.wake.json"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
want=$($MANIFEST "$RD" | grep -E "$T1_ENTRIES")
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
M=$(date -u +%Y-%m)
[ "$out" = "archived T1 archive/$M files=8" ]
[ "$($MANIFEST "$RD/archive/$M")" = "$want" ]
[ ! -e "$RD/tasks/T1.json" ]
[ ! -e "$RD/tasks/T1.lessons.md" ]
[ ! -e "$RD/artifacts/T1" ]
[ ! -e "$RD/workspaces/w9A.json" ]
[ ! -e "$RD/workspaces/w9A.events.jsonl" ]
SH

check "other tasks, unclaimed workspaces and the T10 prefix neighbour stay put" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks/findings" "$RD/workspaces" "$RD/artifacts/T1" "$RD/artifacts/T10"
printf '{"task_id":"T1","status":"merged","workers":[{"workspace_id":"w9A"},{"workspace_id":"w9B"}]}' > "$RD/tasks/T1.json"
printf 'done\n' > "$RD/tasks/T1.done.json"
printf 'a\n' > "$RD/artifacts/T1/a.md"
printf '{"repo_slug":"slug-x","role":"impl","task_id":"T1"}' > "$RD/workspaces/w9A.json"
printf '{"task_id":"T10","status":"in-progress","workers":[]}' > "$RD/tasks/T10.json"
printf 'live\n' > "$RD/tasks/T10.done.json"
printf 'b\n' > "$RD/artifacts/T10/b.md"
printf '{"repo_slug":"slug-x","role":"impl","task_id":"T10"}' > "$RD/workspaces/w9B.json"
printf '{"event":"stopped"}\n' > "$RD/workspaces/w9B.events.jsonl"
printf '{"event":"stopped"}\n' > "$RD/workspaces/w9C.events.jsonl"
printf '{"ts":1}\n' > "$RD/tasks/orch-edits.jsonl"
printf 'f\n' > "$RD/tasks/findings/review.md"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
keep=$($MANIFEST "$RD" | grep -Ev ' (artifacts/T1/|workspaces/w9A\.|tasks/T1\.)')
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
M=$(date -u +%Y-%m)
[ "$out" = "archived T1 archive/$M files=4" ]
[ "$($MANIFEST "$RD" | grep -v ' archive/')" = "$keep" ]
[ -f "$RD/tasks/T10.json" ]
[ -f "$RD/workspaces/w9B.json" ]
[ -f "$RD/workspaces/w9C.events.jsonl" ]
SH

check "abandoned and failed tasks archive too" <<'SH'
for st in abandoned failed; do
    root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
    HERDR_COORDINATION_ROOT=$(mktemp -d); export HERDR_COORDINATION_ROOT
    CLI="python3 claude/hooks/herdr_legacy_fixture.py"
    F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
    RD="$root/herdr-orch/slug-x"
    mkdir -p "$RD/tasks" "$RD/workspaces"
    printf '{"task_id":"T1","status":"%s","workers":[]}' "$st" > "$RD/tasks/T1.json"
    printf '{"result":{"agents":[]}}' > "$root/a.json"
    printf '{"result":{"workspaces":[]}}' > "$root/w.json"
    out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
        --agents-json "$root/a.json" --workspaces-json "$root/w.json")
    [ "$out" = "archived T1 archive/$(date -u +%Y-%m) files=1" ]
done
SH

check "checkin, present-task and status stop listing an archived task" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf '{"task_id":"T1","status":"merged","workers":[{"workspace_id":"w9A"}]}' > "$RD/tasks/T1.json"
printf '{"outcome":"completed"}' > "$RD/tasks/T1.done.json"
printf '{"repo_slug":"slug-x","role":"impl","task_id":"T1"}' > "$RD/workspaces/w9A.json"
printf '{"ts":"2026-10-02T00:00:00Z","event":"stopped"}\n' > "$RD/workspaces/w9A.events.jsonl"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
$CLI checkin --repo-slug slug-x --session S --fence "$F" --all \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json" | grep -q '^T1 '
$CLI present-task --repo-slug slug-x --all | grep -q '"task_id": "T1"'
$CLI status --repo-slug slug-x | python3 -c 'import json,sys; assert "T1" in json.load(sys.stdin)'
$CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json" >/dev/null
if $CLI checkin --repo-slug slug-x --session S --fence "$F" --all \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json" | grep -q '^T1 '; then exit 1; fi
if $CLI present-task --repo-slug slug-x --all | grep -q '"task_id": "T1"'; then exit 1; fi
$CLI status --repo-slug slug-x | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "T1" not in d and "T1" not in d["_orphans"], d'
SH

check "status --archived lists the archived task and writes nothing" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf '{"task_id":"T1","status":"merged","workers":[]}' > "$RD/tasks/T1.json"
printf '{"task_id":"T2","status":"in-progress","workers":[]}' > "$RD/tasks/T2.json"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
[ "$($CLI status --repo-slug slug-x --archived)" = "{}" ]
$CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json" >/dev/null
mkdir -p "$RD/archive/2020-01/tasks"
printf '{not json' > "$RD/archive/2020-01/tasks/T7.json"
printf 'x' > "$RD/archive/2020-01/tasks/T7.done.json"
before=$($MANIFEST "$RD")
M=$(date -u +%Y-%m); export M
$CLI status --repo-slug slug-x --archived | python3 -c '
import json, os, sys
d = json.load(sys.stdin)
assert d == {"T1": {"status": "merged", "archive": os.environ["M"]}}, d'
[ "$($MANIFEST "$RD")" = "$before" ]
$CLI status --repo-slug slug-x | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "T2" in d and "T1" not in d, d'
SH

check "resume completes from every interruption boundary" <<'SH'
ORDER="tasks/T1.json artifacts/T1 tasks/T1.done.json tasks/T1.lessons.md tasks/T1.ship.md workspaces/w9A.events.jsonl workspaces/w9A.wake.json workspaces/w9A.json"
for k in 0 1 2 3 4 5 6 7 8; do
    root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
    HERDR_COORDINATION_ROOT=$(mktemp -d); export HERDR_COORDINATION_ROOT
    CLI="python3 claude/hooks/herdr_legacy_fixture.py"
    F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
    RD="$root/herdr-orch/slug-x"
    mkdir -p "$RD/tasks" "$RD/workspaces" "$RD/artifacts/T1/run-1"
    printf '{"task_id":"T1","status":"merged","workers":[{"workspace_id":"w9A"}]}' > "$RD/tasks/T1.json"
    printf 'done\n' > "$RD/tasks/T1.done.json"
    printf 'LESSON: [T1 plan] keep it\n' > "$RD/tasks/T1.lessons.md"
    printf 'ship\n' > "$RD/tasks/T1.ship.md"
    printf 'spec\n' > "$RD/artifacts/T1/run-1/spec-a.md"
    printf '{"repo_slug":"slug-x","role":"impl","task_id":"T1"}' > "$RD/workspaces/w9A.json"
    printf '{"event":"stopped"}\n' > "$RD/workspaces/w9A.events.jsonl"
    printf '{"v":2}' > "$RD/workspaces/w9A.wake.json"
    printf '{"result":{"agents":[]}}' > "$root/a.json"
    printf '{"result":{"workspaces":[]}}' > "$root/w.json"
    want=$($MANIFEST "$RD" | grep -E "$T1_ENTRIES")
    M=$(date -u +%Y-%m)
    [ "$k" = 0 ] || M=2020-01
    i=0
    for rel in $ORDER; do
        [ "$i" -lt "$k" ] || break
        mkdir -p "$RD/archive/$M/$(dirname "$rel")"
        mv "$RD/$rel" "$RD/archive/$M/$rel"
        i=$((i + 1))
    done
    out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
        --agents-json "$root/a.json" --workspaces-json "$root/w.json")
    [ "$out" = "archived T1 archive/$M files=$((8 - k))" ]
    [ "$($MANIFEST "$RD/archive/$M")" = "$want" ]
    [ -z "$($MANIFEST "$RD" | grep -v ' archive/' | grep -E "$T1_ENTRIES" || true)" ]
done
SH

check "an archived index never claims a live sidecar" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces" "$RD/archive/2020-01/workspaces"
printf '{"task_id":"T1","status":"merged","workers":[]}' > "$RD/tasks/T1.json"
printf '{"repo_slug":"slug-x","role":"impl","task_id":"T1"}' > "$RD/archive/2020-01/workspaces/w9A.json"
printf '{"event":"stopped"}\n' > "$RD/workspaces/w9A.events.jsonl"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
keep=$($MANIFEST "$RD" | grep -F ' workspaces/w9A.events.jsonl')
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
[ "$out" = "archived T1 archive/$(date -u +%Y-%m) files=1" ]
[ "$($MANIFEST "$RD" | grep -F ' workspaces/w9A.events.jsonl')" = "$keep" ]
SH

check "the backfill recipe finishes an interrupted archive and archives the rest" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces" "$RD/archive/2020-01/tasks"
printf '{"task_id":"T1","status":"merged","workers":[{"workspace_id":"w9A"}]}' > "$RD/archive/2020-01/tasks/T1.json"
printf 'done\n' > "$RD/tasks/T1.done.json"
printf '{"repo_slug":"slug-x","role":"impl","task_id":"T1"}' > "$RD/workspaces/w9A.json"
printf '{"event":"stopped"}\n' > "$RD/workspaces/w9A.events.jsonl"
printf '{"task_id":"T2","status":"abandoned","workers":[]}' > "$RD/tasks/T2.json"
printf '{"task_id":"T3","status":"in-progress","workers":[]}' > "$RD/tasks/T3.json"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
{ $CLI status --repo-slug slug-x \
    | python3 -c 'import json,sys; [print(k) for k, v in json.load(sys.stdin).items() if not k.startswith("_") and v.get("status") in ("merged", "abandoned", "failed")]'
  $CLI status --repo-slug slug-x --archived \
    | python3 -c 'import json,sys; [print(k) for k in json.load(sys.stdin)]'
} | sort -u | while read -r t; do
    $CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id "$t" \
        --agents-json "$root/a.json" --workspaces-json "$root/w.json" || true
done > "$root/backfill.out"
grep -qx 'archived T1 archive/2020-01 files=3' "$root/backfill.out"
grep -qx "archived T2 archive/$(date -u +%Y-%m) files=1" "$root/backfill.out"
if grep -q ' T3 \|T3 ' "$root/backfill.out"; then exit 1; fi
[ -f "$RD/tasks/T3.json" ]
[ ! -e "$RD/tasks/T1.done.json" ]
[ ! -e "$RD/workspaces/w9A.json" ]
SH

check "refuses every non-terminal status and moves nothing" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf 'done\n' > "$RD/tasks/T1.done.json"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
for st in kickoff in-progress blocked completed review-dispatched changes-requested reviewed paused NONE; do
    if [ "$st" = NONE ]; then
        printf '{"task_id":"T1","workers":[]}' > "$RD/tasks/T1.json"
    else
        printf '{"task_id":"T1","status":"%s","workers":[]}' "$st" > "$RD/tasks/T1.json"
    fi
    before=$($MANIFEST "$RD")
    set +e
    out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
        --agents-json "$root/a.json" --workspaces-json "$root/w.json")
    rc=$?
    set -e
    [ "$rc" = 1 ]
    [ "$out" = "refused T1 reason=not-terminal" ]
    [ "$($MANIFEST "$RD")" = "$before" ]
done
SH

check "refuses not-found and unreadable records" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T9 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T9 reason=not-found" ]
for body in '{not json' '[]' '{"task_id":"T2","status":"merged"}'; do
    printf '%s' "$body" > "$RD/tasks/T1.json"
    before=$($MANIFEST "$RD")
    set +e
    out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
        --agents-json "$root/a.json" --workspaces-json "$root/w.json")
    rc=$?
    set -e
    [ "$rc" = 1 ]
    [ "$out" = "refused T1 reason=unreadable" ]
    [ "$($MANIFEST "$RD")" = "$before" ]
done
SH

check "malformed field types refuse cleanly" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[{"workspace_id":"w9A"}]}}' > "$root/w.json"
printf '{"task_id":"T1","status":["merged"],"workers":[]}' > "$RD/tasks/T1.json"
before=$($MANIFEST "$RD")
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=not-terminal" ]
[ "$($MANIFEST "$RD")" = "$before" ]
for rec in \
    '{"task_id":"T1","status":"merged","workers":"w9A"}' \
    '{"task_id":"T1","status":"merged","workers":["junk"]}' \
    '{"task_id":"T1","status":"merged","worktree":7,"workers":[]}' \
    '{"task_id":"T1","status":"merged","workers":[{"worktree":7}]}' \
    '{"task_id":"T1","status":"merged","workers":[{"workspace_id":["w9A"]}]}'; do
    printf '%s' "$rec" > "$RD/tasks/T1.json"
    before=$($MANIFEST "$RD")
    set +e
    out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
        --agents-json "$root/a.json" --workspaces-json "$root/w.json")
    rc=$?
    set -e
    [ "$rc" = 1 ]
    [ "$out" = "refused T1 reason=unreadable" ]
    [ "$($MANIFEST "$RD")" = "$before" ]
done
SH

check "refuses teardown-blocked" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf '{"task_id":"T1","status":"merged","teardown_blocked":"head-moved","workers":[]}' > "$RD/tasks/T1.json"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
before=$($MANIFEST "$RD")
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=teardown-blocked" ]
[ "$($MANIFEST "$RD")" = "$before" ]
SH

check "refuses worktree-present for task, worker and dangling-link paths" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces" "$root/wt-task" "$root/wt-worker"
ln -s "$root/nowhere" "$root/wt-link"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
for rec in \
    '{"task_id":"T1","status":"merged","worktree":"ROOT/wt-task","workers":[]}' \
    '{"task_id":"T1","status":"merged","worktree":"ROOT/gone","workers":[{"worktree":"ROOT/wt-worker"}]}' \
    '{"task_id":"T1","status":"merged","worktree":"ROOT/wt-link","workers":[]}'; do
    printf '%s' "$rec" | sed "s#ROOT#$root#g" > "$RD/tasks/T1.json"
    before=$($MANIFEST "$RD")
    set +e
    out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
        --agents-json "$root/a.json" --workspaces-json "$root/w.json")
    rc=$?
    set -e
    [ "$rc" = 1 ]
    [ "$out" = "refused T1 reason=worktree-present" ]
    [ "$($MANIFEST "$RD")" = "$before" ]
done
SH

check "refuses poll-unavailable on a malformed or half poll" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf '{"task_id":"T1","status":"merged","workers":[]}' > "$RD/tasks/T1.json"
printf 'not json' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
before=$($MANIFEST "$RD")
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=poll-unavailable" ]
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=poll-unavailable" ]
[ "$($MANIFEST "$RD")" = "$before" ]
SH

check "refuses workspace-listed for an index, an agent row or a workers-only id" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf '{"task_id":"T1","status":"merged","workers":[{"workspace_id":"w9C"}]}' > "$RD/tasks/T1.json"
printf '{"repo_slug":"slug-x","role":"impl","task_id":"T1"}' > "$RD/workspaces/w9A.json"
printf '{"result":{"agents":[]}}' > "$root/a.json"
before=$($MANIFEST "$RD")
for poll in \
    'w:{"result":{"workspaces":[{"workspace_id":"w9A"}]}}' \
    'a:{"result":{"agents":[{"workspace_id":"w9A","agent_status":"idle","pane_id":"w9A:p1"}]}}' \
    'w:{"result":{"workspaces":[{"workspace_id":"w9C"}]}}'; do
    printf '{"result":{"agents":[]}}' > "$root/a.json"
    printf '{"result":{"workspaces":[]}}' > "$root/w.json"
    printf '%s' "${poll#?:}" > "$root/${poll%%:*}.json"
    set +e
    out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
        --agents-json "$root/a.json" --workspaces-json "$root/w.json")
    rc=$?
    set -e
    [ "$rc" = 1 ]
    [ "$out" = "refused T1 reason=workspace-listed" ]
    [ "$($MANIFEST "$RD")" = "$before" ]
done
SH

check "refuses already-archived for two generations or two months" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces" "$RD/archive/2020-01/tasks" "$RD/archive/2020-02/tasks"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
printf '{"task_id":"T1","status":"merged","workers":[]}' > "$RD/tasks/T1.json"
printf '{"task_id":"T1","status":"merged","workers":[]}' > "$RD/archive/2020-01/tasks/T1.json"
before=$($MANIFEST "$RD")
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=already-archived" ]
[ "$($MANIFEST "$RD")" = "$before" ]
mv "$RD/tasks/T1.json" "$RD/archive/2020-02/tasks/T1.json"
before=$($MANIFEST "$RD")
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=already-archived" ]
[ "$($MANIFEST "$RD")" = "$before" ]
SH

check "refuses destination-exists when a moved entry was recreated" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces" "$RD/archive/2020-01/tasks"
printf '{"task_id":"T1","status":"merged","workers":[]}' > "$RD/archive/2020-01/tasks/T1.json"
printf 'archived copy\n' > "$RD/archive/2020-01/tasks/T1.done.json"
printf 'recreated live copy\n' > "$RD/tasks/T1.done.json"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
before=$($MANIFEST "$RD")
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=destination-exists" ]
[ "$($MANIFEST "$RD")" = "$before" ]
SH

check "refuses unexpected-type for a file artifacts entry or a symlink sidecar" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces" "$RD/artifacts"
printf '{"task_id":"T1","status":"merged","workers":[]}' > "$RD/tasks/T1.json"
printf 'not a directory\n' > "$RD/artifacts/T1"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
before=$($MANIFEST "$RD")
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=unexpected-type" ]
[ "$($MANIFEST "$RD")" = "$before" ]
rm "$RD/artifacts/T1"
printf 'elsewhere\n' > "$root/outside.md"
ln -s "$root/outside.md" "$RD/tasks/T1.brief.md"
before=$($MANIFEST "$RD")
set +e
out=$($CLI archive-task --repo-slug slug-x --session S --fence "$F" --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json")
rc=$?
set -e
[ "$rc" = 1 ]
[ "$out" = "refused T1 reason=unexpected-type" ]
[ "$($MANIFEST "$RD")" = "$before" ]
SH

check "stale fence moves nothing" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
RD="$root/herdr-orch/slug-x"
mkdir -p "$RD/tasks" "$RD/workspaces"
printf '{"task_id":"T1","status":"merged","workers":[]}' > "$RD/tasks/T1.json"
printf '{"result":{"agents":[]}}' > "$root/a.json"
printf '{"result":{"workspaces":[]}}' > "$root/w.json"
before=$($MANIFEST "$RD")
set +e
$CLI archive-task --repo-slug slug-x --session S --fence 999 --task-id T1 \
    --agents-json "$root/a.json" --workspaces-json "$root/w.json" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" != 0 ]
[ "$($MANIFEST "$RD")" = "$before" ]
[ ! -d "$RD/archive" ]
SH

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
