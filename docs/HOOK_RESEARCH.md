# Copilot Hook Research — Skill-Gate Portability

Research target: decide whether stride 1.10.0's PreToolUse(Skill) gate
(`stride-skill-gate.sh` + matcher `"Skill"`) ports to GitHub Copilot CLI.

## Sources consulted

- GitHub Copilot CLI hook configuration reference: <https://docs.github.com/en/copilot/reference/hooks-configuration>
- Using hooks with Copilot CLI (how-to): <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks>
- Copilot CLI hooks tutorial (deny example): <https://docs.github.com/en/copilot/tutorials/copilot-cli-hooks>
- Adding agent skills for Copilot CLI: <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills>
- Copilot agent plugins (VS Code): <https://code.visualstudio.com/docs/copilot/customization/agent-plugins>
- copilot-cli release notes: <https://github.com/github/copilot-cli/releases>
- Local: `stride-copilot/hooks/hooks.json`, `stride-copilot/hooks/stride-hook.sh`
- Reference: `stride/hooks/hooks.json`, `stride/hooks/stride-skill-gate.sh` (the gate this task is evaluating)

## Findings

### 1. Hook events Copilot CLI supports

Per the hooks-configuration reference, Copilot CLI exposes six lifecycle hooks:

- `sessionStart`
- `sessionEnd`
- `userPromptSubmitted`
- `preToolUse`
- `postToolUse`
- `errorOccurred`

There is **no** dedicated "skill activated" / "before skill" event. Skills are
either auto-selected by the agent based on description matching or invoked
explicitly via `/skill-name` slash commands; in both cases what subsequently
fires `preToolUse` is the agent's underlying tool calls (bash, edit, view,
create…), not the skill activation itself.

### 2. `matcher` support and tool-name vocabulary

- VS Code's Copilot integration parses Claude Code's `hooks.json` format for
  compatibility but **currently ignores `matcher` values** — every PreToolUse
  hook fires on every PreToolUse event regardless of matcher.
- The Copilot CLI **honors `matcher`** as of release v1.0.36
  ("Fixed an issue where preToolUse.matcher was ignored. After upgrade, hooks
  with matcher run only for tool names that fully match the regex.").
- Documented tool names that appear in Copilot CLI hook payloads:
  - `bash`
  - `edit`
  - `view`
  - `create`
  - MCP server tools (names defined by each MCP server)
- **No documented `Skill` / `skill` / `ActivateSkill` tool name** appears in
  Copilot CLI's hook payloads. Skill activation is not modeled as a tool call,
  so a matcher of `"Skill"` (or any equivalent) has no event to bind to.

### 3. Hook stdin JSON shape

`preToolUse` input fields documented for Copilot CLI:

- `toolName` — string, e.g. `"bash"`, `"edit"`
- `toolArgs` — JSON-encoded **string** of the tool's arguments
- `timestamp` — Unix milliseconds
- `cwd` — current working directory

Compare to Claude Code's `tool_input` object containing the literal arguments
(e.g. `tool_input.skill` for the Skill tool). The shapes differ in field
casing (camelCase vs snake_case) and arg encoding (string vs object), so even
if a "Skill" tool name existed, the gate's argument-extraction logic
(`jq -r '.tool_input.skill'`) would not work unmodified.

### 4. Block / deny semantics

Copilot CLI hooks block by writing JSON on stdout:

```json
{"permissionDecision": "deny", "permissionDecisionReason": "..."}
```

Currently, only `"deny"` is processed (the docs note `"allow"` and `"ask"`
are reserved but not yet honored). Exit-code semantics are not documented as
an alternative blocking signal — the canonical path is the stdout JSON.

This contrasts with Claude Code's PreToolUse contract, which the gate uses:
**exit 2 + structured JSON on stdout** to block. The two contracts are not
interchangeable; a port would have to switch from `exit 2` to writing the
`permissionDecision: deny` JSON and `exit 0`.

## Decision

**PATH B: gate is NOT portable.**

Three independent reasons, any one of which is sufficient:

1. **No skill-invocation tool event exists in Copilot CLI.** Skills are
   activated via slash command or description match; the resulting
   `preToolUse` events fire on the underlying tools (bash, edit, etc.), not on
   skill activation. There is no event the gate can intercept to enforce
   "block direct sub-skill calls."
2. **No `Skill` tool name in the documented Copilot CLI tool vocabulary.**
   Even if matcher filtering is now honored in the CLI, there is no tool name
   to match against.
3. **Hook contract differs.** Copilot CLI uses stdout `permissionDecision`
   JSON for denial, not Claude Code's exit-2 convention. A direct script port
   would require rewriting the block path, but reasons 1 and 2 mean there is
   no event to block in the first place.

## What stays in effect on Copilot

Layers 2 and 3 of the three-layer defense from stride 1.10.0 are independent
of the runtime and remain enforceable on Copilot:

- **Layer 2 — description reframing (W293 in this goal):** Sub-skill
  `description:` fields begin with
  "INTERNAL — invoked only by stride:stride-workflow. Do NOT invoke from a
  user prompt." Copilot's auto-activation matcher reads description text, so
  the INTERNAL marker plus removal of user-intent verbs steers the matcher
  toward `stride-workflow` for user prompts.
- **Layer 3 — `## STOP — orchestrator check` preamble (W292 in this goal):**
  First H2 of every sub-skill body tells the agent to back out and invoke
  `stride:stride-workflow` instead. Free, prose-only, requires no runtime
  hook support.

## Implication for downstream tasks

The follow-on tasks in goal G1825 that proposed implementing/registering a
Copilot port of `stride-skill-gate.sh` should be **skipped** (or repurposed as
documentation tasks). The CHANGELOG for the next stride-copilot release
should explicitly state that Layer 1 (the runtime gate) is not available on
Copilot CLI today, and that enforcement relies on Layers 2 and 3. If Copilot
CLI later adds either a skill-activation event or a documented "Skill" tool
name, this decision should be revisited.
