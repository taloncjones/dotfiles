# Codex Voice Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a self-contained `voice` skill under `claude/skills/voice/` whose script lints outward-facing text deterministically, asks Codex (`gpt-6-astra`) for a rewrite with invariant checks, reports before/after, and never posts.

**Architecture:** One stdlib Python script (`scripts/voice.py`) with two subcommands. `lint` is a table of regex rules and needs no model. `rewrite` assembles a prompt from `rules.md` plus a per-kind addendum, runs `codex exec` in an empty scratch dir with a JSON output schema, verifies per-kind invariants (URLs, Jira keys, fences, inline spans, protected lines) on the way back, and prints a diff-plus-changes report with the exact apply command for a human. Test seams are two env vars (`VOICE_CODEX_BIN`, `VOICE_GH_BIN`) pointed at fakes under `scripts/tests/`. Posting-path integration is a documented call-site table in `SKILL.md`, not edits to other skills.

**Tech Stack:** Python 3 stdlib (`argparse`, `difflib`, `json`, `re`, `shlex`, `subprocess`, `tempfile`), bash test script in the repo's `ok/bad` + `N passed, N failed` convention, `grep -rIF` for repo-local reference search, `git` for the repo root.

**Spec:** `docs/specs/2026-09-06-codex-voice-pass.md`

## Global Constraints

- Run every command from the worktree root `/Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass`; every `git` call uses `git -C <that path>`.
- Do NOT edit `claude/skills/co-review`, `codex-plan-review`, `codex-spec-review`, `ship`, `post-merge`, `claude/commands/pr.md`, `claude/commands/jira.md`, `codex/AGENTS.md`, or anything under `codex/skills/`. The contract's `review-skills-untouched` command fails the task if any of them differ from base `41dd7a1`.
- Only two files outside `claude/skills/voice/` change: `claude/skills/.gitignore` (add `!/voice/`) and `bin/dotfiles-tests` (add the suite line).
- Codex pin: `-m gpt-6-astra`, `-c model_reasoning_effort="high"` default, `xhigh` via `--effort xhigh`. Always `-c approval_policy="never" -c sandbox_mode="read-only" -C <empty scratch dir> --skip-git-repo-check --ephemeral --output-schema <file> -o <file>`, prompt on stdin (`codex exec -`).
- Exit codes: `0` nothing to change (`unchanged`, `empty`, dry-run), `1` findings or rewrite proposed, `2` error. Multi-unit runs exit with the max.
- `voice.py` is `#!/usr/bin/env python3`, executable, stdlib only, pure ASCII (emoji ranges as `\U` escapes), no emoji, no attribution. Every new file is ASCII.
- The repo's attribution guards block Bash commands that contain an AI co-author trailer. Write files with the Write/Edit tools, never Bash heredocs, and in `voice.py` build the trailer pattern from two string fragments (see Task 1) so the file itself never holds the phrase.
- Commit messages: `skills: <summary>` (imperative, under 75 chars). Do not use the word "claude" or the standalone word "AI" in a message; `commit_guard.py` blocks both.
- Test convention: `ok`/`bad` helpers, `PASS`/`FAIL` counters, final line `voice: N passed, M failed`, exit 1 on any failure. Tests run under `HOME=$(mktemp -d)` where they touch anything user-level (they should not).
- Baseline before Task 1 (record it in the first commit body): `bash bin/dotfiles-tests --list | wc -l` = 19 suites.

---

### Task 1: Lint layer, fixtures, test harness, registration

**Files:**
- Create: `claude/skills/voice/scripts/voice.py`
- Create: `claude/skills/voice/scripts/tests/voice_test.sh`
- Create: `claude/skills/voice/scripts/tests/fixtures/pr_body_generated.md`
- Create: `claude/skills/voice/scripts/tests/fixtures/pr_body_clean.md`
- Create: `claude/skills/voice/scripts/tests/fixtures/jira_title_generated.txt`
- Create: `claude/skills/voice/scripts/tests/fixtures/jira_title_clean.txt`
- Modify: `claude/skills/.gitignore` (append `!/voice/` after `!/wrap/`)
- Modify: `bin/dotfiles-tests:39` (add the suite line after the `recall_test.sh` line)

**Interfaces:**
- Produces: `voice.py lint --kind K (--file F | --stdin)`; Python functions `lint_text(kind, text) -> list[str]`, `read_input(args) -> str`, `VoiceError`, `TEXT_KINDS`, `ALL_KINDS`, `ADDENDA`; `main(argv) -> int`. Task 2 replaces the `cmd_rewrite` stub.
- Produces: the test harness helpers `ok`, `bad`, `assert_eq`, `assert_contains`, `assert_not_contains`, `run_voice` (sets `OUT`, `ERR`, `RC`), `FIX` (fixtures dir), `VOICE` (script path). Later tasks append test blocks to this file.

- [ ] **Step 1: Write the fixtures**

`claude/skills/voice/scripts/tests/fixtures/pr_body_generated.md` (the fake Codex's trigger substrings `This PR introduces`, `comprehensive and robust `, `In order to `, and the `## Notes` line must stay; Task 2's suite asserts they are present):

```markdown
## Description

This PR introduces a comprehensive and robust voice pass for outward text. In order to keep things clean, it might also help with Jira titles.

- Added voice.py
- Added the test suite
- Updated the gitignore

## Notes

## Test plan

- Ran the suite

[DOT-42](https://example.atlassian.net/browse/DOT-42)
```

`claude/skills/voice/scripts/tests/fixtures/pr_body_clean.md`:

```markdown
## Description

Adds a voice pass that rewrites PR and Jira text before it is posted. The pass runs Codex as a second model and never posts on its own.

## Test plan

- Fixture suite passes on macOS and Linux.
- Dry-run prints the prompt without calling Codex.

[DOT-42](https://example.atlassian.net/browse/DOT-42)
```

`claude/skills/voice/scripts/tests/fixtures/jira_title_generated.txt` (one line, no trailing text):

```
Update voice.py lint_text() to handle the comprehensive new edge cases in the parser module for titles
```

`claude/skills/voice/scripts/tests/fixtures/jira_title_clean.txt`:

```
Flag generated-sounding PR text before it is posted
```

- [ ] **Step 2: Write the failing test harness with the lint cases**

`claude/skills/voice/scripts/tests/voice_test.sh`:

```bash
#!/usr/bin/env bash
# Test suite for voice.py. No network, no user-level writes: Codex and gh are
# replaced by fakes via VOICE_CODEX_BIN / VOICE_GH_BIN.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VOICE="$HERE/../voice.py"
FIX="$HERE/fixtures"
export HOME
HOME=$(mktemp -d)
SANDBOX=$(mktemp -d)

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq()           { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains()     { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] missing [$3]";; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "[$2] contains [$3]";; *) ok "$1";; esac; }

# run_voice args...: run voice.py, capture stdout in OUT, stderr in ERR, exit in RC.
run_voice() {
  OUT=$(python3 "$VOICE" "$@" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}

echo "== lint: generated PR body"
run_voice lint --kind pr-body --file "$FIX/pr_body_generated.md"
assert_eq "generated body exits 1" "$RC" 1
assert_contains "flags filler" "$OUT" "filler: comprehensive"
assert_contains "flags In order to" "$OUT" "filler: In order to"
assert_contains "flags hedge" "$OUT" "hedge: might"
assert_contains "flags empty heading" "$OUT" "empty-heading: ## Notes"

echo "== lint: clean PR body"
run_voice lint --kind pr-body --file "$FIX/pr_body_clean.md"
assert_eq "clean body exits 0" "$RC" 0
assert_eq "clean body prints nothing" "$OUT" ""

echo "== lint: jira titles"
run_voice lint --kind jira-title --file "$FIX/jira_title_generated.txt"
assert_eq "generated title exits 1" "$RC" 1
assert_contains "flags word count" "$OUT" "title-shape: 16 words, over 12"
assert_contains "flags filename" "$OUT" "title-shape: filename voice.py"
assert_contains "flags function call" "$OUT" "title-shape: function call lint_text()"
run_voice lint --kind jira-title --file "$FIX/jira_title_clean.txt"
assert_eq "clean title exits 0" "$RC" 0
assert_eq "clean title prints nothing" "$OUT" ""

echo "== lint: pr title shape"
OUT=$(printf 'Added a thing' | python3 "$VOICE" lint --kind pr-title --stdin); RC=$?
assert_eq "title without scope exits 1" "$RC" 1
assert_contains "flags missing scope" "$OUT" "title-shape: missing <scope>: prefix"
OUT=$(printf 'skills: Add voice pass' | python3 "$VOICE" lint --kind pr-title --stdin); RC=$?
assert_eq "scoped short title exits 0" "$RC" 0

echo "== lint: emoji and attribution (fixture built at run time)"
# The trailer is assembled from fragments so the repo's own attribution guards
# never see it as one string in a committed file.
printf 'Ship it \xf0\x9f\x9a\x80\n\nCo-authored' > "$SANDBOX/mixed.md"
printf -- '-by: Claude <noreply@example.com>\n' >> "$SANDBOX/mixed.md"
run_voice lint --kind pr-comment --file "$SANDBOX/mixed.md"
assert_eq "mixed exits 1" "$RC" 1
assert_contains "flags emoji" "$OUT" "emoji: U+1F680"
assert_contains "flags attribution" "$OUT" "attribution: Co-authored"

echo "== lint: input errors"
run_voice lint --kind nope --file "$FIX/pr_body_clean.md"
assert_eq "unknown kind exits 2" "$RC" 2
assert_contains "unknown kind names the kinds" "$ERR" "pr-body"
run_voice lint --kind pr-body
assert_eq "no input source exits 2" "$RC" 2

printf 'voice: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 3: Run the suite to verify it fails**

Run: `bash claude/skills/voice/scripts/tests/voice_test.sh`
Expected: the suite is red (exit 1). Nearly every case FAILs because python3 cannot find `voice.py`; the three cases that expect exit `2` or empty output pass vacuously (a missing script also exits 2 with empty stdout). Final line `voice: 3 passed, 19 failed`.

- [ ] **Step 4: Write `voice.py` with the lint layer and the CLI**

`claude/skills/voice/scripts/voice.py` (make it executable: `chmod +x`):

```python
#!/usr/bin/env python3
"""voice.py - a second-model voice pass for outward-facing text.

    voice.py lint    --kind K (--file F | --stdin)
    voice.py rewrite --kind K (--file F | --stdin | --pr N | --range F:A-B)
                     [--effort high|xhigh] [--dry-run] [--json]

lint applies a fixed table of mechanical checks and needs no model.
rewrite asks Codex for a rewrite, verifies invariants on the way back, and
prints a before/after report with the exact apply command. It never posts.

Exit codes: 0 nothing to change, 1 findings or a rewrite proposed, 2 error.
A run with several units (--pr gives title and body) exits with the max.
"""
import argparse
import difflib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
RULES_PATH = os.path.join(HERE, "..", "rules.md")
CODEX_MODEL = "gpt-6-astra"
TEXT_KINDS = ("pr-title", "pr-body", "pr-comment",
              "jira-title", "jira-description", "jira-comment")
ALL_KINDS = TEXT_KINDS + ("code-comment",)

ADDENDA = {
    "pr-title": "Shape: `<scope>: <summary>`, imperative mood, under 75 characters.",
    "pr-body": ("Keep the Description and Test plan sections. Keep the Jira link "
                "line at the bottom byte-for-byte."),
    "pr-comment": "Lead with the verdict. No process narration.",
    "jira-title": ("State the outcome or impact in 6-10 plain words. No codenames, "
                   "filenames, function names, error codes, or unexpanded "
                   "abbreviations."),
    "jira-description": ("Short declaratives, one meaning per word. No template "
                         "heading with nothing under it."),
    "jira-comment": "Current state first. No process narration.",
    "code-comment": ("Tighten each candidate line; never delete one. Return code "
                     "and protected lines exactly as given."),
}


class VoiceError(Exception):
    """Fatal, user-facing; main() prints it and exits 2."""


# --- lint: table of mechanical rules, no model -----------------------------

EMOJI_RE = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\uFE0F]")
# The trailer pattern is built from two fragments so this file never holds
# the phrase the repo's attribution guards look for.
_TRAILER = "co-authored" + "-by:"
ATTRIBUTION_RES = [
    re.compile(r"^" + _TRAILER + r".*\b(claude|anthropic|copilot|chatgpt|gpt|codex|openai)\b",
               re.I | re.M),
    re.compile(r"generated (by|with)\b.*\b(claude|anthropic|copilot|chatgpt|gpt|codex|openai|ai)\b",
               re.I),
    re.compile(r"\b(written by ai|ai-generated)\b", re.I),
]
FILLER_WORDS = ("comprehensive", "robust", "seamless", "leverage", "delve",
                "streamline", "it is worth noting", "in order to")
FILLER_RES = [re.compile(r"\b" + re.escape(w) + r"\b", re.I) for w in FILLER_WORDS]
FILLER_RES.append(re.compile(r"(?:^|\n|\. )(Ensures?)\b"))
HEDGE_WORDS = ("might", "may want to", "it seems", "should probably")
HEDGE_RES = [re.compile(r"\b" + re.escape(w) + r"\b", re.I) for w in HEDGE_WORDS]
HEADING_RE = re.compile(r"^#{1,6} \S.*$")
TITLE_TOKEN_RES = (
    ("filename", re.compile(r"\b\w+\.(?:py|sh|rs|md|json|yml|yaml|toml|js|ts)\b")),
    ("function call", re.compile(r"\w+\(\)")),
    ("identifier", re.compile(r"\b\w+_\w+\b|::")),
    ("code", re.compile(r"\b(?:0x[0-9A-Fa-f]+|E\d{3,})\b")),
)
PR_TITLE_RE = re.compile(r"^[a-z][a-z0-9/_-]*: \S")


def lint_emoji(kind, text):
    return ["emoji: U+%04X" % ord(m.group()) for m in EMOJI_RE.finditer(text)]


def lint_attribution(kind, text):
    out = []
    for rx in ATTRIBUTION_RES:
        for m in rx.finditer(text):
            out.append("attribution: " + m.group().strip())
    return out


def lint_filler(kind, text):
    out = []
    for rx in FILLER_RES:
        for m in rx.finditer(text):
            word = m.group(1) if m.groups() else m.group()
            out.append("filler: " + word.strip())
    return out


def lint_hedge(kind, text):
    out = []
    for rx in HEDGE_RES:
        for m in rx.finditer(text):
            out.append("hedge: " + m.group().strip())
    return out


def lint_empty_heading(kind, text):
    lines = text.splitlines()
    out = []
    for i, line in enumerate(lines):
        if not HEADING_RE.match(line):
            continue
        body = []
        for later in lines[i + 1:]:
            if HEADING_RE.match(later):
                break
            body.append(later)
        if not any(b.strip() for b in body):
            out.append("empty-heading: " + line.strip())
    return out


def lint_title_shape(kind, text):
    title = text.strip()
    out = []
    if kind == "jira-title":
        words = title.split()
        if len(words) > 12:
            out.append("title-shape: %d words, over 12" % len(words))
        if len(words) < 4:
            out.append("title-shape: %d words, under 4" % len(words))
        for label, rx in TITLE_TOKEN_RES:
            m = rx.search(title)
            if m:
                out.append("title-shape: %s %s" % (label, m.group()))
    elif kind == "pr-title":
        if not PR_TITLE_RE.match(title):
            out.append("title-shape: missing <scope>: prefix")
        if len(title) >= 75:
            out.append("title-shape: %d chars, 75 or more" % len(title))
    return out


LINT_RULES = (lint_emoji, lint_attribution, lint_filler, lint_hedge,
              lint_empty_heading, lint_title_shape)


def lint_text(kind, text):
    findings = []
    for rule in LINT_RULES:
        findings.extend(rule(kind, text))
    return findings


# --- CLI -------------------------------------------------------------------

def read_input(args):
    if getattr(args, "file", None):
        with open(args.file, encoding="utf-8") as f:
            return f.read()
    if getattr(args, "stdin", False):
        return sys.stdin.read()
    raise VoiceError("give one of --file, --stdin, --pr, or --range")


def check_kind(kind):
    if kind not in ALL_KINDS:
        raise VoiceError("unknown kind %r; kinds: %s" % (kind, ", ".join(ALL_KINDS)))


def cmd_lint(args):
    check_kind(args.kind)
    text = read_input(args)
    findings = lint_text(args.kind, text)
    for f in findings:
        print(f)
    return 1 if findings else 0


def cmd_rewrite(args):
    raise VoiceError("rewrite is not implemented yet")


def parse_args(argv):
    p = argparse.ArgumentParser(prog="voice.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("lint", "rewrite"):
        sp = sub.add_parser(name)
        sp.add_argument("--kind", default=None)
        sp.add_argument("--file")
        sp.add_argument("--stdin", action="store_true")
        if name == "rewrite":
            sp.add_argument("--pr", type=int)
            sp.add_argument("--range", dest="line_range",
                            help="FILE:A-B, code-comment only")
            sp.add_argument("--effort", choices=("high", "xhigh"), default="high")
            sp.add_argument("--dry-run", action="store_true")
            sp.add_argument("--json", dest="as_json", action="store_true")
    args = p.parse_args(argv)
    if args.kind is None and not (args.cmd == "rewrite" and args.pr is not None):
        p.error("%s requires --kind" % args.cmd)
    return args


def main(argv=None):
    args = parse_args(argv)
    try:
        if args.cmd == "lint":
            return cmd_lint(args)
        return cmd_rewrite(args)
    except VoiceError as e:
        sys.stderr.write("voice: %s\n" % e)
        return 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: Run the suite to verify the lint cases pass**

Run: `chmod +x claude/skills/voice/scripts/voice.py && bash claude/skills/voice/scripts/tests/voice_test.sh`
Expected: final line `voice: 22 passed, 0 failed`, exit 0. If `title-shape: 16 words` mismatches, count the words in the generated title fixture and fix the fixture, not the assertion.

- [ ] **Step 6: Register the suite and whitelist the skill directory**

Append to `claude/skills/.gitignore` after the `!/wrap/` line:

```
!/voice/
```

Insert into `bin/dotfiles-tests` after the line `bash claude/skills/repo-recall/scripts/tests/recall_test.sh`:

```
bash claude/skills/voice/scripts/tests/voice_test.sh
```

Run: `bash bin/dotfiles-tests --list | grep -c voice_test`
Expected: `1`.

- [ ] **Step 7: Commit**

```bash
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass add claude/skills/.gitignore bin/dotfiles-tests claude/skills/voice/scripts/voice.py claude/skills/voice/scripts/tests/voice_test.sh claude/skills/voice/scripts/tests/fixtures
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass commit -m "skills: Add voice lint layer with fixtures and suite registration"
```

---

### Task 2: Rules, prompt, Codex runner, text-kind rewrite, fake Codex

**Files:**
- Create: `claude/skills/voice/rules.md`
- Create: `claude/skills/voice/scripts/tests/fake_codex.py`
- Modify: `claude/skills/voice/scripts/voice.py` (replace the `cmd_rewrite` stub; add the rewrite section between the lint section and the CLI section)
- Modify: `claude/skills/voice/scripts/tests/voice_test.sh` (append a rewrite block before the final `printf`)

**Interfaces:**
- Consumes: `lint_text`, `ADDENDA`, `TEXT_KINDS`, `VoiceError`, `read_input` from Task 1.
- Produces: `read_rules() -> str`, `build_prompt(kind, text, rows=None) -> str`, `schema_for(kind) -> dict`, `run_codex(prompt, kind, effort, workdir) -> dict`, `check_invariants(kind, before, after) -> list[str]`, `normalize(text) -> str`, `make_report(kind, target, text, lint, after, changes, protected, apply, status) -> dict`, `report_text(report) -> str`, `run_text_unit(kind, target, text, args, workdir, apply) -> dict`, `emit(reports, args) -> int`. The report dict keys are `kind, target, status, lint, before, after, diff, changes, protected, apply`; `status` is one of `dry-run, empty, unchanged, changed`. Tasks 3 and 4 add units that produce the same dict.
- Produces: `fake_codex.py` honoring `-o <file>` and env `FAKE_CODEX_MODE` (`rewrite` default, `drop-link`, `fail`, `touch-protected`) and `FAKE_CODEX_MARKER` (path appended to on every call).

- [ ] **Step 1: Write `rules.md`**

Line 3 is quoted by the contract's dry-run check; keep it exactly as written.

```markdown
# Voice rules

Rewrite the text so a careful engineer would read it as written by a person, not generated.

Keep the meaning. Change the voice. Apply every rule below to the whole
text, not only the first paragraph.

- Lead with the verdict or the outcome. Say what changed or what is true
  before saying why.
  Before: "After careful consideration of the options, we decided to
  switch to a queue." After: "Switched to a queue. Polling missed bursts."
- Short declarative sentences, one fact each, active voice.
  Before: "This change, which was needed because of the race, ensures
  that the flag is set." After: "Set the flag before the read. A race
  cleared it."
- One meaning per word. Cut stacked adjectives and filler: comprehensive,
  robust, seamless, leverage, delve, streamline, in order to.
  Before: "A comprehensive and robust fix." After: "A fix."
- No hedging. State what is known; name what is not.
  Before: "This might help with the timeout." After: "Raises the timeout
  to 30s. Untested under load."
- No process narration. Describe the state, not the journey.
  Before: "After re-running the review pass, the finding was resolved."
  After: "Resolved: the null check is in place."
- Do not restate a diff as bullets. Summarise the intent in one or two
  sentences; keep a bullet only when it carries a decision or a caveat.
- Delete template headings with nothing under them. Keep headings that
  have content.
- Jira titles: the outcome or impact in 6-10 plain words. No codenames,
  filenames, function names, error codes, or unexpanded abbreviations.
  Before: "svc: NewMode in Handler::tick()" After: "Add operating mode
  for shared resources"
- No attribution to a tool or model. No emoji; use [OK], [X], [INFO].
- Comments get tightened, never deleted. A shorter comment that says the
  same thing is the goal.
- Copy every URL, ticket key, code span, and fenced block byte-for-byte.
  Copy every line marked code or protected byte-for-byte.
```

- [ ] **Step 2: Write `fake_codex.py`**

`claude/skills/voice/scripts/tests/fake_codex.py` (make executable):

```python
#!/usr/bin/env python3
"""Deterministic stand-in for `codex exec`. Reads the prompt on stdin, applies
a fixed substitution table, writes the JSON answer to the -o path.

FAKE_CODEX_MODE: rewrite (default) | drop-link | fail | touch-protected
FAKE_CODEX_MARKER: file appended to on every invocation
"""
import json
import os
import sys

SUBS = [
    ("This PR introduces", "Adds", "verdict-first"),
    ("comprehensive and robust ", "", "filler"),
    ("In order to ", "To ", "filler"),
    ("## Notes\n", "", "empty-heading"),
]


def fix(text):
    changes = []
    for before, after, rule in SUBS:
        if before in text:
            text = text.replace(before, after)
            changes.append({"before": before.strip(), "after": after.strip(),
                            "rule": rule})
    return text, changes


def main():
    args = sys.argv[1:]
    out_path = args[args.index("-o") + 1]
    prompt = sys.stdin.read()
    marker = os.environ.get("FAKE_CODEX_MARKER")
    if marker:
        with open(marker, "a") as f:
            f.write("called\n")
    mode = os.environ.get("FAKE_CODEX_MODE", "rewrite")
    if mode == "fail":
        sys.stderr.write("fake codex: simulated failure\n")
        return 3
    if "=== LINES ===\n" in prompt:
        rows = prompt.split("=== LINES ===\n", 1)[1].splitlines()
        lines, changes = [], []
        for row in rows:
            if not row:
                continue
            n, status, text = row.split("|", 2)
            if status == "candidate":
                text, more = fix(text)
                changes.extend(more)
            elif status == "protected" and mode == "touch-protected":
                text = text + " (edited)"
            lines.append({"n": int(n), "text": text})
        data = {"lines": lines, "changes": changes}
    else:
        text = prompt.split("=== TEXT ===\n", 1)[1]
        text, changes = fix(text)
        if mode == "drop-link":
            text = "\n".join(l for l in text.splitlines() if "/browse/" not in l) + "\n"
        data = {"rewritten": text, "changes": changes}
    with open(out_path, "w") as f:
        json.dump(data, f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: Append the failing rewrite tests**

Insert before the final `printf 'voice: ...'` line of `voice_test.sh`:

```bash
echo "== rewrite: fake codex wiring"
export VOICE_CODEX_BIN="$HERE/fake_codex.py"
export FAKE_CODEX_MARKER="$SANDBOX/codex-called"
# The fake only rewrites when its trigger substrings are present; assert the
# coupling so a fixture edit fails here, not as a mystery in AC5.
for trigger in "This PR introduces" "comprehensive and robust " "In order to " "## Notes"; do
  grep -qF -- "$trigger" "$FIX/pr_body_generated.md" && ok "fixture keeps trigger [$trigger]" \
    || bad "fixture keeps trigger [$trigger]" "missing from pr_body_generated.md"
done

echo "== rewrite: generated PR body is rewritten (AC5)"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md"
assert_eq "rewrite exits 1" "$RC" 1
assert_contains "report header" "$OUT" "VOICE pr-body $FIX/pr_body_generated.md: 4 changes"
assert_contains "lint echoed" "$OUT" "hedge: might"
assert_contains "diff marker" "$OUT" "+++ after"
assert_contains "diff drops filler" "$OUT" "-This PR introduces a comprehensive and robust"
assert_contains "changes list rule" "$OUT" "1. verdict-first:"
assert_contains "apply hint" "$OUT" "Apply with:"
assert_contains "codex called once" "$(cat "$FAKE_CODEX_MARKER")" "called"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md" --json
python3 -c 'import json,sys; d=json.load(sys.stdin); assert "https://example.atlassian.net/browse/DOT-42)" in d[0]["after"]' <<<"$OUT" \
  && ok "jira link survives in after" || bad "jira link survives in after" "$OUT"

echo "== rewrite: clean PR body comes back unchanged (AC6)"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_clean.md"
assert_eq "unchanged exits 0" "$RC" 0
assert_contains "reports unchanged" "$OUT" "VOICE pr-body $FIX/pr_body_clean.md: unchanged"
assert_not_contains "no diff on unchanged" "$OUT" "+++ after"

echo "== rewrite: dropped Jira link is an invariant violation (AC7)"
FAKE_CODEX_MODE=drop-link run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md"
assert_eq "invariant violation exits 2" "$RC" 2
assert_contains "names the violation" "$ERR" "invariant violated: url https://example.atlassian.net/browse/DOT-42"
assert_not_contains "no candidate shown" "$OUT" "+++ after"

echo "== rewrite: codex failure (AC11)"
FAKE_CODEX_MODE=fail run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md"
assert_eq "codex failure exits 2" "$RC" 2
assert_contains "names exit code" "$ERR" "codex exited 3"
assert_contains "names log path" "$ERR" "log: "
LOGPATH=${ERR##*log: }
[ -f "$LOGPATH" ] && ok "log file exists" || bad "log file exists" "$LOGPATH"

echo "== rewrite: dry-run never invokes codex (AC10)"
rm -f "$FAKE_CODEX_MARKER"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md" --dry-run
assert_eq "dry-run exits 0" "$RC" 0
assert_contains "prompt has rules line 3" "$OUT" "$(sed -n '3p' "$HERE/../../rules.md")"
assert_contains "prompt has addendum" "$OUT" "=== KIND: pr-body ==="
assert_contains "prompt has text" "$OUT" "=== TEXT ==="
assert_contains "prompt has the input" "$OUT" "This PR introduces a comprehensive"
[ -e "$FAKE_CODEX_MARKER" ] && bad "codex not called on dry-run" "marker exists" || ok "codex not called on dry-run"

echo "== rewrite: empty input"
OUT=$(printf '' | python3 "$VOICE" rewrite --kind pr-comment --stdin); RC=$?
assert_eq "empty exits 0" "$RC" 0
assert_contains "reports empty" "$OUT" "VOICE pr-comment stdin: empty"

echo "== rewrite: json output is always an array"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_clean.md" --json
assert_eq "json exit 0" "$RC" 0
python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list) and len(d)==1 and d[0]["status"]=="unchanged"' <<<"$OUT" \
  && ok "json is a one-element array" || bad "json is a one-element array" "$OUT"
```

- [ ] **Step 4: Run the suite to verify the new block fails**

Run: `bash claude/skills/voice/scripts/tests/voice_test.sh`
Expected: the Task 1 cases pass; every `rewrite:` case fails with `voice: rewrite is not implemented yet` (RC 2). Exit 1.

- [ ] **Step 5: Implement the rewrite section**

In `voice.py`, delete the `cmd_rewrite` stub and insert this section between the lint section and `# --- CLI ---`:

```python
# --- rewrite: prompt, Codex call, invariants, report -----------------------

INVARIANT_EXTRACTORS = {
    "url": re.compile(r"https?://\S+"),
    "jira-key": re.compile(r"\b[A-Z][A-Z0-9]+-[0-9]+\b"),
    "fence": re.compile(r"```.*?```", re.S),
    "inline": re.compile(r"`[^`\n]+`"),
}
INVARIANTS_BY_KIND = {
    "pr-title": ("url", "jira-key"),
    "jira-title": ("url", "jira-key"),
    "pr-comment": ("url", "jira-key", "fence"),
    "jira-comment": ("url", "jira-key", "fence"),
    "pr-body": ("url", "jira-key", "fence", "inline"),
    "jira-description": ("url", "jira-key", "fence", "inline"),
    "code-comment": (),
}


def read_rules():
    with open(RULES_PATH, encoding="utf-8") as f:
        return f.read()


def invariants_text(kind):
    names = INVARIANTS_BY_KIND[kind]
    if kind == "code-comment":
        return "Every line whose status is code or protected comes back byte-identical."
    return "Copy byte-for-byte every: %s." % ", ".join(names)


def build_prompt(kind, text, rows=None):
    parts = [read_rules().rstrip("\n"), "",
             "=== KIND: %s ===" % kind, ADDENDA[kind], "",
             "=== INVARIANTS ===", invariants_text(kind), "",
             "=== OUTPUT ==="]
    if kind == "code-comment":
        parts += ['Return JSON: {"lines": [{"n": <line number>, "text": <line>}], '
                  '"changes": [{"before": ..., "after": ..., "rule": ...}]} with '
                  "exactly one entry per input line, in order.", "",
                  "=== LINES ==="]
        parts += ["%d|%s|%s" % (n, status, line) for n, status, line, _ in rows]
    else:
        parts += ['Return JSON: {"rewritten": <the full text>, '
                  '"changes": [{"before": ..., "after": ..., "rule": ...}]}.', "",
                  "=== TEXT ===", text]
    prompt = "\n".join(parts)
    # Text ends the prompt; do not add a newline the input did not have, or
    # the model's faithful copy diffs against the input at EOF.
    return prompt if prompt.endswith("\n") else prompt + "\n"


def schema_for(kind):
    change = {"type": "object",
              "properties": {"before": {"type": "string"},
                             "after": {"type": "string"},
                             "rule": {"type": "string"}},
              "required": ["before", "after", "rule"],
              "additionalProperties": False}
    if kind == "code-comment":
        line = {"type": "object",
                "properties": {"n": {"type": "integer"}, "text": {"type": "string"}},
                "required": ["n", "text"], "additionalProperties": False}
        props = {"lines": {"type": "array", "items": line},
                 "changes": {"type": "array", "items": change}}
    else:
        props = {"rewritten": {"type": "string"},
                 "changes": {"type": "array", "items": change}}
    return {"type": "object", "properties": props,
            "required": list(props), "additionalProperties": False}


def run_codex(prompt, kind, effort, workdir):
    scratch = tempfile.mkdtemp(prefix="scratch.", dir=workdir)
    prompt_path = os.path.join(workdir, "prompt.txt")
    schema_path = os.path.join(workdir, "schema.json")
    last_path = os.path.join(workdir, "last.json")
    log_path = os.path.join(workdir, "codex.log")
    with open(prompt_path, "w", encoding="utf-8") as f:
        f.write(prompt)
    with open(schema_path, "w") as f:
        json.dump(schema_for(kind), f)
    cmd = [os.environ.get("VOICE_CODEX_BIN", "codex"), "exec", "-",
           "-m", CODEX_MODEL,
           "-c", 'model_reasoning_effort="%s"' % effort,
           "-c", 'approval_policy="never"',
           "-c", 'sandbox_mode="read-only"',
           "-C", scratch, "--skip-git-repo-check", "--ephemeral",
           "--output-schema", schema_path, "-o", last_path]
    with open(prompt_path, "rb") as pin, open(log_path, "wb") as log:
        rc = subprocess.call(cmd, stdin=pin, stdout=log, stderr=subprocess.STDOUT)
    if rc != 0:
        raise VoiceError("codex exited %d; log: %s" % (rc, log_path))
    try:
        with open(last_path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise VoiceError("codex output is not JSON (%s); log: %s" % (e, log_path))
    if not isinstance(data, dict) or not isinstance(data.get("changes"), list):
        raise VoiceError("codex output missing changes; log: %s" % log_path)
    for c in data["changes"]:
        if not all(isinstance(c.get(k), str) for k in ("before", "after", "rule")):
            raise VoiceError("codex change entry malformed; log: %s" % log_path)
    return data


def check_invariants(kind, before, after):
    missing = []
    for name in INVARIANTS_BY_KIND[kind]:
        for m in INVARIANT_EXTRACTORS[name].finditer(before):
            if m.group() not in after:
                missing.append("%s %s" % (name, m.group()))
    return missing


def normalize(text):
    return "\n".join(line.rstrip() for line in text.rstrip().splitlines())


def make_report(kind, target, text, lint, after=None, changes=None,
                protected=None, apply=None, status=None):
    if status is None:
        status = "unchanged" if normalize(after) == normalize(text) else "changed"
    diff = ""
    if status == "changed":
        diff = "".join(difflib.unified_diff(
            text.splitlines(True), after.splitlines(True), "before", "after"))
        if diff and not diff.endswith("\n"):
            diff += "\n"
    return {"kind": kind, "target": target, "status": status, "lint": lint,
            "before": text, "after": after if after is not None else text,
            "diff": diff, "changes": changes or [], "protected": protected or [],
            "apply": apply if status == "changed" else None}


def report_text(r):
    head = "%d changes" % len(r["changes"]) if r["status"] == "changed" else r["status"]
    lines = ["VOICE %s %s: %s" % (r["kind"], r["target"], head)]
    if r["lint"]:
        lines.append("Lint:")
        lines += ["  " + f for f in r["lint"]]
    if r["status"] == "changed":
        lines.append(r["diff"].rstrip("\n"))
        lines.append("Changes:")
        for i, c in enumerate(r["changes"], 1):
            lines.append('  %d. %s: "%s" -> "%s"' % (i, c["rule"], c["before"], c["after"]))
    if r["protected"]:
        lines.append("Protected (left alone):")
        lines += ["  " + p for p in r["protected"]]
    if r["apply"]:
        lines.append("Apply with:")
        lines += ["  " + a for a in r["apply"].splitlines()]
    return "\n".join(lines) + "\n"


def run_text_unit(kind, target, text, args, workdir, apply=None):
    lint = lint_text(kind, text)
    if not text.strip():
        return make_report(kind, target, text, lint, status="empty")
    prompt = build_prompt(kind, text)
    if args.dry_run:
        sys.stdout.write(prompt)
        return make_report(kind, target, text, lint, status="dry-run")
    unit_dir = tempfile.mkdtemp(prefix="unit.", dir=workdir)
    data = run_codex(prompt, kind, args.effort, unit_dir)
    after = data.get("rewritten")
    if not isinstance(after, str):
        raise VoiceError("codex output missing rewritten; log: %s"
                         % os.path.join(unit_dir, "codex.log"))
    missing = check_invariants(kind, text, after)
    if missing:
        raise VoiceError("invariant violated: " + "; ".join(missing))
    return make_report(kind, target, text, lint, after, data["changes"],
                       apply=apply or "paste the after block")


STATUS_RC = {"dry-run": 0, "empty": 0, "unchanged": 0, "changed": 1}


def emit(reports, args):
    if args.as_json:
        json.dump(reports, sys.stdout, indent=2)
        sys.stdout.write("\n")
    elif not args.dry_run:
        for r in reports:
            sys.stdout.write(report_text(r))
    return max(STATUS_RC[r["status"]] for r in reports)


def cmd_rewrite(args):
    workdir = tempfile.mkdtemp(prefix="voice.")
    if args.pr is not None:
        raise VoiceError("--pr is not implemented yet")
    if args.line_range:
        raise VoiceError("--range is not implemented yet")
    check_kind(args.kind)
    if args.kind == "code-comment":
        raise VoiceError("code-comment needs --range FILE:A-B")
    text = read_input(args)
    target = args.file if args.file else "stdin"
    reports = [run_text_unit(args.kind, target, text, args, workdir)]
    return emit(reports, args)
```

- [ ] **Step 6: Run the suite to verify it passes**

Run: `chmod +x claude/skills/voice/scripts/tests/fake_codex.py && bash claude/skills/voice/scripts/tests/voice_test.sh`
Expected: `voice: 55 passed, 0 failed` (22 from Task 1 plus 33 here), exit 0. If the "4 changes" header mismatches, print the report and compare against the four `SUBS` rows in `fake_codex.py`; the generated fixture must trigger all four.

- [ ] **Step 7: Commit**

```bash
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass add claude/skills/voice/rules.md claude/skills/voice/scripts/voice.py claude/skills/voice/scripts/tests/fake_codex.py claude/skills/voice/scripts/tests/voice_test.sh
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass commit -m "skills: Add voice rewrite with Codex runner, invariants, and fake"
```

---

### Task 3: PR target with fake gh

**Files:**
- Create: `claude/skills/voice/scripts/tests/fake_gh.sh`
- Modify: `claude/skills/voice/scripts/voice.py` (replace the `--pr` stub in `cmd_rewrite`; add `fetch_pr` and `pr_units`)
- Modify: `claude/skills/voice/scripts/tests/voice_test.sh` (append a PR block before the final `printf`)

**Interfaces:**
- Consumes: `run_text_unit`, `emit`, `make_report`, `VoiceError` from Task 2.
- Produces: `fetch_pr(number) -> (title: str, body: str)`; `pr_units(number, args, workdir) -> list[report]`. `fake_gh.sh` honours env `FAKE_GH_LOG` (argv appended per call) and `FAKE_GH_PR_JSON` (file served for `pr view`).

- [ ] **Step 1: Write `fake_gh.sh`**

`claude/skills/voice/scripts/tests/fake_gh.sh` (make executable):

```bash
#!/usr/bin/env bash
# Fake gh: appends every call to FAKE_GH_LOG, serves FAKE_GH_PR_JSON for
# `pr view`, and fails loudly on anything else (so an accidental `pr edit`
# shows up in the log AND as a non-zero exit).
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  cat "${FAKE_GH_PR_JSON:?}"
  exit 0
fi
echo "fake gh: unexpected call: $*" >&2
exit 1
```

- [ ] **Step 2: Append the failing PR tests**

```bash
echo "== rewrite: --pr target (AC9)"
export VOICE_GH_BIN="$HERE/fake_gh.sh"
export FAKE_GH_LOG="$SANDBOX/gh.log"
export FAKE_GH_PR_JSON="$SANDBOX/pr.json"
python3 - "$FIX/pr_body_generated.md" "$FAKE_GH_PR_JSON" <<'PY'
import json, sys
body = open(sys.argv[1]).read()
json.dump({"title": "skills: Add voice pass", "body": body}, open(sys.argv[2], "w"))
PY
: > "$FAKE_GH_LOG"
run_voice rewrite --pr 17
assert_eq "pr with rewritten body exits 1 (max rule)" "$RC" 1
assert_contains "title report unchanged" "$OUT" "VOICE pr-title PR #17 title: unchanged"
assert_contains "body report changed" "$OUT" "VOICE pr-body PR #17 body: 4 changes"
assert_contains "apply hint is gh pr edit" "$OUT" "gh pr edit 17 --body-file "
assert_eq "gh called exactly once" "$(wc -l < "$FAKE_GH_LOG" | tr -d ' ')" 1
assert_contains "gh call was pr view" "$(cat "$FAKE_GH_LOG")" "pr view 17 --json title,body"
assert_not_contains "no pr edit" "$(cat "$FAKE_GH_LOG")" "pr edit"
BODYFILE=$(printf '%s\n' "$OUT" | sed -n 's/^  gh pr edit 17 --body-file //p')
[ -f "$BODYFILE" ] && ok "body file written" || bad "body file written" "$BODYFILE"
assert_contains "body file holds the rewrite" "$(cat "$BODYFILE")" "Adds a voice pass"

run_voice rewrite --pr 17 --json
python3 -c 'import json,sys; d=json.load(sys.stdin); assert [r["kind"] for r in d]==["pr-title","pr-body"]' <<<"$OUT" \
  && ok "json array has title then body" || bad "json array has title then body" "$OUT"

echo "== rewrite: --pr with null body (AC9b)"
printf '{"title": "skills: Add voice pass", "body": null}\n' > "$FAKE_GH_PR_JSON"
run_voice rewrite --pr 18
assert_eq "null body exits 0" "$RC" 0
assert_contains "body reported empty" "$OUT" "VOICE pr-body PR #18 body: empty"

echo "== rewrite: --pr when gh fails"
printf 'not json' > "$FAKE_GH_PR_JSON"
run_voice rewrite --pr 19
assert_eq "bad gh json exits 2" "$RC" 2
assert_contains "names gh" "$ERR" "gh pr view"
```

- [ ] **Step 3: Run the suite to verify the block fails**

Run: `bash claude/skills/voice/scripts/tests/voice_test.sh`
Expected: PR cases fail with `--pr is not implemented yet`; all earlier cases pass.

- [ ] **Step 4: Implement the PR target**

Add after `run_text_unit` in `voice.py`:

```python
def fetch_pr(number):
    gh = os.environ.get("VOICE_GH_BIN", "gh")
    cmd = [gh, "pr", "view", str(number), "--json", "title,body"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        raise VoiceError("gh pr view failed to start: %s" % e)
    if proc.returncode != 0:
        raise VoiceError("gh pr view %d failed: %s" % (number, proc.stderr.strip()))
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        raise VoiceError("gh pr view %d returned non-JSON output" % number)
    return data.get("title") or "", data.get("body") or ""


def pr_units(number, args, workdir):
    title, body = fetch_pr(number)
    body_path = os.path.join(workdir, "pr-%d-body.md" % number)
    title_report = run_text_unit("pr-title", "PR #%d title" % number, title, args, workdir,
                                 apply="gh pr edit %d --title <after>" % number)
    if title_report["status"] == "changed":
        title_report["apply"] = "gh pr edit %d --title %s" % (
            number, shlex.quote(title_report["after"].strip()))
    body_report = run_text_unit("pr-body", "PR #%d body" % number, body, args, workdir,
                                apply="gh pr edit %d --body-file %s" % (number, body_path))
    if body_report["status"] == "changed":
        with open(body_path, "w", encoding="utf-8") as f:
            f.write(body_report["after"])
    return [title_report, body_report]
```

Replace the `--pr` stub line in `cmd_rewrite` with:

```python
    if args.pr is not None:
        return emit(pr_units(args.pr, args, workdir), args)
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `chmod +x claude/skills/voice/scripts/tests/fake_gh.sh && bash claude/skills/voice/scripts/tests/voice_test.sh`
Expected: `voice: 69 passed, 0 failed` (55 plus 14 here), exit 0. A `gh pr view failed to start` error means the fake is not executable.

- [ ] **Step 6: Commit**

```bash
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass add claude/skills/voice/scripts/voice.py claude/skills/voice/scripts/tests/fake_gh.sh claude/skills/voice/scripts/tests/voice_test.sh
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass commit -m "skills: Add voice --pr target that reads via gh and never edits"
```

---

### Task 4: Code-comment range with load-bearing protection

**Files:**
- Create: `claude/skills/voice/scripts/tests/fixtures/gui_repo/widgets.py`
- Create: `claude/skills/voice/scripts/tests/fixtures/gui_repo/gui.py`
- Modify: `claude/skills/voice/scripts/voice.py` (replace the `--range` stub; add the classification and range unit)
- Modify: `claude/skills/voice/scripts/tests/voice_test.sh` (append a range block before the final `printf`)

**Interfaces:**
- Consumes: `build_prompt(kind, text, rows)`, `run_codex`, `make_report`, `emit`, `VoiceError`.
- Produces: `parse_range(spec) -> (path, start, end)`, `repo_root(path) -> str`, `grep_files(needle, root, exclude_path) -> list[str]`, `referenced_elsewhere(text, root, path) -> str | None`, `docstring_displayed(owner, root, path) -> str | None`, `classify_range(path, start, end) -> list[(n, status, line, reason)]`, `run_range_unit(path, start, end, args, workdir) -> report`. Row statuses are exactly `code`, `protected`, `candidate`.

- [ ] **Step 1: Write the GUI fixture tree**

`claude/skills/voice/scripts/tests/fixtures/gui_repo/widgets.py`:

```python
# In order to run a comprehensive and robust check we call the checker here.
def run_check():
    """Runs a comprehensive and robust check of every widget.

    Displayed in the status bar by gui.py.
    """
    return True
```

`claude/skills/voice/scripts/tests/fixtures/gui_repo/gui.py`:

```python
from widgets import run_check

label_text = run_check.__doc__
```

- [ ] **Step 2: Append the failing range tests**

```bash
echo "== rewrite: code-comment range protects a displayed docstring (AC8)"
REPO="$SANDBOX/gui_repo"
cp -R "$FIX/gui_repo" "$REPO"
( cd "$REPO" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
run_voice rewrite --kind code-comment --range "$REPO/widgets.py:1-6"
assert_eq "range rewrite exits 1" "$RC" 1
assert_contains "comment line rewritten" "$OUT" "+# To run a check we call the checker here."
assert_contains "docstring protected reason" "$OUT" "widgets.py:3  protected: docstring displayed (run_check.__doc__ in gui.py)"
assert_not_contains "docstring not in diff" "$OUT" "-    \"\"\"Runs a comprehensive"
assert_contains "apply is line replacement" "$OUT" "replace line 1 with: # To run a check we call the checker here."
run_voice rewrite --kind code-comment --range "$REPO/widgets.py:1-6" --json
printf '%s\n' "$OUT" > "$SANDBOX/range.json"
python3 - "$SANDBOX/range.json" <<'PY' && ok "docstring byte-identical in after" || bad "docstring byte-identical in after" "$OUT"
import json, sys
r = json.load(open(sys.argv[1]))[0]
before = r["before"].splitlines(); after = r["after"].splitlines()
assert before[2:6] == after[2:6], (before[2:6], after[2:6])
assert after[0] == "# To run a check we call the checker here."
PY

echo "== rewrite: touched protected line is an invariant violation"
FAKE_CODEX_MODE=touch-protected run_voice rewrite --kind code-comment --range "$REPO/widgets.py:1-6"
assert_eq "touched protected exits 2" "$RC" 2
assert_contains "names the line" "$ERR" "invariant violated: line 3 changed"

echo "== rewrite: referenced-elsewhere comment is protected"
printf '# Keep this exact wording, the dashboard greps for it.\nx = 1\n' > "$REPO/other.py"
printf 'MARK = "Keep this exact wording, the dashboard greps for it."\n' > "$REPO/dash.py"
run_voice rewrite --kind code-comment --range "$REPO/other.py:1-1"
assert_eq "referenced comment unchanged exits 0" "$RC" 0
assert_contains "referenced reason" "$OUT" "other.py:1  protected: referenced elsewhere (dash.py)"

echo "== rewrite: --range guards (AC9c)"
rm -f "$FAKE_CODEX_MARKER"
run_voice rewrite --kind pr-body --range "$REPO/widgets.py:1-6"
assert_eq "range with wrong kind exits 2" "$RC" 2
assert_contains "names the rule" "$ERR" "--range requires --kind code-comment"
[ -e "$FAKE_CODEX_MARKER" ] && bad "codex not called on kind error" "marker exists" || ok "codex not called on kind error"
run_voice rewrite --kind code-comment --range "$REPO/widgets.py:5-99"
assert_eq "out of bounds exits 2" "$RC" 2
run_voice rewrite --kind code-comment --range "$REPO/widgets.py:1-6" --dry-run
assert_eq "range dry-run exits 0" "$RC" 0
assert_contains "dry-run lists rows" "$OUT" "3|protected|"
assert_contains "dry-run lists candidate" "$OUT" "1|candidate|# In order to"
assert_contains "dry-run lists code" "$OUT" "2|code|def run_check():"
```

- [ ] **Step 3: Run the suite to verify the block fails**

Run: `bash claude/skills/voice/scripts/tests/voice_test.sh`
Expected: range cases fail with `--range is not implemented yet`; earlier cases pass.

- [ ] **Step 4: Implement the range unit**

Add after `pr_units` in `voice.py`:

```python
RANGE_RE = re.compile(r"^(.+):(\d+)-(\d+)$")
DEF_RE = re.compile(r"^\s*(?:async\s+)?(?:def|class)\s+(\w+)")
COMMENT_PREFIXES = ("#", "//", "/*", "*")
MIN_REFERENCE_LEN = 12


def parse_range(spec):
    m = RANGE_RE.match(spec or "")
    if not m:
        raise VoiceError("--range must be FILE:A-B")
    return m.group(1), int(m.group(2)), int(m.group(3))


def repo_root(path):
    # realpath everywhere: on macOS mktemp gives /var/... while git reports
    # /private/var/..., and grep echoes whichever root it was handed. One
    # canonical form keeps the self-exclusion below and the relpath in the
    # reason strings consistent.
    proc = subprocess.run(["git", "-C", os.path.dirname(os.path.realpath(path)),
                           "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True)
    if proc.returncode == 0 and proc.stdout.strip():
        return os.path.realpath(proc.stdout.strip())
    return os.path.dirname(os.path.realpath(path))


def grep_files(needle, root, exclude_path):
    """Fixed-string, recursive, file names only; drops exclude_path itself."""
    proc = subprocess.run(["grep", "-rIlF", "--exclude-dir=.git", "--", needle, root],
                          capture_output=True, text=True)
    skip = os.path.realpath(exclude_path)
    hits = [h for h in proc.stdout.splitlines() if os.path.realpath(h) != skip]
    return sorted(hits)


def referenced_elsewhere(text, root, path):
    needle = text.strip().lstrip("#/* ").strip().rstrip('"').strip()
    if len(needle) < MIN_REFERENCE_LEN:
        return None
    hits = grep_files(needle, root, path)
    if hits:
        return "referenced elsewhere (%s)" % os.path.relpath(hits[0], root)
    return None


def docstring_displayed(owner, root, path):
    if not owner:
        return None
    for needle in (owner + ".__doc__", "getdoc(" + owner, owner + ".doc"):
        hits = grep_files(needle, root, path)
        if hits:
            return "docstring displayed (%s in %s)" % (needle, os.path.relpath(hits[0], root))
    return None


def classify_range(path, start, end):
    path = os.path.realpath(path)
    with open(path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    if start < 1 or end > len(lines) or start > end:
        raise VoiceError("range %d-%d out of bounds for %s (%d lines)"
                         % (start, end, path, len(lines)))
    root = repo_root(path)
    rows = []
    in_doc = False
    owner = None
    for n, line in enumerate(lines, 1):
        stripped = line.strip()
        m = DEF_RE.match(line)
        if m:
            owner = m.group(1)
        is_doc = False
        if in_doc:
            is_doc = True
            if '"""' in stripped:
                in_doc = False
        elif stripped.startswith('"""'):
            is_doc = True
            if stripped.count('"""') < 2:
                in_doc = True
        if not (start <= n <= end):
            continue
        if is_doc:
            reason = docstring_displayed(owner, root, path) or referenced_elsewhere(line, root, path)
        elif stripped.startswith(COMMENT_PREFIXES):
            reason = referenced_elsewhere(line, root, path)
        else:
            rows.append((n, "code", line, ""))
            continue
        if reason:
            rows.append((n, "protected", line, reason))
        else:
            rows.append((n, "candidate", line, ""))
    return rows


def run_range_unit(path, start, end, args, workdir):
    rows = classify_range(path, start, end)
    text = "\n".join(line for _, _, line, _ in rows) + "\n"
    target = "%s:%d-%d" % (path, start, end)
    lint = lint_text("code-comment", text)
    protected = ["%s:%d  protected: %s" % (os.path.basename(path), n, reason)
                 for n, status, _, reason in rows if status == "protected"]
    if not any(status == "candidate" for _, status, _, _ in rows):
        return make_report("code-comment", target, text, lint, protected=protected,
                           status="unchanged")
    prompt = build_prompt("code-comment", text, rows)
    if args.dry_run:
        sys.stdout.write(prompt)
        return make_report("code-comment", target, text, lint, status="dry-run")
    unit_dir = tempfile.mkdtemp(prefix="unit.", dir=workdir)
    data = run_codex(prompt, "code-comment", args.effort, unit_dir)
    got = data.get("lines")
    if not isinstance(got, list) or [g.get("n") for g in got] != [n for n, _, _, _ in rows]:
        raise VoiceError("codex returned lines that do not match %d-%d; log: %s"
                         % (start, end, os.path.join(unit_dir, "codex.log")))
    new_lines = []
    replacements = []
    for (n, status, line, _), g in zip(rows, got):
        new = g.get("text")
        if not isinstance(new, str):
            raise VoiceError("codex line %d is not a string" % n)
        if status != "candidate" and new != line:
            raise VoiceError("invariant violated: line %d changed (%s)" % (n, status))
        if new != line:
            replacements.append("replace line %d with: %s" % (n, new))
        new_lines.append(new)
    after = "\n".join(new_lines) + "\n"
    return make_report("code-comment", target, text, lint, after, data["changes"],
                       protected=protected, apply="\n".join(replacements))
```

Replace the `--range` stub in `cmd_rewrite` with:

```python
    if args.line_range:
        if args.kind != "code-comment":
            raise VoiceError("--range requires --kind code-comment")
        path, start, end = parse_range(args.line_range)
        return emit([run_range_unit(path, start, end, args, workdir)], args)
```

- [ ] **Step 5: Run the suite to verify it passes**

Run: `bash claude/skills/voice/scripts/tests/voice_test.sh`
Expected: `voice: 87 passed, 0 failed` (69 plus 18 here), exit 0. If line 1 comes back `protected: referenced elsewhere (widgets.py)` instead of `candidate`, the self-exclusion in `grep_files` is comparing two spellings of the same path (macOS `/var` vs `/private/var`); the `realpath` calls above are the fix, never a weaker assertion.

- [ ] **Step 6: Commit**

```bash
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass add claude/skills/voice/scripts/voice.py claude/skills/voice/scripts/tests/voice_test.sh claude/skills/voice/scripts/tests/fixtures/gui_repo
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass commit -m "skills: Add voice code-comment range with load-bearing protection"
```

---

### Task 5: Skill prose, contract run, static checks

**Files:**
- Create: `claude/skills/voice/SKILL.md`
- Verify: `claude/contracts/td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-contract.json` (already committed with this plan; do not edit unless a command is wrong, and then say why in the commit body)

**Interfaces:**
- Consumes: the `voice.py` CLI exactly as built in Tasks 1-4.
- Produces: the skill that Claude loads; the `## Call sites` section is the integration contract for the follow-up wiring task.

- [ ] **Step 1: Write `SKILL.md`**

```markdown
---
name: voice
description: Use before posting any outward-facing text an agent wrote (PR title or body, PR comment, Jira title, description, or comment, code comment or docstring) to run a second-model voice pass with Codex. Trigger on "voice pass", "de-generify this", "make this sound human", "check this PR body". Returns a rewrite plus what changed and why; never posts, edits, or commits on its own.
---

# Voice (second-model voice pass)

The model that wrote a PR body is a poor judge of its own voice. This skill
sends the text to Codex (`gpt-6-astra`) with the CLAUDE.md style rules and
shows the before/after for a human to approve. The script never posts.

## Usage

```bash
V=~/.claude/skills/voice/scripts/voice.py
python3 $V lint    --kind pr-body --file body.md          # mechanical checks only, no model
python3 $V rewrite --kind pr-body --file body.md          # Codex rewrite + report
python3 $V rewrite --pr 123                               # title and body via gh pr view
python3 $V rewrite --kind code-comment --range src/x.py:40-52
printf '%s' "$TEXT" | python3 $V rewrite --kind jira-comment --stdin
```

Kinds: `pr-title`, `pr-body`, `pr-comment`, `jira-title`, `jira-description`,
`jira-comment`, `code-comment`. Flags: `--effort high|xhigh` (default high),
`--dry-run` (print the prompt, do not call Codex), `--json` (array of report
objects). Exit `0` nothing to change, `1` rewrite proposed, `2` error.

## Steps

1. Pick the kind from the table above. For Jira fields, fetch the text via
   the MCP Jira tools (`getJiraIssue` for summary/description) and pipe it
   in with `--stdin`; the script has no Jira access by design.
2. Run `rewrite`. Show the report verbatim: diff, numbered changes with
   rules, protected lines, and the `Apply with` block.
3. Ask for approval in one line. Do not apply without a yes.
4. Apply with the printed command (`gh pr edit ...`, the MCP update call,
   or paste the after block). For `code-comment`, apply the line
   replacements with Edit, one line at a time.
5. `unchanged`: say so in one line and post the original.
6. Exit `2` with `invariant violated`: Codex dropped a URL, ticket key,
   code span, or protected line. Do not hand-merge; re-run once, then
   post the original and say the pass was skipped.

## What it protects

- URLs and ticket keys always; fenced blocks for comments and bodies;
  inline code spans for bodies and descriptions.
- Code lines and load-bearing comments in a `--range`: a comment whose
  text appears elsewhere in the repo, or a docstring the repo reads via
  `__doc__`, `getdoc(`, or `.doc`, is sent as `protected` and must come
  back byte-identical. The report names the evidence so you can overrule.

## Call sites

Wiring is a follow-up task. Each row is one edit: before the outward
write, run `rewrite --kind <k>` on the text, show before/after, wait for
approval.

| call site | kind | text fed |
|-----------|------|----------|
| `claude/commands/pr.md`, before `gh pr create` | pr-title, pr-body | the title and the heredoc body |
| `claude/commands/jira.md`, `comment` | jira-comment | the comment text |
| `claude/skills/ship/SKILL.md`, step 4 summary and any PR comment it posts | pr-comment | the comment body |
| `claude/skills/post-merge/SKILL.md`, step 4 resolution comment | jira-comment | the resolution comment |
| Herdr reviewer brief findings summary (the `co-review` report comment) | pr-comment | the findings summary |
| Jira ticket creation (`/start`, `reconcile` backfill) | jira-title, jira-description | summary and description |

## Notes

- Runs Codex in an empty scratch dir with a read-only sandbox and no
  approvals; the prompt names no tools or skills, so it cannot recurse
  into a Claude shell-out. Confirm on first live use: the `codex.log`
  path printed on failure (or `--json` event output) should show no
  command execution.
- `lint` alone is deterministic and free; use it in a hurry.
- Each `rewrite` keeps its prompt, schema, Codex log, and any body file
  under a `$TMPDIR/voice.*` directory so the printed paths stay valid
  after the run. Nothing cleans them up; `rm -rf "${TMPDIR:-/tmp}"/voice.*`
  when they pile up.
- Tests: `bash claude/skills/voice/scripts/tests/voice_test.sh` (fakes
  replace Codex and gh; no network).
```

- [ ] **Step 2: Run the whole contract locally**

Run:

```bash
python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 --task-id td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira --worktree /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass --contract claude/contracts/td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-contract.json --allow-unpinned
```

Expected: `ok <name> exit=0` for all 13 commands, then `PASS 13 commands`. A failing command names the criterion; fix the implementation, not the contract, unless the contract's shell is wrong on this platform.

- [ ] **Step 3: Run the full repo suite once**

Run: `bash bin/dotfiles-tests 2>&1 | tail -5`
Expected: `dotfiles-tests: 20 suites passed, 0 failed` (19 baseline plus voice). A pre-existing failure unrelated to `voice` (the hook suite's live permissions drift on some machines) is reported, not fixed here.

- [ ] **Step 4: Commit**

```bash
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass add claude/skills/voice/SKILL.md
git -C /Users/talon/.herdr/worktrees/dotfiles/talon-td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira-voice-pass commit -m "skills: Add voice skill prose with posting call sites"
```

- [ ] **Step 5: Human-verify item (not in the contract)**

Once the Codex usage limit has reset, run one live pass and record the result in the PR body:

```bash
python3 claude/skills/voice/scripts/voice.py rewrite --kind pr-body --file claude/skills/voice/scripts/tests/fixtures/pr_body_generated.md --json
```

Expected: exit `1`, a JSON array with one `changed` report, and no `exec_command` or shell invocation in the Codex log under the printed temp dir. This is AC13.

---

## Acceptance criteria to contract commands

| Criterion | Contract command | How it falsifies |
|-----------|------------------|------------------|
| AC1 generated PR body lint | `lint-generated-pr-body-flags-filler-hedge-empty-heading`, `fixture-suite` | exit must be 1 and output must carry `filler:`, `hedge:`, `empty-heading:` |
| AC2 clean PR body lint | `lint-clean-pr-body-is-silent`, `fixture-suite` | exit must be 0 with empty stdout |
| AC3 Jira title shape | `lint-jira-title-shape`, `fixture-suite` | generated title must print `title-shape:`; clean title must exit 0 |
| AC4 emoji and attribution | `fixture-suite` | run-time-built fixture must yield `emoji: U+1F680` and `attribution:` |
| AC5 generated body rewritten | `fixture-suite` | fake Codex run must exit 1 with a diff and a numbered change |
| AC6 clean body unchanged | `fixture-suite` | must exit 0 and print `unchanged` |
| AC7 dropped link is fatal | `fixture-suite` | `FAKE_CODEX_MODE=drop-link` must exit 2 with `invariant violated: url` |
| AC8 displayed docstring protected | `fixture-suite` | docstring lines byte-identical in `after`; sibling comment rewritten; `touch-protected` exits 2 |
| AC9, AC9b, AC9c PR target and guards | `fixture-suite` | fake gh log holds one `pr view` and no `pr edit`; null body is `empty`; wrong-kind `--range` exits 2 |
| AC10 dry-run | `dry-run-never-invokes-codex`, `fixture-suite` | `VOICE_CODEX_BIN=/usr/bin/false` must still exit 0 and print rules line 3 and `=== TEXT ===` |
| AC11 Codex failure | `fixture-suite` | `FAKE_CODEX_MODE=fail` must exit 2 naming `log:` |
| AC12 stdlib, executable, ASCII, registered | `script-compiles`, `script-executable-and-stdlib-only`, `new-files-ascii-no-emoji`, `no-attribution-in-prose-and-shell`, `suite-registered-in-test-runner`, `skill-dir-tracked`, `skill-frontmatter` | each is a direct check on the file or registration line |
| AC13 live Codex run | none (human-verify, Task 5 step 5) | needs network and the real binary; outside the contract by design |
| Non-goal: review skills untouched | `review-skills-untouched` | `git diff --quiet` against base `41dd7a1` on the excluded paths |

## Review status

- `codex-plan-review` was blocked on 2026-09-06 by the same Codex usage
  limit that blocked the spec review (reset 23:08 local). The fallback
  reviewer (fresh-context Opus, identical prompt) returned 5 findings,
  verdict needs-rework: 1 critical (macOS `/var` vs `/private/var` path
  mismatch in the range unit's self-exclusion, fixed with `realpath`),
  1 medium (`fake_gh.sh` had no `chmod +x` step, added), 3 low (an
  accidental diff-context assertion replaced with a `--json` check, the
  Task 1 red-run expectation corrected, the temp-dir retention
  documented in `SKILL.md`). All five are folded in. The lint regexes
  were also smoke-run against the fixtures in a scratch dir and every
  Task 1 assertion held. Re-run `codex-plan-review` on this file when
  the limit resets, before starting Task 1.
