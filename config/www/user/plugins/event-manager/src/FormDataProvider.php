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
        if ($event === null || !array_key_exists($field, $event)) {
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
