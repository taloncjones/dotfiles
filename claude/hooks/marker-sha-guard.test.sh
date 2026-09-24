#!/bin/sh
# marker-sha-guard.test.sh -- hermetic payload tests for marker_sha_guard.py.
#
# Every fixture lives under one mktemp root; the hook runs with a throwaway
# HOME and an isolated git config, so nothing touches a real checkout. Every
# fixture git call goes through g(), which names its repository under $FIX.
set -u

PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HOOK=${MARKER_SHA_GUARD_HOOK:-claude/hooks/marker_sha_guard.py}
PASS=0
FAIL=0

FIX=$(mktemp -d /tmp/marker-sha-guard.XXXXXX)
[ -n "$FIX" ] && [ -d "$FIX" ] || { printf 'FAIL  cannot create the fixture root\n' >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

g() {
    case "$1" in
        -C) case "$2" in "$FIX"/*) ;; *) printf 'FAIL  fixture git outside FIX: %s\n' "$2" >&2; exit 1 ;; esac ;;
        init|clone) ;;
        *) printf 'FAIL  fixture git must use -C, init, or clone: %s\n' "$*" >&2; exit 1 ;;
    esac
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"
}
# mk DIR URL: a repository with two empty commits whose ids are unique to DIR.
mk() {
    g init -q "$1" && g -C "$1" remote add origin "$2" &&
        g -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "a $1" &&
        g -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "b $1"
}

R="$FIX/repo"
R2="$FIX/repo2"
mk "$R" https://example.invalid/owner/repo.git || exit 1
mk "$R2" https://example.invalid/owner/two.git || exit 1
H=$(g -C "$R" rev-parse HEAD)
B=$(g -C "$R" rev-parse HEAD~1)
TREE=$(g -C "$R" rev-parse 'HEAD^{tree}')
g -C "$R" -c user.name=t -c user.email=t@example.invalid tag -a -m t v1 HEAD || exit 1
TAG=$(g -C "$R" rev-parse v1)
H2=$(g -C "$R2" rev-parse HEAD)
B2=$(g -C "$R2" rev-parse HEAD~1)
FAKE=0123456789abcdef0123456789abcdef01234567
SHORT=$(printf %s "$H" | cut -c1-7)
UPPER=$(printf %s "$H" | tr a-f A-F)
mkdir -p "$FIX/plain" "$FIX/run" "$FIX/ok" "$FIX/home"

rnd() { printf '<!-- co-review: sha=%s base=%s base_ref=main verdict=APPROVE round=1 -->' "$1" "$2"; }
GOOD=$(rnd "$H" "$B")
BAD=$(rnd "$FAKE" "$B")
BAD7=$(rnd "$SHORT" "$B")

# payload KIND CWD COMMAND: a Claude (bash) or Codex-shaped hook payload.
payload() {
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
kind, cwd, cmd = sys.argv[1:4]
shapes = {
    "bash": {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd},
    "exec": {"tool_name": "exec_command", "tool_input": {"cmd": cmd}, "cwd": cwd},
    "nested": {"toolName": "unified_exec", "toolInput": {"args": {"command": cmd}}, "cwd": cwd},
    "shell": {"tool_name": "shell", "tool_input": {"command": cmd}, "cwd": cwd},
    "workdir": {"tool_name": "shell_command", "tool_input": {"command": cmd, "workdir": cwd}, "cwd": "/"},
}
print(json.dumps(shapes[kind]))
PY
}
# run KIND CWD COMMAND [ENV...]: pipe the payload to the hook; rc in $RC.
run() {
    kind=$1; cwd=$2; cmd=$3; shift 3
    payload "$kind" "$cwd" "$cmd" | env -u GH_REPO -u HERDR_ENV -u RUN_DIR -u CDPATH HOME="$FIX/home" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$@" "$HOOK" \
        >"$FIX/out" 2>"$FIX/err"
    RC=$?
}
ok() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
no() { printf 'FAIL  %s (rc=%s)\n' "$1" "$RC" >&2; sed 's/^/      /' "$FIX/err" >&2; FAIL=$((FAIL + 1)); }
# deny NAME CWD COMMAND [KIND]: exit 2 with a Blocked: line.
deny() {
    run "${4:-bash}" "$2" "$3"
    if [ "$RC" -eq 2 ] && grep -q '^Blocked: ' "$FIX/err"; then ok "$1"; else no "$1"; fi
}
# allow NAME CWD COMMAND [KIND]: exit 0, silent.
allow() {
    run "${4:-bash}" "$2" "$3"
    if [ "$RC" -eq 0 ] && [ ! -s "$FIX/out" ] && [ ! -s "$FIX/err" ]; then ok "$1"; else no "$1"; fi
}

# --- R5: SHA format and object checks ---
allow "valid round marker" "$R" "gh pr comment 5 --body '$GOOD'"
deny "fabricated full sha" "$R" "gh pr comment 5 --body '$BAD'"
if grep -q "$FAKE" "$FIX/err"; then ok "denial names the fabricated sha"; else no "denial names the fabricated sha"; fi
if sed -n 2p "$FIX/err" | grep -q 'git rev-parse'; then ok "second line states the rule"; else no "second line states the rule"; fi
deny "short sha" "$R" "gh pr comment 5 --body '$BAD7'"
deny "uppercase sha" "$R" "gh pr comment 5 --body '$(rnd "$UPPER" "$B")'"
deny "tree id" "$R" "gh pr comment 5 --body '$(rnd "$TREE" "$B")'"
# The empty tree is built in and ignores replace refs, so use a blob.
BLOB=$(printf 'blob\n' | g -C "$R" hash-object -w --stdin)
g -C "$R" replace -f "$BLOB" "$H"
deny "replace ref does not make a blob a commit" "$R" "gh pr comment 5 --body '$(rnd "$BLOB" "$B")'"
g -C "$R" replace -d "$BLOB" >/dev/null
deny "annotated tag object id" "$R" "gh pr comment 5 --body '$(rnd "$TAG" "$B")'"
deny "fabricated base" "$R" "gh pr comment 5 --body '$(rnd "$H" "$FAKE")'"
deny "missing base" "$R" "gh pr comment 5 --body '<!-- co-review: sha=$H base_ref=main verdict=APPROVE round=1 -->'"
allow "valid target_tip" "$R" "gh pr comment 5 --body '<!-- co-review: sha=$H base=$B base_ref=main verdict=APPROVE round=1 target_tip=$B -->'"
deny "fabricated target_tip" "$R" "gh pr comment 5 --body '<!-- co-review: sha=$H base=$B base_ref=main verdict=APPROVE round=1 target_tip=$FAKE -->'"
deny "valid plus bad marker in one body" "$R" "$(printf "gh pr comment 5 --body '%s\n%s'" "$GOOD" "$BAD")"

# --- R4: families ---
CW="base_ref=main base_ref_tip=$B verdict=APPROVE round=1"
allow "valid coworker marker" "$R" "gh pr comment 5 --body '<!-- co-review-coworker: sha=$H base=$B $CW -->'"
deny "coworker short base" "$R" "gh pr comment 5 --body '<!-- co-review-coworker: sha=$H base=$SHORT $CW -->'"
deny "coworker fabricated base_ref_tip" "$R" "gh pr comment 5 --body '<!-- co-review-coworker: sha=$H base=$B base_ref=main base_ref_tip=$FAKE verdict=APPROVE round=1 -->'"
deny "coworker missing base_ref_tip" "$R" "gh pr comment 5 --body '<!-- co-review-coworker: sha=$H base=$B base_ref=main verdict=APPROVE round=1 -->'"
allow "valid audit marker" "$R" "gh pr comment 5 --body '<!-- co-review-audit head=$H run=r1 -->'"
deny "audit fabricated head" "$R" "gh pr comment 5 --body '<!-- co-review-audit head=$FAKE run=r1 -->'"
deny "audit short head" "$R" "gh pr comment 5 --body '<!-- co-review-audit head=$SHORT run=r1 -->'"
deny "audit cut after the head sha" "$R" "gh pr comment 5 --body '<!-- co-review-audit head=$H'"
deny "audit cut before the close" "$R" "gh pr comment 5 --body '<!-- co-review-audit head=$H run=r1'"
allow "cut inside the family prefix is plain text" "$R" "gh pr comment 5 --body '<!-- co-review-aud'"
deny "cut right after the family prefix" "$R" "gh pr comment 5 --body '<!-- co-review-audit'"
deny "audit missing head" "$R" "gh pr comment 5 --body '<!-- co-review-audit run=r1 -->'"

# --- R4: recognition matches pr_ready_gate.py ---
allow "backtick-fenced marker ignored" "$R" "$(printf "gh pr comment 5 --body '\`\`\`\n%s\n\`\`\`'" "$BAD")"
allow "tilde-fenced marker ignored" "$R" "$(printf "gh pr comment 5 --body '~~~\n%s\n~~~'" "$BAD")"
allow "space-indented marker ignored" "$R" "gh pr comment 5 --body ' $BAD'"
allow "tab-indented marker ignored" "$R" "$(printf "gh pr comment 5 --body '\t%s'" "$BAD")"
allow "blockquoted marker ignored" "$R" "gh pr comment 5 --body '> $BAD'"
allow "mid-line marker ignored" "$R" "gh pr comment 5 --body 'see $BAD inline'"

# --- R2: inspected verbs ---
for verb in "pr comment 5" "pr create --title t" "pr edit 5" "pr review 5" \
    "issue comment 5" "issue create --title t" "issue edit 5"; do
    deny "gh $verb inspected" "$R" "gh $verb --body '$BAD7'"
done
deny "-R before the subcommand" "$R" "gh -R owner/repo pr comment 5 --body '$BAD7'"
deny "--repo= before the subcommand" "$R" "gh --repo=owner/repo issue comment 5 --body '$BAD7'"
deny "-R before the subcommand names another repo" "$R" "gh -R other/repo pr comment 5 --body '$GOOD'"
deny "attached -R names another repo" "$R" "gh -Rother/repo pr comment 5 --body '$GOOD'"
allow "attached -R names this repo" "$R" "gh -Rowner/repo pr comment 5 --body '$GOOD'"
deny "attached -b" "$R" "gh pr comment 5 -b'$BAD7'"
allow "valid attached -b" "$R" "gh pr comment 5 -b'$GOOD'"
printf '%s\n' "$BAD" >"$FIX/attached-bad.md"
printf '%s\n' "$GOOD" >"$FIX/attached-good.md"
deny "attached -F" "$R" "gh pr comment 5 -F$FIX/attached-bad.md"
allow "valid attached -F" "$R" "gh pr comment 5 -F$FIX/attached-good.md"
deny "segment after && inspected" "$R" "git status && gh pr comment 5 --body '$BAD7'"
for shell in bash sh zsh; do
    allow "valid marker inside $shell -c" "$R" "$shell -c \"gh pr comment 5 --body '$GOOD'\""
done
deny "comment with heredoc-like text" "$R" "$(printf "# example <<EOF\ngh pr comment 5 --body '%s'" "$BAD7")"
deny "comment with an apostrophe" "$R" "$(printf "# don't skip this\ngh pr comment 5 --body '%s'" "$BAD7")"
allow "comment before a valid post" "$R" "$(printf "# post the audit\ngh pr comment 5 --body '%s'" "$GOOD")"
deny "unterminated quote with a marker hint" "$R" "gh pr comment 5 --body '$BAD7"
mkdir -p "$FIX/wrap-bad" "$FIX/wrap-ok"
printf '%s\n' "$BAD7" >"$FIX/wrap-bad/body.md"
printf '%s\n' "$GOOD" >"$FIX/wrap-ok/body.md"
deny "single-quoted sh -c expands its own variables" "$R" "export RUN_DIR=$FIX/wrap-bad; sh -c 'gh pr comment 5 --body-file \"\$RUN_DIR/body.md\"'"
allow "single-quoted sh -c reads the expanded valid path" "$R" "export RUN_DIR=$FIX/wrap-ok; sh -c 'gh pr comment 5 --body-file \"\$RUN_DIR/body.md\"'"
for shell in bash sh zsh; do
    deny "exported GH_REPO reaches $shell -c" "$R" "export GH_REPO=other/repo; $shell -c \"gh pr comment 5 --body '$GOOD'\""
    allow "matching GH_REPO reaches $shell -c" "$R" "export GH_REPO=owner/repo; $shell -c \"gh pr comment 5 --body '$GOOD'\""
    deny "wrapper GH_REPO reaches $shell -c" "$R" "GH_REPO=other/repo $shell -c \"gh pr comment 5 --body '$GOOD'\""
    deny "ambiguous GH_REPO reaches $shell -c" "$R" "true || export GH_REPO=owner/repo; $shell -c \"gh pr comment 5 --body '$GOOD'\""
done
deny "quoted heredoc operator is text" "$R" "$(printf ": '<<EOF'\ngh pr comment 5 --body '%s'" "$BAD7")"
deny "bash -c recursed" "$R" "bash -c \"gh pr comment 5 --body '$BAD7'\""
allow "gh pr view not inspected" "$R" "gh pr view 5 '$BAD7'"
allow "echo not inspected" "$R" "echo '$BAD7'"

# --- R3: body sources ---
printf '%s\n' "$BAD" >"$FIX/bad.md"
printf '%s\n' "$BAD" >"$R/rel.md"
printf '%s\n' "$GOOD" >"$R/good.md"
deny "--body= form" "$R" "gh pr comment 5 --body='$BAD'"
deny "-b form" "$R" "gh pr comment 5 -b '$BAD'"
deny "--body-file literal" "$R" "gh pr comment 5 --body-file $FIX/bad.md"
deny "attached redirection after --body-file" "$R" "gh pr comment 5 --body-file $FIX/bad.md>/dev/null"
allow "valid body file with an attached /dev/null redirection" "$R" "gh pr comment 5 --body-file $R/good.md>/dev/null"
deny "-F literal" "$R" "gh pr comment 5 -F $FIX/bad.md"
deny "--body-file= form" "$R" "gh pr comment 5 --body-file=$FIX/bad.md"
deny "relative body file after cd" "$FIX" "cd $R && gh pr comment 5 --body-file rel.md"
allow "valid relative body file after cd" "$FIX" "cd $R && gh pr comment 5 --body-file good.md"
deny "heredoc on stdin" "$R" "$(printf "gh pr comment 5 --body-file - <<'EOF'\n%s\nEOF" "$BAD")"
allow "valid heredoc on stdin" "$R" "$(printf "gh pr comment 5 --body-file - <<'EOF'\n%s\nEOF" "$GOOD")"
allow "valid cat heredoc inside --body" "$R" "$(printf "gh pr comment 5 --body \"\$(cat <<'EOF'\n%s\nEOF\n)\"" "$GOOD")"
deny "extra command inside the --body substitution" "$R" "$(printf "gh pr comment 5 --body \"\$(true; cat <<'EOF'\n%s\nEOF\n)\"" "$GOOD")"
deny "unquoted heredoc runs a substitution" "$R" "$(printf "gh pr comment 5 --body-file - <<EOF\n\$(true)\n%s\nEOF" "$GOOD")"
allow "unquoted heredoc without a substitution" "$R" "$(printf "gh pr comment 5 --body-file - <<EOF\n%s\nEOF" "$GOOD")"
cp "$R/good.md" "$FIX/self.md"
deny "gh output redirected onto its body file" "$R" "gh pr comment 5 --body-file $FIX/self.md >$FIX/self.md"
allow "gh with 2>&1 and /dev/null" "$R" "gh pr comment 5 --body '$GOOD' >/dev/null 2>&1"
deny "cat heredoc inside --body" "$R" "$(printf "gh pr comment 5 --body \"\$(cat <<'EOF'\n%s\nEOF\n)\"" "$BAD")"
deny "fabricated sha reaches --body through a variable" "$R" "BODY='$BAD'; gh pr comment 5 --body \"\$BODY\""
allow "assigned variable with a valid marker reaches --body" "$R" "BODY='$GOOD'; gh pr comment 5 --body \"\$BODY\""
deny "command substitution reaches --body" "$R" "gh pr comment 5 --body \"\$(printf '%s' '$BAD')\""
deny "unset variable in --body is unreadable" "$R" "gh pr comment 5 --body \"\$UNSET_MARKER_VAR co-review-audit head=$SHORT\""

# --- R6: directory tracking ---
printf '%s\n' "$BAD" >"$R/c.md"
printf '%s\n' "$(rnd "$H2" "$B2")" >"$R2/c.md"
deny "subshell cd is undone" "$R" "(cd $R2); gh pr comment 5 --body-file c.md"
deny "skipped && cd" "$R" "false && cd $R2; gh pr comment 5 --body-file c.md"
deny "skipped || cd" "$R" "true || cd $R2; gh pr comment 5 --body-file c.md"
deny "cd in a pipeline" "$R" "cd $R2 | cat; gh pr comment 5 --body-file c.md"
deny "backgrounded cd" "$R" "cd $R2 & gh pr comment 5 --body-file c.md"
deny "cd to a missing directory" "$R" "cd $FIX/missing; gh pr comment 5 --body-file c.md"
deny "non-literal cd" "$FIX" "cd \"\$D\" && gh pr comment 5 --body '$GOOD'"
if grep -q 'which directory' "$FIX/err"; then ok "unknown directory is named"; else no "unknown directory is named"; fi
mkdir -p "$FIX/alt/repo2"
printf '%s\n' "$BAD" >"$FIX/alt/repo2/c.md"
run bash "$FIX" "cd repo2 && gh pr comment 5 --body-file c.md" CDPATH="$FIX/alt"
if [ "$RC" -eq 2 ]; then ok "CDPATH makes a relative cd unknown"; else no "CDPATH makes a relative cd unknown"; fi
deny "assigned CDPATH makes a relative cd unknown" "$FIX" "CDPATH=$FIX/alt; cd repo2 && gh pr comment 5 --body-file c.md"
allow "relative cd without CDPATH" "$FIX" "cd repo2 && gh pr comment 5 --body-file c.md"
allow "cd && chain" "$FIX" "cd $R2 && gh pr comment 5 --body-file c.md"
allow "cd inside the subshell" "$FIX" "(cd $R && gh pr comment 5 --body-file good.md)"
allow "cd || exit" "$FIX" "cd $R || exit 1; gh pr comment 5 --body-file good.md"
allow "cd later in an && chain" "$FIX" "true && cd $R && gh pr comment 5 --body-file good.md"
deny "quoted operator is not a separator" "$R" "true ';' cd $R2; gh pr comment 5 --body-file c.md"
deny "escaped operator is not a separator" "$R" "true \\; cd $R2; gh pr comment 5 --body-file c.md"

# --- R6: repository resolution ---
deny "non-repo directory" "$FIX/plain" "gh pr comment 5 --body '$GOOD'"
if grep -q 'not in a git repository' "$FIX/err"; then ok "non-repo reason named"; else no "non-repo reason named"; fi
deny "commit of another repo" "$R" "gh pr comment 5 --body '$(rnd "$H2" "$B2")'"
allow "commit of the cwd repo" "$R2" "gh pr comment 5 --body '$(rnd "$H2" "$B2")'"
deny "-R names another repo" "$R" "gh pr comment 5 -R other/repo --body '$GOOD'"
allow "-R names this repo" "$R" "gh pr comment 5 -R owner/repo --body '$GOOD'"
allow "--repo= with host and case" "$R" "gh pr comment 5 --repo=github.com/OWNER/REPO --body '$GOOD'"
deny "PR URL of another repo" "$R" "gh pr comment https://github.com/other/repo/pull/5 --body '$GOOD'"
allow "PR URL of this repo" "$R" "gh pr comment https://github.com/owner/repo/pull/5 --body '$GOOD'"
deny "segment GH_REPO" "$R" "GH_REPO=other/repo gh pr comment 5 --body '$GOOD'"
run bash "$R" "gh pr comment 5 --body '$GOOD'" GH_REPO=other/repo
if [ "$RC" -eq 2 ]; then ok "environment GH_REPO"; else no "environment GH_REPO"; fi
deny "exported GH_REPO" "$R" "export GH_REPO=other/repo; gh pr comment 5 --body '$GOOD'"
allow "exported matching GH_REPO" "$R" "export GH_REPO=owner/repo; gh pr comment 5 --body '$GOOD'"
deny "conditional GH_REPO" "$R" "false && export GH_REPO=owner/repo; gh pr comment 5 --body '$GOOD'"
run bash "$R" "unset GH_REPO; gh pr comment 5 --body '$GOOD'" GH_REPO=other/repo
if [ "$RC" -eq 0 ]; then ok "unset GH_REPO"; else no "unset GH_REPO"; fi

# --- R7: unverifiable sources ---
printf '%s\n' "<!-- co-review-audit head=$FAKE run=r -->" >"$FIX/run/audit-comment.md"
printf '%s\n' "<!-- co-review-audit head=$H run=r -->" >"$FIX/ok/audit-comment.md"
allow "mktemp body file without a hint" "$R" "gh pr comment 5 --body-file \"\$(mktemp)\""
allow "missing file without a hint" "$R" "gh pr comment 5 --body-file $FIX/missing.md"
deny "unresolvable audit body file" "$R" "t=\$(mktemp); gh pr comment 5 --body-file \"\$t/audit-comment.md\""
deny "RUN_DIR assignment is read" "$R" "RUN_DIR=$FIX/run; gh pr comment 5 --body-file \"\$RUN_DIR/audit-comment.md\""
if grep -q "$FAKE" "$FIX/err"; then ok "assigned body file content was read"; else no "assigned body file content was read"; fi
allow "valid RUN_DIR body" "$R" "RUN_DIR=$FIX/ok; gh pr comment 5 --body-file \"\$RUN_DIR/audit-comment.md\""
deny "skipped assignment is ambiguous" "$R" "RUN_DIR=$FIX/run; false && RUN_DIR=$FIX/ok; gh pr comment 5 --body-file \"\$RUN_DIR/audit-comment.md\""
deny "subshell assignment is undone" "$R" "(RUN_DIR=$FIX/ok); gh pr comment 5 --body-file \"\$RUN_DIR/audit-comment.md\""
mkdir -p "$R/\$RUN_DIR"
printf '%s\n' "<!-- co-review-audit head=$FAKE run=r -->" >"$R/\$RUN_DIR/audit-comment.md"
deny "single-quoted path is literal" "$R" "RUN_DIR=$FIX/ok; gh pr comment 5 --body-file '\$RUN_DIR/audit-comment.md'"
deny "escaped dollar path is literal" "$R" "RUN_DIR=$FIX/ok; gh pr comment 5 --body-file \\\$RUN_DIR/audit-comment.md"
allow "export RUN_DIR with braces" "$R" "export RUN_DIR=$FIX/ok; gh pr comment 5 --body-file \"\${RUN_DIR}/audit-comment.md\""
run bash "$R" "gh pr comment 5 --body-file \"\$RUN_DIR/audit-comment.md\"" RUN_DIR="$FIX/ok"
if [ "$RC" -eq 0 ] && [ ! -s "$FIX/err" ]; then ok "environment RUN_DIR"; else no "environment RUN_DIR"; fi
cp "$FIX/ok/audit-comment.md" "$FIX/stale.md"
deny "same-command redirect is unverifiable" "$R" "printf '<!-- co-review-audit head=abc -->' >$FIX/stale.md && gh pr comment 5 --body-file $FIX/stale.md"
deny "same-command tee is unverifiable" "$R" "printf '<!-- co-review-audit head=abc -->' | tee $FIX/stale.md && gh pr comment 5 --body-file $FIX/stale.md"
cp "$FIX/ok/audit-comment.md" "$FIX/x.md"
deny "same-command cp over a marker file" "$R" "cp $FIX/bad.md $FIX/x.md && gh pr comment 5 --body-file $FIX/x.md"
if grep -q 'own command' "$FIX/err"; then ok "rewrite reason named"; else no "rewrite reason named"; fi
deny "substitution in a builtin argument" "$R" ": \"\$(cp $FIX/bad.md $FIX/x.md)\"; gh pr comment 5 --body-file $FIX/x.md"
deny "substitution in an assignment" "$R" "v=\"\$(cp $FIX/bad.md $FIX/x.md)\"; gh pr comment 5 --body-file $FIX/x.md"
deny "backtick substitution" "$R" "true \"\`cp $FIX/bad.md $FIX/x.md\`\"; gh pr comment 5 --body-file $FIX/x.md"
deny "substitution in the gh segment" "$R" "gh pr comment 5 --title \"\$(cp $FIX/bad.md $FIX/x.md)\" --body-file $FIX/x.md"
ln -s "$R" "$FIX/link"
deny "unsafe prefix before an inline marker" "$R" "git status && gh pr comment 5 --body '$GOOD'"
deny "retargeted link before an inline marker" "$FIX" "ln -sfn $R2 $FIX/link; cd $FIX/link && gh pr comment 5 --body '$GOOD'"
allow "link without a retarget" "$FIX" "cd $FIX/link && gh pr comment 5 --body '$GOOD'"
deny "any other command before a marker file" "$R" "git status && gh pr comment 5 --body-file good.md"
allow "harmless prefix before a marker file" "$R" "true; test -d . && gh pr comment 5 --body-file good.md"
allow "same-command write without a hint" "$R" "echo hi >$FIX/fresh.md && gh pr comment 5 --body-file $FIX/fresh.md"
allow "pipe without a hint" "$R" "printf x | gh pr comment 5 --body-file -"
deny "hinted pipe" "$R" "printf '<!-- co-review-audit head=abc -->' | gh pr comment 5 --body-file -"
deny "hinted gh api" "$R" "gh api repos/o/r/issues/5/comments -f body='<!-- co-review-audit head=abc -->'"
allow "plain gh api" "$R" "gh api repos/o/r/pulls"

# --- review focus: shapes no other case exercises ---
deny "operators glued to a subshell" "$R" "(cd $R2);gh pr comment 5 --body-file c.md"
deny "<<- heredoc strips leading tabs" "$R" "$(printf "gh pr comment 5 --body-file - <<-'EOF'\n\t%s\n\tEOF" "$BAD")"
deny "here-string is not a heredoc" "$R" "gh pr comment 5 --body-file - <<< '$BAD'"
deny "here-string does not swallow later lines" "$R" "$(printf "cat <<< x\ngh pr comment 5 --body '%s'" "$BAD")"
printf '%s\r\n' "$BAD" >"$FIX/crlf-bad.md"
printf '%s\r\n' "$GOOD" >"$FIX/crlf-good.md"
deny "CRLF body file" "$R" "gh pr comment 5 --body-file $FIX/crlf-bad.md"
allow "valid CRLF body file" "$R" "gh pr comment 5 --body-file $FIX/crlf-good.md"
allow "-R wins over GH_REPO" "$R" "GH_REPO=other/repo gh pr comment 5 -R owner/repo --body '$GOOD'"

# --- gh hidden behind a wrapper's own options ---
deny "env -u option hides gh" "$R" "env -u GH_TOKEN gh pr comment 5 --body '$BAD'"
deny "command -- hides gh" "$R" "command -- gh pr comment 5 --body '$BAD'"
deny "nice option hides gh" "$R" "nice -n 5 gh pr comment 5 --body '$BAD'"
deny "sudo option hides gh" "$R" "sudo -u nobody gh pr comment 5 --body '$BAD'"
deny "leading redirection hides gh" "$R" "</dev/null gh pr comment 5 --body '$BAD'"
deny "env -u option before a valid marker is still hidden" "$R" "env -u GH_TOKEN gh pr comment 5 --body '$GOOD'"
allow "env -u option without a hint" "$R" "env -u GH_TOKEN gh pr comment 5 --body plain"

# --- R8: non-marker traffic ---
printf 'plain\n' >"$FIX/plain.md"
allow "ordinary comment" "$R" "gh pr comment 5 --body LGTM"
allow "ordinary body file" "$R" "gh pr create --title t --body-file $FIX/plain.md"
allow "git status" "$R" "git status"
allow "other html comment outside a repo" "$FIX/plain" "gh pr comment 5 --body '<!-- other: sha=abc -->'"
printf '%s' '{"tool_name":"Write","tool_input":{"file_path":"x","content":"<!-- co-review-audit head=abc -->"}}' |
    env HOME="$FIX/home" "$HOOK" >"$FIX/out" 2>"$FIX/err"
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$FIX/err" ]; then ok "Write payload ignored"; else no "Write payload ignored"; fi

# --- R1: Codex payload shapes, ungated ---
deny "exec_command cmd" "$R" "gh pr comment 5 --body '$BAD7'" exec
deny "nested unified_exec" "$R" "gh pr comment 5 --body '$BAD7'" nested
deny "lowercase shell" "$R" "gh pr comment 5 --body '$BAD7'" shell
deny "shell_command workdir" "$R" "gh pr comment 5 --body-file rel.md" workdir
allow "valid marker via exec_command" "$R" "gh pr comment 5 --body '$GOOD'" exec

# --- R9: fail modes ---
printf 'not json' | env HOME="$FIX/home" "$HOOK" >"$FIX/out" 2>"$FIX/err"
RC=$?
if [ "$RC" -eq 0 ] && [ ! -s "$FIX/err" ]; then ok "malformed payload fails open"; else no "malformed payload fails open"; fi
PY3=$(command -v python3)
mkdir -p "$FIX/nogit"
payload bash "$R" "gh pr comment 5 --body '$GOOD'" |
    env -u GH_REPO HOME="$FIX/home" PATH="$FIX/nogit" "$PY3" "$HOOK" >"$FIX/out" 2>"$FIX/err"
RC=$?
if [ "$RC" -eq 2 ] && grep -q '^Blocked: ' "$FIX/err"; then ok "missing git denies a marker"; else no "missing git denies a marker"; fi

O="$FIX/origin"
C="$FIX/clone"
mk "$O" https://example.invalid/owner/repo.git || exit 1
g -C "$O" config uploadpack.allowFilter true
g -C "$O" config uploadpack.allowAnySHA1InWant true
g clone -q --no-local --filter=blob:none "file://$O" "$C" >/dev/null 2>&1 || exit 1
g -C "$O" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m c
NEW=$(g -C "$O" rev-parse HEAD)
before=$(find "$C/.git/objects" -type f | wc -l)
deny "promisor-only commit denied" "$C" "gh pr comment 5 --body '$(rnd "$NEW" "$(g -C "$C" rev-parse HEAD)")'"
after=$(find "$C/.git/objects" -type f | wc -l)
if [ "$before" -eq "$after" ]; then ok "verification fetched nothing"; else no "verification fetched nothing"; fi
if g -C "$C" cat-file -t "$NEW" >/dev/null 2>&1; then ok "control: a plain lookup would fetch"; else no "control: a plain lookup would fetch"; fi

# --- repair round 1: gh behind a shell keyword (B1) ---
AUDIT_BAD="<!-- co-review-audit head=$FAKE run=r -->"
printf '%s\n' "$AUDIT_BAD" >"$R/keyword-bad.md"
deny "if-then wraps the gh segment" "$R" "if true; then gh pr comment 5 --body '$AUDIT_BAD'; fi"
deny "brace group wraps the gh segment" "$R" "{ gh pr comment 5 --body '$AUDIT_BAD'; }"
deny "bang wraps the gh segment" "$R" "! gh pr comment 5 --body '$AUDIT_BAD'"
deny "for-do wraps the gh segment" "$R" "for n in 5; do gh pr comment \"\$n\" --body '$AUDIT_BAD'; done"
deny "else wraps the gh segment" "$R" "if false; then :; else gh pr comment 5 --body-file keyword-bad.md; fi"
deny "ship-style duplicate check wraps the gh segment" "$R" "if ! gh pr view 5 --comments | grep -q 'co-review-audit head=$H'; then gh pr comment 5 --body '$AUDIT_BAD'; fi"
deny "control: plain gh segment still denied" "$R" "gh pr comment 5 --body '$AUDIT_BAD'"

# --- repair round 1: unquoted command/arithmetic substitution before the body flag (B2) ---
deny "unquoted command substitution before body" "$R" "gh pr comment \$(echo 5) --body '$AUDIT_BAD'"
deny "unquoted nested gh substitution before body-file" "$R" "gh pr comment \$(gh pr view --json number -q .number) --body-file keyword-bad.md"
deny "unquoted arithmetic substitution before body" "$R" "gh pr comment \$((4+1)) --body '$AUDIT_BAD'"
deny "control: backtick substitution before body still denied" "$R" "gh pr comment \`echo 5\` --body '$AUDIT_BAD'"

# --- repair round 1: ANSI-C quoted bodies are not decoded (A-1) ---
deny "ansi-c body spreads the marker to line two" "$R" "gh pr comment 5 --body \$'Review done\n$AUDIT_BAD'"
deny "ansi-c body wraps a bad marker directly" "$R" "gh pr comment 5 --body \$'$AUDIT_BAD'"

# --- repair round 2: an untaken branch's state leaks into a later gh segment (B3) ---
mkdir -p "$R/sub"
printf '%s\n' "$BAD" >"$R/x.md"
printf '%s\n' "$BAD" >"$R/bad.md"
printf '%s\n' "$GOOD" >"$R/sub/x.md"
deny "else does not inherit an untaken cd" "$R" "if [ 1 = 2 ]; then cd sub; else gh pr comment 5 --body-file x.md; fi"
deny "else does not inherit an untaken cd, target missing" "$R" "if [ 1 = 2 ]; then cd sub; else gh pr comment 5 --body-file bad.md; fi"
deny "elif does not inherit an untaken cd" "$R" "if [ 1 = 2 ]; then cd sub; elif true; then gh pr comment 5 --body-file x.md; fi"
deny "else does not inherit an untaken assignment" "$R" "F=bad.md; if [ 1 = 2 ]; then F=good.md; else gh pr comment 5 --body-file \"\$F\"; fi"
deny "control: plain body-file still denied" "$R" "gh pr comment 5 --body-file x.md"
allow "control: a straight-line cd still resolves" "$R" "cd sub && gh pr comment 5 --body-file x.md"

# --- repair round 2: RESERVED_WORDS misses function and coproc (A-8) ---
deny "function definition wraps the gh segment" "$R" "function f { gh pr comment 5 --body '$AUDIT_BAD'; }; f"
deny "coproc wraps the gh segment" "$R" "coproc gh pr comment 5 --body '$AUDIT_BAD'"

# --- repair round 2: locale ($"...") quoting is not decoded (A-9) ---
deny "locale-quoted body wraps a bad marker directly" "$R" "gh pr comment 5 --body \$\"$AUDIT_BAD\""
allow "locale quoting without a hint stays allowed" "$R" "gh pr comment 5 --body \$\"no marker here\""

# --- repair round 3: a later segment of the same branch body still leaks (B4) ---
deny "else does not inherit an untaken cd behind a harmless first command" "$R" "if [ 1 = 2 ]; then true; cd sub; else gh pr comment 5 --body-file x.md; fi"
deny "elif does not inherit an untaken cd behind a harmless first command" "$R" "if [ 1 = 2 ]; then :; cd sub; elif true; then gh pr comment 5 --body-file x.md; fi"
deny "else does not inherit an untaken assignment behind a harmless first command" "$R" "F=bad.md; if [ 1 = 2 ]; then true; F=good.md; else gh pr comment 5 --body-file \"\$F\"; fi"
deny "else does not inherit an untaken export behind a harmless first command" "$R" "F=bad.md; if [ 1 = 2 ]; then true; export F=good.md; else gh pr comment 5 --body-file \"\$F\"; fi"
deny "else does not inherit an untaken unset behind a harmless first command" "$R" "F=bad.md; if [ 1 = 2 ]; then true; unset F; else gh pr comment 5 --body-file \"\$F\"; fi"
allow "control: straight-line cd still resolves after a round-3 harmless prefix" "$R" "true; cd sub && gh pr comment 5 --body-file x.md"

# --- repair round 3: coproc with a name and a brace body (A-12) ---
deny "named coproc with a brace body wraps the gh segment" "$R" "coproc c { gh pr comment 5 --body '$AUDIT_BAD'; }"
allow "named coproc with a valid marker" "$R" "coproc c { gh pr comment 5 --body '$GOOD'; }"

# --- installed layouts: the shared modules resolve through symlinks ---
mkdir -p "$FIX/home/.claude" "$FIX/codex/hooks"
ln -s "$PWD/claude/hooks" "$FIX/home/.claude/hooks"
ln -s "$PWD/claude/hooks/marker_sha_guard.py" "$FIX/codex/hooks/marker_sha_guard.py"
for link in "$FIX/home/.claude/hooks/marker_sha_guard.py" "$FIX/codex/hooks/marker_sha_guard.py"; do
    payload bash "$R" "gh pr comment 5 --body '$BAD7'" |
        env -u GH_REPO HOME="$FIX/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$link" \
        >"$FIX/out" 2>"$FIX/err"
    RC=$?
    if [ "$RC" -eq 2 ]; then ok "runs through $link"; else no "runs through $link"; fi
done

# --- static ---
if grep -qx 'sh claude/hooks/marker-sha-guard.test.sh' bin/dotfiles-tests; then
    ok "static: suite is registered in bin/dotfiles-tests"
else
    no "static: suite is registered in bin/dotfiles-tests"
fi
if grep -qF 'rm_guard.tokenize' "$HOOK"; then no "static: hook lexes with quote provenance"; else ok "static: hook lexes with quote provenance"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
