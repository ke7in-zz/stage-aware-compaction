#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
RALPH_SCRIPT="$SCRIPT_DIR/ralph.sh"
RUNS_DIR="$SCRIPT_DIR/runs"

MAX_ITERATIONS="${MAX_ITERATIONS:-20}"
MAX_ATTEMPTS_PER_STORY="${MAX_ATTEMPTS_PER_STORY:-4}"
STORY_TIMEOUT_SECONDS="${STORY_TIMEOUT_SECONDS:-1200}"
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
DRY_RUN="${DRY_RUN:-false}"
CLI_FLAG="${RALPH_CLI:-codex}"

CONTEXT_PATH=""
MAX_STORIES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli)
      if [[ $# -lt 2 ]]; then
        echo "--cli requires a value: codex or opencode"
        exit 1
      fi
      CLI_FLAG="$2"
      shift 2
      ;;
    --max-stories)
      if [[ $# -lt 2 ]]; then
        echo "--max-stories requires a numeric value"
        exit 1
      fi
      MAX_STORIES="$2"
      shift 2
      ;;
    *)
      if [[ -z "$CONTEXT_PATH" ]]; then
        CONTEXT_PATH="$1"
      else
        echo "Unexpected argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -n "$MAX_STORIES" && ! "$MAX_STORIES" =~ ^[0-9]+$ ]]; then
  echo "--max-stories must be a non-negative integer"
  exit 1
fi

if [[ ! -f "$PRD_FILE" ]]; then
  echo "Missing PRD file: $PRD_FILE"
  exit 1
fi

/bin/mkdir -p "$RUNS_DIR"

DOC_FILES_TMP="$(mktemp)"
CONTEXT_PATHS_TMP="$(mktemp)"
STORY_PATHS_TMP="$(mktemp)"
MATCHED_IDS_TMP="$(mktemp)"
SELECTED_IDS_TMP="$(mktemp)"
PENDING_IDS_TMP="$(mktemp)"
MANIFEST_TMP="$(mktemp)"

cleanup() {
  /bin/rm -f "$DOC_FILES_TMP" "$CONTEXT_PATHS_TMP" "$STORY_PATHS_TMP" "$MATCHED_IDS_TMP" "$SELECTED_IDS_TMP" "$PENDING_IDS_TMP" "$MANIFEST_TMP"
}
trap cleanup EXIT

build_pending_ids() {
  jq -r '.userStories[] | [.priority, .id, .passes] | @tsv' "$PRD_FILE" \
    | sort -n \
    | while IFS=$'\t' read -r priority story_id passes; do
        if [[ "$passes" == "false" ]]; then
          echo "$story_id"
        fi
      done > "$PENDING_IDS_TMP"
}

apply_max_stories_limit() {
  local source_file="$1"
  local target_file="$2"
  if [[ -n "$MAX_STORIES" && "$MAX_STORIES" -gt 0 ]]; then
    head -n "$MAX_STORIES" "$source_file" > "$target_file"
  else
    cat "$source_file" > "$target_file"
  fi
}

build_story_filter_from_file() {
  local ids_file="$1"
  if [[ -s "$ids_file" ]]; then
    paste -sd, "$ids_file"
  else
    echo ""
  fi
}

write_manifest() {
  local context_value="$1"
  local mode_value="$2"
  local selected_ids_file="$3"
  local filter_ids="$4"
  local run_timestamp
  run_timestamp="$(date '+%Y-%m-%dT%H:%M:%S%z')"
  local manifest_path="$RUNS_DIR/run-$(date '+%Y%m%d-%H%M%S').json"

  jq -n \
    --arg timestamp "$run_timestamp" \
    --arg context "$context_value" \
    --arg mode "$mode_value" \
    --arg maxStories "${MAX_STORIES:-}" \
    --arg filter "$filter_ids" \
    --arg dryRun "$DRY_RUN" \
    --argjson selected "$(jq -R . < "$selected_ids_file" | jq -s .)" \
    '{
      timestamp: $timestamp,
      context: ($context | select(length > 0)),
      mode: $mode,
      maxStories: ($maxStories | select(length > 0)),
      storyFilterIds: ($filter | select(length > 0)),
      dryRun: ($dryRun == "true"),
      selectedStories: $selected
    }' > "$manifest_path"

  echo "Manifest: $manifest_path"
}

run_ralph_with_filter() {
  local filter_ids="$1"
  local mode_value="$2"
  local selected_ids_file="$3"
  write_manifest "${CONTEXT_PATH:-}" "$mode_value" "$selected_ids_file" "$filter_ids"

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ -n "$filter_ids" ]]; then
      echo "DRY_RUN: would run Ralph with story filter: $filter_ids"
    else
      echo "DRY_RUN: would run Ralph with all pending stories"
    fi
    return 0
  fi

  if [[ -n "$filter_ids" ]]; then
    echo "Running Ralph with story filter: $filter_ids (cli=$CLI_FLAG)"
    STORY_FILTER_IDS="$filter_ids" \
    MAX_ATTEMPTS_PER_STORY="$MAX_ATTEMPTS_PER_STORY" \
    STORY_TIMEOUT_SECONDS="$STORY_TIMEOUT_SECONDS" \
    REASONING_EFFORT="$REASONING_EFFORT" \
    "$RALPH_SCRIPT" "$MAX_ITERATIONS" --cli "$CLI_FLAG" --skip-security-check --no-search
  else
    echo "Running Ralph with all pending stories (cli=$CLI_FLAG)"
    MAX_ATTEMPTS_PER_STORY="$MAX_ATTEMPTS_PER_STORY" \
    STORY_TIMEOUT_SECONDS="$STORY_TIMEOUT_SECONDS" \
    REASONING_EFFORT="$REASONING_EFFORT" \
    "$RALPH_SCRIPT" "$MAX_ITERATIONS" --cli "$CLI_FLAG" --skip-security-check --no-search
  fi
}

build_pending_ids

if [[ ! -s "$PENDING_IDS_TMP" ]]; then
  echo "No pending stories remain."
  exit 0
fi

if [[ -z "$CONTEXT_PATH" ]]; then
  apply_max_stories_limit "$PENDING_IDS_TMP" "$SELECTED_IDS_TMP"
  STORY_FILTER_IDS="$(build_story_filter_from_file "$SELECTED_IDS_TMP")"
  run_ralph_with_filter "$STORY_FILTER_IDS" "all-pending" "$SELECTED_IDS_TMP"
  exit 0
fi

if [[ ! -d "$CONTEXT_PATH" ]]; then
  echo "Context folder does not exist: $CONTEXT_PATH"
  exit 1
fi

if [[ "$CONTEXT_PATH" != ./.codex/specs/* && "$CONTEXT_PATH" != ./.codex/bugs/* ]]; then
  echo "Context folder must be under ./.codex/specs/ or ./.codex/bugs/"
  exit 1
fi

find "$CONTEXT_PATH" -maxdepth 3 -type f -name "*.md" | sort > "$DOC_FILES_TMP"
if [[ ! -s "$DOC_FILES_TMP" ]]; then
  echo "No markdown docs found in context folder: $CONTEXT_PATH"
  exit 1
fi

# Match file paths for Python (.py), TypeScript (.ts/.tsx), JSON, YAML, SQL, shell,
# Dockerfiles, Makefiles, and config files referenced in spec/bug docs.
PATH_REGEX='(trading-microservice/[A-Za-z0-9_./-]+\.(py|sql|json|yaml|yml|toml)|frontend/[A-Za-z0-9_./-]+\.(ts|tsx|js|json|mjs)|scripts/[A-Za-z0-9_./-]+\.(sh|py)|docker-compose\.yml|Makefile|Dockerfile|\.gitignore|\.env\.example)'
rg -o --no-filename -e "$PATH_REGEX" $(cat "$DOC_FILES_TMP") 2>/dev/null \
  | sed 's#^\./##' \
  | sort -u > "$CONTEXT_PATHS_TMP" || true

if [[ ! -s "$CONTEXT_PATHS_TMP" ]]; then
  echo "No code file paths found in docs; defaulting to all pending stories."
  apply_max_stories_limit "$PENDING_IDS_TMP" "$SELECTED_IDS_TMP"
  STORY_FILTER_IDS="$(build_story_filter_from_file "$SELECTED_IDS_TMP")"
  run_ralph_with_filter "$STORY_FILTER_IDS" "context-fallback-all-pending" "$SELECTED_IDS_TMP"
  exit 0
fi

# Prefer explicit ownedPaths. Fall back to legacy note bullet extraction.
jq -r '
  .userStories[]
  | .id as $id
  | (
      (.ownedPaths // [])
      +
      ((.notes // "")
        | split("\n")
        | map(select(startswith("- ")) | sub("^-\\s+"; ""))
      )
    )
  | unique[]
  | "\($id)\t\(.)"
' "$PRD_FILE" > "$STORY_PATHS_TMP"

while IFS=$'\t' read -r story_id story_path; do
  [[ -z "$story_id" || -z "$story_path" ]] && continue
  while IFS= read -r context_path; do
    if [[ "$story_path" == "$context_path" || "$story_path" == "$context_path/"* || "$context_path" == "$story_path/"* ]]; then
      echo "$story_id" >> "$MATCHED_IDS_TMP"
      break
    fi
  done < "$CONTEXT_PATHS_TMP"
done < "$STORY_PATHS_TMP"

sort -u "$MATCHED_IDS_TMP" > "$MATCHED_IDS_TMP.sorted" && /bin/mv "$MATCHED_IDS_TMP.sorted" "$MATCHED_IDS_TMP"

jq -r '.userStories[] | [.priority, .id, .passes] | @tsv' "$PRD_FILE" \
  | sort -n \
  | while IFS=$'\t' read -r priority story_id passes; do
      if [[ "$passes" == "false" ]] && grep -Fxq "$story_id" "$MATCHED_IDS_TMP"; then
        echo "$story_id"
      fi
    done > "$SELECTED_IDS_TMP.all"

if [[ ! -s "$SELECTED_IDS_TMP.all" ]]; then
  echo "No matching pending stories found for context; defaulting to all pending stories."
  apply_max_stories_limit "$PENDING_IDS_TMP" "$SELECTED_IDS_TMP"
  STORY_FILTER_IDS="$(build_story_filter_from_file "$SELECTED_IDS_TMP")"
  run_ralph_with_filter "$STORY_FILTER_IDS" "context-no-match-fallback-all-pending" "$SELECTED_IDS_TMP"
  exit 0
fi

apply_max_stories_limit "$SELECTED_IDS_TMP.all" "$SELECTED_IDS_TMP"
STORY_FILTER_IDS="$(build_story_filter_from_file "$SELECTED_IDS_TMP")"
run_ralph_with_filter "$STORY_FILTER_IDS" "context-scoped" "$SELECTED_IDS_TMP"
