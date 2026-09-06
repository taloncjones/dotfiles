# Cloudflared Remote Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the client side of Cloudflare Access SSH reproducible from dotfiles (a tracked template seeded machine-local, an SSH Include, a read-only doctor, tests) and record the exploration's answer and the host runbook durably in the README, without the installer touching tunnels, services, or sshd.

**Architecture:** `ssh/configs/config_cloudflared.tmpl` is seeded to `~/.ssh/config_cloudflared` by the existing `seed_machine_local_file` helper and Included from `ssh/configs/config` between `config_local` and `config_personal`; its placeholder zone `ssh.example.com` matches nothing until the human edits it. `bin/remote-access-doctor` mirrors `bin/identity-doctor`: file and PATH reads only, `HOME` and `PATH` are its only inputs, so a POSIX sh suite drives every branch with a temporary `HOME` and a stub `cloudflared`. The README gains a `### Remote Access` section holding the decision record, the host runbook (Phase 1 probes P1 to P7, human-verify), and the client steps.

**Tech Stack:** bash 3.2-compatible scripts, POSIX `sh` test suites with the repo's `assert` helper, `bin/dotfiles-tests` runner (also on Ubuntu CI), markdown docs.

**Spec:** `docs/specs/2026-09-06-cloudflared-remote-access.md`

**Status:** branch-only document; dropped before merge together with the spec. Review provenance: Codex was over its usage limit on 2026-09-06, so a fresh-context independent reviewer stood in for both the spec and plan reviews; its plan findings (README tree is non-ASCII, vacuous template assert, suite count, placeholder exit code) are folded in. The task contract at `claude/contracts/td-2026-09-05-explore-cloudflared-tunnel-access-remote-access-to-contract.json` stays.


## Global Constraints

- Template placeholder zone, verbatim (spec D4): `ssh.example.com`. Every `Host` line in the template ends in `.ssh.example.com`. No real zone, token, or user in any tracked file.
- ProxyCommand line, verbatim (spec D4): `    ProxyCommand cloudflared access ssh --hostname %h` (four-space indent).
- Include line, verbatim (spec AC1): `Include ~/.ssh/config_cloudflared`, placed after `Include ~/.ssh/config_local` and before `Include ~/.ssh/config_personal`.
- Seed, verbatim (spec AC4): `seed_machine_local_file "$DOTFILEDIR"/ssh/configs/config_cloudflared.tmpl "$HOME"/.ssh/config_cloudflared`. Never `ln -s` for this file.
- Doctor link, verbatim (spec AC4): `ln -sf "$DOTFILEDIR"/bin/remote-access-doctor "$HOME"/bin/remote-access-doctor`.
- Doctor is read-only (spec AC5): no non-comment line of the script contains `sudo`, `launchctl load`, `launchctl bootstrap`, `launchctl kickstart`, `systemctl enable|start|restart`, `cloudflared tunnel`, or `cloudflared service`. Comment lines are exempt. No network calls.
- Doctor exit code: 0 unless any `[X]` line printed; a seeded-but-unedited client exits 0 with a `[WARNING]` line containing `not configured`; tests that need an edited zone use `ssh.example.com.test` and never a real zone (spec AC6).
- Suite registration line, verbatim (spec AC7): `sh bin/remote-access-doctor.test.sh` in `bin/dotfiles-tests`.
- Files that may change (spec R8): `ssh/configs/config_cloudflared.tmpl`, `ssh/configs/config`, `install/common/link.sh`, `install/install.test.sh`, `bin/remote-access-doctor`, `bin/remote-access-doctor.test.sh`, `bin/dotfiles-tests`, `README.md`, `CLAUDE.md`. The contract's `changed-files-within-scope` command enforces this list.
- No emojis, no AI attribution, ASCII only in added lines, LF endings. Commit format `<scope>: <summary>`, imperative, under 75 chars.
- Test baseline (2026-09-06 at main `682d9db`, this machine): `bin/dotfiles-tests` runs 20 suites; `claude/hooks/claude-hooks.test.sh` fails 2 checks from live `settings.json` drift (machine-local, "run update to reconcile") and `git/hooks/public-safety.test.sh` fails "no tracked planning artifacts" while the branch-only spec and plan are tracked. Both are expected until `update` runs and the docs drop before merge; neither is this branch's regression. Every other suite is green at baseline.
- Out of scope, do not touch: `claude/hooks/herdr_orch_core.py`, `claude/skills/herdr-orchestration/`, `claude/skills/co-review/`, `git/hooks/commit-msg`, `install/common/codex-*`.

## File Structure

| File | Responsibility |
|---|---|
| `ssh/configs/config_cloudflared.tmpl` | Tracked template: placeholder `Host *.ssh.example.com` block with the cloudflared ProxyCommand and the personal pubkey pin. |
| `ssh/configs/config` | Adds the Include line. |
| `install/common/link.sh` | Seeds the template machine-local; links the doctor into `~/bin`. |
| `install/install.test.sh` | Static asserts for the three items above. |
| `bin/remote-access-doctor` | Read-only checker: cloudflared on PATH, Include present, seeded file is a regular file with the ProxyCommand, zone edited, Access cache present, host-role unit and authorized_keys. |
| `bin/remote-access-doctor.test.sh` | POSIX sh suite driving the doctor with a temp `HOME` and a stub `cloudflared`. |
| `bin/dotfiles-tests` | Registers the new suite. |
| `README.md` | `### Remote Access`: Status line, decision record, Remote Control note, host runbook with probes P1 to P7, client steps, VPN note, doctor. The Directory Structure tree is left alone (non-ASCII box characters). |
| `CLAUDE.md` | Two symlink-targets bullets (template seed, doctor). |

Task order: 1 client SSH stanza, 2 doctor and suite, 3 docs, 4 verification. Re-run `codex-spec-review` and `codex-plan-review` before implementing if Codex is available again (it was over its usage limit on 2026-09-06). Tasks 1 to 3 are independent in content but Task 2's tests need Task 1's template, so keep the order.

## Acceptance criteria to contract mapping

| Spec AC | Contract command(s) |
|---|---|
| AC1 Include order | `ssh-config-include-order` |
| AC2 template ProxyCommand and placeholder hosts | `template-proxycommand-and-placeholder-hosts` |
| AC3 no secrets or real zones | `template-and-config-carry-no-secrets-or-real-zones` |
| AC4 link.sh seeds and links | `link-seeds-template-and-links-doctor` |
| AC5 doctor executable, syntax, read-only | `doctor-executable-syntax-and-read-only` |
| AC6 doctor exit codes and placeholder warning | `doctor-passes-on-seeded-client`, `doctor-fails-without-include`, `doctor-warns-on-placeholder-zone` |
| AC7 suites registered and green; changed files public-safe | `doctor-suite-registered-and-green`, `install-suite`, `links-suite`, `changed-files-public-safe` |
| AC8 README Status line and content, CLAUDE.md bullets | `readme-remote-access-section`, `claude-md-names-template-and-doctor` |
| AC9 scope and ASCII | `changed-files-within-scope`, `added-lines-ascii` |
| Brewfile unchanged (spec Confirmed facts) | `brewfile-keeps-cloudflared-and-no-warp` |
| AC10 probes P1 to P7 | human-verify (README "verified on" lines), not in the contract |

---

### Task 1: Client SSH stanza (template, Include, seed, static tests)

**Files:**
- Create: `ssh/configs/config_cloudflared.tmpl`
- Modify: `ssh/configs/config` (after the `Include ~/.ssh/config_local` line, line 8)
- Modify: `install/common/link.sh:64-76` (SSH section) and `:93-96` (bin links)
- Test: `install/install.test.sh` (append before the final `printf`)

**Interfaces:**
- Produces: the template file path `ssh/configs/config_cloudflared.tmpl` and the seeded path `$HOME/.ssh/config_cloudflared`, both read by Task 2's doctor and tests; the `~/bin/remote-access-doctor` link consumed by Task 2.

- [ ] **Step 1: Write the failing tests**

Append to `install/install.test.sh` before `printf '\n%d passed, %d failed\n'`:

```sh
assert "ssh config includes config_cloudflared between config_local and config_personal" \
    awk '/^Include ~\/.ssh\/config_local$/{a=NR} /^Include ~\/.ssh\/config_cloudflared$/{b=NR} /^Include ~\/.ssh\/config_personal$/{c=NR} END{exit !(a && b && c && a<b && b<c)}' ssh/configs/config
assert "cloudflared ssh template carries the access ProxyCommand" \
    rg -q -F '    ProxyCommand cloudflared access ssh --hostname %h' ssh/configs/config_cloudflared.tmpl
assert "cloudflared ssh template hosts stay on the example.com placeholder" \
    sh -c "test -f ssh/configs/config_cloudflared.tmpl && rg -q '^Host ' ssh/configs/config_cloudflared.tmpl && ! rg '^Host ' ssh/configs/config_cloudflared.tmpl | rg -v -q '\\.ssh\\.example\\.com$'"
assert "link.sh seeds config_cloudflared machine-local, never symlinks it" \
    sh -c "rg -q -F 'seed_machine_local_file \"\$DOTFILEDIR\"/ssh/configs/config_cloudflared.tmpl \"\$HOME\"/.ssh/config_cloudflared' install/common/link.sh && ! rg -q 'ln -sf.*config_cloudflared' install/common/link.sh"
assert "link.sh links remote-access-doctor into ~/bin" \
    rg -q -F 'ln -sf "$DOTFILEDIR"/bin/remote-access-doctor "$HOME"/bin/remote-access-doctor' install/common/link.sh
```

- [ ] **Step 2: Run the suite to verify the new asserts fail**

Run: `sh install/install.test.sh`
Expected: the five new labels print `FAIL`, the five existing ones `PASS`, final line `5 passed, 5 failed`, exit 1.

- [ ] **Step 3: Create the template**

Write `ssh/configs/config_cloudflared.tmpl`:

```
# Cloudflare Access SSH hosts (see README "Remote Access").
#
# Seeded once to ~/.ssh/config_cloudflared by install/common/link.sh and
# then machine-local: edit the zone in THAT file, never this template.
# The placeholder pattern below matches nothing until the zone is edited,
# so a fresh machine is inert. Host-side setup (tunnel, Access app, sshd)
# is a manual runbook; nothing in dotfiles creates it.
#
# Client use:   ssh <host>.ssh.<zone>
#               herdr --remote <host>.ssh.<zone>
Host *.ssh.example.com
    ProxyCommand cloudflared access ssh --hostname %h
    IdentityFile ~/.ssh/id_ed25519_personal
    IdentitiesOnly yes
```

(`IdentityFile` names the private-key path with no `.pub` suffix, exactly as `config_personal` does; only the `.pub` exists on disk and OpenSSH resolves it through the 1Password agent.)

- [ ] **Step 4: Add the Include**

In `ssh/configs/config`, directly after `Include ~/.ssh/config_local` (line 8) and its blank line, insert:

```
# Cloudflare Access SSH hosts. Seeded machine-local from
# ssh/configs/config_cloudflared.tmpl; inert until the zone is edited.
Include ~/.ssh/config_cloudflared

```

so the Include order reads `config_local`, `config_cloudflared`, `config_personal`, `config_work`.

- [ ] **Step 5: Seed and link in link.sh**

In `install/common/link.sh`, after line 69 (`ln -sf "$DOTFILEDIR"/ssh/keys/id_ed25519_personal.pub ...`) and before the `# identity-setup writes` comment, add:

```sh
# Cloudflare Access SSH stanza: seed once, then machine-local (the real
# zone never enters the repo). See README "Remote Access".
seed_machine_local_file "$DOTFILEDIR"/ssh/configs/config_cloudflared.tmpl "$HOME"/.ssh/config_cloudflared
```

After line 95 (`ln -sf "$DOTFILEDIR"/bin/identity-doctor ...`) add:

```sh
ln -sf "$DOTFILEDIR"/bin/remote-access-doctor "$HOME"/bin/remote-access-doctor
```

(The doctor script itself is created in Task 2; `ln -sf` to a not-yet-existing target is harmless and `install/claude-links.test.sh` does not exercise it.)

- [ ] **Step 6: Run the suites to verify they pass**

Run: `sh install/install.test.sh && sh install/claude-links.test.sh && bash -n install/common/link.sh`
Expected: install suite `10 passed, 0 failed`; links suite unchanged from baseline; syntax OK.

- [ ] **Step 7: Commit**

```bash
git add ssh/configs/config_cloudflared.tmpl ssh/configs/config install/common/link.sh install/install.test.sh
git commit -m "ssh: Add Cloudflare Access SSH stanza template and Include"
```

---

### Task 2: Read-only doctor and its suite

**Files:**
- Create: `bin/remote-access-doctor`
- Create: `bin/remote-access-doctor.test.sh`
- Modify: `bin/dotfiles-tests` (SUITES list, after `sh install/install.test.sh`)

**Interfaces:**
- Consumes: `ssh/configs/config` and `ssh/configs/config_cloudflared.tmpl` from Task 1 (the suite copies them into a temp `HOME`).
- Produces: `bin/remote-access-doctor` (bash, exit 0/1, printers `[OK]`, `[WARNING]`, `[INFO]`, `[X]`), consumed by the contract and the README.

- [ ] **Step 1: Write the failing suite**

Write `bin/remote-access-doctor.test.sh`:

```sh
#!/bin/sh
# remote-access-doctor.test.sh - drive bin/remote-access-doctor through a
# temporary HOME and a stub cloudflared. No network, no real HOME reads.
set -e

PASS=0
FAIL=0

assert() {
    label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        FAIL=$((FAIL + 1))
    fi
}

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOCTOR="$REPO/bin/remote-access-doctor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# fresh_home <name>: a HOME with a stub cloudflared, the tracked ssh config,
# and the seeded template. Prints the path.
fresh_home() {
    h="$WORK/$1"
    mkdir -p "$h/.ssh" "$h/bin"
    printf '#!/bin/sh\nexit 0\n' > "$h/bin/cloudflared"
    chmod +x "$h/bin/cloudflared"
    cp "$REPO/ssh/configs/config" "$h/.ssh/config"
    cp "$REPO/ssh/configs/config_cloudflared.tmpl" "$h/.ssh/config_cloudflared"
    printf '%s\n' "$h"
}

# run_doctor <home> <outfile>: runs the doctor with only the stub PATH.
run_doctor() {
    HOME="$1" PATH="$1/bin:/usr/bin:/bin" bash "$DOCTOR" > "$2" 2>&1
}

# 1. seeded client with an edited zone passes
h="$(fresh_home ok)"
sed 's/\.ssh\.example\.com/.ssh.example.com.test/' "$REPO/ssh/configs/config_cloudflared.tmpl" > "$h/.ssh/config_cloudflared"
assert "doctor: seeded client with edited zone exits 0" run_doctor "$h" "$h/out"
assert "doctor: seeded client reports the Include as OK" grep -q '^\[OK\] .*config_cloudflared' "$h/out"
assert "doctor: seeded client prints no [X] line" sh -c "! grep -q '^\[X\]' '$h/out'"

# 2. placeholder zone warns but passes
h="$(fresh_home placeholder)"
assert "doctor: placeholder zone exits 0" run_doctor "$h" "$h/out"
assert "doctor: placeholder zone prints a not-configured warning" \
    sh -c "grep '^\[WARNING\]' '$h/out' | grep -q 'not configured'"

# 3. missing Include fails
h="$(fresh_home noinclude)"
grep -v 'config_cloudflared' "$REPO/ssh/configs/config" > "$h/.ssh/config"
assert "doctor: missing Include exits 1" sh -c "! HOME='$h' PATH='$h/bin:/usr/bin:/bin' bash '$DOCTOR' > '$h/out' 2>&1"
assert "doctor: missing Include prints an [X] line" grep -q '^\[X\] .*config_cloudflared' "$h/out"

# 4. symlinked config_cloudflared fails
h="$(fresh_home symlink)"
rm "$h/.ssh/config_cloudflared"
ln -s "$REPO/ssh/configs/config_cloudflared.tmpl" "$h/.ssh/config_cloudflared"
assert "doctor: symlinked config_cloudflared exits 1" sh -c "! HOME='$h' PATH='$h/bin:/usr/bin:/bin' bash '$DOCTOR' > '$h/out' 2>&1"
assert "doctor: symlinked config_cloudflared names the symlink" grep -q '^\[X\] .*symlink' "$h/out"

# 5. cloudflared missing from PATH fails
h="$(fresh_home nocf)"
rm "$h/bin/cloudflared"
assert "doctor: cloudflared missing exits 1" sh -c "! HOME='$h' PATH='$h/bin:/usr/bin:/bin' bash '$DOCTOR' > '$h/out' 2>&1"
assert "doctor: cloudflared missing prints an [X] line" grep -q '^\[X\] .*cloudflared' "$h/out"

# 6. host role: user-domain unit present, key authorized
h="$(fresh_home host-ok)"
mkdir -p "$h/Library/LaunchAgents"
: > "$h/Library/LaunchAgents/com.cloudflare.cloudflared.plist"
printf 'ssh-ed25519 AAAATESTKEYONLY test@example.com\n' > "$h/.ssh/id_ed25519_personal.pub"
printf 'ssh-ed25519 AAAATESTKEYONLY test@example.com\n' > "$h/.ssh/authorized_keys"
run_doctor "$h" "$h/out" || true
assert "doctor: host role detected from the LaunchAgents unit" grep -q '^\[INFO\] .*session host' "$h/out"
assert "doctor: authorized_keys with the personal key is OK" grep -q '^\[OK\] .*authorized_keys' "$h/out"

# 7. host role: unit present, key missing warns
h="$(fresh_home host-nokey)"
mkdir -p "$h/Library/LaunchAgents"
: > "$h/Library/LaunchAgents/com.cloudflare.cloudflared.plist"
printf 'ssh-ed25519 AAAATESTKEYONLY test@example.com\n' > "$h/.ssh/id_ed25519_personal.pub"
run_doctor "$h" "$h/out" || true
assert "doctor: host without the personal key in authorized_keys warns" \
    grep -q '^\[WARNING\] .*authorized_keys' "$h/out"

# 8. the script stays read-only
assert "doctor: contains no service or tunnel mutation outside comments" \
    sh -c "! grep -v '^[[:space:]]*#' '$DOCTOR' | grep -E -q 'sudo|launchctl (load|bootstrap|kickstart)|systemctl (enable|start|restart)|cloudflared tunnel|cloudflared service'"
assert "doctor: is executable and parses" sh -c "test -x '$DOCTOR' && bash -n '$DOCTOR'"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `sh bin/remote-access-doctor.test.sh`
Expected: every `doctor:` label prints `FAIL` (the script does not exist), exit 1.

- [ ] **Step 3: Write the doctor**

Write `bin/remote-access-doctor` and `chmod +x` it:

```bash
#!/usr/bin/env bash
# remote-access-doctor - verify the Cloudflare Access SSH remote-access setup.
#
# Client checks: cloudflared on PATH, the ~/.ssh/config Include, the seeded
# ~/.ssh/config_cloudflared (a regular file with the ProxyCommand and an
# edited zone), and the Access login cache. Host checks run only when a
# tunnel service unit exists on this machine: authorized_keys must carry
# the personal public key. See README "Remote Access" for the runbook.
#
# Read-only: never modifies anything, never touches the network, never
# needs root. Only HOME and PATH are read. Exit 1 if any [X] check fails.
#
# Usage: remote-access-doctor

set -uo pipefail

FAILED=0
ok()   { printf '[OK]      %s\n' "$1"; }
warn() { printf '[WARNING] %s\n' "$1"; }
info() { printf '[INFO]    %s\n' "$1"; }
fail() { printf '[X]       %s\n' "$1"; FAILED=1; }

section() { printf '\n--- %s ---\n' "$1"; }

SSH_CONFIG="$HOME/.ssh/config"
CF_CONFIG="$HOME/.ssh/config_cloudflared"
PLACEHOLDER_ZONE='ssh.example.com'
PERSONAL_PUB="$HOME/.ssh/id_ed25519_personal.pub"
AUTHORIZED_KEYS="$HOME/.ssh/authorized_keys"

# --- client: cloudflared -------------------------------------------------
section "client: cloudflared"

if command -v cloudflared >/dev/null 2>&1; then
  ok "cloudflared on PATH ($(command -v cloudflared))"
else
  fail "cloudflared not on PATH (brew bundle with install/common/Brewfile.rb)"
fi

# --- client: ssh config --------------------------------------------------
section "client: ssh config"

if [[ -f "$SSH_CONFIG" ]] && grep -q '^Include ~/.ssh/config_cloudflared$' "$SSH_CONFIG"; then
  ok "~/.ssh/config includes config_cloudflared"
else
  fail "~/.ssh/config does not include config_cloudflared (re-run link.sh)"
fi

if [[ -L "$CF_CONFIG" ]]; then
  fail "~/.ssh/config_cloudflared is a symlink; expected a machine-local file (re-run link.sh)"
elif [[ -f "$CF_CONFIG" ]]; then
  ok "~/.ssh/config_cloudflared present (machine-local)"
  if grep -q 'ProxyCommand cloudflared access ssh' "$CF_CONFIG"; then
    ok "config_cloudflared routes through cloudflared access ssh"
  else
    fail "config_cloudflared has no 'ProxyCommand cloudflared access ssh' line"
  fi
  if grep -q "^Host .*\\.${PLACEHOLDER_ZONE}\$" "$CF_CONFIG"; then
    warn "client not configured: config_cloudflared still uses the ${PLACEHOLDER_ZONE} placeholder zone"
  elif grep -q '^Host ' "$CF_CONFIG"; then
    ok "config_cloudflared zone edited: $(grep '^Host ' "$CF_CONFIG" | head -1)"
  else
    warn "client not configured: config_cloudflared has no Host block"
  fi
else
  fail "~/.ssh/config_cloudflared missing (re-run link.sh to seed it)"
fi

# --- client: access login ------------------------------------------------
section "client: access login"

if [[ -d "$HOME/.cloudflared" ]] && find "$HOME/.cloudflared" -maxdepth 1 -type f 2>/dev/null | grep -q .; then
  info "~/.cloudflared has cached files (an Access login or tunnel credentials)"
else
  info "no ~/.cloudflared cache yet; the first ssh opens the Access login in a browser"
fi

# --- host role -----------------------------------------------------------
section "host role"

unit_found=""
for unit in \
  "$HOME/Library/LaunchAgents/com.cloudflare.cloudflared.plist" \
  "/Library/LaunchDaemons/com.cloudflare.cloudflared.plist" \
  "/etc/systemd/system/cloudflared.service"; do
  if [[ -f "$unit" ]]; then
    unit_found="$unit"
    break
  fi
done

if [[ -n "$unit_found" ]]; then
  info "tunnel service unit present: $unit_found (this machine is a session host)"
  if [[ -f "$PERSONAL_PUB" && -f "$AUTHORIZED_KEYS" ]] \
     && grep -qF -- "$(awk '{print $2}' "$PERSONAL_PUB")" "$AUTHORIZED_KEYS"; then
    ok "authorized_keys carries the personal public key"
  else
    warn "authorized_keys does not carry the personal public key; ssh through the tunnel will be refused after the Access login"
  fi
else
  info "no tunnel service unit found; this machine is a client only"
fi

# --- verdict -------------------------------------------------------------
echo
if [[ "$FAILED" -eq 0 ]]; then
  echo "[OK] remote-access-doctor: no failures"
  exit 0
fi
echo "[X] remote-access-doctor: failures above"
exit 1
```

- [ ] **Step 4: Register the suite**

In `bin/dotfiles-tests`, in the `SUITES` list, insert `sh bin/remote-access-doctor.test.sh` directly after `sh install/install.test.sh`.

- [ ] **Step 5: Run the suite and the runner to verify they pass**

Run: `sh bin/remote-access-doctor.test.sh && bin/dotfiles-tests --list | grep -x 'sh bin/remote-access-doctor.test.sh' && bash -n bin/remote-access-doctor`
Expected: `16 passed, 0 failed`; the list line prints; syntax OK.

- [ ] **Step 6: Commit**

```bash
git add bin/remote-access-doctor bin/remote-access-doctor.test.sh bin/dotfiles-tests
git commit -m "bin: Add read-only remote-access-doctor and its suite"
```

---

### Task 3: Docs (README Remote Access section, CLAUDE.md bullets)

**Files:**
- Modify: `README.md` (insert a `### Remote Access` section directly after the `### Identity Routing` section, before `### Worktree Hydration`). Do NOT edit the Directory Structure tree: it is drawn with non-ASCII box characters, and any added line there fails the contract's `added-lines-ascii` command. No acceptance criterion needs a tree entry.
- Modify: `CLAUDE.md` (Symlink targets list: two bullets after the `ssh/keys/id_ed25519_personal.pub` bullet)

**Interfaces:**
- Consumes: the doctor name from Task 2 and the seeded path from Task 1.
- Produces: the durable decision record the contract's `readme-remote-access-section` command reads (keys: `cloudflared access ssh`, `herdr --remote`, `claude remote-control`, `remote-access-doctor`, `WARP`, `Tailscale`, `Proton`).

- [ ] **Step 1: Write the failing check**

Run: `awk '/^### Remote Access$/{s=1;next} /^### /{if(s)exit} s{print}' README.md | grep -c .`
Expected: `0` (no section yet).

- [ ] **Step 2: Add the README section**

Insert after the Identity Routing section's closing code block (the line after `identity-doctor  # verify the full chain ...` and its closing fence):

````markdown
### Remote Access

**Status:** unverified. The client stanza below is inert until a zone is
edited in; the host runbook has not been exercised end to end. Replace
this line with a dated summary once the probes at the end pass.

Attach to a herdr session or an SSH shell on another machine through
Cloudflare Tunnel + Access. Both ends speak only outbound HTTPS, so it
coexists with Proton VPN (the default VPN) on either side.

**Decision (2026-09):** Cloudflare WARP warp-to-warp was retired on
2026-09-05 because its full-tunnel client conflicted with Proton VPN.
Tailscale and similar mesh VPNs add a second tunnel interface and defeat
Proton's exit-country routing, and router port-forwarding exposes sshd
to the internet and fails behind CGNAT. Cloudflare Tunnel + Access needs
no inbound port, adds an identity login in front of sshd, and uses the
`cloudflared` binary already in the common Brewfile.

**Claude sessions need no tunnel.** `claude remote-control` on the host
dials out to Anthropic; connect from claude.ai/code or the mobile app.
Run it inside a herdr pane so it survives terminal close and sleep.
The tunnel is for `herdr --remote` (a full terminal workspace) and
plain `ssh`. No `herdr integration install` is needed for any of this;
that command stays off dotfiles machines (see CLAUDE.md).

**Client (any machine running these dotfiles):**

1. `link.sh` seeds `~/.ssh/config_cloudflared` from
   `ssh/configs/config_cloudflared.tmpl` and `~/.ssh/config` includes it.
   The seeded placeholder `*.ssh.example.com` matches nothing.
2. Edit the zone in `~/.ssh/config_cloudflared` (never the template).
3. `ssh <host>.ssh.<zone>` runs `cloudflared access ssh` as the
   ProxyCommand, which opens the Access login in a browser once; the
   token is cached under `~/.cloudflared/` for the Access app's session
   length (default 24 hours). Then `herdr --remote <host>.ssh.<zone>`
   attaches to the host's session.
4. Before a `herdr --remote` attach when the token may have expired, run
   `cloudflared access login https://<host>.ssh.<zone>` first; an expired
   token inside the ProxyCommand can leave the attach waiting on a
   browser.
5. `remote-access-doctor` reports the client and host state (read-only).
   It cannot see the host's SSH PATH or sshd state; those are runbook
   checks.

**Host (once per session host, manual, never run by the installer):**

1. Enable Remote Login (macOS System Settings > General > Sharing; on
   Linux, install and enable `sshd`). Optional hardening:
   `ListenAddress 127.0.0.1` in `sshd_config` so sshd is reachable only
   through the tunnel; skip it if LAN SSH is wanted.
2. `cat ~/.ssh/id_ed25519_personal.pub >> ~/.ssh/authorized_keys`;
   keep `PasswordAuthentication no`.
3. `cloudflared tunnel login`, then `cloudflared tunnel create <host>`
   and `cloudflared tunnel route dns <host> <host>.ssh.<zone>`.
4. Ingress: public hostname `<host>.ssh.<zone>` -> `ssh://localhost:22`
   (dashboard-managed tunnel, or `ingress:` in `~/.cloudflared/config.yml`).
   Under a VPN that drops UDP, add `protocol: http2`.
5. `cloudflared service install <token>` (launchd on macOS, systemd on
   Linux). The token is a secret; it lives only in the unit.
6. Zero Trust > Access > Applications: self-hosted app for
   `<host>.ssh.<zone>` with an Allow policy on your login identity.
7. If `herdr --remote` reports `herdr: command not found`, the SSH
   command shell is non-login and lacks Homebrew's PATH; add
   `export PATH="/opt/homebrew/bin:$PATH"` (or the Linuxbrew path) to
   `~/.zshenv.local` on the host.

Revocation: delete the Access session in the dashboard and remove the
key from `authorized_keys`.

**Probes:** record one dated pass/fail/skipped line per probe and update
the Status line above: P1 tunnel connector up across sleep; P2 ssh
through Access; P3 client on Proton; P4 host on Proton (http2 fallback
if QUIC flaps); P5 herdr --remote attach, repeated after the Access
token expires; P6 claude remote-control from the mobile app; P7 ssh
refused after removing the pubkey (second gate).
````

- [ ] **Step 3: Add the CLAUDE.md bullets**

In `CLAUDE.md`, after the bullet beginning `- \`ssh/keys/id_ed25519_personal.pub\` -> ...`, add:

```markdown
- `ssh/configs/config_cloudflared.tmpl` seeded to `~/.ssh/config_cloudflared` on first install (machine-local; the real zone is edited there, the template keeps the inert `*.ssh.example.com` placeholder). Included from `ssh/configs/config` after `config_local`. Client side of Cloudflare Access SSH; host-side tunnel, Access app, and sshd are a manual runbook in README "Remote Access", never installer-driven.
- `bin/remote-access-doctor` -> `~/bin/remote-access-doctor` -- read-only checker for the Cloudflare Access SSH client stanza and host role (tested by `bin/remote-access-doctor.test.sh`)
```

- [ ] **Step 4: Verify the contract keys are present**

Run: `awk '/^### Remote Access$/{s=1;next} /^### /{if(s)exit} s{print}' README.md > /tmp/ra.$$; for k in '**Status:**' 'cloudflared access ssh' 'cloudflared access login' 'herdr --remote' 'claude remote-control' 'remote-access-doctor' 'herdr integration install' 'WARP' 'Tailscale' 'Proton'; do grep -q -F -- "$k" /tmp/ra.$$ && echo "[OK] $k" || echo "[X] $k"; done; rm -f /tmp/ra.$$; grep -q 'config_cloudflared.tmpl' CLAUDE.md && grep -q 'remote-access-doctor' CLAUDE.md && echo '[OK] CLAUDE.md'`
Expected: ten `[OK]` lines and `[OK] CLAUDE.md`.

- [ ] **Step 5: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: Record Cloudflare Access remote-access decision and runbook"
```

---

### Task 4: Verification (suites, contract, human-verify list)

**Files:** none modified.

- [ ] **Step 1: Run every suite**

Run: `bin/dotfiles-tests`
Expected: 21 suites listed (baseline 20 plus the doctor suite); every suite green except the two baseline failures named in Global Constraints (hooks suite settings drift, public-safety tracked planning artifacts) if they still apply on the machine. Any other failure is this branch's regression. Name the baseline failures in the completion report.

- [ ] **Step 2: Run the task contract**

Run:

```bash
python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py" verify-contract \
  --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 \
  --task-id td-2026-09-05-explore-cloudflared-tunnel-access-remote-access-to \
  --worktree "$(git rev-parse --show-toplevel)" \
  --contract claude/contracts/td-2026-09-05-explore-cloudflared-tunnel-access-remote-access-to-contract.json \
  --allow-unpinned
```

Expected: exit 0, all 17 commands pass.

- [ ] **Step 3: Confirm scope and cleanliness**

Run: `git diff --name-only 682d9db093eb63609a72070d78444aa8bb403c06 HEAD | grep -v '^docs/' | grep -v '^claude/contracts/'`
Expected: exactly the nine files in Global Constraints "Files that may change".

- [ ] **Step 4: Human-verify checklist (not done by the worker)**

Report these as open in the completion message; they need a Cloudflare zone, a second machine, and Proton VPN:

- P1 host tunnel connector up, survives sleep/wake
- P2 `ssh <host>.ssh.<zone>` gives a shell after one browser login
- P3 client on Proton VPN, P2 still passes
- P4 host on Proton VPN, connector stable for 10 minutes (else `protocol: http2`)
- P5 `herdr --remote <host>.ssh.<zone>` attaches (else the `~/.zshenv.local` PATH fix); repeat with an expired Access token after `cloudflared access login`, and confirm it never hangs silently
- P6 `claude remote-control` in a herdr pane, reachable from the mobile app
- P7 removing the pubkey from `authorized_keys` makes ssh refuse after the Access login

Each pass or skip becomes a dated line under "Verified on" in the README in a follow-up commit.

## Re-anchoring

Line numbers were read at main `682d9db`. Anchor on the quoted neighbor text (`Include ~/.ssh/config_local`, `ln -sf "$DOTFILEDIR"/bin/identity-doctor`, `sh install/install.test.sh` in the SUITES list, the `### Identity Routing` heading) rather than the numbers if the files have moved.
