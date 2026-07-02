---
name: dotfiles-research-methodology
description: Use when turning a hunch, idea, or half-diagnosed problem in this dotfiles repo into an accepted change -- when you are about to say "I think the cause is X", propose a new subsystem, or decide whether an experiment "worked". Trigger phrases -- "I have a theory", "should we build/add/try X", "is this fix real", "the test passed so we're done", "let's just remove it". Covers the evidence bar (one mechanism explains ALL observations), predict-before-run, the idea lifecycle (adopted AND retired both count as success), and where good ideas historically came from. NOT for executing an already-approved change (dotfiles-change-control), triaging a live failure (dotfiles-debugging-playbook), looking up a settled past investigation (dotfiles-failure-archaeology), or picking a new open problem to work on (dotfiles-research-frontier).
---

# Dotfiles Research Methodology

The discipline that turns a hunch into an accepted change in this repo. It
exists because the repo's biggest wins (cloud first-session plugins) and its
biggest write-off (tiered-orchestrate, 596 lines deleted) both followed the
same arc: hypothesis, prediction, experiment, adversarial refutation, then
either adoption or a documented retirement. Follow the arc; do not skip to
the fix.

## When NOT to use this skill

| You are trying to...                                                      | Use instead                   |
| ------------------------------------------------------------------------- | ----------------------------- |
| Land an already-decided change through the gates (hooks, tests, PR)       | dotfiles-change-control       |
| Triage a live symptom right now ("bootstrap failed", "plugin missing")    | dotfiles-debugging-playbook   |
| Check whether a question was already settled (do this FIRST -- see below) | dotfiles-failure-archaeology  |
| Pick which open problem is worth attacking                                | dotfiles-research-frontier    |
| Prove one concrete fact (symlink chain, plugin install, hook firing)      | dotfiles-verification-toolkit |
| Decide what counts as a passing test / add a test                         | dotfiles-validation-and-qa    |

## Step 0: check the archaeology first

Before investigating anything, confirm the battle is not already settled.
Re-fighting a settled question is the most expensive failure mode this repo
has -- the tiered-orchestrate retirement rationale lives in a commit body,
not in any doc a naive grep would find.

```bash
git log --oneline --all --grep="<keyword>" -i     # search commit subjects+bodies
git log -1 --format=%B <hash>                     # read the full rationale
```

Then read dotfiles-failure-archaeology. If the question is settled there,
stop: cite the hash, do not re-run the experiment.

## The evidence bar

A diagnosis is accepted when ONE mechanism explains ALL observations --
including the negative ones (the things that did NOT fail) -- and survives
adversarial refutation. A mechanism that explains only the failure is a
candidate, not a finding.

### Worked example: the superpowers cloud install failure (settled)

Observations, all from real cloud sessions:

| #   | Observation                                          | Polarity                   |
| --- | ---------------------------------------------------- | -------------------------- |
| 1   | Superpowers plugin missing after first cloud session | failure                    |
| 2   | ECC plugin installed fine in the same run            | negative (did NOT fail)    |
| 3   | `claude plugins install` exited 0                    | negative (no error signal) |
| 4   | Resumed sessions installed superpowers successfully  | negative (worked later)    |

Rejected candidates and why:

- "Flaky network" -- explains 1, not 2 (same network installed ECC) and not 4's
  consistency.
- "Bad plugin id / typo" -- explains 1, contradicts 4 (same id worked on resume).
- "Installer bug" -- explains nothing about 2 or 4.

Winning mechanism: **async marketplace fetch race**. The github-backed official
marketplace is registered at launch but its first manifest fetch is
asynchronous; on a cold container `plugins install` resolves against an empty
manifest and no-ops with exit 0. This explains all four rows: (1) superpowers
lives in the async marketplace; (2) ECC's plain-git marketplace clones
synchronously, so it won the race; (3) "plugin not listed" resolves to
"nothing to do", which is exit 0; (4) by resume time the cache had warmed.
The mechanism and each observation are written into the `ensure_plugin`
comment block in bootstrap-cloud.sh -- read it as the house-style reference
for documenting a mechanism at the fix site.

Fixes then targeted the mechanism, not the symptom: wait on the manifest
condition the resolver actually checks (7cb28b7), register the marketplace by
git URL so the fetch is synchronous and cap the retry backoff (da54e17), and
finally move the install pre-launch entirely (8d4507f). A symptom-level fix
("add a sleep", "retry harder") would have passed a test run and shipped a
latent race.

Rule of thumb: list every observation in a table like the one above before
proposing a mechanism. If your mechanism has no column for the negatives, it
is not done.

## Predict before run

State the expected observation -- a number, a file, an exit condition --
BEFORE running the experiment. A prediction written after the run is a
rationalization.

- Good: "If the race mechanism is right, polling
  `~/.claude/plugins/marketplaces/claude-plugins-official/.claude-plugin/marketplace.json`
  until it lists `superpowers` will make install succeed deterministically on a
  cold container, with zero blind sleeps." That is exactly the design shipped in
  `marketplace_lists_plugin` / `ensure_plugin` (bootstrap-cloud.sh) -- the
  comments there explicitly contrast the deterministic wait with a blind timer.
- Bad: "Let's add a 30s sleep and see if it helps." No falsifiable prediction;
  a pass teaches nothing and a fail is ambiguous.

Corollary from the same saga: exit codes are observations, not verdicts.
`claude plugins install` exiting 0 without installing (verification added at
f91d7d2; the exit-0 no-op root-caused at 7cb28b7) is the canonical local
example. Predict the on-disk state (`installed_plugins.json`), then check the
disk.

## Idea lifecycle

```
hunch -> archaeology check -> hypothesis + prediction -> smallest experiment
      -> adversarial refutation (co-review / codex gates)
      -> ADOPTED (docs updated)  or  RETIRED (written why, in the commit body)
```

Both terminal states are success. An undocumented abandonment is the only
failure outcome.

### Worked example, adopted: cloud plugin declaration

1. Hypothesis: plugins must be placed pre-launch to be usable in session 1
   (post-launch SessionStart installs are dark until the next session) --
   root cause identified at c1c4500.
2. Experiments as PRs: self-bootstrap hook f2f13ab, settings reconcile
   910f2bc, marketplace-cache refresh 722c653, exit-code verification
   f91d7d2, manifest wait 7cb28b7, URL registration + capped backoff
   da54e17.
3. Settled design 8d4507f: declare plugins in `.claude/settings.json`
   (native pre-launch install), demote the hook to self-heal.
4. Documented: CLAUDE.md "Cloud sessions" section states the mechanism and
   why placement is load-bearing. An adopted idea is not done until the doc
   of record says so (see dotfiles-docs-and-writing).

### Worked example, retired: tiered-orchestrate

1. Built: fc88aac added a per-task dual-model Codex gate to the
   tiered-orchestrate subsystem.
2. Its own gate found live bugs -- documented in the fc88aac commit body
   itself: BASE_SHA was recaptured per rework round so retries reviewed only
   the fix commit, and the reviewer, given only file names, inspected the
   orchestrator checkout instead of the task worktree and passed vacuously.
3. Partial retreat: e401175 removed the per-task gate.
4. Full retirement: 7fefcb5 removed the whole subsystem (596 deletions) with
   the rationale in the commit body -- slower and costlier than superpowers
   subagent-driven-development + co-review. The fable->opus planner stopgap
   (4d8255d) died with it.

Retirement with a written why is a success outcome. The commit body is the
minimum durable record; verify with `git log -1 --format=%B 7fefcb5`.

## Where good ideas came from (historically)

| Source                     | Example                                                           | Verify                                            |
| -------------------------- | ----------------------------------------------------------------- | ------------------------------------------------- |
| Papercuts in real sessions | Whole cloud plugin saga started as "why is /brainstorm missing"   | `git log -1 --format=%B f2f13ab`                  |
| Upstream ecosystem moves   | GSD npm package rug-pulled -> retirement + sanctioned fork policy | `git show 9ad4dc8`; dotfiles-external-positioning |
| Audits                     | todo.md public-prep audit hardened the install surface            | `git show c0a9072 --stat`                         |
| Cross-model review         | fc88aac's own Codex gate surfaced its scoping bugs                | `git log -1 --format=%B fc88aac`                  |

When hunting for the next idea (rather than validating one), go to
dotfiles-research-frontier.

## Adversarial refutation: route it through the review skills

Do not self-certify a mechanism or a design. This repo has an assigned
adversary: the cross-model review pipeline (`codex-spec-review`,
`codex-plan-review`, `co-review` -- routing in claude/CLAUDE.md "Default
Skill Routing"). A different model attacking the same claim is the cheapest
refutation available here, and it has a track record: the tiered-orchestrate
gate's fatal bugs were found by its own dual-model review, not by its author.

Rules of engagement (from claude/operating-principles.md):

- Push back on findings you disagree with and name the disagreement; do not
  fold blindly or dismiss blindly.
- Verify reviewer output on disk (`git diff` + grep) before relaying it -- a
  reviewer self-report is a hypothesis.
- Treat empty findings on a large diff as a tool-failure signal, not
  cleanliness.

## The promotion rule

No idea skips the gates, regardless of how good it looks or how senior the
proposer sounds. A validated mechanism plus a passing experiment earns the
right to ENTER dotfiles-change-control -- classification, tests, hooks, PR
review -- not to bypass it. The cloud plugin fix, the strongest-evidenced
change in this repo's history, still went through five reviewed PRs. If your
change feels too obviously correct for the gates, that is a signal to re-read
the tiered-orchestrate arc, which also felt correct at fc88aac.

## Checklist before claiming a finding

- [ ] Archaeology checked -- not re-fighting a settled battle?
- [ ] All observations tabled, negatives included?
- [ ] One mechanism covers every row?
- [ ] Prediction written BEFORE the experiment ran?
- [ ] On-disk state checked, not just exit codes?
- [ ] Refutation routed through a second model (co-review / codex gates)?
- [ ] Outcome recorded durably -- doc update if adopted, commit-body why if retired?
- [ ] Change entering (not bypassing) dotfiles-change-control?

## Provenance and maintenance

Facts date-stamped 2026-07-02. Re-verify before relying on them:

- Commit hashes (7cb28b7, da54e17, 8d4507f, c1c4500, f2f13ab, 910f2bc,
  722c653, f91d7d2, 2304015, fc88aac, e401175, 7fefcb5, 4d8255d, 9ad4dc8,
  c0a9072, 5b799dd): `git show <hash> --stat`. History rewrites would
  invalidate them.
- `ensure_plugin` / `marketplace_lists_plugin` mechanism comments:
  `grep -n "deterministic" /home/user/dotfiles/bootstrap-cloud.sh` (use the
  repo-relative path `bootstrap-cloud.sh` on other checkouts).
- Review-pipeline routing (codex-spec-review / codex-plan-review / co-review):
  `grep -n "codex-spec-review" claude/CLAUDE.md`.
- Refutation rules of engagement: `grep -n "Push back" claude/operating-principles.md`.
- Sibling skill names referenced here: `ls .claude/skills/` -- 16 skills
  planned as of 2026-07-02; names may drift.
- Tiered-orchestrate deletion size (596 deletions): `git show 7fefcb5 --stat | tail -3`.
