# Session State

<!-- STATUS TABLE — one row per active agent. Keep this current at every checkpoint.
     Locks: list files/dirs claimed exclusively; other agents must not edit them.
     Use "—" for empty Locks or Next Gate. Remove rows when work is merged + done. -->

| Agent | Focus | Worktree | Last Checkpoint | Next Gate | Locks | Updated |
| --- | --- | --- | --- | --- | --- | --- |
| codex | <focus-area> | `<absolute-worktree-path>` | <what was last completed> | <next command or gate to run> | `<file-or-dir>`, `SESSION.md` | YYYY-MM-DDTHH:MM:SSZ |

---

<!-- SESSION LOG — prepend new entries; do not delete old ones.
     Format: [Focus: <area>] YYYY-MM-DD — Branch `<branch>` -->

[Focus: <focus-area>] YYYY-MM-DD — Branch `<branch-name>`

- <What was done — key changes, files touched, decisions made.>
- Validation gates: <commands run and results (✅/❌)>

Reality Check — tests rerun? ✅/❌; lint/analyze clean? ✅/❌; context refreshed? ✅/❌.

Next Operator Brief
- Open Work: <what is in progress or pending approval>
- Pending Tests: <any tests not yet run>
- Blockers: <anything blocking progress>
