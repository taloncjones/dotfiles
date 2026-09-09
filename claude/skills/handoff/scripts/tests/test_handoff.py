"""Hermetic handoff tests: subprocess CLI, private fixtures, no model calls."""

import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "handoff.py"
sys.path.insert(0, str(SCRIPT.parent))
import handoff


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / "home"
        self.repo = self.home / "Git/personal/project with spaces"
        self.state = self.root / "state"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GIT_")
            and key
            not in {
                "CLAUDE_CONFIG_DIR",
                "CLAUDE_PERSONAL_ONLY",
                "CLAUDE_WORK_TREE",
                "CLAUDE_WORK_CONFIG_DIR",
                "CODEX_HOME",
                "XDG_STATE_HOME",
            }
        }
        self.env.update(HOME=str(self.home), DOTFILES_HANDOFF_STATE_DIR=str(self.state))
        self.init_repo(self.repo)
        self.brief = self.repo / "brief.txt"
        self.brief.write_text(
            "Scope: finish the regression fix.\nNext: run the focused tests.\n"
        )

    def git(self, *args, repo=None):
        return subprocess.run(
            ["git", "-C", str(repo or self.repo), *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()

    def init_repo(self, repo, metadata=None):
        repo.mkdir(parents=True)
        args = ["git", "init", "-q", "-b", "trunk"]
        if metadata is not None:
            args.extend(["--separate-git-dir", str(metadata)])
        subprocess.run(
            [*args, str(repo)], env=self.env, check=True, capture_output=True
        )
        self.git("config", "user.name", "fixture", repo=repo)
        self.git("config", "user.email", "fixture@example.invalid", repo=repo)
        self.git("config", "commit.gpgsign", "false", repo=repo)
        self.git("commit", "--allow-empty", "-qm", "fixture", repo=repo)

    def run_cli(
        self,
        command,
        *args,
        repo=None,
        runtime="codex",
        personal=False,
        expect=0,
        env=None,
    ):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                command,
                "--repo",
                str(repo or self.repo),
                "--runtime",
                runtime,
                *(["--personal"] if personal else []),
                *args,
            ],
            env=env or self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def save(self, task="task-one", **kwargs):
        return self.run_cli(
            "save", "--task", task, "--brief-file", str(self.brief), **kwargs
        )

    def load(self, task="task-one", **kwargs):
        return self.run_cli("load", "--task", task, **kwargs)

    def test_round_trip_keeps_exact_scope_git_and_brief(self):
        saved = self.save(runtime="claude", personal=True)
        loaded = self.load(runtime="codex", personal=True)
        self.assertEqual(loaded["record"], saved["record"])
        record = loaded["record"]
        self.assertEqual(record["brief"], self.brief.read_text())
        self.assertEqual(record["repository"]["head"], self.git("rev-parse", "HEAD"))
        self.assertEqual(record["repository"]["branch"], "trunk")
        self.assertEqual(record["base_sha"], record["repository"]["head"])
        self.assertEqual(record["source_runtime"], "claude")
        self.assertEqual(record["account_id"], loaded["scope"]["account_id"])
        self.assertEqual(
            self.run_cli("verify", "--task", "task-one")["git_status"], "unchanged"
        )

    def test_load_and_list_do_not_create_missing_state(self):
        self.assertEqual(self.run_cli("list")["tasks"], [])
        self.load(expect=1)
        self.assertFalse(self.state.exists())

    def test_task_selection_does_not_guess_newest(self):
        self.save("one")
        self.brief.write_text("Two is a different task.\n")
        self.save("two")
        report = self.run_cli("list")
        self.assertEqual({item["task_id"] for item in report["tasks"]}, {"one", "two"})
        self.assertIn("regression", self.load("one")["record"]["brief"])
        self.assertEqual(self.load("two")["record"]["brief"], self.brief.read_text())

    def test_history_is_unique_immutable_and_mode_private(self):
        first = self.save()
        path = Path(first["record_path"])
        original = path.read_bytes()
        second = self.save()
        self.assertNotEqual(first["record"]["record_id"], second["record"]["record_id"])
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o700)
        loaded = self.run_cli(
            "load", "--task", "task-one", "--record", first["record"]["record_id"]
        )
        self.assertEqual(loaded["record"], first["record"])

    def test_concurrent_same_and_different_tasks_keep_all_records(self):
        def one(index):
            task = "shared" if index < 5 else f"task-{index}"
            return self.save(task)

        with ThreadPoolExecutor(max_workers=8) as pool:
            saved = list(pool.map(one, range(10)))
        paths = {item["record_path"] for item in saved}
        self.assertEqual(len(paths), 10)
        self.assertTrue(all(Path(path).is_file() for path in paths))
        shared_ids = {item["record"]["record_id"] for item in saved[:5]}
        self.assertIn(self.load("shared")["record"]["record_id"], shared_ids)
        self.assertEqual(len(self.run_cli("list")["tasks"]), 6)

    def test_task_lock_uses_exclusive_creation_and_reopens_same_inode(self):
        parent = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        real_open = os.open

        def checked_open(path, flags, mode=0o777, *, dir_fd=None):
            if path == ".lock":
                self.assertTrue(flags & os.O_NOFOLLOW)
                if flags & os.O_CREAT:
                    self.assertTrue(
                        flags & os.O_EXCL,
                        "Concurrent non-exclusive creation can fail with ENOENT",
                    )
            return real_open(path, flags, mode, dir_fd=dir_fd)

        try:
            with patch.object(handoff.os, "open", side_effect=checked_open):
                with handoff.task_lock(parent):
                    inode = (self.root / ".lock").stat().st_ino
                with handoff.task_lock(parent):
                    self.assertEqual((self.root / ".lock").stat().st_ino, inode)
        finally:
            os.close(parent)

    def test_work_and_personal_same_repo_do_not_share_task_pointers(self):
        work = self.home / "Git/work/project"
        self.init_repo(work)
        self.brief = work / "brief.txt"
        self.brief.write_text("Work repo through my personal quota.\n")
        personal = self.save(repo=work, personal=True)
        self.load(repo=work, expect=1)
        self.assertEqual(self.run_cli("list", repo=work)["tasks"], [])
        self.brief.write_text("Work account's own task.\n")
        work_saved = self.save(repo=work)
        self.assertNotEqual(
            personal["record"]["account_id"], work_saved["record"]["account_id"]
        )
        self.assertEqual(
            self.load(repo=work, personal=True)["record"], personal["record"]
        )
        self.assertEqual(self.load(repo=work)["record"], work_saved["record"])

    def test_symlinked_selected_account_root_blocks_save_and_load(self):
        work = self.home / "Git/work/project"
        self.init_repo(work)
        brief = work / "brief.txt"
        brief.write_text("Synthetic personal-account-only handoff.\n")
        work_config = self.home / ".claude-work"
        work_config.mkdir()
        (self.home / ".claude").symlink_to(work_config, target_is_directory=True)

        saved = self.run_cli(
            "save",
            "--task",
            "td-a",
            "--brief-file",
            str(brief),
            repo=work,
            personal=True,
            expect=1,
        )
        self.assertIn("account root", saved["error"].lower())
        loaded = self.run_cli("load", "--task", "td-a", repo=work, expect=1)
        self.assertIn("account root", loaded["error"].lower())
        self.assertFalse(self.state.exists())

    def test_configured_personal_work_aliases_are_rejected_before_state_access(self):
        work = self.home / "Git/work/project"
        self.init_repo(work)
        brief = work / "brief.txt"
        brief.write_text("Synthetic account-alias handoff.\n")
        (self.home / ".claude").mkdir()
        tilde_alias = {**self.env, "CLAUDE_WORK_CONFIG_DIR": "~/.claude"}
        for personal in (True, False):
            result = self.run_cli(
                "save",
                "--task",
                "td-tilde",
                "--brief-file",
                str(brief),
                repo=work,
                personal=personal,
                env=tilde_alias,
                expect=1,
            )
            self.assertIn("aliases", result["error"].lower())
        self.assertFalse(self.state.exists())

        missing_alias = {
            **self.env,
            "CLAUDE_WORK_CONFIG_DIR": str(self.home / ".claude"),
        }
        (self.home / ".claude").rmdir()
        result = self.run_cli(
            "save",
            "--task",
            "td-missing",
            "--brief-file",
            str(brief),
            repo=work,
            personal=True,
            env=missing_alias,
            expect=1,
        )
        self.assertIn("aliases", result["error"].lower())
        self.assertFalse(self.state.exists())

    def test_work_scope_cannot_import_known_personal_brief(self):
        work = self.home / "Git/work/project"
        self.init_repo(work)
        self.save(repo=work, expect=1)
        self.assertFalse(self.state.exists())
        self.save(repo=work, personal=True)

    def test_work_scope_cannot_import_personal_handoff_state(self):
        personal = self.save()
        work = self.home / "Git/work/project"
        self.init_repo(work)
        self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            personal["record_path"],
            repo=work,
            expect=1,
        )

    def test_work_scope_rejects_unknown_personal_codex_legacy_source(self):
        work = self.home / "Git/work/project"
        self.init_repo(work)
        legacy = self.home / ".codex/handoffs/personal.md"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("Personal-only legacy fixture.\n")
        self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            str(legacy),
            repo=work,
            expect=1,
        )
        self.assertFalse(self.state.exists())
        self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            str(legacy),
            repo=work,
            personal=True,
        )

    def test_work_scope_rejects_personal_record_from_another_state_base(self):
        personal = self.save()
        work = self.home / "Git/work/project"
        self.init_repo(work)
        other_state = self.root / "other-state"
        env = {**self.env, "DOTFILES_HANDOFF_STATE_DIR": str(other_state)}
        self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            personal["record_path"],
            repo=work,
            env=env,
            expect=1,
        )
        self.assertFalse(other_state.exists())

    def test_work_scope_rejects_arbitrary_unknown_legacy_source(self):
        work = self.home / "Git/work/project"
        self.init_repo(work)
        legacy = self.root / "old-archive.txt"
        legacy.write_text("Unknown ownership legacy fixture.\n")
        self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            str(legacy),
            repo=work,
            expect=1,
        )
        self.assertFalse(self.state.exists())

    def test_work_scope_allows_legacy_brief_in_same_repository(self):
        work = self.home / "Git/work/project"
        self.init_repo(work)
        legacy = work / ".codex/handoffs/latest.md"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("Project-scoped legacy fixture.\n")
        saved = self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            str(legacy),
            repo=work,
        )
        self.assertEqual(saved["record"]["brief"], legacy.read_text())

    def test_work_scope_rejects_personal_record_copied_into_work_repository(self):
        personal = self.save()
        work = self.home / "Git/work/project"
        self.init_repo(work)
        copied = work / "copied-handoff.json"
        copied.write_bytes(Path(personal["record_path"]).read_bytes())
        self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            str(copied),
            repo=work,
            expect=1,
        )

    def work_record(self):
        work = self.home / "Git/work/project"
        self.init_repo(work)
        self.brief = work / "brief.txt"
        self.brief.write_text("Same-repository work history.\n")
        return work, self.save(repo=work)

    def test_matching_record_import_from_old_state_extracts_brief(self):
        work, previous = self.work_record()
        source = Path(previous["record_path"])
        original = source.read_bytes()
        env = {**self.env, "DOTFILES_HANDOFF_STATE_DIR": str(self.root / "new-state")}
        saved = self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            str(source),
            repo=work,
            env=env,
        )
        self.assertEqual(saved["record"]["brief"], previous["record"]["brief"])
        self.assertEqual(source.read_bytes(), original)

    def test_personal_scope_may_import_work_record(self):
        work, previous = self.work_record()
        saved = self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            previous["record_path"],
            repo=work,
            personal=True,
        )
        self.assertEqual(saved["record"]["brief"], previous["record"]["brief"])
        self.assertEqual(saved["scope"]["kind"], "personal")

    def test_work_record_from_another_repo_is_rejected(self):
        _, previous = self.work_record()
        other = self.home / "Git/work/other-project"
        self.init_repo(other)
        self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            previous["record_path"],
            repo=other,
            expect=1,
        )

    def test_import_rejects_invalid_digest_and_missing_record_identity(self):
        work, previous = self.work_record()
        copied = work / "record.json"
        for changes in ({"brief": "changed"}, {"record_id": None}):
            with self.subTest(changes=changes):
                copied.write_text(json.dumps({**previous["record"], **changes}))
                self.run_cli(
                    "save",
                    "--task",
                    "import",
                    "--brief-file",
                    str(copied),
                    repo=work,
                    expect=1,
                )

    def test_personal_record_import_rejects_missing_repository_identity(self):
        work, previous = self.work_record()
        copied = work / "record.json"
        copied.write_text(json.dumps({**previous["record"], "repository": {}}))
        self.run_cli(
            "save",
            "--task",
            "import",
            "--brief-file",
            str(copied),
            repo=work,
            personal=True,
            expect=1,
        )

    def test_plain_brief_from_same_work_repo_linked_checkout_is_allowed(self):
        work, _ = self.work_record()
        linked = self.root / "linked work checkout"
        self.git("worktree", "add", "-q", "-b", "linked", str(linked), repo=work)
        self.save(task="linked", repo=linked)
        self.assertEqual(
            self.load("linked", repo=work)["record"]["brief"], self.brief.read_text()
        )

    def test_verify_detects_tracked_worktree_changes_without_head_change(self):
        tracked = self.repo / "tracked.txt"
        tracked.write_text("before\n")
        self.git("add", "tracked.txt")
        self.git("commit", "-qm", "tracked fixture")
        self.save()
        tracked.write_text("after\n")
        report = self.run_cli("verify", "--task", "task-one")
        self.assertIn("working-tree", report["drift"])

    def test_personal_repo_overrides_inherited_work_scope(self):
        inherited = {**self.env, "CLAUDE_CONFIG_DIR": str(self.home / ".claude-work")}
        result = self.save(runtime="claude", env=inherited)
        self.assertEqual(result["scope"]["kind"], "personal")
        self.assertIsNone(result["scope"]["launch_env"]["CLAUDE_CONFIG_DIR"])
        self.assertEqual(
            result["scope"]["launch_env"]["WORKFLOW_PERSONAL_ACCOUNT"], "1"
        )

    def test_linked_worktree_finds_same_task_and_reports_location_drift(self):
        self.save()
        linked = self.root / "linked worktree"
        self.git("worktree", "add", "-q", "-b", "linked", str(linked))
        loaded = self.load(repo=linked)
        self.assertEqual(loaded["record"]["repository"]["root"], str(self.repo))
        verified = self.run_cli("verify", "--task", "task-one", repo=linked)
        self.assertIn("worktree", verified["drift"])

    def test_separate_metadata_primary_and_linked_share_repository_id(self):
        repo = self.home / "Git/personal/separate"
        self.init_repo(repo, self.root / "separate.git")
        self.brief = repo / "brief.txt"
        self.brief.write_text("Separate metadata task.\n")
        saved = self.save(repo=repo)
        linked = self.root / "separate linked"
        self.git("worktree", "add", "-q", "-b", "other", str(linked), repo=repo)
        self.assertEqual(
            self.load(repo=linked, personal=True)["record"], saved["record"]
        )
        self.load(repo=linked, expect=1)

    def test_verify_reports_git_and_explicit_owner_drift(self):
        self.run_cli(
            "save",
            "--task",
            "task-one",
            "--brief-file",
            str(self.brief),
            "--owner-id",
            "owner-1",
        )
        self.git("commit", "--allow-empty", "-qm", "advance")
        report = self.run_cli("verify", "--task", "task-one", "--owner-id", "owner-2")
        self.assertIn("head", report["drift"])
        self.assertEqual(report["owner_status"], "changed")
        self.assertEqual(
            self.run_cli("verify", "--task", "task-one")["owner_status"], "unverified"
        )

    def test_explicit_base_is_resolved_without_fetch(self):
        base = self.git("rev-parse", "HEAD")
        self.git("commit", "--allow-empty", "-qm", "advance")
        saved = self.run_cli(
            "save",
            "--task",
            "task-one",
            "--brief-file",
            str(self.brief),
            "--base",
            base,
        )
        self.assertEqual(saved["record"]["base_sha"], base)
        self.assertNotEqual(
            saved["record"]["base_sha"], saved["record"]["repository"]["head"]
        )

    def test_explicit_legacy_import_leaves_source_unchanged(self):
        legacy = self.repo / ".claude/handoffs/latest.md"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("Legacy intent, imported only when explicitly selected.\n")
        before = legacy.read_bytes()
        self.run_cli("save", "--task", "legacy", "--brief-file", str(legacy))
        self.assertEqual(legacy.read_bytes(), before)
        self.assertEqual(self.load("legacy")["record"]["brief"], before.decode())

    def test_partial_pointer_and_record_are_errors_not_fallback(self):
        saved = self.save()
        path = Path(saved["record_path"])
        pointer = path.parent / "current.json"
        original = pointer.read_bytes()
        pointer.write_text("{")
        self.load(expect=1)
        pointer.write_bytes(original)
        path.write_text("{")
        self.load(expect=1)

    def test_changed_record_hash_is_rejected(self):
        saved = self.save()
        path = Path(saved["record_path"])
        record = json.loads(path.read_text())
        record["brief"] = "unexpected replacement"
        path.write_text(json.dumps(record))
        self.load(expect=1)

    def test_cross_task_record_pointer_is_rejected_even_with_valid_hash(self):
        first = self.save("one")
        second = self.save("two")
        record_path = Path(second["record_path"])
        pointer_path = Path(first["record_path"]).parent / "current.json"
        pointer = json.loads(pointer_path.read_text())
        pointer["record_id"] = second["record"]["record_id"]
        pointer["record_sha256"] = hashlib.sha256(record_path.read_bytes()).hexdigest()
        pointer_path.write_text(json.dumps(pointer))
        target = pointer_path.parent / record_path.name
        target.write_bytes(record_path.read_bytes())
        self.load("one", expect=1)

    def test_symlink_state_parent_and_record_escape_are_rejected(self):
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        self.state.symlink_to(elsewhere, target_is_directory=True)
        self.save(expect=1)
        self.assertEqual(list(elsewhere.iterdir()), [])
        self.state.unlink()
        saved = self.save()
        path = Path(saved["record_path"])
        external = elsewhere / "record.json"
        path.rename(external)
        path.symlink_to(external)
        self.load(expect=1)

    def test_symlink_task_lock_and_pointer_are_rejected(self):
        saved = self.save()
        directory = Path(saved["record_path"]).parent
        for name in (".lock", "current.json"):
            path = directory / name
            before = path.read_bytes()
            target = self.root / f"target-{name}"
            target.write_bytes(before)
            path.unlink()
            path.symlink_to(target)
            self.save(expect=1)
            self.assertEqual(target.read_bytes(), before)
            path.unlink()
            path.write_bytes(before)

    def test_state_inside_repository_is_rejected(self):
        env = {**self.env, "DOTFILES_HANDOFF_STATE_DIR": str(self.repo / "state")}
        self.save(env=env, expect=1)
        self.assertFalse((self.repo / "state").exists())

    def test_native_var_state_alias_uses_the_same_private_state_directory(self):
        private_prefix = "/private/var/"
        state = str(self.state)
        if not state.startswith(private_prefix):
            self.skipTest("native macOS /var alias is unavailable in this fixture")
        alias = lambda path: Path("/var/" + str(path).removeprefix(private_prefix))
        env = {
            **self.env,
            "HOME": str(alias(self.home)),
            "DOTFILES_HANDOFF_STATE_DIR": str(alias(self.state)),
        }
        repo = alias(self.repo)
        brief = alias(self.brief)
        saved = self.run_cli(
            "save",
            "--task",
            "task-one",
            "--brief-file",
            str(brief),
            repo=repo,
            env=env,
        )
        self.assertTrue(Path(saved["record_path"]).is_file())
        verified = self.run_cli("verify", "--task", "task-one", repo=repo, env=env)
        self.assertEqual(verified["git_status"], "unchanged")
        self.assertEqual(
            self.run_cli("load", "--task", "task-one", repo=repo, env=env)["record"],
            saved["record"],
        )

    def test_relative_native_alias_state_roots_are_rejected_without_creation(self):
        context = {
            "root": str(self.repo),
            "primary_root": None,
            "common_dir": "",
            "repo_id": "b" * 64,
        }
        scope = {"account_id": "a" * 64}
        relative_parent = Path.cwd() / self.root.name
        for name in (f"{self.root.name}/var/handoff", f"{self.root.name}/tmp/handoff"):
            env = {**self.env, "DOTFILES_HANDOFF_STATE_DIR": name}
            with (
                patch.dict(os.environ, env, clear=True),
                self.assertRaisesRegex(ValueError, "absolute"),
            ):
                handoff.state_directory(context, scope)
            self.assertFalse(relative_parent.exists())

    def test_parent_traversal_task_is_rejected(self):
        self.save("../escape", expect=1)
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
