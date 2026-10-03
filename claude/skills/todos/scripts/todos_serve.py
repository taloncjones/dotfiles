#!/usr/bin/env python3
"""todos_serve.py - serve this repo's todo board on 127.0.0.1 with note forms.

Invoked as `todos.sh serve [--runtime claude|codex] [--personal] [--online]
[--completed N] [--port N] [--open]`; see claude/skills/todos/SKILL.md
("Serve"). Every GET rebuilds the page with todos_dashboard; every note goes
through `todos.sh note`, the one writer, so TODO.md, the lock and the store
sync stay correct. Every request must name this server in its Host header
and carry the per-run token (`?t=` on GETs, a form field on POSTs), so
neither another site nor another local process can read the page or post
notes. The token URL is printed once on stderr.
"""
import argparse
import hmac
import os
import html
import secrets
import shutil
import signal
import subprocess
import sys
import tempfile
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

import todos_dashboard as board

BIND_HOST = "127.0.0.1"
MAX_BODY = 64 * 1024
NOTE_TIMEOUT = 120
# Seconds a connection may sit idle: the server is single-threaded, so an
# idle socket (browsers open speculative ones) would otherwise block it.
IDLE_TIMEOUT = 1
NOTE_STATUS = {0: 303, 2: 400, 3: 409}
TITLES = {400: "Note refused", 403: "Forbidden", 409: "The todo changed on disk",
          500: "Note failed", 504: "Note still running"}
USAGE = ("usage: todos.sh serve [--runtime claude|codex] [--personal] [--online] "
         "[--completed N] [--port N] [--open]")


class Parser(argparse.ArgumentParser):
    def error(self, message):
        board.die(f"{message} ({USAGE})")


def parse_args(argv):
    p = Parser(prog="todos.sh serve", add_help=True)
    p.add_argument("--runtime", choices=("claude", "codex"))
    p.add_argument("--personal", action="store_true")
    p.add_argument("--online", action="store_true")
    p.add_argument("--completed", type=int, default=board.DEFAULT_COMPLETED)
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--open", action="store_true")
    args = p.parse_args(argv)
    if args.completed < 0:
        board.die("--completed needs a non-negative integer")
    if not 0 <= args.port <= 65535:
        board.die("--port needs 0-65535")
    return args


def message_page(title, message, note="", back="/"):
    """A small error page; echoes the submitted note so it can be copied."""
    esc = board.esc
    kept = ""
    if note:
        kept = ('<p class="meta">Your note text:</p>'
                f'<textarea readonly rows="6" cols="80">{esc(note)}</textarea>')
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<title>{esc(title)}</title><style>{board.CSS}</style></head><body><main>'
            f'<h1>{esc(title)}</h1><p class="meta">{esc(message)}</p>{kept}'
            f'<p><a href="{esc(back)}">Back to the board</a></p></main></body></html>')


def note_env():
    """The server's environment for `todos.sh note`, minus anything that
    would skip its lock or point git somewhere else."""
    return {k: v for k, v in os.environ.items()
            if k != "TODOS_STORE_LOCKED" and not k.startswith("GIT_")}


class Handler(BaseHTTPRequestHandler):
    server_version = "todos-serve"
    timeout = IDLE_TIMEOUT

    def log_message(self, format, *args):
        pass

    def send_page(self, status, page, location=None):
        body = page.encode("utf-8")
        self.send_response(status)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "frame-ancestors 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def host_ok(self):
        return self.headers.get("Host") == f"{BIND_HOST}:{self.server.server_port}"

    def token_ok(self, supplied):
        return hmac.compare_digest(supplied.encode(), self.server.token.encode())

    def do_GET(self):
        if not self.host_ok():
            return self.send_page(403, message_page(TITLES[403], "Unexpected Host header."))
        url = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(url.query)
        if not self.token_ok(query.get("t", [""])[0]):
            return self.send_page(403, message_page(
                TITLES[403], "Open the URL that todos.sh serve printed; it carries the run token."))
        if url.path != "/":
            return self.send_page(404, message_page("Not found", url.path))
        open_id = query.get("open", [""])[0]
        view = {k: query.get(k, [""])[0] for k in ("q", "area", "priority", "sort")}
        view["q"] = view["q"].strip()
        edit = {"token": self.server.token, "open": open_id, "view": view}
        self.send_page(200, board.build_page(self.server.ctx, self.server.args, edit))

    def do_POST(self):
        if not self.host_ok():
            return self.send_page(403, message_page(TITLES[403], "Unexpected Host header."))
        if urllib.parse.urlsplit(self.path).path != "/note":
            return self.send_page(404, message_page("Not found", self.path))
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            length = -1
        if length < 0:
            return self.send_page(400, message_page("Bad request", "Missing Content-Length."))
        if length > MAX_BODY:
            self.close_connection = True
            return self.send_page(413, message_page("Too large", f"Notes are capped well below {MAX_BODY} bytes."))
        form = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8", errors="replace"),
                                     keep_blank_values=True)

        def field(name):
            return form.get(name, [""])[0]

        note_id, section, sha = field("id"), field("section"), field("sha")
        note = field("note").replace("\r\n", "\n").replace("\r", "\n")
        if not self.token_ok(field("token")):
            return self.send_page(403, message_page(
                TITLES[403], "This page is from an earlier server run; reopen the URL "
                "that todos.sh serve printed.", note))
        back = (f"/?t={self.server.token}&open={urllib.parse.quote(note_id)}"
                f"#prd-{urllib.parse.quote(note_id)}")
        if "\0" in note_id + section + sha:
            return self.send_page(400, message_page(
                TITLES[400], "The form fields contain a NUL byte.", note, back))
        argv = ["bash", str(board.TODOS_SH), "note", note_id, section, "--expect-sha", sha]
        try:
            r = subprocess.run(argv, cwd=self.server.ctx["root"], env=note_env(),
                               input=note.encode("utf-8"), capture_output=True,
                               timeout=NOTE_TIMEOUT)
        except subprocess.TimeoutExpired:
            return self.send_page(504, message_page(
                TITLES[504], "todos.sh note did not finish in time. The note may still be "
                "written: reload the board before adding it again.", note, back))
        err = r.stderr.decode("utf-8", errors="replace")
        sys.stderr.write(err)
        status = NOTE_STATUS.get(r.returncode, 500)
        if status == 303:
            return self.send_page(303, "", location=back)
        msg = err.strip() or f"todos.sh note exited {r.returncode}"
        self.send_page(status, message_page(TITLES[status], msg, note, back))


class BoardServer(HTTPServer):
    """One request at a time; holds the board context and the form token."""

    def __init__(self, port, ctx, args):
        super().__init__((BIND_HOST, port), Handler)
        self.ctx, self.args = ctx, args
        self.token = secrets.token_urlsafe(32)


def write_redirect(token_url):
    """Write a private HTML redirect to token_url; return (directory, file path).

    The opener gets this path, so the token never appears in a process argv.
    """
    d = tempfile.mkdtemp(prefix="todos-serve-")
    path = os.path.join(d, "open.html")
    href = html.escape(token_url, quote=True)
    page = ('<!doctype html><meta charset="utf-8">'
            f'<meta http-equiv="refresh" content="0; url={href}">'
            f'<a href="{href}">Open the todo board</a>\n')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(page)
    return d, path


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    ctx = board.board_context(args)
    try:
        server = BoardServer(args.port, ctx, args)
    except OSError as e:
        board.die(f"cannot listen on {BIND_HOST}:{args.port}: {e.strerror or e}")
    url = f"http://{BIND_HOST}:{server.server_port}/"
    token_url = f"{url}?t={server.token}"
    print(url, flush=True)
    print(token_url, file=sys.stderr, flush=True)
    redirect_dir = None
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        if args.open:
            redirect_dir, redirect_file = write_redirect(token_url)
            board.open_file(redirect_file)
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if redirect_dir:
            shutil.rmtree(redirect_dir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
