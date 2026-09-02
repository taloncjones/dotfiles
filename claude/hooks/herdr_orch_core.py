#!/usr/bin/env python3
"""Deterministic core for herdr-orchestration: identity/naming, path-safety,
validators, state I/O, event fold, completion/dispatch decisions, and
single-writer ownership. Imported by the hook and driven as a CLI by the skill.
Stdlib only; fails safe. The CLI is the only fenced state-mutation surface.
"""

import hashlib
import json
import math
import os
import re
import secrets
import signal
import socket
import stat
import subprocess
import sys
import time
from pathlib import Path

WORKSPACE_ID_RE = re.compile(r"[A-Za-z0-9]+\Z")
AGENT_NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}\Z")
REPO_SLUG_RE = re.compile(r"[a-z0-9][a-z0-9-]*\Z")
TASK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*\Z")

CAP_MODELS = ("fable", "opus", "sonnet", "haiku")

ROLE_DEFAULTS = {
    "plan": ("fable", "opus"),
    "impl": ("sonnet", "opus"),
    "review": ("opus", "sonnet"),
    "mech": ("haiku", "sonnet"),
}

# Aliases a role's config override may name. haiku is mech-only: the cheap
# tier is human-designated per task, never a silent option for design,
# implementation, or review.
ROLE_ALIASES = {
    "plan": ("fable", "opus", "sonnet"),
    "impl": ("fable", "opus", "sonnet"),
    "review": ("fable", "opus", "sonnet"),
    "mech": CAP_MODELS,
}

# A 429 whose message names usage/credit exhaustion is reliable "this model is
# not launchable" data (the account is out of credits); a bare 429 is an
# ambiguous transient rate limit. Matched against the probe's result/error text.
# "usage limit" deliberately matches the subscription-window rate limit
# ("Usage limit reached") too, not just spend-balance exhaustion -- both mean
# "do not wait on a human, fall back to the next model now."
_USAGE_EXHAUSTION_RE = re.compile(
    r"usage limit|usage credits|"
    r"insufficient credits?|out of credits?|credit balance",
    re.IGNORECASE,
)


def valid_capabilities(rec, session_id) -> bool:
    if not isinstance(rec, dict):
        return False
    v = rec.get("v")
    if not isinstance(v, int) or isinstance(v, bool) or v != 1:
        return False
    if rec.get("session_id") != session_id:
        return False
    avail = rec.get("available")
    if not isinstance(avail, dict) or set(avail.keys()) != set(CAP_MODELS):
        return False
    return all(isinstance(avail[k], bool) for k in CAP_MODELS)


CONTRACT_MAX_COMMANDS = 32
CONTRACT_MAX_TIMEOUT = 3600
CONTRACT_DEFAULT_TIMEOUT = 600


def _nonempty_str(v) -> bool:
    return isinstance(v, str) and bool(v.strip())


def validate_contract(rec, task_id):
    """Error message for an invalid contract, None when valid. Fail closed:
    unknown keys, bool-typed ints, blank strings, dup names all reject."""
    if not isinstance(rec, dict):
        return "contract must be a JSON object"
    if set(rec.keys()) != {"v", "task_id", "commands"}:
        return "contract keys must be exactly v, task_id, commands"
    v = rec.get("v")
    if not isinstance(v, int) or isinstance(v, bool) or v != 1:
        return "v must be the integer 1"
    if rec.get("task_id") != task_id:
        return "contract task_id does not match the task"
    cmds = rec.get("commands")
    if not isinstance(cmds, list) or not cmds:
        return "commands must be a non-empty list"
    if len(cmds) > CONTRACT_MAX_COMMANDS:
        return f"commands exceeds max {CONTRACT_MAX_COMMANDS}"
    names = set()
    for cmd in cmds:
        if not isinstance(cmd, dict):
            return "each command must be an object"
        if not set(cmd.keys()) <= {"name", "run", "timeout_secs"}:
            return "command keys must be within name, run, timeout_secs"
        if not _nonempty_str(cmd.get("name")) or not _nonempty_str(cmd.get("run")):
            return "command name and run must be non-empty strings"
        if cmd["name"] in names:
            return f"duplicate command name: {cmd['name']}"
        names.add(cmd["name"])
        t = cmd.get("timeout_secs", CONTRACT_DEFAULT_TIMEOUT)
        if not isinstance(t, int) or isinstance(t, bool) or not (
            1 <= t <= CONTRACT_MAX_TIMEOUT
        ):
            return f"timeout_secs must be an int in [1, {CONTRACT_MAX_TIMEOUT}]"
    return None


def contract_sha256(path) -> str:
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def run_contract_commands(commands, worktree) -> int:
    """Run each contract command via sh -c in the worktree, streaming output.
    Own process group per command; on timeout the whole group is SIGKILLed
    (best-effort -- a double-forked daemon can escape). First failure stops
    the run. Returns 0 iff every command exited 0."""
    for cmd in commands:
        t = cmd.get("timeout_secs", CONTRACT_DEFAULT_TIMEOUT)
        proc = subprocess.Popen(
            ["sh", "-c", cmd["run"]], cwd=worktree, start_new_session=True
        )
        try:
            rc = proc.wait(timeout=t)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
            print(f"FAIL {cmd['name']} exit=timeout", flush=True)
            return 1
        if rc != 0:
            print(f"FAIL {cmd['name']} exit={rc}", flush=True)
            return 1
        print(f"ok {cmd['name']} exit=0", flush=True)
    print(f"PASS {len(commands)} commands", flush=True)
    return 0


def role_preference(role, config):
    """Ordered alias preference for a role, or None (-> exit 5) if the role is
    unknown or the config 'models' block is malformed: not a dict, a key outside
    the canonical roles, an override that is not a list, an empty override, or a
    token outside CAP_MODELS. Fail closed on any malformed override so a config
    mistake surfaces rather than silently reverting to defaults. Duplicates
    dropped, first order kept."""
    models = (config or {}).get("models")
    if models is not None:
        if not isinstance(models, dict):
            return None
        # A key outside the canonical roles (typo, or a legacy
        # orchestrator/reviewer key) makes the whole block malformed -> exit 5,
        # matching references/state-layout.md.
        if any(k not in ROLE_DEFAULTS for k in models):
            return None
        override = models.get(role)
        if override is not None:
            # An empty override is a config error, not "no model available"
            # (which would mislabel it as an availability failure, exit 4).
            if not isinstance(override, list) or not override:
                return None
            allowed = ROLE_ALIASES[role]
            seen = []
            for m in override:
                if m not in allowed:
                    return None
                if m not in seen:
                    seen.append(m)
            return tuple(seen)
    return ROLE_DEFAULTS.get(role)


def resolve_model(role, available, config):
    """(model, None) on success; (None, code) on failure.
    3 = capabilities absent/stale; 4 = zero survivors; 5 = invalid role/config."""
    prefs = role_preference(role, config)
    if prefs is None:
        return (None, 5)
    if available is None:
        return (None, 3)
    survivors = [m for m in prefs if available.get(m) is True]
    if not survivors:
        return (None, 4)
    return (survivors[0], None)


MECH_DEFAULTS = {"max_turns": 40, "max_budget_usd": 2.0, "timeout_secs": 1800}
MECH_BOUNDS = {"max_turns": (1, 500), "max_budget_usd": (0, 50), "timeout_secs": (60, 14400)}
MECH_KEYS = frozenset(MECH_DEFAULTS) | {"contract_commands"}

MECH_REASONS = ("max_turns", "max_budget", "timeout", "no_emit", "error",
                "needs_design", "blocked_on_human", "other")


def _cap_error(key, value):
    """Error message when a cap value is out of bounds or mistyped, else None."""
    lo, hi = MECH_BOUNDS[key]
    if isinstance(value, bool):
        return f"{key} must be a number, not a boolean"
    if key == "max_budget_usd":
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            return f"{key} must be a finite number"
        if not (lo < value <= hi):
            return f"{key} must be > {lo} and <= {hi}"
        return None
    if not isinstance(value, int) or not (lo <= value <= hi):
        return f"{key} must be an int in [{lo}, {hi}]"
    return None


def mech_caps(config, max_turns=None, max_budget_usd=None):
    """Effective mech caps: defaults <- config.mech <- per-launch overrides.
    (caps, None) or (None, message). Fail closed on any malformed value or
    unknown key, matching the `models` rule -- never silently default."""
    block = (config or {}).get("mech")
    caps = dict(MECH_DEFAULTS)
    if block is not None:
        if not isinstance(block, dict):
            return None, "mech must be a JSON object"
        unknown = set(block) - MECH_KEYS
        if unknown:
            return None, f"mech has unknown keys: {sorted(unknown)}"
        for k in MECH_BOUNDS:
            if k in block:
                caps[k] = block[k]
        if "contract_commands" in block:
            err = validate_contract(
                {"v": 1, "task_id": "x", "commands": block["contract_commands"]}, "x"
            )
            if err:
                return None, f"mech.contract_commands: {err}"
    if max_turns is not None:
        caps["max_turns"] = max_turns
    if max_budget_usd is not None:
        caps["max_budget_usd"] = max_budget_usd
    for k in MECH_BOUNDS:
        err = _cap_error(k, caps[k])
        if err:
            return None, err
    return caps, None


def mech_contract(config, task_id):
    """Contract dict generated from config.mech.contract_commands, or None
    when the template is absent. Caller validates config via mech_caps first."""
    block = (config or {}).get("mech") or {}
    cmds = block.get("contract_commands") if isinstance(block, dict) else None
    if not cmds:
        return None
    return {"v": 1, "task_id": task_id, "commands": json.loads(json.dumps(cmds))}


def _git(worktree, *args):
    """stdout of a git command in the worktree, or None on any failure."""
    try:
        cp = subprocess.run(["git", "-C", worktree, *args], capture_output=True,
                            text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return cp.stdout.strip() if cp.returncode == 0 else None


def _usage_exhausted(result) -> bool:
    """True when the probe's result/error text names usage/credit exhaustion.
    Scans the string-ish fields a `claude -p` error can carry (`result`,
    `error`, `message`, and an `error` object's `message`)."""
    parts = []
    for key in ("result", "error", "message"):
        v = result.get(key)
        if isinstance(v, str):
            parts.append(v)
        elif isinstance(v, dict):
            m = v.get("message")
            if isinstance(m, str):
                parts.append(m)
    return bool(_USAGE_EXHAUSTION_RE.search(" ".join(parts)))


def classify_probe(result, alias):
    """Classify a `claude -p --output-format json` result for the strong model.
    available: no error and a modelUsage key names the alias.
    unavailable: a hard "not launchable" signal -- a 403 restriction, or a 429
    whose result/error text names usage/credit exhaustion (out of credits ->
    fall back deterministically, do not wait on a human).
    indeterminate: anything else, including a bare/transient 429 (rate limit),
    other statuses, no claude, network error, or an unparseable/success-without-
    the-model result -- caller must abort, not assume."""
    if not isinstance(result, dict):
        return "indeterminate"
    if result.get("is_error") is True:
        # Coerce -- the CLI may surface api_error_status as a string ("429").
        try:
            status = int(result.get("api_error_status"))
        except (TypeError, ValueError):
            status = None
        # 403 is a hard restriction (model not offered to this account).
        if status == 403:
            return "unavailable"
        # A 429 is ambiguous on its own (transient rate limit -> abort/retry),
        # but a 429 whose message names usage/credit exhaustion is reliable
        # "this model is not launchable" data -> unavailable, so the caller
        # falls back to Opus instead of waiting for a human to unblock.
        if status == 429 and _usage_exhausted(result):
            return "unavailable"
        return "indeterminate"
    if result.get("is_error") is False:
        # Shape verified live 2026-08-28: a successful probe reports the resolved
        # model as a modelUsage key like "claude-<alias>-<n>" (spike observed
        # "claude-sonnet-5"), so the alias is a substring of its key.
        mu = result.get("modelUsage")
        if isinstance(mu, dict) and any(alias in str(k) for k in mu):
            return "available"
    return "indeterminate"


def state_root() -> Path:
    base = os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude")
    return Path(base) / "herdr-orch"


def repo_slug(remote_url, common_dir=None) -> str:
    if remote_url:
        u = remote_url.strip()
        u = re.sub(r"\.git\Z", "", u)
        u = re.sub(r"\A[a-z]+://", "", u)
        u = re.sub(r"\A[^@]+@", "", u)
        norm = re.sub(r"[^a-z0-9]+", "-", u.lower()).strip("-")
        h = hashlib.sha256(remote_url.strip().encode()).hexdigest()[:8]
        return f"{norm}-{h}"
    h = hashlib.sha256(str(Path(common_dir).resolve()).encode()).hexdigest()[:8]
    return f"local-{h}"


def jira_task_id(key: str) -> str:
    return key.strip().upper()


def todo_task_id(stable_id: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", stable_id.strip().lower()).strip("-")
    return slug if slug.startswith("td-") else f"td-{slug}"


def agent_name(prefix: str, task_id: str, existing=()) -> str:
    t = re.sub(r"[^a-z0-9-]+", "-", task_id.lower()).strip("-")
    base = f"{prefix}-{t}"[:32]
    name = base
    n = 2
    while name in existing:
        suffix = f"-{n}"
        name = base[: 32 - len(suffix)] + suffix
        n += 1
    return name


def branch_name(user: str, task_id: str, slug: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", slug.lower()).strip("-")[:32]
    return f"{user}/{task_id}/{s}"


def worktree_dirname(branch: str) -> str:
    return branch.replace("/", "+")


def valid_workspace_id(ws) -> bool:
    return bool(ws) and bool(WORKSPACE_ID_RE.match(ws))


MESSAGING_SOCKET_DIRS = (
    re.compile(r"^/tmp/cc-socks(-\d+)?$"),
    re.compile(r"^/run/user/\d+/cc-socks$"),
    re.compile(r"^/data/data/com\.termux/files/usr/tmp/cc-socks(-\d+)?$"),
)
_SOCKET_BASENAME = re.compile(r"^(\d+)\.sock$")


def normalize_socket_path(path: str) -> str:
    """Lexical normalization only: collapse the macOS /private/tmp alias.
    Never resolves symlinks (a socket path is used exactly as published)."""
    if path.startswith("/private/tmp/"):
        return path[len("/private"):]
    return path


def validate_messaging_socket(path, expect_pid=None):
    """Shape-check an inbox socket path. Returns (normalized, pid, reason);
    reason == "ok" iff valid. Pure: touches no filesystem."""
    if not isinstance(path, str) or path == "":
        return None, None, "empty"
    if not path.startswith("/"):
        return None, None, "not-absolute"
    norm = normalize_socket_path(path)
    d, _, base = norm.rpartition("/")
    if not any(p.match(d) for p in MESSAGING_SOCKET_DIRS):
        return None, None, "dir-not-canonical"
    m = _SOCKET_BASENAME.match(base)
    if not m:
        return None, None, "basename-not-pid-sock"
    pid = int(m.group(1))
    if expect_pid is not None and pid != int(expect_pid):
        return None, None, "pid-mismatch"
    return norm, pid, "ok"


def valid_repo_slug(slug) -> bool:
    return bool(slug) and ".." not in slug and bool(REPO_SLUG_RE.match(slug))


def valid_task_id(tid) -> bool:
    return bool(tid) and ".." not in tid and bool(TASK_ID_RE.match(tid))


def contained(path, root) -> bool:
    try:
        rp = Path(path).resolve()
        rr = Path(root).resolve()
    except OSError:
        return False
    return rp == rr or rr in rp.parents


_HINTS = {"stopped", "blocked", "review-stopped"}
_AUTH = {
    "kickoff",
    "phase-advanced",
    "review-dispatched",
    "completed",
    "paused",
    "failed",
    "changes-requested",
    "reviewed",
    "abandoned",
    "merged",
}


def repo_dir(slug: str) -> Path:
    return state_root() / slug


def index_path(rd, ws) -> Path:
    return Path(rd) / "workspaces" / f"{ws}.json"


def events_path(rd, ws) -> Path:
    return Path(rd) / "workspaces" / f"{ws}.events.jsonl"


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_json_atomic(path, data) -> None:
    path = Path(path)
    tmp = Path(f"{path}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(data))
    os.replace(tmp, path)


def read_index(rd, ws):
    if not valid_workspace_id(ws):
        return None
    p = index_path(rd, ws)
    try:
        if p.is_symlink() or not contained(p, state_root()):
            return None
        with open(p) as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def read_config(rd):
    p = Path(rd) / "config.json"
    try:
        if p.is_symlink() or not contained(p, state_root()):
            return {}
        cfg = json.loads(p.read_text())
    except (OSError, ValueError):
        return {}
    return cfg if isinstance(cfg, dict) else {}


def read_capabilities(rd, session_id):
    """Validated 'available' dict, or None if the map is absent, unreadable,
    malformed, or stamped with a different session (stale)."""
    p = Path(rd) / "capabilities.json"
    try:
        if p.is_symlink() or not contained(p, state_root()):
            return None
        cap = json.loads(p.read_text())
    except (OSError, ValueError):
        return None
    if not valid_capabilities(cap, session_id):
        return None
    return cap.get("available")


def append_event(rd, ws, event, **fields) -> bool:
    if not valid_workspace_id(ws):
        return False
    p = events_path(rd, ws)
    rec = {"v": 1, "ts": now_iso(), "workspace_id": ws, "event": event}
    rec.update(fields)
    line = json.dumps(rec, separators=(",", ":")) + "\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(p, flags, 0o600)
    except OSError:
        return False
    try:
        os.write(fd, line.encode())
    finally:
        os.close(fd)
    return True


WAKE_EVENTS = frozenset({"stopped", "blocked", "review-stopped"})
WAKE_BUDGET_SECS = 2.0       # one monotonic deadline across connect + send
WAKE_CONNECT_TIMEOUT = 1.0
WAKE_HEARTBEAT_STALE_SECS = 900
WAKE_HEARTBEAT_SKEW_SECS = 300
_lstat = os.lstat      # test seams (monkeypatched by the suite)
_geteuid = os.geteuid


def wake_line(repo_slug, ws, event, ts=None, nonce=None) -> str:
    """One newline-terminated stream-json user message: the closed-vocabulary
    wake the hook pushes to the orchestrator's inbox. nonce keeps two wakes
    in one second from being byte-identical (receiver dedupes repeats)."""
    if ts is None:
        ts = int(time.time())
    if nonce is None:
        nonce = secrets.token_hex(4)
    content = (f"herdr-wake v=1 repo={repo_slug} workspace={ws} event={event} "
               f"ts={ts} nonce={nonce}")
    msg = {"type": "user", "message": {"role": "user", "content": content}}
    return json.dumps(msg, separators=(",", ":")) + "\n"


def post_wake(rd, ws, event, own_socket="", now=None) -> str:
    """Push one wake line to the owning orchestrator's inbox socket named in
    owner.json. Every guard returns a distinct reason and sends nothing; only
    "sent" means a line left this process. Never raises; 2s wall budget."""
    if event not in WAKE_EVENTS:
        return "bad-event"
    repo_slug = os.path.basename(str(rd))
    if not valid_repo_slug(repo_slug) or not valid_workspace_id(ws):
        return "bad-id"   # keeps the wire content inside the \S+ grammar
    deadline = time.monotonic() + WAKE_BUDGET_SECS
    try:
        owner = json.loads(_owner_path(rd).read_text())
    except (FileNotFoundError, NotADirectoryError):
        return "no-owner"
    except (OSError, ValueError):
        return "bad-owner"
    if not isinstance(owner, dict):
        return "bad-owner"
    sock_path = owner.get("messaging_socket")
    if not isinstance(sock_path, str) or not sock_path:
        return "no-socket"
    hb = owner.get("heartbeat_ts")
    if isinstance(hb, bool) or not isinstance(hb, (int, float)) or not math.isfinite(hb):
        return "bad-heartbeat"
    now = time.time() if now is None else now
    if now - hb > WAKE_HEARTBEAT_STALE_SECS:
        return "stale-heartbeat"
    if hb - now > WAKE_HEARTBEAT_SKEW_SECS:
        return "future-heartbeat"
    pid = owner.get("pid")
    if isinstance(pid, str) and pid.isdigit():
        pid = int(pid)   # legacy records written by the pre-flag CLI
    if isinstance(pid, bool) or not isinstance(pid, int):
        return "bad-pid"
    norm, _pid, reason = validate_messaging_socket(sock_path, expect_pid=pid)
    if reason != "ok":
        return "bad-path"
    if own_socket and normalize_socket_path(own_socket) == norm:
        return "own-socket"
    try:
        st_sock = _lstat(norm)
        st_dir = _lstat(norm.rpartition("/")[0])
    except OSError:
        return "not-a-socket"
    if not stat.S_ISSOCK(st_sock.st_mode):
        return "not-a-socket"
    uid = _geteuid()
    if st_sock.st_uid != uid or st_dir.st_uid != uid:
        return "bad-owner-uid"
    if stat.S_IMODE(st_dir.st_mode) & 0o077:
        return "bad-dir-mode"
    line = wake_line(repo_slug, ws, event).encode()
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    except OSError:
        return "connect-failed"
    try:
        s.settimeout(min(WAKE_CONNECT_TIMEOUT, max(0.05, deadline - time.monotonic())))
        try:
            s.connect(norm)
        except OSError:
            return "connect-failed"
        s.settimeout(max(0.05, deadline - time.monotonic()))
        try:
            s.sendall(line)
        except OSError:
            return "send-failed"
        return "sent"
    finally:
        try:
            s.close()
        except OSError:
            pass


def parse_events(lines):
    out = []
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            rec = json.loads(ln)
        except ValueError:
            continue
        if not isinstance(rec, dict) or rec.get("v") != 1:
            continue
        out.append(rec)
    return out


def fold_status(events):
    """Latest authoritative event wins; last hint is surfaced separately."""
    authoritative = None
    last_hint = None
    for rec in events:
        ev = rec.get("event")
        if ev in _AUTH:
            authoritative = ev
        elif ev in _HINTS:
            last_hint = ev
    return {"authoritative": authoritative, "last_hint": last_hint}


WATCH_DIRS = {
    "tasks": ((".done.json", valid_task_id), (".review.json", valid_task_id)),
    "workspaces": ((".events.jsonl", valid_workspace_id),),
}
ACTIVE_STATUSES = frozenset({"in-progress", "blocked", "review-dispatched"})


def watch_scan(rd, prev):
    """Snapshot {path: (mtime_ns, size)} of the watched completion/hint files.

    Read-only. A missing subdir is an empty set. A subdir whose listing
    fails (OSError other than absence) is reported in `failed` and its
    entries are carried over from `prev`; a per-file stat() failure likewise
    retains the prior entry -- so transient errors and recovery can never
    signal-storm.
    """
    snap, failed = {}, set()
    for sub, suffixes in WATCH_DIRS.items():
        d = Path(rd) / sub
        try:
            names = sorted(os.listdir(d))
        except FileNotFoundError:
            continue
        except OSError:
            failed.add(sub)
            prefix = str(d) + os.sep
            for k, v in prev.items():
                if k.startswith(prefix):
                    snap[k] = v
            continue
        for name in names:
            for suffix, valid in suffixes:
                if name.endswith(suffix) and valid(name[: -len(suffix)]):
                    key = str(d / name)
                    try:
                        st = (d / name).stat()
                    except OSError:
                        if key in prev:
                            snap[key] = prev[key]
                        break
                    snap[key] = (st.st_mtime_ns, st.st_size)
                    break
    return snap, failed


def watch_changed(prev, snap) -> bool:
    """True iff snap has a new or modified entry. Deletions never signal."""
    return any(prev.get(k) != v for k, v in snap.items())


def heartbeat_active(rd) -> bool:
    """True iff any validated primary tasks/<task_id>.json record has an
    active status. Sidecars and foreign filenames never count."""
    d = Path(rd) / "tasks"
    try:
        names = os.listdir(d)
    except OSError:
        return False
    for name in names:
        if not name.endswith(".json") or name.endswith(
            (".done.json", ".review.json")
        ):
            continue
        if not valid_task_id(name[: -len(".json")]):
            continue
        try:
            rec = json.loads((d / name).read_text())
        except (OSError, ValueError):
            continue
        if isinstance(rec, dict) and rec.get("status") in ACTIVE_STATUSES:
            return True
    return False


def watch_tick(st, changed, active, now, heartbeat_secs, debounce_secs):
    """One poll-pass decision (pure; clock injected via `now`).

    st: {"pending": bool, "suppress_until": float, "last_emit": float},
    mutated in place. Returns "signal", "heartbeat", or None. At most one
    line per pass; signal takes precedence; any emit resets the heartbeat
    timer.
    """
    if changed:
        st["pending"] = True
    if st["pending"] and now >= st["suppress_until"]:
        st["pending"] = False
        st["suppress_until"] = now + debounce_secs
        st["last_emit"] = now
        return "signal"
    if now - st["last_emit"] >= heartbeat_secs and active:
        st["last_emit"] = now
        return "heartbeat"
    return None


def _watch_loop(rd, interval, heartbeat_secs, debounce_secs, exit_on_signal,
                since_epoch):
    """Poll the watched set; print watch_tick's decisions (closed vocabulary,
    at most one line per pass). Runs until killed, unless exit_on_signal,
    which returns 0 after the first emitted line. since_epoch (optional)
    seeds the baseline: files newer than it count as already-changed."""
    prev, _failed = watch_scan(rd, {})
    st = {"pending": False, "suppress_until": 0.0,
          "last_emit": time.monotonic()}
    if since_epoch is not None:
        since_ns = int(since_epoch * 1e9)
        st["pending"] = any(m > since_ns for m, _s in prev.values())
    while True:
        time.sleep(interval)
        snap, _failed = watch_scan(rd, prev)
        changed = watch_changed(prev, snap)
        prev = snap
        now = time.monotonic()
        due = now - st["last_emit"] >= heartbeat_secs
        active = due and heartbeat_active(rd)
        line = watch_tick(st, changed, active, now, heartbeat_secs,
                          debounce_secs)
        if line:
            print(line, flush=True)
            if exit_on_signal:
                return 0


def _owner_path(rd) -> Path:
    return Path(rd) / "owner.json"


def claim_owner(rd, session_id, host, pid, stale_secs=900, messaging_socket=None):
    Path(rd).mkdir(parents=True, exist_ok=True)
    p = _owner_path(rd)
    sock, sock_pid, reason = validate_messaging_socket(messaging_socket)
    if reason == "ok" and int(pid) != sock_pid:
        print(f"[WARNING] --pid {pid} differs from messaging socket pid {sock_pid}; "
              f"using {sock_pid}", file=sys.stderr)
    elif reason not in ("ok", "empty"):
        print(f"[WARNING] messaging socket ignored ({reason}): {messaging_socket}",
              file=sys.stderr)
    rec = {
        "session_id": session_id,
        "host": host,
        "pid": sock_pid if reason == "ok" else pid,
        "heartbeat_ts": time.time(),
        "fence": 1,
        "messaging_socket": sock,
    }
    excl = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    tmp = Path(f"{p}.new.{os.getpid()}")
    try:  # fast path: first-ever claim publishes atomically via link, so `p`
        # never appears on disk with partial/empty content for a racing reader.
        tmp.write_text(json.dumps(rec))
        try:
            os.link(tmp, p)
            return 1
        except FileExistsError:
            pass  # someone else won the first claim; fall through to takeover
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    lock = Path(f"{p}.lock")
    try:  # serialize the read-modify-write of an existing owner
        lfd = os.open(lock, excl, 0o600)
    except FileExistsError:
        try:  # a crashed holder (e.g. SIGKILL before the finally unlink) can
            # leave this lock forever; break it by mtime so ownership never
            # wedges permanently, retrying the exclusive-create exactly once.
            stale_lock = time.time() - os.stat(lock).st_mtime > stale_secs
        except OSError:
            stale_lock = False
        if not stale_lock:
            return None  # fresh lock: another takeover in progress; caller may retry
        # Known limitation (single-user-unreachable): two contenders can race
        # this unlink/re-create -- one may unlink a lock the other just remade.
        # The loser's exclusive-create then fails and it returns None to retry;
        # the fence still names exactly one winner, so it self-heals. Only
        # reachable with concurrent orchestrators on one repo.
        try:
            os.unlink(lock)
        except OSError:
            pass
        try:
            lfd = os.open(lock, excl, 0o600)
        except FileExistsError:
            return None  # lost the race to break it; caller may retry
    try:
        try:
            cur = json.loads(p.read_text())
        except (OSError, ValueError):
            cur = {}
        fresh = time.time() - float(cur.get("heartbeat_ts", 0)) <= stale_secs
        if fresh and cur.get("session_id") != session_id:
            return None
        fence = int(cur.get("fence", 0)) + 1
        rec["fence"] = fence
        write_json_atomic(p, rec)
        return fence
    finally:
        os.close(lfd)
        try:
            os.unlink(lock)
        except OSError:
            pass


def check_fence(rd, session_id, fence) -> bool:
    try:
        cur = json.loads(_owner_path(rd).read_text())
    except (OSError, ValueError):
        return False
    return cur.get("session_id") == session_id and int(cur.get("fence", -1)) == int(
        fence
    )


def refresh_owner(rd, session_id, fence, messaging_socket=None) -> bool:
    if not check_fence(rd, session_id, fence):
        return False
    cur = json.loads(_owner_path(rd).read_text())
    cur["heartbeat_ts"] = time.time()
    if isinstance(cur.get("pid"), str) and cur["pid"].isdigit():
        cur["pid"] = int(cur["pid"])  # migrate records written by the pre-flag CLI
    if messaging_socket is not None:  # None = flag omitted: leave untouched
        sock, _pid, reason = validate_messaging_socket(
            messaging_socket, expect_pid=cur.get("pid")
        )
        if reason not in ("ok", "empty"):
            print(f"[WARNING] messaging socket ignored ({reason}): {messaging_socket}",
                  file=sys.stderr)
        cur["messaging_socket"] = sock
    write_json_atomic(_owner_path(rd), cur)
    return True


def is_completed(task, done, live_head_sha, workspace) -> bool:
    if not isinstance(task, dict) or not isinstance(done, dict):
        return False
    if done.get("outcome") != "completed":
        return False
    if done.get("task_id") != task.get("task_id"):
        return False
    # Provenance: the record must come from the workspace the orchestrator
    # dispatched for this task, not a foreign/older worker that raced the file.
    if done.get("workspace_id") != workspace:
        return False
    if done.get("head_sha") != live_head_sha or done.get("base_sha") != task.get(
        "base_sha"
    ):
        return False
    return done.get("head_sha") != done.get(
        "base_sha"
    )  # at least one commit ahead of base


def should_dispatch_review(task, head_sha) -> bool:
    if task.get("status") != "completed":
        return False
    return task.get("review_head_sha") != head_sha


def is_reviewed(task, done, head_sha, workspace) -> bool:
    """Merge-ready only when the dispatched review SHA, the reviewed SHA, and
    live HEAD all agree, the record comes from the dispatched review workspace,
    and no blocking finding was reported. Requiring the task record's dispatched
    `review_head_sha` too (not just `done.reviewed_head_sha` == HEAD) stops a
    branch advance after dispatch from slipping an unreviewed revision through;
    the `blocking_count` guard stops an `approved` verdict that still carries
    blocking findings from clearing the gate."""
    if not isinstance(task, dict) or not isinstance(done, dict):
        return False
    if done.get("task_id") != task.get("task_id"):
        return False
    # Provenance: only the workspace the orchestrator dispatched for review.
    if done.get("workspace_id") != workspace:
        return False
    if done.get("phase") != "review" or done.get("outcome") != "approved":
        return False
    if int(done.get("blocking_count", 0)) != 0:
        return False
    return task.get("review_head_sha") == head_sha and (
        done.get("reviewed_head_sha") == head_sha
    )


def _require(cond, msg) -> None:
    if not cond:
        sys.stderr.write(f"[X] {msg}\n")
        raise SystemExit(2)


def _fenced(ns):
    # Known limitation (single-user-unreachable): this fence check and the
    # caller's subsequent write are not one atomic step -- a just-superseded
    # owner could pass here and then write in the gap after a concurrent
    # takeover. Fence-mitigated (the next refresh/claim by the live owner wins)
    # and needs two contending orchestrators on one repo; revisit only if this
    # ever becomes multi-user.
    _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
    rd = repo_dir(ns.repo_slug)
    _require(check_fence(rd, ns.session, int(ns.fence)), "stale or missing fence")
    return rd


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, *args, fenced=False):
        p = sub.add_parser(name)
        p.add_argument("--repo-slug", required=True)
        if fenced:
            p.add_argument("--session", required=True)
            p.add_argument("--fence", required=True)
        for a in args:
            p.add_argument(a, required=True)
        return p

    co = add("claim-owner", "--session", "--host")
    co.add_argument("--pid", type=int, required=True)   # was a positional-style required str
    co.add_argument("--stale-secs", type=int, default=None)  # test/override hook
    co.add_argument("--messaging-socket", default=None)
    ro = add("refresh-owner", "--session", "--fence")
    ro.add_argument("--messaging-socket", default=None)
    add("check-fence", "--session", "--fence")
    add("write-task", "--task-id", "--json", fenced=True)
    add("write-index", "--workspace", "--json", fenced=True)
    add("write-capabilities", "--json", fenced=True)
    add("resolve-model", "--role", "--session")
    add("disable-model", "--model", fenced=True)
    mc = add("mech-caps")
    mc.add_argument("--max-turns", type=int, default=None)
    mc.add_argument("--max-budget-usd", type=float, default=None)
    add("mech-contract", "--task-id", "--worktree", "--base-sha")
    add("classify-probe", "--model", "--json")
    ed = add(
        "emit-done",
        "--task-id",
        "--workspace",
        "--agent",
        "--phase",
        "--outcome",
        "--head-sha",
        "--base-sha",
    )
    ed.add_argument("--launch-id", default=None)
    ed.add_argument("--reason", default=None)
    er = add(
        "emit-review",
        "--task-id",
        "--workspace",
        "--agent",
        "--reviewed-head-sha",
        "--outcome",
    )
    er.add_argument("--findings-ref", default=None)
    er.add_argument("--blocking-count", type=int, default=0)
    add("status")
    add("should-dispatch-review", "--task-id", "--head-sha")
    add("confirm-completion", "--task-id", "--workspace", "--head-sha")
    add("confirm-review", "--task-id", "--workspace", "--head-sha")
    w = add("watch")
    w.add_argument("--interval", type=int, default=15)
    w.add_argument("--heartbeat-secs", type=int, default=1800)
    w.add_argument("--debounce-secs", type=int, default=60)
    w.add_argument("--exit-on-signal", action="store_true")
    w.add_argument("--once", action="store_true")
    w.add_argument("--since-epoch", type=float, default=None)
    vc = add("verify-contract", "--task-id", "--worktree")
    vc.add_argument("--contract", default=None)
    vc.add_argument("--allow-unpinned", action="store_true")
    vc.add_argument("--validate-only", action="store_true")
    ns = ap.parse_args(argv)

    if ns.cmd == "claim-owner":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        kw = {} if ns.stale_secs is None else {"stale_secs": ns.stale_secs}
        fence = claim_owner(repo_dir(ns.repo_slug), ns.session, ns.host, ns.pid,
                            messaging_socket=ns.messaging_socket, **kw)
        if fence is None:
            print("BUSY")
            return 1
        print(fence)
        return 0
    if ns.cmd == "check-fence":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        return (
            0 if check_fence(repo_dir(ns.repo_slug), ns.session, int(ns.fence)) else 1
        )
    if ns.cmd == "refresh-owner":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        return (
            0 if refresh_owner(repo_dir(ns.repo_slug), ns.session, int(ns.fence),
                               messaging_socket=ns.messaging_socket) else 1
        )
    if ns.cmd == "write-task":
        rd = _fenced(ns)
        _require(valid_task_id(ns.task_id), "invalid task-id")
        try:
            rec = json.loads(ns.json)
        except ValueError:
            rec = None
        # Persisting a non-dict (e.g. a bare `[]`) would later crash `status`
        # on `.get`; a task_id mismatch would mislabel the record under its file.
        _require(
            isinstance(rec, dict) and rec.get("task_id") == ns.task_id,
            "task json must be a JSON object whose task_id equals --task-id",
        )
        (rd / "tasks").mkdir(parents=True, exist_ok=True)
        write_json_atomic(rd / "tasks" / f"{ns.task_id}.json", rec)
        return 0
    if ns.cmd == "write-index":
        rd = _fenced(ns)
        _require(valid_workspace_id(ns.workspace), "invalid workspace")
        try:
            rec = json.loads(ns.json)
        except ValueError:
            rec = None
        # Same guard as write-task: a non-dict index would read back as None
        # (read_index rejects it), silently orphaning the workspace's events.
        _require(isinstance(rec, dict), "index json must be a JSON object")
        (rd / "workspaces").mkdir(parents=True, exist_ok=True)
        write_json_atomic(index_path(rd, ns.workspace), rec)
        return 0
    if ns.cmd == "write-capabilities":
        rd = _fenced(ns)
        try:
            rec = json.loads(ns.json)
        except ValueError:
            rec = None
        _require(
            valid_capabilities(rec, ns.session),
            "capabilities json must be {v:1, session_id==--session, "
            "available:{fable,opus,sonnet,haiku all bool}}",
        )
        Path(rd).mkdir(parents=True, exist_ok=True)
        write_json_atomic(rd / "capabilities.json", rec)
        return 0
    if ns.cmd == "resolve-model":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        rd = repo_dir(ns.repo_slug)
        available = read_capabilities(rd, ns.session)
        model, code = resolve_model(ns.role, available, read_config(rd))
        if code is not None:
            sys.stderr.write(
                {
                    3: "[X] capabilities map absent or stale; re-probe first\n",
                    4: "[X] no available model for role\n",
                    5: "[X] invalid role or config models override\n",
                }[code]
            )
            return code
        print(model)
        return 0
    if ns.cmd == "disable-model":
        rd = _fenced(ns)
        _require(ns.model in CAP_MODELS, "model must be one of fable/opus/sonnet/haiku")
        available = read_capabilities(rd, ns.session)
        _require(available is not None, "capabilities map absent or stale")
        rec = {"v": 1, "session_id": ns.session, "available": dict(available)}
        rec["available"][ns.model] = False
        write_json_atomic(rd / "capabilities.json", rec)
        return 0
    if ns.cmd == "classify-probe":
        _require(ns.model in CAP_MODELS, "model must be one of fable/opus/sonnet/haiku")
        try:
            result = json.loads(ns.json)
        except ValueError:
            result = None
        print(classify_probe(result, ns.model))
        return 0
    if ns.cmd in ("emit-done", "emit-review"):
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        _require(valid_workspace_id(ns.workspace), "invalid workspace")
        rd = repo_dir(ns.repo_slug)
        (rd / "tasks").mkdir(parents=True, exist_ok=True)
        if ns.cmd == "emit-done":
            done = {
                "v": 1,
                "task_id": ns.task_id,
                "workspace_id": ns.workspace,
                "agent": ns.agent,
                "phase": ns.phase,
                "outcome": ns.outcome,
                "head_sha": ns.head_sha,
                "base_sha": ns.base_sha,
                "ts": now_iso(),
            }
            if ns.launch_id:
                done["launch_id"] = ns.launch_id
            if ns.reason is not None:
                _require(ns.reason in MECH_REASONS,
                         f"reason must be one of {'|'.join(MECH_REASONS)}")
                done["reason"] = ns.reason
            out = rd / "tasks" / f"{ns.task_id}.done.json"
        else:
            done = {
                "v": 1,
                "task_id": ns.task_id,
                "workspace_id": ns.workspace,
                "agent": ns.agent,
                "phase": "review",
                "outcome": ns.outcome,
                "reviewed_head_sha": ns.reviewed_head_sha,
                "blocking_count": int(ns.blocking_count),
                "ts": now_iso(),
            }
            if ns.findings_ref:
                done["findings_ref"] = ns.findings_ref
            # A distinct file so a review verdict never clobbers the impl
            # completion record -- the two coexist and are read independently.
            out = rd / "tasks" / f"{ns.task_id}.review.json"
        _require(contained(out, state_root()), "escapes state root")
        write_json_atomic(out, done)
        return 0
    if ns.cmd == "status":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        rd = repo_dir(ns.repo_slug)
        # Associate each workspace's events with its task via the workspace index,
        # then order per-task events chronologically (ts, event tie-breaker).
        by_task = {}
        for ef in (rd / "workspaces").glob("*.events.jsonl"):
            ws = ef.name[: -len(".events.jsonl")]
            idx = read_index(rd, ws) or {}
            tid = idx.get("task_id")
            if not tid:
                continue
            by_task.setdefault(tid, []).extend(
                parse_events(ef.read_text().splitlines())
            )
        for tid in by_task:
            by_task[tid].sort(key=lambda r: (r.get("ts", ""), r.get("event", "")))
        result = {}
        for tf in sorted((rd / "tasks").glob("*.json")):
            # Only the primary <task_id>.json record; the .done.json/.review.json
            # sidecars sort after it and would otherwise overwrite the entry.
            if tf.name.endswith((".done.json", ".review.json")):
                continue
            try:
                task = json.loads(tf.read_text())
            except ValueError:
                continue
            tid = task.get("task_id")
            result[tid] = {
                "status": task.get("status"),
                "fold": fold_status(by_task.get(tid, [])),
            }
        print(json.dumps(result))
        return 0
    if ns.cmd == "should-dispatch-review":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        rd = repo_dir(ns.repo_slug)
        tf = rd / "tasks" / f"{ns.task_id}.json"
        _require(contained(tf, state_root()), "escapes state root")
        try:
            task = json.loads(tf.read_text())
        except (OSError, ValueError):
            return 1
        return 0 if should_dispatch_review(task, ns.head_sha) else 1
    if ns.cmd == "confirm-completion":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        _require(valid_workspace_id(ns.workspace), "invalid workspace")
        rd = repo_dir(ns.repo_slug)
        tf = rd / "tasks" / f"{ns.task_id}.json"
        df = rd / "tasks" / f"{ns.task_id}.done.json"
        _require(contained(tf, state_root()), "escapes state root")
        _require(contained(df, state_root()), "escapes state root")
        try:
            task = json.loads(tf.read_text())
        except (OSError, ValueError):
            return 1
        try:
            done = json.loads(df.read_text())
        except (OSError, ValueError):
            done = None
        return 0 if is_completed(task, done, ns.head_sha, ns.workspace) else 1
    if ns.cmd == "confirm-review":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        _require(valid_workspace_id(ns.workspace), "invalid workspace")
        rd = repo_dir(ns.repo_slug)
        tf = rd / "tasks" / f"{ns.task_id}.json"
        rf = rd / "tasks" / f"{ns.task_id}.review.json"
        _require(contained(tf, state_root()), "escapes state root")
        _require(contained(rf, state_root()), "escapes state root")
        try:
            task = json.loads(tf.read_text())
        except (OSError, ValueError):
            return 1
        try:
            done = json.loads(rf.read_text())
        except (OSError, ValueError):
            done = None
        return 0 if is_reviewed(task, done, ns.head_sha, ns.workspace) else 1
    if ns.cmd == "watch":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(ns.interval >= 1, "interval must be >= 1")
        _require(ns.heartbeat_secs >= 1, "heartbeat-secs must be >= 1")
        _require(ns.debounce_secs >= 1, "debounce-secs must be >= 1")
        _require(not (ns.once and ns.exit_on_signal), "once excludes exit-on-signal")
        _require(not ns.once or ns.since_epoch is not None, "once requires since-epoch")
        if ns.since_epoch is not None:
            _require(
                math.isfinite(ns.since_epoch) and ns.since_epoch >= 0,
                "since-epoch must be a finite float >= 0",
            )
        rd = repo_dir(ns.repo_slug)
        if ns.once:
            snap, _failed = watch_scan(rd, {})
            since_ns = int(ns.since_epoch * 1e9)
            if any(mtime_ns > since_ns for mtime_ns, _size in snap.values()):
                print("signal", flush=True)
            if heartbeat_active(rd):
                print("heartbeat", flush=True)
            return 0
        return _watch_loop(
            rd, ns.interval, ns.heartbeat_secs, ns.debounce_secs,
            ns.exit_on_signal, ns.since_epoch,
        )
    if ns.cmd == "verify-contract":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        wt = Path(ns.worktree)
        _require(wt.is_dir(), "worktree must be an existing directory")
        _require(
            not ns.allow_unpinned or ns.contract,
            "--allow-unpinned requires --contract",
        )
        rel = ns.contract
        expected_sha = None
        if not ns.allow_unpinned:
            tf = repo_dir(ns.repo_slug) / "tasks" / f"{ns.task_id}.json"
            _require(contained(tf, state_root()), "escapes state root")
            # A missing or corrupt task record is an integrity error (exit 2
            # via _require), never exit 5 -- exit 5 is reserved for a VALID
            # record that simply lacks pin fields, so the skill's grandfather
            # rule can never be satisfied by corruption.
            try:
                task = json.loads(tf.read_text())
            except (OSError, ValueError):
                task = None
            _require(
                isinstance(task, dict), "task record missing or unreadable"
            )
            pin_path = task.get("contract_path")
            expected_sha = task.get("contract_sha256")
            if not isinstance(pin_path, str) or not isinstance(expected_sha, str):
                sys.stderr.write("[X] no contract pinned for task\n")
                return 5
            _require(
                rel is None or rel == pin_path,
                "--contract does not match the pinned contract_path",
            )
            rel = pin_path
        cf = wt / rel
        # contained() resolves symlinks, so an in-tree symlink to an outside
        # file already fails containment; the explicit is_symlink() rejection
        # also covers a symlink to another file INSIDE the worktree.
        _require(
            contained(cf, wt) and not cf.is_symlink(),
            "contract path escapes the worktree or is a symlink",
        )
        if not cf.is_file():
            sys.stderr.write("[X] contract file missing\n")
            return 3
        # Single read: hash and parse the SAME bytes, so a concurrent
        # replacement between hash and execution cannot run unhashed commands.
        try:
            data = cf.read_bytes()
        except OSError:
            sys.stderr.write("[X] contract file missing\n")
            return 3
        actual_sha = hashlib.sha256(data).hexdigest()
        if expected_sha is not None and actual_sha != expected_sha:
            sys.stderr.write("[X] contract hash mismatch (tamper or drift)\n")
            return 4
        try:
            rec = json.loads(data)
        except ValueError:
            rec = None
        err = validate_contract(rec, ns.task_id)
        _require(err is None, f"invalid contract: {err}")
        if ns.validate_only:
            print(actual_sha)
            return 0
        return run_contract_commands(rec["commands"], str(wt))
    if ns.cmd == "mech-caps":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        caps, err = mech_caps(read_config(repo_dir(ns.repo_slug)),
                              ns.max_turns, ns.max_budget_usd)
        if err:
            sys.stderr.write(f"[X] {err}\n")
            return 5
        print(json.dumps(caps))
        return 0
    if ns.cmd == "mech-contract":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        wt = Path(ns.worktree)
        _require(wt.is_dir(), "worktree must be an existing directory")
        head = _git(str(wt), "rev-parse", "HEAD")
        _require(head is not None, "worktree must be a git checkout")
        _require(head == ns.base_sha, "worktree HEAD != --base-sha (adopted branch diverged)")
        _require(_git(str(wt), "status", "--porcelain") == "", "worktree must be clean")
        cfg = read_config(repo_dir(ns.repo_slug))
        _, err = mech_caps(cfg)
        if err:
            sys.stderr.write(f"[X] {err}\n")
            return 5
        rec = mech_contract(cfg, ns.task_id)
        if rec is None:
            sys.stderr.write("[X] config has no mech.contract_commands\n")
            return 5
        rel = f"claude/contracts/{ns.task_id}-contract.json"
        out = wt / rel
        _require(contained(out, wt), "contract path escapes the worktree")
        _require(not out.exists(), "contract already exists; use it or remove it deliberately")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(rec, indent=2) + "\n")
        print(rel)
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
