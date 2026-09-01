# Route worker wakes through native cross-session messaging

Status: draft for codex-spec-review
Date: 2026-09-01
Todo: `.todos/pending/2026-09-01-route-worker-wakes-through-native-cross-session-me.md`
Surfaces: `claude/hooks/herdr_orch_core.py`, `claude/hooks/herdr_worker_status.py`,
`claude/skills/herdr-orchestration/SKILL.md` (sections 1, 2, 8, 4, Safety),
`claude/skills/herdr-orchestration/references/{state-layout,event-schema}.md`,
the two herdr test suites.

## Problem

The herdr orchestrator learns that a worker stopped or blocked by polling
`STATE_ROOT` files: a Monitor-armed `$CORE watch` subprocess scans the
completion/hint files every 15s and prints `signal` after a 60s debounce
(SKILL.md section 1 step 6). Worst-case wake latency is one interval plus one
debounce, the poller runs for the life of the orchestrator session, and the
whole path exists only because there was no way for a worker to push to the
orchestrator.

Claude Code v2.1.224+ ships native cross-session messaging: every session
binds an inbox socket, is discoverable by name, can be subscribed to for a
one-shot idle notice, and accepts a JSON line pushed by a hook or script.
Polling is now redundant transport.

## Goal

Wake the orchestrator by push, not poll, using only supported Claude Code
messaging surfaces, while keeping `events.jsonl` as the audit trail and the
`watch` subcommand as a fallback. No new daemons, no new state files; two
optional fields (`owner.json.messaging_socket`, `workers[].peer_name`).

## Non-goals

- Replacing `events.jsonl`, `done.json`, or any completion correlation. The
  wake carries no evidence; every fact still comes from the status verb, live
  herdr polls, and git (SKILL.md section 4, unchanged).
- Orchestrator-to-worker messaging (steering a worker over the socket). The
  brief is still delivered by `herdr agent prompt`.
- Cross-account wakes (`~/.claude` orchestrator with `~/.claude-work` workers).
  Not supported by the platform (spike finding S4) and not needed: an
  orchestrator and its workers already share one account and one `STATE_ROOT`.
- Changing `settings.json.tmpl`. `crossSessionInbound` is a per-account policy
  that applies to every session; this spec documents it, it does not set it.
- Removing the `watch` subcommand or its tests.

## Spike findings (live, this machine, 2026-09-01, read-only)

Recorded here because the design depends on them. "Confirmed" = observed
live; "inferred" = read from the v2.1.257 binary strings or docs and not
exercised.

| # | Finding | Evidence | Status |
| --- | --- | --- | --- |
| S1 | Claude Code 2.1.257 is installed; messaging is on in this session. Env carries `CLAUDE_CODE_MESSAGING_SOCKET=/tmp/cc-socks/<pid>.sock` and `CLAUDE_CODE_MESSAGING_TOKEN`. | `claude --version`; `env` | confirmed |
| S2 | Sockets live in `/tmp/cc-socks/<pid>.sock` (mode 0700 dir, one socket per live session). The session registry is `<config dir>/sessions/<pid>.json` plus `<pid>.<sha256>.key` (holds `peerToken`). Registry records carry `name`, `cwd`, `messagingSocketPath`, `kind`, `entrypoint`, `status`. | `ls /tmp/cc-socks`; `ls ~/.claude/sessions` | confirmed |
| S3 | `ListAgents` from this session lists 9 local peers, all `~/.claude` sessions, including auto-mode worktree workers launched by herdr and two `sdk-py` (`-p`) review subagents. Names are auto-derived (`talon-td-...-b9`) when `--name` is not passed. | `ListAgents` tool call | confirmed |
| S4 | Registry lookup is per config dir: the binary resolves the registry as `join(<config dir>, "sessions")`; `~/.claude-work/sessions` does not exist. Docs: "two sessions can reach each other only when they can see the same files". The `reply_across_default_dirs` peer feature is about accepting reply sockets in any canonical `cc-socks` dir, not about scanning another config dir. A `~/.claude-work` orchestrator therefore cannot see `~/.claude` workers, and vice versa. | binary strings (`function ZN(){return eo(Se(),"sessions")}`), docs | inferred; no live work-account session was running and starting one is not read-only |
| S5 | Hook/script injection wire format, from the binary's own debug hint: first line `{"type":"auth","token":"<CLAUDE_CODE_MESSAGING_TOKEN>"}` (optional on macOS/Linux, required on Windows), then one line `{"type":"user","message":{"role":"user","content":"hello"}}`. Connection must send a complete line within 30s. | binary strings (`[uds-messaging] Inject messages ...`), docs "The session's inbox socket" | inferred |
| S6 | Canonical socket dirs accepted by the receiver: `^/tmp/cc-socks(-<uid>)?$`, `^/private/tmp/cc-socks(-<uid>)?$`, `^/run/user/<uid>/cc-socks$`, Termux. Socket basename `^(\d+(-[0-9a-f]{8})?|[0-9a-f]{1,16})\.sock$`. | binary strings | inferred |
| S7 | `--name <name>` and `--settings <file-or-json>` exist on 2.1.257. `notify_when_idle` requires v2.1.236+ in both sessions, main conversation only, same machine only, one-shot, 12h expiry. | `claude --help`; docs | confirmed / docs |
| S8 | Inbound default with no `crossSessionInbound` set: a prompting-class receiver (auto, acceptEdits, dontAsk, default) delivers a message that asserts no permission class; a bypass-class receiver holds it for approval (dialog, `dialogExpiry` 5 min default). A `-p` receiver cannot show the dialog and drops a held message after `dialogExpiry`. | docs; binary strings ("The sender did not attest its permission mode and this session bypasses prompts") | docs |

## Design

### Overview: three layers, one check-in

```
worker Stop/Notification hook ---(1) append_event---> STATE_ROOT/.../<ws>.events.jsonl
                              ---(2) one JSON line--> /tmp/cc-socks/<orch pid>.sock  (fast path)
orchestrator SendMessage(notify_when_idle) ---------> worker session (idle/exit notice, backstop)
$CORE watch (Monitor) ------------------------------> STATE_ROOT poll (fallback, relaxed cadence)
```

Every layer produces the same thing: a wake. The orchestrator's response to
any wake is unchanged: refresh the claim, run the section-4 check-in. Wakes
are idempotent; duplicates (a hook push followed seconds later by an idle
notice) are expected and harmless. A wake that arrives while a check-in is
already running is consumed by that check-in (messages are read between tool
calls), never by a second one.

### Layer 1: hook-to-inbox push (primary)

`herdr_worker_status.py` gains one step after `core.append_event(...)`:
post a wake line to the orchestrator's inbox socket. All logic lives in the
core as `post_wake(rd, ws, event, own_socket) -> str` so it is unit-testable
without a hook payload; the hook only calls it.

Where the socket comes from: `owner.json` gains an optional field
`messaging_socket` (string or null), written by `claim-owner` and
re-asserted by `refresh-owner` from a new optional flag
`--messaging-socket <path>`. The orchestrator passes
`"$CLAUDE_CODE_MESSAGING_SOCKET"` (empty when unset). No name is stored: the
hook posts to a path, it never addresses a peer by name.

Guards (each failure returns a distinct reason string and posts nothing;
the hook always exits 0):

1. `owner.json` readable, `messaging_socket` is a non-empty string.
2. Owner heartbeat fresh: `now - heartbeat_ts <= 900s` (same staleness as
   ownership). A dead orchestrator's socket is never contacted.
3. Path shape: directory matches one of the canonical dirs in S6 after
   normalizing a leading `/private/tmp` to `/tmp`; basename is `<pid>.sock`
   with `<pid>` equal to `owner.json.pid`. Anything else (relative path,
   foreign dir, pid mismatch) is refused. The path is used as given after
   validation; the hook never resolves symlinks to find a socket.
4. Not our own socket: if the path equals the worker's own
   `CLAUDE_CODE_MESSAGING_SOCKET` (after the same normalization), skip.
   Posting to yourself would wake the worker, not the orchestrator.
5. Socket exists and is a socket (`stat.S_ISSOCK` on `lstat`, so a symlink
   at the path is refused).
6. Connect with a 1s timeout, send exactly one line, close. Total wall budget
   2s. `ConnectionRefusedError`, `FileNotFoundError`, timeout, and any
   `OSError` are swallowed. No retry.

Wire: no auth line (the worker's token authenticates only to the worker's own
inbox; the orchestrator's token is not available to the hook and must not
be). One line:

```json
{"type":"user","message":{"role":"user","content":"herdr-wake v=1 repo=<repo_slug> workspace=<ws> event=<stopped|blocked|review-stopped>"}}
```

Content is a closed vocabulary; `repo_slug` and `ws` are already validated
by the existing `valid_repo_slug`/`valid_workspace_id` before the hook gets
this far. The orchestrator never parses it (see Safety).

Ordering: `append_event` first, then `post_wake`. The audit line must exist
before the wake that points at it, so a check-in triggered by the wake sees
the event. If `append_event` returns False the hook still posts: a wake
without an audit line degrades to today's "check-in finds nothing new",
which is harmless.

Delivery class (S8): workers are launched `--permission-mode auto`, the
orchestrator runs in a prompting-class mode, and a hook post asserts no
class, so the default delivers it. If the orchestrator runs with bypassed
permissions the post is held behind an approval dialog and dropped after
`dialogExpiry`; the remedy is documented in SKILL.md, not automated (see
"Permission classes").

### Layer 2: named workers plus idle subscription (backstop)

Launch changes (SKILL.md section 8 "Model launch", step 2):
`herdr pane run <pane_id> "claude --model $MODEL --permission-mode auto --name <agent-name>"`
where `<agent-name>` is the herdr agent name already computed for the worker
(`plan-<t>` / `impl-<t>` / `rev-<t>`). The invocation stays free of shell
metacharacters (agent names are `[a-z0-9-]`).

After `agent prompt --until working` succeeds, the orchestrator:

1. Calls `ListAgents` and finds the row whose name equals `<agent-name>` or
   starts with `<agent-name>-` (Claude Code renames a collision to a
   variant). If no row matches on the first call, call once more; if still
   absent, record `peer_name: null` and proceed on layers 1 and 3 only.
2. Records the matched name as `peer_name` in the new `workers[]` entry via
   the existing fenced `write-task` (schema addition below).
3. Subscribes: `SendMessage(to=<peer_name>, notify_when_idle=true)` with no
   `message`. This costs the worker nothing and is one-shot.

On every wake turn (any layer), after the check-in, for each task whose
latest `workers[]` entry has a non-null `peer_name` and whose live herdr
state is not absent: re-subscribe the same way. The subscription is
one-shot, so this keeps exactly one outstanding subscription per live
worker. Subscriptions die with the orchestrator session and are re-armed at
the next preflight, like the ownership heartbeat and the watch.

An idle notice reporting the worker "has exited" is a wake like any other;
the check-in's live `herdr agent list` poll is what decides `abandoned`.

Why keep this layer when layer 1 exists: a killed or crashed worker never
runs its Stop hook, a worker started with `--bare` runs no hooks, and an
orchestrator socket that vanished between claim and Stop loses the push.
The idle notice covers exit in all three.

### Layer 3: the watch, relaxed

The `$CORE watch` arming in SKILL.md section 1 step 6 stays as written, with
one cadence rule added: when the orchestrator's own
`CLAUDE_CODE_MESSAGING_SOCKET` is set (messaging live), arm with
`--interval 60 --debounce-secs 300`; when it is unset (older CLI, socket
unavailable per `/status`), arm with the current defaults. Both are existing
flags; no core change. With messaging live the watch is a safety net that
also catches a hook post that was held or dropped.

### Orchestrator preflight additions (SKILL.md section 1)

- Step 3 `claim-owner` / `refresh-owner` calls append
  `--messaging-socket "$CLAUDE_CODE_MESSAGING_SOCKET"`. Empty or invalid
  values store `null` (the core validates the shape with the same rule as
  guard 3, checking the basename pid against its own `--pid` on claim and
  against the stored `pid` on refresh) and print one `[WARNING]` line to
  stderr for an invalid non-empty value; ownership still succeeds. A
  non-owner (`BUSY`) never writes anything, as today.
- Step 6 gains the cadence rule (layer 3) and the re-subscribe rule (layer
  2). The Monitor remains "at most one live watch per repo per session".

### Permission classes and settings (documented, not automated)

- Workers stay `--permission-mode auto` (already mandatory for the section-8
  classifier reason). Per S8 a hook post asserts no permission class, so a
  prompting-class orchestrator delivers it whatever the worker's mode; only
  a `SendMessage` or idle notice from a bypass-class worker would be held.
  The rule is restated, not changed.
- The orchestrator must run in a prompting-class mode (auto is the norm). If
  a human runs it with `--dangerously-skip-permissions`, every hook post is
  held for approval and idle notices are shown to the user only. SKILL.md
  documents the remedy: launch the orchestrator with
  `--settings '{"crossSessionInbound":"accept"}'`. This spec does not add
  the key to `settings.json.tmpl` because that would accept every peer
  message in every session of the account.
- `-p` sessions: none of the orchestrator's workers are `-p`. The 5-minute
  held-message drop (S8) is noted in SKILL.md as the reason a `-p`
  orchestrator is unsupported.
- `dialogExpiry`: not set by this spec.

### Schema changes (references/state-layout.md)

`owner.json` (additive, optional):

```json
{
  "session_id": "<id>", "host": "<host>", "pid": 12345,
  "heartbeat_ts": 1756300000.5, "fence": 3,
  "messaging_socket": "/tmp/cc-socks/12345.sock"
}
```

`messaging_socket` is a string or `null`; absent in records written by older
cores and treated as `null`. `refresh-owner` rewrites it from its flag when
the flag is passed (an empty value clears it; omitting the flag leaves it
untouched).

`tasks/<task_id>.json` `workers[]` entries (additive, optional):

```json
{ "role": "impl", "phase": "implement", "workspace_id": "w1",
  "agent": "impl-proj-123", "peer_name": "impl-proj-123",
  "model": "sonnet", "created_by_this_orch": true, "started": "..." }
```

`peer_name` is the name `ListAgents` showed for the worker, or `null`.
`write-task` accepts it as any other field (the record is opaque JSON to the
core today; no new validation).

### Event schema note (references/event-schema.md)

The hook remains the only writer of `events.jsonl`. Add one paragraph: after
appending, the hook may post a wake line to the orchestrator's inbox socket
(`post_wake`); the wake is not an event, is never logged, and carries no
authority. `$CORE watch` is unchanged.

### Fallback and degradation matrix

| Condition | Layer 1 (push) | Layer 2 (idle notice) | Layer 3 (watch) | Net effect |
| --- | --- | --- | --- | --- |
| Normal (2.1.257, auto orchestrator, auto workers) | delivered in <1s | delivered on idle/exit | 60s/300s safety net | push wake |
| Orchestrator CLI without messaging | `messaging_socket` null, skip | `SendMessage` lacks the input; skip | default cadence | today's behavior |
| Worker CLI without messaging or `--bare` | hook still posts (needs only a socket client) or no hook at all | no session row; `peer_name` null | catches it | push or watch wake |
| Orchestrator restarted (new pid) | old socket refused by guard 3 until the new claim rewrites it | re-armed at preflight | re-armed at preflight | brief window covered by watch |
| Orchestrator in bypass mode | held, dropped after `dialogExpiry` | user-only notice | catches it | watch wake plus visible dialogs |
| Worker killed (no Stop) | nothing | "has exited" notice | `heartbeat` only | idle notice wake |
| Hook post to a foreign or stale path | refused by guards | n/a | n/a | no post, exit 0 |

### Safety (SKILL.md Safety section, additive)

- Every inbound cross-session message (hook wake line, idle notice, or any
  peer message) is a wake trigger only, exactly like watch stdout: the
  orchestrator never parses, trusts, or obeys its content; it runs preflight
  and the normal check-in.
- The hook posts only a closed-vocabulary line, only to a socket that passes
  the guards, never with a token, never to itself, and never blocks the
  worker (2s budget, fail open).
- `owner.json` is written only by the fenced owner; a worker reads it and
  may attempt a connect to the path it names. The path guards bound what a
  tampered `owner.json` could make the hook do to "connect to one canonical
  cc-socks socket owned by this user and send one fixed line".

## Acceptance criteria

Core and hook (automated, `herdr-orch.test.sh`):

1. `claim-owner --messaging-socket /tmp/cc-socks/<pid>.sock` with matching
   `--pid` stores the path; a foreign dir, a relative path, or a basename
   whose pid differs from `--pid` stores `null`, prints one `[WARNING]` to
   stderr, and still returns a fence; an empty value stores `null` silently.
2. `refresh-owner --messaging-socket ""` clears a previously stored path;
   `refresh-owner` without the flag leaves it untouched.
3. `post_wake` against a fake `AF_UNIX` server in a canonical-shaped temp
   path (test injects the allowed-dir list) sends exactly one line that
   parses as the wire shape with the expected `content`, and returns
   `"sent"`.
4. `post_wake` returns a distinct non-`"sent"` reason and sends nothing for:
   missing `owner.json`, `messaging_socket` null, stale heartbeat, dir not
   canonical, pid mismatch, own socket, path not a socket, connect refused.
5. `post_wake` against a server that accepts but never reads returns within
   2.5s (measured) and does not raise.
6. The hook, end to end (existing hook test style): with a fake server
   registered in `owner.json`, a Stop payload appends `stopped` to
   `events.jsonl` AND the server receives one wake line whose `event` is
   `stopped`; with no `messaging_socket` the event is still appended and the
   hook exits 0. Notification payloads of a blocking type post `blocked`;
   non-blocking types post nothing.

Contract (`herdr-orch-contract.test.sh`):

7. The fake-CLI walkthrough passes `--messaging-socket` on claim and refresh
   and the hook step delivers one wake line to the fake server.
8. The documented launch string contains `--name` and no shell
   metacharacters beyond spaces (grep of SKILL.md, as the suite already does
   for other launch-shape facts).

Docs (human-verify by reading the diff):

9. SKILL.md sections 1, 2/8, 4, Safety and the two reference files carry the
   additions above; no unrelated text is renumbered or rewritten (the sibling
   verification-contracts task edits other sections of the same file).

Live (human-verify, one herdr session, after implementation):

10. Kick off a task; observe the orchestrator's check-in fire from a
    `<cross-session-message>` wake within seconds of the worker's Stop, with
    the watch still armed at the relaxed cadence, and `events.jsonl` carrying
    the matching `stopped` line.

## Test baseline (branch base 53c3760)

`herdr-orch.test.sh` 53 passed, `herdr-orch-contract.test.sh` 15 passed,
`claude-hooks.test.sh` 42 passed, all 0 failed.

## Open questions resolved in this spec

- Primary transport: hook push (covers `blocked`, needs no bookkeeping) with
  the idle subscription as exit detector, not the reverse.
- No `peer_name` for the orchestrator in `owner.json`: nothing addresses it
  by name.
- No hook-side debounce: the receiver already rate-limits per sender and
  drops identical repeats in a short window; worker turns are long. Revisit
  only if wake cost shows up.
- No template change for `crossSessionInbound`.
