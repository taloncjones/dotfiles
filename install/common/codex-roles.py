#!/usr/bin/env python3
"""Migrate only proven historical Codex role snapshots, preserving custom state."""

from __future__ import annotations

import argparse
import errno
import fcntl
import hashlib
import json
import os
import stat
import sys
import tomllib
import uuid
from contextlib import ExitStack
from pathlib import Path

# SHA256 of ECC .codex/agents files at
# 06c376ae8b3a11bdafcb56c642b81480622740fc, before upstream eef31ad changed them.
# Deliberately recognize exact bytes, not arbitrary files using the old model.
ROLES = {
    "explorer": (
        "explorer.toml",
        "ba9d7a10cf04a9b25a35ae8fc094b840cceef624d542f45b9d7cf3cdc78126ab",
        "gpt-5.6-luna",
    ),
    "reviewer": (
        "reviewer.toml",
        "9edbc2b5334fed555f2e8001142fcd78938bd1de8355aeb020c0dd8f0315cd80",
        "gpt-6-astra",
    ),
    "docs_researcher": (
        "docs-researcher.toml",
        "e14712b0a5f5e7378819200a07b2867ff84607d7b7dccd222e6fe38da17533e4",
        "gpt-5.6-terra",
    ),
}
OLD_MODEL = b'model = "gpt-5.4"'
MAX_CONFIG_BYTES = 1 << 20


def identity(info: os.stat_result) -> tuple[int, int]:
    return info.st_dev, info.st_ino


def directory(path: str | Path, *, parent: int | None = None) -> int | None:
    """Open a directory without following its final symlink component."""
    try:
        return os.open(
            path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent
        )
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):
            return None
        raise


def read_regular(name: str, parent: int) -> tuple[bytes, os.stat_result] | None:
    """Read a bounded regular file without following symlinks or blocking on pipes."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ELOOP):
            return None
        raise
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            return None
        data = stream.read(MAX_CONFIG_BYTES + 1)
    if len(data) > MAX_CONFIG_BYTES:
        raise ValueError(f"Refusing oversized TOML file: {name}")
    return data, info


def parse_toml(data: bytes, name: str) -> dict:
    try:
        return tomllib.loads(data.decode("utf-8"))
    except (UnicodeError, tomllib.TOMLDecodeError) as exc:
        raise ValueError(f"Malformed TOML in {name}: {exc}") from exc


def classify_roles(root: int, agents: int, report: dict) -> tuple[bytes, list[dict]]:
    config_file = read_regular("config.toml", root)
    if config_file is None:
        report["preserved"] = dict.fromkeys(ROLES, "config-absent-or-not-regular")
        return b"", []
    config_bytes, _ = config_file
    mappings = parse_toml(config_bytes, "config.toml").get("agents", {})
    if not isinstance(mappings, dict):
        raise TypeError("Expected an agents table in config.toml")
    changes = []
    for role, (filename, expected_hash, model) in ROLES.items():
        mapping = mappings.get(role)
        if mapping is None:
            report["preserved"][role] = "unconfigured"
            continue
        if not isinstance(mapping, dict):
            raise TypeError(f"Expected a table for agents.{role}")
        if mapping.get("config_file") != f"agents/{filename}" or set(mapping) - {
            "config_file",
            "description",
        }:
            report["preserved"][role] = "custom-config-mapping"
            continue
        source = read_regular(filename, agents)
        if source is None:
            report["preserved"][role] = "role-absent-or-not-regular"
            continue
        before, info = source
        parse_toml(before, filename)
        replacement = f'model = "{model}"'.encode()
        if hashlib.sha256(before).hexdigest() == expected_hash:
            changes.append(
                {
                    "role": role,
                    "filename": filename,
                    "before": before,
                    "after": before.replace(OLD_MODEL, replacement, 1),
                    "identity": identity(info),
                    "mode": stat.S_IMODE(info.st_mode),
                }
            )
        elif (
            hashlib.sha256(before.replace(replacement, OLD_MODEL, 1)).hexdigest()
            == expected_hash
        ):
            report["preserved"][role] = "already-current"
        else:
            report["preserved"][role] = "custom-or-unknown-content"
    return config_bytes, changes


def unchanged(root: int, agents: int, config_bytes: bytes, changes: list[dict]) -> None:
    current = read_regular("config.toml", root)
    if current is None or current[0] != config_bytes:
        raise ValueError("Configuration changed during role migration")
    entry = os.stat("agents", dir_fd=root, follow_symlinks=False)
    if identity(entry) != identity(os.fstat(agents)) or not stat.S_ISDIR(entry.st_mode):
        raise ValueError("Agents directory changed during role migration")
    for change in changes:
        current = read_regular(change["filename"], agents)
        if (
            current is None
            or current[0] != change["before"]
            or identity(current[1]) != change["identity"]
        ):
            raise ValueError(f"Role changed during migration: {change['role']}")


def apply_changes(
    root: int, agents: int, config_bytes: bytes, changes: list[dict], report: dict
) -> None:
    """Stage all replacements before mutation; publish each file atomically."""
    staged = []
    try:
        for change in changes:
            temporary = f".codex-role-{uuid.uuid4().hex}.tmp"
            fd = os.open(
                temporary,
                os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW,
                0o600,
                dir_fd=agents,
            )
            staged.append((temporary, change))
            with os.fdopen(fd, "wb") as stream:
                stream.write(change["after"])
                stream.flush()
                os.fchmod(stream.fileno(), change["mode"])
                os.fsync(stream.fileno())
        unchanged(root, agents, config_bytes, changes)
        for temporary, change in staged:
            os.replace(
                temporary, change["filename"], src_dir_fd=agents, dst_dir_fd=agents
            )
            report["updated"].append(change["role"])
        os.fsync(agents)
    finally:
        for temporary, _ in staged:
            try:
                os.unlink(temporary, dir_fd=agents)
            except FileNotFoundError:
                pass


def migrate(codex_home: Path, check: bool, report: dict) -> None:
    with ExitStack() as stack:
        root = directory(codex_home)
        if root is None:
            report["preserved"] = dict.fromkeys(
                ROLES, "codex-home-absent-or-not-directory"
            )
            return
        stack.callback(os.close, root)
        agents = directory("agents", parent=root)
        if agents is None:
            report["preserved"] = dict.fromkeys(ROLES, "agents-absent-or-not-directory")
            return
        stack.callback(os.close, agents)
        # Directory locking creates no state files, including in --check mode.
        # It serializes concurrent invocations of this migration only.
        fcntl.flock(agents, fcntl.LOCK_EX)
        config_bytes, changes = classify_roles(root, agents, report)
        report["would_update"] = [change["role"] for change in changes]
        if changes and not check:
            apply_changes(root, agents, config_bytes, changes, report)
        report["changed"] = bool(changes)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    report = {
        "changed": False,
        "check": args.check,
        "updated": [],
        "would_update": [],
        "preserved": {},
    }
    try:
        migrate(args.codex_home, args.check, report)
    except (OSError, TypeError, ValueError) as exc:
        report["changed"] = bool(report["updated"])
        report["error"] = str(exc)
        print(json.dumps(report, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
