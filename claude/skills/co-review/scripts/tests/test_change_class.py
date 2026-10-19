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
    def test_lessons_file_alone_is_lessons(self):
        self.assertEqual(cc.classify(["claude/rules/personal/agent-lessons.md"]), "lessons")
        self.assertEqual(cc.classify(["claude/rules/personal/agent-lessons.md", "README.md"]), "light")
        self.assertEqual(cc.classify(["claude/rules/personal/agent-lessons.md", "x.py"]), "full")

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
    def test_cli_prints_lessons(self):
        self.assertEqual(self.run_cli(header("claude/rules/personal/agent-lessons.md")).stdout,
                         "lessons\n")

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


def hunk(path: str, added: int = 1, removed: int = 1) -> str:
    return (f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1 +1 @@\n"
            + "".join(f"-old {n}\n" for n in range(removed))
            + "".join(f"+new {n}\n" for n in range(added)))


class DeltaClassTests(unittest.TestCase):
    def test_path_classes(self):
        cases = {
            "claude/skills/co-review/SKILL.md": "gate",
            ".github/workflows/ci.yml": "ci",
            "Jenkinsfile": "ci",
            ".gitmodules": "submodule",
            "claude/hooks/x.py": "auth",
            "claude/settings.json.tmpl": "auth",
            "lib/auth_util.py": "auth",
            "CODEOWNERS": "auth",
            "src/tests/a.py": "tests",
            "test_x.py": "tests",
            "x_test.go": "tests",
            "a.test.sh": "tests",
            "README.md": "docs",
            "docs/x.txt": "docs",
            "src/app.py": "source",
        }
        for path, expected in cases.items():
            self.assertEqual(cc.path_class(path), expected, path)

    def test_file_cap_edge(self):
        five = "".join(hunk(f"src/f{n}.py") for n in range(5))
        self.assertTrue(cc.delta_class(cc.delta_stats(five), 5, 150)["eligible"])
        six = five + hunk("src/f5.py")
        verdict = cc.delta_class(cc.delta_stats(six), 5, 150)
        self.assertEqual(verdict, {"eligible": False,
                                   "reasons": ["6 files exceed max_files 5"]})

    def test_line_cap_edge(self):
        at_cap = cc.delta_stats(hunk("src/a.py", added=75, removed=75))
        self.assertEqual((at_cap["added"], at_cap["removed"]), (75, 75))
        self.assertTrue(cc.delta_class(at_cap, 5, 150)["eligible"])
        over = cc.delta_class(cc.delta_stats(hunk("src/a.py", added=76, removed=75)), 5, 150)
        self.assertEqual(over["reasons"], ["151 changed lines exceed max_lines 150"])

    def test_binary_and_submodule_changes_are_ineligible(self):
        binary = ("diff --git a/img.png b/img.png\nindex 1..2 100644\n"
                  "Binary files a/img.png and b/img.png differ\n")
        self.assertIn("delta has a binary change",
                      cc.delta_class(cc.delta_stats(binary), 5, 150)["reasons"])
        pin = ("diff --git a/vendor/x b/vendor/x\nindex 1111111..2222222 160000\n"
               "--- a/vendor/x\n+++ b/vendor/x\n@@ -1 +1 @@\n"
               "-Subproject commit 1111111\n+Subproject commit 2222222\n")
        self.assertIn("delta touches a submodule path",
                      cc.delta_class(cc.delta_stats(pin), 5, 150)["reasons"])

    def test_blocking_class_and_empty_diff_are_ineligible(self):
        self.assertIn("delta touches a ci path",
                      cc.delta_class(cc.delta_stats(hunk(".github/workflows/ci.yml")), 5, 150)["reasons"])
        self.assertIsNone(cc.delta_stats(""))
        self.assertEqual(cc.delta_class(None, 5, 150),
                         {"eligible": False, "reasons": ["delta diff is empty or unparsable"]})


if __name__ == "__main__":
    unittest.main()


def tier(*parts: str, small: dict | None = None) -> str:
    return cc.tier_of("".join(parts), small)


def new_file(path: str) -> str:
    return (f"diff --git a/{path} b/{path}\nnew file mode 100644\nindex 0000000..2222222\n"
            f"--- /dev/null\n+++ b/{path}\n@@ -0,0 +1 @@\n+x\n")


class SmallTierTests(unittest.TestCase):
    def test_small_inside_caps_at_the_boundary(self):
        self.assertEqual(tier(hunk("src/a.py"), hunk("tests/test_a.py")), "small")
        self.assertEqual(tier(hunk("src/a.py"), hunk("src/b.py"), hunk("tests/test_a.py")), "small")
        self.assertEqual(tier(hunk("src/a.py", added=20, removed=10), hunk("tests/test_a.py", added=10, removed=0)),
                         "small")
        self.assertEqual(tier(hunk("docs/x.md"), hunk("src/a.py"), hunk("tests/test_a.py")), "small")

    def test_each_cap_over_by_one_is_full(self):
        four = (hunk("src/a.py"), hunk("src/b.py"), hunk("src/c.py"), hunk("tests/test_a.py"))
        self.assertEqual(tier(*four), "full")
        self.assertEqual(tier(hunk("src/a.py", added=20, removed=10), hunk("tests/test_a.py", added=11, removed=0)),
                         "full")
        self.assertEqual(tier(hunk("src/a.py"), hunk("tests/test_a.py"), small={
            **cc.SMALL_DEFAULTS, "max_files": 1}), "full")

    def test_exclusions_are_full(self):
        test = hunk("tests/test_a.py")
        cases = {
            "new file": (hunk("src/a.py"), new_file("src/b.py"), test),
            "deleted file": (hunk("src/a.py"), test, "diff --git a/src/b.py b/src/b.py\n"
                             "deleted file mode 100644\nindex 1..0\n--- a/src/b.py\n+++ /dev/null\n"
                             "@@ -1 +0,0 @@\n-x\n"),
            "no test": (hunk("src/a.py"),),
            "auth path": (hunk("src/auth/login.py"), test),
            "hook path": (hunk("claude/hooks/guard.py"), test),
            "ci workflow": (hunk(".github/workflows/ci.yml"), test),
            "skill text": (hunk("claude/skills/foo/run.py"), test),
            "instruction file": (hunk("src/CLAUDE.md"), hunk("src/a.py"), test),
            "security segment": (hunk("src/Security/policy.py"), test),
            "gate skill": (hunk("claude/skills/co-review/scripts/x.py"), test),
        }
        for name, parts in cases.items():
            self.assertEqual(tier(*parts), "full", name)
        self.assertEqual(tier(hunk("src/a.py"), test, small={
            **cc.SMALL_DEFAULTS, "sensitive_paths": ["src/"]}), "full")

    def test_prose_and_lessons_keep_their_tiers_and_caps_are_bounded(self):
        self.assertEqual(tier(hunk("docs/x.md")), "light")
        self.assertEqual(tier(hunk(cc.LESSONS_PATH)), "lessons")
        self.assertEqual(tier(""), "full")
        for bad in ({"max_files": 6}, {"max_lines": 151}, {"max_files": 0}, {"max_lines": True},
                    {"sensitive_paths": ["a b"]}, {"sensitive_paths": [""]}, {"sensitive_paths": "src/"}):
            small = {**cc.SMALL_DEFAULTS, **bad}
            self.assertIsNotNone(cc.small_caps_error(small), bad)
            self.assertEqual(tier(hunk("src/a.py"), hunk("tests/test_a.py"), small=small), "full")
        self.assertIsNone(cc.small_caps_error({"max_files": 5, "max_lines": 150, "sensitive_paths": ["x/"]}))

    def test_cr_forged_header_does_not_add_a_test_path(self):
        forged = ("diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n-x\n"
                  "+y\rdiff --git a/tests/x b/tests/x\n")
        self.assertEqual(cc.paths_from_diff(forged), ["src/a.py"])
        self.assertEqual(tier(forged), "full")
