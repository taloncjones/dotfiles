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
Failed tests, incomplete or blocking repair feedback, or a broad redesign need
stops the entire calling workflow and returns control to the user. Diagnosis
may explain the failure; it does not authorize another repair/review cycle.
The allowance belongs to the original task, across development, shipping,
review, resumed sessions, and handoffs. Record an exhausted allowance in the
existing task/handoff record. A new head, run ID, session, or a return to
"development" never resets it. Only a new explicit user instruction after the
stop may authorize another cycle; standing implementation/merge authorization
is not that instruction.

Only a complete, clean repair review permits one follow-up verification on the
new head, with a fresh expected identity and every known blocker supplied for
disposition. The seats of the follow-up report's own class inspect the repair delta and affected
contracts; they do not repeat the initial unrestricted search. Follow-up
coverage is assembled as described below. New material evidence may invalidate
carried coverage, but fewer findings never change severity. Classify a new
blocker as repair-introduced, previously missed, or changed requirements.
Every follow-up outcome stops the coordinator and its outer caller. A material
scope change or invalidated baseline requiring a full new review also stops;
do not launch that review automatically. The mode permits one repair batch
and one follow-up after the initial gate, including a reused current CHANGES
result. It never recursively invokes --fix.

### Follow-up evidence

Retain the successfully finalized initial report and its actual seat artifacts
as hashed, report-relative evidence in the active workflow. They supply prior
coverage, never authority to approve the new head. Freeze and verify the new
head normally; obtain fresh CI, current seat reports for its class, and a current
expected identity. An interrupted workflow cannot reconstruct its authority
from an old report.

The follow-up packet includes the initial report/artifact digests, exact prior
head/base/tree, the repair delta, changed-symbol callers and repair evidence.
Assign each coverage entry one of two evidenced treatments in its existing
coverage string:

- Rechecked: name the repair or affected contract, fresh probe/inspection, and
  current seat evidence.
- Carried: cite the prior report path/digest and entry, the unchanged contract,
  and the current comparison showing the repair and its callers do not affect
  it. Match repository, base, requirements and threat model as well as code.

Never carry an unresolved gap or blocker as completed coverage. An unchanged
filename alone proves nothing about dependencies or behavior. Where the delta
invalidates prior evidence, recheck the affected contract. Opaque diff output
is not evidence that a file is unchanged: inspect the frozen file/tree and
record missing inspection as a coverage gap. No token scanner decides this.

The finder seats receive the same prior baseline independently and report
fresh evidence for their affected scope, plus any invalidated carried entry.
The verifier checks material claims, prior blocker dispositions, and the
combined coverage ledger. It reconciles those claims instead of starting an
unrestricted fourth search. Retain every architecture/checklist entry in the
final report, but do not require every seat to repeat all unchanged probes.

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
frozen Git diff bytes without universal-newline normalization. Capture the CI
payload for the expected head as a regular report artifact. Hash every artifact
after it is complete. Paths in the report are relative to the report file; artifacts must
not be symlinks.

Build the report only from actual seat output and the schema printed by
`gate_report.py schema`. Use its required `preconditions` object with the exact
head/tree, report-relative diff and CI artifacts/digests, and its optional
explicit no-CI evidence. Omit optional fields unless they apply. A skipped or
neutral CI result is visible evidence, not proof that a test ran. Missing or malformed evidence is incomplete.

Comments or strings containing TODO, TEMP, FIXME or similar tokens do not
block approval by themselves. Reviewers inspect unfinished behavior and report
its concrete impact. There is no mandatory token scan or marker exception
ledger. The frozen diff remains a hashed review artifact; opaque source changes
must still be accounted for in review coverage.

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

The seat set follows the change class (`scripts/change_class.py`; `co-review
--full` forces full). The full tier runs four seats: `claude`, `codex`,
`breaker`, `verifier`. The light tier runs `codex` and `verifier`, one Codex
and one Claude runtime, for a diff whose every path is Markdown or `.todos/`
outside the gate skills. Every seat is fresh, read-only, independently
completed runtime calls with a 600-second bound. Record requested and
observed runtime/model/effort; an
unknown observation remains `unknown`. Each seat artifact is nonempty,
SHA-256-bound, and records an actual completion. A narrated dispatch, a
controller opinion, or a current-session implementer does not fill a seat.

1. `claude`: fresh Claude reviewer route.
2. `codex`: fresh native Codex reviewer route. A Codex-led controller creates a
   native child; it never shells into a generic Codex CLI review path.
3. `breaker`: fresh skeptic route, independent of both finder reports.
4. `verifier`: fresh skeptic route after every finder report exists (three in
   the full tier, the `codex` report in the light tier). It receives those
   reports and every known blocker, but performs its own frozen evidence
   check.

Use the shared resolver for every seat. Preserve the original repository's
account route; a personal Claude route unsets `CLAUDE_CONFIG_DIR`. The finder
seats receive the frozen diff, relevant callers, repository conventions,
the declared threat model (default `exposed`), and this policy. The verifier additionally receives
the finder artifacts and prior blockers. Every prompt permits relevant
reference skills for language, security, framework and architecture guidance.
That guidance does not override the review
scope, material-impact threshold or read-only authority. Reviewers perform the
review themselves; they do not launch another review workflow, delegate
reviewers, modify code, publish findings or merge. A skill that would perform
those actions may be read as reference, but its workflow must not be executed.

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
evidence. A confirmed or unresolved critical/high/major allegation also needs
an explicit `impact`: the concrete effect on correctness, security, data,
ownership, lifecycle, or necessary integration, with a supported scenario.
A rule violation, missing preferred pattern, or token by itself does not
establish material impact, including rules written for this review tooling.
The verifier checks the consequence and may record a justified severity
correction; code validates that material allegations include impact, not its
truth. Do not label an impact-free allegation major to force a stop; classify
nonmaterial feedback as advisory. Unknown material impact remains a gap only
when evidence supports a concrete material-risk scenario.
Allowed severities are `critical`, `high`, `major`, `minor`, `low`,
`nit`, and `advisory`. Confirmed `critical`, `high`, and `major` findings yield
`CHANGES`. Confirmed `minor`, `low`, `nit`, and `advisory` findings remain
visible but permit approval. Unknown severity, a disputed classification, or an
unresolved material allegation yields `INCOMPLETE`.

A refutation identifies frozen enforcement that disproves a necessary premise;
absence of a production occurrence, enumeration, naming, or lack of evidence
is not refutation. An explicitly approved requirement change may also make a
prior finding inapplicable: record it as refuted with the decision, current
contract and evidence that no material consequence remains. Do not describe
the removed requirement as repaired or silently drop its prior finding. Each known blocker from the expected identity has an
evidenced `repaired`, `refuted`, or `still-open` disposition. A missing or
still-open material blocker prevents approval. There are no round counts,
severity floors, or automatic fix-and-repeat loops. Follow-up verification
covers repairs and affected contracts using the prior coverage rules above.
Structural or scope changes requiring a new full review stop for a user decision; they do not escape the original workflow allowance.

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
own gap. It remains visible and does not become an unqualified assertion.
A mechanical defect in these repository review tools needs an executable
regression, or the report records it unfixed; prose alone cannot discharge it.
Removing an unnecessary requirement is a design change: remove its executable
policy and obsolete tests together, and test the retained behavior. Do not
claim a deleted requirement was repaired or that caller instructions enforce
a runtime state machine.

| Axis                          | Required review question                                                                      | Blocking example                                                                                                       |
| ----------------------------- | --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `ownership_authority`         | Does one stated authority own each approval, mutation, and cleanup decision?                  | Two services can issue the same payment after a retry because neither exclusively owns the effect.                     |
| `dependency_boundaries`       | Do callers cross declared adapters and validation boundaries rather than bypassing them?      | A new endpoint bypasses the authorization boundary and exposes another tenant's record.                                |
| `contract_coherence`          | Do producer, schema, evaluator, and consumer agree on identity, fields, and failure meanings? | A producer emits a schema version or enum that an existing consumer rejects, breaking deployed clients.                |
| `state_effects`               | Are partial state, interruption, retry, and changed inputs represented and revalidated?       | A timeout after a successful write retries without idempotency and duplicates the external effect.                     |
| `lifecycle_operations`        | Are rollout, upgrade, rollback, cleanup, capacity, and failure exits ordered and bounded?     | A mixed-version rollout writes data the rollback version cannot read, or an unbounded queue exhausts worker resources. |
| `demonstrability_constraints` | Can the stated behavior be exercised under the repository's real limits and tests?            | A changed protocol cannot interoperate with deployed peers and drops required messages under supported conditions.     |

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
