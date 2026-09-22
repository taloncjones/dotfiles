#!/bin/sh
# herdr-orch.test.sh - unit + integration tests for the herdr-orchestration
# core module and worker-status hook. Stdlib python only; no network, no herdr.
set -e
# Self-unset the account selectors, as the runner and the guard suite do.
# Without this a DIRECT `sh claude/hooks/herdr-orch.test.sh` inherits the
# shell's selector, account_scope ignores each fixture's CLAUDE_CONFIG_DIR, and
# the suite reports ~105 phantom failures -- which is exactly what a round-3
# reviewer hit, spending much of its pass chasing an environmental artifact.
# Fixing this in bin/dotfiles-tests alone left the trap set for anyone running
# a single suite, which is how most people run one.
unset WORKFLOW_PERSONAL_ACCOUNT HERDR_PERSONAL CLAUDE_PERSONAL_ONLY
unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR CODEX_HOME XDG_STATE_HOME
# Use physical macOS temp paths so strict no-follow state traversal is tested.
#
# Derived from the SAME source `mktemp -d` uses, which is not $TMPDIR. BSD
# mktemp with no template ignores $TMPDIR entirely and always uses the
# per-user dir, while Python's gettempdir() honours it. Setting TMPDIR from
# Python therefore made the two disagree whenever the caller exported anything
# else: the fixture's containment check then found no match, SILENTLY seeded
# nothing, and this suite went from 242/0 to 152/90 with every failure reading
# "gate record absent" -- indistinguishable from a real regression in lead
# admission. getconf is what mktemp consults, so they cannot diverge.
# Realpath'd, because the physical path is what makes the no-follow traversal
# above meaningful: /var is a symlink to /private/var. Both sides resolve, so
# the physical form still agrees with what mktemp returns.
TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || TMPDIR=""
[ -n "$TMPDIR" ] || TMPDIR=$(mktemp -d -u 2>/dev/null | sed 's:/[^/]*$::')
[ -n "$TMPDIR" ] || TMPDIR=/tmp
TMPDIR=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMPDIR")
export TMPDIR
PASS=0
FAIL=0

# check LABEL  -- runs a python (<<PY, body starts with the $LOAD "import"
# line) or shell (<<'SH', body starts with a shell assignment) snippet on
# stdin; exit 0 pass / non-0 fail.
check() {
    label="$1"
    HERDR_COORDINATION_ROOT=$(mktemp -d); export HERDR_COORDINATION_ROOT
    # Per-check stderr capture, inside the throwaway root. The bodies used to
    # redirect to a bare `err`, which resolves against the cwd -- the repo
    # root -- so every local run littered the checkout, and one such file was
    # committed by a blanket `git add -A`. Its content is a test's stderr,
    # which another failure could make carry a temp path or an account id.
    ERRFILE="$HERDR_COORDINATION_ROOT/err"; export ERRFILE
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
c=importlib.util.module_from_spec(spec);spec.loader.exec_module(c)
from herdr_legacy_fixture import claim_legacy_owner'

# Fake claude for run-mech checks, built once and reached via exported
# FAKE_CLAUDE_DIR (shell functions do not survive into `sh -e -` snippets).
# It records argv/cwd/stdin/pid under $FAKE_CLAUDE_LOG.*, runs the shell
# snippet in $FAKE_CLAUDE_HOOK (e.g. a simulated worker emit-done), sleeps
# $FAKE_CLAUDE_SLEEP secs, prints the JSON file $FAKE_CLAUDE_JSON, exits
# $FAKE_CLAUDE_RC (default 0).
FAKE_CLAUDE_DIR=$(mktemp -d); export FAKE_CLAUDE_DIR
cat > "$FAKE_CLAUDE_DIR/claude" <<'EOF'
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
chmod +x "$FAKE_CLAUDE_DIR/claude"

# Lead-tier checks now run workspace_provenance_ok unconditionally (issue-binding
# and a lead claim-owner both require --repo-path), so they need a real git
# repository with a fake origin remote and a linked worktree rather than a bare
# mktemp directory. Each check body is a fresh `sh -e -` process (not sourced),
# so this helper is a file every affected check sources with `.`; call
# lead_fixture with a unique origin URL to get a fresh LF_REPO/LF_SLUG/LF_WS.
LEAD_FIXTURE_HELPER=$(mktemp); export LEAD_FIXTURE_HELPER
cat > "$LEAD_FIXTURE_HELPER" <<'HELPER'
lead_fixture() {
    LF_REPO=$(mktemp -d)
    git -C "$LF_REPO" init -q
    git -C "$LF_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
    git -C "$LF_REPO" remote add origin "$1"
    LF_SLUG=$(python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as c
print(c.repo_slug(sys.argv[1]))
' "$1")
    LF_WSBASE=$(mktemp -d)
    LF_WS="$LF_WSBASE/wt"
    git -C "$LF_REPO" worktree add -q "$LF_WS"
}
HELPER

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
f1=claim_legacy_owner(rd,"A","h",1);assert f1==1 and c.check_fence(rd,"A",f1)
assert claim_legacy_owner(rd,"B","h",2) is None            # fresh owner: busy
f2=claim_legacy_owner(rd,"B","h",2,stale_secs=0);assert f2==2   # stale: takeover
assert not c.check_fence(rd,"A",f1) and c.check_fence(rd,"B",f2)
assert c.refresh_owner(rd,"B",f2) and not c.refresh_owner(rd,"A",f1)
sys.exit(0)
PY

check "ownership: persistent flock survives an old mtime without unlinking" <<PY
$LOAD
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-lock");rd.mkdir(parents=True)
f1=claim_legacy_owner(rd,"OLD","h",1);assert f1==1
o=json.loads(c.coordination.owner_path(rd).read_text());o["heartbeat_ts"]=0
c.coordination.owner_path(rd).write_text(json.dumps(o))            # stale the stored owner
lock=c.coordination.coordination_root()/".owner.lock"
lock.write_text("")                                     # simulate a SIGKILLed holder's leaked lock
os.utime(lock,(0,0))                                    # ancient mtime: no unlink ever ran
f2=claim_legacy_owner(rd,"NEW","h",2,stale_secs=1)
assert f2 is not None, "stale lock permanently wedged claim_owner"
assert c.check_fence(rd,"NEW",f2)
assert lock.exists()                                    # inode persists across every transaction
sys.exit(0)
PY

check "ownership: concurrent stale takeover yields exactly one winner" <<PY
$LOAD
import subprocess, textwrap
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-abc");rd.mkdir(parents=True)
claim_legacy_owner(rd,"OLD","h",1)                          # existing owner
o=json.loads(c.coordination.owner_path(rd).read_text());o["heartbeat_ts"]=0
c.coordination.owner_path(rd).write_text(json.dumps(o))            # stale the stored heartbeat field
prog=textwrap.dedent('''
import importlib.util,os,sys
s=importlib.util.spec_from_file_location("core","claude/hooks/herdr_orch_core.py")
c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
from herdr_legacy_fixture import claim_legacy_owner
rd=c.repo_dir("slug-abc")
f=claim_legacy_owner(rd,sys.argv[1],"h",int(sys.argv[1][1:] or 0)+1,stale_secs=1)
print("WIN" if f else "LOSE")
''')
env=dict(os.environ)
procs=[subprocess.Popen([sys.executable,"-c",prog,f"s{i}"],stdout=subprocess.PIPE,env=env) for i in range(6)]
outs=[p.communicate()[0].decode().strip() for p in procs]
# with a lock, some LOSE on contention and retry-eligible; but the owner file
# must name exactly one session and check_fence must hold for only that one.
owner=__import__("json").loads(c.coordination.owner_path(rd).read_text())
wins=outs.count("WIN")
assert wins>=1
assert c.check_fence(rd,owner["session_id"],owner["fence"])
sys.exit(0)
PY

check "ownership: concurrent FIRST-ever claim never yields a lost fence" <<PY
$LOAD
import subprocess, textwrap
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-fresh");rd.mkdir(parents=True)
with c.coordination.owner_transaction(rd, canonical_id="fixture", expected_slug="slug-fresh"):
    pass                                                # explicit identity permits first claim
prog=textwrap.dedent('''
import importlib.util,os,sys
s=importlib.util.spec_from_file_location("core","claude/hooks/herdr_orch_core.py")
c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
from herdr_legacy_fixture import claim_legacy_owner
rd=c.repo_dir("slug-fresh")
f=c.claim_owner(rd,sys.argv[1],"h",int(sys.argv[1][1:] or 0)+1)
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

CLI="python3 claude/hooks/herdr_legacy_fixture.py"

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
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
  --repo-slug "../evil" --task-id "PROJ-1" --workspace w1 --agent a --phase implement \
  --outcome completed --head-sha h --base-sha b 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
  --repo-slug "slug-x" --task-id "../evil" --workspace w1 --agent a --phase implement \
  --outcome completed --head-sha h --base-sha b 2>/dev/null; then exit 1; fi
test ! -e "$root/../evil"
SH

check "CLI write-task requires a live fence" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-x --session S --host h --pid 1)
task='{"task_id":"PROJ-1","base_sha":"b0","status":"in-progress"}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence "$f" --json "$task"
test -f "$root/herdr-orch/slug-x/tasks/PROJ-1.json"
# wrong fence is refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence 999 --json "$task" 2>/dev/null; then exit 1; fi
SH

check "CLI write-task rejects non-dict json and task_id mismatch" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-x --session S --host h --pid 1)
# a bare array would persist and later crash `status` on .get -> must be refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence "$f" --json '[]' 2>/dev/null; then exit 1; fi
# a dict whose task_id disagrees with --task-id is refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence "$f" --json '{"task_id":"PROJ-2"}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/slug-x/tasks/PROJ-1.json"
# the matching record persists
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-x --task-id PROJ-1 --session S --fence "$f" --json '{"task_id":"PROJ-1","status":"kickoff"}'
test -f "$root/herdr-orch/slug-x/tasks/PROJ-1.json"
SH

check "write-task resolver: carry-forward, [] on first write, new-row rule only" <<PY
$LOAD
import pathlib
ABSENT = c.PRIOR_ABSENT
CORRUPT = c.PRIOR_CORRUPT
rows = [{"role": "impl", "phase": "implement"}]

# First write with no workers key resolves to [].
assert c.resolve_task_workers({"task_id": "T"}, ABSENT, False) == []

# An explicit list is returned as given.
assert c.resolve_task_workers({"task_id": "T", "workers": rows}, ABSENT, False) == rows

# With a prior record present, an omitted key carries the prior list forward.
prior = {"task_id": "T", "workers": rows}
assert c.resolve_task_workers({"task_id": "T"}, prior, False) == rows

# Only rows NEW in this write face the row rule. A bound record holding a
# legacy (non-native) row stays writable: carrying it forward is accepted, and
# so is appending a native successor after it. Validating inherited rows would
# leave such a record unwritable by every payload.
legacy = {"task_id": "T", "workers": [{"phase": "implement"}]}
native_row = {
    "role": "impl", "launch_id": "L1", "phase": "implement", "runtime": "claude",
    "workspace_id": "w1", "pane_id": "p1", "source_head_sha": "a" * 40,
}
assert c.resolve_task_workers({"task_id": "T"}, legacy, True) == legacy["workers"]
appended = legacy["workers"] + [native_row]
assert c.resolve_task_workers(
    {"task_id": "T", "workers": appended}, legacy, True) == appended

# Forward-only still holds: a NEW non-native row on the bound path is refused
# even when the inherited prefix is itself legacy.
try:
    c.resolve_task_workers(
        {"task_id": "T", "workers": legacy["workers"] + [{"phase": "implement"}]},
        legacy, True)
    raise AssertionError("a new non-native bound row must be refused")
except SystemExit as exc:
    assert exc.code == 2, exc.code

# On the UNBOUND path an explicit list is accepted without consulting prior, so
# a corrupt record is repairable. Omitting the key there refuses instead.
assert c.resolve_task_workers({"task_id": "T", "workers": []}, CORRUPT, False) == []
try:
    c.resolve_task_workers({"task_id": "T"}, CORRUPT, False)
    raise AssertionError("corrupt prior with omitted workers must refuse")
except SystemExit as exc:
    assert exc.code == 2, exc.code

# On the BOUND path that repair does NOT exist: the malformed-prior check
# refuses before the append-only comparison is ever reached. Pinned so the
# limitation is asserted rather than implied.
for payload in ({"task_id": "T", "workers": []},
                {"task_id": "T", "workers": [native_row]}):
    try:
        c.resolve_task_workers(payload, CORRUPT, True)
        raise AssertionError("bound corrupt prior must not be repairable")
    except SystemExit as exc:
        assert exc.code == 2, exc.code

# The append-only comparison lives in the resolver, so substituting a row at an
# inherited index is refused by the function itself rather than only by its
# caller -- otherwise index 0 would be assumed inherited and face no rule.
# Assert WHICH guard fires: every _require exits 2, so a bare code check would
# still pass if some earlier check started firing instead.
import contextlib, io
for label, payload in (
    ("substituted prefix row", {"task_id": "T", "workers": [{"bad": 1}, native_row]}),
    ("truncated history", {"task_id": "T", "workers": []}),
):
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            c.resolve_task_workers(payload, legacy, True)
        raise AssertionError(label + " must be refused")
    except SystemExit as exc:
        assert exc.code == 2, exc.code
    assert "append-only" in err.getvalue(), (label, err.getvalue())

# The prefix persisted is the RECORD's own rows, not the caller's copy: '=='
# holds between 1 and True, so an accepted prefix could otherwise change type.
# Asserted as a CONTRAST, because an equality against the True row would hold
# either way. Keep backticks out of this block: the heredoc is unquoted, so
# the shell would run backticked text as a command substitution.
typed = {"task_id": "T", "workers": [{"phase": "implement", "flag": 1}]}
supplied = {"task_id": "T", "workers": [{"phase": "implement", "flag": True}]}
# Unbound keeps the caller's rows (same count, so no shrink), bool unchanged.
kept = c.resolve_task_workers(supplied, typed, False)
assert isinstance(kept[0]["flag"], bool), kept
# Bound inherits the record's own row, so the stored int survives.
bound_kept = c.resolve_task_workers(supplied, typed, True)
assert not isinstance(bound_kept[0]["flag"], bool), bound_kept
assert bound_kept[0]["flag"] == 1, bound_kept

# The transaction re-assertion in read_prior_task is the half of the R2-F1 fix
# that stops an unbound repair overwriting an intact record. Pin both branches:
# a failing transaction must propagate, never become a record sentinel.
class _StubTxn:
    def __init__(self, exc):
        self.exc = exc

    def assert_current(self):
        raise self.exc

_dest = pathlib.Path(tempfile.mkdtemp()) / "T.json"
_dest.write_text(json.dumps({"task_id": "T", "workers": []}))
for _exc in (ValueError("payload directory was replaced"),
             FileNotFoundError(2, "No such file or directory")):
    c.coordination._LOCAL.transaction = _StubTxn(_exc)
    try:
        got = c.read_prior_task(_dest)
        raise AssertionError(
            f"a failing transaction must propagate, got {got!r}")
    except (ValueError, OSError):
        pass
    finally:
        c.coordination._LOCAL.transaction = None
# With no transaction set the asserts are no-ops and the record reads normally.
assert c.read_prior_task(_dest) == {"task_id": "T", "workers": []}

# RecursionError is a RuntimeError, so it needs its own clause. This Python's
# C-accelerated decoder never raises it, so stub the read: a real deeply nested
# fixture would not exercise the branch, and narrowing the tuple back would
# otherwise pass green.
_real_read = c.read_payload_text
def _deep_read(path):
    raise RecursionError("maximum recursion depth exceeded")

c.read_payload_text = _deep_read
try:
    assert c.read_prior_task(_dest) is c.PRIOR_CORRUPT
    # A stale transaction still wins over the corrupt classification.
    c.coordination._LOCAL.transaction = _StubTxn(ValueError("replaced"))
    try:
        c.read_prior_task(_dest)
        raise AssertionError("a stale transaction must propagate")
    except ValueError:
        pass
    finally:
        c.coordination._LOCAL.transaction = None
finally:
    c.read_payload_text = _real_read

# Row rule on a first write: unbound needs a phase key, bound the full tuple.
loose = [{"role": "review"}]
phased = [{"role": "review", "phase": "review"}]
native = [{
    "role": "review", "launch_id": "L1", "phase": "review", "runtime": "claude",
    "workspace_id": "w1", "pane_id": "p1", "source_head_sha": "a" * 40,
}]
for rows_in, bound, ok in (
    (loose, False, False), (phased, False, True), (native, False, True),
    (phased, True, False), (native, True, True), ([], True, True),
    ("nope", False, False),
):
    try:
        c.resolve_task_workers({"task_id": "T", "workers": rows_in}, ABSENT, bound)
        assert ok, (rows_in, bound)
    except SystemExit as exc:
        assert not ok, (rows_in, bound)
        assert exc.code == 2, exc.code
PY

check "CLI write-index rejects a non-dict payload (would orphan the workspace)" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-x --session S --host h --pid 1)
# a bare array reads back as None from read_index -> events silently orphaned; must be refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-index \
   --repo-slug slug-x --workspace w1 --session S --fence "$f" --json '[]' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/slug-x/workspaces/w1.json"
# a well-formed object persists
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-index \
   --repo-slug slug-x --workspace w1 --session S --fence "$f" --json '{"task_id":"PROJ-1","role":"impl"}'
test -f "$root/herdr-orch/slug-x/workspaces/w1.json"
SH

check "CLI confirm-review: dispatched==reviewed==HEAD+workspace+no-blocking passes; else fails" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-x --session S --host h --pid 1)
$CLI write-task --repo-slug slug-x --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"reviewed","review_head_sha":"h1"}'
$CLI emit-review --repo-slug slug-x --task-id PROJ-1 --workspace w9 --agent rev-proj-1 \
  --reviewed-head-sha h1 --outcome approved
# the sidecar sorts after PROJ-1.json; status must still report the real status
$CLI status --repo-slug slug-x | python3 -c "import json,sys;s=json.load(sys.stdin);assert list(s)==['PROJ-1','_totals','_orphans','_think'] and s['PROJ-1']['status']=='reviewed',s"
SH

check "CLI should-dispatch-review: once per HEAD, re-review on new HEAD" <<'SH'
root=$(mktemp -d); export CLAUDE_CONFIG_DIR="$root"
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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

check "wake_decision: three consecutive Stops with no record change push zero wakes" <<PY
$LOAD
m = {"v": 1, "records": {"/t/d.json": [5, 9]}, "last_push": {"stopped": 100.0}}
fp = {"/t/d.json": [5, 9]}
pushes = []
for t in (200.0, 300.0, 400.0):
    p, m = c.wake_decision(m, "stopped", fp, "stopped", t)
    pushes.append(p)
assert pushes == [False, False, False], pushes
PY

check "wake_decision: a Stop after a done.json write pushes exactly one wake" <<PY
$LOAD
m = {"v": 1, "records": {}, "last_push": {}}
fp = {"/t/d.json": [5, 9]}
p1, m = c.wake_decision(m, "stopped", fp, "stopped", 1000.0)
p2, m = c.wake_decision(m, "stopped", fp, "stopped", 2000.0)
assert (p1, p2) == (True, False), (p1, p2)
assert m["last_push"]["stopped"] == 1000.0, m
PY

check "wake_decision: a blocking Notification pushes once per transition into blocked" <<PY
$LOAD
m = {"v": 1, "records": {}, "last_push": {}}
p1, m = c.wake_decision(m, "blocked", {}, "stopped", 1000.0)
p2, m = c.wake_decision(m, "blocked", {}, "blocked", 1001.0)
p3, m = c.wake_decision(m, "blocked", {}, "blocked", 99000.0)
assert (p1, p2, p3) == (True, False, False), (p1, p2, p3)
PY

check "wake_decision: a debounced record change fires on the next Stop" <<PY
$LOAD
m = {"v": 1, "records": {"/t/d.json": [1, 1]}, "last_push": {"stopped": 1000.0}}
fp = {"/t/d.json": [2, 2]}
p1, m = c.wake_decision(m, "stopped", fp, "stopped", 1010.0)
assert p1 is False, "inside the debounce window"
assert m["records"] == {"/t/d.json": [1, 1]}, "suppression must not advance the fingerprint"
p2, m = c.wake_decision(m, "stopped", fp, "stopped", 1100.0)
assert p2 is True and m["records"] == fp, (p2, m)
PY

check "wake_decision: a deleted completion record pushes no wake" <<PY
$LOAD
m = {"v": 1, "records": {"/t/d.json": [5, 9]}, "last_push": {}}
p, m2 = c.wake_decision(m, "stopped", {}, "stopped", 9000.0)
assert p is False, "a vanished record must never signal"
assert m2["records"] == {"/t/d.json": [5, 9]}, m2
PY

check "wake_decision: a corrupt marker reads as empty and biases toward pushing" <<PY
$LOAD
p, m = c.wake_decision({"garbage": 1}, "stopped", {"/t/d.json": [5, 9]}, "stopped", 9000.0)
assert p is True and m["records"] == {"/t/d.json": [5, 9]}, (p, m)
p2, m2 = c.wake_decision("not-a-dict", "stopped", {"/t/d.json": [5, 9]}, None, 9000.0)
assert p2 is True, p2
PY

check "record_fingerprint: only the task's own two sidecars, absent paths omitted" <<PY
$LOAD
rd = tempfile.mkdtemp()
os.makedirs(os.path.join(rd, "tasks"))
open(os.path.join(rd, "tasks", "PROJ-1.done.json"), "w").write("{}")
open(os.path.join(rd, "tasks", "PROJ-2.done.json"), "w").write("{}")
fp = c.record_fingerprint(rd, "PROJ-1")
assert list(fp) == [os.path.join(rd, "tasks", "PROJ-1.done.json")], fp
assert all(isinstance(v, list) and len(v) == 2 for v in fp.values()), fp
assert c.record_fingerprint(rd, "../escape") == {}, "unsafe task id must yield nothing"
PY

check "prior_hint: the last event, and None when the tail names another task" <<PY
$LOAD
rd = tempfile.mkdtemp()
os.makedirs(os.path.join(rd, "workspaces"))
p = os.path.join(rd, "workspaces", "w1.events.jsonl")
with open(p, "w") as fh:
    fh.write(json.dumps({"v": 1, "ts": "t", "workspace_id": "w1", "event": "stopped", "task_id": "PROJ-1"}) + "\n")
    fh.write(json.dumps({"v": 1, "ts": "t", "workspace_id": "w1", "event": "blocked", "task_id": "PROJ-1"}) + "\n")
assert c.prior_hint(rd, "w1", "PROJ-1") == "blocked"
assert c.prior_hint(rd, "w1", "PROJ-2") is None, "a rebound workspace must reset the transition"
assert c.prior_hint(rd, "w9", "PROJ-1") is None, "no log means no prior hint"
PY

# args: label  ws-or-REGISTER  HERDR_ENV  payload  expect(event|none)
# args: label  ws-or-REGISTER  HERDR_ENV  payload  expect(event|none)  [expect_push(push|nopush)]
hook_case() {
    label="$1"; env_ws="$2"; henv="$3"; payload="$4"; expect="$5"; expect_push="${6:-}"
    outdir=$(mktemp -d); wsdir="$outdir/herdr-orch/slug-x/workspaces"; mkdir -p "$wsdir"
    if [ "$env_ws" = "REGISTER" ]; then
        printf '{"task_id":"PROJ-1","repo_slug":"slug-x","role":"impl"}' > "$wsdir/w1.json"; ws="w1"
    elif [ "$env_ws" = "REGISTER_REVIEW" ]; then
        printf '{"task_id":"PROJ-1","repo_slug":"slug-x","role":"review"}' > "$wsdir/w9.json"; ws="w9"
    elif [ "$env_ws" = "REGISTER_BAD_TASK" ]; then
        printf '{"task_id":"../escape","repo_slug":"slug-x","role":"impl"}' > "$wsdir/w1.json"; ws="w1"
    else ws="$env_ws"; fi
    printf '%s' "$payload" | env CLAUDE_CONFIG_DIR="$outdir" HERDR_ENV="$henv" \
        HERDR_WORKSPACE_ID="$ws" claude/hooks/herdr_worker_status.py >/dev/null 2>&1
    got=$(tail -1 "$wsdir/$ws.events.jsonl" 2>/dev/null) || true
    ok=1
    if [ "$expect" = "none" ]; then
        [ -z "$got" ] || ok=0
    else
        printf '%s' "$got" | grep -q "\"event\":\"$expect\"" || ok=0
    fi
    if [ -n "$expect_push" ]; then
        marker=$(cat "$wsdir/$ws.wake.json" 2>/dev/null || echo '{}')
        case "$expect_push" in
            push) printf '%s' "$marker" | grep -q "\"$expect\":" || ok=0 ;;
            nopush) printf '%s' "$marker" | grep -q "\"$expect\":" && ok=0 ;;
        esac
    fi
    if [ "$ok" = "1" ]; then printf 'PASS  %s\n' "$label"; PASS=$((PASS+1));
    else printf 'FAIL  %s (want %s/%s got %s)\n' "$label" "$expect" "$expect_push" "$got" >&2; FAIL=$((FAIL+1)); fi
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
hook_case "hook: three consecutive Stops with no record change push zero wakes" REGISTER "1" '{"hook_event_name":"Stop"}' stopped nopush
hook_case "hook: an unsafe task_id in the index is a no-op" REGISTER_BAD_TASK "1" '{"hook_event_name":"Stop"}' none

check "hook: a Stop after a done.json write pushes exactly one wake" <<PY
$LOAD
import subprocess
outdir = tempfile.mkdtemp()
rd = os.path.join(outdir, "herdr-orch", "slug-x")
os.makedirs(os.path.join(rd, "workspaces")); os.makedirs(os.path.join(rd, "tasks"))
open(os.path.join(rd, "workspaces", "w1.json"), "w").write(
    json.dumps({"task_id": "PROJ-1", "repo_slug": "slug-x", "role": "impl"}))
env = dict(os.environ, CLAUDE_CONFIG_DIR=outdir, HERDR_ENV="1", HERDR_WORKSPACE_ID="w1")
def run():
    return subprocess.run(["claude/hooks/herdr_worker_status.py"],
                          input=b'{"hook_event_name":"Stop"}', env=env, capture_output=True)
run(); run(); run()
marker = json.load(open(os.path.join(rd, "workspaces", "w1.wake.json")))
assert "stopped" not in marker["last_push"], marker
open(os.path.join(rd, "tasks", "PROJ-1.done.json"), "w").write('{"outcome":"completed"}')
run()
marker = json.load(open(os.path.join(rd, "workspaces", "w1.wake.json")))
assert "stopped" in marker["last_push"], "a record write must push"
PY

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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
assert names==["PROJ-1.done.json","PROJ-1.review.json"],names
assert failed==set()
for v in snap.values():
    assert isinstance(v,tuple) and len(v)==2
sys.exit(0)
PY

check "watch no longer signals on an events.jsonl append" <<PY
$LOAD
assert "workspaces" not in c.WATCH_DIRS, sorted(c.WATCH_DIRS)
assert set(c.WATCH_DIRS) == {"tasks", "think"}, sorted(c.WATCH_DIRS)
rd = tempfile.mkdtemp()
os.makedirs(os.path.join(rd, "tasks")); os.makedirs(os.path.join(rd, "workspaces"))
prev, _f = c.watch_scan(rd, {})
with open(os.path.join(rd, "workspaces", "w1.events.jsonl"), "a") as fh:
    fh.write('{"v":1,"event":"stopped"}\n')
snap, _f = c.watch_scan(rd, prev)
assert not c.watch_changed(prev, snap), "an events.jsonl append must not signal"
open(os.path.join(rd, "tasks", "PROJ-1.done.json"), "w").write("{}")
snap2, _f = c.watch_scan(rd, snap)
assert c.watch_changed(snap, snap2), "a done.json write must still signal"
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
python3 claude/hooks/herdr_legacy_fixture.py watch --repo-slug "$S" \
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
python3 claude/hooks/herdr_legacy_fixture.py watch --repo-slug "$S" \
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
stop=threading.Event(); idle=threading.Event(); listener=None; srv=None
try:
    path=f"{sockdir}/4242.sock"
    srv=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); srv.bind(path); srv.listen(4); srv.settimeout(0.1)
    got=[]
    def acc():
        while not stop.is_set():
            try: conn,_=srv.accept()
            except socket.timeout:
                idle.set()
                continue
            except OSError: return
            buf=b""
            while not buf.endswith(b"\n"):
                d=conn.recv(4096)
                if not d: break
                buf+=d
            got.append(buf); conn.close()
    listener=threading.Thread(target=acc,daemon=True); listener.start()
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
    # 2. socket registered: append, no post without a record change
    json.dump({"session_id":"S","host":"h","pid":4242,"heartbeat_ts":time.time(),"fence":1,"messaging_socket":path},open(os.path.join(rd,"owner.json"),"w"))
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(1,0.3)==0,got
    assert events()==2
    # 3. own socket equals target: still no record change, so still no post
    os.environ["CLAUDE_CODE_MESSAGING_SOCKET"]=path
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(1,0.3)==0 and events()==3
    os.environ.pop("CLAUDE_CODE_MESSAGING_SOCKET")
    # An idle accept timeout must not expire the fixture before the next wake.
    idle.clear(); assert idle.wait(2) and listener.is_alive()
    # 4. a transition into blocked posts regardless of any record; non-blocking posts nothing and appends nothing
    assert run({"hook_event_name":"Notification","notification_type":"permission_prompt"})==0
    assert wait_got(1)==1,got
    assert "event=blocked" in J.loads(got[0])["message"]["content"]
    assert run({"hook_event_name":"Notification","notification_type":"idle_prompt"})==0
    assert wait_got(2,0.3)==1 and events()==4
    # 5. review role appends review-stopped, but still no record -> still no post
    json.dump({"task_id":"PROJ-1","repo_slug":slug,"role":"review"},open(os.path.join(rd,"workspaces","w1.json"),"w"))
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(2,0.3)==1 and events()==5
    # 6. a completion record is what earns the wake; a failed append must not suppress it
    open(os.path.join(rd,"tasks","PROJ-1.done.json"),"w").write('{"outcome":"completed"}')
    core=h.core; real_append=core.append_event
    def boom(*a,**k): raise RuntimeError("disk")
    core.append_event=boom
    events_before=events()
    assert run({"hook_event_name":"Stop"})==0
    assert wait_got(2)==2,got
    assert events()==events_before   # the raise swallowed the audit line
    core.append_event=real_append
    # 6b. post_wake raising still appends; no NEW record change means no new push
    real_post=core.post_wake; core.post_wake=boom
    before=events()
    assert run({"hook_event_name":"Stop"})==0
    assert events()==before+1 and wait_got(3,0.3)==2
    core.post_wake=real_post
    # 7. server gone: exit 0 within 2.5s
    stop.set(); srv.close(); os.unlink(path)
    t0=time.monotonic(); assert run({"hook_event_name":"Stop"})==0; assert time.monotonic()-t0<2.5
finally:
    stop.set()
    if srv is not None: srv.close()
    if listener is not None:
        listener.join(2)
        assert not listener.is_alive(), "fake inbox listener did not stop"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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

check "think_caps: defaults, merge, overrides, fail-closed; mech_caps unchanged" <<PY
$LOAD
caps,err=c.think_caps({})
assert err is None and caps=={"max_turns":15,"max_budget_usd":3.0,"timeout_secs":900,"daily_budget_usd":10.0},caps
caps,err=c.think_caps({"think":{"max_turns":20,"daily_budget_usd":25}},max_budget_usd=4.5)
assert err is None and caps["max_turns"]==20 and caps["max_budget_usd"]==4.5 and caps["daily_budget_usd"]==25
bad=[{"think":{"max_turns":0}},{"think":{"bogus":1}},{"think":{"max_turns":True}},{"think":[]},
     {"think":{"contract_commands":[{"name":"a","run":"true"}]}},{"think":{"daily_budget_usd":0}},
     {"think":{"daily_budget_usd":200.5}},{"think":{"daily_budget_usd":True}},
     {"think":{"max_budget_usd":12,"daily_budget_usd":10}},{"think":{"daily_budget_usd":float("nan")}}]
for b in bad:
    caps,err=c.think_caps(b); assert caps is None and err, b
caps,err=c.think_caps({},max_budget_usd=11); assert caps is None       # override above daily ceiling
assert c.mech_caps({})==({"max_turns":40,"max_budget_usd":2.0,"timeout_secs":1800},None)
caps,err=c.mech_caps({"mech":{"daily_budget_usd":5}}); assert caps is None  # not a mech key
sys.exit(0)
PY

check "think-caps CLI" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-t"; mkdir -p "$RD"
[ "$($CLI think-caps --repo-slug slug-t)" = '{"max_turns": 15, "max_budget_usd": 3.0, "timeout_secs": 900, "daily_budget_usd": 10.0}' ]
printf '{"v":1,"user":"u","default_base":"origin/main","think":{"timeout_secs":600}}' > "$RD/config.json"
[ "$($CLI think-caps --repo-slug slug-t --max-turns 5)" = '{"max_turns": 5, "max_budget_usd": 3.0, "timeout_secs": 600, "daily_budget_usd": 10.0}' ]
rc=0; $CLI think-caps --repo-slug slug-t --max-budget-usd 60 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]
SH

check "emit-done: optional launch_id and reason round-trip; bad reason rejected" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
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
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-s"; mkdir -p "$RD/tasks" "$RD/workspaces"
F=$($CLI claim-owner --repo-slug slug-s --session S --host h --pid 1)
$CLI write-task --repo-slug slug-s --task-id td-a --session S --fence "$F" \
  --json '{"task_id":"td-a","status":"in-progress","workers":[{"role":"mech","launch_id":"L1","phase":"implement"},{"role":"impl","phase":"implement"}]}'
$CLI write-task --repo-slug slug-s --task-id td-b --session S --fence "$F" \
  --json '{"task_id":"td-b","status":"in-progress","workers":[{"role":"review","phase":"review"}]}'
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

check "run-mech: success with fresh worker record; argv/stdin/cwd exact; ledger start+end" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d); PATH="$FAKE_CLAUDE_DIR:$PATH"; L=$(mktemp -d)
export FAKE_CLAUDE_LOG="$L/log"; export FAKE_CLAUDE_JSON="$L/res.json"; unset FAKE_CLAUDE_HOOK FAKE_CLAUDE_SLEEP FAKE_CLAUDE_RC
CLI="python3 $PWD/claude/hooks/herdr_orch_core.py"; RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-r"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q -b main; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base; BASE=$(git -C "$WT" rev-parse HEAD)
printf 'do the thing\n' > "$RD/tasks/td-r.brief.md"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":5,"total_cost_usd":0.11,"duration_ms":10,"session_id":"sid","modelUsage":{"claude-haiku-4-5-20251001":{}}}' > "$FAKE_CLAUDE_JSON"
export FAKE_CLAUDE_HOOK="git -C $WT -c user.name=t -c user.email=t@x commit -q --allow-empty -m work; $CLI emit-done --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --phase implement --outcome completed --head-sha \$(git -C $WT rev-parse HEAD) --base-sha $BASE --launch-id mech-td-r-20260901T000000Z"
$CLI run-mech --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --launch-id mech-td-r-20260901T000000Z \
  --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$RD/tasks/td-r.brief.md" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60
[ "$(tr '\n' ' ' < $FAKE_CLAUDE_LOG.argv)" = "--model haiku --permission-mode auto --name mech-td-r -p --output-format json --max-turns 7 --max-budget-usd 0.5 " ]
[ "$(cat $FAKE_CLAUDE_LOG.stdin)" = "do the thing" ]
[ "$(cd "$WT" && pwd -P)" = "$(cd "$(cat $FAKE_CLAUDE_LOG.cwd)" && pwd -P)" ]
python3 - <<PY
import json
L=[json.loads(l) for l in open("$RD/tasks/td-r.spend.jsonl")]
assert [l["kind"] for l in L]==["start","end"],L
assert L[0]["max_turns"]==7 and L[0]["max_budget_usd"]==0.5 and L[0]["model"]=="haiku" and L[0]["launch_id"]=="mech-td-r-20260901T000000Z"
e=L[1]; assert e["subtype"]=="success" and e["total_cost_usd"]==0.11 and e["num_turns"]==5 and e["downgrade"] is False and e["record_written_by"]=="worker" and e["models_used"]==["claude-haiku-4-5-20251001"] and e["errors"]==[] and e["model_attributable"] is False,e
d=json.load(open("$RD/tasks/td-r.done.json")); assert d["outcome"]=="completed" and "reason" not in d,d
PY
SH

check "run-mech --effort passes the flag and records it; absent -> null and argv unchanged" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-me"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
BASE=$(git -C "$WT" rev-parse HEAD); printf 'brief\n' > "$RD/tasks/td-me.brief.md"
export PATH="$FAKE_CLAUDE_DIR:$PATH" FAKE_CLAUDE_LOG="$RD/log" FAKE_CLAUDE_JSON="$RD/res.json"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.1,"modelUsage":{"claude-haiku-4-5-20251001":{}}}' > "$FAKE_CLAUDE_JSON"
base="$CLI run-mech --repo-slug slug-me --task-id td-me --workspace w1 --agent mech-td-me --model haiku --worktree $WT --base-sha $BASE --brief-file $RD/tasks/td-me.brief.md --max-turns 5 --max-budget-usd 0.5 --timeout-secs 60"
$base --launch-id mech-td-me-1 --effort high
grep -qx -- '--effort' "$FAKE_CLAUDE_LOG.argv" && grep -qx -- 'high' "$FAKE_CLAUDE_LOG.argv"
python3 -c "import json;l=[json.loads(x) for x in open('$RD/tasks/td-me.spend.jsonl')];assert l[0]['kind']=='start' and l[0]['effort']=='high',l"
$base --launch-id mech-td-me-2
! grep -qx -- '--effort' "$FAKE_CLAUDE_LOG.argv"
python3 -c "import json;l=[json.loads(x) for x in open('$RD/tasks/td-me.spend.jsonl')];assert l[2]['kind']=='start' and l[2]['effort'] is None,l"
rc=0; $base --launch-id mech-td-me-3 --effort turbo 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
rc=0; $base --launch-id mech-td-me-4 --effort inherit 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
[ "$(wc -l < "$RD/tasks/td-me.spend.jsonl")" -eq 4 ]
SH

check "run-mech: cap hits, no_emit, errors, dirty, unparseable, downgrade, errors persisted -> wrapper records" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d); PATH="$FAKE_CLAUDE_DIR:$PATH"; L=$(mktemp -d)
export FAKE_CLAUDE_LOG="$L/log"; export FAKE_CLAUDE_JSON="$L/res.json"; unset FAKE_CLAUDE_HOOK FAKE_CLAUDE_SLEEP FAKE_CLAUDE_RC
CLI="python3 $PWD/claude/hooks/herdr_orch_core.py"; RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-r"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q -b main; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base; BASE=$(git -C "$WT" rev-parse HEAD)
: > "$RD/tasks/b.md"
run() { $CLI run-mech --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --launch-id "mech-td-r-$1" \
  --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$RD/tasks/b.md" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60; }
expect() { python3 -c "import json;d=json.load(open('$RD/tasks/td-r.done.json'));assert (d['outcome'],d['reason'],d['launch_id'])==('$1','$2','mech-td-r-$3'),d"; }
last() { python3 -c "import json,sys;L=[json.loads(l) for l in open('$RD/tasks/td-r.spend.jsonl')];e=L[-1];assert e['kind']=='end';$1"; }
printf '{"type":"result","subtype":"error_max_turns","is_error":true,"num_turns":7,"total_cost_usd":0.2}' > "$FAKE_CLAUDE_JSON"; run 1; expect paused max_turns 1
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":3,"total_cost_usd":0.5}' > "$FAKE_CLAUDE_JSON"; run 2; expect paused max_budget 2
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.01}' > "$FAKE_CLAUDE_JSON"; run 3; expect paused no_emit 3
printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"total_cost_usd":0.01,"errors":["network timeout"]}' > "$FAKE_CLAUDE_JSON"; run 4; expect failed error 4   # HEAD == base
last "assert e['errors']==['network timeout'] and e['model_attributable'] is False,e"
printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"total_cost_usd":0.01,"errors":["Unknown model: haiku"]}' > "$FAKE_CLAUDE_JSON"; run 5
last "assert e['model_attributable'] is True,e"
git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m work; run 6; expect paused error 6              # ahead + clean
touch "$WT/dirty"; run 7; expect failed error 7                                                                            # ahead + dirty
rm "$WT/dirty"; git -C "$WT" checkout -q --detach "$BASE"; git -C "$WT" checkout -q -B main
printf 'not json' > "$FAKE_CLAUDE_JSON"; run 8; expect failed error 8
last "assert e['subtype']=='unparseable' and e['total_cost_usd'] is None and e['num_turns'] is None,e"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.01,"modelUsage":{"claude-sonnet-5":{}}}' > "$FAKE_CLAUDE_JSON"; run 9
last "assert e['downgrade'] is True and e['models_used']==['claude-sonnet-5'] and e['model_attributable'] is True,e"
# stale record from another launch is replaced; a live-launch record survives a cap hit
export FAKE_CLAUDE_HOOK="$CLI emit-done --repo-slug slug-r --task-id td-r --workspace w1 --agent mech-td-r --phase implement --outcome completed --head-sha $BASE --base-sha $BASE --launch-id mech-td-r-10"
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":2,"total_cost_usd":0.5}' > "$FAKE_CLAUDE_JSON"; run 10
python3 -c "import json;d=json.load(open('$RD/tasks/td-r.done.json'));assert d['outcome']=='completed' and d['launch_id']=='mech-td-r-10',d"
unset FAKE_CLAUDE_HOOK; run 11; expect paused max_budget 11
python3 -c "import json;L=[json.loads(l) for l in open('$RD/tasks/td-r.spend.jsonl')];assert len([l for l in L if l['kind']=='start'])==11 and L[-1]['record_written_by']=='wrapper',len(L)"
SH

check "run-mech: timeout kills the child process (import seam, 2s wall clock)" <<PY
$LOAD
import types, subprocess as sp, time
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-r"); (rd/"tasks").mkdir(parents=True)
wt=tempfile.mkdtemp(); sp.run(["git","-C",wt,"init","-q","-b","main"],check=True)
sp.run(["git","-C",wt,"-c","user.name=t","-c","user.email=t@x","commit","-q","--allow-empty","-m","b"],check=True)
base=sp.run(["git","-C",wt,"rev-parse","HEAD"],capture_output=True,text=True,check=True).stdout.strip()
log=tempfile.mkdtemp()+"/log"; res=tempfile.mkdtemp()+"/res.json"; open(res,"w").write('{"type":"result","subtype":"success"}')
os.environ.update(FAKE_CLAUDE_LOG=log,FAKE_CLAUDE_JSON=res,FAKE_CLAUDE_SLEEP="30"); os.environ.pop("FAKE_CLAUDE_HOOK",None)
os.environ["PATH"]=os.environ["FAKE_CLAUDE_DIR"]+":"+os.environ["PATH"]
a=types.SimpleNamespace(repo_slug="slug-r",task_id="td-r",workspace="w1",agent="mech-td-r",launch_id="mech-td-r-1",
  model="haiku",worktree=wt,base_sha=base,brief_file="unused",max_turns=7,max_budget_usd=0.5,timeout_secs=60)
t0=time.time(); rc=c.run_mech(rd,a,"brief text",2); assert rc==0 and time.time()-t0<10
d=json.load(open(rd/"tasks"/"td-r.done.json")); assert (d["outcome"],d["reason"])==("paused","timeout"),d
L=[json.loads(l) for l in open(rd/"tasks"/"td-r.spend.jsonl")]; assert L[-1]["subtype"]=="timeout",L
pid=int(open(log+".pid").read())
try:
    os.kill(pid,0); alive=True
except ProcessLookupError:
    alive=False
assert not alive, "fake claude survived the kill"
sys.exit(0)
PY

check "run-mech: git failure after start and unwritable done target both exit 3 with the end line appended" <<PY
$LOAD
import types, subprocess as sp
root=tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-r"); (rd/"tasks").mkdir(parents=True)
wt=tempfile.mkdtemp(); sp.run(["git","-C",wt,"init","-q","-b","main"],check=True)
sp.run(["git","-C",wt,"-c","user.name=t","-c","user.email=t@x","commit","-q","--allow-empty","-m","b"],check=True)
base=sp.run(["git","-C",wt,"rev-parse","HEAD"],capture_output=True,text=True,check=True).stdout.strip()
log=tempfile.mkdtemp()+"/log"; res=tempfile.mkdtemp()+"/res.json"; open(res,"w").write('{"type":"result","subtype":"success"}')
os.environ.update(FAKE_CLAUDE_LOG=log,FAKE_CLAUDE_JSON=res); os.environ.pop("FAKE_CLAUDE_HOOK",None); os.environ.pop("FAKE_CLAUDE_SLEEP",None)
os.environ["PATH"]=os.environ["FAKE_CLAUDE_DIR"]+":"+os.environ["PATH"]
mk=lambda lid: types.SimpleNamespace(repo_slug="slug-r",task_id="td-r",workspace="w1",agent="mech-td-r",launch_id=lid,
  model="haiku",worktree=wt,base_sha=base,brief_file="unused",max_turns=7,max_budget_usd=0.5,timeout_secs=60)
# (1) unwritable completion record: a directory sits where the file must go
(rd/"tasks"/"td-r.done.json").mkdir()
assert c.run_mech(rd,mk("mech-td-r-1"),"x",60)==3
L=[json.loads(l) for l in open(rd/"tasks"/"td-r.spend.jsonl")]
assert [l["kind"] for l in L]==["start","end"] and L[-1]["record_written_by"]=="none",L
os.rmdir(rd/"tasks"/"td-r.done.json")
# (2) git unavailable after start: the worktree's git dir is moved away during the run
os.environ["FAKE_CLAUDE_HOOK"]=f"mv {wt}/.git {wt}/.git-gone"
assert c.run_mech(rd,mk("mech-td-r-2"),"x",60)==3
L=[json.loads(l) for l in open(rd/"tasks"/"td-r.spend.jsonl")]
assert [l["kind"] for l in L]==["start","end","start","end"] and L[-1]["record_written_by"]=="none" and L[-1]["git_ok"] is False,L
assert not (rd/"tasks"/"td-r.done.json").exists()
sys.exit(0)
PY

check "run-mech: unwritable ledger dir exits 2 before any write (fresh task id)" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d); PATH="$FAKE_CLAUDE_DIR:$PATH"; L=$(mktemp -d)
export FAKE_CLAUDE_LOG="$L/log"; export FAKE_CLAUDE_JSON="$L/res.json"; unset FAKE_CLAUDE_HOOK FAKE_CLAUDE_SLEEP FAKE_CLAUDE_RC
CLI="python3 claude/hooks/herdr_legacy_fixture.py"; RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-r"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q -b main; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base; BASE=$(git -C "$WT" rev-parse HEAD)
: > "$RD/tasks/b.md"; printf '{"type":"result","subtype":"success"}' > "$FAKE_CLAUDE_JSON"
chmod 500 "$RD/tasks"
rc=0; $CLI run-mech --repo-slug slug-r --task-id td-new --workspace w1 --agent mech-td-new --launch-id mech-td-new-1 \
  --model haiku --worktree "$WT" --base-sha "$BASE" --brief-file "$RD/tasks/b.md" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60 2>/dev/null || rc=$?
chmod 700 "$RD/tasks"
[ "$rc" -eq 2 ] && [ ! -e "$RD/tasks/td-new.spend.jsonl" ] && [ ! -e "$RD/tasks/td-new.done.json" ] && [ ! -e "$FAKE_CLAUDE_LOG.argv" ]
SH

check "run-mech: validation exits 2 and writes nothing" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d); PATH="$FAKE_CLAUDE_DIR:$PATH"; L=$(mktemp -d)
export FAKE_CLAUDE_LOG="$L/log"; export FAKE_CLAUDE_JSON="$L/res.json"; unset FAKE_CLAUDE_HOOK FAKE_CLAUDE_SLEEP FAKE_CLAUDE_RC
CLI="python3 claude/hooks/herdr_legacy_fixture.py"; RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-r"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q -b main; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base; BASE=$(git -C "$WT" rev-parse HEAD)
: > "$RD/tasks/b.md"; OUT=$(mktemp -d); : > "$OUT/b.md"; : > "$RD/tasks/noread.md"; chmod 000 "$RD/tasks/noread.md"
base="--repo-slug slug-r --task-id td-r --workspace w1 --model haiku --worktree $WT --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60"
try() { rc=0; $CLI run-mech "$@" 2>/dev/null || rc=$?; [ "$rc" -eq 2 ] || { echo "expected 2 got $rc: $*" >&2; return 1; }; }
try $base --agent mech-td-r --launch-id mech-td-r-1 --base-sha "$BASE" --brief-file "$OUT/b.md"             # brief outside STATE_ROOT
try $base --agent mech-td-r --launch-id mech-td-r-1 --base-sha "$BASE" --brief-file "$RD/tasks/noread.md"   # brief unreadable
try $base --agent mech- --launch-id mech--1 --base-sha "$BASE" --brief-file "$RD/tasks/b.md"                # empty suffix
try $base --agent mech-Td-r --launch-id mech-Td-r-1 --base-sha "$BASE" --brief-file "$RD/tasks/b.md"        # uppercase
try $base --agent mech-other --launch-id mech-other-1 --base-sha "$BASE" --brief-file "$RD/tasks/b.md"      # not this task's agent
try $base --agent mech-td-r-10 --launch-id mech-td-r-10-1 --base-sha "$BASE" --brief-file "$RD/tasks/b.md"  # collision suffix > 9
try $base --agent mech-td-r --launch-id other-1 --base-sha "$BASE" --brief-file "$RD/tasks/b.md"            # launch id not prefixed
try $base --agent mech-td-r --launch-id mech-td-r-1 --base-sha abc --brief-file "$RD/tasks/b.md"            # bad sha
try --repo-slug slug-r --task-id td-r --workspace w1 --model haiku --worktree "$(mktemp -d)" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 60 \
    --agent mech-td-r --launch-id mech-td-r-1 --base-sha "$BASE" --brief-file "$RD/tasks/b.md"             # non-git worktree
try --repo-slug slug-r --task-id td-r --workspace w1 --model haiku --worktree "$WT" --max-turns 0 --max-budget-usd 0.5 --timeout-secs 60 \
    --agent mech-td-r --launch-id mech-td-r-1 --base-sha "$BASE" --brief-file "$RD/tasks/b.md"             # cap out of bounds
try --repo-slug slug-r --task-id td-r --workspace w1 --model haiku --worktree "$WT" --max-turns 7 --max-budget-usd 0.5 --timeout-secs 59 \
    --agent mech-td-r --launch-id mech-td-r-1 --base-sha "$BASE" --brief-file "$RD/tasks/b.md"             # timeout below floor
try $base --agent mech-td-r --launch-id 'mech-td-r-1;rm' --base-sha "$BASE" --brief-file "$RD/tasks/b.md"  # metachar
try $base --agent mech-td-r --launch-id 'mech-td-r 1' --base-sha "$BASE" --brief-file "$RD/tasks/b.md"     # whitespace
[ ! -e "$RD/tasks/td-r.spend.jsonl" ] && [ ! -e "$RD/tasks/td-r.done.json" ] && [ ! -e "$FAKE_CLAUDE_LOG.argv" ]
SH

check "effort map: defaults, think constraints, config overrides fail closed" <<PY
$LOAD
assert c.EFFORT_LEVELS==("low","medium","high","xhigh","max") and c.THINK_EFFORTS==("high","xhigh","max")
assert c.ROLE_DEFAULTS["think"]==("fable","opus") and c.ROLE_ALIASES["think"]==("fable","opus")
assert c.role_effort("plan",{})==("high",None) and c.role_effort("review",{})==("high",None)
assert c.role_effort("impl",{})==(None,None) and c.role_effort("mech",{})==(None,None)
assert c.role_effort("think",{})==("high",None)
assert c.role_effort("impl",{"effort":{"impl":"low"}})==("low",None)
assert c.role_effort("plan",{"effort":{"plan":None}})==(None,None)
assert c.role_effort("think",{"effort":{"think":"xhigh"}})==("xhigh",None)
assert c.role_effort("review",{"effort":{"plan":"low"}})==("high",None)   # sibling override untouched
bad=[{"effort":[]},{"effort":None},{"effort":{"bogus":"high"}},{"effort":{"plan":"turbo"}},{"effort":{"plan":True}},
     {"effort":{"plan":3}},{"effort":{"think":None}},{"effort":{"think":"low"}},{"effort":{"think":"medium"}}]
for b in bad:
    assert c.role_effort("plan",b)==(None,5), b
assert c.role_effort("orchestrator",{})==(None,5)
assert c.resolve_model("think",{"fable":True,"opus":True,"sonnet":True,"haiku":True},{})==("fable",None)
assert c.resolve_model("think",{"fable":False,"opus":True,"sonnet":True,"haiku":True},{})==("opus",None)
assert c.resolve_model("think",{"fable":False,"opus":False,"sonnet":True,"haiku":True},{})==(None,4)
assert c.resolve_model("think",{"fable":True,"opus":True,"sonnet":True,"haiku":True},{"models":{"think":["sonnet"]}})==(None,5)
assert c.resolve_model("think",{"fable":True,"opus":True,"sonnet":True,"haiku":True},{"models":{"think":["haiku"]}})==(None,5)
sys.exit(0)
PY

check "resolve-effort CLI prints level or inherit, exit 5 on bad config" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-e"; mkdir -p "$RD"
[ "$($CLI resolve-effort --repo-slug slug-e --role plan)" = high ]
[ "$($CLI resolve-effort --repo-slug slug-e --role impl)" = inherit ]
[ "$($CLI resolve-effort --repo-slug slug-e --role think)" = high ]
printf '{"v":1,"user":"u","default_base":"origin/main","effort":{"impl":"low","think":"xhigh"}}' > "$RD/config.json"
[ "$($CLI resolve-effort --repo-slug slug-e --role impl)" = low ]
[ "$($CLI resolve-effort --repo-slug slug-e --role think)" = xhigh ]
printf '{"v":1,"user":"u","default_base":"origin/main","effort":{"think":null}}' > "$RD/config.json"
rc=0; $CLI resolve-effort --repo-slug slug-e --role plan 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]
rc=0; $CLI resolve-effort --repo-slug slug-e --role nope 2>/dev/null || rc=$?; [ "$rc" -eq 5 ]
SH

check "docs pin the mech tier: role row, run-mech launch, liveness table, ledger schema, brief variant" <<'SH'
S="claude/skills/herdr-orchestration/SKILL.md"; R="claude/skills/herdr-orchestration/references"
grep -q '| Mechanical worker (`mech`)' "$S"
grep -Fq -- 'route --runtime <claude|codex> --role mechanical --risk normal' "$S"
grep -q 'Legacy Claude wrapper' "$S"
grep -q 'run-mech --repo-slug' "$S"
grep -q '"haiku":true' "$S"                                  # probe writes the fourth alias
grep -q 'mech-caps --repo-slug' "$S"
grep -q 'mech-contract --repo-slug' "$S"
grep -q 'Launch base' "$S"                                   # base_sha = post-contract HEAD
grep -q 'wrapper lost' "$S"                                  # mech liveness table
grep -q '_totals' "$S"
grep -q '"mech": {' "$R/state-layout.md"
grep -q '\.spend\.jsonl' "$R/state-layout.md"
grep -q '"haiku": true' "$R/state-layout.md"
grep -q 'launch_id' "$R/state-layout.md"
grep -q 'Mech brief variant' "$R/brief-template.md"
grep -q -- '--launch-id <launch_id>' "$R/brief-template.md"
grep -q 'spend.jsonl' "$R/event-schema.md"
SH

check "docs pin effort routing, banner verb, deep think, and Workflow routing" <<'SH'
S="claude/skills/herdr-orchestration/SKILL.md"; R="claude/skills/herdr-orchestration/references"
grep -q 'routing-table --repo-slug' "$S"                     # one snapshot per dispatch
grep -q 'One snapshot per dispatch' "$S"
grep -q -- '--effort \$EFFORT' "$S"                          # launch line
grep -q 'classify-banner --model' "$S"
grep -q 'effort-mismatch' "$S"
grep -q 'not availability data' "$S"                         # never disable-model on effort-mismatch
grep -q 'Deep-think escalation' "$S"
grep -q 'run-think --repo-slug' "$S"
grep -q 'think-caps --repo-slug' "$S"
for t in 'Ambiguous triage' 'Milestone/epic decomposition' 'Novel incident' 'Not eligible'; do grep -q "$t" "$S"; done
grep -q 'one live escalation per repo' "$S"
grep -q 'daily_budget_usd' "$S"
grep -q 'escalation deferred' "$S"
grep -q '_think' "$S"
grep -q 'Workflow' "$S" && grep -q 'in-turn helper work' "$S"
grep -q 'Precedence with the user' "$S"
grep -q 'route --step implementation-review' "$S"
grep -q -- '--provisional' "$S"
grep -q 'review-change' "$S"
grep -q 'task-local readiness' "$S"
grep -q '600-second deadline' "$S"
grep -q 'outcome: changes-requested' "$S"
grep -q 'outcome: approved' "$S"
grep -q 'Workflow opt-in: granted by the user' "$R/brief-template.md"
grep -q 'Workflow opt-in: withheld for this task' "$R/brief-template.md"
grep -q '## Routing' "$R/brief-template.md"
grep -q 'never call `herdr_orch_core.py`' "$R/brief-template.md"
grep -q 'review-change' "$R/brief-template.md"
grep -q 'not PR approval' "$R/brief-template.md"
grep -q 'per-task/review-change' "$R/dispatch-mechanism.md"
grep -q 'development_reviewer.*sonnet/high' "$R/pipeline-worker-mapping.md"
grep -q 'gpt-5.6-sol/high' "$R/pipeline-worker-mapping.md"
grep -q 'Deep-think brief variant' "$R/brief-template.md"
grep -q '"effort": {' "$R/state-layout.md"
grep -q '"think": {' "$R/state-layout.md"
grep -q '\.launch\.json' "$R/state-layout.md"
grep -q '\.answer\.json' "$R/state-layout.md"
grep -q 'workers\[\].effort\|"effort": "high"' "$R/state-layout.md"
grep -q 'think/' "$R/event-schema.md"
grep -q 'models.think\|"think": \["fable", "opus"\]' "$R/state-layout.md"
SH

check "routing_table: all roles, null model on no survivor, global 3/5" <<PY
$LOAD
avail={"fable":True,"opus":True,"sonnet":True,"haiku":True}
t,code=c.routing_table(avail,{})
assert code is None and set(t)=={"plan","impl","review","mech","think"},t
assert t["plan"]=={"model":"fable","effort":"high"} and t["impl"]=={"model":"sonnet","effort":None}
assert t["mech"]=={"model":"haiku","effort":None} and t["think"]=={"model":"fable","effort":"high"}
t,code=c.routing_table({"fable":False,"opus":False,"sonnet":True,"haiku":True},{})
assert code is None and t["think"]["model"] is None and t["impl"]["model"]=="sonnet"
assert c.routing_table(None,{})==(None,3)
assert c.routing_table(avail,{"effort":{"plan":"turbo"}})==(None,5)
assert c.routing_table(avail,{"models":{"plan":["gpt"]}})==(None,5)
assert c.routing_table(None,{"models":{"plan":["gpt"]}})==(None,5)   # config error outranks stale map
# single snapshot: main reads config and capabilities exactly once
calls={"cfg":0,"cap":0}
real_cfg,real_cap=c.read_config,c.read_capabilities
c.read_config=lambda rd:(calls.__setitem__("cfg",calls["cfg"]+1) or {})
c.read_capabilities=lambda rd,s:(calls.__setitem__("cap",calls["cap"]+1) or avail)
import io,contextlib
buf=io.StringIO()
with contextlib.redirect_stdout(buf):
    rc=c.main(["routing-table","--repo-slug","slug-rt","--session","S"])
assert rc==0 and calls=={"cfg":1,"cap":1},calls
assert json.loads(buf.getvalue())["review"]=={"model":"opus","effort":"high"}
c.read_config,c.read_capabilities=real_cfg,real_cap
sys.exit(0)
PY

check "routing-table CLI exit codes" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-rt --session S --host h --pid 1)
rc=0; $CLI routing-table --repo-slug slug-rt --session S >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 3 ]
$CLI write-capabilities --repo-slug slug-rt --session S --fence "$F" \
  --json '{"v":1,"session_id":"S","available":{"fable":false,"opus":true,"sonnet":true,"haiku":true}}'
$CLI routing-table --repo-slug slug-rt --session S | python3 -c "import json,sys;t=json.load(sys.stdin);assert t['plan']=={'model':'opus','effort':'high'} and t['impl']['effort'] is None,t"
printf '{"v":1,"user":"u","default_base":"origin/main","effort":{"plan":"low","plan2":"x"}}' > "$CLAUDE_CONFIG_DIR/herdr-orch/slug-rt/config.json"
rc=0; $CLI routing-table --repo-slug slug-rt --session S >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 5 ]
SH

check "parse_banner/classify_banner: families, effort clause, indicator line, ansi, adversarial" <<PY
$LOAD
D="\u00b7"; B="\u25cf"
real=" \u2590\u259b\u2588\u2588   Claude Code v2.1.260\n\u259d\u259c\u2588\u2588  Sonnet 5 with high effort "+D+" Claude Max\n  \u259d\u259d    ~/Git/repo\n"
p=c.parse_banner(real); assert p=={"model":"Sonnet 5","effort":"high"},p
assert c.classify_banner(p,"sonnet","high")=="ok"
assert c.classify_banner(p,"sonnet","inherit")=="ok"
assert c.classify_banner(p,"fable","high")=="downgrade"
assert c.classify_banner(p,"sonnet","medium")=="effort-mismatch"
noeff="Claude Code v2.1.260\n  Opus 4.6 "+D+" Claude Max\n"
p=c.parse_banner(noeff); assert p=={"model":"Opus 4.6","effort":None},p
assert c.classify_banner(p,"opus","inherit")=="ok"
assert c.classify_banner(p,"opus","high")=="effort-mismatch"
ind="Claude Code v2.1.260\n  Fable 5.1 "+D+" Claude Max\n\n   "+B+" medium "+D+" /effort\n"
p=c.parse_banner(ind); assert p=={"model":"Fable 5.1","effort":"medium"},p
assert c.classify_banner(p,"fable","high")=="effort-mismatch"
assert c.classify_banner(p,"fable","medium")=="ok"
ansi="\x1b[1mClaude Code v2.1.260\x1b[0m\r\n\x1b[38;5;208mSonnet 5 with xhigh effort\x1b[0m "+D+" Claude Max\n"
assert c.parse_banner(ansi)=={"model":"Sonnet 5","effort":"xhigh"}
assert c.strip_ansi("\x1b]0;title\x07x\x1b[2Ky")=="xy"
# adversarial: ambiguous historical banners are unreadable
two="Claude Code v2.1.260\n Sonnet 5 "+D+" Claude Max\n> tell me about Claude Code v9.9.9\n Opus 9\n"
assert c.classify_banner(c.parse_banner(two),"sonnet","inherit")=="ok"  # quoted mention is not a banner
quoted="> the banner said Claude Code v2.1.260 earlier\n Opus 9\nClaude Code v2.1.260\n Sonnet 5 "+D+" Claude Max\n"
assert c.parse_banner(quoted)["model"]=="Sonnet 5"                       # unanchored mention is not a banner line
far="Claude Code v2.1.260\n Sonnet 5 "+D+" Claude Max\n"+"\n".join("line %d"%i for i in range(20))+"\n "+B+" xhigh "+D+" /effort\n"
assert c.parse_banner(far)["effort"] is None                              # indicator beyond the banner region is ignored
for bad in ("", "no banner here", "Claude Code v2.1.260\n", "Claude Code v2.1.260\n  Loading... "+D+" x\n", "Claude Code vX\n Sonnet 5\n"):
    assert c.parse_banner(bad) is None, bad
    assert c.classify_banner(None,"fable","high")=="unreadable"
sys.exit(0)
PY

check "classify-banner CLI" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
T=$(mktemp); printf 'Claude Code v2.1.260\n  Sonnet 5 with high effort \302\267 Claude Max\n' > "$T"
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort high --text-file "$T")" = ok ]
[ "$($CLI classify-banner --repo-slug slug-b --model fable --effort high --text-file "$T")" = downgrade ]
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort xhigh --text-file "$T")" = effort-mismatch ]
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort inherit --text 'garbage')" = unreadable ]
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort xhigh --text-file "$T" --json)" = '{"class": "effort-mismatch", "model": "Sonnet 5", "effort": "high"}' ]
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort high --text 'garbage' --json)" = '{"class": "unreadable", "model": null, "effort": null}' ]
printf 'Claude Code v2.1.260\n  Sonnet 5 \302\267 Claude Max\n' > "$T"
[ "$($CLI classify-banner --repo-slug slug-b --model sonnet --effort high --text-file "$T" --json)" = '{"class": "effort-mismatch", "model": "Sonnet 5", "effort": null}' ]
rc=0; $CLI classify-banner --repo-slug slug-b --model gpt --effort high --text x 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
rc=0; $CLI classify-banner --repo-slug slug-b --model sonnet --effort turbo --text x 2>/dev/null || rc=$?; [ "$rc" -eq 2 ]
SH

check "think ids: every kind fits 32 with the retry suffix; validator matches THINK_SCHEMA exactly" <<PY
$LOAD
for k in ("triage","decompose","incident","other"):
    for suf in ("","-2"):
        tid=f"think-{k}-20260904170000{suf}"
        assert c.valid_think_id(tid) and len(tid)<=32 and re.fullmatch(c.AGENT_NAME_RE.pattern,tid), tid
        assert c.think_kind(tid)==k
for bad in ("think-triage-202609041700001","think-triage-20260904170000-3","think-Triage-20260904170000",
            "think-triage-20260904T170000Z","think-x-20260904170000","",None,"think-triage-20260904170000-2-2"):
    assert not c.valid_think_id(bad), bad
opt=lambda i:{"label":f"o{i}","summary":"s","tradeoffs":"t","risk":"low"}
good={"recommendation":"r","rationale":"why","options":[opt(1),opt(2)],"confidence":"high"}
assert c.valid_think_answer(good) is None
full=dict(good,options=[opt(i) for i in range(4)],open_questions=["q"]*10,evidence=["e"]*20,
          recommendation="x"*500,rationale="y"*4000)
assert c.valid_think_answer(full) is None
bad=[None,[],{},dict(good,options=[opt(1)]),dict(good,options=[opt(i) for i in range(5)]),
     dict(good,extra=1),dict(good,options=[dict(opt(1),x=1),opt(2)]),dict(good,recommendation="x"*501),
     dict(good,options=[dict(opt(1),risk="none"),opt(2)]),dict(good,confidence="sure"),
     dict(good,open_questions=["q"]*11),dict(good,evidence=[""]),dict(good,rationale=""),
     dict(good,options=[opt(1),{"label":"a","summary":"s","risk":"low"}]),dict(good,recommendation=3)]
for b in bad:
    assert isinstance(c.valid_think_answer(b),str), b
assert c.THINK_SCHEMA["properties"]["options"]["minItems"]==2 and c.THINK_SCHEMA["additionalProperties"] is False
sys.exit(0)
PY

check "think validators + scan: invalid records fail closed; live/lost per record timeout; reservation accounting" <<PY
$LOAD
rd=os.path.join(tempfile.mkdtemp(),"slug"); os.mkdir(rd); td=os.path.join(rd,"think"); os.mkdir(td)
def w(name,rec): open(os.path.join(td,name),"w").write(json.dumps(rec))
L=lambda tid,started,to=900,**kw:dict({"v":1,"think_id":tid,"kind":c.think_kind(tid),"task_id":None,"repo_slug":"s","model":"fable","effort":"high","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":to},"attempt":2 if tid.endswith("-2") else 1,"parent":tid[:-2] if tid.endswith("-2") else None,"started":started,"pid":1},**kw)
opt=lambda i:{"label":f"o{i}","summary":"s","tradeoffs":"t","risk":"low"}
ANS={"recommendation":"r","rationale":"w","options":[opt(1),opt(2)],"confidence":"high"}
A=lambda tid,status,cost,turns,started,**kw:dict({"v":1,"think_id":tid,"status":status,"reason":None if status=="answered" else "error","answer":ANS if status=="answered" else None,"total_cost_usd":cost,"num_turns":turns,"started":started},**kw)
assert c.valid_launch_record(L("think-triage-20260904100000","2026-09-04T10:00:00Z"),"think-triage-20260904100000")
assert c.valid_launch_record(L("think-triage-20260904100000-2","2026-09-04T10:00:00Z"),"think-triage-20260904100000-2")
for bad in (L("think-triage-20260904100000","2026-09-04T10:00:00Z",caps={}), L("think-triage-20260904100000","nope"),
            L("think-triage-20260904100000","2026-09-04T10:00:00Z",model="sonnet"), L("think-triage-20260904100000","2026-09-04T10:00:00Z",effort="low"),
            L("think-triage-20260904100000","2026-09-04T10:00:00Z",attempt=2), L("think-triage-20260904100000-2","2026-09-04T10:00:00Z",parent=None),
            L("think-triage-20260904100000","2026-09-04T10:00:00Z",kind="other"), dict(L("think-triage-20260904100000","2026-09-04T10:00:00Z"),v=True), {}):
    assert not c.valid_launch_record(bad,"think-triage-20260904100000"), bad
assert c.valid_answer_record(A("t","answered",1.0,2,"2026-09-04T10:00:00Z"),"t")
assert c.valid_answer_record(A("t","unanswered",None,None,"2026-09-04T10:00:00Z"),"t")
for bad in (A("t","answered",1.0,2,"2026-09-04T10:00:00Z",answer={"recommendation":"r"}), A("t","done",1.0,2,"2026-09-04T10:00:00Z"),
            A("t","answered",-1,2,"2026-09-04T10:00:00Z"), A("t","answered",1.0,True,"2026-09-04T10:00:00Z"),
            A("t","unanswered",None,None,"2026-09-04T10:00:00Z",reason="bogus"), A("t","unanswered",None,None,"2026-09-04T10:00:00Z",answer=ANS), {"v":1,"think_id":"t"}):
    assert not c.valid_answer_record(bad,"t"), bad
w("think-triage-20260904100000.launch.json",L("think-triage-20260904100000","2026-09-04T10:00:00Z"))
w("think-triage-20260904100000.answer.json",A("think-triage-20260904100000","answered",1.12,6,"2026-09-04T10:00:00Z"))
w("think-other-20260904110000.launch.json",L("think-other-20260904110000","2026-09-04T11:00:00Z"))
w("think-other-20260904110000.answer.json",A("think-other-20260904110000","answered",0.40,3,"2026-09-04T11:00:00Z"))
w("think-incident-20260904120000.launch.json",L("think-incident-20260904120000","2026-09-04T12:00:00Z"))
w("think-incident-20260904120000.answer.json",A("think-incident-20260904120000","unanswered",None,None,"2026-09-04T12:00:00Z"))
w("think-decompose-20260904125900.launch.json",L("think-decompose-20260904125900","2026-09-04T12:59:00Z"))      # live: 1 min old
w("think-incident-20260903120000.launch.json",L("think-incident-20260903120000","2026-09-03T12:00:00Z",600))  # lost
w("think-other-20260904124000.launch.json",L("think-other-20260904124000","2026-09-04T12:40:00Z"))            # invalid answer -> still live
w("think-other-20260904124000.answer.json",{"v":1,"think_id":"think-other-20260904124000","status":"answered"})
open(os.path.join(td,"think-other-20260904130000.answer.json"),"w").write('{"v":1,"trunc')
w("think-other-20260904140000.answer.json",{"v":2,"think_id":"think-other-20260904140000"})
w("think-other-20260904150000.answer.json",A("think-other-20260904150000","answered",0.5,1,"2026-09-04T15:00:00Z"))   # orphan answer: no launch -> skipped
w("think-triage-20260904160000.launch.json",{"v":1,"think_id":"think-triage-20260904160000"})                          # corrupt launch
w("bogus-stem.launch.json",{"v":1})                                                                                       # invalid launch stem -> corrupt
w("bogus-stem.answer.json",{"v":1})                                                                                       # invalid answer stem -> skipped
s=c.think_scan(rd,"2026-09-04T13:00:00Z")
assert [l["think_id"] for l in s["launches"]]==sorted(["think-triage-20260904100000","think-other-20260904110000","think-incident-20260904120000","think-decompose-20260904125900","think-incident-20260903120000","think-other-20260904124000"]),s["launches"]
assert set(s["answers"])=={"think-triage-20260904100000","think-other-20260904110000","think-incident-20260904120000"},s["answers"].keys()
assert s["live"]==["think-decompose-20260904125900","think-other-20260904124000"] and s["lost"]==["think-incident-20260903120000"],s
assert s["skipped_files"]==5 and s["corrupt"]==["bogus-stem","think-triage-20260904160000"],s
# reservation: 1.12 + 0.40 + 3.0 (null-cost unanswered) + 3.0 (live decompose) + 3.0 (live with invalid answer) = 10.52
assert c.think_usd_today(s,"2026-09-04")==10.52, c.think_usd_today(s,"2026-09-04")
assert c.think_usd_today(s,"2026-09-03")==3.0                                   # lost launch counts its cap
e=c.think_scan(tempfile.mkdtemp(),"2026-09-04T13:00:00Z"); assert e=={"launches":[],"answers":{},"live":[],"lost":[],"skipped_files":0,"corrupt":[]},e
sys.exit(0)
PY

check "publish_exclusive never clobbers or leaves partials; think_lock serializes" <<PY
$LOAD
d=tempfile.mkdtemp(); p=os.path.join(d,"x.json")
assert c.publish_exclusive(p,{"a":1}) and json.load(open(p))=={"a":1}
assert not c.publish_exclusive(p,{"a":2}) and json.load(open(p))=={"a":1}      # no replace
assert [n for n in os.listdir(d) if n!="x.json"]==[]                            # no temp left behind
ro=os.path.join(d,"ro"); os.mkdir(ro); os.chmod(ro,0o555)
try:
    assert not c.publish_exclusive(os.path.join(ro,"y.json"),{"a":1}) and os.listdir(ro)==[]
finally:
    os.chmod(ro,0o755)
import threading,time
order=[]
def hold(tag,secs):
    with c.think_lock(d):
        order.append(("in",tag)); time.sleep(secs); order.append(("out",tag))
t1=threading.Thread(target=hold,args=("a",0.3)); t2=threading.Thread(target=hold,args=("b",0.0))
t1.start(); time.sleep(0.05); t2.start(); t1.join(); t2.join()
assert order==[("in","a"),("out","a"),("in","b"),("out","b")],order
assert os.path.exists(os.path.join(d,"think",".lock"))
sys.exit(0)
PY

check "run-mech characterization: popen failure, unparseable stdout, nonzero exit, timeout return" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-ch"; mkdir -p "$RD/tasks"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
BASE=$(git -C "$WT" rev-parse HEAD); printf 'brief\n' > "$RD/tasks/td-ch.brief.md"
export FAKE_CLAUDE_LOG="$RD/log" FAKE_CLAUDE_JSON="$RD/res.json"
base="$CLI run-mech --repo-slug slug-ch --task-id td-ch --workspace w1 --agent mech-td-ch --model haiku --worktree $WT --base-sha $BASE --brief-file $RD/tasks/td-ch.brief.md --max-turns 5 --max-budget-usd 0.5 --timeout-secs 60"
end() { python3 -c "import json,sys;l=[json.loads(x) for x in open('$RD/tasks/td-ch.spend.jsonl')];e=[x for x in l if x['kind']=='end'][-1];print(json.dumps(e))"; }
done_() { python3 -c "import json;print(json.dumps(json.load(open('$RD/tasks/td-ch.done.json'))))"; }
# 1. no claude on PATH (but python3/git/sh present): exit_code null, subtype unparseable, failed/error (HEAD == base)
NOCL=$(mktemp -d); for b in python3 git sh; do ln -s "$(command -v $b)" "$NOCL/$b"; done
PATH="$NOCL" $base --launch-id mech-td-ch-1 || true
end | python3 -c "import json,sys;e=json.load(sys.stdin);assert e['subtype']=='unparseable' and e['exit_code'] is None and e['num_turns'] is None,e"
done_ | python3 -c "import json,sys;d=json.load(sys.stdin);assert d['outcome']=='failed' and d['reason']=='error',d"
# 2. unparseable stdout from a running fake
export PATH="$FAKE_CLAUDE_DIR:$PATH"; printf 'garbage\n' > "$FAKE_CLAUDE_JSON"
$base --launch-id mech-td-ch-2; end | python3 -c "import json,sys;e=json.load(sys.stdin);assert e['subtype']=='unparseable' and e['exit_code']==0 and e['total_cost_usd'] is None,e"
# 3. nonzero exit with a parseable error result
printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"total_cost_usd":0.01,"errors":["boom"]}' > "$FAKE_CLAUDE_JSON"
FAKE_CLAUDE_RC=7 $base --launch-id mech-td-ch-3; end | python3 -c "import json,sys;e=json.load(sys.stdin);assert e['subtype']=='error_during_execution' and e['exit_code']==7 and e['errors']==['boom'] and e['model_attributable'] is False,e"
# 4. timeout: subtype timeout, negative exit code (killed), num_turns null
FAKE_CLAUDE_SLEEP=70 $base --launch-id mech-td-ch-4 --max-turns 5 2>/dev/null || true
end | python3 -c "import json,sys;e=json.load(sys.stdin);assert e['subtype']=='timeout' and e['num_turns'] is None,e"
SH

check "run_think: argv contract, answered/unanswered mapping, popen failure, unparseable, exit 3" <<PY
$LOAD
import types,subprocess,shutil
rd=os.path.join(tempfile.mkdtemp(),"slug"); os.mkdir(rd); td=os.path.join(rd,"think"); os.mkdir(td)
wt=tempfile.mkdtemp(); subprocess.run(["git","init","-q",wt],check=True)
fake=os.environ["FAKE_CLAUDE_DIR"]; log=os.path.join(rd,"log"); resj=os.path.join(rd,"res.json")
os.environ.update(FAKE_CLAUDE_LOG=log,FAKE_CLAUDE_JSON=resj); os.environ.pop("FAKE_CLAUDE_HOOK",None); os.environ.pop("FAKE_CLAUDE_SLEEP",None)
os.environ["PATH"]=fake+os.pathsep+os.environ["PATH"]
tid="think-triage-20260904170000"
a=types.SimpleNamespace(session="S",fence=1,think_id=tid,kind="triage",task_id=None,repo_slug="slug",model="fable",effort="high",cwd=wt)
claim_legacy_owner(rd,"S","h",1)
launch={"v":1,"think_id":tid,"kind":"triage","task_id":None,"repo_slug":"slug","model":"fable","effort":"high","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":60},"attempt":1,"parent":None,"started":"2026-09-04T17:00:00Z","pid":1}
opt=lambda i:{"label":f"o{i}","summary":"s","tradeoffs":"t","risk":"low"}
good={"recommendation":"do A","rationale":"because","options":[opt(1),opt(2)],"confidence":"high"}
def res(**kw): open(resj,"w").write(json.dumps(dict({"type":"result"},**kw)))
def ans(): return json.load(open(os.path.join(td,tid+".answer.json")))
def reset():
    for n in os.listdir(td):
        if n != ".lock": os.unlink(os.path.join(td,n))
res(subtype="success",is_error=False,num_turns=4,total_cost_usd=0.9,duration_ms=1000,session_id="sid",permission_denials=[{"tool":"Read"}],modelUsage={"claude-fable-5-1":{}},structured_output=good)
assert c.run_think(rd,a,"Which item first?\n",launch,[os.path.join(rd,"tasks")])==0
r=ans(); assert r["status"]=="answered" and r["answer"]==good and r["total_cost_usd"]==0.9 and r["num_turns"]==4 and r["permission_denials"]==1 and r["attempt"]==1 and r["caps"]["timeout_secs"]==60,r
argv=open(log+".argv").read().splitlines()          # fake claude's "$@" excludes argv[0] ("claude" itself)
exp=["--model","fable","--effort","high","--permission-mode","dontAsk","--name",tid,"-p","--output-format","json","--json-schema"]
assert argv[:len(exp)]==exp,argv
i=argv.index("--json-schema"); assert json.loads(argv[i+1])==c.THINK_SCHEMA
assert argv[i+2:]==["--max-turns","15","--max-budget-usd","3.0","--restricted","--strict-mcp-config","--tools","Read,Glob,Grep","--add-dir",os.path.join(rd,"tasks")],argv[i+2:]
assert open(log+".stdin").read()=="Which item first?\n" and os.path.realpath(open(log+".cwd").read().strip())==os.path.realpath(wt)
reset(); res(subtype="error_max_turns",is_error=True,num_turns=15,total_cost_usd=2.0)
assert c.run_think(rd,a,"q",launch,[])==0 and ans()["reason"]=="max_turns" and ans()["answer"] is None
reset(); res(subtype="error_max_budget_usd",is_error=True,num_turns=3,total_cost_usd=3.0)
assert c.run_think(rd,a,"q",launch,[])==0 and ans()["reason"]=="max_budget"
reset(); res(subtype="success",is_error=False,num_turns=2,total_cost_usd=0.2,structured_output=dict(good,options=[opt(1)]))
assert c.run_think(rd,a,"q",launch,[])==0 and ans()["reason"]=="no_answer" and "fewer than 2" in ans()["errors"][0]
reset(); res(subtype="success",is_error=False,num_turns=2,total_cost_usd=0.2)          # no structured_output at all
assert c.run_think(rd,a,"q",launch,[])==0 and ans()["reason"]=="no_answer"
reset(); res(subtype="success",is_error=False,num_turns=1,total_cost_usd=0.1,modelUsage={"claude-sonnet-5":{}},structured_output=good)
assert c.run_think(rd,a,"q",launch,[])==0 and ans()["downgrade"] is True and ans()["model_attributable"] is True
reset(); open(resj,"w").write("not json at all")                                      # unparseable stdout
assert c.run_think(rd,a,"q",launch,[])==0 and ans()["reason"]=="error" and ans()["subtype"]=="unparseable" and ans()["total_cost_usd"] is None
reset(); res(subtype="error_during_execution",is_error=True,num_turns=1,total_cost_usd=0.1,errors=["model fable unavailable"])
os.environ["FAKE_CLAUDE_RC"]="1"
assert c.run_think(rd,a,"q",launch,[])==0 and ans()["reason"]=="error" and ans()["exit_code"]==1 and ans()["model_attributable"] is True
os.environ.pop("FAKE_CLAUDE_RC")
reset(); os.environ["FAKE_CLAUDE_SLEEP"]="3"
assert c.run_think(rd,a,"q",dict(launch,caps=dict(launch["caps"],timeout_secs=1)),[])==0 and ans()["reason"]=="timeout"
pid=int(open(log+".pid").read()); import time; time.sleep(0.2)
try:
    os.kill(pid,0); alive=True
except OSError:
    alive=False
assert not alive
os.environ.pop("FAKE_CLAUDE_SLEEP")
reset(); saved=os.environ["PATH"]; os.environ["PATH"]=tempfile.mkdtemp()                # no claude on PATH -> Popen fails
assert c.run_think(rd,a,"q",launch,[])==0 and ans()["reason"]=="error" and ans()["exit_code"] is None
os.environ["PATH"]=saved
reset(); res(subtype="success",is_error=False,num_turns=1,total_cost_usd=0.1,structured_output=good)
os.environ["FAKE_CLAUDE_HOOK"]=f"mkdir {os.path.join(td,tid+'.answer.json')}"          # answer path taken while claude runs
assert c.run_think(rd,a,"q",launch,[])==3 and os.path.isdir(os.path.join(td,tid+".answer.json"))
os.environ.pop("FAKE_CLAUDE_HOOK")
sys.exit(0)
PY

check "run-think handler: happy path via CLI, stale fence, exit 2 cases write nothing" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
git -C "$WT" remote add origin https://github.com/org/repo2.git
SLUG=$(python3 -c "import importlib.util;s=importlib.util.spec_from_file_location('c','claude/hooks/herdr_orch_core.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c);print(c.repo_slug('https://github.com/org/repo2.git'))")
RD="$CLAUDE_CONFIG_DIR/herdr-orch/$SLUG"; mkdir -p "$RD/think" "$RD/tasks"
FE=$($CLI claim-owner --repo-slug $SLUG --session S --host h --pid 1)
export PATH="$FAKE_CLAUDE_DIR:$PATH" FAKE_CLAUDE_LOG="$RD/log" FAKE_CLAUDE_JSON="$RD/res.json"
q() { printf 'q\n' > "$RD/think/$1.question.md"; }
GOOD='{"recommendation":"do A","rationale":"because","options":[{"label":"A","summary":"s","tradeoffs":"t","risk":"low"},{"label":"B","summary":"s","tradeoffs":"t","risk":"medium"}],"confidence":"high"}'
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":4,"total_cost_usd":0.9,"modelUsage":{"claude-fable-5-1":{}},"structured_output":%s}' "$GOOD" > "$FAKE_CLAUDE_JSON"
ok="--repo-slug $SLUG --session S --fence $FE --kind triage --model fable --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60"
ID=think-triage-20260904180000; q $ID
rc=0; $CLI run-think --repo-slug $SLUG --session S --fence 999 --kind triage --model fable --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $ID >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$RD/think/$ID.launch.json" ]                                  # stale fence
$CLI run-think $ok --think-id $ID --add-dir tasks --add-dir think
python3 -c "import json;l=json.load(open('$RD/think/$ID.launch.json'));a=json.load(open('$RD/think/$ID.answer.json'));assert l['caps']['max_budget_usd']==3.0 and l['attempt']==1 and a['status']=='answered',(l,a)"
grep -qx -- "$RD/tasks" "$FAKE_CLAUDE_LOG.argv" && grep -qx -- "$RD/think" "$FAKE_CLAUDE_LOG.argv"
: > "$FAKE_CLAUDE_LOG.argv"
n=0
try() { n=$((n+1)); rc=0; $CLI run-think "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || { echo "expected 2 got $rc for: $*" >&2; exit 1; }; }
T="think-triage-2026090418"          # distinct ids per case: ${T}01xx
q ${T}0101; try $ok --think-id ${T}010                                         # 13-digit stamp
q ${T}0102; try $ok --think-id ${T}0102-3
q ${T}0103; try $ok --think-id think-Triage-20260904180103
q ${T}0104; try $ok --think-id think-other-20260904180104                       # kind disagrees
F2="--repo-slug $SLUG --session S --fence $FE --kind triage"
q ${T}0105; try $F2 --model sonnet --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id ${T}0105
q ${T}0106; try $F2 --model fable --effort inherit --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id ${T}0106
q ${T}0107; try $F2 --model fable --effort medium --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id ${T}0107
q ${T}0108; try $F2 --model fable --effort high --cwd $WT --max-turns 0 --max-budget-usd 3.0 --timeout-secs 60 --think-id ${T}0108
q ${T}0109-2; try $ok --think-id ${T}0109-2                                     # -2 without --parent
q ${T}0110; try $ok --think-id ${T}0110 --parent $ID                            # --parent with a non -2 id
q ${T}0111; try $ok --think-id ${T}0111 --add-dir owner
q ${T}0112; try $ok --think-id ${T}0112 --add-dir "$RD"
q ${T}0113; try $F2 --model fable --effort high --cwd "$(mktemp -d)" --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id ${T}0113   # non-git cwd
OTHER=$(mktemp -d); git -C "$OTHER" init -q; git -C "$OTHER" -c user.name=t -c user.email=t@x commit -q --allow-empty -m b; git -C "$OTHER" remote add origin https://github.com/org/elsewhere.git
q ${T}0114; try $F2 --model fable --effort high --cwd $OTHER --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id ${T}0114          # foreign repo
try $ok --think-id ${T}0115                                                     # question missing
printf 'q\n' > "$RD/think/${T}0116.real.md"; ln -s "$RD/think/${T}0116.real.md" "$RD/think/${T}0116.question.md"; try $ok --think-id ${T}0116
q ${T}0117; : > "$RD/think/${T}0199.launch.json"; rc=0; $CLI run-think $ok --think-id ${T}0117 >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 4 ] && [ ! -e "$RD/think/${T}0117.launch.json" ]; rm "$RD/think/${T}0199.launch.json"   # corrupt SIBLING launch record -> 4 (own id would hit the exists check, exit 2)
q ${T}0118; : > "$RD/think/${T}0118.answer.json"; try $ok --think-id ${T}0118; rm "$RD/think/${T}0118.answer.json"
[ ! -s "$FAKE_CLAUDE_LOG.argv" ]                                                # none of the refusals launched
for f in "$RD"/think/${T}01*.launch.json; do [ -e "$f" ] && { echo "unexpected $f" >&2; exit 1; }; done; true
SH

check "run-think limits: live sibling, lost sibling ignored, daily ceiling with reservation, retry rules, concurrency" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
git -C "$WT" remote add origin https://github.com/org/repo3.git
SLUG=$(python3 -c "import importlib.util;s=importlib.util.spec_from_file_location('c','claude/hooks/herdr_orch_core.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c);print(c.repo_slug('https://github.com/org/repo3.git'))")
RD="$CLAUDE_CONFIG_DIR/herdr-orch/$SLUG"; mkdir -p "$RD/think"
FE=$($CLI claim-owner --repo-slug $SLUG --session S --host h --pid 1)
export PATH="$FAKE_CLAUDE_DIR:$PATH" FAKE_CLAUDE_LOG="$RD/log" FAKE_CLAUDE_JSON="$RD/res.json"
q() { printf 'q\n' > "$RD/think/$1.question.md"; }
L() { printf '{"v":1,"think_id":"%s","kind":"%s","task_id":null,"repo_slug":"%s","model":"fable","effort":"high","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":60},"attempt":1,"parent":null,"started":"%s","pid":1}' "$1" "$2" "$SLUG" "$3" > "$RD/think/$1.launch.json"; }
A() { printf '{"v":1,"think_id":"%s","status":"%s","reason":%s,"answer":%s,"total_cost_usd":%s,"num_turns":%s,"started":"%s"}' "$1" "$2" "$3" "$4" "$5" "$6" "$7" > "$RD/think/$1.answer.json"; }
GOOD='{"recommendation":"do A","rationale":"because","options":[{"label":"A","summary":"s","tradeoffs":"t","risk":"low"},{"label":"B","summary":"s","tradeoffs":"t","risk":"medium"}],"confidence":"high"}'
ok="--repo-slug $SLUG --session S --fence $FE --kind other --model fable --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60"
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ); TODAY=$(date -u +%Y-%m-%d)
# live sibling -> 4, nothing written
L think-triage-20260904170000 triage "$NOW"; q think-other-20260904170100
rc=0; $CLI run-think $ok --think-id think-other-20260904170100 >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 4 ] && [ ! -e "$RD/think/think-other-20260904170100.launch.json" ]
# lost sibling (older than 60+120s) ignored -> proceeds
L think-triage-20260904170000 triage "2020-01-01T00:00:00Z"
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.5,"structured_output":%s}' "$GOOD" > "$FAKE_CLAUDE_JSON"
$CLI run-think $ok --think-id think-other-20260904170100 && [ -e "$RD/think/think-other-20260904170100.answer.json" ]
rm "$RD"/think/think-*
# daily ceiling: 2 answered at 3.0 + 1 null-cost unanswered reserved at 3.0 = 9.0; +3.0 > 10.0 -> 4; then a 1.0 cap fits
for n in 1 2 3; do L think-other-2026090410000$n other "${TODAY}T10:00:0${n}Z"; done
for n in 1 2; do A think-other-2026090410000$n answered null "$GOOD" 3.0 1 "${TODAY}T10:00:0${n}Z"; done
A think-other-20260904100003 unanswered '"error"' null null null "${TODAY}T10:00:03Z"
q think-other-20260904170200
rc=0; $CLI run-think $ok --think-id think-other-20260904170200 >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 4 ] && [ ! -e "$RD/think/think-other-20260904170200.launch.json" ]
$CLI run-think --repo-slug $SLUG --session S --fence $FE --kind other --model fable --effort high --cwd $WT --max-turns 15 --max-budget-usd 1.0 --timeout-secs 60 --think-id think-other-20260904170200
rm "$RD"/think/think-*
# retry rules
P=think-triage-20260904190000; q $P; q $P-2
L $P triage "2020-01-01T00:00:00Z"
PA() { printf '{"v":1,"think_id":"%s","kind":"%s","task_id":null,"model":"fable","status":"%s","reason":%s,"answer":%s,"model_attributable":%s,"total_cost_usd":%s,"num_turns":1,"started":"2020-01-01T00:00:00Z"}' "$P" "$1" "${5:-unanswered}" "${6:-\"error\"}" "${7:-null}" "$2" "$3" > "$RD/think/$P.answer.json"; }
R2="--repo-slug $SLUG --session S --fence $FE --kind triage --model opus --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $P-2 --parent $P"
t2() { rc=0; $CLI run-think "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq "$EXP" ] || { echo "expected $EXP got $rc for: $*" >&2; exit 1; }; [ ! -e "$RD/think/$P-2.launch.json" ]; }
PA triage false 1.0;  EXP=2 t2 $R2                                                          # parent not model-attributable
PA triage true 1.0 x answered null "$GOOD"; EXP=2 t2 $R2                                    # answered parent cannot be retried
PA triage true 1.0;   mv "$RD/think/$P.launch.json" "$RD/think/$P.launch.bak"; EXP=2 t2 $R2; mv "$RD/think/$P.launch.bak" "$RD/think/$P.launch.json"   # orphan parent answer (no launch)
PA triage true 1.0;   EXP=2 t2 --repo-slug $SLUG --session S --fence $FE --kind triage --model opus --effort high --cwd $WT --max-turns 15 --max-budget-usd 9.0 --timeout-secs 60 --think-id $P-2 --parent $P   # inflated retry cap
PA triage true 1.0;   EXP=2 t2 --repo-slug $SLUG --session S --fence $FE --kind triage --model fable --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $P-2 --parent $P   # same model
PA incident true 1.0; EXP=2 t2 $R2                                                          # parent kind differs
PA triage true 1.0;   printf 'different\n' > "$RD/think/$P-2.question.md"; EXP=2 t2 $R2; q $P-2
PA triage true null;  EXP=4 t2 $R2                                                          # null parent cost
PA triage true 2.9;   EXP=4 t2 $R2                                                          # remainder below 0.25
PA triage true 1.0
printf '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"num_turns":3,"total_cost_usd":2.0}' > "$FAKE_CLAUDE_JSON"
$CLI run-think $R2
grep -qx -- '2.0' "$FAKE_CLAUDE_LOG.argv"
python3 -c "import json;l=json.load(open('$RD/think/$P-2.launch.json'));a=json.load(open('$RD/think/$P-2.answer.json'));assert l['attempt']==2 and l['parent']=='$P' and l['caps']['max_budget_usd']==2.0 and a['reason']=='max_budget' and a['parent']=='$P',(l,a)"
rm "$RD"/think/think-*
# concurrency: two distinct ids racing -> exactly one launch record and one exit 4
IDA=think-other-20260904170400; IDB=think-other-20260904170500; q $IDA; q $IDB
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"total_cost_usd":0.1}' > "$FAKE_CLAUDE_JSON"
FAKE_CLAUDE_SLEEP=2 FAKE_CLAUDE_LOG="$RD/logA" $CLI run-think $ok --think-id $IDA >/dev/null 2>&1 & PA_=$!
FAKE_CLAUDE_SLEEP=2 FAKE_CLAUDE_LOG="$RD/logB" $CLI run-think $ok --think-id $IDB >/dev/null 2>&1 & PB_=$!
ra=0; wait $PA_ || ra=$?; rb=0; wait $PB_ || rb=$?
[ $((ra + rb)) -eq 4 ] && [ "$(ls "$RD/think/" | grep -c -E "($IDA|$IDB)\.launch\.json")" -eq 1 ]
SH

check "run-think retry: parent launch record missing task_id key does not crash" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
WT=$(mktemp -d); git -C "$WT" init -q; git -C "$WT" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
git -C "$WT" remote add origin https://github.com/org/repo-taskidkey.git
SLUG=$(python3 -c "import importlib.util;s=importlib.util.spec_from_file_location('c','claude/hooks/herdr_orch_core.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c);print(c.repo_slug('https://github.com/org/repo-taskidkey.git'))")
RD="$CLAUDE_CONFIG_DIR/herdr-orch/$SLUG"; mkdir -p "$RD/think"
FE=$($CLI claim-owner --repo-slug $SLUG --session S --host h --pid 1)
P=think-triage-20260904190500
printf 'q\n' > "$RD/think/$P.question.md"
printf 'q\n' > "$RD/think/$P-2.question.md"
# launch record with the task_id key entirely omitted (not an explicit null) -- still
# passes valid_launch_record, must not crash the retry cross-check with a bare KeyError
printf '{"v":1,"think_id":"%s","kind":"triage","repo_slug":"%s","model":"fable","effort":"high","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":900},"attempt":1,"parent":null,"started":"2020-01-01T00:00:00Z","pid":1}' "$P" "$SLUG" > "$RD/think/$P.launch.json"
printf '{"v":1,"think_id":"%s","kind":"triage","task_id":null,"model":"fable","status":"unanswered","reason":"error","answer":null,"model_attributable":true,"total_cost_usd":1.0,"num_turns":1,"started":"2020-01-01T00:00:00Z"}' "$P" > "$RD/think/$P.answer.json"
# matching (no --task-id passed, so ns.task_id is None -> equals the missing key's .get() default) -> succeeds cleanly, no traceback
rc=0; out=$($CLI run-think --repo-slug $SLUG --session S --fence $FE --kind triage --model opus --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $P-2 --parent $P 2>&1) || rc=$?
[ "$rc" -eq 0 ] || { echo "expected 0 got $rc: $out" >&2; exit 1; }
! printf '%s' "$out" | grep -q Traceback
rm "$RD/think/$P-2.launch.json" "$RD/think/$P-2.answer.json"
# mismatched --task-id against the missing-key parent -> exit 2, no traceback, no files written
rc=0; out=$($CLI run-think --repo-slug $SLUG --session S --fence $FE --kind triage --task-id PROJ-99 --model opus --effort high --cwd $WT --max-turns 15 --max-budget-usd 3.0 --timeout-secs 60 --think-id $P-2 --parent $P 2>&1) || rc=$?
[ "$rc" -eq 2 ] || { echo "expected 2 got $rc: $out" >&2; exit 1; }
! printf '%s' "$out" | grep -q Traceback
[ ! -e "$RD/think/$P-2.launch.json" ] && [ ! -e "$RD/think/$P-2.answer.json" ]
SH

check "status: _think fold, legacy workers effort unknown, watch includes think files" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-st --session S --host h --pid 1)
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-st"; mkdir -p "$RD/think"
TODAY=$(date -u +%Y-%m-%d)
L() { printf '{"v":1,"think_id":"%s","kind":"%s","task_id":null,"repo_slug":"slug-st","model":"fable","effort":"high","caps":{"max_turns":15,"max_budget_usd":3.0,"timeout_secs":%s},"attempt":1,"parent":null,"started":"%s","pid":1}' "$1" "$2" "$3" "$4" > "$RD/think/$1.launch.json"; }
GOOD='{"recommendation":"r","rationale":"w","options":[{"label":"a","summary":"s","tradeoffs":"t","risk":"low"},{"label":"b","summary":"s","tradeoffs":"t","risk":"low"}],"confidence":"high"}'
A() { if [ "$2" = answered ]; then R=null; AN="$GOOD"; else R='"error"'; AN=null; fi; printf '{"v":1,"think_id":"%s","status":"%s","reason":%s,"answer":%s,"total_cost_usd":%s,"num_turns":%s,"started":"%s"}' "$1" "$2" "$R" "$AN" "$3" "$4" "$5" > "$RD/think/$1.answer.json"; }
L think-triage-20260904100000 triage 900 "${TODAY}T10:00:00Z"; A think-triage-20260904100000 answered 1.12 6 "${TODAY}T10:00:00Z"
L think-other-20260904110000 other 900 "${TODAY}T11:00:00Z";  A think-other-20260904110000 answered 0.40 3 "${TODAY}T11:00:00Z"
L think-incident-20260904120000 incident 900 "${TODAY}T12:00:00Z"; A think-incident-20260904120000 unanswered null null "${TODAY}T12:00:00Z"
L think-decompose-20260904125900 decompose 900 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
L think-incident-20260903120000 incident 600 "2026-09-03T12:00:00Z"
printf '{"v":1,"trunc' > "$RD/think/think-other-20260904130000.answer.json"
printf '{"v":2,"think_id":"think-other-20260904140000"}' > "$RD/think/think-other-20260904140000.answer.json"
$CLI write-task --repo-slug slug-st --task-id PROJ-1 --session S --fence "$F" \
  --json '{"task_id":"PROJ-1","status":"in-progress","workers":[{"role":"impl","phase":"plan","model":"fable"},{"role":"impl","phase":"implement","model":"sonnet","effort":null},{"role":"review","phase":"review","model":"opus","effort":"high"}]}'
$CLI status --repo-slug slug-st | python3 -c "
import json,sys;s=json.load(sys.stdin);t=s['_think']
assert t=={'launches':5,'answered':2,'unanswered':1,'usd':1.52,'turns':9,'usd_today':7.52,'live':['think-decompose-20260904125900'],'lost':['think-incident-20260903120000'],'skipped_files':2,'corrupt':[]},t   # usd = actual spend; usd_today = committed (reserved) spend
assert s['PROJ-1']['workers_effort']==['unknown','inherit','high'],s['PROJ-1']"
rm -r "$RD/think"
$CLI status --repo-slug slug-st | python3 -c "import json,sys;t=json.load(sys.stdin)['_think'];assert t=={'launches':0,'answered':0,'unanswered':0,'usd':0.0,'turns':0,'usd_today':0.0,'live':[],'lost':[],'skipped_files':0,'corrupt':[]},t"
python3 - "$RD" <<'PY'
import importlib.util,sys,os,json
s=importlib.util.spec_from_file_location("c","claude/hooks/herdr_orch_core.py");c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
rd=sys.argv[1]; os.makedirs(os.path.join(rd,"think"),exist_ok=True)
assert "think" in c.WATCH_DIRS
snap0,_=c.watch_scan(rd,{})
open(os.path.join(rd,"think","think-triage-20260904150000.question.md"),"w").write("q")
snap0b,_=c.watch_scan(rd,snap0)
assert not c.watch_changed(snap0, snap0b)
open(os.path.join(rd,"think","think-triage-20260904150000.launch.json"),"w").write("{}")
snap1,_=c.watch_scan(rd,snap0); assert c.watch_changed(snap0,snap1)
open(os.path.join(rd,"think","think-triage-20260904150000.answer.json"),"w").write("{}")
snap2,_=c.watch_scan(rd,snap1)
assert c.watch_changed(snap1, snap2)
PY
SH

check "CLI claim-owner defaults control_tier=launcher when omitted" <<'SH'
root=$(mktemp -d)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-l --session S --host h --pid 1 >/dev/null
python3 -c 'import json,sys,os; rec=json.load(open(os.path.join(sys.argv[1],"herdr-orch","slug-l","owner.json"))); assert rec.get("control_tier","launcher")=="launcher", rec; assert rec.get("workspace_root") is None, rec' "$root"
SH

check "CLI claim-owner rejects control_tier=lead without workspace-root" <<'SH'
root=$(mktemp -d)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-x --session S --host h --pid 1 --control-tier lead 2>/dev/null; then exit 1; fi
SH

check "CLI claim-owner rejects workspace-root without lead" <<'SH'
root=$(mktemp -d); ws=$(mktemp -d)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-x --session S --host h --pid 1 --workspace-root "$ws" 2>/dev/null; then exit 1; fi
SH

check "CLI lead claim requires --binding and claims the per-workspace lease" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-lc.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" 2>/dev/null; then exit 1; fi
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
test "$lf" = 1
python3 -c '
import json, os, sys
root, bid, ws, slug = sys.argv[1:5]
slug_owner = json.load(open(os.path.join(os.environ["HERDR_COORDINATION_ROOT"], slug, "owner.json")))
assert slug_owner["session_id"] == "L1", slug_owner
assert slug_owner.get("control_tier", "launcher") == "launcher", slug_owner
rec = json.load(open(os.path.join(root, "herdr-orch", slug, "bindings", bid + ".json")))
assert rec["status"] == "claimed", rec
mirror = json.load(open(os.path.join(root, "herdr-orch", slug, "leads", bid, "owner.json")))
assert mirror["session_id"] == "S1" and mirror["binding_id"] == bid, mirror
assert mirror["workspace_root"] == os.path.realpath(ws), mirror
' "$root" "$bid" "$LF_WS" "$LF_SLUG"
SH

check "CLI lead claim rejects mismatched binding fields" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-mm.git
root=$(mktemp -d); ws2=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session WRONG --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$ws2" --binding "$bid" 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding ldb-00000000000000000000000000000000 2>/dev/null; then exit 1; fi
SH

check "CLI lead claim rejects a revoked binding; same-session reclaim renews" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rv.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
test "$lf" = 1
lf2=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
test "$lf2" = 2
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --status revoked
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" 2>/dev/null; then exit 1; fi
SH

check "CLI launcher claim rejects --binding; lead workspace-root still validated" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-wv.git
root=$(mktemp -d)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-x --session L1 --host h --pid 1 --binding ldb-00000000000000000000000000000000 2>/dev/null; then exit 1; fi
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root relative/ws --binding "$bid" 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root / --binding "$bid" 2>/dev/null; then exit 1; fi
SH

check "CLI lead claim rejects a binding recorded for a different account" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ac.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
python3 -c '
import json, os, sys
p = os.path.join(sys.argv[1], "herdr-orch", sys.argv[3], "bindings", sys.argv[2] + ".json")
rec = json.load(open(p)); rec["account_id"] = "someone-else"; json.dump(rec, open(p, "w"))
' "$root" "$bid" "$LF_SLUG"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" 2>/dev/null; then exit 1; fi
SH

check "read-side _valid_owner matches claim: rejects /, //, NUL, relative, empty" <<'SH'
python3 - <<'PY'
import sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as c
base = dict(session_id="S", host="h", pid=1, fence=1, heartbeat_ts=1.0)
assert c._valid_owner(dict(base, control_tier="lead", workspace_root="/tmp/ws"))
for bad in ("/", "//", "relative/ws", "/tmp/\x00bad", "", None):
    rec = dict(base, control_tier="lead", workspace_root=bad)
    assert not c._valid_owner(rec), ("accepted", bad)
assert c._valid_owner(dict(base))  # legacy launcher record still valid
PY
SH

check "legacy_seen observations persist base fields only (rollback-safe)" <<'SH'
python3 - <<'PY'
import sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as c
base_fields = {"session_id", "host", "pid", "fence", "heartbeat_ts",
               "runtime", "thread_id", "account_id"}
full = dict(session_id="S", host="h", pid=1, fence=1, heartbeat_ts=1.0,
            runtime="claude", thread_id=None, account_id="a",
            control_tier="lead", workspace_root="/tmp/ws")
obs = c._observation(full)
assert set(obs) == base_fields, sorted(obs)  # a rolled-back reader compares verbatim
# An entry persisted WITH extra fields (older HEAD builds) projects equal.
assert c._observation(dict(obs, control_tier="launcher", workspace_root=None)) == obs
PY
SH

check "bindings: id format, schema validation, transitions" <<'SH'
python3 - <<'PY'
import sys
sys.path.insert(0, "claude/hooks")
import herdr_bindings as b
bid = b.new_binding_id()
assert b.BINDING_ID_RE.fullmatch(bid), bid
assert not b.BINDING_ID_RE.fullmatch("ldb-XYZ")
assert not b.BINDING_ID_RE.fullmatch("ldb-" + "0" * 31)
good = {
    "schema_version": 1,
    "binding_id": bid,
    "parent": {"tier": "launcher", "task_id": "td-x", "session_id": "L1"},
    "tier": "lead",
    "task_id": "td-slice",
    "repo_id": None,
    "repo_slug": "slug-x",
    "workspace_root": "/tmp/ws",
    "account_id": "acct",
    "account_kind": "personal",
    "runtime": "claude",
    "expected_session_id": "S1",
    "created_fence": 3,
    "status": "issued",
    "created_ts": "2026-09-12T00:00:00Z",
    "updated_ts": "2026-09-12T00:00:00Z",
}
assert b.valid_binding(good)
for field, bad in [
    ("schema_version", 2),
    ("schema_version", True),
    ("schema_version", 1.0),
    ("binding_id", "nope"),
    ("tier", "launcher"),
    ("parent", {"tier": "lead", "task_id": "t", "session_id": "s"}),
    ("parent", {"tier": "launcher", "task_id": "", "session_id": "s"}),
    ("repo_slug", "Bad/Slug"),
    ("workspace_root", "/"),
    ("workspace_root", "relative"),
    ("runtime", "gpt"),
    ("expected_session_id", ""),
    ("created_fence", 0),
    ("status", "pending"),
    ("account_id", ""),
    ("account_kind", "corporate"),
    ("task_id", "../evil"),
]:
    rec = dict(good, **{field: bad})
    assert not b.valid_binding(rec), (field, bad)
assert b.can_transition("issued", "claimed")
assert b.can_transition("issued", "revoked")
assert b.can_transition("claimed", "completed")
assert b.can_transition("claimed", "revoked")
assert not b.can_transition("claimed", "issued")
assert not b.can_transition("completed", "revoked")
assert not b.can_transition("revoked", "claimed")
PY
SH

check "bindings: read_binding round-trip, absent None, corrupt raises" <<'SH'
python3 - <<'PY'
import json, os, sys, tempfile
sys.path.insert(0, "claude/hooks")
import herdr_bindings as b
from pathlib import Path
rd = Path(tempfile.mkdtemp())
bid = b.new_binding_id()
assert b.read_binding(rd, bid) is None
rec = {
    "schema_version": 1, "binding_id": bid,
    "parent": {"tier": "launcher", "task_id": "td-x", "session_id": "L1"},
    "tier": "lead", "task_id": "td-slice", "repo_id": None,
    "repo_slug": "slug-x", "workspace_root": "/tmp/ws",
    "account_id": "acct", "account_kind": "personal", "runtime": "claude",
    "expected_session_id": "S1", "created_fence": 3, "status": "issued",
    "created_ts": "t", "updated_ts": "t",
}
path = b.binding_path(rd, bid)
path.parent.mkdir(parents=True)
path.write_text(json.dumps(rec))
assert b.read_binding(rd, bid) == rec
path.write_text("not json")
try:
    b.read_binding(rd, bid)
except ValueError:
    pass
else:
    raise AssertionError("corrupt binding must raise")
path.write_text(json.dumps(dict(rec, status="pending")))
try:
    b.read_binding(rd, bid)
except ValueError:
    pass
else:
    raise AssertionError("invalid binding must raise")
# A symlinked binding file is rejected (no-follow read while locks are held).
path.write_text(json.dumps(rec))
target = rd / "elsewhere.json"
os.replace(path, target)
os.symlink(target, path)
try:
    b.read_binding(rd, bid)
except ValueError:
    pass
else:
    raise AssertionError("symlinked binding must raise")
os.remove(path)
try:
    b.binding_path(rd, "../escape")
except ValueError:
    pass
else:
    raise AssertionError("invalid binding_id must raise in binding_path")
PY
SH

check "issue-binding: launcher fence issues a valid issued binding" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ib.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-slice \
   --workspace-root "$LF_WS" --expected-session S1)
python3 -c '
import json, os, sys
sys.path.insert(0, "claude/hooks")
import herdr_bindings as b
root, bid, ws, slug = sys.argv[1:5]
rec = json.load(open(os.path.join(root, "herdr-orch", slug, "bindings", bid + ".json")))
assert b.valid_binding(rec), rec
assert rec["status"] == "issued" and rec["expected_session_id"] == "S1", rec
assert rec["workspace_root"] == os.path.realpath(ws), rec
assert rec["parent"]["tier"] == "launcher" and rec["parent"]["session_id"] == "L1", rec
' "$root" "$bid" "$LF_WS" "$LF_SLUG"
SH

check "issue-binding: rejected without a live launcher fence" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-nolf.git
root=$(mktemp -d)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence 1 --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1 2>/dev/null; then exit 1; fi
SH

check "issue-binding: rejected without repository context (--repo-path)" <<'SH'
root=$(mktemp -d); ws=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-noctx --session L1 --host h --pid 1)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug slug-noctx --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$ws" --expected-session S1 2>/dev/null; then exit 1; fi
SH

check "issue-binding: relative and root workspace-root rejected" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-ib2 --session L1 --host h --pid 1)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug slug-ib2 --session L1 --fence "$f" --task-id td-x \
   --workspace-root relative/ws --expected-session S1 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug slug-ib2 --session L1 --fence "$f" --task-id td-x \
   --workspace-root / --expected-session S1 2>/dev/null; then exit 1; fi
SH

check "set-binding-status: legal transitions only" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-tr.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --status revoked
python3 -c 'import json,os,sys; rec=json.load(open(os.path.join(sys.argv[1],"herdr-orch",sys.argv[3],"bindings",sys.argv[2]+".json"))); assert rec["status"]=="revoked", rec' "$root" "$bid" "$LF_SLUG"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --status completed 2>/dev/null; then exit 1; fi
SH

check "issue-binding: a lead-tier slug owner cannot issue (recursion bound)" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-nb.git
root=$(mktemp -d); ws=$(mktemp -d)
# Manufacture a slug owner record with control_tier=lead (a slice-1-era shape),
# then verify issue-binding refuses it: only a launcher owner issues bindings.
# ws2 is a real linked worktree of the fixture repo so the request actually
# reaches the control_tier check instead of failing provenance first.
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
python3 -c '
import json, os, sys
reg = os.path.join(os.environ["HERDR_COORDINATION_ROOT"], sys.argv[3], "owner.json")
rec = json.load(open(reg))
rec["control_tier"] = "lead"; rec["workspace_root"] = sys.argv[1]
json.dump(rec, open(reg, "w"))
mirror = os.path.join(sys.argv[2], "herdr-orch", sys.argv[3], "owner.json")
rec2 = json.load(open(mirror))
rec2["control_tier"] = "lead"; rec2["workspace_root"] = sys.argv[1]
json.dump(rec2, open(mirror, "w"))
' "$ws" "$root" "$LF_SLUG"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1 2>/dev/null; then exit 1; fi
SH

check "workspace_provenance_ok: linked worktree yes; primary checkout and foreign dir no" <<'SH'
python3 - <<'PY'
import os, subprocess, sys, tempfile
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
base = tempfile.mkdtemp()
repo = os.path.join(base, "repo")
os.mkdir(repo)
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
run = lambda *a, **k: subprocess.run(a, check=True, capture_output=True, env=env, **k)
run("git", "init", "-q", repo)
run("git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-q", "-m", "x")
wt = os.path.join(base, "wt")
run("git", "-C", repo, "worktree", "add", "-q", wt)
ctx = {"common_dir": os.path.realpath(os.path.join(repo, ".git"))}
assert core.workspace_provenance_ok(wt, ctx)
assert not core.workspace_provenance_ok(repo, ctx)          # primary checkout
foreign = tempfile.mkdtemp()
assert not core.workspace_provenance_ok(foreign, ctx)       # not a worktree of this repo
sub = os.path.join(repo, "sub")
os.makedirs(sub)
assert not core.workspace_provenance_ok(sub, ctx)           # subdir of primary checkout
wt_sub = os.path.join(wt, "sub")
os.makedirs(wt_sub)
assert not core.workspace_provenance_ok(wt_sub, ctx)        # subdir of linked worktree
# A primary checkout using --separate-git-dir has a common dir whose parent is
# NOT the checkout root, so the primary-vs-linked-worktree test must be
# git-dir identity (git-dir == common-dir), not path equality against the
# common dir's parent -- otherwise this primary would misclassify as a
# linked worktree.
meta = os.path.join(base, "repo2.git")
repo2 = os.path.join(base, "repo2")
run("git", "init", "-q", "--separate-git-dir", meta, repo2)
run("git", "-C", repo2, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-q", "-m", "x")
ctx2 = {"common_dir": os.path.realpath(meta)}
assert not core.workspace_provenance_ok(repo2, ctx2)        # separate-git-dir primary
PY
SH

check "write-task --binding routes to the lead subtree under the lead fence" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ws.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --task-id PROJ-9 --json '{"task_id":"PROJ-9"}'
test -f "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-9.json"
test ! -e "$root/herdr-orch/$LF_SLUG/tasks/PROJ-9.json"
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-index \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --workspace w1 --json '{"task_id":"PROJ-9","role":"impl"}'
test -f "$root/herdr-orch/$LF_SLUG/leads/$bid/workspaces/w1.json"
# Authorization reads the authoritative coordination lease, never the payload
# mirror: corrupting the mirror must not break a further write under the
# still-valid real lead fence.
python3 -c '
import json, os, sys
p = os.path.join(sys.argv[1], "herdr-orch", sys.argv[3], "leads", sys.argv[2], "owner.json")
json.dump({"session_id": "EVIL"}, open(p, "w"))
' "$root" "$bid" "$LF_SLUG"
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --task-id PROJ-10 --json '{"task_id":"PROJ-10"}'
test -f "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-10.json"
SH

check "cross-scope writes refused in both directions" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-xs.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
# Lead session+fence without --binding: no slug fence -> refused.
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" \
   --task-id PROJ-1 --json '{"task_id":"PROJ-1"}' 2>/dev/null; then exit 1; fi
# Launcher session+fence with the lead's --binding: the fence belongs to the
# slug owner, not the lead lease -> refused (cross-scope write).
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --task-id PROJ-1 --json '{"task_id":"PROJ-1"}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-1.json"
test ! -e "$root/herdr-orch/$LF_SLUG/tasks/PROJ-1.json"
SH

check "emit-done --binding: attempt-grounded, lands in the lead subtree, needs claimed binding" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-em.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id PROJ-2 \
   --json '{"task_id":"PROJ-2","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
# 1) emit-done WITHOUT the runtime attempt flags but WITH --binding -> refused.
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
   --repo-slug "$LF_SLUG" --binding "$bid" --task-id PROJ-2 --workspace w1 --agent mech-td-x \
   --phase implement --outcome completed --head-sha h1 --base-sha b0 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-2.done.json"
# 2) emit-done WITH matching runtime attempt flags + --binding -> succeeds.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-2 --workspace w1 \
   --agent mech-td-x --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40"
# 3) the record lands at leads/$bid/tasks/PROJ-2.done.json, not the launcher path.
test -f "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-2.done.json"
test ! -e "$root/herdr-orch/$LF_SLUG/tasks/PROJ-2.done.json"
# 4) revoke the binding (claimed -> revoked is a legal transition); a further
# emit-done with the same flags is then refused.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --status revoked
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-2 --workspace w1 \
   --agent mech-td-x --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" 2>/dev/null; then exit 1; fi
SH

check "emit-done superseded by a later lead binding on the same workspace is refused" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-sup.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
# Binding A, claimed by lead session SA.
bidA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" --task-id PROJ-4 \
   --json '{"task_id":"PROJ-4","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
# Binding B is issued for the SAME workspace, to a different expected session,
# and claimed with --stale-secs 0 so it can take over the workspace over A's
# still-live claim (a live takeover, not a crash-recovery scenario).
bidB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
lfB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" --task-id PROJ-4 \
   --json '{"task_id":"PROJ-4","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
# A's binding is still "claimed" (nothing transitioned it), but the workspace
# lease now names binding B -- an emit under A must be refused.
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bidA" --task-id PROJ-4 --workspace w1 \
   --agent mech-td-a --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bidA/tasks/PROJ-4.done.json"
# An emit under B, the current lease holder, succeeds.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bidB" --task-id PROJ-4 --workspace w1 \
   --agent mech-td-b --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40"
test -f "$root/herdr-orch/$LF_SLUG/leads/$bidB/tasks/PROJ-4.done.json"
SH

check "a superseded binding cannot re-claim the workspace lease" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-resup.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
# Binding A, claimed by lead session SA -- fence 1.
bidA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-ra \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
test "$lfA" = 1
# Binding B, issued for the SAME workspace to a different session, takes over
# with --stale-secs 0 -- fence 2. A's binding stays "claimed" (nothing
# transitioned it) but the workspace lease now names B.
bidB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-rb \
   --workspace-root "$LF_WS" --expected-session SB)
lfB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0)
test "$lfB" = 2
# A's session tries to re-claim under binding A -- its own binding record is
# still "claimed" and names SA, so the old (pre-fix) renewal rule would let
# this mint fence 3 and revive A's emits. It must be refused instead. Pass
# --stale-secs 0 so a rejection cannot instead come from B's fresh lease
# still being busy -- only the superseded-generation guard is being tested.
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA" --stale-secs 0 2>/dev/null; then exit 1; fi
# The authoritative lease (not just a per-binding mirror) still names B.
key=$(python3 -c 'import os, sys; sys.path.insert(0,"claude/hooks"); import herdr_coordination as c; print(c.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
leaseholder=$(python3 -c "
import json
print(json.load(open('$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$key.json'))['binding_id'])
")
test "$leaseholder" = "$bidB"
# A's own owner mirror is untouched by the failed reclaim (still fence 1);
# B's mirror still shows the fence 2 takeover.
faz=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import json
print(json.load(open('$root/herdr-orch/$LF_SLUG/leads/$bidA/owner.json'))['fence'])
")
test "$faz" = 1
fbz=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import json
print(json.load(open('$root/herdr-orch/$LF_SLUG/leads/$bidB/owner.json'))['fence'])
")
test "$fbz" = 2
SH

check "emit-review --binding lands in the lead subtree" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-er.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
HEAD40=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id PROJ-3 \
   --json '{"task_id":"PROJ-3","base_sha":"'"$SHA40"'","review_head_sha":"'"$HEAD40"'","workers":[{"role":"mech","launch_id":"L1","phase":"review","runtime":"claude","workspace_id":"w9","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-3 --workspace w9 \
   --agent rev-proj-3 --reviewed-head-sha "$HEAD40" --reviewed-base-sha "$SHA40" --outcome approved \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" \
   --reviewer-session R1
test -f "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-3.review.json"
test ! -e "$root/herdr-orch/$LF_SLUG/tasks/PROJ-3.review.json"
SH

check "emit-done --binding refuses a task record with no native attempt" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-noatt.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-noatt \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
# A binding-scoped task record with no workers at all -- the legacy-permissive
# fallback in attempt_matches (no matching workers -> match) exists only to
# keep pre-native task history readable; a NEW binding-scoped record must
# never benefit from it.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id PROJ-6 \
   --json '{"task_id":"PROJ-6"}'
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-6 --workspace w1 \
   --agent mech-td-noatt --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-6.done.json"
# emit-review shares the same check (one guard before attempt_matches covers
# both verbs); same attemptless task record, refused the same way.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id PROJ-7 \
   --json '{"task_id":"PROJ-7"}'
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-7 --workspace w1 \
   --agent rev-proj-7 --reviewed-head-sha h1 --outcome approved \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-7.review.json"
SH

check "emit-done --binding rejects a non-id binding before touching the filesystem" <<'SH'
root=$(mktemp -d)
esc="$(mktemp -d)/evil"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
   --repo-slug slug-escbind --binding "$esc" --task-id PROJ-9 --workspace w1 \
   --agent mech-td-x --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   2>/dev/null; then exit 1; fi
test ! -e "$esc/tasks"
test ! -e "$esc"
SH

check "envelope: each outcome round-trips valid_envelope; strict keys enforced" <<PY
$LOAD
import importlib.util as iu
espec=iu.spec_from_file_location("env","claude/hooks/herdr_envelope.py")
e=iu.module_from_spec(espec);espec.loader.exec_module(e)
SHA="a"*40
def base(outcome, pr=None, ebs=None, reason=None, fu=None):
    return {"schema_version":1,"binding_id":"ldb-"+"0"*32,"task_id":"PROJ-1",
        "attempt":{"launch_id":"L1","phase":"implement","runtime":"claude",
                   "workspace_id":"w1","pane_id":"p1","source_head_sha":SHA},
        "fence":1,"sequence":1,"ts":"2026-09-12T00:00:00Z",
        "summary":{"outcome":outcome,"pr":pr,"expected_base_sha":ebs,
                   "reason":reason,"follow_ups":fu if fu is not None else []}}
PR={"repo_id":None,"number":7,"branch":"b","head_sha":SHA,
    "approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude",
                "reviewed_head_sha":SHA}}
assert e.valid_envelope(base("pr_ready", pr=PR, ebs=SHA))
assert e.valid_envelope(base("blocked", reason="waiting on decision"))
assert e.valid_envelope(base("failed", reason="suite red"))
assert e.valid_envelope(base("cancelled"))
assert e.valid_envelope(base("cancelled", reason="superseded"))
# unused fields must be explicitly null, not absent and not populated
bad=base("blocked", reason="r"); bad["summary"]["pr"]=PR
assert not e.valid_envelope(bad)
bad=base("pr_ready", pr=PR, ebs=SHA); del bad["summary"]["reason"]
assert not e.valid_envelope(bad)
bad=base("pr_ready", pr=PR, ebs=SHA); bad["summary"]["extra"]="x"
assert not e.valid_envelope(bad)
bad=base("pr_ready", pr=dict(PR, extra=1), ebs=SHA)
assert not e.valid_envelope(bad)
bad=base("pr_ready", pr=PR, ebs=SHA); bad["extra"]="x"
assert not e.valid_envelope(bad)
# identity / enum / shape failures
assert not e.valid_envelope(base("shipped"))
assert not e.valid_envelope(dict(base("cancelled"), schema_version=2))
assert not e.valid_envelope(dict(base("cancelled"), binding_id="ldb-xyz"))
assert not e.valid_envelope(dict(base("cancelled"), sequence=0))
assert not e.valid_envelope(dict(base("cancelled"), fence=0))
att=dict(base("cancelled")["attempt"], phase="review")
assert not e.valid_envelope(dict(base("cancelled"), attempt=att))
PY

check "envelope: staleness, caps, and follow_up shape reject deterministically" <<PY
$LOAD
import importlib.util as iu, json
espec=iu.spec_from_file_location("env","claude/hooks/herdr_envelope.py")
e=iu.module_from_spec(espec);espec.loader.exec_module(e)
SHA="a"*40; SHB="b"*40
def base(outcome, pr=None, ebs=None, reason=None, fu=None):
    return {"schema_version":1,"binding_id":"ldb-"+"0"*32,"task_id":"PROJ-1",
        "attempt":{"launch_id":"L1","phase":"implement","runtime":"claude",
                   "workspace_id":"w1","pane_id":"p1","source_head_sha":SHA},
        "fence":1,"sequence":1,"ts":"2026-09-12T00:00:00Z",
        "summary":{"outcome":outcome,"pr":pr,"expected_base_sha":ebs,
                   "reason":reason,"follow_ups":fu if fu is not None else []}}
stale={"repo_id":None,"number":7,"branch":"b","head_sha":SHA,
       "approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude",
                   "reviewed_head_sha":SHB}}
assert not e.valid_envelope(base("pr_ready", pr=stale, ebs=SHA))
assert not e.valid_envelope(base("blocked", reason="x"*(e.ENVELOPE_MAX_STR+1)))
fus=[{"kind":"todo","ref":"t%d"%i} for i in range(e.ENVELOPE_MAX_FOLLOW_UPS+1)]
assert not e.valid_envelope(base("blocked", reason="r", fu=fus))
assert not e.valid_envelope(base("blocked", reason="r", fu=[{"kind":"note","ref":"x"}]))
assert not e.valid_envelope(base("blocked", reason="r", fu=[{"kind":"todo"}]))
assert not e.valid_envelope(base("blocked", reason="r", fu=["free text"]))
ok=base("blocked", reason="r", fu=[{"kind":"todo","ref":"td-1"},{"kind":"handoff","ref":"h-1"}])
assert e.valid_envelope(ok)
# free-text refs rejected: a reference is an identifier, never prose
assert not e.valid_envelope(base("blocked", reason="r",
    fu=[{"kind":"todo","ref":"a private conversation body"}]))
assert not e.valid_envelope(base("blocked", reason="r",
    fu=[{"kind":"todo","ref":"x"*201}]))
# byte cap fires unconditionally: attempt strings have no per-leaf cap, so a
# long launch_id pushes the record past ENVELOPE_MAX_BYTES while every other
# check stays green
over=base("blocked", reason="r")
over["attempt"]=dict(over["attempt"], launch_id="L"*e.ENVELOPE_MAX_BYTES)
assert not e.valid_envelope(over)
assert len(json.dumps(base("cancelled"),separators=(",",":")).encode()) < e.ENVELOPE_MAX_BYTES
PY

check "envelope: path validation and fail-closed read" <<PY
$LOAD
import importlib.util as iu, json, pathlib
espec=iu.spec_from_file_location("env","claude/hooks/herdr_envelope.py")
e=iu.module_from_spec(espec);espec.loader.exec_module(e)
rd=pathlib.Path(tempfile.mkdtemp())
bid="ldb-"+"0"*32
try:
    e.envelope_path(rd,"ldb-short"); raise AssertionError("accepted bad id")
except ValueError: pass
assert e.read_envelope(rd,bid) is None
p=e.envelope_path(rd,bid); p.parent.mkdir(parents=True)
p.write_text("{not json")
try:
    e.read_envelope(rd,bid); raise AssertionError("read corrupt")
except ValueError: pass
p.write_text(json.dumps({"schema_version":1,"binding_id":bid}))
try:
    e.read_envelope(rd,bid); raise AssertionError("read invalid")
except ValueError: pass
SHA="a"*40
rec={"schema_version":1,"binding_id":bid,"task_id":"PROJ-1",
     "attempt":{"launch_id":"L1","phase":"implement","runtime":"claude",
                "workspace_id":"w1","pane_id":"p1","source_head_sha":SHA},
     "fence":1,"sequence":1,"ts":"t",
     "summary":{"outcome":"cancelled","pr":None,"expected_base_sha":None,
                "reason":None,"follow_ups":[]}}
p.write_text(json.dumps(rec))
assert e.read_envelope(rd,bid)["sequence"] == 1
other="ldb-"+"1"*32
q=e.envelope_path(rd,other); q.parent.mkdir(parents=True); q.write_text(json.dumps(rec))
try:
    e.read_envelope(rd,other); raise AssertionError("binding_id mismatch accepted")
except ValueError: pass
PY

check "emit-review --binding requires and records reviewer_session_id; plain path unchanged" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ri.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id PROJ-5 \
   --json '{"task_id":"PROJ-5","base_sha":"'"$SHA40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"review","launch_id":"L1","phase":"review","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
# binding-scoped review emit WITHOUT --reviewer-session -> refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-5 --workspace w1 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$SHA40" --blocking-count 0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-5.review.json"
# WITH --reviewer-session -> succeeds and records it
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-5 --workspace w1 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$SHA40" --blocking-count 0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" \
   --reviewer-session R1
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["reviewer_session_id"] == "R1", rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-5.review.json"
# plain (non-binding) review emit still works with no flag, record has no field
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --task-id PROJ-6 --workspace w1 --agent rev-p6 \
   --outcome approved --reviewed-head-sha "$SHA40" --blocking-count 0
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert "reviewer_session_id" not in rec, rec
' "$root/herdr-orch/$LF_SLUG/tasks/PROJ-6.review.json"
SH

check "emit-envelope: pr_ready round-trips under lease+attempt+approval grounding" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev1.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
# issue-binding's --repo-path resolves a real repository identity, so the
# binding's repo_id is never null here; capture it for the PR grounding check.
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
# task record: native implement + review attempts, dispatched review SHA
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["schema_version"] == 1 and rec["sequence"] == 1, rec
assert rec["binding_id"] == sys.argv[2] and rec["fence"] == int(sys.argv[3]), rec
assert rec["summary"]["outcome"] == "pr_ready", rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json" "$bid" "$lf"
SH

check "emit-envelope refusals: identity, sequence, independence, staleness, size, revocation" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev2.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
# issue-binding's --repo-path resolves a real repository identity, so the
# binding's repo_id is never null here; capture it for the PR grounding check.
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
BLOCKED='{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":SEQ,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# wrong session / wrong fence -> refused (not the lease holder)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session WRONG --fence "$lf" --binding "$bid" \
   --json "$(printf '%s' "$BLOCKED" | sed s/SEQ/1/)" 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence 999 --binding "$bid" \
   --json "$(printf '%s' "$BLOCKED" | sed s/SEQ/1/)" 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# valid blocked emit at sequence 2
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$(printf '%s' "$BLOCKED" | sed s/SEQ/2/)"
# duplicate and stale sequence -> refused; higher accepted
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$(printf '%s' "$BLOCKED" | sed s/SEQ/2/)" 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$(printf '%s' "$BLOCKED" | sed s/SEQ/1/)" 2>/dev/null; then exit 1; fi
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$(printf '%s' "$BLOCKED" | sed s/SEQ/5/)"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["sequence"] == 5
' "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# pr_ready whose approval names a reviewer absent from the stored review
# record (still R1) -> refused by the identity-match gate before any write.
# The lead-as-reviewer independence gate has its own check below: a same-head
# reviewer re-emit is now refused by the verdict-flip guard, so it cannot be
# staged by re-emitting the record at this head.
PRJSON='{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":6,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"b","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"RS","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$(printf '%s' "$PRJSON" | sed s/RS/R9/)" 2>/dev/null; then exit 1; fi
# oversized reason -> deterministic REJECT, stored envelope unchanged
BIG=$(python3 -c 'print("x"*600)')
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":7,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"'"$BIG"'","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["sequence"] == 5
' "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# revoked binding -> refused
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --status revoked
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$(printf '%s' "$BLOCKED" | sed s/SEQ/8/)" 2>/dev/null; then exit 1; fi
SH

check "emit-envelope: attempt grounding requires native implement row and pane match" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev3.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"paneX","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# Dropping the implement row entirely is dispatch-history tampering that
# write-task's append-only guard now refuses, so this exercises the tamper
# path directly (a raw file write) rather than through the CLI.
python3 -c '
import json, sys
json.dump(
    {"task_id": "td-x", "workers": [
        {"role": "review", "launch_id": "L2", "phase": "review",
         "runtime": "claude", "workspace_id": "w2", "pane_id": "pane2",
         "source_head_sha": sys.argv[2]},
    ]},
    open(sys.argv[1], "w"),
)
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.json" "$SHA40"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
SH

check "integrate-envelope: expected-base gate, launcher-only, one-shot accept" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig1.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
# issue-binding's --repo-path resolves a real repository identity, so the
# binding's repo_id is never null here; capture it for the PR grounding check.
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
MOVED40=$(printf 'c%.0s' $(seq 1 40))
# lead session cannot integrate
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40" 2>/dev/null; then exit 1; fi
# base moved -> exit 3, binding stays claimed
rc=0
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$MOVED40" --head-sha "$SHA40" 2>/dev/null || rc=$?
test "$rc" = 3
# branch head moved past the approved revision -> exit 3, binding stays claimed
rc=0
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$MOVED40" 2>/dev/null || rc=$?
test "$rc" = 3
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# pr_ready without --base-sha or without --head-sha -> refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --head-sha "$SHA40" 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" 2>/dev/null; then exit 1; fi
# matching base + head -> accepted, JSON line, binding completed
out=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40")
printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["outcome"] == "pr_ready" and rec["pr"]["number"] == 9, rec
'
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "completed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# second integrate -> idempotent retry: the binding is completed and the
# consumption record matches the stored envelope (sequence + digest), so
# the recorded success is reported again -- byte-identical output.
out2=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40")
test "$out2" = "$out"
# ONLY that exact case: a consumed record that no longer matches the stored
# envelope refuses as before (no invented success).
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["sequence"] = 2
json.dump(rec, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.consumed.json"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "not claimed" "$ERRFILE"
SH

check "integrate-envelope: serial integration of parallel PR-ready branches" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig2.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
git -C "$LF_REPO" worktree add -q "$LF_WSBASE/wt2"
LF_WS2="$LF_WSBASE/wt2"
bidA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
bidB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS2" --expected-session SB)
lfA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
lfB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS2" --binding "$bidB")
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bidA')['repo_id'])
")
BASE40=$(printf 'b%.0s' $(seq 1 40))
MOVED40=$(printf 'c%.0s' $(seq 1 40))
HA=$(printf 'd%.0s' $(seq 1 40))
HB=$(printf 'e%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" --task-id td-a \
   --json '{"task_id":"td-a","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$HA"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$HA"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$HA"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" --task-id td-b \
   --json '{"task_id":"td-b","status":"completed","base_sha":"'"$MOVED40"'","review_head_sha":"'"$HB"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$HB"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$HB"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bidA" --task-id td-a --workspace w2 \
   --agent rev-td-a --outcome approved --reviewed-head-sha "$HA" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$HA" \
   --reviewer-session RA
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bidB" --task-id td-b --workspace w2 \
   --agent rev-td-b --outcome approved --reviewed-head-sha "$HB" --reviewed-base-sha "$MOVED40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$HB" \
   --reviewer-session RB
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" \
   --json '{"task_id":"td-a","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$HA"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-a","head_sha":"'"$HA"'","approval":{"reviewer_session_id":"RA","reviewer_runtime":"claude","reviewed_head_sha":"'"$HA"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" \
   --json '{"task_id":"td-b","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$HB"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":10,"branch":"talon/td-b","head_sha":"'"$HB"'","approval":{"reviewer_session_id":"RB","reviewer_runtime":"claude","reviewed_head_sha":"'"$HB"'"}},"expected_base_sha":"'"$MOVED40"'","reason":null,"follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidA" \
   --base-sha "$BASE40" --head-sha "$HA"
rc=0
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidB" \
   --base-sha "$BASE40" --head-sha "$HB" 2>/dev/null || rc=$?
test "$rc" = 3
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidB" \
   --base-sha "$MOVED40" --head-sha "$HB"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "completed"
assert json.load(open(sys.argv[2]))["status"] == "completed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bidA.json" "$root/herdr-orch/$LF_SLUG/bindings/$bidB.json"
SH

check "integrate-envelope: tamper window (rewritten review record refused)" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig3.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
MOVED40=$(printf 'c%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
python3 -c '
import json, sys
p = sys.argv[1]
rec = json.load(open(p))
rec["reviewed_head_sha"] = sys.argv[2]
json.dump(rec, open(p, "w"))
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json" "$MOVED40"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "integrate-envelope: non-PR outcomes and missing envelope" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig4.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
# no envelope emitted yet -> refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>/dev/null; then exit 1; fi
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "completed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "interrupted integrate resumes from consumption record" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig-resume.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
BINDING="$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
CONSUMED="$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.consumed.json"
python3 -c '
import json, re, sys
rec = json.load(open(sys.argv[1]))
assert rec["sequence"] == 1, rec
assert re.fullmatch(r"[0-9a-f]{64}", rec["envelope_sha256"]), rec
' "$CONSUMED"
before=$(cat "$CONSUMED")
# simulate the crash window: rewrite the binding back to claimed
python3 -c '
import json, sys
p = sys.argv[1]
rec = json.load(open(p))
rec["status"] = "claimed"
json.dump(rec, open(p, "w"))
' "$BINDING"
# re-run integrate: resumes and completes again
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "completed"
' "$BINDING"
after=$(cat "$CONSUMED")
test "$before" = "$after"
SH

check "emit refuses after consumption; integrate refuses digest mismatch" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig-digest.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
BINDING="$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
ENVELOPE="$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# reset binding to claimed AND bump the stored envelope's sequence via a
# direct file rewrite (keeps it valid_envelope but changes the digest):
python3 -c '
import json, sys
p = sys.argv[1]
rec = json.load(open(p))
rec["status"] = "claimed"
json.dump(rec, open(p, "w"))
' "$BINDING"
python3 -c '
import json, sys
p = sys.argv[1]
rec = json.load(open(p))
rec["sequence"] += 1
json.dump(rec, open(p, "w"), separators=(",", ":"))
' "$ENVELOPE"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":3,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"still waiting","follow_ups":[]}}' \
   2>"$ERRFILE"; then exit 1; fi
grep -q "already integrated" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   2>"$ERRFILE"; then exit 1; fi
grep -q "consumed record does not match" "$ERRFILE"
SH

check "consumption freezes binding-scoped writers; null record is corrupt" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig-freeze.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
BINDING="$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
CONSUMED="$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.consumed.json"
# simulate the crash window: the consumption record is durably recorded but
# the binding transition to completed has not yet landed, and the lead lease
# is still live -- every binding-scoped writer must refuse regardless.
python3 -c '
import json, sys
p = sys.argv[1]
rec = json.load(open(p))
rec["status"] = "claimed"
json.dump(rec, open(p, "w"))
' "$BINDING"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}],"status":"blocked"}' \
   2>"$ERRFILE"; then exit 1; fi
grep -q "writes are frozen" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-index \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --workspace w1 \
   --json '{"workspace_id":"w1"}' 2>"$ERRFILE"; then exit 1; fi
grep -q "writes are frozen" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w1 \
   --agent mech-td-x --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" \
   2>"$ERRFILE"; then exit 1; fi
grep -q "writes are frozen" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w1 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$SHA40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1 \
   2>"$ERRFILE"; then exit 1; fi
grep -q "writes are frozen" "$ERRFILE"
# a consumed file holding JSON null is corrupt, not absent:
printf 'null' > "$CONSUMED"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   2>"$ERRFILE"; then exit 1; fi
grep -q "consumption record is unreadable" "$ERRFILE"
SH

check "integrate-envelope: superseded binding cannot integrate" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig5.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bidA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" --task-id td-a \
   --json '{"task_id":"td-a","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" \
   --json '{"task_id":"td-a","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# Binding B is issued for the SAME workspace and claimed with --stale-secs 0,
# taking over the workspace lease over A's still-live claim; A stays claimed.
bidB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
lfB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidA" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bidA.json"
SH

check "integrate refuses after successor claim even with successor lease deleted" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig-delease.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bidA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" --task-id td-a \
   --json '{"task_id":"td-a","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" \
   --json '{"task_id":"td-a","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# Binding B is issued for the SAME workspace and claimed with --stale-secs 0,
# taking over the workspace lease over A's still-live claim; A stays claimed.
bidB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
lfB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0)
# Tamper path: delete B's successor lease file directly. The registry's
# lead_ws entry (written by claim-owner) survives file deletion and must
# still name B as the durable occupant, so A's integrate stays refused.
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 - "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" <<'PY'
import os, sys
os.unlink(sys.argv[1])
PY
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidA" 2>"$ERRFILE"; then exit 1; fi
grep -q "workspace occupancy superseded" "$ERRFILE"
SH

check "set-binding-status: completed is refused outright; revoked still works" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-sbc.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
test "$lf" = 1
# completed is refused outright, bypassing integrate-envelope is not allowed.
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --status completed 2>/dev/null; then exit 1; fi
python3 -c '
import json, os, sys
root, bid, slug = sys.argv[1:4]
rec = json.load(open(os.path.join(root, "herdr-orch", slug, "bindings", bid + ".json")))
assert rec["status"] == "claimed", rec
' "$root" "$bid" "$LF_SLUG"
# revoked is unaffected by the completed refusal.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --status revoked
python3 -c '
import json, os, sys
root, bid, slug = sys.argv[1:4]
rec = json.load(open(os.path.join(root, "herdr-orch", slug, "bindings", bid + ".json")))
assert rec["status"] == "revoked", rec
' "$root" "$bid" "$LF_SLUG"
SH

check "emit-envelope: lead-as-reviewer refused by the independence gate" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev-indep.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
# The review record names the LEAD session S1 as reviewer from its FIRST emit,
# so the envelope's approval identity matches the record and only the
# independence gate fires (no same-head verdict flip is needed).
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session S1
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"S1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
SH

check "envelope schema: nullable attempt, ref-safe branch, control-char reason" <<PY
$LOAD
import importlib.util as iu
espec=iu.spec_from_file_location("env","claude/hooks/herdr_envelope.py")
e=iu.module_from_spec(espec);espec.loader.exec_module(e)
SHA="a"*40
def base(outcome, pr=None, ebs=None, reason=None, fu=None, attempt="_"):
    att=({"launch_id":"L1","phase":"implement","runtime":"claude",
          "workspace_id":"w1","pane_id":"p1","source_head_sha":SHA}
         if attempt=="_" else attempt)
    return {"schema_version":1,"binding_id":"ldb-"+"0"*32,"task_id":"PROJ-1",
        "attempt":att,"fence":1,"sequence":1,"ts":"2026-09-12T00:00:00Z",
        "summary":{"outcome":outcome,"pr":pr,"expected_base_sha":ebs,
                   "reason":reason,"follow_ups":fu if fu is not None else []}}
PR={"repo_id":None,"number":7,"branch":"b","head_sha":SHA,
    "approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":SHA}}
# a null attempt is a terminal handback before any implement dispatch
assert e.valid_envelope(base("blocked", reason="waiting", attempt=None))
assert e.valid_envelope(base("failed", reason="suite red", attempt=None))
assert e.valid_envelope(base("cancelled", attempt=None))
# pr_ready keeps a mandatory full attempt
assert not e.valid_envelope(base("pr_ready", pr=PR, ebs=SHA, attempt=None))
# ref-unsafe branches rejected: whitespace, "..", leading "-"
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="a b"), ebs=SHA))
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="a..b"), ebs=SHA))
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="-x"), ebs=SHA))
# a well-formed branch still validates
assert e.valid_envelope(base("pr_ready", pr=dict(PR, branch="talon/td-x"), ebs=SHA))
# git-ref subset rejections: "//", trailing "/", trailing ".", ".lock", "/."
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="a//b"), ebs=SHA))
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="a/"), ebs=SHA))
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="a."), ebs=SHA))
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="a.lock"), ebs=SHA))
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="a/.b"), ebs=SHA))
# a ".lock" suffix on any path component is rejected, not just the whole ref
assert not e.valid_envelope(base("pr_ready", pr=dict(PR, branch="feature.lock/topic"), ebs=SHA))
# ".lockx" only resembles the forbidden suffix; a component ending in it is fine
assert e.valid_envelope(base("pr_ready", pr=dict(PR, branch="feature.lockx/topic"), ebs=SHA))
# a dotted, hierarchical branch is still valid
assert e.valid_envelope(base("pr_ready", pr=dict(PR, branch="feature/x.y-z"), ebs=SHA))
# a control character in reason is rejected
assert not e.valid_envelope(base("blocked", reason="line1\nline2"))
assert not e.valid_envelope(base("failed", reason="tab\there"))
PY

check "emit-envelope: blocked with attempt null succeeds when no implement row exists" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev-null.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
# task record exists but carries NO implement row
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"blocked before any dispatch","follow_ups":[]}}'
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["attempt"] is None and rec["summary"]["outcome"] == "blocked", rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
SH

check "emit-envelope: duplicate --json key and oversized raw --json refused" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev-raw.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[]}'
# a duplicate top-level key is rejected by the parse hook
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","task_id":"td-x","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"dup","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# a raw --json larger than ENVELOPE_MAX_RAW is rejected before parsing
BIG=$(python3 -c 'import sys;sys.path.insert(0,"claude/hooks");import herdr_envelope as e;print("x"*(e.ENVELOPE_MAX_RAW+1))')
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"'"$BIG"'","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
SH

check "emit-review verdict-flip: outcome/blocking-count/findings swap at one head refused, identical re-emit allowed" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-vf.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$SHA40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
# approved, blocking-count 1, findings F1 at head SHA40 (baseline record)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$SHA40" --blocking-count 1 --findings-ref F1 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
# blocking-count flip (approved bc 0) at the SAME head/reviewer -> refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$SHA40" --blocking-count 0 --findings-ref F1 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["outcome"] == "approved" and rec["blocking_count"] == 1, rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
# findings_ref swap at the SAME head/reviewer -> refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$SHA40" --blocking-count 1 --findings-ref F2 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["findings_ref"] == "F1"
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
# outcome flip (changes-requested) at the SAME head -> refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome changes-requested --reviewed-head-sha "$SHA40" --reviewed-base-sha "$SHA40" --blocking-count 2 --findings-ref F1 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["outcome"] == "approved"
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
# an identical re-emit (same outcome/reviewer/blocking-count/findings) is allowed
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$SHA40" --blocking-count 1 --findings-ref F1 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["outcome"] == "approved" and rec["blocking_count"] == 1 and rec["findings_ref"] == "F1", rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
SH

check "emit-review --binding: intermediate-head dance refused until review_head_sha advances" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ihd.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
H=$(printf 'a%.0s' $(seq 1 40))
H2=$(printf 'c%.0s' $(seq 1 40))
# task dispatched a review at head H
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$H"'","review_head_sha":"'"$H"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"}]}'
# a verdict naming H2 while the task still dispatches H -> refused (dispatched review head)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H2" --reviewed-base-sha "$H" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H2" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
# advance the dispatched review head to H2 (the new attempt is appended, not
# substituted -- dispatch history is append-only); approved@H2 then succeeds
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$H"'","review_head_sha":"'"$H2"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H2"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H2" --reviewed-base-sha "$H" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H2" \
   --reviewer-session R1
# a verdict back at the old head H (task still dispatches H2) -> refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$H" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["reviewed_head_sha"] == sys.argv[2]
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json" "$H2"
SH

check "integrate-envelope: stale blocked envelope refused after a successor implement attempt" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig-stale.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
# implement attempt I1 recorded, blocked envelope grounded to it
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# a successor implement attempt I2 (different launch/pane) is appended
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"mech","launch_id":"L3","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"paneB","source_head_sha":"'"$SHA40"'"}]}'
# integrate now refused: the envelope's I1 no longer matches the latest row I2
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "null-attempt envelope symmetry: emit refused with an implement row; integrate refused once one appears" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev-nullsym.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bidA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
SHA40=$(printf 'a%.0s' $(seq 1 40))
# part 1: a task WITH an implement row rejects a null-attempt emit
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" --task-id td-a \
   --json '{"task_id":"td-a","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" \
   --json '{"task_id":"td-a","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bidA/envelope.json"
# part 2: a second binding whose task has NO implement row accepts a null-attempt emit,
# but integrate is refused once an implement row later appears
bidB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
lfB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" --task-id td-b \
   --json '{"task_id":"td-b","workers":[]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" \
   --json '{"task_id":"td-b","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"blocked before dispatch","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" --task-id td-b \
   --json '{"task_id":"td-b","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidB" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bidB.json"
SH

check "integrate-envelope: stored duplicate-key envelope refused; read_envelope raises" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev-storeddup.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# rewrite the stored envelope with a duplicate "sequence" key (raw text)
python3 -c '
import json, sys
p = sys.argv[1]
body = json.dumps(json.load(open(p)))
open(p, "w").write(body.replace("\"sequence\":", "\"sequence\": 9, \"sequence\":", 1))
' "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# schema-loader check: read_envelope on a handcrafted dup-key file raises ValueError
python3 -c '
import sys, os, tempfile
sys.path.insert(0, "claude/hooks")
import herdr_envelope as e
rd = tempfile.mkdtemp()
bid = "ldb-" + "0" * 32
p = e.envelope_path(rd, bid)
os.makedirs(p.parent, exist_ok=True)
p.write_text("{\"sequence\": 9, \"sequence\": 1}")
try:
    e.read_envelope(rd, bid)
except ValueError:
    sys.exit(0)
raise SystemExit("expected ValueError on a dup-key envelope file")
'
SH

check "integrate-envelope: dispatched attempt rewritten after emit refused (attempt mismatch)" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig-am.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
# Rewrite the implement row's pane_id in place after emit, so the envelope
# attempt no longer matches the dispatched attempt. This is exactly the
# history-tampering write-task's append-only guard now refuses, so exercise
# the tamper path directly (a raw file write).
python3 -c '
import json, sys
json.dump(
    {"task_id": "td-x", "status": "completed",
     "base_sha": sys.argv[2], "review_head_sha": sys.argv[3],
     "workers": [
        {"role": "mech", "launch_id": "L1", "phase": "implement",
         "runtime": "claude", "workspace_id": "w1", "pane_id": "paneZ",
         "source_head_sha": sys.argv[3]},
        {"role": "review", "launch_id": "L2", "phase": "review",
         "runtime": "claude", "workspace_id": "w2", "pane_id": "pane2",
         "source_head_sha": sys.argv[3]},
     ]},
    open(sys.argv[1], "w"),
)
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.json" "$BASE40" "$SHA40"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "integrate-envelope: corrupt workspace lease refused, binding stays claimed" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig-cl.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# corrupt the coordination lease file for the workspace (it lives under the
# coordination registry root, not the payload state tree)
python3 -c '
import glob, sys
hit = glob.glob(sys.argv[1])
assert hit, "no lease file to corrupt"
for p in hit:
    open(p, "w").write("{not json")
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-*.json"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "emit-review journal: a rejection at H blocks a later approved@H even after an H2 detour" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-jr1.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
H=$(printf 'a%.0s' $(seq 1 40))
H2=$(printf 'c%.0s' $(seq 1 40))
BASE=$(printf 'b%.0s' $(seq 1 40))
# review dispatched at H; a changes-requested verdict lands in the journal
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$BASE"'","review_head_sha":"'"$H"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome changes-requested --reviewed-head-sha "$H" --reviewed-base-sha "$BASE" --blocking-count 2 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1
# dispatch advances to H2 (base unchanged, new attempt appended); approved@H2
# succeeds
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$BASE"'","review_head_sha":"'"$H2"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H2"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H2" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H2" \
   --reviewer-session R1
# dispatch returns to H (again appended, not substituted); approved@H is
# refused -- the journal still remembers the changes-requested verdict at H,
# though the latest .review.json record is the H2 approval
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$BASE"'","review_head_sha":"'"$H"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H2"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"}]}'
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["reviewed_head_sha"] == sys.argv[2] and rec["outcome"] == "approved", rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json" "$H2"
SH

check "emit-review journal: a corrupt journal line fails the next binding-scoped emit closed" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-jr2.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
H=$(printf 'a%.0s' $(seq 1 40))
BASE=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$BASE"'","review_head_sha":"'"$H"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"}]}'
# one clean verdict creates the journal
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1
# corrupt the journal with a raw unparseable line
python3 -c 'import sys; open(sys.argv[1], "a").write("not valid json\n")' \
   "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review-log.jsonl"
# an otherwise-identical re-emit is now refused: the journal is unreadable, fail closed
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
SH

check "null-attempt envelope: a malformed implement row counts as a dispatched attempt (emit + integrate)" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev-malrow.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
SHA40=$(printf 'a%.0s' $(seq 1 40))
# binding A: a task carrying a valid I1 and a MALFORMED I2 row rejects a null-attempt emit
bidA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" --task-id td-a \
   --json '{"task_id":"td-a","workers":[{"role":"mech","launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
# write-task now refuses a non-native row, so the malformed I2 row is injected
# directly: this check is about emit-envelope failing closed on a record
# corrupted out of band, which the writer rule does not replace.
python3 -c '
import json, sys
path = sys.argv[1]
record = json.load(open(path))
record["workers"].append({"phase": "implement", "launch_id": "I2"})
json.dump(record, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/leads/$bidA/tasks/td-a.json"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" \
   --json '{"task_id":"td-a","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}' 2>"$root/eA"; then exit 1; fi
# The injected row must be what refuses it, not a stale fence or bad binding:
# has_attempt_rows counts it as a dispatched attempt, so the null-attempt
# envelope is rejected.
grep -q 'null-attempt envelope is only for tasks with no dispatched implement attempt' "$root/eA"
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bidA/envelope.json"
# binding B: a valid null-attempt envelope on a rowless task, THEN a malformed row
# appears -> integrate is refused, binding stays claimed
bidB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
lfB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" --task-id td-b \
   --json '{"task_id":"td-b","workers":[]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" \
   --json '{"task_id":"td-b","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"blocked before dispatch","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" --task-id td-b \
   --json '{"task_id":"td-b","workers":[{"role":"mech","launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
# Same out-of-band corruption as binding A, after the envelope was emitted.
python3 -c '
import json, sys
path = sys.argv[1]
record = json.load(open(path))
record["workers"].append({"phase": "implement", "launch_id": "I2"})
json.dump(record, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/leads/$bidB/tasks/td-b.json"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidB" 2>"$root/eB"; then exit 1; fi
# Same: the injected row is the refusal, not some unrelated guard.
grep -q 'null-attempt envelope is only for tasks with no dispatched implement attempt' "$root/eB"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bidB.json"
SH

check "emit-envelope: base swapped after approval refuses a re-emit (approval does not cover the expected base)" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-baseswap.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
B0=$(printf 'b%.0s' $(seq 1 40))
B1=$(printf 'c%.0s' $(seq 1 40))
# grounded at base B0: review approves at head SHA40, envelope seq 1 expects B0
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$B0"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$B0" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$B0"'","reason":null,"follow_ups":[]}}'
# swap the task base to B1; the approval still records review_base_sha B0
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$B1"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
# a fresh envelope grounded at B1 is refused: the approval does not cover B1
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":2,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$B1"'","reason":null,"follow_ups":[]}}' 2>/dev/null; then exit 1; fi
# the stored envelope is still sequence 1 (grounded at B0); binding stays claimed
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["sequence"] == 1 and rec["summary"]["expected_base_sha"] == sys.argv[2], rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json" "$B0"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "emit-review --binding: --reviewed-base-sha must match the currently dispatched base, not a rewritten one" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-reviewedbase.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
H=$(printf 'a%.0s' $(seq 1 40))
B0=$(printf 'b%.0s' $(seq 1 40))
B1=$(printf 'c%.0s' $(seq 1 40))
# task dispatched at base B0, head H unchanged throughout
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$B0"'","review_head_sha":"'"$H"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"}]}'
# a binding-scoped emit-review WITHOUT --reviewed-base-sha is refused outright
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
# the lead flips base_sha to B1 mid-flight (same head H, review_head_sha unchanged)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$B1"'","review_head_sha":"'"$H"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"}]}'
# the reviewer asserts the base it actually reviewed (B0, stale) -> refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$B0" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
# the reviewer asserts the new dispatched base (B1) -> succeeds and is recorded verbatim
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$B1" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["review_base_sha"] == sys.argv[2]
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json" "$B1"
SH

check "emit-envelope null-attempt: unreadable or malformed task record refuses (not laundered to None)" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ev-badtask.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[]}'
task_file="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.json"
# unreadable (not JSON at all): refused, not treated as absent
python3 -c 'import sys; open(sys.argv[1], "w").write("not json")' "$task_file"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# malformed (workers is a dict, not a list): refused
python3 -c 'import sys, json; json.dump({"task_id": "td-x", "workers": {"phase": "implement"}}, open(sys.argv[1], "w"))' "$task_file"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "emit-artifacts copies files, computes digests, refuses bad inputs" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-art1.git
root=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SRC=$(mktemp -d)
printf 'handoff body' > "$SRC/handoff.md"
printf 'plan body' > "$SRC/plan.md"
CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
    --task-id td-x --file "$SRC/handoff.md" --file "$SRC/plan.md"
ORIG_SHA=$(python3 -c '
import hashlib
print(hashlib.sha256(b"handoff body").hexdigest())')
CLAUDE_CONFIG_DIR="$root" python3 -c '
import hashlib, sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
bid = sys.argv[2]
rec = envelope.read_artifacts(rd, bid)
assert rec["task_id"] == "td-x", rec
assert {a["name"] for a in rec["artifacts"]} == {"handoff.md", "plan.md"}, rec
store = envelope.artifact_store(rd, bid)
for art in rec["artifacts"]:
    data = (store / core.artifact_blob_name(art["sha256"])).read_bytes()
    assert hashlib.sha256(data).hexdigest() == art["sha256"], art
    assert len(data) == art["bytes"], art
stored = {p.name for p in store.iterdir() if p.is_file()}
expected = {core.artifact_blob_name(a["sha256"]) for a in rec["artifacts"]}
assert stored == expected, stored
' "$LF_SLUG" "$bid"
# launcher identity is not the lease holder:
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session L1 --fence "$f" \
    --binding "$bid" --task-id td-x --file "$SRC/handoff.md" 2>"$ERRFILE"; then exit 1; fi
grep -q "not the live lease holder" "$ERRFILE"
# duplicate basenames refuse:
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
    --file "$SRC/handoff.md" --file "$SRC/handoff.md" 2>"$ERRFILE"; then exit 1; fi
grep -q "duplicate artifact name" "$ERRFILE"
# a symlink source refuses (no-follow):
ln -s /etc/passwd "$SRC/link.md"
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
    --file "$SRC/link.md" 2>"$ERRFILE"; then exit 1; fi
# a FIFO source refuses without hanging (O_NONBLOCK + regular-file check):
mkfifo "$SRC/pipe.md"
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
    --file "$SRC/pipe.md" 2>"$ERRFILE"; then exit 1; fi
grep -q "regular file" "$ERRFILE"
# a failed batch leaves prior preserved bytes intact: re-emit with a CHANGED
# handoff.md plus an unreadable second source; after the refusal the stored
# handoff.md still hashes to the ORIGINAL manifest digest.
printf 'changed body' > "$SRC/handoff.md"
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
    --file "$SRC/handoff.md" --file "$SRC/absent.md" 2>"$ERRFILE"; then exit 1; fi
python3 -c '
import hashlib, sys
data = open(sys.argv[1], "rb").read()
assert hashlib.sha256(data).hexdigest() == sys.argv[2], hashlib.sha256(data).hexdigest()
' "$root/herdr-orch/$LF_SLUG/leads/$bid/artifacts/$ORIG_SHA" "$ORIG_SHA"
# a SOURCE reached through a symlinked parent directory refuses (component
# no-follow applies to sources too):
EVILSRC=$(mktemp -d)
printf 'evil parent body' > "$EVILSRC/real.md"
ln -s "$EVILSRC" "$SRC/dirlink"
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
    --file "$SRC/dirlink/real.md" 2>"$ERRFILE"; then exit 1; fi
grep -q "artifact source is unreadable" "$ERRFILE"
# the store swapped for a symlink refuses before any byte lands outside it:
STORE="$root/herdr-orch/$LF_SLUG/leads/$bid/artifacts"
EVIL=$(mktemp -d)
mv "$STORE" "$STORE.real"
ln -s "$EVIL" "$STORE"
printf 'handoff body' > "$SRC/handoff.md"
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
    --file "$SRC/handoff.md" 2>"$ERRFILE"; then exit 1; fi
[ -z "$(ls -A "$EVIL")" ] || exit 1
rm "$STORE"
mv "$STORE.real" "$STORE"
# task mismatch:
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id other-task \
    --file "$SRC/handoff.md" 2>"$ERRFILE"; then exit 1; fi
grep -q "does not match the binding" "$ERRFILE"
SH

check "emit-review journal: an entry with the wrong shape (null, empty object) fails closed" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-jr-shape.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
H=$(printf 'a%.0s' $(seq 1 40))
BASE=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$BASE"'","review_head_sha":"'"$H"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$H"'"}]}'
journal="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review-log.jsonl"
# one clean verdict creates the journal
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1
# append a bare "null" line -> next binding-scoped emit-review refused
python3 -c 'import sys; open(sys.argv[1], "a").write("null\n")' "$journal"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
# reset the journal to the one clean line, then append an empty object -> also refused
python3 -c '
import sys
lines = open(sys.argv[1]).read().splitlines()
open(sys.argv[1], "w").write(lines[0] + "\n")
' "$journal"
python3 -c 'import sys; open(sys.argv[1], "a").write("{}\n")' "$journal"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$H" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
SH

check "integrate-envelope: missing approval record exits 2 cleanly (no traceback), binding stays claimed" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ig-noreview.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
rm -f "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
rc=0
err=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40" 2>&1 1>/dev/null) || rc=$?
test "$rc" = 2
case "$err" in
    *Traceback*) exit 1 ;;
esac
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "null-attempt gates: only file-absent or a well-formed empty task counts as nothing dispatched" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-nag.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
task_file="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.json"
NULL_ENV='{"task_id":"td-x","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# task file present but holds a literal JSON null -> malformed, not absent
mkdir -p "$(dirname "$task_file")"
python3 -c 'import sys; open(sys.argv[1], "w").write("null")' "$task_file"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$NULL_ENV" 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# workers is a list, but the one row is not a dict -> malformed
python3 -c 'import sys, json; json.dump({"task_id": "td-x", "workers": [None]}, open(sys.argv[1], "w"))' "$task_file"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$NULL_ENV" 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
# a worker row without a phase key -> malformed
python3 -c 'import sys, json; json.dump({"task_id": "td-x", "workers": [{"runtime": "claude"}]}, open(sys.argv[1], "w"))' "$task_file"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json "$NULL_ENV" 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.json"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "null-attempt gates: integrate-envelope also refuses a task record that turned malformed" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-nag-ig.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
# emit a valid null-attempt envelope while the task is genuinely absent
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":null,"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# the task record then appears, holding a literal JSON null
task_file="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.json"
mkdir -p "$(dirname "$task_file")"
python3 -c 'import sys; open(sys.argv[1], "w").write("null")' "$task_file"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "emit-review --binding: a non-40hex dispatched review head refuses before the journal is touched" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-jr-loose.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
BASE=$(printf 'b%.0s' $(seq 1 40))
LOOSE=$(printf 'h1%.0s' $(seq 1 19))  # 38 chars, not a 40hex sha
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$BASE"'","review_head_sha":"'"$LOOSE"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$BASE"'"}]}'
journal="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review-log.jsonl"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$LOOSE" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$BASE" \
   --reviewer-session R1 2>/dev/null; then exit 1; fi
test ! -e "$journal"
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
# a proper dispatch at a 40hex head still emits cleanly afterward (no bricking)
H40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$BASE"'","review_head_sha":"'"$H40"'","workers":[{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$BASE"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$H40" --reviewed-base-sha "$BASE" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$BASE" \
   --reviewer-session R1
test -f "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.review.json"
test -f "$journal"
SH

check "integrate-envelope: the integrating launcher cannot be the reviewer, even after a rotation" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rot-launcher.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
# reviewer RVR is independent of the original launcher L1 and lead S1
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session RVR
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"RVR","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
# launcher rotates: session RVR takes over the launcher owner slot (fresh fence)
rf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session RVR --host h --pid 3 --stale-secs 0)
# RVR is now the live launcher AND the recorded reviewer -> integrate refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session RVR --fence "$rf" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# a further takeover by a different launcher session L2 integrates cleanly
l2f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L2 --host h --pid 4 --stale-secs 0)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L2 --fence "$l2f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "completed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "write-task --binding: dispatch history is append-only" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-append-only.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-ao \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
I1='{"role":"mech","launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}'
I2='{"role":"mech","launch_id":"I2","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}'
I1MOD='{"role":"mech","launch_id":"I1-tampered","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-ao \
   --json '{"task_id":"td-ao","workers":['"$I1"']}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-ao \
   --json '{"task_id":"td-ao","workers":['"$I1"','"$I2"']}'
# dropping I1 (a shorter, divergent list) is refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-ao \
   --json '{"task_id":"td-ao","workers":['"$I2"']}' 2>/dev/null; then exit 1; fi
# wiping history to an empty list is refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-ao \
   --json '{"task_id":"td-ao","workers":[]}' 2>/dev/null; then exit 1; fi
# a same-length list with the first element altered is refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-ao \
   --json '{"task_id":"td-ao","workers":['"$I1MOD"','"$I2"']}' 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert [w["launch_id"] for w in rec["workers"]] == ["I1", "I2"], rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-ao.json"
SH

check "write-task --binding: append-only closes the envelope revival regression" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-revival.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-rv \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
I1='{"role":"mech","launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}'
I2='{"role":"mech","launch_id":"I2","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}'
# implement attempt I1 recorded, a blocked envelope is grounded to it
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-rv \
   --json '{"task_id":"td-rv","workers":['"$I1"']}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-rv","attempt":{"launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# successor I2 is appended -- integrate is refused, the envelope no longer
# matches the latest native implement row
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-rv \
   --json '{"task_id":"td-rv","workers":['"$I1"','"$I2"']}'
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>/dev/null; then exit 1; fi
# attempting to restore workers to just [I1] -- reviving the older, already-
# rejected envelope -- is refused as non-append-only history
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-rv \
   --json '{"task_id":"td-rv","workers":['"$I1"']}' 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "emit/integrate-envelope: workers-shape validation applies to the non-null grounding branch too" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-shape-sym.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
SHA40=$(printf 'a%.0s' $(seq 1 40))
# binding A: a task carrying a valid I1 row plus a trailing phaseless row
# refuses a non-null emit-envelope grounded to I1
bidA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-shA \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" --task-id td-shA \
   --json '{"task_id":"td-shA","workers":[{"role":"mech","launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
# a phaseless row is dispatch-history tampering write-task's append-only
# guard would refuse; append it via a direct file write (the tamper path)
python3 -c '
import json, sys
json.dump(
    {"task_id": "td-shA", "workers": [
        {"role": "mech", "launch_id": "I1", "phase": "implement",
         "runtime": "claude", "workspace_id": "w1", "pane_id": "pane1",
         "source_head_sha": sys.argv[2]},
        {"runtime": "claude"},
    ]},
    open(sys.argv[1], "w"),
)
' "$root/herdr-orch/$LF_SLUG/leads/$bidA/tasks/td-shA.json" "$SHA40"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" \
   --json '{"task_id":"td-shA","attempt":{"launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bidA/envelope.json"
# binding B: emit succeeds against a well-formed task, then the task is
# corrupted the same way before integrate -- integrate is refused, binding
# stays claimed
bidB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-shB \
   --workspace-root "$LF_WS" --expected-session SB)
lfB=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" --task-id td-shB \
   --json '{"task_id":"td-shB","workers":[{"role":"mech","launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py emit-envelope \
   --repo-slug "$LF_SLUG" --session SB --fence "$lfB" --binding "$bidB" \
   --json '{"task_id":"td-shB","attempt":{"launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
python3 -c '
import json, sys
json.dump(
    {"task_id": "td-shB", "workers": [
        {"role": "mech", "launch_id": "I1", "phase": "implement",
         "runtime": "claude", "workspace_id": "w1", "pane_id": "pane1",
         "source_head_sha": sys.argv[2]},
        {"runtime": "claude"},
    ]},
    open(sys.argv[1], "w"),
)
' "$root/herdr-orch/$LF_SLUG/leads/$bidB/tasks/td-shB.json" "$SHA40"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidB" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bidB.json"
SH

check "write-task --binding: refuse updates over a malformed prior task record" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-malformed-prior.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-mal \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
I1='{"role":"mech","launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}'
# Create a valid binding-scoped task with implement row
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-mal \
   --json '{"task_id":"td-mal","workers":['"$I1"']}'
# Corrupt the on-disk record to have a phaseless row (malformed worker)
python3 -c '
import json, sys
json.dump(
    {"task_id": "td-mal", "workers": [{"runtime": "claude"}]},
    open(sys.argv[1], "w"),
)
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-mal.json"
# Subsequent binding-scoped write-task updating status should be refused
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-mal \
   --json '{"task_id":"td-mal","status":"claimed","workers":['"$I1"']}' 2>/dev/null; then exit 1; fi
# Verify on-disk record is unchanged (still has the malformed row, status not updated)
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec.get("workers") == [{"runtime": "claude"}], rec
assert rec.get("status") != "claimed", rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-mal.json"
SH

check "teardown completes: artifact gate, lease release, manifest, prune" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-td-complete.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
SRC=$(mktemp -d)
printf 'handoff body' > "$SRC/handoff.md"
printf 'plan body' > "$SRC/plan.md"
CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
    --task-id td-x --file "$SRC/handoff.md" --file "$SRC/plan.md"
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "completed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
MAIN_SLUG="$LF_SLUG"
MAIN_WS="$LF_WS"

# A SECOND repo/binding, artifact-less but otherwise completed, exercises
# the artifact gate. A distinct origin/slug (not just a distinct payload
# root) avoids colliding with the main fixture's shared coordination
# registry (bindings.json, lead leases are keyed by repo slug only).
lead_fixture https://example.com/repo-td-complete-noart.git
f2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L2 --host h --pid 3)
bid2=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L2 --fence "$f2" --task-id td-y \
   --workspace-root "$LF_WS" --expected-session S2)
lf2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S2 --host h --pid 4 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid2")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S2 --fence "$lf2" --binding "$bid2" --task-id td-y \
   --json '{"task_id":"td-y","workers":[{"role":"mech","launch_id":"L3","phase":"implement","runtime":"claude","workspace_id":"w3","pane_id":"pane3","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S2 --fence "$lf2" --binding "$bid2" \
   --json '{"task_id":"td-y","attempt":{"launch_id":"L3","phase":"implement","runtime":"claude","workspace_id":"w3","pane_id":"pane3","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --binding "$bid2"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --binding "$bid2" 2>"$ERRFILE"; then exit 1; fi
grep -q "no artifacts manifest" "$ERRFILE"
LF_SLUG="$MAIN_SLUG"
LF_WS="$MAIN_WS"

# Main fixture: teardown succeeds outright (the descendant history above is
# fully settled: workers[-1] is the review row and tasks/td-x.review.json
# matches it exactly, so it never appears in the descendant list).
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"

KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
if [ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ]; then exit 1; fi
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
' "$LF_SLUG" "$KEY"
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
bid = sys.argv[2]
env = envelope.read_envelope(rd, bid)
rec = envelope.read_teardown(rd, bid)
assert rec["mode"] == "complete", rec
assert rec["lease_released"] is True, rec
assert rec["envelope_sha256"] == envelope.envelope_digest(env), rec
' "$LF_SLUG" "$bid"

# Re-run: exit 0, lease_released STILL true.
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
rec = envelope.read_teardown(rd, sys.argv[2])
assert rec["lease_released"] is True, rec
' "$LF_SLUG" "$bid"

# Tamper an artifact store file's bytes: re-run fails on the digest gate.
HP=$(python3 -c 'import hashlib; print(hashlib.sha256(b"handoff body").hexdigest())')
ART="$root/herdr-orch/$LF_SLUG/leads/$bid/artifacts/$HP"
cp "$ART" "$ART.orig"
printf 'TAMPERED' > "$ART"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>"$ERRFILE"; then exit 1; fi
grep -q "does not match its digest" "$ERRFILE"
cp "$ART.orig" "$ART"

# --prune: envelope.json and the review-log journal are gone; the
# consumption record, artifacts store, and teardown manifest survive.
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --prune
LEAD_DIR="$root/herdr-orch/$LF_SLUG/leads/$bid"
[ ! -e "$LEAD_DIR/envelope.json" ] || exit 1
[ ! -e "$LEAD_DIR/tasks/td-x.review-log.jsonl" ] || exit 1
[ -e "$LEAD_DIR/envelope.consumed.json" ] || exit 1
[ -e "$LEAD_DIR/artifacts/$HP" ] || exit 1
[ -e "$LEAD_DIR/teardown.json" ] || exit 1

# Re-run AFTER prune: exit 0, and the manifest still carries the ORIGINAL
# envelope_sha256 and journal digests (a merge, never an overwrite).
ORIG=$(CLAUDE_CONFIG_DIR="$root" python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
rec = envelope.read_teardown(rd, sys.argv[2])
print(json.dumps([rec["envelope_sha256"], rec["journal_sha256"]], sort_keys=True))
' "$LF_SLUG" "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
CLAUDE_CONFIG_DIR="$root" python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
rec = envelope.read_teardown(rd, sys.argv[2])
assert json.dumps([rec["envelope_sha256"], rec["journal_sha256"]], sort_keys=True) == sys.argv[3], rec
assert rec["lease_released"] is True, rec
' "$LF_SLUG" "$bid" "$ORIG"

# Digest conflict refusal: envelope.json was pruned above, so the
# manifest's retained envelope_sha256 (== the consumption record's) is the
# only surviving record of it. Recreating it with DIFFERENT valid content
# must refuse -- here the consumption-record pin fires first (sequence 2
# and different bytes vs the consumed sequence-1 digest).
python3 -c '
import json, sys
path, bid = sys.argv[1], sys.argv[2]
rec = {
    "schema_version": 1,
    "binding_id": bid,
    "task_id": "td-x",
    "attempt": None,
    "fence": 1,
    "sequence": 2,
    "ts": "2026-01-01T00:00:00Z",
    "summary": {"outcome": "blocked", "pr": None, "expected_base_sha": None,
                "reason": "tampered", "follow_ups": []},
}
json.dump(rec, open(path, "w"))
' "$LEAD_DIR/envelope.json" "$bid"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>"$ERRFILE"; then exit 1; fi
grep -q "does not match the consumption record" "$ERRFILE"
rm -f "$LEAD_DIR/envelope.json"

# Same refusal for a journal-key conflict: the review-log was also pruned;
# recreating it with different bytes must refuse rather than silently
# replace the retained journal digest for td-x.
printf 'tampered review-log line\n' > "$LEAD_DIR/tasks/td-x.review-log.jsonl"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" 2>"$ERRFILE"; then exit 1; fi
grep -q "surviving content conflicts" "$ERRFILE"
rm -f "$LEAD_DIR/tasks/td-x.review-log.jsonl"
SH

check "teardown abandon path and descendant gate" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-td-abandon.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
SHA40=$(printf 'a%.0s' $(seq 1 40))
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'

# No .done.json for the latest (implement) row: outstanding, named by pane.
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --abandon 2>"$ERRFILE"; then exit 1; fi
grep -q "outstanding descendants" "$ERRFILE"
grep -q "pane1" "$ERRFILE"

# Tamper the task record (direct file write) to hold a worker row with only
# {"phase": "implement"}: missing the native identity tuple -> "<unreadable>".
TASK="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.json"
cp "$TASK" "$TASK.orig"
python3 -c '
import json, sys
path = sys.argv[1]
task = json.load(open(path))
task["workers"].append({"phase": "implement"})
json.dump(task, open(path, "w"))
' "$TASK"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --abandon 2>"$ERRFILE"; then exit 1; fi
grep -q "descendant records are unreadable" "$ERRFILE"
cp "$TASK.orig" "$TASK"

# Restored record plus --descendants-terminated: teardown succeeds.
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --abandon --descendants-terminated
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "revoked"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
rec = envelope.read_teardown(rd, sys.argv[2])
assert rec["lease_released"] is True, rec
assert rec["mode"] == "abandon", rec
' "$LF_SLUG" "$bid"

# A fresh claimed binding without --abandon fails outright.
bid2=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-z \
   --workspace-root "$LF_WS" --expected-session S2)
lf2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S2 --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid2")
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid2" 2>"$ERRFILE"; then exit 1; fi
grep -q "only with --abandon" "$ERRFILE"
SH

check "teardown leaves a successor's lease untouched" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-td-succ.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bidA=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
bidB=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
# B takes over A's workspace lease via a stale takeover; A's binding stays
# "claimed" (nothing writes to it), so teardown of A needs --abandon.
lfB=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0)
out=$(CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidA" --abandon)
printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["lease_released"] is False, rec
'
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "revoked"
' "$root/herdr-orch/$LF_SLUG/bindings/$bidA.json"
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
rec = envelope.read_teardown(rd, sys.argv[2])
assert rec["lease_released"] is False, rec
' "$LF_SLUG" "$bidA"
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
' "$LF_SLUG" "$KEY" "$bidB"
SH

check "missing-own teardown records the release it performed" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-td-missing.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
rm "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --abandon --descendants-terminated)
printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["lease_released"] is True, rec
'
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
rec = envelope.read_teardown(rd, sys.argv[2])
assert rec["lease_released"] is True, rec
' "$LF_SLUG" "$bid"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
' "$LF_SLUG" "$KEY"
SH

check "reconcile-leads reports live vs stale and adopts with --apply" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rl-live-stale.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
git -C "$LF_REPO" worktree add -q "$LF_WSBASE/wt2"
LF_WS2="$LF_WSBASE/wt2"
bid1=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-1 \
   --workspace-root "$LF_WS" --expected-session S1)
bid2=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-2 \
   --workspace-root "$LF_WS2" --expected-session S2)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid1" >/dev/null
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S2 --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS2" --binding "$bid2" >/dev/null

# W2's lease heartbeat rewritten to 0 via direct json edit: stale, record
# otherwise stays valid.
KEY2=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS2")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY2.json"

# Simulate a launcher restart: a new launcher session takes the slug owner
# from a fresh session id via a --stale-secs 0 takeover.
f2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L2 --host h --pid 4 --stale-secs 0)

# Report run (no --apply): B1 live/none, B2 stale.
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2")
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["lease"] == "live", rows
assert rows[sys.argv[1]]["action"] == "none", rows
assert rows[sys.argv[2]]["lease"] == "stale", rows
assert rows[sys.argv[2]]["action"] == "none", rows
' "$bid1" "$bid2"

# Apply run: B1 untouched, B2 revoked and its lease released.
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "none", rows
assert rows[sys.argv[2]]["action"] == "revoked+released", rows
' "$bid1" "$bid2"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid1.json"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "revoked"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid2.json"
KEY1=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY1.json" ] || exit 1
if [ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY2.json" ]; then exit 1; fi
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
' "$LF_SLUG" "$KEY2"
SH

check "reconcile-leads defers release while descendants outstanding" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rl-descendants.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
SHA40=$(printf 'a%.0s' $(seq 1 40))
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'

KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"

f2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L2 --host h --pid 3 --stale-secs 0)

# First apply: revokes the binding, lease file REMAINS, action is
# needs-descendant-termination (the implement row is unsettled).
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "needs-descendant-termination", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "revoked"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1

# Second run, --descendants-terminated: the revoked binding is still named
# by lead_ws, so it is selected again; this time the lease is released.
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply --descendants-terminated)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "released", rows
' "$bid"
if [ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ]; then exit 1; fi
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
' "$LF_SLUG" "$KEY"
SH

check "reconcile-leads recovers missing-own and refuses apply on corrupt" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rl-missing-own.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid1=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-1 \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid1" >/dev/null

KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
GEN_BEFORE=$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["generation"])
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json")
# Delete B1's OWN lease file directly; the registry still names B1.
rm "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"

f2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L2 --host h --pid 3 --stale-secs 0)

out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2")
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["lease"] == "missing-own", rows
' "$bid1"

CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply >/dev/null
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "revoked"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid1.json"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
' "$LF_SLUG" "$KEY"

# A fresh claim on the freed workspace succeeds afterwards, with a bumped
# generation.
bid1b=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L2 --fence "$f2" --task-id td-1b \
   --workspace-root "$LF_WS" --expected-session S3)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S3 --host h --pid 4 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid1b" >/dev/null
python3 -c '
import json, sys
gen = json.load(open(sys.argv[1]))["generation"]
assert gen == int(sys.argv[2]) + 1, gen
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" "$GEN_BEFORE"

# Separately: a garbage bindings/<ldb-...>.json file. The report lists a
# "corrupt" row; --apply refuses naming the id and mutates NOTHING.
bid3=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L2 --fence "$f2" --task-id td-3 \
   --workspace-root "$LF_WS" --expected-session S4)
GARBAGE_ID=$(python3 -c 'import uuid; print("ldb-" + uuid.uuid4().hex)')
printf 'not json' > "$root/herdr-orch/$LF_SLUG/bindings/$GARBAGE_ID.json"
BEFORE=$(cat "$root/herdr-orch/$LF_SLUG/bindings/$bid3.json")
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2")
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["lease"] == "corrupt", rows
' "$GARBAGE_ID"
if CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply 2>"$ERRFILE"; then exit 1; fi
grep -q "$GARBAGE_ID" "$ERRFILE"
AFTER=$(cat "$root/herdr-orch/$LF_SLUG/bindings/$bid3.json")
[ "$BEFORE" = "$AFTER" ] || exit 1
SH

check "envelope readers refuse a symlinked binding directory" <<PY
$LOAD
import importlib.util as iu
espec=iu.spec_from_file_location("env","claude/hooks/herdr_envelope.py")
e=iu.module_from_spec(espec);espec.loader.exec_module(e)
rd = tempfile.mkdtemp()
bid = "ldb-" + "0" * 32
env_rec = {"schema_version": 1, "binding_id": bid, "task_id": "PROJ-1",
           "attempt": None, "fence": 1, "sequence": 1,
           "ts": "2026-01-01T00:00:00Z",
           "summary": {"outcome": "blocked", "pr": None,
                       "expected_base_sha": None, "reason": "waiting",
                       "follow_ups": []}}
con_rec = {"schema_version": 1, "binding_id": bid, "sequence": 1,
           "envelope_sha256": "0" * 64, "outcome": "blocked",
           "integrated_by": "L1", "fence": 1, "ts": "2026-01-01T00:00:00Z"}
# control: through a REAL directory chain both records read back fine
real = e.envelope_path(rd, bid).parent
real.mkdir(parents=True)
e.envelope_path(rd, bid).write_text(json.dumps(env_rec))
e.consumed_path(rd, bid).write_text(json.dumps(con_rec))
assert e.read_envelope(rd, bid) == env_rec
assert e.read_consumed(rd, bid) == con_rec
# swap the binding dir for a symlink to an external dir holding the same
# VALID records: every reader must refuse (symlinked parent component),
# never serve the external content as authentic state.
evil = tempfile.mkdtemp()
forged = {
    "envelope.json": env_rec,
    "envelope.consumed.json": con_rec,
    "artifacts.json": {
        "schema_version": 1, "binding_id": bid, "task_id": "PROJ-1",
        "artifacts": [{"name": "a.md", "sha256": "0" * 64, "bytes": 1}],
        "ts": "t"},
    "teardown.json": {
        "schema_version": 1, "binding_id": bid, "mode": "abandon",
        "envelope_sha256": None, "journal_sha256": {},
        "artifacts_present": False, "lease_released": False,
        "generation": None, "ts": "t"},
}
for fname, rec in forged.items():
    with open(os.path.join(evil, fname), "w") as fh:
        json.dump(rec, fh)
import shutil
shutil.rmtree(real)
os.symlink(evil, real)
for reader in (e.read_envelope, e.read_consumed, e.read_artifacts,
               e.read_teardown):
    try:
        reader(rd, bid)
        raise AssertionError(f"{reader.__name__} followed a symlinked dir")
    except ValueError:
        pass
PY

check "_read_fd_capped and _write_fd_all enforce their bounds" <<PY
$LOAD
d = tempfile.mkdtemp()
p = os.path.join(d, "data.bin")
with open(p, "wb") as fh:
    fh.write(b"x" * 100)
fd = os.open(p, os.O_RDONLY)
try:
    try:
        c._read_fd_capped(fd, 50)
        raise AssertionError("read past the cap")
    except ValueError:
        pass
finally:
    os.close(fd)
fd = os.open(p, os.O_RDONLY)
try:
    assert c._read_fd_capped(fd, 100) == b"x" * 100
finally:
    os.close(fd)
# a short-writing os.write (at most 7 bytes per call) must still land the
# full buffer through _write_fd_all
real_write = os.write
q = os.path.join(d, "out.bin")
fd = os.open(q, os.O_WRONLY | os.O_CREAT, 0o600)
try:
    os.write = lambda f, data: real_write(f, bytes(data[:7]))
    c._write_fd_all(fd, b"abcdefghij" * 123)
finally:
    os.write = real_write
    os.close(fd)
with open(q, "rb") as fh:
    assert fh.read() == b"abcdefghij" * 123
PY

check "emit-artifacts: interruption never breaks the published manifest" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-art-crash.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SRC=$(mktemp -d)
printf 'v1 body' > "$SRC/handoff.md"
CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
    --task-id td-x --file "$SRC/handoff.md"
printf 'new one' > "$SRC/new1.md"
printf 'new two' > "$SRC/new2.md"
CLAUDE_CONFIG_DIR="$root" python3 - "$LF_SLUG" "$bid" "$lf" "$SRC" <<'EOF'
import hashlib, sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
slug, bid, lf, src = sys.argv[1:5]
rd = core.repo_dir(slug)
store = envelope.artifact_store(rd, bid)
before = envelope.read_artifacts(rd, bid)
def blobs():
    return sorted(p.name for p in store.iterdir())
args = ["emit-artifacts", "--repo-slug", slug, "--session", "S1",
        "--fence", lf, "--binding", bid, "--task-id", "td-x",
        "--file", src + "/new1.md", "--file", src + "/new2.md"]
# (i) crash while writing the SECOND new blob: the temp is swept, nothing
# is published, the prior manifest and its bytes are untouched.
orig_write_all = core._write_fd_all
calls = {"n": 0}
def boom_write(fd, data):
    calls["n"] += 1
    if calls["n"] >= 2:
        raise OSError("simulated write failure")
    return orig_write_all(fd, data)
core._write_fd_all = boom_write
assert core.main(list(args)) == 2
core._write_fd_all = orig_write_all
assert envelope.read_artifacts(rd, bid) == before
assert not [n for n in blobs() if n.startswith(".tmp-")], blobs()
# (ii) crash BETWEEN blob publication and manifest publication: the prior
# manifest still reads back, its referenced bytes still match, no temps.
orig_wja = core.write_json_atomic
def boom_manifest(path, data):
    if str(path).endswith("artifacts.json"):
        raise OSError("simulated crash before manifest publish")
    return orig_wja(path, data)
core.write_json_atomic = boom_manifest
assert core.main(list(args)) == 2
core.write_json_atomic = orig_wja
assert envelope.read_artifacts(rd, bid) == before
for art in before["artifacts"]:
    data = (store / core.artifact_blob_name(art["sha256"])).read_bytes()
    assert hashlib.sha256(data).hexdigest() == art["sha256"], art
assert not [n for n in blobs() if n.startswith(".tmp-")], blobs()
# (iii) a clean re-run publishes and sweeps everything unreferenced.
assert core.main(list(args)) == 0
final = envelope.read_artifacts(rd, bid)
names = {core.artifact_blob_name(a["sha256"]) for a in final["artifacts"]}
assert {a["name"] for a in final["artifacts"]} == {"new1.md", "new2.md"}
assert set(blobs()) == names, blobs()
EOF
SH

check "emit-artifacts refuses a manifest exceeding the reader size cap" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-art-cap.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
TID=$(python3 -c 'print("t" * 17000)')
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id "$TID" \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SRC=$(mktemp -d)
printf 'body' > "$SRC/a.md"
if CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
    --task-id "$TID" --file "$SRC/a.md" 2>"$ERRFILE"; then exit 1; fi
grep -q "manifest exceeds the size bound" "$ERRFILE"
# nothing was published: no manifest, empty store
[ ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/artifacts.json" ] || exit 1
[ -z "$(ls -A "$root/herdr-orch/$LF_SLUG/leads/$bid/artifacts")" ] || exit 1
SH

check "teardown retry after a successor claim preserves the audit fields" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-td-retry.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bidA=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidA" --abandon --descendants-terminated
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rec = envelope.read_teardown(core.repo_dir(sys.argv[1]), sys.argv[2])
assert rec["generation"] == 1, rec
assert rec["lease_released"] is True, rec
' "$LF_SLUG" "$bidA"
# a successor claims the same workspace: generation advances to 2
bidB=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" >/dev/null
# retry A's teardown: the manifest must keep A's generation (1) and its
# recorded release, never adopt the successor's occupancy as A's evidence.
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidA"
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rec = envelope.read_teardown(core.repo_dir(sys.argv[1]), sys.argv[2])
assert rec["generation"] == 1, rec
assert rec["lease_released"] is True, rec
' "$LF_SLUG" "$bidA"
# and B's occupancy is untouched
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
assert entry["generation"] == 2, entry
' "$LF_SLUG" "$KEY" "$bidB"
SH

check "reconcile-leads --apply survives foreign occupancy and reports needs-manual-repair" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rl-repair.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
git -C "$LF_REPO" worktree add -q "$LF_WSBASE/wt2"
LF_WS2="$LF_WSBASE/wt2"
# Row 1: A claimed on ws1; B stale-takes-over ws1 (registry names B); B's
# binding is then completed (its row drops out of the scan) and ws1's lease
# file is corrupted. A's row must classify superseded, never attempt (and
# die on) a foreign release.
bidA=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA" >/dev/null
bidB=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0 >/dev/null
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["status"] = "completed"
json.dump(rec, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/bindings/$bidB.json"
KEY1=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
printf 'not json' > "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY1.json"
# Row 2: C claimed on ws2 with a LEGACY lease (no generation) and no
# registry lead_ws entry. A lease with no corroborating registry entry is
# uncorroborated authority: reconcile must NOT revoke or release from it
# (registry loss is a manual-repair situation, not a revoke trigger), so
# the row reports needs-manual-repair with no mutation and the scan
# continues past it.
bidC=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-c \
   --workspace-root "$LF_WS2" --expected-session SC)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SC --host h --pid 4 --control-tier lead \
   --workspace-root "$LF_WS2" --binding "$bidC" >/dev/null
KEY2=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS2")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
del rec["generation"]
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY2.json"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
reg = coordination.coordination_root() / "bindings.json"
data = json.loads(reg.read_text())
del data[sys.argv[1]]["lead_ws"][sys.argv[2]]
reg.write_text(json.dumps(data))
' "$LF_SLUG" "$KEY2"
f2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L2 --host h --pid 5 --stale-secs 0)
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["lease"] == "superseded", rows
assert rows[sys.argv[1]]["action"] == "revoked", rows
assert rows[sys.argv[2]]["action"] == "needs-manual-repair", rows
' "$bidA" "$bidC"
python3 -c '
import json, sys
# td-a (foreign occupancy) is revoked; td-c (uncorroborated lease, no
# registry entry) is left untouched for manual repair, still claimed.
assert json.load(open(sys.argv[1]))["status"] == "revoked"
assert json.load(open(sys.argv[2]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bidA.json" "$root/herdr-orch/$LF_SLUG/bindings/$bidC.json"
# ws1's corrupt lease bytes and B's registry occupancy are untouched
[ "$(cat "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY1.json")" = "not json" ] || exit 1
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
' "$LF_SLUG" "$KEY1" "$bidB"
# a retry does not wedge: the run still exits 0
CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply >/dev/null
SH

check "teardown retry after failed manifest publication recovers from the ledger" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-td-receipt.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
# crash AFTER the release lands but BEFORE the manifest publishes
CLAUDE_CONFIG_DIR="$root" python3 - "$LF_SLUG" "$bid" "$f" <<'EOF'
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
slug, bid, f = sys.argv[1:4]
rd = core.repo_dir(slug)
orig_wja = core.write_json_atomic
def boom(path, data):
    if str(path).endswith("teardown.json"):
        raise OSError("simulated crash before manifest publish")
    return orig_wja(path, data)
core.write_json_atomic = boom
rc = core.main(["teardown-binding", "--repo-slug", slug, "--session", "L1",
                "--fence", f, "--binding", bid, "--abandon",
                "--descendants-terminated"])
core.write_json_atomic = orig_wja
assert rc == 2, rc
assert envelope.read_teardown(rd, bid) is None
EOF
# the release landed atomically WITH its ledger attribution
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
import os
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
key = coordination.lead_lease_key(os.path.realpath(sys.argv[2]))
entry = data[sys.argv[1]]["lead_ws"][key]
assert entry["binding_id"] is None, entry
assert entry["releases"] == {"1": sys.argv[3]}, entry
' "$LF_SLUG" "$LF_WS" "$bid"
# retry: audit fields recover from the post-release ledger, never null/false
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --abandon --descendants-terminated
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rec = envelope.read_teardown(core.repo_dir(sys.argv[1]), sys.argv[2])
assert rec["generation"] == 1, rec
assert rec["lease_released"] is True, rec
' "$LF_SLUG" "$bid"
SH

check "emit-artifacts stores a long multibyte logical name under a fixed-length blob" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-art-longname.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SRC=$(mktemp -d)
# 120 U+00E9 characters: a VALID logical name (<=200 chars) whose UTF-8
# encoding is 240 bytes -- any per-name store prefix would overflow a
# 255-byte filesystem component; the fixed-length blob name must not.
NAME=$(python3 -c 'import sys; sys.stdout.write("é" * 120)')
printf 'long name body' > "$SRC/$NAME"
CLAUDE_CONFIG_DIR="$root" $CLI emit-artifacts \
    --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
    --task-id td-x --file "$SRC/$NAME"
CLAUDE_CONFIG_DIR="$root" python3 -c '
import hashlib, sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
bid = sys.argv[2]
rec = envelope.read_artifacts(rd, bid)
(art,) = rec["artifacts"]
assert art["name"] == "é" * 120, art
blob = envelope.artifact_store(rd, bid) / core.artifact_blob_name(art["sha256"])
data = blob.read_bytes()
assert data == b"long name body", data
assert hashlib.sha256(data).hexdigest() == art["sha256"], art
' "$LF_SLUG" "$bid"
SH

check "release ledger survives post-release write failures and a successor claim" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-td-atomic.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
# release lands with its ledger attribution; EVERY post-release write fails
CLAUDE_CONFIG_DIR="$root" python3 - "$LF_SLUG" "$bid" "$f" <<'EOF'
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
slug, bid, f = sys.argv[1:4]
rd = core.repo_dir(slug)
orig_wja = core.write_json_atomic
def boom(path, data):
    if str(path).endswith("teardown.json"):
        raise OSError("simulated crash on every post-release write")
    return orig_wja(path, data)
core.write_json_atomic = boom
rc = core.main(["teardown-binding", "--repo-slug", slug, "--session", "L1",
                "--fence", f, "--binding", bid, "--abandon",
                "--descendants-terminated"])
core.write_json_atomic = orig_wja
assert rc == 2, rc
assert envelope.read_teardown(rd, bid) is None
EOF
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
assert entry["releases"] == {"1": sys.argv[3]}, entry
' "$LF_SLUG" "$KEY" "$bid"
# a successor claims the workspace: the mutable occupancy is rewritten but
# the append-only ledger is PRESERVED -- the erasure the retired receipt
# existed to survive no longer happens.
bid2=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-y \
   --workspace-root "$LF_WS" --expected-session S2)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S2 --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid2" >/dev/null
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
assert "released_binding" not in entry, entry
assert entry["releases"] == {"1": sys.argv[4]}, entry
' "$LF_SLUG" "$KEY" "$bid2" "$bid"
# retry: the ledger proves the release across the successor claim
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --abandon --descendants-terminated
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rec = envelope.read_teardown(core.repo_dir(sys.argv[1]), sys.argv[2])
assert rec["generation"] == 1, rec
assert rec["lease_released"] is True, rec
' "$LF_SLUG" "$bid"
SH

check "reconcile release lands atomically with its ledger attribution" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rl-atomic.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
f2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L2 --host h --pid 3 --stale-secs 0)
# the stale row is revoked and released; the release and its attribution
# are ONE registry write, so the ledger names the binding immediately.
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "revoked+released", rows
' "$bid"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
assert "released_binding" not in entry, entry
assert entry["releases"] == {"1": sys.argv[3]}, entry
' "$LF_SLUG" "$KEY" "$bid"
# a later teardown of the reconcile-released binding records its fields
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --binding "$bid"
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rec = envelope.read_teardown(core.repo_dir(sys.argv[1]), sys.argv[2])
assert rec["generation"] == 1, rec
assert rec["lease_released"] is True, rec
' "$LF_SLUG" "$bid"
SH

check "replayed predecessor lease cannot authorize lead-fenced writes" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f2-replay.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bidA=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
lfA=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA")
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
LEASE="$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
cp "$LEASE" "$LEASE.saved"
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$LEASE"
bidB=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0 >/dev/null
# restore A's lease file over B's: the registry names B, so A's otherwise
# self-consistent lease must not authorize a binding-scoped write
cp "$LEASE.saved" "$LEASE"
if CLAUDE_CONFIG_DIR="$root" $CLI write-index \
   --repo-slug "$LF_SLUG" --session SA --fence "$lfA" --binding "$bidA" --workspace w1 \
   --json '{"workspace_id":"w1"}' 2>"$ERRFILE"; then exit 1; fi
grep -q "missing lead fence" "$ERRFILE"
[ ! -e "$root/herdr-orch/$LF_SLUG/leads/$bidA/workspaces/w1.json" ] || exit 1
SH

check "resumed integrate re-runs the live checks (SHA args required again)" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f3-resume.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
REPO_ID=$(CLAUDE_CONFIG_DIR="$root" python3 -c "
import sys
sys.path.insert(0, 'claude/hooks')
import herdr_orch_core as c
import herdr_bindings as bindings
print(bindings.read_binding(c.repo_dir('$LF_SLUG'), '$bid')['repo_id'])
")
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
MOVED40=$(printf 'c%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","status":"completed","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-x --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"pr_ready","pr":{"repo_id":"'"$REPO_ID"'","number":9,"branch":"talon/td-x","head_sha":"'"$SHA40"'","approval":{"reviewer_session_id":"R1","reviewer_runtime":"claude","reviewed_head_sha":"'"$SHA40"'"}},"expected_base_sha":"'"$BASE40"'","reason":null,"follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40"
# crash window: the consumption record is durable but the completed
# transition is lost -- reset the binding to claimed and RESUME.
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["status"] = "claimed"
json.dump(rec, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# resume WITHOUT --base-sha: the live-observation requirement applies to
# the resumed path exactly as to the first run
if CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "requires --base-sha" "$ERRFILE"
# resume with a MOVED head: exit 3, binding stays claimed
rc=0
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$MOVED40" 2>/dev/null || rc=$?
test "$rc" = 3
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# resume with the true observations completes
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --base-sha "$BASE40" --head-sha "$SHA40"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "completed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "failed release leaves no evidence; a displaced binding reads false" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f5-intent.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
# the release itself fails: no intent record exists, so NOTHING claims a
# release happened -- occupancy and ledger are exactly as before.
CLAUDE_CONFIG_DIR="$root" python3 - "$LF_SLUG" "$bid" "$f" <<'EOF'
import sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
import herdr_orch_core as core
slug, bid, f = sys.argv[1:4]
orig = coordination.OwnerTransaction.lead_release
def boom(self, *args, **kwargs):
    raise ValueError("simulated release failure")
coordination.OwnerTransaction.lead_release = boom
try:
    rc = core.main(["teardown-binding", "--repo-slug", slug, "--session", "L1",
                    "--fence", f, "--binding", bid, "--abandon",
                    "--descendants-terminated"])
except SystemExit as exc:  # _require's clean refusal, same as the force path
    rc = exc.code
coordination.OwnerTransaction.lead_release = orig
assert rc == 2, rc
EOF
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
assert "releases" not in entry, entry
' "$LF_SLUG" "$KEY" "$bid"
# B stale-takes-over the never-released workspace
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
bidB=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0 >/dev/null
# retry: A was displaced, never released -- the ledger never named it, so
# generation stays null and lease_released stays false. No invented history.
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --abandon --descendants-terminated
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rec = envelope.read_teardown(core.repo_dir(sys.argv[1]), sys.argv[2])
assert rec["generation"] is None, rec
assert rec["lease_released"] is False, rec
' "$LF_SLUG" "$bid"
SH

check "oversized teardown manifest refused before any release or prune" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f6-cap.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
# 70 review journals with 200-char task ids push the serialized manifest
# past the reader's 16384-byte cap
python3 - "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks" <<'EOF'
import os, sys
d = sys.argv[1]
os.makedirs(d, exist_ok=True)
for i in range(70):
    tid = ("t%03d" % i) + "x" * 196
    with open(os.path.join(d, tid + ".review-log.jsonl"), "w") as fh:
        fh.write("journal line\n")
EOF
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --abandon --descendants-terminated --prune 2>"$ERRFILE"; then exit 1; fi
grep -q "teardown manifest exceeds the size bound" "$ERRFILE"
# refused BEFORE release or prune: the lease survives and the journals do too
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1
COUNT=$(ls "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks" | grep -c '.review-log.jsonl')
[ "$COUNT" = 70 ] || exit 1
SH

check "teardown --abandon refuses while a consumption record exists" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f7-consumed.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
# crash window: consumed durable, completed transition lost
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["status"] = "claimed"
json.dump(rec, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --abandon --descendants-terminated 2>"$ERRFILE"; then exit 1; fi
grep -q "resume integrate-envelope" "$ERRFILE"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "corrupt lease without registry backing refuses cleanly, no traceback" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f8-clean.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
printf 'not json' > "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
reg = coordination.coordination_root() / "bindings.json"
data = json.loads(reg.read_text())
del data[sys.argv[1]]["lead_ws"][sys.argv[2]]
reg.write_text(json.dumps(data))
' "$LF_SLUG" "$KEY"
rc=0
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --abandon --descendants-terminated 2>"$ERRFILE" || rc=$?
test "$rc" = 2
grep -q '^\[X\]' "$ERRFILE"
if grep -q "Traceback" "$ERRFILE"; then exit 1; fi
SH

check "reconcile leaves freshly issued bindings alone, revokes aged ones" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f9-age.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
# fresh issued binding: never claimed, no lease -- apply must NOT revoke it
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "none", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "issued"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# backdate the record past --stale-secs: now it is abandoned state
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["created_ts"] = "2000-01-01T00:00:00Z"
rec["updated_ts"] = "2000-01-01T00:00:00Z"
json.dump(rec, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "revoked", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "revoked"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "reconcile never revokes or releases a claimed binding with a consumption record" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-g1-consumed.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
# crash window: consumed durable, completed transition lost
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["status"] = "claimed"
json.dump(rec, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
# claimed + consumed: the row is resumable integration, never reclaimable
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "needs-integration-resume", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1
# an UNREADABLE consumption record fails closed to manual repair, no mutation
printf 'not json' > "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.consumed.json"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "needs-manual-repair", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
' "$LF_SLUG" "$KEY" "$bid"
SH

check "integrate-envelope refuses a consumption record exceeding the reader cap" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-g2-cap.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
LONG=$(python3 -c 'print("L" * 4200)')
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session "$LONG" --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session "$LONG" --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
# integrated_by carries the 4200-char launcher session: the record would
# exceed the bounded reader's cap, so the writer must refuse it up front.
if CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session "$LONG" --fence "$f" --binding "$bid" 2>"$ERRFILE"; then exit 1; fi
grep -q "consumption record exceeds the size bound" "$ERRFILE"
[ ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.consumed.json" ] || exit 1
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "reconcile-leads refuses a negative --stale-secs before any row" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-g5-neg.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
if CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply --stale-secs -1 2>"$ERRFILE"; then exit 1; fi
grep -q "must be non-negative" "$ERRFILE"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "reconcile cleans a replayed lease of a terminal binding, ledger untouched" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-a6-replay.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
LEASE="$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
cp "$LEASE" "$LEASE.saved"
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --abandon --descendants-terminated
# replay the pre-release lease file over the released, revoked workspace
cp "$LEASE.saved" "$LEASE"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "cleaned-replayed-lease", rows
' "$bid"
[ ! -e "$LEASE" ] || exit 1
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
assert entry["releases"] == {"1": sys.argv[3]}, entry
' "$LF_SLUG" "$KEY" "$bid"
# with the file gone, the terminal row drops out of the scan entirely
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert sys.argv[1] not in rows, rows
' "$bid"
SH

check "claim refuses a stale takeover displacing a consumed occupant" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-a7-takeover.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid"
# crash window: consumed durable, completed transition lost; lease goes stale
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["status"] = "claimed"
json.dump(rec, open(path, "w"))
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
bid2=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-y \
   --workspace-root "$LF_WS" --expected-session S2)
if CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S2 --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid2" --stale-secs 0 2>"$ERRFILE"; then exit 1; fi
grep -q "occupant has a consumption record" "$ERRFILE"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
' "$LF_SLUG" "$KEY" "$bid"
SH

check "unreadable descendant records refuse teardown and reconcile mutation" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-a11-desc.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
mkdir -p "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks"
printf 'not json' > "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-bad.json"
# teardown: the sentinel refuses even WITH --descendants-terminated (the
# flag asserts terminated panes, not ignorable records)
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --abandon --descendants-terminated 2>"$ERRFILE"; then exit 1; fi
grep -q "descendant records are unreadable" "$ERRFILE"
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1
# reconcile: same sentinel classifies needs-manual-repair before revocation
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply --descendants-terminated)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "needs-manual-repair", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1
SH

check "reconcile releases through a list-shaped lease without crashing" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-g4-list.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
# a lease that parses to a LIST: valid JSON, wrong shape -- classify
# corrupt and release with force, never call dict methods on it
printf '[1, 2]' > "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["lease"] == "corrupt", rows
assert rows[sys.argv[1]]["action"] == "revoked+released", rows
' "$bid"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
assert entry["releases"] == {"1": sys.argv[3]}, entry
' "$LF_SLUG" "$KEY" "$bid"
SH

check "teardown lease_released is ledger-only, never a prior manifest boolean" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f1-ledger.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bidA=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA" >/dev/null
# B stale-takes-over the workspace: A stays claimed but never releases.
bidB=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0 >/dev/null
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidA" --abandon >/dev/null
# forge the manifest's boolean: the ledger never attributed A, so a re-run
# must read the release evidence from the ledger and write false again
TD="$root/herdr-orch/$LF_SLUG/leads/$bidA/teardown.json"
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
assert rec["lease_released"] is False, rec
rec["lease_released"] = True
json.dump(rec, open(path, "w"))
' "$TD"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bidA")
printf '%s' "$out" | python3 -c '
import json, sys
rec = json.loads(sys.stdin.read())
assert rec["lease_released"] is False, rec
'
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rec = envelope.read_teardown(core.repo_dir(sys.argv[1]), sys.argv[2])
assert rec["lease_released"] is False, rec
' "$LF_SLUG" "$bidA"
SH

check "claim takeover guard: cross-account or unattested lease refuses outright" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f2-guard.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bidA=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-a \
   --workspace-root "$LF_WS" --expected-session SA)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SA --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidA" >/dev/null
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
LEASE="$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
cp "$LEASE" "$LEASE.saved"
# stale lease belonging to ANOTHER account scope: no cross-account reads,
# no takeover -- refuse outright
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["account_id"] = "acct-elsewhere"
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$LEASE"
bidB=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-b \
   --workspace-root "$LF_WS" --expected-session SB)
if CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0 2>"$ERRFILE"; then exit 1; fi
grep -q "another account scope" "$ERRFILE"
# same account, but the registry entry is gone: a surviving stale lease
# with no corroborating registry entry is unattested evidence -- refuse
cp "$LEASE.saved" "$LEASE"
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$LEASE"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
reg = coordination.coordination_root() / "bindings.json"
data = json.loads(reg.read_text())
del data[sys.argv[1]]["lead_ws"][sys.argv[2]]
reg.write_text(json.dumps(data))
' "$LF_SLUG" "$KEY"
if CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session SB --host h --pid 3 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bidB" --stale-secs 0 2>"$ERRFILE"; then exit 1; fi
grep -q "no corroborating registry" "$ERRFILE"
[ -e "$LEASE" ] || exit 1
SH

check "consumption freeze: set-binding-status, revoked teardown, and reconcile refuse" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f3-freeze.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
SHA40=$(printf 'a%.0s' $(seq 1 40))
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" >/dev/null
BREC="$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# crash window: consumed durable, completed transition lost
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["status"] = "claimed"
json.dump(rec, open(path, "w"))
' "$BREC"
# verb half: no transition OUT of claimed while a consumption record exists
if CLAUDE_CONFIG_DIR="$root" $CLI set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --status revoked 2>"$ERRFILE"; then exit 1; fi
grep -q "resume integrate-envelope" "$ERRFILE"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$BREC"
# an UNREADABLE consumption record fails the verb closed too
CON="$root/herdr-orch/$LF_SLUG/leads/$bid/envelope.consumed.json"
cp "$CON" "$CON.orig"
printf 'not json' > "$CON"
if CLAUDE_CONFIG_DIR="$root" $CLI set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --status revoked 2>/dev/null; then exit 1; fi
cp "$CON.orig" "$CON"
# teardown half: a BYPASSED revocation cannot launder the frozen evidence
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["status"] = "revoked"
json.dump(rec, open(path, "w"))
' "$BREC"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --descendants-terminated 2>"$ERRFILE"; then exit 1; fi
grep -q "revoked binding holds a consumption record" "$ERRFILE"
[ -e "$CON" ] || exit 1
# reconcile half: the revoked+consumed row is repair-only, never released
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "needs-manual-repair", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "revoked"
' "$BREC"
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
' "$LF_SLUG" "$KEY" "$bid"
SH

check "consumption freeze is status-independent: a replayed issued record cannot be revoked or released" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f3-issued.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
SHA40=$(printf 'a%.0s' $(seq 1 40))
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" >/dev/null
BREC="$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
# replay the binding's ORIGINAL issued record while the consumption record
# stays durable: status is a replayable per-binding file, so the freeze
# must key on the consumption record, not the status. Age its timestamp so
# reconcile does not treat it as a fresh never-claimed issue and reaches
# the revoke/release path the consumption record must block.
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["status"] = "issued"
rec["updated_ts"] = "2020-01-01T00:00:00Z"
json.dump(rec, open(path, "w"))
' "$BREC"
# verb half: issued -> revoked is refused while the record exists
if CLAUDE_CONFIG_DIR="$root" $CLI set-binding-status \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --status revoked 2>"$ERRFILE"; then exit 1; fi
grep -q "resume integrate-envelope" "$ERRFILE"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "issued"
' "$BREC"
# reconcile half: the issued+consumed row is repair-only, never revoked or
# released, and the lease/registry stay untouched
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "needs-manual-repair", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "issued"
' "$BREC"
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1
SH

check "teardown: consumed record pins the envelope and stands in when it is absent" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f4-pin.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
SHA40=$(printf 'a%.0s' $(seq 1 40))
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-envelope \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --json '{"task_id":"td-x","attempt":{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},"sequence":1,"summary":{"outcome":"blocked","pr":null,"expected_base_sha":null,"reason":"waiting","follow_ups":[]}}'
CLAUDE_CONFIG_DIR="$root" $CLI integrate-envelope \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" >/dev/null
LEAD_DIR="$root/herdr-orch/$LF_SLUG/leads/$bid"
# a surviving envelope that differs from the consumption record refuses
# before any release, manifest write, or prune
python3 -c '
import json, sys
path, bid = sys.argv[1], sys.argv[2]
rec = {
    "schema_version": 1,
    "binding_id": bid,
    "task_id": "td-x",
    "attempt": None,
    "fence": 1,
    "sequence": 2,
    "ts": "2026-01-01T00:00:00Z",
    "summary": {"outcome": "blocked", "pr": None, "expected_base_sha": None,
                "reason": "tampered", "follow_ups": []},
}
json.dump(rec, open(path, "w"))
' "$LEAD_DIR/envelope.json" "$bid"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --no-artifacts --descendants-terminated 2>"$ERRFILE"; then exit 1; fi
grep -q "does not match the consumption record" "$ERRFILE"
[ ! -e "$LEAD_DIR/teardown.json" ] || exit 1
# absent envelope: the consumed digest is authoritative for the manifest
rm "$LEAD_DIR/envelope.json"
CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --no-artifacts --descendants-terminated >/dev/null
CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys
sys.path.insert(0, "claude/hooks")
import herdr_envelope as envelope
import herdr_orch_core as core
rd = core.repo_dir(sys.argv[1])
rec = envelope.read_teardown(rd, sys.argv[2])
consumed = envelope.read_consumed(rd, sys.argv[2])
assert rec["envelope_sha256"] == consumed["envelope_sha256"], rec
' "$LF_SLUG" "$bid"
# a prior-manifest digest conflicting with the consumed one refuses
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["envelope_sha256"] = "f" * 64
json.dump(rec, open(path, "w"))
' "$LEAD_DIR/teardown.json"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" \
   --no-artifacts --descendants-terminated 2>"$ERRFILE"; then exit 1; fi
grep -q "surviving content conflicts" "$ERRFILE"
SH

check "emit-artifacts durability: store fsync before publish, sweep, fsync again" <<PY
$LOAD
import inspect
src = inspect.getsource(c._main)
region = src[src.index("STAGE 3"):]
assert src.index("os.fsync(tfd)") < src.index("STAGE 3")  # blob bytes first
first = region.index("os.fsync(sfd)")
publish = region.index("write_json_atomic(out, rec)")
sweep = region.index("os.unlink(existing", publish)
second = region.index("os.fsync(sfd)", first + 1)
assert first < publish < sweep < second, (first, publish, sweep, second)
sys.exit(0)
PY

check "reconcile classifies a fence-mismatched lease as replayed, repair-only" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f10-replay.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf1=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
LEASE="$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
cp "$LEASE" "$LEASE.saved"
# same-identity re-claim moves the registry high-water to fence 2
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
# replay the fence-1 lease and age it: its heartbeat proves nothing
cp "$LEASE.saved" "$LEASE"
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$LEASE"
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L1 --fence "$f" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["lease"] == "replayed-lease", rows
assert rows[sys.argv[1]]["action"] == "needs-manual-repair", rows
' "$bid"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
[ -e "$LEASE" ] || exit 1
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] == sys.argv[3], entry
assert entry["last_fence"] == 2, entry
' "$LF_SLUG" "$KEY" "$bid"
SH

check "emit-done/emit-review refuse when the registry does not corroborate the lease" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f11-occ.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
SHA40=$(printf 'a%.0s' $(seq 1 40))
BASE40=$(printf 'b%.0s' $(seq 1 40))
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id PROJ-2 \
   --json '{"task_id":"PROJ-2","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id PROJ-3 \
   --json '{"task_id":"PROJ-3","base_sha":"'"$BASE40"'","review_head_sha":"'"$SHA40"'","workers":[{"role":"mech","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"},{"role":"review","launch_id":"L2","phase":"review","runtime":"claude","workspace_id":"w2","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}]}'
# rewrite the registry entry's fence: the lease no longer matches the
# durable occupancy, so publication is refused at the source
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
reg = coordination.coordination_root() / "bindings.json"
data = json.loads(reg.read_text())
data[sys.argv[1]]["lead_ws"][sys.argv[2]]["last_fence"] += 5
reg.write_text(json.dumps(data))
' "$LF_SLUG" "$KEY"
if CLAUDE_CONFIG_DIR="$root" $CLI emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-2 --workspace w1 \
   --agent mech-td-x --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id L1 --pane-id pane1 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "does not corroborate the lease" "$ERRFILE"
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-2.done.json"
if CLAUDE_CONFIG_DIR="$root" $CLI emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id PROJ-3 --workspace w2 \
   --agent rev-td-x --outcome approved --reviewed-head-sha "$SHA40" --reviewed-base-sha "$BASE40" --blocking-count 0 \
   --runtime claude --launch-id L2 --pane-id pane2 --source-head-sha "$SHA40" \
   --reviewer-session R1 2>"$ERRFILE"; then exit 1; fi
grep -q "does not corroborate the lease" "$ERRFILE"
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/PROJ-3.review.json"
SH

check "claim refuses a binding the release ledger already attributes" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f12-relaunch.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
LEASE="$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
cp "$LEASE" "$LEASE.saved"
# a teardown that crashed after the release but before the revoke: the
# ledger attributes the binding, its record stays "claimed"
CLAUDE_CONFIG_DIR="$root" python3 - "$LF_SLUG" "$LF_WS" <<'EOF'
import os, sys
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
slug, ws = sys.argv[1:3]
with core.owner_transaction(core.repo_dir(slug)) as tx:
    tx.lead_release(os.path.realpath(ws))
EOF
# replay the lease file: without the ledger check this claim would rebuild
# the released occupancy under the same binding
cp "$LEASE.saved" "$LEASE"
if CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" 2>"$ERRFILE"; then exit 1; fi
grep -q "already released on this workspace" "$ERRFILE"
python3 -c '
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
data = json.loads((coordination.coordination_root() / "bindings.json").read_text())
entry = data[sys.argv[1]]["lead_ws"][sys.argv[2]]
assert entry["binding_id"] is None, entry
assert entry["releases"] == {"1": sys.argv[3]}, entry
' "$LF_SLUG" "$KEY" "$bid"
SH

check "write-task carries prior workers forward on an unbound status-only write" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-cf"; mkdir -p "$RD/tasks"
F=$($CLI claim-owner --repo-slug slug-cf --session S --host h --pid 1)
$CLI write-task --repo-slug slug-cf --task-id td-c --session S --fence "$F" \
  --json '{"task_id":"td-c","status":"in-progress","workers":[{"role":"impl","phase":"implement"}]}'
$CLI write-task --repo-slug slug-cf --task-id td-c --session S --fence "$F" \
  --json '{"task_id":"td-c","status":"completed"}'
python3 -c "
import json
d=json.load(open('$RD/tasks/td-c.json'))
assert d['status']=='completed', d
assert d['workers']==[{'role':'impl','phase':'implement'}], d
"
SH

check "write-task first write with no workers persists an empty list" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
RD="$CLAUDE_CONFIG_DIR/herdr-orch/slug-fw"; mkdir -p "$RD/tasks"
F=$($CLI claim-owner --repo-slug slug-fw --session S --host h --pid 1)
$CLI write-task --repo-slug slug-fw --task-id td-f --session S --fence "$F" \
  --json '{"task_id":"td-f","status":"pending"}'
python3 -c "
import json
d=json.load(open('$RD/tasks/td-f.json'))
assert d['workers']==[], d
assert d['status']=='pending', d
"
SH

check "write-task refuses a non-list workers and a row without a phase" <<'SH'
export CLAUDE_CONFIG_DIR=$(mktemp -d)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
F=$($CLI claim-owner --repo-slug slug-rj --session S --host h --pid 1)
# Assert WHICH guard fired, not merely that the verb failed: a bad fence or an
# invalid task-id would also exit non-zero and pass a status-only check.
if $CLI write-task --repo-slug slug-rj --task-id td-r --session S --fence "$F" \
  --json '{"task_id":"td-r","workers":"nope"}' 2>"$CLAUDE_CONFIG_DIR/e1"; then exit 1; fi
grep -q 'task workers must be a list' "$CLAUDE_CONFIG_DIR/e1"
if $CLI write-task --repo-slug slug-rj --task-id td-r --session S --fence "$F" \
  --json '{"task_id":"td-r","workers":[{"role":"impl"}]}' 2>"$CLAUDE_CONFIG_DIR/e2"; then exit 1; fi
grep -q 'rows must be objects carrying a phase' "$CLAUDE_CONFIG_DIR/e2"
test ! -e "$CLAUDE_CONFIG_DIR/herdr-orch/slug-rj/tasks/td-r.json"
SH

check "teardown clears a binding whose task was written but never dispatched" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-wt.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 \
   --control-tier lead --workspace-root "$LF_WS" --binding "$bid")
# The binding's task is written, but no worker is ever dispatched.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" \
   --task-id td-x --json '{"task_id":"td-x","status":"pending"}'
python3 -c "
import json
d=json.load(open('$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.json'))
assert d['workers']==[], d
"
# Before the fix this refused with 'descendant records are unreadable'.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --abandon
python3 -c "
import importlib.util, pathlib
s=importlib.util.spec_from_file_location('core','claude/hooks/herdr_orch_core.py')
c=importlib.util.module_from_spec(s); s.loader.exec_module(c)
rec=c.bindings.read_binding(pathlib.Path('$root/herdr-orch/$LF_SLUG'), '$bid')
assert rec['status']=='revoked', rec
"
SH

check "write-task keeps a bound record holding a legacy row writable" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-lg.git
root=$(mktemp -d)
SHA40=$(printf 'a%.0s' $(seq 1 40))
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 \
   --control-tier lead --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-l \
   --json '{"task_id":"td-l","workers":[]}'
# A row written before the native-row rule existed, injected out of band.
TASKFILE="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-l.json"
python3 -c '
import json, sys
path = sys.argv[1]
record = json.load(open(path))
record["workers"].append({"phase": "implement", "launch_id": "I1"})
json.dump(record, open(path, "w"))
' "$TASKFILE"
# A status-only write inherits the legacy row instead of refusing it.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-l \
   --json '{"task_id":"td-l","status":"in-progress"}'
python3 -c "
import json
d=json.load(open('$TASKFILE'))
assert d['status']=='in-progress', d
assert d['workers']==[{'phase':'implement','launch_id':'I1'}], d
"
# Appending a native successor after the legacy row is still accepted, so the
# lead can keep driving the task; only the NEW row faces the rule.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-l \
   --json '{"task_id":"td-l","workers":[{"phase":"implement","launch_id":"I1"},{"role":"impl","launch_id":"L2","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"p2","source_head_sha":"'"$SHA40"'"}]}'
python3 -c "
import json
d=json.load(open('$TASKFILE'))
assert len(d['workers'])==2, d
assert d['workers'][0]=={'phase':'implement','launch_id':'I1'}, d
assert d['workers'][1]['launch_id']=='L2', d
"
# Forward-only still holds: a NEW non-native row is refused, and by the row
# rule rather than by some unrelated guard such as a stale fence.
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-l \
   --json '{"task_id":"td-l","workers":[{"phase":"implement","launch_id":"I1"},{"role":"impl","launch_id":"L2","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"p2","source_head_sha":"'"$SHA40"'"},{"phase":"review","launch_id":"I3"}]}' 2>"$root/e3"; then exit 1; fi
grep -q 'new task workers must be native dispatch rows' "$root/e3"
SH

check "write-task bound path requires native rows" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-nr.git
root=$(mktemp -d)
SHA40=$(printf 'a%.0s' $(seq 1 40))
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 \
   --control-tier lead --workspace-root "$LF_WS" --binding "$bid")
# A phased-but-not-native row is refused on the bound path.
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-n \
   --json '{"task_id":"td-n","workers":[{"role":"impl","phase":"implement"}]}' 2>/dev/null; then exit 1; fi
test ! -e "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-n.json"
# The full native row is accepted, and its pane is reported, not <unreadable>.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-n \
   --json '{"task_id":"td-n","workers":[{"role":"impl","launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"p1","source_head_sha":"'"$SHA40"'"}]}'
python3 -c "
import importlib.util, pathlib
s=importlib.util.spec_from_file_location('core','claude/hooks/herdr_orch_core.py')
c=importlib.util.module_from_spec(s); s.loader.exec_module(c)
d=c.outstanding_descendants(pathlib.Path('$root/herdr-orch/$LF_SLUG'), '$bid')
assert d==['p1'], d
"
SH

check "task-lead-status reports disabled and refuses admission on a fresh root" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-tls.git
root=$(mktemp -d)
out=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py task-lead-status \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO")
printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["gate_enabled"] is False, d
assert d["admit"] is False, d
assert d["required"] == 1, d
assert d["core"] == 1 and d["guard"] == 1, d
assert isinstance(d["gate_reason"], str) and d["gate_reason"], d
assert isinstance(d["admit_reason"], str) and d["admit_reason"], d
'
SH

check "task-lead-status agrees with what a real claim would do" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-tlsa.git
root=$(mktemp -d)
# An enabled, fully-capable, identity-bearing gate. status must report
# admit:true here, and a real claim must succeed. The two must never disagree:
# status omitting repo_id while the claim path supplies it would produce
# admit:false from status and a successful claim, which is worse than useless.
CLAUDE_CONFIG_DIR="$root" python3 -c '
import json, os, sys
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
slug, repo = sys.argv[1:3]
ctx = core.repository_context(repo)
scope = core.account_scope(ctx["root"], "claude")
rd = core.repo_dir(slug); rd.mkdir(parents=True, exist_ok=True)
core.write_json_atomic(rd / "task-lead-gate.json", {
    "schema_version": 1, "repo_slug": slug, "repo_id": ctx["repo_id"],
    "account_id": scope["account_id"], "enabled": True})
skill = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "skills", "herdr-orchestration")
os.makedirs(skill, exist_ok=True)
open(os.path.join(skill, "SKILL.md"), "w").write(
    chr(60) + "!-- herdr-capabilities: " + json.dumps({"marker_version":1,"capability":1}) + " --" + chr(62) + chr(10))
' "$LF_SLUG" "$LF_REPO"
out=$(CLAUDE_CONFIG_DIR="$root" HERDR_FIXTURE_NO_SEED=1 python3 claude/hooks/herdr_legacy_fixture.py task-lead-status \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO")
printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["gate_enabled"] is True, d
assert d["admit"] is True, d
'
# Status said admit:true. Now prove a REAL claim agrees. Without this the test
# only exercises the status handler, and the two could still diverge -- which
# is the exact defect this case exists to catch. NO_SEED keeps the fixture from
# overwriting the identity-bearing gate with a repo_id:None one.
f=$(CLAUDE_CONFIG_DIR="$root" HERDR_FIXTURE_NO_SEED=1 python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" HERDR_FIXTURE_NO_SEED=1 python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-agree \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" HERDR_FIXTURE_NO_SEED=1 python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
test -n "$lf"
python3 -c '
import json, os, sys
root, bid, slug = sys.argv[1:4]
rec = json.load(open(os.path.join(root, "herdr-orch", slug, "bindings", bid + ".json")))
assert rec["status"] == "claimed", rec
gate = json.load(open(os.path.join(root, "herdr-orch", slug, "task-lead-gate.json")))
assert gate["repo_id"] is not None, gate
' "$root" "$bid" "$LF_SLUG"
SH

check "task-lead-status exits 0 even when leads are not admissible" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-tls0.git
root=$(mktemp -d)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py task-lead-status \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" >/dev/null
SH

check "fixture publishes an enabled gate and a capable procedure for a lead claim" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-fx.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-fx \
   --workspace-root "$LF_WS" --expected-session S1)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" >/dev/null
python3 -c '
import json, os, sys
root, slug = sys.argv[1:3]
gate = json.load(open(os.path.join(root, "herdr-orch", slug, "task-lead-gate.json")))
assert gate["enabled"] is True, gate
assert gate["repo_slug"] == slug, gate
assert gate["schema_version"] == 1, gate
marker = open(os.path.join(root, "skills", "herdr-orchestration", "SKILL.md"), encoding="utf-8").read()
assert "capability:1" in marker.replace(" ", "").replace(chr(34), ""), marker
' "$root" "$LF_SLUG"
SH

check "lead claim is refused when the gate record is absent" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-ga.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-ga \
   --workspace-root "$LF_WS" --expected-session S1)
# Seed the capable procedure marker but NOT the gate, so the ONLY reason to
# refuse is gate absence. HERDR_FIXTURE_NO_SEED stops the fixture recreating it.
mkdir -p "$root/skills/herdr-orchestration"
printf '%s\n' '<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->' \
   > "$root/skills/herdr-orchestration/SKILL.md"
rm -f "$root/herdr-orch/$LF_SLUG/task-lead-gate.json"
err=$(CLAUDE_CONFIG_DIR="$root" HERDR_FIXTURE_NO_SEED=1 python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" 2>&1 >/dev/null) && exit 1
printf '%s' "$err" | grep -q 'gate record absent'
# The binding must be untouched and NO coordination lease may exist for this
# workspace. The lease lives in the coordination root keyed by
# lead_lease_key(realpath(workspace_root)), not in the payload root.
python3 -c '
import hashlib, json, os, sys
root, bid, slug, ws = sys.argv[1:5]
rec = json.load(open(os.path.join(root, "herdr-orch", slug, "bindings", bid + ".json")))
assert rec["status"] == "issued", rec
key = hashlib.sha256(os.path.realpath(ws).encode()).hexdigest()[:16]
lease = os.path.join(os.environ["HERDR_COORDINATION_ROOT"], slug, "lead-%s.json" % key)
assert not os.path.exists(lease), lease
' "$root" "$bid" "$LF_SLUG" "$LF_WS"
SH

check "lead claim is refused when the procedure is under-level" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-gp.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-gp \
   --workspace-root "$LF_WS" --expected-session S1)
# ENABLE the gate, so the only remaining reason to refuse is the procedure
# level. Write the REAL SKILL.md the reader resolves, at capability 0.
CLAUDE_CONFIG_DIR="$root" python3 -c '
import json, os, sys
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
slug = sys.argv[1]
scope = core.account_scope(sys.argv[2], "claude")
rd = core.repo_dir(slug); rd.mkdir(parents=True, exist_ok=True)
core.write_json_atomic(rd / "task-lead-gate.json", {
    "schema_version": 1, "repo_slug": slug, "repo_id": None,
    "account_id": scope["account_id"], "enabled": True})
' "$LF_SLUG" "$LF_REPO"
mkdir -p "$root/skills/herdr-orchestration"
printf '%s\n' '<!-- herdr-capabilities: {"marker_version":1,"capability":0} -->' \
   > "$root/skills/herdr-orchestration/SKILL.md"
err=$(CLAUDE_CONFIG_DIR="$root" HERDR_FIXTURE_NO_SEED=1 python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" 2>&1 >/dev/null) && exit 1
printf '%s' "$err" | grep -q 'procedure advertises capability 0'
SH

check "lead claim is refused when core or guard is under-level" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-gc.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-gc \
   --workspace-root "$LF_WS" --expected-session S1)
# Everything enabled and capable; drive core and guard under-level one at a
# time and assert each refuses a REAL claim. The claim goes through core.main
# -- the same argv path the CLI takes -- not through task_lead_admission
# directly: a claim path that never consulted these constants would satisfy a
# direct-admission assertion unchanged, which is what this case used to do.
CLAUDE_CONFIG_DIR="$root" python3 -c '
import json, os, sys
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
import herdr_capabilities as hc
slug, repo, ws, bid = sys.argv[1:5]
scope = core.account_scope(repo, "claude")
rd = core.repo_dir(slug); rd.mkdir(parents=True, exist_ok=True)
core.write_json_atomic(rd / "task-lead-gate.json", {
    "schema_version": 1, "repo_slug": slug, "repo_id": None,
    "account_id": scope["account_id"], "enabled": True})
skill = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "skills", "herdr-orchestration")
os.makedirs(skill, exist_ok=True)
open(os.path.join(skill, "SKILL.md"), "w").write(
    chr(60) + "!-- herdr-capabilities: " + json.dumps({"marker_version":1,"capability":1}) + " --" + chr(62) + chr(10))

def claim():
    return core.main(["claim-owner", "--repo-slug", slug, "--repo-path", repo,
                      "--session", "S1", "--host", "h", "--pid", "2",
                      "--control-tier", "lead", "--workspace-root", ws,
                      "--binding", bid])

for name in ("CORE_CAPABILITY", "GUARD_CAPABILITY"):
    saved = getattr(hc, name)
    setattr(hc, name, 0)
    try:
        rc = claim()
    except SystemExit as exc:
        rc = exc.code
    finally:
        setattr(hc, name, saved)
    assert rc != 0, (name, "an under-level claim was admitted")

admit, reason, _ = core.task_lead_admission(
    rd, slug, scope["account_id"], os.environ["CLAUDE_CONFIG_DIR"],
    core.repository_context(repo)["repo_id"])
assert admit is True, reason
' "$LF_SLUG" "$LF_REPO" "$LF_WS" "$bid"
SH

check "lead claim is refused when the gate names another account" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-gx.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-gx \
   --workspace-root "$LF_WS" --expected-session S1)
mkdir -p "$root/skills/herdr-orchestration" "$root/herdr-orch/$LF_SLUG"
printf '%s\n' '<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->' \
   > "$root/skills/herdr-orchestration/SKILL.md"
python3 -c '
import json, os, sys
p = os.path.join(sys.argv[1], "herdr-orch", sys.argv[2], "task-lead-gate.json")
open(p, "w").write(json.dumps({"schema_version":1,"repo_slug":sys.argv[2],"repo_id":None,
  "account_id":"someone-else","enabled":True}))
' "$root" "$LF_SLUG"
err=$(CLAUDE_CONFIG_DIR="$root" HERDR_FIXTURE_NO_SEED=1 python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid" 2>&1 >/dev/null) && exit 1
printf '%s' "$err" | grep -q 'different account'
SH

check "a plain launcher claim is unaffected by an absent gate" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-gl.git
root=$(mktemp -d)
CLAUDE_CONFIG_DIR="$root" HERDR_FIXTURE_NO_SEED=1 python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1 >/dev/null
SH

check "a context-less lead claim raises ValueError, not a scope crash" <<PY
$LOAD
root=tempfile.mkdtemp();os.environ["CLAUDE_CONFIG_DIR"]=root
rd=c.repo_dir("slug-ctxless");rd.mkdir(parents=True)
with c.coordination.owner_transaction(rd, canonical_id="fixture-ctxless", expected_slug="slug-ctxless"):
    pass                                                # explicit identity permits an unbound claim
c.claim_owner(rd, "L1", "h", 1)  # legacy launcher claim so an owner exists
try:
    c.claim_owner(rd, "S1", "h", 2, control_tier="lead",
                  workspace_root="/tmp/slug-ctxless-ws",
                  binding_id="ldb-" + "0" * 32,
                  context=None, scope=None)
    raise AssertionError("claim_owner did not raise")
except ValueError as exc:
    assert str(exc) == "a lead claim requires repository context", str(exc)
except Exception as exc:
    raise AssertionError(f"expected ValueError, got {type(exc).__name__}: {exc}")
sys.exit(0)
PY

check "deactivate-task-leads is idempotent and leaves identical bytes" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-dt.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py deactivate-task-leads \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f"
a=$(shasum "$root/herdr-orch/$LF_SLUG/task-lead-gate.json" | cut -d' ' -f1)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py deactivate-task-leads \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f"
b=$(shasum "$root/herdr-orch/$LF_SLUG/task-lead-gate.json" | cut -d' ' -f1)
test "$a" = "$b"
python3 -c '
import json,os,sys
d=json.load(open(os.path.join(sys.argv[1],"herdr-orch",sys.argv[2],"task-lead-gate.json")))
assert d["enabled"] is False, d
' "$root" "$LF_SLUG"
SH

check "deactivate-task-leads replaces a damaged record with a valid disabled one" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-dd.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
mkdir -p "$root/herdr-orch/$LF_SLUG"
printf '%s' '{not json' > "$root/herdr-orch/$LF_SLUG/task-lead-gate.json"
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py deactivate-task-leads \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f"
python3 -c '
import json,os,sys
d=json.load(open(os.path.join(sys.argv[1],"herdr-orch",sys.argv[2],"task-lead-gate.json")))
assert d["enabled"] is False and d["schema_version"] == 1, d
' "$root" "$LF_SLUG"
SH

check "deactivate-task-leads normalizes a wrong-version or foreign-account record" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-dn.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
mkdir -p "$root/herdr-orch/$LF_SLUG"
for payload in \
  '{"schema_version":99,"repo_slug":"x","repo_id":null,"account_id":"a","enabled":true}' \
  '{"schema_version":1,"repo_slug":"x","repo_id":null,"account_id":"someone-else","enabled":true}'
do
  printf '%s' "$payload" > "$root/herdr-orch/$LF_SLUG/task-lead-gate.json"
  CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py deactivate-task-leads \
     --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f"
  python3 -c '
import json,os,sys
d=json.load(open(os.path.join(sys.argv[1],"herdr-orch",sys.argv[2],"task-lead-gate.json")))
assert d["enabled"] is False, d
assert d["schema_version"] == 1, d
assert d["repo_slug"] == sys.argv[2], d
assert d["account_id"] != "someone-else", d
' "$root" "$LF_SLUG"
done
SH

check "deactivate-task-leads is refused for a wrong session with a correct fence" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-dw.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py deactivate-task-leads \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session IMPOSTOR --fence "$f" 2>/dev/null; then exit 1; fi
test ! -f "$root/herdr-orch/$LF_SLUG/task-lead-gate.json"
SH

check "a failed publication leaves the prior gate bytes intact and exits non-zero" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-dp.git
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py deactivate-task-leads \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f"
before=$(shasum "$root/herdr-orch/$LF_SLUG/task-lead-gate.json" | cut -d' ' -f1)
# Fault injection: make the payload dir unwritable so the temp-file create fails
# BEFORE any replace. The prior record must survive byte-identical.
chmod 500 "$root/herdr-orch/$LF_SLUG"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py deactivate-task-leads \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" 2>/dev/null; then
  chmod 700 "$root/herdr-orch/$LF_SLUG"; exit 1
fi
chmod 700 "$root/herdr-orch/$LF_SLUG"
after=$(shasum "$root/herdr-orch/$LF_SLUG/task-lead-gate.json" | cut -d' ' -f1)
test "$before" = "$after"
SH

check "deactivate-task-leads is refused without a valid fence" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-df.git
root=$(mktemp -d)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1 >/dev/null
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py deactivate-task-leads \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence 9999 2>/dev/null; then exit 1; fi
SH

check "there is no activation verb: the CLI rejects one and no handler writes an enabled gate" <<'SH'
if python3 claude/hooks/herdr_orch_core.py activate-task-leads 2>/dev/null; then exit 1; fi
if grep -qE '"enabled"[[:space:]]*:[[:space:]]*True' claude/hooks/herdr_orch_core.py; then exit 1; fi
SH

check "reserve-dispatch: a settled identity cannot be reserved again; an unsettled one can" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-dup-tuple.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-dup \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
H=$(printf 'a%.0s' $(seq 1 40))
H2=$(printf 'b%.0s' $(seq 1 40))
TASK="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-dup.json"
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-dup \
   --json '{"task_id":"td-dup","workers":[]}'
# A review detour: dispatch at H, advance to H2, then return to H. The
# returning row repeats H's identity but nothing has settled it, so it is a
# legitimate re-dispatch and must be appended (the :4405 shape).
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-dup \
   --launch-id L2 --phase review --runtime claude --workspace-id w2 \
   --pane-id pane2 --source-head-sha "$H"
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-dup \
   --launch-id L2 --phase review --runtime claude --workspace-id w2 \
   --pane-id pane2 --source-head-sha "$H2"
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-dup \
   --launch-id L2 --phase review --runtime claude --workspace-id w2 \
   --pane-id pane2 --source-head-sha "$H"
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
shas = [w["source_head_sha"] for w in rec["workers"]]
assert len(shas) == 3 and shas[0] == shas[2] and shas[0] != shas[1], rec
' "$TASK"
# Now settle the current (H) review attempt. Re-reserving that exact identity
# is then refused: it would arrive already settled and empty the outstanding
# set while pane2 is live.
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-dup \
   --json '{"task_id":"td-dup","review_head_sha":"'"$H"'","base_sha":"'"$H"'","workers":['"$(python3 -c '
import json, sys
print(json.dumps(json.load(open(sys.argv[1]))["workers"])[1:-1])
' "$TASK")"']}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-review \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-dup --workspace w2 \
   --agent rev-td-dup --outcome approved --reviewed-head-sha "$H" --reviewed-base-sha "$H" \
   --blocking-count 0 --runtime claude --launch-id L2 --pane-id pane2 \
   --source-head-sha "$H" --reviewer-session R1
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-dup \
   --launch-id L2 --phase review --runtime claude --workspace-id w2 \
   --pane-id pane2 --source-head-sha "$H2" 2>/dev/null; then :; else exit 1; fi
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-dup \
   --launch-id L2 --phase review --runtime claude --workspace-id w2 \
   --pane-id pane2 --source-head-sha "$H" 2>"$ERRFILE"; then exit 1; fi
grep -q "already settled" "$ERRFILE"
SH


check "reserve-dispatch: appends a native row, idempotent on exact replay" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-reserve.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-r \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
SHA40B=$(printf 'b%.0s' $(seq 1 40))
TASK="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-r.json"
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-r \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "no task record" "$ERRFILE"
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-r \
   --json '{"task_id":"td-r","workers":[]}'
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-r \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" --role mech --agent mech-td-r
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert len(rec["workers"]) == 1, rec
w = rec["workers"][0]
assert w["launch_id"] == "L1" and w["pane_id"] == "pane1", w
assert w["role"] == "mech" and w["agent"] == "mech-td-r", w
' "$TASK"
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --abandon 2>"$ERRFILE"; then exit 1; fi
grep -q "outstanding descendants" "$ERRFILE"
grep -q "pane1" "$ERRFILE"
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-r \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40"
python3 -c '
import json, sys
assert len(json.load(open(sys.argv[1]))["workers"]) == 1
' "$TASK"
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-r \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40"
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert [w["pane_id"] for w in rec["workers"]] == ["pane1", "pane2"], rec
' "$TASK"
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-r \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40B"
# Repeating pane1's earlier identity is allowed while nothing has settled it:
# that is a legitimate re-dispatch back to a prior head. (The settled case is
# refused -- see the settled-identity check.)
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-r \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40"
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
panes = [w["pane_id"] for w in rec["workers"]]
assert panes == ["pane1", "pane2", "pane2", "pane1"], rec
' "$TASK"
SH

check "reserve-dispatch: input and scope guards" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-reserve-guard.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-g \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-g \
   --json '{"task_id":"td-g","workers":[]}'
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-g \
   --launch-id L1 --phase nonsense --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "phase must be one of" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-g \
   --launch-id L1 --phase implement --runtime claude --workspace-id 'w-1' \
   --pane-id pane1 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "invalid workspace-id" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-g \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha notasha 2>"$ERRFILE"; then exit 1; fi
grep -q "source-head-sha must be 40 hex" "$ERRFILE"
# An unparseable pane id would produce the <unreadable> sentinel, which
# --descendants-terminated deliberately does not override and append-only
# cannot remove: the binding would be tearable only by on-disk repair.
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-g \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id '<unreadable>' --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "pane-id must be shell-safe" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-g \
   --launch-id 'bad id' --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "launch-id must be shell-safe" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-g \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id '' --source-head-sha "$SHA40" 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --task-id td-g \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" 2>/dev/null; then exit 1; fi
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence 99 --binding "$bid" --task-id td-g \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" 2>/dev/null; then exit 1; fi
python3 -c '
import json, sys
p = sys.argv[1]
rec = json.load(open(p)); rec["task_id"] = "other"; json.dump(rec, open(p, "w"))
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-g.json"
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-g \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "task_id" "$ERRFILE"
SH

check "enrich-dispatch: identity-preserving update of the current attempt" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-enrich.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-e \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
SHA40=$(printf 'a%.0s' $(seq 1 40))
TASK="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-e.json"
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-e \
   --json '{"task_id":"td-e","workers":[]}'
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-e \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40"
BEFORE=$(CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys; sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
print(core.outstanding_descendants(core.repo_dir(sys.argv[1]), sys.argv[2]))
' "$LF_SLUG" "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-e \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" --json '{"peer_name":"impl-td-e"}'
AFTER=$(CLAUDE_CONFIG_DIR="$root" python3 -c '
import sys; sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
print(core.outstanding_descendants(core.repo_dir(sys.argv[1]), sys.argv[2]))
' "$LF_SLUG" "$bid")
[ "$BEFORE" = "$AFTER" ]
[ "$BEFORE" = "['pane1']" ]
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert len(rec["workers"]) == 1, rec
w = rec["workers"][0]
assert w["peer_name"] == "impl-td-e", w
assert w["launch_id"] == "L1" and w["pane_id"] == "pane1", w
' "$TASK"
if CLAUDE_CONFIG_DIR="$root" $CLI enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-e \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" --json '{"pane_id":"pane9"}' 2>"$ERRFILE"; then exit 1; fi
grep -q "identity field" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" $CLI enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-e \
   --launch-id NOPE --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" --json '{"peer_name":"x"}' 2>"$ERRFILE"; then exit 1; fi
grep -q "not the current attempt" "$ERRFILE"
# A replayed enrichment must NOT land on a later attempt that reuses the
# launch_id: the full identity is what finds the row.
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-e \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40"
if CLAUDE_CONFIG_DIR="$root" $CLI enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-e \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" --json '{"peer_name":"stale"}' 2>"$ERRFILE"; then exit 1; fi
grep -q "not the current attempt" "$ERRFILE"
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert rec["workers"][-1]["pane_id"] == "pane2", rec
assert "peer_name" not in rec["workers"][-1], rec
' "$TASK"
if CLAUDE_CONFIG_DIR="$root" $CLI enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-e \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40" --json '[]' 2>/dev/null; then exit 1; fi
SH


check "teardown fail-open: settled I1, running I2, refused publication" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-failopen.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
SHA40=$(printf 'a%.0s' $(seq 1 40))
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-fo \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-fo \
   --json '{"task_id":"td-fo","workers":[]}'
# I1 is reserved, dispatched, and settles.
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-fo \
   --launch-id I1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40"
CLAUDE_CONFIG_DIR="$root" $CLI emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-fo --workspace w1 \
   --agent impl-td-fo --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id I1 --pane-id pane1 --source-head-sha "$SHA40"
# I2 is reserved and its pane goes live.
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-fo \
   --launch-id I2 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40"
# The lead publishes a further row that the ROW RULE refuses: it omits
# pane_id. The payload carries the full reserved prefix, so the append-only
# check passes and the row rule is what fires -- the exact refusal the source
# todo names as the cause of the fail-open.
I1ROW='{"launch_id":"I1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane1","source_head_sha":"'"$SHA40"'"}'
I2ROW='{"launch_id":"I2","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"pane2","source_head_sha":"'"$SHA40"'"}'
if CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-fo \
   --json '{"task_id":"td-fo","workers":['"$I1ROW"','"$I2ROW"',{"phase":"implement","launch_id":"I3","runtime":"claude","workspace_id":"w1","source_head_sha":"'"$SHA40"'"}]}' 2>"$ERRFILE"; then exit 1; fi
grep -q "must be native dispatch rows" "$ERRFILE"
# The reservation survives the refusal, so teardown must REFUSE, naming pane2.
if CLAUDE_CONFIG_DIR="$root" $CLI teardown-binding \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --binding "$bid" --abandon 2>"$ERRFILE"; then exit 1; fi
grep -q "outstanding descendants" "$ERRFILE"
grep -q "pane2" "$ERRFILE"
python3 -c '
import json, sys
assert json.load(open(sys.argv[1]))["status"] == "claimed", "lease must NOT be released"
' "$root/herdr-orch/$LF_SLUG/bindings/$bid.json"
SH

check "reconcile-leads defers release while a RESERVED descendant is outstanding" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rl-reserved.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
SHA40=$(printf 'a%.0s' $(seq 1 40))
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[]}'
# The row arrives by reservation, not by write-task.
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --launch-id L1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40"
KEY=$(python3 -c '
import os, sys; sys.path.insert(0, "claude/hooks")
import herdr_coordination as coordination
print(coordination.lead_lease_key(os.path.realpath(sys.argv[1])))' "$LF_WS")
python3 -c '
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec["heartbeat_ts"] = 0
json.dump(rec, open(path, "w"))
' "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json"
f2=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L2 --host h --pid 3 --stale-secs 0)
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "needs-descendant-termination", rows
' "$bid"
[ -e "$HERDR_COORDINATION_ROOT/$LF_SLUG/lead-$KEY.json" ] || exit 1
out=$(CLAUDE_CONFIG_DIR="$root" $CLI reconcile-leads --repo-slug "$LF_SLUG" --session L2 --fence "$f2" --apply --descendants-terminated)
printf '%s' "$out" | python3 -c '
import json, sys
rows = {r["binding_id"]: r for r in json.loads(sys.stdin.read())["bindings"]}
assert rows[sys.argv[1]]["action"] == "released", rows
' "$bid"
SH


check "reserve-dispatch: a settled CURRENT row is not an idempotent replay" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-f1.git
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
SHA40=$(printf 'a%.0s' $(seq 1 40))
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" $CLI issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-f1 \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" $CLI claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 --control-tier lead \
   --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" $CLI write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-f1 \
   --json '{"task_id":"td-f1","workers":[]}'
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-f1 \
   --launch-id I1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40"
# The attempt settles. Its identity is now the CURRENT row and settled.
CLAUDE_CONFIG_DIR="$root" $CLI emit-done \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --binding "$bid" --task-id td-f1 --workspace w1 \
   --agent impl-td-f1 --phase implement --outcome completed --head-sha h1 --base-sha b0 \
   --runtime claude --launch-id I1 --pane-id pane1 --source-head-sha "$SHA40"
# Reusing that exact identity for a NEW dispatch must NOT be swallowed as a
# retry: writing nothing would leave the pane the caller is about to start
# invisible to teardown.
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-f1 \
   --launch-id I1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane1 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "already settled" "$ERRFILE"
# An UNSETTLED current row still replays idempotently.
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-f1 \
   --launch-id I2 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40"
CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-f1 \
   --launch-id I2 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40"
python3 -c '
import json, sys
rec = json.load(open(sys.argv[1]))
assert [w["launch_id"] for w in rec["workers"]] == ["I1", "I2"], rec
' "$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-f1.json"
# A reservation whose task does not match the binding is refused.
if CLAUDE_CONFIG_DIR="$root" $CLI reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-other \
   --launch-id I3 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane3 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q "does not match the binding" "$ERRFILE"
# The same pin on enrich-dispatch.
if CLAUDE_CONFIG_DIR="$root" $CLI enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-other \
   --launch-id I2 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40" --json '{"peer_name":"x"}' 2>"$ERRFILE"; then exit 1; fi
grep -q "does not match the binding" "$ERRFILE"
# Enrichment payload constraints: record-level keys and non-scalars refused.
if CLAUDE_CONFIG_DIR="$root" $CLI enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-f1 \
   --launch-id I2 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40" --json '{"task_id":"OTHER"}' 2>"$ERRFILE"; then exit 1; fi
grep -q "task record field" "$ERRFILE"
if CLAUDE_CONFIG_DIR="$root" $CLI enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" --task-id td-f1 \
   --launch-id I2 --phase implement --runtime claude --workspace-id w1 \
   --pane-id pane2 --source-head-sha "$SHA40" --json '{"role":["not","a","string"]}' 2>"$ERRFILE"; then exit 1; fi
grep -q "must be scalars" "$ERRFILE"
SH

check "write-task bound path refuses invalid identity values per field" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-rv.git
root=$(mktemp -d)
SHA40=$(printf 'a%.0s' $(seq 1 40))
SHA39=$(printf 'a%.0s' $(seq 1 39))
SHAUP=$(printf 'A%.0s' $(seq 1 40))
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-v \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 \
   --control-tier lead --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-v \
   --json '{"task_id":"td-v","workers":[]}'
TASKFILE="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-v.json"
BEFORE=$(cat "$TASKFILE")
# One invalid VALUE per attempt; every other field is valid, so the refusal
# can only come from the value rule. The message is the existing row-rule
# string, asserted so a stale fence or bad task id cannot pass this check.
for row in \
  '{"launch_id":"L1","phase":"implement","runtime":"other","workspace_id":"w1","pane_id":"p1","source_head_sha":"'"$SHA40"'"}' \
  '{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"p1","source_head_sha":"'"$SHA39"'"}' \
  '{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"p1","source_head_sha":"'"$SHAUP"'"}' \
  '{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w 1","pane_id":"p1","source_head_sha":"'"$SHA40"'"}' \
  '{"launch_id":"L1","phase":"implement","runtime":"claude","workspace_id":"w1","pane_id":"<unreadable>","source_head_sha":"'"$SHA40"'"}'
do
  if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
     --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-v \
     --json '{"task_id":"td-v","workers":['"$row"']}' 2>"$ERRFILE"; then
    echo "accepted invalid row: $row" >&2; exit 1
  fi
  grep -q 'new task workers must be native dispatch rows' "$ERRFILE"
  [ "$(cat "$TASKFILE")" = "$BEFORE" ]
done
# The fully valid row is still accepted, so the rule is not simply "refuse".
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-v \
   --json '{"task_id":"td-v","workers":[{"launch_id":"L1","phase":"implement","runtime":"codex","workspace_id":"w1","pane_id":"p1","source_head_sha":"'"$SHA40"'"}]}'
python3 -c "
import json
d=json.load(open('$TASKFILE'))
assert len(d['workers'])==1 and d['workers'][0]['runtime']=='codex', d
"
# Unit view of the same rule, and the sentinel constant the reader shares.
python3 -c "
import importlib.util
s=importlib.util.spec_from_file_location('core','claude/hooks/herdr_orch_core.py')
c=importlib.util.module_from_spec(s); s.loader.exec_module(c)
row=dict(launch_id='L1',phase='implement',runtime='claude',workspace_id='w1',pane_id='p1',source_head_sha='a'*40)
assert c._native_worker_row(row)
for k,v in (('runtime','other'),('source_head_sha','a'*39),('source_head_sha','A'*40),('workspace_id','w 1'),('pane_id','<unreadable>')):
    assert not c._native_worker_row({**row,k:v}), (k,v)
assert c.UNREADABLE_SENTINEL=='<unreadable>'
"
SH

check "write-task and outstanding_descendants catch decoder recursion" <<PY
$LOAD
import contextlib, io, pathlib
# This Python's C decoder never raises RecursionError from a real document, so
# each site is pinned with a stub; narrowing a tuple back would otherwise pass.
def _deep(*a, **k):
    raise RecursionError("maximum recursion depth exceeded")

# 1. The payload parse helper write-task uses.
_real_loads = c.json.loads
c.json.loads = _deep
try:
    assert c._parse_payload('{"task_id":"T"}') is None
finally:
    c.json.loads = _real_loads
assert c._parse_payload('{"task_id":"T"}') == {"task_id": "T"}
assert c._parse_payload('not json') is None

# 2. outstanding_descendants: a task record whose read recurses, then a
# settlement record whose read recurses. Each yields the sentinel list.
root = tempfile.mkdtemp(); os.environ["CLAUDE_CONFIG_DIR"] = root
rd = c.repo_dir("slug-rec"); base = rd / "leads" / "ldb-rec" / "tasks"
base.mkdir(parents=True)
row = {"launch_id": "L1", "phase": "implement", "runtime": "claude",
       "workspace_id": "w1", "pane_id": "p1", "source_head_sha": "a" * 40}
(base / "td-r.json").write_text(json.dumps({"task_id": "td-r", "workers": [row]}))
assert c.outstanding_descendants(rd, "ldb-rec") == ["p1"]
_real_read = c.read_payload_text
c.read_payload_text = _deep
try:
    assert c.outstanding_descendants(rd, "ldb-rec") == [c.UNREADABLE_SENTINEL]
finally:
    c.read_payload_text = _real_read
def _deep_settle(path):
    if str(path).endswith(".done.json"):
        raise RecursionError("maximum recursion depth exceeded")
    return _real_read(path)
(base / "td-r.done.json").write_text("{}")
c.read_payload_text = _deep_settle
try:
    assert c.outstanding_descendants(rd, "ldb-rec") == [c.UNREADABLE_SENTINEL]
finally:
    c.read_payload_text = _real_read
sys.exit(0)
PY

check "task record writers refuse a record over the dispatch reader limit" <<'SH'
. "$LEAD_FIXTURE_HELPER"; lead_fixture https://example.com/repo-big.git
root=$(mktemp -d)
SHA40=$(printf 'a%.0s' $(seq 1 40))
CORE_PY='import importlib.util
s=importlib.util.spec_from_file_location("core","claude/hooks/herdr_orch_core.py")
c=importlib.util.module_from_spec(s); s.loader.exec_module(c)'
# Unit: the helper measures the bytes atomic_json_at publishes (sorted keys,
# compact separators, one trailing newline) and refuses only above the cap:
# the largest accepted JSON body is cap - 1 bytes.
python3 -c "
$CORE_PY
import contextlib, io, json
cap = c.TASK_RECORD_MAX_BYTES
assert cap == 2_000_000
base = {'task_id': 'td-b', 'workers': [], 'pad': ''}
overhead = len(json.dumps(base, sort_keys=True, separators=(',', ':')).encode())
largest = {**base, 'pad': 'x' * (cap - 1 - overhead)}
assert len(json.dumps(largest, sort_keys=True, separators=(',', ':')).encode()) + 1 == cap
c._require_record_within_reader_limit(largest)
err = io.StringIO()
try:
    with contextlib.redirect_stderr(err):
        c._require_record_within_reader_limit({**base, 'pad': 'x' * (cap - overhead)})
    raise AssertionError('oversized record must be refused')
except SystemExit as exc:
    assert exc.code == 2, exc.code
assert 'exceed the 2000000-byte dispatch reader limit' in err.getvalue(), err.getvalue()
# Parity with the reader: the literal in herdr_dispatch._read_json.
src = open('claude/hooks/herdr_dispatch.py').read()
body = src.split('def _read_json')[1].split('def _read_task')[0]
assert '2_000_000' in body, 'reader cap moved; update TASK_RECORD_MAX_BYTES parity'
"
# Launcher scope: a prior record padded to the cap through its one worker row.
# write-task omitting workers inherits that row, so the small payload resolves
# to an oversized record and must be refused; ARG_MAX forbids passing 2 MB.
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --session L1 --host h --pid 1)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --task-id td-b \
   --json '{"task_id":"td-b","status":"kickoff","workers":[{"phase":"implement","note":"small"}]}'
TASKFILE="$root/herdr-orch/$LF_SLUG/tasks/td-b.json"
python3 -c "
import json, sys
path = sys.argv[1]
rec = json.load(open(path))
rec['workers'][0]['note'] = 'x' * 1_999_900
json.dump(rec, open(path, 'w'), sort_keys=True, separators=(',', ':'))
" "$TASKFILE"
BEFORE=$(shasum -a 256 "$TASKFILE")
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --task-id td-b \
   --json '{"task_id":"td-b","status":"a-status-long-enough-to-cross-the-cap-by-itself-when-added-to-the-padded-row"}' 2>"$ERRFILE"; then exit 1; fi
grep -q 'exceed the 2000000-byte dispatch reader limit' "$ERRFILE"
[ "$(shasum -a 256 "$TASKFILE")" = "$BEFORE" ]
# A same-count explicit list that drops the padding is the recovery route.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --task-id td-b \
   --json '{"task_id":"td-b","status":"recovered","workers":[{"phase":"implement","note":"small"}]}'
grep -q '"status":"recovered"' "$TASKFILE"
# The omit branch still refuses a malformed prior with its own message, and
# the vacuous inherited-row refusal text is gone from the module.
python3 -c "
import json, sys
path = sys.argv[1]
rec = json.load(open(path)); rec['workers'] = [{'no_phase': True}]
json.dump(rec, open(path, 'w'))
" "$TASKFILE"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session L1 --fence "$f" --task-id td-b \
   --json '{"task_id":"td-b","status":"x"}' 2>"$ERRFILE"; then exit 1; fi
grep -q 'task record is unreadable or malformed; pass an explicit' "$ERRFILE"
if grep -q 'inherited task workers' claude/hooks/herdr_orch_core.py; then exit 1; fi
# Bound scope: reserve-dispatch appending a row that crosses the cap, and
# enrich-dispatch merging a scalar that crosses it, are both refused.
bid=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py issue-binding \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session L1 --fence "$f" --task-id td-x \
   --workspace-root "$LF_WS" --expected-session S1)
lf=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --host h --pid 2 \
   --control-tier lead --workspace-root "$LF_WS" --binding "$bid")
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug "$LF_SLUG" --session S1 --fence "$lf" --binding "$bid" --task-id td-x \
   --json '{"task_id":"td-x","workers":[]}'
BOUNDFILE="$root/herdr-orch/$LF_SLUG/leads/$bid/tasks/td-x.json"
python3 -c "
import json, sys
path = sys.argv[1]
rec = json.load(open(path)); rec['pad'] = 'x' * 1_999_900
json.dump(rec, open(path, 'w'), sort_keys=True, separators=(',', ':'))
" "$BOUNDFILE"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" \
   --task-id td-x --launch-id I1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id p1 --source-head-sha "$SHA40" 2>"$ERRFILE"; then exit 1; fi
grep -q 'exceed the 2000000-byte dispatch reader limit' "$ERRFILE"
python3 -c "
import json
d=json.load(open('$BOUNDFILE')); assert d['workers']==[], d
"
python3 -c "
import json, sys
path = sys.argv[1]
rec = json.load(open(path)); rec['pad'] = 'x' * 1_999_000
json.dump(rec, open(path, 'w'), sort_keys=True, separators=(',', ':'))
" "$BOUNDFILE"
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py reserve-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" \
   --task-id td-x --launch-id I1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id p1 --source-head-sha "$SHA40"
NOTE=$(python3 -c 'print("y"*2000)')
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py enrich-dispatch \
   --repo-slug "$LF_SLUG" --repo-path "$LF_REPO" --session S1 --fence "$lf" --binding "$bid" \
   --task-id td-x --launch-id I1 --phase implement --runtime claude --workspace-id w1 \
   --pane-id p1 --source-head-sha "$SHA40" --json '{"note":"'"$NOTE"'"}' 2>"$ERRFILE"; then exit 1; fi
grep -q 'exceed the 2000000-byte dispatch reader limit' "$ERRFILE"
python3 -c "
import json
d=json.load(open('$BOUNDFILE')); assert len(d['workers'])==1 and 'note' not in d['workers'][0], d
"
SH

check "unbound explicit workers list may not shrink dispatch history" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-ns --session S --host h --pid 1)
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"in-progress","workers":[{"phase":"implement","launch_id":"I1","peer_name":null}]}'
TASKFILE="$root/herdr-orch/slug-ns/tasks/td-s.json"
BEFORE=$(cat "$TASKFILE")
# The laundering shape: an explicit [] over a dispatched record. Refused, the
# row survives, and the null-attempt reader still sees an attempt.
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"in-progress","workers":[]}' 2>"$ERRFILE"; then exit 1; fi
grep -q 'unbound dispatch history may not shrink; open a fresh task id with reset-task' "$ERRFILE"
[ "$(cat "$TASKFILE")" = "$BEFORE" ]
python3 -c "
import importlib.util, json
s=importlib.util.spec_from_file_location('core','claude/hooks/herdr_orch_core.py')
c=importlib.util.module_from_spec(s); s.loader.exec_module(c)
assert c.has_attempt_rows(json.load(open('$TASKFILE')), 'implement')
"
# Same-count rewrite with changed non-identity fields: the director's normal
# full-record rewrite (peer_name discovered after launch) stays accepted.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"in-progress","workers":[{"phase":"implement","launch_id":"I1","peer_name":"impl-td-s"}]}'
grep -q '"peer_name":"impl-td-s"' "$TASKFILE"
# Longer list accepted; omitted key inherits; shrinking from two to one refused.
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"review-dispatched","workers":[{"phase":"implement","launch_id":"I1","peer_name":"impl-td-s"},{"phase":"review","launch_id":"R1"}]}'
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"reviewed"}'
python3 -c "
import json
d=json.load(open('$TASKFILE')); assert d['status']=='reviewed' and len(d['workers'])==2, d
"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"reviewed","workers":[{"phase":"implement","launch_id":"I1"}]}' 2>"$ERRFILE"; then exit 1; fi
grep -q 'may not shrink' "$ERRFILE"
# Repair routes stay open: a phase-less prior row is replaced by a
# same-length repaired list; a prior whose workers is not a list has no
# measurable history, so any explicit list is accepted.
python3 -c "
import json, sys
path = sys.argv[1]
rec = json.load(open(path)); rec['workers'] = [{'launch_id': 'I1'}, {'launch_id': 'R1'}]
json.dump(rec, open(path, 'w'))
" "$TASKFILE"
if CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"repaired","workers":[{"phase":"implement","launch_id":"I1"}]}' 2>"$ERRFILE"; then exit 1; fi
grep -q 'may not shrink' "$ERRFILE"
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"repaired","workers":[{"phase":"implement","launch_id":"I1"},{"phase":"review","launch_id":"R1"}]}'
grep -q '"status":"repaired"' "$TASKFILE"
python3 -c "
import json, sys
path = sys.argv[1]
rec = json.load(open(path)); rec['workers'] = 'nope'
json.dump(rec, open(path, 'w'))
" "$TASKFILE"
CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py write-task \
   --repo-slug slug-ns --session S --fence "$f" --task-id td-s \
   --json '{"task_id":"td-s","status":"rebuilt","workers":[]}'
grep -q '"status":"rebuilt"' "$TASKFILE"
# Unit: the count helper's None cases.
python3 -c "
import importlib.util
s=importlib.util.spec_from_file_location('core','claude/hooks/herdr_orch_core.py')
c=importlib.util.module_from_spec(s); s.loader.exec_module(c)
assert c._readable_row_count(c.PRIOR_ABSENT) is None
assert c._readable_row_count(c.PRIOR_CORRUPT) is None
assert c._readable_row_count(None) is None
assert c._readable_row_count({'workers': 'nope'}) is None
assert c._readable_row_count({'task_id': 'T'}) is None
assert c._readable_row_count({'workers': [{'x': 1}, {'phase': 'review'}]}) == 2
"
SH

check "reset-task opens a fresh task id and retains the old record" <<'SH'
root=$(mktemp -d)
f=$(CLAUDE_CONFIG_DIR="$root" python3 claude/hooks/herdr_legacy_fixture.py claim-owner \
   --repo-slug slug-rs --session S --host h --pid 1)
CLI="python3 claude/hooks/herdr_legacy_fixture.py"
TASKS="$root/herdr-orch/slug-rs/tasks"
CLAUDE_CONFIG_DIR="$root" $CLI write-task --repo-slug slug-rs --session S --fence "$f" --task-id td-a \
   --json '{"task_id":"td-a","base_sha":"b0","status":"in-progress","workers":[{"phase":"implement","launch_id":"I1"}]}'
CLAUDE_CONFIG_DIR="$root" $CLI emit-done --repo-slug slug-rs --task-id td-a --workspace w1 --agent impl-td-a \
   --phase implement --outcome failed --head-sha h1 --base-sha b0
OLD_REC=$(shasum -a 256 "$TASKS/td-a.json"); OLD_DONE=$(shasum -a 256 "$TASKS/td-a.done.json")
# Happy path: fresh id, empty history, provenance, old files byte-identical.
CLAUDE_CONFIG_DIR="$root" $CLI reset-task --repo-slug slug-rs --session S --fence "$f" \
   --task-id td-a --new-task-id td-a2 --json '{"task_id":"td-a2","base_sha":"b0","status":"kickoff"}'
python3 -c "
import json
d=json.load(open('$TASKS/td-a2.json'))
assert d['workers']==[] and d['reset_from']=='td-a' and d['status']=='kickoff' and d['base_sha']=='b0', d
"
[ "$(shasum -a 256 "$TASKS/td-a.json")" = "$OLD_REC" ]
[ "$(shasum -a 256 "$TASKS/td-a.done.json")" = "$OLD_DONE" ]
# The verb has no --binding: it is launcher-scope only.
if python3 claude/hooks/herdr_orch_core.py reset-task --help | grep -q -- '--binding'; then exit 1; fi
refuse() {  # refuse MESSAGE ARGS... : the verb must exit non-zero naming MESSAGE
  msg="$1"; shift
  if CLAUDE_CONFIG_DIR="$root" $CLI reset-task --repo-slug slug-rs --session S --fence "$f" "$@" 2>"$ERRFILE"; then
    echo "accepted: $*" >&2; exit 1
  fi
  grep -q "$msg" "$ERRFILE" || { echo "wrong refusal for $*:"; cat "$ERRFILE"; exit 1; } >&2
}
refuse 'invalid new-task-id' --task-id td-a --new-task-id '../x' --json '{"task_id":"../x"}'
refuse 'reset must open a fresh task id' --task-id td-a --new-task-id td-a --json '{"task_id":"td-a"}'
refuse 'reset json must be a JSON object whose task_id equals --new-task-id' --task-id td-a --new-task-id td-a3 --json '{"task_id":"td-a"}'
refuse 'reset json must be a JSON object whose task_id equals --new-task-id' --task-id td-a --new-task-id td-a3 --json '[]'
refuse 'a reset opens with no dispatch history; append rows with write-task' --task-id td-a --new-task-id td-a3 --json '{"task_id":"td-a3","workers":[{"phase":"implement"}]}'
refuse 'reset_from is set by the verb' --task-id td-a --new-task-id td-a3 --json '{"task_id":"td-a3","reset_from":"td-a"}'
refuse 'no task record to reset' --task-id td-zz --new-task-id td-a3 --json '{"task_id":"td-a3"}'
refuse 'reset target already exists' --task-id td-a --new-task-id td-a2 --json '{"task_id":"td-a2"}'
printf '{}' > "$TASKS/td-b.done.json"
refuse 'reset target has settlement records' --task-id td-a --new-task-id td-b --json '{"task_id":"td-b"}'
test ! -e "$TASKS/td-b.json"
test ! -e "$TASKS/td-a3.json"
# An explicit empty workers key is the one accepted spelling besides omission.
CLAUDE_CONFIG_DIR="$root" $CLI reset-task --repo-slug slug-rs --session S --fence "$f" \
   --task-id td-a2 --new-task-id td-a3 --json '{"task_id":"td-a3","workers":[]}'
python3 -c "
import json
d=json.load(open('$TASKS/td-a3.json')); assert d['reset_from']=='td-a2' and d['workers']==[], d
"
# A stale fence is still refused by the shared scoping, not by this verb.
if CLAUDE_CONFIG_DIR="$root" $CLI reset-task --repo-slug slug-rs --session S --fence 999 \
   --task-id td-a --new-task-id td-a4 --json '{"task_id":"td-a4"}' 2>/dev/null; then exit 1; fi
test ! -e "$TASKS/td-a4.json"
SH

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
