#!/usr/bin/env python3
"""PermissionRequest hook: allow scratch-only rm/rmdir by policy.

Fires only when a Bash permission prompt would otherwise be shown (after
rm_guard.py has passed the command and, in auto mode, after the classifier
declined to decide). Prints an allow decision when EVERY segment of the
command is a plain `rm`/`rmdir` invocation and EVERY target canonicalizes
strictly under a throwaway root: the session scratchpad (payload
`scratchpad_dir`), `$TMPDIR` (or `/tmp` when unset), or a `mktemp` entry
directly under `/tmp`. Anything else, and every error, is "no decision":
exit 0 with empty output, so the normal prompt flow continues. Never
denies. See docs/specs/2026-09-07-scratch-policy-hook.md (branch-only)
for the full rule set; the CLAUDE.md bullet is the durable summary.

When HERDR_ENV=1 and HERDR_WORKSPACE_ID resolves to a workspace index,
each allow is audited to <repo dir>/tasks/<task_id>.policy.jsonl. The
allow is printed and flushed before logging; logging failures never
change the decision.
"""

import fnmatch
import json
import os
import shlex
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_orch_core as core  # noqa: E402  read-only helpers
import rm_guard  # noqa: E402  parsing helpers, unchanged

ALLOW = ('{"hookSpecificOutput":{"hookEventName":"PermissionRequest",'
         '"decision":{"behavior":"allow"}}}')
MODES = ("default", "auto", "acceptEdits")
HEADS = {
    "rm": "rm", "/bin/rm": "rm", "/usr/bin/rm": "rm",
    "rmdir": "rmdir", "/bin/rmdir": "rmdir", "/usr/bin/rmdir": "rmdir",
}
JOINERS = ("&&", ";", "\n")
# `[`/`]` are refused outright: fnmatch lacks POSIX classes ([[:alpha:]]),
# so only `*` and `?` are expanded, and those match the shell's semantics
# per path component.
RAW_REFUSE = "#$`{}[]"
QUOTE_CHARS = "'\"\\"
OPERATOR_CHARS = ";&|()\n"
# Long options are an exact allowlist: GNU accepts unambiguous
# abbreviations (`--par`, `--rec`), which the flag logic below would
# otherwise misread, so anything not listed yields no decision.
LONG_OK = {
    "rm": ("--recursive", "--force", "--verbose", "--dir", "--one-file-system",
           "--preserve-root", "--no-preserve-root"),
    "rmdir": ("--verbose", "--ignore-fail-on-non-empty"),
}
WALK_CAP = 20000
COMMAND_MAX = 300
EVENT = "scratch-allow"


def raw_ok(command: str) -> bool:
    """Raw-text refusals (spec D2 step 3) plus a strict shlex parse."""
    if any(c in command for c in RAW_REFUSE):
        return False
    if "**" in command:
        return False
    if any(c in command for c in QUOTE_CHARS):
        # A quoted glob or tilde is literal to the shell but not to the
        # expander; a quoted operator (`rm S/x ';' rm S/y`) is a filename
        # to the shell but a separator to the tokenizer. Not our call.
        if rm_guard.has_glob_chars(command) or "~" in command \
                or any(c in command for c in OPERATOR_CHARS):
            return False
    try:
        shlex.split(command)
    except ValueError:
        return False
    return True


def operators_ok(tokens: list) -> bool:
    for tok in tokens:
        if tok in ("(", ")"):
            return False
        if "<" in tok or ">" in tok:
            return False
        if tok and all(c in ";&|\n" for c in tok) and tok not in JOINERS:
            return False
    return True


def segment_targets(tokens: list):
    """(kind, recursive, targets) for a plain remove segment, else None."""
    kind = HEADS.get(tokens[0])
    if kind is None:
        return None
    recursive = False
    targets = []
    only_targets = False
    for tok in tokens[1:]:
        if only_targets:
            targets.append(tok)
        elif tok == "--":
            only_targets = True
        elif tok.startswith("--"):
            if tok not in LONG_OK[kind]:
                return None
            if tok == "--recursive":
                recursive = True
        elif tok.startswith("-") and tok != "-":
            if kind == "rmdir" and "p" in tok[1:]:
                return None  # -p removes ancestors that were never checked
            if kind == "rm" and any(c in "rR" for c in tok[1:]):
                recursive = True
        else:
            targets.append(tok)
    if not targets:
        return None
    return kind, recursive, targets


def discard_root(rp: str, home_real: str) -> bool:
    """True when a candidate root (already a realpath) is `/`, HOME, an
    ancestor of HOME, or shallower than two components."""
    if rp == "/" or rp == home_real or home_real.startswith(rp + "/"):
        return True
    return len([c for c in rp.split("/") if c]) < 2


def compute_roots(payload: dict, home_real: str):
    """[(realpath, kind)]: R1 scratchpad, R2 $TMPDIR, R2b /tmp fallback.
    A set-but-relative TMPDIR is neither: no R2 root at all."""
    roots = []
    sp = payload.get("scratchpad_dir")
    if isinstance(sp, str) and os.path.isabs(sp) and not os.path.islink(sp):
        rp = os.path.realpath(sp)
        if not discard_root(rp, home_real):
            roots.append((rp, "R1"))
    tmpdir = os.environ.get("TMPDIR") or ""
    if not tmpdir:
        roots.append((os.path.realpath("/tmp"), "R2b"))  # count rule waived
    elif os.path.isabs(tmpdir):
        rp = os.path.realpath(tmpdir)
        if not discard_root(rp, home_real):
            roots.append((rp, "R2"))
    return roots


def canon(path: str) -> str:
    """realpath of the longest existing ancestor, joined with the rest."""
    existing, rest = path, []
    while existing != "/" and not os.path.lexists(existing):
        existing, tail = os.path.split(existing)
        rest.append(tail)
    real = os.path.realpath(existing)
    return os.path.join(real, *reversed(rest)) if rest else real


def _raise(err: OSError) -> None:
    raise err


def expand_glob(path: str) -> list:
    """Existing paths matching an absolute glob, hidden entries included.
    An unreadable directory raises: an incomplete listing must never
    certify a target (the caller turns the exception into no decision)."""
    results = ["/"]
    for part in [p for p in path.split("/") if p]:
        nxt = []
        for base in results:
            if rm_guard.has_glob_chars(part):
                if not os.path.isdir(base):
                    continue
                names = sorted(os.listdir(base))
                nxt.extend(os.path.join(base, n) for n in names
                           if fnmatch.fnmatchcase(n, part))
            elif os.path.lexists(os.path.join(base, part)):
                nxt.append(os.path.join(base, part))
        results = nxt
        if not results:
            break
    return results


def find_root(c: str, roots: list, tmpdir_set: bool):
    for root, kind in roots:
        if c.startswith(root + "/"):
            return root, kind
    tmp_real = os.path.realpath("/tmp")
    if tmpdir_set and c.startswith(tmp_real + "/tmp."):
        entry = os.path.join(tmp_real, c[len(tmp_real) + 1:].split("/")[0])
        try:
            st = os.lstat(entry)
        except OSError:
            return None
        if stat.S_ISLNK(st.st_mode) or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
            return None
        return entry, "R3"
    return None


def git_between(c: str, root: str) -> bool:
    p = c
    while p.startswith(root):
        if os.path.lexists(os.path.join(p, ".git")):
            return True
        if p == root:
            return False
        p = os.path.dirname(p)
    return False


def subtree_has_git(path: str) -> bool:
    """True when a .git entry exists anywhere below `path` or the walk
    exceeds WALK_CAP. An unreadable directory raises (no decision)."""
    seen = 0
    for _, dirnames, filenames in os.walk(path, onerror=_raise, followlinks=False):
        if ".git" in dirnames or ".git" in filenames:
            return True
        seen += len(dirnames) + len(filenames)
        if seen > WALK_CAP:
            return True  # beyond the cap: no decision
    return False


def target_in_scope(tok: str, cwd: str, home: str, home_real: str, roots: list,
                    recursive: bool, tmpdir_set: bool) -> bool:
    if tok.startswith("~") and tok != "~" and not tok.startswith("~/"):
        return False  # ~user forms: the shell resolves them, we do not
    expanded = rm_guard.expand_home(tok, home)
    if ".." in expanded.split("/"):
        return False
    resolved = rm_guard.resolve(expanded, cwd)
    parts = resolved.split("/")
    if any(rm_guard.has_glob_chars(p) and p.startswith(".") for p in parts):
        return False
    if rm_guard.has_glob_chars(resolved):
        matches = expand_glob(resolved) or [resolved]
        if any(os.path.basename(m).startswith("-") for m in matches):
            return False  # an expanded entry named like an option (`-rf`)
    else:
        matches = [resolved]
    for m in matches:
        # `rm`/`rmdir` unlink the directory entry named by the target, not
        # whatever it resolves to: if the FINAL component is itself a
        # symlink, the entry that disappears lives at the link's own
        # (unfollowed) location, not at canon(m) below. Scope that location
        # too, so a symlink parked outside every root that merely points
        # inside one (or the reverse) cannot certify a target it does not
        # itself occupy.
        if os.path.islink(m):
            own = os.path.join(canon(os.path.dirname(m)), os.path.basename(m))
            if find_root(own, roots, tmpdir_set) is None:
                return False
        # TOCTOU: this check and the eventual exec are two different
        # resolutions of the same path. An intermediate component swapped
        # for a symlink in between could redirect a deeper deletion out of
        # scope. Accepted: it needs an attacker with concurrent filesystem
        # control racing this hook, the hook only ever allows (never
        # denies), and every root is a throwaway scratch/tmp location.
        c = canon(m)
        found = find_root(c, roots, tmpdir_set)
        if found is None:
            return False
        root, kind = found
        if os.path.basename(c) == ".git":
            return False
        if kind == "R2b" and (c == home_real or c.startswith(home_real + "/")):
            return False  # /tmp fallback never reaches into HOME
        # Applied uniformly across every root kind: a checkout parked under
        # the scratchpad or a /tmp/tmp.* mktemp root is still a checkout,
        # and this hook is the one place that would otherwise let it be
        # auto-removed without a prompt.
        if git_between(c, root):
            return False
        if recursive and os.path.isdir(c) and not os.path.islink(c) and subtree_has_git(c):
            return False
    return True


def decide(payload: dict) -> bool:
    if not isinstance(payload, dict):
        return False
    if payload.get("hook_event_name") != "PermissionRequest" or payload.get("tool_name") != "Bash":
        return False
    mode = payload.get("permission_mode")
    if mode not in MODES:
        return False
    tool_input = payload.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command.strip():
        return False
    if not raw_ok(command):
        return False
    tokens = rm_guard.tokenize(command)
    if not operators_ok(tokens):
        return False
    segments = rm_guard.split_segments(tokens)
    if not segments:
        return False
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    home = os.environ.get("HOME", os.path.expanduser("~"))
    home_real = os.path.realpath(home)
    roots = compute_roots(payload, home_real)
    tmpdir_set = bool(os.environ.get("TMPDIR")) and os.path.isabs(os.environ.get("TMPDIR", ""))
    for tokens in segments:
        parsed = segment_targets(tokens)
        if parsed is None:
            return False
        _, recursive, targets = parsed
        for tok in targets:
            if not target_in_scope(tok, cwd, home, home_real, roots, recursive, tmpdir_set):
                return False
    return True


def log_allow(payload: dict, command: str) -> None:
    if os.environ.get("HERDR_ENV") != "1":
        return
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    if not core.valid_workspace_id(ws):
        return
    root = core.state_root()
    # Sorted-first across repo slugs, deliberately: the payload's `cwd` is
    # attacker-influenced input, and picking the audited repo by matching it
    # against a git remote would mean untrusted data selects where the
    # record lands. herdr_stop_gate.py's find_index() makes the same call
    # for the same reason. Workspace ids are unique in practice, so a
    # cross-slug collision misrouting the audit line is theoretical.
    for idx in sorted(root.glob(f"*/workspaces/{ws}.json")):
        rd = idx.parent.parent
        index = core.read_index(rd, ws)
        if not index:
            continue
        task_id = index.get("task_id")
        if not isinstance(task_id, str) or not core.valid_task_id(task_id):
            return
        tasks = rd / "tasks"
        p = tasks / f"{task_id}.policy.jsonl"
        if not tasks.is_dir() or not core.contained(p, root):
            return
        try:
            st = os.lstat(p)
        except FileNotFoundError:
            st = None
        if st is not None and not stat.S_ISREG(st.st_mode):
            return
        rec = {"v": 1, "ts": core.now_iso(), "event": EVENT, "task_id": task_id,
               "workspace_id": ws, "tool_use_id": payload.get("tool_use_id"),
               "command": command[:COMMAND_MAX]}
        flags = (os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NONBLOCK
                 | getattr(os, "O_NOFOLLOW", 0))
        fd = os.open(p, flags, 0o600)
        try:
            os.write(fd, (json.dumps(rec, separators=(",", ":")) + "\n").encode())
        finally:
            os.close(fd)
        return


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    try:
        allow = decide(payload)
    except Exception:  # noqa: BLE001 -- any failure is "no decision"
        return 0
    if not allow:
        return 0
    sys.stdout.write(ALLOW + "\n")
    sys.stdout.flush()
    try:
        log_allow(payload, payload["tool_input"]["command"])
    except Exception:  # noqa: BLE001 -- logging never changes the decision
        pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open toward the normal prompt flow
        sys.exit(0)
