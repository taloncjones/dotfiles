"""Versioned lead return envelope for the task-lead orchestrator tier.

The envelope is a lead's terminal handback: one record per binding at
`<rd>/leads/<binding_id>/envelope.json`, written only through the
emit-envelope transaction and consumed by the launcher's serialized
integrate-envelope. This module owns the schema and its size/privacy caps;
it never takes locks and never imports herdr_orch_core (core imports this
module). An oversized or out-of-scope record is invalid -- the caller must
REJECT it, never strip it down.
"""

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_coordination as coordination

SHA40_RE = re.compile(r"[0-9a-f]{40}\Z")
_BINDING_ID_RE = re.compile(r"ldb-[0-9a-f]{32}\Z")
_SEGMENT_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")

OUTCOMES = ("pr_ready", "blocked", "failed", "cancelled")
FOLLOW_UP_KINDS = ("todo", "handoff", "task")
ENVELOPE_MAX_BYTES = 4096
ENVELOPE_MAX_STR = 500
ENVELOPE_MAX_FOLLOW_UPS = 8
_REF_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/#@+-]{0,199}\Z")

_ATTEMPT_KEYS = {"launch_id", "phase", "runtime", "workspace_id", "pane_id",
                 "source_head_sha"}
_TOP_KEYS = {"schema_version", "binding_id", "task_id", "attempt", "fence",
             "sequence", "ts", "summary"}
_SUMMARY_KEYS = {"outcome", "pr", "expected_base_sha", "reason", "follow_ups"}
_PR_KEYS = {"repo_id", "number", "branch", "head_sha", "approval"}
_APPROVAL_KEYS = {"reviewer_session_id", "reviewer_runtime",
                  "reviewed_head_sha"}


def _nonempty(value):
    return isinstance(value, str) and bool(value)


def _capped(value):
    return isinstance(value, str) and 0 < len(value) <= ENVELOPE_MAX_STR


def _valid_attempt(att):
    if not isinstance(att, dict) or set(att) != _ATTEMPT_KEYS:
        return False
    if att["phase"] != "implement" or att["runtime"] not in ("claude", "codex"):
        return False
    if not (isinstance(att["source_head_sha"], str)
            and SHA40_RE.fullmatch(att["source_head_sha"])):
        return False
    return all(_nonempty(att[k])
               for k in ("launch_id", "workspace_id", "pane_id"))


def _valid_follow_ups(fus):
    if not isinstance(fus, list) or len(fus) > ENVELOPE_MAX_FOLLOW_UPS:
        return False
    # A reference is an identifier, never prose: no whitespace, max 200.
    return all(isinstance(f, dict) and set(f) == {"kind", "ref"}
               and f["kind"] in FOLLOW_UP_KINDS
               and isinstance(f["ref"], str) and _REF_RE.fullmatch(f["ref"])
               for f in fus)


def _valid_approval(ap):
    return (isinstance(ap, dict) and set(ap) == _APPROVAL_KEYS
            and _capped(ap["reviewer_session_id"])
            and ap["reviewer_runtime"] in ("claude", "codex")
            and isinstance(ap["reviewed_head_sha"], str)
            and bool(SHA40_RE.fullmatch(ap["reviewed_head_sha"])))


def _valid_pr(pr):
    if not isinstance(pr, dict) or set(pr) != _PR_KEYS:
        return False
    if pr["repo_id"] is not None and not _capped(pr["repo_id"]):
        return False
    if type(pr["number"]) is not int or pr["number"] <= 0:
        return False
    if not _capped(pr["branch"]):
        return False
    if not (isinstance(pr["head_sha"], str)
            and SHA40_RE.fullmatch(pr["head_sha"])):
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
        return (_valid_pr(pr) and reason is None
                and isinstance(ebs, str) and bool(SHA40_RE.fullmatch(ebs)))
    if pr is not None or ebs is not None:
        return False
    if outcome == "cancelled":
        return reason is None or _capped(reason)
    return _capped(reason)  # blocked | failed


def valid_envelope(rec):
    if not isinstance(rec, dict) or set(rec) != _TOP_KEYS:
        return False
    if type(rec["schema_version"]) is not int or rec["schema_version"] != 1:
        return False
    if not (isinstance(rec["binding_id"], str)
            and _BINDING_ID_RE.fullmatch(rec["binding_id"])):
        return False
    if not (isinstance(rec["task_id"], str)
            and _SEGMENT_RE.fullmatch(rec["task_id"])):
        return False
    if not _valid_attempt(rec["attempt"]):
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


def read_envelope(rd, binding_id):
    """The stored envelope, None if absent; ValueError on corrupt or invalid.

    Reads through coordination._read: no-follow, nonblocking, regular-file
    only. Callers hold the global owner lock.
    """
    path = envelope_path(rd, binding_id)
    try:
        rec = coordination._read(path)
    except ValueError as exc:
        raise ValueError("corrupt return envelope") from exc
    if rec is None:
        return None
    if not valid_envelope(rec) or rec["binding_id"] != binding_id:
        raise ValueError("invalid return envelope")
    return rec
