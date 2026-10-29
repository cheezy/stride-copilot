# Completion Skill Rationale

`skills/stride-completing-tasks/SKILL.md` is loaded whole each time an agent gets ready to call `/complete`. A paragraph there that makes the case for a step, or tells the story of how one arrived, costs the same tokens on each of those loads and alters nothing in the payload, so such paragraphs now live on this page. A passage that only repeated something the skill already says elsewhere was deleted rather than moved, and the skill names where its surviving copy lives.

**Nothing on this page is a rule.** Should the two drift apart, the skill wins, and no completion ever depends on reading this file. Each section below starts by naming the spot in the skill it was lifted from, and that spot now carries a one-line pointer to the section.

## Fields Discovered One Rejection at a Time

*Taken from `skills/stride-completing-tasks/SKILL.md`, the paragraph under the required-field list in "THIS SKILL IS MANDATORY".*

**Attempting to complete a task from memory without this skill results in 3+ failed API calls** as you discover each missing field one at a time. This has been observed in practice.

## The Steps Agents Dropped Under Pressure

*Taken from `skills/stride-completing-tasks/SKILL.md`, the closing paragraph of "BEFORE CALLING COMPLETE: Verification Checklist".*

This checklist exists because agents consistently skipped these steps under pressure to deliver quickly.

## A Summary Line for Servers That Drop the Notes

*Taken from `skills/stride-completing-tasks/SKILL.md`, "Recording Manual & Exploratory Testing Findings", the `completion_summary` mirror in carrier 1.*

`completion_notes` is persisted only by newer Stride servers and you cannot tell which you are talking to, so a record living there alone may reach nobody. This matters most in exactly the case that looks safest: a small task where no reviewer ran, `completion_notes` is the *only* carrier, and a session that surfaced real bugs would otherwise vanish silently on an older server.

## Which Severity Boundary the Mapping Gives Up

*Taken from `skills/stride-completing-tasks/SKILL.md`, "Severity mapping".*

The mapping table used to carry a third column glossing each exploratory level. It was a shortened orientation aid and never authoritative; `bug-advocacy` holds the full impact ladder. The column read:

| Exploratory severity | Why it lands there |
|---|---|
| **Critical** | A boundary that must hold was crossed, committed data destroyed, money or a legal obligation wrong, a secret exposed, or the product's primary purpose taken away. `critical` is the only reviewer value carrying the same cannot-ship disposition. |
| **High** | Something incorrect survives — valid data persisted wrong or lost but identifiable, a main workflow blocked, success falsely reported. *Fix before proceeding.* |
| **Moderate** | A real workflow degraded, a secondary feature broken, or an error the user cannot act on. Nothing incorrect survives, but it is still *fix before proceeding*, which is what `important` means. |
| **Minor** | Presentation only, or the only casualty was already-invalid input. *Optional but recommended*, which is what `minor` means. |

**Where the four-into-three collapse falls, and why it falls there.** One boundary has to be lost. The exploratory ladder's sharpest *descriptive* line is High/Moderate — whether wrong state survives — but the reviewer enum is not descriptive: its three values are **dispositions at the completion gate** (`critical` and `important` both mean *fix before proceeding*; `minor` means *optional but recommended*). So the boundary to lose is the one whose two sides share a disposition, and that is High/Moderate. Collapsing Moderate into `minor` instead would file a broken export alongside a truncated label — the deflation `bug-advocacy` warns costs exactly as much credibility as inflation.

## The Excuses Table and the Figures It Quoted

*Taken from `skills/stride-completing-tasks/SKILL.md`, the former "Rationalization Table" section after "Red Flags - STOP".*

The percentages and durations below came with no source, sample or date when they were written, and none has been found since; read them as illustration rather than measurement.

| Excuse | Reality | Consequence |
|--------|---------|-------------|
| "Tests probably pass" | after_doing catches 40% of issues | Task marked done with failing tests |
| "I can fix later" | Task already marked complete | Have to reopen, wastes review cycle |
| "Just this once" | Becomes a habit | Quality standards erode completely |
| "before_review can wait" | API requires both hook results | Request rejected with 422 error |
| "Hooks take too long" | 2-3 minutes prevents 2+ hours rework | Rushing causes failed deployments |

## Before and After Figures for Hooks First

*Taken from `skills/stride-completing-tasks/SKILL.md`, the former "Real-World Impact" section after the Quick Reference Card.*

As with the excuses table, nothing records where these numbers were measured or over how many completions, so they show the intended effect and prove nothing about it.

**Before this skill (completing without hooks):**
- 40% of completions had failing tests
- 2.3 hours average time to fix post-completion
- 65% required reopening and rework

**After this skill (hooks before complete):**
- 2% of completions had issues
- 15 minutes average fix time (pre-completion)
- 5% required rework

**Time savings: 2+ hours per task (90% reduction in post-completion rework)**
