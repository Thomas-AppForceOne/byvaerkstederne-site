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
    /** @return array<string,string> */
    public static function groupOptions(): array
    {
        return self::repository()->fieldOptions('group');
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
