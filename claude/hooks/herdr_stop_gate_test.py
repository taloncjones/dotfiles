"""Focused strict-attempt and native Stop output tests; no live state."""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HOOKS = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "herdr_stop_gate", HOOKS / "herdr_stop_gate.py"
)
gate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(gate)


class StopGateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        environment = dict(os.environ)
        for key in (
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_PERSONAL_ONLY",
            "WORKFLOW_PERSONAL_ACCOUNT",
            "CLAUDE_WORK_TREE",
            "CLAUDE_WORK_CONFIG_DIR",
            "HERDR_PERSONAL",
            "HERDR_ACCOUNT_ID",
        ):
            environment.pop(key, None)
        environment.update(
            HOME=str(self.root),
            HERDR_ENV="1",
            HERDR_WORKSPACE_ID="w1",
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_CONFIG_NOSYSTEM="1",
            PYTHONDONTWRITEBYTECODE="1",
        )
        self.environment = mock.patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.worktree = self.root / "Git" / "personal" / "project"
        self._make_repository(self.worktree)
        context = gate.core.repository_context(self.worktree)
        self.slug = gate.core.repo_slug("", context["common_dir"])
        self.scope = gate.core.account_scope(self.worktree, "codex")
        self.state_root = Path(self.scope["account_root"]) / "herdr-orch"
        self.rd = self.state_root / self.slug
        (self.rd / "tasks").mkdir(parents=True)
        (self.rd / "workspaces").mkdir()
        self.task_id = "PROJ-1"
        self.workspace = "w1"
        self.base_sha = context["head"]
        self.head_sha = context["head"]
        self.entry = {
            "role": "implementation",
            "phase": "implement",
            "runtime": "codex",
            "workspace_id": self.workspace,
            "agent": "impl-proj-1",
            "launch_id": "launch-1",
            "pane_id": "pane-1",
            "source_head_sha": self.base_sha,
            "account_id": self.scope["account_id"],
            "ts": "2026-09-07T12:00:00Z",
        }
        self._write_index("impl")
        self._write_task([self.entry])

    def _make_repository(self, path):
        path.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(path),
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.test",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "fixture",
            ],
            check=True,
        )

    def _payload(self, active=False):
        return {
            "hook_event_name": "Stop",
            "stop_hook_active": active,
            "cwd": str(self.worktree),
        }

    def tearDown(self):
        self.environment.stop()
        self.tmp.cleanup()

    def _write_index(self, role):
        (self.rd / "workspaces" / f"{self.workspace}.json").write_text(
            json.dumps({"task_id": self.task_id, "repo_slug": self.slug, "role": role})
        )

    def _write_task(self, workers):
        (self.rd / "tasks" / f"{self.task_id}.json").write_text(
            json.dumps(
                {
                    "task_id": self.task_id,
                    "repo_slug": self.slug,
                    "worktree": str(self.worktree),
                    "base_sha": self.base_sha,
                    "workers": workers,
                }
            )
        )

    def _write_done(self, **overrides):
        done = {
            "task_id": self.task_id,
            "workspace_id": self.workspace,
            "agent": self.entry["agent"],
            "phase": self.entry["phase"],
            "outcome": "completed",
            "head_sha": self.head_sha,
            "base_sha": self.base_sha,
            "launch_id": self.entry["launch_id"],
            "runtime": self.entry["runtime"],
            "pane_id": self.entry["pane_id"],
            "source_head_sha": self.entry["source_head_sha"],
            "ts": "2026-09-07T12:00:01Z",
        }
        done.update(overrides)
        (self.rd / "tasks" / f"{self.task_id}.done.json").write_text(json.dumps(done))

    def test_native_attempt_requires_exact_tuple_and_safe_emitter(self):
        self._write_done(phase="plan", launch_id="old-plan")

        result = gate.evaluate(self._payload(), native=True)

        self.assertEqual(result["action"], "refuse")
        command = result["command"]
        self.assertIn("--repo-path", command)
        self.assertIn("--runtime codex", command)
        self.assertIn("--personal", command)
        self.assertIn("--launch-id launch-1", command)
        self.assertIn("--pane-id pane-1", command)
        self.assertIn("--source-head-sha " + self.base_sha, command)
        self.assertIn("--outcome '<completed|failed|paused>'", command)
        self.assertNotIn("--outcome completed|failed|paused", command)

    def test_native_attempt_allows_an_exact_current_record(self):
        self._write_done()

        result = gate.evaluate(self._payload(), native=True)

        self.assertEqual(result["action"], "allow")

    def test_native_review_rejects_impl_record_and_requires_review_tuple(self):
        review = {
            **self.entry,
            "role": "reviewer",
            "phase": "review",
            "launch_id": "review-1",
        }
        self._write_index("review")
        self._write_task([self.entry, review])
        self._write_done()

        result = gate.evaluate(self._payload(), native=True)

        self.assertEqual(result["action"], "refuse")
        self.assertIn("emit-review", result["command"])
        self.assertIn("--launch-id review-1", result["command"])
        self.assertIn("--outcome '<approved|changes-requested>'", result["command"])

    def test_native_account_mismatch_refuses_without_exposing_identity(self):
        self._write_task([{**self.entry, "account_id": "foreign-account"}])
        self._write_done()

        result = gate.evaluate(self._payload(), native=True)

        self.assertEqual(result["action"], "refuse")
        self.assertIsNone(result["command"])
        self.assertNotIn(self.scope["account_id"], result["reason"])
        self.assertNotIn("foreign-account", result["reason"])

    def test_malformed_native_payload_fails_open_and_active_stop_releases(self):
        malformed = gate.evaluate(
            {**self._payload(), "stop_hook_active": "false"}, native=True
        )
        active = gate.evaluate(self._payload(True), native=True)

        self.assertEqual(malformed["action"], "allow")
        self.assertEqual(active["action"], "release")

    def test_codex_work_scope_is_selected_before_index_lookup(self):
        self.worktree = self.root / "Git" / "work" / "project"
        self._make_repository(self.worktree)
        context = gate.core.repository_context(self.worktree)
        self.slug = gate.core.repo_slug("", context["common_dir"])
        self.scope = gate.core.account_scope(self.worktree, "codex")
        self.assertEqual(self.scope["kind"], "work")
        self.rd = Path(self.scope["account_root"]) / "herdr-orch" / self.slug
        (self.rd / "tasks").mkdir(parents=True)
        (self.rd / "workspaces").mkdir()
        self.entry = {
            **self.entry,
            "source_head_sha": context["head"],
            "account_id": self.scope["account_id"],
        }
        self._write_index("impl")
        self._write_task([self.entry])
        result = gate.evaluate(self._payload(), native=True)
        self.assertEqual(result["action"], "refuse")
        self.assertIn("--runtime codex", result["command"])
        self.assertNotIn("--personal", result["command"])
        self.assertNotIn("CLAUDE_CONFIG_DIR", os.environ)

    def test_native_missing_role_never_downgrades_to_legacy_acceptance(self):
        self._write_task([self.entry, {**self.entry, "role": "unexpected"}])
        self._write_done(phase="plan", launch_id="stale")
        result = gate.evaluate(self._payload(), native=True)
        self.assertEqual(result["action"], "refuse")
        self.assertIsNone(result["command"])

    def test_native_planner_uses_current_plan_attempt(self):
        self.entry = {**self.entry, "role": "planner", "phase": "plan"}
        self._write_task([self.entry])
        self._write_done(phase="implement", launch_id="stale")
        result = gate.evaluate(self._payload(), native=True)
        self.assertEqual(result["action"], "refuse")
        self.assertIn("--phase plan", result["command"])

    def test_native_record_requires_a_valid_lifecycle_envelope(self):
        for override in ({"ts": None}, {"outcome": None}):
            with self.subTest(override=override):
                self._write_task([{**self.entry, "role": "impl"}])
                self._write_done(**override)
                self.assertEqual(
                    gate.evaluate(self._payload(), native=True)["action"], "refuse"
                )

    def test_wrapper_handles_fifo_index_and_native_envelopes(self):
        wrapper = HOOKS.parents[1] / "codex" / "hooks" / "herdr_stop_gate.py"
        index = self.rd / "workspaces" / f"{self.workspace}.json"
        index.unlink()
        os.mkfifo(index)
        for active in (False, True):
            process = subprocess.run(
                [sys.executable, str(wrapper)],
                input=json.dumps(self._payload(active)),
                text=True,
                capture_output=True,
                timeout=2,
                check=False,
            )
            self.assertEqual(process.returncode, 0)
            self.assertNotEqual(json.loads(process.stdout).get("decision"), "block")
        index.unlink()
        self._write_index("impl")
        process = subprocess.run(
            [sys.executable, str(wrapper)],
            input=json.dumps(self._payload()),
            text=True,
            capture_output=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(process.returncode, 0)
        self.assertEqual(json.loads(process.stdout)["decision"], "block")

    def test_explicit_personal_selection_is_pinned_without_auth_mutation(self):
        self.worktree = self.root / "Git" / "work" / "personal-project"
        self._make_repository(self.worktree)
        context = gate.core.repository_context(self.worktree)
        self.slug = gate.core.repo_slug("", context["common_dir"])
        self.scope = gate.core.account_scope(self.worktree, "codex", personal=True)
        self.rd = Path(self.scope["account_root"]) / "herdr-orch" / self.slug
        (self.rd / "tasks").mkdir(parents=True)
        (self.rd / "workspaces").mkdir()
        self.entry = {
            **self.entry,
            "source_head_sha": context["head"],
            "account_id": self.scope["account_id"],
            "personal": True,
        }
        self._write_index("impl")
        self._write_task([self.entry])
        os.environ["HERDR_PERSONAL"] = "1"
        os.environ["HERDR_ACCOUNT_ID"] = self.scope["account_id"]
        result = gate.evaluate(self._payload(), native=True)
        self.assertEqual(result["action"], "refuse")
        self.assertIn("--personal", result["command"])
        self.assertNotIn("CLAUDE_CONFIG_DIR", os.environ)
        self._write_task([{**self.entry, "personal": False}])
        result = gate.evaluate(self._payload(), native=True)
        self.assertEqual(result["action"], "refuse")
        self.assertIsNone(result["command"])

    def test_invalid_account_metadata_never_selects_another_payload(self):
        for personal, account in (
            ("true", self.scope["account_id"]),
            ("1", "foreign"),
            ("0", ""),
        ):
            with self.subTest(personal=personal, account=account):
                os.environ["HERDR_PERSONAL"] = personal
                os.environ["HERDR_ACCOUNT_ID"] = account
                self._write_done()
                result = gate.evaluate(self._payload(), native=True)
                self.assertEqual(result["action"], "refuse")
                self.assertIsNone(result["command"])

    def test_native_task_must_match_the_selected_repository_and_id(self):
        other = self.root / "Git" / "personal" / "other"
        self._make_repository(other)
        task_path = self.rd / "tasks" / f"{self.task_id}.json"
        self._write_done()
        for override in (
            {"worktree": str(other)},
            {"task_id": "PROJ-2"},
            {"repo_slug": "foreign"},
        ):
            with self.subTest(override=override):
                self._write_task([self.entry])
                task_path.write_text(
                    json.dumps({**json.loads(task_path.read_text()), **override})
                )
                result = gate.evaluate(self._payload(), native=True)
                self.assertEqual(result["action"], "refuse")
                self.assertIsNone(result["command"])

    def test_claude_bound_metadata_cannot_fall_back_to_legacy(self):
        legacy = {key: value for key, value in self.entry.items() if key != "runtime"}
        self._write_task([{**legacy, "role": "impl", "personal": False}])
        self._write_done(phase="plan", launch_id="stale")
        os.environ["HERDR_PERSONAL"] = "0"
        os.environ["HERDR_ACCOUNT_ID"] = self.scope["account_id"]
        result = gate.evaluate(self._payload())
        self.assertEqual(result["action"], "refuse")
        self.assertIsNone(result["command"])

    def test_legacy_nudge_preserves_compatibility_and_quotes_placeholders(self):
        self._write_task([])
        payload = {"hook_event_name": "Stop", "stop_hook_active": False}
        result = gate.evaluate(payload)
        self.assertEqual(result["action"], "refuse")
        self.assertIn("--agent '<agent>'", result["command"])
        self.assertIn("--phase '<phase>'", result["command"])
        self._write_done()
        self.assertEqual(gate.evaluate(payload)["action"], "allow")
        (self.rd / "tasks" / f"{self.task_id}.done.json").unlink()
        result = gate.evaluate({**payload, "stop_hook_active": True})
        self.assertEqual(result["action"], "release")

    def test_claude_active_stop_releases_with_broken_account_metadata(self):
        for value, account in (("broken", self.scope["account_id"]), ("0", "foreign")):
            with self.subTest(value=value):
                environment = dict(
                    os.environ, HERDR_PERSONAL=value, HERDR_ACCOUNT_ID=account
                )
                process = subprocess.run(
                    [sys.executable, str(HOOKS / "herdr_stop_gate.py")],
                    input=json.dumps(self._payload(True)),
                    capture_output=True,
                    text=True,
                    env=environment,
                    timeout=2,
                    check=False,
                )
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertIn("released", json.loads(process.stdout)["systemMessage"])


if __name__ == "__main__":
    unittest.main()
