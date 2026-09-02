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

---

# Addendum (W2148): the `agentStop` contract and the registration shape

Scope note: everything above this line is the **skill-gate** research, and its
conclusions about `preToolUse` stand unchanged. This addendum answers a
different question — how a **turn-end** gate refuses on Copilot — and exists
because the two questions have different answers that were being read as one
contradiction.

Sources fetched **2026-09-01**:

- <https://docs.github.com/en/copilot/reference/hooks-reference>
- <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks>

## 1. The two stdout contracts are both correct, for different events

The finding above that "Copilot CLI uses stdout `permissionDecision` JSON for
denial, not Claude Code's exit-2 convention" is **scoped to `preToolUse` /
permission requests**, and remains accurate there.

`agentStop` is a different event with a different contract:

```
{ decision: "block" | "allow", reason: string }
```

with `"block"` forcing another agent turn using `reason` as the prompt. So
`decision`/`reason` and `permissionDecision`/`permissionDecisionReason` are not
a contradiction and neither source is stale — they describe different events.
`stride-stop-gate.sh` emits **exactly two keys**, `decision` and `reason`, and
deliberately does not hedge by also emitting the permission pair: a foreign key
invites a strict-parser rejection whose failure mode is silently *allowing* the
stop, and `permissionDecision` has no defined meaning on `agentStop`.

## 2. Exit 2 does not refuse on `agentStop` — the whole reason W2148 was scoped separately

On `agentStop`, a non-zero exit is **logged and skipped**; exit 2 is a warning.
Exit 2 denies only for `preToolUse` / permission requests. A gate ported
unchanged from Claude Code — where exit 2 *does* block — would therefore log its
refusal on every turn end and let the session finish anyway, with no error and
nothing to distinguish it from a gate that correctly found no work. No code path
in `stride-stop-gate.sh` or `.ps1` exits 2.

## 3. Runaway guard and `stop_hook_active`

Verbatim: *"After 8 consecutive `block` continuations, the CLI overrides the
hook and ends the turn anyway, to prevent an unbounded loop."* The `agentStop`
input payload carries `stop_hook_active` — true when the turn was already forced
to continue by a prior `block` from this hook — and the docs advise using it to
self-limit before hitting the cap.

The gate's own default budget is **2**, so it always yields three turn-ends
before the runtime override could fire. The cap is a backstop that is never
reached in normal operation; the gate's persisted counter is the guarantee, and
`stop_hook_active` is honoured as a cheap short-circuit rather than depended on.

## 4. Event names

`agentStop` (camelCase) with `Stop` as the documented PascalCase, VS Code
compatible alias. Both name the same event. `hooks.json` registers **`Stop`
only** — a loader honouring both spellings would double-fire the gate and
double-spend its block budget.

## 5. The registration shape — VERIFIED IN PART, and the gap is real

This is acceptance criterion 6 of W2148, and it is honestly only partly met.

**Verified (structural).** `hooks.json` is well-formed JSON; the `Stop` key
exists exactly once; its single entry carries no `matcher` (Stop is not
tool-scoped); its command resolves to `stride-stop-gate.sh`, which exists and is
executable; the `.ps1` is not separately registered; and the pre-existing
`PreToolUse` / `PostToolUse` entries still parse. Asserted by test 22n.

**Verified (documentary).** `Stop` is a documented event alias, and the
`decision`/`reason` contract, the exit-2 semantics, the 8-block cap and
`stop_hook_active` are all quoted above from the live reference.

**NOT verified (runtime).** That a live Copilot **parses this nested shape** for
`Stop`. The published hooks-file schema is a different, **flat** one:

```json
{"version":1,"hooks":{"agentStop":[{"type":"command","bash":"...","powershell":"...","timeoutSec":10}]}}
```

— no `matcher`, no inner `hooks` array, `bash`/`powershell` rather than
`command`, `timeoutSec` rather than `timeout`, and a required `"version": 1`.
But that schema governs `.github/hooks/NAME.json` and `~/.copilot/hooks/`,
whereas `hooks/hooks.json` is reached through **`plugin.json`'s `"hooks"`
pointer** — the plugin loader, whose schema GitHub does not publish. The two are
different files read by different loaders, which is why the flat schema does not
by itself refute the nested one.

**Two corroborations were considered and BOTH are weaker than they first look.
Neither is offered as evidence; they are recorded here so nobody re-derives
them and mistakes them for support.**

- *The Copilot CLI v1.0.36 release note* — "Fixed an issue where
  `preToolUse.matcher` was ignored" — quoted at line 41 of this document, in
  the pre-addendum skill-gate research. It presupposes that a matcher-bearing
  entry is parsed, but it names **`preToolUse` in camelCase**, which is the
  *published flat schema's* event spelling. It therefore says nothing about the
  nested **PascalCase** form used here.
- *This port's own `PreToolUse` / `PostToolUse` entries.* These corroborate
  only if they are themselves known to fire, and **nothing in this repository
  establishes that.** Treating them as evidence is circular.

So the honest position is that the nested form is **uncorroborated**, not
merely unverified at runtime. It is shipped because it is the shape the rest of
this plugin already uses and changing it would be an equally unverified guess,
not because evidence favours it.

**A registration that fails to parse is indistinguishable from a gate with
nothing to do.** If the gate never fires, the fix is one of: replace the `Stop`
entry with the flat form above, or rename the key to `agentStop`. Settling it
requires a live Copilot restart; the test suite invokes the gate script
directly and structurally cannot.
