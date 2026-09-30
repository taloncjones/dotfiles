"""Herdr task discovery, merge authority, and no bytecode writes (spec R3, R5.8, R8)."""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "pr_status.py"
FAKE_GH = Path(__file__).resolve().parent / "fake_gh.py"
CLAUDE_DIR = SCRIPT.parents[3]
_spec = importlib.util.spec_from_file_location("pr_status", SCRIPT)
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)

HEAD = "a" * 40
GREEN = [{"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS"}]
SCRUB = ("CLAUDE_CONFIG_DIR", "CLAUDE_PERSONAL_ONLY", "XDG_STATE_HOME", "WORKFLOW_PERSONAL_ACCOUNT",
         "CLAUDE_WORK_CONFIG_DIR", "CLAUDE_WORK_TREE", "CODEX_HOME", "HERDR_ENV", "HERDR_WORKSPACE_ID",
         "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_ACCOUNT_ID", "HERDR_PERSONAL", "PYTHONDONTWRITEBYTECODE")


def pr_json(repo, number, **over):
    pr = {"number": number, "title": f"Change {number}", "url": f"https://github.com/{repo}/pull/{number}",
          "state": "OPEN", "headRefName": f"topic-{number}", "headRefOid": HEAD, "isDraft": False,
          "reviewDecision": "", "reviewRequests": [], "statusCheckRollup": GREEN,
          "body": "", "commits": [{"oid": HEAD}]}
    return {**pr, **over}


def approve(repo, number):
    return [[{"id": 1, "html_url": f"https://github.com/{repo}/pull/{number}#issuecomment-1",
              "created_at": "2026-09-29T10:00:00Z", "user": {"login": "me"},
              "body": f"<!-- co-review-audit head={HEAD} run=r1 -->"}]]


def herdr_fixture(tmp, claude_dir):
    """A personal repo with origin org/alpha, its herdr tasks dir, a fake gh, and the env to run in it."""
    home = Path(tmp) / "home"
    repo = home / "Git" / "personal" / "alpha"
    repo.mkdir(parents=True)
    bin_dir = Path(tmp) / "bin"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(f"#!/bin/sh\nexec {sys.executable} {FAKE_GH} \"$@\"\n")
    (bin_dir / "gh").chmod(0o755)
    fixtures = Path(tmp) / "fixtures"
    fixtures.mkdir()
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    env.update(HOME=str(home), PATH=f"{bin_dir}:/usr/bin:/bin", FAKE_GH_DIR=str(fixtures),
               HERDR_COORDINATION_ROOT=str(Path(tmp) / "coord"),
               GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    git = ["git", "-C", str(repo), "-c", "user.name=f", "-c", "user.email=f@example.invalid",
           "-c", "commit.gpgsign=false"]
    subprocess.run([*git, "init", "-q", "-b", "trunk"], check=True, env=env)
    subprocess.run([*git, "remote", "add", "origin", "https://github.com/org/alpha.git"], check=True, env=env)
    subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "f"], check=True, env=env)
    probe = ("import sys, types; sys.path.insert(0, sys.argv[1]); import herdr_orch_core as c; "
             "ctx = c.repository_context(sys.argv[2]); slug = c._context_slug(ctx); "
             "c.select_payload(types.SimpleNamespace(repo_path=sys.argv[2], runtime='claude', "
             "personal=False, repo_slug=slug)); print(c.repo_dir(slug))")
    out = subprocess.run([sys.executable, "-B", "-c", probe, str(claude_dir / "hooks"), str(repo)],
                         check=True, env=env, capture_output=True, text=True)
    tasks = Path(out.stdout.strip()) / "tasks"
    tasks.mkdir(parents=True)
    (fixtures / "user.txt").write_text("me\n")
    (fixtures / "repo.json").write_text(json.dumps({"nameWithOwner": "org/alpha"}))
    return repo, tasks, fixtures, env


def snapshot(root):
    return sorted((str(p), p.stat().st_size, p.stat().st_mtime_ns) for p in Path(root).rglob("*"))


class HerdrPrs(unittest.TestCase):
    def test_records_select_open_prs_and_submodule_pairs(self):
        core = ps.load_core()
        with tempfile.TemporaryDirectory() as tmp:
            tasks = Path(tmp)
            records = {
                "t-open": {"status": "in-progress", "pr_number": 7},
                "t-pr-field": {"status": "reviewed", "pr_number": None, "pr": 8},
                "t-pair": {"status": "completed", "pr_number": 9,
                           "submodule_pr": {"repo": "org/sub", "number": 3}},
                "t-bad-sub": {"status": "completed", "pr_number": 10, "submodule_pr": {"repo": "x", "number": 3}},
                "t-merged": {"status": "merged", "pr_number": 11},
                "t-abandoned": {"status": "abandoned", "pr_number": 12},
                "t-failed": {"status": "failed", "pr_number": 13},
                "t-bool": {"status": "in-progress", "pr_number": True},
                "t-none": {"status": "kickoff", "pr_number": None},
            }
            for name, rec in records.items():
                (tasks / f"{name}.json").write_text(json.dumps(rec))
            (tasks / "t-open.done.json").write_text(json.dumps({"pr_number": 99}))
            (tasks / "t-corrupt.json").write_text("{not json")
            got = ps.herdr_prs(core, tasks)
        self.assertEqual(sorted(got, key=lambda item: item[0]), [
            (7, None), (8, None), (9, {"repo": "org/sub", "number": 3}), (10, None)])


class HerdrRun(unittest.TestCase):
    def test_task_prs_submodule_pair_and_director_merge(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tasks, fx, env = herdr_fixture(tmp, CLAUDE_DIR)
            (tasks / "t-a.json").write_text(json.dumps({"status": "reviewed", "pr_number": 7,
                                                        "submodule_pr": {"repo": "org/sub", "number": 3}}))
            (tasks / "t-b.json").write_text(json.dumps({"status": "in-progress", "pr_number": 8}))
            (tasks / "t-c.json").write_text(json.dumps({"status": "merged", "pr_number": 5}))
            (tasks / "t-d.json").write_text(json.dumps({"status": "reviewed", "pr_number": 6}))
            (fx / "current.json").write_text(json.dumps({"number": 8}))
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json("org/alpha", 7)))
            (fx / "comments_org_alpha_7.json").write_text(json.dumps(approve("org/alpha", 7)))
            (fx / "pr_org_alpha_8.json").write_text(json.dumps(pr_json("org/alpha", 8)))
            (fx / "comments_org_alpha_8.json").write_text(json.dumps(approve("org/alpha", 8)))
            (fx / "pr_org_alpha_6.json").write_text(json.dumps(pr_json("org/alpha", 6, state="MERGED")))
            (fx / "pr_org_sub_3.json").write_text(json.dumps(pr_json("org/sub", 3)))
            (fx / "comments_org_sub_3.json").write_text(json.dumps(approve("org/sub", 3)))
            state = tasks.parent
            before = snapshot(state)
            proc = subprocess.run([sys.executable, str(SCRIPT)], cwd=repo, env=env,
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(snapshot(state), before)
            rows = json.loads(proc.stdout)["rows"]
            self.assertEqual([(r["repo"], r["number"]) for r in rows],
                             [("org/alpha", 7), ("org/alpha", 8), ("org/sub", 3)])
            self.assertEqual(rows[0]["waiting_on"],
                             "submodule PR [#3](https://github.com/org/sub/pull/3) merge + re-pin; merge (director)")
            self.assertEqual(rows[1]["waiting_on"], "merge (director)")
            self.assertTrue(rows[2]["pr"].startswith("sub [#3]("))
            self.assertEqual(rows[2]["waiting_on"], "merge (human)")

    def test_merged_submodule_pr_drops_row_and_prefix(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, tasks, fx, env = herdr_fixture(tmp, CLAUDE_DIR)
            (tasks / "t-a.json").write_text(json.dumps({"status": "reviewed", "pr_number": 7,
                                                        "submodule_pr": {"repo": "org/sub", "number": 3}}))
            (fx / "fail_current.json").write_text("no pull requests found for branch\n")
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json("org/alpha", 7)))
            (fx / "comments_org_alpha_7.json").write_text(json.dumps(approve("org/alpha", 7)))
            (fx / "pr_org_sub_3.json").write_text(json.dumps(pr_json("org/sub", 3, state="MERGED")))
            proc = subprocess.run([sys.executable, str(SCRIPT)], cwd=repo, env=env,
                                  capture_output=True, text=True, timeout=120)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            rows = json.loads(proc.stdout)["rows"]
            self.assertEqual([(r["number"], r["waiting_on"]) for r in rows], [(7, "merge (director)")])

    def test_no_bytecode_written_while_core_is_loaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "copy" / "claude"
            ignore = shutil.ignore_patterns("__pycache__", "*.pyc")
            shutil.copytree(CLAUDE_DIR / "hooks", copy / "hooks", ignore=ignore)
            shutil.copytree(CLAUDE_DIR / "skills" / "lib", copy / "skills" / "lib", ignore=ignore)
            shutil.copytree(CLAUDE_DIR / "skills" / "co-review" / "scripts",
                            copy / "skills" / "co-review" / "scripts", ignore=ignore)
            (copy / "skills" / "pr-status" / "scripts").mkdir(parents=True)
            shutil.copy2(SCRIPT, copy / "skills" / "pr-status" / "scripts" / "pr_status.py")
            repo, tasks, fx, env = herdr_fixture(tmp, copy)
            (tasks / "t-a.json").write_text(json.dumps({"status": "reviewed", "pr_number": 7}))
            (fx / "fail_current.json").write_text("no pull requests found for branch\n")
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json("org/alpha", 7)))
            proc = subprocess.run([sys.executable, str(copy / "skills" / "pr-status" / "scripts" / "pr_status.py")],
                                  cwd=repo, env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual([r["number"] for r in json.loads(proc.stdout)["rows"]], [7])
            self.assertEqual(sorted(str(p) for p in copy.rglob("__pycache__")), [])


if __name__ == "__main__":
    unittest.main()
