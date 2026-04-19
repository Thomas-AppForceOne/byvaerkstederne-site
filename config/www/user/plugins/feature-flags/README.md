# feature-flags

A static, environment-driven, fail-closed feature-flag system for the
Byværkstederne Grav site. Flags are declared in PHP, configured in YAML,
and consumed from Twig and page frontmatter. No admin UI, no endpoint, no
persistent storage.

Source spec: [`specifications/development_flags_specification.md`](../../../../specifications/development_flags_specification.md).
The ADR capturing the final design is written by the orchestrating human
session at PR time — sprint workers do not touch `specifications/` or
`decisions/` during implementation.

---

## 1. Declaring a new flag

Adding a flag is a **one-file code change**: append a `case` to the backed
enum in [`src/FeatureFlag.php`](src/FeatureFlag.php). The backing string is
the YAML key operators will set.

```php
enum FeatureFlag: string
{
    case CheckoutV2         = 'checkout_v2';
    case PricingExperiment  = 'pricing_experiment';
    case PromoBanner        = 'promo_banner';
    case PartnerPortal      = 'partner_portal';
    // Add new cases here. No other code change is required — FlagStore,
    // Twig helpers, and page gating pick the new flag up automatically.
}
```

Do not reference flag names as raw strings outside the `FlagStore`
boundary. Twig is the only place raw strings appear; they are validated by
`FeatureFlag::tryFrom()` on every call.

---

## 2. Config layout

Grav merges config in this order (later wins):

| File                                                   | Purpose                                                      |
|--------------------------------------------------------|--------------------------------------------------------------|
| `user/config/features.yaml`                            | Base, committed. Ships as `enabled: {}` — no flags on.       |
| `user/env/<host>/config/features.yaml`                 | Per-environment override. Only loaded when host matches.     |

The plugin reads the merged map via `Grav::instance()['config']->get('features.enabled', [])`.

Values are **quoted strings** — only the literal `"true"` or `"false"` are
accepted:

```yaml
# user/env/staging.example.com/config/features.yaml
enabled:
  checkout_v2: "true"
  pricing_experiment: "true"
  promo_banner: "false"
```

A committed example is at
[`user/env/staging.example.com/config/features.yaml.example`](../../../env/staging.example.com/config/features.yaml.example).
The `.example` suffix keeps it inactive — Grav only loads `features.yaml`.
To activate on a real host, copy it to the matching `user/env/<host>/config/features.yaml`
and run `bin/grav clearcache`.

Secrets, tokens, or credentials must never appear in these files. Values
are constrained to `"true"` / `"false"`.

---

## 3. Resolution rules

`FlagStore::isEnabled(FeatureFlag)` returns one of two booleans using this
four-branch table:

| Input in `features.enabled[<key>]`               | Result  | Warning logged? |
|--------------------------------------------------|---------|-----------------|
| key missing                                      | `false` | no              |
| `"true"` (exact, lowercase, quoted string)       | `true`  | no              |
| `"false"` (exact, lowercase, quoted string)      | `false` | no              |
| anything else: `"TRUE"`, `1`, `true` (bool), `null`, lists, objects, unknown keys, non-array top-level | `false` | yes (`warning`) |

Warnings are emitted via Grav's Monolog at level `warning`, with the flag
name, the raw value (coerced to a safe scalar), and the current
environment in the log context. Warnings never throw.

---

## 4. Fail-closed contract

**Every unknown, missing, malformed, or ambiguous input resolves to `false`.**
A corrupted config must never flip a flag on. This invariant is the single
most important property of the system. It is exercised by
`tests/Unit/FailClosedInvariantTest.php` across FlagStore, TwigHelpers,
PageGate, and CollectionFilter.

Do not weaken validation, suppress warnings, or accept non-string flag
values. Any PR that does is a regression.

---

## 5. Twig usage

Two helpers are registered in `onTwigInitialized`:

```twig
{# Gate a partial #}
{% if feature_enabled('promo_banner') %}
  {% include 'partials/promo-banner.html.twig' %}
{% endif %}

{# Iterate enabled flag names (strings) #}
<ul>
  {% for f in enabled_features() %}
    <li>{{ f }}</li>
  {% endfor %}
</ul>
```

An unknown string argument (not a declared enum case) returns `false` and
logs a warning — it never throws, so error pages and partials stay safe.

A Twig filter `|feature_visible` is also available for filtering page
collections in listings / navigation / related-pages / children loops:

```twig
{% for child in page.children|feature_visible %}
  <a href="{{ child.url }}">{{ child.title }}</a>
{% endfor %}
```

---

## 6. Page frontmatter gating

A page can be gated by adding a single frontmatter key:

```yaml
---
title: Checkout v2 Landing
feature: checkout_v2
---
```

Behaviour:

- Flag resolves `true` → page renders as normal.
- Flag resolves `false`, or the `feature:` value is not a declared enum
  case → the page returns **404** to every visitor (authenticated and
  anonymous alike; no admin bypass).
- **Group gating**: multiple pages sharing the same `feature:` value are
  all hidden or all shown together — there is no per-page state.
- A page without a `feature:` key is untouched by the plugin.

Disabled gated pages are also stripped from any collection processed by
`|feature_visible` (navigation, children, sitemap, etc.) so they cannot
leak via listings.

---

## 7. Running the tests

PHPUnit 10.5 suite lives in [`tests/`](tests/). Pure unit tests plus a
lightweight Twig integration harness — no Grav boot, no filesystem access
outside `tests/`, no network.

From inside `config/www/user/plugins/feature-flags/`:

```bash
composer install       # once — installs phpunit, twig, psr/log under require-dev
./vendor/bin/phpunit   # runs every testsuite in phpunit.xml.dist
```

The full suite finishes in well under the 5-second budget on a developer
laptop. See [`tests/README.md`](tests/README.md) for suite layout,
assertion conventions, and the per-acceptance-bullet coverage map at
[`tests/acceptance-coverage.md`](tests/acceptance-coverage.md).

---

## 8. References

- Source spec: [`specifications/development_flags_specification.md`](../../../../specifications/development_flags_specification.md).
- Roadmap entry: [`specifications/ROADMAP.md`](../../../../specifications/ROADMAP.md) item #1.
- ADR: not yet written. The orchestrating session writes an ADR in
  `decisions/` at PR time per the repository `CLAUDE.md` lifecycle, and
  deletes the source spec in the same PR. Sprint workers must not modify
  `specifications/` or `decisions/`.
