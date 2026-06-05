# feature-flags tests

PHPUnit 10.5 test suite for the feature-flags plugin. Pure unit + a
lightweight Twig integration harness — no Grav boot, no filesystem access
outside `tests/`, no network.

## Running

From inside `config/www/user/plugins/feature-flags/`:

```bash
composer install       # once, pulls phpunit + twig + psr/log under require-dev
./vendor/bin/phpunit   # runs every testsuite defined in phpunit.xml.dist
```

The full suite finishes in under a second on a developer laptop. All
autoloading is handled by Composer's generated `vendor/autoload.php` —
`tests/bootstrap.php` simply requires it.

## Layout

- `tests/Unit/` — per-class unit tests.
  - `FlagStoreTest` — every branch of the resolution table, malformed
    top-level shapes, unknown/non-string keys, `isConfigured` semantics,
    exact `debug()` shape, and verbatim warning-message assertions.
  - `TwigHelpersTest` — the string → enum shim (known/unknown/non-string
    arguments, warning shape, enabled-features listing, store-throws
    safety).
  - `PageGateTest` — pure decision function for `feature:` frontmatter
    gating (every allow/not-found branch, including non-string, empty,
    unknown, store-throws, and authenticated-visitor invariance).
  - `CollectionFilterTest` — iterable/Generator filter, plain-array /
    object / flat-row entry shapes, order preservation.
  - `FailClosedInvariantTest` — consolidated negative-assertion matrix
    across FlagStore / TwigHelpers / PageGate / CollectionFilter. If a
    refactor accidentally opens a fail-open branch, one of these rows
    goes red before the functional tests.
- `tests/Integration/TwigRenderTest.php` — a real `Twig\Environment` with
  the plugin's helpers registered via `ArrayLoader` template sources.
  Exercises the three spec-mandated snippets end-to-end without touching
  the theme templates under `config/www/user/themes/`.
- `tests/Support/ArrayLogger.php` — minimal in-memory PSR-3 logger double
  used throughout the suite; no Monolog dependency required.
- `tests/fixtures/audit-notes.md` — Sprint 3 audit of templates that
  iterate collections potentially holding gated pages.
- `tests/acceptance-coverage.md` — map from source-spec acceptance bullets
  to the specific `ClassName::methodName` covering each bullet.

## Assertion style — readable failure diffs

The suite follows these conventions so that a broken assertion surfaces
its root cause without forcing a full debug cycle.

1. **Prefer `assertSame` over `assertEquals`.** `assertSame` uses strict
   comparison and prints the full diff when arrays disagree; `assertEquals`
   collapses type differences and can hide e.g. `'1'` vs `1` bugs.
2. **Label `dataProvider` rows.** Use string keys on the returned map so
   PHPUnit prints `FlagStoreTest::testInvalidStringValueFailsClosed with
   data set "upper-TRUE"` rather than an opaque `#3`.
3. **One behaviour per test method.** A single failure names the
   behaviour, not a whole cluster of unrelated assertions. Pair a narrow
   assertion with a clear `$message` argument (`$this->assertFalse(..., 'Fail-closed path: ...')`).
4. **Assert on the full structure once, not key-by-key.** For example,
   `FlagStoreTest::testDebugShapeIsExactAndOrdered` does a single
   `assertSame([...], array_keys($debug))` so any missing or extra key
   shows up as a single readable diff.
5. **No object dumps in messages.** Context logged by the plugin is
   already normalised to safe scalars (via `FlagStore::safeScalar`), so
   every assertion on log context compares plain strings/ints.

### Demonstration

If you want to see what a failure looks like in practice, temporarily
change one line of `FlagStoreTest::testDebugShapeIsExactAndOrdered`, e.g.

```diff
-        $this->assertSame(
-            ['enabled', 'configured', 'all'],
-            array_keys($debug),
+        $this->assertSame(
+            ['enabled', 'all', 'configured'],   // intentionally wrong order
+            array_keys($debug),
             'debug() top-level keys must be exactly [enabled, configured, all] in order.'
         );
```

Running `./vendor/bin/phpunit --filter=testDebugShapeIsExactAndOrdered`
prints a three-line unified diff of the two arrays plus the custom
message — not a var_dump of the whole FlagStore. Revert the change
before committing.

## What the suite deliberately does not cover

- **Live Grav page rendering** (homepage, `/roadmap`, modular pages with
  empty `features.enabled`). Verified by the Sprint 3 evaluator against
  the Docker container; re-doing it here would require booting Grav and
  violates the `no_grav_boot_no_filesystem_no_network` criterion.
- **`features.yaml` repo-diff** ("no committed file turns a flag on").
  Enforced at the repository level via the Sprint 1 / Sprint 5 contract
  checks.
- **HTTP routing / Grav event dispatch.** `PageGate::decide` is pure and
  tested directly; the `onPageInitialized` wiring is trivial glue.

See `tests/acceptance-coverage.md` for a full source-spec → test-method
map including the bullets that are deliberately out of scope here.
