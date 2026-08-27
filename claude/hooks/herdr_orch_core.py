#!/usr/bin/env python3
"""Deterministic core for herdr-orchestration: identity/naming, path-safety,
validators, state I/O, event fold, completion/dispatch decisions, and
single-writer ownership. Imported by the hook and driven as a CLI by the skill.
Stdlib only; fails safe. The CLI is the only fenced state-mutation surface.
"""

import hashlib
import os
import re
import time  # noqa: F401 -- used by state I/O added in a later task
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
