# Repo Recall: per-repo full-text recall for docs, findings, todos, memory

Status: draft for codex-spec-review
Date: 2026-09-01
Todo: `.todos/pending/2026-09-01-ship-per-repo-full-text-recall-skill-for-docs-and.md`

## Problem

Large project repos accumulate specs, plans, findings, todos, handoffs and
session memory that are queried fuzzily ("didn't we decide X?", "what did the
review say about Y?"). `grep` answers exact-token questions; prose recall
degrades with corpus size because the asker does not remember the exact
words. Code search is already covered by LSP plugins and codemaps and is out
of scope here.

## Goal

A dotfiles-shipped skill plus one script that gives any session (human or
worker agent) a ranked full-text search over a repo's prose artifacts, with
zero per-repo setup, no committed index, and correct account isolation for
work repos.

First release is FTS-only (SQLite FTS5, BM25). Embeddings are explicitly
deferred behind a falsifiable evaluation defined in this spec.

## Non-goals (v1)

- Vector / embedding search (sqlite-vec). See "Embeddings decision" below.
- Indexing source code. LSP plugins and codemaps own that.
- Cross-repo search. One index per working tree.
- A daemon, file watcher, or background hook. Freshness is enforced at query
  time (see "Freshness").
- A per-repo config file. Sources are convention-based with one env override.

## Deliverables

| Path | What |
| --- | --- |
| `claude/skills/repo-recall/SKILL.md` | Skill: when to use, commands, how workers call it, degradation behaviour |
| `claude/skills/repo-recall/scripts/recall.py` | Single stdlib-only Python 3 script: `index`, `search`, `status`, `eval` |
| `claude/skills/repo-recall/scripts/tests/recall_test.sh` | Shell test suite in the repo's PASS/FAIL style |
| `claude/skills/.gitignore` | Add `!/repo-recall/` to the whitelist |
| `bin/dotfiles-tests` | Register the new suite in `SUITES` |
| `docs/recall-eval.jsonl` (per repo, optional) | Golden queries for the embeddings decision |

No changes to `settings.json.tmpl`, hooks, or the installer: `claude/skills`
is already symlinked whole-dir into both config dirs, so the skill ships on
the next `update` / link run.

Runtime dependencies: `python3` with a `sqlite3` module compiled with FTS5.
Confirmed on this machine (Python's bundled SQLite 3.53.4, FTS5 present).
`sqlite3` CLI is not required.

## Sources (what gets indexed)

All paths are relative to the **working tree top level** (`git rev-parse
--show-toplevel`). Every source is optional; a missing source is silently
skipped. Files are indexed only if they match `*.md` (plus `*.txt` and
`*.jsonl` for findings), are under 1 MiB, and decode as UTF-8.

| Kind | Globs | Notes |
| --- | --- | --- |
| `docs` | `docs/**/*.md`, `*.md` at repo root | Specs, plans, superpowers docs, README, CLAUDE.md, AGENTS.md |
| `handoffs` | `.claude/handoffs/*.md` | Session handoff briefs |
| `todos` | `.todos/pending/*.md`, `.todos/completed/*.md` | The todos skill's backlog. `TODO.md` index is skipped (derived) |
| `findings` | `docs/findings/**/*`, `.claude/findings/**/*` | Reserved location. Nothing writes here today; co-review reports live in chat. The sibling todo "distill recurring agent findings into standing rules" may adopt it. Indexed if present so it works the day something lands |
| `memory` | `<config_dir>/projects/<slug>/memory/*.md` | Claude Code auto-memory. `<slug>` = absolute path with every non-alphanumeric byte replaced by `-`. Two slugs are checked: the working tree top level and the canonical repo root (`--git-common-dir` parent), so a worktree session sees the main checkout's memory. `MEMORY.md` (the index) is skipped |

Excluded everywhere: `.git/`, `.worktrees/`, `.claude/worktrees/`,
`node_modules/`, any directory starting with `.` other than `.todos` and
`.claude`. Symlinks are not followed.

Override: `RECALL_EXTRA_GLOBS` (colon-separated globs relative to the top
level) adds sources of kind `extra`. This is the only configuration knob.

## Index location and account isolation

The index never lives inside the repo, so it can never be committed and needs
no `info/exclude` entry.

```
<config_dir>/recall/<slug-of-toplevel>/index.db
```

`<config_dir>` resolves in this order:

1. `$CLAUDE_CONFIG_DIR` if set (the same rule the `claude()` zsh wrapper and
   `account_guard.py` honour).
2. Else, if the top level is under `$CLAUDE_WORK_TREE` (default
   `~/Git/work`) and `~/.claude-work` exists: `~/.claude-work`.
3. Else `~/.claude`.

Consequence: a work repo's index and its memory source both resolve under
the work account's config dir. A personal repo never reads or writes
`~/.claude-work`. `recall.py status` prints the resolved config dir, index
path, and source counts so the routing is auditable.

Each working tree (main checkout or linked worktree) gets its own index
because their `docs/` and `.todos/` contents differ per branch.

## Data model

SQLite file, WAL off (single writer, tiny corpus), two tables:

```sql
CREATE TABLE files (
  path      TEXT PRIMARY KEY,   -- absolute path
  kind      TEXT NOT NULL,      -- docs|handoffs|todos|findings|memory|extra
  mtime_ns  INTEGER NOT NULL,
  size      INTEGER NOT NULL
);
CREATE VIRTUAL TABLE chunks USING fts5(
  path UNINDEXED, kind UNINDEXED, line UNINDEXED,
  heading, body,
  tokenize = 'porter unicode61'
);
```

Chunking: a markdown file is split at every heading line (`#` through
`###`); the text before the first heading is one chunk with the file's title
(first H1 or filename) as its heading. YAML front matter is kept in the first
chunk's body so `title:`/`area:` fields are searchable. Non-markdown findings
files are one chunk per file. `line` is the 1-based line of the chunk's
heading, giving `path:line` anchors in output.

Ranking: `bm25(chunks, 0, 0, 0, 3.0, 1.0)` (heading weight 3, body weight 1).

## Commands

Called by absolute path: `~/.claude/skills/repo-recall/scripts/recall.py`.

### `recall.py index [--full] [--quiet]`

Incremental by default: walks the sources, compares `(mtime_ns, size)` with
the `files` table, re-chunks changed/new files, deletes rows for vanished
files. `--full` drops and rebuilds. Prints a one-line summary
(`indexed N files (+a ~m -d), K chunks`). Exit 0.

### `recall.py search <query...> [--limit N] [--kind K]... [--json] [--no-refresh] [--raw]`

1. Runs the incremental `index` first unless `--no-refresh` (see Freshness).
2. Builds the FTS query. Default mode: each whitespace-separated term is
   quoted and the terms are joined with implicit AND, so user input can
   never break FTS5 syntax. `--raw` passes the query through verbatim for
   FTS5 operators (`OR`, `NEAR`, `prefix*`, column filters); a parse error in
   raw mode exits 4 with SQLite's message.
3. Prints up to `--limit` (default 8) hits, best first:

```
1. docs/specs/2026-08-30-codex-hook-cleanup.md:42  [docs]  ## Decision
   ...snippet with >>matched<< terms, one line, <= 200 chars...
```

`--json` emits one object per line: `{rank, score, path, line, kind,
heading, snippet}`. `--kind` is repeatable and filters by source kind.

Exit codes: 0 hits; 1 no hits; 2 no sources found in this repo (message
names the conventional locations it looked for); 3 not inside a git working
tree; 4 query error; 5 SQLite lacks FTS5 (message names the fix:
a Python whose sqlite3 has FTS5, e.g. Homebrew python).

### `recall.py status`

Prints config dir, index path, per-kind file/chunk counts, last index time,
and whether FTS5 is available. Never exits non-zero for missing sources.

### `recall.py eval [<file>] [--k 5]`

Reads golden queries (default `docs/recall-eval.jsonl` under the top
level), one JSON object per line:

```json
{"q": "why did we drop the codex hook", "expect": ["docs/specs/2026-08-30-codex-hook-cleanup.md"], "note": "paraphrase"}
```

`expect` entries are top-level-relative paths, optionally `path#heading
text`. A query is a hit at k if any expected entry appears in the top k
results. Prints per-query hit/miss with the rank achieved, then
`recall@k`, `MRR`, and the miss list grouped by `note`. Exit 0 always
(reporting tool, not a gate).

## Freshness

`search` refreshes incrementally before querying. Cost is one `stat` per
candidate file plus re-chunking of changed files; for the corpora in scope
(hundreds of markdown files) this is well under a second, so results are
always current without a hook. `--no-refresh` exists for tight loops and
tests. A SessionStart hook is deliberately not added: it would touch the
template-owned `hooks` key, the drift test, and both config dirs for no
correctness gain.

## Skill behaviour (`SKILL.md`)

- Trigger phrases: "didn't we decide", "what did the review say", "find the
  spec/plan/todo about", "search our docs/notes/memory", any question about
  prior decisions that is not a code-symbol lookup.
- Workers call `search` by absolute path and read the `path:line` anchors
  before answering; the skill instructs them to open the file at the anchor
  rather than trusting the snippet.
- When exit is 2 the skill says so in one line and falls back to `grep`/`rg`.
  It does not create any files in the repo.
- Recording a miss: when a human or worker notes that recall failed to find
  something that exists, append a line to `docs/recall-eval.jsonl` with the
  paraphrased query, the expected path, and a `note` classifying the miss
  (`paraphrase`, `synonym`, `tokenization`, `missing-source`). This is the
  input to the embeddings decision.

## Embeddings decision (falsifiable)

Add a sqlite-vec column only if all of the following hold, measured with
`recall.py eval` on a repo's golden set:

1. The golden set has at least 30 queries collected from real misses or real
   questions (not synthetic), across at least 2 source kinds.
2. `recall@5 < 0.80` after the cheap fixes are applied: adding `synonym`
   terms to the query, prefix matching, and closing `missing-source` gaps.
3. At least half of the remaining misses are tagged `paraphrase` (the asker
   used different words for the same concept), which is the failure class
   embeddings address. `tokenization` and `synonym` misses are FTS
   configuration problems and do not count toward the threshold.

If 1-3 hold, the follow-up is a second column populated by a local embedding
model, hybrid-scored with BM25, evaluated against the same golden set with
the pass bar `recall@5 >= 0.90`. If they do not hold within the first two
months of use, embeddings stay out and the todo is closed.

## Error handling

- Not a git repo: exit 3, message, no files written.
- Unreadable or non-UTF-8 file: skipped with a warning to stderr unless
  `--quiet`; never aborts the index.
- Index file corrupt (SQLite `DatabaseError` on open): rename to
  `index.db.corrupt-<ts>`, rebuild full, warn on stderr.
- Concurrent writers (two sessions in the same tree): SQLite's default lock
  with a 5 s busy timeout; a `search` that loses the lock proceeds with
  `--no-refresh` semantics and warns.
- Config dir not writable: exit 2 with the path in the message.

## Testing

`recall_test.sh` builds throwaway git repos in `mktemp -d`, sets
`CLAUDE_CONFIG_DIR` (and `HOME`, `CLAUDE_WORK_TREE`) to temp paths so nothing
touches the real config dirs, and covers:

1. Repo with no sources: `search` exits 2 with the conventional-locations
   message; `status` exits 0.
2. Index + search hit: heading-weighted ranking (a heading match outranks a
   body match), `path:line` anchor matches the heading's line.
3. Kinds: `docs`, `todos`, `handoffs`, `memory` (both slugs), `findings`,
   `extra` via `RECALL_EXTRA_GLOBS`; `--kind` filter.
4. Incremental refresh: modify a file, delete a file, add a file; `search`
   reflects each without `--full`; `--no-refresh` does not.
5. Account routing: a tree under `$CLAUDE_WORK_TREE` with `~/.claude-work`
   present writes under `~/.claude-work/recall/`; the same tree with
   `CLAUDE_CONFIG_DIR` set honours the override; a personal tree never
   creates `~/.claude-work`.
6. Worktree: a linked worktree gets its own index and sees the main
   checkout's memory slug.
7. `--json` shape, `--raw` parse error exit 4, default-mode quoting survives
   `"`, `*`, `(`.
8. `eval`: golden file with one hit and one miss reports `recall@5 = 0.5`
   and the miss grouped under its note.
9. Corrupt index file is quarantined and rebuilt.
10. `RECALL_FORCE_NO_FTS5=1` (test-only env) exercises the exit-5 path.

The suite is registered in `bin/dotfiles-tests` and runs in CI with the
others. Baseline before the change: `dotfiles-tests` reports 16 suites.

## Acceptance criteria

- In this dotfiles worktree, `recall.py search codex hook cleanup` returns
  the codex-hook-cleanup handoff or spec as the top hit in under 1 s on a
  cold index.
- `recall.py status` in a repo with no docs/todos/memory reports zero
  sources and exits 0; `search` there exits 2 with a one-line explanation.
- `git status` in any indexed repo shows no new files.
- A repo under `~/Git/work` produces `~/.claude-work/recall/...` and nothing
  under `~/.claude/recall/`.
- `dotfiles-tests` passes with 17 suites.
- `SKILL.md` frontmatter follows the existing personal skills (name,
  description with trigger phrases) and the skill is whitelisted in
  `claude/skills/.gitignore`.

## Open questions resolved in this spec

- Hook vs on-demand: on-demand with refresh-on-search. No hook in v1.
- Index in repo vs config dir: config dir. Satisfies "never committed" and
  "work indexes under work account" structurally, not by convention.
- Per-worktree vs per-repo index: per working tree; memory pulls from both
  the worktree slug and the canonical root slug.
- Findings location: reserved `docs/findings/` and `.claude/findings/`;
  nothing produces them yet.
