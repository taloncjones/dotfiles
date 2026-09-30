"""Carry-forward and delta-tier CLI and evaluator tests over fixture repos."""

from __future__ import annotations

import copy
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

    def test_upstream_flag_is_not_accepted(self):
        self.merge_main()
        result = subprocess.run(
            [sys.executable, str(GATE), "carry-forward", "--repo", str(self.repo),
             *self.pins(), "--upstream", "HEAD"],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--upstream", result.stderr)

    def test_stdout_is_byte_identical_across_reruns(self):
        self.merge_main()
        run = [sys.executable, str(GATE), "carry-forward", "--repo", str(self.repo), *self.pins()]
        first = subprocess.run(run, capture_output=True, check=False).stdout
        self.assertEqual(first, subprocess.run(run, capture_output=True, check=False).stdout)

class DeltaClassCliTests(TierFixture):
    def test_small_follow_up_recommends_delta_and_writes_the_diff(self):
        head = commit_file(self.repo, "src/app.py", "print(2)\n")
        out = self.root / "delta.diff"
        code, rec = cli("delta-class", "--repo", str(self.repo), *self.pins(),
                        "--diff-out", str(out))
        self.assertEqual((code, rec["recommend"]), (0, "delta"), rec["reasons"])
        self.assertEqual((rec["anchor_head"], rec["head"], rec["carry_forward"]),
                         (self.gated, head, None))
        self.assertIn(b"+print(2)", out.read_bytes())

    def test_digest_mismatch_recommends_full(self):
        commit_file(self.repo, "src/app.py", "print(2)\n")
        args = self.pins()
        args[args.index("--expected-sha256") + 1] = "0" * 64
        code, rec = cli("delta-class", "--repo", str(self.repo), *args,
                        "--diff-out", str(self.root / "d.diff"))
        self.assertEqual((code, rec["recommend"]), (1, "full"))
        self.assertIn("prior expected digest does not match its pin", rec["reasons"])
        self.assertFalse((self.root / "d.diff").exists())

    def test_ci_workflow_change_recommends_full(self):
        commit_file(self.repo, ".github/workflows/ci.yml", "on: push\n")
        code, rec = cli("delta-class", "--repo", str(self.repo), *self.pins(),
                        "--diff-out", str(self.root / "d.diff"))
        self.assertEqual((code, rec["recommend"]), (1, "full"))
        self.assertIn("delta touches a ci path", rec["reasons"])

    def test_six_files_recommend_full(self):
        for n in range(6):
            commit_file(self.repo, f"src/f{n}.py", "x\n")
        code, rec = cli("delta-class", "--repo", str(self.repo), *self.pins(),
                        "--diff-out", str(self.root / "d.diff"))
        self.assertEqual(code, 1)
        self.assertIn("6 files exceed max_files 5", rec["reasons"])

    def test_merge_main_then_follow_up_anchors_on_the_merge(self):
        merge = self.merge_main()
        commit_file(self.repo, "src/app.py", "print(3)\n")
        code, rec = cli("delta-class", "--repo", str(self.repo), *self.pins(),
                        "--diff-out", str(self.root / "d.diff"))
        self.assertEqual(code, 0, rec["reasons"])
        self.assertEqual(rec["anchor_head"], merge)
        self.assertTrue(rec["carry_forward"]["pass"])

    def test_prior_light_round_recommends_full(self):
        report, expected = write_run(self.root / "light", "light-1", self.gated, "light",
                                     gate.LIGHT_SEATS)
        report["seats"]["codex"]["runtime"] = "codex"
        report["preconditions"]["diff"] = artifact(self.root / "light", "frozen.diff",
                                                   "diff --git a/README.md b/README.md\n+x\n")
        self.report_path, self.expected_path = save(self.root / "light", report, expected)
        commit_file(self.repo, "src/app.py", "print(2)\n")
        code, rec = cli("delta-class", "--repo", str(self.repo), *self.pins(),
                        "--diff-out", str(self.root / "d.diff"))
        self.assertEqual(code, 1)
        self.assertIn("first round on a branch is always full: no prior full APPROVE",
                      rec["reasons"])


class DeltaEvaluateTests(TierFixture):
    def build_delta(self) -> tuple[dict, dict, Path]:
        head = commit_file(self.repo, "src/app.py", "print(2)\n")
        run = self.root / "delta-run"
        run.mkdir()
        code, rec = cli("delta-class", "--repo", str(self.repo), *self.pins(),
                        "--diff-out", str(run / "delta.diff"))
        self.assertEqual(code, 0, rec["reasons"])
        code, copied = cli("copy-prior", "--report", rec["prior_report"],
                           "--expected", rec["prior_expected"],
                           "--report-sha256", rec["prior_report_sha256"],
                           "--expected-sha256", rec["prior_expected_sha256"],
                           "--out", str(run / "prior"))
        self.assertEqual(code, 0, copied)
        report, expected = write_run(run, "delta-1", head, "delta", gate.DELTA_SEATS)
        ids = {"prior_run": rec["prior_run"], "prior_head": rec["prior_head"],
               "anchor_head": rec["anchor_head"]}
        expected["delta"] = {**ids, "max_files": 5, "max_lines": 150}
        report["delta"] = {**ids, **copied, "carry_forward": None, "blast_radius": "bounded",
                           "diff": {"artifact": "delta.diff", "sha256": sha256(run / "delta.diff")}}
        return report, expected, run

    def test_clean_delta_approves_without_escalation(self):
        report, expected, run = self.build_delta()
        result = gate.evaluate(report, expected, run)
        self.assertEqual(result["verdict"], "APPROVE", result["reasons"])
        self.assertNotIn("escalate", result)

    def test_unbounded_blast_radius_escalates(self):
        report, expected, run = self.build_delta()
        report["delta"]["blast_radius"] = "unbounded"
        result = gate.evaluate(report, expected, run)
        self.assertEqual((result["verdict"], result.get("escalate")), ("INCOMPLETE", "full"))
        self.assertIn("delta blast radius is unbounded", result["reasons"])

    def test_confirmed_material_finding_escalates(self):
        report, expected, run = self.build_delta()
        report["findings"] = [{"id": "f", "severity": "major", "disposition": "confirmed",
                               "scenario": "s", "evidence": "e", "impact": "i"}]
        result = gate.evaluate(report, expected, run)
        self.assertEqual((result["verdict"], result.get("escalate")), ("CHANGES", "full"))

    def test_missing_prior_artifact_escalates(self):
        report, expected, run = self.build_delta()
        (run / "prior" / "claude.txt").unlink()
        result = gate.evaluate(report, expected, run)
        self.assertEqual((result["verdict"], result.get("escalate")), ("INCOMPLETE", "full"))

    def test_expected_without_delta_block_is_incomplete(self):
        report, expected, run = self.build_delta()
        del expected["delta"]
        self.assertIn("delta block is missing", gate.evaluate(report, expected, run)["reasons"])

    def test_delta_seat_on_codex_is_incomplete(self):
        report, expected, run = self.build_delta()
        report["seats"]["claude"]["runtime"] = "codex"
        self.assertIn("delta seat claude must run on claude",
                      gate.evaluate(report, expected, run)["reasons"])

    def test_full_report_with_a_delta_block_is_incomplete(self):
        report = json.loads(self.report_path.read_text())
        expected = json.loads(self.expected_path.read_text())
        report["delta"] = {}
        self.assertIn("delta block on a non-delta class",
                      gate.evaluate(report, expected, self.report_path.parent)["reasons"])

    def assert_escalates(self, report, expected, run, reason_part):
        result = gate.evaluate(report, expected, run)
        self.assertEqual((result["verdict"], result.get("escalate")), ("INCOMPLETE", "full"),
                         result["reasons"])
        self.assertTrue(any(reason_part in reason for reason in result["reasons"]),
                        result["reasons"])

    def test_identity_mismatch_escalates(self):
        base_report, expected, run = self.build_delta()
        for key in ("prior_run", "prior_head", "anchor_head"):
            report = copy.deepcopy(base_report)
            report["delta"][key] = "other"
            with self.subTest(key):
                self.assert_escalates(report, expected, run, f"identity mismatch: delta {key}")

    def test_prior_that_is_not_full_escalates(self):
        report, expected, run = self.build_delta()
        prior_path = run / report["delta"]["prior_report"]["artifact"]
        prior = json.loads(prior_path.read_text())
        prior["class"] = "light"
        prior_path.write_text(json.dumps(prior))
        report["delta"]["prior_report"]["sha256"] = sha256(prior_path)
        self.assert_escalates(report, expected, run, "delta prior run is not a full round")

    def test_prior_with_changes_verdict_escalates(self):
        report, expected, run = self.build_delta()
        prior_path = run / report["delta"]["prior_report"]["artifact"]
        prior = json.loads(prior_path.read_text())
        prior["findings"] = [{"id": "f", "severity": "high", "disposition": "confirmed",
                              "scenario": "s", "evidence": "e", "impact": "i"}]
        prior_path.write_text(json.dumps(prior))
        report["delta"]["prior_report"]["sha256"] = sha256(prior_path)
        self.assert_escalates(report, expected, run, "delta prior run verdict is CHANGES")

    def test_prior_from_another_pr_escalates(self):
        base_report, expected, run = self.build_delta()
        prior_path = run / base_report["delta"]["prior_expected"]["artifact"]
        original = json.loads(prior_path.read_text())
        for key, value in (("repository", "o/other"), ("pr_number", 99), ("base_ref", "dev")):
            report = copy.deepcopy(base_report)
            prior_path.write_text(json.dumps({**original, key: value}))
            report["delta"]["prior_expected"]["sha256"] = sha256(prior_path)
            with self.subTest(key):
                self.assert_escalates(report, expected, run, f"delta prior {key} differs")

    def test_ineligible_delta_diff_escalates(self):
        cases = {
            "gate path": "diff --git a/claude/skills/co-review/SKILL.md "
                         "b/claude/skills/co-review/SKILL.md\n+x\n",
            "empty": "",
        }
        base_report, expected, run = self.build_delta()
        for name, body in cases.items():
            report = copy.deepcopy(base_report)
            report["delta"]["diff"] = artifact(run, "delta.diff", body)
            with self.subTest(name):
                self.assert_escalates(report, expected, run, "delta diff")

    def test_delta_diff_over_the_caps_escalates(self):
        report, expected, run = self.build_delta()
        expected["delta"]["max_lines"] = 1
        self.assert_escalates(report, expected, run, "delta diff is not eligible")

    def test_invalid_caps_escalate(self):
        report, base_expected, run = self.build_delta()
        for caps in ({"max_files": 0}, {"max_lines": True}, {"max_files": "5"}):
            expected = copy.deepcopy(base_expected)
            expected["delta"].update(caps)
            with self.subTest(caps):
                self.assert_escalates(report, expected, run, "delta caps are invalid")

    def test_carry_forward_is_required_when_the_anchor_moved(self):
        report, expected, run = self.build_delta()
        expected["delta"]["anchor_head"] = report["delta"]["anchor_head"] = "a" * 40
        self.assert_escalates(report, expected, run, "delta carry_forward")

    def test_carry_forward_is_forbidden_at_the_prior_head(self):
        report, expected, run = self.build_delta()
        report["delta"]["carry_forward"] = artifact(run, "cf.json", "{}")
        self.assert_escalates(report, expected, run, "delta carry_forward must be null")

    def test_invalid_blast_radius_escalates(self):
        report, expected, run = self.build_delta()
        report["delta"]["blast_radius"] = "huge"
        self.assert_escalates(report, expected, run, "delta blast_radius is invalid")

    def test_audit_comment_names_the_delta_tier_and_prior(self):
        report, expected, run = self.build_delta()
        body = gate.audit_comment(report, expected, run / "report.json")
        self.assertTrue(body.startswith(
            f"<!-- co-review-audit head={report['head']} run=delta-1 tier=delta "
            f"prior_run=full-1 prior_head={self.gated} -->\n"))
        self.assertIn("- Tier: delta (2 seats)", body)

    def test_delta_after_a_delta_and_a_main_merge_recommends_full(self):
        report, expected, run = self.build_delta()
        self.report_path, self.expected_path = save(run, report, expected)
        self.merge_main()
        commit_file(self.repo, "src/app.py", "print(4)\n")
        code, rec = cli("delta-class", "--repo", str(self.repo), *self.pins(),
                        "--diff-out", str(self.root / "d.diff"))
        self.assertEqual((code, rec["recommend"]), (1, "full"))
        self.assertEqual(rec["prior_run"], "full-1")
        self.assertTrue(rec["reasons"][0].startswith(
            "anchor is not a carry-forward of the full head"), rec["reasons"])

    def test_copy_prior_refuses_a_symlinked_artifact(self):
        target = self.report_path.parent / "claude.txt"
        moved = self.root / "elsewhere.txt"
        target.rename(moved)
        target.symlink_to(moved)
        code, out = cli("copy-prior", *self.pins(), "--out", str(self.root / "copy"))
        self.assertEqual(code, 1)
        self.assertIn("not a regular file", out["error"])

    def test_copy_prior_refuses_a_prior_that_is_not_the_pinned_one(self):
        pins = self.pins()
        self.report_path.write_text(self.report_path.read_text() + "\n")
        code, out = cli("copy-prior", *pins, "--out", str(self.root / "copy"))
        self.assertEqual(code, 1)
        self.assertIn("prior report digest does not match its pin", out["error"])
        self.assertFalse((self.root / "copy").exists())

if __name__ == "__main__":
    unittest.main()
