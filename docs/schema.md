# Continuation schema

Every compaction event produces a `## Stage-Aware Continuation` block. Generic
fields appear first; workflow augmentation fields follow, separated by `---`, only
when a canonical workflow is detected.

## Generic fields (always present)

### `## Primary Objective`

The main goal the session should resume toward after compaction.

**Source**: `Open Work:` field from `Next Operator Brief` in `SESSION.md`. Falls
back to "Continue work on: `<focus area>`" if open work is not present, or to a
generic resume phrase if `SESSION.md` is empty.

**Example**:

```
## Primary Objective
- Migrate remaining callers of the old `validateSession()` to the new utility.
```

---

### `## Current Step`

The immediate next action, phrased as an instruction.

**Source**: Same as `## Primary Objective` — the open work field, prefixed with
"Current open work:". Falls back to a generic review instruction.

For `spec-execute` sessions this is overridden by the next incomplete task from
`tasks.md`: `Continue the current implementation lane in <batch>: <task>`.

**Example**:

```
## Current Step
- Current open work: migrate remaining callers of the old `validateSession()`.
```

---

### `## Status`

A one-line assessment of session health.

**Source**: Synthesised from focus area, blockers, and `Blockers:` field in
`Next Operator Brief`.

Patterns:

- `At risk — blockers recorded: <first blocker>` — when real blockers are detected
- `Active — working on <focus area>.` — normal, no blockers
- `Session state should be reviewed before continuing.` — no focus area found

**Example**:

```
## Status
- Active — working on refactor-auth.
```

---

### `## Completed`

What has been finished in the current session (or in the recent session log).

**Source**: Bullet-point lines from `[Focus: ...]` session log entries in
`SESSION.md`, excluding lines that start with `Blockers:`. Limited to 5 items.

For workflow sessions, prepended with artifact approval statements inferred from
later-stage artifact presence.

**Example**:

```
## Completed
- Extracted shared token validation into `src/auth/validate.ts`.
- Removed duplicate middleware from `src/routes/api.ts`.
```

---

### `## Remaining`

What still needs to be done.

**Source**:

- Open work from `Next Operator Brief`
- Pending tests from `Pending Tests:` field in `Next Operator Brief`
- For `spec-execute`: remaining task items from `tasks.md` checkboxes

**Example**:

```
## Remaining
- migrate remaining callers of the old `validateSession()` to the new utility.
- Pending tests: integration tests for the new token validator.
```

---

### `## Decisions`

Decisions recorded during the session.

**Source**: Lines from session log entries containing `decision`, `decided`,
`chose`, `prefer`, `chosen`, or `approved` (case-insensitive). Limited to 4 items.

For workflow sessions, also includes decisions extracted from `## Decisions Made`
sections in `context.md` (spec) or `## Risks / Trade-offs` / `## Decisions`
sections in `analysis.md` (bug).

**Example**:

```
## Decisions
- Decision: keep backward-compatible exports from the old location until v3.
```

---

### `## Active Files`

Files being actively worked on.

**Source**: Backtick-quoted file-like strings from `SESSION.md`, plus source
artifact paths for workflow sessions. Filtered to paths that look like real
files (contain a `.` extension or start with known prefixes like `src/`,
`.codex/`, `tests/`, `steering/`). Limited to 6 items.

**Example**:

```
## Active Files
- src/auth/validate.ts
- src/routes/api.ts
```

---

### `## Blockers / Risks`

Active blockers that should not be forgotten after compaction.

**Source**: Lines from `SESSION.md` that start with `Blockers:` or contain
`BLOCKED` or `blocked`, excluding lines that normalise to `Blockers: none.`
Limited to 4 items.

**Example**:

```
## Blockers / Risks
- database migration on staging must complete before benchmarking.
```

---

### `## Next Action`

The single most concrete next thing to do.

**Source**: Same as `## Primary Objective`. For `spec-execute` sessions, this is
`Resume <spec-name> in spec-execute: <next task>`. For `bug-fix` sessions, this
is `Implement the approved minimal fix for <bug-name>, add regression coverage,
and prepare the hand-off to bug-verify.`

**Example**:

```
## Next Action
- migrate remaining callers of the old `validateSession()` to the new utility.
```

---

## Workflow augmentation fields (conditional)

These fields appear only when a canonical spec or bug workflow is detected. They
are grouped under a `## Workflow-Aware Augmentation` heading separated from the
generic fields by `---`.

### `## Workflow Type`

`spec` or `bug`.

---

### `## Canonical Workflow Stage`

The exact canonical stage name — never paraphrased or normalised.

Valid values: `spec-create`, `spec-design`, `spec-tasks`, `spec-execute`,
`bug-create`, `bug-analyze`, `bug-fix`, `bug-verify`.

---

### `## Source Artifacts`

All artifact files that exist for the active workflow item, as relative paths
from the project root.

For spec: `requirements.md`, `design.md`, `tasks.md`, `context.md`,
`harness/feature_list.json` (any that exist).

For bug: `report.md`, `analysis.md`, `verification.md`,
`harness/progress.md`, `harness/bug_state.json` (any that exist).

---

### `## Current Artifact`

The primary artifact for the current stage:

| Stage          | Artifact                          |
| -------------- | --------------------------------- |
| `spec-create`  | `requirements.md`                 |
| `spec-design`  | `design.md`                       |
| `spec-tasks`   | `tasks.md`                        |
| `spec-execute` | `tasks.md`                        |
| `bug-create`   | `report.md`                       |
| `bug-analyze`  | `analysis.md`                     |
| `bug-fix`      | `analysis.md` (approved fix plan) |
| `bug-verify`   | `verification.md`                 |

---

### `## Artifact Status`

A human-readable summary of the artifact's current state.

For `spec-execute`: `<spec-name>: <N> task(s) complete, <N> remaining; next task is <task>.`

For bug stages: derived from the first non-empty line of `harness/bug_state.json`
or `harness/progress.md`, or a generic phrase.

---

### `## Transition Gate`

What must be true before moving to the next stage. Static per stage from
`SPEC_STAGE_DETAILS` / `BUG_STAGE_DETAILS`.

Examples:

- `spec-execute`: batch gates via `harness.sh spec gate`, review addressed, `context.md` updated
- `bug-fix`: implement fix, add regression tests, run declared validation gates, request approval

---

### `## Approved Decisions`

Approvals inferred from later-stage artifact presence.

Logic: if `design.md` exists and the stage is `spec-tasks` or later, then
`requirements.md` approval is inferred. Explicit approval captures in
`SESSION.md` are also included.

---

### `## Pending Decisions / Open Questions`

Open approval gates or unresolved questions.

For pre-execution stages (`spec-create`, `spec-design`, `spec-tasks`,
`bug-create`, `bug-analyze`): a reminder that explicit user approval is required
before advancing.

For `bug-fix`: a reminder to request approval before moving to `bug-verify`.

Approval-related lines extracted from `SESSION.md` are also included.

---

### `## Dependencies / Preconditions`

Prerequisites for the current stage. Static per stage from
`SPEC_STAGE_DETAILS` / `BUG_STAGE_DETAILS`.

---

### `## Verification / Done Criteria`

What "done" means for the current stage. Static per stage.

Examples:

- `spec-execute`: task-level gates pass, batch validation passes, `context.md` updated
- `bug-verify`: original repro passes after fix, regression documented, audit gate passes

---

## Empty and uncertain values

When a field has no content, it renders as:

```
## Field Name
- none recorded
```

The `## Canonical Workflow Stage` field renders as `uncertain` when stage
detection fails within a detected workflow. This should be rare — it only occurs
if a workflow artifact directory exists but none of the stage-detection conditions
match.
