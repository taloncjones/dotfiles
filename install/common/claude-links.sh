#!/usr/bin/env bash
# claude-links.sh - Shared Claude Code config-dir linking functions
#
# Sourced (not executed) by install/common/link.sh for full machine installs
# and by bootstrap-cloud.sh for ephemeral cloud containers. Defines functions
# only; callers decide which config dirs to link.
#
# Requires: DOTFILEDIR must be set before calling the functions.

# Retired Claude plugins, keyed by plugin id. The settings reconcile and
# sweep_retired_claude_plugins both read this one table. `marketplace` is
# removed with the plugin; the shared official marketplace is not.
RETIRED_CLAUDE_PLUGINS_JSON='{
  "ecc@ecc": {"marketplace": "ecc", "cache": "cache/ecc",
              "source": "https://github.com/affaan-m/ECC.git"},
  "superpowers@claude-plugins-official": {"cache": "cache/claude-plugins-official/superpowers",
              "source": "https://github.com/obra/superpowers.git"}
}'

# Seed a machine-local file from a template, with defensive symlink + size guards.
# Why this exists: the destination is intended to be a real file (Claude/plugin
# installers write into it), but earlier dotfiles installs symlinked it to a repo
# path. If that repo moves or is deleted, the symlink dangles silently. Worse,
# if the symlink is intact, Claude CLI writes through the symlink and pollutes
# the dotfiles repo with machine-local state.
#   1. rm -f any pre-existing symlink at the destination. The [ -L ] guard
#      below is what protects real files — rm -f happily removes regular
#      files too; the only thing -f does is suppress "no such file" errors.
#   2. cp template if no regular file exists.
#   3. Warn if the existing file is suspiciously small (<50% of template size),
#      which usually means a prior corruption (e.g. Claude CLI rewrote the file
#      from scratch through a stale symlink, dropping plugin/hook config).
seed_machine_local_file() {
  local template="$1"
  local dest="$2"

  if [ -L "$dest" ]; then
    echo "[claude-links] Removing pre-existing symlink at $dest (machine-local file expected)"
    rm -f "$dest"
  fi

  if [ ! -f "$dest" ]; then
    cp "$template" "$dest"
    return
  fi

  local tmpl_size dest_size
  tmpl_size=$(wc -c <"$template" 2>/dev/null | tr -d ' ')
  dest_size=$(wc -c <"$dest" 2>/dev/null | tr -d ' ')
  if [ -n "$tmpl_size" ] && [ -n "$dest_size" ] && [ "$tmpl_size" -gt 0 ]; then
    if [ "$(( dest_size * 2 ))" -lt "$tmpl_size" ]; then
      echo "[claude-links] WARNING: $dest is ${dest_size}B but template is ${tmpl_size}B."
      echo "[claude-links]          Existing file may be corrupted (prior install wrote through a stale symlink)."
      echo "[claude-links]          Re-seed manually: rm $dest && cp $template $dest"
    fi
  fi
}

# Reconcile a machine-local settings.json with the tracked template.
#
# seed_machine_local_file copies the template only when the destination is
# ABSENT, so template changes never reach an existing settings.json on their
# own (seed-once design). This merge closes that gap and is safe to run on
# every install/update:
#   - template-owned keys (hooks, statusLine, permissions, env, model, promptSuggestionEnabled, ...) come from
#     the template -- template drift is reconciled away;
#   - plugin-installer-owned keys (enabledPlugins, extraKnownMarketplaces) are
#     unioned with live state winning on conflict, so nothing an installer
#     wrote is lost;
#   - retired plugins (RETIRED_CLAUDE_PLUGINS_JSON) are pinned off while still registered and dropped once gone, their marketplaces dropped, and their env keys (RETIRED_ENV_KEYS) swept;
#   - keys the template does not define are preserved as-is.
# A corrupt/unparseable destination is rebuilt from the template. Idempotent.
# History: the merge logic originated in bootstrap-cloud.sh (910f2bc), which
# now delegates here; machines get the same treatment on every `update`.
# Usage: reconcile_claude_settings_file <template> <dest> [label]
reconcile_claude_settings_file() {
  local tmpl="$1"
  local dest="$2"
  local label="${3:-[claude-links]}"

  if [ ! -f "$tmpl" ]; then
    echo "$label WARNING: settings template missing at $tmpl; skipping reconcile." >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "$label WARNING: python3 not on PATH; cannot reconcile settings.json." >&2
    echo "$label          Template changes must be merged into $dest by hand." >&2
    return 1
  fi

  RECONCILE_LABEL="$label" RETIRED_CLAUDE_PLUGINS_JSON="$RETIRED_CLAUDE_PLUGINS_JSON" \
    python3 - "$tmpl" "$dest" <<'PY'
import json, os, sys

label = os.environ.get("RECONCILE_LABEL", "[claude-links]")
tmpl_path, dest_path = sys.argv[1], sys.argv[2]
with open(tmpl_path) as fh:
    tmpl = json.load(fh)

dest = {}
if os.path.isfile(dest_path) and os.path.getsize(dest_path):
    try:
        with open(dest_path) as fh:
            dest = json.load(fh)
    except json.JSONDecodeError:
        dest = {}  # corrupt/partial -- the template rebuild below is authoritative

# Keys the plugin installers own: union them so installed plugins/marketplaces
# survive (live state wins on conflict). Everything else comes from the template.
PLUGIN_KEYS = ("enabledPlugins", "extraKnownMarketplaces")
result = dict(tmpl)
for key in PLUGIN_KEYS:
    merged = dict(tmpl.get(key, {}))
    merged.update(dest.get(key, {}))
    if merged:
        result[key] = merged

# Keep account-local environment additions instead of dropping them whenever a
# tracked template changes.
env = {}
existing_env = dest.get("env", {})
if isinstance(existing_env, dict):
    env.update(existing_env)
env.update(tmpl.get("env", {}))

# env is a union, so dropping a key from the template would otherwise leave it
# set on every machine that already has it. Model aliases must stay un-pinned:
# ANTHROPIC_DEFAULT_<FAMILY>_MODEL takes a concrete model ID, so a stale one
# strands the machine on a retired model instead of tracking the newest release.
for key in [k for k in env if k.startswith("ANTHROPIC_DEFAULT_") and k.endswith("_MODEL")]:
    if key not in tmpl.get("env", {}):
        del env[key]

# Retired plugins: declared here (ahead of the env sweep below, which needs
# the name list) because enabledPlugins/extraKnownMarketplaces are unions
# where live state wins, so dropping a plugin from the template alone would
# leave it enabled on every machine that had it. Force it off and stop
# refreshing its marketplace; `<name>-uninstall` removes the files.
RETIRED = json.loads(os.environ["RETIRED_CLAUDE_PLUGINS_JSON"])
RETIRED_PLUGINS = tuple(RETIRED)
RETIRED_MARKETPLACES = tuple(e["marketplace"] for e in RETIRED.values() if "marketplace" in e)
# Only ECC carries isolation env keys, so only an installed ECC may hold them.
RETIRED_ENV_OWNERS = ("ecc@ecc",)

# Env keys of retired plugins are swept the same way, but only once the
# plugin they isolate is actually gone from THIS config dir. Disabling
# ecc@ecc in enabledPlugins does not uninstall it -- Claude Code leaves the
# plugin (and any project-level override that re-enables it) in
# plugins/installed_plugins.json until `ecc-uninstall` runs. Sweeping the
# isolation env keys ahead of that removal would strip ECC_DISABLED_HOOKS
# and ECC_AGENT_DATA_HOME from a machine where ECC can still load, sending
# its state through the wrong account. An explicit key list, not a prefix:
# the ECC-derived git hooks still read ECC_SKIP_* and ECC_PREPUSH_AUDIT, and
# a machine-local value of those must survive.
RETIRED_ENV_KEYS = ("ECC_CONTEXT_MONITOR_COST_WARNINGS", "ECC_DISABLED_HOOKS", "ECC_AGENT_DATA_HOME",
                    "ECC_PLAN_CANVAS_STATE_DIR", "GATEGUARD_BASH_ROUTINE_DISABLED",
                    "GATEGUARD_EXEMPT_GLOBS")
installed_plugins_path = os.path.join(os.path.dirname(os.path.abspath(dest_path)), "plugins", "installed_plugins.json")
installed_names = set()
# Same validity rule as sweep_retired_claude_plugins. Unreadable means every
# retired plugin may still be there: keep them pinned off and keep ECC's
# isolation keys rather than act on a guess.
try:
    if os.path.lexists(installed_plugins_path):
        if os.path.islink(installed_plugins_path):
            raise ValueError("symlinked registry")
        with open(installed_plugins_path) as fh:
            installed = json.load(fh)
        plugins = installed.get("plugins", {}) if isinstance(installed, dict) else None
        if not (isinstance(plugins, dict) and all(
                isinstance(recs, list) and all(isinstance(r, dict) for r in recs) for recs in plugins.values())):
            raise ValueError("unexpected registry shape")
        installed_names = set(plugins)
    # A known retired marketplace can still offer its plugin, so it counts
    # as installed too -- the same evidence the sweep uses.
    known_path = os.path.join(os.path.dirname(installed_plugins_path), "known_marketplaces.json")
    if os.path.lexists(known_path):
        with open(known_path) as fh:
            known = json.load(fh)
        if not isinstance(known, dict):
            raise ValueError("unexpected known_marketplaces shape")
        installed_names |= {p for p, e in RETIRED.items() if e.get("marketplace") in known}
except (OSError, ValueError):
    installed_names = set(RETIRED_PLUGINS)
retired_plugins_still_installed = bool(installed_names & set(RETIRED_ENV_OWNERS))
if retired_plugins_still_installed:
    # A corrupt or empty dest (handled above by falling back to {}) has no
    # existing env to inherit these keys from, and the template no longer
    # carries them either, so the union above leaves them silently absent
    # even though the plugin can still load. Restore the last known-good
    # values so a settings.json rebuild cannot drop isolation out from under
    # a still-installed plugin. `{{CLAUDE_CONFIG_DIR}}` is resolved to this
    # dest's own config dir; live values already in env are left untouched.
    RETIRED_ENV_RESCUE_DEFAULTS = {
        "ECC_CONTEXT_MONITOR_COST_WARNINGS": "0",
        "ECC_DISABLED_HOOKS": "session-start:plan-canvas-sessions,stop:plan-canvas-pending,"
                               "post:bash:command-log-audit,post:bash:command-log-cost,"
                               "post:skill:track,pre:mcp-health-check,post:mcp-health-check",
        "ECC_AGENT_DATA_HOME": "{{CLAUDE_CONFIG_DIR}}",
        "ECC_PLAN_CANVAS_STATE_DIR": "{{CLAUDE_CONFIG_DIR}}/plan-canvas",
        "GATEGUARD_BASH_ROUTINE_DISABLED": "1",
        "GATEGUARD_EXEMPT_GLOBS": "/**",
    }
    config_dir = os.path.dirname(os.path.abspath(dest_path))
    restored = []
    for key in RETIRED_ENV_KEYS:
        if key not in env and key in RETIRED_ENV_RESCUE_DEFAULTS:
            env[key] = RETIRED_ENV_RESCUE_DEFAULTS[key].replace("{{CLAUDE_CONFIG_DIR}}", config_dir)
            restored.append(key)
    note = (label + " NOTE: a retired plugin is still installed in "
            + os.path.dirname(installed_plugins_path)
            + "; keeping its isolation env keys until `ecc-uninstall` removes it.")
    if restored:
        note += " Restored missing default(s): " + ", ".join(restored) + "."
    print(note)
else:
    for key in RETIRED_ENV_KEYS:
        if key not in tmpl.get("env", {}):
            env.pop(key, None)
result["env"] = env

# Preserve any platform/installer keys the template does not define.
for key, value in dest.items():
    if key not in result:
        result[key] = value

# Pin a retired plugin off only while this config dir still registers it;
# once it is gone the key goes too, so settings.json stops naming it.
enabled = dict(result.get("enabledPlugins", {}))
for plugin in RETIRED_PLUGINS:
    if plugin in installed_names:
        enabled[plugin] = False
    else:
        enabled.pop(plugin, None)
result["enabledPlugins"] = enabled
markets = {
    name: value
    for name, value in result.get("extraKnownMarketplaces", {}).items()
    if name not in RETIRED_MARKETPLACES
}
if markets:
    result["extraKnownMarketplaces"] = markets
else:
    result.pop("extraKnownMarketplaces", None)

# Personal sessions do not use Jira/Confluence. Scope this policy to the
# personal account; work and custom config directories keep their own choice.
personal_settings = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")
if os.path.abspath(dest_path) == os.path.abspath(personal_settings):
    result["enabledPlugins"] = {
        **result.get("enabledPlugins", {}),
        "atlassian@claude-plugins-official": False,
    }

os.makedirs(os.path.dirname(dest_path), exist_ok=True)
with open(dest_path, "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")

# Drift stamp: settings_drift_check.py (SessionStart) compares this against
# the current template to recommend `update --ai` after template changes.
import hashlib
with open(tmpl_path, "rb") as fh:
    tmpl_sha = hashlib.sha256(fh.read()).hexdigest()
stamp_path = os.path.join(os.path.dirname(os.path.abspath(dest_path)), ".settings-template-sha256")
if not os.path.islink(stamp_path):
    with open(stamp_path, "w") as fh:
        fh.write(tmpl_sha + "\n")

ss = result.get("hooks", {}).get("SessionStart", [])
cmds = [os.path.basename(h.get("command", "")) for grp in ss for h in grp.get("hooks", [])]
print(label + " Reconciled settings.json (SessionStart: "
      + (", ".join(c for c in cmds if c) or "none") + ").")
PY
}

# Remove still-registered retired plugins (RETIRED_CLAUDE_PLUGINS_JSON) from
# one config dir. The settings reconcile only pins them off at user scope;
# project-scope records, the marketplace clone and the cache stay behind
# until this runs. The CLI handles what it can reach from a neutral cwd
# (ECC's marketplace, a user-scope record); the rest of the records are
# pruned from the registry, because a CLI project uninstall rewrites that
# project's own settings file and cannot reach a deleted project at all.
# Usage: sweep_retired_claude_plugins <cfg_dir> <label> [plugin_id ...]
sweep_retired_claude_plugins() {
  local cfg="${1:?sweep_retired_claude_plugins: config dir required}"
  local label="${2:?sweep_retired_claude_plugins: label required}"
  shift 2
  if ! command -v python3 >/dev/null 2>&1; then
    echo "$label [X] python3 not on PATH; cannot sweep retired plugins in $cfg"
    return 1
  fi
  RETIRED_CLAUDE_PLUGINS_JSON="$RETIRED_CLAUDE_PLUGINS_JSON" python3 - "$cfg" "$label" "$@" <<'PY'
import datetime, json, os, shutil, subprocess, sys, tempfile

cfg, label, wanted = os.path.abspath(sys.argv[1]), sys.argv[2], sys.argv[3:]
retired = json.loads(os.environ["RETIRED_CLAUDE_PLUGINS_JSON"])
wanted = wanted or list(retired)
unknown = [p for p in wanted if p not in retired]
if unknown:
    print(f"{label} [X] not a retired plugin: {', '.join(unknown)}")
    sys.exit(2)
plugins_dir = os.path.join(cfg, "plugins")
registry_path = os.path.join(plugins_dir, "installed_plugins.json")
markets_path = os.path.join(plugins_dir, "known_marketplaces.json")
settings_path = os.path.join(cfg, "settings.json")
personal_cfg = os.path.abspath(os.path.join(os.path.expanduser("~"), ".claude"))
git_missing_noted = False


class Unreadable(Exception):
    pass


def registry_valid(data):
    # Same rule as the reconcile's registry read.
    plugins = data.get("plugins", {}) if isinstance(data, dict) else None
    return isinstance(plugins, dict) and all(
        isinstance(recs, list) and all(isinstance(r, dict) for r in recs) for recs in plugins.values())


def is_object(data):
    return isinstance(data, dict)


def read_json(path, valid, refuse_link):
    if refuse_link and os.path.islink(path):
        raise Unreadable(f"{path} is a symlink")
    if not os.path.lexists(path):
        return {}, None
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
        data = json.loads(raw)
    except (OSError, ValueError) as exc:
        raise Unreadable(str(exc))
    if not valid(data):
        raise Unreadable(f"unexpected shape in {path}")
    return data, raw


def read_state():
    registry, raw = read_json(registry_path, registry_valid, True)
    markets, _ = read_json(markets_path, is_object, False)
    return registry.get("plugins", {}), markets, raw


def fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_atomically(path, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix="." + os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        if os.path.exists(path):
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
        fsync_dir(os.path.dirname(path))
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


# The CLI rewrites these three files; a torn one must not outlive the call.
GUARDED = ((settings_path, is_object, False), (registry_path, registry_valid, True),
           (markets_path, is_object, False))


def file_ok(path, valid, refuse):
    try:
        read_json(path, valid, refuse)
        return True
    except Unreadable:
        return False


def snapshot():
    # (bytes or None when absent, valid before the call). Only a file that was
    # valid (or absent) before the call is the CLI's to have torn; a symlink or
    # an already-broken file is left alone.
    snap = {}
    for path, valid, refuse in GUARDED:
        if os.path.islink(path):
            snap[path] = (None, False)
        elif os.path.isfile(path):
            with open(path, "rb") as fh:
                snap[path] = (fh.read(), file_ok(path, valid, refuse))
        else:
            snap[path] = (None, True)
    return snap


def restore_torn(snap, args):
    torn = False
    for path, valid, refuse in GUARDED:
        before, valid_before = snap[path]
        if not valid_before:
            print(f"{label} [INFO] {path} was already unreadable before the CLI call; left as is")
            continue
        if not os.path.lexists(path) or file_ok(path, valid, refuse):
            continue
        if before is not None:
            write_atomically(path, before)
            outcome = "restored it"
        else:
            os.unlink(path)
            outcome = "removed it"
        print(f"{label} [X] claude {' '.join(args)} left {path} unreadable; {outcome}")
        torn = True
    return torn


def run_claude(plugin, *args):
    claude = shutil.which("claude")
    if not claude:
        print(f"{label} [X] claude CLI not found; cannot remove {plugin} from {cfg}")
        return False
    # Match the plain-shell probes: no parent session or pane identity.
    env = {k: v for k, v in os.environ.items()
           if k != "CLAUDECODE" and not k.startswith(("CLAUDE_CODE_", "HERDR_"))}
    prefix = ""
    if cfg == personal_cfg:
        env.pop("CLAUDE_CONFIG_DIR", None)
    else:
        env["CLAUDE_CONFIG_DIR"] = cfg
        prefix = f"CLAUDE_CONFIG_DIR={cfg} "
    snap = snapshot()
    with tempfile.TemporaryDirectory() as cwd:
        rc = subprocess.run([claude, *args], cwd=cwd, env=env, stdin=subprocess.DEVNULL).returncode
    if restore_torn(snap, args):
        return False
    if rc != 0:
        print(f"{label} [X] claude {' '.join(args)} exited {rc} for {cfg}; "
              f"run by hand: {prefix}claude {' '.join(args)}")
        return False
    return True


def write_backup(raw):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = f"{registry_path}.bak-retired-{stamp}"
    for n in range(100):
        path = base if n == 0 else f"{base}-{n}"
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        with os.fdopen(fd, "wb") as fh:
            fh.write(raw)
            fh.flush()
            os.fsync(fh.fileno())
        fsync_dir(plugins_dir)
        return
    raise OSError(f"no free backup name for {base}")


def prune(plugin):
    for _attempt in range(2):
        plugins, _markets, before = read_state()
        if before is None or plugin not in plugins:
            return True
        write_backup(before)
        data = json.loads(before)
        data["plugins"].pop(plugin)
        fd, tmp = tempfile.mkstemp(dir=plugins_dir, prefix=".installed_plugins.json.")
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write((json.dumps(data, indent=2) + "\n").encode())
                fh.flush()
                os.fsync(fh.fileno())
            shutil.copymode(registry_path, tmp)
            hook = os.environ.get("SWEEP_TEST_BEFORE_RECHECK")
            if hook:
                subprocess.run(["sh", "-c", hook], check=False)
            with open(registry_path, "rb") as fh:
                if fh.read() != before:
                    continue
            os.replace(tmp, registry_path)
            fsync_dir(plugins_dir)
            return True
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)
    print(f"{label} [X] registry changed during the sweep; {plugin} not pruned ({cfg})")
    return False


def normalize(url):
    url = url.strip().lower()
    url = url[:-1] if url.endswith("/") else url
    return url[:-4] if url.endswith(".git") else url


def retired_clones(source):
    global git_missing_noted
    cache = os.path.join(plugins_dir, "cache")
    if not os.path.isdir(cache):
        return []
    candidates = [os.path.join(cache, n) for n in sorted(os.listdir(cache))
                  if n.startswith("temp_git_") and os.path.isfile(os.path.join(cache, n, ".git", "config"))]
    if not candidates:
        return []
    git = shutil.which("git")
    if not git:
        if not git_missing_noted:
            print(f"{label} [INFO] git not on PATH; temp_git leftovers in {cfg} not checked")
            git_missing_noted = True
        return []
    found = []
    for clone in candidates:
        url = subprocess.run([git, "config", "--file", os.path.join(clone, ".git", "config"),
                              "--get", "remote.origin.url"], capture_output=True, text=True).stdout
        if normalize(url) == normalize(source):
            found.append(clone)
    return found


def remove_clone(clone):
    # Rename to a sweep-owned name first: a half-deleted temp_git dir loses
    # its git config and would no longer be recognised, but a .retired-* dir
    # is always finished by the next run (finish_staged_clones).
    staged = os.path.join(os.path.dirname(clone), ".retired-" + os.path.basename(clone))
    os.rename(clone, staged)
    remove_path(staged)


def finish_staged_clones():
    cache = os.path.join(plugins_dir, "cache")
    if os.path.isdir(cache):
        for name in sorted(os.listdir(cache)):
            if name.startswith(".retired-temp_git_"):
                remove_path(os.path.join(cache, name))


def remove_path(path):
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.isdir(path):
        shutil.rmtree(path)
    else:
        return False
    return True


try:
    read_state()
except Unreadable as exc:
    print(f"{label} [X] unreadable plugin registry in {cfg} ({exc}); nothing removed")
    sys.exit(1)

status = 0
try:
    finish_staged_clones()
except OSError as exc:
    print(f"{label} [X] staged temp_git leftovers not removed from {cfg}: {exc}")
    status = 1

for plugin in wanted:
    entry = retired[plugin]
    market = entry.get("marketplace")
    clone_dir = os.path.join(plugins_dir, "marketplaces", market) if market else None
    cache_dir = os.path.join(plugins_dir, entry["cache"])
    try:
        plugins, markets, _raw = read_state()
        present = (plugin in plugins or (market and market in markets)
                   or (clone_dir and os.path.lexists(clone_dir))
                   or os.path.lexists(cache_dir) or retired_clones(entry["source"]))
        if not present:
            continue
        ok = True
        if market and market in markets:
            ok = run_claude(plugin, "plugin", "marketplace", "remove", market)
        elif not market and any(r.get("scope") == "user" for r in plugins.get(plugin, [])):
            ok = run_claude(plugin, "plugin", "uninstall", "--scope", "user", plugin)
        ok = ok and prune(plugin)
        if ok:
            plugins, markets, _raw = read_state()
            if plugin in plugins or (market and market in markets):
                print(f"{label} [X] {plugin} is still registered in {cfg}; keeping its cache")
                ok = False
        removed_cache = False
        if ok:
            if clone_dir:
                remove_path(clone_dir)
            removed_cache = remove_path(cache_dir)
            for clone in retired_clones(entry["source"]):
                remove_clone(clone)
    except Unreadable as exc:
        # Earlier plugins' completed changes stay; nothing further is touched.
        print(f"{label} [X] unreadable plugin registry in {cfg} ({exc}); stopping")
        status = 1
        break
    except OSError as exc:
        print(f"{label} [X] {plugin} or its leftovers not removed from {cfg}: {exc}")
        ok = False
    if not ok:
        status = 1
        continue
    print(f"{label} [OK] Removed {plugin} from {cfg}")
    if removed_cache:
        print(f"{label} [INFO] Restart running Claude sessions: {plugin} hooks ran from the removed cache")
sys.exit(status)
PY
}

# Link the dotfiles-managed Claude Code assets into one config dir.
# Two config dirs share the same dotfiles-managed assets via symlinks:
#   ~/.claude       personal account (default; desktop app lands here)
#   ~/.claude-work  work account (selected by the claude() zsh wrapper under ~/Git/work)
# settings.json stays machine-local PER DIR (plugin installers write to it);
# both copies are drift-checked by claude/hooks/claude-hooks.test.sh.
# rm -rf first because ln -sf can't overwrite directory symlinks atomically.
link_claude_config_dir() {
  local cdir="${1:?link_claude_config_dir: config dir required}"

  mkdir -p "$cdir"

  # Sweep the retired interview symlink (its target was never tracked; public
  # clones would get a dangling link) and back up any REAL dir sitting where a
  # symlink belongs -- rm -rf on a real commands/agents/hooks dir would eat
  # user content that was never vendored into the repo.
  local d
  for d in commands agents hooks interview; do
    if [[ -d "$cdir/$d" && ! -L "$cdir/$d" ]]; then
      mv "$cdir/$d" "$cdir/$d.bak.$(date +%Y%m%d-%H%M%S)"
      echo "[claude-links] Backed up pre-existing $cdir/$d (real dir) before symlinking."
    fi
  done
  rm -rf "$cdir"/commands "$cdir"/agents "$cdir"/hooks "$cdir"/interview
  ln -sf "$DOTFILEDIR"/claude/CLAUDE.md "$cdir"/CLAUDE.md

  # Standing operating principles: the committed, model-agnostic discipline file
  # that CLAUDE.md @imports into every session.
  ln -sf "$DOTFILEDIR"/claude/operating-principles.md "$cdir"/operating-principles.md

  # Optional per-model audit deep-dives are local-only and gitignored (they hold
  # private session content). Link them only when present, so a public clone that
  # lacks them does not create dangling symlinks.
  local ref
  for ref in Fable5.md Opus4.md; do
    if [ -f "$DOTFILEDIR/claude/$ref" ]; then
      ln -sf "$DOTFILEDIR/claude/$ref" "$cdir/$ref"
    fi
  done

  # Rules: claude/rules is symlinked here as the single asset source. Claude
  # Code natively auto-loads every .md under ~/.claude/rules at launch (`paths:`
  # frontmatter scopes to matching files; none = every session). Only our own
  # always-on rules under claude/rules/personal/ are tracked. Language dirs
  # left by the retired ECC rules vendoring still auto-load if present; delete
  # them (claude/rules/.gitignore keeps them uncommitted).
  # One-time migration: older machines have rules as a REAL directory (from a
  # blanket ECC install). Preserve it as a timestamped backup before replacing
  # it with the symlink, in case it holds hand-edited rules not yet saved.
  # Steady state it is already a symlink, which rm -rf drops by link only
  # (never recursing into the dotfiles target), so re-runs stay idempotent.
  if [[ -d "$cdir/rules" && ! -L "$cdir/rules" ]]; then
    mv "$cdir/rules" "$cdir/rules.bak.$(date +%Y%m%d-%H%M%S)"
    echo "[claude-links] Backed up pre-existing $cdir/rules (real dir) before symlinking."
  fi
  rm -rf "$cdir"/rules
  ln -sfn "$DOTFILEDIR"/claude/rules "$cdir"/rules

  # Skills: whole-dir symlink into the dotfiles repo, but only PERSONAL skills
  # are version-controlled (see claude/skills/.gitignore, which whitelists
  # them). ECC marketplace skills and continuous-learning's generated
  # `learned/` live in the same dir untracked, and their installers keep
  # writing to this path through the symlink. Same real-dir -> symlink
  # migration as rules above.
  if [[ -d "$cdir/skills" && ! -L "$cdir/skills" ]]; then
    mv "$cdir/skills" "$cdir/skills.bak.$(date +%Y%m%d-%H%M%S)"
    echo "[claude-links] Backed up pre-existing $cdir/skills (real dir) before symlinking."
  fi
  rm -rf "$cdir"/skills
  ln -sfn "$DOTFILEDIR"/claude/skills "$cdir"/skills

  # settings.json is machine-local (plugin installers like GSD/ECC write to it).
  # Seed from template on first install, then reconcile template drift on every
  # run -- plugin-installer keys survive the merge (see reconcile_claude_settings_file).
  seed_machine_local_file "$DOTFILEDIR"/claude/settings.json.tmpl "$cdir"/settings.json
  # Sweep before the reconcile so a retired plugin's settings key goes with it.
  sweep_retired_claude_plugins "$cdir" "[claude-links]" || true
  reconcile_claude_settings_file "$DOTFILEDIR"/claude/settings.json.tmpl "$cdir"/settings.json || true
  ln -sf "$DOTFILEDIR"/claude/commands "$cdir"/commands
  ln -sf "$DOTFILEDIR"/claude/agents "$cdir"/agents
  ln -sf "$DOTFILEDIR"/claude/hooks "$cdir"/hooks

  # Statusline (referenced by statusLine.command in settings.json). Sweep the
  # stale statusline.sh symlink from earlier setups before linking the current one.
  rm -f "$cdir"/statusline.sh
  ln -sf "$DOTFILEDIR"/claude/statusline.js "$cdir"/statusline.js
}
