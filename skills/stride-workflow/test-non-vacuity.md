# Watch every new test fail once

Step 4 of `stride-workflow` points here. **For every test this task's diff adds or changes, break the behaviour that test guards, run it and watch it go red, put the code back, and run it again to watch it go green.** Write down what you saw as one `break_it` entry per test. A diff that adds or changes no test produces no entries; nothing is owed and nothing is missing.

The record has to come from you. The `task-reviewer` custom agent (`agents/task-reviewer.agent.md`) holds only read, search and glob, so it can study a test but never learn whether the test could ever fail. This fleet kept shipping assertions that stayed green with their code broken: W2035's pins were all met by prose elsewhere in the file, W2036 fired an `ok()` outside its loop, W2034 took a cap of 8 up to 1000 and nothing failed, and W2171 lost two assertions inside an unclosed quote. Fix rounds slipped the same way in W2181 and D337. A reviewer mutating the test by hand caught each one; this procedure makes that a step instead of a lucky accident.

## Which tests owe an entry

- **One entry per assertion the runner reports on.** Here that is a single `assert_*` call in `hooks/test-stride-hook.sh`, or a single `Assert-*` call in `hooks/test-stride-hook.ps1`. In the project you are working on, use its runner's own unit: an ExUnit `test`, a Jest `it`, and so on. Point `test` at the line the assertion sits on.
- **Added** means the diff brings the assertion into being. **Changed** means the diff alters its assertion, its setup, or the text or slice it reads.
- Whitespace, rewrapping or comments, with no assertion or setup line meaning anything new, owe no entry. Unsure? Treat it as changed.
- An assertion the diff never touched owes nothing, even when its file was edited elsewhere.

## The procedure

Work inside the repository the change belongs to. On a plugin task that is the nested plugin repo, never the outer project that contains it.

1. **Hash the tree before the first break.** `git status --porcelain` is not enough by itself: by Step 4 your files already show as modified, so a break left inside one of them changes no status line. Fold content into the hash:

   ```bash
   { git status --porcelain --untracked-files=all; git diff HEAD --binary; git diff --cached --binary; git ls-files --others --exclude-standard -z | xargs -0 shasum; } | shasum
   ```

   Copy the printed hash into your notes. A shell variable dies with its tool call, and a snapshot written to a file would alter the tree it describes. Any hash tool will do if both runs use the same one. A permission-only change can slip through, so check `ls -l` after touching a mode.
2. **Break it with one small edit** at the place that carries the behaviour the assertion checks: invert a condition, change a constant, alter the pinned phrase. An edit the assertion never reads proves nothing. Deleting a file is never the break.
3. **Run the assertion and watch it fail.** Record what you saw as `failed_when_broken`.
4. **Undo that one edit by hand.** Never restore with `git checkout`, `git restore`, `git stash` or `git reset`: each would also throw away the uncommitted work you have in that file.
5. **Run it again and watch it pass.** Record that as `passes_when_restored`.

**When the last assertion is done, hash the tree again. No reviewer dispatch, commit or hook may happen until the second hash equals the first.** On a mismatch, `git diff` shows the leftover edit; reverse it by hand and hash again.

**An assertion that stays green while its code is broken is vacuous.** Repair it — narrow the slice it reads, make its phrase unique, move it inside its loop, close the open quote — and break it again. Record `false` only for one you could not repair, and never turn an observed `false` into `true`.

### Phrases pinned in a document

A text pin is broken by altering the phrase where the rule lives. Before you do, count it in the exact text the assertion reads, by **occurrences, not lines**: `sed -n '<range>p' <file> | grep -oF -- '<phrase>' | wc -l`. `grep -c` counts matching lines and says 1 for a line holding the phrase twice, which is what a markdown link like `[x.md](x.md)` does. A count above 1 means a break at one site leaves the assertion green. Narrow the slice or lengthen the phrase until the count is exactly 1.

Several text pins may share one broken run only when each pinned phrase counts exactly 1 in its slice and no two pinned phrases share text. Every pin in the batch must then go red, and every other assertion must keep its result. Two pins on one line do not overlap unless their phrases do.

Worked case: an assertion pins `x.md` against the whole of a skill whose only mention is the link `[x.md](x.md)`. Changing the link text to `[y.md]` leaves it green, because the target still says `x.md`; the occurrence count of 2 predicted that. Record `failed_when_broken: false`, then pin the whole link or the sentence around it, and break it again until it fails.

## Staying inside the repository

- Edit only the working tree of the repository under change. Create, change or delete nothing outside it.
- **Nothing destructive and nothing on the network**: no `rm -rf`, no history rewrite, no restore by checkout, and no contact with a remote, a package registry, any API, or Stride itself.
- Leave shared state alone. A test's own sandbox is fine; a shared database, global configuration, hook cache files and other processes are not.
- Never break inside a gitignored file. The hash cannot see it, so it cannot prove you put it back.
- **Never commit while a break is in place**, and keep to one broken assertion per run except where the text-pin batching rule permits several.
- An assertion whose break would reach outside the repository gets a one-line `not_broken_reason` in place of a break, with `break` and both booleans set to `null`. "Slow", "obvious" or "trivial" points at no effect beyond the repository, so it does not qualify; break the assertion.

## The `break_it` entries

Four fields — `test`, `break`, `failed_when_broken`, `passes_when_restored` — plus `not_broken_reason` on an assertion you could not break safely:

```json
[
  { "test": "hooks/test-stride-hook.sh:9120", "break": "altered the pinned phrase at skills/stride-workflow/test-non-vacuity.md:7", "failed_when_broken": true, "passes_when_restored": true },
  { "test": "test/app/webhook_test.exs:58", "break": null, "failed_when_broken": null, "passes_when_restored": null, "not_broken_reason": "the guarded retry only fires against a real third-party endpoint" }
]
```

- `test` is a repository-relative path plus a line number or the test's name.
- `break` is one line naming the edit and the `file:line` it landed on.
- The booleans hold what happened, never what you expected.
- No entry quotes a test body, diff text or command output. Anything shaped like a credential is replaced by `[REDACTED — break text embedded a credential]` and located by `file:line` — the same rule in the prompt that invokes the reviewer, in `completion_notes` and in `completion_summary`.

The entries reach the reviewer as `break_it`, through `stride-subagent-workflow` Phase 3. `break_it` travels beside `review_round` and never inside its `fixes[]`, and it adds no key to the reviewer's JSON block. When the decision matrix skips the reviewer, still run the procedure and send nothing, because nobody is there to receive it. When you review your own work instead, hold your entries to the test step 4 of `agents/task-reviewer.agent.md` applies.

## Later review rounds

A fix touches an assertion when it edits that assertion or the code its entry broke. Break every touched assertion again and send its new entry under a prose label saying it is fresh, never a fifth key; send round one's entries unchanged for the rest. With no touched assertion, resend round one's entries as they were. When Step 5's triggers grant no second round, still break every touched assertion again before you complete — fix rounds are where W2181 and D337 slipped. `review_round.fixes[]` says what changed; `break_it` says what was proven, and the two never merge.

## What this cannot prove

The entries are your own account. The reviewer judges each against the diff — does the break touch what the assertion checks? — but it cannot replay one. What changes is that a new test nobody ever watched fail can no longer reach review unremarked.
