# /afk - Queue owner questions while away

Turn on herdr away mode: the director queues owner questions instead of opening prompts.

## Instructions

Read `claude/skills/herdr-orchestration/references/away-mode.md` (or the same
path under `~/.claude/skills/herdr-orchestration/references/`), then run
`away --on` as it states. Print the `away:` line. Do not call `AskUserQuestion`
until `/back` or the owner's next chat message.
