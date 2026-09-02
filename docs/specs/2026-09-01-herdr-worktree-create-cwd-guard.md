# Spec: Block `herdr worktree create` without `--cwd` via a PreToolUse hook

Date: 2026-09-01
Branch: talon/td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo/cwd-guard-hook
Source todo: `.todos/pending/2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo.md`

## Problem

`herdr worktree create` resolves the repository to anchor the new
worktree to from the herdr server's notion of "current" context, not
from the caller's shell cwd. Without an explicit `--cwd <repo_root>`
the create can anchor into whatever repo the server session (or an
adjacent submodule) is in. Live incident 2026-08-28: a create for a
ticket defaulted to a submodule root because several active
workspaces lived there, and a worker was briefed into the wrong repo.

The orchestration skill already declares `--cwd` MANDATORY for every
`worktree create` (`claude/skills/herdr-orchestration/SKILL.md:187`).
That is a rule; the agent-lessons routing says a deterministically
detectable rule violation is enforced by hook, not prose. The Bash
permission allowlist cannot do it: `Bash(herdr worktree:*)` is a
literal prefix rule and cannot express "must contain `--cwd`".

## Goal

A PreToolUse Bash hook that denies any `herdr worktree create`
invocation lacking `--cwd`, with an error message that names the exact
fix, registered as a template-owned hook and covered by the hook test
suite. Zero behavior change for every other command.

## Non-goals

- `herdr worktree open` is NOT guarded. The skill permits
  `open --workspace <id>` re-attachment without `--cwd`
  (`SKILL.md:424`, `:450`); the incident and the todo name `create`
  only. Scope the guard to `create` precisely.
- No validation that the `--cwd` value is a real repo root or that it
  matches the caller's repo. The value is opaque to the hook; the
  skill's post-create anchor verification (`SKILL.md:197-207`) covers
  that.
- No override token. `--cwd` is always available to the caller, so
  there is no legitimate "I really mean it" path (unlike push_guard's
  `DOTFILES_ALLOW_FORCE_PUSH=1`).
- No change to the Codex hook set. This hook fires on the Claude Code
  Bash tool only.

## Design

### Hook: `claude/hooks/herdr_worktree_guard.py`

Same shape as `push_guard.py`: read the PreToolUse JSON on stdin,
ignore any `tool_name` other than `Bash`, inspect
`tool_input.command`, exit 2 with a stderr message to deny, exit 0 to
allow. Fail open on any exception (a crashed guard never blocks work);
that matches every guard in this directory.

**Detection algorithm.** Per command string:

1. Join backslash-newline continuations (`\\\n` -> space) BEFORE
   segment splitting. A multiline `herdr worktree create \` with
   `--cwd` on the next physical line is one command and must be
   allowed.
2. Split into segments on `|`, `;`, `&`, and newline (the push_guard
   `SEGMENT_SPLIT`), so a `--cwd` in one segment cannot satisfy a
   `create` in another.
3. For each segment, `shlex.split` (fall back to whitespace split on
   unbalanced quotes). Skip leading `NAME=VALUE` env assignments. The
   next token, by basename, must be `herdr` (covers `/opt/bin/herdr`);
   otherwise this segment is not a direct herdr invocation.
4. For a direct invocation: the two tokens after `herdr` must be
   exactly `worktree` then `create`. herdr has no global options that
   precede the subcommand in its CLI grammar (`herdr --help` lists
   only `--session`/`--remote` on the bare launcher form), so no
   option skipping is done; `herdr --session x worktree create` is not
   a shape the skill or any brief emits. If the subcommand pair
   matches, scan the remaining tokens for `--cwd` (separate value) or
   a token starting with `--cwd=`. Present -> allow; absent -> deny.
5. **Wrapped invocation fallback.** When the segment's command token
   is a shell wrapper (`sh`, `bash`, `zsh`, `dash`, `eval`, `xargs`,
   `env`, `exec`, `command`, `nohup`, `time`), recurse into each
   remaining token that contains the text `herdr worktree create`
   (the quoted string is itself a command line; run steps 1-4 on it).
   When the command token is anything else (`git`, `echo`, `grep`,
   `cat`, ...) do nothing: a commit message or a grep pattern that
   mentions the subcommand is not an invocation. This is the same
   false-positive trade push_guard makes ("trust the parse").

Deliberate holes, documented in the hook docstring and accepted:
- A create hidden behind an alias, a function, or a script file the
  hook cannot see.
- A quoted `--cwd` with an empty value (`--cwd ""`): herdr rejects it
  itself.
- A create inside a `$(...)` substitution or a heredoc body.

**Deny message** (stderr, two lines, matching the guard convention):

```
Blocked: herdr worktree create without --cwd anchors the worktree to the herdr server's current repo, not yours.
Re-run with --cwd "$(git -C <path-in-repo> rev-parse --show-toplevel)" (see herdr-orchestration SKILL.md, section 2 step 5).
```

### Registration: `claude/settings.json.tmpl`

Append `~/.claude/hooks/herdr_worktree_guard.py` to the existing
`PreToolUse` entry with `"matcher": "Bash"`, after `push_guard.py`.
`hooks` is a template-owned key, so `reconcile_claude_settings_file`
propagates it to both live config dirs on the next `update`.

### Tests: `claude/hooks/claude-hooks.test.sh`

Add a `herdr_worktree_guard.py` block using the existing
`assert_blocks` / `assert_allows` helpers (exit 2 = block, 0 = allow).
Required cases:

Blocks:
- bare `herdr worktree create`
- `herdr worktree create --branch x --label y` (other flags, no cwd)
- backslash-continued multiline create with no `--cwd` on any line
- compound: `cd /r && herdr worktree create --branch x`
- compound with `--cwd` only in a DIFFERENT segment:
  `herdr worktree create --branch x; echo --cwd /r`
- `sh -c 'herdr worktree create --branch x'`
- path-qualified `/opt/homebrew/bin/herdr worktree create`
- env-prefixed `HERDR_ENV=1 herdr worktree create`

Allows:
- `herdr worktree create --cwd /repo --branch x`
- `herdr worktree create --cwd=/repo`
- `--cwd` given as the first option, and as the last option
- `--cwd "$(git rev-parse --show-toplevel)"` (quoted substitution
  value; shlex keeps it as one token)
- backslash-continued multiline create with `--cwd` on line 2
- `herdr worktree open --workspace ws1` (no cwd; open is out of scope)
- `herdr worktree list`, `herdr worktree remove --workspace ws1`
- `git commit -m "docs: mention herdr worktree create"` (mention, not
  invocation)
- `grep -rn "herdr worktree create" claude/` (mention)
- non-Bash tool payload
- malformed / empty `tool_input` (fail open)

Plus one static registration assertion, independent of live machine
state: the template's `PreToolUse` `Bash` entry lists
`~/.claude/hooks/herdr_worktree_guard.py`. The existing live-settings
drift check is derived from the template, so it automatically covers
the new hook once `update` has reconciled a machine.

### Docs

- `claude/skills/herdr-orchestration/SKILL.md` section 2 step 5: one
  sentence after "MANDATORY, never a bare path" noting the PreToolUse
  hook enforces it and names the file.
- Repo `CLAUDE.md` Architecture list: one bullet for the hook beside
  the existing `account_guard.py` bullet.

### Verification contract: `claude/contracts/<task_id>-contract.json`

Per the merged convention (`v: 1`, `task_id`, `commands[]` with
`name`/`run`/`timeout_secs`), one command:

```
HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh
```

The sandbox `HOME` makes the suite's live-settings drift section SKIP
(no live `settings.json` exists there) so the contract exercises the
hook assertions and the static template assertion only, and is
independent of whether this machine has run `update`. The
`account_guard` cases already pin their own fixture HOMEs.

## Machine-state note (why the contract sandboxes HOME)

`~/.claude/hooks` on this machine is a symlink to the MAIN checkout's
`claude/hooks`, not this worktree. Reconciling live `settings.json`
from the branch template would register a hook path that does not
exist live until merge, and every Bash call in every session would
report a missing hook until then. So: do NOT reconcile live settings
from the branch. The live drift check goes green post-merge via the
normal `update`. The suite's baseline on this machine before any
change is 41 passed, 1 failed; the single failure is a pre-existing
permissions drift on `~/.claude/settings.json` (six template rules
missing live), unrelated to this task and cleared by the same `update`.

## Acceptance criteria

1. `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh` reports
   0 failed and includes every case listed above.
2. Piping `{"tool_name":"Bash","tool_input":{"command":"herdr worktree
   create --branch x"}}` into the hook exits 2 and prints the two-line
   deny message; the same with `--cwd /repo` added exits 0 silently.
3. `python3 -m py_compile claude/hooks/herdr_worktree_guard.py` passes;
   the file is executable (`chmod +x`, like its siblings).
4. `claude/settings.json.tmpl` parses as JSON and lists the hook in the
   `PreToolUse` `Bash` group.
5. `git diff` touches only: the new hook, the test suite, the template,
   the two doc lines, and the contract file. No live machine state is
   modified.
6. Commit messages avoid the word "claude" outside the scope prefix
   (commit_guard blocks it); use "hooks: ..." as scope.
