---
name: todos
description: Use when capturing, listing, completing, or reviewing cross-session todos for a repo. Trigger when the user says "track this", "add a todo", "what todos are open", "mark that done", or wants a persistent backlog that survives across sessions (unlike the built-in TodoWrite tool, which is session-only).
---

# Todos

A file-based todo tracker: one markdown file per work item under
`<repo>/.todos/`, surviving across sessions where the built-in TodoWrite tool
does not. Replaces GSD's `.planning/todos/` without the worktree/hook machinery.

All mechanics go through the backing script — never hand-create or hand-move
todo files, because the script also keeps `TODO.md` in sync. Call it by
absolute path: `~/.claude/skills/todos/scripts/todos.sh`.

## Layout

```
<repo>/.todos/
  pending/     YYYY-MM-DD-<slug>.md    open items
  completed/   YYYY-MM-DD-<slug>.md    finished items
  TODO.md                             auto-generated index of pending/
```

Todo file:

```markdown
---
created: 2026-06-02
title: <human-readable title>
area: <optional tag, e.g. eol>
due: <optional YYYY-MM-DD deadline>
surface: <optional YYYY-MM-DD; hide from the brief until this date>
priority: <high|med|low; set at creation>
files:
  - path/to/relevant.py:42
---

## Problem

What's wrong / what needs doing, with enough context for a future session.

## Solution

The intended fix or approach. "TBD" is fine when not yet known.
```

## Priority (assigned at creation)

Every new todo gets a `priority`. When you create one, infer it from the
context you have at that moment - area, whether it references a Jira key, and
urgency language ("HOLD", "blocker", "before review"). If you cannot decide
confidently, ask the user for a level (high | med | low). Pass it via
`--priority`. The brief only reads priority; it never re-infers. Existing
todos without a priority are treated as the lowest rank and shown blank.

`high` items surface in the brief regardless of date - except when deferred
(`surface` in the future), which always hides them until the surface date.

## Visibility (local by default)

`init` (and the first `new`) add `.todos/` to the repo's git exclude
(`info/exclude`, resolved via `git rev-parse --git-path` so it works inside
worktrees). Todos stay **local-only** — they never reach the remote. This is
the right default for work repos.

For a personal repo where you want the backlog committed and shared, run
`todos.sh share` once: it removes the exclude line so `.todos/` commits
normally on the next `git add`.

## Commands

| Command                                                     | What it does                                                  |
| ----------------------------------------------------------- | ------------------------------------------------------------- |
| `todos.sh init`                                             | Create `.todos/{pending,completed}/`, set local-only exclude  |
| `todos.sh new "<title>" [--area A] [--file P]...`           | Create a pending todo; prints the file path                   |
| `todos.sh new "<t>" [--due D] [--surface D] [--priority L]` | Time/priority fields on a new todo                            |
| `todos.sh register`                                         | Register the current repo for the cross-repo brief            |
| `todos.sh repos`                                            | List registered repos (warns on missing paths)                |
| `todos.sh brief [--soon N] [--stale M] [--stale-cap K]`     | Print time-relevant todos across all registered repos         |
| `todos.sh list [--all]`                                     | List pending todos (`--all` also lists completed)             |
| `todos.sh done <slug-or-substring>`                         | Move a todo `pending/ -> completed/`                          |
| `todos.sh index`                                            | Regenerate `TODO.md`                                          |
| `todos.sh share`                                            | Stop ignoring `.todos/` in this repo (opt into committing it) |
| `todos.sh path`                                             | Print the `.todos/` directory path                            |

`new` and `done` regenerate `TODO.md` automatically, so the index never drifts.

## Time model & the brief

- `due` - deadline. Drives Overdue (`due < today`), Today (`due == today`), and
  Due soon (`today < due <= today + N`, N default 3).
- `surface` - defer date. The todo is hidden from the brief until then; on the
  day it equals today it appears under Today. Defer wins over priority.
- Undated todos surface via age: once `created` is older than M days (default 14) they appear under Stale (oldest-first, capped, with a "+K more" note).
- `todos.sh brief` reads the registry (`~/.claude/todos/repos.txt`) and scans
  every registered repo. Register each repo you want included with
  `todos.sh register`.

## Workflow

**Capturing a todo.** Run `todos.sh new "<title>"` (add `--area` and `--file`
when known). The script prints the new file path with empty `## Problem` /
`## Solution` sections — then edit that file to fill in the prose. Write enough
context that a future session with no memory of this one can act on it.

**Reviewing.** `todos.sh list` for open items, `--all` to include completed.
Read `TODO.md` for the glance-able summary view.

**Completing.** When an item is finished, `todos.sh done <substring>` using a
distinctive part of the filename slug. If the substring is ambiguous the script
lists the matches so you can disambiguate.

## Common Mistakes

| Mistake                                    | Why it breaks                                                   | Do instead                                                   |
| ------------------------------------------ | --------------------------------------------------------------- | ------------------------------------------------------------ |
| Editing `TODO.md` by hand                  | Clobbered on the next `new`/`done` (it's regenerated)           | Edit the underlying `pending/*.md`, then `todos.sh index`    |
| Hand-creating or `mv`-ing todo files       | `TODO.md` drifts out of sync                                    | Use `todos.sh new` / `todos.sh done` — they re-index         |
| Running commands outside the repo          | `git rev-parse --show-toplevel` fails or targets the wrong repo | `cd` into the target repo first                              |
| Leaving Problem/Solution blank after `new` | A future session has no context to act on                       | Fill in the prose immediately; `new` only stubs the sections |

## Notes

- Todos are **per-repo** and live at the repo root. Run commands from inside
  the target repo (the script uses `git rev-parse --show-toplevel`).
- There is no separate "in progress" state — a todo is either in `pending/` or
  `completed/`. Track active-work nuance in the body if needed.
- Migrating from GSD: copy files from `.planning/todos/{pending,completed}/`
  into `.todos/{pending,completed}/`; the frontmatter is compatible. Then run
  `todos.sh index`.
