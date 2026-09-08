"""Behavioral tests for frozen co-review snapshots and document artifacts."""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "review.py"
DOTFILES_ROOT = SCRIPT.parents[4]


class ReviewHelperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.repo = self.root / "repo with spaces"
        self.repo.mkdir()
        self.run_git("init", "-q")
        self.run_git("config", "user.name", "Fixture")
        self.run_git("config", "user.email", "fixture@example.invalid")
        (self.repo / "tracked.txt").write_text("base\n")
        (self.repo / ".gitignore").write_text("ignored.tmp\n")
        self.run_git("add", "tracked.txt", ".gitignore")
        self.run_git("commit", "-qm", "fixture: Base")
        self.base = self.git("rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_git(self, *args: str) -> None:
        subprocess.run(
            ["git", "-C", str(self.repo), *args],
            check=True,
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "HOME": str(self.home),
                "GIT_CONFIG_NOSYSTEM": "1",
            },
        )

    def git(self, *args: str, cwd: Path | None = None) -> str:
        result = subprocess.run(
            ["git", "-C", str(cwd or self.repo), *args],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def command(
        self,
        *args: str,
        expect: int = 0,
        extra_env: dict[str, str] | None = None,
        cwd: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            capture_output=True,
            text=True,
            env={
                **os.environ,
                "HOME": str(self.home),
                "GIT_CONFIG_NOSYSTEM": "1",
                **(extra_env or {}),
            },
            check=False,
            cwd=cwd,
        )
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return result

    def prepare(
        self, *extra: str, extra_env: dict[str, str] | None = None
    ) -> tuple[Path, dict]:
        output = self.root / "review output"
        result = self.command(
            "prepare",
            "--repo",
            str(self.repo),
            "--base",
            self.base,
            "--output-dir",
            str(output),
            *extra,
            extra_env=extra_env,
        )
        manifest = Path(json.loads(result.stdout)["manifest"])
        return manifest, json.loads(manifest.read_text())

    def test_freezes_staged_unstaged_and_selected_untracked_without_mutating_source(
        self,
    ) -> None:
        (self.repo / "tracked.txt").write_text("unstaged\n")
        (self.repo / "staged.txt").write_text("staged\n")
        self.run_git("add", "staged.txt")
        included = self.repo / "untracked file.txt"
        included.write_text("included\n")
        (self.repo / "excluded.txt").write_text("excluded\n")
        index_before = self.git("write-tree")

        manifest_path, manifest = self.prepare(
            "--include-untracked", "untracked file.txt"
        )

        self.assertEqual(index_before, self.git("write-tree"))
        self.assertEqual(self.base, self.git("rev-parse", "HEAD"))
        self.assertEqual(manifest["source"]["base"], self.base)
        self.assertEqual(
            manifest["snapshot"]["codex_tree"], manifest["snapshot"]["claude_tree"]
        )
        self.assertIn("excluded.txt", manifest["exclusions"]["untracked_not_selected"])
        self.assertEqual(manifest["ownership"]["nonce"].__class__, str)
        self.assertTrue(manifest["ownership"]["nonce"])
        codex_root = Path(manifest["snapshot"]["codex_root"])
        claude_root = Path(manifest["snapshot"]["claude_root"])
        self.assertEqual(
            self.git("show", "HEAD:tracked.txt", cwd=codex_root), "unstaged"
        )
        self.assertEqual(self.git("show", "HEAD:staged.txt", cwd=codex_root), "staged")
        self.assertEqual(
            self.git("show", "HEAD:untracked file.txt", cwd=codex_root), "included"
        )
        self.assertFalse((codex_root / "excluded.txt").exists())
        self.assertEqual(
            self.git("write-tree", cwd=claude_root), manifest["snapshot"]["claude_tree"]
        )
        self.command("verify", "--manifest", str(manifest_path))

    def test_ignores_inherited_git_index_file(self) -> None:
        inherited_index = self.root / "inherited.index"
        shutil.copyfile(self.repo / ".git" / "index", inherited_index)
        original_before = (self.repo / ".git" / "index").read_bytes()
        alternate_before = inherited_index.read_bytes()

        self.prepare(
            extra_env={
                "GIT_INDEX_FILE": str(inherited_index),
                "GIT_DIR": str(self.root / "foreign-git-dir"),
                "GIT_WORK_TREE": str(self.root / "foreign-worktree"),
            }
        )

        self.assertEqual((self.repo / ".git" / "index").read_bytes(), original_before)
        self.assertEqual(inherited_index.read_bytes(), alternate_before)

    def test_literal_untracked_path_never_expands_to_private_siblings(self) -> None:
        (self.repo / "*").write_text("literal\n")
        (self.repo / ":(top)literal.txt").write_text("pathspec magic\n")
        (self.repo / ".env").write_text("private\n")

        _, manifest = self.prepare(
            "--include-untracked",
            "*",
            "--include-untracked",
            ":(top)literal.txt",
        )
        codex_root = Path(manifest["snapshot"]["codex_root"])

        self.assertEqual(self.git("show", "HEAD:*", cwd=codex_root), "literal")
        self.assertEqual(
            (codex_root / ":(top)literal.txt").read_text(), "pathspec magic\n"
        )
        self.assertFalse((codex_root / ".env").exists())
        self.assertIn(".env", manifest["exclusions"]["untracked_not_selected"])

    def test_source_edit_during_capture_fails_closed(self) -> None:
        (self.repo / "tracked.txt").write_text("first change\n")
        stub_dir = self.root / "git stub"
        stub_dir.mkdir()
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        (stub_dir / "git").write_text(
            "#!/bin/sh\n"
            "count_file=$REVIEW_GIT_COUNT\n"
            'count=$(cat "$count_file" 2>/dev/null || printf 0)\n'
            "count=$((count + 1))\n"
            'printf \'%s\\n\' "$count" > "$count_file"\n'
            f'{real_git} "$@"\n'
            "status=$?\n"
            'if [ "$count" -eq 8 ]; then printf \'second change\\n\' > "$REVIEW_EDIT_PATH"; fi\n'
            'exit "$status"\n'
        )
        (stub_dir / "git").chmod(0o755)

        self.command(
            "prepare",
            "--repo",
            str(self.repo),
            "--base",
            self.base,
            "--output-dir",
            str(self.root / "concurrent output"),
            expect=2,
            extra_env={
                "PATH": f"{stub_dir}:{os.environ['PATH']}",
                "REVIEW_GIT_COUNT": str(self.root / "git-count"),
                "REVIEW_EDIT_PATH": str(self.repo / "tracked.txt"),
            },
        )
        self.assertEqual((self.repo / "tracked.txt").read_text(), "second change\n")

    def test_snapshot_creation_does_not_run_checkout_hydration_hooks(self) -> None:
        hooks = self.root / "hydration hooks"
        hooks.mkdir()
        hook = hooks / "post-checkout"
        hook.write_text("#!/bin/sh\nln -s /tmp .todos\n")
        hook.chmod(0o755)
        self.run_git("config", "core.hooksPath", str(hooks))

        manifest_path, manifest = self.prepare()

        self.assertFalse((Path(manifest["snapshot"]["codex_root"]) / ".todos").exists())
        self.assertFalse(
            (Path(manifest["snapshot"]["claude_root"]) / ".todos").exists()
        )
        self.command("verify", "--manifest", str(manifest_path))
        self.command("cleanup", "--manifest", str(manifest_path))

    def test_rejects_private_symlink_and_uninspected_untracked_inputs(self) -> None:
        (self.repo / ".env").write_text("private\n")
        self.command(
            "prepare",
            "--repo",
            str(self.repo),
            "--base",
            self.base,
            "--output-dir",
            str(self.root / "private"),
            "--include-untracked",
            ".env",
            expect=2,
        )
        target = self.root / "outside.txt"
        target.write_text("outside\n")
        (self.repo / "linked.txt").symlink_to(target)
        self.command(
            "prepare",
            "--repo",
            str(self.repo),
            "--base",
            self.base,
            "--output-dir",
            str(self.root / "linked"),
            "--include-untracked",
            "linked.txt",
            expect=2,
        )
        self.command(
            "prepare",
            "--repo",
            str(self.repo),
            "--base",
            self.base,
            "--output-dir",
            str(self.root / "missing"),
            "--include-untracked",
            "not-present.txt",
            expect=2,
        )

    def test_committed_head_and_wrong_manifest_root_are_checked(self) -> None:
        (self.repo / "committed.txt").write_text("fix\n")
        self.run_git("add", "committed.txt")
        self.run_git("commit", "-qm", "fixture: Fix")
        manifest_path, manifest = self.prepare()
        self.assertEqual(manifest["source"]["head"], self.git("rev-parse", "HEAD"))
        manifest["snapshot"]["codex_root"] = str(self.root / "foreign")
        manifest_path.write_text(json.dumps(manifest))
        self.command("verify", "--manifest", str(manifest_path), expect=2)

    def test_cleanup_refuses_modified_or_foreign_snapshots(self) -> None:
        manifest_path, manifest = self.prepare()
        codex_root = Path(manifest["snapshot"]["codex_root"])
        (codex_root / "tracked.txt").write_text("unexpected\n")
        self.command("cleanup", "--manifest", str(manifest_path), expect=2)
        self.assertTrue(codex_root.exists())

        (codex_root / "tracked.txt").write_text("base\n")
        manifest["snapshot"]["claude_root"] = str(self.root / "foreign")
        manifest_path.write_text(json.dumps(manifest))
        self.command("cleanup", "--manifest", str(manifest_path), expect=2)

    def test_cleanup_removes_only_a_verified_owned_snapshot(self) -> None:
        manifest_path, manifest = self.prepare()
        output = manifest_path.parent
        codex_root = Path(manifest["snapshot"]["codex_root"])
        claude_root = Path(manifest["snapshot"]["claude_root"])

        self.command("cleanup", "--manifest", str(manifest_path))

        self.assertFalse(codex_root.exists())
        self.assertFalse(claude_root.exists())
        self.assertFalse(output.exists())

    def test_cleanup_refuses_unexpected_owned_output(self) -> None:
        manifest_path, _ = self.prepare()
        unexpected = manifest_path.parent / "unexpected.txt"
        unexpected.write_text("keep\n")

        self.command("cleanup", "--manifest", str(manifest_path), expect=2)

        self.assertTrue(unexpected.exists())

    def test_cleanup_refuses_ignored_snapshot_files(self) -> None:
        for snapshot_key in ("codex_root", "claude_root"):
            output = self.root / f"ignored-{snapshot_key}"
            result = self.command(
                "prepare",
                "--repo",
                str(self.repo),
                "--base",
                self.base,
                "--output-dir",
                str(output),
            )
            manifest_path = Path(json.loads(result.stdout)["manifest"])
            manifest = json.loads(manifest_path.read_text())
            ignored = Path(manifest["snapshot"][snapshot_key]) / "ignored.tmp"
            ignored.write_text("do not delete\n")

            self.command("cleanup", "--manifest", str(manifest_path), expect=2)

            self.assertTrue(ignored.exists())

    def test_artifact_requires_explicit_repo_scoped_target_and_freezes_content(
        self,
    ) -> None:
        plan = self.repo / "docs/superpowers/plans/feature plan.md"
        plan.parent.mkdir(parents=True)
        plan.write_text("# plan\n")
        result = self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/feature plan.md",
            "--task-id",
            "TASK_1",
            "--runtime",
            "claude",
        )
        artifact = json.loads(result.stdout)
        frozen = Path(artifact["path"])
        self.assertTrue(frozen.is_absolute())
        self.assertTrue(frozen.is_file())
        self.assertEqual(frozen.read_text(), "# plan\n")
        self.assertRegex(artifact["sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(artifact["task"]["task_id"], "TASK_1")
        self.assertEqual(artifact["task"]["repo_id"], artifact["source"]["repo_id"])
        self.assertRegex(artifact["task"]["account_id"], r"^[0-9a-f]{64}$")
        selected_task_root = frozen.parent.parent
        self.assertEqual(selected_task_root.name, "TASK_1")
        self.assertEqual(selected_task_root.parent.name, "artifacts")
        self.assertEqual(selected_task_root.parents[2].name, "herdr-orch")
        explicit_output = selected_task_root / "launch with spaces"
        explicit = self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/feature plan.md",
            "--task-id",
            "TASK_1",
            "--runtime",
            "claude",
            "--output-dir",
            str(explicit_output),
        )
        self.assertTrue(Path(json.loads(explicit.stdout)["path"]).is_file())
        foreign = self.root / "foreign output"
        foreign.mkdir()
        linked_output = selected_task_root / "linked launch"
        linked_output.symlink_to(foreign, target_is_directory=True)
        self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/feature plan.md",
            "--task-id",
            "TASK_1",
            "--runtime",
            "claude",
            "--output-dir",
            str(linked_output),
            expect=2,
        )
        self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/feature plan.md",
            "--task-id",
            "TASK_1",
            "--runtime",
            "claude",
            extra_env={"CLAUDE_CONFIG_DIR": str(self.repo / "private-runtime")},
            expect=2,
        )

        self.assertEqual(list(foreign.iterdir()), [])
        plan.write_text("changed\n")
        self.assertEqual(frozen.read_text(), "# plan\n")
        self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/plans/not-allowed.md",
            "--task-id",
            "TASK_1",
            "--runtime",
            "claude",
            expect=2,
        )

        self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/feature plan.md",
            "--task-id",
            "TASK_1",
            "--runtime",
            "claude",
            "--output-dir",
            str(self.repo / "private artifacts"),
            expect=2,
        )
        self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/feature plan.md",
            "--task-id",
            "TASK_1",
            "--runtime",
            "claude",
            "--output-dir",
            str(self.home / ".claude-work" / "foreign artifacts"),
            expect=2,
        )
        self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "spec",
            "--path",
            "docs/superpowers/specs/missing.md",
            "--task-id",
            "TASK_1",
            "--runtime",
            "claude",
            expect=2,
        )
        self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/feature plan.md",
            "--task-id",
            "../foreign",
            "--runtime",
            "claude",
            expect=2,
        )

    def test_personal_artifacts_reject_account_root_symlink_to_work(self) -> None:
        plan = self.repo / "docs/superpowers/plans/account-boundary.md"
        plan.parent.mkdir(parents=True)
        plan.write_text("# personal plan\n")
        work_root = self.home / ".claude-work"
        work_root.mkdir()
        sentinel = work_root / "untouched.txt"
        sentinel.write_text("work state remains unchanged\n")
        (self.home / ".claude").symlink_to(work_root, target_is_directory=True)

        for runtime in ("claude", "codex"):
            with self.subTest(runtime=runtime):
                self.command(
                    "artifact",
                    "--repo",
                    str(self.repo),
                    "--kind",
                    "plan",
                    "--path",
                    "docs/superpowers/plans/account-boundary.md",
                    "--task-id",
                    "TASK_PERSONAL",
                    "--runtime",
                    runtime,
                    "--personal",
                    expect=2,
                )
        self.assertEqual(list(work_root.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_text(), "work state remains unchanged\n")

    def test_artifact_output_requires_one_launch_directory_under_task(self) -> None:
        plan = self.repo / "docs/superpowers/plans/bounded.md"
        plan.parent.mkdir(parents=True)
        plan.write_text("# bounded plan\n")
        arguments = (
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/bounded.md",
            "--task-id",
            "TASK_BOUND",
            "--runtime",
            "claude",
        )
        result = self.command(*arguments)
        task_root = Path(json.loads(result.stdout)["path"]).parent.parent

        for output in (task_root, task_root / "nested" / "launch"):
            with self.subTest(output=output):
                self.command(*arguments, "--output-dir", str(output), expect=2)
        self.assertFalse((task_root / "nested").exists())

        explicit = self.command(
            *arguments, "--output-dir", str(task_root / "one launch")
        )
        frozen = Path(json.loads(explicit.stdout)["path"])
        self.assertEqual(frozen.parent.parent, task_root)
        self.assertEqual(frozen.read_text(), "# bounded plan\n")

    def test_artifact_helper_runs_from_an_unrelated_directory_with_spaces(self) -> None:
        plan = self.repo / "docs/superpowers/plans/portable.md"
        plan.parent.mkdir(parents=True)
        plan.write_text("# portable\n")
        caller = self.root / "unrelated caller with spaces"
        caller.mkdir()

        result = self.command(
            "artifact",
            "--repo",
            str(self.repo),
            "--kind",
            "plan",
            "--path",
            "docs/superpowers/plans/portable.md",
            "--task-id",
            "TASK_2",
            "--runtime",
            "claude",
            cwd=caller,
        )

        self.assertTrue(Path(json.loads(result.stdout)["path"]).is_file())

    def test_review_skills_use_absolute_helpers_and_the_runtime_runner(self) -> None:
        claude_skills = (
            DOTFILES_ROOT / "claude/skills/co-review/SKILL.md",
            DOTFILES_ROOT / "claude/skills/codex-plan-review/SKILL.md",
            DOTFILES_ROOT / "claude/skills/codex-spec-review/SKILL.md",
        )
        codex_skills = (
            DOTFILES_ROOT / "codex/skills/co-review/SKILL.md",
            DOTFILES_ROOT / "codex/skills/claude-plan-review/SKILL.md",
            DOTFILES_ROOT / "codex/skills/claude-spec-review/SKILL.md",
        )
        for skill in (*claude_skills, *codex_skills):
            content = skill.read_text()
            self.assertIn("DOTFILEDIR", content)
            self.assertIn("agent_runtime.py", content)
            self.assertIn("--provisional", content)
            self.assertIn("uv run --no-project python", content)
        for skill in claude_skills:
            self.assertIn("--runtime codex", skill.read_text())
        for skill in codex_skills:
            self.assertIn("--runtime claude", skill.read_text())

    def test_review_skills_resolve_installed_symlinks_without_shell_profile(
        self,
    ) -> None:
        skills = (
            "claude/skills/co-review/SKILL.md",
            "claude/skills/codex-plan-review/SKILL.md",
            "claude/skills/codex-spec-review/SKILL.md",
            "codex/skills/co-review/SKILL.md",
            "codex/skills/claude-plan-review/SKILL.md",
            "codex/skills/claude-spec-review/SKILL.md",
        )
        caller = self.root / "unrelated caller"
        caller.mkdir()
        for number, relative in enumerate(skills):
            with self.subTest(skill=relative):
                skill = DOTFILES_ROOT / relative
                installed = self.home / f"installed skill {number}"
                installed.symlink_to(skill.parent, target_is_directory=True)
                snippet = skill.read_text().split("```bash\n", 1)[1].split("```", 1)[0]
                self.assertIn("REVIEW_SKILL_FILE", snippet)
                snippet = snippet.replace(
                    "uv run --no-project python", shlex.quote(sys.executable)
                )
                snippet += '\nprintf "%s\\n" "$REVIEW_HELPER" "$RUNNER"\n'
                for source, fallback in (
                    (str(installed / "SKILL.md"), ""),
                    (str(installed / "SKILL.md"), str(self.root / "wrong checkout")),
                    ("", str(DOTFILES_ROOT)),
                ):
                    result = subprocess.run(
                        ["sh", "-c", snippet],
                        cwd=caller,
                        env={
                            "PATH": os.environ["PATH"],
                            "HOME": str(self.home),
                            "REVIEW_SKILL_FILE": source,
                            "DOTFILEDIR": fallback,
                        },
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        result.stdout.splitlines(),
                        [
                            str(SCRIPT),
                            str(DOTFILES_ROOT / "claude/hooks/agent_runtime.py"),
                        ],
                    )
                missing = subprocess.run(
                    ["sh", "-c", snippet],
                    cwd=DOTFILES_ROOT,
                    env={"PATH": os.environ["PATH"], "HOME": str(self.home)},
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(missing.returncode, 2)
                self.assertEqual(missing.stdout, "")

    def test_document_dispatch_names_frozen_input_and_original_repository(self) -> None:
        runner = self.root / "fixture runner.py"
        runner.write_text(
            "import json,sys\nfrom pathlib import Path\n"
            "args = sys.argv[1:]\n"
            "prompt = Path(args[args.index('--prompt-file') + 1]).read_text()\n"
            "print(json.dumps({'args': args, 'prompt': prompt}))\n"
        )
        for host, partner in (("claude", "codex"), ("codex", "claude")):
            for kind in ("plan", "spec"):
                with self.subTest(host=host, kind=kind):
                    skill = (
                        DOTFILES_ROOT
                        / f"{host}/skills/{partner}-{kind}-review/SKILL.md"
                    )
                    snippet = (
                        skill.read_text().rsplit("```bash\n", 1)[1].split("```", 1)[0]
                    )
                    snippet = snippet.replace(
                        "uv run --no-project python", shlex.quote(sys.executable)
                    )
                    frozen = self.root / f"private frozen {kind}.md"
                    frozen.write_text("selected immutable document\n")
                    digest = "a" * 64
                    result = subprocess.run(
                        ["sh", "-c", snippet],
                        cwd=self.repo,
                        env={
                            "PATH": os.environ["PATH"],
                            "HOME": str(self.home),
                            "TMPDIR": str(self.root),
                            "RUNNER": str(runner),
                            "REPO": str(self.repo),
                            "TASK_ID": "TASK_DISPATCH",
                            f"FROZEN_{kind.upper()}": str(frozen),
                            f"FROZEN_{kind.upper()}_SHA256": digest,
                        },
                        text=True,
                        capture_output=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    payload = json.loads(result.stdout)
                    for value in (str(frozen), digest, "TASK_DISPATCH"):
                        self.assertIn(value, payload["prompt"])
                    arguments = payload["args"]
                    for flag, expected in (
                        ("--runtime", partner),
                        ("--cwd", str(self.repo)),
                        ("--sandbox", "read-only"),
                        ("--risk", "normal"),
                    ):
                        self.assertEqual(arguments[arguments.index(flag) + 1], expected)


if __name__ == "__main__":
    unittest.main(verbosity=2)
