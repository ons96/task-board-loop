# task-board-loop worker rules

This repository contains the host-based task-board worker. GitHub Actions is
the preferred general-purpose worker because its runners have more CPU/RAM.

## Worker routing

- VPS-155 defaults to `TASK_ALLOWED_SCOPES=vps-155,gateway-40`.
- GitHub Actions owns `cross-device,github-actions` through its workflow scope filter.
- `device-local` stays on a user-controlled laptop.
- Untagged issues are treated as `cross-device` and stay with the runner.
- Never broaden a worker's scope to make an issue claimable. Fix labels or
  provide the required checkout instead.

## Task lifecycle

- `status:new`: eligible queue item.
- `status:in_progress` + `locked-by:*`: one worker owns it.
- `status:done`: verified work and a PR/commit reference exist.
- `status:blocked`: the current attempt cannot safely continue; the comment
  must name the reason and whether a retry is appropriate.
- `status:needs-user`: human action is required; workers must not retry it.

Transient provider, timeout, or infrastructure failures should be requeued
with evidence when safe. Do not invent solutions to ambiguous requirements,
missing credentials, destructive operations, or unavailable repository access.

Blocked issues use one `blocked_reason:<value>` label and one `attempts:<n>`
label. Canonical reasons are `provider_unavailable`, `transport_timeout`,
`worktree_unavailable`, and `no_work_product` (allowlisted for bounded retry),
plus `needs_user`, `auth_required`, `missing_checkout`, `destructive_request`,
`ambiguous_request`, `tests_failed`, `worktree_conflict`, and
`execution_failed` (not automatically retried). Comments record
`blocked_reason`, cumulative `attempts`, and `last_failure_class`. Recovery is
limited to one additional queue attempt by default, honors cooldown, and must
verify that the issue is open and still held by the recovering worker before
releasing its lock. Preserve partial worktrees when a retry is queued.

## Required work discipline

1. Read target-repository instructions before editing.
2. Work only in `work/<issue>` and its isolated worktree.
3. Run relevant tests and a secret scan.
4. Never push directly to `main`, force-push, expose secrets, or mark work done
   without a real diff/commit and verification evidence.
