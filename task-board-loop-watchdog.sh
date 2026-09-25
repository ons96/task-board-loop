#!/usr/bin/env bash
set -euo pipefail

heartbeat="${HEARTBEAT_FILE:-/tmp/agent-loop.heartbeat}"
pid_file="${LOOP_PID_FILE:-/tmp/task-board-loop.pid}"
max_age="${WATCHDOG_MAX_AGE:-1800}"
now="$(date +%s)"

if [[ "${1:-}" == "--self-test" && "${WATCHDOG_SELF_TEST_CHILD:-0}" != "1" ]]; then
  test_dir="$(mktemp -d)"
  trap 'rm -rf "$test_dir"' EXIT
  HEARTBEAT_FILE="$test_dir/hb" LOOP_PID_FILE="$test_dir/pid" bash -c 'exec -a task-board-loop.sh sleep 30' &
  test_pid=$!
  printf '%s\n' "$test_pid" > "$test_dir/pid"
  printf '%s\n' 'stale' > "$test_dir/hb"
  touch -d '2 hours ago' "$test_dir/hb"
  WATCHDOG_SELF_TEST_CHILD=1 WATCHDOG_MAX_AGE=1 HEARTBEAT_FILE="$test_dir/hb" LOOP_PID_FILE="$test_dir/pid" "$0" >/dev/null
  kill "$test_pid" 2>/dev/null || true
  wait "$test_pid" 2>/dev/null || true
  echo "watchdog self-test: PASS"
  exit 0
fi

[[ "$max_age" =~ ^[0-9]+$ ]] || { echo "invalid WATCHDOG_MAX_AGE" >&2; exit 2; }
[[ -f "$heartbeat" && -f "$pid_file" ]] || { echo "watchdog: no managed loop"; exit 0; }
read -r pid < "$pid_file" || true
[[ "${pid:-}" =~ ^[1-9][0-9]*$ ]] || { echo "watchdog: invalid pid file" >&2; exit 2; }
kill -0 "$pid" 2>/dev/null || { echo "watchdog: managed pid is not running"; exit 0; }
cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
[[ "$cmd" == *task-board-loop.sh* ]] || { echo "watchdog: pid identity mismatch; refusing to signal" >&2; exit 1; }
heartbeat_mtime="$(stat -c %Y "$heartbeat" 2>/dev/null || echo 0)"
[[ "$heartbeat_mtime" =~ ^[0-9]+$ ]] || { echo "watchdog: invalid heartbeat mtime" >&2; exit 2; }
age=$((now - heartbeat_mtime))
(( age >= 0 )) || { echo "watchdog: heartbeat timestamp is in the future" >&2; exit 2; }
if (( age <= max_age )); then echo "watchdog: healthy (${age}s)"; exit 0; fi
kill -TERM "$pid"
echo "watchdog: terminated managed pid $pid after ${age}s stale heartbeat"
