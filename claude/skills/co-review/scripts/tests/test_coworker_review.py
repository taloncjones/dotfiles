"""Tests for coworker_review pure core."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "coworker_review.py"
_spec = importlib.util.spec_from_file_location("coworker_review", SRC)
cr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cr)

SHA_OLD, SHA_NEW = "a" * 40, "b" * 40
BASE = "c" * 40
TIP_OLD, TIP_NEW = "d" * 40, "e" * 40


def prev(sha=SHA_OLD, tip=TIP_OLD):
    return {
        "sha": sha, "base": BASE, "base_ref": "main",
        "base_ref_tip": tip, "verdict": "CHANGES", "round": "1",
    }


class IsBlocking(unittest.TestCase):
    def test_major_family_blocks(self):
        for sev in ("major", "high", "critical", "MAJOR"):
            self.assertTrue(cr.is_blocking(sev), sev)

    def test_advisory_family_does_not_block(self):
        for sev in ("minor", "low", "nit", "advisory"):
            self.assertFalse(cr.is_blocking(sev), sev)

    def test_unknown_or_missing_blocks_fail_closed(self):
        self.assertTrue(cr.is_blocking("weird"))
        self.assertTrue(cr.is_blocking(None))
        self.assertTrue(cr.is_blocking(""))


class Verdict(unittest.TestCase):
    def test_empty_is_approve(self):
        self.assertEqual(cr.verdict_from_findings([]), "APPROVE")

    def test_advisory_only_is_approve(self):
        findings = [{"severity": "minor"}, {"severity": "nit"}]
        self.assertEqual(cr.verdict_from_findings(findings), "APPROVE")

    def test_any_major_is_changes(self):
        findings = [{"severity": "minor"}, {"severity": "major"}]
        self.assertEqual(cr.verdict_from_findings(findings), "CHANGES")

    def test_missing_severity_fails_closed_to_changes(self):
        # A finding with no severity must never silently APPROVE.
        self.assertEqual(cr.verdict_from_findings([{}]), "CHANGES")


class Scope(unittest.TestCase):
    def test_no_prior_marker_is_full(self):
        self.assertEqual(
            cr.decide_review_scope(None, SHA_NEW, TIP_OLD, True), ("full", None)
        )

    def test_equal_head_is_full(self):
        # is_ancestor is True for identical commits; equal-head must still be full.
        self.assertEqual(
            cr.decide_review_scope(prev(sha=SHA_NEW), SHA_NEW, TIP_OLD, True),
            ("full", None),
        )

    def test_non_ancestor_is_full(self):
        self.assertEqual(
            cr.decide_review_scope(prev(), SHA_NEW, TIP_OLD, False), ("full", None)
        )

    def test_moved_base_is_full(self):
        self.assertEqual(
            cr.decide_review_scope(prev(tip=TIP_OLD), SHA_NEW, TIP_NEW, True),
            ("full", None),
        )

    def test_incremental(self):
        self.assertEqual(
            cr.decide_review_scope(prev(), SHA_NEW, TIP_OLD, True),
            ("incremental", (SHA_OLD, SHA_NEW)),
        )


class Marker(unittest.TestCase):
    def test_roundtrip(self):
        text = cr.build_marker(SHA_OLD, BASE, "main", TIP_OLD, "CHANGES", 2)
        got = cr.select_coworker_marker(
            [{"author": "me", "created_at": "2026-09-11T00:00:00Z", "id": 1, "body": text}],
            {"me"},
        )
        self.assertEqual(got["sha"], SHA_OLD)
        self.assertEqual(got["base_ref_tip"], TIP_OLD)
        self.assertEqual(got["verdict"], "CHANGES")

    def test_untrusted_author_ignored(self):
        text = cr.build_marker(SHA_OLD, BASE, "main", TIP_OLD, "CHANGES", 2)
        got = cr.select_coworker_marker(
            [{"author": "them", "created_at": "2026-09-11T00:00:00Z", "id": 1, "body": text}],
            {"me"},
        )
        self.assertIsNone(got)


if __name__ == "__main__":
    unittest.main()
