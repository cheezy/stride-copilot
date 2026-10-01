# Releasing stride-copilot

Shipping a version of this plugin means two repositories: this one (manifest,
changelog, tag, GitHub release) and `stride-copilot-marketplace`, which holds a
pinned, vendored copy of this tree. Copilot CLI users who install through the
catalog only see a release once it has been vendored there.

## The three facts

**Where the version lives.** The root `plugin.json` (`"version"`) — this
repository has no `.copilot-plugin/` directory and no `package.json`; the root
file is the manifest. Nothing in this repository tests it against the
changelog. The catalog repeats the value in two more places, both owned by its
runbook: the entry in `.github/plugin/marketplace.json` and the README Plugins
table row.

**Changelog shape: three variants in the record — no settled rule.** Recent
versions show all of these:

- **Appended, then stamped:** work commits add entries under
  `## [Unreleased]`, and a release commit renames the heading and bumps
  `plugin.json` (2.34.0, 2.35.0).
- **Written by the release commit:** the release commit adds the heading,
  the entry and the bump together (2.36.0, 2.40.0).
- **Written by the work commit:** the work commit itself opens the dated
  heading and bumps the manifest, and the tag lands later (2.37.0, 2.38.0,
  2.41.0).

Since 2.41.0 the file is back to the first shape, with entries accumulating
under `[Unreleased]`, so the next release stamps that heading.

**Catalog: `stride-copilot-marketplace` (vendored).** The catalog keeps this
tree under `plugins/stride-copilot/`. A sync re-vendors it with `rsync`, moves
the version in the catalog entry and the README row, validates, runs the fleet
drift check and a secret scan, then commits, tags and releases the catalog.
The catalog's own `RELEASE.md` is the runbook — follow it, not a summary.
Two things it stresses are easy to miss: the catalog's `metadata.version` is
not this plugin's version and moves only when a plugin is added, and the
catalog's tag numbers are its own sequence. This file is vendored along with
the rest of the tree; that is expected.

## Before you add to the changelog: is the top heading already tagged?

```bash
git tag -l "v$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -n 1)"
```

The command checks the newest numbered heading and skips `[Unreleased]`. Any
output means that version is tagged and closed: new entries go under
`[Unreleased]`, never under it. The lite ports once appended to a released
heading and had to move the entries to a new version; this is the check that
would have caught it.

## Steps

1. Run the gates:

   ```bash
   bash hooks/test-stride-hook.sh
   pwsh -File hooks/test-stride-hook.ps1
   ```

   and the fleet drift check from the `stride` repository
   (`bash scripts/check-port-canon.sh`, run there).

2. Run the top-heading check. Confirm every commit since the last tag
   (`git log --oneline "$(git describe --tags --abbrev=0)"..HEAD`) has an
   entry; then rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and set
   `"version"` in `plugin.json` to `X.Y.Z` in one commit on `main`. Push
   `main`.

3. Tag the release commit (annotated) and push the tag:

   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

4. Publish the GitHub release from the changelog entry:

   ```bash
   gh release create vX.Y.Z --repo cheezy/stride-copilot --notes-file <notes.md>
   ```

5. Re-vendor into `stride-copilot-marketplace` by following its `RELEASE.md`,
   then tag and release the catalog.

## Known gaps on the record

- Three older tags without a GitHub release are recorded, as an accepted gap,
  in the changelog's "Release record" note. Two later tags, `v2.37.0` and
  `v2.38.0`, also have no GitHub release and are **not** yet recorded there —
  decide at the next release whether to record them the same way.
- Several early changelog versions were never tagged.
- Tags are a mix of annotated and lightweight; use annotated.
