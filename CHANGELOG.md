# Changelog

All notable changes to this project will be documented in this file.

## [2.0.0] - 2026-03-25

### Breaking Changes

- **Repository restructured** for `copilot plugin install` support. Skills and agents moved from `.github/` to root-level directories. The `.github/` auto-discovery installation method is no longer supported.

### Changed

- **Installation method** — Now installed via `copilot plugin install cheezy/stride-copilot` instead of copying the `.github/` directory. Supports `copilot plugin update` and `copilot plugin uninstall`.
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
2. Run `copilot plugin install cheezy/stride-copilot`

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
