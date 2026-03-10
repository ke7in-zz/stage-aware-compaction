#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MAX_ITERATIONS="${MAX_ITERATIONS:-2}"
MAX_ATTEMPTS_PER_STORY="${MAX_ATTEMPTS_PER_STORY:-4}"
STORY_TIMEOUT_SECONDS="${STORY_TIMEOUT_SECONDS:-1200}"
REASONING_EFFORT="${REASONING_EFFORT:-medium}"
RALPH_CLI="${RALPH_CLI:-codex}"

if [[ -f "$SCRIPT_DIR/.supervisor.pid" ]]; then
  pid="$(cat "$SCRIPT_DIR/.supervisor.pid" 2>/dev/null || true)"
  if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "Already running: supervisor pid=$pid"
    exit 0
  fi
fi

cd "$REPO_ROOT"
LAUNCH_CMD="cd \"$REPO_ROOT\" && MAX_ITERATIONS=$MAX_ITERATIONS MAX_ATTEMPTS_PER_STORY=$MAX_ATTEMPTS_PER_STORY STORY_TIMEOUT_SECONDS=$STORY_TIMEOUT_SECONDS REASONING_EFFORT=$REASONING_EFFORT RALPH_CLI=$RALPH_CLI ./.codex/ralph-audit/run_supervised.sh"
SETSID_BIN="$(command -v setsid || true)"

if [[ -n "${SETSID_BIN:-}" ]]; then
  nohup "$SETSID_BIN" bash -lc "$LAUNCH_CMD" > "$SCRIPT_DIR/supervisor.nohup.out" 2>&1 < /dev/null &
else
  nohup bash -lc "$LAUNCH_CMD" > "$SCRIPT_DIR/supervisor.nohup.out" 2>&1 < /dev/null &
fi

sleep 1
if [[ -f "$SCRIPT_DIR/.supervisor.pid" ]]; then
  new_pid="$(cat "$SCRIPT_DIR/.supervisor.pid" 2>/dev/null || true)"
  if [[ -n "${new_pid:-}" ]] && kill -0 "$new_pid" 2>/dev/null; then
    echo "Started supervisor pid=$new_pid"
    exit 0
  fi
fi

echo "Launch attempted; check $SCRIPT_DIR/supervisor.nohup.out and $SCRIPT_DIR/supervisor.log"
exit 1
