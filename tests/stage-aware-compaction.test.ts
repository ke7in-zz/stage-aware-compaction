import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  buildWorkflowState,
  renderContinuationContext,
} from "../src/stage-aware-compaction.js";

const tempDirectories: string[] = [];

describe("buildWorkflowState", () => {
  afterEach(async () => {
    await Promise.all(
      tempDirectories
        .splice(0)
        .map((directory) => rm(directory, { recursive: true, force: true })),
    );
  });

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

async function createTempRepo(): Promise<string> {
  const root = await mkdtemp(path.join(os.tmpdir(), "stage-aware-compaction-"));
  tempDirectories.push(root);
  await mkdir(path.join(root, ".codex", "specs"), { recursive: true });
  await mkdir(path.join(root, ".codex", "bugs"), { recursive: true });
  return root;
}
