"""Behavior tests for the co-review change-class classifier."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("change_class", SCRIPTS / "change_class.py")
cc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cc)


def header(path: str) -> str:
    return f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1 +1 @@\n-x\n+y\n"


class ClassifyTests(unittest.TestCase):
    def test_prose_paths_are_light(self):
        for path in ("README.md", "docs/x.md", "claude/skills/todos/SKILL.md", ".todos/pending/a.md"):
            self.assertEqual(cc.classify([path]), "light", path)

    def test_code_and_gate_paths_are_full(self):
        for path in (
            "claude/hooks/x.py",
            "bin/dotfiles-tests",
            "claude/skills/co-review/SKILL.md",
            "claude/skills/ship/SKILL.md",
            "claude/skills/co-review/scripts/review.py",
            "codex/skills/co-review/SKILL.md",
            "claude/skills/review-change/SKILL.md",
        ):
            self.assertEqual(cc.classify([path]), "full", path)

    def test_mixed_and_empty_sets_are_full(self):
        self.assertEqual(cc.classify(["README.md", "install/x.sh"]), "full")
        self.assertEqual(cc.classify([]), "full")


class PathsFromDiffTests(unittest.TestCase):
    def test_two_files_including_a_space(self):
        text = header("docs/a b.md") + header("README.md")
        self.assertEqual(cc.paths_from_diff(text), ["docs/a b.md", "README.md"])

    def test_rename_quoted_and_empty_are_unparseable(self):
        self.assertIsNone(cc.paths_from_diff("diff --git a/old.md b/new.md\nrename from old.md\n"))
        self.assertIsNone(cc.paths_from_diff('diff --git "a/\\303\\251.md" "b/\\303\\251.md"\n'))
        self.assertIsNone(cc.paths_from_diff(""))
        self.assertIsNone(cc.paths_from_diff("+not a header\n"))


class ClassifyCliTests(unittest.TestCase):
    def run_cli(self, text: str) -> subprocess.CompletedProcess:
        with tempfile.NamedTemporaryFile("w", suffix=".diff", delete=False) as handle:
            handle.write(text)
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "gate_report.py"), "classify", "--diff", handle.name],
            capture_output=True, text=True, check=False,
        )

    def test_cli_prints_light_and_full(self):
        self.assertEqual(self.run_cli(header("README.md")).stdout, "light\n")
        self.assertEqual(self.run_cli(header("claude/hooks/x.py")).stdout, "full\n")
        self.assertEqual(self.run_cli("garbage\n").stdout, "full\n")


if __name__ == "__main__":
    unittest.main()
