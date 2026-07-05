<?php
/**
 * EventRepository — all Flex reads/writes for the `begivenheder` directory
 * (frontend_event_crud_specification.md §8). Mutations go through the Flex
 * API so blueprint validation and the supported (serialised) write path
 * apply; the render cache is busted explicitly by the caller after every
 * successful mutation — never via onFlexAfterSave/Delete, whose frontend
 * firing is unverified in Flex Objects 1.3.8.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager;

use Grav\Common\Grav;

final class EventRepository
{
    private const FLEX_TYPE = 'begivenheder';

    private Grav $grav;

    public function __construct(Grav $grav)
    {
        $this->grav = $grav;
    }

    /**
     * @return \Grav\Framework\Flex\Interfaces\FlexDirectoryInterface
     */
    private function directory()
    {
        $flex = $this->grav['flex_objects'] ?? ($this->grav['flex'] ?? null);
        if ($flex === null || !method_exists($flex, 'getDirectory')) {
            throw new \RuntimeException('Flex Objects is not available');
        }
        $directory = $flex->getDirectory(self::FLEX_TYPE);
        if ($directory === null) {
            throw new \RuntimeException('Flex directory "' . self::FLEX_TYPE . '" is not registered');
        }
        return $directory;
    }

    /** @return object|null the Flex object, or null when the key is unknown */
    public function find(string $key)
    {
        try {
            $object = $this->directory()->getObject($key);
        } catch (\Throwable $e) {
            return null;
        }
        return $object ?: null;
    }

    /** @return array<string,mixed>|null */
    public function findArray(string $key): ?array
    {
        $object = $this->find($key);
        return $object === null ? null : $this->toArray($object);
    }

    /** @return array<string,mixed> */
    public function toArray(object $object): array
    {
        // FlexObject::getElements() is protected; jsonSerialize() is the
        // public accessor for the same property map.
        if ($object instanceof \JsonSerializable) {
            return (array)$object->jsonSerialize();
        }
        return [];
    }

    /**
     * Create and persist a new event. Returns the ACTUAL storage key — the
     * requested `ev_<hex>` key is pinned via setStorageKey(), because
     * SimpleStorage otherwise mints its own key on first save and the audit
     * trail / PRG target would reference a key that doesn't exist.
     *
     * @param array<string,mixed> $data
     */
    public function create(array $data, string $key): string
    {
        $object = $this->directory()->createObject($data, $key);
        if (method_exists($object, 'setStorageKey')) {
            $object->setStorageKey($key);
        }
        $object->save();

        $actual = method_exists($object, 'getStorageKey') ? (string)$object->getStorageKey() : '';
        return $actual !== '' ? $actual : $key;
    }

    /** @param array<string,mixed> $data */
    public function update(object $object, array $data): void
    {
        $object->update($data);
        $object->save();
    }

    public function hardDelete(object $object): void
    {
        $object->delete();
    }

    /**
     * Blueprint-sourced enum options for a select field — the single source
     * of truth for `group`/`button_style` (§0). Returns [] when unavailable
     * so callers can degrade (validator skips the enum check rather than
     * rejecting everything).
     *
     * @return array<string,string>
     */
    public function fieldOptions(string $field): array
    {
        try {
            $options = $this->directory()->getBlueprint()->get('form/fields/' . $field . '/options');
        } catch (\Throwable $e) {
            return [];
        }
        return is_array($options) ? $options : [];
    }

    /**
     * Dashboard listing (§8.2): the viewer's own events in every state;
     * super sees all. Sorted by event_date ascending. Each row carries the
     * storage `key` and a derived `status` chip value.
     *
     * @return list<array<string,mixed>>
     */
    public function listFor($user): array
    {
        $isSuper = (bool)$user->authorize('admin.super');
        $username = (string)$user->username;

        $rows = [];
        try {
            $collection = $this->directory()->getCollection();
        } catch (\Throwable $e) {
            return [];
        }

        foreach ($collection as $object) {
            $data = $this->toArray($object);
            $owner = (string)($data['owner'] ?? '');
            if (!$isSuper && ($owner === '' || $owner !== $username)) {
                continue;
            }
            $key = method_exists($object, 'getStorageKey') ? $object->getStorageKey() : null;
            if (!$key && method_exists($object, 'getKey')) {
                $key = $object->getKey();
            }
            if (!$key) {
                continue;
            }
            $data['key'] = (string)$key;
            $data['status'] = !empty($data['archived'])
                ? 'arkiveret'
                : (!empty($data['published']) ? 'publiceret' : 'kladde');
            $rows[] = $data;
        }

        usort($rows, static function (array $a, array $b): int {
            return strcmp((string)($a['event_date'] ?? ''), (string)($b['event_date'] ?? ''));
        });

        return $rows;
    }

    /**
     * Explicit render-cache bust after a successful mutation — mirrors what
     * flex-cache-bust does on onFlexAfterSave/Delete, guaranteeing
     * public-list freshness without depending on those events firing from a
     * frontend save (§8).
     */
    public function bustRenderCache(): void
    {
        try {
            $cache = $this->grav['cache'];
            $cache->getCacheDriver()->deleteAll();
        } catch (\Throwable $e) {
            // Cache bust is freshness, not correctness — never fail the
            // mutation over it.
        }
    }
}
