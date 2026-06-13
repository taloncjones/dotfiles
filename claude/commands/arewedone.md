# /arewedone - Structural completeness check

Verify that changes are fully integrated before considering work complete.

## Usage

- `/arewedone` - Review recent changes for completeness
- `/arewedone <scope>` - Focus on specific files/directories

## Workflow

**Step 1: Identify Changes**
Run `git diff --name-only HEAD~5` (or appropriate range) to identify recently modified files.

**Step 2: Launch Completeness Review**
Using the completeness-reviewer agent methodology, systematically verify:

1. **Dead Code Check**
   - Are there any old implementations left behind?
   - Unused imports or functions?
   - Commented-out code without justification?

2. **Integration Check**
   - If multiple files changed, are all layers updated?
   - Are all call sites updated for any signature changes?
   - Configuration files updated?

3. **Artifact Check**
   - Any TODO/FIXME without ticket references?
   - Debug statements left in?
   - Hardcoded values that should be config?

4. **Dependency Check**
   - New imports actually used?
   - Removed code has dependencies cleaned up?

**Step 3: Report**

Output a structured verdict:

```
## Completeness Check

### Changes Reviewed
- [list of files]

### Checklist
- [ ] Dead code removed
- [ ] All layers updated
- [ ] No dev artifacts
- [ ] Dependencies clean

### Issues Found
[list any problems]

### Verdict: [READY TO MERGE | NEEDS WORK]
```

**Step 4: If Issues Found**
Offer to fix the issues or provide specific guidance on what needs to change.

Be thorough but efficient. The goal is catching incomplete work before it becomes technical debt.
