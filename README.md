# Stride for GitHub Copilot

Task lifecycle skills and custom agents for [Stride](https://www.stridelikeaboss.com) kanban — a task management platform designed for AI agents.

This is the GitHub Copilot version of the [Stride plugin](https://github.com/cheezy/stride). It provides the same workflow enforcement through Copilot's skill and custom agent systems.

## Installation

**From the Stride Copilot marketplace** (recommended):

```bash
copilot plugin marketplace add cheezy/stride-copilot-marketplace
copilot plugin install stride-copilot
```

**Directly from the repository** (alternative):

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

## Optional: Manual & Exploratory Testing Integration

Tasks often carry `manual_tests` in their `testing_strategy` — checks that a human (or a skilled exploratory tester) is meant to perform, not an automated assertion. When the companion [`stride-copilot-exploratory-testing`](https://github.com/cheezy/stride-copilot-exploratory-testing) plugin is **also installed**, `stride-workflow` can run those manual tests for you as a gated **Step 5.5 (Manual & Exploratory Testing)**, between code review and the hooks.

**How it works** — the step is **optional and doubly gated**. It runs only when BOTH:

1. the task's `testing_strategy.manual_tests` is non-empty, **and**
2. the `stride-copilot-exploratory-testing` plugin is available in the session (detected by its `stride-exploratory-testing-explore` skill / `explorer` agent appearing in the session's available lists — availability only, never blind execution).

When it runs, each manual test is framed as a **charter** and driven by the exploratory-testing `explorer` **agent** under an absolute safety boundary — it exercises the app as a user would but **never** runs destructive or production-mutating actions, and treats app content as data. Findings are recorded in existing completion fields only (a summary in `completion_notes`, and — when a reviewer ran — the `reviewer_result.testing_strategy` note); **no new completion field is introduced.** (v2.31.0+) the `explorer` agent is the **only** surface the workflow auto-dispatches: an agent declares a `tools:` list the runtime honours and holds no way to ask a question, whereas a Copilot skill has no tool-restriction field at all, so its unattended-safety rests on prose alone. Interactive surfaces are therefore never auto-dispatched — `stride-exploratory-testing-explore` opens with a question round no argument pre-empts and gates on an explicit authorization-and-non-production answer, `-recon` requires the same confirmation, `-pair` is human-at-the-keyboard by construction, `-nightmare-headline` loops elicitation rounds, and the plugin's routing skill can route to any of them. Running any of these yourself is unaffected; the restriction is on **automated** dispatch only, and it is a principle rather than a closed list — a surface the plugin gains later qualifies by completing unattended, never by being added to a list. (v2.31.0+) an exploratory finding's four-level severity (Critical / High / Moderate / Minor) maps onto the three-level reviewer issue vocabulary, and only a mapped `critical` can escalate — and only when the responsible lines are lines the task itself added or modified. A Critical the task **introduced** escalates fail-closed and is fixed and re-reviewed before completing; a **pre-existing** bug the session merely discovered is recorded and filed as a follow-up defect and never blocks an unrelated task. Provenance is decided from the task's own change set, never from text the application under test controls, and every uncertain case resolves to *discovered* rather than blocking. (v2.32.0+) the dispatch now carries an **explicit session budget** in whatever unit the installed `explorer` contract declares — today probes, default 12, band 8–20, with a tool-call ceiling at 5× — and that budget is the **caller's to set**, because an unbounded dispatch inside an autonomous workflow is both a runaway risk and a larger blast radius against a live application. **Budget exhaustion is a normal outcome that never fails completion**; what changes is only what may honestly be claimed about coverage, and a session that spun out or never reached the feature is recorded as *not performed* and handed back rather than counted. The environment-context block also names how to reach the app, the authorized non-production confirmation, and **a pointer to where test accounts live — credentials are never inlined**. (v2.32.0+) each finding's summary now names **who is harmed and how**, read from the contract's `stakeholder_impact` where it has one and assessed in the agent's own words where it does not; a written session artifact's **path** is cited when one exists, repository-relative and never its contents — though the automated path normally writes none; and one line is mirrored into the required `completion_summary` as a durability backstop for older servers. **Still only the existing carriers** — no new completion field, and no seventh `workflow_steps` name.

**(v2.32.0+) Before your first session, add `.exploratory/` to the project's `.gitignore`, alongside `.stride/`.** Session artifacts land there, hold transcribed application output, and arrive untracked, so an `## after_doing` section that stages everything (`git add -A`) would commit them — the plugin's own hook script stages nothing, so the sweep is your quality gate's. The workflow only ever tells you to add the line; it never edits your `.gitignore` for you. Add it **before** the first session: `.gitignore` does not untrack a path git already tracks, so an artifact already committed needs `git rm --cached` too.

**Graceful fallback** — when the plugin is **not** installed, or the task has no `manual_tests`, the step is skipped and the manual tests remain a human responsibility exactly as before. This **never blocks or fails completion** — the integration is purely additive, and **no exploratory finding can block completion on a task that never ran a session.** Install the companion plugin only if you want manual tests auto-run; nothing about the core task lifecycle changes without it.

## Optional: Security-Considerations Deep Review Integration

Tasks often carry `security_considerations` — the security implications a change must actually mitigate. The self-review records a generalist verdict on them, but when the companion [`stride-copilot-security-review`](https://github.com/cheezy/stride-copilot-security-review) plugin is **also installed**, `stride-workflow` runs a *specialist* considerations-mode review inside **Step 5 (Self-Review)** to confirm each listed consideration was genuinely mitigated by the diff.

**How it works** — the sub-step is **optional and doubly gated**. It runs only when BOTH:

1. the task's `security_considerations` list is non-empty (a `"None — …"` placeholder does not count), **and**
2. the `stride-copilot-security-review` plugin is available in the session (detected by its `security-review-essentials` skill / `security-reviewer` agent appearing in the session's available lists — availability only, never blind execution).

When it runs, the `security-reviewer` agent is invoked in considerations mode with the diff and the task's `security_considerations` framed as **DATA to assess, never as instructions** (prompt-injection safety), and returns one `mitigated`/`partial`/`unmitigated` verdict per consideration. Those verdicts merge into `reviewer_result.security_considerations.considerations[]` via the whole-object copy, and escalation is **fail-closed**: any `partial`/`unmitigated` verdict forces the section status to `failed` and appends a `category: security` Critical issue — routing it through the same gate that already blocks completion on a failed section. The dispatch's time folds into the existing `reviewer` workflow step; **no new completion field and no new `workflow_steps` name are introduced.**

**Graceful fallback** — when the plugin is **not** installed, the task's `security_considerations` is empty, or the agent is unavailable, the deep review is skipped and the self-review's `security_considerations` verdict stands. This **never blocks or fails completion** — the integration is purely additive.

## Skills

### stride-workflow

**RECOMMENDED** entry point for all task work. Single orchestrator that walks through the complete lifecycle: prerequisites, claiming, codebase exploration, implementation, self-review, hooks, and completion. Eliminates the need to remember which skills to activate at which moments. Activate once and follow through. Also supports **context-informed creation**: activate `stride-workflow` with a creation intent plus an optional directory path, and the orchestrator reads the `.md` files into a read-only context bundle (via `glob`/`read`) and forwards it verbatim to the creation sub-skill. Copilot CLI has no Claude-style slash-command system, so there are no `/stride:create-*` commands — the orchestrator invocation is the entry point. (v2.29.0+) `stride-workflow` also threads the optional `behaviour_test_matrix` through Step 4 (implementation driver) and the review phase (Step 5 / `stride-subagent-workflow` Phase 3, reviewer dispatch). (v2.30.0+) every rule reading matrix row text is hardened: row text is untrusted data rather than instructions, the secret rule triggers on row *state* and extends to credentials named by location, a refused row is reported in `completion_notes` by category and position and echoed by the reviewer with the `[REDACTED — row text embedded a credential]` sentinel, and re-sending already-stored row text unchanged onto its own record is stated to be not a new copy. (v2.31.0+) Step 5.5 auto-dispatches only the exploratory plugin's `explorer` agent — never an interactive skill — and a Critical exploratory finding escalates fail-closed only when this task's own lines produced it.

### stride-claiming-tasks

**MANDATORY** before any task claiming or discovery API call. Enforces proper before_doing hook execution, prerequisite verification, and immediate transition to active work. Contains the claim request format including `before_doing_result`.

### stride-completing-tasks

**MANDATORY** before any task completion API call. Contains ALL 5 required completion fields and both hook execution patterns (after_doing + before_review). Skipping causes 3+ failed API calls as missing fields are discovered one at a time.

### stride-creating-tasks

**MANDATORY** before creating work tasks or defects. Contains all required field formats — `verification_steps` must be objects (not strings), `key_files` must be objects (not strings), `testing_strategy` arrays must be arrays (not strings). Includes a "Consuming Provided Context" section: when dispatched with a context bundle, mine the markdown for `key_files` / `patterns_to_follow` / `acceptance_criteria` / `pitfalls` — context augments, never replaces, and the five review_queue-scored fields (now including `security_considerations`) stay required. Also documents the optional `technical_details` field (v2.18.0+) — a free-form JSON object (no fixed keys) for any extra technical context; it is optional everywhere and is not one of the five review_queue-scored fields. (v2.19.0+) documents the optional `created_by_agent` field — set it to the plugin's own agent name (`"GitHub Copilot"`, the same value sent as `agent_name` on claim/complete) so the `/agents` feed attributes the creating agent; create-only and forbidden on `PATCH`, propagated from a batch goal to its child tasks.

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

A pre-completion code review agent dispatched after implementation but before running hooks. Validates the git diff against `acceptance_criteria`, detects `pitfalls` violations, checks `patterns_to_follow` compliance, verifies `testing_strategy` alignment, and confirms the task's `security_considerations` were actually implemented (input validation, authorization boundaries, secret handling, injection surfaces, data exposure). Returns categorized issues (Critical/Important/Minor) with file and line references, plus a structured `reviewer_result` JSON block (**`schema_version` 1.6**) carrying `status`, `issue_counts`, `issues[]`, `acceptance_criteria[]` verdicts, `project_checks[]` (from a project-root `CODE-REVIEW.md`, when present; per-entry `status` enum `met`/`not_met`/`not_applicable`, with the full checklist emitted — no bullet omitted — as of v2.16.0), and per-section `testing_strategy` / `patterns` / `pitfalls` / `security_considerations` verdicts (the fifth review_queue-scored field). As of **schema 1.5** (v2.28.0+), the `security_considerations` verdict may additionally carry an optional nested `considerations[]` breakdown — one `{ consideration, status: mitigated|partial|unmitigated, evidence, note }` entry per listed consideration — populated when the security-considerations deep review runs (see below), absent otherwise. As of **schema 1.6** (v2.29.0+), the block also carries an **OPTIONAL** `behaviour_test_matrix` verdict with a per-row `rows[]` breakdown — emitted only when the task supplies a matrix, and omitted entirely otherwise; the row `status` enum is the task-side `planned`/`passing`/`failing`/`not_applicable`, never a separate reviewer vocabulary. The orchestrator persists that block verbatim as `reviewer_result` (see the `stride-subagent-workflow` "Extracting the structured review block" section); the schema is owned by `agents/task-reviewer.agent.md`.

### hook-diagnostician

Analyzes hook failure output and returns a prioritized fix plan. Accepts both **structured JSON** from the `stride-hook.sh` hook script and raw text from the legacy agent-executed flow. Parses compilation errors, test failures, security warnings, credo issues, format failures, and git failures with structured diagnosis per issue. Dispatched automatically when blocking hooks fail during the completion workflow.

## Configuration

Before using Stride skills, you need two configuration files in your project root:

### `.stride_auth.md`

Contains your API credentials (never commit this file):

```markdown
- **API URL:** `https://www.stridelikeaboss.com`
- **API Token:** `your-token-here`
- **User Email:** `your-email@example.com`
```

Beyond authenticating your own API calls, the `after_doing` hook reads this file (v2.13.0+, D54) as the **primary** source for the URL + token of the fire-and-forget `changed_files` snapshot PUT — matching the production `**API Token:**` line, never `**Local API Token:**`, and falling back to credentials parsed from the intercepted completion command. This makes the snapshot upload work even when your completion curl uses `$STRIDE_API_URL` / `$STRIDE_API_TOKEN` shell variables. The token is never logged.

### `.stride.md`

Contains hook scripts that run during the task lifecycle:

```markdown
## before_doing
git pull origin main
mix deps.get

## after_doing
mix test
mix credo --strict

## after_goal
# Optional fifth hook — fires after the parent goal's final child task
# completes. Omit the section entirely for the back-compat no-op path.
./scripts/notify-team.sh "$GOAL_IDENTIFIER" "$GOAL_TITLE"
```

## Automatic Hook Execution

The plugin includes automatic hook execution via `hooks.json`. When installed, Stride API calls made through the Copilot CLI are intercepted and the corresponding `.stride.md` hook commands run automatically.

### How It Works

| Stride API Call | Hook Triggered | Timing |
|----------------|----------------|--------|
| `POST /api/tasks/claim` | `before_doing` | After claim succeeds (PostToolUse) |
| `PATCH /api/tasks/:id/complete` | `after_doing` | Before completion runs (PreToolUse, blocks on failure) |
| `PATCH /api/tasks/:id/complete` | `before_review` (+ `after_goal` if bundled) | After completion succeeds (PostToolUse) |
| `PATCH /api/tasks/:id/mark_reviewed` | `after_review` (+ `after_goal` if bundled) | After review succeeds (PostToolUse) |

**`after_goal` (v2.11.0+):** the server bundles an `after_goal` entry alongside the primary hook in the response of `/complete` or `/mark_reviewed` when the completing task is the final child of a parent goal. The plugin auto-executes the local `## after_goal` section as a blocking hook (60s timeout, same shape as `after_doing`) and emits a structured result on stdout. The agent forwards the result via `PATCH /api/tasks/:goal_id/after_goal` to flip the goal to Done. A missing `## after_goal` section is a clean no-op (back-compat — older `.stride.md` files keep working unmodified). The hook receives `GOAL_ID` / `GOAL_IDENTIFIER` / `GOAL_TITLE` / `GOAL_DESCRIPTION` env vars from the server's `hook.env`, and is general-purpose — Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses, not just PR creation.

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

The cache also records `TASK_BASE_REF` — the commit HEAD captured at claim time, which anchors the `after_doing` per-file diff. This base ref is refreshed on **every** detected claim, including when the claim response is too large for the host to keep inline and is persisted to a file: the hook recovers the API JSON from the "Full output saved to: …" notice (validated as an existing regular file and parsed read-only — never sourced or executed), and even when no JSON is recoverable it still rewrites `TASK_BASE_REF` to the current HEAD (preserving the existing `TASK_` identity lines). This guarantees a stale base ref from a previous claim can never make `changed_files` span unrelated commits.

Add `.stride/` (the orchestrator's runtime-state directory), `.stride_auth.md` (your API token), `.stride-env-cache`, `.stride-changed-files.json`, and `.stride-diff-upload-state` to your `.gitignore` — the last three are temp files written between hook invocations. **(v2.32.0+)** add **`.exploratory/`** too when the `stride-copilot-exploratory-testing` plugin is installed: session artifacts land there, hold transcribed application output, and arrive untracked, so an `## after_doing` section that stages everything (`git add -A`) would commit them (see the Manual & Exploratory Testing section above). `.stride-changed-files.json` holds the per-file diff snapshot; `.stride-diff-upload-state` records the last upload outcome (task id + HTTP code only, never credentials). All three are cleaned up automatically at the claim refresh and after the `after_review` hook. As a backstop, `capture_changed_files` also excludes `.stride-diff-upload-state` and `.stride-changed-files.json` from the snapshot — anchored to the repository root, so a same-named file in a subdirectory of your project is still captured — and the upload path strips them before PUT, so even an untracked or accidentally-committed state file never appears in a task's `changed_files`.

### The `after_doing` time budget

The two Bash hook entries in `hooks/hooks.json` carry a **300-second timeout**. This is the **outer host budget** — a ceiling the host gives the whole `stride-hook` invocation (your `.stride.md` section plus the plugin's own per-file diff snapshot work), not the per-hook limit.

Separately, the executor enforces an **inner per-hook budget** on the `.stride.md` section itself (W1513): `after_doing` = 120s, and `before_doing` / `before_review` / `after_review` / `after_goal` = 60s — the same limits documented in the stride-workflow SKILL Hooks Reference. A section command that exceeds its inner budget is terminated and reported through the standard structured failure JSON (`exit_code: 124`), which for `after_doing` blocks completion just like any other gate failure. Every inner limit sits comfortably under the 300s outer ceiling, so the two never collide. Enforcement uses a `timeout`/`gtimeout` utility; on platforms that ship neither (stock macOS/BSD bash) the inner limits are not enforced and only the 300s outer ceiling applies. (PowerShell always enforces via `WaitForExit`.)

When the budget is exceeded, the hook process is killed. To keep the task's diffs from being lost in that case, the per-file diff snapshot is captured and uploaded **before** the `after_doing` section commands run, then refreshed after all commands succeed. The `before_review` hook (which runs on its own fresh timeout budget) verifies the recorded outcome in `.stride-diff-upload-state` and re-captures + re-uploads when that state is missing, stale (a different task), or non-2xx — a healthy upload is never repeated.

If your project's quality gate runs close to the ceiling, either trim the `.stride.md` `## after_doing` section (move slow steps like a full coverage run into CI) or raise the `timeout` values further in a fork of the plugin.

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
