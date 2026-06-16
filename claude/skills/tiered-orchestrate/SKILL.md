---
name: tiered-orchestrate
description: Use for substantial multi-step implementation tasks (3+ distinct subtasks touching multiple files) when the session's standing orchestration rule directs you here. Authors a per-task Workflow script with tiered model routing - the configured planner model plans and reviews, sonnet implements, haiku reads and writes docs.
---

# Tiered Model Orchestration

Author a Workflow script for the task at hand following the policy below.
This skill's instructions are the authorization to call the Workflow tool
for the current task. The planner model comes from the session's standing
rule (injected by the tiered_orchestrator.py SessionStart hook from
claude/orchestrator.conf); call it PLANNER below.

## Tier policy (fixed - do not reassign)

| Role                | Model                        | Does                                                               |
| ------------------- | ---------------------------- | ------------------------------------------------------------------ |
| Planner / reviewer  | PLANNER (from standing rule) | Decompose the task, set acceptance criteria, review verified diffs |
| Implementer         | sonnet                       | All code writes                                                    |
| Reader / doc writer | haiku                        | Read-only recon, codebase mapping, documentation files             |

If the standing rule reported the conf invalid or orchestration disabled,
do not orchestrate; tell the user to fix claude/orchestrator.conf.

If a PLANNER agent() call fails at runtime because the configured model is
unavailable (e.g. fable retired before the conf was flipped), stop the
workflow and report: "planner model X unavailable - flip PLANNER_MODEL in
claude/orchestrator.conf". Offer to re-run this one orchestration with
opus. Never edit the conf yourself and never swap models silently.

## Hard rules

- Depth is one: the script never calls workflow(), and no agent prompt may
  instruct an agent to invoke Workflow or spawn sub-orchestration.
- Max 8 concurrent workers. If the plan wants more, batch sequentially.
- Stop and report to the user if execution grows beyond the planned task
  list instead of improvising new agents.
- Parallel implementation tasks must have disjoint file scopes (the
  planner assigns them). Use isolation: 'worktree' only when independent
  tasks write in parallel; merge worker branches sequentially in the main
  session afterward and stop on any conflict.
- A failed task blocks every task that depends on it. Never report the
  overall job as implemented when any task failed - list what completed
  and what did not.

## Canonical script shape

Adapt the skeleton; keep phases, schemas, model assignments, and bounded
rework. Single-task jobs may skip recon and run one worker inline.

```js
export const meta = {
  name: "tiered-<task-slug>",
  description: "<one line>",
  phases: [
    { title: "Recon" },
    { title: "Plan" },
    { title: "Implement" },
    { title: "Verify" },
    { title: "Review" },
  ],
};

const PLANNER = "<model from standing rule>";
const MAX_WORKERS = 8;
// Derive from the task: the subsystems/directories worth mapping
// before planning. Drop recon entirely for small or familiar areas.
const RECON_AREAS = ["<area-1>", "<area-2>"];

const PLAN_SCHEMA = {
  type: "object",
  required: ["tasks"],
  properties: {
    tasks: {
      type: "array",
      items: {
        type: "object",
        required: ["id", "scope", "files", "acceptance", "dependsOn", "kind"],
        properties: {
          id: { type: "string" },
          scope: { type: "string" },
          files: { type: "array", items: { type: "string" } },
          acceptance: { type: "array", items: { type: "string" } },
          dependsOn: { type: "array", items: { type: "string" } },
          kind: { enum: ["code", "docs"] },
        },
      },
    },
  },
};

const VERDICT_SCHEMA = {
  type: "object",
  required: ["approved", "feedback"],
  properties: {
    approved: { type: "boolean" },
    feedback: { type: "string" },
  },
};

// Implement returns its worktree path so verification runs in the SAME tree.
// Under parallel isolation each code worker writes in its own worktree; checks
// must run there, not the orchestrator checkout, or they verify the wrong code.
const IMPL_SCHEMA = {
  type: "object",
  required: ["report", "worktreePath"],
  properties: {
    report: { type: "string" },
    worktreePath: { type: "string" },
  },
};

phase("Recon");
const recon = await parallel(
  RECON_AREAS.map(
    (a) => () =>
      agent(`Read-only: map ${a} relevant to: <task>. Return findings.`, {
        model: "haiku",
        phase: "Recon",
      }),
  ),
);

phase("Plan");
const plan = await agent(
  `Decompose this task into implementation tasks with disjoint file scopes,
   acceptance criteria, and dependencies. Task: <task>.
   Recon: ${JSON.stringify(recon.filter(Boolean))}`,
  { model: PLANNER, schema: PLAN_SCHEMA },
);

// Schedule waves: a task runs only after every dependsOn was APPROVED.
// Unapproved outcomes (agent death, rework exhaustion) block dependents.
const done = {};
const needsHuman = [];
const failed = new Set();
let remaining = plan.tasks;
while (remaining.length > 0) {
  const ready = remaining.filter(
    (t) =>
      t.dependsOn.every((d) => done[d]) &&
      !t.dependsOn.some((d) => failed.has(d)),
  );
  const blocked = remaining.filter((t) =>
    t.dependsOn.some((d) => failed.has(d)),
  );
  blocked.forEach((t) => failed.add(t.id));
  remaining = remaining.filter(
    (t) => !ready.includes(t) && !blocked.includes(t),
  );
  if (ready.length === 0) break;

  // Honor MAX_WORKERS: run each wave in batches of at most 8.
  for (let i = 0; i < ready.length; i += MAX_WORKERS) {
    const batch = ready.slice(i, i + MAX_WORKERS);
    // Worktree isolation only when this batch writes code in parallel.
    const parallelWrite = batch.filter((t) => t.kind === "code").length > 1;
    const results = await parallel(
      batch.map((t) => () => runTask(t, parallelWrite)),
    );
    batch.forEach((t, j) => {
      const r = results[j];
      if (r && !r.needsHuman) {
        done[t.id] = r;
      } else {
        if (r) needsHuman.push(r);
        failed.add(t.id); // blocks dependents either way
      }
    });
  }
}

async function runTask(t, parallelWrite) {
  const model = t.kind === "docs" ? "haiku" : "sonnet";
  const iso =
    t.kind === "code" && parallelWrite ? { isolation: "worktree" } : {};
  let feedback = "";
  for (let round = 0; round <= 2; round++) {
    const impl = await agent(
      `Capture your absolute worktree path (run 'pwd') and return it as
       worktreePath. Implement: ${t.scope}. Files: ${t.files.join(", ")}.
       Acceptance: ${t.acceptance.join("; ")}. ${feedback}
       Then run the repo's tests/lint/typecheck on what you changed and
       report results in the report field.
       Do not invoke Workflow or orchestrate sub-agents.`,
      { model, phase: "Implement", schema: IMPL_SCHEMA, ...iso },
    );
    if (!impl) return null;
    // Capture each round's worktree -- an isolated rework round runs in a fresh
    // worktree, so verification must target THIS round's tree, not round 0's.
    const worktree = impl.worktreePath;
    const verify = await agent(
      `In worktree ${worktree}: run the repo's checks (tests, lint, typecheck)
       for ${t.files.join(", ")}. Report pass/fail with output. Read-only plus
       running checks.`,
      { model: "sonnet", phase: "Verify" },
    );
    const verdict = await agent(
      `Review against plan. Scope: ${t.scope}.
       Acceptance: ${t.acceptance.join("; ")}.
       Implementation report: ${impl.report}
       Verification: ${verify}
       Approve only if acceptance is met AND verification passed.`,
      { model: PLANNER, phase: "Review", schema: VERDICT_SCHEMA },
    );
    if (verdict.approved) return { task: t.id, report: impl.report };
    feedback = `Reviewer feedback (round ${round + 1}): ${verdict.feedback}.`;
  }
  return { task: t.id, needsHuman: true, feedback };
}

return {
  completed: Object.values(done),
  needsHuman,
  failed: [...failed].filter((id) => !needsHuman.some((r) => r.task === id)),
};
```

## Synthesis (after the workflow returns)

Report to the user: what completed, verification results, tasks marked
needsHuman with the reviewer's outstanding feedback, and tasks failed or
blocked. Merge any worktree branches sequentially; stop and surface
conflicts. The report must distinguish complete from incomplete outcomes.
