# Herdr Worktree Create Cwd Guard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a PreToolUse Bash hook that denies `herdr worktree create` invocations lacking `--cwd`, registered in the settings template, covered by the hook test suite, with a verification contract.

**Architecture:** One new stdlib-only Python guard (`claude/hooks/herdr_worktree_guard.py`) shaped like `push_guard.py`: shell-faithful tokenizing via `shlex` with `punctuation_chars`, per-segment detection of a `worktree create` head (after env assignments, prefix wrappers, and herdr global options), recursion into `sh -c '...'` string arguments, exit 2 with a two-line fix message on a miss, fail open on exceptions. Registration is one template entry; tests are appended to the existing POSIX-sh suite; the contract runs that suite under a sandbox HOME.

**Tech Stack:** Python 3 stdlib (`json`, `re`, `shlex`), POSIX sh test script (`PASS/FAIL ... N passed, N failed` convention), JSON template and contract.

**Spec:** `docs/specs/2026-09-01-herdr-worktree-create-cwd-guard.md`

## Global Constraints

- Run every command from the worktree root `/Users/talon/Git/personal/dotfiles/.claude/worktrees/talon+td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo+cwd-guard-hook`; verify with `git rev-parse --show-toplevel` before each commit.
- Guard scope is `worktree create` only; `worktree open` is never denied.
- Hook exit codes: 2 = deny (two stderr lines, first starts `Blocked: herdr worktree create without --cwd`), 0 = allow silently, 0 on any exception (fail open).
- Hook file is executable, `#!/usr/bin/env python3`, stdlib only, no emojis, no AI attribution.
- Do NOT reconcile or edit live `~/.claude/settings.json` / `~/.claude-work/settings.json`; `~/.claude/hooks` points at the main checkout, so the live path would dangle until merge. Template-only.
- The suite is run sandboxed: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh` (the live drift section SKIPs; the pre-existing permissions-drift failure on this machine is unrelated to this task).
- Commit messages: `hooks: <summary>` (imperative, <75 chars) and must not contain the word "claude" outside the scope prefix (commit_guard blocks it). Say "settings template", "hook suite".
- The repo's `push_guard.py` text fallback can false-positive on a Bash heredoc whose body mentions `git`, `push`, and a long force flag on one line. Write files with the Write/Edit tools, not Bash heredocs, when the content is prose about hooks.
- Test-suite additions use the existing `assert_blocks` / `assert_allows` helpers (any nonzero = block) plus one explicit exit-2/stderr check.
- Baseline before any change (recorded 2026-09-01): unsandboxed suite 41 passed, 1 failed (live permissions drift); sandboxed suite must show 0 failed after Task 1.

---

### Task 1: The guard hook plus its test cases

**Files:**
- Create: `claude/hooks/herdr_worktree_guard.py`
- Modify: `claude/hooks/claude-hooks.test.sh` (insert a new block after line 185, the `assert_allows "allows override prefix after user confirmation"` case that ends the push_guard block, and before the `# account_guard.py account-aware routing` comment at line 187)

**Interfaces:**
- Consumes: the suite's `assert_blocks LABEL HOOK PAYLOAD` and `assert_allows LABEL HOOK PAYLOAD` helpers (defined at the top of `claude-hooks.test.sh`; `run_hook` pipes the payload into the hook and returns its exit status; `PASS`/`FAIL` counters).
- Produces: `claude/hooks/herdr_worktree_guard.py` exposing `command_lacks_cwd(command: str, depth: int = 0) -> bool` (importable for future tests) and a `main()` that reads the PreToolUse JSON on stdin. Task 2 registers this exact path in the template; Task 3's contract runs this suite.

- [ ] **Step 1: Write the failing test block**

Insert the following into `claude/hooks/claude-hooks.test.sh` between the last push_guard case (line 185, the closing `'{"tool_name":"Bash","tool_input":{"command":"DOTFILES_ALLOW_FORCE_PUSH=1 git push --force-with-lease"}}'` line) and the blank line before `# account_guard.py account-aware routing`:

```sh

# herdr_worktree_guard.py: exit 2 (block) on `herdr worktree create` lacking
# --cwd, 0 otherwise. `worktree open` is out of scope and never blocked.
HWG=claude/hooks/herdr_worktree_guard.py
assert_blocks "hwg: blocks bare worktree create" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create"}}'
assert_blocks "hwg: blocks create with other flags but no --cwd" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --branch x --label y"}}'
assert_blocks "hwg: blocks backslash-continued create with no --cwd" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create \\\n  --branch x \\\n  --label y"}}'
assert_blocks "hwg: blocks create whose --cwd is only in a comment" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --branch x # --cwd /repo"}}'
assert_blocks "hwg: blocks create in compound command" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"cd /r && herdr worktree create --branch x"}}'
assert_blocks "hwg: blocks create when --cwd is in a different segment" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --branch x; echo --cwd /r"}}'
assert_blocks "hwg: blocks create when --cwd is on a different line" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --branch x\necho --cwd /r"}}'
assert_blocks "hwg: blocks create wrapped in sh -c" \
    "$HWG" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sh -c 'herdr worktree create --branch x'\"}}"
assert_blocks "hwg: blocks path-qualified herdr create" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"/opt/homebrew/bin/herdr worktree create"}}'
assert_blocks "hwg: blocks env-assignment-prefixed create" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"HERDR_ENV=1 herdr worktree create"}}'
assert_blocks "hwg: blocks env-wrapped create" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"env HERDR_ENV=1 herdr worktree create"}}'
assert_blocks "hwg: blocks command-wrapped create" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"command herdr worktree create"}}'
assert_blocks "hwg: blocks create after herdr global option" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr --session main worktree create --branch x"}}'
assert_allows "hwg: allows create with --cwd first" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --cwd /repo --branch x"}}'
assert_allows "hwg: allows create with --cwd=value" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --cwd=/repo"}}'
assert_allows "hwg: allows create with --cwd last" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --branch x --cwd /repo"}}'
assert_allows "hwg: allows quoted substitution as --cwd value" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --cwd \"$(git rev-parse --show-toplevel)\""}}'
assert_allows "hwg: allows quoted separator inside an argument" \
    "$HWG" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"herdr worktree create --label 'a;b' --cwd /repo\"}}"
assert_allows "hwg: allows global option plus --cwd" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr --session main worktree create --cwd /repo"}}'
assert_allows "hwg: allows backslash-continued create with --cwd on line 2" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create \\\n  --cwd /repo"}}'
assert_allows "hwg: allows redirection and pipe after a valid create" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --cwd /repo 2>&1 | tee log"}}'
assert_allows "hwg: allows worktree open without --cwd (out of scope)" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree open --workspace ws1"}}'
assert_allows "hwg: allows worktree list" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree list"}}'
assert_allows "hwg: allows worktree remove" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"herdr worktree remove --workspace ws1"}}'
assert_allows "hwg: allows mention in commit message" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"docs: mention herdr worktree create\""}}'
assert_allows "hwg: allows mention in grep pattern" \
    "$HWG" \
    '{"tool_name":"Bash","tool_input":{"command":"grep -rn \"herdr worktree create\" claude/"}}'
assert_allows "hwg: allows mention behind a prefix wrapper" \
    "$HWG" \
    "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"env echo 'herdr worktree create'\"}}"
assert_allows "hwg: allows non-Bash tool" \
    "$HWG" \
    '{"tool_name":"Write","tool_input":{"file_path":"notes.md"}}'
assert_allows "hwg: allows payload with no tool_input (fail open)" \
    "$HWG" \
    '{"tool_name":"Bash"}'

# Exact contract: deny is exit 2 with the fix-naming first line; allow is
# exit 0 and silent. (assert_blocks accepts any nonzero status.)
if printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --branch x"}}' \
        | "$HWG" >/dev/null 2>/tmp/claude-hook-test.err; then
    hwg_rc=0
else
    hwg_rc=$?
fi
if [ "$hwg_rc" = 2 ] && head -n 1 /tmp/claude-hook-test.err \
        | grep -q '^Blocked: herdr worktree create without --cwd'; then
    printf 'PASS  hwg: deny is exit 2 with fix-naming message\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  hwg: deny is exit 2 with fix-naming message (rc=%s)\n' "$hwg_rc" >&2
    FAIL=$((FAIL + 1))
fi
if printf '%s\n' '{"tool_name":"Bash","tool_input":{"command":"herdr worktree create --branch x --cwd /repo"}}' \
        | "$HWG" >/dev/null 2>/tmp/claude-hook-test.err \
        && [ ! -s /tmp/claude-hook-test.err ]; then
    printf 'PASS  hwg: allow is exit 0 and silent\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  hwg: allow is exit 0 and silent\n' >&2
    FAIL=$((FAIL + 1))
fi
```

Note on the JSON payloads: the suite passes each payload through `printf '%s\n'` untouched, so `\\\n` inside single-quoted sh strings reaches the hook as the JSON escape for a backslash followed by a newline, which `json.load` turns into a real backslash-newline continuation. The `sh -c` and `--label 'a;b'` cases use double-quoted sh strings so the inner single quotes survive.

- [ ] **Step 2: Run the suite to verify the new cases fail**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -c 'hwg'`
Expected: `31` lines mention `hwg`, and `grep -c '^FAIL  hwg'` is at least `14` (every `blocks` case passes vacuously against a missing hook because `run_hook` returns 127, so it is the `allows` cases and the exact-contract checks that fail). `0` here means the block was not inserted.

- [ ] **Step 3: Write the hook**

Create `claude/hooks/herdr_worktree_guard.py` with exactly this content:

```python
#!/usr/bin/env python3
"""Hook to deny `herdr worktree create` invocations that omit --cwd.

Without an explicit `--cwd <repo_root>`, herdr anchors the new worktree to
the repo its server session considers current (or an adjacent submodule),
not the caller's repo -- incident 2026-08-28, a worker briefed into the
wrong repo. The orchestration skill makes --cwd mandatory for create; the
Bash(herdr worktree:*) allowlist rule is a literal prefix and cannot
express "must contain --cwd", so this hook enforces it. `worktree open`
is deliberately NOT guarded (it re-attaches to an existing workspace).

Supported grammar (guaranteed caught): a create that heads a shell
segment on any physical line -- bare or path-qualified binary, after
leading NAME=VALUE assignments, prefix wrappers (env, exec, command,
nohup, time, xargs) or herdr global options (--session, --remote) -- or
that appears verbatim inside a quoted argument of sh/bash/zsh/dash/eval.

Accepted holes: aliases/functions/scripts, $(...) and heredoc bodies,
quoted newlines inside an argument, `--cwd ""` (herdr rejects it), and a
wrapper argument that assembles the command from pieces.

Runs before Bash tool calls. Fails open on any exception.
"""

import json
import re
import shlex
import sys

PREFIX_WRAPPERS = ("env", "exec", "command", "nohup", "time", "xargs")
STRING_WRAPPERS = ("sh", "bash", "zsh", "dash", "eval")
HERDR_GLOBAL_OPTS_WITH_ARG = ("--session", "--remote")
CREATE_TEXT = "herdr worktree create"
MAX_DEPTH = 3

CONTINUATION = re.compile(r"\\\n")
OPERATOR = re.compile(r"^[;&|]+$")


def basename(tok: str) -> str:
    return tok.rsplit("/", 1)[-1]


def is_env_assignment(tok: str) -> bool:
    return "=" in tok and not tok.startswith("-") and "/" not in tok.split("=")[0]


def tokenize(line: str) -> list[str]:
    """Shell-faithful tokens: quotes honored, operators split out, and a
    word-initial `#` starts a comment that is dropped."""
    lexer = shlex.shlex(line, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = "#"
    try:
        return list(lexer)
    except ValueError:
        return line.split()


def segments(tokens: list[str]) -> list[list[str]]:
    out: list[list[str]] = [[]]
    for tok in tokens:
        if OPERATOR.match(tok):
            out.append([])
        else:
            out[-1].append(tok)
    return [seg for seg in out if seg]


def strip_prefixes(tokens: list[str]) -> list[str]:
    """Drop leading env assignments and prefix wrappers until the head token
    is a real command."""
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if is_env_assignment(tok):
            i += 1
        elif basename(tok) in PREFIX_WRAPPERS:
            i += 1
            while i < len(tokens) and tokens[i].startswith("-"):
                i += 1  # wrapper's own options (env -i, nohup -p ...)
        else:
            break
    return tokens[i:]


def create_lacks_cwd(tokens: list[str]) -> bool:
    """True iff `tokens` (head already `herdr`) is a `worktree create`
    invocation with no --cwd."""
    i = 1
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] in HERDR_GLOBAL_OPTS_WITH_ARG:
            i += 2
        else:
            i += 1
    if tokens[i:i + 2] != ["worktree", "create"]:
        return False
    for tok in tokens[i + 2:]:
        if tok == "--cwd" or tok.startswith("--cwd="):
            return False
    return True


def command_lacks_cwd(command: str, depth: int = 0) -> bool:
    if depth > MAX_DEPTH:
        return False
    joined = CONTINUATION.sub(" ", command)
    for line in joined.split("\n"):
        for seg in segments(tokenize(line)):
            seg = strip_prefixes(seg)
            if not seg:
                continue
            head = basename(seg[0])
            if head == "herdr":
                if create_lacks_cwd(seg):
                    return True
            elif head in STRING_WRAPPERS:
                for tok in seg[1:]:
                    if CREATE_TEXT in tok and command_lacks_cwd(tok, depth + 1):
                        return True
            # Any other head (git, echo, grep ...) is a mention, not a create.
    return False


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name", "") != "Bash":
            sys.exit(0)
        command = data.get("tool_input", {}).get("command", "")
        if not isinstance(command, str) or not command_lacks_cwd(command):
            sys.exit(0)
        print(
            "Blocked: herdr worktree create without --cwd anchors the worktree "
            "to the herdr server's current repo, not yours.",
            file=sys.stderr,
        )
        print(
            'Re-run with --cwd "$(git -C <path-in-repo> rev-parse '
            '--show-toplevel)" (herdr-orchestration SKILL.md, section 2 step 5).',
            file=sys.stderr,
        )
        sys.exit(2)
    except Exception:
        # Fail open: a crashed guard must never block work.
        sys.exit(0)


if __name__ == "__main__":
    main()
```

Then: `chmod +x claude/hooks/herdr_worktree_guard.py`

This code was executed against every block/allow case above during planning (0 mismatches); the deny path printed the two lines and exited 2, and a payload with no `tool_input` exited 0.

- [ ] **Step 4: Run the suite to verify it passes**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | tail -1`
Expected: `N passed, 0 failed`. Also `... | grep -c '^PASS  hwg'` -> `31` (13 blocks, 16 allows, 2 exact-contract checks).

Also run: `python3 -m py_compile claude/hooks/herdr_worktree_guard.py && test -x claude/hooks/herdr_worktree_guard.py && echo ok`
Expected: `ok`

- [ ] **Step 5: Commit**

```bash
git rev-parse --show-toplevel   # must print the worktree path from Global Constraints
git add claude/hooks/herdr_worktree_guard.py claude/hooks/claude-hooks.test.sh
git commit -m "hooks: Deny herdr worktree create without --cwd"
```

---

### Task 2: Register the hook in the settings template and document it

**Files:**
- Modify: `claude/settings.json.tmpl:175-178` (the `push_guard.py` entry inside the `PreToolUse` `"matcher": "Bash"` group)
- Modify: `claude/hooks/claude-hooks.test.sh` (append one static assertion right after the Task 1 block, before `# account_guard.py account-aware routing`)
- Modify: `claude/skills/herdr-orchestration/SKILL.md:187-189` (section 2 step 5)
- Modify: `CLAUDE.md:77` (Architecture list, `account_guard.py` bullet)

**Interfaces:**
- Consumes: the hook path `~/.claude/hooks/herdr_worktree_guard.py` from Task 1 (the `~/.claude/hooks` symlink serves both config dirs).
- Produces: a template `PreToolUse` Bash group listing four commands in order: `commit_guard.py`, `no_ai_attribution_bash.py`, `push_guard.py`, `herdr_worktree_guard.py`. The suite's existing live drift check derives its expectations from this template.

- [ ] **Step 1: Write the failing static registration assertion**

Append to `claude/hooks/claude-hooks.test.sh` directly after the Task 1 `hwg` block (still before the `# account_guard.py account-aware routing` comment):

```sh
# Static registration: the template must list the guard in the PreToolUse
# Bash group. Independent of live machine state (the live drift check below
# is derived from the template and covers reconciled machines).
if python3 - <<'PY'
import json
import sys

tmpl = json.load(open("claude/settings.json.tmpl"))["hooks"]["PreToolUse"]
cmds = [h["command"] for e in tmpl if e.get("matcher") == "Bash" for h in e["hooks"]]
sys.exit(0 if "~/.claude/hooks/herdr_worktree_guard.py" in cmds else 1)
PY
then
    printf 'PASS  hwg: template registers the guard in the PreToolUse Bash group\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  hwg: template registers the guard in the PreToolUse Bash group\n' >&2
    FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2: Run the suite to verify the new assertion fails**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | grep 'template registers the guard'`
Expected: `FAIL  hwg: template registers the guard in the PreToolUse Bash group`

- [ ] **Step 3: Register the hook in the template**

In `claude/settings.json.tmpl`, change the `push_guard.py` entry (lines 175-178):

```json
          {
            "type": "command",
            "command": "~/.claude/hooks/push_guard.py"
          }
```

to:

```json
          {
            "type": "command",
            "command": "~/.claude/hooks/push_guard.py"
          },
          {
            "type": "command",
            "command": "~/.claude/hooks/herdr_worktree_guard.py"
          }
```

Verify: `python3 -c 'import json; json.load(open("claude/settings.json.tmpl")); print("json ok")'`
Expected: `json ok`

- [ ] **Step 4: Run the suite to verify it passes**

Run: `HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>&1 | tail -1`
Expected: `N passed, 0 failed` (N is Task 1's count plus 1).

Run the unsandboxed suite once for information only: `sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E '^FAIL|missing hook'`
Expected: the pre-existing `permissions drifted` FAIL for `~/.claude`, plus `missing hook: PreToolUse: ~/.claude/hooks/herdr_worktree_guard.py` FAILs for both live config dirs. This is expected on the branch (see Global Constraints: do NOT reconcile live settings); it clears when `update` runs after merge. Do not "fix" it.

- [ ] **Step 5: Document the hook in the skill and the repo CLAUDE.md**

In `claude/skills/herdr-orchestration/SKILL.md`, section 2 step 5 currently reads (lines 187-189):

```
5. **`herdr worktree create --cwd <repo_root>`** (or `worktree open --cwd
<repo_root>` if adopting) -- the explicit `--cwd` is MANDATORY, never a bare
   path. Resolve `<repo_root>` first as the intended repo's top level:
```

Change it to:

```
5. **`herdr worktree create --cwd <repo_root>`** (or `worktree open --cwd
<repo_root>` if adopting) -- the explicit `--cwd` is MANDATORY, never a bare
   path. A PreToolUse hook (`claude/hooks/herdr_worktree_guard.py`) denies a
   `worktree create` that lacks `--cwd`; `open` is not hook-guarded, so its
   `--cwd` stays on you. Resolve `<repo_root>` first as the intended repo's
   top level:
```

In `CLAUDE.md`, directly after line 77 (the `account_guard.py` bullet), add:

```
- `claude/hooks/herdr_worktree_guard.py` — PreToolUse Bash hook that denies `herdr worktree create` without `--cwd` (a bare create anchors to the herdr server's current repo, not yours); `worktree open` is not guarded (registered in `settings.json.tmpl`; drift-checked by `claude-hooks.test.sh`)
```

(The em-dash and backtick style match the neighboring bullet; the file already uses non-ASCII em-dashes.)

- [ ] **Step 6: Commit**

```bash
git rev-parse --show-toplevel   # must print the worktree path
git add claude/settings.json.tmpl claude/hooks/claude-hooks.test.sh claude/skills/herdr-orchestration/SKILL.md CLAUDE.md
git commit -m "hooks: Register worktree cwd guard in settings template and docs"
```

---

### Task 3: Verification contract

**Files:**
- Create: `claude/contracts/td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo-contract.json`

**Interfaces:**
- Consumes: the sandboxed suite invocation from Tasks 1-2.
- Produces: the contract the orchestrator pins before the implement dispatch and runs at review (`herdr_orch_core.py verify-contract`; commands run via `sh -c` in the worktree, so `$(mktemp -d)` expands there).

- [ ] **Step 1: Write the contract**

Create `claude/contracts/td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo-contract.json`:

```json
{
  "v": 1,
  "task_id": "td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo",
  "commands": [
    {
      "name": "claude-hooks-suite-sandboxed",
      "run": "HOME=\"$(mktemp -d)\" sh claude/hooks/claude-hooks.test.sh",
      "timeout_secs": 300
    }
  ]
}
```

- [ ] **Step 2: Validate the contract shape and run it**

Run:
```bash
python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py" verify-contract \
  --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 \
  --task-id td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo \
  --worktree "$(git rev-parse --show-toplevel)" \
  --contract claude/contracts/td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo-contract.json \
  --allow-unpinned --validate-only
```
Expected: prints a sha256 (validation passed).

Then run the command itself: `sh -c 'HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh' | tail -1`
Expected: `N passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git rev-parse --show-toplevel   # must print the worktree path
git add claude/contracts/td-2026-09-01-block-herdr-worktree-create-without-cwd-via-pretoo-contract.json
git commit -m "hooks: Add verification contract for worktree cwd guard"
```

---

### Final check (after Task 3)

- `git diff --stat origin/main` lists only: `claude/hooks/herdr_worktree_guard.py`, `claude/hooks/claude-hooks.test.sh`, `claude/settings.json.tmpl`, `claude/skills/herdr-orchestration/SKILL.md`, `CLAUDE.md`, the contract file, and the branch-only `docs/specs/...` and `docs/plans/...` files.
- `git status --porcelain` is empty.
- Live `~/.claude/settings.json` and `~/.claude-work/settings.json` are unchanged: record `shasum -a 256` of both before Task 1 and compare after Task 3.
