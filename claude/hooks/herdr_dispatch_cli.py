"""Command-line and protocol transport for runtime and Herdr dispatch adapters."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any

import agent_runtime


def _dispatch_error(message: str) -> RuntimeError:
    from herdr_dispatch import DispatchError

    return DispatchError(message)


def result_object(output: str, operation: str) -> dict[str, Any]:
    try:
        record = json.loads(output)
    except (ValueError, RecursionError) as exc:
        # ValueError covers JSONDecodeError plus value faults such as an integer
        # over the str-conversion limit; RecursionError covers deeply nested
        # input. All are malformed replies, not caller faults.
        raise _dispatch_error(f"{operation} returned malformed JSON") from exc
    if (
        not isinstance(record, dict)
        or not isinstance(record.get("id"), str)
        or "error" in record
    ):
        raise _dispatch_error(f"{operation} did not report success")
    result = record.get("result")
    if not isinstance(result, dict):
        raise _dispatch_error(f"{operation} result is not an object")
    return result


def run_herdr(
    executable: str,
    argv: list[str],
    *,
    env: dict[str, str],
    timeout_secs: float = 10,
    json_result: bool = True,
) -> dict[str, Any] | str:
    try:
        process = subprocess.run(
            [executable, *argv],
            env=env,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_secs,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise _dispatch_error(f"Herdr command failed: {argv[0]} {argv[1]}") from exc
    if process.returncode != 0:
        detail = process.stderr.strip() or process.stdout.strip() or "no detail"
        raise _dispatch_error(f"Herdr command failed: {detail}")
    return (
        result_object(process.stdout, f"Herdr {argv[0]} {argv[1]}")
        if json_result
        else process.stdout
    )


def fresh_codex_hook_review_required(before: str, after: str) -> bool:
    fresh_lines = list(
        (Counter(after.splitlines()) - Counter(before.splitlines())).elements()
    )
    fresh = "\n".join(fresh_lines)
    pending_count = re.search(
        r"\b[1-9][0-9]* hooks? needs? review before (?:it|they) can run\b", fresh
    )
    new_count = re.search(
        r"\b(?:1 hook is|(?:[2-9]|[1-9][0-9]+) hooks are) new or changed\.",
        fresh,
    )
    initial = all(
        marker in fresh
        for marker in (
            "Hooks need review",
            "Hooks can run outside the sandbox after you trust",
            "1. Review hooks",
            "2. Trust all and continue",
            "3. Continue without trusting (hooks won't run)",
            "Press enter to confirm or esc to go back",
        )
    )
    overview = "Press t to trust all; enter to review hooks;" in fresh
    selected = all(
        marker in fresh
        for marker in (
            "New hook - review required",
            "Press t to trust; esc to go back",
        )
    )
    return (new_count is not None and initial) or (
        pending_count is not None and (overview or selected)
    )


def pane_record(result: dict[str, Any]) -> dict[str, Any]:
    if result.get("type") != "pane_info":
        raise _dispatch_error("Herdr pane get returned an unexpected result type")
    pane = result.get("pane")
    if not isinstance(pane, dict):
        raise _dispatch_error("Herdr pane get omitted pane data")
    return pane


def same_directory(left: Any, right: str | os.PathLike[str]) -> bool:
    if not isinstance(left, str) or not left:
        return False
    try:
        return os.path.samefile(left, right)
    except OSError:
        return Path(left).resolve() == Path(right).resolve()


def validate_pane(
    herdr_cli: str,
    pane_id: str,
    workspace_id: str,
    cwd: str | os.PathLike[str],
    env: dict[str, str],
) -> None:
    pane_result = run_herdr(
        herdr_cli, ["pane", "get", pane_id], env=env, json_result=True
    )
    assert isinstance(pane_result, dict)
    pane = pane_record(pane_result)
    if pane.get("pane_id") != pane_id or pane.get("workspace_id") != workspace_id:
        raise _dispatch_error("pane does not match the designated workspace")
    if not same_directory(pane.get("cwd"), cwd):
        raise _dispatch_error("pane does not match the designated worktree")

    process_result = run_herdr(
        herdr_cli,
        ["pane", "process-info", "--pane", pane_id],
        env=env,
        json_result=True,
    )
    assert isinstance(process_result, dict)
    if process_result.get("type") != "pane_process_info":
        raise _dispatch_error("Herdr process info returned an unexpected result type")
    process_info = process_result.get("process_info")
    if not isinstance(process_info, dict) or process_info.get("pane_id") != pane_id:
        raise _dispatch_error("process data belongs to a different pane")
    shell_pid = process_info.get("shell_pid")
    foreground = process_info.get("foreground_processes")
    if (
        isinstance(shell_pid, bool)
        or not isinstance(shell_pid, int)
        or shell_pid < 1
        or not isinstance(foreground, list)
        or any(not isinstance(item, dict) for item in foreground)
        or any(item.get("pid") != shell_pid for item in foreground)
    ):
        raise _dispatch_error("designated pane is not at an interactive shell")
    process_cwds = [item.get("cwd") for item in foreground if item.get("cwd")]
    if process_cwds and not all(same_directory(item, cwd) for item in process_cwds):
        raise _dispatch_error("pane shell does not match the designated worktree")


def validate_agent(
    result: dict[str, Any],
    agent: str,
    runtime: str,
    pane_id: str,
    expected_argv: list[str] | None = None,
) -> None:
    if result.get("type") not in ("agent_started", "agent_info"):
        raise _dispatch_error("agent readiness has an unexpected result type")
    embedded = result.get("agent")
    record = embedded if isinstance(embedded, dict) else result
    if (
        record.get("name") != agent
        or record.get("agent") != runtime
        or record.get("pane_id") != pane_id
        or record.get("agent_status") != "idle"
        or record.get("interactive_ready") is not True
        or record.get("launch_pending") is True
    ):
        raise _dispatch_error("agent readiness does not belong to the current attempt")
    if expected_argv is not None:
        observed = result.get("argv")
        if (
            not isinstance(observed, list)
            or not observed
            or Path(observed[0]).name != runtime
            or observed[1:] != expected_argv[1:]
        ):
            raise _dispatch_error(
                "agent launch argv does not match the current attempt"
            )


def prompt_state(result: dict[str, Any]) -> str:
    if result.get("type") != "agent_prompted":
        raise _dispatch_error("agent prompt returned an unexpected result type")
    state = None
    if isinstance(result.get("agent"), dict):
        state = result["agent"].get("agent_status")
    return state if isinstance(state, str) else "unknown"


def _compact_title(phase: str, task_id: str) -> str:
    text = re.sub(r"[^A-Za-z0-9_-]+", "-", task_id).strip("-")
    return f"{phase} {text}"[:40]


def metadata_argv(
    attempt: dict[str, Any], state: str, sequence: int, *, executable: str = "herdr"
) -> list[str]:
    """Build a display-only metadata update fenced by source, sequence and token."""
    if state not in ("idle", "working", "blocked", "done", "unknown"):
        raise _dispatch_error(f"unsupported metadata state: {state}")
    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 0:
        raise _dispatch_error("metadata sequence must be a non-negative integer")
    required = ("launch_id", "phase", "role", "pane_id", "task_id")
    if any(
        not isinstance(attempt.get(key), str) or not attempt[key] for key in required
    ):
        raise _dispatch_error("attempt lacks metadata identity")
    return [
        executable,
        "pane",
        "report-metadata",
        attempt["pane_id"],
        "--source",
        "agent-runtime",
        "--title",
        _compact_title(attempt["phase"], attempt["task_id"]),
        "--display-agent",
        attempt["role"],
        "--state-label",
        f"{state}={state}",
        "--token",
        f"launch_id={attempt['launch_id']}",
        "--seq",
        str(sequence),
        "--ttl-ms",
        "3600000",
    ]


def _json_arg(value: str | None, name: str) -> dict[str, Any] | None:
    if value is None:
        return None
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise agent_runtime.RouteError(f"{name} must be valid JSON: {exc.msg}") from exc
    if not isinstance(parsed, dict):
        raise agent_runtime.RouteError(f"{name} must be a JSON object")
    return parsed


def _add_route_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--runtime", required=True, choices=("claude", "codex"))
    role_or_step = parser.add_mutually_exclusive_group(required=True)
    role_or_step.add_argument("--role")
    role_or_step.add_argument("--step")
    parser.add_argument("--risk", default="normal")
    parser.add_argument("--config-json")
    parser.add_argument("--capabilities-json")
    parser.add_argument("--provisional", action="store_true")


def _route(args: argparse.Namespace) -> dict[str, Any]:
    capabilities = _json_arg(args.capabilities_json, "capabilities-json")
    if capabilities is None:
        capabilities = agent_runtime.discover_capabilities(args.runtime)
    config = _json_arg(args.config_json, "config-json") or {}
    if args.provisional:
        config = {**config, "provisional": True}
    role = args.role if args.role is not None else agent_runtime.role_for_step(args.step)
    return agent_runtime.resolve_route(
        args.runtime, role, args.risk, config, capabilities
    )


def _runtime_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Runtime route and bounded execution")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("route", "launch-plan", "run"):
        command = commands.add_parser(name)
        _add_route_args(command)
        if name != "route":
            command.add_argument("--cwd", required=True)
            command.add_argument(
                "--sandbox", required=True, choices=agent_runtime.SANDBOXES
            )
            command.add_argument("--timeout-secs", type=float, required=name == "run")
            command.add_argument("--max-turns", type=int)
            command.add_argument("--max-budget-usd", type=float)
            command.add_argument("--personal", action="store_true")
        if name == "launch-plan":
            command.add_argument(
                "--mode", default="interactive", choices=("interactive", "headless")
            )
        elif name == "run":
            command.add_argument("--prompt-file")
    return parser


def _check_codex_limits(args: argparse.Namespace) -> None:
    if args.runtime != "codex":
        return
    if args.max_turns is not None:
        raise agent_runtime.UnsupportedLimitError("Codex cannot enforce max_turns")
    if args.max_budget_usd is not None:
        raise agent_runtime.UnsupportedLimitError("Codex cannot enforce max_budget_usd")


def runtime_main(argv: list[str] | None = None) -> int:
    args = _runtime_parser().parse_args(argv)
    try:
        route = _route(args)
        if args.command == "route":
            output = route
        elif args.command == "launch-plan":
            _check_codex_limits(args)
            _repository, scope = agent_runtime.execution_context(
                args.cwd, args.runtime, args.personal
            )
            output = {
                "route": route,
                "argv": agent_runtime.launch_argv(
                    route, args.cwd, args.sandbox, args.mode, scope=scope
                ),
                "cwd": args.cwd,
                "limits": {
                    key: getattr(args, key)
                    for key in ("timeout_secs", "max_turns", "max_budget_usd")
                },
                "environment": {
                    "unset": [
                        key
                        for key, value in scope["launch_env"].items()
                        if value is None
                    ],
                    "set": [
                        key
                        for key, value in scope["launch_env"].items()
                        if value is not None
                    ],
                },
                "account_kind": scope["kind"],
                "account_id": scope["account_id"],
                "scope_id": scope["scope_id"],
            }
        else:
            prompt = (
                Path(args.prompt_file).read_text()
                if args.prompt_file
                else sys.stdin.read()
            )
            output = agent_runtime.run_bounded(
                route,
                prompt,
                args.cwd,
                args.sandbox,
                timeout_secs=args.timeout_secs,
                max_turns=args.max_turns,
                max_budget_usd=args.max_budget_usd,
                personal=args.personal,
            )
        print(json.dumps(output, sort_keys=True))
        return 1 if args.command == "run" and output["status"] != "success" else 0
    except (
        OSError,
        agent_runtime.RouteError,
        agent_runtime.UnsupportedLimitError,
    ) as exc:
        print(json.dumps({"status": "error", "error": str(exc)}, sort_keys=True))
        return 2


def _dispatch_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    launch = commands.add_parser("launch")
    for flag in (
        "repo-slug",
        "task-id",
        "session",
        "workspace-id",
        "pane-id",
        "phase",
        "agent",
        "route-json",
        "cwd",
        "sandbox",
        "prompt-file",
    ):
        launch.add_argument(f"--{flag}", required=True)
    launch.add_argument("--fence", required=True, type=int)
    launch.add_argument("--start-timeout-ms", type=int, default=30_000)
    launch.add_argument("--prompt-timeout-ms", type=int, default=120_000)
    launch.add_argument("--personal", action="store_true")
    inspect = commands.add_parser("inspect")
    for flag in ("repo-slug", "task-id", "phase", "workspace-id", "cwd"):
        inspect.add_argument(f"--{flag}", required=True)
    inspect.add_argument("--runtime", default="claude", choices=("claude", "codex"))
    inspect.add_argument("--personal", action="store_true")
    wake = commands.add_parser("wake")
    for flag in ("thread-id", "event", "repo-slug", "workspace-id"):
        wake.add_argument(f"--{flag}", required=True)
    wake.add_argument("--queue-validated", action="store_true")
    reprompt = commands.add_parser("reprompt")
    for flag in (
        "repo-slug",
        "task-id",
        "session",
        "workspace-id",
        "launch-id",
        "phase",
        "cwd",
        "prompt-file",
    ):
        reprompt.add_argument(f"--{flag}", required=True)
    reprompt.add_argument("--fence", required=True, type=int)
    reprompt.add_argument("--runtime", default="claude", choices=("claude", "codex"))
    reprompt.add_argument("--prompt-timeout-ms", type=int, default=120_000)
    reprompt.add_argument("--personal", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    import herdr_dispatch

    args = _dispatch_parser().parse_args(argv)
    try:
        if args.command == "launch":
            route = _json_arg(args.route_json, "route-json")
            output = herdr_dispatch.launch(
                repo_slug=args.repo_slug,
                task_id=args.task_id,
                session=args.session,
                fence=args.fence,
                workspace_id=args.workspace_id,
                pane_id=args.pane_id,
                phase=args.phase,
                agent=args.agent,
                route=route,
                cwd=args.cwd,
                sandbox=args.sandbox,
                prompt=Path(args.prompt_file).read_text(),
                start_timeout_ms=args.start_timeout_ms,
                prompt_timeout_ms=args.prompt_timeout_ms,
                personal=args.personal,
            )
        elif args.command == "inspect":
            output = herdr_dispatch.inspect(
                args.repo_slug,
                args.task_id,
                args.phase,
                args.workspace_id,
                cwd=args.cwd,
                runtime=args.runtime,
                personal=args.personal,
            )
        elif args.command == "reprompt":
            output = herdr_dispatch.reprompt(
                repo_slug=args.repo_slug,
                task_id=args.task_id,
                session=args.session,
                fence=args.fence,
                workspace_id=args.workspace_id,
                launch_id=args.launch_id,
                phase=args.phase,
                cwd=args.cwd,
                prompt=Path(args.prompt_file).read_text(),
                runtime=args.runtime,
                prompt_timeout_ms=args.prompt_timeout_ms,
                personal=args.personal,
            )
        else:
            output = herdr_dispatch.wake(
                args.thread_id,
                event=args.event,
                repo_slug=args.repo_slug,
                workspace_id=args.workspace_id,
                queue_validated=args.queue_validated,
            )
        print(json.dumps(output, sort_keys=True))
        return 3 if output.get("status") in ("blocked", "unsupported") else 0
    except (
        herdr_dispatch.DispatchError,
        OSError,
        UnicodeError,
        agent_runtime.RouteError,
    ) as exc:
        # UnicodeError covers a prompt-file that is not valid UTF-8, so a bad
        # --prompt-file returns structured error JSON instead of a traceback.
        print(json.dumps({"status": "error", "error": str(exc)}, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
