import { promises as fs } from "node:fs";
import path from "node:path";

import type { Plugin } from "@opencode-ai/plugin";

const CANONICAL_SPEC_STAGES = [
  "spec-create",
  "spec-design",
  "spec-tasks",
  "spec-execute",
] as const;

const CANONICAL_BUG_STAGES = [
  "bug-create",
  "bug-analyze",
  "bug-fix",
  "bug-verify",
] as const;

const CANONICAL_STAGES = [
  ...CANONICAL_SPEC_STAGES,
  ...CANONICAL_BUG_STAGES,
] as const;

type SpecStage = (typeof CANONICAL_SPEC_STAGES)[number];
type BugStage = (typeof CANONICAL_BUG_STAGES)[number];
type CanonicalStage = (typeof CANONICAL_STAGES)[number];
type WorkflowType = "spec" | "bug" | "unknown";

type WorkflowState = {
  workflowType: WorkflowType;
  canonicalStage: CanonicalStage | "uncertain";
  sourceArtifacts: string[];
  currentArtifact: string;
  artifactStatus: string;
  transitionGate: string;
  primaryObjective: string;
  currentStep: string;
  status: string;
  completed: string[];
  remaining: string[];
  decisions: string[];
  approvedDecisions: string[];
  pendingDecisions: string[];
  dependencies: string[];
  activeFiles: string[];
  blockers: string[];
  verification: string[];
  nextAction: string;
};

type ArtifactDirectory = {
  name: string;
  path: string;
  modifiedAtMs: number;
};

type TaskProgress = {
  completedCount: number;
  remainingCount: number;
  nextTask: string | null;
  currentBatch: string | null;
  completedItems: string[];
  remainingItems: string[];
};

type WorkflowSnapshot = {
  sessionText: string;
  agentsText: string;
  specDirectories: ArtifactDirectory[];
  bugDirectories: ArtifactDirectory[];
};

const SPEC_STAGE_DETAILS: Record<
  SpecStage,
  Omit<
    WorkflowState,
    | "workflowType"
    | "canonicalStage"
    | "sourceArtifacts"
    | "currentArtifact"
    | "artifactStatus"
    | "status"
    | "completed"
    | "remaining"
    | "decisions"
    | "approvedDecisions"
    | "pendingDecisions"
    | "activeFiles"
    | "blockers"
    | "nextAction"
  >
> = {
  "spec-create": {
    transitionGate:
      "Explicit approval of `requirements.md` is required before `spec-design`.",
    primaryObjective:
      "Produce a complete `requirements.md` for the active spec with clear acceptance criteria and validation coverage.",
    currentStep:
      "Finalize `requirements.md` and request explicit approval to proceed to `spec-design`.",
    dependencies: [
      "Load steering docs before drafting requirements.",
      "Assign or confirm the spec directory name under `.codex/specs/`.",
    ],
    verification: [
      "Requirements are complete, unambiguous, and aligned to steering docs.",
      "Validation plan and success metrics are defined.",
      "User approval is captured before moving to `spec-design`.",
    ],
  },
  "spec-design": {
    transitionGate:
      "Explicit approval of `design.md` is required before `spec-tasks`.",
    primaryObjective:
      "Produce an implementation-ready `design.md` aligned with requirements and steering docs.",
    currentStep:
      "Complete `design.md`, including reuse analysis and testing strategy, then request approval for `spec-tasks`.",
    dependencies: [
      "Approved `requirements.md` must exist.",
      "Reuse analysis should reflect the current repo structure and constraints.",
    ],
    verification: [
      "Architecture, interfaces, data models, error handling, and testing strategy are documented.",
      "Trade-offs are explicit and the selected approach is justified.",
      "User approval is captured before moving to `spec-tasks`.",
    ],
  },
  "spec-tasks": {
    transitionGate:
      "Explicit approval of `tasks.md` is required before `spec-execute`.",
    primaryObjective:
      "Convert the approved design into small, traceable implementation tasks with strong validation gates.",
    currentStep:
      "Finish `tasks.md`, make sure every task has validation commands, and request approval for `spec-execute`.",
    dependencies: [
      "Approved `design.md` must exist.",
      "Tasks must map back to requirements and reuse targets.",
    ],
    verification: [
      "Each task includes requirement refs, leverage targets, and concrete validation commands.",
      "Each batch includes a meaningful batch-level validation gate.",
      "User approval is captured before moving to `spec-execute`.",
    ],
  },
  "spec-execute": {
    transitionGate:
      "For the current batch: declared task gates pass via `.codex/scripts/harness.sh spec gate <spec-name> <task-id>`, batch validation passes, `/review` feedback is addressed, `context.md` is updated, and the batch stops after commit.",
    primaryObjective:
      "Execute the current approved spec batch with minimal drift, validate it, update `context.md`, and stop with a resumable hand-off.",
    currentStep:
      "Continue the next incomplete batch or task from `tasks.md`, using `context.md` as the carry-forward brief.",
    dependencies: [
      "Approved `tasks.md` must exist.",
      "Read `context.md` first if it exists.",
      "Harness state must be current; run `/spec-init <spec-name>` if `harness/feature_list.json` is missing or stale.",
    ],
    verification: [
      "Task-level validation gates pass for each completed task.",
      "Batch validation passes before stopping.",
      "`context.md` records discoveries, decisions, utilities, and carry-forward warnings.",
    ],
  },
};

const BUG_STAGE_DETAILS: Record<
  BugStage,
  Omit<
    WorkflowState,
    | "workflowType"
    | "canonicalStage"
    | "sourceArtifacts"
    | "currentArtifact"
    | "artifactStatus"
    | "status"
    | "completed"
    | "remaining"
    | "decisions"
    | "approvedDecisions"
    | "pendingDecisions"
    | "activeFiles"
    | "blockers"
    | "nextAction"
  >
> = {
  "bug-create": {
    transitionGate:
      "Explicit approval of `report.md` is required before `bug-analyze`.",
    primaryObjective:
      "Capture a complete, reproducible bug report and initialize the bug harness.",
    currentStep:
      "Finish `report.md`, initialize the harness, and request approval to proceed to `bug-analyze`.",
    dependencies: [
      "Create `.codex/bugs/<bug-name>/` with the report and harness placeholders.",
      "Gather enough repro and environment detail to make analysis actionable.",
    ],
    verification: [
      "`report.md` clearly states expected vs actual behavior, repro steps, environment, impact, and initial analysis.",
      "Harness initialization has run or is confirmed as not yet configured.",
      "User approval is captured before moving to `bug-analyze`.",
    ],
  },
  "bug-analyze": {
    transitionGate:
      "Explicit approval of `analysis.md` is required before `bug-fix`.",
    primaryObjective:
      "Determine root cause, choose the minimal safe fix, and define the verification strategy.",
    currentStep:
      "Complete `analysis.md`, including alternatives and prevention, then request approval for `bug-fix`.",
    dependencies: [
      "A complete `report.md` must exist.",
      "Affected files and symbols must be identified before choosing the fix.",
    ],
    verification: [
      "`analysis.md` names root cause, contributing factors, affected scope, fix plan, risks, and tests.",
      "The chosen fix is the minimal safe option and alternatives are documented.",
      "User approval is captured before moving to `bug-fix`.",
    ],
  },
  "bug-fix": {
    transitionGate:
      "Implement the approved fix, add regression tests, run the declared validation gates, then request approval to proceed to `bug-verify`.",
    primaryObjective:
      "Implement the approved minimal safe fix with regression coverage and no unrelated refactoring.",
    currentStep:
      "Apply the approved changes from `analysis.md`, run format/lint/typecheck/tests, and prepare the hand-off to `bug-verify`.",
    dependencies: [
      "Approved `analysis.md` must exist.",
      "Regression coverage must target the original failure mode.",
    ],
    verification: [
      "Format, lint, typecheck, and relevant tests pass.",
      "Regression coverage demonstrates the original bug path is fixed.",
      "The change log and gate results are ready for `bug-verify`.",
    ],
  },
  "bug-verify": {
    transitionGate:
      "The original repro, regression checks, project validation gates, and scoped audit gate all pass before closure.",
    primaryObjective:
      "Verify the bug fix end-to-end, record closure evidence, and prepare the bug for closure.",
    currentStep:
      "Re-run the original repro, confirm edge cases and regressions, write `verification.md`, and record audit/archive status.",
    dependencies: [
      "`report.md` and `analysis.md` must be available to drive verification.",
      "The fix must already be implemented before verification begins.",
    ],
    verification: [
      "Original repro passes after the fix and clearly failed before it.",
      "Regression and edge-case testing are documented in `verification.md`.",
      "Project validation gates and the scoped audit gate pass before closure.",
    ],
  },
};

export const StageAwareCompactionPlugin: Plugin = async ({
  directory,
  worktree,
}) => {
  const root = worktree || directory;

  return {
    "experimental.session.compacting": async (_input, output) => {
      const snapshot = await readWorkflowSnapshot(root);
      const workflowState = await buildWorkflowState(root, snapshot);

      output.context.push(renderContinuationContext(workflowState));
    },
  };
};

export default StageAwareCompactionPlugin;

export async function buildWorkflowState(
  root: string,
  snapshot?: WorkflowSnapshot,
): Promise<WorkflowState> {
  const resolvedSnapshot = snapshot ?? (await readWorkflowSnapshot(root));
  const stageHint = findLatestStageMention(
    [resolvedSnapshot.sessionText, resolvedSnapshot.agentsText].join("\n"),
  );

  if (stageHint?.startsWith("spec-")) {
    const activeSpec = await pickActiveArtifactDirectory(
      root,
      resolvedSnapshot,
      "spec",
    );
    if (activeSpec) {
      return buildSpecWorkflowState(
        root,
        activeSpec,
        resolvedSnapshot,
        stageHint as SpecStage,
      );
    }
  }

  if (stageHint?.startsWith("bug-")) {
    const activeBug = await pickActiveArtifactDirectory(
      root,
      resolvedSnapshot,
      "bug",
    );
    if (activeBug) {
      return buildBugWorkflowState(
        root,
        activeBug,
        resolvedSnapshot,
        stageHint as BugStage,
      );
    }
  }

  const activeSpec = await pickActiveArtifactDirectory(
    root,
    resolvedSnapshot,
    "spec",
  );
  if (activeSpec) {
    return buildSpecWorkflowState(root, activeSpec, resolvedSnapshot);
  }

  const activeBug = await pickActiveArtifactDirectory(
    root,
    resolvedSnapshot,
    "bug",
  );
  if (activeBug) {
    return buildBugWorkflowState(root, activeBug, resolvedSnapshot);
  }

  const blockers = collectBlockers(resolvedSnapshot.sessionText);
  const activeFiles = collectActiveFiles(resolvedSnapshot.sessionText, []);

  return {
    workflowType: "unknown",
    canonicalStage: "uncertain",
    sourceArtifacts: [],
    currentArtifact:
      "No active `.codex/specs/` or `.codex/bugs/` artifact detected.",
    artifactStatus: "No workflow artifact is active in the current worktree.",
    transitionGate:
      "Uncertain — no canonical spec or bug workflow artifact was detected.",
    primaryObjective:
      "Resume from the most recent session state without inventing a broader memory system.",
    currentStep:
      "Inspect `SESSION.md` and the latest `.codex/` artifacts to re-establish workflow state.",
    status:
      blockers.length > 0
        ? "At risk — blockers recorded in `SESSION.md`."
        : "Uncertain — workflow state not detected.",
    completed: [],
    remaining: [
      "Determine whether the session should be on the spec workflow or the bug workflow.",
      "Identify the current canonical stage from the active artifact.",
    ],
    decisions: [],
    approvedDecisions: [],
    pendingDecisions: ["Active workflow and stage are uncertain."],
    dependencies: [
      "`SESSION.md` and `.codex/` artifacts need to be refreshed.",
    ],
    activeFiles,
    blockers,
    verification: [
      "Do not continue execution until the active workflow and artifact are clear.",
    ],
    nextAction:
      "Read `SESSION.md`, inspect `.codex/specs/` and `.codex/bugs/`, and re-enter the correct canonical workflow stage.",
  };
}

export function renderContinuationContext(state: WorkflowState): string {
  const sections: Array<[string, string[]]> = [
    ["Workflow Type", [state.workflowType]],
    ["Canonical Workflow Stage", [state.canonicalStage]],
    ["Source Artifacts", state.sourceArtifacts],
    ["Current Artifact", [state.currentArtifact]],
    ["Artifact Status", [state.artifactStatus]],
    ["Transition Gate", [state.transitionGate]],
    ["Primary Objective", [state.primaryObjective]],
    ["Current Step", [state.currentStep]],
    ["Status", [state.status]],
    ["Completed", state.completed],
    ["Remaining", state.remaining],
    ["Decisions", state.decisions],
    ["Approved Decisions", state.approvedDecisions],
    ["Pending Decisions / Open Questions", state.pendingDecisions],
    ["Dependencies / Preconditions", state.dependencies],
    ["Active Files", state.activeFiles],
    ["Blockers / Risks", state.blockers],
    ["Verification / Done Criteria", state.verification],
    ["Next Action", [state.nextAction]],
  ];

  return [
    "## Stage-Aware Continuation",
    "Preserve the canonical workflow names exactly. Treat this as the authoritative resume brief for compaction continuity.",
    ...sections.flatMap(([title, values]) => renderSection(title, values)),
  ].join("\n");
}

async function readWorkflowSnapshot(root: string): Promise<WorkflowSnapshot> {
  return {
    sessionText: (await readTextFile(path.join(root, "SESSION.md"))) ?? "",
    agentsText: (await readTextFile(path.join(root, "AGENTS.md"))) ?? "",
    specDirectories: await listArtifactDirectories(
      path.join(root, ".codex", "specs"),
    ),
    bugDirectories: await listArtifactDirectories(
      path.join(root, ".codex", "bugs"),
    ),
  };
}

async function buildSpecWorkflowState(
  root: string,
  artifact: ArtifactDirectory,
  snapshot: WorkflowSnapshot,
  stageHint?: SpecStage,
): Promise<WorkflowState> {
  const requirementsPath = path.join(artifact.path, "requirements.md");
  const designPath = path.join(artifact.path, "design.md");
  const tasksPath = path.join(artifact.path, "tasks.md");
  const contextPath = path.join(artifact.path, "context.md");
  const harnessPath = path.join(artifact.path, "harness", "feature_list.json");

  const [requirementsText, designText, tasksText, contextText, harnessText] =
    await Promise.all([
      readTextFile(requirementsPath),
      readTextFile(designPath),
      readTextFile(tasksPath),
      readTextFile(contextPath),
      readTextFile(harnessPath),
    ]);

  const sourceArtifacts = existingPaths([
    relativeToRoot(root, requirementsPath, requirementsText),
    relativeToRoot(root, designPath, designText),
    relativeToRoot(root, tasksPath, tasksText),
    relativeToRoot(root, contextPath, contextText),
    relativeToRoot(root, harnessPath, harnessText),
  ]);

  const taskProgress = parseTaskProgress(tasksText ?? "");
  const stage =
    stageHint ??
    detectSpecStage({
      requirementsText,
      designText,
      tasksText,
      contextText,
    });
  const details = SPEC_STAGE_DETAILS[stage];
  const currentArtifact =
    stage === "spec-create"
      ? relativeToRoot(root, requirementsPath, requirementsText)
      : stage === "spec-design"
        ? relativeToRoot(root, designPath, designText)
        : relativeToRoot(root, tasksPath, tasksText);
  const status = buildSpecStatus(
    stage,
    artifact.name,
    taskProgress,
    contextText ?? "",
  );
  const completed = buildSpecCompleted(
    stage,
    taskProgress,
    requirementsText,
    designText,
    tasksText,
    contextText,
  );
  const remaining = buildSpecRemaining(stage, taskProgress, artifact.name);
  const decisions = extractContextDecisions(contextText ?? "");
  const approvedDecisions = inferSpecApprovals(stage, artifact.name);
  const pendingDecisions = buildPendingDecisions(
    stage,
    snapshot.sessionText,
    artifact.name,
  );
  const blockers = collectBlockers(snapshot.sessionText, contextText ?? "");
  const activeFiles = collectActiveFiles(snapshot.sessionText, sourceArtifacts);
  const nextAction =
    stage === "spec-execute" && taskProgress.nextTask
      ? `Resume ${artifact.name} in ${stage}: ${taskProgress.nextTask}.`
      : details.currentStep;

  return {
    workflowType: "spec",
    canonicalStage: stage,
    sourceArtifacts,
    currentArtifact,
    artifactStatus: buildSpecArtifactStatus(stage, taskProgress, artifact.name),
    transitionGate: details.transitionGate,
    primaryObjective: details.primaryObjective,
    currentStep:
      stage === "spec-execute" && taskProgress.nextTask
        ? `Continue the current implementation lane in ${taskProgress.currentBatch ?? "the active batch"}: ${taskProgress.nextTask}.`
        : details.currentStep,
    status,
    completed,
    remaining,
    decisions,
    approvedDecisions,
    pendingDecisions,
    dependencies: details.dependencies,
    activeFiles,
    blockers,
    verification: details.verification,
    nextAction,
  };
}

async function buildBugWorkflowState(
  root: string,
  artifact: ArtifactDirectory,
  snapshot: WorkflowSnapshot,
  stageHint?: BugStage,
): Promise<WorkflowState> {
  const reportPath = path.join(artifact.path, "report.md");
  const analysisPath = path.join(artifact.path, "analysis.md");
  const verificationPath = path.join(artifact.path, "verification.md");
  const progressPath = path.join(artifact.path, "harness", "progress.md");
  const statePath = path.join(artifact.path, "harness", "bug_state.json");

  const [reportText, analysisText, verificationText, progressText, stateText] =
    await Promise.all([
      readTextFile(reportPath),
      readTextFile(analysisPath),
      readTextFile(verificationPath),
      readTextFile(progressPath),
      readTextFile(statePath),
    ]);

  const sourceArtifacts = existingPaths([
    relativeToRoot(root, reportPath, reportText),
    relativeToRoot(root, analysisPath, analysisText),
    relativeToRoot(root, verificationPath, verificationText),
    relativeToRoot(root, progressPath, progressText),
    relativeToRoot(root, statePath, stateText),
  ]);

  const stage =
    stageHint ??
    detectBugStage({
      reportText,
      analysisText,
      verificationText,
      progressText,
      stateText,
    });
  const details = BUG_STAGE_DETAILS[stage];
  const currentArtifact =
    stage === "bug-create"
      ? relativeToRoot(root, reportPath, reportText)
      : stage === "bug-analyze"
        ? relativeToRoot(root, analysisPath, analysisText)
        : stage === "bug-fix"
          ? relativeToRoot(root, analysisPath, analysisText)
          : relativeToRoot(root, verificationPath, verificationText);
  const decisions = extractLinesFromSections(analysisText ?? "", [
    "Risks / Trade-offs",
    "Decision",
    "Decisions",
  ]);
  const approvedDecisions = inferBugApprovals(stage, artifact.name);
  const pendingDecisions = buildPendingDecisions(
    stage,
    snapshot.sessionText,
    artifact.name,
  );
  const blockers = collectBlockers(snapshot.sessionText, progressText ?? "");
  const activeFiles = collectActiveFiles(snapshot.sessionText, sourceArtifacts);
  const nextAction =
    stage === "bug-fix"
      ? `Implement the approved minimal fix for ${artifact.name}, add regression coverage, and prepare the hand-off to bug-verify.`
      : details.currentStep;

  return {
    workflowType: "bug",
    canonicalStage: stage,
    sourceArtifacts,
    currentArtifact,
    artifactStatus: buildBugArtifactStatus(
      stage,
      artifact.name,
      progressText ?? "",
      stateText ?? "",
    ),
    transitionGate: details.transitionGate,
    primaryObjective: details.primaryObjective,
    currentStep: details.currentStep,
    status: buildBugStatus(stage, artifact.name, progressText ?? ""),
    completed: buildBugCompleted(
      stage,
      reportText,
      analysisText,
      verificationText,
      progressText,
    ),
    remaining: buildBugRemaining(stage),
    decisions,
    approvedDecisions,
    pendingDecisions,
    dependencies: details.dependencies,
    activeFiles,
    blockers,
    verification: details.verification,
    nextAction,
  };
}

function detectSpecStage(input: {
  requirementsText: string | null;
  designText: string | null;
  tasksText: string | null;
  contextText: string | null;
}): SpecStage {
  if (
    hasTaskCheckboxes(input.tasksText) ||
    hasExecutionContextMarkers(input.contextText)
  ) {
    return "spec-execute";
  }
  if (hasMeaningfulContent(input.tasksText)) {
    return "spec-tasks";
  }
  if (hasMeaningfulContent(input.designText)) {
    return "spec-design";
  }
  return "spec-create";
}

function detectBugStage(input: {
  reportText: string | null;
  analysisText: string | null;
  verificationText: string | null;
  progressText: string | null;
  stateText: string | null;
}): BugStage {
  if (
    hasMeaningfulContent(input.verificationText) ||
    /bug-verify/i.test(input.progressText ?? "")
  ) {
    return "bug-verify";
  }
  if (/bug-fix/i.test(input.progressText ?? "")) {
    return "bug-fix";
  }
  if (hasMeaningfulContent(input.reportText)) {
    return hasMeaningfulContent(input.analysisText)
      ? "bug-analyze"
      : "bug-create";
  }
  return "bug-create";
}

async function pickActiveArtifactDirectory(
  root: string,
  snapshot: WorkflowSnapshot,
  workflowType: "spec" | "bug",
): Promise<ArtifactDirectory | null> {
  const directories =
    workflowType === "spec"
      ? snapshot.specDirectories
      : snapshot.bugDirectories;
  if (directories.length === 0) {
    return null;
  }

  const hint = findMentionedArtifactName(snapshot.sessionText, workflowType);
  if (hint) {
    const exactMatch = directories.find((entry) => entry.name === hint);
    if (exactMatch) {
      return exactMatch;
    }
  }

  const scored = await Promise.all(
    directories.map(async (entry) => ({
      entry,
      score: await scoreArtifactDirectory(
        snapshot.sessionText,
        workflowType,
        entry,
      ),
    })),
  );

  scored.sort(
    (left, right) =>
      right.score - left.score ||
      right.entry.modifiedAtMs - left.entry.modifiedAtMs,
  );
  return scored[0]?.entry ?? null;
}

async function scoreArtifactDirectory(
  sessionText: string,
  workflowType: "spec" | "bug",
  artifact: ArtifactDirectory,
): Promise<number> {
  let score = artifact.modifiedAtMs;

  if (
    sessionText.includes(artifact.name) ||
    sessionText.includes(`.codex/${workflowType}s/${artifact.name}`)
  ) {
    score += 1_000_000_000_000;
  }

  const primaryFile =
    workflowType === "spec"
      ? path.join(artifact.path, "tasks.md")
      : path.join(artifact.path, "analysis.md");
  const primaryText = await readTextFile(primaryFile);
  if (hasMeaningfulContent(primaryText)) {
    score += 10_000;
  }

  const secondaryFile =
    workflowType === "spec"
      ? path.join(artifact.path, "context.md")
      : path.join(artifact.path, "verification.md");
  const secondaryText = await readTextFile(secondaryFile);
  if (hasMeaningfulContent(secondaryText)) {
    score += 1_000;
  }

  return score;
}

async function listArtifactDirectories(
  directoryPath: string,
): Promise<ArtifactDirectory[]> {
  let entries;
  try {
    entries = await fs.readdir(directoryPath, { withFileTypes: true });
  } catch {
    return [];
  }

  const directories = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory() && entry.name !== "attic")
      .map(async (entry) => {
        const artifactPath = path.join(directoryPath, entry.name);
        const stats = await fs.stat(artifactPath);

        return {
          name: entry.name,
          path: artifactPath,
          modifiedAtMs: stats.mtimeMs,
        } satisfies ArtifactDirectory;
      }),
  );

  directories.sort((left, right) => right.modifiedAtMs - left.modifiedAtMs);
  return directories;
}

async function readTextFile(filePath: string): Promise<string | null> {
  try {
    return await fs.readFile(filePath, "utf8");
  } catch {
    return null;
  }
}

function parseTaskProgress(tasksText: string): TaskProgress {
  const lines = tasksText.split(/\r?\n/);
  let currentBatch: string | null = null;
  const completedItems: string[] = [];
  const remainingItems: string[] = [];

  for (const line of lines) {
    const batchMatch = line.match(/^##\s+Batch\s+(.+)$/);
    if (batchMatch) {
      currentBatch = batchMatch[1].trim();
      continue;
    }

    const taskMatch = line.match(/^- \[( |x)\] ([0-9.]+)\. (.+)$/);
    if (!taskMatch) {
      continue;
    }

    const [, marker, taskId, title] = taskMatch;
    const summary = `${taskId} — ${title}${currentBatch ? ` (${currentBatch})` : ""}`;

    if (marker === "x") {
      completedItems.push(summary);
    } else {
      remainingItems.push(summary);
    }
  }

  return {
    completedCount: completedItems.length,
    remainingCount: remainingItems.length,
    nextTask: remainingItems[0] ?? null,
    currentBatch: remainingItems[0]?.match(/\((.+)\)$/)?.[1] ?? null,
    completedItems: completedItems.slice(0, 4),
    remainingItems: remainingItems.slice(0, 4),
  };
}

function findLatestStageMention(text: string): CanonicalStage | null {
  let latestIndex = -1;
  let latestStage: CanonicalStage | null = null;

  for (const stage of CANONICAL_STAGES) {
    const index = text.lastIndexOf(stage);
    if (index > latestIndex) {
      latestIndex = index;
      latestStage = stage;
    }
  }

  return latestStage;
}

function findMentionedArtifactName(
  text: string,
  workflowType: "spec" | "bug",
): string | null {
  const pathRegex = new RegExp(
    `\\.codex/${workflowType}s/([^/\\s` + "`" + `]+)`,
    "g",
  );
  let match: RegExpExecArray | null;
  let lastMatch: string | null = null;

  while ((match = pathRegex.exec(text)) !== null) {
    lastMatch = match[1] ?? null;
  }

  if (lastMatch) {
    return lastMatch;
  }

  const commandRegex =
    workflowType === "spec"
      ? /\/spec-(?:create|design|tasks|execute)(?:\s+next|\s+batch\s+\d+)?\s+([^\s`]+)/g
      : /\/bug-(?:create|analyze|fix|verify)\s+([^\s`]+)/g;
  let commandMatch: RegExpExecArray | null;
  while ((commandMatch = commandRegex.exec(text)) !== null) {
    lastMatch = commandMatch[1] ?? null;
  }

  return lastMatch;
}

function buildSpecArtifactStatus(
  stage: SpecStage,
  progress: TaskProgress,
  specName: string,
): string {
  if (stage === "spec-execute") {
    return progress.remainingCount > 0
      ? `${specName}: ${progress.completedCount} task(s) complete, ${progress.remainingCount} remaining; next task is ${progress.nextTask ?? "uncertain"}.`
      : `${specName}: all tracked tasks are complete; confirm whether the spec is ready for closure.`;
  }

  return `${specName}: current artifact for ${stage} is present; approval state should be confirmed from the latest session context.`;
}

function buildBugArtifactStatus(
  stage: BugStage,
  bugName: string,
  progressText: string,
  stateText: string,
): string {
  const stateSummary = cleanLine(
    firstNonEmptyLine(stateText) ?? firstNonEmptyLine(progressText) ?? "",
  );
  if (stateSummary) {
    return `${bugName}: ${stateSummary}`;
  }

  return `${bugName}: current artifact for ${stage} is present; confirmation from the latest session context may still be required.`;
}

function buildSpecStatus(
  stage: SpecStage,
  specName: string,
  progress: TaskProgress,
  contextText: string,
): string {
  if (stage === "spec-execute") {
    const lastCompletedBatch = extractField(
      contextText,
      "Last completed batch",
    );
    const batchNote = lastCompletedBatch
      ? ` Last completed batch: ${lastCompletedBatch}.`
      : "";

    return `${specName} is in ${stage}; ${progress.completedCount} task(s) complete and ${progress.remainingCount} task(s) remaining.${batchNote}`;
  }

  return `${specName} is active in ${stage}; preserve the artifact and approval state without widening scope.`;
}

function buildBugStatus(
  stage: BugStage,
  bugName: string,
  progressText: string,
): string {
  const progressSummary = cleanLine(firstNonEmptyLine(progressText) ?? "");
  if (progressSummary) {
    return `${bugName} is in ${stage}; harness progress notes: ${progressSummary}`;
  }

  return `${bugName} is active in ${stage}; preserve the minimal safe-fix workflow and current verification intent.`;
}

function buildSpecCompleted(
  stage: SpecStage,
  progress: TaskProgress,
  requirementsText: string | null,
  designText: string | null,
  tasksText: string | null,
  contextText: string | null,
): string[] {
  const completed: string[] = [];
  if (hasMeaningfulContent(requirementsText) && stage !== "spec-create") {
    completed.push(
      "`requirements.md` exists and later-stage artifacts imply the requirements phase is complete.",
    );
  }
  if (
    hasMeaningfulContent(designText) &&
    (stage === "spec-tasks" || stage === "spec-execute")
  ) {
    completed.push(
      "`design.md` exists and later-stage artifacts imply design approval was completed.",
    );
  }
  if (hasMeaningfulContent(tasksText) && stage === "spec-execute") {
    completed.push("`tasks.md` exists and execution has started.");
  }
  completed.push(...progress.completedItems);
  completed.push(...extractContextDiscoveries(contextText ?? ""));

  return uniqueLimited(completed, 5);
}

function buildSpecRemaining(
  stage: SpecStage,
  progress: TaskProgress,
  specName: string,
): string[] {
  if (stage === "spec-execute") {
    const remaining = [...progress.remainingItems];
    if (remaining.length === 0) {
      remaining.push(
        `Confirm whether ${specName} is ready for final completion handling.`,
      );
    }
    return uniqueLimited(remaining, 5);
  }

  return uniqueLimited(
    [
      SPEC_STAGE_DETAILS[stage].currentStep,
      `Preserve explicit approval before moving beyond ${stage}.`,
    ],
    4,
  );
}

function buildBugCompleted(
  stage: BugStage,
  reportText: string | null,
  analysisText: string | null,
  verificationText: string | null,
  progressText: string | null,
): string[] {
  const completed: string[] = [];
  if (hasMeaningfulContent(reportText) && stage !== "bug-create") {
    completed.push(
      "`report.md` exists and the bug is documented well enough to move beyond `bug-create`.",
    );
  }
  if (
    hasMeaningfulContent(analysisText) &&
    (stage === "bug-fix" || stage === "bug-verify")
  ) {
    completed.push(
      "`analysis.md` exists and later-stage artifacts imply the fix plan was approved.",
    );
  }
  if (hasMeaningfulContent(verificationText) && stage === "bug-verify") {
    completed.push("`verification.md` already contains verification evidence.");
  }
  completed.push(...extractBulletLines(progressText ?? ""));

  return uniqueLimited(completed, 5);
}

function buildBugRemaining(stage: BugStage): string[] {
  return uniqueLimited(
    [
      BUG_STAGE_DETAILS[stage].currentStep,
      `Preserve explicit workflow approval semantics around ${stage}.`,
    ],
    4,
  );
}

function inferSpecApprovals(stage: SpecStage, specName: string): string[] {
  const approvals: string[] = [];
  if (stage !== "spec-create") {
    approvals.push(
      `${specName}: approval of \`requirements.md\` is inferred from the presence of later spec artifacts.`,
    );
  }
  if (stage === "spec-tasks" || stage === "spec-execute") {
    approvals.push(
      `${specName}: approval of \`design.md\` is inferred from the presence of later spec artifacts.`,
    );
  }
  if (stage === "spec-execute") {
    approvals.push(
      `${specName}: \`tasks.md\` is treated as approved because execution artifacts are present.`,
    );
  }

  return uniqueLimited(approvals, 4);
}

function inferBugApprovals(stage: BugStage, bugName: string): string[] {
  const approvals: string[] = [];
  if (stage !== "bug-create") {
    approvals.push(
      `${bugName}: approval of \`report.md\` is inferred from the presence of later bug artifacts.`,
    );
  }
  if (stage === "bug-fix" || stage === "bug-verify") {
    approvals.push(
      `${bugName}: approval of \`analysis.md\` is inferred from the presence of later bug artifacts.`,
    );
  }
  if (stage === "bug-verify") {
    approvals.push(
      `${bugName}: the fix stage is assumed complete enough to start verification.`,
    );
  }

  return uniqueLimited(approvals, 4);
}

function buildPendingDecisions(
  stage: CanonicalStage,
  sessionText: string,
  artifactName: string,
): string[] {
  const pending = extractApprovalLines(sessionText);
  if (pending.length === 0) {
    if (
      stage === "spec-create" ||
      stage === "spec-design" ||
      stage === "spec-tasks"
    ) {
      pending.push(
        `${artifactName}: explicit user approval is still required before advancing beyond ${stage}.`,
      );
    }
    if (stage === "bug-create" || stage === "bug-analyze") {
      pending.push(
        `${artifactName}: explicit user approval is still required before advancing beyond ${stage}.`,
      );
    }
    if (stage === "bug-fix") {
      pending.push(
        `${artifactName}: request approval to proceed to \`bug-verify\` after gates are green.`,
      );
    }
  }

  return uniqueLimited(pending, 4);
}

function collectBlockers(...texts: string[]): string[] {
  const blockers = texts.flatMap((text) =>
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(
        (line) =>
          line.startsWith("- Blockers:") ||
          line.startsWith("Blockers:") ||
          line.includes("BLOCKED") ||
          line.includes("blocked"),
      ),
  );

  return uniqueLimited(blockers.map(cleanLine), 4);
}

function collectActiveFiles(
  sessionText: string,
  sourceArtifacts: string[],
): string[] {
  const matches = [...sessionText.matchAll(/`([^`]+)`/g)]
    .map((match) => match[1])
    .filter((value): value is string => Boolean(value))
    .filter(isLikelyFilePath);

  return uniqueLimited([...sourceArtifacts, ...matches], 6);
}

function extractContextDecisions(contextText: string): string[] {
  return uniqueLimited(
    extractLinesFromSections(contextText, ["Decisions Made"]),
    4,
  );
}

function extractContextDiscoveries(contextText: string): string[] {
  return uniqueLimited(
    extractLinesFromSections(contextText, ["Key Discoveries"]),
    2,
  );
}

function extractLinesFromSections(text: string, headings: string[]): string[] {
  const lines: string[] = [];
  for (const heading of headings) {
    const section = extractMarkdownSection(text, heading);
    if (!section) {
      continue;
    }
    lines.push(...extractBulletLines(section));
  }
  return uniqueLimited(lines, 4);
}

function extractMarkdownSection(text: string, heading: string): string {
  const escapedHeading = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const regex = new RegExp(
    `^##\\s+${escapedHeading}\\s*$\\n?([\\s\\S]*?)(?=^##\\s+|$)`,
    "im",
  );
  const match = text.match(regex);
  return match?.[1]?.trim() ?? "";
}

function extractBulletLines(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("- ") || /^\d+\.\s+/.test(line))
    .map(cleanLine)
    .filter(Boolean);
}

function extractApprovalLines(text: string): string[] {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => /approval|approved/i.test(line))
    .map(cleanLine)
    .filter(Boolean)
    .slice(0, 4);
}

function extractField(text: string, fieldName: string): string | null {
  const regex = new RegExp(`^${fieldName}:\\s*(.+)$`, "im");
  const match = text.match(regex);
  return match?.[1]?.trim() ?? null;
}

function relativeToRoot(
  root: string,
  filePath: string,
  text: string | null,
): string {
  return text === null ? "" : path.relative(root, filePath);
}

function existingPaths(paths: string[]): string[] {
  return paths.filter(Boolean);
}

function renderSection(title: string, values: string[]): string[] {
  const lines = values.length > 0 ? values : ["none recorded"];
  return [``, `## ${title}`, ...lines.map((line) => `- ${line}`)];
}

function hasMeaningfulContent(text: string | null): boolean {
  return Boolean(text && text.trim().replace(/[#\-\s`_*]/g, "").length > 0);
}

function hasTaskCheckboxes(text: string | null): boolean {
  return /- \[(?: |x)\] /.test(text ?? "");
}

function hasExecutionContextMarkers(text: string | null): boolean {
  if (!text) {
    return false;
  }

  return (
    /Last completed batch:/i.test(text) ||
    /Remaining batches:/i.test(text) ||
    /^##\s+Key Discoveries$/im.test(text) ||
    /^##\s+Decisions Made$/im.test(text) ||
    /\[Batch\s+\d+\]/.test(text)
  );
}

function firstNonEmptyLine(text: string): string | null {
  return (
    text
      .split(/\r?\n/)
      .map((line) => line.trim())
      .find(Boolean) ?? null
  );
}

function cleanLine(line: string): string {
  return line
    .replace(/^[-*]\s*/, "")
    .replace(/^\d+\.\s*/, "")
    .trim();
}

function isLikelyFilePath(value: string): boolean {
  return (
    value.startsWith(".codex/") ||
    value.startsWith("src/") ||
    value.startsWith("tests/") ||
    value.startsWith("steering/") ||
    value === "SESSION.md" ||
    value === "AGENTS.md" ||
    /\.[a-z0-9]+$/i.test(value)
  );
}

function uniqueLimited(values: string[], limit: number): string[] {
  return [...new Set(values.filter(Boolean))].slice(0, limit);
}
