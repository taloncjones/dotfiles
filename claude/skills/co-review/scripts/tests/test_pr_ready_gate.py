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


class SameHeadRereviewTests(unittest.TestCase):
    """A second review of an already-reviewed head cannot flip the verdict.

    Fail-closed by choice: letting the later same-round comment win would
    reopen the replay the round check exists to close.
    """

    def test_a_second_verdict_at_the_same_head_fails_closed(self):
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
        self.assertIn("new head", reason)

    def test_the_recovery_is_a_new_head_not_a_deleted_comment(self):
        """Pushing a commit earns a new head, so the next round is round 2."""
        changes = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=1,
        )
        after_push = comment(
            "| y |\n" + marker(sha=SHA_B, verdict="APPROVE", rnd=2),
            created_at="2026-09-11T12:00:00Z",
            cid=2,
        )
        decision, _ = gate.decide([changes, after_push], ME, SHA_B, BASE_A, REF)
        self.assertEqual(decision, "PASS")


class RetargetRecoveryTests(unittest.TestCase):
    """A retarget is a new review of the same head, not a contradiction."""

    def test_a_fresh_review_after_retarget_fails_closed(self):
        """Deliberate. Scoping the conflict check to a matching base_ref let an
        APPROVE published late against a target the PR had returned to stop
        conflicting with the CHANGES posted against the other target between
        them. Recovery here is a pushed commit, which earns a fresh round."""
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
        this check the newest comment won outright. The higher round must be
        one the comment history can support, or it reads as noise instead.
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
