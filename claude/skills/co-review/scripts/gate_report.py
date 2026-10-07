"""Evaluate a structured, current-session co-review report."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import shutil
from pathlib import Path


_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
LIGHT_SEATS = ("codex", "verifier")
FULL_SEATS = ("claude", "codex", "breaker", "verifier")
DELTA_SEATS = ("claude", "verifier")
LESSONS_SEATS = ("verifier",)
_TIER_SEATS = {"light": LIGHT_SEATS, "full": FULL_SEATS, "delta": DELTA_SEATS,
               "lessons": LESSONS_SEATS}
_CODEX_SEATS = {"light": ("codex",), "full": ("codex", "breaker"), "delta": (),
                "lessons": ()}
# A light gate may review a lessons-only diff; it is the stronger gate.
_DIFF_CLASSES = {"light": ("light", "lessons"), "lessons": ("lessons",)}
DELTA_MAX_FILES = 5
DELTA_MAX_LINES = 150
_BLAST_RADIUS = ("bounded", "unbounded")
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


def _load_runner():
    # The skill always ships beside claude/hooks; REVIEW_ROOT requires both.
    path = Path(__file__).resolve().parents[3] / "hooks" / "agent_runtime.py"
    spec = importlib.util.spec_from_file_location("co_review_agent_runtime", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _nonempty(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _sha(value: object) -> bool:
    return isinstance(value, str) and bool(_SHA_RE.fullmatch(value))


def _seat_content_ok(content: bytes, artifact: str, name: str, reasons: list[str]) -> None:
    """Refuse a failed runner result or a usage-limit refusal; .json means runner JSON."""
    refusal = _load_runner().usage_limit_refusal
    if not artifact.endswith(".json"):
        if refusal(content.decode("utf-8", errors="replace")):
            reasons.append(f"seat {name} result is a usage-limit refusal")
        return
    try:
        payload = json.loads(content.decode("utf-8"))
    except ValueError:
        payload = None
    if not isinstance(payload, dict) or not {"runtime", "status"} <= payload.keys():
        reasons.append(f"seat {name} artifact is not runner JSON")
        return
    if payload["status"] != "success":
        reasons.append(f"seat {name} runner status is not success")
    if refusal(payload.get("result")):
        reasons.append(f"seat {name} result is a usage-limit refusal")


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
    _seat_content_ok(content, artifact, name, reasons)


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


def _diff_class_ok(preconditions: object, root: Path, tier: str) -> bool:
    """True when the digest-bound frozen diff classifies as one the tier may gate."""
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
    return paths is not None and change_class.classify(paths) in _DIFF_CLASSES[tier]


def _lessons_ci_ok(preconditions: object, root: Path) -> bool:
    """True when the digest-bound CI artifact holds at least one check; CI is
    where the lessons contract check runs."""
    entry = preconditions.get("ci") if isinstance(preconditions, dict) else None
    path, errors = _load_preconditions()._artifact(entry, root, "CI")
    if errors:
        return False
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError):
        return False
    return isinstance(payload, dict) and any(
        isinstance(payload.get(key), list) and payload[key]
        for key in ("check_runs", "status_contexts"))


_ROLLUP_FIELDS = {"CheckRun": ("name", "status", "conclusion"),
                  "StatusContext": ("context", "state")}


def ci_envelope(pr: object, head: str) -> tuple[dict | None, list[str]]:
    """(envelope, reasons) from `gh pr view --json headRefOid,statusCheckRollup`;
    envelope is None when the input is unusable."""
    if (not isinstance(pr, dict) or not _sha(pr.get("headRefOid"))
            or not isinstance(pr.get("statusCheckRollup"), list)):
        return None, ["PR JSON needs a headRefOid SHA and a statusCheckRollup list"]
    envelope = {"head": pr["headRefOid"], "check_runs": [], "status_contexts": []}
    reasons = []
    for node in pr["statusCheckRollup"]:
        kind = node.get("__typename") if isinstance(node, dict) else None
        fields = _ROLLUP_FIELDS.get(kind)
        if fields is None:
            reasons.append(f"CI rollup node type {kind!r} is unknown")
            continue
        if not all(key in node for key in fields):
            reasons.append(f"CI rollup {kind} node is missing a field")
            continue
        target = "check_runs" if kind == "CheckRun" else "status_contexts"
        envelope[target].append({key: node[key] for key in fields})
    reasons.extend(_load_preconditions()._ci_reasons(envelope, None))
    if envelope["head"] != head:
        reasons.append(f"PR head moved: {envelope['head']} is not {head}")
    return envelope, reasons


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


def _positive_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def _json_artifact(entry: object, root: Path, label: str, reasons: list[str]):
    """(payload, path) of a digest-bound JSON object artifact, else (None, None)."""
    path, errors = _load_preconditions()._artifact(entry, root, label)
    if errors:
        reasons.extend(errors)
        return None, None
    try:
        payload = json.loads(path.read_bytes().decode("utf-8"))
    except (OSError, ValueError):
        payload = None
    if not isinstance(payload, dict):
        reasons.append(f"{label} artifact is not a JSON object")
        return None, None
    return payload, path


def _delta_prior(block: dict, wanted: dict, expected: dict, root: Path, reasons: list[str]) -> None:
    """The copied prior run must be this PR's full APPROVE at the cited head."""
    prior, prior_path = _json_artifact(block.get("prior_report"), root, "delta prior report", reasons)
    prior_expected, _ = _json_artifact(block.get("prior_expected"), root, "delta prior expected", reasons)
    if prior is None or prior_expected is None:
        return
    if prior.get("class") != "full":
        reasons.append("delta prior run is not a full round")
        return
    verdict = evaluate(prior, prior_expected, prior_path.parent)["verdict"]
    if verdict != "APPROVE":
        reasons.append(f"delta prior run verdict is {verdict}")
    if (prior_expected.get("run_id") != wanted.get("prior_run")
            or prior_expected.get("head") != wanted.get("prior_head")):
        reasons.append("delta prior run does not match the expected identity")
    for key in ("repository", "pr_number", "base_ref"):
        if prior_expected.get(key) != expected.get(key):
            reasons.append(f"delta prior {key} differs from this gate")


def _delta(report: dict, expected: dict, root: Path, reasons: list[str]) -> None:
    """Check a delta report's block (spec R19)."""
    wanted, block = expected.get("delta"), report.get("delta")
    if not isinstance(wanted, dict) or not isinstance(block, dict):
        reasons.append("delta block is missing")
        return
    for key in ("prior_run", "prior_head", "anchor_head"):
        if not _nonempty(wanted.get(key)) or block.get(key) != wanted.get(key):
            reasons.append(f"identity mismatch: delta {key}")
    _delta_prior(block, wanted, expected, root, reasons)
    caps = (wanted.get("max_files"), wanted.get("max_lines"))
    diff_path, errors = _load_preconditions()._artifact(block.get("diff"), root, "delta diff")
    reasons.extend(errors)
    if not all(_positive_int(cap) for cap in caps):
        reasons.append("delta caps are invalid")
    elif diff_path is not None:
        change_class = _load_change_class()
        stats = change_class.delta_stats(diff_path.read_bytes().decode("utf-8", "replace"))
        verdict = change_class.delta_class(stats, *caps)
        reasons.extend(f"delta diff is not eligible: {reason}" for reason in verdict["reasons"])
    if wanted.get("anchor_head") == wanted.get("prior_head"):
        if block.get("carry_forward") is not None:
            reasons.append("delta carry_forward must be null when the anchor is the prior head")
    else:
        record, _ = _json_artifact(block.get("carry_forward"), root, "delta carry_forward", reasons)
        if record is not None and not (
            record.get("pass") is True
            and record.get("prior_head") == wanted.get("prior_head")
            and record.get("head") == wanted.get("anchor_head")
        ):
            reasons.append("delta carry_forward does not prove the anchor")
    blast = block.get("blast_radius")
    if blast not in _BLAST_RADIUS:
        reasons.append("delta blast_radius is invalid")
    elif blast == "unbounded":
        reasons.append("delta blast radius is unbounded")


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
        if tier == "delta":
            for name in required:
                if isinstance(seats[name], dict) and seats[name].get("runtime") != "claude":
                    reasons.append(f"delta seat {name} must run on claude")
        if (tier == "lessons" and isinstance(seats["verifier"], dict)
                and seats["verifier"].get("runtime") != "claude"):
            reasons.append("lessons seat verifier must run on claude")
    if (isinstance(tier, str) and tier in _DIFF_CLASSES
            and not _diff_class_ok(report.get("preconditions"), artifact_root, tier)):
        reasons.append(f"class {tier} does not match the frozen diff")
    if tier == "lessons" and not _lessons_ci_ok(report.get("preconditions"), artifact_root):
        reasons.append("class lessons needs CI check evidence")
    if tier == "delta":
        _delta(report, expected, artifact_root, reasons)
    elif "delta" in report or "delta" in expected:
        reasons.append("delta block on a non-delta class")
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
        result = {"verdict": "INCOMPLETE", "approve_allowed": False, "reasons": reasons}
    elif changes:
        result = {
            "verdict": "CHANGES",
            "approve_allowed": False,
            "reasons": ["confirmed material findings or open blockers", *visible],
        }
    else:
        result = {"verdict": "APPROVE", "approve_allowed": True, "reasons": visible}
    # A delta never ends short of APPROVE: the next gate on this head is full
    # (spec [D7], R21).
    if tier == "delta" and result["verdict"] != "APPROVE":
        result["escalate"] = "full"
    return result


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
    tier = report["class"]
    seats = report["seats"]
    prior_fields, prior_lines = "", ()
    if tier == "delta":
        delta = report["delta"]
        prior_fields = f" prior_run={delta['prior_run']} prior_head={delta['prior_head']}"
        prior_lines = (f"- Prior: {delta['prior_run']} at {delta['prior_head']}",)
    substitute_lines = tuple(
        f"- Substitute: {name} seat ran on claude after a codex "
        f"{seats[name]['codex_substitute']['reason']} failure"
        for name in _TIER_SEATS[tier]
        if isinstance(seats.get(name), dict) and "codex_substitute" in seats[name]
    )
    seat_count = len(_TIER_SEATS[tier])
    lines = (
        f"<!-- co-review-audit head={report['head']} run={report['run_id']} "
        f"tier={tier}{prior_fields} -->",
        "Co-review gate: APPROVE",
        "",
        f"- Run: {report['run_id']}",
        f"- Head: {report['head']}",
        f"- Tier: {tier} ({seat_count} seat{'' if seat_count == 1 else 's'})",
        *prior_lines,
        *substitute_lines,
        f"- CI: {ci_line}",
    )
    return "\n".join(lines) + "\n"


def carry_forward_comment(record: dict) -> str:
    """The PR audit comment for a passing carry-forward record (spec R7)."""
    lines = [
        f"<!-- co-review-audit head={record['head']} run={record['prior_run']} "
        f"tier=carry-forward prior_head={record['prior_head']} -->",
        "Co-review gate: APPROVE (carry-forward)",
        "",
        f"- Run: {record['prior_run']} (carried, no seats)",
        f"- Head: {record['head']}",
        f"- Prior head: {record['prior_head']}",
        f"- Base: {record['base_ref']} at {record['base']}",
        "",
        "```text",
    ]
    for proof in record["proofs"]:
        lines.append("$ " + " ".join(proof["argv"]))
        lines.extend(proof["output"] or ["(empty)"])
    lines.append("```")
    return "\n".join(lines) + "\n"


def _read_gate(report_path: Path, expected_path: Path, report_sha256: str | None,
               expected_sha256: str | None, reasons: list[str]):
    """(report, expected) of a digest-pinned gate that still evaluates APPROVE, else None.

    A None digest is only for a file already bound by a pinned report's own digest.
    """
    try:
        report_bytes, expected_bytes = report_path.read_bytes(), expected_path.read_bytes()
    except OSError as error:
        reasons.append(f"cannot read the prior gate: {error}")
        return None
    for label, content, pinned in (("report", report_bytes, report_sha256),
                                   ("expected", expected_bytes, expected_sha256)):
        if pinned is not None and hashlib.sha256(content).hexdigest() != pinned:
            reasons.append(f"prior {label} digest does not match its pin")
            return None
    try:
        report = json.loads(report_bytes.decode("utf-8"))
        expected = json.loads(expected_bytes.decode("utf-8"))
    except ValueError as error:
        reasons.append(f"cannot read the prior gate: {error}")
        return None
    verdict = evaluate(report, expected, report_path.resolve().parent)["verdict"]
    if verdict != "APPROVE":
        reasons.append(f"prior gate verdict is {verdict}")
        return None
    return report, expected


def carry_forward_record(repo: Path, report_path: Path, expected_path: Path,
                         report_sha256: str, expected_sha256: str, head: str) -> dict:
    """Re-evaluate the prior APPROVE and run the carry-forward proofs (spec R1-R7)."""
    record = {
        "schema": 1, "tier": "carry-forward", "pass": False, "reasons": [],
        "prior_run": None, "prior_head": None, "head": None, "upstream": None,
        "base": None, "base_ref": None, "old_base": None, "new_base": None,
        "proofs": [], "audit_comment": None,
    }
    gate = _read_gate(report_path, expected_path, report_sha256, expected_sha256,
                      record["reasons"])
    if gate is None:
        return record
    expected = gate[1]
    upstream = f"origin/{expected['base_ref']}"
    record.update(prior_run=expected["run_id"], base_ref=expected["base_ref"])
    record.update(_load_sibling("branch_delta").carry_forward(repo, expected["head"], head, upstream))
    if record["pass"]:
        record["audit_comment"] = carry_forward_comment(record)
    return record


def _full_prior(report_path: Path, expected_path: Path, report_sha256: str | None,
                expected_sha256: str | None, reasons: list[str]):
    """(expected, report_path, expected_path, report_sha256, expected_sha256) of the
    full APPROVE a delta builds on; the digests pin the bytes that were evaluated."""
    gate = _read_gate(report_path, expected_path, report_sha256, expected_sha256, reasons)
    if gate is None:
        return None
    report, expected = gate
    if report.get("class") == "delta":
        # A delta report pins its prior copy by digest; follow that pin.
        root = report_path.resolve().parent
        report_path = root / report["delta"]["prior_report"]["artifact"]
        expected_path = root / report["delta"]["prior_expected"]["artifact"]
        report_sha256 = report["delta"]["prior_report"]["sha256"]
        expected_sha256 = report["delta"]["prior_expected"]["sha256"]
        gate = _read_gate(report_path, expected_path, report_sha256, expected_sha256, reasons)
        if gate is None:
            return None
        report, expected = gate
    if report.get("class") != "full":
        reasons.append("first round on a branch is always full: no prior full APPROVE")
        return None
    return (expected, report_path.resolve(), expected_path.resolve(),
            report_sha256, expected_sha256)


def delta_recommendation(repo: Path, report_path: Path, expected_path: Path,
                         report_sha256: str, expected_sha256: str, head: str,
                         max_files: int, max_lines: int, diff_out: Path) -> dict:
    """Recommend the delta or full tier for head (spec R15); any doubt is full."""
    rec = {
        "recommend": "full", "reasons": [], "prior_run": None, "prior_head": None,
        "prior_report": None, "prior_expected": None, "prior_report_sha256": None,
        "prior_expected_sha256": None, "anchor_head": None, "head": None,
        "max_files": max_files, "max_lines": max_lines, "stats": None, "carry_forward": None,
    }
    reasons = rec["reasons"]
    if not (_positive_int(max_files) and _positive_int(max_lines)):
        reasons.append("delta caps must be positive integers")
        return rec
    prior = _full_prior(report_path, expected_path, report_sha256, expected_sha256, reasons)
    if prior is None:
        return rec
    expected, full_report, full_expected, full_report_sha256, full_expected_sha256 = prior
    rec.update(prior_run=expected["run_id"], prior_head=expected["head"],
               prior_report=str(full_report), prior_expected=str(full_expected),
               prior_report_sha256=full_report_sha256,
               prior_expected_sha256=full_expected_sha256)
    branch_delta = _load_sibling("branch_delta")
    try:
        anchor_head = branch_delta.derive_anchor(repo, expected["head"], head)
        if anchor_head != expected["head"]:
            proof = branch_delta.carry_forward(
                repo, expected["head"], anchor_head, f"origin/{expected['base_ref']}")
            rec["carry_forward"] = proof
            if not proof["pass"]:
                reasons.append("anchor is not a carry-forward of the full head: "
                               + "; ".join(proof["reasons"]))
                return rec
        span = branch_delta.delta_range(repo, anchor_head, head)
    except branch_delta.ProofError as error:
        reasons.append(f"git check failed: {error}")
        return rec
    rec.update(anchor_head=span["anchor"], head=span["head"])
    if not span["ancestor"]:
        reasons.append("anchor is not an ancestor of head")
    if span["anchor"] == span["head"]:
        reasons.append("head equals the anchor: nothing to review")
    if span["merges"]:
        reasons.append("merge commits in the delta range: " + " ".join(span["merges"]))
    if reasons:
        return rec
    diff_out.write_bytes(span["diff"])
    change_class = _load_change_class()
    rec["stats"] = change_class.delta_stats(span["diff"].decode("utf-8", "replace"))
    verdict = change_class.delta_class(rec["stats"], max_files, max_lines)
    reasons.extend(verdict["reasons"])
    if verdict["eligible"]:
        rec["recommend"] = "delta"
    return rec


def _report_artifacts(report: dict) -> list[str]:
    """Every report-relative artifact name a gate report cites."""
    names = []
    for seat in (report.get("seats") or {}).values():
        if not isinstance(seat, dict):
            continue
        names.append(seat.get("artifact"))
        attempt = (seat.get("codex_substitute") or {}).get("attempt")
        if isinstance(attempt, dict):
            names.append(attempt.get("artifact"))
    for key in ("diff", "ci"):
        entry = (report.get("preconditions") or {}).get(key)
        if isinstance(entry, dict):
            names.append(entry.get("artifact"))
    return [name for name in names if isinstance(name, str)]


def copy_prior(report_path: Path, expected_path: Path, report_sha256: str,
               expected_sha256: str, out: Path) -> dict:
    """Copy one digest-pinned full APPROVE run into a fresh out/ a delta report cites
    (spec R18). The pins are the ones `delta-class` verified, so the copy is the
    prior the pinned ship.json named."""
    source = report_path.resolve().parent
    report_bytes, expected_bytes = report_path.read_bytes(), expected_path.read_bytes()
    for label, content, pinned in (("report", report_bytes, report_sha256),
                                   ("expected", expected_bytes, expected_sha256)):
        if hashlib.sha256(content).hexdigest() != pinned:
            raise ValueError(f"prior {label} digest does not match its pin")
    report = json.loads(report_bytes.decode("utf-8"))
    names = _report_artifacts(report)
    if {"report.json", "expected.json"} & set(names):
        raise ValueError("a prior artifact collides with report.json or expected.json")
    out.mkdir()
    for name in names:
        origin = source / name
        if origin.is_symlink() or not origin.is_file():
            raise ValueError(f"prior artifact {name} is not a regular file")
        origin.resolve().relative_to(source.resolve())
        target = out / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.resolve().relative_to(out.resolve())
        shutil.copyfile(origin, target)
    (out / "report.json").write_bytes(report_bytes)
    (out / "expected.json").write_bytes(expected_bytes)
    reasons: list[str] = []
    if _full_prior(out / "report.json", out / "expected.json", report_sha256,
                   expected_sha256, reasons) is None:
        raise ValueError("copied prior does not evaluate as a full APPROVE: " + "; ".join(reasons))
    return {
        key: {"artifact": f"{out.name}/{key.split('_')[-1]}.json",
              "sha256": hashlib.sha256((out / f"{key.split('_')[-1]}.json").read_bytes()).hexdigest()}
        for key in ("prior_report", "prior_expected")
    }


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
        "delta_seats": list(DELTA_SEATS),
        "lessons_seats": list(LESSONS_SEATS),
        "delta": {
            "expected_fields": {
                "prior_run": "run_id of the full APPROVE this delta builds on",
                "prior_head": "that run's head",
                "anchor_head": "the full head, or the main merge carrying it forward",
                "max_files": "positive int cap (default 5)",
                "max_lines": "positive int cap on added plus removed lines (default 150)",
            },
            "report_fields": {
                "prior_run": "equals expected.delta.prior_run",
                "prior_head": "equals expected.delta.prior_head",
                "anchor_head": "equals expected.delta.anchor_head",
                "prior_report": {"artifact": "prior/report.json", "sha256": "SHA-256"},
                "prior_expected": {"artifact": "prior/expected.json", "sha256": "SHA-256"},
                "diff": {"artifact": "delta.diff", "sha256": "SHA-256"},
                "carry_forward": "null, or {artifact, sha256} of carry-forward.json",
                "blast_radius": "bounded or unbounded",
            },
        },
        "result_fields": {
            "verdict": "APPROVE, CHANGES, or INCOMPLETE",
            "approve_allowed": "true only for APPROVE",
            "reasons": "list of strings",
            "escalate": "present as full only on a non-APPROVE delta result",
        },
        "class": "light, full, delta or lessons; the evaluator recomputes light and lessons from the frozen diff",
        "finding_fields": {
            "id": "nonempty unique identifier",
            "severity": "critical, high, major, minor, low, nit, or advisory",
            "disposition": "confirmed, refuted, or unresolved",
            "scenario": "nonempty reproduction or review scenario",
            "evidence": "nonempty supporting evidence",
            "impact": "nonempty for confirmed or unresolved critical, high, and major findings",
            "category": "optional; structure for a Structure fit finding",
            "proposed_layout": "optional; for a structure finding, what moves where",
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
        "seat_artifact_must_show": (
            "a .json seat artifact is runner JSON with runtime and status keys "
            "and status success; no seat artifact, runner result or native "
            "text, may open with a usage-limit refusal notice"
        ),
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
    lessons_parser = sub.add_parser("lessons-check")
    lessons_parser.add_argument("--file", required=True)
    envelope_parser = sub.add_parser("ci-envelope")
    for flag in ("--pr-json", "--head", "--out"):
        envelope_parser.add_argument(flag, required=True)
    audit_parser = sub.add_parser("audit-comment")
    audit_parser.add_argument("--report", required=True)
    audit_parser.add_argument("--expected", required=True)
    for name in ("carry-forward", "delta-class"):
        tier_parser = sub.add_parser(name)
        for flag in ("--repo", "--report", "--expected", "--report-sha256", "--expected-sha256"):
            tier_parser.add_argument(flag, required=True)
        tier_parser.add_argument("--head", default="HEAD")
        if name == "delta-class":
            tier_parser.add_argument("--max-files", type=int, default=DELTA_MAX_FILES)
            tier_parser.add_argument("--max-lines", type=int, default=DELTA_MAX_LINES)
            tier_parser.add_argument("--diff-out", required=True)
    copy_parser = sub.add_parser("copy-prior")
    for flag in ("--report", "--expected", "--report-sha256", "--expected-sha256", "--out"):
        copy_parser.add_argument(flag, required=True)
    args = parser.parse_args(argv)
    if args.command == "carry-forward":
        record = carry_forward_record(
            Path(args.repo), Path(args.report), Path(args.expected),
            args.report_sha256, args.expected_sha256, args.head)
        print(json.dumps(record, sort_keys=True))
        return 0 if record["pass"] else 1
    if args.command == "delta-class":
        rec = delta_recommendation(
            Path(args.repo), Path(args.report), Path(args.expected),
            args.report_sha256, args.expected_sha256, args.head,
            args.max_files, args.max_lines, Path(args.diff_out))
        print(json.dumps(rec, sort_keys=True))
        return 0 if rec["recommend"] == "delta" else 1
    if args.command == "copy-prior":
        try:
            entries = copy_prior(Path(args.report), Path(args.expected), args.report_sha256,
                                 args.expected_sha256, Path(args.out))
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(json.dumps({"error": str(error)}))
            return 1
        print(json.dumps(entries, sort_keys=True))
        return 0
    if args.command == "schema":
        print(json.dumps(schema(), sort_keys=True))
        return 0
    if args.command == "lessons-check":
        try:
            text = Path(args.file).read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            reasons = [f"cannot read {args.file}: {error}"]
        else:
            reasons = _load_sibling("lessons_contract").check(text)
        print(json.dumps({"pass": not reasons, "reasons": reasons}, sort_keys=True))
        return 0 if not reasons else 1
    if args.command == "ci-envelope":
        try:
            pr = json.loads(Path(args.pr_json).read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError) as error:
            print(json.dumps({"error": str(error)}))
            return 1
        envelope, reasons = ci_envelope(pr, args.head)
        if envelope is None:
            print(json.dumps({"error": reasons[0]}))
            return 1
        out = Path(args.out)
        out.write_text(json.dumps(envelope, sort_keys=True) + "\n", encoding="utf-8")
        checks = len(envelope["check_runs"]) + len(envelope["status_contexts"])
        print(json.dumps({"artifact": out.name, "sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
                          "checks": checks, "reasons": reasons}, sort_keys=True))
        return 0 if not reasons else 1
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
