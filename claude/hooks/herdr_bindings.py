"""Dispatch-binding records for the task-lead orchestrator tier.

A binding is the launcher-issued source of truth for one lead dispatch:
identity, workspace, account, and lifecycle. Records are payload-root files
(`<rd>/bindings/<binding_id>.json`) written only under a launcher fence and
consumed by claim-owner. This module owns the schema; it never takes locks
and never imports herdr_orch_core (core imports this module).
"""

import re
import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_coordination as coordination
from herdr_coordination import _valid_workspace_root

BINDING_ID_RE = re.compile(r"ldb-[0-9a-f]{32}\Z")
BINDING_STATUSES = ("issued", "claimed", "completed", "revoked")
TRANSITIONS = {
    "issued": {"claimed", "revoked"},
    "claimed": {"completed", "revoked"},
    "completed": set(),
    "revoked": set(),
}
_SLUG_RE = re.compile(r"[a-z0-9][a-z0-9-]*\Z")
_SEGMENT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")


def new_binding_id():
    return "ldb-" + uuid.uuid4().hex


def can_transition(old, new):
    return new in TRANSITIONS.get(old, set())


def _nonempty(value):
    return isinstance(value, str) and bool(value)


def valid_binding(rec):
    if not isinstance(rec, dict):
        return False
    parent = rec.get("parent")
    return (
        type(rec.get("schema_version")) is int
        and rec["schema_version"] == 1
        and isinstance(rec.get("binding_id"), str)
        and bool(BINDING_ID_RE.fullmatch(rec["binding_id"]))
        and rec.get("tier") == "lead"
        and isinstance(parent, dict)
        and parent.get("tier") == "launcher"
        and _nonempty(parent.get("task_id"))
        and _nonempty(parent.get("session_id"))
        and isinstance(rec.get("task_id"), str)
        and bool(_SEGMENT_RE.fullmatch(rec["task_id"]))
        and (rec.get("repo_id") is None or _nonempty(rec.get("repo_id")))
        and isinstance(rec.get("repo_slug"), str)
        and bool(_SLUG_RE.fullmatch(rec["repo_slug"]))
        and _valid_workspace_root(rec.get("workspace_root"))
        and _nonempty(rec.get("account_id"))
        and rec.get("account_kind") in ("personal", "work", "custom")
        and rec.get("runtime") in ("claude", "codex")
        and _nonempty(rec.get("expected_session_id"))
        and type(rec.get("created_fence")) is int
        and rec["created_fence"] > 0
        and rec.get("status") in BINDING_STATUSES
        and _nonempty(rec.get("created_ts"))
        and _nonempty(rec.get("updated_ts"))
    )


def binding_path(rd, binding_id):
    if not isinstance(binding_id, str) or not BINDING_ID_RE.fullmatch(binding_id):
        raise ValueError("invalid binding id")
    return Path(rd) / "bindings" / f"{binding_id}.json"


def read_binding(rd, binding_id):
    """The stored record, None if absent; ValueError on corrupt or invalid.

    Reads through coordination._read: no-follow, nonblocking, regular-file
    only. Callers hold the global owner lock, so a symlinked or FIFO binding
    file must fail fast instead of following or blocking.
    """
    path = binding_path(rd, binding_id)
    try:
        rec = coordination._read(path)
    except ValueError as exc:
        raise ValueError("corrupt dispatch binding") from exc
    if rec is None:
        return None
    if not valid_binding(rec) or rec["binding_id"] != binding_id:
        raise ValueError("invalid dispatch binding")
    return rec
