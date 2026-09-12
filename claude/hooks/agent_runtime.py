#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import math
import os
import signal
import subprocess
from pathlib import Path
from typing import Any


class RouteError(ValueError):
    pass


class UnsupportedLimitError(ValueError):
    pass


CODEX_MODELS = ("gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna")
CLAUDE_MODELS = ("fable", "opus", "sonnet", "haiku")
EFFORTS = ("low", "medium", "high", "xhigh")
EFFORT_RANK = {effort: rank for rank, effort in enumerate(EFFORTS)}
RISK_LEVELS = ("normal", "critical")
DIFFICULTIES = ("routine", "hard")
AVAILABILITY = ("available", "unavailable", "indeterminate")
SANDBOXES = ("read-only", "workspace-write", "danger-full-access")

CODEX_ROUTES = {
    "controller": ("gpt-6-astra", "high"),
    "planner": ("gpt-6-astra", "high"),
    "reviewer": ("gpt-6-astra", "high"),
    "skeptic": ("gpt-6-astra", "high"),
    "implementation": ("gpt-5.6-terra", "high"),
    "read_only": ("gpt-5.6-luna", "medium"),
    "mechanical": ("gpt-5.6-luna", "medium"),
    "think": ("gpt-6-astra", "high"),
}

CLAUDE_ROUTES = {
    "controller": ("opus", "medium"),
    "planner": ("fable", "high"),
    "reviewer": ("opus", "high"),
    "skeptic": ("opus", "high"),
    "implementation": ("sonnet", "high"),
    "read_only": ("haiku", "medium"),
    "mechanical": ("haiku", "medium"),
    "think": ("fable", "high"),
}

# Same-account fallbacks applied when a role's DEFAULT model -- the one in the
# route table above -- is unavailable and the caller supplied no fallbacks for
# that role. Fable is the top tier for both fable-rooted roles, so losing it
# drops a tier; xhigh on opus compensates rather than silently working at a
# lower standard. Two deliberate limits:
#   - A caller who overrides the route to a different model owns that choice, so
#     the default does not fire. An explicit cheaper pick is never silently
#     escalated back to opus/xhigh.
#   - A config "fallbacks" entry for a role replaces the default outright,
#     including an empty list to disable fallback for that role.
CLAUDE_FALLBACKS: dict[str, list[dict[str, str]]] = {
    "planner": [{"model": "opus", "effort": "xhigh"}],
    "think": [{"model": "opus", "effort": "xhigh"}],
}

CODEX_FALLBACKS: dict[str, list[dict[str, str]]] = {}

# A typo in a default key would degrade silently to "no fallback" with no signal,
# so pin the default keys to real roles at import.
_UNKNOWN_FALLBACK_ROLES = (set(CLAUDE_FALLBACKS) - set(CLAUDE_ROUTES)) | (
    set(CODEX_FALLBACKS) - set(CODEX_ROUTES)
)
if _UNKNOWN_FALLBACK_ROLES:
    raise RouteError(
        f"unknown fallback role in defaults: {min(_UNKNOWN_FALLBACK_ROLES)}"
    )

CRITICAL_ROLES = ("reviewer", "skeptic", "think")
# Difficulty escalates effort within the role's model. The gateway is excluded on
# purpose: it runs at medium so routing judgment stays cheap and the budget lands
# on specialists. The mechanical and read_only tiers are excluded because they are
# human-designated per task -- a task too hard for them should not have been
# designated mechanical or read_only.
DIFFICULTY_ROLES = ("planner", "implementation", "reviewer", "skeptic", "think")
CONFIG_KEYS = (
    "routes",
    "fallbacks",
    "mechanical",
    "difficulty",
    "parent_effort",
    "provisional",
)

# Pipeline step -> role binding. The single source of truth for which role a
# superpowers pipeline step dispatches under; role -> model/effort stays in
# CLAUDE_ROUTES / CODEX_ROUTES. Steps are runtime-independent; the runtime
# picks the model table.
PIPELINE_ROUTES: dict[str, str] = {
    "brainstorming": "planner",
    "spec": "planner",
    "plan": "planner",
    "spec-review": "reviewer",
    "plan-review": "reviewer",
    "implement": "implementation",
    "implementation-review": "reviewer",
    "co-review": "reviewer",
    "gateway": "controller",
    "read-only": "read_only",
    "mechanical": "mechanical",
}

# A step mapping to a role absent from either policy table would fail only at
# dispatch time, so pin the values to real roles at import.
_UNKNOWN_STEP_ROLES = {
    role
    for role in PIPELINE_ROUTES.values()
    if role not in CLAUDE_ROUTES or role not in CODEX_ROUTES
}
if _UNKNOWN_STEP_ROLES:
    raise RouteError(f"pipeline step maps to unknown role: {min(_UNKNOWN_STEP_ROLES)}")


def role_for_step(step: str) -> str:
    """Map a superpowers pipeline step to its policy role."""
    try:
        return PIPELINE_ROUTES[step]
    except (KeyError, TypeError):
        raise RouteError(f"unknown pipeline step: {step!r}")


def _workflow_context_module():
    path = (
        Path(__file__).resolve().parents[1] / "skills" / "lib" / "workflow_context.py"
    )
    spec = importlib.util.spec_from_file_location("dotfiles_workflow_context", path)
    if spec is None or spec.loader is None:
        raise RouteError(f"cannot load workflow context provider: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def execution_context(
    cwd: str | os.PathLike[str], runtime: str, personal: bool = False
) -> tuple[dict, dict]:
    try:
        provider = _workflow_context_module()
        repository = provider.repository_context(cwd)
        scope = provider.account_scope(cwd, runtime, personal=personal)
        return repository, scope
    except (OSError, subprocess.SubprocessError, ValueError) as exc:
        raise RouteError(f"cannot resolve workflow context: {exc}") from exc


def _apply_launch_environment(environment: dict[str, str], scope: dict) -> None:
    for key, value in scope["launch_env"].items():
        if value is None:
            environment.pop(key, None)
        else:
            environment[key] = value


def _runtime_policy(runtime: str) -> tuple[dict[str, tuple[str, str]], tuple[str, ...]]:
    if runtime == "codex":
        return CODEX_ROUTES, CODEX_MODELS
    if runtime == "claude":
        return CLAUDE_ROUTES, CLAUDE_MODELS
    raise RouteError(f"unsupported runtime: {runtime}")


def _validate_config(config: dict[str, Any] | None) -> dict[str, Any]:
    if config is None:
        return {}
    if not isinstance(config, dict):
        raise RouteError("config must be an object")
    unknown = sorted(set(config) - set(CONFIG_KEYS))
    if unknown:
        if any("account" in key or "config_dir" in key for key in unknown):
            raise RouteError("runtime routing cannot switch accounts")
        raise RouteError(f"unsupported config keys: {', '.join(unknown)}")
    if "parent_effort" in config and config["parent_effort"] not in EFFORTS:
        raise RouteError("parent_effort must be a supported explicit effort")
    if "provisional" in config and not isinstance(config["provisional"], bool):
        raise RouteError("provisional must be a boolean")
    return config


def _difficulty(
    role: str, config: dict[str, Any]
) -> tuple[str | None, str | None, bool | None]:
    if "difficulty" not in config:
        return None, None, None
    block = config["difficulty"]
    if not isinstance(block, dict):
        raise RouteError("difficulty must be an object")
    if set(block) != {"level", "proposed", "confirmed"}:
        raise RouteError("difficulty config requires level, proposed, and confirmed")
    level = block["level"]
    if level not in DIFFICULTIES:
        raise RouteError(f"unsupported difficulty level: {level}")
    proposed = block["proposed"]
    if proposed is not None and proposed not in DIFFICULTIES:
        raise RouteError(f"unsupported proposed difficulty: {proposed}")
    if role not in DIFFICULTY_ROLES:
        raise RouteError(f"difficulty is unsupported for role: {role}")
    if block["confirmed"] is not True:
        raise RouteError("difficulty requires explicit human confirmation")
    return level, proposed, True


def _bump_effort(effort: str) -> str:
    return EFFORTS[min(EFFORT_RANK[effort] + 1, len(EFFORTS) - 1)]


def _route_override(
    runtime: str,
    role: str,
    default_model: str,
    default_effort: str,
    config: dict[str, Any],
) -> tuple[str, str]:
    routes = config.get("routes", {})
    if not isinstance(routes, dict):
        raise RouteError("routes must be an object")
    unknown_roles = sorted(set(routes) - set(_runtime_policy(runtime)[0]))
    if unknown_roles:
        raise RouteError(f"unsupported route role: {unknown_roles[0]}")
    override = routes.get(role, {})
    if not isinstance(override, dict) or set(override) - {"model", "effort"}:
        raise RouteError("a route override may contain only model and effort")
    model = override.get("model", default_model)
    effort = override.get("effort", default_effort)
    known_models = _runtime_policy(runtime)[1]
    if model not in known_models:
        if runtime == "codex":
            raise RouteError(f"Codex routes require a supported full model ID: {model}")
        raise RouteError(f"unsupported Claude model: {model}")
    if effort not in EFFORTS:
        raise RouteError(f"unsupported effort: {effort}")
    if EFFORT_RANK[effort] < EFFORT_RANK[default_effort]:
        raise RouteError(
            f"configured effort {effort} is below the {default_effort} role floor"
        )
    return model, effort


def _capability(
    capabilities: dict[str, Any] | None, model: str, effort: str
) -> tuple[str, str]:
    if capabilities is None or not isinstance(capabilities, dict):
        return "indeterminate", "indeterminate"
    models = capabilities.get("models")
    if not isinstance(models, dict):
        return "indeterminate", "indeterminate"
    record = models.get(model)
    if not isinstance(record, dict):
        return "indeterminate", "indeterminate"
    availability = record.get("status", "indeterminate")
    if availability not in AVAILABILITY:
        raise RouteError(f"invalid capability status for {model}: {availability}")
    efforts = record.get("efforts")
    if efforts is None:
        return availability, "indeterminate"
    if (
        not isinstance(efforts, list)
        or not all(isinstance(item, str) for item in efforts)
        or any(item not in (*EFFORTS, "max", "ultra") for item in efforts)
    ):
        raise RouteError(f"invalid effort capabilities for {model}")
    return availability, "supported" if effort in efforts else "unsupported"


def discover_capabilities(
    runtime: str, environment: dict[str, str] | None = None
) -> dict[str, Any] | None:
    if runtime == "claude":
        return None
    if runtime != "codex":
        raise RouteError(f"unsupported runtime: {runtime}")
    selected_env = os.environ if environment is None else environment
    codex_home = Path(
        selected_env.get(
            "CODEX_HOME", str(Path(selected_env.get("HOME", "~")) / ".codex")
        )
    ).expanduser()
    catalog_path = codex_home / "models_cache.json"
    try:
        catalog = json.loads(catalog_path.read_text())
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        raise RouteError(f"local model catalog is unreadable: {exc}") from exc
    if not isinstance(catalog, dict) or not isinstance(catalog.get("models"), list):
        raise RouteError("local model catalog has an unsupported shape")
    models = {}
    for record in catalog["models"]:
        if not isinstance(record, dict) or record.get("slug") not in CODEX_MODELS:
            continue
        levels = record.get("supported_reasoning_levels")
        if not isinstance(levels, list):
            raise RouteError(f"model catalog lacks effort levels for {record['slug']}")
        efforts = []
        for level in levels:
            if not isinstance(level, dict) or not isinstance(level.get("effort"), str):
                raise RouteError(
                    f"model catalog has an invalid effort for {record['slug']}"
                )
            effort = level["effort"]
            if effort not in (*EFFORTS, "max", "ultra"):
                raise RouteError(
                    f"model catalog has an unknown effort for {record['slug']}"
                )
            if effort not in efforts:
                efforts.append(effort)
        models[record["slug"]] = {
            "status": "indeterminate",
            "efforts": efforts,
        }
    return {
        "models": models,
        "source": "local-model-catalog",
        "authenticated_availability": False,
    }


def _fallbacks(
    runtime: str, role: str, config: dict[str, Any], allow_defaults: bool = True
) -> list[tuple[str, str]]:
    block = config.get("fallbacks", {})
    if not isinstance(block, dict):
        raise RouteError("fallbacks must be an object")
    roles = _runtime_policy(runtime)[0]
    unknown_roles = sorted(set(block) - set(roles))
    if unknown_roles:
        raise RouteError(f"unsupported fallback role: {unknown_roles[0]}")
    if role in block:
        records = block[role]
    elif allow_defaults:
        defaults = CLAUDE_FALLBACKS if runtime == "claude" else CODEX_FALLBACKS
        records = defaults.get(role, [])
    else:
        records = []
    if not isinstance(records, list):
        raise RouteError("role fallbacks must be a list")
    known_models = _runtime_policy(runtime)[1]
    result = []
    for record in records:
        if not isinstance(record, dict) or set(record) != {"model", "effort"}:
            raise RouteError("each fallback requires exactly model and effort")
        model, effort = record["model"], record["effort"]
        if model not in known_models:
            if runtime == "codex":
                raise RouteError(
                    f"Codex routes require a supported full model ID: {model}"
                )
            raise RouteError(f"unsupported Claude model: {model}")
        if effort not in EFFORTS:
            raise RouteError(f"unsupported fallback effort: {effort}")
        result.append((model, effort))
    return result


def resolve_route(
    runtime: str,
    role: str,
    risk: str = "normal",
    config: dict[str, Any] | None = None,
    capabilities: dict[str, Any] | None = None,
) -> dict[str, Any]:
    policy, _ = _runtime_policy(runtime)
    if role not in policy:
        raise RouteError(f"unsupported role: {role}")
    if risk not in RISK_LEVELS:
        raise RouteError(
            "risk must be normal or explicitly critical; diff size is not criticality"
        )
    if risk == "critical" and role not in CRITICAL_ROLES:
        raise RouteError(f"critical risk is unsupported for role: {role}")
    selected_config = _validate_config(config)
    if role == "mechanical":
        mechanical = selected_config.get("mechanical")
        if not isinstance(mechanical, dict):
            raise RouteError("mechanical writing requires an explicit task designation")
        if set(mechanical) != {"designated", "review_gate"}:
            raise RouteError("mechanical config requires designation and review gate")
        if mechanical.get("designated") is not True:
            raise RouteError("mechanical writing requires an explicit task designation")
        if mechanical.get("review_gate") is not True:
            raise RouteError("mechanical writing requires an explicit review gate")

    default_model, default_effort = policy[role]
    difficulty, difficulty_proposed, difficulty_confirmed = _difficulty(
        role, selected_config
    )
    # Each axis was already checked for role eligibility -- risk above, difficulty
    # inside _difficulty -- so an unsupported designation has raised by now rather
    # than being absorbed into this maximum.
    targets = [EFFORT_RANK[default_effort]]
    if difficulty == "hard":
        targets.append(EFFORT_RANK[_bump_effort(default_effort)])
    if risk == "critical":
        targets.append(EFFORT_RANK["xhigh"])
    default_effort = EFFORTS[max(targets)]
    requested_model, requested_effort = _route_override(
        runtime,
        role,
        default_model,
        default_effort,
        selected_config,
    )
    quality_floor = default_effort
    availability, capability = _capability(
        capabilities, requested_model, requested_effort
    )
    selected_model, selected_effort = requested_model, requested_effort
    fallback = None
    blocked_reason = None

    candidates = _fallbacks(
        runtime, role, selected_config, requested_model == default_model
    )
    if availability == "unavailable":
        for candidate_model, candidate_effort in candidates:
            if EFFORT_RANK[candidate_effort] < EFFORT_RANK[quality_floor]:
                continue
            candidate_availability, candidate_capability = _capability(
                capabilities, candidate_model, candidate_effort
            )
            if (
                candidate_availability == "available"
                and candidate_capability == "supported"
            ):
                selected_model, selected_effort = candidate_model, candidate_effort
                availability, capability = candidate_availability, candidate_capability
                fallback = {
                    "from": requested_model,
                    "reason": "requested-model-unavailable",
                }
                break
        if fallback is None:
            blocked_reason = "no-fallback-meets-quality-floor"

    if blocked_reason is None:
        if availability == "unavailable":
            blocked_reason = "requested-model-unavailable"
        elif availability == "indeterminate":
            blocked_reason = "model-availability-indeterminate"
            if capability == "indeterminate":
                blocked_reason += "+effort-capability-indeterminate"
        elif capability == "indeterminate":
            blocked_reason = "effort-capability-indeterminate"
        elif capability == "unsupported":
            blocked_reason = "requested-effort-unsupported"

    ready = availability == "available" and capability == "supported"
    provisional_reason = None
    if (
        selected_config.get("provisional")
        and blocked_reason
        and all(part.endswith("indeterminate") for part in blocked_reason.split("+"))
    ):
        provisional_reason, blocked_reason, ready = blocked_reason, None, True
    return {
        "runtime": runtime,
        "role": role,
        "risk": risk,
        "difficulty": difficulty,
        "difficulty_proposed": difficulty_proposed,
        "difficulty_confirmed": difficulty_confirmed,
        "requested_model": requested_model,
        "requested_effort": requested_effort,
        "model": selected_model,
        "effort": selected_effort,
        "quality_floor": quality_floor,
        "availability": availability,
        "capability": capability,
        "ready": ready,
        "blocked_reason": blocked_reason,
        "provisional": provisional_reason is not None,
        "provisional_reason": provisional_reason,
        "fallback": fallback,
        "account_action": "preserve",
        "review_gate": role != "mechanical"
        or selected_config["mechanical"]["review_gate"],
    }


def _checked_cwd(cwd: str | os.PathLike[str]) -> str:
    path = os.fspath(cwd)
    if not path or "\x00" in path:
        raise RouteError("cwd must be a non-empty path")
    return path


def _codex_add_dirs(route: dict[str, Any], cwd: str) -> list[str]:
    values = route.get("add_dirs", [])
    if not isinstance(values, list) or len(values) > 2:
        raise RouteError("add_dirs must be a list of at most two narrow roots")
    cwd_path = Path(cwd).resolve()
    selected = []
    for value in values:
        if not isinstance(value, str) or not value or "\x00" in value:
            raise RouteError("add_dirs entries must be absolute paths")
        path = Path(value)
        if not path.is_absolute() or ".." in path.parts:
            raise RouteError(
                "add_dirs entries must be absolute paths without traversal"
            )
        resolved = path.resolve()
        if (
            resolved == Path(resolved.anchor)
            or cwd_path == resolved
            or resolved in cwd_path.parents
        ):
            raise RouteError(
                "add_dirs cannot grant a worktree parent or filesystem root"
            )
        normalized = str(resolved)
        if normalized in selected:
            raise RouteError("add_dirs entries must be unique")
        selected.append(normalized)
    return selected


def _personal_repository(scope: dict) -> bool:
    if not isinstance(scope, dict):
        raise RouteError("account scope must be an object")
    personal_repository = scope.get("personal_repository")
    if not isinstance(personal_repository, bool):
        raise RouteError("account scope lacks a boolean personal_repository")
    return personal_repository


def launch_argv(
    route: dict[str, Any],
    cwd: str | os.PathLike[str],
    sandbox: str,
    mode: str = "interactive",
    *,
    scope: dict,
) -> list[str]:
    if not isinstance(route, dict):
        raise RouteError("route must be an object")
    runtime = route.get("runtime")
    model = route.get("model")
    effort = route.get("effort")
    if runtime not in ("claude", "codex") or not isinstance(model, str):
        raise RouteError("route lacks a supported runtime and model")
    if model not in _runtime_policy(runtime)[1]:
        detail = "full model ID" if runtime == "codex" else "model"
        raise RouteError(f"route lacks a supported {detail}: {model}")
    if effort not in EFFORTS:
        raise RouteError("route lacks a supported explicit effort")
    if route.get("ready") is not True:
        raise RouteError(
            f"route is not ready: {route.get('blocked_reason') or 'unknown'}"
        )
    if sandbox not in SANDBOXES:
        raise RouteError(f"unsupported sandbox: {sandbox}")
    if mode not in ("interactive", "headless"):
        raise RouteError(f"unsupported launch mode: {mode}")
    selected_cwd = _checked_cwd(cwd)
    personal_repository = _personal_repository(scope)

    if runtime == "codex":
        add_dirs = _codex_add_dirs(route, selected_cwd)
        if add_dirs and sandbox == "read-only":
            raise RouteError("read-only Codex cannot make lifecycle roots writable")
        lifecycle_approval = route.get("lifecycle_approval")
        if lifecycle_approval not in (None, "auto-review"):
            raise RouteError("unsupported Codex lifecycle approval policy")
        if lifecycle_approval and sandbox != "read-only":
            raise RouteError("lifecycle auto-review is only for read-only Codex")
        argv = ["codex"]
        if mode == "headless":
            argv.append("exec")
        argv.extend(
            [
                "-m",
                model,
                "-c",
                f'model_reasoning_effort="{effort}"',
                *(
                    [
                        "-c",
                        'plugins."atlassian@claude-plugins-official".enabled=false',
                    ]
                    if personal_repository
                    else []
                ),
                "-C",
                selected_cwd,
                "--sandbox",
                sandbox,
            ]
        )
        for directory in add_dirs:
            argv.extend(["--add-dir", directory])
        if lifecycle_approval:
            argv.extend(["-c", 'approvals_reviewer="auto_review"', "-a", "on-request"])
        if mode == "headless":
            argv.extend(["--json", "-"])
        return argv

    if route.get("add_dirs"):
        raise RouteError("add_dirs are supported only for Codex routes")

    permission_modes = {"read-only": "plan", "workspace-write": "auto"}
    if sandbox not in permission_modes:
        raise RouteError(
            "Claude cannot enforce danger-full-access as a sandbox setting"
        )
    argv = [
        "claude",
        "--model",
        model,
        "--effort",
        effort,
        "--permission-mode",
        permission_modes[sandbox],
    ]
    if mode == "headless":
        argv.extend(["-p", "--output-format", "json"])
    return argv


def _json_objects(output: str) -> list[dict[str, Any]]:
    records = []
    for line in output.splitlines():
        try:
            value = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(value, dict):
            records.append(value)
    if not records:
        try:
            value = json.loads(output)
        except (json.JSONDecodeError, TypeError):
            value = None
        if isinstance(value, dict):
            records.append(value)
    return records


def _nonnegative_int(value: Any) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _nonnegative_number(value: Any) -> int | float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if value < 0 or not math.isfinite(value):
        return None
    return value


def _codex_error(record: dict[str, Any]) -> str:
    error = record.get("error")
    if isinstance(error, dict) and isinstance(error.get("message"), str):
        return error["message"]
    if isinstance(error, str):
        return error
    if isinstance(record.get("message"), str):
        return record["message"]
    return "runtime error"


def parse_runtime_result(runtime: str, output: str) -> dict[str, Any]:
    if runtime not in ("claude", "codex"):
        raise RouteError(f"unsupported runtime: {runtime}")
    if not isinstance(output, str):
        raise TypeError("output must be text")
    records = _json_objects(output)
    if not records:
        return {
            "runtime": runtime,
            "status": "unparseable",
            "result": None,
            "errors": ["no runtime JSON object"],
            "token_usage": None,
            "total_cost_usd": None,
            "num_turns": None,
            "session_id": None,
            "observed_model": None,
            "observed_effort": None,
            "observation": "missing-runtime-metadata",
        }

    if runtime == "claude":
        result_records = [
            record for record in records if record.get("type") == "result"
        ]
        if not result_records:
            return parse_runtime_result("claude", "")
        record = result_records[-1]
        errors = record.get("errors")
        if not isinstance(errors, list) or not all(
            isinstance(item, str) for item in errors
        ):
            errors = []
        is_error = record.get("is_error") is True or str(
            record.get("subtype", "")
        ).startswith("error")
        model_usage = record.get("modelUsage")
        observed_model = None
        if isinstance(model_usage, dict) and len(model_usage) == 1:
            observed_model = next(iter(model_usage))
        return {
            "runtime": "claude",
            "status": "error" if is_error else "success",
            "subtype": record.get("subtype"),
            "result": record.get("structured_output", record.get("result")),
            "errors": errors,
            "token_usage": record.get("usage")
            if isinstance(record.get("usage"), dict)
            else None,
            "total_cost_usd": _nonnegative_number(record.get("total_cost_usd")),
            "num_turns": _nonnegative_int(record.get("num_turns")),
            "session_id": record.get("session_id")
            if isinstance(record.get("session_id"), str)
            else None,
            "observed_model": observed_model,
            "observed_effort": None,
            "observation": "model-usage-only"
            if observed_model
            else "missing-runtime-metadata",
        }

    errors = [
        _codex_error(record)
        for record in records
        if record.get("type") in ("error", "turn.failed")
    ]
    messages = []
    for record in records:
        if record.get("type") != "item.completed":
            continue
        item = record.get("item")
        if isinstance(item, dict) and item.get("type") == "agent_message":
            text = item.get("text")
            if isinstance(text, str):
                messages.append(text)
    completed = [record for record in records if record.get("type") == "turn.completed"]
    usage = None
    if completed and isinstance(completed[-1].get("usage"), dict):
        native_usage = completed[-1]["usage"]
        input_tokens = _nonnegative_int(native_usage.get("input_tokens"))
        output_tokens = _nonnegative_int(native_usage.get("output_tokens"))
        cached_tokens = _nonnegative_int(native_usage.get("cached_input_tokens"))
        if input_tokens is not None and output_tokens is not None:
            usage = {
                "input_tokens": input_tokens,
                "cached_input_tokens": cached_tokens or 0,
                "output_tokens": output_tokens,
                "total_tokens": input_tokens + output_tokens,
            }
    status = "error" if errors else "success" if completed else "unparseable"
    if status == "unparseable" and not errors:
        errors = ["no completed Codex turn"]
    thread_ids = [
        record.get("thread_id")
        for record in records
        if record.get("type") == "thread.started"
        and isinstance(record.get("thread_id"), str)
    ]
    return {
        "runtime": "codex",
        "status": status,
        "result": "\n\n".join(messages) if messages else None,
        "errors": errors,
        "token_usage": usage,
        "total_cost_usd": None,
        "num_turns": None,
        "session_id": thread_ids[-1] if thread_ids else None,
        "observed_model": None,
        "observed_effort": None,
        "observation": "unavailable-from-codex-jsonl",
    }


def _timeout_result(runtime: str, stderr: str = "") -> dict[str, Any]:
    return {
        "runtime": runtime,
        "status": "timeout",
        "result": None,
        "errors": [stderr] if stderr else [],
        "token_usage": None,
        "total_cost_usd": None,
        "num_turns": None,
        "session_id": None,
        "observed_model": None,
        "observed_effort": None,
        "observation": "missing-runtime-metadata",
        "timed_out": True,
    }


def _kill_after_timeout(process: subprocess.Popen, drain_secs: float = 5.0) -> str:
    """Terminate a timed-out child and drain its output WITHOUT hanging.

    The child runs in its own session (start_new_session=True), so
    os.killpg(pid) reaches the child and every descendant still in its group.
    A descendant that called setsid() -- e.g. a runtime CLI that detaches its
    model worker -- escapes that group and keeps the stdout/stderr pipe open,
    which makes an UNBOUNDED communicate() block forever draining a pipe that
    never reaches EOF (the observed 34-minute "timeout that never returned").
    So the drain is bounded: after SIGKILL we read what is already buffered
    for a few seconds, then give up. Any escaped worker is left orphaned to
    the OS reaper rather than wedging the runner. Returns captured stderr
    (possibly empty)."""
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        pass
    try:
        process.kill()
    except (ProcessLookupError, OSError):
        pass
    try:
        _stdout, stderr = process.communicate(timeout=drain_secs)
        return stderr or ""
    except subprocess.TimeoutExpired:
        # A detached (setsid) descendant still holds the pipe; stop waiting.
        for stream in (process.stdout, process.stderr, process.stdin):
            try:
                if stream is not None:
                    stream.close()
            except OSError:
                pass
        return ""


def run_bounded(
    route: dict[str, Any],
    prompt: str,
    cwd: str | os.PathLike[str],
    sandbox: str,
    *,
    timeout_secs: float,
    max_turns: int | None = None,
    max_budget_usd: float | None = None,
    env: dict[str, str] | None = None,
    personal: bool = False,
) -> dict[str, Any]:
    runtime = route.get("runtime") if isinstance(route, dict) else None
    if runtime not in ("claude", "codex"):
        raise RouteError("route lacks a supported runtime")
    if isinstance(timeout_secs, bool) or not isinstance(timeout_secs, (int, float)):
        raise UnsupportedLimitError("timeout_secs must be a positive number")
    if not math.isfinite(timeout_secs) or timeout_secs <= 0:
        raise UnsupportedLimitError("timeout_secs must be a positive number")
    if runtime == "codex" and max_turns is not None:
        raise UnsupportedLimitError("Codex cannot enforce max_turns")
    if runtime == "codex" and max_budget_usd is not None:
        raise UnsupportedLimitError("Codex cannot enforce max_budget_usd")

    _repository, scope = execution_context(cwd, runtime, personal)
    argv = launch_argv(route, cwd, sandbox, mode="headless", scope=scope)
    if runtime == "claude":
        if max_turns is not None:
            if (
                isinstance(max_turns, bool)
                or not isinstance(max_turns, int)
                or max_turns <= 0
            ):
                raise UnsupportedLimitError("max_turns must be a positive integer")
            argv.extend(["--max-turns", str(max_turns)])
        if max_budget_usd is not None:
            if (
                isinstance(max_budget_usd, bool)
                or not isinstance(max_budget_usd, (int, float))
                or not math.isfinite(max_budget_usd)
                or max_budget_usd <= 0
            ):
                raise UnsupportedLimitError("max_budget_usd must be a positive number")
            argv.extend(["--max-budget-usd", str(max_budget_usd)])

    child_env = dict(os.environ if env is None else env)
    _apply_launch_environment(child_env, scope)
    process = subprocess.Popen(
        argv,
        cwd=_checked_cwd(cwd),
        env=child_env,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(prompt, timeout=timeout_secs)
    except subprocess.TimeoutExpired:
        stderr = _kill_after_timeout(process)
        result = _timeout_result(runtime, stderr.strip())
        result["account_kind"] = scope["kind"]
        result["account_id"] = scope["account_id"]
        result["scope_id"] = scope["scope_id"]
        return result

    result = parse_runtime_result(runtime, stdout)
    result["account_kind"] = scope["kind"]
    result["account_id"] = scope["account_id"]
    result["scope_id"] = scope["scope_id"]
    result["exit_code"] = process.returncode
    result["timed_out"] = False
    if process.returncode != 0 and result["status"] == "success":
        result["status"] = "error"
    if stderr.strip():
        result["errors"] = [*result["errors"], stderr.strip()]
    return result


def main(argv: list[str] | None = None) -> int:
    from herdr_dispatch_cli import runtime_main

    return runtime_main(argv)


if __name__ == "__main__":
    raise SystemExit(main())
