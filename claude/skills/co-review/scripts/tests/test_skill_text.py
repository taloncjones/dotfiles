"""Drift checks: gate SKILL text stays in step with the gate scripts."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
CO_REVIEW = (REPO / "claude/skills/co-review/SKILL.md").read_text(encoding="utf-8")
MIRROR = (REPO / "codex/skills/co-review/SKILL.md").read_text(encoding="utf-8")
SHIP = (REPO / "claude/skills/ship/SKILL.md").read_text(encoding="utf-8")


def _extract_block(text, contains_needle):
    """Return the fenced bash block that contains contains_needle."""
    anchor = text.index(contains_needle)
    block_start = text.rindex("```bash", 0, anchor)
    block_end = text.index("```", block_start + len("```bash"))
    return text[block_start:block_end]


def _assert_launches_all_precede_one_trailing_wait(testcase, block):
    """Every `&` seat launch in the block precedes a single trailing `wait`."""
    lines = [line.strip() for line in block.splitlines()]
    launch_positions = [i for i, line in enumerate(lines) if line.endswith("&")]
    wait_positions = [i for i, line in enumerate(lines) if line == "wait"]
    testcase.assertTrue(launch_positions, "block has no seat launches")
    testcase.assertEqual(len(wait_positions), 1, "block must wait exactly once")
    testcase.assertGreater(wait_positions[0], max(launch_positions),
                            "wait must follow every launch, not sit between them")


class CoReviewSkillText(unittest.TestCase):
    def test_both_entrypoints_pin_the_frozen_diff_and_class(self):
        for text in (CO_REVIEW, MIRROR):
            for needle in ("-c core.quotePath=true diff --no-color --no-ext-diff --no-textconv --no-renames --binary",
                           'frozen.diff" || exit 2',
                           "classify --diff", "--full", "CLASS"):
                self.assertIn(needle, text)

    def test_both_entrypoints_name_the_light_seats(self):
        for text in (CO_REVIEW, MIRROR):
            self.assertIn("light tier runs `codex` and `verifier`", text)
            self.assertIn("finder", text)
            self.assertNotIn("first three", text)

    def test_co_review_gates_the_finder_dispatch_on_class(self):
        for needle in ('if [ "$CLASS" != "light" ]; then',
                       "Light tier: only the codex reviewer seat. Full tier: also claude and breaker."):
            self.assertIn(needle, CO_REVIEW)
        self.assertNotIn("Repeat once for claude, codex, and breaker", CO_REVIEW)

    def test_mirror_launches_light_verifier_through_claude_runner(self):
        self.assertIn("--runtime claude --role skeptic", MIRROR)

    def test_mirror_branches_every_seat_step(self):
        for needle in ("Full tier only:",
                       "Light tier: dispatch only the `codex` reviewer",
                       "Light tier: wait for the `codex` seat only",
                       "Light tier: only after the `codex` artifact",
                       "the actual runtime artifacts for `CLASS`"):
            self.assertIn(needle, MIRROR)
        self.assertNotIn("actual four runtime artifacts", MIRROR)

    def test_policy_describes_both_tiers(self):
        policy = subprocess.run(
            [sys.executable, str(REPO / "claude/skills/co-review/scripts/gate_report.py"),
             "policy", "--section", "POLICY"],
            capture_output=True, text=True, check=True,
        ).stdout
        for needle in ("light tier", "full tier", "`codex` and `verifier`", "change_class.py"):
            self.assertIn(needle, policy)
        self.assertNotIn("All four seats", policy)
        self.assertNotIn("first three", policy)
        self.assertNotIn("first-three", policy)

    def test_co_review_probes_every_runner_route_before_seats(self):
        probe = CO_REVIEW.index('"$RUN_DIR/probe-')
        first_seat = CO_REVIEW.index('--prompt-file "$RUN_DIR/codex.prompt"')
        self.assertLess(probe, first_seat)
        for needle in ("--timeout-secs 60", '"$RUN_DIR"/probe-*.json',
                       "probe-claude-reviewer.json", "probe-codex-reviewer.json",
                       "probe-codex-skeptic.json", "probe-claude-skeptic.json",
                       'status") != "success"', "json.load(handle)",
                       "Reply ok"):
            self.assertIn(needle, CO_REVIEW)

    def test_co_review_seats_run_in_background_at_1200_seconds(self):
        self.assertEqual(CO_REVIEW.count("--timeout-secs 1200"), 4)
        self.assertNotIn("--timeout-secs 600", CO_REVIEW)
        for needle in ("run_in_background", "git apply --index", "wait"):
            self.assertIn(needle, CO_REVIEW)

    def test_co_review_probe_seats_launch_together_before_one_wait(self):
        block = _extract_block(CO_REVIEW, '"$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-codex-reviewer.json"')
        _assert_launches_all_precede_one_trailing_wait(self, block)

    def test_co_review_finder_seats_launch_together_before_one_wait(self):
        block = _extract_block(CO_REVIEW, '"$RUN_DIR/codex.prompt" >"$RUN_DIR/codex.runtime.json"')
        _assert_launches_all_precede_one_trailing_wait(self, block)

    def test_mirror_probe_seats_launch_together_before_one_wait(self):
        block = _extract_block(MIRROR, '"$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-claude-skeptic.json"')
        _assert_launches_all_precede_one_trailing_wait(self, block)

    def test_mirror_probes_claude_routes_and_launches_nohup_seats(self):
        probe = MIRROR.index('"$RUN_DIR/probe-claude-')
        self.assertLess(probe, MIRROR.index('--prompt-file "$RUN_DIR/verifier.prompt"'))
        self.assertLess(probe, MIRROR.index('--prompt-file "$RUN_DIR/claude.prompt"'))
        for needle in ("probe-claude-reviewer.json", "probe-claude-skeptic.json",
                       "--timeout-secs 60", "nohup uv run", '.pid"',
                       "kill -0", "1200-second deadline"):
            self.assertIn(needle, MIRROR)
        self.assertEqual(MIRROR.count("--timeout-secs 1200"), 2)
        self.assertNotIn("--timeout-secs 600", MIRROR)
        self.assertNotIn("600-second", MIRROR)


class ShipSkillText(unittest.TestCase):
    def test_ship_has_the_audit_comment_step(self):
        for needle in ("audit-comment", "co-review-audit head=", "--paginate",
                       "gh pr comment", "self-classifies", "--full"):
            self.assertIn(needle, SHIP)


if __name__ == "__main__":
    unittest.main()
