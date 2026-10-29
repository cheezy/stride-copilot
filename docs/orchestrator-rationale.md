# Orchestrator Rationale

Copilot CLI loads `skills/stride-workflow/SKILL.md` whole, every time a task runs, so each byte of background in it is paid again on every task. The passages below explain why the workflow is shaped the way it is, and record history that once sat inline. They live here so the skill can stay a list of things to do.

**Nothing on this page is a rule.** Where this page and the skill differ, the skill is right, and no task requires reading this page. Each section names the place in the skill it came from, and that place now carries a one-line pointer back here.

## The Session That Prompted a Single Orchestrator

*Taken from `skills/stride-workflow/SKILL.md`, Purpose.*

During a 17-task session, an agent consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. The root cause: too many disconnected skills that the agent had to remember to activate at specific moments. Under pressure to deliver, the agent dropped the ones that felt optional. This orchestrator eliminates that failure mode.

## What Step 3 Item 4 Used to Say

*Taken from `skills/stride-workflow/SKILL.md`, Step 3, All Other Tasks, item 4.*

Item 4 previously said "for medium+ tasks", which diverged from the matrix for a medium defect (Plan = Skip unless large) (D221).

## The Case for a Second Security Opinion

*Taken from `skills/stride-workflow/SKILL.md`, Step 5, Deep security-considerations review.*

The self-review records a `security_considerations` section verdict, but as a generalist. When the `stride-copilot-security-review` plugin is installed, this sub-step runs the *specialist* `security-reviewer` agent against each of the task's `security_considerations`, folds a per-consideration verdict into the completion payload, and routes any un-addressed consideration through the same gate that already blocks on a failed section — so a real, unmitigated security implication cannot reach Done.

## Why Manual Tests Get Run as Charters

*Taken from `skills/stride-workflow/SKILL.md`, Step 5.5, Why this step exists.*

Tasks routinely carry `manual_tests` in their `testing_strategy`, but the workflow has historically had no way to actually perform them — they were left to a human or silently skipped. When the `stride-copilot-exploratory-testing` plugin is installed, each manual test becomes a **charter** and the explorer runs a real, time-boxed exploratory session, closing the gap between "tests written" and "tests performed."

## Closing the Loop From Explored to Checked

*Taken from `skills/stride-workflow/SKILL.md`, Step 5.6, Why this step exists.*

A session that finds a bug and stops has closed nothing — the same bug can return unnoticed. `-harden` reads the bugs a session confirmed and drafts one regression check per convertible bug, which is the step that turns *Explored* back into *Checked*. It is the only place this workflow can close that loop automatically.

## Inner and Outer Hook Time Limits

*Taken from `skills/stride-workflow/SKILL.md`, Step 6, Hooks Reference, Timeout budgets (W1513).*

The `Timeout` column in Step 6's Hooks Reference is the inner per-hook budget, enforced by the executor on the `.stride.md` section itself. This is distinct from the **outer host budget** — the flat `300s` timeout on each `PreToolUse`/`PostToolUse` Bash entry in `hooks/hooks.json`, which is the ceiling the host gives the whole `stride-hook` invocation (section + the plugin's own diff capture/upload bookkeeping). Every inner limit (60s / 120s) sits well under the 300s outer ceiling, so the two never conflict.

## Finding after_goal When the Response Is Truncated

*Taken from `skills/stride-workflow/SKILL.md`, Step 8, If this completion finishes the parent goal's last child task.*

The `/complete` (and `/mark_reviewed`) response can be large — the echoed `reviewer_result` alone runs to tens of KB — and the harness truncates the `tool_response.stdout` the plugin's `hooks/stride-hook.sh` / `stride-hook.ps1` would otherwise parse. The completion/claim curls therefore capture the full response to the canonical file `$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json` (the `| tee` pattern documented in `stride-completing-tasks` / `stride-claiming-tasks`), which the hook reads in preference to the truncatable stdout (D118). When that file is absent or unreadable, the hook falls back to a fresh, hook-initiated `GET /api/tasks/:id/after_goal_status` (D119) — a subprocess the hook spawns, immune to harness truncation and needing no agent cooperation. The two paths are mutually exclusive, so the `## after_goal` section runs at most once. Detection therefore does not depend on the agent's curl output being intact.

## Goals That Close Without a Posted Result

*Taken from `skills/stride-workflow/SKILL.md`, Step 8, Back-compat.*

- If `.stride.md` has no `## after_goal` section, the hook bridge silently no-ops — no JSON is emitted, no POST is needed. The server's grace-window worker (configured per board, typically a few minutes) will promote the goal to Done automatically.
- If the agent doesn't POST the result at all (older plugin versions, scripted environments), the same grace-window worker covers the gap. The goal transitions to Done after the wait expires, with `after_goal_status: :succeeded` and a synthetic attempt tagged `source: "after_goal_grace_worker"` in the audit log.

## How Completion Validation Is Being Switched On

*Taken from `skills/stride-workflow/SKILL.md`, Explorer and Reviewer Result Rollout.*

The server is rolling out hard enforcement behind a feature flag `:strict_completion_validation`:

| Phase | Server behavior | Agent impact |
|---|---|---|
| **Grace (current)** | Missing or invalid results log a structured warning and the request succeeds | Emit the fields correctly now; the warning volume is a preview of the strict-mode rejection volume |
| **Strict (after all 5 plugins release)** | Missing or invalid results return `422` with a `failures` list | Any agent not emitting valid fields is locked out of completion |

## What the Orchestrator Was Built to Stop

*Taken from `skills/stride-workflow/SKILL.md`, Failure Modes This Skill Prevents.*

| Failure Mode | Old Pattern | This Skill |
|---|---|---|
| Forgot to explore | Agent skipped stride-subagent-workflow | Step 3 is inline -- can't be missed |
| Forgot to review | Agent jumped to completion | Step 5 is inline -- can't be missed |
| Wrong API fields | Agent guessed from memory | Step 7 has the exact format |
| Skipped hooks | Agent called complete directly | Step 6 blocks Step 7 |
| Asked user permission | Agent prompted between steps | Core principle says don't |
| Speed over process | Agent optimized for throughput | Every step is framed as mandatory |
