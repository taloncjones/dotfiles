#!/usr/bin/env bash
set -uo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
export PYTHONPATH="$ROOT/claude/hooks${PYTHONPATH:+:$PYTHONPATH}"
export UV_CACHE_DIR="${TMPDIR:-/tmp}/dotfiles-herdr-dispatch-uv-cache"
if command -v uv >/dev/null 2>&1; then
  PYTHON=(uv run --offline --no-project python)
else
  PYTHON=(python3)
fi

"${PYTHON[@]}" - <<'PY'
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import agent_runtime
import herdr_dispatch
import herdr_orch_core as core


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


def init_repo(path):
    path.mkdir(parents=True)
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


def codex_route():
    return agent_runtime.resolve_route(
        "codex",
        "implementation",
        capabilities={
            "models": {
                "gpt-5.6-terra": {
                    "status": "available",
                    "efforts": ["low", "medium", "high", "xhigh"],
                }
            }
        },
    )


def claude_route():
    return agent_runtime.resolve_route(
        "claude",
        "implementation",
        capabilities={
            "models": {
                "sonnet": {
                    "status": "available",
                    "efforts": ["medium", "high"],
                }
            }
        },
    )


def fake_herdr(path):
    body = r'''#!/usr/bin/env python3
import json
import os
import re
import shlex
import sys
from pathlib import Path

args = sys.argv[1:]
log = Path(os.environ["FAKE_HERDR_LOG"])
with log.open("a") as stream:
    stream.write(json.dumps(args) + "\n")
mode = os.environ.get("FAKE_HERDR_MODE", "ok")
pane = os.environ["FAKE_PANE"]
workspace = os.environ["FAKE_WORKSPACE"]
cwd = os.environ["FAKE_CWD"]
if args[:2] == ["pane", "get"]:
    if mode == "malformed-pane":
        print("not json")
        raise SystemExit(0)
    if mode == "wrong-pane":
        cwd = os.environ["FAKE_WRONG_CWD"]
    print(json.dumps({"id": "fake", "result": {"type": "pane_info", "pane": {
        "pane_id": pane, "workspace_id": workspace, "cwd": cwd,
        "terminal_id": "t1", "tab_id": "tab1", "focused": False,
        "agent_status": "idle", "revision": 1}}}))
elif args[:2] == ["pane", "process-info"]:
    print(json.dumps({"id": "fake", "result": {
        "type": "pane_process_info", "process_info": {
        "pane_id": pane, "shell_pid": 101,
        "foreground_processes": [{"pid": 101, "name": "zsh", "cwd": cwd}]}}}))
elif args[:2] == ["pane", "read"]:
    count = Path(os.environ["FAKE_READ_COUNT"])
    current = int(count.read_text()) if count.exists() else 0
    count.write_text(str(current + 1))
    initial_review = (
        "Hooks need review\n"
        "1 hook is new or changed.\n"
        "Hooks can run outside the sandbox after you trust\n"
        "1. Review hooks\n"
        "2. Trust all and continue\n"
        "3. Continue without trusting (hooks won't run)\n"
        "Press enter to confirm or esc to go back"
    )
    if mode == "hook-review-required":
        print("shell prompt" if current == 0 else initial_review)
    elif mode == "stale-hook-review":
        print(initial_review if current == 0 else f"{initial_review}\nCodex ready")
    else:
        print("shell prompt" if current == 0 else "shell prompt\nCodex ready")
elif args[:2] == ["pane", "run"]:
    command = args[3]
    Path(os.environ["FAKE_COMMAND_ECHO"]).write_text(command + "\n")
    values = {}
    lines = []
    for part in command.split("; "):
        words = shlex.split(part)
        if words[0] == "unset":
            if words[1] != "-f":
                values[words[1]] = "__UNSET__"
        elif words[0] == "export":
            key, value = words[1].split("=", 1)
            values[key] = value
        elif words[0] == "printf":
            if words[1] == "%s%s\\n":
                lines.append(words[2] + words[3])
                continue
            match = re.fullmatch(r"(HERDR_ACCOUNT_[0-9a-f]+):([A-Z_]+)=%s\\n", words[1])
            if match is None:
                raise SystemExit("invalid account probe")
            key = match.group(2)
            if key == "RUNTIME_BINARY":
                value = str(Path(os.environ["FAKE_RUNTIME_DIR"]).resolve() / os.environ.get("FAKE_RUNTIME", "codex"))
                if mode == "wrong-runtime-binary":
                    value = "/wrong/codex"
            else:
                value = "wrong" if mode == "wrong-shell-env" else values[key]
            lines.append(f"{match.group(1)}:{key}={value}")
    Path(os.environ["FAKE_ENV_OUTPUT"]).write_text("\n".join(lines) + "\n")
    # Native protocol 20 pane run acknowledges success with empty stdout.
elif args[:2] == ["pane", "wait-output"]:
    text = Path(os.environ["FAKE_ENV_OUTPUT"]).read_text()
    match_text = args[args.index("--match") + 1]
    if mode == "shell-echo-before-output":
        command_echo = Path(os.environ["FAKE_COMMAND_ECHO"]).read_text()
        if match_text in command_echo:
            text = command_echo
    matched_line = next(
        (line for line in text.splitlines() if match_text in line), ""
    )
    print(json.dumps({"id": "fake", "result": {"type": "output_matched",
        "pane_id": pane, "revision": 2, "matched_line": matched_line,
        "read": {"pane_id": pane, "workspace_id": workspace, "tab_id": "tab1",
        "source": "recent_unwrapped", "format": "plain", "text": text,
        "revision": 2, "truncated": False}}}))
elif args[:2] == ["agent", "start"]:
    task = json.loads(Path(os.environ["FAKE_TASK_FILE"]).read_text())
    latest = task["workers"][-1]
    Path(os.environ["FAKE_ATTEMPT_SEEN"]).write_text(
        "yes" if latest["status"] == "starting" else "no"
    )
    if mode == "start-fail":
        print(json.dumps({"error": "agent_not_ready"}), file=sys.stderr)
        raise SystemExit(1)
    runtime = args[args.index("--kind") + 1]
    native = [runtime, *args[args.index("--") + 1:]]
    print(json.dumps({"id": "fake", "result": {"type": "agent_started", "argv": native, "agent": {
        "name": os.environ["FAKE_AGENT"], "pane_id": pane, "agent": runtime,
        "agent_status": "idle", "interactive_ready": True, "launch_pending": False,
        "terminal_id": "t1", "workspace_id": workspace, "tab_id": "tab1",
        "focused": False, "revision": 2}}}))
elif args[:2] == ["agent", "get"]:
    observed_pane = "w9:p9" if mode == "stale-agent" else pane
    busy = mode == "agent-busy"
    print(json.dumps({"id": "fake", "result": {"type": "agent_info", "agent": {
        "name": os.environ["FAKE_AGENT"], "pane_id": observed_pane,
        "agent": os.environ.get("FAKE_RUNTIME", "codex"),
        "agent_status": "working" if busy else "idle",
        "interactive_ready": not busy, "launch_pending": busy,
        "terminal_id": "t1", "workspace_id": workspace, "tab_id": "tab1",
        "focused": False, "revision": 2}}}))
elif args[:2] == ["agent", "prompt"]:
    if mode == "prompt-reject":
        print(json.dumps({"error": "not_idle"}), file=sys.stderr)
        raise SystemExit(1)
    if mode == "prompt-nonprompted":
        print(json.dumps({"id": "fake", "result": {"type": "agent_info"}}))
        raise SystemExit(0)
    print(json.dumps({"id": "fake", "result": {"type": "agent_prompted", "agent": {
        "name": os.environ["FAKE_AGENT"], "pane_id": pane,
        "agent": os.environ.get("FAKE_RUNTIME", "codex"),
        "agent_status": "done", "interactive_ready": True, "launch_pending": False,
        "terminal_id": "t1", "workspace_id": workspace, "tab_id": "tab1",
        "focused": False, "revision": 3}}}))
elif args[:2] == ["pane", "report-metadata"]:
    if mode == "metadata-fail":
        print(json.dumps({"error": "presentation_unsupported"}), file=sys.stderr)
        raise SystemExit(1)
    # Mutation success is established by the exit status; no result body is required.
else:
    print(json.dumps({"error": "unexpected", "args": args}), file=sys.stderr)
    raise SystemExit(2)
'''
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class Fixture:
    def __init__(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.old_env = dict(os.environ)
        self.home = self.root / "home"
        self.repo = self.home / "Git" / "personal" / "project"
        init_repo(self.repo)
        os.environ.update(
            {
                "HOME": str(self.home),
                "HERDR_ENV": "1",
                "HERDR_COORDINATION_ROOT": str(self.root / "coordination"),
            }
        )
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        context = core.repository_context(self.repo)
        self.slug = core.repo_slug("", context["common_dir"])
        self.rd = self.home / ".claude" / "herdr-orch" / self.slug
        (self.rd / "tasks").mkdir(parents=True)
        self.task_file = self.rd / "tasks" / "td-a.json"
        self.task_file.write_text(
            json.dumps(
                {
                    "v": 1,
                    "task_id": "td-a",
                    "repo_slug": self.slug,
                    "branch": context["branch"],
                    "worktree": str(self.repo.resolve()),
                    "base_sha": context["head"],
                    "status": "in-progress",
                    "workers": [],
                }
            )
        )
        fence = core.claim_owner(
            self.rd,
            "S",
            "host",
            1,
            context=context,
            expected_slug=self.slug,
        )
        assert fence == 1, fence
        self.bin = self.root / "herdr"
        fake_herdr(self.bin)
        self.runtime_dir = self.root / "runtime bin"
        self.runtime_dir.mkdir()
        for runtime in ("claude", "codex"):
            executable = self.runtime_dir / runtime
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o700)
        self.log = self.root / "calls.jsonl"
        self.env = {
            **os.environ,
            "PATH": str(self.runtime_dir) + os.pathsep + os.environ.get("PATH", os.defpath),
            "FAKE_RUNTIME_DIR": str(self.runtime_dir),
            "FAKE_HERDR_LOG": str(self.log),
            "FAKE_HERDR_MODE": "ok",
            "FAKE_PANE": "w1:p1",
            "FAKE_WORKSPACE": "w1",
            "FAKE_CWD": str(self.repo.resolve()),
            "FAKE_WRONG_CWD": str(self.root / "other"),
            "FAKE_READ_COUNT": str(self.root / "read-count"),
            "FAKE_ATTEMPT_SEEN": str(self.root / "attempt-seen"),
            "FAKE_TASK_FILE": str(self.task_file),
            "FAKE_AGENT": "impl-td-a",
            "FAKE_ENV_OUTPUT": str(self.root / "env-output"),
            "FAKE_COMMAND_ECHO": str(self.root / "command-echo"),
        }

    def close(self):
        os.environ.clear()
        os.environ.update(self.old_env)
        self.temp.cleanup()

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def launch(self, sandbox="workspace-write", route=None, **kwargs):
        return herdr_dispatch.launch(
            repo_slug=self.slug,
            task_id="td-a",
            session="S",
            fence=1,
            workspace_id="w1",
            pane_id="w1:p1",
            phase="implement",
            agent="impl-td-a",
            route=route or codex_route(),
            cwd=self.repo,
            sandbox=sandbox,
            prompt="brief $HOME; `literal`",
            herdr_cli=str(self.bin),
            env=self.env,
            start_timeout_ms=4000,
            prompt_timeout_ms=1000,
            **kwargs,
        )

    def reprompt(self, launch_id, prompt="incorporate the review findings",
                 fence=1, prompt_timeout_ms=1000, **kwargs):
        return herdr_dispatch.reprompt(
            repo_slug=self.slug,
            task_id="td-a",
            session="S",
            fence=fence,
            workspace_id="w1",
            launch_id=launch_id,
            phase="implement",
            cwd=self.repo,
            prompt=prompt,
            runtime="codex",
            herdr_cli=str(self.bin),
            env=self.env,
            prompt_timeout_ms=prompt_timeout_ms,
            **kwargs,
        )

    def worker_records(self):
        return json.loads(self.task_file.read_text())["workers"]

    def prompt_calls(self):
        return [c for c in self.calls() if c[:2] == ["agent", "prompt"]]


def test_launch_records_attempt_before_native_start():
    fixture = Fixture()
    try:
        result = fixture.launch()
        calls = fixture.calls()
        start = next(call for call in calls if call[:2] == ["agent", "start"])
        assert start == [
            "agent",
            "start",
            "impl-td-a",
            "--kind",
            "codex",
            "--pane",
            "w1:p1",
            "--timeout",
            "4000",
            "--",
            "-m",
            "gpt-5.6-terra",
            "-c",
            'model_reasoning_effort="high"',
            "-c",
            'plugins."atlassian@claude-plugins-official".enabled=false',
            "-C",
            str(fixture.repo),
            "--sandbox",
            "workspace-write",
            "--add-dir",
            str(fixture.rd.resolve()),
            "--add-dir",
            str((fixture.root / "coordination").resolve()),
        ], start
        assert (fixture.root / "attempt-seen").read_text() == "yes"
        task = json.loads(fixture.task_file.read_text())
        attempt = task["workers"][-1]
        assert attempt["status"] == "launched", attempt
        for key in (
            "launch_id",
            "phase",
            "runtime",
            "workspace_id",
            "pane_id",
            "source_head_sha",
        ):
            assert attempt.get(key), (key, attempt)
        assert result["launch_id"] == attempt["launch_id"], result
        assert result["completion_authoritative"] is False, result
        assert result["strict_ready"] is False, result
        assert result["observed_model"] is None, result
        assert result["observed_effort"] is None, result
    finally:
        fixture.close()


def test_runtime_binding_precedes_start_and_records_selected_entry():
    fixture = Fixture()
    try:
        result = fixture.launch()
        expected = str(fixture.runtime_dir.resolve() / "codex")
        task = json.loads(fixture.task_file.read_text())
        assert task["workers"][-1]["runtime_binary"] == expected, task
        commands = [call[3] for call in fixture.calls() if call[:2] == ["pane", "run"]]
        assert any("command -v" in command and str(fixture.runtime_dir) in command for command in commands)
    finally:
        fixture.close()


def test_missing_or_mismatched_binary_refuses_before_attempt_and_start():
    for mode in ("missing", "wrong-runtime-binary"):
        fixture = Fixture()
        try:
            if mode == "missing":
                fixture.env["PATH"] = str(fixture.root / "missing")
            else:
                fixture.env["FAKE_HERDR_MODE"] = mode
            try:
                fixture.launch()
            except herdr_dispatch.DispatchError as exc:
                assert "runtime" in str(exc), exc
            else:
                raise AssertionError("unverified executable accepted")
            assert json.loads(fixture.task_file.read_text())["workers"] == []
            assert not any(call[:2] == ["agent", "start"] for call in fixture.calls())
        finally:
            fixture.close()


def test_runtime_resolution_preserves_filesystem_parent_semantics():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "actual/nested").mkdir(parents=True)
        (root / "actual/bin").mkdir()
        (root / "bin").mkdir()
        (root / "link").symlink_to(root / "actual/nested", target_is_directory=True)
        versioned = root / "actual/bin/versioned executable"
        versioned.write_text("#!/bin/sh\nprintf 'EXPECTED\\n'\n")
        versioned.chmod(0o700)
        for runtime in ("claude", "codex"):
            (root / "actual/bin" / runtime).symlink_to(versioned)
            wrong = root / "bin" / runtime
            wrong.write_text("#!/bin/sh\nprintf 'WRONG\\n'\n")
            wrong.chmod(0o700)
            original_cwd = Path.cwd()
            try:
                os.chdir(root)
                for search in (str(root / "link/../bin"), "link/../bin"):
                    selected = herdr_dispatch._runtime_binary(runtime, {"PATH": search})
                    assert selected == str((root / "actual/bin").resolve() / runtime), selected
                    assert subprocess.check_output([selected], text=True).strip() == "EXPECTED"
            finally:
                os.chdir(original_cwd)


def test_runtime_binding_bypasses_aliases_functions_and_stale_hashes():
    for shell in ("bash", "zsh"):
        shell_binary = shutil.which(shell)
        if shell_binary is None:
            print(f"SKIP  {shell} runtime binding probe: shell unavailable")
            continue
        for runtime in ("claude", "codex"):
            fixture = Fixture()
            original_run = herdr_dispatch._run_herdr
            original_validate = herdr_dispatch._validate_pane
            try:
                selected = fixture.runtime_dir / runtime
                versioned = fixture.runtime_dir / "versioned executable"
                versioned.write_text('#!/bin/sh\nprintf "BINARY_ACCOUNT=%s\\n" "${CLAUDE_CONFIG_DIR-unset}"\n')
                versioned.chmod(0o700)
                selected.unlink()
                selected.symlink_to(versioned)
                output = ""

                def run(_cli, argv, **kwargs):
                    nonlocal output
                    if argv[:2] == ["pane", "run"]:
                        setup = (
                            f'{runtime}() {{ export CLAUDE_CONFIG_DIR=wrong; printf "WRAPPER\\n"; }}\n'
                            f"alias {runtime}='false'\n"
                            + (f"hash -p /bin/false {runtime}\n" if shell == "bash" else f"hash {runtime}=/bin/false\n")
                        )
                        process = subprocess.run(
                            [shell_binary, "-f", "-c", setup + argv[3] + f"\n{runtime}\n"],
                            env=fixture.env, text=True, capture_output=True, check=True,
                        )
                        output = process.stdout
                        return ""
                    marker = argv[argv.index("--match") + 1]
                    return {"type": "output_matched", "pane_id": "w1:p1", "matched_line": marker,
                            "read": {"text": output}}

                herdr_dispatch._run_herdr = run
                herdr_dispatch._validate_pane = lambda *args: None
                herdr_dispatch._bind_pane_environment(
                    "fake", "w1:p1", "w1", fixture.repo,
                    {"launch_env": {"CLAUDE_CONFIG_DIR": None}, "account_id": "personal"},
                    fixture.env, runtime_binary=str(selected), runtime=runtime,
                )
                assert "BINARY_ACCOUNT=unset" in output and "WRAPPER" not in output, output
            finally:
                herdr_dispatch._run_herdr = original_run
                herdr_dispatch._validate_pane = original_validate
                fixture.close()


def test_prompt_is_literal_argv_and_wait_is_only_a_hint():
    fixture = Fixture()
    try:
        result = fixture.launch()
        prompt = next(call for call in fixture.calls() if call[:2] == ["agent", "prompt"])
        assert prompt[:3] == ["agent", "prompt", "impl-td-a"], prompt
        assert prompt[3].startswith("brief $HOME; `literal`\n\n"), prompt
        assert "Lifecycle attempt context:" in prompt[3], prompt
        assert "--runtime codex" in prompt[3], prompt
        assert "Keep the source tree read-only" not in prompt[3], prompt
        assert "approval is rejected" not in prompt[3], prompt
        assert prompt[4:] == ["--wait", "--timeout", "1000"], prompt
        assert result["prompt_state"] == "done", result
        assert result["completion_authoritative"] is False, result
        assert not (fixture.rd / "tasks" / "td-a.done.json").exists()
    finally:
        fixture.close()


def test_claude_prompt_receives_reserved_attempt_context_without_approval_wording():
    fixture = Fixture()
    try:
        fixture.env["FAKE_RUNTIME"] = "claude"
        fixture.launch(route=claude_route())
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        prompt = next(
            call for call in fixture.calls() if call[:2] == ["agent", "prompt"]
        )[3]
        assert "Lifecycle attempt context:" in prompt, prompt
        for value in (
            attempt["launch_id"],
            attempt["source_head_sha"],
            attempt["pane_id"],
            attempt["workspace_id"],
            "--runtime claude",
            "--phase implement",
        ):
            assert value in prompt, (value, prompt)
        assert "Keep the source tree read-only" not in prompt, prompt
        assert "approval is rejected" not in prompt, prompt
    finally:
        fixture.close()


def test_read_only_codex_launch_does_not_claim_lifecycle_writes():
    fixture = Fixture()
    try:
        result = fixture.launch(sandbox="read-only")
        start = next(
            call for call in fixture.calls() if call[:2] == ["agent", "start"]
        )
        assert "--add-dir" not in start, start
        assert start[-4:] == [
            '-c',
            'approvals_reviewer="auto_review"',
            '-a',
            'on-request',
        ], start
        prompt = next(
            call for call in fixture.calls() if call[:2] == ["agent", "prompt"]
        )
        assert "Lifecycle publication authorization:" in prompt[3], prompt
        assert str((fixture.rd / "tasks" / "td-a.done.json").resolve()) in prompt[3]
        assert "approval is rejected, report blocked" in prompt[3], prompt
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        for value in (
            attempt["launch_id"], attempt["source_head_sha"], attempt["pane_id"],
            attempt["workspace_id"], str(fixture.repo.resolve()), fixture.slug,
            "--repo-path", "--runtime codex", "--phase implement",
        ):
            assert value in prompt[3], (value, prompt)
        assert result["completion_authoritative"] is False, result
        assert result["strict_ready"] is False, result
    finally:
        fixture.close()


def test_wrong_worktree_rejects_before_attempt_or_start():
    fixture = Fixture()
    try:
        fixture.env["FAKE_HERDR_MODE"] = "wrong-pane"
        try:
            fixture.launch()
        except herdr_dispatch.DispatchError as exc:
            assert "worktree" in str(exc), exc
        else:
            raise AssertionError("wrong pane worktree was accepted")
        task = json.loads(fixture.task_file.read_text())
        assert task["workers"] == [], task
        assert not any(call[:2] == ["agent", "start"] for call in fixture.calls())
    finally:
        fixture.close()


def test_invalid_task_base_sha_rejects_before_attempt_or_start():
    fixture = Fixture()
    try:
        task = json.loads(fixture.task_file.read_text())
        fixture.task_file.write_text(json.dumps({**task, "base_sha": "not-a-sha"}))
        try:
            fixture.launch()
        except herdr_dispatch.DispatchError as exc:
            assert "worktree and branch" in str(exc), exc
        else:
            raise AssertionError("task with invalid base SHA was launched")
        assert fixture.calls() == [], fixture.calls()
        assert json.loads(fixture.task_file.read_text())["workers"] == []
    finally:
        fixture.close()


def test_task_designated_linked_worktree_rejects_other_checkout():
    fixture = Fixture()
    try:
        linked = fixture.root / "linked"
        subprocess.run(
            ["git", "-C", str(fixture.repo), "worktree", "add", "-q", "-b", "linked", str(linked)],
            check=True,
        )
        task = json.loads(fixture.task_file.read_text())
        fixture.task_file.write_text(
            json.dumps({**task, "worktree": str(linked), "branch": "linked"})
        )
        try:
            fixture.launch()
        except herdr_dispatch.DispatchError as exc:
            assert "designated worktree" in str(exc), exc
        else:
            raise AssertionError("mismatched task worktree launched")
        assert not any(call[:2] == ["agent", "start"] for call in fixture.calls())
    finally:
        fixture.close()


def test_explicit_todo_binding_must_be_ready_offline_before_dispatch():
    fixture = Fixture()
    try:
        task = json.loads(fixture.task_file.read_text())
        todo_id = "2026-09-07-runtime-policy"
        fixture.task_file.write_text(json.dumps({**task, "todo_id": todo_id}))
        todos = fixture.root / "todos.sh"
        todos.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" > \"$TODO_LOG\"\n"
            "printf '%s\\n' '{\"ready\":false,\"task_id\":\"2026-09-07-runtime-policy\",\"dependencies\":[]}'\n"
            "exit 3\n",
        )
        todos.chmod(todos.stat().st_mode | stat.S_IXUSR)
        fixture.env["TODO_LOG"] = str(fixture.root / "todo-call")
        try:
            fixture.launch(todos_cli=todos)
        except herdr_dispatch.DispatchError as exc:
            assert "TODO dependencies are not ready" in str(exc), exc
        else:
            raise AssertionError("blocked TODO dependency launched")
        assert (fixture.root / "todo-call").read_text().strip() == (
            f"ready {todo_id} --offline"
        )
        assert fixture.calls() == [], fixture.calls()
        todos.write_text(
            "#!/bin/sh\nprintf '%s\\n' "
            "'{\"ready\":true,\"task_id\":\"2026-09-07-runtime-policy\","
            "\"dependencies\":[\"bad\"]}'\n"
        )
        todos.chmod(todos.stat().st_mode | stat.S_IXUSR)
        try:
            fixture.launch(todos_cli=todos)
        except herdr_dispatch.DispatchError as exc:
            assert "result is invalid" in str(exc), exc
        else:
            raise AssertionError("malformed TODO readiness dispatched")
    finally:
        fixture.close()


def test_stale_agent_readiness_marks_launch_failed():
    fixture = Fixture()
    try:
        fixture.env["FAKE_HERDR_MODE"] = "stale-agent"
        try:
            fixture.launch()
        except herdr_dispatch.DispatchError as exc:
            assert "current attempt" in str(exc), exc
        else:
            raise AssertionError("stale agent data was accepted")
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        assert attempt["status"] == "launch_failed", attempt
        assert not (fixture.rd / "tasks" / "td-a.done.json").exists()
    finally:
        fixture.close()


def test_fresh_codex_hook_review_modal_blocks_before_prompt():
    fixture = Fixture()
    try:
        fixture.env["FAKE_HERDR_MODE"] = "hook-review-required"
        result = fixture.launch()
        assert result["status"] == "blocked", result
        assert result["reason"] == "codex-hook-review-required", result
        assert result["completion_candidate"] is False, result
        assert result["completion_authoritative"] is False, result
        assert result["strict_ready"] is False, result
        assert not any(
            call[:2] == ["agent", "prompt"] for call in fixture.calls()
        ), fixture.calls()
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        assert attempt["status"] == "blocked", attempt
        assert attempt["blocked_reason"] == "codex-hook-review-required", attempt
    finally:
        fixture.close()


def test_stale_hook_review_text_does_not_block_fresh_ready_boundary():
    fixture = Fixture()
    try:
        fixture.env["FAKE_HERDR_MODE"] = "stale-hook-review"
        result = fixture.launch()
        assert result["status"] == "launched", result
        assert any(
            call[:2] == ["agent", "prompt"] for call in fixture.calls()
        ), fixture.calls()
    finally:
        fixture.close()


def test_current_codex_hook_review_variants_are_narrowly_recognized():
    before = "shell prompt"
    overview = (
        "Hooks\n"
        "Lifecycle hooks from config and enabled plugins.\n"
        "1 hook needs review before it can run.\n"
        "Press t to trust all; enter to review hooks; esc to"
    )
    selected = (
        "Stop hooks\n"
        "1 hook needs review before it can run.\n"
        "Trust     New hook - review required\n"
        "Press t to trust; esc to go back"
    )
    unrelated = (
        "Hooks need review\n"
        "Review hooks\n"
        "Press enter to confirm or esc to go back"
    )
    assert herdr_dispatch._fresh_codex_hook_review_required(before, overview)
    assert herdr_dispatch._fresh_codex_hook_review_required(before, selected)
    assert not herdr_dispatch._fresh_codex_hook_review_required(before, unrelated)


def test_start_failure_never_emits_completion():
    fixture = Fixture()
    try:
        fixture.env["FAKE_HERDR_MODE"] = "start-fail"
        try:
            fixture.launch()
        except herdr_dispatch.DispatchError as exc:
            assert "agent_not_ready" in str(exc), exc
        else:
            raise AssertionError("failed native start was accepted")
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        assert attempt["status"] == "launch_failed", attempt
        assert not (fixture.rd / "tasks" / "td-a.done.json").exists()
    finally:
        fixture.close()


def test_malformed_herdr_json_fails_before_attempt():
    fixture = Fixture()
    try:
        fixture.env["FAKE_HERDR_MODE"] = "malformed-pane"
        try:
            fixture.launch()
        except herdr_dispatch.DispatchError as exc:
            assert "malformed JSON" in str(exc), exc
        else:
            raise AssertionError("malformed pane JSON was accepted")
        assert json.loads(fixture.task_file.read_text())["workers"] == []
    finally:
        fixture.close()


def test_presentation_failure_is_reported_after_successful_launch():
    fixture = Fixture()
    try:
        fixture.env["FAKE_HERDR_MODE"] = "metadata-fail"
        result = fixture.launch()
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        assert attempt["status"] == "launched", attempt
        assert result["presentation"]["status"] == "unsupported", result
        assert "presentation_unsupported" in result["presentation"]["reason"], result
    finally:
        fixture.close()


def test_launch_requires_managed_herdr_environment():
    fixture = Fixture()
    try:
        fixture.env.pop("HERDR_ENV")
        try:
            fixture.launch()
        except herdr_dispatch.DispatchError as exc:
            assert "Herdr-managed" in str(exc), exc
        else:
            raise AssertionError("unmanaged launch was accepted")
        assert fixture.calls() == [], fixture.calls()
        assert json.loads(fixture.task_file.read_text())["workers"] == []
    finally:
        fixture.close()


def test_native_start_timeout_range_fails_before_mutation():
    fixture = Fixture()
    try:
        for timeout in (3000, 300001):
            try:
                herdr_dispatch.launch(
                    repo_slug=fixture.slug, task_id="td-a", session="S", fence=1,
                    workspace_id="w1", pane_id="w1:p1", phase="implement",
                    agent="impl-td-a", route=codex_route(), cwd=fixture.repo,
                    sandbox="workspace-write", prompt="brief", herdr_cli=str(fixture.bin),
                    env=fixture.env, start_timeout_ms=timeout, prompt_timeout_ms=1000,
                )
            except herdr_dispatch.DispatchError as exc:
                assert "start_timeout_ms" in str(exc), exc
            else:
                raise AssertionError(f"invalid native start timeout accepted: {timeout}")
        assert fixture.calls() == [], fixture.calls()
    finally:
        fixture.close()


def test_target_shell_account_environment_is_applied_and_verified():
    fixture = Fixture()
    try:
        herdr_dispatch._bind_pane_environment(
            str(fixture.bin),
            "w1:p1",
            "w1",
            fixture.repo,
            {
                "launch_env": {"CLAUDE_CONFIG_DIR": None},
                "account_id": "account-123",
            },
            fixture.env,
        )
        run = next(call for call in fixture.calls() if call[:2] == ["pane", "run"])
        assert run[2] == "w1:p1" and "unset CLAUDE_CONFIG_DIR" in run[3], run
        codex_home = fixture.root / "Codex Home"
        herdr_dispatch._bind_pane_environment(
            str(fixture.bin), "w1:p1", "w1", fixture.repo,
            {
                "launch_env": {
                    "CODEX_HOME": str(codex_home),
                    "CLAUDE_CONFIG_DIR": None,
                    "CLAUDE_PERSONAL_ONLY": None,
                    "WORKFLOW_PERSONAL_ACCOUNT": "1",
                },
                "account_id": "account-123",
            },
            fixture.env,
            personal=True,
        )
        runs = [call for call in fixture.calls() if call[:2] == ["pane", "run"]]
        assert f"export CODEX_HOME={shlex.quote(str(codex_home))}" in runs[-1][3], runs[-1]
        assert "unset CLAUDE_CONFIG_DIR" in runs[-1][3], runs[-1]
        assert "unset CLAUDE_PERSONAL_ONLY" in runs[-1][3], runs[-1]
        assert "export WORKFLOW_PERSONAL_ACCOUNT=1" in runs[-1][3], runs[-1]
        assert "export HERDR_PERSONAL=1" in runs[-1][3], runs[-1]
        assert "export HERDR_ACCOUNT_ID=account-123" in runs[-1][3], runs[-1]
        fixture.env["FAKE_HERDR_MODE"] = "wrong-shell-env"
        try:
            herdr_dispatch._bind_pane_environment(
                str(fixture.bin),
                "w1:p1",
                "w1",
                fixture.repo,
                {
                    "launch_env": {"CLAUDE_CONFIG_DIR": None},
                    "account_id": "account-123",
                },
                fixture.env,
            )
        except herdr_dispatch.DispatchError as exc:
            assert "account environment" in str(exc), exc
        else:
            raise AssertionError("unverified target shell environment accepted")
    finally:
        fixture.close()


def test_target_shell_environment_wait_ignores_command_echo():
    fixture = Fixture()
    try:
        fixture.env["FAKE_HERDR_MODE"] = "shell-echo-before-output"
        herdr_dispatch._bind_pane_environment(
            str(fixture.bin),
            "w1:p1",
            "w1",
            fixture.repo,
            {
                "launch_env": {"CODEX_HOME": str(fixture.root / "selected")},
                "account_id": "account-123",
            },
            fixture.env,
            personal=True,
        )
        wait = next(
            call for call in fixture.calls() if call[:2] == ["pane", "wait-output"]
        )
        marker = wait[wait.index("--match") + 1]
        command_echo = (fixture.root / "command-echo").read_text()
        assert marker.startswith("HERDR_READY_"), marker
        assert marker not in command_echo, command_echo
        assert wait[-2:] == ["--source", "recent-unwrapped"], wait
    finally:
        fixture.close()


def test_launch_persists_explicit_account_selection_metadata():
    fixture = Fixture()
    try:
        fixture.launch()
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        assert attempt["personal"] is False, attempt
        assert attempt["account_id"], attempt
        run = next(call for call in fixture.calls() if call[:2] == ["pane", "run"])
        assert "export HERDR_PERSONAL=0" in run[3], run
        assert f"export HERDR_ACCOUNT_ID={attempt['account_id']}" in run[3], run
    finally:
        fixture.close()


def test_metadata_update_carries_sequence_and_launch_token():
    attempt = {
        "launch_id": "launch-123",
        "phase": "review",
        "role": "reviewer",
        "agent": "review-td-a",
        "pane_id": "w1:p1",
        "task_id": "td-a",
    }
    argv = herdr_dispatch.metadata_argv(attempt, "working", 1234)
    assert argv == [
        "herdr",
        "pane",
        "report-metadata",
        "w1:p1",
        "--source",
        "agent-runtime",
        "--title",
        "review td-a",
        "--display-agent",
        "reviewer",
        "--state-label",
        "working=working",
        "--token",
        "launch_id=launch-123",
        "--seq",
        "1234",
        "--ttl-ms",
        "3600000",
    ], argv


def test_inspect_rejects_stale_result_and_accepts_current_attempt():
    fixture = Fixture()
    try:
        result = fixture.launch()
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        done_path = fixture.rd / "tasks" / "td-a.done.json"
        done = {
            **attempt,
            "launch_id": "old-launch",
            "task_id": "td-a",
            "outcome": "completed",
            "head_sha": core.repository_context(fixture.repo)["head"],
            "base_sha": core.repository_context(fixture.repo)["head"],
        }
        done_path.write_text(json.dumps(done))
        inspected = herdr_dispatch.inspect(
            fixture.slug, "td-a", "implement", "w1", cwd=fixture.repo
        )
        assert inspected["result_matches_attempt"] is False, inspected
        done_path.write_text(json.dumps({**done, "launch_id": result["launch_id"]}))
        inspected = herdr_dispatch.inspect(
            fixture.slug, "td-a", "implement", "w1", cwd=fixture.repo
        )
        assert inspected["result_matches_attempt"] is True, inspected
        assert inspected["completion_candidate"] is True, inspected
        assert inspected["completion_authoritative"] is False, inspected
        bad = json.loads(done_path.read_text())
        done_path.write_text(
            json.dumps({**bad, "task_id": "td-wrong", "head_sha": "not-live"})
        )
        inspected = herdr_dispatch.inspect(
            fixture.slug, "td-a", "implement", "w1", cwd=fixture.repo
        )
        assert inspected["completion_authoritative"] is False, inspected
        task = json.loads(fixture.task_file.read_text())
        review_attempt = {**task["workers"][-1], "phase": "review"}
        fixture.task_file.write_text(
            json.dumps({**task, "workers": [*task["workers"], review_attempt]})
        )
        review_path = fixture.rd / "tasks" / "td-a.review.json"
        review_path.write_text(
            json.dumps(
                {**review_attempt, "task_id": "td-a", "outcome": "approved", "blocking_count": 1}
            )
        )
        inspected = herdr_dispatch.inspect(
            fixture.slug, "td-a", "review", "w1", cwd=fixture.repo
        )
        assert inspected["completion_candidate"] is True, inspected
        assert inspected["completion_authoritative"] is False, inspected
    finally:
        fixture.close()


def test_inspect_rejects_traversal_and_symlinked_payload_parent():
    fixture = Fixture()
    try:
        for slug in ("../../foreign", fixture.slug):
            if slug == fixture.slug:
                foreign = fixture.root / "foreign"
                foreign.mkdir()
                (foreign / "td-a.json").write_text(fixture.task_file.read_text())
                tasks = fixture.rd / "tasks"
                original = fixture.rd / "tasks-real"
                tasks.rename(original)
                tasks.symlink_to(foreign, target_is_directory=True)
            try:
                herdr_dispatch.inspect(
                    slug, "td-a", "implement", "w1", cwd=fixture.repo, runtime="codex"
                )
            except herdr_dispatch.DispatchError:
                pass
            else:
                raise AssertionError(f"unsafe inspect succeeded for {slug}")
    finally:
        fixture.close()


def test_unvalidated_wake_uses_bounded_watch_fallback_only():
    result = herdr_dispatch.wake(
        "00000000-0000-4000-8000-000000000001",
        event="stopped",
        repo_slug="local-deadbeef",
        workspace_id="w1",
        queue_validated=False,
    )
    assert result == {
        "status": "unsupported",
        "reason": "native-queue-not-smoke-validated",
        "fallback": "bounded-watch",
    }, result


def test_dispatch_entrypoint_preserves_machine_readable_cli_contract():
    process = subprocess.run(
        [
            sys.executable,
            herdr_dispatch.__file__,
            "wake",
            "--thread-id",
            "00000000-0000-4000-8000-000000000001",
            "--event",
            "stopped",
            "--repo-slug",
            "local-deadbeef",
            "--workspace-id",
            "w1",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert process.returncode == 3, process
    assert json.loads(process.stdout) == {
        "fallback": "bounded-watch",
        "reason": "native-queue-not-smoke-validated",
        "status": "unsupported",
    }, process.stdout


def test_reprompt_cli_subcommand_reaches_the_function():
    # Proves the reprompt subparser + main() wiring reaches herdr_dispatch.reprompt
    # (the only sanctioned entrypoint). HERDR_ENV is unset so reprompt refuses
    # deterministically without needing a live herdr.
    fx = Fixture()
    try:
        prompt_file = fx.root / "reprompt-prompt.txt"
        prompt_file.write_text("incorporate the review findings")
        child_env = {k: v for k, v in fx.env.items() if k != "HERDR_ENV"}
        process = subprocess.run(
            [sys.executable, herdr_dispatch.__file__, "reprompt",
             "--repo-slug", fx.slug, "--task-id", "td-a", "--session", "S",
             "--workspace-id", "w1", "--launch-id", "impl-td-a-abc",
             "--phase", "implement", "--cwd", str(fx.repo), "--fence", "1",
             "--prompt-file", str(prompt_file), "--runtime", "codex"],
            check=False, capture_output=True, text=True, env=child_env,
        )
        assert process.returncode == 2, (process.returncode, process.stdout, process.stderr)
        assert json.loads(process.stdout) == {
            "status": "error",
            "error": "reprompt requires a Herdr-managed environment",
        }, process.stdout
    finally:
        fx.close()


def test_attempt_record_carries_difficulty_provenance():
    fixture = Fixture()
    try:
        fixture.env["FAKE_RUNTIME"] = "claude"
        route = agent_runtime.resolve_route(
            "claude",
            "implementation",
            config={"difficulty": {"level": "hard", "proposed": "routine", "confirmed": True}},
            capabilities={
                "models": {"sonnet": {"status": "available", "efforts": ["high", "xhigh"]}}
            },
        )
        assert route["ready"] is True, route
        fixture.launch(route=route)
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        assert attempt["difficulty"] == "hard", attempt
        assert attempt["difficulty_proposed"] == "routine", attempt
        assert attempt["difficulty_confirmed"] is True, attempt
    finally:
        fixture.close()


def test_attempt_record_carries_absent_difficulty_shape():
    fixture = Fixture()
    try:
        fixture.env["FAKE_RUNTIME"] = "claude"
        fixture.launch(route=claude_route())
        attempt = json.loads(fixture.task_file.read_text())["workers"][-1]
        assert attempt["difficulty"] is None, attempt
        assert attempt["difficulty_proposed"] is None, attempt
        assert attempt["difficulty_confirmed"] is None, attempt
    finally:
        fixture.close()


def test_tampered_unconfirmed_difficulty_route_rejects_launch():
    fixture = Fixture()
    try:
        fixture.env["FAKE_RUNTIME"] = "claude"
        route = agent_runtime.resolve_route(
            "claude",
            "implementation",
            config={"difficulty": {"level": "hard", "proposed": "routine", "confirmed": True}},
            capabilities={
                "models": {"sonnet": {"status": "available", "efforts": ["high", "xhigh"]}}
            },
        )
        assert route["ready"] is True, route
        route["difficulty_confirmed"] = False
        try:
            fixture.launch(route=route)
        except herdr_dispatch.DispatchError as exc:
            assert "confirmed" in str(exc), exc
        else:
            raise AssertionError("unconfirmed difficulty route was accepted")
        assert fixture.calls() == [], fixture.calls()
        assert json.loads(fixture.task_file.read_text())["workers"] == []
    finally:
        fixture.close()


def test_reprompt_targets_named_launch_and_records_in_place():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        before = len(fx.worker_records())
        result = fx.reprompt(lid)
        assert result["status"] == "reprompted", result
        assert result["reprompt_seq"] == 0, result
        assert result["observation"] == "session-identity-not-exposed-by-herdr", result
        workers = fx.worker_records()
        assert len(workers) == before, workers
        target = [w for w in workers if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "delivered", target
        inspected = herdr_dispatch.inspect(
            fx.slug, "td-a", "implement", "w1", cwd=fx.repo, runtime="codex")
        assert inspected["current_attempt"]["launch_id"] == lid, inspected
        # A later attempt for the same phase makes the older launch_id non-current
        # (workers[-1] is NOT the selector; the named launch_id is).
        task = json.loads(fx.task_file.read_text())
        task["workers"].append({
            "launch_id": "impl-td-a-newer", "phase": "implement",
            "runtime": "codex", "workspace_id": "w1", "pane_id": "w1:p1",
            "agent": "impl-td-a", "status": "launched"})
        fx.task_file.write_text(json.dumps(task))
        try:
            fx.reprompt(lid)
        except herdr_dispatch.DispatchError as exc:
            assert "current attempt" in str(exc), exc
        else:
            raise AssertionError("a superseded launch_id must be refused")
    finally:
        fx.close()


def test_reprompt_rejects_wrong_task_context():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        task = json.loads(fx.task_file.read_text())
        task["branch"] = "totally-different-branch"
        fx.task_file.write_text(json.dumps(task))
        try:
            fx.reprompt(lid)
        except herdr_dispatch.DispatchError as exc:
            assert "worktree and branch" in str(exc), exc
        else:
            raise AssertionError("wrong task context must be refused")
        assert len(fx.prompt_calls()) == prompts_before, "no delivery on refusal"
    finally:
        fx.close()


def test_reprompt_requires_live_idle_agent():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        fx.env["FAKE_HERDR_MODE"] = "agent-busy"
        try:
            fx.reprompt(lid)
        except herdr_dispatch.DispatchError as exc:
            assert "current attempt" in str(exc), exc
        else:
            raise AssertionError("a busy agent must be refused")
        assert len(fx.prompt_calls()) == prompts_before, "no delivery to a busy agent"
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "failed", target
    finally:
        fx.close()


def test_reprompt_refuses_on_lost_fence_before_delivery():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        try:
            fx.reprompt(lid, fence=999)
        except herdr_dispatch.DispatchError:
            pass
        else:
            raise AssertionError("a wrong fence must be refused")
        assert len(fx.prompt_calls()) == prompts_before, "no delivery without the fence"
    finally:
        fx.close()


def test_reprompt_supersession_before_delivery_refuses_without_delivery():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        original = herdr_dispatch._validate_agent

        def superseding(*args, **kwargs):
            task = json.loads(fx.task_file.read_text())
            task["workers"].append({
                "launch_id": "impl-td-a-newer", "phase": "implement",
                "runtime": "codex", "workspace_id": "w1", "pane_id": "w1:p1",
                "agent": "impl-td-a", "status": "launched"})
            fx.task_file.write_text(json.dumps(task))
            return original(*args, **kwargs)

        herdr_dispatch._validate_agent = superseding
        try:
            fx.reprompt(lid)
        except herdr_dispatch.DispatchError as exc:
            assert "current attempt" in str(exc), exc
        else:
            raise AssertionError("supersession before delivery must refuse")
        finally:
            herdr_dispatch._validate_agent = original
        assert len(fx.prompt_calls()) == prompts_before, "no delivery on supersession"
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "failed", target
    finally:
        fx.close()


def test_reprompt_spawn_failure_is_retry_safe_failed():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        import types
        original = herdr_dispatch.subprocess

        def boom(*args, **kwargs):
            raise FileNotFoundError("no such delivery binary")

        herdr_dispatch.subprocess = types.SimpleNamespace(
            run=boom, TimeoutExpired=original.TimeoutExpired,
            SubprocessError=original.SubprocessError)
        try:
            fx.reprompt(lid)
        except herdr_dispatch.DispatchError as exc:
            assert "rejected before acceptance" in str(exc), exc
        else:
            raise AssertionError("a spawn failure must raise")
        finally:
            herdr_dispatch.subprocess = original
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "failed", target
    finally:
        fx.close()


def test_reprompt_nonzero_exit_is_uncertain_not_failed():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        fx.env["FAKE_HERDR_MODE"] = "prompt-reject"
        result = fx.reprompt(lid)
        assert result["status"] == "uncertain", result
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "uncertain", target
        assert target["reprompts"][0]["status"] != "failed", target
        assert len(fx.prompt_calls()) == prompts_before + 1, "exactly one delivery, no resend"
    finally:
        fx.close()


def test_reprompt_nonprompted_result_is_uncertain():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        fx.env["FAKE_HERDR_MODE"] = "prompt-nonprompted"
        result = fx.reprompt(lid)
        assert result["status"] == "uncertain", result
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "uncertain", target
    finally:
        fx.close()


def test_reprompt_uncertain_timeout_marks_uncertain_no_resend():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        import types
        original = herdr_dispatch.subprocess

        def slow(*args, **kwargs):
            raise original.TimeoutExpired(cmd="agent prompt", timeout=1)

        herdr_dispatch.subprocess = types.SimpleNamespace(
            run=slow, TimeoutExpired=original.TimeoutExpired,
            SubprocessError=original.SubprocessError)
        try:
            result = fx.reprompt(lid)
        finally:
            herdr_dispatch.subprocess = original
        assert result["status"] == "uncertain", result
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "uncertain", target
        assert len(fx.prompt_calls()) == prompts_before, "delivery raised before reaching herdr"
    finally:
        fx.close()


def test_reprompt_delivered_but_persistence_fails_returns_unrecorded():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        original = herdr_dispatch._set_reprompt_status
        state = {"calls": 0}

        def failing(*args, **kwargs):
            state["calls"] += 1
            raise OSError("disk full while recording")

        herdr_dispatch._set_reprompt_status = failing
        try:
            result = fx.reprompt(lid)
        finally:
            herdr_dispatch._set_reprompt_status = original
        assert result["status"] == "delivered-unrecorded", result
        assert len(fx.prompt_calls()) == prompts_before + 1, "delivered once, no resend"
    finally:
        fx.close()


def test_reprompt_post_spawn_oserror_is_uncertain_not_failed():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        import types
        original = herdr_dispatch.subprocess

        def comm_error(*args, **kwargs):
            raise OSError("communication failed after the child started")

        herdr_dispatch.subprocess = types.SimpleNamespace(
            run=comm_error, TimeoutExpired=original.TimeoutExpired,
            SubprocessError=original.SubprocessError)
        try:
            result = fx.reprompt(lid)
        finally:
            herdr_dispatch.subprocess = original
        assert result["status"] == "uncertain", result
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "uncertain", target
        assert target["reprompts"][0]["status"] != "failed", target
    finally:
        fx.close()


def test_reprompt_undecodable_output_is_uncertain():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        import types
        original = herdr_dispatch.subprocess

        def bad_bytes(*args, **kwargs):
            return types.SimpleNamespace(
                returncode=0, stdout=b"\xff\xfe\xff", stderr=b"")

        herdr_dispatch.subprocess = types.SimpleNamespace(
            run=bad_bytes, TimeoutExpired=original.TimeoutExpired,
            SubprocessError=original.SubprocessError)
        try:
            result = fx.reprompt(lid)
        finally:
            herdr_dispatch.subprocess = original
        assert result["status"] == "uncertain", result
    finally:
        fx.close()


def test_reprompt_refuses_to_stack_on_unresolved_prior():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        import types
        original = herdr_dispatch.subprocess

        def slow(*args, **kwargs):
            raise original.TimeoutExpired(cmd="agent prompt", timeout=1)

        herdr_dispatch.subprocess = types.SimpleNamespace(
            run=slow, TimeoutExpired=original.TimeoutExpired,
            SubprocessError=original.SubprocessError)
        try:
            first = fx.reprompt(lid)
        finally:
            herdr_dispatch.subprocess = original
        assert first["status"] == "uncertain", first
        prompts_before = len(fx.prompt_calls())
        # A retry would deliver cleanly now, but the unresolved prior turn must
        # block it so the same incorporation is never double-delivered.
        try:
            fx.reprompt(lid)
        except herdr_dispatch.DispatchError as exc:
            assert "unresolved" in str(exc), exc
        else:
            raise AssertionError("stacking on an unresolved reprompt must refuse")
        assert len(fx.prompt_calls()) == prompts_before, "no delivery while unresolved"
    finally:
        fx.close()


def test_reprompt_unparseable_reply_valueerror_is_uncertain():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        original = herdr_dispatch.result_object

        def bad_parse(*args, **kwargs):
            raise ValueError("Exceeds the limit for integer string conversion")

        herdr_dispatch.result_object = bad_parse
        try:
            result = fx.reprompt(lid)
        finally:
            herdr_dispatch.result_object = original
        assert result["status"] == "uncertain", result
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "uncertain", target
    finally:
        fx.close()


def test_reprompt_readiness_decode_error_marks_failed_and_refuses():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        original = herdr_dispatch._run_herdr

        def bad_readiness(cli, argv, **kwargs):
            if argv[:2] == ["agent", "get"]:
                raise ValueError("invalid utf-8 in agent readiness output")
            return original(cli, argv, **kwargs)

        herdr_dispatch._run_herdr = bad_readiness
        try:
            fx.reprompt(lid)
        except herdr_dispatch.DispatchError as exc:
            assert "confirm the live agent" in str(exc), exc
        else:
            raise AssertionError("a readiness decode failure must refuse")
        finally:
            herdr_dispatch._run_herdr = original
        assert len(fx.prompt_calls()) == prompts_before, "no delivery on readiness failure"
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "failed", target
    finally:
        fx.close()


def test_reprompt_delivered_unrecorded_repersists_and_allows_next_pass():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        original_set = herdr_dispatch._set_reprompt_status
        calls = {"n": 0}

        def fail_once(*args, **kwargs):
            calls["n"] += 1
            if calls["n"] == 1:
                raise OSError("transient storage error")
            return original_set(*args, **kwargs)

        herdr_dispatch._set_reprompt_status = fail_once
        try:
            result = fx.reprompt(lid)
        finally:
            herdr_dispatch._set_reprompt_status = original_set
        assert result["status"] == "delivered-unrecorded", result
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert target["reprompts"][0]["status"] == "delivered-unrecorded", target
        # A delivered-unrecorded entry must not block a later distinct pass.
        second = fx.reprompt(lid)
        assert second["status"] == "reprompted", second
        assert second["reprompt_seq"] == 1, second
    finally:
        fx.close()


def test_reprompt_rejects_unbounded_timeout_before_recording_intent():
    fx = Fixture()
    try:
        lid = fx.launch()["launch_id"]
        prompts_before = len(fx.prompt_calls())
        try:
            fx.reprompt(lid, prompt_timeout_ms=2**31)
        except herdr_dispatch.DispatchError as exc:
            assert "between 1 and 300000" in str(exc), exc
        else:
            raise AssertionError("an unbounded timeout must be refused")
        assert len(fx.prompt_calls()) == prompts_before, "no delivery on bad timeout"
        target = [w for w in fx.worker_records() if w["launch_id"] == lid][0]
        assert "reprompts" not in target or target["reprompts"] == [], target
    finally:
        fx.close()


def test_result_object_normalizes_parse_failures_to_dispatch_error():
    import herdr_dispatch_cli as cli

    original = cli.json.loads
    for exc in (RecursionError("too deep"), ValueError("integer too large")):
        def raising(*args, _exc=exc, **kwargs):
            raise _exc

        cli.json.loads = raising
        try:
            cli.result_object('{"id": "x"}', "op")
        except herdr_dispatch.DispatchError as caught:
            assert "malformed JSON" in str(caught), caught
        except Exception as leaked:  # noqa: BLE001
            cli.json.loads = original
            raise AssertionError(f"parse failure leaked as {type(leaked).__name__}")
        else:
            cli.json.loads = original
            raise AssertionError("a parse failure must become DispatchError")
        finally:
            cli.json.loads = original


def test_reprompt_cli_rejects_non_utf8_prompt_file():
    fx = Fixture()
    try:
        bad = fx.root / "bad-prompt.bin"
        bad.write_bytes(b"\xff\xfe\x00 not utf-8")
        process = subprocess.run(
            [sys.executable, herdr_dispatch.__file__, "reprompt",
             "--repo-slug", fx.slug, "--task-id", "td-a", "--session", "S",
             "--workspace-id", "w1", "--launch-id", "impl-td-a-abc",
             "--phase", "implement", "--cwd", str(fx.repo), "--fence", "1",
             "--prompt-file", str(bad), "--runtime", "codex"],
            check=False, capture_output=True, text=True, env=fx.env,
        )
        assert process.returncode == 2, (process.returncode, process.stdout, process.stderr)
        payload = json.loads(process.stdout)
        assert payload["status"] == "error", payload
    finally:
        fx.close()


for name, test in (
    ("reprompt targets the named launch and records in place", test_reprompt_targets_named_launch_and_records_in_place),
    ("reprompt rejects a wrong task context", test_reprompt_rejects_wrong_task_context),
    ("reprompt requires a live idle agent", test_reprompt_requires_live_idle_agent),
    ("reprompt refuses on a lost fence before delivery", test_reprompt_refuses_on_lost_fence_before_delivery),
    ("reprompt refuses supersession before delivery", test_reprompt_supersession_before_delivery_refuses_without_delivery),
    ("reprompt spawn failure is retry-safe failed", test_reprompt_spawn_failure_is_retry_safe_failed),
    ("reprompt nonzero exit is uncertain not failed", test_reprompt_nonzero_exit_is_uncertain_not_failed),
    ("reprompt non-prompted result is uncertain", test_reprompt_nonprompted_result_is_uncertain),
    ("reprompt timeout marks uncertain without resend", test_reprompt_uncertain_timeout_marks_uncertain_no_resend),
    ("reprompt delivered but persistence fails returns unrecorded", test_reprompt_delivered_but_persistence_fails_returns_unrecorded),
    ("reprompt post-spawn OSError is uncertain not failed", test_reprompt_post_spawn_oserror_is_uncertain_not_failed),
    ("reprompt undecodable output is uncertain", test_reprompt_undecodable_output_is_uncertain),
    ("reprompt refuses to stack on an unresolved prior", test_reprompt_refuses_to_stack_on_unresolved_prior),
    ("reprompt unparseable reply is uncertain", test_reprompt_unparseable_reply_valueerror_is_uncertain),
    ("reprompt readiness decode error marks failed and refuses", test_reprompt_readiness_decode_error_marks_failed_and_refuses),
    ("reprompt delivered-unrecorded repersists and allows next pass", test_reprompt_delivered_unrecorded_repersists_and_allows_next_pass),
    ("reprompt rejects an unbounded timeout before recording intent", test_reprompt_rejects_unbounded_timeout_before_recording_intent),
    ("result_object normalizes parse failures to DispatchError", test_result_object_normalizes_parse_failures_to_dispatch_error),
    ("reprompt CLI rejects a non-utf8 prompt file", test_reprompt_cli_rejects_non_utf8_prompt_file),
    ("reprompt CLI subcommand reaches the function", test_reprompt_cli_subcommand_reaches_the_function),
    ("runtime resolution respects symlink parent traversal", test_runtime_resolution_preserves_filesystem_parent_semantics),
    ("runtime binding records selected executable before start", test_runtime_binding_precedes_start_and_records_selected_entry),
    ("missing or mismatched runtime blocks before launch", test_missing_or_mismatched_binary_refuses_before_attempt_and_start),
    ("real shells bypass stale runtime wrappers and hashes", test_runtime_binding_bypasses_aliases_functions_and_stale_hashes),
    ("personal pane launch disables the Atlassian plugin", test_launch_records_attempt_before_native_start),
    ("prompt content stays argv-literal and wait is a hint", test_prompt_is_literal_argv_and_wait_is_only_a_hint),
    ("Claude prompt receives its reserved attempt context", test_claude_prompt_receives_reserved_attempt_context_without_approval_wording),
    ("read-only Codex launch does not claim lifecycle writes", test_read_only_codex_launch_does_not_claim_lifecycle_writes),
    ("wrong pane worktree rejects before mutation", test_wrong_worktree_rejects_before_attempt_or_start),
    ("invalid task base SHA rejects before mutation", test_invalid_task_base_sha_rejects_before_attempt_or_start),
    ("task designated linked worktree rejects other checkout", test_task_designated_linked_worktree_rejects_other_checkout),
    ("explicit TODO binding must be ready offline before dispatch", test_explicit_todo_binding_must_be_ready_offline_before_dispatch),
    ("stale agent readiness cannot confirm current attempt", test_stale_agent_readiness_marks_launch_failed),
    ("fresh Codex hook review modal blocks before prompt", test_fresh_codex_hook_review_modal_blocks_before_prompt),
    ("stale hook review text does not block a fresh ready boundary", test_stale_hook_review_text_does_not_block_fresh_ready_boundary),
    ("current Codex hook review variants are narrowly recognized", test_current_codex_hook_review_variants_are_narrowly_recognized),
    ("failed native start never emits completion", test_start_failure_never_emits_completion),
    ("malformed Herdr JSON rejects before mutation", test_malformed_herdr_json_fails_before_attempt),
    ("presentation failure is reported after launch", test_presentation_failure_is_reported_after_successful_launch),
    ("launch requires a managed Herdr environment", test_launch_requires_managed_herdr_environment),
    ("native start timeout range fails before mutation", test_native_start_timeout_range_fails_before_mutation),
    ("target shell account environment is applied and verified", test_target_shell_account_environment_is_applied_and_verified),
    ("target shell environment wait ignores command echo", test_target_shell_environment_wait_ignores_command_echo),
    ("launch pins explicit account selection metadata", test_launch_persists_explicit_account_selection_metadata),
    ("delayed metadata updates carry sequence and launch token", test_metadata_update_carries_sequence_and_launch_token),
    ("inspect matches only the latest strict attempt", test_inspect_rejects_stale_result_and_accepts_current_attempt),
    ("inspect rejects traversal and symlinked payload parent", test_inspect_rejects_traversal_and_symlinked_payload_parent),
    ("unvalidated native wake falls back to bounded watch", test_unvalidated_wake_uses_bounded_watch_fallback_only),
    ("dispatch entrypoint preserves its JSON CLI contract", test_dispatch_entrypoint_preserves_machine_readable_cli_contract),
    ("attempt record carries difficulty provenance", test_attempt_record_carries_difficulty_provenance),
    ("attempt record carries absent difficulty shape", test_attempt_record_carries_absent_difficulty_shape),
    ("tampered unconfirmed difficulty route rejects launch", test_tampered_unconfirmed_difficulty_route_rejects_launch),
):
    check(name, test)

print(f"\n{PASS} passed, {FAIL} failed")
raise SystemExit(FAIL != 0)
PY
