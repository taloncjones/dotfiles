# Ship carry-forward and delta tier (SKILL.md section 6)

## Carry-forward and delta tier (section 6)

**Merge-main-only commits keep the verdict.** On every check-in whose task
is `reviewed` with a `stale` handoff of verdict `APPROVE`, before any ship
dispatch decision, prove the carry-forward against the pinned handoff;
`ship.json` supplies the paths and digests:

```bash
git -C <worktree> fetch origin <default>
python3 "$GATE_REPORT" carry-forward --repo <worktree> \
  --report <report_path> --expected <expected_path> \
  --report-sha256 <report_sha256> --expected-sha256 <expected_sha256> \
  ><scratchpad>/carry-forward.json
```

Exit 0 keeps the verdict for the new head: post the record's
`audit_comment` exactly as ship step 5 (dedupe on
`co-review-audit head=<head>`, standing authorization), then the
carry-forward marker under the co-review skill's Carry-forward and Publish
rules (its dedupe; a personal repository needs no go, a work repository
asks the owner with `AskUserQuestion`), and never dispatch a gate for that head.
Exit 1 continues to the ship dispatch rules below. `merge-ready` still pins
the gated head and reports `head-moved` for it, so the director merges that
head only after one `AskUserQuestion` merge prompt, as in a work repository.

**Delta tier.** When a dispatch is due under rule (b), the stale handoff's
verdict is `APPROVE`, and the carry-forward proof above exited 1, run:

```bash
python3 "$GATE_REPORT" delta-class --repo <worktree> \
  --report <report_path> --expected <expected_path> \
  --report-sha256 <report_sha256> --expected-sha256 <expected_sha256> \
  --max-files <files> --max-lines <lines> --diff-out <scratchpad>/delta.diff
```

`<files>` and `<lines>` come from `config.json` `ship.delta`
(`references/state-layout.md`), defaulting to 5 and 150. Exit 1 dispatches
as usual. On exit 0, a personal repository (`account-scope` reports
`personal_repository` true) proceeds; a work repository asks the owner once
with `AskUserQuestion`, options "Delta round (Recommended)" and "Full
round", naming the PR, head, caps and the recommendation's `stats`; "Full
round" dispatches as usual. The delta brief carries these lines:
`herdr-ship-brief: tier=delta`,
`herdr-ship-prior-handoff: <pinned ship.json path>`,
`herdr-ship-delta-head: <head>`, and
`herdr-ship-delta-caps: <files>/<lines>`.

**Gate base.** The gate's base is the live tip from `git ls-remote` (not the lagging `baseRefOid`; co-review Freeze), and `ship.json` `base_sha` copies the expected identity's `base`, so a fresh gate gates the current PR base. A head behind that base is gated on its merge result and needs no merge. On a `prepare` conflict the ship worker records INCOMPLETE and the director's repair flow resolves it; no worker merges the base into the branch. A base that moves cleanly after the gate needs no re-gate: `merge-ready` re-checks it with `base-check`.

A ship worker's `## Lessons` section in `STATE_ROOT/<slug>/tasks/<task_id>.ship.md` is not harvested at check-in; `/post-merge` step 1 reads it.
