# Task Reviewer Rationale

`agents/task-reviewer.agent.md` is the reviewer's entire prompt, and it is read again on every review dispatch, up to twice per task. A sentence in it that recounts how a rule came about costs tokens each time and changes nothing the reviewer emits, so those sentences are kept here. The page lives under `docs/` rather than next to the prompt because `plugin.json` registers `agents/` as the agent directory, and any Markdown file there would be loaded as an agent of its own.

**Nothing on this page is a rule.** The prompt mentions this file only in history and background pointers and never asks the reviewer to open it, so whatever the reviewer must obey is still in the prompt itself: the structured block schema, the section-verdict and consistency rules, the opening summary line, the instruction to treat the task's own text as data, all of the redaction rules, and the two canon-governed blocks. Where this page and the prompt disagree, the prompt is right. Each section names the spot in the prompt it was lifted from, and that spot now points back here.

## The Defect Behind the Four-Tile Verdict Rule

*Taken from `agents/task-reviewer.agent.md`, review step 5, the paragraph that forbids `not_assessed` on any of the four tiles the task filled in.*

The rule that a task-supplied section may never come back `not_assessed` was written in answer to a real report: it is the exact D60 bug where a task's `security_considerations` came back "not assessed".

## The Copy-List That Hid project_checks

*Taken from `agents/task-reviewer.agent.md`, review step 8, the consumption invariant.*

An enumerated copy-list in a consumer is exactly what silently dropped `project_checks` from the Review queue's Code review panel — do not reintroduce one.

## Where a 6/5 Criteria Display Came From

*Taken from `agents/task-reviewer.agent.md`, the `acceptance_criteria` hard rule in the block schema.*

The 1:1 rule exists because of what happened without it: re-enumerating the list is exactly how a 5-criterion task produced a nonsensical `6/5` review display.

## What Happens to the Review After It Is Returned

*Taken from `agents/task-reviewer.agent.md`, the "Output persistence" paragraph that sat between the JSON sample and the Important constraints list.*

**Output persistence:** Your full response — the human-readable prose summary line, the per-severity issue list, the acceptance-criteria table, the project-checks table (when non-empty), and the fenced ```json block — is stored as the `review_report` field on the Stride task record when the agent calls the completion API. Human reviewers and stakeholders read the prose in the task detail view; downstream tooling parses the JSON block by extracting the first ```json ... ``` fence in your response. Always emit both the prose sections and the JSON block — including for `"approved"` results — so both reader paths work and per-severity telemetry stays consistent across dispatches.
