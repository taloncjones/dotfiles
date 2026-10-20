"""Classify a frozen co-review diff as a light (prose) or full (code) change."""

from __future__ import annotations

import re

GATE_PREFIXES = (
    "claude/skills/co-review/",
    "codex/skills/co-review/",
    "claude/skills/ship/",
    "claude/skills/review-change/",
    "codex/skills/review-change/",
)
LESSONS_PATH = "claude/rules/personal/agent-lessons.md"
_HEADER = "diff --git "
_HUNK_HEADER = re.compile(r"^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@")


def paths_from_diff(text: str) -> list[str] | None:
    """Changed paths from symmetric `diff --git a/P b/P` headers, or None."""
    paths: list[str] = []
    for line in text.split("\n"):
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
    """Return "lessons" for the lessons file alone, "light" when every path is
    prose outside the gate skills, else "full"."""
    if paths == [LESSONS_PATH]:
        return "lessons"
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
    binary = submodule = new_file = deleted_file = mode_change = False
    in_hunk = malformed = False
    section_hunks = section_changes = file_headers = 0
    old_hdr = new_hdr = sec_new = sec_del = False
    old_left = new_left = 0
    section = -1
    for line in text.removesuffix("\n").split("\n") + [_HEADER]:
        if line.startswith(_HEADER) or line.startswith("@@"):
            # Each hunk body must match the counts in its own @@ header.
            if in_hunk and (old_left, new_left) != (0, 0):
                malformed = True
        if line.startswith(_HEADER):
            # A hunk section with no +/- line is not a plain unified diff.
            malformed = malformed or (section_hunks > 0 and section_changes == 0)
            # Git emits hunkless sections only for renames (asymmetric paths,
            # rejected above), mode changes, empty adds and binary markers.
            malformed = malformed or (section >= 0 and section_hunks == 0)
            malformed = malformed or (section_hunks > 0 and not (old_hdr and new_hdr))
            section += 1
            in_hunk = False
            section_hunks = section_changes = file_headers = 0
            old_hdr = new_hdr = sec_new = sec_del = False
        elif line.startswith("@@"):
            counts = _HUNK_HEADER.match(line)
            in_hunk = counts is not None
            malformed = malformed or counts is None
            old_left = int(counts.group(1) or 1) if counts else 0
            new_left = int(counts.group(2) or 1) if counts else 0
            section_hunks += 1
        elif not in_hunk:
            if line.startswith(("Binary files ", "GIT binary patch")):
                binary = True
            elif line.startswith("new file mode "):
                new_file = sec_new = True
            elif line.startswith("deleted file mode "):
                deleted_file = sec_del = True
            elif line.startswith(("--- ", "+++ ")) and section_hunks == 0:
                file_headers += 1
                malformed = malformed or file_headers > 2
                old_side = line.startswith("--- ")
                target = line[4:].split("\t")[0]
                expected = ("a/" if old_side else "b/") + paths[section] if 0 <= section < len(paths) else None
                null_ok = sec_new if old_side else sec_del
                malformed = malformed or target != expected and not (target == "/dev/null" and null_ok)
                if old_side:
                    old_hdr = True
                else:
                    new_hdr = True
            elif line.startswith(("+", "-")):
                malformed = True
            if line.startswith(_MODE_LINES) and line.endswith(" 160000"):
                submodule = True
            elif line.startswith(_MODE_LINES[1:]):
                mode_change = True
        elif line.startswith("+"):
            added += 1
            new_left -= 1
            section_changes += 1
            submodule = submodule or line.startswith("+Subproject commit ")
        elif line.startswith("-"):
            removed += 1
            old_left -= 1
            section_changes += 1
        elif line.startswith(" ") or (line == "" and (old_left, new_left) != (0, 0)):
            old_left -= 1
            new_left -= 1
        elif line and line[0] != "\\":
            malformed = True
        if old_left < 0 or new_left < 0:
            malformed = True
    classes = {path_class(path) for path in paths}
    if submodule:
        classes.add("submodule")
    return {"files": len(paths), "added": added, "removed": removed,
            "paths": paths, "classes": sorted(classes), "binary": binary,
            "new_files": new_file, "deleted_files": deleted_file,
            "mode_change": mode_change,
            "malformed": malformed}


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
    if stats["malformed"]:
        reasons.append("delta diff is not a plain unified diff")
    reasons.extend(f"delta touches a {name} path" for name in BLOCKING_CLASSES
                   if name in stats["classes"])
    return {"eligible": not reasons, "reasons": reasons}


# Small tier. Config may tune the caps up to the ceiling (the delta defaults).
SMALL_DEFAULTS = {"max_files": 3, "max_lines": 40, "sensitive_paths": []}
SMALL_CEILING = {"max_files": 5, "max_lines": 150}
INSTRUCTION_FILES = ("SKILL.md", "AGENTS.md", "CLAUDE.md")


def small_caps_error(small: object) -> str | None:
    """Why a small-caps block is unusable, or None when it is valid."""
    if not isinstance(small, dict):
        return "small caps must be an object"
    for key, ceiling in SMALL_CEILING.items():
        value = small.get(key)
        if not isinstance(value, int) or isinstance(value, bool) or not 0 < value <= ceiling:
            return f"{key} must be an integer from 1 to {ceiling}"
    prefixes = small.get("sensitive_paths")
    if not isinstance(prefixes, list) or not all(
            isinstance(p, str) and p and not any(c.isspace() for c in p) for p in prefixes):
        return "sensitive_paths must be a list of non-empty strings without whitespace"
    return None


def small_class(stats: dict | None, small: dict) -> dict:
    """Whether a diff qualifies for the small tier, with every reason it does not."""
    if stats is None:
        return {"eligible": False, "reasons": ["diff is empty or unparsable"]}
    reasons = []
    if stats["files"] > small["max_files"]:
        reasons.append(f"{stats['files']} files exceed max_files {small['max_files']}")
    lines = stats["added"] + stats["removed"]
    if lines > small["max_lines"]:
        reasons.append(f"{lines} changed lines exceed max_lines {small['max_lines']}")
    if stats["new_files"] or stats["deleted_files"]:
        reasons.append("diff adds or deletes a file")
    if stats["binary"]:
        reasons.append("diff has a binary change")
    if stats["mode_change"]:
        reasons.append("diff changes a file mode")
    if stats["malformed"]:
        reasons.append("diff is not a plain unified diff")
    reasons.extend(f"diff touches a {name} path" for name in BLOCKING_CLASSES
                   if name in stats["classes"])
    for path in stats["paths"]:
        parts = path.split("/")
        if "skills" in parts or parts[-1] in INSTRUCTION_FILES:
            reasons.append(f"{path} is skill or agent-instruction text")
        if any("security" in part.lower() for part in parts):
            reasons.append(f"{path} is on a security path")
        if path.startswith(tuple(small["sensitive_paths"])):
            reasons.append(f"{path} is on a configured sensitive path")
    if "tests" not in stats["classes"]:
        reasons.append("diff touches no test")
    return {"eligible": not reasons, "reasons": reasons}


def tier_of(text: str, small: dict | None = None) -> str:
    """The tier of a frozen diff: lessons, light, small or full, in that precedence."""
    stats = delta_stats(text)
    if stats is None:
        return "full"
    if stats["malformed"]:
        return "full"
    tier = classify(stats["paths"])
    if tier != "full":
        return tier
    caps = small if small is not None else SMALL_DEFAULTS
    if small_caps_error(caps) is None and small_class(stats, caps)["eligible"]:
        return "small"
    return "full"
