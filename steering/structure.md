# Project Structure — stage-aware-compaction

## Directory Layout
```
stage-aware-compaction/
├── src/                  # TypeScript source (this repo — the plugin itself)
│   ├── index.ts          # Plugin entry point; exports the Plugin function
│   ├── stage-detector.ts # Reads SESSION.md / todo / spec to determine task stage
│   ├── strategy.ts       # Maps stages to compaction retention policies
│   └── config.ts         # Reads + validates the opencode.json plugin config block
├── tests/                # Unit and integration tests (vitest)
├── steering/             # Product, tech, and structure steering docs (this file)
├── .codex/               # Specs, templates, scripts, ralph-audit loop
├── .opencode/
│   └── plugins/          # Symlink or copy of built plugin for local dogfooding
├── package.json          # devDependencies only (vitest, eslint, prettier, tsup)
├── tsconfig.json
├── AGENTS.md             # Repo-level agent instructions
└── SESSION.md            # Active session state
```

Note: end-users of the plugin place the `.ts` file (or install via npm) into their
own project's `.opencode/plugins/` directory. This repo is the development workspace
for that plugin file.

## Naming Conventions
- **Files**: `kebab-case.ts` for source, matching the exported module's primary concept.
- **Classes / interfaces**: `PascalCase`.
- **Functions / variables**: `camelCase`.
- **Constants**: `SCREAMING_SNAKE_CASE` for true compile-time constants; `camelCase` for
  runtime config values.
- **Test files**: co-located with source or under `tests/`; suffix `.test.ts`.

## Module / Package Boundaries
- `src/index.ts` is the **only** module that imports from OpenCode's hook API;
  everything else is pure logic with no external dependencies.
- `stage-detector.ts` may read the filesystem; it must **not** write.
- `strategy.ts` is a pure function module — no I/O, no side effects.
- `config.ts` validates at startup and throws if the config is invalid; it is
  called once and the result is passed down via function arguments (no global state).
- Tests must not touch the real filesystem; use in-memory stubs/fakes.

## Quality Standards
- TypeScript strict mode (`"strict": true` in `tsconfig.json`).
- Coverage target: ≥80% for all touched modules.
- Lint: eslint with `@typescript-eslint/recommended` rule set.
- Format: prettier (defaults; enforced via `prettier --check` in CI).
- All public functions must have JSDoc comments describing parameters and return value.
- No `any` except in test stubs; document with `// eslint-disable-next-line @typescript-eslint/no-explicit-any` + rationale.
