"""Fixture-repo tests for the carry-forward proofs and the delta range."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("branch_delta", SCRIPTS / "branch_delta.py")
bd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bd)

GIT_ENV = {
    **{k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
}
SHARED = "".join(f"line {n}\n" for n in range(1, 21))


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, env=GIT_ENV,
                          capture_output=True, text=True).stdout.strip()


def commit_file(repo: Path, name: str, body: str, message: str) -> str:
    (repo / name).parent.mkdir(parents=True, exist_ok=True)
    (repo / name).write_text(body, encoding="utf-8")
    git(repo, "add", "--", name)
    git(repo, "commit", "-q", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def replace_line(body: str, number: int, text: str) -> str:
    lines = body.splitlines(keepends=True)
    lines[number - 1] = text + "\n"
    return "".join(lines)


class CarryForwardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        commit_file(self.repo, "shared.txt", SHARED, "base")
        commit_file(self.repo, "main_only.txt", "a\n", "main file")
        git(self.repo, "checkout", "-q", "-b", "topic")
        commit_file(self.repo, "shared.txt", replace_line(SHARED, 2, "branch edit"), "branch shared")
        self.gated = commit_file(self.repo, "feature.txt", "feature\n", "branch feature")
        git(self.repo, "checkout", "-q", "main")

    def tearDown(self):
        self.tmp.cleanup()

    def advance_main(self, name: str, body: str) -> None:
        git(self.repo, "checkout", "-q", "main")
        commit_file(self.repo, name, body, f"main {name}")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")

    def merge_main(self) -> str:
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "merge", "-q", "--no-edit", "main")
        return git(self.repo, "rev-parse", "HEAD")

    def proof(self, head: str = "HEAD") -> dict:
        return bd.carry_forward(self.repo, self.gated, head, "origin/main")

    def test_merge_tree_lists_only_conflicted_paths(self):
        review = bd._review
        base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "checkout", "-q", "-b", "side")
        side = commit_file(self.repo, "both.txt", "side\n", "side")
        git(self.repo, "checkout", "-q", "-b", "other", base)
        other = commit_file(self.repo, "both.txt", "other\n", "other")
        tree, conflicted = review.merge_tree(self.repo, side, other)
        self.assertRegex(tree, r"^[0-9a-f]{40}$")
        self.assertEqual(conflicted, ["both.txt"])
        clean_tree, clean = review.merge_tree(self.repo, base, side)
        self.assertEqual(clean, [])
        self.assertEqual(clean_tree, git(self.repo, "rev-parse", f"{side}^{{tree}}"))

    def split_directory_rename(self) -> tuple[str, str]:
        # One side splits a/ across b/ and c/; the other adds a/z.txt. Git exits 1
        # with a directory-rename conflict and stages no conflicted path.
        base = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "checkout", "-q", "-b", "split", base)
        commit_file(self.repo, "a/x.txt", "x1\nx2\nx3\n", "a x")
        commit_file(self.repo, "a/y.txt", "y1\ny2\ny3\n", "a y")
        before = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "mv", "a/x.txt", "b_x.txt")
        (self.repo / "b").mkdir()
        git(self.repo, "mv", "b_x.txt", "b/x.txt")
        (self.repo / "c").mkdir()
        git(self.repo, "mv", "a/y.txt", "c/y.txt")
        git(self.repo, "commit", "-q", "-m", "split a")
        splitter = git(self.repo, "rev-parse", "HEAD")
        git(self.repo, "checkout", "-q", "-b", "adder", before)
        adder = commit_file(self.repo, "a/z.txt", "z\n", "add to a")
        return splitter, adder

    def test_merge_tree_exit_one_without_a_listed_path_is_a_conflict(self):
        splitter, adder = self.split_directory_rename()
        tree, conflicted = bd._review.merge_tree(self.repo, splitter, adder)
        self.assertRegex(tree, r"^[0-9a-f]{40}$")
        self.assertTrue(conflicted, "a nonzero merge-tree exit must report a conflict")

    def test_merge_main_only_with_untouched_files_passes(self):
        self.advance_main("main_only.txt", "a\nb\n")
        self.merge_main()
        record = self.proof()
        self.assertTrue(record["pass"], record["reasons"])
        self.assertEqual(record["prior_head"], self.gated)
        names = [item["name"] for item in record["proofs"]]
        self.assertEqual(names[:3], ["ancestry", "commits-head", "commits-gated"])

    def test_auto_merged_shared_file_with_equal_hunks_passes(self):
        self.advance_main("shared.txt", replace_line(SHARED, 18, "main edit"))
        self.merge_main()
        record = self.proof()
        self.assertTrue(record["pass"], record["reasons"])
        self.assertIn("hunks shared.txt", [item["name"] for item in record["proofs"]])

    def test_branch_commit_after_the_merge_fails(self):
        self.advance_main("main_only.txt", "a\nb\n")
        self.merge_main()
        extra = commit_file(self.repo, "feature.txt", "feature\nmore\n", "branch follow-up")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(extra in reason for reason in record["reasons"]), record["reasons"])

    def test_hand_resolved_conflict_fails(self):
        self.advance_main("shared.txt", replace_line(SHARED, 2, "main edit"))
        git(self.repo, "checkout", "-q", "topic")
        merged = subprocess.run(["git", "-C", str(self.repo), "merge", "-q", "--no-edit", "main"],
                                env=GIT_ENV, capture_output=True, text=True)
        self.assertNotEqual(merged.returncode, 0)
        (self.repo / "shared.txt").write_text(replace_line(SHARED, 2, "resolved by hand"),
                                              encoding="utf-8")
        git(self.repo, "add", "shared.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("shared.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_ours_merge_that_drops_upstream_hunks_in_a_branch_file_fails(self):
        self.advance_main("shared.txt", replace_line(SHARED, 18, "main edit"))
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "merge", "-q", "--no-edit", "-s", "ours", "main")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("shared.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_conflict_resolved_with_ours_fails(self):
        self.advance_main("shared.txt", replace_line(SHARED, 2, "main edit"))
        git(self.repo, "checkout", "-q", "topic")
        merged = subprocess.run(["git", "-C", str(self.repo), "merge", "-q", "--no-edit", "main"],
                                env=GIT_ENV, capture_output=True, text=True)
        self.assertNotEqual(merged.returncode, 0)
        git(self.repo, "checkout", "--ours", "shared.txt")
        git(self.repo, "add", "shared.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("shared.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_merge_hand_edited_to_move_a_line_fails(self):
        # Original [A,X,B]; branch [X,A,X,B]; main [A,B]. Git merges to [X,A,B];
        # the head holds [A,X,B], the same hunk text at a different position.
        git(self.repo, "checkout", "-q", "-b", "dup", "main")
        original = commit_file(self.repo, "dup.txt", "A\nX\nB\n", "dup original")
        git(self.repo, "checkout", "-q", "-b", "dup-branch", original)
        self.gated = commit_file(self.repo, "dup.txt", "X\nA\nX\nB\n", "dup branch")
        git(self.repo, "checkout", "-q", "main")
        git(self.repo, "merge", "-q", "--ff-only", original)
        commit_file(self.repo, "dup.txt", "A\nB\n", "main drops X")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")
        git(self.repo, "checkout", "-q", "dup-branch")
        git(self.repo, "merge", "-q", "--no-commit", "main")
        self.assertEqual((self.repo / "dup.txt").read_text(encoding="utf-8"), "X\nA\nB\n")
        (self.repo / "dup.txt").write_text("A\nX\nB\n", encoding="utf-8")
        git(self.repo, "add", "dup.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("dup.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_hand_resolved_conflict_in_duplicate_lines_fails(self):
        # Both sides edit a run of identical lines; git conflicts and the
        # resolution differs from any merge git would produce.
        git(self.repo, "checkout", "-q", "-b", "dup", "main")
        original = commit_file(self.repo, "dup.txt", "A\nX\nX\nX\nB\n", "dup original")
        git(self.repo, "checkout", "-q", "-b", "dup-branch", original)
        self.gated = commit_file(self.repo, "dup.txt", "A\nX\nbranch\nX\nB\n", "dup branch")
        git(self.repo, "checkout", "-q", "main")
        git(self.repo, "merge", "-q", "--ff-only", original)
        commit_file(self.repo, "dup.txt", "A\nX\nmain\nX\nB\n", "main edits the run")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")
        git(self.repo, "checkout", "-q", "dup-branch")
        merged = subprocess.run(["git", "-C", str(self.repo), "merge", "-q", "--no-edit", "main"],
                                env=GIT_ENV, capture_output=True, text=True)
        self.assertNotEqual(merged.returncode, 0)
        (self.repo / "dup.txt").write_text("A\nX\nX\nX\nB\n", encoding="utf-8")
        git(self.repo, "add", "dup.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("dup.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_hand_placed_duplicate_line_differing_from_the_clean_merge_fails(self):
        # Original [A,X,B]; branch adds an X after the first; main adds one before A.
        # Git merges to [X,A,X,X,B]; the head holds [A,X,X,X,B] (same hunk text).
        git(self.repo, "checkout", "-q", "-b", "dup", "main")
        original = commit_file(self.repo, "dup.txt", "A\nX\nB\n", "dup original")
        git(self.repo, "checkout", "-q", "-b", "dup-branch", original)
        self.gated = commit_file(self.repo, "dup.txt", "A\nX\nX\nB\n", "dup branch")
        git(self.repo, "checkout", "-q", "main")
        git(self.repo, "merge", "-q", "--ff-only", original)
        commit_file(self.repo, "dup.txt", "X\nA\nX\nB\n", "main adds X first")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")
        git(self.repo, "checkout", "-q", "dup-branch")
        git(self.repo, "merge", "-q", "--no-commit", "main")
        self.assertEqual((self.repo / "dup.txt").read_text(encoding="utf-8"), "X\nA\nX\nX\nB\n")
        (self.repo / "dup.txt").write_text("A\nX\nX\nX\nB\n", encoding="utf-8")
        git(self.repo, "add", "dup.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("dup.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_merge_whose_tree_differs_from_the_merge_result_fails(self):
        self.advance_main("main_only.txt", "a\nb\n")
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "merge", "-q", "--no-commit", "main")
        (self.repo / "other.txt").write_text("sneaked in\n", encoding="utf-8")
        git(self.repo, "add", "other.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any("other.txt" in reason for reason in record["reasons"]),
                        record["reasons"])

    def test_merge_that_flips_a_branch_file_mode_fails(self):
        self.advance_main("main_only.txt", "a\nb\n")
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "merge", "-q", "--no-commit", "main")
        git(self.repo, "update-index", "--chmod=+x", "feature.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("feature.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_merge_that_turns_a_branch_file_into_a_symlink_fails(self):
        self.advance_main("main_only.txt", "a\nb\n")
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "merge", "-q", "--no-commit", "main")
        (self.repo / "feature.txt").unlink()
        (self.repo / "feature.txt").symlink_to("shared.txt")
        git(self.repo, "add", "feature.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("feature.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_upstream_mode_flip_merged_in_passes(self):
        git(self.repo, "checkout", "-q", "main")
        (self.repo / "shared.txt").chmod(0o755)
        git(self.repo, "commit", "-q", "-a", "-m", "main makes shared executable")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "merge", "-q", "--no-edit", "main")
        record = self.proof()
        self.assertTrue(record["pass"], record["reasons"])

    def test_rebased_branch_is_not_an_ancestor(self):
        self.advance_main("main_only.txt", "a\nb\n")
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "rebase", "-q", "main")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any("not an ancestor" in reason for reason in record["reasons"]))

    def test_unknown_ref_fails_closed(self):
        record = bd.carry_forward(self.repo, self.gated, "HEAD", "origin/missing")
        self.assertFalse(record["pass"])
        self.assertTrue(record["reasons"][0].startswith("git proof failed"))

    def test_record_is_identical_across_reruns(self):
        self.advance_main("main_only.txt", "a\nb\n")
        self.merge_main()
        self.assertEqual(self.proof(), self.proof())


class RenameCarryForwardTests(unittest.TestCase):
    """Main renames a file the branch edited; the proof must follow the rename."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        commit_file(self.repo, "old.txt", SHARED, "base")
        git(self.repo, "checkout", "-q", "-b", "topic")
        self.gated = commit_file(self.repo, "old.txt", replace_line(SHARED, 2, "branch edit"),
                                 "branch edit")
        git(self.repo, "checkout", "-q", "main")

    def tearDown(self):
        self.tmp.cleanup()

    def rename_on_main(self, body: str) -> str:
        git(self.repo, "mv", "old.txt", "new.txt")
        (self.repo / "new.txt").write_text(body, encoding="utf-8")
        git(self.repo, "add", "new.txt")
        git(self.repo, "commit", "-q", "-m", "main renames old to new")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")
        return body

    def merge_main(self, expect_clean: bool) -> None:
        git(self.repo, "checkout", "-q", "topic")
        args = ["git", "-C", str(self.repo), "merge", "-q", "--no-edit", "main"]
        merged = subprocess.run(args, env=GIT_ENV, capture_output=True, text=True)
        self.assertEqual(merged.returncode == 0, expect_clean, merged.stdout + merged.stderr)

    def proof(self) -> dict:
        return bd.carry_forward(self.repo, self.gated, "HEAD", "origin/main")

    def test_conflicting_rename_resolved_by_hand_fails(self):
        self.rename_on_main(replace_line(SHARED, 2, "main edit"))
        self.merge_main(expect_clean=False)
        (self.repo / "new.txt").write_text(replace_line(SHARED, 2, "resolved by hand"),
                                           encoding="utf-8")
        git(self.repo, "add", "new.txt")
        git(self.repo, "commit", "-q", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("new.txt:") and "conflicts" in reason
                            for reason in record["reasons"]), record["reasons"])

    def test_clean_rename_merge_restored_to_main_copy_fails(self):
        main_copy = self.rename_on_main(replace_line(SHARED, 18, "main edit"))
        self.merge_main(expect_clean=True)
        self.assertEqual((self.repo / "new.txt").read_text(encoding="utf-8"),
                         replace_line(replace_line(SHARED, 2, "branch edit"), 18, "main edit"))
        (self.repo / "new.txt").write_text(main_copy, encoding="utf-8")
        git(self.repo, "add", "new.txt")
        git(self.repo, "commit", "-q", "--amend", "--no-edit")
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("new.txt:") for reason in record["reasons"]),
                        record["reasons"])

    def test_clean_rename_merge_as_git_produced_it_passes(self):
        self.rename_on_main(replace_line(SHARED, 18, "main edit"))
        self.merge_main(expect_clean=True)
        record = self.proof()
        self.assertTrue(record["pass"], record["reasons"])


class RenamePairingTests(unittest.TestCase):
    """Main deletes f and s and adds x and y; diff -M and merge-ort pair them differently."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        common = "".join(f"common shared line number {n:02d} with some padding text\n"
                         for n in range(1, 19))
        f_body = common + "f only line one alpha\nf only line two beta\n"
        s_body = common + "s only line one gamma\ns only line two delta\n"
        git(self.repo, "init", "-q", "-b", "main")
        commit_file(self.repo, "f.txt", f_body, "base f")
        commit_file(self.repo, "s.txt", s_body, "base s")
        git(self.repo, "checkout", "-q", "-b", "topic")
        edited = f_body.replace(common.splitlines(keepends=True)[2], "BRANCH EDIT OF LINE THREE\n")
        self.gated = commit_file(self.repo, "f.txt", edited, "branch edit f")
        git(self.repo, "checkout", "-q", "main")
        git(self.repo, "rm", "-q", "f.txt", "s.txt")
        x_body = ("".join(common.splitlines(keepends=True)[:12])
                  + "f only line one alpha\nf only line two beta\n"
                  + "".join(f"x new line {n}\n" for n in range(1, 7)))
        y_body = s_body + "y new line 1\n"
        (self.repo / "x.txt").write_text(x_body, encoding="utf-8")
        (self.repo / "y.txt").write_text(y_body, encoding="utf-8")
        git(self.repo, "add", "x.txt", "y.txt")
        git(self.repo, "commit", "-q", "-m", "main replaces f and s with x and y")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "merge", "-q", "--no-edit", "main")

    def tearDown(self):
        self.tmp.cleanup()

    def proof(self) -> dict:
        return bd.carry_forward(self.repo, self.gated, "HEAD", "origin/main")

    def test_merge_as_git_produced_it_passes(self):
        record = self.proof()
        self.assertTrue(record["pass"], record["reasons"])

    def test_merge_with_branch_hunk_restored_away_fails(self):
        # Git put the branch edit into y.txt; restoring y.txt to main's copy drops it.
        self.assertIn("BRANCH EDIT", (self.repo / "y.txt").read_text(encoding="utf-8"))
        git(self.repo, "checkout", "-q", "origin/main", "--", "y.txt")
        git(self.repo, "commit", "-q", "--amend", "--no-edit")
        self.assertNotIn("BRANCH EDIT", (self.repo / "y.txt").read_text(encoding="utf-8"))
        record = self.proof()
        self.assertFalse(record["pass"])
        self.assertTrue(any(reason.startswith("y.txt:") for reason in record["reasons"]),
                        record["reasons"])


class DeltaRangeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self.tmp.name)
        git(self.repo, "init", "-q", "-b", "main")
        self.anchor = commit_file(self.repo, "a.txt", "a\n", "base")

    def tearDown(self):
        self.tmp.cleanup()

    def test_linear_follow_up_has_no_merges_and_a_diff(self):
        head = commit_file(self.repo, "a.txt", "a\nb\n", "follow-up")
        span = bd.delta_range(self.repo, self.anchor, head)
        self.assertTrue(span["ancestor"])
        self.assertEqual(span["merges"], [])
        self.assertIn(b"+b", span["diff"])

    def test_merge_inside_the_range_is_reported(self):
        git(self.repo, "checkout", "-q", "-b", "side")
        commit_file(self.repo, "b.txt", "b\n", "side")
        git(self.repo, "checkout", "-q", "main")
        commit_file(self.repo, "c.txt", "c\n", "main")
        git(self.repo, "merge", "-q", "--no-edit", "side")
        span = bd.delta_range(self.repo, self.anchor, "HEAD")
        self.assertEqual(len(span["merges"]), 1)

    def test_derive_anchor_without_merges_is_the_gated_head(self):
        head = commit_file(self.repo, "a.txt", "a\nb\n", "follow-up")
        self.assertEqual(bd.derive_anchor(self.repo, self.anchor, head), self.anchor)

    def test_derive_anchor_is_the_last_merge_before_head(self):
        git(self.repo, "checkout", "-q", "-b", "side")
        commit_file(self.repo, "b.txt", "b\n", "side")
        git(self.repo, "checkout", "-q", "main")
        commit_file(self.repo, "c.txt", "c\n", "main")
        git(self.repo, "merge", "-q", "--no-edit", "side")
        merge = git(self.repo, "rev-parse", "HEAD")
        head = commit_file(self.repo, "a.txt", "a\nb\n", "follow-up")
        self.assertEqual(bd.derive_anchor(self.repo, self.anchor, head), merge)

    def test_non_ancestor_anchor_is_reported(self):
        git(self.repo, "checkout", "-q", "-b", "side")
        side = commit_file(self.repo, "b.txt", "b\n", "side")
        git(self.repo, "checkout", "-q", "main")
        head = commit_file(self.repo, "c.txt", "c\n", "main")
        self.assertFalse(bd.delta_range(self.repo, side, head)["ancestor"])


if __name__ == "__main__":
    unittest.main()
