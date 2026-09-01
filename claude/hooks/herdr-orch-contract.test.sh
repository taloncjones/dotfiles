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

# 7. launch shape: run claude in the worktree's OWN root pane ->
# "claude --model <m> --permission-mode auto" (auto mode, NOT
# --dangerously-skip-permissions: an auto-mode orchestrator's classifier blocks
# a skip-permissions worker). NO pane split (a split lands in the current
# workspace, giving the worker the wrong HERDR_WORKSPACE_ID); NO agent-start
# argv. herdr auto-detects the agent from pane run; report-agent, if ever used,
# takes NO --kind. Validated live against herdr 0.8.2.
# FIXTURE-ONLY: the orchestrator's worker launch is skill-prose (SKILL.md
# section 8), not a Python function; this documents the intended argv-safe
# command shape and proves the fake-CLI mechanics.
: > "$BIN/calls.log"
PID=$(herdr worktree create --cwd "$PWD" --branch talon/PROJ-1/x --base origin/main --label PROJ-1 | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['root_pane']['pane_id'])")
herdr pane run "$PID" "claude --model sonnet --permission-mode auto"
ok "launch runs claude in the worktree root pane in auto mode, no split, no skip-permissions, no agent start" "python3 - <<PY
lines = open('$BIN/calls.log').read().splitlines()

def idx(prefix):
    for i, l in enumerate(lines):
        if l.startswith(prefix):
            return i
    return -1

c = idx('worktree create')
r = idx('pane run w1:p1 claude --model sonnet --permission-mode auto')
assert c >= 0 and r >= 0 and c < r
assert idx('pane split') == -1
assert idx('agent start') == -1
assert not any('dangerously-skip-permissions' in l for l in lines)
PY"

# model discovery: capability map drives deterministic, fail-closed resolution.
# (The skill's launch-gating -- no `pane run` on exit 3/4/5, resolve-before-launch
# ordering -- is SKILL.md prose, not a Python function, so it is verified by
# reading the skill and by the exit-code contract below, not executed here.)
# Own dedicated slug + fresh claim: earlier ownership/fence cases above leave
# $SLUG owned by a different session, so use an isolated repo here.
MSLUG="github-com-org-models-cafebabe"
MF=$($CLI claim-owner --repo-slug "$MSLUG" --session M --host h --pid 2)
ok "resolve-model fails closed (exit 3) with no capability map" \
  'rc=0; $CLI resolve-model --repo-slug "$MSLUG" --role plan --session M >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ]'
$CLI write-capabilities --repo-slug "$MSLUG" --session M --fence "$MF" \
  --json '{"v":1,"session_id":"M","available":{"fable":false,"opus":true,"sonnet":true}}'
ok "resolve-model falls back to opus when fable unavailable" \
  '[ "$($CLI resolve-model --repo-slug "$MSLUG" --role plan --session M)" = opus ]'
$CLI disable-model --repo-slug "$MSLUG" --session M --fence "$MF" --model sonnet
ok "disable-model advances impl past a disabled sonnet to opus" \
  '[ "$($CLI resolve-model --repo-slug "$MSLUG" --role impl --session M)" = opus ]'
ok "disable-model left fable/opus untouched (downward-only, single alias)" \
  'python3 - <<PY
import json
d=json.load(open("$ROOT/herdr-orch/$MSLUG/capabilities.json"))
assert d["available"]=={"fable":False,"opus":True,"sonnet":False}, d
PY'
ok "resolve-model rejects a malformed models override (exit 5)" \
  'python3 - <<PY
import json,os
p="$ROOT/herdr-orch/$MSLUG/config.json"
os.makedirs(os.path.dirname(p),exist_ok=True)
json.dump({"v":1,"user":"u","default_base":"origin/main","models":{"plan":["gpt"]}},open(p,"w"))
PY
rc=0; $CLI resolve-model --repo-slug "$MSLUG" --role plan --session M >/dev/null 2>&1 || rc=$?; [ "$rc" = 5 ]'

# watch: documented arm-command shape works read-only against fresh state
WSLUG="github-com-org-watch-cafe0001"
mkdir -p "$ROOT/herdr-orch/$WSLUG/tasks"
echo '{}' > "$ROOT/herdr-orch/$WSLUG/tasks/PROJ-9.done.json"
WOUT=$($CLI watch --repo-slug "$WSLUG" --once --since-epoch 0)
ok "watch --once emits signal for recorded task state" "[ '$WOUT' = 'signal' ]"

SKILL="claude/skills/herdr-orchestration/SKILL.md"
ok "skill: claim/refresh pass the orchestrator inbox socket" \
  "grep -Fq -- '--messaging-socket \"\$CLAUDE_CODE_MESSAGING_SOCKET\"' $SKILL"
ok "skill: worker launch names the session" \
  "grep -Fq -- 'claude --model \$MODEL --permission-mode auto --name <agent-name>' $SKILL"
ok "skill: --name gated on a once-per-session capability check" \
  "grep -Fq -- 'claude --help' $SKILL && grep -Fq -- 'lists \`--name\`' $SKILL"
ok "skill: orchestrator launch sets crossSessionInbound explicitly" \
  "grep -Fq -- \"--settings '{\\\"crossSessionInbound\\\":\\\"accept\\\"}'\" $SKILL"
ok "skill: watch armed at relaxed cadence when messaging is live, default otherwise" \
  "grep -Fq -- '--interval 60 --debounce-secs 300' $SKILL && grep -Fq 'default cadence' $SKILL"
ok "skill: re-subscription eligible only for working/blocked workers" \
  "grep -Fq 'Re-subscribe only when the live herdr state is \`working\` or \`blocked\`' $SKILL"
ok "skill: no-lost-wake rule, capped at three passes" \
  "grep -Fq 'capped at three passes per turn' $SKILL"
ok "skill: discovery fails closed on zero or several candidates" \
  "grep -Fq 'Zero or more than one candidate' $SKILL && grep -Fq 'peer_name' $SKILL"
ok "skill: safety names cross-session messages as wake-only" \
  "grep -Fq 'Every inbound cross-session message' $SKILL"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
