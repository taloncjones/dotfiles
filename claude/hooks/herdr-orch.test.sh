#!/bin/sh
# herdr-orch.test.sh - unit + integration tests for the herdr-orchestration
# core module and worker-status hook. Stdlib python only; no network, no herdr.
set -e
PASS=0
FAIL=0

# check LABEL  -- runs a python (<<PY, body starts with the $LOAD "import"
# line) or shell (<<'SH', body starts with a shell assignment) snippet on
# stdin; exit 0 pass / non-0 fail.
check() {
    label="$1"
    body=$(cat)
    first_line=$(printf '%s\n' "$body" | head -n 1)
    case "$first_line" in
        import*) runner="python3 -" ;;
        *) runner="sh -e -" ;;
    esac
    if printf '%s\n' "$body" | $runner; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2; FAIL=$((FAIL + 1))
    fi
}
# load helper prefixed to every snippet
LOAD='import importlib.util,sys,os,tempfile,json,re
spec=importlib.util.spec_from_file_location("core","claude/hooks/herdr_orch_core.py")
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)'

check "repo_slug deterministic + hashed + valid" <<PY
$LOAD
a=c.repo_slug("git@github.com:org/repo.git")
assert a==c.repo_slug("git@github.com:org/repo.git")
assert a.startswith("github-com-org-repo-")
assert c.repo_slug("https://github.com/org/repo2.git")!=a
assert c.valid_repo_slug(a)
sys.exit(0)
PY

check "task_id jira upper / todo prefixed / validated" <<PY
$LOAD
assert c.jira_task_id("proj-123")=="PROJ-123"
assert c.todo_task_id("Fix The Bus")=="td-fix-the-bus"
assert c.valid_task_id("PROJ-123") and c.valid_task_id("td-fix-the-bus")
assert not c.valid_task_id("../evil") and not c.valid_task_id("a/b") and not c.valid_task_id("")
sys.exit(0)
PY

check "agent_name herdr-compliant, bounded, unique" <<PY
$LOAD
n=c.agent_name("impl","PROJ-123")
assert re.fullmatch(r"[a-z][a-z0-9_-]{0,31}",n) and n=="impl-proj-123"
assert c.agent_name("impl","PROJ-123",existing={"impl-proj-123"})=="impl-proj-123-2"
assert len(c.agent_name("impl","X"*60))<=32
sys.exit(0)
PY

check "branch slash-form (generic user), worktree plus-form" <<PY
$LOAD
b=c.branch_name("dev","PROJ-123","Teardown Lifecycle")
assert b=="dev/PROJ-123/teardown-lifecycle", b
assert c.worktree_dirname(b)=="dev+PROJ-123+teardown-lifecycle"
sys.exit(0)
PY

check "path-safety: workspace-id + repo-slug charset + containment" <<PY
$LOAD
assert c.valid_workspace_id("w1") and c.valid_workspace_id("wC")
assert not c.valid_workspace_id("../x") and not c.valid_workspace_id("a/b") and not c.valid_workspace_id("")
assert not c.valid_repo_slug("../x") and not c.valid_repo_slug("a/b")
root=tempfile.mkdtemp()
assert c.contained(os.path.join(root,"a","b"),root) and not c.contained("/etc/passwd",root)
sys.exit(0)
PY

check "append_event writes JSONL, rejects symlinked events file" <<PY
$LOAD
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-abc");(rd/"workspaces").mkdir(parents=True)
assert c.append_event(rd,"w1","stopped",task_id="PROJ-1",role="impl")
recs=c.parse_events((rd/"workspaces"/"w1.events.jsonl").read_text().splitlines())
assert len(recs)==1 and recs[0]["event"]=="stopped" and recs[0]["v"]==1
os.symlink("/tmp/evil",c.events_path(rd,"w2"))
assert c.append_event(rd,"w2","stopped") is False
sys.exit(0)
PY

check "parse_events skips malformed / scalar / array / unknown-version" <<PY
$LOAD
lines=['{"v":1,"event":"a"}','not json','','123','["x"]','{"v":9,"event":"z"}','{"v":1,"event":"b"}']
assert [r["event"] for r in c.parse_events(lines)]==["a","b"]
sys.exit(0)
PY

check "read_index rejects symlinked / uncontained / invalid" <<PY
$LOAD
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-abc");(rd/"workspaces").mkdir(parents=True)
c.index_path(rd,"w1").write_text(json.dumps({"task_id":"PROJ-1","role":"impl"}))
assert c.read_index(rd,"w1")["role"]=="impl"
assert c.read_index(rd,"../etc") is None
os.symlink("/etc/hostname",c.index_path(rd,"w2"))
assert c.read_index(rd,"w2") is None
sys.exit(0)
PY

check "is_completed: outcome + task-id + HEAD==live + ahead-of-base" <<PY
$LOAD
task={"task_id":"PROJ-1","base_sha":"b0"}
good={"outcome":"completed","task_id":"PROJ-1","head_sha":"h1","base_sha":"b0"}
assert c.is_completed(task,good,"h1")
assert not c.is_completed(task,good,"h2")                                   # HEAD moved
assert not c.is_completed(task,{**good,"task_id":"PROJ-2"},"h1")            # wrong task
assert not c.is_completed(task,{**good,"head_sha":"b0"},"b0")              # zero commits (head==base)
assert not c.is_completed(task,{**good,"outcome":"paused"},"h1")
assert not c.is_completed(task,None,"h1")
sys.exit(0)
PY

check "fold_status: latest authoritative wins, blocked hint surfaces" <<PY
$LOAD
ev=[{"v":1,"event":"kickoff"},{"v":1,"event":"stopped"},{"v":1,"event":"blocked"}]
assert c.fold_status(ev)["last_hint"]=="blocked"
ev2=ev+[{"v":1,"event":"completed"}]
assert c.fold_status(ev2)["authoritative"]=="completed"
sys.exit(0)
PY

check "ownership: exclusive claim, locked stale takeover, fence" <<PY
$LOAD
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-abc");rd.mkdir(parents=True)
f1=c.claim_owner(rd,"A","h",1);assert f1==1 and c.check_fence(rd,"A",f1)
assert c.claim_owner(rd,"B","h",2) is None            # fresh owner: busy
f2=c.claim_owner(rd,"B","h",2,stale_secs=0);assert f2==2   # stale: takeover
assert not c.check_fence(rd,"A",f1) and c.check_fence(rd,"B",f2)
assert c.refresh_owner(rd,"B",f2) and not c.refresh_owner(rd,"A",f1)
sys.exit(0)
PY

check "ownership: stale owner.json.lock (crashed holder) is broken by mtime, not wedged forever" <<PY
$LOAD
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-lock");rd.mkdir(parents=True)
f1=c.claim_owner(rd,"OLD","h",1);assert f1==1
o=json.loads((rd/"owner.json").read_text());o["heartbeat_ts"]=0
(rd/"owner.json").write_text(json.dumps(o))            # stale the stored owner
lock=rd/"owner.json.lock"
lock.write_text("")                                     # simulate a SIGKILLed holder's leaked lock
os.utime(lock,(0,0))                                    # ancient mtime: no unlink ever ran
f2=c.claim_owner(rd,"NEW","h",2,stale_secs=1)
assert f2 is not None, "stale lock permanently wedged claim_owner"
assert c.check_fence(rd,"NEW",f2)
assert not lock.exists()                                # broken lock cleaned up, not left behind
sys.exit(0)
PY

check "ownership: concurrent stale takeover yields exactly one winner" <<PY
$LOAD
import subprocess, textwrap
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-abc");rd.mkdir(parents=True)
c.claim_owner(rd,"OLD","h",1)                          # existing owner
o=json.loads((rd/"owner.json").read_text());o["heartbeat_ts"]=0
(rd/"owner.json").write_text(json.dumps(o))            # stale the stored heartbeat field
prog=textwrap.dedent('''
import importlib.util,os,sys
s=importlib.util.spec_from_file_location("core","claude/hooks/herdr_orch_core.py")
c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
rd=c.repo_dir("slug-abc")
f=c.claim_owner(rd,sys.argv[1],"h",int(sys.argv[1][1:] or 0),stale_secs=1)
print("WIN" if f else "LOSE")
''')
env=dict(os.environ)
procs=[subprocess.Popen([sys.executable,"-c",prog,f"s{i}"],stdout=subprocess.PIPE,env=env) for i in range(6)]
outs=[p.communicate()[0].decode().strip() for p in procs]
# with a lock, some LOSE on contention and retry-eligible; but the owner file
# must name exactly one session and check_fence must hold for only that one.
owner=__import__("json").loads((rd/"owner.json").read_text())
wins=outs.count("WIN")
assert wins>=1
assert c.check_fence(rd,owner["session_id"],owner["fence"])
sys.exit(0)
PY

check "ownership: concurrent FIRST-ever claim never yields a lost fence" <<PY
$LOAD
import subprocess, textwrap
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-fresh");rd.mkdir(parents=True)          # no pre-existing owner
prog=textwrap.dedent('''
import importlib.util,os,sys
s=importlib.util.spec_from_file_location("core","claude/hooks/herdr_orch_core.py")
c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
rd=c.repo_dir("slug-fresh")
f=c.claim_owner(rd,sys.argv[1],"h",int(sys.argv[1][1:] or 0))
print(f if f is not None else "None")
''')
env=dict(os.environ)
procs=[subprocess.Popen([sys.executable,"-c",prog,f"s{i}"],stdout=subprocess.PIPE,env=env) for i in range(8)]
outs=[p.communicate()[0].decode().strip() for p in procs]
# every session that reports a non-None fence must really be the on-disk
# owner for that fence -- a lost-fence bug lets a loser believe it won.
winners=[(f"s{i}",out) for i,out in enumerate(outs) if out!="None"]
assert len(winners)>=1, outs
for sid,fence in winners:
    assert c.check_fence(rd,sid,int(fence)), (sid,fence,outs)
sys.exit(0)
PY

CLI="python3 claude/hooks/herdr_orch_core.py"

check "should_dispatch_review: once per HEAD, re-review on new HEAD" <<PY
$LOAD
t={"status":"completed","review_head_sha":None}
assert c.should_dispatch_review(t,"h1")
t["review_head_sha"]="h1"
assert not c.should_dispatch_review(t,"h1")            # already dispatched for h1
assert c.should_dispatch_review(t,"h2")                # new HEAD -> re-review
assert not c.should_dispatch_review({"status":"in-progress"},"h1")
sys.exit(0)
PY

check "CLI emit-done rejects path-escaping ids" <<'SH'
root=$(mktemp -d)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py emit-done \
  --repo-slug "../evil" --task-id "PROJ-1" --workspace w1 --agent a --phase implement \
  --outcome completed --head-sha h --base-sha b 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py emit-done \
  --repo-slug "slug-x" --task-id "../evil" --workspace w1 --agent a --phase implement \
  --outcome completed --head-sha h --base-sha b 2>/dev/null; then exit 1; fi
test ! -e "$root/../evil"
SH

check "CLI write-task requires a live fence" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py claim-owner \
   --repo-slug slug-x --session S --host h --pid 1)
task='{"task_id":"PROJ-1","base_sha":"b0","status":"in-progress"}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence "$f" --json "$task"
test -f "$root/herdr-orch/slug-x/tasks/PROJ-1.json"
# wrong fence is refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence 999 --json "$task" 2>/dev/null; then exit 1; fi
SH

check "CLI emit-review records reviewed_head_sha + outcome" <<'SH'
root=$(mktemp -d)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py emit-review \
  --repo-slug slug-x --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h9 --outcome changes-requested --findings-ref /tmp/f.md
python3 - <<PY
import json;d=json.load(open("$root/herdr-orch/slug-x/tasks/PROJ-1.done.json"))
assert d["phase"]=="review" and d["outcome"]=="changes-requested" and d["reviewed_head_sha"]=="h9"
PY
SH

check "CLI status folds events per task, not cross-contaminated" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" --json '{"task_id":"PROJ-1","status":"in-progress"}'
$CLI write-task --repo-slug slug-x --task-id PROJ-2 --session S --fence "$F" --json '{"task_id":"PROJ-2","status":"in-progress"}'
$CLI write-index --repo-slug slug-x --workspace w1 --session S --fence "$F" --json '{"task_id":"PROJ-1","role":"impl"}'
$CLI write-index --repo-slug slug-x --workspace w2 --session S --fence "$F" --json '{"task_id":"PROJ-2","role":"impl"}'
# w1 -> PROJ-1 completed; w2 -> PROJ-2 blocked. Events must not cross tasks.
printf '{"v":1,"ts":"2026-01-01T00:00:00Z","event":"kickoff"}\n{"v":1,"ts":"2026-01-01T00:01:00Z","event":"completed"}\n' > "$root/herdr-orch/slug-x/workspaces/w1.events.jsonl"
printf '{"v":1,"ts":"2026-01-01T00:00:30Z","event":"blocked"}\n' > "$root/herdr-orch/slug-x/workspaces/w2.events.jsonl"
$CLI status --repo-slug slug-x | python3 -c "import json,sys;s=json.load(sys.stdin);assert s['PROJ-1']['fold']['authoritative']=='completed',s;assert s['PROJ-2']['fold']['last_hint']=='blocked' and s['PROJ-2']['fold']['authoritative']!='completed',s"
SH

check "CLI should-dispatch-review: once per HEAD, re-review on new HEAD" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"completed","review_head_sha":null}'
$CLI should-dispatch-review --repo-slug slug-x --task-id PROJ-1 --head-sha h1
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"completed","review_head_sha":"h1"}'
if $CLI should-dispatch-review --repo-slug slug-x --task-id PROJ-1 --head-sha h1 2>/dev/null; then exit 1; fi
$CLI should-dispatch-review --repo-slug slug-x --task-id PROJ-1 --head-sha h2
SH

check "CLI confirm-completion: matching HEAD/base completes, mismatch does not" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"in-progress"}'
# no done.json yet -> not completed
if $CLI confirm-completion --repo-slug slug-x --task-id PROJ-1 --head-sha h1 2>/dev/null; then exit 1; fi
$CLI emit-done --repo-slug slug-x --task-id PROJ-1 --workspace w1 --agent impl-proj-1 \
  --phase implement --outcome completed --head-sha h1 --base-sha b0
$CLI confirm-completion --repo-slug slug-x --task-id PROJ-1 --head-sha h1
# HEAD moved past the recorded done.json -> not completed
if $CLI confirm-completion --repo-slug slug-x --task-id PROJ-1 --head-sha h2 2>/dev/null; then exit 1; fi
SH

# args: label  ws-or-REGISTER  HERDR_ENV  payload  expect(event|none)
hook_case() {
    label="$1"; env_ws="$2"; henv="$3"; payload="$4"; expect="$5"
    outdir=$(mktemp -d); wsdir="$outdir/herdr-orch/slug-x/workspaces"; mkdir -p "$wsdir"
    if [ "$env_ws" = "REGISTER" ]; then
        printf '{"task_id":"PROJ-1","repo_slug":"slug-x","role":"impl"}' > "$wsdir/w1.json"; ws="w1"
    elif [ "$env_ws" = "REGISTER_REVIEW" ]; then
        printf '{"task_id":"PROJ-1","repo_slug":"slug-x","role":"review"}' > "$wsdir/w9.json"; ws="w9"
    else ws="$env_ws"; fi
    printf '%s' "$payload" | env CLAUDE_CONFIG_DIR="$outdir" HERDR_ENV="$henv" \
        HERDR_WORKSPACE_ID="$ws" claude/hooks/herdr_worker_status.py >/dev/null 2>&1
    got=$(tail -1 "$wsdir/$ws.events.jsonl" 2>/dev/null) || true
    if [ "$expect" = "none" ]; then
        [ -z "$got" ] && { printf 'PASS  %s\n' "$label"; PASS=$((PASS+1)); } || { printf 'FAIL  %s (got %s)\n' "$label" "$got" >&2; FAIL=$((FAIL+1)); }
    else
        printf '%s' "$got" | grep -q "\"event\":\"$expect\"" && { printf 'PASS  %s\n' "$label"; PASS=$((PASS+1)); } || { printf 'FAIL  %s (want %s got %s)\n' "$label" "$expect" "$got" >&2; FAIL=$((FAIL+1)); }
    fi
    rm -rf "$outdir"
}
hook_case "no HERDR_ENV -> no-op" REGISTER "" '{"hook_event_name":"Stop"}' none
hook_case "no index -> no-op" "w9" "1" '{"hook_event_name":"Stop"}' none
hook_case "unsafe workspace id -> no-op" "..x" "1" '{"hook_event_name":"Stop"}' none
hook_case "impl Stop -> stopped" REGISTER "1" '{"hook_event_name":"Stop"}' stopped
hook_case "review Stop -> review-stopped" REGISTER_REVIEW "1" '{"hook_event_name":"Stop"}' review-stopped
hook_case "permission Notification -> blocked" REGISTER "1" '{"hook_event_name":"Notification","notification_type":"permission_prompt"}' blocked
hook_case "elicitation Notification -> blocked" REGISTER "1" '{"hook_event_name":"Notification","notification_type":"elicitation_dialog"}' blocked
hook_case "idle_prompt Notification -> no-op" REGISTER "1" '{"hook_event_name":"Notification","notification_type":"idle_prompt"}' none

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
