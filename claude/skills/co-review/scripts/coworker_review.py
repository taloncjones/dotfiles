"""Coworker-PR review pure logic: verdict, marker, and re-review scope.

No fixes are applied in this mode. The marker is namespaced 'co-review-coworker:'
so the pr-ready currency gate (anchored to the colon-terminated MARKER_PREFIX,
'<!-- co-review:') can never consume it.
"""
from __future__ import annotations

import importlib.util
import re
from pathlib import Path

# Reuse the hardened fence/indent/quote-safe author-trusted scanner.
_GATE_SRC = Path(__file__).resolve().parent / "pr_ready_gate.py"
_gspec = importlib.util.spec_from_file_location("pr_ready_gate", _GATE_SRC)
_gate = importlib.util.module_from_spec(_gspec)
_gspec.loader.exec_module(_gate)

COWORKER_MARKER_RE = re.compile(
    r"^<!-- co-review-coworker: sha=(?P<sha>[0-9a-f]{40}) "
    r"base=(?P<base>[0-9a-f]{40}) base_ref=(?P<base_ref>\S+) "
    r"base_ref_tip=(?P<base_ref_tip>[0-9a-f]{40}) "
    r"verdict=(?P<verdict>APPROVE|CHANGES) round=(?P<round>\d+) -->$"
)
# See pr_ready_gate.MARKER_PREFIX: the shortest prefix that unambiguously
# identifies this family (up to and including the discriminating colon), not
# the marker's longer literal opening. Do not lengthen this back toward
# "<!-- co-review-coworker: " -- that reopens the truncation leak this
# constant exists to close.
COWORKER_MARKER_PREFIX = "<!-- co-review-coworker:"


def build_marker(sha, base, base_ref, base_ref_tip, verdict, rnd) -> str:
    return (
        f"<!-- co-review-coworker: sha={sha} base={base} base_ref={base_ref} "
        f"base_ref_tip={base_ref_tip} verdict={verdict} round={rnd} -->"
    )


def select_coworker_marker(comments, trusted_authors):
    """Latest trusted single coworker marker, or None. Fail-closed."""
    return _gate.select_marker(
        comments,
        set(trusted_authors),
        COWORKER_MARKER_RE,
        COWORKER_MARKER_PREFIX,
        require_findings=False,
    )


# Severity drives blocking. Anything not a recognized advisory level is
# treated as blocking (fail closed), so a missing or unknown severity can never
# silently produce APPROVE.
_BLOCKING_SEVERITIES = {"major", "high", "critical"}
_ADVISORY_SEVERITIES = {"minor", "low", "nit", "advisory"}


# The progressive floor. After a round or two the useful question stops being
# "is anything wrong" and becomes "is this functional", so the bar to block
# rises with the round index. Rank order is the severity's strength; a finding
# blocks when its rank meets the round's floor.
_SEVERITY_RANK = {"major": 1, "high": 2, "critical": 3}
_FLOOR_BY_ROUND = {1: 1, 2: 2}
_FINAL_FLOOR = 3  # round 3 and later: critical only


def floor_for_round(round_index) -> int:
    """Minimum blocking rank for this round. Fail closed to the round-1 floor.

    An unusable round index means the caller could not establish which round
    this is, and the strictest floor is the safe answer -- never the most
    permissive one, which would silently stop blocking on real defects.
    """
    try:
        index = int(round_index)
    except (TypeError, ValueError):
        return _FLOOR_BY_ROUND[1]
    if index < 1:
        return _FLOOR_BY_ROUND[1]
    return _FLOOR_BY_ROUND.get(index, _FINAL_FLOOR)


def is_blocking(severity, *, round_index=1, fix_regression=False) -> bool:
    """True when this finding blocks at this round (fail closed).

    Anything not a recognized advisory level still blocks at round 1, so a
    missing or unknown severity can never silently produce APPROVE.

    The parameters are keyword-only with round-1 defaults because this helper
    is shared with the coworker-review family, which has no progressive floor:
    the round-1 floor with no regression concept IS the coworker contract, and
    every existing call site keeps its behaviour untouched.

    ``fix_regression`` is the verification seat's answer to "was this scenario
    reachable at the baseline tree". A finding the floor would otherwise let
    through still blocks when it is high or above and the seat says the change
    introduced it -- that is the one thing a late round still cares about.
    """
    if not isinstance(severity, str):
        return True
    rank = _SEVERITY_RANK.get(severity.strip().lower())
    if rank is None:
        # Not a recognized severity at all. Advisory levels are known and
        # never block; anything else is unrecognized and fails closed.
        return severity.strip().lower() not in _ADVISORY_SEVERITIES
    if rank >= floor_for_round(round_index):
        return True
    return bool(fix_regression) and rank >= _SEVERITY_RANK["high"]


def verdict_from_findings(findings, *, round_index=1) -> str:
    """CHANGES if any finding blocks at this round, else APPROVE.

    Blocking is derived from each finding's 'severity' and 'fix_regression'
    fields, not a caller-set flag, so the conversion is what the tests
    exercise. A missing 'fix_regression' is read as True: an unclassified
    finding is one the seat could not rule on, and those block.
    """
    return (
        "CHANGES"
        if any(
            is_blocking(
                f.get("severity"),
                round_index=round_index,
                fix_regression=f.get("fix_regression", True),
            )
            for f in findings
        )
        else "APPROVE"
    )


def decide_review_scope(prev_marker, new_head, current_base_ref, current_base_ref_tip, is_ancestor):
    """('full', None) or ('incremental', (prev_head, new_head)).

    Full review whenever incremental would be wrong: first review, unchanged
    head (empty delta -- note --is-ancestor is True for identical commits),
    rewritten history (prev not an ancestor), a retargeted base branch, or a
    moved base tip.
    """
    if prev_marker is None:
        return ("full", None)
    prev_head = prev_marker["sha"]
    if prev_head == new_head:
        return ("full", None)
    if not is_ancestor:
        return ("full", None)
    if current_base_ref != prev_marker["base_ref"]:
        return ("full", None)
    if current_base_ref_tip != prev_marker["base_ref_tip"]:
        return ("full", None)
    return ("incremental", (prev_head, new_head))
