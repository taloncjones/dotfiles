#!/usr/bin/env python3
"""Fenced Herdr launch adapter for Claude and Codex workers."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

import agent_runtime
import herdr_bindings as bindings
import herdr_orch_core as core
from herdr_dispatch_cli import (
    fresh_codex_hook_review_required as _fresh_codex_hook_review_required,
)
from herdr_dispatch_cli import NOT_AT_SHELL, metadata_argv, result_object
from herdr_dispatch_cli import prompt_state as _prompt_state
from herdr_dispatch_cli import run_herdr as _run_herdr
from herdr_dispatch_cli import same_directory as _same_directory
from herdr_dispatch_cli import validate_agent as _validate_agent
from herdr_dispatch_cli import validate_pane as _validate_pane


class DispatchError(RuntimeError):
    """A dispatch precondition or current-attempt check failed."""


PHASES = ("plan", "implement", "review", "think", "read", "mechanical", "ship")
WAKE_EVENTS = ("stopped", "blocked", "review-stopped", "completed")
AGENT_STATES = core.IDLE_AGENT_STATES
PANE_READY_ATTEMPTS = 3
SHELL_READY_POLLS = 10
SHELL_READY_POLL_SECS = 0.5
# macOS MAX_CANON: a longer line pasted into a canonical-mode tty is truncated.
PANE_RUN_MAX_BYTES = 1023
EXIT_WAIT_MS = 10_000
SETTLE_POLLS = 20
SETTLE_POLL_SECS = 0.5
# Wall-clock cap per wait, so a herdr call timing out (10 s each) cannot
# stretch one wait to SETTLE_POLLS timeouts.
SETTLE_WAIT_SECS = 10
# bin/op-env: a project's 1Password-resolved credentials for Claude panes.
OP_ENV = Path(__file__).resolve().parents[2] / "bin" / "op-env"
# Ready wait for a pane that resolves op-env: its 20 s op bound plus startup.
OP_ENV_READY_WAIT_MS = 50_000
# Claude Code's /exit menu when background work is running; option 1 exits.
# Requires the numbered option, not just the phrase, so prose is never
# mistaken for the menu. Human-verify H1: the live text is untested.
BACKGROUND_EXIT_MENU_RE = re.compile(
    r"background (?:tasks?|work|process(?:es)?)\s+(?:are|is)\s+still\s+running"
    r".{0,120}?1\.\s*exit\s+anyway",
    re.IGNORECASE | re.DOTALL,
)

# Launch-time facts copied from the attempt dict onto a bound row by the first
# enrichment. Record-level keys (task_id, repo_slug, worktree, branch) are
# deliberately absent: enrich-dispatch refuses the first three.
BOUND_LAUNCH_FACTS = (
    "runtime_binary",
    "difficulty",
    "difficulty_proposed",
    "difficulty_confirmed",
    "status",
    "started_ns",
    "capture_before_sha256",
    "account_id",
    "personal",
    "launch_failed_cause",
)
CORE_CALL_TIMEOUT_SECS = 30


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


def _pane_run(herdr_cli: str, pane_id: str, line: str, env: dict[str, str]) -> None:
    if len(line.encode()) > PANE_RUN_MAX_BYTES:
        raise DispatchError("pane-prep: line-too-long")
    _run_herdr(herdr_cli, ["pane", "run", pane_id, line], env=env, json_result=False)


def _wait_marker(herdr_cli, pane_id, marker, timeout_ms, env) -> dict[str, Any]:
    observed = _run_herdr(
        herdr_cli,
        ["pane", "wait-output", pane_id, "--match", marker,
         "--timeout", str(timeout_ms), "--source", "recent-unwrapped"],
        env=env,
        timeout_secs=timeout_ms / 1000 + 5,
    )
    if (
        observed.get("type") != "output_matched"
        or observed.get("pane_id") != pane_id
        or observed.get("matched_line") != marker
    ):
        raise DispatchError("target pane account environment probe was not current")
    return observed


def _split_marker_line(marker: str) -> str:
    # Printed in two halves so the command echo never contains the marker.
    half = len(marker) // 2
    return f"printf '%s%s\\n' {shlex.quote(marker[:half])} {shlex.quote(marker[half:])}"


def _wait_for_shell(herdr_cli: str, pane_id: str, env: dict[str, str]) -> None:
    marker = f"HERDR_SHELL_{uuid.uuid4().hex[:16]}"
    _pane_run(herdr_cli, pane_id, _split_marker_line(marker), env)
    for _ in range(PANE_READY_ATTEMPTS):
        try:
            _wait_marker(herdr_cli, pane_id, marker, 5000, env)
            return
        except DispatchError:
            continue
    raise DispatchError("pane-prep: shell-not-ready")


def _await_pane_shell(
    herdr_cli: str, pane_id: str, workspace_id: str, cwd: Path, env: dict[str, str]
) -> None:
    """Retry the entry pane check while a fresh split pane's shell starts."""
    for attempt in range(SHELL_READY_POLLS):
        try:
            _validate_pane(herdr_cli, pane_id, workspace_id, cwd, env)
            return
        except DispatchError as exc:
            if str(exc) != NOT_AT_SHELL or attempt == SHELL_READY_POLLS - 1:
                raise
        time.sleep(SHELL_READY_POLL_SECS)


def _op_env_prep_line(cwd: str | os.PathLike[str], env: dict[str, str]) -> str | None:
    """Prep line that loads the project's op-env exports, or None without op.env."""
    try:
        located = subprocess.run(
            [str(OP_ENV), "locate", "--cwd", str(cwd)],
            env=env, capture_output=True, text=True, timeout=10, check=False,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    if not located:
        return None
    return 'eval "$(' + shlex.join([str(OP_ENV), "shell-exports", "--cwd", str(cwd)]) + ')"'


def _bind_pane_environment(
    herdr_cli: str,
    pane_id: str,
    workspace_id: str,
    cwd: str | os.PathLike[str],
    scope: dict,
    env: dict[str, str],
    *,
    prep_dir: Path,
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
                # The gh shim goes in front of the runtime dir, which can hold
                # the real gh (agent_runtime.arm_gh_shim, gh_post_shim.py).
                f'export PATH={shlex.quote(str(agent_runtime.GH_SHIM_DIR))}:"$PATH"',
                f'export BASH_ENV="${{BASH_ENV:-{agent_runtime.GH_SHIM_ANCHOR}}}"',
                "hash -r",
            ]
        )
        probes.append(
            f"printf '{token}:RUNTIME_BINARY=%s\\n' \"$(command -v '{runtime}')\""
        )
        probes.append(f"printf '{token}:GH=%s\\n' \"$(command -v gh)\"")
    # Only command text enters the prep script; values stay in the pane shell.
    # Codex shells drop exported variables (spec F18), so Claude panes only.
    ready_wait_ms = 10_000
    if runtime == "claude":
        op_env_line = _op_env_prep_line(cwd, env)
        if op_env_line is not None:
            assignments.append(op_env_line)
            ready_wait_ms = OP_ENV_READY_WAIT_MS
    ready_probe = _split_marker_line(ready_marker)
    stage = "shell-not-ready"
    script = None
    try:
        _wait_for_shell(herdr_cli, pane_id, env)
        stage = "script-write"
        prep_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        script = prep_dir / f"{uuid.uuid4().hex}.sh"
        fd = os.open(script, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write("\n".join([*assignments, *probes, ready_probe]) + "\n")
        stage = "script-source"
        _pane_run(herdr_cli, pane_id, f". {shlex.quote(str(script))}", env)
        stage = "environment-probe"
        observed = _wait_marker(herdr_cli, pane_id, ready_marker, ready_wait_ms, env)
        stage = "script-cleanup"
        script.unlink(missing_ok=True)
        script = None
        stage = "environment-mismatch"
        read = observed.get("read") if isinstance(observed, dict) else None
        text = read.get("text") if isinstance(read, dict) else None
        expected = {
            f"{token}:{key}={'__UNSET__' if value is None else value}"
            for key, value in bindings.items()
        }
        expected.add(ready_marker)
        if runtime_binary is not None:
            expected.add(f"{token}:RUNTIME_BINARY={runtime_binary}")
            expected.add(f"{token}:GH={agent_runtime.GH_SHIM_DIR / 'gh'}")
        if not isinstance(text, str) or not expected.issubset(set(text.splitlines())):
            raise DispatchError(
                "target pane account environment or runtime executable could not be verified"
            )
        stage = "pane-validate"
        _validate_pane(herdr_cli, pane_id, workspace_id, cwd, env)
    except (DispatchError, OSError) as exc:
        if script is not None:
            try:
                script.unlink(missing_ok=True)
            except OSError:
                pass  # a cleanup error must not replace the prep failure being reported
        if str(exc).startswith("pane-prep: "):
            raise
        # The caller records any pane-prep failure as a launch_failed row.
        raise DispatchError(f"pane-prep: {stage}: {exc}") from exc


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


def _live_agent_status(result: Any, agent: str, runtime: str, pane_id: str) -> str | None:
    """Read agent_status from an `agent get` reply, or None if it is not ours.

    Deliberately not `_validate_agent`: that helper requires an idle (or, for
    reprompt, done) interactive-ready agent, which is the pre-launch contract
    and the exact inverse of what a post-prompt reconciliation has to accept.
    """
    if not isinstance(result, dict) or result.get("type") not in (
        "agent_info",
        "agent_started",
    ):
        return None
    embedded = result.get("agent")
    record = embedded if isinstance(embedded, dict) else result
    if (
        record.get("name") != agent
        or record.get("agent") != runtime
        or record.get("pane_id") != pane_id
    ):
        return None
    status = record.get("agent_status")
    return status if isinstance(status, str) else None


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


class _LauncherRecords:
    """Launcher-scope attempt writer: the in-process owner-transaction path."""

    def __init__(self, rd, task_id, session, fence, repository, scope, repo_slug, todo_binding):
        self.rd = rd
        self.task_id = task_id
        self.session = session
        self.fence = fence
        self.repository = repository
        self.scope = scope
        self.repo_slug = repo_slug
        self.todo_binding = todo_binding

    def reserve(self, attempt: dict[str, Any]) -> dict[str, Any]:
        try:
            return _write_attempt(
                self.rd, self.task_id, self.session, self.fence, self.repository,
                self.scope, self.repo_slug, attempt, self.todo_binding,
            )
        except ValueError as exc:
            # owner_transaction refuses a stale or foreign fence with a bare
            # ValueError; the adapter's callers only handle DispatchError.
            raise DispatchError(f"launcher record write refused: {exc}") from exc

    def update(self, launch_id: str, **fields: Any) -> dict[str, Any]:
        try:
            return _update_attempt(
                self.rd, self.task_id, self.session, self.fence, self.repository,
                self.scope, self.repo_slug, launch_id, **fields,
            )
        except ValueError as exc:
            raise DispatchError(f"launcher record write refused: {exc}") from exc


class _BoundRecords:
    """Binding-scoped attempt writer: the core's reserve/enrich verbs as
    subprocesses, each followed by a read-back of the bound record.

    The adapter never writes a leads/ record itself, so the bound row keeps
    its sole-writer property (introduced only by reserve-dispatch, mutated
    only by enrich-dispatch)."""

    def __init__(self, *, rd, task_id, session, fence, repository, repo_slug,
                 binding, runtime, personal, cwd, env, todo_binding):
        self.rd = rd
        self.base = rd / "leads" / binding
        self.task_id = task_id
        self.session = session
        self.fence = fence
        self.repository = repository
        self.repo_slug = repo_slug
        self.binding = binding
        self.runtime = runtime
        self.personal = personal
        self.cwd = os.fspath(cwd)
        self.env = env
        self.todo_binding = todo_binding
        self.identity: tuple[str, ...] | None = None

    def _core(self, verb: str, *args: str) -> None:
        argv = [
            sys.executable, str(Path(core.__file__).resolve()), verb,
            "--repo-slug", self.repo_slug, "--repo-path", self.cwd,
            "--runtime", self.runtime,
        ]
        if self.personal:
            argv.append("--personal")
        argv += [
            "--session", self.session, "--fence", str(self.fence),
            "--binding", self.binding, "--task-id", self.task_id, *args,
        ]
        try:
            process = subprocess.run(
                argv, check=False, capture_output=True, text=True,
                timeout=CORE_CALL_TIMEOUT_SECS, env=self.env,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise DispatchError(
                f"bound record write failed: {verb}: {type(exc).__name__}"
            ) from exc
        if process.returncode != 0:
            lines = process.stderr.strip().splitlines() or ["no reason given"]
            raise DispatchError(f"bound record write refused: {verb}: {lines[0][:200]}")

    def _identity_args(self) -> list[str]:
        assert self.identity is not None
        launch_id, phase, _runtime, workspace_id, pane_id, source_head_sha = self.identity
        return [
            "--launch-id", launch_id, "--phase", phase,
            "--workspace-id", workspace_id, "--pane-id", pane_id,
            "--source-head-sha", source_head_sha,
        ]

    def _current(self) -> tuple[dict[str, Any], dict[str, Any]]:
        task = _read_task(self.base / "tasks" / f"{self.task_id}.json", self.task_id)
        workers = task.get("workers", [])
        row = workers[-1] if workers and isinstance(workers[-1], dict) else None
        if row is None or tuple(row.get(key) for key in core.ATTEMPT_FIELDS) != self.identity:
            raise DispatchError("bound reservation is not the current row")
        return task, row

    def reserve(self, attempt: dict[str, Any]) -> dict[str, Any]:
        self.identity = tuple(attempt[key] for key in core.ATTEMPT_FIELDS)
        route = ["--role", attempt["role"], "--agent", attempt["agent"],
                 "--model", attempt["model"]]
        if isinstance(attempt.get("effort"), str):
            route += ["--effort", attempt["effort"]]
        self._core("reserve-dispatch", *self._identity_args(), *route)
        facts = {key: attempt.get(key) for key in BOUND_LAUNCH_FACTS}
        self._core("enrich-dispatch", *self._identity_args(), "--json", json.dumps(facts))
        task, _row = self._current()
        _validate_task_context(task, self.repository, self.repo_slug)
        if ("todo_id" in task, task.get("todo_id")) != self.todo_binding:
            raise DispatchError("persisted TODO binding changed before dispatch")
        return task

    def update(self, launch_id: str, **fields: Any) -> dict[str, Any]:
        if self.identity is None or launch_id != self.identity[0]:
            raise DispatchError("readiness does not belong to the current attempt")
        self._core("enrich-dispatch", *self._identity_args(), "--json", json.dumps(fields))
        _task, row = self._current()
        # task_id is a record-level key the bound row never carries; the
        # in-memory copy needs it for metadata_argv only.
        return {**row, "task_id": self.task_id}


def _read_binding_record(rd: Path, binding: Any) -> dict[str, Any]:
    if not isinstance(binding, str) or not bindings.BINDING_ID_RE.fullmatch(binding):
        raise DispatchError("invalid binding id")
    try:
        record = bindings.read_binding(rd, binding)
    except ValueError as exc:
        raise DispatchError("unknown or corrupt dispatch binding") from exc
    if record is None:
        raise DispatchError("unknown or corrupt dispatch binding")
    return record


def _check_bound_launch(record: dict[str, Any], task_id: str, repository: dict) -> None:
    if record.get("status") != "claimed":
        raise DispatchError("binding is not claimed")
    if record.get("task_id") != task_id:
        raise DispatchError("binding does not name this task")
    if not _same_directory(record.get("workspace_root"), repository["root"]):
        raise DispatchError("binding workspace does not match the launch worktree")


def _attempt_context(prompt: str, attempt: dict[str, Any]) -> str:
    return (
        f"{prompt.rstrip()}\n\nLifecycle attempt context:\n"
        "This adapter block is authoritative over conflicting lifecycle fields in the task "
        "text. The reserved attempt is "
        f"launch_id={attempt['launch_id']} phase={attempt['phase']} "
        f"runtime={attempt['runtime']} workspace_id={attempt['workspace_id']} "
        f"pane_id={attempt['pane_id']} source_head_sha={attempt['source_head_sha']}. "
    )


def _lifecycle_prompt(
    prompt: str,
    attempt: dict[str, Any],
    task: dict[str, Any],
    base: Path,
    personal: bool,
    *,
    approval_mediated: bool,
    binding: str | None = None,
) -> str:
    if attempt["phase"] == "ship":
        launch_dir = core.ship_launch_dir(base, attempt["task_id"], attempt["launch_id"])
        return (
            f"{_attempt_context(prompt, attempt)}"
            "A ship attempt publishes no emit record and runs no core emitter. "
            f"Its result is {(launch_dir / 'ship.json').resolve()}, written last as the "
            "brief directs; the director reads it by this launch_id."
        )
    suffix = "review" if attempt["phase"] == "review" else "done"
    result = (base / "tasks" / f"{attempt['task_id']}.{suffix}.json").resolve()
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
    ]
    if binding is not None:
        command += ["--binding", binding]
    command += [
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
    elif binding is not None:
        command += ["--reviewed-base-sha", task["base_sha"]]
    context = (
        f"{_attempt_context(prompt, attempt)}"
        f"Publish the final result only with this emitter identity: {shlex.join(command)}. "
        f"Supply only its required outcome and final-result fields. The emitter writes {result} "
        f"and its lock under {coordination}."
    )
    if binding is not None and suffix == "review":
        context += (
            " This binding-scoped review emit also requires --reviewer-session "
            "<your own session id>; append it yourself, the adapter cannot know it."
        )
    if not approval_mediated:
        return context
    return (
        f"{context}\n\nLifecycle publication authorization:\n"
        "Keep the source tree read-only. You may request approval only for the exact emitter "
        "above. Do not request other writes. If that exact emitter approval is rejected, "
        "report blocked and do not claim completion."
    )


def ship_agent_name(launch_id: str) -> str:
    """Fit a ship launch id in herdr's 32-character agent name, keeping the hex tail."""
    if len(launch_id) <= 32:
        return launch_id
    return f"{launch_id[:-13][:19]}-{launch_id[-12:]}"


def _task_label_result(rd, task_id, herdr_cli, env):
    """Relabel the task's workspace from the record on disk; never raises."""
    try:
        task = _read_task(rd / "tasks" / f"{task_id}.json", task_id)
        label = core.task_label(task, core.task_ship_handoff(rd, task_id, task))
        return core.apply_workspace_label(task, label, herdr_cli=herdr_cli, env=env)
    except Exception as exc:  # noqa: BLE001 -- a label never changes the caller's outcome
        return {"status": "unsupported", "label": None, "workspace_id": None,
                "reason": (str(exc) or type(exc).__name__)[:200]}


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
    binding: str | None = None,
) -> dict[str, Any]:
    """Launch into an explicit existing shell pane and record strict provenance."""
    if phase not in PHASES:
        raise DispatchError(f"unsupported phase: {phase} (expected one of: {', '.join(PHASES)})")
    if binding is not None and phase not in core.DESCENDANT_PHASES:
        raise DispatchError("a binding-scoped launch supports only plan, implement, or review")
    if not core.valid_task_id(task_id) or not core.valid_workspace_id(workspace_id):
        raise DispatchError("invalid task or workspace identity")
    if not isinstance(prompt, str) or not prompt.strip():
        raise DispatchError("prompt must be non-empty text")
    if route.get("runtime") not in ("claude", "codex"):
        raise DispatchError("route runtime is unsupported")
    if phase == "ship" and (route["runtime"] != "claude" or sandbox != "read-only"):
        raise DispatchError("a ship launch requires the claude runtime and the read-only sandbox")
    if phase == "ship" and not core.valid_task_id(agent):
        raise DispatchError("a ship agent name must be a plain id")
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
    base_env = dict(child_env)
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
    base = rd
    if binding is not None:
        _check_bound_launch(_read_binding_record(rd, binding), task_id, repository)
        base = rd / "leads" / binding
    pending_task = _read_task(base / "tasks" / f"{task_id}.json", task_id)
    _validate_task_context(pending_task, repository, repo_slug)
    if binding is not None and phase == "review":
        head = pending_task.get("review_head_sha")
        if not isinstance(head, str) or head != repository["head"]:
            raise DispatchError(
                "a binding-scoped review dispatch requires review_head_sha equal to HEAD"
            )
    todo_binding = ("todo_id" in pending_task, pending_task.get("todo_id"))
    if todos_cli is None:
        todos_cli = (
            Path(__file__).resolve().parents[1] / "skills/todos/scripts/todos.sh"
        )
    _check_todo_ready(pending_task, repository["root"], todos_cli, child_env)
    if binding is None:
        records = _LauncherRecords(
            rd, task_id, session, fence, repository, scope, repo_slug, todo_binding
        )
    else:
        records = _BoundRecords(
            rd=rd, task_id=task_id, session=session, fence=fence,
            repository=repository, repo_slug=repo_slug, binding=binding,
            runtime=runtime, personal=personal, cwd=cwd, env=base_env,
            todo_binding=todo_binding,
        )
    agent_runtime._apply_launch_environment(child_env, scope)
    runtime_binary = _runtime_binary(runtime, child_env)
    _await_pane_shell(herdr_cli, pane_id, workspace_id, cwd, child_env)
    launch_id = f"{agent}-{uuid.uuid4().hex[:12]}"
    if phase == "ship":
        agent = ship_agent_name(launch_id)
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
        "capture_before_sha256": None,
        "account_id": scope["account_id"],
        "personal": personal,
        "repo_slug": repo_slug,
        "worktree": repository["root"],
        "branch": repository["branch"],
        "launch_failed_cause": None,
    }
    try:
        _bind_pane_environment(
            herdr_cli, pane_id, workspace_id, cwd, scope, child_env,
            prep_dir=rd / "prep", personal=personal,
            runtime=runtime, runtime_binary=runtime_binary,
        )
    except DispatchError as exc:
        if str(exc).startswith("pane-prep: "):
            # Status and cause in one write, so no row is failed without a cause.
            records.reserve({**attempt, "status": "launch_failed",
                             "launch_failed_cause": str(exc)[:200]})
        raise

    pre_capture = _run_herdr(
        herdr_cli,
        ["pane", "read", pane_id, "--source", "detection", "--lines", "200"],
        env=child_env,
        json_result=False,
    )
    assert isinstance(pre_capture, str)
    attempt["capture_before_sha256"] = hashlib.sha256(pre_capture.encode()).hexdigest()
    task = records.reserve(attempt)

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
            records.update(
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
        records.update(
            launch_id,
            status="ready",
            capture_after_sha256=capture_after_sha256,
        )
        launch_prompt = _lifecycle_prompt(
            prompt,
            attempt,
            task,
            base,
            personal,
            approval_mediated=runtime == "codex" and sandbox == "read-only",
            binding=binding,
        )
        # The reconciled region spans the prompt AND its reply parsing. A
        # --wait failure does not mean the prompt was not accepted, so the
        # agent is observed once before the attempt is called a failure.
        # _prompt_state must be inside: it binds prompt_state for both
        # branches, and it keeps an unexpected reply shape reconcilable
        # instead of fatal.
        try:
            prompt_result = _run_herdr(
                herdr_cli,
                [
                    "agent",
                    "prompt",
                    agent,
                    launch_prompt,
                    "--wait",
                    # Bound the wait to acceptance. herdr's default predicate
                    # is idle|done|blocked -- the first turn FINISHING -- so
                    # without --until a normally-long first turn times out and
                    # a live, briefed worker is recorded launch_failed.
                    "--until",
                    "working",
                    "--until",
                    "blocked",
                    "--timeout",
                    str(prompt_timeout_ms),
                ],
                env=child_env,
                timeout_secs=prompt_timeout_ms / 1000 + 5,
                json_result=True,
            )
            assert isinstance(prompt_result, dict)
            prompt_state = _prompt_state(prompt_result)
            prompt_wait = "accepted"
            prompt_wait_cause = None
        except DispatchError as exc:
            # A --wait failure is not proof the prompt was refused: it covers a
            # timeout, a transport fault, and an unexpected reply alike. Ask the
            # agent once. Only a live agent rescues the attempt; the re-poll's
            # own failure is swallowed so the recorded error stays the prompt's.
            # agent_blocked is herdr stating it refused the submission before
            # writing any input: delivery is PROVABLY absent, so no observation
            # can rescue it. Checked before polling, because an agent that
            # unblocks and starts an unrelated turn would otherwise read as
            # live. Matches the code result_object appends.
            if str(exc).endswith(": agent_blocked"):
                raise
            observed = None
            try:
                polled = _run_herdr(
                    herdr_cli,
                    ["agent", "get", agent],
                    env=child_env,
                    json_result=True,
                )
                observed = _live_agent_status(polled, agent, runtime, pane_id)
            except DispatchError:
                observed = None
            # Readiness proved the agent idle, so only a turn that began after
            # it can show working or done -- either way the brief landed.
            #
            # `blocked` is NOT accepted here, even though the wait itself may
            # match it. herdr refuses a submission to an already-blocked agent
            # with agent_blocked BEFORE writing any input, and `agent get`
            # cannot tell that refusal apart from a brief that was delivered
            # and then hit a permission prompt. Recording the refusal as
            # launched would strand a phantom worker the controller waits on
            # forever. On the accepted path the agent_prompted envelope proves
            # delivery, so `--until blocked` stays correct there.
            if observed not in ("working", "done"):
                raise
            prompt_state = observed
            prompt_wait = "late-ready"
            # Keep WHY the wait failed: late-ready alone cannot distinguish a
            # benign timeout from a transport fault or an unexpected reply.
            # Bounded because a nonzero exit carries herdr's whole stderr and
            # this string is persisted into the shared task record.
            prompt_wait_cause = str(exc)[:200]
        final_attempt = records.update(
            launch_id,
            status="launched",
            prompt_state=prompt_state,
            prompt_wait=prompt_wait,
            prompt_wait_cause=prompt_wait_cause,
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
            records.update(launch_id, status="launch_failed")
        except DispatchError:
            pass
        raise

    # Outside the try above: a label failure must never record launch_failed.
    if binding is not None:
        label = {"status": "skipped", "label": None, "workspace_id": None,
                 "reason": "lead-scope"}
    else:
        try:
            with core.owner_transaction(rd, session, fence, context=repository,
                                        scope=scope, expected_slug=repo_slug):
                label = _task_label_result(rd, task_id, herdr_cli, child_env)
        except Exception as exc:  # noqa: BLE001 -- a stale fence only loses the label
            label = {"status": "unsupported", "label": None, "workspace_id": None,
                     "reason": (str(exc) or type(exc).__name__)[:200]}

    inspected = inspect(
        repo_slug,
        task_id,
        phase,
        workspace_id,
        cwd=cwd,
        runtime=runtime,
        personal=personal,
        binding=binding,
    )
    candidate = inspected["completion_candidate"]
    return {
        "status": "launched",
        "launch_id": launch_id,
        "prompt_state": prompt_state,
        "prompt_wait": prompt_wait,
        "prompt_wait_cause": prompt_wait_cause,
        "completion_candidate": candidate,
        "completion_authoritative": False,
        "observed_model": None,
        "observed_effort": None,
        "observation": "not-exposed-by-herdr-agent-metadata",
        "strict_ready": False,
        "presentation": presentation,
        "label": label,
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
    binding: str | None = None,
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
    base = rd
    if binding is not None:
        _read_binding_record(rd, binding)
        base = rd / "leads" / binding
    task = _read_task(base / "tasks" / f"{task_id}.json", task_id)
    _validate_task_context(task, repository, repo_slug)
    workers = task.get("workers", [])
    matches = [
        worker
        for worker in workers
        if isinstance(worker, dict) and worker.get("phase") == phase
    ]
    attempt = matches[-1] if matches else None
    suffix = "review" if phase == "review" else "done"
    result_path = base / "tasks" / f"{task_id}.{suffix}.json"
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
    argv = ["agent", "prompt", agent, prompt, "--wait",
            "--until", "working", "--until", "blocked",
            "--timeout", str(prompt_timeout_ms)]
    # The invariant: the ONLY provably-retry-safe outcome is a process-CREATION
    # failure (the delivery binary never ran). Once the process has started,
    # every failure -- timeout, communication error, nonzero exit, undecodable
    # or unparseable output, or a non-agent_prompted reply -- is uncertain,
    # because the turn may already have been accepted. Never resend an uncertain.
    try:
        process = subprocess.run(
            [herdr_cli, *argv], env=env, check=False, capture_output=True,
            timeout=prompt_timeout_ms / 1000 + 5,
        )
    except (FileNotFoundError, PermissionError) as exc:
        raise _RejectedDelivery("reprompt delivery could not start") from exc
    except (subprocess.TimeoutExpired, OSError):
        return ("uncertain", None)  # started; outcome unknown
    if process.returncode != 0:
        return ("uncertain", None)
    try:
        stdout = process.stdout.decode("utf-8")
        result = result_object(stdout, "Herdr agent prompt")
        prompted = result.get("type") == "agent_prompted"
    except (DispatchError, ValueError, AttributeError):
        # Any failure to read a clean reply: the turn may have landed.
        return ("uncertain", None)
    if not prompted:
        return ("uncertain", None)
    return ("delivered", _prompt_state(result))


def reprompt(*, repo_slug, task_id, session, fence, workspace_id, launch_id,
             phase, cwd, prompt, runtime="claude", herdr_cli="herdr",
             env=None, prompt_timeout_ms=120_000, personal=False):
    """Append a follow-up turn to a named, still-live dispatched worker."""
    if phase not in PHASES:
        raise DispatchError(f"unsupported phase: {phase} (expected one of: {', '.join(PHASES)})")
    if phase == "ship":
        raise DispatchError("a ship launch is never reprompted; dispatch a fresh ship launch")
    if not core.valid_task_id(task_id) or not core.valid_workspace_id(workspace_id):
        raise DispatchError("invalid task or workspace identity")
    if not isinstance(launch_id, str) or not launch_id:
        raise DispatchError("launch_id must be non-empty text")
    if not isinstance(prompt, str) or not prompt.strip():
        raise DispatchError("prompt must be non-empty text")
    if isinstance(fence, bool) or not isinstance(fence, int) or fence < 1:
        raise DispatchError("fence must be a positive integer")
    if (isinstance(prompt_timeout_ms, bool)
            or not isinstance(prompt_timeout_ms, int)
            or not 0 < prompt_timeout_ms <= 300_000):
        # Upper-bounded so a pathological value cannot overflow subprocess
        # timeout math during delivery and strand a recorded intent.
        raise DispatchError(
            "prompt_timeout_ms must be between 1 and 300000"
        )
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
            if target.get("exit_requested"):
                raise DispatchError(
                    "exit was requested for this launch; relaunch for further work")
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

    # Live-agent validation: idle or done, interactive-ready, on the recorded
    # pane. Read-only herdr query, safe outside the fence; a failure here
    # delivered nothing, so intent is marked failed (retry-safe), not orphaned.
    try:
        current = _run_herdr(herdr_cli, ["agent", "get", agent], env=child_env,
                             json_result=True)
        assert isinstance(current, dict)
        _validate_agent(current, agent, runtime, pane_id, states=AGENT_STATES)
    except (DispatchError, OSError, ValueError) as exc:
        # Readiness probe failed (validation, transport, or a decode/parse
        # error). Nothing was delivered, so mark the intent failed (retry-safe)
        # rather than stranding it at "starting", and refuse cleanly.
        _mark_reprompt(rd, task_id, session, fence, repository, scope, repo_slug,
                       launch_id, seq, status="failed", best_effort=True)
        if isinstance(exc, DispatchError):
            raise
        raise DispatchError(
            f"reprompt could not confirm the live agent: {exc}"
        ) from exc

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
        # Best-effort re-persist the true outcome in a fresh transaction so the
        # entry is not stranded at "starting" -- a "delivered-unrecorded" entry
        # does not block a later distinct pass, and a persisted "uncertain" one
        # correctly does. If this also fails (storage still down), the entry
        # stays "starting" and blocks pending manual reconciliation, which is
        # the safe fallback.
        _mark_reprompt(rd, task_id, session, fence, repository, scope, repo_slug,
                       launch_id, seq, status=status,
                       prompt_state=delivered["state"], best_effort=True)
        return {"status": status, "launch_id": launch_id, "phase": phase,
                "reprompt_seq": seq, "prompt_state": delivered["state"],
                "observation": REPROMPT_OBSERVATION}

    result_status = "reprompted" if delivered["outcome"] == "delivered" else "uncertain"
    return {"status": result_status, "launch_id": launch_id, "phase": phase,
            "reprompt_seq": seq, "prompt_state": delivered["state"],
            "observation": REPROMPT_OBSERVATION}


def _settle_context(repo_slug, task_id, workspace_id, cwd, runtime, personal, env, verb):
    if not core.valid_task_id(task_id) or not core.valid_workspace_id(workspace_id):
        raise DispatchError("invalid task or workspace identity")
    if runtime not in ("claude", "codex"):
        raise DispatchError("route runtime is unsupported")
    child_env = dict(os.environ if env is None else env)
    if child_env.get("HERDR_ENV") != "1":
        raise DispatchError(f"{verb} requires a Herdr-managed environment")
    try:
        repository, scope = agent_runtime.execution_context(cwd, runtime, personal)
    except agent_runtime.RouteError as exc:
        raise DispatchError(str(exc)) from exc
    if repo_slug != _expected_slug(repository, cwd):
        raise DispatchError("repo slug does not match repository context")
    return child_env, repository, scope, _payload_repo_dir(scope, repo_slug)


def _sidecar(rd: Path, task_id: str, suffix: str) -> dict[str, Any] | None:
    try:
        record = json.loads(core.read_payload_text(rd / "tasks" / f"{task_id}{suffix}"))
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as exc:
        raise DispatchError(f"settlement record is unreadable: {task_id}{suffix}") from exc
    return record if isinstance(record, dict) else None


def _agents_snapshot(herdr_cli, env):
    agents = _run_herdr(herdr_cli, ["agent", "list"], env=env).get("agents")
    if not isinstance(agents, list):
        raise DispatchError("herdr agent or pane list is malformed")
    return agents


def _snapshot(herdr_cli, workspace_id, env):
    agents = _agents_snapshot(herdr_cli, env)
    panes = _run_herdr(herdr_cli, ["pane", "list", "--workspace", workspace_id],
                       env=env).get("panes")
    if not isinstance(panes, list):
        raise DispatchError("herdr agent or pane list is malformed")
    return (agents,
            [p for p in panes if isinstance(p, dict) and p.get("workspace_id") == workspace_id])


def _malformed_agent(agent):
    # Unplaceable in any pane. A missing name is normal: hand-started agents.
    return not isinstance(agent, dict) or not (
        isinstance(agent.get("pane_id"), str) and agent["pane_id"])


def _other_occupants(agents, row):
    """List members that keep the row's pane: malformed ones, or other agents in it."""
    return [a for a in agents if _malformed_agent(a)
            or (a.get("pane_id") == row["pane_id"] and a.get("name") != row["agent"])]


def _row_agent(herdr_cli, row, env):
    """Whether the row's named agent is ("gone", None), ("present", record) or ("unknown", None)."""
    try:
        result = _run_herdr(herdr_cli, ["agent", "get", row["agent"]], env=env)
    except DispatchError as exc:
        return ("gone", None) if str(exc).endswith(": agent_not_found") else ("unknown", None)
    record = result.get("agent")
    if (result.get("type") != "agent_info" or not isinstance(record, dict)
            or record.get("name") != row["agent"]
            or not isinstance(record.get("pane_id"), str) or not record["pane_id"]):
        return "unknown", None
    if record["pane_id"] != row["pane_id"]:
        return "gone", None
    return "present", record


def _poll(check):
    deadline = time.monotonic() + SETTLE_WAIT_SECS
    for attempt in range(SETTLE_POLLS):
        if check():
            return True
        if attempt == SETTLE_POLLS - 1 or time.monotonic() >= deadline:
            return False
        time.sleep(SETTLE_POLL_SECS)
    return False


def _await_gone(herdr_cli, row, env):
    return _poll(lambda: _row_agent(herdr_cli, row, env)[0] == "gone")


# /exit delivery is confirmed only by these two SKILL.md codes: stalled is
# the accepted-submission code, timeout is documented only as not itself a
# failure. Everything else (incl. agent_blocked) fails closed by default.
_EXIT_DELIVERED_PREFIX = "Herdr agent prompt did not report success: "
_EXIT_DELIVERED_CODES = frozenset({"agent_prompt_stalled", "timeout"})

# herdr says the agent is gone: agent_not_running (it left the pane during
# --wait) or agent_not_found (nothing to deliver to). Only a fresh agent
# get decides; settle never reads the pane or sends keys after these.
_EXIT_GONE_CODES = frozenset({"agent_not_running", "agent_not_found"})


def _exit_agent(herdr_cli, row, workspace_id, env):
    try:
        result = _run_herdr(herdr_cli, ["agent", "prompt", row["agent"], "/exit", "--wait",
                               "--timeout", str(EXIT_WAIT_MS)],
                   env=env, timeout_secs=EXIT_WAIT_MS / 1000 + 5)
        # A well-formed-but-wrong result (e.g. {"id": ..., "result": {}}) is
        # not proof of delivery; only a genuine agent_prompted envelope is.
        _prompt_state(result)
    except DispatchError as exc:
        message = str(exc)
        code = (message[len(_EXIT_DELIVERED_PREFIX):]
                if message.startswith(_EXIT_DELIVERED_PREFIX) else None)
        if code in _EXIT_GONE_CODES:
            return "exited" if _await_gone(herdr_cli, row, env) else "still-live"
        if code not in _EXIT_DELIVERED_CODES:
            return "still-live"
    if _row_agent(herdr_cli, row, env)[0] != "gone":
        text = _run_herdr(herdr_cli, ["pane", "read", row["pane_id"], "--source", "detection",
                                      "--lines", "20"], env=env, json_result=False)
        if BACKGROUND_EXIT_MENU_RE.search(text):
            # Target the agent by name, not the pane. herdr resolves TARGET at
            # call time and refuses with agent_not_found if it is gone, so there
            # is no occupant snapshot left to go stale between read and send.
            try:
                _run_herdr(herdr_cli, ["agent", "send-keys", row["agent"], "1", "enter"],
                           env=env, json_result=False)
            except DispatchError as exc:
                if str(exc).endswith(": agent_not_found"):
                    return "exited"
                raise
    return "exited" if _await_gone(herdr_cli, row, env) else "still-live"


def _pane_ids(panes):
    return {p["pane_id"] for p in panes if isinstance(p.get("pane_id"), str) and p["pane_id"]}


def _pane_verdict(task, row, agents, panes, reasons):
    pane_id = row["pane_id"]
    if pane_id not in [p.get("pane_id") for p in panes]:
        return "absent"
    # Distinct ids: herdr can list one pane twice.
    if len(_pane_ids(panes)) < 2:
        return "kept-last-pane"
    sharing = [i for i, w in enumerate(task["workers"])
               if isinstance(w, dict) and w.get("pane_id") == pane_id]
    # The first row's pane is the workspace root; a repair may still follow.
    if pane_id == task["workers"][0].get("pane_id"):
        return "kept-shared"
    if not all(core.row_releases_pane(task, i, reasons(i)) for i in sharing):
        return "kept-shared"
    if any(reasons(i) is None for i in sharing):
        return "kept-unsettled"
    if _other_occupants(agents, row):
        return "kept-occupied"
    return "close"


def _pane_idle(herdr_cli, pane_id, env):
    """True only when the pane's foreground pid equals its shell pid.

    An empty or failed process inspection is unverified, not idle.
    """
    try:
        result = _run_herdr(herdr_cli, ["pane", "process-info", "--pane", pane_id], env=env)
    except DispatchError:
        return False
    info = result.get("process_info") if isinstance(result, dict) else None
    if not isinstance(info, dict):
        return False
    shell_pid = info.get("shell_pid")
    foreground = info.get("foreground_processes")
    if isinstance(shell_pid, bool) or not isinstance(shell_pid, int) or shell_pid < 1:
        return False
    # An empty list is `all([])`-vacuously "idle" but is also herdr's shape
    # for a failed process inspection; a real idle shell reports itself as
    # one foreground entry, never zero.
    if not isinstance(foreground, list) or not foreground:
        return False
    return all(isinstance(item, dict) and item.get("pid") == shell_pid for item in foreground)


def _await_pane_idle(herdr_cli, pane_id, env):
    return _poll(lambda: _pane_idle(herdr_cli, pane_id, env))


def _occupant_proven(task, index, panes):
    # The pane's launch token names this attempt, and no later row claims the
    # pane: a successor may be reserved (row written) before its agent starts.
    row = task["workers"][index]
    entry = next((p for p in panes if p.get("pane_id") == row["pane_id"]), None)
    tokens = entry.get("tokens") if entry else None
    if not isinstance(tokens, dict) or tokens.get("launch_id") != row["launch_id"]:
        return False
    return not any(isinstance(w, dict) and w.get("pane_id") == row["pane_id"]
                   for w in task["workers"][index + 1:])


def _mark_exit_requested(task_path, task, index, reason):
    # Persisted before /exit so an interrupted exit stays authorized (rule 0b).
    task["workers"][index] = {**task["workers"][index], "exit_requested": reason}
    core.write_json_atomic(task_path, task)


def _settle_index(herdr_cli, task_path, task, index, reasons, workspace_id, env):
    row = task["workers"][index]
    reason = reasons(index)
    base = {"launch_id": row.get("launch_id"), "reason": reason}
    if reason is None or not _nonempty_str_row(row):
        return {**base, "status": "not-settled"}
    state, record = _row_agent(herdr_cli, row, env)
    if state == "unknown":
        raise DispatchError("settle could not read the row's agent")
    agents, panes = _snapshot(herdr_cli, workspace_id, env)
    agent = "absent"
    if state == "present" and record.get("agent_status") not in AGENT_STATES:
        return {**base, "status": "busy", "agent": "busy", "pane": "untouched"}
    if state == "present":
        if not _occupant_proven(task, index, panes):
            return {**base, "status": "occupant-unverified", "agent": "live",
                    "pane": "untouched"}
        if not row.get("exit_requested"):
            _mark_exit_requested(task_path, task, index, reason)
        agent = _exit_agent(herdr_cli, row, workspace_id, env)
        agents, panes = _snapshot(herdr_cli, workspace_id, env)
        if agent == "exited" and _row_agent(herdr_cli, row, env)[0] != "gone":
            # The exit verdict can go stale before this read; trust the
            # freshest one before deciding whether to close.
            agent = "still-live"
    pane = _pane_verdict(task, row, agents, panes, reasons)
    if pane == "close" and agent == "still-live":
        # The agent never actually exited; keep the pane rather than close
        # one whose agent is still working.
        pane = "kept-occupied"
    elif pane == "close" and not _await_pane_idle(herdr_cli, row["pane_id"], env):
        # No registered agent is live, but an untracked live process (the
        # user's own shell command) could still occupy the pane.
        pane = "kept-occupied"
    elif pane == "close":
        # herdr has no compare-and-close; re-read right before closing and
        # keep the pane on any change since the verdict snapshot.
        fresh_agents, fresh_panes = _snapshot(herdr_cli, workspace_id, env)
        if _pane_ids(fresh_panes) != _pane_ids(panes):
            pane = "kept-changed"
        elif _row_agent(herdr_cli, row, env)[0] != "gone":
            agent, pane = "still-live", "kept-occupied"
        elif _other_occupants(fresh_agents, row):
            pane = "kept-occupied"
        else:
            _run_herdr(herdr_cli, ["pane", "close", row["pane_id"]], env=env)
            pane = "closed"
    status = "exit-incomplete" if agent == "still-live" and pane != "closed" else "settled"
    return {**base, "status": status, "agent": agent, "pane": pane}


def _nonempty_str_row(row):
    return all(isinstance(row.get(k), str) and row[k] for k in ("agent", "pane_id"))


def _settlement_reasons(task, rd, task_id, head):
    done = _sidecar(rd, task_id, ".done.json")
    review = _sidecar(rd, task_id, ".review.json")
    payload_root = rd.parent.parent
    ship_report = core.ship_report_ns(rd, task_id)
    ship_handoffs = core.ship_handoff_launches(rd, task_id, task)
    return lambda i: core.row_settlement(task, i, done=done, review=review,
                                         head=head, payload_root=payload_root,
                                         ship_report=ship_report,
                                         ship_handoffs=ship_handoffs)


def settle(*, repo_slug, task_id, session, fence, workspace_id, launch_id, cwd,
           runtime="claude", herdr_cli="herdr", env=None, personal=False):
    """Exit a settled worker row's idle agent and close its pane once every row that used it releases it."""
    child_env, repository, scope, rd = _settle_context(
        repo_slug, task_id, workspace_id, cwd, runtime, personal, env, "settle")
    try:
        with core.owner_transaction(rd, session, fence, context=repository, scope=scope,
                                    expected_slug=repo_slug):
            task_path = rd / "tasks" / f"{task_id}.json"
            task = _read_task(task_path, task_id)
            _validate_task_context(task, repository, repo_slug)
            index = next((i for i, w in enumerate(task.get("workers", []))
                          if isinstance(w, dict) and w.get("launch_id") == launch_id
                          and w.get("workspace_id") == workspace_id), None)
            if index is None:
                raise DispatchError("no worker row for that launch in the workspace")
            reasons = _settlement_reasons(task, rd, task_id, repository["head"])
            result = _settle_index(herdr_cli, task_path, task, index, reasons,
                                   workspace_id, child_env)
            return {**result, "label": _task_label_result(rd, task_id, herdr_cli, child_env)}
    except (OSError, ValueError) as exc:
        raise DispatchError(f"settle could not hold the owner fence: {exc}") from exc


def sweep(*, repo_slug, task_id, session, fence, workspace_id, cwd,
          runtime="claude", herdr_cli="herdr", env=None, personal=False):
    """Settle every worker row of the task in one workspace, oldest first."""
    child_env, repository, scope, rd = _settle_context(
        repo_slug, task_id, workspace_id, cwd, runtime, personal, env, "sweep")
    try:
        with core.owner_transaction(rd, session, fence, context=repository, scope=scope,
                                    expected_slug=repo_slug):
            task_path = rd / "tasks" / f"{task_id}.json"
            task = _read_task(task_path, task_id)
            _validate_task_context(task, repository, repo_slug)
            reasons = _settlement_reasons(task, rd, task_id, repository["head"])
            rows = [_settle_index(herdr_cli, task_path, task, i, reasons,
                                  workspace_id, child_env)
                    for i, w in enumerate(task.get("workers", []))
                    if isinstance(w, dict) and w.get("workspace_id") == workspace_id]
            return {"status": "swept", "rows": rows}
    except (OSError, ValueError) as exc:
        raise DispatchError(f"sweep could not hold the owner fence: {exc}") from exc


def runtime_main(argv: list[str] | None = None) -> int:
    from herdr_dispatch_cli import runtime_main as cli_runtime_main

    return cli_runtime_main(argv)


def main(argv: list[str] | None = None) -> int:
    from herdr_dispatch_cli import main as cli_main

    return cli_main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
