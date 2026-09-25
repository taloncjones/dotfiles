"""Evaluate a structured, current-session co-review report."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path


_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
LIGHT_SEATS = ("codex", "verifier")
FULL_SEATS = ("claude", "codex", "breaker", "verifier")
_TIER_SEATS = {"light": LIGHT_SEATS, "full": FULL_SEATS}
_CODEX_SEATS = {"light": ("codex",), "full": ("codex", "breaker")}
_SUBSTITUTE_REASONS = ("quota", "auth", "unavailable")
_FAILED_CODEX_STATUSES = ("error", "unparseable")
_AXES = (
    "ownership_authority",
    "dependency_boundaries",
    "contract_coherence",
    "state_effects",
    "lifecycle_operations",
    "demonstrability_constraints",
)
_CHECKLIST = (
    "quoting_separators",
    "symlinks",
    "content_filters",
    "hostile_git_config",
    "signals_toctou",
    "temp_dir_lifecycle",
    "fail_open_exits",
    "ignored_untracked_overwrites",
    "fetch_ref_races",
    "replayable_file_authority",
    "resume_retry_revalidation",
    "writer_reader_parity",
    "functional_behavior",
    "snapshot_integrity",
    "preconditions_ci",
    "threat_model",
)
_SEVERITIES = {"critical", "high", "major", "minor", "low", "nit", "advisory"}
_MATERIAL = {"critical", "high", "major"}


def _load_sibling(name: str):
    spec = importlib.util.spec_from_file_location(
        f"co_review_{name}", Path(__file__).with_name(f"{name}.py")
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _load_preconditions():
    return _load_sibling("preconditions")


def _load_change_class():
    return _load_sibling("change_class")


def _nonempty(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _sha(value: object) -> bool:
    return isinstance(value, str) and bool(_SHA_RE.fullmatch(value))


def _artifact_ok(entry: object, root: Path, name: str, reasons: list[str]) -> None:
    if not isinstance(entry, dict):
        reasons.append(f"seat {name} is invalid")
        return
    if entry.get("status") != "complete":
        reasons.append(f"seat {name} is not complete")
    for field in ("artifact", "sha256", "runtime", "model", "effort"):
        if not _nonempty(entry.get(field)):
            reasons.append(f"seat {name} {field} is invalid")
    artifact, expected = entry.get("artifact"), entry.get("sha256")
    if not isinstance(artifact, str) or not isinstance(expected, str):
        return
    try:
        path = (root / artifact).resolve()
        path.relative_to(root.resolve())
        content = path.read_bytes()
    except (OSError, ValueError):
        reasons.append(f"seat {name} artifact cannot be read")
        return
    if not content.strip():
        reasons.append(f"seat {name} artifact is empty")
    if hashlib.sha256(content).hexdigest() != expected:
        reasons.append(f"seat {name} artifact digest does not match")


def _substitute_cause(seat: dict, root: Path) -> tuple[str | None, Path | None]:
    """Return (cause, None) for spec rules a-k, or (None, resolved_path) when valid."""
    if seat.get("runtime") != "claude":
        return "seat runtime is not claude", None
    record = seat.get("codex_substitute")
    if not isinstance(record, dict) or set(record) != {"reason", "attempt"}:
        return "record keys must be reason and attempt", None
    if record["reason"] not in _SUBSTITUTE_REASONS:
        return "reason is not quota, auth or unavailable", None
    attempt = record["attempt"]
    if (
        not isinstance(attempt, dict)
        or set(attempt) != {"artifact", "sha256"}
        or not _nonempty(attempt.get("artifact"))
        or not _nonempty(attempt.get("sha256"))
    ):
        return "attempt keys must be artifact and sha256", None
    resolved, errors = _load_preconditions()._artifact(attempt, root, "attempt")
    if errors:
        return errors[0], None
    try:
        payload = json.loads(resolved.read_bytes().decode("utf-8"))
    except (OSError, ValueError):
        return "attempt is not a JSON object", None
    if not isinstance(payload, dict):
        return "attempt is not a JSON object", None
    if payload.get("runtime") != "codex":
        return "attempt runtime is not codex", None
    if payload.get("status") not in _FAILED_CODEX_STATUSES:
        return "attempt status is not error or unparseable", None
    if payload.get("result") is not None:
        return "attempt produced a review result", None
    errors_field = payload.get("errors")
    if not isinstance(errors_field, list) or not any(
        isinstance(item, str) and item.strip() for item in errors_field
    ):
        return "attempt errors are empty", None
    return None, resolved


def _substitutes(
    tier: str, seats: dict, root: Path, reasons: list[str], visible: list[str]
) -> set[str]:
    """Validate codex_substitute records for the tier's seats; return substituted names."""
    codex_routed = set(_CODEX_SEATS[tier])
    substituted: set[str] = set()
    seen: dict[tuple[int, int], str] = {}
    for name in _TIER_SEATS[tier]:
        seat = seats.get(name)
        if not isinstance(seat, dict):
            continue
        has_record = "codex_substitute" in seat
        if name not in codex_routed:
            if has_record:
                reasons.append(f"seat {name} cannot take a codex_substitute")
            continue
        if not has_record:
            if seat.get("runtime") == "claude":
                reasons.append(f"seat {name} ran on claude without a codex_substitute")
            continue
        cause, resolved = _substitute_cause(seat, root)
        if cause is not None:
            reasons.append(f"seat {name} codex_substitute is invalid: {cause}")
            continue
        key = (resolved.stat().st_dev, resolved.stat().st_ino)
        if key in seen:
            reasons.append(
                f"seat {name} codex_substitute is invalid: "
                f"attempt is shared with seat {seen[key]}"
            )
            continue
        seen[key] = name
        record = seat["codex_substitute"]
        visible.append(
            f"seat {name} ran on claude after a failed codex attempt "
            f"({record['reason']}): {record['attempt']['artifact']} "
            f"sha256={record['attempt']['sha256']}"
        )
        substituted.add(name)
    return substituted


def _light_diff_ok(preconditions: object, root: Path) -> bool:
    """True when the digest-bound frozen diff still classifies as light."""
    entry = preconditions.get("diff") if isinstance(preconditions, dict) else None
    if not isinstance(entry, dict):
        return False
    try:
        path = (root / entry["artifact"]).resolve()
        path.relative_to(root.resolve())
        content = path.read_bytes()
    except (KeyError, TypeError, OSError, ValueError):
        return False
    if hashlib.sha256(content).hexdigest() != entry.get("sha256"):
        return False
    change_class = _load_change_class()
    paths = change_class.paths_from_diff(content.decode("utf-8", "replace"))
    return paths is not None and change_class.classify(paths) == "light"


def _coverage(report: dict, reasons: list[str], visible: list[str]) -> None:
    coverage = report.get("coverage")
    if not isinstance(coverage, dict):
        reasons.append("coverage is missing")
        return
    for group, required in (("architecture", _AXES), ("checklist", _CHECKLIST)):
        entries = coverage.get(group)
        if not isinstance(entries, dict) or set(entries) != set(required):
            reasons.append(f"coverage {group} is incomplete")
            continue
        for label, value in entries.items():
            if _nonempty(value):
                continue
            if not isinstance(value, dict) or set(value) != {"gap", "accepted_by"}:
                reasons.append(f"coverage {label} is invalid")
                continue
            gap = value["gap"]
            if (
                not isinstance(gap, dict)
                or set(gap) != {"material", "reason"}
                or not isinstance(gap["material"], bool)
                or not _nonempty(gap["reason"])
                or not _nonempty(value["accepted_by"])
            ):
                reasons.append(f"coverage {label} gap is invalid")
            elif gap["material"]:
                reasons.append(f"coverage {label} has a material gap")
            else:
                visible.append(f"coverage {label} has an accepted nonmaterial gap")


def _findings(report: dict, expected: dict, reasons: list[str]) -> bool:
    changes = False
    findings = report.get("findings")
    if not isinstance(findings, list):
        reasons.append("findings are invalid")
        return changes
    ids = set()
    for finding in findings:
        if not isinstance(finding, dict) or not all(
            _nonempty(finding.get(key))
            for key in ("id", "severity", "disposition", "scenario", "evidence")
        ):
            reasons.append("finding is invalid")
            continue
        if (
            finding["id"] in ids
            or finding["severity"] not in _SEVERITIES
            or finding["disposition"] not in {"confirmed", "refuted", "unresolved"}
        ):
            reasons.append(f"finding {finding['id']} is invalid")
            continue
        ids.add(finding["id"])
        if (
            finding["severity"] in _MATERIAL
            and finding["disposition"] in {"confirmed", "unresolved"}
            and not _nonempty(finding.get("impact"))
        ):
            reasons.append(f"material finding {finding['id']} impact is invalid")
            continue
        if finding["disposition"] == "unresolved" and finding["severity"] in _MATERIAL:
            reasons.append(f"material finding {finding['id']} is unresolved")
        elif finding["disposition"] == "confirmed" and finding["severity"] in _MATERIAL:
            changes = True
    known = expected.get("known_blockers")
    if not isinstance(known, list) or not all(_nonempty(item) for item in known):
        reasons.append("expected known_blockers is invalid")
        return changes
    dispositions = report.get("prior_blockers")
    if not isinstance(dispositions, list):
        reasons.append("prior blockers are invalid")
        return changes
    found = {}
    for item in dispositions:
        if (
            not isinstance(item, dict)
            or not _nonempty(item.get("id"))
            or item.get("disposition") not in {"repaired", "refuted", "still-open"}
            or not _nonempty(item.get("evidence"))
            or item["id"] in found
        ):
            reasons.append("prior blocker is invalid")
            continue
        found[item["id"]] = item
    for blocker in known:
        if blocker not in found:
            reasons.append(f"prior blocker {blocker} is missing")
        elif found[blocker]["disposition"] == "still-open":
            changes = True
    if any(item["disposition"] == "still-open" for item in found.values()):
        changes = True
    return changes


def evaluate(report: dict, expected: dict, artifact_root: Path) -> dict:
    """Return APPROVE, CHANGES, or INCOMPLETE without raising on bad input."""
    reasons: list[str] = []
    visible: list[str] = []
    changes = False
    if not isinstance(report, dict) or not isinstance(expected, dict):
        return {
            "verdict": "INCOMPLETE",
            "approve_allowed": False,
            "reasons": ["report or expected identity is invalid"],
        }
    if report.get("schema_version") != 1 or expected.get("schema_version") != 1:
        reasons.append("unsupported schema version")
    for field in (
        "run_id",
        "repository",
        "pr_number",
        "head",
        "base",
        "base_ref",
        "tree",
    ):
        if field not in expected or report.get(field) != expected.get(field):
            reasons.append(f"identity mismatch: {field}")
    for field in ("run_id", "repository", "base_ref"):
        if not _nonempty(report.get(field)):
            reasons.append(f"report {field} is invalid")
    if (
        isinstance(report.get("pr_number"), bool)
        or not isinstance(report.get("pr_number"), int)
        or report["pr_number"] <= 0
    ):
        reasons.append("report pr_number is invalid")
    for field in ("head", "base", "tree", "reviewed_tree"):
        if not _sha(report.get(field)):
            reasons.append(f"report {field} is invalid")
    if report.get("reviewed_tree") != report.get("tree"):
        reasons.append("reviewed tree is dirty")
    tier = report.get("class")
    if "class" not in expected or tier != expected.get("class"):
        reasons.append("identity mismatch: class")
    required = _TIER_SEATS.get(tier) if isinstance(tier, str) else None
    if required is None:
        reasons.append("report class is invalid")
    seats = report.get("seats")
    if required is None or not isinstance(seats, dict) or set(seats) != set(required):
        reasons.append("required seats are missing")
    else:
        for name in required:
            _artifact_ok(seats[name], artifact_root, name, reasons)
        substituted = _substitutes(tier, seats, artifact_root, reasons, visible)
        if tier == "light":
            runtimes = set()
            for name in required:
                seat = seats[name]
                if not isinstance(seat, dict):
                    continue
                if name in substituted:
                    runtimes.add("codex")
                elif isinstance(seat.get("runtime"), str):
                    runtimes.add(seat.get("runtime"))
            if runtimes != {"claude", "codex"}:
                reasons.append("light seats must be one claude and one codex runtime")
    if tier == "light" and not _light_diff_ok(report.get("preconditions"), artifact_root):
        reasons.append("class light does not match the frozen diff")
    _coverage(report, reasons, visible)
    changes = _findings(report, expected, reasons)
    source = report.get("preconditions")
    if (
        not isinstance(source, dict)
        or source.get("head") != report.get("head")
        or source.get("tree") != report.get("tree")
    ):
        reasons.append("preconditions identity does not match report")
    preconditions = _load_preconditions().evaluate(source, artifact_root)
    if not preconditions["approve_allowed"]:
        reasons.extend(preconditions["reasons"])
    if reasons:
        return {"verdict": "INCOMPLETE", "approve_allowed": False, "reasons": reasons}
    if changes:
        return {
            "verdict": "CHANGES",
            "approve_allowed": False,
            "reasons": ["confirmed material findings or open blockers", *visible],
        }
    return {"verdict": "APPROVE", "approve_allowed": True, "reasons": visible}


def audit_comment(report: dict, expected: dict, report_path: Path) -> str | None:
    """The PR audit comment for an APPROVE report, or None."""
    root = report_path.resolve().parent
    if evaluate(report, expected, root)["verdict"] != "APPROVE":
        return None
    preconditions = report["preconditions"]
    ci = json.loads((root / preconditions["ci"]["artifact"]).read_text(encoding="utf-8"))
    count = len(ci["check_runs"]) + len(ci["status_contexts"])
    ci_line = (f"{count}/{count} checks passed" if count
               else f"no CI: {preconditions['no_ci']['evidence']}")
    shown = str(report_path.resolve())
    home = str(Path.home().resolve())
    if shown == home or shown.startswith(home + os.sep):
        shown = "~" + shown[len(home):]
    tier = report["class"]
    seats = report["seats"]
    substitute_lines = tuple(
        f"- Substitute: {name} seat ran on claude after a codex "
        f"{seats[name]['codex_substitute']['reason']} failure"
        for name in _TIER_SEATS[tier]
        if isinstance(seats.get(name), dict) and "codex_substitute" in seats[name]
    )
    lines = (
        f"<!-- co-review-audit head={report['head']} run={report['run_id']} -->",
        "Co-review gate: APPROVE",
        "",
        f"- Run: {report['run_id']}",
        f"- Head: {report['head']}",
        f"- Tier: {tier} ({len(_TIER_SEATS[tier])} seats)",
        *substitute_lines,
        f"- CI: {ci_line}",
        f"- Report: {shown}",
    )
    return "\n".join(lines) + "\n"


def schema() -> dict:
    preconditions = {
        "head": "40-char SHA",
        "tree": "40-char SHA",
        "diff": {"artifact": "report-relative path", "sha256": "SHA-256"},
        "ci": {"artifact": "report-relative path", "sha256": "SHA-256"},
        "no_ci": {"evidence": "explicit evidence"},
    }
    return {
        "schema_version": 1,
        "light_seats": list(LIGHT_SEATS),
        "full_seats": list(FULL_SEATS),
        "class": "light or full; the evaluator recomputes light from the frozen diff",
        "finding_fields": {
            "id": "nonempty unique identifier",
            "severity": "critical, high, major, minor, low, nit, or advisory",
            "disposition": "confirmed, refuted, or unresolved",
            "scenario": "nonempty reproduction or review scenario",
            "evidence": "nonempty supporting evidence",
            "impact": "nonempty for confirmed or unresolved critical, high, and major findings",
        },
        "coverage": {"architecture": list(_AXES), "checklist": list(_CHECKLIST)},
        "report_example": {
            "schema_version": 1,
            "run_id": "active-run",
            "repository": "owner/repo",
            "pr_number": 1,
            "head": "40-char SHA",
            "base": "40-char SHA",
            "base_ref": "main",
            "tree": "40-char SHA",
            "reviewed_tree": "40-char SHA",
            "class": "full",
            "seats": {
                seat: {
                    "status": "complete",
                    "artifact": "report-relative path",
                    "sha256": "SHA-256",
                    "runtime": "observed or unknown",
                    "model": "observed or unknown",
                    "effort": "observed or unknown",
                }
                for seat in FULL_SEATS
            },
            "findings": [],
            "prior_blockers": [],
            "coverage": {
                "architecture": {key: "evidence" for key in _AXES},
                "checklist": {key: "evidence" for key in _CHECKLIST},
            },
            "preconditions": preconditions,
        },
        "expected_example": {
            "schema_version": 1,
            "run_id": "active-run",
            "repository": "owner/repo",
            "pr_number": 1,
            "head": "40-char SHA",
            "base": "40-char SHA",
            "base_ref": "main",
            "tree": "40-char SHA",
            "known_blockers": [],
            "class": "full",
        },
        "bindings": {
            "manifest.source.source_tree": "expected.tree",
            "snapshot.codex_tree": "report.reviewed_tree",
        },
        "codex_substitute": {
            "seats": {k: list(v) for k, v in _CODEX_SEATS.items()},
            "reasons": list(_SUBSTITUTE_REASONS),
            "seat_runtime": "claude",
            "seat_field": {
                "reason": "quota, auth, or unavailable",
                "attempt": {
                    "artifact": "report-relative path to the preserved failed Codex runner JSON",
                    "sha256": "SHA-256",
                },
            },
            "attempt_must_show": (
                "runtime codex; status error or unparseable; "
                "result absent or null; at least one nonempty string in errors"
            ),
        },
    }


def extract_policy(text: str, section: str) -> str:
    if section != "POLICY":
        raise ValueError("unsupported policy section")
    start, end = "<!-- gate-policy:start -->", "<!-- gate-policy:end -->"
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError("policy anchors must appear exactly once")
    before, remainder = text.split(start, 1)
    body, after = remainder.split(end, 1)
    if not before or not after or not body.strip():
        raise ValueError("policy anchors are reversed or empty")
    return body.strip() + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="gate_report.py")
    sub = parser.add_subparsers(dest="command", required=True)
    evaluate_parser = sub.add_parser("evaluate")
    evaluate_parser.add_argument("--report", required=True)
    evaluate_parser.add_argument("--expected", required=True)
    sub.add_parser("schema")
    policy_parser = sub.add_parser("policy")
    policy_parser.add_argument("--section", required=True)
    classify_parser = sub.add_parser("classify")
    classify_parser.add_argument("--diff", required=True)
    audit_parser = sub.add_parser("audit-comment")
    audit_parser.add_argument("--report", required=True)
    audit_parser.add_argument("--expected", required=True)
    args = parser.parse_args(argv)
    if args.command == "schema":
        print(json.dumps(schema(), sort_keys=True))
        return 0
    if args.command == "classify":
        try:
            text = Path(args.diff).read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            print(json.dumps({"error": str(error)}))
            return 1
        change_class = _load_change_class()
        paths = change_class.paths_from_diff(text)
        print(change_class.classify(paths or []))
        return 0
    if args.command == "policy":
        try:
            print(
                extract_policy(
                    Path(__file__)
                    .parents[1]
                    .joinpath("gate-policy.md")
                    .read_text(encoding="utf-8"),
                    args.section,
                ),
                end="",
            )
        except (OSError, ValueError) as error:
            print(json.dumps({"error": str(error)}))
            return 1
        return 0
    if args.command == "audit-comment":
        try:
            report = json.loads(Path(args.report).read_text(encoding="utf-8"))
            expected = json.loads(Path(args.expected).read_text(encoding="utf-8"))
            body = audit_comment(report, expected, Path(args.report))
        except (OSError, ValueError, TypeError, KeyError):
            body = None
        if body is None:
            return 1
        print(body, end="")
        return 0
    try:
        report = json.loads(Path(args.report).read_text(encoding="utf-8"))
        expected = json.loads(Path(args.expected).read_text(encoding="utf-8"))
        result = evaluate(report, expected, Path(args.report).resolve().parent)
    except (OSError, ValueError, TypeError) as error:
        result = {
            "verdict": "INCOMPLETE",
            "approve_allowed": False,
            "reasons": [f"cannot read gate input: {error}"],
        }
    print(json.dumps(result, sort_keys=True))
    return 0 if result["verdict"] == "APPROVE" else 1


if __name__ == "__main__":
    raise SystemExit(main())
