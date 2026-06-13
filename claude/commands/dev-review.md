# /dev-review - Comprehensive development review

Pre-PR review combining architecture analysis, bug hunting, and CLAUDE.md compliance with confidence scoring.

## Usage

- `/dev-review` - Review current changes (staged or unstaged)
- `/dev-review <path>` - Review specific file/directory
- `/dev-review --staged` - Review only staged changes

## Instructions

1. **Determine scope**

   ```bash
   # If path provided, use that
   # Otherwise, find changed files
   git diff --name-only          # unstaged
   git diff --cached --name-only # staged
   ```

   If no changes found, ask user what to review.

2. **Gather context**
   - Read relevant CLAUDE.md files (repo root + `~/.claude/CLAUDE.md`)
   - Identify the file types and languages involved
   - Note the architectural patterns in use

3. **Launch 3 parallel review agents**

   Use the Task tool to launch these agents simultaneously:

   **Agent 1: Architecture (architecture-reviewer)**
   - SOLID principles compliance
   - Separation of concerns
   - Module boundaries and coupling
   - Scalability concerns
   - Anti-patterns (god objects, circular deps, leaky abstractions)

   **Agent 2: Bug Hunter (bug-finder)**
   - Logic errors and edge cases
   - Race conditions in async code
   - Null/undefined handling
   - Resource leaks
   - Error handling gaps
   - Security issues (OWASP top 10)
   - Performance concerns
   - Missing validation at boundaries

   **Agent 3: CLAUDE.md Compliance (code-documentation:code-reviewer)**
   - Check against repo CLAUDE.md
   - Check against user CLAUDE.md (~/.claude/CLAUDE.md)
   - Code style requirements
   - Commit/branch conventions (if applicable)
   - Use `git log main..HEAD --oneline` to check commit messages

   Each agent should return issues in this format:

   ```
   - Issue: <description>
     Location: <file:line>
     Category: <arch|bug|claude-md>
     Confidence: <0-100>
     Reason: <why this is an issue>
   ```

4. **Score and filter issues**

   For each issue returned, evaluate confidence:

   | Score  | Meaning                                   |
   | ------ | ----------------------------------------- |
   | 0-25   | False positive or pre-existing issue      |
   | 26-50  | Might be real, but nitpicky or rare       |
   | 51-75  | Real issue, moderate importance           |
   | 76-90  | Verified issue, will impact functionality |
   | 91-100 | Confirmed critical issue                  |

   **Filter to issues with confidence >= 75**

5. **Output report**

   ```
   ## Development Review

   **Scope**: <files reviewed>
   **Issues**: <count> found (filtered from <total> candidates)

   ### Critical (90+)
   1. [BUG] <description> - <file:line>
      <reason and fix suggestion>

   ### High (75-89)
   1. [ARCH] <description> - <file:line>
      <reason and fix suggestion>

   2. [CLAUDE.md] <description> - <file:line>
      <relevant CLAUDE.md rule>

   ### Summary
   <1-2 sentence overview of code health>

   Ready for PR: [YES | FIX CRITICAL ISSUES FIRST | NEEDS REDESIGN]
   ```

6. **If no issues >= 75 confidence**

   ```
   ## Development Review

   **Scope**: <files reviewed>
   **Issues**: None found above threshold

   Checked: architecture, bugs, CLAUDE.md compliance
   Ready for PR: YES
   ```

## Notes

- Focus on actionable issues, not style preferences
- Pre-existing issues in unchanged code should score 0
- Issues a linter/compiler would catch score 0 (CI will find them)
- When in doubt, check if CLAUDE.md explicitly requires it

---

Related commands:

- `/arch-review` - Architecture-only review (faster, narrower)
- `/bugs` - Bug hunting only
- `/arewedone` - Quick structural completeness check (use during development)
- `/code-review:code-review` - Post-PR review with GitHub comments
