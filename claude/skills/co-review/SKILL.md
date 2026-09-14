---
name: co-review
description: Freeze one code change, obtain independent Claude and Codex findings, then verify them before fixing.
---

# Co-Review

Set `REVIEW_SKILL_FILE` to this skill's absolute `SKILL.md` path supplied by
the skill loader. Resolve installed symlinks before using a helper. If the
loader supplies no path, the existing `DOTFILEDIR` is the fallback; never guess
from the target checkout or another account's skill directory.

```bash
REVIEW_ROOT=$(uv run --no-project python - "${REVIEW_SKILL_FILE:-}" "${DOTFILEDIR:-}" <<'PYROOT'
from pathlib import Path
import sys

source, fallback = sys.argv[1:]
if source and (not Path(source).is_absolute() or Path(source).name != "SKILL.md"):
    raise SystemExit("Use the absolute SKILL.md path supplied by the skill loader")
root = Path(source).resolve(strict=True).parents[3] if source else (
    Path(fallback).expanduser().resolve(strict=True) if fallback else None
)
required = ("claude/skills/co-review/scripts/review.py", "claude/hooks/agent_runtime.py")
if root is None or not all((root / name).is_file() for name in required):
    raise SystemExit("Installed review helpers are unavailable")
print(root)
PYROOT
) || exit 2
REVIEW_HELPER="$REVIEW_ROOT/claude/skills/co-review/scripts/review.py"
RUNNER="$REVIEW_ROOT/claude/hooks/agent_runtime.py"
```

Use this skill after implementation and before a merge. Both finders read one
frozen snapshot. Do not publish, comment, fetch, or modify the source checkout
during review preparation.

Before changing to the target repository, resolve the helper to an absolute
path. Never invoke a helper through a path relative to the target repository.

```bash
test -f "$REVIEW_HELPER" || { echo "co-review helper is unavailable" >&2; exit 2; }
# PR review: resolve the base from the PR's real target branch.
uv run --no-project python "$REVIEW_HELPER" prepare --repo "$REPO" --base-ref "$BASE_REF" \
  --output-dir "$REVIEW_OUTPUT" --include-untracked path/inspected-first
# Local / plan / no-PR review: pin an explicit base commit instead.
#   ... prepare --repo "$REPO" --base "$BASE" ...
```

For a PR review first confirm `origin` is the PR's base repository: compare
origin's real fetch URL (`git remote get-url origin`) to the base repo from the
pulls REST response (`gh api repos/{owner}/{repo}/pulls/<n> -q
.base.repo.full_name`; `baseRepository` is not a `pr view` field). On a fork PR
`origin` is the contributor's fork and resolving the base there is wrong; fetch
the verified target remote or stop. Then pass `--base-ref <baseRefName>` (the PR's target
branch from `gh pr view --json baseRefName`). The helper fetches that origin branch
read-only into an invocation-owned ref and diffs against the merge-base
(three-dot, matching GitHub "Files changed"), so a stale local base cannot
produce phantom findings for commits already on the target. Use `--base <sha>`
only for local or plan review with no PR target. The base-ref fetch is a read
that establishes the diff target; the no-mutate-source rule (do not publish,
comment, or modify the checkout during preparation) still holds -- the only ref
written is the invocation-owned `refs/co-review/*`, deleted before return.

Require explicit repository, base (`--base` XOR `--base-ref`), output directory,
and untracked paths. The helper captures the committed head plus staged and
unstaged changes through a temporary index, accepts only explicitly named
regular untracked paths, and rejects symlinks, private paths, inherited Git
routing, source drift, and tree mismatch. Its manifest pins
base/base_ref/base_ref_tip/head/tree, source identity, two worktrees,
scope/exclusions, and an ownership nonce.

```bash
uv run --no-project python "$REVIEW_HELPER" verify --manifest "$MANIFEST"
```

An empty diff, helper failure, empty finder output, or malformed bounded output
is incomplete, never a clean review.

## Claude-led dispatch

The Claude half MUST be performed by a fresh Claude instance -- a dispatched
reviewer subagent or the `/code-review` flow that spawns fresh review agents --
pointed at `snapshot.claude_root`, which is based at the pinned base with the
reviewed tree applied to its index. The implementing or authoring session MUST
NOT review its own diff inline; "the diff is small, I'll just review it
myself" is exactly the biased self-review this gate exists to prevent. Give
the fresh reviewer only the round's defined inputs -- for a complete round the
frozen snapshot, the base, the failure-class rubric
(`references/failure-classes.md` in this skill directory), and the
deferral digest when deferred lineages exist; for a scoped round
additionally the prior round's open blocking lineages and the fix diff
-- never the authoring session's rationalizations. It is the Claude half, not a substitute for
Codex. Controller disk-verification of a fix is not a substitute for either
half.

Decorrelate the two finder halves' reading order in a complete round.
Mechanism: from the frozen diff's changed paths, build two reading-order
lists -- one in natural diff order (`git diff --name-only <base>`
order), one grouped by subsystem (directory or module grouping the
orchestrator picks when freezing the round and records in the ledger).
Append one list to each half's prompt as "Read and probe the changed
paths in this order". Both halves still read the same frozen snapshot;
only the prescribed traversal differs. Structured reordering measurably
changes which defects a reviewer finds; random shuffling degrades
reviewer accuracy and is not used. Attacker and skeptic receive no
reading-order list.

The independent Codex finder runs from `snapshot.codex_root` through the shared
runtime runner. It selects the policy model and effort and returns structured
runtime metadata; this skill never restates a route table.

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/co-review-codex.XXXXXX")
cat >"$PROMPT_FILE" <<'EOF'
Review only the frozen change against the base commit named below. Probe
every failure class in the rubric appended below against this diff, then any
further issues. Report each actionable issue as severity, file:line, failure
scenario, and concrete fix. End with one verdict. Do not invoke skills,
partners, or external actions.
EOF
printf '\nBase: %s\n\n' "$BASE" >>"$PROMPT_FILE"
RUBRIC="$REVIEW_ROOT/claude/skills/co-review/references/failure-classes.md"
grep -q '^## Classes' "$RUBRIC" || { echo "rubric Classes heading missing" >&2; exit 2; }
sed -n '/^## Classes/,$p' "$RUBRIC" >>"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run --runtime codex --role reviewer --risk normal \
  --provisional --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

When deferred lineages exist, append the deferral digest (see "Finding
lineages and deferrals") to the prompt before dispatch; the digest is
context to prevent re-derivation, never a review target.

For a scoped round, build the prompt from the prior findings and the fix
diff instead (`$PREV_HEAD` is the previously reviewed head from the last
posted marker, `$HEAD` the newly frozen committed head this round reviews,
`$FINDINGS_FILE` the prior round's OPEN BLOCKING lineages only, saved
locally -- deferred and resolved lineages never enter the review-target
table; they travel in the deferral digest; the diff
read from the source repository is a read, not a mutation):

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/co-review-codex.XXXXXX")
cat >"$PROMPT_FILE" <<'EOF'
Scoped re-review of the frozen change. For each OPEN BLOCKING prior finding
listed below, return ADDRESSED or NOT-ADDRESSED against the frozen tree
with one line of evidence; deferred lineages appear only in the digest and
are not review targets, but if your in-scope review yields new evidence, a
severity escalation, or fix-regression implication for one, report it.
Then complete your review scope over the fix diff below ONLY -- do not
stop at the first finding. If the fixed subsystem
still contains failure orderings, enumerate every one you can construct.
Zero or one residual is a complete answer only when you also list the
changed mechanisms and the failure orderings you examined (file
references included) -- a bare completion sentence is not scope evidence;
when several residuals exist, report them all. Report each as severity,
file:line, failure scenario, and concrete fix. End with one verdict. Do
not invoke skills, partners, or external actions.
EOF
printf '\nPrior reviewed head: %s\nCurrent head: %s\n\nPrior findings:\n' \
  "$PREV_HEAD" "$HEAD" >>"$PROMPT_FILE"
test -s "$FINDINGS_FILE" || { echo "prior findings file missing or empty" >&2; exit 2; }
cat "$FINDINGS_FILE" >>"$PROMPT_FILE" || { echo "appending findings failed" >&2; exit 2; }
printf '\nFix diff:\n' >>"$PROMPT_FILE"
git -C "$REPO" -c diff.external= diff --no-ext-diff --no-textconv \
  "$PREV_HEAD..$HEAD" >>"$PROMPT_FILE" || { echo "fix diff failed" >&2; exit 2; }
uv run --no-project python "$RUNNER" run --runtime codex --role reviewer --risk normal \
  --provisional --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

When deferred lineages exist, append the deferral digest (see "Finding
lineages and deferrals") to the prompt before dispatch; the digest is
context to prevent re-derivation, never a review target.

Use the runner only; do not launch a generic or nested Codex CLI review. Pass
`--risk critical` only for explicitly critical review risk, never diff size.
Record requested route separately from runtime-reported model or effort; unknown
observation remains unknown. A failed, malformed, or unsupported result makes
the independent pass incomplete.

## Bounded attacker and skeptic

Run at most one attacker when frozen changed paths affect auth, authorization,
validation, permission, credentials, tokens, signatures, secrets, or a review
or guard hook. It states a concrete bypass scenario. Run at most one skeptic to
reproduce high-severity findings and mark each confirmed, disproved, or
uncertain. Resolve each fresh Codex role through `agent_runtime.resolve_route`
with role `reviewer` or `skeptic`; never select a model or effort ad hoc.

Merge only findings checked against the frozen files. Retain uncertain or
unsupported high-severity findings as unresolved and do not return a clean
verdict while a required finder or skeptic is incomplete. Apply confirmed fixes
within existing user authorization; otherwise ask before editing source files.
After all readers finish, remove only this run's snapshots:

```bash
uv run --no-project python "$REVIEW_HELPER" cleanup --manifest "$MANIFEST"
```

Cleanup refuses foreign roots, marker mismatches, modified trees, ignored or
untracked snapshot files, and unexpected owned-output entries. Preserve the
snapshot if it refuses cleanup.

## Fix-plan gate

After any round whose verdict leaves blocking findings, and before
dispatching the fix implementer, run one fix-plan review turn -- but only
while the loop still authorizes another fix wave (never after the caps
are spent or after a divergence or escalation exit):

1. Write a fix-design note per affected subsystem: the intended fix
   mechanism for each blocking finding, referenced by lineage ID --
   design, not code.
2. Spend one read-only Codex turn (shared runner, role `reviewer`) on the
   note with this instruction: "Assume this design is implemented
   correctly. Enumerate every remaining failure ordering you can
   construct. If the failure family is not closed, name the minimal
   design change that closes it."
3. Fold the response into the fix plan. Every concrete residual failure
   ordering the gate surfaces enters the lineage ledger as a finding of
   the round that triggered the gate, continuing that round's lineage
   ordinals, with that round as its discovery round
   and the blocking status its severity earns there; dismissing one
   requires recorded evidence disproving the scenario -- a disagreement
   ruling alone cannot discharge it. Rule any disagreement as the
   orchestrator and record the ruling in the round ledger. One turn, no
   iteration; then dispatch the implementer.

The gate consumes no round cap. Its seat evidence is the runner session
id plus the enumeration text in the ledger. On failure or timeout, retry
once with a longer timeout (at least 1.5x the first; 600s -> 900s is the
reference pair); on a second failure, perform the enumeration yourself
and record the seat as FAILED in the ledger TOGETHER WITH both failure
artifacts (each attempt's runner result or timeout evidence and its
timeout setting -- a FAILED entry without both artifacts is not a FAILED
entry). A FAILED gate does not discharge independent scrutiny of the fix
design: name the affected subsystems as priority probe targets in the
next round's seat prompts, so the design the partner never reviewed gets
independent eyes in review. Never block the loop on partner
availability, and never start implementation without either a completed
gate or a recorded FAILED entry.

## Re-review loop

One pass is not a gate. Two round types:

- **Complete round**: freeze the committed head; both finders -- the fresh
  Claude reviewer and the Codex runner -- review the whole frozen diff,
  probing every class in `references/failure-classes.md`; plus any bounded
  attacker or skeptic required by the frozen paths; plus skeptic
  verification of high-severity findings. A round that leaves any required
  finder or verification incomplete cannot approve.
- **Scoped round**: freeze the committed head; both independent halves
  (fresh Claude reviewer AND Codex runner -- never only the half that
  raised a finding) receive the prior round's open blocking lineages and
  the fix diff since the last posted round (prior reviewed head to new
  head). Each half returns
  a per-finding verdict, ADDRESSED or NOT-ADDRESSED with one-line
  evidence, plus any new actionable findings in the fix diff only. Skip
  the attacker/skeptic unless a fix touched the sensitive paths that
  trigger them. For a trivial fix the fresh Claude pass may be a
  cheap-tier reviewer, but it must exist.

**Seat evidence rule.** Every seat in every round -- finder halves,
attacker, skeptic, scoped halves -- counts only when its runtime
artifact exists: the Codex runner's structured result (session id,
success status) or the dispatched Claude reviewer's agent result or
report file. In a Codex-led run (the codex/skills adapter reviews
in-session rather than through a nested runner), the Codex half's
evidence is that session's own bounded findings output plus its resolved
route metadata. A narrated dispatch with no artifact is not a dispatch. A
round claiming completion without an artifact for every required seat
is incomplete, never clean. Cite each seat's artifact (runner session
id or report path) in the round's comment.

Sequence:

0. **Pre-freeze self-audit.** Before round 1, the author walks
   `references/failure-classes.md` against their own diff and fixes what
   it catches. Not a review round; posts nothing.
1. **Round 1: complete round.** Any complete round with zero effective
   blockers -- round 1 included -- terminates the loop with APPROVE
   ((a) clean, (b) empty, clean tree); floor-deferred and advisory
   lineages do not block, and surface at the branch gate.
2. Post the round's comment first (findings table + marker,
   verdict=CHANGES) -- **before** committing any fix -- then apply
   confirmed fixes with verified repros, re-run the affected tests,
   commit and push.
3. **Scoped round** at the new committed head. Any NOT-ADDRESSED verdict
   on an open blocking lineage, or any new finding that is an effective
   blocker under the current round's floor: fix (repeating step 2's
   post-then-fix order) and run another scoped round. New findings the
   floor defers enter the deferral digest instead. A clean scoped round
   advances to the final complete round.
4. **Final complete round** at the committed head. Zero effective
   blockers = APPROVE. Findings the round's floor defers enter the
   deferral digest, not this classification. Otherwise classify each
   effective blocker per distinct defect (both halves reporting the same
   underlying defect is one finding):
   - **fix-regression** -- introduced by a fix commit. When provenance is
     disputed or cannot be established against the round-1 tree, classify
     as fix-regression. Fix it (repeating step 2's post-then-fix order),
     then return to step 3.
   - **new-surface** -- present since round 1; a rubric miss. Fix it
     (repeating step 2's post-then-fix order), and grow the rubric: in
     the rubric's own repository add or generalize the class in the same
     commit as the fix; from any other repository record the missed
     class and update the rubric as a separate authorized dotfiles
     change. Then return to step 3. New-surface findings never count
     toward divergence.

   **Divergence:** two complete rounds in one loop that each contain at
   least one fix-regression finding. Stop and escalate for a structural
   fix.

   **RECOMMEND SPLIT:** when a complete round's blocking findings cluster
   across more than one subsystem or evidence model, the round output MAY
   include a `RECOMMEND SPLIT` line naming the seams. The orchestrator
   raises the split question with the user immediately after the round
   that emits the line -- any complete round, not only the escalation
   exit -- and the loop pauses on that answer before spending further
   rounds. This is a decision point, not a new loop state.

5. **Caps:** at most 3 complete rounds and at most 3 scoped rounds per
   PR. Print each round's type and actionable count. The cap check
   applies to the round about to start: a clean scoped round always
   advances to the final complete round while complete-round capacity
   remains, even with the scoped cap exhausted. Stop and escalate only
   when the next required round would exceed its own type's cap without
   APPROVE. Real bugs can persist across rounds: never hard-stop merely
   because a count failed to strictly decrease; the caps and the
   divergence rule are the only stop conditions.

### Finding lineages and deferrals

THE LEDGER: one append-only markdown file, `round-ledger.md`, in a
loop-owned session directory that OUTLIVES the per-round output
directories -- a sibling of them, never inside one, because `prepare`
requires an empty output directory and `cleanup` removes the output
directory after verifying it holds only its own four entries. Every
round of the loop appends to that same file. It carries -- per
round -- the round index and type, the frozen head, the seat artifacts,
the decorrelation grouping, every lineage row (ID, severity, status,
blocking, category), fix-plan gate rulings and enumeration text (or the
FAILED entry with both failure artifacts), and the verdict with its
(a)/(b) components. Each completed round's comment reproduces its rows,
so the PR carries a durable copy; a resumed loop reconstructs effective
blockers from the ledger and re-verifies them against the live tree
before continuing (never from memory of prior sessions).

The orchestrator assigns every distinct finding a stable lineage ID at
the round's merge/dedup step (round + ordinal, e.g. R1-F3). Seats report
findings; they never mint IDs. Re-reviews, fix waves, ledgers, and
digests refer to lineages, not re-derived descriptions; a finding whose
code moved keeps its lineage. Two seat reports with the same root cause
merge into the earlier lineage; the merged lineage retains every source
report's location and failure scenario, and closes only when every
retained scenario is verified fixed -- reports needing independent
repairs stay separate, cross-linked lineages. A finding that splits into distinct root
causes gets new IDs cross-referenced to the parent; children of an
unresolved BLOCKING parent inherit the parent's blocking obligation and
original discovery round (the floor treats them at the parent's age,
never as fresh findings), and the parent closes only when every child is
resolved. A finding is a FIX-REGRESSION iff any fix-wave commit in this
loop introduced its defect -- either absent from the round-1 frozen tree
and introduced by a fix wave, or RESOLVED earlier in this loop and
restored by a later fix wave (reintroduction reopens the original
lineage as blocking, never a fresh deferrable finding). Discovery round
is irrelevant: delayed discovery never downgrades a regression to a
deferrable new finding.
When provenance is disputed or cannot be established against the
round-1 tree, classify as fix-regression, and the finding keeps blocking
status until any classification dispute resolves -- ambiguity never
defers.

Advisory findings (minor/low/nit) are recorded once with status DEFERRED
and are not re-checked in later rounds. Deferred lineages -- advisory or
DEFERRED-BY-FLOOR -- are never silently dropped: inject them into every
subsequent seat prompt as a deferral digest, and surface them once at
the branch gate as a wrap-up note for the author. The digest text
itself carries the reopen exception -- it reads: "Previously ruled, do
not re-derive or re-litigate the lineages below. Suppress only
unchanged duplicate reports: if your in-scope review yields new
evidence, a severity escalation, or fix-regression implication for any
of them, report it." -- followed by one line per lineage (ID, severity,
one-line summary, ruling). Prompts that exclude deferred lineages as
review targets carry the same exception.

Reopen rules: ONE seat reopens a deferred lineage immediately when its
evidence makes the finding blocking under the current round's policy (an
escalation to a severity the round's floor treats as blocking, or
implication in a fix-regression) -- evidence, not vote counting, is the
trigger. Re-raises that remain non-blocking under the current policy
reopen only when TWO independent seats have re-raised the same lineage;
those re-raises accumulate across all later rounds. Either reopen path
transitions the lineage to open-and-blocking: it enters verdict
component (b) as an unresolved effective blocker and the floor cannot
defer it again. Deferral suppresses duplicate reporting, never
investigation -- a seat that independently finds new evidence about a
deferred lineage while reviewing its scope reports it. Deferral never
suppresses newly blocking evidence.

### Round-indexed blocking floor and verdict

- Rounds 1-2: all major/high/critical findings block (current behavior).
- Round 3 onward (complete or scoped): only (a) HIGH/critical findings,
  (b) fix-regressions of any severity, and (c) already-open blocking
  lineages can block. A NEW major-severity finding is recorded with its
  severity intact, status DEFERRED-BY-FLOOR, Blocking=no, and enters the
  deferral digest instead of forcing a fix wave.
- HIGH/critical findings are never capped and never deferred, at any
  round index. Everything the floor defers surfaces at the branch gate
  and is subject to the reopen rules in "Finding lineages and deferrals"
  above.
- Severity fails closed at every round index: a finding whose severity
  is unrecognized (anything outside
  critical/high/major/minor/low/nit/advisory),
  missing, or disputed between seats is blocking and never
  floor-deferrable until clarified. A lineage's recorded severity is the
  maximum any seat reported, lowered only by a skeptic disproof -- the
  orchestrator never downgrades a seat's severity on its own.

The round verdict is two-part:

- (a) `coworker_review.verdict_from_findings` (script unchanged) computes
  the severity component over ONLY rows whose effective status is
  open-and-blocking. Rows with status DEFERRED, DEFERRED-BY-FLOOR, or
  RESOLVED are excluded from the helper's input entirely; they live in
  the ledger, never in the verdict input.
- (b) the orchestrator forces REQUEST CHANGES whenever any UNRESOLVED
  EFFECTIVE BLOCKER exists regardless of severity: an open
  fix-regression lineage, a finding whose classification is disputed
  (ambiguity never defers), an unresolved child carrying an inherited
  blocking obligation, or a deferred lineage reopened under the reopen
  rules -- any open-and-blocking lineage whose severity the (a) helper
  would treat as advisory belongs in (b).

APPROVE requires both (a) clean and (b) empty. The ledger persists, per
round: the round index, each deferred lineage with severity, each
effective-blocker lineage with its category, and the resulting verdict.

Examples: a round-3 COMPLETE-round table whose only finding is a
floor-deferred major is APPROVE ((a) sees no rows, (b) empty) and the
major surfaces at the branch gate (a clean scoped round still advances
to the final complete round; only a complete round emits APPROVE). A
round whose only open finding is a minor fix-regression is REQUEST
CHANGES ((a) clean, (b) fires). A round whose only open finding
is an advisory-severity item under classification dispute is REQUEST
CHANGES until the dispute resolves.

A finding that reappears unfixed is still actionable -- not a dismissible
"duplicate". "Duplicate/non-actionable" means only: already fixed and
re-surfaced against old code, explicitly confirmed wontfix, or
out-of-scope for this change.

Worked examples (trace each against the sequence above):

- **Clean round 1:** complete round finds nothing, tree clean -> APPROVE.
  1 round.
- **Happy path:** round 1 (complete) finds 3 issues -> post, fix -> round
  2 (scoped) all ADDRESSED, no new findings -> round 3 (final complete)
  clean -> APPROVE. 3 rounds.
- **Scoped cap exhausted:** rounds 2-4 are scoped (a fix kept leaving one
  NOT-ADDRESSED); round 4 comes back clean. Scoped cap (3) is now spent,
  but the next required round is complete and only 1 complete round has
  run -> advance to the final complete round. Clean -> APPROVE.
- **Divergence:** final complete round finds a defect introduced by a fix
  (fix-regression #1) -> fix -> scoped round clean -> second final
  complete round finds another fix-introduced defect (fix-regression in a
  second complete round) -> divergence -> stop, escalate.

## Coworker PR review (`--comment`)

Use this mode to review someone else's PR and hand back a verdict, not to run
the own-PR loop above. No fixes are applied here -- the author writes the fix;
fixing a coworker's branch yourself is the own-PR loop against a local
checkout of it, not this mode.

Binding gate first: run

```bash
uv run --no-project python "$REVIEW_ROOT/claude/skills/co-review/scripts/repo_binding.py" \
  --repo "$REPO" --pr-url "$PR_URL"
```

A non-zero exit means `origin` does not bind to the PR's base (a fork or the
wrong remote) -- stop, or fetch the verified base remote before continuing.
The PR URL is the independent identity for this check; never derive it from
`origin`. The origin probe runs with `GIT_*` routing stripped so an inherited
`insteadOf` cannot make it disagree with the fetch that co-review `prepare`
performs.

Known limitation: the SSH resolution mirrors `git`'s connection via `ssh -G`
with the URL's user and port, but does not parse a repo-local
`core.sshCommand`. A `core.sshCommand` that rewrites the destination host is
outside this check's threat model (it requires control of the reviewer's own
git config); the binding assumes no such override.

Per-round output:

1. A findings table `| Severity | File:line | Issue | Blocking |` -- no `Fix`
   column, since the author writes the fix, not this review.
2. A visible `VERDICT: APPROVE` or `VERDICT: REQUEST CHANGES` line.
3. The hidden coworker marker from
   `claude/skills/co-review/scripts/coworker_review.py`'s `build_marker(...)`.

Compute the verdict with `coworker_review.verdict_from_findings(findings)`:
major/high/critical findings are blocking, minor/low/nit/advisory are
advisory, and an unrecognized severity fails closed to blocking. Fill each
row's `Blocking` column with `coworker_review.is_blocking(severity)`.

Re-review scope: read the latest trusted coworker marker with
`coworker_review.select_coworker_marker(comments, {gh_user})`; compute
`is_ancestor` via `git merge-base --is-ancestor <prev_sha> <new_head>`; then
call `coworker_review.decide_review_scope(prev_marker, new_head,
current_base_ref, current_base_ref_tip, is_ancestor)`. On `full`, re-diff the whole PR
(three-dot). On `incremental`, review `prev_head..new_head` and also re-check
every still-open prior finding against the new tree -- an incremental diff
alone can miss a finding whose surrounding code moved. The verdict always
gates on all currently-open blocking findings, not just the ones from this
round's diff.

This mode never emits the own-PR currency marker (`co-review: ...` from
"Review provenance marker" below). A coworker's PR is not your pr-ready gate.

## Review provenance marker

On every completed round, post one PR comment, by the authenticated `gh` user,
that is both human-readable and machine-parseable. Post it before committing the
round's fixes (per the "Re-review loop" order) so the marker's `sha` sits above
those fix commits on the timeline. Lead with a findings **table** (clearer than
bullets), then the hidden currency marker as its own unindented top-level line:

```markdown
### Co-review round <n>

| Lineage | Severity | File:line       | Issue | Status | Fix |
| ------- | -------- | --------------- | ----- | ------ | --- |
| R1-F1   | HIGH     | path/file.py:42 | ...   | open   | ... |

(Status: open, RESOLVED, DEFERRED, or DEFERRED-BY-FLOOR -- deferred rows
stay visible in the durable record.)

(or "No actionable findings." when the round is clean)

<!-- co-review: sha=<reviewed-head-sha> base=<resolved-merge-base> base_ref=<baseRefName> verdict=<APPROVE|CHANGES> round=<n> -->
```

`sha` is the frozen committed head, `base` the resolved merge-base from
`--base-ref`, `base_ref` the PR target branch, `verdict` APPROVE only on a
complete round with zero effective blockers ((a) clean, (b) empty);
deferred lineages do not forfeit APPROVE.

**Emit APPROVE only for a snapshot that equals the committed head.** `prepare`
folds staged and unstaged changes into the reviewed tree, but the marker's `sha`
names the committed head -- so an uncommitted local fix could earn an APPROVE
whose `sha` still points at the buggy committed head, and the gate would pass for
content that was never on the PR. For a PR review, freeze with a **clean working
tree** and confirm `snapshot.codex_tree == source.source_tree` in the manifest
before posting APPROVE; never emit an APPROVE marker for a dirty snapshot whose
tree differs from its head.

The marker line must be exactly one per comment,
unindented, and outside the table/any code fence, so `scripts/pr_ready_gate.py`
accepts it -- the gate and `ship`'s resume rule parse the latest such marker by
comment creation instant and ignore quoted, fenced, indented, multiply-markered,
or other-author comments.

## Document reviews

Plan/spec review skills require an explicit document, task id, runtime, and the
same absolute helper. Artifact output is always private under the selected
account/repository/task payload root; an explicit output directory must be a
single direct launch subdirectory there. The helper records caller-selected task id, account
id, and repository id. The coordinator validates the digest and containment under the selected
account/repository/task payload root before accepting a planning milestone;
retain the helper metadata as provenance, not as an independent ownership proof. Plans live under
`docs/superpowers/plans/`; specs live under `docs/superpowers/specs/`.
