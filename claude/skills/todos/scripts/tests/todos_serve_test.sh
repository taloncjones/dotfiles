#!/usr/bin/env bash
# Test suite for `todos.sh serve` (todos_serve.py). Starts the real server on
# an OS-chosen loopback port and talks to it with python's http.client;
# never opens a browser or touches the network.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TODOS="$HERE/../todos.sh"

# A developer's own overrides must not leak into the fixtures.
unset TODOS_DASHBOARD_DIR TODOS_STATE_ROOT TODOS_DASHBOARD_TODOS_SH TODOS_DASHBOARD_OPENER \
      TODOS_OFFLINE TODOS_GH TODOS_BASE_REF TODOS_STORE_LOCKED TODOS_LOCK_WAIT XDG_STATE_HOME \
      CODEX_HOME CLAUDE_CONFIG_DIR CLAUDE_PERSONAL_ONLY CLAUDE_WORK_CONFIG_DIR CLAUDE_WORK_TREE \
      ORCH_RUNTIME HERDR_PERSONAL WORKFLOW_PERSONAL_ACCOUNT HERDR_ENV HERDR_PANE_ID \
      HERDR_WORKSPACE_ID HERDR_ACCOUNT_ID
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TEMPLATE_DIR=""

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "missing [$3]";; esac; }
assert_missing()  { case "$2" in *"$3"*) bad "$1" "found [$3]";; *) ok "$1";; esac; }

# http <url> <method> <path> [host] [form-urlencoded body] -> "status|location|body"
http() {
  python3 - "$@" <<'PY'
import http.client, sys, urllib.parse
url, method, path = sys.argv[1:4]
host = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else None
body = sys.argv[5].encode() if len(sys.argv) > 5 else b""
port = urllib.parse.urlsplit(url).port
c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
c.putrequest(method, path, skip_host=True)
c.putheader("Host", host or f"127.0.0.1:{port}")
if method == "POST":
    c.putheader("Content-Type", "application/x-www-form-urlencoded")
    c.putheader("Content-Length", str(len(body)))
c.endheaders(body or None)
r = c.getresponse()
print(f"{r.status}|{r.getheader('Location') or ''}|{r.read().decode()}")
PY
}
# form k=v... -> form-urlencoded body (python quoting, so CR and LF survive)
form() { python3 -c 'import sys, urllib.parse; print(urllib.parse.urlencode([tuple(a.split("=", 1)) for a in sys.argv[1:]]), end="")' "$@"; }
sha_of() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }

REPO=$(mktemp -d); REPO=$(cd "$REPO" && pwd -P)
STATE=$(mktemp -d)
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m base
mkdir -p "$REPO/.todos/pending" "$REPO/.todos/completed" "$REPO/.git/info"
printf '.todos/\n' >>"$REPO/.git/info/exclude"
ID=2026-06-01-serve-target
F="$REPO/.todos/pending/$ID.md"
cat >"$F" <<'EOF'
---
created: 2026-06-01
title: Serve target
files:
---

## Problem

Served problem.

## Solution

Served solution.
EOF
cat >"$REPO/.todos/completed/2026-05-30-finished.md" <<'EOF'
---
created: 2026-05-30
title: Finished
---

## Solution

All done.
EOF

OUT=$(mktemp); ERR=$(mktemp)
(cd "$REPO" && TODOS_STATE_ROOT="$STATE" TODOS_DASHBOARD_NOW="2026-06-01 09:00" \
  exec bash "$TODOS" serve --runtime claude --port 0) >"$OUT" 2>"$ERR" &
PID=$!
cleanup() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; rm -rf "$REPO" "$STATE" "$OUT" "$ERR"; }
trap cleanup EXIT
for _ in $(seq 1 100); do [ -s "$OUT" ] && break; sleep 0.1; done
URL=$(head -1 "$OUT")
for _ in $(seq 1 100); do [ -s "$ERR" ] && break; sleep 0.1; done
TOKEN=$(head -1 "$ERR" | sed -n 's/.*[?]t=\([^&]*\)$/\1/p')

test_serve_url() {
  case "$URL" in
    http://127.0.0.1:[0-9]*/) ok "serve: prints a loopback URL" ;;
    *) bad "serve: prints a loopback URL" "got [$URL]; stderr: $(cat "$ERR")" ;;
  esac
}
test_serve_url

test_serve_page() {
  local r sha
  r=$(http "$URL" GET "/?t=$TOKEN")
  sha=$(sha_of "$F")
  assert_contains "serve: GET / is 200" "${r%%|*}" "200"
  assert_contains "serve: pending row has a note form" "$r" "name=\"id\" value=\"$ID\"><input type=\"hidden\" name=\"section\" value=\"Solution\">"
  assert_contains "serve: form carries the file's hash" "$r" "name=\"sha\" value=\"$sha\""
  assert_contains "serve: completed row is rendered" "$r" 'data-prd="2026-05-30-finished"'
  assert_missing "serve: completed row has no form" "$r" 'name="id" value="2026-05-30-finished"'
  r=$(http "$URL" GET "/?t=$TOKEN&open=$ID")
  assert_contains "serve: ?open= opens that row" "$r" "<details class=\"prd\" id=\"prd-$ID\" open>"
  r=$(http "$URL" GET "/nope?t=$TOKEN")
  assert_eq "serve: unknown path is 404" "${r%%|*}" "404"
}
test_serve_page

test_serve_host_and_token() {
  local r before
  before=$(cksum <"$F")
  r=$(http "$URL" GET "/?t=$TOKEN" "attacker.example:80")
  assert_eq "serve: foreign Host is 403" "${r%%|*}" "403"
  assert_missing "serve: foreign Host gets no board" "$r" "Serve target"
  r=$(http "$URL" POST /note "" "$(form id=$ID section=Solution sha="$(sha_of "$F")" token=wrong note='Lost idea.')")
  assert_eq "serve: bad token is 403" "${r%%|*}" "403"
  assert_contains "serve: bad token page echoes the note" "$r" "Lost idea."
  assert_eq "serve: bad token leaves the file" "$(cksum <"$F")" "$before"
}
test_serve_host_and_token

test_serve_get_requires_token() {
  local r
  for q in "" "?t=wrong" "?t=" "?x=$TOKEN" "?open=$ID" "?open=$ID&t=wrong"; do
    r=$(http "$URL" GET "/$q")
    assert_eq "serve: GET /$q is 403" "${r%%|*}" "403"
    assert_missing "serve: GET /$q leaks no todo text" "$r" "Served problem."
    assert_missing "serve: GET /$q leaks no title" "$r" "Serve target"
    assert_missing "serve: GET /$q leaks no token" "$r" "$TOKEN"
  done
  r=$(http "$URL" GET "/nope")
  assert_eq "serve: tokenless unknown path is 403" "${r%%|*}" "403"
  r=$(http "$URL" GET "/?t=$TOKEN")
  assert_eq "serve: GET with the token is 200" "${r%%|*}" "200"
  assert_contains "serve: GET with the token shows the board" "$r" "Served problem."
  assert_eq "serve: stderr names the tokenized URL once" "$(grep -c "^http://127.0.0.1:[0-9]*/[?]t=$TOKEN$" "$ERR")" "1"
}
test_serve_get_requires_token

test_serve_post_note() {
  local page token sha old r
  page=$(http "$URL" GET "/?t=$TOKEN")
  token=$(printf '%s' "$page" | sed -n 's/.*name="token" value="\([^"]*\)".*/\1/p' | head -1)
  sha=$(sha_of "$F"); cp "$F" "$REPO/old.md"
  r=$(http "$URL" POST /note "" "$(form id=$ID section=Solution sha="$sha" token="$token" note=$'Served idea.\r\nSecond line.')")
  assert_eq "serve: good post redirects back to the row" "${r%|*}" "303|/?t=$TOKEN&open=$ID#prd-$ID"
  assert_eq "serve: note appended as LF note LF, CRLF folded to LF" \
    "$(python3 - "$REPO/old.md" "$F" <<'PY'
import sys
old = open(sys.argv[1], "rb").read()
new = open(sys.argv[2], "rb").read()
p = old.index(b"Served solution.\n") + len(b"Served solution.\n")
print(new == old[:p] + b"\nServed idea.\nSecond line.\n" + old[p:], b"\r" in new)
PY
)" "True False"
  printf 'Edited by hand.\n' >>"$F"; cp "$F" "$REPO/hand.md"
  r=$(http "$URL" POST /note "" "$(form id=$ID section=Solution sha="$sha" token="$token" note='Stale idea.')")
  assert_eq "serve: stale hash is 409" "${r%%|*}" "409"
  assert_contains "serve: 409 page echoes the note" "$r" "Stale idea."
  assert_eq "serve: stale post leaves the file" "$(cksum <"$F")" "$(cksum <"$REPO/hand.md")"
  r=$(http "$URL" POST /note "" "$(form id=2026-05-30-finished section=Solution sha="$sha" token="$token" note='x')")
  assert_eq "serve: completed id is 400" "${r%%|*}" "400"
  r=$(http "$URL" POST /note "" "$(form id=../completed/2026-05-30-finished section=Solution sha="$sha" token="$token" note='x')")
  assert_eq "serve: traversal id is 400" "${r%%|*}" "400"
  assert_eq "serve: completed todo unchanged" "$(tail -1 "$REPO/.todos/completed/2026-05-30-finished.md")" "All done."
}
test_serve_post_note

test_serve_body_cap() {
  local r
  r=$(python3 - "$URL" <<'PY'
import http.client, sys, urllib.parse
port = urllib.parse.urlsplit(sys.argv[1]).port
c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
c.putrequest("POST", "/note", skip_host=True)
c.putheader("Host", f"127.0.0.1:{port}")
c.putheader("Content-Length", "70000")
c.endheaders()
print(c.getresponse().status)
PY
)
  assert_eq "serve: body over 64 KiB is 413" "$r" "413"
}
test_serve_body_cap

test_serve_idle_socket() {
  local r
  r=$(python3 - "$URL" "$TOKEN" <<'PY'
import http.client, socket, sys, time, urllib.parse
port = urllib.parse.urlsplit(sys.argv[1]).port
idle = socket.create_connection(("127.0.0.1", port))
time.sleep(0.2)
start = time.monotonic()
c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
c.putrequest("GET", f"/?t={sys.argv[2]}", skip_host=True)
c.putheader("Host", f"127.0.0.1:{port}")
c.endheaders()
status = c.getresponse().status
print(f"{status}|{time.monotonic() - start < 10}")
idle.close()
PY
)
  assert_eq "serve: an idle connection does not block the server" "$r" "200|True"
}
test_serve_idle_socket

test_serve_frame_header() {
  local r
  r=$(python3 - "$URL" "$TOKEN" <<'PY'
import http.client, re, sys, urllib.parse
port = urllib.parse.urlsplit(sys.argv[1]).port
for path in (f"/?t={sys.argv[2]}", "/"):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    c.putrequest("GET", path, skip_host=True)
    c.putheader("Host", f"127.0.0.1:{port}")
    c.endheaders()
    resp = c.getresponse()
    csp = re.sub(r"'sha256-[A-Za-z0-9+/]{43}='", "'sha256-H'", resp.getheader("Content-Security-Policy"))
    print(csp, resp.getheader("Referrer-Policy"))
PY
)
  assert_eq "serve: pages refuse framing and referrers" "$r" "frame-ancestors 'none'; script-src 'sha256-H' no-referrer
frame-ancestors 'none'; script-src 'sha256-H' no-referrer"
}
test_serve_frame_header

test_serve_nul_field() {
  local page token r
  page=$(http "$URL" GET "/?t=$TOKEN")
  token=$(printf '%s' "$page" | sed -n 's/.*name="token" value="\([^"]*\)".*/\1/p' | head -1)
  r=$(http "$URL" POST /note "" "id=$ID%00x&section=Solution&sha=0&token=$token&note=x")
  assert_eq "serve: a NUL in a form field is 400" "${r%%|*}" "400"
}
test_serve_nul_field

test_serve_timeout_504() {
  local stub r
  stub="$REPO/slow-todos.sh"
  printf '#!/usr/bin/env bash\nsleep 5\n' >"$stub"
  r=$(cd "$REPO" && TODOS_STATE_ROOT="$STATE" python3 - "$HERE/.." "$stub" <<'PY'
import sys, threading, urllib.parse, http.client
sys.path.insert(0, sys.argv[1])
import todos_dashboard as board
import todos_serve as srv
board.TODOS_SH = sys.argv[2]
srv.NOTE_TIMEOUT = 1
args = srv.parse_args(["--runtime", "claude"])
server = srv.BoardServer(0, board.board_context(args), args)
threading.Thread(target=server.serve_forever, daemon=True).start()
port = server.server_port
body = urllib.parse.urlencode({"id": "2026-06-01-serve-target", "section": "Solution",
                               "sha": "0" * 64, "token": server.token, "note": "Late idea."}).encode()
c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
c.putrequest("POST", "/note", skip_host=True)
c.putheader("Host", f"127.0.0.1:{port}")
c.putheader("Content-Type", "application/x-www-form-urlencoded")
c.putheader("Content-Length", str(len(body)))
c.endheaders(body)
resp = c.getresponse()
page = resp.read().decode()
print(f"{resp.status}|{'Late idea.' in page}|{'may still be' in page}")
server.shutdown()
PY
)
  assert_eq "serve: a slow note is 504 and echoes the note" "$r" "504|True|True"
}
test_serve_timeout_504

test_serve_quiet_stdout() {
  assert_eq "serve: stdout holds only the URL" "$(wc -l <"$OUT" | tr -d ' ')" "1"
}
test_serve_quiet_stdout

test_serve_rejects_host_flag() {
  local rc err
  err=$( (cd "$REPO" && TODOS_STATE_ROOT="$STATE" bash "$TODOS" serve --runtime claude --host 0.0.0.0) 2>&1 >/dev/null ); rc=$?
  assert_eq "serve: --host is a usage error" "$rc" "1"
  assert_contains "serve: --host usage message" "$err" "unrecognized arguments: --host"
}
test_serve_rejects_host_flag

test_serve_ignores_inherited_lock_marker() {
  local out2 err2 pid2 url2 lock holder page token r
  out2=$(mktemp); err2=$(mktemp)
  (cd "$REPO" && TODOS_STATE_ROOT="$STATE" TODOS_STORE_LOCKED=1 TODOS_LOCK_WAIT=1 \
    exec bash "$TODOS" serve --runtime claude --port 0) >"$out2" 2>"$err2" &
  pid2=$!
  for _ in $(seq 1 100); do [ -s "$out2" ] && break; sleep 0.1; done
  url2=$(head -1 "$out2")
  for _ in $(seq 1 100); do [ -s "$err2" ] && break; sleep 0.1; done
  TOKEN2=$(head -1 "$err2" | sed -n 's/.*[?]t=\([^&]*\)$/\1/p')
  lock="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/todos-sync.lock"
  python3 "$HERE/../todos_store.py" lock "$lock" 30 -- sleep 26.519 & holder=$!
  for _ in $(seq 1 50); do
    python3 "$HERE/../todos_store.py" lock "$lock" 0 -- true; [ "$?" = 75 ] && break; sleep 0.1
  done
  page=$(http "$url2" GET "/?t=$TOKEN2")
  token=$(printf '%s' "$page" | sed -n 's/.*name="token" value="\([^"]*\)".*/\1/p' | head -1)
  cp "$F" "$REPO/pre-lock.md"
  r=$(http "$url2" POST /note "" "$(form id=$ID section=Solution sha="$(sha_of "$F")" token="$token" note='Locked out.')")
  assert_eq "serve: inherited TODOS_STORE_LOCKED still waits for the lock" "${r%%|*}" "500"
  assert_contains "serve: busy lock message shown" "$r" "todos: .todos is busy"
  assert_eq "serve: busy lock leaves the file" "$(cksum <"$F")" "$(cksum <"$REPO/pre-lock.md")"
  kill -9 "$holder"; wait "$holder" 2>/dev/null; pkill -f 'sleep 26.519' 2>/dev/null
  kill "$pid2" 2>/dev/null; wait "$pid2" 2>/dev/null; rm -f "$out2" "$err2"
}
test_serve_ignores_inherited_lock_marker

test_serve_open_keeps_token_out_of_argv() {
  local rec argv_file out3 err3 pid3 token3 argv target mode owner dir
  rec=$(mktemp); argv_file=$(mktemp); out3=$(mktemp); err3=$(mktemp)
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s"\n' "$argv_file" >"$rec"
  chmod 700 "$rec"
  (cd "$REPO" && TODOS_STATE_ROOT="$STATE" TODOS_DASHBOARD_OPENER="$rec" \
    exec bash "$TODOS" serve --runtime claude --port 0 --open) >"$out3" 2>"$err3" &
  pid3=$!
  for _ in $(seq 1 100); do [ -s "$err3" ] && [ -s "$argv_file" ] && break; sleep 0.1; done
  token3=$(head -1 "$err3" | sed -n 's/.*[?]t=\([^&]*\)$/\1/p')
  argv=$(cat "$argv_file")
  assert_missing "serve --open: opener argv has no token" "$argv" "$token3"
  assert_missing "serve --open: opener argv has no query string" "$argv" "?t="
  target=${argv#file://}
  if [ -f "$target" ] && [ ! -L "$target" ]; then
    ok "serve --open: opener gets a regular file"
    mode=$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$target")
    owner=$(python3 -c 'import os, sys; print(os.stat(sys.argv[1]).st_uid == os.getuid())' "$target")
    assert_eq "serve --open: redirect file is mode 0600" "$mode" "0o600"
    assert_eq "serve --open: redirect file is owned by the user" "$owner" "True"
    assert_contains "serve --open: redirect file refreshes to the token URL" "$(cat "$target")" "http-equiv=\"refresh\""
    assert_contains "serve --open: redirect file carries the token URL" "$(cat "$target")" "$(head -1 "$err3")"
  else
    bad "serve --open: opener gets a regular file" "argv [$argv]"
  fi
  assert_eq "serve --open: stdout is the bare URL" "$(sed -n 's/^\(http:\/\/127\.0\.0\.1:[0-9]*\/\)$/\1/p' "$out3" | head -1)" "$(head -1 "$out3")"
  assert_eq "serve --open: stderr is the single token URL" "$(wc -l <"$err3" | tr -d ' ')" "1"
  dir=$(dirname "$target")
  kill "$pid3" 2>/dev/null; wait "$pid3" 2>/dev/null
  if [ -e "$target" ] || [ -d "$dir" ]; then
    bad "serve --open: redirect file removed on exit" "still present: $target"
  else
    ok "serve --open: redirect file removed on exit"
  fi
  rm -f "$rec" "$argv_file" "$out3" "$err3"
}
test_serve_open_keeps_token_out_of_argv

# Board-search fixtures. Written after the note tests so those cases keep
# their one-pending-todo board; every GET below re-reads .todos/.
cat >"$REPO/.todos/pending/2026-07-01-alpha.md" <<'EOF'
---
created: 2026-07-01
title: Alpha
area: board
priority: low
due: 2026-09-01
---

## Problem

Needle zebra.
EOF
cat >"$REPO/.todos/pending/2026-07-02-beta.md" <<'EOF'
---
created: 2026-07-02
title: Beta
area: board
priority: high
---

## Problem

Needle only.
EOF
cat >"$REPO/.todos/pending/2026-07-03-gamma.md" <<'EOF'
---
created: 2026-07-03
title: Gamma
area: store
priority: med
due: 2026-08-01
---

## Problem

Other words.
EOF
cat >"$REPO/.todos/completed/2026-07-04-delta.md" <<'EOF'
---
created: 2026-07-04
title: Delta
---

## Problem

Needle in a finished todo.
EOF

# open_order <page> -> pending row ids in page order (completed rows carry no data-state)
open_order() { printf '%s' "$1" | python3 -c 'import re, sys; print(" ".join(re.findall(r"data-todo=\"([^\"]+)\" data-state", sys.stdin.read())))'; }

test_serve_search() {
  local r
  r=$(http "$URL" GET "/?t=$TOKEN&q=zebra")
  assert_eq "search: one term keeps only the matching row" "$(open_order "$r")" "2026-07-01-alpha"
  r=$(http "$URL" GET "/?t=$TOKEN&q=needle")
  assert_eq "search: matches body text" "$(open_order "$r")" "2026-07-01-alpha 2026-07-02-beta"
  assert_contains "search: matching completed row shown" "$r" 'data-todo="2026-07-04-delta"'
  assert_missing "search: other completed row hidden" "$r" 'data-todo="2026-05-30-finished"'
  r=$(http "$URL" GET "/?t=$TOKEN&q=NEEDLE+zebra")
  assert_eq "search: terms are ANDed, case-insensitive" "$(open_order "$r")" "2026-07-01-alpha"
  r=$(http "$URL" GET "/?t=wrong&q=needle")
  assert_eq "search: stale token is 403" "${r%%|*}" "403"
  assert_missing "search: stale token shows no todo" "$r" "Needle"
}
test_serve_search

test_serve_filter_area() {
  local r
  r=$(http "$URL" GET "/?t=$TOKEN&area=board")
  assert_eq "area: only that area" "$(open_order "$r")" "2026-07-01-alpha 2026-07-02-beta"
}
test_serve_filter_area

test_serve_filter_priority() {
  local r
  r=$(http "$URL" GET "/?t=$TOKEN&priority=high")
  assert_eq "priority: only that priority" "$(open_order "$r")" "2026-07-02-beta"
  r=$(http "$URL" GET "/?t=$TOKEN&priority=urgent")
  assert_eq "priority: unknown value matches nothing" "$(open_order "$r")" ""
}
test_serve_filter_priority

test_serve_sort() {
  local r
  r=$(http "$URL" GET "/?t=$TOKEN")
  assert_eq "sort: default is due date, then priority" "$(open_order "$r")" "2026-07-03-gamma 2026-07-01-alpha 2026-07-02-beta $ID"
  r=$(http "$URL" GET "/?t=$TOKEN&sort=priority")
  assert_eq "sort: priority" "$(open_order "$r")" "2026-07-02-beta 2026-07-03-gamma 2026-07-01-alpha $ID"
  r=$(http "$URL" GET "/?t=$TOKEN&sort=created")
  assert_eq "sort: newest first" "$(open_order "$r")" "2026-07-03-gamma 2026-07-02-beta 2026-07-01-alpha $ID"
  r=$(http "$URL" GET "/?t=$TOKEN&sort=bogus")
  assert_eq "sort: unknown value keeps the default" "$(open_order "$r")" "2026-07-03-gamma 2026-07-01-alpha 2026-07-02-beta $ID"
}
test_serve_sort
test_serve_filter_form() {
  local r
  r=$(http "$URL" GET "/?t=$TOKEN")
  assert_contains "form: no filter counts every open todo" "$r" 'data-match="4/4"'
  assert_contains "form: clear link keeps only the token" "$r" "<a href=\"/?t=$TOKEN\">Clear</a>"
  r=$(http "$URL" GET "/?t=$TOKEN&q=needle")
  assert_contains "form: search box keeps the query" "$r" 'name="q" value="needle"'
  assert_contains "form: count shows matches of total" "$r" 'data-match="2/4"'
  r=$(http "$URL" GET "/?t=$TOKEN&area=board")
  assert_contains "form: area option selected" "$r" '<option value="board" selected>board</option>'
  assert_contains "form: other areas listed" "$r" '<option value="store">store</option>'
  r=$(http "$URL" GET "/?t=$TOKEN&priority=urgent")
  assert_contains "form: unknown priority stays selected" "$r" '<option value="urgent" selected>urgent</option>'
  r=$(http "$URL" GET "/?t=$TOKEN&sort=priority")
  assert_contains "form: sort option selected" "$r" '<option value="priority" selected>Priority</option>'
  r=$(http "$URL" GET "/?t=$TOKEN&sort=bogus")
  assert_contains "form: unknown sort selects the default" "$r" '<option value="" selected>Due date, then priority</option>'
  r=$(http "$URL" GET "/?t=$TOKEN&q=%22%3E%3Cscript%3Ex%3C%2Fscript%3E")
  assert_contains "form: query is escaped" "$r" 'name="q" value="&quot;&gt;&lt;script&gt;x&lt;/script&gt;"'
  assert_missing "form: query never becomes markup" "$r" '<script>x</script>'
}
test_serve_filter_form
test_serve_copy_chips() {
  local r
  r=$(http "$URL" GET "/?t=$TOKEN")
  assert_contains "chips: copy the id" "$r" "<button type=\"button\" class=\"copy\" data-copy=\"$ID\" title=\"Copy: $ID\">$ID</button>"
  assert_contains "chips: copy the done command" "$r" "data-copy=\"todos.sh done $ID\""
  assert_contains "chips: copy the kick off command" "$r" "data-copy=\"kick off $ID\""
  assert_missing "chips: none on completed rows" "$r" 'data-copy="2026-05-30-finished"'
}
test_serve_copy_chips

test_serve_board_script() {
  local r
  r=$(python3 - "$URL" "$TOKEN" <<'PY'
import base64, hashlib, http.client, re, sys, urllib.parse
port = urllib.parse.urlsplit(sys.argv[1]).port
c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
c.putrequest("GET", f"/?t={sys.argv[2]}", skip_host=True)
c.putheader("Host", f"127.0.0.1:{port}")
c.endheaders()
resp = c.getresponse()
page = resp.read().decode()
scripts = re.findall(r"<script>(.*?)</script>", page, re.S)
print(page.count("<script"))
print(len(scripts) == 1 and "hashchange" in scripts[0] and "clipboard" in scripts[0])
digest = base64.b64encode(hashlib.sha256(scripts[0].encode()).digest()).decode() if scripts else ""
print(resp.getheader("Content-Security-Policy") == f"frame-ancestors 'none'; script-src 'sha256-{digest}'")
PY
)
  assert_eq "script: one board script, allowed by its hash in the CSP" "$r" "1
True
True"
}
test_serve_board_script

test_serve_filter_before_cap() {
  local r n
  # Ten newer completed todos push 2026-05-30-finished past the default
  # --completed 10 cap, so only filtering before the cap can show it.
  for n in 01 02 03 04 05 06 07 08 09 10; do
    printf -- '---\ncreated: 2026-08-%s\ntitle: Filler %s\n---\n' "$n" "$n" \
      >"$REPO/.todos/completed/2026-08-$n-filler.md"
  done
  r=$(http "$URL" GET "/?t=$TOKEN")
  assert_missing "cap: unfiltered board hides the oldest completed row" "$r" 'data-todo="2026-05-30-finished"'
  r=$(http "$URL" GET "/?t=$TOKEN&q=finished")
  assert_contains "cap: a search reaches completed rows past the cap" "$r" 'data-todo="2026-05-30-finished"'
}
test_serve_filter_before_cap

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
