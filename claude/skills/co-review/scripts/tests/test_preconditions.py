"""Tests for the deterministic co-review preconditions.

These checks run before any reviewer seat and gate APPROVE only: a failure
never stops the finders, it makes an approval impossible.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SPEC = Path(__file__).resolve().parents[1] / "preconditions.py"
_spec = importlib.util.spec_from_file_location("preconditions", SPEC)
pre = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pre)

HEAD = "a" * 40
OTHER = "b" * 40


def rollup(*conclusions, head=HEAD):
    return {
        "headRefOid": head,
        "statusCheckRollup": [
            {"name": f"check{i}", "conclusion": c} for i, c in enumerate(conclusions)
        ],
    }


def diff(added_lines, path="test/hil/constants.py", start=70):
    body = "".join(f"+{line}\n" for line in added_lines)
    return (
        f"diff --git a/{path} b/{path}\n"
        f"--- a/{path}\n"
        f"+++ b/{path}\n"
        f"@@ -{start},0 +{start},{len(added_lines)} @@\n"
        f"{body}"
    )


class CiGreenForHead(unittest.TestCase):
    def test_all_success_passes(self):
        result = pre.check_ci(rollup("SUCCESS", "SUCCESS"), HEAD)
        self.assertEqual(result["status"], "PASS")

    def test_skipped_and_neutral_count_as_green(self):
        result = pre.check_ci(rollup("SUCCESS", "SKIPPED", "NEUTRAL"), HEAD)
        self.assertEqual(result["status"], "PASS")

    def test_failure_conclusion_fails(self):
        result = pre.check_ci(rollup("SUCCESS", "FAILURE"), HEAD)
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("check1", result["detail"])

    def test_timed_out_and_cancelled_fail(self):
        for conclusion in ("TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"):
            with self.subTest(conclusion=conclusion):
                result = pre.check_ci(rollup(conclusion), HEAD)
                self.assertEqual(result["status"], "FAIL")

    def test_pending_is_not_green(self):
        result = pre.check_ci(rollup("SUCCESS", None), HEAD)
        self.assertEqual(result["status"], "FAIL")

    def test_checks_for_a_different_head_fail(self):
        """A green run on an older commit is not a green run on this head."""
        result = pre.check_ci(rollup("SUCCESS", head=OTHER), HEAD)
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("different head", result["detail"])

    def test_no_checks_reported_is_skipped_not_passed(self):
        """A repo with no CI must not wedge, but the gap stays visible."""
        result = pre.check_ci(rollup(), HEAD)
        self.assertEqual(result["status"], "SKIPPED")
        self.assertIn("no checks", result["detail"].lower())

    def test_absent_payload_is_skipped(self):
        result = pre.check_ci(None, HEAD)
        self.assertEqual(result["status"], "SKIPPED")


class ProvisionalMarkers(unittest.TestCase):
    def test_clean_diff_passes(self):
        result = pre.check_markers(diff(["ENVELOPE_VBATT_MIN_V = 250.0"]))
        self.assertEqual(result["status"], "PASS")

    def test_temp_marker_in_added_line_fails_with_location(self):
        text = diff(
            ["# TEMP EDGE PROBE (run 118 follow-up)"],
            path="test/hil/envelope.py",
            start=63,
        )
        result = pre.check_markers(text)
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("test/hil/envelope.py:63", result["detail"])
        self.assertIn("TEMP", result["detail"])

    def test_revert_before_merge_phrase_is_case_insensitive(self):
        result = pre.check_markers(diff(["# Revert before merge to (250, 330)"]))
        self.assertEqual(result["status"], "FAIL")

    def test_each_marker_token_fails(self):
        for token in ("TODO", "FIXME", "XXX", "HACK"):
            with self.subTest(token=token):
                result = pre.check_markers(diff([f"# {token}: fix this"]))
                self.assertEqual(result["status"], "FAIL")

    def test_lowercase_prose_is_not_a_marker(self):
        """'temperature' and 'attempt' must not trip the TEMP token."""
        text = diff(["temperature = attempt_read()  # nominal"])
        self.assertEqual(pre.check_markers(text)["status"], "PASS")

    def test_template_is_not_a_marker(self):
        result = pre.check_markers(diff(["TEMPLATE_PATH = 'x'"]))
        self.assertEqual(result["status"], "PASS")

    def test_preexisting_marker_on_context_line_is_ignored(self):
        text = (
            "diff --git a/f.py b/f.py\n"
            "--- a/f.py\n"
            "+++ b/f.py\n"
            "@@ -1,3 +1,3 @@\n"
            " # TODO: this was already here\n"
            "+value = 1\n"
        )
        self.assertEqual(pre.check_markers(text)["status"], "PASS")

    def test_removed_marker_line_is_ignored(self):
        text = (
            "diff --git a/f.py b/f.py\n"
            "--- a/f.py\n"
            "+++ b/f.py\n"
            "@@ -1,2 +1,1 @@\n"
            "-# TEMP: going away\n"
            "+value = 1\n"
        )
        self.assertEqual(pre.check_markers(text)["status"], "PASS")

    def test_line_numbers_track_multiple_hunks(self):
        text = (
            "diff --git a/f.py b/f.py\n"
            "--- a/f.py\n"
            "+++ b/f.py\n"
            "@@ -1,1 +1,1 @@\n"
            " context\n"
            "@@ -40,0 +40,1 @@\n"
            "+# TODO: later\n"
        )
        result = pre.check_markers(text)
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("f.py:40", result["detail"])

    def test_empty_diff_is_not_a_pass(self):
        """An empty diff means the freeze produced nothing to review."""
        result = pre.check_markers("")
        self.assertEqual(result["status"], "FAIL")


class ApproveArithmetic(unittest.TestCase):
    def test_any_failure_forbids_approve(self):
        result = pre.evaluate(rollup("FAILURE"), HEAD, diff(["ok = 1"]))
        self.assertFalse(result["approve_allowed"])

    def test_all_pass_allows_approve(self):
        result = pre.evaluate(rollup("SUCCESS"), HEAD, diff(["ok = 1"]))
        self.assertTrue(result["approve_allowed"])

    def test_skipped_alone_still_allows_approve(self):
        result = pre.evaluate(None, HEAD, diff(["ok = 1"]))
        self.assertTrue(result["approve_allowed"])

    def test_every_check_is_reported_even_when_one_fails(self):
        result = pre.evaluate(rollup("FAILURE"), HEAD, diff(["# TODO: x"]))
        names = {c["name"] for c in result["checks"]}
        self.assertEqual(names, {"ci_green_for_head", "no_provisional_markers"})
        self.assertTrue(all(c["status"] == "FAIL" for c in result["checks"]))


class Cli(unittest.TestCase):
    def _run(self, checks, diff_text, head=HEAD):
        with tempfile.TemporaryDirectory() as tmp:
            diff_path = Path(tmp) / "diff.txt"
            diff_path.write_text(diff_text, encoding="utf-8")
            argv = ["--head", head, "--diff-file", str(diff_path)]
            if checks is not None:
                checks_path = Path(tmp) / "checks.json"
                checks_path.write_text(json.dumps(checks), encoding="utf-8")
                argv += ["--checks", str(checks_path)]
            proc = subprocess.run(
                [sys.executable, str(SPEC), *argv],
                capture_output=True,
                text=True,
            )
        return proc

    def test_clean_run_exits_zero_with_json(self):
        proc = self._run(rollup("SUCCESS"), diff(["ok = 1"]))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(json.loads(proc.stdout)["approve_allowed"])

    def test_failing_precondition_exits_nonzero(self):
        proc = self._run(rollup("FAILURE"), diff(["ok = 1"]))
        self.assertEqual(proc.returncode, 1)
        self.assertFalse(json.loads(proc.stdout)["approve_allowed"])

    def test_unreadable_diff_file_fails_closed(self):
        proc = subprocess.run(
            [
                sys.executable,
                str(SPEC),
                "--head",
                HEAD,
                "--diff-file",
                "/nonexistent/diff.txt",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 1)
        self.assertFalse(json.loads(proc.stdout)["approve_allowed"])

    def test_malformed_checks_json_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            diff_path = Path(tmp) / "diff.txt"
            diff_path.write_text(diff(["ok = 1"]), encoding="utf-8")
            checks_path = Path(tmp) / "checks.json"
            checks_path.write_text("{not json", encoding="utf-8")
            proc = subprocess.run(
                [
                    sys.executable,
                    str(SPEC),
                    "--head",
                    HEAD,
                    "--diff-file",
                    str(diff_path),
                    "--checks",
                    str(checks_path),
                ],
                capture_output=True,
                text=True,
            )
        self.assertEqual(proc.returncode, 1)
        self.assertFalse(json.loads(proc.stdout)["approve_allowed"])
