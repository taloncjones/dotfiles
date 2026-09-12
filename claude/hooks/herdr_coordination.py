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
            try:
                rec = _read_at(parent, name)
            except (ValueError, OSError):
                continue
            if rec is not None and _valid_lead_lease(rec):
                leases.append(rec)
    finally:
        os.close(parent)
    return leases


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
            return json.load(stream)
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
        and math.isfinite(value["heartbeat_ts"])
        and value["heartbeat_ts"] >= 0
        and value.get("runtime", "claude") in ("claude", "codex")
        and (value.get("thread_id") is None or isinstance(value["thread_id"], str))
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


def _valid_lead_lease(rec):
    return (
        _valid_owner(rec)
        and type(rec.get("schema_version")) is int
        and rec["schema_version"] == 1
        and rec.get("control_tier") == "lead"
        and isinstance(rec.get("binding_id"), str)
        and bool(_BINDING_ID.fullmatch(rec["binding_id"]))
    )


def _owner_metadata(value):
    result = {
        key: value[key]
        for key in ("session_id", "host", "pid", "fence", "heartbeat_ts")
    }
    return dict(
        result,
        runtime=value.get("runtime", "claude"),
        thread_id=value.get("thread_id"),
        account_id=value.get("account_id"),
        control_tier=value.get("control_tier", "launcher"),
        workspace_root=value.get("workspace_root"),
    )


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
            bindings = {}
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
        self._owner_write(self.current)
        return fence

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
        if old is None and key in seen:
            # Symmetric to owner_initialized on the slug lease: a lease that
            # has existed must not silently restart at fence 1, or an old
            # fence becomes valid again after the file is deleted or nulled.
            raise ValueError(
                "initialized lead lease is missing; explicit recovery required"
            )
        if old is not None and not _valid_lead_lease(old):
            raise ValueError("corrupt lead lease; explicit recovery required")
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
        fence = old["fence"] + 1 if old else 1
        if key not in seen:
            updated = dict(self.bindings[self.slug], lead_seen=sorted({*seen, key}))
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
        return (
            type(fence) is int
            and lease is not None
            and _valid_lead_lease(lease)
            and lease["session_id"] == session
            and lease["fence"] == fence
            and lease.get("account_id") == self.account_id
            # Pin the fence to its binding generation: a successor lead on
            # the same workspace must not authorize under a predecessor's
            # still-claimed binding.
            and (binding_id is None or lease["binding_id"] == binding_id)
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
