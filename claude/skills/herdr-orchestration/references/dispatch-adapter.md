# Dispatch adapter: routes, launch, presentation (SKILL.md sections 1 and 8)

## Route config and readiness (section 1 step 6)

6. **Selected-runtime readiness (owner only, after config validation).**
   New native Claude and Codex dispatches use the selected runtime's resolver:
   `python3 "$RUNTIME" route --runtime <claude|codex> --role <controller|planner|implementation|reviewer|plan_reviewer|development_reviewer|read_only|mechanical|think> --risk <normal|critical>`.
   Step-to-worker defaults and the two effort-raising axes are in
   `references/pipeline-worker-mapping.md`.

   Every native `route` call in this skill also passes the repo's `routes`
   config block (empty when `config.json` has no `routes` key), so a repo can
   lower a role's effort down to the resolver's floor without a code change.
   Build ONE config object per call: read `routes` from `config.json`
   (default `{}`), then merge in the `DIFFICULTY_JSON` environment variable
   when it is non-empty (a difficulty object the human confirmed). Export it
   in the SAME shell call as the snippet -- shell state does not survive
   between Bash tool calls -- and only for a route whose role accepts
   difficulty (`planner`, `implementation`, `development_reviewer`,
   `reviewer`, `skeptic`, `think`; `DIFFICULTY_ROLES` in
   `agent_runtime.py`); leave it unset for `controller`, `plan_reviewer`,
   `read_only` and `mechanical`, which refuse it:

   ```bash
   ROUTE_CONFIG="$(python3 - "$STATE_ROOT/<slug>/config.json" <<'PY'
   import json, os, sys
   cfg = json.load(open(sys.argv[1]))
   config = {"routes": cfg.get("routes", {})}
   difficulty = os.environ.get("DIFFICULTY_JSON", "").strip()
   if difficulty:
       config["difficulty"] = json.loads(difficulty)
   print(json.dumps(config))
   PY
   )"
   python3 "$RUNTIME" route --runtime claude --role implementation --risk normal --config-json "$ROUTE_CONFIG"
   ```

   `--config-json` is passed once per route call; routes and difficulty
   travel in the same object. Re-run this snippet immediately before each
   route call rather than reusing a stale shell variable.

   A malformed `routes` block fails the `route` call with the resolver's
   message, which blocks that dispatch.
   Inspect the returned readiness and capability evidence before dispatch;
   retain unknown availability as unknown and block an unready route. Use
   explicit policy/capability inputs when needed, as described under Model
   launch in section 8. Neither native adapter requires the opposite CLI or
   the legacy Fable probe below. A `BUSY` non-owner performs no discovery,
   probe, or capability write.

## Model launch (section 8)

**Model launch (shared native adapter).** For all new interactive workers,
resolve model and effort together through `agent_runtime.py`. The older Claude
`routing-table --repo-slug` remains for existing `run-mech`/`run-think` wrappers;
do not pass its Claude-only aliases to Codex.

One snapshot per dispatch: use `route --runtime <claude|codex> --role
<planner|implementation|reviewer|plan_reviewer|read_only|mechanical|think> --risk
<normal|critical> --config-json "$ROUTE_CONFIG"` (step 6 snippet) and optional
explicit policy/capability files. Inspect the
returned readiness, availability reason, model, and effort before launch.
Catalog presence is not proof that the selected account can run a model.
Unknown availability is reported; no silent downgrade of a critical route.

`config.json`'s optional `routes` block lets a repo pin a role's model and/or
effort: `{role: {model?, effort?}}`. The resolver, not the core, enforces a
floor that compares the configured model/effort's quality tier against the
role's default model at `low` (`EFFORT_FLOOR`) -- a stronger model may
pass at a lower effort label, and a weaker model at a higher one (an opus
role accepts `sonnet/medium` but not `sonnet/low`) -- raised under critical
risk or
`difficulty=hard`; a malformed `routes` block fails the `route` call and
blocks that dispatch rather than silently falling back.

Use `herdr_dispatch.py launch` with the existing shell pane/workspace,
canonical repo path, task, session/fence, phase, unique agent name, resolved
route JSON, sandbox, and prompt file. Read its `--help` for the exact current
flags. Launch waits up to about 5 seconds for a fresh pane's shell before
refusing with `designated pane is not at an interactive shell`. The adapter
owns argv quoting, environment binding, attempt reservation,
readiness inspection, and presentation updates. It never creates a worktree
or chooses a different account for the caller.

## Adapter launch rules (section 8)

- Native Herd fixes the executable name. The adapter resolves that executable
  through the dispatch environment, removes its alias/function only in the
  designated idle task pane, and verifies its PATH resolution alongside account
  bindings before start. The attempt records `runtime_binary`. This verifies
  prelaunch resolution; it does not prove the running process's account or
  permit another controller to change the pane between binding and start.
- Implementation uses `workspace-write`; read/review uses `read-only`.
- A read-only Codex reviewer may request normal automatic approval for the
  exact lifecycle record and findings-output paths authorized by its brief.
  `approvals_reviewer="auto_review"` does not change its sandbox. An approval
  rejection means blocked; it is never proof of completed review. Do not use
  `--approve-for-me` here because it changes the sandbox to workspace-write.
- Requested model/effort is not observed model/effort. Record unknown when the
  native metadata does not expose a value. In-session reviewers report their
  actual current effort; the policy does not change an already running model.
- Herdr startup/readiness and `agent prompt --wait` are transport evidence,
  never completion. Only the core's milestone/contract/review gates advance.
- The adapter's own `agent prompt --wait` is bounded to ACCEPTANCE with
  `--until working --until blocked`. Without `--until`, herdr matches
  `idle|done|blocked` -- the first turn finishing -- so a normally-long first
  turn times out and a live worker is misrecorded. Verified against herdr
  0.9.1; the release that introduced `--until` is not established, so an older
  herdr would reject the flag and fail the launch loudly. This applies to the
  adapter's launch and reprompt calls only. The `/exit` interrupt above wants
  the DEFAULT predicate -- it is waiting for the agent to leave -- so never add
  `--until working` to it.
- A prompt-wait timeout is not itself a launch failure. The adapter re-polls
  `agent get` once before classifying: a `working` or `done` agent records
  `launched` with `prompt_wait: late-ready` and `prompt_wait_cause` holding the
  wait's error, so the timeout stays visible rather than being swallowed.
  Anything else keeps `launch_failed` and surfaces the prompt's error, not the
  re-poll's. A clean wait records `prompt_wait: accepted`. Never delete a task
  or worktree because a prompt wait timed out.
- The re-poll never accepts `blocked`, even though the wait itself may match
  it. herdr rejects a submission to an already-blocked agent with
  `agent_blocked` BEFORE writing any input, and `agent get` cannot tell that
  refusal apart from a brief that landed and then hit a permission prompt.
  Recording the refusal as `launched` would strand a phantom worker the
  controller waits on forever. On the accepted path the `agent_prompted`
  envelope proves delivery, so `--until blocked` is correct there. When herdr
  names the refusal outright with `agent_blocked`, the adapter skips the
  re-poll entirely: delivery is provably absent, so no later observation --
  including an agent that unblocks and starts an unrelated turn -- can rescue
  the attempt.
- Two residual windows this does NOT close, both pre-existing. herdr applies a
  fixed 5000ms acceptance bound independent of `--timeout` and returns
  `agent_prompt_stalled` for an accepted submission showing no activity in it,
  so a delivered brief whose worker is slow to register can still record
  `launch_failed`. And `--until working` is weak against an agent that is
  already working; `AgentInfo.state_change_seq` is the signal that would close
  that, and the adapter reads neither it nor `revision` across the prompt.
- Banner evidence must follow a unique current-launch boundary. The legacy
  `classify-banner --model <alias> --effort <level|inherit> --text-file <path>`
  requires `--after <marker>` or an independently fresh `--fresh-capture`.
  A changed whole-screen hash alone does not make old scrollback fresh.
- `effort-mismatch` is not availability data. Do not disable a model or evade
  account caps because a requested effort was refused. Stop the owned worker,
  report requested versus observed settings, and resolve an authorized route.
- Route fallback never switches authentication. After an unavailable model,
  choose only an explicitly configured same-account fallback and record it.

## Compact presentation (section 8)

Compact presentation. The Herdr sidebar label of a task workspace is
`<state>: <title>`, at most 25 characters, with the state first so any
truncation keeps it. `<title>` is the record's `title` (the Jira summary
or todo title) with ticket keys and `#<n>` PR references removed; the
task record keeps the ids. `core.task_label` derives it:

| Record                                                     | Token                  |
| ---------------------------------------------------------- | ---------------------- |
| `in-progress`, last launched phase plan (or none)          | `plan`                 |
| `in-progress`, last launched phase implement or mechanical | `impl`                 |
| `in-progress`, last launched phase review / ship           | `review` / `co-review` |
| `blocked`                                                  | `blocked`              |
| `completed`                                                | `review-due`           |
| `review-dispatched`                                        | `review`               |
| `changes-requested`                                        | `repair`               |
| `reviewed`, no `pr_number`                                 | `open-pr?`             |
| `reviewed`, PR, no ship handoff for `ship_launch_id`       | `co-review`            |
| `reviewed`, PR, handoff APPROVE at `review_head_sha`       | `merge?`               |
| `reviewed`, PR, any other handoff                          | `gate?`                |
| `pr-open-pending-merge`                                    | `merge?`               |
| `merged`, `abandoned`, `failed`, `paused`                  | verbatim               |

A `?` marks a state that waits on the owner. Triggers:
`write-task --present` (section 9), the adapter's `launch` and `settle`,
and `present-task --all --apply` at preflight and every check-in. A
rename happens only when the workspace's `worktree.checkout_path` is the
task's `worktree`, so a reused workspace id or the director's own
workspace is never relabelled. The label is display-only Herdr state: no
gate reads it, the next trigger overwrites a manual rename, and launch
IDs, not labels, are the provenance keys. Pane metadata still shows
role, runtime/model and status separately; presentation failure is
visible but never changes completion state. Lead-scoped records are not
labelled.
