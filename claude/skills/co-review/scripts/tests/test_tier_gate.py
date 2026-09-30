"""Carry-forward and delta-tier CLI and evaluator tests over fixture repos."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
GATE = SCRIPTS / "gate_report.py"
_spec = importlib.util.spec_from_file_location("gate_report", GATE)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

GIT_ENV = {
    **{k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
    "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
}
AXES = ("ownership_authority", "dependency_boundaries", "contract_coherence",
        "state_effects", "lifecycle_operations", "demonstrability_constraints")
CHECKLIST = ("quoting_separators", "symlinks", "content_filters", "hostile_git_config",
             "signals_toctou", "temp_dir_lifecycle", "fail_open_exits",
             "ignored_untracked_overwrites", "fetch_ref_races", "replayable_file_authority",
             "resume_retry_revalidation", "writer_reader_parity", "functional_behavior",
             "snapshot_integrity", "preconditions_ci", "threat_model")
BASE_SHA = "b" * 40


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, env=GIT_ENV,
                          capture_output=True, text=True).stdout.strip()


def commit_file(repo: Path, name: str, body: str) -> str:
    (repo / name).parent.mkdir(parents=True, exist_ok=True)
    (repo / name).write_text(body, encoding="utf-8")
    git(repo, "add", "--", name)
    git(repo, "commit", "-q", "-m", f"edit {name}")
    return git(repo, "rev-parse", "HEAD")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def artifact(root: Path, name: str, body: str) -> dict:
    (root / name).write_text(body, encoding="utf-8")
    return {"artifact": name, "sha256": sha256(root / name)}


def write_run(run: Path, run_id: str, head: str, tier: str, seats: tuple[str, ...],
              runtime: str = "claude") -> tuple[dict, dict]:
    """A complete gate report and expected identity for head (data, not flow)."""
    run.mkdir(parents=True, exist_ok=True)
    seat_entries = {
        name: {"status": "complete", **artifact(run, f"{name}.txt", f"{name} ok\n"),
               "runtime": runtime, "model": "unknown", "effort": "unknown"}
        for name in seats
    }
    ci = {"head": head, "check_runs": [{"name": "t", "status": "COMPLETED",
                                        "conclusion": "SUCCESS"}], "status_contexts": []}
    identity = {"schema_version": 1, "run_id": run_id, "repository": "o/r", "pr_number": 3,
                "head": head, "base": BASE_SHA, "base_ref": "main", "tree": head}
    report = {
        **identity, "reviewed_tree": head, "class": tier, "seats": seat_entries,
        "findings": [], "prior_blockers": [],
        "coverage": {"architecture": {k: "checked" for k in AXES},
                     "checklist": {k: "checked" for k in CHECKLIST}},
        "preconditions": {"head": head, "tree": head,
                          "diff": artifact(run, "frozen.diff",
                                           "diff --git a/x.py b/x.py\n+x\n"),
                          "ci": artifact(run, "ci.json", json.dumps(ci))},
    }
    expected = {**identity, "known_blockers": [], "class": tier}
    return report, expected


def save(run: Path, report: dict, expected: dict) -> tuple[Path, Path]:
    (run / "report.json").write_text(json.dumps(report), encoding="utf-8")
    (run / "expected.json").write_text(json.dumps(expected), encoding="utf-8")
    return run / "report.json", run / "expected.json"


def cli(*args: str) -> tuple[int, dict]:
    result = subprocess.run([sys.executable, str(GATE), *args], capture_output=True,
                            text=True, check=False)
    return result.returncode, json.loads(result.stdout)


class TierFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        commit_file(self.repo, "shared.txt", "one\n")
        git(self.repo, "checkout", "-q", "-b", "topic")
        self.gated = commit_file(self.repo, "src/app.py", "print(1)\n")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")
        report, expected = write_run(self.root / "prior", "full-1", self.gated, "full",
                                     gate.FULL_SEATS, runtime="known")
        self.report_path, self.expected_path = save(self.root / "prior", report, expected)

    def tearDown(self):
        self.tmp.cleanup()

    def pins(self) -> list[str]:
        return ["--report", str(self.report_path), "--expected", str(self.expected_path),
                "--report-sha256", sha256(self.report_path),
                "--expected-sha256", sha256(self.expected_path)]

    def merge_main(self) -> str:
        git(self.repo, "checkout", "-q", "main")
        commit_file(self.repo, "main_only.txt", "m\n")
        git(self.repo, "update-ref", "refs/remotes/origin/main", "main")
        git(self.repo, "checkout", "-q", "topic")
        git(self.repo, "merge", "-q", "--no-edit", "main")
        return git(self.repo, "rev-parse", "HEAD")


class CarryForwardCliTests(TierFixture):
    def test_merge_main_only_passes_with_an_audit_comment_for_the_new_head(self):
        head = self.merge_main()
        code, record = cli("carry-forward", "--repo", str(self.repo), *self.pins())
        self.assertEqual(code, 0, record["reasons"])
        self.assertEqual((record["prior_run"], record["prior_head"], record["head"]),
                         ("full-1", self.gated, head))
        self.assertTrue(record["audit_comment"].startswith(
            f"<!-- co-review-audit head={head} run=full-1 tier=carry-forward "
            f"prior_head={self.gated} -->\n"))
        self.assertIn("$ git rev-list --no-merges", record["audit_comment"])

    def test_digest_mismatch_fails(self):
        self.merge_main()
        args = self.pins()
        args[args.index("--report-sha256") + 1] = "0" * 64
        code, record = cli("carry-forward", "--repo", str(self.repo), *args)
        self.assertEqual((code, record["pass"]), (1, False))
        self.assertIn("prior report digest does not match its pin", record["reasons"])
        self.assertIsNone(record["audit_comment"])

    def test_non_approving_prior_fails(self):
        self.merge_main()
        report = json.loads(self.report_path.read_text())
        report["findings"] = [{"id": "f", "severity": "high", "disposition": "confirmed",
                               "scenario": "s", "evidence": "e", "impact": "i"}]
        self.report_path.write_text(json.dumps(report))
        code, record = cli("carry-forward", "--repo", str(self.repo), *self.pins())
        self.assertEqual(code, 1)
        self.assertIn("prior gate verdict is CHANGES", record["reasons"])

    def test_stdout_is_byte_identical_across_reruns(self):
        self.merge_main()
        run = [sys.executable, str(GATE), "carry-forward", "--repo", str(self.repo), *self.pins()]
        first = subprocess.run(run, capture_output=True, check=False).stdout
        self.assertEqual(first, subprocess.run(run, capture_output=True, check=False).stdout)

if __name__ == "__main__":
    unittest.main()
