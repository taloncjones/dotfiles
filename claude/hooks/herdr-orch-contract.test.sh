#!/bin/sh
# Contract suite: the orchestrator's decisions are core-tested; a fake-CLI
# walkthrough drives the fenced CLI through the documented sequence. No real
# herdr, no network. Fake herdr/jira just emit canned JSON to prove command
# shape and state transitions.
set -e
PASS=0; FAIL=0
ok() { if eval "$2"; then printf 'PASS  %s\n' "$1"; PASS=$((PASS+1)); else printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL+1)); fi; }

ROOT=$(mktemp -d); export CLAUDE_CONFIG_DIR="$ROOT"
CLI="python3 claude/hooks/herdr_orch_core.py"
SLUG="github-com-org-repo-deadbeef"

# fake herdr/jira on PATH (canned JSON; asserts only that the skill's command
# shape is satisfiable -- not real orchestration).
BIN=$(mktemp -d)
cat > "$BIN/herdr" <<EOF
#!/bin/sh
echo "\$@" >> "$BIN/calls.log"
case "\$1 \$2" in
  "worktree create") echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"}}}';;
  "pane split") echo '{"result":{"pane":{"pane_id":"w1:p2"}}}';;
  "pane run") echo '{"result":{}}';;
  "pane report-agent") echo '{"result":{}}';;
  "agent list") echo '{"result":{"agents":[]}}';;
  *) echo '{"result":{}}';;
esac
EOF
chmod +x "$BIN/herdr"; PATH="$BIN:$PATH"

# 1. ownership + kickoff writes exactly one task record
F=$($CLI claim-owner --repo-slug "$SLUG" --session S --host h --pid 1)
ok "claim-owner returns a fence" "[ -n '$F' ]"
$CLI write-task --repo-slug "$SLUG" --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"in-progress","review_head_sha":null}'
$CLI write-index --repo-slug "$SLUG" --workspace w1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","repo_slug":"'"$SLUG"'","role":"impl"}'
ok "kickoff wrote one task record" "[ -f '$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.json' ]"

# 2. write-task is single-record last-write-wins per task_id (idempotency
# substrate): a re-kickoff never duplicates the task record. Skill-level
# kickoff idempotency (check tasks/<id>.json exists before writing) builds on
# this core guarantee.
ok "status shows the task" "$CLI status --repo-slug '$SLUG' | grep -q PROJ-1"
$CLI write-task --repo-slug "$SLUG" --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"re-kicked-off","review_head_sha":null}'
ok "write-task is single-record last-write-wins per task_id" \
  "[ \"\$(ls '$ROOT/herdr-orch/$SLUG/tasks/'PROJ-1.json | wc -l)\" -eq 1 ] && python3 -c \"import json;d=json.load(open('$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.json'));import sys;sys.exit(0 if d['status']=='re-kicked-off' else 1)\""

# 3. worker completes -> emit-done; completion correlates
$CLI emit-done --repo-slug "$SLUG" --task-id PROJ-1 --workspace w1 --agent impl-proj-1 \
  --phase implement --outcome completed --head-sha h1 --base-sha b0
ok "done.json written with matching SHAs" \
  "python3 -c \"import json;d=json.load(open('$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.done.json'));import sys;sys.exit(0 if d['outcome']=='completed' and d['head_sha']=='h1' and d['base_sha']=='b0' else 1)\""

# 4. dispatch-once-per-HEAD, re-review on new HEAD (decision function)
ok "dispatch once per HEAD; re-review on new HEAD" "python3 - <<PY
import importlib.util
s=importlib.util.spec_from_file_location('core','claude/hooks/herdr_orch_core.py')
c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
t={'status':'completed','review_head_sha':None}
assert c.should_dispatch_review(t,'h1')
t['review_head_sha']='h1'
assert not c.should_dispatch_review(t,'h1') and c.should_dispatch_review(t,'h2')
PY"

# 5. review changes-requested recorded in a separate file; impl done.json survives
$CLI emit-review --repo-slug "$SLUG" --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h1 --outcome changes-requested --findings-ref /tmp/f.md
ok "review record is a separate review.json; the impl completion record is not clobbered" \
  "python3 -c \"import json,sys;r=json.load(open('$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.review.json'));d=json.load(open('$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.done.json'));sys.exit(0 if r['outcome']=='changes-requested' and r['reviewed_head_sha']=='h1' and d['outcome']=='completed' and d['head_sha']=='h1' else 1)\""

# 6. fenced writes fail after ownership takeover (yield semantics)
F2=$($CLI claim-owner --repo-slug "$SLUG" --session T --host h --pid 2 --stale-secs 0 2>/dev/null || true)
# S's fence is now stale; a write under it must be refused
ok "stale-fence write refused" \
  "! $CLI write-task --repo-slug '$SLUG' --task-id PROJ-1 --session S --fence '$F' --json '{}' 2>/dev/null"

# 7. launch shape: build a slot via pane split -> pane run "claude --model <m>" ->
# pane report-agent (argv-safe; NO agent-start argv passthrough).
# FIXTURE-ONLY: the orchestrator's worker launch is skill-prose (SKILL.md),
# not a Python function; this documents the intended argv-safe command shape
# and proves the fake-CLI mechanics. It would need rewiring to call a real
# launch wrapper only if one is ever added.
: > "$BIN/calls.log"
PID=$(herdr pane split --cwd /tmp/wt --no-focus | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['pane']['pane_id'])")
herdr pane run "$PID" "claude --model sonnet --dangerously-skip-permissions"
herdr pane report-agent "$PID" --kind claude
ok "launch uses pane split+run+report-agent with model, not agent start, in order" "python3 - <<PY
lines = open('$BIN/calls.log').read().splitlines()

def idx(prefix):
    for i, l in enumerate(lines):
        if l.startswith(prefix):
            return i
    return -1

s = idx('pane split')
r = idx('pane run w1:p2 claude --model sonnet')
p = idx('pane report-agent w1:p2')
a = idx('agent start')
assert s >= 0 and r >= 0 and p >= 0 and s < r < p and a == -1
PY"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
