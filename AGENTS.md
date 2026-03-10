# stage-aware-compaction: Agent Notes

## Start Here

- Confirm branch + destination: `main` is protected — changes must land via a pull request.
- Skim `steering/product.md` and `steering/tech.md` before starting any work.
- Read `SESSION.md` for current state, active locks, and next steps.

## Non-Negotiables (repo-specific)

- **Plugin is a drop-in TypeScript file**, not a compiled bundle. The source in `src/`
  is the distributable. Do not introduce a build step that produces a separate `dist/`
  file that users must reference — users copy (or symlink) the `.ts` file directly.
- **Read-only filesystem access at runtime.** The plugin reads `SESSION.md`,
  `.codex/specs/`, `AGENTS.md` — it must never write to the user's project files.
- **No network egress in the plugin.** Hook execution must remain local and fast
  (filesystem reads only; no subprocess, no fetch).
- **No global state in the plugin module.** The plugin function is called once per
  OpenCode session; do not cache state in module-level variables that persist across
  multiple hook invocations in the same process.
- **`@opencode-ai/plugin` for types only** — import as `import type`, never as a
  runtime import that would create a dependency users must install.

## Validation Gates (minimum before "done")

```bash
# Type-check (no emit)
npx tsc --noEmit

# Lint
npx eslint src/ tests/

# Format check
npx prettier --check .

# Tests
npx vitest run
```

Coverage target: ≥80% for touched modules.

## Environment / Local-Only Files (avoid committing)

- `.env` — not expected, but guard against it
- `node_modules/` — devDependencies only; not part of the plugin distribution
- `.DS_Store`
- `dist/` — if a build step is ever added, keep generated outputs out of git
- `.opencode/` — local dogfooding config; not part of the plugin source

## References

- Steering: `steering/product.md`, `steering/tech.md`, `steering/structure.md`
- OpenCode plugin docs: https://opencode.ai/docs/plugins/
- OpenCode plugin hook API: `experimental.session.compacting`
- Specs: `.codex/specs/`
- Session: `SESSION.md`
