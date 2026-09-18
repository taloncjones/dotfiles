"""Executable finalization checks for both final-gate skill adapters."""

from __future__ import annotations

import os
import re
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


def finalization_block(adapter: Path) -> str:
    match = _BLOCK.search(adapter.read_text())
    if match is None:
        raise AssertionError(f"{adapter} lacks a finalization block")
    return match.group("body")


class AdapterFinalizationTests(unittest.TestCase):
    def run_block(
        self, adapter: Path, *, evaluator_exit: int, cleanup_exit: int
    ) -> tuple[subprocess.CompletedProcess[str], bool, list[str]]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run"
            run_dir.mkdir()
            expected = root / "expected.json"
            expected.write_text("{}")
            trace = root / "trace"
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
                },
                check=False,
            )
            return result, expected.exists(), trace.read_text().splitlines()

    def test_approve_requires_successful_cleanup_and_invalidates_on_failure(self):
        for adapter in ADAPTERS:
            with self.subTest(adapter=adapter):
                result, expected_exists, trace = self.run_block(
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
                result, expected_exists, trace = self.run_block(
                    adapter, evaluator_exit=1, cleanup_exit=0
                )
                self.assertEqual(result.returncode, 1)
                self.assertTrue(expected_exists)
                self.assertIn('"verdict":"CHANGES"', result.stdout)
                self.assertTrue(any(" evaluate " in f" {line} " for line in trace))
                self.assertTrue(any(" cleanup " in f" {line} " for line in trace))


if __name__ == "__main__":
    unittest.main()
