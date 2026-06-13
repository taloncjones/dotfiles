# /test - Run project tests

Run tests for the current project. Detect the test framework and run appropriately.

## Instructions

1. Detect the project type by checking for:
   - `pyproject.toml` with pytest -> `uv run pytest`
   - `Cargo.toml` -> `cargo test`
   - `package.json` with test script -> `npm test`

2. If arguments provided, pass them to the test command (e.g., `/test -v` or `/test tests/specific_test.py`)

3. Run from the appropriate directory:
   - For Python projects with `/tool` and `/test` dirs, prefer `/test` directory
   - Otherwise run from project root

4. Report results concisely:
   - On success: "Tests passed (X passed, Y skipped)"
   - On failure: Show failed test names and brief error summary

5. If tests fail, offer to investigate specific failures
