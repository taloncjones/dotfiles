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
destinations, `mv` sources and destinations, `rm`/`rmdir` operands, and
one level of `sh -c` (a combined flag cluster like `-lc`/`-ec` counts).

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
`$VAR`/`$(...)`/globs, a heredoc with no terminator, git calls past the
10-second budget, NotebookEdit/MultiEdit. This is a guard against drift,
not evasion.

Beyond TARGET_CAP (20) distinct targets, only the extra ones past the cap
are unguarded (paths[:TARGET_CAP] keeps the first 20 seen and drops the
rest) -- a single command mixing scratch and tracked targets is guarded
or not per target, in first-seen order, not as a whole-command allow.

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
SENTINEL_RE = re.compile(r"__ORCH_REDIR_(\d+)__\Z")
WORD_STOP = " \t\n;&|()<>"
SHELL_WRAPPERS = ("sh", "bash", "zsh", "dash")


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
                out.append(text[j + 1]); j += 2; continue
            if c == quote:
                quote = None; j += 1; continue
            out.append(c); j += 1; continue
        if c in "'\"":
            quote = c; j += 1; continue
        if c == "\\" and j + 1 < n:
            out.append(text[j + 1]); j += 2; continue
        if c in WORD_STOP:
            break
        out.append(c); j += 1
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
    if k < len(out) and (k == 0 or out[k - 1] in (" ", "\t", "\n", ";", "&", "|", "(", ")")):
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
    arith_paren = 0    # open '(' still needed to close a $(( ... )) we're in
    arith_bracket = 0  # open '[' still needed to close a $[ ... ] we're in
    i = 0
    quote = None
    while i < n:
        c = text[i]
        if quote:
            if quote == '"' and c == "\\" and i + 1 < n:
                out.append(text[i:i + 2]); i += 2; continue
            if c == quote:
                quote = None
            out.append(c); i += 1; continue
        if c in "'\"":
            quote = c; out.append(c); i += 1; continue
        if c == "\\" and i + 1 < n:
            out.append(text[i:i + 2]); i += 2; continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "\n":
            out.append(c); i += 1
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
                out.append("$(("); i += 3; continue
            if c == "$" and text.startswith("$[", i):
                arith_bracket = 1
                out.append("$["); i += 2; continue
        elif arith_paren > 0:
            if c == "(":
                arith_paren += 1
            elif c == ")":
                arith_paren -= 1
            out.append(c); i += 1; continue
        elif arith_bracket > 0:
            if c == "[":
                arith_bracket += 1
            elif c == "]":
                arith_bracket -= 1
            out.append(c); i += 1; continue
        if c == "<":
            if text.startswith("<<<", i) or text.startswith("<>", i) \
                    or not text.startswith("<<", i):
                # input redirection (<, <>, <<<): consume the operator, an
                # IO number before it, and the operand; never a target
                j = i + (3 if text.startswith("<<<", i) else 2 if text.startswith("<>", i) else 1)
                m = j
                while m < n and text[m] in " \t":
                    m += 1
                del out[io_number_start(out):]
                if m < n and text[m] == "&":
                    e = m + 1
                    while e < n and text[e].isdigit():
                        e += 1
                else:
                    _w, e = read_word(text, m)
                out.append(" "); i = e; continue
            j = i + 2                              # heredoc
            strip_tabs = False
            if j < n and text[j] == "-":
                strip_tabs = True; j += 1
            while j < n and text[j] in " \t":
                j += 1
            word, j = read_word(text, j)
            heredocs.append((word, strip_tabs))
            del out[io_number_start(out):]        # 0<<EOF: the IO number goes too
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
            del out[io_number_start(out):]        # 2> / &> prefix, if any
            if m < n and text[m] == "&":
                e = m + 1
                while e < n and text[e].isdigit():
                    e += 1
                if e > m + 1:                      # dup: >&2, 2>&1
                    out.append(" "); i = e; continue
                if e < n and text[e] == "-":        # close: >&-
                    out.append(" "); i = e + 1; continue
                # bare '&' with no digit/'-' after it: >&file / >>&file
                # redirects stdout+stderr to a FILENAME, not a dup (B2).
                m = e
                while m < n and text[m] in " \t":
                    m += 1
            if m < n and text[m] == "(":          # process substitution
                out.append(" "); i = m; continue
            word, e = read_word(text, m)
            if word:
                num = len(redirs)
                redirs[num] = word
                out.append(f" __ORCH_REDIR_{num}__ ")
            else:
                out.append(" ")
            i = e
            continue
        out.append(c); i += 1
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
    script option (-e/-f, or a bundled -ne/-pe cluster) is present."""
    if not has_inplace(words):
        return []
    explicit = False
    ops, skip = [], False
    for t in words[1:]:
        if skip:
            skip = False; continue
        if t in value_opts:
            skip = True; explicit = True; continue
        if any(t.startswith(v + "=") for v in value_opts if v.startswith("--")):
            explicit = True; continue
        if t.startswith("-") and not t.startswith("--") and len(t) > 1 \
                and any(ch in t[1:] for ch in script_flags):
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
    resolved by resolve_targets/canon() through its final target, not as
    the symlink entry mv actually removes; catching that needs a
    dereference-mode flag threaded through every target tuple, not a
    local fix here."""
    ops, tdir, skip = [], None, False
    for t in words[1:]:
        if skip:
            tdir = t; skip = False; continue
        if t in ("-t", "--target-directory"):
            skip = True; continue
        if t.startswith("--target-directory="):
            tdir = t.split("=", 1)[1]; continue
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
    dpath = rm_guard.resolve(rm_guard.expand_home(dest, home), cwd)
    if os.path.isdir(dpath):
        out.extend(os.path.join(dpath, os.path.basename(s)) for s in srcs)
    else:
        out.append(dest)
    if include_sources:
        out.extend(srcs)
    return out


def _existing(ops, cwd, home):
    return [w for w in ops
            if os.path.lexists(rm_guard.resolve(rm_guard.expand_home(w, home), cwd))]


def shell_c_arg(words):
    """Like rm_guard.extract_shell_c_arg, but a flag CLUSTER containing
    `c` (`-lc`, `-ec`) is also a `-c <script>` invocation, not just a
    standalone `-c` -- the ordinary login/exit-on-error spellings that
    rm_guard's exact-token match misses (B1)."""
    i = 1
    while i < len(words):
        tok = words[i]
        if tok == "-c" or (tok.startswith("-") and not tok.startswith("--")
                            and len(tok) > 1 and "c" in tok[1:]):
            return words[i + 1] if i + 1 < len(words) else None
        if tok.startswith("-"):
            i += 1
            continue
        break
    return None


def segment_groups(tokens):
    """Yield ('seg', words) per `;`/`&`/`|`-separated segment, and
    ('push', []) / ('pop', []) at `(`/`)` subshell boundaries -- a `cd`
    inside a subshell must not persist past its closing `)` (B3)."""
    current = []
    for tok in tokens:
        if tok and all(c in ";&|\n" for c in tok):
            if current:
                yield "seg", current
                current = []
        elif tok == "(":
            if current:
                yield "seg", current
                current = []
            yield "push", []
        elif tok == ")":
            if current:
                yield "seg", current
                current = []
            yield "pop", []
        else:
            current.append(tok)
    if current:
        yield "seg", current


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


def cd_target_candidates(words, cwd, home):
    """The set of cwds the shell might be in after a `cd`: one, when the
    target can be confirmed a real directory; {target, cwd} otherwise --
    a `cd` to a nonexistent directory leaves the shell in `cwd`, and the
    guard cannot know at scan time which it will be, so both are scanned
    and a write is guarded if EITHER lands on a tracked path (B3). Option
    flags (`-L`/`-P`/...) and a `--` marker are skipped to find the real
    operand; bare `cd` and `cd -` are a no-op (HOME/OLDPWD are not
    tracked), matching the existing accepted-hole simplification."""
    operand, seen_dashdash = None, False
    for t in words[1:]:
        if not seen_dashdash and t == "--":
            seen_dashdash = True
            continue
        if not seen_dashdash and t.startswith("-") and t != "-" and len(t) > 1:
            continue
        operand = t
        break
    if operand is None or operand == "-":
        return {cwd}
    if "$" in operand or "`" in operand or rm_guard.has_glob_chars(operand):
        return {cwd}  # unexpanded target: accepted hole, same as other operands
    target = rm_guard.resolve(rm_guard.expand_home(operand, home), cwd)
    return {target} if os.path.isdir(target) else {target, cwd}


def bash_targets(command, cwd, home, depth=0):
    """[(cwd, word)] write targets of one command string. `cwd` is tracked
    as a SET of candidates rather than one string, so an uncertain `cd`
    (a subshell, a failed cd, cd options) fails toward guarding rather
    than away from it (B3)."""
    if depth > 1:
        return []
    cleaned, redirs = scan_raw(command)
    found = []
    cwds = {cwd}
    stack = []
    for kind, tokens in segment_groups(rm_guard.tokenize(cleaned)):
        if kind == "push":
            stack.append(cwds)
            continue
        if kind == "pop":
            if stack:
                cwds = stack.pop()
            continue
        words = []
        for t in tokens:
            m = SENTINEL_RE.match(t)
            if m:
                w = redirs.get(int(m.group(1)))
                if w:
                    found.extend((c, w) for c in cwds)
            else:
                words.append(t)
        words = rm_guard.strip_prefixes(words)
        if not words:
            continue
        head = rm_guard.basename(words[0])
        if head == "cd":
            new_cwds = set()
            for c in cwds:
                new_cwds |= cd_target_candidates(words, c, home)
            cwds = new_cwds
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
        elif head in SHELL_WRAPPERS:
            inner = shell_c_arg(words)
            if inner is not None:
                for c in cwds:
                    found.extend(bash_targets(inner, c, home, depth + 1))
    return found


# --- targets ---------------------------------------------------------------

def targets_for(payload, tool, cwd, home):
    """[(cwd, word)] raw write targets of one tool call."""
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        return []
    if tool == "Bash":
        cmd = ti.get("command")
        if not isinstance(cmd, str) or not cmd.strip():
            return []
        return bash_targets(cmd, cwd, home)
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
    plain regular file (symlink, FIFO) or cannot be opened. Never raises.

    Accepted gap (A5): near-identical to herdr_orch_core.append_orch_edit
    (same O_APPEND|O_NOFOLLOW + short-write check); the two must stay
    byte-compatible for the shared budget log but are not shared code."""
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


# --- marker and budget -----------------------------------------------------

def read_marker(slug, session_id, fence):
    """(marker, None) when the slug's marker is valid for this session and
    fence and unexpired; else (None, why) with why in no-marker, fence,
    expired. A malformed file is no marker, never an exception."""
    m = read_state_json(core.repo_dir(slug) / MARKER_FILE)
    if not m or m.get("v") != 1 or m.get("session_id") != session_id:
        return None, "no-marker"
    mid = m.get("marker_id")
    if not isinstance(mid, str) or not MARKER_ID_RE.match(mid):
        return None, "no-marker"
    me = m.get("max_edits")
    if isinstance(me, bool) or not isinstance(me, int) \
            or not (MAX_EDITS_RANGE[0] <= me <= MAX_EDITS_RANGE[1]):
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


def claim_budget(slug, marker, session_id, tool_use_id, paths):
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
        rec = {"v": 1, "ts": core.now_iso(), "event": "orch-edit-claim",
               "marker_id": marker["marker_id"], "claim_id": claim_id,
               "session_id": session_id, "tool_use_id": tool_use_id,
               "path": p[:PATH_MAX]}
        if not audit_append(slug, rec):
            return None
    try:
        with open(core.repo_dir(slug) / "tasks" / AUDIT_FILE, errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return None
    ordinal, own, seen = 0, None, 0
    for line in lines:
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("event") != "orch-edit-claim" \
                or rec.get("marker_id") != marker["marker_id"]:
            continue
        ordinal += 1
        if rec.get("claim_id") == claim_id:
            own = ordinal
            seen += 1
    # Every claim of this invocation must have survived as a parseable
    # line; a lost or mangled one (a concurrent partial line spliced into
    # ours) means the reservation is not complete, so deny.
    return own if seen == len(paths) else None


def marker_verdict(guarded, owned, session_id, tool_use_id, budget):
    """('allow', slug, marker) or ('deny', why, slug, detail). Every
    guarded target must resolve to one slug this session owns; that
    slug's marker must validate; then the budget claim must land within
    max_edits."""
    cache = {}
    slugs = {}
    for c, top, _reason in guarded:
        slugs.setdefault(repo_slug_of(top, budget, cache), []).append(c)
    first = sorted(owned)[0]
    if len(slugs) != 1 or None in slugs or next(iter(slugs)) not in owned:
        # When every slug in `slugs` IS owned (a single command writing
        # tracked files in two repos this session owns), the generator
        # below finds none and target_slug prints as "unknown" -- a safe
        # deny either way, but the refusal wording is misleading for this
        # one-command-two-repos shape (A4).
        target = next((s for s in slugs if s not in owned), None) or "unknown"
        return "deny", "scope", first, {"target_slug": target}
    slug = next(iter(slugs))
    marker, why = read_marker(slug, session_id, owned[slug])
    if marker is None:
        return "deny", why, slug, {}
    ordinal = claim_budget(slug, marker, session_id, tool_use_id,
                           [c for c, _top, _reason in guarded])
    if ordinal is None:
        return "deny", "budget", slug, {"unwritable": True, "marker": marker}
    if ordinal > marker["max_edits"]:
        return "deny", "budget", slug, {"ordinal": ordinal, "marker": marker}
    return "allow", slug, marker


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
