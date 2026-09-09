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
  `show`, `get-url`, or `-v`: they do not delete the remote or its URL,
  and `remote add` is the documented recovery step.
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
- No shared-parser refactor. The hook imports rm_guard's tokenizer, prefix
  stripper, cd resolver, shell-wrapper extractor, and path helpers as-is
  (the same reuse `scratch_policy.py` does); nothing in rm_guard moves.
  The hook's own segment walk (D3) exists because rm_guard's
  `split_segments` drops parentheses and treats `);` as a word, which is
  exactly the scope bug this guard must not inherit.

## Confirmed facts (read at base `9ae3daf`, 2026-09-08)

- `rm_guard.py` exposes `tokenize`, `split_segments`, `strip_prefixes`,
  `basename`, `expand_home`, `resolve`, `resolve_cd_target`,
  `extract_shell_c_arg`, `has_glob_chars`, `SHELL_WRAPPERS`; its
  tokenizer keeps quoted text as one token (`"$repo"` becomes `$repo`,
  `""` becomes an empty token) and emits runs of `;&|()` and newline as
  operator tokens, so `(cd /x); git ...` tokenizes to `cd`, `/x`, `);`,
  `git`, ... and `split_segments` (which only recognizes tokens made solely
  of `;&|` plus bare `(`/`)`) keeps `);` as a word inside the `cd`
  segment. `scratch_policy.py` already imports rm_guard this way.
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
  `-C <path>` exists. `git remote` accepts `-v`/`--verbose` before its
  subcommand. `git worktree remove <worktree>` accepts a path or a unique
  trailing-component suffix of the path (git-worktree(1)). `git config`
  accepts both the option grammar (`--unset`, `--add`, `--remove-section`,
  ...) and, since 2.46, subcommands (`set`, `unset`, `get`, `list`,
  `remove-section`, `rename-section`, `edit`); subsection names may
  contain dots (`branch.release.1.remote`).
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
- Design prototype: every rule below was executed against the D8 suite
  in the session scratchpad (165 behavioral cases after two Codex spec
  reviews and one Codex plan review); 165 passed. A deny costs about 30 ms including the
  `git rev-parse` in D4.

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
JSON on stdin and dispatches on `tool_name`: `Bash` runs D3 to D7 on
`tool_input.command`; `Write` and `Edit` run D7 on `tool_input.file_path`;
every other tool exits 0. Deny is exit 2 with two stderr lines (D9); allow
is exit 0 with no output. Any exception exits 0 (fail open, the guard
convention in this directory). Malformed JSON, a missing or non-dict
`tool_input`, an empty command: exit 0.

### D3. Command walk (Bash)

`check_command(command, real_cwd, home, roots, home_real, cwds=None)`
tracks a SET of possible working directories, never a single one, because
a `cd` may be skipped, undone by a subshell, or fabricated by the
tokenizer. A mutation is allowed only when every possible directory is a
fixture (D4).

1. Quoted-operator rule. Scan the raw command text with a quote-aware
   state machine (single quotes, double quotes, backslash). If any
   character from `;&|()` or a newline appears inside quotes or after a
   backslash, the tokenizer would turn it into a fake segment boundary
   (`echo ';' cd /tmp/f; git ...` would fabricate a `cd` segment), so the
   possible-cwd set becomes the single non-literal sentinel
   `$UNTRUSTED_CWD`: every cd-derived exemption fails, explicit `git -C`
   still works, and the segment scan still runs.
2. `tokens = normalize_operators(rm_guard.tokenize(command))`: a token
   made only of characters from `;&|()` and newline is split into bare
   `(` and `)` tokens and maximal runs of `;&|` or newline (so `);`
   becomes `)`, `;`; `&&` and `||` stay whole); then a `|` operator that
   directly follows a word token `>` is merged back into the word `>|`
   (the tokenizer splits the clobber redirection at the pipe). Every other
   token is untouched.
3. Walk the tokens into segments. Operators (`;`, newline, `&&`, `||`,
   `|`, `&`) terminate a segment; `(` and `)` open and close a subshell
   scope; end of input terminates the last segment. Chains: a chain is
   the run of segments between unconditional boundaries (`;`, newline,
   `&`, `(`, `)`, start, end); inside a chain, segments are joined by
   `&&`, `||`, or `|`. Per chain keep: `start` (the possible-cwd set when
   the chain began), `first_cd` (the target of a `cd` that is the chain's
   first segment, which always runs), `cds` (targets of later `cd`s in
   the chain, which may be skipped), and `pure` (true while every joiner
   seen so far in the chain is `&&`).
   - The possible-cwd set for a segment is: if `pure`, the single latest
     `cd` target in the chain (`cds[-1]`, else `first_cd`, else `start`);
     if not `pure`, `start` (or `{first_cd}` when the chain opened with a
     cd) united with every target in `cds`. Rationale: in a pure `&&`
     chain a segment that runs implies every earlier segment ran; after
     any `||`, earlier `cd`s may have been skipped.
   - At an unconditional boundary the next chain's `start` is the
     not-pure formula (`false && cd X; git ...` leaves both the original
     cwd and `X` possible; `cd X; git ...` leaves only `X`).
   - `(` saves the chain state and opens a new chain whose `start` is the
     current segment's possible set; `)` restores the saved chain (a
     subshell's `cd` never leaks; the subshell counts as one non-first
     segment of the outer chain).
   - A `cd` segment records its target only when its terminator is not
     `|` or `&` (a `cd` in a pipeline or a background job runs in its own
     subshell). Target: `resolve_cd_target` for an argument (so `cd ""`
     resolves to the current directory and `cd "$repo"` to the literal
     `<cwd>/$repo`, non-literal), HOME for a bare `cd`, the sentinel for
     `cd -`. When the segment's possible set has more than one member or
     a non-literal member, the target is the sentinel.
   - Taint: once any segment's head is `ln`, `mv`, `cp`, or `rsync`, or
     is `git` with subcommand `worktree add|move|repair`, every later
     mutation in the same command is denied with reason "an earlier
     segment can re-point the fixture path before git runs; run it as a
     separate call" (a same-command `ln -sfn <real> <fixture-link>` would
     otherwise invalidate a check that already passed). Taint is sticky
     across `)`, chain boundaries, and `sh -c` wrappers in both directions
     (raised inside a wrapper it reaches the caller; raised before a
     wrapper it reaches the script), and it is raised by an overridden
     segment too. Under taint the temp-root exemption of D7 is withdrawn
     as well: a redirection or writer into any path matching the guarded
     pattern denies, even under a root.
4. Per segment, in this order:
   a. `stripped = rm_guard.strip_prefixes(raw)`; the override (D6) is
      present only when `DOTFILES_ALLOW_GIT_META=1` is among the tokens
      strip_prefixes removed (the leading assignments and wrappers), never
      after the head. A `cd` head records its target (step d) and a taint
      head raises taint BEFORE the override is consulted: the override
      suppresses denials, never shell-state tracking
      (`DOTFILES_ALLOW_GIT_META=1 cd <real>; git remote remove origin`
      denies). Override present: the segment is allowed, including its
      redirections, and a wrapper segment is not descended into.
   b. Redirection scan (D7) on the raw tokens, whatever the head is
      (`git status > .git/config` and `sh -c true > .git/info/exclude`
      deny).
   c. Empty `stripped`: done.
   d. Head `cd`: record the target as above; done.
   e. Head in `SHELL_WRAPPERS` (`sh`, `bash`, `zsh`): recurse into the
      `-c` argument with the current possible set as its initial set; the
      inner script has its own segments, chains, and override positions.
   f. Head `git` (by basename, so `/usr/bin/git` counts): D4 and D5.
   g. Any other head: the writer check of D7.
   The first denial wins. Chain bookkeeping applies to every terminator,
   including one that follows `)` with no pending segment: the `;` in
   `false && cd X && (true); git ...` ends the chain, so `git` sees both
   the original cwd and `X` and denies.

### D4. Git invocation parsing and the fixture exemption

`parse_git(tokens)` walks git's global options to find the subcommand:
`-C <path>` values are collected in order; `-c`, `--namespace`,
`--config-env`, `--attr-source`, `--super-prefix` consume one value;
`--git-dir`, `--work-tree` (separate or `=` form) set a location-hint
flag. A fixed table of known valueless globals (`--no-pager`,
`--paginate`, `-p`/`-P`, `--bare`, `--no-optional-locks`,
`--literal-pathspecs`, and similar) is skipped in place, since none of
them can shift a later value into the subcommand position. Any other
`-`-prefixed token given as a separate argument is unrecognized and
indistinguishable from a value-taking option whose value would
otherwise be misread as the subcommand, so it fails closed instead of
guessing. The first non-option token is the subcommand; the rest are
its args.

Effective directories: for every member of the segment's possible-cwd
set, apply each `-C` value in order with `resolve(expand_home(value,
home), current)`; an empty `-C ""` is a no-op (as in git). A `-C` value
containing `$`, a backtick, or a glob character: reason "working
directory contains an unexpanded variable or glob"; a non-literal member
(the sentinel): reason "working directory cannot be established
(unexpanded variable, quoted operator, or cd -)". Every effective
directory must pass `fixture_dir`; the first failure is the reason.

A mutating shape (D5 R1, R2) that carries a location hint is denied with
reason "--git-dir/--work-tree forms are not accepted; use git -C": the
fixture idiom is `git -C`, and a hint can select metadata the cwd probe
below would not see. The hint check and the taint check (D3) run before
every exemption, the `--file` exemption of R2 included.

Temp roots: `realpath($TMPDIR)` when `TMPDIR` is set and absolute and not
`/`, HOME, an ancestor of HOME, or shallower than two components; plus
`realpath("/tmp")` always. `under_root(c)` returns the matching root when
`c` starts with `root + "/"`, except that a path equal to or under
`realpath(HOME)` is never under a root, whatever the roots are: a checkout
under HOME is real by definition (`~/Git/...`), and this is also what lets
the suite build a "real" repository hermetically (D8).

`fixture_dir(path)` returns None (fixture) or a reason string:

1. `c = canon(path)` (realpath of the longest existing ancestor joined
   with the rest, as in scratch_policy).
2. `c` must be under a root: else reason "targets a checkout outside every
   temp root".
3. `c` must exist as a directory: else reason "fixture path does not exist
   yet (resolve mktemp -d in a separate call)". Deliberate: a path that
   does not exist at hook time cannot be proven a fixture, and allowing it
   would open `git worktree add /tmp/wt && git -C /tmp/wt remote remove
origin`, which mutates the real repo's shared config through a linked
   worktree created moments earlier.
4. `git -C <c> rev-parse --path-format=absolute --git-common-dir`, run
   with `GIT_CEILING_DIRECTORIES=<the matched root>`,
   `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, and `GIT_DIR`,
   `GIT_WORK_TREE`, `GIT_COMMON_DIR` removed from the environment, 5 s
   timeout. Non-zero exit, timeout, or launch failure: reason "fixture
   path is not inside a repository under the temp root". The printed
   common dir, canonicalized, must also be under a root: else reason
   "fixture path is a linked worktree whose .git lives outside the temp
   root". This closes the linked-worktree escape (a gitfile under a root
   whose `gitdir:` resolves into a real checkout).

The exemption is evaluated only for the mutating shapes in D5; reads and
unguarded subcommands never reach it, so they never pay the rev-parse.

### D5. Mutating git shapes

Rule R1, remotes. Subcommand `remote`; skip leading `-`-prefixed args
(`-v`, `--verbose`); the first remaining arg is the remote subcommand.
`remove`, `rm`, `set-url`, `rename`, `prune`: mutation. Deny unless the
effective directory is a fixture (D4). The remote name is irrelevant (an
unexpanded `"$r"` still denies).

Rule R2, config writes. Subcommand `config`. `config_action(args)`
walks the args against fixed option tables and returns `(kind, keys,
section_level, scope_outside, file_path, unknown_option)`:

- value-taking long options, consumed with their value in both the
  `--opt value` and `--opt=value` spellings: `--file`, `--blob`, `--type`,
  `--default`, `--comment`, `--value`, `--url`; `--file` in either
  spelling sets the file path;
- short `-f`, as `-f value` or glued `-fvalue`: sets the file path;
- read options that take one value: `--get-color`, `--get-colorbool`;
- `--global` or `--system`: scope outside the repo;
- write options: `--add`, `--replace-all`, `--unset`, `--unset-all`,
  `--remove-section`, `--rename-section`, `--edit`, `-e`; the two
  section options also set section_level;
- read options: `--get`, `--get-all`, `--get-regexp`, `--get-urlmatch`,
  `--list`, `-l`;
- known flags, skipped: `--local`, `--worktree`, `--bool`, `--int`,
  `--bool-or-int`, `--bool-or-str`, `--path`, `--expiry-date`,
  `--fixed-value`, `--all`, `--append`, `--includes`, `--no-includes`,
  `--null`, `-z`, `--name-only`, `--show-origin`, `--show-scope`,
  `--show-names`, `--no-show-names`, `--`;
- any other `-`-prefixed token sets unknown_option (fail closed: an
  option the tables do not know could be consuming the token the walk
  would otherwise take as the key);
- positionals collected in order; a leading positional `set`, `unset`,
  `remove-section`, `rename-section`, or `edit` makes it a write (the two
  section verbs set section_level) and is dropped; a leading `get` or
  `list` makes it a read and is dropped;
- with no explicit action: two or more positionals is a write (`git config
  <key> <value>`), otherwise a read;
- keys: the first two positionals for a section-level action (rename
  names old and new), else the first positional.

A write is guarded when unknown_option is set, or it has no key at all
(`--edit`, `-e`, `edit`: a whole-file write), or any key is not literal
(unexpanded variable), or any key matches, case-insensitively:

- key-level: `^(remote(\..*)?|core(\..*)?|branch\..+\.(remote|merge|pushremote))$`
  (every `remote.*` key, every `core.*` key, and a branch's `remote`,
  `merge`, or `pushremote` for any branch name, dots included);
- section-level: `^(remote(\..*)?|core|branch\..+)$` (removing or renaming
  a remote, core, or any branch section).

Other keys (`user.name`, `branch.x.description`, ...) with only known
options are never guarded.

For a guarded write: `--global`/`--system` denies always (reason "edits
the user's git config"); a `--file` path denies unless literal and, for
every possible cwd, canonicalized under a root (D4's `under_root`, so a
file under HOME denies); otherwise the effective-directory rule of D4
applies (`--local`, `--worktree`, and the default scope all mean "this
checkout"). The key-less `--edit` forms follow the same three branches.

`git -c key=value <cmd>` is a per-invocation override, not a write, and is
never guarded.

Rule R3, another task's branch or worktree. Read-only lookup over
`STATE_ROOT/<slug>/tasks/<task_id>.json` for every slug (basename minus
`.json` must satisfy `valid_task_id`, which excludes every sidecar;
symlinks and non-object JSON skipped; any read error skips the record).
The session's own task is the pair `(repo_slug, task_id)` read from the
workspace index that `HERDR_WORKSPACE_ID` resolves to (`read_index`
across slugs, sorted-first, exactly as scratch_policy's `log_allow`);
no index means no own-task exemption. A record is _protected_ when its
`status` is not in `{"merged", "failed", "abandoned"}` and `(slug,
task_id)` is not the own pair. Protection is deliberately cross-slug: a
branch name in flight in any orchestrated repo is protected everywhere
(the false positive is a same-named branch in an unrelated repo, which
the override covers), while the exemption is slug-scoped so a same-named
task id in another repo never exempts.

- `git branch` with a delete flag (`-d`, `-D`, `--delete`, or a bundled
  short group containing `d` or `D`): every positional is a branch name;
  strip a `refs/heads/` prefix; deny when it equals a protected record's
  `branch`. A non-literal name (`"$branch"`) denies whenever at least one
  protected record carries a branch (reason names the count), since it
  could be any of them.
- `git worktree remove [--force ...] <worktree>`: every positional is a
  target; deny when its canonical path (resolved against any possible
  cwd) equals a protected record's canonical `worktree`, or when the
  token is relative and the record's canonical worktree ends with
  `/<token>` (git's trailing-component form), or when the token is
  relative and the possible-cwd set contains the sentinel. A non-literal
  token denies whenever at least one protected record carries a
  worktree.

R3 never consults D4: a task worktree under `/tmp` is still another
task's worktree.

Rule R4 is D7 (files). Every other git subcommand allows.

### D6. Override

`DOTFILES_ALLOW_GIT_META=1` as a leading env assignment of a segment
(among the tokens `strip_prefixes` removes: before the head, possibly
after `env`) allows that segment through every rule, redirections
included (`DOTFILES_ALLOW_GIT_META=1 echo x > .git/config` and
`DOTFILES_ALLOW_GIT_META=1 tee .git/config` are treated alike). It is not an
override when it appears after the head (a config value, a trailing
argument), and it does not carry to an adjacent segment. A wrapper
segment led by the override is allowed without descending into its
script; a script inside `sh -c` may carry its own override on its own
segments. The denial names the token and states the condition: explicit
user confirmation in conversation, never added by the model on its own.
Consumers: `/post-merge` Step 3 under herdr (the record may still read
`reviewed`), and a human-confirmed `git remote set-url` in an
orchestrator session. Precedent: push_guard's `DOTFILES_ALLOW_FORCE_PUSH=1`.

### D7. Guarded files (Write, Edit, and Bash writers)

A path is a guarded file when, for some member of the possible-cwd set
(the payload cwd for Write/Edit), after `expand_home` and `resolve`
against it, EITHER the resolved path OR its canonical form (`canon`, which
follows symlinks in every existing component, the final one included)
matches `(^|/)\.git/(config|info/exclude)$`, and the canonical form is not
under a root (D4's `under_root`, HOME excluded). So `/tmp/config-link`
symlinked to a real checkout's `.git/config`, and `/tmp/repo-link/.git/
config` through a symlinked directory, are both guarded. Non-literal
paths are never matched (an unexpanded variable in a file path cannot be
resolved, and Write/Edit paths are literal by construction); a resolution
against the sentinel cwd uses `/` as the base, which only matters for
relative paths.

- Tools `Write` and `Edit`: deny when `tool_input.file_path` is a guarded
  file. `Read`, `NotebookEdit`, and everything else: exit 0. The documented
  flows that touch `.git/info/exclude` (`bin/setup-claude`, the todos
  script `todos.sh`) are shell scripts invoked by name, never Write/Edit
  calls, so nothing legitimate is caught.
- Bash, every segment, before head dispatch (D3 step 3a): a redirection
  token (`>`, `>>`, `>|`, `1>`, `2>`, `1>>`, `2>>`, `&>`, `&>>`) followed
  by a guarded file, or a token gluing one of those to a guarded file
  (`>>.git/config`). The tokenizer does not split on `>`, so the glued
  form is one token and the spaced form is two adjacent tokens; `&>`
  splits at `&` and the `>` starts the next segment, which the same scan
  catches.
- Bash, heads `tee`, `cp`, `mv`, `truncate`, or `sed` with an in-place
  flag (`-i...` short, `--in-place[=...]`): any non-option token that is a
  guarded file.

### D8. Test suite: `claude/hooks/git-remote-guard.test.sh`

Hermetic, payload-driven, modelled on `scratch-policy.test.sh`: POSIX sh,
`PASS`/`FAIL` lines, `N passed, N failed` trailer, non-zero exit on any
failure, `PYTHONDONTWRITEBYTECODE=1`, the hook path overridable through
`GIT_REMOTE_GUARD_HOOK` (static checks skip when it is overridden).

Fixture safety, enforced by the suite's own shape and by a contract text
scan:

- one mktemp root `FIX=$(mktemp -d /tmp/git-remote-guard.XXXXXX)`
  asserted with `[ -n "$FIX" ] && [ -d "$FIX" ]` before any use, removed
  by a trap;
- every fixture git call goes through one helper, `g()`, which runs
  `env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"` only after
  checking its repository argument: `-C <path>` or `init [-q] <path>`
  with the path under `$FIX`, anything else prints a FAIL line and exits
  1 before git runs; the suite proves the abort once, in a subshell
  (`( g -C /Users/grg-test-user/proj status )` fails);
- no executed `cd` anywhere in the file: the two-character word `cd`
  followed by a space may appear only inside a payload string on a case
  line (a line starting with the case helper's name). The contract scan
  is: every line matching `(^|[;&|(]|[[:space:]])cd[[:space:]]` must start
  with the case helper name;
- no `git remote` or `git config` mutation outside `$FIX`.

Fixtures: `$FIX/repo` (a real repo with an `origin` remote and one
commit), `$FIX/wt` (a linked worktree of `$FIX/repo`), `$FIX/esc` (a
directory whose `.git` is a gitfile reading
`gitdir: /Users/grg-test-user/proj/.git/worktrees/esc`, the
discovery-failure shape), `$FIX/tmpdir` (the per-case `TMPDIR`),
`$FIX/home` (the hook's `HOME`), `$FIX/home/proj` (a real repo with a
remote and one commit; under HOME, so outside every root by D4),
`$FIX/tmpdir/wt-esc` (a linked worktree of `$FIX/home/proj`: under a root
while its common dir is not, the true containment escape),
`$FIX/tmpdir/config-link` (a symlink to `$FIX/home/proj/.git/config`) and
`$FIX/tmpdir/repo-link` (a symlink to `$FIX/home/proj`), `$FIX/cfg` (a
throwaway `CLAUDE_CONFIG_DIR` holding `herdr-orch/slug-x/tasks/T-1.json`
in-progress with branch `talon/T-1/x` and worktree `$FIX/wt-t1`,
`T-2.json` merged, `T-3.json` reviewed, `herdr-orch/slug-y/tasks/T-1.json`
in-progress with branch `talon/T-1/y`, and `slug-x/workspaces/w1.json`
for `T-1`), `$FIX/wt-t1` and `$FIX/other` (plain directories). The
synthetic non-temp cwd is `/Users/grg-test-user/proj` (non-existent,
outside every root, the idiom rm_guard's cases use).

Drive: `printf '%s' "$payload" | env -u HERDR_WORKSPACE_ID HERDR_ENV=1
TMPDIR="$FIX/tmpdir" HOME="$FIX/home" CLAUDE_CONFIG_DIR="$FIX/cfg" [extra]
"$HOOK"`; a deny is exit 2, stdout empty, stderr exactly two lines, the
first starting `Blocked: `; an allow is exit 0 with empty stdout and
stderr. Gate cases use a second runner that unsets `HERDR_ENV` instead of
setting it.

Deny cases (cwd `/Users/grg-test-user/proj` unless noted): bare
`git remote remove origin`; `remote rm`, `set-url`, `rename`, `prune`;
`remote -v remove origin`; `remote --verbose remove origin`;
`( cd "" && git remote remove origin )`; `( cd "$repo" && git remote
remove origin )`; `( cd $FIX/repo ); git remote remove origin` and the
glued `(cd $FIX/repo); ...` (subshell scope); `cd $FIX/repo | git remote
remove origin` (pipeline); `cd $FIX/repo & git remote remove origin`
(background); `cd $FIX/tmpdir/missing; git remote remove origin`; `git -C
"$d" remote remove origin`; `-C` to a non-existent temp path; `-C
$FIX/tmpdir` (not a repo); `-C $FIX/esc` (discovery failure); `-C
$FIX/tmpdir/wt-esc` (containment escape, and the first stderr line
contains `linked worktree whose .git lives outside the temp root`); `-C
$FIX/home/proj` (under HOME); `-C /Users/grg-test-user/proj`; `-C ""`;
`sh -c 'git remote remove origin'`; `env FOO=1 git remote remove origin`;
`/usr/bin/git remote remove origin`; `ls && git remote remove origin`;
`git config remote.origin.url DOTFILES_ALLOW_GIT_META=1` (token as a
value); `git remote remove origin DOTFILES_ALLOW_GIT_META=1` (trailing);
`DOTFILES_ALLOW_GIT_META=1 true; git remote remove origin` (adjacent
segment); `git config --unset remote.origin.url`; `git config
remote.origin.url https://x`; `--remove-section branch.main`;
`--remove-section branch.release.1`; `--rename-section foo branch.main`;
`--unset branch.main.remote`; `--unset branch.release.1.remote`; `git
config core.hooksPath /x`; `--global core.sshCommand ssh`; `git config set
remote.origin.url x`; `git config unset core.hooksPath`; `git config
--edit`; `git config -e --global`; `git config edit`; `--file
<non-temp>/.git/config remote.origin.url x`; `--unset "$key"`; `--local
remote.origin.url x`; `--git-dir=<non-temp>/.git remote remove origin`;
`-C $FIX/repo --git-dir $FIX/wt/.git remote remove origin` (hint under a
root still denies); `--work-tree=$FIX/repo remote remove origin`; `git
branch -D talon/T-1/x`; `--delete --force talon/T-1/x`; `-D talon/T-3/x`
(reviewed, unmerged); `-D refs/heads/talon/T-1/x`; `-D talon/T-1/y` with
`HERDR_WORKSPACE_ID=w1` (same task id, other slug); `git worktree remove
$FIX/wt-t1`; `--force $FIX/wt-t1`; `remove wt-t1` (suffix); `echo x >>
.git/config`; `printf 'x\n' >>.git/info/exclude`; `git status >
.git/config`; `cd . > .git/config`; `sh -c true > .git/info/exclude`;
`tee -a .git/config`; `sed -i '' 's/a/b/' .git/config`; `cp x
.git/config`; `echo x > <non-temp>/.git/config`; Write
`<non-temp>/.git/config`; Edit `<non-temp>/.git/info/exclude`; Write
`.git/config` (relative); Write `$FIX/home/proj/.git/config`; Write
`$FIX/tmpdir/config-link`; `tee $FIX/tmpdir/config-link`; `echo x >>
$FIX/tmpdir/repo-link/.git/config`; `git -C $FIX/tmpdir/repo-link remote
remove origin`; `false && cd $FIX/repo; git remote remove origin`
(skipped cd); `true || cd $FIX/repo; git remote remove origin`; `mkdir -p
$FIX/tmpdir/x && cd $FIX/repo; git remote remove origin`; `cd; git remote
remove origin` with cwd `$FIX/repo` (bare cd goes home); `cd -; git
remote remove origin` with cwd `$FIX/repo`; `echo ';' cd $FIX/repo; git
remote remove origin` and the backslash form `echo \; cd ...` (quoted
operator); `git config set --value old core.hooksPath /x`; `git -C
$FIX/repo config -f<non-temp>/.git/config core.hooksPath /x` (glued);
`git -C $FIX/repo config --file=<non-temp>/.git/config core.hooksPath
/x`; `git config --frobnicate x user.name y` (unknown option); `git branch
-D "$branch"`; `git worktree remove "$wt"`; `echo x >| .git/config` and
the glued `>|.git/config`; `ln -sfn $FIX/home/proj $FIX/tmpdir/link; git
-C $FIX/repo remote remove origin` (taint); `git -C $FIX/repo worktree
add $FIX/tmpdir/wt2 && git -C $FIX/repo remote remove origin` (taint);
`false && cd $FIX/repo && (true); git remote remove origin` (chain ends
after the subshell); `ln -sfn $FIX/home/proj $FIX/tmpdir/link2; sh -c
'git -C $FIX/repo remote remove origin'` and `sh -c 'ln -sfn ...'; git -C
$FIX/repo remote remove origin` (taint across wrappers); `ln -sfn
$FIX/home/proj/.git/config $FIX/tmpdir/cfg; git config --file
$FIX/tmpdir/cfg remote.origin.url x`, `ln -sfn $FIX/home/proj
$FIX/tmpdir/link2; echo x >> $FIX/tmpdir/link2/.git/config`, and the
`tee` form (taint withdraws the temp-root exemption); `git
--git-dir=<non-temp>/.git config --file $FIX/tmpdir/cfg remote.origin.url
x` (hint before the file exemption); `DOTFILES_ALLOW_GIT_META=1 cd
$FIX/home/proj; git remote remove origin` with cwd `$FIX/repo` (an
overridden cd still moves); the first line of the `echo x >> .git/config`
denial contains `-- echo x >> .git/config`.

Allow cases: `git -C $FIX/repo remote remove origin`; `-C $FIX/repo remote
set-url origin x`; `-C $FIX/wt remote remove origin` (linked worktree
inside the root); `-C $FIX/repo/.git remote remove origin`; `cd $FIX/repo
&& git remote remove origin`; `cd $FIX/repo; git remote remove origin`;
`( cd $FIX/repo && git remote remove origin )`; bare `git remote remove
origin` with payload cwd `$FIX/repo`; `-C $FIX/repo config
remote.origin.url x`; `git config --file $FIX/tmpdir/cfg remote.origin.url
x`; `git remote add origin x`; `remote -v`; `remote get-url origin`;
`config --get remote.origin.url`; `config remote.origin.url` (single
positional read); `config --list`; `config get remote.origin.url`;
`config user.name x`; `config branch.main.description x`; `git -c
remote.origin.url=x fetch --dry-run`; `branch --list`; `branch -D
feature/other`; `branch -D talon/T-2/x` (merged); `branch -D talon/T-1/x`
with `HERDR_WORKSPACE_ID=w1` (own task); `worktree remove --force
$FIX/other`; `worktree remove $FIX/wt-t1` with `HERDR_WORKSPACE_ID=w1`;
`worktree list`; `worktree prune`; `DOTFILES_ALLOW_GIT_META=1 git remote
remove origin`; `env DOTFILES_ALLOW_GIT_META=1 git remote remove origin`;
`sh -c 'DOTFILES_ALLOW_GIT_META=1 git remote remove origin'`;
`DOTFILES_ALLOW_GIT_META=1 sh -c 'git remote remove origin'`; `git commit
-m 'docs: git remote remove origin'` (mention); `grep -rn 'git remote
remove' claude/`; `echo x >> .gitignore`; `echo x >>
$FIX/tmpdir/.git/config`; `sed -n 1p .git/config`; Write
`$FIX/home/.gitconfig`; Write `$FIX/tmpdir/r/.git/config`; Read
`<non-temp>/.git/config`; an empty command; `DOTFILES_ALLOW_GIT_META=1
echo x > .git/config`; `DOTFILES_ALLOW_GIT_META=1 tee .git/config`;
`mkdir -p $FIX/tmpdir/x && cd $FIX/repo && git remote remove origin`
(pure chain); `cd $FIX/repo; cd $FIX/wt; git remote remove origin`;
`false && cd $FIX/repo && git remote remove origin` (git runs only after
the cd); `echo ';' && git -C $FIX/repo remote remove origin` (quoted
operator, explicit -C); `git commit -m 'a; b' && git status`; `git -C
$FIX/repo config set --value old core.hooksPath /x`; `git branch -D
"$branch"` with an empty `CLAUDE_CONFIG_DIR` (no protected records); `git
-C $FIX/repo remote remove origin; ln -s a b` (a later taint does not
reach an earlier segment); `HERDR_ENV` unset; `HERDR_ENV=0`; malformed
JSON (`not json`); a payload whose `tool_input` is a string.

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
remote.origin.url rewrites the shared .git/config of this checkout` (key
`(whole file)` for the edit forms), `git config --global/--system write to
core.sshCommand edits the user's git config`, `git config --file write to
<key> targets a config outside the temp root`, `git branch delete of
talon/T-1/x targets the branch of orchestrated task T-1 (status
in-progress)`, `git worktree remove of wt-t1 targets the worktree of
orchestrated task T-1 (status in-progress)`, `redirection into
.git/config edits git metadata shared by every linked worktree`, `tee on
.git/config edits git metadata shared by every linked worktree`, `Write
to /x/.git/config edits git metadata shared by every linked worktree`.
`<reason>` is the D4 reason when one applies (omitted with its
parentheses otherwise). `<segment>` is the offending segment's tokens
joined by spaces, truncated to 160 characters, present on every Bash
denial (redirections and writers included); a Write/Edit denial names the
tool and path instead. The second line is constant
so the fixture-path rule is always present.

### D10. Accepted holes (documented in the hook docstring)

Aliases, functions, and script files; `eval`; `$(...)` and heredoc bodies
(a heredoc line that starts with `git remote remove origin` IS scanned as
a segment, the same way rm_guard scans heredoc lines, so prose containing
that command at line start in a Bash heredoc denies; write such prose with
the Write tool); `GIT_DIR=`/`GIT_WORK_TREE=` env assignments (stripped by
`strip_prefixes`, not interpreted); `xargs git ...` (the `xargs` prefix is
stripped, so the git invocation IS checked, but its stdin-fed arguments
are not visible); shell control-flow keywords (`if`, `for`, `{ }`) are
plain words to the walk, so a `cd` inside a `{ ...; }` group leaks like a
plain `cd` (groups run in the current shell, so that is also the shell's
behavior); a bind mount into a real checkout (symlinks are caught by
canonicalization); a same-command re-point of a fixture path by a tool
other than `ln`/`mv`/`cp`/`rsync`/`git worktree` (for example `python3 -c
"os.symlink(...)"`), and a concurrent re-point by another process between
the rev-parse and the executed command (every fixture root is throwaway);
`cd` reachability through `if`/`case`/`for` bodies (the walk only models
`&&`, `||`, `;`, subshells, pipelines, and background jobs); `cp`/`mv` source detection (every non-option token is
checked, so `cp .git/config /tmp/backup`, itself a read, denies).

### D11. Docs

- Repo `CLAUDE.md`, Architecture symlink list: one bullet for
  `claude/hooks/git_remote_guard.py` directly after the `scratch_policy.py`
  bullet, in the same shape (PreToolUse, matcher `Bash|Edit|Write`, the
  HERDR_ENV gate, what it denies, the fixture rule, the override
  `DOTFILES_ALLOW_GIT_META=1`, registered in the template, tested by
  `git-remote-guard.test.sh`, drift-checked by `claude-hooks.test.sh`).
- `claude/skills/post-merge/SKILL.md`, Step 3 code block: the two
  teardown commands become `DOTFILES_ALLOW_GIT_META=1 git worktree remove
"<wt>" 2>/dev/null \` and `DOTFILES_ALLOW_GIT_META=1 git branch -D
"<headRefName>"`, preceded by a two-line comment: in a herdr session the
  git metadata guard denies deleting a task's worktree or branch while its
  record is not yet `merged`; the Step 2 confirmation is the explicit
  confirmation the override requires. No other post-merge change.

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
   `( cd "$repo" && git remote remove origin )` deny; `( cd <fixture> );
   git remote remove origin`, `false && cd <fixture>; git remote remove
   origin`, and the quoted-operator shape deny; `git -C <fixture repo>
   remote remove origin` and `cd <fixture> && git remote remove origin`
   allow; the containment escape (`$FIX/tmpdir/wt-esc`) denies with the
   linked-worktree reason; the symlink aliases and the taint shapes deny.
4. AC4 Config: every D8 config deny and allow case behaves as listed.
5. AC5 Task records: every D8 branch/worktree case behaves as listed and
   the throwaway state root is byte-identical afterwards.
6. AC6 Files: every D8 Write/Edit/redirection/writer case behaves as
   listed; non-Bash, non-Write/Edit tools exit 0.
7. AC7 Override: the D8 override allow cases allow and the override deny
   cases (value, trailing, adjacent segment) deny; the deny message names
   the token.
8. AC8 Registration: the template carries the D2 entry and nothing else
   changed in `hooks`, `permissions`, or `env`; `reconcile_claude_settings_file`
   delivers the entry to a fresh settings file; `claude-hooks.test.sh`
   passes with the new `grg:` label and its diff is append-only;
   `scratch-policy.test.sh` still passes.
9. AC9 Suite: `sh claude/hooks/git-remote-guard.test.sh` under a sandbox
   `HOME` reports `N passed, 0 failed` with at least 160 PASS lines, is
   registered in `bin/dotfiles-tests` (one added line, no removed lines),
   has no executed `cd` (D8 scan), asserts the mktemp root before use,
   and routes every fixture git call through the env-isolating `g()`.
10. AC10 Docs: `CLAUDE.md` names the hook, `PreToolUse`, `Bash|Edit|Write`,
    `HERDR_ENV`, `DOTFILES_ALLOW_GIT_META`, and `git-remote-guard.test.sh`;
    `post-merge/SKILL.md` Step 3 contains both prefixed teardown commands.
11. AC11 Scope: the non-docs diff against `origin/main` touches exactly
    the files listed above; added lines are ASCII with no attribution
    strings (scan excludes `docs/` and `claude/contracts/`); every suite
    except public-safety is green and public-safety's only failure is the
    tracked-planning-artifacts one.

## Review resolution (Codex spec review, round 1, 2026-09-08)

Verdict was needs-rework with 13 findings. Applied: 1 (subshell and
pipeline cwd scope, D3), 2 (override position and wrapper semantics, D3
and D6), 3 (redirection scan on every head, D3/D7), 4 (location hints,
resolved by denying `--git-dir`/`--work-tree` mutations outright, D4), 5
(`git remote -v remove`, R1), 6 (dotted branch names, R2), 7 (key-less
`--edit`, R2), 8 (fixture env isolation, D8), 9 (slug-scoped own-task
exemption, R3), 10 (a true containment escape fixture through the HOME
exclusion, D4/D8), 11 (executed-`cd` scan definition, D8), 12 (executable
post-merge teardown lines, D11). Not applied: 13 (untracked planning
artifacts): branch-only tracked specs and plans are this repo's
established orchestration convention and the task instruction requires
committing them; the public-safety failure is the documented expected
one. Side finding from Codex's probe: rm_guard's `split_segments` treats
`);` as a word, so `(cd /x); rm -rf /` hides the `rm` from rm_guard; filed
under Follow-ups, not fixed here.

## Review resolution (Codex spec review, round 2, 2026-09-08)

Verdict was needs-rework with 8 findings, all applied: 1 (conditional and
bare `cd`: the possible-cwd set and chain purity model, D3), 2 (quoted
operators fabricating segments: the quoted-operator rule, D3), 3
(`--value`, glued `-f`, `--file=`, and unknown options fail closed, R2),
4 (non-literal branch/worktree targets, R3), 5 (symlink aliases of
guarded files, D7), 6 (same-command re-pointing: the taint rule, D3, with
the residual narrowed in D10), 7 (`>|` tokenization, D3 step 2), 8
(override covers redirections, D6/D3). Per the review skill's two-round
cap, no third spec round was run; the plan review is the next external
gate.

## Review resolution (Codex plan review, 2026-09-08)

The plan review (frozen artifact, Codex reviewer route) returned 7
findings against the plan's embedded code; the design rules they exposed
are now stated here so spec and code agree: chain bookkeeping on empty
segments (D3), taint across `sh -c` wrappers and under override (D3),
hint and taint checks before the `--file` exemption (D4), taint
withdrawing the temp-root file exemption (D7), the segment suffix on
every Bash denial (D9), and the `g()` argument guard (D8). The seventh
finding (verification loops exiting 0) is plan-only.

## Follow-ups (not in this task)

- Brief template and planner-contract rule: "fixture mutations only under
  an asserted mktemp root; never `cd "$var"` into a possibly-empty
  variable" (one line each) lives on `talon/claude-codex-parity`; add it
  when parity lands.
- rm_guard: normalize operator runs (`);`) before segment splitting so a
  subshell close cannot hide an `rm`; D3's walk is the reference.
- Widen the gate to `permission_mode == auto` plain sessions if the
  incident class recurs outside herdr.
- `git push --delete` of a task branch (push_guard).
