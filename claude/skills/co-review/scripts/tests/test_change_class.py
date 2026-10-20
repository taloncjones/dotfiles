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
        with tempfile.NamedTemporaryFile("wb", suffix=".diff", delete=False) as handle:
            handle.write(text.encode())
        return subprocess.run(
            [sys.executable, str(SCRIPTS / "gate_report.py"), "classify", "--diff", handle.name],
            capture_output=True, text=True, check=False,
        )

    def test_cli_reads_bytes_so_a_cr_forged_header_matches_the_evaluator(self):
        lessons = header("claude/rules/personal/agent-lessons.md")
        forged = lessons[:-1] + "\rdiff --git a/src/a.py b/src/a.py\n"
        self.assertEqual(cc.tier_of(forged), "lessons")
        self.assertEqual(self.run_cli(forged).stdout, "lessons\n")

    def test_cli_prints_light_and_full(self):
        self.assertEqual(self.run_cli(header("README.md")).stdout, "light\n")
        self.assertEqual(self.run_cli(header("claude/hooks/x.py")).stdout, "full\n")
        self.assertEqual(self.run_cli("garbage\n").stdout, "full\n")


def hunk(path: str, added: int = 1, removed: int = 1) -> str:
    return (f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n@@ -1,{removed} +1,{added} @@\n"
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


class MalformedDiffTests(unittest.TestCase):
    def test_diff_without_hunk_headers_is_full(self):
        diff = tier_text("src/a.py") + tier_text("tests/test_a.py")
        no_hunks = "".join(line + "\n" for line in diff.split("\n") if not line.startswith("@@"))
        self.assertEqual(cc.tier_of(diff), "small")
        self.assertEqual(cc.tier_of(no_hunks), "full")
        self.assertTrue(cc.delta_stats(no_hunks)["malformed"])
        self.assertIn("delta diff is not a plain unified diff",
                      cc.delta_class(cc.delta_stats(no_hunks), 5, 150)["reasons"])

    def test_word_diff_form_is_full(self):
        word = ("diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n"
                "[-old-]{+new+}\n"
                "diff --git a/tests/test_a.py b/tests/test_a.py\n--- a/tests/test_a.py\n"
                "+++ b/tests/test_a.py\n@@ -1 +1 @@\n[-old-]{+new+}\n")
        self.assertEqual(cc.tier_of(word), "full")
        self.assertEqual(cc.delta_stats(word)["added"], 0)

    def test_dropped_headers_with_triple_marker_lines_is_full(self):
        diff = "".join(
            f"diff --git a/{p} b/{p}\n--- a/{p}\n+++ b/{p}\n" + "--- old\n+++ new\n" * 3
            for p in ("src/a.py", "tests/test_a.py"))
        self.assertTrue(cc.delta_stats(diff)["malformed"])
        self.assertEqual(cc.tier_of(diff), "full")

    def test_word_diff_with_one_column_zero_plus_per_file_is_full(self):
        diff = "".join(
            f"diff --git a/{p} b/{p}\n--- a/{p}\n+++ b/{p}\n@@ -1,2 +1,2 @@\n"
            " a [-old-]{+new+} b\n x [-y-]{+z+}\n+extra\n"
            for p in ("src/a.py", "tests/test_a.py"))
        self.assertTrue(cc.delta_stats(diff)["malformed"])
        self.assertEqual(cc.tier_of(diff), "full")

    def test_hunk_counts_must_match_the_body(self):
        good = "diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1,2 +1,2 @@\n c\n-x\n+y\n"
        self.assertFalse(cc.delta_stats(good)["malformed"])
        for label, bad in (("short", good.replace("-1,2 +1,2", "-1,3 +1,3")),
                           ("long", good.replace("-1,2 +1,2", "-1 +1")),
                           ("triple-dash body line", good + "--- z\n")):
            with self.subTest(label):
                self.assertTrue(cc.delta_stats(bad)["malformed"])

    def test_mode_only_change_beside_a_test_is_full(self):
        mode = ("diff --git a/src/a.py b/src/a.py\nold mode 100644\nnew mode 100755\n")
        diff = hunk("tests/test_a.py") + mode
        self.assertEqual(cc.tier_of(hunk("tests/test_a.py") + hunk("src/b.py")), "small")
        self.assertEqual(cc.tier_of(diff), "full")

    def test_hunk_section_without_changes_is_malformed(self):
        empty = ("diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n@@ -1 +1 @@\n context\n")
        self.assertTrue(cc.delta_stats(empty)["malformed"])

    def test_hunkless_section_is_malformed(self):
        base = hunk("src/a.py") + hunk("src/b.py")
        self.assertEqual(cc.tier_of(base + hunk("tests/test_a.py")), "small")
        bare = "diff --git a/tests/test_a.py b/tests/test_a.py\n"
        indexed = bare + "index 1111111..2222222 100644\n"
        for label, tail in (("bare header", bare), ("index only", indexed)):
            with self.subTest(label):
                diff = base + tail
                self.assertTrue(cc.delta_stats(diff)["malformed"])
                self.assertEqual(cc.tier_of(diff), "full")
        self.assertEqual(cc.tier_of(bare), "full")

    def test_file_headers_must_match_the_diff_git_path(self):
        spoof = ("diff --git a/src/app.py b/src/app.py\n--- a/src/auth/login.py\n"
                 "+++ b/src/auth/login.py\n@@ -1 +1 @@\n-x\n+y\n")
        diff = spoof + hunk("tests/test_a.py")
        self.assertEqual(cc.tier_of(hunk("src/app.py") + hunk("tests/test_a.py")), "small")
        self.assertTrue(cc.delta_stats(diff)["malformed"])
        self.assertEqual(cc.tier_of(diff), "full")
        one_side = spoof.replace("--- a/src/auth/login.py", "--- a/src/app.py")
        self.assertEqual(cc.tier_of(one_side + hunk("tests/test_a.py")), "full")

    def test_dev_null_headers_match_an_add_or_delete(self):
        add = ("diff --git a/src/n.py b/src/n.py\nnew file mode 100644\n--- /dev/null\n"
               "+++ b/src/n.py\n@@ -0,0 +1 @@\n+y\n")
        self.assertFalse(cc.delta_stats(add)["malformed"])
        gone = ("diff --git a/src/n.py b/src/n.py\ndeleted file mode 100644\n--- a/src/n.py\n"
                "+++ /dev/null\n@@ -1 +0,0 @@\n-y\n")
        self.assertFalse(cc.delta_stats(gone)["malformed"])


def git_diff_of(setup: dict, change: dict) -> str:
    """Real `git diff` output of change (path -> text or None to delete) over setup."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)

        def git(*args):
            return subprocess.run(["git", "-C", tmp, *args], check=True, capture_output=True,
                                  text=True).stdout

        git("init", "-q")
        for rel, body in setup.items():
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_text(body)
        git("add", "-A")
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
        for rel, body in change.items():
            if body is None:
                (root / rel).unlink()
            else:
                (root / rel).parent.mkdir(parents=True, exist_ok=True)
                (root / rel).write_text(body)
        git("add", "-A")
        return git("diff", "--cached", "--no-color")


class HeaderStrictnessTests(unittest.TestCase):
    def test_malformed_prose_diff_is_full(self):
        spoof = ("diff --git a/README.md b/README.md\n--- a/src/auth/login.py\n"
                 "+++ b/src/auth/login.py\n@@ -1 +1 @@\n-x\n+y\n")
        lone = "diff --git a/README.md b/README.md\n"
        truncated = "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1,2 +1,2 @@\n-x\n+y\n"
        self.assertEqual(cc.tier_of(hunk("README.md")), "light")
        for label, diff in (("spoof", spoof), ("lone", lone), ("truncated", truncated)):
            with self.subTest(label):
                self.assertEqual(cc.tier_of(diff), "full")

    def test_hunks_need_both_file_headers(self):
        base = "diff --git a/src/a.py b/src/a.py\n"
        cases = {
            "no headers": base + "@@ -1 +1 @@\n-x\n+y\n",
            "minus only": base + "--- a/src/a.py\n@@ -1 +1 @@\n-x\n+y\n",
            "plus only": base + "+++ b/src/a.py\n@@ -1 +1 @@\n-x\n+y\n",
            "dev null old on edit": base + "--- /dev/null\n+++ b/src/a.py\n@@ -1 +1 @@\n-x\n+y\n",
            "dev null new on edit": base + "--- a/src/a.py\n+++ /dev/null\n@@ -1 +1 @@\n-x\n+y\n",
            "dev null old on delete": base + "deleted file mode 100644\n--- /dev/null\n"
                                      "+++ /dev/null\n@@ -1 +0,0 @@\n-x\n",
        }
        for label, diff in cases.items():
            with self.subTest(label):
                self.assertTrue(cc.delta_stats(diff)["malformed"])

    def test_real_git_add_delete_and_edit_stay_well_formed(self):
        edit = git_diff_of({"src/a.py": "x\n"}, {"src/a.py": "y\n"})
        add = git_diff_of({"src/z.py": "z\n"}, {"src/n.py": "n\n"})
        gone = git_diff_of({"src/n.py": "n\n"}, {"src/n.py": None})
        for label, diff in (("edit", edit), ("add", add), ("delete", gone)):
            with self.subTest(label):
                self.assertFalse(cc.delta_stats(diff)["malformed"])
        self.assertTrue(cc.delta_stats(add)["new_files"])
        self.assertTrue(cc.delta_stats(gone)["deleted_files"])
        self.assertEqual(cc.tier_of(edit + hunk("tests/test_a.py")), "small")

    def test_preamble_file_header_is_malformed(self):
        diff = "--- a/tests/test_a.py\n" + hunk("src/a.py") + hunk("tests/test_a.py")
        self.assertTrue(cc.delta_stats(diff)["malformed"])
        self.assertEqual(cc.tier_of(diff), "full")


def tier_text(path: str) -> str:
    return hunk(path)
