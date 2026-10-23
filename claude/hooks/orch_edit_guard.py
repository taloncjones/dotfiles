#!/usr/bin/env python3
"""PreToolUse hook: refuse an orchestrator session's writes into any git
work tree.

The herdr orchestrator dispatches workers; it does not edit repo files.
The rule lives in the herdr-orchestration skill (Safety) and this hook
makes it structural. It is inert unless ALL hold: the payload is a
PreToolUse event for Edit, Write, or Bash; HERDR_ENV=1; the payload
session_id equals owner.json.session_id for at least one repo slug under
STATE_ROOT (the orchestrator claimed ownership with its own session id).
Workers, plain sessions, and headless mech/think runs never own a repo, so
they never reach a git call, let alone a refusal.

Guarded target: a path whose canonical form lies inside a git work tree
(a checkout under the scratchpad or $TMPDIR is still a checkout) and is
tracked, or untracked and not gitignored; paths with a `.todos` component
and paths under STATE_ROOT are exempt. Edit/Write use tool_input.file_path;
Bash targets are shell redirections (quote-aware raw scan, heredoc bodies
dropped), `sed -i`/`perl -i` operands, `tee` operands, `cp`/`install`
destinations, `mv` sources and destinations, `rm`/`rmdir` operands, git work-tree
writes (`commit`, `merge`, `cherry-pick`, `reset` and the rest of
GIT_WRITE_SUBCOMMANDS; the target is the --work-tree or -C directory, else
the cwd), and one level of `sh -c` (a combined flag cluster like `-lc`/`-ec` counts).

Escape hatch: `herdr_orch_core.py allow-edit` mints
STATE_ROOT/<slug>/orch-edit-allow.json under a live fence. The hook honours
it only for the session and fence it names, only for targets in that
slug's repo, only until it expires, and only for its write budget --
reserved claim-then-count in tasks/orch-edits.jsonl so parallel tool calls
cannot overshoot. Every guarded attempt (allowed or refused) is appended to
that log, best effort, after the decision.

Git work-tree writers pass only as an allowlist, and any other form that may
run one is refused for a launcher or lead, before any marker lookup, so no
marker can lift it. A command with a git writer verb passes the target scan
only when each git invocation is a plain simple command: `git [-C <path>]...
<writer> <args>`, every word a literal (no `$`, backtick, substitution or
glob), a literal verb, not behind a wrapper (env, command, nice, time, sudo,
exec, nohup, xargs, builtin, eval, timeout, a shell -c string and the like),
and the command has no heredoc, here-string or function definition. A `cd <literal>`
before it sets the cwd; a non-literal `cd` makes a later relative writer fail
closed. When unsure whether a word is a writer (`$GIT commit`, `git $VERB`)
the call is refused. Read-only verbs (`status`, `log`, `diff`, `fetch`) pass
with `-C "$W"`; a writer word as an argument of a wrapped or option-prefixed
read-only call (`timeout 5 git log --grep=merge`) is refused. There is no dry-run exemption; a literal
`clean -n` takes the normal marker path. `env -C`/`sudo -D` ahead of a
non-git writer (`sed -i`, `tee`) is refused too. `git merge --abort` in plain
form is not a work-tree write for the guard; a launcher's call is logged as
allowed.

Accepted holes (allow), listed exactly and mirrored in install-layout.md:
- Verbs outside GIT_WRITE_SUBCOMMANDS pass in any form, including `add`,
  `bisect`, `merge-file`, `mergetool`, `update-index`, `read-tree`,
  `checkout-index`, `submodule update`, `worktree add`, `branch -f`/`-D`,
  `update-ref`, `symbolic-ref`, `tag -f`, `reflog expire`, `gc --prune`,
  `filter-branch`, `sparse-checkout`.
- Git alias verbs (`git ci`, from ~/.gitconfig) read as non-writers, including
  a `-c alias.*` value taken from a variable or command substitution.
- A heredoc whose end marker is split by a backslash-newline, which hides the
  body's commands.
- Brace-expansion words, a verb passed from stdin to `xargs`, and the dashed
  `git-commit` binary.
- Work-tree retargeting without a work-tree flag: `--git-dir=<repo>/.git` or
  `GIT_DIR=<repo>/.git` from a non-repo cwd, `-c core.worktree=<repo>`, and
  the `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` env.
- Commands built or run outside the scanner: shell functions defined in an
  earlier Bash call, strings built wholly from variables (`eval "$CMD"`,
  `bash -c "$CMD"`, `sh -c "$VAR"`), scripts, inline interpreters (`python -c`,
  `perl -e`, `ruby -e`, `node -e`, `awk 'BEGIN{system()}'`), process
  substitution, `builtin cd`, a heredoc with no terminator, and git calls past
  the 10-second budget.
- A quoted git command line given to a head outside ARGUMENT_RUNNERS (`flock`,
  `su`, `ssh`, `tmux`, `screen`, `parallel`, `script`, `at`, `watch`, `runuser`,
  `sg`, `systemd-run`, `mosh`).
- Non-git writers: `patch`, `truncate`, `touch`, `mkdir`, `ln`, `rsync`, `dd`,
  editors, NotebookEdit/MultiEdit, and `awk`/`gawk -i inplace`; non-git
  targets built from `$VAR`/`$(...)`/globs (redirects, `sed -i`, `tee` keep
  their existing handling).
- A bare `cd` or `cd -`, read as a no-op by the cd tracker.
- The unknown-cd advisory never clearing after a later literal `cd` (it only
  over-refuses).
This is a guard against drift, not evasion. The guard targets momentum
mistakes; shapes that need deliberate obfuscation are accepted holes.

Scanner seams that fail closed: scan_raw drops a backslash-newline as the
shell does (an even backslash run is escaped backslashes, and a comment still
ends at its newline); a GIT_DIR/GIT_WORK_TREE prefix assignment or earlier
`export`/`declare` counts as the matching flag (non-literal value refused); a
git global option other than `-C`, `-c`, the `--git-dir`/`--work-tree`/
`--namespace` forms and `--no-pager -P --bare --literal-pathspecs
--no-optional-locks` is refused before a writer verb; a `-c alias.*` option is
refused when any word names a writer; a quoted argument that is a git command
line (`su -c`, `flock -c`, `ssh`, `parallel`) and `find -exec/-execdir/-ok/
-okdir` with a writer are refused. Under an ARGUMENT_RUNNERS head, any `git`
token plus a writer word in one argument is refused, as is a commit message
that names both.

A command naming more than TARGET_CAP (20) distinct canonical targets is an
overflow the guard cannot scan within its git budget. Nothing is silently
dropped: a privileged session (launcher or lead) is refused outright (fail
closed -- an unscanned target could be a tracked file hidden by alias
spellings or by one relative operand expanding across many retained `cd`
candidates), while a plain worker is allowed as always.

Deny is exit 2 with three stderr lines; allow is exit 0 and silent. On an
unexpected exception the verdict is routed through crash_verdict(): a
session identifiable as a launcher or lead fails CLOSED (exit 2, spec R9),
and only a session with no privileged identity keeps the fail-open default
(exit 0, matching the other guards) -- so no single reader or parser that
raises can un-fence a fenced session. Malformed state files still have
defined outcomes: a bad owner.json is skipped, a bad marker is no marker.
"""

import json
import math
import os
import re
import secrets
import shlex
import stat
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ under the hooks dir
sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_bindings as bindings
import herdr_capabilities as herdr_caps
import herdr_orch_core as core
import rm_guard
from workflow_context import account_scope, repository_context

TOOLS = ("Edit", "Write", "Bash")
SESSION_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z"
)
MARKER_ID_RE = re.compile(r"[0-9a-f]{16}\Z")
MARKER_FILE = "orch-edit-allow.json"
AUDIT_FILE = "orch-edits.jsonl"
TARGET_CAP = 20
GIT_BUDGET_SECS = 10.0
GIT_CALL_MAX_SECS = 5.0
PATH_MAX = 300
MAX_EDITS_RANGE = (1, 10)
CORE_CMD = "python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py"
BLOCKED = "Blocked: orch-edit-guard"
SENTINEL_RE = re.compile(r"__ORCH_REDIR_(\d+)__\Z")
SUBST_RE = re.compile(r"\$ORCHSUBST_(\d+)_")
WORD_STOP = " \t\n;&|()<>"
SHELL_WRAPPERS = ("sh", "bash", "zsh", "dash")
# Subcommands that change a work tree; `stash list|show` are reads.
GIT_WRITE_SUBCOMMANDS = frozenset({
    "commit", "merge", "cherry-pick", "revert", "rebase", "am", "apply", "reset",
    "stash", "restore", "checkout", "switch", "pull", "rm", "mv", "clean",
})
GIT_VALUE_OPTIONS = ("-C", "-c", "--git-dir", "--work-tree", "--namespace")
GIT_BARE_OPTIONS = frozenset({
    "--no-pager", "-P", "--bare", "--literal-pathspecs", "--no-optional-locks",
})
GIT_ENV_TARGETS = ("GIT_DIR", "GIT_WORK_TREE")
ENV_DECLARERS = frozenset({"export", "declare", "typeset", "local", "readonly"})
# Commands that run another command; a git writer behind one is refused.
WRAPPER_HEADS = frozenset({
    "env", "command", "nice", "time", "sudo", "exec", "nohup", "xargs", "builtin",
    "eval", "timeout", "stdbuf", "setsid", "ionice", "caffeinate", "doas",
    "unbuffer", "chronic", *SHELL_WRAPPERS,
})
CWD_WRITERS = frozenset({"sed", "gsed", "perl", "tee", "cp", "install", "mv", "rm", "rmdir"})
HEREDOC_RE = re.compile(r"(?<!<)<<(?!<)")
FUNCTION_RE = re.compile(r"(?:^|[\s;&|(){}])function\s|[\w.:-]\s*\(\s*\)")
# A multi-word argument that is itself a git command line (`su -c 'git ...'`).
QUOTED_GIT_RE = re.compile(
    r"(?m)(?:^|[;&|(])\s*(?:\S*/)?git\s|(?:^|\s)git\s+(?:-C|-c|--)"
)
# Heads that run a quoted argument as a command line.
ARGUMENT_RUNNERS = frozenset({
    "flock", "su", "ssh", "tmux", "screen", "parallel", "script", "at", "watch",
    "runuser", "sg", "systemd-run", "mosh",
})
GIT_TOKEN_RE = re.compile(r"(?<![\w.-])git(?![\w-])")
FIND_EXEC_OPTIONS = frozenset({"-exec", "-execdir", "-ok", "-okdir"})
WRITER_WORD_RE = re.compile(
    r"(?<![\w-])(?:" + "|".join(sorted(GIT_WRITE_SUBCOMMANDS)) + r")(?![\w-])"
)


class Budget:
    """One monotonic deadline shared by every git call of an invocation."""

    def __init__(self, secs):
        self.deadline = time.monotonic() + secs

    def slice(self):
        return min(GIT_CALL_MAX_SECS, self.deadline - time.monotonic())


def git(args, cwd, budget):
    """(returncode, stdout); (None, "") on timeout, a missing git, or an
    exhausted budget. Every caller treats None as 'not guarded'."""
    left = budget.slice()
    if left <= 0:
        return None, ""
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    # surrogateescape: a non-UTF-8 pathspec makes git echo raw bytes in its
    # diagnostics, and a strict decode raised UnicodeDecodeError past every
    # caller into the top-level fail-open handler (co-review r7). Decode
    # losslessly, and treat any residual decode failure as this one probe
    # being unguarded -- never as the whole hook crashing open.
    try:
        p = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            timeout=left,
            env=env,
            check=False,
        )
        # Decode ourselves: text=True would also translate universal newlines,
        # turning a legal `\r` inside a path into `\n` and breaking the
        # containment comparison (co-review r10). Bytes in, lossless out.
        return p.returncode, p.stdout.decode("utf-8", "surrogateescape")
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None, ""


# --- state root reads ------------------------------------------------------


def read_state_json(path):
    """Parsed regular payload object, or None for an invalid record.

    Total over arbitrary on-disk content: any read or decode error -- including
    a RecursionError from deeply nested JSON, which is not a ValueError -- is
    "no record". This reader feeds owned_slugs(), which runs BEFORE lead
    discovery on every path, so an unrelated malformed owner.json must never
    escape to the top-level fail-open handler and un-fence a contained lead."""
    try:
        data = json.loads(core.read_payload_text(path))
    except Exception:  # noqa: BLE001 -- a bad state record is no record, never a crash
        return None
    return data if isinstance(data, dict) else None


def selected_scope(cwd, runtime):
    personal = (
        os.environ.get("HERDR_PERSONAL") == "1"
        or os.environ.get("WORKFLOW_PERSONAL_ACCOUNT") == "1"
    )
    return account_scope(cwd, runtime, personal=personal)


def owned_slugs(session_id, runtime, caller_scope, candidates):
    """Caller-account owners and independently resolved target scopes."""
    owned = {}
    personal = (
        os.environ.get("HERDR_PERSONAL") == "1"
        or os.environ.get("WORKFLOW_PERSONAL_ACCOUNT") == "1"
    )
    targets = {}
    for slug, top in candidates.items():
        try:
            context = repository_context(top)
            scope = account_scope(context["root"], runtime, personal=personal)
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        targets[slug] = {"context": context, "scope": scope}
    root = core.account_payload_root(caller_scope) / "herdr-orch"
    try:
        names = core.payload_names(root)
    except (OSError, ValueError):
        return owned
    for slug in sorted(name for name in names if core.valid_repo_slug(name)):
        rd = root / slug
        rec = read_state_json(core.coordination.owner_path(rd))
        if not (
            rec
            and rec.get("runtime", "claude") == runtime
            and rec.get("session_id") == session_id
            and rec.get("account_id") == caller_scope["account_id"]
            and isinstance(rec.get("fence"), int)
            and not isinstance(rec.get("fence"), bool)
            and rec.get("control_tier", "launcher") == "launcher"
        ):
            continue
        entry = {"fence": rec["fence"], "rd": rd, "caller_scope": caller_scope}
        if slug in targets:
            entry.update(targets[slug])
        owned[slug] = entry
    return owned


def lead_admissible(rd, slug, account_id, caller_scope, workspace_root, seen=None):
    """Is a lead in this workspace admissible right now? Total; False on doubt.

    Delegates to core.task_lead_admission -- the SAME decision admission makes
    at claim time -- rather than re-deriving a partial one here. The guard
    previously checked only the gate record plus `GUARD_CAPABILITY <
    REQUIRED_CAPABILITY`, which is `1 < 1` and therefore dead as written: the
    procedure's advertised capability was never consulted on this side at all,
    so the second lock existed at admission only.

    The repo_id is resolved LIVE from the workspace, not taken from the
    binding record. The binding's copy is nullable, so passing it made a
    gate record that names a repository identity unverifiable from here --
    gate_enabled refuses an uncorroborated claim, fail-closed -- and an
    admitted lead ended up with zero authorized roots permanently. Admission
    passes the live value, so the guard must too, or the two locks disagree
    about the same lead.

    A workspace whose repository context will not resolve yields no roots.

    Cost discipline. Resolving the context spends SIX git subprocesses on a
    linked worktree -- five on a plain checkout, but herdr workspaces ARE
    linked worktrees, so six is the normal case, and the extra call is
    `worktree list --porcelain -z`, the slowest of the set -- each at up to
    GIT_CALL_MAX_SECS, and all of them outside the Budget the rest of this
    hook's git calls share. A PreToolUse hook that overruns its timeout lets
    the tool call through, so an expensive check is a fail-open risk and not
    merely slow.

    Two bounds. First the gate is READ before any subprocess, rather than
    merely tested for existence: `deactivate-task-leads` writes
    `enabled: false` instead of removing the record, so after step 2 of the
    documented rollback an existence test is true forever and the expensive
    path becomes the permanent steady state. The pre-check passes
    IDENTITY_DEFERRED, not None -- None would refuse a record that names a
    concrete identity, which is the right final answer but the wrong
    pre-check, since it rejects leads the full check admits. Second, `seen`
    memoizes the resolution per workspace, so a session holding several leases
    pays once per distinct workspace rather than once per lease.
    """
    config_dir = Path(caller_scope["account_root"])
    try:
        # The SAME admission, minus the one clause the sentinel defers -- not a
        # hand-copy of its cheap terms. An earlier version of this function
        # carried a partial copy that drifted into a dead `1 < 1` test and
        # never consulted the procedure at all, which is why the docstring
        # above says to delegate. A second copy drifts the same way: add a
        # fourth component to the required set and the copy admits what the
        # real check refuses.
        pre_admit, _pre_why, _pre_levels = core.task_lead_admission(
            rd, slug, account_id, config_dir, herdr_caps.IDENTITY_DEFERRED)
    except Exception:  # noqa: BLE001 -- an undecidable admission withholds the root
        return False
    if not pre_admit:
        return False
    if seen is None:
        seen = {}
    if workspace_root not in seen:
        try:
            seen[workspace_root] = repository_context(workspace_root)["repo_id"]
        except (OSError, ValueError, subprocess.SubprocessError, KeyError):
            seen[workspace_root] = False
    repo_id = seen[workspace_root]
    if repo_id is False:
        return False
    try:
        admit, _reason, _levels = core.task_lead_admission(
            rd, slug, account_id, config_dir, repo_id)
    except Exception:  # noqa: BLE001 -- an undecidable admission withholds the root
        return False
    return bool(admit)


def corroborated_lead(payload_root, session_id, runtime, account_id=None):
    """Is this session named by a binding at a LIVE registry occupancy?

    Recognition that survives deletion of the lead lease. The lease is one
    file, and deleting it used to reclassify a live lead as an ordinary
    worker -- a WIDER classification, so destroying the evidence granted
    more access. Two records in independently-failing trees must now agree:
    the coordination registry says a workspace is occupied by a binding id,
    and that binding record names this session.

    This never grants a root, only sets is_lead, so it can only NARROW
    access. That is precisely why a record from the payload root is safe to
    consult here even though the guard exempts that tree from
    classification and a fenced session can therefore write it: a forged
    record denies its author and nobody else.

    A cleared occupancy ends the classification, which is what keeps a
    stale non-terminal binding -- reachable by a crash mid-teardown, or by
    reconcile-leads' replayed-lease cleanup, which releases with no status
    write -- from bricking a resumed session permanently.

    account_id None skips the account match, for privileged_anywhere, which
    has no scope from which to derive one; its over-match is documented and
    safe. Total: no failure here may escape into the guard's fail-open
    handler.
    """
    try:
        occupancies = core.coordination.occupied_lead_bindings()
    except Exception:  # noqa: BLE001 -- an unreadable registry corroborates nothing
        return False
    for slug, keyed in occupancies.items():
        for binding_id in keyed.values():
            # Broad by necessity: read_binding raises ValueError on a corrupt
            # record, but open_state_parent lets any non-FileNotFoundError
            # OSError through, and a leaked OSError would reach crash_verdict
            # and answer "not privileged" for the very lead this exists to
            # catch.
            try:
                rec = bindings.read_binding(Path(payload_root) / slug, binding_id)
            except Exception:  # noqa: BLE001, S112 -- an unreadable binding corroborates nothing
                continue
            if (
                rec is not None
                and rec.get("status") in ("issued", "claimed")
                and rec.get("expected_session_id") == session_id
                and rec.get("runtime") == runtime
                and (account_id is None or rec.get("account_id") == account_id)
            ):
                return True
    return False


def lead_authority(session_id, runtime, caller_scope):
    """(is_lead, [authorized workspace_root, ...]) for this session.

    Discovery is from the AUTHORITATIVE coordination namespace, not the
    payload root: a session is a lead if any coordination slug holds a lead
    lease naming it (session_id + account + runtime + control_tier lead, valid
    record). This keeps a lead classified -- and therefore fenced -- even when
    its payload-root slug directory or binding file has been removed.

    A workspace_root is AUTHORIZED only when the lease's dispatch binding is
    present, valid, not terminal (issued|claimed), issued by a launcher
    parent, of tier lead, and agrees with the lease/context on runtime,
    repo_slug, workspace_root, account, and expected session. A missing,
    corrupt, revoked, completed, or mismatched binding leaves the session a
    lead (is_lead True) with that workspace_root withheld -- fail closed.

    Classification also survives deletion of the LEASE, via
    corroborated_lead: a live registry occupancy whose binding record names
    this session. It ends when the registry records the release, so a stale
    non-terminal binding cannot keep a session classified. Unlike the lease
    path above, that corroboration reads the account payload root, so --
    unlike the lease path -- it does NOT survive removal or alteration of
    the binding record or of the payload root (spec S8).
    """
    payload_root = core.account_payload_root(caller_scope) / "herdr-orch"
    is_lead = False
    roots = []
    seen = {}
    account_id = caller_scope["account_id"]
    for slug in core.coordination.coordination_slugs():
        try:
            leases = core.coordination.iter_lead_leases(slug)
        except (OSError, ValueError):
            continue
        for lease in leases:
            if (
                lease.get("session_id") != session_id
                or lease.get("account_id") != account_id
                or lease.get("runtime", "claude") != runtime
                or lease.get("control_tier") != "lead"
            ):
                continue
            is_lead = True
            ws = lease.get("workspace_root")
            binding_id = lease.get("binding_id")
            try:
                rec = bindings.read_binding(payload_root / slug, binding_id)
            except Exception:  # noqa: BLE001 -- any read/validate error withholds the root (fail closed)
                rec = None
            if (
                rec is not None
                and rec.get("status") in ("issued", "claimed")
                and rec.get("parent", {}).get("tier") == "launcher"
                and rec.get("tier") == "lead"
                and rec.get("runtime") == runtime
                and rec.get("repo_slug") == slug
                and rec.get("workspace_root") == ws
                and rec.get("account_id") == account_id
                and rec.get("expected_session_id") == session_id
                and ws not in roots
            ):
                if not lead_admissible(payload_root / slug, slug, account_id,
                                       caller_scope, ws, seen):
                    continue
                roots.append(ws)
    if not is_lead:
        # The lease is gone or never named this session. A live registry
        # occupancy whose binding names it still does -- fail closed.
        is_lead = corroborated_lead(payload_root, session_id, runtime, account_id)
    return is_lead, roots


def env_payload_roots():
    """Account payload roots derivable from the environment alone.

    privileged_anywhere runs where the account scope could not be derived,
    or must not be: deriving it spends a git subprocess, and one of its two
    call sites is reached precisely when subprocesses are failing or timing
    out. A PreToolUse hook that overruns its timeout fails OPEN, so the
    scope-free derivation is a correctness requirement, not a shortcut.

    These are every root account_payload_root can return, including both
    the resolved and unresolved spellings of HOME: account_payload_root
    builds its personal-scope root from Path.home().resolve(), but
    coordination.payload_path does not resolve symlinks (it only rewrites
    a leading /tmp or /var to /private on macOS), so a symlinked HOME
    needs both spellings covered here or the resolved one is missed.
    Skipping the macOS normalization would also make open_state_parent's
    O_NOFOLLOW walk fail with ELOOP and silently under-match.

    A "custom" account kind needs no entry: it arises only on the branch
    where CLAUDE_CONFIG_DIR is explicitly set, which is already covered.
    Over-matching across candidates is this function's documented and safe
    direction -- a match still requires a binding to name the session.
    """
    home = Path(os.environ.get("HOME", os.path.expanduser("~")))
    homes = [home]
    try:
        resolved_home = home.resolve()
    except Exception:  # noqa: BLE001, S112 -- an unresolvable HOME is skipped
        resolved_home = None
    if resolved_home is not None and resolved_home != home:
        homes.append(resolved_home)
    candidates = []
    for one_home in homes:
        candidates.append(one_home / ".claude")
        candidates.append(one_home / ".claude-work")
    for name in ("CLAUDE_CONFIG_DIR", "CLAUDE_WORK_CONFIG_DIR"):
        value = os.environ.get(name)
        if value:
            candidates.append(Path(value))
    roots = []
    for candidate in candidates:
        try:
            root = core.coordination.payload_path(candidate) / "herdr-orch"
        except Exception:  # noqa: BLE001, S112 -- an unusable candidate is skipped
            continue
        if root not in roots:
            roots.append(root)
    return roots


def privileged_anywhere(session_id, runtime):
    """Scope-independent: does ANY coordination record name this session as
    a launcher (a slug's owner.json) or a lead (a lead-*.json lease)?

    Used where the account scope cannot be derived: account_scope() reads
    repository metadata (`git branch --show-current`, strict UTF-8) and can
    raise on a legal non-UTF-8 branch name, yet the session's coordination
    records stay readable. Ignoring account_id here can only over-match (a
    false deny for a session privileged under another account), never
    under-match. Total: an unreadable coordination root is False.

    A deleted lease is also covered: a live registry occupancy whose
    binding record names this session reports privileged, resolved against
    environment-derived payload roots so no subprocess is added to a path
    reached when subprocesses are already failing. account_id is
    deliberately not matched here -- there is no scope from which to derive
    one, and over-matching is this function's safe direction.

    One limit, by construction: the corroboration runs only if the scan
    above did not itself raise, because that except returns first. So an
    unreadable coordination root still answers False without consulting the
    registry. Reordering to fix that would let a raise in the newer code
    skip the lease scan entirely, which is the worse trade.
    """
    try:
        for slug in core.coordination.coordination_slugs():
            rec = read_state_json(
                core.coordination.coordination_root() / slug / "owner.json"
            )
            if (
                rec
                and rec.get("session_id") == session_id
                and rec.get("runtime", "claude") == runtime
                and rec.get("control_tier", "launcher") == "launcher"
            ):
                return True
            # Per-slug isolation (co-review r10): a listing error in one slug
            # must not abort the scan before a later slug's valid record --
            # otherwise a fenced session reads as unprivileged and is allowed.
            try:
                leases = core.coordination.iter_lead_leases(slug)
            except Exception:  # noqa: BLE001, S112 -- skip this slug, keep scanning
                continue
            for lease in leases:
                if (
                    lease.get("session_id") == session_id
                    and lease.get("runtime", "claude") == runtime
                ):
                    return True
    except Exception:  # noqa: BLE001 -- unreadable namespace: cannot identify
        return False
    # After the existing scan, never before it: this whole function's body
    # is inside one broad except that returns False, so a raise in new code
    # placed first would skip the lease scan entirely and read an intact
    # lease as unprivileged -- a regression on today's behaviour.
    try:
        for payload_root in env_payload_roots():
            if corroborated_lead(payload_root, session_id, runtime):
                return True
    except Exception:  # noqa: BLE001, S110 -- best effort; the lease scan already answered
        pass
    return False


# --- paths and classification ---------------------------------------------


def canonical_target(word, cwd, home):
    """True canonical destination of a raw write token, or None to skip.

    Resolves from the RAW token (spec A1): the token is joined to its cwd
    WITHOUT a lexical normpath, then os.path.realpath resolves symlinks and
    `..` together, so a `..` that follows a symlink escapes correctly and a
    `.todos`/STATE_ROOT component produced only by an unresolved `..` cannot
    grant a false exemption (H1). realpath handles a nonexistent tail by
    resolving the longest existing prefix and appending the rest.

    None means "not a guardable target": an empty token, or one carrying a
    NUL byte or any path value os.path cannot process (H2 -- the caller skips
    it rather than letting the exception fail the whole hook open)."""
    word = rm_guard.expand_home(word, home)
    if not word or "\x00" in word:
        return None
    joined = word if word.startswith("/") else os.path.join(cwd, word)
    try:
        return os.path.realpath(joined)
    except (OSError, ValueError, RecursionError):
        # RecursionError: an older recursive realpath on a long symlink
        # chain; this one target is unguardable, the others still scan.
        return None


def exempt(c, state_real):
    if ".todos" in c.split("/"):
        return True
    return c == state_real or c.startswith(state_real + "/")


def git_toplevel(c, budget):
    """Work-tree root of the directory a git command acts in, else `c`."""
    d = c if os.path.isdir(c) else os.path.dirname(c)
    while d != "/" and not os.path.isdir(d):
        d = os.path.dirname(d)
    rc, out = git(["rev-parse", "--show-toplevel"], d, budget)
    if rc != 0 or not out:
        return c
    return os.path.realpath(out.removesuffix("\n"))


def classify(c, budget):
    """(toplevel, 'tracked'|'untracked') when `c` is guarded, else None:
    outside every work tree, inside .git/, gitignored, or git failed."""
    d = c if os.path.isdir(c) else os.path.dirname(c)
    while d != "/" and not os.path.isdir(d):
        d = os.path.dirname(d)
    # Two calls, parsed losslessly: the combined form's splitlines() misparsed
    # a work-tree root containing a newline, returned "not guarded", and let
    # a write into such a repo bypass containment (co-review r9). git ends the
    # path with exactly one newline; strip only that, never embedded ones.
    rc, out = git(["rev-parse", "--show-toplevel"], d, budget)
    if rc != 0 or not out:
        return None
    rc, inside = git(["rev-parse", "--is-inside-git-dir"], d, budget)
    if rc != 0 or inside.strip() != "false":
        return None
    top = os.path.realpath(out.removesuffix("\n"))
    if c != top and not c.startswith(top + "/"):
        return None
    # The work tree root itself (`mv /repo /tmp/x`) is guarded when it has
    # any tracked content: ls-files on "." exits 0 in that case.
    rel = os.path.relpath(c, top)
    # --literal-pathspecs: a legal filename beginning with `:(` (e.g.
    # `:(glob)x`) is otherwise read as pathspec magic -- ls-files reports no
    # match, check-ignore rejects it, and the target is "not guarded"
    # (co-review r10). Every operand here is a literal path, never a pattern.
    rc, _ = git(
        ["--literal-pathspecs", "ls-files", "--error-unmatch", "--", rel], top, budget
    )
    if rc == 0:
        return top, "tracked"
    if rc is None:
        return None
    # check-ignore does not support literal-pathspec magic (rc 128), so the
    # leading-colon magic is neutralized with a `./` prefix instead.
    rc, _ = git(["check-ignore", "-q", "--", "./" + rel], top, budget)
    return (top, "untracked") if rc == 1 else None


def repo_slug_of(top, budget, cache):
    """core.repo_slug of a work tree, the orchestrator's own derivation."""
    if top not in cache:
        rc, url = git(["remote", "get-url", "origin"], top, budget)
        rc2, common = git(["rev-parse", "--git-common-dir"], top, budget)
        slug = None
        if rc2 == 0 and common.strip():
            cd = common.strip()
            cd = cd if os.path.isabs(cd) else os.path.join(top, cd)
            # Total: git output is decoded with surrogateescape, so a
            # non-UTF-8 origin URL reaches repo_slug() with surrogates that
            # its strict .encode() rejects (UnicodeEncodeError). That raised
            # past decide() into the fail-open handler (co-review r8). An
            # underivable slug is None, which both the launcher path (scope
            # deny) and the lead path (workspace check) treat as fail closed.
            try:
                slug = core.repo_slug(url.strip() if rc == 0 else "", cd)
            except Exception:  # noqa: BLE001 -- underivable slug is None, never a crash
                slug = None
        cache[top] = slug
    return cache[top]


# --- Bash: pass 1, raw scan ------------------------------------------------


def read_word(text, j):
    """Quote-aware word starting at text[j]: (word, end). Quotes are
    removed and backslash escapes resolved; `$` and backticks are kept
    verbatim so resolve_targets can skip what the shell would expand."""
    n = len(text)
    out = []
    quote = None
    while j < n:
        c = text[j]
        if quote:
            if quote == '"' and c == "\\" and j + 1 < n:
                out.append(text[j + 1])
                j += 2
                continue
            if c == quote:
                quote = None
                j += 1
                continue
            out.append(c)
            j += 1
            continue
        if c in "'\"":
            quote = c
            j += 1
            continue
        if c == "\\" and j + 1 < n:
            out.append(text[j + 1])
            j += 2
            continue
        if c in WORD_STOP:
            break
        out.append(c)
        j += 1
    return "".join(out), j


def io_number_start(out):
    """Index in `out` where an IO-number prefix of the operator at the end
    begins: a run of digits that forms a whole word (`2>`), or a lone `&`
    (`&>`); len(out) when there is no such prefix (`file2>` keeps its
    digits -- they belong to the filename, bash only treats digits as a
    descriptor when they are the entire preceding word)."""
    k = len(out)
    while k > 0 and len(out[k - 1]) == 1 and out[k - 1].isdigit():
        k -= 1
    if k < len(out) and (
        k == 0 or out[k - 1] in (" ", "\t", "\n", ";", "&", "|", "(", ")")
    ):
        return k
    k = len(out)
    if k > 0 and out[k - 1] == "&":
        return k - 1
    return k


def scan_raw(text):
    """(cleaned, redirs). One quote-aware pass: comments and heredoc bodies
    are dropped; every OUTPUT redirection operator plus its target word is
    replaced by a sentinel word so pass 2 sees it inside the right segment
    but never as a command operand; redirs maps sentinel number -> target.
    Input redirections (`<`, `<>`, `<<<`) and their operands are consumed
    and blanked without producing a target, so they never become a
    cp/mv/tee operand either. Only unquoted characters are operators: a
    quoted `>` or `<<` is data. Descriptor dups (`>&2`, `2>&1`) and process
    substitution yield no target. A heredoc with no terminator swallows
    the rest (allow)."""
    n = len(text)
    out = []
    redirs = {}
    heredocs = []  # (word, strip_tabs) pending on the current line
    arith_paren = 0  # open '(' still needed to close a $(( ... )) we're in
    arith_bracket = 0  # open '[' still needed to close a $[ ... ] we're in
    i = 0
    join_end = -1  # index just past the last backslash-newline join
    quote = None
    while i < n:
        c = text[i]
        if quote:
            if quote == '"' and c == "\\" and i + 1 < n:
                if text[i + 1] == "\n":
                    i += 2
                    join_end = i
                    continue
                out.append(text[i : i + 2])
                i += 2
                continue
            if c == quote:
                quote = None
            out.append(c)
            i += 1
            continue
        if c in "'\"":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            if text[i + 1] == "\n":  # the shell drops a backslash-newline
                i += 2
                join_end = i
                continue
            out.append(text[i : i + 2])
            i += 2
            continue
        prev = (out[-1][-1:] if out else "") if i == join_end else text[i - 1 : i]
        if c == "#" and (prev == "" or prev in " \t\n;&|("):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "\n":
            out.append(c)
            i += 1
            for word, strip_tabs in heredocs:
                while i < n:
                    j = text.find("\n", i)
                    j = n if j < 0 else j
                    line = text[i:j]
                    i = j + 1 if j < n else n
                    if (line.lstrip("\t") if strip_tabs else line) == word:
                        break
            heredocs = []
            continue
        # $(( ... )) / $[ ... ] (B-1): a '<<' inside arithmetic is a shift
        # operator, not a heredoc. Paren/bracket balance alone locates the
        # close, since any nested $(...)/[...] inside is itself balanced.
        if arith_paren == 0 and arith_bracket == 0:
            if c == "$" and text.startswith("$((", i):
                arith_paren = 2
                out.append("$((")
                i += 3
                continue
            if c == "$" and text.startswith("$[", i):
                arith_bracket = 1
                out.append("$[")
                i += 2
                continue
        elif arith_paren > 0:
            if c == "(":
                arith_paren += 1
            elif c == ")":
                arith_paren -= 1
            out.append(c)
            i += 1
            continue
        elif arith_bracket > 0:
            if c == "[":
                arith_bracket += 1
            elif c == "]":
                arith_bracket -= 1
            out.append(c)
            i += 1
            continue
        if c == "<":
            if (
                text.startswith("<<<", i)
                or text.startswith("<>", i)
                or not text.startswith("<<", i)
            ):
                # input redirection (<, <>, <<<): consume the operator, an
                # IO number before it, and the operand; never a target
                j = i + (
                    3
                    if text.startswith("<<<", i)
                    else 2
                    if text.startswith("<>", i)
                    else 1
                )
                m = j
                while m < n and text[m] in " \t":
                    m += 1
                del out[io_number_start(out) :]
                if m < n and text[m] == "&":
                    e = m + 1
                    while e < n and text[e].isdigit():
                        e += 1
                else:
                    _w, e = read_word(text, m)
                out.append(" ")
                i = e
                continue
            j = i + 2  # heredoc
            strip_tabs = False
            if j < n and text[j] == "-":
                strip_tabs = True
                j += 1
            while j < n and text[j] in " \t":
                j += 1
            word, j = read_word(text, j)
            heredocs.append((word, strip_tabs))
            del out[io_number_start(out) :]  # 0<<EOF: the IO number goes too
            out.append(" ")
            i = j
            continue
        if c == ">":
            j = i + 1
            if j < n and text[j] in ">|":
                j += 1
            m = j
            while m < n and text[m] in " \t":
                m += 1
            del out[io_number_start(out) :]  # 2> / &> prefix, if any
            if m < n and text[m] == "&":
                e = m + 1
                while e < n and text[e].isdigit():
                    e += 1
                if e > m + 1:  # dup: >&2, 2>&1
                    out.append(" ")
                    i = e
                    continue
                if e < n and text[e] == "-":  # close: >&-
                    out.append(" ")
                    i = e + 1
                    continue
                # bare '&' with no digit/'-' after it: >&file / >>&file
                # redirects stdout+stderr to a FILENAME, not a dup (B2).
                m = e
                while m < n and text[m] in " \t":
                    m += 1
            if m < n and text[m] == "(":  # process substitution
                out.append(" ")
                i = m
                continue
            word, e = read_word(text, m)
            if word:
                # Key by the exact generated sentinel string so pass 2 looks
                # it up verbatim and never int()-converts command text.
                sentinel = f"__ORCH_REDIR_{len(redirs)}__"
                redirs[sentinel] = word
                out.append(f" {sentinel} ")
            else:
                out.append(" ")
            i = e
            continue
        out.append(c)
        i += 1
    return "".join(out), redirs


# --- Bash: pass 2, per-segment operands -----------------------------------


def has_inplace(words):
    """Accepted gap (A7): a sed `w file` command or `s///w file` flag also
    writes a file with no `-i` present; catching it needs parsing the sed
    SCRIPT text itself, not just its own argv flags. Aligns with the
    documented "sed without -i passes" hole."""
    for t in words[1:]:
        if t == "--in-place" or t.startswith("--in-place="):
            return True
        if t.startswith("-") and not t.startswith("--") and "i" in t[1:]:
            return True
    return False


def script_operands(words, value_opts, script_flags):
    """Operands of a sed/perl segment that has an in-place flag, minus
    option values; the first operand is the script unless an explicit
    script option (-e/-f, or a bundled -ne/-pe cluster) is present.

    Accepted gap (cycle-3 A-6): a clustered script flag (`perl -i -pe
    's/x/y/' file`) sets explicit=True but doesn't skip the script string
    itself, so it lands in `ops` alongside the real file. _existing()
    drops it (it's not an existing path), so the real file is still
    guarded -- no live miss, only a spurious over-guard if the script
    text ever equalled an existing filename."""
    if not has_inplace(words):
        return []
    explicit = False
    ops, skip = [], False
    for t in words[1:]:
        if skip:
            skip = False
            continue
        if t in value_opts:
            skip = True
            explicit = True
            continue
        if any(t.startswith(v + "=") for v in value_opts if v.startswith("--")):
            explicit = True
            continue
        if (
            t.startswith("-")
            and not t.startswith("--")
            and len(t) > 1
            and any(ch in t[1:] for ch in script_flags)
        ):
            explicit = True
            continue
        if t.startswith("-") and len(t) > 1:
            continue
        if t == "":
            continue
        ops.append(t)
    if not explicit and ops:
        ops = ops[1:]
    return ops


def tee_operands(words):
    ops, rest = [], False
    for t in words[1:]:
        if rest or t == "-" or not t.startswith("-"):
            ops.append(t)
        elif t == "--":
            rest = True
    return ops


def copy_targets(words, cwd, home, include_sources):
    """cp/install: the destination (or dest/basename(src) per source when
    the destination is an existing directory). mv: the same plus every
    source, because a move deletes the source path.

    Accepted gap (A1): a source that is itself a tracked symlink is
    resolved by resolve_targets/canonical_target() through its final target,
    not as
    the symlink entry mv actually removes; catching that needs a
    dereference-mode flag threaded through every target tuple, not a
    local fix here.

    Accepted gap (cycle-3 A-5): `cp -r a/ /destdir/` computes dest as
    basename('/destdir/') == '' -> '/destdir' rather than '/destdir/a'.
    Harmless: '/destdir' is a parent of the real target, so it is guarded
    whenever the real target would be -- no live miss, latent imprecision
    only."""
    ops, tdir, skip = [], None, False
    for t in words[1:]:
        if skip:
            tdir = t
            skip = False
            continue
        if t in ("-t", "--target-directory"):
            skip = True
            continue
        if t.startswith("--target-directory="):
            tdir = t.split("=", 1)[1]
            continue
        if t.startswith("-") and len(t) > 1:
            continue
        ops.append(t)
    if tdir is None:
        if len(ops) < 2:
            return []
        dest, srcs = ops[-1], ops[:-1]
    else:
        dest, srcs = tdir, ops
    out = []
    # Probe the REALPATH destination, not the normpath one: a `dest` like
    # `link/../out` with a symlinked `link` resolves to a different directory
    # than its lexical spelling, so a normpath probe could pick the wrong
    # dir-vs-file branch and drop the source basename (A1). The emitted target
    # stays the RAW join so the single resolve_targets chokepoint canonicalizes.
    try:
        dprobe = os.path.realpath(os.path.join(cwd, rm_guard.expand_home(dest, home)))
    except (OSError, ValueError, RecursionError):
        dprobe = ""
    if dprobe and os.path.isdir(dprobe):
        out.extend(os.path.join(dest, os.path.basename(s)) for s in srcs)
    else:
        out.append(dest)
    if include_sources:
        out.extend(srcs)
    return out


def _existing(ops, cwd, home):
    # Probe existence on the REALPATH of the raw token, not its normpath: a
    # `sed -i`/`perl -i` operand like `link/../f` (with a symlinked `link`)
    # has a lexical spelling that may not exist while its true target does,
    # and a normpath probe would drop the real, guardable file (A1). Emit the
    # raw `w` so the resolve_targets chokepoint still canonicalizes it.
    kept = []
    for w in ops:
        p = canonical_target(w, cwd, home)
        if p is not None and os.path.lexists(p):
            kept.append(w)
    return kept


def shell_c_arg(words):
    """Like rm_guard.extract_shell_c_arg, but a flag CLUSTER containing
    `c` (`-lc`, `-ec`) is also a `-c <script>` invocation, not just a
    standalone `-c` -- the ordinary login/exit-on-error spellings that
    rm_guard's exact-token match misses (B1)."""
    i = 1
    while i < len(words):
        tok = words[i]
        if tok == "-c" or (
            tok.startswith("-")
            and not tok.startswith("--")
            and len(tok) > 1
            and "c" in tok[1:]
        ):
            return words[i + 1] if i + 1 < len(words) else None
        if tok.startswith("-"):
            i += 1
            continue
        break
    return None


def segment_groups(tokens):
    """Yield segments with their preceding and following shell operators, and
    ('push', []) / ('pop', []) at `(`/`)` subshell boundaries -- a `cd`
    inside a subshell must not persist past its closing `)` (B3)."""
    current = []
    previous = None
    for tok in tokens:
        if tok and all(c in ";&|\n" for c in tok):
            if current:
                yield "seg", current, previous, tok
                current = []
            previous = tok
        elif tok == "(":
            if current:
                yield "seg", current, previous, None
                current = []
            yield "push", [], previous, None
            previous = None
        elif tok == ")":
            if current:
                yield "seg", current, previous, None
                current = []
            yield "pop", [], previous, None
            previous = None
        else:
            current.append(tok)
    if current:
        yield "seg", current, previous, None


def rm_operands(words):
    """Positional operands of an `rm`/`rmdir` invocation: everything that
    is not an option flag, honouring `--` as the end-of-options marker --
    a removal deletes the path outright, same as a `mv` source, but was
    the one unguarded shape in an otherwise removal-aware guard (B4)."""
    ops, only_targets = [], False
    for t in words[1:]:
        if only_targets:
            ops.append(t)
        elif t == "--":
            only_targets = True
        elif t.startswith("-") and t != "-":
            continue
        else:
            ops.append(t)
    return ops


class GitDir(str):
    """A git invocation's directory: the command acts on its whole
    repository, so the decision is made on that repository, not this path."""


class Unresolved(str):
    """A git writer's directory word the scanner cannot turn into a path."""


class MergeAbort(str):
    """A `git merge --abort` call's directory word; audit-only, never a target."""


def unexpanded(word, home):
    """True when the shell would still expand `word` ($VAR, backtick, glob)."""
    w = rm_guard.expand_home(word, home)
    return "$" in w or "`" in w or rm_guard.has_glob_chars(w)


def git_write_targets(words, home, unknown_cd=None, env=None):
    """[path] the git invocation writes (--work-tree or GIT_WORK_TREE, else the
    -C chain, else "."), or [] for a verb that does not change a work tree. A
    fenced writer must be plain: every word literal, so any unexpanded word (or
    a relative directory after an unresolvable `cd`) yields [Unresolved(word)].
    The global options are `-C <path>`, `-c <k=v>` (not `alias.*`), the
    `--git-dir`/`--work-tree`/`--namespace` forms and GIT_BARE_OPTIONS; any
    other option before a writer verb is refused, because it may take the next
    word as its value (`--config-env`, `--attr-source`). `env` holds GIT_DIR and
    GIT_WORK_TREE values set by a prefix assignment or an earlier export.
    `merge --abort` yields [MergeAbort(dir)]."""
    chdir, work_tree, bad, i = "", None, None, 1
    while i < len(words):
        word = words[i]
        if word in GIT_VALUE_OPTIONS:
            if i + 1 >= len(words):
                return []
            opt, value, step = word, words[i + 1], 2
            if opt == "-c" and value.lower().startswith("alias."):
                # an alias may expand to a writer; read-only verbs still pass
                if any(WRITER_WORD_RE.search(w) for w in words[1:]):
                    return [Unresolved(value)]
        elif word.startswith("-C") and len(word) > 2:
            opt, value, step = "-C", word[2:], 1
        elif word.startswith("--work-tree="):
            opt, value, step = "--work-tree", word.split("=", 1)[1], 1
        elif word.startswith(("--git-dir=", "--namespace=")) or word in GIT_BARE_OPTIONS:
            opt, value, step = None, word, 1
        elif word.startswith("-"):
            if any(w in GIT_WRITE_SUBCOMMANDS for w in words[i + 1:]):
                return [Unresolved(word)]
            return []
        elif unexpanded(word, home):
            return [Unresolved(word)]  # may hide the verb or an option
        else:
            break
        if bad is None and unexpanded(value, home):
            bad = value
        if opt == "-C":
            chdir = os.path.join(chdir, value)
        elif opt == "--work-tree":
            work_tree = value
        i += step
    if i >= len(words) or words[i] not in GIT_WRITE_SUBCOMMANDS:
        return []
    if words[i] == "stash" and i + 1 < len(words) and words[i + 1] in ("list", "show"):
        return []
    for name in GIT_ENV_TARGETS:
        value = (env or {}).get(name)
        if not value:
            continue
        if bad is None and unexpanded(value, home):
            bad = value
        if name == "GIT_WORK_TREE" and work_tree is None:
            work_tree = value
    if bad is None:
        bad = next((w for w in words[i + 1:] if unexpanded(w, home)), None)
    where = os.path.join(chdir, work_tree) if work_tree is not None else chdir
    if bad is None and unknown_cd is not None and not os.path.isabs(where):
        bad = unknown_cd
    if bad is not None:
        return [Unresolved(bad)]
    if words[i] == "merge" and words[i + 1:] == ["--abort"]:
        return [MergeAbort(where or ".")]
    return [GitDir(where or ".")]


def substitution_end(text, i):
    """Index of the `)` closing the `$(` whose `$` is text[i], or -1."""
    depth, j, q, n = 0, i + 1, None, len(text)
    while j < n:
        ch = text[j]
        if q:
            if ch == "\\" and q == '"':
                j += 1
            elif ch == q:
                q = None
        elif ch in "'\"":
            q = ch
        elif ch == "\\":
            j += 1
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


def backtick_end(text, i):
    """Index of the backtick closing the one at text[i], or -1."""
    j = i + 1
    while j < len(text):
        if text[j] == "\\":
            j += 1
        elif text[j] == "`":
            return j
        j += 1
    return -1


def split_substitutions(text):
    """(text, inners): each `$(...)` or backtick substitution outside single
    quotes (inside double quotes too) becomes the single word `$ORCHSUBST_n_`
    (so its spaces cannot split a git -C/--work-tree value), and inners[n]
    holds the body for a scan at the cwd where the substitution runs.
    Unbalanced ones are left alone."""
    out, inners = [], []
    quote = None
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        end = -1
        if quote == "'":
            if c == "'":
                quote = None
        elif c == "\\" and i + 1 < n:
            out.append(text[i:i + 2])
            i += 2
            continue
        elif c == "$" and text.startswith("$(", i):
            end = substitution_end(text, i)
            body = text[i + 2:end]
        elif c == "`":
            end = backtick_end(text, i)
            body = text[i + 1:end]
        elif c == '"':
            quote = None if quote == '"' else '"'
        elif c == "'" and quote is None:
            quote = "'"
        if end >= 0:
            out.append(f"$ORCHSUBST_{len(inners)}_")
            inners.append(body)
            i = end + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), inners


def leading_words(words):
    """`words` without leading keywords and env assignments."""
    i = 0
    while i < len(words) and (
        rm_guard.is_env_assignment(words[i]) or words[i] in rm_guard.LEADING_KEYWORDS
    ):
        i += 1
    return words[i:]


def hidden_git_writer(words, home):
    """The word to refuse when a command whose head is not `git` may still run
    a git writer (a wrapper, a shell -c string, a variable head, `find -exec`),
    or a wrapper's own directory option (`env -C DIR`) moves a non-git writer,
    else None. Only a writer verb word triggers the git cases, so `gh pr
    create --title "fix git commit"` and wrapped read-only git calls pass."""
    head = words[0]
    name = rm_guard.basename(head)
    if name in ("env", "sudo") and any(
        w in ("-C", "-D", "--chdir") or w.startswith("--chdir=")
        or (w.startswith("-") and not w.startswith("--") and ("C" in w or "D" in w))
        for w in words[1:]
    ) and any(rm_guard.basename(w) in CWD_WRITERS for w in words[1:]):
        return head
    text = " ".join(words)
    if not set(re.findall(r"[\w-]+", text)) & GIT_WRITE_SUBCOMMANDS:
        return None
    if unexpanded(head, home):
        return head
    if any(QUOTED_GIT_RE.search(w) and WRITER_WORD_RE.search(w) for w in words[1:]):
        return head
    if name in ARGUMENT_RUNNERS and any(
        GIT_TOKEN_RE.search(w) and WRITER_WORD_RE.search(w) for w in words[1:]
    ):
        return head
    if name == "find" and any(w in FIND_EXEC_OPTIONS for w in words[1:]):
        if "git" in text.lower() or "$" in text:
            return head
    if name in WRAPPER_HEADS:
        mentions_git = "git" in text.lower()
    else:
        mentions_git = any(rm_guard.basename(w) == "git" for w in words[1:])
    return head if mentions_git else None


def cd_operand(words):
    """The directory operand of a `cd`/`pushd`, or None; skips option flags."""
    seen_dashdash = False
    for t in words[1:]:
        if not seen_dashdash and t == "--":
            seen_dashdash = True
            continue
        if not seen_dashdash and t.startswith("-") and t != "-" and len(t) > 1:
            continue
        return t
    return None


def cd_target_candidates(words, cwd, home):
    """The set of cwds the shell might be in after a `cd`: one, when the
    target can be confirmed a real directory; {target, cwd} otherwise --
    a `cd` to a nonexistent directory leaves the shell in `cwd`, and the
    guard cannot know at scan time which it will be, so both are scanned
    and a write is guarded if EITHER lands on a tracked path (B3). Option
    flags (`-L`/`-P`/...) and a `--` marker are skipped to find the real
    operand; bare `cd` and `cd -` are a no-op (HOME/OLDPWD are not
    tracked), matching the existing accepted-hole simplification.

    Accepted gap (cycle-3 A-3): the same {target, cwd} conservatism means
    `mkdir -p /tmp/x && cd /tmp/x && echo hi > out.txt` can be denied even
    though /tmp/x exists by the time the shell actually runs `cd` -- a
    false-positive deny, never a missed guard."""
    operand = cd_operand(words)
    if operand is None or operand == "-":
        return {cwd}
    if unexpanded(operand, home):
        return {cwd}  # unexpanded target: accepted hole, same as other operands
    # A logical `cd` keeps the lexical path; `cd -P` resolves symlinks
    # physically. The scanner does not know which spelling the shell will use,
    # so it keeps BOTH the lexical and the realpath candidate -- otherwise a
    # `cd -P link/..` through a symlink would leave the guard scanning the
    # wrong (lexical) directory and miss the real target (A1). Widening the
    # candidate set only over-guards; it never misses.
    # Always keep the incoming `cwd` as a candidate alongside the lexical and
    # physical (realpath) destinations. A `cd` can fail for reasons neither
    # spelling reveals -- a non-directory intermediate component
    # (`cd -P /dev/null/..`, both spellings collapse to `/dev` yet the shell
    # cannot traverse the file `/dev/null`), or a pipeline-ending `cd` that
    # runs in a subshell and never moves the parent shell -- and then the
    # shell stays in `cwd`. Dropping `cwd` under any "cd surely succeeded"
    # heuristic under-guards; retaining it only over-guards, which is safe.
    lexical = rm_guard.resolve(rm_guard.expand_home(operand, home), cwd)
    real = canonical_target(operand, cwd, home)
    cands = {lexical, cwd}
    if real is not None:
        cands.add(real)
    return cands


def git_env_words(words):
    """{GIT_DIR|GIT_WORK_TREE: value} among the words that are assignments."""
    found = {}
    for w in words:
        name, sep, value = w.partition("=")
        if sep and name in GIT_ENV_TARGETS:
            found[name] = value
    return found


def leading_assignments(words):
    """The words before the command word: env assignments and keywords."""
    i = 0
    while i < len(words) and (
        rm_guard.is_env_assignment(words[i]) or words[i] in rm_guard.LEADING_KEYWORDS
    ):
        i += 1
    return words[:i]


def bash_targets(command, cwd, home, depth=0, unknown_cd=None, outer_redirs=None,
                 git_env=None):
    """[(cwd, word)] write targets of one command string. `cwd` is tracked
    as a SET of candidates rather than one string, so an uncertain `cd`
    (a subshell, a failed cd, cd options) fails toward guarding rather
    than away from it (B3). `pushd` is a `cd` that also remembers the old
    cwd; `popd` returns to it, but this scanner doesn't model the actual
    dir stack, so a `popd` is treated as a cwd change of unknown
    direction -- widened to every cwd candidate seen so far in this
    command, never narrowed (B-2)."""
    if depth > 1:
        return []
    git_env = dict(git_env or {})
    cleaned, redirs = scan_raw(command)
    if outer_redirs:
        redirs = {**outer_redirs, **redirs}
    cleaned, inners = split_substitutions(cleaned)
    found = []
    visited = set()
    cwds = {cwd}
    seen_cwds = {cwd}
    stack = []
    for kind, tokens, previous, following in segment_groups(rm_guard.tokenize(cleaned)):
        if kind == "push":
            stack.append((cwds, unknown_cd))
            continue
        if kind == "pop":
            if stack:
                cwds, unknown_cd = stack.pop()
            continue
        # A substitution runs at its position in the command: scan its body
        # with the cwds and unknown-cd state the shell has reached here.
        for t in tokens:
            for m in SUBST_RE.finditer(t):
                idx = int(m.group(1))
                if idx < len(inners):
                    visited.add(idx)
                    for c in cwds:
                        found.extend(
                            bash_targets(inners[idx], c, home, depth, unknown_cd, redirs, git_env)
                        )
        words = []
        for t in tokens:
            if SENTINEL_RE.match(t):
                # Look the sentinel up by its exact string. A lookalike token
                # in the command text (e.g. thousands of digits) used to be
                # int()-converted, which raised ValueError past every caller
                # and failed the guard open (co-review r7). An unknown
                # sentinel-shaped token is simply not a redirect.
                w = redirs.get(t)
                if w:
                    found.extend((c, w) for c in cwds)
            else:
                words.append(t)
        prefix_env = git_env_words(leading_assignments(words))
        words = leading_words(words)
        if not words:
            git_env.update(prefix_env)  # a bare `GIT_DIR=x` assignment persists
            continue
        if rm_guard.basename(words[0]) in ENV_DECLARERS:
            git_env.update(git_env_words(words[1:]))
        hidden = hidden_git_writer(words, home) if rm_guard.basename(words[0]) != "git" else None
        if hidden is not None:
            found.extend((c, Unresolved(hidden)) for c in cwds)
            continue
        words = rm_guard.strip_prefixes(words)
        if not words:
            continue
        head = rm_guard.basename(words[0])
        if head in ("cd", "pushd"):
            new_cwds = set()
            for c in cwds:
                new_cwds |= cd_target_candidates(words, c, home)
            if previous in ("&&", "||"):
                new_cwds |= cwds
            if following != "|":
                cwds = new_cwds
                operand = cd_operand(words)
                if operand is not None and unexpanded(operand, home):
                    unknown_cd = operand
            seen_cwds |= cwds
        elif head == "popd":
            cwds |= seen_cwds
        elif head in ("sed", "gsed"):
            ops = script_operands(words, ("-e", "-f", "--expression", "--file"), "ef")
            for c in cwds:
                found.extend((c, w) for w in _existing(ops, c, home))
        elif head == "perl":
            ops = script_operands(words, ("-e", "-E"), "eE")
            for c in cwds:
                found.extend((c, w) for w in _existing(ops, c, home))
        elif head == "tee":
            for c in cwds:
                found.extend((c, w) for w in tee_operands(words))
        elif head in ("cp", "install", "mv"):
            for c in cwds:
                found.extend((c, w) for w in copy_targets(words, c, home, head == "mv"))
        elif head in ("rm", "rmdir"):
            for c in cwds:
                found.extend((c, w) for w in rm_operands(words))
        elif head == "git":
            for c in cwds:
                found.extend(
                    (c, w)
                    for w in git_write_targets(
                        words, home, unknown_cd, {**git_env, **prefix_env}
                    )
                )
        elif head in SHELL_WRAPPERS:
            inner = shell_c_arg(words)
            if inner is not None:
                for c in cwds:
                    found.extend(bash_targets(inner, c, home, depth + 1, unknown_cd, None, git_env))
    # A substitution in a word the walk never saw (a redirect target) runs
    # somewhere in the command: scan it at every cwd reached.
    for idx, inner in enumerate(inners):
        if idx not in visited:
            for c in seen_cwds:
                found.extend(
                    bash_targets(inner, c, home, depth, unknown_cd, redirs, git_env)
                )
    return found


# --- targets ---------------------------------------------------------------


def unscannable_shape(command):
    """Name of a heredoc, here-string or function definition in a command that mentions a
    git writer: the scan cannot see where its body runs, so it is refused."""
    if not WRITER_WORD_RE.search(command) or "git" not in command.lower():
        return None
    if HEREDOC_RE.search(command):
        return "heredoc"
    if "<<<" in command:
        return "here-string"
    if FUNCTION_RE.search(command):
        return "function definition"
    return None


def targets_for(payload, tool, cwd, home):
    """[(cwd, word, shell_expands)] raw write targets of one tool call."""
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        return []
    if tool == "Bash":
        cmd = ti.get("command")
        if not isinstance(cmd, str) or not cmd.strip():
            return []
        shape = unscannable_shape(cmd)
        if shape is not None:
            return [(cwd, Unresolved(shape), True)]
        return [
            (target_cwd, word, True)
            for target_cwd, word in bash_targets(cmd, cwd, home)
        ]
    paths = ti.get("file_paths")
    if isinstance(paths, list):
        return [
            (cwd, path, False)
            for path in paths
            if isinstance(path, str) and path.strip()
        ]
    fp = ti.get("file_path")
    return [(cwd, fp, False)] if isinstance(fp, str) and fp.strip() else []


def resolve_targets(raw, home):
    """Marker budget unit: one per distinct canonical target per call, so
    `git commit && git reset` in one repo costs one unit. Canonical absolute paths, skipping anything the shell would still
    expand ($VAR, backticks, globs), deduplicated by canonical path, NOT
    capped.

    Every operand is resolved: dedup by canonical path collapses alias
    spellings of one destination (`/dev/null`, `/dev/./null`, ...) to a single
    entry, so aliases cannot consume a budget. The caller treats more than
    TARGET_CAP distinct canonical targets as an overflow it cannot scan within
    the git budget and fails CLOSED for a privileged session -- silently
    dropping the extras (whether from alias inflation or from one relative
    operand expanding across many retained cwd candidates) would un-guard a
    tracked write hidden past the cap."""
    paths = []
    for c_cwd, w, shell_expands in raw:
        if isinstance(w, (Unresolved, MergeAbort)):
            continue
        we = rm_guard.expand_home(w, home)
        if not we or (shell_expands and unexpanded(w, home)):
            continue
        p = canonical_target(we, c_cwd, home)
        if p is not None and isinstance(w, GitDir):
            p = GitDir(p)
        if p is not None and p not in paths:
            paths.append(p)
    return paths


# --- audit -----------------------------------------------------------------


def audit_append(rd, rec):
    """Append one JSON line to the selected payload's tasks/orch-edits.jsonl.
    True on success; False when tasks/ is missing or the file is not a
    plain regular file (symlink, FIFO) or cannot be opened. Never raises.

    Accepted gap (A5): near-identical to herdr_orch_core.append_orch_edit
    (same O_APPEND|O_NOFOLLOW + short-write check); the two must stay
    byte-compatible for the shared budget log but are not shared code."""
    p = Path(rd) / "tasks" / AUDIT_FILE
    try:
        with core.coordination.payload_parent(p) as (parent, name):
            try:
                st = os.stat(name, dir_fd=parent, follow_symlinks=False)
            except FileNotFoundError:
                st = None
            if st is not None and not stat.S_ISREG(st.st_mode):
                return False
            flags = (
                os.O_WRONLY
                | os.O_CREAT
                | os.O_APPEND
                | os.O_NONBLOCK
                | getattr(os, "O_NOFOLLOW", 0)
            )
            data = (json.dumps(rec, separators=(",", ":")) + "\n").encode()
            fd = os.open(name, flags, 0o600, dir_fd=parent)
            try:
                written = os.write(fd, data)
            finally:
                os.close(fd)
    except (OSError, ValueError):
        return False
    return written == len(data)  # a short write is not a record


# --- marker and budget -----------------------------------------------------


def read_marker(rd, session_id, fence):
    """(marker, None) when the slug's marker is valid for this session and
    fence and unexpired; else (None, why) with why in no-marker, fence,
    expired. A malformed file is no marker, never an exception."""
    m = read_state_json(Path(rd) / MARKER_FILE)
    if not m or m.get("v") != 1 or m.get("session_id") != session_id:
        return None, "no-marker"
    mid = m.get("marker_id")
    if not isinstance(mid, str) or not MARKER_ID_RE.match(mid):
        return None, "no-marker"
    me = m.get("max_edits")
    if (
        isinstance(me, bool)
        or not isinstance(me, int)
        or not (MAX_EDITS_RANGE[0] <= me <= MAX_EDITS_RANGE[1])
    ):
        return None, "no-marker"
    mf = m.get("fence")
    if isinstance(mf, bool) or not isinstance(mf, int) or mf != fence:
        return None, "fence"
    exp = m.get("expires_epoch")
    if isinstance(exp, bool) or not isinstance(exp, (int, float)):
        return None, "expired"
    try:
        exp = float(exp)  # a JSON integer too large for float raises here
    except (OverflowError, ValueError):
        return None, "expired"
    if not math.isfinite(exp) or exp <= time.time():
        return None, "expired"
    return m, None


def claim_budget(rd, marker, session_id, tool_use_id, paths):
    """Reserve budget claim-then-count: append one claim line per path,
    re-read the log, and return the 1-based ordinal of this invocation's
    last claim among all claims carrying this marker_id. None when an
    append fails or none of our claims is found on re-read -- the caller
    denies. Claims consume budget whether or not the allow follows, which
    is what keeps parallel tool calls from overshooting max_edits.

    Accepted gap (A3): the log is never rotated, so every claim re-reads
    the slug's entire orch-edits.jsonl history; fine at today's budgets
    (1-10) and short-lived markers, worth rotating if that changes."""
    claim_id = secrets.token_hex(4)
    for p in paths:
        rec = {
            "v": 1,
            "ts": core.now_iso(),
            "event": "orch-edit-claim",
            "marker_id": marker["marker_id"],
            "claim_id": claim_id,
            "session_id": session_id,
            "tool_use_id": tool_use_id,
            "path": p[:PATH_MAX],
        }
        if not audit_append(rd, rec):
            return None
    try:
        lines = core.read_payload_text(Path(rd) / "tasks" / AUDIT_FILE).splitlines()
    except (OSError, ValueError):
        return None
    ordinal, own, seen = 0, None, 0
    for line in lines:
        try:
            rec = json.loads(line)
        except Exception:  # noqa: BLE001, S112 -- an unparseable line is skipped, never a crash (co-review r7)
            # A torn concurrent line is skipped by contract; a corrupt or
            # deeply nested line (RecursionError on older decoders) is
            # likewise skipped -- it cannot be a valid claim, and letting it
            # raise bypassed the whole marker limit via the fail-open handler.
            continue
        if (
            not isinstance(rec, dict)
            or rec.get("event") != "orch-edit-claim"
            or rec.get("marker_id") != marker["marker_id"]
        ):
            continue
        ordinal += 1
        if rec.get("claim_id") == claim_id:
            own = ordinal
            seen += 1
    # Every claim of this invocation must have survived as a parseable
    # line; a lost or mangled one (a concurrent partial line spliced into
    # ours) means the reservation is not complete, so deny.
    return own if seen == len(paths) else None


def marker_verdict(guarded, owned, session_id, tool_use_id, budget, runtime):
    """('allow', slug, marker) or ('deny', why, slug, detail). Every
    guarded target must resolve to one slug this session owns; that
    slug's marker must validate; then the budget claim must land within
    max_edits."""
    cache = {}
    slugs = {}
    for c, top, _reason in guarded:
        slugs.setdefault(repo_slug_of(top, budget, cache), []).append(c)
    first = min(owned)
    if len(slugs) != 1 or None in slugs or next(iter(slugs)) not in owned:
        # When every slug in `slugs` IS owned (a single command writing
        # tracked files in two repos this session owns), the generator
        # below finds none and target_slug prints as "unknown" -- a safe
        # deny either way, but the refusal wording is misleading for this
        # one-command-two-repos shape (A4). Same misleading-wording family,
        # different trigger (cycle-3 A-4): if the git budget drains mid
        # classify(), a later repo_slug_of returns None, "unknown" prints,
        # and this denies scope for a target the session actually owns a
        # valid marker for -- fails safe (denies); a retry with a fresh
        # budget succeeds.
        target = next((s for s in slugs if s not in owned), None) or "unknown"
        return "deny", "scope", first, {"target_slug": target}
    slug = next(iter(slugs))
    owner = owned[slug]
    if "context" not in owner:
        return "deny", "scope", first, {"target_slug": slug}
    if owner["scope"]["account_id"] != owner["caller_scope"]["account_id"]:
        return "deny", "scope", first, {"target_slug": slug}
    rd = owner["rd"]
    try:
        with core.owner_transaction(
            rd,
            session_id,
            owner["fence"],
            context=owner["context"],
            expected_slug=slug,
            scope=owner["scope"],
        ) as tx:
            marker, why = read_marker(rd, session_id, tx.current["fence"])
            if marker is None:
                return "deny", why, slug, {}
            ordinal = claim_budget(
                rd,
                marker,
                session_id,
                tool_use_id,
                [c for c, _top, _reason in guarded],
            )
            if ordinal is None:
                return "deny", "budget", slug, {"unwritable": True, "marker": marker}
            if ordinal > marker["max_edits"]:
                return "deny", "budget", slug, {"ordinal": ordinal, "marker": marker}
            return "allow", slug, marker
    except Exception:  # noqa: BLE001 -- any transaction/reader failure denies (fail closed, co-review r7)
        return "deny", "fence", slug, {}


# --- refusal ---------------------------------------------------------------


def _printable(s):
    """Collapse newlines/carriage returns in an interpolated path so a legal
    filename with an embedded newline cannot add extra stderr lines and break
    the exactly-three-line refusal contract. A no-op for ordinary paths."""
    return s.replace("\n", "\\n").replace("\r", "\\r")


def refuse(why, slug, fence, session_id, first, detail, runtime, rd):
    """Print the three-line refusal for `why` and return 2."""
    c, top, reason = first
    c, top = _printable(c), _printable(top)
    print(
        f"{BLOCKED} -- this session is the herdr orchestrator for {slug} "
        f"and {c} is a {reason} path in {top}.",
        file=sys.stderr,
    )
    allow_line = (
        f"Small edit the human approved THIS turn? Run: {CORE_CMD} "
        f"allow-edit --repo-slug {slug} --session {session_id} "
        f"--fence {fence} --repo-path {shlex.quote(top)} "
        f"--runtime {runtime} --minutes 5 --note '<what was approved>' "
        f"and retry."
    )
    if why == "scope":
        print(
            f"This session does not orchestrate {detail.get('target_slug')} "
            f"(owned: {detail.get('owned')}); no marker can allow an edit there.",
            file=sys.stderr,
        )
        print(
            "Dispatch it: file a todo in that repo and kick off a worker, "
            "or ask the human.",
            file=sys.stderr,
        )
    elif why == "budget":
        if detail.get("unwritable"):
            audit_path = _printable(str(Path(rd) / "tasks" / AUDIT_FILE))
            print(
                f"Cannot reserve budget: {audit_path} is not writable.",
                file=sys.stderr,
            )
        else:
            m = detail["marker"]
            print(
                f"The allow-edit marker {m['marker_id']} for {slug} is exhausted "
                f"({detail['ordinal']} of {m['max_edits']} claims).",
                file=sys.stderr,
            )
        print(allow_line, file=sys.stderr)
    else:
        print(
            "Orchestrators dispatch, they do not edit: file a todo and kick "
            "off a worker (herdr-orchestration SKILL.md, Safety).",
            file=sys.stderr,
        )
        print(allow_line, file=sys.stderr)
    sys.stderr.flush()
    return 2


def refuse_overflow(count):
    """Three-line refusal when a privileged session's command names more
    distinct canonical targets than the guard can scan (TARGET_CAP)."""
    print(
        f"{BLOCKED} -- this command names {count} distinct write targets, "
        f"more than the {TARGET_CAP} the guard can scan.",
        file=sys.stderr,
    )
    print(
        "An orchestrator or lead session is fenced, and an unscanned target "
        "could be a tracked file, so the whole command is refused.",
        file=sys.stderr,
    )
    print(
        "Split the command into smaller writes, or dispatch it to a worker.",
        file=sys.stderr,
    )
    sys.stderr.flush()
    return 2


def refuse_unresolved(word):
    """Three-line refusal for a fenced session's git write whose target
    directory the guard cannot resolve."""
    print(
        f"{BLOCKED} -- this session is fenced and a git write targets a "
        f"directory the guard cannot resolve: {_printable(word)[:PATH_MAX]}.",
        file=sys.stderr,
    )
    print(
        "A variable, substitution, glob, wrapper, heredoc or function hides "
        "which repository it changes, and no allow-edit marker can scope it.",
        file=sys.stderr,
    )
    print(
        "Write the git call as a plain `git -C <literal path> <verb>` with "
        "literal words, no wrapper, heredoc or function, or dispatch it.",
        file=sys.stderr,
    )
    sys.stderr.flush()
    return 2


def under_workspace(path, roots):
    return any(path == r or path.startswith(r + "/") for r in roots)


def refuse_lead(first, roots):
    """Print the three-line refusal for a lead editing outside its workspace."""
    c, _top, reason = first
    c = _printable(c)
    print(
        f"{BLOCKED} -- this session is a herdr lead fenced to its workspace "
        f"and {c} is a {reason} path outside it.",
        file=sys.stderr,
    )
    if roots:
        print(
            "A lead may only edit under its workspace: "
            + ", ".join(_printable(r) for r in roots)
            + ".",
            file=sys.stderr,
        )
    else:
        print(
            "No workspace edit is authorized for this lead: either its "
            "dispatch binding is missing, revoked, or complete, or "
            "task-lead dispatch is not active for this repository.",
            file=sys.stderr,
        )
    print(
        "Edit inside the lead's own worktree, or hand the change back to the "
        "launcher (herdr-orchestration SKILL.md, Safety).",
        file=sys.stderr,
    )
    sys.stderr.flush()
    return 2


# --- decision --------------------------------------------------------------


def decide(payload, runtime="claude"):
    """Exit status for one PreToolUse payload: 0 allow, 2 refuse."""
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "PreToolUse":
        return 0
    tool = payload.get("tool_name")
    if tool not in TOOLS or os.environ.get("HERDR_ENV") != "1":
        return 0
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not SESSION_ID_RE.match(sid):
        return 0
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    caller_cwd = (
        payload.get("caller_cwd") if isinstance(payload.get("caller_cwd"), str) else cwd
    )
    try:
        caller_scope = selected_scope(caller_cwd, runtime)
    except (OSError, ValueError, subprocess.SubprocessError):
        # Scope derivation reads git metadata and can raise on a legal
        # non-UTF-8 branch name. That is not "no privileged identity": the
        # session's coordination records are still readable, so identify it
        # without the scope and fail closed if it is fenced (co-review r9).
        return refuse_crash() if privileged_anywhere(sid, runtime) else 0
    home = os.environ.get("HOME", os.path.expanduser("~"))
    raw = targets_for(payload, tool, cwd, home)
    unresolved = [w for _c, w, _s in raw if isinstance(w, Unresolved)]
    aborts = [w for _c, w, _s in raw if isinstance(w, MergeAbort)]
    if unresolved or aborts:
        owned = owned_slugs(sid, runtime, caller_scope, {})
        if unresolved and (owned or lead_authority(sid, runtime, caller_scope)[0]):
            rc = refuse_unresolved(unresolved[0])
            for slug in sorted(owned):
                audit_append(
                    owned[slug]["rd"],
                    {
                        "v": 1,
                        "ts": core.now_iso(),
                        "event": "orch-edit-denied",
                        "session_id": sid,
                        "tool_name": tool,
                        "tool_use_id": payload.get("tool_use_id"),
                        "path": _printable(unresolved[0])[:PATH_MAX],
                        "repo": "",
                        "reason": "unresolved",
                        "why": "unresolved",
                    },
                )
            return rc
        for slug in sorted(owned):
            for w in aborts:
                audit_append(
                    owned[slug]["rd"],
                    {
                        "v": 1,
                        "ts": core.now_iso(),
                        "event": "orch-edit-allowed",
                        "session_id": sid,
                        "tool_name": tool,
                        "tool_use_id": payload.get("tool_use_id"),
                        "path": _printable(w)[:PATH_MAX],
                        "cwd": _printable(cwd)[:PATH_MAX],
                        "repo": "",
                        "reason": "merge-abort",
                    },
                )
    paths = resolve_targets(raw, home)
    if not paths:
        return 0
    if len(paths) > TARGET_CAP:
        # Too many distinct canonical targets to scan every one within the git
        # budget. Dropping the extras would un-guard a tracked write hidden
        # past the cap (alias- or cd-inflated commands), so a privileged
        # session (launcher or lead) fails CLOSED; a plain worker is allowed.
        owned = owned_slugs(sid, runtime, caller_scope, {})
        is_lead, _roots = lead_authority(sid, runtime, caller_scope)
        if owned or is_lead:
            return refuse_overflow(len(paths))
        return 0
    state_real = os.path.realpath(
        core.account_payload_root(caller_scope) / "herdr-orch"
    )
    budget = Budget(GIT_BUDGET_SECS)
    guarded = []
    for p in paths:
        if isinstance(p, GitDir):
            # A git write changes the whole repository: judge its root, so a
            # .todos or gitignored cwd is not an exemption.
            p = git_toplevel(p, budget)
        if exempt(p, state_real):
            continue
        hit = classify(p, budget)
        if hit and all(g[0] != p for g in guarded):
            guarded.append((p, hit[0], hit[1]))
    if not guarded:
        return 0
    slug_cache = {}
    candidates = {}
    for _path, top, _reason in guarded:
        slug = repo_slug_of(top, budget, slug_cache)
        if slug is not None:
            candidates.setdefault(slug, top)
    owned = owned_slugs(sid, runtime, caller_scope, candidates)
    if owned:
        tool_use_id = payload.get("tool_use_id")
        verdict = marker_verdict(guarded, owned, sid, tool_use_id, budget, runtime)
        if verdict[0] == "allow":
            _, slug, marker = verdict
            rd = owned[slug]["rd"]
            for c, top, reason in guarded:
                audit_append(
                    rd,
                    {
                        "v": 1,
                        "ts": core.now_iso(),
                        "event": "orch-edit-allowed",
                        "session_id": sid,
                        "tool_name": tool,
                        "tool_use_id": tool_use_id,
                        "path": c[:PATH_MAX],
                        "repo": top[:PATH_MAX],
                        "reason": reason,
                        "marker_id": marker["marker_id"],
                        "marker_expires": marker.get("expires"),
                    },
                )
            return 0
        _, why, slug, detail = verdict
        detail = dict(detail, owned=",".join(sorted(owned)))
        rd = owned[slug]["rd"]
        rc = refuse(
            why, slug, owned[slug]["fence"], sid, guarded[0], detail, runtime, rd
        )
        c, top, reason = guarded[0]
        audit_append(
            rd,
            {
                "v": 1,
                "ts": core.now_iso(),
                "event": "orch-edit-denied",
                "session_id": sid,
                "tool_name": tool,
                "tool_use_id": tool_use_id,
                "path": c[:PATH_MAX],
                "repo": top[:PATH_MAX],
                "reason": reason,
                "why": why,
            },
        )
        return rc
    # A session that owns no launcher lease may still be a lead, fenced to its
    # workspace_root. A lead never consults the marker path, so a marker minted
    # for the slug can never widen its scope. A non-lead is a plain worker.
    is_lead, roots = lead_authority(sid, runtime, caller_scope)
    if not is_lead:
        return 0
    if roots and all(under_workspace(c, roots) for c, _top, _reason in guarded):
        return 0
    return refuse_lead(guarded[0], roots)


def refuse_crash():
    """Three-line refusal when the guard itself failed while checking a
    fenced session's write. Failing closed here is what turns "make X raise"
    from a bypass into, at worst, a false deny."""
    # The verdict is 2 regardless of whether the diagnostics can be written:
    # a failing stderr must never turn a decided deny into an allow.
    try:
        print(
            f"{BLOCKED} -- the guard hit an internal error while checking a "
            "fenced (orchestrator or lead) session's write.",
            file=sys.stderr,
        )
        print(
            "A fenced session fails closed on any guard error: an unverified "
            "target could be a tracked file.",
            file=sys.stderr,
        )
        print(
            "Retry once; if it persists, dispatch the edit to a worker and "
            "report the guard error.",
            file=sys.stderr,
        )
        sys.stderr.flush()
    except Exception:  # noqa: BLE001, S110 -- diagnostics are best effort; the deny stands
        pass
    return 2


def crash_verdict(payload, runtime="claude"):
    """Exit status after decide() raised: 2 if the payload's session can be
    identified as a launcher or lead (fail closed), else 0.

    Spec R9 -- fail closed on ambiguity -- applied at the ONE chokepoint every
    reader and parser sits behind, so it holds regardless of which of them
    raised. Only a session with no privileged identity at all keeps the
    documented fail-open default; if identification itself is impossible,
    there is nothing to fence and 0 is returned. Total by construction."""
    try:
        if os.environ.get("HERDR_ENV") != "1":
            return 0
        sid = payload.get("session_id") if isinstance(payload, dict) else None
        if not isinstance(sid, str) or not SESSION_ID_RE.match(sid):
            return 0
        # Scope-INDEPENDENT identification (co-review r9): deriving the
        # account scope itself reads repository metadata (`git branch
        # --show-current`, strict UTF-8) and can raise -- e.g. a non-UTF-8
        # branch name -- which must not read as "not privileged" for a session
        # whose coordination records are perfectly readable. Decide the
        # verdict first; the refusal's diagnostics are total on their own.
        return refuse_crash() if privileged_anywhere(sid, runtime) else 0
    except Exception:  # noqa: BLE001 -- unidentifiable session: nothing to fence
        return 0


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    try:
        return decide(payload)
    except Exception:  # noqa: BLE001 -- route the crash through the fail-closed chokepoint
        return crash_verdict(payload)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
