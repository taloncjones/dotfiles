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
    path = Path(config_dir) / "skills" / "herdr-orchestration" / "SKILL.md"
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, ValueError):
        return None
    return parse_marker(text)
