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


class ProgressiveFloor(unittest.TestCase):
    """The bar to block rises with the round index."""

    def test_round_one_blocks_major(self):
        self.assertTrue(cr.is_blocking("major", round_index=1))

    def test_round_two_does_not_block_major(self):
        self.assertFalse(cr.is_blocking("major", round_index=2))

    def test_round_two_blocks_high_and_critical(self):
        self.assertTrue(cr.is_blocking("high", round_index=2))
        self.assertTrue(cr.is_blocking("critical", round_index=2))

    def test_round_three_blocks_critical_only(self):
        self.assertTrue(cr.is_blocking("critical", round_index=3))
        self.assertFalse(cr.is_blocking("high", round_index=3))
        self.assertFalse(cr.is_blocking("major", round_index=3))

    def test_round_three_blocks_high_when_it_is_a_fix_regression(self):
        """A late round still cares about defects the fixes introduced."""
        self.assertTrue(
            cr.is_blocking("high", round_index=3, fix_regression=True)
        )

    def test_fix_regression_does_not_promote_major_or_advisory(self):
        """Only high and above block as a fix-regression."""
        self.assertFalse(
            cr.is_blocking("major", round_index=3, fix_regression=True)
        )
        self.assertFalse(
            cr.is_blocking("minor", round_index=3, fix_regression=True)
        )

    def test_unrecognized_severity_blocks_at_every_round(self):
        for rnd in (1, 2, 3, 9):
            self.assertTrue(cr.is_blocking("weird", round_index=rnd), rnd)
            self.assertTrue(cr.is_blocking(None, round_index=rnd), rnd)

    def test_unusable_round_index_falls_back_to_the_strictest_floor(self):
        """An unknown round must not silently stop blocking on real defects."""
        for rnd in (None, "x", 0, -1):
            self.assertTrue(cr.is_blocking("major", round_index=rnd), rnd)

    def test_later_rounds_keep_the_final_floor(self):
        self.assertFalse(cr.is_blocking("high", round_index=9))
        self.assertTrue(cr.is_blocking("critical", round_index=9))

    def test_default_call_is_the_round_one_floor(self):
        """The coworker family calls the defaults and must not shift."""
        self.assertTrue(cr.is_blocking("major"))
        self.assertFalse(cr.is_blocking("minor"))
        self.assertEqual(cr.floor_for_round(1), cr.floor_for_round(None))


class ProgressiveFloorVerdict(unittest.TestCase):
    def test_major_only_approves_from_round_two(self):
        findings = [{"severity": "major", "fix_regression": False}]
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=1), "CHANGES"
        )
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=2), "APPROVE"
        )

    def test_unclassified_high_blocks_at_round_three(self):
        """No 'fix_regression' means the seat could not rule; that blocks."""
        findings = [{"severity": "high"}]
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=3), "CHANGES"
        )

    def test_confirmed_pre_existing_high_does_not_block_at_round_three(self):
        findings = [{"severity": "high", "fix_regression": False}]
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=3), "APPROVE"
        )

    def test_confirmed_regression_high_blocks_at_round_three(self):
        findings = [{"severity": "high", "fix_regression": True}]
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=3), "CHANGES"
        )


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
            cr.decide_review_scope(None, SHA_NEW, "main", TIP_OLD, True), ("full", None)
        )

    def test_equal_head_is_full(self):
        # is_ancestor is True for identical commits; equal-head must still be full.
        self.assertEqual(
            cr.decide_review_scope(prev(sha=SHA_NEW), SHA_NEW, "main", TIP_OLD, True),
            ("full", None),
        )

    def test_non_ancestor_is_full(self):
        self.assertEqual(
            cr.decide_review_scope(prev(), SHA_NEW, "main", TIP_OLD, False), ("full", None)
        )

    def test_moved_base_is_full(self):
        self.assertEqual(
            cr.decide_review_scope(prev(tip=TIP_OLD), SHA_NEW, "main", TIP_NEW, True),
            ("full", None),
        )

    def test_retargeted_base_ref_is_full(self):
        # Base branch changed (e.g. PR retargeted main -> release), even
        # though tip and ancestry would otherwise allow incremental.
        self.assertEqual(
            cr.decide_review_scope(prev(), SHA_NEW, "release", TIP_OLD, True),
            ("full", None),
        )

    def test_incremental(self):
        self.assertEqual(
            cr.decide_review_scope(prev(), SHA_NEW, "main", TIP_OLD, True),
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

    def test_own_pr_currency_marker_not_selected(self):
        # Symmetric isolation guard: the pr-ready currency marker format
        # ('co-review: ...') must never be picked up as a coworker marker,
        # even from a trusted author.
        text = (
            "<!-- co-review: sha=" + "a" * 40 + " base=" + "c" * 40 +
            " base_ref=main verdict=APPROVE round=1 -->"
        )
        got = cr.select_coworker_marker(
            [{"author": "me", "created_at": "2026-09-11T00:00:00Z", "id": 1, "body": text}],
            {"me"},
        )
        self.assertIsNone(got)


if __name__ == "__main__":
    unittest.main()
