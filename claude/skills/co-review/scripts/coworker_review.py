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
        check_round_currency=False,
    )


# Severity drives blocking. Anything not a recognized advisory level is
# treated as blocking (fail closed), so a missing or unknown severity can never
# silently produce APPROVE. The blocking levels live in _SEVERITY_RANK below,
# which carries their order as well as their membership.
_ADVISORY_SEVERITIES = {"minor", "low", "nit", "advisory"}

_SHA_RE = re.compile(r"[0-9a-f]{40}")


# The progressive floor. After a round or two the useful question stops being
# "is anything wrong" and becomes "is this functional", so the bar to block
# rises with the round index. Rank order is the severity's strength; a finding
# blocks when its rank meets the round's floor.
_SEVERITY_RANK = {"major": 1, "high": 2, "critical": 3}
_FLOOR_BY_ROUND = {1: 1, 2: 2}
_FINAL_FLOOR = 3  # round 3 and later: critical only


def floor_for_round(round_index, *, baseline_ok: bool = False) -> int:
    """Minimum blocking rank for this round. Fail closed to the round-1 floor.

    An unusable round index means the caller could not establish which round
    this is, and the strictest floor is the safe answer -- never the most
    permissive one, which would silently stop blocking on real defects. A bool
    is a caller bug, not a round index, so it never reaches int().

    ``baseline_ok`` is the baseline contract's guard: narrowing depends on
    comparing the current tree against the head round 1 reviewed, so when that
    evidence is missing or contradictory the floor does not narrow at all.

    It defaults to False so that narrowing requires positive evidence. A caller
    that forgets to validate the baseline gets the strict round-1 floor rather
    than silent narrowing, and every PR whose markers predate the field reviews
    at the strict floor by construction.
    """
    if baseline_ok is not True:
        # Positive evidence means the literal True, not merely truthy. The
        # callers pass values read out of the same table whose documented
        # negatives are strings like "no" and "unknown", and every one of those
        # is truthy.
        return _FLOOR_BY_ROUND[1]
    # Accept an ordinal, not anything int() will consume. Truncation is the
    # danger: 2.5, Decimal("2.5") and Fraction(5, 2) all become 2 and narrow
    # the floor on a number that was never a round ordinal. Allowing only real
    # ints and digit strings rules out every fractional type at once, and takes
    # float('inf') and float('nan') with them.
    if isinstance(round_index, bool):
        return _FLOOR_BY_ROUND[1]
    if isinstance(round_index, int):
        index = round_index
    elif isinstance(round_index, str) and round_index.strip().isdigit():
        index = int(round_index.strip())
    else:
        return _FLOOR_BY_ROUND[1]
    if index < 1:
        return _FLOOR_BY_ROUND[1]
    return _FLOOR_BY_ROUND.get(index, _FINAL_FLOOR)


# The seat answers "was this scenario reachable at the baseline tree" in the
# round table's Regression column, so the value arriving here is the documented
# vocabulary -- a string -- not a bool. Only an explicit no narrows.
_NOT_A_REGRESSION = {"no", "false"}


def is_fix_regression(value) -> bool:
    """Read the seat's regression answer. Fail closed to "yes".

    Everything that is not an explicit negative is a regression: a missing
    column, an empty cell, None, and the documented "unknown" all block, which
    is what the skill promises. Plain ``bool(value)`` would get this exactly
    backwards on both ends -- the documented "no" is a non-empty string and so
    truthy, while an unfilled cell arrives as None or "" and so falsy.
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() not in _NOT_A_REGRESSION
    # Anything else -- None, 0, [], {} -- is a malformed answer, not evidence
    # that the seat ruled the scenario pre-existing. bool() would read 0 and
    # the empty containers as an explicit "no" and narrow the floor on them.
    return True


def baseline_ok_from_markers(markers) -> bool:
    """Whether the marker history supports narrowing the floor.

    The first trusted marker must record a `baseline`, and every later marker
    must repeat it unchanged. A missing first marker, a missing value, or any
    disagreement means the evidence the floor narrows on is not there, and the
    round stays at the strict floor.

    This is the producer for ``baseline_ok``. Leaving it to the reviewing agent
    would make the guard the same self-declared bookkeeping the round index was
    changed to stop trusting. The caller still has to confirm the baseline tree
    is readable -- that needs a repository, not a marker -- and must AND its
    answer with this one.
    """
    markers = list(markers or ())
    if not markers:
        return False
    first = markers[0] if isinstance(markers[0], dict) else {}
    baseline = first.get("baseline")
    if not isinstance(baseline, str) or not _SHA_RE.fullmatch(baseline):
        return False
    # The baseline must be the head the FIRST round actually reviewed, not
    # merely a value every marker agrees on. Consistency alone would accept a
    # baseline pointing past the real starting point, and a regression
    # introduced after it would then classify as pre-existing and stop blocking.
    if first.get("sha") != baseline:
        return False
    for marker in markers[1:]:
        if not isinstance(marker, dict) or marker.get("baseline") != baseline:
            return False
    return True


def round_index_for_head(prior_markers, head) -> int:
    """Which round this review is, counted in DISTINCT REVIEWED HEADS.

    The floor may only narrow on evidence of progress, and the marker's own
    ``round`` field is self-declared bookkeeping: an agent counts comments and
    writes an integer. Counting comments lets a publish retry, a miscount, or
    simply re-running the review on an unchanged tree narrow the floor without
    a single line of code changing.

    Distinct `sha` values are evidence the markers already carry. A retry
    repeats a sha, and a re-review of an unfixed tree repeats the current head,
    so neither advances the round. Only a genuinely new reviewed head does.

    ``prior_markers`` must be in publication order; the ordinal a head receives
    is its first appearance in that sequence.
    """
    if not (isinstance(head, str) and _SHA_RE.fullmatch(head)):
        # Prior shas are validated below for exactly this reason; an unusable
        # head would otherwise fall through to the len(order) + 1 branch and
        # take the LOOSEST index on a caller bug.
        return 1
    order: list[str] = []
    for marker in prior_markers or ():
        sha = marker.get("sha") if isinstance(marker, dict) else None
        # Only a real object name counts. Anything else is a malformed or
        # foreign-family marker, and counting it would inflate the index and
        # narrow the floor on evidence that is not a reviewed head at all.
        if isinstance(sha, str) and _SHA_RE.fullmatch(sha) and sha not in order:
            order.append(sha)
    if head in order:
        # A head keeps the ordinal of the round that FIRST reviewed it. Simply
        # counting earlier heads would hand a rolled-back head a later round's
        # looser floor, so a fresh major found after returning to head A could
        # be narrowed away by rounds that only ever examined B and C.
        return order.index(head) + 1
    return len(order) + 1


def is_blocking(
    severity,
    *,
    round_index=1,
    fix_regression=None,
    carried: object = False,
    discharged: object = None,
    baseline_ok: bool = False,
) -> bool:
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
    if _is_discharged(discharged) and is_carried(carried):
        # The seat verified the failure path is repaired. The published table
        # keeps the row so the thread stays a complete record, but a repaired
        # finding does not block on its severity either -- checking this before
        # severity is what makes "RESOLVED" mean resolved rather than "resolved
        # unless it happens to be critical".
        #
        # Scoped to carried rows. A round publishes BEFORE its fixes are
        # committed, so a fresh finding cannot honestly be RESOLVED, and
        # without this one mislabelled Status cell on a fresh critical would
        # buy a clean round.
        return False
    if is_carried(carried):
        # Checked BEFORE severity classification. Downgrading a carried blocker
        # to an advisory severity would otherwise clear it through the advisory
        # early-return, discharging it by reclassification instead of by the
        # verification seat's repair evidence.
        return True
    if not isinstance(severity, str):
        return True
    rank = _SEVERITY_RANK.get(severity.strip().lower())
    if rank is None:
        # Not a recognized severity at all. Advisory levels are known and
        # never block; anything else is unrecognized and fails closed.
        return severity.strip().lower() not in _ADVISORY_SEVERITIES
    if rank >= floor_for_round(round_index, baseline_ok=baseline_ok):
        return True
    return is_fix_regression(fix_regression) and rank >= _SEVERITY_RANK["high"]


def is_carried(value) -> bool:
    """Read the Carried cell. Fail closed to "carried".

    Same table, same vocabulary, same trap as is_fix_regression: the documented
    negative is the string "no", and bool("no") is True, which would mark every
    row carried and make the floor inert. Only an explicit negative clears it.
    """
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() not in _NOT_A_REGRESSION
    # Anything else is a malformed cell, not an explicit "this was not carried".
    # Reading it as cleared would discharge a blocker by corruption, so it
    # fails closed exactly as is_fix_regression does. Absence is handled by the
    # caller, which only passes a value when the column is present.
    return True


def _is_discharged(status) -> bool:
    """True only for the seat's explicit RESOLVED disposition.

    Takes the Status cell verbatim, like the other two normalizers.

    The published table keeps discharged rows so the thread stays a complete
    record, so the verdict has to tell a row the seat repaired from one it is
    still carrying. Anything other than an explicit resolved -- missing,
    blank, "open", "disputed" -- leaves the row blocking.
    """
    return isinstance(status, str) and status.strip().lower() == "resolved"


def verdict_from_findings(
    findings,
    *,
    round_index=1,
    baseline_ok: bool = False,
    require_carried: bool = False,
) -> str:
    """CHANGES if any finding blocks at this round, else APPROVE.

    Blocking is derived from each finding's 'severity' and 'fix_regression'
    fields, not a caller-set flag, so the conversion is what the tests
    exercise. A missing 'fix_regression' is read as True: an unclassified
    finding is one the seat could not rule on, and those block.

    Rows are dicts keyed 'severity', 'fix_regression', 'carried' and 'status'.

    ``require_carried`` says the rows come from a co-review round table, where
    every row carries a Carried cell: an absent one is a malformed row and
    blocks, like every other absent cell here. The coworker-review family has
    no Carried column at all, so it leaves this False and absence means what it
    says. Without the distinction an absent key silently un-carried a blocker
    while ``is_blocking`` -- fed the same row's cell directly -- still reported
    it blocking, so a published table could read Blocking=yes beside APPROVE.
    """
    return (
        "CHANGES"
        if any(
            is_blocking(
                row.get("severity"),
                round_index=round_index,
                fix_regression=row.get("fix_regression"),
                carried=(
                    row.get("carried")
                    if require_carried
                    else row.get("carried", False)
                ),
                discharged=row.get("status"),
                baseline_ok=baseline_ok,
            )
            # A malformed row is not a reason to take down the round. An empty
            # dict has no severity, which is_blocking already fails closed on,
            # so a junk entry blocks instead of raising -- and the result no
            # longer depends on where in the list it sits, which any() would
            # otherwise make order-dependent.
            for row in (f if isinstance(f, dict) else {} for f in findings)
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
