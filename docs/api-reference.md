# API Reference

Exported symbols from `src/stage-aware-compaction.ts` (re-exported via `src/index.ts`).

The plugin is a TypeScript source file that users copy directly — there is no compiled
bundle. Import directly from the file path, or use the re-export barrel in `src/index.ts`.

---

## `StageAwareCompactionPlugin`

```ts
export const StageAwareCompactionPlugin: Plugin;
```

The OpenCode plugin function. This is the **primary export** and the only thing most
users interact with. OpenCode discovers it automatically because the file is placed in
`.opencode/plugins/`.

Registers one hook: `experimental.session.compacting`.

When the hook fires, the plugin:

1. Reads `SESSION.md`, `AGENTS.md`, `.codex/specs/`, and `.codex/bugs/` from the
   project root (or worktree root, if a worktree is active).
2. Calls `buildHybridState` to construct a structured continuation brief.
3. Calls `renderHybridContinuationContext` to serialise the brief as a Markdown block.
4. Pushes that Markdown block onto `output.context`.
5. Logs the outcome via `client.app.log` at `info`, `warn`, or `error`.

**Parameters** (destructured from the OpenCode plugin context):

| Name        | Type     | Description                                  |
| ----------- | -------- | -------------------------------------------- |
| `directory` | `string` | Absolute path to the project root            |
| `worktree`  | `string` | Absolute path to the active worktree, if any |
| `client`    | `object` | OpenCode client; used for `client.app.log()` |

**Returns**: `Plugin` — a record mapping the hook name to the async handler.

**Throws**: Never. All errors are caught and logged at `error` level. The hook always
completes, even if context injection fails.

---

## `buildHybridState`

```ts
export async function buildHybridState(
  root: string,
  snapshot?: WorkflowSnapshot,
): Promise<HybridState>;
```

Primary logic entry point. Reads the filesystem (or accepts a pre-built snapshot) and
returns a `HybridState` with the generic layer always populated and the workflow
augmentation populated only when a canonical workflow is clearly detected.

**Parameters**:

| Name       | Type                | Description                                                      |
| ---------- | ------------------- | ---------------------------------------------------------------- |
| `root`     | `string`            | Absolute path to the project root                                |
| `snapshot` | `WorkflowSnapshot?` | Optional pre-loaded snapshot; if omitted, the filesystem is read |

**Returns**: `Promise<HybridState>`

**Detection order**:

1. Look for a stage hint (`spec-*` or `bug-*`) in `SESSION.md` + `AGENTS.md`.
2. If the hint points to a spec stage, find the most recently modified `.codex/specs/`
   subdirectory and build a spec hybrid state.
3. If the hint points to a bug stage, find the most recently modified `.codex/bugs/`
   subdirectory and build a bug hybrid state.
4. If no hint, fall back to artifact-presence detection (spec first, then bug).
5. If no workflow is detected, return generic-only state (`workflow: null`).

**Usage**:

```ts
import { buildHybridState } from "./src/stage-aware-compaction.js";

const state = await buildHybridState("/path/to/project");
console.log(state.generic.primaryObjective);
console.log(state.workflow?.canonicalStage); // null if generic-only
```

---

## `renderHybridContinuationContext`

```ts
export function renderHybridContinuationContext(state: HybridState): string;
```

Serialises a `HybridState` into a Markdown string that is pushed into the compaction
context. The output has two sections:

- **`## Stage-Aware Continuation`** — generic fields; always present.
- **`## Workflow-Aware Augmentation`** — workflow fields; only present when
  `state.workflow !== null`.

**Parameters**:

| Name    | Type          | Description        |
| ------- | ------------- | ------------------ |
| `state` | `HybridState` | State to serialise |

**Returns**: `string` — Markdown block suitable for injection into `output.context`.

**Example output** (generic-only):

```markdown
## Stage-Aware Continuation

Preserve the canonical workflow names exactly. Treat this as the authoritative resume brief for compaction continuity.

### Primary Objective

- Implement rate-limiting middleware

### Current Step

- Writing unit tests for the middleware

...
```

---

## `buildWorkflowState` _(deprecated)_

```ts
export async function buildWorkflowState(
  root: string,
  snapshot?: WorkflowSnapshot,
): Promise<WorkflowState>;
```

Backward-compatible wrapper around `buildHybridState`. Flattens the two-layer
`HybridState` into the legacy flat `WorkflowState` shape.

**Use `buildHybridState` for all new code.** This export is preserved only so that
existing tests and integrations do not break.

---

## `renderContinuationContext` _(deprecated)_

```ts
export function renderContinuationContext(state: WorkflowState): string;
```

Backward-compatible renderer for the legacy flat `WorkflowState`. Produces a single
`## Stage-Aware Continuation` section with all fields regardless of whether a workflow
was detected.

**Use `renderHybridContinuationContext` for all new code.**

---

## Types

### `HybridState`

```ts
type HybridState = {
  generic: GenericState;
  workflow: WorkflowAugmentation | null;
};
```

The combined hybrid state. `generic` is always populated. `workflow` is `null` when no
canonical workflow is detected.

---

### `GenericState`

```ts
type GenericState = {
  primaryObjective: string;
  currentStep: string;
  status: string;
  completed: string[];
  remaining: string[];
  decisions: string[];
  activeFiles: string[];
  blockers: string[];
  nextAction: string;
};
```

Generic continuation fields extracted from `SESSION.md`. See [schema.md](schema.md) for
the source and derivation of each field.

---

### `WorkflowAugmentation`

```ts
type WorkflowAugmentation = {
  workflowType: "spec" | "bug";
  canonicalStage: CanonicalStage;
  sourceArtifacts: string[];
  currentArtifact: string;
  artifactStatus: string;
  transitionGate: string;
  approvedDecisions: string[];
  pendingDecisions: string[];
  dependencies: string[];
  verification: string[];
};
```

Workflow-specific fields present only when a canonical spec or bug workflow is detected.
See [schema.md](schema.md) for field semantics.

---

### `CanonicalStage`

```ts
type CanonicalStage =
  | "spec-create"
  | "spec-design"
  | "spec-tasks"
  | "spec-execute"
  | "bug-create"
  | "bug-analyze"
  | "bug-fix"
  | "bug-verify";
```

All eight canonical workflow stage names. These are the only valid values for
`WorkflowAugmentation.canonicalStage`. The plugin preserves these names verbatim in the
compaction context so the resuming agent does not invent non-canonical stage names.

---

### `WorkflowState` _(deprecated)_

```ts
type WorkflowState = {
  workflowType: "spec" | "bug" | "unknown";
  canonicalStage: CanonicalStage | "uncertain";
  // ... all GenericState fields and all WorkflowAugmentation fields flat
};
```

Legacy flat shape used by `buildWorkflowState` and `renderContinuationContext`. Prefer
`HybridState` for new work.

---

## Default export

```ts
export default StageAwareCompactionPlugin;
```

Same as the named `StageAwareCompactionPlugin` export. Provided for convenience.
