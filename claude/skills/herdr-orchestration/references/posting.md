# Gated posts (SKILL.md section 4)

## Gated posts (section 4, Decisions log)

A gated post (a review, a thread reply, a comment on another author's PR, a
body that mentions someone, a Jira comment) is asked the same way.

1. Register it first with `python3 ~/.claude/hooks/pr_post_guard.py draft --
gh <args>`. A Jira comment has no draft.
2. Ask one single-select question per draft, at most four per prompt. Put the
   full draft text in the question; an option preview is clipped by the
   terminal, so it never counts.
3. Write each option so it reads as the action and ends with `(draft <hash>)`
   for a post or `(skip draft <hash>)` for a skip: a post option such as `Post the closing comment on PR #1
   (draft 9cb85c49)`, a skip option such as `Leave PR #1 open (skip draft
   9cb85c49)`. The recommended one comes first, with ` (Recommended)`.
   The verb rule: a label is a post when its leading word (followed by a space) or the
   word before `draft <hash>` is `post`, and a skip when that word is `skip`. A `skip`
   elsewhere in the label does not count. A label with neither verb, both
   verbs, a negation (`not`, `no`, `never`, `nothing`, `without`, `cannot`, `n't`), or two hashes is ambiguous
   and never decides. The legacy labels
   `Post draft <hash>` and `Skip draft <hash>` still work.

A PreToolUse hook refuses the prompt before the owner sees it when a
post option names an unregistered draft or one whose text is
not in the question, or when an option label is ambiguous, and prints the fix.

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
withdrawn with the skip option, or pruned 24 hours later.

When a post answer prints no `post gate:` line, the answer hook
is not active in this session. Do not ask again. Try the post once. If the
shim refuses it, tell the owner to run `update --ai` and restart Claude, and
leave the draft in the report.
