#!/usr/bin/env python3
"""Hook to deny catastrophic `rm`/`rmdir` targets that a literal permission
rule cannot express.

Bash permission rules are literal, per-subcommand text patterns: they never
expand `~`/`$HOME`, never resolve a path relative to cwd, and cannot express
"any glob directly under root/home/.git". A deny-floor of literal strings
therefore misses `rm -rf /*`, `rm -rf ~/*`, `rm -rf $HOME/*`, `rm -rf .git/*`,
`rm -rf /etc`, compound commands (`cd / && rm -rf *`), shell-wrapped commands
(`sh -c 'rm -rf /*'`), brace-expanded targets (`rm -rf /{,bin}`), and variable
targets (`rm -rf "$X"`) -- see push_guard.py's docstring for the same class of
problem with git push. This hook resolves what a literal rule cannot: it
splits compound commands, skips leading shell keywords (`do`, `then`, `{`, `!`),
unwraps shell/env/nice-style wrappers, shlex-parses
each `rm`/`rmdir` invocation, brace-expands and normalizes every target, and
denies the shapes that are actually catastrophic. A permissionDecision "ask"
could be auto-approved in auto permission mode, so the hook denies (exit 2)
instead.

Scope: this hook only recognizes `rm` and `rmdir` invocations (including
inside `sh -c`/`bash -c`/`zsh -c` wrappers). A command substitution body is
checked like a command, except inside a heredoc body; a substitution the scan
cannot pair denies when an rm follows it. Other deleters
(`find -delete`, `xargs rm`, `gio trash`, etc.) and `rm` reached only via a
pipe are not inspected; that residual is left to the classifier.

The hook also runs warn-only checks for recurring zsh pitfalls (a stored
multi-word command prefix, a `$var:X` modifier, a loop variable named `path`,
`kill` of a multi-PID scalar that zsh does not word-split, a multi-word scalar
expanded unquoted as an argument or `for` list).
A warning is printed as PreToolUse `additionalContext` JSON on stdout with exit
0; it never blocks, and a denial never prints to stdout.

Runs before Claude and Codex shell tool calls. Fails open on any exception,
and on any segment that contains no `rm`/`rmdir` token.
"""

# PEP 604 annotations (`str | None`) are evaluated at def time, so without this
# every function below raises TypeError at IMPORT on Python 3.9 -- the stock
# macOS interpreter, and what `#!/usr/bin/env python3` resolves to before
# Homebrew python is installed. An import-time failure exits 1, which is
# neither the allow (0) nor the deny (2) a hook may return, so every guard that
# imports this module fails OPEN. It happens before main(), so no crash handler
# can catch it, and `py_compile` cannot see it because the annotation is a
# runtime expression.
from __future__ import annotations

import json
import os
import re
import shlex
import sys

SEGMENT_OPERATORS = ";&|()\n"

PREFIX_WRAPPERS = ("env", "exec", "command", "nohup", "time", "xargs", "sudo", "nice")

SHELL_WRAPPERS = ("sh", "bash", "zsh")

REMOVE_COMMANDS = ("rm", "rmdir")

SHELL_TOOLS = {"bash", "shell", "exec_command", "shell_command", "unified_exec"}

SYSTEM_PATHS = (
    "/etc", "/bin", "/usr", "/sbin", "/lib",
    "/System", "/Applications", "/private", "/var", "/opt",
)

# Directories that are legitimately covered by a SYSTEM_PATHS prefix only
# because macOS aliases them (/tmp -> /private/tmp, /var -> /private/var):
# scratch and mktemp cleanup here must stay allowed.
SCRATCH_EXCEPTIONS = ("/tmp", "/var/folders")

RECURSIVE_OR_FORCE_LONG = ("--recursive", "--force")

BRACE_GROUP = re.compile(r"^(.*)\{([^{}]+)\}(.*)$")

LEADING_KEYWORDS = ("do", "then", "else", "elif", "if", "while", "until", "!", "{")

SCALAR_ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\+?=(.*)$", re.S)
VAR_REF = re.compile(r"^\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})$")
# zsh history-style modifier letters; `$sha:path` stays literal (`p` is not one).
MODIFIER = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*):([acehlqrstuAPQ&])")

WARN_PREFIX = (
    "[WARNING] rm_guard: $%s holds several words, but zsh does not word-split "
    "an unquoted variable, so it runs as one command name; write the command "
    "and its flags literally."
)
WARN_MODIFIER = (
    "[WARNING] rm_guard: zsh reads $%s:%s as the :%s modifier on $%s, not as a "
    "literal colon; write ${%s}:%s to keep the colon."
)
WARN_PATH = (
    "[WARNING] rm_guard: zsh ties the variable path to PATH, so a loop variable "
    "named path replaces PATH and later commands are not found; rename it "
    "(for example p or file)."
)


def basename(tok: str) -> str:
    return tok.rsplit("/", 1)[-1]


def is_env_assignment(tok: str) -> bool:
    return "=" in tok and not tok.startswith("-") and "/" not in tok.split("=")[0]


def strip_prefixes(tokens: list[str]) -> list[str]:
    """Drop leading shell keywords, env assignments and wrapper names."""
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if is_env_assignment(tok):
            i += 1
        elif basename(tok) in PREFIX_WRAPPERS:
            i += 1
        elif tok in LEADING_KEYWORDS:
            i += 1
        else:
            break
    return tokens[i:]


def skipped_keyword(tokens: list[str], stripped: list[str]) -> bool:
    """True when strip_prefixes dropped a conditional keyword; a cd there may never run."""
    dropped = tokens[: len(tokens) - len(stripped)]
    return any(t in LEADING_KEYWORDS and t not in ("{", "!") for t in dropped)


def strip_line_comments(command: str) -> str:
    """Remove an unquoted `# ...` through end of line, keeping the newline.
    A `#` starts a comment only at a word start (input start, after
    whitespace or one of `;&|()`), as in a shell; `a#b` is one word.
    Quote-aware so a stray apostrophe or quote inside a comment can never
    desync the tokenizer below: shlex's own `#` handling reads to end of
    line too, but via `readline()`, which consumes the newline itself and
    merges the commented line into the next one."""
    out = []
    quote = None
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote:
            out.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < n:
                i += 1
                out.append(command[i])
            elif ch == quote:
                quote = None
        elif ch in ("'", '"'):
            quote = ch
            out.append(ch)
        elif ch == "\\" and i + 1 < n:
            out.append(ch)
            i += 1
            out.append(command[i])
        elif ch == "#" and (not out or out[-1] in " \t\n;&|()"):
            while i < n and command[i] != "\n":
                i += 1
            continue
        else:
            out.append(ch)
        i += 1
    return "".join(out)


# The delimiter is `'any but quote'`, `"any but quote"`, or an optionally
# escaped run of characters that are not whitespace, `;&|()<>`, a quote, a
# backslash, `$`, a backtick or a bracket: a word with an expansion is left
# unmatched so its lines stay visible. The lookahead keeps `<<EOF"x"` from
# reading as `<<EOF`.
HEREDOC_OP = re.compile(
    r"""<<(-?)[ \t]*(?:'([^']*)'|"([^"]*)"|\\?([^\s;&|()<>'"\\$`{}\[\]]+))(?=[ \t\n;&|()<>]|$)"""
)


class TooComplexError(Exception):
    """Raised when the guard has spent its text budget rescanning lines."""


def charge(budget: list[int], n: int) -> None:
    """Spend n characters of the shared text budget; raise when it is gone."""
    budget[1] -= n
    if budget[1] < 0:
        raise TooComplexError


def heredoc_word(m: re.Match) -> tuple[str, bool]:
    """The (delimiter word, dash) of a HEREDOC_OP match."""
    word = next(g for g in m.group(2, 3, 4) if g is not None)
    return word, m.group(1) == "-"


def skip_heredoc_bodies(command: str, i: int, pending: list[tuple], missing: set) -> int:
    """Index just past the terminator line of each pending (word, dash, ...)
    heredoc. A heredoc with no terminator line is not one: its lines stay, so
    the index where its body would start is returned. missing holds the
    (word, dash) pairs already found to have no terminator line after an
    earlier index, so a later newline does not rescan to the end of text."""
    n = len(command)
    for entry in pending:
        word, dash = entry[0], entry[1]
        if (word, dash) in missing:
            return i
        start = i
        found = False
        while i < n:
            end = command.find("\n", i)
            end = n if end == -1 else end
            line = command[i:end]
            i = min(end + 1, n)
            if (line.lstrip("\t") if dash else line) == word:
                found = True
                break
        if not found:
            missing.add((word, dash))
            return start
    return i


def in_arith_or_cond(text: str) -> bool:
    """True when the last line of text leaves a `((` or `[[` unclosed."""
    line = text.rsplit("\n", 1)[-1]
    return line.count("((") > line.count("))") or line.count("[[") > line.count("]]")


def in_expansion(text: str) -> bool:
    """True when the last line of text leaves a `${` or `$[` open."""
    line = text.rsplit("\n", 1)[-1]
    stack = []
    i, n = 0, len(line)
    while i < n:
        ch = line[i]
        if ch == "$" and line[i + 1 : i + 2] in ("{", "["):
            stack.append("}" if line[i + 1] == "{" else "]")
            i += 1
        elif stack and ch in "{[":
            stack.append("}" if ch == "{" else "]")
        elif stack and ch == stack[-1]:
            stack.pop()
        i += 1
    return bool(stack)


def heredoc_at(command: str, i: int, before: str) -> re.Match | None:
    """The HEREDOC_OP match at i, or None when the `<<` is a here-string, part
    of `<<<`, or sits inside `((`, `[[`, `${` or `$[` on its line. before is
    the text up to i with quoted characters blanked."""
    if command.startswith("<<<", i) or command[i - 1 : i] == "<":
        return None
    if in_arith_or_cond(before) or in_expansion(before):
        return None
    return HEREDOC_OP.match(command, i)


def single_quote_end(command: str, i: int, ansi: bool) -> int:
    """Index of the `'` closing a span whose body starts at i, or len(command).
    With ansi (`$'...'`), a backslash escapes the next character."""
    n = len(command)
    while i < n:
        if ansi and command[i] == "\\":
            i += 2
        elif command[i] == "'":
            return i
        else:
            i += 1
    return n


def ansi_quote_at(command: str, i: int) -> bool:
    """True when the `'` at i opens `$'...'`: an odd run of unescaped `$`
    precedes it (`$$'` is the PID and a plain quote)."""
    run = 0
    while i - run > 0 and command[i - run - 1] == "$":
        run += 1
    slashes = 0
    while i - run - slashes > 0 and command[i - run - slashes - 1] == "\\":
        slashes += 1
    if slashes % 2:
        run -= 1
    return run % 2 == 1


def last_line(chars: list[str], budget: list[int]) -> str:
    """The text after the last newline in chars, charged to the budget."""
    k = len(chars)
    while k and chars[k - 1] != "\n":
        k -= 1
    charge(budget, len(chars) - k)
    return "".join(chars[k:])


def drop_heredocs_and_continuations(command: str, budget: list[int]) -> str:
    """Drop heredoc bodies and unquoted backslash-newline pairs, so a body is
    not read as commands and a continued line stays one command. Quote- and
    comment-aware like strip_line_comments; a backtick span and `$'...'` count
    as quotes."""
    out = []
    bare = []  # out without quoted characters (each is `_`) and comments
    pending = []  # (word, dash, paren level)
    missing = set()
    quote = None
    level = 0
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote:
            out.append(ch)
            bare.append(ch if ch == "\n" else "_")
            if ch == "\\" and quote != "'" and i + 1 < n:
                i += 1
                out.append(command[i])
                bare.append(command[i] if command[i] == "\n" else "_")
            elif ch == quote[-1]:
                quote = None
        elif ch in ("'", '"', "`"):
            quote = "$'" if ch == "'" and ansi_quote_at(command, i) else ch
            out.append(ch)
            bare.append("_")
        elif ch == "\\" and i + 1 < n:
            if command[i + 1] != "\n":
                out.append(ch)
                out.append(command[i + 1])
                bare.extend("__")
            i += 1
        elif ch == "#" and (not out or out[-1] in " \t\n;&|()"):
            while i < n and command[i] != "\n":
                out.append(command[i])
                i += 1
            continue
        elif ch == "\n" and pending:
            out.append(ch)
            bare.append(ch)
            i = skip_heredoc_bodies(command, i + 1, pending, missing)
            pending = []
            continue
        elif ch == "<" and command.startswith("<<", i):
            m = heredoc_at(command, i, last_line(bare, budget))
            if m:
                pending.append((*heredoc_word(m), level))
                out.extend(m.group(0))
                bare.extend(m.group(0))
                i = m.end()
                continue
            out.append(ch)
            bare.append(ch)
        elif ch == "(":
            level += 1
            out.append(ch)
            bare.append(ch)
        elif ch == ")":
            level = max(0, level - 1)
            pending = [p for p in pending if p[2] <= level]
            out.append(ch)
            bare.append(ch)
        else:
            out.append(ch)
            bare.append(ch)
        i += 1
    return "".join(out)


def mask_quotes(command: str) -> str:
    """Replace each quoted span and each backslash-escaped character with `_`,
    so a token pass can tell `"$v"` from `$v`."""
    out = []
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if ch in ("'", '"'):
            j = i + 1
            while j < n and command[j] != ch:
                j += 2 if ch == '"' and command[j] == "\\" else 1
            out.append("_")
            i = j + 1
        elif ch == "\\" and i + 1 < n and command[i + 1] != "\n":
            out.append("_")
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def tokenize(command: str) -> list[str]:
    """Tokenize the whole command in one quote-aware pass: `;`, `&`, `|`,
    `(`, `)` become their own tokens (so `&&`/`||` stay one token each)
    while quoted text -- including a `sh -c '...'` script containing those
    same characters -- stays intact as a single word token. A naive
    per-character regex split on the raw command text (the prior approach)
    would slice through a quoted script the same way it slices real segment
    separators, corrupting the extracted `-c` argument."""
    try:
        lexer = shlex.shlex(
            strip_line_comments(command), posix=True, punctuation_chars=SEGMENT_OPERATORS
        )
        lexer.whitespace_split = True
        # A bare newline separates commands like `;` does (e.g. a heredoc'd
        # multi-line script); punctuation_chars alone does not take effect
        # for it because shlex's default whitespace set consumes it first.
        lexer.whitespace = lexer.whitespace.replace("\n", "")
        # Comments are already stripped above; disabling shlex's own handling
        # avoids its newline-eating readline() path entirely.
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        return command.split()


def split_segments(tokens: list[str]) -> list[list[str]]:
    """Split a token stream on `;`/`&`/`|`/`\\n` operator tokens, dropping
    grouping `(`/`)` tokens so a subshell's contents are treated the same as
    an unparenthesized compound command (BF3: `(cd / && rm -rf *)`).

    shlex's `punctuation_chars` greedily glues any run of adjacent operator
    characters into one token -- not just real shell operators like `&&`, but
    also e.g. `)\\n` or `;\\n` when a paren or `;` sits right before a
    newline. Such a token is still pure punctuation, so it is a segment
    boundary the same as any of its individual characters would be."""
    segments = []
    current = []
    for tok in tokens:
        if tok and all(c in SEGMENT_OPERATORS for c in tok):
            if current:
                segments.append(current)
                current = []
        else:
            current.append(tok)
    if current:
        segments.append(current)
    return segments


def expand_home(tok: str, home: str) -> str:
    m = re.match(r"^\$\{HOME\}(.*)$", tok) or re.match(r"^\$HOME(.*)$", tok)
    if m:
        return home + m.group(1)
    if tok == "~":
        return home
    if tok.startswith("~/"):
        return home + tok[1:]
    return tok


def expand_braces(tok: str) -> list[str]:
    """Expand one level of shell brace-list syntax (`{a,b,c}`), recursing so
    multiple non-nested groups in the same token all expand. Non-list groups
    (no comma, e.g. `{1..3}` ranges) are left literal, matching the common
    case this guard cares about: comma-separated alternatives."""
    m = BRACE_GROUP.match(tok)
    if not m:
        return [tok]
    prefix, body, suffix = m.groups()
    if "," not in body:
        return [tok]
    results = []
    for part in body.split(","):
        results.extend(expand_braces(prefix + part + suffix))
    return results


def canonicalize(path: str) -> str:
    """Lexically resolve macOS's `/tmp` and `/var` symlinks to their real
    `/private/...` location, without touching the filesystem, so a target
    and a SYSTEM_PATHS/SCRATCH_EXCEPTIONS entry compare equal regardless of
    which spelling was used."""
    if path == "/tmp" or path.startswith("/tmp/"):
        return "/private" + path
    if path == "/var" or path.startswith("/var/"):
        return "/private" + path
    return path


def resolve(tok: str, cwd: str) -> str:
    if tok.startswith("/"):
        path = os.path.normpath(tok)
    else:
        path = os.path.normpath(os.path.join(cwd, tok))
    # normpath preserves a leading "//" (POSIX allows it special meaning);
    # bash does not treat "//" specially, so collapse it to match root.
    return re.sub(r"^/{2,}", "/", path)


def has_glob_chars(name: str) -> bool:
    return any(c in name for c in "*?[")


def system_path_reason(path: str) -> str | None:
    canon_path = canonicalize(path)
    for exc in SCRATCH_EXCEPTIONS:
        canon_exc = canonicalize(exc)
        if canon_path == canon_exc or canon_path.startswith(canon_exc + "/"):
            return None
    for sys_path in SYSTEM_PATHS:
        canon_sys = canonicalize(sys_path)
        if canon_path == canon_sys or canon_path.startswith(canon_sys + "/"):
            return (
                "Blocked: rm target is a system path (%s). Fix: remove only "
                "scratch paths under /tmp or $TMPDIR, or ask the user to run "
                "this removal." % sys_path
            )
    return None


def is_git_root(cwd: str) -> bool:
    try:
        return os.path.exists(os.path.join(cwd, ".git"))
    except OSError:
        return False


def denial_reason(path: str, has_unexpanded_var: bool, recursive_or_force: bool,
                   home: str, real_cwd: str, cwd: str) -> str | None:
    if has_unexpanded_var and recursive_or_force:
        return (
            "Blocked: rm -r/-f target holds a shell variable or command "
            "substitution, which this guard cannot check. Fix: write the "
            "literal path (for example paste the mktemp output) or skip the rm."
        )

    parent, name = os.path.split(path) if path != "/" else ("/", "")

    if path == "/" or (parent == "/" and has_glob_chars(name)):
        return (
            "Blocked: rm target is the filesystem root or a glob directly "
            "under it. Fix: name the specific file or subdirectory to "
            "remove, or skip the rm."
        )

    if path == home or (parent == home and has_glob_chars(name)):
        return (
            "Blocked: rm target is the home directory or a glob directly "
            "under it. Fix: name the specific file or subdirectory to "
            "remove, or skip the rm."
        )

    if name == ".git" or (basename(parent) == ".git" and has_glob_chars(name)):
        return (
            "Blocked: rm target is a .git directory or a glob directly under "
            "it. Fix: name the one file inside .git to remove (for example "
            ".git/index.lock), or skip the rm."
        )

    sys_reason = system_path_reason(path)
    if sys_reason:
        return sys_reason

    if real_cwd.startswith(path + "/") and path != real_cwd:
        return (
            "Blocked: rm target is a parent of the current working directory. "
            "Fix: name the specific file or subdirectory inside it, or skip "
            "the rm."
        )

    if path == cwd and (cwd == home or is_git_root(cwd)):
        return (
            "Blocked: rm target is the current directory, which is a git "
            "worktree root or the home directory. Fix: name the specific "
            "files or subdirectories to remove, or skip the rm."
        )

    return None


def rm_flag_is_recursive_or_force(tok: str) -> bool:
    if tok in RECURSIVE_OR_FORCE_LONG:
        return True
    if tok.startswith("-") and not tok.startswith("--"):
        return any(c in "rRf" for c in tok[1:])
    return False


def check_rm(tokens: list[str], cwd: str, home: str, real_cwd: str) -> str | None:
    """Return a denial reason for the `rm`/`rmdir` invocation `tokens`, or
    None."""
    recursive_or_force = any(rm_flag_is_recursive_or_force(t) for t in tokens[1:])
    targets = []
    only_targets = False
    for tok in tokens[1:]:
        if only_targets:
            targets.append(tok)
        elif tok == "--":
            only_targets = True
        elif tok.startswith("-") and tok != "-":
            continue
        else:
            targets.append(tok)

    for raw in targets:
        for candidate in expand_braces(raw):
            expanded = expand_home(candidate, home)
            has_unexpanded_var = "$" in expanded or "`" in expanded
            path = resolve(expanded, cwd)
            reason = denial_reason(path, has_unexpanded_var, recursive_or_force, home, real_cwd, cwd)
            if reason:
                return reason
    return None


def resolve_cd_target(tokens: list[str], cwd: str, home: str) -> str:
    if len(tokens) < 2 or tokens[1] == "-":
        return cwd
    return resolve(expand_home(tokens[1], home), cwd)


def extract_shell_c_arg(tokens: list[str]) -> str | None:
    """If `tokens` is a `sh`/`bash`/`zsh` invocation with a `-c <script>`
    argument, return the script string; else None."""
    i = 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-c":
            return tokens[i + 1] if i + 1 < len(tokens) else None
        if tok.startswith("-"):
            i += 1
            continue
        break
    return None


BACKTICK_ESCAPE = re.compile(r"\\([\\$`])")
SUBSTITUTION_DEPTH = 32
SUBSTITUTION_BUDGET = 4096
SUBSTITUTION_TEXT_BUDGET = 1 << 18
RM_WORD = re.compile(r"(?<![A-Za-z0-9_.\-])(?:rm|rmdir)(?![A-Za-z0-9_.\-])")
UNPAIRED = (
    "Blocked: this guard cannot find where a command substitution ends, and an "
    "rm follows it. Fix: close each $( and backtick, or run the rm as a "
    "separate command."
)
TOO_COMPLEX = (
    "Blocked: command nests more command substitutions than this guard can "
    "check. Fix: split it into separate, simpler commands."
)


def check_command(command: str, real_cwd: str, home: str, cwd: str | None = None) -> str | None:
    if cwd is None:
        cwd = real_cwd
    return check_segments(command, real_cwd, home, cwd, [], []) or check_substitutions(
        command, real_cwd, home, cwd, 0, [SUBSTITUTION_BUDGET, SUBSTITUTION_TEXT_BUDGET]
    )


def check_segments(
    command: str,
    real_cwd: str,
    home: str,
    cwd: str,
    cwds: list[str],
    scripts: list[tuple[str, str]],
) -> str | None:
    """Check each segment of command. Appends every directory a `cd` enters to
    cwds and every `sh -c` script, with its directory, to scripts."""
    for tokens in split_segments(tokenize(command)):
        raw = tokens
        tokens = strip_prefixes(raw)
        if not tokens:
            continue
        head = basename(tokens[0])
        if head in REMOVE_COMMANDS:
            reason = check_rm(tokens, cwd, home, real_cwd)
            if reason:
                return reason
        elif head == "cd":
            if not skipped_keyword(raw, tokens):
                cwd = resolve_cd_target(tokens, cwd, home)
                cwds.append(cwd)
        elif head in SHELL_WRAPPERS:
            inner = extract_shell_c_arg(tokens)
            if inner is not None:
                scripts.append((inner, cwd))
                reason = check_segments(inner, real_cwd, home, cwd, [], [])
                if reason:
                    return reason
    return None


def check_substitutions(
    command: str, real_cwd: str, home: str, cwd: str, depth: int, budget: list[int]
) -> str | None:
    """Check the rm inside each backtick and double-quoted `$(...)` body, and
    any top-level rm a backtick comment hid from the raw walk. Denies when the
    depth, check count or re-read text limit is reached instead of failing
    open. Denies when a span cannot be paired and an rm word follows it."""
    budget[0] -= 1
    if depth:
        budget[1] -= len(command)
    if depth > SUBSTITUTION_DEPTH or budget[0] < 0 or budget[1] < 0:
        return TOO_COMPLEX
    try:
        _, collapsed, ticks, quoted, unpaired = collapse_quoted_substitutions(
            drop_heredocs_and_continuations(command, budget), budget
        )
    except TooComplexError:
        return TOO_COMPLEX
    cwds, scripts = [cwd], []
    reason = check_segments(collapsed, real_cwd, home, cwd, cwds, scripts)
    if reason:
        return reason
    for text, text_cwd in scripts:
        reason = check_substitutions(text, real_cwd, home, text_cwd, depth + 1, budget)
        if reason:
            return reason
    dirs = list(dict.fromkeys(cwds))
    for body in [BACKTICK_ESCAPE.sub(r"\1", tick) for tick in ticks] + quoted:
        for body_cwd in dirs:
            reason = check_substitutions(body, real_cwd, home, body_cwd, depth + 1, budget)
            if reason:
                return reason
    return UNPAIRED if RM_WORD.search(unpaired) else None


def strip_keywords(tokens: list[str]) -> list[str]:
    i = 0
    while i < len(tokens) and tokens[i] in LEADING_KEYWORDS:
        i += 1
    return tokens[i:]


def unquoted_text(command: str) -> str:
    """The command with single-quoted spans and backslash-escaped characters
    removed, so a `$name:x` scan sees only text zsh would expand."""
    out = []
    quote = None
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote == "'":
            if ch == "'":
                quote = None
        elif ch == "\\" and i + 1 < n:
            i += 1
        elif ch == "'" and quote is None:
            quote = "'"
        else:
            if ch == '"':
                quote = None if quote == '"' else '"'
            out.append(ch)
        i += 1
    return "".join(out)

WARN_KILL = (
    "[WARNING] rm_guard: zsh does not word-split $%s, so kill gets every PID in "
    "it as one argument, refuses it, and the processes keep running; write "
    "kill ${=%s}, or collect the PIDs in an array (%s+=($!)) and write "
    'kill "${%s[@]}".'
)


WARN_UNSPLIT = (
    "[WARNING] rm_guard: zsh does not word-split an unquoted $%s, so it reaches "
    "the command as one word and a for loop over it runs once; write \"$%s\" if "
    "one word is meant, or split it with an array (%s=(a b), then "
    '"${%s[@]}"), ${=%s}, literal words, or a bash heredoc.'
)

# One word behaves the same as several for these, or the argument is a name
# or an assignment, never a word list.
UNSPLIT_HARMLESS = (
    "echo", "print", "[", "[[", "test", "case", "kill", "for",
    "eval", "export", "local", "typeset", "declare", "readonly",
)
DECLARATIONS = ("export", "local", "typeset", "declare", "readonly")
REDIRECT_OP = re.compile(r"\d*[<>]+")


def substitution_end(command: str, i: int, budget: list[int]) -> int:
    """Index just past the `)` closing a `$(` whose body starts at i, or -1.
    Reads the body as shell: `#` comments, heredoc bodies, `'...'`, `$'...'`,
    backtick spans and nested double-quoted spans hide their `)`. Iterative."""
    n, start = len(command), i
    stack = [1]  # an int counts open parentheses; `"` is a double-quoted span
    nest = 1
    pending = []  # (word, dash, nest)
    missing = set()
    while i < n:
        ch = command[i]
        if stack[-1] == '"':
            if ch == "\\":
                i += 2
                continue
            if ch == "`":
                end = backtick_end(command, i + 1)
                if end == -1:
                    return -1
                i = end + 1
                continue
            if command.startswith("$(", i) and not command.startswith("$((", i):
                stack.append(1)
                nest += 1
                i += 2
                continue
            if ch == '"':
                stack.pop()
                nest -= 1
            i += 1
            continue
        if ch == "\\":
            i += 2
        elif ch == "`":
            end = backtick_end(command, i + 1)
            if end == -1:
                return -1
            i = end + 1
        elif ch == "'" and ansi_quote_at(command, i):
            i = single_quote_end(command, i + 1, True) + 1
        elif ch == "'":
            i = single_quote_end(command, i + 1, False) + 1
        elif ch == '"':
            stack.append('"')
            nest += 1
            i += 1
        elif ch == "#" and (i == start or command[i - 1] in " \t\n;&|()"):
            while i < n and command[i] != "\n":
                i += 1
        elif ch == "\n" and pending:
            i = skip_heredoc_bodies(command, i + 1, pending, missing)
            pending = []
        elif ch == "<" and command.startswith("<<", i):
            line_start = max(command.rfind("\n", 0, i) + 1, start)
            charge(budget, i - line_start)
            m = heredoc_at(command, i, mask_quotes(command[line_start:i]))
            if m:
                pending.append((*heredoc_word(m), nest))
                i = m.end()
            else:
                i += 1
        elif ch == "(":
            stack[-1] += 1
            nest += 1
            i += 1
        elif ch == ")":
            stack[-1] -= 1
            nest -= 1
            pending = [p for p in pending if p[2] <= nest]
            if stack[-1] == 0:
                stack.pop()
                if not stack:
                    return i + 1
            i += 1
        else:
            i += 1
    return -1


def backtick_end(command: str, i: int) -> int:
    """Index of the backtick closing a span whose body starts at i, or -1.
    A backslash escapes the one character after it."""
    n = len(command)
    while i < n:
        if command[i] == "\\":
            i += 2
        elif command[i] == "`":
            return i
        else:
            i += 1
    return -1


def collapse_quoted_substitutions(
    command: str, budget: list[int] | None = None
) -> tuple[str, str, list[str], list[str], str]:
    """Drop `#` comments and collapse backtick spans in one quote-aware walk.
    Returns (plain, collapsed, bodies, quoted, unpaired). plain has each
    backtick span replaced by `_` between backticks; collapsed also replaces
    each `$(...)` inside double quotes with `$(_)` and each `$'...'` with
    `$'_'`, so a quote or space inside it neither pairs with the quote around
    it nor splits the token. bodies lists the backtick span bodies in text
    order; quoted lists the collapsed `$(...)` bodies; unpaired is the text
    from a backtick or `$(` the walk could not pair (it stops there), or ""."""
    if budget is None:
        budget = [0, SUBSTITUTION_TEXT_BUDGET]
    plain, collapsed, bodies, quoted = [], [], [], []
    unpaired = ""
    last = ""
    quote = None
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        if quote == "'":
            quote = None if ch == "'" else quote
        elif ch == "\\" and i + 1 < n:
            plain.append(command[i : i + 2])
            collapsed.append(command[i : i + 2])
            last = command[i + 1]
            i += 2
            continue
        elif ch == "#" and quote is None and (not last or last in " \t\n;&|()"):
            while i < n and command[i] != "\n":
                i += 1
            continue
        elif ch == "`":
            end = backtick_end(command, i + 1)
            if end == -1:
                plain.append(command[i:])
                collapsed.append(command[i:])
                unpaired = command[i:]
                break
            bodies.append(command[i + 1 : end])
            plain.append("`_`")
            collapsed.append("`_`")
            last = "`"
            i = end + 1
            continue
        elif quote == '"' and command.startswith("$(", i) and not command.startswith("$((", i):
            end = substitution_end(command, i + 2, budget)
            if end == -1:
                plain.append(command[i:])
                collapsed.append(command[i:])
                unpaired = command[i:]
                break
            quoted.append(command[i + 2 : end - 1])
            plain.append(command[i:end])
            collapsed.append("$(_)")
            last = ")"
            i = end
            continue
        elif ch == "'" and quote is None and ansi_quote_at(command, i):
            end = single_quote_end(command, i + 1, True)
            if end >= n:
                plain.append(command[i:])
                collapsed.append(command[i:])
                unpaired = command[i:]
                break
            plain.append(command[i : end + 1])
            collapsed.append("'_'")
            last = "'"
            i = end + 1
            continue
        elif ch in ("'", '"'):
            quote = None if quote == ch else (quote or ch)
        plain.append(ch)
        collapsed.append(ch)
        last = ch
        i += 1
    return "".join(plain), "".join(collapsed), bodies, quoted, unpaired


def outside_substitutions(value: str) -> str:
    """The value without `$(...)` (nesting counted) and backtick spans."""
    out = []
    depth = 0
    tick = False
    i, n = 0, len(value)
    while i < n:
        ch = value[i]
        if ch == "`":
            tick = not tick
        elif depth == 0 and not tick and value.startswith("$(", i):
            depth = 1
            i += 1
        elif depth and ch == "(":
            depth += 1
        elif depth and ch == ")":
            depth -= 1
        elif depth == 0 and not tick:
            out.append(ch)
        i += 1
    return "".join(out)


def word_indexes(tokens: list[str]) -> list[int]:
    """Indexes of the tokens that are not a redirection or the operand of one
    whose operator is a token of its own."""
    indexes = []
    i = 0
    while i < len(tokens):
        m = REDIRECT_OP.match(tokens[i])
        if not m:
            indexes.append(i)
            i += 1
        else:
            i += 2 if m.end() == len(tokens[i]) else 1
    return indexes


def assignment_indexes(tokens: list[str]) -> list[int]:
    """Indexes of the tokens that assign a name: every word of a segment that
    has no command word (redirections anywhere are ignored), or the operands
    of a declaration command."""
    if tokens[:1] and tokens[0] in DECLARATIONS:
        return [i for i, tok in enumerate(tokens) if i and SCALAR_ASSIGNMENT.match(tok)]
    words = word_indexes(tokens)
    if words and all(SCALAR_ASSIGNMENT.match(tokens[i]) for i in words):
        return words
    return []


def apply_assignments(frame: dict, tokens: list[str], follower: str, maybe: bool = False) -> None:
    """Update frame (name -> (unsplit, multiword)) from the segment's assignments.
    follower is the operator token after the segment, where the tokenizer puts
    the `(` of an unquoted `NAME=$(cmd)`. maybe is true when the assignment may
    not run, so its flags merge into the old ones."""
    for i in assignment_indexes(tokens):
        m = SCALAR_ASSIGNMENT.match(tokens[i])
        name, value = m.group(1), m.group(2)
        outside = outside_substitutions(value)
        split_subst = (
            i == len(tokens) - 1
            and value.endswith("$")
            and follower.startswith("(")
            and not follower.startswith("((")
        )
        unsplit = bool(
            re.search(r"[ \t\n]", outside) or "`" in value or re.search(r"\$\((?!\()", value) or split_subst
        )
        multiword = bool(re.search(r"[ \t\n]", outside))
        source = var_name(value)
        if source in frame:
            unsplit, multiword = frame[source]
        if maybe or tokens[i][len(name)] == "+":
            old = frame.get(name, (False, False))
            unsplit, multiword = unsplit or old[0], multiword or old[1]
        frame[name] = (unsplit, multiword)


def stated_segments(all_tokens: list[str], masked_tokens: list[str]) -> list[tuple[list[str], dict]]:
    """(segment, state) pairs in command order. State maps a name to its
    (unsplit, multiword) flags as they stand before the segment; each `(`
    opens a copy of the state and each `)` closes it. A quoted parenthesis
    is a `_` in masked_tokens and changes nothing."""
    if len(masked_tokens) != len(all_tokens):
        masked_tokens = all_tokens
    frames = [{}]
    depth, previous = 0, ""
    pairs, current = [], []
    for tok, masked in zip(all_tokens + [None], masked_tokens + [None]):
        is_operator = tok is None or (tok and all(c in SEGMENT_OPERATORS for c in tok))
        if not is_operator:
            current.append(tok)
            continue
        if current:
            tokens = strip_keywords(current)
            dropped = current[: len(current) - len(tokens)]
            if tokens[:1] in (["fi"], ["done"], ["esac"]):
                depth = max(depth - 1, 0)
            elif tokens[:1] in (["for"], ["case"]) or {"if", "while", "until"} & set(dropped):
                depth += 1
            maybe = depth > 0 or "&&" in previous or "||" in previous
            pairs.append((tokens, dict(frames[-1])))
            apply_assignments(frames[-1], tokens, tok or "", maybe)
            current = []
        previous = tok or ""
        for ch in masked or "":
            if ch == "(":
                frames.append(dict(frames[-1]))
            elif ch == ")" and len(frames) > 1:
                frames.pop()
    return pairs


def flag(state: dict, name: str | None, which: int) -> bool:
    """which: 0 for unsplit, 1 for multiword."""
    return state.get(name, (False, False))[which]


def var_name(tok: str) -> str | None:
    m = VAR_REF.match(tok)
    return (m.group(1) or m.group(2)) if m else None


def masked_segments(all_tokens: list[str], masked_tokens: list[str]) -> list[list[str]]:
    """Segments of the quote-masked tokens, cut where the POSIX token is an operator."""
    segments, current = [], []
    for tok, masked in zip(all_tokens, masked_tokens):
        if tok and all(c in SEGMENT_OPERATORS for c in tok):
            if current:
                segments.append(current)
                current = []
        else:
            current.append(masked)
    if current:
        segments.append(current)
    return segments


def unsplit_lines(segments, masked, states, reported) -> list[str]:
    """WARN_UNSPLIT lines for unquoted multi-word scalars in a `for` list or
    in the arguments of a command. A redirect operand takes one word."""
    lines = []
    for tokens, mtokens, state in zip(segments, masked, states):
        if tokens[:1] == ["for"] and tokens[2:3] == ["in"]:
            words, which = mtokens[3:], 0
        else:
            stripped = strip_prefixes(tokens)
            if not stripped or basename(stripped[0]) in UNSPLIT_HARMLESS:
                continue
            words, which = mtokens[len(tokens) - len(stripped) + 1:], 1
        previous = ""
        for word in words:
            name = var_name(word)
            after_redirect = REDIRECT_OP.fullmatch(previous)
            if flag(state, name, which) and name not in reported and not after_redirect:
                lines.append(WARN_UNSPLIT % ((name,) * 5))
            previous = word
    return lines


def shlex_accepts(command: str) -> bool:
    """False when shlex rejects the command (unmatched quote, trailing escape)."""
    try:
        shlex.split(strip_line_comments(command), comments=False)
    except ValueError:
        return False
    return True


def zsh_warnings(command: str) -> list[str]:
    """Warning lines for zsh pitfalls visible in the command text. Advisory
    only: the caller never blocks on them."""
    budget = [0, SUBSTITUTION_TEXT_BUDGET]
    try:
        plain, collapsed, bodies, _, _ = collapse_quoted_substitutions(
            drop_heredocs_and_continuations(command, budget), budget
        )
    except TooComplexError:
        return []
    all_tokens = tokenize(collapsed)
    masked_tokens = tokenize(mask_quotes(collapsed))
    pairs = stated_segments(all_tokens, masked_tokens)
    segments = [tokens for tokens, _ in pairs]
    states = [state for _, state in pairs]

    reported = set()
    prefix_lines, path_lines, kill_lines = [], [], []
    for tokens, state in pairs:
        stripped = strip_prefixes(tokens)
        if stripped:
            name = var_name(stripped[0])
            if flag(state, name, 1):
                prefix_lines.append(WARN_PREFIX % name)
                reported.add(name)
        if stripped and basename(stripped[0]) == "kill":
            for arg in stripped[1:]:
                name = var_name(arg)
                if flag(state, name, 0):
                    kill_lines.append(WARN_KILL % (name, name, name, name))
                    reported.add(name)
        loop_path = len(tokens) > 1 and tokens[0] == "for" and tokens[1] == "path"
        read_path = len(stripped) > 1 and stripped[0] == "read" and "path" in stripped[1:]
        if loop_path or read_path:
            path_lines.append(WARN_PATH)

    unsplit_out = []
    if shlex_accepts(plain) and len(masked_tokens) == len(all_tokens):
        masked = [strip_keywords(seg) for seg in masked_segments(all_tokens, masked_tokens)]
        unsplit_out = unsplit_lines(segments, masked, states, reported)

    modifier_lines = [
        WARN_MODIFIER % (name, letter, letter, name, name, letter)
        for name, letter in MODIFIER.findall(unquoted_text(plain))
    ]

    body_lines = [line for body in bodies for line in zsh_warnings(body)]
    lines = []
    for line in prefix_lines + modifier_lines + path_lines + kill_lines + unsplit_out + body_lines:
        if line not in lines:
            lines.append(line)
    return lines


def main():
    try:
        data = json.load(sys.stdin)
        tool_name = data.get("tool_name") or data.get("toolName") or ""
        if not isinstance(tool_name, str) or tool_name.lower() not in SHELL_TOOLS:
            sys.exit(0)

        tool_input = data.get("tool_input") or data.get("toolInput") or {}
        if not isinstance(tool_input, dict):
            sys.exit(0)
        nested = tool_input.get("args")
        inputs = [tool_input] + ([nested] if isinstance(nested, dict) else [])
        command = next(
            (
                value
                for item in inputs
                for key in ("command", "cmd")
                if isinstance(value := item.get(key), str)
            ),
            "",
        )
        if not isinstance(command, str):
            sys.exit(0)

        payload_cwd = data.get("cwd")
        real_cwd = (
            payload_cwd
            if isinstance(payload_cwd, str) and payload_cwd
            else os.getcwd()
        )
        tool_workdir = next(
            (
                value
                for item in inputs
                for key in ("workdir", "cwd")
                if isinstance(value := item.get(key), str) and value
            ),
            None,
        )
        if tool_workdir is not None:
            real_cwd = resolve(tool_workdir, real_cwd)
        home = os.environ.get("HOME", os.path.expanduser("~"))

        reason = check_command(command, real_cwd, home) if "rm" in command else None
        if reason:
            print(reason, file=sys.stderr)
            sys.exit(2)

        warnings = zsh_warnings(command)
        if warnings:
            print(json.dumps({"hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": "\n".join(warnings),
            }}))
        sys.exit(0)
    except Exception:
        # Fail open: a crashed guard must never block work.
        sys.exit(0)


if __name__ == "__main__":
    main()
