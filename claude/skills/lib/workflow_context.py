"""Safe, metadata-only repository and account context for workflow helpers.

``repository_context`` identifies the checkout that a caller is operating in.
Its ``repo_id`` is derived from Git's shared common directory, so linked
worktrees share one identity without treating a Git metadata parent as a
checkout. ``primary_root`` is nullable when Git cannot prove an owner checkout.

``account_scope`` keeps two boundaries explicit.  ``root`` and ``scope_id``
describe the selected runtime configuration.  ``account_root`` and
``account_id`` describe the Claude account policy that authorizes shared
payloads, independently of whether the caller runs Claude or Codex.  Account
policy is routing metadata, not credential attestation; this module never
reads authentication files.
"""

from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import secrets
import stat
import subprocess
from pathlib import Path

_GIT_LOCATION_PREFIX = "GIT_"


def _resolved(path: str | Path) -> Path:
    """Return an absolute path without requiring it to exist."""
    return Path(path).expanduser().resolve()


def _inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def _digest(*parts: str) -> str:
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()


def account_id_for_root(root: str | Path) -> str:
    """Identify a previously selected account root; does not authorize its use."""
    return _digest("claude-account", str(_resolved(root)))


def git(cwd: str | Path, *args: str) -> str:
    """Run a checked Git probe with all inherited Git location state removed."""
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(_GIT_LOCATION_PREFIX)
    }
    result = subprocess.run(
        ["git", "-C", str(cwd), *args],
        env=environment,
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    return result.stdout.rstrip("\n")


def _git_path(cwd: str | Path, value: str) -> Path:
    path = Path(value)
    return _resolved(path if path.is_absolute() else Path(cwd) / path)


def _primary_worktree(
    cwd: str | Path, root: Path, common_dir: Path
) -> tuple[Path | None, bool]:
    """Read Git's NUL-delimited inventory without losing paths containing spaces."""
    git_dir = _git_path(cwd, git(cwd, "rev-parse", "--absolute-git-dir"))
    if git_dir == common_dir:
        # A primary checkout with a separate Git directory has no checkout
        # path in Git's inventory: its first record is the metadata directory.
        return root, True
    inventory = git(cwd, "worktree", "list", "--porcelain", "-z")
    for field in inventory.split("\0"):
        if field.startswith("worktree "):
            primary = _resolved(field.removeprefix("worktree "))
            if primary == common_dir:
                # Git stores no primary checkout path for a linked worktree
                # whose owner uses --separate-git-dir. Do not infer one from
                # the metadata location or route an inherited work account.
                return None, False
            return primary, True
    return None, False


def repository_context(cwd: str | Path) -> dict:
    """Return repository metadata, including nullable ``primary_root`` and its proof flag."""
    root = _resolved(git(cwd, "rev-parse", "--show-toplevel"))
    common_dir = _git_path(cwd, git(cwd, "rev-parse", "--git-common-dir"))
    primary_root, primary_known = _primary_worktree(cwd, root, common_dir)
    try:
        head = git(cwd, "rev-parse", "--verify", "HEAD")
    except subprocess.CalledProcessError:
        # A newly initialized checkout still has useful ownership metadata.
        head = ""
    return {
        "root": str(root),
        "primary_root": str(primary_root) if primary_root is not None else None,
        "primary_known": primary_known,
        "common_dir": str(common_dir),
        "repo_id": _digest("repository", str(common_dir)),
        "branch": git(cwd, "branch", "--show-current"),
        "head": head,
    }


def _claude_policy(cwd: str | Path, *, personal: bool) -> tuple[str, Path, dict, bool]:
    """Return account policy and whether repository ownership is personal."""
    home = _resolved(os.environ.get("HOME", str(Path.home())))
    personal_root = _resolved(home / "Git" / "personal")
    work_root = _resolved(os.environ.get("CLAUDE_WORK_TREE", home / "Git" / "work"))
    personal_config = _resolved(home / ".claude")
    work_config = _resolved(
        os.environ.get("CLAUDE_WORK_CONFIG_DIR", home / ".claude-work")
    )
    try:
        context = repository_context(cwd)
    except subprocess.CalledProcessError:
        context = None
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        raise ValueError("Git context is unavailable") from exc
    checkout = _resolved(context["root"] if context is not None else cwd)
    if os.environ.get("CLAUDE_PERSONAL_ONLY") == "1" or _inside(
        checkout, personal_root
    ):
        return "personal", personal_config, {"CLAUDE_CONFIG_DIR": None}, True

    owners = (
        tuple(_resolved(context[key]) for key in ("root", "primary_root", "common_dir"))
        if context is not None and context["primary_known"]
        else (checkout,)
    )
    if any(_inside(owner, personal_root) for owner in owners):
        return "personal", personal_config, {"CLAUDE_CONFIG_DIR": None}, True

    # A scoped personal account does not turn a work repository into a personal
    # repository. Keep plugin policy independent from a quota/account override.
    if personal or os.environ.get("WORKFLOW_PERSONAL_ACCOUNT") == "1":
        return "personal", personal_config, {"CLAUDE_CONFIG_DIR": None}, False

    explicit = os.environ.get("CLAUDE_CONFIG_DIR")
    if explicit:
        config = _resolved(explicit)
        if config == personal_config:
            return "personal", personal_config, {"CLAUDE_CONFIG_DIR": None}, False

    if context is not None and not context["primary_known"]:
        raise ValueError("canonical repository owner is ambiguous")

    if explicit:
        config = _resolved(explicit)
        kind = "work" if config == work_config else "custom"
        return kind, config, {"CLAUDE_CONFIG_DIR": str(config)}, False

    if any(_inside(owner, work_root) for owner in owners):
        return "work", work_config, {"CLAUDE_CONFIG_DIR": str(work_config)}, False
    return "personal", personal_config, {"CLAUDE_CONFIG_DIR": None}, False


def main(argv: list[str] | None = None) -> int:
    """Emit account context as JSON for shell launchers without shell evaluation."""
    parser = argparse.ArgumentParser(prog="workflow_context.py")
    subparsers = parser.add_subparsers(dest="command", required=True)
    scope_parser = subparsers.add_parser("account-scope")
    scope_parser.add_argument("--cwd", required=True)
    scope_parser.add_argument("--runtime", required=True, choices=("claude", "codex"))
    scope_parser.add_argument("--personal", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = account_scope(args.cwd, args.runtime, personal=args.personal)
    except (ValueError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
    print(json.dumps(result, sort_keys=True))
    return 0


def account_scope(cwd: str | Path, runtime: str, personal: bool = False) -> dict:
    """Return a metadata-only account scope for ``claude`` or ``codex``.

    Stable dict keys are ``runtime``, ``kind``, ``root``, ``scope_id``,
    ``account_root``, ``account_id``, and ``launch_env``.  Callers apply a
    ``None`` launch environment value by removing that variable from a child
    process environment.  In particular, native personal Claude must receive
    an unset ``CLAUDE_CONFIG_DIR`` rather than an explicit personal path.
    Ambiguous owner identity raises ``ValueError`` before work/custom routing.
    """
    runtime = runtime.lower()
    if runtime not in {"claude", "codex"}:
        raise ValueError(f"unsupported runtime: {runtime}")

    kind, account_root, claude_environment, personal_repository = _claude_policy(
        cwd, personal=personal
    )
    home = _resolved(os.environ.get("HOME", str(Path.home())))
    explicit = os.environ.get("CODEX_HOME")
    codex_root = _resolved(explicit) if explicit else _resolved(home / ".codex")
    root = account_root if runtime == "claude" else codex_root
    # A reused pane can retain another runtime home or account selector.
    # Bind both runtimes so a later partner launch reproduces the same scope.
    launch_env = {
        **claude_environment,
        "CODEX_HOME": str(codex_root),
        "CLAUDE_PERSONAL_ONLY": (
            "1" if os.environ.get("CLAUDE_PERSONAL_ONLY") == "1" else None
        ),
        "WORKFLOW_PERSONAL_ACCOUNT": "1" if kind == "personal" else None,
    }

    return {
        "runtime": runtime,
        "kind": kind,
        "root": str(root),
        "scope_id": _digest("runtime", runtime, str(root)),
        "account_root": str(account_root),
        "account_id": account_id_for_root(account_root),
        "launch_env": launch_env,
        "personal_repository": personal_repository,
    }


def open_state_parent(path: str | Path, create: bool = False) -> tuple[int, str]:
    """Open a state parent through held no-follow directory fds.

    The caller owns and must close the returned descriptor.  Missing path
    components raise ``FileNotFoundError`` unless ``create`` is true.
    """
    target = Path(path).expanduser()
    if not target.name or ".." in target.parts:
        raise ValueError("state path must be a file without parent traversal")
    if target.is_absolute():
        descriptor = os.open(target.anchor, os.O_RDONLY | os.O_DIRECTORY)
        parts = target.parts[1:-1]
    else:
        descriptor = os.open(".", os.O_RDONLY | os.O_DIRECTORY)
        parts = target.parts[:-1]
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0)
    try:
        for part in parts:
            try:
                child = os.open(part, flags, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    raise
                try:
                    os.mkdir(part, mode=0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
                try:
                    child = os.open(part, flags, dir_fd=descriptor)
                except OSError as exc:
                    if exc.errno in {errno.ELOOP, errno.ENOTDIR}:
                        raise ValueError("state path contains a symlink") from exc
                    raise
            except OSError as exc:
                if exc.errno in {errno.ELOOP, errno.ENOTDIR}:
                    raise ValueError("state path contains a symlink") from exc
                raise
            os.close(descriptor)
            descriptor = child
        return descriptor, target.name
    except BaseException:
        os.close(descriptor)
        raise


def _open_temporary(parent: int, name: str) -> tuple[int, str]:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    for _ in range(100):
        temporary = f".{name}.{secrets.token_hex(16)}.tmp"
        try:
            return os.open(temporary, flags, 0o600, dir_fd=parent), temporary
        except FileExistsError:
            continue
    raise OSError(errno.EEXIST, "could not allocate unique state file")


def _basename(name: str) -> str:
    if not isinstance(name, str) or not name or name in {".", ".."}:
        raise ValueError("state name must be a basename")
    separators = {os.sep}
    if os.altsep:
        separators.add(os.altsep)
    if any(separator in name for separator in separators):
        raise ValueError("state name must be a basename")
    return name


def atomic_json_at(
    parent_fd: int, name: str, data: dict, exclusive: bool = False
) -> None:
    """Atomically publish JSON in an open directory without closing its fd."""
    name = _basename(name)
    try:
        existing = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        existing = None
    if existing is not None and stat.S_ISLNK(existing.st_mode):
        raise ValueError("state path is a symlink")
    descriptor, temporary = _open_temporary(parent_fd, name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(data, output, sort_keys=True, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        if exclusive:
            os.link(
                temporary,
                name,
                src_dir_fd=parent_fd,
                dst_dir_fd=parent_fd,
                follow_symlinks=False,
            )
        else:
            os.replace(temporary, name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        os.fsync(parent_fd)
    finally:
        try:
            os.unlink(temporary, dir_fd=parent_fd)
        except FileNotFoundError:
            pass


def atomic_json(path: str | Path, data: dict, exclusive: bool = False) -> None:
    """Atomically publish JSON, optionally failing if another writer won first."""
    parent, name = open_state_parent(path, create=True)
    try:
        atomic_json_at(parent, name, data, exclusive=exclusive)
    finally:
        os.close(parent)


if __name__ == "__main__":
    raise SystemExit(main())
