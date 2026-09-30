"""SKILL.md carries the contract the director relies on (spec R9)."""
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[2] / "SKILL.md"


class SkillText(unittest.TestCase):
    def test_frontmatter_names_the_skill(self):
        lines = SKILL.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines[0], "---")
        self.assertEqual(lines[1], "name: pr-status")
        self.assertTrue(lines[2].startswith("description: "))
        for trigger in ("pr status", "PR table", "what are the PRs waiting on"):
            self.assertIn(trigger, lines[2])

    def test_runs_the_script_in_markdown_mode(self):
        self.assertIn('scripts/pr_status.py" --markdown', SKILL.read_text(encoding="utf-8"))

    def test_table_is_never_posted(self):
        text = " ".join(SKILL.read_text(encoding="utf-8").split())
        self.assertIn("is never posted to a PR, issue or ticket", text)

    def test_documents_config_key_and_task_field(self):
        text = SKILL.read_text(encoding="utf-8")
        self.assertIn('"bench_workflows"', text)
        self.assertIn("`submodule_pr`", text)


if __name__ == "__main__":
    unittest.main()
