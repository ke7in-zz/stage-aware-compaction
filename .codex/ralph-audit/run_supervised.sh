#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPH_SCRIPT="$SCRIPT_DIR/ralph.sh"
SUP_PID_FILE="$SCRIPT_DIR/.supervisor.pid"
SUP_LOG="$SCRIPT_DIR/supervisor.log"

MAX_ITERATIONS="${MAX_ITERATIONS:-3}"
MAX_ATTEMPTS_PER_STORY="${MAX_ATTEMPTS_PER_STORY:-3}"
STORY_TIMEOUT_SECONDS="${STORY_TIMEOUT_SECONDS:-1500}"
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
RALPH_CLI="${RALPH_CLI:-codex}"

if [[ -f "$SUP_PID_FILE" ]]; then
  OLD_PID="$(cat "$SUP_PID_FILE" 2>/dev/null || true)"
  if [[ -n "${OLD_PID:-}" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Supervisor already running (pid=$OLD_PID)."
    exit 0
  fi
fi

echo $$ > "$SUP_PID_FILE"

cleanup() {
  /bin/rm -f "$SUP_PID_FILE" 2>/dev/null || true
}
trap cleanup EXIT
trap 'echo "[$(date "+%Y-%m-%dT%H:%M:%S%z")] SUPERVISOR SIGNAL SIGHUP (ignored)" >> "$SUP_LOG"' HUP

echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] SUPERVISOR START pid=$$" >> "$SUP_LOG"

clear_or_wait_on_lock() {
  local lock_dir="$SCRIPT_DIR/.run-lock"
  if [[ ! -d "$lock_dir" ]]; then
    return 0
  fi

  local lock_pid=""
  lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || true)"

  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] SUPERVISOR WAIT active_lock_pid=$lock_pid" >> "$SUP_LOG"
    sleep 10
    return 1
  fi

  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] SUPERVISOR CLEAR stale_lock" >> "$SUP_LOG"
  /bin/rm -rf "$lock_dir"
  return 0
}

while true; do
  if ! clear_or_wait_on_lock; then
    continue
  fi

  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] SUPERVISOR LAUNCH" >> "$SUP_LOG"
  set +e
  MAX_ATTEMPTS_PER_STORY="$MAX_ATTEMPTS_PER_STORY" \
  STORY_TIMEOUT_SECONDS="$STORY_TIMEOUT_SECONDS" \
  REASONING_EFFORT="$REASONING_EFFORT" \
  "$RALPH_SCRIPT" "$MAX_ITERATIONS" --cli "$RALPH_CLI" --skip-security-check --no-search >> "$SUP_LOG" 2>&1
  RC=$?
  set -e

  echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] SUPERVISOR EXIT_CODE rc=$RC" >> "$SUP_LOG"

  # 0 means all stories complete.
  if [[ "$RC" -eq 0 ]]; then
    echo "[$(date '+%Y-%m-%dT%H:%M:%S%z')] SUPERVISOR COMPLETE" >> "$SUP_LOG"
    exit 0
  fi

  # Keep relaunching to survive intermittent codex or session failures.
  sleep 5
done
