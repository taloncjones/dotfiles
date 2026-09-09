#!/usr/bin/env python3
"""Repair proven Codex surface conflicts without changing Claude or skill files."""

from __future__ import annotations

import argparse
import ast
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
from contextlib import contextmanager, nullcontext
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    print(
        "[X] Codex surface repair needs Python 3.11+. Run it with 'uv run --python 3.11 --no-project python'.",
        file=sys.stderr,
    )
    raise SystemExit(1) from None


SECURITY_PLUGIN = "security-guidance@claude-plugins-official"
ECC_PLUGIN = "ecc@dotfiles-workflows"
INERT_PLUGINS = ("code-review", "code-simplifier")
MANAGED_BLOCK = re.compile(
    r"(?ms)^# dotfiles-managed: (legacy-copy|legacy-command|ecc-focus)"
    r"(?: sha256=([a-f0-9]{64}))?\n\[\[skills.config\]\]\n"
    r"(.*?)(?=^\[|^# dotfiles-managed:|\Z)"
)


def incompatible_security_hook(root: Path) -> bool:
    """Recognize the Claude async handshake followed by a second JSON response."""
    if (root / ".codex-plugin/plugin.json").exists():
        return False
    try:
        hooks = json.loads((root / "hooks/hooks.json").read_text())
        commands = [
            hook.get("command", "")
            for group in hooks.get("hooks", {}).get("SessionStart", [])
            for hook in group.get("hooks", [])
            if hook.get("type") == "command"
        ]
        known_command = (
            'bash "${CLAUDE_PLUGIN_ROOT}/hooks/sg-python.sh" '
            '"${CLAUDE_PLUGIN_ROOT}/hooks/ensure_agent_sdk.py"'
        )
        if known_command not in commands:
            return False
        tree = ast.parse((root / "hooks/ensure_agent_sdk.py").read_text())
    except (OSError, ValueError, SyntaxError, AttributeError, TypeError):
        return False
    # Recognize only upstream's first unconditional __main__ handshake. Do not
    # infer whether later prints execute after a custom prelude or control flow.
    main_guard = ast.dump(ast.parse("__name__ == '__main__'", mode="eval").body)
    entrypoints = [
        statement
        for statement in tree.body
        if isinstance(statement, ast.If) and ast.dump(statement.test) == main_guard
    ]
    if len(entrypoints) != 1 or entrypoints[0].orelse:
        return False
    statements = entrypoints[0].body
    if not isinstance(statements[0], ast.Expr):
        return False
    calls = [
        statement.value
        for statement in statements
        if isinstance(statement, ast.Expr) and isinstance(statement.value, ast.Call)
    ]
    json_prints = [
        node
        for node in calls
        if isinstance(node.func, ast.Name)
        and node.func.id == "print"
        and node.args
        and isinstance(node.args[0], ast.Call)
        and isinstance(node.args[0].func, ast.Attribute)
        and ast.unparse(node.args[0].func) == "json.dumps"
    ]
    if len(json_prints) < 2 or json_prints[0] is not statements[0].value:
        return False
    call = json_prints[0].args[0]
    if not call.args or not isinstance(call.args[0], ast.Dict):
        return False
    try:
        return ast.literal_eval(call.args[0]).get("async") is True
    except (ValueError, TypeError):
        return False


def disable_plugin(text: str, plugin: str) -> str:
    table = re.compile(
        r"(?m)^\s*\[plugins\.([\"'])" + re.escape(plugin) + r"\1\]\s*(?:#.*)?$"
    )
    match = table.search(text)
    if not match:
        return text
    tail = text[match.end() :]
    next_table = re.search(r"(?m)^\s*\[", tail)
    end = match.end() + next_table.start() if next_table else len(text)
    section = re.sub(
        r"(?m)^(\s*enabled\s*=\s*)true(\s*(?:#.*)?)$",
        r"\1false\2",
        text[match.end() : end],
    )
    return text[: match.end()] + section + text[end:]


def inert_claude_plugin(root: Path) -> bool:
    if not (root / ".claude-plugin/plugin.json").is_file():
        return False
    if any(
        (root / name).exists()
        for name in (".codex-plugin", ".mcp.json", "hooks", "skills")
    ):
        return False
    try:
        manifest = json.loads((root / ".claude-plugin/plugin.json").read_text())
    except (OSError, ValueError):
        return False
    return (
        not any(manifest.get(key) for key in ("skills", "mcpServers", "hooks"))
        and not any(root.rglob("SKILL.md"))
        and any((root / name).is_dir() for name in ("commands", "agents"))
    )


def unsupported_plugins(data: dict, codex: Path) -> list[str]:
    disabled = []
    for name in ("security-guidance", *INERT_PLUGINS):
        plugin = f"{name}@claude-plugins-official"
        if data.get("plugins", {}).get(plugin, {}).get("enabled") is not True:
            continue
        cache = codex / "plugins/cache/claude-plugins-official" / name
        versions = [path for path in cache.glob("*") if path.is_dir()]
        incompatible = (
            incompatible_security_hook
            if name == "security-guidance"
            else inert_claude_plugin
        )
        # Any unknown/newer cached version may be compatible: leave it alone.
        if versions and all(incompatible(path) for path in versions):
            disabled.append(plugin)
    return disabled


def file_tree(root: Path) -> dict[str, tuple[str, str]] | None:
    """Use Git blob identities and executable modes; reject symlink/custom trees."""
    if not root.is_dir() or root.is_symlink():
        return None
    result = {}
    try:
        for path in root.rglob("*"):
            if path.is_symlink():
                return None
            if path.is_dir():
                continue
            if not path.is_file():
                return None
            content = path.read_bytes()
            blob = hashlib.sha1(
                f"blob {len(content)}\0".encode() + content, usedforsecurity=False
            ).hexdigest()
            mode = "100755" if path.stat().st_mode & 0o111 else "100644"
            result[path.relative_to(root).as_posix()] = (mode, blob)
    except OSError:
        return None
    return result


def git_read(repo: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, timeout=15, check=False
    )
    return result.stdout if result.returncode == 0 else b""


def tree_signature(tree: dict) -> str:
    return hashlib.sha256(json.dumps(tree, sort_keys=True).encode()).hexdigest()


def legacy_migration_text(text: str) -> str:
    """Recognize the old importer's rewrite; never apply it to installed files."""
    return re.sub(
        r"claude(?:[ -]code)?",
        "Codex",
        text.replace("CLAUDE.md", "AGENTS.md"),
        flags=re.IGNORECASE,
    )


def translated_tree_matches(repo: Path, snapshot: dict, expected: dict) -> bool:
    if snapshot.keys() != expected.keys():
        return False
    for path, (mode, blob) in snapshot.items():
        if mode != expected[path][0]:
            return False
        content = git_read(repo, "cat-file", "blob", blob)
        if (
            hashlib.sha1(
                f"blob {len(content)}\0".encode() + content, usedforsecurity=False
            ).hexdigest()
            != blob
        ):
            return False
        try:
            content = legacy_migration_text(content.decode()).encode()
        except UnicodeDecodeError:
            pass
        translated = hashlib.sha1(
            f"blob {len(content)}\0".encode() + content, usedforsecurity=False
        ).hexdigest()
        if translated != expected[path][1]:
            return False
    return True


def managed_provenance(text: str) -> dict[str, str]:
    proven = {}
    for match in MANAGED_BLOCK.finditer(text):
        entry = tomllib.loads("[[skills.config]]\n" + match[3])["skills"]["config"][0]
        if (
            match[2]
            and entry.get("enabled") is False
            and set(entry) == {"path", "enabled"}
        ):
            proven[entry["path"]] = match[2]
    return proven


def historical_match(repo: Path, name: str, expected: dict) -> bool:
    if not (repo / ".git").exists():
        return False
    prefix = f"skills/{name}/"
    try:
        commits = git_read(repo, "log", "--all", "-64", "--format=%H", "--", prefix)
        for commit in commits.decode().splitlines():
            entries = git_read(repo, "ls-tree", "-r", "-z", commit, "--", prefix)
            snapshot = {}
            for entry in entries.split(b"\0"):
                if not entry:
                    continue
                metadata, path = entry.decode().split("\t", 1)
                mode, kind, blob = metadata.split()
                if kind != "blob" or mode not in ("100644", "100755"):
                    break
                snapshot[path.removeprefix(prefix)] = (mode, blob)
            else:
                if snapshot == expected or translated_tree_matches(
                    repo, snapshot, expected
                ):
                    return True
    except (OSError, UnicodeError, ValueError, subprocess.TimeoutExpired):
        return False
    return False


def explicit_skill_override(entries: list, skill: Path, config: Path) -> bool:
    for entry in entries:
        if entry.get("name") in (skill.name, legacy_migration_text(skill.name)):
            return True
        if entry.get("path"):
            path = Path(entry["path"]).expanduser()
            resolved = (path if path.is_absolute() else config.parent / path).resolve()
            if resolved in (skill.resolve(), (skill / "SKILL.md").resolve()):
                return True
    return False


def legacy_duplicates(
    data: dict, codex: Path, skills: Path, repo: Path, proven: dict
) -> list[Path]:
    if data.get("plugins", {}).get(ECC_PLUGIN, {}).get("enabled") is not True:
        return []
    versions = [
        path / "skills"
        for path in (codex / "plugins/cache/dotfiles-workflows/ecc").glob("*")
        if path.is_dir()
    ]
    if not versions or not skills.is_dir():
        return []
    overrides = data.get("skills", {}).get("config", [])
    duplicates = []
    for skill in sorted(skills.iterdir()):
        # Cache directory order/version numbers do not identify the active
        # plugin. Require a replacement under every possible cached version.
        if not all(
            (version / skill.name / "SKILL.md").is_file() for version in versions
        ):
            continue
        if explicit_skill_override(overrides, skill, codex / "config.toml"):
            continue
        tree = file_tree(skill)
        if not tree or "SKILL.md" not in tree:
            continue
        if (
            proven.get(str(skill / "SKILL.md")) == tree_signature(tree)
            or any(tree == file_tree(version / skill.name) for version in versions)
            or tree == file_tree(repo / "skills" / skill.name)
            or historical_match(repo, skill.name, tree)
        ):
            duplicates.append(skill / "SKILL.md")
    return duplicates


def translated_command(content: str, name: str) -> str | None:
    """Recreate the exact wrapper used for old imported slash commands."""
    match = re.match(r"\A---\n(.*?)\n---\n(.*)\Z", content, re.DOTALL)
    if not match:
        return None
    description = re.search(r"(?m)^description: (.+)$", match[1])
    if not description:
        return None
    value = description[1]
    if value.startswith('"'):
        try:
            value = json.loads(value)
        except ValueError:
            return None
    skill = f"source-command-{name}"
    return (
        f"---\nname: {json.dumps(skill)}\ndescription: {json.dumps(value)}\n---\n\n"
        f"# {skill}\n\nUse this skill when the user asks to run the migrated source command `{name}`.\n\n"
        f"## Command Template\n\n{match[2].strip()}\n"
    )


def imported_commands(
    data: dict, codex: Path, skills: Path, repo: Path, proven: dict
) -> list[Path]:
    if data.get("plugins", {}).get(ECC_PLUGIN, {}).get("enabled") is not True:
        return []
    disabled = []
    for skill in sorted(skills.glob("source-command-*")):
        if explicit_skill_override(
            data.get("skills", {}).get("config", []), skill, codex / "config.toml"
        ):
            continue
        tree = file_tree(skill)
        if not tree or set(tree) != {"SKILL.md"}:
            continue
        if proven.get(str(skill / "SKILL.md")) == tree_signature(tree):
            disabled.append(skill / "SKILL.md")
            continue
        name = skill.name.removeprefix("source-command-")
        source_path = f"commands/{name}.md"
        try:
            command = repo / source_path
            versions = [command.read_text()] if command.is_file() else []
            commits = git_read(
                repo, "log", "--all", "-64", "--format=%H", "--", source_path
            )
            versions += [
                git_read(repo, "show", f"{commit}:{source_path}").decode()
                for commit in commits.decode().splitlines()
            ]
            existing = (skill / "SKILL.md").read_text()
            for content in versions:
                wrapper = translated_command(content, name)
                if wrapper is not None and existing in (
                    wrapper,
                    legacy_migration_text(wrapper),
                ):
                    disabled.append(skill / "SKILL.md")
                    break
        except (OSError, UnicodeError, subprocess.TimeoutExpired):
            continue
    return disabled


def focused_skills(data: dict, codex: Path, catalog: Path) -> list[Path]:
    if data.get("plugins", {}).get(ECC_PLUGIN, {}).get("enabled") is not True:
        return []
    keep = {
        line.strip()
        for line in catalog.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    }
    if not keep:
        raise ValueError("The ECC focus catalog is empty")
    candidates = (codex / "plugins/cache/dotfiles-workflows/ecc").glob("*/skills/*")
    return sorted(
        skill / "SKILL.md"
        for skill in candidates
        if (skill / "SKILL.md").is_file()
        and skill.name not in keep
        and not explicit_skill_override(
            data.get("skills", {}).get("config", []), skill, codex / "config.toml"
        )
        and not any(
            entry.get("name") == f"ecc:{skill.name}"
            for entry in data.get("skills", {}).get("config", [])
        )
    )


def clear_managed_disabled(text: str) -> str:
    def preserve_override(match: re.Match) -> str:
        entry = tomllib.loads("[[skills.config]]\n" + match[3])["skills"]["config"][0]
        if set(entry) == {"path", "enabled"} and entry["enabled"] is False:
            return preserve_managed_comments(match)
        return match[0]

    return MANAGED_BLOCK.sub(preserve_override, text)


def preserve_managed_comments(match: re.Match) -> str:
    """Remove our two simple fields, retaining user notes in the same span."""
    field = re.compile(
        r"[ \t]*(?:path[ \t]*=[ \t]*(?:\"(?:[^\"\\]|\\.)*\"|'[^']*')"
        r"|enabled[ \t]*=[ \t]*false)[ \t]*(?P<comment>\#.*)?(?:\n|\Z)"
    )
    kept = []
    removed = 0
    for line in match[3].splitlines(keepends=True):
        parsed = field.fullmatch(line)
        if parsed:
            removed += 1
            if parsed["comment"]:
                kept.append(parsed["comment"] + "\n")
        else:
            kept.append(line)
    # A user changed the field layout (for example to a multiline string).
    # Leave the entire entry intact instead of partially removing TOML.
    return "".join(kept) if removed == 2 else match[0]


def add_skill_settings(text: str, data: dict, disabled: dict[str, list[Path]]) -> str:
    settings = data.get("skills", {})
    # Inline tables cannot be extended elsewhere in TOML. Preserve this valid
    # user layout instead of rewriting it or producing a conflicting table.
    if re.search(r"(?m)^skills\s*=\s*\{", text):
        return text
    if "max_context_tokens" not in settings:
        match = re.search(r"(?m)^\s*\[skills\]\s*(?:#.*)?$", text)
        if match:
            text = (
                text[: match.end()]
                + "\nmax_context_tokens = 10000"
                + text[match.end() :]
            )
        else:
            text = text.rstrip() + "\n\n[skills]\nmax_context_tokens = 10000\n"
    for reason, paths in disabled.items():
        for path in paths:
            provenance = (
                f" sha256={tree_signature(file_tree(path.parent))}"
                if reason != "ecc-focus"
                else ""
            )
            text = text.rstrip() + (
                f"\n\n# dotfiles-managed: {reason}{provenance}\n[[skills.config]]\n"
                f"path = {json.dumps(str(path))}\n"
                "enabled = false\n"
            )
    return text


def atomic_replace(config: Path, before: str, after: str) -> None:
    tomllib.loads(after)
    if after == before:
        return
    mode = stat.S_IMODE(config.stat().st_mode)
    descriptor, filename = tempfile.mkstemp(
        prefix=f".{config.name}.", dir=config.parent
    )
    temporary = Path(filename)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(after)
        temporary.chmod(mode)
        if config.read_text() != before:
            raise ValueError(
                "Codex config changed during repair; retry after the writer finishes"
            )
        os.replace(temporary, config)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def config_lock(config: Path):
    """Serialize helper writers; native Codex writers do not honor this lock."""
    path = config.with_name(f".{config.name}.dotfiles.lock")
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def unrelated_config(data: dict, plugins: list[str]) -> dict:
    """Exclude only fields this repair is allowed to change from comparison."""
    return {
        **{
            key: value
            for key, value in data.items()
            if key not in ("skills", "plugins")
        },
        "skills": {
            key: value
            for key, value in data.get("skills", {}).items()
            if key not in ("config", "max_context_tokens")
        },
        "plugins": {
            plugin: {key: value for key, value in settings.items() if key != "enabled"}
            if plugin in plugins
            else settings
            for plugin, settings in data.get("plugins", {}).items()
        },
    }


def repair_config(args: argparse.Namespace, config: Path) -> dict:
    before = config.read_text()
    original = tomllib.loads(before)
    proven = managed_provenance(before)
    after = clear_managed_disabled(before)
    data = tomllib.loads(after)
    focus = args.focus or "# dotfiles-managed: ecc-focus\n" in before
    disabled = {
        "legacy-copy": legacy_duplicates(
            data, args.codex_home, args.agents_skills, args.ecc_repo, proven
        )
    }
    if focus:
        disabled["legacy-command"] = imported_commands(
            data, args.codex_home, args.agents_skills, args.ecc_repo, proven
        )
        disabled["ecc-focus"] = focused_skills(data, args.codex_home, args.catalog)
    plugins = unsupported_plugins(data, args.codex_home)
    for plugin in plugins:
        after = disable_plugin(after, plugin)
    after = add_skill_settings(after, data, disabled)
    result = tomllib.loads(after)
    expected_budget = original.get("skills", {}).get("max_context_tokens", 10000)
    if result.get("skills", {}).get("max_context_tokens") != expected_budget:
        raise ValueError(
            "Cannot safely set the skill budget in this TOML layout; config was not changed."
        )
    if unrelated_config(original, plugins) != unrelated_config(result, plugins):
        raise ValueError(
            "Cannot safely repair this TOML layout without changing unrelated values; config was not changed."
        )
    for plugin in plugins:
        if result.get("plugins", {}).get(plugin, {}).get("enabled") is not False:
            raise ValueError(
                f"Cannot safely disable {plugin} in this TOML layout; "
                'config was not changed. Use a [plugins."plugin-id"] table.'
            )
    configured_paths = {
        entry.get("path")
        for entry in result.get("skills", {}).get("config", [])
        if entry.get("enabled") is False
    }
    if any(
        str(path) not in configured_paths
        for paths in disabled.values()
        for path in paths
    ):
        raise ValueError(
            "Cannot safely disable skills in this TOML layout; config was not changed. "
            "Use a [skills] table instead of an inline table."
        )
    if args.apply:
        atomic_replace(config, before, after)
    return {
        "changed": after != before,
        "applied": args.apply,
        "disabled_plugins": plugins,
        "focus": focus,
        "skill_counts": {reason: len(paths) for reason, paths in disabled.items()},
        "disabled_skill_paths": [
            str(path) for paths in disabled.values() for path in paths
        ],
        "max_context_tokens": result.get("skills", {}).get("max_context_tokens"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--codex-home",
        type=Path,
        default=Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")),
    )
    parser.add_argument(
        "--agents-skills", type=Path, default=Path.home() / ".agents/skills"
    )
    parser.add_argument(
        "--ecc-repo", type=Path, default=Path.home() / "Git/personal/ECC"
    )
    parser.add_argument(
        "--focus",
        action="store_true",
        help="Use the focused ECC catalog; preserve all skill files",
    )
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path(__file__).resolve().parents[2] / "codex/ecc-skills.txt",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--apply", action="store_true", help="Apply the reported config repair"
    )
    mode.add_argument(
        "--check",
        action="store_true",
        help="Report proposed changes without writing (default)",
    )
    args = parser.parse_args()
    config = (args.codex_home / "config.toml").resolve()
    if not config.is_file():
        return 0
    try:
        with config_lock(config) if args.apply else nullcontext():
            report = repair_config(args, config)
        print(json.dumps(report, indent=2))
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        print(f"[X] Codex surface repair failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
