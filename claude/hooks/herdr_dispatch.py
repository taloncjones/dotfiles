#!/usr/bin/env python3
"""Fenced Herdr launch adapter for Claude and Codex workers."""

from __future__ import annotations

import hashlib
import json
import os
import shlex
import shutil
import stat
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any

import agent_runtime
import herdr_orch_core as core
from herdr_dispatch_cli import (
    fresh_codex_hook_review_required as _fresh_codex_hook_review_required,
)
from herdr_dispatch_cli import metadata_argv, result_object
from herdr_dispatch_cli import prompt_state as _prompt_state
from herdr_dispatch_cli import run_herdr as _run_herdr
from herdr_dispatch_cli import same_directory as _same_directory
from herdr_dispatch_cli import validate_agent as _validate_agent
from herdr_dispatch_cli import validate_pane as _validate_pane


class DispatchError(RuntimeError):
    """A dispatch precondition or current-attempt check failed."""


PHASES = ("plan", "implement", "review", "think", "read", "mechanical")
WAKE_EVENTS = ("stopped", "blocked", "review-stopped", "completed")
AGENT_STATES = ("idle", "done")


def _runtime_binary(runtime: str, env: dict[str, str]) -> str:
    executable = shutil.which(runtime, path=env.get("PATH", os.defpath))
    if executable is None:
        raise DispatchError(f"runtime executable is unavailable: {runtime}")
    # Keep the entry name: versioned installations often use a runtime-named
    # symlink whose resolved target has a different basename.
    try:
        entry = Path(executable)
        selected = str(entry.parent.resolve(strict=True) / entry.name)
    except (OSError, RuntimeError) as exc:
        raise DispatchError(
            f"runtime executable parent cannot be resolved: {runtime}"
        ) from exc
    if ":" in str(Path(selected).parent) or any(c in selected for c in "\r\n"):
        raise DispatchError("runtime executable cannot be bound through PATH")
    return selected


def _bind_pane_environment(
    herdr_cli: str,
    pane_id: str,
    workspace_id: str,
    cwd: str | os.PathLike[str],
    scope: dict,
    env: dict[str, str],
    *,
    personal: bool = False,
    runtime: str | None = None,
    runtime_binary: str | None = None,
) -> None:
    launch_env = scope.get("launch_env")
    if not isinstance(launch_env, dict) or len(launch_env) > 4:
        raise DispatchError("account launch environment is invalid")
    account_id = scope.get("account_id")
    if not isinstance(account_id, str) or not account_id:
        raise DispatchError("account identity is invalid")
    if any(
        key
        not in (
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
            "CLAUDE_PERSONAL_ONLY",
            "WORKFLOW_PERSONAL_ACCOUNT",
        )
        or value is not None
        and not isinstance(value, str)
        for key, value in launch_env.items()
    ):
        raise DispatchError("account launch environment is invalid")

    bindings = {
        **launch_env,
        "HERDR_PERSONAL": "1" if personal else "0",
        "HERDR_ACCOUNT_ID": account_id,
    }
    token = f"HERDR_ACCOUNT_{uuid.uuid4().hex}"
    ready_marker = f"HERDR_READY_{uuid.uuid4().hex[:16]}"
    marker_split = len(ready_marker) // 2
    assignments = [
        f"unset {key}" if value is None else f"export {key}={shlex.quote(value)}"
        for key, value in bindings.items()
    ]
    probes = [
        f"printf '{token}:{key}=%s\\n' \"${{{key}-__UNSET__}}\"" for key in bindings
    ]
    if runtime is not None or runtime_binary is not None:
        if (
            runtime not in ("claude", "codex")
            or not isinstance(runtime_binary, str)
            or not Path(runtime_binary).is_absolute()
            or Path(runtime_binary).name != runtime
            or ":" in str(Path(runtime_binary).parent)
            or any(c in runtime_binary for c in "\r\n")
        ):
            raise DispatchError("runtime executable binding is invalid")
        # Herd's agent-start protocol fixes argv[0] to the runtime name.
        # Bypass wrappers in this owned idle task pane, then verify the exact
        # entry that its shell will resolve. Persistent shell files are untouched.
        assignments.extend(
            [
                f"unset -f '{runtime}' 2>/dev/null || :",
                f"unalias '{runtime}' 2>/dev/null || :",
                f'export PATH={shlex.quote(str(Path(runtime_binary).parent))}:"$PATH"',
                "hash -r",
            ]
        )
        probes.append(
            f"printf '{token}:RUNTIME_BINARY=%s\\n' \"$(command -v '{runtime}')\""
        )
    ready_probe = (
        "printf '%s%s\\n' "
        f"{shlex.quote(ready_marker[:marker_split])} "
        f"{shlex.quote(ready_marker[marker_split:])}"
    )
    _run_herdr(
        herdr_cli,
        ["pane", "run", pane_id, "; ".join([*assignments, *probes, ready_probe])],
        env=env,
        json_result=False,
    )
    observed = _run_herdr(
        herdr_cli,
        [
            "pane",
            "wait-output",
            pane_id,
            "--match",
            ready_marker,
            "--timeout",
            "5000",
            "--source",
            "recent-unwrapped",
        ],
        env=env,
    )
    if (
        observed.get("type") != "output_matched"
        or observed.get("pane_id") != pane_id
        or observed.get("matched_line") != ready_marker
    ):
        raise DispatchError("target pane account environment probe was not current")
    read = observed.get("read") if isinstance(observed, dict) else None
    text = read.get("text") if isinstance(read, dict) else None
    expected = {
        f"{token}:{key}={'__UNSET__' if value is None else value}"
        for key, value in bindings.items()
    }
    expected.add(ready_marker)
    if runtime_binary is not None:
        expected.add(f"{token}:RUNTIME_BINARY={runtime_binary}")
    if not isinstance(text, str) or not expected.issubset(set(text.splitlines())):
        raise DispatchError(
            "target pane account environment or runtime executable could not be verified"
        )
    _validate_pane(herdr_cli, pane_id, workspace_id, cwd, env)


def _expected_slug(repository: dict, cwd: str | os.PathLike[str]) -> str:
    provider = agent_runtime._workflow_context_module()
    try:
        remote = provider.git(cwd, "remote", "get-url", "origin")
    except subprocess.SubprocessError:
        remote = ""
    return core.repo_slug(remote, repository["common_dir"])


def _payload_repo_dir(scope: dict, repo_slug: str) -> Path:
    return core.account_payload_root(scope) / "herdr-orch" / repo_slug


def _read_json(path: Path, label: str) -> Any:
    provider = agent_runtime._workflow_context_module()
    try:
        parent, name = provider.open_state_parent(path)
        try:
            fd = os.open(
                name,
                os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent,
            )
        finally:
            os.close(parent)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise OSError("not a regular file")
            with os.fdopen(fd) as stream:
                content = stream.read(2_000_001)
            if len(content) > 2_000_000:
                raise OSError("record exceeds size limit")
        except BaseException:
            try:
                os.close(fd)
            except OSError:
                pass
            raise
        return json.loads(content)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise DispatchError(f"{label} is missing or unreadable") from exc


def _read_task(path: Path, task_id: str) -> dict[str, Any]:
    task = _read_json(path, "task record")
    if not isinstance(task, dict) or task.get("task_id") != task_id:
        raise DispatchError("task record does not match the requested task")
    workers = task.get("workers", [])
    if not isinstance(workers, list):
        raise DispatchError("task workers must be a list")
    return task


def _validate_task_context(
    task: dict[str, Any], repository: dict, repo_slug: str
) -> None:
    if (
        task.get("repo_slug") != repo_slug
        or not _same_directory(task.get("worktree"), repository["root"])
        or task.get("branch") != repository["branch"]
        or not isinstance(task.get("base_sha"), str)
        or not core.SHA40_RE.fullmatch(task["base_sha"])
    ):
        raise DispatchError("task does not match the designated worktree and branch")


def _check_todo_ready(
    task: dict[str, Any],
    cwd: str | os.PathLike[str],
    cli: str | os.PathLike[str],
    env: dict[str, str],
) -> None:
    if "todo_id" not in task:
        return
    todo_id = task["todo_id"]
    if not isinstance(todo_id, str):
        raise DispatchError("persisted TODO binding is invalid")
    try:
        process = subprocess.run(
            ["bash", os.fspath(cli), "ready", todo_id, "--offline"],
            cwd=cwd,
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
            env=env,
        )
        result = json.loads(process.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        raise DispatchError("TODO readiness check failed") from exc
    valid = (
        isinstance(result, dict)
        and result.get("task_id") == todo_id
        and isinstance(result.get("ready"), bool)
        and isinstance(result.get("dependencies"), list)
        and all(
            isinstance(item, dict)
            and set(item) == {"ref", "state"}
            and all(isinstance(item[key], str) for key in ("ref", "state"))
            for item in result.get("dependencies", [])
        )
    )
    if not valid or process.returncode not in (0, 2, 3):
        raise DispatchError("TODO readiness result is invalid")
    if process.returncode != 0 or result["ready"] is not True:
        raise DispatchError("TODO dependencies are not ready")


def _write_attempt(
    rd: Path,
    task_id: str,
    session: str,
    fence: int,
    repository: dict,
    scope: dict,
    repo_slug: str,
    attempt: dict[str, Any],
    todo_binding: tuple[bool, Any],
) -> dict[str, Any]:
    task_path = rd / "tasks" / f"{task_id}.json"
    with core.owner_transaction(
        rd,
        session,
        fence,
        context=repository,
        scope=scope,
        expected_slug=repo_slug,
    ):
        task = _read_task(task_path, task_id)
        _validate_task_context(task, repository, repo_slug)
        if ("todo_id" in task, task.get("todo_id")) != todo_binding:
            raise DispatchError("persisted TODO binding changed before dispatch")
        workers = [*task.get("workers", []), attempt]
        updated = {**task, "workers": workers}
        core.write_json_atomic(task_path, updated)
        return updated


def _update_attempt(
    rd: Path,
    task_id: str,
    session: str,
    fence: int,
    repository: dict,
    scope: dict,
    repo_slug: str,
    launch_id: str,
    **updates: Any,
) -> dict[str, Any]:
    task_path = rd / "tasks" / f"{task_id}.json"
    with core.owner_transaction(
        rd,
        session,
        fence,
        context=repository,
        scope=scope,
        expected_slug=repo_slug,
    ):
        task = _read_task(task_path, task_id)
        _validate_task_context(task, repository, repo_slug)
        workers = task.get("workers", [])
        if not workers or not isinstance(workers[-1], dict):
            raise DispatchError("current task has no launch attempt")
        if workers[-1].get("launch_id") != launch_id:
            raise DispatchError("readiness does not belong to the current attempt")
        updated = {**workers[-1], **updates}
        core.write_json_atomic(task_path, {**task, "workers": [*workers[:-1], updated]})
        return updated


def _lifecycle_prompt(
    prompt: str,
    attempt: dict[str, Any],
    task: dict[str, Any],
    rd: Path,
    personal: bool,
    *,
    approval_mediated: bool,
) -> str:
    suffix = "review" if attempt["phase"] == "review" else "done"
    result = (rd / "tasks" / f"{attempt['task_id']}.{suffix}.json").resolve()
    emitter = Path(core.__file__).resolve()
    coordination = core.coordination.coordination_root().resolve()
    command = [
        "python3",
        str(emitter),
        f"emit-{suffix}",
        "--repo-path",
        attempt["worktree"],
        "--runtime",
        attempt["runtime"],
    ]
    if personal:
        command.append("--personal")
    command += [
        "--repo-slug",
        attempt["repo_slug"],
        "--task-id",
        attempt["task_id"],
        "--workspace",
        attempt["workspace_id"],
        "--agent",
        attempt["agent"],
        "--launch-id",
        attempt["launch_id"],
        "--pane-id",
        attempt["pane_id"],
        "--source-head-sha",
        attempt["source_head_sha"],
    ]
    if suffix == "done":
        command += ["--phase", attempt["phase"], "--base-sha", task["base_sha"]]
    context = (
        f"{prompt.rstrip()}\n\nLifecycle attempt context:\n"
        "This adapter block is authoritative over conflicting lifecycle fields in the task "
        "text. The reserved attempt is "
        f"launch_id={attempt['launch_id']} phase={attempt['phase']} "
        f"runtime={attempt['runtime']} workspace_id={attempt['workspace_id']} "
        f"pane_id={attempt['pane_id']} source_head_sha={attempt['source_head_sha']}. "
        f"Publish the final result only with this emitter identity: {shlex.join(command)}. "
        f"Supply only its required outcome and final-result fields. The emitter writes {result} "
        f"and its lock under {coordination}."
    )
    if not approval_mediated:
        return context
    return (
        f"{context}\n\nLifecycle publication authorization:\n"
        "Keep the source tree read-only. You may request approval only for the exact emitter "
        "above. Do not request other writes. If that exact emitter approval is rejected, "
        "report blocked and do not claim completion."
    )


def launch(
    *,
    repo_slug: str,
    task_id: str,
    session: str,
    fence: int,
    workspace_id: str,
    pane_id: str,
    phase: str,
    agent: str,
    route: dict[str, Any],
    cwd: str | os.PathLike[str],
    sandbox: str,
    prompt: str,
    herdr_cli: str = "herdr",
    env: dict[str, str] | None = None,
    start_timeout_ms: int = 30_000,
    prompt_timeout_ms: int = 120_000,
    personal: bool = False,
    todos_cli: str | os.PathLike[str] | None = None,
) -> dict[str, Any]:
    """Launch into an explicit existing shell pane and record strict provenance."""
    if phase not in PHASES:
        raise DispatchError(f"unsupported phase: {phase}")
    if not core.valid_task_id(task_id) or not core.valid_workspace_id(workspace_id):
        raise DispatchError("invalid task or workspace identity")
    if not isinstance(prompt, str) or not prompt.strip():
        raise DispatchError("prompt must be non-empty text")
    if route.get("runtime") not in ("claude", "codex"):
        raise DispatchError("route runtime is unsupported")
    if route.get("ready") is not True:
        raise DispatchError("route is not ready")
    if route.get("difficulty") is not None and route.get("difficulty_confirmed") is not True:
        raise DispatchError("route difficulty must be confirmed")
    if isinstance(fence, bool) or not isinstance(fence, int) or fence < 1:
        raise DispatchError("fence must be a positive integer")
    for name, value in (
        ("start_timeout_ms", start_timeout_ms),
        ("prompt_timeout_ms", prompt_timeout_ms),
    ):
        if isinstance(value, bool) or not isinstance(value, int) or value < 1:
            raise DispatchError(f"{name} must be a positive integer")
    if not 3_000 < start_timeout_ms <= 300_000:
        raise DispatchError(
            "start_timeout_ms must be greater than 3000 and at most 300000"
        )

    child_env = dict(os.environ if env is None else env)
    if child_env.get("HERDR_ENV") != "1":
        raise DispatchError("launch requires a Herdr-managed environment")

    runtime = route["runtime"]
    try:
        repository, scope = agent_runtime.execution_context(cwd, runtime, personal)
    except agent_runtime.RouteError as exc:
        raise DispatchError(str(exc)) from exc
    if repo_slug != _expected_slug(repository, cwd):
        raise DispatchError("repo slug does not match repository context")
    rd = _payload_repo_dir(scope, repo_slug)
    pending_task = _read_task(rd / "tasks" / f"{task_id}.json", task_id)
    _validate_task_context(pending_task, repository, repo_slug)
    todo_binding = ("todo_id" in pending_task, pending_task.get("todo_id"))
    if todos_cli is None:
        todos_cli = (
            Path(__file__).resolve().parents[1] / "skills/todos/scripts/todos.sh"
        )
    _check_todo_ready(pending_task, repository["root"], todos_cli, child_env)
    agent_runtime._apply_launch_environment(child_env, scope)
    runtime_binary = _runtime_binary(runtime, child_env)
    _validate_pane(herdr_cli, pane_id, workspace_id, cwd, child_env)
    _bind_pane_environment(
        herdr_cli,
        pane_id,
        workspace_id,
        cwd,
        scope,
        child_env,
        personal=personal,
        runtime=runtime,
        runtime_binary=runtime_binary,
    )

    pre_capture = _run_herdr(
        herdr_cli,
        ["pane", "read", pane_id, "--source", "detection", "--lines", "200"],
        env=child_env,
        json_result=False,
    )
    assert isinstance(pre_capture, str)
    launch_id = f"{agent}-{uuid.uuid4().hex[:12]}"
    started_ns = time.time_ns()
    attempt = {
        "launch_id": launch_id,
        "phase": phase,
        "runtime": runtime,
        "runtime_binary": runtime_binary,
        "workspace_id": workspace_id,
        "pane_id": pane_id,
        "source_head_sha": repository["head"],
        "task_id": task_id,
        "agent": agent,
        "role": route["role"],
        "model": route["model"],
        "effort": route["effort"],
        "difficulty": route.get("difficulty"),
        "difficulty_proposed": route.get("difficulty_proposed"),
        "difficulty_confirmed": route.get("difficulty_confirmed"),
        "status": "starting",
        "started_ns": started_ns,
        "capture_before_sha256": hashlib.sha256(pre_capture.encode()).hexdigest(),
        "account_id": scope["account_id"],
        "personal": personal,
        "repo_slug": repo_slug,
        "worktree": repository["root"],
        "branch": repository["branch"],
    }
    task = _write_attempt(
        rd,
        task_id,
        session,
        fence,
        repository,
        scope,
        repo_slug,
        attempt,
        todo_binding,
    )

    try:
        launch_route = route
        if runtime == "codex" and sandbox == "workspace-write":
            launch_route = {
                **route,
                "add_dirs": [
                    str(rd.resolve()),
                    str(core.coordination.coordination_root().resolve()),
                ],
            }
        elif runtime == "codex" and sandbox == "read-only":
            launch_route = {**route, "lifecycle_approval": "auto-review"}
        native = agent_runtime.launch_argv(
            launch_route, cwd, sandbox, mode="interactive", scope=scope
        )
        start_result = _run_herdr(
            herdr_cli,
            [
                "agent",
                "start",
                agent,
                "--kind",
                runtime,
                "--pane",
                pane_id,
                "--timeout",
                str(start_timeout_ms),
                "--",
                *native[1:],
            ],
            env=child_env,
            timeout_secs=start_timeout_ms / 1000 + 5,
            json_result=True,
        )
        assert isinstance(start_result, dict)
        _validate_agent(start_result, agent, runtime, pane_id, native)
        current = _run_herdr(
            herdr_cli,
            ["agent", "get", agent],
            env=child_env,
            json_result=True,
        )
        assert isinstance(current, dict)
        _validate_agent(current, agent, runtime, pane_id)
        post_capture = _run_herdr(
            herdr_cli,
            ["pane", "read", pane_id, "--source", "detection", "--lines", "200"],
            env=child_env,
            json_result=False,
        )
        assert isinstance(post_capture, str)
        if post_capture == pre_capture:
            raise DispatchError("post-launch capture has no fresh readiness boundary")
        capture_after_sha256 = hashlib.sha256(post_capture.encode()).hexdigest()
        if runtime == "codex" and _fresh_codex_hook_review_required(
            pre_capture, post_capture
        ):
            _update_attempt(
                rd,
                task_id,
                session,
                fence,
                repository,
                scope,
                repo_slug,
                launch_id,
                status="blocked",
                blocked_reason="codex-hook-review-required",
                capture_after_sha256=capture_after_sha256,
            )
            return {
                "status": "blocked",
                "reason": "codex-hook-review-required",
                "launch_id": launch_id,
                "prompt_state": None,
                "completion_candidate": False,
                "completion_authoritative": False,
                "observed_model": None,
                "observed_effort": None,
                "observation": "fresh-native-hook-review-modal",
                "strict_ready": False,
                "presentation": {
                    "status": "not-attempted",
                    "reason": "blocked-before-prompt",
                },
            }
        _update_attempt(
            rd,
            task_id,
            session,
            fence,
            repository,
            scope,
            repo_slug,
            launch_id,
            status="ready",
            capture_after_sha256=capture_after_sha256,
        )
        launch_prompt = _lifecycle_prompt(
            prompt,
            attempt,
            task,
            rd,
            personal,
            approval_mediated=runtime == "codex" and sandbox == "read-only",
        )
        prompt_result = _run_herdr(
            herdr_cli,
            [
                "agent",
                "prompt",
                agent,
                launch_prompt,
                "--wait",
                "--timeout",
                str(prompt_timeout_ms),
            ],
            env=child_env,
            timeout_secs=prompt_timeout_ms / 1000 + 5,
            json_result=True,
        )
        assert isinstance(prompt_result, dict)
        prompt_state = _prompt_state(prompt_result)
        final_attempt = _update_attempt(
            rd,
            task_id,
            session,
            fence,
            repository,
            scope,
            repo_slug,
            launch_id,
            status="launched",
            prompt_state=prompt_state,
        )
        metadata = metadata_argv(final_attempt, "working", started_ns)
        try:
            _run_herdr(
                herdr_cli,
                metadata[1:],
                env=child_env,
                json_result=False,
            )
            presentation = {"status": "applied", "reason": None}
        except DispatchError as exc:
            presentation = {"status": "unsupported", "reason": str(exc)}
    except DispatchError:
        try:
            _update_attempt(
                rd,
                task_id,
                session,
                fence,
                repository,
                scope,
                repo_slug,
                launch_id,
                status="launch_failed",
            )
        except DispatchError:
            pass
        raise

    inspected = inspect(
        repo_slug,
        task_id,
        phase,
        workspace_id,
        cwd=cwd,
        runtime=runtime,
        personal=personal,
    )
    candidate = inspected["completion_candidate"]
    return {
        "status": "launched",
        "launch_id": launch_id,
        "prompt_state": prompt_state,
        "completion_candidate": candidate,
        "completion_authoritative": False,
        "observed_model": None,
        "observed_effort": None,
        "observation": "not-exposed-by-herdr-agent-metadata",
        "strict_ready": False,
        "presentation": presentation,
    }


def inspect(
    repo_slug: str,
    task_id: str,
    phase: str,
    workspace_id: str,
    *,
    cwd: str | os.PathLike[str],
    runtime: str = "claude",
    personal: bool = False,
) -> dict[str, Any]:
    """Inspect current attempt provenance without treating pane state as completion."""
    if (
        not core.valid_repo_slug(repo_slug)
        or not core.valid_task_id(task_id)
        or phase not in PHASES
        or not core.valid_workspace_id(workspace_id)
    ):
        raise DispatchError("invalid inspect identity")
    try:
        repository, scope = agent_runtime.execution_context(cwd, runtime, personal)
    except agent_runtime.RouteError as exc:
        raise DispatchError(str(exc)) from exc
    if repo_slug != _expected_slug(repository, cwd):
        raise DispatchError("repo slug does not match repository context")
    rd = _payload_repo_dir(scope, repo_slug)
    task = _read_task(rd / "tasks" / f"{task_id}.json", task_id)
    _validate_task_context(task, repository, repo_slug)
    workers = task.get("workers", [])
    matches = [
        worker
        for worker in workers
        if isinstance(worker, dict) and worker.get("phase") == phase
    ]
    attempt = matches[-1] if matches else None
    suffix = "review" if phase == "review" else "done"
    result_path = rd / "tasks" / f"{task_id}.{suffix}.json"
    try:
        result = _read_json(result_path, "attempt result")
    except DispatchError:
        result = None
    result_matches = isinstance(result, dict) and core.attempt_matches(
        task, result, phase, workspace_id
    )
    candidate = result_matches and result.get("outcome") in ("completed", "approved")
    return {
        "task_id": task_id,
        "phase": phase,
        "current_attempt": attempt,
        "result_matches_attempt": result_matches,
        "result_outcome": result.get("outcome") if isinstance(result, dict) else None,
        "completion_candidate": candidate,
        "completion_authoritative": False,
        "strict_ready": bool(attempt)
        and attempt.get("status") in ("ready", "launched")
        and attempt.get("observed_model") is not None
        and attempt.get("observed_effort") is not None,
    }


def wake(
    thread_id: str,
    *,
    event: str,
    repo_slug: str,
    workspace_id: str,
    queue_validated: bool = False,
) -> dict[str, str]:
    """Refuse native queue use until its pinned-thread behavior is smoke-tested."""
    try:
        uuid.UUID(thread_id)
    except (ValueError, AttributeError) as exc:
        raise DispatchError("thread ID must be a UUID") from exc
    if event not in WAKE_EVENTS:
        raise DispatchError("wake event is outside the closed vocabulary")
    if not core.valid_repo_slug(repo_slug) or not core.valid_workspace_id(workspace_id):
        raise DispatchError("wake metadata identity is invalid")
    if not queue_validated:
        return {
            "status": "unsupported",
            "reason": "native-queue-not-smoke-validated",
            "fallback": "bounded-watch",
        }
    return {
        "status": "unsupported",
        "reason": "native-queue-adapter-unavailable",
        "fallback": "bounded-watch",
    }


REPROMPT_OBSERVATION = "session-identity-not-exposed-by-herdr"


class _RejectedDelivery(DispatchError):
    """The reprompt was PROVABLY not accepted: the delivery process never ran.

    Only this pre-acceptance signal is retry-safe. A nonzero exit, timeout, or
    malformed reply can each occur AFTER the prompt was accepted (--wait), so
    they are classified uncertain, never retry-safe.
    """


def _find_current_target(task, launch_id, phase, workspace_id, runtime):
    workers = task.get("workers", [])
    if not isinstance(workers, list):
        raise DispatchError("task workers must be a list")
    target = next(
        (w for w in workers
         if isinstance(w, dict) and w.get("launch_id") == launch_id),
        None,
    )
    if target is None:
        raise DispatchError("named launch is not present in the task record")
    matching = [w for w in workers if isinstance(w, dict) and w.get("phase") == phase]
    if not matching or matching[-1] is not target:
        raise DispatchError("named launch is no longer the current attempt for its phase")
    if target.get("status") != "launched":
        raise DispatchError("named launch is not a live launched attempt")
    if target.get("runtime") != runtime:
        raise DispatchError("named launch runtime does not match")
    if target.get("workspace_id") != workspace_id:
        raise DispatchError("named launch workspace does not match")
    for key in ("pane_id", "agent"):
        if not isinstance(target.get(key), str) or not target[key]:
            raise DispatchError("named launch lacks pane or agent identity")
    return target


def _write_target_reprompts(task, task_path, launch_id, reprompts):
    workers = task.get("workers", [])
    new_workers = []
    replaced = False
    for worker in workers:
        if (
            isinstance(worker, dict)
            and worker.get("launch_id") == launch_id
            and not replaced
        ):
            new_workers.append({**worker, "reprompts": reprompts})
            replaced = True
        else:
            new_workers.append(worker)
    if not replaced:
        raise DispatchError("named launch vanished before write")
    core.write_json_atomic(task_path, {**task, "workers": new_workers})


def _set_reprompt_status(task, task_path, launch_id, seq, status, prompt_state):
    """Update reprompt entry `seq` using an already-read `task` (call inside an
    open owner transaction)."""
    target = next(
        (w for w in task.get("workers", [])
         if isinstance(w, dict) and w.get("launch_id") == launch_id),
        None,
    )
    if target is None:
        raise DispatchError("named launch vanished before recording")
    reprompts = list(target.get("reprompts", []))
    if seq >= len(reprompts) or not isinstance(reprompts[seq], dict):
        raise DispatchError("reprompt record entry missing")
    entry = {**reprompts[seq], "status": status}
    if prompt_state is not None:
        entry["prompt_state"] = prompt_state
    reprompts[seq] = entry
    _write_target_reprompts(task, task_path, launch_id, reprompts)


def _mark_reprompt(rd, task_id, session, fence, repository, scope, repo_slug,
                   launch_id, seq, *, status, prompt_state=None, best_effort=False):
    """Open a fresh owner transaction to set a reprompt entry's status."""
    task_path = rd / "tasks" / f"{task_id}.json"
    try:
        with core.owner_transaction(
            rd, session, fence, context=repository, scope=scope,
            expected_slug=repo_slug,
        ):
            task = _read_task(task_path, task_id)
            _set_reprompt_status(task, task_path, launch_id, seq, status, prompt_state)
    except (DispatchError, OSError, ValueError):
        if best_effort:
            return
        raise


def _deliver_reprompt(herdr_cli, agent, prompt, prompt_timeout_ms, env):
    """Deliver one turn; classify into (delivered,state) | (uncertain,None) |
    raise _RejectedDelivery (provable pre-acceptance rejection only).

    Only a process-CREATION failure (FileNotFoundError/PermissionError -- the
    delivery binary never ran) is retry-safe rejection. A timeout, a nonzero
    exit, any other OSError (which may arise while communicating AFTER the child
    started), a decode failure, or a malformed/non-`agent_prompted` reply are
    all uncertain -- the turn may have been accepted, so never resend.
    Output is captured as bytes and decoded explicitly so invalid UTF-8 cannot
    escape as a ValueError that a caller might mistake for a pre-delivery fault.
    """
    argv = ["agent", "prompt", agent, prompt, "--wait", "--timeout",
            str(prompt_timeout_ms)]
    try:
        process = subprocess.run(
            [herdr_cli, *argv], env=env, check=False, capture_output=True,
            timeout=prompt_timeout_ms / 1000 + 5,
        )
    except subprocess.TimeoutExpired:
        return ("uncertain", None)  # may have accepted then run long
    except (FileNotFoundError, PermissionError) as exc:
        raise _RejectedDelivery("reprompt delivery could not start") from exc
    except OSError:
        return ("uncertain", None)  # communication error; may have landed
    if process.returncode != 0:
        return ("uncertain", None)  # could be a post-acceptance failure
    try:
        stdout = process.stdout.decode("utf-8")
    except (UnicodeDecodeError, AttributeError):
        return ("uncertain", None)
    try:
        result = result_object(stdout, "Herdr agent prompt")
    except DispatchError:
        return ("uncertain", None)
    if result.get("type") != "agent_prompted":
        return ("uncertain", None)
    return ("delivered", _prompt_state(result))


def reprompt(*, repo_slug, task_id, session, fence, workspace_id, launch_id,
             phase, cwd, prompt, runtime="claude", herdr_cli="herdr",
             env=None, prompt_timeout_ms=120_000, personal=False):
    """Append a follow-up turn to a named, still-live dispatched worker."""
    if phase not in PHASES:
        raise DispatchError(f"unsupported phase: {phase}")
    if not core.valid_task_id(task_id) or not core.valid_workspace_id(workspace_id):
        raise DispatchError("invalid task or workspace identity")
    if not isinstance(launch_id, str) or not launch_id:
        raise DispatchError("launch_id must be non-empty text")
    if not isinstance(prompt, str) or not prompt.strip():
        raise DispatchError("prompt must be non-empty text")
    if isinstance(fence, bool) or not isinstance(fence, int) or fence < 1:
        raise DispatchError("fence must be a positive integer")
    if (isinstance(prompt_timeout_ms, bool)
            or not isinstance(prompt_timeout_ms, int) or prompt_timeout_ms < 1):
        raise DispatchError("prompt_timeout_ms must be a positive integer")
    if runtime not in ("claude", "codex"):
        raise DispatchError("route runtime is unsupported")

    child_env = dict(os.environ if env is None else env)
    if child_env.get("HERDR_ENV") != "1":
        raise DispatchError("reprompt requires a Herdr-managed environment")

    try:
        repository, scope = agent_runtime.execution_context(cwd, runtime, personal)
    except agent_runtime.RouteError as exc:
        raise DispatchError(str(exc)) from exc
    if repo_slug != _expected_slug(repository, cwd):
        raise DispatchError("repo slug does not match repository context")
    rd = _payload_repo_dir(scope, repo_slug)
    task_path = rd / "tasks" / f"{task_id}.json"
    prompt_sha = hashlib.sha256(prompt.encode()).hexdigest()
    started_ns = time.time_ns()

    # Transaction 1: record intent (crash marker), fence-validated. A bad/lost
    # fence or a persistence error surfaces from owner_transaction as
    # ValueError/OSError; convert it to a DispatchError refusal (nothing has
    # been delivered). Validation DispatchErrors propagate unchanged.
    try:
        with core.owner_transaction(
            rd, session, fence, context=repository, scope=scope,
            expected_slug=repo_slug,
        ):
            task = _read_task(task_path, task_id)
            _validate_task_context(task, repository, repo_slug)
            target = _find_current_target(task, launch_id, phase, workspace_id, runtime)
            agent = target["agent"]
            pane_id = target["pane_id"]
            reprompts = list(target.get("reprompts", []))
            # Refuse to stack a new turn on an unresolved prior one: a "starting"
            # (in-flight/crashed) or "uncertain" (timeout/ambiguous) entry means
            # a previous turn may already have landed. Reconcile it before
            # sending another, so a retry can never double-deliver. "delivered",
            # "delivered-unrecorded" (a distinct next pass) and "failed" (nothing
            # delivered) do not block. Cross-session concurrency is already
            # serialized by the owner fence.
            if any(
                isinstance(entry, dict)
                and entry.get("status") in ("starting", "uncertain")
                for entry in reprompts
            ):
                raise DispatchError(
                    "a prior reprompt on this launch is unresolved; reconcile it "
                    "before sending another"
                )
            seq = len(reprompts)
            reprompts.append({
                "seq": seq, "started_ns": started_ns,
                "prompt_sha256": prompt_sha, "status": "starting",
            })
            _write_target_reprompts(task, task_path, launch_id, reprompts)
    except (OSError, ValueError) as exc:
        raise DispatchError(f"reprompt could not record intent: {exc}") from exc

    # Live-agent validation: idle + interactive-ready on the recorded pane.
    # Read-only herdr query; safe outside the fence. A failure here delivered
    # nothing, so the recorded intent is marked failed (retry-safe), not orphaned.
    try:
        current = _run_herdr(herdr_cli, ["agent", "get", agent], env=child_env,
                             json_result=True)
        assert isinstance(current, dict)
        _validate_agent(current, agent, runtime, pane_id)
    except DispatchError:
        _mark_reprompt(rd, task_id, session, fence, repository, scope, repo_slug,
                       launch_id, seq, status="failed", best_effort=True)
        raise

    # Transaction 2: re-validate current-for-phase, deliver (acceptance), and
    # record the outcome -- ALL under one held fence, so no superseding writer
    # or ownership transfer can slip between validation and acceptance.
    # `agent prompt --wait` returns at prompt acceptance (agent transitions to
    # "working"), not turn completion (matching launch), so the critical section
    # is bounded to acceptance, not the worker's whole turn.
    delivered = {"done": False, "outcome": None, "state": None}
    try:
        with core.owner_transaction(
            rd, session, fence, context=repository, scope=scope,
            expected_slug=repo_slug,
        ):
            task = _read_task(task_path, task_id)
            _validate_task_context(task, repository, repo_slug)
            _find_current_target(task, launch_id, phase, workspace_id, runtime)
            outcome, state = _deliver_reprompt(herdr_cli, agent, prompt,
                                               prompt_timeout_ms, child_env)
            delivered.update(done=True, outcome=outcome, state=state)
            _set_reprompt_status(
                task, task_path, launch_id, seq,
                "delivered" if outcome == "delivered" else "uncertain", state,
            )
    except _RejectedDelivery:
        # Provable pre-acceptance rejection: nothing delivered, retry-safe.
        _mark_reprompt(rd, task_id, session, fence, repository, scope, repo_slug,
                       launch_id, seq, status="failed", best_effort=True)
        raise DispatchError("reprompt delivery was rejected before acceptance")
    except (DispatchError, OSError, ValueError) as exc:
        # If the exception fired BEFORE delivery (supersession, task-context,
        # fence, persistence-on-read), nothing was delivered -> refuse and mark
        # the intent failed (retry-safe). If AFTER delivery, the turn landed and
        # only recording failed -> delivered-unrecorded; never resend.
        if not delivered["done"]:
            _mark_reprompt(rd, task_id, session, fence, repository, scope,
                           repo_slug, launch_id, seq, status="failed",
                           best_effort=True)
            if isinstance(exc, DispatchError):
                raise
            raise DispatchError(
                f"reprompt could not be validated or delivered: {exc}"
            ) from exc
        status = ("delivered-unrecorded"
                  if delivered["outcome"] == "delivered" else "uncertain")
        return {"status": status, "launch_id": launch_id, "phase": phase,
                "reprompt_seq": seq, "prompt_state": delivered["state"],
                "observation": REPROMPT_OBSERVATION}

    result_status = "reprompted" if delivered["outcome"] == "delivered" else "uncertain"
    return {"status": result_status, "launch_id": launch_id, "phase": phase,
            "reprompt_seq": seq, "prompt_state": delivered["state"],
            "observation": REPROMPT_OBSERVATION}


def runtime_main(argv: list[str] | None = None) -> int:
    from herdr_dispatch_cli import runtime_main as cli_runtime_main

    return cli_runtime_main(argv)


def main(argv: list[str] | None = None) -> int:
    from herdr_dispatch_cli import main as cli_main

    return cli_main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
