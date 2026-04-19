# Source-spec acceptance-criteria coverage map

This file enumerates every bullet from the source spec's "Acceptance Criteria"
sections and names the PHPUnit test class::method that covers it. The source
spec lives at `specifications/development_flags_specification.md`; at PR time
the orchestrating session will write the ADR and delete that spec, so the
headings below quote the bullets verbatim to keep this map self-contained.

Legend:

- **FlagStoreTest** = `tests/Unit/FlagStoreTest.php`
- **TwigHelpersTest** = `tests/Unit/TwigHelpersTest.php`
- **TwigRenderTest** = `tests/Integration/TwigRenderTest.php`
- **PageGateTest** = `tests/Unit/PageGateTest.php`
- **CollectionFilterTest** = `tests/Unit/CollectionFilterTest.php`
- **FailClosedInvariantTest** = `tests/Unit/FailClosedInvariantTest.php`
- **S3-live** = verified live via the Sprint 3 evaluation (`.gan/sprint-3-feedback-*.json`);
  re-testing would require booting Grav and is deliberately out of scope per
  the `no_grav_boot_no_filesystem_no_network` criterion.

## Config

| Source bullet | Covered by |
|---|---|
| `features.enabled` missing / empty / null → every flag resolves `false` | `FlagStoreTest::testMissingKeyIsEnabledFalseIsConfiguredFalseNoWarning`, `FlagStoreTest::testNullEnabledIsEquivalentToEmpty` |
| Non-array top-level shape fails closed with one warning per construction | `FlagStoreTest::testMalformedTopLevelFailsClosedForEveryFlag` (dataProvider: string, int, bool, float), `FlagStoreTest::testNonArrayTopLevelWarningContextShape` |
| Unknown key in config produces warning and is ignored | `FlagStoreTest::testUnknownKeyProducesWarningAndDoesNotAffectKnownKey`, `FlagStoreTest::testUnknownKeyWarningContextShape` |
| Non-string keys (numeric indices) are skipped with a warning | `FlagStoreTest::testNumericKeyIsSkippedWithWarning`, `FlagStoreTest::testMixedUnknownNumericAndValidEachWarnedIndependently` |
| Repo commits `enabled: {}` — no flag is turned on by committed config | `FlagStoreTest::testMissingKeyIsEnabledFalseIsConfiguredFalseNoWarning` (the default ctor input `[]` models this); live repo-diff check is part of the `no_committed_features_enabled_true` criterion from earlier sprints |

## API — resolution table

| Source bullet | Covered by |
|---|---|
| Value exact-string `"true"` → `isEnabled=true`, `isConfigured=true`, no warning | `FlagStoreTest::testExactStringTrueEnables` |
| Value exact-string `"false"` → `isEnabled=false`, `isConfigured=true`, no warning | `FlagStoreTest::testExactStringFalseDisablesWithoutWarning` |
| Any other string (`"TRUE"`, `"yes"`, `"1"`, `""`, `"truthy"`) → false + one warning | `FlagStoreTest::testInvalidStringValueFailsClosedWithExactlyOneWarning` (dataProvider) |
| Non-string scalar (int, float, bool, null) → false + one warning | `FlagStoreTest::testNonStringScalarValueFailsClosedWithExactlyOneWarning` (dataProvider) |
| Array value → false + one warning | `FlagStoreTest::testArrayValueFailsClosedWithWarning` |
| `isConfigured` true when key is present with invalid value | `FlagStoreTest::testIsConfiguredDistinguishesAbsentFromInvalid` |
| `isConfigured` false when key is absent | `FlagStoreTest::testIsConfiguredDistinguishesAbsentFromInvalid` |
| `getEnabledFlags()` returns enum cases | `FlagStoreTest::testEnabledFlagsReturnsEnumCases` |
| `allFlags()` always returns the four declared keys mapped to booleans | `FlagStoreTest::testAllFlagsAlwaysHasFourDeclaredKeys`, `FlagStoreTest::testMalformedTopLevelFailsClosedForEveryFlag` |
| `debug()` shape is `{enabled: list<string>, configured: list<string>, all: array<string,bool>}` exactly | `FlagStoreTest::testDebugShapeIsExactAndOrdered` |

## Rendering (Twig)

| Source bullet | Covered by |
|---|---|
| `{% if feature_enabled('promo_banner') %}` renders iff flag is true | `TwigRenderTest::testEnabledFlagBodyRendersIffTrue`, `TwigRenderTest::testPromoBannerEnabledRendersThreeSpecSnippets` |
| `{{ feature_enabled('not_a_real_flag') }}` → false, warning, no throw | `TwigHelpersTest::testUnknownNameReturnsFalseAndLogsExactlyOneWarning`, `TwigRenderTest::testUnknownFlagInTemplateDoesNotThrowAndLogsWarning` |
| `{% for f in enabled_features() %}{{ f }}{% endfor %}` iterates exact string names | `TwigHelpersTest::testEnabledFeaturesReturnsStringArrayNotEnumCases`, `TwigRenderTest::testPromoBannerEnabledRendersThreeSpecSnippets` |
| Helpers are safe from any template including error page | `TwigRenderTest::testHelpersSafeOnErrorPageLikeTemplate`, `TwigHelpersTest::testFailClosedWhenStoreThrows` |
| Unknown-name / bad-arg path does not throw | `TwigHelpersTest::testNonStringArgumentReturnsFalseAndWarns` (dataProvider), `FailClosedInvariantTest::testTwigFeatureEnabledNeverReturnsTrueForBadArg` |
| Homepage / `/roadmap` / modular page render identically with empty config | **S3-live** (Sprint 3 evaluator verified against live Docker site; `no_visual_regression_empty_config` criterion) |

## Pages

| Source bullet | Covered by |
|---|---|
| Disabled `feature:` header → 404 | `PageGateTest::testKnownDisabledFlagReturnsNotFoundWithoutWarning` |
| Enabled flag → page renders | `PageGateTest::testKnownEnabledFlagAllows` |
| Unknown enum name in frontmatter → 404 + warning | `PageGateTest::testUnknownEnumNameFailsClosedWithWarning` |
| Empty / non-string frontmatter value → 404 + warning | `PageGateTest::testEmptyStringValueFailsClosedWithWarning`, `PageGateTest::testNonStringFeatureValueFailsClosed` (dataProvider) |
| Group gating: pages sharing `feature:` behave identically | `PageGateTest::testKnownDisabledFlagReturnsNotFoundWithoutWarning` + `CollectionFilterTest::testUnknownEnumNameIsStripped` (decision is pure; applies identically to every page with the same header value) |
| Gating applies to authenticated and anonymous visitors alike | `PageGateTest::testGatingDecisionIsIdenticalForAuthenticatedVisitor` |
| Store exception resolves to 404 (does not render) | `PageGateTest::testStoreThrowingResolvesToNotFoundWithWarning` |

## Hidden references (collections)

| Source bullet | Covered by |
|---|---|
| Entry without `header` passes through | `CollectionFilterTest::testNoFeatureHeaderPassesThrough` (plain rows), `CollectionFilterTest::testGravLikePageObjectIsHandled` (plain object) |
| Entry with header but no `feature` key passes through | `CollectionFilterTest::testNoFeatureHeaderPassesThrough` |
| Entry with enabled `feature` passes through; order preserved | `CollectionFilterTest::testEnabledFlagPassesThroughAndPreservesOrder` |
| Entry with disabled `feature` is stripped | `CollectionFilterTest::testDisabledFlagIsStripped` |
| Entry with unknown `feature` enum name is stripped | `CollectionFilterTest::testUnknownEnumNameIsStripped` |
| Entry with non-string / empty-string `feature` value is stripped | `CollectionFilterTest::testNonStringFeatureValueIsStripped` (dataProvider), `CollectionFilterTest::testEmptyStringFeatureValueIsStripped` |
| Generator / iterator input is supported | `CollectionFilterTest::testAcceptsGenerator` |
| Grav-Page-like objects with `header()` method supported | `CollectionFilterTest::testGravLikePageObjectIsHandled` |
| Flat-row top-level `feature` key supported | `CollectionFilterTest::testFlatRowWithTopLevelFeatureKey` |
| Audit of existing theme templates is documented | `tests/fixtures/audit-notes.md` (committed audit record) |

## Safety / fail-closed invariant

| Source bullet | Covered by |
|---|---|
| Every unknown / missing / malformed / ambiguous input resolves to `false` | `FailClosedInvariantTest::testFlagStoreNeverResolvesTrueForMalformedInput` (dataProvider), `FailClosedInvariantTest::testTwigFeatureEnabledNeverReturnsTrueForBadArg` (dataProvider), `FailClosedInvariantTest::testPageGateNeverRendersForBadOrDisabled` (dataProvider), `FailClosedInvariantTest::testCollectionFilterStripsBadOrDisabled` (dataProvider) |
| Three spec-mandated warning messages fire verbatim with correct context | `FlagStoreTest::testInvalidValueWarningMessageAndContextAreVerbatim`, `FlagStoreTest::testUnknownKeyWarningContextShape`, `FlagStoreTest::testNonArrayTopLevelWarningContextShape` |
| Log context contains no stack traces, request bodies, session, or PII | `PageGateTest::testLogContextDoesNotLeakSensitiveData`, `TwigHelpersTest::testWarningContextContainsEnvironmentButNoSensitiveData` |
| Long raw values are truncated before reaching logs | `PageGateTest::testLongFlagNameIsTruncatedInLogs`, `TwigHelpersTest::testLogMessageDoesNotLeakLongRawStrings` |
| No real filesystem / network / Grav boot in the test suite | Enforced by `phpunit.xml.dist` (no Grav bootstrap); grep for `file_get_contents`, `curl_`, `fopen` across `tests/` returns zero results |

## Notes

- The "no committed config file turns any flag `true`" and "empty `user/config/features.yaml`"
  invariants are covered by repository-level checks in the Sprint 1 contract
  (`no_committed_features_enabled_true`) and re-verified by the Sprint 5
  operator-docs sprint; they are not unit-testable here.
- Live HTTP / visual-regression checks against the homepage, `/roadmap`, and
  modular pages are Sprint 3 concerns (S3-live above).
