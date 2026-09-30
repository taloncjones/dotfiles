"""pr_status.py end to end against a fake gh (spec R2, R6, R7, R8, R10)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "pr_status.py"
FAKE_GH = Path(__file__).resolve().parent / "fake_gh.py"
HEAD7 = "a" * 40
HEAD8 = "d" * 40
OLD = "b" * 40
URL7 = "https://github.com/org/alpha/pull/7"
URL8 = "https://github.com/org/alpha/pull/8"
GREEN = [{"__typename": "CheckRun", "name": "lint", "status": "COMPLETED", "conclusion": "SUCCESS"}]


def pr_json(number, head, **over):
    pr = {"number": number, "title": f"Change {number}", "url": f"https://github.com/org/alpha/pull/{number}",
          "state": "OPEN", "headRefName": f"topic-{number}", "headRefOid": head, "isDraft": False,
          "reviewDecision": "", "reviewRequests": [], "statusCheckRollup": GREEN,
          "body": "## Test plan\n- [x] unit tests\n", "commits": [{"oid": head}]}
    return {**pr, **over}


def approve_at(head, cid):
    return [[{"id": cid, "html_url": f"https://github.com/org/alpha/pull/7#issuecomment-{cid}",
              "created_at": "2026-09-29T10:00:00Z", "user": {"login": "me"},
              "body": f"<!-- co-review: sha={head} base={'c' * 40} base_ref=main verdict=APPROVE round=2 -->"}]]


def gh_env(tmp):
    """Env whose PATH resolves gh to the fake, with HOME and config isolated."""
    bin_dir = Path(tmp) / "bin"
    bin_dir.mkdir()
    (bin_dir / "gh").write_text(f"#!/bin/sh\nexec {sys.executable} {FAKE_GH} \"$@\"\n")
    (bin_dir / "gh").chmod(0o755)
    fixtures = Path(tmp) / "fixtures"
    fixtures.mkdir()
    (fixtures / "user.txt").write_text("me\n")
    home = Path(tmp) / "home"
    home.mkdir()
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CONFIG_DIR"}
    env.update(PATH=f"{bin_dir}:/usr/bin:/bin", HOME=str(home), FAKE_GH_DIR=str(fixtures),
               HERDR_COORDINATION_ROOT=str(Path(tmp) / "coord"))
    return env, fixtures


def calls(fixtures):
    return [json.loads(line) for line in (fixtures / "calls.log").read_text().splitlines()]


class CliTable(unittest.TestCase):
    def test_markdown_golden_two_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json(7, HEAD7)))
            (fx / "comments_org_alpha_7.json").write_text(json.dumps(approve_at(HEAD7, 11)))
            (fx / "runs_org_alpha_hil.yaml_topic-7.json").write_text(json.dumps([
                {"databaseId": 42, "headSha": HEAD7, "status": "completed", "conclusion": "success",
                 "createdAt": "2026-09-29T10:00:00Z", "url": "https://github.com/org/alpha/actions/runs/42"}]))
            (fx / "pr_org_alpha_8.json").write_text(json.dumps(pr_json(8, HEAD8, isDraft=True)))
            (fx / "comments_org_alpha_8.json").write_text(json.dumps(approve_at(OLD, 12)))
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "8", "7",
                                   "--bench-workflow", "hil.yaml", "--markdown"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout, "\n".join([
                "| PR | Head | CI | Co-review at head | Bench / UAT | Body current | Draft | Waiting on |",
                "| --- | --- | --- | --- | --- | --- | --- | --- |",
                f"| [#7]({URL7}) Change 7 | [{HEAD7[:9]}](https://github.com/org/alpha/commit/{HEAD7}) | green"
                f" | r2 APPROVE ([11]({URL7}#issuecomment-11)) | success [42](https://github.com/org/alpha/actions/runs/42)"
                " | yes | no | merge (human) |",
                f"| [#8]({URL8}) Change 8 | [{HEAD8[:9]}](https://github.com/org/alpha/commit/{HEAD8}) | green"
                f" | stale (r2 at {OLD[:9]}) | none at head | yes | yes | co-review at head |",
            ]) + "\n")
            for argv in calls(fx):
                self.assertIn(argv[0], ("api", "repo", "pr", "run"))

    def test_json_rows_carry_repo_number_and_cells(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json(7, HEAD7)))
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "7"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            out = json.loads(proc.stdout)
            self.assertEqual(out["repo"], "org/alpha")
            self.assertEqual(out["errors"], [])
            row = out["rows"][0]
            self.assertEqual(sorted(row), sorted(["repo", "number", "pr", "head", "ci", "co_review",
                                                 "bench", "body", "draft", "waiting_on"]))
            self.assertEqual((row["repo"], row["number"], row["bench"], row["waiting_on"]),
                             ("org/alpha", 7, "n/a", "co-review at head"))

    def test_rows_are_deduplicated_and_sorted(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json(7, HEAD7)))
            (fx / "pr_org_alpha_8.json").write_text(json.dumps(pr_json(8, HEAD8)))
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "8", "7", "8"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual([r["number"] for r in json.loads(proc.stdout)["rows"]], [7, 8])

    def test_explicit_merged_pr_is_shown_as_merged(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json(7, HEAD7, state="MERGED")))
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "7"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(json.loads(proc.stdout)["rows"][0]["waiting_on"], "merged")

    def test_config_bench_workflow_is_used_per_repo(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            config = Path(tmp) / "projects.json"
            config.write_text(json.dumps({"proj": {"github_repos": ["org/alpha"],
                                                   "bench_workflows": {"org/alpha": "bench.yml"}}}))
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json(7, HEAD7)))
            (fx / "comments_org_alpha_7.json").write_text(json.dumps(approve_at(HEAD7, 11)))
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "7", "--config", str(config)],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            row = json.loads(proc.stdout)["rows"][0]
            self.assertEqual((row["bench"], row["waiting_on"]), ("none at head", "bench run"))
            self.assertIn(["run", "list", "--repo", "org/alpha", "--workflow", "bench.yml", "--branch", "topic-7",
                           "--limit", "10", "--json", "databaseId,headSha,status,conclusion,createdAt,url"],
                          calls(fx))

    def test_current_branch_pr_without_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "repo.json").write_text(json.dumps({"nameWithOwner": "org/alpha"}))
            (fx / "current.json").write_text(json.dumps({"number": 7}))
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json(7, HEAD7)))
            proc = subprocess.run([sys.executable, str(SCRIPT)], cwd=tmp, env=env,
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual([r["number"] for r in json.loads(proc.stdout)["rows"]], [7])

    def test_current_branch_pr_that_is_merged_is_dropped(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "repo.json").write_text(json.dumps({"nameWithOwner": "org/alpha"}))
            (fx / "current.json").write_text(json.dumps({"number": 7}))
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json(7, HEAD7, state="MERGED")))
            proc = subprocess.run([sys.executable, str(SCRIPT)], cwd=tmp, env=env,
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(json.loads(proc.stdout)["rows"], [])


class CliErrors(unittest.TestCase):
    def test_failed_pr_fetch_is_an_error_row_and_exit_1(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "fail_pr_org_alpha_7.json").write_text("GraphQL: Could not resolve to a PullRequest\nmore\n")
            (fx / "pr_org_alpha_8.json").write_text(json.dumps(pr_json(8, HEAD8)))
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "7", "8", "--markdown"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 1, proc.stderr)
            lines = proc.stdout.splitlines()
            self.assertEqual(lines[2], f"| [#7]({URL7}) | ? | ? | ? | ? | ? | ? | "
                                       "error: GraphQL: Could not resolve to a PullRequest |")
            self.assertTrue(lines[3].startswith(f"| [#8]({URL8}) Change 8 |"))

    def test_failed_comments_fetch_is_an_error_row(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "pr_org_alpha_7.json").write_text(json.dumps(pr_json(7, HEAD7)))
            (fx / "fail_comments_org_alpha_7.json").write_text("HTTP 502\n")
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "7"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 1)
            out = json.loads(proc.stdout)
            self.assertEqual(out["rows"][0]["waiting_on"], "error: HTTP 502")
            self.assertEqual(out["errors"], ["org/alpha#7: HTTP 502"])

    def test_gh_user_failure_exits_2_without_table(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (fx / "fail_user.txt").write_text("gh auth login required\n")
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "7"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual((proc.returncode, proc.stdout), (2, ""))
            self.assertIn("gh auth login required", proc.stderr)

    def test_missing_gh_exits_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, _fx = gh_env(tmp)
            env["PATH"] = str(Path(tmp) / "home")
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "7"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual((proc.returncode, proc.stdout), (2, ""))
            self.assertIn("gh not found", proc.stderr)

    def test_repo_without_numbers_is_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha"],
                                  cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(proc.returncode, 2)
            self.assertFalse((fx / "calls.log").exists())

    def test_unreadable_config_is_usage_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, fx = gh_env(tmp)
            (Path(tmp) / "bad.json").write_text("{not json")
            (Path(tmp) / "list.json").write_text("[]")
            for name in ("missing.json", "fixtures", "bad.json", "list.json"):
                with self.subTest(config=name):
                    proc = subprocess.run([sys.executable, str(SCRIPT), "--repo", "org/alpha", "7",
                                           "--config", str(Path(tmp) / name)],
                                          cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
                    self.assertEqual((proc.returncode, proc.stdout), (2, ""))
                    self.assertIn("--config is not a readable JSON object", proc.stderr)
                    self.assertFalse((fx / "calls.log").exists())

    def test_no_repo_anywhere_exits_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            env, _fx = gh_env(tmp)
            proc = subprocess.run([sys.executable, str(SCRIPT), "7"], cwd=tmp, env=env,
                                  capture_output=True, text=True, timeout=60)
            self.assertEqual((proc.returncode, proc.stdout), (2, ""))


if __name__ == "__main__":
    unittest.main()
