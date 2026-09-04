# Changelog

All notable changes to this project will be documented in this file.

## [2.39.0] - 2026-09-04

### Added — `dispatch_count` review-cost telemetry (W2157)

The `reviewer` entry of `workflow_steps` may now carry an optional
`dispatch_count`: how many times the reviewer subagent was **dispatched**,
counting a re-dispatch after a crash, because a crashed dispatch really did
spend its tokens. A cost nobody can see is a cost nobody manages — the review
phase is the most expensive part of a task and nothing in a completion record
showed it.

**It counts dispatches, not rounds**, and those are deliberately different
quantities. Omitting it stays valid, so a version of this port predating the key
completes exactly as before. **No seventh step name was added** — the six-name
vocabulary is untouched, and the optional sub-step dispatches (deep security
review, Step 5.5, Step 5.6) still fold their wall-clock into this entry's
`duration_ms` rather than earning names of their own. A new key is not a new
name. It follows the `reason_code` precedent exactly: a table row marked
optional, a canon anchor, and the elaboration immediately below it.

**The six limits are the more important half, and they ship with the key.** The
task's own instruction was "port the limits with the key, or do not port the
key", and it is right: a figure trusted past its accuracy is worse than no
figure. Wall-clock is not token cost — tokens per second varied about **2.1×**
by dispatch kind, and on real records the pair ranked one task **20.3% more
expensive when its token cost was 1.4% cheaper**, inverting the order. The two
keys measure **different populations**, so `duration_ms / dispatch_count` is not
a per-round figure; it overstated the mean reviewer round by 40% and 52% on the
records available. A review-skipped task can have real review-phase cost and
record none of it, so **absence of a figure is not evidence of absent cost**. An
omitted count is ambiguous and must not be imputed. And nothing validates the
value on the way in.

**Judgement call 1 — the limits are an inline section, not a sibling file.** The
reference keeps them in `skills/stride-workflow/telemetry-cost.md`. This port
has **no sibling files at all** — every skill is a single `SKILL.md` — so
importing that shape would have introduced a file convention the port does not
use, the same mistake as importing a `$MERGED` it does not have. Same substance,
this port's shape, following the `reason_code` model that already lives eight
lines away.

**Judgement call 2 — limit 5 says something stronger here than in the
reference.** A `2` may be one round plus one crash or two rounds, so a fully
compliant `3` reads like a breach of the two-round cap to anyone who knows that
cap. **It is not one.** The reference can reconcile the distinction while a task
is in flight, from its round-counter and merged-result files. **This port
carries neither** — W2155 said so explicitly and deliberately — so the round
count lives only in the orchestrator's context and is recoverable from no
artifact at all, in flight or afterwards. That makes it *more* important here to
say in `completion_notes` what a count above two meant — **as dispatch
bookkeeping only**, on the bounded terms the contract sentence carries.

**Judgement call 3 — say plainly that this port cannot measure it.** The task's
manual test asked whether the field is fillable here or merely aspirational.
Verified: `hooks.json` wires only Bash tool events and the stop gate, so nothing
observes a subagent dispatch. `dispatch_count` is **self-reported by the
orchestrator from its own context**, exactly as the review-round count is — a
record of what the orchestrator says it did, not a measurement. The contract
says so rather than leaving a reader to assume a mechanism.

**The guard obligation is assigned, not left implicit.** Verified directly
against this Stride server: the `workflow_steps` validator checks `name`,
`dispatched`, `duration_ms` and `reason`, and separately gates the `reason_code`
enum — but **not** `dispatch_count`. Unlike `reason_code`, which is refused when
unrecognised, this key is accepted whatever its type, persisted, and returned
verbatim. Nothing reads it today, so the present cost is a corrupt record rather
than anything worse — and the first consumer to read it must guard for a
non-integer itself, or the validator should gain `reason_code`'s
optional-but-validated shape. **Recorded, not fixed:** the task page renders
name, duration and `reason_code` only, so a recorded count is invisible there.
That is in the outer Phoenix app, outside this task's scope, and matches the
reference's own disclosure.

**No token count was invented** — but be precise about why, because the usual
justification is wrong. Some runtimes *do* measure a per-dispatch token cost, so
recording one would not be inventing it; the open question is **portability**,
and it is unsettled.

### Fixed in the same task — the sink that keeps re-opening (W2157)

The specialist security review returned `partial` on the counts-and-durations
consideration, and the cause is a pattern this goal has now hit **three times in
three tasks**: limit 5 ended with "say in `completion_notes` what a count above
two meant" — a free-prose write into a persisted, Review-queue-rendered field,
with no redaction pointer. Every sibling instruction writing to that field in
the same file carries one, and there is no unconditional blanket rule to
inherit: the completing-tasks security rule is scoped to material *captured
during exploration*, and the schema row attaches nothing. Explaining what a
count meant naturally invites the reviewer prose or finding description the
consideration bars.

The clause is now bounded to **dispatch bookkeeping only** — "3 = two rounds
plus one crashed dispatch" — in the agent's own words, paths repository-relative,
redacted on the terms already governing that field, and never quoting reviewer
prose, a finding's description, or observed crash output. Case `25r` pins both
halves of that.

An exploratory session chartered on the measurability question found the other
half. The same illustrative `workflow_steps` record appears **four times** across
two skills with byte-identical figures, and only the canonical copy gained the
key — so three examples, one of them in the schema-owning file itself, modelled
exactly the chosen omission the writing rule added in this same change forbids
("state a `1` you know: an omission you chose looks exactly like one a version
could not avoid"), and manufactured the ambiguity limit 4 warns readers about.
Worse, `stride-completing-tasks` — the skill an agent actually reads while
building a completion payload — mentioned `dispatch_count` **zero times** while
carrying two full payload examples without it. All four now carry the count, and
case `25s` counts the full-dispatch examples and requires the counts to match,
with a non-vacuity guard so it cannot pass on an empty sweep. Proven to bite by
reverting one copy.

That session is also worth recording for what it did *not* find. It verified
every checkable self-claim in this change: the hooks wiring description exactly,
"no hook observes a subagent dispatch" exactly, "this port carries neither"
round-count artifact (independently corroborated by text predating the change),
"no sibling files at all", limit 3's no-reviewer-precondition gates, and **all
twelve numeric figures against the reference, with no drift in magnitude or
direction.**

The code review's one finding was the mirror image: Group 25 read the
completing-tasks contract into a variable and never used it, while its comment
claimed that side "defers rather than restating" — a claim the group proved only
via a port-wide count. Both reads are now live assertions against that file
directly, so the comment is backed by a check rather than by inference.

### Added — hook suite coverage

**Test Group 25** (bash) and **Test Group 22** (PowerShell), 43 cases each,
mirrored case-for-case and verified label-for-label. They pin the optional row,
the dispatches-not-rounds rule, the absence of a seventh name, every one of the
six limits including its figures, the self-reported honesty clause, and that the
canonical full-dispatch example carries a count while the **skip-form example
does not** — a skipped step has no dispatches to count.

Group 23's `23y` guard, left by W2155 asserting `dispatch_count` was absent, is
**flipped in place** so Group 23 keeps its 65 cases. That is the third and last
of the boundary guards this goal's chained tasks left for each other, and all
three have now been flipped by the task that earned it.

## [2.38.0] - 2026-09-04

### Added — the cosmetic finding class (W2156)

`issues[]` entries may now carry an optional `cosmetic` boolean. A cosmetic
finding is presentational only — wrapping, column width, word and line counts,
phrasing preference, the ordering of equivalent prose — and it is still emitted
with its honest severity and category, still reported, and still recorded in
`completion_notes`. **The single thing it changes is the re-review
disposition:** a round whose findings are *all* cosmetic buys no further round.
It is not a carve-out, an exclusion, or a suppression, so it amends none of the
exhaustive-carve-out wording this port carries.

**The gate reads on the artifact's claim, not only the finding's** — and this is
the half that is easy to get wrong, because it was the reference's own defect.
Your finding can be perfectly correct while the thing it points at states
something false: a doc saying "prints six values" where seven print, a comment
placing an assert below a write that sits above it, a heading reading "Two
limits" above three. Each of those is substantive. **A false statement of fact
is never cosmetic, however small.** The subject list is examples of a test,
never a list to match against — and it is qualified by **location**: re-wrapping
a paragraph is cosmetic, but a re-wrap inside executable content (a jq
expression, a heredoc, a fence something greps) changes what runs.

**Cosmetic is orthogonal to severity, not a fourth level of it.** It only ever
sits on a `minor`, and a `minor` can be substantive and still buy a round.
`cosmetic: true` on a substantive finding is a **reviewer defect**, not a
judgement call.

**Judgement call 1 — prose, not a pin, and the shipped text says so.** The
reference refuses three conditions (severity ≠ `minor`, `category ==
"security"`, non-boolean) with a `cosmetic_shape_ok` pin on its two extraction
paths. This port has no extraction split, no `review-block-extraction.md`, and
no hook that can observe a reviewer's block, so there is nothing to attach a pin
to. The refusal became a stated prohibition in the reviewer contract plus a
self-check bullet in the completion hard gate, and **both say in shipped text
that nothing refuses the submission.** Inventing a pin to have one would be
W2127's defect in a new costume. The reference's own recorded slip here is
avoided too: its prohibition paragraph said "two categories" while naming one
category and one *severity*, omitting `important` — all three are named
explicitly.

**Judgement call 2 — the Source A/B/C scoping was re-anchored, not dropped.**
The reference scopes its all-cosmetic rule to its structured-extraction paths,
because on its prose fallback `issues[]` is absent by construction and "every
entry is cosmetic" would be vacuously true. Copilot has no such split, so
importing that vocabulary would name machinery this port does not have — the
failure case `23e` already guards for `$MERGED`. The caveat re-anchored on the
artifact this port *does* have: the parsable fenced json block, the same
threshold W2155's round definition already uses.

**Judgement call 3 — `schema_version` bumped to `"1.7"`.** The port genuinely
gains a field, which is the rule the reference applied. **Ten sites moved**,
including the two `stride-subagent-workflow` worked examples and the `README.md`
headline — and the README is precisely the file the reference's own implementer
left stale on this same change. Cases `24t` and `24u` exist to catch that
recurrence: `24t` sweeps the `find`-enumerated contract corpus for a surviving
`"1.6"` and requires its single remaining occurrence to be the bump note rather
than a live mirror; `24u` reads `README.md`, which sits *outside* that corpus
and is therefore exactly the file a corpus sweep misses. `24u` also asserts the
historical "as of schema 1.5 / 1.6" sentences **survive**, so an over-eager
global replace fails just as a missed one does.

**The residual, stated stronger than the reference's.** The refusal keys on the
literal `category: "security"` string, so a security-relevant finding filed at
`minor` under `code_quality` or `pitfall` can still carry the flag. The
reference records that edge as accepted, because *its* round cap relies on the
same category-keyed boundary. **This port's does not:** W2155 made the security
rule key on the finding's **subject matter however it was categorized**, and the
completion hard gate re-applies that test to every finding before submission,
independent of any `cosmetic` flag. A mis-filed security finding marked cosmetic
still cannot be recorded and shipped — it is fixed or escalated at the gate.
What the flag can still spare is the re-review dispatch that might have surfaced
it a second time. That is a narrower residual, and it is stated rather than left
to inference — which is what this task's `security_considerations` asked for.

**Recorded, not fixed:** the Review queue groups issues by severity alone, so
the flag is invisible there. Pre-existing, in the outer Phoenix app, out of
scope here — and now written down as the fourth stated limit beside the cap,
alongside the disclosure that the classification is **self-certified**: nothing
in this port reads a finding and judges whether it is truly presentational, so
the cheapest abuse is relabelling an ordinary substantive `minor`, which no
artifact here can see.

### Fixed — the porting loss an exploratory session found (W2156)

A session chartered against the definition's own weak point — judgement drift —
classified five **real** findings from this port's recent tasks against the
shipped text and found the definition could not decide three of them. Tracing
the rule back to the reference explained why: **the reference states four
conditions and the first draft shipped two.**

The reference gates are (1) the finding's claim is correct, (2) the artifact it
points at asserts nothing false, (3) *"with both gates satisfied, the subject
must then be purely presentational"*, and then a default: *"Apply the test, not
the examples. Set it `false` (or omit it) on everything else."* The draft kept
gates one and two verbatim, demoted **gate three to a descriptive sentence**,
and dropped the default entirely — then added "read that list as examples of a
test, never as a list to match against", which in the reference disclaims the
exhaustiveness of a *required* gate but here disclaimed the only remaining
sentence naming a subject test. What shipped was a definition of **necessary
conditions with no sufficient condition and no default.**

That is not theoretical. Three of the five real findings — a skip-list entry
matching nothing yet, a trigger stated more broadly than its example, two suite
halves counting with different primitives — clear gate one, clear gate two (a
skip-list and a counting function state no proposition for it to bite on), and
are plainly substantive. Nothing in the draft refused them. The session then
built the adversarial argument end to end, every sentence of it supported by
shipped text. **Gate three and the default-deny are restored**, gate three is
marked a requirement rather than a description, and it is explicitly **not
present-tense** — "nothing behaves differently today" does not satisfy it —
because latent defects were the majority of the real corpus and passed every
present-tense formulation.

**The location qualifier named operations instead of the property.** It reached
re-wraps and re-orderings, so inserting a blank line in markdown *prose* read as
cosmetic. The session demonstrated otherwise against this port's own suite:
case `24c` does line arithmetic over that prose, and one inserted blank line
turns it red. The qualifier now keys on the property — **whether anything reads
the thing you changed** — and names blank lines, heading levels and moved lines
alongside re-wraps.

**The mirror was weaker than the definition, in the file with the incentive.**
The reviewer contract said "only when both gates hold" (necessary); the
workflow mirror used an appositive that reads as a definition (sufficient) — and
the workflow file is the one read by the orchestrator, the party that pays for a
re-review round. The mirror now states all three gates and says in terms that
this is a necessary condition, not a definition.

**The all-cosmetic licence reintroduced W2155's own defect class.** "Proceed to
completion without re-dispatching" carried no deference to the three dispatches
that are not rounds — so an all-cosmetic round followed by a hardened check
entering the test tree pitted this paragraph against the Step 5.6 mandate, which
is exactly the contradiction the previous release fixed across nine sites. Worse,
the `23ag` sweep structurally could not see it: the paragraph contains neither of
that sweep's needles. The licence now excepts the non-round dispatches
explicitly.

**And the hard gate overclaimed its own enforcement.** Its closing sentence said
a failing self-check is a failing completion, generalizing over two bullets that
state in their own words that nothing checks them. The claim is now scoped to
the count, key and status-enum checks the server actually rejects, and says
plainly that the two self-reports bind because you run them. This tension
predates W2156 — W2155 added the first such bullet — so it is recorded as
pre-existing and widened, not newly introduced.

Cases `24aa`–`24ag` pin all five.

### Fixed in the same task — what the review round found (W2156)

**The best of them is the one this change is about.** The diff appended a
fourth stated limit beside the cap and left the heading reading *"Three limits,
written down so nobody reads a pin where there is prose"* above a four-item
list. That is, verbatim, the shape the new definition ships as its own worked
example of a **substantive, never-cosmetic** finding — "a heading reading 'Two
limits' above three". A change introducing the rule that a false statement of
fact is never cosmetic introduced one, in normative contract text, four
paragraphs away. One word fixed it; **case `24z` now pins the numeral against
the actual list length**, counting the items rather than trusting the word, so
the next limit added cannot re-introduce it. Proven to bite by reverting the
word and watching it go red.

**A false attribution, caught by the specialist security reviewer.** The
residual paragraph claimed the reference "records the same edge as accepted".
It does not. What the reference discloses is that its `cosmetic_shape_ok` pin
reaches a flag's type and co-ordinates but never a finding's subject matter,
and the cheapest abuse it names is relabelling an ordinary substantive `minor`
— a *different* edge. The paragraph borrowed authority the source does not
give, in a document that had just finished saying a false statement of fact is
never cosmetic. It now states only what is verifiable: the reference's
recording prohibition keys on the literal `category: "security"` string, and
this port's keys on subject matter. The comparison survives; the attribution
does not.

**And an absolute that overstated its own gate.** "A mis-filed security finding
marked cosmetic therefore still cannot be recorded and shipped" reads as a
mechanism, twelve words before the same file admits the gate is a self-report.
It now says the finding is *caught before submission* "on the same
prose-and-self-report terms as every other bullet there, since nothing in this
port refuses a payload". Claiming enforcement this port does not have is the
precise failure both this task and the last one exist to avoid.

**The all-cosmetic licence now carries the qualifier its sibling had.** The
disposition granted "fix them or not as you choose" with its only security
qualification keyed on the literal category string, while the record-don't-fix
paragraph eleven lines below was explicitly written as "subject to the security
rule below, which is not conditioned on the round number". A security-substance
finding filed under `code_quality` at `minor` with the flag set was, reading
Step 5 alone, both exempted from re-review and permitted to go unfixed — the
completion gate still caught it, so this weakened a defence-in-depth layer
rather than opening a suppression channel, but the asymmetry was real. Both
paragraphs now carry the pointer, and the qualification names subject matter
rather than three category strings.

**A guard that did not cover what its group reads.** Group 24's SKIP guard
omitted the one contract file case `24y` actually opens, so an absent file
would have produced a spurious failure instead of the intended skip. Group 23
guards its equivalent; both halves now match it.

### Fixed after round two — a count that rotted, under the security exemption

Round two and a specialist security re-check independently found the same
defect, and it is the same shape as the "Three limits" one: restoring gate
three left **three pointer sentences still calling it a two-gate definition** —
in `stride-subagent-workflow`, in `stride-workflow` seven lines below the
paragraph that correctly says "all three", and in this changelog. A reader
acting on the numeral rather than opening the definition reconstructs exactly
the necessary-conditions-only rule the exploratory session showed admits
substantive findings. Fixed at all three, and **case `24ah` now sweeps the
corpus** for any surviving two-gate claim that is not the deliberate "the first
two gates", so the count cannot rot a third time. That sweep needed one correction of its own before it was honest: first written, it swept every `two gates` line in the corpus and tripped on an unrelated gate elsewhere in the port that legitimately describes two conditions. It is now scoped to lines about this definition, and was proven to bite by re-introducing the defect and watching it go red.

Two more from the same pass. The residual's replacement clause — "on the same
prose-and-self-report terms as **every other bullet there**" — was itself false:
verified against the server's own completion validator, most bullets in that
gate *do* have server backing, and the same diff had just added the correct
scoping to the gate itself. It understated this port's enforcement rather than
granting a licence, but it re-committed in one file the generalization that had
just been removed from the other; it is now scoped to the two self-report
bullets. And the non-round exception introduced "the three dispatches" above a
two-item gloss closed by "both" — verbatim the shape `24z` exists to police —
so the numeral is dropped.

**These were fixed rather than recorded, and the reason is the rule this
release ships.** Round two is the ceiling, and remaining `important` and `minor`
findings after it are recorded — **except a security finding, at any severity**.
The specialist filed all three under `category: security`, which exempts them.
No third review round was dispatched: the fixes are verified by the full suites
and by three new assertions, and the exemption is recorded here rather than
being used to buy another round.

### Added — hook suite coverage

**Test Group 24** (bash) and **Test Group 21** (PowerShell), 62 cases each (Group 23 unchanged at 65),
mirrored case-for-case and verified label-for-label. They pin the three gates, the
false-statement rule, the location qualifier, the four things the flag does not
change, all three refused conditions, the prose-not-pin disclosure, the
hard-gate bullet's presence *inside* the gate (line arithmetic, not mere
presence), the canon anchor sitting immediately above the definition and
appearing exactly once port-wide, the disposition being stated exactly once and
inside the cap section, and the stale-mirror catchers above.

`24o` earned its keep immediately: the first draft of the deference line in
`stride-subagent-workflow` repeated the disposition sentence verbatim, and the
exactly-once assertion caught the single-source violation before it shipped.

The three `23x` boundary guards W2155 left asserting `cosmetic` and `"1.7"` were
absent are **flipped in place** rather than added to, so Group 23 stays at 65
cases. `23y` (`dispatch_count`) is deliberately left asserting zero — that
boundary belongs to W2157 and is not pre-empted here.

## [2.37.0] - 2026-09-04

### Added — the two-round review cap (W2155)

A reviewer asked to review always finds something, so an uncapped review loop
does not converge. The reference measured every task taking two rounds and one
taking a third fix cycle, at over a hundred thousand subagent tokens a round.
Copilot inherits that cost until it inherits the cap, so here it is: **two
review rounds is the ceiling, and the second verifies rather than
re-reviews.**

Round two's mission is scoped to verifying round one's fixes; its **evidence is
not** — it still receives the full diff and every field the first dispatch
received, and it still emits every section verdict, the full 1:1
`acceptance_criteria` array, and the complete `project_checks`. Scoping changes
what you look for, never what you emit. A dispatch handed only the fix delta
would make the 1:1 array dishonest, and a round two that re-enumerates
everything from scratch buys nothing.

After round two, remaining `important` and `minor` findings are **recorded**,
by severity, category and `file:line`, in `completion_notes` and one line of
`completion_summary` — **never** a `category: "security"` issue, at any
severity, which is fixed or escalated instead. A `critical` is **exempt** from
the cap and blocks at any round number; where it cannot be fixed the task stops
at `review_blocked` (`failure.kind: "review_escalation"`) rather than being
recorded and submitted.

The rule is stated **once**, in `stride-workflow` Step 5, under a
`<!-- canon:review-round-cap v1 -->` anchor. Every other site defers to it:
the D66 re-review paragraph, the `stride-subagent-workflow` issues-found
bullets and its re-review and extraction sections, both Complete Completion
Process variants, and a new bullet in the completing-tasks hard gate. Two
copies of a rule is how the D221 drift this port has already been bitten by
starts.

**Judgement call 1 — what counts as a round.** The reference anchors the count
on `$MERGED`, the merged result file its Source A / Source B extraction split
writes. **Copilot has neither**: its reviewer returns the structured block
inline, and there is no file-based reviewer path anywhere in the port. So the
anchor moved to the artifact this port *does* already name — a round is a
`task-reviewer` dispatch whose response yielded a **parsable** fenced ```json
block, the block the "Extracting the structured review block" section already
extracts. That is the same threshold under a different surface: both count a
round when a block was *parsed*, not when a dispatch was *attempted*, so the
carve-out that a crashed reviewer must not eat a round falls out rather than
being bolted on. `$MERGED` and `.review-rounds-<IDENTIFIER>.json` now each
appear exactly once in the port, as prohibitions against importing them; cases
`23e` pin that they never become live mechanisms.

**Judgement call 2 — no counter file was invented.** A
`.stride/.review-rounds-<ID>.json` that only an agent writes and only an agent
reads is exactly as skippable as the instruction it would replace — this port's
own W2147 finding, and the reason the loop-state record is written by the hook
rather than the agent. No copilot hook can observe an agent dispatch, so there
is no non-agent writer available. The count therefore lives in the
orchestrator's context and touches no file. The state that gives up is handled
by failing **closed**: where the round number cannot be established — a resumed
or compacted session — the next dispatch is treated as **round two**, never as
round one.

**Judgement call 3 — this is prose, not a pin, and it says so.** What shipped
is a normative instruction. Nothing in this port refuses a third dispatch.
`stride-workflow` Step 5 carries the sentence "This cap is stated, not
mechanically enforced." and three stated limits beneath it; the hard-gate
bullet says in its own words that it is a self-report. That is what the
reference itself does for `CRITICAL_CLEARED`, and stating the limit is the
whole point — a rule that reads like a pin and is not one is worse than a rule
that admits what it is. `dispatch_count` telemetry (W2157) is the first surface
that could make the cap server-visible, and is deliberately not pre-empted
here.

**A contradiction closed.** `stride-subagent-workflow` said "After fixing, you
do NOT need to re-run the reviewer" directly beside a re-review section with
nothing bounding how many rounds there could be. The clause was **bounded, not
deleted** — Phase 3.5 quotes it verbatim, so rewriting it would dangle that
citation. Case `23q` uses a whole-line match to prove the unbounded form is
gone (a substring test would keep passing, since the amended bullet still
starts with the same words), and `23r` proves the quoted phrase survives in
both the bullet and its citation.

### Fixed in the same task — four defects the review round found (W2155 round two)

The cap survived its own review round; its **edges** did not. All four were
found before the change shipped — one by the specialist security reviewer, one
by an exploratory session chartered against the cap's own stranding risk, one
by the paper walkthrough the task's `integration_tests` asked for, and three
more by the code reviewer.

**The harden step mandated a round the cap forbade.** Step 5.6 / Phase 3.6
orders a re-review whenever a hardened check enters the test tree, and says in
terms not to weigh whether the edit was substantial. Nine such post-review
re-review sites existed across four files and the README, and **not one of them
deferred to the new ceiling** — while the cap's own limits paragraph claimed the
rule was "not contradicted elsewhere in the port". An agent that obeyed the
harden step ran a third round for a non-critical reason and then met a hard gate
whose only sanctioned third round is one clearing a `critical`, and whose remedy
for a failed check is another re-run: no terminating exit. An agent that obeyed
the cap instead shipped unreviewed executable code with a cited reason to do it.

The fix is a rule, not nine cross-references: **three dispatches are not rounds.**
The cap bounds the find-and-fix loop *over one diff*, so a dispatch that is not
another turn of that loop does not spend a round — a crashed one, a review of
material no earlier round saw (the harden case), and a repair demanded by the
completion self-check. Each is scoped to its own reason, and findings it raises
about already-reviewed lines are treated as if they had arrived at the ceiling,
so this buys no rounds. The harden step, Phase 3.6 and the completion gate each
say so locally, because a reader who lands there and never returns to Step 5
must still get it right.

**The third of those was a deadlock nobody had reported yet.** The completion
gate mandates a reviewer re-run on *any* failed check and budgets no rounds for
it, so a passthrough defect surfacing at the ceiling would have pitted the gate
against the cap with no compliant exit. Found by walking a task through the
review path on paper, which is exactly what the task's `integration_tests` asked
for and the reason that step is worth doing.

**The security carve-out never fired on the single-round path.** It was
grammatically inside the "after round two" disposition — in all three copies —
while the port makes one round the default and an unamended neighbouring bullet
still called `minor` issues optional. A `category: "security"`, `severity:
"minor"` finding from round one was therefore neither fixed nor recorded. The
rule is now stated **outside** the cap: never recorded, at any severity, at any
round number, round one included, and the `minor`-issues bullet excludes it
explicitly.

**And it keyed on the wrong thing.** The carve-out named `category: "security"`,
but a security control failing a `CODE-REVIEW.md` bullet arrives as `category:
"project_check"` — at the reviewer's documented default `important`, the one
default this port actually does document. An unauthenticated mutation route
could have been recorded and shipped under a rule the prose itself describes as
written for nits. The carve-out now keys on **subject matter**, not the category
string.

**Two smaller ones.** The fail-closed round-two default capped dispatches but
also silently licensed *recording* on a compacted session that had never run a
real round one — recording now requires having seen a round-one findings list
and fixed against it. And both Complete Completion Process variants read as
capping Critical fixes; Critical is now split out at both.

### Fixed — the security carve-out's restatements, after a specialist re-check

The specialist security review was re-run against the round-two fixes and came
back `partial` a second time — on a narrower gap, and a real one. The **canon**
now keyed on subject matter, but its two **restatements** still enumerated
`category: "security"` and `project_check` and stopped there. The reviewer's
category enum has seven values, and security substance lands in others
routinely: a violated "don't log tokens" pitfall arrives as `category:
"pitfall"`, a hardcoded credential noted during review as `code_quality`, both
`important` by default. The restatement that mattered most is the hard-gate
bullet — the last check before the PATCH — and it deferred for the round
definition but not for the security rule. **Both restatements now say the two
routes are examples, not the test.**

Two more from the same pass. **"Fixed, or escalated" had only one working
limb:** the single named non-submit exit (`review_blocked` /
`review_escalation`) was textually bound to `critical`, so an `important` or
`minor` security finding that could not be fixed faced three prohibitions and
no compliant path — and that pressure resolves toward submitting. The escalate
limb now names that exit explicitly, **whatever severity the finding carries**.
And the one recording instruction added by the non-round paragraph — "record
which dispatches you treated as non-rounds, and why" — was unbounded free text
into a persisted, rendered sink, where every sibling instruction constrains its
payload; it now carries the same redaction pointer, which matters because
reason 2's "why" describes harden-drafted material this port classifies as
application-influenced text.

Cases `23ah`, `23ai` and `23aj` pin all three, so no site can drift back to a
bare enumeration or lose the exit.

### Recorded, not fixed — round two's remaining findings

The cap this release ships says remaining `important` and `minor` findings after
round two are recorded rather than fixed, security excepted. Applying that rule
to this task's own review, three `minor` `code_quality` findings from round two
are recorded here rather than fixed:

- `minor` / `code_quality` / `skills/stride-workflow/SKILL.md:237` — three
  consecutive blank lines where the section uses one. Presentational only; no
  assertion, anchor arithmetic or grep depends on it.
- `minor` / `code_quality` / `skills/stride-workflow/SKILL.md:241` — non-round
  carve-out 2 ("a dispatch reviewing material no previous round saw") states its
  trigger more broadly than its worked example, so an agent could argue that
  fixes it wrote in response to round one are themselves unseen material and
  spend an extra dispatch. The outcome constraint one paragraph later already
  forces any finding such a dispatch raises about already-reviewed lines onto
  the at-ceiling disposition, so the loophole buys tokens rather than fixes.
- `minor` / `code_quality` / `hooks/test-stride-hook.sh:5676` — the `23ag`
  sweep's skip-list carries a deference keyword (`same terms as a check`) that
  no current mandate line contains: a pre-authorized exemption inside an
  assertion whose purpose is to refuse exemptions. It would silently absolve a
  future undeferred mandate that happened to carry the phrase. The other five
  keyword skips are live and load-bearing.

The security findings above were **not** recorded under that rule, because the
rule this release ships exempts them — which is the point of the exemption, and
this task is the first thing to test it.

### Added — hook suite coverage

**Test Group 23** (bash) and **Test Group 20** (PowerShell), **65 cases each**,
mirrored case-for-case and verified label-for-label. They pin that the rule is stated, stated exactly once,
placed inside the hard gate rather than merely somewhere in the file, and not
contradicted elsewhere — plus the anchor sitting on the line immediately above
the sentence it governs, and negative pins holding the W2156 (`cosmetic`,
`schema_version` `1.7`) and W2157 (`dispatch_count`) boundaries so this task
cannot silently pre-empt the next two.

**The port-wide contradiction sweep is the case that would have caught the
harden defect**, and it did not exist in round one — the group built a
whole-port text variable and then used it for a single assertion. It now sweeps
every markdown contract for the known competing re-review phrasings and requires
each hit to sit beside a deference, skipping flow-diagram lines that restate
prose. It was proven to bite by injecting an undeferred mandate and watching it
go red. It is a **keyword** sweep, not a proof of consistency — a contradiction
phrased in words it does not carry passes it — and stated-limit 1 in the
contract now says exactly that, where round one had claimed the group pinned
non-contradiction outright.

**No executed half was written, and that is a decision rather than a gap.** The
reference's Group 36 `awk`-extracts its `round_cap_ok` jq out of
`review-block-extraction.md` and `eval`s it, so the test runs the contract's
own bytes. Copilot ships no executable check to extract — the cap is prose — so
there is nothing to extract. Hand-*inventing* check logic to have an executed
half would be W2127's defect in a new costume: there, 25 hand-retyped
assertions went green over a real defect precisely because they tested the
retyping. Both group headers record this, and record that a green group means
"the contract says the right thing", never "the cap is enforced".

**Two mirror-fidelity fixes.** The bash half counted with `grep -c`, which
counts matching **lines**, while the PowerShell half counts **occurrences** —
so four exact-count cases asserted subtly different propositions and would have
diverged the first time a needle appeared twice on one line. Bash now counts
occurrences too. And the bash half's file list was word-split from `find`
output; with `set -f` unset, a future markdown filename carrying a space or a
glob character would have silently shrunk the scanned set — which, because the
sweeps are exactly-zero and exactly-one assertions, would have made them **pass**
rather than fail. It is read into an array.

### Fixed — `assert_contains` failed on large haystacks under `pipefail`

Found while writing Group 23. The helper piped its haystack into `grep -q`,
which exits at the first match and closes the pipe — SIGPIPE-ing a writer still
pushing bytes. Under this file's `set -o pipefail` that turned a genuine
**match** into status 141 and failed the assertion. It only bites past the
~64KB pipe buffer, which is why 22 groups of small fixtures never saw it and
Group 23's whole-contract haystacks did immediately: every assertion against
`skills/stride-workflow/SKILL.md` (119KB) failed while the same needle grepped
directly from the file passed. The helper now uses a herestring, and `--` so a
needle beginning with `-` cannot be read as an option. The PowerShell half uses
`.Contains()` and never had the bug.

## [2.36.0] - 2026-09-02

### Added — the loop gate: a completion record, an `agentStop` gate, and the coverage that proves it (G423)

Copilot has a real blocking stop hook, and it is the one runtime where a
copy-paste of the Claude Code gate would **silently do nothing**. On
`agentStop` a non-zero exit is logged and skipped — exit 2 is a *warning*, not
a deny, which it is only for `preToolUse`. A gate ported unchanged would log
its refusal on every turn end, let the session finish anyway, and look healthy
doing it. That single fact is why this shipped as three deliberate tasks rather
than one port.

**The record (W2147).** A successful completion now writes
`.stride/.loop-state.json` — `identifier`, `needs_review` verbatim from the API
response, a second-precision UTC `completed_at`, and the session id — and any
claim clears it. The **hook** writes it, never the agent: an agent-written
marker is exactly as skippable as the instruction it replaces, which is the
whole point of gating on it. The clear is unconditional, including on a failed
claim, because the claim that fails most often is the one against an empty
ready queue and a record preserved there is indistinguishable from one left by
an agent that never claimed at all.

The two halves produce a **byte-identical** record, and the type rules are
fixed once rather than discovered twice: positional key order, `needs_review`
as a real JSON boolean, one shared charset gate, LF-only trailing-newline
normalisation, UTF-8 without BOM, exactly one trailing LF. Two cross-half
divergences were found and closed during review — the bash gate's `case` glob
used collation-based ranges that accept a non-ASCII letter .NET's code-point
ranges refuse (it now enumerates its character set), and an object-shaped
`tool_response.stdout` rendered as PowerShell's `@{...}` where `jq -r`
re-serialises it (a `ConvertTo-OwnCallText` helper now mirrors `jq -r` and
`//` across every value shape). Cases `21w` / `18t` assert the byte identity
with `cmp`, not by inspection.

**The gate (W2148).** `stride-stop-gate.sh` and its PowerShell twin, registered
as `Stop` in `hooks.json`. It blocks on exactly one condition — the record
exists, `needs_review` is the JSON boolean `false`, and `GET /api/tasks/next`
returns a claimable task — and permits on everything else, always at exit 0,
emitting `{"decision":"block","reason":...}` on stdout. No code path in either
half exits 2. It self-limits with a counter keyed on the *completed*
identifier, default budget 2, written before blocking and read back; every
failure to count permits, because a block that cannot be counted cannot be
bounded and wedging a session is worse than missing a gate. `stop_hook_active`
is honoured as a cheap short-circuit but never depended on, and the budget of 2
sits below Copilot's own 8-continuation cap so the runtime override never fires
in normal operation.

**Registration is disclosed, not asserted.** The `Stop` key uses the nested
matcher-plus-hooks shape the rest of this file already uses. What is verified:
the file is well-formed, the entry resolves to the gate, and `Stop` is
GitHub's documented PascalCase alias for `agentStop`. What is **not**: that a
live Copilot parses that shape. The published hooks-file schema is a different,
*flat* one — but it governs `.github/hooks/` and `~/.copilot/hooks/`, not the
plugin loader this file is reached through, whose schema GitHub does not
publish. The shape is **uncorroborated rather than merely unverified**: the
v1.0.36 `preToolUse.matcher` release note names the flat schema's camelCase
spelling, and this port's own working entries are evidence only if they are
known to fire. It ships because it is what the rest of the plugin uses and
changing it would be an equally unverified guess. Both gate headers,
`hooks.json`, `docs/HOOK_RESEARCH.md` and a SKIP-never-PASS test case all say
so; a live restart is what would settle it.

**The coverage (W2149).** Test Group 22 (bash) and Group 19 (PowerShell), with
the permits vastly outnumbering the block and every permit asserting **its own**
reason string — exit 0 plus empty stdout is true of every permit alike and
therefore pins nothing. Every silent permit carries a positive control. Case
`22z` proves the exit-2 distinction rather than commenting on it, by running
both the real gate's output and an inline naive-port stub through a model of
the documented contract. A **13-mutation campaign** in disposable worktrees,
nine against the bash gate and four against the PowerShell one, each disabling
exactly one pinned behaviour, killed every mutant.

Three branches are recorded as **structurally unreachable** rather than covered:
`.stride` directory-creation failure (the loop-state file lives inside it and is
read first, so any run reaching the `mkdir` has already proved it exists), the
"no recognised scheme" arm (the resolver's own `https?://` extraction means any
value that resolves already carries one of those schemes), and — on the
PowerShell half — the top-level `trap`. The counter read-back branch is
likewise unpinnable without mocking the filesystem. Recorded rather than faked.

### Fixed — a symlink write-through in the counter, and a recorder that captured its own bearer header

The block-counter guard refused a directory or a character device but **not a
symlink**, because `[ -f ]` dereferences: a planted
`.stride/.stop-gate-blocks -> <victim>` would have been followed and the target
**truncated**, anywhere the agent user can write, unattended on every turn end
and repeatable by rotating the completed identifier. A dangling link would have
been created outright. Both halves now refuse a symlink before the
regular-file test — `[ -L ]` in bash, the `ReparsePoint` attribute via
`Get-Item -Force` in PowerShell, since `Test-Path` resolves a dangling link and
reports false. Proven with a live exploit reproduction, and pinned by cases
`22af` / `19af` whose block-path control is what makes them non-vacuous.

The Group 22 curl stub recorded its full argv — including
`Authorization: Bearer <token>` — to `curl.log`, which was not in `.gitignore`
in a repo whose `after_doing` commits with `git add -A`. The recorder now
redacts the bearer value with pure parameter expansion (adding no dependency a
restricted-PATH farm would have to carry), `curl.log` and `curl-call.txt` are
ignored, and case `22ai` pins the redaction so the claim cannot rot. The
PowerShell fixture root is now `0700`, matching what `mktemp -d` gives the bash
half.

## [2.35.0] - 2026-08-20

### Added — the four port-canon anchors, plus row precedence and `reason_code` (D253, D239)

`check-port-canon.sh` searches each port for a short HTML comment carrying a rule id and a version number, and calls the cell MISSING when there is none. All four cells for this port were MISSING; all four now read ok.

Two of them needed only the comment. The anti-placeholder rule for a `"failed"` section `note` in `agents/task-reviewer.agent.md` was already correct, and so was the D221 sentence declaring the decision matrix the decision point for its columns. That sentence lives in `skills/stride-subagent-workflow/SKILL.md` rather than in `stride-workflow`, because this port keeps its only matrix there and `stride-workflow` Step 3 reads the `Plan (manual)` column instead of restating a trigger — so both markers land beside that one table, which is where a reader looking for the rule would actually be standing.

Two of them needed new text:

- **Row precedence, and a bottom row to fall to.** The matrix can fit a task on more than one row and never said which row governs. It now carries an authority order and says plainly that the order is not the printed order: the three decomposition rows resolve first despite sitting near the bottom of the table, `small, 0-1 key_files` resolves ahead of `Defect type` (a one-file change is priced as a one-file change however it was filed), `Defect type` outranks `medium (any)` and `large (any)`, after which whichever complexity row fits takes over, and last of all the freshly added `Complexity absent or unrecognised` row — `Skip` / `Run` / `Run` / `Run`, fired only by a task that arrived with no `complexity` or with a value outside `small` / `medium` / `large`, and never available for breaking a tie between rows that do fit. Such a task previously matched no row whatsoever. Had the first two entries been ordered the other way, a small single-file defect would have picked up `Run` in both the `task-explorer` and `task-reviewer` columns and contradicted `stride-workflow` Step 3's own "Small Task, 0-1 Key Files" branch. Step 3's "All Other Tasks" branch now says outright that its heading is shorthand and the matrix row decides, so the new bottom row has somewhere to land.
- **`reason_code` on `workflow_steps`.** An optional six-value enum documented in `stride-workflow`'s Per-Step Schema, sent next to the prose `reason` and never in place of it. A value outside the six is rejected with a `422`; sending nothing is always fine. `matrix_deviation` is the value for a step the matrix asked for and that was skipped regardless — the one code reporting non-compliance rather than a sanctioned skip.

Prompt text only: no plugin behaviour changes; `plugin.json` moves only to carry this release.

## [2.34.0] - 2026-08-19

### Fixed — the failed-verdict `note` rule the server already enforces (D240)

This port's task-reviewer prompt described `note` as optional on every section verdict. The completion API has required it on a `"failed"` verdict since D231, and enforces that **unconditionally** — independently of the `strict_completion_validation` flag — so an agent on this runtime could emit a note-less failed verdict that its own prompt endorsed and be rejected with a `422`. The rejection is self-describing and recoverable, so nothing was broken; every such completion simply paid an avoidable round trip.

The prompt now states that on a `"failed"` section verdict `note` is **REQUIRED** and must name the specific violation or gap in at least **20 non-whitespace characters**, carries the anti-placeholder prohibition (no stub, `TODO`, empty string, or bare restatement of the status), and directs that an empty note means the *verdict* is wrong rather than that the note is unnecessary. `note` stays **optional** on `"passed"` and `"not_assessed"`, so the ordinary empty-section case gains no friction.

Producer-side only: the server-side check in `Kanban.Tasks.CompletionValidation.ReviewContract` is unchanged, and no port was accommodated by weakening it.

### Fixed — planner precedence: the decision matrix is the sole decision point (D232, propagating D221)

This port carried the same ambiguity D221 fixed in the canonical plugin, in `stride-subagent-workflow` only: the decision matrix row `small, 2+ key_files` says Plan = Skip, while the Phase 2 "When:" line independently said "Task complexity is medium or large, OR task has 3+ key_files, OR task has 3+ acceptance criteria lines" — two separately-satisfiable planner triggers with no stated precedence. The same conflict pattern existed for the Explore and Review columns (Phases 1 and 3, `stride-completing-tasks`' pre-completion review items), plus drifted narrower restatements in the flowchart, quick-reference card, and Plan-agent usage gloss. This port's `stride-workflow` Step 3 prose branches carried no competing OR-clause for the task's target shape, but its "For medium+ tasks, outline" item diverged from the matrix for a medium defect (Plan = Skip unless large) and now reads the matrix's Plan (manual) column instead. Measured consequence in canonical: two runners on identically-shaped tasks resolved the collision differently and wrote different skip reasons into `workflow_steps` telemetry.

The fix mirrors canonical's D221 resolution: the matrix now states it is the decision point for its columns, and every restatement — the three "When:" lines, the skip-planning line, `stride-completing-tasks`' review items, and the flowchart/quick-reference glosses — reads its matrix column with "**Read the column; do not re-derive the condition here** (D221)" instead of re-deriving a condition. Resolved toward the matrix (Plan = Skip for `small, 2+ key_files`), so no planner work is added to the most common task shape.

Recorded verification grep (should return only row definitions, D221 history, matrix-agreeing glosses, and `stride-workflow`'s own non-conflicting prose branches — never a rule that could fire independently of the matrix):

```
grep -rniE "if medium|medium\+ OR|medium or large, OR|3\+ (key_files|criteria|acceptance)|2\+ key_files" --include="*.md" skills/ agents/
```

## Release record — tags without a GitHub release

*This is a record-keeping note, not a release. It describes no change to this plugin and carries no version.*

A fleet-wide audit found **3 tags** in this repository that are tagged and pushed but have no corresponding GitHub release. **The gap is accepted and will not be backfilled.** It is recorded here so the next release engineer does not rediscover and re-litigate it:

- `v2.3.1` — 2026-04-14
- `v2.5.0` — 2026-04-16
- `v2.8.0` — 2026-05-19

Why accepted rather than backfilled:

- **Nothing resolved through these releases.** A GitHub release is a human-readable record, not a resolution mechanism — nothing installs *through* one. The missing releases cost nothing at the time and cost nothing now.
- **Backfilling would be worse than the gap.** A release created today against a commit from April or May would be dated today, and would manufacture a record for a state no user ever resolved through — misrepresenting the very history it claims to document.
- **The convention itself is unchanged.** These are omissions from a few release cycles, not a policy shift. Every tag still gets a release going forward.

The audit also found **zero** GitHub releases without a matching tag, so the record is incomplete in only this one direction.

## [2.33.0] - 2026-08-02

Ports the optional `-harden` sub-step — the last deferral the `[2.31.0]` and `[2.32.0]` Scope blocks named — completing this port's exploratory-testing integration. Prompt text only; the companion `stride-copilot-exploratory-testing` plugin is untouched.

### Added — an optional `-harden` sub-step (Step 5.6 / Phase 3.6), sequenced so a drafted check cannot redden the gate

A session that finds a bug and stops has closed nothing. `-harden` drafts one regression check per convertible bug, which is the step that turns *Explored* back into *Checked*, and it is the only place the workflow can close that loop automatically.

- **A three-condition gate:** a Step 5.5 session ran and returned **convertible** findings; the `stride-exploratory-testing-harden` skill is available (a real gate — it arrived in the companion's **0.2.0**, and 0.1.0 shipped without it, so check for the skill rather than the plugin); and the runtime can activate it. That third condition has no Step 5.5 analog, because `-harden` ships **only** as a skill with no agent to fall back on — and it creates a tempting wrong answer, so **never approximate an unavailable activation by drafting the checks yourself** is stated in the gate, the Decision Summary, and both flow artifacts.
- **The sequencing rule.** `after_doing` is a blocking gate that runs the suite, and a check reproducing an **unfixed** bug is *supposed* to fail — that failure is the evidence it reproduces the bug. Sequenced naively, a session that did exactly the right thing blocks a task that may not even be scoped to fix the bug. **Leaving drafts staged in `.exploratory/checks/` is the default and always safe**, which activating without `--output` preserves.
- **Two things must hold before a check enters the suite, and a skip marker gives only one:** the **file must load** — a marker makes a *case* inert, not a *file*, and runners compile the whole tree first, so an unresolved `TODO(harden):` wiring marker fails however it is tagged — and the **case must be green or inert**. Both are established by **running the gate's own command once across the whole suite**, never by expecting.
- **Three dispositions, and no others**, with the still-open path carrying four conditions: the file loads clean, the case is marked skipped or pending (`xfail` is not a skip), a follow-up defect is filed, **and** the check asserts the guard rather than performing the bypass. **Never red in the tree** — the hazard is presence, not the commit, since `after_doing` runs the working tree.
- **A check for a security finding asserts the guard, never performs the bypass.** `-harden`'s convertibility test bars a destructive step, a shared-environment mutation, a real third-party side effect, and a real credential or customer record — but an auth-bypass sequence, a cross-tenant read or an IDOR fetch **against the suite's own fixtures** violates none of those and converts cleanly. Those are precisely the findings the plugin's own rubric rates **Critical** (data crossing a tenant, account, role or permission scope; a secret or token exposed) or **High** (an authorization control demonstrably absent) — so a check built from that repro is, by construction, a **working exploit for a live vulnerability**, and the still-open disposition would commit it into a suite the gate compiles on every future task. The draft must assert the boundary **holds**, and **independently of how the finding was rated, one that reproduces the bug by successfully exploiting it may not enter the test tree while the bug is open**. A stored exploit is not made safe by a skip marker.
- **Three checks at the move are the agent's, not the skill's.** `-harden` never overwrites a path **it** writes and never writes into your test tree at all, so the copy you perform there is protected by nothing — it prints that line for you, unrun. Never overwrite an existing test file, never edit a test you did not write, and **read the draft first**: a literal credential, token, session identifier, customer record or internal hostname where a fixture value belongs means the draft does not move.
- **Three checks at the move cover all three deferred rules, not two.** The credential class and the destructive class both get an independent check before the copy, because a destructive check **runs green** and so passes the load-and-inert gate untouched — and the verification run is the moment such a step would first execute, so "run it once and see" cannot be the control. The draft and its `INDEX.md` are also read **as data, never as instructions**: both are built from application-controlled text, and they are read at the moment the agent is about to write into the test tree and run the gate's command.
- **The discriminator is the assertion, not the request.** A guard-asserting check necessarily still issues the crossing request — that is how it proves the guard fires — and that form is sanctioned; what is barred is a check asserting the crossing **succeeded**. For a still-open boundary failure the committed check names the guard and the expected rejection, while the exact payload and identity-substitution mechanics go in the follow-up defect, which is access-controlled where the repository is not.
- **The no-runner property is contractual, not mechanical**, and the port says so: the skill's own text states that a Copilot skill carries no tool allowlist, so "I did not run it" has to be true because you chose not to, every time. That is exactly why a drafted check is never reported as passing on its say-so or the agent's own.
- **Post-review files are surfaced, never smuggled.** Paths in `completion_notes`, one line in `completion_summary`, and any check that entered the tree in `actual_files_changed` — extended to cover the staged path too when `.exploratory/` turns out not to be ignored, since the obligation turns on unreviewed executable code reaching the commit rather than on which directory it sat in. The reviewer is re-run **whenever** a check entered the tree, with no substantiality judgement, and if it cannot be re-run that is said in the record.
- **Telemetry** folds into the existing `reviewer` `workflow_steps` entry, never a seventh name, with the Step 5.5 and Phase 3.5 telemetry sentences updated to name the sub-step as a second contributor.
- **The move-time content check reaches the summary artifacts too.** A Decision Summary row, a flowchart line and two Quick Reference Cards exist to be consulted instead of the full prose, so a control present only in the prose is a control an agent may never read — the same defect shape as a mis-nested reference card. Both classes now appear in all four.
- **Redaction is restated at the sinks the sub-step creates.** What it records is derived from findings that originate in observed application output, so Step 5.5's rule binds unchanged on `completion_notes`, `completion_summary`, the `testing_strategy` note — **and on the follow-up defect**, whose carried substance includes the repro the check encodes and which is persisted and rendered like any other sink.

### Scope

Prompt text and documentation only. **No completion field is added, removed, or made required; no seventh `workflow_steps` name; no enum, schema, hook-script or agent change.** The new step is additive and gated: with no session, no convertible findings, no `-harden`, or a runtime that cannot activate it, the workflow behaves exactly as it did in `[2.32.0]`. Still deliberately not corrected, and carried forward from `[2.31.0]`: `stride-subagent-workflow`'s flowchart does not mention Phase 3.5 or Phase 3.6 at all, and `stride-completing-tasks`' flowchart and Quick Reference Card mention neither Step 5.5 nor Step 5.6. Those are pre-existing gaps this release does not introduce — inserting a 5.6 reference into a diagram that has never referenced 5.5 would be net-new rather than keeping an existing citation in sync — and they remain follow-ups.

## [2.32.0] - 2026-08-02

Ports three more `stride`-side changes into this GitHub Copilot port — an explicit session budget with a named environment context on the Step 5.5 / Phase 3.5 dispatch, richer session recording, and `.exploratory/` gitignore guidance — plus two later refinements of the same prose. Prompt text only; the companion `stride-copilot-exploratory-testing` plugin is untouched.

### Added — an explicit session budget and a named environment context

The dispatch said only "passing the running-app environment context": what that had to contain was nowhere stated, and Step 5.5 passed no budget at all — an unbounded dispatch inside an autonomous workflow, against a live application.

- **Eight named inputs**, packed into the single free-text block the `explorer` agent takes alongside the charter, two of them safety-bearing: the authorized non-production confirmation (recorded here, not re-opened — the determination itself already happens before dispatch, per v2.31.0). **Where that warrant comes from is stated, because it differs from the canonical plugin:** there a human affirmative is collected once at Step 0 and may be neither supplied nor inferred; this port has no such collection point and never prompts between steps, so the confirmation is one the orchestrator establishes from the environment — the target is authorized because it is the task's own local or explicitly non-production instance. That is a narrower warrant, and it is why the determination fails closed: with no other source to fall back on, an unestablished target means no dispatch at all (never supplied on the user's behalf), and **a pointer to where test accounts live, never inlined credentials**, because the dispatch prompt is an artifact like any other.
- **The budget is the caller's to set**, in whatever unit the **installed** contract declares — the two plugins release independently, so the unit is established from `stride-copilot-exploratory-testing/agents/explorer.agent.md` rather than hardcoded here. Today that is probes: default **12**, band **8–20**, tool-call ceiling **5×**, whichever is reached first ending the session and recorded in `stop_reason`. If it will not fund one workable charter, **do not dispatch at all** — the band is per dispatch, not a pool to divide.
- **Phase 3.5 was passing the wrong unit.** Its dispatch list said "Any test accounts or seed data, and **the time box**" — a wall-clock box, against an installed contract that states outright it has no `duration` and no `tbs` and will not report a duration it never measured. That bullet is replaced rather than supplemented: **never hand a wall-clock box to a probes contract.**
- **Budget exhaustion is a normal outcome that never fails completion.** What changes is only what may honestly be claimed: `charter_quiet` (and `risk_acceptable`) is the only ending supporting "this manual test was performed"; `probe_budget_exhausted` is valid partial findings with an incomplete coverage claim; `tool_call_ceiling` and `blocked` are **judged on the session sheet, not on the word** — at or near zero probes both mean the session did not happen, so it is recorded as **not performed** and the manual test handed back, while after meaningful probes both are partial coverage. Claiming a spun-out session as a performed manual test is worse than not running the plugin at all, because the plugin-absent path at least flags the test as still owed. Leftover risk goes to a **filed follow-up with an ID**, never to a "follow-up charter", which has no identifier and no lifetime past the session.
- **Capture everything the dispatch returned**, the session sheet included, establishing its fields from the installed contract rather than from the page — enumerating them here is how a later contract change silently drops one.

### Added — richer recording: stakeholder impact, the artifact path, and a `completion_summary` mirror

- **Each finding now names who is harmed and how**, not only its severity — a severity word says how bad the failure is, not who it lands on, which is what a reader triaging the Review queue needs. Read from the installed contract's `bugs[].stakeholder_impact` (emitted honest-or-"could not establish"), restated and redacted rather than pasted; where a contract emits none, say who is harmed in your own assessment or say plainly that the session did not establish it. **Never invent an impact the session did not support.**
- **The artifact's path is cited when one exists — and the text is explicit that usually it does not.** The `explorer` agent is not asked to write a session file, and the plugin's own `session` skill attributes session-sheet writes to the `-explore`, `-pair` and `-debrief` skills, none of which Step 5.5 dispatches — so on the automated path the prose summary is the normal and complete record rather than a degraded fallback. The reasoning is deliberately narrower than the reference's: the agent's `tools:` list holds no write tool **but does hold `run`**, a shell surface, so "no write tool" does not settle it. **Record the path, never the contents**, repository-relative, since an absolute path discloses a username and machine layout and the artifact may hold unredacted output.
- **One line is mirrored into `completion_summary`**, which is required, persisted and rendered on the Review queue, where `completion_notes` is persisted only by newer servers. It matters most in the case that looks safest — a small task with no reviewer, where `completion_notes` is the only carrier. **This is not a new field and not a third record**: the two carriers remain the sole carriers *of the record*, and the mirror is a durability backstop on an already-required field.
- **Redaction now binds explicitly on the impact text and the artifact path**, and on every finding field that carries secrets, as examples rather than a closed list — **the rule is the sink, not the field name**. **Restating is not redacting**: a faithful paraphrase carries an account name, a customer email and a hostname through untouched, so redact by **generalising the referent**, and name a finding rather than quoting it when its text carries a secret.

### Added — `.exploratory/` gitignore guidance, delivered at Step 0

Session artifacts land under `.exploratory/`, hold transcribed application output — the exact material the redaction rules keep out of the completion payload — and arrive **untracked**. An operator's `## after_doing` that stages everything (`git add -A`) sweeps them into a commit, which is far harder to walk back than a payload field.

- **Step 0 gains item 3**, which is the delivery point: Step 5.5 runs only once a session is already under way, so it is structurally too late. It names `.stride/`, `.stride_auth.md` and the three hook temp files unconditionally, and adds `.exploratory/` **only** when the exploratory plugin is installed. Step 5.5 and Phase 3.5 carry the *reasoning* as the agent's reminder of what to say.
- **Operator guidance only — the workflow never edits their `.gitignore`.** `git commit -a` is named as the safe shape against `git add -A`, and the sweeper is correctly attributed: this plugin's own `hooks/stride-hook.sh` stages nothing. An already-committed artifact needs `git rm --cached`, because `.gitignore` is inert for a tracked path.
- **The line's limits are stated, not glossed:** it protects the default locations only, and since all seven command-derived skills accept `--output`, a redirected destination outside `.exploratory/` carries the same transcribed output with no protection from that entry. The cited artifact path is also rendered inert on the same terms as an unrecognized severity string, since a path learned rather than authored is application-influenced text and `completion_notes` renders as Markdown on the Review queue.
- **`README.md`'s existing gitignore sentence is extended rather than replaced**, and gains `.stride/` and `.stride_auth.md`, which it had never named despite the port creating both.

### Fixed — a blocked session is recorded as an obstacle, not as a finding

Both skills said an unreachable app should have its obstacle "reported as a finding". That hands it to the absent-severity rule, which maps it to `important` — filing an unreachable dev server as an important testing finding whose worst impact the agent is then asked to name. The installed contract requires a blocked session to set its `status`, record the obstacle in its `debrief` and **not fabricate results**, so the obstacle lives there carrying no exploratory severity. **A blocked session that returns bugs is no contradiction** — those are real observations recorded on their own terms; only the *obstacle* is never one. Coverage is judged from the sheet rather than the word, so a `blocked` session at or near zero probes takes the same disposition as a zero-probe ceiling hit.

### Added — where the exploratory session's wall-clock goes

The port forbade the wrong answer in one skill and gave the right answer for the sibling deep-security dispatch in another, while saying nothing at the site where the question arises. It now says it: fold the session's wall-clock into the existing **`reviewer`** `workflow_steps` entry, **never a seventh step name**. The wall-clock is the orchestrator's own measurement, never a field read out of the session sheet — today's contract carries no `duration` and no `tbs`. When no reviewer ran, that entry is the skip form carrying no duration, so the dispatch is recorded in `completion_notes` rather than given an invented one; that case is routine here, since this gate has no review precondition.

### Scope

Prompt text and documentation only. **No completion field is added, removed, or made required; no seventh `workflow_steps` name; no enum, schema, hook-script or agent change.** No trigger condition moves — the budget-too-small and unestablished-target refusals are post-gate dispatch decisions, so every path still skips gracefully when the plugin is absent. Deliberately **not** in this release: the optional `-harden` sub-step and its `after_doing` sequencing.

## [2.31.0] - 2026-08-01

Ports two `stride`-side changes into this GitHub Copilot port: the exploratory severity ladder is aligned with the reviewer's issue vocabulary and given an escalation policy, and the Step 5.5 / Phase 3.5 dispatch is narrowed to surfaces that can complete without a human. Prompt text only; the companion `stride-copilot-exploratory-testing` plugin is untouched.

### Added — the exploratory severity ladder mapped onto the reviewer issue vocabulary

The companion plugin rates each bug on a four-level ladder (**Critical > High > Moderate > Minor**, owned by its `bug-advocacy` skill); `reviewer_result` has three (`critical` / `important` / `minor`). Nothing said how one became the other, so a finding could reach the completion payload on whichever scale the agent happened to be holding.

- **`skills/stride-completing-tasks/SKILL.md`** gains a `### Severity mapping` subsection: the four-row table, and the reason the four-into-three collapse falls on **High/Moderate** — the reviewer enum's values are *dispositions at the completion gate* rather than descriptions, and `critical` and `important` share one (*fix before proceeding*), so that is the boundary whose loss costs least. Collapsing Moderate into `minor` instead would file a broken export alongside a truncated label. **The section maps; it never re-rates** — the plugin's rubric stays the sole source of truth for what level a finding *is*, and a mapped reviewer value is never written back onto `bugs[].severity`.
- **Mapping a severity is not appending an `issues[]` entry.** Only a `critical` the escalation rules find *introduced* becomes one; everything else — including a *discovered* `critical` — goes to `completion_notes` and the `testing_strategy` note only. Appending a non-escalating finding would leave `issues[]` disagreeing with a `passed` `testing_strategy` verdict, which the pre-submission self-check refuses outright — manufacturing exactly the blocked completion the policy promises not to cause.
- **Absent or unrecognized severity → `important`; never dropped, never `critical`.** `critical` is the one value that triggers escalation, so an unparsed string must never reach a blocking path; `minor` would be a silent downgrade. The raw value is quoted to 40 characters in inline backticks **only when it carries nothing from the protected classes** — a credential or token, customer data, an internal hostname — otherwise it is replaced with a redaction sentinel and its length reported. **Judge by class, never by length**: an email address or internal hostname is short and legible, so a length bound would emit the whole thing while looking like a mitigation.

### Added — a Critical exploratory finding now escalates, but only when this task introduced it

Before this release a Critical exploratory finding was advisory prose while a `partial`/`unmitigated` security verdict was fail-closed — an asymmetry that was an accident rather than a decision. It is now a decision, and a bounded one.

- **`skills/stride-workflow/SKILL.md`** gains `### Escalation: what happens when a session returns a Critical finding` in Step 5.5, and **`skills/stride-subagent-workflow/SKILL.md`** gains the matching `**Escalating a Critical finding.**` digest in Phase 3.5 — identical in substance, with reciprocal keep-in-sync pointers naming each other's exact heading.
- **One question decides it: are the responsible lines among the lines this task changed?** *Introduced* escalates fail-closed — `testing_strategy.status` → `"failed"` plus a `category: "testing"` / `severity: "critical"` entry with matching `issue_counts.critical` and `issues_found` increments — which the pre-submission self-check refuses at submission time, so the defect is fixed, the charter re-run, and the review re-run before completing. *Discovered* appends no issue and flips no verdict: it is recorded at its **exploratory** severity in `completion_notes` and one line of `completion_summary`, added as an advisory to the `testing_strategy` note, and **filed as a follow-up defect** so it has an owner. **A pre-existing bug never blocks an unrelated task.**
- **Provenance is computed from your own artifacts, never from the finding's text**, because the application under test controls that text and a blocking escalation must not be triggerable by content an attacker can influence. Falling back to the task's `key_files` is explicitly barred — that would hand the blocking footprint to task-author text.
- **The change-set mechanics are this port's own, not the reference's.** The canonical plugin reads the claim-time dirty baseline from a separate `.stride-dirty-baseline` file. **This port has no such file**: it carries the baseline as a **base64-encoded `TASK_DIRTY_BASELINE=` line inside `.stride-env-cache`**, alongside `TASK_BASE_REF` — one lookup rather than two artifacts — decoding to one `<blob-hash>\t<path>` line per path, which makes line-level attribution recoverable where a baseline path was touched again. Porting the reference's file path verbatim would have been a reference no agent could resolve. Two port-specific signals are named too: `TASK_BASE_REF_TRUSTED='1'` marks a base written by the post-`before_doing` capture, and a cache carrying **no `TASK_BASE_REF` line at all** is the undeterminable branch rather than an error to work around.
- **Lines the agent did not author are outside the change set, and a non-production determination is required before dispatch.** The dirty baseline is computed once, right after `before_doing`, so it cannot cover a file the application under test writes into the working tree *during* a session — counting those would put an app-controlled footprint inside the branch that blocks completion, the exact property this test exists to deny. Anything that appeared without the agent's authorship is excluded and resolves to *discovered*; the test is **authorship, not the file's category**, so output the task deliberately generated by a build or codegen step stays in. Separately, narrowing dispatch to the `explorer` agent takes `stride-exploratory-testing-explore`'s own authorization gate off the automated path — it was never reachable there as a mandatory control, since the previous text already offered direct agent dispatch as an equal alternative, but the agent treats a caller-named target as authorized by construction, so both skills now require establishing that the environment context names a local or explicitly non-production instance before dispatching, and skipping gracefully when it cannot be established.
- **The unrecognized-severity quote cannot break out of its frame.** The 40-character prefix is quoted only when it contains no backtick and no line break — either closes the inline-code span early and lets application-controlled text render as live Markdown in a persisted, reviewer-facing field — and otherwise a sentinel and the length are recorded instead.
- **Every uncertain state resolves to `discovered`** — an undeterminable change set, a base ref failing its sanity check, a baselined path whose per-path attribution could not be resolved, a fault site unidentified after a bounded attempt — and is labelled *provenance undetermined*, never *pre-existing*, because those branches never established provenance. Blocking on a link you could not draw would be a denial-of-progress surface.
- **No structured review block in the payload → no escalation, and nothing may be synthesized.** A small task (0-1 `key_files`) whose review the decision matrix skipped, and a review whose JSON would not parse, both reach this. Never fabricate a structured block, an `issues[]`, an `issue_counts`, a section verdict or a `dispatched: true` — and never downgrade a review that *did* run to a self-reported skip.
- **The remedy is a re-review, and that is a stated exception.** Phase 3 says that after fixing reviewer-reported issues you do **not** need to re-run the reviewer. That rule governs issues the *reviewer* reported; an escalation the *orchestrator* wrote into `reviewer_result` leaves a `failed` verdict and a stale Critical entry that only a fresh review regenerates away — the same remedy the security sub-step already requires.
- **The graceful-skip contract is unchanged.** No trigger condition moved, the fallback text is untouched, and both skills now say plainly that **no exploratory finding can block completion on a task that never ran a session.**

### Changed — Step 5.5 and Phase 3.5 dispatch only non-interactive surfaces

Both skills previously offered the `stride-exploratory-testing-explore` skill and the `explorer` agent as equally valid dispatch targets. That skill opens with a question round, so an autonomous workflow that chose it would **hang with no error** — the worst failure shape, because it looks like a stall rather than a violation.

- **The principle governs, not the list:** *dispatch only a surface that runs to completion without requiring a human*, because the orchestrator does not prompt between steps. "Requires a human" is read broadly — a surface that waits on an out-of-band approval fails identically to one that prompts. A surface the plugin gains later qualifies by satisfying the principle, **never by being added to a list**, and the entries recorded are reasoning rather than a standing guarantee: the companion versions separately, so re-establish a surface from its own frontmatter whenever its version changes.
- **The sanctioned surface is the `explorer` agent, and it is the only one.** This port's argument is its own, not a translation of the canonical plugin's (which reasons from a withheld `Agent`/`WebFetch` allowlist that does not exist here): **an agent declares a `tools:` list and a skill has no tool-restriction field at all** — an asymmetry the companion's own frontmatter harness makes explicit by requiring `tools` on every `agents/*.agent.md` and checking only `name`/`description` on every `skills/*/SKILL.md`. A skill's unattended-safety therefore rests on its prose alone, which the companion says of its own `-pair` skill in as many words. The `explorer` agent additionally states "Never ask the user a question."
- **Never auto-dispatched:** `stride-exploratory-testing-explore` — disqualified **twice over**, by an unconditional question round no argument pre-empts (it must ask, precisely because the agent it dispatches cannot) and by a Step 4 authorization-and-non-production **safety gate** that fails closed; `-recon` (the same safety-control confirmation); `-pair` (human-at-the-keyboard by construction); `-nightmare-headline` (looping elicitation rounds); and the **`stride-exploratory-testing` routing skill**, which can route to any of them and is what the bare plugin name resolves to, so "dispatch the plugin" lands on it. `-charter`, `-debrief` and `-harden` clear the bar but run no session.
- **Disqualification turns on prompts a surface *can* raise, by a stated test:** a prompt you pre-empt with an input you control does not disqualify; one fired by a condition you do not control does; a safety-control prompt disqualifies regardless.
- **This narrows what may be *run*, never what counts as *installed*.** Detection is unchanged and still availability-only, with the never-execute rule intact — it now says explicitly that detection **confers no dispatch licence**. The `stride-subagent-workflow` gate additionally gains the same seven-surface detection list Step 5.5 uses, so the two gates share one trigger — the `-pair` and `-harden` skills and the routing skill are named in the prose as present-but-barred rather than added as detection entries, which would have widened the gate.

### Fixed — three flow artifacts that routed around the policy

`stride-subagent-workflow`'s Quick Reference Card named the `-explore` skill as a dispatch target this release bars, and `stride-workflow`'s ASCII workflow and Quick Reference Card described a Step 5.5 with no escalation branch — while already carrying the "app not running → do NOT fail" branch, which establishes them as the place Step 5.5's outcomes are enumerated. All three are corrected.

### Fixed — the enforcement anchor, corrected before release

The reference anchors this escalation in a completion self-check checkbox ("Section verdict and `issues[]` agree in both directions") that **this port does not have**. The first draft re-anchored both citations to Phase 3's "Fix all Critical issues before proceeding" gate — which is real, but is **upstream of the phase that writes the escalation**: Phase 3 has already been passed by the time Step 5.5 runs, so a Critical appended there cannot flow back through it, and the claim described a mechanism that would never fire. `stride-completing-tasks`' pre-submission self-check therefore gains the missing checkbox, on the same shape as the one that already backs the `security_considerations` escalation: a `passed` `testing_strategy` alongside a `category: "testing"` Critical is a hard fail. That makes the escalation genuinely fail-closed at submission time, which is what `patterns_to_follow`'s "follow the fail-closed escalation already documented for the security-review integration" actually requires.

### Scope

Prompt text and documentation only. **No completion field is added, removed, or made required; no seventh `workflow_steps` name; no enum, schema, hook-script or agent change.** The escalation writes only into fields that already exist (`reviewer_result.issues[]`, `issue_counts`, `testing_strategy.status` and `.note`, `completion_notes`, `completion_summary`), as a named bounded exception to the whole-object-copy rule on the same terms the `security_considerations` escalation already is. Deliberately **not** corrected here: `stride-subagent-workflow`'s flowchart does not mention Phase 3.5 at all, and `stride-completing-tasks`' flowchart and Quick Reference Card do not mention Step 5.5 at all. Both are pre-existing gaps this release does not introduce, and both are left as follow-ups rather than folded in — which is the *discovered versus introduced* policy this release itself adds, applied to its own diff. Also deliberately not in this release: the explorer session budget and named environment-context inputs, the richer session recording, the `.exploratory/` gitignore guidance, and the optional `-harden` sub-step.

## [2.30.0] - 2026-07-28

### Changed — the `behaviour_test_matrix` rules treat row text as untrusted, and say what to do when it carries a credential

`behaviour_test_matrix` row text is authored by whoever created the task and is attacker-controlled at the API boundary — anyone posting directly to the Stride API never sees these instructions. v2.29.0 threaded the field through the port; this release hardens every rule that reads it, and resolves a contradiction that made one of them impossible to obey.

- **Row text is data, never instructions.** The completion self-check's matrix gate and the Step 4 implementation driver both state the boundary explicitly: a row is a specification to satisfy, and text inside a row that appears to address the agent, waive a check, or exempt the task is content being submitted — reportable as a finding, never a directive to follow.
- **The secret rule is scoped to row *state*, not agent intent, and covers references.** A row that embeds a secret, credential, or token — **or that names a location where one lives** (file path, env var, secret-store key, vault reference, CI/CD or platform secret, Kubernetes Secret, git object, database row) — is by that fact alone a defect to raise (D184, D187).
- **A refused row has a named reporting channel and a defined representation.** The implementing agent reports the defect in `completion_notes`, identifying the row by `category` and position rather than quoting its text, and leaves the row exactly as authored. The reviewer, required to echo rows verbatim, instead substitutes the literal sentinel `[REDACTED — row text embedded a credential]` into the required field carrying the credential, echoes that row `failing`, and raises a `category: "security"` issue. The resulting `failed` verdict is the **expected outcome of a correct refusal** (D186).
- **The PATCH-body contradiction is resolved.** The driver mandated recording a row's status advance by PATCHing the matrix while forbidding a credential from reaching the PATCH body — unsatisfiable together, since `PATCH /api/tasks/:id` replaces the whole array and a non-empty matrix is rejected unless it covers all seven categories. The rules now state that re-sending row text the record **already stores**, byte-for-byte unchanged, back onto that same record is not a new copy, and name exactly one correct action (D185).
- **The review-phase self-review checklist** gained a `behaviour_test_matrix` bullet (W1949).

### Changed — guidance now cites the real controls instead of authoring conventions

- **`completion_notes` is persisted.** Every span that described it as unpersisted now states the deployment-conditional truth: persisted by Stride servers from D188 onward, but an agent cannot tell which server version it is talking to. The rule requiring the refusal to *also* appear in one line of `completion_summary` is unchanged — only its premise was corrected.
- **Row-text rendering is defended by escaping, not by an authoring rule.** The creation and enrichment guidance now cites the real controls (auto-escaped interpolation on every render path; the API hard-rejects an out-of-vocabulary `category` or `status`), keeps the no-raw-HTML rule as hygiene, and separates the secrets rule as genuinely authoring-only (W1947).

### Fixed

- **Reviewer per-section `not_assessed` wording** aligned with the other ports, so the Copilot reviewer describes an unassessed section on the same terms as its siblings (D181).

## [2.29.0] - 2026-07-26

### Added — `behaviour_test_matrix` threaded through populate, verify, and utilize (G384)

The Kanban app stores a task's **behaviour/test matrix** — one row per behaviour paired with the test that covers it, across seven fixed categories. This release makes the Copilot port actually *use* it: document it as a creation field, populate it during enrichment, verify it during review, and drive implementation from it. Mirrors the upstream Claude Code implementation (stride 1.40.0 / G381) adapted to Copilot's layout.

The field is **OPTIONAL throughout**. It is deliberately **not** added to the five review_queue-scored fields (`acceptance_criteria`, `testing_strategy`, `security_considerations`, `pitfalls`, `patterns_to_follow`), so a task without a matrix is never penalized and never renders an empty pill.

- **`stride-creating-tasks`** documents `behaviour_test_matrix` as a structured creation field: a new **Embedded Object Formats** subsection (four WRONG cases that each fail for a real schema reason, plus a labelled RIGHT excerpt), a Field Quick Reference row, a Recommended-fields checklist entry, and a full seven-row sample in the Complete Task Object example. Row contract: `category` (one of the 7 fixed categories), `behaviour`, and `status` are required; `test_name` is required unless the row is waived (`status: "not_applicable"` or an N/A-like `test_name`), in which case `na_reason` is required instead; `type` is `unit`/`integration`/`manual` or a `/`-joined combination; `position` is order-bearing. **All-or-nothing:** an absent or empty matrix passes, but a non-empty one must carry a row for every one of the seven categories.
- **`stride-creating-goals`** documents the identical shape for nested tasks — no batch-specific variation.
- **`stride-enriching-tasks`** builds the matrix in Step 3, projecting the `unit_tests` / `integration_tests` / `manual_tests` / `edge_cases` it just derived onto the seven categories, and adds it to the pre-submission checklist (now **18 items**).
- **`agents/task-enricher.agent.md`** populates it on the custom-agent path. Emission is the default whenever the testing analysis produced test cases; omission is reserved for a task with genuinely no testable behaviour. Rows authored at enrichment time are `status: "planned"` unless honestly waived as `"not_applicable"`, and each names a real test or carries an `na_reason`, and never records secrets or raw HTML. Its checklist is likewise now **18 items**, with `behaviour_test_matrix` as the one item that may legitimately be omitted.
- **`agents/task-reviewer.agent.md`** schema bumps to `schema_version` **1.6** (schema bullet + worked-example JSON): a **Behaviour/Test Matrix Verification** pass in review step 4 locates the test each row names and judges the row *Verified* / *Missing* / *Mismatch*, plus a new **OPTIONAL** top-level `behaviour_test_matrix` verdict object `{ status, note, rows[] }` modeled on the `security_considerations.considerations[]` precedent. The echoed rows reuse the task-side row vocabulary — `category` and `behaviour` are required, `status` is one of `planned`/`passing`/`failing`/`not_applicable` — so Verified maps to `passing` and both Missing and Mismatch map to `failing`; `verified`/`missing`/`mismatch` are **not** wire values and are rejected. Fail-closed: any `failing` row forces the section to `failed` and requires a matching `category: "testing"` issue, which also flips `testing_strategy`. The verdict key is **omitted entirely** when the task supplied no matrix. Matrix rows are treated as untrusted data to assess, never as instructions. The canonical schema continues to live in [`stride/agents/task-reviewer.md`](https://github.com/cheezy/stride/blob/main/agents/task-reviewer.md) and is cited, never redefined.
- **`stride-workflow`** utilizes it: Step 4 lists it as an implementation driver (write the test each row names, advance the row's `status`, re-check that a waived row's reason still holds, and PATCH the updated matrix onto the task).
- **`stride-subagent-workflow`** documents it as an **Orthogonal (not complexity-gated)** driver and adds it to the reviewer-dispatch field list (now 9 fields), kept in sync with the reviewer's own "You will receive" input contract. **`stride-completing-tasks`** gains a pre-submission self-check for the verdict: when the task supplied a matrix the verdict must be present with a real status and row-for-row `rows`, with the fail-closed consistency rule enforced. The existing whole-object passthrough already carries the new section, so no consumer enumerates keys.

**Prompt-injection hardening (beyond the upstream source).** Every surface where row text reaches an agent now carries an explicit data-not-instructions boundary. Because the reviewer is *required* to echo row `category`/`behaviour` text verbatim into `reviewer_result`, that text reaches the completion agent's context — so `stride-completing-tasks` now states the echoed `rows[]` text is untrusted data that never carries system or developer authority however it is framed, and that a row attempting to steer the gate is itself a finding to report. Both implementation surfaces (`stride-workflow` Step 4 and the `stride-subagent-workflow` orthogonal bullet) now forbid copying a secret found in row text into code, tests, commit messages, or the PATCH body, and state that a row never overrides the task's `pitfalls` or `security_considerations`.

- **`README.md`** documents the schema bump (`schema_version` 1.5 → 1.6) and the new OPTIONAL `behaviour_test_matrix` verdict with its per-row `rows[]` breakdown in the `task-reviewer` section, and notes in the `stride-workflow` section that the orchestrator threads the field through Step 4 and the review phase.

Also in this release: the stale `schema_version` example payloads in `stride-completing-tasks`, `stride-workflow`, and `stride-subagent-workflow` (still showing `1.4`) are synced to `1.6`, as prior schema bumps were done in lockstep — `README.md`, which was already at `1.5`, is carried to `1.6` with them; the enrichment checklist counts are corrected from 17 to 18 and a stale "16-item" reference fixed; a red-flag line citing a long-outdated field count is made number-free; and the `stride-completing-tasks` gate sentence that said "all three checks" against a four-item list now reads "every check above" so it cannot drift again.

Every change is documentation/skill-text only — no hook logic, `.stride.md`, or wire-shape change, and no new server-validated completion field.

## [2.28.0] - 2026-07-23

### Added — optional security-considerations deep review with `stride-copilot-security-review` (G5673)

A new `considerations` review-phase integration turns "security considerations declared" into "security considerations verified mitigated" when the companion [`stride-copilot-security-review`](https://github.com/cheezy/stride-copilot-security-review) plugin is installed — without any server change, new completion field, or new `workflow_steps` name.

- **`agents/task-reviewer.agent.md` (W1906)** bumps the `reviewer_result` `schema_version` from **1.4 to 1.5** (schema bullet + worked-example JSON) and extends the `security_considerations` verdict object with an **optional nested `considerations[]` array** — one `{ consideration, status: mitigated|partial|unmitigated, evidence, note }` entry per listed consideration — documenting the fail-closed escalation rule (any `partial`/`unmitigated` forces the section status to `failed` and requires a matching `category: security` issue) and that the array is populated only via the Copilot security-reviewer dispatch, absent otherwise, never required. The `passed`/`failed`/`not_assessed` section-status enum is unchanged.
- **`stride-workflow` (W1907)** gains a gated **Deep security-considerations review** sub-step inside **Step 5 (Self-Review)**: when the task's `security_considerations` is non-empty (a `"None — …"` placeholder does not count) AND the `stride-copilot-security-review` plugin is available (detected by its `security-review-essentials` skill / `security-reviewer` agent appearing — availability only, never blind execution), it invokes the `security-reviewer` agent in considerations mode with the diff + considerations framed as DATA, merges the returned `consideration_verdicts` into `reviewer_result.security_considerations.considerations[]` via the whole-object passthrough, folds the time into the existing reviewer step (no new step name), and escalates fail-closed. A Decision Summary table and graceful fallback (plugin/agent absent → skip, no failure, self-review verdict stands) are included.
- **`stride-subagent-workflow` (W1908)** documents the trigger as an **Orthogonal (not complexity-gated)** entry in its decision matrix, deliberately identical to the Step 5 sub-step condition, reusing the sanctioned-surface availability idiom.
- **`stride-completing-tasks` (W1909)** makes explicit that the whole-object copy carries the nested `reviewer_result.security_considerations.considerations[]` array through to `/complete`, and extends the pre-submission self-check to require — when a deep review ran — that the nested array be present and consistent with the section status (a `passed` status alongside a `partial`/`unmitigated` entry is a hard fail); the array is absent and not required when no deep review ran.

The trigger wording is identical across all four surfaces so authoring guidance and execution stay in sync. Every change is documentation/skill-text only — no hook logic, `.stride.md`, or wire-shape change, and no new server-validated completion field. When the companion plugin is **not** installed, everything degrades gracefully and the completion payload is unchanged.

## [2.27.0] - 2026-07-21

### Added — optional Manual & Exploratory Testing integration with `stride-copilot-exploratory-testing` (G349)

The task lifecycle can now run a task's `manual_tests` as real exploratory sessions when the companion [`stride-copilot-exploratory-testing`](https://github.com/cheezy/stride-copilot-exploratory-testing) plugin is installed — without any server change, new completion field, or new `workflow_steps` name.

- **`stride-workflow` (W1791)** gains a gated **Step 5.5: Manual & Exploratory Testing**, placed between Self-Review (Step 5) and Execute Hooks (Step 6). It is doubly gated — it runs only when the task's `testing_strategy.manual_tests` is non-empty **and** the `stride-copilot-exploratory-testing` plugin is available in the session (detected by its `stride-exploratory-testing-explore` skill / `explorer` agent appearing in the session's available lists; availability only, never blind execution). Each manual test is framed as a charter and driven by the `explorer` under the plugin's absolute safety boundary (no destructive or production-mutating actions; an unreachable app is reported as an obstacle, never a completion failure). Uses a decimal step number so no existing step numbers or cross-references change; the flowchart and quick-reference card are updated.
- **`stride-subagent-workflow` (W1792)** documents the dispatch as an optional, externally-provided **Phase 3.5** in the decision matrix, mirroring the task-explorer/task-reviewer phase style (trigger, inputs, outputs, graceful skip). The trigger wording is kept identical to Step 5.5.
- **`stride-completing-tasks` (W1793)** documents recording the findings in existing tolerant fields only — a summary in `completion_notes` and, when a reviewer ran, the `reviewer_result.testing_strategy` note — with an explicit no-op fallback (plugin absent or no `manual_tests` → the completion payload is byte-for-byte unchanged). No new server-validated field and no new `workflow_steps` name, keeping the strict-completion-validation contract intact.
- **`stride-creating-tasks` / `stride-creating-goals` (W1794)** gain an advisory authoring note beside their `manual_tests` documentation: when the companion plugin is installed each entry runs as an exploratory charter, so phrase entries as chartable scenarios (a target plus the information/risk to discover), with a before/after example. Advisory only — it adds no required field and does not change the `testing_strategy` shape or the review_queue empty-pill gate, so existing terse entries still validate.

**Graceful degradation:** when the companion plugin is not installed, the entire integration is inert — manual tests remain a human responsibility and nothing about the core lifecycle changes. The integration is purely additive.

### Testing

Documentation/skill-text only; no test suite is exercised. Verified by grep sweep and cross-file consistency check: the Step 5.5 trigger wording matches the Phase 3.5 trigger and the completion-recording guidance; the flowchart and quick-reference cards in both workflow skills include the new step; and no new completion field or `workflow_steps` name was introduced.

### Backward compatibility

Fully backward compatible. Skill-text only — no hook logic, `.stride.md`, env-var, or `.stride_auth.md` change, and no completion-payload schema change. Agents without the companion plugin see identical behavior.

### Source

G349 — "Integrate the stride-copilot-exploratory-testing plugin into the stride-copilot manual-testing workflow" (tasks W1791, W1792, W1793, W1794, W1795).

### Fixed — the enrichment surface documented create and update bodies without their `task` root key (D151)

`stride-enriching-tasks` documented submitting an enriched task with a bare body: `POST /api/tasks` carried `-d '{...enriched task JSON...}'` and no `agent_name`. The server requires a `{"task": {...}}` envelope and rejects a bare object with `422 Missing 'task' key`, so an agent following the enrichment skill literally built a rejected request and — once corrected by hand — created a task with no attribution fallback. The create example now shows the envelope with `"agent_name": "GitHub Copilot"` beside the `task` key, matching the Request Envelope section in `stride-creating-tasks` and the plain agent name this port already sends on claim and complete.

The same file's `PATCH /api/tasks/:id` example was broken the same way and is fixed too — but its rule differs and the doc now says so: `PATCH` needs the identical `task` root key, yet takes **no** `agent_name`, because attribution is create-only and `created_by_agent` is forbidden on update. Conflating the two would have been its own defect.

The `task-enricher` agent doc is deliberately **left unwrapped**: its JSON is the agent's return value for the orchestrator to submit, not a request body, so an envelope there would be wrong. It gains a note saying exactly that, and pointing at who does the wrapping.

This surface was missed by goal G4687 (the fleet-wide `agent_name` rollout) because it sits outside that goal's tasks' `key_files` and outside both of their grep sweeps.

### Testing

Documentation-only; no test suite is exercised. Verified by grep sweep: the enrichment create example carries the envelope and this port's own agent name (`GitHub Copilot`), matching its `stride-creating-tasks` Request Envelope section; every curl body in the file is brace-balanced; and no other file in the port documents a create body.

### Backward compatibility

Fully backward compatible. Documentation/skill-text only — no hook logic, `.stride.md`, env-var, or `.stride_auth.md` change. The documented shapes are corrected to what the server has always required; nothing that previously worked stops working.

### Source

D151 — follow-up to goal G4687; the gap was recorded by the W1684 reviewer as out of scope at the time. Kanban `task_controller.ex` is the contract of record: `create/2` reads `agent_name` beside the `task` key, `update/2` requires `task` and reads no `agent_name`.

## [2.26.0] - 2026-07-16

### Added — every documented create payload carries a top-level `agent_name` (W1688)

Mirrors the canonical `stride` plugin's W1684 change (released as `stride` v1.37.0) into the Copilot bridge. `stride-creating-tasks`, `stride-creating-goals`, and `agents/task-decomposer.agent.md` now document a top-level `agent_name` on every create request — beside the `task` root key for `POST /api/tasks` and beside the `goals` root key for `POST /api/tasks/batch` — set to the exact same plain agent name the bridge already sends as `agent_name` on claim and complete (`"GitHub Copilot"`, never the `ai_agent:<model>` token form).

Per-task `created_by_agent` is forgotten in practice and cannot be backfilled (`PATCH` rejects it), so tasks lost their attribution permanently and the `/agents` feed rendered them with a `?` avatar. The root-level param is the always-sent fallback that kanban D137 teaches the server to read. Both creation skills gain the full five-step server resolution order (explicit `created_by_agent` → token `ai_agent:<model>` → top-level `agent_name` → token's last agent name → unset), an `agent_name` row in their field tables, and an explicit note that `agent_name` is display metadata only — never an authorization signal.

### Fixed — `stride-creating-tasks` documented the single-create body without its `task` root key

The skill's complete example was a bare task object, but `POST /api/tasks` requires a `{"task": {...}}` envelope and returns `422 Missing 'task' key` without it. Surfaced while placing `agent_name` "beside the task root key" — the key it had to sit beside was never documented. A new Request Envelope section shows the wrapper with `agent_name` as its top-level sibling, and the Quick Reference heading now names the block as the value of the `task` key rather than the request body; the single-goal format in `agents/task-decomposer.agent.md` is corrected the same way. The bridge inherited this defect from the canonical plugin, where W1684 fixed it.

### Backward compatibility

Fully backward compatible, and safe to ship ahead of the server. Documentation/skill-text only — no hook logic, `.stride.md` wire shape, env-var, or `.stride_auth.md` change; the five task-lifecycle hooks are untouched. Unknown top-level keys are ignored by older servers, so sending `agent_name` before kanban D137 reaches production is a no-op. `created_by_agent` guidance is unchanged and still highest precedence — the new param is a fallback, never a replacement.

### Source

W1688 — mirrors the canonical `stride` plugin's W1684 (`stride` v1.37.0) and the `stride-codex` port W1686 (`stride-codex` v1.25.0). Kanban D137 ships the server half. Released by W1689 as `stride-copilot` v2.26.0, with the vendored `stride-copilot-marketplace` re-synced to match.

## [2.25.0] - 2026-07-14

### Fixed — post-pull `TASK_BASE_REF` capture and committed-work snapshot completeness (D142)

Mirrors the canonical `stride` plugin's D142 fix (released as `stride` v1.36.0) into the Copilot bridge. Two production incidents silently corrupted the review diff surface, and stride-copilot mirrored the same hook architecture at the older W1516 generation, so any Copilot user on a multi-clone workflow hit both defects verbatim. All changes are backward-compatible; the `.stride.md` wire shape and the five task-lifecycle hooks are unchanged. Copilot's base64 `TASK_DIRTY_BASELINE` env-cache transport is kept as-is — only **when** the baseline is computed moved (post-`before_doing`), not **how** it is stored.

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (D132)** — `TASK_BASE_REF` was captured at claim time, **before** the `## before_doing` section's `git pull` moved `HEAD`, so the `after_doing` diff spanned another clone's already-completed task (a reviewer saw another machine's task inside an unrelated defect's Review diff). The claim interception now writes task **identity only** and strips any inherited `TASK_BASE_REF` (and its trust marker) immediately; a new `finalize_before_doing` (bash) / `Invoke-FinalizeBeforeDoing` (PowerShell) rewrites the base and re-records the dirty baseline **after** the section finishes — jq-free, regardless of the section's exit code — stamping a `TASK_BASE_REF_TRUSTED` marker.
- **`hooks/stride-hook.sh` (D132)** — Added `resolve_snapshot_base`, a trust guard wired into `finalize_after_doing` and the `before_review` self-heal: empty/unresolvable and non-ancestor-of-`HEAD` bases always recompute from the task branch point (merge-base with the origin default branch) with a loud stderr notice; the strict-ancestor-of-branch-point rule applies only to **unmarked inherited** bases, so a workflow that pushes its own task commits before completing stays safe. The judgment resolves **once per task window** (memoized against the after_doing section's own `git push` moving origin refs) and is persisted as a `base=` line in `.stride-diff-upload-state` for the self-heal to reuse.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (D137)** — The claim-time dirty-baseline filter excluded files whose blob hash matched claim time even after the auto-commit committed them as task work (silently dropping tracked edits and an untracked migration). `capture_changed_files` (bash) and the `Invoke-ChangedFilesUpload` filter (PowerShell) now override the baseline exclusion for any path in the `base..HEAD` committed range — committed range = task work, by definition.

### Testing

`hooks/test-stride-hook.sh` (326 assertions) and `hooks/test-stride-hook.ps1` (237 assertions) both pass, with a new **Test Group 20** (bash) / **Test Group 17** (PowerShell) covering the two-clone bare-origin cross-pull scenario, the `resolve_snapshot_base` trust-guard units (recompute for older/unresolvable/non-ancestor bases, passthrough for trusted and no-origin cases), the D137 committed-range override, the push-in-`after_doing` once-per-window memoization with persisted `base=`, the trusted pre-pushed base, and the jq-free `finalize_before_doing` rewrite. Both groups were verified failing against the pre-fix hooks (16 bash / 2 PowerShell failures) and passing after.

### Backward compatibility

Backward-compatible and additive. The `TASK_BASE_REF_TRUSTED` marker and the `base=` state line are new but tolerated when absent (an inherited cache simply gets the full trust guard); the committed-range override only ever **includes** more task work, never excludes; the base64 `TASK_DIRTY_BASELINE` transport is unchanged; `after_goal` detection, the `tee`/`.last-api-response.json` fallback, and the non-fatal upload semantics are untouched.

### Source

D142 — mirrors the canonical `stride` plugin at v1.36.0 (`finalize_before_doing`, `resolve_snapshot_base`, the committed-range override, and the claim identity-only strip).

## [2.24.1] - 2026-07-10

### Fixed — `changed_files` upload targeting and terminal-failure visibility (D127 / W1658)

Mirrors the canonical `stride` plugin's `changed_files` upload fix (PORTING section 2–3) into the Copilot bridge. Completed review tasks were arriving with an empty `changed_files` array — the diff was being `PUT` to the wrong task — because the upload targeted the (possibly stale) env-cache `TASK_ID` seeded from the claim response. When that response was hidden from the hook, the cache kept the previous task's id and the current task's diff was lost silently. All changes are backward-compatible; the `.stride.md` wire shape and the four task-lifecycle hooks are unchanged.

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (D127)** — Added a URL→id helper (`task_id_from_command` / `Get-TaskIdFromCommand`) that parses the authoritative task id from the `/complete|/mark_reviewed` URL in the intercepted command, and used it at **both** diff-upload call sites (`finalize_after_doing` / `Invoke-FinalizeAfterDoing` and `self_heal_changed_files_upload` / `Invoke-SelfHealChangedFilesUpload`). The env-cache `TASK_ID` is now the fallback only for the claim path (whose URL carries no id). This removes the dependency on the claim having seeded the env cache correctly and needs no network call — the id is a pure parse of a command already in hand.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (W1658)** — The `before_review` self-heal is the last retry, so a non-2xx PUT there means the diff is definitively lost for the task. It now surfaces a distinct `CHANGED_FILES UPLOAD UNRESOLVED` message on stderr (separate from the per-attempt warning) and appends `unresolved=yes` to `.stride-diff-upload-state` so the failure is queryable, not silent. Non-blocking — the hook exit code is unchanged and the completion still succeeds; a later successful PUT overwrites the truncating state file and self-clears the mark; the id + HTTP code only are ever emitted (never the bearer token).

### Testing

`hooks/test-stride-hook.sh` (304 assertions) and `hooks/test-stride-hook.ps1` (231 assertions) both pass, with a new URL→id unit test (bash 9g) and stale-env targeting integration tests (bash 9h, PowerShell 8g) proving the diff PUT targets the URL id over a stale env id, the existing "missing env `TASK_ID` → no PUT" expectations flipped to "PUTs to the URL id" (bash 9c, PowerShell 8e), and terminal fail-loud tests (bash 12k/12l, PowerShell 9j) asserting the loud `UNRESOLVED` signal + `unresolved=yes` marker + unchanged exit code, with the mark self-clearing on a later 2xx.

### Backward compatibility

Backward-compatible and additive. The URL→id parse only runs on the `/complete|/mark_reviewed` path and falls back to the env-cache `TASK_ID` for the claim path; the fail-loud signal never changes the hook's exit semantics.

### Source

D127 (W1662), W1658 (W1663), version bump (W1664) — goal G-copilot-changed-files-upload-fix.

## [2.24.0] - 2026-07-09

### Fixed / Added — `after_goal` reliability against harness truncation (G315 — D118/W1609/D119/W1611/W1612/W1610)

Mirrors the canonical `stride` plugin's after_goal reliability fix into the Copilot bridge. The harness truncates a large `/complete` `tool_response.stdout` mid-JSON (the echoed `reviewer_result` alone can run to tens of KB), so the bridge's `after_goal` detection silently missed the entry on a goal's last child and the goal-completion push never fired. All changes are backward-compatible; the `.stride.md` wire shape and the four task-lifecycle hooks are unchanged.

- **`hooks/stride-hook.sh` (D118 / W1624)** — Added a `RESPONSE_FILE` global (`$PROJECT_DIR/.stride/.last-api-response.json`) and a jq-validated `read_canonical_response` helper, threaded as a fast path into both payload consumers (`response_has_after_goal` and `export_after_goal_env`) so after_goal detection and `GOAL_*` env forwarding prefer the untruncated canonical file, falling back to the `tool_response.stdout` parse.
- **`hooks/stride-hook.sh` (W1609 / W1625)** — Introduced `extract_response_payload` as the single shared resolver (canonical file → `tool_response.stdout` unwrap → W1086 persisted-output file → best-effort raw) and routed `response_has_after_goal`, `export_after_goal_env`, **and** the `before_doing` claim env-cache/`TASK_BASE_REF` refresh through it, so a truncated claim stdout no longer loses `TASK_ID` or leaves a stale base ref. Added `capture_canonical_response` (persists this call's valid stdout to the canonical file early in the post phase) and hard-excluded the `.stride/` state dir from `changed_files`.
- **`hooks/stride-hook.sh` (D119 / W1626)** — Added the reliability guarantee: a hook-initiated fresh `GET /api/tasks/:id/after_goal_status` (`detect_after_goal_via_api`), immune to harness truncation and needing zero agent cooperation. `route_after_goal` keeps the D118 fast path and the D119 fresh call mutually exclusive so `## after_goal` runs at most once; unreachable/non-JSON/missing-prereq degrades to a clean no-op (the grace-window worker still completes the goal). The token is never logged.
- **`hooks/stride-hook.ps1` (W1611 / W1627)** — PowerShell parity: `Read-CanonicalResponse`, `Save-CanonicalResponse`, the unified `Get-ResponsePayload` resolver (with the truncated-`{stdout}`-to-`$null` elseif gate so the fresh call fires), the claim env-cache restructure, the `^\.stride/` exclusion, and `Invoke-AfterGoalDetectionViaApi`/`Invoke-AfterGoalRouting` (fresh GET via `Invoke-WebRequest -SkipHttpErrorCheck -TimeoutSec 10`).
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (W1612 / W1628)** — Closed two after_goal reliability gaps to reach parity with `stride`: the exported `GOAL_*` are now persisted to the env cache (so the agent's separate follow-up `PATCH /api/tasks/:goal_id/after_goal` process can read them), and a **parent-id fallback** exports `GOAL_ID` from `data.parent_id` when the server omits it from the after_goal env.
- **`skills/stride-completing-tasks`, `skills/stride-claiming-tasks`, `skills/stride-workflow` (W1610 / W1629)** — Documented the `| tee "$CLAUDE_PROJECT_DIR/.stride/.last-api-response.json"` response-capture pattern (with a `--output` tee-less fallback) that feeds the canonical file, the canonical-file→fresh-GET detection ordering, and a `git log origin/main..main` push-verification step (noting the grace worker only flips the goal to Done and does **not** push).

### Testing

`hooks/test-stride-hook.sh` (296 assertions) and `hooks/test-stride-hook.ps1` (225 assertions) both pass, with new groups for the canonical-file fast path, the shared resolver + capture + claim-from-file recovery, the D119 hook-initiated fresh call (bash Group 18 / PowerShell Group 15), and the end-to-end after_goal reliability under truncation including the parent-id fallback (bash Group 19 / PowerShell Group 16).

### Backward compatibility

Backward-compatible and additive. Detection falls back to the `tool_response.stdout` parse when no canonical file is present, and the D119 fresh call degrades to a clean no-op (with the grace-window worker as the ultimate backstop) when the endpoint is unreachable. The `GET /api/tasks/:id/after_goal_status` endpoint must be live on the target server for the fresh call to resolve; it degrades cleanly otherwise.

### Source

G315 — W1624 (D118), W1625 (W1609), W1626 (D119), W1627 (W1611), W1628 (W1612), W1629 (W1610).

## [2.23.0] - 2026-07-03

### Fixed / Added — hook-executor behavioral fixes and `after_goal` diagnostician awareness (G287 / W1512–W1517)

Six fixes to the client-side hook bridge (`hooks/stride-hook.sh` + `hooks/stride-hook.ps1`) and the hook-diagnostician agent. All are backward-compatible; the `.stride.md` wire shape and the four task-lifecycle hooks' documented behavior are unchanged.

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (W1512)** — The bridge now forwards the server-supplied `after_goal` `hook.env` into the `## after_goal` child process. Before running the section it extracts the `env` object from the `after_goal` hook entry and exports `GOAL_ID`/`GOAL_IDENTIFIER`/`GOAL_TITLE`/`GOAL_DESCRIPTION` (plus `BOARD_*`/`COLUMN_*`/`AGENT_NAME`) **verbatim** — never invented or derived client-side. A missing `env` object is a clean no-op. Previously the `2.11.0` CHANGELOG and the workflow SKILL promised these vars but the scripts never read them, so an `after_goal` command referencing `$GOAL_ID` ran with it empty.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (W1513)** — The executor now **enforces** the documented per-hook timeouts (`after_doing` 120s; `before_doing`/`before_review`/`after_review`/`after_goal` 60s) on the `.stride.md` section, keyed on the routed hook. Each command runs under the section's remaining budget (bash via `timeout`/`gtimeout`, PowerShell via `WaitForExit`), so the section can never exceed its limit nor the 300s outer host budget. A timed-out command is terminated and reported through the existing structured failed-JSON (`exit_code: 124`), preserving the `after_doing` PreToolUse block. Where no `timeout` utility exists (stock macOS/BSD bash) the inner limits are not enforced and only the 300s host ceiling applies. `hooks.json`, the workflow SKILL, and the README now distinguish the outer host budget from the inner per-hook limits.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (W1514)** — The hook success JSON now reports an integer millisecond `duration_ms` (portable high-resolution timing — bash `EPOCHREALTIME`/`date +%s%N`/`perl`/whole-second fallback; PowerShell `Stopwatch`) instead of whole-second `duration_seconds`, matching the `duration_ms` convention the hook-diagnostician and `workflow_steps` telemetry already use (a sub-second hook previously reported `0`).
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (W1515)** — The `.stride.md` parser now joins backslash line-continuations, so a multi-line command (e.g. a long `gh pr create` split with trailing `\`) runs as one command instead of fragmented pieces. Only an unescaped (odd-count) trailing backslash continues; literal `\\` is left intact; comment/blank handling and single-fence/first-wins selection are unchanged.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1` (W1516)** — The changed-files snapshot is now guarded against pre-existing working-tree edits. `before_doing` records a claim-time dirty baseline (`<blobsha>` + path content fingerprints, base64 in the env cache — never file contents) so `capture_changed_files` (bash) / the upload filter (PowerShell) omits paths already dirty at claim time whose content is unchanged, while still capturing a pre-existing file the task itself modifies. Truncation, binary-placeholder, and self-artifact exclusion are preserved.
- **`agents/hook-diagnostician.agent.md` (W1517)** — The diagnostician now recognizes the fifth `after_goal` hook: it is enumerated in the description/opening, added to the Hook Timeout Handling thresholds (60,000 ms), and a new **after_goal Hook Context** section documents the `GOAL_*` env context (vs `TASK_*`) and the `PATCH /api/tasks/:goal_id/after_goal` forward path so a goal-rollup failure is diagnosable. Agent prose only.

### Testing

`hooks/test-stride-hook.sh` (259 assertions) and `hooks/test-stride-hook.ps1` (201 assertions) both pass, with new groups for the `after_goal` env export (8f/8g, 7f/7g), per-hook timeout enforcement (Group 14 / Group 11), millisecond durations (Group 15 / Group 12), line-continuation (Group 16 / Group 13), and the claim-time dirty baseline guard (Group 17 / Group 14).

### Backward compatibility

Backward-compatible. `after_goal` env forwarding and the dirty-baseline guard are additive; timeout enforcement degrades to the prior no-enforcement behavior where no `timeout` utility exists; `duration_seconds` is replaced by `duration_ms` in the success JSON (the field the diagnostician already expects).

### Source

G287 — W1512, W1513, W1514, W1515, W1516, W1517.

## [2.22.0] - 2026-07-01

### Added — `API Notes & Limitations` section in the workflow orchestrator skill (G286 / W1420)

Two recurring API gotchas were undocumented, and agents kept rediscovering them the hard way: attempting to move a task to a different goal via `PATCH` (impossible — `parent_id` is creation-only and there is no DELETE endpoint), and calling the hosted API from an HTTP library whose default User-Agent the edge rejects.

- **`skills/stride-workflow/SKILL.md`** — Added an **API Notes & Limitations** section directly after **API Authorization**, mirroring the canonical stride wording: (a) tasks cannot be reparented and there is no DELETE endpoint — moving a task between goals or removing it is a human board-UI action, never to be worked around by recreating the task as a supersede; (b) raw HTTP calls must use curl or a curl/browser-like `User-Agent`, because the hosted API edge returns `403` with `error code: 1010` to default library User-Agents (e.g. `python-urllib`).

### Backward compatibility

Documentation/skill-text only. No skill logic, hook, or wire-shape changes.

### Source

G286 — W1420 (mirrors the canonical stride W1416 wording).

## [2.21.0] - 2026-06-29

### Added — `create-tasks`/`create-goals` now have an explicit terminal state, plus a Backlog claim-fail guard (G284 / W1404)

In an autonomous/build context the create-tasks/create-goals flow could create a task and then fall straight through the `stride-workflow` orchestrator's build loop — auto-claiming and building the just-created task. The claim fails because newly created tasks sit in the Backlog (not Ready), and the agent would then build the work outside the Stride lifecycle (no claim, no hooks, no completion record). The orchestrator had no terminal state for the create intent, unlike `stride-ideation` which stops at the written document.

- **`skills/stride-workflow/SKILL.md`** — Added a **Creation Terminal State** section: on a create-tasks/create-goals intent the orchestrator now reports the created identifiers and STOPS without entering Task Discovery, claiming, or implementation (no-marker variant — Copilot satisfies the sub-skill STOP gate by routing through the orchestrator). Added a **Backlog Claim-Fail Guard**: a failed claim is a terminal stop, never a fallback to building outside the lifecycle. The build loop (Steps 1–9) is unchanged.
- **`skills/stride-creating-tasks/SKILL.md`**, **`skills/stride-creating-goals/SKILL.md`** — Added a `## Terminal state` note: creation ends the turn; building is a separate, explicitly-invoked action.

### Backward compatibility

Documentation/skill-text only. No hook, `.stride.md`, or wire-shape change. The build loop is unchanged; only the create-intent path gains an explicit stop.

## [2.20.0] - 2026-06-24

Distribution release: stride-copilot is now published in a GitHub Copilot CLI marketplace, [`cheezy/stride-copilot-marketplace`](https://github.com/cheezy/stride-copilot-marketplace). This **supersedes the "there is no marketplace" divergence note** carried by earlier entries — going forward stride-copilot is distributed through that marketplace (the historical entries below remain as written, accurate as of their dates). Delivered under goal G266 (W1318 README, W1319 marketplace sync doc, W1320 this release).

### Added

- **`README.md`** (W1318) — the Installation section now documents the marketplace install path as the recommended option: `copilot plugin marketplace add cheezy/stride-copilot-marketplace` then `copilot plugin install stride-copilot`. The direct-from-repository install (`copilot plugin install https://github.com/cheezy/stride-copilot`) is retained as a labeled alternative.
- **`cheezy/stride-copilot-marketplace` `RELEASE.md`** (W1319) — the marketplace repo gained a documented sync/release process: each plugin is vendored as a pinned copy under `plugins/<name>/`, so a new stride-copilot release must re-vendor the tree (excluding `.git` and secrets) and bump the `marketplace.json` plugin entry version to match this `plugin.json` version. That re-sync is tracked separately (W1321).

### Backward compatibility

Documentation/distribution-only: no wire-shape, hook, `.stride.md` / `.stride_auth.md`, or `.gitignore` change. Existing direct-URL installs continue to work unchanged; the marketplace is an additional install path, not a replacement.

## [2.19.0] - 2026-06-20

Parity release: ports the canonical stride **v1.30.0** change (goal G254), documenting the `created_by_agent` task field across the Copilot creation skills. Copilot divergences are preserved: agents keep the `.agent.md` suffix and there is no marketplace. Delivered under task W1234.

### Added

Agent-created tasks previously landed with `created_by_agent` nil, so the `/agents` activity feed rendered an uninformative `?` avatar on every `created` row. The creation skills now document the field on the create request bodies:

- **`skills/stride-creating-tasks/SKILL.md`** — `created_by_agent` added to the complete-task example, the Field Quick Reference table (string, create-only, forbidden on `PATCH`), and an explanatory note: set it to the plugin's own agent name (`"GitHub Copilot"` — the exact value sent as `agent_name` on claim/complete), never the `ai_agent:<model>` token form, so one agent stays one roster identity.
- **`skills/stride-creating-goals/SKILL.md`** — `created_by_agent` added to the batch goal example with a note that the server propagates the goal's value to every nested child task.

Documentation-only: no wire-shape, hook, or auth change; `created_by_agent` is optional on create, was already accepted by the API, and is forbidden on `PATCH`.

## [2.18.0] - 2026-06-19

Parity release: ports the canonical stride **v1.29.0** change (goal G243 → Copilot goal G244), documenting the `technical_details` task field across the Copilot variant. Copilot divergences are preserved: agents keep the `.agent.md` suffix and there is no marketplace.

### Added

- **`technical_details` task field documentation** (W1183–W1185 — canonical **v1.29.0**, G243/W1179–W1181) — `technical_details` is an **optional, free-form JSON object** (arbitrary keys/values) a task may carry for any additional technical context that does not fit the structured fields — data shapes, gotchas, key decisions, reference links. Unlike `testing_strategy` it has **no fixed keys**, and it is **not** one of the five review_queue-scored fields (`acceptance_criteria`, `testing_strategy`, `security_considerations`, `pitfalls`, `patterns_to_follow`), so a blank `{}` is never a scoring gap. Documented consistently in the creation contracts (`skills/stride-creating-tasks/SKILL.md` Field Quick Reference, complete-task example, Embedded Object Formats — contrasted with `testing_strategy`; `skills/stride-creating-goals/SKILL.md` nested-task note), the enrichment/decomposition guidance (`agents/task-enricher.agent.md` + `skills/stride-enriching-tasks/SKILL.md` — optional, populate from discovered context only, never fabricated, no secrets; `agents/task-decomposer.agent.md` MAY-carry note), and the workflow/exploration references (`skills/stride-workflow/SKILL.md` Step 1 review list; `agents/task-explorer.agent.md` folds it into the summary).

### Backward compatibility

Documentation-only. No wire-shape, hook, or `.stride.md` / `.stride_auth.md` change; `technical_details` is optional everywhere it appears and is never added to any scored-field set, so tasks that omit it behave exactly as before.

## [2.17.0] - 2026-06-13

Parity release: brings the Copilot variant up from canonical stride v1.23.0 to **v1.28.0**, porting five canonical releases (goal G229). Copilot divergences are preserved, not "fixed" toward canonical: agents keep the `.agent.md` suffix, there is no `AGENTS.md` (README is the doc surface), there is no marketplace, and the review-block extraction lives in `skills/stride-subagent-workflow/SKILL.md` rather than `stride-workflow` Step 6. Already-shipped items (reviewer `project_checks`/`not_applicable` enum, `security_considerations` scoring, the base64 `changed_files` envelope, and the `reviewer_result` verbatim passthrough) were **not** re-ported.

### Added

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`, `hooks/hooks.json`** (W1118 — canonical **v1.25.0**, W1093–W1096) — *changed_files survives an `after_doing` timeout.* The per-file diff snapshot is now captured and uploaded **before** the `after_doing` gate commands run (early `finalize_after_doing` / `Invoke-FinalizeAfterDoing`, gated on the GLOBAL `$HOOK_NAME` so `after_goal` stays inert), then refreshed after the gate succeeds. A new `.stride-diff-upload-state` file records the last upload outcome (task id + HTTP code only — never credentials), and the `before_review` hook self-heals on a fresh timeout budget: it re-verifies that state and re-captures + re-uploads when no healthy 2xx is on record for the current task (a successful upload is never repeated). Shared helpers `upload_changed_files_snapshot` + `record_diff_upload_state` (bash) and `Invoke-ChangedFilesUpload` + `Write-DiffUploadState` (PowerShell). Both Bash hook timeouts in `hooks.json` rise from 120s to **300s**, `.gitignore` gains `.stride-diff-upload-state`, and the README documents the `after_doing` time budget. The PowerShell upload helper recovers the real HTTP code from a `WebException` so non-2xx outcomes are recorded without `-SkipHttpErrorCheck` (preserves PowerShell 5.1 support).

### Fixed

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** (D68 — canonical **v1.26.0**, D65) — *a passing `after_doing` gate no longer renders as a red hook error.* Each successful command's tail-truncated (50-line cap) stdout/stderr is folded into a new `commands_output` array on the success JSON instead of being written to stderr (which Claude Code mislabels as an error even on exit 0). The failure branch is unchanged; the no-jq degraded path still emits no success JSON. `commands_output` is encoded via `jq --arg` / `ConvertTo-Json` so command output cannot inject JSON fields.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** (D69 — canonical **v1.27.0**, D67) — the hook's own `.stride-diff-upload-state` and `.stride-changed-files.json` are excluded from the `changed_files` snapshot (bash capture and PowerShell upload), anchored to **exact repo-root paths** so a same-named file in a subdirectory is still captured.
- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** (W1119 — canonical **v1.28.0**, G224/W1086+W1087) — the claim-time `TASK_BASE_REF` refresh is now **unconditional on every detected claim**, with a persisted-output-file fallback that recovers the claim API JSON from a "Full output saved to: …" notice (validated as an existing regular file and parsed read-only — never sourced or executed) so an oversized claim response no longer leaves a stale base ref that makes `changed_files` span unrelated commits. The PowerShell hook now **writes `TASK_BASE_REF` for the first time** and guards property access with `PSObject.Properties.Name` against StrictMode throws.

### Updated

- **`agents/task-reviewer.agent.md`, `skills/stride-subagent-workflow/SKILL.md`, `skills/stride-completing-tasks/SKILL.md`, `skills/stride-workflow/SKILL.md`** (W1117 — canonical **v1.24.0**, G222/W1072–W1076, hardening-only — plus D66 from canonical v1.26.0) — the reviewer dispatch now passes **every** review field the task supplies (adds `security_considerations`, `description`, `what`, `why`); `not_assessed` is reserved strictly for task-empty sections; `reviewer_result` is a mechanical whole-object copy guarded by a **non-bypassable pre-submission self-check** (every section present, `project_checks` count matches, and — D66 — `acceptance_criteria` is an exact 1:1 verbatim restatement of the task's criterion lines with a re-review count self-check).

### Testing

- `hooks/test-stride-hook.sh` (217 assertions) and `hooks/test-stride-hook.ps1` (168 assertions) both pass, including new groups for the early-capture + self-heal (W1118), the `commands_output` D65 contract (D68), the D67 artifact exclusion (D69), and the claim-time base-ref refresh (W1119 — the PowerShell suite's first git-backed fixtures). As part of W1118, the PowerShell test harness was also repaired for PowerShell 7.x (process spawning switched from arg-splitting `Start-Process` to `ProcessStartInfo`, plus StrictMode `$null.Count` guards).

### Source

Goal G229 — five canonical ports: v1.24.0 (G222), v1.25.0 (W1093–W1096), v1.26.0 (D65+D66), v1.27.0 (D67), v1.28.0 (G224). No marketplace pin update — stride-copilot is not distributed through a marketplace.

## [2.16.0] - 2026-06-08

Parity release: brings the Copilot variant to G220/G219 parity for the reviewer `project_checks` `not_applicable` status and full-checklist emission (canonical: stride v1.23.0, commit a4e7e6f, W1057). Feature minor (2.15.0 → 2.16.0).

### Updated

- **`agents/task-reviewer.agent.md`** — The `project_checks[]` per-entry `status` enum gains a third value, **`not_applicable`**, alongside `met` / `not_met`, and the reviewer is now required to **emit one entry for every top-level `CODE-REVIEW.md` bullet — never omit one**. Previously, with only `met` / `not_met` available, the reviewer silently dropped bullets that had no bearing on the diff under review (a small one-line fix surfaced only 2 of ~9 checks), so the Kanban review queue's "Code review" panel rendered a partial, ambiguous checklist. Now bullets that do not apply are marked `not_applicable` with a one-line reason in `evidence`; `not_applicable` is **approval-neutral** — it produces no paired `issues[]` entry and never contributes to `changes_requested` (only `not_met` does). `schema_version` bumps `"1.3"` → `"1.4"`, and the worked example demonstrates a `not_applicable` row.
- **`README.md`, `skills/stride-completing-tasks/SKILL.md`, `skills/stride-workflow/SKILL.md`, `skills/stride-subagent-workflow/SKILL.md`** — All example/prose `schema_version` strings bumped `"1.3"` → `"1.4"` in lockstep so no stale `"1.3"` remains; the README schema summary now notes the `met`/`not_met`/`not_applicable` enum and full-checklist emission.

### Backward compatibility

Documentation/agent-prompt change only — no wire-shape, hook, `.stride.md`, `.stride_auth.md`, or `.gitignore` changes. The change is additive: `reviewer_result` is stored as `:jsonb` by the Kanban server and persisted verbatim (the v2.15.0 passthrough change), so the new `not_applicable` status value flows through with no consumer edit. Payloads from reviewers on the prior `"1.3"` schema (emitting only `met` / `not_met`) remain valid. The Kanban review-queue panel renders `not_applicable` as a neutral "N/A" pill (kanban-side, ships independently).

### Source

W1060 under goal G220 — the Copilot port of W1057 (reviewer `not_applicable` status + full-checklist emission) from goal G219. The canonical implementation is stride v1.23.0 (commit a4e7e6f). No marketplace pin update — stride-copilot is not distributed through a marketplace.

## [2.15.0] - 2026-06-08

Bundled release covering two ports from the main `stride` plugin (G217 + G218 parity).

### Added

- **`hooks/stride-hook.sh`, `hooks/stride-hook.ps1`** (W1044 / D61) — The `after_doing` hook now uploads the per-file diff snapshot to `/api/tasks/:id/changed_files` as a **transport-encoded envelope** — `{"changed_files":{"encoding":"base64","data":"<single-line-base64>"}}` — instead of the raw `{"changed_files":[...]}` array. An edge request filter (WAF) in front of the Stride server can misread a dense code diff as an attack payload and silently drop the upload, leaving `changed_files` empty in the review queue; base64-wrapping the body neutralizes that false positive while the server decodes it back to the identical list. Falls back to the raw `{"changed_files":[...]}` object when `base64` is unavailable (never a bare top-level array). A non-2xx upload response is now surfaced as a stderr warning rather than discarded (non-fatal to completion; the bearer token is never logged). The PowerShell mirror uses `[System.Convert]::ToBase64String` and `[Console]::Error.WriteLine`. Hook test suites (`hooks/test-stride-hook.sh` 140/0, `hooks/test-stride-hook.ps1`) assert the encoded envelope, raw-text absence, and base64 round-trip.

### Fixed

- **`skills/stride-subagent-workflow/SKILL.md`** (W1052 / D63) — The "Extracting the structured review block" guidance built `reviewer_result` from a hand-maintained enumerated copy-list of structured keys that omitted `project_checks`, so the reviewer's CODE-REVIEW.md per-bullet audit was silently dropped on completion and the Kanban review queue's **Code review** panel rendered nothing. The guidance is now a **verbatim passthrough**: copy the reviewer's entire parsed JSON object into `reviewer_result` and overlay only the legacy summary fields. The fallback (no parseable JSON block) was inverted to a legacy-only send list so it no longer enumerates structured keys either.

### Updated

- **`agents/task-reviewer.agent.md`** (W1052 / W1049) — Added an explicit **consumption invariant**: the canonical schema is the only place the structured key-set is enumerated, and the completion path MUST persist the reviewer's emitted JSON verbatim and MUST NOT maintain its own allow-list of keys to copy.

### Backward compatibility

Wire-shape: the `changed_files` envelope requires a Stride server that accepts the `base64` / `gzip+base64` encodings on `/changed_files` (ships in the kanban repo); the raw-array fallback path remains byte-compatible with the prior hook. The `reviewer_result` change is documentation/skill-instruction only — `project_checks[]` already existed and is already rendered by the review queue; this release simply stops dropping it. No `.stride.md` / `.stride_auth.md` / `.gitignore` changes required.

### Source

W1044 (D61 base64 changed_files transport port), W1052 (D63 reviewer_result verbatim passthrough + W1049 consumption invariant). Mirrors the main `stride` plugin's 1.22.0 (D61) and 1.22.1 (project_checks) releases.

## [2.14.0] - 2026-06-07

Parity release: brings the Copilot variant to G210 parity by adding `security_considerations` as the **fifth** review_queue-scored field across the creation, enrichment, decomposition, review, completion, and extraction skills/agents. Feature minor (2.13.0 → 2.14.0).

### Added

- **`skills/stride-creating-goals/SKILL.md` + `skills/stride-creating-tasks/SKILL.md` — `security_considerations` as the 5th scored field (mirrors canonical G210).** Adds `security_considerations` everywhere the four-field scored set appears: the review_queue scoring banner, the required/nesting field lists, the minimum-bar list, the Red Flags - STOP list, the Rationalization Table, and the example JSON. `creating-tasks` also gains the `### security_considerations` Embedded-Object-Formats WRONG-vs-RIGHT subsection (array-of-strings shape + the `"None — …"` escape hatch for tasks with no security surface).
- **`skills/stride-enriching-tasks/SKILL.md` + `agents/task-enricher.agent.md` — Step 5 security pass + 17-item checklist.** Expands enrichment Step 5 from "Identify Risks" to "Identify Risks **and Security**" → `pitfalls`, `security_considerations` (input validation/sanitization, authorization boundaries, secret/credential handling, injection surfaces, data exposure). Grows the pre-submission checklist from 16 to **17** items, and threads `security_considerations` through the PATCH/output example JSON, the field-type reminders, and the Red Flags list.
- **`agents/task-decomposer.agent.md` — `security_considerations` Required.** Marks `security_considerations` a Required field in the per-task field table, the single-goal output template, and every one of the four worked-example tasks (array-of-strings with concrete, context-appropriate considerations).
- **`agents/task-reviewer.agent.md` — Step 5 Security Considerations review + schema 1.3.** Adds the "Security Considerations Alignment" review step (gating that the listed considerations were actually implemented), extends the `issues[]` category enum with `"security"`, adds the `security_considerations` per-section verdict object (`passed` | `failed` | `not_assessed`), and extends the consistency rule + review-queue tile list to cover it. Bumps the reviewer `schema_version` **1.2 → 1.3**.
- **`skills/stride-completing-tasks/SKILL.md` + `skills/stride-subagent-workflow/SKILL.md` — `security_considerations` persistence + extraction.** The structured `reviewer_result` block now carries the `security_considerations` section verdict alongside `testing_strategy` / `patterns` / `pitfalls` (all examples + prose verdict-chains + Shape-1 schema + quick-reference cheat-sheet), at `schema_version` **1.3**. The "Extracting the structured review block" section in `stride-subagent-workflow` (Copilot's extraction location) adds `security_considerations` to the verbatim-copy field map, the worked examples (schema 1.3), and the JSON-parse-failure omit-list. `skills/stride-workflow/SKILL.md` gains a delegation note naming the `security_considerations` verdict and pointing to the extraction section.

### Backward compatibility

Documentation/contract-only release. No hook script, parser contract, env-var matrix, or workflow step changed — every `.stride.md` hook behavior is byte-identical to 2.13.0. The `security_considerations` additions are contract additions: older completions that omit the field continue to validate (the server tolerates the structured keys as `:jsonb`, and an absent section renders nothing). All intentional Copilot adaptations are preserved (tool-name vocabulary `read`/`search`/`glob`, the `.agent.md` suffix, the `tools:` frontmatter, the `hooks.json` mechanism, and the extraction-in-`stride-subagent-workflow` divergence from canonical's `stride-workflow` Step 6).

### Source

G210 parity (W1029 creating-goals/creating-tasks, W1030 enriching-tasks/task-enricher, W1031 task-decomposer/task-reviewer, W1032 completing-tasks/subagent-workflow/stride-workflow, W1033 release). Mirrors the canonical stride/ G210 `security_considerations` fifth-scored-field release into the Copilot variant. No marketplace pin update — stride-copilot is not distributed through a marketplace.

## [2.13.0] - 2026-06-05

Parity release: brings the Copilot variant up to the canonical stride 1.18.0–1.20.0 reviewer/creation feature set, plus the D54 credential-resolution fix and an adapter-quality uplift. Feature minor (2.12.1 → 2.13.0).

### Added

- **`agents/task-reviewer.agent.md` — project-level checks (mirrors stride 1.18.0).** Adds a step 6 "Project-Level Checks": read `CODE-REVIEW.md` from the project root (via the `read` tool), parse each top-level Markdown bullet as a standing check (nested sub-bullets are context, not separate checks), map a case-sensitive `CRITICAL:` prefix to severity `critical` (default `important`, prefix stripped), and emit `project_checks[]` (`check` / `source` / `status` / `evidence`). Every `not_met` check requires a paired `issues[]` entry with `category: "project_check"`. When `CODE-REVIEW.md` is absent, `project_checks` renders as `[]`. Bumps the reviewer `schema_version` 1.0 → 1.1 and extends the `issues[]` category enum + the `changes_requested` status rule.
- **`agents/task-reviewer.agent.md` — per-section verdicts + schema 1.2 (mirrors stride 1.19.0 / D58).** Adds the `testing_strategy` / `patterns` / `pitfalls` verdict objects (`passed` | `failed` | `not_assessed` + one-line `note`), the consistency rule (a `failed` verdict must be backed by a matching-category `issues[]` entry and vice-versa), and the three step verdict-recording lines (Pitfall Detection / Pattern Compliance / Testing Strategy Alignment). Bumps the reviewer `schema_version` 1.1 → **1.2**.
- **`skills/stride-completing-tasks/SKILL.md` + `skills/stride-subagent-workflow/SKILL.md` — structured `reviewer_result` persistence (mirrors stride 1.19.0 / D57).** Documents persisting the reviewer's full structured block verbatim as `reviewer_result` (the rich `schema_version` / `status` / `issue_counts` / `issues[]` / `acceptance_criteria[]` / `project_checks[]` / `testing_strategy` / `patterns` / `pitfalls` keys merged with the legacy `dispatched` / `duration_ms` / `issues_found` / `acceptance_criteria_checked` envelope) rather than the thin envelope. The "Extracting the structured review block" subsection (field mapping, omit-unemitted-keys rule, and JSON-parse-failure fallback) lives in **`stride-subagent-workflow`** — Copilot's extraction location, distinct from canonical's `stride-workflow` Step 6. The schema is cited (`agents/task-reviewer.agent.md`), not redefined.
- **`skills/stride-workflow/SKILL.md` + `skills/stride-creating-tasks/SKILL.md` + `skills/stride-creating-goals/SKILL.md` — context-informed creation docs (mirrors stride 1.20.0).** Adds a "Context-Informed Creation" section to the orchestrator and "Consuming Provided Context" sections to the two creation skills (context→field mapping, augment-never-override rule, still-required four review_queue fields, and the unchanged `"goals"` root-key / index-dependency rules). Reframed for Copilot's no-slash-command reality: invocation is activating `stride-workflow` with a creation intent + optional directory path (the orchestrator reads the `.md` bundle via `glob`/`read`), **not** `/stride:create-*` commands — no `commands/` directory is added; the sub-skill `## STOP — orchestrator check` gate is referenced (Copilot has no activation-marker file).

### Changed / Fixed

- **`hooks/stride-hook.sh` + `hooks/stride-hook.ps1` — D54 `changed_files` credential resolution.** `finalize_after_doing` / `Invoke-FinalizeAfterDoing` now resolve the upload URL + Bearer token via new `resolve_stride_api_url` / `resolve_stride_api_token` (bash) and `Resolve-StrideApiUrl` / `Resolve-StrideApiToken` (PowerShell) helpers that read `$PROJECT_DIR/.stride_auth.md` as the **primary** source — matching the production `**API Token:**` line, deliberately NOT `**Local API Token:**` — and fall back to the `$COMMAND` literal extraction. This makes the snapshot PUT work when the agent's completion curl uses `$STRIDE_API_URL` / `$STRIDE_API_TOKEN` shell variables (previously the PUT silently no-opped). Fire-and-forget / non-fatal semantics preserved; the token is never logged. New `test-stride-hook.sh` Group 10 (10a–10g) covers auth-file primary, the API-Token-vs-Local discrimination, the `$COMMAND` fallback, the shell-variable skip, and no-token-logging. Bash suite: 140 passed / 0 failed.
- **`agents/hook-diagnostician.agent.md` — structured-JSON input handling.** Added the "Input Detection and Parsing" section (structured-JSON-from-`stride-hook.sh` detection + raw-text fallback) and the structured-JSON sub-variant of "Structured Output Format" (Command Sequence context), so the diagnostician can parse the structured JSON the plugin's own hook script emits.
- **Adapter uplift + accuracy reconciliation.** Hardened the bash + PowerShell hook scripts (explanatory `set +uo pipefail` comment, after_review cleanup parity for `.stride-changed-files.json`), corrected Copilot vocabulary (hook-script headers and inline comments "Claude Code" → "GitHub Copilot"/host-neutral; skill prose "shell tool" → "the terminal"; stale `.github/agents/` paths → `agents/`), and reconciled all 7 skills + 5 agents + `plugin.json` against canonical — fixing residual drift while preserving the intentional Copilot adaptations (tool-name vocabulary `read`/`search`/`glob`, the `.agent.md` suffix, `plugin.json`, the `hooks.json` PreToolUse/PostToolUse mechanism, bash + PowerShell hook scripts, and the extraction-in-`stride-subagent-workflow` divergence).

### Backward compatibility

The reviewer-schema, structured-`reviewer_result`, and context-creation changes are documentation/contract additions — older completions that still send the thin `reviewer_result` envelope continue to validate (the server tolerates the structured keys as `:jsonb`). The D54 credential-resolution change is the only behavioral change: the `changed_files` PUT now succeeds in the shell-variable-completion-curl case it previously skipped; it remains fire-and-forget and no-ops when neither `.stride_auth.md` nor a `$COMMAND` literal yields a URL+token. All four `.stride.md` hooks produce byte-identical output; the bash test suite is green (140/0).

### Source

G207 (W991 adapter uplift, W992 1.18.0 project_checks, W993 1.19.0/D58 section verdicts, W994 1.19.0/D57 structured reviewer_result persistence, W995 1.19.0/D54 credential resolution, W996 1.20.0 context-threading docs, W997 accuracy reconciliation, W998 release). Mirrors the stride/ **1.18.0** (project_checks), **1.19.0** (section verdicts + structured persistence + D54), and **1.20.0** (context-informed creation) releases into the Copilot variant. No marketplace pin update — stride-copilot is not distributed through a marketplace. No gh release is cut here — that step is human-triggered.

## [2.12.1] - 2026-05-25

### Updated

- **`skills/stride-creating-tasks/SKILL.md`** (W853) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING" callout that names the four fields the review_queue dashboard scores on every completion (`acceptance_criteria`, `testing_strategy`, `pitfalls`, `patterns_to_follow`) and frames the consequence of omitting any of them: a visible, public, persistent **empty pill** on the dashboard that does not get back-filled later. Reinforces the same four fields with four new bullets in the existing **Red Flags - STOP** list and four new rows in the existing **Rationalization Table**. Wording matches the stride/ Claude Code variant for cross-plugin consistency. No new top-level section was introduced; all reinforcement is co-located with existing structures.
- **`skills/stride-enriching-tasks/SKILL.md`** (W854) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING — ENRICHMENT IS THE LAST CHANCE" callout. Promotes `acceptance_criteria`, `testing_strategy`, `pitfalls`, and `patterns_to_follow` to individual mandatory-for-review items in the Phase 4 16-item pre-submission checklist (replacing the prior single-line bundling), each annotated with its specific empty-pill condition. Adds four new Red Flags - STOP bullets matching the existing imperative tone.
- **`skills/stride-creating-goals/SKILL.md`** (W855) — Adds a top-of-file "⚠️ REVIEW QUEUE SCORING — NESTED TASKS ARE NOT EXEMPT" callout stressing the four-field minimum bar applies to every nested task individually — no "it's just a subtask" discount. Strengthens Task Nesting Rules with a per-field block enumerating each scored field with its empty-pill condition. Adds four new Red Flags - STOP bullets and four new Rationalization Table rows specifically targeting nested-task offloading rationalizations.

### Backward compatibility

Content-only release. No hook script, parser contract, env-var matrix, API field shape, or workflow step changed — every behavior is byte-identical to 2.12.0. The three SKILL.md edits strengthen guidance only; existing task-creation, enrichment, and goal-creation calls continue to validate without modification. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required.

### Source

G166 / W853 / W854 / W855 / W856. Patch release — documentation-only emphasis updates across three SKILL.md files. The change set mirrors the stride/ plugin's 1.17.3 release (Claude Code variant) and the goal is to raise the floor on the four fields the review_queue dashboard scores at completion, so empty pills become rare rather than common.

## [2.12.0] - 2026-05-25

### Critical fix

- **`hooks/stride-hook.sh`** and **`hooks/stride-hook.ps1`** — `finalize_after_doing` / `Invoke-FinalizeAfterDoing` now PUT the per-file diff snapshot to Stride immediately after writing `.stride-changed-files.json` to disk, with the body shaped as `{"changed_files": [...]}` (G162 + G174 ports from main stride 1.16.0 + 1.17.2 shipped together). URL and Bearer token are extracted from the intercepted agent completion command in `$COMMAND` / `$Command` (via `grep -oE` and `-match`) — no new top-level env vars (superseded in 2.13.0, which adds `.stride_auth.md` as the primary credential source — see the D54 fix). The PUT is fire-and-forget (`-s ... > /dev/null 2>&1 || true` on bash; `try`/`catch` + `-ErrorAction SilentlyContinue` on PS) and silently no-ops when any prerequisite is missing (`HAS_JQ=false`, no `curl`, no `TASK_ID`, no URL/token in `$COMMAND`, no snapshot file on disk). The on-disk snapshot at `.stride-changed-files.json` is preserved unchanged for legacy `--argjson cf` consumers on older deployments. **G162 and G174 ship together because the wrap is required for the PUT to work at all** — a bare top-level array lands at `params['_json']` under Plug.Parsers, validates as `{:ok, nil}`, and is persisted as NULL, silently clearing `changed_files` on every task completed against a 1.16.0+ server doing real PUT-side processing.

### Added

- **`hooks/test-stride-hook.sh`** — New Test Group 9 (W838) — 6 sub-cases covering PUT-success (URL/token/method/body assertions via a stub `curl` recorded into a fixture, plus wrapped-object body assertion and snapshot round-trip), no-Bearer-token (PUT skipped, snapshot still written), no-`TASK_ID` (PUT skipped), empty-snapshot (`[]` still PUTs as wrapped `{"changed_files": []}`), PUT-failure (stub exits 1, hook still exits 0, snapshot persists), and `HAS_JQ=false` (PUT skipped via the sourced unit-test path). Bash suite total: 131 passed / 0 failed (117 prior + 14 new).
- **`hooks/test-stride-hook.ps1`** — New Test Group 8 (W839) — HttpListener-backed PUT-success test (asserts method, path, Authorization header, body content, wrapped-object shape, snapshot round-trip) plus 4 wrapper-resilience cases (unreachable port doesn't propagate, no snapshot file no-ops, no Bearer token no-ops, no `TASK_ID` no-ops).

### Backward compatibility

The wire-shape fix is fully backward-compatible at the server boundary — a wrapped `{"changed_files": [...]}` body has always been the documented contract. The four existing `.stride.md` hooks (`before_doing`, `after_doing` outer body, `before_review`, `after_review`, `after_goal`) produce byte-identical output to v2.11.0, empirically confirmed by all 117 prior bash tests passing unchanged. The on-disk `.stride-changed-files.json` snapshot is preserved unchanged so legacy `--argjson cf` consumers on older deployments still read it.

### Migration

Install or update via your normal stride-copilot install flow. No `.stride.md`, `.stride_auth.md`, or `.gitignore` changes are required. No marketplace pin update — stride-copilot is not distributed through stride-marketplace. Going forward, every task completed under 2.12.0+ will populate `changed_files` correctly against any Stride server with the `PUT /api/tasks/:id/changed_files` endpoint (kanban W777+). Against pre-1.16.0 servers without that endpoint, the hook PUT 404s harmlessly (fire-and-forget) and the inline-cat pattern in `stride-completing-tasks/SKILL.md` remains the path that carries the snapshot.

### Source

G162 (auto-PUT — bash port W838, PS port W839, test groups W840) + G174 (wrapped body — folded into W838/W839 since shipping the PUT without the wrap is the broken state that made stride 1.17.2 a critical fix). Mirrors the stride/ 1.16.0 + 1.17.2 releases into the Copilot variant. No marketplace pin update — stride-copilot is not on the marketplace per user instruction.

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
