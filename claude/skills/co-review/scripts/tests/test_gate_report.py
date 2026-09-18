"""Behavior tests for the structured co-review report gate."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = SCRIPTS / "gate_report.py"
_spec = importlib.util.spec_from_file_location("gate_report", SPEC)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

SHA_A = "a" * 40
SHA_B = "b" * 40
AXES = (
    "ownership_authority",
    "dependency_boundaries",
    "contract_coherence",
    "state_effects",
    "lifecycle_operations",
    "demonstrability_constraints",
)
CHECKLIST = (
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


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class GateReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.expected = {
            "schema_version": 1,
            "run_id": "run-1",
            "repository": "owner/repo",
            "pr_number": 7,
            "head": SHA_A,
            "base": SHA_B,
            "base_ref": "main",
            "tree": SHA_A,
            "known_blockers": ["old-1"],
        }
        self.report = self._report()

    def tearDown(self):
        self.tmp.cleanup()

    def _write(self, relative: str, body: str) -> dict:
        path = self.root / relative
        path.write_text(body, encoding="utf-8")
        return {"artifact": relative, "sha256": digest(path)}

    def _write_bytes(self, relative: str, body: bytes) -> dict:
        path = self.root / relative
        path.write_bytes(body)
        return {"artifact": relative, "sha256": digest(path)}

    def _report(self):
        seats = {}
        for name in ("claude", "codex", "breaker", "verifier"):
            seat = self._write(f"{name}.txt", f"{name} evidence\n")
            seats[name] = {
                "status": "complete",
                **seat,
                "runtime": "known",
                "model": "unknown",
                "effort": "unknown",
            }
        frozen = self._write(
            "review.diff",
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+reviewed\n",
        )
        ci = self._write(
            "ci.json",
            json.dumps(
                {
                    "head": SHA_A,
                    "check_runs": [
                        {
                            "name": "tests",
                            "status": "COMPLETED",
                            "conclusion": "SUCCESS",
                        }
                    ],
                    "status_contexts": [],
                }
            ),
        )
        coverage = {name: "reviewed" for name in AXES + CHECKLIST}
        return {
            "schema_version": 1,
            "run_id": "run-1",
            "repository": "owner/repo",
            "pr_number": 7,
            "head": SHA_A,
            "base": SHA_B,
            "base_ref": "main",
            "tree": SHA_A,
            "reviewed_tree": SHA_A,
            "seats": seats,
            "findings": [],
            "prior_blockers": [
                {"id": "old-1", "disposition": "repaired", "evidence": "test"}
            ],
            "coverage": {
                "architecture": {key: coverage[key] for key in AXES},
                "checklist": {key: coverage[key] for key in CHECKLIST},
            },
            "preconditions": {"head": SHA_A, "tree": SHA_A, "diff": frozen, "ci": ci},
        }

    def verdict(self):
        return gate.evaluate(self.report, self.expected, self.root)

    def test_valid_report_approves(self):
        result = self.verdict()
        self.assertEqual(result["verdict"], "APPROVE")
        self.assertTrue(result["approve_allowed"])

    def test_missing_failed_or_empty_seat_is_incomplete(self):
        for mutation in (
            lambda: self.report["seats"].pop("codex"),
            lambda: self.report["seats"]["codex"].update(status="failed"),
            lambda: (self.root / "codex.txt").write_text("  \n", encoding="utf-8"),
        ):
            with self.subTest(mutation=mutation):
                baseline = self._report()
                self.report = baseline
                mutation()
                self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_bad_seat_digest_and_schema_fail_closed(self):
        self.report["seats"]["claude"]["sha256"] = "0" * 64
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self.report = self._report()
        self.report["schema_version"] = 2
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_every_identity_mismatch_is_incomplete(self):
        for key, changed in {
            "run_id": "other",
            "repository": "other/repo",
            "pr_number": 8,
            "head": SHA_B,
            "base": SHA_A,
            "base_ref": "release",
            "tree": SHA_B,
        }.items():
            with self.subTest(key=key):
                self.report = self._report()
                self.report[key] = changed
                self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_precondition_identity_and_pr_number_must_be_ready_for_a_pr(self):
        self.report["preconditions"]["head"] = SHA_B
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self.report = self._report()
        self.report["pr_number"] = 0
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_dirty_tree_missing_coverage_and_unknown_severity_are_incomplete(self):
        self.report["reviewed_tree"] = SHA_B
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self.report = self._report()
        self.report["coverage"]["architecture"].pop(AXES[0])
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self.report = self._report()
        self.report["findings"] = [
            {
                "id": "f",
                "severity": "bad",
                "disposition": "refuted",
                "scenario": "x",
                "evidence": "y",
            }
        ]
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_material_findings_require_impact_evidence_shape(self):
        finding = {
            "id": "f",
            "severity": "major",
            "disposition": "confirmed",
            "scenario": "x",
            "evidence": "y",
        }
        self.report["findings"] = [finding]
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        finding["impact"] = "Users can bypass the required check."
        self.assertEqual(self.verdict()["verdict"], "CHANGES")
        finding.update(disposition="unresolved")
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        for impact in ("", "  "):
            with self.subTest(impact=repr(impact)):
                finding["impact"] = impact
                self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        finding.pop("impact")
        finding.update(severity="advisory", disposition="confirmed")
        self.assertEqual(self.verdict()["verdict"], "APPROVE")

    def test_prior_blocker_omission_and_material_gap_are_incomplete(self):
        self.report["prior_blockers"] = []
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_extra_still_open_prior_blocker_cannot_be_ignored(self):
        self.expected["known_blockers"] = []
        self.report["prior_blockers"] = [
            {
                "id": "extra",
                "disposition": "still-open",
                "evidence": "unrepaired required contract",
            }
        ]
        self.assertEqual(self.verdict()["verdict"], "CHANGES")
        self.report = self._report()
        self.report["coverage"]["checklist"][CHECKLIST[0]] = {
            "gap": {"material": True, "reason": "missing"},
            "accepted_by": "owner",
        }
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_named_nonmaterial_gap_remains_visible_without_blocking(self):
        self.report["coverage"]["checklist"][CHECKLIST[0]] = {
            "gap": {"material": False, "reason": "not applicable"},
            "accepted_by": "owner",
        }
        result = self.verdict()
        self.assertEqual(result["verdict"], "APPROVE")
        self.assertIn("accepted nonmaterial gap", result["reasons"][0])

    def test_cli_uses_report_relative_artifacts_and_expected_identity(self):
        report_path = self.root / "report.json"
        expected_path = self.root / "expected.json"
        report_path.write_text(json.dumps(self.report), encoding="utf-8")
        expected_path.write_text(json.dumps(self.expected), encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SPEC),
                "evaluate",
                "--report",
                str(report_path),
                "--expected",
                str(expected_path),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        (self.root / "claude.txt").write_text("changed\n", encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SPEC),
                "evaluate",
                "--report",
                str(report_path),
                "--expected",
                str(expected_path),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.expected["run_id"] = "stale"
        expected_path.write_text(json.dumps(self.expected), encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SPEC),
                "evaluate",
                "--report",
                str(report_path),
                "--expected",
                str(expected_path),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)

    def test_policy_requires_exact_one_anchor_pair(self):
        with self.assertRaises(ValueError):
            gate.extract_policy("no anchors", "POLICY")
        with self.assertRaises(ValueError):
            gate.extract_policy(
                "<!-- gate-policy:start -->\na\n<!-- gate-policy:end -->\n<!-- gate-policy:start -->\nb\n<!-- gate-policy:end -->",
                "POLICY",
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
