# Changelog

All notable changes to this project will be documented in this file.

## [2.11.0] - 2026-05-22

### Added

- **`## after_goal` hook section** — fifth `.stride.md` hook, fires after the parent goal's final child task completes. Blocking, 60s timeout, same single-bash-fence parsing rule as the four existing hooks. The plugin's `hooks/stride-hook.sh` and `hooks/stride-hook.ps1` now inspect the response payload of `/complete` and `/mark_reviewed` for an `after_goal` entry and execute the local `## after_goal` section as a blocking hook when present. Missing section is a clean no-op (back-compat). Structured failure JSON surfaces on stdout for the agent to forward via `PATCH /api/tasks/:goal_id/after_goal` per the Stride server contract. Implemented as W788 / W789.
- **`GOAL_*` env vars** — `GOAL_ID`, `GOAL_IDENTIFIER`, `GOAL_TITLE`, `GOAL_DESCRIPTION` forwarded by the hook bridge into the `## after_goal` child process environment, sourced verbatim from the server-supplied `hook.env`. `BOARD_*`, `COLUMN_*`, `AGENT_NAME`, and `HOOK_NAME` remain present across all five hooks. The bridge never invents, derives, or looks up these values client-side.
- **`skills/stride-workflow/SKILL.md`** — Step 6 (Execute Hooks) opens with a Hooks Reference table listing all five hooks (timing/blocking/timeout/purpose), followed by a Hook Environment Variables matrix (`TASK_*` vs `GOAL_*` per hook) and a Canonical Hook Examples block. Step 8 (Post-Completion Decision) gains a subsection describing the goal-Done transition triggered by `after_goal` success and the agent's `PATCH /api/tasks/:goal_id/after_goal` POST contract. The examples explicitly note the hook is general-purpose (Slack notifications, artifact archival, release pipelines, project-level smoke tests are all valid uses). Implemented as W791.
- **`hooks/test-stride-hook.sh`** and **`hooks/test-stride-hook.ps1`** — End-to-end test coverage for the new routing (W790). Each harness adds five cases: after_goal present + section present, after_goal present + section absent (back-compat), after_goal absent (unchanged behavior), section command exits non-zero (structured failure JSON on stdout, script exit 0), and mark_reviewed parity with /complete. Bash suite now reports 117/0 (100 prior + 17 new).

### Backward compatibility

A `.stride.md` without a `## after_goal` section continues to work unchanged — the new routing code is a clean no-op for that case. The four existing hook routes (`before_doing` / `after_doing` / `before_review` / `after_review`) produce byte-identical output to v2.10.1 (and prior), empirically confirmed by all 100 pre-existing tests passing unchanged after the parse-and-exec refactor. Older agent runtimes that don't speak the after_goal protocol — including those that don't make the PATCH POST — are covered by the server-side grace-window worker, which promotes the goal after the configured wait expires.

### Migration

Install or update via your normal stride-copilot install flow. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required. To opt into the new hook, add a `## after_goal` section to `.stride.md`. The receiving Stride server must include the `PATCH /api/tasks/:id/after_goal` endpoint and the `after_goal_status` / `after_goal_result` / `after_goal_attempts` columns on the `tasks` table for agent reports to land.

### Source

G164 / W788 (bash routing), W789 (PowerShell mirror), W790 (end-to-end tests), W791 (SKILL.md), W792 (this release). Pattern mirrors the Claude plugin's v1.17.1 release (https://github.com/cheezy/stride/releases/tag/v1.17.1) — the after_goal feature shipped first on the Claude plugin and is being ported to the other Stride agent plugins.

## [2.10.1] - 2026-05-21

### Fixed

- **`skills/stride-completing-tasks/SKILL.md`** — Replaced three occurrences of `"$CLAUDE_PROJECT_DIR/.stride-changed-files.json"` with the defaulted form `"${CLAUDE_PROJECT_DIR:-.}/.stride-changed-files.json"` in the canonical inline-cat pattern. Affected lines: the pre-completion verification checklist item, the canonical `API Request Format` PATCH snippet, and the `Per-File Diff Capture (Optional)` snippet. The inline structure, the `--argjson cf "$(cat ... 2>/dev/null || echo '[]')"` shape, and the binary/truncation contract are unchanged — only the variable expansion is defaulted.

### Why this release

Under Claude Code's TypeScript SDK runtime (the host shape under GitHub Copilot CLI when bridging to Claude Code agents), `$CLAUDE_PROJECT_DIR` is unset/empty, so the bare expansion produced `/.stride-changed-files.json`. The `cat` failed, the `|| echo '[]'` fallback fired, and agents POSTed `changed_files: []` even when the hook had correctly written the snapshot. The defaulted form `${CLAUDE_PROJECT_DIR:-.}` falls back to the current working directory whenever the variable is unset or empty, so the read works under both runtimes.

### Backward compatibility

Wire shape unchanged. Behavior under a non-empty `$CLAUDE_PROJECT_DIR` is byte-identical to v2.10.0. Under the empty-variable shape, agents that follow the canonical SKILL.md pattern now successfully capture the snapshot they were already trying to send.

### Source

Mirrors the stride/ v1.15.1 fix (W767/W768) for the Copilot variant. Implemented as W769 (SKILL.md hotfix) and W770 (release coordination). No marketplace pin update — stride-copilot is not distributed through stride-marketplace.

## [2.10.0] - 2026-05-20

### Changed

- **`hooks/stride-hook.sh`** — `capture_changed_files()` now reflects the agent's full working state at completion time, not just committed history. The function uses `git diff $base` (no `..HEAD`) so committed-since-base, staged-but-uncommitted, AND modified-but-unstaged changes all surface in a single pass, and adds a `git ls-files --others --exclude-standard` pass to enumerate untracked new files. Untracked text files appear as synthesized new-file unified patches (diffed against `/dev/null` via `git diff --no-index --no-color`); untracked binaries are detected via the `Binary files ... differ` sentinel that `--no-index` emits and use the existing binary placeholder string. A path that is both committed-since-base AND further modified in the working tree appears exactly once in the snapshot with a diff that reflects the final working-tree state. The 500-line per-file truncation rule and the `[binary file — no diff captured]` placeholder string are preserved unchanged.
- **`skills/stride-completing-tasks/SKILL.md`** — Three coordinated surface rewrites so agents stop the broken "separate cat then curl" pattern. (1) The canonical "API Request Format" section now leads with a `bash`/`curl` example that inlines the snapshot read via `--argjson cf "$(cat \"$CLAUDE_PROJECT_DIR/.stride-changed-files.json\" 2>/dev/null || echo '[]')"` INSIDE the `jq -n` that builds the curl's `-d` payload — followed by the JSON body shape as an illustrative supplement. The absolute `$CLAUDE_PROJECT_DIR/...` path is used so a non-root agent CWD does not silently miss the file. (2) The Per-File Diff Capture (Optional) section now contains a "Why inline?" paragraph explaining that the PreToolUse-on-complete hook writes the snapshot DURING the curl call, so a separate Bash tool call BEFORE the curl reads the file before the hook populates it. (3) The pre-completion verification checklist item for `changed_files` is rewritten to test for the inline pattern + absolute path explicitly, replacing the older "read it and embed it verbatim" prose. A new "Working-tree semantic (v1.15.0+)" paragraph documents the broadened capture.
- **`hooks/test-stride-hook.sh`** — Test Group 7 grows from 14 cases to 19 cases with 5 new Option D cases (7o-7s): modified-uncommitted tracked file present in snapshot, staged-uncommitted change present, untracked new file appears as synthesized `+++ b/<path>` patch with `+<content>` body, untracked binary file emits the exact binary placeholder, and dedupe — a committed-then-further-modified path appears exactly once with the diff reflecting the final working-tree content. Existing 7i (HEAD~1 fallback), 7j (e2e after_doing), 7k (all-commented after_doing), and 7m (empty diff) fixtures updated to add a `.gitignore` for stride runtime artifacts (`.stride.md`, `.stride-env-cache`, `.stride-changed-files.json`) and to redirect subshell stdout to a sibling temp file rather than to a path inside the test's working directory — both adjustments accommodate the new untracked-file capture without weakening any assertion.
- **`plugin.json`** — Version bumped from `2.9.1` to `2.10.0` (the snapshot semantic broadens; the wire shape is unchanged).

### Why this release

A Copilot CLI task completing without an intermediate commit produced an empty `.stride-changed-files.json`. Same root cause as stride 1.15.0: (a) `capture_changed_files()` was anchored to `<base>..HEAD`, so working-tree-only changes were invisible; (b) the canonical SKILL.md example read the snapshot in a separate Bash tool call BEFORE the curl, which means the PreToolUse-on-complete hook had not yet populated the file at read time. This release mirrors the stride 1.15.0 fix into stride-copilot — the snapshot now reflects the agent's working state regardless of commit state, and the canonical example inlines the snapshot read inside the curl invocation so the read happens AFTER the hook fires.

### Backward compatibility

The wire shape of `changed_files` is unchanged — same `path` + `diff` keys, same 500-line truncation rule, same binary placeholder string. Completion payloads that omit `changed_files` entirely continue to validate (the empty-array form produced by the inline `|| echo '[]'` fallback is also valid). Reviewers consuming the field see additional content under the new semantic — uncommitted edits and untracked new files now appear in `/review` whereas previously they were silently dropped.

### Source

Mirrors stride 1.15.0 (G157/W758) into stride-copilot. Delivered in copilot as W759 (combined SKILL.md + hook + tests + release). No marketplace coordination — stride-copilot ships by tag directly.

## [2.9.1] - 2026-05-20

### Changed

- **`skills/stride-completing-tasks/SKILL.md`** — Closes the canonical-example/checklist gap left behind by 2.9.0 (W729). 2.9.0 added the dedicated `## Per-File Diff Capture (Optional)` section, but the canonical API Request Format example body and the pre-completion verification checklist still omitted `changed_files`, so agents copying from the canonical example never reached the Optional section and never embedded `.stride-changed-files.json` into their completion payload. This release adds (a) `actual_files_changed` + `changed_files` to the canonical example body with a one-entry unified-patch diff, (b) the verification checklist item `Did you embed \`.stride-changed-files.json\` into the payload as \`changed_files\`?`, and (c) the `**Optional:** Include changed_files...` paragraph after the `**Critical:**` line linking to `docs/diff-contract.md`. The W729-authored `## Per-File Diff Capture (Optional)` section is preserved intact as the encoding-rules anchor.
- **`plugin.json`** — Version bumped from `2.9.0` to `2.9.1`.

### Source

Mirrors stride 1.14.1 (G155/W748) into stride-copilot for cross-plugin parity. Delivered in copilot as W755 (canonical-example + checklist edit) and W757 (this release).

## [2.9.0] - 2026-05-20

### Added

- **`hooks/stride-hook.sh`** — Added `capture_changed_files()` per the G148/W719 contract: emits a JSON array of `{path, diff}` entries for every file changed between `$TASK_BASE_REF` and `HEAD`, truncates diffs over 500 lines with the marker `[diff truncated at 500 lines]`, and emits `[binary file — no diff captured]` for files git reports as binary in `--numstat`. Falls back to `HEAD~1` when the base ref is empty or unresolvable; returns `[]` for any degraded path (jq missing, git missing, not in a repo, no commits to diff). The function is defined above the early-exit guards so the test suite can `source` the script to call it in isolation.
- **`hooks/stride-hook.sh`** — Added `TASK_BASE_REF` (captured via `git rev-parse HEAD` at `before_doing` time) to the `.stride-env-cache` writer so `capture_changed_files` has an anchor when `after_doing` fires.
- **`hooks/stride-hook.sh`** — Added `finalize_after_doing()` helper and wired it to all three `after_doing` exit points (no-commands branch, all-comments-filtered branch, and post-command-loop). The helper writes the JSON array to `$CLAUDE_PROJECT_DIR/.stride-changed-files.json`.
- **`hooks/stride-hook.sh`** — Added stale-snapshot cleanup on `before_doing` (`rm -f .stride-changed-files.json`) and lifecycle cleanup on `after_review` (removes both `.stride-env-cache` and `.stride-changed-files.json`).
- **`hooks/test-stride-hook.sh`** — Added Test Group 7 (22 cases, 7a–7n) covering truncation thresholds (7a 500-line preserved, 7b 750-line truncated with marker as last line, 7c empty stays empty), binary detection (7d numstat `- -` row, 7e text row not flagged, 7f missing file not flagged), real-git integration against a temp repo with text + binary + deleted entries (7g), non-repo fallback (7h), empty-base fallback to `HEAD~1` (7i), end-to-end `after_doing` snapshot write (7j), all-commented `after_doing` path (7k), legacy-bypass guarantee — `before_review` preserves a pre-seeded stale snapshot (7l), empty changed-files list (7m), and null-byte binary file detection (7n). Suite now reports 91 passed / 0 failed (up from 69).
- **`skills/stride-completing-tasks/SKILL.md`** — Added the `changed_files` row to the Completion Request Field Reference table and a new "Per-File Diff Capture (Optional)" section. The section cites the canonical [`docs/diff-contract.md`](https://raw.githubusercontent.com/cheezy/kanban/refs/heads/main/docs/diff-contract.md) for the field shape, truncation marker, binary placeholder, and 500-line inclusive cap. It documents the snapshot lifecycle (refreshed on every `after_doing`, cleaned up on `after_review`), the `cat .stride-changed-files.json 2>/dev/null || printf '[]'` read pattern, and the explicit backward-compatibility rule that absent snapshots must produce completions that omit the field entirely (no synthesized diffs).

### Changed

- **`hooks/stride-hook.sh`** — Rewrote the bare `exit 0` early-exit guards as `return 0 2>/dev/null || exit 0` so the test suite can `source` the script to drive `capture_changed_files` in isolation. The guards now sit immediately after the function definition and behave identically when the script is executed normally.
- **`plugin.json`** — Version bumped from `2.8.0` to `2.9.0`.

### Source

Ported from stride 1.14.0 (commits `7b95b4a` "Add per-file diff capture for completion payloads (W725)" and `07d15d8` "Document optional changed_files completion field (W726)", released as `v1.14.0`). Cross-plugin parity for Stride G148 / W719. Delivered in copilot as W729 (capture + tests + docs) and W730 (test coverage acknowledgment).

## [2.8.0] - 2026-05-19

### Changed

- **`agents/task-reviewer.agent.md`** — Rewrote Step 6 ("Return Structured Review") and the Output persistence paragraph to require an unconditional fenced ```json block alongside the existing markdown prose. The block matches the canonical `reviewer_result` schema documented in [`stride/agents/task-reviewer.md`](https://github.com/cheezy/stride/blob/main/agents/task-reviewer.md) — `schema_version`, `summary`, `status`, `issue_counts`, `issues[]` (with `severity`/`category` enums), and `acceptance_criteria[]` (with `met`/`not_met` enum). Includes a verbatim worked `changes_requested` example. The prose summary line is preserved above the JSON block so orchestrator fallback paths that grep substring summaries continue to work when JSON parsing fails. No copilot-specific schema variant introduced — the canonical schema is cited by path.
- **`skills/stride-subagent-workflow/SKILL.md`** — Added an "Extracting the structured review block" subsection to Phase 3 (Code Review). The orchestrator now extracts the first fenced ```json fence from the reviewer's response and populates `reviewer_result` in the completion PATCH payload with both (a) the legacy summary fields (`summary`, `issues_found` from `sum(issue_counts.values())`, `acceptance_criteria_checked` from the length of the structured array) and (b) the structured fields verbatim (`status`, `issue_counts`, `issues`, `acceptance_criteria`, `schema_version`). Includes a worked example and a documented fallback path that keeps older agent versions and parse failures working: substring-match the prose summary, omit structured fields from the PATCH (never empty placeholders), do not abort the completion.
- **`plugin.json`** — Version bumped from `2.7.0` to `2.8.0`.

### Source

Ported from stride 1.13.0 (commits 9c19359 "Define structured JSON review-report schema in task-reviewer agent" and 8e94eca "Extract structured review block into reviewer_result PATCH payload"). Cross-plugin parity for Stride W685/W686 (implemented in stride-copilot as W694).

## [2.7.0] - 2026-05-06

### Added

- **`agents/task-enricher.agent.md`** — New custom agent that owns the four-phase enrichment procedure (intent parse, codebase exploration, complexity heuristic, 16-item validation checklist). Receives sparse task fields from the orchestrator and returns a single enriched-task JSON object ready for `PATCH /api/tasks/:id`. Ported from stride 1.11.0 (`stride/agents/task-enricher.md`) with Copilot-specific frontmatter (`tools: ["read", "search", "glob"]`, no `model` field, `.agent.md` filename suffix). The body is platform-neutral.

### Changed

- **`skills/stride-enriching-tasks/SKILL.md`** — Slimmed from 776 lines to 264 lines. The four-phase manual enrichment procedure now lives in `agents/task-enricher.agent.md`. The skill retains the STOP preamble, MANDATORY warning, API Authorization block, Iron Law, API integration curl examples, and output example, but the Copilot CLI path now invokes `task-enricher` instead of walking the procedure inline. Other environments still follow the condensed manual walkthrough phases (Phases 1-4 retained in summary form, with the 16-item Phase 4 checklist preserved verbatim).
- **`skills/stride-subagent-workflow/SKILL.md`** — Added `task-enricher` to the agent inventory in the MANDATORY teaser block. Added a new `## Pre-Claim: Enrichment (Sparse Tasks)` section documenting when and how to invoke the enricher before claiming a task. Added `task-enricher.agent.md` to the Quick Reference Card and References section. Updated the frontmatter `description:` to enumerate `task-enricher` alongside the other custom agents.
- **`skills/stride-workflow/SKILL.md`** — Step 1 enrichment check expanded into two platform subsections: `#### Copilot CLI: Invoke the Enricher Agent` (3-step dispatch + PATCH flow) and `#### Other Environments: Activate the Enrichment Skill` (manual-phase fallback). Matches the stride 1.11.0 platform-split pattern.
- **`plugin.json`** — Version bumped from `2.6.0` to `2.7.0`.

### Source

Ported from stride 1.11.0 (commit 92b72ea). Cross-plugin parity goal G86 / W348.

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
