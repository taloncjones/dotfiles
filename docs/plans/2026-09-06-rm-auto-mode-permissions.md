# Rm Auto-Mode Permissions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop `Bash(rm:*)` from the settings template's ask list and add a literal deny floor for root / home / `.git` removals, covered by the hook suite's static checks, the links suite's delivery check, and the committed verification contract.

**Architecture:** Pure data change plus tests. Edit `permissions` in `claude/settings.json.tmpl`; assert the shape statically in `claude/hooks/claude-hooks.test.sh` (three exact-list checks plus a Python model of the documented Bash rule matcher); assert delivery through the reconcile path in `install/claude-links.test.sh`. The existing live drift check in the hook suite covers reconciled machines with no change. The contract is already committed on the branch; Task 2 runs it end to end. Codex parity is a follow-up (spec, last section), not part of this plan.

**Tech Stack:** JSON template, POSIX sh test scripts (`PASS/FAIL ... N passed, N failed` convention), Python 3 stdlib (`json`, `re`).

**Spec:** `docs/specs/2026-09-06-rm-auto-mode-permissions.md`

## Global Constraints

- Run every command from the task worktree root. Before every commit, `git rev-parse --show-toplevel` must print a path ending in `rm-auto-mode` and `git branch --show-current` must print `talon/td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking/rm-auto-mode`. Use `git -C <worktree> ...` for every git command; the Bash cwd resets between commands.
- Pre-implementation gate (before Task 1): `git status --porcelain` is empty. Record `shasum -a 256 ~/.claude/settings.json ~/.claude-work/settings.json` for the final check; neither may change during implementation.
- Do NOT run `update`, `link.sh`, `dotfiles-repair`, or `reconcile_claude_settings_file` against a live config dir, and do NOT edit `~/.claude*/settings.json`. Template only. The live permissions-drift check in the hook suite fails on this machine until the user runs `update` after merge; that is expected (spec, design section).
- Always run the hook suite sandboxed: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh` (the live drift section SKIPs).
- Baselines recorded 2026-09-06 on this branch: hook suite sandboxed 76 passed, 0 failed; `install/claude-links.test.sh` 16 passed, 0 failed. Expected after Task 1: 80 and 17 passed, 0 failed.
- Deny floor: exactly 26 rules in the order given in Task 1 step 5 (target-major, bare form before trailing-text form). Ask list after the edit: exactly the four force-push rules and the Jira-create rule, unchanged order.
- Test labels: every new hook-suite line starts `PASS  permissions: ` (four lines); the new links-suite line is exactly `PASS  link path delivers the rm deny floor and drops the rm ask rule`. The contract greps these.
- Commit messages: `<scope>: <summary>` imperative, under 75 chars, and must not contain the word "claude" outside a scope prefix (commit_guard blocks it). Say "settings template", "hook suite", "auto mode".
- Write the test blocks with the Edit tool, not Bash heredocs: the content contains `rm -rf /` strings that trip the destructive-command gate when they appear in a Bash command line.
- A session in auto mode may be unable to commit the template edit (the classifier blocked a session editing its own permission rules on 2026-09-05). If `git commit` for Task 1 is refused, stop, report the exact refusal, and leave the change staged for a human or a non-auto session; do not work around it.
- Codex usage quota was exhausted on 2026-09-06 (reset 23:08 local). The spec and plan reviews used an independent fresh-context reviewer instead of the Codex gate. If the implement phase's `co-review` still cannot reach Codex, run the Claude half and report the Codex half as skipped.

## Acceptance criteria to contract mapping

Contract: `claude/contracts/td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking-contract.json` (committed with this plan; do not edit it during implementation).

| Spec acceptance criterion | Contract command(s) | Notes |
|---|---|---|
| 1. Template parses; no rm ask/allow; ask exact; deny exactly the 26-rule floor | `template-parses-and-rm-ask-rule-gone`, `template-ask-rules-exact`, `template-deny-floor-exact` | Task 1 step 5 |
| 2. Rule-model check passes for every harmless and prohibited shape | `template-rule-model-harmless-and-prohibited`, `claude-hooks-suite-has-permissions-checks` | The same model lives in the hook suite (Task 1 step 1) |
| 3. Links suite passes with the deny-floor delivery line | `claude-links-suite-with-deny-floor-delivery` | Task 1 step 3 |
| 4. Hook suite sandboxed 0 failed, exactly four `permissions:` lines | `claude-hooks-suite-sandboxed`, `claude-hooks-suite-has-permissions-checks` | Task 1 step 1 |
| 5. Live post-merge checks (drift check in both config dirs, auto-mode probes) | human-verify | Not repo-testable; listed in the spec's criterion 5 |
| 6. Diff touches only the three named files plus the contract; no live settings modified | human-verify | Task 2 step 3 (`git diff --stat`, settings hashes) |

---

### Task 1: Settings template deny floor with static and delivery tests

**Files:**
- Modify: `claude/settings.json.tmpl:156-164` (the `deny` and `ask` arrays)
- Modify: `claude/hooks/claude-hooks.test.sh` (insert after line 346, the `fi` closing the "template lists the Bash guards in order" check, and before the blank line preceding the `# account_guard.py account-aware routing` comment at line 348)
- Modify: `install/claude-links.test.sh` (insert after line 160, the `fi` closing the "link path delivers template permissions/statusLine" case)

**Interfaces:**
- Consumes: the hook suite's `PASS` / `FAIL` counters; the links suite's `pass NAME` / `fail NAME` helpers and its `jget FILE EXPR` helper (evaluates a Python expression against the parsed JSON as `d`).
- Produces: the 26-rule `permissions.deny` list and the 5-rule `permissions.ask` list that the contract's `template-*` commands and Task 2 assert byte-for-byte.

- [ ] **Step 1: Add the failing static permissions block to the hook suite**

Insert this block into `claude/hooks/claude-hooks.test.sh` after line 346 (`fi` of the hwg static-registration check) and before the blank line that precedes `# account_guard.py account-aware routing`:

```sh

# Permissions floor: the template must not ask (or allow) for rm, so auto
# mode's classifier decides scratch cleanup; must keep the force-push and
# Jira-create ask rules; and must deny the literal root / home / .git
# removal shapes, which block in every mode. Static: independent of live
# machine state (the live drift check below covers reconciled machines).
if python3 - <<'PY'
import json
import sys

p = json.load(open("claude/settings.json.tmpl"))["permissions"]
sys.exit(0 if "Bash(rm:*)" not in p["ask"] and "Bash(rm:*)" not in p["allow"] else 1)
PY
then
    printf 'PASS  permissions: template has no rm ask or allow rule\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  permissions: template has no rm ask or allow rule\n' >&2
    FAIL=$((FAIL + 1))
fi
if python3 - <<'PY'
import json
import sys

p = json.load(open("claude/settings.json.tmpl"))["permissions"]
want = [
    "Bash(git push --force:*)",
    "Bash(git push -f:*)",
    "Bash(git push --force-with-lease:*)",
    "Bash(git push --mirror:*)",
    "mcp__plugin_atlassian_atlassian__createJiraIssue",
]
sys.exit(0 if p["ask"] == want else 1)
PY
then
    printf 'PASS  permissions: template ask list is exactly force-push plus Jira create\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  permissions: template ask list is exactly force-push plus Jira create\n' >&2
    FAIL=$((FAIL + 1))
fi
if python3 - <<'PY'
import json
import sys

p = json.load(open("claude/settings.json.tmpl"))["permissions"]
targets = ["/", "~", "~/", "$HOME", "$HOME/", '"$HOME"', '"$HOME/"', "${HOME}", "${HOME}/",
           ".git", ".git/", "./.git", "./.git/"]
want = [r for t in targets for r in ("Bash(rm * %s)" % t, "Bash(rm * %s *)" % t)]
sys.exit(0 if p["deny"] == want else 1)
PY
then
    printf 'PASS  permissions: template deny floor is exactly the 26 root/home/.git rules\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  permissions: template deny floor is exactly the 26 root/home/.git rules\n' >&2
    FAIL=$((FAIL + 1))
fi
# Rule model: the documented Bash rule matcher (`*` matches any text; a
# trailing sole ` *` also matches the bare command; everything else is
# literal and the pattern spans the whole subcommand). Harmless scratch
# shapes must match no ask/deny rule; prohibited shapes must match a deny
# rule. This checks the rule text against the documented semantics, not
# the live matcher.
if python3 - <<'PY'
import json
import re
import sys

p = json.load(open("claude/settings.json.tmpl"))["permissions"]


def matches(rule, cmd):
    pat = rule[len("Bash("):-1]
    if pat.endswith(":*"):
        pat = pat[:-2] + " *"
    if pat.endswith(" *") and pat.count("*") == 1:
        rx = "^" + re.escape(pat[:-2]) + "( .*)?$"
    else:
        rx = "^" + ".*".join(re.escape(x) for x in pat.split("*")) + "$"
    return re.match(rx, cmd, re.DOTALL) is not None


assert matches("Bash(ls *)", "ls") and not matches("Bash(ls *)", "lsof")
assert matches("Bash(* --help *)", "npm --help x") and not matches("Bash(* --help *)", "npm --help")
bash_rules = [r for r in p["deny"] + p["ask"] if r.startswith("Bash(")]
harmless = [
    "rm -f /tmp/scratch.txt",
    "rm -rf /tmp/co-review-snap.x",
    "rm -rf .git/index.lock",
    "rm -rf build",
    "rm -rf ~/proj/build",
    "rm -rf $HOME/.cache/x",
    "rm .gitignore",
    "rm -rf ./.github",
]
prohibited = [
    "rm -rf /",
    "rm -r -f ~",
    'rm -rf "$HOME"',
    "rm -rf ${HOME}",
    "rm -rf ${HOME}/",
    "rm -f ~",
    "rm -rf .git",
    "rm -rf ./.git/",
    "rm -rf / --no-preserve-root",
    "rm --recursive --force ~/",
]
bad = [c for c in harmless if any(matches(r, c) for r in bash_rules)]
bad += [c for c in prohibited if not any(matches(r, c) for r in p["deny"])]
for c in bad:
    print("  rule-model failure: " + c)
sys.exit(1 if bad else 0)
PY
then
    printf 'PASS  permissions: rule model leaves scratch cleanup unmatched and denies prohibited targets\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  permissions: rule model leaves scratch cleanup unmatched and denies prohibited targets\n' >&2
    FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Run the hook suite to verify the new block fails**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep 'permissions:'`
Expected: four `FAIL  permissions: ...` lines (the template still asks for rm, the ask list has six entries, deny is empty, and the prohibited shapes match nothing). The final line reports `76 passed, 4 failed`.

- [ ] **Step 3: Add the failing delivery case to the links suite**

Insert after line 160 of `install/claude-links.test.sh` (the `fi` that closes the `link path delivers template permissions/statusLine` case):

```sh
if jget "$CFG/settings.json" "'Bash(rm * /)' in d['permissions']['deny'] and 'Bash(rm:*)' not in d['permissions']['ask']"; then
    pass "link path delivers the rm deny floor and drops the rm ask rule"
else
    fail "link path delivers the rm deny floor and drops the rm ask rule"
fi
```

- [ ] **Step 4: Run the links suite to verify the new case fails**

Run: `sh install/claude-links.test.sh 2>&1 | tail -4`
Expected: `FAIL  link path delivers the rm deny floor and drops the rm ask rule` and `16 passed, 1 failed`.

- [ ] **Step 5: Edit the settings template**

In `claude/settings.json.tmpl`, replace lines 156-164:

```json
    "deny": [],
    "ask": [
      "Bash(rm:*)",
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git push --force-with-lease:*)",
      "Bash(git push --mirror:*)",
      "mcp__plugin_atlassian_atlassian__createJiraIssue"
    ],
```

with:

```json
    "deny": [
      "Bash(rm * /)",
      "Bash(rm * / *)",
      "Bash(rm * ~)",
      "Bash(rm * ~ *)",
      "Bash(rm * ~/)",
      "Bash(rm * ~/ *)",
      "Bash(rm * $HOME)",
      "Bash(rm * $HOME *)",
      "Bash(rm * $HOME/)",
      "Bash(rm * $HOME/ *)",
      "Bash(rm * \"$HOME\")",
      "Bash(rm * \"$HOME\" *)",
      "Bash(rm * \"$HOME/\")",
      "Bash(rm * \"$HOME/\" *)",
      "Bash(rm * ${HOME})",
      "Bash(rm * ${HOME} *)",
      "Bash(rm * ${HOME}/)",
      "Bash(rm * ${HOME}/ *)",
      "Bash(rm * .git)",
      "Bash(rm * .git *)",
      "Bash(rm * .git/)",
      "Bash(rm * .git/ *)",
      "Bash(rm * ./.git)",
      "Bash(rm * ./.git *)",
      "Bash(rm * ./.git/)",
      "Bash(rm * ./.git/ *)"
    ],
    "ask": [
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git push --force-with-lease:*)",
      "Bash(git push --mirror:*)",
      "mcp__plugin_atlassian_atlassian__createJiraIssue"
    ],
```

Leave `"defaultMode": "auto"` and everything else untouched. Verify the file still parses: `python3 -c "import json; json.load(open('claude/settings.json.tmpl'))"`.

- [ ] **Step 6: Run both suites to verify they pass**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | tail -6`
Expected: four `PASS  permissions: ...` lines and `80 passed, 0 failed`.

Run: `sh install/claude-links.test.sh 2>&1 | tail -3`
Expected: `PASS  link path delivers the rm deny floor and drops the rm ask rule` and `17 passed, 0 failed`.

Spot check the counts the contract asserts:
`python3 -c "import json,sys; p=json.load(open('claude/settings.json.tmpl'))['permissions']; print(len(p['deny']), len(p['ask']))"`
Expected: `26 5`.

- [ ] **Step 7: Commit**

```bash
git -C "$W" add claude/settings.json.tmpl claude/hooks/claude-hooks.test.sh install/claude-links.test.sh
git -C "$W" commit -m "permissions: Drop rm ask rule and add deny floor to settings template"
```

If the commit is refused by the auto-mode classifier, stop and report per Global Constraints.

---

### Task 2: Contract run and final checks

**Files:**
- None modified. Reads `claude/contracts/td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking-contract.json`.

**Interfaces:**
- Consumes: the orchestrator CLI `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract` (runs every contract command via `sh -c` in the worktree; first failure stops the run).

- [ ] **Step 1: Run the full contract**

Run:
```bash
python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py" verify-contract \
  --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 \
  --task-id td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking \
  --worktree "$W" \
  --contract claude/contracts/td-2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking-contract.json \
  --allow-unpinned
```
Expected: exit 0, all 7 commands pass.

- [ ] **Step 2: Run the full repo test runner**

Run: `bin/dotfiles-tests 2>&1 | grep -E 'passed, [1-9]|FAIL' || echo all-green`
Expected: `all-green`, except that the unsandboxed hook suite inside the runner reports the live permissions drift on this machine as `FAIL  settings: ... permissions drifted` until the user runs `update`. If those two `settings:` lines (one per config dir) and the hook suite's own summary line are the only failures, record them as expected and continue.

- [ ] **Step 3: Confirm scope and untouched machine state**

Run: `git -C "$W" diff --stat 41dd7a164e858ca23dbda077dbbc2f69478118b3..HEAD -- . ':!docs' ':!claude/contracts'`
Expected: exactly these files: `claude/hooks/claude-hooks.test.sh`, `claude/settings.json.tmpl`, `install/claude-links.test.sh`.

Run: `shasum -a 256 ~/.claude/settings.json ~/.claude-work/settings.json`
Expected: identical to the hashes recorded before Task 1.

Run: `git -C "$W" status --porcelain`
Expected: empty.

- [ ] **Step 4: Report**

State the two suite totals, the contract result, the scope check, and the one item left for a human after merge: run `update`, which reconciles both config dirs so the live drift check passes and the new rules take effect in the next session. Note whether the Task 1 commit needed a human hand.

## Self-review

- Spec coverage: template edit (Task 1 step 5), static assertions and rule model (Task 1 step 1), links delivery (Task 1 step 3), contract end to end and scope check (Task 2). Criterion 5 is human-verify by design and is listed in the mapping table. The Codex follow-up is explicitly out of scope.
- Placeholder scan: none; every code step carries its full content.
- Name consistency: the label prefix `permissions: `, the links label, the 26-rule order, and the harmless/prohibited shape lists are identical across the spec, Task 1, and the contract.
