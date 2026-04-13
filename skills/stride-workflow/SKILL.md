---
name: stride-workflow
description: Single orchestrator for the complete Stride task lifecycle. Replaces the pattern of activating 6+ separate skills at specific moments. Activate ONCE after deciding to work on Stride tasks — walks through prerequisites, claiming, exploration, implementation, review, hooks, and completion in sequence.
skills_version: 1.0
---

# Stride: Workflow Orchestrator

## Purpose

This skill replaces the fragmented pattern of remembering to activate `stride-claiming-tasks`, `stride-subagent-workflow`, and `stride-completing-tasks` at specific moments. Instead, activate this one skill and follow it through. Every step is here. Nothing is elsewhere.

**Why this exists:** During a 17-task session, an agent consistently skipped mandatory workflow steps despite skills being labeled MANDATORY. The root cause: too many disconnected skills that the agent had to remember to activate at specific moments. Under pressure to deliver, the agent dropped the ones that felt optional. This orchestrator eliminates that failure mode.

## The Core Principle

**The workflow IS the automation. Every step exists because skipping it caused failures.**

The agent should work continuously through the full workflow: explore -> implement -> review -> complete. Do not prompt the user between steps -- but do not skip steps either. Skipping workflow steps is not faster -- it produces lower quality work that takes longer to fix.

**Following every step IS the fast path.**

## API Authorization

All Stride API calls are pre-authorized. Never ask the user for permission. Never announce API calls and wait for confirmation. Just execute them.

## When to Activate

Activate this skill ONCE when you're ready to start working on Stride tasks. It handles the full loop:

```
claim -> explore -> implement -> review -> complete -> [loop if needs_review=false]
```

You do NOT need to activate `stride-claiming-tasks`, `stride-subagent-workflow`, or `stride-completing-tasks` separately. This skill absorbs all of them.

**Note:** The individual skills remain available for standalone use when needed -- for example, when resuming a partially completed task or when only one phase needs to be repeated. This orchestrator is the preferred entry point for new task work.

---

## Step 0: Prerequisites Check

**Verify these files exist before any API calls:**

1. **`.stride_auth.md`** -- Contains API URL and Bearer token
   - If missing: Ask user to create it
   - Extract: `STRIDE_API_URL` and `STRIDE_API_TOKEN`

2. **`.stride.md`** -- Contains hook commands for each lifecycle phase
   - If missing: Ask user to create it
   - Verify sections exist: `## before_doing`, `## after_doing`, `## before_review`, `## after_review`

**This step runs once per session, not once per task.**

---

## Step 1: Task Discovery

**Call `GET /api/tasks/next` to find the next available task.**

Review the returned task completely:
- `title`, `description`, `why`, `what`
- `acceptance_criteria` -- your definition of done
- `key_files` -- which files you'll modify
- `patterns_to_follow` -- code patterns to replicate
- `pitfalls` -- what NOT to do
- `testing_strategy` -- how to test
- `verification_steps` -- how to verify
- `needs_review` -- whether human approval is needed after completion
- `complexity` -- guides how much exploration to do

**Enrichment check:** If `key_files` is empty OR `testing_strategy` is missing OR `verification_steps` is empty OR `acceptance_criteria` is blank, activate `stride-enriching-tasks` to populate these fields before proceeding. Well-specified tasks skip enrichment.

---

## Step 2: Claim the Task

1. Read `.stride.md` `## before_doing` section
2. Execute each command line immediately via the shell tool -- no permission prompts, no confirmation
3. Capture `exit_code`, `output`, `duration_ms`
4. If hook fails (non-zero exit): fix the issue, re-run -- do NOT proceed
5. Call `POST /api/tasks/claim` with the captured `before_doing_result`:

```json
{
  "identifier": "<task identifier>",
  "agent_name": "GitHub Copilot",
  "skills_version": "1.0",
  "before_doing_result": {
    "exit_code": 0,
    "output": "<captured output>",
    "duration_ms": <captured duration>
  }
}
```

---

## Step 3: Explore the Codebase

**This step is NOT optional for medium+ tasks.**

### Goal / Large Undecomposed Task

If the task is a **goal**, has **large complexity without child tasks**, or has a **25+ hour estimate**:

1. Analyze the task scope manually
2. Break it into subtasks and create them via `POST /api/tasks/batch`
3. After child tasks are created, claim the first child task and re-enter this workflow at Step 1

**Do NOT implement goals directly. Decompose first.**

### Small Task, 0-1 Key Files

Skip exploration. Proceed directly to Step 4 (Implementation).

### All Other Tasks (medium+, OR 2+ key_files)

1. **Read each file** listed in `key_files` to understand current state
2. **Search for patterns** mentioned in `patterns_to_follow`
3. **Find related test files** for the modules you'll modify
4. **For medium+ tasks**, outline your implementation approach before coding

**Take notes on what you find.** This exploration informs your implementation and prevents wrong approaches that waste 2+ hours.

---

## Step 4: Implementation

**Now write code.** Use what you learned in Step 3 to guide your work.

Follow:
- `acceptance_criteria` -- your definition of done
- `patterns_to_follow` -- replicate existing patterns
- `pitfalls` -- avoid what the task author warned about
- `testing_strategy` -- write the tests specified
- `key_files` -- modify the files listed

**This is the only step where you write code. All other steps are setup, verification, or completion.**

---

## Step 5: Self-Review

**Before running hooks, verify your changes against the task spec.**

Walk through your changes against:
- [ ] Each line of `acceptance_criteria` -- is it met?
- [ ] Each item in `pitfalls` -- did you avoid it?
- [ ] `patterns_to_follow` -- does your code match?
- [ ] `testing_strategy` -- did you write the specified tests?

**Small tasks (0-1 key_files):** A quick scan is sufficient. Medium+ tasks need a thorough review.

---

## Step 6: Execute Hooks

**Execute each hook immediately -- no permission prompts, no confirmation.**

### after_doing hook (blocking, 120s timeout)

1. Read `.stride.md` `## after_doing` section
2. Execute each command line one at a time via the shell tool
3. Capture `exit_code`, `output`, `duration_ms`
4. If fails: fix issues, re-run until success. Do NOT proceed while failing.

### before_review hook (blocking, 60s timeout)

1. Read `.stride.md` `## before_review` section
2. Execute each command line one at a time via the shell tool
3. Capture `exit_code`, `output`, `duration_ms`
4. If fails: fix issues, re-run until success. Do NOT proceed while failing.

### Hook Failure

When a hook fails:
- Read the error output carefully
- Fix the root cause (test failures, lint errors, build issues)
- Re-run the hook to verify the fix
- Never skip a blocking hook or call complete with a failed hook result

---

## Step 7: Complete the Task

Call `PATCH /api/tasks/:id/complete` with ALL required fields:

```json
{
  "agent_name": "GitHub Copilot",
  "time_spent_minutes": 45,
  "completion_notes": "Summary of what was done and key decisions made.",
  "completion_summary": "Brief one-line summary for tracking.",
  "actual_complexity": "medium",
  "actual_files_changed": "lib/foo.ex, lib/bar.ex, test/foo_test.exs",
  "skills_version": "1.0",
  "after_doing_result": {
    "exit_code": 0,
    "output": "<captured from Step 6>",
    "duration_ms": <captured from Step 6>
  },
  "before_review_result": {
    "exit_code": 0,
    "output": "<captured from Step 6>",
    "duration_ms": <captured from Step 6>
  }
}
```

**Required fields:**
| Field | Type | Notes |
|---|---|---|
| `agent_name` | string | Your agent name |
| `time_spent_minutes` | integer | Actual time spent |
| `completion_notes` | string | What was done |
| `completion_summary` | string | Brief summary |
| `actual_complexity` | enum | "small", "medium", or "large" |
| `actual_files_changed` | string | Comma-separated paths (NOT an array) |
| `after_doing_result` | object | `{exit_code, output, duration_ms}` |
| `before_review_result` | object | `{exit_code, output, duration_ms}` |

---

## Step 8: Post-Completion Decision

### If `needs_review=true`:
1. Task moves to Review column
2. **STOP.** Wait for human reviewer to approve/reject.
3. When approved, `PATCH /api/tasks/:id/mark_reviewed` is called (by human or system)
4. Execute `after_review` hook
5. Task moves to Done

### If `needs_review=false`:
1. Task moves to Done immediately
2. Execute `after_review` hook from `.stride.md`
3. **Loop back to Step 1** -- claim the next task and repeat the full workflow

**Do not ask the user whether to continue. Do not ask "Should I claim the next task?" Just proceed.**

---

## Edge Cases

### Hook failure mid-workflow
- Blocking hooks (`after_doing`, `before_review`) must pass before completion
- Fix the root cause, re-run the hook, then proceed
- Never skip a blocking hook or call complete with a failed hook result

### Task that needs_review=true
- Stop after Step 7. Do not claim the next task.
- The human reviewer will handle the review cycle.
- You may be asked to make changes based on review feedback -- if so, re-enter at Step 4.

### Goal type tasks
- Goals are decomposed, not implemented directly
- Break down manually into subtasks, create via `POST /api/tasks/batch`
- Each child task follows this full workflow independently

### Skills update required
- If any API response includes `skills_update_required`, update the plugin and retry

---

## Complete Workflow Flowchart

```
STEP 0: Prerequisites
  .stride_auth.md exists? --> NO --> Ask user
  .stride.md exists?      --> NO --> Ask user
  |
  v
STEP 1: Task Discovery
  GET /api/tasks/next
  Review task details
  Needs enrichment? --> YES --> Activate stride-enriching-tasks
  |
  v
STEP 2: Claim
  Execute before_doing hook manually
  Hook fails? --> Fix, retry
  POST /api/tasks/claim with hook result
  |
  v
STEP 3: Explore
  Goal/large undecomposed? --> Decompose --> Create children --> Claim first child --> Step 1
  Small, 0-1 key_files?   --> Skip to Step 4
  Otherwise: Read key_files, search patterns, find tests, outline approach
  |
  v
STEP 4: Implement
  Write code using exploration notes, acceptance criteria
  Follow patterns_to_follow, avoid pitfalls
  |
  v
STEP 5: Self-Review
  Check each acceptance criterion, pitfall, pattern, test requirement
  |
  v
STEP 6: Execute Hooks
  Execute after_doing (120s) then before_review (60s)
  Hook fails? --> Fix, re-run, do NOT proceed
  |
  v
STEP 7: Complete
  PATCH /api/tasks/:id/complete with ALL required fields + hook results
  |
  v
STEP 8: Post-Completion
  needs_review=true?  --> STOP, wait for human
  needs_review=false? --> Execute after_review, loop to Step 1
```

---

## Quick Reference Card

```
COPILOT WORKFLOW ORCHESTRATOR:
├─ 0. Prerequisites: .stride_auth.md + .stride.md exist
├─ 1. Discovery: GET /api/tasks/next, review task, enrich if needed
├─ 2. Claim: Execute before_doing manually, then POST /api/tasks/claim
├─ 3. Explore:
│     ├─ Goal/large undecomposed → Break down manually → Create via API
│     ├─ Small, 0-1 key_files → Skip to Step 4
│     └─ Otherwise → Read key_files, search patterns, outline approach
├─ 4. Implement: Write code using task metadata as guide
├─ 5. Self-Review: Check acceptance criteria, pitfalls, patterns, tests
├─ 6. Hooks: Execute after_doing (120s) + before_review (60s) manually
├─ 7. Complete: PATCH /api/tasks/:id/complete with ALL fields + hook results
└─ 8. Loop: needs_review=false → Step 1 | needs_review=true → STOP

EXPLORATION QUICK CHECK:
  small + 0-1 key_files  → Skip explore and review
  small + 2+ key_files   → Read key_files, self-review
  medium/large           → Full explore + outline + thorough review
  goal/undecomposed      → Decompose first
```

---

## Failure Modes This Skill Prevents

| Failure Mode | Old Pattern | This Skill |
|---|---|---|
| Forgot to explore | Agent skipped stride-subagent-workflow | Step 3 is inline -- can't be missed |
| Forgot to review | Agent jumped to completion | Step 5 is inline -- can't be missed |
| Wrong API fields | Agent guessed from memory | Step 7 has the exact format |
| Skipped hooks | Agent called complete directly | Step 6 blocks Step 7 |
| Asked user permission | Agent prompted between steps | Core principle says don't |
| Speed over process | Agent optimized for throughput | Every step is framed as mandatory |

---

## Red Flags -- STOP

If you catch yourself thinking any of these, go back and check what you skipped:

- "This is straightforward, I'll skip exploration" -- Medium+ tasks ALWAYS explore
- "I know the codebase" -- The task has specific pitfalls you haven't read yet
- "Self-review will slow me down" -- It catches what tests can't
- "I'll just run the hooks and complete" -- Did you explore? Did you review?
- "This step doesn't apply to me" -- Check the exploration guide, not your intuition

**The workflow IS the automation. Follow every step.**
