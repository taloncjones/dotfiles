# Spec: Task dependencies on todos

Date: 2026-09-06
Branch: talon/td-2026-09-06-add-task-dependencies-to-todos-and-gate-dispatch-o/todo-dependencies
Source task: td-2026-09-06-add-task-dependencies-to-todos-and-gate-dispatch-o
Status: branch-only document; dropped before merge together with the plan.

## Problem

Todos carry no machine-readable dependency information. On 2026-09-05 an
implement worker was launched for a task whose plan depended on an
unmerged branch; it paused after a wasted launch and the orchestrator
checked preconditions by hand afterwards. Twelve todos filed on
2026-09-05 and 2026-09-06 say "depends on" in prose that nothing reads.
A scheduler cannot honour a sentence.

## Goal

Half 1 of the dependency feature, confined to the todos skill: a
`depends_on:` frontmatter list on a todo naming other todos, branches, or
pull requests; a resolver that classifies each reference as satisfied or
not from local git state and, when online, from `gh`; `todos.sh list`
and the generated `TODO.md` index marking items whose dependencies are
not all satisfied; `todos.sh new --depends-on` and a new
`todos.sh depend` subcommand to set the field through the script; and a
backfill of the existing todos whose bodies state a hard dependency.

Half 2 (orchestrator kickoff refusing blocked todos, phase re-checks,
`depends_on` in the task record, wave scheduling) is a later task and is
out of scope here. This half must land without touching the orchestrator
core or its skill.

## Non-goals

- No changes to `claude/hooks/herdr_orch_core.py` or
  `claude/skills/herdr-orchestration/`. A parallel branch owns them.
- No cycle detection beyond the direct self-dependency. A cycle between
  two todos simply shows both as blocked; half 2 may detect it.
- No dependency awareness in `todos.sh brief`. The brief keeps its time
  model; a follow-up may add a blocked marker there.
- No network access from `new`, `done`, `depend`, or `index`. Only
  `todos.sh list` may call `gh`, and only when not told to stay offline.
- No `git fetch`. Branch resolution reads whatever refs the local
  repository already has.
- No removal of dependencies through the script. Editing the todo file's
  frontmatter by hand remains the way to drop one (as for every other
  key except `TODO.md`).
- No inline YAML list form (`depends_on: [a, b]`). Only the block-list
  form the `files:` key already uses.

## Confirmed facts (2026-09-06, worktree at main `41dd7a1`)

- `claude/skills/todos/scripts/todos.sh` (488 lines) reads frontmatter
  with `frontmatter_value` (first `key: value` line) and writes `files:`
  as a block list (`  - item`). `list` prints `  %-44s %s` (basename,
  title). `regenerate_index` sorts by due/priority/created and appends
  ` due D` and ` [priority]` metadata after the link.
- `claude/skills/todos/scripts/tests/todos_test.sh` passes 60/0 at base
  (baseline recorded 2026-09-06). `bin/dotfiles-tests` line 38 runs it in
  CI (`.github/workflows/tests.yml`), on Linux as well as macOS.
- `/usr/bin/env bash` is bash 3.2.57 on this machine. No associative
  arrays, no `mapfile`. The script already avoids both.
- `.todos/` is git-excluded and untracked in this repository (0 tracked
  files). Inside this worktree `.todos` is a symlink to the main
  checkout's `.todos/`, so the script run from the worktree edits the
  live backlog. The backfill is therefore a machine-local runbook step,
  not a committed artifact.
- This repository squash-merges. After merge the branch is deleted
  (`post-merge` skill), so a merged branch is usually absent from local
  refs rather than an ancestor of `origin/main`. Branch resolution must
  handle "ref absent" as a first-class case.
- `gh` 2.96 is installed on this machine; `shellcheck` is not.
  `origin/main` exists in this worktree.
- Twelve pending todos state a hard dependency in prose (see Backfill).
  Nine of them depend on the same branch, `talon/claude-codex-parity`.

## Design

### D1. Reference grammar

A dependency reference is one of three kinds, stored in canonical
prefixed form:

| Kind   | Canonical form          | Payload rule                                        |
|--------|-------------------------|-----------------------------------------------------|
| todo   | `todo:<basename>`       | `YYYY-MM-DD-<slug>`, chars `[a-z0-9-]`, no `.md`     |
| branch | `branch:<name>`         | passes `git check-ref-format --branch <name>`       |
| pr     | `pr:<number>`           | decimal integer, at least 1, no leading `#`         |

`normalize_ref <input>` maps an input to its canonical form or reports it
invalid. It accepts the canonical forms plus these shorthands: `#85` and
`85` become `pr:85`; a `.md` suffix on a todo payload is dropped (both
`todo:<x>.md` and a bare `<x>.md`); a bare value matching
`^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+$` after that strip becomes
`todo:`; a bare value containing `/` becomes `branch:`. Any other bare
value is invalid. A branch payload that starts with `-` or contains `@{`
is invalid before `git check-ref-format` runs (git would parse the first
as a flag and the second as a reflog shorthand). The same function runs
on CLI input and on values read from files, so a hand-edited shorthand
in a file behaves like the CLI form.

Whitespace is trimmed and surrounding single or double quotes are
stripped before normalization, matching `frontmatter_value`.

### D2. Frontmatter field

```
depends_on:
  - todo:2026-09-05-activate-reviewed-claude-and-codex-parity
  - branch:talon/claude-codex-parity
  - pr:85
```

Parsing (`depends_list <file>`): inside the first frontmatter block
(between the first two `---` lines), the items are the consecutive
`  - <value>` lines directly under the `depends_on:` key, stopping at the
first line that does not start with two spaces and a dash. A blank line
therefore ends the list: hand edits must keep the items contiguous (the
writer always does). A `depends_on:` key with no items means no
dependencies. A missing key means no dependencies. Order is preserved;
duplicates are kept as read (the writer dedupes, the reader does not).

Writing (`add_depends <file> <ref>...`): all edits are bounded to the
first frontmatter block; `files:` or `---` lines in the body are never
touched. When `depends_on:` exists in the block, new items are appended
after its last item; otherwise the key and items are inserted directly
before the first `files:` line in the block, or before the block's
closing `---` when there is no `files:` line. Every other byte of the
file is preserved. The write goes to a temp file in the same directory
followed by `mv` (the pattern `regenerate_index` already uses). A ref
already present (compared after normalizing the existing items) is not
added again.

### D3. Resolver

A dependency reference ends in exactly one state token. `resolve_ref
<canonical-ref>` produces `done`, `merged`, `open`, `closed`, `missing`,
or `unknown` from a canonical ref alone. The two remaining tokens are
assigned by the callers that have the context: `invalid` by the
normalizer (the value did not parse) and `self` by the renderer (a
`todo:` ref equal to the basename of the todo being rendered). The
hidden `_resolve` verb has no current-todo context: it prints `invalid`
for a value that does not normalize and never prints `self`.

| State     | Meaning                                                 | Satisfied |
|-----------|---------------------------------------------------------|-----------|
| `done`    | todo file exists under `completed/`                     | yes       |
| `merged`  | branch ancestor of base, or PR/branch reported MERGED   | yes       |
| `open`    | todo under `pending/`; branch not ancestor; PR OPEN     | no        |
| `closed`  | PR reported CLOSED (closed without merge)               | no        |
| `missing` | todo under neither `pending/` nor `completed/`          | no        |
| `unknown` | could not be determined (offline, gh absent or failing) | no        |
| `invalid` | did not normalize                                       | no        |
| `self`    | todo ref equal to the todo being rendered               | no        |

Sources, in order:

- `todo:` -- `completed/<basename>.md` then `pending/<basename>.md`.
  Local only, always determinate.
- `branch:` -- base ref is `${TODOS_BASE_REF:-origin/main}`. If the base
  ref does not exist the state is `unknown`. Otherwise the branch ref is
  `refs/remotes/origin/<name>` if present, else `refs/heads/<name>`, else
  absent. Steps, in order:
  1. If a ref is found and `git merge-base --is-ancestor <ref> <base>`
     exits 0, the state is `merged` (equivalent to membership in
     `git branch --merged <base>`, without parsing branch listings). An
     exit above 1 is a git error and gives `unknown`.
  2. Otherwise, when online, run
     `gh pr list --head <name> --state all --limit 1 --json state --jq '.[0].state'`
     and map MERGED/OPEN/CLOSED to `merged`/`open`/`closed`. This is what
     makes a squash-merged branch resolve: the branch commits are never
     ancestors of the base, and after `post-merge` the ref is gone.
  3. When `gh` gives nothing (offline, absent, failing, or no PR for that
     head): `open` if the ref was found, `unknown` if it was absent.
- `pr:` -- offline gives `unknown`; online runs
  `gh pr view <number> --json state --jq .state` and maps as above.

Offline means `TODOS_OFFLINE` is set to a non-empty value in the
environment or `--offline` is on the `list` command line. The `gh`
binary is `${TODOS_GH:-gh}`; a value that does not resolve to an
executable behaves as a failing `gh` with no error output. `gh` stderr
is discarded. The script runs under `set -euo pipefail`, so every `gh`
invocation must capture a non-zero exit explicitly (`out=$(...) ||
out=""` shape); a failing `gh` never aborts `list`, which still exits 0
with the affected refs rendered as `unknown` (or `open` for a present
branch). The script does not impose its own timeout on `gh`;
`--offline` is the escape hatch for a hung network. `list` stays online
by default because it is the interactive command and the one place a
PR ref can resolve at all; making it offline-by-default would leave
every `pr:` ref permanently `unknown` unless the user remembers a flag.

Within one `list` invocation each distinct canonical ref is resolved at
most once (a per-invocation cache in a temp file keyed by ref, because
bash 3.2 has no associative arrays). Nine todos that share one branch
ref cost one `gh` call, not nine.

`index` (and therefore `new`, `done`, `depend`) resolves in offline mode
unconditionally: todo refs and locally-present branch refs resolve
normally; PR refs and absent branch refs are `unknown`. The index never
performs network I/O and never emits dependency diagnostics (D4).

### D4. Rendering

`todos.sh list` (pending section): after the title, todos with at least
one unsatisfied dependency get a trailing annotation

```
  2026-09-06-scale-review-effort-to-diff-size.md       Scale review effort to diff size  [blocked-on: branch:talon/claude-codex-parity (unknown)]
```

listing every unsatisfied ref as `<ref> (<state>)`, comma-separated, in
file order. Todos whose dependencies are all satisfied, and todos with
none, print exactly as today. The completed section (`--all`) never
annotates. `list` accepts `--all` and `--offline` in any order; an
unknown flag is an error as for other commands.

`TODO.md` (`regenerate_index`): the metadata run after the link gains,
after the priority tag and before the ` -- summary`, up to two markers
computed offline: ` [blocked-on: <ref>, <ref>]` listing the refs whose
state is determinately unsatisfied (`open`, `closed`, `missing`,
`invalid`, `self`), then ` [unverified: <ref>, <ref>]` listing the refs
whose state is `unknown` (PR refs, absent branches). Either marker is
omitted when its list is empty. The distinction keeps a todo whose only
dependency is a merged PR from reading as blocked forever in the index;
`todos.sh list` (online) is the authoritative view. Sorting is
unchanged; a blocked item keeps its due/priority position.

Diagnostics: during `list` only, an `invalid` ref and a `self` ref each
produce one stderr line `todos: <basename>: invalid dependency ref
'<value>'` or `todos: <basename>: depends on itself`; the command still
exits 0 and the ref is rendered with its state. `index` is silent about
dependency refs, so `new`, `done`, and `depend` on one todo never warn
about another todo's frontmatter.

### D5. Commands

`todos.sh new "<title>" [--depends-on REF]...` -- repeatable, like
`--file`. Each REF is normalized (D1); an invalid ref, a `todo:` ref that
matches no file, or an ambiguous `todo:` substring exits 1 with a
`todos:` message before any file is written. A `todo:` payload is
resolved against `pending/` and `completed/` by exact basename first,
then by unique substring (the `done` matching rule); the stored form is
always the exact basename. A ref equal to the new todo's own basename is
refused (defensive; the basename is uniquified so this cannot normally
occur). The field is written between `priority:` and `files:` in the
generated frontmatter. Refs are deduped in order of first appearance.

`todos.sh depend <slug-or-substring> REF...` -- adds one or more refs to
an existing pending todo, found with the `done` matching rule (exact or
unique substring of the basename; ambiguous or no match exits 1). Refs
are normalized and validated as for `new`. A ref that resolves to the
target todo itself exits 1 with `todos: a todo cannot depend on itself`.
Refs already present are skipped silently. On success the file is
rewritten (D2), the index is regenerated, and the file path is printed.
With zero refs the command exits 1 (`depend requires at least one ref`).

Hidden verbs for tests, following `_validate_date`: `_normalize_ref
<input>` prints the canonical form or exits 1; `_resolve <ref>` prints
the state token (runs inside the repo, honours `TODOS_OFFLINE`,
`TODOS_GH`, `TODOS_BASE_REF`); `_depends <file>` prints the parsed list
one per line.

### D6. SKILL.md

`claude/skills/todos/SKILL.md` documents: the `depends_on:` key in the
todo file template and the reference grammar with the three canonical
forms; the `--depends-on` flag and the `depend` command rows in the
Commands table; a short "Dependencies" section stating the state table,
what satisfied means, the offline rule (index never uses the network,
`list --offline` / `TODOS_OFFLINE=1`), the squash-merge caveat (a merged
and deleted branch resolves only through `gh`, so prefer a `pr:` ref
once the PR number is known), and that the orchestrator will read this
field in a later task. A Common Mistakes row: writing `#85` unquoted in
YAML (it is a comment); use `pr:85`.

## Backfill

Applied after the implementation is green, from inside the worktree
(`.todos` is a symlink to the live backlog), with `todos.sh depend`.
Only hard dependencies stated in the todo body are recorded; "ideally",
"coordinate with", and context mentions of merged PRs are left as prose.

| Todo (basename)                                                   | Refs added |
|-------------------------------------------------------------------|------------|
| 2026-09-06-add-a-fast-path-that-skips-the-plan-phase-for-smal     | branch:talon/claude-codex-parity |
| 2026-09-06-adopt-a-tiered-loop-judge-and-pausing-budget-count     | branch:talon/claude-codex-parity |
| 2026-09-06-block-worker-stops-until-the-completion-record-exi     | branch:talon/claude-codex-parity |
| 2026-09-06-cut-orchestrator-wake-noise-to-record-writes-only      | branch:talon/claude-codex-parity |
| 2026-09-06-keep-workers-alive-through-machine-sleep-and-hung      | branch:talon/claude-codex-parity |
| 2026-09-06-scale-review-effort-to-diff-size                       | branch:talon/claude-codex-parity |
| 2026-09-06-size-plan-tasks-to-one-review-sitting-and-a-contex     | branch:talon/claude-codex-parity |
| 2026-09-06-stop-worker-stalls-on-scratch-cleanup-by-avoiding      | branch:talon/claude-codex-parity |
| 2026-09-05-improve-herd-task-labels-and-orchestrator-layout-a     | branch:talon/claude-codex-parity, pr:85 |
| 2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat     | todo:2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking |
| 2026-09-05-add-codex-adapter-to-the-shared-herd-orchestrator      | todo:2026-09-05-activate-reviewed-claude-and-codex-parity, pr:85, todo:2026-09-05-serialize-shared-herd-ownership-and-completion, todo:2026-09-05-unify-frozen-code-and-document-review-inputs, todo:2026-09-05-resolve-review-models-and-effort-explicitly |

That is eleven todos and thirteen refs. The twelfth todo that says
"depends on" is this task's own todo, whose dependency (the parity
merge) belongs to half 2; it is not backfilled so half 2's kickoff gate
does not block on itself. Expected `list --offline` result after
backfill: the nine parity-branch todos show `open` (the local ref
`refs/heads/talon/claude-codex-parity` at `ca6c5d8` is visible from
every worktree and is not an ancestor of `origin/main`); after the
squash merge and branch deletion they show `unknown` offline and
`merged` online. The rm-permission todo shows `open` until that todo
completes, and `pr:85` shows `unknown` offline and `merged` online.

The `depend` invocations for the backfill are listed verbatim in the
plan. Every `todo:` ref names a file that must exist under `pending/` or
`completed/` at backfill time, or that `depend` call exits 1; the
runbook says to skip and report such a row rather than invent a ref.
The backfill is verified by reading `todos.sh list --offline` output,
not by the task contract, because `.todos/` is machine-local.

## Acceptance criteria

Each is a named check in `todos_test.sh`; the label in parentheses is
the `ok` line the contract greps for.

- AC1 parse: `_depends` returns nothing for a todo with no key, nothing
  for an empty key, one item for one, three in order for three, strips
  quotes, and stops at the next key and at the closing `---`
  (`depends: parse block list`).
- AC2 normalize: `_normalize_ref` maps `#85`, `85`, `pr:85` to `pr:85`;
  `talon/x` and `branch:talon/x` to `branch:talon/x`; a date-slug,
  `<slug>.md`, and `todo:<slug>.md` to `todo:<slug>`; and exits 1 for
  `pr:0`, `pr:abc`, `branch:bad..name`, `branch:-x`, `branch:a@{1}`, and
  a bare word (`depends: normalize refs`).
- AC3 resolve todo: `done` for a completed basename, `open` for a
  pending one, `missing` for neither (`resolve: todo states`).
- AC4 resolve branch: with a fixture repo where `origin/main` is created
  by `git update-ref`, offline: a branch at an ancestor commit is
  `merged`, a branch with an extra commit is `open`, an absent branch is
  `unknown`, and with `TODOS_BASE_REF` pointing at a nonexistent ref
  every branch is `unknown`; online with the AC5 stub: the extra-commit
  branch is `merged` when the stub answers MERGED for its head and
  `open` when the stub knows no PR for it (`resolve: branch states`).
- AC5 resolve PR: with `TODOS_GH` pointing at a stub script that answers
  MERGED for 1, OPEN for 2, CLOSED for 3 and exits 1 for 4, states are
  `merged`, `open`, `closed`, `unknown`; with `TODOS_OFFLINE=1` all are
  `unknown`; with `TODOS_GH=/nonexistent/gh` all are `unknown` and
  stderr is empty (`resolve: pr states via gh stub`). The stub also
  answers `pr list --head` so an absent branch resolves to `merged`
  online (`resolve: absent branch via gh stub`).
- AC6 list rendering: a pending todo with one unsatisfied ref shows
  `[blocked-on: <ref> (<state>)]`; one with all refs satisfied shows no
  annotation; one with two unsatisfied refs lists both in file order;
  `--all` shows no annotation on completed items; `list --offline` works
  with the flags in either order; online with a `TODOS_GH` stub that
  exits 1 for every call, `list` still exits 0; with a counting stub and
  three pending todos sharing one `pr:` ref, the stub runs exactly once
  per `list` (`list: blocked-on annotation`).
- AC7 index: `TODO.md` marks a blocked item with `[blocked-on: <ref>]`
  after the priority tag, lists `unknown` refs under `[unverified:
  <ref>]` instead, omits both for satisfied deps, and `new` never
  invokes `gh` even when `TODOS_GH` points at a script that would fail
  the test by writing a sentinel file; `done` on one todo writes nothing
  to stderr when another pending todo carries an invalid ref (`index:
  blocked marker, no network`).
- AC8 new flag: `new --depends-on` writes the canonical list between
  `priority:` and `files:`, dedupes, resolves a unique substring to the
  exact basename, and exits 1 for an invalid ref, an unknown todo, and an
  ambiguous substring, writing no file in the failure cases
  (`new: --depends-on`).
- AC9 depend command: `depend` appends to an existing list, creates the
  key before `files:` when absent, skips duplicates, preserves every
  other line byte-for-byte (compared with `diff` against the expected
  file), regenerates the index, and exits 1 for a self-dependency
  by exact basename and by unique substring (`depend: add refs`,
  `depend: refuses self-dependency`).
- AC10 diagnostics: an invalid ref and a self ref in a file each warn on
  stderr once during `list`, render with state `invalid` / `self`, and
  `list` exits 0 (`list: invalid and self refs warn`).
- AC11 baseline: every pre-existing check still passes; the suite total
  is 60 plus the new checks with 0 failures.
- AC12 docs: `SKILL.md` contains `depends_on:`, `--depends-on`,
  `todos.sh depend`, `pr:85`, and `TODOS_OFFLINE`.
- AC13 scope: the implementation diff against base `41dd7a1` touches
  only `claude/skills/todos/scripts/todos.sh`,
  `claude/skills/todos/scripts/tests/todos_test.sh`,
  `claude/skills/todos/SKILL.md`, plus the branch-only spec and plan and
  the task contract; added lines are ASCII.

## Verification outside the contract

- Backfill applied and `todos.sh list --offline` shows the eleven
  todos annotated as described (human or orchestrator reads the output).
- One online `todos.sh list` on this machine shows `pr:85 (merged)` is
  absent from annotations (satisfied) and the parity branch resolves
  through the local ref. This is the only network check and it is manual.
