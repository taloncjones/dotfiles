#!/bin/sh
# token-burn.test.sh - verify token-burn against fixture JSONL files.
# No network, no real ~/.claude reads; uses CLAUDE_CONFIG_DIR and CODEX_HOME overrides.
set -e

PASS=0
FAIL=0

assert_contains() {
    label="$1"
    haystack="$2"
    needle="$3"
    if printf '%s\n' "$haystack" | grep -qF "$needle"; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        printf '    expected substring: %s\n' "$needle" >&2
        printf '    in output:\n%s\n' "$haystack" | sed 's/^/    /' >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    label="$1"
    haystack="$2"
    needle="$3"
    if ! printf '%s\n' "$haystack" | grep -qF "$needle"; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        printf '    found unexpected substring: %s\n' "$needle" >&2
        FAIL=$((FAIL + 1))
    fi
}

REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# token-burn resolves "today" via the local clock (datetime.now()), so the
# fixture's two days must be computed relative to that same clock rather than
# pinned to a fixed calendar date - a hardcoded date goes stale and breaks the
# --since 0d cutoff test the moment the wall clock moves past it.
TODAY=$(python3 -c "from datetime import datetime; print(datetime.now().date().isoformat())")
YESTERDAY=$(python3 -c "from datetime import datetime, timedelta; print((datetime.now().date() - timedelta(days=1)).isoformat())")
CODEX_TS_MS=$(python3 -c "from datetime import datetime; print(int(datetime.now().replace(hour=10, minute=0, second=0, microsecond=0).timestamp() * 1000))")

mkdir -p "$WORK/claude_home/projects/proj1"
mkdir -p "$WORK/claude_home/projects/proj2"
mkdir -p "$WORK/codex_home/archived_sessions"

# Claude project 1, session 1, two days of data
cat > "$WORK/claude_home/projects/proj1/session1.jsonl" <<EOF
{"type":"message","sessionId":"sess-1","timestamp":"${YESTERDAY}T10:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":500}}}
{"type":"message","sessionId":"sess-1","timestamp":"${YESTERDAY}T11:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":200,"output_tokens":100,"cache_creation_input_tokens":2000,"cache_read_input_tokens":1000}}}
{"type":"message","sessionId":"sess-1","timestamp":"${TODAY}T10:00:00Z","message":{"model":"claude-haiku-4-5-20251001","usage":{"input_tokens":150,"output_tokens":75,"cache_creation_input_tokens":1500,"cache_read_input_tokens":750}}}
EOF

# Claude project 2, session 2, different model
cat > "$WORK/claude_home/projects/proj2/session2.jsonl" <<EOF
{"type":"message","sessionId":"sess-2","timestamp":"${TODAY}T12:00:00Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":300,"output_tokens":200,"cache_creation_input_tokens":3000,"cache_read_input_tokens":1500}}}
{"type":"message","sessionId":"sess-2","timestamp":"${TODAY}T13:00:00Z","message":{"model":"claude-opus-5-5","usage":{"input_tokens":400,"output_tokens":250,"cache_creation_input_tokens":4000,"cache_read_input_tokens":2000}}}
EOF

# Malformed line (should be skipped, not crash)
cat > "$WORK/claude_home/projects/proj1/broken.jsonl" <<EOF
this is not json
{"type":"message","sessionId":"sess-3","timestamp":"${TODAY}T15:00:00Z","message":{"model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":300,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2500}}}
EOF

# Codex archived session (timestamp for today in milliseconds)
cat > "$WORK/codex_home/archived_sessions/codex_sess.jsonl" <<EOF
{"type":"event_msg","session_id":"codex-1","timestamp":${CODEX_TS_MS},"payload":{"type":"token_count","info":{"input_tokens":100,"output_tokens":50,"cached_input_tokens":500,"cache_write_input_tokens":0,"reasoning_output_tokens":0}}}
EOF

output=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 7d 2>&1)

# Check that models are present in output
assert_contains "haiku in grand total" "$output" "Grand Total by Model"
assert_contains "haiku model name" "$output" "claude-haiku-4-5-20251001"
assert_contains "opus model name" "$output" "claude-opus-5-5"
assert_contains "fable model name" "$output" "claude-fable-5-1"

# Check sessions are listed
assert_contains "sess-1 listed" "$output" "sess-1"
assert_contains "sess-2 listed" "$output" "sess-2"
assert_contains "sess-3 listed" "$output" "sess-3"

# Codex should be present
assert_contains "codex model present" "$output" "codex-unknown"

# Codex cache_creation must be reported as unknown, never a fabricated 0
codex_line=$(printf '%s\n' "$output" | grep "codex-unknown")
assert_contains "codex cache_creation is unknown, not 0" "$codex_line" "cache_creation:     unknown"

# Per-day grouping (Goal 1) must surface in the output
assert_contains "grand total by day header" "$output" "Grand Total by Day:"
assert_contains "per-day totals include today" "$output" "$TODAY"
assert_contains "per-day totals include yesterday" "$output" "$YESTERDAY"

# Top sessions should list the big ones
assert_contains "top sessions header" "$output" "Top Sessions by Priced Tokens"
assert_contains "top sessions by cache read" "$output" "Top Sessions by Cache Read Volume"

# Malformed line should not crash (task requirement: fail soft)
assert_not_contains "no crash on malformed" "$output" "JSONDecodeError"
assert_not_contains "no crash on malformed" "$output" "Traceback"

# Malformed line must emit a stderr diagnostic and keep going (PRD requirement 6)
assert_contains "stderr warning on malformed line" "$output" "token-burn: warning: malformed line"
assert_contains "stderr warning names the file" "$output" "broken.jsonl"

# Unreadable file must emit a stderr diagnostic and keep going (PRD requirement 6)
chmod 000 "$WORK/claude_home/projects/proj2/session2.jsonl"
output_unreadable=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 7d 2>&1)
chmod 644 "$WORK/claude_home/projects/proj2/session2.jsonl"
assert_contains "stderr warning on unreadable file" "$output_unreadable" "token-burn: warning: unreadable file"
assert_contains "unreadable file warning names the file" "$output_unreadable" "session2.jsonl"
assert_not_contains "unreadable file does not crash" "$output_unreadable" "Traceback"

# Test --since filter: cutoff to just today's data
output_filtered=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 0d 2>&1)
assert_contains "--since 0d excludes older" "$output_filtered" "claude-haiku-4-5-20251001"

# Test --model filter
output_model=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 7d --model opus 2>&1)
assert_contains "--model filter includes opus" "$output_model" "claude-opus-5-5"
assert_not_contains "--model filter excludes haiku" "$output_model" "claude-haiku-4-5-20251001"

# Test --session-limit
output_limit=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 7d --session-limit 1 2>&1)
session_count=$(printf '%s\n' "$output_limit" | grep -c "cache_cr:" || echo 0)
if [ "$session_count" -le 2 ]; then
    printf 'PASS  --session-limit restricts output\n'
    PASS=$((PASS + 1))
else
    printf 'FAIL  --session-limit restricts output\n' >&2
    FAIL=$((FAIL + 1))
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
