import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  buildWorkflowState,
  buildHybridState,
  renderContinuationContext,
  renderHybridContinuationContext,
} from "../src/stage-aware-compaction.js";

const tempDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    tempDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

describe("buildWorkflowState (backward compatibility)", () => {
  it("preserves spec-execute continuity with canonical stage names and next task", async () => {
    const root = await createTempRepo();
    const specDir = path.join(root, ".codex", "specs", "001-prd-compaction");

    await mkdir(path.join(specDir, "harness"), { recursive: true });
    await writeFile(
      path.join(root, "SESSION.md"),
      [
        "# Session State",
        "",
        "[Focus: execution] 2026-03-10 — Branch `feature/spec-exec`",
        "- Continue `/spec-execute next 001-prd-compaction` after compaction.",
        "- Active files: `src/stage-aware-compaction.ts`, `.codex/specs/001-prd-compaction/tasks.md`.",
        "- Blockers: none.",
      ].join("\n"),
    );
    await writeFile(path.join(root, "AGENTS.md"), "- Specs: `.codex/specs/`\n");
    await writeFile(
      path.join(specDir, "requirements.md"),
      "# Requirements\nready\n",
    );
    await writeFile(path.join(specDir, "design.md"), "# Design\nready\n");
    await writeFile(
      path.join(specDir, "tasks.md"),
      [
        "# Tasks",
        "",
        "## Batch 1 — Foundation",
        "- [x] 1. Parse SESSION.md",
        "- [ ] 2. Build continuation context",
        "",
        "## Batch 2 — Validation",
        "- [ ] 3. Add workflow tests",
      ].join("\n"),
    );
    await writeFile(
      path.join(specDir, "context.md"),
      [
        "# Execution Context — 001-prd-compaction",
        "",
        "## Status",
        "Last completed batch: 0",
        "Remaining batches: 1, 2",
        "",
        "## Decisions Made",
        "- [Batch 0] Decision: prefer inject-only compaction context — Rationale: preserves default OpenCode prompt behavior.",
        "",
        "## Key Discoveries",
        "- [Batch 0] `experimental.session.compacting` can push to `output.context`.",
      ].join("\n"),
    );

    const state = await buildWorkflowState(root);
    const rendered = renderContinuationContext(state);

    expect(state.workflowType).toBe("spec");
    expect(state.canonicalStage).toBe("spec-execute");
    expect(state.nextAction).toContain("001-prd-compaction");
    expect(state.currentStep).toContain("2 — Build continuation context");
    expect(rendered).toContain("## Canonical Workflow Stage\n- spec-execute");
    expect(rendered).toContain("inject-only compaction context");
  });

  it("preserves bug-fix continuity with analysis-driven execution state", async () => {
    const root = await createTempRepo();
    const bugDir = path.join(
      root,
      ".codex",
      "bugs",
      "session-resume-regression",
    );

    await mkdir(path.join(bugDir, "harness"), { recursive: true });
    await writeFile(
      path.join(root, "SESSION.md"),
      [
        "# Session State",
        "",
        "[Focus: bugfix] 2026-03-10 — Branch `feature/bug-fix`",
        "- Continue `bug-fix session-resume-regression` after compaction.",
        "- Active files: `.codex/bugs/session-resume-regression/analysis.md`, `src/stage-aware-compaction.ts`.",
      ].join("\n"),
    );
    await writeFile(path.join(root, "AGENTS.md"), "- Bugs: `.codex/bugs/`\n");
    await writeFile(
      path.join(bugDir, "report.md"),
      "# Bug Report\nrepro confirmed\n",
    );
    await writeFile(
      path.join(bugDir, "analysis.md"),
      [
        "# Bug Analysis",
        "",
        "## Risks / Trade-offs",
        "- Choose the minimal safe fix in the compaction hook without adding persistent memory.",
      ].join("\n"),
    );
    await writeFile(
      path.join(bugDir, "harness", "progress.md"),
      "- bug-fix approved; implement fix and add regression coverage\n",
    );

    const state = await buildWorkflowState(root);
    const rendered = renderContinuationContext(state);

    expect(state.workflowType).toBe("bug");
    expect(state.canonicalStage).toBe("bug-fix");
    expect(state.currentArtifact).toBe(
      ".codex/bugs/session-resume-regression/analysis.md",
    );
    expect(state.nextAction).toContain("hand-off to bug-verify");
    expect(rendered).toContain("## Canonical Workflow Stage\n- bug-fix");
    expect(rendered).toContain("minimal safe fix");
  });

  it("keeps a drafted analysis in bug-analyze until bug-fix is explicitly active", async () => {
    const root = await createTempRepo();
    const bugDir = path.join(root, ".codex", "bugs", "draft-analysis");

    await mkdir(bugDir, { recursive: true });
    await writeFile(path.join(root, "SESSION.md"), "# Session State\n");
    await writeFile(path.join(root, "AGENTS.md"), "- Bugs: `.codex/bugs/`\n");
    await writeFile(
      path.join(bugDir, "report.md"),
      "# Bug Report\nrepro confirmed\n",
    );
    await writeFile(
      path.join(bugDir, "analysis.md"),
      "# Bug Analysis\n\nWorking draft of root cause and options.\n",
    );

    const state = await buildWorkflowState(root);

    expect(state.workflowType).toBe("bug");
    expect(state.canonicalStage).toBe("bug-analyze");
  });

  it("falls back to unknown when no workflow artifacts are present", async () => {
    const root = await createTempRepo();

    await writeFile(
      path.join(root, "SESSION.md"),
      "# Session State\n\nNext Operator Brief\n- Blockers: none.\n",
    );
    await writeFile(path.join(root, "AGENTS.md"), "# Agent Notes\n");

    const state = await buildWorkflowState(root);
    const rendered = renderContinuationContext(state);

    expect(state.workflowType).toBe("unknown");
    expect(state.canonicalStage).toBe("uncertain");
    expect(rendered).toContain("## Workflow Type\n- unknown");
  });
});

describe("buildHybridState", () => {
  it("returns generic-only state for a non-workflow session with SESSION.md context", async () => {
    const root = await createTempRepo();

    await writeFile(
      path.join(root, "SESSION.md"),
      [
        "# Session State",
        "",
        "[Focus: refactor-auth] 2026-03-11 — Branch `refactor/auth-cleanup`",
        "- Extracted shared token validation into `src/auth/validate.ts`.",
        "- Removed duplicate middleware from `src/routes/api.ts`.",
        "- Decision: keep backward-compatible exports from the old location until v3.",
        "",
        "Reality Check — tests rerun? ✅; lint/analyze clean? ✅; context refreshed? ✅.",
        "",
        "Next Operator Brief",
        "",
        "- Open Work: migrate remaining callers of the old `validateSession()` to the new utility.",
        "- Pending Tests: integration tests for the new token validator.",
        "- Blockers: none.",
      ].join("\n"),
    );
    await writeFile(path.join(root, "AGENTS.md"), "# Agent Notes\n");

    const hybrid = await buildHybridState(root);
    const rendered = renderHybridContinuationContext(hybrid);

    // Generic state should be populated
    expect(hybrid.workflow).toBeNull();
    expect(hybrid.generic.primaryObjective).toContain("validateSession()");
    expect(hybrid.generic.status).toContain("refactor-auth");
    expect(hybrid.generic.completed).toContain(
      "Extracted shared token validation into `src/auth/validate.ts`.",
    );
    expect(hybrid.generic.completed).toContain(
      "Removed duplicate middleware from `src/routes/api.ts`.",
    );
    expect(hybrid.generic.remaining).toEqual(
      expect.arrayContaining([expect.stringContaining("validateSession()")]),
    );
    expect(hybrid.generic.decisions).toEqual(
      expect.arrayContaining([
        expect.stringContaining("backward-compatible exports"),
      ]),
    );

    // Rendered output should have generic sections but NO workflow augmentation
    expect(rendered).toContain("## Primary Objective");
    expect(rendered).toContain("## Current Step");
    expect(rendered).toContain("## Next Action");
    expect(rendered).not.toContain("## Workflow-Aware Augmentation");
    expect(rendered).not.toContain("## Canonical Workflow Stage");
    expect(rendered).not.toContain("## Source Artifacts");
  });

  it("returns generic + workflow augmentation for a spec-execute session", async () => {
    const root = await createTempRepo();
    const specDir = path.join(root, ".codex", "specs", "feat-metrics");

    await mkdir(path.join(specDir, "harness"), { recursive: true });
    await writeFile(
      path.join(root, "SESSION.md"),
      [
        "# Session State",
        "",
        "[Focus: spec-execute] 2026-03-11 — Branch `feat/metrics`",
        "- Continue `/spec-execute next feat-metrics` after compaction.",
      ].join("\n"),
    );
    await writeFile(path.join(root, "AGENTS.md"), "# Agent Notes\n");
    await writeFile(
      path.join(specDir, "requirements.md"),
      "# Requirements\napproved\n",
    );
    await writeFile(path.join(specDir, "design.md"), "# Design\napproved\n");
    await writeFile(
      path.join(specDir, "tasks.md"),
      [
        "# Tasks",
        "## Batch 1",
        "- [x] 1. Create metrics module",
        "- [ ] 2. Add export formatters",
      ].join("\n"),
    );
    await writeFile(
      path.join(specDir, "context.md"),
      [
        "# Execution Context",
        "## Status",
        "Last completed batch: 0",
        "## Decisions Made",
        "- [Batch 0] Decision: use structured JSON for metric export.",
      ].join("\n"),
    );

    const hybrid = await buildHybridState(root);
    const rendered = renderHybridContinuationContext(hybrid);

    // Both layers should be present
    expect(hybrid.workflow).not.toBeNull();
    expect(hybrid.workflow!.workflowType).toBe("spec");
    expect(hybrid.workflow!.canonicalStage).toBe("spec-execute");
    expect(hybrid.generic.nextAction).toContain("feat-metrics");

    // Rendered output should have both sections
    expect(rendered).toContain("## Primary Objective");
    expect(rendered).toContain("## Workflow-Aware Augmentation");
    expect(rendered).toContain("## Canonical Workflow Stage\n- spec-execute");
    expect(rendered).toContain("## Source Artifacts");
  });

  it("returns generic + workflow augmentation for a bug-fix session", async () => {
    const root = await createTempRepo();
    const bugDir = path.join(root, ".codex", "bugs", "auth-crash");

    await mkdir(path.join(bugDir, "harness"), { recursive: true });
    await writeFile(
      path.join(root, "SESSION.md"),
      [
        "# Session State",
        "",
        "[Focus: bug-fix] 2026-03-11 — Branch `fix/auth-crash`",
        "- Continue `bug-fix auth-crash` after compaction.",
      ].join("\n"),
    );
    await writeFile(path.join(root, "AGENTS.md"), "# Agent Notes\n");
    await writeFile(
      path.join(bugDir, "report.md"),
      "# Bug Report\nAuth crash on expired tokens\n",
    );
    await writeFile(
      path.join(bugDir, "analysis.md"),
      "# Analysis\n## Root Cause\nMissing null check in token refresh\n",
    );
    await writeFile(
      path.join(bugDir, "harness", "progress.md"),
      "- bug-fix approved; implement null check\n",
    );

    const hybrid = await buildHybridState(root);
    const rendered = renderHybridContinuationContext(hybrid);

    expect(hybrid.workflow).not.toBeNull();
    expect(hybrid.workflow!.workflowType).toBe("bug");
    expect(hybrid.workflow!.canonicalStage).toBe("bug-fix");
    expect(hybrid.generic.nextAction).toContain("auth-crash");

    expect(rendered).toContain("## Workflow-Aware Augmentation");
    expect(rendered).toContain("## Canonical Workflow Stage\n- bug-fix");
  });

  it("extracts pending tests and blockers into generic remaining and blockers", async () => {
    const root = await createTempRepo();

    await writeFile(
      path.join(root, "SESSION.md"),
      [
        "# Session State",
        "",
        "[Focus: perf-tuning] 2026-03-11 — Branch `perf/query-optimizer`",
        "- Rewrote the N+1 query in `src/db/users.ts`.",
        "- BLOCKED: waiting for database migration to complete on staging.",
        "",
        "Next Operator Brief",
        "",
        "- Open Work: benchmark the new query against the old one.",
        "- Pending Tests: load test with 10k users.",
        "- Blockers: database migration on staging.",
      ].join("\n"),
    );
    await writeFile(path.join(root, "AGENTS.md"), "# Agent Notes\n");

    const hybrid = await buildHybridState(root);

    expect(hybrid.workflow).toBeNull();
    expect(hybrid.generic.blockers.length).toBeGreaterThan(0);
    expect(hybrid.generic.blockers.some((b) => /migration/i.test(b))).toBe(
      true,
    );
    expect(hybrid.generic.remaining).toEqual(
      expect.arrayContaining([
        expect.stringContaining("benchmark"),
        expect.stringContaining("load test"),
      ]),
    );
    expect(hybrid.generic.status).toContain("At risk");
  });

  it("produces minimal but useful output for an empty SESSION.md", async () => {
    const root = await createTempRepo();

    await writeFile(path.join(root, "SESSION.md"), "# Session State\n");
    await writeFile(path.join(root, "AGENTS.md"), "# Agent Notes\n");

    const hybrid = await buildHybridState(root);
    const rendered = renderHybridContinuationContext(hybrid);

    expect(hybrid.workflow).toBeNull();
    expect(hybrid.generic.nextAction).toBeTruthy();
    expect(rendered).toContain("## Primary Objective");
    expect(rendered).toContain("## Next Action");
    expect(rendered).not.toContain("## Workflow-Aware Augmentation");
  });
});

async function createTempRepo(): Promise<string> {
  const root = await mkdtemp(path.join(os.tmpdir(), "stage-aware-compaction-"));
  tempDirectories.push(root);
  await mkdir(path.join(root, ".codex", "specs"), { recursive: true });
  await mkdir(path.join(root, ".codex", "bugs"), { recursive: true });
  return root;
}
