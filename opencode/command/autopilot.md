---
description: Convert a raw idea or messy brief into well-scoped task-board issues for the autonomous loop. Runs intake: parse, classify (question/small/medium/large/spec), sniff prior art, write spec, create parent + child issues on ons96/task-board. Stops only for human-only gates (signup/MFA/credentials/payment/legal/access grant/production loss/public push/policy weakening).
agent: general
---

You are running the **autopilot intake**. Load the `autopilot` skill and execute its pipeline on the user's raw brief below.

# Input

The user typed:

$ARGUMENTS

# Execution rules

- Follow the skill pipeline in order. Do not skip phases.
- If the brief names a target repo, use it. If not, infer from keywords in `~/CodingProjects/<repos>`. If ambiguous, ask ONE multiple-choice question via the `question` tool and stop.
- Use `gh` CLI for all issue creation. If `gh` fails with auth-not-found, run `unset GITHUB_TOKEN GH_TOKEN; gh auth switch --user ons96` ONCE and retry. Never expose tokens in committed files or issue bodies.
- Apply all labels the skill specifies. Default priority is `priority:P2`. Default scope tag is `tag:github-actions` for child issues (so the GH Actions runner can claim them), `tag:cross-device` for parent epics.
- Record assumptions explicitly in the issue body. Do not silently absorb user intent.
- Do NOT execute destructive operations. Queue them as `category:manual` issues instead.
- Stop and ask the user ONE concise question only when hitting a HUMAN gate (signup/MFA/credentials/payment/legal/access grant/production loss/public push/policy weakening). For anything else, infer a safe default and proceed.

# Output format

When done, reply with:

1. **Bucket chosen**: question | small-fix | medium | large | spec
2. **Issues created**: bullet list of `#N — <title>` with URL
3. **Assumptions made**: bullet list
4. **Next**: one sentence. Either "task-board-loop will pick up child issues tagged `tag:github-actions`" OR "no issues created — answered inline" OR one human-gate question.

Keep the reply under 12 lines. The detail lives in the issue bodies, not here.
