# Technical Architecture — stage-aware-compaction

## Stack
- **Language**: TypeScript (strict mode)
- **Runtime**: Bun (OpenCode's native runtime; plugins run inside the OpenCode process)
- **Plugin surface**: OpenCode plugin hook API — `@opencode-ai/plugin` for types
- **Hook**: `experimental.session.compacting` (fires before the LLM generates a
  continuation summary; can push to `output.context` or replace `output.prompt`)
- **Plugin location**: `.opencode/plugins/stage-aware-compaction.ts` in the user's project
- **Config format**: JSON — plugin config block lives in the user's `opencode.json`
- **Workflow vocabulary source**: `AGENTS.md` and `skills/` (read-only at runtime)
- **Build tooling**: tsup (bundles to a distributable if published to npm; local use
  is loaded directly by OpenCode's Bun runtime without a build step)
- **Test framework**: vitest
- **Lint / format**: eslint (`@typescript-eslint/recommended`) + prettier

## Architecture Overview
The plugin is a TypeScript module loaded by OpenCode from `.opencode/plugins/` in
the user's project (or globally from `~/.config/opencode/plugins/`). It exports a
single `Plugin` function that registers the `experimental.session.compacting` hook.

At each compaction event, the hook:

1. **Reads stage context** — inspects `SESSION.md`, active todo list, and any
   open spec file (via filesystem reads using Bun APIs) to determine the current
   task stage.
2. **Selects a compaction strategy** — maps the detected stage to a configured
   retention policy (what to keep verbatim, what to summarise, what to drop).
3. **Emits a compaction hint** — either pushes structured markdown sections to
   `output.context` (to augment the default prompt) or replaces `output.prompt`
   entirely for custom compaction behaviour.

Boundaries:
- Plugin code **reads** project files (`SESSION.md`, `.codex/specs/`, `AGENTS.md`)
  but never writes them.
- All configuration (retention policies, stage detection rules) lives in
  the user's `opencode.json` under a plugin-namespaced key.
- No network calls; entirely local.
- The plugin does not spawn subprocesses; it uses Bun's native file APIs.

## Key Decisions
- **TypeScript over JavaScript**: type safety on the hook API contracts catches
  mismatches early; OpenCode itself is TypeScript.
- **Plugin loaded from `.opencode/plugins/`**: zero install friction for users —
  drop the file in, no npm install required for the plugin itself.
- **`@opencode-ai/plugin` types**: import `Plugin` type for full type safety on
  the hook signature without a runtime dependency.
- **JSON config in `opencode.json`**: keeps the plugin zero-dependency for users
  and co-locates config with the tool it extends.
- **AGENTS.md / skills as vocabulary source, not implementation**: the plugin
  reads these files for stage signals but does not execute or interpret them as
  code — this keeps the blast radius small.
- **`output.context` over `output.prompt`**: prefer pushing to `output.context`
  to layer on top of OpenCode's default compaction; only replace `output.prompt`
  for fully custom compaction strategies, since replacing it discards the context array.

## Performance Requirements
- Hook execution must complete quickly to avoid blocking OpenCode's compaction path.
  Target: filesystem reads only (SESSION.md + one spec file); no network, no subprocess.
- Must not hold open file handles or accumulate memory across hook calls.

## Security Requirements
- Read-only filesystem access (project files only; no home-dir or system paths
  outside the project root).
- No network egress.
- No eval or dynamic code execution of user-provided content.

## Constraints
- Targets the OpenCode `experimental.session.compacting` hook API (current as of
  OpenCode 2026-03-09 release).
- Runtime is Bun (version bundled with OpenCode); no separate Node.js installation
  required by users.
- Must not introduce transitive dependencies that require native compilation.
- Plugin is distributed as a TypeScript source file, not a compiled bundle — Bun
  transpiles it at load time.
