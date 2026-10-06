"""Behavior tests for the CI envelope a co-review gate freezes before seats."""

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
GREEN_RUN = {"__typename": "CheckRun", "name": "tests", "status": "COMPLETED",
             "conclusion": "SUCCESS", "workflowName": "tests"}
GREEN_CONTEXT = {"__typename": "StatusContext", "context": "ci/x", "state": "SUCCESS"}


class CiEnvelopeTests(unittest.TestCase):
    def test_green_rollup_maps_both_node_types(self):
        pr = {"headRefOid": SHA_A, "statusCheckRollup": [GREEN_RUN, GREEN_CONTEXT]}
        envelope, reasons = gate.ci_envelope(pr, SHA_A)
        self.assertEqual(reasons, [])
        self.assertEqual(envelope, {
            "head": SHA_A,
            "check_runs": [{"name": "tests", "status": "COMPLETED", "conclusion": "SUCCESS"}],
            "status_contexts": [{"context": "ci/x", "state": "SUCCESS"}],
        })

    def test_pending_check_is_a_reason(self):
        run = {**GREEN_RUN, "status": "IN_PROGRESS", "conclusion": ""}
        _, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": [run]}, SHA_A)
        self.assertEqual(reasons, ["CI check run is pending"])

    def test_failed_check_is_a_reason(self):
        run = {**GREEN_RUN, "conclusion": "FAILURE"}
        _, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": [run]}, SHA_A)
        self.assertEqual(reasons, ["CI check run conclusion is 'FAILURE'"])

    def test_empty_rollup_reports_missing_ci_only(self):
        envelope, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": []}, SHA_A)
        self.assertEqual(reasons, ["CI evidence is missing"])
        self.assertEqual(envelope, {"head": SHA_A, "check_runs": [], "status_contexts": []})

    def test_unknown_or_short_node_is_a_reason(self):
        pr = {"headRefOid": SHA_A, "statusCheckRollup": [{"__typename": "Mystery"}, GREEN_RUN]}
        _, reasons = gate.ci_envelope(pr, SHA_A)
        self.assertEqual(reasons, ["CI rollup node type 'Mystery' is unknown"])
        pr = {"headRefOid": SHA_A, "statusCheckRollup": [{"__typename": "CheckRun", "name": "x"}]}
        _, reasons = gate.ci_envelope(pr, SHA_A)
        self.assertEqual(reasons, ["CI rollup CheckRun node is missing a field",
                                   "CI evidence is missing"])

    def test_head_moved_is_a_reason(self):
        _, reasons = gate.ci_envelope({"headRefOid": SHA_B, "statusCheckRollup": [GREEN_RUN]}, SHA_A)
        self.assertEqual(reasons, [f"PR head moved: {SHA_B} is not {SHA_A}"])

    def test_head_moved_with_zero_checks_keeps_both_reasons(self):
        _, reasons = gate.ci_envelope({"headRefOid": SHA_B, "statusCheckRollup": []}, SHA_A)
        self.assertEqual(reasons, ["CI evidence is missing",
                                   f"PR head moved: {SHA_B} is not {SHA_A}"])

    def test_cli_writes_a_green_envelope_preconditions_accept(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pr-ci.json").write_text(json.dumps(
                {"headRefOid": SHA_A, "statusCheckRollup": [GREEN_RUN, GREEN_CONTEXT]}),
                encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SPEC), "ci-envelope", "--pr-json", str(root / "pr-ci.json"),
                 "--head", SHA_A, "--out", str(root / "ci.json")],
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 0, result.stdout)
            digest = hashlib.sha256((root / "ci.json").read_bytes()).hexdigest()
            self.assertEqual(json.loads(result.stdout),
                             {"artifact": "ci.json", "sha256": digest, "checks": 2, "reasons": []})
            (root / "frozen.diff").write_text("diff --git a/a b/a\n+x\n", encoding="utf-8")
            diff_digest = hashlib.sha256((root / "frozen.diff").read_bytes()).hexdigest()
            verdict = gate._load_preconditions().evaluate(
                {"head": SHA_A, "tree": SHA_A,
                 "diff": {"artifact": "frozen.diff", "sha256": diff_digest},
                 "ci": {"artifact": "ci.json", "sha256": digest}}, root)
            self.assertEqual(verdict, {"approve_allowed": True, "reasons": []})

    def test_cli_malformed_pr_json_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pr-ci.json").write_text(json.dumps({"statusCheckRollup": []}), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SPEC), "ci-envelope", "--pr-json", str(root / "pr-ci.json"),
                 "--head", SHA_A, "--out", str(root / "ci.json")],
                capture_output=True, text=True, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("error", json.loads(result.stdout))
            self.assertFalse((root / "ci.json").exists())


if __name__ == "__main__":
    unittest.main()
