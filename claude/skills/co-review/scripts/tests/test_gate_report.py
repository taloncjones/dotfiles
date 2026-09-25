"""Behavior tests for the structured co-review report gate."""

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
SPEC = SCRIPTS / "gate_report.py"
_spec = importlib.util.spec_from_file_location("gate_report", SPEC)
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

SHA_A = "a" * 40
SHA_B = "b" * 40
QUOTA_ATTEMPT = {"runtime": "codex", "status": "error", "result": None,
                 "errors": ["You've hit your usage limit."]}
AXES = (
    "ownership_authority",
    "dependency_boundaries",
    "contract_coherence",
    "state_effects",
    "lifecycle_operations",
    "demonstrability_constraints",
)
CHECKLIST = (
    "quoting_separators",
    "symlinks",
    "content_filters",
    "hostile_git_config",
    "signals_toctou",
    "temp_dir_lifecycle",
    "fail_open_exits",
    "ignored_untracked_overwrites",
    "fetch_ref_races",
    "replayable_file_authority",
    "resume_retry_revalidation",
    "writer_reader_parity",
    "functional_behavior",
    "snapshot_integrity",
    "preconditions_ci",
    "threat_model",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class GateReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.expected = {
            "schema_version": 1,
            "run_id": "run-1",
            "repository": "owner/repo",
            "pr_number": 7,
            "head": SHA_A,
            "base": SHA_B,
            "base_ref": "main",
            "tree": SHA_A,
            "known_blockers": ["old-1"],
            "class": "full",
        }
        self.report = self._report()

    def tearDown(self):
        self.tmp.cleanup()

    def _write(self, relative: str, body: str) -> dict:
        path = self.root / relative
        path.write_text(body, encoding="utf-8")
        return {"artifact": relative, "sha256": digest(path)}

    def _write_bytes(self, relative: str, body: bytes) -> dict:
        path = self.root / relative
        path.write_bytes(body)
        return {"artifact": relative, "sha256": digest(path)}

    def _report(self):
        seats = {}
        for name in ("claude", "codex", "breaker", "verifier"):
            seat = self._write(f"{name}.txt", f"{name} evidence\n")
            seats[name] = {
                "status": "complete",
                **seat,
                "runtime": "known",
                "model": "unknown",
                "effort": "unknown",
            }
        frozen = self._write(
            "review.diff",
            "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -0,0 +1 @@\n+reviewed\n",
        )
        ci = self._write(
            "ci.json",
            json.dumps(
                {
                    "head": SHA_A,
                    "check_runs": [
                        {
                            "name": "tests",
                            "status": "COMPLETED",
                            "conclusion": "SUCCESS",
                        }
                    ],
                    "status_contexts": [],
                }
            ),
        )
        coverage = {name: "reviewed" for name in AXES + CHECKLIST}
        return {
            "schema_version": 1,
            "run_id": "run-1",
            "repository": "owner/repo",
            "pr_number": 7,
            "head": SHA_A,
            "base": SHA_B,
            "base_ref": "main",
            "tree": SHA_A,
            "reviewed_tree": SHA_A,
            "class": "full",
            "seats": seats,
            "findings": [],
            "prior_blockers": [
                {"id": "old-1", "disposition": "repaired", "evidence": "test"}
            ],
            "coverage": {
                "architecture": {key: coverage[key] for key in AXES},
                "checklist": {key: coverage[key] for key in CHECKLIST},
            },
            "preconditions": {"head": SHA_A, "tree": SHA_A, "diff": frozen, "ci": ci},
        }

    def verdict(self):
        return gate.evaluate(self.report, self.expected, self.root)

    def _light(self, diff_text: str, runtimes=("codex", "claude")):
        self.expected["class"] = "light"
        self.report["class"] = "light"
        seats = {}
        for name, runtime in zip(("codex", "verifier"), runtimes):
            seat = self._write(f"{name}.txt", f"{name} evidence\n")
            seats[name] = {"status": "complete", **seat, "runtime": runtime,
                           "model": "unknown", "effort": "unknown"}
        self.report["seats"] = seats
        self.report["preconditions"]["diff"] = self._write("review.diff", diff_text)

    def test_light_report_over_markdown_diff_approves(self):
        self._light("diff --git a/README.md b/README.md\n+x\n")
        self.assertEqual(self.verdict()["verdict"], "APPROVE")

    def test_light_class_over_code_diff_is_incomplete(self):
        self._light("diff --git a/claude/hooks/x.py b/claude/hooks/x.py\n+x\n")
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn("class light does not match the frozen diff", result["reasons"])

    def test_light_recompute_uses_digest_bound_diff(self):
        self._light("diff --git a/README.md b/README.md\n+x\n")
        (self.root / "review.diff").write_text("diff --git a/x.py b/x.py\n", encoding="utf-8")
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_class_mismatch_and_missing_class_are_incomplete(self):
        self.expected["class"] = "light"
        self.assertIn("identity mismatch: class", self.verdict()["reasons"])
        self.expected["class"] = "full"
        del self.report["class"]
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_seat_set_must_match_class(self):
        self.report["class"] = self.expected["class"] = "light"
        self.assertIn("required seats are missing", self.verdict()["reasons"])
        self._light("diff --git a/README.md b/README.md\n+x\n")
        self.report["class"] = self.expected["class"] = "full"
        self.assertIn("required seats are missing", self.verdict()["reasons"])

    def test_light_seats_need_one_claude_and_one_codex_runtime(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("codex", "unknown"))
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_light_seat_runtime_must_be_a_string(self):
        for bad in ([], {}):
            self._light("diff --git a/README.md b/README.md\n+x\n")
            self.report["seats"]["verifier"]["runtime"] = bad
            self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_light_codex_substitute_after_quota_failure_approves(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "APPROVE")
        self.assertIn(
            f"seat codex ran on claude after a failed codex attempt (quota): "
            f"codex.codex-attempt.json sha256={attempt['sha256']}",
            result["reasons"],
        )

    def test_light_codex_substitute_accepts_unparseable_auth_failure(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        payload = {
            "runtime": "codex", "status": "unparseable", "result": None,
            "errors": ["no completed Codex turn", "Not logged in"],
        }
        attempt = self._write("codex.codex-attempt.json", json.dumps(payload))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "auth", "attempt": attempt}
        self.assertEqual(self.verdict()["verdict"], "APPROVE")

    def test_light_codex_substitute_accepts_unavailable_reason(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "unavailable", "attempt": attempt}
        self.assertEqual(self.verdict()["verdict"], "APPROVE")

    def test_light_without_any_codex_attempt_stays_incomplete(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn("light seats must be one claude and one codex runtime", result["reasons"])
        self.assertIn("seat codex ran on claude without a codex_substitute", result["reasons"])

    def test_light_codex_seat_on_claude_needs_a_substitute(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "codex"))
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn("seat codex ran on claude without a codex_substitute", result["reasons"])

    def test_light_substitute_with_a_codex_verifier_stays_incomplete(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "codex"))
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn("light seats must be one claude and one codex runtime", result["reasons"])

    def test_codex_substitute_rejects_attempts_that_are_not_access_failures(self):
        for status in ("timeout", "interrupted", "success"):
            with self.subTest(status=status):
                self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
                payload = {**QUOTA_ATTEMPT, "status": status}
                attempt = self._write("codex.codex-attempt.json", json.dumps(payload))
                self.report["seats"]["codex"]["codex_substitute"] = {
                    "reason": "quota", "attempt": attempt
                }
                result = self.verdict()
                self.assertEqual(result["verdict"], "INCOMPLETE")
                self.assertIn(
                    "seat codex codex_substitute is invalid: "
                    "attempt status is not error or unparseable",
                    result["reasons"],
                )
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        payload = {**QUOTA_ATTEMPT, "result": "a full review"}
        attempt = self._write("codex.codex-attempt.json", json.dumps(payload))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat codex codex_substitute is invalid: attempt produced a review result",
            result["reasons"],
        )

    def test_codex_substitute_rejects_non_codex_or_errorless_attempts(self):
        no_runtime = {k: v for k, v in QUOTA_ATTEMPT.items() if k != "runtime"}
        cases = (
            ({**QUOTA_ATTEMPT, "runtime": "claude"}, "attempt runtime is not codex"),
            (no_runtime, "attempt runtime is not codex"),
            ({"status": "error", "error": "x"}, "attempt runtime is not codex"),
            ({**QUOTA_ATTEMPT, "errors": []}, "attempt errors are empty"),
            ({**QUOTA_ATTEMPT, "errors": ["   "]}, "attempt errors are empty"),
            ({**QUOTA_ATTEMPT, "errors": [5, None]}, "attempt errors are empty"),
            ({**QUOTA_ATTEMPT, "errors": "text"}, "attempt errors are empty"),
        )
        for payload, cause in cases:
            with self.subTest(payload=payload):
                self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
                attempt = self._write("codex.codex-attempt.json", json.dumps(payload))
                self.report["seats"]["codex"]["codex_substitute"] = {
                    "reason": "quota", "attempt": attempt
                }
                result = self.verdict()
                self.assertEqual(result["verdict"], "INCOMPLETE")
                self.assertIn(
                    f"seat codex codex_substitute is invalid: {cause}", result["reasons"]
                )
        for body in ("[]", "usage limit"):
            with self.subTest(body=body):
                self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
                attempt = self._write("codex.codex-attempt.json", body)
                self.report["seats"]["codex"]["codex_substitute"] = {
                    "reason": "quota", "attempt": attempt
                }
                result = self.verdict()
                self.assertEqual(result["verdict"], "INCOMPLETE")
                self.assertIn(
                    "seat codex codex_substitute is invalid: attempt is not a JSON object",
                    result["reasons"],
                )
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        attempt = self._write_bytes("codex.codex-attempt.json", b"\xff\xfe{}")
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat codex codex_substitute is invalid: attempt is not a JSON object",
            result["reasons"],
        )

    def test_codex_substitute_rejects_bad_binding(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        attempt = {**attempt, "sha256": "0" * 64}
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat codex codex_substitute is invalid: attempt artifact digest does not match",
            result["reasons"],
        )

        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        missing = {"artifact": "missing.json", "sha256": "0" * 64}
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": missing}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat codex codex_substitute is invalid: attempt artifact cannot be read",
            result["reasons"],
        )

        original_root = self.root
        run = original_root / "run"
        run.mkdir()
        self.root = run
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        outside_path = original_root / "outside.json"
        outside_path.write_text(json.dumps(QUOTA_ATTEMPT), encoding="utf-8")
        escape = {"artifact": "../outside.json", "sha256": digest(outside_path)}
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": escape}
        result = self.verdict()
        self.root = original_root
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat codex codex_substitute is invalid: attempt artifact cannot be read",
            result["reasons"],
        )

    def test_codex_substitute_rejects_bad_record_shape(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "other", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat codex codex_substitute is invalid: reason is not quota, auth or unavailable",
            result["reasons"],
        )

        bad_records = ({"attempt": attempt}, {"reason": "quota", "note": "x"}, "quota")
        for record in bad_records:
            with self.subTest(record=record):
                self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
                fresh_attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
                value = {**record, "attempt": fresh_attempt} if isinstance(record, dict) else record
                self.report["seats"]["codex"]["codex_substitute"] = value
                result = self.verdict()
                self.assertEqual(result["verdict"], "INCOMPLETE")
                self.assertIn(
                    "seat codex codex_substitute is invalid: "
                    "record keys must be reason and attempt",
                    result["reasons"],
                )

        bad_attempts = (
            {"artifact": "codex.codex-attempt.json"},
            {"artifact": "", "sha256": "0" * 64},
        )
        for attempt_fields in bad_attempts:
            with self.subTest(attempt_fields=attempt_fields):
                self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
                self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
                self.report["seats"]["codex"]["codex_substitute"] = {
                    "reason": "quota", "attempt": attempt_fields
                }
                result = self.verdict()
                self.assertEqual(result["verdict"], "INCOMPLETE")
                self.assertIn(
                    "seat codex codex_substitute is invalid: "
                    "attempt keys must be artifact and sha256",
                    result["reasons"],
                )

    def test_codex_substitute_needs_a_claude_seat_runtime(self):
        for runtime in ("codex", "unknown"):
            with self.subTest(runtime=runtime):
                self._light(
                    "diff --git a/README.md b/README.md\n+x\n", runtimes=(runtime, "claude")
                )
                attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
                self.report["seats"]["codex"]["codex_substitute"] = {
                    "reason": "quota", "attempt": attempt
                }
                result = self.verdict()
                self.assertEqual(result["verdict"], "INCOMPLETE")
                self.assertIn(
                    "seat codex codex_substitute is invalid: seat runtime is not claude",
                    result["reasons"],
                )

    def test_codex_substitute_only_on_codex_routed_seats(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("codex", "claude"))
        attempt = self._write("verifier.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["verifier"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn("seat verifier cannot take a codex_substitute", result["reasons"])

        for name in ("claude", "verifier"):
            with self.subTest(name=name):
                self.report = self._report()
                attempt = self._write(f"{name}.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
                self.report["seats"][name]["codex_substitute"] = {
                    "reason": "quota", "attempt": attempt
                }
                result = self.verdict()
                self.assertEqual(result["verdict"], "INCOMPLETE")
                self.assertIn(f"seat {name} cannot take a codex_substitute", result["reasons"])

    def test_full_tier_applies_the_same_codex_substitute_rule(self):
        self.report = self._report()
        self.report["seats"]["breaker"]["runtime"] = "claude"
        attempt = self._write("breaker.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["breaker"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "APPROVE")
        self.assertIn(
            f"seat breaker ran on claude after a failed codex attempt (quota): "
            f"breaker.codex-attempt.json sha256={attempt['sha256']}",
            result["reasons"],
        )

        self.report = self._report()
        self.report["seats"]["codex"]["runtime"] = "claude"
        timeout_attempt = self._write(
            "codex.codex-attempt.json", json.dumps({**QUOTA_ATTEMPT, "status": "timeout"})
        )
        self.report["seats"]["codex"]["codex_substitute"] = {
            "reason": "quota", "attempt": timeout_attempt
        }
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat codex codex_substitute is invalid: attempt status is not error or unparseable",
            result["reasons"],
        )

    def test_full_tier_codex_seat_on_claude_needs_a_substitute(self):
        self.report = self._report()
        self.report["seats"]["codex"]["runtime"] = "claude"
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn("seat codex ran on claude without a codex_substitute", result["reasons"])

    def test_full_tier_rejects_a_shared_codex_attempt(self):
        self.report = self._report()
        self.report["seats"]["codex"]["runtime"] = "claude"
        self.report["seats"]["breaker"]["runtime"] = "claude"
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        self.report["seats"]["breaker"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat breaker codex_substitute is invalid: attempt is shared with seat codex",
            result["reasons"],
        )

        self.report = self._report()
        self.report["seats"]["codex"]["runtime"] = "claude"
        self.report["seats"]["breaker"]["runtime"] = "claude"
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        alias = {"artifact": "./codex.codex-attempt.json", "sha256": attempt["sha256"]}
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        self.report["seats"]["breaker"]["codex_substitute"] = {"reason": "quota", "attempt": alias}
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat breaker codex_substitute is invalid: attempt is shared with seat codex",
            result["reasons"],
        )

        self.report = self._report()
        self.report["seats"]["codex"]["runtime"] = "claude"
        self.report["seats"]["breaker"]["runtime"] = "claude"
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        symlink_path = self.root / "breaker.codex-attempt.json"
        symlink_path.symlink_to(self.root / "codex.codex-attempt.json")
        symlink_attempt = {"artifact": "breaker.codex-attempt.json", "sha256": attempt["sha256"]}
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        self.report["seats"]["breaker"]["codex_substitute"] = {
            "reason": "quota", "attempt": symlink_attempt
        }
        result = self.verdict()
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn(
            "seat breaker codex_substitute is invalid: attempt is shared with seat codex",
            result["reasons"],
        )

        self.report = self._report()
        self.report["seats"]["codex"]["runtime"] = "claude"
        self.report["seats"]["breaker"]["runtime"] = "claude"
        attempt_codex = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        attempt_breaker = self._write("breaker-2.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["codex"]["codex_substitute"] = {
            "reason": "quota", "attempt": attempt_codex
        }
        self.report["seats"]["breaker"]["codex_substitute"] = {
            "reason": "quota", "attempt": attempt_breaker
        }
        result = self.verdict()
        self.assertEqual(result["verdict"], "APPROVE")

    def test_changes_verdict_keeps_the_substitute_note(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        self.report["findings"] = [{
            "id": "f1", "severity": "high", "disposition": "confirmed",
            "scenario": "s", "evidence": "e", "impact": "i",
        }]
        result = self.verdict()
        self.assertEqual(result["verdict"], "CHANGES")
        self.assertIn(
            f"seat codex ran on claude after a failed codex attempt (quota): "
            f"codex.codex-attempt.json sha256={attempt['sha256']}",
            result["reasons"],
        )

    def test_audit_comment_names_a_substitute_without_evidence_text(self):
        self._light("diff --git a/README.md b/README.md\n+x\n", runtimes=("claude", "claude"))
        attempt = self._write("codex.codex-attempt.json", json.dumps(QUOTA_ATTEMPT))
        self.report["seats"]["codex"]["codex_substitute"] = {"reason": "quota", "attempt": attempt}
        result = self._cli_audit(self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = result.stdout
        tier_index = body.index("- Tier:")
        substitute_index = body.index(
            "- Substitute: codex seat ran on claude after a codex quota failure"
        )
        ci_index = body.index("- CI:")
        self.assertGreater(substitute_index, tier_index)
        self.assertLess(substitute_index, ci_index)
        self.assertNotIn("codex.codex-attempt.json", body)
        self.assertNotIn("usage limit", body)

    def test_full_report_over_markdown_diff_approves(self):
        self.report["preconditions"]["diff"] = self._write(
            "review.diff", "diff --git a/README.md b/README.md\n+x\n")
        self.assertEqual(self.verdict()["verdict"], "APPROVE")

    def test_schema_documents_class_and_seat_sets(self):
        shape = gate.schema()
        self.assertEqual(shape["light_seats"], ["codex", "verifier"])
        self.assertEqual(shape["full_seats"], ["claude", "codex", "breaker", "verifier"])
        self.assertEqual(shape["report_example"]["class"], "full")
        self.assertEqual(shape["expected_example"]["class"], "full")
        self.assertNotIn("required_seats", shape)
        self.assertEqual(
            shape["codex_substitute"]["seats"],
            {"light": ["codex"], "full": ["codex", "breaker"]},
        )
        self.assertEqual(
            shape["codex_substitute"]["reasons"], ["quota", "auth", "unavailable"]
        )

    def test_valid_report_approves(self):
        result = self.verdict()
        self.assertEqual(result["verdict"], "APPROVE")
        self.assertTrue(result["approve_allowed"])

    def test_missing_failed_or_empty_seat_is_incomplete(self):
        for mutation in (
            lambda: self.report["seats"].pop("codex"),
            lambda: self.report["seats"]["codex"].update(status="failed"),
            lambda: (self.root / "codex.txt").write_text("  \n", encoding="utf-8"),
        ):
            with self.subTest(mutation=mutation):
                baseline = self._report()
                self.report = baseline
                mutation()
                self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_bad_seat_digest_and_schema_fail_closed(self):
        self.report["seats"]["claude"]["sha256"] = "0" * 64
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self.report = self._report()
        self.report["schema_version"] = 2
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_every_identity_mismatch_is_incomplete(self):
        for key, changed in {
            "run_id": "other",
            "repository": "other/repo",
            "pr_number": 8,
            "head": SHA_B,
            "base": SHA_A,
            "base_ref": "release",
            "tree": SHA_B,
        }.items():
            with self.subTest(key=key):
                self.report = self._report()
                self.report[key] = changed
                self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_precondition_identity_and_pr_number_must_be_ready_for_a_pr(self):
        self.report["preconditions"]["head"] = SHA_B
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self.report = self._report()
        self.report["pr_number"] = 0
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_dirty_tree_missing_coverage_and_unknown_severity_are_incomplete(self):
        self.report["reviewed_tree"] = SHA_B
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self.report = self._report()
        self.report["coverage"]["architecture"].pop(AXES[0])
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        self.report = self._report()
        self.report["findings"] = [
            {
                "id": "f",
                "severity": "bad",
                "disposition": "refuted",
                "scenario": "x",
                "evidence": "y",
            }
        ]
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_material_findings_require_impact_evidence_shape(self):
        finding = {
            "id": "f",
            "severity": "major",
            "disposition": "confirmed",
            "scenario": "x",
            "evidence": "y",
        }
        self.report["findings"] = [finding]
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        finding["impact"] = "Users can bypass the required check."
        self.assertEqual(self.verdict()["verdict"], "CHANGES")
        finding.update(disposition="unresolved")
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        for impact in ("", "  "):
            with self.subTest(impact=repr(impact)):
                finding["impact"] = impact
                self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")
        finding.pop("impact")
        finding.update(severity="advisory", disposition="confirmed")
        self.assertEqual(self.verdict()["verdict"], "APPROVE")

    def test_prior_blocker_omission_and_material_gap_are_incomplete(self):
        self.report["prior_blockers"] = []
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_extra_still_open_prior_blocker_cannot_be_ignored(self):
        self.expected["known_blockers"] = []
        self.report["prior_blockers"] = [
            {
                "id": "extra",
                "disposition": "still-open",
                "evidence": "unrepaired required contract",
            }
        ]
        self.assertEqual(self.verdict()["verdict"], "CHANGES")
        self.report = self._report()
        self.report["coverage"]["checklist"][CHECKLIST[0]] = {
            "gap": {"material": True, "reason": "missing"},
            "accepted_by": "owner",
        }
        self.assertEqual(self.verdict()["verdict"], "INCOMPLETE")

    def test_named_nonmaterial_gap_remains_visible_without_blocking(self):
        self.report["coverage"]["checklist"][CHECKLIST[0]] = {
            "gap": {"material": False, "reason": "not applicable"},
            "accepted_by": "owner",
        }
        result = self.verdict()
        self.assertEqual(result["verdict"], "APPROVE")
        self.assertIn("accepted nonmaterial gap", result["reasons"][0])

    def test_cli_uses_report_relative_artifacts_and_expected_identity(self):
        report_path = self.root / "report.json"
        expected_path = self.root / "expected.json"
        report_path.write_text(json.dumps(self.report), encoding="utf-8")
        expected_path.write_text(json.dumps(self.expected), encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SPEC),
                "evaluate",
                "--report",
                str(report_path),
                "--expected",
                str(expected_path),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        (self.root / "claude.txt").write_text("changed\n", encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SPEC),
                "evaluate",
                "--report",
                str(report_path),
                "--expected",
                str(expected_path),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.expected["run_id"] = "stale"
        expected_path.write_text(json.dumps(self.expected), encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable,
                str(SPEC),
                "evaluate",
                "--report",
                str(report_path),
                "--expected",
                str(expected_path),
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)

    def _cli_audit(self, home: Path):
        report_path = self.root / "report.json"
        expected_path = self.root / "expected.json"
        report_path.write_text(json.dumps(self.report), encoding="utf-8")
        expected_path.write_text(json.dumps(self.expected), encoding="utf-8")
        return subprocess.run(
            [sys.executable, str(SPEC), "audit-comment",
             "--report", str(report_path), "--expected", str(expected_path)],
            capture_output=True, text=True, check=False,
            env={**os.environ, "HOME": str(home)},
        )

    def test_audit_comment_renders_every_field_once(self):
        result = self._cli_audit(self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        body = result.stdout
        self.assertEqual(body.count(f"<!-- co-review-audit head={SHA_A} run=run-1 -->"), 1)
        self.assertTrue(body.startswith("<!-- co-review-audit"))
        for text in ("Co-review gate: APPROVE", "- Run: run-1", f"- Head: {SHA_A}",
                     "- Tier: full (4 seats)", "- CI: 1/1 checks passed",
                     "- Report: ~/report.json"):
            self.assertIn(text, body)
        self.assertNotIn("Substitute", body)

    def test_audit_comment_refuses_non_approval(self):
        self.report["findings"] = [{"id": "f1", "severity": "high", "disposition": "confirmed",
                                    "scenario": "s", "evidence": "e", "impact": "i"}]
        changes = self._cli_audit(self.root)
        self.assertEqual((changes.returncode, changes.stdout), (1, ""))
        self.report["findings"] = []
        self.report["run_id"] = "other"
        incomplete = self._cli_audit(self.root)
        self.assertEqual((incomplete.returncode, incomplete.stdout), (1, ""))

    def test_policy_requires_exact_one_anchor_pair(self):
        with self.assertRaises(ValueError):
            gate.extract_policy("no anchors", "POLICY")
        with self.assertRaises(ValueError):
            gate.extract_policy(
                "<!-- gate-policy:start -->\na\n<!-- gate-policy:end -->\n<!-- gate-policy:start -->\nb\n<!-- gate-policy:end -->",
                "POLICY",
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
