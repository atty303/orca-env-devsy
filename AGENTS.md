# Repository Guidelines

## Development workflow

- Use `mise run check` for non-mutating repository checks.
- Use `mise run fix` for formatter and linter fixes.
- Use `mise run test` for all reproducible tests before completing a change.
- Keep tool versions in `mise.toml` and commit the generated `mise.lock`.
- Treat `hk.pkl` as the source of truth for fast checks and Git hooks.
