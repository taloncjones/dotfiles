"""Tests for frozen diff and CI preconditions."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
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

    def test_explicit_no_ci_and_marker_exceptions_are_narrow(self):
        report = self.report(
            ci={"head": SHA, "check_runs": [], "status_contexts": []},
            no_ci={"evidence": "repository has no CI"},
        )
        self.assertTrue(checks.evaluate(report, self.root)["approve_allowed"])
        diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+TODO remove\n"
        report = self.report(diff=diff)
        self.assertFalse(checks.evaluate(report, self.root)["approve_allowed"])
        report["marker_exceptions"] = [
            {
                "file": "a",
                "line": 1,
                "text": "TODO remove",
                "kind": "fixture_literal",
                "evidence": "fixture source",
                "reason": "fixture literal",
            }
        ]
        self.assertTrue(checks.evaluate(report, self.root)["approve_allowed"])

    def test_detector_literal_exception_is_exact_and_fail_closed(self):
        detector_line = SPEC.read_text(encoding="utf-8").splitlines()[11]
        diff = (
            "diff --git a/claude/skills/co-review/scripts/preconditions.py "
            "b/claude/skills/co-review/scripts/preconditions.py\n"
            "--- a/claude/skills/co-review/scripts/preconditions.py\n"
            "+++ b/claude/skills/co-review/scripts/preconditions.py\n"
            f"@@ -11,0 +12 @@\n+{detector_line}\n"
        )
        exception = {
            "file": "claude/skills/co-review/scripts/preconditions.py",
            "line": 12,
            "text": detector_line,
            "kind": "detector_literal",
            "evidence": "_MARKER_RE detector token definition",
            "reason": "detector tokens are not unfinished production work",
        }
        self.assertTrue(
            checks.evaluate(
                self.report(diff=diff, marker_exceptions=[exception]), self.root
            )["approve_allowed"]
        )
        self.assertFalse(
            checks.evaluate(self.report(diff=diff), self.root)["approve_allowed"]
        )
        partial = {key: value for key, value in exception.items() if key != "reason"}
        self.assertFalse(
            checks.evaluate(
                self.report(diff=diff, marker_exceptions=[partial]), self.root
            )["approve_allowed"]
        )
        unknown = {**exception, "kind": "detector_literal_extra"}
        self.assertFalse(
            checks.evaluate(
                self.report(diff=diff, marker_exceptions=[unknown]), self.root
            )["approve_allowed"]
        )
        non_detector_diff = (
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n"
            "+TODO unfinished production code\n"
        )
        self.assertFalse(
            checks.evaluate(
                self.report(
                    diff=non_detector_diff,
                    marker_exceptions=[
                        {
                            **exception,
                            "file": "a",
                            "line": 1,
                            "text": "TODO unfinished production code",
                        }
                    ],
                ),
                self.root,
            )["approve_allowed"]
        )
        trailing_text = (
            f"{detector_line}  # TODO restore case-sensitive handling before merge"
        )
        trailing_diff = diff.replace(detector_line, trailing_text)
        self.assertFalse(
            checks.evaluate(
                self.report(
                    diff=trailing_diff,
                    marker_exceptions=[{**exception, "text": trailing_text}],
                ),
                self.root,
            )["approve_allowed"]
        )

    def test_multiple_same_line_occurrences_need_exact_exception_and_bad_diff_fails(
        self,
    ):
        diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+TODO TODO\n"
        report = self.report(
            diff=diff,
            marker_exceptions=[
                {
                    "file": "a",
                    "line": 1,
                    "text": "TODO",
                    "kind": "fixture_literal",
                    "evidence": "fixture source",
                    "reason": "fixture",
                }
            ],
        )
        self.assertFalse(checks.evaluate(report, self.root)["approve_allowed"])
        report = self.report(diff="not a unified diff")
        self.assertFalse(checks.evaluate(report, self.root)["approve_allowed"])

    def test_truncated_added_line_hunk_fails_closed(self):
        diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n+TODO hidden by truncation\n"
        self.assertFalse(
            checks.evaluate(self.report(diff=diff), self.root)["approve_allowed"]
        )

    def test_declared_hunk_count_cannot_be_truncated(self):
        diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1,2 @@\n+one line\n"
        self.assertFalse(
            checks.evaluate(self.report(diff=diff), self.root)["approve_allowed"]
        )

    def test_metadata_only_and_empty_diff_are_valid_frozen_inputs(self):
        repo = self.root / "repo"
        repo.mkdir()
        path = repo / "x"
        path.write_text("x\n", encoding="utf-8")
        for command in (
            ["git", "init", "-q"],
            ["git", "config", "user.email", "test@example.invalid"],
            ["git", "config", "user.name", "Test"],
            ["git", "add", "x"],
            ["git", "commit", "-qm", "initial"],
        ):
            subprocess.run(command, cwd=repo, check=True)
        os.chmod(path, 0o755)
        diff = subprocess.run(
            ["git", "diff", "--", "x"],
            cwd=repo,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertTrue(
            checks.evaluate(self.report(diff=diff), self.root)["approve_allowed"]
        )
        self.assertTrue(
            checks.evaluate(self.report(diff=""), self.root)["approve_allowed"]
        )

    def test_added_plus_prefix_still_scans_provisional_marker(self):
        repo = self.root / "marker-repo"
        repo.mkdir()
        path = repo / "x"
        path.write_text("before\n", encoding="utf-8")
        for command in (
            ["git", "init", "-q"],
            ["git", "config", "user.email", "test@example.invalid"],
            ["git", "config", "user.name", "Test"],
            ["git", "add", "x"],
            ["git", "commit", "-qm", "initial"],
        ):
            subprocess.run(command, cwd=repo, check=True)
        path.write_text("++ foo // TODO unfinished\n", encoding="utf-8")
        diff = subprocess.run(
            ["git", "diff", "--", "x"],
            cwd=repo,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertFalse(
            checks.evaluate(self.report(diff=diff), self.root)["approve_allowed"]
        )

    def test_second_file_cannot_borrow_prior_hunk_context(self):
        diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+ok\ndiff --git a/b b/b\n+TODO malformed\n"
        self.assertFalse(
            checks.evaluate(self.report(diff=diff), self.root)["approve_allowed"]
        )

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

    def test_marker_exception_kind_is_limited_to_safe_literals(self):
        diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+TODO remove\n"
        report = self.report(
            diff=diff,
            marker_exceptions=[
                {
                    "file": "a",
                    "line": 1,
                    "text": "TODO remove",
                    "kind": "production_follow_up",
                    "evidence": "issue 1",
                    "reason": "later",
                }
            ],
        )
        self.assertFalse(checks.evaluate(report, self.root)["approve_allowed"])

    def test_exact_documentation_exception_can_cover_multiple_markers(self):
        text = "Example: TODO and FIXME are prohibited markers."
        diff = f"diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+{text}\n"
        report = self.report(
            diff=diff,
            marker_exceptions=[
                {
                    "file": "a",
                    "line": 1,
                    "text": text,
                    "kind": "documentation_example",
                    "evidence": "documentation section",
                    "reason": "literal example",
                }
            ],
        )
        self.assertTrue(checks.evaluate(report, self.root)["approve_allowed"])
        report["marker_exceptions"][0]["text"] = "TODO"
        self.assertFalse(checks.evaluate(report, self.root)["approve_allowed"])

    def test_exception_path_uses_git_header_name_without_tab_suffix(self):
        repo = self.root / "space-path-repo"
        repo.mkdir()
        path = repo / "guide example.txt"
        path.write_text("before\n", encoding="utf-8")
        for command in (
            ["git", "init", "-q"],
            ["git", "config", "user.email", "test@example.invalid"],
            ["git", "config", "user.name", "Test"],
            ["git", "add", path.name],
            ["git", "commit", "-qm", "initial"],
        ):
            subprocess.run(command, cwd=repo, check=True)
        text = "Example: TODO is prohibited."
        path.write_text(text + "\n", encoding="utf-8")
        diff = subprocess.run(
            ["git", "diff", "--", path.name],
            cwd=repo,
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertIn("+++ b/guide example.txt\t", diff)
        report = self.report(
            diff=diff,
            marker_exceptions=[
                {
                    "file": path.name,
                    "line": 1,
                    "text": text,
                    "kind": "documentation_example",
                    "evidence": "guide",
                    "reason": "literal example",
                }
            ],
        )
        self.assertTrue(checks.evaluate(report, self.root)["approve_allowed"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
