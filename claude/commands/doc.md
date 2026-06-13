# /doc - Generate or review documentation

Generate documentation or audit existing docs for quality.

## Usage

- `/doc` - Document current file
- `/doc <file>` - Document specific file
- `/doc <file:function>` - Document specific function/class
- `/doc --review` - Audit docs without making changes (uses doc-reviewer)

## Workflow

**Step 1: Determine mode**
- If `--review` flag: Use doc-reviewer methodology (read-only audit)
- Otherwise: Use doc-implementer methodology (write docs)

**Step 2: Read and understand target**
- Read the target code thoroughly
- Identify inputs, outputs, side effects
- Note any non-obvious behavior
- Check existing documentation style in codebase

---

## Review Mode (--review)

Using doc-reviewer agent methodology:

1. **Coverage analysis**: What % is documented?
2. **Staleness check**: Do docs match current code?
3. **Quality assessment**: Are docs clear and useful?
4. **Report findings** without making changes

Output:
```
## Documentation Audit

**Coverage**: X/Y functions documented
**Health**: [GOOD | NEEDS ATTENTION | POOR]

### Issues by Priority
**High**: [blocks understanding]
**Medium**: [causes confusion]
**Low**: [nice to have]

### Recommendations
1. Highest impact improvement
```

---

## Implementation Mode (default)

Using doc-implementer agent methodology:

**For functions/methods:**
```python
def function_name(param1: Type, param2: Type) -> ReturnType:
    """One-line summary in imperative mood.

    Args:
        param1: Description (types are in signature)
        param2: Description

    Returns:
        What the return value represents

    Example:
        >>> function_name("input", 42)
        "output"
    """
```

**For classes:**
- Class-level docstring explaining purpose
- Document `__init__` params
- Document public methods
- Note important attributes

**For modules:**
- Module docstring at top
- Brief description of what it provides
- Key exports listed

**Principles:**
- Concise over comprehensive
- Examples over explanations
- Don't document obvious things
- Use type hints instead of documenting types
