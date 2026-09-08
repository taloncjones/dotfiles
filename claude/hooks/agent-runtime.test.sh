#!/usr/bin/env bash
set -uo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONPATH="$ROOT/claude/hooks${PYTHONPATH:+:$PYTHONPATH}"
export UV_CACHE_DIR="${TMPDIR:-/tmp}/dotfiles-agent-runtime-uv-cache"
if command -v uv >/dev/null 2>&1; then
  PYTHON=(uv run --offline --no-project python)
else
  PYTHON=(python3)
fi

"${PYTHON[@]}" - <<'PY'
import json
import os
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import agent_runtime as runtime


PASS = 0
FAIL = 0


def check(name, test):
    global PASS, FAIL
    try:
        test()
    except Exception as exc:
        FAIL += 1
        print(f"FAIL  {name}: {exc}")
    else:
        PASS += 1
        print(f"PASS  {name}")


def raises(error, call, text=None):
    try:
        call()
    except error as exc:
        if text is not None:
            assert text in str(exc), (text, str(exc))
        return
    raise AssertionError(f"expected {error.__name__}")


def model(status="available", efforts=("low", "medium", "high", "xhigh")):
    return {"status": status, "efforts": list(efforts)}


def codex_capabilities():
    return {
        "models": {
            "gpt-6-astra": model(),
            "gpt-5.6-sol": model(),
            "gpt-5.6-terra": model(),
            "gpt-5.6-luna": model(efforts=("low", "medium", "high", "xhigh", "max")),
        }
    }


def test_model_catalog_discovers_effort_without_claiming_availability():
    with tempfile.TemporaryDirectory() as td:
        home = Path(td)
        (home / "models_cache.json").write_text(
            json.dumps(
                {
                    "models": [
                        {
                            "slug": "gpt-6-astra",
                            "supported_reasoning_levels": [
                                {"effort": "high"},
                                {"effort": "xhigh"},
                            ],
                        }
                    ]
                }
            )
        )
        caps = runtime.discover_capabilities("codex", {"CODEX_HOME": str(home)})
    assert caps == {
        "models": {
            "gpt-6-astra": {
                "status": "indeterminate",
                "efforts": ["high", "xhigh"],
            }
        },
        "source": "local-model-catalog",
        "authenticated_availability": False,
    }, caps
    route = runtime.resolve_route(
        "codex", "reviewer", risk="critical", capabilities=caps
    )
    assert route["capability"] == "supported", route
    assert route["availability"] == "indeterminate", route
    assert route["ready"] is False, route


def test_codex_role_table():
    caps = codex_capabilities()
    expected = {
        "controller": ("gpt-6-astra", "high"),
        "planner": ("gpt-6-astra", "high"),
        "reviewer": ("gpt-6-astra", "high"),
        "skeptic": ("gpt-6-astra", "high"),
        "implementation": ("gpt-5.6-terra", "high"),
        "read_only": ("gpt-5.6-luna", "medium"),
        "think": ("gpt-6-astra", "high"),
    }
    for role, wanted in expected.items():
        route = runtime.resolve_route("codex", role, capabilities=caps)
        assert (route["model"], route["effort"]) == wanted, (role, route)
        assert route["availability"] == "available", route
        assert route["account_action"] == "preserve", route
        assert "account" not in route and "config_dir" not in route, route


def test_critical_routes_are_explicit_xhigh():
    caps = codex_capabilities()
    for role in ("reviewer", "think"):
        route = runtime.resolve_route("codex", role, risk="critical", capabilities=caps)
        assert route["model"] == "gpt-6-astra", route
        assert route["effort"] == "xhigh", route
        assert route["quality_floor"] == "xhigh", route
        assert route["risk"] == "critical", route


def test_parent_xhigh_is_not_inherited():
    route = runtime.resolve_route(
        "codex",
        "reviewer",
        config={"parent_effort": "xhigh"},
        capabilities=codex_capabilities(),
    )
    assert route["effort"] == "high", route
    assert route["requested_effort"] == "high", route


def test_mechanical_writing_needs_designation_and_review_gate():
    caps = codex_capabilities()
    raises(
        runtime.RouteError,
        lambda: runtime.resolve_route("codex", "mechanical", capabilities=caps),
        "designation",
    )
    route = runtime.resolve_route(
        "codex",
        "mechanical",
        config={"mechanical": {"designated": True, "review_gate": True}},
        capabilities=caps,
    )
    assert (route["model"], route["effort"]) == ("gpt-5.6-luna", "medium"), route
    assert route["review_gate"] is True, route


def test_aliases_efforts_and_diff_size_risk_are_rejected():
    caps = codex_capabilities()
    raises(
        runtime.RouteError,
        lambda: runtime.resolve_route(
            "codex",
            "reviewer",
            config={"routes": {"reviewer": {"model": "astra"}}},
            capabilities=caps,
        ),
        "full model ID",
    )
    raises(
        runtime.RouteError,
        lambda: runtime.resolve_route(
            "codex",
            "reviewer",
            config={"routes": {"reviewer": {"effort": "ultra"}}},
            capabilities=caps,
        ),
        "effort",
    )
    raises(
        runtime.RouteError,
        lambda: runtime.resolve_route("codex", "reviewer", risk="large_diff", capabilities=caps),
        "risk",
    )
    raises(
        runtime.RouteError,
        lambda: runtime.resolve_route(
            "codex", "reviewer", config={"account": "work"}, capabilities=caps
        ),
        "switch accounts",
    )
    forged = runtime.resolve_route("codex", "reviewer", capabilities=caps)
    raises(
        runtime.RouteError,
        lambda: runtime.launch_argv({**forged, "model": "astra"}, "/tmp/repo", "read-only"),
        "full model ID",
    )


def test_unavailable_falls_back_but_indeterminate_does_not():
    caps = codex_capabilities()
    caps["models"]["gpt-6-astra"]["status"] = "unavailable"
    config = {"fallbacks": {"reviewer": [{"model": "gpt-5.6-sol", "effort": "high"}]}}
    route = runtime.resolve_route("codex", "reviewer", config=config, capabilities=caps)
    assert (route["model"], route["effort"]) == ("gpt-5.6-sol", "high"), route
    assert route["fallback"] == {
        "from": "gpt-6-astra",
        "reason": "requested-model-unavailable",
    }, route

    caps["models"]["gpt-6-astra"]["status"] = "indeterminate"
    route = runtime.resolve_route("codex", "reviewer", config=config, capabilities=caps)
    assert route["model"] == "gpt-6-astra", route
    assert route["availability"] == "indeterminate", route
    assert route["fallback"] is None, route


def test_fallback_never_lowers_critical_floor():
    caps = codex_capabilities()
    caps["models"]["gpt-6-astra"]["status"] = "unavailable"
    config = {"fallbacks": {"reviewer": [{"model": "gpt-5.6-sol", "effort": "high"}]}}
    route = runtime.resolve_route(
        "codex", "reviewer", risk="critical", config=config, capabilities=caps
    )
    assert route["model"] == "gpt-6-astra", route
    assert route["availability"] == "unavailable", route
    assert route["blocked_reason"] == "no-fallback-meets-quality-floor", route


def test_unknown_effort_capability_stays_explicit():
    caps = codex_capabilities()
    del caps["models"]["gpt-6-astra"]["efforts"]
    route = runtime.resolve_route(
        "codex", "reviewer", risk="critical", capabilities=caps
    )
    assert route["capability"] == "indeterminate", route
    assert route["ready"] is False, route
    assert route["blocked_reason"] == "effort-capability-indeterminate", route


def test_unsupported_effort_is_never_lowered():
    caps = codex_capabilities()
    caps["models"]["gpt-6-astra"]["efforts"] = ["low", "medium", "high"]
    route = runtime.resolve_route(
        "codex", "reviewer", risk="critical", capabilities=caps
    )
    assert route["effort"] == "xhigh", route
    assert route["capability"] == "unsupported", route
    assert route["ready"] is False, route
    assert route["blocked_reason"] == "requested-effort-unsupported", route


def test_explicit_provisional_launch_preserves_unknown_capability():
    caps = codex_capabilities()
    caps["models"]["gpt-6-astra"]["status"] = "indeterminate"
    route = runtime.resolve_route(
        "codex", "reviewer", config={"provisional": True}, capabilities=caps
    )
    assert route["ready"] is True, route
    assert route["availability"] == "indeterminate", route
    assert route["capability"] == "supported", route
    assert route["provisional"] is True, route
    assert route["provisional_reason"] == "model-availability-indeterminate", route
    claude = runtime.resolve_route(
        "claude", "reviewer", config={"provisional": True}, capabilities=None
    )
    assert claude["ready"] is True, claude
    assert claude["availability"] == "indeterminate", claude
    assert claude["capability"] == "indeterminate", claude
    assert claude["provisional_reason"] == (
        "model-availability-indeterminate+effort-capability-indeterminate"
    ), claude
    caps["models"]["gpt-6-astra"]["status"] = "unavailable"
    route = runtime.resolve_route(
        "codex", "reviewer", config={"provisional": True}, capabilities=caps
    )
    assert route["ready"] is False and route["provisional"] is False, route
    raises(
        runtime.RouteError,
        lambda: runtime.resolve_route(
            "codex", "reviewer", config={"provisional": "yes"}, capabilities=caps
        ),
        "provisional",
    )


def test_native_argv_mappings_are_exact():
    caps = codex_capabilities()
    codex_route = runtime.resolve_route("codex", "implementation", capabilities=caps)
    assert runtime.launch_argv(
        codex_route, "/tmp/work tree", "workspace-write", mode="interactive"
    ) == [
        "codex",
        "-m",
        "gpt-5.6-terra",
        "-c",
        'model_reasoning_effort="high"',
        "-C",
        "/tmp/work tree",
        "--sandbox",
        "workspace-write",
    ]
    assert runtime.launch_argv(
        codex_route, "/tmp/work tree", "read-only", mode="headless"
    ) == [
        "codex",
        "exec",
        "-m",
        "gpt-5.6-terra",
        "-c",
        'model_reasoning_effort="high"',
        "-C",
        "/tmp/work tree",
        "--sandbox",
        "read-only",
        "--json",
        "-",
    ]

    claude_caps = {"models": {"fable": model()}}
    claude_route = runtime.resolve_route("claude", "planner", capabilities=claude_caps)
    assert runtime.launch_argv(
        claude_route, "/tmp/work tree", "workspace-write", mode="headless"
    ) == [
        "claude",
        "--model",
        "fable",
        "--effort",
        "high",
        "--permission-mode",
        "auto",
        "-p",
        "--output-format",
        "json",
    ]


def test_codex_lifecycle_roots_require_workspace_write():
    base_route = runtime.resolve_route(
        "codex", "reviewer", capabilities=codex_capabilities()
    )
    route = {
        **base_route,
        "add_dirs": ["/tmp/task-payload", "/tmp/coordination"],
    }
    raises(
        runtime.RouteError,
        lambda: runtime.launch_argv(route, "/tmp/worktree", "read-only"),
        "cannot make lifecycle roots writable",
    )
    argv = runtime.launch_argv(route, "/tmp/worktree", "workspace-write")
    assert argv[-4:] == [
        "--add-dir",
        str(Path("/tmp/task-payload").resolve()),
        "--add-dir",
        str(Path("/tmp/coordination").resolve()),
    ], argv
    approval_route = {**base_route, "lifecycle_approval": "auto-review"}
    approval_argv = runtime.launch_argv(
        approval_route, "/tmp/worktree", "read-only"
    )
    assert approval_argv[-4:] == [
        "-c",
        'approvals_reviewer="auto_review"',
        "-a",
        "on-request",
    ], approval_argv
    raises(
        runtime.RouteError,
        lambda: runtime.launch_argv(
            approval_route, "/tmp/worktree", "workspace-write"
        ),
        "read-only Codex",
    )
    for unsafe in (["/"], ["relative"], ["/tmp", "/tmp/other", "/tmp/third"]):
        candidate = {**route, "add_dirs": unsafe}
        raises(
            runtime.RouteError,
            lambda candidate=candidate: runtime.launch_argv(
                candidate, "/tmp/worktree", "workspace-write"
            ),
            "add_dirs",
        )
def test_codex_result_reports_tokens_and_unknown_observations():
    output = "\n".join(
        [
            json.dumps({"type": "thread.started", "thread_id": "thread-1"}),
            json.dumps(
                {
                    "type": "item.completed",
                    "item": {"type": "agent_message", "text": "answer"},
                }
            ),
            json.dumps(
                {
                    "type": "turn.completed",
                    "usage": {
                        "input_tokens": 12,
                        "cached_input_tokens": 3,
                        "output_tokens": 7,
                    },
                }
            ),
        ]
    )
    result = runtime.parse_runtime_result("codex", output)
    assert result["status"] == "success", result
    assert result["result"] == "answer", result
    assert result["token_usage"] == {
        "input_tokens": 12,
        "cached_input_tokens": 3,
        "output_tokens": 7,
        "total_tokens": 19,
    }, result
    assert result["total_cost_usd"] is None, result
    assert result["num_turns"] is None, result
    assert result["observed_model"] is None, result
    assert result["observed_effort"] is None, result
    assert result["observation"] == "unavailable-from-codex-jsonl", result


def test_result_errors_and_malformed_output_fail_closed():
    malformed = runtime.parse_runtime_result("codex", "not json\n[]")
    assert malformed["status"] == "unparseable", malformed
    failed = runtime.parse_runtime_result(
        "codex", json.dumps({"type": "turn.failed", "error": {"message": "boom"}})
    )
    assert failed["status"] == "error" and failed["errors"] == ["boom"], failed
    claude = runtime.parse_runtime_result(
        "claude",
        json.dumps(
            {
                "type": "result",
                "subtype": "success",
                "is_error": False,
                "result": "ok",
                "num_turns": 2,
                "total_cost_usd": 0.25,
                "modelUsage": {"claude-fable-5": {}},
            }
        ),
    )
    assert claude["status"] == "success", claude
    assert claude["observed_model"] == "claude-fable-5", claude
    assert claude["observed_effort"] is None, claude


def executable(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def init_repo(path):
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(
        ["git", "-C", str(path), "commit", "--allow-empty", "-qm", "test: init"],
        check=True,
        env={
            **os.environ,
            "GIT_AUTHOR_NAME": "Test",
            "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test",
            "GIT_COMMITTER_EMAIL": "test@example.invalid",
        },
    )


def test_run_uses_argv_and_unsets_default_claude_config():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bindir = root / "bin"
        bindir.mkdir()
        repo = root / "repo"
        init_repo(repo)
        log = root / "log.json"
        executable(
            bindir / "claude",
            "python3 - \"$@\" <<'STUB'\n"
            "import json,os,sys\n"
            "json.dump({'argv':sys.argv[1:],'cwd':os.getcwd(),"
            "'config':os.environ.get('CLAUDE_CONFIG_DIR','UNSET')},open(os.environ['RUN_LOG'],'w'))\n"
            "print(json.dumps({'type':'result','subtype':'success','is_error':False,'result':'ok',"
            "'num_turns':1,'total_cost_usd':0.1,'modelUsage':{'claude-fable-5':{}}}))\n"
            "STUB\n",
        )
        env = dict(os.environ)
        env.update(
            {
                "PATH": f"{bindir}:{env['PATH']}",
                "RUN_LOG": str(log),
                "CLAUDE_CONFIG_DIR": str(root / "wrong-account"),
            }
        )
        route = runtime.resolve_route(
            "claude", "planner", capabilities={"models": {"fable": model()}}
        )
        result = runtime.run_bounded(
            route,
            "prompt with $HOME and `literal`",
            repo,
            "workspace-write",
            timeout_secs=5,
            env=env,
        )
        call = json.loads(log.read_text())
        assert call["config"] == "UNSET", call
        assert os.path.samefile(call["cwd"], repo), call
        assert call["argv"] == runtime.launch_argv(
            route, repo, "workspace-write", mode="headless"
        )[1:], call
        assert result["status"] == "success", result


def test_run_consumes_shared_work_account_scope():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        repo = root / "Git" / "work" / "project"
        init_repo(repo)
        bindir = root / "bin"
        bindir.mkdir()
        log = root / "config"
        executable(
            bindir / "claude",
            "printf '%s' \"${CLAUDE_CONFIG_DIR-UNSET}\" > \"$RUN_LOG\"\n"
            "printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\","
            "\"is_error\":false,\"result\":\"ok\",\"num_turns\":1,"
            "\"total_cost_usd\":0.1}'\n",
        )
        old = dict(os.environ)
        try:
            os.environ.update(
                {
                    "HOME": str(root),
                    "CLAUDE_WORK_TREE": str(root / "Git" / "work"),
                    "CLAUDE_WORK_CONFIG_DIR": str(root / ".claude-work"),
                }
            )
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
            env = dict(os.environ)
            env.update({"PATH": f"{bindir}:{env['PATH']}", "RUN_LOG": str(log)})
            route = runtime.resolve_route(
                "claude", "planner", capabilities={"models": {"fable": model()}}
            )
            result = runtime.run_bounded(
                route,
                "prompt",
                repo,
                "workspace-write",
                timeout_secs=5,
                env=env,
            )
        finally:
            os.environ.clear()
            os.environ.update(old)
        assert Path(log.read_text()).resolve() == (root / ".claude-work").resolve(), log.read_text()
        assert result["account_kind"] == "work", result


def test_codex_caps_reject_before_invocation():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bindir = root / "bin"
        bindir.mkdir()
        repo = root / "repo"
        init_repo(repo)
        marker = root / "invoked"
        executable(bindir / "codex", f"touch '{marker}'\n")
        env = dict(os.environ)
        env["PATH"] = f"{bindir}:{env['PATH']}"
        route = runtime.resolve_route(
            "codex", "implementation", capabilities=codex_capabilities()
        )
        raises(
            runtime.UnsupportedLimitError,
            lambda: runtime.run_bounded(
                route,
                "prompt",
                repo,
                "workspace-write",
                timeout_secs=5,
                max_turns=3,
                env=env,
            ),
            "max_turns",
        )
        assert not marker.exists(), marker


def test_timeout_kills_the_process_group():
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        bindir = root / "bin"
        bindir.mkdir()
        repo = root / "repo"
        init_repo(repo)
        executable(bindir / "codex", "sleep 30\n")
        env = dict(os.environ)
        env["PATH"] = f"{bindir}:{env['PATH']}"
        route = runtime.resolve_route(
            "codex", "implementation", capabilities=codex_capabilities()
        )
        started = time.monotonic()
        result = runtime.run_bounded(
            route,
            "prompt",
            repo,
            "workspace-write",
            timeout_secs=0.2,
            env=env,
        )
        elapsed = time.monotonic() - started
        assert elapsed < 3, elapsed
        assert result["status"] == "timeout", result
        assert result["timed_out"] is True, result
        assert result["total_cost_usd"] is None, result


def test_route_and_launch_plan_cli_emit_json_contracts():
    caps = json.dumps(codex_capabilities())
    route_process = subprocess.run(
        [
            sys.executable,
            runtime.__file__,
            "route",
            "--runtime",
            "codex",
            "--role",
            "implementation",
            "--capabilities-json",
            caps,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    route = json.loads(route_process.stdout)
    assert route["model"] == "gpt-5.6-terra" and route["ready"] is True, route
    provisional_caps = json.dumps(
        {"models": {"gpt-5.6-terra": {"status": "indeterminate", "efforts": ["high"]}}}
    )
    provisional_process = subprocess.run(
        [
            sys.executable, runtime.__file__, "route", "--runtime", "codex",
            "--role", "implementation", "--capabilities-json", provisional_caps,
            "--provisional",
        ],
        check=True, capture_output=True, text=True,
    )
    provisional = json.loads(provisional_process.stdout)
    assert provisional["ready"] is True and provisional["provisional"] is True, provisional
    with tempfile.TemporaryDirectory() as td:
        repo = Path(td) / "repo"
        init_repo(repo)
        plan_process = subprocess.run(
            [
                sys.executable,
                runtime.__file__,
                "launch-plan",
                "--runtime",
                "codex",
                "--role",
                "implementation",
                "--capabilities-json",
                caps,
                "--cwd",
                str(repo),
                "--sandbox",
                "workspace-write",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    plan = json.loads(plan_process.stdout)
    assert plan["argv"][0:4] == ["codex", "-m", "gpt-5.6-terra", "-c"], plan
    assert plan["limits"] == {
        "max_budget_usd": None,
        "max_turns": None,
        "timeout_secs": None,
    }, plan


for name, test in (
    ("model catalog separates effort support from availability", test_model_catalog_discovers_effort_without_claiming_availability),
    ("Codex role table uses Astra, Terra and Luna", test_codex_role_table),
    ("critical review and think explicitly use xhigh", test_critical_routes_are_explicit_xhigh),
    ("parent xhigh is not inherited", test_parent_xhigh_is_not_inherited),
    ("mechanical writing requires designation and review", test_mechanical_writing_needs_designation_and_review_gate),
    ("aliases, unsupported effort and diff-size risk reject", test_aliases_efforts_and_diff_size_risk_are_rejected),
    ("confirmed unavailable falls back; indeterminate does not", test_unavailable_falls_back_but_indeterminate_does_not),
    ("fallback cannot lower the critical quality floor", test_fallback_never_lowers_critical_floor),
    ("unknown effort capability remains explicit", test_unknown_effort_capability_stays_explicit),
    ("unsupported effort is never silently lowered", test_unsupported_effort_is_never_lowered),
    ("explicit provisional launch preserves unknown capability", test_explicit_provisional_launch_preserves_unknown_capability),
    ("native Claude and Codex argv are exact", test_native_argv_mappings_are_exact),
    ("Codex lifecycle roots require workspace-write", test_codex_lifecycle_roots_require_workspace_write),
    ("Codex JSONL reports tokens and unknown observations", test_codex_result_reports_tokens_and_unknown_observations),
    ("error and malformed runtime output fail closed", test_result_errors_and_malformed_output_fail_closed),
    ("bounded run uses argv and native personal Claude env", test_run_uses_argv_and_unsets_default_claude_config),
    ("bounded run consumes the shared work account scope", test_run_consumes_shared_work_account_scope),
    ("Codex rejects unsupported caps before invocation", test_codex_caps_reject_before_invocation),
    ("bounded run kills the process group on timeout", test_timeout_kills_the_process_group),
    ("route and launch-plan CLI emit JSON contracts", test_route_and_launch_plan_cli_emit_json_contracts),
):
    check(name, test)

print(f"\n{PASS} passed, {FAIL} failed")
raise SystemExit(FAIL != 0)
PY
