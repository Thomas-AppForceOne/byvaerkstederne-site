<?php

namespace Grav\Plugin;

use Grav\Common\Plugin;
use RocketTheme\Toolbox\Event\Event;

class FlexCacheBustPlugin extends Plugin
{
    public static function getSubscribedEvents(): array
    {
        return [
            'onFlexAfterSave'   => ['onFlexDataChanged', 0],
            'onFlexAfterDelete' => ['onFlexAfterDelete', 0],
            'onPluginsInitialized' => ['onPluginsInitialized', 0],
        ];
    }

    public function onPluginsInitialized(): void
    {
        // Fix the port-in-path redirect bug for Docker port mapping
        // Catches URLs like /admin/flex-objects/opgaver/:8080
        $uri = $_SERVER['REQUEST_URI'] ?? '';
        if (preg_match('#(.*)/:\d+$#', $uri, $matches)) {
            header('Location: ' . $matches[1], true, 302);
            exit;
        }
    }

    public function onFlexDataChanged(Event $event): void
    {
        $cache = $this->grav['cache'];
        $driver = $cache->getCacheDriver();
        $driver->deleteAll();
    }

    public function onFlexAfterDelete(Event $event): void
    {
        // Clear cache
        $cache = $this->grav['cache'];
        $driver = $cache->getCacheDriver();
        $driver->deleteAll();

        // Fix redirect: override the bad redirect before it happens
        // The delete action sets a redirect via dirname() which mangles the port
        $uri = $_SERVER['REQUEST_URI'] ?? '';
        if (preg_match('#(/admin/flex-objects/[^/]+)/#', $uri, $matches)) {
            header('Location: ' . $matches[1], true, 302);
            exit;
        }
    }
}
