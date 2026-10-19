
## Seat report block

End your final message with exactly one fenced `co-review-seat` block, after
the prose report. Never emit a draft block earlier. The gate reads this block
and nothing else for your findings, coverage and tests. The body is one JSON
object with exactly these keys:

```co-review-seat
{
  "seat": "<your seat name: claude, codex, breaker or verifier>",
  "verdict": "APPROVE",
  "findings": [
    {"id": "F1", "severity": "minor", "disposition": "confirmed",
     "scenario": "what happens", "evidence": "file:line or command output"}
  ],
  "coverage": {
    "architecture": {"ownership_authority": "evidence", "...": "all six axes"},
    "checklist": {"functional_behavior": "evidence", "...": "all sixteen items"}
  },
  "tests": [
    {"command": "sh tests/run.sh", "exit_code": 0, "result": "12 passed"}
  ]
}
```

- `verdict` is `APPROVE`, `CHANGES` or `INCOMPLETE`. `disposition` is
  `confirmed`, `refuted` or `unresolved`. Finding ids are unique. Add
  `impact` to a material finding as the policy requires.
- Every architecture axis and checklist item carries a nonempty string. Use
  the exact keys from the policy.
- Run at least one command that exercises the changed behavior (a targeted
  test, the owning suite, or an executable probe). Record each command you
  ran in `tests` with its exit code and a one-line result. A failing command
  is still evidence; list it. Never list a command you did not run.
- Small tier: when the prompt has a `## Small tier` section, it replaces the
  two rules above and the disposable-copy rule below. Run no test suite, build
  no copy, and list only read-only inspection commands (or none) in `tests`.
- Run commands in a disposable copy outside the snapshot root, built with
  `d=$(mktemp -d) && git -C <snapshot root> archive <reviewed tree> | tar -x -C "$d"`,
  or with a command that writes nothing under the snapshot root.
- Run commands in the foreground. Do not start background tasks or monitors.
  The final message must be the complete report; if anything arrives after
  it, repeat the whole report including the block.
- If no command could run, leave `tests` empty and say why in
  `coverage.checklist.functional_behavior`. The gate then records that
  coverage as incomplete.
