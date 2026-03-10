# stage-aware-compaction

Layer 2 context management for OpenCode: a minimal compaction plugin that keeps
workflow-critical state intact when a session is compacted.

## What this implements

- A local plugin at `.opencode/plugins/stage-aware-compaction.ts`
- A single production-oriented source file at `src/stage-aware-compaction.ts`
- The `experimental.session.compacting` hook
- Structured continuation context for the canonical spec and bug workflows

This is intentionally narrow:

- no persistent memory files beyond the workflow artifacts that already exist
- no vector store, database, or external context service
- no prompt replacement unless needed later

## Hook strategy

This plugin uses **inject-only** via `output.context.push(...)`.

Why:

- It preserves OpenCode's default compaction prompt and only adds workflow state.
- It is safer against experimental API changes than replacing `output.prompt`.
- It keeps the change small and reversible.

Prompt replacement was not used because the current problem is missing
workflow-critical continuity, not a failure of the entire base compaction prompt.

## Workflow inspection and schema design

The schema was derived from the repo workflow docs plus the canonical skills in
`~/.config/opencode/skills`:

- Spec workflow: `spec-create` -> `spec-design` -> `spec-tasks` -> `spec-execute`
- Bug workflow: `bug-create` -> `bug-analyze` -> `bug-fix` -> `bug-verify`

The implementation preserves those exact stage names in the continuation output.
It also preserves workflow-specific semantics from the skills:

- approval gates between spec artifacts and bug artifacts
- `context.md` as the carry-forward file for `spec-execute`
- `tasks.md` checkbox progress for spec execution
- `report.md`, `analysis.md`, and `verification.md` as bug artifacts
- harness-driven transition rules like `.codex/scripts/harness.sh spec gate <spec-name> <task-id>`

## Continuation schema

The compaction context is always rendered in the same order:

- `## Workflow Type`
- `## Canonical Workflow Stage`
- `## Source Artifacts`
- `## Current Artifact`
- `## Artifact Status`
- `## Transition Gate`
- `## Primary Objective`
- `## Current Step`
- `## Status`
- `## Completed`
- `## Remaining`
- `## Decisions`
- `## Approved Decisions`
- `## Pending Decisions / Open Questions`
- `## Dependencies / Preconditions`
- `## Active Files`
- `## Blockers / Risks`
- `## Verification / Done Criteria`
- `## Next Action`

The goal is compact, resume-oriented signal rather than transcript replay.

## Sample continuation output — spec workflow

```md
## Stage-Aware Continuation

Preserve the canonical workflow names exactly. Treat this as the authoritative resume brief for compaction continuity.

## Workflow Type

- spec

## Canonical Workflow Stage

- spec-execute

## Source Artifacts

- .codex/specs/001-prd-compaction/requirements.md
- .codex/specs/001-prd-compaction/design.md
- .codex/specs/001-prd-compaction/tasks.md
- .codex/specs/001-prd-compaction/context.md

## Current Artifact

- .codex/specs/001-prd-compaction/tasks.md

## Artifact Status

- 001-prd-compaction: 1 task(s) complete, 2 remaining; next task is 2 — Build continuation context (Batch 1 — Foundation).

## Next Action

- Resume 001-prd-compaction in spec-execute: 2 — Build continuation context (Batch 1 — Foundation).
```

## Sample continuation output — bug workflow

```md
## Stage-Aware Continuation

Preserve the canonical workflow names exactly. Treat this as the authoritative resume brief for compaction continuity.

## Workflow Type

- bug

## Canonical Workflow Stage

- bug-fix

## Source Artifacts

- .codex/bugs/session-resume-regression/report.md
- .codex/bugs/session-resume-regression/analysis.md
- .codex/bugs/session-resume-regression/harness/progress.md

## Current Artifact

- .codex/bugs/session-resume-regression/analysis.md

## Artifact Status

- session-resume-regression: bug-fix approved; implement fix and add regression coverage

## Next Action

- Implement the approved minimal fix for session-resume-regression, add regression coverage, and prepare the hand-off to bug-verify.
```

## Tuning later

The current implementation is intentionally simple:

- detection relies on `SESSION.md` plus existing `.codex/specs/` and `.codex/bugs/` artifacts
- stage inference falls back to artifact presence and content when the session log is ambiguous
- workflow semantics are isolated in `SPEC_STAGE_DETAILS` and `BUG_STAGE_DETAILS`

That makes future changes easy:

- adjust stage inference rules in one file
- add more artifact parsing without changing the hook boundary
- switch to prompt replacement later if inject-only proves insufficient

## Where Layer 3 would fit later

Layer 3 can be added later by introducing a separate source of durable execution
memory and plugging it into the same state builder before rendering the
continuation schema.

That is intentionally not implemented here.

## Validation scenarios

Automated tests cover two realistic compaction scenarios:

1. Spec execution with a live `tasks.md` + `context.md`
2. Bug fixing with an approved `analysis.md` + harness progress note

Run:

```bash
npm test
```

Recommended manual validation in OpenCode:

1. Create a spec artifact under `.codex/specs/<spec-name>/` with `tasks.md` and `context.md`.
2. Start work in `spec-execute`, force compaction, and confirm the continuation preserves `spec-execute`, the next task, active files, and next action.
3. Create a bug artifact under `.codex/bugs/<bug-name>/` with `report.md` and `analysis.md`.
4. Start work in `bug-fix`, force compaction, and confirm the continuation preserves `bug-fix`, the current artifact, validation intent, and hand-off to `bug-verify`.
