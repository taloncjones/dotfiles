"""Validate frozen review diff and CI evidence."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path


_MARKER_RE = re.compile(r"\b(?:TEMP|TODO|FIXME|XXX|HACK|revert-before-merge)\b", re.I)
_HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")
_DETECTOR_LITERAL_FILE = "claude/skills/co-review/scripts/preconditions.py"
_DETECTOR_LITERAL_TEXT = f'_MARKER_RE = re.compile(r"{_MARKER_RE.pattern}", re.I)'
_MARKER_EXCEPTION_KINDS = {
    "fixture_literal",
    "documentation_example",
    "detector_literal",
}


def _artifact(entry: object, root: Path, label: str) -> tuple[Path | None, list[str]]:
    if not isinstance(entry, dict):
        return None, [f"{label} artifact is missing"]
    name, expected = entry.get("artifact"), entry.get("sha256")
    if not isinstance(name, str) or not isinstance(expected, str):
        return None, [f"{label} artifact metadata is invalid"]
    try:
        path = (root / name).resolve()
        path.relative_to(root.resolve())
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
    except (OSError, ValueError):
        return None, [f"{label} artifact cannot be read"]
    if actual != expected:
        return None, [f"{label} artifact digest does not match"]
    return path, []


def _ci_reasons(payload: object, no_ci: object) -> list[str]:
    if not isinstance(payload, dict):
        return ["CI payload is invalid"]
    head = payload.get("head")
    if not isinstance(head, str) or not head:
        return ["CI payload head is missing"]
    if "check_runs" not in payload or "status_contexts" not in payload:
        return ["CI payload has missing check collections"]
    runs, contexts = payload["check_runs"], payload["status_contexts"]
    if not isinstance(runs, list) or not isinstance(contexts, list):
        return ["CI payload has invalid checks"]
    if not runs and not contexts:
        if (
            isinstance(no_ci, dict)
            and isinstance(no_ci.get("evidence"), str)
            and no_ci["evidence"].strip()
        ):
            return []
        return ["CI evidence is missing"]
    reasons: list[str] = []
    for run in runs:
        if not isinstance(run, dict):
            reasons.append("CI check run is invalid")
            continue
        status = run.get("status")
        conclusion = run.get("conclusion")
        if "head_sha" in run and run["head_sha"] != head:
            reasons.append("CI check run head does not match payload")
        if status != "COMPLETED":
            reasons.append("CI check run is pending")
        elif conclusion != "SUCCESS":
            reasons.append(f"CI check run conclusion is {conclusion!r}")
    for context in contexts:
        if not isinstance(context, dict):
            reasons.append("CI status context is invalid")
            continue
        if "head_sha" in context and context["head_sha"] != head:
            reasons.append("CI status context head does not match payload")
        if context.get("state") != "SUCCESS":
            reasons.append(f"CI status context state is {context.get('state')!r}")
    return reasons


def _marker_reasons(diff: str, exceptions: object, artifact_root: Path) -> list[str]:
    if not diff:
        return []
    if not diff.startswith("diff --git "):
        return ["frozen diff is malformed"]
    try:
        parsed = subprocess.run(
            ["git", "apply", "--numstat", "-z"],
            input=diff,
            text=True,
            capture_output=True,
            check=False,
            cwd=artifact_root,
        )
    except OSError:
        return ["frozen diff cannot be parsed"]
    if parsed.returncode != 0:
        return ["frozen diff is malformed"]
    if exceptions is None:
        exceptions = []
    if not isinstance(exceptions, list):
        return ["marker exceptions are invalid"]
    allowed = set()
    for item in exceptions:
        if (
            not isinstance(item, dict)
            or not all(
                isinstance(item.get(key), str) and item[key].strip()
                for key in ("file", "text", "evidence", "reason")
            )
            or not isinstance(item.get("line"), int)
            or item.get("kind") not in _MARKER_EXCEPTION_KINDS
            or (
                item.get("kind") == "detector_literal"
                and (
                    item["file"] != _DETECTOR_LITERAL_FILE
                    or item["text"] != _DETECTOR_LITERAL_TEXT
                )
            )
        ):
            return ["marker exception is invalid"]
        allowed.add((item["file"], item["line"], item["text"]))
    file_name: str | None = None
    new_line: int | None = None
    reasons: list[str] = []
    for raw in diff.split("\n"):
        if raw.startswith("diff --git "):
            file_name = None
            new_line = None
            continue
        if raw.startswith("--- "):
            continue
        if raw.startswith("+++ ") and new_line is None:
            target = raw[4:].split("\t", 1)[0]
            file_name = target[2:] if target.startswith("b/") else target
            continue
        hunk = _HUNK_RE.match(raw)
        if hunk:
            new_line = int(hunk.group(1))
            continue
        if raw.startswith("+"):
            if file_name is None or new_line is None:
                return ["frozen diff is malformed"]
            text = raw[1:]
            matches = list(_MARKER_RE.finditer(text))
            if matches:
                key = (file_name, new_line, text)
                if key not in allowed:
                    reasons.append(
                        f"provisional marker in {file_name}:{new_line}: {text}"
                    )
            new_line += 1
        elif raw.startswith(" ") and new_line is not None:
            new_line += 1
    return reasons


def evaluate(preconditions: object, artifact_root: Path) -> dict:
    """Return an approval verdict for independently pinned source artifacts."""
    reasons: list[str] = []
    if not isinstance(preconditions, dict):
        return {"approve_allowed": False, "reasons": ["preconditions are missing"]}
    for field in ("head", "tree"):
        if not isinstance(preconditions.get(field), str) or not preconditions[field]:
            reasons.append(f"preconditions {field} is invalid")
    diff_path, diff_errors = _artifact(
        preconditions.get("diff"), artifact_root, "frozen diff"
    )
    ci_path, ci_errors = _artifact(preconditions.get("ci"), artifact_root, "CI")
    reasons.extend(diff_errors + ci_errors)
    if diff_path is not None:
        try:
            reasons.extend(
                _marker_reasons(
                    diff_path.read_bytes().decode("utf-8"),
                    preconditions.get("marker_exceptions"),
                    artifact_root,
                )
            )
        except (OSError, UnicodeError):
            reasons.append("frozen diff cannot be read")
    if ci_path is not None:
        try:
            payload = json.loads(ci_path.read_text(encoding="utf-8"))
            if isinstance(payload, dict) and payload.get("head") != preconditions.get(
                "head"
            ):
                reasons.append("CI payload head does not match preconditions")
            reasons.extend(_ci_reasons(payload, preconditions.get("no_ci")))
        except (OSError, UnicodeError, ValueError):
            reasons.append("CI payload cannot be read")
    return {"approve_allowed": not reasons, "reasons": reasons}
