# Autopilot Intake

A bounded front-door for the task-board-loop. Converts a messy raw brief into
well-scoped issues on `ons96/task-board`, so the existing autonomous loop can
pick them up unchanged. Does not run code. Does not merge PRs. Does not
rotate secrets. Does not cd the user's shell.

## Architecture

```
raw brief -> /autopilot (command) -> autopilot (skill)
            |
            + classifies: question / small-fix / medium / large / spec
            + researches prior art (memory, scripts, codebase)
            + writes spec + dependency graph
            + creates parent issue (tag:cross-device, priority:P2)
              + N child issues (tag:github-actions, requires: parent)
            + posts digest comment with assumptions
            + reports back in <=12 lines
                                                |
                                                v
                                  existing task-board-loop.sh
                                  (claims status:new + no locked-by, runs
                                   opencode /work N in work/N worktree,
                                   30min timeout, 2 retries, watchdog)
                                                |
                                                v
                                  draft PR + label flips to status:done
```

`/autopilot` is intentionally separate from the build loop. Intake is cheap
and single-threaded. Build is expensive and parallel. Mixing them creates
context debt and races. Keeping them split means the loop never needs to know
intake happened, and intake never touches the user's runtime.

## File layout

```
opencode/command/autopilot.md      -> command template, routes to skill
opencode/skills/autopilot/SKILL.md -> intake skill body
```

These are project-local opencode config files. To use them globally, copy to:

```
~/.config/opencode/command/autopilot.md
~/.config/opencode/skills/autopilot/SKILL.md
```

and restart opencode.

## Usage

From any repo:

```
/autopilot add a /cleanup command that scans for orphan backups in ~/CodingProjects and queues them as task-board issues
```

From the multi-repo root with no target repo named, the skill infers the
target from the brief keywords. If ambiguous, it asks one multiple-choice.

## Bucket behavior

| Bucket | What `/autopilot` does |
|---|---|
| **question** | Answers inline. No issues. |
| **small-fix** | One issue (`priority:P2`, `tag:github-actions`). |
| **medium** | One issue with phased body (`priority:P2`, `tag:github-actions`). |
| **large** | Parent epic (`tag:cross-device`) + N child issues (`tag:github-actions`), children `requires:` parent. |
| **spec / explore** | One issue tagged `category:research` with research plan as body. |

## Human gates (where it stops)

- Signup / OAuth / MFA / CAPTCHA
- Credential rotation or new API key
- Payment / legal / license decision
- Permission / access grant
- Production data loss or destructive op without tested reversal
- Public release / upstream main push
- Policy weakening (safety, secret, protected-path)

For everything else, the skill infers a safe default and records it as an
assumption in the issue body.

## Destructive commands

Deny-by-default. The skill body never contains `rm -rf`, `git clean`,
`git reset --hard`, `git push --force`, direct main edits, destructive DB
commands, or credential deletion. If the brief implies such an action, the
skill queues it as a `category:manual` issue with a one-sentence rationale.
Local untracked artifacts get a `category:cleanup` issue proposing a manifest
move to `~/.local/share/agent-archive/<repo>/<run>/` instead of deletion.

## What it explicitly does NOT do

- Run code. Issue creation is the only write action.
- Merge PRs. The task-board-loop handles build/PR.
- Rotate keys or secrets.
- Touch `~/.config/opencode/` directly (this PR adds files to the worktree;
  user copies to `~/.config/opencode/` when ready).
- Spawn subagents. Intake is single-threaded on purpose.
- Force-push, write to main, or delete branches.
- Modify the user's dirty working tree in any repo.

## Safety audits (pre-merge)

- [ ] `rg -n 'rm -rf|git push --force|git reset --hard|git clean' opencode/`
      returns nothing.
- [ ] No secrets / tokens / PII in either file.
- [ ] SKILL.md frontmatter `name: autopilot` (matches folder).
- [ ] Command frontmatter has `agent: general` + `description`.
- [ ] Command body references `$ARGUMENTS` correctly.
- [ ] No mention of `anthropic/`, `claude-`, or other provider strings that
      imply a specific paid model — the skill works on whatever the active
      agent model is.

## Merge plan (for the user, not the agent)

1. Review this PR.
2. If happy: copy the two files to `~/.config/opencode/`:
   ```
   cp opencode/command/autopilot.md ~/.config/opencode/command/autopilot.md
   cp -r opencode/skills/autopilot ~/.config/opencode/skills/autopilot
   ```
3. Restart opencode.
4. Test from `~/CodingProjects` root:
   ```
   /autopilot add a hello-world smoke issue tagged for the cross-device scope
   ```
5. Verify a single `status:new, tag:github-actions, priority:P2` issue was
   created on `ons96/task-board` with title under 80 chars.
6. The autonomous loop will claim it within 30 min (cron) or immediately if a
   manual run is triggered.

## Future work (NOT in this PR)

- `/autopilot` digest cron (daily summary of what the loop did overnight)
- explorer/executor split for self-improvement (read-only audit pass ->
  queued `category:research` issues)
- metrics-backed config canaries for opencode plugins/MCPs/model routing
- `--dry-run` flag for /autopilot that emits the planned issues as markdown
  without creating them (useful for reviewing intent before commit)
