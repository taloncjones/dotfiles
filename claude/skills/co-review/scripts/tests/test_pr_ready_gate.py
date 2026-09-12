"""Tests for co-review marker parsing and PR-ready currency decision."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import unittest
from pathlib import Path

SPEC = Path(__file__).resolve().parents[1] / "pr_ready_gate.py"
_spec = importlib.util.spec_from_file_location("pr_ready_gate", SPEC)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

SHA_A, SHA_B = "a" * 40, "b" * 40
BASE_A, BASE_B = "c" * 40, "d" * 40
REF = "main"
ME = {"me"}


def marker(sha=SHA_A, base=BASE_A, base_ref=REF, verdict="APPROVE", rnd=1):
    return (
        f"<!-- co-review: sha={sha} base={base} base_ref={base_ref} "
        f"verdict={verdict} round={rnd} -->"
    )


def comment(body, author="me", created_at="2026-09-11T10:00:00Z", cid=1):
    return {"author": author, "created_at": created_at, "id": cid, "body": body}


class SelectMarkerTests(unittest.TestCase):
    def test_trusted_approve_selected(self):
        self.assertEqual(gate.select_marker([comment(marker())], ME)["sha"], SHA_A)

    def test_other_author_ignored(self):
        self.assertIsNone(gate.select_marker([comment(marker(), author="x")], ME))

    def test_quoted_rejected(self):
        self.assertIsNone(gate.select_marker([comment("> " + marker())], ME))

    def test_backtick_fenced_rejected(self):
        body = "```\n" + marker() + "\n```"
        self.assertIsNone(gate.select_marker([comment(body)], ME))

    def test_tilde_fenced_rejected(self):
        body = "~~~\n" + marker() + "\n~~~"
        self.assertIsNone(gate.select_marker([comment(body)], ME))

    def test_indented_code_rejected(self):
        self.assertIsNone(gate.select_marker([comment("    " + marker())], ME))

    def test_malformed_ignored(self):
        self.assertIsNone(
            gate.select_marker([comment("<!-- co-review: sha=xyz -->")], ME)
        )

    def test_two_markers_one_comment_rejected(self):
        body = marker(verdict="APPROVE") + "\n" + marker(verdict="CHANGES")
        self.assertIsNone(gate.select_marker([comment(body)], ME))

    def test_latest_by_instant_not_round(self):
        older = comment(
            marker(sha=SHA_A, verdict="APPROVE", rnd=5),
            created_at="2026-09-11T09:00:00Z", cid=1,
        )
        newer = comment(
            marker(sha=SHA_B, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z", cid=2,
        )
        self.assertEqual(gate.select_marker([older, newer], ME)["verdict"], "CHANGES")

    def test_offset_timestamps_ordered_by_instant(self):
        # 09:30Z is LATER than 11:00+02:00 (== 09:00Z); lexicographic would invert.
        earlier = comment(
            marker(sha=SHA_A), created_at="2026-09-11T11:00:00+02:00", cid=1
        )
        later = comment(marker(sha=SHA_B), created_at="2026-09-11T09:30:00Z", cid=2)
        self.assertEqual(gate.select_marker([earlier, later], ME)["sha"], SHA_B)

    def test_missing_created_at_dropped(self):
        bad = comment(marker(sha=SHA_A))
        del bad["created_at"]
        self.assertIsNone(gate.select_marker([bad], ME))

    def test_tie_break_by_id(self):
        a = comment(marker(sha=SHA_A), created_at="2026-09-11T10:00:00Z", cid=1)
        b = comment(marker(sha=SHA_B), created_at="2026-09-11T10:00:00Z", cid=2)
        self.assertEqual(gate.select_marker([a, b], ME)["sha"], SHA_B)

    def test_non_list_raises(self):
        with self.assertRaises(gate.GateInputError):
            gate.select_marker({"not": "a list"}, ME)


class DecideTests(unittest.TestCase):
    def test_pass(self):
        verdict, _ = gate.decide([comment(marker())], ME, SHA_A, BASE_A, REF)
        self.assertEqual(verdict, "PASS")

    def test_fail_sha_mismatch(self):
        verdict, why = gate.decide([comment(marker(sha=SHA_A))], ME, SHA_B, BASE_A, REF)
        self.assertEqual(verdict, "FAIL")
        self.assertIn("stale", why)

    def test_fail_base_mismatch(self):
        verdict, why = gate.decide(
            [comment(marker(base=BASE_A))], ME, SHA_A, BASE_B, REF
        )
        self.assertEqual(verdict, "FAIL")
        self.assertIn("base", why)

    def test_fail_base_ref_mismatch_retarget(self):
        verdict, why = gate.decide(
            [comment(marker(base_ref="main"))], ME, SHA_A, BASE_A, "release"
        )
        self.assertEqual(verdict, "FAIL")
        self.assertIn("retarget", why)

    def test_fail_changes(self):
        verdict, _ = gate.decide(
            [comment(marker(verdict="CHANGES"))], ME, SHA_A, BASE_A, REF
        )
        self.assertEqual(verdict, "FAIL")

    def test_fail_no_marker(self):
        verdict, why = gate.decide([], ME, SHA_A, BASE_A, REF)
        self.assertEqual(verdict, "FAIL")
        self.assertIn("run co-review", why)

    def test_fail_bad_input_container(self):
        verdict, why = gate.decide("nope", ME, SHA_A, BASE_A, REF)
        self.assertEqual(verdict, "FAIL")
        self.assertIn("fail closed", why)


class CliTests(unittest.TestCase):
    def test_unreadable_comments_file_fails_closed(self):
        result = subprocess.run(
            [
                sys.executable, str(SPEC), "--comments", "/nonexistent.json",
                "--head", SHA_A, "--base", BASE_A, "--base-ref", REF,
                "--trusted-author", "me",
            ],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("fail closed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
