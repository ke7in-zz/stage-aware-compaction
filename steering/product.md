# Product — stage-aware-compaction

## Vision
A custom OpenCode compaction plugin that gives long-running AI coding agent sessions
better continuity across compaction boundaries by making the compaction decision
stage-aware rather than purely token-count-driven.

## Goals
1. Preserve task-critical context (active spec, current todo list, open blockers)
   across compaction events without manual intervention.
2. Reduce the frequency of agent "amnesia" — where a compacted session loses
   thread and repeats work already done.
3. Integrate seamlessly as an OpenCode plugin (`.opencode/plugins/` drop-in) with
   zero changes to the user's normal workflow.
4. Stay composable: the plugin layers on top of OpenCode's `experimental.session.compacting`
   hook, augmenting rather than replacing the default compaction behaviour.
5. Measurable success: after a compaction event, the agent correctly resumes the
   active task (correct next step, no repeated tool calls) in ≥90% of observed sessions.

## Target Users
OpenCode power users running long, multi-session agentic tasks (spec execution,
large refactors, multi-file features) who hit compaction boundaries frequently
and need the agent to resume coherently.

Key needs:
- The agent must "remember" where it was mid-task after compaction.
- Minimal setup — one config block in `opencode.json`.
- Works within the AGENTS.md / skills / SESSION.md workflow vocabulary.

## Non-goals
- Not a general-purpose memory or RAG system.
- Not a replacement for OpenCode's native compaction algorithm.
- Not targeting casual / short-session OpenCode users.
- No UI — config-only integration via `opencode.json`.

## Key Constraints
- Must conform to the OpenCode `experimental.session.compacting` hook API
  (`@opencode-ai/plugin` type: `Plugin`).
- Configuration lives in the user's `opencode.json`; no external services or databases.
- Plugin is distributed as a TypeScript source file and loaded directly by Bun
  (OpenCode's runtime); no build step required for users.
- Plugin must be side-effect-free with respect to the user's project files
  (read-only access to `SESSION.md`, `.codex/specs/`, `AGENTS.md`).
- Hook execution must not block compaction for a perceptible duration (no network,
  no subprocess, filesystem reads only).
