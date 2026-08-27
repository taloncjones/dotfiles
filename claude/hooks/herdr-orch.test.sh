#!/bin/sh
# herdr-orch.test.sh - unit + integration tests for the herdr-orchestration
# core module and worker-status hook. Stdlib python only; no network, no herdr.
set -e
PASS=0
FAIL=0

# check LABEL  -- runs a python snippet on stdin; exit 0 pass / non-0 fail.
check() {
    label="$1"
    if python3 - ; then printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else printf 'FAIL  %s\n' "$label" >&2; FAIL=$((FAIL + 1)); fi
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
