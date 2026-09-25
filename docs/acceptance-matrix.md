# Issue #918 Acceptance Matrix

| Requirement | Policy section | Evidence |
|---|---|---|
| Three-part identity and lock/restart/reclaim rules | Worker identity; Lock, restart, and reclaim rules | Review policy against the loop's claim, heartbeat, and stale-lock tests; run `./task-board-loop.sh --self-test` |
| Allowed and denied actions | Allowed and denied actions | Review operator commands; confirm no direct-main, force-push, destructive, or live-claim path is authorized |
| Credential sourcing, non-persistence, and rotation | Credential handling | Secret scan and review logs/comments/config for values; rotation remains manual |
| Retryable vs human-blocked failures and safe release | Failure handling; Lock, restart, and reclaim rules | Review retry classification and blocked-flow comments; verify only owner lock is released |
| Future merge gate | Future merge gate | Confirm PR base, green CI, human approval, resolved threads, branch protection, and no force-push; auto-merge stays off |
| Enabled-but-not-started decision | Staged service decision; Fleet deployment notes | VPS-155 evidence must show `is-enabled=enabled`, `is-active=inactive`, claim-disabled default, and no task-board writes |

## Policy gate

Until every row has evidence and a human accepts this policy, fleet claims
remain disabled. This matrix does not authorize a service start or a credential
rotation.
