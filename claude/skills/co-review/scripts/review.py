"""Freeze review inputs without changing the caller's branch or index."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

SKILLS_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(SKILLS_ROOT))
HOOKS_ROOT = Path(__file__).resolve().parents[3] / "hooks"
sys.path.insert(0, str(HOOKS_ROOT))
from herdr_orch_core import account_payload_root, repo_slug, valid_task_id
from lib.workflow_context import (
    account_scope,
    atomic_json,
    open_state_parent,
    repository_context,
)
from lib.workflow_context import git as context_git


class ReviewError(Exception):
    """An input or snapshot cannot be proved safe."""


def git_environment(overrides: dict[str, str] | None = None) -> dict[str, str]:
    """Ignore caller Git routing so every probe targets its explicit checkout."""
    environment = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    if overrides:
        environment.update(overrides)
    return environment


def git(
    repo: Path,
    *args: str,
    input_data: bytes | None = None,
    env: dict[str, str] | None = None,
) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        input=input_data,
        capture_output=True,
        env=git_environment(env),
        check=False,
    )
    if result.returncode:
        raise ReviewError(
            result.stderr.decode(errors="replace").strip() or "git command failed"
        )
    return result.stdout


def text_git(repo: Path, *args: str, **kwargs: Any) -> str:
    return git(repo, *args, **kwargs).decode().strip()


def resolved_repo(value: str) -> Path:
    supplied = Path(value).expanduser().resolve()
    try:
        return Path(text_git(supplied, "rev-parse", "--show-toplevel")).resolve()
    except ReviewError as error:
        raise ReviewError(f"repository is unavailable: {error}") from error


def full_commit(repo: Path, reference: str) -> str:
    return text_git(repo, "rev-parse", "--verify", f"{reference}^{{commit}}")


_BRANCH_BAD = ("..", "@{", "~", "^", ":", "\\", " ")


def resolve_base(
    repo: Path, base: str | None, base_ref: str | None, head: str
) -> tuple[str, str | None, str | None]:
    """Resolve the review base: an explicit commit, or an origin branch merge-base."""
    if bool(base) == bool(base_ref):
        raise ReviewError("exactly one of --base or --base-ref is required")
    if base:
        return full_commit(repo, base), None, None
    branch = base_ref
    if branch.startswith("-") or any(bad in branch for bad in _BRANCH_BAD):
        raise ReviewError("--base-ref must be a plain origin branch name")
    check = subprocess.run(
        ["git", "-C", str(repo), "check-ref-format", "--branch", branch],
        capture_output=True,
        env=git_environment(),
        check=False,
    )
    if check.returncode:
        raise ReviewError("--base-ref is not a valid branch name")
    nonce = secrets.token_hex(16)
    ref = f"refs/co-review/{nonce}"
    # One scope so the ref is always cleaned up even if fetch creates it and
    # then fails. Bound the fetch to the owned ref: --refmap= and
    # --no-write-fetch-head keep it from touching refs/remotes/origin/* or
    # FETCH_HEAD (which prepare's source-unchanged checks cannot see), and
    # --no-recurse-submodules keeps it from fanning out.
    try:
        try:
            git(
                repo,
                "fetch",
                "--no-tags",
                "--no-write-fetch-head",
                "--no-recurse-submodules",
                "--refmap=",
                "origin",
                f"+refs/heads/{branch}:{ref}",
            )
        except ReviewError as error:
            raise ReviewError(
                f"cannot fetch origin branch {branch!r}: {error}"
            ) from error
        tip = full_commit(repo, ref)
        # merge-base exits 1 with empty output when histories are unrelated;
        # that is "no merge base", not a git failure, so do not use git() here.
        found = subprocess.run(
            ["git", "-C", str(repo), "merge-base", "--all", tip, head],
            capture_output=True,
            env=git_environment(),
            check=False,
            text=True,
        )
        if found.returncode not in (0, 1):
            raise ReviewError(found.stderr.strip() or "merge-base failed")
        merge_bases = found.stdout.split()
        if not merge_bases:
            raise ReviewError("no merge-base between origin branch and head")
        if len(merge_bases) > 1:
            raise ReviewError(
                "multiple merge-bases; resolve explicitly: " + " ".join(merge_bases)
            )
        return merge_bases[0], branch, tip
    finally:
        removal = subprocess.run(
            ["git", "-C", str(repo), "update-ref", "-d", ref],
            capture_output=True,
            env=git_environment(),
            check=False,
        )
        still_present = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", ref],
            capture_output=True,
            env=git_environment(),
            check=False,
        )
        if removal.returncode != 0 and still_present.returncode == 0:
            print(
                f"warning: could not remove co-review ref {ref}",
                file=sys.stderr,
            )


def sha256_bytes(content: bytes) -> str:
    return hashlib.sha256(content).hexdigest()


def secure_directory(value: Path, *, create: bool) -> tuple[Path, int]:
    """Open a directory through no-follow descriptors and retain its fd."""
    requested = value.expanduser()
    if not requested.is_absolute():
        requested = Path.cwd() / requested
    try:
        descriptor, _ = open_state_parent(requested / ".artifact-probe", create=create)
    except (OSError, ValueError) as error:
        raise ReviewError("artifact output directory is unsafe") from error
    return requested.resolve(), descriptor


def safe_relative_path(
    repo: Path, value: str, *, private: bool = True
) -> tuple[Path, str]:
    raw = Path(value)
    if raw.is_absolute() or not value or ".." in raw.parts:
        raise ReviewError(
            "path must be a repository-relative path without parent traversal"
        )
    candidate = repo.joinpath(*raw.parts)
    relative = candidate.relative_to(repo).as_posix()
    for parent in (candidate, *candidate.parents):
        if parent == repo.parent:
            break
        if parent.is_symlink():
            raise ReviewError(f"symlinked path is not eligible: {relative}")
    if private and any(
        part in {".git", ".ssh"} or part.startswith(".env") for part in raw.parts
    ):
        raise ReviewError(f"private path is not eligible: {relative}")
    try:
        candidate.resolve().relative_to(repo)
    except ValueError as error:
        raise ReviewError(f"path escapes the repository: {relative}") from error
    return candidate, relative


def status_porcelain(repo: Path) -> bytes:
    return git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all")


def untracked_paths(repo: Path, *, include_ignored: bool = False) -> set[str]:
    arguments = ["ls-files", "--others", "--exclude-standard", "-z"]
    entries = git(repo, *arguments)
    if include_ignored:
        entries += git(
            repo, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"
        )
    return {path.decode() for path in entries.split(b"\0") if path}


def tree_contains(repo: Path, tree: str, path: str) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), "cat-file", "-e", f"{tree}:{path}"],
        capture_output=True,
        env=git_environment(),
        check=False,
    )
    if result.returncode == 0:
        return True
    if result.returncode == 128 and (
        b"does not exist in" in result.stderr or b"exists on disk" in result.stderr
    ):
        return False
    raise ReviewError("cannot inspect selected snapshot tree")


def no_untracked_or_unstaged(
    repo: Path, *, expected_tree: str, expected_head: str
) -> None:
    if full_commit(repo, "HEAD") != expected_head:
        raise ReviewError("snapshot head changed")
    if text_git(repo, "write-tree") != expected_tree:
        raise ReviewError("snapshot index tree changed")
    changed = subprocess.run(
        ["git", "-C", str(repo), "diff", "--quiet"],
        capture_output=True,
        env=git_environment(),
        check=False,
    )
    if changed.returncode not in {0, 1}:
        raise ReviewError("cannot inspect snapshot worktree")
    if changed.returncode == 1:
        raise ReviewError("snapshot has unexpected unstaged changes")
    if untracked_paths(repo, include_ignored=True):
        raise ReviewError("snapshot has unexpected untracked paths")


def binding(manifest: dict[str, Any]) -> dict[str, Any]:
    snapshot = manifest["snapshot"]
    return {
        "nonce": manifest["ownership"]["nonce"],
        "repo_id": manifest["source"]["repo_id"],
        "codex_root": snapshot["codex_root"],
        "claude_root": snapshot["claude_root"],
        "codex_tree": snapshot["codex_tree"],
        "claude_tree": snapshot["claude_tree"],
    }


def read_json(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise ReviewError("manifest is not a regular file")
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ReviewError(f"invalid manifest: {error}") from error
    if not isinstance(value, dict):
        raise ReviewError("manifest must be a JSON object")
    return value


def load_manifest(path_value: str) -> tuple[Path, dict[str, Any], Path]:
    path = Path(path_value).expanduser().resolve()
    manifest = read_json(path)
    try:
        ownership = manifest["ownership"]
        nonce = ownership["nonce"]
        output_dir = Path(ownership["output_dir"]).resolve()
        marker = output_dir / ownership["marker"]
        codex_root = Path(manifest["snapshot"]["codex_root"]).resolve()
        claude_root = Path(manifest["snapshot"]["claude_root"]).resolve()
    except (KeyError, TypeError, ValueError) as error:
        raise ReviewError("manifest lacks ownership or snapshot metadata") from error
    if not isinstance(nonce, str) or not nonce or path.parent != output_dir:
        raise ReviewError("manifest is outside its owned output directory")
    if marker.parent != output_dir or marker.is_symlink() or not marker.is_file():
        raise ReviewError("snapshot ownership marker is unavailable")
    if codex_root.parent != output_dir or claude_root.parent != output_dir:
        raise ReviewError("snapshot root is outside its owned output directory")
    if codex_root.name != f"codex-{nonce}" or claude_root.name != f"claude-{nonce}":
        raise ReviewError("snapshot root does not match ownership nonce")
    if read_json(marker) != binding(manifest):
        raise ReviewError("snapshot ownership marker does not match manifest")
    return path, manifest, output_dir


def verify_manifest(path_value: str) -> tuple[Path, dict[str, Any], Path]:
    path, manifest, output_dir = load_manifest(path_value)
    try:
        source = manifest["source"]
        repo = Path(source["root"]).resolve()
        context = repository_context(repo)
        snapshot = manifest["snapshot"]
        codex_root = Path(snapshot["codex_root"]).resolve()
        claude_root = Path(snapshot["claude_root"]).resolve()
    except (KeyError, TypeError, ValueError, subprocess.SubprocessError) as error:
        raise ReviewError("manifest source metadata is invalid") from error
    if context["repo_id"] != source.get("repo_id") or str(repo) != source.get("root"):
        raise ReviewError("manifest source repository does not match its identity")
    registered = git(repo, "worktree", "list", "--porcelain", "-z")
    for root in (codex_root, claude_root):
        if f"worktree {root}".encode() + b"\0" not in registered:
            raise ReviewError("snapshot is not a registered worktree")
    no_untracked_or_unstaged(
        codex_root,
        expected_tree=snapshot["codex_tree"],
        expected_head=snapshot["snapshot_head"],
    )
    no_untracked_or_unstaged(
        claude_root, expected_tree=snapshot["claude_tree"], expected_head=source["base"]
    )
    return path, manifest, output_dir


def prepare(args: argparse.Namespace) -> dict[str, Any]:
    repo = resolved_repo(args.repo)
    requested_output = Path(args.output_dir).expanduser()
    if requested_output.exists() and requested_output.is_symlink():
        raise ReviewError("output directory must not be a symlink")
    output_dir = requested_output.resolve()
    if output_dir == repo or repo in output_dir.parents:
        raise ReviewError("output directory must be outside the source repository")
    if output_dir.exists() and (output_dir.is_symlink() or not output_dir.is_dir()):
        raise ReviewError("output directory must be a real directory")
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ReviewError("output directory must be empty")
    output_dir.mkdir(parents=True, exist_ok=True)
    current_head = full_commit(repo, "HEAD")
    head = full_commit(repo, args.head or "HEAD")
    if head != current_head:
        raise ReviewError(
            "head must be the source repository's current HEAD when freezing local changes"
        )
    base, base_ref, base_ref_tip = resolve_base(
        repo, args.base, getattr(args, "base_ref", None), head
    )
    before = status_porcelain(repo)
    original_index_tree = text_git(repo, "write-tree")
    staged = git(
        repo,
        "diff",
        "--cached",
        "--binary",
        "--full-index",
        "--no-ext-diff",
        "--no-textconv",
        head,
    )
    unstaged = git(
        repo, "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv"
    )
    selected = sorted(set(args.include_untracked or []))
    available = untracked_paths(repo, include_ignored=True)
    selected_records: list[dict[str, str]] = []
    for value in selected:
        candidate, relative = safe_relative_path(repo, value)
        if (
            relative not in available
            or not candidate.is_file()
            or candidate.is_symlink()
        ):
            raise ReviewError(
                f"untracked path was not inspected as a regular file: {relative}"
            )
        selected_records.append(
            {"path": relative, "sha256": sha256_bytes(candidate.read_bytes())}
        )
    exclusions = {
        "untracked_not_selected": sorted(
            available - {item["path"] for item in selected_records}
        )
    }
    index = output_dir / f".index-{secrets.token_hex(16)}"
    patch = output_dir / f".patch-{secrets.token_hex(16)}"
    try:
        index_env = {"GIT_INDEX_FILE": str(index)}
        git(repo, "read-tree", head, env=index_env)
        if staged:
            git(
                repo,
                "apply",
                "--cached",
                "--whitespace=nowarn",
                "-",
                input_data=staged,
                env=index_env,
            )
        if unstaged:
            git(
                repo,
                "apply",
                "--cached",
                "--whitespace=nowarn",
                "-",
                input_data=unstaged,
                env=index_env,
            )
        for record in selected_records:
            git(repo, "add", "--", f":(literal){record['path']}", env=index_env)
        tree = text_git(repo, "write-tree", env=index_env)
        selected_paths = {record["path"] for record in selected_records}
        for record in selected_records:
            if not tree_contains(repo, tree, record["path"]):
                raise ReviewError(
                    "selected untracked input is absent from the snapshot"
                )
        for path in available - selected_paths:
            if tree_contains(repo, tree, path):
                raise ReviewError("unselected untracked input entered the snapshot")
        snapshot_head = text_git(
            repo,
            "commit-tree",
            tree,
            "-p",
            head,
            "-m",
            "co-review snapshot",
            env={
                **index_env,
                "GIT_AUTHOR_NAME": "review",
                "GIT_AUTHOR_EMAIL": "review@example.invalid",
                "GIT_COMMITTER_NAME": "review",
                "GIT_COMMITTER_EMAIL": "review@example.invalid",
            },
        )
        patch.write_bytes(
            git(
                repo,
                "diff",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--no-textconv",
                base,
                snapshot_head,
            )
        )
        after = status_porcelain(repo)
        if (
            before != after
            or original_index_tree != text_git(repo, "write-tree")
            or staged
            != git(
                repo,
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--no-textconv",
                head,
            )
            or unstaged
            != git(
                repo,
                "diff",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--no-textconv",
            )
        ):
            raise ReviewError("source changed while capture was in progress; retry")
        for record in selected_records:
            candidate = repo / record["path"]
            if (
                not candidate.is_file()
                or sha256_bytes(candidate.read_bytes()) != record["sha256"]
            ):
                raise ReviewError(
                    "selected untracked input changed while capture was in progress; retry"
                )
        nonce = secrets.token_hex(16)
        codex_root = output_dir / f"codex-{nonce}"
        claude_root = output_dir / f"claude-{nonce}"
        git(
            repo,
            "-c",
            "core.hooksPath=/dev/null",
            "worktree",
            "add",
            "--detach",
            str(codex_root),
            snapshot_head,
        )
        git(
            repo,
            "-c",
            "core.hooksPath=/dev/null",
            "worktree",
            "add",
            "--detach",
            str(claude_root),
            base,
        )
        if patch.stat().st_size:
            git(claude_root, "apply", "--index", "--whitespace=nowarn", str(patch))
        if (
            text_git(codex_root, "write-tree") != tree
            or text_git(claude_root, "write-tree") != tree
        ):
            raise ReviewError(
                "Codex and Claude snapshots did not materialize the same tree"
            )
        context = repository_context(repo)
        manifest: dict[str, Any] = {
            "schemaVersion": 1,
            "ownership": {
                "nonce": nonce,
                "output_dir": str(output_dir),
                "marker": f".owner-{nonce}.json",
            },
            "source": {
                "root": str(repo),
                "repo_id": context["repo_id"],
                "base": base,
                "base_ref": base_ref,
                "base_ref_tip": base_ref_tip,
                "head": head,
                "source_tree": text_git(repo, "rev-parse", f"{head}^{{tree}}"),
            },
            "snapshot": {
                "snapshot_head": snapshot_head,
                "codex_root": str(codex_root),
                "claude_root": str(claude_root),
                "codex_tree": tree,
                "claude_tree": tree,
            },
            "scope": {"include_untracked": selected_records},
            "exclusions": exclusions,
        }
        marker = output_dir / manifest["ownership"]["marker"]
        atomic_json(marker, binding(manifest), exclusive=True)
        manifest_path = output_dir / "review-manifest.json"
        atomic_json(manifest_path, manifest, exclusive=True)
        return {
            "manifest": str(manifest_path),
            "snapshot_head": snapshot_head,
            "tree": tree,
        }
    finally:
        index.unlink(missing_ok=True)
        patch.unlink(missing_ok=True)


def artifact(args: argparse.Namespace) -> dict[str, Any]:
    repo = resolved_repo(args.repo)
    if not valid_task_id(args.task_id):
        raise ReviewError("task id is invalid")
    candidate, relative = safe_relative_path(repo, args.path)
    allowed = (
        "docs/superpowers/plans" if args.kind == "plan" else "docs/superpowers/specs"
    )
    if (
        not relative.startswith(f"{allowed}/")
        or candidate.suffix != ".md"
        or not candidate.is_file()
    ):
        raise ReviewError(
            f"{args.kind} must be an existing Markdown file under {allowed}"
        )
    content = candidate.read_bytes()
    context = repository_context(repo)
    scope = account_scope(repo, args.runtime, personal=args.personal)
    try:
        remote = context_git(repo, "remote", "get-url", "origin")
    except subprocess.CalledProcessError:
        remote = ""
    slug = repo_slug(remote, context["common_dir"])
    payload_root = account_payload_root(scope) / "herdr-orch" / slug
    resolved_payload_root = payload_root.resolve()
    if resolved_payload_root == repo or repo in resolved_payload_root.parents:
        raise ReviewError("artifact payload root is inside the source repository")
    task_root, task_fd = secure_directory(
        payload_root / "artifacts" / args.task_id, create=True
    )
    os.close(task_fd)
    if args.output_dir:
        requested_output = Path(os.path.abspath(Path(args.output_dir).expanduser()))
        if requested_output.parent != task_root:
            raise ReviewError(
                "artifact output directory must be one launch directory under the selected task"
            )
    else:
        requested_output = task_root / secrets.token_hex(16)
    output_dir, output_fd = secure_directory(requested_output, create=True)
    try:
        if output_dir.parent != task_root:
            raise ReviewError(
                "artifact output directory must be one launch directory under the selected task"
            )
        frozen_name = f"{args.kind}-{secrets.token_hex(16)}.md"
        descriptor = os.open(
            frozen_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=output_fd,
        )
        with os.fdopen(descriptor, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        frozen = output_dir / frozen_name
    finally:
        os.close(output_fd)
    digest = sha256_bytes(content)
    return {
        "kind": args.kind,
        "path": str(frozen.resolve()),
        "sha256": digest,
        "source": {
            "root": str(repo),
            "repo_id": context["repo_id"],
            "path": relative,
            "sha256": digest,
        },
        "task": {
            "task_id": args.task_id,
            "repo_id": context["repo_id"],
            "account_id": scope["account_id"],
        },
    }


def cleanup(args: argparse.Namespace) -> dict[str, Any]:
    manifest_path, manifest, output_dir = verify_manifest(args.manifest)
    repo = Path(manifest["source"]["root"])
    claude_root = Path(manifest["snapshot"]["claude_root"])
    codex_root = Path(manifest["snapshot"]["codex_root"])
    marker = output_dir / manifest["ownership"]["marker"]
    if set(output_dir.iterdir()) != {manifest_path, marker, codex_root, claude_root}:
        raise ReviewError("owned output directory contains unexpected paths")
    git(claude_root, "reset", "--hard", manifest["source"]["base"])
    git(repo, "worktree", "remove", str(claude_root))
    git(repo, "worktree", "remove", str(codex_root))
    marker.unlink()
    manifest_path.unlink()
    shutil.rmtree(output_dir)
    return {"cleaned": True}


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="review.py")
    commands = result.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    prepare_parser.add_argument("--repo", required=True)
    prepare_parser.add_argument("--base")
    prepare_parser.add_argument("--base-ref", dest="base_ref")
    prepare_parser.add_argument("--head")
    prepare_parser.add_argument("--output-dir", required=True)
    prepare_parser.add_argument("--include-untracked", action="append")
    resolve_parser = commands.add_parser("resolve-base")
    resolve_parser.add_argument("--repo", required=True)
    resolve_parser.add_argument("--base-ref", dest="base_ref", required=True)
    resolve_parser.add_argument("--head", required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--manifest", required=True)
    artifact_parser = commands.add_parser("artifact")
    artifact_parser.add_argument("--repo", required=True)
    artifact_parser.add_argument("--kind", required=True, choices=("plan", "spec"))
    artifact_parser.add_argument("--path", required=True)
    artifact_parser.add_argument("--task-id", required=True)
    artifact_parser.add_argument(
        "--runtime", required=True, choices=("claude", "codex")
    )
    artifact_parser.add_argument("--personal", action="store_true")
    artifact_parser.add_argument("--output-dir")
    cleanup_parser = commands.add_parser("cleanup")
    cleanup_parser.add_argument("--manifest", required=True)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "prepare":
            result = prepare(args)
        elif args.command == "verify":
            _, manifest, _ = verify_manifest(args.manifest)
            result = {
                "verified": True,
                "manifest": str(Path(args.manifest).expanduser().resolve()),
                "snapshot_head": manifest["snapshot"]["snapshot_head"],
            }
        elif args.command == "artifact":
            result = artifact(args)
        elif args.command == "resolve-base":
            repo = resolved_repo(args.repo)
            head = full_commit(repo, args.head)
            base, base_ref, base_ref_tip = resolve_base(
                repo, None, args.base_ref, head
            )
            result = {
                "base": base,
                "base_ref": base_ref,
                "base_ref_tip": base_ref_tip,
            }
        else:
            result = cleanup(args)
    except ReviewError as error:
        parser().error(str(error))
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
