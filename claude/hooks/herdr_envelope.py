"""Versioned lead return envelope for the task-lead orchestrator tier.

The envelope is a lead's terminal handback: one record per binding at
`<rd>/leads/<binding_id>/envelope.json`, written only through the
emit-envelope transaction and consumed by the launcher's serialized
integrate-envelope. This module owns the schema and its size/privacy caps;
it never takes locks and never imports herdr_orch_core (core imports this
module). An oversized or out-of-scope record is invalid -- the caller must
REJECT it, never strip it down.
"""

import hashlib
import json
import os
import re
import stat
from pathlib import Path

SHA40_RE = re.compile(r"[0-9a-f]{40}\Z")
_BINDING_ID_RE = re.compile(r"ldb-[0-9a-f]{32}\Z")
_SEGMENT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
_SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")

OUTCOMES = ("pr_ready", "blocked", "failed", "cancelled")
FOLLOW_UP_KINDS = ("todo", "handoff", "task")
ENVELOPE_MAX_BYTES = 4096
ENVELOPE_MAX_RAW = ENVELOPE_MAX_BYTES * 4
ENVELOPE_MAX_STR = 500
ENVELOPE_MAX_FOLLOW_UPS = 8
_REF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/#@+-]{0,199}\Z")
_BRANCH_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._/+-]{0,199}\Z")

CONSUMED_KEYS = frozenset((
    "schema_version", "binding_id", "sequence", "envelope_sha256",
    "outcome", "integrated_by", "fence", "ts",
))
CONSUMED_MAX_RAW = 4096

_ATTEMPT_KEYS = {
    "launch_id",
    "phase",
    "runtime",
    "workspace_id",
    "pane_id",
    "source_head_sha",
}
_TOP_KEYS = {
    "schema_version",
    "binding_id",
    "task_id",
    "attempt",
    "fence",
    "sequence",
    "ts",
    "summary",
}
_SUMMARY_KEYS = {"outcome", "pr", "expected_base_sha", "reason", "follow_ups"}
_PR_KEYS = {"repo_id", "number", "branch", "head_sha", "approval"}
_APPROVAL_KEYS = {"reviewer_session_id", "reviewer_runtime", "reviewed_head_sha"}


def _nonempty(value):
    return isinstance(value, str) and bool(value)


def _capped(value):
    return isinstance(value, str) and 0 < len(value) <= ENVELOPE_MAX_STR


def _valid_reason(reason):
    # A capped reason string carrying no control characters (C0 or DEL).
    return _capped(reason) and not any(ord(c) < 32 or ord(c) == 127 for c in reason)


def _valid_attempt(att):
    if not isinstance(att, dict) or set(att) != _ATTEMPT_KEYS:
        return False
    if att["phase"] != "implement" or att["runtime"] not in ("claude", "codex"):
        return False
    if not (
        isinstance(att["source_head_sha"], str)
        and SHA40_RE.fullmatch(att["source_head_sha"])
    ):
        return False
    return all(_nonempty(att[k]) for k in ("launch_id", "workspace_id", "pane_id"))


def _valid_follow_ups(fus):
    if not isinstance(fus, list) or len(fus) > ENVELOPE_MAX_FOLLOW_UPS:
        return False
    # A reference is an identifier, never prose: no whitespace, max 200.
    return all(
        isinstance(f, dict)
        and set(f) == {"kind", "ref"}
        and f["kind"] in FOLLOW_UP_KINDS
        and isinstance(f["ref"], str)
        and _REF_RE.fullmatch(f["ref"])
        for f in fus
    )


def _valid_approval(ap):
    return (
        isinstance(ap, dict)
        and set(ap) == _APPROVAL_KEYS
        and _capped(ap["reviewer_session_id"])
        and ap["reviewer_runtime"] in ("claude", "codex")
        and isinstance(ap["reviewed_head_sha"], str)
        and bool(SHA40_RE.fullmatch(ap["reviewed_head_sha"]))
    )


def _valid_pr(pr):
    if not isinstance(pr, dict) or set(pr) != _PR_KEYS:
        return False
    if pr["repo_id"] is not None and not _capped(pr["repo_id"]):
        return False
    if type(pr["number"]) is not int or pr["number"] <= 0:
        return False
    # A ref-safe branch (git ref syntax subset): no whitespace, within the
    # length cap, none of the sequences git itself forbids in a ref, and no
    # slash-separated component ending in ".lock" (git forbids a .lock suffix
    # on any ref path component, not just the whole ref).
    branch = pr["branch"]
    if not (isinstance(branch, str) and _BRANCH_RE.fullmatch(branch)):
        return False
    if (
        ".." in branch
        or "//" in branch
        or "/." in branch
        or branch.endswith(("/", "."))
        or any(part.endswith(".lock") for part in branch.split("/"))
    ):
        return False
    if not (isinstance(pr["head_sha"], str) and SHA40_RE.fullmatch(pr["head_sha"])):
        return False
    if not _valid_approval(pr["approval"]):
        return False
    # Non-stale by construction: an approval names exactly this head.
    return pr["approval"]["reviewed_head_sha"] == pr["head_sha"]


def _valid_summary(summary):
    if not isinstance(summary, dict) or set(summary) != _SUMMARY_KEYS:
        return False
    outcome = summary["outcome"]
    if outcome not in OUTCOMES:
        return False
    if not _valid_follow_ups(summary["follow_ups"]):
        return False
    pr = summary["pr"]
    ebs = summary["expected_base_sha"]
    reason = summary["reason"]
    if outcome == "pr_ready":
        return (
            _valid_pr(pr)
            and reason is None
            and isinstance(ebs, str)
            and bool(SHA40_RE.fullmatch(ebs))
        )
    if pr is not None or ebs is not None:
        return False
    if outcome == "cancelled":
        return reason is None or _valid_reason(reason)
    return _valid_reason(reason)  # blocked | failed


def valid_envelope(rec):
    """True when rec is a well-formed return envelope.

    A null attempt marks a terminal outcome reached before any dispatched
    implement attempt: it is allowed for blocked/failed/cancelled but never
    for pr_ready, which keeps a mandatory full attempt. A non-null attempt is
    validated by _valid_attempt unchanged.
    """
    if not isinstance(rec, dict) or set(rec) != _TOP_KEYS:
        return False
    if type(rec["schema_version"]) is not int or rec["schema_version"] != 1:
        return False
    if not (
        isinstance(rec["binding_id"], str)
        and _BINDING_ID_RE.fullmatch(rec["binding_id"])
    ):
        return False
    if not (isinstance(rec["task_id"], str) and _SEGMENT_RE.fullmatch(rec["task_id"])):
        return False
    if rec["attempt"] is None:
        summary = rec["summary"]
        if isinstance(summary, dict) and summary.get("outcome") == "pr_ready":
            return False
    elif not _valid_attempt(rec["attempt"]):
        return False
    if type(rec["fence"]) is not int or rec["fence"] <= 0:
        return False
    if type(rec["sequence"]) is not int or rec["sequence"] < 1:
        return False
    if not _nonempty(rec["ts"]):
        return False
    if not _valid_summary(rec["summary"]):
        return False
    try:
        body = json.dumps(rec, separators=(",", ":")).encode()
    except (TypeError, ValueError):
        return False
    return len(body) <= ENVELOPE_MAX_BYTES


def envelope_path(rd, binding_id):
    if not isinstance(binding_id, str) or not _BINDING_ID_RE.fullmatch(binding_id):
        raise ValueError("invalid binding id")
    return Path(rd) / "leads" / binding_id / "envelope.json"


def _no_dup_pairs(pairs):
    """object_pairs_hook that rejects duplicate keys in a JSON object."""
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError("duplicate key")
        d[k] = v
    return d


def read_envelope(rd, binding_id):
    """The stored envelope, None if absent; ValueError on corrupt or invalid.

    Self-contained bounded read: no-follow, nonblocking, regular-file only,
    size-capped, and duplicate-key-rejecting. Callers hold the global owner
    lock. This module never imports core, so the tiny no-dup hook is
    duplicated here rather than shared.
    """
    path = envelope_path(rd, binding_id)
    try:
        fd = os.open(
            str(path), os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
        )
    except FileNotFoundError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > ENVELOPE_MAX_RAW:
            raise ValueError("corrupt return envelope")
        raw = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw += chunk
            if len(raw) > ENVELOPE_MAX_RAW:
                raise ValueError("corrupt return envelope")
    finally:
        os.close(fd)
    try:
        rec = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_dup_pairs)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError("corrupt return envelope") from exc
    if not valid_envelope(rec) or rec["binding_id"] != binding_id:
        raise ValueError("invalid return envelope")
    return rec


def envelope_digest(rec):
    """Canonical digest of an envelope's semantic content (key-order free)."""
    return hashlib.sha256(
        json.dumps(rec, separators=(",", ":"), sort_keys=True).encode()
    ).hexdigest()


def consumed_path(rd, binding_id):
    if not isinstance(binding_id, str) or not _BINDING_ID_RE.fullmatch(binding_id):
        raise ValueError("invalid binding id")
    return Path(rd) / "leads" / binding_id / "envelope.consumed.json"


def valid_consumed(rec):
    return (
        isinstance(rec, dict)
        and set(rec) == CONSUMED_KEYS
        and type(rec["schema_version"]) is int and rec["schema_version"] == 1
        and isinstance(rec["binding_id"], str)
        and bool(_BINDING_ID_RE.fullmatch(rec["binding_id"]))
        and type(rec["sequence"]) is int and rec["sequence"] >= 1
        and isinstance(rec["envelope_sha256"], str)
        and bool(_SHA256_RE.fullmatch(rec["envelope_sha256"]))
        and rec["outcome"] in OUTCOMES
        and _nonempty(rec["integrated_by"])
        and type(rec["fence"]) is int and rec["fence"] > 0
        and _nonempty(rec["ts"])
    )


def _read_bounded(path, cap, label):
    """Bounded no-follow read shared by the consumption/artifact readers;
    same discipline as read_envelope. None if absent; ValueError on corrupt."""
    try:
        fd = os.open(
            str(path), os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0)
        )
    except FileNotFoundError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size > cap:
            raise ValueError(f"corrupt {label}")
        raw = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw += chunk
            if len(raw) > cap:
                raise ValueError(f"corrupt {label}")
    finally:
        os.close(fd)
    try:
        rec = json.loads(raw.decode("utf-8"), object_pairs_hook=_no_dup_pairs)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError(f"corrupt {label}") from exc
    if not isinstance(rec, dict):
        # A file holding JSON null (or any non-object) must be corrupt, not
        # "absent": absence is signaled only by FileNotFoundError above.
        raise ValueError(f"corrupt {label}")
    return rec


def read_consumed(rd, binding_id):
    """The stored consumption record, None if absent; ValueError on corrupt."""
    rec = _read_bounded(consumed_path(rd, binding_id), CONSUMED_MAX_RAW,
                        "consumption record")
    if rec is None:
        return None
    if not valid_consumed(rec) or rec["binding_id"] != binding_id:
        raise ValueError("invalid consumption record")
    return rec
