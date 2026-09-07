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

- No server, no polling, no JavaScript data fetching. The page is inert
  HTML; refresh means rerunning the command.
- No writes anywhere except the output file (and its parent directory).
  The herdr state root is read only; `.todos/` is never modified; no
  `TODO.md` regeneration.
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

## Confirmed facts (read 2026-09-07 at main `026f043`)

- `todos.sh` already exposes hidden verbs `_depends <file>` (prints the
  `depends_on` items one per line) and `_resolve <ref>` (prints one state
  token: `done|open|missing|merged|closed|unknown|invalid`). `_resolve`
  honours `TODOS_OFFLINE=1` (no `gh`), `TODOS_BASE_REF`, and `TODOS_GH`.
  It never prints `self`; `resolve_cached` adds that in `list`/`index`.
- Frontmatter reads are first-match `key: value` with one pair of
  surrounding quotes stripped (`frontmatter_value`). `depends_on` is a
  block list of `  - ` items inside the first `---` block.
- `TODO.md` sort key: dated todos first by `due` then priority weight;
  undated by priority weight then `created` (`regenerate_index`).
- Herdr state root is `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/herdr-orch`;
  per task: `tasks/<task_id>.json` (record), `.done.json` (completion),
  `.review.json` (verdict with `outcome`, `blocking_count`,
  `findings_ref`). A todo's task id is `td-` plus its basename
  (`todo_task_id`, core line 501). Live records observed with `status`
  in `in-progress|blocked|merged`, `workers[]` possibly absent on older
  records, `review_outcome` null or `approved`.
- `repo_slug` (core line 484): remote URL with trailing `.git`, scheme,
  and `user@` stripped, lowercased, non-`[a-z0-9]` runs to `-`, trimmed,
  plus `-` and the first 8 hex of sha256 of the trimmed original URL;
  no remote gives `local-<8hex>` of the resolved common dir.
- In a herdr worktree `.todos` is a symlink to the main checkout's
  `.todos` (observed here), so `.todos/research/` written from any
  worktree lands in one place.
- `python3` is 3.14 on this machine and a hard dependency of the
  orchestration core already; the renderer may use the stdlib only.
- Test baseline: `todos_test.sh` 162 passed, 0 failed.
- The repo test runner `bin/dotfiles-tests` lists suites in a `SUITES`
  block; a new suite must be added there to run in CI.

## Design

### D1. Command surface

`todos.sh dashboard [--open] [--online] [--out PATH] [--completed N]`

`todos.sh` gains exactly two lines: the usage string entry and a
dispatch case that execs the renderer with the same arguments:

```
dashboard) exec python3 "$(dirname "${BASH_SOURCE[0]}")/todos_dashboard.py" "$@" ;;
```

The renderer is `claude/skills/todos/scripts/todos_dashboard.py`,
Python 3 stdlib only, executable directly as well (`python3
todos_dashboard.py ...`). It locates `todos.sh` as its sibling file.

| Flag | Meaning |
|---|---|
| `--open` | After writing, open the file with `open` (Darwin) or `xdg-open` (else). A missing opener is a warning on stderr, exit stays 0. |
| `--online` | Let dependency resolution call `gh` (clears the default `TODOS_OFFLINE=1`). Default is offline, matching `index`. |
| `--out PATH` | Write to PATH instead of the default location. Parent directories are created. |
| `--completed N` | Number of completed todos to show (default 10; 0 hides the section). |

Environment overrides (tests and unusual setups):

| Variable | Default | Purpose |
|---|---|---|
| `TODOS_DASHBOARD_DIR` | `${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/dashboard` | Output directory; file is `<repo_slug>.html` |
| `TODOS_STATE_ROOT` | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/herdr-orch` | Herdr state root to read task records from |
| `TODOS_DASHBOARD_NOW` | current local time | `YYYY-MM-DD HH:MM` stamp printed in the header |
| `TODOS_TODAY` | today | Passed through to `todos.sh` calls (existing) |
| `TODOS_OFFLINE`, `TODOS_BASE_REF`, `TODOS_GH` | existing | Passed through to `todos.sh _resolve` |

Exit codes: 0 rendered; 1 usage error, not inside a git repository, or
the output file cannot be written. Unknown flags exit 1 with a `todos:`
prefixed message on stderr (same shape as the rest of the script).
On success stdout is exactly the absolute output path, one line.

A repo with no `.todos/` directory renders an empty board (every
section shows its empty-state line) and exits 0.

### D2. Data collection

Repo root is `git rev-parse --show-toplevel` from the current directory.

**Todos.** Every `*.md` under `.todos/pending/` and `.todos/completed/`,
sorted by basename. Per file the renderer reads, with the same rules as
`frontmatter_value`: `created`, `title` (falls back to the basename),
`area`, `priority`, `due`, `surface`, `maturity`, `tier`, and the
`files:` list. `depends_on` items come from `todos.sh _depends <file>`
so the list parser stays single-sourced. The body summary is the first
non-empty line under `## Problem`, cut at 140 characters (same rule as
`problem_summary`). Links are every `https?://` URL in the body,
deduplicated in order, capped at 5, classified by host: `claude.ai`
paths under `/code/artifacts/` or `/artifacts/` are labelled
`artifact`, `github.com/.../pull/<n>` is labelled `PR #<n>`, anything
else shows its host.

**Dependency state.** For pending todos only. Each ref is normalised
and resolved by one `todos.sh _resolve <ref>` call with cwd at the repo
root, memoised per ref for the run. A ref equal to `todo:<own
basename>` is `self` without a call. A todo is **blocked** when any ref
resolves to something other than `done` or `merged`; the row lists
every unsatisfied ref as `<ref> (<state>)`. Satisfied refs are still
shown, muted, so the reader sees the full graph. Completed todos never
resolve (as in `list --all`).

**Herdr task status.** For every todo (pending and completed) the
renderer looks for `<state_root>/<repo_slug>/tasks/td-<basename>.json`.
Missing file: no status (shown as a blank cell, `data-task-status=""`).
Present and valid JSON: `status`, the last `workers[]` entry's `phase`,
`role`, `model`, and `agent` (blank when the list is absent or empty),
`review_outcome`, `branch`. Then, if present and valid, `.review.json`
adds `outcome` and `blocking_count` and `findings_ref`, and `.done.json`
adds `outcome` and `phase`. A file that is present but unreadable or not
valid JSON sets the status text to `unreadable` for that record and the
run continues; nothing is ever written under the state root. Keys are
read defensively: a missing key is blank, never an exception.

`repo_slug` is computed in the renderer from `git remote get-url
origin` (else the common dir) by the rule in the confirmed facts; a
test pins it against `claude.hooks.herdr_orch_core.repo_slug` on fixed
inputs so drift is caught.

**Research.** Every `*.md` under `.todos/research/`, recursively, sorted
by `created` descending then path. Frontmatter: `created` (required;
files without it sort last and show `undated`), `title` (falls back to
the filename), `kind` (free text, e.g. `field-notes`, `review-findings`,
`report`), `task` (a task id or todo basename; rendered as a link to the
todo row when that basename exists on the page), `artifact` (a URL). The
summary is the first non-empty body line after the frontmatter, cut at
200 characters. Each entry links to the file itself with a `file://`
URL so it opens in the browser.

### D3. The `.todos/research/` convention

Documented in `claude/skills/todos/SKILL.md`, no tooling beyond the
index:

```
<repo>/.todos/research/
  YYYY-MM-DD-<slug>.md        durable report (field notes, a study, a decision memo)
  <task_id>/                  per-task material copied at merge time (future post-merge step)
    review-findings.md
```

Report frontmatter (all keys optional except `created` and `title`):

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

The directory inherits the `.todos/` visibility rule (local by default,
committed only after `todos.sh share`). Reports are hand-written or
saved by whichever session produced them; the dashboard is the index.

### D4. Page structure

Single HTML file, inline CSS, no script, no remote assets. Sections, in
order:

1. **Header.** Repo name (basename of the repo root), the generated
   stamp, the output of `git rev-parse --abbrev-ref HEAD` for the
   checkout the command ran in, and three counts: open, blocked, and
   in-flight (open todos with a readable task record whose `status` is
   not `merged`, `abandoned`, or `failed`; an unreadable record never
   counts).
2. **Open.** One table sorted with the `TODO.md` key. Columns: todo
   (title, basename beneath it, area chip, priority chip, `maturity` /
   `tier` chips when set), created / due, depends on (each ref with its
   state; blocked rows carry a state stripe), herdr (status pill, phase
   and worker line, review verdict with blocking count), links.
   Empty state: `No open todos.`
3. **Completed.** The `--completed N` most recent by `created` desc then
   basename desc. Columns: todo, created, herdr (same as above), links.
   Empty state: `Nothing completed yet.`
4. **Research.** List sorted per D2. Each entry: title (linked to the
   file), created, kind chip, task link, artifact link, summary.
   Empty state: `No research reports. Save durable notes under
   .todos/research/ (see the todos skill).`

Machine-readable hooks for tests and tooling, on every row:
`data-todo="<basename>"`, `data-state="open|blocked"` (pending rows),
`data-task-status="<status or empty>"`, and on research entries
`data-research="<path relative to .todos/research>"`. All text content
and attribute values pass through `html.escape(..., quote=True)`.

### D5. Visual design

The page is a board that is scanned, not read, so the craft is
information design: state in form before number. Tokens, all defined
on bare `:root` for light, redefined under
`@media (prefers-color-scheme: dark)` guarded as
`:root:not([data-theme="light"])`, and again under
`:root[data-theme="dark"]`; `body` paints its background from a token.

- Palette (light): ground `#f7f6f2` (warm paper, hue-biased toward the
  accent), ink `#1f2a24`, muted `#6b746e`, accent `#2f6f5e` (deep
  green, the todos skill's "open" colour), rule `#d9ddd7`. Semantic,
  separate from the accent: blocked `#b3541e`, merged `#3b6ea5`,
  in-flight `#8a6d1f`. Dark: ground `#171b19`, ink `#e8ece9`, muted
  `#9aa39d`, accent `#7fbfa8`, rule `#2c332f`, semantic colours lifted
  for contrast.
- Type: a humanist sans for everything (`"Avenir Next", "Segoe UI",
  system-ui, sans-serif`) with a monospace utility face (`"SF Mono",
  Menlo, Consolas, monospace`) for basenames, refs, and shas;
  `tabular-nums` on dates and counts; uppercase letter-spaced section
  eyebrows; headings `text-wrap: balance`.
- Layout: max width 1200px, one column of tables; the header counts are
  a flex row of three plain figures (no cards). Tables sit in an
  `overflow-x: auto` wrapper. Chips are the only rounded element; the
  blocked state also paints a 3px left stripe on the row so it reads
  without colour.
- Motion: none. `prefers-reduced-motion` needs nothing to respect.

The field notes artifact used the same warm-neutral ground and a
restrained chip vocabulary; this page follows that so the two read as
one system. The implementer loads the `artifact-design` skill for the
fundamentals and keeps the tokens above verbatim.

### D6. Orchestrator preflight

`claude/skills/herdr-orchestration/SKILL.md` section 1 gains one step
after the ownership claim:

```
   - Regenerate the board: `bash ~/.claude/skills/todos/scripts/todos.sh dashboard`
     (add `--open` on the initial claim only). Best-effort: a non-zero
     exit is reported in the turn summary and never blocks the action.
```

Nothing else in that skill changes.

### D7. Tests

New suite `claude/skills/todos/scripts/tests/todos_dashboard_test.sh`,
same helpers and output shape as `todos_test.sh` (`ok`/`bad` lines,
final `N passed, M failed`), registered in `bin/dotfiles-tests`. Every
test builds a throwaway git repo with `origin/main` set by
`update-ref`, a `.todos/` fixture set, and a fake state root passed via
`TODOS_STATE_ROOT`; `TODOS_OFFLINE=1`, `TODOS_TODAY`, and
`TODOS_DASHBOARD_NOW` pin determinism. No test opens a browser.

Fixture set (the "one blocked, one merged, one plain" of the task):

- `2026-05-01-plain.md`: pending, no deps, no task record.
- `2026-05-02-blocked.md`: pending, `depends_on: [todo:2026-05-01-plain, pr:7]`.
- `2026-05-03-merged.md`: completed; state root has
  `td-2026-05-03-merged.json` with `status: merged` and a `.review.json`
  with `outcome: approved`, `blocking_count: 0`.
- `2026-05-04-in-flight.md`: pending; record with `status: in-progress`,
  `workers[-1].phase: implement`.
- `2026-05-05-bad-record.md`: pending, title
  `<script>alert(1)</script>`; record file containing `{not json`.
- `research/2026-05-06-notes.md` and `research/td-x/review-findings.md`.

## Acceptance criteria

- AC1 **Renders the fixture board.** `todos.sh dashboard --out F` exits
  0, prints F, and F contains a row `data-todo="2026-05-02-blocked"
  data-state="blocked"` listing `todo:2026-05-01-plain (open)` and
  `pr:7 (unknown)`; a row for `2026-05-01-plain` with
  `data-state="open"`; a completed row for `2026-05-03-merged` with
  `data-task-status="merged"` and the text `approved`; an in-flight row
  with `data-task-status="in-progress"` and the text `implement`; and
  the header counts `open 4`, `blocked 1`, `in-flight 1`
  (rendered as `<b data-count="open">4</b>` etc.).
- AC2 **Bad records do not abort.** The `2026-05-05-bad-record` row
  renders with the text `unreadable`; exit stays 0.
- AC3 **Research index.** Both research files appear with
  `data-research="2026-05-06-notes.md"` and
  `data-research="td-x/review-findings.md"`, the first carrying its
  `kind` chip text and an `href` to its `artifact` URL, sorted newest
  first.
- AC4 **Escaping.** The `2026-05-05-bad-record` title appears only as
  `&lt;script&gt;alert(1)&lt;/script&gt;`; the raw `<script` string is
  absent from F.
- AC5 **Default path and slug.** With `TODOS_DASHBOARD_DIR=D` and an
  `origin` remote `git@github.com:Org/Repo.git`, the command writes
  `D/github-com-org-repo-<8hex>.html` where `<8hex>` equals what
  `herdr_orch_core.repo_slug` returns for the same URL; with no remote
  the name starts with `local-`.
- AC6 **Read-only.** After a render the fixture state root's file list
  and contents are byte-identical, and `.todos/` is unchanged (no
  `TODO.md` created or modified).
- AC7 **Empty board.** In a repo with no `.todos/`, exit 0 and F
  contains `No open todos.`
- AC8 **Flags.** `--completed 0` omits the completed table;
  `--completed 1` shows exactly one completed row (the newest by
  `created`); an unknown flag exits 1 with a `todos:` message on stderr.
- AC9 **Offline default.** With a `TODOS_GH` stub that records calls,
  a default render makes no `gh` call; `--online` makes at least one.
- AC10 **Dispatch is thin.** `todos.sh` diff against base adds at most
  four lines, all within the usage comment block and the `main` case;
  `todos_test.sh` is untouched; `todos_test.sh` still reports 0 failed.
- AC11 **Docs.** The todos skill documents the `dashboard` command row,
  the `.todos/research/` convention with its frontmatter keys, and the
  `TODOS_DASHBOARD_DIR` / `TODOS_STATE_ROOT` overrides; the
  orchestration skill's section 1 contains `todos.sh dashboard`.
- AC12 **Registered suite.** `bin/dotfiles-tests --list` includes the
  new test file.

## Verification not covered by tests

- Opening in a real browser on this machine and checking both colour
  schemes: human-verify after implementation (one look, per the design
  skill's rule).
- The orchestrator actually running the preflight step: human-verify on
  the next orchestrated turn after merge.

## Open questions resolved here

- Recency for completed todos uses `created`, not file mtime: `mv`
  preserves mtime and the completed record carries no completion date.
- The renderer is Python rather than bash because HTML escaping and
  JSON reading in bash are fragile, and the core already makes python3
  a hard dependency. Dependency resolution stays in `todos.sh` through
  the hidden verbs, so there is one resolver.
