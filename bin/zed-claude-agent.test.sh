#!/bin/sh
# zed-claude-agent.test.sh - drive bin/zed-claude-agent through a fake HOME,
# a stub npx, and a stub account resolver. No network, no real HOME reads.
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
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAKEHOME="/tmp/fakehome"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/npx" <<'EOF'
#!/bin/sh
printf 'CONFIG_SET=%s\n' "${CLAUDE_CONFIG_DIR+yes}"
printf 'CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR-}"
printf 'PERSONAL=%s\n' "${WORKFLOW_PERSONAL_ACCOUNT-}"
printf 'KEY_SET=%s\n' "${ANTHROPIC_API_KEY+yes}"
printf 'ARGS=%s\n' "$*"
EOF
chmod +x "$WORK/bin/npx"

# A fake checkout so the wrapper resolves a stub resolver next to itself.
# STUB_KIND picks the account the stub claims the cwd belongs to, mirroring
# the real launch_env shapes (personal unsets CLAUDE_CONFIG_DIR, work pins it).
mkdir -p "$WORK/checkout/bin" "$WORK/checkout/claude/skills/lib"
cp "$REPO/bin/zed-claude-agent" "$WORK/checkout/bin/zed-claude-agent"
cat > "$WORK/checkout/claude/skills/lib/workflow_context.py" <<'EOF'
import json, os, sys

argv_out = os.environ.get("STUB_ARGV_OUT")
if argv_out:
    with open(argv_out, "w") as handle:
        handle.write(" ".join(sys.argv[1:]))

kind = os.environ.get("STUB_KIND", "personal")
home = os.environ["HOME"]
if kind == "work":
    launch = {"CLAUDE_CONFIG_DIR": home + "/.claude-work",
              "WORKFLOW_PERSONAL_ACCOUNT": None}
else:
    launch = {"CLAUDE_CONFIG_DIR": None, "WORKFLOW_PERSONAL_ACCOUNT": "1"}
json.dump({"kind": kind, "launch_env": launch}, sys.stdout)
EOF

# A second checkout with no resolver, to exercise the fallback path.
mkdir -p "$WORK/bare/bin"
cp "$REPO/bin/zed-claude-agent" "$WORK/bare/bin/zed-claude-agent"

run_wrapper() {
    HOME="$FAKEHOME" PATH="$WORK/bin:/usr/bin:/bin" \
        bash "$WORK/checkout/bin/zed-claude-agent" "$@"
}

run_bare() {
    HOME="$FAKEHOME" PATH="$WORK/bin:/usr/bin:/bin" \
        bash "$WORK/bare/bin/zed-claude-agent" "$@"
}

# ~/bin/zed-claude-agent is a symlink into the checkout, so exercise that path.
mkdir -p "$WORK/link"
ln -s "$WORK/checkout/bin/zed-claude-agent" "$WORK/link/zed-claude-agent"

run_linked() {
    HOME="$FAKEHOME" PATH="$WORK/bin:/usr/bin:/bin" \
        bash "$WORK/link/zed-claude-agent" "$@"
}

# 1. personal launches with CLAUDE_CONFIG_DIR unset, not pinned to the
#    personal directory: an explicit value selects a separate auth namespace.
out="$(STUB_KIND=personal run_wrapper personal)"
assert "personal leaves CLAUDE_CONFIG_DIR unset" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^CONFIG_SET=\$'"

# 2. personal carries the scoped-account marker the shell wrapper also sets
assert "personal exports WORKFLOW_PERSONAL_ACCOUNT" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^PERSONAL=1\$'"

# 3. work pins CLAUDE_CONFIG_DIR from the resolver
out="$(STUB_KIND=work run_wrapper work)"
assert "work pins CLAUDE_CONFIG_DIR from the resolver" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^CLAUDE_CONFIG_DIR=/tmp/fakehome/.claude-work\$'"

mismatch() {
    status=0
    STUB_KIND=personal run_wrapper work >/dev/null 2>&1 || status=$?
    [ "$status" = 3 ]
}

# 4. a work entry opened on a personal-routed directory refuses
assert "account/route mismatch exits 3" mismatch

# 5. an empty ANTHROPIC_API_KEY is unset before exec
out="$(ANTHROPIC_API_KEY="" STUB_KIND=personal run_wrapper personal)"
assert "empty ANTHROPIC_API_KEY is unset, not passed through empty" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^KEY_SET=\$'"

# 6. the adapter version is pinned in the exec args
out="$(STUB_KIND=personal run_wrapper personal)"
assert "exec args pin the adapter version" \
    sh -c "printf '%s\n' \"$out\" | grep -q -- '-y @agentclientprotocol/claude-agent-acp@0.79.0'"

# 7. extra args after the account pass through
out="$(STUB_KIND=personal run_wrapper personal --foo bar)"
assert "extra args after the account pass through" \
    sh -c "printf '%s\n' \"$out\" | grep -q -- '--foo bar\$'"

bad_account() {
    status=0
    HOME="$FAKEHOME" PATH="$WORK/bin:/usr/bin:/bin" \
        bash "$WORK/checkout/bin/zed-claude-agent" bogus >/dev/null 2>&1 || status=$?
    [ "$status" = 2 ]
}

# 8. a bad account exits 2
assert "bad account exits 2" bad_account

# 9. without a resolver, personal still launches unpinned
out="$(run_bare personal 2>/dev/null)"
assert "fallback personal leaves CLAUDE_CONFIG_DIR unset" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^CONFIG_SET=\$'"

# 10. without a resolver, work still reaches the work config dir
out="$(run_bare work 2>/dev/null)"
assert "fallback work pins the work config dir" \
    sh -c "printf '%s\n' \"$out\" | grep -q '^CLAUDE_CONFIG_DIR=/tmp/fakehome/.claude-work\$'"

# 11. invoked through a symlink, the wrapper still finds the checkout's
#     resolver and hands it this process's cwd plus the personal override
ARGV_FILE="$WORK/argv.txt"
HERE="$(pwd)"
STUB_KIND=personal STUB_ARGV_OUT="$ARGV_FILE" run_linked personal >/dev/null
assert "symlinked wrapper passes cwd to the resolver" \
    grep -q -- "--cwd $HERE" "$ARGV_FILE"

# 12. the personal entry asks the resolver for the personal override, which is
#     what lets a personal thread open inside a work repository
assert "personal entry passes --personal to the resolver" \
    grep -q -- "--personal" "$ARGV_FILE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
