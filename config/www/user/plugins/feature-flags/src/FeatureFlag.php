<?php
/**
 * FeatureFlag — the single typed source of truth for flag names.
 *
 * Application code must never refer to a flag via raw string outside the
 * FlagStore boundary. Adding a new flag is a two-line patch: add a case
 * here with its YAML-config key as the backing string value.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags;

enum FeatureFlag: string
{
    case CheckoutV2 = 'checkout_v2';
    case PricingExperiment = 'pricing_experiment';
    case PromoBanner = 'promo_banner';
    case PartnerPortal = 'partner_portal';
}
