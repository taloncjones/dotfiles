#!/usr/bin/env bash
# op-env.test.sh -- behavioral tests for bin/op-env, bin/op-env-sign and
# git/agent-https.gitconfig. A fake `op` stands in for 1Password; ssh-agent,
# ssh-keygen and git are real. No network, no real 1Password, no writes
# outside a mktemp root.
#
# Fixture tokens are built at runtime so no secret-shaped literal lands in
# this file.

set -u
unset OP_ENV_FILE OP_ENV_ACTIVE OP_SERVICE_ACCOUNT_TOKEN GIT_CONFIG_SYSTEM
unset GIT_CONFIG_COUNT GH_TOKEN CLOUDFLARE_API_TOKEN

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OP_ENV="$ROOT/bin/op-env"
for tool in git ssh-agent ssh-add ssh-keygen; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }
done

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/op-env-test.XXXXXX")"
TMP="$(cd -P "$TMP" && pwd)"
AGENT_PIDS=()
cleanup() {
    local f
    for f in "$TMP"/s*/op-env-signing.pid; do
        [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
    done
    rm -rf "$TMP"
}
trap cleanup EXIT

export HOME="$TMP/home"
export GIT_CONFIG_GLOBAL="$TMP/global.gitconfig"
export GIT_CONFIG_NOSYSTEM=1
export OP_LOG="$TMP/op.log"
mkdir -p "$HOME" "$TMP/fakebin"
printf '[user]\n\temail = test@example.invalid\n\tname = Test\n' >"$GIT_CONFIG_GLOBAL"
FIXTURE_TOKEN="ops_$(printf 'q%.0s' $(seq 1 32))"
LITERAL="lit$(printf 'z%.0s' $(seq 1 20))"

# Fake op: `run` resolves every NAME=op://... in --env-file to
# "resolved-NAME" and execs the command; `read` serves FAKE_OP_KEY.
# It logs argv and whether the token reached it, never the token itself.
cat >"$TMP/fakebin/op" <<'EOF'
#!/bin/sh
printf '%s token=%s\n' "$*" "${OP_SERVICE_ACCOUNT_TOKEN:+set}" >>"$OP_LOG"
[ "${FAKE_OP_MODE:-}" = sleep ] && sleep 30
[ "${FAKE_OP_MODE:-}" = fail ] && exit 1
[ -n "${FAKE_OP_DELAY:-}" ] && sleep "$FAKE_OP_DELAY"
case "$1" in
    run)
        shift
        envfile=""
        while [ "$1" != -- ]; do
            [ "$1" = --env-file ] && { envfile="$2"; shift; }
            shift
        done
        shift
        for name in $(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$envfile"); do
            export "$name=${FAKE_OP_VALUE:-resolved-$name}"
        done
        exec "$@"
        ;;
    read)
        case "$2" in
            *"/private key?ssh-format=openssh") cat "$FAKE_OP_KEY" ;;
            *"/public key") cat "$FAKE_OP_KEY.pub" ;;
            *) exit 1 ;;
        esac
        ;;
esac
EOF
chmod +x "$TMP/fakebin/op"
export PATH="$TMP/fakebin:$PATH"

REPO="$HOME/Git/personal/proj"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m seed

write_op_env() {
    printf 'OP_SERVICE_ACCOUNT_TOKEN=%s\n' "$FIXTURE_TOKEN" >"$REPO/op.env"
    [ $# -gt 0 ] && printf '%s\n' "$@" >>"$REPO/op.env"
    chmod 600 "$REPO/op.env"
}

# --- 1. unconfigured: nothing printed, nothing called ---
: >"$OP_LOG"
out="$("$OP_ENV" shell-exports --cwd "$REPO" 2>"$TMP/err")"; rc=$?
check "unconfigured: shell-exports prints nothing and exits 0" '[ -z "$out" ] && [ "$rc" = 0 ] && [ ! -s "$TMP/err" ]'
check "unconfigured: locate prints nothing" '[ -z "$("$OP_ENV" locate --cwd "$REPO")" ]'
check "unconfigured: op is never called" '[ ! -s "$OP_LOG" ]'

# --- 2. op.env validation ---
write_op_env
chmod 644 "$REPO/op.env"
out="$("$OP_ENV" shell-exports --cwd "$REPO" 2>"$TMP/err")"
check "op.env mode 644 is refused with no output" '[ -z "$out" ] && grep -q "mode is 644, expected 600" "$TMP/err"'
check "op.env mode refusal calls no op" '[ ! -s "$OP_LOG" ]'
check "op.env refusal never prints the token" '! grep -qF "$FIXTURE_TOKEN" "$TMP/err"'

write_op_env "OP_MYSTERY=1"
out="$("$OP_ENV" shell-exports --cwd "$REPO" 2>"$TMP/err")"
check "op.env unknown key is refused" '[ -z "$out" ] && grep -q "unknown key OP_MYSTERY" "$TMP/err"'

write_op_env "OP_SIGNING_KEY=op://V/sign"
out="$("$OP_ENV" shell-exports --cwd "$REPO" 2>"$TMP/err")"
check "OP_SIGNING_KEY without OP_SIGNING_PUBKEY is refused" '[ -z "$out" ] && grep -q "OP_SIGNING_PUBKEY is missing" "$TMP/err"'

# --- 3. project.env validation ---
write_op_env
printf '# refs\nGH_TOKEN=op://V/gh/token\nCLOUDFLARE_API_TOKEN=%s\n' "$LITERAL" >"$REPO/project.env"
out="$("$OP_ENV" shell-exports --cwd "$REPO" 2>"$TMP/err")"
check "literal project.env line is refused by line and name" '[ -z "$out" ] && grep -q "project.env line 3 (CLOUDFLARE_API_TOKEN) is not an op:// reference" "$TMP/err"'
check "literal value never printed" '! grep -qF "$LITERAL" "$TMP/err"'
check "literal refusal calls no op" '[ ! -s "$OP_LOG" ]'

# --- 4. resolution ---
printf 'GH_TOKEN=op://V/gh/token\nCLOUDFLARE_API_TOKEN="op://V/cf/credential"\n' >"$REPO/project.env"
out="$("$OP_ENV" shell-exports --cwd "$REPO" 2>"$TMP/err")"
check "resolved GH_TOKEN is exported" 'printf "%s\n" "$out" | grep -qx "export GH_TOKEN='"'"'resolved-GH_TOKEN'"'"'"'
check "resolved CLOUDFLARE_API_TOKEN is exported" 'printf "%s\n" "$out" | grep -q "^export CLOUDFLARE_API_TOKEN="'
check "service-account token never printed" '! printf "%s" "$out" | grep -qF "$FIXTURE_TOKEN" && ! grep -qF "$FIXTURE_TOKEN" "$TMP/err"'
check "OP_SERVICE_ACCOUNT_TOKEN is not exported" '! printf "%s" "$out" | grep -q OP_SERVICE_ACCOUNT_TOKEN'
check "op run used --no-masking and --env-file with the token" 'grep -q "^run --no-masking --env-file $REPO/project.env -- .* token=set$" "$OP_LOG"'
check "OP_ENV_FILE and OP_ENV_ACTIVE are exported" 'printf "%s\n" "$out" | grep -qx "export OP_ENV_FILE='"'"'$REPO/op.env'"'"'" && printf "%s\n" "$out" | grep -qx "export OP_ENV_ACTIVE=1"'
check "GH_TOKEN turns on HTTPS push" 'printf "%s\n" "$out" | grep -qx "export GIT_CONFIG_SYSTEM='"'"'$ROOT/git/agent-https.gitconfig'"'"'"'
check "locate prints the op.env path" '[ "$("$OP_ENV" locate --cwd "$REPO")" = "$REPO/op.env" ]'

git -C "$REPO" worktree add -q "$TMP/wt" -b wt
out="$("$OP_ENV" shell-exports --cwd "$TMP/wt" 2>/dev/null)"
check "a linked worktree resolves the main checkout's files" 'printf "%s\n" "$out" | grep -q "^export GH_TOKEN="'

out="$(cd "$REPO" && "$OP_ENV" exec -- sh -c 'printf %s "$GH_TOKEN"')"
check "exec runs the command with resolved values" '[ "$out" = resolved-GH_TOKEN ]'

printf 'CLOUDFLARE_API_TOKEN=op://V/cf/credential\n' >"$REPO/project.env"
out="$("$OP_ENV" shell-exports --cwd "$REPO" 2>/dev/null)"
check "no GH_TOKEN means no HTTPS push override" '! printf "%s" "$out" | grep -q GIT_CONFIG_SYSTEM'

# A value with a quote and a newline survives eval in bash and zsh.
TRICKY="it's
two lines"
out="$(FAKE_OP_VALUE="$TRICKY" "$OP_ENV" shell-exports --cwd "$REPO" 2>/dev/null)"
got="$(bash -c 'eval "$1"; printf %s "$CLOUDFLARE_API_TOKEN"' _ "$out")"
check "a quoted multi-line value round-trips through bash eval" '[ "$got" = "$TRICKY" ]'
if command -v zsh >/dev/null 2>&1; then
    got="$(zsh -fc 'eval "$1"; printf %s "$CLOUDFLARE_API_TOKEN"' _ "$out")"
    check "a quoted multi-line value round-trips through zsh eval" '[ "$got" = "$TRICKY" ]'
fi

# --- 5. op calls are bounded ---
printf 'GH_TOKEN=op://V/gh/token\n' >"$REPO/project.env"
start=$SECONDS
out="$(FAKE_OP_MODE=sleep OP_ENV_OP_TIMEOUT=2 "$OP_ENV" shell-exports --cwd "$REPO" 2>"$TMP/err")"
check "a hung op returns within 10 s" '[ $((SECONDS - start)) -lt 10 ]'
check "a hung op warns and exports no credentials" 'grep -q "^\[WARNING\] op-env: op run failed or timed out" "$TMP/err" && ! printf "%s" "$out" | grep -q GH_TOKEN'
out="$(FAKE_OP_MODE=fail "$OP_ENV" shell-exports --cwd "$REPO" 2>/dev/null)"
check "a failed op run clears the active marker" '! printf "%s" "$out" | grep -q "export OP_ENV_ACTIVE" && printf "%s\n" "$out" | grep -qx "unset OP_ENV_ACTIVE" && printf "%s" "$out" | grep -q "^export OP_ENV_FILE="'
got="$( (export OP_ENV_ACTIVE=1 OP_ENV_FILE=/elsewhere/op.env; eval "$out"; "$OP_ENV" status --cwd "$REPO") )"
check "status after a failed op run says not active" 'printf "%s\n" "$got" | grep -q "^\[INFO\] *credentials: configured (1 references), not active in this shell"'

# --- 6. HTTPS push for every remote form ---
cat >"$TMP/identity.gitconfig" <<'EOF'
[url "git@Git-Personal:"]
	insteadOf = git@github.com:
	insteadOf = ssh://git@github.com/
	pushInsteadOf = https://github.com/
EOF
printf '[include]\n\tpath = %s\n' "$TMP/identity.gitconfig" >>"$GIT_CONFIG_GLOBAL"
for form in pushurl scp https alias; do git init -q "$TMP/r-$form"; done
git -C "$TMP/r-pushurl" remote add origin https://github.com/o/r.git
git -C "$TMP/r-pushurl" remote set-url --push origin git@Git-Personal:o/r.git
git -C "$TMP/r-scp" remote add origin git@github.com:o/r.git
git -C "$TMP/r-https" remote add origin https://github.com/o/r.git
git -C "$TMP/r-alias" remote add origin git@Git-Personal:o/r.git
check "fixture: identity rewrites push over SSH without op-env" '[ "$(git -C "$TMP/r-https" remote get-url --push origin)" = git@Git-Personal:o/r.git ]'
exports="$("$OP_ENV" shell-exports --cwd "$REPO" 2>/dev/null)"
for form in pushurl scp https alias; do
    got="$( (unset GIT_CONFIG_NOSYSTEM; eval "$exports"; git -C "$TMP/r-$form" remote get-url --push origin) )"
    check "$form remote pushes over HTTPS" '[ "$got" = https://github.com/o/r.git ]'
    got="$( (unset GIT_CONFIG_NOSYSTEM; eval "$exports"; git -C "$TMP/r-$form" remote get-url origin) )"
    check "$form remote fetches over HTTPS" '[ "$got" = https://github.com/o/r.git ]'
done
cred="$( (unset GIT_CONFIG_NOSYSTEM; eval "$exports"; printf 'protocol=https\nhost=github.com\n\n' | GIT_TERMINAL_PROMPT=0 git -C "$TMP/r-https" credential fill) )"
check "credential helper answers from GH_TOKEN" 'printf "%s\n" "$cred" | grep -qx "username=x-access-token" && printf "%s\n" "$cred" | grep -qx "password=resolved-GH_TOKEN"'

# --- 7. signing through a plain ssh-agent ---
ssh-keygen -q -t ed25519 -N '' -C op-env-test -f "$TMP/signkey"
export FAKE_OP_KEY="$TMP/signkey"
PUB="$(cat "$TMP/signkey.pub")"
SOCKDIR="$TMP/s1"
export OP_ENV_SIGNING_SOCK="$SOCKDIR/op-env-signing.sock"
rm -f "$REPO/project.env"
write_op_env "OP_SIGNING_KEY=op://V/sign" "OP_SIGNING_PUBKEY=$PUB" "OP_SIGNING_TTL=3"
printf 'test@example.invalid %s\n' "$PUB" >"$TMP/allowed_signers"
exports="$("$OP_ENV" shell-exports --cwd "$REPO" 2>/dev/null)"
check "signing exports set gpg.ssh.program to op-env-sign" 'printf "%s\n" "$exports" | grep -qx "export GIT_CONFIG_KEY_1=gpg.ssh.program GIT_CONFIG_VALUE_1='"'"'$ROOT/bin/op-env-sign'"'"'"'
check "signing exports never set commit.gpgsign" '! printf "%s" "$exports" | grep -q commit.gpgsign'
: >"$OP_LOG"
( eval "$exports"; git -C "$REPO" -c commit.gpgsign=true commit -q --allow-empty -m signed1 ) 2>"$TMP/err"
check "commit signs with 1Password absent" 'git -C "$REPO" -c gpg.ssh.allowedSignersFile="$TMP/allowed_signers" verify-commit HEAD 2>/dev/null'
check "the key was read once in OpenSSH format" '[ "$(grep -c "^read op://V/sign/private key?ssh-format=openssh token=set$" "$OP_LOG")" = 1 ]'
( eval "$exports"; git -C "$REPO" -c commit.gpgsign=true commit -q --allow-empty -m signed2 ) 2>/dev/null
check "a loaded key is not read again" '[ "$(grep -c "^read " "$OP_LOG")" = 1 ]'
sleep 4
( eval "$exports"; git -C "$REPO" -c commit.gpgsign=true commit -q --allow-empty -m signed3 ) 2>/dev/null
check "an expired key (TTL) reloads on the next signature" '[ "$(grep -c "^read " "$OP_LOG")" = 2 ] && git -C "$REPO" -c gpg.ssh.allowedSignersFile="$TMP/allowed_signers" verify-commit HEAD 2>/dev/null'

out="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=cat "$OP_ENV" shell-exports --cwd "$REPO" 2>/dev/null)"
check "signing entries append after an existing GIT_CONFIG_COUNT" 'printf "%s\n" "$out" | grep -q "^export GIT_CONFIG_KEY_1=gpg.format " && printf "%s\n" "$out" | grep -qx "export GIT_CONFIG_COUNT=4"'

# --- 8. concurrent first signatures and a stale lock ---
export OP_ENV_SIGNING_SOCK="$TMP/s2/op-env-signing.sock"
write_op_env "OP_SIGNING_KEY=op://V/sign" "OP_SIGNING_PUBKEY=$PUB"
# ssh-keygen prompts before overwriting a .sig, so every signer gets its own
# payload and stdin is closed.
for i in 1 2 3; do printf 'payload\n' >"$TMP/payload$i"; done
: >"$OP_LOG"
for i in 1 2; do
    ( OP_ENV_FILE="$REPO/op.env" FAKE_OP_DELAY=1 "$ROOT/bin/op-env-sign" -Y sign -n git -f "$TMP/signkey.pub" "$TMP/payload$i" </dev/null >/dev/null 2>&1; echo $? >"$TMP/rc$i" ) &
done
wait
check "concurrent first signatures both succeed" '[ "$(cat "$TMP/rc1")" = 0 ] && [ "$(cat "$TMP/rc2")" = 0 ]'
check "concurrent first signatures read the key once" '[ "$(grep -c "^read " "$OP_LOG")" = 1 ]'
check "concurrent first signatures start one agent" '[ "$(pgrep -f "ssh-agent -a $OP_ENV_SIGNING_SOCK" | wc -l | tr -d " ")" = 1 ]'

export OP_ENV_SIGNING_SOCK="$TMP/s3/op-env-signing.sock"
mkdir -p "$TMP/s3" "$OP_ENV_SIGNING_SOCK.lock"
touch -t 202001010000 "$OP_ENV_SIGNING_SOCK.lock"
start=$SECONDS
OP_ENV_FILE="$REPO/op.env" "$ROOT/bin/op-env-sign" -Y sign -n git -f "$TMP/signkey.pub" "$TMP/payload3" </dev/null >/dev/null 2>&1
rc=$?
check "a stale lock does not block signing" '[ "$rc" = 0 ] && [ $((SECONDS - start)) -lt 5 ]'

# --- 9. status ---
rm -f "$REPO/op.env"
out="$("$OP_ENV" status --cwd "$REPO")"; rc=$?
check "status unconfigured: three not-configured lines, exit 0" '[ "$rc" = 0 ] && [ "$(printf "%s\n" "$out" | grep -c "not configured")" = 3 ]'
write_op_env "OP_SIGNING_KEY=op://V/sign" "OP_SIGNING_PUBKEY=$PUB"
printf 'GH_TOKEN=op://V/gh/token\n' >"$REPO/project.env"
out="$("$OP_ENV" status --cwd "$REPO")"
check "status configured: credentials, push and signing not active" '[ "$(printf "%s\n" "$out" | grep -c "configured.*not active in this shell")" = 3 ]'
exports="$("$OP_ENV" shell-exports --cwd "$REPO" 2>/dev/null)"
: >"$OP_LOG"
out="$( (eval "$exports"; "$OP_ENV" status --cwd "$REPO") 2>&1)"
check "status active: three active lines" '[ "$(printf "%s\n" "$out" | grep -c "^\[OK\] .*active in this shell")" = 3 ]'
check "status never calls op or prints the token" '[ ! -s "$OP_LOG" ] && ! printf "%s" "$out" | grep -qF "$FIXTURE_TOKEN"'
chmod 644 "$REPO/op.env"
out="$("$OP_ENV" status --cwd "$REPO")"; rc=$?
check "status reports a bad mode as [X] and exits 1" '[ "$rc" = 1 ] && printf "%s\n" "$out" | grep -q "^\[X\] .*mode is 644"'

# --- 10. setup-op ---
SETUP="$ROOT/bin/setup-op"
REPO2="$HOME/Git/personal/proj2"
git init -q "$REPO2"
out="$(cd "$REPO2" && printf '%s\n' "$FIXTURE_TOKEN" | "$SETUP" 2>&1)"; rc=$?
check "setup-op first run exits 0" '[ "$rc" = 0 ]'
check "setup-op writes op.env mode 600 with the token" '[ "$(stat -c %a "$REPO2/op.env" 2>/dev/null || stat -f %Lp "$REPO2/op.env")" = 600 ] && grep -qx "OP_SERVICE_ACCOUNT_TOKEN=$FIXTURE_TOKEN" "$REPO2/op.env"'
check "setup-op never prints the token" '! printf "%s" "$out" | grep -qF "$FIXTURE_TOKEN"'
check "setup-op template has no active assignment" '[ "$(grep -v "^#" "$REPO2/project.env" | grep -c "=")" = 0 ]'
check "setup-op excludes project.env" 'grep -qx project.env "$REPO2/.git/info/exclude"'
check "setup-op leaves no temp file" '[ -z "$(find "$REPO2" -maxdepth 1 -name ".op.env.*")" ]'
check "setup-op excludes op.env and its temp files" 'grep -qx "op.env" "$REPO2/.git/info/exclude" && grep -qxF ".op.env.*" "$REPO2/.git/info/exclude"'
check "setup-op leaves op.env untracked with no global ignore" '[ -z "$(git -C "$REPO2" status --short | grep "op.env")" ]'
before="$(cksum <"$REPO2/op.env")"
out="$(cd "$REPO2" && "$SETUP" </dev/null 2>&1)"
check "setup-op rerun leaves op.env untouched" '[ "$(cksum <"$REPO2/op.env")" = "$before" ] && printf "%s" "$out" | grep -q "pass --rotate"'
: >"$OP_LOG"
out="$(cd "$REPO2" && "$SETUP" --signing-key op://V/sign </dev/null 2>&1)"
check "setup-op --signing-key adds the reference and public key" 'grep -qx "OP_SIGNING_KEY=op://V/sign" "$REPO2/op.env" && grep -qxF "OP_SIGNING_PUBKEY=$PUB" "$REPO2/op.env"'
check "setup-op --signing-key keeps the token" 'grep -qx "OP_SERVICE_ACCOUNT_TOKEN=$FIXTURE_TOKEN" "$REPO2/op.env"'
check "setup-op read the public key with the token" 'grep -q "^read op://V/sign/public key token=set$" "$OP_LOG"'
printf 'OP_SIGNING_TTL=2h\n' >>"$REPO2/op.env"
signing_before="$(grep "^OP_SIGNING_" "$REPO2/op.env")"
NEWTOKEN="ops_$(printf 'r%.0s' $(seq 1 32))"
out="$(cd "$REPO2" && printf '%s\n' "$NEWTOKEN" | "$SETUP" --rotate 2>&1)"
check "setup-op --rotate replaces the token" 'grep -qx "OP_SERVICE_ACCOUNT_TOKEN=$NEWTOKEN" "$REPO2/op.env" && ! grep -qF "$FIXTURE_TOKEN" "$REPO2/op.env"'
check "setup-op --rotate keeps the signing lines byte-identical" '[ "$(grep "^OP_SIGNING_" "$REPO2/op.env")" = "$signing_before" ]'
check "setup-op --rotate output never prints either token" '! printf "%s" "$out" | grep -qF "$NEWTOKEN" && ! printf "%s" "$out" | grep -qF "$FIXTURE_TOKEN"'

out="$(cd "$REPO2" && printf '%s\n' "$NEWTOKEN" | "$SETUP" --rotate 2>&1)"
check "setup-op excludes are not duplicated on rerun" '[ "$(grep -cx "op.env" "$REPO2/.git/info/exclude")" = 1 ] && [ "$(grep -cxF ".op.env.*" "$REPO2/.git/info/exclude")" = 1 ] && [ "$(grep -cx "project.env" "$REPO2/.git/info/exclude")" = 1 ]'
printf 'keep\n' >"$REPO2/.op.env.bak"
out="$(cd "$REPO2" && printf '%s\n' "$NEWTOKEN" | "$SETUP" --rotate 2>&1)"
check "setup-op --rotate leaves a foreign .op.env.* file alone" '[ "$(cat "$REPO2/.op.env.bak")" = keep ]'
rm -f "$REPO2/.op.env.bak"
REPO3="$HOME/Git/personal/proj3"
git init -q "$REPO3"
printf '%s\n' "$FIXTURE_TOKEN" | (cd "$REPO3" && "$SETUP" >/dev/null 2>&1)
printf 'x\n' >"$REPO3/.op.env.keep"
out="$(cd "$REPO3" && printf '%s\n' "$FIXTURE_TOKEN" | FAKE_OP_MODE=fail "$SETUP" --signing-key op://V/missing 2>&1)"; rc=$?
check "setup-op failure leaves a foreign .op.env.* file and no own temp" '[ "$rc" != 0 ] && [ -f "$REPO3/.op.env.keep" ] && [ "$(find "$REPO3" -maxdepth 1 -name ".op.env.*" | wc -l | tr -d " ")" = 1 ]'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
