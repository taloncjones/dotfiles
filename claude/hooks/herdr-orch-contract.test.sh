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
SOCKDIR="/tmp/cc-socks-9$(python3 -c 'import random;print("%09d"%random.randrange(10**9))')"
mkdir -m 700 "$SOCKDIR"
INBOX="$SOCKDIR/4242.sock"
trap 'kill "$INBOX_PID" 2>/dev/null; rm -rf "$SOCKDIR"' EXIT
python3 - "$INBOX" "$SOCKDIR/got.txt" <<'PY' &
import socket,sys
srv=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); srv.bind(sys.argv[1]); srv.listen(2); srv.settimeout(10)
try:
    conn,_=srv.accept()
except socket.timeout:
    sys.exit(1)
buf=b""
while not buf.endswith(b"\n"):
    d=conn.recv(4096)
    if not d: break
    buf+=d
open(sys.argv[2],"wb").write(buf)
PY
INBOX_PID=$!
i=0; while [ ! -S "$INBOX" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
ok "fake inbox listener is up" "[ -S '$INBOX' ]"
F=$($CLI claim-owner --repo-slug "$SLUG" --session S --host h --pid 4242 --messaging-socket "$INBOX")
ok "claim-owner returns a fence" "[ -n '$F' ]"
ok "claim-owner recorded the inbox socket" \
  "python3 -c \"import json;o=json.load(open('$ROOT/herdr-orch/$SLUG/owner.json'));assert o['messaging_socket']=='$INBOX' and o['pid']==4242,o\""
$CLI refresh-owner --repo-slug "$SLUG" --session S --fence "$F" --messaging-socket "$INBOX"
$CLI write-task --repo-slug "$SLUG" --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"in-progress","review_head_sha":null}'
$CLI write-index --repo-slug "$SLUG" --workspace w1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","repo_slug":"'"$SLUG"'","role":"impl"}'
ok "kickoff wrote one task record" "[ -f '$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.json' ]"

# 1b. the worker hook (Stop) appends the hint AND pushes one wake to the inbox
printf '{"hook_event_name":"Stop"}' | HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 python3 claude/hooks/herdr_worker_status.py
wait "$INBOX_PID" 2>/dev/null || true
ok "hook appended the stopped hint" "grep -q '\"event\":\"stopped\"' '$ROOT/herdr-orch/$SLUG/workspaces/w1.events.jsonl'"
ok "hook pushed one herdr-wake line to the orchestrator inbox" \
  "python3 -c \"import json;l=open('$SOCKDIR/got.txt','rb').read();assert l.count(b'\\\\n')==1;c=json.loads(l)['message']['content'];assert c.startswith('herdr-wake v=1 repo=$SLUG workspace=w1 event=stopped ts='),c\""
rm -rf "$SOCKDIR"; trap - EXIT

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
  --json '{"v":1,"session_id":"M","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
ok "resolve-model falls back to opus when fable unavailable" \
  '[ "$($CLI resolve-model --repo-slug "$MSLUG" --role plan --session M)" = opus ]'
$CLI disable-model --repo-slug "$MSLUG" --session M --fence "$MF" --model sonnet
ok "disable-model advances impl past a disabled sonnet to opus" \
  '[ "$($CLI resolve-model --repo-slug "$MSLUG" --role impl --session M)" = opus ]'
ok "disable-model left fable/opus untouched (downward-only, single alias)" \
  'python3 - <<PY
import json
d=json.load(open("$ROOT/herdr-orch/$MSLUG/capabilities.json"))
assert d["available"]=={"fable":False,"opus":True,"sonnet":False,"haiku":True}, d
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

# 8. verification contract: author -> pin -> verify -> tamper -> merge_check
# Section 6 stole ownership of $SLUG from session S to session T (stale-fence
# test above), so S's fence $F is no longer valid; reclaim as T (the current
# owner) before writing.
F3=$($CLI claim-owner --repo-slug "$SLUG" --session T --host h --pid 2)
WT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}' > "$WT/contract.json"
SHA=$($CLI verify-contract --repo-slug "$SLUG" --task-id PROJ-1 --worktree "$WT" \
  --contract contract.json --allow-unpinned --validate-only)
ok "plan-phase validate-only prints the pin hash" "printf '%s' '$SHA' | grep -qE '^[0-9a-f]{64}$'"
$CLI write-task --repo-slug "$SLUG" --task-id PROJ-1 --session T --fence "$F3" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"in-progress","contract_path":"contract.json","contract_sha256":"'"$SHA"'"}'
ok "pinned verify passes for the impl phase" \
  "$CLI verify-contract --repo-slug '$SLUG' --task-id PROJ-1 --worktree '$WT' >/dev/null"
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"},{"name":"x","run":"true"}]}' > "$WT/contract.json"
ok "tampered contract is exit 4" \
  "$CLI verify-contract --repo-slug '$SLUG' --task-id PROJ-1 --worktree '$WT' 2>/dev/null; [ \$? -eq 4 ]"
$CLI write-task --repo-slug "$SLUG" --task-id PROJ-1 --session T --fence "$F3" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"reviewed","contract_path":"contract.json","contract_sha256":"'"$SHA"'","merge_check":{"base_main_sha":"m1","branch_head_sha":"h1","result":"pass","ts":"t"}}'
ok "merge_check round-trips through write-task" \
  "python3 -c \"import json,sys;d=json.load(open('$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.json'));sys.exit(0 if d['merge_check']['result']=='pass' else 1)\""
ok "pin fields survive a status-transition rewrite" \
  "python3 -c \"import json,sys;d=json.load(open('$ROOT/herdr-orch/$SLUG/tasks/PROJ-1.json'));sys.exit(0 if d['contract_path']=='contract.json' and len(d['contract_sha256'])==64 else 1)\""

# 9. speculative merge check: detached worktree rebase + verify, conflict abort
GR=$(mktemp -d)
git -C "$GR" init -q -b main
git -C "$GR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$GR" checkout -q -b task
printf '{"v":1,"task_id":"PROJ-9","commands":[{"name":"t","run":"test -f feature.txt"}]}' > "$GR/contract.json"
echo f > "$GR/feature.txt"
git -C "$GR" add contract.json feature.txt
git -C "$GR" -c user.email=t@t -c user.name=t commit -q -m task-work
git -C "$GR" checkout -q main
echo m > "$GR/main.txt"; git -C "$GR" add main.txt
git -C "$GR" -c user.email=t@t -c user.name=t commit -q -m main-advance
BR=$(git -C "$GR" rev-parse task); MAIN=$(git -C "$GR" rev-parse main)
# Pin from the PRE-rebase task branch blob (as the orchestrator would at
# implement dispatch) -- the assertion below proves the pin survives rebase.
F2=$($CLI claim-owner --repo-slug slug-rebase --session S --host h --pid 1)
SHA9=$(git -C "$GR" show task:contract.json | python3 -c "import hashlib,sys;print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())")
$CLI write-task --repo-slug slug-rebase --task-id PROJ-9 --session S --fence "$F2" \
  --json '{"task_id":"PROJ-9","contract_path":"contract.json","contract_sha256":"'"$SHA9"'"}'
TMP="$GR-spec"
git -C "$GR" worktree add --detach -q "$TMP" "$BR"
git -C "$TMP" -c user.email=t@t -c user.name=t rebase -q "$MAIN"
ok "verify-contract passes on the rebased detached tree" \
  "$CLI verify-contract --repo-slug slug-rebase --task-id PROJ-9 --worktree '$TMP' >/dev/null"
git -C "$GR" worktree remove --force "$TMP"
ok "temp worktree cleaned up" "[ ! -d '$TMP' ]"
git -C "$GR" checkout -q main
echo conflict > "$GR/feature.txt"; git -C "$GR" add feature.txt
git -C "$GR" -c user.email=t@t -c user.name=t commit -q -m conflicting
MAIN2=$(git -C "$GR" rev-parse main)
git -C "$GR" worktree add --detach -q "$TMP" "$BR"
if git -C "$TMP" -c user.email=t@t -c user.name=t rebase -q "$MAIN2" >/dev/null 2>&1; then RB=0; else RB=1; fi
ok "conflicting rebase reports failure for conflict result" "[ $RB -eq 1 ]"
git -C "$TMP" rebase --abort 2>/dev/null || true
git -C "$GR" worktree remove --force "$TMP"

# 10. mech kickoff: config-generated contract committed on a fresh branch,
# base_sha = post-contract HEAD, pin computed, shell-safety, run-mech through
# pane run, ledger + record, status spend; relaunch; contract-only cannot complete.
# Section 6 took ownership of $SLUG with session T (and section 8 reclaimed as
# T again); claim-owner --session M --stale-secs 0 takes over again, which is
# why every fenced write here uses M/$F.
FAKE=$(mktemp -d)   # same fake claude as herdr-orch.test.sh
cat > "$FAKE/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_CLAUDE_LOG.argv"
pwd > "$FAKE_CLAUDE_LOG.cwd"
cat > "$FAKE_CLAUDE_LOG.stdin"
echo $$ > "$FAKE_CLAUDE_LOG.pid"
[ -n "$FAKE_CLAUDE_HOOK" ] && sh -c "$FAKE_CLAUDE_HOOK"
sleep "${FAKE_CLAUDE_SLEEP:-0}"
[ -n "$FAKE_CLAUDE_JSON" ] && cat "$FAKE_CLAUDE_JSON"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
chmod +x "$FAKE/claude"; PATH="$FAKE:$PATH"
export FAKE_CLAUDE_LOG="$FAKE/log"; export FAKE_CLAUDE_JSON="$FAKE/res.json"
F=$($CLI claim-owner --repo-slug "$SLUG" --session M --host h --pid 7 --stale-secs 0)
RD="$ROOT/herdr-orch/$SLUG"
printf '{"v":1,"user":"talon","default_base":"origin/main","mech":{"max_turns":9,"contract_commands":[{"name":"t","run":"true"}]}}' > "$RD/config.json"
$CLI write-capabilities --repo-slug "$SLUG" --session M --fence "$F" \
  --json '{"v":1,"session_id":"M","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
ok "mech model resolves to haiku" "[ \"\$($CLI resolve-model --repo-slug '$SLUG' --role mech --session M)\" = haiku ]"
CAPS=$($CLI mech-caps --repo-slug "$SLUG" --max-budget-usd 1)
ok "mech-caps merges config and override" "[ '$CAPS' = '{\"max_turns\": 9, \"max_budget_usd\": 1.0, \"timeout_secs\": 1800}' ]"
# fresh task branch in a scratch repo standing in for the worktree
WT=$(mktemp -d); git -C "$WT" init -q -b main; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
ORIG=$(git -C "$WT" rev-parse HEAD); git -C "$WT" checkout -q -b talon/td-m/x
REL=$($CLI mech-contract --repo-slug "$SLUG" --task-id td-m --worktree "$WT" --base-sha "$ORIG")
git -C "$WT" add "$REL"; git -C "$WT" -c user.name=t -c user.email=t@x commit -q -m "td-m: Add mech contract"
BASE=$(git -C "$WT" rev-parse HEAD)
ok "launch base is the post-contract HEAD, not origin" "[ '$BASE' != '$ORIG' ]"
SHA=$($CLI verify-contract --repo-slug "$SLUG" --task-id td-m --worktree "$WT" --contract "$REL" --allow-unpinned --validate-only)
ok "generated contract validates and pins" "printf '%s' '$SHA' | grep -qE '^[0-9a-f]{64}$'"
BRIEF="$RD/tasks/td-m.brief.md"; mkdir -p "$RD/tasks"; printf 'lint sweep\n' > "$BRIEF"
LID="mech-td-m-20260901T000000Z"
CMD="python3 claude/hooks/herdr_orch_core.py run-mech --repo-slug $SLUG --task-id td-m --workspace w1 --agent mech-td-m --launch-id $LID --model haiku --worktree $WT --base-sha $BASE --brief-file $BRIEF --max-turns 9 --max-budget-usd 1.0 --timeout-secs 1800"
ok "every launch value is shell-safe" "python3 -c \"import re,sys;sys.exit(0 if all(re.fullmatch(r'[A-Za-z0-9_./+:@-]+',w) for w in '$CMD'.split()) else 1)\""
: > "$BIN/calls.log"
PID=$(herdr worktree create --cwd "$PWD" --branch talon/td-m/x --base origin/main --label td-m | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['root_pane']['pane_id'])")
herdr pane run "$PID" "$CMD"
ok "mech launch goes through pane run in the root pane with run-mech, no claude argv" \
  "grep -q '^pane run w1:p1 python3 claude/hooks/herdr_orch_core.py run-mech ' '$BIN/calls.log' && ! grep -q 'pane run w1:p1 claude' '$BIN/calls.log'"
# the fake herdr only logs; run the same command for real to land state
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.3,"modelUsage":{"claude-haiku-4-5-20251001":{}}}' > "$FAKE_CLAUDE_JSON"
export FAKE_CLAUDE_HOOK="$CLI emit-done --repo-slug $SLUG --task-id td-m --workspace w1 --agent mech-td-m --phase implement --outcome completed --head-sha $BASE --base-sha $BASE --launch-id $LID"
$CMD
$CLI write-task --repo-slug "$SLUG" --task-id td-m --session M --fence "$F" \
  --json "{\"task_id\":\"td-m\",\"base_sha\":\"$BASE\",\"status\":\"in-progress\",\"contract_path\":\"$REL\",\"contract_sha256\":\"$SHA\",\"workers\":[{\"role\":\"mech\",\"phase\":\"implement\",\"workspace_id\":\"w1\",\"agent\":\"mech-td-m\",\"launch_id\":\"$LID\",\"model\":\"haiku\",\"peer_name\":null,\"caps\":$CAPS,\"created_by_this_orch\":true,\"started\":\"t\"}]}"
ok "the fake saw the brief on stdin and the worktree as cwd" \
  "[ \"\$(cat $FAKE_CLAUDE_LOG.stdin)\" = 'lint sweep' ] && [ \"\$(cd '$WT' && pwd -P)\" = \"\$(cd \"\$(cat $FAKE_CLAUDE_LOG.cwd)\" && pwd -P)\" ]"
ok "ledger has start+end and status reports spend" \
  "$CLI status --repo-slug '$SLUG' | python3 -c \"import json,sys;s=json.load(sys.stdin);assert s['td-m']['spend']['usd']==0.3 and s['td-m']['spend']['launches']==1,s\""
ok "contract-only branch with a completed record cannot complete (HEAD == launch base)" \
  "! $CLI confirm-completion --repo-slug '$SLUG' --task-id td-m --workspace w1 --head-sha '$BASE'"
# relaunch: new launch id, second workers[] entry, launches doubles
unset FAKE_CLAUDE_HOOK
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":9,"total_cost_usd":0.7}' > "$FAKE_CLAUDE_JSON"
LID2="mech-td-m-20260901T001000Z"
CAPS2=$($CLI mech-caps --repo-slug "$SLUG" --max-turns 20 --max-budget-usd 2)
$CLI run-mech --repo-slug "$SLUG" --task-id td-m --workspace w1 --agent mech-td-m --launch-id "$LID2" --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$BRIEF" --max-turns 20 --max-budget-usd 2.0 --timeout-secs 1800
# the orchestrator appends a second workers[] entry (same workspace, new launch_id, raised caps); status unchanged
$CLI write-task --repo-slug "$SLUG" --task-id td-m --session M --fence "$F" \
  --json "{\"task_id\":\"td-m\",\"base_sha\":\"$BASE\",\"status\":\"in-progress\",\"contract_path\":\"$REL\",\"contract_sha256\":\"$SHA\",\"workers\":[{\"role\":\"mech\",\"phase\":\"implement\",\"workspace_id\":\"w1\",\"agent\":\"mech-td-m\",\"launch_id\":\"$LID\",\"model\":\"haiku\",\"peer_name\":null,\"caps\":$CAPS,\"created_by_this_orch\":true,\"started\":\"t\"},{\"role\":\"mech\",\"phase\":\"implement\",\"workspace_id\":\"w1\",\"agent\":\"mech-td-m\",\"launch_id\":\"$LID2\",\"model\":\"haiku\",\"peer_name\":null,\"caps\":$CAPS2,\"created_by_this_orch\":true,\"started\":\"t2\"}]}"
ok "relaunch: second workers[] entry with a distinct launch id and raised caps; record superseded by launch id; launches doubles" \
  "python3 -c \"import json;t=json.load(open('$RD/tasks/td-m.json'));w=t['workers'];assert len(w)==2 and w[0]['launch_id']!=w[1]['launch_id'] and w[1]['caps']['max_turns']==20,t;d=json.load(open('$RD/tasks/td-m.done.json'));assert d['launch_id']=='$LID2' and d['reason']=='max_turns',d\" && $CLI status --repo-slug '$SLUG' | python3 -c \"import json,sys;s=json.load(sys.stdin);assert s['td-m']['spend']=={'usd':1.0,'turns':13,'launches':2,'unknown_cost_launches':0,'skipped_lines':0},s\""

# 11. effort routing + deep-think: one routing-table snapshot per dispatch, effort on the
# launch line and in workers[], effort-mismatch publishes nothing and touches no
# capability, think escalation lands launch+answer and refuses a concurrent second.
ESLUG="github-com-org-effort-0badf00d"
EF=$($CLI claim-owner --repo-slug "$ESLUG" --session E --host h --pid 3)
ERD="$ROOT/herdr-orch/$ESLUG"; mkdir -p "$ERD/tasks" "$ERD/think"
printf '{"v":1,"user":"talon","default_base":"origin/main"}' > "$ERD/config.json"
$CLI write-capabilities --repo-slug "$ESLUG" --session E --fence "$EF" \
  --json '{"v":1,"session_id":"E","available":{"fable":true,"opus":true,"sonnet":true,"haiku":true}}'
ROUTING=$($CLI routing-table --repo-slug "$ESLUG" --session E)
PM=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["plan"]["model"])')
PE=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["plan"]["effort"] or "inherit")')
IM=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["impl"]["model"])')
IE=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["impl"]["effort"] or "inherit")')
ok "routing snapshot: plan fable/high, impl sonnet/inherit" "[ '$PM/$PE' = fable/high ] && [ '$IM/$IE' = sonnet/inherit ]"
: > "$BIN/calls.log"
PID=$(herdr worktree create --cwd "$PWD" --branch talon/PROJ-E/x --base origin/main --label PROJ-E | python3 -c "import json,sys;print(json.load(sys.stdin)['result']['root_pane']['pane_id'])")
herdr pane run "$PID" "claude --model $PM --effort $PE --permission-mode auto --name plan-proj-e"
ok "plan launch line carries --effort high" "grep -q '^pane run w1:p1 claude --model fable --effort high --permission-mode auto --name plan-proj-e$' '$BIN/calls.log'"
# impl inherits: the snapshot says null, so the launch line has NO --effort; review is high
if [ "$IE" = inherit ]; then herdr pane run "$PID" "claude --model $IM --permission-mode auto --name impl-proj-e"; else herdr pane run "$PID" "claude --model $IM --effort $IE --permission-mode auto --name impl-proj-e"; fi
ok "impl launch line omits --effort when the snapshot says inherit" "grep -q '^pane run w1:p1 claude --model sonnet --permission-mode auto --name impl-proj-e$' '$BIN/calls.log'"
RM=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["review"]["model"])'); RE=$(printf '%s' "$ROUTING" | python3 -c 'import json,sys;print(json.load(sys.stdin)["review"]["effort"] or "inherit")')
herdr pane run "$PID" "claude --model $RM --effort $RE --permission-mode auto --name rev-proj-e"
ok "review launch line carries --effort high" "grep -q '^pane run w1:p1 claude --model opus --effort high --permission-mode auto --name rev-proj-e$' '$BIN/calls.log'"
BANNER=$(mktemp); printf 'Claude Code v2.1.260\n  Fable 5.1 with high effort \302\267 Claude Max\n' > "$BANNER"
ok "banner classifies ok for the requested pin" "[ \"\$($CLI classify-banner --repo-slug '$ESLUG' --model $PM --effort $PE --text-file '$BANNER')\" = ok ]"
$CLI write-task --repo-slug "$ESLUG" --task-id PROJ-E --session E --fence "$EF" \
  --json "{\"task_id\":\"PROJ-E\",\"base_sha\":\"b0\",\"status\":\"in-progress\",\"workers\":[{\"role\":\"impl\",\"phase\":\"plan\",\"workspace_id\":\"w1\",\"agent\":\"plan-proj-e\",\"model\":\"$PM\",\"effort\":\"$PE\",\"created_by_this_orch\":true,\"started\":\"t\"}]}"
ok "workers[] records the pinned effort" "python3 -c \"import json;t=json.load(open('$ERD/tasks/PROJ-E.json'));assert t['workers'][0]['effort']=='high',t\""
# effort-mismatch: a config pins impl to high (fresh snapshot), the banner shows none -> nothing published, capabilities untouched, no disable-model, no workspace close
printf '{"v":1,"user":"talon","default_base":"origin/main","effort":{"impl":"high"}}' > "$ERD/config.json"
ROUTING2=$($CLI routing-table --repo-slug "$ESLUG" --session E)
IE2=$(printf '%s' "$ROUTING2" | python3 -c 'import json,sys;print(json.load(sys.stdin)["impl"]["effort"])')
ok "config override pins impl effort in a fresh snapshot" "[ '$IE2' = high ]"
printf 'Claude Code v2.1.260\n  Sonnet 5 \302\267 Claude Max\n' > "$BANNER"
CLS=$($CLI classify-banner --repo-slug "$ESLUG" --model sonnet --effort $IE2 --text-file "$BANNER" --json)
ok "impl pinned high but banner shows none -> effort-mismatch with observed effort null" "[ '$CLS' = '{\"class\": \"effort-mismatch\", \"model\": \"Sonnet 5\", \"effort\": null}' ]"
CAP_BEFORE=$(cat "$ERD/capabilities.json"); : > "$BIN/calls.log"
herdr pane run "$PID" "claude --model sonnet --effort $IE2 --permission-mode auto --name impl-proj-e"
# the skill terminates the worker and publishes nothing; simulate exactly that and assert the invariants
herdr agent prompt "$PID" "/exit"
ok "effort-mismatch: capabilities unchanged, no disable-model, no workspace close, record unchanged" \
  "[ \"\$(cat '$ERD/capabilities.json')\" = \"\$CAP_BEFORE\" ] && ! grep -q disable-model '$BIN/calls.log' && ! grep -q 'workspace close' '$BIN/calls.log' && python3 -c \"import json;t=json.load(open('$ERD/tasks/PROJ-E.json'));assert len(t['workers'])==1 and t['status']=='in-progress',t\""
printf 'Claude Code v2.1.260\n  Sonnet 5 with high effort \302\267 Claude Max\n' > "$BANNER"
ok "downgrade still flips the requested alias" \
  "[ \"\$($CLI classify-banner --repo-slug '$ESLUG' --model fable --effort high --text-file '$BANNER')\" = downgrade ] && $CLI disable-model --repo-slug '$ESLUG' --session E --fence '$EF' --model fable && [ \"\$($CLI resolve-model --repo-slug '$ESLUG' --role plan --session E)\" = opus ]"
# think escalation (triage): question at the canonical path, run-think with --add-dir tasks, launch+answer, status _think, concurrent refusal, then an explicit other
TWT=$(mktemp -d); git -C "$TWT" init -q; git -C "$TWT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
git -C "$TWT" remote add origin https://github.com/org/effort.git
TSLUG=$(python3 -c "import importlib.util;s=importlib.util.spec_from_file_location('c','claude/hooks/herdr_orch_core.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c);print(c.repo_slug('https://github.com/org/effort.git'))")
TRD="$ROOT/herdr-orch/$TSLUG"; mkdir -p "$TRD/tasks" "$TRD/think"
TF=$($CLI claim-owner --repo-slug "$TSLUG" --session E --host h --pid 4)
TID=think-triage-20260904170000
printf 'You are %s ...\n## Question\nWhich of the three todos first?\n' "$TID" > "$TRD/think/$TID.question.md"
export FAKE_CLAUDE_LOG="$FAKE/tlog" FAKE_CLAUDE_JSON="$FAKE/tres.json"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":5,"total_cost_usd":1.1,"modelUsage":{"claude-fable-5-1":{}},"structured_output":{"recommendation":"todo B first","rationale":"unblocks A and C","options":[{"label":"B first","summary":"s","tradeoffs":"t","risk":"low"},{"label":"A first","summary":"s","tradeoffs":"t","risk":"medium"}],"confidence":"high"}}' > "$FAKE_CLAUDE_JSON"
TCMD="python3 claude/hooks/herdr_orch_core.py run-think --repo-slug $TSLUG --session E --fence $TF --think-id $TID --kind triage --model fable --effort high --cwd $TWT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 900 --add-dir tasks"
ok "every think launch value is shell-safe" "python3 -c \"import re,sys;sys.exit(0 if all(re.fullmatch(r'[A-Za-z0-9_./+:@-]+',w) for w in '$TCMD'.split()) else 1)\""
$TCMD
ok "think launch record then answer landed, answered" \
  "python3 -c \"import json;l=json.load(open('$TRD/think/$TID.launch.json'));a=json.load(open('$TRD/think/$TID.answer.json'));assert l['kind']=='triage' and a['status']=='answered' and a['answer']['recommendation']=='todo B first',(l,a)\""
ok "the advisor saw the question on stdin, the repo as cwd, and --add-dir tasks" \
  "grep -q 'Which of the three todos first' '$FAKE_CLAUDE_LOG.stdin' && grep -qx -- '$TRD/tasks' '$FAKE_CLAUDE_LOG.argv' && grep -qx -- '--restricted' '$FAKE_CLAUDE_LOG.argv'"
ok "status reports _think" "$CLI status --repo-slug '$TSLUG' | python3 -c \"import json,sys;t=json.load(sys.stdin)['_think'];assert t['launches']==1 and t['answered']==1 and t['usd']==1.1,t\""
TID2=think-other-20260904170100; printf 'q\n' > "$TRD/think/$TID2.question.md"
rm "$TRD/think/$TID.answer.json"          # first escalation looks live again
ok "a second run-think while one is live exits 4 and writes nothing" \
  "rc=0; $CLI run-think --repo-slug $TSLUG --session E --fence $TF --think-id $TID2 --kind other --model fable --effort high --cwd $TWT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 900 >/dev/null 2>&1 || rc=\$?; [ \"\$rc\" = 4 ] && [ ! -e '$TRD/think/$TID2.launch.json' ]"
python3 -c "import json;p='$TRD/think/$TID.launch.json';d=json.load(open(p));d['started']='2020-01-01T00:00:00Z';json.dump(d,open(p,'w'))"
$CLI run-think --repo-slug $TSLUG --session E --fence $TF --think-id $TID2 --kind other --model fable --effort high --cwd $TWT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 900
ok "explicit other-kind escalation succeeds once the first is no longer live" "[ -e '$TRD/think/$TID2.answer.json' ]"
# brief rendering: Routing block equals the snapshot; opt-in line; helper rule; no-workflow variant
render_brief() {   # $1 = ROUTING json, $2 = granted|withheld
  printf '%s' "$1" | python3 -c '
import json,sys
t=json.load(sys.stdin); mode=sys.argv[1]
print("## Routing")
for r in ("plan","impl","review","mech","think"):
    m=t[r]["model"] or "unavailable"; e=t[r]["effort"] or "inherit"
    print(f"- {r}: {m} / {e}")
print("Workflow opt-in: granted by the user'"'"'s standing order (global CLAUDE.md, Default Skill Routing) for this orchestrated task; default size guideline" if mode=="granted" else "Workflow opt-in: withheld for this task")
print("Workflow/subagent helpers never call `herdr_orch_core.py`; only you emit the completion record.")' "$2"
}
B1=$(render_brief "$ROUTING" granted); B2=$(render_brief "$ROUTING" withheld)
ok "brief Routing block matches the snapshot and carries the grant + helper rule" \
  "printf '%s' \"\$B1\" | grep -q '^- plan: fable / high$' && printf '%s' \"\$B1\" | grep -q '^- impl: sonnet / inherit$' && printf '%s' \"\$B1\" | grep -q '^Workflow opt-in: granted by the user' && printf '%s' \"\$B1\" | grep -q 'never call \`herdr_orch_core.py\`'"
ok "no-workflow kickoff renders the withheld line" "printf '%s' \"\$B2\" | grep -q '^Workflow opt-in: withheld for this task$'"
ok "skill documents the brief Routing block and both opt-in lines" \
  "grep -q '## Routing' claude/skills/herdr-orchestration/references/brief-template.md && grep -q 'withheld for this task' claude/skills/herdr-orchestration/references/brief-template.md"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
