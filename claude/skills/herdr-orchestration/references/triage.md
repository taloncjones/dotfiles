# Triage (SKILL.md section 3)

## 3. Triage (advisory only -- read-only)

Creates no task/worktree/agent/index/record.

1. Inputs: Jira active sprint (JQL) plus repo epic(s) from `config.epics`,
   plus open todos. Exclude anything already an active task.
2. Deterministic ranking: in-sprint (Jira priority, then key ascending) ->
   epic backlog order (the epic's child order) -> todos (by todo id). Ties
   break by `task_id`.
3. Missing data: no sprint -> fall back to epic backlog; Jira unreachable ->
   todos only, and say so.
4. Report the ranked list. If the eligible count exceeds `config.soft_cap`,
   note it -- advisory only, never a hard cap.

**Escalation.** Ambiguous triage is one of the named deep-think triggers
(section 8, Deep-think escalation): the human asks for a judgment call
("which should we do first and why", conflicting priorities), or the
deterministic ranking above has no usable inputs (Jira unreachable AND more
eligible todos than `config.soft_cap`). The director may launch one
bounded think escalation (kind `triage`) per turn through the selected runtime
path in section 8; `run-think` is the legacy Claude wrapper only. A second eligible trigger
in the same turn is reported as "escalation deferred: already launched this
turn". The answer is advisory data only -- it reorders or annotates the
ranked list above; this section stays read-only, so nothing here ever
creates a task/worktree/agent/index/record off an escalation's answer.
