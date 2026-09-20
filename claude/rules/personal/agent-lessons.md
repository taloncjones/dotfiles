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
- (2026-09) Open the PR before co-review so its rounds land there, and merge
  on it, never locally -- protected main refuses, as does a draft (`isDraft`).
- (2026-09) Never expand or abbreviate a sha by hand: emit what rev-parse or
  ls-remote returns -- flags like --match-head-commit reject a short sha.
- (2026-09) A worker never commits with failing tests: fix or report
  BLOCKED/DONE_WITH_CONCERNS uncommitted; green-before-commit is the contract.
- (2026-09) A content-flagged adversarial run with no output is incomplete, not
  clean: retry once with defensive review framing before counting the seat.
- (2026-09) Never change or fix one instance in isolation: name the failure
  class or consumer set, grep every sibling site, and run their suites too.
- (2026-09) A reviewer never mutates the tree under review: baseline from
  `git archive` into a temp dir; a live checkout ate uncommitted work.
- (2026-09) A completion-enforcing hook is not user consent: hold the gated
  action, say you are blocked once, and wait instead of restating.
- (2026-09) Never write an unverified reference: grep-verify code anchors, and
  check external CLI flags against their help, before a plan or skill cites it.
- (2026-09) Read every static-scan hit in full before calling it a false
  positive: judging one by a truncated line shipped a rule that broke a test.
- (2026-09) Run suites to a file, then grep it: pipes hide failures and stderr.
- (2026-09) Settle a factual review dispute by executing the case, not by rank.
