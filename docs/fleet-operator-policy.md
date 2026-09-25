# Fleet Operator Safety Policy

Status: proposed for issue #918. This policy is a prerequisite for unattended
claims from a laptop or VPS-155. It defines operator boundaries; it does not
add runtime claim features. Until this policy is accepted, live claims remain
disabled.

## Worker identity

Every worker identity has three parts: runner class, host, and ordinal. The
canonical form is `<runner>-<host>-<ordinal>`, for example
`local-vps155-w1` or `gha-run-123`. A process keeps one immutable identity for
its lifetime and owns exactly one `locked-by:<identity>` label. Identities are
not shared, copied, or reused by another live process. The host and ordinal
make concurrent workers distinguishable; the runner class identifies the
execution trust boundary (`local`, `gha`, or `svc`).

## Lock, restart, and reclaim rules

1. A worker may claim only an eligible `status:new` issue in its configured
   scope. Claiming adds its lock and `status:in_progress`, then performs the
   two-second race check. A worker that loses the race releases its own labels
   and does no work.
2. The worker posts periodic heartbeats while active. A lock is not proof of
   liveness: the heartbeat and GitHub's update time are the evidence.
3. A restart never silently takes a foreign lock. A same-host replacement may
   reclaim only after the documented stale threshold and only when the prior
   process is dead. A foreign-host lock requires the longer stale threshold and
   an explanatory comment before release. GitHub server time is authoritative.
4. Safe release removes the worker's lock and in-progress label, removes its
   assignee, and applies `status:done` or `status:blocked` as appropriate. The
   worker then posts the result. Operators must not remove another worker's
   lock as a convenience or to force progress.
5. A watchdog or operator may reclaim a stale lock only with evidence of the
   stale condition, an audit comment, and no active heartbeat. Reclaim is never
   a reason to delete worktree data or discard uncommitted changes.

## Allowed and denied actions

Allowed actions are limited to the worker's scope: inspect the issue, create
or use its `work/<N>` branch and worktree, edit tracked files in that worktree,
run tests and safety checks, use approved free-tier providers, comment on its
issue, and open a PR targeting `main`. The worker may change labels and
assignee only for its own claim lifecycle.

Denied actions include direct edits or pushes to `main`, merging its own PR,
force-pushing (including `--force-with-lease` on shared branches), deleting or
rewriting another worker's branch, and enabling live claims while this policy
is unresolved. Operators must not run destructive commands such as `rm -rf`
outside an explicitly disposable worktree, `git reset --hard`, `git clean`
with deletion scope beyond that worktree, destructive database commands, or
service-wide shutdowns. No worker may broaden scope, bypass branch
protection, disable safety checks, or make unreviewed production changes.

## Credential handling

Credentials come only from the pre-existing process environment or approved
local authentication stores. They are read at process start as needed and are
never copied into a repository, worktree, artifact, SQLite database, log,
issue comment, PR, or commit. Logs and comments contain identifiers and
outcomes, never values or authorization headers. The staged service receives
no new credential material.

Rotation is manual and supervised. If exposure is suspected, stop claims,
revoke and rotate the affected credential, remove exposed artifacts, and run
secret scanning before any worker is re-enabled. Workers do not create,
delete, or rotate credentials autonomously.

## Failure handling

Retryable failures are transient network errors, provider 5xx responses,
429/rate limits, timeouts, transport resets, and a documented transient CI
failure. Retry with bounded exponential backoff and the configured model
fallbacks. After the retry budget is exhausted, release the claim and skip or
block with evidence; never spin indefinitely.

Human-blocked failures are authentication or authorization errors (401/403),
missing repository or scope access, secret-scan findings, ambiguous
requirements, repeated verification failure, a required destructive action,
or any unclassified exit. Mark `status:blocked`, release only the worker's
own lock, and comment with a safe diagnosis that contains no secrets. Human
review is required before retrying a blocked issue.

## Future merge gate

Auto-merge remains disabled. A future merge requires a PR whose expected base
is `main`, a head commit up to date with that base, all required CI checks
green (including secret and safety checks), at least one human approval, and
all review threads resolved with no outstanding change request. Branch
protection must require PRs, approvals, required checks, conversation
resolution, and prohibit direct pushes, force-pushes, branch deletion, and
bypass. The merge must use a linear history without force-push; policy changes
require a human merger. Approvals must be fresh after the final CI result.

## Staged service decision

Decision: promote the VPS-155 fleet service to **enabled but not started**.
The unit must retain its claim-disabled default, such as `FLEET_CLAIM=0`, and
must not perform task-board writes. Enabling permits boot-time staging and
inspection without creating live claims. A separate human decision is required
before starting it with claims enabled. To reverse the staging decision, run
`systemctl --user disable --now <unit>` and remove the unit through the normal
reviewed deployment procedure.
