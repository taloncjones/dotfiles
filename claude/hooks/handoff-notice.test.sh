#!/bin/sh
# handoff_notice.py: SessionStart notice of saved handoffs for the cwd repo.
# Hermetic: temp HOME, temp state dir, fixture git repo, no network.
set -u
cd "$(dirname "$0")/../.." || exit 1
PASS=0
FAIL=0
HOOK=claude/hooks/handoff_notice.py
HELPER=claude/skills/handoff/scripts/handoff.py
if command -v uv >/dev/null 2>&1; then
    PY="uv run --python >=3.11 --no-project --offline --no-cache python"
else
    PY=python3
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/handoff-notice.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export DOTFILES_HANDOFF_STATE_DIR="$TMP/state"
unset CLAUDE_CONFIG_DIR CLAUDE_PERSONAL_ONLY XDG_STATE_HOME
REPO="$HOME/Git/personal/fixture"
mkdir -p "$REPO"
git -C "$REPO" init -q -b trunk
git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -q --allow-empty -m fixture

run_hook() {
    printf '{"cwd":"%s","hook_event_name":"SessionStart"}' "$1" | $PY "$HOOK"
}

silent() {
    label=$1; out=$2; rc=$3
    if [ "$rc" = 0 ] && [ -z "$out" ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s): %s\n' "$label" "$rc" "$out" >&2; FAIL=$((FAIL + 1))
    fi
}

contains() {
    label=$1; out=$2; rc=$3; shift 3
    ok=1
    [ "$rc" = 0 ] || ok=0
    for needle in "$@"; do
        printf '%s' "$out" | grep -qF -- "$needle" || ok=0
    done
    if [ "$ok" = 1 ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s)\n%s\n' "$label" "$rc" "$out" >&2; FAIL=$((FAIL + 1))
    fi
}

# SessionStart output must be a JSON envelope; only additionalContext reaches
# the model's context. Bare stdout is never folded in.
envelope_ok() {
    label=$1; out=$2
    if printf '%s' "$out" | $PY -c 'import json,sys; h=json.load(sys.stdin)["hookSpecificOutput"]; sys.exit(0 if h["hookEventName"]=="SessionStart" and isinstance(h["additionalContext"],str) else 1)' 2>/dev/null; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n%s\n' "$label" "$out" >&2; FAIL=$((FAIL + 1))
    fi
}

context() {
    printf '%s' "$1" | $PY -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}

# 1. No records: silent, exit 0.
out=$(run_hook "$REPO"); rc=$?
silent "no records prints nothing" "$out" "$rc"

# 2. Two records: one line each plus the kickoff hint.
printf 'working: fix the flaky login test.\nNext: rerun it.\n' > "$TMP/brief-a.txt"
printf 'assigned: write the release notes.\n' > "$TMP/brief-b.txt"
$PY "$HELPER" save --repo "$REPO" --runtime claude --task fix-login \
    --brief-file "$TMP/brief-a.txt" --role lead >/dev/null
$PY "$HELPER" save --repo "$REPO" --runtime claude --task release-notes \
    --brief-file "$TMP/brief-b.txt" --role worker --parent fix-login >/dev/null
out=$(run_hook "$REPO"); rc=$?
envelope_ok "two records emit a SessionStart envelope" "$out"
ctx=$(context "$out")
contains "two records list task, role, summary, hint" "$ctx" "$rc" \
    "fix-login [lead]" "working: fix the flaky login test." \
    "release-notes [worker of fix-login]" "assigned: write the release notes." \
    "Run /kickoff <task> to resume one."

# 3. cwd outside any repository: silent, exit 0.
mkdir -p "$TMP/plain"
out=$(run_hook "$TMP/plain"); rc=$?
silent "non-repository cwd prints nothing" "$out" "$rc"

# 4. Hook copied beside no skills tree: missing helper exits 0 silently.
mkdir -p "$TMP/fixture/hooks"
cp "$HOOK" "$TMP/fixture/hooks/handoff_notice.py"
out=$(printf '{"cwd":"%s"}' "$REPO" | $PY "$TMP/fixture/hooks/handoff_notice.py"); rc=$?
silent "missing helper exits 0 silently" "$out" "$rc"

# 5. Malformed stdin: exit 0.
out=$(printf 'not json' | $PY "$HOOK"); rc=$?
[ "$rc" = 0 ] && { printf 'PASS  malformed payload exits 0\n'; PASS=$((PASS + 1)); } \
    || { printf 'FAIL  malformed payload exits 0 (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1)); }

# 6. Overflow: 12 ready records show the 10 newest and an omitted count.
i=1
while [ "$i" -le 10 ]; do
    printf 'assigned: filler %s.\n' "$i" > "$TMP/brief-f.txt"
    $PY "$HELPER" save --repo "$REPO" --runtime claude --task "filler-$i" \
        --brief-file "$TMP/brief-f.txt" >/dev/null
    i=$((i + 1))
done
out=$(run_hook "$REPO"); rc=$?
ctx=$(context "$out")
shown=$(printf '%s\n' "$ctx" | grep -c '^  [a-z0-9-]* \[')
if [ "$rc" = 0 ] && [ "$shown" = 10 ] \
    && printf '%s' "$ctx" | grep -qF 'and 2 more' \
    && printf '%s' "$ctx" | grep -qF 'filler-10 [no role]' \
    && ! printf '%s' "$ctx" | grep -qF 'fix-login ['; then
    printf 'PASS  overflow shows ten newest and omitted count\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  overflow shows ten newest and omitted count (rc=%s shown=%s)\n%s\n' "$rc" "$shown" "$out" >&2
    FAIL=$((FAIL + 1))
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
