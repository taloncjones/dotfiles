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


class Sources(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.top = self.tmp / "repo"
        self.cfg = self.tmp / "cfg"
        self.home = self.tmp / "home"
        for rel in ["docs/specs", "docs/findings", ".claude/handoffs", ".todos/pending",
                    ".todos/completed", ".hidden", "node_modules", "extra"]:
            (self.top / rel).mkdir(parents=True)
        self.write("docs/specs/s.md", "# S\nbody")
        self.write("docs/findings/f.md", "# F\nbody")
        self.write("docs/findings/f.txt", "plain finding")
        self.write(".claude/handoffs/h.md", "# H\nbody")
        self.write(".todos/pending/t.md", "# T\nbody")
        self.write(".todos/TODO.md", "index")
        self.write("README.md", "# R\nbody")
        self.write(".hidden/x.md", "# X\nbody")
        self.write("node_modules/n.md", "# N\nbody")
        self.write("extra/e.txt", "extra text")
        self.write("extra/e.py", "print(1)")
        mem = self.cfg / "projects" / recall.slug(self.top) / "memory"
        mem.mkdir(parents=True)
        (mem / "m.md").write_text("# M\nbody")
        (mem / "MEMORY.md").write_text("index")
        self.env = {"HOME": str(self.home)}

    def write(self, rel, text):
        p = self.top / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def kinds(self, env=None):
        srcs = recall.collect_sources(self.top, self.top, self.cfg, env or self.env, quiet=True)
        return {s.display: s.kind for s in srcs}

    def test_kinds_and_precedence(self):
        got = self.kinds()
        self.assertEqual(got["docs/specs/s.md"], "docs")
        self.assertEqual(got["docs/findings/f.md"], "findings")
        self.assertEqual(got["docs/findings/f.txt"], "findings")
        self.assertEqual(got[".claude/handoffs/h.md"], "handoffs")
        self.assertEqual(got[".todos/pending/t.md"], "todos")
        self.assertEqual(got["README.md"], "docs")
        self.assertNotIn(".todos/TODO.md", got)
        self.assertNotIn(".hidden/x.md", got)
        self.assertNotIn("node_modules/n.md", got)
        self.assertNotIn("extra/e.txt", got)

    def test_memory_display_and_index_skip(self):
        got = self.kinds()
        mem = [d for d, k in got.items() if k == "memory"]
        self.assertEqual(len(mem), 1)
        self.assertTrue(mem[0].endswith("/memory/m.md"))

    def test_memory_display_is_tilde_relative_when_under_home(self):
        cfg = self.home / ".claude"
        mem = cfg / "projects" / recall.slug(self.top) / "memory"
        mem.mkdir(parents=True)
        (mem / "m.md").write_text("# M\nbody")
        srcs = recall.collect_sources(self.top, self.top, cfg, self.env, quiet=True)
        mem_display = [s.display for s in srcs if s.kind == "memory"]
        self.assertEqual(mem_display, [f"~/.claude/projects/{recall.slug(self.top)}/memory/m.md"])

    def test_extra_globs_and_containment(self):
        env = dict(self.env, RECALL_EXTRA_GLOBS="extra/*.txt:extra/*.py:../outside/*.md")
        got = self.kinds(env)
        self.assertEqual(got["extra/e.txt"], "extra")
        self.assertNotIn("extra/e.py", got)
        self.assertFalse(any(d.startswith("..") for d in got))

    def test_each_path_once(self):
        srcs = recall.collect_sources(self.top, self.top, self.cfg, self.env, quiet=True)
        paths = [s.path for s in srcs]
        self.assertEqual(len(paths), len(set(paths)))

    def test_oversized_and_symlink_excluded(self):
        self.write("docs/big.md", "x" * (recall.MAX_FILE_BYTES + 1))
        os.symlink(self.top / "docs/specs/s.md", self.top / "docs/link.md")
        os.symlink(self.top / "docs/specs", self.top / "docs/linkdir")
        got = self.kinds()
        self.assertNotIn("docs/big.md", got)
        self.assertNotIn("docs/link.md", got)
        self.assertFalse(any(d.startswith("docs/linkdir/") for d in got))

    def test_extra_glob_double_star_matches_nested_and_direct(self):
        self.write("notes/a.txt", "a")
        self.write("notes/deep/b.txt", "b")
        env = dict(self.env, RECALL_EXTRA_GLOBS="notes/**/*.txt")
        got = self.kinds(env)
        self.assertEqual(got["notes/a.txt"], "extra")
        self.assertEqual(got["notes/deep/b.txt"], "extra")

    def test_canonical_root_memory_included_for_worktree(self):
        canonical = self.tmp / "main"
        mem = self.cfg / "projects" / recall.slug(canonical) / "memory"
        mem.mkdir(parents=True)
        (mem / "c.md").write_text("# C\nbody")
        srcs = recall.collect_sources(self.top, canonical, self.cfg, self.env, quiet=True)
        self.assertEqual(sorted(Path(s.path).name for s in srcs if s.kind == "memory"),
                         ["c.md", "m.md"])


if __name__ == "__main__":
    sys.exit(unittest.main())
