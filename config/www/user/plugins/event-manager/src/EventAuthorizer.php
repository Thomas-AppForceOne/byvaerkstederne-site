<?php
/**
 * EventAuthorizer — the single place the per-object event policy lives
 * (frontend_event_crud_specification.md §3/§8).
 *
 * Ownership rule: an event is owned by the user whose username equals the
 * STORED `owner` field. A null/empty stored owner (the pre-existing legacy
 * events) means super-only-editable. `admin.super` passes every check.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager;

final class EventAuthorizer
{
    /**
     * Capability check for one of the §4 actions (create/read/update/delete).
     *
     * NOTE: the spec assumed Grav's `admin.super` passes every authorize()
     * call automatically; core UserTrait::authorize() is actually a plain
     * access-tree lookup with no super override (the override lives in the
     * admin plugin only). Super therefore gets an explicit OR here.
     */
    public static function hasCapability($user, string $action): bool
    {
        if (!$user || empty($user->authenticated) || empty($user->authorized)) {
            return false;
        }
        return (bool)$user->authorize('admin.events.' . $action)
            || (bool)$user->authorize('admin.super');
    }

    /**
     * May $user act on an object whose stored owner is $owner?
     * (Capability checks — admin.events.* — happen separately in the
     * contract; this is the per-object half.)
     */
    public static function ownsOrSuper($user, ?string $owner): bool
    {
        if (!$user || empty($user->authenticated) || empty($user->authorized)) {
            return false;
        }
        if ($user->authorize('admin.super')) {
            return true;
        }
        if ($owner === null || $owner === '') {
            return false; // legacy/ownerless events: super-only (§2)
        }
        return $owner === $user->username;
    }

    /**
     * Read-visibility (§8.2): published+non-archived ⇒ anyone; otherwise the
     * owner (holding admin.events.read) or super only.
     *
     * @param array<string,mixed> $event
     */
    public static function canRead($user, array $event): bool
    {
        if (!empty($event['published']) && empty($event['archived'])) {
            return true;
        }
        if (!self::ownsOrSuper($user, isset($event['owner']) ? (string)$event['owner'] : null)) {
            return false;
        }
        return (bool)$user->authorize('admin.events.read') || (bool)$user->authorize('admin.super');
    }
}
