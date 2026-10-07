"""Drift checks: gate SKILL text stays in step with the gate scripts."""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[5]
CO_REVIEW = (REPO / "claude/skills/co-review/SKILL.md").read_text(encoding="utf-8")
MIRROR = (REPO / "codex/skills/co-review/SKILL.md").read_text(encoding="utf-8")
SHIP = (REPO / "claude/skills/ship/SKILL.md").read_text(encoding="utf-8")
SPEC_REVIEW = (REPO / "claude/skills/codex-spec-review/SKILL.md").read_text(encoding="utf-8")
PLAN_REVIEW = (REPO / "claude/skills/codex-plan-review/SKILL.md").read_text(encoding="utf-8")
POLICY_FILE = (REPO / "claude/skills/co-review/gate-policy.md").read_text(encoding="utf-8")
HERDR = (REPO / "claude/skills/herdr-orchestration/SKILL.md").read_text(encoding="utf-8")
BRIEF = (REPO / "claude/skills/herdr-orchestration/references/brief-template.md").read_text(encoding="utf-8")
PR_READY = (REPO / "claude/commands/pr-ready.md").read_text(encoding="utf-8")


def _extract_block(text, contains_needle):
    """Return the fenced bash block that contains contains_needle."""
    anchor = text.index(contains_needle)
    block_start = text.rindex("```bash", 0, anchor)
    block_end = text.index("```", block_start + len("```bash"))
    return text[block_start:block_end]


def _assert_launches_all_precede_one_trailing_wait(testcase, block):
    """Every `&` seat launch in the block precedes a single trailing `wait`."""
    lines = [line.strip() for line in block.splitlines()]
    launch_positions = [i for i, line in enumerate(lines) if line.endswith("&")]
    wait_positions = [i for i, line in enumerate(lines) if line == "wait"]
    testcase.assertTrue(launch_positions, "block has no seat launches")
    testcase.assertEqual(len(wait_positions), 1, "block must wait exactly once")
    testcase.assertGreater(wait_positions[0], max(launch_positions),
                            "wait must follow every launch, not sit between them")


class CoReviewSkillText(unittest.TestCase):
    def test_both_entrypoints_pin_the_frozen_diff_and_class(self):
        for text in (CO_REVIEW, MIRROR):
            for needle in ("-c core.quotePath=true diff --no-color --no-ext-diff --no-textconv --no-renames --binary",
                           'frozen.diff" || exit 2',
                           "classify --diff", "--full", "CLASS"):
                self.assertIn(needle, text)

    def test_both_entrypoints_name_the_light_seats(self):
        for text in (CO_REVIEW, MIRROR):
            self.assertIn("light tier runs `codex` and `verifier`", text)
            self.assertIn("finder", text)
            self.assertNotIn("first three", text)

    def test_both_entrypoints_state_the_usage_limit_rule(self):
        for text in (CO_REVIEW, MIRROR):
            self.assertIn("usage-limit refusal", text)
            self.assertIn("not retried", text)
        self.assertIn("<seat>.native.md", MIRROR)

    def test_co_review_gates_the_finder_dispatch_on_class(self):
        for needle in ('if [ "$CLASS" = "full" ] || [ "$CLASS" = "delta" ]; then',
                       "Light tier: only the codex reviewer seat. Full tier: also claude and breaker."):
            self.assertIn(needle, CO_REVIEW)
        self.assertNotIn("Repeat once for claude, codex, and breaker", CO_REVIEW)

    def test_mirror_launches_light_verifier_through_claude_runner(self):
        self.assertIn("--runtime claude --role skeptic", MIRROR)

    def test_mirror_branches_every_seat_step(self):
        for needle in ("Full tier only:",
                       "Light tier: dispatch only the `codex` reviewer",
                       "Light tier: wait for the `codex` seat only",
                       "Light tier: only after the `codex` artifact",
                       "the actual runtime artifacts for `CLASS`"):
            self.assertIn(needle, MIRROR)
        self.assertNotIn("actual four runtime artifacts", MIRROR)

    def test_policy_describes_both_tiers(self):
        policy = subprocess.run(
            [sys.executable, str(REPO / "claude/skills/co-review/scripts/gate_report.py"),
             "policy", "--section", "POLICY"],
            capture_output=True, text=True, check=True,
        ).stdout
        for needle in ("light tier", "full tier", "`codex` and `verifier`", "change_class.py",
                       "codex_substitute", "quota, auth or availability",
                       "`breaker` in the full tier"):
            self.assertIn(needle, policy)
        self.assertNotIn("All four seats", policy)
        self.assertNotIn("first three", policy)
        self.assertNotIn("first-three", policy)

    def test_co_review_documents_the_codex_substitute_procedure(self):
        for needle in ("codex_substitute", ".codex-attempt.json", "substitute-probe-",
                       "SUBSTITUTE", "not the fallback for a Codex outage",
                       "A failed probe never switches runtime on its own"):
            self.assertIn(needle, CO_REVIEW)
        probe_needle = '"$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-codex-reviewer.json"'
        substitute_needle = '>"$RUN_DIR/substitute-probe-'
        seat_needle = '--prompt-file "$RUN_DIR/codex.prompt"'
        self.assertGreater(CO_REVIEW.index(substitute_needle), CO_REVIEW.index(probe_needle))
        self.assertLess(CO_REVIEW.index(substitute_needle), CO_REVIEW.index(seat_needle))
        block = _extract_block(CO_REVIEW, substitute_needle)
        status_index = block.index('"status") == "success"')
        mv_index = block.index("mv --")
        runner_index = block.index('"$RUNNER" run')
        self.assertLess(status_index, mv_index)
        self.assertLess(mv_index, runner_index)
        self.assertIn('--cwd "$CLAUDE_ROOT"', block)

    def test_co_review_substitute_block_runs_under_bash_and_zsh(self):
        import json as jsonlib
        import shutil
        import subprocess as sp
        import sys as syslib
        import tempfile

        body = _extract_block(CO_REVIEW, '>"$RUN_DIR/substitute-probe-').split("\n", 1)[1]
        stub_runner = Path(tempfile.mkstemp(suffix=".py")[1])
        stub_runner.write_text(
            "import json, sys\nprint(json.dumps({'status': 'success'}))\n", encoding="utf-8"
        )
        script = (
            "uv() { shift 3; \"$PYTHON\" \"$@\"; }\n"
            f'PYTHON="{syslib.executable}"\n'
            f'RUNNER="{stub_runner}"\n'
            + body
        )

        def run_case(shell, run_dir, substitute, reviewer_status, skeptic_status):
            (run_dir / "probe-codex-reviewer.json").write_text(
                jsonlib.dumps({"status": reviewer_status, "runtime": "codex",
                               "errors": ["fail"]}), encoding="utf-8"
            )
            (run_dir / "probe-codex-skeptic.json").write_text(
                jsonlib.dumps({"status": skeptic_status, "runtime": "codex",
                               "errors": ["fail"]}), encoding="utf-8"
            )
            (run_dir / "probe-claude-reviewer.json").write_text(
                jsonlib.dumps({"status": "success"}), encoding="utf-8"
            )
            (run_dir / "probe-claude-skeptic.json").write_text(
                jsonlib.dumps({"status": "success"}), encoding="utf-8"
            )
            env = {**__import__("os").environ, "RUN_DIR": str(run_dir),
                   "SUBSTITUTE": substitute, "CLAUDE_ROOT": str(run_dir)}
            return sp.run([shell, "-c", script], capture_output=True, text=True, env=env)

        for shell in ("bash", "zsh"):
            if shell == "zsh" and not shutil.which("zsh"):
                self.skipTest("zsh not found")
            with self.subTest(shell=shell):
                with tempfile.TemporaryDirectory() as tmp:
                    run_dir = Path(tmp)
                    result = run_case(shell, run_dir, "codex breaker", "error", "error")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        (run_dir / "codex.codex-attempt.json").read_text(encoding="utf-8"),
                        jsonlib.dumps({"status": "error", "runtime": "codex", "errors": ["fail"]}),
                    )
                    self.assertEqual(
                        (run_dir / "breaker.codex-attempt.json").read_text(encoding="utf-8"),
                        jsonlib.dumps({"status": "error", "runtime": "codex", "errors": ["fail"]}),
                    )
                    self.assertTrue((run_dir / "substitute-probe-codex.json").exists())
                    self.assertTrue((run_dir / "substitute-probe-breaker.json").exists())
                    self.assertFalse(list(run_dir.glob("probe-codex-*.json")))

                with tempfile.TemporaryDirectory() as tmp:
                    run_dir = Path(tmp)
                    result = run_case(shell, run_dir, "codex", "success", "error")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue((run_dir / "probe-codex-reviewer.json").exists())
                    self.assertFalse((run_dir / "codex.codex-attempt.json").exists())

                with tempfile.TemporaryDirectory() as tmp:
                    run_dir = Path(tmp)
                    result = run_case(shell, run_dir, "codex breaker", "error", "success")
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue((run_dir / "probe-codex-reviewer.json").exists())
                    self.assertTrue((run_dir / "probe-codex-skeptic.json").exists())
                    self.assertFalse(list(run_dir.glob("*.codex-attempt.json")))
                    self.assertFalse(list(run_dir.glob("substitute-probe-*")))

    def test_co_review_probes_every_runner_route_before_seats(self):
        probe = CO_REVIEW.index('"$RUN_DIR/probe-')
        first_seat = CO_REVIEW.index('--prompt-file "$RUN_DIR/codex.prompt"')
        self.assertLess(probe, first_seat)
        for needle in ("--timeout-secs 60", '"$RUN_DIR"/probe-*.json',
                       "probe-claude-reviewer.json", "probe-codex-reviewer.json",
                       "probe-codex-skeptic.json", "probe-claude-skeptic.json",
                       'status") != "success"', "json.load(handle)",
                       "Reply ok"):
            self.assertIn(needle, CO_REVIEW)

    def test_co_review_seats_run_in_background_at_1200_seconds(self):
        self.assertEqual(CO_REVIEW.count("--timeout-secs 1200"), 4)
        self.assertNotIn("--timeout-secs 600", CO_REVIEW)
        for needle in ("run_in_background", "git apply --index", "wait"):
            self.assertIn(needle, CO_REVIEW)

    def test_co_review_probe_seats_launch_together_before_one_wait(self):
        block = _extract_block(CO_REVIEW, '"$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-codex-reviewer.json"')
        _assert_launches_all_precede_one_trailing_wait(self, block)

    def test_co_review_finder_seats_launch_together_before_one_wait(self):
        block = _extract_block(CO_REVIEW, '"$RUN_DIR/codex.prompt" >"$RUN_DIR/codex.runtime.json"')
        _assert_launches_all_precede_one_trailing_wait(self, block)

    def test_mirror_probe_seats_launch_together_before_one_wait(self):
        block = _extract_block(MIRROR, '"$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-claude-skeptic.json"')
        _assert_launches_all_precede_one_trailing_wait(self, block)

    def test_mirror_probes_claude_routes_and_launches_nohup_seats(self):
        probe = MIRROR.index('"$RUN_DIR/probe-claude-')
        self.assertLess(probe, MIRROR.index('--prompt-file "$RUN_DIR/verifier.prompt"'))
        self.assertLess(probe, MIRROR.index('--prompt-file "$RUN_DIR/claude.prompt"'))
        for needle in ("probe-claude-reviewer.json", "probe-claude-skeptic.json",
                       "--timeout-secs 60", "nohup uv run", '.pid"',
                       "kill -0", "1200-second deadline"):
            self.assertIn(needle, MIRROR)
        self.assertEqual(MIRROR.count("--timeout-secs 1200"), 2)
        self.assertNotIn("--timeout-secs 600", MIRROR)
        self.assertNotIn("600-second", MIRROR)

    def test_both_entrypoints_document_carry_forward(self):
        for text in (CO_REVIEW, MIRROR):
            for needle in ("## Carry-forward", '"$GATE_REPORT" carry-forward --repo "$REPO"',
                           '--report-sha256 "$PRIOR_REPORT_SHA256"',
                           "tier=carry-forward prior_run=<prior_run> prior_sha=<prior_head>",
                           "for dedupe only, never authority",
                           "`tier` = expected `class`"):
                self.assertIn(needle, text)

    def test_policy_names_the_carry_forward_exception(self):
        policy = subprocess.run(
            [sys.executable, str(REPO / "claude/skills/co-review/scripts/gate_report.py"),
             "policy", "--section", "POLICY"],
            capture_output=True, text=True, check=True,
        ).stdout
        for needle in ("### Carry-forward", "the one named exception", "digest-pinned",
                       "never the `gated..HEAD` range"):
            self.assertIn(needle, policy)

    def test_both_entrypoints_document_the_delta_tier(self):
        for text in (CO_REVIEW, MIRROR):
            for needle in ("## Delta tier", '"$GATE_REPORT" delta-class --repo "$REPO"',
                           '"$GATE_REPORT" copy-prior', '--diff-out "$RUN_DIR/delta.diff"',
                           "blast_radius: unbounded", "one fresh full gate",
                           "Delta round (Recommended)", "herdr-ship-delta-head:",
                           "`prior_sha` = expected `delta.prior_head`"):
                self.assertIn(needle, text)

    def test_delta_evidence_is_written_in_data_flow_order(self):
        for text in (CO_REVIEW, MIRROR):
            order = [text.index(needle) for needle in (
                '--diff-out "$RUN_DIR/delta.diff"', '--out "$RUN_DIR/prior"',
                '(run / "carry-forward.json")',
                "into the expected identity before any seat runs")]
            self.assertEqual(order, sorted(order))

    def test_co_review_branches_probes_and_seats_on_delta(self):
        for needle in ('if [ "$CLASS" = "full" ] || [ "$CLASS" = "light" ]; then', 'if [ "$CLASS" = "full" ]; then',
                       '[ "$CLASS" = "delta" ] && SEATS="claude verifier"',
                       "Delta tier: only the claude reviewer seat.",
                       "The delta tier runs `claude` and `verifier`"):
            self.assertIn(needle, CO_REVIEW)
        self.assertIn("Delta tier: the `claude` reviewer seat and the verifier", MIRROR)

    def test_policy_describes_the_delta_tier(self):
        policy = subprocess.run(
            [sys.executable, str(REPO / "claude/skills/co-review/scripts/gate_report.py"),
             "policy", "--section", "POLICY"],
            capture_output=True, text=True, check=True,
        ).stdout
        for needle in ("### Delta tier", "The delta tier runs `claude` and `verifier`",
                       'escalate: "full"', "cumulative from the full head"):
            self.assertIn(needle, policy)

    def test_co_review_captures_ci_before_probes(self):
        block = _extract_block(CO_REVIEW, '"$GATE_REPORT" ci-envelope')
        for needle in ('gh pr checks "$PR" --watch --interval 30', "|| true",
                       'gh pr view "$PR" --json headRefOid,statusCheckRollup >"$RUN_DIR/pr-ci.json"',
                       '--head "$HEAD" --out "$RUN_DIR/ci.json" >"$RUN_DIR/ci-envelope.json"'):
            self.assertIn(needle, block)
        self.assertLess(CO_REVIEW.index('"$GATE_REPORT" ci-envelope'),
                        CO_REVIEW.index('"$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-codex-reviewer.json"'))
        flat = " ".join(CO_REVIEW.split())
        self.assertIn('exactly `["CI evidence is missing"]`', flat)
        self.assertIn("stops co-review `INCOMPLETE` before any probe", flat)

    def test_co_review_prompt_loop_names_ci_json_under_bash_and_zsh(self):
        import json as jsonlib
        import os
        import shutil
        import tempfile

        body = _extract_block(CO_REVIEW, "ci.json: %s sha256=%s").split("\n", 1)[1]
        script = 'uv() { shift 3; "$PYTHON" "$@"; }\n' + f'PYTHON="{sys.executable}"\n' + body
        digest = "f" * 64
        for shell in ("bash", "zsh"):
            if not shutil.which(shell):
                self.skipTest(f"{shell} not found")
            for cls, prompts, with_ci in (("light", ["codex.prompt", "verifier.prompt"], True),
                                          ("lessons", ["verifier.prompt"], True),
                                          ("light", ["codex.prompt", "verifier.prompt"], False)):
                with self.subTest(shell=shell, cls=cls, with_ci=with_ci), \
                        tempfile.TemporaryDirectory() as tmp:
                    run_dir = Path(tmp)
                    ci = jsonlib.dumps({"head": "a" * 40, "check_runs": [], "status_contexts": []})
                    if with_ci:
                        (run_dir / "ci.json").write_text(ci + "\n", encoding="utf-8")
                        (run_dir / "ci-envelope.json").write_text(
                            jsonlib.dumps({"sha256": digest}), encoding="utf-8")
                    env = {**os.environ, "RUN_DIR": str(run_dir), "CLASS": cls,
                           "REVIEW_ROOT": str(REPO)}
                    result = subprocess.run([shell, "-c", script], capture_output=True,
                                            text=True, env=env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(sorted(p.name for p in run_dir.glob("*.prompt")), prompts)
                    for name in prompts:
                        text = (run_dir / name).read_text(encoding="utf-8")
                        if with_ci:
                            self.assertIn(f"ci.json: {run_dir}/ci.json sha256={digest}", text)
                            self.assertIn(ci, text)
                        else:
                            self.assertIn("None: a local no-PR review captures no CI.", text)
                        self.assertIn("## Classes", text)
                        self.assertEqual("## Lessons fact-check" in text, cls == "lessons")
                    if cls == "lessons":
                        text = (run_dir / "verifier.prompt").read_text(encoding="utf-8")
                        self.assertIn("technical claim", text)
                        self.assertIn("admission filter", text)

    def test_co_review_lessons_tier_dispatch(self):
        for needle in ('[ "$CLASS" = "lessons" ] && SEATS="verifier"',
                       '"$GATE_REPORT" lessons-check',
                       '--file "$CODEX_ROOT/claude/rules/personal/agent-lessons.md"',
                       'if [ "$CLASS" = "full" ] || [ "$CLASS" = "light" ]; then',
                       'if [ "$CLASS" = "full" ] || [ "$CLASS" = "delta" ]; then',
                       "The lessons tier runs only `verifier`",
                       "falls back to `CLASS=light`"):
            self.assertIn(needle, CO_REVIEW)
        self.assertNotIn('if [ "$CLASS" != "delta" ]; then', CO_REVIEW)
        self.assertNotIn('if [ "$CLASS" != "light" ]; then', CO_REVIEW)
        self.assertLess(CO_REVIEW.index('"$GATE_REPORT" lessons-check'),
                        CO_REVIEW.index('"$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-codex-reviewer.json"'))

    def test_mirror_captures_ci_and_runs_the_lessons_tier(self):
        for needle in ('"$GATE_REPORT" ci-envelope --pr-json "$RUN_DIR/pr-ci.json"',
                       "ci-watch.done", "## CI evidence", "ci.json: $RUN_DIR/ci.json sha256=",
                       '"$GATE_REPORT" lessons-check',
                       "Lessons tier: only the Claude-runner verifier",
                       "## Lessons fact-check",
                       'if [ "$CLASS" = "full" ] || [ "$CLASS" = "delta" ]; then'):
            self.assertIn(needle, MIRROR)
        self.assertNotIn('if [ "$CLASS" != "light" ]; then', MIRROR)

    def test_policy_describes_the_lessons_tier_and_ci_first(self):
        policy = subprocess.run(
            [sys.executable, str(REPO / "claude/skills/co-review/scripts/gate_report.py"),
             "policy", "--section", "POLICY"],
            capture_output=True, text=True, check=True,
        ).stdout
        flat = " ".join(policy.split())
        for needle in ("The lessons tier runs one `verifier`",
                       "`claude/rules/personal/agent-lessons.md`",
                       "before any probe or seat runs", "`gate_report.py ci-envelope`",
                       "names `ci.json`, its digest and its content",
                       "none in the lessons tier"):
            self.assertIn(needle, flat)


class CodexReviewGatesSkillText(unittest.TestCase):
    def test_spec_review_documents_probe_once(self):
        text = " ".join(SPEC_REVIEW.split())
        self.assertIn("later rounds of this review run the substitute directly", text)

    def test_spec_review_prompt_reviews_a_prd(self):
        self.assertIn("before implementation", SPEC_REVIEW)
        self.assertNotIn("before planning", SPEC_REVIEW)
        line = next(l for l in SPEC_REVIEW.splitlines() if "Round ${ROUND:-1} of $SPEC_MAX_ROUNDS" in l)
        for needle in ("acceptance criterion", "separable mechanisms", "existing tool"):
            self.assertIn(needle, line)

    def test_spec_review_documents_the_substitute_round(self):
        self.assertIn("### Substitute a failed Codex round", SPEC_REVIEW)
        for needle in ("quota, auth, or", "availability failure",
                       "never fires automatically for any other failure",
                       "is a completed round: the substitute never applies to it",
                       "--runtime claude --role reviewer",
                       "counts toward `SPEC_MAX_ROUNDS`"):
            self.assertIn(needle, SPEC_REVIEW)

    def test_spec_review_documents_the_closure_check(self):
        text = " ".join(SPEC_REVIEW.split())
        for needle in ("Closure check", "critical or high",
                       "the only call allowed past the cap",
                       "CLOSED or STILL-OPEN"):
            self.assertIn(needle, text)

    def test_spec_review_closure_check_covers_carried_findings(self):
        text = " ".join(SPEC_REVIEW.split())
        for needle in ("a critical or high finding is open after the round at the cap",
                       "The closure check never falls back to the full-document prompt"):
            self.assertIn(needle, text)

    def test_spec_review_proceeds_past_the_cap_only_after_a_complete_call(self):
        text = " ".join(SPEC_REVIEW.split())
        for needle in ("When no critical or high finding is open after a complete round at the cap",
                       "An incomplete round at the cap never starts the closure check"):
            self.assertIn(needle, text)

    def test_plan_review_documents_the_substitute_round(self):
        self.assertIn("### Substitute a failed Codex round", PLAN_REVIEW)
        for needle in ("quota, auth, or", "availability failure",
                       "never fires automatically for any other failure",
                       "is a completed round: the substitute never applies to it",
                       "--runtime claude --step plan-review",
                       "counts toward `PLAN_MAX_ROUNDS`"):
            self.assertIn(needle, PLAN_REVIEW)


class ShipSkillText(unittest.TestCase):
    def test_ship_has_the_audit_comment_step(self):
        for needle in ("audit-comment", "co-review-audit head=", "--paginate",
                       "gh pr comment", "self-classifies", "--full"):
            self.assertIn(needle, SHIP)

    def test_ship_stops_after_the_gate_under_a_herdr_brief(self):
        for needle in ("herdr-ship-brief: stop-after-gate", "ship.json",
                       "explicit merge confirmation", "step 6 confirmation"):
            self.assertIn(needle, SHIP)
        self.assertNotIn("step-5 confirmation", SHIP)

    def test_ship_carries_a_merge_main_head_with_the_proof(self):
        for needle in ("`carry-forward` command exits 0",
                       "carry-forward record's `audit_comment`"):
            self.assertIn(needle, SHIP)
        self.assertNotIn('"Merge-main-only commits keep the verdict" in', SHIP)

    def test_ship_maps_the_herdr_tier_lines(self):
        for needle in ("herdr-ship-brief: tier=full", "herdr-ship-brief: tier=delta",
                       "herdr-ship-prior-handoff:", "herdr-ship-delta-caps:",
                       "is not a relaunch after a fix"):
            self.assertIn(needle, SHIP)

    def test_ship_names_the_lessons_class(self):
        flat = " ".join(SHIP.split())
        self.assertIn("lessons for a diff touching only `claude/rules/personal/agent-lessons.md`", flat)


class PrBasePinText(unittest.TestCase):
    def test_both_entrypoints_pin_the_pr_base(self):
        for text in (CO_REVIEW, MIRROR):
            for needle in ("baseRefOid", "--pr-base", "merge result", "behind_by", "carry-forward"):
                self.assertIn(needle, text)
            self.assertNotIn("up-to-date branch", text)
            self.assertNotIn("merge_tree", text)

    def test_co_review_prepare_passes_the_pr_base(self):
        block = _extract_block(CO_REVIEW, '"$REVIEW_HELPER" prepare')
        self.assertIn('--pr-base "$PR_BASE"', block)

    def test_policy_frozen_inputs_gate_the_merge_result(self):
        start = POLICY_FILE.index("### Frozen inputs and report construction")
        end = POLICY_FILE.index("\n### ", start + 1)
        section = POLICY_FILE[start:end]
        for needle in ("baseRefOid", "merge result", "base-check", "carry-forward"):
            self.assertIn(needle, section)
        self.assertNotIn("up-to-date branch", section)
        self.assertNotIn("merge_tree", section)

    def test_herdr_section_6_names_the_pr_base(self):
        start = HERDR.index("\n## 6. ")
        end = HERDR.index("\n## 6a. ")
        self.assertIn("baseRefOid", HERDR[start:end])
        self.assertIn("merge result", HERDR[start:end])
        self.assertNotIn("up-to-date branch", HERDR)
        self.assertNotIn("rule (d)", HERDR)

    def test_pr_ready_and_ship_run_base_check(self):
        for needle in ("baseRefOid", "git ls-remote", "base-check"):
            self.assertIn(needle, PR_READY)
            self.assertIn(needle, SHIP)
        self.assertNotIn("resolve-base", PR_READY)
        self.assertIn("never compared for equality", PR_READY)
        for text in (PR_READY, SHIP):
            self.assertNotIn("merge-base --is-ancestor", text)
            self.assertNotIn("merge_tree", text)

    def test_ship_handoff_base_sha_is_the_pr_base(self):
        self.assertIn("baseRefOid", BRIEF)


class StructureLensText(unittest.TestCase):
    def test_policy_names_structure_fit_without_checklist_id(self):
        flat = " ".join(POLICY_FILE.split())
        self.assertIn(
            "The Structure fit class has no checklist ID; seats report it in "
            "their `Architecture` section and as findings.",
            flat,
        )


    def test_both_entrypoints_hand_finders_the_diff_and_frozen_worktree(self):
        for text in (CO_REVIEW, MIRROR):
            flat = " ".join(text.split())
            self.assertIn("frozen diff path (`$RUN_DIR/frozen.diff`)", flat)
            self.assertIn("as the frozen worktree for reading files outside the diff", flat)
        self.assertIn("sed -n '/^## Classes/,$p' \"$RUBRIC\" >>\"$RUN_DIR/$seat.prompt\"",
                      CO_REVIEW)

    def test_both_entrypoints_keep_structure_finding_fields(self):
        for text in (CO_REVIEW, MIRROR):
            flat = " ".join(text.split())
            self.assertIn("Copy each seat's Structure fit findings into `findings` with "
                          "`category: \"structure\"` and their `proposed_layout`", flat)

    def test_both_entrypoints_allow_one_structure_marker_line(self):
        for text in (CO_REVIEW, MIRROR):
            flat = " ".join(text.split())
            self.assertIn("one line per blocker (`<id>: <title>`), then at most one "
                          "`Structure: <id>: <proposed layout>` line", flat)

    def test_brief_template_forbids_per_run_architecture_addendum(self):
        section = BRIEF[BRIEF.index("## Repair and ship brief variants"):]
        flat = " ".join(section.split())
        self.assertIn("adds no architecture or lens addendum", flat)
        self.assertIn("`claude/skills/co-review/references/failure-classes.md`", flat)


if __name__ == "__main__":
    unittest.main()
