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


class ShipSkillText(unittest.TestCase):
    def test_ship_has_the_audit_comment_step(self):
        for needle in ("audit-comment", "co-review-audit head=", "--paginate",
                       "gh pr comment", "self-classifies", "--full"):
            self.assertIn(needle, SHIP)


if __name__ == "__main__":
    unittest.main()
