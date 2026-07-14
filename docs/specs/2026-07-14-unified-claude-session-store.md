# Unified Claude Code session store across config roots

Status: reviewed (codex-spec-review 2026-07-14; decisions D1-D4 settled by user)
Date: 2026-07-14

## Requirements (from the user, 2026-07-14)

- R1. Decide the canonical transcript location; push back if risky.
- R2. One-time merge of both `projects/` trees first; `memory/` dirs must
  survive and remain reachable at the same paths.
- R3. Dedupe the two known duplicated sessions; newer/larger copy wins.
- R4. Scope: link only transcript history; evaluate `history.jsonl` and
  `file-history/` with trade-offs before touching (resolved: D2, D3).
- R5. Durable: idempotent link step in the dotfiles installer.
- R6. Verify both roots list the same sessions in `/resume`; memory still
  loads; back up both trees before the merge.

Deliberate boundary decision: both roots belong to the same operator on the
same machine; after unification, work transcripts are readable from
personal-account sessions and vice versa. This is intended (R1-R6) and
matches the existing shared `agents`/`skills`/`hooks` surface.

## Problem

Two Claude Code config roots exist on this machine: `~/.claude` (default;
VS Code-launched and personal sessions) and `~/.claude-work` (work shells
export `CLAUDE_CONFIG_DIR=~/.claude-work` via the `claude()` zsh wrapper).
Session transcripts live at `<root>/projects/<encoded-cwd>/<session-id>.jsonl`
plus a sidecar directory per session with the same id. `/resume` only lists
sessions under the ACTIVE root, so history is fragmented. Incident
(2026-07-14): a session in
`~/.claude/projects/-Users-talon-jones-Git-work-rw-bess/` was invisible from
a `~/.claude-work` session and had to be found and copied by hand, creating
duplicates that are now diverging.

## Measured state (2026-07-14)

- `~/.claude/projects`: 941M, 19 encoded-cwd dirs.
- `~/.claude-work/projects`: 1.3G, 33 encoded-cwd dirs.
- Overlapping encoded-cwd dirs: 3
  (`-Users-talon-jones-Git-personal-dotfiles` — no common entries;
  `-Users-talon-jones-Git-work` — common entry `memory/`;
  `-Users-talon-jones-Git-work-rw-bess` — common entries `memory/` plus the
  two duplicated sessions).
- Duplicated sessions (manually copied 2026-07-14, personal -> work):
  - `41dfd579-c295-47be-a9c8-daf8b332273c`: work copy larger and newer
    (4,640,893 bytes, 09:58) vs personal (4,386,254 bytes, 09:38). Work copy
    was resumed after the copy; work wins.
  - `aaec0865-b3f1-4fa2-87d9-208a2498de6e`: byte-identical (3,895,044) in
    both roots; keep the personal copy, drop the work copy.
- `memory/` dirs (persistent auto-memory; MUST survive and remain reachable
  at the same paths):
  - Personal root: `-Git-work-rw-bess` (11 files), `-Git-personal-dotfiles`
    (9 files), `-Git-work` (2 files).
  - Work root: `-Git-work-rw-bess` (42 files), `-Git-work` (3 files),
    `-Git-work-rw-test-infrastructure` (4), `-Git-work-rw-test-stand` (3),
    `-Git-work-hil-infra-project` (3).
  - Conflicting dirs needing file-level union: `-Git-work` and
    `-Git-work-rw-bess`.
- `file-history/`: session-uuid-keyed directories. 34 ids personal, 48 work,
  overlap exactly one: `41dfd579-...` (follows the duplicated session).
  Backs `/rewind` checkpoints.
- `history.jsonl`: append-only prompt history, one JSON line per prompt with
  `project` and `sessionId` fields. 2.7M personal, 274K work.
- `sessions/` (top level): PID-keyed runtime state; ephemeral, per-root.
- `tasks/`: session-uuid-keyed background-task state, per-root.

## Decisions

### D1. Canonical location: `~/.claude/projects`; work side becomes a symlink

`~/.claude-work/projects -> ~/.claude/projects` (absolute symlink), matching
how `agents`, `commands`, `hooks`, `skills`, `rules` are already served to
both roots.

Risk review (why this is safe):

- Writers never collide: transcripts, sidecars, and file-history entries are
  keyed by session UUID; two live sessions (one per root) write different
  files inside the shared tree. Directory symlink means renames/creates land
  in the shared store (unlike a file symlink, which a rename-replace would
  sever).
- The daemon and its state (`daemon.lock`, `daemon.status.json`, `jobs`,
  `sessions/`) stay per-root and are out of scope.
- Fresh machine: `~/.claude/projects` is created by the CLI on demand; the
  installer step only needs to guarantee the work-side symlink.
- Cloud containers have no `~/.claude-work`; no cloud change.
- Retention: `cleanupPeriodDays` from either root now prunes the shared
  store, so a shorter setting in one root would silently prune the other
  root's history. The migration preflight warns when the two roots'
  `settings.json` values differ, and notes when both are unset (platform
  default applies). Pinning an explicit value in `settings.json.tmpl` is a
  separate retention-policy decision, deferred to the user.

### D2. Also unify `file-history/` (settled 2026-07-14)

`~/.claude-work/file-history -> ~/.claude/file-history`. Rationale: it is
session-uuid-keyed, so the merge is a disjoint union (single overlap follows
the winning transcript for `41dfd579`), and without it `/rewind` breaks for
any session resumed under the other root — the exact cross-root resume this
project enables. Same directory-symlink mechanics and risk profile as D1.

### D3. Do NOT unify `history.jsonl` (settled 2026-07-14)

Prompt-history fragmentation is cosmetic; `/resume` pain is solved by D1.
Unifying requires a FILE symlink, and if the CLI ever rewrites the file via
write-temp-then-rename (compaction), the rename silently replaces the
symlink and re-forks the store with no error. Low benefit, silent failure
mode. Revisit only if fragmented prompt history becomes a real annoyance.

### D4. Everything else stays per-root

`settings.json`, `plugins/`, daemon state, caches, `sessions/`, `tasks/`,
`shell-snapshots/`, `session-env/`. Known, accepted degradation: a session
resumed under the other root loses access to that root's `tasks/` state for
its background tasks. `tasks/` is session-keyed like file-history and can be
unified later if this ever bites.

## Components

### C1. `bin/claude-unify-projects` (new, tracked, linked to `~/bin` like `identity-setup`)

One script, two modes, idempotent in both:

- **Link mode (default, safe, no data movement).** For each of
  `projects`, `file-history`:
  - work-side path is already the correct symlink -> no-op;
  - absent or empty dir -> replace with symlink to the personal-side path
    (creating the personal-side dir if needed);
  - non-empty real dir -> print `[WARNING] run claude-unify-projects --merge`
    and exit non-zero for that entry. Never moves data in this mode.
- **Merge mode (`--merge`, one-time migration).** The merge is
  COPY-then-swap: the work-side trees are never mutated until the final
  atomic rename, so an interruption at any earlier stage leaves both roots
  fully working and the script safe to re-run from scratch.
  1. Preflight (fail closed):
     - `lsof +D` over all four trees (`projects/` and `file-history/` in
       both roots) must be empty; if `lsof` is unavailable or errors, stop.
     - Print the close-all-Claude-sessions reminder; require interactive
       confirm (or `--yes`).
     - Warn if `cleanupPeriodDays` differs between the two roots'
       `settings.json` (see D1).
     - Free-space check: destination filesystem must have headroom for a
       full copy of the work trees plus the backup tar.
  2. Backup: tar both `projects/` trees and both `file-history/` trees into
     `~/tmp/claude-projects-backup-<timestamp>.tar.gz` with root-distinct
     archive paths (`claude/...`, `claude-work/...`), mode 0600. Validate
     with `tar -tzf` (list must succeed and entry count match the source
     inventory). Write the pre-merge inventory (path, size, mtime per file)
     next to the tar. Abort before any mutation if validation fails.
  3. Compute collisions from the RUNTIME inventory, not from this spec's
     snapshot. The two ids named in Measured state are expectation checks:
     if the runtime scan finds duplicate ids beyond `41dfd579-...` and
     `aaec0865-...`, list them and apply the same rule; if it does not find
     those two, warn (state changed since the spec) and require re-confirm.
  4. Merge work -> personal by COPY (`cp -a` semantics, no source deletion):
     - encoded-cwd dir only in work: copy whole dir.
     - overlapping dir: copy entries one by one; never overwrite an existing
       personal-side file except via an explicit collision rule below.
       - `<session-id>.jsonl` collision (R3): larger byte size wins; equal
         size with identical bytes -> keep personal; equal size, different
         bytes -> newer mtime. The winner's side also supplies
         the sidecar dir and the `file-history/<id>` entry. The losing copy
         is simply not copied (work loser) or overwritten by the work winner
         (personal loser); every loser survives in the backup tar and in the
         untouched work tree until the swap.
       - `memory/` collision (R2): file-level union. Same filename,
         identical bytes -> keep one. Same filename, different bytes ->
         newer mtime wins in place; the losing version is preserved
         alongside as `<name>.conflict-<root>.md` and listed in the final
         report. `MEMORY.md`: keep the personal file's content and order,
         then append work-only lines — a work line is "new" if its exact
         trimmed text does not appear in the personal file; the original
         work `MEMORY.md` is also preserved as `MEMORY.md.conflict-work.md`.
       - any other name collision: keep both (work copy renamed with a
         `.from-work` suffix) and report; UUID keying makes this unexpected.
     - `file-history/`: copy all work-side session dirs not already present
       (disjoint union); for ids present in both, the transcript winner's
       side supplies the whole dir; work-only orphan entries (no matching
       transcript) are copied as-is; an id present in BOTH roots without a
       transcript collision (unexpected) keeps the personal copy and
       preserves the work copy alongside as `<id>.from-work`.
  5. Swap (the only mutation of the work root, one rename per tree):
     `mv ~/.claude-work/projects ~/.claude-work/projects.premerge-<ts>`,
     then `ln -s ~/.claude/projects ~/.claude-work/projects`. Same for
     `file-history`. If a `.premerge-*` from an earlier run exists, stop and
     ask rather than guessing.
  6. Verify (script-enforced, from the recorded inventory):
     - `readlink` of both work-side paths resolves to the personal-side dirs;
     - every pre-merge file (both roots) is reachable post-merge via both
       root paths at its original relative path, except (a) dedupe losers,
       which are enumerated with their winning counterpart, and (b)
       `.conflict-*`/`.from-work` renames, which are enumerated;
     - every duplicate id found in step 3 now exists exactly once;
     - every pre-merge `memory/` file is readable through BOTH root paths.
       On success, print that `projects.premerge-<ts>` and
       `file-history.premerge-<ts>` can be deleted after a manual `/resume`
       and `/rewind` spot check; do not auto-delete.

### C2. Installer integration (R5)

`install/common/link.sh` calls `bin/claude-unify-projects` in link mode
right after its two `link_claude_config_dir` calls (both roots must exist
first) on every install/update run. Fresh machine: work side has no `projects/` yet, so link
mode creates the symlinks outright — no merge ever needed. Existing machine
with unmerged content: the installer prints the warning and CONTINUES (the
link step never fails the install; it reports at the end like other link
warnings). Cloud containers and machines without `~/.claude-work` skip the
step entirely. The script is plain bash, portable across macOS and Linux
(no `stat -f`-style platform-specific flags).

Link-mode edge states (all no-data-loss): a symlink pointing anywhere other
than the personal-side path is replaced only if its target does not exist
(dangling); otherwise warn and skip. A regular file at the path: warn and
skip. Only empty dirs, dangling symlinks, and absent paths are converted.

### C3. Tests and docs

- Extend the links test suite (`bin/dotfiles-tests`) with shape checks:
  `~/.claude-work/projects` and `~/.claude-work/file-history` are symlinks
  resolving into `~/.claude/`, and link mode is a no-op when already linked.
  Merge-rule unit checks (collision winner selection, memory union) run
  against a fixture tree in a temp dir, never against live roots.
- Repo `CLAUDE.md` symlink-targets table gains the two entries.

## Operational constraints

- The merge runs from a plain terminal with NO live Claude sessions on this
  machine — including the session that authored this change. The preflight
  lsof over all four trees enforces this; the operator closes sessions
  first. (Copy-then-swap means a stray reader is recoverable, but the rule
  is full quiescence.)
- Machine-state mutation (the merge) happens only after explicit user
  go-ahead; the repo change and the script land first.

## Acceptance criteria (R6)

1. `claude` (default root) and `CLAUDE_CONFIG_DIR=~/.claude-work claude`
   list the same NON-EMPTY session set in `/resume` for `~/Git/work/rw-bess`,
   including sessions that originated in each root.
2. Auto-memory loads in a work-root session for rw-bess and in a
   personal-root session for the dotfiles repo (spot check: MEMORY.md
   content present in session context, fact files readable at the old
   work-root paths).
3. Backup tar exists, `tar -tzf` succeeds, and its entry list matches the
   recorded pre-merge inventory file for file.
4. `/rewind` in a resumed cross-root session shows checkpoints (D2 works).
5. `bin/dotfiles-tests` green, including the new shape checks.
6. Re-running `bin/claude-unify-projects` (link mode) and the installer is
   a no-op afterwards (verified by identical before/after `find` listings
   of both roots).
