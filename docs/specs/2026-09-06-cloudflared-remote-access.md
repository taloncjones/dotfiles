# Spec: Remote access to herdr and Claude sessions via Cloudflare Tunnel + Access

Date: 2026-09-06
Branch: talon/td-2026-09-05-explore-cloudflared-tunnel-access-remote-access-to/cloudflared-access
Source task: td-2026-09-05-explore-cloudflared-tunnel-access-remote-access-to
Status: branch-only document; dropped before merge together with the plan.
Review: Codex spec review could not run on 2026-09-06 (Codex usage limit,
reset 23:08 local); a fresh-context independent reviewer stood in and its
ten findings (IdentityFile form, AC5/AC6/AC8 testability, phase gating,
token expiry, P5 limits) are folded in below.

## Problem

Remote access between machines that host herdr and Claude Code sessions
was planned on Cloudflare WARP warp-to-warp. WARP was retired on
2026-09-05 (commit `eae6afa`): as a full-tunnel VPN it conflicted with
Proton VPN, which is now the default VPN because it is paid for and can
pick exit countries. Nothing replaced it. There is no path today to
attach to a herdr session on another machine.

## Verdict

Proceed, with the live probe as the gate. Cloudflare Tunnel plus Access
over SSH is the right shape for this repo: both ends speak only outbound
HTTPS, so it coexists with Proton VPN; Access adds an identity gate in
front of sshd; `cloudflared` is already in the common Brewfile; and
herdr's own remote attach (`herdr --remote <ssh-target>`) is SSH, so no
herdr-specific plumbing is needed. Claude Remote Control needs no tunnel
at all (see D2). The one thing this repo cannot settle offline is
whether the tunnel behaves under Proton on both ends and whether herdr's
remote attach finds `herdr` on the host's SSH command path; those are
the Phase 1 probe (Section "Phase 1"), human-verify. Phase 2's repo
changes are inert until a real zone is configured and may merge before
the probe runs; the README section carries a prominent `Status:` line
that reads unverified until probe results are recorded, so a reader
cannot mistake the runbook for a proven one. The human performs the D3
host steps ad hoc during Phase 1 from this spec; Phase 2 codifies them
in the README, amended by whatever the probe changed.

## Goal

1. Answer the exploration question (above) and record the decision and
   its reasons durably in the README, since `docs/` is branch-only.
2. Phase 1: a runbook for the human-verify probe with a results record.
3. Phase 2: the dotfiles changes that make the client and host sides
   reproducible on a fresh machine: an SSH config Include backed by a
   machine-local template, a read-only doctor, docs, and tests. No
   machine-state mutation from the installer (no tunnel creation, no
   service install, no Remote Login toggling).

## Non-goals

- No Cloudflare account, zone, tunnel, Access application, or DNS record
  is created by anything in this repo. Those are runbook steps a human
  performs once per host.
- No tunnel token, Access service token, or credentials file is written
  to the repo or to a template. Tokens live in the host's launchd or
  systemd unit as installed by `cloudflared service install`, or in
  `~/.cloudflared/`, both machine-local.
- No `cloudflared service install` or `launchctl`/`systemctl` mutation
  from `install/` or `bin/`. The doctor is read-only.
- No Cloudflare browser-rendered SSH terminal, short-lived certificates,
  or WARP-based private routing. Plain `cloudflared access ssh` as a
  `ProxyCommand` is enough for `ssh` and `herdr --remote`.
- No Tailscale, ZeroTier, WireGuard, or router port-forwarding path.
  Rejected in "Alternatives".
- No change to `claude/hooks/herdr_orch_core.py`,
  `claude/skills/herdr-orchestration/`, `claude/skills/co-review/`,
  `git/hooks/commit-msg`, or `install/common/codex-*`. A parallel branch
  owns them.
- No network calls from the verification contract. Every live check is
  human-verify.

## Confirmed facts (2026-09-06, worktree at main `682d9db`)

- `brew "cloudflared"` is in `install/common/Brewfile.rb:68` (all
  platforms). The WARP cask is gone from `install/macos/Brewfile.rb`.
  Local `cloudflared` is 2026.8.2.
- `herdr --help` (local 0.8.2) lists `herdr --remote <ssh-target>
  [--session <name>]`, "Attach through SSH to a remote Herdr server",
  plus `--remote-keybindings <local|server>` and `--handoff`. Remote
  attach is therefore an SSH problem; nothing herdr-specific needs to
  cross the tunnel.
- `claude remote-control --help` (local): "Control local sessions from
  claude.ai/code or the Claude mobile app ... runs as a persistent
  server". The host dials out to Anthropic; the client is a browser or
  the mobile app. No inbound path and no tunnel are involved.
- `cloudflared access ssh` (alias of `access tcp`) takes `--hostname`
  and proxies to the Cloudflare edge over HTTPS; `cloudflared access
  ssh-config --hostname <h>` prints the `ProxyCommand` stanza. Both are
  local help text; no network was used.
- `ssh/configs/config` Includes `~/.ssh/config_local` (machine-local,
  untracked), then `config_personal`, then `config_work`, then a
  `Host *` block that sets the 1Password `IdentityAgent`. First value
  per option wins, so a Host block in an earlier Include takes
  precedence.
- `install/common/link.sh:64-76` symlinks the tracked SSH files and
  seeds `agent.toml` machine-local through `seed_machine_local_file`
  (`install/common/claude-links.sh:23`). That helper copies a template
  once and replaces a pre-existing symlink with a file. This is the
  existing pattern for "tracked template, machine-local values".
- `install/common/link.sh:93-96` links `bin/identity-doctor` and friends
  into `~/bin`. `bin/identity-doctor` is a read-only bash checker with
  `ok/warn/info/fail` printers and exit 1 on any `[X]`.
- `zsh/.zshenv` sets no PATH; Homebrew's PATH comes from
  `zsh/.zprofile` (login shells only). An SSH command shell
  (`ssh host cmd`) is non-login and non-interactive, so `herdr`,
  `cloudflared`, and `claude` are not on PATH there unless herdr's
  remote attach starts a login shell or the host adds Homebrew to PATH
  in `~/.zshenv.local`. Whether this bites `herdr --remote` is a probe
  item (P5). The doctor cannot detect it: it reads the client's PATH,
  not the host's non-login SSH PATH, so P5 stays human-verify.
- `bin/dotfiles-tests` runs 20 POSIX `sh`/`bash` suites, also on
  Ubuntu in CI (`.github/workflows/tests.yml`), which also `bash -n`s
  every `bin/*` script except `*.test.sh`. `rg` is available in CI and
  used by `install/install.test.sh`.
- `git/hooks/public-safety.test.sh` fails on tracked local user paths and
  high-confidence secrets. The tunnel token format (a long base64 blob)
  is not in its regex list, so the "no tokens in repo" rule is enforced
  by design and review, plus the contract's template grep (AC3).
- `~/.ssh/config_local` does not exist on this machine. No cloudflared
  SSH config exists anywhere locally yet.

## Design

### D1. Topology

```
client laptop                      Cloudflare edge                 session host
ssh <host>.ssh.<zone>  --HTTPS-->  Access policy (identity)  <--HTTPS/QUIC--  cloudflared tunnel
  ProxyCommand                     then WebSocket relay            ingress ssh://localhost:22
  cloudflared access ssh                                            sshd (key auth, 1Password pubkey)
herdr --remote <host>.ssh.<zone>                                    herdr server (persistent session)
```

- One tunnel per host, named for the host. One public hostname per
  host, `<host>.ssh.<zone>`, routed to that tunnel with ingress
  `ssh://localhost:22`.
- One Access self-hosted application per hostname (or one app with a
  wildcard `*.ssh.<zone>`), policy: allow the owner's identity only.
- The client's `ssh` uses `ProxyCommand cloudflared access ssh
  --hostname %h`. `cloudflared` opens a browser once for the Access
  login and caches the token under `~/.cloudflared/`.
- `herdr --remote <host>.ssh.<zone>` reuses the same SSH config; the
  hostname is the ssh target. No `herdr integration install` is needed
  or allowed (CLAUDE.md standing rule); SSH is all herdr needs.
- Access token expiry: `cloudflared access ssh` opens a browser when the
  cached token is missing or expired (lifetime is the Access app's
  session duration, default 24 hours). Interactive `ssh` tolerates that;
  `herdr --remote` may hang waiting on a browser. The runbook says to run
  `cloudflared access login https://<host>.ssh.<zone>` first when the
  token may have expired, and P5 checks the expired-token attach.

### D2. Claude Remote Control needs no tunnel

`claude remote-control` is outbound-only on the host and served to
browsers and the mobile app by Anthropic. It is the answer for "drive a
Claude session on machine B from my phone" and needs nothing from this
spec except a place to keep the server alive: run it inside a herdr pane
on the host so it survives terminal close and sleep. The README states
this so nobody builds a tunnel for it. It is not a substitute for herdr
remote attach (a full terminal workspace), which is what the tunnel is
for.

### D3. Host side (runbook, machine-local)

Performed once per host by a human, never by the installer:

1. Enable Remote Login (macOS System Settings, or `sshd` on Linux).
   Optional hardening: `ListenAddress 127.0.0.1` in `sshd_config` so
   sshd is reachable only through the tunnel; the runbook presents this
   as a choice, since LAN SSH is also useful.
2. Put the personal public key (`ssh/keys/id_ed25519_personal.pub`,
   already linked to `~/.ssh/id_ed25519_personal.pub`) in
   `~/.ssh/authorized_keys`. Password auth off.
3. `cloudflared tunnel login`, `cloudflared tunnel create <host>`,
   `cloudflared tunnel route dns <host> <host>.ssh.<zone>`.
4. Ingress config or a dashboard-managed tunnel with public hostname
   `<host>.ssh.<zone>` -> `ssh://localhost:22`.
5. `cloudflared service install <token>` (launchd on macOS, systemd on
   Linux). The token is a secret and stays in the unit.
6. Access application for the hostname with an allow policy on the
   owner's login identity.

The runbook records the exact commands with `<host>` and `<zone>`
placeholders, the `cloudflared access login` pre-step for expired
tokens, and points at the doctor for the read-only checks. The doctor
does not detect host-side PATH or sshd state.

### D4. Client side (tracked template, machine-local values)

- New tracked template `ssh/configs/config_cloudflared.tmpl`:

  ```
  # Cloudflare Access SSH hosts. Seeded machine-local from
  # ssh/configs/config_cloudflared.tmpl; edit the zone below, never
  # the template. The placeholder pattern matches nothing until edited.
  Host *.ssh.example.com
      ProxyCommand cloudflared access ssh --hostname %h
      IdentityFile ~/.ssh/id_ed25519_personal
      IdentitiesOnly yes
  ```

  The `Host` pattern uses the reserved `example.com` so the seeded file
  is inert until the human replaces the zone. No real zone ever enters
  the repo (public repo; a real hostname invites probing even though
  Access would refuse it).
- `install/common/link.sh` seeds it with `seed_machine_local_file` to
  `~/.ssh/config_cloudflared` (not a symlink), next to the existing
  `agent.toml` seed.
- `ssh/configs/config` gains `Include ~/.ssh/config_cloudflared` after
  `config_local` and before `config_personal`, so a machine-local
  override in `config_local` still wins, and the personal `github.com`
  block is unaffected (`*.ssh.<zone>` never matches it). ssh ignores a
  missing Include, so pre-seed machines are safe.
- The 1Password agent supplies the private key. `IdentityFile
  ~/.ssh/id_ed25519_personal` names the private-key path with no `.pub`
  suffix, exactly as `config_personal` does: only the `.pub` exists on
  disk, and OpenSSH appends `.pub`, reads it, and asks the agent for the
  matching key. `IdentitiesOnly yes` stops the agent offering the work
  key.

### D5. Read-only doctor

New `bin/remote-access-doctor`, linked to `~/bin/remote-access-doctor`
by `install/common/link.sh`, modelled on `identity-doctor` (same
printers, exit 1 on any `[X]`). Checks, all file and PATH reads, no
network, no service mutation:

| Check | Verdict |
|---|---|
| `cloudflared` on PATH | `[X]` if missing (Brewfile drift) |
| `~/.ssh/config` Includes `config_cloudflared` | `[X]` if missing |
| `~/.ssh/config_cloudflared` exists and is a regular file | `[X]` if missing or a symlink |
| the seeded file still has the `example.com` placeholder | `[WARNING]` "client not configured" |
| `~/.cloudflared/` has any Access token file | `[INFO]` logged in / not yet |
| host role: a tunnel service unit exists (`~/Library/LaunchAgents/com.cloudflare.cloudflared.plist`, `/Library/LaunchDaemons/com.cloudflare.cloudflared.plist`, or `/etc/systemd/system/cloudflared.service`) | `[INFO]` host / not a host |
| host role: `~/.ssh/authorized_keys` contains the personal pubkey | `[WARNING]` when a unit exists but the key is absent |

`HOME` and `PATH` are the only inputs, so the test suite can drive every
branch with a temporary `HOME` and stub binaries. Live checks (sshd
listening, tunnel connected, `cloudflared tunnel info`) stay in the
runbook because they need the network or root.

### D6. Docs

- `README.md`: new `### Remote Access` section under Key Commands (next
  to Identity Routing): the decision and reasons (why cloudflared, why
  not WARP, Tailscale, or port forwarding), the D2 Remote Control note,
  the host runbook (D3), the client steps (edit zone, first login,
  `ssh`, `herdr --remote`), the VPN note (D7), and the doctor. This is
  the durable record of the exploration's answer.
- `CLAUDE.md` symlink-targets list: one bullet for the template seed and
  one for the doctor, in the existing bullet style.
- `README.md` Directory Structure: `bin/remote-access-doctor` and the
  template, if those lists enumerate siblings.

### D7. VPN coexistence

- Client: `cloudflared access ssh` is a WebSocket over HTTPS to the
  edge. Under Proton (or any VPN) it is ordinary TCP 443 egress.
- Host: `cloudflared tunnel` prefers QUIC on UDP 7844 and falls back to
  HTTP/2 over TCP 443. Some VPNs drop or flap UDP; the runbook says to
  set `protocol: http2` in the tunnel config (or `--protocol http2`) if
  the probe shows reconnect loops under Proton.
- Neither side installs a network extension, changes DNS, or adds
  routes. This is the property WARP lacked.

### D8. Safety

- Inbound exposure on the host is zero: the tunnel is outbound, sshd
  need not be reachable from the internet, and with `ListenAddress
  127.0.0.1` not even from the LAN.
- Two independent gates before a shell: Access (identity provider login
  bound to the owner's identity) and sshd public-key auth (private key
  never leaves the 1Password agent).
- SSH remains end-to-end encrypted through the relay; Cloudflare sees
  the WebSocket, not the SSH plaintext.
- Secrets: tunnel token in the service unit, Access token in
  `~/.cloudflared/`, both machine-local and outside the repo. The
  template carries no zone, no token, no user.
- Blast radius of a lost laptop: revoke the Access session in the
  dashboard and remove the pubkey from `authorized_keys`. Documented in
  the runbook.

### D9. What the repo does and does not automate

| Concern | Where |
|---|---|
| cloudflared binary | Brewfile (already) |
| client SSH stanza | template seed + Include (D4) |
| host sshd, tunnel, Access, DNS | runbook only (D3) |
| checks | doctor (D5, read-only) and runbook live checks |
| decision record | README (D6) |

## Phase 1: probe (human-verify, gates the runbook)

Prerequisites: a Cloudflare account with one zone and a Zero Trust
organization (free tier is enough for one user). Zone name is the
human's choice and never appears in the repo.

| # | Probe | Pass condition |
|---|---|---|
| P1 | Host tunnel up via `cloudflared service install`, `cloudflared tunnel info <host>` shows a connector | connector listed, survives host sleep/wake |
| P2 | Access app created, `ssh <host>.ssh.<zone>` from the client opens the browser login once, then a shell | shell with no password prompt |
| P3 | Client on Proton VPN, host off VPN | P2 still passes |
| P4 | Host on Proton VPN | connector stays up for 10 minutes; if it flaps, `protocol: http2` fixes it |
| P5 | `herdr --remote <host>.ssh.<zone>` attaches to the host's running session; repeat after the Access token expires (or after deleting `~/.cloudflared/` token files) | herdr UI shows the remote panes; if `herdr: command not found`, adding Homebrew's bin to `~/.zshenv.local` on the host fixes it; the expired-token attach either opens the browser or fails fast after `cloudflared access login`, never hangs silently |
| P6 | `claude remote-control` inside a herdr pane on the host, connect from the mobile app | session visible and steerable, no tunnel involved |
| P7 | Remove the pubkey from `authorized_keys` | `ssh` is refused after the Access login (second gate proven) |

Results go in the README Remote Access section: the `**Status:**` line
flips from `unverified` to a dated summary, and one dated line per probe
records pass, fail, or skipped.
If P1 to P3 fail for a structural reason (for example Access refusing
the SSH app type on the free tier), the README records "do not" with the
reason and the D4/D5 pieces stay inert; nothing needs removing.

## Phase 2: repo changes (R)

- R1 `ssh/configs/config_cloudflared.tmpl` (new, D4).
- R2 `ssh/configs/config` gains the Include line (D4).
- R3 `install/common/link.sh` seeds the template and links the doctor.
- R4 `bin/remote-access-doctor` (new, D5).
- R5 `bin/remote-access-doctor.test.sh` (new) registered in
  `bin/dotfiles-tests`.
- R6 `install/install.test.sh` asserts for R1 to R3.
- R7 `README.md` and `CLAUDE.md` (D6).
- R8 Files that may change: exactly R1 to R7's files plus `docs/` and
  `claude/contracts/`. Nothing else.

## Acceptance criteria

- AC1 `ssh/configs/config` contains `Include ~/.ssh/config_cloudflared`
  on a line after `Include ~/.ssh/config_local` and before
  `Include ~/.ssh/config_personal`.
- AC2 `ssh/configs/config_cloudflared.tmpl` exists, contains
  `ProxyCommand cloudflared access ssh --hostname %h`, and every `Host`
  line's pattern ends in `.ssh.example.com`.
- AC3 The template contains no token-like string (no `eyJ` JWT prefix,
  no run of 60 or more base64/url-safe characters) and no domain other
  than `example.com`; the tracked SSH config contains no `eyJ` prefix
  and no 60-character run either.
- AC4 `install/common/link.sh` calls `seed_machine_local_file` with the
  template and `$HOME/.ssh/config_cloudflared`, never `ln -s` for it,
  and links `bin/remote-access-doctor` into `~/bin`.
- AC5 `bin/remote-access-doctor` is executable, passes `bash -n`, and
  has no non-comment line containing `sudo`, `launchctl load`,
  `launchctl bootstrap`, `launchctl kickstart`, `systemctl enable`,
  `systemctl start`, `systemctl restart`, `cloudflared tunnel`, or
  `cloudflared service`. Comment lines (leading `#`) are exempt so the
  header can point at the runbook.
- AC6 With a temporary `HOME` (holding a real-file copy of the tracked
  `ssh/configs/config` and of the template) and a stub `cloudflared` on
  `PATH`: a seeded-but-unedited client exits 0 and prints a `[WARNING]`
  line containing `not configured`; a client whose zone was edited to
  `ssh.example.com.test` (the reserved `.test` TLD, never a real zone)
  exits 0 with an `[OK]` line for the Include and no `[X]` line; a
  client whose `~/.ssh/config` lacks the Include exits 1 with an `[X]`
  line. No test ever writes a real zone.
- AC7 `bin/remote-access-doctor.test.sh` is registered in
  `bin/dotfiles-tests` and passes; `install/install.test.sh` and
  `install/claude-links.test.sh` pass; every file this branch adds or
  changes outside `docs/` and `claude/contracts/` is free of `/Users/`
  paths and high-confidence secret patterns (the public-safety suite's
  own "no tracked planning artifacts" check fails by design while the
  branch-only spec and plan are tracked, so the contract applies the
  other two checks to the changed files directly).
- AC8 `README.md` has a `### Remote Access` section that opens with a
  `**Status:**` line (reading `unverified` until probe results replace
  it), names `cloudflared access ssh`, `herdr --remote`,
  `claude remote-control`, `remote-access-doctor`, `cloudflared access
  login`, states why WARP and Tailscale were not chosen, and says
  `herdr integration install` is not needed; `CLAUDE.md` names
  `config_cloudflared.tmpl` and `remote-access-doctor`.
- AC9 Changed files (excluding `docs/` and `claude/contracts/`) are
  within R8; added lines are ASCII.
- AC10 Phase 1 probes P1 to P7: human-verify, recorded in the README.

## Verification

Contract commands (repo-local, hermetic) cover AC1 to AC9; the mapping
table lives in the plan. AC10 is human-verify by definition (needs a
Cloudflare account, a second machine, and Proton VPN). The doctor is
tested only with stubbed `HOME` and `PATH`; its behaviour against a real
launchd unit is asserted, not demonstrated, until P1.

## Alternatives rejected

- WARP warp-to-warp: retired 2026-09-05; full-tunnel client conflicts
  with Proton VPN (leftover loopback DNS killed connectivity).
- Tailscale or ZeroTier: a second tun interface and route table on a
  Proton-connected Mac; the same class of conflict, and it defeats
  Proton's exit-country selection. Not revisited unless Proton is
  dropped.
- Router port-forward plus dynamic DNS: exposes sshd to the internet,
  needs router control on every network, fails behind CGNAT and on
  mobile hotspots.
- Cloudflare browser-rendered SSH: useful for a phone but not for
  `herdr --remote`; can be added later on the same tunnel with no repo
  change.
- Claude Remote Control alone: covers Claude sessions, not herdr
  workspaces; kept as the zero-infrastructure first step (D2).

## Open assumptions

- A1 The owner has, or will create, a zone on Cloudflare. If not, the
  spec's answer degrades to "Remote Control only" (D2) and the D4/D5
  pieces stay inert.
- A2 `herdr --remote` needs only `ssh` reachability and `herdr` on the
  host's command PATH (P5). If it needs a specific herdr version match,
  the runbook notes `herdr update` on both ends.
- A3 The Zero Trust free tier admits self-hosted SSH applications for
  one user. Cloudflare's published free-tier limits say so as of the
  author's knowledge; confirmed by P2.
