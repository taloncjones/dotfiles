#!/bin/sh
set -eu
repo_dir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
test_home="$(mktemp -d)"
custom_home="$(mktemp -d)"
trap 'rm -rf "$test_home" "$custom_home"' EXIT HUP INT TERM
HOME="$test_home" DOTFILEDIR="$repo_dir" bash "$repo_dir/install/common/link.sh" >"$test_home/install.log" 2>&1
cp "$test_home/.codex/config.toml" "$test_home/before.toml"
HOME="$test_home" DOTFILEDIR="$repo_dir" bash "$repo_dir/install/common/link.sh" >>"$test_home/install.log" 2>&1
cmp "$test_home/before.toml" "$test_home/.codex/config.toml"
mkdir -p "$custom_home/.codex/hooks"
printf 'custom guard\n' > "$custom_home/.codex/hooks/orch_edit_guard.py"
HOME="$custom_home" DOTFILEDIR="$repo_dir" bash "$repo_dir/install/common/link.sh" >"$custom_home/install.log" 2>&1
test ! -L "$custom_home/.codex/hooks/orch_edit_guard.py"
test "$(cat "$custom_home/.codex/hooks/orch_edit_guard.py")" = 'custom guard'
if command -v uv >/dev/null 2>&1; then
    set -- uv run --no-project --python '>=3.11' --offline --no-cache python
else
    set -- python3
fi
"$@" - "$test_home" "$repo_dir" <<'PY'
import json
import pathlib
import shlex
import subprocess
import sys
import tomllib

home, repo = map(pathlib.Path, sys.argv[1:])
config = tomllib.loads((home / '.codex/config.toml').read_text())
commands = [hook['command'] for group in config.get('hooks', {}).get('Stop', [])
            for hook in group.get('hooks', []) if 'herdr_stop_gate.py' in hook.get('command', '')]
assert len(commands) == 1, 'installer must register exactly one native Stop adapter'
linked = home / '.codex/hooks/herdr_stop_gate.py'
assert linked.is_symlink() and linked.resolve() == repo / 'codex/hooks/herdr_stop_gate.py'
pretool = [hook['command'] for group in config.get('hooks', {}).get('PreToolUse', [])
           for hook in group.get('hooks', []) if 'orch_edit_guard.py' in hook.get('command', '')]
assert len(pretool) == 1, 'installer must register exactly one native edit guard adapter'
linked_guard = home / '.codex/hooks/orch_edit_guard.py'
assert linked_guard.is_symlink() and linked_guard.resolve() == repo / 'codex/hooks/orch_edit_guard.py'
result = subprocess.run(shlex.split(commands[0]), input='{"hook_event_name":"Stop","stop_hook_active":false}',
                        text=True, capture_output=True, timeout=10)
assert result.returncode == 0, result.stderr
assert json.loads(result.stdout) == {}, result.stdout
print('[OK] Codex adapters are linked, registered, idempotent, and valid outside Herd')
PY
