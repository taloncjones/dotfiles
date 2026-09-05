#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CODEX_ROLES_SCRIPT="$SCRIPT_DIR/common/codex-roles.py"

if command -v uv >/dev/null 2>&1; then
  set -- uv run --python '>=3.11' --no-project --offline --no-cache python
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
  set -- python3
else
  echo "[X] Codex role tests require Python 3.11+." >&2
  exit 1
fi

"$@" - <<'PY'
import json
import os
import stat
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

# Exact upstream ECC .codex/agents fixtures at
# 06c376ae8b3a11bdafcb56c642b81480622740fc (no final newline). See NOTICE.
FIXTURES = {
    "explorer": (
        "medium",
        "explorer.toml",
        "gpt-5.6-luna",
        (
            "Stay in exploration mode.\n"
            "Trace the real execution path, cite files and symbols, and avoid proposing fixes unless the parent agent asks for them.\n"
            "Prefer targeted search and file reads over broad scans."
        ),
    ),
    "reviewer": (
        "high",
        "reviewer.toml",
        "gpt-6-astra",
        (
            "Review like an owner.\n"
            "Prioritize correctness, security, behavioral regressions, and missing tests.\n"
            "Lead with concrete findings and avoid style-only feedback unless it hides a real bug."
        ),
    ),
    "docs_researcher": (
        "medium",
        "docs-researcher.toml",
        "gpt-5.6-terra",
        (
            "Verify APIs, framework behavior, and release-note claims against primary documentation before changes land.\n"
            "Cite the exact docs or file paths that support each claim.\n"
            "Do not invent undocumented behavior."
        ),
    ),
}


def fixture(role):
    effort, _, _, instructions = FIXTURES[role]
    return (
        f'model = "gpt-5.4"\nmodel_reasoning_effort = "{effort}"\n'
        'sandbox_mode = "read-only"\n\ndeveloper_instructions = """\n'
        + instructions
        + '\n"""'
    ).encode()


class RoleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.codex = self.root / "codex"
        self.agents = self.codex / "agents"
        self.agents.mkdir(parents=True)
        self.config = self.codex / "config.toml"
        self.config.write_text(
            "".join(
                f'[agents.{role}]\nconfig_file = "agents/{values[1]}"\n'
                for role, values in FIXTURES.items()
            )
        )
        for role, values in FIXTURES.items():
            (self.agents / values[1]).write_bytes(fixture(role))

    def run_migration(self, *args, expect=0):
        result = subprocess.run(
            [
                sys.executable,
                os.environ["CODEX_ROLES_SCRIPT"],
                "--codex-home",
                str(self.codex),
                *args,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return json.loads(result.stdout)

    def snapshot(self):
        return {path.name: path.read_bytes() for path in self.agents.iterdir()}

    def test_exact_snapshots_migrate_without_changing_other_content(self):
        config = self.config.read_bytes()
        before = self.snapshot()
        (self.agents / "reviewer.toml").chmod(0o640)
        report = self.run_migration()
        self.assertTrue(report["changed"])
        self.assertEqual(set(report["updated"]), set(FIXTURES))
        for _, name, replacement, _ in FIXTURES.values():
            after = (self.agents / name).read_bytes()
            self.assertEqual(
                after, before[name].replace(b"gpt-5.4", replacement.encode(), 1)
            )
            self.assertEqual(tomllib.loads(after.decode())["sandbox_mode"], "read-only")
        self.assertEqual(self.config.read_bytes(), config)
        self.assertEqual(
            stat.S_IMODE((self.agents / "reviewer.toml").stat().st_mode), 0o640
        )

    def test_second_run_is_unchanged(self):
        self.run_migration()
        before = self.snapshot()
        report = self.run_migration()
        self.assertFalse(report["changed"])
        self.assertEqual(report["updated"], [])
        self.assertEqual(self.snapshot(), before)

    def test_custom_instructions_model_extra_key_and_formatting_survive(self):
        for transform in (
            lambda raw: raw.replace(
                b"Stay in exploration mode.", b"Keep my custom instructions."
            ),
            lambda raw: raw.replace(b"gpt-5.4", b"gpt-5.5"),
            lambda raw: raw + b"\ncustom_option = true\n",
            lambda raw: raw + b"\n",
        ):
            with self.subTest(transform=transform):
                custom = transform(fixture("explorer"))
                (self.agents / "explorer.toml").write_bytes(custom)
                report = self.run_migration()
                self.assertIn("explorer", report["preserved"])
                self.assertEqual((self.agents / "explorer.toml").read_bytes(), custom)

    def test_unconfigured_and_custom_mappings_are_preserved(self):
        for config in (
            "",
            "[agents]\nmax_threads = 6\n",
            '[agents.explorer]\nconfig_file = "custom/explorer.toml"\n',
            '[agents.explorer]\nconfig_file = "agents/explorer.toml"\nmodel = "gpt-5.5"\n',
        ):
            with self.subTest(config=config):
                self.config.write_text(config)
                before = self.snapshot()
                report = self.run_migration()
                self.assertFalse(report["changed"])
                self.assertEqual(self.snapshot(), before)

    def test_absent_config_does_not_seed_anything(self):
        self.config.unlink()
        before = self.snapshot()
        self.assertFalse(self.run_migration()["changed"])
        self.assertFalse(self.config.exists())
        self.assertEqual(self.snapshot(), before)

    def test_absent_agents_and_role_files_are_not_created(self):
        for path in self.agents.iterdir():
            path.unlink()
        self.agents.rmdir()
        self.assertFalse(self.run_migration()["changed"])
        self.assertFalse(self.agents.exists())
        self.agents.mkdir()
        self.assertFalse(self.run_migration()["changed"])
        self.assertEqual(list(self.agents.iterdir()), [])

    def test_symlink_role_is_preserved_without_writing_target(self):
        target = self.root / "custom-role.toml"
        target.write_bytes(fixture("explorer"))
        role_file = self.agents / "explorer.toml"
        role_file.unlink()
        role_file.symlink_to(target)
        report = self.run_migration()
        self.assertIn("explorer", report["preserved"])
        self.assertTrue(role_file.is_symlink())
        self.assertEqual(target.read_bytes(), fixture("explorer"))

    def test_symlink_root_directory_is_preserved(self):
        original = self.codex
        link = self.root / "codex-link"
        link.symlink_to(original, target_is_directory=True)
        self.codex = link
        before = self.snapshot()
        self.assertFalse(self.run_migration()["changed"])
        self.assertEqual(self.snapshot(), before)

    def test_symlink_agents_directory_is_preserved(self):
        destination = self.root / "external-agents"
        self.agents.rename(destination)
        self.agents.symlink_to(destination, target_is_directory=True)
        before = self.snapshot()
        self.assertFalse(self.run_migration()["changed"])
        self.assertEqual(self.snapshot(), before)

    def test_symlink_config_is_preserved(self):
        destination = self.root / "external-config.toml"
        self.config.rename(destination)
        self.config.symlink_to(destination)
        before = self.snapshot()
        self.assertFalse(self.run_migration()["changed"])
        self.assertEqual(self.snapshot(), before)

    def test_malformed_config_fails_without_role_updates(self):
        self.config.write_text("[broken")
        before = self.snapshot()
        report = self.run_migration(expect=1)
        self.assertIn("error", report)
        self.assertEqual(self.snapshot(), before)

    def test_malformed_later_role_fails_before_any_updates(self):
        (self.agents / "docs-researcher.toml").write_text("[broken")
        before = self.snapshot()
        report = self.run_migration(expect=1)
        self.assertIn("error", report)
        self.assertEqual(self.snapshot(), before)

    def test_check_reports_changes_without_writing(self):
        before = self.snapshot()
        report = self.run_migration("--check")
        self.assertTrue(report["changed"])
        self.assertEqual(report["updated"], [])
        self.assertEqual(set(report["would_update"]), set(FIXTURES))
        self.assertEqual(self.snapshot(), before)

    def test_malformed_agent_mapping_fails_without_updates(self):
        self.config.write_text('[agents]\nexplorer = "unexpected"\n')
        before = self.snapshot()
        self.run_migration(expect=1)
        self.assertEqual(self.snapshot(), before)


unittest.main(verbosity=2)
PY
