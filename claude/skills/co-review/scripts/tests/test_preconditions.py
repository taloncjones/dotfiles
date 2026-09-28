"""Tests for frozen diff and CI preconditions."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SPEC = Path(__file__).resolve().parents[1] / "preconditions.py"
_spec = importlib.util.spec_from_file_location("preconditions", SPEC)
checks = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(checks)
SHA = "a" * 40


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PreconditionsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def report(
        self,
        diff="diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+ok\n",
        ci=None,
        **extra,
    ):
        diff_path = self.root / "frozen.diff"
        ci_path = self.root / "ci.json"
        diff_path.write_text(diff, encoding="utf-8")
        ci_path.write_text(
            json.dumps(
                ci
                if ci is not None
                else {
                    "head": SHA,
                    "check_runs": [{"status": "COMPLETED", "conclusion": "SUCCESS"}],
                    "status_contexts": [],
                }
            ),
            encoding="utf-8",
        )
        return {
            "head": SHA,
            "tree": SHA,
            "diff": {"artifact": "frozen.diff", "sha256": digest(diff_path)},
            "ci": {"artifact": "ci.json", "sha256": digest(ci_path)},
            **extra,
        }

    def test_check_run_and_status_context_success_pass(self):
        for ci in (
            {
                "head": SHA,
                "check_runs": [{"status": "COMPLETED", "conclusion": "SUCCESS"}],
                "status_contexts": [],
            },
            {"head": SHA, "check_runs": [], "status_contexts": [{"state": "SUCCESS"}]},
        ):
            self.assertTrue(
                checks.evaluate(self.report(ci=ci), self.root)["approve_allowed"]
            )

    def test_failing_pending_missing_and_neutral_ci_fail_closed(self):
        for ci in (
            {
                "head": SHA,
                "check_runs": [{"status": "COMPLETED", "conclusion": "FAILURE"}],
                "status_contexts": [],
            },
            {
                "head": SHA,
                "check_runs": [{"status": "IN_PROGRESS", "conclusion": None}],
                "status_contexts": [],
            },
            {},
            {
                "head": SHA,
                "check_runs": [{"status": "COMPLETED", "conclusion": "NEUTRAL"}],
                "status_contexts": [],
            },
        ):
            self.assertFalse(
                checks.evaluate(self.report(ci=ci), self.root)["approve_allowed"]
            )

    def test_completed_skipped_check_run_is_accepted_but_neutral_still_fails(self):
        ci_skipped = {
            "head": SHA,
            "check_runs": [
                {"status": "COMPLETED", "conclusion": "SUCCESS"},
                {"status": "COMPLETED", "conclusion": "SKIPPED"},
            ],
            "status_contexts": [],
        }
        result = checks.evaluate(self.report(ci=ci_skipped), self.root)
        self.assertEqual(result["reasons"], [])
        self.assertTrue(result["approve_allowed"])

        ci_neutral = {
            "head": SHA,
            "check_runs": [{"status": "COMPLETED", "conclusion": "NEUTRAL"}],
            "status_contexts": [],
        }
        result = checks.evaluate(self.report(ci=ci_neutral), self.root)
        self.assertFalse(result["approve_allowed"])

    def test_explicit_no_ci_allows_empty_captured_checks(self):
        report = self.report(
            ci={"head": SHA, "check_runs": [], "status_contexts": []},
            no_ci={"evidence": "repository has no CI"},
        )
        self.assertTrue(checks.evaluate(report, self.root)["approve_allowed"])

    def test_diff_content_does_not_change_a_valid_artifact_outcome(self):
        ordinary_text = (
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n"
            "+TODO is ordinary reviewed text\n"
        )
        ordinary = checks.evaluate(self.report(diff=ordinary_text), self.root)
        binary_report = self.report()
        binary_path = self.root / "frozen.diff"
        binary_path.write_bytes(b"GIT binary patch\nliteral 4\n\xffTODO\x00\n")
        binary_report["diff"] = {
            "artifact": "frozen.diff",
            "sha256": digest(binary_path),
        }
        binary = checks.evaluate(binary_report, self.root)
        self.assertEqual(ordinary, binary)
        self.assertTrue(ordinary["approve_allowed"])

    def test_bad_or_missing_artifacts_and_ci_remain_fail_closed(self):
        report = self.report()
        report["diff"]["sha256"] = "0" * 64
        self.assertFalse(checks.evaluate(report, self.root)["approve_allowed"])

        report = self.report()
        (self.root / "frozen.diff").unlink()
        self.assertFalse(checks.evaluate(report, self.root)["approve_allowed"])

        report = self.report(
            ci={
                "head": SHA,
                "check_runs": [{"status": "COMPLETED", "conclusion": "FAILURE"}],
                "status_contexts": [],
            }
        )
        self.assertFalse(checks.evaluate(report, self.root)["approve_allowed"])

    def test_ci_head_and_collections_must_be_captured_for_this_head(self):
        stale = {
            "head": "b" * 40,
            "check_runs": [{"status": "COMPLETED", "conclusion": "SUCCESS"}],
            "status_contexts": [],
        }
        self.assertFalse(
            checks.evaluate(self.report(ci=stale), self.root)["approve_allowed"]
        )
        mismatched_check = {
            "head": SHA,
            "check_runs": [
                {
                    "status": "COMPLETED",
                    "conclusion": "SUCCESS",
                    "head_sha": "b" * 40,
                }
            ],
            "status_contexts": [],
        }
        self.assertFalse(
            checks.evaluate(self.report(ci=mismatched_check), self.root)[
                "approve_allowed"
            ]
        )
        missing = {"head": SHA, "check_runs": []}
        self.assertFalse(
            checks.evaluate(self.report(ci=missing), self.root)["approve_allowed"]
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
