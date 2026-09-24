"""Classify a frozen co-review diff as a light (prose) or full (code) change."""

from __future__ import annotations

GATE_PREFIXES = (
    "claude/skills/co-review/",
    "codex/skills/co-review/",
    "claude/skills/ship/",
    "claude/skills/review-change/",
    "codex/skills/review-change/",
)
_HEADER = "diff --git "


def paths_from_diff(text: str) -> list[str] | None:
    """Changed paths from symmetric `diff --git a/P b/P` headers, or None."""
    paths: list[str] = []
    for line in text.splitlines():
        if not line.startswith(_HEADER):
            continue
        rest = line[len(_HEADER):]
        if not rest.startswith("a/"):
            return None
        body = rest[2:]
        if (len(body) - 3) % 2:
            return None
        half = (len(body) - 3) // 2
        path = body[:half]
        if not path or body[half:] != f" b/{path}":
            return None
        paths.append(path)
    return paths or None


def classify(paths: list[str]) -> str:
    """Return "light" only when every path is prose outside the gate skills."""
    if not paths:
        return "full"
    for path in paths:
        if path.startswith(GATE_PREFIXES):
            return "full"
        if not (path.endswith(".md") or path.startswith(".todos/")):
            return "full"
    return "light"
