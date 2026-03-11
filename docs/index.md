# stage-aware-compaction — documentation

A hybrid OpenCode compaction plugin. Keeps workflow-critical state intact when a
session is compacted, and provides useful generic continuity for any other
long-running session.

## Quick start

### Install for one project

Copy (or symlink) the plugin source into your project:

```bash
cp path/to/stage-aware-compaction/src/stage-aware-compaction.ts \
   .opencode/plugins/stage-aware-compaction.ts
```

No `opencode.json` changes needed. Files in `.opencode/plugins/` are
auto-loaded by OpenCode at startup.

### Install globally

Copy the plugin source into the global plugin directory:

```bash
mkdir -p ~/.config/opencode/plugins
cp path/to/stage-aware-compaction/src/stage-aware-compaction.ts \
   ~/.config/opencode/plugins/stage-aware-compaction.ts
```

Ensure `~/.config/opencode/package.json` includes the types dependency:

```json
{
  "dependencies": {
    "@opencode-ai/plugin": "1.2.24"
  }
}
```

### Verify it loaded

After starting OpenCode, check the logs:

```bash
grep "stage-aware-compaction" ~/.local/share/opencode/log/*.log
```

You should see a line like:

```
service=plugin path=...stage-aware-compaction.ts loading plugin
```

Then after a compaction event:

```
service=stage-aware-compaction level=info message="compaction context injected" mode=generic
```

## What the plugin does

When OpenCode's context window fills up, it compacts the session — summarising the
conversation so the agent can continue without the full history. Without
intervention, the compaction model can lose track of:

- which task is currently in progress
- which artifacts have been approved
- what the next concrete step is
- whether there are open blockers

This plugin fires the `experimental.session.compacting` hook before the LLM
generates its summary and injects a structured **continuation brief** into the
compaction context. The brief is resume-oriented, not a transcript — it tells the
compaction model what to preserve.

## Two modes

| Mode                   | When                                              | Output                                                                                                                        |
| ---------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **Generic**            | Always                                            | Primary objective, status, completed, remaining, decisions, active files, blockers, next action — extracted from `SESSION.md` |
| **Workflow-augmented** | When a canonical spec or bug workflow is detected | Everything above, plus workflow type, canonical stage, source artifacts, transition gate, approvals, verification criteria    |

Generic mode works for any session — ad hoc coding, refactors, research,
exploratory debugging, multi-step implementation. Workflow mode layered on top
for the canonical spec and bug workflows.

## Document map

| Document                             | Read this to...                                                 |
| ------------------------------------ | --------------------------------------------------------------- |
| [how-it-works.md](how-it-works.md)   | Understand detection logic, the two-layer design, and data flow |
| [schema.md](schema.md)               | See every output field, when it appears, and what it signals    |
| [operations.md](operations.md)       | Install, deploy, verify loading, read logs, troubleshoot        |
| [api-reference.md](api-reference.md) | Use or extend the exported functions and types                  |

## Scope

This is a Layer 2 plugin only:

- no persistent memory files
- no vector store, database, or external context service
- no network calls
- read-only access to `SESSION.md`, `AGENTS.md`, `.codex/specs/`, `.codex/bugs/`
- hook execution is filesystem reads only — no subprocess, no network
