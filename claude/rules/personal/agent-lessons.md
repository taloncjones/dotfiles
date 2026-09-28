# Agent Lessons

Distilled from recurring agent failures at merge time (/post-merge lessons
step). Contract: max 30 rule bullets; file stays at or under 70 physical
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

- (2026-09) Bind headless workers, reviewers and probes to an explicit clean env
  and account: inherited settings outlive the config change they predate.
- (2026-09) Shell variables: zsh does not word-split unquoted expansions and
  uses `pipestatus`; rm/git-meta guards reject them -- pass literal paths.
- (2026-09) Before `gh pr merge`, check `isDraft`: a draft PR reports
  MERGEABLE/CLEAN yet the merge call is refused as "still a draft".
- (2026-09) Never emit an identifier from memory, or one an earlier edit moved:
  shas, symbols, line numbers -- re-read it, or anchor on surrounding text.
- (2026-09) A worker never commits with failing tests: fix or report
  BLOCKED/DONE_WITH_CONCERNS uncommitted; green-before-commit is the contract.
- (2026-09) A content-flagged adversarial run with no output is incomplete, not
  clean: retry once with defensive review framing before counting the seat.
- (2026-09) Never change or fix one instance in isolation: name the failure
  class or consumer set, grep every sibling site, and run their suites too.
- (2026-09) A protected main makes a local merge unshippable: open the PR
  first, so the co-review gate runs against it, then merge there.
- (2026-09) A completion-enforcing hook is not user consent: hold the gated
  action, say you are blocked once, and wait instead of restating.
- (2026-09) Verify external CLI syntax against its help/docs before writing it
  into a skill: unverified gh fields and flag combinations shipped broken.
- (2026-09) Run suites to a file, then grep it: pipes hide failures and stderr.
- (2026-09) Settle a factual review dispute by executing the case, not by rank.
- (2026-09) Bound a reviewer by its diff, not a fixed clock: a live reviewer
  past a static deadline is re-sized or waited on, never interrupted and re-run.
- (2026-09) After a review round, re-dispatch a fresh implement attempt before
  the repair worker emits: a superseded attempt row refuses its emit-done.
- (2026-09) Re-read a PR body against the final head before posting it: wording
  written mid-fix (record-only vs asserted, tip sha vs bench sha) drifts.
- (2026-09) The commit guard rejects the bare word "claude" in a commit message:
  write "substitute seat" or "work config" up front, not after a block.
- (2026-09) A contract pinned before a long-lived branch ships goes stale when
  main moves: after any main merge re-run the whole gate, never one check.
- (2026-09) Re-fetch CI and re-read the head right before finalizing a review
  report; a check still pending at round start can flip mid-round.
- (2026-09) A reviewer of a new runner-local cache or marker dir checks that
  the target's .gitignore covers it instead of calling it "untracked".
