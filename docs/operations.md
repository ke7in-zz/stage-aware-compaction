# Operations

## Installation

### Project-level (one repo)

Place the plugin source in `.opencode/plugins/`:

```bash
mkdir -p .opencode/plugins
cp path/to/stage-aware-compaction/src/stage-aware-compaction.ts \
   .opencode/plugins/stage-aware-compaction.ts
```

OpenCode loads all `.ts` and `.js` files from `.opencode/plugins/` automatically
at startup. No `opencode.json` changes are needed.

### Global (all sessions on this machine)

Copy the plugin source into the global plugin directory:

```bash
mkdir -p ~/.config/opencode/plugins
cp path/to/stage-aware-compaction/src/stage-aware-compaction.ts \
   ~/.config/opencode/plugins/stage-aware-compaction.ts
```

Ensure `~/.config/opencode/package.json` includes the types dependency (OpenCode
will run `bun install` at startup):

```json
{
  "dependencies": {
    "@opencode-ai/plugin": "1.2.24"
  }
}
```

The global plugin fires for every OpenCode session on the machine. For sessions
in repos without `.codex/specs/` or `.codex/bugs/` it operates in generic mode,
extracting state from `SESSION.md` only.

### Updating

The plugin is a single self-contained `.ts` file. To update, overwrite it:

```bash
# Project-level
cp path/to/stage-aware-compaction/src/stage-aware-compaction.ts \
   .opencode/plugins/stage-aware-compaction.ts

# Global
cp path/to/stage-aware-compaction/src/stage-aware-compaction.ts \
   ~/.config/opencode/plugins/stage-aware-compaction.ts
```

Then restart OpenCode. No build step is required.

---

## Verifying the plugin loaded

After starting OpenCode, grep the log:

```bash
grep "stage-aware-compaction" ~/.local/share/opencode/log/*.log
```

Expected output on successful load:

```
level=INFO service=plugin path=file:///path/to/.opencode/plugins/stage-aware-compaction.ts loading plugin
```

If this line is absent, the file is not in the right directory or has a syntax
error — see [Troubleshooting](#troubleshooting).

---

## Reading compaction logs

Every compaction event produces a log entry. Filter to see them:

```bash
grep '"service":"stage-aware-compaction"' ~/.local/share/opencode/log/*.log
```

Or, if logs are plaintext:

```bash
grep 'service=stage-aware-compaction' ~/.local/share/opencode/log/*.log
```

### Normal output (info)

```json
{
  "service": "stage-aware-compaction",
  "level": "info",
  "message": "compaction context injected",
  "sessionID": "ses_...",
  "mode": "workflow:spec/spec-execute",
  "artifact": ".codex/specs/my-spec/tasks.md"
}
```

`mode` values:

| Value                   | Meaning                                       |
| ----------------------- | --------------------------------------------- |
| `generic`               | No workflow detected; generic continuity only |
| `workflow:spec/<stage>` | Spec workflow detected at `<stage>`           |
| `workflow:bug/<stage>`  | Bug workflow detected at `<stage>`            |

### Warning: no session state

```json
{
  "service": "stage-aware-compaction",
  "level": "warn",
  "message": "compaction fired with no session state detected",
  "sessionID": "ses_...",
  "mode": "generic",
  "root": "/path/to/project"
}
```

Means `SESSION.md` was empty, missing, or contained no parseable state. The
plugin still ran but had little to inject. Consider adding a `[Focus: ...]`
session log entry to `SESSION.md`.

### Error: hook failed

```json
{
  "service": "stage-aware-compaction",
  "level": "error",
  "message": "compaction hook failed — no context injected",
  "sessionID": "ses_...",
  "error": "<error message>",
  "root": "/path/to/project"
}
```

The plugin threw an unhandled exception. Compaction proceeded with the default
prompt only — no context was injected. The error message identifies what failed.

---

## Troubleshooting

### Plugin does not appear in logs

1. Check the file is in the right directory (`ls .opencode/plugins/` or
   `ls ~/.config/opencode/plugins/`).
2. Check for TypeScript syntax errors — OpenCode/Bun will fail to load a file with
   a parse error. Run `npx tsc --noEmit` in the `stage-aware-compaction` repo.
3. Check the full OpenCode log for load errors:
   ```bash
   grep "plugins" ~/.local/share/opencode/log/*.log | grep -i "error\|fail"
   ```

### Compaction fires but mode is always `generic`

The plugin is running but not detecting a workflow. Causes:

- No `.codex/specs/` or `.codex/bugs/` directories in the project root
- Directories exist but are empty (no subdirectories with artifact files)
- `SESSION.md` and `AGENTS.md` contain no canonical stage name mentions

Check:

```bash
ls .codex/specs/
ls .codex/bugs/
grep -E "spec-(create|design|tasks|execute)|bug-(create|analyze|fix|verify)" SESSION.md AGENTS.md
```

### Wrong stage detected

The stage detection is conservative by design. Common reasons for a stage
appearing lower than expected:

**`spec-execute` not detected when it should be:**
`context.md` must contain at least one execution marker:
`Last completed batch:`, `Remaining batches:`, `## Key Discoveries`,
`## Decisions Made`, or `[Batch N]`. Or `tasks.md` must contain `- [ ]` or
`- [x]` checkboxes.

**`bug-fix` not detected when it should be:**
`harness/progress.md` must contain the text `bug-fix`. The presence of
`analysis.md` alone is not sufficient — this is intentional to avoid premature
promotion during the draft analysis phase.

### Compaction summary does not reflect the injected context

The plugin is inject-only: the compaction model receives the injected text but
rewrites it in its own words. The summary will not be a verbatim copy of the
injected block — it will incorporate the signal. Verify by checking whether the
summary contains the correct workflow stage name, active artifact, and next action.

If the signal is not appearing at all, check that the compaction log entry shows
`mode=workflow:...` rather than `generic`.

### `@opencode-ai/plugin` not found (global install)

The global plugin directory needs a `package.json` with the dependency:

```bash
cat ~/.config/opencode/package.json
```

If missing or incomplete, add it and restart OpenCode to trigger `bun install`.

---

## Keeping the global plugin in sync

The deployed global plugin is a copy of `src/stage-aware-compaction.ts`. There
is no automatic sync. After pulling changes to the repo, redeploy:

```bash
cp /path/to/stage-aware-compaction/src/stage-aware-compaction.ts \
   ~/.config/opencode/plugins/stage-aware-compaction.ts
```

To check whether the deployed copy is current:

```bash
diff /path/to/stage-aware-compaction/src/stage-aware-compaction.ts \
     ~/.config/opencode/plugins/stage-aware-compaction.ts
```
