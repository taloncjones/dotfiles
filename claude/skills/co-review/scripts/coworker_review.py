"""Coworker-PR review pure logic: verdict, marker, and re-review scope.

No fixes are applied in this mode. The marker is namespaced 'co-review-coworker:'
so the pr-ready currency gate (anchored to 'co-review: ') can never consume it.
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


def build_marker(sha, base, base_ref, base_ref_tip, verdict, rnd) -> str:
    return (
        f"<!-- co-review-coworker: sha={sha} base={base} base_ref={base_ref} "
        f"base_ref_tip={base_ref_tip} verdict={verdict} round={rnd} -->"
    )


def select_coworker_marker(comments, trusted_authors):
    """Latest trusted single coworker marker, or None. Fail-closed."""
    return _gate.select_marker(comments, set(trusted_authors), COWORKER_MARKER_RE)


# Severity drives blocking. Anything not a recognized advisory level is
# treated as blocking (fail closed), so a missing or unknown severity can never
# silently produce APPROVE.
_BLOCKING_SEVERITIES = {"major", "high", "critical"}
_ADVISORY_SEVERITIES = {"minor", "low", "nit", "advisory"}


def is_blocking(severity) -> bool:
    """True unless severity is a recognized advisory level (fail closed)."""
    if not isinstance(severity, str):
        return True
    return severity.strip().lower() not in _ADVISORY_SEVERITIES


def verdict_from_findings(findings) -> str:
    """CHANGES if any finding's severity is blocking, else APPROVE.

    Blocking is derived from each finding's 'severity' field, not a caller-set
    flag, so severity-to-blocking conversion is what the tests exercise.
    """
    return "CHANGES" if any(is_blocking(f.get("severity")) for f in findings) else "APPROVE"


def decide_review_scope(prev_marker, new_head, current_base_ref_tip, is_ancestor):
    """('full', None) or ('incremental', (prev_head, new_head)).

    Full review whenever incremental would be wrong: first review, unchanged
    head (empty delta -- note --is-ancestor is True for identical commits),
    rewritten history (prev not an ancestor), or a moved base tip.
    """
    if prev_marker is None:
        return ("full", None)
    prev_head = prev_marker["sha"]
    if prev_head == new_head:
        return ("full", None)
    if not is_ancestor:
        return ("full", None)
    if current_base_ref_tip != prev_marker["base_ref_tip"]:
        return ("full", None)
    return ("incremental", (prev_head, new_head))
