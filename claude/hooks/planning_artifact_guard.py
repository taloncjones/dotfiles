#!/usr/bin/env python3
"""PreToolUse hook: refuse staging or committing private planning artifacts.

Specs, plans, and herdr verification contracts are working documents, not
repository content. Committed copies were read as authoritative, bloated
PRs, and polluted work-repo branches (2026-09-08/09). Ignore rules keep
them out of `git add -A`; this hook is the backstop for `-f`, literal
paths, and machines whose ignore rules are stale.

Active in every session (no HERDR_ENV gate): the rule is global policy.
Matcher `Bash`; rm_guard's payload shapes (Claude Bash, Codex
exec_command / shell_command / unified_exec) are accepted, so the same file
serves both runtimes.

Denies (exit 2; stderr: the command and path, then the rule and override):
- `git add|stage` of a pathspec at or under a protected prefix, resolved
  against every literal possible working directory (git -C, a leading cd,
  subshells and && / || chains, tracked as a set like git_remote_guard);
  with no resolvable directory the pathspec is read as top-level-relative.
- `git add|stage -A|--all|-u|--update|.|<dir>` when `git status` shows an
  added, modified, renamed, copied, or untracked (with -f: ignored) entry
  under a protected prefix within the pathspec; deletions alone pass.
- `git commit` when the index holds a non-deletion change under a
  protected prefix; with -a/--all/-i/--include also the worktree; with
  --amend also HEAD's own change set; with -o/--only or pathspecs, those
  paths as for add.

Protected prefixes are relative to `git rev-parse --show-toplevel`:
docs/specs/, docs/plans/, docs/superpowers/, .planning/, claude/contracts/.

Allowed: a repository whose top level is under $TMPDIR or /tmp and not
under HOME (test fixtures); `DOTFILES_ALLOW_PLAN_ARTIFACTS=1` as a leading
env assignment on the segment; every other git subcommand.

Git calls share one 10-second budget; a failed or timed-out call yields no
decision for that scan. Accepted holes: aliases, scripts, eval, xargs git,
a non-literal cd before a scan (the scan runs against the payload cwd),
`--git-dir`/`--work-tree` forms (no decision), --amend hiding a path
introduced before HEAD, and commits made outside a Claude or Codex session.
Reuses rm_guard's tokenizer and git_remote_guard's cwd-set primitives;
fails open on any exception.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import git_remote_guard as grg
import rm_guard

OVERRIDE = "DOTFILES_ALLOW_PLAN_ARTIFACTS=1"
PROTECTED = (
    "docs/specs/",
    "docs/plans/",
    "docs/superpowers/",
    ".planning/",
    "claude/contracts/",
)
GIT_BUDGET_SECS = 10.0
GIT_CALL_MAX_SECS = 5.0
ADD_VERBS = ("add", "stage")
ADD_ALL = ("-A", "--all", "--no-ignore-removal", "--ignore-removal")
ADD_UPDATE = ("-u", "--update")
FORCE = ("-f", "--force")
ADD_OPTS_WITH_ARG = ("--chmod", "--pathspec-from-file")
COMMIT_ALL = ("-a", "--all", "-i", "--include")
COMMIT_ONLY = ("-o", "--only")
COMMIT_OPTS_WITH_ARG = (
    "-m", "--message", "-F", "--file", "-C", "--reuse-message", "-c",
    "--reedit-message", "--fixup", "--squash", "--author", "--date", "-t",
    "--template", "--cleanup", "--trailer", "--pathspec-from-file",
)
COMMIT_SHORT_WITH_ARG = "mFCct"
STAGING = set("AMRC")
GLOB_CHARS = "*?["
RULE = (
    "Planning docs, specs, plans, and verification contracts stay untracked; "
    "unstage with git restore --staged, or prefix the segment with "
    "DOTFILES_ALLOW_PLAN_ARTIFACTS=1 for a deliberate exception."
)


class Budget:
    """One monotonic deadline shared by every git call of an invocation."""

    def __init__(self, secs):
        self.deadline = time.monotonic() + secs

    def slice(self):
        return min(GIT_CALL_MAX_SECS, self.deadline - time.monotonic())


def git(args, cwd, budget):
    """(returncode, stdout bytes); (None, b"") on timeout, missing git, or
    an exhausted budget. Every caller treats None as 'no decision'."""
    left = budget.slice()
    if left <= 0:
        return None, b""
    try:
        p = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            timeout=left,
            env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"),
            check=False,
        )
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None, b""


def toplevel(d, ctx):
    """Real path of the work tree containing `d`, or None (cached per dir)."""
    if d not in ctx["tops"]:
        rc, out = git(["rev-parse", "--show-toplevel"], d, ctx["budget"])
        top = out.decode("utf-8", "surrogateescape").strip() if rc == 0 else ""
        ctx["tops"][d] = os.path.realpath(top) if top else None
    return ctx["tops"][d]


def protected_hit(rel):
    """The protected prefix a top-level-relative path sits under, or None."""
    for prefix in PROTECTED:
        if rel == prefix.rstrip("/") or rel.startswith(prefix):
            return prefix
    return None


def needs_scan(rel):
    """True for `.` or a strict ancestor of a protected prefix; a glob counts
    by the literal directory before its first glob character."""
    head = rel
    for i, c in enumerate(rel):
        if c in GLOB_CHARS:
            before = rel[:i]
            head = before.rsplit("/", 1)[0] if "/" in before else ""
            break
    if head in ("", "."):
        return True
    return any(p.startswith(head + "/") for p in PROTECTED)


def classify(pathspec, d, top, home):
    """('deny', prefix, rel) | ('scan', rel) | ('skip',).

    With a known top level and a literal pathspec the path is resolved from
    `d` with filesystem semantics (`top` is a real path, so the join must be
    too, or a symlinked /tmp or checkout would hide every hit); when the
    path cannot be placed under `top`, the pathspec string itself is read as
    top-level-relative, so a `cd "$var"` or a failed git call cannot hide
    `docs/specs/x.md` either."""
    spec = pathspec[2:] if pathspec.startswith("./") and len(pathspec) > 2 else pathspec
    rel = None
    if top is not None and d is not None and grg.literal(spec):
        abs_path = grg.resolve_filesystem(spec, d, home)
        if abs_path == top:
            rel = "."
        elif abs_path.startswith(top + "/"):
            rel = abs_path[len(top) + 1 :]
    if rel is None:
        rel = os.path.normpath(spec) if spec else "."
        if rel.startswith("/") or rel == ".." or rel.startswith("../"):
            return ("skip",)
    hit = protected_hit(rel)
    if hit:
        return ("deny", hit, rel)
    if needs_scan(rel):
        return ("scan", rel)
    return ("skip",)


def parse_add(args):
    """(pathspecs, force, scan_all, update_only)."""
    specs, force, scan_all, update = [], False, False, False
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "--":
            specs.extend(args[i + 1 :])
            break
        if tok in FORCE:
            force = True
        elif tok in ADD_ALL:
            scan_all = True
        elif tok in ADD_UPDATE:
            update = True
        elif tok in ADD_OPTS_WITH_ARG:
            scan_all = scan_all or tok == "--pathspec-from-file"
            i += 1
        elif tok.startswith("--pathspec-from-file="):
            scan_all = True
        elif tok.startswith("-") and not tok.startswith("--") and len(tok) > 2:
            flags = tok[1:]
            force = force or "f" in flags
            scan_all = scan_all or "A" in flags
            update = update or "u" in flags
        elif tok.startswith("-"):
            pass
        else:
            specs.append(tok)
        i += 1
    return specs, force, scan_all, update


def parse_commit(args):
    """(pathspecs, include_worktree, only, amend)."""
    specs, worktree, only, amend = [], False, False, False
    i = 0
    while i < len(args):
        tok = args[i]
        if tok == "--":
            specs.extend(args[i + 1 :])
            break
        if tok in COMMIT_ALL:
            worktree = True
        elif tok in COMMIT_ONLY:
            only = True
        elif tok == "--amend":
            amend = True
        elif tok in COMMIT_OPTS_WITH_ARG:
            i += 1
        elif tok.startswith("--"):
            pass
        elif tok.startswith("-") and len(tok) > 1:
            cluster = tok[1:]
            for j, c in enumerate(cluster):
                if c in "ai":
                    worktree = True
                elif c == "o":
                    only = True
                elif c in COMMIT_SHORT_WITH_ARG:
                    if j == len(cluster) - 1:
                        i += 1  # -m msg: the value is the next token
                    break  # -mmsg: the rest of the cluster is the value
        else:
            specs.append(tok)
        i += 1
    return specs, worktree, only, amend


def status_hits(d, specs, ctx, untracked, ignored):
    """Protected paths `git status` would stage under `specs` (all when
    empty), or None when git gave no answer. Porcelain paths are top-level
    relative; deletions alone never count."""
    args = ["status", "--porcelain=v1", "-z", "--untracked-files=all"]
    if ignored:
        args.append("--ignored")
    if specs:
        args += ["--", *specs]
    rc, out = git(args, d, ctx["budget"])
    if rc != 0:
        return None
    fields = out.split(b"\0")
    hits = []
    i = 0
    while i < len(fields):
        entry = fields[i].decode("utf-8", "surrogateescape")
        i += 1
        if len(entry) < 4:
            continue
        x, y, path = entry[0], entry[1], entry[3:]
        if x in "RC":
            i += 1  # the original path follows as its own field
        xy = x + y
        staged = (
            x in STAGING
            or y in STAGING
            or (untracked and xy == "??")
            or (ignored and xy == "!!")
        )
        if staged and protected_hit(path):
            hits.append(path)
    return hits


def diff_hits(args, d, ctx):
    """Protected paths named by a `git diff`/`git show` probe, or None."""
    rc, out = git([*args, "-z"], d, ctx["budget"])
    if rc != 0:
        return None
    return [
        p
        for p in out.decode("utf-8", "surrogateescape").split("\0")
        if p and protected_hit(p)
    ]


def exempt(top, ctx):
    return top is not None and grg.under_root(top, ctx["roots"], ctx["home_real"]) is not None


def check_add(args, dirs, ctx):
    specs, force, scan_all, update = parse_add(args)
    for d in sorted(dirs) or [None]:
        top = toplevel(d, ctx) if d is not None else None
        if exempt(top, ctx):
            continue
        to_scan = []
        for spec in specs:
            verdict = classify(spec, d, top, ctx["home"])
            if verdict[0] == "deny":
                return f"git add of {verdict[2]} stages a private planning artifact ({verdict[1]})"
            if verdict[0] == "scan":
                to_scan.append(spec)
        if top is None or not (scan_all or update or to_scan):
            continue
        # Keep git's own pathspec limiter: `git add -A README.md` scans
        # README.md only, never the whole tree.
        hits = status_hits(d, to_scan or specs, ctx, untracked=not update, ignored=force)
        if hits:
            return f"git add would stage a private planning artifact ({hits[0]})"
    return None


def check_commit(args, dirs, ctx):
    specs, worktree, only, amend = parse_commit(args)
    for d in sorted(dirs) or [None]:
        top = toplevel(d, ctx) if d is not None else None
        if exempt(top, ctx):
            continue
        if top is None:
            # No repository to probe: only literal pathspecs can decide.
            for spec in specs:
                verdict = classify(spec, d, top, ctx["home"])
                if verdict[0] == "deny":
                    return f"git commit of {verdict[2]} records a private planning artifact ({verdict[1]})"
            continue
        probes = []
        if not (only and specs):
            probes.append(["diff", "--cached", "--name-only", "--diff-filter=d"])
        if worktree:
            probes.append(["diff", "--name-only", "--diff-filter=d"])
        if amend:
            probes.append(["show", "--pretty=", "--name-only", "--diff-filter=d", "HEAD"])
        for probe in probes:
            hits = diff_hits(probe, d, ctx)
            if hits:
                return f"git commit would record a private planning artifact ({hits[0]})"
        to_scan = []
        for spec in specs:
            verdict = classify(spec, d, top, ctx["home"])
            if verdict[0] == "deny":
                return f"git commit of {verdict[2]} records a private planning artifact ({verdict[1]})"
            if verdict[0] == "scan":
                to_scan.append(spec)
        if to_scan:
            hits = status_hits(d, to_scan, ctx, untracked=False, ignored=False)
            if hits:
                return f"git commit would record a private planning artifact ({hits[0]})"
    return None


def check_git(tokens, possible, ctx):
    sub, args, cdirs, hints, unknown = grg.parse_git(tokens)
    if unknown or hints or sub not in (*ADD_VERBS, "commit"):
        return None
    literal_cwds = {c for c in possible if grg.literal(c)} or {ctx["cwd"]}
    dirs, err = grg.effective_dirs(cdirs, literal_cwds, ctx["home"])
    if err:
        dirs = set()
    if sub in ADD_VERBS:
        return check_add(args, dirs, ctx)
    return check_commit(args, dirs, ctx)


def check_command(command, ctx, start=None):
    """Denial reason for `command`, or None. Same chain bookkeeping as the
    git-metadata guard's walk (possible cwds as a set), without its
    metadata checks."""
    start = set(start) if start is not None else {ctx["cwd"]}
    if grg.quoted_operator(command):
        start = {grg.UNTRUSTED}
    tokens = grg.normalize_operators(rm_guard.tokenize(command))
    home = ctx["home"]
    state = {"chain": grg.Chain(start)}
    stack = []
    current = []

    def evaluate(raw, term):
        chain = state["chain"]
        possible = chain.possible()
        stripped = rm_guard.strip_prefixes(raw)
        overridden = OVERRIDE in raw[: len(raw) - len(stripped)]
        head = rm_guard.basename(stripped[0]) if stripped else ""
        if head == "cd" and term not in ("|", "&"):
            targets = {
                grg.cd_target(stripped, cwd, home) if grg.literal(cwd) else grg.UNTRUSTED
                for cwd in possible
            }
            chain.record_cd(next(iter(targets)) if len(targets) == 1 else grg.UNTRUSTED)
        reason = None
        if overridden or not stripped or head == "cd":
            pass
        elif head in rm_guard.SHELL_WRAPPERS:
            inner = rm_guard.extract_shell_c_arg(stripped)
            if inner is not None:
                reason = check_command(inner, ctx, possible)
        elif head == "git":
            reason = check_git(stripped, possible, ctx)
        chain.first = False
        return reason

    def apply_term(term):
        if term in (";", "\n", "", "&"):
            state["chain"] = grg.Chain(state["chain"].after())
        elif term == "||":
            state["chain"].pure = False

    def flush(term):
        reason = None
        if current:
            raw = list(current)
            current.clear()
            reason = evaluate(raw, term)
        apply_term(term)
        return reason

    for tok in tokens:
        if tok == "(":
            if current:
                if (reason := evaluate(list(current), "&&")) is not None:
                    return reason
                current.clear()
            stack.append(state["chain"])
            state["chain"] = grg.Chain(state["chain"].possible())
        elif tok == ")":
            if (reason := flush("")) is not None:
                return reason
            if stack:
                state["chain"] = stack.pop()
                state["chain"].first = False
        elif grg.is_operator(tok):
            if (reason := flush(tok)) is not None:
                return reason
        else:
            current.append(tok)
    return flush("")


def decide(data):
    tool = data.get("tool_name") or data.get("toolName") or ""
    if not isinstance(tool, str) or tool.lower() not in rm_guard.SHELL_TOOLS:
        return None
    tool_input = data.get("tool_input") or data.get("toolInput") or {}
    if not isinstance(tool_input, dict):
        return None
    nested = tool_input.get("args")
    inputs = [tool_input] + ([nested] if isinstance(nested, dict) else [])
    command = next(
        (v for item in inputs for k in ("command", "cmd") if isinstance(v := item.get(k), str)),
        "",
    )
    if not command.strip() or "git" not in command:
        return None
    home = os.environ.get("HOME", os.path.expanduser("~"))
    home_real = os.path.realpath(home)
    payload_cwd = data.get("cwd")
    cwd = payload_cwd if isinstance(payload_cwd, str) and payload_cwd else os.getcwd()
    tool_cwd = next(
        (v for item in inputs for k in ("workdir", "cwd") if isinstance(v := item.get(k), str) and v),
        None,
    )
    if tool_cwd is not None:
        cwd = grg.resolve_filesystem(tool_cwd, cwd, home)
    ctx = {
        "cwd": cwd,
        "home": home,
        "home_real": home_real,
        "roots": grg.tmp_roots(home_real),
        "budget": Budget(GIT_BUDGET_SECS),
        "tops": {},
    }
    return check_command(command, ctx)


def main():
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(data, dict):
        return 0
    reason = decide(data)
    if not reason:
        return 0
    print("Blocked: " + reason + ".", file=sys.stderr)
    print(RULE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
