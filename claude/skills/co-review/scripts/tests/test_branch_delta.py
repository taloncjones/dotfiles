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

    def test_merge_that_edits_an_outside_file_fails_scope(self):
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
