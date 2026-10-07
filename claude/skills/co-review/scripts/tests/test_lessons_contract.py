"""Behavior tests for the agent-lessons.md contract check."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
REPO = Path(__file__).resolve().parents[5]
LESSONS = REPO / "claude/rules/personal/agent-lessons.md"
_spec = importlib.util.spec_from_file_location("lessons_contract", SCRIPTS / "lessons_contract.py")
lc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lc)

# Six lines; the first rule lands on line 7.
HEADER = "# Agent Lessons\n\nContract text.\n\n## Rules\n\n"


def rule(number: int) -> str:
    return f"- (2026-09) Rule number {number} stays short.\n"


class ContractTests(unittest.TestCase):
    def test_repo_file_passes(self):
        self.assertEqual(lc.check(LESSONS.read_text(encoding="utf-8")), [])

    def test_71_line_file_fails(self):
        text = "# Agent Lessons\n" + "Filler line.\n" * 63 + "## Rules\n\n"
        self.assertEqual(lc.check(text + "".join(rule(n) for n in range(4))), [])
        self.assertEqual(lc.check(text + "".join(rule(n) for n in range(5))),
                         ["file has 71 lines, over 70"])

    def test_31st_rule_fails(self):
        self.assertEqual(lc.check(HEADER + "".join(rule(n) for n in range(30))), [])
        self.assertEqual(lc.check(HEADER + "".join(rule(n) for n in range(31))),
                         ["file has 31 rules, over 30"])

    def test_81_column_line_fails(self):
        self.assertEqual(lc.check(HEADER + "- (2026-09) " + "x" * 68 + "\n"), [])
        self.assertEqual(lc.check(HEADER + "- (2026-09) " + "x" * 69 + "\n"),
                         ["line 7 is 81 columns, over 80"])

    def test_three_line_entry_fails(self):
        self.assertEqual(lc.check(HEADER + rule(1) + "  more words.\n"), [])
        self.assertEqual(lc.check(HEADER + rule(1) + "  more words.\n" + "  even more.\n"),
                         ["line 9 makes its entry longer than two lines"])

    def test_bad_entry_lines_fail(self):
        text = HEADER + "- (2026-13) bad month.\n" + "\n" + "  stray continuation.\n"
        self.assertEqual(lc.check(text),
                         ["line 7 is not a rule entry", "line 9 is not a rule entry"])

    def test_rules_heading_required_once(self):
        self.assertEqual(lc.check("# Agent Lessons\n\n" + rule(1)),
                         ["expected one '## Rules' line, found 0",])
        self.assertEqual(lc.check(HEADER + "## Rules\n"),
                         ["expected one '## Rules' line, found 2"])

    def test_rule_before_heading_fails(self):
        self.assertEqual(lc.check("# Agent Lessons\n" + rule(1) + "## Rules\n\n" + rule(2)),
                         ["line 2 is a rule before '## Rules'"])


class LessonsCheckCliTests(unittest.TestCase):
    def test_cli_passes_repo_file(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPTS / "gate_report.py"), "lessons-check", "--file", str(LESSONS)],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(json.loads(result.stdout), {"pass": True, "reasons": []})

    def test_cli_fails_bad_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "agent-lessons.md"
            path.write_text(HEADER + "".join(rule(n) for n in range(31)), encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "gate_report.py"), "lessons-check", "--file", str(path)],
                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout),
                         {"pass": False, "reasons": ["file has 31 rules, over 30"]})

    def test_cli_unreadable_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(
                [sys.executable, str(SCRIPTS / "gate_report.py"), "lessons-check",
                 "--file", str(Path(tmp) / "missing.md")],
                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        payload = json.loads(result.stdout)
        self.assertFalse(payload["pass"])
        self.assertTrue(payload["reasons"][0].startswith("cannot read "))


if __name__ == "__main__":
    unittest.main()
