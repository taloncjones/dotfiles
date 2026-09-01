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

Wake the orchestrator by push, not poll, using only documented Claude Code
messaging surfaces (the inbox socket and its env vars, the `auth` line, the
`--name` flag, `ListAgents`/`SendMessage` with `notify_when_idle`; the
injected message shape is the documented `--input-format stream-json` user
message), while keeping `events.jsonl` as the audit trail and the `watch`
subcommand as a fallback. Because the push layer depends on a platform wire
shape, it is never the only wake path: the two other layers stay armed and
the live acceptance test (criterion 10) is the compatibility check on every
Claude Code upgrade. No new daemons, no new state files; two optional fields
(`owner.json.messaging_socket`, `workers[].peer_name`).

### Version and platform matrix

| Capability | Requires | Degradation when absent |
| --- | --- | --- |
| Inbox socket, `CLAUDE_CODE_MESSAGING_SOCKET` in hooks (layer 1 receive side) | Claude Code >= 2.1.224, macOS/Linux/WSL2 (native Windows needs the auth line and is out of scope) | `messaging_socket` stored `null`; layer 1 skipped |
| Hook socket client (layer 1 send side) | Python 3 stdlib on the worker; no Claude Code version requirement | n/a |
| `notify_when_idle` (layer 2) | >= 2.1.236 in both sessions, main conversation only, same machine | `SendMessage` lacks the input or refuses; skip, `peer_name` still recorded |
| `--name` (layer 2 discovery) | confirmed on 2.1.257; unverified earlier | worker keeps an auto-derived name; discovery finds no candidate; `peer_name: null` |
| Everything | any | layer 3 watch at default cadence; today's behavior |

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
notice) are expected and harmless.

**No lost wake (normative).** Every wake the orchestrator observes must be
followed by authoritative reads (the status verb, live herdr polls, git)
that BEGAN after that wake arrived. Cross-session messages are read between
tool calls, so a wake can land in the middle of a check-in after its reads
completed. Rule: when a wake message appears in the transcript during a
check-in turn, the orchestrator runs one more check-in before ending the
turn (at most one extra pass per turn; a wake landing during that extra pass
is covered by it because its reads start after the wake). A wake arriving
while the orchestrator is idle starts a new turn, which runs preflight and
a check-in as today.

**Launch gap (existing, unchanged).** A worker that stops between
`agent prompt` and the section-2 step-7 index publication has no index, so
its hook appends nothing and posts nothing. This gap exists today and is
covered today: the worker's `done.json`, if any, is a watched file (layer 3
signals it), and the next check-in polls live herdr state regardless of
events. This spec adds no new mechanism for the gap and adds a live
acceptance case (criterion 11) that proves the cover.

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

**PID source.** The socket basename is the Claude Code process id (S2), and
that process is the only authority for "the orchestrator". When
`--messaging-socket` passes shape validation, `claim-owner` stores its
basename pid as `owner.json.pid` and ignores `--pid` for that field (a
`--pid` that differs is reported in the same `[WARNING]` line, since a
Bash-tool `$PPID` is not reliably the Claude process). When no valid socket
is given, `pid` is `--pid` as today. `refresh-owner` with a valid socket whose
basename pid differs from the stored `pid` stores `null` and warns: the
owner's Claude process cannot change without a new claim.

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
6. Ownership: the socket's `lstat` uid and its directory's `lstat` uid both
   equal `os.geteuid()`, and the directory mode has no group/other bits
   (0700), matching how Claude Code creates `/tmp/cc-socks` (S2). This is
   what makes the Safety claim "owned by this user" true rather than
   asserted.
7. Connect with a 1s timeout, send exactly one line, close. Total wall budget
   2s. `ConnectionRefusedError`, `FileNotFoundError`, timeout, and any
   `OSError` are swallowed. No retry.

PID reuse after an orchestrator crash: guards 2 and 7 bound it. A crashed
orchestrator stops refreshing, so within 900s the heartbeat goes stale
(guard 2) and the socket file is gone (guard 5, then 7). Inside that window
a reused pid would need a new Claude session of the same user bound at the
identical path; the worst case is that session receives one closed-vocabulary
wake line it will ignore. Accepted; documented in Safety.

Wire: no auth line (the worker's token authenticates only to the worker's own
inbox; the orchestrator's token is not available to the hook and must not
be). One line:

```json
{"type":"user","message":{"role":"user","content":"herdr-wake v=1 repo=<repo_slug> workspace=<ws> event=<stopped|blocked|review-stopped> ts=<unix epoch seconds, int>"}}
```

Content is a closed vocabulary; `repo_slug` and `ws` are already validated
by the existing `valid_repo_slug`/`valid_workspace_id` before the hook gets
this far. `ts` exists only so two wakes from the same worker are never
byte-identical: the receiver "drops identical repeats arriving within a
short window" (docs, Limitations), and a second Stop within that window
must still wake. The orchestrator never parses any of it (see Safety).

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

1. Discovery (bounded, fails closed): call `ListAgents`; candidates are the
   local-session rows whose name equals `<agent-name>` or matches
   `<agent-name>-<suffix>` where `<suffix>` is what Claude Code appends on a
   collision (Claude Code keeps a taken name with its holder and renames the
   newcomer to a variant). If there is no candidate, call `ListAgents` once
   more after the `agent prompt` wait completes (the two calls are at least
   the prompt wait apart, no sleep). Exactly one candidate -> that is
   `peer_name`. Zero or more than one candidate -> `peer_name: null`, layers
   1 and 3 only, and one status line saying so. Never pick among several: a
   stale variant from an earlier worker of the same task would receive the
   subscription instead of the live one.
2. Records `peer_name` (name or `null`) in the new `workers[]` entry via the
   existing fenced `write-task` (schema addition below).
3. If `peer_name` is non-null, subscribes:
   `SendMessage(to=<peer_name>, notify_when_idle=true)` with no `message`.
   This costs the worker nothing and is one-shot.

**Re-subscription eligibility (normative).** After every check-in (any
wake source or a human prompt), for each task whose latest `workers[]`
entry has a non-null `peer_name`: re-subscribe only if the live herdr
agent state read by that check-in is `working` or `blocked`. Never
re-subscribe to a worker that is `idle`, `done`, `unknown`, or absent:
the platform sends the notice immediately for an already idle session,
which would wake the orchestrator, whose check-in would re-subscribe, and
so on. The check-in that saw `idle`/`done` has already handled that worker
(completion correlation or phase advance); the next launch subscribes to
the next worker. Duplicate subscriptions do not stack: a second
`notify_when_idle` from the same requester to the same target replaces the
first (docs: one notice per subscription; binary: the receiver replaces an
existing subscriber entry for the same requester and target), so the
invariant "at most one outstanding subscription per live worker" holds
without bookkeeping. Subscriptions die with the orchestrator session and
are re-armed at the next preflight for every `working`/`blocked` worker,
like the ownership heartbeat and the watch. A `SendMessage` that fails or
reports "no subscription was made" is logged in the status line and
ignored; layers 1 and 3 cover that worker.

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
  guard 3; the basename pid becomes `owner.json.pid` on claim and must equal
  the stored `pid` on refresh, see "PID source") and print one `[WARNING]`
  line to stderr for an invalid non-empty value; ownership still succeeds. A
  non-owner (`BUSY`) never writes anything, as today.
- Step 6 gains the cadence rule (layer 3) and the re-subscribe rule (layer
  2). The Monitor remains "at most one live watch per repo per session".

### Permission classes and settings

Normative matrix for what reaches the orchestrator's Claude, with no
`crossSessionInbound` set on the receiver (S8, docs "Control inbound
messages"). "Prompting" = default, auto, acceptEdits, dontAsk; "bypass" =
bypassPermissions (and plan mode where bypass is available).

| Sender -> orchestrator | Orchestrator prompting (auto) | Orchestrator bypass |
| --- | --- | --- |
| Hook post (asserts no class) | delivered | held; dialog, dropped after `dialogExpiry` (5 min) |
| Idle notice from an auto worker | delivered | shown to the user only, not to Claude |
| Idle notice from a bypass worker | held | delivered |
| `SendMessage` from an auto worker (not used by this spec) | delivered | held |

Every other section refers to this table.

- Workers stay `--permission-mode auto` (already mandatory for the section-8
  classifier reason). Under the table an auto worker's posts and notices are
  delivered to an auto orchestrator. The rule is restated, not changed.
- The brief requires the inbound policy to be set explicitly rather than
  relying on the default. This spec satisfies that per session, not per
  account: SKILL.md documents the orchestrator launch line as
  `claude --permission-mode auto --settings '{"crossSessionInbound":"accept"}'`
  (the `--settings` JSON form, S7), and the same `--settings` value is the
  documented remedy for an orchestrator someone runs in bypass mode (then
  the bypass column collapses to "delivered" for every row). The
  orchestrator is safe to run with `accept` because it treats every inbound
  message as wake-only (Safety). `settings.json.tmpl` is not changed: a
  template `accept` would apply to every session of the account, including
  ones that are not wake-only.
- Preflight cannot read its own permission class or inbound policy from
  Bash, so nothing is asserted at runtime; the launch line and the matrix
  are the contract, and criterion 10 (live) is the check.
- `-p` sessions: none of the orchestrator's workers are `-p`. The 5-minute
  held-message drop (S8) is noted in SKILL.md as the reason a `-p`
  orchestrator without `accept` is unsupported.
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
(`post_wake`); the wake is not an event, is written to no herdr file
(`events.jsonl` or otherwise), and carries no authority. Claude Code itself
persists the delivered line in the orchestrator's session transcript like
any other message; that is platform behavior, outside `STATE_ROOT`, and the
line contains only the already-public `repo_slug`, workspace id, event name
and timestamp. `$CORE watch` is unchanged.

### Fallback and degradation matrix

| Condition | Layer 1 (push) | Layer 2 (idle notice) | Layer 3 (watch) | Net effect |
| --- | --- | --- | --- | --- |
| Normal (2.1.257, auto orchestrator, auto workers) | delivered in <1s | delivered on idle/exit | 60s/300s safety net | push wake |
| Orchestrator CLI without messaging | `messaging_socket` null, skip | `SendMessage` lacks the input; skip | default cadence | today's behavior |
| Worker CLI without messaging or `--bare` | hook still posts (needs only a socket client) or no hook at all | no session row; `peer_name` null | catches it | push or watch wake |
| Orchestrator restarted (new pid) | until the new claim: old path still matches the old `pid`, so guards 5/7 (socket gone, connect refused) skip it; after the new claim: new path and `pid`, delivered | re-armed at preflight | re-armed at preflight | window until the new claim covered by watch |
| Orchestrator crashed, pid reused within 900s | heartbeat fresh, guards 5/6/7 decide; worst case one ignored wake line to another session of this user | n/a | catches it | watch wake |
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
  may attempt a connect to the path it names. The path and ownership guards
  (3, 5, 6) bound what a tampered `owner.json` could make the hook do to
  "connect to one canonical cc-socks socket owned by this uid and send one
  fixed line". PID reuse within the heartbeat window can at worst deliver
  that line to another Claude session of the same user, which ignores it.

## Acceptance criteria

Core and hook (automated, `herdr-orch.test.sh`):

1. `claim-owner --messaging-socket <canonical dir>/<n>.sock --pid <n>` stores
   the path and `pid` `<n>`; with `--pid <m>` (m != n) it stores the path,
   `pid` `<n>`, and prints one `[WARNING]` naming both. A foreign dir, a
   relative path, a basename that is not `<digits>.sock`, or a path
   containing a symlink component stores `null`, prints one `[WARNING]`,
   and still returns a fence. An empty value stores `null` silently and
   `pid` = `--pid`. The allowed-dir list is injectable for tests (a
   canonical-shaped temp dir), since `/tmp/cc-socks` belongs to live
   sessions.
2. `refresh-owner --messaging-socket ""` clears a stored path;
   `refresh-owner` without the flag leaves it untouched; `refresh-owner`
   with a valid path whose basename pid differs from the stored `pid` stores
   `null` and warns.
3. `post_wake` against a fake `AF_UNIX` server at an injected canonical path
   sends exactly one line that parses as the wire shape, whose `content`
   matches `^herdr-wake v=1 repo=\S+ workspace=\S+ event=(stopped|blocked|review-stopped) ts=\d+$`
   with the expected repo/workspace/event, and returns `"sent"`. Two
   consecutive calls one second apart produce different `content`.
4. `post_wake` returns a distinct non-`"sent"` reason and sends nothing for
   each of: missing `owner.json`; unparseable `owner.json`; `messaging_socket`
   null, non-string, or empty; `heartbeat_ts` missing, non-numeric, NaN,
   infinite, or older than 900s (a future timestamp is treated as fresh);
   `pid` missing or non-integer; dir not canonical; basename pid != `pid`;
   own socket; path missing; path exists but is not a socket (regular file,
   symlink to a socket); socket or dir owned by another uid or dir mode with
   group/other bits (tested by monkeypatching the stat results); connect
   refused (socket file with no listener).
5. `post_wake` against a server that accepts but never reads returns within
   2.5s (measured) and does not raise.
6. The hook, end to end (existing hook test style): with a fake server
   registered in `owner.json`, a Stop payload appends `stopped` to
   `events.jsonl` AND the server receives one wake line whose `event` is
   `stopped`; with no `messaging_socket` the event is still appended and the
   hook exits 0; with `CLAUDE_CODE_MESSAGING_SOCKET` set to the same path
   the event is appended and nothing is posted. Notification payloads of a
   blocking type post `blocked`; non-blocking types append nothing and post
   nothing. A hook run with the fake server absent exits 0 within 2.5s.

Contract (`herdr-orch-contract.test.sh`, fake-CLI walkthrough plus
SKILL.md text checks; layer 2 is tool-call prose and is checked as text):

7. The walkthrough passes `--messaging-socket` on claim and refresh and the
   hook step delivers one wake line to the fake server.
8. SKILL.md text checks: the model-launch line contains the literal
   `--name <agent-name>`; the orchestrator launch line contains the literal
   `--settings '{"crossSessionInbound":"accept"}'`; the section-1 watch
   arming names both `--interval 60 --debounce-secs 300` and the default
   cadence; the re-subscription rule names `working` and `blocked` as the
   only eligible states; the Safety section names cross-session messages as
   wake-only.

Suites: all three (`herdr-orch.test.sh`, `herdr-orch-contract.test.sh`,
`claude-hooks.test.sh`) must pass with zero failures.

Docs (human-verify by reading the diff):

9. SKILL.md sections 1, 2/8, 4, Safety and the two reference files carry the
   additions above; no unrelated text is renumbered or rewritten (the sibling
   verification-contracts task edits other sections of the same file).

Live (human-verify, one herdr session, after implementation; these are the
only checks of layer 2's runtime behavior and of the platform wire shape):

10. Kick off a task; the orchestrator's check-in fires from a
    `<cross-session-message>` wake no later than 5s after the worker's Stop
    (compare the hook's `ts` with the check-in turn start), with the watch
    armed at the relaxed cadence and `events.jsonl` carrying the matching
    `stopped` line. `workers[].peer_name` equals the worker's `ListAgents`
    name. Kill the worker process (`kill <pid>`) mid-task: an idle notice
    "has exited" wakes the orchestrator and the check-in reports `abandoned`
    per the existing section-4 table. Let a worker go idle and confirm no
    second wake follows the check-in (no re-subscribe loop).
11. Launch-gap cover: kick off a task whose brief makes the worker `emit-done`
    and stop immediately; even if the Stop precedes the index publication,
    the next check-in (watch signal on the new `done.json`, or the next
    turn) correlates completion. No completion is lost.

## Test baseline (branch base 53c3760)

`herdr-orch.test.sh` 53 passed, `herdr-orch-contract.test.sh` 15 passed,
`claude-hooks.test.sh` 42 passed, all 0 failed.

## Open questions resolved in this spec

- Primary transport: hook push (covers `blocked`, needs no bookkeeping) with
  the idle subscription as exit detector, not the reverse.
- No `peer_name` for the orchestrator in `owner.json`: nothing addresses it
  by name.
- No hook-side debounce: worker turns are long, and the `ts` field keeps
  distinct Stops from being deduped by the receiver. Revisit only if wake
  cost shows up.
- No template change for `crossSessionInbound`; the explicit setting the
  brief asks for is carried on the documented orchestrator launch line.
- Cross-account visibility: the brief asked for a live check that
  `~/.claude` and `~/.claude-work` sessions see each other. The read-only
  spike answers it structurally (S4: per-config-dir registry, so they do
  not); a live confirmation needs a work-account session started for the
  purpose, which is not read-only and was not done. The design does not
  depend on the answer (orchestrator and workers share a config dir), so
  this is recorded as a scoped-down prerequisite, flagged for the human,
  not a blocker.
