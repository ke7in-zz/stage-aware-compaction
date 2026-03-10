# Ralph Audit Loop

Read-only autonomous code audit runner. Supports both OpenAI Codex CLI and
OpenCode CLI.

## Setup

1. Edit `prd.json` — define your audit stories (see Story Format below).
2. Edit `CODEX.md` — set your quality bar and safety rules.
3. Run: `./ralph.sh 20 --cli opencode`

## Quick start

```bash
cd .codex/ralph-audit

# Run with OpenCode (Claude)
./ralph.sh 20 --cli opencode

# Run with Codex (GPT)
./ralph.sh 20 --cli codex

# Override model
RALPH_MODEL=anthropic/claude-sonnet-4-6 ./ralph.sh 10 --cli opencode

# Context-scoped run (only stories relevant to a spec/bug folder)
bash ./run_for_context.sh ./.codex/specs/<spec-name>

# Dry run
DRY_RUN=true bash ./run_for_context.sh ./.codex/specs/<spec-name>
```

## Story format (prd.json)

```json
{
  "title": "Ralph Audit — My Project",
  "userStories": [
    {
      "id": "SA-01",
      "title": "Auth flow audit",
      "description": "Audit the authentication and session management flow.",
      "notes": "Focus: token refresh, session expiry, RBAC enforcement.",
      "acceptanceCriteria": [
        "Created .codex/ralph-audit/audit/01-auth-flow.md",
        "All findings include file:line references",
        "Severity classified for each finding"
      ],
      "ownedPaths": [
        "src/services/auth_service.ts",
        "src/middleware/auth.ts"
      ],
      "passes": false,
      "priority": 1
    }
  ]
}
```

## Logs

```bash
tail -f events.log    # high-level progress
tail -f run.log       # full agent output
```

## Archive completed reports

```bash
bash ./archive_reports.sh          # archive passed stories
bash ./archive_reports.sh --all    # archive everything
```

## Customise

- `prd.json` — your audit stories and file ownership
- `CODEX.md` — quality bar and report structure
- Model/effort in `ralph.sh` or via env vars (`RALPH_MODEL`, `REASONING_EFFORT`)
