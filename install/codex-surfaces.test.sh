#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export CODEX_SURFACES_SCRIPT="$SCRIPT_DIR/common/codex-surfaces.py"

if command -v uv >/dev/null 2>&1; then
  set -- uv run --python '>=3.11' --no-project --offline --no-cache python
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
  set -- python3
else
  echo "[X] Codex surface tests require Python 3.11+; install a supported Python or uv." >&2
  exit 1
fi

"$@" - <<'PY'
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
import unittest


class SurfaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.codex = self.root / ".codex"
        self.codex.mkdir()
        self.config = self.codex / "config.toml"
        self.skills = self.root / ".agents/skills"
        self.source = self.root / "ECC"
        self.canonical = self.codex / "plugins/cache/dotfiles-workflows/ecc/2.0.0"
        self.security = self.codex / "plugins/cache/claude-plugins-official/security-guidance/2.0.7"

    def write(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def run_repair(self, expect=0, extra=()):
        result = subprocess.run(
            [sys.executable, os.environ["CODEX_SURFACES_SCRIPT"],
             "--codex-home", str(self.codex), "--agents-skills", str(self.skills),
             "--ecc-repo", str(self.source), *extra, "--apply"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        return tomllib.loads(self.config.read_text()) if expect == 0 else result

    def run_lifecycle(self, alternate, extra_env=None):
        repo = Path(os.environ["CODEX_SURFACES_SCRIPT"]).resolve().parents[2]
        result = subprocess.run(
            ["bash", "-c", 'source "$DOTFILEDIR/install/common/codex-plugin-dedupe.sh"; dedupe_codex_workflow_plugins'],
            env={**os.environ, "HOME": str(self.root), "CODEX_HOME": str(alternate), "DOTFILEDIR": str(repo), **(extra_env or {})},
            cwd=self.root, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_lifecycle_repairs_alternate_only_codex_home(self):
        alternate = self.root / "codex-alt"
        self.write(alternate / "config.toml", '[plugins."ecc@dotfiles-workflows"]\nenabled = true\n[plugins."ecc@ecc"]\nenabled = true\n')
        self.run_lifecycle(alternate)
        result = tomllib.loads((alternate / "config.toml").read_text())
        self.assertFalse(result["plugins"]["ecc@ecc"]["enabled"])
        self.assertEqual(result["skills"]["max_context_tokens"], 10000)
        self.assertFalse(self.config.exists())

    def test_lifecycle_preserves_default_home_when_alternate_selected(self):
        original = '# default-home preference\n[plugins."ecc@dotfiles-workflows"]\nenabled = true\n[plugins."ecc@ecc"]\nenabled = true\n[skills]\nmax_context_tokens = 4000\n'
        self.config.write_text(original)
        alternate = self.root / "codex-alt"
        self.write(alternate / "config.toml", '[plugins."ecc@dotfiles-workflows"]\nenabled = true\n[plugins."ecc@ecc"]\nenabled = true\n')
        self.run_lifecycle(alternate)
        self.assertEqual(self.config.read_text(), original)
        result = tomllib.loads((alternate / "config.toml").read_text())
        self.assertFalse(result["plugins"]["ecc@ecc"]["enabled"])
        self.assertEqual(result["skills"]["max_context_tokens"], 10000)

    def test_lifecycle_ignores_unsupported_caller_python_version(self):
        self.config.write_text("# fixture\n")
        (self.root / ".python-version").write_text("3.10\n")
        self.run_lifecycle(self.codex)
        self.assertEqual(tomllib.loads(self.config.read_text())["skills"]["max_context_tokens"], 10000)

    def test_lifecycle_without_uv_uses_supported_system_python(self):
        toolbin = self.root / "test-bin"
        toolbin.mkdir()
        for name in ("bash", "awk", "cp", "mv"):
            (toolbin / name).symlink_to(shutil.which(name))
        (toolbin / "python3").symlink_to(sys.executable)
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n[plugins."ecc@ecc"]\nenabled = true\n')
        self.run_lifecycle(self.codex, {"PATH": str(toolbin)})
        result = tomllib.loads(self.config.read_text())
        self.assertFalse(result["plugins"]["ecc@ecc"]["enabled"])
        self.assertEqual(result["skills"]["max_context_tokens"], 10000)

    def test_optional_installers_continue_when_python_is_unavailable(self):
        repo = Path(os.environ["CODEX_SURFACES_SCRIPT"]).resolve().parents[2]
        toolbin = self.root / "installer-bin"
        toolbin.mkdir()
        for name in ("bash", "awk", "basename", "cp", "date", "dirname", "find", "grep", "ln", "mkdir", "mv", "rm", "rmdir", "sed", "wc"):
            (toolbin / name).symlink_to(shutil.which(name))
        self.write(toolbin / "python3", '#!/bin/sh\nexit 1\n')
        (toolbin / "python3").chmod(0o755)
        env = {**os.environ, "HOME": str(self.root), "CODEX_HOME": str(self.codex), "DOTFILEDIR": str(repo), "PATH": str(toolbin)}
        self.config.write_text('# preserve this preference\n[skills]\nmax_context_tokens = 4000\n')
        stale = self.codex / "skills/ecc-obsolete/SKILL.md"
        self.write(stale, 'old managed snapshot\n')
        for script in ("link.sh", "claude-plugins.sh"):
            with self.subTest(script=script):
                result = subprocess.run([str(toolbin / "bash"), str(repo / "install/common" / script)], env=env, cwd=self.root, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('Codex surface reconciliation did not complete', result.stderr)
        self.assertFalse(stale.exists(), 'later link cleanup must still run')
        self.assertEqual(tomllib.loads(self.config.read_text())["skills"]["max_context_tokens"], 4000)
        strict = subprocess.run([str(toolbin / "bash"), '-ec', 'source "$DOTFILEDIR/install/common/codex-plugin-dedupe.sh"; dedupe_codex_workflow_plugins'], env=env, capture_output=True, text=True)
        self.assertNotEqual(strict.returncode, 0, 'explicit reconciliation must report failure')

    def test_optional_installers_preserve_unsupported_valid_toml(self):
        repo = Path(os.environ["CODEX_SURFACES_SCRIPT"]).resolve().parents[2]
        original = 'developer_instructions = """\n[skills]\nmax_context_tokens = 4000\n"""\n'
        self.config.write_text(original)
        env = {**os.environ, "HOME": str(self.root), "CODEX_HOME": str(self.codex), "DOTFILEDIR": str(repo)}
        result = subprocess.run(['bash', '-ec', 'source "$DOTFILEDIR/install/common/codex-plugin-dedupe.sh"; reconcile_codex_workflow_plugins_for_install; echo later-install-step'], env=env, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Codex surface reconciliation did not complete', result.stderr)
        self.assertIn('later-install-step', result.stdout)
        self.assertEqual(self.config.read_text(), original)
        strict = subprocess.run(['bash', '-ec', 'source "$DOTFILEDIR/install/common/codex-plugin-dedupe.sh"; dedupe_codex_workflow_plugins'], env=env, cwd=self.root, capture_output=True, text=True)
        self.assertNotEqual(strict.returncode, 0)
        self.assertEqual(self.config.read_text(), original)

    def test_early_duplicate_failure_stops_strict_reconciliation(self):
        repo = Path(os.environ["CODEX_SURFACES_SCRIPT"]).resolve().parents[2]
        original = '[plugins."ecc@dotfiles-workflows"]\nenabled = true\n'
        self.config.write_text(original)
        env = {**os.environ, "HOME": str(self.root), "CODEX_HOME": str(self.codex), "DOTFILEDIR": str(repo)}
        command = 'source "$DOTFILEDIR/install/common/codex-plugin-dedupe.sh"; disable_codex_plugin() { return 7; }; if dedupe_codex_workflow_plugins; then exit 0; else exit 1; fi'
        strict = subprocess.run(['bash', '-ec', command], env=env, cwd=self.root, capture_output=True, text=True)
        self.assertNotEqual(strict.returncode, 0, 'a failed duplicate write must not be masked by successful later repair')
        self.assertEqual(self.config.read_text(), original)

    def security_hook(self, asynchronous=True):
        self.write(self.security / ".claude-plugin/plugin.json", '{"name":"security-guidance"}')
        self.write(self.security / "hooks/hooks.json", json.dumps({"hooks": {
            "SessionStart": [{"hooks": [{"type": "command", "command":
                'bash "${CLAUDE_PLUGIN_ROOT}/hooks/sg-python.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/ensure_agent_sdk.py"'}]}]
        }}))
        self.write(self.security / "hooks/ensure_agent_sdk.py", (
            'import json\nif __name__ == "__main__":\n'
            + ('    print(json.dumps({"async": True, "asyncTimeout": 180000}), flush=True)\n' if asynchronous else '')
            + '    response = {"metrics": {}}\n    print(json.dumps(response), flush=True)\n'
        ))

    def skill(self, name, content="original", custom=False):
        body = f"---\nname: {name}\ndescription: Example\n---\n{content}\n"
        self.write(self.skills / name / "SKILL.md", body)
        self.write(self.source / "skills" / name / "SKILL.md", body)
        self.write(self.canonical / "skills" / name / "SKILL.md", body)
        if custom:
            self.write(self.skills / name / "custom.txt", "personal customization\n")

    def test_repairs_only_incompatible_codex_plugin_and_adds_default(self):
        original = '# user comment\n[plugins."security-guidance@claude-plugins-official"]\nenabled = true # keep comment\n[plugins."other@market"]\nenabled = true\n'
        self.config.write_text(original)
        self.config.chmod(0o600)
        claude = self.root / ".claude/settings.json"
        self.write(claude, '{"enabledPlugins":{"security-guidance@claude-plugins-official":true}}')
        self.security_hook()
        result = self.run_repair()
        self.assertFalse(result["plugins"]["security-guidance@claude-plugins-official"]["enabled"])
        self.assertTrue(result["plugins"]["other@market"]["enabled"])
        self.assertEqual(result["skills"]["max_context_tokens"], 10000)
        self.assertIn("# keep comment", self.config.read_text())
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.assertTrue(json.loads(claude.read_text())["enabledPlugins"]["security-guidance@claude-plugins-official"])
        first = self.config.read_bytes()
        self.run_repair()
        self.assertEqual(first, self.config.read_bytes())

    def test_preserves_compatible_and_native_security_plugins(self):
        for native in (False, True):
            with self.subTest(native=native):
                self.config.write_text('[plugins."security-guidance@claude-plugins-official"]\nenabled = true\n')
                self.security_hook(asynchronous=native)
                if native:
                    self.write(self.security / ".codex-plugin/plugin.json", '{}')
                self.assertTrue(self.run_repair()["plugins"]["security-guidance@claude-plugins-official"]["enabled"])

    def test_preserves_ambiguous_or_unused_async_hook_code(self):
        legacy_print = 'print(json.dumps({"async": True, "asyncTimeout": 180000}))'
        synchronous_print = 'print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart"}}))'
        sources = (
            f'import json\ndef unused_legacy():\n    {legacy_print}\nif __name__ == "__main__":\n    {synchronous_print}\n',
            f'import json\nif __name__ == "__main__":\n    if False:\n        {legacy_print}\n    {synchronous_print}\n',
            f'import json\ndef optional_response():\n    {legacy_print}\nif __name__ == "__main__":\n    optional_response()\n    {synchronous_print}\n',
        )
        for source in sources:
            with self.subTest(source=source):
                self.config.write_text('[plugins."security-guidance@claude-plugins-official"]\nenabled = true\n')
                self.security_hook(asynchronous=False)
                self.write(self.security / "hooks/ensure_agent_sdk.py", source)
                self.assertTrue(self.run_repair()["plugins"]["security-guidance@claude-plugins-official"]["enabled"])

    def test_preserves_async_prints_after_synchronous_exit(self):
        self.config.write_text('[plugins."security-guidance@claude-plugins-official"]\nenabled = true\n')
        self.security_hook()
        self.write(self.security / "hooks/ensure_agent_sdk.py", (
            'import json\nif __name__ == "__main__":\n'
            '    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "Ready"}}))\n'
            '    raise SystemExit(0)\n'
            '    print(json.dumps({"async": True}))\n'
            '    print(json.dumps({"metrics": {}}))\n'
        ))
        self.assertTrue(self.run_repair()["plugins"]["security-guidance@claude-plugins-official"]["enabled"])

    def test_preserves_custom_security_hook_invocation(self):
        self.config.write_text('[plugins."security-guidance@claude-plugins-official"]\nenabled = true\n')
        self.security_hook()
        hooks_path = self.security / "hooks/hooks.json"
        hooks = json.loads(hooks_path.read_text())
        hook = hooks["hooks"]["SessionStart"][0]["hooks"][0]
        hook["command"] = 'false && ' + hook["command"]
        hooks_path.write_text(json.dumps(hooks))
        self.assertTrue(self.run_repair()["plugins"]["security-guidance@claude-plugins-official"]["enabled"])

    def test_exact_duplicates_disabled_custom_and_unmapped_skills_preserved(self):
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        self.skill("same")
        self.skill("custom", custom=True)
        self.write(self.skills / "personal/SKILL.md", "personal")
        result = self.run_repair()
        self.assertEqual(result["skills"]["config"], [{"path": str(self.skills / "same/SKILL.md"), "enabled": False}])
        self.assertTrue((self.skills / "same/SKILL.md").is_file())
        self.assertEqual((self.skills / "custom/custom.txt").read_text(), "personal customization\n")

    def test_explicit_skill_and_budget_preferences_preserved(self):
        self.skill("same")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n[skills]\nmax_context_tokens = 4000\n[[skills.config]]\nname = "same"\nenabled = true\n')
        first = self.config.read_bytes()
        self.run_repair()
        self.assertEqual(first, self.config.read_bytes())

    def test_disabled_canonical_plugin_never_hides_legacy_skills(self):
        self.skill("same")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = false\n')
        self.assertNotIn("config", self.run_repair()["skills"])

    def test_recognizes_whole_historical_snapshot(self):
        self.skill("old")
        for args in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture: Add old skill"]):
            subprocess.run(["git", "-C", str(self.source), *args], check=True, capture_output=True)
        self.write(self.source / "skills/old/SKILL.md", "new upstream version")
        self.write(self.canonical / "skills/old/SKILL.md", "new upstream version")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        self.assertEqual(self.run_repair()["skills"]["config"][0]["path"], str(self.skills / "old/SKILL.md"))

    def test_recognizes_exact_translated_historical_tree(self):
        original = '---\nname: migrated\ndescription: Use Claude Code\n---\nRead CLAUDE.md through claude-code.\n'
        migrated = '---\nname: migrated\ndescription: Use Codex\n---\nRead AGENTS.md through Codex.\n'
        self.write(self.source / 'skills/migrated/SKILL.md', original)
        self.write(self.source / 'skills/migrated/helper.txt', 'Use ~/.claude/\n')
        self.write(self.canonical / 'skills/migrated/SKILL.md', original)
        self.write(self.skills / 'migrated/SKILL.md', migrated)
        self.write(self.skills / 'migrated/helper.txt', 'Use ~/.Codex/\n')
        for args in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture: Add untranslated tree"]):
            subprocess.run(["git", "-C", str(self.source), *args], check=True, capture_output=True)
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        result = self.run_repair()
        self.assertEqual(result['skills']['config'][0]['path'], str(self.skills / 'migrated/SKILL.md'))
        self.assertEqual((self.skills / 'migrated/SKILL.md').read_text(), migrated)
        self.assertEqual((self.source / 'skills/migrated/SKILL.md').read_text(), original)
        self.write(self.skills / 'migrated/helper.txt', 'Use ~/.Codex/ with my custom rule\n')
        self.assertNotIn('config', self.run_repair()['skills'])

    def test_translated_skill_preserves_explicit_display_name_override(self):
        original = '---\nname: claude-example\ndescription: Use Claude Code\n---\nRead CLAUDE.md.\n'
        migrated = '---\nname: Codex-example\ndescription: Use Codex\n---\nRead AGENTS.md.\n'
        self.write(self.source / 'skills/claude-example/SKILL.md', original)
        self.write(self.canonical / 'skills/claude-example/SKILL.md', original)
        self.write(self.skills / 'claude-example/SKILL.md', migrated)
        for args in (["init", "-q"], ["add", "."], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture: Add untranslated skill"]):
            subprocess.run(["git", "-C", str(self.source), *args], check=True, capture_output=True)
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n[skills]\nmax_context_tokens = 4000\n[[skills.config]]\nname = "Codex-example"\nenabled = true\n')
        first = self.config.read_bytes()
        self.run_repair()
        self.assertEqual(first, self.config.read_bytes())

    def test_translated_command_requires_exact_wrapper_and_body(self):
        self.write(self.source / 'commands/resume.md', '---\ndescription: Resume Claude Code with CLAUDE.md\n---\n\n# Continue\nRead ~/.claude/session-data/.\n')
        migrated = '---\nname: "source-command-resume"\ndescription: "Resume Codex with AGENTS.md"\n---\n\n# source-command-resume\n\nUse this skill when the user asks to run the migrated source command `resume`.\n\n## Command Template\n\n# Continue\nRead ~/.Codex/session-data/.\n'
        self.write(self.skills / 'source-command-resume/SKILL.md', migrated)
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        result = self.run_repair(extra=("--focus",))
        self.assertEqual(result['skills']['config'][0]['path'], str(self.skills / 'source-command-resume/SKILL.md'))
        self.write(self.skills / 'source-command-resume/SKILL.md', migrated + 'Keep this custom instruction.\n')
        result = self.run_repair(extra=("--focus",))
        self.assertNotIn('config', result['skills'])

    def test_malformed_config_untouched(self):
        self.config.write_text('[broken\n')
        first = self.config.read_bytes()
        self.run_repair(expect=1)
        self.assertEqual(first, self.config.read_bytes())

    def test_explicit_path_override_preserved(self):
        self.skill("same")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n[skills]\nmax_context_tokens = 9000\n[[skills.config]]\npath = ' + json.dumps(str(self.skills / "same/SKILL.md")) + '\nenabled = true\n')
        first = self.config.read_bytes()
        self.run_repair()
        self.assertEqual(first, self.config.read_bytes())

    def test_focus_preserves_explicit_preferences_and_survives_cache_updates(self):
        self.skill("keep")
        self.skill("specialist")
        self.skill("chosen")
        catalog = self.root / "catalog.txt"
        catalog.write_text("keep\n")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n[[skills.config]]\nname = "ecc:chosen"\nenabled = true\n')
        result = self.run_repair(extra=("--focus", "--catalog", str(catalog)))
        disabled = {entry.get("path") for entry in result["skills"]["config"] if entry["enabled"] is False}
        self.assertIn(str(self.canonical / "skills/specialist/SKILL.md"), disabled)
        self.assertNotIn(str(self.canonical / "skills/chosen/SKILL.md"), disabled)
        self.assertNotIn(str(self.canonical / "skills/keep/SKILL.md"), disabled)
        first = self.config.read_bytes()
        self.run_repair(extra=("--catalog", str(catalog)))
        self.assertEqual(first, self.config.read_bytes())
        updated = self.canonical.parent / "3.0.0"
        for name in ("keep", "specialist", "chosen"):
            self.write(updated / "skills" / name / "SKILL.md", "updated upstream skill")
        result = self.run_repair(extra=("--catalog", str(catalog)))
        disabled = {entry.get("path") for entry in result["skills"]["config"] if entry["enabled"] is False}
        self.assertIn(str(updated / "skills/specialist/SKILL.md"), disabled)
        self.assertNotIn(str(updated / "skills/chosen/SKILL.md"), disabled)
        self.assertNotIn(str(updated / "skills/keep/SKILL.md"), disabled)

    def test_inert_plugin_disabled_but_usable_skill_plugin_preserved(self):
        self.config.write_text('[plugins."code-review@claude-plugins-official"]\nenabled = true\n[plugins."code-simplifier@claude-plugins-official"]\nenabled = true\n')
        base = self.codex / "plugins/cache/claude-plugins-official"
        for name in ("code-review", "code-simplifier"):
            self.write(base / name / "1/.claude-plugin/plugin.json", '{}')
            self.write(base / name / "1/commands/review.md", "command")
        self.write(base / "code-simplifier/1/skills/usable/SKILL.md", "usable")
        result = self.run_repair()
        self.assertFalse(result["plugins"]["code-review@claude-plugins-official"]["enabled"])
        self.assertTrue(result["plugins"]["code-simplifier@claude-plugins-official"]["enabled"])

    def test_default_check_does_not_write(self):
        self.config.write_text("# untouched\n")
        result = subprocess.run([sys.executable, os.environ["CODEX_SURFACES_SCRIPT"], "--codex-home", str(self.codex)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["changed"])
        self.assertEqual(self.config.read_text(), "# untouched\n")

    def test_customization_after_migration_restores_discovery(self):
        self.skill("same")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        self.run_repair()
        self.write(self.skills / "same/personal.txt", "new custom instructions")
        result = self.run_repair()
        self.assertNotIn("config", result["skills"])

    def test_user_can_reenable_a_managed_specialist(self):
        self.skill("specialist")
        catalog = self.root / "catalog.txt"
        catalog.write_text("keep\n")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        self.run_repair(extra=("--focus", "--catalog", str(catalog)))
        self.config.write_text(self.config.read_text().replace("enabled = false", "enabled = true"))
        first = self.config.read_bytes()
        self.run_repair(extra=("--catalog", str(catalog)))
        self.assertEqual(first, self.config.read_bytes())

    def test_provenance_survives_unavailable_upstream_history(self):
        self.skill("same")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        self.run_repair()
        self.write(self.source / "skills/same/SKILL.md", "updated upstream")
        self.write(self.canonical / "skills/same/SKILL.md", "updated upstream")
        first = self.config.read_bytes()
        self.run_repair()
        self.assertEqual(first, self.config.read_bytes())

    def test_inline_skills_table_remains_valid(self):
        self.config.write_text('skills = { max_context_tokens = 4000 }\n')
        first = self.config.read_bytes()
        self.run_repair()
        self.assertEqual(first, self.config.read_bytes())

    def test_inline_incompatible_plugin_fails_without_mutation(self):
        self.security_hook()
        self.config.write_text('plugins = { "security-guidance@claude-plugins-official" = { enabled = true } }\n')
        first = self.config.read_bytes()
        result = self.run_repair(expect=1)
        self.assertIn("Cannot safely disable", result.stderr)
        self.assertIn("security-guidance", result.stderr)
        self.assertEqual(first, self.config.read_bytes())
        self.assertEqual(result.stdout, "")

    def test_inline_skills_layout_cannot_report_unapplied_disables(self):
        self.skill("same")
        self.config.write_text('skills = { max_context_tokens = 4000 }\n[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        first = self.config.read_bytes()
        result = self.run_repair(expect=1)
        self.assertIn("Cannot safely disable skills", result.stderr)
        self.assertEqual(first, self.config.read_bytes())
        self.assertEqual(result.stdout, "")

    def test_embedded_skills_table_example_cannot_be_edited_as_config(self):
        for delimiter in ('"""', "'''"):
            with self.subTest(delimiter=delimiter):
                original = 'developer_instructions = ' + delimiter + '\nShow this example when asked:\n[skills]\nmax_context_tokens = 4000\n' + delimiter + '\nmodel = "custom-model"\n'
                self.config.write_text(original)
                result = self.run_repair(expect=1)
                self.assertIn("Cannot safely", result.stderr)
                self.assertEqual(self.config.read_text(), original)
                self.assertEqual(result.stdout, "")

    def test_user_comments_survive_managed_entry_refresh(self):
        self.skill("same")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        self.run_repair()
        self.config.write_text(self.config.read_text().replace("enabled = false\n", "enabled = false # temporary opt-out\n# preserve my explanation\n") + '\n# model selection rationale\n[profiles.work]\nmodel = "work-model"\n')
        self.run_repair()
        for note in ("# temporary opt-out", "# preserve my explanation", "# model selection rationale"):
            self.assertEqual(self.config.read_text().count(note), 1)
        first = self.config.read_bytes()
        self.run_repair()
        self.assertEqual(first, self.config.read_bytes())

    def test_legacy_requires_counterpart_in_every_cached_version(self):
        self.skill("new-only")
        self.skill("old-only")
        cache = self.codex / "plugins/cache/dotfiles-workflows/ecc"
        self.write(cache / "1.0.0/skills/old-only/SKILL.md", "old cached skill")
        (self.canonical / "skills/old-only/SKILL.md").unlink()
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        self.assertNotIn("config", self.run_repair()["skills"])

    def test_concurrent_cooperating_writer_preserves_user_override(self):
        self.skill("same")
        self.config.write_text('[plugins."ecc@dotfiles-workflows"]\nenabled = true\n')
        code = '''
import importlib.util
from pathlib import Path
import sys
import time
spec = importlib.util.spec_from_file_location("surfaces", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = Path(sys.argv[2])
with module.config_lock(config):
    before = config.read_text()
    print("locked", flush=True)
    time.sleep(0.3)
    after = before + '[skills]\\nmax_context_tokens = 4000\\n[[skills.config]]\\nname = "same"\\nenabled = true\\n'
    module.atomic_replace(config, before, after)
'''
        writer = subprocess.Popen([sys.executable, "-c", code, os.environ["CODEX_SURFACES_SCRIPT"], str(self.config)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: writer.kill() if writer.poll() is None else None)
        self.assertEqual(writer.stdout.readline().strip(), "locked")
        result = self.run_repair()
        _, errors = writer.communicate(timeout=5)
        self.assertEqual(writer.returncode, 0, errors)
        self.assertEqual(result["skills"]["max_context_tokens"], 4000)
        self.assertEqual(result["skills"]["config"], [{"name": "same", "enabled": True}])


unittest.main(verbosity=2)
PY
