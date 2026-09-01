# Agent Lessons

Distilled from recurring agent failures at merge time (/post-merge lessons
step). Contract: max 20 rule bullets; file stays at or under 45 physical
lines. At cap, adding a rule means dropping or merging one in the same
edit. Entry format: "- (YYYY-MM) <imperative rule>", one bullet, wrapped
at 80 columns, two physical lines max. Admission filter (all must hold):
agent-process failure, not a code bug; recurring or clearly repeatable;
not already covered by CLAUDE.md, operating-principles.md, or a hook;
public-safe (no employer, internal-system, or customer specifics --
generalize or reject). Candidates passing the filter are then routed:
hookable ones become dotfiles hook todos, not rules; the rest land here.
Staleness: entries dated 6+ calendar months before the current month are
prune candidates at the next edit -- prune, keep-and-redate, or file a
graduation todo to move the rule into operating-principles.md. This file
is the staging tier, not an archive.

## Rules

- (2026-09) Non-interactive shells: set CLAUDE_CONFIG_DIR explicitly and
  call the real claude binary; the zsh claude() wrapper assumes an
  interactive shell for account routing and fails auth without it.
