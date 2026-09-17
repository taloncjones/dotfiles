"""Component capability levels for the task-lead orchestrator tier.

Core and guard both import this module, so each component has exactly one
declared level rather than two that can disagree. Guard already imports core's
package, so keeping the constants here avoids a circular import.

Reading your OWN constant reads the level of the code actually executing.
Reading ANOTHER component's constant reads an installation fact, not an
execution fact -- see the activation gate design, section 4.1.
"""

import json
import os
import re
import stat
import sys
from pathlib import Path

# Self-sufficient import, as in herdr_coordination and herdr_orch_core: this
# module is loaded both as a sibling hook import and by file path (the
# capability suite uses spec_from_file_location), and the latter puts nothing
# on sys.path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_coordination as coordination

#: Marker format version. Bump only when the marker's SHAPE changes.
MARKER_VERSION = 1

#: Level required before a lead may be admitted.
REQUIRED_CAPABILITY = 1

#: Core implements gate enforcement at admission.
CORE_CAPABILITY = 1

#: Guard implements gate enforcement at authority.
GUARD_CAPABILITY = 1

_MARKER_RE = re.compile(r"^<!--\s*herdr-capabilities:\s*(.*?)\s*-->\s*$", re.M)


def _exact_int(value):
    """True only for a real int. bool is a subclass of int and must not pass."""
    return type(value) is int


def parse_marker(text):
    """The declared capability, or None when the advertisement is unusable.

    Fail-closed: missing, duplicated, malformed, wrong marker_version, or a
    non-integer capability all yield None. Never raises on caller input.
    """
    if not isinstance(text, str):
        return None
    found = _MARKER_RE.findall(text)
    if len(found) != 1:
        return None
    try:
        rec = json.loads(found[0])
    except Exception:  # noqa: BLE001 -- deep nesting raises RecursionError, not ValueError
        return None
    if not isinstance(rec, dict):
        return None
    if not _exact_int(rec.get("marker_version")) or rec["marker_version"] != MARKER_VERSION:
        return None
    if not _exact_int(rec.get("capability")) or rec["capability"] < 0:
        return None
    return rec["capability"]


#: Most of a procedure file we will read. The shipped SKILL.md is ~82 KB; an
#: unbounded read on a hook path is a denial of service by a large file.
PROCEDURE_READ_LIMIT = 4 * 1024 * 1024


def _read_procedure_text(path):
    """Procedure marker text, read without following a link AT THE LEAF.

    Deliberately NOT the no-follow parent walk `_read_gate_text` uses. The
    supported install reaches this file THROUGH a symlinked directory --
    `~/.claude/skills` is a symlink into the dotfiles checkout -- so refusing
    symlinked parents here would refuse the layout we ship. The leaf is a
    plain regular file in that layout, so O_NOFOLLOW on it costs nothing and
    refuses a planted link that would otherwise advertise a capability from a
    file the account does not own. That is the second lock, and it is the one
    carrying the adversarial claim: the gate record lives under the
    guard-exempt state root, so the marker is what an attacker must forge.

    O_NONBLOCK for the reason the gate reader states: a FIFO here parks
    admission forever. Admission runs inside the owner transaction's exclusive
    flock, so that wedges every other verb on the coordination root, and a
    PreToolUse hook that never exits is timed out -- after which the tool call
    proceeds. A hang is not an exception, so no crash handler can catch it.
    """
    fd = os.open(str(path), os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("procedure marker must be a regular file")
        return stream.read(PROCEDURE_READ_LIMIT).decode("utf-8")


def procedure_capability(config_dir):
    """The installed procedure's capability, or None when unreadable.

    Resolved through the SELECTED ACCOUNT's config dir, never the working
    directory: a compatible sibling file in the current checkout is not
    evidence of what is installed.
    """
    try:
        path = Path(config_dir) / "skills" / "herdr-orchestration" / "SKILL.md"
        text = _read_procedure_text(path)
    except Exception:  # noqa: BLE001 -- unreadable advertises nothing, never a crash
        return None
    return parse_marker(text)


#: Version of the gate record itself. Validated at exactly one site.
GATE_SCHEMA_VERSION = 1

GATE_NAME = "task-lead-gate.json"


def gate_path(rd):
    return Path(rd) / GATE_NAME


def _read_gate_text(path):
    """Gate record text, read without following a link at any component.

    `herdr_orch_core.read_payload_bytes` already reads payload files exactly
    this way, but core imports THIS module, so calling it would be a circular
    import. The flags below match it component for component:

    - `payload_parent` walks every parent with O_NOFOLLOW, so a symlinked
      ancestor is refused rather than followed. It takes no lock and asserts
      nothing outside a transaction, which is what lets the edit guard call
      the gate reader on its read-only path.
    - O_NOFOLLOW on the leaf refuses a symlinked record. Accepting one would
      let anyone who can create a link in the state dir point the gate at a
      file saying `enabled`, which reads as FAIL-OPEN against the
      absence-means-disabled default -- and the real writer could then no
      longer turn it off, leaving rollback step 0 unsatisfiable.
    - O_NONBLOCK means a FIFO in the record's place returns instead of
      parking the hook forever. On a hook timeout the tool call proceeds, so
      a blocking read removes the guard rather than tightening it.
    - S_ISREG refuses a device or directory that opened anyway.
    """
    with coordination.payload_parent(path) as (parent, name):
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent,
        )
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("gate record must be a regular file")
            return stream.read().decode("utf-8")


def gate_enabled(rd, repo_slug, account_id, repo_id=None):
    """(enabled, reason). Anything other than a well-formed, identity-matching,
    enabled record is disabled. Never raises: every failure is a disabled
    answer with a diagnostic, because the operator needs the reason more than
    they need a traceback.

    repo_id is the canonical repository identity and is NULLABLE, matching how
    binding records already treat it (`herdr_bindings.py:59`). The matching
    rule, fail-closed at the ambiguous end:

    - record's repo_id is None      -> no constraint; the record makes no
                                       identity claim to corroborate.
    - record's set, caller's set    -> must be equal.
    - record's set, caller's None   -> REFUSE. The record asserts an identity
                                       and we cannot corroborate it; accepting
                                       would honour an unverifiable claim.
    - record's present but not a
      string or None                -> REFUSE as malformed.

    The first three rows are the SAME rule `claim_owner` already applies to a
    binding's identity at `herdr_orch_core.py:1805`
    (`rec["repo_id"] is not None and rec["repo_id"] != context["repo_id"]`).
    This follows that convention rather than inventing a second one.
    """
    try:
        raw = _read_gate_text(gate_path(rd))
    except FileNotFoundError:
        return False, "gate record absent"
    except Exception as exc:  # noqa: BLE001 -- unreadable is disabled, never a crash
        return False, f"gate record unreadable: {exc}"
    try:
        rec = json.loads(raw)
    except Exception:  # noqa: BLE001 -- deep nesting raises RecursionError, not ValueError
        return False, "gate record is not valid JSON"
    if not isinstance(rec, dict):
        return False, "gate record is not an object"
    if not _exact_int(rec.get("schema_version")) or rec["schema_version"] != GATE_SCHEMA_VERSION:
        return False, "gate record schema_version is unsupported"
    if rec.get("repo_slug") != repo_slug:
        return False, "gate record names a different repository slug"
    if rec.get("account_id") != account_id:
        return False, "gate record names a different account"
    stated = rec.get("repo_id")
    if stated is not None:
        if not isinstance(stated, str) or not stated:
            return False, "gate record repo_id is malformed"
        if repo_id is None:
            return False, "gate record names a repository identity that cannot be corroborated"
        if stated != repo_id:
            return False, "gate record names a different repository identity"
    if type(rec.get("enabled")) is not bool:
        return False, "gate record enabled is not a boolean"
    if not rec["enabled"]:
        return False, "task-lead dispatch is disabled"
    return True, "task-lead dispatch is enabled"
