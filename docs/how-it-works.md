# How it works

## Overview

The plugin registers a single hook: `experimental.session.compacting`. This hook
fires synchronously before the LLM generates the compaction summary. The plugin
reads filesystem state, builds a structured continuation brief, and pushes it to
`output.context`. The LLM then incorporates that brief when writing the summary.

```
compaction triggered
        │
        ▼
experimental.session.compacting hook
        │
        ├─ readWorkflowSnapshot()       ← reads SESSION.md, AGENTS.md,
        │                                  .codex/specs/, .codex/bugs/
        │
        ├─ buildHybridState()           ← detects workflow, builds both layers
        │
        │   ┌─ workflow detected? ──────────────────────────┐
        │   │                                               │
        │   ▼ NO                                            ▼ YES
        │ buildGenericState()          buildSpec/BugHybridState()
        │ (parses SESSION.md)          (parses artifacts + SESSION.md)
        │                                    │
        │                              generic layer  +  workflow augmentation
        │
        └─ renderHybridContinuationContext()
                │
                └─ output.context.push(rendered markdown)
                        │
                        ▼
              LLM generates compaction summary
              incorporating the continuation brief
```

## Hook strategy: inject-only

The plugin uses `output.context.push(...)` rather than replacing `output.prompt`.

This means the plugin **adds** structured context on top of OpenCode's default
compaction prompt. The default prompt is preserved. The LLM receives both the
default instructions and the plugin's continuation brief, then rewrites them into
its own summary language.

Consequence: the injected text is not reproduced verbatim in the compaction
summary — the model incorporates the _signal_ and writes in its own words. Proof
of effectiveness is behavioral (the summary contains the right workflow state),
not textual.

Replacing `output.prompt` is not used because the problem is missing workflow
continuity, not a failure of the default compaction prompt. Replacing it would
discard the `output.context` array and require maintaining a full compaction
prompt independently.

## Detection

Detection runs in priority order:

### 1. Stage hint from session text

`findLatestStageMention()` scans `SESSION.md` + `AGENTS.md` for the last
occurrence of any canonical stage name:

```
spec-create  spec-design  spec-tasks  spec-execute
bug-create   bug-analyze  bug-fix     bug-verify
```

If found, the plugin uses that stage as a hint and looks for matching artifact
directories under `.codex/specs/` (for `spec-*`) or `.codex/bugs/` (for `bug-*`).

### 2. Artifact directory presence

If no stage hint is found, the plugin checks whether any directories exist under
`.codex/specs/` or `.codex/bugs/`. If they do, it scores them and picks the most
recently active one.

Scoring factors:

| Factor                                         | Score bonus        |
| ---------------------------------------------- | ------------------ |
| Artifact name mentioned in `SESSION.md`        | +1,000,000,000,000 |
| Primary artifact file has meaningful content   | +10,000            |
| Secondary artifact file has meaningful content | +1,000             |
| File modification time                         | base score         |

### 3. Generic fallback

If neither stage hint nor artifact directories are found, the plugin falls back
to generic mode. No workflow augmentation is emitted.

### Stage detection within a workflow

Once an artifact directory is selected, the stage is inferred from artifact
presence and content:

**Spec workflow:**

| Condition                                                       | Stage          |
| --------------------------------------------------------------- | -------------- |
| `tasks.md` has checkboxes OR `context.md` has execution markers | `spec-execute` |
| `tasks.md` has meaningful content                               | `spec-tasks`   |
| `design.md` has meaningful content                              | `spec-design`  |
| Otherwise                                                       | `spec-create`  |

Execution markers in `context.md`: `Last completed batch:`, `Remaining batches:`,
`## Key Discoveries`, `## Decisions Made`, `[Batch N]`

**Bug workflow:**

| Condition                                                            | Stage         |
| -------------------------------------------------------------------- | ------------- |
| `verification.md` has content OR `progress.md` contains `bug-verify` | `bug-verify`  |
| `progress.md` contains `bug-fix`                                     | `bug-fix`     |
| `report.md` + `analysis.md` both have content                        | `bug-analyze` |
| Otherwise                                                            | `bug-create`  |

The `bug-fix` vs `bug-analyze` distinction is intentionally conservative: the
presence of `analysis.md` alone is not enough to promote to `bug-fix`. An
explicit `bug-fix` signal must appear in `harness/progress.md`. This prevents
false promotion during the analysis draft phase.

## The two-layer design

### Generic layer (`GenericState`)

Always populated. Extracted from `SESSION.md`:

- **Focus area** — from `[Focus: <area>]` header in the session log
- **Open work** — from `Open Work:` field in `Next Operator Brief`
- **Completed items** — bullet-point lines from session log entries (before `Reality Check` / `Next Operator Brief`)
- **Decisions** — lines containing `decision`, `decided`, `chose`, `prefer`, `chosen`, or `approved`
- **Pending tests** — from `Pending Tests:` field in `Next Operator Brief`
- **Blockers** — lines starting with `Blockers:` or containing `BLOCKED` / `blocked`, excluding `Blockers: none.`
- **Active files** — backtick-quoted file paths from session text + source artifact paths

### Workflow augmentation (`WorkflowAugmentation`)

Added only when a canonical workflow is detected. Drawn from:

- Artifact files (`requirements.md`, `design.md`, `tasks.md`, `context.md` for spec;
  `report.md`, `analysis.md`, `verification.md`, `harness/progress.md` for bug)
- Stage-specific static detail tables (`SPEC_STAGE_DETAILS`, `BUG_STAGE_DETAILS`)
- Approval inference (later-stage artifacts imply earlier-stage approvals)

### Rendered output structure

```
## Stage-Aware Continuation
<preamble>

## Primary Objective        ← generic
## Current Step             ← generic
## Status                   ← generic
## Completed                ← generic
## Remaining                ← generic
## Decisions                ← generic
## Active Files             ← generic
## Blockers / Risks         ← generic
## Next Action              ← generic

---                         ← only when workflow detected

## Workflow-Aware Augmentation
<preamble>

## Workflow Type            ← workflow
## Canonical Workflow Stage ← workflow (canonical name, verbatim)
## Source Artifacts         ← workflow
## Current Artifact         ← workflow
## Artifact Status          ← workflow
## Transition Gate          ← workflow
## Approved Decisions       ← workflow
## Pending Decisions / Open Questions  ← workflow
## Dependencies / Preconditions        ← workflow
## Verification / Done Criteria        ← workflow
```

## Filesystem reads

At each compaction event the plugin reads:

| File                                   | Required | Purpose                            |
| -------------------------------------- | -------- | ---------------------------------- |
| `SESSION.md`                           | No       | Generic layer signal source        |
| `AGENTS.md`                            | No       | Stage hint scanning                |
| `.codex/specs/*/`                      | No       | Spec workflow artifact directories |
| `.codex/bugs/*/`                       | No       | Bug workflow artifact directories  |
| `<artifact>/requirements.md`           | No       | Spec source artifact               |
| `<artifact>/design.md`                 | No       | Spec source artifact               |
| `<artifact>/tasks.md`                  | No       | Spec task progress                 |
| `<artifact>/context.md`                | No       | Spec carry-forward context         |
| `<artifact>/harness/feature_list.json` | No       | Spec harness state                 |
| `<artifact>/report.md`                 | No       | Bug source artifact                |
| `<artifact>/analysis.md`               | No       | Bug source artifact                |
| `<artifact>/verification.md`           | No       | Bug verification artifact          |
| `<artifact>/harness/progress.md`       | No       | Bug stage signal + progress        |
| `<artifact>/harness/bug_state.json`    | No       | Bug harness state                  |

All reads are best-effort — a missing file yields `null` and is handled gracefully.
The plugin never writes.

## Logging

The hook logs via `client.app.log()` at three points:

| Level   | Message                                             | When                                                                                   |
| ------- | --------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `info`  | `"compaction context injected"`                     | Normal path — context was built and pushed                                             |
| `warn`  | `"compaction fired with no session state detected"` | Generic layer produced only the fallback objective (empty or unparseable `SESSION.md`) |
| `error` | `"compaction hook failed — no context injected"`    | An exception escaped the hook; compaction proceeds with default prompt only            |

Fields included in every log entry:

- `service`: always `"stage-aware-compaction"`
- `sessionID`: the OpenCode session ID
- `mode`: `"generic"` or `"workflow:spec/spec-execute"` etc.
- `artifact`: active artifact path (workflow mode only)
- `error`: error message (error level only)
- `root`: project root path (warn and error levels)

To read logs:

```bash
grep "stage-aware-compaction" ~/.local/share/opencode/log/*.log
```
