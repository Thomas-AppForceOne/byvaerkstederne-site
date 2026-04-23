<?php
/**
 * FeatureFlag — the single typed source of truth for flag names.
 *
 * Application code must never refer to a flag via raw string outside the
 * FlagStore boundary. Adding a new flag is a two-line patch: add a case
 * here with its YAML-config key as the backing string value.
 *
 * These are the 17 rollout-catalogue flags required by the
 * `feature_flag_rollout_specification.md` spec. Each is the canonical
 * identifier used in page frontmatter, Twig guards, PHP handler gates,
 * and the per-environment `features.yaml` profile files.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags;

enum FeatureFlag: string
{
    case Roadmap = 'roadmap';
    case FeatureSuggestion = 'feature_suggestion';
    case BugReport = 'bug_report';
    case CommunityFooterColumn = 'community_footer_column';
    case MembershipSignup = 'membership_signup';
    case NewsletterSignup = 'newsletter_signup';
    case EventHighlight = 'event_highlight';
    case PressPage = 'press_page';
    case MinutesArchive = 'minutes_archive';
    case WorkshopCalendar = 'workshop_calendar';
    case WorkshopCalendarFilters = 'workshop_calendar_filters';
    case WorkshopCalendarFeatured = 'workshop_calendar_featured';
    case WorkshopDetailPages = 'workshop_detail_pages';
    case PressAssetsDownload = 'press_assets_download';
    case PressStats = 'press_stats';
    case ContactPage = 'contact_page';
    case StatutesPage = 'statutes_page';

    /**
     * The 17 rollout-catalogue flag string values, in the order specified by
     * the rollout spec. Used by tests and profile validators that need to
     * assert "every catalogue flag is present".
     *
     * @return list<string>
     */
    public static function catalogueValues(): array
    {
        return [
            'roadmap',
            'feature_suggestion',
            'bug_report',
            'community_footer_column',
            'membership_signup',
            'newsletter_signup',
            'event_highlight',
            'press_page',
            'minutes_archive',
            'workshop_calendar',
            'workshop_calendar_filters',
            'workshop_calendar_featured',
            'workshop_detail_pages',
            'press_assets_download',
            'press_stats',
            'contact_page',
            'statutes_page',
        ];
    }
}
