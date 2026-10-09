# Director launch, lease adoption and watch details (SKILL.md section 1)

## Why an unarmed pane fails (section 1 step 2)

An unarmed pane predates the `claude()`/`director()`
arming logic or survived a stale `reload`; `pr_post_guard.py` fails closed
on every `gh`-mentioning Bash call from it, including read-only queries.

## Lease adoption and the initial-claim label (section 1 step 4)

- **Same-process adoption.** A fresh lease whose `pid` equals the
  `--messaging-socket` pid AND is an ancestor of the claiming process is
  adopted under the new session id with a fence bump, instead of `BUSY`.
  This is the `/clear` case: the session id changes, the Claude process
  does not. The record's `pid_start` must also match the claimant's
  process start identity, so a recycled pid is never adopted: the claim
  sees the holder gone and takes over with a fence bump (see the
  liveness rule in references/state-layout.md). Launcher-tier
  Claude leases only; a pid claimed from another process tree still gets
  `BUSY`. Never run `claim-owner` in the
  background: a background process started before `/clear` would pass the
  ancestry check under the old session id.
- **Handover adoption.** A fresh lease is also adopted, with a fence bump,
  when `STATE_ROOT/<slug>/rollover-pending.json` (written by section 1a's
  `rollover` verb) names this pane (`HERDR_PANE_ID`) and the token in
  `HERDR_ROLLOVER_TOKEN`, has not expired, and names the current lease's
  session and fence. The marker is single-use: adoption appends an
  `adopted` line to `<slug>/rollover.jsonl` and deletes it. A missing or
  mismatched marker changes nothing; the other claim rules still apply.
  Launcher-tier Claude claims only.
- **On the initial claim only** (not on refresh), label THIS session's own
  workspace so the Herdr UI shows the standing director, not a bare
  name: `herdr workspace rename "$HERDR_WORKSPACE_ID" "director:<repo>"`
  (`<repo>` = short repo name, e.g. `director:dotfiles`). Idempotent -- skip if
  the workspace label already equals it (`herdr workspace get
"$HERDR_WORKSPACE_ID"` -> `.result.workspace.label`). This is display-only
  Herdr state, never repo/worktree state; a worker's own workspace is
  labelled `<task_id>` at `worktree create` (section 2) and then
  `<state>: <title>` from its task record (section 8, Compact
  presentation), so no worker is ever left as a generic "Worker N".

## Inbox socket, launch line and auto-mode classifier (section 1 step 4)

- `--messaging-socket` publishes THIS session's inbox socket (empty when
  the CLI has no messaging) so worker hooks can push a wake to it. The
  core stores it as `owner.json.messaging_socket` and takes the owner
  `pid` from the socket basename (the Claude process, not a Bash `$PPID`);
  an unusable value stores `null` with one `[WARNING]` and ownership still
  succeeds. Launch with the `director` shell function
  (`zsh/claude-account.zsh`), which runs `claude --agent director
--settings '{"crossSessionInbound":"accept","autoCompactWindow":350000}' --permission-mode auto`
  through the account-routing wrapper and refuses outside a herdr pane.
  Auto mode is the documented launch; an explicit `--permission-mode`
  argument overrides it. Nothing in the director flow assumes a
  permission mode; the rollover hook runs in every mode.
  The 350000 `autoCompactWindow` is provisional, pending the measured
  post-split director boot figure.

  Auto mode's server-side classifier intercepts two kinds of action.
  It refuses `gh pr merge`, `gh workflow run`, `gh pr comment` and
  `gh pr ready` unless an allow rule covers them. The four rules
  (`Bash(gh pr merge:*)`, `Bash(gh workflow run:*)`,
  `Bash(gh pr comment:*)`, `Bash(gh pr ready:*)`) live in
  `claude/settings.json.tmpl`, so `update --ai` carries them into every
  account's `settings.json`; the post gate hook still runs on each of
  them. And it refuses any edit that loosens the
  director's own guardrails (this skill's launch and posting rules, the
  post gate, the `director` function's permission mode), from the
  director and from every worker it launches, which also run in auto
  mode. Those edits run from a manual-mode session
  (`director --permission-mode manual`).

  What the director runs, and what the classifier does with it:

  | Action                                                                                                                 | Covering template rule              | Prompt in manual mode | Auto mode                                                 | Recovery                                                                                   |
  | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------- | --------------------- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
  | `gh pr view`, `gh pr comment`, `gh pr merge`                                                                           | `Bash(gh pr:*)`                     | no                    | allowed by the template allow rules; refused without them | run `update --ai` to reconcile the rules into settings.json                                |
  | `gh repo view`, `gh api`                                                                                               | `Bash(gh repo:*)`, `Bash(gh api:*)` | no                    | allowed                                                   | none needed                                                                                |
  | core verbs: `write-task` contract pins, `confirm-plan`, `merge-authority`, `merge-ready`                               | `Bash(python3:*)`                   | no                    | allowed; an occasional refusal is reported                | rerun the verb from a manual-mode session                                                  |
  | `git worktree remove`                                                                                                  | `Bash(git worktree:*)`              | no                    | allowed                                                   | none needed                                                                                |
  | `DOTFILES_ALLOW_GIT_META=1 git ...`, the `rm -rf` teardown fallback                                                    | none                                | accepted prompt       | refused                                                   | finish `/post-merge` by hand                                                               |
  | an edit to this skill's launch or posting rules, the post gate, or the `director` permission mode (director or worker) | not applicable                      | accepted prompt       | refused as self-modification                              | make the edit from a manual-mode session; a worker reports `blocked:` with the denial text |

  The explicit `accept` is safe here because every inbound message is
  wake-only (Safety); a bypass-mode director without it has every
  hook wake held behind a dialog and dropped after `dialogExpiry`, and a
  `-p` director drops them after 5 minutes. Not added to
  `settings.json.tmpl` (it would apply to every session of the account).

## Backstop watch output (section 1 step 7)

While a task is
active it refreshes this session's ownership heartbeat itself every
`BACKSTOP_REFRESH_SECS` (300 s), following the lease this Claude process
holds across `/clear`, so worker pushes stay deliverable without a wake.
It prints nothing while pushes are delivered. It exits with one `signal`
line when a completion record stays undelivered for 120 s, or as soon as
a worker's `blocked` wake was dropped after this session's last check-in
(the next check-in row's `wake=<reason>` names why); with
`owner: lost` when another process holds the lease; and with
`owner: holder-gone` when it can no longer see this session's process as
its ancestor.

## Monitor watch when the socket is unset (section 1 step 7)

If the socket is unset, arm the
watch at the default cadence via the `Monitor` tool instead: if this
session has no live watch for this repo, capture `EPOCH=$(date +%s)`
FIRST, then start one via the `Monitor` tool --
`command: python3 "$CORE" watch --repo-slug <slug> --since-epoch $EPOCH`,
`persistent: true`, description `herdr worker activity (<repo>)` -- and
note the returned task id. The pre-captured epoch makes any event landing
while the watch subprocess starts up count as changed on its first pass.
Rules:

## Fallback without the Monitor tool (section 1 step 7)

- **Fallback** (no Monitor tool): `Bash run_in_background` with
  `python3 "$CORE" watch --repo-slug <slug> --exit-on-signal --since-epoch $EPOCH`.
  Its exit IS the wake; re-arm only on the wake turn it produced or after
  TaskStop -- never stack a second watcher.
  The default watch reads only `STATE_ROOT` and prints a closed vocabulary
  (`signal` / `heartbeat`); the backstop writes only the ownership
  heartbeat and prints `signal`, `owner: lost` or `owner: holder-gone`;
  worst-case wake latency is one `--interval`
  (default 15s) plus one `--debounce-secs` (default 60s) after a burst.
  The default watch fires on completion-record, think-answer, and
  mech-ledger writes; the hook pushes on completion-record changes and
  blocks; an ordinary worker turn end produces neither.
