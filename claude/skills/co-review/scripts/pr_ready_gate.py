"""Parse co-review markers and decide PR-ready currency. Pure logic + thin CLI."""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone

MARKER_RE = re.compile(
    r"^<!-- co-review: sha=(?P<sha>[0-9a-f]{40}) base=(?P<base>[0-9a-f]{40}) "
    r"base_ref=(?P<base_ref>\S+) verdict=(?P<verdict>APPROVE|CHANGES) "
    r"round=(?P<round>\d+) -->$"
)
_FENCE_RE = re.compile(r"^([`~])\1{2,}")


class GateInputError(Exception):
    """The comments payload is not the expected shape."""


def _markers_in_body(body: str) -> list[dict]:
    """Every valid marker on an unindented, unquoted, unfenced top-level line."""
    found: list[dict] = []
    fence: tuple[str, int] | None = None
    for raw in body.splitlines():
        stripped = raw.strip()
        fence_hit = _FENCE_RE.match(stripped)
        if fence is not None:
            if (
                fence_hit
                and fence_hit.group(1) == fence[0]
                and len(fence_hit.group(0)) >= fence[1]
            ):
                fence = None
            continue
        if fence_hit:
            fence = (fence_hit.group(1), len(fence_hit.group(0)))
            continue
        if raw.lstrip().startswith(">"):
            continue
        if raw[:1] == "\t" or (len(raw) - len(raw.lstrip(" "))) >= 4:
            continue  # indented code block
        hit = MARKER_RE.match(stripped)
        if hit:
            found.append(hit.groupdict())
    return found


def _parse_instant(value) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    text = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def select_marker(comments, trusted_authors: set[str]) -> dict | None:
    """Latest trusted single marker by creation instant, or None. Fail-closed."""
    if not isinstance(comments, list):
        raise GateInputError("comments must be a JSON array")
    candidates = []
    for entry in comments:
        if not isinstance(entry, dict):
            raise GateInputError("each comment must be an object")
        if entry.get("author") not in trusted_authors:
            continue
        markers = _markers_in_body(entry.get("body", "") or "")
        if len(markers) != 1:
            continue  # none, or ambiguous multiple markers in one comment
        instant = _parse_instant(entry.get("created_at"))
        cid = entry.get("id")
        if instant is None or not isinstance(cid, int):
            continue  # fail closed: no defaulting of ordering metadata
        candidates.append((instant, cid, markers[0]))
    if not candidates:
        return None
    candidates.sort(key=lambda item: (item[0], item[1]))
    return candidates[-1][2]


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
