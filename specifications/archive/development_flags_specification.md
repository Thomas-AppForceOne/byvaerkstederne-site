# Development Flags Specification — Grav CMS

Static, environment-driven, fail-closed feature flag system. Configuration-based, type-safe in PHP. No rollouts, user targeting, segmentation, scheduling, remote providers, admin UI, or analytics.

## Core Principles

- All flags declared in code via typed construct — unknown flags are warned and ignored
- Undefined/missing flags resolve to `false`
- Invalid values resolve to `false` (with warning logged)
- Only exact strings `"true"` and `"false"` are accepted — no case normalization
- Disabled features produce zero user-visible references

## Known Flags

```php
// Preferred: PHP backed enum
enum FeatureFlag: string
{
    case CheckoutV2 = 'checkout_v2';
    case PricingExperiment = 'pricing_experiment';
    case PromoBanner = 'promo_banner';
    case PartnerPortal = 'partner_portal';
}
// Fallback: final class with string constants
```

Application code must use `FeatureFlag` values, not raw strings. String-to-enum conversion happens only at the Twig boundary.

## Configuration

Source: Grav config at `features.enabled` (after environment overrides).

```yaml
# user/config/features.yaml (base — empty)
enabled: {}

# user/env/www.hackersbychoice.dk/config/features.yaml
enabled:
  checkout_v2: "true"
  pricing_experiment: "true"
  promo_banner: "false"
```

Environments maintain only the flags they explicitly set.

## Resolution Rules

- Known flag missing from config → `false`
- Known flag value `"true"` → `true`
- Known flag value `"false"` → `false`
- Known flag value anything else → warn + `false`
- Unknown flag name in config → warn + ignore
- `features.enabled` not an array → warn + empty map

A flag is **configured** if its key exists in `features.enabled` (regardless of value validity).
A flag is **disabled** when missing, not configured, invalid, or `"false"`.

## FlagStore API

```php
interface FlagStoreInterface
{
    public function isEnabled(FeatureFlag $flag): bool;    // true only if resolved to enabled
    public function isDisabled(FeatureFlag $flag): bool;   // !isEnabled()
    public function isConfigured(FeatureFlag $flag): bool; // true if key exists in config (even if invalid)
    /** @return list<FeatureFlag> */
    public function getEnabledFlags(): array;              // all flags resolving to true
    /** @return array<string,bool> */
    public function allFlags(): array;                     // all known flags with resolved booleans
    /** @return array{enabled: list<string>, configured: list<string>, all: array<string,bool>} */
    public function debug(): array;                        // full diagnostic snapshot
}
```

`FlagStore` handles only flag parsing/querying. Page filtering and request guarding live outside it, consuming it as a dependency.

## Flag Loading Procedure

1. Read merged Grav config → `features.enabled`
2. If not an array → warn, use empty map
3. Initialize all known flags to `false`
4. For each config entry:
   - Non-string key → skip
   - Unknown flag name → warn, skip
   - Known flag → mark as configured
   - Value not `"true"`/`"false"` → warn, resolve `false`
   - Valid value → resolve normally
5. Store resolved + configured state in `FlagStore`

## Logging

Warn on: non-array `features.enabled`, invalid/non-string keys, unknown flag names, invalid values.

Include context: flag name, raw value, environment (if available).

```text
features.enabled is not an array, defaulting to empty.
Unknown feature flag.
Invalid feature flag value, expected exact string "true" or "false". Defaulting to false.
```

## Template Integration

```twig
{# Required function — accepts string, returns resolved bool #}
{% if feature_enabled('promo_banner') %}
  {% include 'partials/promo-banner.html.twig' %}
{% endif %}

{# Optional — returns all enabled flag names #}
{% for flag in enabled_features() %}
  <li>{{ flag }}</li>
{% endfor %}
```

Unknown string names → warn + return `false`.

## Page-Level Feature Gating

Frontmatter field:

```yaml
---
title: Checkout V2
feature: checkout_v2
---
```

When a page declares `feature` and that flag is disabled:
- Direct request → 404 / not-found
- Page does not render
- No navigation, collection, or listing references shown

Pages without `feature` field are always eligible for display.

Multiple pages can share the same `feature` value to form a grouped feature (e.g., `/partner-portal`, `/partner-portal/getting-started`, `/partner-portal/faq` all using `partner_portal`).

## Hidden References Requirement

When a feature is disabled, filter it from: navigation menus, links, buttons, cards, page collections, related pages, landing page sections, breadcrumbs, search results, sitemap listings, and any other user-facing reference.

Centralize collection filtering in PHP rather than duplicating across templates.

```twig
{% for p in collection %}
  {% set feature = p.header.feature ?? null %}
  {% if not feature or feature_enabled(feature) %}
    <a href="{{ p.url }}">{{ p.title }}</a>
  {% endif %}
{% endfor %}
```

## Acceptance Criteria

**Config**: undefined→false, only `"true"`/`"false"` accepted, invalid→warn+false, unknown→warn+ignore
**API**: all `FlagStoreInterface` methods return correct values per resolution rules
**Rendering**: Twig queries flags via helper; disabled elements not rendered
**Pages**: flagged pages return 404 when disabled, accessible when enabled
**Hidden refs**: disabled features absent from all navigation, collections, and listings
**Safety**: malformed config fails closed; invalid/unknown values never enable features
