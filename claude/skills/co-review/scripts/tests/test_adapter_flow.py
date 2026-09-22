"""Executable finalization checks for both final-gate skill adapters."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[5]
ADAPTERS = (
    ROOT / "claude/skills/co-review/SKILL.md",
    ROOT / "codex/skills/co-review/SKILL.md",
)
_BLOCK = re.compile(
    r"# co-review-finalize:start\n(?P<body>.*?)# co-review-finalize:end", re.S
)
_CHANGED_FILES_BLOCK = re.compile(
    r"# co-review-changed-files:start\n(?P<body>.*?)# co-review-changed-files:end",
    re.S,
)


def finalization_block(adapter: Path) -> str:
    match = _BLOCK.search(adapter.read_text())
    if match is None:
        raise AssertionError(f"{adapter} lacks a finalization block")
    return match.group("body")


def changed_files_block(adapter: Path) -> str:
    match = _CHANGED_FILES_BLOCK.search(adapter.read_text())
    if match is None:
        raise AssertionError(f"{adapter} lacks a changed-files block")
    return match.group("body")


class AdapterFinalizationTests(unittest.TestCase):
    def run_block(
        self,
        adapter: Path,
        *,
        evaluator_exit: int,
        cleanup_exit: int,
        ref_repo: str | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], bool, list[str], str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run"
            run_dir.mkdir()
            expected = root / "expected.json"
            expected.write_text("{}")
            trace = root / "trace"
            # A real repository for the run ref the block deletes after cleanup.
            repo = root / "repo"
            repo.mkdir()
            git_env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(root)}
            subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True, env=git_env)
            subprocess.run(
                ["git", "-C", str(repo), "-c", "user.name=t", "-c",
                 "user.email=t@example.invalid", "commit", "-q", "--allow-empty", "-m", "x"],
                check=True, env=git_env, capture_output=True,
            )
            subprocess.run(
                ["git", "-C", str(repo), "update-ref", "refs/co-review-run/test-run", "HEAD"],
                check=True, env=git_env,
            )
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_uv = fake_bin / "uv"
            fake_uv.write_text(
                "#!/bin/sh\n"
                'printf "%s\\n" "$*" >> "$TRACE"\n'
                'case " $* " in\n'
                '  *" evaluate "*) printf "{\\"verdict\\":\\"CHANGES\\"}\\n"; exit "$EVALUATOR_EXIT";;\n'
                '  *" cleanup "*) printf "cleanup\\n"; exit "$CLEANUP_EXIT";;\n'
                '  *" verify "*) exit 0;;\n'
                "esac\n"
                "exit 99\n"
            )
            fake_uv.chmod(0o755)
            result = subprocess.run(
                "set -e\n" + finalization_block(adapter),
                shell=True,
                executable="/bin/sh",
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "PATH": f"{fake_bin}:{os.environ['PATH']}",
                    "TRACE": str(trace),
                    "EVALUATOR_EXIT": str(evaluator_exit),
                    "CLEANUP_EXIT": str(cleanup_exit),
                    "RUN_DIR": str(run_dir),
                    "EXPECTED_IDENTITY": str(expected),
                    "REVIEW_HELPER": "review.py",
                    "GATE_REPORT": "gate_report.py",
                    "MANIFEST": "manifest.json",
                    "REPO": ref_repo if ref_repo is not None else str(repo),
                    "RUN_ID": "test-run",
                },
                check=False,
            )
            refs = subprocess.run(
                ["git", "-C", str(repo), "for-each-ref", "refs/co-review-run/"],
                capture_output=True, text=True, check=True, env=git_env,
            ).stdout.strip()
            return result, expected.exists(), trace.read_text().splitlines(), refs

    def test_approve_requires_successful_cleanup_and_invalidates_on_failure(self):
        for adapter in ADAPTERS:
            with self.subTest(adapter=adapter):
                result, expected_exists, trace, _refs = self.run_block(
                    adapter, evaluator_exit=0, cleanup_exit=7
                )
                self.assertEqual(result.returncode, 2)
                self.assertFalse(expected_exists)
                self.assertIn(
                    "snapshot cleanup failed; evidence preserved", result.stderr
                )
                self.assertTrue(any(" evaluate " in f" {line} " for line in trace))
                self.assertTrue(any(" cleanup " in f" {line} " for line in trace))

    def test_evaluator_failure_still_runs_cleanup_before_returning_result(self):
        for adapter in ADAPTERS:
            with self.subTest(adapter=adapter):
                result, expected_exists, trace, _refs = self.run_block(
                    adapter, evaluator_exit=1, cleanup_exit=0
                )
                self.assertEqual(result.returncode, 1)
                self.assertTrue(expected_exists)
                self.assertIn('"verdict":"CHANGES"', result.stdout)
                self.assertTrue(any(" evaluate " in f" {line} " for line in trace))
                self.assertTrue(any(" cleanup " in f" {line} " for line in trace))

    def test_approve_path_deletes_the_run_ref(self):
        for adapter in ADAPTERS:
            with self.subTest(adapter=adapter):
                result, expected_exists, trace, refs = self.run_block(
                    adapter, evaluator_exit=0, cleanup_exit=0
                )
                self.assertEqual(result.returncode, 0)
                self.assertTrue(expected_exists)
                self.assertEqual(refs, "")
                self.assertTrue(any(" cleanup " in f" {line} " for line in trace))

    def test_run_ref_removal_failure_invalidates_after_cleanup(self):
        for adapter in ADAPTERS:
            with self.subTest(adapter=adapter):
                result, expected_exists, trace, refs = self.run_block(
                    adapter, evaluator_exit=0, cleanup_exit=0,
                    ref_repo="/nonexistent/not-a-repo",
                )
                self.assertEqual(result.returncode, 2)
                self.assertFalse(expected_exists)
                self.assertIn(
                    "run ref removal failed; evidence preserved", result.stderr
                )
                self.assertTrue(any(" cleanup " in f" {line} " for line in trace))
                self.assertNotEqual(refs, "")


class AdapterChangedFileSetTests(unittest.TestCase):
    """Executes the real changed-file-set/base-tip block (local --base mode) in
    both adapters against a disposable git fixture, proving V-1's empty-set
    guard and V-2's `-z` quoting fix behaviorally rather than by grep."""

    def make_repo(self, root: Path) -> Path:
        repo = root / "repo"
        repo.mkdir()
        env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(root)}
        subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True, env=env)
        subprocess.run(
            ["git", "-C", str(repo), "-c", "user.name=t", "-c",
             "user.email=t@example.invalid", "commit", "-q", "--allow-empty",
             "-m", "base"],
            check=True, env=env,
        )
        return repo

    def commit_all(self, repo: Path, message: str) -> None:
        env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(repo.parent)}
        subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=env)
        subprocess.run(
            ["git", "-C", str(repo), "-c", "user.name=t", "-c",
             "user.email=t@example.invalid", "commit", "-q", "-m", message],
            check=True, env=env,
        )

    def sha(self, repo: Path, rev: str = "HEAD") -> str:
        env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "HOME": str(repo.parent)}
        return subprocess.run(
            ["git", "-C", str(repo), "rev-parse", rev],
            check=True, capture_output=True, text=True, env=env,
        ).stdout.strip()

    def run_changed_files_block(
        self, adapter: Path, repo: Path, run_dir: Path, base_sha: str, head_sha: str,
    ) -> subprocess.CompletedProcess[str]:
        manifest = run_dir / "manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "source": {"base": base_sha, "head": head_sha},
                    "snapshot": {"snapshot_head": head_sha},
                }
            )
        )
        # uv's own resolution of its managed Python/venv can be HOME-sensitive
        # (observed in CI); pin its real directory onto PATH explicitly so
        # overriding HOME below for git isolation can't hide the uv binary.
        uv_path = shutil.which("uv")
        uv_dir = os.path.dirname(uv_path) if uv_path else ""
        env = {
            **os.environ,
            "GIT_CONFIG_NOSYSTEM": "1",
            "HOME": str(repo.parent),
            "PATH": f"{uv_dir}:{os.environ.get('PATH', '')}" if uv_dir else os.environ.get("PATH", ""),
            "REPO": str(repo),
            "RUN_DIR": str(run_dir),
            "MANIFEST": str(manifest),
            "RUN_ID": "test-run",
            "REVIEW_HELPER": "review.py",
        }
        return subprocess.run(
            "set -e\n" + changed_files_block(adapter),
            shell=True,
            executable="/bin/sh",
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def test_local_base_produces_sorted_changed_files_and_null_base_context(self):
        for adapter in ADAPTERS:
            with self.subTest(adapter=adapter):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    repo = self.make_repo(root)
                    base_sha = self.sha(repo)
                    (repo / "b.txt").write_text("b\n")
                    (repo / "a.txt").write_text("a\n")
                    self.commit_all(repo, "feature: add a and b")
                    head_sha = self.sha(repo)
                    run_dir = root / "run"
                    run_dir.mkdir()
                    result = self.run_changed_files_block(
                        adapter, repo, run_dir, base_sha, head_sha
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(
                        (run_dir / "changed-files.txt").read_text(),
                        "a.txt\nb.txt\n",
                    )
                    base_context = json.loads(
                        (run_dir / "base-context.json").read_text()
                    )
                    self.assertEqual(base_context["base"], base_sha)
                    self.assertIsNone(base_context["base_ref"])
                    self.assertIsNone(base_context["base_ref_tip"])

    def test_empty_changed_file_set_is_incomplete(self):
        for adapter in ADAPTERS:
            with self.subTest(adapter=adapter):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    repo = self.make_repo(root)
                    head_sha = self.sha(repo)
                    run_dir = root / "run"
                    run_dir.mkdir()
                    result = self.run_changed_files_block(
                        adapter, repo, run_dir, head_sha, head_sha
                    )
                    self.assertEqual(result.returncode, 2)
                    self.assertFalse((run_dir / "base-context.json").exists())

    def test_tab_containing_path_survives_dash_z(self):
        for adapter in ADAPTERS:
            with self.subTest(adapter=adapter):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    repo = self.make_repo(root)
                    base_sha = self.sha(repo)
                    (repo / "tab\tname.txt").write_text("x\n")
                    self.commit_all(repo, "feature: add a tab-bearing path")
                    head_sha = self.sha(repo)
                    run_dir = root / "run"
                    run_dir.mkdir()
                    result = self.run_changed_files_block(
                        adapter, repo, run_dir, base_sha, head_sha
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    changed = (run_dir / "changed-files.txt").read_text()
                    self.assertIn("tab\tname.txt", changed)
                    self.assertNotIn('"tab', changed)


if __name__ == "__main__":
    unittest.main()
