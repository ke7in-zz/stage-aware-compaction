# stage-aware-compaction

Layer 2 context management for OpenCode: a hybrid compaction plugin that keeps
workflow-critical state intact when a session is compacted, while also providing
useful generic continuity for any long-running session.

## What this implements

- A local plugin at `.opencode/plugins/stage-aware-compaction.ts`
- A single production-oriented source file at `src/stage-aware-compaction.ts`
- The `experimental.session.compacting` hook
- A **hybrid continuation system** with two layers:
  1. **Generic continuity** — always active for any session
  2. **Workflow-aware augmentation** — added when the session matches a canonical
     spec or bug workflow

This is intentionally narrow:

- no persistent memory files beyond the workflow artifacts that already exist
- no vector store, database, or external context service
- no prompt replacement unless needed later

## What changed from the narrow implementation

The original plugin was workflow-specific only. If no canonical spec or bug workflow
was detected, it produced a weak fallback that told the assistant to "go read
SESSION.md" — not useful for generic coding sessions, refactors, research, or
exploratory debugging.

The hybrid enhancement:

1. **Added a generic continuity layer** that parses `SESSION.md` for any session
   and extracts: focus area, open work, completed items, decisions, pending tests,
   blockers, and next action.
2. **Restructured the rendered output** so generic fields come first (always present),
   followed by a `## Workflow-Aware Augmentation` section (only when a canonical
   workflow is clearly detected).
3. **Fixed a pre-existing bug** in `collectBlockers` that treated
   "Blockers: none." as a real blocker.
4. **Preserved all existing workflow-aware behavior** — the spec and bug workflow
   builders, stage detection, artifact scoring, and stage details tables are
   unchanged.

## How generic vs workflow-aware mode is selected

The plugin reads `SESSION.md`, `AGENTS.md`, and the `.codex/specs/` and
`.codex/bugs/` directories at compaction time.

**Workflow detection uses the same logic as before:**

1. Look for the latest canonical stage name mention in `SESSION.md` + `AGENTS.md`
2. If a stage hint is found, look for matching artifact directories
3. If no hint, fall back to artifact directory presence and scoring

**What's new:** when no workflow is detected, the plugin no longer produces a
weak fallback. Instead, it builds a proper generic continuity state from
`SESSION.md` content — focus area, open work, completed items, decisions,
blockers, and next action.

**Detection signals for workflow mode** (unchanged):

- Explicit canonical stage names in `SESSION.md` or `AGENTS.md`
- Known workflow artifact directories under `.codex/specs/` or `.codex/bugs/`
- Artifact file presence: `requirements.md`, `design.md`, `tasks.md`,
  `context.md` for specs; `report.md`, `analysis.md`, `harness/progress.md`
  for bugs

**When workflow mode is NOT activated:**

- No `.codex/specs/` or `.codex/bugs/` artifact directories exist
- No canonical stage name is mentioned in session text
- The session is ad hoc coding, refactoring, research, debugging, or any other
  non-workflow activity

## Hook strategy

This plugin uses **inject-only** via `output.context.push(...)`.

The hook strategy is preserved from the original implementation. The hybrid
enhancement only changes what text is pushed, not the mechanism. Inject-only
remains appropriate because:

- It preserves OpenCode's default compaction prompt and only adds structured state
- It is safer against experimental API changes than replacing `output.prompt`
- The generic continuity layer adds more useful context without needing prompt control
- The change is small and reversible

## Continuation schema

### Generic layer (always present)

- `## Primary Objective`
- `## Current Step`
- `## Status`
- `## Completed`
- `## Remaining`
- `## Decisions`
- `## Active Files`
- `## Blockers / Risks`
- `## Next Action`

### Workflow-aware augmentation (conditional)

When a canonical workflow is detected, a `## Workflow-Aware Augmentation` section
is appended with:

- `## Workflow Type`
- `## Canonical Workflow Stage`
- `## Source Artifacts`
- `## Current Artifact`
- `## Artifact Status`
- `## Transition Gate`
- `## Approved Decisions`
- `## Pending Decisions / Open Questions`
- `## Dependencies / Preconditions`
- `## Verification / Done Criteria`

The goal is compact, resume-oriented signal rather than transcript replay.
Generic sessions get useful continuity without workflow jargon. Workflow sessions
get everything.

## Vocabulary alignment

The canonical workflow stage names are preserved exactly:

- Spec workflow: `spec-create` -> `spec-design` -> `spec-tasks` -> `spec-execute`
- Bug workflow: `bug-create` -> `bug-analyze` -> `bug-fix` -> `bug-verify`

These names appear verbatim in the `## Canonical Workflow Stage` field. They are
not renamed, paraphrased, or normalized.

## Sample continuation output — generic session (refactor)

```md
## Stage-Aware Continuation

Preserve the canonical workflow names exactly. Treat this as the authoritative resume brief for compaction continuity.

## Primary Objective

- Migrate remaining callers of the old `validateSession()` to the new utility.

## Current Step

- Current open work: migrate remaining callers of the old `validateSession()` to the new utility.

## Status

- Active — working on refactor-auth.

## Completed

- Extracted shared token validation into `src/auth/validate.ts`.
- Removed duplicate middleware from `src/routes/api.ts`.

## Remaining

- migrate remaining callers of the old `validateSession()` to the new utility.
- Pending tests: integration tests for the new token validator.

## Decisions

- Decision: keep backward-compatible exports from the old location until v3.

## Active Files

- none recorded

## Blockers / Risks

- none recorded

## Next Action

- migrate remaining callers of the old `validateSession()` to the new utility.
```

## Sample continuation output — spec workflow

```md
## Stage-Aware Continuation

Preserve the canonical workflow names exactly. Treat this as the authoritative resume brief for compaction continuity.

## Primary Objective

- Execute the current approved spec batch with minimal drift, validate it, update `context.md`, and stop with a resumable hand-off.

## Current Step

- Continue the current implementation lane in Batch 1 — Foundation: 2 — Build continuation context (Batch 1 — Foundation).

## Status

- 001-prd-compaction is in spec-execute; 1 task(s) complete and 2 task(s) remaining.

## Completed

- `requirements.md` exists and later-stage artifacts imply the requirements phase is complete.
- `design.md` exists and later-stage artifacts imply design approval was completed.
- `tasks.md` exists and execution has started.
- 1 — Parse SESSION.md (Batch 1 — Foundation)

## Remaining

- 2 — Build continuation context (Batch 1 — Foundation)
- 3 — Add workflow tests (Batch 2 — Validation)

## Decisions

- [Batch 0] Decision: prefer inject-only compaction context — Rationale: preserves default OpenCode prompt behavior.

## Active Files

- .codex/specs/001-prd-compaction/requirements.md
- .codex/specs/001-prd-compaction/design.md
- .codex/specs/001-prd-compaction/tasks.md
- .codex/specs/001-prd-compaction/context.md

## Blockers / Risks

- none recorded

## Next Action

- Resume 001-prd-compaction in spec-execute: 2 — Build continuation context (Batch 1 — Foundation).

---

## Workflow-Aware Augmentation

The following sections apply because this session is part of a canonical workflow. Preserve these fields for workflow continuity.

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

## Transition Gate

- For the current batch: declared task gates pass via `.codex/scripts/harness.sh spec gate <spec-name> <task-id>`, batch validation passes, `/review` feedback is addressed, `context.md` is updated, and the batch stops after commit.

## Approved Decisions

- 001-prd-compaction: approval of `requirements.md` is inferred from the presence of later spec artifacts.
- 001-prd-compaction: approval of `design.md` is inferred from the presence of later spec artifacts.
- 001-prd-compaction: `tasks.md` is treated as approved because execution artifacts are present.

## Verification / Done Criteria

- Task-level validation gates pass for each completed task.
- Batch validation passes before stopping.
- `context.md` records discoveries, decisions, utilities, and carry-forward warnings.
```

## Sample continuation output — bug workflow

```md
## Stage-Aware Continuation

Preserve the canonical workflow names exactly. Treat this as the authoritative resume brief for compaction continuity.

## Primary Objective

- Implement the approved minimal safe fix with regression coverage and no unrelated refactoring.

## Current Step

- Apply the approved changes from `analysis.md`, run format/lint/typecheck/tests, and prepare the hand-off to `bug-verify`.

## Status

- session-resume-regression is in bug-fix; harness progress notes: bug-fix approved; implement fix and add regression coverage

## Completed

- `report.md` exists and the bug is documented well enough to move beyond `bug-create`.
- `analysis.md` exists and later-stage artifacts imply the fix plan was approved.
- bug-fix approved; implement fix and add regression coverage

## Remaining

- Apply the approved changes from `analysis.md`, run format/lint/typecheck/tests, and prepare the hand-off to `bug-verify`.
- Preserve explicit workflow approval semantics around bug-fix.

## Decisions

- Choose the minimal safe fix in the compaction hook without adding persistent memory.

## Active Files

- .codex/bugs/session-resume-regression/report.md
- .codex/bugs/session-resume-regression/analysis.md
- .codex/bugs/session-resume-regression/harness/progress.md

## Blockers / Risks

- none recorded

## Next Action

- Implement the approved minimal fix for session-resume-regression, add regression coverage, and prepare the hand-off to bug-verify.

---

## Workflow-Aware Augmentation

The following sections apply because this session is part of a canonical workflow. Preserve these fields for workflow continuity.

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

## Transition Gate

- Implement the approved fix, add regression tests, run the declared validation gates, then request approval to proceed to `bug-verify`.

## Approved Decisions

- session-resume-regression: approval of `report.md` is inferred from the presence of later bug artifacts.
- session-resume-regression: approval of `analysis.md` is inferred from the presence of later bug artifacts.

## Verification / Done Criteria

- Format, lint, typecheck, and relevant tests pass.
- Regression coverage demonstrates the original bug path is fixed.
- The change log and gate results are ready for `bug-verify`.
```

## Tuning later

The current implementation is intentionally simple:

- detection relies on `SESSION.md` plus existing `.codex/specs/` and `.codex/bugs/` artifacts
- stage inference falls back to artifact presence and content when the session log is ambiguous
- workflow semantics are isolated in `SPEC_STAGE_DETAILS` and `BUG_STAGE_DETAILS`
- generic continuity parses `SESSION.md` structured fields (Focus, Open Work, Pending Tests, Blockers)

That makes future changes easy:

- adjust stage inference rules in one file
- add more artifact parsing without changing the hook boundary
- add more generic signal sources (e.g., recent git log, open files) if needed
- switch to prompt replacement later if inject-only proves insufficient

## Where Layer 3 would fit later

Layer 3 can be added later by introducing a separate source of durable execution
memory and plugging it into the same state builder before rendering the
continuation schema.

That is intentionally not implemented here.

## Live dogfood evidence

### Spec workflow — session `ses_32738bc67ffesdQJgepVbfae50`

Token count climbed from 18k → 143k across six turns then dropped to 51k —
consistent with compaction. The compaction summary preserved `dogfood-spec`,
canonical `spec-execute`, the `context.md`-first instruction, harness gate command
pattern, artifact progression, and open decisions/discoveries.

### Bug workflow — session `ses_327240060ffe78bWr5Tsm4Qv1n`

Token count climbed from 18k → 172k across eight turns then dropped to 19k —
consistent with compaction. The compaction summary preserved `dogfood-bug`,
canonical `bug-fix`, the active artifact (`analysis.md`), the transition gate
(run gates → `bug-verify`), and the next action (implement fix + add regression tests).

Because the plugin is inject-only, the compaction model rewrites the injected context
rather than reproducing it verbatim — proof is behavioral. The compaction summary
contains the right workflow state, not a literal copy of the injected text.

## Validation

Automated tests cover:

1. Spec execution with a live `tasks.md` + `context.md` (backward-compatible)
2. Bug fixing with an approved `analysis.md` + harness progress note (backward-compatible)
3. Bug-analyze draft detection (backward-compatible)
4. Unknown fallback (backward-compatible)
5. Generic non-workflow session with `SESSION.md` context
6. Hybrid spec-execute session (generic + workflow layers)
7. Hybrid bug-fix session (generic + workflow layers)
8. Blocker and pending test extraction
9. Empty `SESSION.md` minimal output

Run:

```bash
npm test
```
