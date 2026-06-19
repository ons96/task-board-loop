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
```

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
- All actions logged to `/tmp/agent-loop-issue-N.log` + journal
- Non-interactive OpenCode runs prefer `~/.config/opencode/scripts/opencode-resilient.sh`, which retries only classified transient network/provider/transport failures and logs to `~/.local/state/opencode/resilience/`
- Issues with missing/blocked deps auto-skipped (see opencode `/work` Phase 0)

## Resilience wrapper

Set `OPENCODE_BIN=opencode` to bypass the wrapper, or `OPENCODE_RESILIENCE_DISABLE=1` to keep the wrapper path but disable retry logic. The wrapper retries recoverable failures such as connection resets, timeouts, 429/5xx, gateway/tunnel drops, streaming aborts, and MCP transport resets. It does not retry auth/config/tool misuse failures such as 401/403, bad credentials, invalid config, syntax errors, missing files, or provider mapping errors.

## Resource use (VPS, 1GB RAM)

- Idle: ~5MB (bash + gh calls)
- Per-issue peak: ~150MB (opencode + npm modules) for up to 30 min
- Worktree: ~10-50MB per checked-out worktree
- Concurrent worktrees cap: 3-5 on 1GB VPS (monitor with `du -sh ../worktrees`)
