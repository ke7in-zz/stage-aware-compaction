# Project Structure — stage-aware-compaction

## Directory Layout

```
stage-aware-compaction/
├── src/
│   ├── stage-aware-compaction.ts  # Plugin — all logic, all types, all exports (~1650 lines)
│   └── index.ts                   # Re-export barrel (named + default exports)
├── tests/
│   └── stage-aware-compaction.test.ts  # Unit tests (vitest); 9 tests
├── docs/                          # User-facing documentation
│   ├── index.md                   # Quick start and overview
│   ├── how-it-works.md            # Detection logic and two-layer design
│   ├── schema.md                  # All output fields documented
│   ├── operations.md              # Install, verify, troubleshoot
│   └── api-reference.md           # Exported functions and types
├── steering/                      # Architectural and product steering docs (this file)
├── .codex/                        # Specs, templates, scripts, audit loop
├── .opencode/
│   └── plugins/
│       └── stage-aware-compaction.ts  # Re-exports from src/index.js (project-level dogfood)
├── package.json                   # devDependencies only (vitest, eslint, prettier, typescript)
├── tsconfig.json
├── eslint.config.js
├── .prettierignore
├── AGENTS.md                      # Repo-level agent instructions
└── SESSION.md                     # Active session state
```

Note: end-users of the plugin place the `.ts` source file directly into their own
project's `.opencode/plugins/` directory. This repo is the development workspace for
that file. There is no build step and no compiled `dist/` output.

## Architecture

The plugin is a **single self-contained TypeScript file** (`src/stage-aware-compaction.ts`).
All logic lives there: types, constants, helpers, the hook handler, and the exported
functions. `src/index.ts` is a thin re-export barrel.

The earlier multi-file layout described in older steering drafts (with separate
`stage-detector.ts`, `strategy.ts`, `config.ts` modules) was never built. Do not
introduce that split — the single-file layout is deliberate and keeps the plugin easy
to distribute as a drop-in copy.

### Key exported symbols

| Symbol                            | Kind     | Description                                                |
| --------------------------------- | -------- | ---------------------------------------------------------- |
| `StageAwareCompactionPlugin`      | `Plugin` | The OpenCode plugin function (primary export)              |
| `buildHybridState`                | function | Reads filesystem, returns `HybridState`                    |
| `renderHybridContinuationContext` | function | Serialises `HybridState` to Markdown for context injection |
| `buildWorkflowState`              | function | Deprecated: flattens to legacy `WorkflowState`             |
| `renderContinuationContext`       | function | Deprecated: renders legacy `WorkflowState`                 |

See `docs/api-reference.md` for full type signatures.

## Naming Conventions

- **Files**: `kebab-case.ts` for source, matching the exported module's primary concept.
- **Classes / interfaces / types**: `PascalCase`.
- **Functions / variables**: `camelCase`.
- **Constants**: `SCREAMING_SNAKE_CASE` for true compile-time constants; `camelCase` for
  runtime config values.
- **Test files**: under `tests/`; suffix `.test.ts`.

## Module Boundaries

- `src/stage-aware-compaction.ts` contains everything — types, constants, helpers, the
  hook handler, and all exported functions.
- `src/index.ts` re-exports public symbols only; it does not add logic.
- `.opencode/plugins/stage-aware-compaction.ts` re-exports from `src/index.js` for
  local dogfooding; it is not part of the distributable.
- The plugin function receives the OpenCode `client` object; all logging goes through
  `client.app.log()`. No `console.log` in production paths.
- The plugin must **never write** to the user's project files. Filesystem access is
  read-only: `SESSION.md`, `AGENTS.md`, `.codex/specs/`, `.codex/bugs/`.
- Tests must not touch the real filesystem; use in-memory stubs/fakes.

## Quality Standards

- TypeScript strict mode (`"strict": true` in `tsconfig.json`).
- Coverage target: ≥80% for all touched modules.
- Lint: eslint with `@typescript-eslint/recommended` rule set.
- Format: prettier (defaults; enforced via `prettier --check` in CI).
- All public functions must have JSDoc comments describing parameters and return value.
- No `any` except in test stubs; document with
  `// eslint-disable-next-line @typescript-eslint/no-explicit-any` + rationale.
