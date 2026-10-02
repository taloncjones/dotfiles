#!/usr/bin/env python3
"""todos_prd.py - a todo's PRD sections: split, render, append a note.

  todos_prd.py append <file> <Problem|Solution|Verification> [--expect-sha HEX]

The note text comes on stdin. Exit 0 written, 2 refused input, 3 stale
(the file's SHA-256 is not HEX), 1 any other failure; on every non-zero
exit the file is unchanged. split_sections is the one boundary rule the
dashboard renderer and the note writer share.
"""
import hashlib
import html
import os
import re
import sys

NOTE_SECTIONS = ("Problem", "Solution", "Verification")
MAX_NOTE_BYTES = 4000
REFUSED = 2
STALE = 3
URL_RE = re.compile(r"https?://[^\s<>()\[\]\"']+")
TOKEN_RE = re.compile(r"\[([^\]\n]+)\]\(([^)\s]+)\)|(" + URL_RE.pattern + r")|\*\*([^*\n]+)\*\*")
LIST_ITEM_RE = re.compile(r"^( *)([-*+]|\d+\.) +(.*)$")
SUBHEAD_RE = re.compile(r"^#{3,6} +(.*)$")
NOTE_HEADING_RE = re.compile(r"^#{1,6}( |$)")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


class NoteRefused(Exception):
    pass


def esc(s):
    return html.escape(str(s), quote=True)


def safe_href(url):
    """Only http(s) URLs become links; anything else renders as text."""
    return url if re.match(r"^https?://", url) else ""


def is_fence(line):
    return line.startswith("```") or line.startswith("~~~")


def lines_of(text):
    """-> [(start, end, line)]: LF-split lines; end is past the LF."""
    out, pos = [], 0
    while pos < len(text):
        nl = text.find("\n", pos)
        end = len(text) if nl < 0 else nl + 1
        out.append((pos, end, text[pos:end].rstrip("\n")))
        pos = end
    return out


def split_sections(text):
    """-> (body_start, [(name, head_start, head_end, end)]).

    Frontmatter ends at the first `---` line after an opening `---` (the
    dashboard's frontmatter rule). A section heading is a `## ` line outside
    a fenced block; the section runs to the next heading or end of text.
    """
    lines = lines_of(text)
    body_start, first = 0, 0
    if lines and lines[0][2].strip() == "---":
        body_start, first = len(text), len(lines)
        for i in range(1, len(lines)):
            if lines[i][2].strip() == "---":
                body_start, first = lines[i][1], i + 1
                break
    sections, fenced = [], False
    for start, end, line in lines[first:]:
        if is_fence(line):
            fenced = not fenced
        elif not fenced and line.startswith("## "):
            if sections:
                sections[-1][3] = start
            sections.append([line[3:].rstrip(" \t"), start, end, len(text)])
    return body_start, [tuple(s) for s in sections]


# --- rendering ---------------------------------------------------------------

def render_text(raw):
    """Escape raw text, then turn links, bare URLs and **bold** into markup."""
    out, pos = [], 0
    for m in TOKEN_RE.finditer(raw):
        out.append(esc(raw[pos:m.start()]))
        label, target, bare, bold = m.groups()
        if bare:
            url = bare.rstrip(".,;")
            out.append(f'<a href="{esc(url)}">{esc(url)}</a>{esc(bare[len(url):])}')
        elif bold:
            out.append(f"<strong>{render_text(bold)}</strong>")
        elif safe_href(target):
            out.append(f'<a href="{esc(target)}">{esc(label)}</a>')
        else:
            out.append(esc(m.group(0)))
        pos = m.end()
    out.append(esc(raw[pos:]))
    return "".join(out)


def render_inline(raw):
    """Inline code first, so nothing inside backticks becomes markup."""
    parts = re.split(r"`([^`\n]+)`", raw)
    return "".join(f"<code>{esc(p)}</code>" if i % 2 else render_text(p)
                   for i, p in enumerate(parts))


def render_markdown(md):
    """The todo-body markdown subset (spec R2.2) as HTML; all text escaped."""
    out, para, items = [], [], []

    def flush_para():
        if para:
            out.append(f"<p>{render_inline(' '.join(para))}</p>")
            para.clear()

    def flush_list():
        if items:
            lis = "".join(
                f'<li class="d{depth}">'
                + (f'<span class="num">{esc(num)}</span> ' if num else "")
                + f"{render_inline(text)}</li>"
                for depth, num, text in items)
            out.append(f'<ul class="md">{lis}</ul>')
            items.clear()

    lines = md.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        if is_fence(line) or line.startswith("|"):
            flush_para()
            flush_list()
            if is_fence(line):
                j = i + 1
                while j < len(lines) and not lines[j].startswith(line[:3]):
                    j += 1
                block, i = lines[i + 1:j], j + 1
            else:
                j = i
                while j < len(lines) and lines[j].startswith("|"):
                    j += 1
                block, i = lines[i:j], j
            out.append("<pre>" + esc("\n".join(block)) + "</pre>")
            continue
        item = LIST_ITEM_RE.match(line)
        sub = SUBHEAD_RE.match(line)
        if not line.strip():
            flush_para()
            flush_list()
        elif sub:
            flush_para()
            flush_list()
            out.append(f"<h5>{render_inline(sub.group(1))}</h5>")
        elif item:
            flush_para()
            indent, marker, text = item.groups()
            num = marker if marker[0].isdigit() else ""
            items.append([min(len(indent) // 2, 3), num, text])
        elif items and line.startswith(" "):
            items[-1][2] += " " + line.strip()
        else:
            flush_list()
            para.append(line.strip())
        i += 1
    flush_para()
    flush_list()
    return "".join(out)


def render_body(text, after_section=None):
    """The rendered body: preamble, then every section under an <h4>.

    after_section(name) -> HTML placed after the LAST section of that name.
    """
    body_start, sections = split_sections(text)
    first = sections[0][1] if sections else len(text)
    parts = [render_markdown(text[body_start:first])]
    last = {s[0]: k for k, s in enumerate(sections)}
    for k, (name, _, head_end, end) in enumerate(sections):
        parts.append(f"<h4>{esc(name)}</h4>" + render_markdown(text[head_end:end]))
        if after_section is not None and last[name] == k:
            parts.append(after_section(name))
    return "".join(parts)


# --- appending a note --------------------------------------------------------

def check_note(note):
    """-> the note without trailing LFs, or raise NoteRefused (spec R4.1-R4.2)."""
    note = note.rstrip("\n")
    if not note.strip():
        raise NoteRefused("empty note")
    for n, line in enumerate(note.split("\n"), 1):
        for ch in line:
            if ch != "\t" and not " " <= ch <= "~":
                raise NoteRefused(f"line {n}: character U+{ord(ch):04X} is not allowed "
                                  "(printable ASCII, tab and newline only)")
        if NOTE_HEADING_RE.match(line):
            raise NoteRefused(f"line {n}: a note cannot contain a heading")
        if is_fence(line):
            raise NoteRefused(f"line {n}: a note cannot contain a code fence")
    if len(note.encode("utf-8")) > MAX_NOTE_BYTES:
        raise NoteRefused(f"note is longer than {MAX_NOTE_BYTES} bytes")
    return note


def append_note(text, section, note):
    """-> text with `\\n<note>\\n` after the last content line of the LAST
    `## <section>`; raise NoteRefused when it cannot (spec R4.3-R4.4)."""
    if section not in NOTE_SECTIONS:
        raise NoteRefused(f"section must be one of {', '.join(NOTE_SECTIONS)}")
    note = check_note(note)
    if "\r" in text:
        raise NoteRefused("the todo file has CR line endings")
    if not text.endswith("\n"):
        raise NoteRefused("the todo file does not end with a newline")
    matches = [s for s in split_sections(text)[1] if s[0] == section]
    if not matches:
        raise NoteRefused(f"the todo has no '## {section}' section")
    _, _, head_end, end = matches[-1]
    at = head_end
    for _, line_end, line in lines_of(text[head_end:end]):
        if line.strip():
            at = head_end + line_end
    return text[:at] + "\n" + note + "\n" + text[at:]


def write_atomic(path, data):
    """Replace path with data via a git-ignored sibling temp file (spec R4.5)."""
    folder, name = os.path.split(os.path.abspath(path))
    tmp = os.path.join(folder, f".{name}.tmp.{os.getpid()}")
    mode = os.stat(path).st_mode & 0o7777
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def refuse(msg, code=REFUSED):
    print(f"todos: note: {msg}", file=sys.stderr)
    return code


def cmd_append(argv):
    if len(argv) not in (2, 4) or (len(argv) == 4 and argv[2] != "--expect-sha"):
        return refuse("usage: todos.sh note <exact-id> <Problem|Solution|Verification> [--expect-sha HEX]")
    path, section = argv[0], argv[1]
    expect = argv[3] if len(argv) == 4 else None
    if expect is not None and not SHA_RE.match(expect):
        return refuse("--expect-sha needs 64 lowercase hex digits")
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return refuse(f"cannot read {path}: {e.strerror}", 1)
    if expect is not None and hashlib.sha256(data).hexdigest() != expect:
        return refuse("the todo changed on disk since the page loaded it; "
                      "reload and add the note again", STALE)
    try:
        note = sys.stdin.buffer.read().decode("utf-8")
    except UnicodeDecodeError:
        return refuse("the note is not valid UTF-8")
    try:
        new = append_note(data.decode("utf-8"), section, note)
    except UnicodeDecodeError:
        return refuse("the todo file is not valid UTF-8")
    except NoteRefused as e:
        return refuse(str(e))
    try:
        write_atomic(path, new.encode("utf-8"))
    except OSError as e:
        return refuse(f"cannot write {path}: {e.strerror or e}", 1)
    return 0


def main(argv):
    if argv[:1] == ["append"]:
        return cmd_append(argv[1:])
    return refuse("usage: todos_prd.py append <file> <section> [--expect-sha HEX]")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
