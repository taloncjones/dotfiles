# Final Co-Review Gate Policy

<!-- gate-policy:start -->
## POLICY

Use this policy only for a finished change before a merge decision. It returns
one final-gate report with `APPROVE`, `CHANGES`, or `INCOMPLETE`, then stops.
Each plain gate is read-only and does not publish, merge, post a comment, fix
code, create another gate, or turn advisory feedback into an implementation
queue. The bounded `--fix` coordinator exception is defined below.

### Authority and freshness

The coordinator creates a fresh `run_id` and an expected-identity JSON before
freezing the change. It independently retains that file for the active workflow,
separate from the report and never reconstructed from report/history. The
expected identity comes from the live target:
`schema_version`, `run_id`, repository, PR number, full head SHA, full base
SHA, base branch, and committed tree. A report, PR comment, marker, historical
artifact, or current-session implementer cannot supply or replace it.

One active coordinator owns one gate invocation. An interruption, changed
head/base/tree, changed target, or missing expected file invalidates the run
and requires a fresh gate. Prior findings may be included as evidence only.
The report is workflow evidence, not a security boundary against a malicious
trusted coordinator or administrator.

### Bounded `--fix` coordinator

`co-review --fix` is a bounded coordinator mode around plain gates, not a
different gate, a `review.py` or `gate_report.py` flag, or a new shell helper.
An explicit user `co-review --fix` invocation authorizes its one scoped repair
batch; an already-authorized development controller may use the same bounded
handoff. A plain co-review or coworker review never grants edit authority. This
mode does not authorize publishing, merging, or changing the fixed blocker
threshold.

The coordinator starts from either a fresh initial plain gate or one current
finalized `CHANGES` report. It may reuse the latter only after revalidating the
active expected identity against the exact unchanged live repository, PR,
head, base, base branch, and committed tree, and confirming the retained report
still evaluates as `CHANGES`. Missing, stale, invalid, interrupted, or
incomplete evidence stops without edits. An initial `APPROVE` returns unchanged.

For an eligible `CHANGES` result, hand one batch of only its confirmed material
blockers to an implementer separate from the required read-only gate seats.
Keep advisory findings visible but do not edit for them. The repair packet names
each original finding's report/seat/ID, scenario, and concrete violated
contract. The implementer records self-review, relevant tests, and, where
executable, a behavioral regression showing the original failure and repaired
success; it also covers affected failure paths, including ownership or lifecycle
where relevant. Self-review is evidence only and never grants approval.

Obtain exactly one independent `review-change` review of that packet, repairs,
and affected contracts. It classifies each new blocker as repair-introduced,
previously missed, or changed requirements, with its concrete consequence.
Failed tests, incomplete or blocking development feedback, or a broad redesign
need returns the work to development. Repeated fix-induced blockers in one
subsystem require diagnosis of the common design contract, never a local patch
loop. The outer development orchestrator cannot reset an exhausted `--fix`
budget or re-enter the gate until that diagnosis and development evidence address
the stopping cause.

Only a complete, clean repair review permits one new full plain gate on the new
head, with a new run and expected identity and every known blocker supplied for
disposition. It retains full coverage and the fixed material threshold while
focusing investigation on repairs and affected contracts. Settled unchanged
advisories do not reopen as blockers without new material evidence. Its new
blockers classify as repair-introduced, previously missed, or changed
requirements, with a concrete consequence; fewer findings never reclassify one.
The new gate's `APPROVE`, `CHANGES`, or `INCOMPLETE` result stops the coordinator.
Repair feedback, stale artifacts, or the development review never substitutes
for that full gate or approves the PR. The mode therefore allows at most one
repair batch and at most two full gates, including a reused current `CHANGES`
gate; it never recursively invokes `--fix`.

Run each plain gate's finalization block as a separate subprocess. Capture its
structured evaluation and cleanup result before deciding what the coordinator
does next. A nonzero gate exit is evidence to inspect, not permission to
swallow an evaluator, verification, or cleanup error; malformed or missing
structured output is `INCOMPLETE`.

### Frozen inputs and report construction

Prepare one immutable snapshot with `review.py prepare`, then run
`review.py verify --manifest` before dispatch, before evaluation, and before
cleanup. Freeze a dirty source when requested, record its state, and make the
result incomplete unless the committed expected tree equals the frozen reviewed
tree. `manifest.source.source_tree` binds `expected.tree`; the verified
`manifest.snapshot.codex_tree` binds `report.reviewed_tree`. Capture the exact
frozen Git diff bytes without universal-newline normalization, then decode them
strictly and scan structural records only at LF. Capture the CI payload for the
expected head as a regular report artifact. Hash every artifact after it is
complete. Paths in the report are relative to the report file; artifacts must
not be symlinks.

Build the report only from actual seat output and the schema printed by
`gate_report.py schema`. Use its required `preconditions` object with the exact
head/tree, report-relative diff and CI artifacts/digests, and its optional
explicit no-CI evidence and exact marker exceptions. Omit optional fields unless
they apply. A skipped or neutral CI result is visible evidence, not proof that a
test ran. Missing or malformed evidence is incomplete.

Each marker exception is an exact `{file, line, text, kind, evidence, reason}`
record. `kind` is only `fixture_literal`, `documentation_example`, or
`detector_literal`; the latter applies only to the detector's own token
definition in its complete canonical form, never unfinished production code.
`evidence` and `reason` identify why that exact added line is allowed. No
path-wide, category-wide, or
undocumented marker exception is valid.

Normalize the live provider payload before hashing it as the CI artifact. It is
the strict envelope `{head, check_runs, status_contexts}`: `head` is the actual
full `headRefOid` returned by the provider, never a copied expected value. Both
arrays are required even when observed empty. Map GraphQL `statusCheckRollup`
nodes by type, preserving each check/context identity and its actual status,
conclusion or state; an optional `head_sha` on a record must be its returned
value. Capture both CheckRun and StatusContext records. An observed empty pair
may use explicit no-CI evidence. Unavailable or missing provider data is missing
evidence, not an empty success.

### Required independent seats

All four seats are fresh, read-only, independently completed runtime calls with
a 600-second bound. Record requested and observed runtime/model/effort; an
unknown observation remains `unknown`. Each seat artifact is nonempty,
SHA-256-bound, and records an actual completion. A narrated dispatch, a
controller opinion, or a current-session implementer does not fill a seat.

1. `claude`: fresh Claude reviewer route.
2. `codex`: fresh native Codex reviewer route. A Codex-led controller creates a
   native child; it never shells into a generic Codex CLI review path.
3. `breaker`: fresh skeptic route, independent of both finder reports.
4. `verifier`: fresh skeptic route after the first three reports exist. It
   receives those reports and every known blocker, but performs its own frozen
   evidence check.

Use the shared resolver for every seat. Preserve the original repository's
account route; a personal Claude route unsets `CLAUDE_CONFIG_DIR`. The first
three seats receive the frozen diff, relevant callers, repository conventions,
the declared threat model (default `exposed`), and this policy. The verifier additionally receives
the first-three artifacts and prior blockers. No seat invokes a generic
external review plugin, another partner, external actions, comments, fixes, or
merge actions.

Every seat uses the same adversarial method: trace affected call sites and
state transitions; try ordinary mistakes, interrupted operations, and retries;
seek an executable counterexample in the frozen tree; and identify evidence
gaps. A privileged sabotage scenario counts only when its actor is in the
declared threat model. Content contradictions are a threat-model gap, not a
silent pass. All probes use disposable fixtures and never live hardware or
production actions. Append the complete `## Classes` section from
`references/failure-classes.md` verbatim to every seat prompt. The class IDs in
the report record coverage; the appended class text supplies the required probe
descriptions.

### Findings, blockers, and coverage

Each finding has a stable ID, severity, disposition, concrete scenario, and
evidence. Allowed severities are `critical`, `high`, `major`, `minor`, `low`,
`nit`, and `advisory`. Confirmed `critical`, `high`, and `major` findings yield
`CHANGES`. Confirmed `minor`, `low`, `nit`, and `advisory` findings remain
visible but permit approval. Unknown severity, a disputed classification, or an
unresolved material allegation yields `INCOMPLETE`.

A refutation identifies frozen enforcement that disproves a necessary premise;
absence of a production occurrence, enumeration, naming, or lack of evidence
is not refutation. Each known blocker from the expected identity has an
evidenced `repaired`, `refuted`, or `still-open` disposition. A missing or
still-open material blocker prevents approval. There are no round counts,
severity floors, or automatic fix-and-repeat loops. A bounded repair check may
cover a repaired defect and its affected contracts; structural or scope change
requires a new full gate outside the bounded coordinator. Two successive
fix-induced blockers in one subsystem return work to development/design.

Coverage is separate from findings. Supply evidence or an explicit gap for each
architecture axis:

- `ownership_authority`
- `dependency_boundaries`
- `contract_coherence`
- `state_effects`
- `lifecycle_operations`
- `demonstrability_constraints`

Supply evidence or an explicit gap for each checklist item:

- `quoting_separators`
- `symlinks`
- `content_filters`
- `hostile_git_config`
- `signals_toctou`
- `temp_dir_lifecycle`
- `fail_open_exits`
- `ignored_untracked_overwrites`
- `fetch_ref_races`
- `replayable_file_authority`
- `resume_retry_revalidation`
- `writer_reader_parity`
- `functional_behavior`
- `snapshot_integrity`
- `preconditions_ci`
- `threat_model`

A material gap yields `INCOMPLETE`. A nonmaterial gap needs the schema's exact
`accepted_by` field naming a human who accepted it; no reviewer can accept its
own gap. It remains visible and does not become an unqualified assertion. A
mechanical defect in these
repository review tools needs an executable regression, or the report records
visible unfixed coverage; prose alone cannot discharge it.

| Axis | Required review question | Blocking example |
| --- | --- | --- |
| `ownership_authority` | Does one stated authority own each approval, mutation, and cleanup decision? | Two services can issue the same payment after a retry because neither exclusively owns the effect. |
| `dependency_boundaries` | Do callers cross declared adapters and validation boundaries rather than bypassing them? | A new endpoint bypasses the authorization boundary and exposes another tenant's record. |
| `contract_coherence` | Do producer, schema, evaluator, and consumer agree on identity, fields, and failure meanings? | A producer emits a schema version or enum that an existing consumer rejects, breaking deployed clients. |
| `state_effects` | Are partial state, interruption, retry, and changed inputs represented and revalidated? | A timeout after a successful write retries without idempotency and duplicates the external effect. |
| `lifecycle_operations` | Are rollout, upgrade, rollback, cleanup, capacity, and failure exits ordered and bounded? | A mixed-version rollout writes data the rollback version cannot read, or an unbounded queue exhausts worker resources. |
| `demonstrability_constraints` | Can the stated behavior be exercised under the repository's real limits and tests? | A review-tool guard changes behavior without an executable regression, leaving the defect unproven. |

An architecture finding blocks only when it cites the applicable required
contract and a material consequence like these. A loud failure may block.
Naming, taste, speculative extension, and unaffected pre-existing debt do not.

### Evaluation and cleanup

Verify the frozen snapshot, invoke `gate_report.py evaluate --report REPORT
--expected EXPECTED`, and retain the emitted verdict and reasons with the
active workflow. Only `APPROVE` permits the workflow to present a merge-ready
result. `CHANGES` returns concrete blockers to development. `INCOMPLETE`
states missing or invalid evidence. Human risk acceptance and required human
approvals remain separate from this verdict.

After all seats and evaluation finish, run `review.py cleanup --manifest`. If
verification or cleanup refuses, preserve the report artifacts, invalidate the
coordinator-owned expected identity, and report the failure; never delete a
foreign or changed snapshot. Consumers accept only a successfully finalized
active gate, so a cleanup-failed report cannot be re-evaluated into approval.
<!-- gate-policy:end -->
