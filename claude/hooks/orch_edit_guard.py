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
destinations, `mv` sources and destinations, and one level of `sh -c`.

Escape hatch: `herdr_orch_core.py allow-edit` mints
STATE_ROOT/<slug>/orch-edit-allow.json under a live fence. The hook honours
it only for the session and fence it names, only for targets in that
slug's repo, only until it expires, and only for its write budget --
reserved claim-then-count in tasks/orch-edits.jsonl so parallel tool calls
cannot overshoot. Every guarded attempt (allowed or refused) is appended to
that log, best effort, after the decision.

Accepted holes (allow): scripts and functions, `python -c`, `git apply`/
`checkout`/`stash`/`restore`, `patch`, `truncate`, `touch`, `mkdir`, `ln`,
`rsync`, `dd`, editors, `xargs`, process substitution, targets built from
`$VAR`/`$(...)`/globs, a heredoc with no terminator, more than 20 distinct
targets, git calls past the 10-second budget, NotebookEdit/MultiEdit. This
is a guard against drift, not evasion.

Deny is exit 2 with three stderr lines; allow is exit 0 and silent. Fails
open on any unexpected exception (exit 0), matching the other guards.
Malformed state files have defined outcomes: a bad owner.json is skipped,
a bad marker is no marker.
"""

import json
import math
import os
import re
import secrets
import stat
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ under the hooks dir
sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_orch_core as core  # noqa: E402  read-only helpers
import rm_guard  # noqa: E402  tokenizer and path helpers, unchanged

TOOLS = ("Edit", "Write", "Bash")
SESSION_ID_RE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
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
    try:
        p = subprocess.run(["git", "-C", cwd, *args], capture_output=True,
                           text=True, timeout=left, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return p.returncode, p.stdout


# --- state root reads ------------------------------------------------------

def read_state_json(path):
    """Parsed JSON object at `path`, or None when it is a symlink, not a
    regular file, outside STATE_ROOT, unreadable, or not an object."""
    p = Path(path)
    try:
        if p.is_symlink() or not p.is_file() \
                or not core.contained(p, core.state_root()):
            return None
        with open(p) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def owned_slugs(session_id):
    """{slug: fence} over every owner record naming this session. A file
    that is not an owner record (corrupt, symlink, no int fence) is
    skipped: it never un-guards a valid sibling."""
    owned = {}
    try:
        files = sorted(core.state_root().glob("*/owner.json"))
    except OSError:
        return owned
    for p in files:
        rec = read_state_json(p)
        if not rec or rec.get("session_id") != session_id:
            continue
        fence = rec.get("fence")
        if isinstance(fence, bool) or not isinstance(fence, int):
            continue
        owned[p.parent.name] = fence
    return owned


# --- paths and classification ---------------------------------------------

def canon(path):
    """realpath of the longest existing ancestor, joined with the rest."""
    existing, rest = path, []
    while existing != "/" and not os.path.lexists(existing):
        existing, tail = os.path.split(existing)
        rest.append(tail)
    real = os.path.realpath(existing)
    return os.path.join(real, *reversed(rest)) if rest else real


def exempt(c, state_real):
    if ".todos" in c.split("/"):
        return True
    return c == state_real or c.startswith(state_real + "/")


def classify(c, budget):
    """(toplevel, 'tracked'|'untracked') when `c` is guarded, else None:
    outside every work tree, inside .git/, gitignored, or git failed."""
    d = c if os.path.isdir(c) else os.path.dirname(c)
    while d != "/" and not os.path.isdir(d):
        d = os.path.dirname(d)
    rc, out = git(["rev-parse", "--show-toplevel", "--is-inside-git-dir"], d, budget)
    if rc != 0:
        return None
    lines = out.splitlines()
    if len(lines) < 2 or lines[1].strip() != "false":
        return None
    top = os.path.realpath(lines[0].strip())
    if c != top and not c.startswith(top + "/"):
        return None
    # The work tree root itself (`mv /repo /tmp/x`) is guarded when it has
    # any tracked content: ls-files on "." exits 0 in that case.
    rel = os.path.relpath(c, top)
    rc, _ = git(["ls-files", "--error-unmatch", "--", rel], top, budget)
    if rc == 0:
        return top, "tracked"
    if rc is None:
        return None
    rc, _ = git(["check-ignore", "-q", "--", rel], top, budget)
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
            slug = core.repo_slug(url.strip() if rc == 0 else "", cd)
        cache[top] = slug
    return cache[top]


# --- targets ---------------------------------------------------------------

def targets_for(payload, tool, cwd, home):
    """[(cwd, word)] raw write targets of one tool call."""
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        return []
    if tool == "Bash":
        return []  # Task 3 wires bash_targets here
    fp = ti.get("file_path")
    return [(cwd, fp)] if isinstance(fp, str) and fp.strip() else []


def resolve_targets(raw, home):
    """Canonical absolute paths, skipping anything the shell would still
    expand ($VAR, backticks, globs), deduplicated, capped."""
    paths = []
    for c_cwd, w in raw:
        w = rm_guard.expand_home(w, home)
        if not w or "$" in w or "`" in w or rm_guard.has_glob_chars(w):
            continue
        p = canon(rm_guard.resolve(w, c_cwd))
        if p not in paths:
            paths.append(p)
    return paths[:TARGET_CAP]


# --- audit -----------------------------------------------------------------

def audit_append(slug, rec):
    """Append one JSON line to STATE_ROOT/<slug>/tasks/orch-edits.jsonl.
    True on success; False when tasks/ is missing or the file is not a
    plain regular file (symlink, FIFO) or cannot be opened. Never raises."""
    p = core.repo_dir(slug) / "tasks" / AUDIT_FILE
    try:
        if not p.parent.is_dir() or not core.contained(p.parent, core.state_root()):
            return False
        try:
            st = os.lstat(p)
        except FileNotFoundError:
            st = None
        if st is not None and not stat.S_ISREG(st.st_mode):
            return False
        flags = (os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NONBLOCK
                 | getattr(os, "O_NOFOLLOW", 0))
        data = (json.dumps(rec, separators=(",", ":")) + "\n").encode()
        fd = os.open(p, flags, 0o600)
        try:
            written = os.write(fd, data)
        finally:
            os.close(fd)
    except OSError:
        return False
    return written == len(data)  # a short write is not a record


# --- marker (Task 4 adds read_marker and claim_budget here) ---------------

def marker_verdict(guarded, owned, session_id, tool_use_id, budget):
    """('allow', slug, marker) or ('deny', why, slug, detail).
    Task 2: no marker support yet -- always deny against the target's slug
    when owned, else the sorted-first owned slug."""
    cache = {}
    slugs = {}
    for c, top, _reason in guarded:
        slugs.setdefault(repo_slug_of(top, budget, cache), []).append(c)
    first = sorted(owned)[0]
    if len(slugs) != 1 or None in slugs or next(iter(slugs)) not in owned:
        target = next((s for s in slugs if s not in owned), None) or "unknown"
        return "deny", "scope", first, {"target_slug": target}
    return "deny", "no-marker", next(iter(slugs)), {}


# --- refusal ---------------------------------------------------------------

def refuse(why, slug, fence, session_id, first, detail):
    """Print the three-line refusal for `why` and return 2."""
    c, top, reason = first
    print(f"{BLOCKED} -- this session is the herdr orchestrator for {slug} "
          f"and {c} is a {reason} path in {top}.", file=sys.stderr)
    allow_line = (f"Small edit the human approved THIS turn? Run: {CORE_CMD} "
                  f"allow-edit --repo-slug {slug} --session {session_id} "
                  f"--fence {fence} --minutes 5 --note '<what was approved>' "
                  f"and retry.")
    if why == "scope":
        print(f"This session does not orchestrate {detail.get('target_slug')} "
              f"(owned: {detail.get('owned')}); no marker can allow an edit there.",
              file=sys.stderr)
        print("Dispatch it: file a todo in that repo and kick off a worker, "
              "or ask the human.", file=sys.stderr)
    elif why == "budget":
        if detail.get("unwritable"):
            print(f"Cannot reserve budget: {core.repo_dir(slug) / 'tasks' / AUDIT_FILE} "
                  "is not writable.", file=sys.stderr)
        else:
            m = detail["marker"]
            print(f"The allow-edit marker {m['marker_id']} for {slug} is exhausted "
                  f"({detail['ordinal']} of {m['max_edits']} claims).", file=sys.stderr)
        print(allow_line, file=sys.stderr)
    else:
        print("Orchestrators dispatch, they do not edit: file a todo and kick "
              "off a worker (herdr-orchestration SKILL.md, Safety).", file=sys.stderr)
        print(allow_line, file=sys.stderr)
    sys.stderr.flush()
    return 2


# --- decision --------------------------------------------------------------

def decide(payload):
    """Exit status for one PreToolUse payload: 0 allow, 2 refuse."""
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "PreToolUse":
        return 0
    tool = payload.get("tool_name")
    if tool not in TOOLS or os.environ.get("HERDR_ENV") != "1":
        return 0
    sid = payload.get("session_id")
    if not isinstance(sid, str) or not SESSION_ID_RE.match(sid):
        return 0
    owned = owned_slugs(sid)
    if not owned:
        return 0
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    home = os.environ.get("HOME", os.path.expanduser("~"))
    paths = resolve_targets(targets_for(payload, tool, cwd, home), home)
    if not paths:
        return 0
    state_real = os.path.realpath(core.state_root())
    budget = Budget(GIT_BUDGET_SECS)
    guarded = []
    for p in paths:
        if exempt(p, state_real):
            continue
        hit = classify(p, budget)
        if hit:
            guarded.append((p, hit[0], hit[1]))
    if not guarded:
        return 0
    tool_use_id = payload.get("tool_use_id")
    verdict = marker_verdict(guarded, owned, sid, tool_use_id, budget)
    if verdict[0] == "allow":
        _, slug, marker = verdict
        for c, top, reason in guarded:
            audit_append(slug, {
                "v": 1, "ts": core.now_iso(), "event": "orch-edit-allowed",
                "session_id": sid, "tool_name": tool, "tool_use_id": tool_use_id,
                "path": c[:PATH_MAX], "repo": top[:PATH_MAX], "reason": reason,
                "marker_id": marker["marker_id"], "marker_expires": marker.get("expires")})
        return 0
    _, why, slug, detail = verdict
    detail = dict(detail, owned=",".join(sorted(owned)))
    rc = refuse(why, slug, owned[slug], sid, guarded[0], detail)
    c, top, reason = guarded[0]
    audit_append(slug, {
        "v": 1, "ts": core.now_iso(), "event": "orch-edit-denied",
        "session_id": sid, "tool_name": tool, "tool_use_id": tool_use_id,
        "path": c[:PATH_MAX], "repo": top[:PATH_MAX], "reason": reason, "why": why})
    return rc


def main():
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    return decide(payload)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
