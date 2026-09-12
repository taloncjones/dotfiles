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
10-second budget, NotebookEdit/MultiEdit, `awk`/`gawk -i inplace` (cycle-3
A-1; only sed/gsed/perl are modeled as in-place editors). This is a guard
against drift, not evasion.

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
import shlex
import stat
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True  # never leave __pycache__ under the hooks dir
sys.path.insert(0, str(Path(__file__).resolve().parent))
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
        p = subprocess.run(
            ["git", "-C", cwd, *args],
            capture_output=True,
            text=True,
            timeout=left,
            env=env,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    return p.returncode, p.stdout


# --- state root reads ------------------------------------------------------


def read_state_json(path):
    """Parsed regular payload object, or None for an invalid marker."""
    try:
        data = json.loads(core.read_payload_text(path))
    except (OSError, ValueError, json.JSONDecodeError):
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
        ):
            continue
        entry = {"fence": rec["fence"], "rd": rd, "caller_scope": caller_scope}
        if slug in targets:
            entry.update(targets[slug])
        owned[slug] = entry
    return owned


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
    except (OSError, ValueError):
        return None


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
    quote = None
    while i < n:
        c = text[i]
        if quote:
            if quote == '"' and c == "\\" and i + 1 < n:
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
            out.append(text[i : i + 2])
            i += 2
            continue
        if c == "#" and (i == 0 or text[i - 1] in " \t\n;&|("):
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
                num = len(redirs)
                redirs[num] = word
                out.append(f" __ORCH_REDIR_{num}__ ")
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
    except (OSError, ValueError):
        dprobe = ""
    if dprobe and os.path.isdir(dprobe):
        out.extend(os.path.join(dest, os.path.basename(s)) for s in srcs)
    else:
        out.append(dest)
    if include_sources:
        out.extend(srcs)
    return out


def _existing(ops, cwd, home):
    return [
        w
        for w in ops
        if os.path.lexists(rm_guard.resolve(rm_guard.expand_home(w, home), cwd))
    ]


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
    than away from it (B3). `pushd` is a `cd` that also remembers the old
    cwd; `popd` returns to it, but this scanner doesn't model the actual
    dir stack, so a `popd` is treated as a cwd change of unknown
    direction -- widened to every cwd candidate seen so far in this
    command, never narrowed (B-2)."""
    if depth > 1:
        return []
    cleaned, redirs = scan_raw(command)
    found = []
    cwds = {cwd}
    seen_cwds = {cwd}
    stack = []
    for kind, tokens, previous, following in segment_groups(rm_guard.tokenize(cleaned)):
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
        # Accepted gap (cycle-3 A-2): rm_guard.strip_prefixes only skips a
        # wrapper name, not its own flag argument (`nice -n 10 sed -i ...`,
        # `time -p ...`, `env -i ...`, `sudo -u x ...`), so the loop below
        # breaks on the flag token and the wrapped sed/perl/tee/cp/mv/rm
        # operand is never inspected. Redirects are unaffected (the
        # sentinel scan above is head-independent); only operand-writers
        # behind a flagged wrapper are missed, a rare shape for an
        # orchestrator edit.
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
        elif head in SHELL_WRAPPERS:
            inner = shell_c_arg(words)
            if inner is not None:
                for c in cwds:
                    found.extend(bash_targets(inner, c, home, depth + 1))
    return found


# --- targets ---------------------------------------------------------------


def targets_for(payload, tool, cwd, home):
    """[(cwd, word, shell_expands)] raw write targets of one tool call."""
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        return []
    if tool == "Bash":
        cmd = ti.get("command")
        if not isinstance(cmd, str) or not cmd.strip():
            return []
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
    """Canonical absolute paths, skipping anything the shell would still
    expand ($VAR, backticks, globs), deduplicated, capped."""
    paths = []
    for c_cwd, w, shell_expands in raw:
        w = rm_guard.expand_home(w, home)
        if not w or (
            shell_expands and ("$" in w or "`" in w or rm_guard.has_glob_chars(w))
        ):
            continue
        p = canonical_target(w, c_cwd, home)
        if p is not None and p not in paths:
            paths.append(p)
    return paths[:TARGET_CAP]


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
        except ValueError:
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
    except (OSError, ValueError, subprocess.SubprocessError, KeyError):
        return "deny", "fence", slug, {}


# --- refusal ---------------------------------------------------------------


def refuse(why, slug, fence, session_id, first, detail, runtime, rd):
    """Print the three-line refusal for `why` and return 2."""
    c, top, reason = first
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
            print(
                f"Cannot reserve budget: {Path(rd) / 'tasks' / AUDIT_FILE} "
                "is not writable.",
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
        return 0
    home = os.environ.get("HOME", os.path.expanduser("~"))
    paths = resolve_targets(targets_for(payload, tool, cwd, home), home)
    if not paths:
        return 0
    state_real = os.path.realpath(
        core.account_payload_root(caller_scope) / "herdr-orch"
    )
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
    slug_cache = {}
    candidates = {}
    for _path, top, _reason in guarded:
        slug = repo_slug_of(top, budget, slug_cache)
        if slug is not None:
            candidates.setdefault(slug, top)
    owned = owned_slugs(sid, runtime, caller_scope, candidates)
    if not owned:
        return 0
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
    rc = refuse(why, slug, owned[slug]["fence"], sid, guarded[0], detail, runtime, rd)
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
