# Changelog

All notable changes to this project will be documented in this file.

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
