"""Focused behavioral tests for shared workflow context."""

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "workflow_context", HERE / "workflow_context.py"
)
workflow_context = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(workflow_context)


class WorkflowContextTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.git_env = {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
        }

    def tearDown(self):
        for path in sorted(self.tmp.rglob("*"), reverse=True):
            if path.is_symlink() or path.is_file():
                path.unlink()
            elif path.is_dir():
                path.rmdir()
        self.tmp.rmdir()

    def run_git(self, *args, cwd=None):
        return subprocess.run(
            ["git", *args],
            cwd=cwd,
            env={**os.environ, **self.git_env},
            check=True,
            capture_output=True,
            text=True,
        )

    def repository(self, path, *, metadata=None):
        path.parent.mkdir(parents=True, exist_ok=True)
        args = ["init", "-q"]
        if metadata is not None:
            args.extend(["--separate-git-dir", str(metadata)])
        args.append(str(path))
        self.run_git(*args)
        self.run_git("-C", str(path), "commit", "--allow-empty", "-q", "-m", "fixture")
        return path

    def account_env(self, **overrides):
        account_variables = {
            "HOME",
            "CLAUDE_PERSONAL_ONLY",
            "WORKFLOW_PERSONAL_ACCOUNT",
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_WORK_TREE",
            "CLAUDE_WORK_CONFIG_DIR",
            "CODEX_HOME",
        }
        environment = {
            key: value
            for key, value in os.environ.items()
            if key not in account_variables
        }
        environment.update({"HOME": str(self.home), **overrides})
        return mock.patch.dict(os.environ, environment, clear=True)

    def test_linked_worktree_has_its_owner_repository_id(self):
        owner = self.repository(self.tmp / "owner repository")
        linked = self.tmp / "linked worktree"
        self.run_git(
            "-C", str(owner), "worktree", "add", "-q", "-b", "linked", str(linked)
        )

        main = workflow_context.repository_context(owner)
        child = workflow_context.repository_context(linked)

        self.assertEqual(main["repo_id"], child["repo_id"])
        self.assertEqual(main["primary_root"], str(owner))
        self.assertEqual(child["primary_root"], str(owner))
        self.assertEqual(main["root"], str(owner))
        self.assertEqual(child["root"], str(linked))
        self.assertNotEqual(main["common_dir"], child["root"])

    def test_separate_metadata_never_becomes_checkout_root(self):
        checkout = self.tmp / "checkout"
        metadata = self.tmp / "metadata" / "owner.git"
        metadata.parent.mkdir()
        self.repository(checkout, metadata=metadata)

        context = workflow_context.repository_context(checkout)

        self.assertEqual(context["root"], str(checkout))
        self.assertEqual(context["primary_root"], str(checkout))
        self.assertEqual(context["common_dir"], str(metadata))
        self.assertNotEqual(context["root"], str(metadata.parent))

    def test_unborn_repository_still_has_account_context(self):
        checkout = self.tmp / "unborn repository"
        checkout.mkdir()
        self.run_git("init", "-q", str(checkout))

        context = workflow_context.repository_context(checkout)

        self.assertEqual(context["root"], str(checkout))
        self.assertEqual(context["head"], "")

    def test_separate_metadata_linked_worktree_uses_common_identity_and_fails_closed(
        self,
    ):
        metadata = self.home / "metadata" / "owner.git"
        metadata.parent.mkdir(parents=True)
        owner = self.repository(
            self.home / "Git" / "personal" / "project", metadata=metadata
        )
        linked = self.tmp / "external linked worktree"
        self.run_git(
            "-C", str(owner), "worktree", "add", "-q", "-b", "linked", str(linked)
        )

        owner_context = workflow_context.repository_context(owner)
        linked_context = workflow_context.repository_context(linked)

        self.assertEqual(owner_context["repo_id"], linked_context["repo_id"])
        self.assertTrue(owner_context["primary_known"])
        self.assertFalse(linked_context["primary_known"])
        self.assertIsNone(linked_context["primary_root"])
        with self.account_env(CLAUDE_CONFIG_DIR=str(self.home / ".claude-work")):
            with self.assertRaises(ValueError):
                workflow_context.account_scope(linked, "claude")
            forced = workflow_context.account_scope(linked, "claude", personal=True)
        self.assertEqual(forced["kind"], "personal")
        self.assertIsNone(forced["launch_env"]["CLAUDE_CONFIG_DIR"])

    def test_git_location_environment_cannot_retarget_a_probe(self):
        repo = self.repository(self.tmp / "safe repository")
        baseline = workflow_context.repository_context(repo)
        with mock.patch.dict(
            os.environ,
            {
                "GIT_DIR": str(self.tmp / "attacker.git"),
                "GIT_WORK_TREE": str(self.tmp / "attacker-tree"),
                "GIT_INDEX_FILE": str(self.tmp / "attacker.index"),
            },
        ):
            observed = workflow_context.repository_context(repo)

        self.assertEqual(observed, baseline)

    def test_personal_owner_overrides_inherited_work_scope(self):
        owner = self.repository(self.home / "Git" / "personal" / "project")
        linked = self.tmp / "external linked worktree"
        self.run_git(
            "-C", str(owner), "worktree", "add", "-q", "-b", "linked", str(linked)
        )

        with self.account_env(CLAUDE_CONFIG_DIR=str(self.home / ".claude-work")):
            scope = workflow_context.account_scope(linked, "claude")

        self.assertEqual(scope["kind"], "personal")
        self.assertEqual(scope["root"], str(self.home / ".claude"))
        self.assertIsNone(scope["launch_env"]["CLAUDE_CONFIG_DIR"])

    def test_repository_context_rejects_malformed_head_identity(self):
        repo = self.repository(self.tmp / "repo")
        real_git = workflow_context.git
        for invalid in ("not-a-sha", "a" * 40 + "\nextra", ""):
            with self.subTest(head=invalid):

                def malformed(cwd, *args, invalid=invalid):
                    if args == ("rev-parse", "--verify", "HEAD"):
                        return invalid
                    return real_git(cwd, *args)

                with (
                    mock.patch.object(workflow_context, "git", side_effect=malformed),
                    self.assertRaisesRegex(ValueError, "Git HEAD"),
                ):
                    workflow_context.repository_context(repo)

    def test_personal_path_checks_require_a_directory_boundary(self):
        work = self.repository(self.home / "Git" / "personal-other" / "project")

        with self.account_env(CLAUDE_CONFIG_DIR=str(self.home / ".claude-work")):
            scope = workflow_context.account_scope(work, "claude")

        self.assertEqual(scope["kind"], "work")
        self.assertEqual(scope["root"], str(self.home / ".claude-work"))

    def test_deliberate_personal_scope_in_work_repository_stays_native(self):
        work = self.repository(self.home / "Git" / "work" / "project")
        with self.account_env(CLAUDE_CONFIG_DIR=str(self.home / ".claude")):
            scope = workflow_context.account_scope(work, "claude")

        self.assertEqual(scope["kind"], "personal")
        self.assertIsNone(scope["launch_env"]["CLAUDE_CONFIG_DIR"])

    def test_custom_work_scope_preserves_explicit_config(self):
        work = self.repository(self.home / "Git" / "work" / "project")
        custom = self.home / "custom-claude"
        with self.account_env(CLAUDE_CONFIG_DIR=str(custom)):
            scope = workflow_context.account_scope(work, "claude")

        self.assertEqual(scope["kind"], "custom")
        self.assertEqual(scope["root"], str(custom))
        self.assertEqual(scope["launch_env"]["CLAUDE_CONFIG_DIR"], str(custom))

    def test_codex_scope_has_a_distinct_stable_identity(self):
        repo = self.repository(self.tmp / "repo")
        with self.account_env():
            scope = workflow_context.account_scope(repo, "codex")
            claude_scope = workflow_context.account_scope(repo, "claude")

        self.assertEqual(scope["runtime"], "codex")
        self.assertEqual(scope["kind"], "personal")
        self.assertEqual(scope["root"], str(self.home / ".codex"))
        self.assertEqual(len(scope["scope_id"]), 64)
        self.assertEqual(scope["account_root"], str(self.home / ".claude"))
        self.assertEqual(scope["account_id"], claude_scope["account_id"])

    def test_codex_scope_preserves_explicit_home_and_shared_account_id(self):
        repo = self.repository(self.tmp / "repo")
        codex_home = self.home / "codex-session"
        custom_claude = self.home / "custom-claude"
        with self.account_env(
            CODEX_HOME=str(codex_home), CLAUDE_CONFIG_DIR=str(custom_claude)
        ):
            scope = workflow_context.account_scope(repo, "codex")
            claude_scope = workflow_context.account_scope(repo, "claude")

        self.assertEqual(scope["kind"], "custom")
        self.assertEqual(scope["root"], str(codex_home))
        self.assertEqual(scope["launch_env"]["CODEX_HOME"], str(codex_home))
        self.assertEqual(scope["account_id"], claude_scope["account_id"])

    def test_codex_reused_pane_reproduces_selected_account_and_home(self):
        work = self.repository(self.home / "Git" / "work" / "project")
        cases = (
            ({}, False),
            ({}, True),
            ({"CLAUDE_CONFIG_DIR": str(self.home / ".claude")}, False),
            (
                {
                    "CLAUDE_CONFIG_DIR": str(self.home / "custom-account"),
                    "CODEX_HOME": str(self.home / "selected-codex"),
                },
                False,
            ),
        )
        for selected, personal in cases:
            with self.subTest(selected=selected, personal=personal):
                with self.account_env(**selected):
                    expected = workflow_context.account_scope(work, "codex", personal)
                    pane = dict(os.environ)
                pane.update(
                    {
                        "CODEX_HOME": str(self.home / "foreign-codex"),
                        "CLAUDE_CONFIG_DIR": str(self.home / "foreign-account"),
                        "CLAUDE_PERSONAL_ONLY": "1",
                    }
                )
                for key, value in expected["launch_env"].items():
                    if value is None:
                        pane.pop(key, None)
                    else:
                        pane[key] = value
                with mock.patch.dict(os.environ, pane, clear=True):
                    observed = workflow_context.account_scope(work, "codex")
                self.assertEqual(observed["root"], expected["root"])
                self.assertEqual(observed["account_id"], expected["account_id"])
                self.assertEqual(
                    observed["personal_repository"], expected["personal_repository"]
                )
                if expected["kind"] == "personal":
                    self.assertNotIn("CLAUDE_CONFIG_DIR", pane)

    def test_personal_quota_preserves_repository_plugin_policy(self):
        work = self.repository(self.home / "Git" / "work" / "project")
        owner = self.repository(self.home / "Git" / "personal" / "project")
        linked = self.tmp / "linked-personal"
        self.run_git("-C", str(owner), "worktree", "add", "--detach", str(linked))
        for repo, is_personal in ((work, False), (linked, True)):
            for selected in ({}, {"CLAUDE_CONFIG_DIR": str(self.home / ".claude")}):
                with self.subTest(repo=repo, selected=selected):
                    with self.account_env(**selected):
                        scope = workflow_context.account_scope(
                            repo, "codex", personal=True
                        )
                    self.assertEqual(scope["kind"], "personal")
                    self.assertEqual(scope["personal_repository"], is_personal)
                    self.assertIsNone(scope["launch_env"]["CLAUDE_PERSONAL_ONLY"])

    def test_work_claude_clears_previous_personal_codex_selection(self):
        work = self.repository(self.home / "Git" / "work" / "project")
        with self.account_env():
            personal = workflow_context.account_scope(work, "codex", personal=True)
            selected = workflow_context.account_scope(work, "claude")
            pane = dict(os.environ)
        for scope in (personal, selected):
            for key, value in scope["launch_env"].items():
                if value is None:
                    pane.pop(key, None)
                else:
                    pane[key] = value
        with mock.patch.dict(os.environ, pane, clear=True):
            observed = workflow_context.account_scope(work, "claude")
        self.assertEqual(observed["account_id"], selected["account_id"])
        self.assertEqual(observed["kind"], "work")

    def test_atomic_json_exclusive_publishes_unique_task_records(self):
        target = self.tmp / "state" / "task-a.json"
        sibling = target.with_name("task-b.json")

        workflow_context.atomic_json(target, {"task": "a"}, exclusive=True)
        workflow_context.atomic_json(sibling, {"task": "b"}, exclusive=True)

        with self.assertRaises(FileExistsError):
            workflow_context.atomic_json(target, {"task": "new"}, exclusive=True)
        self.assertEqual(json.loads(target.read_text()), {"task": "a"})
        self.assertEqual(json.loads(sibling.read_text()), {"task": "b"})

    def test_atomic_json_rejects_symlink_paths(self):
        real = self.tmp / "real"
        real.mkdir()
        linked = self.tmp / "linked"
        linked.symlink_to(real, target_is_directory=True)

        with self.assertRaises(ValueError):
            workflow_context.atomic_json(linked / "state.json", {"safe": True})

    def test_open_state_parent_does_not_create_missing_directories(self):
        target = self.tmp / "missing" / "state.json"

        with self.assertRaises(FileNotFoundError):
            workflow_context.open_state_parent(target)

        self.assertFalse(target.parent.exists())

    def test_open_state_parent_rejects_symlinked_directories(self):
        real = self.tmp / "real"
        linked = self.tmp / "linked"
        real.mkdir()
        linked.symlink_to(real, target_is_directory=True)

        with self.assertRaises(ValueError):
            workflow_context.open_state_parent(linked / "state.json")

    def test_atomic_json_confines_parent_directory_swap_after_open(self):
        state = self.tmp / "state"
        outside = self.tmp / "outside"
        parked = self.tmp / "parked-state"
        state.mkdir()
        outside.mkdir()
        original = workflow_context.open_state_parent
        swapped = False

        def swap_after_open(path, create=False):
            nonlocal swapped
            descriptor, name = original(path, create=create)
            state.rename(parked)
            state.symlink_to(outside, target_is_directory=True)
            swapped = True
            return descriptor, name

        with mock.patch.object(
            workflow_context, "open_state_parent", side_effect=swap_after_open
        ):
            workflow_context.atomic_json(state / "state.json", {"safe": True})

        self.assertTrue(swapped)
        self.assertFalse((outside / "state.json").exists())
        self.assertEqual(
            json.loads((parked / "state.json").read_text()), {"safe": True}
        )

    def test_atomic_json_at_keeps_publication_in_held_directory(self):
        state = self.tmp / "state"
        outside = self.tmp / "outside"
        parked = self.tmp / "parked-state"
        state.mkdir()
        outside.mkdir()
        descriptor, name = workflow_context.open_state_parent(state / "state.json")
        try:
            state.rename(parked)
            state.symlink_to(outside, target_is_directory=True)
            workflow_context.atomic_json_at(descriptor, name, {"safe": True})
        finally:
            os.close(descriptor)

        self.assertFalse((outside / "state.json").exists())
        self.assertEqual(
            json.loads((parked / "state.json").read_text()), {"safe": True}
        )

    def test_atomic_json_at_rejects_non_basenames(self):
        parent = self.tmp / "state"
        parent.mkdir()
        descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for name in ("", ".", "..", "nested/state.json"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    workflow_context.atomic_json_at(descriptor, name, {"safe": True})
        finally:
            os.close(descriptor)

    def test_atomic_json_keeps_concurrent_publications_parseable(self):
        target = self.tmp / "state" / "task.json"

        def write(number):
            workflow_context.atomic_json(
                target, {"writer": number, "items": [number] * 100}
            )

        with ThreadPoolExecutor(max_workers=8) as executor:
            list(executor.map(write, range(32)))

        result = json.loads(target.read_text())
        self.assertIn(result["writer"], range(32))
        self.assertEqual(result["items"], [result["writer"]] * 100)


if __name__ == "__main__":
    unittest.main()
