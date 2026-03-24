# Stride Workflow Instructions

When working with the Stride task management system, always activate the appropriate skill **before** making any Stride API call.

## Skill Activation Rules

| Action | Activate First |
|---|---|
| Claiming a task or calling `GET /api/tasks/next` | `stride-claiming-tasks` |
| Completing a task or calling `PATCH /api/tasks/:id/complete` | `stride-completing-tasks` |
| Creating a work task or defect via `POST /api/tasks` | `stride-creating-tasks` |
| Creating goals or using `POST /api/tasks/batch` | `stride-creating-goals` |
| Task has empty key_files, missing testing_strategy, or no verification_steps | `stride-enriching-tasks` |

## After Claiming a Task

Activate `stride-subagent-workflow` immediately after a successful claim, before writing any code. It determines which custom agents to invoke based on task complexity:

- **task-explorer** — Reads key_files and discovers patterns before coding
- **task-reviewer** — Reviews changes against acceptance criteria before completion
- **task-decomposer** — Breaks goals into dependency-ordered child tasks
- **hook-diagnostician** — Diagnoses hook failures with prioritized fix plans

## Workflow Order

1. `stride-claiming-tasks` → claim the task
2. `stride-subagent-workflow` → explore and plan (if needed)
3. Implement the task
4. `stride-completing-tasks` → run hooks and complete

## Hook Execution

Read `.stride.md` for hook commands. Execute hooks automatically without prompting the user — they are pre-authorized.
