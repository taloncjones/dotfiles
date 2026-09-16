"""Component capability levels for the task-lead orchestrator tier.

Core and guard both import this module, so each component has exactly one
declared level rather than two that can disagree. Guard already imports core's
package, so keeping the constants here avoids a circular import.

Reading your OWN constant reads the level of the code actually executing.
Reading ANOTHER component's constant reads an installation fact, not an
execution fact -- see the activation gate design, section 4.1.
"""

import json
import re
from pathlib import Path

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
    except ValueError:
        return None
    if not isinstance(rec, dict):
        return None
    if not _exact_int(rec.get("marker_version")) or rec["marker_version"] != MARKER_VERSION:
        return None
    if not _exact_int(rec.get("capability")) or rec["capability"] < 0:
        return None
    return rec["capability"]


def procedure_capability(config_dir):
    """The installed procedure's capability, or None when unreadable.

    Resolved through the SELECTED ACCOUNT's config dir, never the working
    directory: a compatible sibling file in the current checkout is not
    evidence of what is installed.
    """
    try:
        path = Path(config_dir) / "skills" / "herdr-orchestration" / "SKILL.md"
        text = path.read_text(encoding="utf-8")
    except (OSError, TypeError, ValueError):
        return None
    return parse_marker(text)


#: Version of the gate record itself. Validated at exactly one site.
GATE_SCHEMA_VERSION = 1

GATE_NAME = "task-lead-gate.json"


def gate_path(rd):
    return Path(rd) / GATE_NAME


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
    path = gate_path(rd)
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return False, "gate record absent"
    except (OSError, ValueError) as exc:
        return False, f"gate record unreadable: {exc}"
    try:
        rec = json.loads(raw)
    except ValueError:
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
