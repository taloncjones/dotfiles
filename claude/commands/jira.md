# /jira - Interact with linked Jira ticket

Manage the Jira ticket associated with the current branch, or view your tickets.

Requires Atlassian plugin to be configured.

## Usage

- `/jira` - Show current ticket details
- `/jira mine` - List tickets assigned to me (grouped by sprint)
- `/jira sprint` - Show current sprint board
- `/jira comment <text>` - Add a comment to the ticket
- `/jira todo` - Transition ticket to To Do
- `/jira progress` - Transition ticket to In Progress
- `/jira done` - Transition ticket to Done
- `/jira open` - Open ticket in browser
- `/jira assign <user>` - Assign ticket to user (search by name)

## Examples

```
/jira
/jira mine
/jira sprint
/jira comment "blocked waiting for hardware"
/jira comment "WIP: unit tests passing, integration tests remain"
/jira todo
/jira progress
/jira done
/jira open
/jira assign john
```

## Instructions

**Step 1: Discover Atlassian site**

- Call `getAccessibleAtlassianResources` to get available sites
- If fails or no sites returned: "Jira plugin not configured. This command requires the Atlassian MCP plugin."
- Extract the site URL and cloud ID

**Step 2: Determine Jira ticket** (for commands that need it)

Priority order:

1. Extract from current branch name: `<user>/<PROJ-###>/topic` -> `PROJ-###`
2. Check recent conversation context for ticket references
3. Ask user for ticket key

**Step 3: Execute action**

### No argument - Show ticket details

- Fetch ticket using `getJiraIssue`
- Display:
  ```
  PROJ-123: <ticket summary>
  Status:   In Progress
  Assignee: <user>
  Sprint:   <Sprint Name>
  Link:     https://<site>.atlassian.net/browse/PROJ-123
  ```

### `mine` - List my tickets (grouped)

- Search using `searchJiraIssuesUsingJql`:
  ```
  assignee = currentUser() AND status != Done ORDER BY updated DESC
  ```
- Group results by sprint vs backlog
- Display:

  ```
  My Jira Tickets:

  <Sprint Name> (current):
  | Key       | Status      | Summary                    |
  |-----------|-------------|----------------------------|
  | PROJ-123  | In Progress | <ticket summary>           |
  | PROJ-124  | In Progress | <ticket summary>           |

  Backlog (no sprint):
  | Key       | Status      | Summary                    |
  |-----------|-------------|----------------------------|
  | PROJ-125  | To Do       | <ticket summary>           |

  Use /start <key> to begin work on a ticket.
  ```

### `sprint` - Show current sprint board

- Find active sprint using JQL:
  ```
  project = <PROJECT> AND sprint in openSprints() ORDER BY status DESC, updated DESC
  ```
- Parse results with a single jq command (Jira responses are large and get saved to file):
  ```bash
  jq -r '.[0].text | fromjson | {
    sprint: .issues[0].fields.customfield_10020[0],
    issues: [.issues[] | {
      key,
      status: .fields.status.name,
      assignee: (.fields.assignee.displayName // "Unassigned"),
      summary: .fields.summary
    }]
  }' <results-file>
  ```
- Display sprint info and all tickets (not just yours):

  ```
  <Sprint Name>
  Goal: <sprint goal>
  Dates: <start> - <end>

  In Progress:
  | Key       | Assignee | Summary            |
  |-----------|----------|--------------------|
  | PROJ-123  | <user>   | <ticket summary>   |
  | PROJ-124  | <user>   | <ticket summary>   |

  To Do:
  | Key       | Assignee | Summary            |
  |-----------|----------|--------------------|
  | PROJ-125  | <user>   | <ticket summary>   |

  Done (this sprint): N tickets
  ```

### `comment <text>` - Add comment

- Call `addCommentToJiraIssue` with the provided text
- Confirm: "Comment added to PROJ-123"

### `todo` / `progress` / `done` - Transition status

- Get available transitions using `getTransitionsForJiraIssue`
- Find matching transition:
  - `todo` -> "To Do" transition
  - `progress` -> "In Progress" transition
  - `done` -> "Done" transition
- Execute using `transitionJiraIssue`
- For `progress` only: also assign to current user
  - Get current user via `atlassianUserInfo`
  - Update assignee using `editJiraIssue` with `fields: { assignee: { accountId: <id> } }`
- Confirm: "PROJ-123 transitioned to In Progress" (add "and assigned to you" for progress)

### `open` - Open in browser

```bash
open "https://<site>.atlassian.net/browse/PROJ-123"
```

### `assign <user>` - Assign to user

- Search for user using `lookupJiraAccountId` with provided name
- If multiple matches, show options and ask user to pick
- Update ticket using `editJiraIssue` with assignee field
- Confirm: "PROJ-123 assigned to <user>"

---

Related commands:

- `/start` - begin work on a ticket (creates worktree)
- `/status` - overview including Jira status
- `/pr` - create PR and link ticket
- `/done` - transition to Done and cleanup

Branch naming convention: `<user>/<PROJ-###>/<topic>`
