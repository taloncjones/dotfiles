---
name: repo-recall
description: Use when answering questions about prior decisions, specs, plans, findings, todos, handoffs or session memory in the current repo -- "didn't we decide X", "what did the review say about Y", "find the spec/plan/todo about Z", "search our docs/notes/memory". Ranked SQLite FTS5 search over the repo's prose artifacts; not for code symbols (use LSP / grep).
---

# Repo Recall

A per-repo full-text index over prose artifacts, shared by Claude and Codex
and refreshed at query time. Resolve the directory containing this loaded
SKILL.md (including its symlink target), then invoke its adjacent script:

    python3 "<loaded-skill-directory>/scripts/recall.py" search <terms>

Run from the repo being searched; the script path is independent of its
installation under either runtime's skills directory.

## What it indexes

| Kind     | Where                                                      |
| -------- | ---------------------------------------------------------- |
| docs     | `docs/**/*.md`, `*.md` at the repo root                    |
| handoffs | `.claude/handoffs/*.md`, `.codex/handoffs/*.md`             |
| todos    | `.todos/pending/*.md`, `.todos/completed/*.md`             |
| findings | `docs/findings/**`, `.claude/findings/**`, `.codex/findings/**` (md, txt, jsonl) |
| memory   | Claude auto-memory for this tree and its main checkout     |
| extra    | `RECALL_EXTRA_GLOBS` (colon-separated, repo-relative)      |

Files over 1 MiB, symlinks, non-UTF-8 files, `.git/`, worktree dirs and
`node_modules/` are skipped. Every path is indexed once under the first
matching kind: memory, extra, findings, handoffs, todos, docs.

## Where the index lives

`<config_dir>/recall/<repo-id>/index.db`, always outside the repo.
`RECALL_CONFIG_DIR`, when set, overrides index storage for either runtime.
Within that shared root, the cache directory is
`<repo-id>-account-<digest>`, where the digest identifies the resolved
Claude memory root. Different accounts therefore cannot reuse each other's
cached memory through `--no-refresh` or a locked-refresh fallback.
`CLAUDE_PERSONAL_ONLY=1` makes the memory account `~/.claude` for every
repo on a personal machine, regardless of inherited account variables or
repo location. It also selects default storage there; an explicit
`RECALL_CONFIG_DIR` continues to override storage alone.

Otherwise, a checkout or canonical repository owner under `~/Git/personal`
uses `~/.claude` for memory and default storage, even when
`CLAUDE_CONFIG_DIR` was inherited from a work session. Either personal
location wins, including linked worktrees and separate Git metadata.
Other repos honor `CLAUDE_CONFIG_DIR` if set, else route `~/Git/work` to
`~/.claude-work`, else use `~/.claude`; configured work-tree/account
overrides retain their existing meaning.
Both runtimes use the same index for the same checkout and memory account
by sharing these settings; do not select a different cache automatically
just because the caller is Codex. Existing default cache paths are unchanged.

The storage override does not change Claude memory discovery: memory stays
scoped to this repo and its main checkout under the account route above.
Personal repos never discover inherited work-account memory. Global Codex
memories and sessions are never indexed. `recall.py
status` prints both storage and memory roots. Different worktrees retain
separate indexes so their differing files cannot overwrite each other's
search results.

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
