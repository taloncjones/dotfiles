# /arch-review - Architecture review

Review code for architectural issues, design patterns, and SOLID principles.

## Usage

- `/arch-review` - Review recent git changes
- `/arch-review <path>` - Review specific file/directory
- `/arch-review <path1> <path2>` - Review multiple paths

## Workflow

**Step 1: Determine scope**
- If paths provided: Review those specific files/directories
- If no args: Use `git diff --name-only` to find changed files
  - Prefer staged changes if present
  - Fall back to unstaged changes

**Step 2: Understand context**
- Identify the architectural style (layered, microservices, etc.)
- Check existing patterns in the codebase
- Understand module boundaries

**Step 3: Evaluate using architecture-reviewer methodology**

**Separation of Concerns**
- Are responsibilities clearly divided?
- Do modules have single purposes?
- Is business logic separated from infrastructure?

**SOLID Principles**
- Single Responsibility
- Open/Closed
- Liskov Substitution
- Interface Segregation
- Dependency Inversion

**Scalability**
- Can this handle growth?
- Are there bottlenecks?
- Is state management appropriate?

**Maintainability**
- Is this understandable?
- Are changes localized?
- Is it testable?

**Step 4: Check for anti-patterns**
- God objects
- Circular dependencies
- Leaky abstractions
- Tight coupling

**Step 5: Report**

```
## Architecture Review

**Scope**: [files reviewed]
**Health**: [SOLID | MINOR ISSUES | NEEDS ATTENTION]

### Issues
**High**: [architectural problems]
**Medium**: [design smells]
**Low**: [suggestions]

### Summary
[Key findings and recommendations]
```

Focus on real architectural issues, not style preferences.
