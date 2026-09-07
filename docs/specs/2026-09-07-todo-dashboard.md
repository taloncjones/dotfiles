# Spec: Local dashboard of open todos and research notes

Date: 2026-09-07
Branch: talon/td-2026-09-06-render-a-local-dashboard-of-open-todos-and-researc/todo-dashboard
Source task: td-2026-09-06-render-a-local-dashboard-of-open-todos-and-researc
Status: branch-only document; dropped before merge together with the plan.

## Problem

The board for this repo lives in three places: the todo files under
`.todos/pending/` and `.todos/completed/`, the herdr task records under
the account state root, and research reports (the 2026-09-06 orchestrator
field notes, co-review findings) that exist only as published artifacts
or as scratchpad files that vanish with their worktree. Reading the board
today means `todos.sh list` plus a question to the orchestrator for the
rest. A fresh orchestrator session has no single page to open.

Hosting was settled in the 2026-09-06 brainstorm and is not reopened
here: a published artifact is a snapshot that needs a republish per
change, so it suits reports, not the live list; GitHub Pages is out
because the repo is public and `.todos/` names private projects; the
page is local, static, and served from `file://` with no server.

## Goal

One command, `todos.sh dashboard`, renders the whole board for the
current repo into one self-contained HTML file under a machine-local
state directory, and optionally opens it. The page shows every open
todo with its resolved blocked-on state and its herdr task status, the
most recent completed todos, and an index of durable research reports
kept under a new `.todos/research/` convention. The orchestrator
regenerates the page once per turn in preflight and opens it on the
initial claim.

## Non-goals

- No server, no polling, no JavaScript. The page is inert HTML; refresh
  means rerunning the command and reloading the browser tab (the page
  says so in its header).
- No writes anywhere except the output file and its parent directory.
  The herdr state root is read only; `.todos/` is never modified; no
  `TODO.md` regeneration. The output path is refused when it resolves
  inside `.todos/` or inside the state root (D1).
- No copying of review findings at merge time. That is `post-merge`
  territory (a skill outside this task's scope). This task defines where
  such copies go (`.todos/research/<task_id>/`) so the dashboard already
  indexes them when a later task writes them.
- No PR number column from the task record: the record carries no PR
  field. A `pr:<n>` dependency ref and any GitHub pull-request URL in the
  body are shown instead.
- No live refresh code. `fswatch` is not in the Brewfile; the skill doc
  gives a one-line `herdr pane run` recipe for machines that have it.
- No edit to `todos.sh` beyond one usage line and one dispatch case, and
  no edit to `todos_test.sh`. The unmerged `talon/claude-codex-parity`
  branch carries uncommitted edits to both files; the renderer and its
  tests are new files.
- No change to `co-review`, the herdr brief template, or
  `claude/hooks/herdr_orch_core.py`.
- No Google Fonts or any remote asset: the page must render offline
  from `file://`.

## Scope

Files this task may change or create:

| File | Change |
|---|---|
| `claude/skills/todos/scripts/todos.sh` | one usage-comment line, one `main` case line |
| `claude/skills/todos/scripts/todos_dashboard.py` | new renderer |
| `claude/skills/todos/scripts/tests/todos_dashboard_test.sh` | new suite |
| `claude/skills/todos/SKILL.md` | `dashboard` row, Dashboard section, `.todos/research/` convention |
| `claude/skills/herdr-orchestration/SKILL.md` | one preflight line (D6) |
| `bin/dotfiles-tests` | one `SUITES` line registering the new suite |

The `bin/dotfiles-tests` line is a deliberate one-line extension of the
task brief's file list: the runner is the only way the suite runs in CI,
and the parity branch does not touch that file. Nothing else changes.

## Confirmed facts (read 2026-09-07 at main `026f043`)

- `todos.sh` already exposes hidden verbs `_depends <file>` (prints the
  `depends_on` items one per line, stripped), `_normalize_ref <input>`
  (prints the canonical `todo:|branch:|pr:` ref, exit 1 when invalid),
  and `_resolve <ref>` (prints one state token:
  `done|open|missing|merged|closed|unknown|invalid`). `_resolve` honours
  `TODOS_OFFLINE=1` (no `gh`), `TODOS_BASE_REF`, and `TODOS_GH`. It never
  prints `self`; `resolve_cached` adds that in `list`/`index`.
- Frontmatter reads are first-match `key: value` with one pair of
  surrounding quotes stripped (`frontmatter_value`). `depends_on` is a
  block list of `  - ` items inside the first `---` block; an inline
  `[a, b]` list is not supported by `_depends`.
- `TODO.md` sort key: dated todos first by `due` then priority weight;
  undated by priority weight then `created` (`regenerate_index`).
- Herdr state root is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/herdr-orch`;
  per task: `tasks/<task_id>.json` (record, with `status`,
  `review_head_sha`, `review_outcome`, `workers[]` each with `phase`,
  `role`, `model`, `agent`, `workspace_id`), `.done.json` (`outcome`,
  `phase`, `workspace_id`), `.review.json` (`outcome`, `blocking_count`,
  `reviewed_head_sha`, `findings_ref`). A todo's task id is `td-` plus
  its basename (`todo_task_id`, core line 501). Live records observed
  with `status` in `in-progress|blocked|merged`, `workers[]` absent on
  older records, `review_outcome` null or `approved`. The documented
  status vocabulary is `kickoff|in-progress|blocked|completed|
  review-dispatched|changes-requested|reviewed|failed|abandoned|merged`.
- `repo_slug` (core line 484): remote URL with trailing `.git`, scheme,
  and `user@` stripped, lowercased, non-`[a-z0-9]` runs to `-`, trimmed,
  plus `-` and the first 8 hex of sha256 of the trimmed original URL;
  no remote gives `local-<8hex>` of the resolved common dir.
- In a herdr worktree `.todos` is a symlink to the main checkout's
  `.todos` (observed here), so `.todos/research/` written from any
  worktree lands in one place, and every worktree of a repo shares one
  output file name (same remote, same slug).
- `.todos/` is git-ignored only because `todos.sh init` (or the first
  `new`) appended `.todos/` to `info/exclude`; a hand-made `.todos/`
  has no such line.
- `python3` is 3.14 on this machine and a hard dependency of the
  orchestration core already; the renderer uses the stdlib only.
- Test baseline: `todos_test.sh` 162 passed, 0 failed.
- The repo test runner `bin/dotfiles-tests` lists suites in a `SUITES`
  block; a new suite must be added there to run in CI.

## Design

### D1. Command surface

`todos.sh dashboard [--open] [--online] [--out PATH] [--completed N]`

`todos.sh` gains exactly two lines: the usage-comment entry and a
dispatch case that execs the renderer with the same arguments:

```
dashboard) exec python3 "$(dirname "${BASH_SOURCE[0]}")/todos_dashboard.py" "$@" ;;
```

The renderer is `claude/skills/todos/scripts/todos_dashboard.py`,
Python 3 stdlib only, also runnable directly (`python3
todos_dashboard.py ...`). It locates `todos.sh` as its sibling file.

| Flag | Meaning |
|---|---|
| `--open` | After writing and after printing the path, spawn `open <file>` (Darwin) or `xdg-open <file>` (else) detached, with the child's stdout and stderr sent to `/dev/null`, never waited on. A spawn failure (missing opener) is a `todos:` warning on stderr; exit stays 0 and stdout stays the path alone. |
| `--online` | Let dependency resolution call `gh`: the renderer removes `TODOS_OFFLINE` from the child environment even when the caller exported it. Without the flag the renderer sets `TODOS_OFFLINE=1` in the child environment regardless of the caller's value. The flag always wins. |
| `--out PATH` | Write to PATH (relative to the current directory) instead of the default location. Parent directories are created. |
| `--completed N` | Number of completed todos to show (default 10; 0 hides the section; negative is a usage error). |

Environment overrides (tests and unusual setups):

| Variable | Default | Purpose |
|---|---|---|
| `TODOS_DASHBOARD_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/dashboard` | Output directory; file is `<repo_slug>.html` |
| `TODOS_STATE_ROOT` | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/herdr-orch` | Herdr state root to read task records from |
| `TODOS_DASHBOARD_NOW` | current local time | `YYYY-MM-DD HH:MM` stamp printed in the header |
| `TODOS_TODAY`, `TODOS_BASE_REF`, `TODOS_GH` | existing | Passed through unchanged to the `todos.sh` calls |
| `TODOS_DASHBOARD_TODOS_SH` | sibling `todos.sh` | Path of the script used for `_depends` / `_normalize_ref` / `_resolve` (tests only) |
| `TODOS_DASHBOARD_OPENER` | `open` / `xdg-open` | Command used by `--open` (tests only) |

**Output path guard.** Before reading anything, the renderer resolves
the output path (its parent when the file does not exist yet) with
`realpath` and exits 1 with `todos: refusing to write the dashboard
under <label>: <path>` when it lies inside `<repo>/.todos/` or inside
the state root, symlinks included. `TODOS_DASHBOARD_DIR` goes through
the same guard.

**Atomic write.** The page is written to `<out>.tmp.<pid>` in the
output directory, opened with `O_CREAT|O_EXCL|O_NOFOLLOW` so a planted
file or symlink at that name fails the render instead of being followed,
then renamed over `<out>` with `os.replace`. Any failure after the temp
file exists unlinks it. A reader never sees a partial file, a failed
render leaves the previous page intact, and concurrent renders from two
worktrees of one repo end with whichever finished last, complete. No
lock is taken.

**Failure handling.**

| Condition | Behaviour |
|---|---|
| unknown flag, negative `--completed` | `todos:` message on stderr, exit 1, nothing written |
| not inside a git repository | `todos: not inside a git repository`, exit 1 |
| output path under `.todos/` or the state root | guard message, exit 1 |
| output directory cannot be created or file cannot be written | `todos: cannot write <path>: <reason>`, exit 1, previous page untouched |
| a todo or research file cannot be read (permissions, vanished mid-run) | `todos: skipping unreadable file: <path> (<reason>)` on stderr, entry omitted, exit 0 |
| a todo file is not valid UTF-8 | decoded with replacement characters, no message |
| a `todos.sh` resolver call fails or prints nothing | that ref shows `unknown` (`_resolve`) or `invalid` (`_normalize_ref`); exit 0 |
| `todos.sh _depends` exits non-zero for a todo | the row shows the single entry `depends_on (unreadable)` in the blocked colour and the todo counts as blocked; exit 0 |
| a task, review, or done record is unreadable or not a JSON object | shown as `unreadable` for that record, exit 0 |
| no `.todos/` directory | empty board, exit 0 |

On success stdout is exactly the absolute output path, one line, and
the exit code is 0. Nothing is printed to stdout on failure.

### D2. Data collection

Repo root is `git rev-parse --show-toplevel` from the current directory.

**Todos.** Every `*.md` under `.todos/pending/` and `.todos/completed/`,
sorted by basename. Per file the renderer reads, inside the first `---`
block only and with the same first-match and quote-stripping rules as
`frontmatter_value` (the first line for a key wins even when its value
is blank, so `title:` followed by `title: later` yields a blank title
and the basename fallback): `created`, `title` (falls back to the basename),
`area`, `priority`, `due`, `surface`, `maturity`, `tier`, and the
`files:` list. `depends_on` items come from `todos.sh _depends <file>`
so the list parser stays single-sourced. The body summary is the first
non-empty line under `## Problem`, cut at 140 characters (same rule as
`problem_summary`). Links are every `http://` or `https://` URL in the
body, where a URL runs from the scheme to the first whitespace, `<`,
`>`, `(`, `)`, `[`, `]`, `"`, or `'`, then loses any trailing `.`, `,`,
or `;` (so `[PR](https://github.com/o/r/pull/12)` and `see
https://x.test/a.` both yield the clean URL; a URL that itself contains
parentheses is cut at the first one). Deduplicated in order, capped at
5, classified by host:
`claude.ai` paths under `/code/artifacts/` or `/artifacts/` are labelled
`artifact`, `github.com/<org>/<repo>/pull/<n>` is labelled `PR #<n>`,
anything else shows its host. No other scheme is ever extracted.

**Dependency state.** For pending todos only. Each raw item is passed
to `todos.sh _normalize_ref`; a failure renders the raw text with state
`invalid`. A canonical ref equal to `todo:<own basename>` is `self`
without a resolver call (so `2026-05-01-x`, `todo:2026-05-01-x.md`, and
`todo:2026-05-01-x` all detect self). Every other canonical ref is
resolved by one `todos.sh _resolve <ref>` call with cwd at the repo
root, memoised per canonical ref for the run. A todo is **blocked**
when any ref resolves to something other than `done` or `merged`; the
row lists every ref as `<canonical ref> (<state>)`, unsatisfied ones in
the blocked colour and satisfied ones muted. Completed todos never
resolve (as in `list --all`).

**Herdr task status.** For every todo (pending and completed) the
renderer looks for `<state_root>/<repo_slug>/tasks/td-<basename>.json`.

- Missing record: no status (blank cell, `data-task-status=""`), and
  the review and done records are not consulted.
- Record present but unreadable or not a JSON object: status text
  `unreadable`, the review and done records are still consulted.
- Record valid: `status`, `branch`, `review_head_sha`, and
  `review_outcome` from the record; `phase`, `role`, `model`, `agent`,
  and `workspace_id` from the last `workers[]` entry when `workers` is a
  non-empty list whose last element is an object, else blank. Every
  field is read as a string or integer; `null`, booleans, lists, and
  objects read as blank. A missing key is blank, never an exception.
- Review record (`.review.json`), when present and valid: `outcome`
  (shown as `unknown` when blank or missing in a present record),
  `blocking_count`, `findings_ref`. It is **current** only when
  `reviewed_head_sha` is non-blank and equals the task record's
  `review_head_sha`; otherwise the cell shows it tagged `(stale)`. The
  task record's own `review_outcome` is shown only when the review file
  does not exist; a present-but-empty review record never falls back to
  it.
- Done record (`.done.json`), when present and valid: `outcome`,
  `phase`. Current only when its `phase` equals the live worker's
  `phase` and its `agent` equals the live worker's `agent` (all four
  non-blank); otherwise tagged `(stale)`. Workspace ids are not used:
  herdr reuses one workspace across plan, implement, and review.
- **In-flight** is a pending todo whose readable record has `status`
  in exactly `kickoff`, `in-progress`, `blocked`, `review-dispatched`,
  `changes-requested`, `reviewed`. An unreadable record, an empty
  object, or any other status (including `merged`, `completed`,
  `failed`, `abandoned`, or an unknown token) is not in flight.

`repo_slug` is computed in the renderer from `git remote get-url
origin` (else the git common dir) by the rule in the confirmed facts; a
test pins it against `claude/hooks/herdr_orch_core.py`'s `repo_slug`
on fixed inputs so drift is caught.

**Research.** Every `*.md` under `.todos/research/`, recursively, sorted
by `created` descending, ties by relative path ascending; files without
`created` follow, by relative path, and show `undated`. Frontmatter:
`title` (falls back to the filename), `kind` (free text, e.g.
`field-notes`, `review-findings`, `report`), `task` (a task id or todo
basename; a `td-` prefix is stripped for matching; rendered as an
in-page link when that basename is a row on the page, else as plain
monospace text), `artifact` (rendered as a link only when it starts
with `http://` or `https://`; any other value, `javascript:` included,
is shown as escaped plain text). The summary is the first non-empty
body line after the frontmatter, cut at 200 characters. Each entry's
title links to the file itself with a `file://` URL.

### D3. The `.todos/research/` convention

Documented in `claude/skills/todos/SKILL.md`, no tooling beyond the
index:

```
<repo>/.todos/research/
  YYYY-MM-DD-<slug>.md        durable report (field notes, a study, a decision memo)
  <task_id>/                  per-task material copied at merge time (future post-merge step)
    review-findings.md
```

Report frontmatter (`created` and `title` expected; the rest optional):

```markdown
---
created: 2026-09-06
title: Orchestrator field notes, 2026-09-06
kind: field-notes
task: 2026-09-06-render-a-local-dashboard-of-open-todos-and-researc
artifact: https://claude.ai/code/artifacts/...
---

One-paragraph summary, then the report body in markdown.
```

Visibility: the directory inherits the `.todos/` rule, which exists
only after `todos.sh init` (or the first `new`) has written the
`.todos/` exclude line. The skill doc says to run `todos.sh init`
before saving research in a repo that has never used todos, and that a
repo where `todos.sh share` was run commits research along with the
backlog. The renderer warns once on stderr (`todos: .todos/ is neither
git-ignored nor tracked; run todos.sh init before saving research
there`) when `.todos/` exists but `git check-ignore` rejects it and
`git ls-files .todos` is empty; the render still succeeds.

### D4. Page structure

Single HTML file, inline CSS, no script, no remote assets. Sections, in
order:

1. **Header.** Repo name (basename of the repo root), the generated
   stamp, the output of `git rev-parse --abbrev-ref HEAD` for the
   checkout the command ran in, the sentence `Static page: rerun
   todos.sh dashboard and reload to refresh.`, and three counts: open,
   blocked, and in-flight (D2), rendered as `<b data-count="open">N</b>`,
   `data-count="blocked"`, `data-count="in-flight"`.
2. **Open.** One table sorted with the `TODO.md` key. Columns: todo
   (title, basename beneath it, problem summary, area chip, priority
   chip, `maturity` / `tier` chips when set), created / due, depends on
   (each ref with its state; blocked rows carry a state stripe), herdr
   (status pill, then `phase role model` line, review verdict with
   blocking count and `(stale)` tag, done outcome with `(stale)` tag),
   links. Empty state: `No open todos.`
3. **Completed.** The `--completed N` most recent by `created` desc then
   basename desc. Columns: todo, created, herdr (same as above), links.
   Empty state: `Nothing completed yet.` Omitted entirely at N = 0.
4. **Research.** List sorted per D2. Each entry: title (linked to the
   file), created or `undated`, kind chip, task link or text, artifact
   link or text, summary. Empty state: `No research reports. Save
   durable notes under .todos/research/ (see the todos skill).`

Attribute safety: every attribute value is escaped, and CSS class
names are literals chosen by the renderer (the priority chip gets a
`prio-<level>` class only when the level is one of `high`, `med`,
`low`); no frontmatter value ever reaches an attribute unescaped, so a
value like `x" onclick="..."` renders as text.

Machine-readable hooks on every row: `id="todo-<basename>"`,
`data-todo="<basename>"`, `data-state="open|blocked"` (pending rows
only), `data-task-status="<status or empty>"`, and on research entries
`data-research="<path relative to .todos/research>"`. All text content
and attribute values pass through `html.escape(..., quote=True)`; every
`href` is either a `file://` URI built by `Path.as_uri()`, an in-page
`#todo-` anchor, or an `http(s)` URL that passed the scheme check.

### D5. Visual design

The page is a board that is scanned, not read, so the craft is
information design: state in form before number. Tokens, all defined
on bare `:root` for light, redefined under
`@media (prefers-color-scheme: dark)` guarded as
`:root:not([data-theme="light"])`, and again under
`:root[data-theme="dark"]`; `body` paints its background from a token.

- Palette (light): ground `#f7f6f2` (warm paper, hue-biased toward the
  accent), ink `#1f2a24`, muted `#6b746e`, accent `#2f6f5e` (deep
  green), rule `#d9ddd7`, chip `#ebeae4`. Semantic, separate from the
  accent: blocked `#b3541e`, merged `#3b6ea5`, in-flight `#8a6d1f`.
  Dark: ground `#171b19`, ink `#e8ece9`, muted `#9aa39d`, accent
  `#7fbfa8`, rule `#2c332f`, chip `#232927`, blocked `#e0895a`, merged
  `#7fa9d8`, in-flight `#d1b25a`.
- Type: a humanist sans for everything (`"Avenir Next", "Segoe UI",
  system-ui, sans-serif`) with a monospace utility face (`"SF Mono",
  Menlo, Consolas, monospace`) for basenames, refs, and branch names;
  `tabular-nums` on dates and counts; uppercase letter-spaced section
  headings; the title `text-wrap: balance`.
- Layout: max width 1200px, one column of tables; the header counts are
  a flex row of three plain figures (no cards). Tables sit in an
  `overflow-x: auto` wrapper. Chips and pills are the only rounded
  elements; a blocked row also paints a 3px left stripe on its first
  cell so it reads without colour.
- Motion: none.

The field notes artifact used the same warm-neutral ground and a
restrained chip vocabulary; this page follows that so the two read as
one system. The implementer keeps the tokens above verbatim.

### D6. Orchestrator preflight

`claude/skills/herdr-orchestration/SKILL.md` section 1 gains exactly one
line, inserted after the ownership-claim bullet list (after the
`check-fence` sentence) and before step 4:

```
   - Regenerate the board with `bash ~/.claude/skills/todos/scripts/todos.sh dashboard` (add `--open` on the initial claim only); best-effort, a non-zero exit is noted in the turn summary and never blocks the action.
```

Nothing else in that skill changes.

### D7. Tests

New suite `claude/skills/todos/scripts/tests/todos_dashboard_test.sh`,
same helpers and output shape as `todos_test.sh` (`ok`/`FAIL` lines,
final `N passed, M failed`, exit 1 on any failure), registered in
`bin/dotfiles-tests`. Every test builds a throwaway git repo with
`origin/main` set by `update-ref` and an `origin` remote URL set by
`git remote add`, a `.todos/` fixture set, and a fake state root passed
via `TODOS_STATE_ROOT`; `TODOS_TODAY` and `TODOS_DASHBOARD_NOW` pin
determinism, `TODOS_GH` points at a stub that records calls. No test
opens a browser or reaches the network.

Fixture set (the "one blocked, one merged, one plain" of the task):

- `pending/2026-05-01-plain.md`: no deps, no task record; body links a
  GitHub PR URL and a `claude.ai` artifact URL.
- `pending/2026-05-02-blocked.md`: `priority: high` and a block list

  ```
  depends_on:
    - todo:2026-05-01-plain
    - pr:7
  ```

- `completed/2026-05-03-merged.md`; state root has
  `td-2026-05-03-merged.json` with `status: merged`,
  `review_head_sha: abc`, and a `.review.json` with `outcome: approved`,
  `blocking_count: 0`, `reviewed_head_sha: abc`.
- `pending/2026-05-04-in-flight.md`; record with `status: in-progress`,
  `workers[-1]` `phase: implement`, `agent: impl-a`; a `.done.json`
  with `outcome: completed`, `phase: plan`, `agent: plan-a` (stale).
- `pending/2026-05-05-bad-record.md`, title
  `<script>alert(1)</script>`; record file containing `{not json`.
- `research/2026-05-06-notes.md` (`kind: field-notes`, `task:
  td-2026-05-01-plain`, `artifact: https://claude.ai/code/artifacts/x`)
  and `research/td-x/review-findings.md` (`created: 2026-05-02`,
  `artifact: javascript:alert(1)`).

## Acceptance criteria

- AC1 **Renders the fixture board.** `todos.sh dashboard --out F` exits
  0, prints F, and F contains a row `data-todo="2026-05-02-blocked"
  data-state="blocked"` listing `todo:2026-05-01-plain (open)` and
  `pr:7 (unknown)`; a row for `2026-05-01-plain` with
  `data-state="open"` and the link labels `PR #12` and `artifact`; a
  completed row `data-todo="2026-05-03-merged"
  data-task-status="merged"` with the text `review approved (0
  blocking)` and no `(stale)` on that line; an in-flight row with
  `data-task-status="in-progress"`, the text `implement`, and `done
  completed plan (stale)`; and the counts `data-count="open">4`,
  `data-count="blocked">1`, `data-count="in-flight">1`.
- AC2 **Bad records do not abort.** The `2026-05-05-bad-record` row
  renders with `data-task-status="unreadable"`; exit stays 0; the
  in-flight count is still 1.
- AC3 **Research index.** Both research files appear, `2026-05-06-notes.md`
  before `td-x/review-findings.md`, the first with the chip text
  `field-notes`, an `href="https://claude.ai/code/artifacts/x"`, and an
  `href="#todo-2026-05-01-plain"`; the second shows
  `artifact: javascript:alert(1)` as text and F contains no
  `href="javascript:`.
- AC4 **Escaping.** The `2026-05-05-bad-record` title appears only as
  `&lt;script&gt;alert(1)&lt;/script&gt;`; the string `<script` is
  absent from F.
- AC5 **Default path and slug.** With `TODOS_DASHBOARD_DIR=D` and an
  `origin` remote `git@github.com:Org/Repo.git`, the printed path is
  `D/<slug>.html` where `<slug>` equals what
  `herdr_orch_core.repo_slug("git@github.com:Org/Repo.git")` returns;
  with no remote the name starts with `local-`.
- AC6 **Read-only.** After a render the fixture state root's file list
  and checksums are identical to before, and `.todos/` contains no
  `TODO.md`.
- AC7 **Empty board.** In a repo with no `.todos/`, exit 0 and F
  contains `No open todos.` and `Nothing completed yet.` and
  `No research reports.`
- AC8 **Flags.** `--completed 0` omits the `Completed` heading;
  `--completed 1` shows exactly one completed row, the newest by
  `created`; `--completed -1` and an unknown flag exit 1 with a `todos:`
  line on stderr and nothing on stdout.
- AC9 **Offline precedence.** With the `TODOS_GH` stub: a default render
  records no `gh` call; `--online` records at least one; `--online` with
  `TODOS_OFFLINE=1` exported still records at least one; a default
  render with `TODOS_OFFLINE` unset records none.
- AC10 **Output guard.** `--out <repo>/.todos/x.html` and `--out
  <state_root>/<slug>/x.html` exit 1 with `refusing to write` on stderr
  and create no file; `TODOS_DASHBOARD_DIR=<repo>/.todos` likewise.
- AC11 **Failed write preserves the previous page.** After one
  successful render to F, F's directory is made non-writable
  (`chmod 555`; skipped when running as root) and a second render to
  the same F exits 1 with `cannot write`, prints nothing on stdout, and
  leaves F's checksum unchanged and no `.tmp.` file beside it.
- AC12 **Unreadable todo skipped.** A pending todo made unreadable
  (`chmod 000`; the check is skipped when running as root) is omitted,
  a `skipping unreadable file` line appears on stderr, exit 0, and the
  other rows still render.
- AC13 **Self and invalid refs.** A pending todo listing
  `todo:<its own basename>.md` and `not a ref!` renders `(self)` and
  `not a ref! (invalid)` and is blocked. A pending todo whose
  `_depends` read fails (simulated with a `TODOS_DASHBOARD_TODOS_SH`
  override pointing at a stub that exits 1 for `_depends`) renders
  `depends_on (unreadable)` and is blocked.
- AC17 **Link boundaries.** A body line `[PR](https://github.com/o/r/pull/12).`
  yields `href="https://github.com/o/r/pull/12"` and no `href` ending
  in `)` or `.`.
- AC14 **Dispatch is thin.** The diff of `todos.sh` against the merge
  base adds at most two lines and removes none; `todos_test.sh` has no
  diff; `todos_test.sh` still reports 0 failed.
- AC15 **Docs.** The todos skill documents the `dashboard` command row,
  the `.todos/research/` convention with its frontmatter keys, the
  `todos.sh init` visibility note, and the `TODOS_DASHBOARD_DIR` /
  `TODOS_STATE_ROOT` overrides; the orchestration skill's section 1
  contains `todos.sh dashboard` on exactly one added line.
- AC16 **Registered suite.** `bin/dotfiles-tests --list` includes the
  new test file.

## Branch-only documents

`git/hooks/public-safety.test.sh` rejects any tracked file under
`docs/plans/` or `docs/specs/`, so this spec and its plan (tracked with
`git add -f` for the plan and implement phases) make the full runner
fail until they are dropped from tracking. The plan's last task removes
them from the index (the cached-removal form of git rm) as the final
commit before review; the files stay on disk because `docs/` is in
`info/exclude`, and the review reads them by path or from history.

## Verification not covered by tests

- Opening in a real browser on this machine and checking both colour
  schemes: human-verify after implementation (one look).
- The orchestrator actually running the preflight step: human-verify on
  the next orchestrated turn after merge.

## Decisions recorded

- Recency for completed todos uses `created`, not file mtime: `mv`
  preserves mtime and the completed record carries no completion date.
- The renderer is Python rather than bash because HTML escaping and
  JSON reading in bash are fragile, and the core already makes python3
  a hard dependency. Dependency resolution stays in `todos.sh` through
  the hidden verbs, so there is one resolver.
- Review round 1 (Codex, 2026-09-07, verdict needs-rework, 12 findings)
  folded in full: output-path guard, http(s)-only links, record
  precedence and staleness tags, the `.todos/` visibility warning, the
  block-list fixture, the explicit scope table, typed record fields and
  the enumerated in-flight statuses, `--online` precedence, the failure
  table, the atomic write, the reload sentence, and normalisation via
  `_normalize_ref`.
- Review round 2 (Codex, 2026-09-07, verdict needs-rework, 5 findings)
  folded in full: done-record freshness by phase and agent, a failed
  dependency read counts as blocked, `--open` bounded and detached, URL
  boundary rules, and AC11 retargeted at the existing page. Two rounds
  is the review skill's cap; the plan review is the next gate.
- Plan review (Codex, 2026-09-07, verdict needs-rework, 13 findings)
  folded where they touched the spec: `O_EXCL|O_NOFOLLOW` temp file,
  attribute-safety rule, review-record presence rule, blank-first-value
  frontmatter rule, `TODOS_DASHBOARD_OPENER`, and this branch-only
  documents section. The rest are plan-level (see the plan's review
  notes).
