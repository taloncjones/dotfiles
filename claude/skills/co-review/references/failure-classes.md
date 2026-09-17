# Co-Review Checklist

Read the three questions in `SKILL.md` first; they decide what blocks. This
file directs the reader's attention. It is not a quota.

Check an entry only when the frozen diff touches its surface. A diff of pure
in-process logic gets no symlink probe; a prose-only diff gets no TOCTOU probe.
Finding nothing under an entry is the normal outcome, and reporting nothing at
all is a clean review.

## Classes

### Always, on any diff

- Does each changed function still do what its name, its docstring and its
  callers assume?
- Does every call site of every changed symbol still hold? Include other
  consumers of a shared thing the diff touches. Search the repository for them;
  do not reason about which callers probably exist. If a consumer or contract
  is not in the frozen tree, say it is not determinable rather than assuming a
  test fake speaks for the real thing.
- Do the docs, skill prose and tests describing this behaviour still match the
  behaviour?
- Does every error path return failure? A guard returning success on error, an
  allowlist consulted after the action it gates, `|| true` swallowing a verdict.

### If the diff runs shell

- Unquoted expansions that word-split; NUL vs newline separation; `xargs`
  without `-0`; filenames with spaces, newlines or globs.
- `rm -rf` of a variable that can be empty or redirected; traps firing outside
  the intended root; mktemp race or reuse.

### If the diff touches paths it did not create

- Reads or writes through a symlink, or through a symlinked parent of an
  inspected path.
- Operations that clobber gitignored or untracked files the user owns.

### If the diff touches git plumbing

- A base ref moving between resolution and use; a stale local ref standing in
  for remote state.
- `clean`/`smudge` filters or `core.autocrlf` altering bytes between worktree
  and object store.

### If the diff decides authority or currency

- Authority resting on something replayable or reconstructible rather than a
  durable record; a counter or fence that can move backward.
- A resume or retry path that skips revalidation the first-run path performs.
- State checked before use, with a window between the check and the use.

### If the diff crosses a trust boundary

Only when `SKILL.md`'s threat model says it does: untrusted network input,
credentials, another account's data, or a repository we do not control. Our own
tooling run by us on our own machines does not qualify.

- Input reaching a parser, a filesystem path or a command without validation.
- A writer publishing a payload its own bounded reader would refuse.

## Growing this file

Add an entry only for a defect that reached a merge and that no entry above
would have prompted. File it under the gate that makes it relevant, never in
the always-check list. Delete entries that stop earning their keep.

This file is meant to stay short. A checklist too long to hold in your head
produces noise instead of findings.
