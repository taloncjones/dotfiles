# Repo Recall: per-repo full-text recall for docs, findings, todos, memory

Status: reviewed (codex-spec-review rounds 1-2, 2026-09-01); ready-to-plan
Date: 2026-09-01
Todo: `.todos/pending/2026-09-01-ship-per-repo-full-text-recall-skill-for-docs-and.md`
(this spec supersedes the todo's Solution section where they differ, notably
"rebuilt by a hook": v1 refreshes at query time and ships no hook)

## Problem

Large project repos accumulate specs, plans, findings, todos, handoffs and
session memory that are queried fuzzily ("didn't we decide X?", "what did the
review say about Y?"). `grep` answers exact-token questions; prose recall
degrades with corpus size because the asker does not remember the exact
words. Code search is already covered by LSP plugins and codemaps and is out
of scope here.

## Goal

A dotfiles-shipped skill plus one script that gives a Claude Code session
(interactive or worker agent) or a direct shell caller a ranked full-text
search over a repo's prose artifacts, with zero per-repo setup, no committed
index, and correct account isolation for work repos.

First release is FTS-only (SQLite FTS5, BM25). Embeddings are explicitly
deferred behind a falsifiable evaluation defined in this spec.

## Non-goals (v1)

- Vector / embedding search (sqlite-vec). See "Embeddings decision".
- Indexing source code. LSP plugins and codemaps own that.
- Cross-repo search. One index per working tree.
- A daemon, file watcher, or background hook. Freshness is enforced at query
  time (see "Freshness").
- A per-repo config file. Sources are convention-based with one env override.
- A Codex-side skill mirror. Codex skills are managed independently in this
  repo; Codex sessions can call the script directly by path.

## Deliverables

| Path | What |
| --- | --- |
| `claude/skills/repo-recall/SKILL.md` | Skill: when to use, commands, how workers call it, degradation behaviour |
| `claude/skills/repo-recall/scripts/recall.py` | Single stdlib-only Python 3 script: `index`, `search`, `status`, `eval`, `eval add` |
| `claude/skills/repo-recall/scripts/tests/recall_test.sh` | Shell test suite in the repo's PASS/FAIL style |
| `claude/skills/.gitignore` | Add `!/repo-recall/` to the whitelist |
| `bin/dotfiles-tests` | Register the new suite in `SUITES` |
| `docs/recall-eval.jsonl` (per repo, optional) | Golden queries for the embeddings decision |

No changes to `settings.json.tmpl`, hooks, or the installer: `claude/skills`
is already symlinked whole-dir into both config dirs, so the skill ships on
the next `update` / link run.

Runtime: `python3` >= 3.9 whose `sqlite3` module has FTS5. Supported
platforms are the ones the dotfiles support: macOS (system or Homebrew
python3) and Linux (apt or Linuxbrew python3). Confirmed present on this
macOS machine (Python's bundled SQLite 3.53.4). The script probes FTS5 at
startup by creating an in-memory FTS5 table; the plan includes a live check
on a Linux container. No `uv` project, no third-party packages; `ruff`
clean under the repo's Python rules.

## Sources (what gets indexed)

All in-repo paths are relative to the **working tree top level** (`git
rev-parse --show-toplevel`, symlinks resolved). Every source is optional; a
missing source is silently skipped.

Eligibility (applies to every kind, including `extra`): regular file, not a
symlink, resolved path inside the top level (memory: inside its memory dir),
extension in the kind's allowed set, size <= 1 MiB, decodes as UTF-8.

| Kind | Globs | Extensions | Notes |
| --- | --- | --- | --- |
| `memory` | `<config_dir>/projects/<slug>/memory/*.md` | md | Claude Code auto-memory for two project slugs: the top level and the canonical repo root (`--git-common-dir` parent), deduplicated when equal. `MEMORY.md` (the index) skipped. Slug = absolute path with every non-alphanumeric byte replaced by `-`, exactly as Claude Code names `~/.claude/projects/` entries |
| `extra` | `RECALL_EXTRA_GLOBS` (colon-separated, top-level-relative) | md, txt, jsonl | The only configuration knob. Globs containing `..` or resolving outside the top level are rejected with a warning |
| `findings` | `docs/findings/**/*`, `.claude/findings/**/*` | md, txt, jsonl | Reserved location. Nothing writes here today; co-review reports live in chat. The sibling todo "distill recurring agent findings into standing rules" may adopt it |
| `handoffs` | `.claude/handoffs/*.md` | md | Session handoff briefs |
| `todos` | `.todos/pending/*.md`, `.todos/completed/*.md` | md | The todos skill backlog. `TODO.md` skipped (derived) |
| `docs` | `docs/**/*.md`, `*.md` at top level | md | Specs, plans, superpowers docs, README, CLAUDE.md, AGENTS.md |

Kind precedence and deduplication: each resolved path is indexed exactly
once. When a file matches several kinds it takes the first kind in the table
order above (`memory` > `extra` > `findings` > `handoffs` > `todos` > `docs`),
so `docs/findings/x.md` is `findings`, not `docs`.

Excluded directories everywhere: `.git/`, `.worktrees/`, `.claude/worktrees/`,
`node_modules/`, and any directory starting with `.` other than `.todos` and
`.claude`. Symlinked directories are not descended.

## Index location and account isolation

The index lives under the active Claude config dir, never inside the repo,
so it cannot be committed and needs no `info/exclude` entry.

```
<config_dir>/recall/<repo-id>/index.db
<repo-id> = <slug truncated to 80 bytes>-<first 12 hex of sha256(resolved top level)>
```

The hash suffix makes the id collision-free and bounded even though the slug
is lossy.

`<config_dir>` resolves with the same rule as `_claude_config_dir()` in
`zsh/functions.zsh` and `account_guard.py`:

1. `$CLAUDE_CONFIG_DIR` if set.
2. Else, if the resolved top level is under `$CLAUDE_WORK_TREE` (default
   `~/Git/work`, symlinks resolved on both sides): `$CLAUDE_WORK_CONFIG_DIR`
   (default `~/.claude-work`), created if absent (mode 0700), matching the
   wrapper, which also routes there before the dir exists.
3. Else `~/.claude`.

Guarantees:

- The resolved index path must not be inside the working tree or the
  canonical repo root (symlink-resolved). If it is, exit 6 with the path.
- Account boundary: the resolved config dir is the active account. Index
  state and the external `memory` source are read and written only under
  that one config dir (repo files are, of course, read from the tree). A
  deliberate `CLAUDE_CONFIG_DIR` override moves the boundary, exactly as it
  moves the Claude login. Tested with sentinel memory files in each config
  dir that must never appear in the other account's results.
- Index dir and file are created with mode 0700 / 0600.
- `recall.py status` prints the resolved config dir, index path, and
  per-kind counts so the routing is auditable.
- Stale indexes (top level deleted) are not auto-purged; `status --all`
  lists every index under the config dir with its recorded top level and
  whether it still exists, so a human can `rm` them. `--all` routes
  without git: `$CLAUDE_CONFIG_DIR` if set, else the resolved current
  directory classified against `$CLAUDE_WORK_TREE`. It only reads; an
  unreadable or corrupt index is listed as `corrupt` and left untouched. Corrupt-index backups:
  at most one `index.db.corrupt` is kept (newer replaces older).

Each working tree (main checkout or linked worktree) gets its own index
because their `docs/` and `.todos/` contents differ per branch.

## Data model

SQLite file, default journal, `busy_timeout = 5000`, three tables:

```sql
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
  -- schema_version, toplevel, last_index_at (ISO-8601 UTC), last_index_ok
CREATE TABLE files (
  path      TEXT PRIMARY KEY,   -- absolute, resolved
  display   TEXT NOT NULL,      -- see "Display paths"
  kind      TEXT NOT NULL,
  mtime_ns  INTEGER NOT NULL,
  size      INTEGER NOT NULL,
  sha256    TEXT NOT NULL
);
CREATE VIRTUAL TABLE chunks USING fts5(
  display UNINDEXED, kind UNINDEXED, line UNINDEXED,
  heading, body,
  tokenize = 'porter unicode61'
);
```

`schema_version` mismatch on open triggers a full rebuild (no migration
code in v1).

Chunking (markdown): split at every ATX heading line `#`, `##`, `###`
(deeper headings stay in their parent's body). Heading text is the line with
leading `#`s, trailing `#`s and surrounding whitespace stripped. The heading
line itself is not part of the body. Text before the first heading is the
preamble chunk: heading = first H1 text if the file has one, else the file
name; `line` = 1. A chunk whose body is blank after stripping is dropped.
YAML front matter stays in the preamble body so `title:`/`area:` fields are
searchable. A file with no headings is one chunk (heading = file name, line
1). Non-markdown files (txt, jsonl) are one chunk per file. `line` is the
1-based line of the chunk's heading.

Ranking: `bm25(chunks, 0, 0, 0, 3.0, 1.0)` (heading weight 3, body 1). Ties
break by `display`, then `line`, ascending, so output is deterministic.

## Display paths

- In-repo files: path relative to the top level (`docs/specs/x.md`).
- Memory files: tilde-abbreviated absolute path
  (`~/.claude/projects/<slug>/memory/x.md`), never the raw home directory.

Display paths are what `search` prints, what `--json` carries, and what
`eval` matches against.

## Commands

Called by absolute path: `~/.claude/skills/repo-recall/scripts/recall.py`.
All commands: usage errors (unknown option, empty or whitespace-only query,
`--limit` outside 1..100, unknown `--kind`) exit 64 with a one-line usage
message on stderr. Warnings always go to stderr.

### `recall.py index [--full] [--quiet]`

Incremental by default. For each eligible file, compares `(mtime_ns, size)`
with `files`; on any difference recomputes `sha256`, and re-chunks only when
the hash changed. Files that vanished or became ineligible (oversized,
unreadable, non-UTF-8, excluded, symlinked) are removed. A file whose kind
changed is re-indexed under the new kind. `--full` drops and rebuilds. The
whole refresh is one transaction: readers see the old index or the new one,
never a partial one; an interrupted refresh leaves the old index intact.
Prints `indexed N files (+a ~m -d), K chunks` on stdout. Exit 0; exit 7 if
the index is locked for longer than the busy timeout.

Known limit, documented in `SKILL.md`: an edit that preserves both mtime
and size is not detected until `--full`. Git checkouts and editors update
mtime, so this does not occur in normal use.

### `recall.py search <query...> [--limit N] [--kind K]... [--json] [--no-refresh] [--raw]`

1. Runs the incremental refresh first unless `--no-refresh`. Its summary and
   any warnings go to stderr, so stdout carries results only. If the index
   is locked: with a usable prior index, search it and warn; with no prior
   index, exit 7. `--no-refresh` with no index exits 7.
2. Builds the FTS query. Default mode: each whitespace-separated term is
   double-quoted (embedded `"` doubled) and terms are joined with implicit
   AND, so user input cannot break FTS5 syntax. `--raw` passes the query
   through verbatim for FTS5 operators; a parse error exits 4 with SQLite's
   message.
3. Prints up to `--limit` (default 8, max 100) hits, best first:

```
1. docs/specs/2026-08-30-codex-hook-cleanup.md:42  [docs]  Decision
   ...snippet with >>matched<< terms, one line, <= 200 chars...
```

`--json` emits one object per line on stdout and nothing else:
`{rank, score, path, line, kind, heading, snippet}` where `path` is the
display path. `--kind` is repeatable and filters by source kind.

Exit codes: 0 hits; 1 no hits; 2 no eligible sources in this repo (message
lists the conventional locations searched); 3 not inside a git working
tree; 4 raw query parse error; 5 SQLite lacks FTS5 (message names the fix:
a python3 whose sqlite3 has FTS5, e.g. Homebrew python); 6 config dir not
writable or index path resolves inside the repo; 7 index locked / missing;
64 usage.

### `recall.py status [--all]`

Prints config dir, index path, schema version, script version, per-kind
file/chunk counts, `last_index_at`, and whether FTS5 is available. `--all`
lists every index under the config dir (routing per "Index location") with
its recorded top level, existence, and `corrupt` where the file cannot be
opened; it never rebuilds or quarantines. Never exits non-zero for missing
sources; exits 3 outside a git tree (without `--all`).

### `recall.py eval [<file>] [--k 5]`

Reads golden queries (default `docs/recall-eval.jsonl` under the top
level), one JSON object per line:

```json
{"q": "why did we drop the codex hook", "expect": ["docs/specs/2026-08-30-codex-hook-cleanup.md"], "note": "paraphrase", "added": "2026-09-01"}
```

Schema: `q` non-empty string; `expect` non-empty list of display paths,
each optionally suffixed `#<heading text>` (compared case-insensitively
after the same normalization as chunk headings); `note` one of `hit`,
`paraphrase`, `synonym`, `tokenization`, `missing-source`; `added` ISO date.
The command runs one incremental refresh, then evaluates every query
against that single snapshot (`--no-refresh` semantics for the rest of the
run). Validation failures (malformed JSON, wrong types, unknown note,
duplicate `q`, expected path not currently indexed unless `note` is
`missing-source`) are listed and the command exits 8 without printing
metrics. `missing-source` entries with an absent expected path are legal,
always count as misses, and stay in the file until the source gap is
closed and the note is changed. A query hits at k if any expected entry appears
in the top k results (path match, plus heading match when a heading suffix
is given). Output: a header line with the script version (`RECALL_VERSION`, a
constant bumped whenever ranking, tokenization, chunking, or the synonym
table changes), `k`, `n`, and `last_index_at`; then per-query hit/miss
with rank achieved; then `recall@k` and `MRR` to two decimals; then misses
grouped by `note`. Exit 0 on
a valid run regardless of scores (reporting tool, not a gate).

### `recall.py eval add "<q>" --expect <display-path>[#heading]... [--note N]`

Appends one validated line to `docs/recall-eval.jsonl` (single
`O_APPEND` write, so concurrent appends do not interleave), refusing
duplicates of `q`. Default note is `hit`. This is the only way the skill
writes into a repo, and only when a human asks for it (see Skill behaviour).

## Freshness

`search` refreshes incrementally before querying. Cost is one `stat` per
candidate file plus hashing and re-chunking of changed files; for the corpora
in scope (hundreds of markdown files) this is well under a second, so results
reflect the working tree as of the query, subject to the documented
mtime+size limit. `--no-refresh` exists for tight loops and tests. A
SessionStart hook is deliberately not added: it would touch the
template-owned `hooks` key, the drift test, and both config dirs for no
correctness gain.

## Skill behaviour (`SKILL.md`)

- Trigger phrases: "didn't we decide", "what did the review say", "find the
  spec/plan/todo about", "search our docs/notes/memory", any question about
  prior decisions that is not a code-symbol lookup.
- Workers call `search` by absolute path and open the file at the
  `path:line` anchor before answering; the snippet is a pointer, not
  evidence.
- Exit 2 or 5: say so in one line and fall back to `rg`. The skill never
  creates files in the repo on its own.
- Golden-set capture is opt-in and human-driven: when the user says to
  record a query ("add that to the recall eval"), run `eval add` with the
  query verbatim, the expected path, and a `note`. Workers never append on
  their own. Queries that contain secrets or customer data are not recorded
  (the file may be committed). Privacy exception to "never edited": an
  entry found to hold sensitive data is deleted or redacted immediately
  (the human decides which), and a redacted entry is re-added as a new
  entry with today's `added` date so longitudinal comparisons exclude it.

## Embeddings decision (falsifiable)

The golden set is prospective, not miss-only: it records real questions as
they are asked, hits and misses alike, so `recall@k` estimates real recall
rather than the miss rate. Queries are stored verbatim and never edited.

Add a sqlite-vec column only if all of the following hold, measured with
`recall.py eval`:

1. The set has at least 30 queries from real use (not synthetic), spanning
   at least 2 source kinds, collected over at least 4 weeks.
2. After product-level fixes shipped in `recall.py` (tokenizer settings, a
   synonym table applied to queries, prefix matching, closing
   `missing-source` gaps), a re-run of the unchanged golden file gives
   `recall@5 < 0.80`. Fixes are versioned in the script; eval output prints
   the script version so runs are comparable.
3. At least half of the remaining misses are noted `paraphrase` (different
   words for the same concept), the failure class embeddings address.
   `tokenization` and `synonym` misses are FTS configuration problems and
   do not count.

If 1-3 hold, the follow-up is a second column populated by a local embedding
model, hybrid-scored with BM25. Its pass bar is `recall@5 >= 0.90` on a
held-out slice: queries added after the embedding work started, never used
for tuning. If 1-3 do not hold within two months of daily use, embeddings
stay out and the todo is closed.

## Error handling

- Not a git repo: exit 3, message, nothing written.
- Unreadable or non-UTF-8 file: skipped with a stderr warning unless
  `--quiet`; removed from the index if previously indexed; never aborts.
- Index file corrupt: detected narrowly, by `PRAGMA quick_check` not
  returning `ok` on open, or by `sqlite3.DatabaseError` whose message
  starts with `file is not a database` or `database disk image is
  malformed`. Only then: rename to `index.db.corrupt` (replacing any older
  one), full rebuild, stderr warning. Lock errors (`database is locked`),
  FTS parse errors (`fts5: syntax error`), permission and I/O errors are
  never treated as corruption and map to exits 7, 4, and 6 respectively.
  Automatic rebuild happens only for the current tree's index.
- Concurrent writers: SQLite locking with a 5 s busy timeout; behaviour per
  command as specified above (search degrades to the prior index, index
  exits 7).
- Config dir not writable, or index path inside the repo: exit 6 with the
  path.

## Testing

Test-first per the superpowers TDD workflow: each numbered case below is
written as a failing test before the code that makes it pass.
`recall_test.sh` builds throwaway git repos in `mktemp -d` and sets `HOME`,
`CLAUDE_CONFIG_DIR`, `CLAUDE_WORK_TREE`, `CLAUDE_WORK_CONFIG_DIR` to temp
paths so nothing touches the real config dirs. Cases:

1. Repo with no sources: `search` exits 2 with the conventional-locations
   message; `status` exits 0; outside a git tree exits 3.
2. Index + search hit: heading match outranks body match; `path:line`
   anchor equals the heading's line; preamble anchor is line 1; empty
   chunks dropped; headingless file is one chunk.
3. Kinds: `docs`, `todos`, `handoffs`, `memory` (both slugs), `findings`,
   `extra`; precedence (`docs/findings/x.md` is `findings`); `--kind`
   filter; extra glob with `..` rejected.
4. Incremental refresh: modify, delete, add, make oversized, change kind;
   `search` reflects each without `--full`; `--no-refresh` does not.
5. Account routing: tree under `$CLAUDE_WORK_TREE` with the work config dir
   absent creates it and writes there; `CLAUDE_CONFIG_DIR` overrides; a
   personal tree never creates the work dir; sentinel memory files never
   cross accounts; `CLAUDE_CONFIG_DIR` inside the repo exits 6.
6. Repo id: two top levels whose slugs collide get distinct index dirs.
7. Worktree: a linked worktree gets its own index and sees the main
   checkout's memory slug.
8. Output contract: `--json` stdout is pure JSONL even when the refresh
   changed files; `--raw` parse error exits 4; default mode survives `"`,
   `*`, `(`; ties order deterministically; `--limit 0` exits 64.
9. `eval`: one hit and one miss gives `recall@5 0.50`, miss grouped under
   its note; malformed line exits 8; `eval add` refuses a duplicate `q`.
10. Corrupt index is quarantined and rebuilt; schema version mismatch
    rebuilds.
11. `RECALL_FORCE_NO_FTS5=1` (test-only env) exercises exit 5.
12. Locked index: with a prior index `search` still answers and warns;
    `index` exits 7.

The suite is registered in `bin/dotfiles-tests`. Baseline before the change
is recorded in the plan; the change adds exactly one suite and every suite
passes.

## Acceptance criteria

- The fixture suite above passes locally via `dotfiles-tests`.
- Manual smoke in this dotfiles worktree: with no index present,
  `recall.py search budget capped cheap model tier` lists the todo
  `.todos/pending/2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical.md`
  in its top 3 and the whole command, including the cold index build,
  finishes in under 1 s wall clock on this machine.
- `recall.py status` in a repo with no docs/todos/memory reports zero
  sources and exits 0; `search` there exits 2 with a one-line explanation.
- A before/after `git status --porcelain` snapshot of a fixture repo is
  identical after `index`, `search`, and `status`.
- A fixture tree under `$CLAUDE_WORK_TREE` produces an index under the work
  config dir and nothing under the personal one, and vice versa.
- `SKILL.md` frontmatter follows the existing personal skills (name,
  description with trigger phrases); the skill is whitelisted in
  `claude/skills/.gitignore`; `ruff check` passes on `recall.py`.

## Decisions recorded

- Hook vs on-demand: on-demand with refresh-on-search. No hook in v1.
- Index in repo vs config dir: config dir. Satisfies "never committed" and
  "work indexes under work account" structurally, not by convention.
- Per-worktree vs per-repo index: per working tree; memory pulls from both
  the worktree slug and the canonical root slug.
- Findings location: reserved `docs/findings/` and `.claude/findings/`;
  nothing produces them yet.
- Change detection: mtime+size gate, sha256 confirm; same-mtime same-size
  edits need `--full` (documented limit, not worth a content scan per query).

## Codex spec review, round 2 (2026-09-01)

Seven high findings, no critical. All folded in: account boundary
restated as index-plus-memory under one config dir with the override
moving it; `missing-source` eval entries allowed; corruption detected
narrowly (quick_check / specific messages) and never triggered by lock,
parse, or permission errors; `status --all` routes without git and never
rebuilds; `eval` uses one snapshot and prints `RECALL_VERSION`; privacy
redaction exception for the golden set. Verdict stayed needs-rework on
the round-2 text; per the codex-spec-review skill the loop stops at two
rounds and proceeds on judgment. Status: ready-to-plan.

## Codex spec review, round 1 (2026-09-01)

Verdict was needs-rework with 25 findings. Folded in: routing contract
aligned with the wrapper (work dir created if absent, `CLAUDE_WORK_CONFIG_DIR`
honoured), index-inside-repo rejection, hashed repo id, kind precedence and
dedup, extra-glob containment, isolation guarantees and sentinel tests,
sha256 change detection and ineligibility removal, transactional refresh
and lock semantics, chunk edge cases, display paths for external files,
distinct exit codes, JSONL stdout purity, prospective golden set with
verbatim queries and held-out slice, eval schema validation, opt-in `eval
add`, fixture-based acceptance, TDD/ruff requirements, `meta` table with
schema version, command validation, Claude-only scope, platform floor,
non-brittle suite count, todo supersession note.

Declined: 80% coverage target and `uv` project (the repo's Python rules do
not require them for a stdlib script; the fixture suite covers every
command path); automatic stale-index purge (`status --all` plus manual
`rm` is enough for two repos).
