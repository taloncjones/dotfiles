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

assert_eq() {
    label="$1"
    actual="$2"
    expected="$3"
    if [ "$actual" = "$expected" ]; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        printf '    expected: %s\n    actual:   %s\n' "$expected" "$actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

# Extracts the lines of one section (from its header up to the next blank
# line) so counts can be scoped to a single table instead of matching every
# "cache_cr:" row in the whole report.
section() {
    haystack="$1"
    header="$2"
    printf '%s\n' "$haystack" | awk -v h="$header" '
        $0 ~ h { found=1; next }
        found && NF == 0 { exit }
        found { print }
    '
}

# Extracts a "label:   VALUE" field's value from a line, independent of
# column-width padding, so numeric assertions do not depend on hardcoded
# whitespace counts.
field_value() {
    line="$1"
    label="$2"
    printf '%s\n' "$line" | grep -oE "${label}:[[:space:]]*[A-Za-z0-9,]+" | head -1 | sed -E "s/^${label}:[[:space:]]*//"
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
CODEX_TODAY_TS=$(python3 -c "from datetime import datetime; print(datetime.now().replace(hour=10, minute=0, second=0, microsecond=0).isoformat() + 'Z')")

mkdir -p "$WORK/claude_home/projects/proj1"
mkdir -p "$WORK/claude_home/projects/proj2"
mkdir -p "$WORK/codex_home/sessions/2026/09/17"
mkdir -p "$WORK/codex_home/archived_sessions"

# Claude project 1, session 1, two days of data
cat > "$WORK/claude_home/projects/proj1/session1.jsonl" <<EOF
{"type":"message","sessionId":"sess-1","requestId":"req-1","timestamp":"${YESTERDAY}T10:00:00Z","message":{"id":"msg-1","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":500}}}
{"type":"message","sessionId":"sess-1","requestId":"req-2","timestamp":"${YESTERDAY}T11:00:00Z","message":{"id":"msg-2","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":200,"output_tokens":100,"cache_creation_input_tokens":2000,"cache_read_input_tokens":1000}}}
{"type":"message","sessionId":"sess-1","requestId":"req-3","timestamp":"${TODAY}T10:00:00Z","message":{"id":"msg-3","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":150,"output_tokens":75,"cache_creation_input_tokens":1500,"cache_read_input_tokens":750}}}
EOF

# Claude project 1, session yesterday-only, used to prove --since 0d actually excludes it.
cat > "$WORK/claude_home/projects/proj1/session_old.jsonl" <<EOF
{"type":"message","sessionId":"sess-old","requestId":"req-old","timestamp":"${YESTERDAY}T09:00:00Z","message":{"id":"msg-old","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":50}}}
EOF

# Claude project 2, session 2, different model
cat > "$WORK/claude_home/projects/proj2/session2.jsonl" <<EOF
{"type":"message","sessionId":"sess-2","requestId":"req-4","timestamp":"${TODAY}T12:00:00Z","message":{"id":"msg-4","model":"claude-opus-5-5","usage":{"input_tokens":300,"output_tokens":200,"cache_creation_input_tokens":3000,"cache_read_input_tokens":1500}}}
{"type":"message","sessionId":"sess-2","requestId":"req-5","timestamp":"${TODAY}T13:00:00Z","message":{"id":"msg-5","model":"claude-opus-5-5","usage":{"input_tokens":400,"output_tokens":250,"cache_creation_input_tokens":4000,"cache_read_input_tokens":2000}}}
EOF

# Claude project 2, session with duplicated content-block lines: same
# message id/requestId repeated, as Claude Code writes one line per content
# block. The first line carries a provisional in-progress output_tokens
# count; the last line carries the true final count. Must keep the LAST
# line's value (341), not the first (3) and not the sum.
cat > "$WORK/claude_home/projects/proj2/session_dup.jsonl" <<EOF
{"type":"message","sessionId":"sess-dup","requestId":"req-dup","timestamp":"${TODAY}T14:00:00Z","message":{"id":"msg-dup","model":"claude-fable-5-1","usage":{"input_tokens":9,"output_tokens":3,"cache_creation_input_tokens":9,"cache_read_input_tokens":9}}}
{"type":"message","sessionId":"sess-dup","requestId":"req-dup","timestamp":"${TODAY}T14:00:00Z","message":{"id":"msg-dup","model":"claude-fable-5-1","usage":{"input_tokens":9,"output_tokens":341,"cache_creation_input_tokens":9,"cache_read_input_tokens":9}}}
EOF

# Malformed lines (should be skipped with a warning, not crash): plain
# garbage, a JSON null line, and a message:null line.
cat > "$WORK/claude_home/projects/proj1/broken.jsonl" <<EOF
this is not json
null
{"type":"message","sessionId":"sess-null-msg","timestamp":"${TODAY}T15:30:00Z","message":null}
{"type":"message","sessionId":"sess-3","requestId":"req-6","timestamp":"${TODAY}T15:00:00Z","message":{"id":"msg-6","model":"claude-fable-5-1","usage":{"input_tokens":500,"output_tokens":300,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2500}}}
{"type":"message","sessionId":"sess-bad-ts","requestId":"req-7","timestamp":"not-a-date","message":{"id":"msg-7","model":"claude-fable-5-1","usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1}}}
EOF
# Invalid UTF-8 byte in its own file: must warn as unreadable and continue.
printf '\xff\xfe not valid utf-8\n' > "$WORK/claude_home/projects/proj1/badutf8.jsonl"

# Codex session under sessions/ (real schema: ISO timestamp string, usage
# nested under payload.info.last_token_usage, no top-level session_id --
# the session id comes from the rollout filename). Real, redacted sample.
CODEX_KNOWN_FILE="$WORK/codex_home/sessions/2026/09/17/rollout-2026-09-17T10-00-00-01a0K-codex-known.jsonl"
cat > "$CODEX_KNOWN_FILE" <<EOF
{"timestamp":"${CODEX_TODAY_TS}","ordinal":0,"type":"session_meta","payload":{"session_id":"01a0K-codex-known","cwd":"/repo"}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":20,"output_tokens":300,"reasoning_output_tokens":50,"total_tokens":1300},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"cache_write_input_tokens":20,"output_tokens":300,"reasoning_output_tokens":50,"total_tokens":1300}}}}
EOF

# Codex session under archived_sessions/ with no cache_write_input_tokens
# field, proving the 'unknown' sentinel is used rather than a fabricated 0,
# plus the malformed-input cases specific to the Codex schema: a JSON array
# line and a token_count event with info:null.
CODEX_UNKNOWN_FILE="$WORK/codex_home/archived_sessions/rollout-2026-09-16T09-00-00-01a0U-codex-unknown.jsonl"
cat > "$CODEX_UNKNOWN_FILE" <<EOF
["not", "an", "object"]
{"timestamp":"${CODEX_TODAY_TS}","ordinal":0,"type":"session_meta","payload":{"session_id":"01a0U-codex-unknown","cwd":"/repo"}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":null}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":20,"total_tokens":80},"last_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":20,"total_tokens":80}}}}
EOF

# Codex session with cache_write_input_tokens present but exactly 0 -- the
# real-world shape (observed in 100% of sampled real events). Must land in
# the unranked unknown section like the field-absent case, not be treated as
# a measured zero.
mkdir -p "$WORK/codex_home/sessions/2026/09/18"
CODEX_ZEROWRITE_FILE="$WORK/codex_home/sessions/2026/09/18/rollout-2026-09-18T11-00-00-01a0Z-codex-zerowrite.jsonl"
cat > "$CODEX_ZEROWRITE_FILE" <<EOF
{"timestamp":"${CODEX_TODAY_TS}","ordinal":0,"type":"session_meta","payload":{"session_id":"01a0Z-codex-zerowrite","cwd":"/repo"}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":50,"cache_write_input_tokens":0,"output_tokens":75,"reasoning_output_tokens":10,"total_tokens":275},"last_token_usage":{"input_tokens":200,"cached_input_tokens":50,"cache_write_input_tokens":0,"output_tokens":75,"reasoning_output_tokens":10,"total_tokens":275}}}}
EOF

# Codex session with a re-emitted token_count event: a second event whose
# cumulative total_token_usage (and last_token_usage) exactly repeats the
# previous event's, as Codex does for a rate-limit-only update. Must be
# counted once (output 200), not twice (400).
mkdir -p "$WORK/codex_home/sessions/2026/09/19"
CODEX_REEMIT_FILE="$WORK/codex_home/sessions/2026/09/19/rollout-2026-09-19T08-00-00-01a0R-codex-reemit.jsonl"
cat > "$CODEX_REEMIT_FILE" <<EOF
{"timestamp":"${CODEX_TODAY_TS}","ordinal":0,"type":"session_meta","payload":{"session_id":"01a0R-codex-reemit","cwd":"/repo"}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"cache_write_input_tokens":20,"output_tokens":200,"reasoning_output_tokens":30,"total_tokens":700},"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,"cache_write_input_tokens":20,"output_tokens":200,"reasoning_output_tokens":30,"total_tokens":700}}}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":5,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":500,"cached_input_tokens":100,"cache_write_input_tokens":20,"output_tokens":200,"reasoning_output_tokens":30,"total_tokens":700},"last_token_usage":{"input_tokens":500,"cached_input_tokens":100,"cache_write_input_tokens":20,"output_tokens":200,"reasoning_output_tokens":30,"total_tokens":700}}}}
EOF

# Codex session with a legitimate rate-limit-only event: info:null alongside
# a populated rate_limits payload. Must be skipped silently (no "malformed
# line" warning), unlike a genuinely malformed info:null with no rate_limits.
mkdir -p "$WORK/codex_home/archived_sessions"
CODEX_RATELIMIT_FILE="$WORK/codex_home/archived_sessions/rollout-2026-09-15T07-00-00-01a0L-codex-ratelimit.jsonl"
cat > "$CODEX_RATELIMIT_FILE" <<EOF
{"timestamp":"${CODEX_TODAY_TS}","ordinal":0,"type":"session_meta","payload":{"session_id":"01a0L-codex-ratelimit","cwd":"/repo"}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":1,"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":50.0}}}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"cached_input_tokens":5,"cache_write_input_tokens":3,"output_tokens":15,"total_tokens":60},"last_token_usage":{"input_tokens":40,"cached_input_tokens":5,"cache_write_input_tokens":3,"output_tokens":15,"total_tokens":60}}}}
EOF

# Claude leaf-shape malformed values (still-open V-4-residual): a null or
# string token count, a null sessionId, and a non-string model each used to
# abort the whole run with an uncaught TypeError outside the per-line
# try/except. Each must now warn and be skipped instead. A shared, otherwise
# unused model name isolates the surviving rows' totals from every other
# fixture.
cat > "$WORK/claude_home/projects/proj1/leaf_malformed.jsonl" <<EOF
{"type":"message","sessionId":"sess-leaf-null-input","requestId":"req-leaf-a","timestamp":"${TODAY}T16:00:00Z","message":{"id":"msg-leaf-a","model":"claude-leaftest-1","usage":{"input_tokens":null,"output_tokens":10,"cache_creation_input_tokens":10,"cache_read_input_tokens":10}}}
{"type":"message","sessionId":"sess-leaf-string-input","requestId":"req-leaf-b","timestamp":"${TODAY}T16:05:00Z","message":{"id":"msg-leaf-b","model":"claude-leaftest-1","usage":{"input_tokens":"10","output_tokens":10,"cache_creation_input_tokens":10,"cache_read_input_tokens":10}}}
{"type":"message","sessionId":null,"requestId":"req-leaf-c","timestamp":"${TODAY}T16:10:00Z","message":{"id":"msg-leaf-c","model":"claude-leaftest-1","usage":{"input_tokens":5,"output_tokens":5,"cache_creation_input_tokens":5,"cache_read_input_tokens":5}}}
{"type":"message","sessionId":"sess-leaf-list-model","requestId":"req-leaf-d","timestamp":"${TODAY}T16:15:00Z","message":{"id":"msg-leaf-d","model":[],"usage":{"input_tokens":5,"output_tokens":5,"cache_creation_input_tokens":5,"cache_read_input_tokens":5}}}
{"type":"message","sessionId":"sess-leaf-ok","requestId":"req-leaf-ok","timestamp":"${TODAY}T16:20:00Z","message":{"id":"msg-leaf-ok","model":"claude-leaftest-1","usage":{"input_tokens":5,"output_tokens":5,"cache_creation_input_tokens":5,"cache_read_input_tokens":5}}}
EOF

# Codex leaf-shape malformed value: output_tokens as a string instead of a
# number.
mkdir -p "$WORK/codex_home/sessions/2026/09/20"
CODEX_LEAF_FILE="$WORK/codex_home/sessions/2026/09/20/rollout-2026-09-20T06-00-00-01a0X-codex-leaf.jsonl"
cat > "$CODEX_LEAF_FILE" <<EOF
{"timestamp":"${CODEX_TODAY_TS}","ordinal":0,"type":"session_meta","payload":{"session_id":"01a0X-codex-leaf","cwd":"/repo"}}
{"timestamp":"${CODEX_TODAY_TS}","ordinal":4,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":1,"output_tokens":"2","total_tokens":13},"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":1,"output_tokens":"2","total_tokens":13}}}}
EOF

set +e
output=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 7d 2>&1)
main_status=$?
set -e
assert_eq "main run exits 0 despite leaf-malformed input" "$main_status" "0"

# Check that models are present in output
assert_contains "haiku in grand total" "$output" "Grand Total by Model"
assert_contains "haiku model name" "$output" "claude-haiku-4-5-20251001"
assert_contains "opus model name" "$output" "claude-opus-5-5"
assert_contains "fable model name" "$output" "claude-fable-5-1"

# Check sessions are listed
assert_contains "sess-1 listed" "$output" "sess-1"
assert_contains "sess-2 listed" "$output" "sess-2"
assert_contains "sess-3 listed" "$output" "sess-3"

# Codex sessions from both sessions/ and archived_sessions/ must be scanned.
assert_contains "codex model present" "$output" "codex-unknown"
assert_contains "codex session id from sessions/ tree" "$output" "01a0K-co"
assert_contains "codex session id from archived_sessions/ tree" "$output" "01a0U-co"

# V-1: known codex cache_write_input_tokens must be reported as a real
# number, not the old fabricated 'unknown' sentinel.
known_section=$(section "$output" "Top Sessions by Priced Tokens")
assert_contains "codex known cache_write is numeric" "$known_section" "cache_cr:        20"

# V-3: a codex session with no cache_write_input_tokens field must appear in
# the unranked unknown section, never silently as a priced 0.
unknown_section=$(section "$output" "Unknown-Priced Sessions")
assert_contains "codex unknown cache_write in unknown section" "$unknown_section" "01a0U-co"
assert_not_contains "codex unknown session absent from ranked section" "$known_section" "01a0U-co"

# Finding 1 (review round 3): cache_write_input_tokens present but exactly 0
# is the real-world shape (observed in 100% of sampled real events) and must
# be treated as unknown, not as a measured 0 -- otherwise every real Codex
# session lands in the ranked table with a fabricated priced total.
assert_contains "codex present-but-zero cache_write in unknown section" "$unknown_section" "01a0Z-co"
assert_not_contains "codex present-but-zero session absent from ranked section" "$known_section" "01a0Z-co"

# V-4: both codex-schema malformed lines in the unknown-priced file (the
# JSON array line and the info:null token_count event) must each warn.
codex_file_malformed_count=$(printf '%s\n' "$output" | grep "malformed line" | grep -c "codex-unknown.jsonl" || true)
assert_eq "codex-unknown file has exactly 2 malformed-line warnings" "$codex_file_malformed_count" "2"

# V-2/R-1: the duplicated content-block lines must be counted once, keeping
# the LAST line's value (341, the true final count), not the first
# (provisional, 3) and not the sum of both.
dup_session_line=$(printf '%s\n' "$output" | grep "sess-dup" | head -1)
assert_eq "dup session output keeps last line, not first or sum" "$(field_value "$dup_session_line" "output")" "341"

# R-2: a Codex event that re-emits the previous event's cumulative total
# (a rate-limit-only update) must be counted once, not twice.
reemit_line=$(printf '%s\n' "$output" | grep "01a0R-co" | head -1)
assert_eq "codex re-emitted event counted once, not twice" "$(field_value "$reemit_line" "output")" "200"

# R-3: a legitimate rate-limit-only event (info:null with a populated
# rate_limits payload) must not be reported as a malformed line, unlike a
# genuinely malformed info:null.
assert_not_contains "no false-positive warning on rate-limit-only event" "$output" "codex-ratelimit.jsonl"
ratelimit_line=$(printf '%s\n' "$output" | grep "01a0L-co" | head -1)
assert_eq "codex rate-limit-only session still counts its real event" "$(field_value "$ratelimit_line" "output")" "15"

# V-4-residual: leaf-level malformed values (null/string token counts, a
# null sessionId, a non-string model) must warn and be skipped, never crash
# aggregation or rendering outside the per-line try/except. Only the one
# well-formed leaf_malformed.jsonl line should survive, under the shared
# isolating model name.
leaftest_section=$(section "$output" "Grand Total by Model")
leaftest_line=$(printf '%s\n' "$leaftest_section" | grep "claude-leaftest-1" | head -1)
assert_eq "leaf-malformed lines excluded, only the valid row counted" "$(field_value "$leaftest_line" "output")" "5"
leaf_malformed_count=$(printf '%s\n' "$output" | grep "malformed line" | grep -c "leaf_malformed.jsonl" || true)
assert_eq "leaf_malformed.jsonl has exactly 4 malformed-line warnings" "$leaf_malformed_count" "4"
assert_contains "stderr warning on codex leaf-malformed output_tokens" "$output" "codex-leaf.jsonl"

# V-4: malformed input (JSON null, message:null, invalid UTF-8, a Codex JSON
# array line, Codex info:null) must warn and continue, never raise.
assert_not_contains "no crash on malformed" "$output" "Traceback"
assert_contains "stderr warning on malformed line" "$output" "token-burn: warning: malformed line"
assert_contains "stderr warning names the broken file" "$output" "broken.jsonl"
assert_contains "stderr warning on invalid utf-8" "$output" "badutf8.jsonl"
assert_contains "stderr warning on codex array line" "$output" "codex-unknown.jsonl"

# V-6: an unparseable timestamp must emit its own one-line diagnostic.
assert_contains "stderr warning on unparseable timestamp" "$output" "token-burn: warning: unparseable timestamp"
assert_not_contains "unparseable timestamp session excluded from report" "$output" "sess-bad-ts"

# Per-day grouping (Goal 1) must surface in the output
assert_contains "grand total by day header" "$output" "Grand Total by Day:"
assert_contains "per-day totals include today" "$output" "$TODAY"
assert_contains "per-day totals include yesterday" "$output" "$YESTERDAY"

# Top sessions should list the big ones
assert_contains "top sessions header" "$output" "Top Sessions by Priced Tokens"
assert_contains "top sessions by cache read" "$output" "Top Sessions by Cache Read Volume"

# Unreadable file must emit a stderr diagnostic and keep going (PRD requirement 6)
chmod 000 "$WORK/claude_home/projects/proj2/session2.jsonl"
output_unreadable=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 7d 2>&1)
chmod 644 "$WORK/claude_home/projects/proj2/session2.jsonl"
assert_contains "stderr warning on unreadable file" "$output_unreadable" "token-burn: warning: unreadable file"
assert_contains "unreadable file warning names the file" "$output_unreadable" "session2.jsonl"
assert_not_contains "unreadable file does not crash" "$output_unreadable" "Traceback"

# V-7: a FIFO in a scanned tree must be skipped with a warning, never opened
# (which would block the whole run indefinitely).
if command -v mkfifo >/dev/null 2>&1; then
    mkfifo "$WORK/claude_home/projects/proj1/a_fifo.jsonl"
    output_fifo=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
        timeout 10 "$REPO/bin/token-burn" --since 7d 2>&1)
    fifo_status=$?
    assert_eq "fifo run does not time out" "$fifo_status" "0"
    assert_contains "stderr warning on non-regular file" "$output_fifo" "token-burn: warning: skipping non-regular file"
    assert_contains "fifo warning names the file" "$output_fifo" "a_fifo.jsonl"
    rm -f "$WORK/claude_home/projects/proj1/a_fifo.jsonl"
else
    printf 'SKIP  fifo test (mkfifo unavailable)\n'
fi

# Test --since 0d filter: cutoff to just today's data. sess-old only has a
# yesterday line, so it must be excluded entirely from today-only output.
output_filtered=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 0d 2>&1)
assert_contains "--since 0d includes today's model" "$output_filtered" "claude-haiku-4-5-20251001"
assert_not_contains "--since 0d excludes yesterday-only session" "$output_filtered" "sess-old"

# Test --model filter
output_model=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 7d --model opus 2>&1)
assert_contains "--model filter includes opus" "$output_model" "claude-opus-5-5"
assert_not_contains "--model filter excludes haiku" "$output_model" "claude-haiku-4-5-20251001"

# Test --session-limit: with a limit of 1, the ranked (known-priced) table
# must carry exactly one session row, scoped to that section only so it is
# not conflated with the unranked unknown-priced section or the cache-read
# table.
output_limit=$(env CLAUDE_CONFIG_DIR="$WORK/claude_home" CODEX_HOME="$WORK/codex_home" \
    "$REPO/bin/token-burn" --since 7d --session-limit 1 2>&1)
ranked_section=$(section "$output_limit" "Top Sessions by Priced Tokens")
ranked_count=$(printf '%s\n' "$ranked_section" | grep -c "cache_cr:" || true)
assert_eq "--session-limit restricts ranked table to exact count" "$ranked_count" "1"

# The unknown-priced session must still appear even under --session-limit 1;
# it is unranked and therefore never truncated.
unknown_section_limit=$(section "$output_limit" "Unknown-Priced Sessions")
assert_contains "--session-limit does not drop unknown-priced session" "$unknown_section_limit" "01a0U-co"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
