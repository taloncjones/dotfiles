# /lint - Run linters and formatters

Run linting and formatting for the current project with auto-fix enabled.

## Instructions

1. Detect project type and run appropriate linters:

   **Python** (if `pyproject.toml` exists):
   ```bash
   uv run ruff check --fix .
   uv run ruff format .
   ```

   **Rust** (if `Cargo.toml` exists):
   ```bash
   cargo fmt
   cargo clippy --fix --allow-dirty
   ```

   **JavaScript/TypeScript** (if `package.json` exists):
   ```bash
   npm run lint --fix  # or eslint --fix
   ```

2. Run from project root unless in a subdirectory with its own config

3. Report results:
   - Files modified by formatter
   - Remaining warnings/errors that couldn't be auto-fixed

4. If unfixable issues remain, briefly explain what needs manual attention
