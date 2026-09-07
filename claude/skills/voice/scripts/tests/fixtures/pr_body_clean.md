## Description

Adds a voice pass that rewrites PR and Jira text before it is posted. The pass runs Codex as a second model and never posts on its own.

## Test plan

- Fixture suite passes on macOS and Linux.
- Dry-run prints the prompt without calling Codex.

[DOT-42](https://example.atlassian.net/browse/DOT-42)
