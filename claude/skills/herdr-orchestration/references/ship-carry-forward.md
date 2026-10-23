# Ship carry-forward and delta tier (SKILL.md sections 4 and 6)

## Task review carry (section 4)

`carry-review` reports `carry-review` ahead of `stale-review-reset` for a
`reviewed` task whose HEAD moved with an approval that still verifies at its pin.
Run `$CORE carry-review --repo-slug <slug> --task-id <id> --session <s>
--fence <f>` without asking, as a long background run (it runs the pinned
contract; wait on the `EXIT` line), and start no second run for a task while
one runs. It proves every commit since the reviewed head is a clean main
merge, runs the contract at HEAD, and records the proof in
`artifacts/<task>/review-carry/`. Exit 0: re-pinned at HEAD with
`review_carry`; the next check-in reports `ship`. Exit 3: the task is reset as
the stale-verdict reset (SKILL.md section 4) does and the next check-in reports `dispatch-review`.
Exit 4: nothing written; for a held lock wait for the earlier run, else the
next check-in offers it again, and repeated exit 4 goes to the user. Exit 2:
integrity halt; surface it.

## Carry-forward and delta tier (section 6)

The task-local review approval carries across clean main merges the same way
(`carry-review`, Task review carry above).

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
rules (its dedupe) and `references/auto-actions.md` (Carry-forward marker),
without asking in any repository, and never dispatch a gate for that head.
Exit 1 continues to the ship dispatch rules below. `merge-ready` still pins
the gated head and reports `head-moved` for it, so the director merges that
head only after one `AskUserQuestion` merge prompt, as in a work repository.

**Small tier.** A dispatch without `--tier` renders
`herdr-ship-brief: tier=auto`, `herdr-ship-small-caps: <files>/<lines>` and,
when `ship.small.sensitive_paths` is set, `herdr-ship-small-sensitive:
<prefix> ...`. The ship worker passes them to `classify`; co-review picks
the tier. A `small` handoff other than APPROVE is handled like a `delta`
one: section 6 rule (c) relaunches with `--tier full`, and 6a step 0
surfaces a full `INCOMPLETE`. A small APPROVE is a valid delta prior.

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
as usual. On exit 0 the director dispatches the delta round in every
repository, under `references/auto-actions.md` (Delta round). The delta brief carries these lines:
`herdr-ship-brief: tier=delta`,
`herdr-ship-prior-handoff: <pinned ship.json path>`,
`herdr-ship-delta-head: <head>`, and
`herdr-ship-delta-caps: <files>/<lines>`.

## Ship dispatch details (section 6)

Without `--tier`, on a first gate or after an `APPROVE`, the brief carries `herdr-ship-brief: tier=auto` and the
small-tier caps from `config.json` `ship.small`; co-review picks the tier.
`dispatch-gate` refuses a live or unknown pinned agent. For a pinned run with no
`ship.json` (it stopped before the gate wrote it), pass `--infra-rerun`
(`references/auto-actions.md`); it relaunches at most
once per reviewed head: it refuses when `ship_relaunch_head` equals
`review_head_sha`, otherwise writes `ship_relaunch_head` before launching
(so an interrupted relaunch parks the task) and forces `tier=full`. It
launches read-only on `claude`, pins `ship_launch_id`, then settles the old
pinned row.
