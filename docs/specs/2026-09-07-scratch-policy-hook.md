# Spec: Worker-side permission policy hook for scratch cleanup

Date: 2026-09-07
Branch: talon/td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat/scratch-policy-hook
Source task: td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat
Base: origin/main 026f0432c83f57cabb5038673c07ea1e48aa76ac
Status: branch-only document; dropped before merge together with the plan
(`git/hooks/public-safety.test.sh` refuses tracked `docs/specs/**` and
`docs/plans/**`, and `.gitignore` ignores both directories, so the two
files are force-added on this branch only, the convention the last seven
branch-only spec/plan commits followed, because the task brief requires
the spec and plan to be committed for the implement worker). The
verification contract under `claude/contracts/` stays.

Review provenance: Codex spec review round 1 (2026-09-07,
`model_reasoning_effort=high`) returned 12 findings, verdict
needs-rework; all are folded in below (redirection tokens, lexical `..`
before symlink resolution, globs through symlinks, `rmdir -p`,
executable identity, symlinked `tmp.*` roots, R2b overlap with the
scratchpad root, deny-rule precedence wording, shell grammar, layered
safety claim, a controlled AC10 trigger, artifact lifecycle). Round 2
returned 7 findings, verdict needs-rework; all are folded in (mid-token
`#` comments, substitutions inside option tokens, quoted brace/glob
text, shell glob settings, repository protection at the root and inside
recursively removed subtrees, `mktemp` regular files, a FIFO sidecar
blocking the allow). Per `codex-spec-review`'s two-round cap the spec
proceeds to planning on judgment after round 2; the plan review is
recorded in the plan's review notes. Plan review round 1 fed three
rule changes back into D2 (quoted operators refused, long-option
allowlist, inspection errors yield no decision); round 2 fed four more
(brackets and `~user`/quoted tildes refused, glob matches named like
options refused, a relative `$TMPDIR` yields no R2 root, R2b never
reaches under `$HOME`).

## Problem

After PR #88, `rm` is no longer an `ask` rule: auto mode's classifier
decides it and `claude/hooks/rm_guard.py` denies the catastrophic shapes
as a PreToolUse hook. Scratch cleanup under the session scratchpad or
`$TMPDIR` therefore reaches the classifier every time, and any residual
prompt (a classifier fallback to ask, or a future `ask` rule) parks an
orchestrated worker in its herdr pane with nobody watching. Cross-session
answering of prompts is disallowed, so the only sanctioned automation is
a `PermissionRequest` hook in the worker's own settings that answers the
prompt by policy.

## Verdict

Proceed. `PermissionRequest` exists in the installed Claude Code
(2.1.263), its payload and output schema are confirmed against the
binary and the official hooks reference, and it is consulted exactly at
the point this task cares about: after rules and the auto-mode
classifier, when a prompt would otherwise be shown to a human. A
policy hook that allows only plain `rm`/`rmdir` invocations whose every
target resolves under a throwaway root closes the gap without weakening
`rm_guard.py` (which runs first and, when it denies, suppresses the
event entirely).

Two deviations from the todo text, each with its reason:

1. The todo says "deny rules and critical-path rm still win over it".
   The hooks reference has no explicit sentence on whether a bare
   `PermissionRequest` `allow` beats a matching deny rule (the binary
   re-runs rule checks only when the allow carries `updatedInput`,
   `guardHookUpdatedInput`), so this spec makes no claim either way and
   relies on neither: the template's deny list is empty by design
   (PR #88), and what demonstrably wins over the hook is a PreToolUse
   exit-2 block, which is how `rm_guard.py` denies (a block suppresses
   the event). Safety is therefore layered, not disjoint: `rm_guard.py`
   runs first on every Bash call, and the policy hook additionally
   excludes the shapes it can recognize on its own (D2 steps 5-7), so a
   catastrophic shape is refused twice rather than relying on one layer.
2. The todo says "log each allow to the task events file". The
   orchestrator's `events.jsonl` is documented as single-writer
   (`herdr_worker_status.py` only), carries a closed hint vocabulary, and
   every append wakes the orchestrator's `watch`. Scratch allows are
   audit lines, not lifecycle hints, so they go to a per-task sidecar
   `tasks/<task_id>.policy.jsonl` that is not in `WATCH_DIRS` (see D6).

## Goal

1. `claude/hooks/scratch_policy.py`: a `PermissionRequest` hook for the
   Bash tool that returns `decision.behavior: allow` when, and only when,
   the command is one or more plain `rm`/`rmdir` invocations whose every
   target canonicalizes strictly under a throwaway root (session
   scratchpad, `$TMPDIR`, or a `mktemp` path). Everything else yields no
   decision and the normal prompt flow continues.
2. Register it in `claude/settings.json.tmpl` so both account config
   dirs receive it through the existing reconcile.
3. Audit each allow to `tasks/<task_id>.policy.jsonl` under the herdr
   state root when the session is an orchestrated worker.
4. A hermetic, payload-driven test suite, registered in
   `bin/dotfiles-tests`, plus the CLAUDE.md symlink-targets bullet.

## Non-goals

- No change to `claude/hooks/rm_guard.py`, `claude/hooks/herdr_orch_core.py`,
  `claude/skills/herdr-orchestration/**`, `claude/hooks/claude-hooks.test.sh`,
  `bin/dotfiles-tests` beyond one runner line, `install/**`, or
  `claude/hooks/account_guard.py`. The parity branch owns the herdr
  files and has uncommitted rewrites of the others.
- No `deny` decision from this hook, ever. Denials stay with
  `rm_guard.py` (PreToolUse) and the classifier.
- No `updatedInput`, `updatedPermissions`, or `systemMessage` in the
  allow output. An allow that carries `updatedInput` is re-checked
  against permission rules by the binary (`guardHookUpdatedInput`) and
  can be overridden; a bare allow is honored as-is.
- No headless (`-p`) worker support. In print mode `PermissionRequest`
  hooks are consulted only when the session is launched with
  `--permission-prompts none`; that launch recipe belongs to the parity
  branch (Follow-ups F1, F4).
- No changes to `events.jsonl` semantics, vocabulary, or writers.
- No live Claude session in the test suite or the contract.

## Confirmed facts (2026-09-07, worktree at origin/main 026f043)

Verified against the installed binary
`/Users/talon/.local/share/claude/versions/2.1.263`, the official hooks
reference (code.claude.com/docs/en/hooks), and live probes run from this
session. "Confirmed" means observed; "inferred" is marked.

- `claude --version` is 2.1.263. `PermissionRequest` is a valid hook
  event: the settings validator lists it, the input schema is
  `hook_event_name: "PermissionRequest", tool_name, tool_input,
  permission_suggestions (optional)`, and the decision schema is
  `{behavior: "allow", updatedInput?, updatedPermissions?}` or
  `{behavior: "deny", message, interrupt?}`.
- Output contract (hooks reference): exit 0 with
  `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  on stdout is honored. Exit 2 is NOT honored for this event. Any other
  exit code, or invalid JSON, is a non-blocking error and the flow
  proceeds unchanged. An empty stdout on exit 0 is treated as no
  decision: inferred from the shared hook-output parser (every other
  guard in this repo prints nothing on allow), confirmed for Stop and
  PreToolUse, human-verify for this event (AC10).
- Matcher semantics: `"matcher": "Bash"` is an exact tool-name match.
- Lifecycle (hooks reference, confirmed by probes): `PermissionRequest`
  fires after PreToolUse hooks, only when a permission decision is still
  needed. Auto-approved allow rules skip it. A PreToolUse exit-2 block
  suppresses it entirely. In auto mode the binary's ask path runs rules,
  then the classifier, and consults `PermissionRequest` hooks only when
  the result is still `ask` (`executePermissionRequestHooks` is invoked
  from the ask path, `decideLocation: "ask-path"`). So this hook costs
  nothing when the classifier allows and only acts on residual prompts.
- Common payload fields include `session_id`, `cwd`, `permission_mode`
  (`default|plan|acceptEdits|auto|dontAsk|bypassPermissions`), and
  `scratchpad_dir` (binary: `scratchpad_dir: eA() ? GH(session_id) : undefined`,
  the same gate that announces "Scratchpad directory: ..." in the system
  prompt). Headless probe payloads had no `scratchpad_dir`; interactive
  sessions that announce a scratchpad carry it (inferred from the shared
  gate; human-verify in AC10). The scratchpad path shape on this machine
  is `/private/tmp/claude-501/<cwd-slug>/<session-id>/scratchpad`.
- Live in this interactive auto-mode session: `rm -f <scratchpad>/file`,
  `rm <mktemp-path>` (under `$TMPDIR` =
  `/var/folders/.../T/`), and `rm -f /tmp/<nonexistent>` all ran without
  a prompt. `rm -f "$VAR"` shapes were denied by `rm_guard.py` (unexpanded
  variable with `-f`), which the policy hook must also treat as
  unresolvable.
- Live headless probes (`claude -p --permission-mode default` and
  `--permission-mode auto`, hook registered via `--settings` and via a
  project `.claude/settings.json`): `--settings` hooks do load (a
  PreToolUse dump fired), `permission_mode` reported `default` even when
  `auto` was requested, and every `rm` was blocked by the Bash tool's
  own path validation ("rm in '<path>' was blocked. For security, Claude
  Code may only remove files from the allowed working directories for
  this session") before any permission prompt, so `PermissionRequest`
  never fired. That validation is headless-only (the same removals ran
  interactively) and carries a `bashAllowRuleOverridable` marker. Without
  `--permission-prompts none` (present in 2.1.263: "none: anything that
  would prompt is denied automatically"), a headless ask is denied
  without consulting `PermissionRequest` hooks; with it, the binary
  consults them (`consultPermissionRequestHooksForUnpromptableAsk`).
  Recorded for Follow-ups F1/F4, not a deliverable.
- ECC's GateGuard "Fact-Forcing Gate" PreToolUse hook blocks the first
  Bash call of a fresh session (recovery: `ECC_GATEGUARD=off`); because
  a PreToolUse block suppresses `PermissionRequest`, any live
  verification of this hook must present the gate facts first.
- `rm_guard.py` exposes reusable pure functions: `tokenize`,
  `split_segments`, `strip_prefixes`, `basename`, `is_env_assignment`,
  `expand_braces`, `expand_home`, `resolve` (normpath against cwd),
  `has_glob_chars`, `extract_shell_c_arg`, and constants
  `REMOVE_COMMANDS`, `PREFIX_WRAPPERS`, `SHELL_WRAPPERS`.
  `herdr_stop_gate.py` already imports a sibling module via
  `sys.path.insert(0, <hook dir>)`.
- `herdr_orch_core.py`: `state_root()` is
  `${CLAUDE_CONFIG_DIR:-~/.claude}/herdr-orch`; a worker is identified by
  `HERDR_ENV=1` plus `HERDR_WORKSPACE_ID` resolving to
  `<state_root>/<slug>/workspaces/<ws>.json` (`read_index`, role and
  `task_id` inside); `append_event` writes with
  `O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW`, mode 0o600, one JSON line;
  `append_spend` is a plain append that creates `tasks/`.
  `WATCH_DIRS` watches only `tasks/*.done.json`, `*.review.json`,
  `*.spend.jsonl`, `workspaces/*.events.jsonl`, and `think/*`; a
  `tasks/<task_id>.policy.jsonl` sidecar is never scanned, so appending
  to it wakes nothing.
- `claude/hooks/claude-hooks.test.sh` derives its live-settings drift
  check from the template ("a new hook can never be invisible to this
  check"), so registering the hook in the template needs no edit there.
  `install/common/claude-links.sh` `reconcile_claude_settings_file`
  reasserts the whole template-owned `hooks` key, so both account dirs
  receive the new event on the next `update`.
- Test baseline (this machine, base 026f043): `bin/dotfiles-tests`
  reports 23 suites passed, 0 failed; `claude/hooks/claude-hooks.test.sh`
  prints 183 PASS lines (57 `rmg:`). CI runs the same runner on Ubuntu
  and `python3 -m py_compile claude/hooks/*.py`. Local python is 3.14;
  `rm_guard.py` already uses `str | None` syntax, so 3.10+ is the floor.
- Orchestrated workers are interactive panes:
  `claude --model $MODEL [--effort ..] --permission-mode auto --name <agent>`
  with `HERDR_ENV=1` and `HERDR_WORKSPACE_ID` exported (herdr-orchestration
  SKILL.md, section on launching), so `PermissionRequest` applies to them
  and the scratchpad is announced.

## Design

### D1. Event and registration

`claude/settings.json.tmpl` gains one top-level hooks event, placed after
`Notification`:

```json
"PermissionRequest": [
  { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "~/.claude/hooks/scratch_policy.py" }
  ] }
]
```

The PreToolUse Bash group, its order, `permissions`, and `env` are
untouched. `~/.claude/hooks` is the same symlink both config dirs share,
exactly as every other registered hook.

### D2. Decision rule

The hook prints an allow decision iff ALL of the following hold; otherwise
it prints nothing and exits 0 ("no decision"):

1. stdin is a JSON object with `hook_event_name == "PermissionRequest"`,
   `tool_name == "Bash"`, and a non-empty string `tool_input.command`.
2. `permission_mode` is absent or one of `default`, `auto`,
   `acceptEdits`. `plan`, `dontAsk`, and `bypassPermissions` yield no
   decision (plan mode must not delete; the other two never prompt).
3. Grammar. Raw-text refusals first, before any tokenizing: the command
   yields no decision if it contains `#` (the tokenizer treats a
   mid-word `#` as a comment while the shell does not, so
   `rm S/x# /repo/file` would hide an operand), `$` or a backtick
   anywhere (substitution or variable in ANY token, option tokens
   included: `rm "-$(cmd)" S/x` executes the substitution before `rm`),
   `{` or `}` anywhere (brace expansion is not supported; quoted braces
   are literal to the shell but not to the tokenizer), `[` or `]`
   anywhere (bracket expressions, including POSIX classes such as
   `[[:alpha:]]`, are not expanded the way the shell expands them; only
   `*` and `?` are supported globs), or a quote or backslash together
   with any glob character (`*`, `?`), a tilde, or any operator
   character (`;`, `&`, `|`, `(`, `)`, newline) anywhere (a quoted glob
   or tilde is literal to the shell but not to the expander; a quoted
   operator such as `rm S/x ';' rm S/y` is a filename to the shell but
   a separator to the tokenizer). Plain quoted literal paths, e.g.
   `rm -rf "S/build dir"`, stay eligible. The command must then parse with `shlex.split` (posix)
   without a `ValueError`; unbalanced quoting yields no decision (so
   `rm_guard.tokenize`'s whitespace fallback is never the basis of an
   allow). The token stream from `rm_guard.tokenize` may contain, as
   operator tokens, only `&&`, `;`, and newline; any `|`, `||`, `&`,
   `(`, or `)` token yields no decision (pipelines, background jobs,
   and subshell grouping are left to the classifier; D7 says the same).
   `rm_guard.split_segments` then yields one or more segments, and
   EVERY segment is a plain remove invocation: `tokens[0]` is exactly
   `rm`, `rmdir`, `/bin/rm`, `/usr/bin/rm`, `/bin/rmdir`, or
   `/usr/bin/rmdir` (any other path or name, e.g. `/repo/rm`, yields no
   decision); no leading env assignment, no prefix wrapper (`env`,
   `sudo`, `nice`, ...), no shell wrapper (`sh -c`), no `cd`. A bare
   `rm` is trusted to resolve through `PATH` exactly as `rm_guard.py`
   and the classifier already assume; shell functions or aliases that
   shadow `rm` are outside this hook's trust boundary and are not
   considered.
4. Tokens and flags. No token in any segment may contain `<` or `>`
   (redirections, whether standalone like `> /dev/null` or glued to an
   operand like `S/x>/repo/file`, yield no decision: the shell would
   split the operand and the tokenizer does not). Each segment has at
   least one target; targets are the non-flag tokens after the head,
   honoring `--` as in `rm_guard.check_rm`. Short flags: for `rm` every
   short flag is accepted (no `rm` option widens the set of removed
   paths beyond its operands); for `rmdir` a short flag group containing
   `p` yields no decision (it removes ancestors that were never
   checked). Long options are an exact allowlist, because GNU accepts
   any unambiguous abbreviation (`--par`, `--rec`) that the rules above
   would misread: `rm` accepts only `--recursive`, `--force`,
   `--verbose`, `--dir`, `--one-file-system`, `--preserve-root`,
   `--no-preserve-root`; `rmdir` accepts only `--verbose` and
   `--ignore-fail-on-non-empty`; any other long option yields no
   decision.
5. Resolution. A target of the form `~name...` (any tilde form other
   than exactly `~` or a `~/` prefix) yields no decision: the shell
   resolves another user's home, the hook does not. Every remaining
   target, after `rm_guard.expand_home` (no brace expansion: braces were
   refused in step 3), contains no `..` path component (lexical `..` collapse would disagree with the kernel when
   a symlink precedes it, e.g. `S/link/../victim`; no decision). It
   then resolves via `rm_guard.resolve(expanded, cwd)` with `cwd` from
   the payload and canonicalizes (D3) to a path that is a STRICT
   descendant of one of the throwaway roots: `canon.startswith(root + "/")`.
   The root itself is never in scope (one R3 exception, D3).
6. Globs. `**` anywhere yields no decision (zsh, which the Bash tool
   runs on this machine, treats it as recursive; Python does not). A
   target containing glob characters is expanded at decision time
   against the filesystem INCLUDING hidden entries (`fnmatch` over
   `os.scandir` per component, or `glob.glob(include_hidden=True)`),
   so the checked set is a superset of what the executing shell yields
   under any `dotglob`/`GLOB_DOTS` setting, and EVERY match must
   individually satisfy steps 5 and 7 after canonicalization (a match
   reached through a symlink to outside a root fails; a hidden `.git`
   match fails by step 7). Zero matches: the literal must satisfy
   steps 5 and 7 (the non-glob prefix is what canonicalizes; `rm` on a
   non-matching glob merely errors). No glob component may start with
   `.` (`rm -rf <root>/.*` yields no decision). Any match whose
   basename starts with `-` yields no decision: the shell would hand it
   to `rm` as an option (a file named `-rf` next to `rm *` turns the
   removal recursive), and the flag rule of step 4 ran before
   expansion. A directory that cannot be listed during expansion is an
   inspection error and yields no decision: an incomplete listing never
   certifies a target. The
   decision reflects the filesystem at decision time; a change between
   decision and execution is accepted as out of scope, as it is for
   every other guard in this repo.
7. Repository exclusions, applied after a target is found under a
   root: no decision when the canonical target's basename is `.git`
   (any root). For the shared roots R2a and R2b only (the session-owned
   R1 scratchpad and R3 `mktemp` entries are throwaway trees by
   construction, and a scratch clone inside them is legitimately
   scratch): no decision when the canonical target, any ancestor of it
   up to AND including the root, contains a `.git` entry; and, when the
   invocation is recursive (`-r`, `-R`, `--recursive`, or a bundled
   short group containing `r`/`R`) and the target is a directory, the
   subtree is walked without following symlinks and any `.git` entry
   inside it yields no decision, with the walk capped at 20000 entries
   (beyond the cap: no decision, the classifier decides) and any
   directory the walk cannot read also yielding no decision. These
   exclusions exist so the hook refuses the shapes independently of
   `rm_guard.py`'s upstream block.

The hook never emits `deny`. Command text is never echoed to stdout or
stderr.

### D3. Throwaway roots and canonicalization

Roots are computed per invocation and each canonicalized with
`os.path.realpath`. A root is discarded when its realpath is `/`, is
`$HOME` or an ancestor of `$HOME`, or has fewer than two path components
(so `/tmp` itself qualifies only via R2b, which waives the count rule).

- R1 scratchpad: the payload's `scratchpad_dir` when it is an absolute
  string and not itself a symlink. Absent field: no scratchpad root.
- R2a tmpdir: `$TMPDIR` from the hook's environment when set and
  absolute (macOS: `/var/folders/<..>/T` -> `/private/var/folders/<..>/T`).
  A user who points `$TMPDIR` under `$HOME` has chosen that directory as
  scratch; the root survives unless it is `$HOME` itself.
- R2b tmp fallback: when `$TMPDIR` is unset or empty, `/tmp`
  (realpath, `/private/tmp` on macOS). This is Linux `mktemp`'s default.
  A `$TMPDIR` that is set but not absolute is neither R2a nor R2b:
  there is no R2 root and no R3 match at all. Consequence, by design:
  with `$TMPDIR` unset every non-excluded descendant of `/tmp` is in
  scope, including this and other sessions' scratchpads and the
  scratchpad root directory itself (it is a strict descendant of
  `/tmp`). Two exclusions hold under R2b: repository checkouts under
  `/tmp` are refused by D2 step 7, and a target at or under `$HOME`
  (realpath) is refused even when `$HOME` itself lives under `/tmp`
  (the count-rule waiver never waives the home protection). Tests that
  assert "root itself" or "missing `scratchpad_dir`" outcomes therefore
  run with `$TMPDIR` set.
- R3 mktemp under /tmp: when `$TMPDIR` is set, each entry directly under
  `<realpath /tmp>` whose name starts with `tmp.` (the default `mktemp`
  template `tmp.XXXXXXXXXX` on both BSD and GNU) is a root, provided the
  entry is a directory or a regular file (`mktemp /tmp/tmp.XXXXXXXXXX`
  creates a file) that is not a symlink and its realpath stays under
  `<realpath /tmp>` (a `tmp.*` symlink into a repository can never
  promote its destination into a root). The entry itself is in scope
  (the one exception to "root itself never in scope", because
  `rm -rf "$(mktemp -d)"`-style cleanup removes the entry). Provenance
  is by naming convention only: the hook cannot prove `mktemp` created
  the entry or that this session owns it; the accepted risk is that a
  `tmp.*` directory under `/tmp` is throwaway by definition of that
  directory.

Target canonicalization: realpath of the longest existing ancestor of
the resolved path, joined with the non-existing remainder (no `..`
components remain by D2 step 5). A symlink inside a root that points
outside it therefore escapes the root and yields no decision, whether
the target is the link itself or a path through it. The realpath is
computed with the hook's own filesystem view; no path is created or
touched.

### D4. Parsing reuse

`scratch_policy.py` does `sys.path.insert(0, <its own dir>)` and
`import rm_guard`, then uses `rm_guard.tokenize`, `split_segments`,
`is_env_assignment`, `PREFIX_WRAPPERS`, `SHELL_WRAPPERS`,
`REMOVE_COMMANDS`, `expand_home`, `resolve`, and `has_glob_chars`. It
defines no tokenizer, segment splitter, or brace expander of its own
(AC6 greps for this); brace expansion is not used because braces are
refused in D2 step 3. `rm_guard.py` is not modified.

### D5. Output

- Allow: stdout is exactly
  `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
  followed by a newline; stderr empty; exit 0.
- No decision: stdout and stderr empty; exit 0.
- Any exception, unreadable stdin, or malformed payload: no decision
  (exit 0, silent). Fail open toward the normal prompt flow, never toward
  allow.

### D6. Audit logging for orchestrated workers

After computing an allow (never for a no-decision), when `HERDR_ENV=1`
and `HERDR_WORKSPACE_ID` passes `core.valid_workspace_id` and a workspace
index resolves (same discovery as `herdr_worker_status.py`:
`state_root().glob("*/workspaces/<ws>.json")`, `core.read_index`, first
readable wins, `task_id` validated with `core.valid_task_id`), append one
line to `<repo_dir>/tasks/<task_id>.policy.jsonl`:

```json
{"v":1,"ts":"2026-09-07T12:00:00Z","event":"scratch-allow","task_id":"td-...","workspace_id":"w11","tool_use_id":"toolu_...","command":"rm -rf /private/tmp/.../scratchpad/build"}
```

`command` is truncated to 300 characters. Ordering: the allow line is
written to stdout and flushed BEFORE the logging step, so a slow or
blocked write can never withhold the decision. The write uses
`append_event`'s open flags plus `O_NONBLOCK`
(`O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW|O_NONBLOCK`, 0o600) on a path
checked with `core.contained` against `core.state_root()`, only after an
`os.lstat` shows the path absent or a regular file (a FIFO, socket,
symlink, or directory at that path skips logging: a FIFO with no reader
would otherwise block the open); `ts` from `core.now_iso()`; `tasks/`
is not created (a missing dir means "not an orchestrated repo dir", so
logging is skipped). The whole step is wrapped so any failure is
swallowed: logging never changes the decision. The hook imports
`herdr_orch_core` read-only
for these helpers; the sidecar is outside `WATCH_DIRS`, so no
orchestrator wake fires, and `events.jsonl` stays single-writer. Nothing
is written when `HERDR_ENV` is not `1`, when the workspace id is unsafe,
or when no index resolves; the config dir is never otherwise touched.

### D7. Failure posture and security notes

- Every failure path is "no decision". The hook cannot make a prompt
  worse than it already was.
- Layered safety (Verdict, deviation 1): `rm_guard.py` runs first on
  every Bash call and its exit-2 block suppresses this event; the hook
  is only ever consulted on commands `rm_guard.py` already passed. The
  hook additionally refuses, on its own, `.git` targets and checkouts
  under a root (D2 step 7), unexpanded variables and `..` components
  (step 5), and every root that canonicalizes to `/` or `$HOME` (D3).
  The two layers overlap deliberately; neither is assumed sufficient.
- Every root is under `/private/tmp`, `/private/var/folders`, or `/tmp`
  (`rm_guard.SCRATCH_EXCEPTIONS` territory) unless `$TMPDIR` is pointed
  elsewhere by the user.
- `$TMPDIR` pointing at `/`, `$HOME`, an ancestor of `$HOME`, or a
  top-level dir is discarded as a root (D3), so a hostile environment
  cannot widen the allow set to the home directory.
- Symlink escapes are closed by canonicalization plus the `..` and glob
  rules (D2 steps 5-6, D3).
- Wrapper, shell, pipeline, background, and subshell shapes, and
  malformed quoting, are refused by D2 step 3; the classifier keeps
  deciding those.

### D8. Tests

`claude/hooks/scratch-policy.test.sh` (POSIX `sh`, `PASS`/`FAIL` lines,
final `N passed, M failed`, exit 1 on any failure; the same shape as the
other hook suites), hermetic:

- A fixture scratchpad `S=$(mktemp -d)/scratchpad` with `S/build/x`, a
  fixture `T=$(mktemp -d)` used as `TMPDIR`, a fixture `/tmp/tmp.<id>`
  created via `mktemp -d /tmp/tmp.XXXXXXXXXX`, and a fixture repo dir
  `R=$(mktemp -d)/repo` with `R/.git` and `R/file`. The suite removes all
  of them on exit and never runs any `rm` the hook approves.
- A payload builder `pr_payload CMD CWD [SCRATCH]` producing the
  `PermissionRequest` JSON with `session_id`, `cwd`, `permission_mode`,
  `tool_use_id`, and optional `scratchpad_dir`.
- `allow_case`/`none_case` helpers asserting exit 0, exact stdout (the
  allow JSON, or empty), and empty stderr.
- Every case runs with `TMPDIR=$T` unless it says otherwise, so R2b is
  inactive and the scratchpad-root outcomes are unambiguous.
- Allow cases: scratch `rm -rf S/build`; `rmdir S/build`; `/bin/rm S/build/x`;
  relative `rm -rf ./build` with cwd `S`; `rm -- S/-x`; glob
  `rm -rf S/build/*` (matches only real children); two remove segments
  joined by `&&` and by `;` both in scope; newline-joined pair;
  `$T/x` (TMPDIR target); `/tmp/tmp.<id>` dir itself and a child;
  with TMPDIR unset: `/tmp/other/x` (R2b) and `rm -rf S` (the scratchpad
  root is a strict descendant of `/tmp`).
- No-decision cases: repo path `R/file`; mixed in/out targets; root
  itself `rm -rf S` (TMPDIR set); `S/../../etc`; `S/link/../victim` with
  `S/link -> R`; symlink `S/link -> R` for `S/link` and `S/link/file`;
  glob through a symlink `S/*/file` with `S/link -> R/` present; `$VAR`
  target; dotglob `S/.*`; `.git` target `S/.git`; checkout under a root
  `rm -rf S/repo/src` with `S/repo/.git` present; `/tmp/other` with
  TMPDIR set; `/tmp/tmp.<id2>` that is a symlink to `R` (both the entry
  and a child); `rmdir -p S/build/leaf` and `rmdir -pv S/build/leaf`;
  `/repo/rm S/x` and `./rm S/x`; `sudo rm S/x`; `FOO=1 rm S/x`;
  `sh -c 'rm S/x'`; `cd S && rm -rf build`; `rm S/x && ls`;
  `rm S/x | cat`; `rm S/x || true`; `rm S/x &`; `(rm S/x)`;
  `rm S/x > /dev/null`; `rm S/x>/dev/null`; `rm S/x>R/file`;
  `rm 'S/x` (unbalanced quote); `rm S/x ';' rm S/-x` (quoted
  separator); `rm *` with cwd `$T` containing a file named `-rf`
  (glob-expanded option word); `rm S/[[:alpha:]]*/file` and
  `rm S/[a-z]*` (brackets refused); `rm ~root/file` (named-user tilde)
  and `rm "~/tmpdir/file"` (quoted tilde); `/tmp` descendants with
  `TMPDIR=relative-tmp` (set but relative: no R2 root); `rm -rf $H/x`
  with TMPDIR unset and `$H` under `/tmp` (R2b never reaches HOME); `rmdir --par S/build`, `rm --rec S/build`, and
  `rm --interactive=never S/x` (long options outside the allowlist;
  `rm --recursive --force --verbose S/build` is an allow case); a
  recursive removal and a glob over a `chmod 000` directory under the
  R2a root (inspection errors, skipped when running as root);
  `rm S/x# R/file` (mid-token comment);
  `rm "-$(true)" S/x` and a backtick in an option token; `rm 'S/{a,b}/x'`
  and `rm S/{a,b}/x` (braces refused); `rm 'S/build/*'` (quoted glob);
  `rm -rf S/**/x` (recursive glob); `rm -rf $T/build/*` with
  `$T/build/.git` present (hidden-inclusive expansion finds it under the
  R2a root); `rm -rf $T/src` with `$T/.git` present (root-level checkout
  under R2a); `rm -rf $T/build` with `$T/build/project/.git` present
  (nested checkout in a recursive removal); missing `scratchpad_dir`
  with a scratch target (TMPDIR set); non-Bash tool; `PreToolUse` event;
  `permission_mode: plan`; malformed JSON; empty command; TMPDIR set to
  `$HOME` with a `$HOME/x` target; TMPDIR set to `/` with a `/etc` target.
- Allow cases that pin the R1/R3 exemption from step 7: `rm -rf S/clone`
  with `S/clone/.git` present (session-owned scratchpad) and
  `rm -rf /tmp/tmp.<id>/clone` with a `.git` inside it; and a regular
  file `/tmp/tmp.<id3>` created by `mktemp /tmp/tmp.XXXXXXXXXX` with
  TMPDIR set (R3 file entry).
- Defense in depth: `rm -rf /` -> rm_guard exit 2 and scratch_policy
  none; `rm -rf S/.git` -> rm_guard exit 2 and scratch_policy none;
  `rm -rf S/build/*` -> rm_guard exit 0 and scratch_policy allow.
- Logging: with `CLAUDE_CONFIG_DIR=<fixture>`, `HERDR_ENV=1`,
  `HERDR_WORKSPACE_ID=w1`, and a fixture index
  `herdr-orch/slug-x/workspaces/w1.json` + `tasks/`, an allow appends one
  line to `tasks/PROJ-1.policy.jsonl` with `v`, `ts`, `event`, `task_id`,
  `workspace_id`, `tool_use_id`, `command`; a no-decision appends
  nothing; without `HERDR_ENV` nothing is created under the fixture;
  an unwritable `tasks/` still prints the allow; a FIFO (`mkfifo`) at
  the sidecar path with no reader still prints the allow within the
  suite's 10-second bound and leaves the FIFO untouched; a symlink at
  the sidecar path is not followed; `events.jsonl` is never created.
- Static: template registers exactly this hook under
  `PermissionRequest` with matcher `Bash`; PreToolUse Bash order
  unchanged; hook is executable, shebang `#!/usr/bin/env python3`,
  `py_compile` clean; `scratch_policy.py` imports `rm_guard` and defines
  no `tokenize`/`split_segments`/`expand_braces`.

### D9. Files

| File | Change |
|---|---|
| `claude/hooks/scratch_policy.py` | New: the hook (D2-D7). |
| `claude/hooks/scratch-policy.test.sh` | New: the suite (D8). |
| `claude/settings.json.tmpl` | Add the `PermissionRequest` event (D1). |
| `bin/dotfiles-tests` | One line: `sh claude/hooks/scratch-policy.test.sh` after the `herdr-orch-contract` suite line. |
| `CLAUDE.md` | One symlink-targets bullet for `claude/hooks/scratch_policy.py` after the `herdr_stop_gate.py` bullet. |
| `claude/contracts/td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat-contract.json` | New: verification contract (kept after merge). |
| `docs/specs/`, `docs/plans/` | Branch-only; dropped before merge. |

No other tracked file changes (AC8).

## Acceptance criteria

- AC1 Registration: the template's `hooks.PermissionRequest` is exactly
  one matcher group `Bash` with exactly one command
  `~/.claude/hooks/scratch_policy.py`; the PreToolUse Bash command list
  is byte-identical to today's five entries in order; `permissions` and
  `env` are unchanged from base.
- AC2 Allow: for each in-scope shape in D8, stdout is exactly the allow
  JSON line, stderr empty, exit 0.
- AC3 No decision: for each out-of-scope shape in D8 (repo paths,
  `..` and symlink escapes including through globs, unresolvable
  targets, substitutions in any token, mid-token `#`, braces, quoted
  globs, `**`, `.git` targets, checkouts at or under a shared root and
  inside recursively removed subtrees, `rmdir -p`, non-standard
  executables, wrappers, non-remove segments, pipelines, background and
  subshell operators, redirections glued or standalone, malformed
  quoting, root itself, dotglob, missing scratchpad_dir, symlinked
  `tmp.*` roots, hostile `$TMPDIR`, non-Bash, other events, plan mode,
  malformed input), stdout and stderr are empty and exit is 0.
- AC3b Shared-root versus session-root distinction: a `.git` inside the
  R1 scratchpad or an R3 `mktemp` entry does not block removal, a `.git`
  at or under an R2 root does; a `mktemp` regular file under `/tmp` is
  in scope with `$TMPDIR` set.
- AC4 Defense in depth: `rm_guard.py` exits 2 on `rm -rf /` and on
  `rm -rf S/.git`, and the policy hook yields no decision on both
  payloads on its own; `rm_guard.py` exits 0 on the scratch shape the
  policy hook allows.
- AC5 Audit sidecar: under a fixture config dir with `HERDR_ENV=1` and
  a resolving workspace index, one allow appends exactly one
  `scratch-allow` line to `tasks/<task_id>.policy.jsonl` with the fields
  in D6; a no-decision appends nothing; with `HERDR_ENV` unset nothing is
  created; an unwritable `tasks/`, a reader-less FIFO at the sidecar
  path, and a symlink at the sidecar path each still yield the allow
  promptly (bounded by the suite's timeout) without writing through; no
  `*.events.jsonl` is ever created by the hook.
- AC6 Parsing reuse: `scratch_policy.py` contains `import rm_guard` and
  no `def tokenize`, `def split_segments`, or `def expand_braces`;
  `rm_guard.py` is unchanged from base.
- AC7 Suites: `bin/dotfiles-tests --list` includes
  `sh claude/hooks/scratch-policy.test.sh`; that suite passes under a
  throwaway `HOME`; `claude/hooks/claude-hooks.test.sh` keeps its 57
  `rmg:` passes; the full runner is green; the hook compiles and is
  executable with the python3 shebang.
- AC8 Scope: the set of tracked files changed against the merge base is
  exactly `CLAUDE.md`, `bin/dotfiles-tests`,
  `claude/hooks/scratch-policy.test.sh`, `claude/hooks/scratch_policy.py`,
  `claude/settings.json.tmpl`,
  `claude/contracts/td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat-contract.json`,
  and, while the branch is open, the two branch-only documents
  `docs/specs/2026-09-07-scratch-policy-hook.md` and
  `docs/plans/2026-09-07-scratch-policy-hook.md`; nothing else. All
  added lines are ASCII; no emoji; no attribution.
- AC9 Delivery: `reconcile_claude_settings_file` from
  `install/common/claude-links.sh`, run against the template into a
  fresh temp dir, produces a `settings.json` whose
  `hooks.PermissionRequest` matches AC1; `install/claude-links.test.sh`
  stays green.
- AC10 Human-verify (live, not in the contract; blocks the PR until
  recorded): on a reconciled machine, start an interactive session with
  `claude --permission-mode default --debug` in a throwaway git repo
  (default mode has no `rm` allow rule, so every `rm` reaches the ask
  path deterministically and the classifier is not involved), present
  the GateGuard facts, then: (a) run `rm -f <scratchpad>/probe` after
  creating the file: no dialog appears, the file is gone, and the debug
  log contains `executePermissionRequestHooks called for tool: Bash`
  followed by the hook's allow; (b) with `HERDR_ENV=1` and a resolving
  `HERDR_WORKSPACE_ID` exported into that session, the same removal
  appends one `scratch-allow` line to `tasks/<task_id>.policy.jsonl`
  carrying the payload's `scratchpad_dir`-derived path (proves the
  field is present interactively); (c) run `rm -f ./tracked-file` in
  the repo: the permission dialog appears and no "invalid hook JSON" or
  hook error line is logged for the no-decision path. Record all three
  outcomes in the PR description.

## Follow-ups (recorded, not deliverables)

- F1 Mech-tier launch recipe: add `--permission-prompts none` so a
  headless worker's residual asks are denied (or answered by this hook)
  instead of stalling. Confirmed present in 2.1.263; owned by
  `claude/hooks/herdr_orch_core.py` and the herdr-orchestration skill on
  the parity branch.
- F2 PreToolUse `permissionDecision: defer` flow for the small class of
  decisions a policy cannot make alone (`tool_deferred` exit, resume with
  `claude -p --resume <id>`). Same owner as F1.
- F3 Document `tasks/<task_id>.policy.jsonl` in
  `claude/skills/herdr-orchestration/references/state-layout.md` and
  `event-schema.md` (parity branch owns those files).
- F4 Headless path validation: in `-p` mode the Bash tool blocks `rm`
  outside the allowed working directories before any permission
  decision (`bashAllowRuleOverridable`), and `--permission-mode auto`
  reported `permission_mode: default`. The mech recipe must add the
  scratchpad/TMPDIR as allowed directories (`--add-dir`) or a Bash allow
  rule, or its scratch cleanup fails regardless of this hook.

## Alternatives rejected

- A `Bash(rm:*)` allow rule scoped by literal path prefixes: rules never
  resolve `~`, `$TMPDIR`, relative paths, or realpaths, which is the
  exact class of problem `rm_guard.py` exists for.
- Returning `allow` with `updatedInput` (e.g. a normalized command): the
  binary re-runs rule checks on updated input and may override; a bare
  allow is honored. Also needless.
- Appending `scratch-allow` to `workspaces/<ws>.events.jsonl`: breaks
  the documented single-writer rule and wakes the orchestrator on every
  scratch cleanup.
- Deriving the scratchpad root from `cwd` or from a hard-coded
  `/tmp/claude-<uid>` base when `scratchpad_dir` is absent: would allow
  other sessions' scratchpads and re-implements a private path scheme.
  `$TMPDIR` still covers mktemp cleanup in that case.
- Answering prompts from the orchestrator session: disallowed
  cross-session answering; the hook is the sanctioned mechanism.

## Verification gaps

- The interactive `PermissionRequest` path (hook consulted on the ask
  path, `scratchpad_dir` present, empty stdout treated as no decision)
  is inferred from the binary and the reference, not observed
  end-to-end: headless probes cannot reach the event without
  `--permission-prompts none`, and a live interactive prompt cannot be
  driven hermetically. AC10 closes this by hand with a deterministic
  trigger (`--permission-mode default`).
- Deny-rule precedence for a bare hook allow is undocumented in the
  reference; the spec relies on nothing about it (Verdict, deviation 1).
- Codex review provenance is recorded in the plan's review notes.
