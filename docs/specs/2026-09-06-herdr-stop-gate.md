# Spec: Block worker stops until the completion record exists

Date: 2026-09-06
Branch: talon/td-2026-09-06-block-worker-stops-until-the-completion-record-exi/stop-gate
Source task: td-2026-09-06-block-worker-stops-until-the-completion-record-exi
Status: branch-only document; dropped before merge together with the plan.

## Problem

An orchestrated worker's completion signal is prose in its brief ("run
emit-done, then stop"). When a worker goes idle without emitting (it forgot,
a denied action ended its turn, its context ran out) the orchestrator sees
`idle` with no `tasks/<task_id>.done.json` and has to inspect the pane by
hand. Nothing structural stands between "the model decided to stop" and
"the record exists". Anthropic's hook guidance and the ralph-loop family
gate completion with a `Stop` hook that refuses the stop until the artifact
exists, bounded by a continuation cap so it cannot loop forever.

## Goal

A `Stop` hook, `claude/hooks/herdr_stop_gate.py`, registered in
`claude/settings.json.tmpl`, that refuses a worker session's stop until the
completion record for its task and workspace exists and is newer than the
worker's launch, tells the worker exactly what to run, and releases after
two refusals so a worker that genuinely cannot emit still hands back. It is
inert for every session that is not an orchestrated worker, reads herdr
state read-only, and fails open.

## Non-goals

- No writes anywhere. The hook never appends to `events.jsonl`, never
  touches `STATE_ROOT`, and keeps no counter file. The task brief's
  `stop-unblocked` events marker is therefore NOT emitted: the events
  vocabulary and its single-writer rule live in `herdr_orch_core.py` and
  `claude/skills/herdr-orchestration/references/event-schema.md`, both
  owned by a parallel branch. A release after the cap is surfaced to the
  human through the hook's own output instead (D5) and the orchestrator's
  existing "idle with no record" handling covers the rest.
- No changes to `claude/hooks/herdr_orch_core.py`,
  `claude/skills/herdr-orchestration/`, `claude/skills/co-review/`,
  `git/hooks/commit-msg`, or `install/common/codex-*`. The worker briefs
  and the skill's event notes are not updated here; see Follow-ups.
- No change to `claude/hooks/herdr_worker_status.py`. It keeps firing on
  every Stop, including refused ones (see Known interactions).
- No verifier run inside the hook. The contract gate (`verify-contract`)
  stays where it is, in the worker's close procedure and the orchestrator's
  correlation. The hook checks only that the record exists.
- No gating of `SubagentStop`, `Notification`, or any non-`Stop` event.
- No gating of headless mech or deep-think runs. They inherit the
  orchestrator's `HERDR_WORKSPACE_ID`, whose workspace has no index, so the
  hook is inert for them by construction (D1).

## Confirmed facts (2026-09-06, worktree at main `682d9db`)

- Claude Code 2.1.263. A headless probe with a scratch `Stop` hook showed:
  the Stop payload carries `session_id`, `cwd`, `prompt_id`,
  `permission_mode`, `hook_event_name`, `stop_hook_active`,
  `last_assistant_message`, `background_tasks`, `session_crons`, and NO
  `transcript_path`. A hook that exits 2 with text on stderr refuses the
  stop; Claude continues, and the next Stop payload has
  `stop_hook_active: true`. The refusal is persisted in the session
  transcript as a `type: user` line whose message content starts
  `Stop hook feedback:` followed by `[<hook command>]: <stderr text>`. The
  transcript lives at `<config dir>/projects/<cwd slug>/<session_id>.jsonl`
  and a glob on `projects/*/<session_id>.jsonl` under the config dir
  matched exactly one file.
- The orchestrator's live task record for this task writes each
  `workers[]` entry with `ts` (`2026-09-06T18:38:51Z`), not the `started`
  key that `references/state-layout.md` documents. The hook must accept
  either key. The `.done.json` written by `emit-done` carries `ts` in the
  same `YYYY-MM-DDTHH:MM:SSZ` form (`core.now_iso`), plus `task_id` and
  `workspace_id`; `.review.json` carries the same three keys.
- `workspaces/<ws>.json` holds `task_id`, `repo_slug`, `role` with role
  `impl` (plan and implement phases alike) or `review`. A live index for
  this session's workspace exists with role `impl` and phase `plan` in the
  task record.
- `herdr_worker_status.py` finds its index with
  `state_root().glob("*/workspaces/<ws>.json")`, derives the repo dir from
  the index path (never from payload paths), uses `core.read_index`,
  `core.valid_workspace_id`, and always exits 0. `core.read_index` rejects
  symlinks and paths outside `state_root()`.
- `herdr_orch_core.run_headless` passes no `HERDR_*` overrides; mech and
  think launches inherit the orchestrator's environment.
- Template `Stop` group: one `*` matcher listing
  `~/.claude/hooks/herdr_worker_status.py`. `claude-hooks.test.sh` proves
  every template hook is present in each live `settings.json` (superset
  check) and asserts exact order only for the PreToolUse Bash group.
- Baselines: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh`
  77/0 (the unsandboxed run shows 81/2, both failures live settings drift
  on this machine); `sh claude/hooks/herdr-orch.test.sh` 106/0;
  `sh claude/hooks/herdr-orch-contract.test.sh` 65/0.
- `talon/claude-codex-parity` (unmerged) edits `account_guard.py`,
  `herdr_worktree_guard.py`, the `guard_case` region of
  `claude-hooks.test.sh`, and the template `env` block. It does not touch
  the `Stop` group or `herdr_worker_status.py`. New tests are appended at
  the end of the suite, before the summary lines, to stay clear of that
  region.
- CI runs `bin/dotfiles-tests` on `ubuntu-latest`; every check must pass
  on Linux as well as macOS (no `st_birthtime`, no BSD-only flags). This
  machine runs Python 3.14; no minimum is pinned anywhere in the repo, so
  the hook uses only APIs stable since Python 3.8 (D2 parser).

## Design

### D1. Activation

The hook runs on every `Stop`. It allows the stop (exit 0, no output)
unless ALL of the following hold; each check is evaluated in this order and
the first miss ends the hook:

1. stdin parses as a JSON object and `hook_event_name == "Stop"`.
2. `HERDR_ENV == "1"`.
3. `HERDR_WORKSPACE_ID` passes `core.valid_workspace_id`.
4. Some `<state_root>/*/workspaces/<ws>.json` reads through
   `core.read_index` as an object. Candidates are visited in sorted path
   order (a sorted variant of the status hook's glob walk, which takes
   them in glob order); the first readable one is the worker's index and
   its grandparent directory is the repo dir `rd`.
5. The index `role` is `impl` or `review` and its `task_id` passes
   `core.valid_task_id`. Everywhere below, `<task_id>` means this index
   value and `<ws>` means `HERDR_WORKSPACE_ID`.

An orchestrator session, a plain interactive session, a mech or think
headless run, and a workspace whose index was never written all fail one of
these and are never gated.

### D2. Launch time

From `rd/tasks/<task_id>.json` (read as an object; anything else means
unknown), take the LAST `workers[]` entry whose `workspace_id` equals
`<ws>` AND whose `role` equals the index role. The role match matters
because a mech launch shares the impl workspace id (state-layout's
`workers[]` example has an `impl` and a `mech` entry both on `w1`);
without it the later mech entry would post-date the impl worker's own
record and wrongly refuse it. The entry's launch time is `started` if
present, else `ts`. Missing record, no matching entry, or an unparseable
value gives an UNKNOWN launch time. Unknown never blocks by itself: it
only removes the recency test in D3.

Timestamp parser (used for launch time and for record `ts`, stdlib only,
identical on every Python 3 the repo runs on): the value must match
`^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$`.
The six captured fields build a `datetime` in UTC; a numeric offset is
subtracted (`+02:00` means two hours earlier in UTC); `Z` or no suffix
means UTC; fractional seconds are dropped. Anything else (a date only, a
space separator, a non-string) is unparseable. `datetime.fromisoformat`
is NOT used: it rejects a trailing `Z` before Python 3.11.

The matched entry supplies `agent` and `phase` for the refusal text (D5);
`base_sha` comes from the task record's TOP level (`workers[]` entries
carry none). Each falls back to a literal `<placeholder>` when absent.

### D3. Record acceptance

The record path is `rd/tasks/<task_id>.done.json` for role `impl` and
`rd/tasks/<task_id>.review.json` for role `review`, with `<task_id>` the
index value (D1 step 5). The other file never satisfies the other role.
The record is ACCEPTED iff:

- the path is a regular file, not a symlink, contained in `state_root()`;
- it parses as a JSON object;
- `task_id` equals the index `task_id` and `workspace_id` equals `<ws>`
  (provenance, mirroring `confirm-completion`);
- `ts` parses under the D2 parser; and
- when the launch time is known, `ts >= launch time` (second resolution,
  equality accepted, no tolerance: orchestrator and worker run on one host
  and both stamp UTC from the same clock, and any tolerance wide enough to
  matter would re-accept the previous phase's record when the next phase
  launches within it; a skewed clock costs at most the two refusals of
  D4, never a lost handback).

`outcome`, `v`, `phase`, and the SHA fields are not inspected: any
`emit-done`/`emit-review` record for this workspace, written after launch,
is a handback. An accepted record allows the stop with exit 0 and no output.

### D4. Continuation cap

When no record is accepted, the hook decides between BLOCK and RELEASE from
two read-only inputs: the payload's `stop_hook_active` boolean and the
number of earlier refusals in this session.

Earlier refusals are counted from the session transcript: `session_id` must
match `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`;
the transcript is the single match of `<base>/projects/*/<session_id>.jsonl`
where `<base>` is the config dir itself, `CLAUDE_CONFIG_DIR` or
`~/.claude` (the directory `core.state_root()` appends `herdr-orch` to,
i.e. `state_root().parent`, never `state_root()`). The count is the number
of transcript lines containing the marker `herdr-stop-gate: blocked` (the
first token of every refusal, D5; confirmed persisted verbatim inside the
`Stop hook feedback:` user line by the 2026-09-06 probe). Zero or several
matches, an unreadable file, or an invalid session id give an UNKNOWN
count. The marker literal is assembled from two pieces in the hook source
so a worker that prints the hook file does not add a spurious match; a
worker that echoes the marker on purpose only releases itself earlier,
never traps itself.

Decision with `MAX_BLOCKS = 2`:

| `stop_hook_active` | count                 | result                                        |
|--------------------|-----------------------|-----------------------------------------------|
| false              | any or unknown        | BLOCK (a fresh stop cycle always gets one)    |
| true               | unknown               | RELEASE, reason `transcript unavailable`      |
| true               | 0                     | RELEASE, reason `transcript evidence missing` |
| true               | 1 .. `MAX_BLOCKS - 1` | BLOCK                                         |
| true               | >= `MAX_BLOCKS`       | RELEASE, reason `cap reached`                 |

The third row is the loop backstop: `stop_hook_active` true proves at
least one refusal already happened in this cycle, so a readable transcript
with zero markers proves the marker is not being recorded (a future
transcript format, an unflushed line) and the gate must not rely on ever
counting to the cap. Every row with `stop_hook_active` true and no
countable evidence releases; the gate therefore never refuses more than
`MAX_BLOCKS` times in a row regardless of transcript behaviour, and
degrades to one refusal when evidence is missing.

The count is per session, not per cycle: after a release, a later stop
cycle (new user prompt, `stop_hook_active` false) is refused once more and
then released on its next firing. This re-trap is intended: each new cycle
gets exactly one reminder, and a worker that truly cannot emit pays one
refusal per cycle, never more. A `/clear` or relaunch starts a new session
id and a fresh count.

### D5. Output contract

BLOCK: exit 2, nothing on stdout, exactly three lines on stderr:

```
herdr-stop-gate: blocked (<n> of 2) -- emit-done (or emit-review) before stopping; the orchestrator only recognizes the record.
Run: <command>
Then stop again. The gate releases after 2 blocks even without a record.
```

`<n>` is the refusal number (`count + 1`, or `1` when the count is
unknown). `<command>` is the complete `emit-done` line for role `impl`:

```
python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py emit-done --repo-slug <slug> --task-id <task_id> --workspace <ws> --agent <agent> --phase <phase> --outcome completed|failed|paused --head-sha "$(git rev-parse HEAD)" --base-sha <base_sha>
```

and the `emit-review` line for role `review`:

```
python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py emit-review --repo-slug <slug> --task-id <task_id> --workspace <ws> --agent <agent> --reviewed-head-sha "$(git rev-parse HEAD)" --outcome approved|changes-requested --blocking-count <n> --findings-ref <path>
```

`<slug>` is the repo dir's basename, `<task_id>` and `<ws>` are the
worker's, `<agent>` and `<phase>` (`plan` or `implement` only; anything
else prints `<phase>`) come from the D2 entry, and `<base_sha>` from the
task record's top level; each stays a literal `<placeholder>` when absent.
The alternations `completed|failed|paused`, `approved|changes-requested`,
and the `<n>`/`<path>` tokens are printed literally for the worker to
edit; the `${CLAUDE_CONFIG_DIR:-$HOME/.claude}` and
`$(git rev-parse HEAD)` fragments are printed verbatim for the worker's
shell to expand. Tests compare these lines byte-for-byte.

RELEASE: exit 0, nothing on stderr, one JSON object on stdout:

```
{"systemMessage": "herdr-stop-gate: released without a completion record (<reason>); the orchestrator will see idle with no record for <task_id>"}
```

`systemMessage` is the documented all-events field that shows the text to
the human without feeding it back to the model (asserted from the hooks
reference, not demonstrated live; the tests check exit status and stdout
text only).

ALLOW (D1 miss or D3 accepted): exit 0, no output on either stream.

### D6. Fail-open and limits

Any exception, including a malformed payload, exits 0 silently, matching
`push_guard.py` and `herdr_worktree_guard.py`. Every filesystem read is
bounded: one glob for the index, at most three small JSON files, one glob
plus one linear read of the transcript. No network, no subprocess, no
write, no lock. The hook imports `herdr_orch_core` for
`state_root`, `read_index`, `valid_workspace_id`, `valid_task_id`, and
`contained` only, all read-only.

### D7. Registration

The template's `Stop` group keeps its single `*` matcher and lists, in this
order, `~/.claude/hooks/herdr_worker_status.py` then
`~/.claude/hooks/herdr_stop_gate.py`. Order is documentary (Claude Code runs
a group's hooks in parallel); the test asserts it so a later edit cannot
drop or reorder the pair unnoticed. The existing live drift check picks the
new command up automatically, so machines fail visibly until `update`
reconciles. The `Notification` group is untouched.

### D8. Documentation

`CLAUDE.md` gains one bullet in the symlink-targets list, after the
`herdr_worktree_guard.py` bullet, naming the hook, the two gated roles, the
cap, the read-only rule, and that it is registered in the template and
drift-checked. The hook's module docstring restates D1 to D6 in prose. No
skill or brief text changes (Non-goals).

## Known interactions

- `herdr_worker_status.py` appends a `stopped`/`review-stopped` hint and
  posts a wake on every Stop, including the refused ones, so the
  orchestrator may receive up to three wakes at the end of one phase. This
  is harmless by design: the orchestrator never advances status on a hint,
  only on the correlated record, and a check-in that finds the worker
  `working` again reports in-progress. A refused stop therefore costs one
  spurious wake, not a wrong transition.
- Mech and think headless runs are launched from the orchestrator's own
  session and inherit its `HERDR_WORKSPACE_ID`; that workspace never has an
  index, so they are inert under D1. The only way a headless run (or the
  orchestrator itself) gets gated is a leftover `workspaces/<ws>.json` for
  a reused workspace id. `run-mech` writes the record on the worker's
  behalf only after the process exits, so such a run would be refused
  twice and released, spending two extra turns. This is bounded by the cap
  and documented rather than special-cased, because the hook cannot tell
  a headless session from an interactive one; clearing stale indices stays
  the orchestrator's teardown job.
- A worker that is refused with `permission_mode` restrictions still gets
  the full command line in the refusal; running `emit-done` needs only
  `python3`, which every worker brief already allows.

## Acceptance criteria

- AC1 Worker without a record is refused: role `impl`, no `.done.json`,
  `stop_hook_active` false, exits 2 with the three-line stderr of D5
  whose first line starts `herdr-stop-gate: blocked (1 of 2)` and whose
  second line contains `emit-done --repo-slug <slug> --task-id <task_id>
  --workspace <ws>` with the fixture's values.
- AC2 Worker with an accepted record is allowed: `.done.json` for the same
  task and workspace with `ts` after the launch time exits 0 with empty
  stdout and stderr.
- AC3 Provenance and recency: a `.done.json` with `ts` before the launch
  time, or with another `workspace_id`, or with another `task_id`, is
  refused (exit 2). With an unknown launch time (no task record) a
  matching-provenance record is accepted. A later `mech` entry on the
  same workspace id does not move the launch time: a `.done.json` dated
  after the `impl` entry but before the `mech` entry is accepted.
- AC4 Role to file: role `review` is refused by a fresh `.done.json` and
  allowed by a fresh `.review.json`; role `impl` is refused by a fresh
  `.review.json` alone. The review refusal's second line contains
  `emit-review`.
- AC5 Non-workers are never refused: no `HERDR_ENV`, `HERDR_ENV=1` with no
  index for the workspace, an invalid workspace id, an index with role
  `mech`, and a non-`Stop` payload each exit 0 silently.
- AC6 Cap: with no record and `stop_hook_active` true, a transcript with
  one marker line is refused (`(2 of 2)`), two marker lines release with
  exit 0 and a stdout line containing `herdr-stop-gate: released` and
  `cap reached`, a missing transcript releases with `transcript
  unavailable`, and a present transcript with zero marker lines releases
  with `transcript evidence missing`. With `stop_hook_active` false and two marker lines the
  stop is still refused and its first line reads `(3 of 2)`: `<n>` is
  always `count + 1` and may exceed the cap in a later cycle.
- AC7 Read-only: a recursive listing with content hashes of the fixture
  config dir (state root and projects tree) is byte-identical before and
  after running the refuse, allow, and release scenarios.
- AC8 Fail-open: non-JSON stdin and a JSON array each exit 0 silently; an
  unreadable task record (a directory in its place) makes the launch time
  unknown, so a matching-provenance record is accepted (exit 0) while no
  record is still refused (exit 2).
- AC9 Registration: the template `Stop` group is exactly
  `[herdr_worker_status.py, herdr_stop_gate.py]` under one `*` matcher, and
  the sandboxed hooks suite passes with the new `gate:` labels present.
- AC10 Docs and scope: `CLAUDE.md` names `herdr_stop_gate.py`; the
  implementation diff from `682d9db` touches only
  `claude/hooks/herdr_stop_gate.py`, `claude/hooks/claude-hooks.test.sh`,
  `claude/settings.json.tmpl`, and `CLAUDE.md` (plus `docs/` and
  `claude/contracts/`); every added line in the hook, the test suite, and
  the template is ASCII (`CLAUDE.md` already carries non-ASCII dashes and
  is exempt); the parallel branch's files are untouched.

## Test plan

All in `claude/hooks/claude-hooks.test.sh`, appended before the summary
lines, POSIX sh, stdlib Python only, no network, every fixture under
`mktemp -d`:

- A `gate_fixture` helper builds a config dir with
  `herdr-orch/slug-x/workspaces/<ws>.json`, `herdr-orch/slug-x/tasks/PROJ-1.json`
  (one `workers[]` entry, `ts` `2026-09-06T12:00:00Z`), an optional
  `.done.json`/`.review.json` with a chosen `ts` and `workspace_id`, and an
  optional `projects/p/<session_id>.jsonl` with N marker lines.
- A `gate_case` helper runs the hook with `CLAUDE_CONFIG_DIR` pointed at the
  fixture, `HERDR_ENV`, `HERDR_WORKSPACE_ID`, and a payload, then asserts
  exit status, stderr first-line prefix or emptiness, and stdout content or
  emptiness.
- One case per AC1 to AC8 bullet, one static template check for AC9, and
  one read-only check for AC7 that hashes the fixture tree before and
  after.

Live verification (human, after merge and `update`): launch a worker
through the orchestrator, let it stop without emitting, confirm the refusal
text in the pane and the release on the third stop; then confirm a normal
`emit-done` stop is silent.

## Verification contract

`claude/contracts/td-2026-09-06-block-worker-stops-until-the-completion-record-exi-contract.json`,
committed with the plan. Every command runs from the worktree root, builds
its own fixture under `mktemp -d`, writes nothing outside it, and needs no
network.

| Acceptance criterion | Contract command(s) |
|---|---|
| AC1 refused without record, message shape | `blocks-worker-without-record` |
| AC2 allowed with fresh record, silent | `allows-worker-with-fresh-record` |
| AC3 stale, foreign workspace, foreign task, unknown launch, mech entry ignored | `blocks-stale-record`, `blocks-foreign-workspace-record`, `blocks-foreign-task-record`, `allows-record-when-launch-unknown`, `launch-time-ignores-mech-entry` |
| AC4 role to file | `review-role-uses-review-record`, `impl-role-ignores-review-record` |
| AC5 non-workers allowed | `allows-non-worker-sessions` |
| AC6 cap | `cap-second-block`, `cap-release-after-two`, `cap-release-without-transcript`, `cap-release-on-zero-markers`, `cap-fresh-cycle-blocks-again` |
| AC7 read-only | `state-root-untouched` |
| AC8 fail-open | `fails-open-on-bad-input` |
| AC9 registration and suite | `template-registers-gate-after-status-hook`, `hooks-suite-sandboxed`, `hooks-suite-has-gate-labels`, `orch-suite-unchanged` |
| AC10 docs and scope | `claude-md-documents-gate`, `changed-files-within-scope`, `forbidden-files-untouched`, `ascii-added-lines`, `hook-compiles-and-executable` |

## Follow-ups (not filed here; for the orchestrator or human to route)

- Once `herdr_orch_core.py` reopens: add `stop-unblocked` to the events
  vocabulary and let a hook append it, restoring the brief's marker.
- Once the orchestration skill reopens: mention the gate in
  `references/brief-template.md` ("the Stop hook refuses your stop until
  the record exists") and in `event-schema.md` (refused stops still emit
  `stopped` hints).
- If the spurious wakes from refused stops prove noisy, have
  `herdr_worker_status.py` skip the wake when the gate is about to refuse;
  that needs a shared read-only signal and is a separate design.
