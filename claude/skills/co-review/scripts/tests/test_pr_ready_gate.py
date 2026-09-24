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

    def test_latest_by_instant_not_round(self):
        older = comment(
            "| x |\n" + marker(sha=SHA_A, verdict="APPROVE", rnd=5),
            created_at="2026-09-11T09:00:00Z",
            cid=1,
        )
        newer = comment(
            "| y |\n" + marker(sha=SHA_B, verdict="CHANGES", rnd=1),
            created_at="2026-09-11T10:00:00Z",
            cid=2,
        )
        self.assertEqual(gate.select_marker([older, newer], ME)["verdict"], "CHANGES")

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
            "<!-- co-review-coworker: sha="
            + SHA_A
            + " base="
            + BASE_A
            + " base_ref=main base_ref_tip="
            + SHA_B
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

    def test_graphql_node_id_fails_closed_and_rest_id_selects(self):
        # gh api graphql returns string node ids; the REST comments endpoint
        # returns the integer ids selection needs to order same-second rounds.
        body = "| x |\n" + marker(sha=SHA_A)
        with self.assertRaisesRegex(gate.GateInputError, "invalid created_at/id"):
            gate.select_marker([comment(body, cid="IC_kwDOABCDEF")], ME)
        self.assertEqual(gate.select_marker([comment(body, cid=42)], ME)["sha"], SHA_A)

    def test_tie_break_by_id(self):
        a = comment(
            "| x |\n" + marker(sha=SHA_A), created_at="2026-09-11T10:00:00Z", cid=1
        )
        b = comment(
            "| y |\n" + marker(sha=SHA_B), created_at="2026-09-11T10:00:00Z", cid=2
        )
        self.assertEqual(gate.select_marker([a, b], ME)["sha"], SHA_B)

    def test_non_list_raises(self):
        with self.assertRaises(gate.GateInputError):
            gate.select_marker({"not": "a list"}, ME)


class DecideTests(unittest.TestCase):
    def test_comment_history_never_grants_ready(self):
        verdict, _ = gate.decide(
            [comment("| x |\n" + marker())], ME, SHA_A, BASE_A, REF
        )
        self.assertEqual(verdict, "FAIL")

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
            created_at="2026-09-11T09:00:00Z",
            cid=1,
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
                sys.executable,
                str(SPEC),
                "--comments",
                "/nonexistent.json",
                "--head",
                SHA_A,
                "--base",
                BASE_A,
                "--base-ref",
                REF,
                "--trusted-author",
                "me",
            ],
            capture_output=True,
            text=True,
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
            comment(
                marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1
            ),
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
            comment(
                marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1
            ),
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
            comment(
                marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1
            ),
            comment("<!-- co-review: ", created_at="2026-09-11T11:00:00Z", cid=2),
        ]
        with self.assertRaises(gate.GateInputError):
            gate.select_marker(comments, ME)
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")
        self.assertIn("ambiguous or unparsable", reason)

    def test_truncated_latest_changes_does_not_expose_older_approve(self):
        comments = [
            comment(
                marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1
            ),
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
            comment(
                marker(verdict="APPROVE"), created_at="2026-09-11T10:00:00Z", cid=1
            ),
            comment("| a |\n" + body, created_at="2026-09-11T11:00:00Z", cid=2),
        ]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")

    def test_wellformed_latest_changes_supersedes_approve(self):
        comments = [
            comment(
                "| x |\n" + marker(verdict="APPROVE"),
                created_at="2026-09-11T10:00:00Z",
                cid=1,
            ),
            comment(
                "| y |\n" + marker(verdict="CHANGES"),
                created_at="2026-09-11T11:00:00Z",
                cid=2,
            ),
        ]
        decision, _ = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")

    def test_approve_with_table_still_fails(self):
        comments = [
            comment("| x |\n" + marker(), created_at="2026-09-11T10:00:00Z", cid=1)
        ]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL", reason)

    def test_no_actionable_findings_still_fails(self):
        body = "No actionable findings.\n\n" + marker()
        comments = [comment(body, created_at="2026-09-11T10:00:00Z", cid=1)]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL", reason)

    def test_unparsable_latest_marker_does_not_fall_back_to_older_approve(self):
        # The exact fallback this task exists to prevent: the newest comment's
        # marker line does not parse at all, and an older APPROVE is present.
        comments = [
            comment(
                "| x |\n" + marker(verdict="APPROVE"),
                created_at="2026-09-11T10:00:00Z",
                cid=1,
            ),
            comment(
                "| y |\n<!-- co-review: sha=zzz -->",
                created_at="2026-09-11T11:00:00Z",
                cid=2,
            ),
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

    def test_non_round_comment_cannot_revive_history(self):
        comments = [
            comment("| x |\n" + marker(), created_at="2026-09-11T10:00:00Z", cid=1),
            comment("looks good to me", created_at="2026-09-11T12:00:00Z", cid=2),
        ]
        decision, reason = gate.decide(comments, ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL", reason)


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

    def test_gate_ignores_target_tip_but_history_still_fails(self):
        body = "| x |\n" + self._marker_with_tip(self.TIP)
        decision, reason = gate.decide([comment(body)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL", reason)

    def test_malformed_target_tip_does_not_parse_as_a_marker(self):
        body = "| x |\n" + self._marker_with_tip("nothex")
        decision, _ = gate.decide([comment(body)], ME, SHA_A, BASE_A, REF)
        self.assertEqual(decision, "FAIL")


if __name__ == "__main__":
    unittest.main(verbosity=2)
