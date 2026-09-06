# Spec: Codex voice pass that de-generifies PR, Jira, and comment text

Date: 2026-09-06
Branch: talon/td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira/voice-pass
Source task: td-2026-09-05-add-a-codex-voice-pass-that-de-generifies-pr-jira

## Problem

Outward-facing text written by agents reads as generated: stacked
adjectives, "comprehensive" and "robust", bulleted restatements of the
diff, hedging, template headings with nothing under them. The style
rules already exist (`claude/CLAUDE.md` Response Style, the Jira title
rules, no attribution, no emojis) but nothing checks text against them
before it is posted, and the model that wrote the text is a poor judge
of its own voice. PR titles and bodies, Jira titles, descriptions, and
resolution comments, and code comments and docstrings all go out
unchecked.

## Goal

A second-model voice pass, run by Codex, packaged as a new
self-contained skill `voice` under `claude/skills/voice/`. Given a text
blob or a target (PR number, file line range) it returns a rewrite plus
a short list of what changed and why, applying the CLAUDE.md style
rules. It never posts. Every posting path gets a documented call site
that runs the pass and shows before/after for human approval; wiring
those call sites is a follow-up, not this task.

## Non-goals

- No edits to `ship`, `pr`, `jira`, `post-merge`, `co-review`,
  `codex-plan-review`, `codex-spec-review`, `codex/AGENTS.md`, or the
  Codex-side skill mirrors under `codex/skills/`. A parallel branch owns
  the review skills; this task adds one new skill directory and touches
  only the two registration files named below.
- No Jira fetching from the script. Jira access in this setup is MCP
  (`addCommentToJiraIssue` and friends), which a shell script cannot
  call. The skill prose tells Claude to fetch the field and feed it as
  text with the right `--kind`.
- No automatic posting, editing, or committing. The script prints the
  exact follow-up command (`gh pr edit ...`) or the MCP call to make;
  the human runs it.
- No rewrite of the model's reasoning about voice into regex. The
  deterministic layer catches mechanical violations only; judgment
  stays with Codex.
- No Codex-side (`codex/skills/`) mirror of this skill.

## Confirmed facts

- Codex model and effort, read from `~/.codex/config.toml` on
  2026-09-06: `model = "gpt-6-astra"`, `model_reasoning_effort =
  "xhigh"`. The pass pins `-m gpt-6-astra` and `-c
  model_reasoning_effort="high"` by default; `xhigh` is opt-in via
  `--effort xhigh`. Rationale: a rewrite of a few hundred words is not
  a deep-reasoning task, and this pass sits in front of every outward
  post, so latency matters more than the last increment of care.
- `codex exec` (help output, 2026-09-06) supports `-m`, `-c`, `-C`,
  `--skip-git-repo-check`, `--ephemeral`, `--output-schema <FILE>`,
  `-o <FILE>` (last message to file), `--json`, and reads the prompt
  from stdin when the argument is `-`.
- The repo's existing Codex skills warn that a generic `codex exec
  "<prompt>"` run inside this repo loads `AGENTS.md` and can recurse
  into a Claude shell-out. This pass runs in an empty scratch directory
  (`-C`, `--skip-git-repo-check`, `--ephemeral`, read-only sandbox,
  approvals never) with a prompt that mentions no review, skill, or
  tool, so there is nothing to recurse into. Live confirmation is a
  human-verify item (see Verification).

## Design

### Layout

```
claude/skills/voice/
  SKILL.md                      skill prose: triggers, usage, call sites
  rules.md                      the voice rubric sent verbatim to Codex
  scripts/voice.py              stdlib Python 3, the whole tool
  scripts/tests/voice_test.sh   bash suite, PASS/FAIL convention
  scripts/tests/fake_codex.sh   deterministic stand-in for codex exec
  scripts/tests/fake_gh.sh      records calls, serves canned PR JSON
  scripts/tests/fixtures/       inputs and expected outputs (below)
```

Registration: `!/voice/` in `claude/skills/.gitignore`; `bash
claude/skills/voice/scripts/tests/voice_test.sh` in the `SUITES` list
of `bin/dotfiles-tests`.

### Command surface (`voice.py`)

```
voice.py lint    --kind <kind> [--file F | --stdin]
voice.py rewrite --kind <kind> [--file F | --stdin | --pr N | --range F:A-B]
                 [--effort high|xhigh] [--dry-run] [--json]
```

Kinds and their per-kind rule addenda (table-driven, one row each):

| kind             | addendum                                                   |
|------------------|------------------------------------------------------------|
| pr-title         | `<scope>: <summary>`, imperative, under 75 chars           |
| pr-body          | keep Description and Test plan sections; keep Jira link line verbatim at the bottom |
| pr-comment       | front-loaded verdict; no process narration                 |
| jira-title       | outcome or impact, 6-10 words, no codenames, filenames, function names, error codes, or unexpanded abbreviations |
| jira-description | short declaratives, one meaning per word, no template headings with nothing under them |
| jira-comment     | current state first; no process narration                  |
| code-comment     | tighten, never delete; keep every line that is protected (below) byte-identical |

Exit codes are shared by both subcommands: `0` nothing to change, `1`
findings or a rewrite proposed, `2` error (bad input, Codex failure,
invariant violated). `--dry-run` prints the assembled prompt and exits
`0` without invoking Codex.

### Layer 1: deterministic lint (no model)

`lint` applies a fixed table of mechanical checks to the input and
prints one finding per line as `<rule>: <evidence>`. Rules:

- `emoji`: any code point in the emoji ranges, or the emoji variation
  selector.
- `attribution`: case-insensitive match on the generated-by,
  generated-with, and co-author trailer forms when they name an AI
  assistant or vendor, plus the "written by AI" and "AI-generated"
  phrasings. The exact pattern list lives in the script as one table.
- `filler`: a word from a fixed list (`comprehensive`, `robust`,
  `seamless`, `leverage`, `delve`, `streamline`, `ensure` as a verb
  opener, `it is worth noting`, `in order to`).
- `empty-heading`: a markdown heading followed by another heading or
  end of text with no body.
- `hedge`: `might`, `may want to`, `it seems`, `should probably`.
- `title-shape` (jira-title only): more than 12 words, or fewer than
  4; contains a filename (`\w+\.(py|sh|rs|md|json|yml|yaml|toml|js|ts)`),
  a function call (`\w+\(\)`), a snake_case or `::` identifier, a hex
  or `E\d{3,}` style code.
- `title-shape` (pr-title only): missing `<scope>: ` prefix, or 75 or
  more characters.

`lint` is the layer the fixture tests and the verification contract
exercise fully. It is also what `rewrite` runs first, so the report can
say which mechanical rules the input tripped even before Codex speaks.

### Layer 2: Codex rewrite

`rewrite` assembles one prompt: the contents of `rules.md`, the
per-kind addendum, the invariants list, then the text under an `===
TEXT ===` delimiter. It invokes:

```
codex exec - -m gpt-6-astra -c model_reasoning_effort="<effort>" \
  -c approval_policy="never" -c sandbox_mode="read-only" \
  -C "$SCRATCH" --skip-git-repo-check --ephemeral \
  --output-schema "$SCHEMA" -o "$LAST" < "$PROMPT" > "$LOG" 2>&1
```

`$SCRATCH` is an empty temp directory; `$SCHEMA` is a JSON Schema
written by the script requiring `{"rewritten": string, "changes":
[{"before": string, "after": string, "rule": string}], "unchanged":
bool}`. The binary comes from `VOICE_CODEX_BIN` (default `codex`); this
is the test seam.

After the call the script:

1. Parses `$LAST` as JSON against the schema; a parse failure is exit
   `2` with the log path on stderr.
2. Runs the invariant check: every fenced code block, inline code span,
   URL, Jira key (`[A-Z]+-[0-9]+`), and the Jira link line from the
   input must appear byte-identical in `rewritten`. A miss is exit `2`
   with `invariant violated: <what>`; the rewrite is not shown as a
   candidate.
3. If `rewritten` equals the input after trailing-whitespace
   normalisation, reports `unchanged` and exits `0`, regardless of the
   `unchanged` flag the model set.
4. Otherwise prints the report and exits `1`.

Report shape (plain text; `--json` emits the same fields as one
object):

```
VOICE <kind> <target>: <n> changes
--- before
+++ after
<unified diff>
Changes:
  1. <rule>: "<before>" -> "<after>"
Protected (left alone):
  <file>:<line>  <reason>
Apply with:
  <exact gh pr edit / MCP call, or "paste the after block">
```

### Targets

- `--stdin` / `--file F`: the whole text is the unit.
- `--pr N`: `gh pr view N --json title,body` (binary from
  `VOICE_GH_BIN`, default `gh`). Title runs as `pr-title`, body as
  `pr-body`, two reports. The script never calls `gh pr edit`; it
  prints the command with the rewritten text for the human.
- `--range F:A-B` with `--kind code-comment`: lines A through B of
  file F are the unit. Only comment lines (`#`, `//`, `/* */`, and
  docstring bodies) are candidates; code lines are passed through as
  protected. Before the prompt is built, each candidate line is
  classified:
  - `protected: referenced elsewhere` when the stripped line text (at
    least 12 characters) occurs verbatim anywhere else in the
    repository tree (fixed-string search from `git rev-parse
    --show-toplevel`, excluding the file itself and `.git`).
  - `protected: docstring displayed` when the line is inside a
    docstring and the tree references the enclosing definition's name
    with `__doc__`, `getdoc(`, or `.doc` (fixed-string search on
    `<name>.__doc__`, `getdoc(<name>` and `<name>.doc`).
  - `candidate` otherwise.
  Protected lines are sent to Codex marked as such and re-verified
  byte-identical on return; a change to one is an invariant violation
  (exit `2`). This is the Code Cleanup rule made mechanical: grep
  first, leave load-bearing strings alone.

### Skill prose (`SKILL.md`)

Triggers: "voice pass", "de-generify this", "make this sound human",
"check this PR body", and any time the agent is about to post outward
text. Steps: pick the kind, get the text (for Jira, fetch the field
via MCP and pipe it in), run `rewrite`, show the report, ask for
approval, then apply with the printed command. Never apply without a
yes. When the pass returns `unchanged`, say so in one line and post.

A "Call sites" section lists where the pass belongs and what each
feeds it, as the integration contract for the follow-up wiring task:

| call site                                  | kind(s)                    | text fed                          |
|--------------------------------------------|----------------------------|-----------------------------------|
| `claude/commands/pr.md` before `gh pr create` | pr-title, pr-body      | the title and heredoc body        |
| `claude/commands/jira.md` `comment`         | jira-comment               | the comment text                  |
| `claude/skills/ship/SKILL.md` step 4 summary and any PR comment it posts | pr-comment | the comment body |
| `claude/skills/post-merge/SKILL.md` step 4  | jira-comment               | the resolution comment            |
| Herdr reviewer brief findings summary (`co-review` report comment) | pr-comment | the findings summary |
| Jira ticket creation (`/start`, `reconcile` backfill) | jira-title, jira-description | summary and description |

Each row is one future edit: insert "run `voice rewrite --kind <k>`,
show before/after, wait for approval" before the outward write.

### `rules.md`

The rubric, as prose Codex reads verbatim. Content is the CLAUDE.md
Response Style and Jira title rules restated for a rewriter:
front-loaded verdict; short declaratives, one fact each; one meaning
per word; cut stacked adjectives and filler; no hedging; no process
narration; no restating the diff as bullets; no empty template
headings; Jira titles state the outcome in 6-10 plain words; no
attribution, no emoji; comments get tightened, not deleted; everything
under the invariants list is copied byte-for-byte. Steering is by
positive example (one short before/after pair per rule), not by
"don't" lists, per `claude-prompting.md`.

## Acceptance criteria

- AC1: `lint --kind pr-body` on the generated-sounding fixture PR body
  exits `1` and reports at least `filler` and `empty-heading`.
- AC2: `lint --kind pr-body` on the clean human-written fixture exits
  `0` with no findings.
- AC3: `lint --kind jira-title` on the generated fixture title (over
  12 words, a filename, a function call) exits `1` reporting
  `title-shape`; the clean fixture title exits `0`.
- AC4: `lint` reports `emoji` and `attribution` on the fixture that
  contains both.
- AC5: `rewrite` with the fake Codex on the generated PR body exits
  `1`, prints a non-empty unified diff, and lists at least one change
  with a rule name.
- AC6: `rewrite` with the fake Codex on the clean PR body exits `0`
  and reports `unchanged`.
- AC7: `rewrite` exits `2` with `invariant violated` when the fake
  Codex drops the Jira link line, and the report shows no candidate.
- AC8: `rewrite --kind code-comment --range` on the GUI fixture leaves
  the displayed docstring byte-identical and marks it `protected:
  docstring displayed`, while the sibling `#` comment in the same
  range is rewritten.
- AC9: `rewrite --pr N` with the fake `gh` produces the two reports
  and the fake records no `pr edit` call; the report ends with the
  `gh pr edit` command for the human.
- AC10: `--dry-run` prints a prompt containing the full `rules.md`
  text and the input, exits `0`, and the fake Codex is never invoked.
- AC11: a non-zero fake Codex exit yields exit `2` and a stderr line
  naming the log path.
- AC12: `voice.py` is stdlib-only Python 3, executable, ASCII, no
  emoji, no attribution; the test suite is registered in
  `bin/dotfiles-tests` and `!/voice/` is in `claude/skills/.gitignore`.
- AC13: a live `rewrite` against the real `codex` binary (human
  verify, not in the contract) returns schema-valid JSON and the log
  shows no shell command execution.

## Fixtures

- `pr_body_generated.md`: "This PR introduces a comprehensive and
  robust ..." with an empty `## Notes` heading, a bullet list
  restating file changes, a hedge, and a Jira link line at the bottom.
- `pr_body_clean.md`: a two-paragraph human-written body with a test
  plan and the same Jira link line.
- `jira_title_generated.txt` and `jira_title_clean.txt`.
- `mixed_emoji_attribution.md`: one emoji and one AI co-author
  trailer line. The repo's own no-attribution hooks block writing that
  trailer through Bash, so the test assembles this fixture at run time
  from fragments in a temp directory instead of committing it.
- `gui_repo/widgets.py` (a function with a filler-laden docstring and
  a filler-laden `#` comment above it) and `gui_repo/gui.py` (displays
  `run_check.__doc__`). The test copies this tree into a temp git repo
  so the search is repo-local and deterministic.
- `fake_codex.sh`: reads the prompt from stdin, extracts the `=== TEXT
  ===` block, applies a fixed substitution table (drops `comprehensive
  and robust`, `In order to`, the empty heading), writes the JSON to
  the `-o` path. Env `FAKE_CODEX_MODE=drop-link|fail` produces the
  invariant-violation and failure cases. Writes a marker file so tests
  can assert it was or was not invoked.
- `fake_gh.sh`: serves canned `pr view` JSON; appends every argv to a
  call log.

## Verification

- Contract (deterministic, no network, no machine-state writes): the
  fixture suite; a `--dry-run` smoke against a fixture; `python3 -m
  py_compile` on the script; grep-based checks for the two
  registration lines and for emoji/attribution absence in the new
  files.
- Human-verify: one live `rewrite --kind pr-body --file <fixture>`
  with the real Codex; confirm schema-valid output and no command
  execution in the `--json` event log.

## Risks and open points

- Codex may still load `~/.codex/AGENTS.md` (global) in the scratch
  dir. Its content (no emoji, no attribution) agrees with the rubric;
  accepted.
- The fixed-string "referenced elsewhere" search is a floor, not a
  proof; a docstring shown through reflection by name is caught by the
  `__doc__` search, one shown through a registry lookup is not. The
  report names its evidence so the human can overrule.
- `--output-schema` behaviour with a stdin prompt is confirmed from
  `--help` only; if the live run shows the schema is not enforced, the
  script's own JSON parse and invariant check still gate the result.
