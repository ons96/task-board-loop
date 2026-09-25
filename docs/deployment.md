# Fleet Deployment Notes

This document records the safe staging posture for issue #918. VPS-155 may
have the fleet unit installed and enabled, but it must remain inactive and
claim-disabled while the policy is proposed or unresolved.

## Safe lifecycle

Use the reviewed unit name and environment configured on VPS-155; never put
credential values in this document.

```text
systemctl --user is-enabled <unit>   # expected: enabled
systemctl --user is-active <unit>    # expected: inactive
systemctl --user disable --now <unit> # rollback staging
```

Starting, restarting, or changing claim-related environment is a human-gated
operation. No unattended operator may enable live claims. The unit's default
must remain claim-disabled, and logs must show no task-board claim or label
writes during staging.

## Safe lock release

Only the owning worker may release a live lock during normal operation. For a
stale foreign lock, first verify the stale threshold, dead or absent heartbeat,
and absence of an active worker; then record the reason in the issue comment,
remove only the stale lock and assignee, and return the issue to `status:new`.
Never delete a worktree or reset files as part of lock recovery.

## Evidence before promotion

Review the policy and acceptance matrix, inspect service status and journal,
and confirm there are no new `locked-by:*` labels or claim comments during the
staging window. Credential values, tokens, and authorization headers must not
appear in command output, logs, comments, or artifacts.
