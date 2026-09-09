# Spec: Guard git remote and config mutations in worker sessions

Date: 2026-09-08
Branch: talon/td-2026-09-07-guard-git-remote-and-config-mutations-in-worker-se/plan-git-remote-guard
Source task: td-2026-09-07-guard-git-remote-and-config-mutations-in-worker-se
Todo: `.todos/pending/2026-09-07-guard-git-remote-and-config-mutations-in-worker-se.md`
Status: branch-only document; dropped before merge together with the plan.

## Problem

On 2026-09-07 a plan worker's embedded test suite ran
`( cd "$repo" && git remote remove origin )` with `$repo` empty. `cd ""`
succeeds in place, so the removal ran in the worker's own worktree. Every
herdr worktree is a linked worktree sharing the main checkout's `.git`, so
that one fixture bug deleted the `origin` remote and every `[branch]`
upstream stanza for every checkout at once, and every contract gate
(`git merge-base origin/main HEAD`) would have failed until a human
restored the remote by hand.

`claude/hooks/rm_guard.py` (PR #88) denies catastrophic `rm` targets;
nothing guards the equivalent class for git metadata: remote removal and
rewrites, `git config` writes to remote/branch/core keys, deletion of
another task's branch or worktree, and direct edits to `.git/config` or
`.git/info/exclude`. Worker briefs already say "never cd into a variable
that may be empty"; prose does not stop a running command, a hook does.

## Goal

A PreToolUse hook, `claude/hooks/git_remote_guard.py`, that in herdr
sessions denies git-metadata mutations aimed at a real checkout, allows
the same mutations aimed at a fixture repository under a temp root, and
tells the caller the exact fixture-path rule in the denial. Registered in
`claude/settings.json.tmpl`, covered by its own hermetic, payload-driven
suite `claude/hooks/git-remote-guard.test.sh`, registered in
`bin/dotfiles-tests`, and drift-checked by `claude-hooks.test.sh`. Zero
behavior change outside herdr sessions.

## Non-goals

- No change to plain (non-herdr) sessions. See D1 for the gate and why.
- No guard on `git remote add`, `set-head`, `set-branches`, `update`,
  `show`, `get-url`, or `-v`: they do not delete or rewrite an existing
  remote, and `remote add` is the documented recovery step.
- No guard on `git push --delete` / `git push origin :branch`: that is
  push_guard territory (a follow-up if wanted).
- No guard on `git update-ref -d`, `git branch -m/-M` (rename), `git
worktree move`, or `herdr worktree remove --workspace <id>`: none of them
  appeared in the incident class; `herdr worktree remove` is the
  orchestrator's own teardown verb and stays unguarded exactly like
  `herdr_worktree_guard.py` leaves it.
- No inspection of script files. The hook sees the Bash tool's command
  text; `sh some.test.sh` is opaque, the same accepted residual as
  rm_guard's ("other deleters ... are not inspected"). The script-side
  rule (fixture mutations only under an asserted mktemp root, addressed
  with `git -C`) is the brief-template / planner-contract one-liner that
  lives on the parity branch (see Follow-ups).
- No writes anywhere. The hook never writes STATE_ROOT, never logs, never
  reconciles settings.
- No edits to `claude/skills/herdr-orchestration/`,
  `references/brief-template.md`, `claude/hooks/rm_guard.py`,
  `claude/hooks/scratch_policy.py`, or `claude/hooks/herdr_orch_core.py`.
- No shared-parser refactor. The hook imports rm_guard's tokenizer,
  segment splitter, prefix stripper, cd tracker, and shell-wrapper
  extractor as-is (the same reuse `scratch_policy.py` does); nothing in
  rm_guard moves.

## Confirmed facts (read at base `9ae3daf`, 2026-09-08)

- `rm_guard.py` exposes `tokenize`, `split_segments`, `strip_prefixes`,
  `basename`, `expand_home`, `resolve`, `resolve_cd_target`,
  `extract_shell_c_arg`, `has_glob_chars`, `SHELL_WRAPPERS`; its
  tokenizer keeps quoted text as one token (`"$repo"` becomes `$repo`,
  `""` becomes an empty token) and splits on `;`, `&`, `|`, `(`, `)`, and
  newline. `scratch_policy.py` already imports it this way.
- `herdr_orch_core.py` exposes `state_root()` (`$CLAUDE_CONFIG_DIR` or
  `~/.claude`, plus `herdr-orch`), `valid_workspace_id`, `valid_task_id`
  (`[A-Za-z0-9][A-Za-z0-9_-]*`, so no dots), `read_index(rd, ws)`, and
  `contained`. Importing it costs about 30 ms (measured); rm_guard about
  2 ms.
- Task records live at `STATE_ROOT/<slug>/tasks/<task_id>.json` with
  `branch` (string), `worktree` (absolute path or null), `status`
  (`kickoff|in-progress|blocked|completed|review-dispatched|changes-requested|reviewed|failed|abandoned|merged`
  per `references/state-layout.md:273`); sidecars are
  `<task_id>.done.json`, `.review.json`, `.policy.jsonl`. Workspace
  indexes at `STATE_ROOT/<slug>/workspaces/<ws>.json` carry `task_id`,
  `repo_slug`, `role`. The orchestration skill's status table marks
  `failed`, `abandoned`, and `merged` terminal; `reviewed` is NOT terminal
  (the branch waits for a human merge).
- `/post-merge` (claude/skills/post-merge/SKILL.md, Step 3) runs
  `git worktree remove "<wt>"` then `git branch -D "<headRefName>"` after
  a human confirmation, while the task record may still read `reviewed`
  (`merged` is written by `/post-merge` itself or the orchestrator's next
  check-in).
- Herdr sessions carry `HERDR_ENV=1`; workers additionally carry
  `HERDR_WORKSPACE_ID` (this planning session: `HERDR_ENV=1`,
  `HERDR_WORKSPACE_ID=wQ`). `herdr_stop_gate.py` and `scratch_policy.py`
  gate on exactly these.
- Claude Code runs every hook in a matching PreToolUse group in parallel;
  entry order inside the template is documentary. The template's Bash
  group is `commit_guard`, `no_ai_attribution_bash`, `push_guard`,
  `herdr_worktree_guard`, `rm_guard`; both `claude-hooks.test.sh` (label
  `hwg: template lists the Bash guards in order`) and
  `scratch-policy.test.sh` (label `static: template registers exactly this
hook under PermissionRequest`) pin that exact list, so a new hook
  appended to the Bash group would break both suites. The live-settings
  drift check in `claude-hooks.test.sh` is derived from the template and
  covers any new entry without edits.
- `git -C<path>` (glued) is rejected by git 2.55 ("unknown option"); only
  `-C <path>` exists. `git worktree remove <worktree>` accepts a path or a
  unique trailing-component suffix of the path (git-worktree(1)).
- `git config` accepts both the option grammar (`--unset`, `--add`,
  `--remove-section`, ...) and, since 2.46, subcommands (`set`, `unset`,
  `get`, `list`, `remove-section`, `rename-section`, `edit`).
- Docs under `docs/specs/` and `docs/plans/` are gitignored and excluded
  (`.git/info/exclude`); prior planning branches committed them with
  `git add -f` and dropped them before merge. The public-safety suite's
  "no tracked planning artifacts" failure is the documented, expected one
  while they are tracked.
- The committed `talon/claude-codex-parity` branch holds uncommitted
  changes to `claude/hooks/claude-hooks.test.sh` and `bin/dotfiles-tests`
  that this worktree cannot see; every hunk in those two files must stay
  small and append-only.
- Test baseline on this machine, 2026-09-08, at base `9ae3daf`, sandboxed
  `HOME`: `bin/dotfiles-tests` 25 suites passed, 0 failed;
  `claude-hooks.test.sh` 185/0; `scratch-policy.test.sh` 104/0;
  `herdr-orch.test.sh` 106/0; `herdr-orch-contract.test.sh` 71/0;
  `install/claude-links.test.sh` 26/0; `public-safety.test.sh` 5/0.
- Design prototype: every rule below was executed against 83 payload
  cases (the D8 list) in the session scratchpad; 83 passed. A deny costs
  about 30 ms including the `git rev-parse` in D4.

## Design

### D1. Gate: herdr sessions only

The hook decides only when the environment variable `HERDR_ENV` equals
the string `1`. Otherwise it exits 0 silently before parsing anything.

Rationale: the incident class is an unattended worker running generated
commands; herdr sets `HERDR_ENV=1` for every pane it launches (workers
and the orchestrator alike), and the orchestrator's own metadata verbs are
covered by the terminal-status and override rules below. In a plain
session the user is driving and sees each permission prompt; the todo
scopes those sessions out, and widening to `permission_mode == auto`
plain sessions is a follow-up if incidents recur there. The gate is
env-only (no payload field), so it is identical for Bash, Write, and Edit
payloads and cannot be spoofed by tool input.

### D2. Registration and events

One new template entry, appended to `hooks.PreToolUse` in
`claude/settings.json.tmpl`:

```json
{
  "matcher": "Bash|Edit|Write",
  "hooks": [
    { "type": "command", "command": "~/.claude/hooks/git_remote_guard.py" }
  ]
}
```

A separate entry with a combined matcher, not an append to the existing
Bash group, because the two suites above pin the Bash group's exact list
and hooks in a group run in parallel anyway. The hook reads the PreToolUse
JSON on stdin and dispatches on `tool_name`: `Bash` runs D3 to D6 on
`tool_input.command`; `Write` and `Edit` run D7 on `tool_input.file_path`;
every other tool exits 0. Deny is exit 2 with two stderr lines (D9); allow
is exit 0 with no output. Any exception exits 0 (fail open, the guard
convention in this directory). Malformed JSON, a missing or non-dict
`tool_input`, an empty command: exit 0.

### D3. Command walk (Bash)

`check_command(command, real_cwd, home, roots, cwd=None)`, modelled on
rm_guard's: `split_segments(tokenize(command))`, then per segment:

1. `overridden = "DOTFILES_ALLOW_GIT_META=1" in tokens` (checked before
   prefix stripping, so the token must lead the segment among its env
   assignments, exactly like push_guard's `DOTFILES_ALLOW_FORCE_PUSH=1`).
2. `tokens = strip_prefixes(tokens)`; empty: next segment.
3. Head `cd`: `cwd = resolve_cd_target(tokens, cwd, home)`; next segment.
   `cd ""` resolves to the current cwd; `cd "$repo"` resolves to the
   literal `<cwd>/$repo`, which later fails the literal test (D4).
4. Head in `SHELL_WRAPPERS` (`sh`, `bash`, `zsh`): recurse into the `-c`
   argument with the tracked cwd; next segment.
5. `overridden`: next segment (the override covers one segment only).
6. Head `git` (by basename, so `/usr/bin/git` counts): D4 to D6.
7. Any other head: D7's Bash writer check.

The first denial wins; no denial means allow.

### D4. Git invocation parsing and the fixture exemption

`parse_git(tokens)` skips git's global options to find the subcommand:
`-C <path>` values are collected in order; `-c`, `--namespace`,
`--config-env` consume one value; `--git-dir <x>`, `--work-tree <x>`,
`--git-dir=<x>`, `--work-tree=<x>` are collected as location hints; any
other `-`-prefixed token is skipped. The first non-option token is the
subcommand; the rest are its args.

Effective directory: start from the tracked cwd, apply each `-C` value in
order with `resolve(expand_home(value, home), current)`; an empty `-C ""`
is a no-op (as in git). A value or the resulting path containing `$`, a
backtick, or a glob character is not literal.

`fixture_dir(path, roots)` returns None (fixture) or a reason string:

1. `c = canon(path)` (realpath of the longest existing ancestor joined
   with the rest, as in scratch_policy).
2. `c` must be strictly under a temp root (`root + "/"` prefix). Roots:
   `realpath($TMPDIR)` when `TMPDIR` is set and absolute and not `/`,
   HOME, an ancestor of HOME, or shallower than two components; plus
   `realpath("/tmp")` always. Not under any root: reason "targets a
   checkout outside every temp root".
3. `c` must exist as a directory: reason "fixture path does not exist yet
   (resolve mktemp -d in a separate call)". This is deliberate: a path
   that does not exist at hook time cannot be proven a fixture, and the
   alternative (allow non-existent paths) opens
   `git worktree add /tmp/wt && git -C /tmp/wt remote remove origin`,
   which would mutate the real repo's shared config through a linked
   worktree created moments earlier.
4. `git -C <c> rev-parse --path-format=absolute --git-common-dir`, run
   with `GIT_CEILING_DIRECTORIES=<the matched root>`,
   `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, and `GIT_DIR`,
   `GIT_WORK_TREE`, `GIT_COMMON_DIR` removed from the environment, 5 s
   timeout. Non-zero exit or timeout: reason "fixture path is not inside
   a repository under the temp root". The printed common dir, canonicalized,
   must also be strictly under a temp root: otherwise reason "fixture path
   is a linked worktree whose .git lives outside the temp root". This is
   the check that closes the linked-worktree escape (a `.git` file under
   `/tmp` whose `gitdir:` points at a real checkout).

Location hints (`--git-dir`, `--work-tree`, and their `=` forms) must each
be literal and canonicalize strictly under a temp root; otherwise the
mutation is denied with reason "--git-dir/--work-tree outside the temp
root". `GIT_DIR=`-style env assignments are stripped by `strip_prefixes`
and not interpreted (accepted hole, listed in D10).

The exemption is evaluated only for the mutating shapes in D5; reads and
unguarded subcommands never reach it, so they never pay the rev-parse.

### D5. Mutating git shapes

Rule R1, remotes. Subcommand `remote` whose first arg is one of `remove`,
`rm`, `set-url`, `rename`, `prune`: mutation. Deny unless the effective
directory is a fixture (D4). The remote name is irrelevant (an unexpanded
`"$r"` still denies).

Rule R2, config writes. Subcommand `config`. Classify with
`config_action(args)`:

- value-taking options consumed with their value: `--file`/`-f`,
  `--blob`, `--type`, `--default`, `--comment`; `--file=<x>` also sets
  the file path;
- `--global` or `--system`: scope outside the repo;
- write options: `--add`, `--replace-all`, `--unset`, `--unset-all`,
  `--remove-section`, `--rename-section`, `--edit`, `-e`;
- read options: `--get`, `--get-all`, `--get-regexp`, `--get-urlmatch`,
  `--list`, `-l`, `--get-colorbool`, `--get-color`;
- positionals collected in order; a leading positional `set`, `unset`,
  `remove-section`, `rename-section`, or `edit` makes it a write and is
  dropped; a leading `get` or `list` makes it a read and is dropped;
- with no explicit action: two or more positionals is a write (`git config
<key> <value>`), otherwise a read.

The key is the first remaining positional. A write is guarded when the
key is not literal (unexpanded variable) or matches, case-insensitively,
`^(remote(\..*)?|branch\.[^.]+(\.(remote|merge|pushremote))?|core(\..*)?)$`:
every `remote.*` key and the `remote` section, `branch.<name>` as a
section (for `--remove-section` / `--rename-section`) plus its `remote`,
`merge`, and `pushremote` keys (the upstream is the pair; the incident
wiped both), and every `core.*` key. Other keys (`user.name`,
`branch.x.description`, ...) are never guarded.

For a guarded write: `--global`/`--system` denies always (reason "edits
the user's git config"); a `--file` path denies unless literal and
canonicalized strictly under a temp root; otherwise the effective
directory rule of D4 applies (`--local`, `--worktree`, and the default
scope all mean "this checkout").

`git -c key=value <cmd>` is a per-invocation override, not a write, and is
never guarded.

Rule R3, another task's branch or worktree. Read-only lookup over
`STATE_ROOT/*/tasks/<task_id>.json` (basename minus `.json` must satisfy
`valid_task_id`, which excludes every sidecar; symlinks and non-object
JSON skipped; any read error skips the record). A record is _protected_
when its `status` is not in `{"merged", "failed", "abandoned"}` and its
`task_id` (the filename stem) is not the session's own task. The own task
resolves from `HERDR_WORKSPACE_ID` through `read_index` across slugs,
sorted-first, exactly as scratch_policy's `log_allow` does; no index means
no own-task exemption.

- `git branch` with a delete flag (`-d`, `-D`, `--delete`, or a bundled
  short group containing `d` or `D`): every positional is a branch name;
  strip a `refs/heads/` prefix; deny when it equals a protected record's
  `branch`.
- `git worktree remove [--force ...] <worktree>`: every positional is a
  target; deny when its canonical path equals a protected record's
  canonical `worktree`, or when the token is relative and the record's
  canonical worktree ends with `/<token>` (git's trailing-component
  form).

R3 never consults D4: a task worktree under `/tmp` is still another
task's worktree.

Rule R4 is D7 (files). Every other git subcommand allows.

### D6. Override

`DOTFILES_ALLOW_GIT_META=1` as a leading env assignment on the same
segment allows that segment through every rule (R1 to R4). The denial
names it and states the condition: explicit user confirmation in
conversation, never added by the model on its own. Consumers:
`/post-merge` Step 3 under herdr (the record may still read `reviewed`),
and a human-confirmed `git remote set-url` in an orchestrator session.
Precedent: push_guard's `DOTFILES_ALLOW_FORCE_PUSH=1`.

### D7. Guarded files (Write, Edit, and Bash writers)

A path is a guarded file when, after `expand_home` and `resolve` against
the effective cwd, it matches `(^|/)\.git/(config|info/exclude)$` and its
canonical form is not strictly under a temp root. Non-literal paths are
never matched (an unexpanded variable in a file path cannot be resolved,
and Write/Edit paths are literal by construction).

- Tools `Write` and `Edit`: deny when `tool_input.file_path` is a guarded
  file. `Read`, `NotebookEdit`, and everything else: exit 0. The documented
  flows that touch `.git/info/exclude` (`bin/setup-claude`, the todos
  script `todos.sh`) are shell scripts invoked by name, never Write/Edit
  calls, so nothing legitimate is caught.
- Bash, per segment (any head): a redirection token (`>`, `>>`, `>|`,
  `1>`, `2>`, `1>>`, `2>>`, `&>`, `&>>`) followed by a guarded file, or a
  token gluing one of those to a guarded file (`>>.git/config`); and for
  heads `tee`, `cp`, `mv`, `truncate`, or `sed` with an in-place flag
  (`-i...` short, `--in-place[=...]`), any non-option token that is a
  guarded file. The tokenizer does not split on `>`, so the glued form is
  one token and the spaced form is two adjacent tokens; `&>` splits at
  `&` and the `>` starts the next segment, which the same scan catches.

### D8. Test suite: `claude/hooks/git-remote-guard.test.sh`

Hermetic, payload-driven, modelled on `scratch-policy.test.sh`: POSIX sh,
`PASS`/`FAIL` lines, `N passed, N failed` trailer, non-zero exit on any
failure, `PYTHONDONTWRITEBYTECODE=1`, the hook path overridable through
`GIT_REMOTE_GUARD_HOOK` (static checks skip when it is overridden).

Fixture safety, enforced by the suite's own shape and by a contract text
scan: one mktemp root `FIX=$(mktemp -d /tmp/git-remote-guard.XXXXXX)`
asserted with `[ -n "$FIX" ] && [ -d "$FIX" ]` before any use; every
fixture git call is `env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git -C "<path under FIX>" ...`; no `cd` anywhere in the file; no
`git remote` or `git config` mutation outside `$FIX`; a trap removes
`$FIX`. Fixtures: `$FIX/repo` (a real repo with an `origin` remote and one
commit), `$FIX/wt` (a linked worktree of `$FIX/repo`, created with
`git -C "$FIX/repo" worktree add`), `$FIX/esc` (a directory whose `.git`
is a file reading `gitdir: /Users/grg-test-user/proj/.git/worktrees/esc`,
the escape shape), `$FIX/tmpdir` (the per-case `TMPDIR`), `$FIX/home` (the
hook's `HOME`), `$FIX/cfg` (a throwaway `CLAUDE_CONFIG_DIR` holding
`herdr-orch/slug-x/tasks/T-1.json` in-progress with branch `talon/T-1/x`
and worktree `$FIX/wt-t1`, `T-2.json` merged, `T-3.json` reviewed, and
`workspaces/w1.json` for `T-1`), `$FIX/wt-t1` and `$FIX/other` (plain
directories). The synthetic non-temp cwd is `/Users/grg-test-user/proj`
(non-existent, outside every root, the same idiom rm_guard's cases use).

Drive: `printf '%s' "$payload" | env -u HERDR_WORKSPACE_ID HERDR_ENV=1
TMPDIR="$FIX/tmpdir" HOME="$FIX/home" CLAUDE_CONFIG_DIR="$FIX/cfg" [extra]
"$HOOK"`; a deny is exit 2, stdout empty, stderr exactly two lines, the
first starting `Blocked: `; an allow is exit 0 with empty stdout and
stderr. Gate cases use a separate runner that omits `HERDR_ENV=1`.

Deny cases (cwd `/Users/grg-test-user/proj` unless noted): bare
`git remote remove origin`; `remote rm`, `set-url`, `rename`, `prune`;
`( cd "" && git remote remove origin )`; `( cd "$repo" && git remote
remove origin )`; `git -C "$d" remote remove origin`; `-C` to a
non-existent temp path; `-C $FIX/tmpdir` (not a repo); `-C $FIX/esc`
(escape); `-C /Users/grg-test-user/proj`; `-C ""`; `sh -c 'git remote
remove origin'`; `env FOO=1 git remote remove origin`; `/usr/bin/git
remote remove origin`; `ls && git remote remove origin`; `git config
--unset remote.origin.url`; `git config remote.origin.url https://x`;
`--remove-section branch.main`; `--unset branch.main.remote`; `git config
core.hooksPath /x`; `--global core.sshCommand ssh`; `git config set
remote.origin.url x`; `git config unset core.hooksPath`; `--file
<non-temp>/.git/config remote.origin.url x`; `--unset "$key"`; `--local
remote.origin.url x`; `--git-dir=<non-temp>/.git remote remove origin`;
`git branch -D talon/T-1/x`; `--delete --force talon/T-1/x`; `-D
talon/T-3/x` (reviewed, unmerged); `-D refs/heads/talon/T-1/x`; `git
worktree remove $FIX/wt-t1`; `--force $FIX/wt-t1`; `remove wt-t1`
(suffix); `echo x >> .git/config`; `printf 'x\n' >>.git/info/exclude`;
`tee -a .git/config`; `sed -i '' 's/a/b/' .git/config`; `cp x
.git/config`; `echo x > <non-temp>/.git/config`; Write
`<non-temp>/.git/config`; Edit `<non-temp>/.git/info/exclude`; Write
`.git/config` (relative).

Allow cases: `git -C $FIX/repo remote remove origin`; `-C $FIX/repo remote
set-url origin x`; `-C $FIX/wt remote remove origin` (linked worktree
inside the root); `-C $FIX/repo/.git remote remove origin` (subdir of a
fixture); `cd $FIX/repo && git remote remove origin` (literal cd); bare
`git remote remove origin` with payload cwd `$FIX/repo`; `-C $FIX/repo
config remote.origin.url x`; `git config --file $FIX/tmpdir/cfg
remote.origin.url x`; `git remote add origin x`; `remote -v`; `remote
get-url origin`; `config --get remote.origin.url`; `config
remote.origin.url` (single positional read); `config --list`; `config get
remote.origin.url`; `config user.name x`; `git -c remote.origin.url=x
fetch --dry-run`; `branch --list`; `branch -D feature/other`; `branch -D
talon/T-2/x` (merged); `branch -D talon/T-1/x` with
`HERDR_WORKSPACE_ID=w1` (own task); `worktree remove --force $FIX/other`;
`worktree remove $FIX/wt-t1` with `HERDR_WORKSPACE_ID=w1`; `worktree
list`; `worktree prune`; `DOTFILES_ALLOW_GIT_META=1 git remote remove
origin`; `git commit -m 'docs: git remote remove origin'` (mention);
`grep -rn 'git remote remove' claude/`; `echo x >> .gitignore`; `echo x >>
$FIX/tmpdir/.git/config`; `sed -n 1p .git/config`; Write `$FIX/home/.gitconfig`;
Write `$FIX/tmpdir/r/.git/config`; Read `<non-temp>/.git/config`; an
empty command; `HERDR_ENV` unset; `HERDR_ENV=0`; malformed JSON (`not
json`); a payload whose `tool_input` is a string.

Read-only proof: a sha256 listing of every file under `$FIX/cfg` is
identical before and after a denied `git branch -D talon/T-1/x` and an
allowed `git branch -D talon/T-2/x`, and no `events.jsonl` or
`policy.jsonl` appears.

Static checks (skipped when `GIT_REMOTE_GUARD_HOOK` overrides the path):
the hook is executable with a `#!/usr/bin/env python3` shebang and
compiles (`py_compile` with `PYTHONPYCACHEPREFIX` under `$FIX`); the hook
has `^import rm_guard` and defines none of `tokenize`, `split_segments`,
`expand_braces`; the template has exactly one PreToolUse entry with
matcher `Bash|Edit|Write` and it lists exactly
`~/.claude/hooks/git_remote_guard.py`, and the Bash group still equals
the five-guard list above; `bin/dotfiles-tests` contains the line
`sh claude/hooks/git-remote-guard.test.sh`.

### D9. Denial message

Two stderr lines, exit 2:

```
Blocked: <what> (<reason>) -- <segment>.
Fixture repos only: pass a literal, existing path under ${TMPDIR:-/tmp} to git -C (resolve mktemp -d in a separate call; never cd into a variable that may be empty). With explicit user confirmation, prefix the command with DOTFILES_ALLOW_GIT_META=1.
```

`<what>` names the rule and command: `git remote remove rewrites the
shared .git/config of this checkout`, `git config write to
remote.origin.url rewrites the shared .git/config of this checkout`,
`git config --global/--system write to core.sshCommand edits the user's
git config`, `git branch delete of talon/T-1/x targets the branch of
orchestrated task T-1 (status in-progress)`, `git worktree remove of
wt-t1 targets the worktree of orchestrated task T-1 (status
in-progress)`, `redirection into .git/config edits git metadata shared by
every linked worktree`, `tee on .git/config edits git metadata shared by
every linked worktree`, `Write to /x/.git/config edits git metadata shared
by every linked worktree`. `<reason>` is the D4 reason when one applies.
`<segment>` is the offending segment's tokens joined by spaces, truncated
to 160 characters. The second line is constant so the fixture-path rule
is always present.

### D10. Accepted holes (documented in the hook docstring)

Aliases, functions, and script files; `eval`; `$(...)` and heredoc bodies
(a heredoc line that starts with `git remote remove origin` IS scanned as
a segment, the same way rm_guard scans heredoc lines, so prose containing
that command at line start in a Bash heredoc denies; write such prose with
the Write tool); `GIT_DIR=`/`GIT_WORK_TREE=` env assignments (stripped,
not interpreted); `xargs git ...` (the `xargs` prefix is stripped, so the
git invocation IS checked, but its stdin-fed arguments are not visible);
`git -C <dir>` where `<dir>` is a symlink into a real checkout is caught
by canonicalization, but a bind mount is not; TOCTOU between the
rev-parse and the executed command (needs a concurrent attacker with
filesystem control; every fixture root is throwaway); `cp`/`mv` source
detection (only the destination position matters and every non-option
token is checked, so a guarded file anywhere in the args denies, which is
a false positive only for `cp .git/config /tmp/backup`, itself a read).

### D11. Docs

- Repo `CLAUDE.md`, Architecture symlink list: one bullet for
  `claude/hooks/git_remote_guard.py` directly after the `scratch_policy.py`
  bullet, in the same shape (PreToolUse, matcher, what it denies, the
  fixture rule, the override, registered in the template, tested by the
  new suite, drift-checked by `claude-hooks.test.sh`).
- `claude/skills/post-merge/SKILL.md`, Step 3 code block: a two-line
  comment before `git worktree remove` stating that under herdr the guard
  denies these two teardown commands until the record reads `merged`, and
  that the confirmed teardown runs them with the `DOTFILES_ALLOW_GIT_META=1`
  prefix. No other post-merge change.

### D12. Suite registration and drift check

- `bin/dotfiles-tests`: one line, `sh claude/hooks/git-remote-guard.test.sh`,
  inserted directly after `sh claude/hooks/scratch-policy.test.sh`.
- `claude/hooks/claude-hooks.test.sh`: one static block appended at the end
  of the file, immediately before the final `printf '\n%d passed, %d
failed\n'`, in the style of the `hwg:` and `gate:` template checks: the
  template's PreToolUse list contains exactly one entry whose matcher is
  `Bash|Edit|Write`, its hooks list is exactly
  `["~/.claude/hooks/git_remote_guard.py"]`, and the Bash group is
  unchanged. Label `grg: template registers the git metadata guard under
Bash|Edit|Write`. The live drift check needs no edit (derived from the
  template). Nothing else in that file changes; the diff must have no
  removed lines.

## Files that may change

`claude/hooks/git_remote_guard.py` (new), `claude/hooks/git-remote-guard.test.sh`
(new), `claude/settings.json.tmpl`, `claude/hooks/claude-hooks.test.sh`
(append-only), `bin/dotfiles-tests` (one added line), `CLAUDE.md`,
`claude/skills/post-merge/SKILL.md`, and the contract
`claude/contracts/td-2026-09-07-guard-git-remote-and-config-mutations-in-worker-se-contract.json`
(committed with the plan). Nothing under `docs/` is merged.

## Acceptance criteria

1. AC1 Hook shape: `claude/hooks/git_remote_guard.py` is executable, has a
   `#!/usr/bin/env python3` shebang, compiles, imports rm_guard for
   parsing (no local `tokenize`/`split_segments`/`expand_braces`), and
   its docstring lists the D10 holes.
2. AC2 Gate: with `HERDR_ENV` unset or not `1`, every payload exits 0
   silently; with `HERDR_ENV=1`, bare `git remote remove origin` from a
   non-temp cwd exits 2 with the two-line D9 message naming
   `git remote remove origin` and `git -C`.
3. AC3 Incident shapes: `( cd "" && git remote remove origin )` and
   `( cd "$repo" && git remote remove origin )` deny; `git -C
<fixture repo> remote remove origin` allows; the linked-worktree escape
   denies.
4. AC4 Config: every D8 config deny and allow case behaves as listed.
5. AC5 Task records: every D8 branch/worktree case behaves as listed and
   the throwaway state root is byte-identical afterwards.
6. AC6 Files: every D8 Write/Edit/redirection/writer case behaves as
   listed; non-Bash, non-Write/Edit tools exit 0.
7. AC7 Override: `DOTFILES_ALLOW_GIT_META=1 git remote remove origin`
   allows; the deny message names the token.
8. AC8 Registration: the template carries the D2 entry and nothing else
   changed in `hooks`, `permissions`, or `env`; `reconcile_claude_settings_file`
   delivers the entry to a fresh settings file; `claude-hooks.test.sh`
   passes with the new `grg:` label and its diff is append-only;
   `scratch-policy.test.sh` still passes.
9. AC9 Suite: `sh claude/hooks/git-remote-guard.test.sh` under a sandbox
   `HOME` reports `N passed, 0 failed` with at least 90 PASS lines, is
   registered in `bin/dotfiles-tests` (one added line, no removed lines),
   contains no `cd`, asserts the mktemp root before use, and sets
   `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1` on fixture git
   calls.
10. AC10 Docs: `CLAUDE.md` names the hook, `PreToolUse`, `Bash|Edit|Write`,
    `DOTFILES_ALLOW_GIT_META`, and `git-remote-guard.test.sh`;
    `post-merge/SKILL.md` names `DOTFILES_ALLOW_GIT_META=1`.
11. AC11 Scope: the non-docs diff against `origin/main` touches exactly
    the files listed above; added lines are ASCII with no attribution
    strings (scan excludes `docs/` and `claude/contracts/`); every suite
    except public-safety is green and public-safety's only failure is the
    tracked-planning-artifacts one.

## Follow-ups (not in this task)

- Brief template and planner-contract rule: "fixture mutations only under
  an asserted mktemp root; never `cd "$var"` into a possibly-empty
  variable" (one line each) lives on `talon/claude-codex-parity`; add it
  when parity lands.
- Widen the gate to `permission_mode == auto` plain sessions if the
  incident class recurs outside herdr.
- `git push --delete` of a task branch (push_guard).
