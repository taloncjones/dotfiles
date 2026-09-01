#!/usr/bin/env python3
"""Unit tests for the pure functions in recall.py."""
import importlib.util
import os
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("recall", HERE.parent / "recall.py")
recall = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recall)


class SlugAndRepoId(unittest.TestCase):
    def test_slug_replaces_every_non_alnum_with_dash(self):
        self.assertEqual(recall.slug("/Users/t/Git/x.y/a+b"), "-Users-t-Git-x-y-a-b")

    def test_slug_is_byte_wise_for_non_ascii(self):
        # e-acute is two UTF-8 bytes, so it becomes two dashes, as Claude Code does.
        self.assertEqual(recall.slug("/tmp/café"), "-tmp-caf--")

    def test_repo_id_is_bounded_and_distinct_for_colliding_slugs(self):
        a = recall.repo_id(Path("/tmp/x.y"))
        b = recall.repo_id(Path("/tmp/x-y"))
        self.assertNotEqual(a, b)
        self.assertTrue(a.startswith("-tmp-x-y-"))
        self.assertEqual(len(a.rsplit("-", 1)[1]), 12)
        long = recall.repo_id(Path("/" + "a" * 300))
        self.assertLessEqual(len(long), 80 + 1 + 12)


class Routing(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.home = self.tmp / "home"
        self.work_tree = self.home / "Git" / "work"
        (self.work_tree / "repo").mkdir(parents=True)
        (self.home / "Git" / "personal" / "repo").mkdir(parents=True)
        self.env = {"HOME": str(self.home)}

    def test_explicit_config_dir_wins(self):
        env = dict(self.env, CLAUDE_CONFIG_DIR=str(self.tmp / "cfg"))
        got = recall.resolve_config_dir(self.work_tree / "repo", env)
        self.assertEqual(got, self.tmp / "cfg")

    def test_work_tree_routes_to_work_config_dir(self):
        got = recall.resolve_config_dir((self.work_tree / "repo").resolve(), self.env)
        self.assertEqual(got, self.home / ".claude-work")

    def test_work_config_dir_env_override(self):
        env = dict(self.env, CLAUDE_WORK_CONFIG_DIR=str(self.tmp / "w"))
        got = recall.resolve_config_dir((self.work_tree / "repo").resolve(), env)
        self.assertEqual(got, self.tmp / "w")

    def test_personal_tree_routes_to_personal(self):
        got = recall.resolve_config_dir(
            (self.home / "Git" / "personal" / "repo").resolve(), self.env)
        self.assertEqual(got, self.home / ".claude")

    def test_index_path_inside_repo_raises(self):
        top = (self.home / "Git" / "personal" / "repo").resolve()
        with self.assertRaises(recall.ConfigError):
            recall.index_path(top / ".claude", top, top)

    def test_index_path_layout(self):
        top = (self.home / "Git" / "personal" / "repo").resolve()
        got = recall.index_path(self.home / ".claude", top, top)
        self.assertEqual(got.name, "index.db")
        self.assertEqual(got.parent.parent, self.home / ".claude" / "recall")
        self.assertEqual(got.parent.name, recall.repo_id(top))


class Fts5Probe(unittest.TestCase):
    def test_force_flag_disables(self):
        os.environ["RECALL_FORCE_NO_FTS5"] = "1"
        try:
            self.assertFalse(recall.fts5_available())
        finally:
            del os.environ["RECALL_FORCE_NO_FTS5"]


if __name__ == "__main__":
    sys.exit(unittest.main())
