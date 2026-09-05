---
name: co-review
description: Use when reviewing a local code change or pull request with both Codex and Claude before fixing findings.
---

# Co-Review

Run an internal Codex review in the current session plus an external Claude
review over one frozen change, verify their findings, then resolve fixes
within the user's authorized scope.

## Shared policy and runtime adapters

Read the canonical repo-owned policy at
`../../../claude/skills/co-review/SKILL.md`, relative to this skill's
resolved directory (follow the skill symlink first). Apply its gate
classification, threat-model attacker (step 2.5), finding merge (step 3),
skeptic verification (step 3.5), lessons (step 4), and bounded rereview
(step 5). These policies are shared; do not maintain a separate copy here.

Use the Codex adaptations below for target snapshots and reviewer calls.
Never execute the canonical skill's external `codex exec` recipe from this
session. Translate its `Agent`, `Read`, and `Grep` operations to the current
runtime's equivalent tools. If an independent verifier is unavailable,
report that stage incomplete; do not claim its verdict was obtained.

## Target and frozen snapshot

- A supplied PR number/URL selects that PR. Resolve and verify its exact
  head SHA and base repository/branch, then pin their merge-base SHA.
  A failed fetch or checkout is an error, never an empty or clean review.
- Otherwise include staged and unstaged changes plus intended untracked
  source files. Enumerate and inspect untracked paths before including
  them; report exclusions such as private state, generated output, or
  symlinks instead of silently staging everything.
- With no working changes, fall back to the committed branch diff against
  its fork point. Resolve the actual base branch from repo/task evidence;
  do not assume an upstream tracking branch is the fork point.
- State the target, pinned base/head, and any exclusions before reviewing.
  Stop only when that selected diff is verified empty. Treat a diff-command
  failure separately from an empty diff.

Before creating snapshots, capture an absolute `REVIEW_CLAUDE_CONFIG` for
the original target repository. `CLAUDE_PERSONAL_ONLY=1`, a checkout under
`~/Git/personal`, or canonical personal ownership selects `~/.claude`, even when a
parent work session exported `CLAUDE_CONFIG_DIR`. Otherwise preserve an
explicit `CLAUDE_CONFIG_DIR`, resolving relative paths against the original
invocation directory. With no override, classify the original repository's
resolved Git common directory under `${CLAUDE_WORK_TREE:-$HOME/Git/work}`:
work uses `${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}`, others use `~/.claude`.
Resolve both directory conventions before comparing path boundaries. A linked
worktree follows its owning repository. Never infer the account from `WT` or
`CLAUDE_WT`: their temporary locations could change the selected account.
An explicit personal-account override for a work repository is valid and
must survive reviewer dispatch. Abort the external pass if the intended
account cannot be determined.

Follow the canonical step 0 snapshot procedure to produce `SNAP_BASE`,
`SNAP_HEAD`, and a detached read-only worktree `WT` at `SNAP_HEAD`. For
uncommitted work, use its temporary-index/commit-tree procedure, adding
only the explicitly inspected untracked source paths to that temporary
index as well. Check every command and verify the snapshot matches the
selected file set. Never change the user's branch, index, or files to
prepare a review. If the source changes during capture, recapture before
starting reviewers.

Claude's installed native local `/code-review` can inspect only changes
against HEAD. Materialize the same pinned change as an uncommitted diff
in a second unique detached worktree, `CLAUDE_WT`, at `SNAP_BASE`:

```bash
# WT already contains the frozen reviewed head; PATCH is a unique temp file.
git -C "$WT" diff --binary --full-index --no-ext-diff --no-textconv \
  "$SNAP_BASE" "$SNAP_HEAD" > "$PATCH"
git worktree add --detach "$CLAUDE_WT" "$SNAP_BASE"
git -C "$CLAUDE_WT" apply --index "$PATCH"
# Require equality before invoking either reviewer.
git -C "$CLAUDE_WT" write-tree
git -C "$WT" rev-parse "$SNAP_HEAD^{tree}"
```

Run these sequentially and abort on any failure or tree mismatch. The
extra worktree lets native `/code-review` see committed branches and PRs
without relying on a moving remote PR or its publication workflow.

## Codex Review

Review `SNAP_BASE..SNAP_HEAD` yourself in the current Codex session, reading
full files from `WT`. Use the normal code review stance: findings first,
ordered by severity, focused on bugs, regressions, security risks, data
loss, broken tests, and missing tests.

Do not launch `codex review` from inside Codex. Do not launch `codex exec`
as a second reviewer either. The in-session review is the Codex half.

## Claude Review

Run only Claude's native local code review in the prepared `CLAUDE_WT`:

```bash
(
  cd "$CLAUDE_WT" || exit 1
  : "${REVIEW_CLAUDE_CONFIG:?capture the target account first}"
  if [ "$REVIEW_CLAUDE_CONFIG" = "$HOME/.claude" ]; then
    env -u CLAUDE_CONFIG_DIR claude -p "/code-review" </dev/null
  else
    env CLAUDE_CONFIG_DIR="$REVIEW_CLAUDE_CONFIG" claude -p "/code-review" </dev/null
  fi
)
```

Unset the variable for the default personal login: an explicit `~/.claude`
can select a separate credential namespace. Never pass an empty value.

**ALWAYS call the native `/code-review`. NEVER hand Claude a generic review
prompt or ask it to run its `co-review` skill.** Do not append a PR argument:
this review already contains the pinned PR diff, and the native PR mode
may publish a review. Reviewers and verifier subagents must not call
co-review or launch the partner again.

If Claude or `/code-review` is unavailable, report the failure and continue
with the internal Codex review unless the user requires both reviewers.
There is no generic-prompt fallback. Missing, empty, or failed external
output is not a clean verdict. After Claude finishes, verify its worktree
still matches the prepared diff; discard its verdict if the input changed.

## Verification and resolution

Apply the shared policy stages against the same `WT` snapshot:

- Detect gate-like changes before dispatch. For them, an independent
  attacker tests the stated invariant with concrete bypass attempts;
  absent an identifiable invariant, report the stage inconclusive.
- Verify and dedupe findings by `file:line + issue`, retaining source tags
  `[both]`, `[codex]`, `[claude]`, and `[threat-model]` or composites.
- Run fresh skeptic verification, including the shared bounded majority
  escalation for a refuted high-risk finding. Errors remain NOT-REFUTED.
  Keep refuted findings visible in their own lower-confidence tier.
- Carry `LESSON: <candidate rule> [hookable]` lines in every report shape,
  including clean results and rereviews. Post-merge owns admission and
  writes to the shared standing lessons; a review only proposes them.
- Apply confirmed fixes already authorized by the user, and run relevant
  verification. Track fixed and unresolved findings individually.
- For nontrivial fixes, run one rereview against only the fix diff using
  fresh snapshots and the same stages. Carry forward unresolved findings
  and lessons; recheck earlier refutations whose evidence changed. Stop
  after two passes total. Trivial fixes need only appropriate checks.

Do not post PR comments, push, or publish unless explicitly authorized.
Report any incomplete stages and state explicitly when no findings remain.

## Cleanup on every exit

Keep both worktrees until all reviewers and verifiers have stopped. Then
remove only this run's exact worktrees, temporary index, path list, patch,
and logs on success, empty diff, error, or cancellation. Follow canonical
step 3.6's unconditional finalization; verify the temporary worktrees are
absent from `git worktree list`. Never use a broad wildcard to remove a
concurrent review's files.
