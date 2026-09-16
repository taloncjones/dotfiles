"""Parse co-review markers and decide PR-ready currency. Pure logic + thin CLI."""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone

MARKER_RE = re.compile(
    r"^<!-- co-review: sha=(?P<sha>[0-9a-f]{40}) base=(?P<base>[0-9a-f]{40}) "
    r"base_ref=(?P<base_ref>\S+) verdict=(?P<verdict>APPROVE|CHANGES) "
    r"round=(?P<round>[1-9]\d*)(?: target_tip=(?P<target_tip>[0-9a-f]{40}))?"
    r"(?: baseline=(?P<baseline>[0-9a-f]{40}))? -->$"
)
# target_tip records the target-branch tip the review compared against. It is
# for the reader: decide() never compares it, so an approval does not expire
# when the target moves. A target change that breaks the PR is CI's job.
#
# baseline records the head round 1 reviewed, and drives the progressive
# blocking floor during review. decide() never compares it either, so adding
# it cannot change a gate outcome. Both optional fields sit AFTER round and in
# this order: every marker written before either existed still parses.
# A malformed baseline does not match, so the line counts as shaped-but-invalid
# and fails the gate closed when it is the newest comment -- it is never
# skipped in favour of an older one.
# The candidate prefix -- checked with a plain startswith, not derived from
# MARKER_RE, so a truncated marker is still recognized as "a round comment
# that failed to parse" instead of falling through as ordinary text and
# letting selection revive an older comment.
#
# Deliberately shorter than the marker's literal opening ("<!-- co-review: ",
# with a trailing space before "sha="): it is the SHORTEST prefix that still
# unambiguously identifies this family, i.e. up to and including the colon
# that distinguishes it from "<!-- co-review-coworker:". Anything shorter
# cannot be attributed to a family at all, which is the right place to stop --
# do not "tidy" this back to the longer literal, that reopens the truncation
# leak this constant exists to close (a marker cut off right at the colon
# would then score as ordinary text, not a malformed round comment).
MARKER_PREFIX = "<!-- co-review:"
# A fence opener may be indented up to 3 spaces and carry an info string.
_FENCE_OPEN_RE = re.compile(r"^ {0,3}([`~])\1{2,}")
# Markdown recognizes only CRLF/CR/LF as line breaks; str.splitlines() also
# breaks on \v, \f, \x1c-\x1e, \x85, U+2028/2029, which would wrongly promote
# text after such a character to a column-zero line.
_LINE_RE = re.compile(r"\r\n|\r|\n")

_NO_FINDINGS = "No actionable findings."


class GateInputError(Exception):
    """The comments payload is not the expected shape."""


def _leading_ws(raw: str) -> str:
    return raw[: len(raw) - len(raw.lstrip(" \t"))]


def _is_fence_close(raw: str, fence: tuple[str, int]) -> bool:
    """A closer is only fence chars (same char, >= opener length), indented at
    most 3 spaces and never by a tab.

    Checking the raw line -- not a stripped copy -- is what makes a four-space or
    tab-indented ``~~~`` count as code content, not a closer. Markdown also
    forbids a non-whitespace suffix on a closer, so ``~~~x`` stays inside.
    """
    lead = _leading_ws(raw)
    if "\t" in lead or len(lead) > 3:
        return False
    body = raw.strip(" \t")  # only ASCII space/tab count as fence whitespace
    return bool(body) and set(body) == {fence[0]} and len(body) >= fence[1]


def _fence_opener(raw: str) -> tuple[str, int] | None:
    """(char, length) if raw opens a fenced code block, else None.

    A backtick fence's info string cannot contain a backtick, so a line like
    ``` ```example``` ``` is an inline code span, not a fence opener -- rejecting
    it keeps a later top-level marker visible.
    """
    match = _FENCE_OPEN_RE.match(raw)
    if not match:
        return None
    run = match.group(0).lstrip(" ")
    char, length = run[0], len(run)
    rest = raw.lstrip(" ")[length:]
    if char == "`" and "`" in rest:
        return None
    return (char, length)


def _top_level_lines(body: str):
    """Yield each line that is outside every fenced code block.

    Both the marker scan and the findings-body check walk this, so a table or a
    marker shown as an EXAMPLE inside a fence counts for neither. Letting the
    two disagree would let a comment satisfy the findings-body requirement with
    a fenced sample while its real marker sits alone at top level.
    """
    fence: tuple[str, int] | None = None
    for raw in _LINE_RE.split(body):
        if fence is not None:
            if _is_fence_close(raw, fence):
                fence = None
            continue
        opened = _fence_opener(raw)
        if opened is not None:
            fence = opened
            continue
        yield raw


def _scan_body(
    body: str, marker_re=MARKER_RE, prefix: str = MARKER_PREFIX
) -> tuple[int, list[dict]]:
    """(marker-shaped line count, valid markers) on top-level lines.

    The count includes lines that begin with ``prefix`` but do not parse as
    marker_re, which is what lets selection tell "this is a malformed round
    comment" apart from "this is an ordinary comment". ``prefix`` is a plain
    literal, not derived from marker_re, so a marker truncated anywhere after
    the prefix -- even mid-prefix-adjacent text -- still counts as a
    candidate instead of silently reading as ordinary text.
    """
    candidates = 0
    found: list[dict] = []
    for raw in _top_level_lines(body):
        # The marker must sit at column 0: any leading whitespace (space or tab,
        # in any mix) is Markdown code indentation. Checking the unstripped raw
        # line enforces that. The candidate check must run before any trailing
        # strip: a marker truncated to exactly `prefix` ends in the prefix's
        # own trailing space, and stripping first would eat that space and
        # miss the candidate.
        if not raw.startswith(prefix):
            continue
        candidates += 1
        line = raw.rstrip(" \t")  # ASCII trailing space only, for the $-anchored match
        hit = marker_re.match(line)
        if hit:
            found.append(hit.groupdict())
    return candidates, found


def _has_findings_body(body: str) -> bool:
    """True when the comment carries a findings table or the clean sentence.

    Neither fenced NOR indented content counts. Markdown treats a line indented
    four spaces (or by a tab) as a code block, so an example table shown that
    way is an example, not a findings table -- the same reason the marker scan
    requires column zero.
    """
    for raw in _top_level_lines(body):
        lead = _leading_ws(raw)
        if "\t" in lead or len(lead) >= 4:
            continue  # Markdown indented code block
        line = raw.strip()
        if line.startswith("|") or line == _NO_FINDINGS:
            return True
    return False


def _parse_instant(value) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def select_marker(
    comments,
    trusted_authors: set[str],
    marker_re=MARKER_RE,
    prefix: str = MARKER_PREFIX,
    require_findings: bool = True,
    check_round_currency: bool = True,
) -> dict | None:
    """Latest trusted round comment's marker, or None. Fail-closed.

    Selection precedes validation. The newest trusted comment that looks like a
    round comment (starts with ``prefix``) wins; if it is malformed, that is an
    error, never a reason to fall back to an older -- possibly approving --
    comment. ``require_findings`` gates the findings-table check: it applies to
    the pr-ready currency marker's round comments, not to other marker
    families (e.g. coworker-review markers) that share this scanner but do not
    carry that convention.
    """
    if not isinstance(comments, list):
        raise GateInputError("comments must be a JSON array")
    candidates = []
    for entry in comments:
        if not isinstance(entry, dict):
            raise GateInputError("each comment must be an object")
        if entry.get("author") not in trusted_authors:
            continue
        body = entry.get("body", "") or ""
        shaped, markers = _scan_body(body, marker_re, prefix)
        if shaped == 0:
            continue  # an ordinary comment, not a round comment
        instant = _parse_instant(entry.get("created_at"))
        cid = entry.get("id")
        if instant is None or not isinstance(cid, int):
            # A round comment without valid ordering metadata cannot be placed
            # in time; silently dropping it could revive an older approval over
            # a newer CHANGES. Fail closed instead.
            raise GateInputError("marker comment has invalid created_at/id")
        candidates.append((instant, cid, shaped, markers, body))
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], item[1]))
    _, _, shaped, markers, body = candidates[-1]
    if shaped != 1 or len(markers) != 1:
        raise GateInputError("latest co-review comment has an ambiguous or unparsable marker")
    if require_findings and not _has_findings_body(body):
        raise GateInputError("latest co-review comment has a marker but no findings table")
    selected = markers[0]
    if check_round_currency:
        _check_round_currency(selected, candidates)
    return selected


def all_markers(comments, trusted_authors, marker_re=MARKER_RE,
                prefix: str = MARKER_PREFIX,
                require_findings: bool = True) -> list[dict]:
    """Every parsed trusted marker on the PR, in publication order.

    The floor's inputs -- the round index and the baseline guard -- are
    properties of the whole marker history, not of the latest marker, and
    ``select_marker`` deliberately returns only the latest. Without this the
    caller has to rebuild the history by hand, which is the self-declared
    bookkeeping the round check exists to distrust.

    An unparsable or findings-less trusted marker makes the whole history
    unusable and raises. Skipping it would let the floor narrow on a history
    the gate itself would refuse: a malformed FIRST marker would drop out, the
    second would be read as the first, and its baseline accepted as the PR's.
    Callers needing only the floor's inputs treat the error as "no narrowing"
    -- round 1, ``baseline_ok=False`` -- the same strict answer an empty
    history gives.
    """
    if not isinstance(comments, list):
        raise GateInputError("comments must be a JSON array")
    found = []
    for entry in comments:
        if not isinstance(entry, dict):
            raise GateInputError("each comment must be an object")
        if entry.get("author") not in trusted_authors:
            continue
        shaped, markers = _scan_body(entry.get("body", "") or "", marker_re, prefix)
        if shaped == 0:
            continue
        instant = _parse_instant(entry.get("created_at"))
        cid = entry.get("id")
        if instant is None or not isinstance(cid, int):
            raise GateInputError("marker comment has invalid created_at/id")
        if shaped != 1 or len(markers) != 1:
            raise GateInputError(
                "co-review history contains an ambiguous or unparsable marker "
                f"(comment {cid}); the floor cannot narrow on it"
            )
        if require_findings and not _has_findings_body(entry.get("body", "") or ""):
            raise GateInputError(
                "co-review history contains a marker with no findings table "
                f"(comment {cid}); an incomplete round does not advance the floor"
            )
        found.append((instant, cid, markers[0]))
    found.sort(key=lambda item: (item[0], item[1]))
    markers = [marker for _, _, marker in found]
    if markers:
        _check_history_currency(markers[-1], markers[:-1])
    return markers


def _check_history_currency(latest: dict, others) -> None:
    """The same currency rules ``select_marker`` applies, over a history.

    Both readers have to agree about what a usable history is. When they did
    not, a history ``select_marker`` refuses -- two verdicts at one round --
    still fed the floor, which narrowed on it and approved a finding that
    should have blocked.
    """
    latest_round = _marker_round(latest)
    for other in others:
        other_round = _marker_round(other)
        if other_round > latest_round:
            raise GateInputError(
                "co-review history is not current; an earlier marker claims a "
                "later round than the newest one"
            )
        if other_round == latest_round and other["verdict"] != latest["verdict"]:
            raise GateInputError(
                "co-review history contradicts itself; one round carries two "
                "verdicts"
            )


def next_round_number(comments, trusted_authors, marker_re=MARKER_RE,
                      prefix: str = MARKER_PREFIX) -> int:
    """The number the NEXT round comment should carry.

    This is the publication ordinal, deliberately NOT the floor's round index.
    The floor's index is evidence of progress and falls back to 1 whenever that
    evidence is unusable; the published number has to stay monotonic anyway.
    Resetting both together wedges the PR: a round published after an
    unreadable history would claim a round the PR has already passed, the
    currency check would reject it, and pushing a commit would not help because
    the older marker stays on the PR.

    So this tolerates the malformed markers ``all_markers`` refuses -- it reads
    the highest round anything trusted on the PR claims, and adds one.
    """
    if not isinstance(comments, list):
        raise GateInputError("comments must be a JSON array")
    highest = 0
    for entry in comments:
        if not isinstance(entry, dict) or entry.get("author") not in trusted_authors:
            continue
        # A shaped-but-unparsable marker carries no round at all, so it is
        # invisible to the currency check too -- ignoring it here keeps the two
        # readers symmetric, and is what lets a PR with one old truncated
        # comment still publish a monotonic round. A marker that PARSES but
        # whose round will not convert is the asymmetric case, and
        # _marker_round below fails closed on it in both readers.
        _, markers = _scan_body(entry.get("body", "") or "", marker_re, prefix)
        for marker in markers:
            # Fail closed on a round this cannot convert, rather than skipping
            # it. Skipping was the asymmetry that mattered: the publisher
            # ignored an oversized round while the currency check treated it as
            # authoritative, so a replay of the round below it passed. Bounding
            # the field instead just moved the asymmetry to the bound, where
            # the publisher emitted a number its own parser refused.
            highest = max(highest, _marker_round(marker, entry.get("id")))
    nxt = highest + 1
    try:
        # The successor has to survive being written into a marker. At the
        # interpreter's decimal-conversion boundary the predecessor converts
        # and its successor does not, which would publish a number this
        # module's own reader then refuses -- the same publisher/reader
        # disagreement the removed four-digit bound created.
        str(nxt)
    except ValueError:
        raise GateInputError(
            "co-review round numbering is exhausted; correct the comment "
            "claiming the highest round"
        ) from None
    return nxt


def _check_round_currency(selected: dict, candidates) -> None:
    """Fail closed when another marker contradicts the selected one.

    The newest comment by creation instant still governs selection, but a
    delayed publish can land an older round after a newer one: round 1
    APPROVEs head H, round 2 posts CHANGES for H, a late round-1 publish
    arrives, and without this check the revived APPROVE passes the gate with
    round 2's blockers unresolved. A retry of the LATEST round stays benign --
    same round, same verdict -- which is the only case the skill ever claimed
    was harmless.

    The equal-round check exists because the greater-than check alone would
    still let a delayed same-round APPROVE supersede a same-round CHANGES,
    which is the same defect one round index down.

    Only markers that parse are compared. A truncated higher-round marker is
    invisible here, so a delayed lower-round APPROVE can still win in that
    case. That residual is deliberate: failing closed on any unparsable marker
    anywhere on the PR would wedge a PR permanently over one old truncated
    comment, which is a strictly more common and more benign event than the
    replay it would catch.
    """
    selected_round = _marker_round(selected)
    # Bounding a claimed round by the comment count was tried and REVERTED. It
    # let a miscounted round-4 CHANGES be dismissed as noise, so a delayed
    # round-1 APPROVE passed -- trading a fail-closed wedge for a fail-open,
    # which is the wrong direction. It also made the gate non-deterministic:
    # an ignored marker became authoritative once enough comments accumulated
    # to support its number.
    #
    # Collapsing identical markers to their first publication was tried too and
    # reverted: it re-ordered a candidate BEFORE its findings body was
    # validated, so a marker-only copy of an older round passed as a benign
    # retry, and it hid genuinely different reviews that happened to share
    # those fields. There is no collapsing now.
    #
    # An over-claimed round therefore does wedge the PR, deliberately. Recovery
    # is editing or deleting the offending comment, which the error names. A
    # retry of the CURRENT round needs no special handling: it carries the same
    # round and the same verdict, so neither branch below fires.
    for _, _, _, markers, _ in candidates:
        # Iterate the PARSED markers, not one per comment. Skipping a whole
        # comment when it did not carry exactly one marker also hid a comment
        # carrying TWO readable markers, and those were then invisible here
        # while all_markers refused the same history -- so a newest round-1
        # APPROVE passed with two higher-round CHANGES markers sitting on the
        # PR. A truncated comment still has no parsed markers, so the
        # documented residual is unchanged.
        for other in markers:
            if other is selected:
                continue
            other_round = _marker_round(other)
            if other_round > selected_round:
                raise GateInputError(
                    "a later co-review round exists; the newest comment is "
                    "stale (if that round number is a miscount, correct or "
                    "delete that comment)"
                )
            if (
                other_round == selected_round
                and other["verdict"] != selected["verdict"]
            ):
                # One round reaches one verdict, so two verdicts at one round is
                # contradictory evidence and the safe reading is the blocking one.
                #
                # Recovery is simply the next round: the published ordinal comes
                # from next_round_number and always advances, so a fresh round
                # clears this without a pushed commit. An earlier version of this
                # comment claimed the opposite -- that a head keeps its ordinal so
                # a re-review re-contradicts itself -- which was true only while
                # the marker's round came from the floor index. It does not.
                #
                # What keeps a same-head re-review honest is NOT this check: it is
                # that round_index_for_head returns that head's original ordinal so
                # the floor does not move, and that the carried set does not empty.
                # Do not reach for this check to guard that case.
                #
                # Deliberately NOT scoped to a matching base/base_ref. Scoping it
                # that way was tried so a retargeted PR could be re-reviewed at
                # the same head, and it reopened a fail-open: an APPROVE published
                # late against a target the PR has since returned to no longer
                # conflicted with the CHANGES published against the other target
                # in between. A retarget is cleared by the next round's ordinal,
                # which is recoverable; the fail-open was not.
                #
                # Only the verdict is compared. Extending this to sha/base/base_ref
                # was considered and declined: re-posting a round against a new
                # head is bookkeeping sloppiness rather than a fail-open, the
                # dangerous form is already caught by decide()'s sha == head check,
                # and comparing sha here makes two same-round markers on different
                # heads unselectable -- which is exactly how comment ordering is
                # exercised when two comments share a timestamp.
                raise GateInputError(
                    "co-review round has conflicting verdicts; re-run co-review "
                    "-- the next round publishes a later ordinal"
                )


def _marker_round(marker: dict, cid=None) -> int:
    """The marker's round as an int. Fail closed on anything unusable.

    ``cid`` names the offending comment when the caller knows it. The operator
    is told to correct that comment, so an error that cannot name one leaves
    them hand-scanning the thread.
    """
    try:
        return int(marker["round"])
    except (KeyError, TypeError, ValueError):
        where = f" (comment {cid})" if cid is not None else ""
        raise GateInputError(
            f"co-review marker has an unusable round{where}"
        ) from None


def decide(comments, trusted_authors, head_oid, resolved_base, base_ref):
    """('PASS'|'FAIL', reason). Current APPROVE for this head, base, and target."""
    try:
        marker = select_marker(comments, set(trusted_authors))
    except GateInputError as error:
        return ("FAIL", f"invalid comments input (fail closed): {error}")
    if marker is None:
        return ("FAIL", "no trusted co-review marker; run co-review first")
    if marker["verdict"] != "APPROVE":
        return ("FAIL", "latest co-review verdict is not APPROVE; re-run co-review")
    if marker["sha"] != head_oid:
        return ("FAIL", "co-review is stale: reviewed sha != PR head; re-run co-review")
    if marker["base"] != resolved_base:
        return ("FAIL", "co-review base != current target base; re-run co-review")
    if marker["base_ref"] != base_ref:
        return ("FAIL", "co-review target branch changed (retarget); re-run co-review")
    return ("PASS", "co-review APPROVE is current for this head and target")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="pr_ready_gate.py")
    ap.add_argument(
        "--comments", required=True, help="JSON array of {author,created_at,id,body}"
    )
    ap.add_argument("--head", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--base-ref", dest="base_ref", required=True)
    ap.add_argument("--trusted-author", action="append", required=True)
    args = ap.parse_args(argv)
    try:
        with open(args.comments, encoding="utf-8") as handle:
            comments = json.load(handle)
    except (OSError, ValueError):
        print(
            json.dumps(
                {"decision": "FAIL", "reason": "cannot read comments (fail closed)"}
            )
        )
        return 1
    decision, reason = decide(
        comments, set(args.trusted_author), args.head, args.base, args.base_ref
    )
    print(json.dumps({"decision": decision, "reason": reason}))
    return 0 if decision == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
