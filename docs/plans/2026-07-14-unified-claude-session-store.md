# Unified Claude Session Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One shared transcript store: `~/.claude-work/{projects,file-history}` become symlinks into `~/.claude/`, with a one-time merge script and an idempotent installer link step.

**Architecture:** A single Python 3 (stdlib-only) CLI, `bin/claude-unify-projects`, with a safe link mode (default) and a copy-then-swap merge mode (`--merge`). The installer calls link mode after `link_claude_config_dir`; a shell test suite drives both modes against fixture trees via root-override flags. Spec: `docs/specs/2026-07-14-unified-claude-session-store.md`.

**Tech Stack:** Python 3 stdlib (`argparse`, `pathlib`, `shutil`, `tarfile`, `json`), bash test suites in the repo's existing `*.test.sh` style, `bin/dotfiles-tests` runner.

## Global Constraints

- No emojis anywhere; log tags are `[OK]`, `[X]`, `[WARNING]`, `[INFO]`.
- No AI attribution in code or commits. Commit format `<scope>: <summary>` (<75 chars, imperative). The word "claude" must appear ONLY in the scope prefix of a commit message, never in the summary body (commit_guard.py blocks it otherwise).
- Unix LF, no spaces in filenames, `#!/usr/bin/env python3` / `#!/usr/bin/env bash` shebangs.
- The script must never touch live roots in tests: every invocation in tests passes `--personal-root` and `--work-root` pointing at a fixture under `mktemp -d`.
- Link mode never moves or deletes data. Merge mode never mutates the work tree except the final rename-to-`.premerge-<ts>` swap.
- Portable across macOS and Linux: no `stat -f`, no GNU-only flags in the test suite.

## File Structure

- Create: `bin/claude-unify-projects` — the CLI (link + merge modes).
- Create: `bin/claude-unify-projects.test.sh` — fixture-based suite for both modes.
- Modify: `install/common/link.sh` — call link mode after `link_claude_config_dir "$HOME"/.claude-work` (line 72); add `~/bin` symlink next to identity-setup (lines 84-85).
- Modify: `bin/dotfiles-tests` — register the new suite in `SUITES`.
- Modify: `install/claude-links.test.sh` — static assertion that the installer runs the link step.
- Modify: `CLAUDE.md` — two entries in the symlink-targets list.

---

### Task 1: `bin/claude-unify-projects` link mode

**Files:**

- Create: `bin/claude-unify-projects`
- Create: `bin/claude-unify-projects.test.sh`
- Modify: `bin/dotfiles-tests` (SUITES block, after `sh install/claude-links.test.sh`)

**Interfaces:**

- Produces: CLI `claude-unify-projects [--personal-root P] [--work-root W] [--backup-dir B] [--merge] [--yes]`. Exit 0 = all trees linked/no-op; exit 1 = at least one tree needs `--merge` or was skipped with a warning. Link mode handles both trees: `projects`, `file-history`.
- Produces (for Task 2-4): module-level constants `TREES = ("projects", "file-history")`, helpers `log(tag, msg)` and `ensure_link(personal, work, name) -> int`.

- [ ] **Step 1: Write the failing test**

Create `bin/claude-unify-projects.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for bin/claude-unify-projects. Fixture trees only -- never live roots.
set -u
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
UNIFY="$SCRIPT_DIR/claude-unify-projects"
pass=0; fail=0
ok()   { echo "[OK] $1"; pass=$((pass+1)); }
bad()  { echo "[X] $1"; fail=$((fail+1)); }
check() { # check <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
fixture() { # fresh personal/work roots; echoes base dir
  local base; base="$(mktemp -d)"
  mkdir -p "$base/personal" "$base/work"
  echo "$base"
}
run_link() { # run_link <base> [extra args...]
  local base="$1"; shift
  python3 "$UNIFY" --personal-root "$base/personal" --work-root "$base/work" "$@"
}

# --- link mode ---
base="$(fixture)"
run_link "$base" >/dev/null 2>&1
check "link: absent work trees become symlinks" test -L "$base/work/projects"
check "link: file-history linked too" test -L "$base/work/file-history"
check "link: canonical dirs created" test -d "$base/personal/projects"
[ "$(readlink "$base/work/projects")" = "$base/personal/projects" ] \
  && ok "link: symlink targets personal root" || bad "link: symlink targets personal root"
run_link "$base" >/dev/null 2>&1 && ok "link: rerun is a no-op (exit 0)" || bad "link: rerun is a no-op (exit 0)"

base="$(fixture)"
mkdir -p "$base/work/projects"           # empty real dir -> converted
run_link "$base" >/dev/null 2>&1
check "link: empty real dir converted" test -L "$base/work/projects"

base="$(fixture)"
mkdir -p "$base/work/projects/-x"; touch "$base/work/projects/-x/a.jsonl"
run_link "$base" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "link: non-empty dir exits non-zero" || bad "link: non-empty dir exits non-zero"
test -d "$base/work/projects" && ! test -L "$base/work/projects" \
  && ok "link: non-empty dir untouched" || bad "link: non-empty dir untouched"

base="$(fixture)"
ln -s "$base/nowhere" "$base/work/projects"   # dangling -> replaced
run_link "$base" >/dev/null 2>&1
[ "$(readlink "$base/work/projects")" = "$base/personal/projects" ] \
  && ok "link: dangling symlink replaced" || bad "link: dangling symlink replaced"

base="$(fixture)"
mkdir -p "$base/elsewhere"; ln -s "$base/elsewhere" "$base/work/projects"
run_link "$base" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ "$(readlink "$base/work/projects")" = "$base/elsewhere" ] \
  && ok "link: foreign live symlink skipped with warning" || bad "link: foreign live symlink skipped with warning"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash bin/claude-unify-projects.test.sh`
Expected: FAIL lines (script does not exist yet), non-zero exit.

- [ ] **Step 3: Implement link mode**

Create `bin/claude-unify-projects` (mode 0755):

```python
#!/usr/bin/env python3
"""claude-unify-projects - one shared Claude Code session store across roots.

Link mode (default): make <work-root>/{projects,file-history} symlinks to
<personal-root>/{projects,file-history}. Safe and idempotent; never moves
data. Exits non-zero if a tree still needs the one-time merge.

Merge mode (--merge): one-time copy-then-swap migration of the work-root
trees into the personal root. Spec:
docs/specs/2026-07-14-unified-claude-session-store.md
"""

import argparse
import os
import sys
from pathlib import Path

TREES = ("projects", "file-history")


def log(tag, msg):
    print(f"[{tag}] {msg}")


def ensure_link(personal: Path, work: Path, name: str) -> int:
    """Return 0 if linked (or already linked), 1 if skipped with a warning."""
    src = (personal / name).resolve()
    dst = work / name
    src.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink():
        if dst.exists() and dst.resolve() == src:
            return 0
        if not dst.exists():  # dangling: safe to replace
            dst.unlink()
        else:
            log("WARNING", f"{dst} is a live symlink to {dst.resolve()}, not touching it")
            return 1
    elif dst.exists():
        if dst.is_dir() and not any(dst.iterdir()):
            dst.rmdir()
        elif dst.is_dir():
            log("WARNING", f"{dst} has content; run claude-unify-projects --merge once")
            return 1
        else:
            log("WARNING", f"{dst} is a regular file, not touching it")
            return 1
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.symlink(src, dst)
    log("OK", f"{dst} -> {src}")
    return 0


def parse_args(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--personal-root", default=os.path.expanduser("~/.claude"))
    ap.add_argument("--work-root", default=os.path.expanduser("~/.claude-work"))
    ap.add_argument("--backup-dir", default=os.path.expanduser("~/tmp"))
    ap.add_argument("--merge", action="store_true")
    ap.add_argument("--yes", action="store_true")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    personal, work = Path(args.personal_root), Path(args.work_root)
    if not work.exists():
        log("INFO", f"{work} missing; nothing to do")
        return 0
    p_res, w_res = personal.resolve(), work.resolve()
    if p_res == w_res or p_res in w_res.parents or w_res in p_res.parents:
        log("X", f"refusing: roots are equal or nested ({p_res} vs {w_res})")
        return 1
    if args.merge:
        rc = merge(personal, work, Path(args.backup_dir), args.yes)
        if rc != 0:
            return rc
    rc = 0
    for name in TREES:
        rc |= ensure_link(personal, work, name)
    return rc


def merge(personal, work, backup_dir, assume_yes):  # implemented in Task 2-4
    log("X", "--merge not implemented yet")
    return 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `bash bin/claude-unify-projects.test.sh`
Expected: all `[OK]`, `N passed, 0 failed`, exit 0.

- [ ] **Step 5: Register the suite and commit**

In `bin/dotfiles-tests`, add to the `SUITES` block after `sh install/claude-links.test.sh`:

```
bash bin/claude-unify-projects.test.sh
```

```bash
chmod +x bin/claude-unify-projects
git add bin/claude-unify-projects bin/claude-unify-projects.test.sh bin/dotfiles-tests
git commit -m "bin: Add session-store unify script (link mode)"
```

---

### Task 2: Merge mode preflight, inventory, and backup

**Files:**

- Modify: `bin/claude-unify-projects` (replace the `merge()` stub)
- Modify: `bin/claude-unify-projects.test.sh` (append merge-preflight cases)

**Interfaces:**

- Consumes: `TREES`, `log`, `parse_args` from Task 1.
- Produces: `take_inventory(root: Path) -> dict` mapping `"<tree>/<rel>"` to `{"size": int, "mtime": float}` for every regular file; `make_backup(personal, work, backup_dir, inv_all) -> Path`; `preflight(personal, work, assume_yes) -> int`. Tasks 3-4 plug `merge_trees` and `swap_and_verify` in after these.

- [ ] **Step 1: Append failing tests**

Append to `bin/claude-unify-projects.test.sh` before the summary lines:

```bash
# --- merge mode: preflight + backup ---
mkfile() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

base="$(fixture)"
mkfile "$base/personal/projects/-p1/s1.jsonl" "personal-s1"
mkfile "$base/work/projects/-p1/s2.jsonl" "work-s2"
mkfile "$base/work/file-history/u1/f1" "fh"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
# Task 2 build: backup happens, merge declares itself incomplete (rc=2) and
# the work tree is untouched. Task 4 Step 1 flips this to expect rc=0.
[ "$rc" -eq 2 ] && ok "merge: incomplete build exits 2 after backup" || bad "merge: incomplete build exits 2 after backup (rc=$rc)"
test -d "$base/work/projects" && ! test -L "$base/work/projects" \
  && ok "merge: incomplete build leaves work tree untouched" || bad "merge: incomplete build leaves work tree untouched"
tarball="$(ls "$base/backups"/claude-projects-backup-*.tar.gz 2>/dev/null | head -1)"
[ -n "$tarball" ] && ok "merge: backup tar created" || bad "merge: backup tar created"
if [ -n "$tarball" ]; then
  perms="$(ls -l "$tarball" | cut -c1-10)"
  [ "$perms" = "-rw-------" ] && ok "merge: backup is 0600" || bad "merge: backup is 0600 ($perms)"
  tar -tzf "$tarball" | grep -q 'claude-work/projects/-p1/s2.jsonl' \
    && ok "merge: tar contains root-distinct paths" || bad "merge: tar contains root-distinct paths"
fi
inv="$(ls "$base/backups"/claude-projects-inventory-*.json 2>/dev/null | head -1)"
if [ -n "$inv" ] && python3 -c "import json; json.load(open('$inv'))" 2>/dev/null; then
  ok "merge: inventory json written"
else
  bad "merge: inventory json written"
fi

base="$(fixture)"
mkfile "$base/work/projects/-p1/s2.jsonl" "w"
run_link "$base" --merge --backup-dir "$base" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "merge: refuses without --yes when stdin is not a tty" \
  || bad "merge: refuses without --yes when stdin is not a tty"
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash bin/claude-unify-projects.test.sh`
Expected: link cases pass, merge cases FAIL (`--merge not implemented yet`).

- [ ] **Step 3: Implement preflight, inventory, backup**

Add `import json`, `import shutil`, `import subprocess`, `import tarfile`, `import time` to the imports, then replace the `merge()` stub with:

```python
def take_inventory(root: Path) -> dict:
    inv = {}
    for tree in TREES:
        base = root / tree
        if not base.is_dir() or base.is_symlink():
            continue
        for p in base.rglob("*"):
            if p.is_file() and not p.is_symlink():
                st = p.stat()
                inv[f"{tree}/{p.relative_to(base)}"] = {"size": st.st_size, "mtime": st.st_mtime}
    return inv


def lsof_busy(paths) -> bool:
    """True if any path has open files, or if lsof is unusable (fail closed)."""
    existing = [str(p) for p in paths if Path(p).is_dir() and not Path(p).is_symlink()]
    if not existing:
        return False
    if shutil.which("lsof") is None:
        log("X", "lsof not found; cannot prove quiescence, refusing")
        return True
    for tree in existing:  # +D recurses one directory; check each tree alone
        r = subprocess.run(["lsof", "+D", tree], capture_output=True, text=True)
        # lsof exits 1 with no output when nothing is open; stdout means busy;
        # any other outcome is indeterminate -> fail closed.
        if r.stdout.strip():
            log("X", f"open files detected under {tree}:")
            print(r.stdout.splitlines()[0])
            return True
        if r.returncode not in (0, 1):
            log("X", f"lsof failed on {tree} (rc={r.returncode}): {r.stderr.strip()[:200]}")
            return True
    return False


def read_cleanup_days(root: Path):
    try:
        return json.load(open(root / "settings.json")).get("cleanupPeriodDays")
    except (OSError, ValueError):
        return None


def preflight(personal: Path, work: Path, assume_yes: bool) -> int:
    trees = [personal / t for t in TREES] + [work / t for t in TREES]
    if lsof_busy(trees):
        log("X", "close ALL Claude Code sessions (both roots), then re-run")
        return 1
    p_days, w_days = read_cleanup_days(personal), read_cleanup_days(work)
    if p_days != w_days:
        log("WARNING", f"cleanupPeriodDays differs (personal={p_days}, work={w_days}); "
            "align them or one root's retention will prune the other's history")
    elif p_days is None:
        log("INFO", "cleanupPeriodDays unset in both roots (platform default applies "
            "to the shared store); pin it in settings.json.tmpl to control retention")
    work_bytes = sum(v["size"] for v in take_inventory(work).values())
    if shutil.disk_usage(personal).free < work_bytes * 2:
        log("X", f"not enough free space on {personal} for the merge copy")
        return 1
    if not assume_yes:
        if not sys.stdin.isatty():
            log("X", "refusing to merge without --yes on non-interactive stdin")
            return 1
        reply = input("Merge work-root session trees into the personal root? [y/N] ")
        if reply.strip().lower() != "y":
            log("INFO", "aborted by user")
            return 1
    return 0


def backup_space_ok(backup_dir: Path, total_bytes: int) -> bool:
    """Tar worst case: no compression; backup_dir may be a different filesystem."""
    backup_dir.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(backup_dir).free < total_bytes:
        log("X", f"not enough free space under {backup_dir} for the backup tar")
        return False
    return True


def make_backup(personal: Path, work: Path, backup_dir: Path, inv_all: dict) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    tar_path = backup_dir / f"claude-projects-backup-{stamp}.tar.gz"
    fd = os.open(tar_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as fh, tarfile.open(fileobj=fh, mode="w:gz") as tar:
        for label, root in (("claude", personal), ("claude-work", work)):
            for tree in TREES:
                src = root / tree
                if src.is_dir() and not src.is_symlink():
                    tar.add(src, arcname=f"{label}/{tree}")
    with tarfile.open(tar_path, "r:gz") as tar:
        tar_files = {m.name for m in tar.getmembers() if m.isfile()}
    if tar_files != set(inv_all):  # exact file-for-file match, both directions
        diff = tar_files.symmetric_difference(inv_all)
        log("X", f"backup validation failed: {len(diff)} mismatched entries, first: {sorted(diff)[0]}")
        tar_path.unlink()
        raise SystemExit(1)
    inv_path = backup_dir / f"claude-projects-inventory-{stamp}.json"
    inv_path.write_text(json.dumps(inv_all, indent=1, sort_keys=True))
    os.chmod(inv_path, 0o600)
    log("OK", f"backup: {tar_path}")
    log("OK", f"inventory: {inv_path}")
    return tar_path


# The two duplicates known when the spec was written; the runtime scan is
# authoritative, these are only an expectation check (spec, Measured state).
EXPECTED_DUPLICATES = (
    "41dfd579-c295-47be-a9c8-daf8b332273c",
    "aaec0865-b3f1-4fa2-87d9-208a2498de6e",
)


def find_duplicates(personal: Path, work: Path) -> list:
    """Session ids whose <id>.jsonl exists in the same encoded-cwd dir in both roots."""
    dups = []
    w_projects, p_projects = work / "projects", personal / "projects"
    if not (w_projects.is_dir() and p_projects.is_dir()):
        return dups
    for w_dir in w_projects.iterdir():
        p_dir = p_projects / w_dir.name
        if not (w_dir.is_dir() and p_dir.is_dir()):
            continue
        for j in w_dir.glob("*.jsonl"):
            if (p_dir / j.name).is_file():
                dups.append(j.stem)
    return dups


def merge(personal: Path, work: Path, backup_dir: Path, assume_yes: bool) -> int:
    if all((work / name).is_symlink() for name in TREES):
        log("INFO", "work-root trees already symlinks; nothing to merge")
        return 0
    for name in TREES:
        if list(work.glob(name + ".premerge-*")):
            log("X", f"stale {name}.premerge-* exists under {work}; resolve it first")
            return 1
    b_res = backup_dir.resolve()
    for root in (personal, work):
        for name in TREES:
            tree = (root / name).resolve()
            if b_res == tree or tree in b_res.parents:
                log("X", f"backup dir {b_res} is inside {tree}; choose another --backup-dir")
                return 1
    rc = preflight(personal, work, assume_yes)
    if rc != 0:
        return rc
    dups = find_duplicates(personal, work)
    if dups:
        log("INFO", f"duplicate session ids to dedupe: {', '.join(sorted(dups))}")
    missing_expected = [d for d in EXPECTED_DUPLICATES if d not in dups]
    if missing_expected and any((personal / "projects").glob("*/" + missing_expected[0] + "*")):
        log("WARNING", "state differs from the spec snapshot "
            f"(expected duplicates not found: {', '.join(missing_expected)}); re-check before proceeding")
    inv_all = {}
    for label, root in (("claude", personal), ("claude-work", work)):
        for key, meta in take_inventory(root).items():
            inv_all[f"{label}/{key}"] = meta
    if not backup_space_ok(backup_dir, sum(v["size"] for v in inv_all.values())):
        return 1
    make_backup(personal, work, backup_dir, inv_all)
    rc = merge_trees(personal, work)                  # Task 3
    if rc != 0:
        return rc
    return swap_and_verify(personal, work, inv_all)   # Task 4
```

Until Tasks 3-4 land, add temporary NON-DESTRUCTIVE stubs so this commit
stands alone: `--merge` performs preflight and backup, then declares itself
incomplete without moving or renaming anything.

```python
def merge_trees(personal, work):
    log("WARNING", "merge incomplete in this build: tree merge not implemented yet")
    return 2


def swap_and_verify(personal, work, inv_all):
    raise AssertionError("unreachable until merge_trees is implemented")
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `bash bin/claude-unify-projects.test.sh`
Expected: all cases pass (merge fixture: backup created, swap stub renames, `ensure_link` links).

- [ ] **Step 5: Commit**

```bash
git add bin/claude-unify-projects bin/claude-unify-projects.test.sh
git commit -m "bin: Add merge preflight, inventory, and backup to unify script"
```

---

### Task 3: Merge logic — collisions, memory union, file-history

**Files:**

- Modify: `bin/claude-unify-projects` (replace the `merge_trees` stub)
- Modify: `bin/claude-unify-projects.test.sh` (append collision cases)

**Interfaces:**

- Consumes: `TREES`, `log`.
- Produces: `merge_trees(personal, work) -> int` and module-level `REPORT = {"dedupe_losers": [], "conflicts": [], "renamed": []}` (lists of absolute-path strings; `dedupe_losers` entries are `"personal:<abs>"` / `"work:<abs>"`), consumed by Task 4's verify/report.

- [ ] **Step 1: Append failing tests**

Append to `bin/claude-unify-projects.test.sh` before the summary lines:

```bash
# --- merge mode: collisions, memory union, file-history ---
base="$(fixture)"
# duplicated session: work copy larger -> work wins
mkfile "$base/personal/projects/-p1/dup.jsonl" "short"
mkfile "$base/work/projects/-p1/dup.jsonl" "longer-content-wins"
mkfile "$base/personal/projects/-p1/dup/sidecar.txt" "personal-sidecar"
mkfile "$base/work/projects/-p1/dup/sidecar.txt" "work-sidecar"
mkfile "$base/personal/file-history/dup/cp1" "personal-fh"
mkfile "$base/work/file-history/dup/cp1" "work-fh"
# identical twins -> personal kept (distinguishable via their sidecars)
mkfile "$base/personal/projects/-p1/same.jsonl" "identical"
mkfile "$base/work/projects/-p1/same.jsonl" "identical"
mkfile "$base/personal/projects/-p1/same/tag.txt" "personal-side"
mkfile "$base/work/projects/-p1/same/tag.txt" "work-side"
# work-only session INSIDE an overlapping project dir: sidecar must survive
mkfile "$base/work/projects/-p1/wonly.jsonl" "work-only-session"
mkfile "$base/work/projects/-p1/wonly/state.txt" "work-only-sidecar"
# memory: distinct files union; same-name different content -> newer wins
mkfile "$base/personal/projects/-p1/memory/MEMORY.md" "# Memory Index

- [Alpha](alpha.md) - a
"
mkfile "$base/personal/projects/-p1/memory/alpha.md" "alpha"
mkfile "$base/work/projects/-p1/memory/MEMORY.md" "# Memory Index

- [Alpha](alpha.md) - a
- [Beta](beta.md) - b
"
mkfile "$base/work/projects/-p1/memory/beta.md" "beta"
mkfile "$base/work/projects/-p1/memory/alpha.md" "alpha-work-newer"
touch -t 203001010000 "$base/work/projects/-p1/memory/alpha.md"
# work-only project dir and file-history id
mkfile "$base/work/projects/-only/w1.jsonl" "work-only"
mkfile "$base/work/file-history/workonly/cp" "fh-work-only"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
# Task 3 build: trees merge but swap is still stubbed (rc=2); Task 4 Step 1
# flips this to expect rc=0.
[ "$rc" -eq 2 ] && ok "merge: task-3 build exits 2 after tree merge" || bad "merge: task-3 build exits 2 after tree merge (rc=$rc)"
P="$base/personal/projects/-p1"
[ "$(cat "$P/dup.jsonl")" = "longer-content-wins" ] && ok "merge: larger jsonl wins" || bad "merge: larger jsonl wins"
[ "$(cat "$P/same/tag.txt")" = "personal-side" ] && ok "merge: identical twin keeps personal sidecar" || bad "merge: identical twin keeps personal sidecar"
[ "$(cat "$P/wonly/state.txt")" = "work-only-sidecar" ] && ok "merge: work-only session sidecar survives" || bad "merge: work-only session sidecar survives"
[ "$(cat "$P/dup/sidecar.txt")" = "work-sidecar" ] && ok "merge: sidecar follows winner" || bad "merge: sidecar follows winner"
[ "$(cat "$base/personal/file-history/dup/cp1")" = "work-fh" ] && ok "merge: file-history follows winner" || bad "merge: file-history follows winner"
[ "$(cat "$P/same.jsonl")" = "identical" ] && ok "merge: identical twin kept once" || bad "merge: identical twin kept once"
[ "$(cat "$P/memory/alpha.md")" = "alpha-work-newer" ] && ok "merge: newer memory fact wins" || bad "merge: newer memory fact wins"
test -f "$P/memory/alpha.md.conflict-personal.md" && ok "merge: losing memory fact preserved" || bad "merge: losing memory fact preserved"
[ "$(cat "$P/memory/beta.md")" = "beta" ] && ok "merge: work-only memory fact copied" || bad "merge: work-only memory fact copied"
grep -q 'Beta' "$P/memory/MEMORY.md" && ok "merge: MEMORY.md gained work-only line" || bad "merge: MEMORY.md gained work-only line"
[ "$(grep -c 'Alpha' "$P/memory/MEMORY.md")" = "1" ] && ok "merge: MEMORY.md lines deduped" || bad "merge: MEMORY.md lines deduped"
test -f "$P/memory/MEMORY.md.conflict-work.md" && ok "merge: work MEMORY.md preserved" || bad "merge: work MEMORY.md preserved"
test -f "$base/personal/projects/-only/w1.jsonl" && ok "merge: work-only project copied" || bad "merge: work-only project copied"
test -f "$base/personal/file-history/workonly/cp" && ok "merge: work-only file-history copied" || bad "merge: work-only file-history copied"
test -d "$base/work/projects" && ! test -L "$base/work/projects" \
  && ok "merge: task-3 build leaves work tree untouched" || bad "merge: task-3 build leaves work tree untouched"
```

(The symlink-swap and premerge-kept assertions belong to Task 4, which
implements the swap.)

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash bin/claude-unify-projects.test.sh`
Expected: the new collision cases FAIL (stub copies nothing); earlier cases pass.

- [ ] **Step 3: Implement `merge_trees`**

Replace the `merge_trees` stub:

```python
# dedupe_losers/moved hold "personal:<abs>" / "work:<abs>" origin strings;
# conflicts holds destination paths whose content was merged or replaced in
# place (original preserved as .conflict-*); renamed holds new .from-work paths.
REPORT = {"dedupe_losers": [], "conflicts": [], "renamed": [], "moved": []}


def conflict_path(base_dir: Path, name: str) -> Path:
    """First non-existing of <name>, <name>.2, <name>.3 ... (rerun safety)."""
    cand = base_dir / name
    n = 2
    while cand.exists():
        cand = base_dir / f"{name}.{n}"
        n += 1
    return cand


def jsonl_winner(p: Path, w: Path) -> Path:
    """R3: larger wins; equal size + identical bytes -> personal; else newer mtime."""
    ps, ws = p.stat().st_size, w.stat().st_size
    if ws != ps:
        return w if ws > ps else p
    if p.read_bytes() == w.read_bytes():
        return p
    return w if w.stat().st_mtime > p.stat().st_mtime else p


def copy_any(src: Path, dst: Path):
    if src.is_dir():
        shutil.copytree(src, dst, symlinks=True)
    else:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)


def merge_memory(p_mem: Path, w_mem: Path):
    """File-level union, recursive; newer wins on conflict, loser kept as .conflict-*."""
    for wf in sorted(w_mem.iterdir()):
        pf = p_mem / wf.name
        if wf.is_dir():
            if pf.is_dir():
                merge_memory(pf, wf)
            elif not pf.exists():
                shutil.copytree(wf, pf, symlinks=True)
            else:
                REPORT["conflicts"].append(str(pf))
            continue
        if not pf.exists():
            shutil.copy2(wf, pf)
            continue
        if pf.read_bytes() == wf.read_bytes():
            continue
        if wf.name == "MEMORY.md":
            p_lines = pf.read_text().splitlines()
            seen = {ln.strip() for ln in p_lines}
            extra = [ln for ln in wf.read_text().splitlines()
                     if ln.strip() and ln.strip() not in seen]
            if extra:
                pf.write_text("\n".join(p_lines + extra) + "\n")
            shutil.copy2(wf, conflict_path(p_mem, "MEMORY.md.conflict-work.md"))
            REPORT["conflicts"].append(str(pf))
            continue
        work_wins = wf.stat().st_mtime >= pf.stat().st_mtime
        loser_tag = "personal" if work_wins else "work"
        loser_src = pf if work_wins else wf
        shutil.copy2(loser_src, conflict_path(p_mem, f"{wf.name}.conflict-{loser_tag}.md"))
        if work_wins:
            shutil.copy2(wf, pf)
        REPORT["conflicts"].append(str(pf))


def merge_trees(personal: Path, work: Path) -> int:
    w_projects, p_projects = work / "projects", personal / "projects"
    w_fh, p_fh = work / "file-history", personal / "file-history"
    p_projects.mkdir(parents=True, exist_ok=True)
    p_fh.mkdir(parents=True, exist_ok=True)
    fh_decided = set()  # ids whose file-history side followed a transcript winner

    work_dirs = sorted(d for d in w_projects.iterdir() if d.is_dir()) if w_projects.is_dir() else []
    for w_dir in work_dirs:
        p_dir = p_projects / w_dir.name
        if not p_dir.exists():
            copy_any(w_dir, p_dir)
            continue
        for entry in sorted(w_dir.iterdir()):
            target = p_dir / entry.name
            if entry.name == "memory" and entry.is_dir():
                if target.is_dir():
                    merge_memory(target, entry)
                else:
                    copy_any(entry, target)
                continue
            if entry.is_dir() and (w_dir / (entry.name + ".jsonl")).exists() \
                    and (p_dir / (entry.name + ".jsonl")).exists():
                continue  # COLLIDING session's sidecar: handled with its transcript;
                          # a work-only session's sidecar falls through and is copied
            if not target.exists():
                copy_any(entry, target)
                continue
            if entry.suffix == ".jsonl" and entry.is_file() and target.is_file():
                sid = entry.stem
                win = jsonl_winner(target, entry)
                fh_decided.add(sid)
                if win is entry:  # work wins: transcript, sidecar, file-history
                    for lp in (target, p_dir / sid, p_fh / sid):
                        REPORT["dedupe_losers"].append(f"personal:{lp}")
                    shutil.copy2(entry, target)
                    for pair_src, pair_dst in ((w_dir / sid, p_dir / sid), (w_fh / sid, p_fh / sid)):
                        if pair_src.is_dir():
                            # copy to a temp sibling first so an interruption
                            # never leaves the destination half-deleted
                            tmp = pair_dst.with_name(pair_dst.name + ".tmp-merge")
                            if tmp.exists():
                                shutil.rmtree(tmp)
                            copy_any(pair_src, tmp)
                            if pair_dst.is_dir():
                                shutil.rmtree(pair_dst)
                            tmp.rename(pair_dst)
                else:
                    for lp in (entry, w_dir / sid, w_fh / sid):
                        REPORT["dedupe_losers"].append(f"work:{lp}")
                continue
            renamed = conflict_path(p_dir, entry.name + ".from-work")
            copy_any(entry, renamed)
            REPORT["renamed"].append(str(renamed))
            REPORT["moved"].append(f"work:{entry}")
            log("WARNING", f"unexpected collision, kept both: {renamed}")

    if w_fh.is_dir():
        for w_id in sorted(d for d in w_fh.iterdir() if d.is_dir()):
            if w_id.name in fh_decided:
                continue
            p_id = p_fh / w_id.name
            if not p_id.exists():
                copy_any(w_id, p_id)
            else:
                # both roots have this id without a transcript collision
                # (unexpected): keep personal, preserve the work copy alongside
                kept = conflict_path(p_fh, w_id.name + ".from-work")
                copy_any(w_id, kept)
                REPORT["renamed"].append(str(kept))
                REPORT["moved"].append(f"work:{w_id}")
                log("WARNING", f"divergent file-history without transcript collision: kept both ({kept})")
    return 0
```

Placement note: `REPORT` and these functions go ABOVE `merge()` in the file;
delete the Task 2 `merge_trees` stub. Keep `swap_and_verify` stubbed, but
replace its body so the Task 3 build stays non-destructive and testable:

```python
def swap_and_verify(personal, work, inv_all):
    log("WARNING", "merge incomplete in this build: swap/verify not implemented yet")
    return 2
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `bash bin/claude-unify-projects.test.sh`
Expected: all pass. (The sidecar of a personal-winning twin stays personal because the work sidecar dir is skipped via the `.jsonl`-companion guard, and the work jsonl loser is simply not copied.)

- [ ] **Step 5: Commit**

```bash
git add bin/claude-unify-projects bin/claude-unify-projects.test.sh
git commit -m "bin: Add collision, memory-union, and file-history merge rules"
```

---

### Task 4: Swap guard, verification, report

**Files:**

- Modify: `bin/claude-unify-projects` (replace the `swap_and_verify` stub)
- Modify: `bin/claude-unify-projects.test.sh` (append verify cases)

**Interfaces:**

- Consumes: `REPORT`, `TREES`, `ensure_link`, `inv_all` (keys `claude/<tree>/<rel>` and `claude-work/<tree>/<rel>`).
- Produces: `swap_and_verify(personal, work, inv_all) -> int`; exit 0 only when every inventoried file is accounted for.

- [ ] **Step 1: Update earlier expectations and append failing tests**

Task 4 completes `--merge`, so first FLIP the interim expectations from
Tasks 2-3 in `bin/claude-unify-projects.test.sh`:

- Task 2 block: change `[ "$rc" -eq 2 ]` to `[ "$rc" -eq 0 ]` (label:
  "merge: complete run exits 0 after backup") and replace the
  "incomplete build leaves work tree untouched" assertion with
  `test -L "$base/work/projects"` ("merge: work projects swapped to symlink").
- Task 3 block: change `[ "$rc" -eq 2 ]` to `[ "$rc" -eq 0 ]` and replace the
  "task-3 build leaves work tree untouched" assertion with two: `test -L
"$base/work/projects"` and `ls -d "$base/work/projects.premerge-"*`
  ("merge: premerge tree kept").

Then append before the summary lines:

```bash
# --- merge mode: swap guard + verify ---
base="$(fixture)"
mkfile "$base/work/projects/-p1/a.jsonl" "a"
mkdir -p "$base/work/projects.premerge-20260101-000000"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "merge: stale premerge dir aborts" || bad "merge: stale premerge dir aborts"
test -d "$base/work/projects" && ! test -L "$base/work/projects" \
  && ok "merge: aborted run leaves work tree untouched" || bad "merge: aborted run leaves work tree untouched"

base="$(fixture)"
mkfile "$base/work/projects/-p1/a.jsonl" "a"
mkfile "$base/personal/projects/-p2/b.jsonl" "b"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1 \
  && ok "merge: verify passes on clean merge" || bad "merge: verify passes on clean merge"
test -f "$base/work/projects/-p2/b.jsonl" \
  && ok "verify: personal file reachable via work path" || bad "verify: personal file reachable via work path"
test -f "$base/work/projects/-p1/a.jsonl" \
  && ok "verify: work file reachable via work path post-swap" || bad "verify: work file reachable via work path post-swap"
run_link "$base" >/dev/null 2>&1 && ok "merge: link mode no-op after merge" || bad "merge: link mode no-op after merge"
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `bash bin/claude-unify-projects.test.sh`
Expected: "stale premerge dir aborts" FAILS (the Task 2 stub renames unconditionally and never checks).

- [ ] **Step 3: Implement `swap_and_verify`**

(The stale-premerge guard already runs at the top of `merge()`, before any
mutation — Task 2 put it there.) Replace the `swap_and_verify` stub:

```python
def swap_and_verify(personal: Path, work: Path, inv_all: dict) -> int:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    swapped = []
    try:
        for name in TREES:
            src = work / name
            if src.is_dir() and not src.is_symlink():
                src.rename(work / f"{name}.premerge-{stamp}")
                swapped.append(name)
            if ensure_link(personal, work, name) != 0:
                raise RuntimeError(f"could not link {work / name}")
    except (OSError, RuntimeError) as exc:
        log("X", f"swap failed ({exc}); rolling back the work root")
        for name in reversed(swapped):
            dst = work / name
            if dst.is_symlink():
                dst.unlink()
            (work / f"{name}.premerge-{stamp}").rename(dst)
        return 1

    loser_paths = {p.split(":", 1)[1] for p in REPORT["dedupe_losers"] + REPORT["moved"]}
    changed = set(REPORT["conflicts"])

    def excused(origin: str) -> bool:
        # dedupe losers and .from-work moves are dirs or files whose ORIGINAL
        # path legitimately has no counterpart; children of a losing dir too
        return any(origin == lp or origin.startswith(lp + "/") for lp in loser_paths)

    missing = []
    for key, meta in inv_all.items():
        label, rel = key.split("/", 1)  # label: claude|claude-work; rel: <tree>/<relpath>
        origin_root = personal if label == "claude" else work
        if excused(str(origin_root / rel)):
            continue
        merged_path = personal / rel      # post-swap, both roots resolve here
        via_work = work / rel
        if not merged_path.is_file() or not via_work.is_file():
            missing.append(f"{key} (unreachable at {merged_path} / {via_work})")
            continue
        if str(merged_path) in changed:
            continue  # merged or conflict-replaced in place; original kept as .conflict-*
        if merged_path.stat().st_size != meta["size"]:
            missing.append(f"{key} (size {merged_path.stat().st_size} != inventoried {meta['size']})")
    if missing:
        log("X", f"verify failed; {len(missing)} pre-merge files unaccounted for, first: {missing[0]}")
        return 1

    for name in TREES:
        if Path(os.readlink(work / name)).resolve() != (personal / name).resolve():
            log("X", f"{work / name} does not resolve to {personal / name}")
            return 1

    log("OK", "verify passed: every pre-merge file reachable via both roots")
    if REPORT["dedupe_losers"]:
        log("INFO", "deduped (loser in backup only): " + ", ".join(REPORT["dedupe_losers"]))
    if REPORT["conflicts"]:
        log("WARNING", "conflicts preserved for manual review: " + ", ".join(REPORT["conflicts"]))
    if REPORT["renamed"]:
        log("WARNING", "unexpected collisions kept as .from-work: " + ", ".join(REPORT["renamed"]))
    log("INFO", f"after a /resume and /rewind spot check, delete {work}/*.premerge-{stamp}")
    return 0
```

Correctness notes the implementer must preserve:

- Task 3 records the WHOLE losing side (transcript, sidecar dir,
  file-history dir) in `REPORT["dedupe_losers"]`, and `.from-work` origins
  in `REPORT["moved"]`; `excused()` covers exact matches and children.
- The size check is skipped for paths in `REPORT["conflicts"]` — those were
  merged or replaced in place (MEMORY.md union, newer-wins facts) and their
  originals live on as `.conflict-*` files.

- [ ] **Step 4: Run the full suite, verify green**

Run: `bash bin/claude-unify-projects.test.sh`
Expected: all pass, including Task 3 cases (the winner-side sidecar/file-history survive verification because the losing side's paths are excused).

- [ ] **Step 5: Commit**

```bash
git add bin/claude-unify-projects bin/claude-unify-projects.test.sh
git commit -m "bin: Add swap guard and inventory-based merge verification"
```

---

### Task 5: Installer integration, shape check, docs

**Files:**

- Modify: `install/common/link.sh` (after line 72 `link_claude_config_dir "$HOME"/.claude-work`; and the `~/bin` block at lines 84-85)
- Modify: `install/claude-links.test.sh` (static assertion; read the file first and reuse its existing pass/fail helper names)
- Modify: `CLAUDE.md` (symlink-targets list)

**Interfaces:**

- Consumes: `bin/claude-unify-projects` link-mode CLI (non-zero exit tolerated by the installer).

- [ ] **Step 1: Add the failing static test**

In `install/claude-links.test.sh`, append an assertion in that suite's existing style (its helpers may be named differently — mirror the neighboring checks):

```bash
if grep -q '"\$DOTFILEDIR"/bin/claude-unify-projects' install/common/link.sh; then
  echo "[OK] link.sh runs the session-store link step"; pass=$((pass+1))
else
  echo "[X] link.sh runs the session-store link step"; fail=$((fail+1))
fi
if grep -q 'claude-unify-projects "\$HOME"/bin/claude-unify-projects' install/common/link.sh; then
  echo "[OK] link.sh installs claude-unify-projects into ~/bin"; pass=$((pass+1))
else
  echo "[X] link.sh installs claude-unify-projects into ~/bin"; fail=$((fail+1))
fi
```

- [ ] **Step 2: Run to verify it fails**

Run: `sh install/claude-links.test.sh`
Expected: the new assertion FAILS, suite exits non-zero.

- [ ] **Step 3: Wire the installer**

In `install/common/link.sh`, insert after line 72:

```bash
# Unified session store: ~/.claude-work/{projects,file-history} are symlinks
# into ~/.claude so /resume and /rewind see every session from either root.
# Link mode never moves data; on an unmigrated machine it warns and points
# at `claude-unify-projects --merge` (one-time, run with no live sessions).
"$DOTFILEDIR"/bin/claude-unify-projects \
  || echo "[link] session store not unified yet; see warning above"
```

Next to the identity-setup links (lines 84-85), add:

```bash
ln -sf "$DOTFILEDIR"/bin/claude-unify-projects "$HOME"/bin/claude-unify-projects
```

- [ ] **Step 4: Docs**

In `CLAUDE.md`, in the "Symlink targets" list after the `claude/rules/` entry, add:

```markdown
- `~/.claude-work/projects`, `~/.claude-work/file-history` -> symlinks to the
  same paths under `~/.claude` (unified session store: `/resume` and
  `/rewind` see every session from either config root). Created idempotently
  by `bin/claude-unify-projects` (link mode) on every install/update run; an
  existing machine with real work-side trees runs `claude-unify-projects
--merge` ONCE (backs up both trees, merges with collision rules, swaps; no
  live sessions allowed). See
  `docs/specs/2026-07-14-unified-claude-session-store.md`.
```

- [ ] **Step 5: Run everything, verify green, commit**

Run: `bin/dotfiles-tests`
Expected: all suites pass, including `bin/claude-unify-projects.test.sh` and `install/claude-links.test.sh`.

```bash
git add install/common/link.sh install/claude-links.test.sh CLAUDE.md
git commit -m "install: Link unified session store on install and update"
```

---

## Post-merge operational runbook (NOT part of the repo change)

Executed manually on this machine after the PR merges, per the spec's
Operational constraints:

1. Close ALL Claude Code sessions (both roots, IDE and terminal).
2. From a plain terminal: `~/bin/claude-unify-projects --merge`
   (interactive confirm; `--yes` only if scripted).
3. Spot-check `/resume` from both roots in `~/Git/work/rw-bess`, `/rewind`
   in a cross-root resumed session, and that auto-memory loads.
4. After the spot check: delete the `*.premerge-*` trees; keep the backup
   tar until comfortable.
