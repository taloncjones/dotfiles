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
- (2026-10) zsh: unquoted vars do not word-split, `$v:h` is a modifier (write
  `${v}:h`), use `pipestatus`; rm/git guards reject vars -- pass literal paths.
- (2026-10) Never emit an identifier from memory, or one an earlier edit moved:
  shas, paths, symbols, line numbers -- re-read it or anchor on nearby text.
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
- (2026-10) Run suites one at a time, to a file, then grep it; size the wait
  from `timeout_secs`. Concurrent suites flake; pipes hide failures and stderr.
- (2026-09) Settle a factual review dispute by executing the case, not by rank.
- (2026-09) Bound a reviewer by its diff, not a fixed clock: a live reviewer
  past a static deadline is re-sized or waited on, never interrupted and re-run.
- (2026-09) After a review round, re-dispatch a fresh implement attempt before
  the repair worker emits: a superseded attempt row refuses its emit-done.
- (2026-09) Re-read a PR body against the final head before posting it: wording
  written mid-fix (record-only vs asserted, tip sha vs bench sha) drifts.
- (2026-09) A contract pinned before a long-lived branch ships goes stale when
  main moves: after any main merge re-run the whole gate, never one check.
- (2026-10) Each review round re-runs CI, lint and format, re-reads the head and
  re-derives any carried finding's scope; prior results are not evidence.
- (2026-09) A reviewer of a new runner-local cache or marker dir checks that
  the target's .gitignore covers it instead of calling it "untracked".
- (2026-09) Never brief a Claude substitute on a recorded Codex quota premise:
  run one live Codex probe first; a stale exhaustion note cost two real seats.
- (2026-09) Run a test you expect to fail with retries off (`--reruns 0` or the
  equivalent): a rerun plugin in ini addopts turns a red mutation check green.
- (2026-10) Poll `gh run view` when `gh run watch` dies on a transient API
  error; a dead watch is not a failed run.
- (2026-10) Launch each review seat as its own detached job and poll its result
  file; one shared background wrapper loses every seat at its tool limit.
- (2026-10) Build a scratch or mutation copy from the whole tree (`git archive`
  or a detached worktree); a partial `cp` misses the files a test imports.
- (2026-10) Re-grep anchors after a Markdown Write/Edit: the formatter reflows.
- (2026-10) Never pass `-c commit.gpgsign=false`; a locked signer means pause.
- (2026-10) A suite outside the brief that fails in a worker pane: rerun it on
  the base tree first, and blame the change only if the base passes.
- (2026-10) A fast-path contract runs the owning suite of every edited module
  and greps tests for the changed literal; a one-file scope hides pinned tests.
- (2026-10) An auto-mode worker cannot edit rules or principles files (the
  self-modification classifier refuses); route those edits to a manual session.
