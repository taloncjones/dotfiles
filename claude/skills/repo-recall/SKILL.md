---
name: repo-recall
description: Use when answering questions about prior decisions, specs, plans, findings, todos, handoffs or session memory in the current repo -- "didn't we decide X", "what did the review say about Y", "find the spec/plan/todo about Z", "search our docs/notes/memory". Ranked SQLite FTS5 search over the repo's prose artifacts; not for code symbols (use LSP / grep).
---

# Repo Recall

A per-repo full-text index over prose artifacts, stored under the active
Claude config dir (never in the repo), refreshed at query time. One script,
called by absolute path:

    ~/.claude/skills/repo-recall/scripts/recall.py

## What it indexes

| Kind     | Where                                                      |
| -------- | ---------------------------------------------------------- |
| docs     | `docs/**/*.md`, `*.md` at the repo root                    |
| handoffs | `.claude/handoffs/*.md`                                    |
| todos    | `.todos/pending/*.md`, `.todos/completed/*.md`             |
| findings | `docs/findings/**`, `.claude/findings/**` (md, txt, jsonl) |
| memory   | Claude auto-memory for this tree and its main checkout     |
| extra    | `RECALL_EXTRA_GLOBS` (colon-separated, repo-relative)      |

Files over 1 MiB, symlinks, non-UTF-8 files, `.git/`, worktree dirs and
`node_modules/` are skipped. Every path is indexed once under the first
matching kind: memory, extra, findings, handoffs, todos, docs.

## Where the index lives

`<config_dir>/recall/<repo-id>/index.db`. The config dir follows the
`claude()` wrapper rule: `CLAUDE_CONFIG_DIR` if set, else `~/.claude-work`
for trees under `~/Git/work`, else `~/.claude`. So a work repo's index and
memory stay under the work account. `recall.py status` prints the resolved
paths.

## Commands

| Command                                                                              | Does                                                                             |
| ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `recall.py search <terms...> [--limit N] [--kind K] [--json] [--raw] [--no-refresh]` | Refresh, then rank. Terms are AND-ed; `--raw` passes FTS5 syntax through         |
| `recall.py index [--full] [--quiet]`                                                 | Refresh the index (search does this for you)                                     |
| `recall.py status [--all]`                                                           | Show routing, counts, last index; `--all` lists every index under the config dir |
| `recall.py eval [file] [--k N]`                                                      | Score the golden set (`docs/recall-eval.jsonl`)                                  |
| `recall.py eval add "<q>" --expect <path>[#heading] [--note N]`                      | Record a golden query (human-requested only)                                     |

Output line: `N. path:line  [kind]  Heading` then a one-line snippet.
`--json` prints one object per line and nothing else on stdout.

Exit codes: 0 hits, 1 no hits, 2 no sources here, 3 not a git tree, 4 raw
query error, 5 python3's sqlite3 lacks FTS5, 6 config dir problem, 7 index
locked or missing, 8 bad eval input, 64 usage.

## How to use it as a worker

1. Run `search` with the concept words, not a sentence:
   `recall.py search frobnicator decision`.
2. Open the file at the `path:line` anchor before answering. The snippet
   is a pointer, not evidence.
3. Exit 2 or 5: say so in one line and fall back to `rg`.
4. Never create files in the repo on the tool's behalf. `eval add` runs
   only when the user asks to record a query, and never with queries that
   contain secrets or customer data.
5. Golden queries are stored verbatim and never edited, with one exception:
   an entry found to contain sensitive data is deleted or redacted at once
   (the user decides which). A redacted query is re-added as a new entry
   with today's `added` date so longitudinal comparisons exclude it.

## Known limits

- An edit that keeps both mtime and size is not detected until
  `index --full`. Editors and git checkouts change mtime, so this does not
  occur in normal use.
- Headings deeper than `###` stay inside their parent section.
- Symlinked directories (e.g. `.todos` shared across worktrees) are never
  indexed — symlinks are deliberately not descended to prevent scope expansion.

## Golden set and the embeddings decision

`docs/recall-eval.jsonl` records real questions as they are asked, hits and
misses alike, with a `note` (`hit`, `paraphrase`, `synonym`,
`tokenization`, `missing-source`). Embeddings are added only if, with at
least 30 real queries over 4 weeks, `recall@5 < 0.80` after FTS-level fixes
and at least half the misses are `paraphrase`. The full rule is in
`docs/specs/2026-09-01-repo-recall-skill.md`.
