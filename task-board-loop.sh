#!/usr/bin/env bash
# task-board-loop.sh - Autonomous multi-device task worker
# - Lists open issues with status:new (or --label override)
# - Claims one (adds locked-by:<worker-id> + status:in_progress) - others skip
# - Creates git worktree, runs /work, opens PR, comments on issue
# - Handles errors, never force-pushes, never force-removes worktrees with changes
# - Recovers occupied worktree paths: a stale wt dir from a dead run is reused or
#   adopted (uncommitted leftovers kept, never force-removed), not a blocker (#929)
# - Posts heartbeat comments so watchdog.sh detects liveness
# - Marks status:blocked + comment if /work can't proceed
# - Health: writes last-heartbeat to $HEARTBEAT_FILE for systemd watchdog timer
#
# Usage:
#   ./task-board-loop.sh                # run forever
#   ./task-board-loop.sh --once         # do one issue, exit
#   ./task-board-loop.sh --max N        # stop after N issues
#   ./task-board-loop.sh --dry-run      # claim+list only, don't actually work
#   ./task-board-loop.sh --self-test    # unit-test lock/sweep decision logic, exit
#   ./task-board-loop.sh --simulate     # local-only logic simulation; no network/process side effects
#   ./task-board-loop.sh --label X,Y    # custom label filter (default: status:new)
#   ./task-board-loop.sh --worker ID    # explicit worker ID (auto-detect otherwise)
#   ./task-board-loop.sh --worktree-dir DIR  # parent dir for worktrees
#
# Locking scheme (matches claim-task.sh + run-task.sh):
#   WORKER_ID:     gha-${GITHUB_RUN_ID} | local-${HOSTNAME} | local-$$
#   LOCK_LABEL:    locked-by:${WORKER_ID}
#   Claim:         gh issue edit --add-label status:in_progress --add-label locked-by:WORKER_ID --remove-label status:new
#   Race check:    pre-read labels (must be status:new + no locked-by:*), edit, sleep 2s, re-read, confirm our LOCK_LABEL
#   Release:       gh issue edit --remove-label status:in_progress --remove-label locked-by:WORKER_ID --add-label <done|blocked>
#   Stale TTL:     sweep_stale_locks() frees status:in_progress with no sign of life:
#                    same-host lock  -> free only if no live pid AND no heartbeat comment within STALE_GRACE
#                    other-host lock -> free only if neither update nor heartbeat comment within LOCK_TTL (48h)
#                  always posts a comment when freeing (the comment refreshes updatedAt = anti-flap)
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
#   OPENCODE_MODEL_CHAIN comma-separated opencode model ids; retry advances to next (default below)
#   FREE_MODEL_ALLOWLIST comma-separated models with current verified-free evidence; required for live runs
#   OPENCODE_MODEL    if set, prepended to the chain as first choice
#   MIN_LOG_BYTES     verify gate: /work log smaller than this = failure (default: 200)
#   OPENCODE_NICE     CPU niceness for active runs (default: 10)
#   OPENCODE_IONICE   I/O priority class for active runs (default: 3/idle)
#   OPENCODE_MEMORY_MAX_MB optional systemd user-scope memory cap
#   PAUSE_ON_HUMAN     pause claims while a user's opencode/omp session exists (default: 1)
#   TASK_ALLOWED_SCOPES comma-separated scope tags this worker may claim
#                      (default: vps-155,gateway-40; VPS stays specialized)
#   VPS_GATEWAY_URL   gateway base URL for model probes (default: http://100.71.95.75:8000)
#   STALE_TIMEOUT     watchdog frees tasks after this many seconds of no heartbeat (default: 600)
#   LOCK_TTL          sweep frees other-host locks idle this long, seconds (default: 172800 = 48h)
#   STALE_GRACE       sweep frees same-host locks idle this long, seconds (default: 5400 = 90min)
#   SWEEP_INTERVAL    min seconds between stale-lock sweeps (default: 1800)
#   TASK_BOARD_REPO   GitHub repo for issue queue (default: ons96/task-board)

set -euo pipefail
TASK_BOARD_REPO="${TASK_BOARD_REPO:-ons96/task-board}"

# --- args ---
ONCE=0
MAX=0
DRY=0
SELF_TEST=0
SIMULATE=0
LABELS="status:new"
WORKTREE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --once) ONCE=1; shift ;;
    --max) MAX="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    --simulate) SIMULATE=1; shift ;;
    --label) LABELS="$2"; shift 2 ;;
    --worker) WORKER_ID="$2"; shift 2 ;;
    --worktree-dir) WORKTREE_DIR="$2"; shift 2 ;;
    -h|--help) grep '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- blocked_reason taxonomy + bounded recovery policy (#944) ---
# Pure decision helpers: no gh/git/network/env side effects. Defined before the
# --simulate block so recovery routing can be dry-run against fixtures offline.

blocked_reason_from_log() {
  local log="${1:-}" text
  text="$(tail -c 12000 "$log" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
  if [[ "$text" =~ (missing[[:space:]_-]*checkout|no[[:space:]_-]*matching[[:space:]_-]*checkout|checkout[[:space:]_-]*not[[:space:]_-]*found|repository[[:space:]_-]*not[[:space:]_-]*found|access[[:space:]_-]*denied) ]]; then
    echo "missing_checkout"
  elif [[ "$text" =~ (occupied.*worktree|worktree.*(busy|occupied|locked)) ]]; then
    echo "worktree_unavailable"
  elif [[ "$text" =~ (missing[[:space:]_-]*credentials|needs[[:space:]_-]*user|operator[[:space:]_-]*action) ]]; then
    echo "needs_user"
  elif [[ "$text" =~ (401|403|unauthori[sz]ed|invalid[[:space:]_-]*api[[:space:]_-]*key|authentication) ]]; then
    echo "auth_required"
  elif [[ "$text" =~ (destructive|force[[:space:]_-]*push|drop[[:space:]_-]*database|delete[[:space:]_-]*production) ]]; then
    echo "destructive_request"
  elif [[ "$text" =~ (ambiguous|needs[[:space:]_-]*clarification|clarify[[:space:]_-]*before) ]]; then
    echo "ambiguous_request"
  elif [[ "$text" =~ ((^|[^a-z])tests?[[:space:]_-]*failed|failing[[:space:]]+tests?|pytest.*(failed|error)|npm[[:space:]]+test.*(failed|error)) ]]; then
    echo "tests_failed"
  elif [[ "$text" =~ (no[[:space:]_-]*work[[:space:]_-]*product|verify[[:space:]_-]*failed|runner[[:space:]_-]*timeout|job[[:space:]_-]*timed[[:space:]_-]*out) ]]; then
    echo "no_work_product"
  elif [[ "$text" =~ (transport[[:space:]_-]*(timeout|reset|failure)|streaming[[:space:]_-]*abort|mcp[[:space:]_-]*transport) ]]; then
    echo "transport_timeout"
  elif [[ "$text" =~ (timeout|timed[[:space:]]+out|connection[[:space:]]+reset|connection[[:space:]]+refused|network|502|503|504|rate[[:space:]_-]*limit|429|upstream|probe[[:space:]]+failed) ]]; then
    echo "provider_unavailable"
  else
    echo "execution_failed"
  fi
}

reason_is_requeueable() {
  case "${1:-}" in
    provider_unavailable|transport_timeout|worktree_unavailable|no_work_product) return 0 ;;
    *) return 1 ;;
  esac
}

recovery_decision() {
  local reason="${1:-}" prior="${2:-0}" limit="${3:-1}" locked="${4:-0}" last="${5:-0}" now="${6:-0}" cooldown="${7:-0}"
  [[ "$prior" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ ]] || { echo blocked; return; }
  [[ "$last" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$cooldown" =~ ^[0-9]+$ ]] || { echo blocked; return; }
  [ "$locked" = "0" ] || { echo blocked; return; }
  reason_is_requeueable "$reason" && [ "$prior" -lt "$limit" ] || { echo blocked; return; }
  [ "$now" -ge "$((last + cooldown))" ] && echo requeue || echo cooldown
}

# Linear backoff: each queued recovery waits one extra base cooldown per prior
# attempt, so raising MAX_RECOVERY_REQUEUES can never hammer the queue.
recovery_cooldown_after() {
  local base="${RECOVERY_COOLDOWN:-300}" prior="${1:-0}"
  echo "$(( base * (prior + 1) ))"
}

worktree_failure_reason() {
  case "${1:-}" in
    *"git worktree add failed"*|*"branch checked out elsewhere"*) echo worktree_unavailable ;;
    *) echo worktree_conflict ;;
  esac
}

# repo_available proj -> 0 if this device has the matching checkout
repo_available() {
  local p
  p="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [ -z "$p" ] && return 1
  [[ ",$HAVE_PROJ," == *",$p,"* ]] && return 0
  return 1
}

# scope_allowed SCOPE -> 0 when this worker is configured for the scope.
# Untagged issues are cross-device by convention and stay with GH Actions.
scope_allowed() {
  local scope="${1:-cross-device}" allowed
  IFS=',' read -ra allowed_scopes <<< "$TASK_ALLOWED_SCOPES"
  for allowed in "${allowed_scopes[@]}"; do
    allowed="$(echo "$allowed" | xargs)"
    [ "$allowed" = "$scope" ] && return 0
  done
  return 1
}

# gates_expired GATES NOW -> 0 iff every comma-separated recovery-after epoch is
# numeric and already expired (<= now). Malformed or future gates fail closed,
# matching claimable_issue: an unreadable gate must never requeue early.
gates_expired() {
  local gates="${1:-}" now="$2" g
  [ -z "$gates" ] && return 0
  local IFS=','
  for g in $gates; do
    [[ "$g" =~ ^[0-9]+$ ]] || return 1
    [ "$g" -le "$now" ] || return 1
  done
  return 0
}

# pick_claimable [NOW]: read "num project-label scope [recovery-gates]" lines,
# echo first eligible issue. NOW defaults to the current epoch; fixtures pass it
# so cooldown gates stay deterministic offline.
pick_claimable() {
  local now="${1:-$(date +%s)}" num pl scope gates
  while read -r num pl scope gates; do
    [ -n "$num" ] || continue
    gates_expired "$gates" "$now" || continue
    scope_allowed "$scope" || continue
    if repo_available "${pl#project:}"; then echo "$num"; return 0; fi
  done
  return 1
}

# Simulation exits before env loading, filesystem setup, gh, curl, OpenCode, or git.
if [ "$SIMULATE" = "1" ]; then
  sim_chain="${OPENCODE_MODEL_CHAIN:-vps-gateway/coding-fast,vps-gateway/coding-smart}"
  sim_probe_tokens="${PROBE_MAX_TOKENS:-15}"
  sim_min_log="${MIN_LOG_BYTES:-200}"
  IFS=',' read -r -a sim_models <<< "$sim_chain"
  # ponytail: force N failed attempts to exercise fallback without network.
  sim_fail_first="${SIMULATE_FAIL_FIRST:-0}"
  case "$sim_fail_first" in
    ''|*[!0-9]*) echo "simulation: SIMULATE_FAIL_FIRST must be a non-negative integer (got '$sim_fail_first')" >&2; exit 2 ;;
  esac
  if [ "$sim_fail_first" -ge "${#sim_models[@]}" ]; then
    echo "simulation: SIMULATE_FAIL_FIRST=$sim_fail_first >= chain length ${#sim_models[@]}" >&2; exit 2
  fi
  sim_selected="101"
  sim_attempt0="${sim_models[0]}"
  sim_next_model="${sim_models[$sim_fail_first]}"
  sim_payload="{\"model\":\"$sim_attempt0\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":$sim_probe_tokens}"
  sim_log="$(mktemp)"
  printf '%*s' "$sim_min_log" '' > "$sim_log"
  sim_log_size="$(wc -c < "$sim_log")"
  rm -f "$sim_log"
  [ "$sim_selected" = "101" ] || { echo "simulation: FAIL issue selection" >&2; exit 1; }
  [ "$sim_log_size" -ge "$sim_min_log" ] || { echo "simulation: FAIL verify gate" >&2; exit 1; }
  # #944: dry-run recovery routing against a fixture issue list, no live mutation.
  # Fields: reason|prior_attempts|limit|locked|last_live|now|cooldown|expected
  sim_recovery_fixtures="provider_unavailable|0|1|0|100|500|300|requeue
provider_unavailable|0|1|0|100|399|300|cooldown
provider_unavailable|1|1|0|100|999|300|blocked
transport_timeout|0|1|0|100|500|300|requeue
worktree_unavailable|0|1|0|100|500|300|requeue
no_work_product|0|1|0|100|500|300|requeue
no_work_product|0|0|0|100|500|300|blocked
auth_required|0|1|0|100|500|300|blocked
needs_user|0|1|0|100|500|300|blocked
missing_checkout|0|1|0|100|500|300|blocked
destructive_request|0|1|0|100|500|300|blocked
ambiguous_request|0|1|0|100|500|300|blocked
tests_failed|0|1|0|100|500|300|blocked
worktree_conflict|0|1|0|100|500|300|blocked
execution_failed|0|1|0|100|500|300|blocked
provider_unavailable|0|1|1|100|500|300|blocked
provider_unavailable|x|1|0|0|0|0|blocked
not-a-reason|0|1|0|100|500|300|blocked"
  sim_recovery_fail=0
  sim_recovery_total=0
  while IFS='|' read -r sim_r sim_prior sim_lim sim_locked sim_last sim_now sim_cd sim_expect; do
    [ -n "${sim_r:-}" ] || continue
    sim_recovery_total=$((sim_recovery_total + 1))
    sim_got="$(recovery_decision "$sim_r" "$sim_prior" "$sim_lim" "$sim_locked" "$sim_last" "$sim_now" "$sim_cd")"
    if [ "$sim_got" != "$sim_expect" ]; then
      echo "simulation: FAIL recovery fixture reason=$sim_r prior=$sim_prior locked=$sim_locked -> $sim_got (want $sim_expect)" >&2
      sim_recovery_fail=1
    fi
  done <<< "$sim_recovery_fixtures"
  [ "$(worktree_failure_reason 'uncommitted changes on branch work/9, expected work/10 (manual salvage needed)')" = worktree_conflict ] || \
    { echo "simulation: FAIL salvage worktree must stay blocked" >&2; sim_recovery_fail=1; }
  [ "$(worktree_failure_reason 'git worktree add failed for branch work/9')" = worktree_unavailable ] || \
    { echo "simulation: FAIL recoverable worktree must requeue" >&2; sim_recovery_fail=1; }
  [ "$sim_recovery_fail" = "0" ] || exit 1
  # #944: fixture issue-list dry run - the real claimable filter (scope, checkout,
  # recovery gates) runs against fixture rows with a fixed clock; no gh mutation.
  TASK_ALLOWED_SCOPES="cross-device,github-actions"
  HAVE_PROJ="task-board-loop"
  # Fields: number|project|scope|gates|expected_pick
  sim_list_fixtures="101|project:task-board-loop|cross-device||101
102|project:task-board-loop|cross-device|400|102
103|project:task-board-loop|cross-device|999999999999|
104|project:task-board-loop|cross-device|tomorrow|
105|project:task-board-loop|cross-device|400,501|
106|project:task-board-loop|vps-155||
107|project:missing-repo|cross-device||"
  sim_list_total=0
  while IFS='|' read -r sim_n sim_pl sim_scope sim_gates sim_expect; do
    [ -n "${sim_n:-}" ] || continue
    sim_list_total=$((sim_list_total + 1))
    sim_line="$sim_n $sim_pl $sim_scope"
    [ -n "$sim_gates" ] && sim_line="$sim_line $sim_gates"
    sim_pick="$(printf '%s\n' "$sim_line" | pick_claimable 500 || true)"
    if [ "$sim_pick" != "$sim_expect" ]; then
      echo "simulation: FAIL list fixture #$sim_n -> '${sim_pick:-<none>}' (want '${sim_expect:-<none>}')" >&2
      sim_recovery_fail=1
    fi
  done <<< "$sim_list_fixtures"
  [ "$sim_recovery_fail" = "0" ] || exit 1
  if [ "$sim_fail_first" -gt 0 ]; then
    printf 'simulation: PASS\nissue_selected: #%s\nfailed_attempts: %s (forced dead)\nfallback_model: %s\nprobe_payload: %s\nverify_gate: PASS (mock dirty worktree + %s-byte log)\nrecovery_fixtures: %s pass (requeue/blocked/cooldown routing, no live mutation)\nissue_list_fixtures: %s pass (scope/checkout/recovery-gate routing, no live mutation)\nside_effects: none (no gh/curl/opencode/git/network)\n' \
      "$sim_selected" "$sim_attempt0" "$sim_next_model" "$sim_payload" "$sim_log_size" "$sim_recovery_total" "$sim_list_total"
  else
    printf 'simulation: PASS\nissue_selected: #%s\nattempt_0_model: %s\nprobe_payload: %s\nverify_gate: PASS (mock dirty worktree + %s-byte log)\nrecovery_fixtures: %s pass (requeue/blocked/cooldown routing, no live mutation)\nissue_list_fixtures: %s pass (scope/checkout/recovery-gate routing, no live mutation)\nside_effects: none (no gh/curl/opencode/git/network)\n' \
      "$sim_selected" "$sim_attempt0" "$sim_payload" "$sim_log_size" "$sim_recovery_total" "$sim_list_total"
  fi
  exit 0
fi

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
MAX_RECOVERY_REQUEUES="${MAX_RECOVERY_REQUEUES:-1}"
RECOVERY_COOLDOWN="${RECOVERY_COOLDOWN:-300}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-300}"
STALE_TIMEOUT="${STALE_TIMEOUT:-600}"
LOCK_TTL="${LOCK_TTL:-172800}"
STALE_GRACE="${STALE_GRACE:-5400}"
SWEEP_INTERVAL="${SWEEP_INTERVAL:-1800}"
# Terminal labels (filter these out + use for completion)
DONE_LABEL="${DONE_LABEL:-status:done}"
BLOCKED_LABEL="${BLOCKED_LABEL:-status:blocked}"
IN_PROGRESS_LABEL="${IN_PROGRESS_LABEL:-status:in_progress}"
BLOCKED_REASON_PREFIX="${BLOCKED_REASON_PREFIX:-blocked_reason:}"
ATTEMPTS_PREFIX="${ATTEMPTS_PREFIX:-attempts:}"

# --- model chain (#841 follow-up): dead-model resilience ---
# Comma-separated; retry N uses chain position (round-robin). vps-gateway/* virtual models
# have gateway-internal fallback chains AND are curl-probed pre-flight; dead ones are skipped.
#nous/stealth/ox-alpha REMOVED 2026-09-08: model no longer exists upstream (40s empty runs rubber-stamped as done, see #841).
# A chain must be supplied from a recent probe inventory; guessed model IDs can
# turn every retry into a fast failure or silently route to a paid model.
DEFAULT_MODEL_CHAIN=""
MODEL_CHAIN="${OPENCODE_MODEL_CHAIN:-}"
MODEL_CHAIN_FILE="${OPENCODE_MODEL_CHAIN_FILE:-$HOME/.config/opencode/model-chain.txt}"
if [ -z "$MODEL_CHAIN" ] && [ -r "$MODEL_CHAIN_FILE" ]; then
  inventory="$(grep -Ev '^[[:space:]]*(#|$)' "$MODEL_CHAIN_FILE" || true)"
  [ -n "$inventory" ] && MODEL_CHAIN="$(printf '%s\n' "$inventory" | paste -sd, -)"
fi
[ -z "$MODEL_CHAIN" ] && MODEL_CHAIN="${OPENCODE_MODEL:-}"
if [ -z "$MODEL_CHAIN" ] && [ "$SELF_TEST" = "1" ]; then
  MODEL_CHAIN="self-test/model"
fi
if [ -z "$MODEL_CHAIN" ] && [ "$SIMULATE" = "1" ]; then
  MODEL_CHAIN="vps-gateway/coding-fast,vps-gateway/coding-smart"
fi
if [ -z "$MODEL_CHAIN" ]; then
  echo "no model chain: provide OPENCODE_MODEL_CHAIN or a probed OPENCODE_MODEL_CHAIN_FILE" >&2
  exit 2
fi
IFS=',' read -r -a MODELS <<< "$MODEL_CHAIN"
VPS_GATEWAY_URL="${VPS_GATEWAY_URL:-http://100.71.95.75:8000}"
PROBE_MAX_TOKENS="${PROBE_MAX_TOKENS:-15}"
MIN_LOG_BYTES="${MIN_LOG_BYTES:-200}"
OPENCODE_NICE="${OPENCODE_NICE:-10}"
OPENCODE_IONICE="${OPENCODE_IONICE:-3}"
OPENCODE_MEMORY_MAX_MB="${OPENCODE_MEMORY_MAX_MB:-}"
PAUSE_ON_HUMAN="${PAUSE_ON_HUMAN:-1}"
TASK_ALLOWED_SCOPES="${TASK_ALLOWED_SCOPES:-vps-155,gateway-40}"
# ponytail: targeted key extraction instead of sourcing ~/.env (stray-line exec gotcha)
if [ -z "${GATEWAY_API_KEY:-}" ] && [ -f "$HOME/.env" ]; then
  GATEWAY_API_KEY="$(grep -E '^GATEWAY_API_KEY=' "$HOME/.env" | head -1 | cut -d= -f2- | tr -d '"'"'"'"' || true)"
  export GATEWAY_API_KEY
fi

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

# --- same-host matching for stale-lock sweep (#826) ---
MY_HOST_LOWER="$(echo "${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}" | tr '[:upper:]' '[:lower:]')"
WORKER_LOWER="$(echo "$WORKER_ID" | tr '[:upper:]' '[:lower:]')"
LAST_SWEEP=0

# --- decision helpers (pure logic, unit-tested by --self-test) ---
# stale_by_ttl now last_live ttl -> 0 (stale) if now-last_live >= ttl, else 1
stale_by_ttl() { [ "$1" -ge "$(( $2 + $3 ))" ]; }

# find_checkout ROOT proj -> echo checkout dir under ROOT matching proj (case-insensitive), else 1
# ponytail: linear dir scan instead of -d test so label case mismatches resolve (project:llm-api-key-proxy -> LLM-API-Key-Proxy)
find_checkout() {
  local root="$1" p d
  p="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
  for d in "$root"/*/; do
    [ -e "${d}.git" ] || continue
    if [ "$(basename "$d" | tr '[:upper:]' '[:lower:]')" = "$p" ]; then echo "${d%/}"; return 0; fi
  done
  return 1
}

# lock_same_host lock_label -> 0 if the lock belongs to this host (own worker or hostname substring)
lock_same_host() {
  local l
  l="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$l" == "locked-by:$WORKER_LOWER" ]] && return 0
  [[ -n "$MY_HOST_LOWER" && "$MY_HOST_LOWER" != "unknown" && "$l" == *"$MY_HOST_LOWER"* ]] && return 0
  return 1
}

reason_label() { echo "${BLOCKED_REASON_PREFIX}${1}"; }
attempts_label() { echo "${ATTEMPTS_PREFIX}${1}"; }

issue_attempts() {
  local n="$1" value
  value="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json labels 2>/dev/null | jq -r --arg prefix "$ATTEMPTS_PREFIX" \
    '[.labels[].name | select(startswith($prefix)) | ltrimstr($prefix)] | if length == 0 then "0" elif length == 1 then .[0] else "invalid" end')" || return 1
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  echo "$value"
}

set_issue_reason() {
  local n="$1" reason="$2" attempts="$3" label old_labels old
  owns_claim "$n" || return 1
  label="$(reason_label "$reason")"
  gh label create "$label" -R "$TASK_BOARD_REPO" --color "F9D0C4" 2>/dev/null || true
  gh label create "$(attempts_label "$attempts")" -R "$TASK_BOARD_REPO" --color "D4C5F9" 2>/dev/null || true
  old_labels="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json labels 2>/dev/null | jq -r --arg rp "$BLOCKED_REASON_PREFIX" --arg ap "$ATTEMPTS_PREFIX" \
    '.labels[].name | select(startswith($rp) or startswith($ap))')" || return 1
  local -a args=(--add-label "$label" --add-label "$(attempts_label "$attempts")")
  while IFS= read -r old; do
    [ -n "$old" ] && [ "$old" != "$label" ] && [ "$old" != "$(attempts_label "$attempts")" ] && args+=(--remove-label "$old")
  done <<< "$old_labels"
  gh issue edit "$n" -R "$TASK_BOARD_REPO" "${args[@]}" 2>/dev/null
}

# --- release lock + transition to terminal label ---
unclaim() {
  local n="$1" label="$2"  # label = $DONE_LABEL | $BLOCKED_LABEL
  gh issue edit "$n" -R "$TASK_BOARD_REPO" \
    --remove-label "$IN_PROGRESS_LABEL" \
    --remove-label "$LOCK_LABEL" \
    --add-label "$label" 2>/dev/null || true
}

queue_recovery() {
  local n="$1" prior="$2" cooldown label old
  owns_claim "$n" || return 1
  cooldown="$(recovery_cooldown_after "$prior")"
  label="recovery-after:$(( $(date +%s) + cooldown ))"
  gh label create "$label" -R "$TASK_BOARD_REPO" --color "C2E0C6" 2>/dev/null || true
  gh issue edit "$n" -R "$TASK_BOARD_REPO" --add-label "$label" 2>/dev/null || return 1
  # A failed or stale gate must never put an issue back in the eligible queue.
  old="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json labels --jq '.labels[].name' 2>/dev/null)" || return 1
  printf '%s\n' "$old" | jq -R -e --arg label "$label" 'select(. == $label)' >/dev/null || return 1
  requeue_claim "$n"
}

# clear_issue_recovery N -> strip blocked_reason:*/attempts:*/recovery-after:*
# labels so a recovered issue that finishes carries no blocked metadata (idempotent).
clear_issue_recovery() {
  local n="$1" old_labels old
  old_labels="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json labels 2>/dev/null | jq -r --arg rp "$BLOCKED_REASON_PREFIX" --arg ap "$ATTEMPTS_PREFIX" \
    '.labels[].name | select(startswith($rp) or startswith($ap) or startswith("recovery-after:"))')" || return 1
  [ -n "$old_labels" ] || return 0
  local -a args=()
  while IFS= read -r old; do [ -n "$old" ] && args+=(--remove-label "$old"); done <<< "$old_labels"
  [ "${#args[@]}" -gt 0 ] || return 0
  gh issue edit "$n" -R "$TASK_BOARD_REPO" "${args[@]}" 2>/dev/null || true
  return 0
}

# Release only our own claim, and only if the issue is still in progress with our lock.
owned_claim_json() {
  echo "$1" | jq -e --arg ours "$LOCK_LABEL" --arg progress "$IN_PROGRESS_LABEL" '
    .state == "OPEN" and ([.labels[].name | select(startswith("locked-by:"))] == [$ours])
    and ([.labels[].name] | index($progress) != null)' >/dev/null
}

owns_claim() {
  local state
  state="$(gh issue view "$1" -R "$TASK_BOARD_REPO" --json state,labels 2>/dev/null)" || return 1
  owned_claim_json "$state"
}

requeue_claim() {
  local n="$1" owner_labels state
  state="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json state,labels \
    --jq '{state:.state, labels:[.labels[].name]}' 2>/dev/null || echo '')"
  [ -n "$state" ] || return 1
  [ "$(echo "$state" | jq -r .state)" = OPEN ] || return 1
  owner_labels="$(echo "$state" | jq -r --arg ours "$LOCK_LABEL" '[.labels[] | select(startswith("locked-by:") and . != $ours)] | length')"
  [ "$owner_labels" = 0 ] || return 1
  echo "$state" | jq -e --arg ours "$LOCK_LABEL" --arg progress "$IN_PROGRESS_LABEL" '.labels | index($ours) and index($progress)' >/dev/null || return 1
  gh issue edit "$n" -R "$TASK_BOARD_REPO" --remove-label "$IN_PROGRESS_LABEL" --remove-label "$LOCK_LABEL" --add-label "status:new" 2>/dev/null
}

requeue_claim_blocked() {
  local n="$1" state
  state="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json state,labels 2>/dev/null)" || return 1
  owned_claim_json "$state" || return 1
  unclaim "$n" "$BLOCKED_LABEL"
}

# Recheck queue eligibility at claim time; an expired recovery gate stays on the
# issue as evidence until completion, while malformed gates fail closed.
claimable_issue() {
  local json="$1" now="$2"
  echo "$json" | jq -e --arg completed "$DONE_LABEL" --arg blocked "$BLOCKED_LABEL" \
    --arg progress "$IN_PROGRESS_LABEL" --argjson now "$now" '
    .state == "OPEN" and
    ([.labels[].name] | index("status:new") != null and index($completed) == null and
      index($blocked) == null and index($progress) == null and
      all(.[]; (startswith("locked-by:") | not) and
        (if startswith("recovery-after:") then
          (ltrimstr("recovery-after:") | tonumber? // ($now + 1)) <= $now
         else true end)))
  ' >/dev/null
}

# --- model selection + verification (#841) ---
# pick_model RETRY -> model for this attempt (round-robin over MODELS array)
pick_model() {
  local i=$(( $1 % ${#MODELS[@]} ))
  echo "${MODELS[$i]}"
}

run_opencode() {
  local model="$1" prompt="$2"
  local -a cmd=(timeout "$OPENCODE_TIMEOUT" nice -n "$OPENCODE_NICE")
  if command -v ionice >/dev/null 2>&1; then
    cmd+=(ionice -c "$OPENCODE_IONICE")
  fi
  cmd+=("$OPENCODE_BIN" run -m "$model" "$prompt")
  if [ -n "$OPENCODE_MEMORY_MAX_MB" ] && command -v systemd-run >/dev/null 2>&1; then
    systemd-run --user --scope --quiet -p "MemoryMax=${OPENCODE_MEMORY_MAX_MB}M" -- "${cmd[@]}"
  else
    "${cmd[@]}"
  fi
}

human_active() {
  [ "$PAUSE_ON_HUMAN" = "1" ] || return 1
  pgrep -u "$(id -u)" -x opencode >/dev/null 2>&1 ||
    pgrep -u "$(id -u)" -x omp >/dev/null 2>&1
}

# probe_gateway_model MODEL -> 0 if gateway virtual model answers a short ping
# ponytail: probe only vps-gateway/* (their chains route whole provider pools);
# non-gateway models rely on the verify gate instead of pre-flight probing.
probe_gateway_model() {
  local model="$1" sub="${model#vps-gateway/}"
  [ "$sub" = "$model" ] && return 0   # not a gateway model, nothing to probe
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${GATEWAY_API_KEY:-}" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$sub\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":$PROBE_MAX_TOKENS}" \
    "$VPS_GATEWAY_URL/v1/chat/completions" 2>/dev/null) || return 1
  [ "$code" = "200" ]
}

# worktree_fingerprint WT -> HEAD + sorted porcelain status.
# Two identical fingerprints mean the worktree saw no new work between snapshots.
worktree_fingerprint() {
  local wt="$1"
  git -C "$wt" rev-parse HEAD 2>/dev/null || echo "(no-head)"
  git -C "$wt" status --porcelain 2>/dev/null | LC_ALL=C sort
}

# verify_work LOG WT BRANCH [BASELINE] -> 0 only if the run produced real work.
# Gate: log at least MIN_LOG_BYTES (bogus runs were 33-byte banner-only) AND
# (dirty worktree OR commits ahead of main). BASELINE (a worktree_fingerprint
# snapshot taken before the run) additionally rejects no-op runs on adopted
# worktrees whose pre-existing dirt would otherwise satisfy the gate (#929).
verify_work() {
  local log="$1" wt="$2" branch="$3" baseline="${4:-}"
  [ -f "$log" ] || return 1
  [ "$(wc -c < "$log")" -ge "$MIN_LOG_BYTES" ] || return 1
  git -C "$wt" rev-parse --verify "$branch" >/dev/null 2>&1 || return 1
  if [ -n "$baseline" ] && [ "$(worktree_fingerprint "$wt")" = "$baseline" ]; then
    return 1
  fi
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    # ponytail: test gate, fail if tests exist and break
    if [ -f "$wt/package.json" ]; then (cd "$wt" && npm test -- --silent) || return 2; elif [ -f "$wt/pyproject.toml" ]; then (cd "$wt" && pytest -q) || return 2; fi
    return 0
  fi
  if [ -f "$wt/package.json" ]; then (cd "$wt" && npm test -- --silent) || return 2; elif [ -f "$wt/pyproject.toml" ]; then (cd "$wt" && pytest -q) || return 2; fi
  git -C "$wt" fetch origin "$MAIN_BRANCH" >/dev/null 2>&1 || true
  [ "$(git -C "$wt" rev-list --count "origin/$MAIN_BRANCH..$branch" 2>/dev/null || echo 0)" -gt 0 ]
}

# Append actionable process errors even when OpenCode exits without writing stdout.
record_attempt_failure() {
  local model="$1" result="$2" size
  size=0
  [ ! -f "$logf" ] || size="$(wc -c < "$logf")"
  printf '\n[task-board-loop] attempt failed: model=%s exit=%s log_bytes=%s\n' \
    "$model" "$result" "$size" >> "$logf"
  if [ "$size" -eq 0 ]; then
    printf '[task-board-loop] OpenCode produced no output; inspect binary, model configuration, and provider connectivity.\n' >> "$logf"
  fi
}

if [ "$SELF_TEST" = "1" ]; then
  fails=0
  check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok: $d"; else echo "FAIL: $d"; fails=$((fails+1)); fi; }
  check_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "FAIL: $d"; fails=$((fails+1)); else echo "ok: $d"; fi; }
  check "own lock is same-host" lock_same_host "locked-by:${WORKER_ID}"
  check "hostname-substring lock is same-host" lock_same_host "locked-by:local-${MY_HOST_LOWER}"
  check_not "gha lock is other-host" lock_same_host "locked-by:gha-12345"
  check_not "other hostname is other-host" lock_same_host "locked-by:local-someotherhost99"
  HAVE_PROJ="task-board-loop,vps-gh-agent-loop"
  check_not "unpinned project is unavailable" repo_available ""
  check_not "missing general checkout is unavailable" repo_available "general"
  check "local checkout is available" repo_available "Task-Board-Loop"
  check_not "missing checkout is unavailable" repo_available "llm-leaderboard-aggregate"
  # #930 + scope fixtures: skip unavailable projects and route only configured scopes.
  TASK_ALLOWED_SCOPES="vps-155,gateway-40"
  [ "$(printf '5 project:missing-repo vps-155\n7 project:task-board-loop vps-155\n' | pick_claimable)" = "7" ] && echo "ok: next_issue skips unavailable project" || { echo "FAIL: next_issue skips unavailable project"; fails=$((fails+1)); }
  [ -z "$(printf '9 project:task-board-loop cross-device\n' | pick_claimable)" ] && echo "ok: VPS skips cross-device issue" || { echo "FAIL: VPS claimed cross-device issue"; fails=$((fails+1)); }
  TASK_ALLOWED_SCOPES="cross-device,github-actions"
  [ "$(printf '9 project:task-board-loop cross-device\n' | pick_claimable)" = "9" ] && echo "ok: runner claims cross-device issue" || { echo "FAIL: runner skipped cross-device issue"; fails=$((fails+1)); }
  [ -z "$(printf '10 project:task-board-loop vps-155\n' | pick_claimable)" ] && echo "ok: runner skips VPS issue" || { echo "FAIL: runner claimed VPS issue"; fails=$((fails+1)); }
  [ "$(printf '11 project:task-board-loop\n' | pick_claimable)" = "11" ] && echo "ok: untagged issue defaults to cross-device" || { echo "FAIL: untagged issue routing"; fails=$((fails+1)); }
  # #944: recovery gates ride on pick_claimable; malformed/future gates fail closed.
  [ "$(printf '12 project:task-board-loop cross-device 400\n' | pick_claimable 500)" = "12" ] && echo "ok: expired recovery gate is claimable" || { echo "FAIL: expired recovery gate claim"; fails=$((fails+1)); }
  [ -z "$(printf '13 project:task-board-loop cross-device 999999999999\n' | pick_claimable 500)" ] && echo "ok: active recovery gate skipped at list time" || { echo "FAIL: active recovery gate claimed"; fails=$((fails+1)); }
  [ -z "$(printf '14 project:task-board-loop cross-device tomorrow\n' | pick_claimable 500)" ] && echo "ok: malformed recovery gate skipped at list time" || { echo "FAIL: malformed recovery gate claimed"; fails=$((fails+1)); }
  [ "$(printf '15 project:task-board-loop cross-device 400,500\n' | pick_claimable 500)" = "15" ] && echo "ok: all-expired gates claimable" || { echo "FAIL: all-expired gates claim"; fails=$((fails+1)); }
  [ -z "$(printf '16 project:task-board-loop cross-device 400,501\n' | pick_claimable 500)" ] && echo "ok: one future gate among many blocks claim" || { echo "FAIL: mixed gates claim"; fails=$((fails+1)); }
  check "no gates is expired" gates_expired "" 500
  check "gate at exactly now is expired" gates_expired "500" 500
  check_not "gate after now is active" gates_expired "501" 500
  check_not "non-numeric gate fails closed" gates_expired "tomorrow" 500
  check_not "mixed numeric gate fails on active one" gates_expired "400,501" 500
  ckdir="$(mktemp -d /tmp/cktest.XXXXXX)"
  mkdir -p "$ckdir/LLM-API-Key-Proxy/.git" "$ckdir/noext"
  check "find_checkout resolves case-insensitively" find_checkout "$ckdir" "llm-api-key-proxy"
  check_not "find_checkout fails on missing project" find_checkout "$ckdir" "no-such-repo"
  rm -rf "$ckdir"
  check "idle past ttl is stale" stale_by_ttl 100 0 50
  check "idle exactly ttl is stale" stale_by_ttl 100 50 50
  check_not "idle within ttl is live" stale_by_ttl 100 60 50
  taxdir="$(mktemp -d /tmp/taxonomy.XXXXXX)"
  printf '401 unauthorized API key\n' > "$taxdir/auth"
  printf 'please force-push and delete production\n' > "$taxdir/destructive"
  printf 'needs clarification before proceeding\n' > "$taxdir/ambiguous"
  printf 'pytest test failed\n' > "$taxdir/tests"
  printf 'test coverage summary: all passing\n' > "$taxdir/test-success"
  printf 'HTTP 503 Rate Limit\n' > "$taxdir/provider-upper"
  printf 'upstream timeout HTTP 503\n' > "$taxdir/provider"
  printf 'runner timeout: no work product\n' > "$taxdir/runner"
  printf 'transport timeout while streaming\n' > "$taxdir/transport"
  printf 'project checkout not found\n' > "$taxdir/checkout"
  printf 'worktree path occupied by live worktree\n' > "$taxdir/occupied"
  printf 'missing credentials\n' > "$taxdir/credentials"
  printf 'needs-user decision required\n' > "$taxdir/needs-user"
  printf 'shell exited unexpectedly\n' > "$taxdir/execution"
  printf 'gateway probe failed for model=vps-gateway/coding-fast (cause unknown)\n' > "$taxdir/probe"
  printf 'the latest failed CI run had no other errors\n' > "$taxdir/latest-failed"
  [ "$(blocked_reason_from_log "$taxdir/auth")" = "auth_required" ] && echo "ok: auth taxonomy" || { echo "FAIL: auth taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/destructive")" = "destructive_request" ] && echo "ok: destructive taxonomy" || { echo "FAIL: destructive taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/ambiguous")" = "ambiguous_request" ] && echo "ok: ambiguous taxonomy" || { echo "FAIL: ambiguous taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/tests")" = "tests_failed" ] && echo "ok: tests taxonomy" || { echo "FAIL: tests taxonomy"; fails=$((fails+1)); }
  check "passing test mention is not a test failure" test "$(blocked_reason_from_log "$taxdir/test-success")" = execution_failed
  check "case-insensitive provider taxonomy" test "$(blocked_reason_from_log "$taxdir/provider-upper")" = provider_unavailable
  [ "$(blocked_reason_from_log "$taxdir/provider")" = "provider_unavailable" ] && echo "ok: provider taxonomy" || { echo "FAIL: provider taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/runner")" = "no_work_product" ] && echo "ok: runner timeout/no-work taxonomy" || { echo "FAIL: runner timeout/no-work taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/transport")" = "transport_timeout" ] && echo "ok: transport taxonomy" || { echo "FAIL: transport taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/checkout")" = "missing_checkout" ] && echo "ok: missing checkout taxonomy" || { echo "FAIL: missing checkout taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/occupied")" = "worktree_unavailable" ] && echo "ok: occupied worktree taxonomy" || { echo "FAIL: occupied worktree taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/credentials")" = "needs_user" ] && echo "ok: credential taxonomy" || { echo "FAIL: credential taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/needs-user")" = "needs_user" ] && echo "ok: needs-user taxonomy" || { echo "FAIL: needs-user taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/execution")" = "execution_failed" ] && echo "ok: execution taxonomy" || { echo "FAIL: execution taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/probe")" = "provider_unavailable" ] && echo "ok: dead gateway probe is provider-unavailable" || { echo "FAIL: dead gateway probe taxonomy"; fails=$((fails+1)); }
  [ "$(blocked_reason_from_log "$taxdir/latest-failed")" = "execution_failed" ] && echo "ok: latest-failed wording is not a test failure" || { echo "FAIL: latest-failed false positive"; fails=$((fails+1)); }
  check "provider failures requeue" reason_is_requeueable provider_unavailable
  check "no-work retries requeue" reason_is_requeueable no_work_product
  check "transport failures requeue" reason_is_requeueable transport_timeout
  check_not "auth failures stay blocked" reason_is_requeueable auth_required
  check_not "missing checkout stays blocked" reason_is_requeueable missing_checkout
  check_not "needs-user stays blocked" reason_is_requeueable needs_user
  check_not "test failures stay blocked" reason_is_requeueable tests_failed
  check_not "destructive requests stay blocked" reason_is_requeueable destructive_request
  check_not "ambiguous requests stay blocked" reason_is_requeueable ambiguous_request
  check_not "repeated execution failures stay blocked" test "$(recovery_decision execution_failed 0 1 0)" = requeue
  check "first transient recovery is allowed" test "$(recovery_decision provider_unavailable 0 1 0)" = requeue
  check_not "repeated transient failure stays blocked" test "$(recovery_decision provider_unavailable 1 1 0)" = requeue
  check_not "active lock prevents recovery" test "$(recovery_decision provider_unavailable 0 1 1)" = requeue
  check_not "cooldown prevents early recovery" test "$(recovery_decision provider_unavailable 0 1 0 100 399 300)" = requeue
  check "recovery allowed after cooldown" test "$(recovery_decision provider_unavailable 0 1 0 100 400 300)" = requeue
  check_not "missing checkout stays blocked" reason_is_requeueable missing_checkout
  check_not "worktree conflict stays blocked" reason_is_requeueable worktree_conflict
  check "recoverable occupied worktree classified" test "$(worktree_failure_reason 'git worktree add failed for branch')" = worktree_unavailable
  check "recoverable worktree failures requeue" reason_is_requeueable worktree_unavailable
  check "unsafe worktree conflict classified" test "$(worktree_failure_reason 'path occupied by a worktree of a different repo')" = worktree_conflict
  check "dirty wrong-branch salvage stays a conflict" test "$(worktree_failure_reason 'uncommitted changes on branch work/9, expected work/10 (manual salvage needed)')" = worktree_conflict
  check "unregistered occupied path stays a conflict" test "$(worktree_failure_reason 'path occupied by a directory that is not a worktree root of this repo')" = worktree_conflict
  check_not "invalid attempt count stays blocked" test "$(recovery_decision provider_unavailable x 1 0)" = requeue
  check_not "empty reason stays blocked" test "$(recovery_decision '' 0 1 0)" = requeue
  check_not "unknown reason stays blocked" test "$(recovery_decision not-a-reason 0 1 0)" = requeue
  check "missing log classifies as execution failure" test "$(blocked_reason_from_log /nonexistent/no-such-log)" = execution_failed
  check "first recovery uses base cooldown" test "$(recovery_cooldown_after 0)" = "$RECOVERY_COOLDOWN"
  check "recovery backoff scales with attempts" test "$(recovery_cooldown_after 2)" = "$((RECOVERY_COOLDOWN * 3))"
  local_claim='{"state":"OPEN","labels":[{"name":"status:new"},{"name":"recovery-after:400"}]}'
  check_not "claim rejects recovery during cooldown" claimable_issue "$local_claim" 399
  check "claim accepts expired recovery gate" claimable_issue "$local_claim" 400
  check_not "claim rejects malformed recovery gate" claimable_issue '{"state":"OPEN","labels":[{"name":"status:new"},{"name":"recovery-after:bad"}]}' 500
  check_not "claim rejects another worker lock" claimable_issue '{"state":"OPEN","labels":[{"name":"status:new"},{"name":"locked-by:other"}]}' 500
  check_not "claim rejects in-progress status" claimable_issue '{"state":"OPEN","labels":[{"name":"status:new"},{"name":"status:in_progress"}]}' 500
  check_not "claim rejects closed issue" claimable_issue '{"state":"CLOSED","labels":[{"name":"status:new"}]}' 500
  check "owned in-progress claim" owned_claim_json "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"status:in_progress\"},{\"name\":\"$LOCK_LABEL\"}]}"
  check_not "competing lock prevents metadata updates" owned_claim_json "{\"state\":\"OPEN\",\"labels\":[{\"name\":\"status:in_progress\"},{\"name\":\"$LOCK_LABEL\"},{\"name\":\"locked-by:other\"}]}"
  check_not "lost lock prevents metadata updates" owned_claim_json '{"state":"OPEN","labels":[{"name":"status:in_progress"},{"name":"locked-by:other"}]}'
  check_not "closed claim prevents metadata updates" owned_claim_json "{\"state\":\"CLOSED\",\"labels\":[{\"name\":\"status:in_progress\"},{\"name\":\"$LOCK_LABEL\"}]}"
  rm -rf "$taxdir"
  # #944: live-path fixtures - real set_issue_reason/queue_recovery/requeue_claim
  # running against an offline gh() shim (state in $ghdir JSON files), so the
  # label-mutation sequence each decision class drives is verified without network.
  ghdir="$(mktemp -d /tmp/ghmock.XXXXXX)"
  gh() {
    # offline gh shim: label create succeeds; issue view/edit/comment mutate state files
    if [ "${1:-}" = label ]; then return 0; fi
    [ "${1:-}" = issue ] || return 1
    local verb="$2" n="" filter="" body="" l f
    local -a adds=() removes=()
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        -R|--json|--color|--state|--limit|--label) shift 2 ;;
        --jq) filter="$2"; shift 2 ;;
        --add-label) adds+=("$2"); shift 2 ;;
        --remove-label) removes+=("$2"); shift 2 ;;
        --body) body="$2"; shift 2 ;;
        *) n="$1"; shift ;;
      esac
    done
    f="$ghdir/issue-$n.json"
    case "$verb" in
      view)
        [ -f "$f" ] || return 1
        if [ -n "$filter" ]; then jq -r "$filter" "$f"; else jq -c '.' "$f"; fi
        ;;
      edit)
        [ -f "$f" ] || return 1
        for l in "${adds[@]}"; do
          jq --arg l "$l" '.labels |= (if any(.[]; .name == $l) then . else . + [{"name":$l}] end)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        done
        for l in "${removes[@]}"; do
          jq --arg l "$l" '.labels |= [.[] | select(.name != $l)]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        done
        ;;
      comment)
        [ -f "$f" ] || return 1
        jq --arg b "$body" '.comments += [$b]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
        ;;
      *) return 1 ;;
    esac
  }
  ghmock_seed() { local n="$1"; shift; printf '%s\n' "$@" | jq -R . | jq -sc '{state:"OPEN",labels:[.[] | {name:.}]}' > "$ghdir/issue-$n.json"; }
  ghmock_seed_closed() { local n="$1"; shift; printf '%s\n' "$@" | jq -R . | jq -sc '{state:"CLOSED",labels:[.[] | {name:.}]}' > "$ghdir/issue-$n.json"; }
  ghmock_has() { jq -e --arg l "$2" 'any(.labels[]; .name == $l)' "$ghdir/issue-$1.json" >/dev/null 2>&1; }
  ghmock_count() { jq --arg p "$2" '[.labels[] | select(.name | startswith($p))] | length' "$ghdir/issue-$1.json"; }
  ghmock_gate() { jq -r --arg p 'recovery-after:' 'first(.labels[].name | select(startswith($p)) | ltrimstr($p)) // ""' "$ghdir/issue-$1.json"; }
  ghmock_state() { cat "$ghdir/issue-$1.json"; }
  # A: transient failure -> one bounded recovery requeue behind a cooldown gate
  ghmock_seed 201 "status:in_progress" "$LOCK_LABEL"
  check "issue_attempts reads 0 on fresh claim" test "$(issue_attempts 201)" = 0
  check "owned claim records metadata" set_issue_reason 201 provider_unavailable 1
  check "exactly one blocked_reason label" test "$(ghmock_count 201 'blocked_reason:')" = 1
  check "exactly one attempts label" test "$(ghmock_count 201 'attempts:')" = 1
  check "attempts label carries count" ghmock_has 201 "attempts:1"
  check "queue bounded recovery" queue_recovery 201 0
  gate="$(ghmock_gate 201)"
  check "recovery gate epoch is numeric" test "$gate" -ne 0
  check "gate is in the future (cooldown)" test "$gate" -gt "$(date +%s)"
  check "exactly one recovery gate" test "$(ghmock_count 201 'recovery-after:')" = 1
  check_not "second recovery queue refused (idempotent)" queue_recovery 201 0
  check "still exactly one recovery gate" test "$(ghmock_count 201 'recovery-after:')" = 1
  check "requeue released our lock" test "$(ghmock_count 201 'locked-by:')" = 0
  check_not "requeue removed in-progress" ghmock_has 201 "status:in_progress"
  check "requeue returned to status:new" ghmock_has 201 "status:new"
  check_not "gate active: not claimable yet" claimable_issue "$(ghmock_state 201)" "$((gate - 1))"
  check "gate expired: claimable again" claimable_issue "$(ghmock_state 201)" "$gate"
  # second exhausted attempt: metadata swaps, repeated transient stays terminal
  gh issue edit 201 -R "$TASK_BOARD_REPO" --add-label "status:in_progress" --add-label "$LOCK_LABEL" --remove-label "status:new"
  check "second attempt swaps metadata" set_issue_reason 201 provider_unavailable 2
  check "still one blocked_reason after swap" test "$(ghmock_count 201 'blocked_reason:')" = 1
  check "still one attempts label after swap" test "$(ghmock_count 201 'attempts:')" = 1
  check "attempts bumped to 2" ghmock_has 201 "attempts:2"
  check_not "repeated transient failure stays blocked" test "$(recovery_decision provider_unavailable 1 "$MAX_RECOVERY_REQUEUES" 0)" = requeue
  check "terminal block on repeated failure" requeue_claim_blocked 201
  check "blocked label applied" ghmock_has 201 "status:blocked"
  check "no lock after terminal block" test "$(ghmock_count 201 'locked-by:')" = 0
  check_not "blocked issue is not claimable" claimable_issue "$(ghmock_state 201)" "$gate"
  # B: human-blocked reason never requeues, stays terminally blocked
  ghmock_seed 203 "status:in_progress" "$LOCK_LABEL"
  check "needs-user metadata recorded" set_issue_reason 203 needs_user 1
  check_not "needs-user never requeues" test "$(recovery_decision needs_user 0 "$MAX_RECOVERY_REQUEUES" 0)" = requeue
  check "terminal block for needs-user" requeue_claim_blocked 203
  check "no recovery gate for needs-user" test "$(ghmock_count 203 'recovery-after:')" = 0
  check "needs-user metadata survives as evidence" ghmock_has 203 "blocked_reason:needs_user"
  # C: foreign or stolen locks are never mutated by another worker
  ghmock_seed 205 "status:in_progress" "locked-by:other-worker"
  check_not "foreign claim refuses metadata" set_issue_reason 205 provider_unavailable 1
  check_not "foreign claim refuses recovery queue" queue_recovery 205 0
  check_not "foreign claim refuses requeue" requeue_claim 205
  check_not "foreign claim refuses blocked transition" requeue_claim_blocked 205
  check "foreign issue untouched" test "$(jq -r '.labels | map(.name) | join(",")' "$ghdir/issue-205.json")" = "status:in_progress,locked-by:other-worker"
  ghmock_seed 206 "status:in_progress" "$LOCK_LABEL"
  gh issue edit 206 -R "$TASK_BOARD_REPO" --remove-label "$LOCK_LABEL" --add-label "locked-by:other-worker"
  check_not "stolen lock refuses metadata" set_issue_reason 206 provider_unavailable 1
  check_not "stolen lock refuses recovery" queue_recovery 206 0
  check "no gate added to stolen lock" test "$(ghmock_count 206 'recovery-after:')" = 0
  # D: closed issues are never mutated
  ghmock_seed_closed 207 "status:in_progress" "$LOCK_LABEL"
  check_not "closed issue refuses metadata" set_issue_reason 207 provider_unavailable 1
  check_not "closed issue refuses recovery" queue_recovery 207 0
  check_not "closed issue refuses requeue" requeue_claim 207
  check_not "closed issue refuses blocked transition" requeue_claim_blocked 207
  # E: completion strips blocked metadata and gates
  ghmock_seed 208 "status:in_progress" "$LOCK_LABEL" "blocked_reason:provider_unavailable" "attempts:2" "recovery-after:1"
  check "clear strips blocked metadata" clear_issue_recovery 208
  check "no blocked_reason after clear" test "$(ghmock_count 208 'blocked_reason:')" = 0
  check "no attempts after clear" test "$(ghmock_count 208 'attempts:')" = 0
  check "no gates after clear" test "$(ghmock_count 208 'recovery-after:')" = 0
  check "claim state labels survive clear" ghmock_has 208 "$LOCK_LABEL"
  # ambiguous attempts labels fail closed
  ghmock_seed 209 "status:in_progress" "$LOCK_LABEL" "attempts:1" "attempts:2"
  check_not "ambiguous attempts label fails closed" issue_attempts 209
  unset -f gh ghmock_seed ghmock_seed_closed ghmock_has ghmock_count ghmock_gate ghmock_state
  rm -rf "$ghdir"
  # verify_work gate (#841): exercised in a throwaway git repo (log lives OUTSIDE the
  # worktree, like real $LOG_DIR runs; bare origin so origin/main..branch is resolvable)
  MIN_LOG_BYTES=200
  MAIN_BRANCH=main
  vdir="$(mktemp -d /tmp/vwtest.XXXXXX)"
  git init -q --bare "$vdir/origin.git" || { echo "FAIL: vwtest git init"; fails=$((fails+1)); }
  if git clone -q "$vdir/origin.git" "$vdir/wt" 2>/dev/null && \
     git -C "$vdir/wt" config user.email t@t && git -C "$vdir/wt" config user.name t && \
     ( echo seed > "$vdir/wt/seed" && git -C "$vdir/wt" add -A && git -C "$vdir/wt" commit -qm seed ) && \
     git -C "$vdir/wt" push -q origin HEAD:main 2>/dev/null && \
     git -C "$vdir/wt" checkout -qb work/1 2>/dev/null; then
  vlog="$vdir/run.log"
  printf '%200s' '' > "$vlog"   # 200 bytes of padding
  check_not "verify fails: big log but clean tree, no commits" verify_work "$vlog" "$vdir/wt" work/1
  echo change > "$vdir/wt/seed"     # dirty worktree
  check "verify passes: dirty worktree" verify_work "$vlog" "$vdir/wt" work/1
  git -C "$vdir/wt" commit -qam work   # commit the dirty change -> clean tree, ahead of origin/main
  check "verify passes: commit ahead of origin/main" verify_work "$vlog" "$vdir/wt" work/1
  printf 'banner only' > "$vlog"   # 11 bytes < MIN_LOG_BYTES
  echo change2 > "$vdir/wt/seed"
  check_not "verify fails: dirty tree but tiny log" verify_work "$vlog" "$vdir/wt" work/1
  git -C "$vdir/wt" reset --hard -q HEAD
  printf '%200s' '' > "$vlog"
  git -C "$vdir/wt" checkout -q main
  check_not "verify fails: substantial log without work product" verify_work "$vlog" "$vdir/wt" main
  rm -rf "$vdir"
  else
    echo "FAIL: vwtest repo setup"; fails=$((fails+1)); rm -rf "$vdir"
  fi
  [ "$(pick_model 0)" = "${MODELS[0]}" ] && echo "ok: pick_model 0" || { echo "FAIL: pick_model 0"; fails=$((fails+1)); }
  [ "$(pick_model ${#MODELS[@]})" = "${MODELS[0]}" ] && echo "ok: pick_model wraps" || { echo "FAIL: pick_model wraps"; fails=$((fails+1)); }
  if [ "$(date -d '2026-09-06T03:24:58Z' +%s 2>/dev/null || echo 0)" -gt 0 ]; then echo "ok: iso date parse"; else echo "FAIL: iso date parse"; fails=$((fails+1)); fi
  [ "$fails" = "0" ] && { echo "self-test: ALL PASS"; exit 0; } || { echo "self-test: $fails FAILURES"; exit 1; }
fi

# Live work fails closed unless every eligible fallback is backed by current
# free-tier evidence supplied by the operator; never infer price from a provider name.
if [ "$SELF_TEST" != "1" ]; then
  FREE_MODEL_ALLOWLIST="${FREE_MODEL_ALLOWLIST:-}"
  if [ -z "$FREE_MODEL_ALLOWLIST" ]; then
    echo "FREE_MODEL_ALLOWLIST required; include only models with current verified-free evidence" >&2
    exit 2
  fi
  IFS=',' read -r -a free_models <<< "$FREE_MODEL_ALLOWLIST"
  allowed_models=()
  for candidate in "${MODELS[@]}"; do
    candidate="$(echo "$candidate" | xargs)"
    for free_model in "${free_models[@]}"; do
      free_model="$(echo "$free_model" | xargs)"
      if [[ "$candidate" == "$free_model" ]]; then
        allowed_models+=("$candidate")
        break
      fi
    done
  done
  if [ "${#allowed_models[@]}" -eq 0 ]; then
    echo "model chain has no entries in FREE_MODEL_ALLOWLIST" >&2
    exit 2
  fi
  MODELS=("${allowed_models[@]}")
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
# ponytail: launch repo name feeds the pre-claim availability set
LAUNCH_REPO="$REPO"
# ponytail: pre-claim repo-availability set (#830: 155 ran #834 in the wrong repo via launch fallback)
HAVE_PROJ="$(basename "$LAUNCH_REPO" | tr '[:upper:]' '[:lower:]')"
if [ -e "$HOME/CodingProjects/.git" ]; then HAVE_PROJ="$HAVE_PROJ,codingprojects"; fi
for _d in "$HOME/CodingProjects"/*/; do
  [ -e "${_d}.git" ] || continue
  HAVE_PROJ="$HAVE_PROJ,$(basename "$_d" | tr '[:upper:]' '[:lower:]')"
done
echo "task-board-loop: repo=$REPO main=$MAIN_BRANCH worker=$WORKER_ID lock=$LOCK_LABEL labels=$LABELS worktrees=$WORKTREE_DIR have=$HAVE_PROJ"

# --- counters ---
DONE=0
SKIPPED=0
BLOCKED=0
FAILED=0

# --- heartbeat (file for systemd watchdog timer) ---
LOOP_PID_FILE="${LOOP_PID_FILE:-/tmp/task-board-loop.pid}"
printf '%s\n' "$$" > "$LOOP_PID_FILE"
cleanup_pid() { [ "$(cat "$LOOP_PID_FILE" 2>/dev/null || true)" != "$$" ] || rm -f "$LOOP_PID_FILE"; }
trap cleanup_pid EXIT
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
  local l1 l2 json
  l1="$(echo "$LABELS" | cut -d, -f1)"
  l2="$(echo "$LABELS" | cut -d, -f2)"
  if [ -n "$l2" ] && [ "$l2" != "$l1" ]; then
    json="$(gh issue list -R "$TASK_BOARD_REPO" --label "$l1" --label "$l2" --state open --json number,labels --limit 100)"
  else
    json="$(gh issue list -R "$TASK_BOARD_REPO" --label "$l1" --state open --json number,labels --limit 100)"
  fi
  # ponytail: first candidate in this worker's scope whose repo exists locally wins
  # recovery-after gates ride along as a 4th column; pick_claimable fails closed
  # on future or malformed gates (claim() re-checks via claimable_issue).
  echo "$json" | jq -r --arg done "$DONE_LABEL" --arg blocked "$BLOCKED_LABEL" '
      .[]
      | select((.labels | map(.name) | any(. == $done or . == $blocked or startswith("locked-by:"))) | not)
      | "\(.number) \(.labels | map(.name) | map(select(startswith("project:"))) | .[0] // "") \(.labels | map(.name) | map(select(startswith("tag:")) | sub("^tag:"; "") | select(. == "cross-device" or . == "device-local" or . == "vps-155" or . == "gateway-40" or . == "github-actions")) | .[0] // "cross-device") \(.labels | map(.name) | map(select(startswith("recovery-after:")) | sub("^recovery-after:"; "")) | join(","))"
    ' | pick_claimable || true
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

  # ponytail #826: pre-check avoids piling a second lock onto a live claim (flap source)
  local pre current now
  pre="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json state,labels 2>/dev/null)" || return 1
  now="$(date +%s)"
  if ! claimable_issue "$pre" "$now"; then
    heartbeat "issue #$n not eligible for claim, skipping"
    return 1
  fi

  if ! gh issue edit "$n" -R "$TASK_BOARD_REPO" \
    --add-label "$IN_PROGRESS_LABEL" \
    --add-label "$LOCK_LABEL" \
    --remove-label "status:new" 2>/dev/null; then
    return 1
  fi

  sleep 2

  current="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json state,labels 2>/dev/null)" || return 1
  if ! echo "$current" | jq -e --arg ours "$LOCK_LABEL" --arg progress "$IN_PROGRESS_LABEL" '
    .state == "OPEN" and ([.labels[].name | select(startswith("locked-by:"))] == [$ours])
    and ([.labels[].name] | index($progress) != null)' >/dev/null; then
    heartbeat "issue #$n claim changed after edit, skipping without changing another lock"
    return 1
  fi

  comment "$n" "Claimed by \`${WORKER_ID}\` at $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  return 0
}

# --- stale-lock TTL sweep (#826) ---
# Newest liveness epoch for issue $1 = max(updatedAt, newest heartbeat-type comment).
# ponytail: one API call (updatedAt+comments together); returns 1 on any error (fail-open)
issue_last_liveness() {
  local n="$1" raw upd hb ue he
  raw="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json updatedAt,comments \
    --jq '{u: .updatedAt, h: ([.comments[] | select(.body // "" | test("heartbeat|Claimed by|Still working"; "i")) | .createdAt] | max // "")}' 2>/dev/null || echo "")"
  [ -z "$raw" ] && return 1
  upd="$(echo "$raw" | jq -r .u)"; hb="$(echo "$raw" | jq -r .h)"
  ue="$(date -d "$upd" +%s 2>/dev/null || echo 0)"; he=0
  [ -n "$hb" ] && he="$(date -d "$hb" +%s 2>/dev/null || echo 0)"
  if [ "$he" -gt "$ue" ]; then echo "$he"; else echo "$ue"; fi
}

# Frees status:in_progress locks with no sign of life (comment posted on every free = anti-flap).
# DRY=1 logs without mutating. Fail-open: any API error skips the issue, never frees.
sweep_stale_locks() {
  local now nums n locks lock same ttl last_live age args l
  now="$(date +%s)"
  if [ "$now" -lt "$((LAST_SWEEP + SWEEP_INTERVAL))" ]; then return 0; fi
  LAST_SWEEP="$now"
  nums="$(gh issue list -R "$TASK_BOARD_REPO" --label "$IN_PROGRESS_LABEL" --state open --json number --jq '.[].number' 2>/dev/null || echo "")"
  [ -z "$nums" ] && return 0
  heartbeat "sweeping stale locks (ttl=${LOCK_TTL}s grace=${STALE_GRACE}s)"
  for n in $nums; do
    # ponytail: newline-joined, lock labels may contain spaces
    locks="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json labels \
      --jq '[.labels[].name | select(startswith("locked-by:"))] | join("\n")' 2>/dev/null || echo "")"
    if [ -z "$locks" ]; then
      lock="(legacy, no locked-by)"; same=0; ttl="$LOCK_TTL"
    else
      lock="$(echo "$locks" | head -1)"
      [ "$lock" = "$LOCK_LABEL" ] && continue  # ours, never sweep self
      if lock_same_host "$lock"; then same=1; ttl="$STALE_GRACE"; else same=0; ttl="$LOCK_TTL"; fi
    fi
    if [ "$same" = "1" ]; then
      local pidf="/tmp/opencode-work-${n}.pid" pid
      pid="$(cat "$pidf" 2>/dev/null || echo "")"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        heartbeat "#$n same-host lock $lock has live pid $pid, keeping"
        continue
      fi
    fi
    last_live="$(issue_last_liveness "$n" || echo "")"
    [ -z "$last_live" ] && { heartbeat "#$n liveness unreadable, skipping (fail-open)"; continue; }
    age="$((now - last_live))"
    if stale_by_ttl "$now" "$last_live" "$ttl"; then
      if [ "$DRY" = "1" ]; then
        heartbeat "dry-run: would auto-release #$n (lock $lock, idle ${age}s > ttl ${ttl}s)"
        continue
      fi
      comment "$n" "task-board-loop: auto-release, lock \`${lock}\` idle ${age}s with no heartbeat (ttl ${ttl}s). Returning to open queue."
      args=(--remove-label "$IN_PROGRESS_LABEL" --add-label "status:new")
      while IFS= read -r l; do [ -n "$l" ] && args+=(--remove-label "$l"); done <<< "$locks"
      gh issue edit "$n" -R "$TASK_BOARD_REPO" "${args[@]}" 2>/dev/null || true
      heartbeat "auto-released #$n (was $lock)"
    fi
  done
}

# --- ensure worktree at path, recovering occupied paths (#929) ---
# ensure_worktree WT BRANCH -> 0 when $WT is ready for /work; sets WORKTREE_ERR
# with a human reason on failure. Recovery rules (a stale dir from a dead run
# must not block the issue, see #897/#911):
#   - path free                        -> worktree add -b BRANCH MAIN (or reuse existing BRANCH)
#   - registered worktree of this repo on BRANCH -> reuse (clean) or adopt (dirty);
#     uncommitted leftovers are kept and /work finishes them
#   - registered on another/detached branch, clean -> checkout BRANCH (fetch fallback)
#   - anything else (unregistered dir, different repo, dirty wrong branch,
#     broken metadata) -> fail so the caller blocks the issue with the reason.
# Never removes or resets anything; cleanup_worktree keeps the dirty-tree guard.
ensure_worktree() {
  local wt="$1" branch="$2"
  local wt_real repo_real top wt_common repo_common wt_branch dirty
  WORKTREE_ERR=""
  if [ ! -e "$wt" ]; then
    if git worktree add "$wt" -b "$branch" "$MAIN_BRANCH" 2>/dev/null; then return 0; fi
    # ponytail: branch may exist locally or on the remote only (GHA-era work/N) - fetch, then reuse
    git fetch origin "$branch" 2>/dev/null || true
    if git worktree add "$wt" "$branch" 2>/dev/null; then
      heartbeat "reusing existing branch $branch for $wt"
      return 0
    fi
    WORKTREE_ERR="git worktree add failed for branch $branch"
    return 1
  fi
  if [ ! -d "$wt" ]; then
    WORKTREE_ERR="path exists but is not a directory"
    return 1
  fi
  # occupied path: recover only when it is a live worktree of this repo
  wt_real="$(cd "$wt" 2>/dev/null && pwd -P)"
  repo_real="$(cd "$REPO" 2>/dev/null && pwd -P)"
  if [ -z "$wt_real" ] || [ "$wt_real" = "$repo_real" ]; then
    WORKTREE_ERR="path not accessible or is the repo itself"
    return 1
  fi
  top="$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null)"
  if [ -z "$top" ] || [ "$top" != "$wt_real" ]; then
    # also catches plain dirs inside the repo (git would climb to the repo root)
    WORKTREE_ERR="path occupied by a directory that is not a worktree root of this repo (left in place)"
    return 1
  fi
  if ! git -C "$wt" rev-parse --verify HEAD >/dev/null 2>&1; then
    WORKTREE_ERR="worktree metadata broken (needs git worktree prune + manual salvage)"
    return 1
  fi
  wt_common="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)"
  repo_common="$(git rev-parse --git-common-dir 2>/dev/null)"
  wt_common="$(cd "$wt_common" 2>/dev/null && pwd -P)"
  repo_common="$(cd "$repo_common" 2>/dev/null && pwd -P)"
  if [ -z "$wt_common" ] || [ "$wt_common" != "$repo_common" ]; then
    WORKTREE_ERR="path occupied by a worktree of a different repo (left in place)"
    return 1
  fi
  wt_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "(unreadable)")"
  if [ "$wt_branch" = "$branch" ]; then
    dirty="$(git -C "$wt" status --porcelain 2>/dev/null)"
    if [ -n "$dirty" ]; then
      heartbeat "adopting existing worktree $wt on branch $branch (uncommitted changes from a previous run are kept)"
    else
      heartbeat "reusing existing worktree $wt on branch $branch"
    fi
    return 0
  fi
  # different or detached branch: repair only a clean tree; a dirty one needs manual salvage
  if [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    git fetch origin "$branch" 2>/dev/null || true
    if git -C "$wt" checkout "$branch" 2>/dev/null; then
      heartbeat "repaired worktree $wt: switched from $wt_branch to $branch"
      return 0
    fi
    if ! git show-ref --verify --quiet "refs/heads/$branch" && \
       git -C "$wt" checkout -b "$branch" "$MAIN_BRANCH" 2>/dev/null; then
      heartbeat "repaired worktree $wt: created branch $branch from $MAIN_BRANCH"
      return 0
    fi
    WORKTREE_ERR="worktree on branch $wt_branch could not be switched to $branch (branch checked out elsewhere?)"
    return 1
  fi
  WORKTREE_ERR="uncommitted changes on branch $wt_branch, expected $branch (manual salvage needed)"
  return 1
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
  local n="$1" proj hit=""
  proj="$(gh issue view "$n" -R "$TASK_BOARD_REPO" --json labels --jq '.labels[].name' 2>/dev/null \
          | grep -oE '^project:[a-z0-9_-]+$' | head -1 | cut -d: -f2)"
  if [ -n "$proj" ]; then
    hit="$(find_checkout "$HOME/CodingProjects" "$proj" || true)"
  fi
  # #930: never fall back to the launch repo when project: is set but unresolvable -
  # running /work there does wrong-repo work (#830 bug class). Unclaim as blocked instead.
  if [ -n "$proj" ] && [ -z "$hit" ]; then
    heartbeat "project:$proj has no local checkout; refusing fallback repo for #$n"
    owns_claim "$n" || return 1
    local count
    count="$(issue_attempts "$n")" || count="unknown"
    comment "$n" "task-board-loop: blocked_reason=missing_checkout attempts=$count last_failure_class=missing_checkout; project:$proj has no checkout on $WORKER_ID; refusing launch-repo fallback. Human/operator action required; not requeued."
    [ "$count" = unknown ] || set_issue_reason "$n" missing_checkout "$count" || true
    unclaim "$n" "$BLOCKED_LABEL"
    BLOCKED=$((BLOCKED+1))
    return 1
  fi
  if [ -n "$hit" ]; then
    REPO="$hit"
    REPO_PARENT="$(dirname "$REPO")"
    REPO_NAME="$(basename "$REPO")"
    WORKTREE_DIR="$REPO_PARENT/${REPO_NAME}-worktrees"
    MAIN_BRANCH="$(git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
    if [ "$proj" = "codingprojects" ]; then
      MAIN_BRANCH="$(git -C "$REPO" symbolic-ref --short HEAD)"
    fi
    # ponytail: origin/HEAD often unset locally; fall back main->master by inspection
    if [ -z "$MAIN_BRANCH" ]; then
      if git -C "$REPO" show-ref --verify --quiet refs/heads/main; then MAIN_BRANCH=main
      elif git -C "$REPO" show-ref --verify --quiet refs/heads/master; then MAIN_BRANCH=master
      else MAIN_BRANCH=$(git -C "$REPO" rev-parse --abbrev-ref HEAD); fi
    fi
  else
    heartbeat "project '$proj' has no matching checkout; refusing fallback repo"
    return 1
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
  trap "stop_heartbeat_poster '$n' 2>/dev/null || true; requeue_claim_blocked '$n' 2>/dev/null || true" RETURN

  # resolve target repo per-issue (multi-repo task-board support);
  # #930: abort (unclaim blocked via RETURN trap already fired inside resolve) when project: has no checkout
  if ! resolve_repo_for_issue "$n"; then
    return 1
  fi
  local wt="$WORKTREE_DIR/wt-$n"
  local branch="work/$n"

  # create or recover worktree (#929: an occupied wt path from a dead run must not block)
  heartbeat "ensuring worktree $wt on branch $branch"
  if ! ensure_worktree "$wt" "$branch"; then
    owns_claim "$n" || { heartbeat "claim lost for #$n; leaving worktree and issue untouched"; return 1; }
    local wt_reason
    wt_reason="$(worktree_failure_reason "${WORKTREE_ERR:-unknown reason}")"
    local prior_attempts attempts
    prior_attempts="$(issue_attempts "$n")" || prior_attempts="unknown"
    if [ "$prior_attempts" = unknown ]; then attempts=unknown; else attempts=$((prior_attempts + 1)); fi
    local metadata_ok=0
    if [ "$attempts" != unknown ] && set_issue_reason "$n" "$wt_reason" "$attempts"; then metadata_ok=1; fi
    comment "$n" "task-board-loop: blocked_reason=$wt_reason attempts=$attempts last_failure_class=$wt_reason; worktree error: ${WORKTREE_ERR:-unknown reason}. Worktree preserved."
    local wt_recovery wt_cooldown
    wt_recovery="$(recovery_decision "$wt_reason" "$prior_attempts" "$MAX_RECOVERY_REQUEUES" 0)"
    if [ "$wt_recovery" = requeue ] && [ "$metadata_ok" = 1 ]; then
      if queue_recovery "$n" "$prior_attempts"; then
        wt_cooldown="$(recovery_cooldown_after "$prior_attempts")"
        comment "$n" "task-board-loop: bounded recovery requeue ${prior_attempts}/${MAX_RECOVERY_REQUEUES} after ${wt_cooldown}s cooldown/backoff; occupied worktree preserved."
      else
        heartbeat "recovery skipped for #$n: gate or issue state/lock changed"
        requeue_claim_blocked "$n"
      fi
    else
      requeue_claim_blocked "$n"
    fi
    BLOCKED=$((BLOCKED+1))
    # trap - RETURN: the default trap would re-apply status:blocked and undo the requeue
    trap - RETURN
    return 1
  fi
  local baseline
  baseline="$(git -C "$wt" rev-parse HEAD)"

  # baseline fingerprint: pre-existing dirt on an adopted worktree must not
  # satisfy the verify gate on its own - only new work may (#929)
  local base_fp=""
  [ "$DRY" = "1" ] || base_fp="$(worktree_fingerprint "$wt" || true)"

  # run opencode with /work prompt, retry up to MAX_RETRIES times
  local model logf="$LOG_DIR/issue-$n.log"
  : > "$logf"
  start_heartbeat_poster "$n"
  while [ "$retry" -le "$MAX_RETRIES" ]; do
    model="$(pick_model "$retry")"
    heartbeat "running /work $n (attempt $((retry+1)), model=$model)"
    if [ "$DRY" = "1" ]; then
      heartbeat "dry-run: would run: cd $wt && $OPENCODE_BIN run -m $model < /work prompt"
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
      if ! probe_gateway_model "$model"; then
        heartbeat "model $model dead (gateway probe fail), skipping to next"
        printf '[task-board-loop] gateway probe failed for model=%s (cause unknown)\n' "$model" >> "$logf"
        result=1
      else
        set +e
        run_opencode "$model" "$prompt" 2>&1 | tee -a "$logf"
        result=${PIPESTATUS[0]}
        set -e
      fi
    fi
    # verify-before-done gate (#841): exit-0 alone is NOT success
    if [ "$result" = "0" ] && [ "$DRY" != "1" ]; then
      local verify_result=0
      verify_work "$logf" "$wt" "$branch" "$base_fp" || verify_result=$?
      if [ "$verify_result" = 0 ]; then
        heartbeat "verify OK for #$n (log $(wc -c < "$logf") bytes, real work present)"
      else
        heartbeat "verify FAILED for #$n (exit-0 but verify gate failed) — downgrading"
        if [ "$verify_result" = 2 ]; then
          printf '\n[task-board-loop] tests failed during verification\n' >> "$logf"
        else
          printf '\n[task-board-loop] verify failed: no work product\n' >> "$logf"
        fi
        result=1
      fi
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
      comment "$n" "task-board-loop: completed on attempt $((retry+1)) (model=$model, verified: log $(wc -c < "$logf")B + worktree diff)"
      clear_issue_recovery "$n"
      unclaim "$n" "$DONE_LABEL"
      cleanup_worktree "$wt"
      stop_heartbeat_poster "$n"
      trap - RETURN
      DONE=$((DONE+1))
      return 0
    fi
    if [ "$result" != "0" ]; then
      record_attempt_failure "$model" "$result"
    fi
    retry=$((retry+1))
    if [ "$retry" -le "$MAX_RETRIES" ]; then
      heartbeat "attempt $retry failed (exit=$result), retrying in 30s"
      sleep 30
    fi
  done

  # all retries exhausted
  owns_claim "$n" || { heartbeat "claim lost for #$n; leaving worktree and issue untouched"; stop_heartbeat_poster "$n"; return 1; }
  local log_tail=""
  if [ -f "$logf" ]; then
    log_tail="$(tail -c 4000 "$logf" | tail -12 | sed 's/`/'"'"'/g')"
  fi
  [ -n "$log_tail" ] || log_tail="No provider output; see per-attempt failure diagnostics in $logf."
  local reason prior_attempts attempts recovery recovery_cooldown
  reason="$(blocked_reason_from_log "$logf")"
  prior_attempts="$(issue_attempts "$n")" || prior_attempts=unknown
  if [ "$prior_attempts" = unknown ]; then attempts=unknown; else attempts=$((prior_attempts + 1)); fi
  local metadata_ok=0
  if [ "$attempts" != unknown ] && set_issue_reason "$n" "$reason" "$attempts"; then metadata_ok=1; fi
  comment "$n" "task-board-loop: blocked_reason=$reason attempts=$attempts last_failure_class=$reason after $((MAX_RETRIES+1)) attempts (model chain: $MODEL_CHAIN). Log: \`$logf\`. Last log lines:
 $log_tail"
  recovery="$(recovery_decision "$reason" "$prior_attempts" "$MAX_RECOVERY_REQUEUES" 0)"
  if [ "$recovery" = requeue ] && [ "$metadata_ok" = 1 ]; then
    if queue_recovery "$n" "$prior_attempts"; then
      recovery_cooldown="$(recovery_cooldown_after "$prior_attempts")"
      comment "$n" "task-board-loop: transient failure; bounded recovery requeue ${prior_attempts}/${MAX_RECOVERY_REQUEUES} after ${recovery_cooldown}s cooldown/backoff. Partial worktree preserved."
    else
      heartbeat "recovery skipped for #$n: gate or issue state/lock changed"
      requeue_claim_blocked "$n"
    fi
  else
    requeue_claim_blocked "$n"
  fi
  [ "$recovery" = requeue ] && [ "$metadata_ok" = 1 ] || cleanup_worktree "$wt"
  stop_heartbeat_poster "$n"
  trap - RETURN
  FAILED=$((FAILED+1))
  return 1
}

# --- main loop ---
heartbeat "starting (once=$ONCE max=$MAX dry=$DRY)"
trap 'heartbeat "interrupted, summary: done=$DONE skipped=$SKIPPED blocked=$BLOCKED failed=$FAILED"; exit 130' INT TERM
sweep_stale_locks || true  # startup reclaim before first claim

while :; do
  heartbeat
  sweep_stale_locks || true  # throttled by SWEEP_INTERVAL
  if human_active; then
    heartbeat "human OpenCode session active, pausing claims"
    sleep "$IDLE_SLEEP"
    continue
  fi
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
