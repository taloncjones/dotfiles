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
import sys  # noqa: F401 -- used by the CLI added in a later task
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
