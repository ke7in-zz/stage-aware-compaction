#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRD_FILE="$SCRIPT_DIR/prd.json"
AUDIT_DIR="$SCRIPT_DIR/audit"
ARCHIVE_ROOT="$SCRIPT_DIR/archive"
DRY_RUN="${DRY_RUN:-false}"

MODE="passed"
GLOB_PATTERN=""
MANIFEST_PATH=""
STORY_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      MODE="all"
      shift
      ;;
    --glob)
      if [[ $# -lt 2 ]]; then
        echo "--glob requires a pattern"
        exit 1
      fi
      MODE="glob"
      GLOB_PATTERN="$2"
      shift 2
      ;;
    --manifest)
      if [[ $# -lt 2 ]]; then
        echo "--manifest requires a file path"
        exit 1
      fi
      MODE="manifest"
      MANIFEST_PATH="$2"
      shift 2
      ;;
    --story)
      if [[ $# -lt 2 ]]; then
        echo "--story requires an AUDIT id"
        exit 1
      fi
      MODE="story"
      STORY_IDS+=("$2")
      shift 2
      ;;
    *)
      echo "Unexpected argument: $1"
      exit 1
      ;;
  esac
done

if [[ ! -f "$PRD_FILE" ]]; then
  echo "Missing PRD file: $PRD_FILE"
  exit 1
fi

if [[ ! -d "$AUDIT_DIR" ]]; then
  echo "Missing audit directory: $AUDIT_DIR"
  exit 1
fi

FILES_TMP="$(mktemp)"
cleanup() {
  /bin/rm -f "$FILES_TMP"
}
trap cleanup EXIT

if [[ "$MODE" == "all" ]]; then
  find "$AUDIT_DIR" -maxdepth 1 -type f -name "*.md" ! -name "00-INDEX.md" | sort > "$FILES_TMP"
elif [[ "$MODE" == "glob" ]]; then
  find "$AUDIT_DIR" -maxdepth 1 -type f -name "$GLOB_PATTERN" ! -name "00-INDEX.md" | sort > "$FILES_TMP"
elif [[ "$MODE" == "manifest" ]]; then
  if [[ ! -f "$MANIFEST_PATH" ]]; then
    echo "Manifest file not found: $MANIFEST_PATH"
    exit 1
  fi
  jq -r '.selectedStories[]?' "$MANIFEST_PATH" 2>/dev/null | while IFS= read -r sid; do
    [[ -z "$sid" ]] && continue
    jq -r --arg id "$sid" '
      .userStories[]
      | select(.id == $id)
      | .acceptanceCriteria[]
      | select(test("^Created "))
      | split(" ")[1]
    ' "$PRD_FILE" | sed 's#^\./##' | while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      case "$rel" in
        .codex/ralph-audit/audit/*)
          if [[ -f "$SCRIPT_DIR/${rel#.codex/ralph-audit/}" ]]; then
            echo "$SCRIPT_DIR/${rel#.codex/ralph-audit/}"
          fi
          ;;
      esac
    done
  done | sort -u > "$FILES_TMP"
elif [[ "$MODE" == "story" ]]; then
  for sid in "${STORY_IDS[@]}"; do
    jq -r --arg id "$sid" '
      .userStories[]
      | select(.id == $id)
      | .acceptanceCriteria[]
      | select(test("^Created "))
      | split(" ")[1]
    ' "$PRD_FILE" | sed 's#^\./##' | while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      case "$rel" in
        .codex/ralph-audit/audit/*)
          if [[ -f "$SCRIPT_DIR/${rel#.codex/ralph-audit/}" ]]; then
            echo "$SCRIPT_DIR/${rel#.codex/ralph-audit/}"
          fi
          ;;
      esac
    done
  done | sort -u > "$FILES_TMP"
else
  # Default mode: archive reports for stories already marked passes:true.
  jq -r '
    .userStories[]
    | select(.passes == true)
    | .acceptanceCriteria[]
    | select(test("^Created "))
    | split(" ")[1]
  ' "$PRD_FILE" | sed 's#^\./##' | while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    case "$rel" in
      .codex/ralph-audit/audit/*)
        local_path="$SCRIPT_DIR/${rel#.codex/ralph-audit/}"
        if [[ -f "$local_path" ]] && [[ "$(basename "$local_path")" != "00-INDEX.md" ]]; then
          echo "$local_path"
        fi
        ;;
    esac
  done | sort -u > "$FILES_TMP"
fi

if [[ ! -s "$FILES_TMP" ]]; then
  echo "No reports matched archive selection."
  exit 0
fi

stamp="$(date '+%Y%m%d-%H%M%S')"
dest_dir="$ARCHIVE_ROOT/$stamp"

echo "Archive mode: $MODE"
echo "Destination: $dest_dir"
echo "Files:"
sed 's#^#- #' "$FILES_TMP"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "DRY_RUN=true: no files moved."
  exit 0
fi

/bin/mkdir -p "$dest_dir"

while IFS= read -r src; do
  base="$(basename "$src")"
  /bin/mv "$src" "$dest_dir/$base"
done < "$FILES_TMP"

manifest="$dest_dir/archive-manifest.json"
jq -n \
  --arg timestamp "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
  --arg mode "$MODE" \
  --arg destination "$dest_dir" \
  --argjson files "$(jq -R . < "$FILES_TMP" | jq -s .)" \
  '{
    timestamp: $timestamp,
    mode: $mode,
    destination: $destination,
    files: $files
  }' > "$manifest"

echo "Archived reports to: $dest_dir"
echo "Manifest: $manifest"
