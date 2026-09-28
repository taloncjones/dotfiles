"""Metadata-only owner fencing shared by runtime and account payload roots.

The persistent registry flock encloses both fence validation and publication.
No command execution belongs inside this transaction. Slug-only access can
migrate an existing owner, but cannot create an unbound repository owner.
"""

import contextlib
import fcntl
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "lib"))
from workflow_context import account_id_for_root, atomic_json_at, open_state_parent

_LOCAL = threading.local()
_SLUG = re.compile(r"[a-z0-9][a-z0-9-]*\Z")


def coordination_root():
    override = os.environ.get("HERDR_COORDINATION_ROOT")
    if override:
        requested = Path(override).expanduser().absolute()
        return requested.parent.resolve() / requested.name
    base = Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state")
    return base.expanduser().resolve() / "dotfiles/herdr-orch/coordination"


def owner_path(rd):
    slug = Path(rd).name
    if not _SLUG.fullmatch(slug):
        raise ValueError("invalid repository slug")
    return coordination_root() / slug / "owner.json"


def iter_lead_leases(slug):
    """Every valid lead lease under a slug's coordination dir, read-only and
    lockless -- the guard's convenience view of who holds a lead lease.

    Opens the slug dir no-follow, scans `lead-*.json`, reads each no-follow,
    and keeps only records that pass _valid_lead_lease. A missing dir yields
    []; a corrupt, symlinked, or non-regular entry is skipped, never raised
    (this never mutates and never takes the global lock)."""
    if not _SLUG.fullmatch(slug):
        raise ValueError("invalid repository slug")
    base = coordination_root() / slug
    try:
        parent = os.open(
            str(base),
            os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError:
        return []
    leases = []
    try:
        for name in os.listdir(parent):
            if not (name.startswith("lead-") and name.endswith(".json")):
                continue
            # Read AND validate under one guard: a malformed record must be
            # skipped, never allowed to raise out of this read-only view and
            # crash a caller (e.g. the edit guard) open. Any per-record error
            # -- unreadable, corrupt, or a validation edge -- drops just that
            # record and leaves valid siblings discoverable.
            try:
                rec = _read_at(parent, name)
                valid = rec is not None and _valid_lead_lease(rec)
            except Exception:  # noqa: BLE001, S112 -- read-only view; skip a bad record
                continue
            if valid:
                leases.append(rec)
    finally:
        os.close(parent)
    return leases


def occupied_lead_bindings():
    """{slug: {workspace_key: binding_id}} for live lead occupancies.

    ONE lockless read of the whole registry: bindings.json is a single file
    keyed by slug, so a per-slug reader would re-parse all of it once per
    slug.

    Total. Every unit it cannot trust is dropped at the tightest scope the
    damage allows -- a whole-file failure yields {}, an unusable slug drops
    that slug, an invalid entry drops that entry and keeps its valid
    siblings. The guard consults an occupancy only to WITHHOLD authority, so
    reporting one narrows access and dropping one widens it; scoping each
    failure tightly is therefore the fail-closed direction here.

    This deliberately does NOT mirror OwnerTransaction.__init__, which
    raises on any invalid entry anywhere. Refusing to operate is
    conservative for a writer; for a total reader the nearest equivalent --
    reporting nothing -- is the permissive answer.

    An absent registry and a corrupt one are indistinguishable here, and
    that is correct: both mean "no occupancy to corroborate". The
    disambiguating stat OwnerTransaction performs would be dead code,
    because nothing downstream branches on the difference.
    """
    try:
        parent = os.open(
            str(coordination_root()),
            os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
        )
    except Exception:  # noqa: BLE001 -- broader than OSError on purpose
        # coordination_root() itself can raise: Path.home() raises
        # RuntimeError with HOME unset, and a NUL byte in
        # HERDR_COORDINATION_ROOT makes os.open raise ValueError. Neither is
        # an OSError, and either would break the "never raises" contract.
        return {}
    try:
        registry = _read_at(parent, "bindings.json")
    except Exception:  # noqa: BLE001 -- an unreadable registry reports no occupancy
        return {}
    finally:
        os.close(parent)
    if not isinstance(registry, dict):
        return {}
    occupied = {}
    for slug, item in registry.items():
        if not isinstance(slug, str) or not _SLUG.fullmatch(slug):
            continue
        if not isinstance(item, dict):
            continue
        ws_map = item.get("lead_ws", {})
        if not isinstance(ws_map, dict):
            continue
        keyed = {}
        for key, entry in ws_map.items():
            # Per-entry guard: a record whose validation raises -- an
            # oversized release-ledger key hits CPython's int-from-string
            # digit limit -- drops alone rather than taking its valid
            # siblings with it.
            try:
                valid = isinstance(key, str) and _valid_lead_ws_entry(entry)
            except Exception:  # noqa: BLE001, S112 -- read-only view; skip a bad entry
                continue
            if valid and entry["binding_id"] is not None:
                keyed[key] = entry["binding_id"]
        if keyed:
            occupied[slug] = keyed
    return occupied


def coordination_slugs():
    """Valid slug directory names under the coordination root, sorted.

    The coordination root is the authoritative cross-account namespace for
    ownership and lead leases; the guard enumerates it (not the payload root)
    so a lead lease stays discoverable even when its payload-root slug dir was
    removed. A missing root yields []; non-slug entries are ignored."""
    try:
        names = os.listdir(str(coordination_root()))
    except OSError:
        return []
    return sorted(n for n in names if _SLUG.fullmatch(n))


def _no_dup_pairs(pairs):
    """object_pairs_hook that rejects duplicate keys in a JSON object: two
    spellings of one registry key would let the parser silently pick a
    loser, so the record is corrupt, never a choice."""
    d = {}
    for k, v in pairs:
        if k in d:
            raise ValueError("duplicate key")
        d[k] = v
    return d


def _read_at(parent, name):
    try:
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent,
        )
        with os.fdopen(fd, "r") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("coordination metadata must be a regular file")
            return json.load(stream, object_pairs_hook=_no_dup_pairs)
    except FileNotFoundError:
        return None
    except (ValueError, OSError) as exc:
        raise ValueError("unreadable coordination metadata") from exc


def _read(path):
    try:
        parent, name = open_state_parent(payload_path(path))
    except FileNotFoundError:
        return None
    try:
        return _read_at(parent, name)
    finally:
        os.close(parent)


def payload_account_root(rd):
    parent = payload_path(rd).parent
    return parent.parent if parent.name == "herdr-orch" else parent


def payload_path(path):
    """Normalize only native macOS system aliases, never account directories."""
    target = Path(path).expanduser().absolute()
    if sys.platform == "darwin" and len(target.parts) > 1:
        alias = target.parts[1]
        if alias in ("tmp", "var") and Path("/", alias).resolve() == Path(
            "/private", alias
        ):
            target = Path("/private", *target.parts[1:])
    return target


def _inode(st):
    return st.st_dev, st.st_ino


def _lock_at(parent, name):
    fd = os.open(
        name,
        os.O_RDWR | os.O_CREAT | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=parent,
    )
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("lock must be a regular file")
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        return fd
    except BaseException:
        os.close(fd)
        raise


def _valid_workspace_root(value):
    # Shared by claim (write side) and _valid_owner (read side) so a record
    # one side rejects can never be accepted by the other. "//" is a distinct
    # POSIX root that normpath preserves; a NUL byte survives isabs().
    return (
        isinstance(value, str)
        and bool(value)
        and "\x00" not in value
        and os.path.isabs(value)
        and os.path.normpath(value) not in (os.sep, os.sep * 2)
    )


def _valid_pid_start(value):
    return isinstance(value, str) and 0 < len(value) <= 128


def process_start_id(pid):
    """A string naming one process lifetime, so a recycled pid never matches
    the process that wrote a lease. None when it cannot be read or is
    not a valid pid_start."""
    if type(pid) is not int or pid < 1:
        return None
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            fields = f.read().rsplit(b")", 1)[1].split()
        with open("/proc/sys/kernel/random/boot_id") as f:
            boot = f.read().strip()
        # Field 22 (starttime); fields after the ")" start at field 3.
        ident = f"linux:{boot}:{int(fields[19])}"
        return ident if _valid_pid_start(ident) else None
    except (OSError, IndexError, ValueError):
        pass
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                              capture_output=True, text=True, timeout=5, check=False,
                              env=dict(os.environ, LC_ALL="C", TZ="UTC"))
    except (OSError, subprocess.SubprocessError):
        return None
    text = " ".join(out.stdout.split())
    if out.returncode != 0 or not text:
        return None
    ident = "ps:" + text
    return ident if _valid_pid_start(ident) else None


def lead_lease_key(workspace_root):
    return hashlib.sha256(workspace_root.encode()).hexdigest()[:16]


def _valid_owner(value):
    if not isinstance(value, dict):
        return False
    return (
        isinstance(value.get("session_id"), str)
        and bool(value["session_id"])
        and isinstance(value.get("host"), str)
        and bool(value["host"])
        and type(value.get("pid")) is int
        and value["pid"] > 0
        and type(value.get("fence")) is int
        and value["fence"] > 0
        and type(value.get("heartbeat_ts")) in (int, float)
        # An int is always finite; only a float can be inf/nan. Calling
        # math.isfinite on an oversized int (from arbitrary JSON) raises
        # OverflowError, which would otherwise escape validation and crash a
        # reader open -- so never convert an int to float here.
        and (type(value["heartbeat_ts"]) is int or math.isfinite(value["heartbeat_ts"]))
        and value["heartbeat_ts"] >= 0
        and value.get("runtime", "claude") in ("claude", "codex")
        and (value.get("thread_id") is None or isinstance(value["thread_id"], str))
        and ("pid_start" not in value or _valid_pid_start(value["pid_start"]))
        and (value.get("runtime") != "codex" or bool(value.get("thread_id")))
        and (value.get("account_id") is None or isinstance(value["account_id"], str))
        and value.get("control_tier", "launcher") in ("launcher", "lead")
        and (
            value.get("control_tier", "launcher") != "lead"
            or _valid_workspace_root(value.get("workspace_root"))
        )
        and (
            value.get("control_tier", "launcher") == "lead"
            or value.get("workspace_root") is None
        )
    )


_BINDING_ID = re.compile(r"ldb-[0-9a-f]{32}\Z")
_GENERATION_KEY = re.compile(r"[1-9][0-9]*\Z")


def _valid_lead_lease(rec):
    return (
        _valid_owner(rec)
        and type(rec.get("schema_version")) is int
        and rec["schema_version"] == 1
        and rec.get("control_tier") == "lead"
        and isinstance(rec.get("binding_id"), str)
        and bool(_BINDING_ID.fullmatch(rec["binding_id"]))
        # Bound the heartbeat so staleness arithmetic (time.time() -
        # heartbeat_ts) can never overflow inside a scan. _valid_owner
        # already admits any non-negative int or finite float; the only
        # value that overflows the float subtraction is an int too large to
        # convert to float, so the bound need only exclude those. 1e300 sits
        # safely below the float ceiling yet far past any real clock or
        # far-future sentinel; the int-vs-float comparison is exact, so an
        # absurd int (e.g. 10**400) is rejected here without itself
        # overflowing.
        and rec["heartbeat_ts"] <= 1e300
        and ("generation" not in rec
             or (type(rec["generation"]) is int and rec["generation"] >= 1))
    )


def _valid_lead_ws_entry(v):
    """One lead_ws registry entry. `releases` is the append-only release
    ledger: each key is a generation (canonical positive decimal string)
    mapped to the binding that occupied the workspace for that generation
    and released it, written only by lead_release in the same atomic
    registry write that clears the occupancy. Keys never exceed the entry's
    generation, and the CURRENT generation may not appear while the entry
    is occupied (release and occupancy-clear are one event).
    `released_binding` is the retired mutable field: read-tolerated so
    stray pre-ledger state cannot brick the registry, but never written
    and never consulted for attribution or proof."""
    if not isinstance(v, dict):
        return False
    if not ({"generation", "binding_id", "last_fence"}
            <= set(v)
            <= {"generation", "binding_id", "last_fence",
                "released_binding", "releases"}):
        return False
    if type(v["generation"]) is not int or v["generation"] < 1:
        return False
    if not (v["binding_id"] is None
            or (isinstance(v["binding_id"], str)
                and _BINDING_ID.fullmatch(v["binding_id"]))):
        return False
    if not (v.get("released_binding") is None
            or (isinstance(v["released_binding"], str)
                and _BINDING_ID.fullmatch(v["released_binding"]))):
        return False
    if type(v["last_fence"]) is not int or v["last_fence"] < 1:
        return False
    releases = v.get("releases", {})
    if not isinstance(releases, dict):
        return False
    for gen_key, released in releases.items():
        if not isinstance(gen_key, str) or not _GENERATION_KEY.fullmatch(gen_key):
            return False
        if int(gen_key) > v["generation"]:
            return False
        if not (isinstance(released, str) and _BINDING_ID.fullmatch(released)):
            return False
    return v["binding_id"] is None or str(v["generation"]) not in releases


def _owner_metadata(value):
    result = {
        key: value[key]
        for key in ("session_id", "host", "pid", "fence", "heartbeat_ts")
    }
    meta = dict(
        result,
        runtime=value.get("runtime", "claude"),
        thread_id=value.get("thread_id"),
        account_id=value.get("account_id"),
        control_tier=value.get("control_tier", "launcher"),
        workspace_root=value.get("workspace_root"),
    )
    if "pid_start" in value:
        meta["pid_start"] = value["pid_start"]
    return meta


def _observation(value):
    # legacy_seen entries persist in the BASE field set only. They exist to
    # detect a changed foreign legacy owner, and a rolled-back (pre-tier)
    # reader compares them verbatim: persisting newer optional fields would
    # make that reader spuriously report an unchanged owner as changed and
    # block every transaction until the entry is repaired.
    result = {
        key: value[key]
        for key in ("session_id", "host", "pid", "fence", "heartbeat_ts")
    }
    return dict(
        result,
        runtime=value.get("runtime", "claude"),
        thread_id=value.get("thread_id"),
        account_id=value.get("account_id"),
    )


def _owner_key(value):
    return (
        value["session_id"],
        value["fence"],
        value.get("runtime", "claude"),
        value.get("thread_id"),
        value.get("account_id"),
    )


@contextlib.contextmanager
def ordered_lock(path, kind):
    """Owner precedes think; retain directory identity for the entire lock."""
    held = getattr(_LOCAL, "locks", ())
    if kind == "owner" and held:
        raise RuntimeError(
            "owner lock must precede think lock; nested owner lock forbidden"
        )
    if kind == "think" and "think" in held:
        raise RuntimeError("nested think lock forbidden")
    path = Path(path)
    parent = fd = guard_parent = guard_fd = None
    try:
        if kind == "owner":
            # A renamed/replaced registry must not mint an independent lock
            # while an old transaction can still publish account payloads.
            guard = path.parent.parent / f".{path.parent.name}.owner.guard"
            guard_parent, guard_name = open_state_parent(guard, create=True)
            guard_fd = _lock_at(guard_parent, guard_name)
        parent, name = open_state_parent(path, create=True)
        fd = _lock_at(parent, name)
        _LOCAL.locks = (*held, kind)
        yield parent, fd
    finally:
        _LOCAL.locks = held
        for descriptor in (fd, parent, guard_fd, guard_parent):
            if descriptor is not None:
                os.close(descriptor)


def assert_transaction_current():
    tx = getattr(_LOCAL, "transaction", None)
    if tx is not None:
        tx.assert_current()


@contextlib.contextmanager
def payload_parent(path, create=False):
    """Retain a no-follow payload parent through an entire read/publication."""
    assert_transaction_current()
    parent, name = open_state_parent(payload_path(path), create=create)
    try:
        assert_transaction_current()
        yield parent, name
    finally:
        os.close(parent)


def locks_held():
    return bool(getattr(_LOCAL, "locks", ()))


class OwnerTransaction:
    """Unlocked operations; construct only through owner_transaction."""

    def __init__(
        self,
        rd,
        canonical_id,
        expected_slug,
        legacy_roots,
        registry_fd,
        lock_fd,
        account_id,
        payload_fd,
    ):
        self.rd = payload_path(rd)
        self.path = owner_path(rd)
        self.slug = self.rd.name
        self.registry_fd = registry_fd
        self.registry_inode = _inode(os.fstat(registry_fd))
        self.lock_inode = _inode(os.fstat(lock_fd))
        self.account_id = account_id or account_id_for_root(payload_account_root(rd))
        self.payload_inode = _inode(os.fstat(payload_fd))
        self.assert_current()
        bindings = _read_at(registry_fd, "bindings.json")
        if bindings is None:
            # _read_at returns None for BOTH an absent file and a file whose
            # content parsed to JSON null. Only genuine absence may read as
            # an empty registry; a null registry file is corrupt.
            try:
                os.stat("bindings.json", dir_fd=registry_fd,
                        follow_symlinks=False)
            except FileNotFoundError:
                bindings = {}
            else:
                raise ValueError("corrupt repository bindings")
        if not isinstance(bindings, dict) or any(
            not isinstance(key, str)
            or not isinstance(item, dict)
            or "repo_id" not in item
            or type(item.get("owner_initialized", False)) is not bool
            or not isinstance(item.get("legacy_seen", {}), dict)
            or any(
                not isinstance(scope, str) or not _valid_owner(owner)
                for scope, owner in item.get("legacy_seen", {}).items()
            )
            or not isinstance(item.get("payload_scopes"), list)
            or any(not isinstance(root, str) for root in item["payload_scopes"])
            or (
                item.get("repo_id") is not None and not isinstance(item["repo_id"], str)
            )
            or not isinstance(item.get("lead_seen", []), list)
            or any(not isinstance(k, str) for k in item.get("lead_seen", []))
            or not isinstance(item.get("lead_ws", {}), dict)
            or any(
                not isinstance(k, str) or not _valid_lead_ws_entry(v)
                for k, v in item.get("lead_ws", {}).items()
            )
            for key, item in bindings.items()
        ):
            raise ValueError("corrupt repository bindings")
        binding = bindings.get(self.slug, {"repo_id": None, "payload_scopes": []})
        if canonical_id is not None:
            if not canonical_id or self.slug != expected_slug:
                raise ValueError("repository slug disagrees with canonical identity")
            if binding["repo_id"] not in (None, canonical_id):
                raise ValueError("repository slug already belongs to another identity")
            if any(
                key != self.slug and item["repo_id"] == canonical_id
                for key, item in bindings.items()
            ):
                raise ValueError(
                    "canonical repository already has a different slug binding"
                )
            binding = dict(binding, repo_id=canonical_id)
        if (
            canonical_id is None
            and self.slug not in bindings
            and any(item["repo_id"] for item in bindings.values())
        ):
            raise ValueError("legacy identity is ambiguous; provide repository context")
        current = self._owner_read()
        if current is None and binding.get("owner_initialized"):
            raise ValueError(
                "initialized owner record is missing; explicit recovery required"
            )
        if current is not None and not _valid_owner(current):
            raise ValueError("corrupt owner state; explicit recovery required")
        # Known account scopes and explicitly supplied migration roots. Only
        # owner metadata is inspected; prompts/capabilities/auth never move.
        roots = {str(self.rd.absolute())}
        roots.update(str(payload_path(root) / self.slug) for root in legacy_roots)
        candidates = []
        observed = dict(binding.get("legacy_seen", {}))
        for root in roots:
            legacy = _read(Path(root) / "owner.json")
            if legacy is None:
                continue
            if (
                isinstance(legacy, dict)
                and isinstance(legacy.get("pid"), str)
                and legacy["pid"].isdigit()
            ):
                legacy = dict(legacy, pid=int(legacy["pid"]))
            if not _valid_owner(legacy):
                raise ValueError(
                    "corrupt legacy owner state; explicit recovery required"
                )
            legacy = dict(
                _owner_metadata(legacy),
                account_id=legacy.get("account_id")
                or account_id_for_root(payload_account_root(root)),
            )
            scope = hashlib.sha256(root.encode()).hexdigest()
            previous = observed.get(scope)
            if previous is not None:
                # Project the persisted observation to the same base field set
                # as the fresh one before comparing: an entry written by another
                # version (older, or newer with extra optional fields) must not
                # make an unchanged legacy owner read as changed and block the
                # transaction.
                previous = dict(
                    _observation(previous),
                    account_id=previous.get("account_id")
                    or account_id_for_root(payload_account_root(root)),
                )
            foreign = current and _owner_key(legacy) != _owner_key(current)
            if (
                foreign
                and previous != _observation(legacy)
                and time.time() - legacy["heartbeat_ts"] <= 900
            ):
                raise ValueError("active legacy owner conflicts with shared ownership")
            observed[scope] = _observation(legacy)
            candidates.append(legacy)
        if current is None:
            live = [
                item for item in candidates if time.time() - item["heartbeat_ts"] <= 900
            ]
            identities = {_owner_key(item) for item in live}
            if len(identities) > 1:
                raise ValueError("conflicting active legacy owners")
            pool = live or candidates
            if pool:
                current = max(
                    pool, key=lambda item: (item["fence"], item["heartbeat_ts"])
                )
                self._owner_write(current)
        if current is None and binding["repo_id"] is None:
            raise ValueError(
                "unbound repository: provide repository context or migrate an existing owner"
            )
        self.current = current
        self.migrated = self.path.exists() and self.slug not in bindings
        scopes = {
            *binding["payload_scopes"],
            hashlib.sha256(str(self.rd.absolute()).encode()).hexdigest(),
        }
        updated = dict(
            binding,
            payload_scopes=sorted(scopes),
            legacy_seen=observed,
            owner_initialized=current is not None,
        )
        if bindings.get(self.slug) != updated:
            self.assert_current()
            atomic_json_at(
                self.registry_fd,
                "bindings.json",
                dict(bindings, **{self.slug: updated}),
            )

        self.bindings = dict(bindings, **{self.slug: updated})

    def assert_current(self):
        payload, _ = open_state_parent(self.rd / "owner.json")
        try:
            if _inode(os.fstat(payload)) != self.payload_inode:
                raise ValueError("account payload directory was replaced")
        finally:
            os.close(payload)
        parent, name = open_state_parent(coordination_root() / ".owner.lock")
        try:
            if (
                _inode(os.fstat(parent)) != self.registry_inode
                or _inode(os.stat(name, dir_fd=parent, follow_symlinks=False))
                != self.lock_inode
            ):
                raise ValueError("coordination registry or lock was replaced")
        finally:
            os.close(parent)

    def _owner_parent(self, create=False):
        if create:
            try:
                os.mkdir(self.slug, 0o700, dir_fd=self.registry_fd)
            except FileExistsError:
                pass
        try:
            return os.open(
                self.slug,
                os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=self.registry_fd,
            )
        except FileNotFoundError:
            if not create:
                return None
            raise
        except OSError as exc:
            raise ValueError("invalid repository metadata directory") from exc

    def _owner_read(self):
        parent = self._owner_parent()
        if parent is None:
            return None
        try:
            return _read_at(parent, "owner.json")
        finally:
            os.close(parent)

    def _owner_write(self, value):
        self.assert_current()
        parent = self._owner_parent(create=True)
        try:
            atomic_json_at(parent, "owner.json", value)
        finally:
            os.close(parent)

    def check(self, session, fence):
        self.assert_current()
        return (
            type(fence) is int
            and self.current is not None
            and self.current["session_id"] == session
            and self.current["fence"] == fence
            and self.current.get("account_id") == self.account_id
            and self.current.get("control_tier", "launcher") == "launcher"
        )

    def claim(
        self,
        session,
        host,
        pid,
        stale_secs=900,
        runtime="claude",
        thread_id=None,
        control_tier="launcher",
        workspace_root=None,
        adopt_pid=None,
        pid_start=None,
        adopt_start=None,
    ):
        if (
            not isinstance(session, str)
            or not session
            or not isinstance(host, str)
            or not host
        ):
            raise ValueError("session and host must be nonempty strings")
        if (
            type(pid) is not int
            or pid < 1
            or type(stale_secs) is not int
            or stale_secs < 0
        ):
            raise ValueError("invalid owner pid or stale interval")
        if (
            runtime not in ("claude", "codex")
            or (thread_id is not None and not isinstance(thread_id, str))
            or (runtime == "codex" and not thread_id)
        ):
            raise ValueError("invalid owner runtime/thread identity")
        if control_tier != "launcher":
            # Slug owner records are launcher-only; lead ownership is a
            # per-workspace lease (lead_claim) grounded in a dispatch binding.
            raise ValueError("slug ownership is launcher-only; use lead_claim")
        if workspace_root is not None:
            raise ValueError("workspace_root is only valid for a lead lease")
        self.assert_current()
        old = self.current
        if (
            old
            and time.time() - old["heartbeat_ts"] <= stale_secs
            and (
                old["session_id"] != session
                or old.get("runtime", "claude") != runtime
                or old.get("thread_id") != thread_id
                or old.get("account_id") != self.account_id
            )
            and not self._adoptable(old, adopt_pid, runtime, thread_id, adopt_start)
        ):
            return None
        fence = (
            old["fence"]
            if old
            and self.migrated
            and old["session_id"] == session
            and old.get("runtime", "claude") == runtime
            and old.get("thread_id") == thread_id
            and old.get("account_id") == self.account_id
            else (old["fence"] + 1 if old else 1)
        )
        if not self.bindings[self.slug].get("owner_initialized"):
            self.bindings = dict(
                self.bindings,
                **{self.slug: dict(self.bindings[self.slug], owner_initialized=True)},
            )
            atomic_json_at(self.registry_fd, "bindings.json", self.bindings)
        self.current = {
            "session_id": session,
            "host": host,
            "pid": pid,
            "fence": fence,
            "heartbeat_ts": time.time(),
            "runtime": runtime,
            "thread_id": thread_id,
            "account_id": self.account_id,
            "control_tier": "launcher",
            "workspace_root": None,
        }
        if _valid_pid_start(pid_start):
            self.current["pid_start"] = pid_start
        self._owner_write(self.current)
        return fence

    def _adoptable(self, old, adopt_pid, runtime, thread_id, adopt_start=None):
        # A fresh lease held by the same Claude process under an older session
        # id (after /clear). The caller proves process identity (ancestry) and
        # its start identity; a record without pid_start predates it (legacy).
        return (
            type(adopt_pid) is int
            and old.get("pid") == adopt_pid
            and ("pid_start" not in old
                 or (isinstance(adopt_start, str) and old["pid_start"] == adopt_start))
            and runtime == "claude"
            and old.get("runtime", "claude") == "claude"
            and old.get("thread_id") == thread_id
            and old.get("account_id") == self.account_id
            and old.get("control_tier", "launcher") == "launcher"
        )

    def refresh(self, session, fence):
        if not self.check(session, fence):
            return False
        self.current = dict(self.current, heartbeat_ts=time.time())
        self._owner_write(self.current)
        return True

    def _lead_name(self, workspace_root):
        if not _valid_workspace_root(workspace_root):
            raise ValueError("invalid lead workspace_root")
        return f"lead-{lead_lease_key(workspace_root)}.json"

    def lead_read(self, workspace_root):
        name = self._lead_name(workspace_root)
        parent = self._owner_parent()
        if parent is None:
            return None
        try:
            return _read_at(parent, name)
        finally:
            os.close(parent)

    def lead_claim(
        self,
        session,
        host,
        pid,
        workspace_root,
        binding_id,
        stale_secs=900,
        runtime="claude",
        thread_id=None,
    ):
        if (
            not isinstance(session, str)
            or not session
            or not isinstance(host, str)
            or not host
        ):
            raise ValueError("session and host must be nonempty strings")
        if (
            type(pid) is not int
            or pid < 1
            or type(stale_secs) is not int
            or stale_secs < 0
        ):
            raise ValueError("invalid lead pid or stale interval")
        if (
            runtime not in ("claude", "codex")
            or (thread_id is not None and not isinstance(thread_id, str))
            or (runtime == "codex" and not thread_id)
        ):
            raise ValueError("invalid lead runtime/thread identity")
        if not isinstance(binding_id, str) or not _BINDING_ID.fullmatch(binding_id):
            raise ValueError("invalid lead binding id")
        name = self._lead_name(workspace_root)
        self.assert_current()
        old = self.lead_read(workspace_root)
        key = lead_lease_key(workspace_root)
        seen = self.bindings[self.slug].get("lead_seen", [])
        ws_map = self.bindings[self.slug].get("lead_ws", {})
        entry = ws_map.get(key)
        if old is None and key in seen and (entry is None or entry["binding_id"] is not None):
            # A lease that has existed must not silently restart: either
            # it predates generation tracking, or it vanished without a
            # recorded lead_release. Explicit recovery required.
            raise ValueError(
                "initialized lead lease is missing; explicit recovery required"
            )
        if old is not None and not _valid_lead_lease(old):
            raise ValueError("corrupt lead lease; explicit recovery required")
        if old is not None and entry is None:
            # A lease file with NO corroborating registry entry is
            # uncorroborated authority: a genuine first-ever claim has
            # neither a lease nor an entry, and every later claim writes the
            # entry atomically with the lease. A lease standing alone can
            # only be a restored/replayed file over a wiped or never-written
            # entry; its identity and counters vouch only for themselves, so
            # it may bootstrap nothing.
            raise ValueError(
                "lead lease has no corroborating registry entry; "
                "explicit recovery required"
            )
        if old is not None and entry is not None:
            # Registry occupancy outranks the lease file (lead_release's
            # philosophy): a restored or replayed lease file that disagrees
            # with the durable lead_ws entry must never rebuild an old
            # occupancy, displace a successor, or roll the generation back.
            if entry["binding_id"] != old["binding_id"]:
                raise ValueError(
                    "lead lease disagrees with registry occupancy; "
                    "explicit recovery required"
                )
            if (
                old.get("generation") is not None
                and entry["generation"] > old["generation"]
            ):
                raise ValueError(
                    "lead lease generation is behind the registry; "
                    "explicit recovery required"
                )
        if (
            old is not None
            and entry is not None
            and (
                old["fence"] != entry["last_fence"]
                or old.get("generation") != entry["generation"]
            )
        ):
            # Claim-path sibling of reconcile's replayed-lease rule, applied
            # UNCONDITIONALLY: the on-disk lease may drive any decision
            # (staleness, identity match, high-water seeding) only when the
            # registry corroborates it at its exact fence AND generation. A
            # mismatched lease is a replayed older copy -- and the lease's
            # own identity fields cannot vouch for it, so this gate never
            # exempts a same-identity caller: a displaced holder replaying
            # its own stale lease must not reclaim past a live successor.
            # A genuine same-holder re-claim carries the current-counter
            # lease and passes; the high-water clamp below then advances it.
            raise ValueError(
                "lead lease disagrees with the registry fence/generation; "
                "explicit recovery required"
            )
        if (
            old
            and time.time() - old["heartbeat_ts"] <= stale_secs
            and (
                old["session_id"] != session
                or old.get("runtime", "claude") != runtime
                or old.get("thread_id") != thread_id
                or old.get("account_id") != self.account_id
            )
        ):
            return None
        if old:
            # High-water clamp against the durable registry: a replayed
            # lease file carrying an older fence must never make the chain
            # reissue a fence at or below the entry's recorded last_fence.
            floor = entry["last_fence"] if entry else 0
            fence = max(old["fence"], floor) + 1
            prior_generation = max(
                old.get("generation") or 0,
                entry["generation"] if entry else 0,
            ) or 1
            # A stale takeover by a DIFFERENT binding is a fresh occupancy of
            # the path and gets a fresh generation; the same binding
            # re-claiming its own workspace keeps its generation.
            generation = (
                prior_generation if old["binding_id"] == binding_id
                else prior_generation + 1
            )
        elif entry is not None:
            # cleanly released occupancy: resume the fence chain, fresh generation
            fence = entry["last_fence"] + 1
            generation = entry["generation"] + 1
        else:
            fence = 1
            generation = 1
        occupancy = {"generation": generation, "binding_id": binding_id,
                     "last_fence": fence}
        if entry is not None and entry.get("releases"):
            # The append-only release ledger survives a successor claim;
            # only the mutable occupancy fields are rewritten. (The retired
            # mutable released_binding is dropped, as before -- that erasure
            # is exactly what the ledger replaces.)
            occupancy["releases"] = entry["releases"]
        updated = dict(
            self.bindings[self.slug],
            lead_seen=sorted({*seen, key}),
            lead_ws=dict(ws_map, **{key: occupancy}),
        )
        self.bindings = dict(self.bindings, **{self.slug: updated})
        atomic_json_at(self.registry_fd, "bindings.json", self.bindings)
        record = {
            "schema_version": 1,
            "session_id": session,
            "host": host,
            "pid": pid,
            "fence": fence,
            "heartbeat_ts": time.time(),
            "runtime": runtime,
            "thread_id": thread_id,
            "account_id": self.account_id,
            "control_tier": "lead",
            "workspace_root": workspace_root,
            "binding_id": binding_id,
            "generation": generation,
        }
        parent = self._owner_parent(create=True)
        try:
            self.assert_current()
            atomic_json_at(parent, name, record)
        finally:
            os.close(parent)
        return fence

    def lead_check(self, session, fence, workspace_root, binding_id=None):
        self.assert_current()
        try:
            lease = self.lead_read(workspace_root)
        except ValueError:
            return False
        if lease is None or not _valid_lead_lease(lease):
            return False
        entry = self.bindings[self.slug].get("lead_ws", {}).get(
            lead_lease_key(workspace_root)
        )
        return (
            type(fence) is int
            and lease["session_id"] == session
            and lease["fence"] == fence
            and lease.get("account_id") == self.account_id
            # Pin the fence to its binding generation: a successor lead on
            # the same workspace must not authorize under a predecessor's
            # still-claimed binding.
            and (binding_id is None or lease["binding_id"] == binding_id)
            # The durable registry outranks the lease file everywhere: the
            # entry must name this lease's binding at this exact fence and
            # generation, or a replayed predecessor lease could authorize
            # lead-fenced writes into a superseded namespace.
            and entry is not None
            and entry["binding_id"] == lease["binding_id"]
            and entry["last_fence"] == lease["fence"]
            and (lease.get("generation") is None
                 or entry["generation"] == lease["generation"])
        )

    def lead_refresh(self, session, fence, workspace_root):
        if not self.lead_check(session, fence, workspace_root):
            return False
        lease = dict(self.lead_read(workspace_root), heartbeat_ts=time.time())
        parent = self._owner_parent(create=True)
        try:
            self.assert_current()
            atomic_json_at(parent, self._lead_name(workspace_root), lease)
        finally:
            os.close(parent)
        return True

    def lead_release(self, workspace_root, expected_binding=None, force=False):
        """Remove a workspace's lead lease and durably record the release.

        The explicit-recovery counterpart to lead_claim's missing-initialized
        refusal: after lead_release, a later claim on the same path resumes
        the fence chain with a fresh generation instead of raising. Returns
        True when a lease file was removed, False when nothing was on disk
        (idempotent re-run). A valid lease naming a different binding is
        refused unless expected_binding is None; a corrupt lease requires
        force=True (the caller asserts operator-level recovery). The registry
        occupancy is checked INDEPENDENTLY of the lease file: when the file
        is absent or corrupt, a lead_ws entry naming a binding other than
        expected_binding refuses the release even with force -- deleting a
        successor's lease must never let a predecessor's teardown clear the
        successor's occupancy.

        Release attribution is the entry's append-only ledger ("releases":
        generation -> binding), written ONLY here, in the SAME atomic
        registry write that clears the occupancy, and only on the
        occupied->released transition. An already-released entry is
        cleanup-only: a leftover or replayed lease file is removed, but
        nothing is appended and nothing is rewritten -- a replayed
        predecessor teardown can never rewrite attribution."""
        name = self._lead_name(workspace_root)
        key = lead_lease_key(workspace_root)
        self.assert_current()
        try:
            old = self.lead_read(workspace_root)
        except ValueError:
            old = None
            if not force:
                raise ValueError("corrupt lead lease; pass force to release")
        if old is not None and not _valid_lead_lease(old):
            if not force:
                raise ValueError("corrupt lead lease; pass force to release")
            old = None
        if (
            old is not None
            and expected_binding is not None
            and old["binding_id"] != expected_binding
        ):
            raise ValueError("lease names a different binding")
        ws_map = self.bindings[self.slug].get("lead_ws", {})
        entry = ws_map.get(key)
        if (
            entry is not None
            and entry["binding_id"] is not None
            and old is not None
            and old["binding_id"] != entry["binding_id"]
        ):
            # The registry determines attribution for an occupied entry; a
            # valid lease naming a DIFFERENT binding is conflicting evidence
            # (a replayed file, or a torn claim), never a source to pair
            # with the registry's generation -- even with no expectation.
            raise ValueError(
                "lease conflicts with registry occupancy; "
                "explicit recovery required"
            )
        if (
            entry is not None
            and entry["binding_id"] is not None
            and expected_binding is not None
            and entry["binding_id"] != expected_binding
        ):
            # Registry occupancy outranks the (possibly deleted or corrupt)
            # lease file; force does not override another binding's occupancy.
            raise ValueError("workspace is occupied by another binding")
        if entry is not None and entry["binding_id"] is None:
            # Already released: cleanup-only. Remove a leftover/replayed
            # lease file if present, but never touch the entry or its
            # ledger -- appending here would invent history for a
            # generation whose occupied->released transition this call
            # never observed.
            return self._unlink_lease(name)
        # High-water: the registry entry's counters never move backward,
        # even when the lease file being released is a replayed older copy.
        fences = [
            v
            for v in (
                old["fence"] if old else None,
                entry["last_fence"] if entry else None,
            )
            if v is not None
        ]
        last_fence = max(fences) if fences else None
        gens = [
            v
            for v in (
                (old or {}).get("generation"),
                entry["generation"] if entry else None,
            )
            if v is not None
        ]
        generation = max(gens) if gens else None
        if last_fence is None or generation is None:
            # No readable fence to resume from: a never-claimed workspace is a
            # no-op; anything else (pre-generation legacy, corrupt without
            # registry backing) needs explicit repair, not a silent release.
            if entry is None and old is None and not self._lease_file_exists(name):
                return False
            if last_fence is not None and generation is None:
                raise ValueError(
                    "legacy lease has no recorded generation; "
                    "explicit recovery required"
                )
            raise ValueError("release requires a recorded fence; explicit recovery")
        seen = self.bindings[self.slug].get("lead_seen", [])
        # Attribution rides the SAME atomic registry write as the release.
        # For an occupied entry the registry is the authority: its binding
        # at its generation (a lease's identity is never paired with the
        # registry's generation). With no entry at all, the caller's
        # expectation or the lease file is the only evidence. First-writer-
        # wins: an existing ledger key is never overwritten.
        if entry is not None:
            released_binding = entry["binding_id"]
            released_generation = entry["generation"]
        else:
            released_binding = expected_binding
            if released_binding is None:
                released_binding = (old or {}).get("binding_id")
            released_generation = generation
        releases = dict((entry or {}).get("releases", {}))
        if released_binding is not None and str(released_generation) not in releases:
            releases[str(released_generation)] = released_binding
        released_entry = {"generation": generation, "binding_id": None,
                          "last_fence": last_fence}
        if releases:
            released_entry["releases"] = releases
        updated = dict(
            self.bindings[self.slug],
            lead_seen=sorted({*seen, key}),
            lead_ws=dict(ws_map, **{key: released_entry}),
        )
        if entry is None:
            # No registry entry backs this release: the lease file is the
            # ONLY evidence, so the entry+ledger write must land BEFORE the
            # unlink -- a crash between the two must never destroy it.
            self.bindings = dict(self.bindings, **{self.slug: updated})
            atomic_json_at(self.registry_fd, "bindings.json", self.bindings)
            return self._unlink_lease(name)
        # An entry exists: it survives a crash after the unlink, and the
        # retry re-runs the release, so unlink-then-registry stays.
        removed = self._unlink_lease(name)
        self.bindings = dict(self.bindings, **{self.slug: updated})
        atomic_json_at(self.registry_fd, "bindings.json", self.bindings)
        return removed

    def _unlink_lease(self, name):
        parent = self._owner_parent()
        if parent is None:
            return False
        try:
            self.assert_current()
            try:
                os.unlink(name, dir_fd=parent)
                return True
            except FileNotFoundError:
                return False
        finally:
            os.close(parent)

    def _lease_file_exists(self, name):
        parent = self._owner_parent()
        if parent is None:
            return False
        try:
            os.stat(name, dir_fd=parent, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False
        finally:
            os.close(parent)


@contextlib.contextmanager
def owner_transaction(
    rd,
    session=None,
    fence=None,
    canonical_id=None,
    expected_slug=None,
    legacy_roots=(),
    account_id=None,
):
    with ordered_lock(coordination_root() / ".owner.lock", "owner") as (parent, lock):
        payload, _ = open_state_parent(payload_path(rd) / "owner.json", create=True)
        try:
            tx = OwnerTransaction(
                rd,
                canonical_id,
                expected_slug,
                legacy_roots,
                parent,
                lock,
                account_id,
                payload,
            )
            if session is not None and not tx.check(session, fence):
                raise ValueError("stale, foreign-account, or missing owner fence")
            _LOCAL.transaction = tx
            try:
                yield tx
            finally:
                _LOCAL.transaction = None
        finally:
            os.close(payload)
