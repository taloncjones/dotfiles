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


TIP = "e" * 40


def marker_with(trailing, sha=SHA_A, verdict="APPROVE", rnd=1):
    """A marker whose optional trailing fields are written verbatim."""
    return (
        f"<!-- co-review: sha={sha} base={BASE_A} base_ref={REF} "
        f"verdict={verdict} round={rnd}{trailing} -->"
    )


class HistoryCurrencyTests(unittest.TestCase):
    """The floor must not narrow on a history the gate itself would reject."""

    def test_a_replayed_history_is_not_usable_for_narrowing(self):
        r1 = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        r2 = comment(
            "| y |\n" + marker(sha=SHA_B, verdict="CHANGES", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        replay = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=1),
            created_at="2026-09-11T12:00:00Z",
            cid=3,
        )
        with self.assertRaises(gate.GateInputError):
            gate.all_markers([r1, r2, replay], ME)

    def test_a_current_history_is_usable(self):
        r1 = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        r2 = comment(
            "| y |\n" + marker(sha=SHA_B, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        self.assertEqual(len(gate.all_markers([r1, r2], ME)), 2)


class ErrorsNameTheComment(unittest.TestCase):
    """The operator is told to correct a comment, so the error must name one."""

    def test_a_stale_round_names_the_later_comment(self):
        older = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd=5),
            created_at="2026-09-11T10:00:00Z",
            cid=91,
        )
        newer = comment(
            "| y |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T11:00:00Z",
            cid=92,
        )
        _, reason = gate.decide([older, newer], ME, SHA_A, BASE_A, REF)
        self.assertIn("comment 91", reason)

    def test_an_unusable_round_on_the_newest_comment_names_it(self):
        bad = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd="9" * 5000),
            created_at="2026-09-11T10:00:00Z",
            cid=77,
        )
        _, reason = gate.decide([bad], ME, SHA_A, BASE_A, REF)
        self.assertIn("comment 77", reason)

    def test_an_unusable_history_names_the_comment(self):
        bad = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd="9" * 5000),
            created_at="2026-09-11T10:00:00Z",
            cid=31,
        )
        good = comment(
            "| y |\n" + marker(verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=32,
        )
        with self.assertRaises(gate.GateInputError) as caught:
            gate.all_markers([bad, good], ME)
        self.assertIn("comment 31", str(caught.exception))

    def test_exhaustion_names_the_comment_not_the_number(self):
        at_limit = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd="9" * 4300),
            created_at="2026-09-11T10:00:00Z",
            cid=44,
        )
        with self.assertRaises(gate.GateInputError) as caught:
            gate.next_round_number([at_limit], ME)
        message = str(caught.exception)
        self.assertIn("comment 44", message)
        self.assertLess(len(message), 200)


class RoundNumberingExhaustionTests(unittest.TestCase):
    """The publisher must never emit a number its own reader refuses."""

    def test_an_unserializable_successor_fails_closed(self):
        at_limit = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd="9" * 4300),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        with self.assertRaises(gate.GateInputError):
            gate.next_round_number([at_limit], ME)


class HistoryParityTests(unittest.TestCase):
    """all_markers and select_marker must agree on what a usable history is."""

    def test_same_round_conflicting_verdicts_make_the_history_unusable(self):
        """select_marker refuses this, so the floor must not narrow on it."""
        at_a = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        at_b = comment(
            "| y |\n" + marker(sha=SHA_B, verdict="APPROVE", rnd=1),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([at_a, at_b], ME)
        with self.assertRaises(gate.GateInputError):
            gate.all_markers([at_a, at_b], ME)

    def test_a_same_round_retry_is_usable_by_both(self):
        first = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        retry = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        self.assertEqual(len(gate.all_markers([first, retry], ME)), 2)
        self.assertEqual(
            gate.decide([first, retry], ME, SHA_A, BASE_A, REF)[0], "PASS"
        )


class RoundBoundsTests(unittest.TestCase):
    """Bounding the field was tried and reverted: it let the publisher emit a
    number its own parser refused, and the unparseable marker was then skipped
    by the currency check, so a replay of the round below it passed."""

    def test_both_readers_fail_closed_on_an_unconvertible_round(self):
        huge = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd="9" * 5000),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        current = comment(
            "| y |\n" + marker(verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        self.assertEqual(gate.decide([huge, current], ME, SHA_A, BASE_A, REF)[0], "FAIL")
        with self.assertRaises(gate.GateInputError):
            gate.next_round_number([huge, current], ME)
        with self.assertRaises(gate.GateInputError):
            gate.all_markers([huge, current], ME)

    def test_a_round_past_the_old_bound_is_not_a_boundary(self):
        """9999 -> 10000 used to publish a number the parser rejected."""
        at_9999 = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=9999),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        self.assertEqual(gate.next_round_number([at_9999], ME), 10000)
        self.assertIsNotNone(gate.MARKER_RE.match(marker(rnd=10000)))

    def test_the_boundary_replay_fails_closed(self):
        a = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=9999),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        b = comment(
            "| y |\n" + marker(verdict="CHANGES", rnd=10000),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        replay = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=9999),
            created_at="2026-09-11T12:00:00Z",
            cid=3,
        )
        self.assertEqual(gate.decide([a, b, replay], ME, SHA_A, BASE_A, REF)[0], "FAIL")


class NextRoundNumberTests(unittest.TestCase):
    """The publication ordinal stays monotonic when the floor's index cannot."""

    def test_first_round_is_one(self):
        self.assertEqual(gate.next_round_number([], ME), 1)

    def test_it_follows_the_highest_claimed_round(self):
        r2 = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd=2),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        self.assertEqual(gate.next_round_number([r2], ME), 3)

    def test_it_tolerates_the_history_all_markers_refuses(self):
        """Otherwise an unreadable history wedges every later round."""
        broken = comment(
            "<!-- co-review: sha=xyz -->",
            created_at="2026-09-11T09:00:00Z",
            cid=1,
        )
        r2 = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd=2),
            created_at="2026-09-11T10:00:00Z",
            cid=2,
        )
        with self.assertRaises(gate.GateInputError):
            gate.all_markers([broken, r2], ME)
        self.assertEqual(gate.next_round_number([broken, r2], ME), 3)

    def test_untrusted_authors_do_not_advance_it(self):
        theirs = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd=9),
            author="someone",
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        self.assertEqual(gate.next_round_number([theirs], ME), 1)


class SameHeadRereviewTests(unittest.TestCase):
    """What holds a same-head re-review honest is NOT the round check.

    The published ordinal always advances, so two rounds never share one and
    the equal-round branch cannot be what guards this. The floor not moving
    (round_index_for_head returns that head's original ordinal) and the carried
    set not emptying are the actual guarantees.
    """

    def test_two_verdicts_at_one_ordinal_fail_closed(self):
        """This guards concurrent publication, not a sequential re-review."""
        changes = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        approve = comment(
            "| y |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=1),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        decision, reason = gate.decide([changes, approve], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("re-run co-review", reason)

    def test_the_next_round_clears_it_at_the_same_head(self):
        """No pushed commit is needed; the ordinal advances on its own."""
        changes = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        conflicting = comment(
            "| y |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=1),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        history = [changes, conflicting]
        self.assertEqual(gate.next_round_number(history, ME), 2)
        fresh = comment(
            "| z |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T12:00:00Z",
            cid=3,
        )
        decision, _ = gate.decide(history + [fresh], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS")

class TwoMarkerCommentTests(unittest.TestCase):
    """A comment carrying two readable markers must not hide them."""

    def test_higher_rounds_in_a_two_marker_comment_are_not_invisible(self):
        older = comment(
            "| x |\n"
            + marker(verdict="CHANGES", rnd=2)
            + "\n"
            + marker(verdict="CHANGES", rnd=3),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        newest = comment(
            "| y |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        decision, _ = gate.decide([older, newest], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")

    def test_a_truncated_comment_still_does_not_wedge(self):
        """The documented residual survives: no parsed markers, nothing compared."""
        truncated = comment(
            "<!-- co-review: sha=xyz -->",
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        current = comment(
            "| y |\n" + marker(verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        decision, _ = gate.decide([truncated, current], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS")


class RetargetRecoveryTests(unittest.TestCase):
    """A retarget is a new review of the same head, not a contradiction."""

    def test_a_fresh_review_after_retarget_fails_closed(self):
        """Deliberate. Scoping the conflict check to a matching base_ref let an
        APPROVE published late against a target the PR had returned to stop
        conflicting with the CHANGES posted against the other target between
        them. Recovery is the next round, which publishes a later ordinal -- no
        pushed commit is needed; see the same-head tests above."""
        against_main = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        against_release = comment(
            "| y |\n" + marker(verdict="APPROVE", rnd=1, base_ref="release"),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        decision, _ = gate.decide(
            [against_main, against_release], ME, SHA_A, BASE_A, "release"
        )
        self.assertEqual(decision, "FAIL")

    def test_same_target_conflicting_verdicts_still_fail_closed(self):
        changes = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        approve = comment(
            "| y |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([changes, approve], ME)


class AllMarkersTests(unittest.TestCase):
    """The floor's inputs need the whole history, not the latest marker."""

    def test_returns_every_trusted_marker_in_publication_order(self):
        first = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        second = comment(
            "| y |\n" + marker(sha=SHA_B, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        markers = gate.all_markers([second, first], ME)
        self.assertEqual([m["sha"] for m in markers], [SHA_A, SHA_B])

    def test_untrusted_authors_are_excluded(self):
        mine = comment("| x |\n" + marker(), cid=1)
        theirs = comment("| y |\n" + marker(sha=SHA_B), author="someone", cid=2)
        self.assertEqual(len(gate.all_markers([mine, theirs], ME)), 1)

    def test_an_unparsable_marker_makes_the_history_unusable(self):
        """Skipping it would let a malformed FIRST marker drop out, so the
        second would be read as the first and its baseline taken as the PR's."""
        broken = comment(
            "<!-- co-review: sha=xyz -->", created_at="2026-09-11T10:00:00Z", cid=1
        )
        good = comment(
            "| y |\n" + marker(sha=SHA_B),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        with self.assertRaises(gate.GateInputError):
            gate.all_markers([broken, good], ME)


class RepublishTests(unittest.TestCase):
    """A retry of the current round is benign; a replay of an older one is not."""

    def test_replayed_older_round_fails_closed(self):
        """Round 2 is on the PR, so the replayed round-1 APPROVE is stale."""
        r1 = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        r2 = comment(
            "| y |\n" + marker(verdict="CHANGES", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        replay = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T12:00:00Z",
            cid=3,
        )
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([r1, r2, replay], ME)

    def test_retry_of_the_current_round_stays_benign(self):
        first = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=2),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        retry = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        decision, _ = gate.decide([first, retry], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS")

    def test_an_overclaimed_round_wedges_and_says_how_to_recover(self):
        """Deliberate: a fail-closed wedge beats the fail-open it replaced.

        Bounding the claim by the comment count let a miscounted higher round
        be dismissed as noise, which let a delayed older APPROVE through.
        """
        inflated = comment(
            "| x |\n" + marker(verdict="CHANGES", rnd=9999),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        current = comment(
            "| y |\n" + marker(verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        decision, reason = gate.decide([inflated, current], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("delete that comment", reason)

    def test_a_miscounted_higher_round_is_never_dismissed_as_noise(self):
        """The fail-open this replaced: round 4 ignored, stale round 1 passes."""
        r1 = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        miscounted = comment(
            "| y |\n" + marker(verdict="CHANGES", rnd=4),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        replay = comment(
            "| x |\n" + marker(verdict="APPROVE", rnd=1),
            created_at="2026-09-11T12:00:00Z",
            cid=3,
        )
        decision, _ = gate.decide([r1, miscounted, replay], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")


class BaselineFieldTests(unittest.TestCase):
    """baseline is optional, trails target_tip, and the gate never reads it."""

    def test_baseline_alone_parses_and_is_exposed(self):
        body = "| x |\n" + marker_with(f" baseline={SHA_B}")
        self.assertEqual(
            gate.select_marker([comment(body)], ME)["baseline"], SHA_B
        )

    def test_target_tip_then_baseline_parses(self):
        body = "| x |\n" + marker_with(f" target_tip={TIP} baseline={SHA_B}")
        selected = gate.select_marker([comment(body)], ME)
        self.assertEqual(selected["target_tip"], TIP)
        self.assertEqual(selected["baseline"], SHA_B)

    def test_target_tip_only_still_parses_with_no_baseline(self):
        body = "| x |\n" + marker_with(f" target_tip={TIP}")
        selected = gate.select_marker([comment(body)], ME)
        self.assertEqual(selected["target_tip"], TIP)
        self.assertIsNone(selected["baseline"])

    def test_marker_written_before_either_field_still_parses(self):
        body = "| x |\n" + marker_with("")
        selected = gate.select_marker([comment(body)], ME)
        self.assertIsNone(selected["target_tip"])
        self.assertIsNone(selected["baseline"])

    def test_malformed_baseline_fails_closed_as_newest(self):
        """Shaped but unparsable: never skipped in favour of an older comment."""
        older = comment(
            "| x |\n" + marker_with("", verdict="APPROVE"),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        newest = comment(
            "| y |\n" + marker_with(" baseline=nothex"),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([older, newest], ME)

    def test_baseline_changes_no_gate_decision(self):
        """decide() reads verdict, sha, base and base_ref -- never baseline."""
        without = comment("| x |\n" + marker_with(""))
        with_baseline = comment("| x |\n" + marker_with(f" baseline={SHA_B}"))
        self.assertEqual(
            gate.decide([without], ME, SHA_A, BASE_A, REF),
            gate.decide([with_baseline], ME, SHA_A, BASE_A, REF),
        )


class SelectMarkerTests(unittest.TestCase):
    def test_trusted_approve_selected(self):
        body = "| x |\n" + marker()
        self.assertEqual(gate.select_marker([comment(body)], ME)["sha"], SHA_A)

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

    def test_space_tab_mixed_indent_rejected(self):
        # one space then a tab is four columns of Markdown code indentation
        self.assertIsNone(gate.select_marker([comment(" \t" + marker())], ME))

    def test_fence_close_with_suffix_keeps_marker_hidden(self):
        # "~~~x" is not a valid closing fence (non-whitespace suffix), so the
        # marker stays inside the code block and must be ignored.
        body = "~~~\n~~~still-code\n" + marker() + "\n~~~"
        self.assertIsNone(gate.select_marker([comment(body)], ME))

    def test_four_space_indented_closer_keeps_marker_hidden(self):
        # a four-space-indented fence is code content, not a closer
        body = "~~~\n    ~~~\n" + marker() + "\n~~~"
        self.assertIsNone(gate.select_marker([comment(body)], ME))

    def test_tab_indented_closer_keeps_marker_hidden(self):
        body = "~~~\n\t~~~\n" + marker() + "\n~~~"
        self.assertIsNone(gate.select_marker([comment(body)], ME))

    def test_inline_backtick_span_is_not_a_fence(self):
        # ```example``` is an inline code span (backtick info strings cannot hold
        # backticks), so a following top-level marker stays visible.
        body = "```example```\n| x |\n" + marker()
        self.assertEqual(gate.select_marker([comment(body)], ME)["sha"], SHA_A)

    def test_nbsp_closer_keeps_marker_hidden(self):
        # a non-breaking space is not Markdown fence whitespace, so "~~~ "
        # is not a valid closer and the marker stays inside the block.
        body = "~~~\n~~~ \n" + marker() + "\n~~~"
        self.assertIsNone(gate.select_marker([comment(body)], ME))

    def test_vertical_tab_is_not_a_line_break(self):
        # \v is not a Markdown line break, so "example\v<marker>" is one line and
        # the marker is not at column zero.
        body = "example\v" + marker()
        self.assertIsNone(gate.select_marker([comment(body)], ME))

    def test_malformed_marker_fails_closed(self):
        # A newest (and here, only) round comment whose marker line does not
        # parse is an error, never something to silently drop.
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([comment("<!-- co-review: sha=xyz -->")], ME)

    def test_two_markers_one_comment_fails_closed(self):
        body = marker(verdict="APPROVE") + "\n" + marker(verdict="CHANGES")
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([comment(body)], ME)

    def test_higher_round_elsewhere_fails_closed(self):
        """A round that ran later than the newest comment makes it stale.

        Selection is still by instant; the round check runs after it. Before
        this check the newest comment won outright. Every parsed, convertible
        higher round is authoritative -- the comment-count allowance that once
        dismissed unsupported rounds as noise was reverted, because it let a
        delayed older APPROVE through.
        """
        older = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        newer = comment(
            "| y |\n" + marker(sha=SHA_B, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([older, newer], ME)

    def test_delayed_replay_of_superseded_approve_fails_closed(self):
        """Round 1 APPROVE, round 2 CHANGES, then a late round-1 publish.

        The replayed APPROVE is newest and names the live head, so without the
        round check the gate passes with round 2's blockers unresolved.
        """
        round1 = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        round2 = comment(
            "| y |\n" + marker(sha=SHA_A, verdict="CHANGES", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        replay = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=1),
            created_at="2026-09-11T12:00:00Z",
            cid=3,
        )
        decision, _ = gate.decide([round1, round2, replay], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")

    def test_duplicate_publish_of_latest_round_passes(self):
        """A retry of the CURRENT round is benign: same round, same verdict."""
        first = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        retry = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        decision, _ = gate.decide([first, retry], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS")

    def test_same_round_conflicting_verdicts_fail_closed(self):
        """One round publishes one verdict; two is contradictory evidence."""
        changes = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="CHANGES", rnd=2),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        approve = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([changes, approve], ME)

    def test_truncated_older_comment_does_not_wedge_the_pr(self):
        """An unparsable OLD comment must not block a current approval.

        This is the reason the round check compares only markers that parse,
        and the reason the truncated-higher-round replay stays uncovered.
        """
        truncated = comment(
            "<!-- co-review: sha=xyz -->",
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        current = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T11:00:00Z",
            cid=2,
        )
        decision, _ = gate.decide([truncated, current], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS")

    def test_offset_timestamps_ordered_by_instant(self):
        # 09:30Z is LATER than 11:00+02:00 (== 09:00Z); lexicographic would invert.
        earlier = comment(
            "| x |\n" + marker(sha=SHA_A), created_at="2026-09-11T11:00:00+02:00", cid=1
        )
        later = comment(
            "| y |\n" + marker(sha=SHA_B), created_at="2026-09-11T09:30:00Z", cid=2
        )
        self.assertEqual(gate.select_marker([earlier, later], ME)["sha"], SHA_B)

    def test_coworker_marker_is_not_a_currency_marker(self):
        cw = (
            "<!-- co-review-coworker: sha=" + SHA_A + " base=" + BASE_A
            + " base_ref=main base_ref_tip=" + SHA_B
            + " verdict=APPROVE round=1 -->"
        )
        # The anchored currency regex must not select a coworker marker...
        self.assertIsNone(gate.select_marker([comment(cw)], ME))
        # ...and the gate must FAIL when the only marker present is a coworker one.
        verdict, _ = gate.decide([comment(cw)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(verdict, "FAIL")

    def test_missing_created_at_fails_closed(self):
        # A marker-bearing trusted comment without ordering metadata cannot be
        # placed in time; fail closed rather than silently drop it.
        bad = comment(marker(sha=SHA_A))
        del bad["created_at"]
        with self.assertRaises(gate.GateInputError):
            gate.select_marker([bad], ME)

    def test_tie_break_by_id(self):
        a = comment("| x |\n" + marker(sha=SHA_A), created_at="2026-09-11T10:00:00Z", cid=1)
        b = comment("| y |\n" + marker(sha=SHA_B), created_at="2026-09-11T10:00:00Z", cid=2)
        self.assertEqual(gate.select_marker([a, b], ME)["sha"], SHA_B)

    def test_non_list_raises(self):
        with self.assertRaises(gate.GateInputError):
            gate.select_marker({"not": "a list"}, ME)


class DecideTests(unittest.TestCase):
    def test_pass(self):
        verdict, _ = gate.decide([comment("| x |\n" + marker())], ME, SHA_A, BASE_A, REF)
        self.assertEqual(verdict, "PASS")

    def test_fail_sha_mismatch(self):
        verdict, why = gate.decide(
            [comment("| x |\n" + marker(sha=SHA_A))], ME, SHA_B, BASE_A, REF
        )
        self.assertEqual(verdict, "FAIL")
        self.assertIn("stale", why)

    def test_fail_base_mismatch(self):
        verdict, why = gate.decide(
            [comment("| x |\n" + marker(base=BASE_A))], ME, SHA_A, BASE_B, REF
        )
        self.assertEqual(verdict, "FAIL")
        self.assertIn("base", why)

    def test_fail_base_ref_mismatch_retarget(self):
        verdict, why = gate.decide(
            [comment("| x |\n" + marker(base_ref="main"))], ME, SHA_A, BASE_A, "release"
        )
        self.assertEqual(verdict, "FAIL")
        self.assertIn("retarget", why)

    def test_fail_changes(self):
        verdict, _ = gate.decide(
            [comment("| x |\n" + marker(verdict="CHANGES"))], ME, SHA_A, BASE_A, REF
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

    def test_fail_when_newer_changes_has_invalid_metadata(self):
        # older valid APPROVE + newer CHANGES with no timestamp must not revive
        # the approval: the whole decision fails closed.
        older = comment(
            marker(sha=SHA_A, verdict="APPROVE"),
            created_at="2026-09-11T09:00:00Z", cid=1,
        )
        newer = comment(marker(sha=SHA_A, verdict="CHANGES"), cid=2)
        del newer["created_at"]
        verdict, why = gate.decide([older, newer], ME, SHA_A, BASE_A, REF)
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


class FailClosedSelectionTests(unittest.TestCase):
    def test_truncated_at_colon_does_not_expose_older_approve(self):
        # Truncated one character earlier still: right at the discriminating
        # colon, with no trailing space at all. The candidate prefix must be
        # the colon-terminated form, not the marker's longer literal opening
        # (which has a trailing space before "sha="), or this one character
        # of truncation slips through as ordinary text.
        comments = [
            comment(marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1),
            comment("<!-- co-review:", created_at="2026-09-11T11:00:00Z", cid=2),
        ]
        with self.assertRaises(gate.GateInputError):
            gate.select_marker(comments, ME)
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("ambiguous or unparsable", reason)

    def test_truncated_before_sha_does_not_expose_older_approve(self):
        # Truncated so early that the prefix itself is cut mid-token ("...sh").
        # Reproduces the leak this task closes: a naive candidate check
        # derived from the marker regex loses the prefix match here and lets
        # selection fall through to the older APPROVE.
        comments = [
            comment(marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1),
            comment("<!-- co-review: sh", created_at="2026-09-11T11:00:00Z", cid=2),
        ]
        with self.assertRaises(gate.GateInputError):
            gate.select_marker(comments, ME)
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("ambiguous or unparsable", reason)

    def test_truncated_at_bare_prefix_does_not_expose_older_approve(self):
        # Truncated to exactly the literal prefix, nothing after it.
        comments = [
            comment(marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1),
            comment("<!-- co-review: ", created_at="2026-09-11T11:00:00Z", cid=2),
        ]
        with self.assertRaises(gate.GateInputError):
            gate.select_marker(comments, ME)
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("ambiguous or unparsable", reason)

    def test_truncated_latest_changes_does_not_expose_older_approve(self):
        comments = [
            comment(marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1),
            comment(
                marker(verdict="CHANGES"),  # marker only, no findings table
                created_at="2026-09-11T11:00:00Z",
                cid=2,
            ),
        ]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("findings table", reason)

    def test_two_markers_in_latest_comment_fails_closed(self):
        body = marker(verdict="CHANGES") + "\n" + marker(verdict="APPROVE")
        comments = [
            comment(marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1),
            comment("| a |\n" + body, created_at="2026-09-11T11:00:00Z", cid=2),
        ]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")

    def test_wellformed_latest_changes_supersedes_approve(self):
        comments = [
            comment("| x |\n" + marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1),
            comment("| y |\n" + marker(verdict="CHANGES"), created_at="2026-09-11T11:00:00Z", cid=2),
        ]
        decision, _ = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")

    def test_approve_with_table_passes(self):
        comments = [comment("| x |\n" + marker(), created_at="2026-09-11T10:00:00Z", cid=1)]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS", reason)

    def test_no_actionable_findings_counts_as_a_table(self):
        body = "No actionable findings.\n\n" + marker()
        comments = [comment(body, created_at="2026-09-11T10:00:00Z", cid=1)]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS", reason)

    def test_unparsable_latest_marker_does_not_fall_back_to_older_approve(self):
        # The exact fallback this task exists to prevent: the newest comment's
        # marker line does not parse at all, and an older APPROVE is present.
        comments = [
            comment("| x |\n" + marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1),
            comment("| y |\n<!-- co-review: sha=zzz -->", created_at="2026-09-11T11:00:00Z", cid=2),
        ]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("ambiguous or unparsable", reason)

    def test_fenced_table_does_not_satisfy_the_findings_requirement(self):
        body = "```\n| not | a | real | table |\n```\n" + marker()
        decision, reason = gate.decide([comment(body)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("findings table", reason)

    def test_tilde_fenced_no_findings_sentence_does_not_satisfy_it(self):
        body = "~~~\nNo actionable findings.\n~~~\n" + marker()
        decision, _ = gate.decide([comment(body)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")

    def test_indented_no_findings_sentence_does_not_satisfy_it(self):
        body = "    No actionable findings.\n\n" + marker()
        decision, reason = gate.decide([comment(body)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("findings table", reason)

    def test_indented_table_does_not_satisfy_it(self):
        body = "    | x | y |\n\n" + marker()
        decision, _ = gate.decide([comment(body)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")

    def test_non_round_comment_is_not_a_candidate(self):
        comments = [
            comment("| x |\n" + marker(), created_at="2026-09-11T10:00:00Z", cid=1),
            comment("looks good to me", created_at="2026-09-11T12:00:00Z", cid=2),
        ]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS", reason)


class TargetTipTests(unittest.TestCase):
    TIP = "e" * 40

    def _marker_with_tip(self, tip=None, verdict="APPROVE"):
        tail = f" target_tip={tip}" if tip else ""
        return (
            f"<!-- co-review: sha={SHA_A} base={BASE_A} base_ref={REF} "
            f"verdict={verdict} round=1{tail} -->"
        )

    def test_marker_without_target_tip_still_parses(self):
        got = gate.select_marker([comment("| x |\n" + self._marker_with_tip())], ME)
        self.assertIsNone(got["target_tip"])

    def test_marker_with_target_tip_parses(self):
        body = "| x |\n" + self._marker_with_tip(self.TIP)
        got = gate.select_marker([comment(body)], ME)
        self.assertEqual(got["target_tip"], self.TIP)

    def test_gate_ignores_target_tip_entirely(self):
        body = "| x |\n" + self._marker_with_tip(self.TIP)
        decision, reason = gate.decide([comment(body)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "PASS", reason)

    def test_malformed_target_tip_does_not_parse_as_a_marker(self):
        body = "| x |\n" + self._marker_with_tip("nothex")
        decision, _ = gate.decide([comment(body)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")


if __name__ == "__main__":
    unittest.main(verbosity=2)
