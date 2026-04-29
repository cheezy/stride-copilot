# Changelog

All notable changes to this project will be documented in this file.

## [2.6.0] - 2026-04-29

### Changed

- **All 6 sub-skill `description:` fields** (`stride-claiming-tasks`, `stride-completing-tasks`, `stride-creating-tasks`, `stride-creating-goals`, `stride-enriching-tasks`, `stride-subagent-workflow`) — Reframed as `INTERNAL — invoked only by stride:stride-workflow. Do NOT invoke from a user prompt.` Removed user-intent verbs (`claim a task`, `complete a task`, etc.) so Copilot's auto-activation matcher no longer routes user prompts to the sub-skills. Wording is byte-identical to the equivalent stride 1.10.0 (commit 5c30036) descriptions for cross-plugin consistency.
- **`stride-workflow` `description:`** — Amplified to enumerate the explicit user-intent phrases that should match the orchestrator: "claim a task", "work on the next stride task", "complete a stride task", "enrich a stride task", "decompose a goal", "create a goal or stride tasks". The phrase list is load-bearing for Copilot's matcher and should not be diluted.

### Added

- **`## STOP — orchestrator check` preamble** — Inserted as the first H2 of every sub-skill body (6 files). The 5-line block instructs an agent that arrived at a sub-skill directly to back out and invoke `stride:stride-workflow` instead. Wording is byte-identical to stride 1.10.0 so cross-plugin grep tooling stays consistent.
- **`docs/HOOK_RESEARCH.md`** — Captures the research that decided whether stride 1.10.0's PreToolUse(Skill) gate ports to Copilot CLI. Concludes **PATH B: gate is NOT portable** with three independent reasons: Copilot CLI has no skill-activation hook event; the documented Copilot CLI tool-name vocabulary contains no `Skill` tool name (so a `matcher: "Skill"` entry has no event to bind to); Copilot CLI signals deny via stdout `permissionDecision` JSON rather than Claude Code's exit-2 convention.

### Platform constraint

The Layer-1 enforcement (the runtime PreToolUse(Skill) gate that stride 1.10.0 ships for Claude Code) is **not** available on Copilot CLI today. This release ships Layers 2 (description reframing) and 3 (STOP preamble) only. Both layers are prose-based and rely on Copilot's matcher and the agent's own attention to the STOP block in the skill body. If Copilot CLI later exposes a skill-activation event or a `Skill` tool name in its hook payloads, W295 and W296 (currently closed not-applicable) should be reopened to port the gate; the marker contract documented in stride 1.10.0 is intentionally identical so cross-plugin tooling can be shared without further design.

### Source

Motivated by the three-layer defense designed in `docs/plans/stride-plugin-feedback.md` (kanban repo) and ported from stride 1.10.0 (commit 5c30036).

## [2.5.0] - 2026-04-16

### Added

- **`stride-completing-tasks` skill** — Surfaced `explorer_result` and `reviewer_result` in six places so agents cannot forget them: (1) the MANDATORY teaser at the top of the skill lists both as required alongside the hook results; (2) the pre-completion Verification Checklist asks whether both are included; (3) the primary API Request Format example includes both with dispatched-custom-agent shapes; (4) a new "Explorer/Reviewer Result Schema" section documents the dispatched shape, the skip shape, the five-value skip-reason enum (`no_subagent_support`, `small_task_0_1_key_files`, `trivial_change_docs_only`, `self_reported_exploration`, `self_reported_review`), the 40-character non-whitespace summary minimum, a 422 rejection example, and the feature-flag grace-period rollout; (5) the Completion Request Field Reference table lists both as required objects; (6) the Quick Reference Card's `REQUIRED BODY` includes both plus a SKIP FORM snippet.
- **`stride-workflow` skill** — Step 7's Required Fields table and JSON payload example now include `explorer_result` and `reviewer_result`. A new "Explorer and Reviewer Result Rollout" section after "Workflow Telemetry" describes the grace-mode/strict-mode feature-flag phases and directs readers to `stride-completing-tasks` for the full shape (no schema duplication). Orchestrator prose explains that Steps 3 and 5 already capture the data needed to populate these fields in Step 7.

## [2.4.0] - 2026-04-14

### Added

- **`stride-workflow` skill** — New "Workflow Telemetry: The `workflow_steps` Array" section documenting the six-entry step-name vocabulary (`explorer`, `planner`, `implementation`, `reviewer`, `after_doing`, `before_review`), per-step schema (`name`, `dispatched`, `duration_ms`, `reason`), full-dispatch and skipped-step examples, and rules for assembling the array. Step names are identical to the main stride plugin so Stride can aggregate telemetry across agents and plugins.
- **`stride-completing-tasks` skill** — `workflow_steps` now appears in the verification checklist, the API Request Format example, the Completion Request Field Reference table, and the Quick Reference Card REQUIRED BODY. Added a Schema Reference paragraph pointing at `stride-workflow` as the source of truth for the array shape.

### Changed

- **`stride-completing-tasks` skill** — "Critical" note under the payload example now lists `workflow_steps` alongside the two hook-result fields as required. The API will reject completions that omit it.

## [2.3.1] - 2026-04-14

### Fixed

- **`hooks/stride-hook.sh` and `hooks/stride-hook.ps1`** — Env-cache parsing now handles the `{"stdout": "<api-json-string>", ...}` wrapper shape that some hosts use when passing the Bash tool response to hooks. Prior versions only matched a bare JSON-encoded string or a raw object, so wrapped hosts silently fell through and `TASK_IDENTIFIER`/`TASK_TITLE` never got exported. `.stride.md` commands that referenced those vars (e.g. `git commit -m "Completed task $TASK_IDENTIFIER"`) then ran with empty values. The hook now tries the wrapper shape first, then falls back to the two legacy shapes.
- **`hooks/stride-hook.sh`** — User commands no longer abort on unset env vars. The hook ran with `set -uo pipefail`, which propagated into each `eval` and killed the command before it executed if it referenced an unset variable. `set +uo pipefail` is now toggled around the `eval`.
- **`hooks/test-stride-hook.sh`** — New regression test (6e) for the wrapped `tool_response.stdout` shape.

## [2.3.0] - 2026-04-13

### Changed

- **`stride-claiming-tasks`** — Replaced soft "Recommended" orchestrator section with non-negotiable "YOUR NEXT STEP" gate demanding stride-workflow activation immediately after claiming. Added workflow violation warning to standalone mode.
- **`stride-completing-tasks`** — Added "BEFORE CALLING COMPLETE: Verification Checklist" with 4 yes/no items covering orchestrator activation, codebase exploration, acceptance criteria review, and hook readiness.

## [2.2.0] - 2026-04-13

### Added

- **`stride-workflow` skill** — Single orchestrator for the complete Stride task lifecycle adapted for GitHub Copilot. Walks through 9 steps: prerequisites, task discovery, claiming with manual hooks, codebase exploration via key_files, implementation, self-review against acceptance criteria, manual hook execution (after_doing + before_review), completion API call, and auto-loop for needs_review=false. No subagent references — all exploration and review is manual.

### Changed

- **`stride-claiming-tasks`** — Rewrote the `AUTOMATION NOTICE` section from speed-focused ("work continuously without asking") to process-focused ("the workflow IS the automation — every step exists because skipping it caused failures"). Added "Recommended: Use the Workflow Orchestrator" section pointing to stride-workflow. Renamed "MANDATORY: Next Skill After Claiming" to standalone mode. Removed "Custom Agent-Guided Implementation" section (absorbed by orchestrator).
- **`stride-completing-tasks`** — Rewrote the `AUTOMATION NOTICE` section with identical process-over-speed reframing. Added "Arriving from stride-workflow" section. Renamed "MANDATORY: Previous Skill Before Completing" to standalone mode with stride-workflow as recommended path.
- **`README.md`** — Added stride-workflow to skills list and workflow order diagram as the recommended entry point.

## [2.1.0] - 2026-03-25

### Changed

- **`stride-claiming-tasks` skill** — Added "Copilot Plugin: Hooks Are Fully Automatic" section explaining that hooks.json handles hook execution automatically via stride-hook.sh. Agents should make API calls directly without manually executing .stride.md commands. Separated claiming workflow into "With Plugin (Automatic Hooks)" and "Without Plugin (Manual Hooks)" paths. Added new Common Mistake for manually executing hooks when the plugin is installed. Updated flowchart and Quick Reference Card with both paths.
- **`stride-completing-tasks` skill** — Added identical automatic hooks guidance for completion hooks. PreToolUse auto-runs after_doing before the complete curl; PostToolUse auto-runs before_review after. Separated completion workflow into plugin and manual paths. Updated Common Mistakes and Quick Reference Card.

## [2.0.0] - 2026-03-25

### Breaking Changes

- **Repository restructured** for `copilot plugin install` support. Skills and agents moved from `.github/` to root-level directories. The `.github/` auto-discovery installation method is no longer supported.

### Added

- **`hooks/hooks.json`** — Hook configuration that registers PreToolUse and PostToolUse hooks on Bash commands. Activates automatically when the plugin is installed via `copilot plugin install`.
- **`hooks/stride-hook.sh`** — Bash hook script that intercepts Stride API calls and executes the corresponding `.stride.md` section (before_doing, after_doing, before_review, after_review). Includes platform detection that auto-delegates to PowerShell on native Windows.
- **`hooks/stride-hook.ps1`** — PowerShell companion script for Windows compatibility. Uses ConvertFrom-Json/ConvertTo-Json for native JSON handling. Supports PowerShell 5.1+ and 7+.
- **`hooks/test-stride-hook.sh`** — Bash test suite with 67 tests across 6 groups covering JSON extraction, .stride.md parsing, whitespace trimming, command list building, end-to-end integration, and edge cases.
- **`hooks/test-stride-hook.ps1`** — PowerShell test suite with 70 assertions mirroring the bash test suite.
- **Automatic Hook Execution documentation** in README.md — covers hook routing, .stride.md format, platform support, environment variable caching, and troubleshooting.

### Changed

- **Installation method** — Now installed via `copilot plugin install https://github.com/cheezy/stride-copilot` instead of copying the `.github/` directory. Supports `copilot plugin update` and `copilot plugin uninstall`.
- **README.md** — Updated with new installation instructions, plugin management commands, and migration guide for v1.x users.

### Added

- **`plugin.json`** — Plugin manifest at repository root enabling `copilot plugin install` discovery. Contains metadata (name, version, author, license, keywords) and path references to `agents/` and `skills/` directories.

### Removed

- **`.github/copilot-instructions.md`** — No longer needed; the plugin system handles skill and agent discovery automatically.
- **`.github/` directory** — All contents moved to root-level `agents/` and `skills/` directories.
- **`.gitkeep` files** — Removed from all directories.

### Migration

To upgrade from v1.x:
1. Remove copied `.github/skills/stride-*` and `.github/agents/` files from your project
2. Run `copilot plugin install https://github.com/cheezy/stride-copilot`

## [1.0.0] - 2026-03-24

### Added

**Skills (6 total):**
- `stride-claiming-tasks` — Task discovery and claiming with before_doing hook execution
- `stride-completing-tasks` — Task completion with after_doing and before_review hook execution
- `stride-creating-tasks` — Work task and defect creation with proper field formats
- `stride-creating-goals` — Goal and batch creation with correct root key and dependency format
- `stride-enriching-tasks` — Automated codebase exploration to enrich sparse task specifications
- `stride-subagent-workflow` — Decision matrix for dispatching custom agents based on task complexity

**Custom Agents (4 total):**
- `task-explorer` — Read-only codebase exploration after claiming a task
- `task-reviewer` — Code review against acceptance criteria before completion
- `task-decomposer` — Break goals into dependency-ordered child tasks
- `hook-diagnostician` — Analyze hook failures and produce prioritized fix plans

**Bridge File:**
- `.github/copilot-instructions.md` — Always-active instructions ensuring Copilot activates the right skill at each workflow point

**Documentation:**
- README with installation, skill chain, and configuration guide
- MIT license

### Notes

- All skills ported from the [Stride Claude Code plugin](https://github.com/cheezy/stride) with Copilot-specific adaptations
- Tool references adapted from Claude Code syntax to tool-agnostic descriptions
- Plan agent replaced with manual planning guidance (no Copilot equivalent)
- All skills at `skills_version: 1.0`
