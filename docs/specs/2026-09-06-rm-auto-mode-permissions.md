# Spec: Let auto mode decide `rm` commands instead of asking

Date: 2026-09-06
Branch: talon/td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking/rm-auto-mode
Source todo: `.todos/pending/2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking.md`

## Problem

`claude/settings.json.tmpl` lists `Bash(rm:*)` under `permissions.ask`
(line 158). Claude Code evaluates ask rules before the auto-mode
classifier and an ask rule forces a prompt even in auto mode, including
when the `rm` sits inside a compound command or a `$(...)` substitution
(permissions doc, "Compound commands"; permission-modes doc, "Critical
paths"). On 2026-09-05 that rule stalled three orchestrated worker
sessions in one evening, each on `rm -f` of its own `mktemp` scratch
files or a co-review snapshot worktree, and every stall needed a human
to press 1 in the worker's pane. The user approves these essentially
every time. The rule adds friction without safety: auto mode's
classifier already reviews every `rm`, and Claude Code routes `rm` of a
critical path (filesystem root, top-level directories, the home
directory, the working directory and its parents) to the classifier
regardless of allow rules or hooks.

The destructive-operation policy is shared across runtimes. Codex runs
the same shell payloads on this machine with its own sandbox, approval
policy, and PreToolUse hooks; dropping the Claude ask rule must not
leave Codex with weaker protection than Claude for the prohibited
targets.

## Goal

1. In Claude auto mode, harmless scratch cleanup (`rm -f` of a mktemp
   file, `rm -rf` of a mktemp or snapshot directory under `/tmp` or
   `$TMPDIR`) runs on the classifier's judgment with no prompt.
2. A `permissions.deny` floor blocks, in every permission mode and with
   no classifier involvement, recursive `rm` rooted at `/`, `~`,
   `$HOME`, and `.git`.
3. The force-push and Jira-create ask rules are unchanged.
4. Codex shell payloads have an equivalent floor for the same prohibited
   targets, through Codex's own mechanisms (sandbox plus a PreToolUse
   hook), with a Codex-specific explanation when a command is blocked.
5. The repo's test suites and the task's verification contract prove
   the template shape, the delivery path, and the Codex hook behavior
   without touching live machine state.

## Non-goals

- No change to which `rm` shapes the auto-mode classifier approves or
  blocks. The floor is a floor: everything not on it stays with the
  classifier (Claude) or the sandbox and approval policy (Codex).
- No new Claude PreToolUse hook for `rm`. Claude's deny rules plus the
  built-in critical-path check cover the Claude side; a hook would
  duplicate the deny list in a second place that the drift check cannot
  see.
- No copying of Claude permission JSON into Codex, and no change to
  either runtime's approval system (`defaultMode`, `approval_policy`,
  `sandbox_mode` stay as they are).
- No attempt to catch `rm` hidden behind an alias, a shell function, a
  script file, or a variable that expands to a prohibited path. Both
  runtimes' primary layers (classifier, sandbox) exist for those.
- No wildcard-target rules on the Claude side. A literal `*` cannot be
  written in a Claude Bash rule (it is always the wildcard), so
  `rm -rf /*`, `rm -rf ~/*`, and `rm -rf "$DIR"/*` stay with Claude
  Code's built-in critical-path check, which already treats a glob
  under the root, the home, or a shell variable as critical.

## Design

### Claude: `claude/settings.json.tmpl`

**Remove** `"Bash(rm:*)"` from `permissions.ask`. The remaining ask
rules stay in their current order:

```
"Bash(git push --force:*)",
"Bash(git push -f:*)",
"Bash(git push --force-with-lease:*)",
"Bash(git push --mirror:*)",
"mcp__plugin_atlassian_atlassian__createJiraIssue"
```

**Add** the deny floor to `permissions.deny` (currently `[]`). Claude
Bash rules match the literal command text of each subcommand; `*`
stands in for any text including spaces; a trailing ` *` also matches
the bare command only when it is the rule's sole wildcard; `:*` is the
same as a trailing ` *`. So each prohibited target gets two rules: one
for the target as the last token, one for the target followed by more
text (`--no-preserve-root`, a second target). The first `*` stands in
for the flags in any spelling or order (`-rf`, `-fr`, `-r -f`,
`--recursive --force`) and for any extra earlier targets.

```
"Bash(rm * /)",         "Bash(rm * / *)",
"Bash(rm * ~)",         "Bash(rm * ~ *)",
"Bash(rm * ~/)",        "Bash(rm * ~/ *)",
"Bash(rm * $HOME)",     "Bash(rm * $HOME *)",
"Bash(rm * $HOME/)",    "Bash(rm * $HOME/ *)",
"Bash(rm * \"$HOME\")", "Bash(rm * \"$HOME\" *)",
"Bash(rm * \"$HOME/\")","Bash(rm * \"$HOME/\" *)",
"Bash(rm * ${HOME})",   "Bash(rm * ${HOME} *)",
"Bash(rm * .git)",      "Bash(rm * .git *)",
"Bash(rm * .git/)",     "Bash(rm * .git/ *)",
"Bash(rm * ./.git)",    "Bash(rm * ./.git *)",
"Bash(rm * ./.git/)",   "Bash(rm * ./.git/ *)"
```

24 rules, listed in the template in exactly this order (target-major,
bare form before trailing-text form). Properties that follow from the
documented matcher and that the tests assert:

- `rm -rf /tmp/x` does not match `Bash(rm * /)` or `Bash(rm * / *)`:
  the rule needs a space-delimited `/` token, and `/tmp/x` is one
  token. Same for `~/x`, `$HOME/x`, `.git/index.lock`.
- Non-recursive `rm -f ~` matches the floor too. That is accepted: the
  command fails on a directory anyway, and a shorter list is easier to
  audit than a recursive-only list that must enumerate flag spellings.
- Deny rules match past a leading `FOO=bar` assignment, inside
  `$(...)`, and in any segment of a `&&`, `;`, `|`, or newline chain,
  so `cd /tmp && rm -rf ~` is denied.
- A deny rule "blocks in every mode, including `bypassPermissions`",
  and the permission-modes doc states a matching deny rule blocks a
  critical-path removal outright, before the classifier.

`permissions` is a template-owned key, so `reconcile_claude_settings_file`
reasserts it wholesale into `~/.claude/settings.json` and
`~/.claude-work/settings.json` on the next `update`; until then the
live permissions-drift check in `claude/hooks/claude-hooks.test.sh`
fails on this machine by design.

### Codex: sandbox as the primary layer, `codex/hooks/rm_guard.py` as the floor

**Sandbox (already in place, not changed).** Codex hooks on this
machine run under `sandbox_mode = "workspace-write"` with
`approval_policy = "on-request"` (`~/.codex/config.toml`, machine-local,
not dotfiles-managed). Probed live on 2026-09-06 with `codex sandbox`
(codex-cli 0.153.4, macOS seatbelt) from a scratch git repo:
workspace-write blocks writes to `.git`, to `$HOME`, and to `/`, and
allows `rm` of a file inside the workspace; read-only blocks workspace
writes. That is Codex's equivalent of the classifier plus critical-path
check. It does not apply under `danger-full-access` or
`--dangerously-bypass-approvals-and-sandbox`, which is why a floor is
still needed.

**Hook.** New `codex/hooks/rm_guard.py`, same shape as
`codex/hooks/no_ai_attribution_bash.py`: stdlib only, reads the
PreToolUse JSON on stdin, ignores any `tool_name` outside the shell set
(`bash`, `shell`, `exec_command`, `shell_command`, `unified_exec`,
case-insensitive), extracts the command with the same
`tool_input.command` / `cmd` / `args.cmd` fallback chain, fails open on
any exception, and on a hit prints `{"decision": "block", "reason": ...}`
to stdout and exits 2 (the shape Codex documents as the accepted legacy
block form and that the existing Codex hooks use).

Detection, per command:

1. Join backslash-newline continuations, then split into segments on
   `&&`, `||`, `;`, `|`, `&`, and newlines. Also scan the text inside
   every `$(...)` and backtick substitution as its own segment.
2. Per segment, `shlex.split` (posix, so quotes are removed and
   `"$HOME"` becomes `$HOME`); fall back to whitespace split on
   unbalanced quotes. Skip leading `NAME=VALUE` tokens and the prefix
   wrappers `sudo`, `command`, `env`, `nohup`, `time`, `nice`,
   `timeout` (plus that wrapper's own leading option tokens). For
   `sh`, `bash`, `zsh`, `dash` with `-c`, recurse into the string
   argument.
3. The command token, by basename, must be `rm`. Otherwise the segment
   is ignored (so `git rm -r x`, `echo rm -rf /`, and
   `grep "rm -rf ~"` never match).
4. Collect the remaining tokens. Recursive if any token is `-r`, `-R`,
   `--recursive`, or a short-flag cluster (`-` followed by letters)
   containing `r` or `R`. Targets are the non-flag tokens, plus every
   token after a bare `--`.
5. Block when recursive and any target, after stripping one trailing
   `/` (but not from a bare `/`), is one of: `/`, `~`, `$HOME`,
   `${HOME}`, `.git`, `./.git`, or ends with `/.git`. The `/.git`
   suffix covers `rm -rf /path/to/repo/.git`, which Claude's literal
   rules cannot express and which is the same loss as `rm -rf .git`.
   Also block when a target is `/*`, `~/*`, `$HOME/*`, or `${HOME}/*`
   (the shell has not expanded these when the hook sees them).

Everything else is allowed silently: `rm -f "$d/m"`,
`rm -rf "$(mktemp -d)"`-style scratch removal, `rm -rf /tmp/snapshot.x`,
`rm -rf .git/index.lock`, `rm -rf build`, `rm -r node_modules`.

Deny message (the `reason` field and stderr), Codex-specific so the
human reading the pane knows which runtime refused and why:

```
Blocked by the Codex rm guard: recursive rm of <target> is never allowed from an agent session. Codex's workspace-write sandbox already refuses writes to .git, $HOME, and /; this guard is the floor when the sandbox or approvals are bypassed. Name a narrower path (a scratch dir under /tmp, a build dir inside the workspace) instead.
```

**Registration.** `install/common/link.sh`:

- one more symlink line next to the existing four:
  `ln -sf "$DOTFILEDIR"/codex/hooks/rm_guard.py "$HOME"/.codex/hooks/rm_guard.py`
- one more `add_codex_hook` call, after the `no_ai_comments.py` call:
  marker `rm_guard.py`, matcher
  `Bash|Shell|exec_command|shell_command|unified_exec`, command
  `$HOME/.codex/hooks/rm_guard.py`.

Codex trust-gates every non-managed hook by the hash of its definition
("new or changed hooks are marked for review and skipped until
trusted"). The new `[[hooks.PreToolUse]]` entry that `update` appends
is inert until the user trusts it once via `/hooks` in the Codex TUI
(or a one-off `--dangerously-bypass-hook-trust`). That one-time trust
step is a documented human action, not something the installer does.

**Docs.** One sentence in the README's Codex hooks description naming
`rm_guard.py` and the one-time trust step. No other docs change.

### Tests

`claude/hooks/claude-hooks.test.sh`, a static block after the existing
"template lists the Bash guards in order" check, independent of live
state:

- `Bash(rm:*)` appears in neither `ask` nor `allow`.
- `ask` equals exactly the five remaining rules, in order.
- `deny` equals exactly the 24-rule floor, in order.
- Rule-model check: a small Python model of the documented Bash rule
  matcher (`*` -> `.*`, trailing sole ` *` optional, literal text
  otherwise, applied to one subcommand) asserts that no `ask` or `deny`
  rule matches `rm -f /tmp/scratch.txt`, `rm -rf /tmp/co-review-snap.x`,
  `rm -rf .git/index.lock`, `rm -rf build`, or `rm -rf ~/proj/build`,
  and that at least one `deny` rule matches each of `rm -rf /`,
  `rm -r -f ~`, `rm -rf "$HOME"`, `rm -rf ${HOME}`, `rm -rf .git`,
  `rm -rf ./.git/`, and `rm -rf / --no-preserve-root`. This checks the
  rule text against the documented semantics; it is not a test of
  Claude Code itself.

The existing live permissions-drift check already covers reconciled
machines and needs no change.

`install/claude-links.test.sh`, in the `link_claude_config_dir`
integration block: the reconciled scratch `settings.json` has
`Bash(rm * /)` in `permissions.deny` and no `Bash(rm:*)` in
`permissions.ask`.

`codex/hooks/codex-hooks.test.sh`, using the existing `assert_blocks` /
`assert_allows` helpers plus one explicit exit-2-and-JSON check:

Blocks: `rm -rf /`; `rm -r -f /`; `rm -rf / --no-preserve-root`;
`rm -rf ~`; `rm -rf ~/`; `rm -rf "$HOME"`; `rm -rf ${HOME}`;
`rm -rf $HOME/*`; `rm -rf .git`; `rm -rf ./.git/`;
`rm -rf /work/repo/.git`; `sudo rm -rf /`; `FOO=1 rm -rf ~`;
`cd /tmp && rm -rf ~`; `echo "$(rm -rf .git)"`;
`sh -c 'rm -rf /'`; `/bin/rm -rf /`; the same `rm -rf /` payload with
`tool_name` `exec_command` and the command under `tool_input.cmd`.

Allows: `rm -f /tmp/scratch.txt`; `rm -rf /tmp/co-review-snap.x`;
`rm -rf "$(mktemp -d)"`; `rm -rf .git/index.lock`; `rm -rf build`;
`rm -r node_modules`; `rm -f ~/.cache/x`; `git rm -r --cached x`;
`echo rm -rf /`; `grep -rn "rm -rf ~" .`; a `Write` tool payload; an
empty `tool_input`; malformed JSON (fail open).

Explicit contract: `rm -rf /` exits 2, stdout is a JSON object with
`decision` `block` and a `reason` starting `Blocked by the Codex rm
guard`; `rm -f /tmp/scratch.txt` exits 0 with empty stdout.

### Verification contract

`claude/contracts/td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking-contract.json`,
committed with the plan: template shape assertions, the rule-model
check, the three suites (hook suite sandboxed with a throwaway `HOME`),
direct `rm_guard.py` block/allow payloads, `py_compile` plus executable
bit, and a `link.sh` registration grep. Every command is repo-local,
deterministic, and writes only under `mktemp`.

## Acceptance criteria

1. `claude/settings.json.tmpl` parses; `Bash(rm:*)` is absent from
   `ask` and `allow`; `ask` is exactly the five remaining rules;
   `deny` is exactly the 24-rule floor in the order above.
2. The rule-model check passes for every listed harmless and
   prohibited shape.
3. `sh install/claude-links.test.sh` passes, including the new
   deny-floor delivery assertion.
4. `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh` passes
   with 0 failed (baseline 2026-09-06: 76 passed, 0 failed).
5. `sh codex/hooks/codex-hooks.test.sh` passes with 0 failed and every
   block and allow case above present (baseline: 11 passed, 0 failed).
6. `codex/hooks/rm_guard.py` is executable, stdlib-only, `py_compile`
   clean, exits 2 with the Codex-specific JSON block on `rm -rf /`, and
   exits 0 silently on `rm -f /tmp/scratch.txt`.
7. `install/common/link.sh` symlinks `rm_guard.py` and registers it via
   `add_codex_hook` with the shell-tool matcher.
8. Human-verify after merge and `update`: the live permissions-drift
   check passes in both config dirs (`sh claude/hooks/claude-hooks.test.sh`
   unsandboxed); in a Claude auto-mode session a `rm -f` of a mktemp
   file runs without a prompt and `rm -rf .git` inside a scratch git
   repo is refused by the deny rule; in Codex, `/hooks` shows
   `rm_guard.py` and after trusting it `rm -rf /` is refused with the
   Codex guard message.
9. The diff touches only: the settings template, the three test
   scripts, `codex/hooks/rm_guard.py`, `install/common/link.sh`,
   `README.md`, and the contract. No live `settings.json` or
   `~/.codex/config.toml` is modified by the implementation.

## Known limits (accepted)

- Claude deny rules are literal. `rm -rf "$HOME"/` (quote then slash),
  `rm -rf $HOME/.` , `rm -rf ~user`, and `rm -rf $(echo /)` are not on
  the floor; they reach the classifier and the critical-path check.
- The Claude floor denies non-recursive `rm ~` too (harmless failure).
- The Codex guard cannot see aliases, functions, or script files, and
  reads `$HOME`/`~` as text, not expanded; a variable that expands to
  `/` is caught by the sandbox, not the hook.
- The new Codex hook is inert until trusted once in the Codex TUI.
- A session running in auto mode may be unable to commit an edit to
  its own permission rules (the classifier blocked this on 2026-09-05);
  the implementation commit may need a human hand or a session outside
  auto mode.
