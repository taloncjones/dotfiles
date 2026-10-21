"""Behavior tests for the CI envelope a co-review gate freezes before seats."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
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
STUB_GH = ('#!/bin/sh\npwd -P >"$STUB_DIR/cwd"\nprintf "%s\\n" "$@" >"$STUB_DIR/argv"\n'
           'cat "$STUB_DIR/out.json"\nexit "$(cat "$STUB_DIR/rc")"\n')
GH_ARGV = ["pr", "view", "7", "--repo", "o/r", "--json", "headRefOid,statusCheckRollup"]


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

    def test_old_failed_run_is_superseded_by_a_newer_success(self):
        old = {**GREEN_RUN, "conclusion": "FAILURE", "startedAt": '2026-10-21T10:00:00Z', "detailsUrl": "https://x/1"}
        new = {**GREEN_RUN, "startedAt": '2026-10-21T11:00:00Z'}
        for rollup in ([old, new], [new, old]):
            envelope, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": rollup}, SHA_A)
            self.assertEqual(reasons, [])
            self.assertEqual(envelope["check_runs"],
                             [{"name": "tests", "status": "COMPLETED", "conclusion": "SUCCESS"}])
            self.assertEqual(envelope["superseded_check_runs"], [
                {"name": "tests", "workflow_name": "tests", "status": "COMPLETED",
                 "conclusion": "FAILURE", "started_at": '2026-10-21T10:00:00Z', "latest_started_at": '2026-10-21T11:00:00Z',
                 "details_url": "https://x/1"}])
        del old["detailsUrl"]
        envelope, _ = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": [old, new]}, SHA_A)
        self.assertIsNone(envelope["superseded_check_runs"][0]["details_url"])

    def test_latest_failed_run_still_fails(self):
        ok = {**GREEN_RUN, "startedAt": '2026-10-21T10:00:00Z'}
        bad = {**GREEN_RUN, "conclusion": "FAILURE", "startedAt": '2026-10-21T11:00:00Z'}
        _, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": [ok, bad]}, SHA_A)
        self.assertEqual(reasons, ["CI check run conclusion is 'FAILURE'"])
        busy = {**GREEN_RUN, "status": "IN_PROGRESS", "conclusion": "", "startedAt": '2026-10-21T11:00:00Z'}
        _, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": [ok, busy]}, SHA_A)
        self.assertEqual(reasons, ["CI check run is pending"])

    def test_unknown_or_tied_start_is_never_superseded(self):
        ok = {**GREEN_RUN, "startedAt": '2026-10-21T10:00:00Z'}
        queued = {**GREEN_RUN, "status": "QUEUED", "conclusion": ""}
        for started in ({"startedAt": "0001-01-01T00:00:00Z"}, {}, {"startedAt": "soon"},
                        {"startedAt": "2026-10-21'2026-10-21T10:00:00Z'0:00:00"}):
            _, reasons = gate.ci_envelope(
                {"headRefOid": SHA_A, "statusCheckRollup": [ok, {**queued, **started}]}, SHA_A)
            self.assertEqual(reasons, ["CI check run is pending"], started)
        tied = {**GREEN_RUN, "conclusion": "FAILURE", "startedAt": '2026-10-21T10:00:00Z'}
        _, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": [ok, tied]}, SHA_A)
        self.assertEqual(reasons, ["CI check run conclusion is 'FAILURE'"])

    def test_same_name_in_other_workflow_is_not_superseded(self):
        old = {**GREEN_RUN, "conclusion": "FAILURE", "workflowName": "a", "startedAt": '2026-10-21T10:00:00Z'}
        new = {**GREEN_RUN, "workflowName": "b", "startedAt": '2026-10-21T11:00:00Z'}
        _, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": [old, new]}, SHA_A)
        self.assertEqual(reasons, ["CI check run conclusion is 'FAILURE'"])

    def test_status_contexts_and_incomplete_runs_pass_through(self):
        pr = {"headRefOid": SHA_A, "statusCheckRollup": [GREEN_CONTEXT, GREEN_CONTEXT]}
        envelope, _ = gate.ci_envelope(pr, SHA_A)
        self.assertEqual(len(envelope["status_contexts"]), 2)
        broken = {"__typename": "CheckRun", "name": "tests", "conclusion": "SUCCESS", "startedAt": '2026-10-21T10:00:00Z'}
        new = {**GREEN_RUN, "startedAt": '2026-10-21T11:00:00Z'}
        kept, superseded = gate.latest_check_runs([broken, new])
        self.assertEqual((kept, superseded), ([broken, new], []))
        _, reasons = gate.ci_envelope({"headRefOid": SHA_A, "statusCheckRollup": [broken, new]}, SHA_A)
        self.assertEqual(reasons, ["CI rollup CheckRun node is missing a field"])


class CiCaptureCliTests(unittest.TestCase):
    def test_cli_capture_writes_a_green_envelope_preconditions_accept(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(os.path.realpath(tmp))
            (root / "bin").mkdir()
            (root / "bin" / "gh").write_text(STUB_GH, encoding="utf-8")
            (root / "bin" / "gh").chmod(0o755)
            (root / "co").mkdir()
            (root / "rc").write_text("0", encoding="utf-8")
            (root / "out.json").write_text(json.dumps({"headRefOid": SHA_A, "statusCheckRollup": [GREEN_RUN, GREEN_CONTEXT]}), encoding="utf-8")
            (root / "expected.json").write_text(json.dumps(
                {"repository": "o/r", "pr_number": 7, "head": SHA_A}), encoding="utf-8")
            env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "STUB_DIR": str(root)}
            result = subprocess.run(
                [sys.executable, str(SPEC), "ci-capture", "--repo", str(root / "co"),
                 "--expected", str(root / "expected.json"), "--out", str(root / "ci.json")],
                capture_output=True, text=True, env=env, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / "argv").read_text(encoding="utf-8").splitlines(), GH_ARGV)
            self.assertEqual((root / "cwd").read_text(encoding="utf-8").strip(), str(root / "co"))
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

    def test_cli_capture_records_superseded_runs(self):
        old = {**GREEN_RUN, "conclusion": "FAILURE", "startedAt": '2026-10-21T10:00:00Z'}
        new = {**GREEN_RUN, "startedAt": '2026-10-21T11:00:00Z'}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(os.path.realpath(tmp))
            (root / "bin").mkdir()
            (root / "bin" / "gh").write_text(STUB_GH, encoding="utf-8")
            (root / "bin" / "gh").chmod(0o755)
            (root / "co").mkdir()
            (root / "rc").write_text("0", encoding="utf-8")
            (root / "out.json").write_text(json.dumps({"headRefOid": SHA_A, "statusCheckRollup": [old, new]}), encoding="utf-8")
            (root / "expected.json").write_text(json.dumps(
                {"repository": "o/r", "pr_number": 7, "head": SHA_A}), encoding="utf-8")
            env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "STUB_DIR": str(root)}
            result = subprocess.run(
                [sys.executable, str(SPEC), "ci-capture", "--repo", str(root / "co"),
                 "--expected", str(root / "expected.json"), "--out", str(root / "ci.json")],
                capture_output=True, text=True, env=env, check=False)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            out = json.loads(result.stdout)
            self.assertEqual((out["checks"], out["reasons"]), (1, []))
            saved = json.loads((root / "ci.json").read_text(encoding="utf-8"))
            self.assertEqual([r["conclusion"] for r in saved["superseded_check_runs"]], ["FAILURE"])
            self.assertEqual(len(saved["check_runs"]), 1)

    def test_cli_capture_gh_failure_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(os.path.realpath(tmp))
            (root / "bin").mkdir()
            (root / "bin" / "gh").write_text(STUB_GH, encoding="utf-8")
            (root / "bin" / "gh").chmod(0o755)
            (root / "co").mkdir()
            (root / "rc").write_text("1", encoding="utf-8")
            (root / "out.json").write_text("{}", encoding="utf-8")
            (root / "expected.json").write_text(json.dumps(
                {"repository": "o/r", "pr_number": 7, "head": SHA_A}), encoding="utf-8")
            env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "STUB_DIR": str(root)}
            result = subprocess.run(
                [sys.executable, str(SPEC), "ci-capture", "--repo", str(root / "co"),
                 "--expected", str(root / "expected.json"), "--out", str(root / "ci.json")],
                capture_output=True, text=True, env=env, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("error", json.loads(result.stdout))
            self.assertFalse((root / "ci.json").exists())

    def test_cli_capture_reports_a_moved_head(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(os.path.realpath(tmp))
            (root / "bin").mkdir()
            (root / "bin" / "gh").write_text(STUB_GH, encoding="utf-8")
            (root / "bin" / "gh").chmod(0o755)
            (root / "co").mkdir()
            (root / "rc").write_text("0", encoding="utf-8")
            (root / "out.json").write_text(json.dumps({"headRefOid": SHA_B, "statusCheckRollup": [GREEN_RUN]}), encoding="utf-8")
            (root / "expected.json").write_text(json.dumps(
                {"repository": "o/r", "pr_number": 7, "head": SHA_A}), encoding="utf-8")
            env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "STUB_DIR": str(root)}
            result = subprocess.run(
                [sys.executable, str(SPEC), "ci-capture", "--repo", str(root / "co"),
                 "--expected", str(root / "expected.json"), "--out", str(root / "ci.json")],
                capture_output=True, text=True, env=env, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["reasons"],
                             [f"PR head moved: {SHA_B} is not {SHA_A}"])
            self.assertTrue((root / "ci.json").exists())

    def test_cli_capture_empty_rollup_is_missing_ci_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(os.path.realpath(tmp))
            (root / "bin").mkdir()
            (root / "bin" / "gh").write_text(STUB_GH, encoding="utf-8")
            (root / "bin" / "gh").chmod(0o755)
            (root / "co").mkdir()
            (root / "rc").write_text("0", encoding="utf-8")
            (root / "out.json").write_text(json.dumps({"headRefOid": SHA_A, "statusCheckRollup": []}), encoding="utf-8")
            (root / "expected.json").write_text(json.dumps(
                {"repository": "o/r", "pr_number": 7, "head": SHA_A}), encoding="utf-8")
            env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "STUB_DIR": str(root)}
            result = subprocess.run(
                [sys.executable, str(SPEC), "ci-capture", "--repo", str(root / "co"),
                 "--expected", str(root / "expected.json"), "--out", str(root / "ci.json")],
                capture_output=True, text=True, env=env, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)["reasons"], ["CI evidence is missing"])
            self.assertEqual(json.loads((root / "ci.json").read_text(encoding="utf-8")),
                             {"head": SHA_A, "check_runs": [], "status_contexts": []})

    def test_cli_capture_rejects_a_bad_expected_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(os.path.realpath(tmp))
            (root / "bin").mkdir()
            (root / "bin" / "gh").write_text(STUB_GH, encoding="utf-8")
            (root / "bin" / "gh").chmod(0o755)
            (root / "co").mkdir()
            (root / "rc").write_text("0", encoding="utf-8")
            (root / "out.json").write_text(json.dumps({"headRefOid": SHA_A, "statusCheckRollup": [GREEN_RUN]}), encoding="utf-8")
            (root / "expected.json").write_text(json.dumps(
                {"repository": "o/r", "pr_number": True, "head": SHA_A}), encoding="utf-8")
            env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "STUB_DIR": str(root)}
            result = subprocess.run(
                [sys.executable, str(SPEC), "ci-capture", "--repo", str(root / "co"),
                 "--expected", str(root / "expected.json"), "--out", str(root / "ci.json")],
                capture_output=True, text=True, env=env, check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("error", json.loads(result.stdout))
            self.assertFalse((root / "argv").exists())
            self.assertFalse((root / "ci.json").exists())

    def _capture(self, root, expected, manifest_head=None, extra_out=None):
        (root / "bin").mkdir()
        (root / "bin" / "gh").write_text(STUB_GH, encoding="utf-8")
        (root / "bin" / "gh").chmod(0o755)
        (root / "co").mkdir()
        (root / "rc").write_text("0", encoding="utf-8")
        (root / "out.json").write_text(json.dumps(
            {"headRefOid": SHA_A, "statusCheckRollup": [GREEN_RUN]}), encoding="utf-8")
        (root / "expected.json").write_text(json.dumps(expected), encoding="utf-8")
        command = [sys.executable, str(SPEC), "ci-capture", "--repo", str(root / "co"),
                   "--expected", str(root / "expected.json"), "--out", str(root / "ci.json")]
        if manifest_head is not None:
            (root / "manifest.json").write_text(json.dumps(
                {"source": {"head": manifest_head}}), encoding="utf-8")
            command += ["--manifest", str(root / "manifest.json")]
        env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "STUB_DIR": str(root)}
        return subprocess.run(command, capture_output=True, text=True, env=env, check=False)

    def test_cli_capture_refuses_a_frozen_head_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(os.path.realpath(tmp))
            expected = {"repository": "o/r", "pr_number": 7, "head": SHA_A}
            (root / "ci.json").write_text("old\n", encoding="utf-8")
            result = self._capture(root, expected, manifest_head=SHA_B)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout),
                             {"error": f"frozen head {SHA_B} is not the expected head {SHA_A}"})
            self.assertFalse((root / "argv").exists())
            self.assertEqual((root / "ci.json").read_text(encoding="utf-8"), "old\n")

    def test_cli_capture_accepts_a_matching_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(os.path.realpath(tmp))
            expected = {"repository": "o/r", "pr_number": 7, "head": SHA_A}
            result = self._capture(root, expected, manifest_head=SHA_A)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((root / "argv").read_text(encoding="utf-8").splitlines(), GH_ARGV)
            self.assertTrue((root / "ci.json").exists())

    def test_cli_capture_rejects_a_bad_repository(self):
        for repository in ("not-a-repo", "a/b/c", "", 7, None):
            with self.subTest(repository=repository), tempfile.TemporaryDirectory() as tmp:
                root = Path(os.path.realpath(tmp))
                expected = {"repository": repository, "pr_number": 7, "head": SHA_A}
                result = self._capture(root, expected)
                self.assertEqual(result.returncode, 1)
                self.assertIn("error", json.loads(result.stdout))
                self.assertFalse((root / "argv").exists())
                self.assertFalse((root / "ci.json").exists())

    def test_ci_envelope_subcommand_is_retired(self):
        result = subprocess.run(
            [sys.executable, str(SPEC), "ci-envelope", "--pr-json", "x", "--head", SHA_A, "--out", "y"],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice", result.stderr)


if __name__ == "__main__":
    unittest.main()
