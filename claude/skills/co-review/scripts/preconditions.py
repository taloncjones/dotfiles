"""Validate frozen review diff and CI evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


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
        elif conclusion not in ("SUCCESS", "SKIPPED"):
            # path-filtered jobs report COMPLETED/SKIPPED, not a failure
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
