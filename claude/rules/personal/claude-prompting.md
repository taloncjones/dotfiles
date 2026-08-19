# Claude Prompting

Always-on facts that shape prompts, skills, and subagent dispatches. Everything
else -- cross-model behaviors, per-model deltas, the retirement playbook --
lives in the on-demand `model-tuning` skill; deep API mechanics in `claude-api`.

- **Effort is the primary lever** for intelligence vs latency/cost. Prefer
  raising effort over "think harder" prose; `low`/`medium` are respected
  strictly. Verbose output is often an effort artifact, not an instruction gap.
- **Literal instruction following.** Current models do not generalize an
  instruction across items or infer unrequested work -- state scope explicitly
  ("every section, not just the first").
- **Steer with positive examples** ("communicate like X"), not "don't do Y"
  lists. Verbosity self-calibrates to task complexity; keep concise-by-default
  guidance and correct the shape only when it is off.
