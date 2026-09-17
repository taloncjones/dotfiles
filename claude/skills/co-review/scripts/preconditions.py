#!/usr/bin/env python3
"""Deterministic co-review preconditions.

These run before any reviewer seat, cost nothing, and gate APPROVE only. A
failure never stops the finders: reviewing red or messy code is legitimate and
often the fastest way to learn why it is red. Approving it never is.

Both checks exist because a model is the wrong tool for them. An unreverted
`TEMP` marker and a red check on the reviewed head are facts, not judgments,
and paying a reviewer to notice a fact it can miss is how a gate gets
expensive and unreliable at the same time.

No network and no git calls happen here. The caller supplies the `gh` payload
and the diff text, which keeps every branch below reachable from a test.
"""

from __future__ import annotations

import argparse
import json
import re
import sys

# A check that ran and reported one of these did not fail. NEUTRAL and SKIPPED
# are conclusions GitHub gives a check that opted out, not a passing test.
GREEN_CONCLUSIONS = frozenset({"SUCCESS", "SKIPPED", "NEUTRAL"})

# Uppercase and word-bounded on purpose: real provisional markers are shouted.
# Matching case-insensitively would trip on "temperature" and "attempt", and
# dropping the boundary would trip on "TEMPLATE".
MARKER_TOKENS = re.compile(r"\b(TEMP|TODO|FIXME|XXX|HACK)\b")
MARKER_PHRASE = re.compile(r"revert before merge", re.IGNORECASE)

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def _check(name: str, status: str, detail: str) -> dict:
    return {"name": name, "status": status, "detail": detail}


def check_ci(payload: dict | None, head: str) -> dict:
    """Is CI green for exactly this head?

    A green run on an older commit is the failure this check exists to catch,
    so the payload's own head is compared to the reviewed head before any
    conclusion is read.
    """
    name = "ci_green_for_head"
    if not payload:
        return _check(name, "SKIPPED", "no CI payload supplied")

    reported_head = payload.get("headRefOid")
    if reported_head != head:
        return _check(
            name,
            "FAIL",
            f"checks are for a different head ({reported_head!r}, not {head!r})",
        )

    rollup = payload.get("statusCheckRollup") or []
    if not rollup:
        # A repo with no CI must not be permanently unapprovable, but the gap
        # belongs on the round comment rather than silently counting as green.
        return _check(name, "SKIPPED", "no checks reported for this head")

    bad = [
        entry.get("name") or "<unnamed>"
        for entry in rollup
        if (entry.get("conclusion") or "") not in GREEN_CONCLUSIONS
    ]
    if bad:
        return _check(name, "FAIL", "not green: " + ", ".join(sorted(bad)))
    return _check(name, "PASS", f"{len(rollup)} checks green for {head[:9]}")


def _added_lines(diff_text: str):
    """Yield (path, new_file_line_number, text) for added lines only.

    Added lines only, so a marker that was already in a touched file does not
    block, and a marker being deleted does not either.
    """
    path = "<unknown>"
    lineno = 0
    for raw in diff_text.splitlines():
        if raw.startswith("+++ "):
            target = raw[4:].strip()
            path = target[2:] if target.startswith(("a/", "b/")) else target
            continue
        if raw.startswith("--- ") or raw.startswith("diff --git "):
            continue
        hunk = HUNK.match(raw)
        if hunk:
            lineno = int(hunk.group(1))
            continue
        if raw.startswith("+"):
            yield path, lineno, raw[1:]
            lineno += 1
        elif raw.startswith("-"):
            continue  # removed: consumes no line in the new file
        else:
            lineno += 1  # context


def check_markers(diff_text: str) -> dict:
    """Did this change introduce a provisional marker?"""
    name = "no_provisional_markers"
    if not diff_text.strip():
        # Never a pass: an empty diff means the freeze produced nothing, which
        # the skill already treats as an incomplete review rather than a clean
        # one.
        return _check(name, "FAIL", "diff is empty; nothing was frozen")

    hits = []
    for path, lineno, text in _added_lines(diff_text):
        found = {match.group(1) for match in MARKER_TOKENS.finditer(text)}
        if MARKER_PHRASE.search(text):
            found.add("revert before merge")
        for token in sorted(found):
            hits.append(f"{path}:{lineno} {token}")

    if hits:
        return _check(name, "FAIL", "; ".join(hits))
    return _check(name, "PASS", "no provisional markers in added lines")


def evaluate(payload: dict | None, head: str, diff_text: str) -> dict:
    """Run every check and say whether an APPROVE is permitted.

    Every check is reported even when an earlier one fails, so the round
    comment carries the whole picture instead of the first problem found.
    """
    checks = [check_ci(payload, head), check_markers(diff_text)]
    allowed = not any(check["status"] == "FAIL" for check in checks)
    return {"approve_allowed": allowed, "checks": checks}


def _fail_closed(detail: str) -> int:
    print(
        json.dumps(
            {
                "approve_allowed": False,
                "checks": [_check("inputs", "FAIL", detail)],
            }
        )
    )
    return 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="preconditions.py")
    ap.add_argument("--head", required=True, help="the reviewed committed head")
    ap.add_argument(
        "--diff-file",
        dest="diff_file",
        required=True,
        help="unified diff of the frozen change",
    )
    ap.add_argument(
        "--checks",
        help="JSON from: gh pr view <n> --json headRefOid,statusCheckRollup",
    )
    args = ap.parse_args(argv)

    try:
        with open(args.diff_file, encoding="utf-8") as handle:
            diff_text = handle.read()
    except OSError:
        return _fail_closed("cannot read the diff file (fail closed)")

    payload = None
    if args.checks:
        try:
            with open(args.checks, encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, ValueError):
            return _fail_closed("cannot read the CI payload (fail closed)")

    result = evaluate(payload, args.head, diff_text)
    print(json.dumps(result))
    return 0 if result["approve_allowed"] else 1


if __name__ == "__main__":
    sys.exit(main())
