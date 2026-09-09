"""Focused ownership races and current-attempt regressions; no live state."""

import json
import os
import subprocess
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from unittest.mock import patch

HOOKS = Path(__file__).resolve().parent
sys.path.insert(0, str(HOOKS))
import herdr_orch_core as core

try:
    import herdr_coordination as coordination
except ImportError:
    coordination = None


class CoordinationTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ)
        environment.start()
        self.addCleanup(environment.stop)
        os.environ.pop("WORKFLOW_PERSONAL_ACCOUNT", None)
        os.environ.pop("CLAUDE_PERSONAL_ONLY", None)
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.previous = os.environ.get("HERDR_COORDINATION_ROOT")
        os.environ["HERDR_COORDINATION_ROOT"] = str(self.root / "registry")
        self.rd = self.root / "account-a" / "herdr-orch" / "repo"
        self.other = self.root / "account-b" / "herdr-orch" / "repo"
        self.rd.mkdir(parents=True)
        self.other.mkdir(parents=True)

    def tearDown(self):
        if self.previous is None:
            os.environ.pop("HERDR_COORDINATION_ROOT", None)
        else:
            os.environ["HERDR_COORDINATION_ROOT"] = self.previous
        self.tmp.cleanup()

    def test_shared_owner_blocks_other_account_payload(self):
        self.assertIsNotNone(coordination, "shared coordination module missing")
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            self.assertEqual(tx.claim("A", "host", 1), 1)
        with coordination.owner_transaction(
            self.other, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            self.assertIsNone(tx.claim("B", "host", 2))
        self.assertFalse((self.other / "capabilities.json").exists())
        metadata = coordination.owner_path(self.rd).read_text()
        self.assertNotIn("capabilities", metadata)

    def test_alias_binding_and_corrupt_owner_fail_closed(self):
        self.assertIsNotNone(coordination, "shared coordination module missing")
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            tx.claim("A", "host", 1)
        with (
            self.assertRaises(ValueError),
            coordination.owner_transaction(
                self.root / "alias", canonical_id="canonical", expected_slug="repo"
            ),
        ):
            pass
        coordination.owner_path(self.rd).write_text("[]")
        with (
            self.assertRaises(ValueError),
            coordination.owner_transaction(
                self.other, canonical_id="canonical", expected_slug="repo"
            ) as tx,
        ):
            tx.claim("B", "host", 2, stale_secs=0)

    def test_new_account_with_active_legacy_owner_blocks_canonical_claim(self):
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            tx.claim("A", "host", 1)
        (self.other / "owner.json").write_text(
            json.dumps(
                {
                    "session_id": "LEGACY",
                    "host": "host",
                    "pid": 2,
                    "fence": 1,
                    "heartbeat_ts": time.time(),
                }
            )
        )
        with (
            self.assertRaises(ValueError),
            coordination.owner_transaction(
                self.other, canonical_id="canonical", expected_slug="repo"
            ),
        ):
            pass

    def test_registry_slug_directory_symlink_is_rejected(self):
        registry = coordination.coordination_root()
        registry.mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (registry / "repo").symlink_to(outside, target_is_directory=True)
        with (
            self.assertRaises(ValueError),
            coordination.owner_transaction(
                self.rd, canonical_id="canonical", expected_slug="repo"
            ),
        ):
            pass
        self.assertFalse((outside / "owner.json").exists())

    def test_runtime_and_thread_identity_are_shared_without_payload_paths(self):
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            self.assertEqual(
                tx.claim("same", "host", 1, runtime="codex", thread_id="thread-1"), 1
            )
        with coordination.owner_transaction(
            self.other, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            self.assertIsNone(tx.claim("same", "host", 2, runtime="claude"))
            self.assertIsNone(
                tx.claim("same", "host", 2, runtime="codex", thread_id="thread-2")
            )
        record = json.loads(coordination.owner_path(self.rd).read_text())
        self.assertEqual(
            (record["runtime"], record["thread_id"]), ("codex", "thread-1")
        )
        bindings = (coordination.coordination_root() / "bindings.json").read_text()
        self.assertNotIn(str(self.root), bindings)
        self.assertNotIn("payload_roots", bindings)
        alias = self.root / "account-b" / "herdr-orch" / "alias"
        alias.mkdir()
        (alias / "owner.json").write_text(json.dumps(record))
        with self.assertRaises(ValueError), coordination.owner_transaction(alias):
            pass

    def test_corrupt_bindings_and_cli_fence_values_fail_closed(self):
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            tx.claim("A", "host", 1)
        registry = coordination.coordination_root() / "bindings.json"
        registry.write_text('{"repo":{"payload_scopes":[]}}')
        with self.assertRaises(ValueError), coordination.owner_transaction(self.rd):
            pass
        result = subprocess.run(
            [
                sys.executable,
                str(HOOKS / "herdr_orch_core.py"),
                "check-fence",
                "--repo-slug",
                "repo",
                "--session",
                "A",
                "--fence",
                "NaN",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)

    def test_owner_lock_persists_and_rejects_symlink(self):
        self.assertIsNotNone(coordination, "shared coordination module missing")
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ):
            pass
        lock = self.root / "registry" / ".owner.lock"
        ino = lock.stat().st_ino
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ):
            pass
        self.assertEqual(lock.stat().st_ino, ino)
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)
        lock.unlink()
        lock.symlink_to(self.root / "victim")
        with self.assertRaises(OSError), coordination.owner_transaction(self.rd):
            pass

    def test_no_fresh_unbound_owner_and_legacy_owner_migrates(self):
        self.assertIsNotNone(coordination, "shared coordination module missing")
        with (
            self.assertRaises(ValueError),
            coordination.owner_transaction(self.rd) as tx,
        ):
            tx.claim("A", "host", 1)
        legacy = {
            "session_id": "OLD",
            "host": "host",
            "pid": 1,
            "fence": 7,
            "heartbeat_ts": time.time(),
        }
        (self.rd / "owner.json").write_text(json.dumps(legacy))
        with coordination.owner_transaction(self.rd) as tx:
            self.assertIsNone(tx.claim("NEW", "host", 2))
        with coordination.owner_transaction(self.other) as tx:
            self.assertFalse(tx.check("OLD", 7))
        with coordination.owner_transaction(self.rd) as tx:
            self.assertTrue(tx.check("OLD", 7))

    def test_writer_validation_and_publish_precede_takeover(self):
        self.assertIsNotNone(coordination, "shared coordination module missing")
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            tx.claim("A", "host", 1)
        ready, release, result = [self.root / n for n in ("ready", "release", "result")]
        script = """import sys,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import herdr_coordination as c
rd,ready,release,result=map(Path,sys.argv[2:])
with c.owner_transaction(rd,session="A",fence=1):
 ready.touch()
 while not release.exists(): time.sleep(.01)
 (rd/'published').write_text('A')
with c.owner_transaction(rd) as tx:
 result.write_text(str(tx.check('A',1)))
"""
        writer = subprocess.Popen(
            [
                sys.executable,
                "-c",
                script,
                str(HOOKS),
                str(self.rd),
                str(ready),
                str(release),
                str(result),
            ]
        )
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists())
            claim = "import sys;sys.path.insert(0,sys.argv[1]);import herdr_coordination as c\nwith c.owner_transaction(sys.argv[2]) as tx: print(tx.claim('B','host',2,stale_secs=0),flush=True)"
            taker = subprocess.Popen(
                [sys.executable, "-c", claim, str(HOOKS), str(self.other)],
                stdout=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.1)
            self.assertIsNone(taker.poll(), "takeover escaped the writer transaction")
            release.touch()
            self.assertEqual(taker.communicate(timeout=5)[0].strip(), "2")
            writer.wait(timeout=5)
            self.assertEqual((self.rd / "published").read_text(), "A")
            with (
                self.assertRaises(ValueError),
                coordination.owner_transaction(self.rd, session="A", fence=1),
            ):
                (self.rd / "stale").touch()
            self.assertFalse((self.rd / "stale").exists())
        finally:
            release.touch()
            writer.wait(timeout=5)

    def test_reverse_lock_acquisition_is_rejected(self):
        self.assertIsNotNone(coordination, "shared coordination module missing")
        with (
            core.think_lock(self.rd),
            self.assertRaises(RuntimeError),
            coordination.owner_transaction(self.rd),
        ):
            pass

    def test_blocked_model_releases_locks_and_rechecks_owner_before_answer(self):
        self.assertIsNotNone(coordination, "shared coordination module missing")
        wt = self.root / "checkout"
        subprocess.run(["git", "init", "-q", str(wt)], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(wt),
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "base",
            ],
            check=True,
        )
        context = core.repository_context(wt)
        slug = core.repo_slug("", context["common_dir"])
        payload = self.root / "payload"
        rd = payload / "herdr-orch" / slug
        (rd / "think").mkdir(parents=True)
        tid = "think-triage-20260905170000"
        (rd / "think" / f"{tid}.question.md").write_text("question")
        original_config = os.environ.get("CLAUDE_CONFIG_DIR")
        os.environ["CLAUDE_CONFIG_DIR"] = str(payload)
        try:
            core.claim_owner(rd, "A", "host", 1, context=context, expected_slug=slug)
        finally:
            if original_config is None:
                os.environ.pop("CLAUDE_CONFIG_DIR", None)
            else:
                os.environ["CLAUDE_CONFIG_DIR"] = original_config
        ready, release = self.root / "model-ready", self.root / "model-release"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        fake = bin_dir / "claude"
        fake.write_text(
            f'#!{sys.executable}\nfrom pathlib import Path\nimport time\nPath({str(ready)!r}).touch()\nwhile not Path({str(release)!r}).exists(): time.sleep(.01)\nprint(\'{{"type":"result","subtype":"error_max_turns","num_turns":1,"total_cost_usd":0.1}}\')\n'
        )
        fake.chmod(0o700)
        env = dict(
            os.environ,
            CLAUDE_CONFIG_DIR=str(payload),
            PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
        )
        argv = [
            sys.executable,
            str(HOOKS / "herdr_orch_core.py"),
            "run-think",
            "--repo-slug",
            slug,
            "--session",
            "A",
            "--fence",
            "1",
            "--think-id",
            tid,
            "--kind",
            "triage",
            "--model",
            "fable",
            "--effort",
            "high",
            "--cwd",
            str(wt),
            "--max-turns",
            "15",
            "--max-budget-usd",
            "3",
            "--timeout-secs",
            "60",
        ]
        model = subprocess.Popen(
            argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        try:
            deadline = time.monotonic() + 5
            while (
                not ready.exists()
                and model.poll() is None
                and time.monotonic() < deadline
            ):
                time.sleep(0.01)
            self.assertTrue(ready.exists(), "model did not start")
            # Both locks must be available from another process while inference blocks.
            probe = "import sys;sys.path.insert(0,sys.argv[1]);import herdr_orch_core as c\nwith c.owner_transaction(sys.argv[2]) as tx,c.think_lock(sys.argv[2]): print(tx.claim('B','host',2,stale_secs=0))"
            result = subprocess.run(
                [sys.executable, "-c", probe, str(HOOKS), str(rd)],
                env=env,
                capture_output=True,
                text=True,
                timeout=3,
                check=True,
            )
            self.assertEqual(result.stdout.strip(), "2")
            release.touch()
            _, stderr = model.communicate(timeout=5)
            self.assertEqual(model.returncode, 3, stderr)
            self.assertFalse((rd / "think" / f"{tid}.answer.json").exists())
        finally:
            release.touch()
            model.communicate(timeout=5)

    def test_model_success_on_wrong_model_remains_retryable(self):
        self.assertIsNotNone(coordination, "shared coordination module missing")
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            tx.claim("A", "host", 1)
        tid = "think-triage-20260905170000"
        (self.rd / "think").mkdir()
        a = types.SimpleNamespace(
            session="A",
            fence=1,
            think_id=tid,
            kind="triage",
            task_id=None,
            repo_slug="repo",
            model="fable",
            effort="high",
            cwd=str(self.root),
        )
        answer = {
            "recommendation": "do A",
            "rationale": "why",
            "options": [
                {"label": "A", "summary": "s", "tradeoffs": "t", "risk": "low"},
                {"label": "B", "summary": "s", "tradeoffs": "t", "risk": "low"},
            ],
            "confidence": "high",
        }
        launch = {
            "caps": {"max_turns": 15, "max_budget_usd": 3, "timeout_secs": 60},
            "attempt": 1,
            "parent": None,
            "started": core.now_iso(),
        }
        original = core.run_headless
        core.run_headless = lambda *_: (
            "success",
            {
                "structured_output": answer,
                "modelUsage": {"claude-opus-4": {}},
                "num_turns": 1,
                "total_cost_usd": 0.1,
            },
            0,
        )
        try:
            self.assertEqual(core.run_think(self.rd, a, "q", launch, []), 0)
        finally:
            core.run_headless = original
        record = json.loads((self.rd / "think" / f"{tid}.answer.json").read_text())
        self.assertEqual(record["status"], "unanswered")
        self.assertTrue(record["model_attributable"])
        self.assertTrue(core.valid_answer_record(record, tid))


class AttemptTests(unittest.TestCase):
    def test_latest_attempt_rejects_old_completion_and_review(self):
        worker = {
            "launch_id": "new",
            "phase": "implement",
            "runtime": "codex",
            "workspace_id": "w1",
            "pane_id": "w1:p1",
            "source_head_sha": "a" * 40,
        }
        task = {"task_id": "td-a", "base_sha": "a" * 40, "workers": [worker]}
        done = dict(
            worker,
            task_id="td-a",
            base_sha="a" * 40,
            head_sha="b" * 40,
            outcome="completed",
        )
        self.assertTrue(core.is_completed(task, done, "b" * 40, "w1"))
        for field in ("launch_id", "phase", "runtime", "pane_id", "source_head_sha"):
            self.assertFalse(
                core.is_completed(task, dict(done, **{field: "old"}), "b" * 40, "w1"),
                field,
            )
        review = dict(worker, phase="review", source_head_sha="b" * 40)
        task = dict(task, workers=[worker, review], review_head_sha="b" * 40)
        done = dict(
            review,
            task_id="td-a",
            outcome="approved",
            reviewed_head_sha="b" * 40,
            blocking_count=0,
        )
        self.assertTrue(core.is_reviewed(task, done, "b" * 40, "w1"))
        self.assertFalse(
            core.is_reviewed(task, dict(done, launch_id="old"), "b" * 40, "w1")
        )
        self.assertFalse(
            core.is_reviewed(task, dict(done, blocking_count="bad"), "b" * 40, "w1")
        )

    def test_plan_completion_uses_hashed_private_artifacts_without_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            launch = root / "herdr-orch/repo/artifacts/td-a/planned-launch"
            launch.mkdir(parents=True)
            spec, plan = launch / "spec.md", launch / "plan.md"
            spec.write_text("Reviewed specification")
            plan.write_text("Reviewed plan")
            import hashlib

            artifacts = [
                {
                    "kind": kind,
                    "path": str(path),
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                }
                for kind, path in (("spec", spec), ("plan", plan))
            ]
            worker = {
                "launch_id": "new",
                "phase": "plan",
                "runtime": "codex",
                "workspace_id": "w1",
                "pane_id": "w1:p1",
                "source_head_sha": "a" * 40,
            }
            task = {
                "task_id": "td-a",
                "repo_slug": "repo",
                "base_sha": "a" * 40,
                "workers": [worker],
                "plan_artifacts": artifacts,
            }
            done = dict(
                worker,
                task_id="td-a",
                outcome="completed",
                head_sha="a" * 40,
                base_sha="a" * 40,
                plan_artifacts=artifacts,
            )
            self.assertTrue(
                hasattr(core, "is_plan_completed"),
                "private planning milestone validator missing",
            )
            self.assertTrue(core.is_plan_completed(task, done, "a" * 40, "w1", root))
            self.assertTrue(
                core.is_plan_completed(
                    task, dict(done, head_sha="b" * 40), "b" * 40, "w1", root
                )
            )
            self.assertFalse(core.is_completed(task, done, "a" * 40, "w1"))
            self.assertFalse(
                core.is_plan_completed(
                    task, dict(done, launch_id="old"), "a" * 40, "w1", root
                )
            )
            plan.write_text("unreviewed change")
            self.assertFalse(core.is_plan_completed(task, done, "a" * 40, "w1", root))
            plan.unlink()
            plan.symlink_to(spec)
            self.assertFalse(core.is_plan_completed(task, done, "a" * 40, "w1", root))

    def test_banner_cli_requires_fresh_launch_evidence(self):
        argv = [
            sys.executable,
            str(HOOKS / "herdr_orch_core.py"),
            "classify-banner",
            "--repo-slug",
            "repo",
            "--model",
            "sonnet",
            "--effort",
            "inherit",
            "--text",
            "Claude Code v2.1.1\n Sonnet 5\n",
        ]
        result = subprocess.run(argv, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.strip(), "unreadable")
        result = subprocess.run(
            [*argv, "--fresh-capture"], capture_output=True, text=True, check=True
        )
        self.assertEqual(result.stdout.strip(), "ok")

    def test_banner_requires_fresh_capture_boundary(self):
        old = "Claude Code v2.1.1\n Sonnet 5\n"
        new = "Claude Code v2.1.1\n Opus 4.6\n"
        self.assertIsNone(
            core.parse_banner(old + new),
            "ambiguous historical banners cannot confirm a launch",
        )
        self.assertEqual(
            core.parse_banner(old + "LAUNCH-X\n" + new, after="LAUNCH-X")["model"],
            "Opus 4.6",
        )
        self.assertIsNone(core.parse_banner(old, after="LAUNCH-X"))


if __name__ == "__main__":
    unittest.main()
