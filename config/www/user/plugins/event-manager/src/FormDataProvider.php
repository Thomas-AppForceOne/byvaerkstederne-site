<?php
/**
 * FormDataProvider — static callables referenced by the event form pages'
 * `data-options@` / `data-default@` blueprint directives (Grav core
 * Blueprint::dynamicData). This is the supported way to make cached
 * page-frontmatter forms dynamic: the directives are evaluated per request
 * when the form blueprint is built, so select options always come from the
 * begivenheder blueprint (single source of truth) and the edit form is
 * prefilled from the stored object of the key in the current URL.
 *
 * Prefill security: the event-manager plugin's route resolution has already
 * 403'd a non-owner before the form renders, but every accessor here
 * re-checks ownership (owner or admin.super) independently — a provider
 * must not leak field values on its own.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager;

use Grav\Common\Grav;

final class FormDataProvider
{
    private const OLD_INPUT_SESSION_KEY = 'em_old_input';

    /** @var array<string,mixed>|null Old input consumed from the session for THIS request. */
    private static ?array $oldInput = null;
    private static bool $oldInputLoaded = false;

    /** @return array<string,string> */
    public static function groupOptions(): array
    {
        return self::repository()->fieldOptions('group');
    }

    /**
     * Price choices for the form select — keys are the stored/displayed
     * values (EventValidator::PRICE_OPTIONS is the single source).
     *
     * @return array<string,string>
     */
    public static function priceOptions(): array
    {
        $options = [];
        foreach (EventValidator::PRICE_OPTIONS as $value) {
            $options[$value] = $value === '' ? 'Ingen prisvisning' : $value;
        }
        return $options;
    }

    /**
     * Button-label choices — keys are the stored values
     * (EventValidator::BUTTON_TEXT_OPTIONS is the single source).
     *
     * @return array<string,string>
     */
    public static function buttonTextOptions(): array
    {
        $options = [];
        foreach (EventValidator::BUTTON_TEXT_OPTIONS as $value) {
            $options[$value] = $value;
        }
        return $options;
    }

    /**
     * Stash a rejected submission so the next form render repopulates the
     * fields instead of losing the member's input (the §8.1.10 PRG error
     * path). Read-once: the next render consumes and clears it.
     *
     * @param array<string,mixed> $data
     */
    public static function stashOldInput($grav, array $data): void
    {
        $session = $grav['session'] ?? null;
        if ($session === null) {
            return;
        }
        $stash = [];
        foreach (EventValidator::FORM_FIELDS as $field) {
            if (array_key_exists($field, $data) && is_scalar($data[$field])) {
                $stash[$field] = (string)$data[$field];
            }
        }
        $session->{self::OLD_INPUT_SESSION_KEY} = $stash;
    }

    /**
     * Repopulation value for one field after a rejected submission (create
     * form), or null to leave the static default. Values render through
     * Twig's attribute escaping, so a hostile stashed value cannot inject.
     */
    public static function oldInputDefault(string $field): mixed
    {
        $old = self::consumeOldInput();
        return $old !== null && array_key_exists($field, $old) ? $old[$field] : null;
    }

    /**
     * The full stashed old input from a rejected submission, consumed
     * read-once, or null. Used by the inline card editor to repopulate its
     * client state after a server-side validation redirect.
     *
     * @return array<string,mixed>|null
     */
    public static function allOldInput(): ?array
    {
        return self::consumeOldInput();
    }

    /**
     * Build the inline card editor's initial client state (event_editor.html.twig)
     * from an optional stored event and optional rejected-submission old input.
     * Precedence: old input (a validation redirect) → stored event (edit) →
     * empty (create). Maps the stored shape onto the editor's shape: event_time
     * → timeStart/timeEnd, capacity → capacityUnlimited/capacityCount,
     * details_html → details.
     *
     * @param array<string,mixed>|null $event    stored event (edit) or null (create)
     * @param array<string,mixed>|null $oldInput rejected submission stash or null
     * @return array<string,mixed>
     */
    public static function editorState(?array $event, ?array $oldInput): array
    {
        $oi = is_array($oldInput) ? $oldInput : [];
        $ev = is_array($event) ? $event : [];

        // time: old input time_start/end wins; else parse the stored
        // "HH:MM - HH:MM" event_time (legacy strings tolerated).
        $timeStart = isset($oi['time_start']) ? (string)$oi['time_start'] : '';
        $timeEnd = isset($oi['time_end']) ? (string)$oi['time_end'] : '';
        if ($timeStart === '' && $timeEnd === '' && isset($ev['event_time'])
            && preg_match('/(\d{1,2}[:.]\d{2}).*?(\d{1,2}[:.]\d{2})/u', (string)$ev['event_time'], $m)) {
            $timeStart = str_pad(str_replace('.', ':', $m[1]), 5, '0', STR_PAD_LEFT);
            $timeEnd = str_pad(str_replace('.', ':', $m[2]), 5, '0', STR_PAD_LEFT);
        }

        // capacity: old input wins; else derive from the stored capacity
        // (numeric ⇒ limited with that count; empty/non-numeric ⇒ unlimited).
        // Create default (neither present): limited (Nej), so a count is asked for.
        $capacityUnlimited = false;
        $capacityCount = '';
        if (array_key_exists('capacity_unlimited', $oi)) {
            $capacityUnlimited = in_array((string)$oi['capacity_unlimited'], ['1', 'true', 'on'], true);
            $capacityCount = (string)($oi['capacity_count'] ?? '');
        } elseif (array_key_exists('capacity', $ev)) {
            $cap = trim((string)$ev['capacity']);
            if (preg_match('/^\d+$/', $cap)) {
                $capacityUnlimited = false;
                $capacityCount = $cap;
            } else {
                $capacityUnlimited = true;
            }
        }

        $published = false;
        if (array_key_exists('published', $oi)) {
            $published = in_array((string)$oi['published'], ['1', 'true', 'on'], true);
        } elseif (array_key_exists('published', $ev)) {
            $published = !empty($ev['published']);
        }

        $pick = static fn (string $oiKey, string $evKey, string $default = ''): string
            => (string)($oi[$oiKey] ?? $ev[$evKey] ?? $default);

        // Date prefill: a stored date in the past is no longer selectable
        // (events must be today or later), so default the field to today so a
        // reactivating edit lands on a valid date. Old input (after a
        // validation bounce) always wins, so the user's own entry is kept.
        $eventDate = (string)($oi['event_date'] ?? $ev['event_date'] ?? '');
        if (!array_key_exists('event_date', $oi) && preg_match('/^\d{4}-\d{2}-\d{2}$/', $eventDate)) {
            $today = (new \DateTimeImmutable('now', new \DateTimeZone('Europe/Copenhagen')))->format('Y-m-d');
            if ($eventDate < $today) {
                $eventDate = $today;
            }
        }

        return [
            'title' => $pick('title', 'title'),
            'group' => $pick('group', 'group'),
            'description' => $pick('description', 'description'),
            'location' => $pick('location', 'location'),
            'eventDate' => $eventDate,
            'timeStart' => $timeStart,
            'timeEnd' => $timeEnd,
            'capacityUnlimited' => $capacityUnlimited,
            'capacityCount' => $capacityCount,
            'price' => $pick('price', 'price'),
            'buttonText' => $pick('button_text', 'button_text', 'Tilmeld'),
            'published' => $published,
            // The details textarea is prefilled from the sanitized stored HTML
            // (round-trip stable, §5.4); old input wins after a redirect.
            'details' => $pick('details', 'details_html'),
        ];
    }

    /** @return array<string,mixed>|null */
    private static function consumeOldInput(): ?array
    {
        if (self::$oldInputLoaded) {
            return self::$oldInput;
        }
        self::$oldInputLoaded = true;
        $session = Grav::instance()['session'] ?? null;
        $key = self::OLD_INPUT_SESSION_KEY;
        if ($session !== null && isset($session->{$key}) && is_array($session->{$key})) {
            self::$oldInput = $session->{$key};
            unset($session->{$key});
        }
        return self::$oldInput;
    }

    /**
     * Delete-mode choices: soft archive for everyone; the permanent hard
     * delete only for super (and the POST handler re-checks admin.super on
     * mode=hard regardless of what was rendered or posted).
     *
     * @return array<string,string>
     */
    public static function deleteModeOptions(): array
    {
        $options = ['archive' => 'Arkivér (kan gendannes)'];
        $user = Grav::instance()['user'] ?? null;
        if ($user && !empty($user->authenticated) && $user->authorize('admin.super')) {
            $options['hard'] = 'Slet permanent (kan IKKE fortrydes)';
        }
        return $options;
    }

    private const NEW_KEY_SESSION_KEY = 'em_new_event_key';

    /**
     * A pre-generated `ev_<hex>` key for the create form, stable across the
     * form's lifetime (stored in the session) so images uploaded before first
     * save (§5.2/§6) go to the folder the finished event will use. handleCreate
     * adopts this key when it is still unused, then clears it.
     */
    public static function newEventKey(): string
    {
        $session = Grav::instance()['session'] ?? null;
        if ($session !== null
            && isset($session->{self::NEW_KEY_SESSION_KEY})
            && preg_match('/^ev_[a-f0-9]{16}$/', (string)$session->{self::NEW_KEY_SESSION_KEY})) {
            return (string)$session->{self::NEW_KEY_SESSION_KEY};
        }
        $key = 'ev_' . bin2hex(random_bytes(8));
        if ($session !== null) {
            $session->{self::NEW_KEY_SESSION_KEY} = $key;
        }
        return $key;
    }

    /** Clear the create-form key once an event has adopted it. */
    public static function clearNewEventKey($grav): void
    {
        $session = $grav['session'] ?? null;
        if ($session !== null) {
            unset($session->{self::NEW_KEY_SESSION_KEY});
        }
    }

    /** The <key> segment of /begivenheder/{rediger,slet}/<key>, or ''. */
    public static function currentEventKey(): string
    {
        $path = (string)Grav::instance()['uri']->path();
        if (!preg_match('#^/begivenheder/(?:rediger|slet)/([A-Za-z0-9_-]{1,64})$#', $path, $m)) {
            return '';
        }
        return $m[1];
    }

    /**
     * Prefill value for one client-settable field of the event addressed by
     * the current URL. Null (leave the static default) when there is no key,
     * no object, or the viewer is not owner/super.
     */
    public static function eventFieldDefault(string $field): mixed
    {
        if (!in_array($field, EventValidator::FORM_FIELDS, true)) {
            return null;
        }
        // A rejected submission's own values win over the stored object, so
        // the member's edits survive a validation round-trip.
        $old = self::oldInputDefault($field);
        if ($old !== null) {
            return $old;
        }
        $event = self::currentEvent();
        if ($event === null) {
            return null;
        }

        // Virtual form fields derived from the stored shape: the time pair
        // comes from the "HH:MM - HH:MM" event_time string, the capacity
        // pair from the capacity value ('' or non-numeric legacy text =
        // unlimited).
        if ($field === 'time_start' || $field === 'time_end') {
            $time = (string)($event['event_time'] ?? '');
            if (preg_match('/(\d{1,2}[:.]\d{2}).*?(\d{1,2}[:.]\d{2})/u', $time, $m)) {
                $value = $field === 'time_start' ? $m[1] : $m[2];
                return str_pad(str_replace('.', ':', $value), 5, '0', STR_PAD_LEFT);
            }
            return null;
        }
        if ($field === 'capacity_unlimited') {
            $capacity = trim((string)($event['capacity'] ?? ''));
            return preg_match('/^\d+$/', $capacity) ? '0' : '1';
        }
        if ($field === 'capacity_count') {
            $capacity = trim((string)($event['capacity'] ?? ''));
            return preg_match('/^\d+$/', $capacity) ? $capacity : null;
        }
        if ($field === 'details') {
            // The raw form field is `details`; the stored (sanitized) value
            // lives under details_html. Feed it back for a round-trip-stable
            // edit (§5.4). It is sanitizer output, safe to re-edit.
            return (string)($event['details_html'] ?? '');
        }

        if (!array_key_exists($field, $event)) {
            return null;
        }
        $value = $event[$field];
        // Toggle fields compare against their '1'/'0' option keys.
        if (is_bool($value)) {
            return $value ? '1' : '0';
        }
        return $value;
    }

    /** @return array<string,mixed>|null */
    private static function currentEvent(): ?array
    {
        $key = self::currentEventKey();
        if ($key === '') {
            return null;
        }
        $grav = Grav::instance();
        $event = self::repository()->findArray($key);
        if ($event === null) {
            return null;
        }
        $user = $grav['user'] ?? null;
        if (!EventAuthorizer::ownsOrSuper($user, isset($event['owner']) ? (string)$event['owner'] : null)) {
            return null;
        }
        return $event;
    }

    private static function repository(): EventRepository
    {
        return new EventRepository(Grav::instance());
    }
}
