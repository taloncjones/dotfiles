#!/bin/sh
# zed-claude-agent.test.sh - drive bin/zed-claude-agent through a fake HOME
# and a stub npx. No network, no real HOME reads.
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
WRAPPER="$REPO/bin/zed-claude-agent"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKEHOME="/tmp/fakehome"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npx" <<'EOF'
#!/bin/sh
printf 'CLAUDE_CONFIG_DIR=%s\n' "$CLAUDE_CONFIG_DIR"
printf 'KEY_SET=%s\n' "${ANTHROPIC_API_KEY+yes}"
printf 'ARGS=%s\n' "$*"
EOF
chmod +x "$WORK/bin/npx"

run_wrapper() {
    HOME="$FAKEHOME" PATH="$WORK/bin:/usr/bin:/bin" bash "$WRAPPER" "$@"
}

# 1. personal account resolves CLAUDE_CONFIG_DIR from HOME
out="$(run_wrapper personal)"
assert "personal resolves CLAUDE_CONFIG_DIR under fake HOME" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^CLAUDE_CONFIG_DIR=/tmp/fakehome/.claude\$'"

# 2. work account resolves CLAUDE_CONFIG_DIR from HOME
out="$(run_wrapper work)"
assert "work resolves CLAUDE_CONFIG_DIR under fake HOME" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^CLAUDE_CONFIG_DIR=/tmp/fakehome/.claude-work\$'"

# 3. an empty ANTHROPIC_API_KEY is unset before exec
out="$(ANTHROPIC_API_KEY="" run_wrapper personal)"
assert "empty ANTHROPIC_API_KEY is unset, not passed through empty" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^KEY_SET=\$'"

# 4. the adapter version is pinned in the exec args
out="$(run_wrapper personal)"
assert "exec args pin the adapter version" \
    sh -c "printf '%s\n' \"$out\" | grep -q -- '-y @agentclientprotocol/claude-agent-acp@0.79.0'"

# 5. extra args after the account pass through
out="$(run_wrapper personal --foo bar)"
assert "extra args after the account pass through" \
    sh -c "printf '%s\n' \"$out\" | grep -q -- '--foo bar\$'"

bad_account() {
    status=0
    out=$(HOME="$FAKEHOME" PATH="$WORK/bin:/usr/bin:/bin" bash "$WRAPPER" bogus 2>&1) || status=$?
    [ "$status" = 2 ]
}

# 6. a bad account exits 2
assert "bad account exits 2" bad_account

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
