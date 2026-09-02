# Spec: Block `herdr worktree create` without `--cwd` via a PreToolUse hook

Date: 2026-09-01
Branch: talon/td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo/cwd-guard-hook
Source todo: `.todos/pending/2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo.md`
Task id: `td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo`

## Problem

`herdr worktree create` resolves the repository to anchor the new
worktree to from the herdr server's notion of "current" context, not
from the caller's shell cwd. Without an explicit `--cwd <repo_root>`
the create can anchor into whatever repo the server session (or an
adjacent submodule) is in. Live incident 2026-08-28: a create for a
ticket defaulted to a submodule root because several active
workspaces lived there, and a worker was briefed into the wrong repo.

The orchestration skill already declares `--cwd` MANDATORY for
`worktree create` (`claude/skills/herdr-orchestration/SKILL.md:187-189`).
That is a rule; the agent-lessons routing says a deterministically
detectable rule violation is enforced by hook, not prose. The Bash
permission allowlist cannot do it: `Bash(herdr worktree:*)` is a
literal prefix rule and cannot express "must contain `--cwd`".

## Goal

A PreToolUse Bash hook that denies every `herdr worktree create`
invocation it can parse as a direct or wrapper-prefixed command (the
supported grammar is enumerated under "Enforcement boundary") when
that invocation lacks `--cwd`. The deny message names the exact fix.
The hook is registered as a template-owned hook, covered by the hook
test suite, and allows every other command shape it sees unchanged.

## Scope decision: `create` only, deliberately partial

`herdr worktree open` is NOT guarded. The skill text is not uniform on
`open`: section 2 step 5 says `open --cwd <repo_root>` when adopting,
and section 5 step 1 (`SKILL.md:450-454`) says a rarely-needed `open`
carries the same mandatory `--cwd`, while `SKILL.md:424` describes
`open` as a plain re-attach to an existing workspace. The orchestrator
brief for this task settles it: scope the guard to `create` precisely,
because the incident, the todo, and the mis-anchor mechanism (choosing
a repo for a NEW worktree) are all about `create`. `open` re-attaches
to a workspace that already has a repo. Enforcement of `--cwd` on
`open` stays prose-only in the skill; the docs line this task adds
must say "create" and must not imply `open` is hook-enforced.

Other non-goals:

- No validation that the `--cwd` value is a real repo root or matches
  the caller's repo. The value is opaque to the hook; the skill's
  post-create anchor verification (`SKILL.md:197-207`) covers that.
- No override token. `--cwd` is always available to the caller, so
  there is no legitimate "I really mean it" path (unlike push_guard's
  `DOTFILES_ALLOW_FORCE_PUSH=1`).
- No change to the Codex hook set. This hook fires on the Claude Code
  Bash tool only.

## Design

### Hook: `claude/hooks/herdr_worktree_guard.py`

Same shape as `push_guard.py`: read the PreToolUse JSON on stdin,
ignore any `tool_name` other than `Bash`, inspect
`tool_input.command`, exit 2 with a stderr message to deny, exit 0
silently to allow. Fail open (exit 0) on any exception, including a
missing or non-string `command`; that matches every guard in this
directory. Executable, `#!/usr/bin/env python3`, stdlib only.

**Tokenizing.** Per command string:

1. Join backslash-newline continuations (`\\\n` -> single space)
   first, so a multiline `herdr worktree create \` with `--cwd` on
   the next physical line is one command.
2. Split on physical newlines. Each line is a segment source.
3. Tokenize each line with `shlex.shlex(line, posix=True,
   punctuation_chars=True)`, `whitespace_split=True`,
   `commenters="#"`. This yields shell-faithful tokens: quotes are
   honored (a quoted `;` inside `--label 'a;b'` stays inside its
   token), operators `;`, `&&`, `||`, `|`, `&` come out as their own
   tokens, and a `#` at the start of a word begins a comment that is
   dropped (so `herdr worktree create # --cwd /repo` is seen without
   `--cwd`, exactly as the shell runs it). On a tokenizer `ValueError`
   (unbalanced quote) fall back to `line.split()`.
4. Split the token list into segments at operator tokens (any token
   consisting only of characters from `;&|`). Redirection tokens such
   as `>&` or `2` are ordinary tokens and are ignored by the scan.

**Per-segment detection.**

5. Drop leading `NAME=VALUE` env assignments (a token containing `=`,
   not starting with `-`, whose left side has no `/`).
6. Drop leading PREFIX wrappers, repeating steps 5-6 until the head
   token is neither. PREFIX wrappers, by basename: `env`, `exec`,
   `command`, `nohup`, `time`, `xargs`. These run the following argv
   inline, so `env HERDR_ENV=1 herdr worktree create` and
   `command herdr worktree create` are direct invocations after the
   strip. (Wrapper-specific options such as `env -i` are not
   modelled; a `-`-prefixed token after a prefix wrapper is also
   dropped.)
7. If the head token, by basename, is `herdr` (covers
   `/opt/homebrew/bin/herdr`): skip herdr's global options, which
   `herdr --help` and a live probe confirm may precede the subcommand:
   `--session <name>` and `--remote <target>` (each consumes the next
   token, or is self-contained in `--opt=value` form), plus any other
   `-`-prefixed token. The next two tokens must then be exactly
   `worktree` then `create`; if not, this segment is not a create.
   For a create, scan the remaining tokens of the segment for a token
   equal to `--cwd` or starting with `--cwd=`. Present -> allow this
   segment; absent -> deny the command.
8. If the head token is a STRING wrapper, by basename, `sh`, `bash`,
   `zsh`, `dash`, or `eval`: for every remaining token in the segment
   whose text contains `herdr worktree create`, treat that token as a
   nested command line and run steps 1-8 on it (recursion, depth
   capped at 3). This catches `sh -c 'herdr worktree create ...'`.
9. Any other head token (`git`, `echo`, `grep`, `cat`, `printf`,
   ...): the segment is not an invocation. A commit message, a grep
   pattern, or `env echo 'herdr worktree create'` (after the prefix
   strip the head is `echo`) is a mention, not a create. This is the
   same false-positive trade `push_guard.py` makes ("trust the
   parse").

The command is denied if any segment (at any recursion depth) is a
create without `--cwd`; otherwise allowed.

### Enforcement boundary (the supported grammar)

Guaranteed caught: a `herdr worktree create` (bare or path-qualified
binary, with or without leading env assignments, PREFIX wrappers, or
herdr global options) that is the head of a shell segment on any
physical line, or that appears verbatim inside a quoted argument of a
STRING wrapper, with no `--cwd`/`--cwd=` token in that same segment.

Deliberately outside the guarantee (documented in the hook docstring,
accepted, and not tested for either outcome):

- A create hidden behind a shell alias, a function, or a script file.
- A create inside a `$(...)` / backtick substitution or a heredoc body.
- A quoted newline inside an argument (line-splitting happens before
  tokenizing).
- `--cwd` with an empty value (`--cwd ""`): herdr rejects it itself.
- A STRING-wrapper argument that builds the command from pieces
  (`sh -c "herdr worktree $sub"`).

### Deny message

Two stderr lines, matching the guard convention:

```
Blocked: herdr worktree create without --cwd anchors the worktree to the herdr server's current repo, not yours.
Re-run with --cwd "$(git -C <path-in-repo> rev-parse --show-toplevel)" (herdr-orchestration SKILL.md, section 2 step 5).
```

### Registration: `claude/settings.json.tmpl`

Append `~/.claude/hooks/herdr_worktree_guard.py` to the existing
`PreToolUse` entry with `"matcher": "Bash"`, after `push_guard.py`.
`hooks` is a template-owned key, so `reconcile_claude_settings_file`
propagates it to both live config dirs on the next `update`.

### Tests: `claude/hooks/claude-hooks.test.sh`

Add a `herdr_worktree_guard.py` block using the existing
`assert_blocks` / `assert_allows` helpers. Required cases:

Blocks (nonzero exit):
- bare `herdr worktree create`
- `herdr worktree create --branch x --label y` (other flags, no cwd)
- backslash-continued multiline create with no `--cwd` on any line
- `herdr worktree create --branch x # --cwd /repo` (cwd only in a
  comment)
- compound: `cd /r && herdr worktree create --branch x`
- `--cwd` only in a DIFFERENT segment:
  `herdr worktree create --branch x; echo --cwd /r`
- `--cwd` only on a DIFFERENT physical line:
  `herdr worktree create --branch x\necho --cwd /r`
- `sh -c 'herdr worktree create --branch x'`
- path-qualified `/opt/homebrew/bin/herdr worktree create`
- env-prefixed `HERDR_ENV=1 herdr worktree create`
- prefix-wrapped `env HERDR_ENV=1 herdr worktree create` and
  `command herdr worktree create`
- global-option form `herdr --session main worktree create --branch x`

Allows (exit 0):
- `herdr worktree create --cwd /repo --branch x`
- `herdr worktree create --cwd=/repo`
- `--cwd` as the last option
- `--cwd "$(git rev-parse --show-toplevel)"` (quoted substitution
  value stays one token)
- `herdr worktree create --label 'a;b' --cwd /repo` (quoted
  separator inside an argument)
- `herdr --session main worktree create --cwd /repo`
- backslash-continued multiline create with `--cwd` on line 2
- `herdr worktree create --cwd /repo 2>&1 | tee log` (redirection
  and a pipe after a valid create)
- `herdr worktree open --workspace ws1` (no cwd; open is out of scope)
- `herdr worktree list`, `herdr worktree remove --workspace ws1`
- `git commit -m "docs: mention herdr worktree create"` (mention)
- `grep -rn "herdr worktree create" claude/` (mention)
- `env echo 'herdr worktree create'` (mention behind a prefix wrapper)
- non-Bash tool payload
- payload with no `tool_input` / no `command` (fail open)

One focused exit-code and message assertion, beyond the helpers'
nonzero check: pipe the bare create payload into the hook, assert the
exit status is exactly 2 and stderr's first line starts with
`Blocked: herdr worktree create without --cwd`; then pipe the same
payload with `--cwd /repo` added and assert exit 0 with empty stderr.

One static registration assertion, independent of live machine state:
the template's `PreToolUse` `Bash` entry lists
`~/.claude/hooks/herdr_worktree_guard.py`. The existing live-settings
drift check is derived from the template, so it automatically covers
the new hook once `update` has reconciled a machine.

### Docs

- `claude/skills/herdr-orchestration/SKILL.md` section 2 step 5: one
  sentence after "MANDATORY, never a bare path" stating that a
  PreToolUse hook (`claude/hooks/herdr_worktree_guard.py`) denies a
  `worktree create` lacking `--cwd`, and that `open` is not
  hook-guarded.
- Repo `CLAUDE.md` Architecture list: one bullet for the hook beside
  the existing `account_guard.py` bullet, same wording discipline.

### Verification contract

File: `claude/contracts/td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo-contract.json`

```json
{
  "v": 1,
  "task_id": "td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo",
  "commands": [
    {
      "name": "claude-hooks-suite-sandboxed",
      "run": "HOME=\"$(mktemp -d)\" sh claude/hooks/claude-hooks.test.sh",
      "timeout_secs": 300
    }
  ]
}
```

The sandbox `HOME` makes the suite's live-settings drift section SKIP
(no live `settings.json` exists there), so the contract exercises the
hook assertions, the focused exit-2 assertion, and the static template
assertion, independent of whether this machine has run `update`. The
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
2. The focused assertion passes: bare create -> exit 2 with the
   `Blocked: herdr worktree create without --cwd` first line; with
   `--cwd /repo` -> exit 0, empty stderr.
3. `python3 -m py_compile claude/hooks/herdr_worktree_guard.py` passes;
   the file is executable (`chmod +x`, like its siblings).
4. `claude/settings.json.tmpl` parses as JSON and lists the hook in the
   `PreToolUse` `Bash` group.
5. `git diff` against `origin/main` touches only: the new hook, the
   test suite, the template, the two doc edits, and the contract file
   (plus this spec and its plan, which are branch-only and dropped
   before merge). No live machine state is modified.
6. Commit messages avoid the word "claude" outside the scope prefix
   (commit_guard blocks it); use `hooks:` as scope.
