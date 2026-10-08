# Gated posts (SKILL.md section 4)

## Gated posts (section 4, Decisions log)

A gated post (a review, a thread reply, a comment on another author's PR, a
body that mentions someone, a Jira comment) is asked the same way.

1. Register it first with `python3 ~/.claude/hooks/pr_post_guard.py draft --
gh <args>`. A Jira comment has no draft.
2. Ask one single-select question per draft, at most four per prompt. Put the
   full draft text in the question; an option preview is clipped by the
   terminal, so it never counts.
3. The options are `Post draft <hash>` and `Skip draft <hash>`. The
   recommended one comes first, with ` (Recommended)`.

The answer is the go. A PostToolUse hook approves exactly the draft the
chosen option names, and only when its text was in that question
and the draft text and that question are each at most 2000 characters, the
most a prompt displays.
It prints a `post gate:` line for each decision. A typed message never
approves a post, so never ask the owner to type one. Without the tool, a
gated post cannot be approved; leave the draft in the report.

Answers are not stored. An answer authorizes the action it names in the same
turn. After any interruption (a crash, `/clear`, compaction, a resume),
re-derive the state from live sources and ask again: the PR's state and head,
the worktree and branch, the Jira issue, and a draft's state file. Only an
approved draft outlives the turn. It stays approved until it is posted,
withdrawn with `Skip draft <hash>`, or pruned 24 hours later.

When a `Post draft <hash>` answer prints no `post gate:` line, the answer hook
is not active in this session. Do not ask again. Try the post once. If the
shim refuses it, tell the owner to run `update --ai` and restart Claude, and
leave the draft in the report.
