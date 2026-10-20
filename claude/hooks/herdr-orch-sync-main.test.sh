#!/bin/sh
# herdr-orch-sync-main.test.sh - the sync-main verb and its section 6a prose.
# TMPDIR fixtures with path remotes and a sandbox HOME: no network, no ~/.claude.
set -e
unset WORKFLOW_PERSONAL_ACCOUNT HERDR_PERSONAL CLAUDE_PERSONAL_ONLY
unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR CLAUDE_CONFIG_DIR CODEX_HOME XDG_STATE_HOME
unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID HERDR_ACCOUNT_ID BASH_ENV
TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null) || TMPDIR=""
[ -n "$TMPDIR" ] || TMPDIR=$(mktemp -d -u 2>/dev/null | sed 's:/[^/]*$::')
[ -n "$TMPDIR" ] || TMPDIR=/tmp
TMPDIR=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMPDIR")
export TMPDIR
PASS=0
FAIL=0

HELPERS=$(mktemp -d)
export HELPERS
cat > "$HELPERS/fixture.py" <<'PY'
import json, os, subprocess, sys, tempfile
from pathlib import Path
for k in [k for k in os.environ if k.startswith("GIT_")]:
    os.environ.pop(k)
sb = Path(tempfile.mkdtemp()).resolve()
os.environ["HOME"] = str(sb)
os.environ["GIT_CONFIG_NOSYSTEM"] = "1"
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path[:0] = ["claude/hooks", "claude/skills/lib"]
sys.dont_write_bytecode = True
import herdr_orch_core as c, workflow_context as w
CORE = "claude/hooks/herdr_orch_core.py"

def git(cwd, *a):
    return subprocess.run(["git", "-C", str(cwd), *a], check=True,
                          capture_output=True, text=True).stdout.strip()

def commit(cwd, name, text):
    f = Path(cwd) / name
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(text)
    git(cwd, "add", name)
    git(cwd, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", name)

def fixture(tag, seed=(("a.txt", "a\n"),)):
    origin = sb / f"{tag}-origin.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True)
    up = sb / f"{tag}-up"
    subprocess.run(["git", "init", "-q", "-b", "main", str(up)], check=True)
    for name, text in seed:
        commit(up, name, text)
    git(up, "remote", "add", "origin", str(origin))
    git(up, "push", "-q", "origin", "main")
    main = sb / f"{tag}-main"
    subprocess.run(["git", "clone", "-q", str(origin), str(main)], check=True)
    return up, main, origin

def advance(up, name, text):
    commit(up, name, text)
    git(up, "push", "-q", "origin", "main")
    return git(up, "rev-parse", "HEAD")

def run(path, branch="main", slug=None, personal=False):
    slug = slug or c._context_slug(w.repository_context(str(path)))
    cmd = [sys.executable, CORE, "sync-main", "--repo-slug", slug,
           "--repo-path", str(path), "--branch", branch]
    if personal:
        cmd.append("--personal")
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    lines = p.stdout.strip().splitlines()
    try:
        out = json.loads(lines[-1]) if lines else None
    except ValueError:
        out = None
    return p.returncode, out, p.stdout + p.stderr
PY

check() {
    label="$1"
    if sh -e -; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2; FAIL=$((FAIL + 1))
    fi
}

check "sync-main: fast-forward from a linked worktree path syncs the primary checkout" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("ff")
wt = sb / "ff-wt"
git(main, "worktree", "add", "-q", "-b", "topic", str(wt))
old, wt_head = git(main, "rev-parse", "HEAD"), git(wt, "rev-parse", "HEAD")
tip = advance(up, "b.txt", "b\n")
rc, out, log = run(wt)
assert rc == 0 and out["reason"] == "synced" and out["synced"] is True, log
assert out["old_head"] == old and out["new_head"] == tip, log
assert Path(out["checkout"]).resolve() == main, log
assert git(main, "rev-parse", "HEAD") == tip
assert git(wt, "rev-parse", "HEAD") == wt_head
PY
SH2

check "sync-main: an untracked file does not block the fast-forward and is kept" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("untracked")
tip = advance(up, "b.txt", "b\n")
(main / "notes.txt").write_text("keep\n")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "synced", log
assert git(main, "rev-parse", "HEAD") == tip
assert (main / "notes.txt").read_text() == "keep\n"
PY
SH2

check "sync-main: an up-to-date checkout reports up-to-date" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("utd")
head = git(main, "rev-parse", "HEAD")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "up-to-date" and out["synced"] is True, log
assert out["old_head"] == head and out["new_head"] == head, log
PY
SH2

check "sync-main: a dirty tracked tree skips and keeps the edit" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("dirty")
head = git(main, "rev-parse", "HEAD")
advance(up, "b.txt", "b\n")
(main / "a.txt").write_text("edited\n")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "dirty" and out["synced"] is False, log
assert git(main, "rev-parse", "HEAD") == head
assert (main / "a.txt").read_text() == "edited\n"
PY
SH2

check "sync-main: a diverged main skips" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("diverged")
commit(main, "local.txt", "local\n")
local = git(main, "rev-parse", "HEAD")
advance(up, "remote.txt", "remote\n")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "diverged" and out["synced"] is False, log
assert git(main, "rev-parse", "HEAD") == local
PY
SH2

check "sync-main: a checkout not on the default branch skips" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("offbranch")
git(main, "checkout", "-q", "-b", "side")
side = git(main, "rev-parse", "HEAD")
advance(up, "remote.txt", "remote\n")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "not-on-branch" and out["synced"] is False, log
assert git(main, "rev-parse", "HEAD") == side
PY
SH2

check "sync-main: a detached HEAD skips" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("detached")
git(main, "checkout", "-q", "--detach")
head = git(main, "rev-parse", "HEAD")
advance(up, "remote.txt", "remote\n")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "detached" and out["synced"] is False, log
assert git(main, "rev-parse", "HEAD") == head
PY
SH2

check "sync-main: an unreachable origin reports fetch-failed" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, origin = fixture("offline")
head = git(main, "rev-parse", "HEAD")
git(main, "remote", "set-url", "origin", str(sb / "missing-origin.git"))
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "fetch-failed" and out["synced"] is False, log
assert git(main, "rev-parse", "HEAD") == head
PY
SH2

check "sync-main: a primary checkout that cannot be proven reports no-primary" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
main = sb / "sep-main"
gitdir = sb / "sep-gitdir"
subprocess.run(["git", "init", "-q", "-b", "main", "--separate-git-dir", str(gitdir), str(main)], check=True)
commit(main, "a.txt", "a\n")
wt = sb / "sep-wt"
git(main, "worktree", "add", "-q", "-b", "topic", str(wt))
head = git(main, "rev-parse", "HEAD")
rc, out, log = run(wt, slug=c._context_slug(w.repository_context(str(wt))), personal=True)
assert rc == 0 and out["reason"] == "no-primary" and out["synced"] is False, log
assert git(main, "rev-parse", "HEAD") == head
PY
SH2

check "sync-main: a slug mismatch exits 2 and leaves the checkout alone" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("slug")
head = git(main, "rev-parse", "HEAD")
advance(up, "b.txt", "b\n")
rc, out, log = run(main, slug="not-the-slug")
assert rc == 2, log
assert git(main, "rev-parse", "HEAD") == head
PY
SH2

check "sync-main: update_ai lists install-managed paths in a dotfiles checkout" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
sentinel = sb / "installer-ran"
trap = f"#!/bin/sh\ntouch {sentinel}\n"
up, main, _ = fixture("ai", seed=(("install/common/ai-update.sh", trap),
                                   ("install/install.sh", trap), ("README.md", "r\n")))
commit(up, "install/common/x.sh", "x\n")
commit(up, "docs/y.md", "y\n")
git(up, "push", "-q", "origin", "main")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "synced", log
assert out["update_ai"] is True and out["update_ai_paths"] == ["install/common/x.sh"], log
assert not sentinel.exists(), "sync-main ran an installer"
PY
SH2

check "sync-main: update_ai is false for a docs-only range" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("docs", seed=(("install/common/ai-update.sh", "#!/bin/sh\n"),))
advance(up, "docs/z.md", "z\n")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "synced", log
assert out["update_ai"] is False and out["update_ai_paths"] == [], log
PY
SH2

check "sync-main: update_ai is false outside a dotfiles checkout" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("plain")
advance(up, "install/common/x.sh", "x\n")
rc, out, log = run(main)
assert rc == 0 and out["reason"] == "synced", log
assert out["update_ai"] is False and out["update_ai_paths"] == [], log
PY
SH2

check "docs: section 6a step 7 syncs the main checkout before teardown and only reports update --ai" <<'SH2'
python3 - <<'PY'
import re, sys
s = open("claude/skills/herdr-orchestration/SKILL.md", encoding="utf-8").read()
sec = s[s.index("\n## 6a. "):s.index("\n## 7. ")]
m = re.search(r"^7\. ", sec, re.M)
assert m, "no step 7 in section 6a"
step = " ".join(sec[m.start():].split())
for needle in ("sync-main --repo-slug", "--branch", "defaultBranchRef", "update --ai", "up-to-date"):
    assert needle in step, needle
assert re.search(r"never run", step, re.I)
assert step.index("sync-main --repo-slug") < step.index("/post-merge")
PY
SH2

check "sync-main: an index lock in the primary checkout reports locked and runs nothing" <<'SH2'
python3 - <<'PY'
exec(open(__import__("os").environ["HELPERS"] + "/fixture.py").read())
up, main, _ = fixture("lock")
head = git(main, "rev-parse", "HEAD")
advance(up, "b.txt", "b\n")
lock = Path(git(main, "rev-parse", "--path-format=absolute", "--git-path", "index.lock"))
lock.write_text("")
rc, out, log = run(main)
assert rc == 1 and out["reason"] == "locked" and out["synced"] is False, log
assert git(main, "rev-parse", "HEAD") == head
assert lock.exists()
PY
SH2

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
