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


# Delta tier (spec R14). A path takes the first class that matches, in the
# order path_class() tests them; BLOCKING_CLASSES force a full round.
CI_PREFIXES = (".github/workflows/", ".github/actions/", ".circleci/", ".buildkite/")
CI_FILES = (".gitlab-ci.yml", "Jenkinsfile", "azure-pipelines.yml")
AUTH_WORDS = ("auth", "permission", "credential", "secret", "token")
HOOK_DIRS = ("hooks", ".githooks")
BLOCKING_CLASSES = ("gate", "ci", "auth", "submodule")
_MODE_LINES = ("index ", "new file mode ", "deleted file mode ", "old mode ", "new mode ")


def path_class(path: str) -> str:
    """The delta path class of one changed path."""
    parts = path.split("/")
    name = parts[-1]
    if path.startswith(GATE_PREFIXES):
        return "gate"
    if path.startswith(CI_PREFIXES) or path in CI_FILES:
        return "ci"
    if name == ".gitmodules":
        return "submodule"
    if (
        any(part in HOOK_DIRS for part in parts[:-1])
        or name == "CODEOWNERS"
        or (name.startswith("settings") and name.endswith((".json", ".json.tmpl")))
        or any(word in part.lower() for part in parts for word in AUTH_WORDS)
    ):
        return "auth"
    stem = name.rsplit(".", 1)[0]
    if (
        any(part in ("test", "tests") for part in parts[:-1])
        or name.startswith("test_")
        or ".test." in name
        or stem.endswith("_test")
    ):
        return "tests"
    if name.endswith(".md") or path.startswith(("docs/", ".todos/")):
        return "docs"
    return "source"


def delta_stats(text: str) -> dict | None:
    """File and line counts plus path classes of a `git diff`, or None if unparsable."""
    paths = paths_from_diff(text)
    if paths is None:
        return None
    added = removed = 0
    binary = submodule = False
    in_hunk = False
    for line in text.split("\n"):
        if line.startswith(_HEADER):
            in_hunk = False
        elif line.startswith("@@"):
            in_hunk = True
        elif not in_hunk:
            if line.startswith(("Binary files ", "GIT binary patch")):
                binary = True
            elif line.startswith(_MODE_LINES) and line.endswith(" 160000"):
                submodule = True
        elif line.startswith("+"):
            added += 1
            submodule = submodule or line.startswith("+Subproject commit ")
        elif line.startswith("-"):
            removed += 1
    classes = {path_class(path) for path in paths}
    if submodule:
        classes.add("submodule")
    return {"files": len(paths), "added": added, "removed": removed,
            "paths": paths, "classes": sorted(classes), "binary": binary}


def delta_class(stats: dict | None, max_files: int, max_lines: int) -> dict:
    """Whether a delta qualifies for the delta tier, with every reason it does not."""
    if stats is None:
        return {"eligible": False, "reasons": ["delta diff is empty or unparsable"]}
    reasons = []
    if stats["files"] > max_files:
        reasons.append(f"{stats['files']} files exceed max_files {max_files}")
    lines = stats["added"] + stats["removed"]
    if lines > max_lines:
        reasons.append(f"{lines} changed lines exceed max_lines {max_lines}")
    if stats["binary"]:
        reasons.append("delta has a binary change")
    reasons.extend(f"delta touches a {name} path" for name in BLOCKING_CLASSES
                   if name in stats["classes"])
    return {"eligible": not reasons, "reasons": reasons}
