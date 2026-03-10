#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_DIR="$SCRIPT_DIR/audit"
OUT_DIR="$SCRIPT_DIR/fix-plans"

REPORT_GLOB="${1:-all}"
TOP_N="${TOP_N:-40}"

/bin/mkdir -p "$OUT_DIR"

plan_path="$OUT_DIR/fix-plan-$(date '+%Y%m%d-%H%M%S').md"

collect_reports() {
  if [[ "$REPORT_GLOB" == "all" ]]; then
    find "$AUDIT_DIR" -maxdepth 1 -type f -name "*.md" ! -name "00-INDEX.md" | sort
  else
    find "$AUDIT_DIR" -maxdepth 1 -type f -name "$REPORT_GLOB" | sort
  fi
}

mapfile_reports_tmp="$(mktemp)"
findings_tmp="$(mktemp)"
cleanup() {
  /bin/rm -f "$mapfile_reports_tmp" "$findings_tmp"
}
trap cleanup EXIT

collect_reports > "$mapfile_reports_tmp"
if [[ ! -s "$mapfile_reports_tmp" ]]; then
  echo "No reports found for selector: $REPORT_GLOB"
  exit 1
fi

while IFS= read -r report; do
  awk -v report="$(basename "$report")" '
    BEGIN { sev=""; title=""; file=""; lines=""; cat="" }
    /^### \[/ {
      sev=$0
      sub(/^### \[/, "", sev)
      sub(/\].*$/, "", sev)
      title=$0
      sub(/^### \[[A-Z]+\] Finding #[0-9]+: /, "", title)
      file=""; lines=""; cat=""
    }
    /^\*\*File:\*\*/ {
      file=$0
      sub(/^\*\*File:\*\* /, "", file)
      gsub(/`/, "", file)
      gsub(/[[:space:]]+$/, "", file)
    }
    /^\*\*Lines:\*\*/ {
      lines=$0
      sub(/^\*\*Lines:\*\* /, "", lines)
      gsub(/`/, "", lines)
      gsub(/[[:space:]]+$/, "", lines)
    }
    /^\*\*Category:\*\*/ {
      cat=$0
      sub(/^\*\*Category:\*\* /, "", cat)
    }
    /^---$/ {
      if (sev != "" && title != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", sev, title, file, lines, cat, report
      }
      sev=""; title=""; file=""; lines=""; cat=""
    }
    END {
      if (sev != "" && title != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", sev, title, file, lines, cat, report
      }
    }
  ' "$report" >> "$findings_tmp"
done < "$mapfile_reports_tmp"

severity_rank() {
  case "$1" in
    CRITICAL) echo 1 ;;
    HIGH) echo 2 ;;
    MEDIUM) echo 3 ;;
    LOW) echo 4 ;;
    *) echo 9 ;;
  esac
}

{
  echo "# Ralph Fix Plan"
  echo
  echo "Generated: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "Report selector: \`$REPORT_GLOB\`"
  echo "Top findings: \`$TOP_N\`"
  echo
  echo "## Prioritized Backlog"
  echo
  count=0
  while IFS=$'\t' read -r sev title file lines cat report; do
    rank="$(severity_rank "$sev")"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$rank" "$sev" "$title" "$file" "$lines" "$cat" "$report"
  done < "$findings_tmp" \
    | sort -t$'\t' -k1,1n -k2,2 -k7,7 \
    | while IFS=$'\t' read -r rank sev title file lines cat report; do
        count=$((count + 1))
        if [[ "$count" -gt "$TOP_N" ]]; then
          break
        fi
        echo "- [ ] [$sev] $title"
        echo "  - Source report: \`$report\`"
        if [[ -n "$file" ]]; then
          echo "  - File: \`$file\`"
        fi
        if [[ -n "$lines" ]]; then
          echo "  - Lines: \`$lines\`"
        fi
        if [[ -n "$cat" ]]; then
          echo "  - Category: $cat"
        fi
      done
  echo
  echo "## Execution Workflow"
  echo
  echo "- Create a bug/spec item for each Critical/High cluster."
  echo "- Implement fixes in small batches (3-7 findings) with tests."
  echo "- Re-run scoped Ralph: \`/ralph-run <same context> --max-stories N\`."
  echo "- Close batch only when findings are eliminated or reclassified with rationale."
} > "$plan_path"

echo "Created fix plan: $plan_path"
