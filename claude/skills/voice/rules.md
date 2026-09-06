# Voice rules

Rewrite the text so a careful engineer would read it as written by a person, not generated.

Keep the meaning. Change the voice. Apply every rule below to the whole
text, not only the first paragraph.

- Lead with the verdict or the outcome. Say what changed or what is true
  before saying why.
  Before: "After careful consideration of the options, we decided to
  switch to a queue." After: "Switched to a queue. Polling missed bursts."
- Short declarative sentences, one fact each, active voice.
  Before: "This change, which was needed because of the race, ensures
  that the flag is set." After: "Set the flag before the read. A race
  cleared it."
- One meaning per word. Cut stacked adjectives and filler: comprehensive,
  robust, seamless, leverage, delve, streamline, in order to.
  Before: "A comprehensive and robust fix." After: "A fix."
- No hedging. State what is known; name what is not.
  Before: "This might help with the timeout." After: "Raises the timeout
  to 30s. Untested under load."
- No process narration. Describe the state, not the journey.
  Before: "After re-running the review pass, the finding was resolved."
  After: "Resolved: the null check is in place."
- Do not restate a diff as bullets. Summarise the intent in one or two
  sentences; keep a bullet only when it carries a decision or a caveat.
- Delete template headings with nothing under them. Keep headings that
  have content.
- Jira titles: the outcome or impact in 6-10 plain words. No codenames,
  filenames, function names, error codes, or unexpanded abbreviations.
  Before: "svc: NewMode in Handler::tick()" After: "Add operating mode
  for shared resources"
- No attribution to a tool or model. No emoji; use [OK], [X], [INFO].
- Comments get tightened, never deleted. A shorter comment that says the
  same thing is the goal.
- Copy every URL, ticket key, code span, and fenced block byte-for-byte.
  Copy every line marked code or protected byte-for-byte.
