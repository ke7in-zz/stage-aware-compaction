#!/bin/bash
# Ralph Audit Loop - Long-running autonomous *read-only* audit loop.
# Supports both OpenAI Codex CLI and OpenCode CLI.
#
# Usage: ./ralph.sh [max_iterations] [--cli codex|opencode] [--skip-security-check] [--no-search]
#
# Writes all artifacts under `.codex/ralph-audit/` (PRD state, logs, and audit reports).

set -euo pipefail

# ─── Help ──────────────────────────────────────────────────────────────────────

show_help() {
  cat <<'HELPEOF'
Ralph Audit/Fix Loop — autonomous code audit and fix runner

USAGE
  ./ralph.sh [max_iterations] [OPTIONS]

OPTIONS
  --cli <backend>         CLI backend to use: codex | opencode  (default: codex)
  --mode <audit|fix>      Loop mode: audit (default) or fix
  --phase <1-6>           Fix mode only: restrict to findings in phase N (1-6)
  --model <model-id>      Override the model; takes precedence over RALPH_MODEL env var
  -m <model-id>           Short alias for --model
  --skip-security-check   Skip the credential-exposure pre-flight check
  --search                Enable agent search capability (default)
  --no-search             Disable agent search capability
  -h, --help              Show this help message and exit

POSITIONAL
  max_iterations          Number of audit/fix iterations to run (default: 20)

ENVIRONMENT VARIABLES
  RALPH_CLI               Default CLI backend (codex | opencode)
  RALPH_MODEL             Override the model used by the selected backend
  REASONING_EFFORT        Reasoning effort level: low | medium | high (default: medium)
  MAX_ATTEMPTS_PER_STORY  Circuit-breaker: max retries per story (default: 5)
  STORY_TIMEOUT_SECONDS   Watchdog timeout per story in seconds
                            Adaptive default: 1800s (≤2 paths), 3600s (3-4 paths),
                            5400s (≥5 paths). Set explicitly to override for all stories.
  STORY_FILTER_IDS        Comma-separated story IDs to restrict the run to
  TAIL_N                  Lines shown in tail commands (default: 200)

DEFAULT MODELS
  Backend       Model ID (codex fmt)    Model ID (opencode fmt)
  -----------   --------------------    -----------------------
  GPT 5.4       gpt-5.4                 openai/gpt-5.4
  Claude Opus   claude-opus-4-6         anthropic/claude-opus-4-6
  Claude Sonnet claude-sonnet-4-6       anthropic/claude-sonnet-4-6

  codex  default: gpt-5.4
  opencode default: anthropic/claude-opus-4-6

  Override with RALPH_MODEL, e.g.:
    RALPH_MODEL=openai/gpt-5.4 ./ralph.sh --cli opencode
    RALPH_MODEL=gpt-5.4        ./ralph.sh --cli codex

EXAMPLES
  # Run all 20 stories with Codex CLI (GPT 5.4)
  ./ralph.sh

  # Run 5 stories with OpenCode CLI (Claude Opus 4.6)
  ./ralph.sh 5 --cli opencode

  # Run with OpenCode targeting GPT 5.4 instead of Claude
  RALPH_MODEL=openai/gpt-5.4 ./ralph.sh --cli opencode

  # Run specific stories only
  STORY_FILTER_IDS=SA-01,SA-02 ./ralph.sh --cli codex

  # Skip security check (CI / sandboxed environments)
  ./ralph.sh --skip-security-check

  # Fix mode: run Phase 1 findings with OpenCode
  ./ralph.sh 20 --mode fix --phase 1 --cli opencode

  # Fix mode: retry specific stories
  STORY_FILTER_IDS=FIX-001,FIX-002 ./ralph.sh 1 --mode fix --cli opencode

  # Fix mode with explicit model and timeout
  ./ralph.sh 10 --mode fix --phase 2 -m anthropic/claude-sonnet-4-6 --cli opencode
HELPEOF
  exit 0
}

# ─── Defaults ──────────────────────────────────────────────────────────────────

MAX_ITERATIONS=20
MAX_ATTEMPTS_PER_STORY="${MAX_ATTEMPTS_PER_STORY:-5}"
STORY_TIMEOUT_SECONDS_ENV_SET="${STORY_TIMEOUT_SECONDS+set}"
STORY_TIMEOUT_SECONDS="${STORY_TIMEOUT_SECONDS:-1800}"
STORY_FILTER_IDS="$(echo "${STORY_FILTER_IDS:-}" | tr -d '[:space:]')"
SKIP_SECURITY="${SKIP_SECURITY_CHECK:-false}"
ENABLE_SEARCH="true"
TAIL_N="${TAIL_N:-200}"
RUN_MODE=""
FIX_PHASE=""

# CLI backend: "codex" (OpenAI Codex) or "opencode" (OpenCode / Anthropic)
CLI_BACKEND="${RALPH_CLI:-codex}"

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      ;;
    --cli)
      if [[ $# -lt 2 ]]; then
        echo "--cli requires a value: codex or opencode"
        exit 1
      fi
      CLI_BACKEND="$2"
      shift 2
      ;;
    -m|--model)
      if [[ $# -lt 2 ]]; then
        echo "--model requires a value (model ID)"
        exit 1
      fi
      RALPH_MODEL="$2"
      shift 2
      ;;
    --mode)
      if [[ $# -lt 2 ]]; then
        echo "--mode requires a value: audit or fix"
        exit 1
      fi
      RUN_MODE="$2"
      shift 2
      ;;
    --phase)
      if [[ $# -lt 2 ]]; then
        echo "--phase requires an integer"
        exit 1
      fi
      if [[ ! "$2" =~ ^[1-6]$ ]]; then
        echo "--phase must be an integer 1-6"
        exit 1
      fi
      FIX_PHASE="$2"
      shift 2
      ;;
    --skip-security-check)
      SKIP_SECURITY="true"
      shift
      ;;
    --search)
      ENABLE_SEARCH="true"
      shift
      ;;
    --no-search)
      ENABLE_SEARCH="false"
      shift
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
      fi
      shift
      ;;
  esac
done

RUN_MODE="${RUN_MODE:-audit}"
if [[ "$RUN_MODE" != "audit" && "$RUN_MODE" != "fix" ]]; then
  echo "ERROR: --mode must be 'audit' or 'fix'"
  exit 1
fi

if [[ "$CLI_BACKEND" != "codex" && "$CLI_BACKEND" != "opencode" ]]; then
  echo "ERROR: --cli must be 'codex' or 'opencode', got '$CLI_BACKEND'"
  exit 1
fi

if [[ "$SKIP_SECURITY" != "true" ]]; then
  echo ""
  echo "==============================================================="
  echo "  Security Pre-Flight Check"
  echo "==============================================================="
  echo ""

  SECURITY_WARNINGS=()

  if [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    SECURITY_WARNINGS+=("AWS_ACCESS_KEY_ID is set - production credentials may be exposed")
  fi

  if [[ -n "${DATABASE_URL:-}" ]]; then
    SECURITY_WARNINGS+=("DATABASE_URL is set - database credentials may be exposed")
  fi

  # Add project-specific credential checks here, e.g.:
  #   if [[ -n "${MY_SECRET:-}" ]]; then
  #     SECURITY_WARNINGS+=("MY_SECRET is set - credentials may be exposed")
  #   fi

  if [[ ${#SECURITY_WARNINGS[@]} -gt 0 ]]; then
    echo "WARNING: Potential credential exposure detected:"
    echo ""
    for warning in "${SECURITY_WARNINGS[@]}"; do
      echo "  - $warning"
    done
    echo ""
    echo "Running an autonomous agent with these credentials set could expose"
    echo "them in logs, commit messages, or API calls."
    echo ""
    echo "See your repo's security docs for sandboxing guidance."
    echo ""
    if [[ ! -t 0 ]]; then
      echo "ERROR: Non-interactive session with security warnings. Use --skip-security-check to bypass."
      exit 1
    fi
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborted. Unset credentials or use --skip-security-check to bypass."
      exit 1
    fi
  else
    echo "No credential exposure risks detected."
  fi
  echo ""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PRD_FILE="$SCRIPT_DIR/prd.json"
RUN_LOG="$SCRIPT_DIR/run.log"
EVENT_LOG="$SCRIPT_DIR/events.log"
MODEL_CHECK_LOG="$SCRIPT_DIR/.model-check.log"
PROGRESS_FILE="$SCRIPT_DIR/progress.txt"
LOCK_DIR="$SCRIPT_DIR/.run-lock"

mkdir -p "$SCRIPT_DIR/audit"

# ─── Story-empty guard ─────────────────────────────────────────────────────────
# Fail early if prd.json has no stories — prevents a confusing "no incomplete
# stories" exit on the very first iteration.
if [[ -f "$PRD_FILE" ]]; then
  STORY_COUNT="$(jq '.userStories | length' "$PRD_FILE" 2>/dev/null || echo 0)"
  if [[ "$STORY_COUNT" -eq 0 ]]; then
    echo "ERROR: prd.json has 0 stories. Add at least one story to .userStories[]."
    echo "       See README.md for the expected story format."
    exit 1
  fi
  echo "prd.json loaded: $STORY_COUNT stories."
else
  echo "ERROR: prd.json not found at $PRD_FILE"
  exit 1
fi

ATTEMPTS_FILE="$SCRIPT_DIR/.story-attempts"
LAST_STORY_FILE="$SCRIPT_DIR/.last-story"

if [ ! -f "$ATTEMPTS_FILE" ]; then
  echo "{}" > "$ATTEMPTS_FILE"
fi

get_current_story() {
  if [ -f "$PRD_FILE" ]; then
    if [[ -n "$STORY_FILTER_IDS" ]]; then
      jq -r '.userStories[] | select(.passes == false) | .id' "$PRD_FILE" 2>/dev/null \
        | while IFS= read -r candidate_id; do
            case ",$STORY_FILTER_IDS," in
              *",$candidate_id,"*)
                echo "$candidate_id"
                break
                ;;
            esac
          done
    else
      jq -r '.userStories[] | select(.passes == false) | .id' "$PRD_FILE" 2>/dev/null | head -1
    fi
  fi
}

get_story_attempts() {
  local story_id="$1"
  jq -r --arg id "$story_id" '.[$id] // 0' "$ATTEMPTS_FILE" 2>/dev/null || echo "0"
}

increment_story_attempts() {
  local story_id="$1"
  local current
  current=$(get_story_attempts "$story_id")
  local new_count=$((current + 1))
  jq --arg id "$story_id" --argjson count "$new_count" '.[$id] = $count' "$ATTEMPTS_FILE" > "$ATTEMPTS_FILE.tmp" \
    && mv "$ATTEMPTS_FILE.tmp" "$ATTEMPTS_FILE"
  echo "$new_count"
}

mark_story_skipped() {
  local story_id="$1"
  local max_attempts="$2"
  local note="Skipped: exceeded $max_attempts attempts without passing"
  jq --arg id "$story_id" --arg note "$note" '
    .userStories = [
      .userStories[]
      | if .id == $id then
          (.notes = $note) | (.passes = true) | (.skipped = true)
        else
          .
        end
    ]
  ' "$PRD_FILE" > "$PRD_FILE.tmp" && mv "$PRD_FILE.tmp" "$PRD_FILE"
  echo "Circuit breaker: Marked story $story_id as skipped after $max_attempts attempts"
}

check_circuit_breaker() {
  local story_id="$1"
  local attempts
  attempts=$(get_story_attempts "$story_id")

  if [ "$attempts" -ge "$MAX_ATTEMPTS_PER_STORY" ]; then
    echo "Circuit breaker: Story $story_id has reached max attempts ($attempts/$MAX_ATTEMPTS_PER_STORY)"
    mark_story_skipped "$story_id" "$MAX_ATTEMPTS_PER_STORY"
    return 0
  fi
  return 1
}

ts() {
  date '+%Y-%m-%dT%H:%M:%S%z'
}

log_event() {
  echo "[$(ts)] $*" >> "$EVENT_LOG"
}

on_script_exit() {
  local exit_code=$?
  /bin/rm -rf "$LOCK_DIR" 2>/dev/null || true
  log_event "RUN EXIT code=$exit_code"
}

get_story_title() {
  local story_id="$1"
  jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .title' "$PRD_FILE" 2>/dev/null || true
}

get_story_description() {
  local story_id="$1"
  jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | .description' "$PRD_FILE" 2>/dev/null || true
}

get_story_notes() {
  local story_id="$1"
  jq -r --arg id "$story_id" '.userStories[] | select(.id == $id) | (.notes // "")' "$PRD_FILE" 2>/dev/null || true
}

# compute_adaptive_timeout <story_id> <prd_file>
# Prints timeout in seconds. Respects STORY_TIMEOUT_SECONDS env override.
compute_adaptive_timeout() {
  local story_id="$1"
  local prd_file="$2"
  if [[ -n "${STORY_TIMEOUT_SECONDS_ENV_SET:-}" ]]; then
    echo "$STORY_TIMEOUT_SECONDS"
    return
  fi
  local path_count
  path_count="$(jq -r --arg id "$story_id" \
    '.userStories[] | select(.id == $id) | .ownedPaths | length' \
    "$prd_file" 2>/dev/null)" || path_count=1
  if [[ "$path_count" -ge 5 ]]; then
    echo 5400
  elif [[ "$path_count" -ge 3 ]]; then
    echo 3600
  else
    echo 1800
  fi
}

get_story_output_relpath() {
  local story_id="$1"
  jq -r --arg id "$story_id" '
    .userStories[]
    | select(.id == $id)
    | .acceptanceCriteria[]
    | select(test("^Created "))
    | split(" ")[1]
  ' "$PRD_FILE" 2>/dev/null | head -n 1
}

mark_story_passed() {
  local story_id="$1"
  jq --arg id "$story_id" '
    .userStories = [
      .userStories[]
      | if .id == $id then
          (.passes = true)
        else
          .
        end
    ]
  ' "$PRD_FILE" > "$PRD_FILE.tmp" && mv "$PRD_FILE.tmp" "$PRD_FILE"
}

mark_progress_checked() {
  local story_id="$1"
  if [ ! -f "$PROGRESS_FILE" ]; then
    return 0
  fi
  sed -i '' "s|^- \\[ \\] ${story_id}:|- [x] ${story_id}:|g" "$PROGRESS_FILE" || true
}

# ─── Fix-mode story helpers ────────────────────────────────────────────────────

# get_next_fix_story
# Selects the next eligible fix story by priority order.
# Respects FIX_PHASE if set (only stories with matching phase).
# Excludes passes=true, skipped=true, and manualReviewRequired=true stories.
get_next_fix_story() {
  jq -r --argjson phase "${FIX_PHASE:-0}" '
    .userStories
    | sort_by(.priority)
    | .[]
    | select(
        .passes == false
        and (.skipped // false) == false
        and (.manualReviewRequired // false) == false
        and (if $phase > 0 then .phase == $phase else true end)
      )
    | .id
  ' "$FIX_PRD_FILE" 2>/dev/null | head -1
}

# get_fix_story_attempts <story_id>
get_fix_story_attempts() {
  local story_id="$1"
  jq -r --arg id "$story_id" '.[$id] // 0' "$FIX_ATTEMPTS_FILE" 2>/dev/null || echo "0"
}

# increment_fix_attempts <story_id>
increment_fix_attempts() {
  local story_id="$1"
  local current
  current=$(get_fix_story_attempts "$story_id")
  local new_count=$((current + 1))
  jq --arg id "$story_id" --argjson count "$new_count" '.[$id] = $count' \
    "$FIX_ATTEMPTS_FILE" > "$FIX_ATTEMPTS_FILE.tmp" \
    && mv "$FIX_ATTEMPTS_FILE.tmp" "$FIX_ATTEMPTS_FILE"
  echo "$new_count"
}

# mark_fix_passed <story_id>
# Sets passes=true. Must NOT set skipped.
mark_fix_passed() {
  local story_id="$1"
  jq --arg id "$story_id" '
    .userStories = [
      .userStories[]
      | if .id == $id then (.passes = true) else . end
    ]
  ' "$FIX_PRD_FILE" > "$FIX_PRD_FILE.tmp" && mv "$FIX_PRD_FILE.tmp" "$FIX_PRD_FILE"
}

# mark_fix_skipped <story_id> <failure_text>
# Sets skipped=true, keeps passes=false, writes failure_text into lastFailure.
mark_fix_skipped() {
  local story_id="$1"
  local failure_text="${2:-}"
  jq --arg id "$story_id" --arg failure "$failure_text" '
    .userStories = [
      .userStories[]
      | if .id == $id then
          (.skipped = true) | (.passes = false) | (.lastFailure = $failure)
        else
          .
        end
    ]
  ' "$FIX_PRD_FILE" > "$FIX_PRD_FILE.tmp" && mv "$FIX_PRD_FILE.tmp" "$FIX_PRD_FILE"
}

# record_fix_failure <story_id> <failure_text>
# Writes failure_text into lastFailure only; does not change passes or skipped.
record_fix_failure() {
  local story_id="$1"
  local failure_text="${2:-}"
  jq --arg id "$story_id" --arg failure "$failure_text" '
    .userStories = [
      .userStories[]
      | if .id == $id then (.lastFailure = $failure) else . end
    ]
  ' "$FIX_PRD_FILE" > "$FIX_PRD_FILE.tmp" && mv "$FIX_PRD_FILE.tmp" "$FIX_PRD_FILE"
}

# check_phase1_gate
# When running a phase > 1, verifies Phase 1 has no incomplete/skipped stories.
check_phase1_gate() {
  local phase="${FIX_PHASE:-0}"
  if [[ "$phase" -gt 1 ]]; then
    local blockers
    blockers="$(jq -r '.userStories[]
      | select(.phase == 1 and (.passes == false or .skipped == true))
      | .id' "$FIX_PRD_FILE" 2>/dev/null)"
    if [[ -n "$blockers" ]]; then
      echo "ERROR: Phase 1 has incomplete or skipped stories. Resolve them first:"
      echo "$blockers"
      exit 1
    fi
  fi
}

# ─── sync_mirrored_paths (project-specific hook) ─────────────────────────────
# sync_mirrored_paths <story_id>
# Override this function if your project needs to sync ownedPaths to mirror
# locations after agent exit (e.g. files that live in two places).
# Default: no-op.
sync_mirrored_paths() {
  return 0
}

# ─── run_fix_gates ────────────────────────────────────────────────────────────
# run_fix_gates <story_id>
# Runs validation gates for a fix story. Delegates to gates.sh if present;
# otherwise prints a warning and passes (allowing manual verification).
# Returns 0 if all gates pass; returns 1 and sets gate_failure_output on failure.
#
# To add project-specific gates, create .codex/ralph-audit/gates.sh:
#   #!/usr/bin/env bash
#   # gates.sh <story_id> <repo_root> <fix_prd_file>
#   set -euo pipefail
#   STORY_ID="$1"; REPO_ROOT="$2"; FIX_PRD="$3"
#   # Run your tests, lint, build, etc.
#   pytest -q "$REPO_ROOT"
run_fix_gates() {
  local story_id="$1"
  gate_failure_output=""

  local gates_script="$SCRIPT_DIR/gates.sh"
  if [[ -x "$gates_script" ]]; then
    local gate_out
    gate_out="$(bash "$gates_script" "$story_id" "$REPO_ROOT" "$FIX_PRD_FILE" 2>&1)" || {
      gate_failure_output="Gates failed:\n$gate_out"
      echo "$gate_out" | tail -40
      return 1
    }
    return 0
  fi

  echo "WARNING: No gates.sh found at $gates_script — skipping validation gates."
  echo "         Create gates.sh to run project-specific tests/lint/build after fixes."
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────

# validate_fix_prd
# Verifies fix-prd.json integrity before starting fix mode.
# Exits 1 with a descriptive error on any failure.
validate_fix_prd() {
  # 1. File must exist and be valid JSON
  if [[ ! -f "${FIX_PRD_FILE:-}" ]]; then
    echo "ERROR: fix-prd.json not found at '${FIX_PRD_FILE:-<unset>}'"
    echo "       Create it with your fix stories (see README.md for format)."
    exit 1
  fi

  if ! jq '.' "$FIX_PRD_FILE" >/dev/null 2>&1; then
    echo "ERROR: fix-prd.json is not valid JSON: $FIX_PRD_FILE"
    exit 1
  fi

  # 2. Must have at least one story
  local count
  count="$(jq '.userStories | length' "$FIX_PRD_FILE" 2>/dev/null)"
  if [[ "$count" -eq 0 ]]; then
    echo "ERROR: fix-prd.json has 0 stories. Add at least one story to .userStories[]."
    exit 1
  fi

  # 3. Required fields check on every story
  local required_fields='["id","title","description","acceptanceCriteria","priority","passes","ownedPaths"]'
  local missing
  missing="$(jq --argjson req "$required_fields" '
    .userStories[]
    | . as $s
    | $req[]
    | . as $field
    | select(($s | has($field)) | not)
    | "Story \($s.id // "?") missing field: \($field)"
  ' "$FIX_PRD_FILE" 2>/dev/null)"
  if [[ -n "$missing" ]]; then
    echo "ERROR: fix-prd.json has stories with missing required fields:"
    echo "$missing" | head -20
    exit 1
  fi

  echo "fix-prd.json validated: $count stories."
}

# ─── CLI-specific configuration ────────────────────────────────────────────────

# Default models per backend.
CODEX_DEFAULT_MODEL="gpt-5.4"
OPENCODE_DEFAULT_MODEL="anthropic/claude-opus-4-6"

REASONING_EFFORT="${REASONING_EFFORT:-medium}"

if [[ "$CLI_BACKEND" == "codex" ]]; then
  REQUESTED_MODEL="${RALPH_MODEL:-$CODEX_DEFAULT_MODEL}"

  if [[ -n "${CODEX_MODEL:-}" && "${CODEX_MODEL}" != "$REQUESTED_MODEL" ]]; then
    echo "ERROR: This loop is pinned to CODEX_MODEL=$REQUESTED_MODEL. Unset CODEX_MODEL to continue."
    exit 1
  fi
  if [[ -n "${CODEX_REASONING_EFFORT:-}" && "${CODEX_REASONING_EFFORT}" != "$REASONING_EFFORT" ]]; then
    echo "ERROR: This loop is pinned to CODEX_REASONING_EFFORT=$REASONING_EFFORT. Unset CODEX_REASONING_EFFORT to continue."
    exit 1
  fi
else
  REQUESTED_MODEL="${RALPH_MODEL:-$OPENCODE_DEFAULT_MODEL}"
fi

# ─── Fix-mode file setup ───────────────────────────────────────────────────────

# Preserve any externally-set FIX_PRD_FILE before blanket initialization.
_FIX_PRD_FILE_OVERRIDE="${FIX_PRD_FILE:-}"

FIX_PRD_FILE=""
FIX_ATTEMPTS_FILE=""
FIX_LAST_STORY_FILE=""
FIX_SUMMARY_FILE=""

if [[ "$RUN_MODE" == "fix" ]]; then
  FIX_PRD_FILE="${_FIX_PRD_FILE_OVERRIDE:-$SCRIPT_DIR/fix-prd.json}"
  FIX_ATTEMPTS_FILE="$SCRIPT_DIR/.fix-story-attempts"
  FIX_LAST_STORY_FILE="$SCRIPT_DIR/.fix-last-story"
  FIX_SUMMARY_FILE="$SCRIPT_DIR/fix-summary.md"
  [[ ! -f "$FIX_ATTEMPTS_FILE" ]] && echo "{}" > "$FIX_ATTEMPTS_FILE"
  validate_fix_prd  # integrity check; exits 1 on failure
fi

# ─── Single-instance lock ──────────────────────────────────────────────────────

if [[ -d "$LOCK_DIR" ]]; then
  LOCK_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "${LOCK_PID:-}" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
    echo "ERROR: Another Ralph run appears active (lock exists: $LOCK_DIR, pid=$LOCK_PID)."
    exit 1
  fi
  /bin/rm -rf "$LOCK_DIR"
fi

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "ERROR: Could not create run lock at $LOCK_DIR."
  exit 1
fi
echo "$$" > "$LOCK_DIR/pid"
echo "$(ts)" > "$LOCK_DIR/started_at"

touch "$RUN_LOG" "$EVENT_LOG"
trap on_script_exit EXIT
trap 'log_event "RUN SIGNAL SIGHUP (ignored)"' HUP
trap 'log_event "RUN SIGNAL SIGINT"; exit 130' INT
trap 'log_event "RUN SIGNAL SIGTERM"; exit 143' TERM

echo "Starting Ralph Audit"
echo "  CLI backend: $CLI_BACKEND"
echo "  Max iterations: $MAX_ITERATIONS"
echo "  Max attempts per story: $MAX_ATTEMPTS_PER_STORY"
echo "  Story timeout (seconds): $STORY_TIMEOUT_SECONDS"
echo "  Model: $REQUESTED_MODEL (reasoning_effort=$REASONING_EFFORT)"
echo "  Logs:"
echo "    - events: $EVENT_LOG"
echo "    - full:   $RUN_LOG"
echo "  Tail:"
echo "    tail -n $TAIL_N -f $EVENT_LOG"
echo "    tail -n $TAIL_N -f $RUN_LOG"

log_event "RUN START cli=$CLI_BACKEND max_iterations=$MAX_ITERATIONS max_attempts_per_story=$MAX_ATTEMPTS_PER_STORY story_timeout_seconds=$STORY_TIMEOUT_SECONDS search=$ENABLE_SEARCH model=$REQUESTED_MODEL reasoning_effort=$REASONING_EFFORT story_filter_ids=${STORY_FILTER_IDS:-<none>}"

# ─── Preflight model check ────────────────────────────────────────────────────

if [[ "$CLI_BACKEND" == "codex" ]]; then
  MODEL_CHECK_CMD=(
    codex
    -a never
    exec
    -C "$REPO_ROOT"
    -m "$REQUESTED_MODEL"
    -c "model_reasoning_effort=\"$REASONING_EFFORT\""
    -s read-only
    "Respond with exactly: OK"
  )
  if ! "${MODEL_CHECK_CMD[@]}" > "$MODEL_CHECK_LOG" 2>&1; then
    echo "ERROR: Model preflight failed for '$REQUESTED_MODEL'. See: $MODEL_CHECK_LOG"
    echo "Fix options:"
    echo "  1) Re-auth with an API key that has access:"
    echo "     printenv OPENAI_API_KEY | codex login --with-api-key"
    exit 1
  fi
else
  # opencode: verify the binary exists; skip model preflight (opencode handles auth)
  if ! command -v opencode &>/dev/null; then
    echo "ERROR: 'opencode' not found on PATH."
    exit 1
  fi
  echo "opencode found: $(command -v opencode) ($(opencode --version 2>/dev/null || echo 'unknown'))"
fi

# ─── Build CLI args ───────────────────────────────────────────────────────────

# ─── Writable CLI invocation (pinned for fix mode) ────────────────────────────
#
# VERIFIED at implementation time (see CODEX-FIX.md for full detail):
#
# OpenCode backend (--cli opencode):
#   opencode run is write-capable by default — no extra flag required.
#   The env -u OPENCODE_SERVER_PASSWORD workaround is preserved (A-01).
#
# Codex backend (--cli codex):
#   Writable mode: -s workspace-write
#   Audit mode uses -s read-only; fix mode uses -s workspace-write.
#   Narrowest mode that permits repo file edits.
#
# run_fix_agent() below uses these invocations.
# ──────────────────────────────────────────────────────────────────────────────

# run_agent <prompt_file> <last_message_file> <step_log_file>
# Launches the agent in the background, sets AGENT_PID.
run_agent() {
  local prompt_file="$1"
  local last_message_file="$2"
  local step_log_file="$3"

  if [[ "$CLI_BACKEND" == "codex" ]]; then
    local codex_args=( -a never )
    if [[ "$ENABLE_SEARCH" == "true" ]]; then
      codex_args+=(--search)
    fi
    codex_args+=(
      exec
      -C "$REPO_ROOT"
      -m "$REQUESTED_MODEL"
      -c "model_reasoning_effort=\"$REASONING_EFFORT\""
      -s read-only
    )
    codex "${codex_args[@]}" --output-last-message "$last_message_file" < "$prompt_file" > "$step_log_file" 2>&1 &
    AGENT_PID=$!

  else
    # opencode: run with prompt from file, capture output, extract last assistant message.
    local prompt_text
    prompt_text="$(cat "$prompt_file")"
    local raw_output_file="$SCRIPT_DIR/.opencode-raw.json"

    # Workaround: OpenCode desktop app sets OPENCODE_SERVER_PASSWORD in the
    # shell env. When present, `opencode run`'s in-process server enforces
    # Basic Auth on its own internal requests — but the SDK client sends no
    # Authorization header, causing silent auth rejection ("Session not found").
    # See: https://github.com/anomalyco/opencode/issues/14532
    env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME -u OPENCODE_CLIENT \
      opencode run \
        --dir "$REPO_ROOT" \
        -m "$REQUESTED_MODEL" \
        --variant "$REASONING_EFFORT" \
        --format json \
        "$prompt_text" > "$raw_output_file" 2>"$step_log_file" &
    AGENT_PID=$!

    # Post-process: wait for agent, then extract last assistant text from JSON stream.
    # We do this in the caller after wait, so just set a marker for post-processing.
    export _OPENCODE_RAW_OUTPUT="$raw_output_file"
  fi
}

# extract_opencode_last_message <raw_json_file> <last_message_file>
# Parses the newline-delimited JSON from opencode --format json and extracts
# the last assistant text block.
extract_opencode_last_message() {
  local raw_file="$1"
  local out_file="$2"

  if [[ ! -s "$raw_file" ]]; then
    return 1
  fi

  # opencode --format json emits newline-delimited JSON events.
  # The text event structure (verified from actual output) is:
  #   {"type":"text","part":{"type":"text","text":"THE REPORT"}}
  # There may be multiple text events; we want the last (longest) one which
  # contains the full report.

  # Approach 1: exact match on the verified event schema (uses -s to slurp all
  # events into an array so we can pick the last text event without tail -1,
  # which would break multi-line text content).
  local extracted=""
  extracted="$(jq -rs '
    [.[] | select(.type == "text" and .part.type == "text") | .part.text]
    | to_entries
    | sort_by([(.value | length), .key])
    | last
    | .value // empty
  ' "$raw_file" 2>/dev/null)" || true

  # Approach 2: fallback — message.part.updated events (older opencode versions)
  if [[ -z "$extracted" ]]; then
    extracted="$(jq -rs '
      [.[] | select(.type == "message.part.updated" and .properties.part.type == "text")
       | .properties.part.text]
      | to_entries
      | sort_by([(.value | length), .key])
      | last
      | .value // empty
    ' "$raw_file" 2>/dev/null)" || true
  fi

  # Approach 3: brute-force — grab last .part.text or top-level .text
  if [[ -z "$extracted" ]]; then
    extracted="$(jq -rs '
      [.[] | (.part.text // .text) // empty]
      | to_entries
      | sort_by([(.value | length), .key])
      | last
      | .value // empty
    ' "$raw_file" 2>/dev/null)" || true
  fi

  if [[ -n "$extracted" ]]; then
    printf '%s\n' "$extracted" > "$out_file"
    return 0
  fi

  # Final fallback: if the output is plain text (non-JSON), use it directly
  if ! jq -e '.' "$raw_file" &>/dev/null 2>&1; then
    # Not valid JSON — treat the whole file as the response
    cp "$raw_file" "$out_file"
    return 0
  fi

  return 1
}

# ─── build_fix_prompt ─────────────────────────────────────────────────────────
# build_fix_prompt <story_id> <prompt_file>
# Builds a fix prompt from the backlog story and appends CODEX-FIX.md.
build_fix_prompt() {
  local story_id="$1"
  local prompt_file="$2"
  local title severity category phase owned_paths notes acceptance
  title="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | .title' "$FIX_PRD_FILE")"
  severity="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | .severity' "$FIX_PRD_FILE")"
  category="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | .category' "$FIX_PRD_FILE")"
  phase="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | .phase' "$FIX_PRD_FILE")"
  owned_paths="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | .ownedPaths | join(", ")' "$FIX_PRD_FILE")"
  notes="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | (.notes // "")' "$FIX_PRD_FILE")"
  acceptance="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | .acceptanceCriteria | join("\n- ")' "$FIX_PRD_FILE")"
  {
    printf "# Ralph Fix\n\nToday's date: %s\n\n" "$(date +%Y-%m-%d)"
    printf "## Finding: %s — %s\n\n" "$story_id" "$title"
    printf "**Severity:** %s  **Phase:** %s  **Category:** %s\n\n" "$severity" "$phase" "$category"
    printf "**Files you may modify:** %s\n\n" "$owned_paths"
    printf "## Finding Details\n%s\n\n" "$notes"
    printf "## Acceptance Criteria\n- %s\n\n---\n\n" "$acceptance"
    if [[ -f "$SCRIPT_DIR/CODEX-FIX.md" ]]; then
      cat "$SCRIPT_DIR/CODEX-FIX.md"
    else
      echo "WARNING: CODEX-FIX.md not found — fix agent will run without quality bar instructions." >&2
    fi
  } > "$prompt_file"
}

# ─── run_fix_agent ────────────────────────────────────────────────────────────
# run_fix_agent <prompt_file> <step_log_file>
# Launches the fix agent in write-capable mode in the background, sets AGENT_PID.
# Does not require a last_message_file (fix mode does not need report persistence).
run_fix_agent() {
  local prompt_file="$1"
  local step_log_file="$2"

  if [[ "$CLI_BACKEND" == "codex" ]]; then
    # Fix mode: -s workspace-write (writable); audit mode uses -s read-only.
    local codex_args=( -a never )
    if [[ "$ENABLE_SEARCH" == "true" ]]; then
      codex_args+=(--search)
    fi
    codex_args+=(
      exec
      -C "$REPO_ROOT"
      -m "$REQUESTED_MODEL"
      -c "model_reasoning_effort=\"$REASONING_EFFORT\""
      -s workspace-write
    )
    codex "${codex_args[@]}" < "$prompt_file" > "$step_log_file" 2>&1 &
    AGENT_PID=$!

  else
    # opencode run is write-capable by default; no extra flag required.
    # Preserve env -u OPENCODE_SERVER_PASSWORD workaround (A-01).
    local prompt_text
    prompt_text="$(cat "$prompt_file")"
    local raw_output_file="$SCRIPT_DIR/.opencode-fix-raw.json"

    env -u OPENCODE_SERVER_PASSWORD -u OPENCODE_SERVER_USERNAME -u OPENCODE_CLIENT \
      opencode run \
        --dir "$REPO_ROOT" \
        -m "$REQUESTED_MODEL" \
        --variant "$REASONING_EFFORT" \
        "$prompt_text" > "$step_log_file" 2>&1 &
    AGENT_PID=$!
    # Fix mode does not use raw JSON output; logs go directly to step_log_file.
  fi
}

# ─── append_fix_summary ──────────────────────────────────────────────────────
# append_fix_summary <story_id>
# Appends a success line to fix-summary.md.
append_fix_summary() {
  local story_id="$1"
  local title file lines
  title="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | .title' "$FIX_PRD_FILE")"
  file="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | .ownedPaths[0]' "$FIX_PRD_FILE")"
  lines="$(jq -r --arg id "$story_id" '.userStories[] | select(.id==$id) | (.sourceLines // "")' "$FIX_PRD_FILE")"
  local file_display="$file"
  [[ -n "$lines" && "$lines" != "null" ]] && file_display="$file:$lines"
  if [[ ! -f "$FIX_SUMMARY_FILE" ]]; then
    echo "# Ralph Fix Summary" > "$FIX_SUMMARY_FILE"
    echo "" >> "$FIX_SUMMARY_FILE"
  fi
  echo "- [$(date +%Y-%m-%d)] $story_id FIXED: $title ($file_display)" >> "$FIX_SUMMARY_FILE"
}

# ─── run_fix_iteration ───────────────────────────────────────────────────────
# Runs one fix iteration. Selects next story, invokes agent, runs gates, updates state.
# Returns 0 (continue) or 1 (skip / story failed); calls exit for fatal errors.
run_fix_iteration() {
  CURRENT_STORY=$(get_next_fix_story)

  if [[ -z "$CURRENT_STORY" ]]; then
    log_event "RUN COMPLETE (no eligible fix stories)"
    echo ""
    echo "No eligible fix stories found."
    echo "Ralph fix mode completed all tasks!"
    echo "<promise>COMPLETE</promise>"
    exit 0
  fi

  local attempts
  attempts=$(get_fix_story_attempts "$CURRENT_STORY")

  # Circuit breaker: skip if max attempts reached
  if [[ "$attempts" -ge "$MAX_ATTEMPTS_PER_STORY" ]]; then
    echo "Circuit breaker: $CURRENT_STORY has reached max attempts ($attempts/$MAX_ATTEMPTS_PER_STORY)"
    mark_fix_skipped "$CURRENT_STORY" "Exceeded $MAX_ATTEMPTS_PER_STORY attempts without passing"
    log_event "FIX SKIP id=$CURRENT_STORY reason=circuit_breaker"
    return 1
  fi

  increment_fix_attempts "$CURRENT_STORY"
  echo "Fix story: $CURRENT_STORY (attempt $((attempts + 1))/$MAX_ATTEMPTS_PER_STORY)"

  STORY_TIMEOUT_SECONDS="$(compute_adaptive_timeout "$CURRENT_STORY" "$FIX_PRD_FILE")"

  PROMPT_FILE="$SCRIPT_DIR/.fix-prompt.md"
  STEP_LOG_FILE="$SCRIPT_DIR/.fix-agent-step.log"
  STEP_TIMEOUT_MARKER="$SCRIPT_DIR/.fix-agent-step-timeout"

  /bin/rm -f "$STEP_TIMEOUT_MARKER"
  : > "$STEP_LOG_FILE"

  build_fix_prompt "$CURRENT_STORY" "$PROMPT_FILE"
  log_event "FIX AGENT START cli=$CLI_BACKEND story=$CURRENT_STORY timeout_seconds=$STORY_TIMEOUT_SECONDS"
  run_fix_agent "$PROMPT_FILE" "$STEP_LOG_FILE"

  (
    sleep "$STORY_TIMEOUT_SECONDS"
    if kill -0 "$AGENT_PID" 2>/dev/null; then
      : > "$STEP_TIMEOUT_MARKER"
      echo "[watchdog] fix story timeout (${STORY_TIMEOUT_SECONDS}s); terminating agent pid=$AGENT_PID" >> "$STEP_LOG_FILE"
      kill -TERM "$AGENT_PID" 2>/dev/null || true
      sleep 5
      kill -KILL "$AGENT_PID" 2>/dev/null || true
    fi
  ) &
  local WATCHDOG_PID=$!

  (
    while kill -0 "$AGENT_PID" 2>/dev/null; do
      sleep 30
      if kill -0 "$AGENT_PID" 2>/dev/null; then
        log_event "AGENT HEARTBEAT story=$CURRENT_STORY"
      fi
    done
  ) &
  local HEARTBEAT_PID=$!

  AGENT_STATUS=0
  wait "$AGENT_PID" || AGENT_STATUS=$?
  kill "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  cat "$STEP_LOG_FILE" >> "$RUN_LOG"
  log_event "FIX AGENT END cli=$CLI_BACKEND story=$CURRENT_STORY exit_code=$AGENT_STATUS"

  if [[ -f "$STEP_TIMEOUT_MARKER" ]]; then
    local failure_text="Agent timed out after ${STORY_TIMEOUT_SECONDS}s"
    log_event "ERROR story=$CURRENT_STORY fix-agent-timeout"
    echo "ERROR: Fix agent timed out after ${STORY_TIMEOUT_SECONDS}s for $CURRENT_STORY"
    record_fix_failure "$CURRENT_STORY" "$failure_text"
    return 1
  fi

  if [[ "$AGENT_STATUS" -ne 0 ]]; then
    local failure_text="Agent exited non-zero ($AGENT_STATUS)"
    log_event "ERROR story=$CURRENT_STORY fix-agent-nonzero exit_code=$AGENT_STATUS"
    echo "ERROR: Fix agent exited non-zero ($AGENT_STATUS) for $CURRENT_STORY"
    record_fix_failure "$CURRENT_STORY" "$failure_text"
    return 1
  fi

  # Sync mirrored paths (project-specific hook) before gates run
  sync_mirrored_paths "$CURRENT_STORY" || {
    local failure_text="Mirror sync failed for $CURRENT_STORY"
    log_event "ERROR story=$CURRENT_STORY mirror-sync-failed"
    echo "ERROR: Mirror sync failed for $CURRENT_STORY — treating as gate failure"
    record_fix_failure "$CURRENT_STORY" "$failure_text"
    return 1
  }

  # Run fix gates
  local gate_failure_output=""
  if ! run_fix_gates "$CURRENT_STORY"; then
    log_event "ERROR story=$CURRENT_STORY fix-gate-failed"
    echo "ERROR: Fix gates failed for $CURRENT_STORY"
    record_fix_failure "$CURRENT_STORY" "$gate_failure_output"
    return 1
  fi

  # All gates passed
  mark_fix_passed "$CURRENT_STORY"
  append_fix_summary "$CURRENT_STORY"
  log_event "STORY PASS id=$CURRENT_STORY"
  echo "Fix story $CURRENT_STORY PASSED."
  return 0
}

# ─── run_audit_iteration ───────────────────────────────────────────────────────
# run_audit_iteration <iteration_number>
# Runs one audit iteration. Returns:
#   0 — completed normally; outer loop should continue
#   1 — story skipped or failed; outer loop should continue (same as 0)
# Calls exit directly for fatal errors or successful completion.
run_audit_iteration() {
  local i="$1"

  echo ""
  echo "==============================================================="
  echo "  Ralph Audit Iteration $i of $MAX_ITERATIONS"
  echo "==============================================================="

  echo "" >> "$RUN_LOG"
  echo "===============================================================" >> "$RUN_LOG"
  echo "Ralph Audit Iteration $i of $MAX_ITERATIONS - $(date)" >> "$RUN_LOG"
  echo "===============================================================" >> "$RUN_LOG"

  log_event "ITERATION START $i/$MAX_ITERATIONS"

  CURRENT_STORY=$(get_current_story)

  if [ -z "$CURRENT_STORY" ]; then
    log_event "RUN COMPLETE (no incomplete stories)"
    echo "No incomplete stories found."
    echo ""
    echo "Ralph audit completed all tasks!"
    echo "<promise>COMPLETE</promise>"
    exit 0
  fi

  LAST_STORY=""
  if [ -f "$LAST_STORY_FILE" ]; then
    LAST_STORY=$(cat "$LAST_STORY_FILE" 2>/dev/null || echo "")
  fi

  if [ "$CURRENT_STORY" == "$LAST_STORY" ]; then
    echo "Consecutive attempt on story: $CURRENT_STORY"
    ATTEMPTS=$(increment_story_attempts "$CURRENT_STORY")
    echo "Attempts on $CURRENT_STORY: $ATTEMPTS/$MAX_ATTEMPTS_PER_STORY"

    if check_circuit_breaker "$CURRENT_STORY"; then
      echo "Skipping to next story..."
      echo "$CURRENT_STORY" > "$LAST_STORY_FILE"
      sleep 1
      return 1
    fi
  else
    ATTEMPTS=$(increment_story_attempts "$CURRENT_STORY")
    echo "Starting story: $CURRENT_STORY (attempt $ATTEMPTS/$MAX_ATTEMPTS_PER_STORY)"
  fi

  echo "$CURRENT_STORY" > "$LAST_STORY_FILE"

  STORY_TITLE="$(get_story_title "$CURRENT_STORY")"
  STORY_DESC="$(get_story_description "$CURRENT_STORY")"
  STORY_NOTES="$(get_story_notes "$CURRENT_STORY")"
  OUT_REL="$(get_story_output_relpath "$CURRENT_STORY")"

  if [ -z "$OUT_REL" ] || [ "$OUT_REL" == "null" ]; then
    log_event "ERROR story=$CURRENT_STORY could-not-determine-output-path"
    echo "ERROR: Could not determine output path for story $CURRENT_STORY from prd.json acceptanceCriteria."
    exit 1
  fi

  OUT_FILE="$REPO_ROOT/$OUT_REL"
  mkdir -p "$(dirname "$OUT_FILE")"

  log_event "STORY START id=$CURRENT_STORY attempt=$ATTEMPTS out=$OUT_REL title=$(printf '%s' "$STORY_TITLE" | tr '\n' ' ')"

  PROMPT_FILE="$SCRIPT_DIR/.prompt.md"
  LAST_MESSAGE_FILE="$SCRIPT_DIR/.last-message.md"
  STEP_LOG_FILE="$SCRIPT_DIR/.agent-step.log"
  STEP_TIMEOUT_MARKER="$SCRIPT_DIR/.agent-step-timeout"

  {
    printf "# Ralph Audit\n\n"
    printf "Today's date: %s\n\n" "$(date +%Y-%m-%d)"
    printf "Current story: %s — %s\n" "$CURRENT_STORY" "$STORY_TITLE"
    printf "Target output file (relative to repo root): %s\n\n" "$OUT_REL"
    printf "Hard requirements:\n"
    printf '%s\n' "- Do NOT modify any files in the repo."
    printf '%s\n' "- Your final response MUST be ONLY the markdown report contents for $OUT_REL."
    printf "  Do not include any extra commentary.\n\n"
    printf "Story description:\n%s\n\n" "$STORY_DESC"
    printf "Story notes:\n%s\n\n" "$STORY_NOTES"
    printf '%s\n\n' "---"
    cat "$SCRIPT_DIR/CODEX.md"
  } > "$PROMPT_FILE"

  # Ensure we never reuse a stale completion from a previous run.
  /bin/rm -f "$LAST_MESSAGE_FILE"
  /bin/rm -f "$STEP_TIMEOUT_MARKER"
  /bin/rm -f "$SCRIPT_DIR/.opencode-raw.json"
  : > "$STEP_LOG_FILE"

  # Run agent with a watchdog timeout; persist all output.
  STORY_TIMEOUT_SECONDS="$(compute_adaptive_timeout "$CURRENT_STORY" "$PRD_FILE")"
  log_event "AGENT START cli=$CLI_BACKEND story=$CURRENT_STORY timeout_seconds=$STORY_TIMEOUT_SECONDS"
  run_agent "$PROMPT_FILE" "$LAST_MESSAGE_FILE" "$STEP_LOG_FILE"

  (
    sleep "$STORY_TIMEOUT_SECONDS"
    if kill -0 "$AGENT_PID" 2>/dev/null; then
      : > "$STEP_TIMEOUT_MARKER"
      echo "[watchdog] story timeout reached (${STORY_TIMEOUT_SECONDS}s); terminating agent pid=$AGENT_PID" >> "$STEP_LOG_FILE"
      kill -TERM "$AGENT_PID" 2>/dev/null || true
      sleep 5
      kill -KILL "$AGENT_PID" 2>/dev/null || true
    fi
  ) &
  WATCHDOG_PID=$!

  (
    while kill -0 "$AGENT_PID" 2>/dev/null; do
      sleep 30
      if kill -0 "$AGENT_PID" 2>/dev/null; then
        log_event "AGENT HEARTBEAT story=$CURRENT_STORY"
      fi
    done
  ) &
  HEARTBEAT_PID=$!

  AGENT_STATUS=0
  wait "$AGENT_PID" || AGENT_STATUS=$?
  kill "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  kill "$HEARTBEAT_PID" 2>/dev/null || true
  wait "$HEARTBEAT_PID" 2>/dev/null || true
  cat "$STEP_LOG_FILE" >> "$RUN_LOG"
  log_event "AGENT END cli=$CLI_BACKEND story=$CURRENT_STORY exit_code=$AGENT_STATUS"

  # For opencode backend, post-process the JSON output to extract the last message.
  if [[ "$CLI_BACKEND" == "opencode" && -f "${_OPENCODE_RAW_OUTPUT:-}" ]]; then
    if ! extract_opencode_last_message "$_OPENCODE_RAW_OUTPUT" "$LAST_MESSAGE_FILE"; then
      log_event "ERROR story=$CURRENT_STORY opencode-message-extraction-failed"
      echo "WARNING: Could not extract last message from opencode output. Checking raw output..."
      # If the raw output file has content, use it as-is (opencode default format is plain text)
      if [[ -s "$_OPENCODE_RAW_OUTPUT" ]]; then
        cp "$_OPENCODE_RAW_OUTPUT" "$LAST_MESSAGE_FILE"
      fi
    fi
    cat "$_OPENCODE_RAW_OUTPUT" >> "$RUN_LOG" 2>/dev/null || true
  fi

  if [ -f "$STEP_TIMEOUT_MARKER" ]; then
    log_event "ERROR story=$CURRENT_STORY agent-timeout timeout_seconds=$STORY_TIMEOUT_SECONDS"
    echo "ERROR: Agent timed out after ${STORY_TIMEOUT_SECONDS}s. See: $RUN_LOG"
    echo "Iteration $i complete (failed). Continuing..."
    sleep 2
    return 1
  fi

  if [ "$AGENT_STATUS" -ne 0 ]; then
    log_event "ERROR story=$CURRENT_STORY agent-nonzero-exit exit_code=$AGENT_STATUS"
    echo "ERROR: Agent exited non-zero ($AGENT_STATUS). See: $RUN_LOG"
    echo "Iteration $i complete (failed). Continuing..."
    sleep 2
    return 1
  fi

  if [ ! -s "$LAST_MESSAGE_FILE" ]; then
    log_event "ERROR story=$CURRENT_STORY agent-empty-last-message-after-success"
    echo "ERROR: Agent exited successfully but did not produce a last message file (or it was empty). See: $RUN_LOG"
    echo "Iteration $i complete (failed). Continuing..."
    sleep 2
    return 1
  fi

  # Persist the audit report and mark story passed in PRD state.
  cat "$LAST_MESSAGE_FILE" > "$OUT_FILE"
  mark_story_passed "$CURRENT_STORY"
  mark_progress_checked "$CURRENT_STORY"

  OUT_BYTES="$(wc -c < "$OUT_FILE" | tr -d ' ')"
  log_event "STORY COMPLETE id=$CURRENT_STORY wrote=$OUT_REL bytes=$OUT_BYTES"

  REMAINING="$(get_current_story)"
  if [ -z "$REMAINING" ]; then
    log_event "RUN COMPLETE (all stories passed)"
    echo ""
    echo "All audit tasks are marked passes:true."
    echo "Ralph audit completed all tasks!"
    echo "<promise>COMPLETE</promise>"
    exit 0
  fi

  echo "Iteration $i complete. Continuing..."
  sleep 2
  return 0
}

# ─── Main dispatch ─────────────────────────────────────────────────────────────

if [[ "$RUN_MODE" == "fix" ]]; then
  check_phase1_gate
  for i in $(seq 1 "$MAX_ITERATIONS"); do
    run_fix_iteration
  done
else
  for i in $(seq 1 "$MAX_ITERATIONS"); do
    run_audit_iteration "$i"
  done
fi

echo ""
echo "Ralph reached max iterations ($MAX_ITERATIONS) without completing all tasks."
echo "Tail log: tail -f $RUN_LOG"
log_event "RUN STOPPED (reached max iterations without completing all tasks)"
exit 1
