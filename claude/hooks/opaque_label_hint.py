#!/usr/bin/env python3
"""PreToolUse hook (AskUserQuestion): warn when a prompt uses an unexpanded label.

Scans question, header, and option label/description (not preview) for
short labels (R12), number references (#272), run numbers and decision IDs.
A token is flagged when its first occurrence in the call is neither inside
parentheses nor followed by a definition. Advisory only: prints one
additionalContext line and exits 0. Silent on anything else, including errors.
"""
import json
import re
import sys

PATTERNS = {
    "short label": re.compile(r"\bR\d{1,3}\b"),
    "number ref": re.compile(r"(?<![\w&])#\d+\b"),
    "run number": re.compile(r"\b[Rr]un #?\d+\b"),
    "decision id": re.compile(r"\b[Dd]ecision [0-9a-f]{8,}\b"),
}
MAX_LISTED = 5
ADVICE = (
    "Name each by its substance on first use with the label in parentheses "
    "(Stand-alone messages, ~/.claude/CLAUDE.md); if the owner may not know a "
    "label, restate it in plain words after the answer."
)


def fields(questions):
    """Yield scanned text fields in reading order."""
    for q in questions:
        if not isinstance(q, dict):
            continue
        yield q.get("question")
        yield q.get("header")
        for opt in q.get("options") or []:
            if isinstance(opt, dict):
                yield opt.get("label")
                yield opt.get("description")


def tokens(text):
    """Return (start, end) spans in text; the longer of two overlaps wins."""
    spans = [m.span() for rx in PATTERNS.values() for m in rx.finditer(text)]
    spans.sort(key=lambda s: s[0] - s[1])
    kept = []
    for s in spans:
        if all(s[1] <= k[0] or s[0] >= k[1] for k in kept):
            kept.append(s)
    return sorted(kept)


def expanded(text, start, end):
    if text.count("(", 0, start) > text.count(")", 0, start):
        return True
    rest = text[end:]
    after = rest.lstrip(" ")
    return rest.startswith(": ") or after.startswith(("(", '"', "“", "—", "-- "))


def flagged(questions):
    seen = set()
    out = []
    for text in fields(questions):
        if not isinstance(text, str):
            continue
        for start, end in tokens(text):
            token = " ".join(text[start:end].split())
            key = token.casefold()
            if key in seen:
                continue
            seen.add(key)
            if not expanded(text, start, end):
                out.append(token)
    return out


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name") != "AskUserQuestion":
            return
        questions = data["tool_input"]["questions"]
        found = flagged(questions)
        if not found:
            return
        listed = ", ".join(found[:MAX_LISTED])
        if len(found) > MAX_LISTED:
            listed += f" and {len(found) - MAX_LISTED} more"
        line = f"[WARNING] opaque label in AskUserQuestion: {listed}. {ADVICE}"
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "additionalContext": line}}))
    except Exception:
        pass


if __name__ == "__main__":
    main()
    sys.exit(0)
