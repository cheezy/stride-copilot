# Stride for GitHub Copilot

Task lifecycle skills and custom agents for [Stride](https://www.stridelikeaboss.com) kanban — a task management platform designed for AI agents.

This is the GitHub Copilot version of the [Stride plugin](https://github.com/cheezy/stride). It provides the same workflow enforcement through Copilot's skill and custom agent systems.

## Installation

Install via the Copilot CLI plugin command:

```bash
copilot plugin install https://github.com/cheezy/stride-copilot
```

### Plugin Management

```bash
copilot plugin list                        # View installed plugins
copilot plugin update stride-copilot       # Update to latest version
copilot plugin uninstall stride-copilot    # Remove plugin
```

### Migrating from v1.x (copy-based installation)

If you previously installed by copying the `.github/` directory into your project:

1. Remove the copied `.github/skills/stride-*` and `.github/agents/` files from your project
2. Install via the plugin command above
3. The plugin system handles discovery automatically — no manual file copying needed

## Mandatory Skill Chain

Every Stride skill is **MANDATORY** — not optional. Each skill contains required API fields, hook execution patterns, and validation rules that are ONLY documented in that skill. Attempting to call Stride API endpoints without the corresponding skill results in API rejections, malformed data, or hours of wasted rework.

### Workflow Order

**Recommended:** Use the single orchestrator skill for the complete lifecycle:

```
stride-workflow                  ← Activate ONCE — handles claim → explore → implement → review → complete
```

**Standalone mode** (when you need individual skills):

```
stride-claiming-tasks            ← BEFORE calling GET /api/tasks/next or POST /api/tasks/claim
    ↓
stride-subagent-workflow         ← AFTER claim succeeds, BEFORE implementation
    ↓
[implementation]
    ↓
stride-completing-tasks          ← BEFORE calling PATCH /api/tasks/:id/complete
```

When creating tasks or goals:

```
stride-enriching-tasks           ← WHEN task has empty key_files/testing_strategy/verification_steps
    ↓
stride-creating-tasks            ← BEFORE calling POST /api/tasks (work tasks or defects)
stride-creating-goals            ← BEFORE calling POST /api/tasks/batch (goals with nested tasks)
```

### Why This Matters

| Without skill | What happens |
|---------------|-------------|
| Claim without `stride-claiming-tasks` | API rejects — missing `before_doing_result` |
| Complete without `stride-completing-tasks` | 3+ failed API calls — missing `completion_summary`, `actual_complexity`, `actual_files_changed`, `after_doing_result`, `before_review_result` |
| Create task without `stride-creating-tasks` | Malformed `verification_steps`, `key_files`, `testing_strategy` — causes 3+ hours wasted during implementation |
| Create goal without `stride-creating-goals` | 422 error — wrong root key (`"tasks"` instead of `"goals"`) |
| Skip `stride-subagent-workflow` | No codebase exploration, no code review — wrong approach, missed acceptance criteria |
| Skip `stride-enriching-tasks` | Sparse task specs → implementing agent wastes 3+ hours on unfocused exploration |

## Skills

### stride-workflow

**RECOMMENDED** entry point for all task work. Single orchestrator that walks through the complete lifecycle: prerequisites, claiming, codebase exploration, implementation, self-review, hooks, and completion. Eliminates the need to remember which skills to activate at which moments. Activate once and follow through.

### stride-claiming-tasks

**MANDATORY** before any task claiming or discovery API call. Enforces proper before_doing hook execution, prerequisite verification, and immediate transition to active work. Contains the claim request format including `before_doing_result`.

### stride-completing-tasks

**MANDATORY** before any task completion API call. Contains ALL 5 required completion fields and both hook execution patterns (after_doing + before_review). Skipping causes 3+ failed API calls as missing fields are discovered one at a time.

### stride-creating-tasks

**MANDATORY** before creating work tasks or defects. Contains all required field formats — `verification_steps` must be objects (not strings), `key_files` must be objects (not strings), `testing_strategy` arrays must be arrays (not strings).

### stride-creating-goals

**MANDATORY** before batch creation or goal creation. Contains the only correct batch format — root key must be `"goals"` not `"tasks"`. Most common API error when skipped.

### stride-enriching-tasks

**MANDATORY** when a task has sparse specification. Transforms minimal human-provided specs into complete implementation-ready tasks through automated codebase exploration. 5 minutes of enrichment saves 3+ hours of unfocused implementation.

### stride-subagent-workflow

**MANDATORY** after claiming any task. Contains the decision matrix for dispatching task-explorer, task-reviewer, task-decomposer, and hook-diagnostician custom agents. Determines exploration and review strategy based on task complexity and key_files count.

## Custom Agents

### task-explorer

A read-only codebase exploration agent dispatched after claiming a task. Reads every file listed in `key_files`, finds related test files, searches for patterns referenced in `patterns_to_follow`, navigates to `where_context`, and returns a structured summary so the primary agent can start coding with full context.

### task-decomposer

Breaks goals and large tasks into dependency-ordered child tasks. Uses scope analysis, task boundary identification, and dependency ordering to produce implementation-ready task arrays with complexity estimates, key files, and testing strategies per task.

### task-reviewer

A pre-completion code review agent dispatched after implementation but before running hooks. Validates the git diff against `acceptance_criteria`, detects `pitfalls` violations, checks `patterns_to_follow` compliance, and verifies `testing_strategy` alignment. Returns categorized issues (Critical/Important/Minor) with file and line references.

### hook-diagnostician

Analyzes hook failure output and returns a prioritized fix plan. Parses compilation errors, test failures, security warnings, credo issues, format failures, and git failures with structured diagnosis per issue. Dispatched automatically when blocking hooks fail during the completion workflow.

## Configuration

Before using Stride skills, you need two configuration files in your project root:

### `.stride_auth.md`

Contains your API credentials (never commit this file):

```markdown
- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `your-token-here`
- **User Email:** `your-email@example.com`
```

### `.stride.md`

Contains hook scripts that run during the task lifecycle:

```markdown
## before_doing
git pull origin main
mix deps.get

## after_doing
mix test
mix credo --strict
```

## Automatic Hook Execution

The plugin includes automatic hook execution via `hooks.json`. When installed, Stride API calls made through the Copilot CLI are intercepted and the corresponding `.stride.md` hook commands run automatically.

### How It Works

| Stride API Call | Hook Triggered | Timing |
|----------------|----------------|--------|
| `POST /api/tasks/claim` | `before_doing` | After claim succeeds (PostToolUse) |
| `PATCH /api/tasks/:id/complete` | `after_doing` | Before completion runs (PreToolUse, blocks on failure) |
| `PATCH /api/tasks/:id/complete` | `before_review` | After completion succeeds (PostToolUse) |
| `PATCH /api/tasks/:id/mark_reviewed` | `after_review` | After review succeeds (PostToolUse) |

### .stride.md Format

Hook commands are defined in `.stride.md` using `## heading` + ` ```bash ` code blocks:

```markdown
## before_doing
```bash
git pull origin main
mix deps.get
```

## after_doing
```bash
mix test
mix credo --strict
```
```

Each command runs one at a time. If any command fails, execution stops and the hook returns exit code 2 (blocking the API call for PreToolUse hooks).

### Platform Support

- **macOS / Linux**: `stride-hook.sh` runs directly via bash
- **Windows (Git Bash / WSL)**: `stride-hook.sh` runs directly (bash is available)
- **Windows (native PowerShell)**: `stride-hook.sh` detects the platform and delegates to `stride-hook.ps1` automatically

No platform-specific configuration needed — the single `hooks.json` entry handles all platforms.

### Windows PowerShell Notes

- The PowerShell script uses `ConvertFrom-Json` (built-in, no jq needed)
- Execution policy: The delegation uses `-ExecutionPolicy Bypass` to avoid policy blocks
- Both PowerShell 5.1 (ships with Windows) and PowerShell 7+ (pwsh) are supported

### Environment Variable Caching

After a successful task claim, hook scripts extract task metadata (TASK_ID, TASK_IDENTIFIER, TASK_TITLE, etc.) from the API response and cache them to `.stride-env-cache`. Subsequent hooks can reference these variables in `.stride.md` commands (e.g., `$TASK_IDENTIFIER`). The cache is cleaned up after the `after_review` hook.

Add `.stride-env-cache` to your `.gitignore`.

### Troubleshooting

- **Hooks not firing**: Verify the plugin is installed (`copilot plugin list`) and `hooks.json` is referenced in `plugin.json`
- **Permission errors on Windows**: Ensure PowerShell execution policy allows scripts, or verify the `-ExecutionPolicy Bypass` flag is working
- **Hook failures blocking API calls**: PreToolUse hooks (after_doing) block on failure by design. Fix the underlying issue (test failures, lint errors) and retry
- **Missing .stride.md**: Hooks exit cleanly (code 0) when `.stride.md` is not present — no action needed

## Updating

Update to the latest version:

```bash
copilot plugin update stride-copilot
```

## License

MIT — see [LICENSE](LICENSE) for details.
