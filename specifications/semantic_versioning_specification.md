# Specification — Semantic version + build number display for apex and site

Status: Planned
Owner: thomas@appforceone.dk
Depends on: nothing (the apex landing page introduced in PR #9 already
shows a SemVer label baked in by `deploy/deploy.sh` — this spec
formalises, decouples it from the deploy script, and adds an
auto-maintained build number alongside).
Scope: Track and display a SemVer version number plus an automatically
maintained build number for the apex selector page and for the Grav
site. The version comes from a file in the repo (single-line edit to
bump). The build number is derived from the commit being deployed and
is identical on every tier that runs that commit. Together the two
must be a property of the code, not of the deploy step.

---

## Motivation

The apex landing page (`hackersbychoice.dk`) currently shows
"Version 0.1.0" on each tier card and in its own footer. That number is
read from a single `VERSION` file at the repo root, baked into a
per-tier `version.json` by `deploy/deploy.sh`, and read back by
`apex/index.php` at request time.

This works but has three problems:

1. **One number, two components.** The apex selector and the Byværkstederne
   site itself are separate pieces of software that will evolve at
   different paces. A single `VERSION` conflates them.
2. **No version is shown on the site itself.** The Grav site has no
   visible version anywhere. A super user looking at the test or
   staging surface cannot tell which version they are exercising
   without going back to the apex selector.
3. **Version is a property of the deploy, not the code.** Today the
   number you see at request time depends on what `deploy.sh` wrote
   into `version.json` at deploy time. Two deploys of the same commit
   could in principle differ. The displayed version should be derivable
   purely from the source tree at the deployed commit.
4. **No automatic build number to disambiguate identical SemVers.**
   Between version bumps the team will commit dozens of small fixes —
   typos, copy tweaks, css adjustments — that don't merit a SemVer
   bump but do change what's deployed. Two deploys both labelled
   "Version 0.1.0" today are indistinguishable from the displayed
   string. We want a build number alongside that increments
   automatically, so commit-level differences are visible without
   needing to read git history.

We want both surfaces to declare their version in a file they own,
have it read at request time, and have a bump be a single-line edit
that needs nothing more than a regular deploy to take effect — plus a
build number that is regenerated automatically on every deploy and
that is **identical** for every tier running the same commit.

---

## Non-goals

- **Automatic SemVer bumping** based on commit messages or
  conventional-commits parsing. Bumps are manual edits.
- **Release notes / changelog generation.** Tracking *what changed in
  each version* is a separate concern (see "Future work" at the bottom
  of this doc).
- **Synchronising apex and site versions.** They are intentionally
  independent. If they happen to align that's fine, but it isn't a
  requirement and tooling will not enforce it.
- **Git tags.** Tagging the repo at each release is welcome practice
  but is not part of this spec.
- **Per-tier version differences.** A given commit produces one apex
  version and one site version, regardless of which tier it is
  deployed to. The build number derives from the commit and so is
  also identical across tiers running that commit.
- **Build numbers tied to deploy time, environment, or operator.**
  Two deploys of the same commit must produce the same build number.
  That rules out timestamps, CI run numbers, environment-prefixed
  counters, and anything else that varies between deploys of identical
  source. The build number is a function of the commit only.

---

## Files of record

Two version files, each owned by the component it labels — manually
edited. Plus two build-number markers per component, written
automatically by the deploy script.

### Manually edited (tracked in git)

| Component | Path                | Content              |
|-----------|---------------------|----------------------|
| Apex      | `apex/VERSION`      | One line, SemVer 2.0.0 |
| Site      | `config/www/VERSION`| One line, SemVer 2.0.0 |

Each file:

- Contains a single SemVer string (`MAJOR.MINOR.PATCH`, optionally with
  pre-release suffix per [SemVer 2.0.0](https://semver.org)). No
  surrounding whitespace beyond a single trailing newline.
- Is plain text, no YAML or JSON wrapping.
- Initial values: both `0.1.0` (matching what the apex currently
  displays).

The repo-root `VERSION` file introduced by PR #9 is removed; it served
its purpose as a placeholder during the topology refactor and is
superseded by the two component-scoped files above.

A version bump is `edit file → commit → deploy`. Nothing else.

### Auto-generated at deploy time (NOT tracked in git)

| Component | Path             | Content                            |
|-----------|------------------|------------------------------------|
| Apex      | `apex/BUILD`     | One integer, count of commits      |
| Site      | `config/www/BUILD`| One integer, count of commits     |

Each `BUILD` file:

- Contains a single integer: the output of
  `git rev-list --count HEAD` against the repo at the commit being
  deployed.
- Is generated by `deploy/deploy.sh` immediately after it has captured
  the deploy metadata, before the package is built.
- Is shipped in the deploy package alongside the corresponding
  `VERSION` file (i.e., into `apex/` for the landing deploy and into
  the Grav root for tier deploys), but is **not** committed to git.
  Its content is purely a function of the commit, so committing it
  would create a chicken-and-egg loop.
- Has the same fallback as `VERSION` (see "Robustness" below).

`git rev-list --count HEAD` is deterministic for a given commit
regardless of who runs it, when, or on which tier. dev/test/staging
all running commit `abc1234` yield the same integer. That is what
satisfies the "remain stable from dev through test, staging and prod"
requirement.

### When does the build number update?

The question hides two clocks. They have different answers.

| Clock | When does the build number change? |
|-------|--------------------------------------|
| The conceptual value | When a commit is added to the deploy branch. The number is `git rev-list --count HEAD`, so it gains 1 with every commit. |
| The deployed BUILD file | When `./deploy/deploy.sh <env>` runs. Computed once per deploy and shipped in the package. |
| What visitors see | After the next deploy of the new commit. |

Three implications worth being explicit about:

1. **dev / test / staging / prod always agree when they're on the same
   commit.** Whoever deploys first writes a BUILD file containing N;
   whoever deploys next on the same commit writes the same N. That is
   how "stable from dev through test, staging and prod" is achieved.
2. **A trivial commit bumps the build number even with no SemVer bump.**
   That's the whole point — the build number disambiguates two
   "Version 0.1.0" deploys that differ by a typo fix. SemVer says
   nothing about typo fixes; the build number does.
3. **The build number for any commit is knowable without deploying.**
   `git rev-list --count <commit>` gives the number that *would* ship
   if that commit were deployed. Useful for a developer who wants to
   reference a build before it's gone out, or for someone debugging
   "which build introduced this bug?" against git history.

Edge cases to be aware of:

- **Force-pushing or rebasing the deploy branch** changes commit
  ancestry, which can change the count. Develop is protected against
  force-push, so this should never happen in practice — but if it does,
  the displayed build numbers across tiers can briefly disagree until
  every tier redeploys.
- **Feature branches in flight** have their own counts (= deploy
  branch count + branch commits). They never display in production
  because feature branches don't deploy directly — they merge into
  develop first. So the count visitors see is always relative to
  develop's history.

### Example values

A normal deploy of develop's tip:

```
Version 0.1.0 · build 247
```

A pre-release SemVer:

```
Version 0.2.0-rc.1 · build 312
```

Component sources for the example above:

| Token        | Source on disk                       | How it got there        |
|--------------|--------------------------------------|-------------------------|
| `0.1.0`      | `apex/VERSION` or `config/www/VERSION` | Manually edited, committed |
| `247`        | `apex/BUILD` or `config/www/BUILD`   | `git rev-list --count HEAD`, written by `deploy.sh` |
| ` · `        | (literal in the template)            | Hard-coded U+00B7 |
| `0.2.0-rc.1` | `…/VERSION`                          | Manually edited (pre-release per SemVer 2.0.0) |

A fallback rendering (BUILD file missing on the deployed instance):

```
Version 0.1.0 · build ukendt
```

A double-fallback (both files missing for that component) — the entire
combined line is omitted from the output rather than rendered as
"Version `ukendt` · build `ukendt`".

---

## Display

### Format

The version and build number always appear together, in this exact
form everywhere they are rendered:

```
Version 0.1.0 · build 247
```

- A literal interpunct (` · `, U+00B7) between the two halves.
- "Version" capitalised, "build" lowercase — Danish convention for
  this register, matches the apex's existing tone.
- Both values plain text, no monospace, no badge styling.
- If the VERSION file is missing/malformed, the line reads
  `Version <em>ukendt</em> · build <N>` (or vice versa for a missing
  BUILD file). If both are missing, the entire line is omitted from
  the rendered output rather than showing two `ukendt`s back-to-back.

### Apex landing page

`apex/index.php` reads `apex/VERSION` and `apex/BUILD` at request
time and renders the combined line on the page. Two places it must
appear:

- **Each tier card** — describes the *tier's content*, so tier cards
  keep reading their tier's `version.json`, where the deploy script
  has stored both the site version (read from `config/www/VERSION` at
  deploy time) and the build number (computed from the deployed
  commit). Format on the card is the same combined line as everywhere
  else.
- **Apex footer** — replace the current "this selector" line. Reads
  from `apex/VERSION` and `apex/BUILD` directly, not from
  `apex/version.json`.

### Grav site

Add a small, unobtrusive version line to the site's footer
(`config/www/user/themes/byvaerkstederne/templates/partials/footer.html.twig`)
in the bottom strip alongside the existing copyright notice. Same
combined format: `Version 0.1.0 · build 247`.

The Twig template reads the values via a helper that loads
`config/www/VERSION` and `config/www/BUILD` once per request and
returns a struct (`{ version: '0.1.0', build: '247' }`), with either
value being `null` when the source file is missing or malformed (see
fallback rules below).

Implementation choices for the Twig helper, in order of preference:

1. **A tiny plugin** (`config/www/user/plugins/site-version/`) that
   exposes a single `site_version()` Twig function returning a
   two-key struct (`{ version, build }`). ~40 lines of PHP. Mirrors
   the shape of the existing `feature-flags` plugin so conventions
   stay uniform.
2. **A Grav config-shipping route**, where the values are read into
   Grav config keys at boot (e.g. via a `system.yaml` interpolation
   or a one-shot in `setup.php`). Less code but harder to discover
   for a future maintainer.

Use option 1 unless review prefers otherwise.

---

## Robustness — what happens when a file is missing or malformed

Reading any of the four files (apex VERSION/BUILD, site VERSION/BUILD)
must never throw a PHP error or break the page. Specifically:

### VERSION (manually edited, tracked)

- **File missing** → return `null` from the helper; display
  `ukendt` (Danish for "unknown") in italics where the SemVer string
  would appear. Log a warning to Grav's log
  (`config/www/logs/grav.log`) once per request. Apex, which has no
  Grav logger, writes to PHP's `error_log()` instead.
- **File present but not a valid SemVer string** → same behaviour as
  missing. The validation regex is `/^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$/`.
  Build metadata (`+...`) is not allowed in the VERSION file; the build
  number lives separately in BUILD. If the team needs to embed it in
  VERSION later, this spec is amended.
- **File present but empty** → treat as missing.

### BUILD (auto-generated, not tracked)

- **File missing** → return `null`; display `ukendt` in italics where
  the integer would appear. Log a warning as above.
- **File present but not a non-negative integer** → same behaviour as
  missing. Validation regex: `/^\d+$/`. Whitespace trimmed before
  matching; values up to 6 digits (millions) are well within
  reasonable expectations.
- **File present but empty** → treat as missing.

If both VERSION and BUILD are missing or invalid for the same component,
the entire combined line is omitted from the rendered output (i.e. no
"Version <em>ukendt</em> · build <em>ukendt</em>" double-fallback).

The point of the fallback is that a deploy with missing or mistyped
files is visually obvious (it shows `ukendt` in public) but doesn't
prevent the page from rendering. A failed deploy should not require
the files to be perfect.

---

## Deploy script changes

`deploy/deploy.sh` is updated to:

1. **Compute the build number once per run** as
   `BUILD="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"` — this is
   the same integer regardless of which `ENV` is being deployed,
   ensuring the build is identical for every tier running the same
   commit.
2. **Apex (`landing` env) build:**
   - Read `apex/VERSION` from the source tree.
   - Write the trimmed value into the deployed `apex/VERSION`
     (rsync would do this naturally; explicit handling not needed).
   - Generate `apex/BUILD` containing just the integer from step 1.
   - Write both values into `apex/version.json`'s `version` and
     `build` fields for ops debugging.
3. **Grav tier (`dev`, `test`, `staging`, `prod`) build:**
   - Read `config/www/VERSION` from the source tree.
   - Ship it as part of the rsync (already handled — it lives under
     the rsync source root).
   - Generate `config/www/BUILD` (i.e. `<deploy-staging-dir>/BUILD`)
     with the integer from step 1.
   - Write both values into the tier's `version.json`'s `version` and
     `build` fields for ops debugging.
4. **Stop reading repo-root `VERSION`.** The script removes that
   reference. The file is deleted from the repo.

The new `version.json` schema:

```json
{
  "tier": "test",
  "version": "0.1.0",
  "build": "247",
  "deployed_at": "2026-04-29T18:00Z",
  "branch": "develop",
  "sha_short": "abc1234"
}
```

`branch` and `sha_short` continue to be written for ops debugging only;
nothing public reads them. `version` and `build` in `version.json`
mirror what the deployed `VERSION` and `BUILD` files contain — they
exist for ops reasons (one place to grep across tiers) and to feed the
apex's tier-card readout, not as a separate source of truth.

The site's own footer reads `config/www/VERSION` directly at request
time (not via `version.json`). This is the "independent of where it is
deployed" part of the requirement: even a Grav install opened directly
in dev or via `bin/grav serve` shows the right version, with no deploy
step in the loop.

---

## Acceptance criteria

A reviewer or test must be able to confirm each of the following.

### File handling

- [ ] `apex/VERSION` exists at repo root with content `0.1.0\n` (one
      trailing newline).
- [ ] `config/www/VERSION` exists with content `0.1.0\n`.
- [ ] Repo-root `VERSION` is removed.
- [ ] `apex/BUILD` and `config/www/BUILD` are listed in `.gitignore`
      (or each component's local `.gitignore`) — they're auto-generated
      and must not be committed.

### Apex display

- [ ] On `https://hackersbychoice.dk` the footer line reads
      "Denne side — Version <X> · build <N> …" where `<X>` matches
      the SemVer in `apex/VERSION` and `<N>` matches the integer in
      `apex/BUILD`.
- [ ] If `apex/VERSION` is renamed/deleted on a deployed instance,
      the footer line reads "Denne side — <em>ukendt</em> · build <N>"
      and the page still renders. (Reverted after the test.)
- [ ] If both `apex/VERSION` and `apex/BUILD` are renamed/deleted,
      the entire "Denne side" line is omitted, not double-fallback'd.
- [ ] The three tier cards render their site version + build number,
      sourced from each tier's `version.json` (which now carries both
      `version` and `build` fields).

### Site display

- [ ] On any of `dev/test/staging.hackersbychoice.dk`, the site footer
      shows a `Version <X> · build <N>` line where `<X>` matches the
      SemVer in `config/www/VERSION` and `<N>` matches the integer in
      `config/www/BUILD`.
- [ ] If either source file is missing, the corresponding half shows
      `ukendt`; the page still renders.
- [ ] The styling of the version line is unobtrusive — small text,
      same colour family as the existing copyright line, no visual
      weight that would distract a regular visitor.

### Stability across tiers

- [ ] Deploying the same commit to dev, test, and staging in any
      order produces the same `build` integer in all three tiers'
      `version.json` files (verified by ssh+cat or by checking the
      rendered footers).
- [ ] Committing one trivial change and redeploying any tier
      increments the build number by exactly 1 there. The other
      tiers, still on the previous commit, continue to show the
      previous build.

### Bump-and-deploy procedure

- [ ] Editing `config/www/VERSION` from `0.1.0` to `0.2.0`,
      committing, and running `./deploy/deploy.sh test` updates the
      footer on `test.hackersbychoice.dk` to "Version 0.2.0 · build
      <N>" where `<N>` is incremented by 1 from the previous deploy
      (because of the version-bump commit). (Revert before merging.)
- [ ] Same procedure for `apex/VERSION` updates the apex footer
      analogously after `./deploy/deploy.sh landing`. (Revert before
      merging.)

### Validation / failure modes

- [ ] An invalid value in either VERSION file (e.g. `0.1`, `latest`,
      empty) results in `ukendt` rendered for the version half;
      page still renders.
- [ ] An invalid value in either BUILD file (e.g. `abc`, empty)
      results in `ukendt` rendered for the build half; page still
      renders.
- [ ] A warning is logged exactly once per request when the
      validation fails (Grav log on the site, PHP `error_log()` on
      the apex).

### Tests

- [ ] Unit test: site-version plugin's `site_version()` function
      returns `{ version, build }` with trimmed file contents on the
      happy path; returns `null` for either field that is missing,
      empty, or invalid.
- [ ] Live HTTP test (anonymous Playwright suite or a small bash
      probe): footers on the apex and on each tier carry a matching
      `Version <semver> · build <N>` substring.

---

## Out-of-scope future work

These are deliberately not part of this spec. They are listed so a
future spec author has a record of what was considered.

- **Per-version release notes / changelogs.** The current placeholder
  on each tier card ("Forbereder første udgivelse") will eventually
  be replaced by a short summary of what shipped in that version. The
  source could be `CHANGELOG.md`, conventional commits, or a separate
  YAML map. Out of scope here.
- **Git tagging at each version bump.** Useful for `git diff
  v0.1.0..v0.2.0` and for GitHub releases, but not required for the
  display.
- **A `bin/bump-version` helper script** that bumps major/minor/patch
  from the command line. Manual edits are fine for now; revisit if
  the bump cadence picks up.
- **Synchronising apex and site versions.** Independent on purpose.
