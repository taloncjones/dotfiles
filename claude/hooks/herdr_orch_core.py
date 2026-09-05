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
    "think": ("fable", "opus"),
}

# Aliases a role's config override may name. haiku is mech-only: the cheap
# tier is human-designated per task, never a silent option for design,
# implementation, or review.
ROLE_ALIASES = {
    "plan": ("fable", "opus", "sonnet"),
    "impl": ("fable", "opus", "sonnet"),
    "review": ("fable", "opus", "sonnet"),
    "mech": CAP_MODELS,
    "think": ("fable", "opus"),
}

EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")
THINK_EFFORTS = ("high", "xhigh", "max")
# None = inherit: no --effort flag on the launch line.
ROLE_EFFORT_DEFAULTS = {"plan": "high", "impl": None, "review": "high",
                        "mech": None, "think": "high"}

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


def role_effort(role, config):
    """(level_or_None, None) on success -- None means inherit; (None, 5) when
    the role is unknown or the config 'effort' block is malformed: not a
    dict, a key outside the roles, a value outside EFFORT_LEVELS (or outside
    THINK_EFFORTS / null for think), or a bool/number. Fail closed like the
    models block."""
    if role not in ROLE_EFFORT_DEFAULTS:
        return (None, 5)
    cfg = config or {}
    if "effort" not in cfg:
        return (ROLE_EFFORT_DEFAULTS[role], None)
    block = cfg["effort"]                      # an explicit null is a malformed block
    if not isinstance(block, dict) or any(k not in ROLE_EFFORT_DEFAULTS for k in block):
        return (None, 5)
    for k, v in block.items():
        if v is None:
            if k == "think":
                return (None, 5)
            continue
        allowed = THINK_EFFORTS if k == "think" else EFFORT_LEVELS
        if isinstance(v, bool) or not isinstance(v, str) or v not in allowed:
            return (None, 5)
    if role in block:
        return (block[role], None)
    return (ROLE_EFFORT_DEFAULTS[role], None)


def routing_table(available, config):
    """{role: {model, effort}} for every role from one config + one
    capabilities snapshot. (table, None), or (None, 5) on a malformed
    models/effort block, (None, 3) on an absent/stale map. A role with no
    surviving model gets model None (the caller halts that launch)."""
    for role in ROLE_DEFAULTS:
        if role_preference(role, config) is None or role_effort(role, config)[1] is not None:
            return (None, 5)
    if available is None:
        return (None, 3)
    table = {}
    for role in ROLE_DEFAULTS:
        model, _ = resolve_model(role, available, config)
        table[role] = {"model": model, "effort": role_effort(role, config)[0]}
    return (table, None)


MECH_DEFAULTS = {"max_turns": 40, "max_budget_usd": 2.0, "timeout_secs": 1800}
MECH_BOUNDS = {"max_turns": (1, 500), "max_budget_usd": (0, 50), "timeout_secs": (60, 14400)}
MECH_KEYS = frozenset(MECH_DEFAULTS) | {"contract_commands"}

MECH_REASONS = ("max_turns", "max_budget", "timeout", "no_emit", "error",
                "needs_design", "blocked_on_human", "other")

SHELL_SAFE_RE = re.compile(r"[A-Za-z0-9_./+:@-]+\Z")
SHA40_RE = re.compile(r"[0-9a-f]{40}\Z")
_CAP_SUBTYPES = {"error_max_turns": "max_turns", "error_max_budget_usd": "max_budget"}
_ERRORS_MAX, _ERROR_LEN = 5, 500


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


_ANSI_RE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"            # CSI
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC
    r"|\x1b[@-Z\\-_]"                     # single-char escapes
)
_BANNER_VERSION_RE = re.compile(r"^[^A-Za-z]*Claude Code v\d+\.\d+\.\d+")   # anchored: glyphs, then the banner
_BANNER_SCAN_LINES = 12                                                        # indicator lives within the banner region
_BANNER_MODEL_RE = re.compile(
    r"^(?P<model>(?:Fable|Opus|Sonnet|Haiku)\b[^\u00b7]*?)"
    r"(?: with (?P<effort>low|medium|high|xhigh|max) effort)?"
    r"(?:\s*\u00b7.*)?$"
)
_BANNER_EFFORT_LINE_RE = re.compile(r"\u25cf\s*(low|medium|high|xhigh|max)\s*\u00b7\s*/effort")
_MODEL_FAMILY = {"fable": "fable", "opus": "opus", "sonnet": "sonnet", "haiku": "haiku"}


def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", (text or "").replace("\r", ""))


def parse_banner(text):
    """{"model", "effort"} from the FIRST Claude Code banner in text, or
    None when there is no anchored version line or the model line names no
    known family (spec 3): unknown text is unreadable, never a downgrade."""
    lines = strip_ansi(text).splitlines()
    for i, line in enumerate(lines):
        if not _BANNER_VERSION_RE.search(line):
            continue
        rest = [l for l in lines[i + 1:] if l.strip()]
        if not rest:
            return None
        model_line = re.sub(r"^[^A-Za-z]+", "", rest[0]).strip()
        m = _BANNER_MODEL_RE.match(model_line)
        if not m:
            return None
        effort = m.group("effort")
        if effort is None:
            for later in rest[1:_BANNER_SCAN_LINES]:
                e = _BANNER_EFFORT_LINE_RE.search(later)
                if e:
                    effort = e.group(1)
                    break
        return {"model": m.group("model").strip(), "effort": effort}
    return None


def classify_banner(parsed, alias, effort) -> str:
    """Spec 3 precedence: unreadable > downgrade > effort-mismatch > ok."""
    if not parsed:
        return "unreadable"
    if _MODEL_FAMILY[alias] not in parsed["model"].lower():
        return "downgrade"
    if effort != "inherit" and parsed.get("effort") != effort:
        return "effort-mismatch"
    return "ok"


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


SPEND_KEYS = ("usd", "turns", "launches", "unknown_cost_launches", "skipped_lines")


def spend_path(rd, task_id) -> Path:
    return Path(rd) / "tasks" / f"{task_id}.spend.jsonl"


def append_spend(rd, task_id, rec) -> None:
    """Append one ledger line. Raises OSError on failure (caller maps it)."""
    p = spend_path(rd, task_id)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "a") as f:
        f.write(json.dumps(rec) + "\n")
        f.flush()


def valid_mech_agent(agent, task_id) -> bool:
    """agent is the canonical agent_name("mech", task_id) or one of its
    collision variants -2..-9 (same truncation rule as agent_name)."""
    base = agent_name("mech", task_id)
    if agent == base:
        return True
    for n in range(2, 10):
        suffix = f"-{n}"
        if agent == base[: 32 - len(suffix)] + suffix:
            return True
    return False


def parse_claude_result(stdout: str):
    """The single result object from `claude -p --output-format json`, or
    None. Tolerates leading noise by scanning lines from the end."""
    for candidate in [stdout] + list(reversed(stdout.splitlines())):
        try:
            obj = json.loads(candidate)
        except ValueError:
            continue
        if isinstance(obj, dict) and obj.get("type") == "result":
            return obj
    return None


def models_used(result) -> list:
    mu = (result or {}).get("modelUsage")
    return sorted(mu.keys()) if isinstance(mu, dict) else []


def is_downgrade(models: list, alias: str) -> bool:
    """True when the CLI reports models and none belong to the requested
    alias family (alias is a substring of every model id in its family)."""
    return bool(models) and not any(alias in m for m in models)


def result_errors(result) -> list:
    """The result's errors[] as a bounded list of strings (non-strings dropped,
    each clipped, at most _ERRORS_MAX) -- persisted so the orchestrator can
    judge model-attributability without the transcript."""
    errs = (result or {}).get("errors")
    if not isinstance(errs, list):
        return []
    return [e[:_ERROR_LEN] for e in errs if isinstance(e, str)][:_ERRORS_MAX]


def model_attributable(subtype, downgrade, errors, alias) -> bool:
    """Spec s4 within-role fallback trigger: a downgrade, or an execution
    error whose text names the alias or 'model'."""
    if downgrade:
        return True
    if subtype != "error_during_execution":
        return False
    text = " ".join(errors).lower()
    return alias in text or "model" in text


def own_launch_record(done, workspace, agent, launch_id, start_ts) -> bool:
    if not isinstance(done, dict):
        return False
    if done.get("workspace_id") != workspace or done.get("agent") != agent:
        return False
    if "launch_id" in done:
        return done.get("launch_id") == launch_id
    ts = done.get("ts")
    return isinstance(ts, str) and ts >= start_ts


def wrapper_outcome(subtype, head_sha, base_sha, dirty):
    """(outcome, reason) for a launch whose worker left no record."""
    if subtype in _CAP_SUBTYPES:
        return "paused", _CAP_SUBTYPES[subtype]
    if subtype == "timeout":
        return "paused", "timeout"
    if subtype == "success":
        return "paused", "no_emit"
    usable = head_sha is not None and head_sha != base_sha and not dirty
    return ("paused" if usable else "failed"), "error"


def run_mech(rd, a, brief, timeout_secs) -> int:
    """Launch a headless capped worker; write start/end ledger lines and a
    guaranteed completion record. Exit 0 all writes ok; 2 nothing written;
    3 a post-start step failed (git lookup, record write, or end line)."""
    start_ts = now_iso()
    caps = {"max_turns": a.max_turns, "max_budget_usd": a.max_budget_usd,
            "timeout_secs": a.timeout_secs}
    base = {"v": 1, "task_id": a.task_id, "workspace_id": a.workspace,
            "agent": a.agent, "launch_id": a.launch_id}
    try:
        append_spend(rd, a.task_id, dict(base, kind="start", role="mech",
                                         model=a.model, ts=start_ts, **caps))
    except OSError:
        sys.stderr.write("[X] cannot append the spend ledger\n")
        return 2
    argv = ["claude", "--model", a.model, "--permission-mode", "auto",
            "--name", a.agent, "-p", "--output-format", "json",
            "--max-turns", str(a.max_turns), "--max-budget-usd", str(a.max_budget_usd)]
    subtype, result, exit_code, stdout = "unparseable", None, None, ""
    try:
        proc = subprocess.Popen(argv, cwd=a.worktree, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, start_new_session=True)
    except OSError as e:
        sys.stderr.write(f"[X] cannot launch claude: {e}\n")
    else:
        try:
            stdout, _err = proc.communicate(brief, timeout=timeout_secs)
            exit_code = proc.returncode
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                pass
            proc.wait()
            subtype, exit_code = "timeout", proc.returncode
    if subtype != "timeout":
        result = parse_claude_result(stdout)
        if result is not None:
            subtype = str(result.get("subtype") or "unparseable")
    used = models_used(result)
    errors = result_errors(result)
    downgrade = is_downgrade(used, a.model)
    head = _git(a.worktree, "rev-parse", "HEAD")
    porcelain = _git(a.worktree, "status", "--porcelain")
    git_ok = head is not None and porcelain is not None
    dirty = not git_ok or porcelain != ""
    done_path = rd / "tasks" / f"{a.task_id}.done.json"
    try:
        existing = json.loads(done_path.read_text())
    except (OSError, ValueError):
        existing = None
    rc = 0
    written_by = "worker"
    if not own_launch_record(existing, a.workspace, a.agent, a.launch_id, start_ts):
        if not git_ok:
            # No trustworthy HEAD: never fabricate a completion record.
            sys.stderr.write("[X] git unavailable in the worktree; no completion record\n")
            written_by, rc = "none", 3
        else:
            outcome, reason = wrapper_outcome(subtype, head, a.base_sha, dirty)
            done = {"v": 1, "task_id": a.task_id, "workspace_id": a.workspace,
                    "agent": a.agent, "phase": "implement", "outcome": outcome,
                    "head_sha": head, "base_sha": a.base_sha,
                    "launch_id": a.launch_id, "reason": reason, "dirty": dirty,
                    "ts": now_iso()}
            try:
                write_json_atomic(done_path, done)
                written_by = "wrapper"
            except OSError:
                sys.stderr.write("[X] cannot write the completion record\n")
                written_by, rc = "none", 3

    def _num(k, integer=False):
        v = (result or {}).get(k)
        return v if _finite_nonneg(v, integer) else None

    end = dict(base, kind="end", subtype=subtype,
               is_error=bool((result or {}).get("is_error", subtype != "success")),
               num_turns=_num("num_turns", True), total_cost_usd=_num("total_cost_usd"),
               duration_ms=_num("duration_ms", True), models_used=used,
               downgrade=downgrade, errors=errors,
               model_attributable=model_attributable(subtype, downgrade, errors, a.model),
               record_written_by=written_by, git_ok=git_ok, exit_code=exit_code,
               session_id=(result or {}).get("session_id"), ts=now_iso())
    try:
        append_spend(rd, a.task_id, end)
    except OSError:
        sys.stderr.write("[X] cannot append the spend ledger end line\n")
        rc = 3
    return rc


def _finite_nonneg(x, integer=False) -> bool:
    """None passes (absent/unknown); bools never; ints/floats must be finite
    and >= 0; integer=True additionally requires an int."""
    if x is None:
        return True
    if isinstance(x, bool):
        return False
    if integer:
        return isinstance(x, int) and x >= 0
    return isinstance(x, (int, float)) and math.isfinite(x) and x >= 0


def valid_spend_line(rec, task_id) -> bool:
    if not isinstance(rec, dict):
        return False
    v = rec.get("v")
    if not isinstance(v, int) or isinstance(v, bool) or v != 1:
        return False
    if rec.get("kind") not in ("start", "end"):
        return False
    if rec.get("task_id") != task_id or not _nonempty_str(rec.get("launch_id")):
        return False
    if rec["kind"] == "end":
        if "num_turns" not in rec or "total_cost_usd" not in rec:
            return False
        if not _finite_nonneg(rec.get("num_turns"), integer=True):
            return False
        if not _finite_nonneg(rec.get("total_cost_usd")):
            return False
    return True


def fold_spend(lines, task_id):
    """Sum a task's ledger. Malformed/foreign lines are skipped and counted,
    never fatal -- same posture as parse_events."""
    out = {k: 0 for k in SPEND_KEYS}
    out["usd"] = 0.0
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            rec = json.loads(ln)
        except ValueError:
            out["skipped_lines"] += 1
            continue
        if not valid_spend_line(rec, task_id):
            out["skipped_lines"] += 1
            continue
        if rec["kind"] == "start":
            out["launches"] += 1
            continue
        cost = rec.get("total_cost_usd")
        if cost is None:
            out["unknown_cost_launches"] += 1
        else:
            out["usd"] += cost
        if rec.get("num_turns") is not None:
            out["turns"] += rec["num_turns"]
    out["usd"] = round(out["usd"], 4)
    return out


WATCH_DIRS = {
    "tasks": ((".done.json", valid_task_id), (".review.json", valid_task_id),
              (".spend.jsonl", valid_task_id)),
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
    add("resolve-effort", "--role")
    add("routing-table", "--session")
    add("disable-model", "--model", fenced=True)
    mc = add("mech-caps")
    mc.add_argument("--max-turns", type=int, default=None)
    mc.add_argument("--max-budget-usd", type=float, default=None)
    add("mech-contract", "--task-id", "--worktree", "--base-sha")
    rm = add("run-mech", "--task-id", "--workspace", "--agent", "--launch-id",
             "--model", "--worktree", "--base-sha", "--brief-file")
    rm.add_argument("--max-turns", type=int, required=True)
    rm.add_argument("--max-budget-usd", type=float, required=True)
    rm.add_argument("--timeout-secs", type=int, required=True)
    add("classify-probe", "--model", "--json")
    cb = add("classify-banner", "--model", "--effort")
    cb.add_argument("--text-file", default=None)
    cb.add_argument("--text", default=None)
    cb.add_argument("--json", action="store_true")
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
    if ns.cmd == "resolve-effort":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        level, code = role_effort(ns.role, read_config(repo_dir(ns.repo_slug)))
        if code is not None:
            sys.stderr.write("[X] invalid role or config effort block\n")
            return code
        print(level or "inherit")
        return 0
    if ns.cmd == "routing-table":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        rd = repo_dir(ns.repo_slug)
        cfg = read_config(rd)
        available = read_capabilities(rd, ns.session)
        table, code = routing_table(available, cfg)
        if code is not None:
            sys.stderr.write({3: "[X] capabilities map absent or stale; re-probe first\n",
                              5: "[X] invalid config models or effort block\n"}[code])
            return code
        print(json.dumps(table))
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
    if ns.cmd == "classify-banner":
        _require(ns.model in CAP_MODELS, "model must be one of fable/opus/sonnet/haiku")
        _require(ns.effort == "inherit" or ns.effort in EFFORT_LEVELS, "effort must be a level or inherit")
        _require((ns.text is None) != (ns.text_file is None), "pass exactly one of --text/--text-file")
        text = ns.text
        if ns.text_file is not None:
            try:
                text = Path(ns.text_file).read_text(errors="replace")
            except OSError:
                text = None
        _require(text is not None, "text-file not readable")
        parsed = parse_banner(text)
        cls = classify_banner(parsed, ns.model, ns.effort)
        if ns.json:
            print(json.dumps({"class": cls, "model": (parsed or {}).get("model"),
                              "effort": (parsed or {}).get("effort")}))
        else:
            print(cls)
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
        totals = {k: 0 for k in SPEND_KEYS}
        totals["usd"] = 0.0
        untracked = 0
        primary = set()
        for tf in sorted((rd / "tasks").glob("*.json")):
            if tf.name.endswith((".done.json", ".review.json")):
                continue
            try:
                task = json.loads(tf.read_text())
            except ValueError:
                continue
            if not isinstance(task, dict):
                continue
            tid = task.get("task_id")
            primary.add(tf.name[: -len(".json")])
            sp = spend_path(rd, tid) if isinstance(tid, str) else None
            try:
                lines = sp.read_text().splitlines() if sp and sp.is_file() else []
            except OSError:
                lines = []
            spend = fold_spend(lines, tid)
            for k in SPEND_KEYS:
                totals[k] += spend[k]
            workers = task.get("workers")
            if isinstance(workers, list):
                untracked += sum(
                    1 for w in workers if isinstance(w, dict) and w.get("role") != "mech"
                )
            result[tid] = {
                "status": task.get("status"),
                "fold": fold_status(by_task.get(tid, [])),
                "spend": spend,
            }
        totals["usd"] = round(totals["usd"], 4)
        totals["untracked_launches"] = untracked
        orphans = set()
        for suffix in (".spend.jsonl", ".done.json"):
            for f in (rd / "tasks").glob(f"*{suffix}"):
                tid = f.name[: -len(suffix)]
                if valid_task_id(tid) and tid not in primary:
                    orphans.add(tid)
        result["_totals"] = totals
        result["_orphans"] = sorted(orphans)
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
    if ns.cmd == "run-mech":
        _require(valid_repo_slug(ns.repo_slug), "invalid repo-slug")
        _require(valid_task_id(ns.task_id), "invalid task-id")
        _require(valid_workspace_id(ns.workspace), "invalid workspace")
        for name in ("repo_slug", "task_id", "workspace", "agent", "launch_id",
                     "model", "worktree", "base_sha", "brief_file"):
            _require(SHELL_SAFE_RE.match(str(getattr(ns, name))),
                     f"--{name.replace('_', '-')} contains whitespace or a shell metacharacter")
        _require(valid_mech_agent(ns.agent, ns.task_id),
                 "agent must be agent_name('mech', task_id) or a -2..-9 collision variant")
        _require(ns.launch_id.startswith(ns.agent + "-"), "launch-id must be prefixed by the agent name")
        _require(ns.model in CAP_MODELS, "model must be a known alias")
        _require(SHA40_RE.match(ns.base_sha), "base-sha must be 40 hex")
        for k in ("max_turns", "max_budget_usd", "timeout_secs"):
            err = _cap_error(k, getattr(ns, k))
            _require(err is None, err or "")
        bf = Path(ns.brief_file)
        _require(bf.is_file() and not bf.is_symlink() and contained(bf, state_root()),
                 "brief-file must be a regular file under STATE_ROOT")
        try:
            brief = bf.read_text()
        except (OSError, UnicodeDecodeError):
            brief = None
        _require(brief is not None, "brief-file is not readable as text")
        wt = Path(ns.worktree)
        _require(wt.is_dir() and _git(str(wt), "rev-parse", "--git-dir") is not None,
                 "worktree must be an existing git checkout")
        rd = repo_dir(ns.repo_slug)
        try:
            (rd / "tasks").mkdir(parents=True, exist_ok=True)
        except OSError:
            pass  # run_mech's first append reports the unwritable ledger as exit 2
        return run_mech(rd, ns, brief, ns.timeout_secs)
    return 2


if __name__ == "__main__":
    sys.exit(main())
