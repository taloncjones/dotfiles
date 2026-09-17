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

#: Longest line that can plausibly hold a marker. The shipped one is 62 bytes.
MARKER_LINE_MAX = 512

_MARKER_OPEN = "<!--"
_MARKER_KEY = "herdr-capabilities:"
_MARKER_CLOSE = "-->"


def _marker_payloads(text):
    """Every marker payload in `text`, or None if any candidate is unusable.

    Deliberately NOT a regular expression. The pattern this replaces was
    `^<!--\\s*herdr-capabilities:\\s*(.*?)\\s*-->\\s*$`, and a lazy group
    between two whitespace quantifiers backtracks catastrophically, because
    `.` also matches the whitespace the quantifiers are claiming. Measured on
    a malformed line -- one with no terminator, or a near-miss like a trailing
    lone `-`:

        pure spaces   n=2000  3.2s   n=5000  47s    n=8000  206s
        tab+space     n=2000  26s    n=4000  214s   n=8000  1728s

    Both fail-open. It runs on the PreToolUse path, where overrunning the hook
    timeout lets the tool call proceed (crossed at roughly a 5 KB file), and
    inside owner_transaction's exclusive flock at claim time, which has no
    timeout at all and wedges every other verb on the coordination root -- one
    8 KB line costs about half an hour there.

    Narrowing the classes does NOT fix this. An intermediate version used
    `[ \\t]` instead of `\\s`, which removes only the newline ambiguity;
    measured against the tab-and-space variant it was no faster than the
    original. Nor is a read bound a defence: the pathology reaches its worst
    case in a few kilobytes, so the 4 MB limit is irrelevant rather than
    generous. And a length cap alone is a control with no margin.

    So: explicit line parsing, every step linear in the line's length, with no
    backtracking to exploit. A well-formed marker was always free even under
    the old pattern -- the cost needed a MALFORMED candidate -- which is why
    this was never seen in normal use and why nothing about the payload looks
    suspicious on inspection.
    """
    if _spans_lines(text):
        return None
    payloads = []
    # split("\n"), never splitlines(). splitlines() also breaks on VT, FF, FS,
    # GS, RS, NEL, U+2028, U+2029 and a bare CR, while the regex's ^ and $
    # under MULTILINE anchor only at \n. Accepting those let a marker be
    # smuggled mid-prose: every renderer and grep sees one line, the parser
    # saw a declaration.
    for line in text.split("\n"):
        # Column 0, with no lstrip. The regex anchored `<!--` at ^, so an
        # INDENTED marker declared nothing -- which is what makes a four-space
        # Markdown example safe to write. Stripping first turned every such
        # example into a live declaration.
        if not line.startswith(_MARKER_OPEN) or _MARKER_KEY not in line:
            continue
        # Length is checked only AFTER the shape test. Checking it first let
        # one long prose line that merely mentioned the key refuse the whole
        # file. Every step below is linear, so this cap is defence in depth,
        # not the bound that holds.
        if len(line) > MARKER_LINE_MAX:
            return None
        rest = line.rstrip()
        if not rest.endswith(_MARKER_CLOSE):
            continue
        body = rest[len(_MARKER_OPEN):-len(_MARKER_CLOSE)].strip()
        if not body.startswith(_MARKER_KEY):
            continue
        payloads.append(body[len(_MARKER_KEY):].strip())
    return payloads


def _spans_lines(text):
    """True if a marker-looking comment spans more than one line.

    The regex this replaced matched such a comment, because its `\\s` crossed
    newlines, and counted it toward the duplicate rule. The line parser cannot
    see it at all -- so a file the interlock used to refuse as duplicated
    started advertising a capability instead.

    Neither behaviour is right. A marker spanning lines is not a line marker,
    so accepting it is wrong; ignoring it reopens the duplicate hole. Refusing
    the whole file is the only fail-closed answer, and it is what a reader who
    wrote one across lines should be told.
    """
    pos = 0
    while True:
        start = text.find(_MARKER_OPEN, pos)
        if start < 0:
            return False
        if start == 0 or text[start - 1] == "\n":
            end = text.find(_MARKER_CLOSE, start + len(_MARKER_OPEN))
            if end < 0:
                return False
            span = text[start:end]
            if "\n" in span and _MARKER_KEY in span:
                return True
        pos = start + len(_MARKER_OPEN)


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
    found = _marker_payloads(text)
    if found is None or len(found) != 1:
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
    file the account does not own.

    What that is NOT is an adversarial control, and an earlier version of this
    docstring claimed otherwise -- that the marker "carries the adversarial
    claim" and is "what an attacker must forge". It is not. Because the parent
    is deliberately followed, one `ln -sfn <tree> <config_dir>/skills` takes
    this function from 0 to 1 and admission from refuse to admit; `python -c
    os.symlink` does the same, and both are listed among the edit guard's
    documented accepted holes, which states outright that it guards against
    drift and not evasion. Nor is the gate record a control: it lives under
    the guard-exempt state root and is hand-writable by the very sessions it
    constrains. There is no second lock. Both records sit inside the session's
    own uid write scope, and nothing here puts either outside it.

    So read the whole activation gate as what it is: an interlock against
    accident, drift and premature activation. That is a real and useful
    property -- it is what keeps a half-installed or downgraded component from
    silently dispatching leads -- and it is worth the no-follow and S_ISREG
    checks below, which refuse the accidental and the drifting case. It is not
    a boundary against a session that has decided to cross it.

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
        # LIMIT + 1, then refuse. A silent truncation at the bound turns an
        # INVALID file into a VALID advertisement: a capability-1 marker,
        # padding, and a second marker past the cutoff read as 1, where
        # parsing the whole file returns None under the fail-closed
        # duplicate-marker rule. Over-length must be refused, not trimmed.
        raw = stream.read(PROCEDURE_READ_LIMIT + 1)
    if len(raw) > PROCEDURE_READ_LIMIT:
        raise ValueError("procedure marker is too large to read")
    return raw.decode("utf-8")


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

#: Most of a gate record we will read. A canonical record with a full-length
#: slug and 32-hex account/repo ids serializes to 181 bytes.
GATE_READ_LIMIT = 64 * 1024


class _IdentityDeferred:
    """Sentinel: evaluate every gate clause EXCEPT identity corroboration.

    For a caller that must decide whether resolving a live repo_id is worth
    paying for -- the edit guard, where that resolution is six git
    subprocesses outside its own budget, on a path whose failure mode is a
    hook timeout that proceeds.

    It is NOT the same as passing None. None means "I have no identity to
    offer", which makes a record that NAMES an identity fail closed as
    uncorroborated -- correct as a final answer, wrong as a pre-check, because
    it would refuse exactly the leads the full check admits. This sentinel
    instead skips the corroboration clause while still validating the
    record's shape, so a caller can cheaply learn whether anything OTHER than
    identity already disqualifies the gate, then resolve the live repo_id and
    call again for the real decision. Only ever a pre-check: a decision made
    under this sentinel has not checked identity at all.
    """

    def __repr__(self):
        return "IDENTITY_DEFERRED"


IDENTITY_DEFERRED = _IdentityDeferred()


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
            # Bounded, for the reason the procedure reader is. The sibling got
            # this and the gate reader did not: an unbounded read of a
            # plantable file (the state root is guard-exempt) costs 2x the
            # file in memory -- 256MB of record peaked 525MB RSS -- on a path
            # whose failure mode is a hook timeout, which proceeds. A
            # canonical record with a full-length slug and 32-hex ids is 181
            # bytes, so 64 KiB is four decimal orders of headroom.
            raw = stream.read(GATE_READ_LIMIT + 1)
        if len(raw) > GATE_READ_LIMIT:
            raise ValueError("gate record is too large to be a record")
        return raw.decode("utf-8")


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
    if repo_id is IDENTITY_DEFERRED:
        # Validate the record's shape, defer corroboration. See the sentinel's
        # comment for why this is not the same as passing None.
        if stated is not None and (not isinstance(stated, str) or not stated):
            return False, "gate record repo_id is malformed"
    elif stated is not None:
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
