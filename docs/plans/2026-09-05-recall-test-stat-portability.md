# Recall Test Stat Portability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the recall suite's `file_mode` probe return the permission octal on both GNU and BSD `stat`, guard its output, and self-test it, so the `tests` job on main goes green.

**Architecture:** One helper in one test script changes. `file_mode` tries GNU `stat -c %a` first and falls back to BSD `stat -f %Lp`, then validates the result against a 3- or 4-digit octal pattern and prints `MODE-PROBE-BROKEN` otherwise. A two-assertion self-test at suite start exercises the probe on a `750` directory and a `640` file before any recall behaviour runs.

**Tech Stack:** bash test script (`set -uo pipefail`, `ok`/`bad`/`assert_eq` helpers already in the file); GNU coreutils `gstat` from Homebrew as the local Linux stand-in; `bin/dotfiles-tests` as the runner CI calls.

**Spec:** `docs/specs/2026-09-05-recall-test-stat-portability.md` (branch-only). Read it first; every task cites its section.

Status: plan, revision 2 after Codex plan review round 1. Review log at the end.

## Global Constraints

- Only `claude/skills/repo-recall/scripts/tests/recall_test.sh` changes (spec AC4). No edits to `recall.py`, other suites, `zsh/functions.zsh`, or CI.
- Expected modes in existing assertions stay `700` and `600` (spec Non-goals).
- Guard pattern is exactly `[0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]`; broken-probe token is exactly `MODE-PROBE-BROKEN` (spec Design).
- Self-test modes are `750` (directory) and `640` (file); assertion names are `file_mode reads dir mode` and `file_mode reads file mode` (spec Design).
- Pass count moves from `115 passed, 0 failed` to `117 passed, 0 failed` (spec AC1).
- Run every suite and the runner from the worktree root with `HOME="$(mktemp -d)"` so no real config dir is touched. Every check captures the exit status and asserts it; never judge by eye from a `tail`.
- While the branch-only spec and plan are tracked, `bin/dotfiles-tests` reports exactly one failing suite, `git/hooks/public-safety.test.sh` (`no tracked planning artifacts`). That is the drop-before-merge convention, not a regression; any other failing suite is.
- Run every git command as `git -C <worktree> ...`; Bash cwd resets between commands.
- No emojis, no AI attribution, no hardcoded home-directory paths in any tracked file (the public-safety suite greps for them). Commit format `<scope>: <summary>` (<75 chars, imperative). `docs/` is ignored in this checkout, so branch-only docs need `git add -f`.
- Local Linux stand-in: `gstat` (Homebrew coreutils, `/opt/homebrew/bin/gstat`). If it is missing, stop and report; do not skip the GNU run.

## File map

| File | Responsibility in this change |
| --- | --- |
| `claude/skills/repo-recall/scripts/tests/recall_test.sh` | `file_mode` rewrite (line 42) and the `== probe self-test` block inserted after it |
| `claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json` | this task's verification contract (committed with this plan) |

## Acceptance-criterion mapping

| AC | Task | Contract command |
| --- | --- | --- |
| AC1 native BSD-stat run, 117 passed | 1 | `recall-suite-native` (pins `/usr/bin/stat` first on Darwin; on Linux it is a second GNU run) |
| AC2 GNU-stat run, 117 passed | 1 | `recall-suite-gnu-stat` (local, via `gstat` shim); CI on `ubuntu-latest` is the human-verify half |
| AC3a GNU-shaped junk stat fails loudly | 1 | `probe-guard-gnu-shaped-junk` |
| AC3b BSD-shaped junk stat fails loudly | 1 | `probe-guard-bsd-shaped-junk` |
| AC4 single-file implementation diff | 2 | `diff-scope-single-file` |
| AC5 `tests` workflow green on PR and main | 2 | human-verify: read the GitHub Actions run on the PR after the branch-only docs are dropped, then on main after merge |

## Shim recipes

Every shim lives in a fresh `mktemp -d` directory prepended to `PATH` for one run. Nothing else in the suite calls a `stat` binary (spec Verification), so a shim changes only `file_mode`.

```bash
# GNU stat shim: real coreutils stat first on PATH
gnu_shim() { d=$(mktemp -d); ln -s "$(command -v gstat)" "$d/stat"; printf '%s\n' "$d"; }
# GNU-shaped junk: prints a fake filesystem block and exits 0 on every call
gnu_junk_shim() { d=$(mktemp -d); printf '#!/bin/sh\nprintf "  File: junk\\nBlock size: junk\\n"\nexit 0\n' > "$d/stat"; chmod +x "$d/stat"; printf '%s\n' "$d"; }
# BSD-shaped junk: rejects -c like BSD stat, prints the fake block otherwise
bsd_junk_shim() { d=$(mktemp -d); printf '#!/bin/sh\n[ "$1" = -c ] && { echo "stat: illegal option -- c" >&2; exit 1; }\nprintf "  File: junk\\nBlock size: junk\\n"\nexit 0\n' > "$d/stat"; chmod +x "$d/stat"; printf '%s\n' "$d"; }
# run_suite <shim-dir or ""> : runs the suite isolated, prints the probe/mode/summary lines, sets RC and OUT
run_suite() { OUT=$(PATH="${1:+$1:}$PATH" HOME="$(mktemp -d)" bash claude/skills/repo-recall/scripts/tests/recall_test.sh 2>&1); RC=$?; printf '%s\n' "$OUT" | grep -E 'file_mode|mode 700|mode 600|passed'; echo "rc=$RC"; }
```

Paste these into the shell before any step below that calls them (they are step-local conveniences, not repo code).

---

### Task 0: Baseline

- [ ] **Step 1: Record the native baseline**

```bash
run_suite ""; [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx '115 passed, 0 failed' && echo "[OK] baseline"
```

Expected: `[OK] baseline`. Carry `115 passed, 0 failed` into Task 1's commit body.

- [ ] **Step 2: Reproduce the CI failure locally with GNU stat**

```bash
command -v gstat >/dev/null || { echo "[X] gstat missing; install coreutils via Homebrew"; exit 1; }
run_suite "$(gnu_shim)"; [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qx '111 passed, 4 failed' && echo "[OK] reproduced"
```

Expected: four `FAIL` lines (`work config dir mode 700`, `recall dir mode 700`, `index file mode 600`, `index dir mode 700`) whose `got [...]` values start with `File:`, then `[OK] reproduced`. If the run is green instead, the shim is not first on `PATH`; fix that before continuing.

---

### Task 1: Probe self-test and portable `file_mode`

**Files:**
- Modify: `claude/skills/repo-recall/scripts/tests/recall_test.sh:42` (replace the one-line helper) and insert the self-test block between the helper definitions and the `echo "== unit tests"` line (currently line 44).

**Interfaces:**
- Consumes: existing `ok`, `bad`, `assert_eq` helpers (lines 9-11).
- Produces: `file_mode <path>` printing a 3- or 4-digit octal string, or `MODE-PROBE-BROKEN` with a one-line stderr diagnostic. The contract relies on the token text and on the two assertion names below.

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

- [ ] **Step 2: Run RED under GNU stat and under both junk shims (old probe still in place)**

```bash
run_suite "$(gnu_shim)";      [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -q 'FAIL file_mode reads dir mode' && printf '%s\n' "$OUT" | grep -qx '111 passed, 6 failed' && echo "[OK] red: gnu"
run_suite "$(gnu_junk_shim)"; [ "$RC" -ne 0 ] && ! printf '%s\n' "$OUT" | grep -q 'MODE-PROBE-BROKEN' && echo "[OK] red: gnu junk (no guard token yet)"
run_suite "$(bsd_junk_shim)"; [ "$RC" -ne 0 ] && ! printf '%s\n' "$OUT" | grep -q 'MODE-PROBE-BROKEN' && echo "[OK] red: bsd junk (no guard token yet)"
```

Expected: all three `[OK] red:` lines. Under the GNU shim the two new assertions fail with a multi-line `got [ File: ...` value. Under the junk shims the mode assertions fail but nothing prints `MODE-PROBE-BROKEN`, which is the guard behaviour Step 3 adds. The native run (no shim) already passes both new assertions; that is fine, the GNU run is the red step for the probe order.

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

- [ ] **Step 4: Run GREEN on all four stat shapes**

```bash
run_suite "";                 [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx '117 passed, 0 failed' && echo "[OK] green: native"
run_suite "$(gnu_shim)";      [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx '117 passed, 0 failed' && echo "[OK] green: gnu"
run_suite "$(gnu_junk_shim)"; [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qx '111 passed, 6 failed' && printf '%s\n' "$OUT" | grep -q 'got \[MODE-PROBE-BROKEN\]' && printf '%s\n' "$OUT" | grep -q 'FAIL file_mode reads dir mode' && printf '%s\n' "$OUT" | grep -q 'FAIL file_mode reads file mode' && ! printf '%s\n' "$OUT" | grep -q 'Block size' && echo "[OK] guard: gnu junk (AC3a)"
run_suite "$(bsd_junk_shim)"; [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qx '111 passed, 6 failed' && printf '%s\n' "$OUT" | grep -q 'got \[MODE-PROBE-BROKEN\]' && printf '%s\n' "$OUT" | grep -q 'FAIL file_mode reads dir mode' && printf '%s\n' "$OUT" | grep -q 'FAIL file_mode reads file mode' && ! printf '%s\n' "$OUT" | grep -q 'Block size' && echo "[OK] guard: bsd junk (AC3b)"
```

Expected: all four `[OK]` lines. Under the junk shims the two self-test assertions and the four mode assertions all read `got [MODE-PROBE-BROKEN]`, the stderr diagnostic reads `file_mode: non-octal output for ...: [  File: junk]`, and `Block size` never appears. If any line is missing, fix the probe here and re-run this step; nothing is committed yet.

- [ ] **Step 5: Syntax-gate the file the way CI does and run the full runner**

```bash
bash -n claude/skills/repo-recall/scripts/tests/recall_test.sh && echo "[OK] syntax"
ROUT=$(HOME="$(mktemp -d)" bash bin/dotfiles-tests 2>&1); RRC=$?
printf '%s\n' "$ROUT" | grep -E '^\[X\]|dotfiles-tests:|^11[0-9] passed'
printf '%s\n' "$ROUT" | grep -qx '117 passed, 0 failed' && [ "$(printf '%s\n' "$ROUT" | grep -c '^\[X\] FAILED')" -eq 1 ] && printf '%s\n' "$ROUT" | grep -q '^\[X\] FAILED git/hooks/public-safety.test.sh' && echo "[OK] runner (only the branch-only-docs suite failing)"
```

Expected: `[OK] syntax`, `RRC` is 1, the runner summary reads `18 suites passed, 1 failed`, and `[OK] runner ...`. The single failing suite is `git/hooks/public-safety.test.sh` on `no tracked planning artifacts` (see Global Constraints). If any other suite fails, stop: that is a regression to investigate before committing.

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add claude/skills/repo-recall/scripts/tests/recall_test.sh
git -C <worktree> commit -m "recall: Make test file-mode probe portable across GNU and BSD stat" -m "GNU stat treats -f as filesystem status and prints a filesystem block before exiting 1, so the old probe captured the block plus the mode on Linux. Try -c first, guard the output, and self-test the probe at suite start.

Baseline on ed5f036: 115 passed, 0 failed natively; 111 passed, 4 failed under GNU stat. After: 117 passed, 0 failed on both."
```

---

### Task 2: Contract run and scope check

**Files:**
- Read only: `claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json`

- [ ] **Step 1: Confirm the implementation diff is one file (spec AC4)**

```bash
changed=$(git -C <worktree> diff --name-only ed5f036f37be67a7a8f2bc0a025794ea77326320 -- . ':(exclude)docs' ':(exclude)claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json')
printf '%s\n' "$changed"; [ "$changed" = claude/skills/repo-recall/scripts/tests/recall_test.sh ] && echo "[OK] scope"
```

Expected: exactly one path printed, then `[OK] scope`.

- [ ] **Step 2: Run the verification contract end to end**

```bash
python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py" verify-contract \
  --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 \
  --task-id td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li \
  --worktree <worktree> \
  --contract claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json \
  --allow-unpinned; echo "rc=$?"
```

Expected: `rc=0` with all five commands passing. A failing command names the AC to revisit via the mapping table above.

- [ ] **Step 3: Record what is unverified**

In the close, state plainly: Linux was verified locally through a `gstat` shim, not on a Linux host; the authoritative Linux run is the `tests` job on the PR (AC5), which a human reads from GitHub Actions after the branch-only docs are dropped and the branch is pushed. Nothing is pushed by the implementer.

---

## Self-review

- Spec coverage: Goals 1-3, Design, Failure shape, AC1-AC3b land in Task 1; AC4 in Task 2; AC5 is human-verify by design (CI is the only Linux host the repo owns).
- Placeholders: none. Every step carries its command, an asserted exit status, and the expected `[OK]` line.
- Name consistency: `MODE-PROBE-BROKEN`, `file_mode reads dir mode`, `file_mode reads file mode`, `750`/`640`, `117 passed, 0 failed`, `111 passed, 6 failed` match the spec and the contract verbatim.

## Review log

- Revision 1: initial plan.
- Revision 2: Codex plan review round 1 (verdict minor-fixes). Folded all seven: isolated `HOME` for the runner and the expected public-safety failure while docs are tracked (medium); every check asserts exit status and the exact summary instead of piping to `tail` (medium); junk-stat guard cases run RED before the probe rewrite and GREEN before the commit, old Task 2 folded into Task 1 (medium); contract suite commands require the exact `117 passed, 0 failed` line plus both self-test lines (medium); native contract command pins `/usr/bin/stat` first on Darwin (medium); guard snippets assert with `! grep -q` rather than print counts (low); commit carries a body via a second `-m` (low).
