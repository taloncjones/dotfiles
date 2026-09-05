# Portable file-mode probe in the recall test suite

Task: `td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li`
Base: origin/main @ ed5f036 (PR #79 merged)
Status: spec, revision 2 after Codex spec review round 1 (branch-only;
dropped before merge per repo convention). Review log at the end.

## Problem

The `tests` job on main has been red since PR #77 merged (run 33582266297,
2026-09-02). `claude/skills/repo-recall/scripts/tests/recall_test.sh` fails
four permission-mode assertions on `ubuntu-latest`:

- `work config dir mode 700` (line 74)
- `recall dir mode 700` (line 75)
- `index file mode 600` (line 135)
- `index dir mode 700` (line 136)

All four go through one helper at line 42:

```bash
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
```

Verified mechanism (reproduced locally with GNU coreutils `gstat` 2026-09-05):
GNU `stat -f` means "print filesystem status", not "format". It treats `%Lp`
as a filename (missing, exit 1) and `$1` as a filesystem, and prints a
five-line filesystem block to stdout before exiting 1. The `||` fallback then
runs and prints the mode. Inside `$(...)` the captured value is the filesystem
block followed by the mode, so `assert_eq` compares `700` against a six-line
string and fails. The task brief's phrasing ("succeeds, so the fallback never
runs") describes the symptom; the exact mechanism is stdout pollution, and the
fix is the same either way.

Every PR inherits the red check (#79 and #80 both showed it), which hides real
regressions.

The three `stat` calls in `zsh/functions.zsh` (lines 105, 107, 1027) are not
affected: two branch on `uname`, one uses `-f%m`, which GNU stat rejects
outright with nothing on stdout. They are out of scope.

## Goals

1. `file_mode` returns the permission bits as an octal string on both GNU
   coreutils `stat` (Linux CI) and BSD `stat` (macOS), regardless of which
   `stat` is first on `PATH`.
2. The probe validates its own output. Anything that is not a 3- or 4-digit
   octal string makes the affected assertion fail with a message that names
   the probe. The raw output is reported on stderr as one truncated line for
   diagnosis; the multi-line filesystem block never reaches the suite output.
3. The suite self-tests the probe once at startup on a file and a directory
   with known, non-default modes, so a future regression fails on a line that
   says "file_mode", before any recall behaviour is tested.
4. The `tests` job is green on the PR and on main after merge.

## Non-goals

- No change to `recall.py` or to any assertion's expected value. The modes
  under test (`700`, `600`) are correct; only the probe is wrong.
- No macOS runner in CI. The suite is verified on macOS by hand and on Linux
  by CI (and locally through a GNU-stat shim, see Verification).
- No change to the `stat` calls in `zsh/functions.zsh`.
- No shared shell helper library. One helper in one suite is the whole surface.

## Design

### The probe

Replace line 42 with:

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

The stderr diagnostic keeps only the first line of the raw output, cut at 60
characters, so a filesystem block collapses to its `File:` line. The
`MODE-PROBE-BROKEN` token on stdout is what the assertion compares against.

Behaviour by platform (both verified locally on 2026-09-05; `gstat` stands
in for GNU coreutils on macOS):

| Platform | `stat -c %a` | `stat -f %Lp` | Result |
| --- | --- | --- | --- |
| GNU coreutils (Linux CI) | prints `700`, exit 0 | not reached | `700` |
| BSD (macOS) | `illegal option -- c`, exit 1, empty stdout | prints `700`, exit 0 | `700` |
| Any stat printing junk on `-c` | non-octal, exit 0 | not reached | `MODE-PROBE-BROKEN` |
| Any stat rejecting `-c`, junk on `-f` | exit 1, empty stdout | non-octal, exit 0 | `MODE-PROBE-BROKEN` |

The guard accepts four digits so a setuid/setgid/sticky mode (`4755`,
`1777`) is not misreported as broken; the assertions in this suite only ever
expect three digits.

### The self-test

Insert immediately after the helper definitions and before `== unit tests`:

```bash
echo "== probe self-test"
PROBE=$(mktemp -d)
mkdir "$PROBE/d"; chmod 750 "$PROBE/d"
touch "$PROBE/f"; chmod 640 "$PROBE/f"
assert_eq "file_mode reads dir mode" "$(file_mode "$PROBE/d")" 750
assert_eq "file_mode reads file mode" "$(file_mode "$PROBE/f")" 640
```

Modes `750` and `640` are chosen because they match neither the suite's
expected values nor a typical umask result, so the self-test cannot pass by
coincidence. The two assertions raise the suite's pass count from 115 to 117.

### Failure shape

With a broken probe the suite output contains lines of the form:

```
  FAIL file_mode reads dir mode
     expected [750] got [MODE-PROBE-BROKEN]
```

and the final line reports a non-zero failure count, so `bin/dotfiles-tests`
and CI go red on a line that names the probe.

## Acceptance criteria

- AC1: On macOS with BSD `stat` first on `PATH`, the suite prints
  `117 passed, 0 failed` and exits 0. Baseline before the change: `115
  passed, 0 failed`.
- AC2: With GNU coreutils `stat` first on `PATH` (natively on
  `ubuntu-latest`; locally via a `stat` symlink to `gstat` prepended to
  `PATH`), the suite prints `117 passed, 0 failed` and exits 0.
- AC3a: With a `stat` on `PATH` that prints a fake multi-line filesystem
  block (first line `  File: junk`, second line `Block size: junk`) and exits
  0 for every invocation, the suite exits non-zero, its combined output
  contains `MODE-PROBE-BROKEN`, both `file_mode reads ... mode` assertions
  report `FAIL`, and the combined output does not contain `Block size`.
- AC3b: With a `stat` on `PATH` that exits 1 with empty stdout when its first
  argument is `-c` and otherwise prints the same fake block and exits 0 (the
  BSD-shaped failure), the suite behaves exactly as in AC3a.
- AC4: After the branch-only artifacts are removed, the only path that
  differs from `ed5f036` is
  `claude/skills/repo-recall/scripts/tests/recall_test.sh`. On the branch,
  `git diff --name-only ed5f036 -- . ':(exclude)docs' ':(exclude)claude/contracts/td-2026-09-04-fix-recall-test-file-mode-check-so-ci-passes-on-li-contract.json'`
  prints exactly that one path.
- AC5: The `tests` workflow is green on the PR and on main after merge
  (human-verified from the GitHub Actions run; CI is the only Linux
  execution the repo owns).

## Verification

Three local runs, all from the worktree root with `HOME` pointed at a
temporary directory so nothing under the real config dirs is touched:

1. Native: `bash claude/skills/repo-recall/scripts/tests/recall_test.sh`.
2. GNU emulation: prepend a temp dir containing `stat -> $(command -v gstat)`
   to `PATH`, then run the suite. `gstat` is Homebrew coreutils, present on
   the development machine at `/opt/homebrew/bin/gstat`; the step fails
   loudly if it is absent rather than skipping.
3. Broken probe, GNU-shaped (AC3a): prepend a temp dir containing a `stat`
   shell script that prints the fake block and exits 0, run the suite, and
   assert a non-zero exit, `MODE-PROBE-BROKEN` present, `Block size` absent.
4. Broken probe, BSD-shaped (AC3b): same, with a `stat` script that exits 1
   on `-c` and prints the fake block on anything else.

Nothing else in the suite invokes a `stat` binary (checked with `rg` on
2026-09-05: the only hits are the four `file_mode` call sites), so the shims
cannot change any other assertion's behaviour.

## Risks

- A `stat` that accepts `-c` but prints a different format (busybox prints
  `%a` identically; no other variant is expected in CI or on developer
  machines). The guard turns any such surprise into a named failure rather
  than a silent pass.
- `gstat` absent on a future development machine: verification step 2 fails
  loudly and CI remains the authoritative Linux run.

## Review log

- Revision 1: initial spec.
- Revision 2: Codex spec review round 1 (verdict minor-fixes). Folded:
  diagnostic truncated to one line so the filesystem dump never reaches suite
  output (medium); added the BSD-shaped broken-stat case AC3b (low); named
  the contract path and the exact diff command in AC4 (low).
- Codex plan review round 1 (verdict minor-fixes) changed no requirement;
  its folds live in the plan's review log.
