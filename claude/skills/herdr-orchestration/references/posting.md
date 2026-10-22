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
   The verb rule: a post label starts with `Post` followed by a space, or with `(` then
   `Post`; a pinned approving review starts with `Approve` and a request-changes review
   with `Request changes` (next section). The verb must name the event the draft
   carries: a `Post` label never approves a review draft, and an `Approve` label never
   approves a comment draft. Any other leading word before `post draft <hash>` (`Hold off on`, `Cancel`,
   `Decline to`, `Maybe`) is a refusal. `Post:`, `Post,` and `Post` plus a dash fail the
   space rule. A skip is a leading `Skip` or `skip draft <hash>`. A `skip` elsewhere
   in the label does not count. A post label that carries a negation (`not`, `no`, `never`, `nothing`, `without`,
   `n't`) or a hedge (`if`, `unless`, `after`, `until`, `later`, `wait`, `hold`, `or`,
   `maybe`, `but`, `only`, `again`, `for now`, a `?`, a dash aside) is ambiguous too.
   A label with neither verb, both verbs, a
   non-`Post` lead before `post draft`, or two hashes is ambiguous and never
   decides. The legacy labels
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

## Review events on another author's PR

When a co-review finishes on a PR this account did not author, in a work or
personal repository, the owner can leave a GitHub review whose event matches
the verdict instead of a plain comment. `gh pr review --approve` approves
whatever head is live when it runs, so the draft guard refuses it; the review
goes through the reviews API with the gated head pinned.

Before the prompt, read the live head and this account's reviews:

```bash
LIVE=$(gh pr view "$PR" --repo "$PR_REPO" --json headRefOid --jq .headRefOid)
ME=$(gh api user --jq .login)
gh api --paginate "repos/$PR_REPO/pulls/$PR/reviews" --jq '.[] | select(.user.login == "'"$ME"'" and .commit_id == "'"$LIVE"'") | .state'
```

Offer an event option only when `$LIVE` equals the gated head and the query
lists no `APPROVED` row (APPROVE verdict) or `CHANGES_REQUESTED` row (CHANGES
verdict). Otherwise ask as for any comment: the comment draft and a skip option.

Register two drafts with the same body file, the comment and the review:

```bash
python3 ~/.claude/hooks/pr_post_guard.py draft -- gh pr comment "$PR" --repo "$PR_REPO" --body-file "$RUN_DIR/marker.md"
python3 ~/.claude/hooks/pr_post_guard.py draft -- gh api -X POST "repos/$PR_REPO/pulls/$PR/reviews" -f commit_id=<gated head> -f event=APPROVE -F body=@"$RUN_DIR/marker.md"
```

Use `event=REQUEST_CHANGES` for a CHANGES verdict. Registration refuses any
other approving or request-changes shape: `gh pr review --approve`, graphql,
the pending-review events path, or a `commit_id` that is not 40 hex characters.

Ask one single-select question with the body in it. `<head7>` is the first
seven characters of the gated head (an eight-character id reads as a second
draft hash). Options for an APPROVE verdict, in order:

1. `Approve #<n> at <head7> with this text (draft <review hash>)`, with ` (Recommended)`
2. `Post as a comment on #<n> (draft <comment hash>)`
3. `Hold the review on #<n>`

Options for a CHANGES verdict, in order:

1. `Post as a comment on #<n> (draft <comment hash>)`, with ` (Recommended)`
2. `Request changes on #<n> at <head7> with this text (draft <review hash>)`
3. `Hold the review on #<n>`

The request-changes option's description says it blocks the PR's merge until
the review is dismissed; the label cannot, because the hedge rule refuses
`until`. The hold option names no draft: both drafts stay pending and are
pruned after 24 hours.

Choosing an option approves its draft and dismisses the other one; the guard
allows one question to name two drafts only when their recorded texts are equal.

Run the approved draft's exact argv. The gh shim reads the live head again at
that moment and refuses the call when it differs from `commit_id`; the draft
stays approved. Re-gate the new head and register new drafts; do not retry the
old one.

If the review call fails after the shim let it through, read the reviews query
above with `$ME` and the gated head. Register and ask again only when it lists
no row for the event. If registering the second draft fails, run that
registration again; it is idempotent by digest.

A posted review is not a marker comment: skip the supersede step.
