#!/usr/bin/env bash
# scripts/redeploy-supervisor.sh - redeploy the VPS-155 task-board-loop supervisor
#
# Brings merged main changes (e.g. the PR 6 verify_work test gate, #883) live
# on the device that runs the 24/7 loop: record the deployed commit, fast-
# forward the ~/task-board-loop clone, restart the tmux supervisor session
# with the documented environment, re-ensure the watchdog timer, and print
# liveness evidence. Pure packaging of the README procedure:
#   - pull is --ff-only only; never push, reset, clean, or force anything
#   - the claim environment is not changed, only the documented start env
#   - a failed pull aborts before kill-session, so the old supervisor keeps
#     running (no downtime unless the update itself succeeds)
#   - restarts are human-gated: --apply refuses to run inside CI/unattended
#     environments; the default is a dry-run that only prints the plan
#
# Usage:
#   scripts/redeploy-supervisor.sh             # dry-run: print the exact plan
#   scripts/redeploy-supervisor.sh --apply     # execute over SSH (operator)
#   scripts/redeploy-supervisor.sh --self-test # offline fixtures, no SSH
#
# Env:
#   SUPERVISOR_HOST     SSH target (default ubuntu@155.248.217.255)
#   SUPERVISOR_DIR      clone dir on the target (default ~/task-board-loop;
#                       the tilde expands on the remote host)
#   SUPERVISOR_SESSION  tmux session name (default taskboard-loop)
#   SUPERVISOR_ENV      env for the restarted loop (default documented pair)

set -euo pipefail

APPLY=0
SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

SUPERVISOR_HOST="${SUPERVISOR_HOST:-ubuntu@155.248.217.255}"
SUPERVISOR_DIR="${SUPERVISOR_DIR:-}"
[ -n "$SUPERVISOR_DIR" ] || SUPERVISOR_DIR='~/task-board-loop'
SUPERVISOR_SESSION="${SUPERVISOR_SESSION:-taskboard-loop}"
SUPERVISOR_ENV="${SUPERVISOR_ENV:-OPENCODE_HEADLESS=1 OPENCODE_MODEL=vps-gateway/coding-fast}"

# Plan steps, in execution order. Commands run via the remote shell, so ~ and
# $HOME in SUPERVISOR_DIR expand on the target, never locally.
compose_plan() {
  PLAN_CMD=()
  PLAN_DESC=()
  PLAN_CMD+=("git -C $SUPERVISOR_DIR rev-parse --short HEAD")
  PLAN_DESC+=("record deployed commit (before)")
  PLAN_CMD+=("git -C $SUPERVISOR_DIR pull --ff-only")
  PLAN_DESC+=("fast-forward the supervisor clone to merged main")
  PLAN_CMD+=("tmux kill-session -t $SUPERVISOR_SESSION 2>/dev/null || true")
  PLAN_DESC+=("stop the current supervisor session, if any")
  PLAN_CMD+=("tmux new-session -d -s $SUPERVISOR_SESSION -c $SUPERVISOR_DIR \"env $SUPERVISOR_ENV ./task-board-loop.sh\"")
  PLAN_DESC+=("start the supervisor on the merged code")
  PLAN_CMD+=("systemctl --user enable --now task-board-loop-watchdog.timer")
  PLAN_DESC+=("re-ensure the watchdog timer")
  PLAN_CMD+=("tmux ls 2>/dev/null | grep $SUPERVISOR_SESSION || true")
  PLAN_DESC+=("evidence: supervisor session is up")
  PLAN_CMD+=("cat /tmp/agent-loop.heartbeat 2>/dev/null || true")
  PLAN_DESC+=("evidence: heartbeat file")
  PLAN_CMD+=("git -C $SUPERVISOR_DIR rev-parse --short HEAD")
  PLAN_DESC+=("record deployed commit (after)")
}

run_plan() {
  local i
  for i in "${!PLAN_CMD[@]}"; do
    if [ "$APPLY" = "1" ]; then
      echo "redeploy: ${PLAN_DESC[$i]}"
      ssh "$SUPERVISOR_HOST" "${PLAN_CMD[$i]}"
    else
      printf 'dry-run: %s\n  ssh %s %s\n' "${PLAN_DESC[$i]}" "$SUPERVISOR_HOST" "${PLAN_CMD[$i]}"
    fi
  done
}

if [ "$SELF_TEST" = "1" ]; then
  fails=0
  rt_fail() { echo "FAIL: $1"; fails=$((fails+1)); }
  SUPERVISOR_HOST=user@fixture-host
  SUPERVISOR_DIR='~/fixture-loop'
  SUPERVISOR_SESSION=fixture-session
  SUPERVISOR_ENV='OPENCODE_HEADLESS=1 OPENCODE_MODEL=fixture/model'
  compose_plan
  joined="$(printf '%s\n' "${PLAN_CMD[@]}")"
  [ "${#PLAN_CMD[@]}" = 8 ] || rt_fail "plan has ${#PLAN_CMD[@]} steps, want 8"
  case "$joined" in
    *"pull --ff-only"*) : ;;
    *) rt_fail "plan must fast-forward with pull --ff-only" ;;
  esac
  case "$joined" in
    *"reset --hard"*|*" rm -rf"*|*--force*|*" push "*|*" git clean"*)
      rt_fail "plan must never reset, clean, force, or push" ;;
  esac
  pi=0; ki=0; si=0; n=0
  for i in "${!PLAN_CMD[@]}"; do
    case "${PLAN_CMD[$i]}" in
      *"pull --ff-only"*) pi=$i ;;
      *"kill-session"*) ki=$i ;;
      *"new-session"*) si=$i ;;
    esac
  done
  [ "$pi" -lt "$ki" ] && [ "$ki" -lt "$si" ] || rt_fail "plan must pull, then kill, then start (got pull=$pi kill=$ki start=$si)"
  start_cmd="${PLAN_CMD[$si]}"
  case "$start_cmd" in
    *"-s $SUPERVISOR_SESSION -c $SUPERVISOR_DIR"*) : ;;
    *) rt_fail "restart must use documented session and dir" ;;
  esac
  case "$start_cmd" in
    *"env $SUPERVISOR_ENV ./task-board-loop.sh"*) : ;;
    *) rt_fail "restart must run the documented env + loop entrypoint" ;;
  esac
  # dry-run prints the plan without any SSH traffic
  APPLY=0
  ssh() { echo "SSH-CALLED $*"; }
  dry_out="$(run_plan)"
  case "$dry_out" in *"SSH-CALLED"*) rt_fail "dry-run must not ssh" ;; esac
  case "$dry_out" in *"ssh $SUPERVISOR_HOST"*) : ;; *) rt_fail "dry-run must print the exact commands" ;; esac
  # apply path executes every step over ssh, in order, one host per call
  APPLY=1
  calls_file="$(mktemp)"
  ssh() { printf 'CALL:%s\n' "$2" >> "$calls_file"; }
  run_plan >/dev/null
  call_count="$(grep -c '^CALL:' "$calls_file")"
  [ "$call_count" = "${#PLAN_CMD[@]}" ] || rt_fail "apply ran $call_count ssh calls, want ${#PLAN_CMD[@]}"
  first_call="$(sed -n 's/^CALL://p' "$calls_file" | head -1)"
  [ "$first_call" = "git -C $SUPERVISOR_DIR rev-parse --short HEAD" ] || rt_fail "apply must record the before-commit first"
  rm -f "$calls_file"
  unset -f ssh
  # operator gate: unattended CI must never restart the live supervisor
  GITHUB_ACTIONS=set APPLY=1
  if GITHUB_ACTIONS=set "$0" --apply >/dev/null 2>&1; then
    rt_fail "--apply must refuse under GITHUB_ACTIONS"
  fi
  [ "$fails" = 0 ] && { echo "self-test: ALL PASS"; exit 0; }
  echo "self-test: $fails FAILURES"
  exit 1
fi

if [ "$APPLY" = "1" ]; then
  if [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${CI:-}" ]; then
    echo "refusing --apply: supervisor restarts are human-gated, never run from CI" >&2
    exit 2
  fi
  command -v ssh >/dev/null 2>&1 || { echo "ssh client required" >&2; exit 1; }
fi

compose_plan
if [ "$APPLY" != "1" ]; then
  echo "supervisor redeploy plan (dry-run; pass --apply on the operator host):"
fi
run_plan
[ "$APPLY" = "1" ] && echo "redeploy: supervisor restarted on merged code; verify session + heartbeat above"
