"""Reproductions for the independent owner-fencing review."""

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_coordination as coordination
import herdr_orch_core as core


class ReviewRegressions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.previous = os.environ.get("HERDR_COORDINATION_ROOT")
        os.environ["HERDR_COORDINATION_ROOT"] = str(self.root / "registry")
        self.rd = self.root / "personal" / "herdr-orch" / "repo"
        self.other = self.root / "work" / "herdr-orch" / "repo"
        self.rd.mkdir(parents=True)
        self.other.mkdir(parents=True)

    def tearDown(self):
        if self.previous is None:
            os.environ.pop("HERDR_COORDINATION_ROOT", None)
        else:
            os.environ["HERDR_COORDINATION_ROOT"] = self.previous
        self.tmp.cleanup()

    def claim(self):
        with coordination.owner_transaction(
            self.rd, canonical_id="canonical", expected_slug="repo"
        ) as tx:
            return tx.claim("A", "host", 1)

    def test_registry_replacement_cannot_rollback_or_publish_after_takeover(self):
        self.claim()
        registry = coordination.coordination_root()
        old = self.root / "old-registry"
        with coordination.owner_transaction(self.rd, session="A", fence=1) as tx:
            registry.rename(old)
            shutil.copytree(old, registry)
            code = "import sys;sys.path.insert(0,sys.argv[1]);import herdr_coordination as c\nwith c.owner_transaction(sys.argv[2]) as tx: print(tx.claim('B','host',2,stale_secs=0),flush=True)"
            contender = subprocess.Popen(
                [
                    sys.executable,
                    "-c",
                    code,
                    str(Path(core.__file__).parent),
                    str(self.rd),
                ],
                stdout=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.2)
            try:
                self.assertIsNone(
                    contender.poll(),
                    "replacement directory gave takeover an independent owner lock",
                )
                with self.assertRaises(ValueError):
                    tx.refresh("A", 1)
                with self.assertRaises(ValueError):
                    core.write_json_atomic(
                        self.rd / "must-not-publish.json", {"stale": True}
                    )
                self.assertFalse((self.rd / "must-not-publish.json").exists())
            except BaseException:
                contender.kill()
                contender.communicate(timeout=3)
                raise
        self.assertEqual(contender.communicate(timeout=3)[0].strip(), "2")
        self.assertEqual(
            json.loads(coordination.owner_path(self.rd).read_text())["fence"], 2
        )

    def test_fifo_metadata_fails_promptly_and_releases_global_lock(self):
        registry = coordination.coordination_root()
        registry.mkdir()
        fifo = registry / "bindings.json"
        os.mkfifo(fifo)
        code = "import sys;sys.path.insert(0,sys.argv[1]);import herdr_coordination as c\ntry:\n with c.owner_transaction(sys.argv[2],canonical_id='canonical',expected_slug='repo'): pass\nexcept ValueError: sys.exit(2)"
        process = subprocess.Popen(
            [sys.executable, "-c", code, str(Path(core.__file__).parent), str(self.rd)]
        )
        try:
            try:
                result = process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.fail("FIFO metadata blocked the shared owner lock")
            self.assertEqual(result, 2)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=2)
        fifo.unlink()
        self.assertEqual(self.claim(), 1)

    def test_missing_initialized_owner_cannot_reset_fence(self):
        self.claim()
        coordination.owner_path(self.rd).unlink()
        with (
            self.assertRaises(ValueError),
            coordination.owner_transaction(self.rd) as tx,
        ):
            tx.claim("B", "host", 2)

    def test_owner_and_plan_artifact_fifos_fail_promptly(self):
        self.claim()
        owner = coordination.owner_path(self.rd)
        owner.unlink()
        os.mkfifo(owner)
        code = "import sys;sys.path.insert(0,sys.argv[1]);import herdr_coordination as c\ntry:\n with c.owner_transaction(sys.argv[2]): pass\nexcept ValueError: sys.exit(2)"
        result = subprocess.run(
            [sys.executable, "-c", code, str(Path(core.__file__).parent), str(self.rd)],
            timeout=1,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        artifact = self.root / "herdr-orch/repo/artifacts/td-a/launch/spec.md"
        artifact.parent.mkdir(parents=True)
        os.mkfifo(artifact)
        task = {
            "task_id": "td-a",
            "repo_slug": "repo",
            "base_sha": "a" * 40,
            "workers": [],
            "plan_artifacts": [
                {"kind": "spec", "path": str(artifact), "sha256": "a" * 64},
                {
                    "kind": "plan",
                    "path": str(artifact.with_name("plan.md")),
                    "sha256": "b" * 64,
                },
            ],
        }
        done = {
            "task_id": "td-a",
            "phase": "plan",
            "outcome": "completed",
            "workspace_id": "w1",
            "head_sha": "a" * 40,
            "base_sha": "a" * 40,
            "plan_artifacts": task["plan_artifacts"],
        }
        script = "import json,sys;sys.path.insert(0,sys.argv[1]);import herdr_orch_core as c;print(c.is_plan_completed(json.loads(sys.argv[2]),json.loads(sys.argv[3]),'a'*40,'w1',sys.argv[4]))"
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                script,
                str(Path(core.__file__).parent),
                json.dumps(task),
                json.dumps(done),
                str(self.root),
            ],
            timeout=1,
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(result.stdout.strip(), "False")

    def test_foreign_account_cannot_reuse_owner_session_and_fence(self):
        self.claim()
        with (
            self.assertRaises(ValueError),
            coordination.owner_transaction(self.other, session="A", fence=1),
        ):
            pass
        with coordination.owner_transaction(self.other) as tx:
            self.assertIsNone(tx.claim("A", "host", 1))

    def test_active_legacy_accounts_with_reused_session_fence_conflict(self):
        record = {
            "session_id": "same",
            "host": "host",
            "pid": 1,
            "fence": 7,
            "heartbeat_ts": time.time(),
        }
        (self.rd / "owner.json").write_text(json.dumps(record))
        (self.other / "owner.json").write_text(json.dumps(record))
        with (
            self.assertRaises(ValueError),
            coordination.owner_transaction(self.rd, legacy_roots=(self.other.parent,)),
        ):
            pass

    def test_migrated_runtime_takeover_advances_fence(self):
        (self.rd / "owner.json").write_text(
            json.dumps(
                {
                    "session_id": "same",
                    "host": "host",
                    "pid": 1,
                    "fence": 7,
                    "heartbeat_ts": 0,
                }
            )
        )
        with coordination.owner_transaction(self.rd) as tx:
            self.assertEqual(
                tx.claim("same", "host", 2, runtime="codex", thread_id="new-thread"), 8
            )
            self.assertFalse(tx.check("same", 7))

    def test_codex_emission_uses_validated_work_payload_without_auth_override(self):
        home = self.root / "home"
        repo = home / "Git/work/project"
        repo.mkdir(parents=True)
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GIT_")
            and key
            not in (
                "CLAUDE_CONFIG_DIR",
                "CLAUDE_PERSONAL_ONLY",
                "CLAUDE_WORK_TREE",
                "CLAUDE_WORK_CONFIG_DIR",
            )
        }
        env["HOME"] = str(home)
        subprocess.run(["git", "init", "-q", str(repo)], env=env, check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
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
            env=env,
            check=True,
        )
        context = core.repository_context(repo)
        slug = core.repo_slug("", context["common_dir"])
        rd = home / ".claude-work/herdr-orch" / slug
        (rd / "tasks").mkdir(parents=True)
        with coordination.owner_transaction(
            rd, canonical_id=context["repo_id"], expected_slug=slug
        ) as tx:
            tx.claim("A", "host", 1, runtime="codex", thread_id="thread")
        worker = {
            "launch_id": "L1",
            "phase": "implement",
            "runtime": "codex",
            "workspace_id": "w1",
            "pane_id": "w1:p1",
            "source_head_sha": context["head"],
        }
        (rd / "tasks/td-a.json").write_text(
            json.dumps(
                {"task_id": "td-a", "base_sha": context["head"], "workers": [worker]}
            )
        )
        argv = [
            sys.executable,
            str(Path(core.__file__)),
            "emit-done",
            "--repo-slug",
            slug,
            "--repo-path",
            str(repo),
            "--runtime",
            "codex",
            "--task-id",
            "td-a",
            "--workspace",
            "w1",
            "--agent",
            "impl-td-a",
            "--phase",
            "implement",
            "--outcome",
            "completed",
            "--head-sha",
            "b" * 40,
            "--base-sha",
            context["head"],
            "--launch-id",
            "L1",
            "--pane-id",
            "w1:p1",
            "--source-head-sha",
            context["head"],
        ]
        result = subprocess.run(
            argv, env=env, text=True, capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((rd / "tasks/td-a.done.json").exists())
        self.assertFalse(
            (home / ".claude/herdr-orch" / slug / "tasks/td-a.done.json").exists()
        )
        self.assertNotIn("CLAUDE_CONFIG_DIR", env)

    def test_account_identity_helper_preserves_provider_hash(self):
        import workflow_context

        self.assertTrue(
            hasattr(workflow_context, "account_id_for_root"),
            "public legacy account identity helper missing",
        )
        import hashlib

        selected = self.root / "personal"
        expected = hashlib.sha256(
            ("claude-account\0" + str(selected.resolve())).encode()
        ).hexdigest()
        self.assertEqual(workflow_context.account_id_for_root(selected), expected)

    def test_payload_parent_symlinks_never_read_or_publish_foreign_state(self):
        for component in ("personal", "herdr-orch", "repo", "tasks"):
            with self.subTest(component=component):
                base = self.root / component
                local = base / "personal/herdr-orch/repo"
                foreign = base / "work/herdr-orch/repo"
                (local / "tasks").mkdir(parents=True)
                (foreign / "tasks").mkdir(parents=True)
                (foreign / "tasks/private.json").write_text('{"private":true}')
                parts = local.parts
                link = (
                    Path(*parts[: parts.index(component, len(base.parts)) + 1])
                    if component != "tasks"
                    else local / "tasks"
                )
                destination = (
                    foreign / "tasks"
                    if component == "tasks"
                    else {
                        "personal": base / "work",
                        "herdr-orch": foreign.parent,
                        "repo": foreign,
                    }[component]
                )
                shutil.rmtree(link)
                link.symlink_to(destination, target_is_directory=True)
                with self.assertRaises((ValueError, OSError)):
                    core.write_json_atomic(local / "tasks/new.json", {"personal": True})
                self.assertFalse((foreign / "tasks/new.json").exists())
                self.assertFalse(
                    core.publish_exclusive(local / "tasks/exclusive.json", {})
                )
                self.assertFalse((foreign / "tasks/exclusive.json").exists())
                with self.assertRaises((ValueError, OSError)):
                    core.read_payload_text(local / "tasks/private.json")

    def test_claim_rejects_payload_symlink_before_legacy_read(self):
        self.rd.rmdir()
        self.rd.symlink_to(self.other, target_is_directory=True)
        (self.other / "owner.json").write_text('{"private":"not-owner-metadata"}')
        with (
            patch.object(
                coordination, "_read", side_effect=AssertionError("foreign read")
            ),
            self.assertRaises((ValueError, OSError)),
        ):
            self.claim()
        self.assertFalse(coordination.owner_path(self.rd).exists())

    def test_payload_publication_stays_on_open_directory_when_path_changes(self):
        target = self.rd / "tasks"
        target.mkdir()
        original = self.rd / "old-tasks"
        real_replace = os.replace

        def swap_then_replace(source, destination, **kwargs):
            target.rename(original)
            target.symlink_to(self.other, target_is_directory=True)
            return real_replace(source, destination, **kwargs)

        with patch.object(os, "replace", side_effect=swap_then_replace):
            core.write_json_atomic(target / "new.json", {"personal": True})
        self.assertFalse((self.other / "new.json").exists())
        self.assertEqual(
            json.loads((original / "new.json").read_text()), {"personal": True}
        )

    def test_owner_payload_directory_replacement_invalidates_publication(self):
        self.claim()
        with coordination.owner_transaction(self.rd, session="A", fence=1):
            self.rd.rename(self.rd.with_name("old-repo"))
            self.rd.symlink_to(self.other, target_is_directory=True)
            with self.assertRaises((ValueError, OSError)):
                core.write_json_atomic(self.rd / "private.json", {"personal": True})
        self.assertFalse((self.other / "private.json").exists())

    def test_personal_account_root_keeps_symlink_visible(self):
        home = self.root / "home"
        home.mkdir()
        (home / ".claude-work").mkdir()
        (home / ".claude").symlink_to(home / ".claude-work", target_is_directory=True)
        selected = {
            "scope": {"kind": "personal", "account_root": str(home / ".claude-work")}
        }
        with patch.dict(os.environ, {"HOME": str(home)}):
            token = core._PAYLOAD_SELECTION.set(selected)
            try:
                self.assertEqual(core.state_root(), home / ".claude/herdr-orch")
                with self.assertRaises((ValueError, OSError)):
                    core.write_json_atomic(core.repo_dir("repo") / "task.json", {})
            finally:
                core._PAYLOAD_SELECTION.reset(token)

    def test_native_personal_cli_rejects_account_and_payload_symlink_crossing(self):
        for component in ("account", "herdr-orch", "repo", "tasks"):
            with self.subTest(component=component):
                home = self.root / component / "home"
                repo = home / "Git/personal/project"
                repo.mkdir(parents=True)
                env = {
                    key: value
                    for key, value in os.environ.items()
                    if not key.startswith(("GIT_", "CLAUDE_"))
                }
                env.update(
                    HOME=str(home), HERDR_COORDINATION_ROOT=str(home / "registry")
                )
                subprocess.run(["git", "init", "-q", str(repo)], env=env, check=True)
                subprocess.run(
                    [
                        "git",
                        "-C",
                        str(repo),
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
                    env=env,
                    check=True,
                )
                context = core.repository_context(repo)
                slug = core.repo_slug("", context["common_dir"])
                local = home / ".claude/herdr-orch" / slug
                foreign = home / ".claude-work/herdr-orch" / slug
                (local / "tasks").mkdir(parents=True)
                (foreign / "tasks").mkdir(parents=True)
                paths = {
                    "account": (local.parent.parent, foreign.parent.parent),
                    "herdr-orch": (local.parent, foreign.parent),
                    "repo": (local, foreign),
                    "tasks": (local / "tasks", foreign / "tasks"),
                }
                common = [
                    "--repo-slug",
                    slug,
                    "--repo-path",
                    str(repo),
                    "--runtime",
                    "codex",
                    "--personal",
                ]
                claim = [
                    sys.executable,
                    str(Path(core.__file__)),
                    "claim-owner",
                    *common,
                    "--session",
                    "A",
                    "--host",
                    "host",
                    "--pid",
                    "1",
                    "--thread-id",
                    "thread",
                ]
                if component == "tasks":
                    result = subprocess.run(
                        claim, env=env, text=True, capture_output=True, check=False
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                link, destination = paths[component]
                shutil.rmtree(link)
                link.symlink_to(destination, target_is_directory=True)
                command = (
                    claim
                    if component != "tasks"
                    else [
                        sys.executable,
                        str(Path(core.__file__)),
                        "write-task",
                        *common,
                        "--session",
                        "A",
                        "--fence",
                        "1",
                        "--task-id",
                        "td-a",
                        "--json",
                        '{"task_id":"td-a","brief":"personal"}',
                    ]
                )
                result = subprocess.run(
                    command,
                    env=env,
                    text=True,
                    capture_output=True,
                    timeout=3,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((foreign / "tasks/td-a.json").exists())
                self.assertFalse((foreign / "owner.json").exists())

    def test_nonblocking_append_and_read_reject_fifo_payloads(self):
        fifo = self.rd / "fifo.json"
        os.mkfifo(fifo)
        with self.assertRaises((ValueError, OSError)):
            core.read_payload_text(fifo)
        with self.assertRaises((ValueError, OSError)):
            core.append_payload(fifo, b"private")

    def test_plan_artifacts_belong_to_current_task_and_one_launch_directory(self):
        account = self.root / "account"
        for task_id, suffix in (
            ("td-b", "launch"),
            ("td-a", "launch/nested"),
            ("td-a", ""),
            ("td-a", "launch"),
        ):
            with self.subTest(task_id=task_id, suffix=suffix):
                folder = account / "herdr-orch/repo/artifacts" / task_id / suffix
                folder.mkdir(parents=True, exist_ok=True)
                artifacts = []
                for kind in ("spec", "plan"):
                    path = folder / f"{kind}.md"
                    path.write_text("identical reviewed content")
                    artifacts.append(
                        {
                            "kind": kind,
                            "path": str(path),
                            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        }
                    )
                task = {
                    "task_id": "td-a",
                    "repo_slug": "repo",
                    "base_sha": "a" * 40,
                    "workers": [],
                    "plan_artifacts": artifacts,
                }
                done = {
                    "task_id": "td-a",
                    "phase": "plan",
                    "outcome": "completed",
                    "workspace_id": "w1",
                    "head_sha": "a" * 40,
                    "base_sha": "a" * 40,
                    "plan_artifacts": artifacts,
                }
                self.assertEqual(
                    core.is_plan_completed(task, done, "a" * 40, "w1", account),
                    task_id == "td-a" and suffix == "launch",
                )
                if task_id == "td-a" and suffix == "launch":
                    task["repo_id"] = "canonical-repository"
                    metadata = {
                        "task_id": "td-a",
                        "repo_id": task["repo_id"],
                        "account_id": coordination.account_id_for_root(account),
                    }
                    artifacts[0]["task"] = metadata
                    artifacts[0]["source"] = {
                        "repo_id": task["repo_id"],
                        "sha256": artifacts[0]["sha256"],
                    }
                    self.assertTrue(
                        core.is_plan_completed(task, done, "a" * 40, "w1", account)
                    )
                    for key in metadata:
                        artifacts[0]["task"] = dict(metadata, **{key: "foreign"})
                        self.assertFalse(
                            core.is_plan_completed(task, done, "a" * 40, "w1", account)
                        )
                    artifacts[0]["task"] = metadata
                    artifacts[0]["source"]["sha256"] = "0" * 64
                    self.assertFalse(
                        core.is_plan_completed(task, done, "a" * 40, "w1", account)
                    )

    def test_legacy_review_without_explicit_review_worker_remains_valid(self):
        task = {
            "task_id": "td-a",
            "base_sha": "base",
            "review_head_sha": "head",
            "workers": [{"role": "impl", "workspace_id": "w1"}],
        }
        done = {
            "task_id": "td-a",
            "phase": "review",
            "outcome": "approved",
            "workspace_id": "w2",
            "reviewed_head_sha": "head",
            "blocking_count": 0,
        }
        self.assertTrue(core.is_reviewed(task, done, "head", "w2"))
        task["workers"].append(
            {
                "phase": "review",
                "runtime": "codex",
                "launch_id": "new",
                "workspace_id": "w2",
                "pane_id": "w2:p1",
                "source_head_sha": "a" * 40,
            }
        )
        self.assertFalse(core.is_reviewed(task, done, "head", "w2"))

    def test_native_history_requires_the_latest_row_for_every_phase(self):
        for phase in ("implement", "plan", "review"):
            worker = {
                "phase": phase,
                "runtime": "codex",
                "workspace_id": "w1",
                "pane_id": "pane1",
                "launch_id": "old-attempt",
                "source_head_sha": "a" * 40,
            }
            legacy = {"phase": phase, "workspace_id": "w1"}
            done = {**worker}
            self.assertTrue(
                core.attempt_matches({"workers": [legacy, worker]}, done, phase, "w1")
            )
            other_phase = "plan" if phase != "plan" else "implement"
            tails = (
                None,
                {},
                [],
                "broken",
                {"phase": other_phase},
                {**legacy, "launch_id": "new-attempt"},
                {**worker, "phase": other_phase, "launch_id": "new-attempt"},
            )
            for tail in tails:
                with self.subTest(phase=phase, tail=tail):
                    self.assertFalse(
                        core.attempt_matches(
                            {"workers": [worker, tail]}, done, phase, "w1"
                        )
                    )
            # A result matching a newer untyped row must not downgrade a
            # task that already has native history to legacy validation.
            untyped = {key: value for key, value in worker.items() if key != "runtime"}
            untyped["launch_id"] = "new-attempt"
            with self.subTest(phase=phase, tail="matching untyped result"):
                self.assertFalse(
                    core.attempt_matches(
                        {"workers": [worker, untyped]},
                        {**worker, "launch_id": "new-attempt"},
                        phase,
                        "w1",
                    )
                )

    def test_stale_native_emission_and_confirmation_reject_malformed_latest_row(self):
        home = self.root / "home"
        repo = home / "Git/personal/project"
        repo.mkdir(parents=True)
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GIT_")
            and key
            not in (
                "CLAUDE_CONFIG_DIR",
                "CLAUDE_PERSONAL_ONLY",
                "CLAUDE_WORK_TREE",
                "CLAUDE_WORK_CONFIG_DIR",
            )
        }
        env["HOME"] = str(home)

        def git(*args):
            return subprocess.check_output(
                ["git", "-C", str(repo), *args], env=env, text=True
            ).strip()

        git("init", "-q")
        for message in ("base", "implementation"):
            (repo / "tracked.txt").write_text(message)
            git("add", "tracked.txt")
            git(
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "user.name=Test",
                "-c",
                "user.email=test@example.invalid",
                "commit",
                "-qm",
                message,
            )
        head, base = git("rev-parse", "HEAD"), git("rev-parse", "HEAD^")
        context = core.repository_context(repo)
        slug = core.repo_slug("", context["common_dir"])
        common = [
            "--repo-slug",
            slug,
            "--repo-path",
            str(repo),
            "--runtime",
            "codex",
            "--personal",
        ]

        def run(command, *args):
            return subprocess.run(
                [sys.executable, str(Path(core.__file__)), command, *common, *args],
                env=env,
                text=True,
                capture_output=True,
                check=False,
                timeout=5,
            )

        claim = run(
            "claim-owner",
            "--session",
            "controller",
            "--host",
            "host",
            "--pid",
            str(os.getpid()),
            "--thread-id",
            "00000000-0000-4000-8000-000000000001",
        )
        self.assertEqual(claim.returncode, 0, claim.stderr)
        rd = home / ".claude/herdr-orch" / slug
        (rd / "tasks").mkdir(parents=True)
        worker = {
            "phase": "implement",
            "runtime": "codex",
            "role": "implementation",
            "workspace_id": "w1",
            "pane_id": "pane1",
            "launch_id": "old-impl",
            "source_head_sha": base,
        }
        task = {"task_id": "td-a", "base_sha": base, "workers": [worker]}
        task_path = rd / "tasks/td-a.json"
        task_path.write_text(json.dumps(task))
        emit_args = (
            "--task-id",
            "td-a",
            "--workspace",
            "w1",
            "--agent",
            "impl-td-a",
            "--phase",
            "implement",
            "--outcome",
            "completed",
            "--head-sha",
            head,
            "--base-sha",
            base,
            "--launch-id",
            "old-impl",
            "--pane-id",
            "pane1",
            "--source-head-sha",
            base,
        )
        confirm_args = ("--task-id", "td-a", "--workspace", "w1", "--head-sha", head)
        emitted = run("emit-done", *emit_args)
        self.assertEqual(emitted.returncode, 0, emitted.stderr)
        self.assertEqual(run("confirm-completion", *confirm_args).returncode, 0)
        done_path = rd / "tasks/td-a.done.json"
        saved_done = done_path.read_bytes()
        tails = (
            {
                "phase": "plan",
                "role": "planner",
                "workspace_id": "w1",
                "pane_id": "pane1",
                "launch_id": "new-plan",
                "source_head_sha": head,
            },
            None,
            {},
            {"phase": "plan"},
        )
        for tail in tails:
            with self.subTest(tail=tail):
                task_path.write_text(json.dumps({**task, "workers": [worker, tail]}))
                rejected = run("emit-done", *emit_args)
                confirmed = run("confirm-completion", *confirm_args)
                with self.subTest(operation="emit"):
                    self.assertEqual(rejected.returncode, 2, rejected.stderr)
                with self.subTest(operation="confirm"):
                    self.assertEqual(confirmed.returncode, 1, confirmed.stderr)
                with self.subTest(operation="preserve prior record"):
                    self.assertEqual(done_path.read_bytes(), saved_done)


if __name__ == "__main__":
    unittest.main()
