# Agent Lessons

Distilled from recurring agent failures at merge time (/post-merge lessons
step). Contract: max 20 rule bullets; file stays at or under 45 physical
lines. At cap, adding a rule means dropping or merging one in the same
edit. Entry format: "- (YYYY-MM) <imperative rule>", one bullet, wrapped
at 80 columns, two physical lines max. Admission filter (all must hold):
agent-process failure, not a code bug; recurring or clearly repeatable;
not already covered by CLAUDE.md, operating-principles.md, or a hook;
public-safe (no employer, internal-system, or customer specifics --
generalize or reject). Candidates passing the filter are then routed:
hookable ones become dotfiles hook todos, not rules; the rest land here.
Staleness: entries dated 6+ calendar months before the current month are
prune candidates at the next edit -- prune, keep-and-redate, or file a
graduation todo to move the rule into operating-principles.md. This file
is the staging tier, not an archive.

## Rules

- (2026-09) Headless workers and reviewers: preserve the intended account
  explicitly before entering temporary worktrees; verify launch readiness.
- (2026-09) Shell variables: zsh does not word-split unquoted expansions and
  uses `pipestatus`; rm/git-meta guards reject them -- pass literal paths.
- (2026-09) An orchestrator session dispatches; it edits repo files only for
  a small change the human approved this turn. Larger: todo + kickoff.
- (2026-09) Before `gh pr merge`, check `isDraft`: a draft PR reports
  MERGEABLE/CLEAN yet the merge call is refused as "still a draft".
- (2026-09) Never expand or abbreviate a sha by hand: emit what rev-parse or
  ls-remote returns -- flags like --match-head-commit reject a short sha.
- (2026-09) A worker never commits with failing tests: fix or report
  BLOCKED/DONE_WITH_CONCERNS uncommitted; green-before-commit is the contract.
- (2026-09) A content-flagged adversarial run with no output is incomplete, not
  clean: retry once with defensive review framing before counting the seat.
- (2026-09) Changing a shared thing: find every consumer first -- callers,
  cited concepts, parallel installed copies -- then run their suites too.
- (2026-09) A protected main makes a local merge unshippable: open the PR
  first, so co-review round comments and markers land on it, then merge there.
- (2026-09) A completion-enforcing hook is not user consent: hold the gated
  action, say you are blocked once, and wait instead of restating.
- (2026-09) Never cite code anchors from memory in a plan: grep-verify that
  every referenced test case or symbol exists before a worker is sent to it.
- (2026-09) Verify external CLI syntax against its help/docs before writing it
  into a skill: unverified gh fields and flag combinations shipped broken.
- (2026-09) Grep a suite's stderr: a passing suite can hide command-not-found.
- (2026-09) Settle a factual review dispute by executing the case, not by rank.
