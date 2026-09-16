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
        self.assertFalse(cr.is_blocking("major", round_index=2, baseline_ok=True))

    def test_round_two_blocks_high_and_critical(self):
        self.assertTrue(cr.is_blocking("high", round_index=2))
        self.assertTrue(cr.is_blocking("critical", round_index=2))

    def test_round_three_blocks_critical_only(self):
        """High and major narrow only once the seat rules out a regression."""
        self.assertTrue(cr.is_blocking("critical", round_index=3))
        self.assertFalse(
            cr.is_blocking(
                "high", round_index=3, fix_regression="no", baseline_ok=True
            )
        )
        self.assertFalse(
            cr.is_blocking(
                "major", round_index=3, fix_regression="no", baseline_ok=True
            )
        )

    def test_unanswered_regression_blocks_high_at_round_three(self):
        """The default is fail-closed: no answer means the seat did not rule."""
        self.assertTrue(cr.is_blocking("high", round_index=3))

    def test_round_three_blocks_high_when_it_is_a_fix_regression(self):
        """A late round still cares about defects the fixes introduced."""
        self.assertTrue(
            cr.is_blocking("high", round_index=3, fix_regression=True)
        )

    def test_fix_regression_does_not_promote_major_or_advisory(self):
        """Only high and above block as a fix-regression."""
        self.assertFalse(
            cr.is_blocking(
                "major", round_index=3, fix_regression=True, baseline_ok=True
            )
        )
        self.assertFalse(
            cr.is_blocking(
                "minor", round_index=3, fix_regression=True, baseline_ok=True
            )
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
        self.assertFalse(
            cr.is_blocking(
                "high", round_index=9, fix_regression="no", baseline_ok=True
            )
        )
        self.assertTrue(cr.is_blocking("critical", round_index=9))

    def test_narrowing_requires_explicit_baseline_evidence(self):
        """The default is no narrowing: a forgotten guard must not fail open."""
        self.assertTrue(cr.is_blocking("major", round_index=3))
        self.assertTrue(
            cr.is_blocking("high", round_index=3, fix_regression="no")
        )
        self.assertEqual(
            cr.verdict_from_findings(
                [{"severity": "major", "fix_regression": "no"}], round_index=3
            ),
            "CHANGES",
        )

    def test_default_call_is_the_round_one_floor(self):
        """The coworker family calls the defaults and must not shift."""
        self.assertTrue(cr.is_blocking("major"))
        self.assertFalse(cr.is_blocking("minor"))
        self.assertEqual(cr.floor_for_round(1), cr.floor_for_round(None))


class RegressionVocabulary(unittest.TestCase):
    """The seat writes yes/no/unknown in a table cell, not a Python bool."""

    def test_explicit_no_is_the_only_narrowing_answer(self):
        self.assertFalse(cr.is_fix_regression("no"))
        self.assertFalse(cr.is_fix_regression("No"))
        self.assertFalse(cr.is_fix_regression(False))

    def test_unknown_and_empty_answers_fail_closed(self):
        for value in ("unknown", "", "   ", None, "yes"):
            self.assertTrue(cr.is_fix_regression(value), repr(value))

    def test_documented_no_actually_narrows_the_floor(self):
        """bool('no') is True, so truthiness made the feature inert."""
        self.assertFalse(
            cr.is_blocking(
                "high", round_index=3, fix_regression="no", baseline_ok=True
            )
        )

    def test_empty_cell_does_not_fail_open(self):
        """An unfilled Regression cell arrives as None or '', not as absent."""
        for value in (None, ""):
            self.assertTrue(
                cr.is_blocking("high", round_index=3, fix_regression=value),
                repr(value),
            )
            self.assertEqual(
                cr.verdict_from_findings(
                    [{"severity": "high", "fix_regression": value}],
                    round_index=3,
                ),
                "CHANGES",
                repr(value),
            )


class CarriedBlockers(unittest.TestCase):
    """Only the verification seat discharges a carried blocker."""

    def test_carried_blocker_survives_the_rising_floor(self):
        self.assertTrue(
            cr.is_blocking("major", round_index=3, carried=True)
        )

    def test_carried_blocker_keeps_changes_at_a_later_round(self):
        carried = [{"severity": "major", "carried": True}]
        self.assertEqual(
            cr.verdict_from_findings(carried, round_index=2), "CHANGES"
        )

    def test_an_uncarried_major_still_narrows(self):
        fresh = [{"severity": "major", "fix_regression": "no"}]
        self.assertEqual(
            cr.verdict_from_findings(fresh, round_index=2, baseline_ok=True),
            "APPROVE",
        )


class BaselineGuard(unittest.TestCase):
    """No usable baseline means no narrowing at all."""

    def test_missing_baseline_holds_the_round_one_floor(self):
        self.assertEqual(cr.floor_for_round(3, baseline_ok=False), 1)
        self.assertTrue(
            cr.is_blocking(
                "major", round_index=3, fix_regression="no", baseline_ok=False
            )
        )

    def test_verdict_does_not_narrow_without_a_baseline(self):
        findings = [{"severity": "major", "fix_regression": "no"}]
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=3, baseline_ok=False),
            "CHANGES",
        )


HEAD_1, HEAD_2, HEAD_3, HEAD_4 = ("1" * 40, "2" * 40, "3" * 40, "4" * 40)


class RoundIndexFromHeads(unittest.TestCase):
    """The floor narrows once per distinct reviewed head, not per comment."""

    def test_first_review_is_round_one(self):
        self.assertEqual(cr.round_index_for_head([], HEAD_1), 1)

    def test_a_new_head_advances_the_round(self):
        priors = [{"sha": HEAD_1}]
        self.assertEqual(cr.round_index_for_head(priors, HEAD_2), 2)

    def test_re_reviewing_an_unchanged_head_does_not_advance(self):
        """Otherwise a major clears by spending one more round on no fix."""
        priors = [{"sha": HEAD_1}]
        self.assertEqual(cr.round_index_for_head(priors, HEAD_1), 1)

    def test_a_publish_retry_does_not_advance(self):
        priors = [{"sha": HEAD_1}, {"sha": HEAD_1}]
        self.assertEqual(cr.round_index_for_head(priors, HEAD_2), 2)

    def test_unusable_shas_are_ignored(self):
        priors = [{"sha": None}, {}, {"sha": ""}, {"sha": "nothex"}, {"sha": HEAD_1}]
        self.assertEqual(cr.round_index_for_head(priors, HEAD_2), 2)


class CarriedVocabulary(unittest.TestCase):
    """Same table, same yes/no cell, same trap as the Regression column."""

    def test_explicit_no_clears_carried(self):
        self.assertFalse(cr.is_carried("no"))
        self.assertFalse(cr.is_carried(False))

    def test_everything_else_stays_carried(self):
        for value in ("yes", "unknown", "", True):
            self.assertTrue(cr.is_carried(value), repr(value))

    def test_a_no_cell_does_not_make_every_row_carried(self):
        """bool("no") is True, which would disable the floor entirely."""
        self.assertEqual(
            cr.verdict_from_findings([{"severity": "minor", "carried": "no"}]),
            "APPROVE",
        )

    def test_the_floor_still_narrows_with_a_no_cell(self):
        findings = [
            {"severity": "major", "fix_regression": "no", "carried": "no"}
        ]
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=3, baseline_ok=True),
            "APPROVE",
        )

    def test_a_carried_yes_cell_still_blocks(self):
        self.assertEqual(
            cr.verdict_from_findings([{"severity": "minor", "carried": "yes"}]),
            "CHANGES",
        )


class DischargedRows(unittest.TestCase):
    """The table keeps discharged rows; the verdict must not count them."""

    def test_a_resolved_carried_row_stops_blocking(self):
        row = [{"severity": "major", "carried": "yes", "status": "RESOLVED"}]
        self.assertEqual(
            cr.verdict_from_findings(row, round_index=2, baseline_ok=True),
            "APPROVE",
        )

    def test_an_open_carried_row_still_blocks(self):
        row = [{"severity": "major", "carried": "yes", "status": "open"}]
        self.assertEqual(
            cr.verdict_from_findings(row, round_index=2, baseline_ok=True),
            "CHANGES",
        )

    def test_a_disputed_carried_row_still_blocks(self):
        row = [{"severity": "major", "carried": "yes", "status": "disputed"}]
        self.assertEqual(
            cr.verdict_from_findings(row, round_index=2, baseline_ok=True),
            "CHANGES",
        )


class StrictBaselineFlag(unittest.TestCase):
    """baseline_ok is the sole gate on narrowing, so truthy is not enough."""

    def test_only_the_literal_true_narrows(self):
        for value in ("no", "unknown", "yes", 1, [1]):
            self.assertEqual(cr.floor_for_round(3, baseline_ok=value), 1, repr(value))
        self.assertEqual(cr.floor_for_round(3, baseline_ok=True), 3)


class UnusableHead(unittest.TestCase):
    def test_an_unusable_head_takes_the_strictest_index(self):
        priors = [{"sha": "1" * 40}, {"sha": "2" * 40}]
        for head in (None, "nothex", ""):
            self.assertEqual(cr.round_index_for_head(priors, head), 1, repr(head))


class BaselineProducer(unittest.TestCase):
    """The guard has a producer, so it is not agent hand-work."""

    def test_no_markers_means_no_narrowing(self):
        self.assertFalse(cr.baseline_ok_from_markers([]))

    def test_first_marker_without_a_baseline_means_no_narrowing(self):
        self.assertFalse(cr.baseline_ok_from_markers([{"baseline": None}]))
        self.assertFalse(cr.baseline_ok_from_markers([{"baseline": "nothex"}]))

    def test_agreeing_markers_permit_narrowing(self):
        markers = [
            {"sha": "1" * 40, "baseline": "1" * 40},
            {"baseline": "1" * 40},
        ]
        self.assertTrue(cr.baseline_ok_from_markers(markers))

    def test_a_baseline_that_is_not_the_first_reviewed_head_is_rejected(self):
        """Agreement alone would accept a baseline past the real start, and a
        regression introduced after it would classify as pre-existing."""
        markers = [
            {"sha": "1" * 40, "baseline": "2" * 40},
            {"baseline": "2" * 40},
        ]
        self.assertFalse(cr.baseline_ok_from_markers(markers))

    def test_a_later_marker_disagreeing_means_no_narrowing(self):
        markers = [{"baseline": "1" * 40}, {"baseline": "2" * 40}]
        self.assertFalse(cr.baseline_ok_from_markers(markers))

    def test_a_later_marker_dropping_it_means_no_narrowing(self):
        markers = [{"baseline": "1" * 40}, {}]
        self.assertFalse(cr.baseline_ok_from_markers(markers))


class UnusableRoundIndex(unittest.TestCase):
    def test_infinity_fails_closed_instead_of_raising(self):
        """The docstring promises a floor for an unusable index, not a crash."""
        self.assertEqual(cr.floor_for_round(float("inf"), baseline_ok=True), 1)

    def test_nan_fails_closed(self):
        self.assertEqual(cr.floor_for_round(float("nan"), baseline_ok=True), 1)


class RolledBackHead(unittest.TestCase):
    """A head keeps the ordinal of the round that first reviewed it."""

    def test_returning_to_an_earlier_head_restores_its_round(self):
        priors = [{"sha": HEAD_1}, {"sha": HEAD_2}, {"sha": HEAD_3}]
        self.assertEqual(cr.round_index_for_head(priors, HEAD_1), 1)

    def test_a_rollback_does_not_inherit_a_looser_floor(self):
        """Rounds that only examined B and C must not narrow a finding on A."""
        priors = [{"sha": HEAD_1}, {"sha": HEAD_2}, {"sha": HEAD_3}]
        index = cr.round_index_for_head(priors, HEAD_1)
        self.assertTrue(
            cr.is_blocking(
                "major", round_index=index, fix_regression="no", baseline_ok=True
            )
        )

    def test_a_genuinely_new_head_still_advances(self):
        priors = [{"sha": HEAD_1}, {"sha": HEAD_2}, {"sha": HEAD_3}]
        self.assertEqual(cr.round_index_for_head(priors, HEAD_4), 4)


class CoworkerSelectionUnaffected(unittest.TestCase):
    """Change A's round contract belongs to co-review, not this family."""

    def _cw(self, verdict, rnd):
        return (
            f"<!-- co-review-coworker: sha={'a' * 40} base={'c' * 40} "
            f"base_ref=main base_ref_tip={'e' * 40} verdict={verdict} "
            f"round={rnd} -->"
        )

    def test_same_round_differing_verdicts_still_selects(self):
        older = {
            "author": "me", "created_at": "2026-09-11T10:00:00Z", "id": 1,
            "body": self._cw("CHANGES", 1),
        }
        newer = {
            "author": "me", "created_at": "2026-09-11T11:00:00Z", "id": 2,
            "body": self._cw("APPROVE", 1),
        }
        selected = cr.select_coworker_marker([older, newer], {"me"})
        self.assertEqual(selected["verdict"], "APPROVE")

    def test_a_lower_newer_round_still_selects(self):
        older = {
            "author": "me", "created_at": "2026-09-11T10:00:00Z", "id": 1,
            "body": self._cw("CHANGES", 5),
        }
        newer = {
            "author": "me", "created_at": "2026-09-11T11:00:00Z", "id": 2,
            "body": self._cw("APPROVE", 2),
        }
        selected = cr.select_coworker_marker([older, newer], {"me"})
        self.assertEqual(selected["round"], "2")


class ProgressiveFloorVerdict(unittest.TestCase):
    def test_major_only_approves_from_round_two(self):
        findings = [{"severity": "major", "fix_regression": False}]
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=1, baseline_ok=True),
            "CHANGES",
        )
        self.assertEqual(
            cr.verdict_from_findings(findings, round_index=2, baseline_ok=True),
            "APPROVE",
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
            cr.verdict_from_findings(findings, round_index=3, baseline_ok=True),
            "APPROVE",
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
