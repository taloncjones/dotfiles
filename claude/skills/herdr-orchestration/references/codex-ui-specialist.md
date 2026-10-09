# Bounded Codex UI specialist (SKILL.md section 2a-UI and Runtime boundary)

## Codex compatibility entrypoint (from Runtime boundary)

`codex/skills/herdr-orchestration/SKILL.md` remains an installed compatibility
entrypoint. Shared compatibility APIs are retained, but a Codex-driven Herd
controller is not supported and is not a goal; Codex participates only as a
bounded specialist. Any later Codex controller-oriented examples
are compatibility references, not default dispatch instructions. Claude socket,
Monitor, SendMessage, and Workflow instructions apply only when those native
Claude capabilities exist. They are not Codex APIs.

## 2a-UI. Bounded Codex UI specialist dispatch

Use this path only from the Claude implementation worker's existing task
worktree. It adds no worktree, controller, permission bypass, account switch,
or parallel writer. The Codex specialist may edit only the assigned UI files
and tests, then exits with a result. It never claims task ownership, commits,
or emits `emit-done` or `emit-review`.

Resolve the UI route with the existing runtime policy override:

```python
agent_runtime.resolve_route(
    "codex",
    "implementation",
    config={"routes": {"implementation": {"model": "gpt-6-astra", "effort": "high"}}},
)
```

The generic Codex implementation route remains Terra/medium for non-UI work. Run
the existing `run_bounded`/`launch_argv` path through `agent_runtime.py` from
the Claude worker's own worktree. `TASK_WORKTREE`, `UI_BRIEF`, and `UI_RESULT`
must be absolute paths; the brief and result are private paths outside public
repository content. The private brief must name the exact assigned UI files and
tests, forbid commits, lifecycle emission, and account changes, and require the
specialist to report any scope drift.

```bash
# Add --personal before --cwd when the original work-repository task deliberately
# uses personal Claude quota.
if uv run --no-cache --offline --no-project python "$RUNTIME" run \
  --runtime codex --role implementation --risk normal \
  --config-json '{"routes":{"implementation":{"model":"gpt-6-astra","effort":"high"}}}' \
  --provisional --cwd "$TASK_WORKTREE" --sandbox workspace-write \
  --timeout-secs 600 --prompt-file "$UI_BRIEF" > "$UI_RESULT"; then
  python3 - "$UI_RESULT" <<'PY' || exit 1
import json
import sys

try:
    record = json.load(open(sys.argv[1]))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid Codex runner JSON: {exc}")

if not (
    isinstance(record, dict)
    and record.get("status") == "success"
    and record.get("exit_code") == 0
    and record.get("timed_out") is False
    and isinstance(record.get("result"), str)
    and record["result"].strip()
):
    raise SystemExit("Codex UI specialist result is incomplete")
PY
else
  printf '%s\n' 'Codex UI specialist did not complete' >&2
  exit 1
fi
```

Run this inside the already isolated Claude worker worktree, preserving the
selected account. For a personal Claude worker, leave `CLAUDE_CONFIG_DIR`
unset. Preserve the worker's actual `CODEX_HOME`; do not replace either
environment value or broaden `workspace-write` permissions. `--provisional`
reports unverified availability; it does not make an error acceptable. Retain
`--personal` on the runner invocation when the original task deliberately
selects personal quota in a work repository.

The runner process and JSON gate must both succeed before any other writer
resumes. A nonzero process exit, malformed JSON, `error` or `timeout` status,
missing or nonzero `exit_code`, true `timed_out`, empty/non-string `result`, or
any diff/status scope drift blocks the pass. Claude then validates the complete
diff, status including untracked files, and applicable tests. A fresh
independent Claude reviewer -- never the supervising worker -- must run
`review-change` before the Claude worker accepts a Codex UI change and emits
its own lifecycle record. The task-local result is not PR approval. Frozen
Claude + Codex co-review remains the final finished-PR gate.
