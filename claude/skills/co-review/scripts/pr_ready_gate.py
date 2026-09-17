"""Parse co-review markers and decide PR-ready currency. Pure logic + thin CLI."""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone

MARKER_RE = re.compile(
    r"^<!-- co-review: sha=(?P<sha>[0-9a-f]{40}) base=(?P<base>[0-9a-f]{40}) "
    r"base_ref=(?P<base_ref>\S+) verdict=(?P<verdict>APPROVE|CHANGES) "
    r"round=(?P<round>\d+)(?: target_tip=(?P<target_tip>[0-9a-f]{40}))? -->$"
)
# target_tip records the target-branch tip the review compared against. It is
# for the reader: decide() never compares it, so an approval does not expire
# when the target moves. A target change that breaks the PR is CI's job.
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
    return markers[0]


def decide(comments, trusted_authors, head_oid, resolved_base, base_ref):
    """Compatibility tuple: comment history no longer grants readiness."""
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
    return ("FAIL", "comment history cannot grant readiness; run current co-review")


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
