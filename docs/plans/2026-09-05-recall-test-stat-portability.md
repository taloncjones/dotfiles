# Recall Test Stat Portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the recall suite's `file_mode` probe return the permission octal on both GNU and BSD `stat`, guard its output, and self-test it, so the `tests` job on main goes green.

**Architecture:** One helper in one test script changes. `file_mode` tries GNU `stat -c %a` first and falls back to BSD `stat -f %Lp`, then validates the result against a 3- or 4-digit octal pattern and prints `MODE-PROBE-BROKEN` otherwise. A two-assertion self-test at suite start exercises the probe on a `750` directory and a `640` file before any recall behaviour runs.

**Tech Stack:** bash test script (`set -uo pipefail`, `ok`/`bad`/`assert_eq` helpers already in the file); GNU coreutils `gstat` from Homebrew as the local Linux stand-in; `bin/dotfiles-tests` as the runner CI calls.

**Spec:** `docs/specs/2026-09-05-recall-test-stat-portability.md` (branch-only). Read it first; every task cites its section.

## Global Constraints

- Only `claude/skills/repo-recall/scripts/tests/recall_test.sh` changes (spec AC4). No edits to `recall.py`, other suites, `zsh/functions.zsh`, or CI.
- Expected modes in existing assertions stay `700` and `600` (spec Non-goals).
- Guard pattern is exactly `[0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]`; broken-probe token is exactly `MODE-PROBE-BROKEN` (spec Design).
- Self-test modes are `750` (directory) and `640` (file); assertion names are `file_mode reads dir mode` and `file_mode reads file mode` (spec Design).
- Pass count moves from `115 passed, 0 failed` to `117 passed, 0 failed` (spec AC1).
- Run every suite from the worktree root with `HOME` pointed at a fresh `mktemp -d` so no real config dir is touched.
- Run every git command as `git -C <worktree> ...`; Bash cwd resets between commands.
- No emojis, no AI attribution. Commit format `<scope>: <summary>` (<75 chars, imperative). `docs/` is ignored in this checkout, so branch-only docs need `git add -f`.
- Local Linux stand-in: `gstat` at `/opt/homebrew/bin/gstat`. If it is missing, stop and report; do not skip the GNU run.

## File map

| File | Responsibility in this change |
| --- | --- |
| `claude/skills/repo-recall/scripts/tests/recall_test.sh` | `file_mode` rewrite (line 42) and the `== probe self-test` block inserted after it |
| `claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json` | this task's verification contract (committed with this plan) |

## Acceptance-criterion mapping

| AC | Task | Contract command |
| --- | --- | --- |
| AC1 native run, 117 passed | 1 | `recall-suite-native` |
| AC2 GNU stat run, 117 passed | 1 | `recall-suite-gnu-stat` (local, via `gstat` shim); CI on `ubuntu-latest` is the human-verify half |
| AC3a GNU-shaped junk stat fails loudly | 2 | `probe-guard-gnu-shaped-junk` |
| AC3b BSD-shaped junk stat fails loudly | 2 | `probe-guard-bsd-shaped-junk` |
| AC4 single-file implementation diff | 3 | `diff-scope-single-file` |
| AC5 `tests` workflow green on PR and main | 3 | human-verify: read the GitHub Actions run on the PR, then on main after merge |

---

### Task 0: Baseline

- [ ] **Step 1: Record the native baseline**

```bash
HOME="$(mktemp -d)" bash claude/skills/repo-recall/scripts/tests/recall_test.sh 2>&1 | tail -1
```

Expected: `115 passed, 0 failed`. Carry this line into Task 1's commit body.

- [ ] **Step 2: Reproduce the CI failure locally with GNU stat**

```bash
command -v gstat || { echo "[X] gstat missing; install coreutils via Homebrew"; exit 1; }
d=$(mktemp -d); ln -s "$(command -v gstat)" "$d/stat"
PATH="$d:$PATH" HOME="$(mktemp -d)" bash claude/skills/repo-recall/scripts/tests/recall_test.sh 2>&1 | grep -E 'FAIL|passed'
```

Expected: four `FAIL` lines (`work config dir mode 700`, `recall dir mode 700`, `index file mode 600`, `index dir mode 700`), each followed by a multi-line `got [ File: ...` value, and `111 passed, 4 failed`. If the run is green instead, the shim is not first on `PATH`; fix that before continuing.

---

### Task 1: Probe self-test and portable `file_mode`

**Files:**
- Modify: `claude/skills/repo-recall/scripts/tests/recall_test.sh:42` (replace the one-line helper) and insert the self-test block between the helper definitions and the `echo "== unit tests"` line (currently line 44).

**Interfaces:**
- Consumes: existing `ok`, `bad`, `assert_eq` helpers (lines 9-11).
- Produces: `file_mode <path>` printing a 3- or 4-digit octal string, or `MODE-PROBE-BROKEN` with a one-line stderr diagnostic. Task 2's shims and the contract rely on the token text and on the two assertion names below.

- [ ] **Step 1: Write the failing self-test**

Insert after line 42 (the `file_mode` line) and before `echo "== unit tests"`:

```bash

echo "== probe self-test"
PROBE=$(mktemp -d)
mkdir "$PROBE/d"; chmod 750 "$PROBE/d"
touch "$PROBE/f"; chmod 640 "$PROBE/f"
assert_eq "file_mode reads dir mode" "$(file_mode "$PROBE/d")" 750
assert_eq "file_mode reads file mode" "$(file_mode "$PROBE/f")" 640
```

- [ ] **Step 2: Run it under GNU stat to verify it fails**

```bash
d=$(mktemp -d); ln -s "$(command -v gstat)" "$d/stat"
PATH="$d:$PATH" HOME="$(mktemp -d)" bash claude/skills/repo-recall/scripts/tests/recall_test.sh 2>&1 | grep -E 'file_mode|passed'
```

Expected: `FAIL file_mode reads dir mode`, `FAIL file_mode reads file mode`, and `111 passed, 6 failed`. The native run (no shim) is expected to already pass both new assertions; that is fine, the GNU run is the red step.

- [ ] **Step 3: Replace the probe**

Replace line 42 (`file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }`) with:

```bash
# GNU coreutils first: BSD stat rejects -c outright (exit 1, nothing on
# stdout), so the fallback runs clean. The reverse order is the bug this
# replaces: GNU stat accepts -f as "filesystem status", prints a filesystem
# block to stdout, and only then exits 1, so $(...) captures the block too.
file_mode() {
  local mode
  mode=$(stat -c %a "$1" 2>/dev/null) || mode=$(stat -f %Lp "$1" 2>/dev/null)
  case "$mode" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) printf '%s\n' "$mode" ;;
    *) printf 'MODE-PROBE-BROKEN\n'
       printf '     file_mode: non-octal output for %s: [%.60s]\n' \
         "$1" "${mode%%$'\n'*}" >&2 ;;
  esac
}
```

- [ ] **Step 4: Run natively and under GNU stat to verify both pass**

```bash
HOME="$(mktemp -d)" bash claude/skills/repo-recall/scripts/tests/recall_test.sh 2>&1 | tail -1
d=$(mktemp -d); ln -s "$(command -v gstat)" "$d/stat"
PATH="$d:$PATH" HOME="$(mktemp -d)" bash claude/skills/repo-recall/scripts/tests/recall_test.sh 2>&1 | tail -1
```

Expected: both print `117 passed, 0 failed`.

- [ ] **Step 5: Syntax-gate the file the way CI does and run the full runner**

```bash
bash -n claude/skills/repo-recall/scripts/tests/recall_test.sh && echo "[OK] syntax"
bash bin/dotfiles-tests 2>&1 | tail -5
```

Expected: `[OK] syntax`; the runner ends with every suite passing (the recall line reads `117 passed, 0 failed`).

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add claude/skills/repo-recall/scripts/tests/recall_test.sh
git -C <worktree> commit -m "recall: Make test file-mode probe portable across GNU and BSD stat"
```

Commit body: the Task 0 baseline line (`115 passed, 0 failed` native; `111 passed, 4 failed` under GNU stat) and the new counts (`117 passed, 0 failed` on both).

---

### Task 2: Prove the guard fires on a broken stat

**Files:**
- No repo file changes expected. Shims live in `mktemp -d` directories only.

**Interfaces:**
- Consumes: `MODE-PROBE-BROKEN` token and the two self-test assertion names from Task 1.

- [ ] **Step 1: GNU-shaped junk stat (spec AC3a)**

```bash
d=$(mktemp -d)
printf '#!/bin/sh\nprintf "  File: junk\\nBlock size: junk\\n"\nexit 0\n' > "$d/stat"; chmod +x "$d/stat"
out=$(PATH="$d:$PATH" HOME="$(mktemp -d)" bash claude/skills/repo-recall/scripts/tests/recall_test.sh 2>&1); rc=$?
printf '%s\n' "$out" | grep -E 'file_mode|passed'
echo "rc=$rc"
printf '%s\n' "$out" | grep -c 'Block size'
```

Expected: `FAIL file_mode reads dir mode` and `FAIL file_mode reads file mode`, each with `got [MODE-PROBE-BROKEN]`; two stderr lines `file_mode: non-octal output for ...: [  File: junk]`; `111 passed, 6 failed`; `rc=1`; the `Block size` count is `0`.

- [ ] **Step 2: BSD-shaped junk stat (spec AC3b)**

```bash
d=$(mktemp -d)
printf '#!/bin/sh\n[ "$1" = -c ] && { echo "stat: illegal option -- c" >&2; exit 1; }\nprintf "  File: junk\\nBlock size: junk\\n"\nexit 0\n' > "$d/stat"; chmod +x "$d/stat"
out=$(PATH="$d:$PATH" HOME="$(mktemp -d)" bash claude/skills/repo-recall/scripts/tests/recall_test.sh 2>&1); rc=$?
printf '%s\n' "$out" | grep -E 'file_mode|passed'
echo "rc=$rc"
printf '%s\n' "$out" | grep -c 'Block size'
```

Expected: identical to Step 1.

- [ ] **Step 3: If either step deviates, fix the probe in Task 1's file, re-run Task 1 Steps 4-5, and add a new commit `recall: Tighten file-mode probe guard`. Do not amend.**

---

### Task 3: Contract run and scope check

**Files:**
- Read only: `claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json`

- [ ] **Step 1: Confirm the implementation diff is one file (spec AC4)**

```bash
git -C <worktree> diff --name-only ed5f036f37be67a7a8f2bc0a025794ea77326320 -- . ':(exclude)docs' ':(exclude)claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json'
```

Expected: exactly one line, `claude/skills/repo-recall/scripts/tests/recall_test.sh`.

- [ ] **Step 2: Run the verification contract end to end**

```bash
python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py" verify-contract \
  --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 \
  --task-id td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li \
  --worktree <worktree> \
  --contract claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json \
  --allow-unpinned
```

Expected: exit 0 with all five commands passing. A failing command names the AC to revisit via the mapping table above.

- [ ] **Step 3: Record what is unverified**

In the close, state plainly: Linux was verified locally through a `gstat` shim, not on a Linux host; the authoritative Linux run is the `tests` job on the PR (AC5), which a human reads from GitHub Actions after the branch is pushed. Nothing is pushed by the implementer.

---

## Self-review

- Spec coverage: Goals 1-3 and Design land in Task 1; Failure shape and AC3a/AC3b in Task 2; AC4 in Task 3; AC5 is human-verify by design (CI is the only Linux host the repo owns).
- Placeholders: none. Every step carries its command and expected output.
- Name consistency: `MODE-PROBE-BROKEN`, `file_mode reads dir mode`, `file_mode reads file mode`, `750`/`640` match the spec and the contract verbatim.
