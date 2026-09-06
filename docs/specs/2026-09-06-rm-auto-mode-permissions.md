# Spec: Let auto mode decide `rm` commands instead of asking

Date: 2026-09-06
Branch: talon/td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking/rm-auto-mode
Source todo: `.todos/pending/2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking.md`
Scope (orchestrator, 2026-09-06): the Claude settings change only. The
todo's Runtime compatibility (Codex) section is carried as a follow-up
note at the end, not as acceptance criteria.

## Problem

`claude/settings.json.tmpl` lists `Bash(rm:*)` under `permissions.ask`
(line 158). Claude Code evaluates ask rules before the auto-mode
classifier, and an ask rule forces a prompt even in auto mode. The
permissions doc ("Compound commands") states it directly: "Deny and ask
rules apply when any subcommand matches them, including a command nested
inside a subshell, a command substitution, or a control-flow body ... An
ask rule like `Bash(git clean *)` still prompts you for
`cd /tmp && git clean -f` or `echo "$(git clean -f)"`, even in auto
mode." The permission-modes doc repeats it: "Explicit ask rules still
force a prompt." On 2026-09-05 that rule stalled three orchestrated
worker sessions in one evening, each on `rm -f` of its own `mktemp`
scratch files or a co-review snapshot worktree, and every stall needed a
human to press 1 in the worker's pane. The user approves these
essentially every time. The rule adds friction without safety: auto
mode's classifier already reviews every `rm`, and Claude Code routes
`rm` of a critical path (filesystem root, top-level directories, the
home directory, the working directory and its parents, a glob under a
shell variable) to the classifier regardless of allow rules or hooks.

## Goal

1. In auto mode, harmless scratch cleanup (`rm -f` of a mktemp file,
   `rm -rf` of a mktemp or snapshot directory under `/tmp` or `$TMPDIR`)
   runs on the classifier's judgment with no prompt.
2. A `permissions.deny` floor blocks, in every permission mode and with
   no classifier involvement, `rm` whose literal target is the
   filesystem root, the home directory, or a `.git` directory, in the
   spellings listed below. The floor is written so every recursive
   spelling (`-rf`, `-fr`, `-r -f`, `--recursive --force`) is covered.
3. The force-push and Jira-create ask rules are unchanged.
4. The links suite proves the reconcile path delivers the new
   permissions block, and the existing live drift check in the hook
   suite proves both config dirs carry it after `update`.

## Non-goals

- No change to which `rm` shapes the auto-mode classifier approves or
  blocks. The floor is a floor: everything not on it stays with the
  classifier.
- No new PreToolUse hook for `rm`. Deny rules plus the built-in
  critical-path check cover it; a hook would duplicate the deny list in
  a second place that the drift check cannot see.
- No wildcard-target rules. A literal `*` cannot be written in a Bash
  rule (it is always the wildcard), so `rm -rf /*`, `rm -rf ~/*`, and
  `rm -rf "$DIR"/*` stay with the built-in critical-path check
  (classifier in auto mode; a prompt in `bypassPermissions`, per the
  critical-paths table).
- No attempt to catch `rm` hidden behind an alias, a shell function, a
  script file, or a variable that expands to a prohibited path. The
  classifier exists for those.
- No Codex change in this task (see Follow-up).

## Design

### `claude/settings.json.tmpl`

**Remove** `"Bash(rm:*)"` from `permissions.ask`. The remaining ask
rules stay in their current order:

```
"Bash(git push --force:*)",
"Bash(git push -f:*)",
"Bash(git push --force-with-lease:*)",
"Bash(git push --mirror:*)",
"mcp__plugin_atlassian_atlassian__createJiraIssue"
```

**Add** the deny floor to `permissions.deny` (currently `[]`). Bash
rules match the literal command text of each subcommand; `*` stands in
for any text including spaces and including nothing; a trailing ` *`
also matches the bare command only when it is the rule's sole wildcard;
`:*` is the same as a trailing ` *`; every other character, including
the spaces around a `*`, is literal. So each prohibited target gets two
rules: one for the target as the last token, one for the target
followed by more text (`--no-preserve-root`, a second target). The
first `*` stands in for the flags in any spelling or order and for any
extra earlier targets.

```
"Bash(rm * /)",          "Bash(rm * / *)",
"Bash(rm * ~)",          "Bash(rm * ~ *)",
"Bash(rm * ~/)",         "Bash(rm * ~/ *)",
"Bash(rm * $HOME)",      "Bash(rm * $HOME *)",
"Bash(rm * $HOME/)",     "Bash(rm * $HOME/ *)",
"Bash(rm * \"$HOME\")",  "Bash(rm * \"$HOME\" *)",
"Bash(rm * \"$HOME/\")", "Bash(rm * \"$HOME/\" *)",
"Bash(rm * ${HOME})",    "Bash(rm * ${HOME} *)",
"Bash(rm * ${HOME}/)",   "Bash(rm * ${HOME}/ *)",
"Bash(rm * .git)",       "Bash(rm * .git *)",
"Bash(rm * .git/)",      "Bash(rm * .git/ *)",
"Bash(rm * ./.git)",     "Bash(rm * ./.git *)",
"Bash(rm * ./.git/)",    "Bash(rm * ./.git/ *)"
```

26 rules, listed in the template in exactly this order (target-major,
bare form before trailing-text form). Properties that follow from the
documented matcher and that the tests assert:

- `rm -rf /tmp/x` does not match `Bash(rm * /)` or `Bash(rm * / *)`:
  the rule needs a space-delimited `/` token, and `/tmp/x` is one
  token. Same for `~/x`, `$HOME/x`, `.git/index.lock`, `./.github`.
- Any flagged form is denied regardless of recursion: `rm -f ~` matches
  `Bash(rm * ~)` with `*` standing in for `-f`. A finite literal list
  cannot express "recursive flag present" without enumerating every
  flag spelling, and a non-recursive `rm` of a directory fails on its
  own, so the broader match costs nothing. A bare two-token `rm ~` does
  not match (the rule's two literal spaces need a token between `rm`
  and `~`); that command also fails on its own.
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

### Tests

`claude/hooks/claude-hooks.test.sh`, a static block after the existing
"template lists the Bash guards in order" check, independent of live
state, emitting four `PASS  permissions: ...` lines:

- `Bash(rm:*)` appears in neither `ask` nor `allow`.
- `ask` equals exactly the five remaining rules, in order.
- `deny` equals exactly the 26-rule floor, in order.
- Rule-model check: a small Python model of the documented Bash rule
  matcher (`*` -> `.*`; a trailing sole ` *` becomes an optional ` .*`
  suffix; every other character is regex-escaped so `.` in `.git` is
  literal; the pattern is anchored to the whole subcommand) asserts
  that no `ask` or `deny` Bash rule matches `rm -f /tmp/scratch.txt`,
  `rm -rf /tmp/co-review-snap.x`, `rm -rf .git/index.lock`,
  `rm -rf build`, `rm -rf ~/proj/build`, `rm -rf $HOME/.cache/x`,
  `rm .gitignore`, or `rm -rf ./.github`, and that at least one `deny`
  rule matches each of `rm -rf /`, `rm -r -f ~`, `rm -rf "$HOME"`,
  `rm -rf ${HOME}`, `rm -rf ${HOME}/`, `rm -f ~`, `rm -rf .git`,
  `rm -rf ./.git/`, `rm -rf / --no-preserve-root`, and
  `rm --recursive --force ~/`. This checks the rule text against the
  documented semantics; it is not a test of Claude Code itself (see
  "Verification gaps").

The existing live permissions-drift check (`settings: <dir> permissions
match template`) already covers reconciled machines and needs no
change.

`install/claude-links.test.sh`, in the `link_claude_config_dir`
integration block, one new case labelled `link path delivers the rm
deny floor and drops the rm ask rule`: the reconciled scratch
`settings.json` has `Bash(rm * /)` in `permissions.deny` and no
`Bash(rm:*)` in `permissions.ask`.

### Verification contract

`claude/contracts/td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking-contract.json`,
committed with the plan: three template shape assertions, the
rule-model check, the hook suite sandboxed with a throwaway `HOME` plus
an exact count of its new `permissions:` lines, and the links suite
with its new delivery line. Every command is repo-local, deterministic,
and writes only under `mktemp`.

## Acceptance criteria

1. `claude/settings.json.tmpl` parses; `Bash(rm:*)` is absent from
   `ask` and `allow`; `ask` is exactly the five remaining rules;
   `deny` is exactly the 26-rule floor in the order above.
2. The rule-model check passes for every listed harmless and
   prohibited shape.
3. `sh install/claude-links.test.sh` passes (baseline 2026-09-06: 16
   passed, 0 failed) and prints the new deny-floor delivery `PASS` line.
4. `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh` passes
   with 0 failed (baseline 2026-09-06: 76 passed, 0 failed) and prints
   exactly four `PASS  permissions: ` lines.
5. Human-verify after merge and `update`: the live permissions-drift
   check passes in both config dirs (`sh claude/hooks/claude-hooks.test.sh`
   unsandboxed); in an auto-mode session inside a scratch git repo
   under `$TMPDIR`, `rm -f` of a mktemp file and `rm -rf` of a scratch
   subdirectory run without a prompt, while `rm -rf "$HOME"`,
   `rm -rf ./.git/`, and `rm -r -f ~` are each refused by a deny rule.
6. The diff touches only `claude/settings.json.tmpl`,
   `claude/hooks/claude-hooks.test.sh`, `install/claude-links.test.sh`,
   and the contract. No live `settings.json` is modified by the
   implementation.

## Verification gaps (named)

- The rule-model check (criterion 2) validates the 26 rules against a
  Python model of the documented matcher, not against Claude Code. If
  the model mis-encodes a semantic, rules and check pass together while
  live behavior differs. Criterion 5's live probes (three denied
  shapes, two harmless shapes) are the only exercise of the real
  matcher, and they run after merge.

## Known limits (accepted)

- Deny rules are literal. `rm -rf "$HOME"/` (quote then slash),
  `rm -rf $HOME/.`, `rm -rf ~user`, `rm -rf "${HOME}"`,
  `rm -rf /path/to/repo/.git`, and `rm -rf $(echo /)` are not on the
  floor; they reach the classifier and the critical-path check.
- In `bypassPermissions` mode there is no classifier; a critical-path
  removal not on the deny floor (e.g. `rm -rf /*`) prompts instead of
  being blocked (permission-modes doc, critical-paths table). This repo
  runs `defaultMode: auto`.
- A session running in auto mode may be unable to commit an edit to
  its own permission rules (the classifier blocked this on 2026-09-05);
  the implementation commit may need a human hand or a session outside
  auto mode.

## Follow-up (out of scope here): Codex parity

The todo's Runtime compatibility section asks for equivalent protection
on the Codex side. That is deferred to its own task. What is already
known, for whoever picks it up: Codex on this machine runs
`sandbox_mode = "workspace-write"` with `approval_policy = "on-request"`
(machine-local `~/.codex/config.toml`), and a live `codex sandbox` probe
on 2026-09-06 (codex-cli 0.153.4, macOS) showed workspace-write refuses
writes to `.git`, `$HOME`, and `/` while allowing `rm` inside the
workspace. A floor for `danger-full-access` sessions would be a
PreToolUse hook (`codex/hooks/rm_guard.py`, registered via
`add_codex_hook` in `install/common/link.sh`, trust-gated once via
`/hooks` in the Codex TUI) with a Codex-specific deny message; do not
copy the Claude permission JSON into Codex or disable either runtime's
approval system.
