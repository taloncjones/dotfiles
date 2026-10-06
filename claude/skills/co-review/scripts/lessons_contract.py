"""Check claude/rules/personal/agent-lessons.md against its header contract."""

from __future__ import annotations

import re

MAX_LINES = 70
MAX_RULES = 30
MAX_COLUMNS = 80
RULES_HEADING = "## Rules"
_RULE_START = re.compile(r"^- \(\d{4}-(0[1-9]|1[0-2])\) \S")
_CONTINUATION = re.compile(r"^  \S")


def check(text: str) -> list[str]:
    """One reason per contract violation; empty when the file conforms."""
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    reasons = []
    if len(lines) > MAX_LINES:
        reasons.append(f"file has {len(lines)} lines, over {MAX_LINES}")
    for number, line in enumerate(lines, 1):
        if len(line) > MAX_COLUMNS:
            reasons.append(f"line {number} is {len(line)} columns, over {MAX_COLUMNS}")
    headings = [number for number, line in enumerate(lines, 1) if line == RULES_HEADING]
    if len(headings) != 1:
        reasons.append(f"expected one {RULES_HEADING!r} line, found {len(headings)}")
        return reasons
    start = headings[0]
    for number, line in enumerate(lines[: start - 1], 1):
        if line.startswith("- ("):
            reasons.append(f"line {number} is a rule before {RULES_HEADING!r}")
    rules = 0
    span = 0  # physical lines of the current entry; 0 between entries
    for number, line in enumerate(lines[start:], start + 1):
        if not line.strip():
            span = 0
        elif _RULE_START.match(line):
            rules += 1
            span = 1
        elif span and _CONTINUATION.match(line):
            span += 1
            if span == 3:
                reasons.append(f"line {number} makes its entry longer than two lines")
        else:
            reasons.append(f"line {number} is not a rule entry")
            span = 0
    if rules > MAX_RULES:
        reasons.append(f"file has {rules} rules, over {MAX_RULES}")
    return reasons
