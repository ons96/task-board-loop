# task-board-loop

Autonomous multi-device task worker for [ons96/task-board](https://github.com/ons96/task-board) (GitHub Issues as work queue).

## How it differs from `../vps-gh-agent-loop/`

| | vps-gh-agent-loop | task-board-loop (this) |
|---|---|---|
| Work source | `BRAINSTORM.md` -> `SPEC.md` -> `TASKS.md` | GitHub issues with `status:new` and no `locked-by:*` |
| Coordination | GH Actions coordinator + wave graph (20 parallel slots) | GitHub assignees + labels (self-coordinating) |
| Execution env | GH Actions runners (public repo, free unlimited) | Any device w/ `opencode` + `gh` CLI (VPS, local, GH bot) |
| Isolation | Per-task PR against private staging branch | Per-issue git worktree on device |
| State | `STATE.md` schema v2 (slots array) | GitHub issue state (assignee + labels) |
| Use when | Big projects needing wave decomposition + multi-PR coordination | Quick task pickup, many small issues, multi-device fan-out |

## Files

- `task-board-loop.sh` - main loop: claim issue -> worktree -> /work -> PR -> cleanup
- `opencode-headless.sh` - bundled pure-mode wrapper for RAM-tight headless hosts (VPS)
- `task-board-loop-watchdog.service` - systemd unit: kill silent loops
- `task-board-loop-watchdog.timer` - systemd timer: runs watchdog every 10 min

## Quick start

```bash
# install on a device
cd task-board-loop
cp task-board-loop-watchdog.service ~/.config/systemd/user/
cp task-board-loop-watchdog.timer   ~/.config/systemd/user/
systemctl --user enable --now task-board-loop-watchdog.timer

# start the loop (runs forever, one issue at a time)
./task-board-loop.sh

# or once
./task-board-loop.sh --once

# or with limits
./task-board-loop.sh --max 3
./task-board-loop.sh --dry-run
# local-only simulation; no GitHub, provider, OpenCode, git, or network calls
./task-board-loop.sh --simulate
```

## Supervisor on VPS-155 (tmux)

The loop runs 24/7 in tmux on VPS-155 (`oci-agent-vnic`); zero autonomous load on the laptop.

```bash
# start (from laptop)
ssh ubuntu@155.248.217.255 'tmux new-session -d -s taskboard-loop -c ~/task-board-loop "env OPENCODE_HEADLESS=1 OPENCODE_MODEL=vps-gateway/coding-fast ./task-board-loop.sh"'
# watchdog kills silent loops (>30min no heartbeat), every 10min
ssh ubuntu@155.248.217.255 'systemctl --user enable --now task-board-loop-watchdog.timer'
# status
ssh ubuntu@155.248.217.255 'tmux ls | grep taskboard; cat /tmp/agent-loop.heartbeat'
# restart: pull latest, kill session, start again
ssh ubuntu@155.248.217.255 'git -C ~/task-board-loop pull --ff-only && tmux kill-session -t taskboard-loop'
# stop
ssh ubuntu@155.248.217.255 'tmux kill-session -t taskboard-loop'
```

Notes:

- `OPENCODE_MODEL` must exist in the device's `opencode.json` (155 uses `vps-gateway/coding-fast`; the default `nous/stealth/ox-alpha` is not configured there).
- Pre-claim guard: issues whose `project:` repo has no local checkout are skipped (`project:general` / unpinned run in the loop repo).
- `~/task-board-loop` on 155 is a git clone tracking `origin/main`; `loop-opencode.json` is device-local (untracked).

## How it works

1. Lists open issues with `status:new`, no assignee, no `locked-by:*`
2. Claims one (self-assigns, adds `status:in_progress`) - other devices skip
3. Creates git worktree `../worktrees/wt-N` on branch `work/N`
4. Runs local resilient OpenCode wrapper when installed, otherwise `opencode /work N` (30 min timeout, 2 retries)
5. PR via `gh`, comment on issue with result
6. Marks `status:done` on success, `status:blocked` on failure
7. Loops

## Coordination across devices

Each device identifies as a different GitHub user (machine user / personal / GH bot).
The loop only claims UNASSIGNED issues. Once claimed, others see it and skip.
Worktrees live on each device separately, so no branch collision.

## Required labels (must exist in task-board repo)

- `status:new` - work queue (issues must have this + no assignee + no `locked-by:*`)
- `status:in_progress` - locked (auto-added on claim)
- `status:done` - completed (auto-added on success)
- `status:blocked` - needs user (auto-added on failure)

Priority labels: `priority:P0`..`priority:P9` (used for sort order)

## Safety

- Never force-pushes
- Never removes worktree with uncommitted changes (leaves for manual review)
- Heartbeat file written every iteration; watchdog kills silent loops > 30min
- Stale-lock TTL sweep runs at startup and every `SWEEP_INTERVAL` (default 1800s):
  other-host `status:in_progress` locks idle longer than `LOCK_TTL` (default
  172800s = 48h) with no heartbeat-type comment are auto-released back to
  `status:new` with an explanatory comment; same-host locks are freed only if
  their PID is dead AND idle longer than `STALE_GRACE` (default 5400s = 90min).
  The loop never sweeps its own lock. `--dry-run` logs instead of freeing.
  Self-test: `./task-board-loop.sh --self-test`
- All actions logged to `/tmp/agent-loop-issue-N.log` + journal
- Non-interactive OpenCode runs prefer `~/.config/opencode/scripts/opencode-resilient.sh`, which retries only classified transient network/provider/transport failures and logs to `~/.local/state/opencode/resilience/`
- Issues with missing/blocked deps auto-skipped (see opencode `/work` Phase 0)
- By default, claims pause while the current user has an `opencode` or `omp` process; set `PAUSE_ON_HUMAN=0` only for unattended workers.
- `--simulate` is safe for local validation: it exercises issue/model selection, the probe payload, and the verification threshold with mocks; it exits before `gh`, `curl`, OpenCode, git, or network setup.
- Set `SIMULATE_FAIL_FIRST=N` with `--simulate` to force a dead first attempt and verify fallback selection; invalid values fail without external calls.
- Active runs default to CPU niceness 10 and idle I/O priority; set `OPENCODE_NICE`, `OPENCODE_IONICE`, and optional `OPENCODE_MEMORY_MAX_MB` to tune resource limits.
- Set `OPENCODE_MODEL_CHAIN_FILE` to a plain-text, one-model-per-line inventory to refresh fallback choices without editing the script; comments and blank lines are ignored. Use only recently verified models; the built-in list remains the fallback.

## Session-close reconciliation

Use `scripts/session-close-reconcile.py` only for the explicitly named current
OpenCode session. It defaults to dry-run and never selects sessions by age.

```bash
scripts/session-close-reconcile.py \
  --session-id ses_... --issue 900 --outcome done --ref 0123abc
scripts/session-close-reconcile.py \
  --session-id ses_... --issue 900 --outcome blocked \
  --reason 'needs supervised VPS validation'
scripts/session-close-reconcile.py --self-test
```

Add `--apply` only after reviewing the dry-run. A `done` close marks only that
session's pending/in-progress rows completed, requires a commit/PR reference,
and creates a database backup first. `blocked` and `deferred` preserve rows and
append evidence to `~/.local/share/opencode/session-reconciliations.log`.

## Resilience wrapper

Set `OPENCODE_BIN=opencode` to bypass the wrapper, or `OPENCODE_RESILIENCE_DISABLE=1` to keep the wrapper path but disable retry logic. The wrapper retries recoverable failures such as connection resets, timeouts, 429/5xx, gateway/tunnel drops, streaming aborts, and MCP transport resets. It does not retry auth/config/tool misuse failures such as 401/403, bad credentials, invalid config, syntax errors, missing files, or provider mapping errors.

## Resource use (VPS, 1GB RAM)

- Idle: ~5MB (bash + gh calls)
- Per-issue peak: ~150MB (opencode + npm modules) for up to 30 min
- Worktree: ~10-50MB per checked-out worktree
- Concurrent worktrees cap: 3-5 on 1GB VPS (monitor with `du -sh ../worktrees`)

## VPS headless runner

On RAM-tight headless hosts (e.g. 1GB VPS-155), the interactive OpenCode
config loads global plugins/MCPs that push startup past the loop's short
timeout. The bundled `opencode-headless.sh` wrapper sidesteps this:

- Sources and exports `~/.env` (so `{env:GATEWAY_API_KEY}` resolves)
- Runs `opencode --pure "$@"` (skips external plugins + MCPs, ~25s boot)
- Validates the binary exists and `GATEWAY_API_KEY` is nonempty
- Self-check: `./opencode-headless.sh --self-check` prints `opencode-headless: OK`
- `OPENCODE_BIN=/path/to/real/opencode` overrides and bypasses the wrapper

Enable in the loop by setting `OPENCODE_HEADLESS=1` (the wrapper is only
selected when that env is `1` and the bundled file is executable; explicit
`OPENCODE_BIN` always wins):

```bash
# PONG smoke (expect <30s, output "PONG"); pick a virtual model with a
# no-TPM-cap first candidate (agent-oracle -> NVIDIA NIM) since OpenCode's
# default agent system prompt is ~9k tokens — Groq's 12k TPM free tier rejects it.
OPENCODE_HEADLESS=1 timeout 120 ./task-board-loop.sh  # then Ctrl-C the loop
# or test the wrapper directly:
timeout 120 ./opencode-headless.sh run -m vps-gateway/agent-oracle "reply with exactly: PONG"
```

Normal interactive OpenCode on the same host is untouched — the wrapper is
loop-only. Use a virtual model whose first healthy candidate has no free-tier
TPM cap (e.g. `agent-oracle` / NVIDIA NIM) because OpenCode emits a large
default agent system prompt plus `tools` and `tool_choice`; small-TPM models
will return misleading "model not found" errors when the token window is exceeded.
