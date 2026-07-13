<?php
/**
 * EventValidator — server-side re-validation of every client-settable event
 * field (frontend_event_crud_specification.md §8.1.6), independent of any
 * HTML5/client checks and of the Form plugin (whose processing the contract
 * handler pre-empts). Enum options are injected from the blueprint — the
 * single source of truth — never hardcoded here.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager;

final class EventValidator
{
    /**
     * The client-settable form fields, in blueprint order. Server-managed
     * fields (`owner`, `created_*`, `updated_*`, `archived`) are stamped by
     * the handlers and deliberately absent.
     */
    public const FORM_FIELDS = [
        'published', 'title', 'description', 'details', 'group', 'event_date',
        'time_start', 'time_end', 'location', 'capacity_unlimited',
        'capacity_count', 'event_type', 'button_text', 'featured', 'featured_tag',
    ];

    /**
     * The card button is a signup affordance, not a free link: the label is
     * a closed choice and the target is always the event's own detail page
     * (button_url is retired for new/edited events). The RSVP spec builds
     * the actual signup flow on top of this label.
     */
    public const BUTTON_TEXT_OPTIONS = ['Tilmeld', 'Interesseret'];

    /** Suggested rooms for the location field (free text remains allowed). */
    public const LOCATION_SUGGESTIONS = ['Store Rum', 'Lille Rum', 'Plænen'];

    /**
     * Visual accent per workshop group — the single mapping the stored
     * `button_style` is DERIVED from (never a user choice; the button/badge
     * colour must follow the workshop the event belongs to). Values are the
     * closed accent set partials/event_card.html.twig accepts. Both the
     * current blueprint enum keys (kreativ/groenne) and the post-rename
     * candidates (krea/groent, PR #57) are mapped so the derivation
     * survives the rename. Mirrored client-side by the live preview in
     * partials/event_form.html.twig — keep the two in sync.
     */
    /**
     * Card badge per workshop group — derived alongside the accent, never a
     * user choice (matches the badges the legacy seed events carry). Both
     * current and post-rename group keys are mapped, like ACCENT_BY_GROUP.
     * Mirrored client-side by the live preview — keep in sync.
     */
    public const BADGE_BY_GROUP = [
        'alle' => 'Alle grupper',
        'makerspace' => 'Makerspace & Reparation',
        'kreativ' => 'Krea Café',
        'krea' => 'Krea Café',
        'groenne' => 'Grønt BYværksted',
        'groent' => 'Grønt BYværksted',
        'kulturhus' => 'Eventværkstedet',
    ];

    public const ACCENT_BY_GROUP = [
        'alle' => 'primary',
        'makerspace' => 'secondary',
        'kreativ' => 'tertiary',
        'krea' => 'tertiary',
        'groenne' => 'primary',
        'groent' => 'primary',
        'kulturhus' => 'kulturhus',
    ];

    /**
     * Event type is a closed choice, stored as the display text the card
     * renders. '' = nothing shown on the card. Legacy events keep whatever
     * free-text value they carried until edited, at which point one of these
     * is chosen. (Stored field: event_type — historically named `price`.)
     */
    public const EVENT_TYPE_OPTIONS = ['', 'Gratis', 'Brugerbetaling', 'Drop-in'];

    /** Bounded lengths for free-text fields (defense against unbounded payloads). */
    private const MAX_LENGTHS = [
        'description' => 2000,
        'location' => 120,
        'featured_tag' => 60,
    ];

    /** @var array<string,string> */
    private array $groupOptions;

    private DetailsSanitizer $detailsSanitizer;

    /**
     * @param array<string,string> $groupOptions blueprint `group` enum
     */
    public function __construct(array $groupOptions, ?DetailsSanitizer $detailsSanitizer = null)
    {
        $this->groupOptions = $groupOptions;
        $this->detailsSanitizer = $detailsSanitizer ?? new DetailsSanitizer();
    }

    /**
     * @param array<string,mixed> $data raw client payload (form `data[...]`)
     * @return array{values: array<string,mixed>, errors: array<string,string>}
     */
    public function validate(array $data): array
    {
        $errors = [];
        $values = [];

        // title — required, ≤80, no angle brackets (house ^[^<>]{1,80}$ rule;
        // the title reaches flash messages rendered with |raw).
        $title = $this->str($data, 'title');
        if (!preg_match('/^[^<>]{1,80}$/u', $title)) {
            $errors['title'] = 'Titlen skal være 1-80 tegn og må ikke indeholde tegnene < eller >.';
        } else {
            $values['title'] = $title;
        }

        // group — must be a blueprint enum key.
        $group = $this->str($data, 'group');
        if ($this->groupOptions !== [] && !array_key_exists($group, $this->groupOptions)) {
            $errors['group'] = 'Ugyldig værkstedsgruppe.';
        } else {
            $values['group'] = $group;
        }

        // event_date — strict YYYY-MM-DD, a real calendar date, and today or
        // later. Events may not be created or edited into the past (the past-
        // date guard mirrors the editor's date `min`, which is not a trust
        // boundary).
        $date = $this->str($data, 'event_date');
        if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $date, $m)
            || !checkdate((int)$m[2], (int)$m[3], (int)$m[1])) {
            $errors['event_date'] = 'Datoen skal have formatet ÅÅÅÅ-MM-DD og være en gyldig dato.';
        } elseif ($date < self::today()) {
            $errors['event_date'] = 'Datoen kan ikke ligge før i dag.';
        } else {
            $values['event_date'] = $date;
        }

        // button_style + badge — DERIVED from the group, never client-
        // settable: the card colour and the category badge must follow the
        // workshop. Any posted values are ignored.
        $values['button_style'] = self::ACCENT_BY_GROUP[$group] ?? 'primary';
        $values['badge'] = self::BADGE_BY_GROUP[$group] ?? '';

        // event_time — composed from two required native time inputs
        // (HH:MM), end after start; stored in the card's established
        // "HH:MM - HH:MM" shape so rendering and legacy data are untouched.
        $timeStart = $this->str($data, 'time_start');
        $timeEnd = $this->str($data, 'time_end');
        if (!preg_match('/^\d{2}:\d{2}$/', $timeStart) || !preg_match('/^\d{2}:\d{2}$/', $timeEnd)) {
            $errors['time_start'] = 'Vælg både start- og sluttidspunkt.';
        } elseif ($timeEnd <= $timeStart) {
            $errors['time_end'] = 'Sluttidspunktet skal være efter starttidspunktet.';
        } else {
            $values['event_time'] = $timeStart . ' - ' . $timeEnd;
        }

        // capacity — unlimited (default, stored '') or a bounded integer.
        $unlimited = array_key_exists('capacity_unlimited', $data)
            ? self::toBool($data['capacity_unlimited'])
            : true;
        if ($unlimited) {
            $values['capacity'] = '';
        } else {
            $count = $this->str($data, 'capacity_count');
            if (!preg_match('/^\d{1,4}$/', $count) || (int)$count < 1) {
                $errors['capacity_count'] = 'Angiv antal pladser som et tal (mindst 1), eller vælg ubegrænset.';
            } else {
                $values['capacity'] = (string)(int)$count;
            }
        }

        $values['button_url'] = ''; // retired — the card button IS the signup action.

        // event type — closed set (select in the form; anything else is tampering).
        $eventType = $this->str($data, 'event_type');
        if (!in_array($eventType, self::EVENT_TYPE_OPTIONS, true)) {
            $errors['event_type'] = 'Ugyldig begivenhedstype — vælg Gratis, Brugerbetaling eller Drop-in.';
        } else {
            $values['event_type'] = $eventType;
        }

        // button_text is NOT a free choice — it follows the event type and is
        // never client-settable: a Drop-in event is always "Interesseret"
        // (uforpligtende, no fixed signup), every other type is always
        // "Tilmeld". Any submitted button_text is ignored.
        $values['button_text'] = (($values['event_type'] ?? '') === 'Drop-in') ? 'Interesseret' : 'Tilmeld';

        // A Drop-in event never carries a capacity cap — it is uforpligtende, so
        // "unlimited" is not a choice but a rule. The editor locks the capacity
        // field to unlimited for Drop-in; enforce the same server-side so a
        // tampered POST (capacity_unlimited=0 + a count) cannot slip a cap
        // through, and drop any capacity_count error that stale/limited input
        // would otherwise raise.
        if (($values['event_type'] ?? '') === 'Drop-in') {
            $values['capacity'] = '';
            unset($errors['capacity_count']);
        }

        // Bounded free-text fields.
        foreach (self::MAX_LENGTHS as $field => $max) {
            $value = $this->str($data, $field);
            if (mb_strlen($value) > $max) {
                $errors[$field] = 'Feltet er for langt (maks. ' . $max . ' tegn).';
            } else {
                $values[$field] = $value;
            }
        }

        // details — rich WYSIWYG body (§5). Untrusted member HTML: sanitized to
        // the allowlist here on WRITE and stored under the server-managed name
        // details_html. The raw `details` field is never persisted; the stored
        // value is sanitizer output, which is the only reason it may later be
        // rendered with |raw. Size is bounded inside the sanitizer.
        $rawDetails = $data['details'] ?? '';
        $values['details_html'] = $this->detailsSanitizer->sanitize(
            is_scalar($rawDetails) ? (string)$rawDetails : ''
        );

        // published — strict boolean server-side (the blueprint runs
        // validation: loose, so never rely on it). Only a genuinely absent
        // field means "default visible" (§0/§8.1.6).
        $values['published'] = array_key_exists('published', $data)
            ? self::toBool($data['published'])
            : true;

        // featured — same strict coercion; absent means false.
        $values['featured'] = array_key_exists('featured', $data)
            ? self::toBool($data['featured'])
            : false;

        return ['values' => $values, 'errors' => $errors];
    }

    /** @param array<string,mixed> $data */
    private function str(array $data, string $key): string
    {
        $value = $data[$key] ?? '';
        return is_scalar($value) ? trim((string)$value) : '';
    }

    /** Today in Europe/Copenhagen (Y-m-d) — the earliest allowed event date. */
    private static function today(): string
    {
        return (new \DateTimeImmutable('now', new \DateTimeZone('Europe/Copenhagen')))->format('Y-m-d');
    }

    private static function toBool(mixed $value): bool
    {
        return in_array($value, [true, 1, '1', 'true', 'on'], true);
    }
}
