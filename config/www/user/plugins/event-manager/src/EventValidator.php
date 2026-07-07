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
        'published', 'title', 'description', 'group', 'event_date',
        'event_time', 'location', 'capacity', 'price', 'button_text',
        'button_url', 'featured', 'featured_tag',
    ];

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
     * Price is a closed choice, stored as the display text the card renders.
     * '' = no price shown on the card. Legacy events keep their free-text
     * prices until they are edited, at which point one of these is chosen.
     */
    public const PRICE_OPTIONS = ['', 'Gratis', 'Brugerbetaling', 'Drop-in'];

    /** Bounded lengths for free-text fields (defense against unbounded payloads). */
    private const MAX_LENGTHS = [
        'description' => 2000,
        'event_time' => 60,
        'location' => 120,
        'capacity' => 60,
        'button_text' => 60,
        'button_url' => 300,
        'featured_tag' => 60,
    ];

    /** @var array<string,string> */
    private array $groupOptions;

    /**
     * @param array<string,string> $groupOptions blueprint `group` enum
     */
    public function __construct(array $groupOptions)
    {
        $this->groupOptions = $groupOptions;
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

        // event_date — strict YYYY-MM-DD and a real calendar date.
        $date = $this->str($data, 'event_date');
        if (!preg_match('/^(\d{4})-(\d{2})-(\d{2})$/', $date, $m)
            || !checkdate((int)$m[2], (int)$m[3], (int)$m[1])) {
            $errors['event_date'] = 'Datoen skal have formatet ÅÅÅÅ-MM-DD og være en gyldig dato.';
        } else {
            $values['event_date'] = $date;
        }

        // button_style + badge — DERIVED from the group, never client-
        // settable: the card colour and the category badge must follow the
        // workshop. Any posted values are ignored.
        $values['button_style'] = self::ACCENT_BY_GROUP[$group] ?? 'primary';
        $values['badge'] = self::BADGE_BY_GROUP[$group] ?? '';

        // price — closed set (select in the form; anything else is tampering).
        $price = $this->str($data, 'price');
        if (!in_array($price, self::PRICE_OPTIONS, true)) {
            $errors['price'] = 'Ugyldig pris — vælg Gratis, Brugerbetaling eller Drop-in.';
        } else {
            $values['price'] = $price;
        }

        // button_url — allowlist, not denylist (§8.1.6): empty (no button),
        // a site-relative path (leading single '/'), or absolute http(s).
        // Everything else — javascript:, data:, vbscript:, protocol-relative
        // //host, bare words — is rejected.
        $url = $this->str($data, 'button_url');
        if ($url !== ''
            && !preg_match('#^/(?!/)#', $url)
            && !preg_match('#^https?://#i', $url)) {
            $errors['button_url'] = 'Linket skal være en side på sitet (fx /vaerksteder) eller en fuld http(s)-adresse.';
        } else {
            $values['button_url'] = $url;
        }

        // Bounded free-text fields.
        foreach (self::MAX_LENGTHS as $field => $max) {
            if ($field === 'button_url') {
                continue; // validated above; length-checked below
            }
            $value = $this->str($data, $field);
            if (mb_strlen($value) > $max) {
                $errors[$field] = 'Feltet er for langt (maks. ' . $max . ' tegn).';
            } elseif (!isset($errors[$field])) {
                $values[$field] = $value;
            }
        }
        if (isset($values['button_url']) && mb_strlen($values['button_url']) > self::MAX_LENGTHS['button_url']) {
            unset($values['button_url']);
            $errors['button_url'] = 'Feltet er for langt (maks. ' . self::MAX_LENGTHS['button_url'] . ' tegn).';
        }

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

    private static function toBool(mixed $value): bool
    {
        return in_array($value, [true, 1, '1', 'true', 'on'], true);
    }
}
