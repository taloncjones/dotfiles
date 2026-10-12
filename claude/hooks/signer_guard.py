#!/usr/bin/env python3
"""PreToolUse guard: refuse a git command that would hang on a locked 1Password.

While 1Password is locked, every signed commit and every SSH push waits about
60 s on its unlock prompt and then fails. This guard denies such a command at
once (exit 2) with the remedy, instead of letting an unattended session sit
on the prompt and retry.

Rule: for a git segment that signs (commit, merge, rebase, cherry-pick,
revert, am, pull; `--ff-only` merge/pull never commit and are exempt) or
pushes, and only when 1Password's own log says the last lock state is
`Locked`:
- a signing segment is denied when the effective repo config signs with
  `op-ssh-sign` (gpg.format ssh, commit.gpgsign true). The command's own
  `-c` and `--no-gpg-sign` are ignored, so they cannot dodge the refusal;
- a push is denied when any destination URL is SSH. Every SSH host on a
  managed machine uses the 1Password agent, so `ssh -G` is not consulted.

Lock state is read from files only (the app log); the guard never runs ssh,
ssh-add, ssh-keygen, op or the signing program, so it cannot raise a prompt.
Its only subprocesses are git config / remote get-url / symbolic-ref, and
only on the locked path, under one 10 s budget (5 s per call).

Override: prefix the segment with DOTFILES_ALLOW_LOCKED_SIGNER=1, after the
user confirms. An exported variable has no effect.

Accepted holes: wrappers, scripts, aliases and `sh -c` bodies, `git tag -s`,
SSH fetch, GIT_SSH_COMMAND/core.sshCommand, a `cd` earlier in the command
(judged by the payload cwd), the unlocked-but-unapproved session case (no log
signal), and commits made outside a Claude or Codex session. Fails open on a
malformed payload, an unknown lock state, a git timeout or any exception.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import git_remote_guard as grg
import planning_artifact_guard as pag
import rm_guard

OVERRIDE = "DOTFILES_ALLOW_LOCKED_SIGNER=1"
LOG_DIR = (
    "Library/Group Containers/2BUA8C4S2C.com.1password/"
    "Library/Application Support/1Password/Data/logs"
)
MAX_ROTATED = 3
LOCK_LINE = re.compile(r"Lock state changed: (Locked|Unlocked)$")
ROTATED = re.compile(r"^1Password_r(\d+)\.log$")

SIGNING_SUBCOMMANDS = ("commit", "merge", "rebase", "cherry-pick", "revert", "am", "pull")
FF_ONLY_EXEMPT = ("merge", "pull")
PUSH_OPTS_WITH_ARG = ("-o", "--push-option", "--repo", "--receive-pack", "--exec")
SSH_SCHEMES = ("ssh://", "git+ssh://", "ssh+git://")
TRUE_VALUES = ("true", "yes", "on", "1", "")

SIGN_KEYS = r"^(gpg\.format|gpg\.ssh\.program|commit\.gpgsign)$"
REMOTE_KEYS = r"^(remote\.pushdefault|branch\..*\.(pushremote|remote))$"


def lock_state(home):
    """'Locked', 'Unlocked' or None, from the last complete lock line in the
    newest readable 1Password log that holds one."""
    log_dir = Path(home) / LOG_DIR
    try:
        names = os.listdir(log_dir)
    except OSError:
        return None
    rotated = sorted(
        (n for n in names if ROTATED.match(n)),
        key=lambda n: int(ROTATED.match(n).group(1)),
        reverse=True,
    )
    for name in ["1Password_rCURRENT.log"] + rotated[:MAX_ROTATED]:
        try:
            data = (log_dir / name).read_bytes()
        except OSError:
            continue
        # Dropping the last split element ignores an unterminated tail line.
        for raw in reversed(data.split(b"\n")[:-1]):
            m = LOCK_LINE.search(raw.decode("utf-8", "replace").rstrip("\r"))
            if m:
                return m.group(1)
    return None


def config_values(d, pattern, budget):
    """{key: last value} for config keys matching `pattern`, or None when git
    fails (timeout, not a repository)."""
    rc, out = pag.git(["config", "--get-regexp", pattern], d, budget)
    if rc is None or rc not in (0, 1):
        return None
    values = {}
    for line in out.decode("utf-8", "replace").splitlines():
        key, _, value = line.partition(" ")
        values[key] = value
    return values


def signs_with_1password(d, budget):
    cfg = config_values(d, SIGN_KEYS, budget)
    if cfg is None:
        return False
    program = cfg.get("gpg.ssh.program", "")
    return (
        cfg.get("gpg.format", "").lower() == "ssh"
        and rm_guard.basename(program) == "op-ssh-sign"
        and cfg.get("commit.gpgsign", "false").lower() in TRUE_VALUES
    )


def is_ssh_url(url):
    if url.startswith(SSH_SCHEMES):
        return True
    if "://" in url or ":" not in url:
        return False
    return "/" not in url.split(":", 1)[0]


def push_remote_arg(args):
    """The remote or URL a push names, or None when it names none."""
    i = 0
    while i < len(args):
        tok = args[i]
        if tok.startswith("--repo="):
            return tok.split("=", 1)[1]
        if tok in PUSH_OPTS_WITH_ARG:
            if tok == "--repo" and i + 1 < len(args):
                return args[i + 1]
            i += 2
            continue
        if tok == "--":
            return args[i + 1] if i + 1 < len(args) else None
        if not tok.startswith("-"):
            return tok
        i += 1
    return None


def default_remote(d, budget):
    """git's push remote when none is named, or None when it cannot be told."""
    rc, out = pag.git(["symbolic-ref", "--short", "-q", "HEAD"], d, budget)
    branch = out.decode("utf-8", "replace").strip() if rc == 0 else ""
    cfg = config_values(d, REMOTE_KEYS, budget)
    if cfg is None:
        return None
    keys = ["remote.pushdefault"]
    if branch:
        keys = ["branch.%s.pushremote" % branch] + keys + ["branch.%s.remote" % branch]
    for key in keys:
        # Section and variable names fold to lower case, the branch does not.
        hit = next((v for k, v in cfg.items() if k.lower() == key.lower()), None)
        if hit:
            return hit
    return "origin"


def push_needs_1password(d, args, budget):
    remote = push_remote_arg(args)
    if remote is None:
        remote = default_remote(d, budget)
        if remote is None:
            return False
    if ":" in remote or "/" in remote:
        return is_ssh_url(remote)
    rc, out = pag.git(["remote", "get-url", "--push", "--all", remote], d, budget)
    if rc != 0:
        return False
    return any(is_ssh_url(u) for u in out.decode("utf-8", "replace").splitlines())


def target_segments(command):
    """(kind, sub, args, cdirs) for each git segment that signs or pushes and
    carries no leading override."""
    found = []
    for raw in rm_guard.split_segments(rm_guard.tokenize(command)):
        stripped = rm_guard.strip_prefixes(raw)
        if not stripped or rm_guard.basename(stripped[0]) != "git":
            continue
        if OVERRIDE in raw[: len(raw) - len(stripped)]:
            continue
        sub, args, cdirs, hints, unknown = grg.parse_git(stripped)
        if unknown or hints:
            continue
        if sub == "push":
            found.append(("push", sub, args, cdirs))
        elif sub in SIGNING_SUBCOMMANDS:
            if sub in FF_ONLY_EXEMPT and "--ff-only" in args:
                continue
            found.append(("sign", sub, args, cdirs))
    return found


def refusal(sub):
    return [
        "Blocked: 1Password is locked, so `git %s` would wait about 60 s on its "
        "unlock prompt and then fail. Ask the user to unlock 1Password, then "
        "re-run; staged changes stay staged." % sub,
        "Never bypass signing (-c commit.gpgsign=false, --no-gpg-sign). A herdr "
        "worker stops here: emit-done --outcome paused --reason blocked_on_human.",
        "Only after the user confirms, prefix the segment with %s." % OVERRIDE,
    ]


def decide(data):
    """The refused subcommand name, or None to allow."""
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
    if "git" not in command:
        return None
    segments = target_segments(command)
    if not segments:
        return None
    home = os.environ.get("HOME", os.path.expanduser("~"))
    if lock_state(home) != "Locked":
        return None
    payload_cwd = data.get("cwd")
    cwd = payload_cwd if isinstance(payload_cwd, str) and payload_cwd else os.getcwd()
    tool_cwd = next(
        (v for item in inputs for k in ("workdir", "cwd") if isinstance(v := item.get(k), str) and v),
        None,
    )
    if tool_cwd is not None:
        cwd = grg.resolve_filesystem(tool_cwd, cwd, home)
    budget = pag.Budget(pag.GIT_BUDGET_SECS)
    for kind, sub, args, cdirs in segments:
        dirs, _ = grg.effective_dirs(cdirs, {cwd}, home)
        for d in dirs or ():
            if kind == "sign" and signs_with_1password(d, budget):
                return sub
            if kind == "push" and push_needs_1password(d, args, budget):
                return sub
    return None


def main():
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(data, dict):
        return 0
    sub = decide(data)
    if not sub:
        return 0
    for line in refusal(sub):
        print(line, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
