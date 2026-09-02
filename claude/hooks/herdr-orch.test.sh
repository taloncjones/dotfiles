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

check "is_completed: outcome + task-id + workspace + HEAD==live + ahead-of-base" <<PY
$LOAD
task={"task_id":"PROJ-1","base_sha":"b0"}
good={"outcome":"completed","task_id":"PROJ-1","workspace_id":"w1","head_sha":"h1","base_sha":"b0"}
assert c.is_completed(task,good,"h1","w1")
assert not c.is_completed(task,good,"h2","w1")                              # HEAD moved
assert not c.is_completed(task,good,"h1","w2")                             # foreign workspace (provenance)
assert not c.is_completed(task,{**good,"task_id":"PROJ-2"},"h1","w1")       # wrong task
assert not c.is_completed(task,{**good,"head_sha":"b0"},"b0","w1")         # zero commits (head==base)
assert not c.is_completed(task,{**good,"outcome":"paused"},"h1","w1")
assert not c.is_completed(task,None,"h1","w1")
sys.exit(0)
PY

check "is_reviewed: dispatched==reviewed==HEAD + workspace + no blocking; else rejected" <<PY
$LOAD
task={"task_id":"PROJ-1","review_head_sha":"h1"}
done={"task_id":"PROJ-1","workspace_id":"w9","phase":"review","outcome":"approved","reviewed_head_sha":"h1","blocking_count":0}
assert c.is_reviewed(task,done,"h1","w9")
assert not c.is_reviewed(task,done,"h2","w9")                              # HEAD advanced past the reviewed SHA
assert not c.is_reviewed(task,done,"h1","w8")                             # foreign review workspace (provenance)
assert not c.is_reviewed(task,{**done,"blocking_count":2},"h1","w9")      # approved but blocking findings remain
assert not c.is_reviewed(task,{**done,"reviewed_head_sha":"h2"},"h2","w9") # reviewer logged new HEAD, dispatch was h1
assert not c.is_reviewed({"task_id":"PROJ-1","review_head_sha":"h0"},done,"h1","w9")  # dispatch != reviewed/HEAD
assert not c.is_reviewed(task,{**done,"outcome":"changes-requested"},"h1","w9")
assert not c.is_reviewed(task,{**done,"phase":"implement"},"h1","w9")     # not a review record
assert not c.is_reviewed(task,{**done,"task_id":"PROJ-2"},"h1","w9")
assert not c.is_reviewed(task,None,"h1","w9")
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

check "CLI write-task rejects non-dict json and task_id mismatch" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py claim-owner \
   --repo-slug slug-x --session S --host h --pid 1)
# a bare array would persist and later crash `status` on .get -> must be refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence "$f" --json '[]' 2>/dev/null; then exit 1; fi
# a dict whose task_id disagrees with --task-id is refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence "$f" --json '{"task_id":"PROJ-2"}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/slug-x/tasks/PROJ-1.json"
# the matching record persists
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence "$f" --json '{"task_id":"PROJ-1","status":"kickoff"}'
test -f "$root/herdr-orch/slug-x/tasks/PROJ-1.json"
SH

check "CLI write-index rejects a non-dict payload (would orphan the workspace)" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py claim-owner \
   --repo-slug slug-x --session S --host h --pid 1)
# a bare array reads back as None from read_index -> events silently orphaned; must be refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py write-index \
   --repo-slug slug-x --workspace w1 --session S --fence "$f" --json '[]' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/slug-x/workspaces/w1.json"
# a well-formed object persists
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py write-index \
   --repo-slug slug-x --workspace w1 --session S --fence "$f" --json '{"task_id":"PROJ-1","role":"impl"}'
test -f "$root/herdr-orch/slug-x/workspaces/w1.json"
SH

check "CLI confirm-review: dispatched==reviewed==HEAD+workspace+no-blocking passes; else fails" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
# no task/review yet -> not reviewed
if $CLI confirm-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --head-sha h1 2>/dev/null; then exit 1; fi
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"review-dispatched","review_head_sha":"h1"}'
# task dispatched at h1 but no review.json yet -> not reviewed
if $CLI confirm-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --head-sha h1 2>/dev/null; then exit 1; fi
$CLI emit-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h1 --outcome approved
# dispatched == reviewed == HEAD (h1), right workspace, no blocking -> merge-ready
$CLI confirm-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --head-sha h1
# a foreign review workspace's record does not clear the gate (provenance)
if $CLI confirm-review --repo-slug slug-x --task-id PROJ-1 --workspace w8 --head-sha h1 2>/dev/null; then exit 1; fi
# HEAD advanced to h2 after a clean review of h1 -> gate holds
if $CLI confirm-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --head-sha h2 2>/dev/null; then exit 1; fi
# reviewer records the new live SHA h2 though dispatch was h1 -> still rejected
$CLI emit-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h2 --outcome approved
if $CLI confirm-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --head-sha h2 2>/dev/null; then exit 1; fi
# approved but blocking findings remain -> rejected
$CLI emit-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h1 --outcome approved --blocking-count 1
if $CLI confirm-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --head-sha h1 2>/dev/null; then exit 1; fi
# a changes-requested review is never merge-ready
$CLI emit-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h1 --outcome changes-requested
if $CLI confirm-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --head-sha h1 2>/dev/null; then exit 1; fi
SH

check "CLI emit-review writes a separate review.json with blocking_count, never clobbering done.json" <<'SH'
root=$(mktemp -d)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_orch_core.py emit-review \
  --repo-slug slug-x --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h9 --outcome changes-requested --blocking-count 3 --findings-ref /tmp/f.md
python3 - <<PY
import json,os
d=json.load(open("$root/herdr-orch/slug-x/tasks/PROJ-1.review.json"))
assert d["phase"]=="review" and d["outcome"]=="changes-requested" and d["reviewed_head_sha"]=="h9"
assert d["blocking_count"]==3
assert not os.path.exists("$root/herdr-orch/slug-x/tasks/PROJ-1.done.json")  # review record is a distinct file
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

check "CLI status ignores .review.json sidecars (does not overwrite the task's status)" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"reviewed","review_head_sha":"h1"}'
$CLI emit-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h1 --outcome approved
# the sidecar sorts after PROJ-1.json; status must still report the real status
$CLI status --repo-slug slug-x | python3 -c "import json,sys;s=json.load(sys.stdin);assert list(s)==['PROJ-1','_totals','_orphans'] and s['PROJ-1']['status']=='reviewed',s"
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

check "CLI confirm-completion: matching HEAD/base/workspace completes, mismatch does not" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","base_sha":"b0","status":"in-progress"}'
# no done.json yet -> not completed
if $CLI confirm-completion --repo-slug slug-x --task-id PROJ-1 --workspace w1 --head-sha h1 2>/dev/null; then exit 1; fi
$CLI emit-done --repo-slug slug-x --task-id PROJ-1 --workspace w1 --agent impl-proj-1 \
  --phase implement --outcome completed --head-sha h1 --base-sha b0
$CLI confirm-completion --repo-slug slug-x --task-id PROJ-1 --workspace w1 --head-sha h1
# a foreign workspace's record does not satisfy the gate (provenance)
if $CLI confirm-completion --repo-slug slug-x --task-id PROJ-1 --workspace w2 --head-sha h1 2>/dev/null; then exit 1; fi
# HEAD moved past the recorded done.json -> not completed
if $CLI confirm-completion --repo-slug slug-x --task-id PROJ-1 --workspace w1 --head-sha h2 2>/dev/null; then exit 1; fi
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

# --- model discovery: write-capabilities / resolve-model / disable-model / classify-probe ---

check "valid_capabilities strict: exact keys, int-not-bool v, session match" <<PY
$LOAD
ok={"v":1,"session_id":"S","available":{"fable":False,"opus":True,"sonnet":True,"haiku":True}}
assert c.valid_capabilities(ok,"S")
assert not c.valid_capabilities(ok,"OTHER")
assert not c.valid_capabilities({"v":True,"session_id":"S","available":{"fable":False,"opus":True,"sonnet":True,"haiku":True}},"S")
assert not c.valid_capabilities({"v":1,"session_id":"S","available":{"opus":True,"sonnet":True,"haiku":True}},"S")
assert not c.valid_capabilities({"v":1,"session_id":"S","available":{"fable":False,"opus":True,"sonnet":True,"haiku":True,"gpt":True}},"S")
assert not c.valid_capabilities({"v":1,"session_id":"S","available":{"fable":0,"opus":True,"sonnet":True,"haiku":True}},"S")
assert not c.valid_capabilities({"v":1,"session_id":"S","available":[]},"S")
assert not c.valid_capabilities([],"S")
sys.exit(0)
PY

check "write-capabilities CLI round-trips; rejects bad payload and stale fence" <<'SH'
CLI="python3 claude/hooks/herdr_orch_core.py"
export CLAUDE_CONFIG_DIR="$(mktemp -d)"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-capabilities --repo-slug slug-x --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
test -f "$CLAUDE_CONFIG_DIR/herdr-orch/slug-x/capabilities.json"
rc=0; $CLI write-capabilities --repo-slug slug-x --session S --fence "$F" \
  --json '{"v":1,"session_id":"T","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}' 2>/dev/null || rc=$?
test "$rc" != "0"
rc=0; $CLI write-capabilities --repo-slug slug-x --session S --fence 999 \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}' 2>/dev/null || rc=$?
test "$rc" != "0"
SH

check "role_preference: defaults, override precedence, malformed -> None" <<PY
$LOAD
assert c.role_preference("plan",{})==("fable","opus")
assert c.role_preference("impl",{})==("sonnet","opus")
assert c.role_preference("review",{})==("opus","sonnet")
assert c.role_preference("bogus",{}) is None
assert c.role_preference("plan",{"models":{"plan":["opus","opus","fable"]}})==("opus","fable")
assert c.role_preference("plan",{"models":{"plan":["gpt"]}}) is None
assert c.role_preference("plan",{"models":["opus"]}) is None
assert c.role_preference("plan",{"models":{"plan":"opus"}}) is None
assert c.role_preference("plan",{"models":{"plan":[]}}) is None          # empty override -> exit 5, not 4
assert c.role_preference("impl",{"models":{"orchestrator":["opus"]}}) is None  # legacy/unknown key -> malformed
assert c.role_preference("impl",{"models":{"implement":["opus"]}}) is None     # typo'd role key -> malformed
sys.exit(0)
PY

check "resolve_model: filtering and error codes" <<PY
$LOAD
full={"fable":True,"opus":True,"sonnet":True}
nofable={"fable":False,"opus":True,"sonnet":True}
assert c.resolve_model("plan",full,{})==("fable",None)
assert c.resolve_model("plan",nofable,{})==("opus",None)
assert c.resolve_model("impl",nofable,{})==("sonnet",None)
assert c.resolve_model("review",nofable,{})==("opus",None)
assert c.resolve_model("plan",None,{})==(None,3)
assert c.resolve_model("plan",{"fable":False,"opus":False,"sonnet":False},{})==(None,4)
assert c.resolve_model("bogus",full,{})==(None,5)
assert c.resolve_model("plan",full,{"models":{"plan":["gpt"]}})==(None,5)
sys.exit(0)
PY

check "resolve-model CLI: exit codes, stdout discipline, config override" <<'SH'
CLI="python3 claude/hooks/herdr_orch_core.py"
export CLAUDE_CONFIG_DIR="$(mktemp -d)"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
rc=0; out=$($CLI resolve-model --repo-slug slug-x --role plan --session S 2>/dev/null) || rc=$?
test "$rc" = "3"; test -z "$out"
$CLI write-capabilities --repo-slug slug-x --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
m=$($CLI resolve-model --repo-slug slug-x --role plan --session S); test "$m" = "opus"
$CLI write-capabilities --repo-slug slug-x --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":false,"sonnet":false,"haiku":false}}'
rc=0; $CLI resolve-model --repo-slug slug-x --role plan --session S >/dev/null 2>&1 || rc=$?; test "$rc" = "4"
rc=0; $CLI resolve-model --repo-slug slug-x --role plan --session OTHER >/dev/null 2>&1 || rc=$?; test "$rc" = "3"
rc=0; $CLI resolve-model --repo-slug slug-x --role nope --session S >/dev/null 2>&1 || rc=$?; test "$rc" = "5"
printf 'not json' > "$CLAUDE_CONFIG_DIR/herdr-orch/slug-x/capabilities.json"
rc=0; $CLI resolve-model --repo-slug slug-x --role plan --session S >/dev/null 2>&1 || rc=$?; test "$rc" = "3"
SH

check "disable-model: flips one alias false, downward-only, guards session+alias" <<'SH'
CLI="python3 claude/hooks/herdr_orch_core.py"
export CLAUDE_CONFIG_DIR="$(mktemp -d)"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-capabilities --repo-slug slug-x --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":true,"opus":true,"sonnet":true,"haiku":true}}'
$CLI disable-model --repo-slug slug-x --session S --fence "$F" --model fable
python3 - <<PY
import json,os
d=json.load(open(os.environ["CLAUDE_CONFIG_DIR"]+"/herdr-orch/slug-x/capabilities.json"))
assert d["available"]=={"fable":False,"opus":True,"sonnet":True,"haiku":True}, d
PY
$CLI disable-model --repo-slug slug-x --session S --fence "$F" --model sonnet
python3 - <<PY
import json,os
d=json.load(open(os.environ["CLAUDE_CONFIG_DIR"]+"/herdr-orch/slug-x/capabilities.json"))
assert d["available"]=={"fable":False,"opus":True,"sonnet":False,"haiku":True}, d
PY
rc=0; $CLI disable-model --repo-slug slug-x --session S --fence "$F" --model gpt 2>/dev/null || rc=$?; test "$rc" != "0"
export CLAUDE_CONFIG_DIR="$(mktemp -d)"
F2=$($CLI claim-owner --repo-slug slug-y --session S --host h --pid 1)
rc=0; $CLI disable-model --repo-slug slug-y --session S --fence "$F2" --model fable 2>/dev/null || rc=$?; test "$rc" != "0"
SH

check "classify_probe: available / 403+credit-429 unavailable / ambiguous-429+else indeterminate" <<PY
$LOAD
ok={"is_error":False,"modelUsage":{"claude-fable-5":{"in":1}}}
assert c.classify_probe(ok,"fable")=="available"
assert c.classify_probe({"is_error":False,"modelUsage":{"claude-sonnet-5":{}}},"fable")=="indeterminate"
# 403 restriction is a hard "not launchable" signal
assert c.classify_probe({"is_error":True,"api_error_status":403},"fable")=="unavailable"
# a 429 whose message names usage/credit exhaustion -> unavailable (out of credits; fall back to Opus)
assert c.classify_probe({"is_error":True,"api_error_status":429,"result":"You're out of usage credits"},"fable")=="unavailable"
assert c.classify_probe({"is_error":True,"api_error_status":429,"error":{"message":"Usage limit reached"}},"fable")=="unavailable"
assert c.classify_probe({"is_error":True,"api_error_status":"429","result":"out of usage credits"},"fable")=="unavailable"  # string status coerced
# a bare/transient 429 (rate limit, no exhaustion message) stays indeterminate -> caller aborts
assert c.classify_probe({"is_error":True,"api_error_status":429},"fable")=="indeterminate"
assert c.classify_probe({"is_error":True,"api_error_status":429,"result":"rate limit exceeded, retry later"},"fable")=="indeterminate"
# an exhaustion message without a 429 status is not the exhaustion signal (do not over-broaden)
assert c.classify_probe({"is_error":True,"result":"out of usage credits"},"fable")=="indeterminate"
assert c.classify_probe({"is_error":True,"api_error_status":500},"fable")=="indeterminate"
assert c.classify_probe({"is_error":True},"fable")=="indeterminate"
assert c.classify_probe("not a dict","fable")=="indeterminate"
assert c.classify_probe({},"fable")=="indeterminate"
sys.exit(0)
PY

check "classify-probe CLI prints classification" <<'SH'
CLI="python3 claude/hooks/herdr_orch_core.py"
out=$($CLI classify-probe --repo-slug x --model fable --json '{"is_error":true,"api_error_status":429,"result":"usage limit reached"}')
test "$out" = "unavailable"
out=$($CLI classify-probe --repo-slug x --model fable --json '{"is_error":true,"api_error_status":429}')
test "$out" = "indeterminate"
out=$($CLI classify-probe --repo-slug x --model fable --json '{"is_error":false,"modelUsage":{"claude-fable-5":{}}}')
test "$out" = "available"
SH

check "watch_scan snapshots only validated watched files" <<PY
$LOAD
import pathlib
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("github-com-org-repo-deadbeef")
(rd/"tasks").mkdir(parents=True); (rd/"workspaces").mkdir(parents=True)
(rd/"tasks"/"PROJ-1.done.json").write_text("{}")
(rd/"tasks"/"PROJ-1.review.json").write_text("{}")
(rd/"workspaces"/"w1.events.jsonl").write_text("")
(rd/"tasks"/"PROJ-1.json").write_text("{}")             # primary record: not watched
(rd/"tasks"/"a b.done.json").write_text("{}")           # invalid stem: ignored
(rd/"tasks"/"notes.txt").write_text("")                 # outside globs: ignored
snap,failed=c.watch_scan(rd,{})
names=sorted(pathlib.Path(k).name for k in snap)
assert names==["PROJ-1.done.json","PROJ-1.review.json","w1.events.jsonl"],names
assert failed==set()
for v in snap.values():
    assert isinstance(v,tuple) and len(v)==2
sys.exit(0)
PY

check "watch_scan missing dirs empty; watch_changed semantics" <<PY
$LOAD
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("github-com-org-repo-deadbeef")   # nothing created
snap,failed=c.watch_scan(rd,{})
assert snap=={} and failed==set()
assert not c.watch_changed({},{})
assert c.watch_changed({},{"a":(1,1)})          # new file
assert c.watch_changed({"a":(1,1)},{"a":(2,1)}) # mtime bump
assert not c.watch_changed({"a":(1,1)},{})      # deletion is silent
assert not c.watch_changed({"a":(1,1)},{"a":(1,1)})
sys.exit(0)
PY

check "watch_scan retains prev entries under an unreadable dir" <<PY
$LOAD
if hasattr(os,"geteuid") and os.geteuid()==0:
    sys.exit(0)  # chmod 0 is not a barrier for root; skip
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("github-com-org-repo-deadbeef")
(rd/"tasks").mkdir(parents=True)
p=rd/"tasks"/"PROJ-1.done.json"; p.write_text("{}")
snap,_=c.watch_scan(rd,{})
os.chmod(rd/"tasks",0)
try:
    snap2,failed=c.watch_scan(rd,snap)
finally:
    os.chmod(rd/"tasks",0o700)
assert "tasks" in failed
assert str(p) in snap2 and snap2[str(p)]==snap[str(p)]
assert not c.watch_changed(snap,snap2)
sys.exit(0)
PY

check "heartbeat_active gates on validated primary record status" <<PY
$LOAD
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("github-com-org-repo-deadbeef")
(rd/"tasks").mkdir(parents=True)
assert not c.heartbeat_active(rd)                       # empty
(rd/"tasks"/"PROJ-1.json").write_text(json.dumps({"status":"merged"}))
assert not c.heartbeat_active(rd)                       # terminal only
(rd/"tasks"/"PROJ-2.json").write_text("not json")
assert not c.heartbeat_active(rd)                       # malformed = inactive
(rd/"tasks"/"PROJ-3.done.json").write_text(json.dumps({"status":"in-progress"}))
assert not c.heartbeat_active(rd)                       # sidecar never counts
(rd/"tasks"/"a b.json").write_text(json.dumps({"status":"in-progress"}))
assert not c.heartbeat_active(rd)                       # invalid stem never counts
for s in ("in-progress","blocked","review-dispatched"):
    (rd/"tasks"/"PROJ-4.json").write_text(json.dumps({"status":s}))
    assert c.heartbeat_active(rd), s
sys.exit(0)
PY

check "watch_tick debounce, precedence, heartbeat reset" <<PY
$LOAD
st={"pending":False,"suppress_until":0.0,"last_emit":0.0}
assert c.watch_tick(st,True,False,10.0,1800,60)=="signal"
assert c.watch_tick(st,True,False,20.0,1800,60) is None      # debounced
assert c.watch_tick(st,False,False,71.0,1800,60)=="signal"   # coalesced after window
assert c.watch_tick(st,False,True,100.0,1800,60) is None     # heartbeat not due
assert c.watch_tick(st,True,True,2000.0,1800,60)=="signal"   # signal precedence
assert c.watch_tick(st,False,True,4000.0,1800,60)=="heartbeat"
assert c.watch_tick(st,False,True,4001.0,1800,60) is None    # reset by emit
assert c.watch_tick(st,False,False,9000.0,1800,60) is None   # inactive: silent
sys.exit(0)
PY

check "watch --once emits one signal for new files, none when quiet" <<PY
$LOAD
import io,contextlib,time
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("github-com-org-repo-deadbeef")
(rd/"tasks").mkdir(parents=True); (rd/"workspaces").mkdir(parents=True)
def run(argv):
    buf=io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            code=c.main(argv)
    except SystemExit as e:
        code=e.code
    return code,buf.getvalue()
base=["watch","--repo-slug","github-com-org-repo-deadbeef","--once","--since-epoch"]
past=str(time.time()-3600); future=str(time.time()+3600)
(rd/"tasks"/"PROJ-1.done.json").write_text("{}")
(rd/"tasks"/"PROJ-1.review.json").write_text("{}")
(rd/"workspaces"/"w1.events.jsonl").write_text("")
(rd/"tasks"/"junk.txt").write_text("")
code,out=run(base+[past])
assert code==0 and out=="signal\n",(code,out)      # many changes, ONE line
code,out=run(base+[future])
assert code==0 and out=="",(code,out)              # nothing newer
sys.exit(0)
PY

check "watch --once heartbeat gating and vocabulary" <<PY
$LOAD
import io,contextlib,time
import re as rx
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("github-com-org-repo-deadbeef")
(rd/"tasks").mkdir(parents=True)
def run(argv):
    buf=io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            code=c.main(argv)
    except SystemExit as e:
        code=e.code
    return code,buf.getvalue()
base=["watch","--repo-slug","github-com-org-repo-deadbeef","--once","--since-epoch"]
past=str(time.time()-3600)
(rd/"tasks"/"PROJ-1.json").write_text(json.dumps({"status":"in-progress"}))
(rd/"tasks"/"PROJ-1.done.json").write_text("{}")
code,out=run(base+[past])
assert code==0 and out=="signal\nheartbeat\n",(code,out)
for ln in out.splitlines():
    assert rx.fullmatch(r"signal|heartbeat",ln),ln
(rd/"tasks"/"PROJ-1.json").write_text(json.dumps({"status":"merged"}))
code,out=run(base+[str(time.time()+3600)])
assert code==0 and out=="",(code,out)              # terminal: silent
sys.exit(0)
PY

check "watch invalid args exit 2; missing state root exits 0 silent" <<PY
$LOAD
import io,contextlib
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
def run(argv):
    buf=io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            code=c.main(argv)
    except SystemExit as e:
        code=e.code
    return code,buf.getvalue()
S="github-com-org-repo-deadbeef"
for argv in (
    ["watch","--repo-slug","..","--once","--since-epoch","0"],
    ["watch","--repo-slug",S,"--interval","0"],
    ["watch","--repo-slug",S,"--heartbeat-secs","-5"],
    ["watch","--repo-slug",S,"--debounce-secs","0"],
    ["watch","--repo-slug",S,"--once"],                       # missing since-epoch
    ["watch","--repo-slug",S,"--once","--since-epoch","inf"],
    ["watch","--repo-slug",S,"--once","--since-epoch","-1"],
    ["watch","--repo-slug",S,"--once","--since-epoch","0","--exit-on-signal"],
):
    code,out=run(argv)
    assert code==2 and out=="",(argv,code,out)
code,out=run(["watch","--repo-slug",S,"--once","--since-epoch","0"])
assert code==0 and out=="",(code,out)              # repo dir absent: empty, quiet
sys.exit(0)
PY

check "watch read-only: full state tree unchanged after a run" <<PY
$LOAD
import subprocess,hashlib
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("github-com-org-repo-deadbeef")
(rd/"tasks").mkdir(parents=True); (rd/"workspaces").mkdir(parents=True)
(rd/"tasks"/"PROJ-1.done.json").write_text("{}")
(rd/"tasks"/"PROJ-1.json").write_text(json.dumps({"status":"in-progress"}))
def tree():
    out={}
    for dp,_,fns in os.walk(root):
        for fn in fns:
            p=os.path.join(dp,fn); st=os.stat(p)
            with open(p,"rb") as f:
                h=hashlib.sha256(f.read()).hexdigest()
            out[p]=(st.st_size,st.st_mtime_ns,h)
    return out
before=tree()
r=subprocess.run([sys.executable,"claude/hooks/herdr_orch_core.py","watch",
    "--repo-slug","github-com-org-repo-deadbeef","--once","--since-epoch","0"],
    capture_output=True,env=dict(os.environ))
assert r.returncode==0,r
assert tree()==before
sys.exit(0)
PY

check "watch loop smoke: baseline silent, touch emits one signal" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
S=github-com-org-repo-deadbeef
mkdir -p "$root/herdr-orch/$S/tasks" "$root/herdr-orch/$S/workspaces"
echo '{}' > "$root/herdr-orch/$S/tasks/PROJ-1.done.json"
out="$root/watch.out"
python3 claude/hooks/herdr_orch_core.py watch --repo-slug "$S" \
  --interval 1 --debounce-secs 1 > "$out" &
wpid=$!
trap 'kill $wpid 2>/dev/null || true' EXIT
sleep 2
[ ! -s "$out" ]                                    # pre-existing file: no signal
echo '{"x":1}' > "$root/herdr-orch/$S/tasks/PROJ-1.done.json"
echo junk > "$root/herdr-orch/$S/tasks/notes.txt"  # foreign: never signals
n=0
while [ ! -s "$out" ] && [ "$n" -lt 10 ]; do sleep 1; n=$((n+1)); done
kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
[ "$(cat "$out")" = "signal" ]
SH

check "watch loop --since-epoch seeds baseline; --exit-on-signal exits" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
S=github-com-org-repo-deadbeef
mkdir -p "$root/herdr-orch/$S/tasks"
echo '{}' > "$root/herdr-orch/$S/tasks/PROJ-1.done.json"
out="$root/watch.out"
python3 claude/hooks/herdr_orch_core.py watch --repo-slug "$S" \
  --interval 1 --debounce-secs 1 --exit-on-signal --since-epoch 0 > "$out"
[ "$(cat "$out")" = "signal" ]
SH

check "SKILL.md pins the non-available probe-sample capture bullet" <<'SH'
SKILL="claude/skills/herdr-orchestration/SKILL.md"
rg -q -F 'probe-samples.jsonl' "$SKILL"
rg -q -F 'If `CLS` is not `available`' "$SKILL"
rg -q -F '|| true`' "$SKILL"
SH

check "validate_messaging_socket: canonical dirs, pid basename, /private alias, rejects" <<PY
$LOAD
ok=c.validate_messaging_socket("/tmp/cc-socks/12345.sock")
assert ok==("/tmp/cc-socks/12345.sock",12345,"ok"),ok
assert c.validate_messaging_socket("/private/tmp/cc-socks/12345.sock")==("/tmp/cc-socks/12345.sock",12345,"ok")
assert c.validate_messaging_socket("/tmp/cc-socks-501/7.sock")[2]=="ok"
assert c.validate_messaging_socket("/run/user/1000/cc-socks/7.sock")[2]=="ok"
assert c.validate_messaging_socket("/data/data/com.termux/files/usr/tmp/cc-socks/7.sock")[2]=="ok"
assert c.validate_messaging_socket("/tmp/cc-socks/12345.sock",expect_pid=12345)[2]=="ok"
assert c.validate_messaging_socket("/tmp/cc-socks/12345.sock",expect_pid=1)[2]=="pid-mismatch"
assert c.validate_messaging_socket("")[2]=="empty"
assert c.validate_messaging_socket("cc-socks/1.sock")[2]=="not-absolute"
assert c.validate_messaging_socket("/tmp/other/1.sock")[2]=="dir-not-canonical"
assert c.validate_messaging_socket("/tmp/cc-socks/../cc-socks/1.sock")[2]=="dir-not-canonical"
assert c.validate_messaging_socket("/tmp/cc-socks/12345-0123abcd.sock")[2]=="basename-not-pid-sock"
assert c.validate_messaging_socket("/tmp/cc-socks/abcdef.sock")[2]=="basename-not-pid-sock"
assert c.validate_messaging_socket("/tmp/cc-socks/1.sock/")[2]=="dir-not-canonical"
sys.exit(0)
PY

check "claim-owner stores a valid messaging_socket and takes pid from its basename" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
err=$(mktemp)
F=$($CLI claim-owner --repo-slug slug-ms --session S --host h --pid 999 --messaging-socket /private/tmp/cc-socks/4242.sock 2>"$err")
[ "$F" = 1 ]
grep -q '^\[WARNING\]' "$err"            # --pid 999 differs from basename 4242: one warning
[ "$(grep -c '^\[WARNING\]' "$err")" = 1 ]
python3 - <<PY
import json;o=json.load(open("$root/herdr-orch/slug-ms/owner.json"))
assert o["messaging_socket"]=="/tmp/cc-socks/4242.sock",o
assert o["pid"]==4242,o
PY
SH

check "claim-owner: matching --pid warns nothing; empty value stores null silently; invalid stores null with one warning" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
err=$(mktemp)
$CLI claim-owner --repo-slug slug-a --session S --host h --pid 4242 --messaging-socket /tmp/cc-socks/4242.sock 2>"$err" >/dev/null
[ ! -s "$err" ]
$CLI claim-owner --repo-slug slug-b --session S --host h --pid 5 --messaging-socket "" 2>"$err" >/dev/null
[ ! -s "$err" ]
python3 -c "import json;o=json.load(open('$root/herdr-orch/slug-b/owner.json'));assert o['messaging_socket'] is None and o['pid']==5,o"
$CLI claim-owner --repo-slug slug-c --session S --host h --pid 5 --messaging-socket /tmp/cc-socks/5-0123abcd.sock 2>"$err" >/dev/null
[ "$(grep -c '^\[WARNING\]' "$err")" = 1 ]
python3 -c "import json;o=json.load(open('$root/herdr-orch/slug-c/owner.json'));assert o['messaging_socket'] is None and o['pid']==5,o"
$CLI claim-owner --repo-slug slug-d --session S --host h --pid 5 --messaging-socket /tmp/other/5.sock 2>"$err" >/dev/null
[ "$(grep -c '^\[WARNING\]' "$err")" = 1 ]
python3 -c "import json;o=json.load(open('$root/herdr-orch/slug-d/owner.json'));assert o['messaging_socket'] is None,o"
$CLI claim-owner --repo-slug slug-e --session S --host h --pid 5 2>"$err" >/dev/null   # flag omitted
[ ! -s "$err" ]
python3 -c "import json;o=json.load(open('$root/herdr-orch/slug-e/owner.json'));assert o['messaging_socket'] is None and o['pid']==5,o"
SH

check "refresh-owner: omitted flag keeps socket; empty clears; pid mismatch nulls and warns" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
err=$(mktemp)
F=$($CLI claim-owner --repo-slug slug-r --session S --host h --pid 4242 --messaging-socket /tmp/cc-socks/4242.sock)
O="$root/herdr-orch/slug-r/owner.json"
$CLI refresh-owner --repo-slug slug-r --session S --fence "$F"
python3 -c "import json;o=json.load(open('$O'));assert o['messaging_socket']=='/tmp/cc-socks/4242.sock',o"
$CLI refresh-owner --repo-slug slug-r --session S --fence "$F" --messaging-socket /tmp/cc-socks/9.sock 2>"$err"
[ "$(grep -c '^\[WARNING\]' "$err")" = 1 ]
python3 -c "import json;o=json.load(open('$O'));assert o['messaging_socket'] is None and o['pid']==4242,o"
$CLI refresh-owner --repo-slug slug-r --session S --fence "$F" --messaging-socket /tmp/cc-socks/4242.sock 2>"$err"
python3 -c "import json;o=json.load(open('$O'));assert o['messaging_socket']=='/tmp/cc-socks/4242.sock',o"
$CLI refresh-owner --repo-slug slug-r --session S --fence "$F" --messaging-socket ""
python3 -c "import json;o=json.load(open('$O'));assert o['messaging_socket'] is None,o"
rc=0; $CLI refresh-owner --repo-slug slug-r --session S --fence 99 --messaging-socket /tmp/cc-socks/4242.sock || rc=$?
[ "$rc" = 1 ]        # stale fence still refuses, unchanged
SH

check "legacy owner.json with string pid: refresh migrates it to int; --pid rejects non-integers" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_orch_core.py"
mkdir -p "$root/herdr-orch/slug-l"
python3 -c "import json,time;json.dump({'session_id':'S','host':'h','pid':'4242','heartbeat_ts':time.time(),'fence':1},open('$root/herdr-orch/slug-l/owner.json','w'))"
$CLI refresh-owner --repo-slug slug-l --session S --fence 1 --messaging-socket /tmp/cc-socks/4242.sock
python3 -c "import json;o=json.load(open('$root/herdr-orch/slug-l/owner.json'));assert o['pid']==4242 and o['messaging_socket']=='/tmp/cc-socks/4242.sock',o"
rc=0; $CLI claim-owner --repo-slug slug-m --session S --host h --pid abc >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ]        # argparse type=int rejects cleanly (exit 2), no traceback
SH

check "wake_line shape, nonce uniqueness within one second" <<PY
$LOAD
import json as J
l=c.wake_line("github-com-org-repo-deadbeef","w1","stopped")
assert l.endswith("\n") and l.count("\n")==1
o=J.loads(l)
assert o["type"]=="user" and o["message"]["role"]=="user"
assert re.fullmatch(r"herdr-wake v=1 repo=github-com-org-repo-deadbeef workspace=w1 event=stopped ts=\d+ nonce=[0-9a-f]{8}",o["message"]["content"]),o
l2=c.wake_line("github-com-org-repo-deadbeef","w1","stopped")
assert l!=l2
assert J.loads(c.wake_line("s","w","blocked",ts=5,nonce="deadbeef"))["message"]["content"]=="herdr-wake v=1 repo=s workspace=w event=blocked ts=5 nonce=deadbeef"
sys.exit(0)
PY

check "post_wake sends exactly one wire line to a fake inbox and returns sent" <<PY
$LOAD
import socket,threading,random,shutil,time,json as J
sockdir="/tmp/cc-socks-9%09d"%random.randrange(10**9); os.mkdir(sockdir,0o700)
try:
    path=f"{sockdir}/4242.sock"
    srv=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); srv.bind(path); srv.listen(1)
    got=[]
    def acc():
        conn,_=srv.accept(); buf=b""
        while not buf.endswith(b"\n"):
            d=conn.recv(4096)
            if not d: break
            buf+=d
        got.append(buf); conn.close()
    t=threading.Thread(target=acc,daemon=True); t.start()
    rd=os.path.join(tempfile.mkdtemp(),"github-com-org-repo-deadbeef"); os.mkdir(rd); ws="w1"   # basename must be a valid repo slug
    json.dump({"session_id":"S","host":"h","pid":4242,"heartbeat_ts":time.time(),"fence":1,"messaging_socket":path},open(os.path.join(rd,"owner.json"),"w"))
    r=c.post_wake(rd,ws,"stopped",own_socket=f"{sockdir}/1.sock")
    assert r=="sent",r
    t.join(2); assert got,"server got nothing"
    o=J.loads(got[0]); cnt=o["message"]["content"]
    assert cnt.startswith(f"herdr-wake v=1 repo={os.path.basename(rd)} workspace=w1 event=stopped ts="),cnt
    assert got[0].count(b"\n")==1
finally:
    shutil.rmtree(sockdir,ignore_errors=True)
sys.exit(0)
PY

check "post_wake guards: each bad owner/state returns its reason and sends nothing" <<PY
$LOAD
import socket,random,shutil,time,math
sockdir="/tmp/cc-socks-9%09d"%random.randrange(10**9); os.mkdir(sockdir,0o700)
try:
    path=f"{sockdir}/4242.sock"
    srv=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); srv.bind(path); srv.listen(1); srv.settimeout(0.2)
    rd=os.path.join(tempfile.mkdtemp(),"github-com-org-repo-deadbeef"); os.mkdir(rd); of=os.path.join(rd,"owner.json")
    def owner(**kw):
        o={"session_id":"S","host":"h","pid":4242,"heartbeat_ts":time.time(),"fence":1,"messaging_socket":path}; o.update(kw)
        open(of,"w").write(json.dumps(o))
    def nothing():
        try: srv.accept(); return False
        except socket.timeout: return True
    assert c.post_wake(rd,"w1","stopped")=="no-owner"
    open(of,"w").write("{not json"); assert c.post_wake(rd,"w1","stopped")=="bad-owner"
    owner(messaging_socket=None); assert c.post_wake(rd,"w1","stopped")=="no-socket"
    owner(messaging_socket=""); assert c.post_wake(rd,"w1","stopped")=="no-socket"
    owner(messaging_socket=7); assert c.post_wake(rd,"w1","stopped")=="no-socket"
    for hb in (None,"x",float("nan"),float("inf")):
        owner(heartbeat_ts=hb); assert c.post_wake(rd,"w1","stopped")=="bad-heartbeat",hb
    owner(heartbeat_ts=time.time()-901); assert c.post_wake(rd,"w1","stopped")=="stale-heartbeat"
    owner(heartbeat_ts=time.time()+301); assert c.post_wake(rd,"w1","stopped")=="future-heartbeat"
    owner(heartbeat_ts=time.time()+200); assert c.post_wake(rd,"w1","stopped")=="sent"   # skew allowance
    srv.accept()[0].close()
    owner(pid=None); assert c.post_wake(rd,"w1","stopped")=="bad-pid"
    owner(pid="abc"); assert c.post_wake(rd,"w1","stopped")=="bad-pid"
    owner(pid=True); assert c.post_wake(rd,"w1","stopped")=="bad-pid"
    owner(pid="4242"); assert c.post_wake(rd,"w1","stopped")=="sent"       # legacy digit-string pid tolerated
    srv.accept()[0].close()
    owner(pid=1); assert c.post_wake(rd,"w1","stopped")=="bad-path"          # pid-mismatch -> bad-path
    owner(messaging_socket="/tmp/other/4242.sock"); assert c.post_wake(rd,"w1","stopped")=="bad-path"
    owner(); assert c.post_wake(rd,"w1","stopped",own_socket=path)=="own-socket"
    assert c.post_wake(rd,"w1","stopped",own_socket="/private"+path)=="own-socket"
    owner(); assert c.post_wake(rd,"w1","bogus")=="bad-event"
    assert c.post_wake(rd,"../w1","stopped")=="bad-id"
    assert c.post_wake(os.path.join(tempfile.mkdtemp(),"bad slug"),"w1","stopped")=="bad-id"
    owner(messaging_socket=f"{sockdir}/4245.sock",pid=4245); assert c.post_wake(rd,"w1","stopped")=="not-a-socket"   # path absent
    assert nothing()
    # not a socket: regular file, and a symlink to the real socket
    reg=f"{sockdir}/4243.sock"; open(reg,"w").close(); owner(pid=4243,messaging_socket=reg)
    assert c.post_wake(rd,"w1","stopped")=="not-a-socket"
    ln=f"{sockdir}/4244.sock"; os.symlink(path,ln); owner(pid=4244,messaging_socket=ln)
    assert c.post_wake(rd,"w1","stopped")=="not-a-socket"
    # ownership seams
    owner(); real=c._lstat
    class St:  # minimal stat_result stand-in
        def __init__(s,base,**kw): s.st_mode=base.st_mode; s.st_uid=base.st_uid; s.__dict__.update(kw)
    c._lstat=lambda p: St(real(p),st_uid=real(p).st_uid+1) if p==path else real(p)
    assert c.post_wake(rd,"w1","stopped")=="bad-owner-uid"
    c._lstat=lambda p: St(real(p),st_uid=real(p).st_uid+1) if p==sockdir else real(p)
    assert c.post_wake(rd,"w1","stopped")=="bad-owner-uid"
    c._lstat=lambda p: St(real(p),st_mode=real(p).st_mode|0o077) if p==sockdir else real(p)
    assert c.post_wake(rd,"w1","stopped")=="bad-dir-mode"
    c._lstat=real
    assert nothing()
    # connect refused: socket file with no listener
    srv.close()
    owner(); assert c.post_wake(rd,"w1","stopped")=="connect-failed"
finally:
    shutil.rmtree(sockdir,ignore_errors=True)
sys.exit(0)
PY

check "post_wake returns within 2.5s against a listener that never accepts" <<PY
$LOAD
import socket,random,shutil,time
sockdir="/tmp/cc-socks-9%09d"%random.randrange(10**9); os.mkdir(sockdir,0o700)
try:
    path=f"{sockdir}/4242.sock"
    srv=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); srv.bind(path); srv.listen(1)   # never accept()s
    rd=os.path.join(tempfile.mkdtemp(),"github-com-org-repo-deadbeef"); os.mkdir(rd)
    json.dump({"session_id":"S","host":"h","pid":4242,"heartbeat_ts":time.time(),"fence":1,"messaging_socket":path},open(os.path.join(rd,"owner.json"),"w"))
    t0=time.monotonic(); r=c.post_wake(rd,"w1","stopped"); dt=time.monotonic()-t0
    assert r in ("sent","send-failed","connect-failed"),r     # AF_UNIX queues the connect and a short send; this is a budget smoke test, not a blocked-send simulation
    assert dt<2.5,dt
    # socket creation failure is caught, not raised
    real_socket=c.socket.socket
    def nosock(*a,**k): raise OSError("emfile")
    c.socket.socket=nosock
    try:
        assert c.post_wake(rd,"w1","stopped")=="connect-failed"
    finally:
        c.socket.socket=real_socket
finally:
    shutil.rmtree(sockdir,ignore_errors=True)
sys.exit(0)
PY

check "hook end to end: Stop appends stopped AND posts one wake; no socket -> append only" <<PY
$LOAD
import socket,threading,random,shutil,time,io,json as J
hs=importlib.util.spec_from_file_location("hook","claude/hooks/herdr_worker_status.py")
h=importlib.util.module_from_spec(hs); hs.loader.exec_module(h)
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
os.environ["HERDR_ENV"]="1"; os.environ["HERDR_WORKSPACE_ID"]="w1"; os.environ.pop("CLAUDE_CODE_MESSAGING_SOCKET",None)
slug="github-com-org-repo-deadbeef"; rd=os.path.join(root,"herdr-orch",slug)
os.makedirs(os.path.join(rd,"workspaces")); os.makedirs(os.path.join(rd,"tasks"))
json.dump({"task_id":"PROJ-1","repo_slug":slug,"role":"impl"},open(os.path.join(rd,"workspaces","w1.json"),"w"))
sockdir="/tmp/cc-socks-9%09d"%random.randrange(10**9); os.mkdir(sockdir,0o700)
try:
    path=f"{sockdir}/4242.sock"
    srv=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); srv.bind(path); srv.listen(4); srv.settimeout(2)
    got=[]
    def acc():
        while True:
            try: conn,_=srv.accept()
            except (socket.timeout,OSError): return
            buf=b""
            while not buf.endswith(b"\n"):
                d=conn.recv(4096)
                if not d: break
                buf+=d
            got.append(buf); conn.close()
    threading.Thread(target=acc,daemon=True).start()
    def run(payload):
        sys.stdin=io.StringIO(json.dumps(payload)); return h.main()
    def wait_got(n,secs=2.0):   # bounded poll instead of fixed sleeps
        end=time.monotonic()+secs
        while len(got)<n and time.monotonic()<end: time.sleep(0.02)
        time.sleep(0.1)          # settle: catch an unexpected extra message
        return len(got)
    ev=os.path.join(rd,"workspaces","w1.events.jsonl")
    def events(): return open(ev).read().count("\n")
    # 1. no messaging_socket in owner: append only, exit 0
    json.dump({"session_id":"S","host":"h","pid":4242,"heartbeat_ts":time.time(),"fence":1,"messaging_socket":None},open(os.path.join(rd,"owner.json"),"w"))
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(1,0.3)==0 and events()==1
    # 2. socket registered: append + one post
    json.dump({"session_id":"S","host":"h","pid":4242,"heartbeat_ts":time.time(),"fence":1,"messaging_socket":path},open(os.path.join(rd,"owner.json"),"w"))
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(1)==1,got
    assert "event=stopped" in J.loads(got[0])["message"]["content"]
    assert events()==2
    # 3. own socket equals target: append, no post
    os.environ["CLAUDE_CODE_MESSAGING_SOCKET"]=path
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(2,0.3)==1 and events()==3
    os.environ.pop("CLAUDE_CODE_MESSAGING_SOCKET")
    # 4. blocking notification posts blocked; non-blocking posts nothing and appends nothing
    assert run({"hook_event_name":"Notification","notification_type":"permission_prompt"})==0
    assert wait_got(2)==2 and "event=blocked" in J.loads(got[1])["message"]["content"]
    assert run({"hook_event_name":"Notification","notification_type":"idle_prompt"})==0
    assert wait_got(3,0.3)==2 and events()==4
    # 5. review role posts review-stopped
    json.dump({"task_id":"PROJ-1","repo_slug":slug,"role":"review"},open(os.path.join(rd,"workspaces","w1.json"),"w"))
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(3)==3 and "event=review-stopped" in J.loads(got[2])["message"]["content"]
    # 6. append_event raising still posts
    core=h.core; real_append=core.append_event
    def boom(*a,**k): raise RuntimeError("disk")
    core.append_event=boom
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(4)==4,got
    core.append_event=real_append
    # 6b. post_wake raising still appends exactly one event and exits 0
    real_post=core.post_wake; core.post_wake=boom
    before=events()
    assert run({"hook_event_name":"Stop"})==0
    assert events()==before+1 and wait_got(5,0.3)==4
    core.post_wake=real_post
    # 7. server gone: exit 0 within 2.5s
    srv.close(); os.unlink(path)
    t0=time.monotonic(); assert run({"hook_event_name":"Stop"})==0; assert time.monotonic()-t0<2.5
finally:
    shutil.rmtree(sockdir,ignore_errors=True)
sys.exit(0)
PY

check "validate_contract accepts v1 and rejects each violation" <<PY
$LOAD
ok={"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}
assert c.validate_contract(ok,"PROJ-1") is None
assert c.validate_contract(ok,"PROJ-2") is not None          # task_id mismatch
assert c.validate_contract({**ok,"v":True},"PROJ-1") is not None   # bool v
assert c.validate_contract({**ok,"v":2},"PROJ-1") is not None
assert c.validate_contract({**ok,"extra":1},"PROJ-1") is not None  # unknown key
assert c.validate_contract({**ok,"commands":[]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","x":1}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":" ","run":"true"}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":""}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true"},{"name":"t","run":"true"}]},"PROJ-1") is not None  # dup name
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","timeout_secs":True}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","timeout_secs":0}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","timeout_secs":3601}]},"PROJ-1") is not None
assert c.validate_contract({**ok,"commands":[{"name":"t","run":"true","timeout_secs":3600}]},"PROJ-1") is None
big=[{"name":"t%d"%i,"run":"true"} for i in range(33)]
assert c.validate_contract({**ok,"commands":big},"PROJ-1") is not None  # >32
assert c.validate_contract([],"PROJ-1") is not None          # non-dict
sys.exit(0)
PY

check "contract_sha256 hashes file bytes" <<PY
$LOAD
import hashlib
root=tempfile.mkdtemp()
p=os.path.join(root,"c.json");open(p,"w").write("{}")
assert c.contract_sha256(p)==hashlib.sha256(b"{}").hexdigest()
sys.exit(0)
PY

check "run_contract_commands: pass, first-failure stop, timeout killpg" <<PY
$LOAD
import time
root=tempfile.mkdtemp()
cmds=[{"name":"a","run":"true"},{"name":"b","run":"true"}]
assert c.run_contract_commands(cmds,root)==0
marker=os.path.join(root,"ran")
cmds=[{"name":"a","run":"false"},{"name":"b","run":"touch "+marker}]
assert c.run_contract_commands(cmds,root)==1
assert not os.path.exists(marker)                 # stopped at first failure
cmds=[{"name":"slow","run":"sleep 30","timeout_secs":1}]
t0=time.time()
assert c.run_contract_commands(cmds,root)==1
assert time.time()-t0 < 10                        # killed, not waited out
cmds=[{"name":"cwd","run":"touch ran"}]
assert c.run_contract_commands(cmds,root)==0 and os.path.exists(marker)  # cwd=worktree
sys.exit(0)
PY

check "verify-contract: unpinned validate/run/missing/schema exits" <<'SH'
ROOT=$(mktemp -d); export CLAUDE_CONFIG_DIR="$ROOT"
CLI="python3 claude/hooks/herdr_orch_core.py"
WT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}' > "$WT/c.json"
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract c.json --allow-unpinned --validate-only | grep -qE '^[0-9a-f]{64}$'
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract c.json --allow-unpinned
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract missing.json --allow-unpinned 2>/dev/null; [ $? -eq 3 ] || exit 1
printf '{"v":1,"task_id":"WRONG","commands":[{"name":"t","run":"true"}]}' > "$WT/bad.json"
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract bad.json --allow-unpinned 2>/dev/null; [ $? -eq 2 ] || exit 1
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"false"}]}' > "$WT/f.json"
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract f.json --allow-unpinned 2>/dev/null; [ $? -eq 1 ] || exit 1
exit 0
SH

check "verify-contract: pinned mode enforces pin, hash, path match" <<'SH'
ROOT=$(mktemp -d); export CLAUDE_CONFIG_DIR="$ROOT"
CLI="python3 claude/hooks/herdr_orch_core.py"
WT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}' > "$WT/c.json"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"in-progress"}'
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" 2>/dev/null
[ $? -eq 5 ] || exit 1                                                              # no pin
set -e
SHA=$(python3 -c "import hashlib;print(hashlib.sha256(open('$WT/c.json','rb').read()).hexdigest())")
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"in-progress","contract_path":"c.json","contract_sha256":"'"$SHA"'"}'
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT"           # pass
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract other.json 2>/dev/null; [ $? -eq 2 ] || exit 1                         # path mismatch
MARKER="$WT/tampered-ran"
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"touch tampered-ran"}]}' > "$WT/c.json"
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" 2>/dev/null
[ $? -eq 4 ] || exit 1                                                              # tamper
[ ! -f "$MARKER" ] || exit 1                                                        # never ran
exit 0
SH

check "verify-contract: pinned validate-only prints hash, runs nothing; corrupt record exits 2" <<'SH'
ROOT=$(mktemp -d); export CLAUDE_CONFIG_DIR="$ROOT"
CLI="python3 claude/hooks/herdr_orch_core.py"
WT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"touch vo-ran"}]}' > "$WT/c.json"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
SHA=$(python3 -c "import hashlib;print(hashlib.sha256(open('$WT/c.json','rb').read()).hexdigest())")
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","contract_path":"c.json","contract_sha256":"'"$SHA"'"}'
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --validate-only | grep -qE '^[0-9a-f]{64}$'
[ ! -f "$WT/vo-ran" ]                                       # validate-only never executed
printf 'not-json' > "$ROOT/herdr-orch/slug-x/tasks/PROJ-1.json"
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" 2>/dev/null
[ $? -eq 2 ] || exit 1                                      # corrupt record: integrity, not grandfather
exit 0
SH

check "verify-contract: rejects escape paths and symlinked contracts" <<'SH'
ROOT=$(mktemp -d); export CLAUDE_CONFIG_DIR="$ROOT"
CLI="python3 claude/hooks/herdr_orch_core.py"
WT=$(mktemp -d); OUT=$(mktemp -d)
printf '{"v":1,"task_id":"PROJ-1","commands":[{"name":"t","run":"true"}]}' > "$OUT/c.json"
ln -s "$OUT/c.json" "$WT/link.json"
set +e
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract ../escape.json --allow-unpinned 2>/dev/null; [ $? -eq 2 ] || exit 1
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --contract link.json --allow-unpinned 2>/dev/null; [ $? -eq 2 ] || exit 1
$CLI verify-contract --repo-slug slug-x --task-id PROJ-1 --worktree "$WT" \
  --allow-unpinned 2>/dev/null; [ $? -eq 2 ] || exit 1   # --allow-unpinned needs --contract
exit 0
SH

check "mech role: haiku-first defaults, haiku only legal in mech, 4-alias capabilities" <<PY
$LOAD
assert c.CAP_MODELS==("fable","opus","sonnet","haiku")
assert c.role_preference("mech",{})==("haiku","sonnet")
assert c.role_preference("mech",{"models":{"mech":["sonnet","haiku"]}})==("sonnet","haiku")
for r in ("plan","impl","review"):
    assert c.role_preference(r,{"models":{r:["haiku"]}}) is None, r
assert c.role_preference("plan",{"models":{"mech":["haiku"]}})==("fable","opus")  # sibling override does not taint
ok3={"v":1,"session_id":"S","available":{"fable":True,"opus":True,"sonnet":True}}
assert not c.valid_capabilities(ok3,"S")                      # old 3-alias map is stale
ok4=dict(ok3,available=dict(ok3["available"],haiku=True))
assert c.valid_capabilities(ok4,"S")
assert c.resolve_model("mech",{"fable":False,"opus":True,"sonnet":True,"haiku":True},{})==("haiku",None)
assert c.resolve_model("mech",{"fable":False,"opus":True,"sonnet":True,"haiku":False},{})==("sonnet",None)
assert c.resolve_model("mech",{"fable":False,"opus":True,"sonnet":False,"haiku":False},{})==(None,4)
assert c.resolve_model("mech",{"fable":True,"opus":True,"sonnet":True,"haiku":True},{"models":{"mech":["gpt"]}})==(None,5)
sys.exit(0)
PY

check "resolve-model/disable-model CLI accept the mech role and haiku alias" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
F=$($CLI claim-owner --repo-slug slug-m --session S --host h --pid 1)
! $CLI write-capabilities --repo-slug slug-m --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true}}' 2>/dev/null
$CLI write-capabilities --repo-slug slug-m --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
[ "$($CLI resolve-model --repo-slug slug-m --role mech --session S)" = haiku ]
$CLI disable-model --repo-slug slug-m --session S --fence "$F" --model haiku
[ "$($CLI resolve-model --repo-slug slug-m --role mech --session S)" = sonnet ]
[ "$($CLI resolve-model --repo-slug slug-m --role plan --session S)" = opus ]   # other roles unaffected
SH

check "mech_caps: defaults, config merge, overrides, fail-closed validation" <<PY
$LOAD
caps,err=c.mech_caps({})
assert err is None and caps=={"max_turns":40,"max_budget_usd":2.0,"timeout_secs":1800},caps
caps,err=c.mech_caps({"mech":{"max_turns":60,"max_budget_usd":3}})
assert err is None and caps["max_turns"]==60 and caps["max_budget_usd"]==3 and caps["timeout_secs"]==1800
caps,err=c.mech_caps({"mech":{"max_turns":60}},max_turns=10,max_budget_usd=0.5)
assert err is None and caps["max_turns"]==10 and caps["max_budget_usd"]==0.5
bad=[{"mech":{"max_turns":0}},{"mech":{"max_turns":501}},{"mech":{"max_budget_usd":0}},
     {"mech":{"max_budget_usd":50.01}},{"mech":{"timeout_secs":59}},{"mech":{"max_turns":True}},
     {"mech":{"bogus":1}},{"mech":[]},{"mech":{"max_budget_usd":float("inf")}},
     {"mech":{"contract_commands":[]}},{"mech":{"contract_commands":[{"name":"a","run":"true","x":1}]}}]
for b in bad:
    caps,err=c.mech_caps(b); assert caps is None and err, b
caps,err=c.mech_caps({},max_turns=0); assert caps is None
caps,err=c.mech_caps({},max_budget_usd=51); assert caps is None
good={"mech":{"contract_commands":[{"name":"t","run":"true","timeout_secs":5}]}}
assert c.mech_caps(good)[1] is None
assert c.mech_contract(good,"td-x")=={"v":1,"task_id":"td-x","commands":[{"name":"t","run":"true","timeout_secs":5}]}
assert c.mech_contract({},"td-x") is None
sys.exit(0)
PY

check "mech-caps / mech-contract CLI" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-c"; mkdir -p "$RD"
out=$($CLI mech-caps --repo-slug slug-c)
[ "$out" = '{"max_turns": 40, "max_budget_usd": 2.0, "timeout_secs": 1800}' ]
printf '{"v":1,"user":"u","default_base":"origin/main","mech":{"max_turns":60,"contract_commands":[{"name":"t","run":"true"}]}}' > "$RD/config.json"
out=$($CLI mech-caps --repo-slug slug-c --max-budget-usd 1.5)
[ "$out" = '{"max_turns": 60, "max_budget_usd": 1.5, "timeout_secs": 1800}' ]
rc=0; $CLI mech-caps --repo-slug slug-c --max-turns 999 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
B=$(git -C "$WT" rev-parse HEAD)
touch "$WT/dirty"
rc=0; $CLI mech-contract --repo-slug slug-c --task-id td-x --worktree "$WT" --base-sha "$B" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$WT/claude/contracts/td-x-contract.json" ]                                             # dirty -> nothing written
rm "$WT/dirty"
rc=0; $CLI mech-contract --repo-slug slug-c --task-id td-x --worktree "$WT" --base-sha "$(printf %040d 1)" 2>/dev/null || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$WT/claude/contracts/td-x-contract.json" ]                                             # diverged -> nothing written
rel=$($CLI mech-contract --repo-slug slug-c --task-id td-x --worktree "$WT" --base-sha "$B")
[ "$rel" = claude/contracts/td-x-contract.json ]
python3 -c "import json;d=json.load(open('$WT/$rel'));assert d=={'v':1,'task_id':'td-x','commands':[{'name':'t','run':'true'}]},d"
git -C "$WT" add "$rel"; git -C "$WT" -c user.name=t -c user.email=t@x commit -q -m c; B2=$(git -C "$WT" rev-parse HEAD)
rc=0; $CLI mech-contract --repo-slug slug-c --task-id td-x --worktree "$WT" --base-sha "$B2" 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]   # exists
printf '{"v":1,"user":"u","default_base":"origin/main"}' > "$RD/config.json"
rc=0; $CLI mech-contract --repo-slug slug-c --task-id td-y --worktree "$WT" --base-sha "$B2" 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]   # no template
SH

check "emit-done: optional launch_id and reason round-trip; bad reason rejected" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
$CLI emit-done --repo-slug slug-e --task-id td-x --workspace w1 --agent mech-td-x --phase implement \
  --outcome paused --head-sha h1 --base-sha b0 --launch-id mech-td-x-20260901T000000Z --reason needs_design
python3 -c "import json;d=json.load(open('$CLAUDE_CONFIG_DIR/herdr-orch/slug-e/tasks/td-x.done.json'));assert d['launch_id']=='mech-td-x-20260901T000000Z' and d['reason']=='needs_design',d"
$CLI emit-done --repo-slug slug-e --task-id td-x --workspace w1 --agent impl-td-x --phase implement \
  --outcome completed --head-sha h1 --base-sha b0
python3 -c "import json;d=json.load(open('$CLAUDE_CONFIG_DIR/herdr-orch/slug-e/tasks/td-x.done.json'));assert 'launch_id' not in d and 'reason' not in d,d"
rc=0; $CLI emit-done --repo-slug slug-e --task-id td-x --workspace w1 --agent impl-td-x --phase implement \
  --outcome paused --head-sha h1 --base-sha b0 --reason tired 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
SH

check "agent_name mech prefix obeys canonical constraints" <<PY
$LOAD
n=c.agent_name("mech","td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical")
assert n.startswith("mech-") and len(n)<=32 and re.fullmatch(r"mech-[a-z0-9-]{1,27}",n),n
assert c.agent_name("mech","TD-1",existing={"mech-td-1"})=="mech-td-1-2"
assert c.MECH_REASONS==("max_turns","max_budget","timeout","no_emit","error","needs_design","blocked_on_human","other")
sys.exit(0)
PY

check "fold_spend: exact AC6 fixture" <<PY
$LOAD
L=[
 '{"v":1,"kind":"start","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"L1","ts":"t"}',
 '{"v":1,"kind":"end","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"L1","num_turns":17,"total_cost_usd":0.42,"ts":"t"}',
 '{"v":1,"kind":"start","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"L2","ts":"t"}',
 '{"v":1,"kind":"end","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"L2","num_turns":3,"total_cost_usd":null,"ts":"t"}',
 '{"v":1,"kind":"end","task_id":"td-x","launch_id":"L3","num_tur',
 '{"v":1,"kind":"end","task_id":"td-other","launch_id":"L4","num_turns":1,"total_cost_usd":9.0,"ts":"t"}',
 '{"v":1,"kind":"end","task_id":"td-x","launch_id":"L5","num_turns":1,"total_cost_usd":true,"ts":"t"}',
]
assert c.fold_spend(L,"td-x")=={"usd":0.42,"turns":20,"launches":2,"unknown_cost_launches":1,"skipped_lines":3}
assert c.fold_spend([],"td-x")=={"usd":0.0,"turns":0,"launches":0,"unknown_cost_launches":0,"skipped_lines":0}
assert not c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","num_turns":-1},"td-x")
assert not c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","total_cost_usd":float("nan")},"td-x")
assert not c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","num_turns":2.5},"td-x")
assert not c.valid_spend_line({"v":True,"kind":"end","task_id":"td-x","launch_id":"L"},"td-x")
assert not c.valid_spend_line({"v":1,"kind":"mid","task_id":"td-x","launch_id":"L"},"td-x")
assert not c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","num_turns":1},"td-x")   # total_cost_usd key required
assert c.valid_spend_line({"v":1,"kind":"end","task_id":"td-x","launch_id":"L","num_turns":None,"total_cost_usd":None,"subtype":"weird"},"td-x")
assert (".spend.jsonl", c.valid_task_id) in c.WATCH_DIRS["tasks"]
sys.exit(0)
PY

check "status: per-task spend, _totals with untracked_launches, _orphans" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_orch_core.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-s"; mkdir -p "$RD/tasks" "$RD/workspaces"
F=$($CLI claim-owner --repo-slug slug-s --session S --host h --pid 1)
$CLI write-task --repo-slug slug-s --task-id td-a --session S --fence "$F" \
  --json '{"task_id":"td-a","status":"in-progress","workers":[{"role":"mech","launch_id":"L1"},{"role":"impl"}]}'
$CLI write-task --repo-slug slug-s --task-id td-b --session S --fence "$F" \
  --json '{"task_id":"td-b","status":"in-progress","workers":[{"role":"review"}]}'
printf '%s\n' '{"v":1,"kind":"start","task_id":"td-a","launch_id":"L1","ts":"t"}' \
  '{"v":1,"kind":"end","task_id":"td-a","launch_id":"L1","num_turns":17,"total_cost_usd":0.42,"ts":"t"}' > "$RD/tasks/td-a.spend.jsonl"
printf '{"v":1,"kind":"start","task_id":"td-z","launch_id":"L9","ts":"t"}\n' > "$RD/tasks/td-z.spend.jsonl"
$CLI status --repo-slug slug-s | python3 -c '
import json,sys; s=json.load(sys.stdin)
assert s["td-a"]["spend"]=={"usd":0.42,"turns":17,"launches":1,"unknown_cost_launches":0,"skipped_lines":0},s
assert s["td-b"]["spend"]["launches"]==0 and s["td-b"]["spend"]["usd"]==0.0
assert s["_totals"]=={"usd":0.42,"turns":17,"launches":1,"unknown_cost_launches":0,"skipped_lines":0,"untracked_launches":2},s
assert s["_orphans"]==["td-z"],s
'
SH

check "run-mech helpers: agent validity, result parsing, downgrade, errors, provenance, outcome" <<PY
$LOAD
t="td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical"
base=c.agent_name("mech",t)
assert c.valid_mech_agent(base,t) and c.valid_mech_agent(c.agent_name("mech",t,existing={base}),t)
assert c.valid_mech_agent("mech-td-r-9","td-r") and not c.valid_mech_agent("mech-td-r-10","td-r")
assert not c.valid_mech_agent("mech-other","td-r") and not c.valid_mech_agent("mech-","td-r") and not c.valid_mech_agent("mech-Td-r","td-r")
assert not c.valid_mech_agent("impl-td-r","td-r")
r=c.parse_claude_result('noise\n{"type":"result","subtype":"success","num_turns":2}\n')
assert r and r["num_turns"]==2
assert c.parse_claude_result("not json") is None and c.parse_claude_result('{"type":"other"}') is None
assert c.models_used({"modelUsage":{"claude-haiku-4-5-20251001":{},"claude-sonnet-5":{}}})==["claude-haiku-4-5-20251001","claude-sonnet-5"]
assert c.models_used({}) == [] and c.models_used(None) == []
assert c.is_downgrade(["claude-sonnet-5"],"haiku") and not c.is_downgrade(["claude-haiku-4-5-20251001"],"haiku") and not c.is_downgrade([],"haiku")
assert c.result_errors({"errors":["a","b"*1000,3]})==["a","b"*500]
assert c.result_errors({}) == [] and c.result_errors({"errors":"x"}) == []
assert c.model_attributable("success",True,[],"haiku")
assert c.model_attributable("error_during_execution",False,["haiku is not available"],"haiku")
assert c.model_attributable("error_during_execution",False,["Unknown model"],"haiku")
assert not c.model_attributable("error_during_execution",False,["network timeout"],"haiku")
assert not c.model_attributable("error_max_turns",False,["model x"],"haiku")
d={"workspace_id":"w1","agent":"mech-td-r","launch_id":"L1","ts":"2026-09-01T00:00:01Z"}
assert c.own_launch_record(d,"w1","mech-td-r","L1","2026-09-01T00:00:00Z")
assert not c.own_launch_record(d,"w1","mech-td-r","L2","2026-09-01T00:00:00Z")
assert not c.own_launch_record(dict(d,agent="impl-td-r"),"w1","mech-td-r","L1","2026-09-01T00:00:00Z")
old={"workspace_id":"w1","agent":"mech-td-r","ts":"2026-08-01T00:00:00Z"}
assert not c.own_launch_record(old,"w1","mech-td-r","L1","2026-09-01T00:00:00Z")
assert c.own_launch_record(dict(old,ts="2026-09-01T00:00:00Z"),"w1","mech-td-r","L1","2026-09-01T00:00:00Z")
assert not c.own_launch_record(None,"w1","mech-td-r","L1","t")
assert c.wrapper_outcome("error_max_turns","h","b",False)==("paused","max_turns")
assert c.wrapper_outcome("error_max_budget_usd","h","b",False)==("paused","max_budget")
assert c.wrapper_outcome("timeout","h","b",False)==("paused","timeout")
assert c.wrapper_outcome("success","h","b",False)==("paused","no_emit")
assert c.wrapper_outcome("error_during_execution","h","b",False)==("paused","error")
assert c.wrapper_outcome("error_during_execution","b","b",False)==("failed","error")
assert c.wrapper_outcome("error_during_execution","h","b",True)==("failed","error")
assert c.wrapper_outcome("unparseable",None,"b",True)==("failed","error")
assert c.SHELL_SAFE_RE.match("a/b+c:d@e.f_g-1") and not c.SHELL_SAFE_RE.match("a b") and not c.SHELL_SAFE_RE.match("a;b") and not c.SHELL_SAFE_RE.match("")
assert c.SHA40_RE.match("0"*40) and not c.SHA40_RE.match("abc") and not c.SHA40_RE.match("A"*40)
sys.exit(0)
PY

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
