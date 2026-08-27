#!/usr/bin/env python3
"""Deterministic core for herdr-orchestration: identity/naming, path-safety,
validators, state I/O, event fold, completion/dispatch decisions, and
single-writer ownership. Imported by the hook and driven as a CLI by the skill.
Stdlib only; fails safe. The CLI is the only fenced state-mutation surface.
"""

import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

WORKSPACE_ID_RE = re.compile(r"[A-Za-z0-9]+\Z")
AGENT_NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}\Z")
REPO_SLUG_RE = re.compile(r"[a-z0-9][a-z0-9-]*\Z")
TASK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*\Z")


def state_root() -> Path:
    base = os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude")
    return Path(base) / "herdr-orch"


def repo_slug(remote_url, common_dir=None) -> str:
    if remote_url:
        u = remote_url.strip()
        u = re.sub(r"\.git\Z", "", u)
        u = re.sub(r"\A[a-z]+://", "", u)
        u = re.sub(r"\A[^@]+@", "", u)
        norm = re.sub(r"[^a-z0-9]+", "-", u.lower()).strip("-")
        h = hashlib.sha256(remote_url.strip().encode()).hexdigest()[:8]
        return f"{norm}-{h}"
    h = hashlib.sha256(str(Path(common_dir).resolve()).encode()).hexdigest()[:8]
    return f"local-{h}"


def jira_task_id(key: str) -> str:
    return key.strip().upper()


def todo_task_id(stable_id: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", stable_id.strip().lower()).strip("-")
    return slug if slug.startswith("td-") else f"td-{slug}"


def agent_name(prefix: str, task_id: str, existing=()) -> str:
    t = re.sub(r"[^a-z0-9-]+", "-", task_id.lower()).strip("-")
    base = f"{prefix}-{t}"[:32]
    name = base
    n = 2
    while name in existing:
        suffix = f"-{n}"
        name = base[: 32 - len(suffix)] + suffix
        n += 1
    return name


def branch_name(user: str, task_id: str, slug: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", slug.lower()).strip("-")[:32]
    return f"{user}/{task_id}/{s}"


def worktree_dirname(branch: str) -> str:
    return branch.replace("/", "+")


def valid_workspace_id(ws) -> bool:
    return bool(ws) and bool(WORKSPACE_ID_RE.match(ws))


def valid_repo_slug(slug) -> bool:
    return bool(slug) and ".." not in slug and bool(REPO_SLUG_RE.match(slug))


def valid_task_id(tid) -> bool:
    return bool(tid) and ".." not in tid and bool(TASK_ID_RE.match(tid))


def contained(path, root) -> bool:
    try:
        rp = Path(path).resolve()
        rr = Path(root).resolve()
    except OSError:
        return False
    return rp == rr or rr in rp.parents


_HINTS = {"stopped", "blocked", "review-stopped"}
_AUTH = {
    "kickoff",
    "phase-advanced",
    "review-dispatched",
    "completed",
    "paused",
    "failed",
    "changes-requested",
    "reviewed",
    "abandoned",
    "merged",
}


def repo_dir(slug: str) -> Path:
    return state_root() / slug


def index_path(rd, ws) -> Path:
    return Path(rd) / "workspaces" / f"{ws}.json"


def events_path(rd, ws) -> Path:
    return Path(rd) / "workspaces" / f"{ws}.events.jsonl"


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_json_atomic(path, data) -> None:
    path = Path(path)
    tmp = Path(f"{path}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


def read_index(rd, ws):
    if not valid_workspace_id(ws):
        return None
    p = index_path(rd, ws)
    try:
        if p.is_symlink() or not contained(p, state_root()):
            return None
        with open(p) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def append_event(rd, ws, event, **fields) -> bool:
    if not valid_workspace_id(ws):
        return False
    p = events_path(rd, ws)
    rec = {"v": 1, "ts": now_iso(), "workspace_id": ws, "event": event}
    rec.update(fields)
    line = json.dumps(rec, separators=(",", ":")) + "\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(p, flags, 0o600)
    except OSError:
        return False
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)
    return True


def parse_events(lines):
    out = []
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            rec = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("v") != 1:
            continue
        out.append(rec)
    return out


def fold_status(events):
    """Latest authoritative event wins; last hint is surfaced separately."""
    authoritative = None
    last_hint = None
    for rec in events:
        ev = rec.get("event")
        if ev in _AUTH:
            authoritative = ev
        elif ev in _HINTS:
            last_hint = ev
    return {"authoritative": authoritative, "last_hint": last_hint}


def _owner_path(rd) -> Path:
    return Path(rd) / "owner.json"


def claim_owner(rd, session_id, host, pid, stale_secs=900):
    Path(rd).mkdir(parents=True, exist_ok=True)
    p = _owner_path(rd)
    rec = {
        "session_id": session_id,
        "host": host,
        "pid": pid,
        "heartbeat_ts": time.time(),
        "fence": 1,
    }
    excl = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    tmp = Path(f"{p}.new.{os.getpid()}")
    try:  # fast path: first-ever claim publishes atomically via link, so `p`
        # never appears on disk with partial/empty content for a racing reader.
        tmp.write_text(json.dumps(rec))
        try:
            os.link(tmp, p)
            return 1
        except FileExistsError:
            pass  # someone else won the first claim; fall through to takeover
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    lock = Path(f"{p}.lock")
    try:  # serialize the read-modify-write of an existing owner
        lfd = os.open(lock, excl, 0o600)
    except FileExistsError:
        try:  # a crashed holder (e.g. SIGKILL before the finally unlink) can
            # leave this lock forever; break it by mtime so ownership never
            # wedges permanently, retrying the exclusive-create exactly once.
            stale_lock = time.time() - os.stat(lock).st_mtime > stale_secs
        except OSError:
            stale_lock = False
        if not stale_lock:
            return None  # fresh lock: another takeover in progress; caller may retry
        # Known limitation (single-user-unreachable): two contenders can race
        # this unlink/re-create -- one may unlink a lock the other just remade.
        # The loser's exclusive-create then fails and it returns None to retry;
        # the fence still names exactly one winner, so it self-heals. Only
        # reachable with concurrent orchestrators on one repo.
        try:
            os.unlink(lock)
        except OSError:
            pass
        try:
            lfd = os.open(lock, excl, 0o600)
        except FileExistsError:
            return None  # lost the race to break it; caller may retry
    try:
        try:
            cur = json.loads(p.read_text())
        except (OSError, ValueError):
            cur = {}
        fresh = time.time() - float(cur.get("heartbeat_ts", 0)) <= stale_secs
        if fresh and cur.get("session_id") != session_id:
            return None
        fence = int(cur.get("fence", 0)) + 1
        rec["fence"] = fence
        write_json_atomic(p, rec)
        return fence
    finally:
        os.close(lfd)
        try:
            os.unlink(lock)
        except OSError:
            pass


def check_fence(rd, session_id, fence) -> bool:
    try:
        cur = json.loads(_owner_path(rd).read_text())
    except (OSError, ValueError):
        return False
    return cur.get("session_id") == session_id and int(cur.get("fence", -1)) == int(
        fence
    )


def refresh_owner(rd, session_id, fence) -> bool:
    if not check_fence(rd, session_id, fence):
        return False
    cur = json.loads(_owner_path(rd).read_text())
    cur["heartbeat_ts"] = time.time()
    write_json_atomic(_owner_path(rd), cur)
    return True


def is_completed(task, done, live_head_sha) -> bool:
    if not isinstance(done, dict) or done.get("outcome") != "completed":
        return False
    if done.get("task_id") != task.get("task_id"):
        return False
    if done.get("head_sha") != live_head_sha or done.get("base_sha") != task.get(
        "base_sha"
    ):
        return False
    return done.get("head_sha") != done.get(
        "base_sha"
    )  # at least one commit ahead of base


def should_dispatch_review(task, head_sha) -> bool:
    if task.get("status") != "completed":
        return False
    return task.get("review_head_sha") != head_sha


def is_reviewed(task, done, head_sha) -> bool:
    """Merge-ready only when the dispatched review SHA, the reviewed SHA, and
    live HEAD all agree. Requiring the task record's dispatched `review_head_sha`
    too (not just `done.reviewed_head_sha` == HEAD) stops a branch advance after
    dispatch from slipping an unreviewed revision through: if the reviewer records
    the new live SHA while `/code-review` actually ran against the old one, the
    dispatched SHA no longer matches and the gate holds."""
    if not isinstance(task, dict) or not isinstance(done, dict):
        return False
    if done.get("task_id") != task.get("task_id"):
        return False
    if done.get("phase") != "review" or done.get("outcome") != "approved":
        return False
    return task.get("review_head_sha") == head_sha and (
        done.get("reviewed_head_sha") == head_sha
    )


def _require(cond, msg) -> None:
    if not cond:
        sys.stderr.write(f"[X] {msg}\n")
        raise SystemExit(2)


def _fenced(ns):
    # Known limitation (single-user-unreachable): this fence check and the
    # caller's subsequent write are not one atomic step -- a just-superseded
    # owner could pass here and then write in the gap after a concurrent
    # takeover. Fence-mitigated (the next refresh/claim by the live owner wins)
    # and needs two contending orchestrators on one repo; revisit only if this
    # ever becomes multi-user.
    _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
    rd = repo_dir(ns.repo_slug)
    _require(check_fence(rd, ns.session, int(ns.fence)), "stale or missing fence")
    return rd


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, *args, fenced=False):
        p = sub.add_parser(name)
        p.add_argument("--repo-slug", required=True)
        if fenced:
            p.add_argument("--session", required=True)
            p.add_argument("--fence", required=True)
        for a in args:
            p.add_argument(a, required=True)
        return p

    co = add("claim-owner", "--session", "--host", "--pid")
    co.add_argument("--stale-secs", type=int, default=None)  # test/override hook
    add("refresh-owner", "--session", "--fence")
    add("check-fence", "--session", "--fence")
    add("write-task", "--task-id", "--json", fenced=True)
    add("write-index", "--workspace", "--json", fenced=True)
    add(
        "emit-done",
        "--task-id",
        "--workspace",
        "--agent",
        "--phase",
        "--outcome",
        "--head-sha",
        "--base-sha",
    )
    er = add(
        "emit-review",
        "--task-id",
        "--workspace",
        "--agent",
        "--reviewed-head-sha",
        "--outcome",
    )
    er.add_argument("--findings-ref", default=None)
    add("status")
    add("should-dispatch-review", "--task-id", "--head-sha")
    add("confirm-completion", "--task-id", "--head-sha")
    add("confirm-review", "--task-id", "--head-sha")
    ns = ap.parse_args(argv)

    if ns.cmd == "claim-owner":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        kw = {} if ns.stale_secs is None else {"stale_secs": ns.stale_secs}
        fence = claim_owner(repo_dir(ns.repo_slug), ns.session, ns.host, ns.pid, **kw)
        if fence is None:
            print("BUSY")
            return 1
        print(fence)
        return 0
    if ns.cmd == "check-fence":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        return (
            0 if check_fence(repo_dir(ns.repo_slug), ns.session, int(ns.fence)) else 1
        )
    if ns.cmd == "refresh-owner":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        return (
            0 if refresh_owner(repo_dir(ns.repo_slug), ns.session, int(ns.fence)) else 1
        )
    if ns.cmd == "write-task":
        rd = _fenced(ns)
        _require(valid_task_id(ns.task_id), "invalid task-id")
        try:
            rec = json.loads(ns.json)
        except ValueError:
            rec = None
        # Persisting a non-dict (e.g. a bare `[]`) would later crash `status`
        # on `.get`; a task_id mismatch would mislabel the record under its file.
        _require(
            isinstance(rec, dict) and rec.get("task_id") == ns.task_id,
            "task json must be a JSON object whose task_id equals --task-id",
        )
        (rd / "tasks").mkdir(parents=True, exist_ok=True)
        write_json_atomic(rd / "tasks" / f"{ns.task_id}.json", rec)
        return 0
    if ns.cmd == "write-index":
        rd = _fenced(ns)
        _require(valid_workspace_id(ns.workspace), "invalid workspace")
        (rd / "workspaces").mkdir(parents=True, exist_ok=True)
        write_json_atomic(index_path(rd, ns.workspace), json.loads(ns.json))
        return 0
    if ns.cmd in ("emit-done", "emit-review"):
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        _require(valid_workspace_id(ns.workspace), "invalid workspace")
        rd = repo_dir(ns.repo_slug)
        (rd / "tasks").mkdir(parents=True, exist_ok=True)
        if ns.cmd == "emit-done":
            done = {
                "v": 1,
                "task_id": ns.task_id,
                "workspace_id": ns.workspace,
                "agent": ns.agent,
                "phase": ns.phase,
                "outcome": ns.outcome,
                "head_sha": ns.head_sha,
                "base_sha": ns.base_sha,
                "ts": now_iso(),
            }
        else:
            done = {
                "v": 1,
                "task_id": ns.task_id,
                "workspace_id": ns.workspace,
                "agent": ns.agent,
                "phase": "review",
                "outcome": ns.outcome,
                "reviewed_head_sha": ns.reviewed_head_sha,
                "ts": now_iso(),
            }
            if ns.findings_ref:
                done["findings_ref"] = ns.findings_ref
        out = rd / "tasks" / f"{ns.task_id}.done.json"
        _require(contained(out, state_root()), "escapes state root")
        write_json_atomic(out, done)
        return 0
    if ns.cmd == "status":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        rd = repo_dir(ns.repo_slug)
        # Associate each workspace's events with its task via the workspace index,
        # then order per-task events chronologically (ts, event tie-breaker).
        by_task = {}
        for ef in (rd / "workspaces").glob("*.events.jsonl"):
            ws = ef.name[: -len(".events.jsonl")]
            idx = read_index(rd, ws) or {}
            tid = idx.get("task_id")
            if not tid:
                continue
            by_task.setdefault(tid, []).extend(
                parse_events(ef.read_text().splitlines())
            )
        for tid in by_task:
            by_task[tid].sort(key=lambda r: (r.get("ts", ""), r.get("event", "")))
        result = {}
        for tf in sorted((rd / "tasks").glob("*.json")):
            if tf.name.endswith(".done.json"):
                continue
            try:
                task = json.loads(tf.read_text())
            except ValueError:
                continue
            tid = task.get("task_id")
            result[tid] = {
                "status": task.get("status"),
                "fold": fold_status(by_task.get(tid, [])),
            }
        print(json.dumps(result))
        return 0
    if ns.cmd == "should-dispatch-review":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        rd = repo_dir(ns.repo_slug)
        tf = rd / "tasks" / f"{ns.task_id}.json"
        _require(contained(tf, state_root()), "escapes state root")
        try:
            task = json.loads(tf.read_text())
        except (OSError, ValueError):
            return 1
        return 0 if should_dispatch_review(task, ns.head_sha) else 1
    if ns.cmd == "confirm-completion":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        rd = repo_dir(ns.repo_slug)
        tf = rd / "tasks" / f"{ns.task_id}.json"
        df = rd / "tasks" / f"{ns.task_id}.done.json"
        _require(contained(tf, state_root()), "escapes state root")
        _require(contained(df, state_root()), "escapes state root")
        try:
            task = json.loads(tf.read_text())
        except (OSError, ValueError):
            return 1
        try:
            done = json.loads(df.read_text())
        except (OSError, ValueError):
            done = None
        return 0 if is_completed(task, done, ns.head_sha) else 1
    if ns.cmd == "confirm-review":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        rd = repo_dir(ns.repo_slug)
        tf = rd / "tasks" / f"{ns.task_id}.json"
        df = rd / "tasks" / f"{ns.task_id}.done.json"
        _require(contained(tf, state_root()), "escapes state root")
        _require(contained(df, state_root()), "escapes state root")
        try:
            task = json.loads(tf.read_text())
        except (OSError, ValueError):
            return 1
        try:
            done = json.loads(df.read_text())
        except (OSError, ValueError):
            done = None
        return 0 if is_reviewed(task, done, ns.head_sha) else 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
