#!/usr/bin/env python3
"""Save and inspect explicit, account-private task handoffs without executing them."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time
import uuid
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
from workflow_context import (
    account_scope,
    atomic_json_at,
    git,
    open_state_parent,
    repository_context,
)

TASK_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
RECORD_PATTERN = re.compile(r"[0-9]{16,20}-[0-9a-f]{32}\Z")
SHA_PATTERN = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
MAX_BRIEF_BYTES = 1 << 20
MAX_RECORD_BYTES = 8 << 20
RECORD_KEYS = {
    "schema_version",
    "record_id",
    "task_id",
    "account_id",
    "source_runtime",
    "created_at",
    "repository",
    "base_sha",
    "base_source",
    "owner_id",
    "brief",
    "brief_sha256",
    "imported_from",
    "working_tree",
}


def identifier(value: str, pattern: re.Pattern, kind: str) -> str:
    if not pattern.fullmatch(value):
        raise ValueError(f"Invalid {kind}")
    return value


def encoded(data: dict) -> bytes:
    return (json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n").encode()


def inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def normalize_native_path(root: Path) -> Path:
    """Normalize only native macOS temporary-directory aliases."""
    if (
        root.is_absolute()
        and sys.platform == "darwin"
        and len(root.parts) > 1
        and root.parts[1] in {"tmp", "var"}
    ):
        alias = root.parts[1]
        if Path("/", alias).resolve() == Path("/private", alias):
            return Path("/private", *root.parts[1:])
    return root


def lexical_account_root(scope: dict) -> Path:
    """Return the selected Claude account directory without resolving links."""
    home = Path(os.environ.get("HOME", str(Path.home()))).expanduser().absolute()
    if scope["kind"] == "personal":
        root = home / ".claude"
    elif scope["kind"] == "work":
        root = (
            Path(
                os.environ.get("CLAUDE_CONFIG_DIR")
                or os.environ.get("CLAUDE_WORK_CONFIG_DIR")
                or home / ".claude-work"
            )
            .expanduser()
            .absolute()
        )
    else:
        root = (
            Path(os.environ.get("CLAUDE_CONFIG_DIR") or scope["account_root"])
            .expanduser()
            .absolute()
        )
    return normalize_native_path(root)


def validate_lexical_account_root(scope: dict) -> None:
    """Reject a selected account root whose lexical path traverses a link."""
    home = Path(os.environ.get("HOME", str(Path.home()))).expanduser().absolute()
    personal = normalize_native_path(home / ".claude")
    work = normalize_native_path(
        Path(os.environ.get("CLAUDE_WORK_CONFIG_DIR", home / ".claude-work"))
        .expanduser()
        .absolute()
    )
    if scope["kind"] in {"personal", "work"} and personal == work:
        raise ValueError("Selected account root aliases another account root")
    root = lexical_account_root(scope)
    try:
        parent, _ = open_state_parent(root / ".handoff-account-root", create=False)
    except FileNotFoundError:
        # A missing account directory is valid for a fresh native account. The
        # handoff state is stored separately and no path through this root is used.
        return
    except ValueError as exc:
        raise ValueError("Selected account root is a symlink") from exc
    else:
        os.close(parent)
    if scope["kind"] not in {"personal", "work"}:
        return
    try:
        aliases = os.path.samefile(personal, work)
    except FileNotFoundError:
        aliases = False
    if aliases:
        raise ValueError("Selected account root aliases another account root")


def state_directory(context: dict, scope: dict) -> Path:
    home = Path(os.environ.get("HOME", str(Path.home()))).expanduser()
    xdg = Path(os.environ.get("XDG_STATE_HOME", home / ".local/state")).expanduser()
    base = Path(
        os.environ.get(
            "DOTFILES_HANDOFF_STATE_DIR", xdg / "dotfiles/workflows/handoffs"
        )
    ).expanduser()
    base = normalize_native_path(base)
    if not base.is_absolute() or ".." in base.parts:
        raise ValueError(
            "Handoff state directory must be absolute without parent traversal"
        )
    for key in ("root", "primary_root", "common_dir"):
        if context.get(key) and inside(base.resolve(), Path(context[key]).resolve()):
            raise ValueError(
                "Handoff state must remain outside repository and Git directories"
            )
    return base / scope["account_id"] / context["repo_id"]


def read_at(parent: int, name: str, limit: int = MAX_RECORD_BYTES) -> bytes:
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
    descriptor = os.open(name, flags, dir_fd=parent)
    with os.fdopen(descriptor, "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError("Handoff input must be a regular file")
        content = source.read(limit + 1)
    if len(content) > limit:
        raise ValueError("Handoff input exceeds size limit")
    return content


def read_json_at(parent: int, name: str) -> tuple[dict, bytes]:
    content = read_at(parent, name)
    parsed = json.loads(content)
    if not isinstance(parsed, dict):
        raise TypeError("Handoff state must contain a JSON object")
    return parsed, content


def brief_content(path: Path, context: dict, scope: dict) -> str:
    resolved = normalize_native_path(path.expanduser().absolute())
    parent, name = open_state_parent(resolved, create=False)
    try:
        content = read_at(parent, name).decode("utf-8")
    finally:
        os.close(parent)
    if not content.strip():
        raise ValueError("Handoff brief must not be empty")
    if content.lstrip().startswith("{") or resolved.suffix == ".json":
        record = json.loads(content)
        if not isinstance(record, dict):
            raise ValueError("Structured handoff input must be a record")
        source_context = record.get("repository")
        if not isinstance(source_context, dict) or not isinstance(
            source_context.get("repo_id"), str
        ):
            raise ValueError("Structured handoff input lacks repository identity")
        # Explicit personal processing can import work history. Work/custom
        # processing requires the original record's account and repository.
        expected_context = context if scope["kind"] != "personal" else source_context
        expected_scope = (
            scope
            if scope["kind"] != "personal"
            else {"account_id": record.get("account_id")}
        )
        validate_record(
            record,
            expected_context,
            expected_scope,
            record.get("task_id"),
            record.get("record_id"),
        )
        content = record["brief"]
    elif scope["kind"] != "personal":
        try:
            source_context = repository_context(resolved.parent)
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            raise ValueError(
                "Unscoped legacy brief requires deliberate personal scope; "
                "author a new work brief inside the selected repository"
            ) from exc
        if source_context["repo_id"] != context["repo_id"]:
            raise ValueError("Handoff source belongs to another repository scope")
        source_scope = account_scope(resolved.parent, scope["runtime"])
        if source_scope["account_id"] != scope["account_id"]:
            raise ValueError("Handoff source belongs to another account scope")
    if len(content.encode()) > MAX_BRIEF_BYTES:
        raise ValueError("Handoff brief exceeds size limit")
    return content


def validate_record(
    record: dict, context: dict, scope: dict, task: str, record_id: str
) -> None:
    if (
        set(record) != RECORD_KEYS
        or type(record.get("schema_version")) is not int
        or record["schema_version"] != 1
    ):
        raise ValueError("Unsupported or malformed handoff record")
    repository = record.get("repository")
    if (
        not isinstance(repository, dict)
        or repository.get("repo_id") != context["repo_id"]
        or record.get("task_id") != task
        or record.get("account_id") != scope["account_id"]
        or record.get("record_id") != record_id
        or record.get("source_runtime") not in {"claude", "codex"}
    ):
        raise ValueError(
            "Handoff record belongs to another repository, task or account"
        )
    for value, pattern, kind in (
        (record.get("task_id"), TASK_PATTERN, "task ID"),
        (record.get("record_id"), RECORD_PATTERN, "record ID"),
        (record.get("account_id"), re.compile(r"[0-9a-f]{64}\Z"), "account ID"),
        (repository.get("repo_id"), re.compile(r"[0-9a-f]{64}\Z"), "repository ID"),
    ):
        if not isinstance(value, str):
            raise TypeError(f"Handoff record has invalid {kind}")
        identifier(value, pattern, kind)
    for field in (record.get("base_sha"), repository.get("head")):
        if not isinstance(field, str) or not SHA_PATTERN.fullmatch(field):
            raise ValueError("Handoff record has invalid Git identity")
    brief = record.get("brief")
    if not isinstance(brief, str) or hashlib.sha256(
        brief.encode()
    ).hexdigest() != record.get("brief_sha256"):
        raise ValueError("Handoff brief failed integrity verification")


def load_at(
    parent: int, context: dict, scope: dict, task: str, record_id: str | None = None
) -> tuple[dict, str]:
    expected_hash = None
    if record_id is None:
        pointer, _ = read_json_at(parent, "current.json")
        if (
            pointer.get("schema_version") != 1
            or pointer.get("task_id") != task
            or pointer.get("repo_id") != context["repo_id"]
            or pointer.get("account_id") != scope["account_id"]
        ):
            raise ValueError(
                "Handoff pointer belongs to another repository, task or account"
            )
        record_id = pointer.get("record_id")
        expected_hash = pointer.get("record_sha256")
        if not isinstance(expected_hash, str) or not re.fullmatch(
            r"[0-9a-f]{64}", expected_hash
        ):
            raise ValueError("Malformed handoff pointer digest")
    if not isinstance(record_id, str):
        raise TypeError("Malformed handoff record identity")
    identifier(record_id, RECORD_PATTERN, "record ID")
    record, content = read_json_at(parent, f"{record_id}.json")
    if (
        expected_hash is not None
        and hashlib.sha256(content).hexdigest() != expected_hash
    ):
        raise ValueError("Handoff record failed integrity verification")
    validate_record(record, context, scope, task, record_id)
    return record, record_id


@contextmanager
def task_lock(parent: int):
    flags = os.O_RDWR | os.O_NOFOLLOW
    try:
        # Concurrent non-exclusive creation can return ENOENT on macOS.
        descriptor = os.open(
            ".lock", flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent
        )
    except FileExistsError:
        descriptor = os.open(".lock", flags, dir_fd=parent)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError("Handoff task lock must be a regular file")
        deadline = time.monotonic() + 10
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Handoff task is busy") from None
                time.sleep(0.01)
        yield
    finally:
        os.close(descriptor)


def working_state(repo: Path) -> dict:
    probes = {
        "tracked_diff_sha256": (
            "diff",
            "--binary",
            "--no-ext-diff",
            "--no-textconv",
            "HEAD",
            "--",
        ),
        "index_diff_sha256": (
            "diff",
            "--cached",
            "--binary",
            "--no-ext-diff",
            "--no-textconv",
            "HEAD",
            "--",
        ),
        "status_sha256": ("status", "--porcelain=v1", "--untracked-files=normal", "-z"),
    }
    return {
        name: hashlib.sha256(git(repo, *args).encode()).hexdigest()
        for name, args in probes.items()
    }


def make_record(args, context: dict, scope: dict) -> dict:
    brief = brief_content(args.brief_file, context, scope)
    base = git(
        args.repo,
        "rev-parse",
        "--verify",
        "--end-of-options",
        f"{args.base or context['head']}^{{commit}}",
    )
    identifier(base, SHA_PATTERN, "base commit")
    working_tree = working_state(args.repo)
    if repository_context(args.repo) != context:
        raise ValueError("Repository changed while preparing handoff")
    return {
        "schema_version": 1,
        "record_id": f"{time.time_ns()}-{uuid.uuid4().hex}",
        "task_id": args.task,
        "account_id": scope["account_id"],
        "source_runtime": args.runtime,
        "created_at": datetime.now(UTC).isoformat(),
        "repository": context,
        "working_tree": working_tree,
        "base_sha": base,
        "base_source": "explicit" if args.base else "saved-head",
        "owner_id": args.owner_id,
        "brief": brief,
        "brief_sha256": hashlib.sha256(brief.encode()).hexdigest(),
        "imported_from": str(args.brief_file.expanduser().absolute()),
    }


def save(args, context: dict, scope: dict, directory: Path) -> dict:
    record = make_record(args, context, scope)
    parent, _ = open_state_parent(directory / args.task / "current.json", create=True)
    try:
        with task_lock(parent):
            try:
                os.stat("current.json", dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                load_at(parent, context, scope, args.task)
            record_id = record["record_id"]
            atomic_json_at(parent, f"{record_id}.json", record, exclusive=True)
            atomic_json_at(
                parent,
                "current.json",
                {
                    "schema_version": 1,
                    "task_id": args.task,
                    "repo_id": context["repo_id"],
                    "account_id": scope["account_id"],
                    "record_id": record_id,
                    "record_sha256": hashlib.sha256(encoded(record)).hexdigest(),
                },
            )
    finally:
        os.close(parent)
    return {
        "record": record,
        "record_path": str(directory / args.task / f"{record_id}.json"),
        "scope": scope,
    }


def load(args, context: dict, scope: dict, directory: Path) -> dict:
    parent, _ = open_state_parent(directory / args.task / "current.json", create=False)
    try:
        record, record_id = load_at(parent, context, scope, args.task, args.record)
    finally:
        os.close(parent)
    return {
        "record": record,
        "record_path": str(directory / args.task / f"{record_id}.json"),
        "scope": scope,
    }


def verify(args, context: dict, scope: dict, directory: Path) -> dict:
    result = load(args, context, scope, directory)
    record = result["record"]
    previous = record["repository"]
    drift = []
    for key, label in (("head", "head"), ("branch", "branch"), ("root", "worktree")):
        if previous.get(key) != context[key]:
            drift.append(label)
    if record["working_tree"] != working_state(args.repo):
        drift.append("working-tree")
    saved_owner = record.get("owner_id")
    owner_status = "unverified"
    if args.owner_id is not None and saved_owner is not None:
        owner_status = "unchanged" if args.owner_id == saved_owner else "changed"
    return {
        **result,
        "current_repository": context,
        "drift": drift,
        "git_status": "changed" if drift else "unchanged",
        "owner_status": owner_status,
        "observed_owner_id": args.owner_id,
    }


def list_tasks(context: dict, scope: dict, directory: Path) -> dict:
    try:
        parent, _ = open_state_parent(directory / "unused", create=False)
    except FileNotFoundError:
        return {"tasks": [], "scope": scope}
    tasks = []
    try:
        for task in sorted(os.listdir(parent)):
            if not TASK_PATTERN.fullmatch(task):
                continue
            child = None
            try:
                child = os.open(
                    task, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent
                )
                record, record_id = load_at(child, context, scope, task)
                tasks.append(
                    {
                        "task_id": task,
                        "record_id": record_id,
                        "created_at": record["created_at"],
                        "status": "ready",
                    }
                )
            except (OSError, TypeError, ValueError) as exc:
                tasks.append({"task_id": task, "status": "invalid", "error": str(exc)})
            finally:
                if child is not None:
                    os.close(child)
    finally:
        os.close(parent)
    return {"tasks": tasks, "scope": scope}


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("save", "load", "list", "verify"):
        command = commands.add_parser(name)
        command.add_argument("--repo", type=Path, required=True)
        command.add_argument("--runtime", choices=("claude", "codex"), required=True)
        command.add_argument("--personal", action="store_true")
        if name != "list":
            command.add_argument("--task", required=True)
        if name in {"load", "verify"}:
            command.add_argument("--record")
        if name in {"save", "verify"}:
            command.add_argument("--owner-id")
        if name == "save":
            command.add_argument("--brief-file", type=Path, required=True)
            command.add_argument("--base")
    return parser.parse_args()


def main() -> int:
    args = arguments()
    try:
        if args.command != "list":
            identifier(args.task, TASK_PATTERN, "task ID")
        context = repository_context(args.repo)
        scope = account_scope(args.repo, args.runtime, personal=args.personal)
        validate_lexical_account_root(scope)
        directory = state_directory(context, scope)
        if args.command == "list":
            result = list_tasks(context, scope, directory)
        else:
            result = {"save": save, "load": load, "verify": verify}[args.command](
                args, context, scope, directory
            )
    except (OSError, TypeError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps({"error": str(exc)}, sort_keys=True))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
