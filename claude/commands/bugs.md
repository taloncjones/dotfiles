# /bugs - Systematic bug hunting

Conduct a thorough code audit to find bugs before they reach production.

## Usage

- `/bugs` - Audit recent changes
- `/bugs <file>` - Focus on specific file
- `/bugs <file:function>` - Deep dive on specific function
- `/bugs --critical` - Only report critical/high severity

## Workflow

**Step 1: Determine Scope**
- If no argument: Use `git diff --name-only main...HEAD` to find changed files
- If file specified: Focus on that file and its direct dependencies
- If function specified: Deep dive that function and its callers/callees

**Step 2: Understand Context**
Before hunting bugs:
- Read relevant tests to understand expected behavior
- Check recent commits for context on changes
- Identify the data flow through target code

**Step 3: Systematic Analysis**
Using bug-finder agent methodology, examine each code section asking:

**Null/Undefined:**
- What if this value is None/null/undefined?
- Are optional values checked before use?

**Error Handling:**
- What if this operation fails?
- Are errors caught and handled appropriately?
- Are errors logged with enough context?

**Logic:**
- Are loop bounds correct? (off-by-one?)
- Are boolean conditions correct?
- Are comparisons using correct operators?

**Async/Concurrency:**
- Could this race with other code?
- Are promises/futures handled correctly?
- Is shared state protected?

**Edge Cases:**
- Empty collections?
- Zero/negative values?
- Very large inputs?

**Step 4: Report Findings**

```
## Bug Audit Report

**Scope**: [what was examined]
**Findings**: X critical, Y high, Z medium

### Critical
- **[file:line]** Summary
  Impact: What breaks
  Fix: How to fix

### High
...

### Medium
...

### Suspicious (verify intent)
...

## Recommendation
[Overall assessment and priority order for fixes]
```

**Step 5: Offer Fixes**
For each bug found, offer to implement the fix if desired.

Find the bugs that would wake someone up at 3am - before they make it to production.
