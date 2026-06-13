# /start - Start new work

Begin work on a new task with optional Jira integration and worktree creation.

## Usage

- `/start <topic>` - Create worktree with topic name (no Jira)
- `/start PROJ-123` - Start work on existing Jira ticket (requires Atlassian plugin)
- `/start` - Interactive: ask for topic or search Jira tickets

## Examples

```
/start feature-tests
/start PROJ-123
/start
```

## Instructions

**Step 1: Check for Atlassian plugin**

Try calling `getAccessibleAtlassianResources`:

- If successful: Jira integration is available, store site URL and cloud ID
- If fails or no sites returned: Jira not available, proceed without it

**Step 2: Determine task**

If argument looks like a Jira key (e.g., `PROJ-123`, `PROJ-456`) AND Jira is available:

- Fetch the ticket details using `getJiraIssue`
- Show ticket summary and status for confirmation
- Extract topic from ticket summary

If argument looks like a Jira key but Jira is NOT available:

- Warn: "Jira plugin not available. Use `/start <topic>` instead."
- Stop

If argument is free text (topic):

- Use it as the topic slug directly
- If Jira available, optionally ask: "Link to a Jira ticket?" (default: no)

If no argument (interactive):

- If Jira available, ask: "Link to a Jira ticket?"
  - **Yes**: Offer options:
    - Pick from open tickets (To Do, In Progress) assigned to user
    - Enter a ticket key directly
    - Create a new ticket
  - **No**: Ask for topic name only, proceed without Jira
- If Jira not available: Ask for topic name for the branch

**Creating a new Jira ticket:**

When creating a new ticket, use conversation context to propose a title and description:

1. Review recent conversation for task details, feature names, or technical specs
2. Generate a proposed title (concise, <80 chars) and description (bullet points)
3. Present them for confirmation:

   ```
   Proposed Jira ticket:
   Title: <proposed title>
   Description:
   <proposed description>

   Create this ticket? [Yes / Edit title / Edit description / Cancel]
   ```

4. If user provides topic text with `/start <topic>`, use that as the basis for the title
5. Only ask open-ended "What should the title be?" if there's no context to work from

**Step 3: Check for existing worktree**

Check if a worktree already exists for this topic/ticket:

```bash
git worktree list | grep -i "<topic-or-jira-key>"
```

If found, run `/switch <match>` instead of creating a duplicate.

**Step 4: Transition, assign, and add to sprint (Jira only)**

If Jira ticket is linked:

1. **Transition to "In Progress"** (if not already):
   - Get available transitions via `getTransitionsForJiraIssue`
   - Find the "In Progress" transition and apply via `transitionJiraIssue`

2. **Assign to current user**:
   - Get user account ID via `atlassianUserInfo`
   - Update assignee via `editJiraIssue`

3. **Move to current sprint**:
   - Find the active sprint by copying from the user's own recent tickets, not a project-wide search (different teams run different boards, so `project = X AND sprint in openSprints()` can return the wrong board's sprint):
     ```
     JQL: assignee = currentUser() AND sprint in openSprints() ORDER BY updated DESC
     Fields: ["summary", "customfield_10020"]  # customfield_10020 is typically the sprint field
     ```
   - From the first result, take the sprint entry with `state == "active"` and extract its integer sprint ID
   - If active sprint found, update the issue:
     ```
     editJiraIssue(issueIdOrKey, fields: {"customfield_10020": <sprint_id>})
     ```
   - If no active sprint found, skip silently (issue stays in backlog)

**Step 5: Generate branch name**

With Jira: `<user>/<PROJ-###>/<topic-slug>`
Without Jira: `<user>/<topic-slug>`

- User: extract from git config `user.email` (part before @), lowercase
- Topic: slugified (lowercase, hyphens, max 40 chars, remove filler words)

Examples:

- With Jira: `talon/PROJ-123/add-widget`
- Without Jira: `talon/feature-tests`

**Step 6: Create worktree and switch to it**

```bash
git fetch origin

# Determine default branch
DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | grep "HEAD branch" | cut -d: -f2 | xargs)
if [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH="main"
fi

# Determine repo name for folder prefix
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")

# Determine folder name using naming convention:
#   With Jira: <repo>-<PROJ-N>-<topic-slug> (e.g., myapp-PROJ-123-add-widget)
#   Without Jira: <repo>-<topic-slug> (e.g., myapp-feature-tests)
if [ -n "$JIRA_KEY" ]; then
    FOLDER_NAME="${REPO_NAME}-${JIRA_KEY}-${TOPIC_SLUG}"
else
    FOLDER_NAME="${REPO_NAME}-${TOPIC_SLUG}"
fi
WORKTREE_PATH="../$FOLDER_NAME"
git worktree add --track -b "$BRANCH_NAME" "$WORKTREE_PATH" "origin/$DEFAULT_BRANCH"

# Switch to the new worktree
cd "$WORKTREE_PATH"
```

**Step 7: Scope the work before coding**

Default to plan-then-code — do not jump straight to implementation.

1. **Design pass check.** Read the ticket description and comments (including carry-over findings triaged from prior tickets). Run a short brainstorm (superpowers:brainstorming) and write a plan (superpowers:writing-plans) BEFORE implementing if the ticket involves any of:
   - an interface or contract that later tickets will build on (wire formats, schemas, shared APIs, subprocess pipe handling)
   - a security/auth model (what is open vs. token-gated)
   - a multi-component skeleton that future work extends

   Small single-concern fixes skip the design pass and go straight to implementation.

2. **Submodule split check.** If any of the work lands in a git submodule (e.g., a shared test-infra submodule), plan two PRs: the submodule PR first, then the parent-repo PR bumping the submodule pointer. Call this out in the plan and in the report below.

**Step 8: Report**

With Jira:

```
Started work on PROJ-123: <ticket summary>

Worktree: ../<repo>-<PROJ-N>-<topic-slug>
Branch:   <user>/PROJ-123/<topic-slug>
Jira:     https://<site>.atlassian.net/browse/PROJ-123
Status:   In Progress
Sprint:   <sprint name> (or "Backlog" if not in a sprint)

Ready to begin.
```

Without Jira:

```
Started work: <topic>

Worktree: ../<repo>-<topic-slug>
Branch:   <user>/<topic-slug>

Ready to begin.
```

---

Related commands:

- `/jira mine` - list tickets to pick from (if Jira configured)
- `/status` - check current work status
- `/pr` - create pull request when done
