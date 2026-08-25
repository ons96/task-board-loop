#!/usr/bin/env bash
# task-board-loop.sh - Autonomous multi-device task worker
# - Lists open issues with status:new (or --label override)
# - Claims one (adds locked-by:<worker-id> + status:in_progress) - others skip
# - Creates git worktree, runs /work, opens PR, comments on issue
# - Handles errors, never force-pushes, never force-removes worktrees with changes
# - Posts heartbeat comments so watchdog.sh detects liveness
# - Marks status:blocked + comment if /work can't proceed
# - Health: writes last-heartbeat to $HEARTBEAT_FILE for systemd watchdog timer
#
# Usage:
#   ./task-board-loop.sh                # run forever
#   ./task-board-loop.sh --once         # do one issue, exit
#   ./task-board-loop.sh --max N        # stop after N issues
#   ./task-board-loop.sh --dry-run      # claim+list only, don't actually work
#   ./task-board-loop.sh --label X,Y    # custom label filter (default: status:new)
#   ./task-board-loop.sh --worker ID    # explicit worker ID (auto-detect otherwise)
#   ./task-board-loop.sh --worktree-dir DIR  # parent dir for worktrees
#
# Locking scheme (matches claim-task.sh + run-task.sh):
#   WORKER_ID:     gha-${GITHUB_RUN_ID} | local-${HOSTNAME} | local-$$
#   LOCK_LABEL:    locked-by:${WORKER_ID}
#   Claim:         gh issue edit --add-label status:in_progress --add-label locked-by:WORKER_ID --remove-label status:new
#   Race check:    sleep 2s, re-read labels, confirm our LOCK_LABEL is present
#   Release:       gh issue edit --remove-label status:in_progress --remove-label locked-by:WORKER_ID --add-label <done|blocked>
#   Heartbeat:     comment "heartbeat" every HEARTBEAT_INTERVAL seconds during work
#                  (watchdog.sh reads last comment containing "heartbeat|Claimed by|Still working")
#
# Env:
#   REPO              path to git repo (default: $PWD)
#   WORKER_ID         explicit worker ID (default: auto-detect gha-/local-)
#   HEARTBEAT_FILE    path (default: /tmp/agent-loop.heartbeat)
#   HEARTBEAT_INTERVAL seconds between heartbeat comments (default: 300)
#   OPENCODE_BIN      opencode binary/wrapper (overrides all defaults)
#   OPENCODE_HEADLESS set to 1 to use bundled VPS headless wrapper
#   IDLE_SLEEP        seconds to wait when no work (default: 60)
#   OPENCODE_TIMEOUT  max seconds per /work (default: 1800 = 30min)
#   MAX_RETRIES       per-issue retry count on transient failure (default: 2)
#   STALE_TIMEOUT     watchdog frees tasks after this many seconds of no heartbeat (default: 600)
#   TASK_BOARD_REPO   GitHub repo for issue queue (default: ons96/task-board)

set -euo pipefail
TASK_BOARD_REPO="${TASK_BOARD_REPO:-ons96/task-board}"

# --- args ---
ONCE=0
MAX=0
DRY=0
LABELS="status:new"
WORKTREE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --max) MAX="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --label) LABELS="$2"; shift 2 ;;
    --worker) WORKER_ID="$2"; shift 2 ;;
    --worktree-dir) WORKTREE_DIR="$2"; shift 2 ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- env ---
REPO="${REPO:-$PWD}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-/tmp/agent-loop.heartbeat}"
LOG_DIR="${LOG_DIR:-$HOME/.local/state/task-board-loop/logs}"
mkdir -p "$LOG_DIR"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HEADLESS_OPENCODE_BIN="$SCRIPT_DIR/opencode-headless.sh"
DEFAULT_OPENCODE_BIN="$HOME/.config/opencode/scripts/opencode-resilient.sh"
# ponytail: hardcode real opencode path so non-interactive tmux shells (no PATH rc) find it
export OPENCODE_REAL_BIN="${OPENCODE_REAL_BIN:-$HOME/.opencode/bin/opencode}"
if [ "${OPENCODE_HEADLESS:-0}" = "1" ] && [ -x "$HEADLESS_OPENCODE_BIN" ]; then
  OPENCODE_BIN="${OPENCODE_BIN:-$HEADLESS_OPENCODE_BIN}"
elif [ -x "$DEFAULT_OPENCODE_BIN" ]; then
  OPENCODE_BIN="${OPENCODE_BIN:-$DEFAULT_OPENCODE_BIN}"
else
  OPENCODE_BIN="${OPENCODE_BIN:-$HOME/.opencode/bin/opencode}"
fi
IDLE_SLEEP="${IDLE_SLEEP:-60}"
OPENCODE_TIMEOUT="${OPENCODE_TIMEOUT:-1800}"
MAX_RETRIES="${MAX_RETRIES:-2}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-300}"
STALE_TIMEOUT="${STALE_TIMEOUT:-600}"
# Terminal labels (filter these out + use for completion)
DONE_LABEL="${DONE_LABEL:-status:done}"
BLOCKED_LABEL="${BLOCKED_LABEL:-status:blocked}"
IN_PROGRESS_LABEL="${IN_PROGRESS_LABEL:-status:in_progress}"

# --- canonical WORKER_ID (matches claim-task.sh) ---
if [[ -z "${WORKER_ID:-}" ]]; then
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    WORKER_ID="gha-${GITHUB_RUN_ID:-unknown}"
  elif [[ -n "${HOSTNAME:-}" ]]; then
    WORKER_ID="local-${HOSTNAME}"
  else
    WORKER_ID="local-$$"
  fi
fi
LOCK_LABEL="locked-by:${WORKER_ID}"

# Validate label syntax (gh label name rules: 1-50 chars, no leading/trailing -, no commas)
if [[ ! "$LOCK_LABEL" =~ ^[a-zA-Z0-9_:\.\-]{1,50}$ ]]; then
  echo "invalid WORKER_ID -> LOCK_LABEL: $LOCK_LABEL" >&2
  exit 1
fi

[ -d "$REPO/.git" ] || { echo "warning: launch cwd not a git repo: $REPO (per-issue resolution will be used)" >&2; }
command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }
command -v "$OPENCODE_BIN" >/dev/null || { echo "opencode not on PATH" >&2; exit 1; }

cd "$REPO"
REPO_PARENT="$(dirname "$REPO")"
REPO_NAME="$(basename "$REPO")"
[ -n "$WORKTREE_DIR" ] || WORKTREE_DIR="$REPO_PARENT/${REPO_NAME}-worktrees"
mkdir -p "$WORKTREE_DIR"

# Resolve main branch name
MAIN_BRANCH="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)"
# ponytail: preserve launch values for per-issue fallback (multi-repo task-board)
LAUNCH_REPO="$REPO"
LAUNCH_WORKTREE_DIR="$WORKTREE_DIR"
LAUNCH_MAIN_BRANCH="$MAIN_BRANCH"
echo "task-board-loop: repo=$REPO main=$MAIN_BRANCH worker=$WORKER_ID lock=$LOCK_LABEL labels=$LABELS worktrees=$WORKTREE_DIR"

# --- counters ---
DONE=0
SKIPPED=0
BLOCKED=0
FAILED=0

# --- heartbeat (file for systemd watchdog timer) ---
heartbeat() {
  date -u +%Y-%m-%dT%H:%M:%SZ > "$HEARTBEAT_FILE"
  echo "[$(date +%H:%M:%S)] $*" >&2
}

# --- issue comments ---
# Two flavors:
#   heartbeat_comment "N" -> short "heartbeat" comment so watchdog.sh sees liveness
#   claim_comment "N"     -> one-time "Claimed by WORKER_ID" on successful claim
GH_TIMEOUT="${GH_TIMEOUT:-30}"
comment() {
  local n="$1" body="$2"
  timeout "$GH_TIMEOUT" gh issue comment "$n" -R "$TASK_BOARD_REPO" --body "$body" >/dev/null 2>&1 || \
    heartbeat "comment on #$n timed out/failed (non-fatal)"
}

# --- find next claimable issue ---
# claimable = has all of $LABELS, no status:done, no status:blocked, no locked-by:* label
next_issue() {
  local l1 l2
  l1="$(echo "$LABELS" | cut -d, -f1)"
  l2="$(echo "$LABELS" | cut -d, -f2)"
  local jq_filter
  jq_filter='
      .[]
      | select((.labels | map(.name) | any(. == "'"$DONE_LABEL"'" or . == "'"$BLOCKED_LABEL"'" or startswith("locked-by:"))) | not)
      | .number
    '
  if [ -n "$l2" ] && [ "$l2" != "$l1" ]; then
    gh issue list -R "$TASK_BOARD_REPO" --label "$l1" --label "$l2" --state open --json number,title,labels --limit 100 | jq -r "$jq_filter" | head -1
  else
    gh issue list -R "$TASK_BOARD_REPO" --label "$l1" --state open --json number,title,labels --limit 100 | jq -r "$jq_filter" | head -1
  fi
}

# --- claim issue (label-based, matches claim-task.sh) ---
# Steps:
#   1. Ensure LOCK_LABEL exists in repo (gh label create, idempotent)
#   2. gh issue edit: add status:in_progress + LOCK_LABEL, remove status:new
#   3. sleep 2s grace period
#   4. Re-read labels; if our LOCK_LABEL is not present, we lost the race
# Returns: 0 if claim succeeded, 1 if lost race or API error
claim() {
  local n="$1"
  gh label create "$LOCK_LABEL" -R "$TASK_BOARD_REPO" --color "BFD4F2" 2>/dev/null || true

  if ! gh issue edit "$n" -R "$TASK_BOARD_REPO" \
    --add-label "$IN_PROGRESS_LABEL" \
    --add-label "$LOCK_LABEL" \
    --remove-label "status:new" 2>/dev/null; then
    return 1
  fi

  sleep 2

  local current_lock
  current_lock=$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json labels --jq \
    '[.labels[] | select(.name | startswith("locked-by:")) | .name] | first // ""' 2>/dev/null || echo "")

  if [[ "$current_lock" != "$LOCK_LABEL" ]]; then
    heartbeat "issue #$n claimed by '${current_lock:-none}' after we tried, releasing"
    gh issue edit "$n" -R "$TASK_BOARD_REPO" \
      --remove-label "$IN_PROGRESS_LABEL" \
      --remove-label "$LOCK_LABEL" \
      --add-label "status:new" 2>/dev/null || true
    return 1
  fi

  comment "$n" "Claimed by \`${WORKER_ID}\` at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  return 0
}

# --- release lock + transition to terminal label ---
unclaim() {
  local n="$1" label="$2"  # label = $DONE_LABEL | $BLOCKED_LABEL
  gh issue edit "$n" -R "$TASK_BOARD_REPO" \
    --remove-label "$IN_PROGRESS_LABEL" \
    --remove-label "$LOCK_LABEL" \
    --add-label "$label" 2>/dev/null || true
}

# --- cleanup worktree safely (never force-removes with changes) ---
cleanup_worktree() {
  local wt="$1"
  if [ -d "$wt" ]; then
    cd "$wt"
    if [ -z "$(git status --porcelain)" ]; then
      cd "$REPO"
      git worktree remove "$wt" 2>/dev/null || git worktree remove --force "$wt" 2>/dev/null || true
    else
      heartbeat "worktree $wt has uncommitted changes, leaving in place"
    fi
  fi
}

# --- background heartbeat comment poster ---
# Spawns a subshell that posts "heartbeat" comments every $HEARTBEAT_INTERVAL seconds
# while PID file exists. Caller removes the PID file on stop.
start_heartbeat_poster() {
  local issue_num="$1"
  local pid_file="$LOG_DIR/issue-${issue_num}.hb.pid"
  (
    while [ -f "$pid_file" ]; do
      sleep "$HEARTBEAT_INTERVAL"
      [ -f "$pid_file" ] || break
      timeout "$GH_TIMEOUT" gh issue comment "$issue_num" -R "$TASK_BOARD_REPO" --body \
        "heartbeat from \`${WORKER_ID}\` at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >/dev/null 2>&1 || true
    done
  ) &
  echo $! > "$pid_file"
}

stop_heartbeat_poster() {
  local pid_file="$LOG_DIR/issue-${1}.hb.pid"
  [ -f "$pid_file" ] && rm -f "$pid_file"
  # subshell exits on its own when pid_file disappears
}

# Resolve target repo for an issue from its project:<repo> label.
# Overrides globals (REPO/WORKTREE_DIR/etc) per-issue; falls back to launch values.
# ponytail: mutates globals -- safe because loop is sequential (one do_issue at a time)
resolve_repo_for_issue() {
  local n="$1" proj
  proj="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json labels --jq '.labels[].name' 2>/dev/null \
          | grep -oE '^project:[a-z0-9_-]+$' | head -1 | cut -d: -f2)"
  if [ -n "$proj" ] && [ -d "$HOME/CodingProjects/$proj/.git" ]; then
    REPO="$HOME/CodingProjects/$proj"
    REPO_PARENT="$(dirname "$REPO")"
    REPO_NAME="$(basename "$REPO")"
    WORKTREE_DIR="$REPO_PARENT/${REPO_NAME}-worktrees"
    MAIN_BRANCH="$(cd "$REPO" && git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main)"
  else
    REPO="$LAUNCH_REPO"
    REPO_PARENT="$(dirname "$REPO")"
    REPO_NAME="$(basename "$REPO")"
    WORKTREE_DIR="$LAUNCH_WORKTREE_DIR"
    MAIN_BRANCH="$LAUNCH_MAIN_BRANCH"
  fi
  mkdir -p "$WORKTREE_DIR"
  cd "$REPO"
}

# --- run /work on a single issue ---
do_issue() {
  local n="$1" retry=0

  heartbeat "claiming issue #$n"
  if ! claim "$n"; then
    heartbeat "claim failed for #$n (race?), skipping"
    SKIPPED=$((SKIPPED+1))
    return 1
  fi

  # claim success -> ensure we always release the lock on any exit path
  # ponytail: || true inside trap - a failing trap under set -e kills the whole script (seen live: double-unclaim after blocked path exited code 1)
  trap "stop_heartbeat_poster '$n' 2>/dev/null || true; unclaim '$n' '$BLOCKED_LABEL' 2>/dev/null || true" RETURN

  # resolve target repo per-issue (multi-repo task-board support)
  resolve_repo_for_issue "$n"
  local wt="$WORKTREE_DIR/wt-$n"
  local branch="work/$n"

  # create worktree
  heartbeat "creating worktree $wt on branch $branch"
  if ! git worktree add "$wt" -b "$branch" "$MAIN_BRANCH" 2>/dev/null; then
    # ponytail: branch may exist on remote only (GHA-era work/N) - fetch before reusing it
    git fetch origin "$branch" 2>/dev/null || true
    git worktree add "$wt" "$branch" 2>/dev/null || {
      comment "$n" "task-board-loop: failed to create worktree, marking blocked"
      unclaim "$n" "$BLOCKED_LABEL"
      BLOCKED=$((BLOCKED+1))
      return 1
    }
  fi

  # run opencode with /work prompt, retry up to MAX_RETRIES times
  start_heartbeat_poster "$n"
  while [ "$retry" -le "$MAX_RETRIES" ]; do
    heartbeat "running /work $n (attempt $((retry+1)))"
    if [ "$DRY" = "1" ]; then
      heartbeat "dry-run: would run: cd $wt && $OPENCODE_BIN run < /work prompt"
      result=0
    else
      cd "$wt"
      local issue_meta
      issue_meta="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json title,body,labels,number --jq '{n:.number,t:.title,b:.body,labs:[.labels[].name]}' 2>/dev/null)"
      local prompt
      prompt=$(cat <<EOF
/work $n

Issue: #$n
Title: $(echo "$issue_meta" | jq -r .t)
Labels: $(echo "$issue_meta" | jq -r '.labs | join(", ")')

Body:
$(echo "$issue_meta" | jq -r .b)
EOF
)
      set +e
      timeout "$OPENCODE_TIMEOUT" "$OPENCODE_BIN" run -m "${OPENCODE_MODEL:-opencode_zen/x-preview-f-free}" "$prompt" 2>&1 | tee "$LOG_DIR/issue-$n.log"
      result=${PIPESTATUS[0]}
      set -e
    fi
    if [ "$result" = "0" ]; then
      if [ "$DRY" = "1" ]; then
        heartbeat "dry-run: reverting claim on #$n (back to status:new)"
        gh issue edit "$n" -R "$TASK_BOARD_REPO" \
          --remove-label "$IN_PROGRESS_LABEL" \
          --remove-label "$LOCK_LABEL" \
          --add-label "status:new" 2>/dev/null || true
        cleanup_worktree "$wt"
        stop_heartbeat_poster "$n"
        trap - RETURN
        DONE=$((DONE+1))
        return 0
      fi
      comment "$n" "task-board-loop: completed on attempt $((retry+1))"
      unclaim "$n" "$DONE_LABEL"
      cleanup_worktree "$wt"
      stop_heartbeat_poster "$n"
      trap - RETURN
      DONE=$((DONE+1))
      return 0
    fi
    retry=$((retry+1))
    if [ "$retry" -le "$MAX_RETRIES" ]; then
      heartbeat "attempt $retry failed (exit=$result), retrying in 30s"
      sleep 30
    fi
  done

  # all retries exhausted
  comment "$n" "task-board-loop: failed after $((MAX_RETRIES+1)) attempts. Log: \`$LOG_DIR/issue-$n.log\`. Needs investigation."
  unclaim "$n" "$BLOCKED_LABEL"
  cleanup_worktree "$wt"
  stop_heartbeat_poster "$n"
  trap - RETURN
  FAILED=$((FAILED+1))
  return 1
}

# --- main loop ---
heartbeat "starting (once=$ONCE max=$MAX dry=$DRY)"
trap 'heartbeat "interrupted, summary: done=$DONE skipped=$SKIPPED blocked=$BLOCKED failed=$FAILED"; exit 130' INT TERM

while :; do
  heartbeat
  N="$(next_issue || true)"
  if [ -z "$N" ]; then
    heartbeat "no claimable issues, sleeping ${IDLE_SLEEP}s"
    if [ "$ONCE" = "1" ]; then
      heartbeat "(--once) exiting. summary: done=$DONE skipped=$SKIPPED blocked=$BLOCKED failed=$FAILED"
      exit 0
    fi
    sleep "$IDLE_SLEEP"
    continue
  fi

  do_issue "$N" || true

  if [ "$ONCE" = "1" ]; then
    heartbeat "(--once) exiting. summary: done=$DONE skipped=$SKIPPED blocked=$BLOCKED failed=$FAILED"
    exit 0
  fi
  if [ "$MAX" -gt 0 ] && [ "$DONE" -ge "$MAX" ]; then
    heartbeat "(--max=$MAX) reached, exiting. summary: done=$DONE skipped=$SKIPPED blocked=$BLOCKED failed=$FAILED"
    exit 0
  fi
done
