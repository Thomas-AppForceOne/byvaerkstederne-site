<?php
/**
 * Roadmap Plugin for Byværkstederne
 *
 * Handles:
 *  - Public roadmap page data injection (items, budgets, nonces)
 *  - AJAX vote add/remove endpoint  (/roadmap/vote)
 *  - Admin vote-release endpoint    (/admin/roadmap/release-votes)
 *  - Server-side enforcement of budget limits, uniqueness and locked-state rules
 *  - Automatic vote-release when status transitions to 'klar_til_implementation'
 */

namespace Grav\Plugin;

use Grav\Common\Plugin;
use Grav\Common\Utils;
use RocketTheme\Toolbox\Event\Event;
use Grav\Framework\Psr7\Response;

class RoadmapPlugin extends Plugin
{
    private const MAX_VOTES     = 3;
    private const LOCKED_STATUSES = ['under_implementation', 'klar_til_test', 'loest'];
    private const RELEASE_STATUS  = 'klar_til_implementation';

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    public static function getSubscribedEvents(): array
    {
        return [
            'onPluginsInitialized' => ['onPluginsInitialized', 0],
            'onFlexAfterSave'      => ['onFlexAfterSave', 0],
        ];
    }

    public function onPluginsInitialized(): void
    {
        if (!$this->config->get('plugins.roadmap.enabled')) {
            return;
        }

        /** @var \Grav\Common\Uri $uri */
        $uri    = $this->grav['uri'];
        $path   = $uri->path();
        $method = $_SERVER['REQUEST_METHOD'] ?? '';

        // Public AJAX vote endpoint
        if ($path === '/roadmap/vote' && $method === 'POST') {
            $this->handleVote();
            return;
        }

        // Admin vote-release endpoint
        if ($path === '/admin/roadmap/release-votes' && $method === 'POST') {
            $this->handleReleaseVotes();
            return;
        }

        // Frontend template data injection (only non-admin pages)
        if (!$this->isAdmin()) {
            $this->enable([
                'onTwigSiteVariables' => ['onTwigSiteVariables', 0],
            ]);
        }
    }

    // -------------------------------------------------------------------------
    // Automatic vote release on Flex Object status change (admin save)
    // -------------------------------------------------------------------------

    /**
     * Fired by the Flex Objects plugin after any Flex Object is saved via admin.
     * Detects when a roadmap item's status is set to 'klar_til_implementation'
     * and automatically releases all active votes atomically.
     */
    public function onFlexAfterSave(Event $event): void
    {
        $object = $event['object'] ?? null;
        if ($object === null) {
            return;
        }

        // Determine the flex type — skip if not a roadmap item
        $flexType = null;
        if (method_exists($object, 'getFlexType')) {
            $flexType = $object->getFlexType();
        } elseif (method_exists($object, 'getType')) {
            $flexType = $object->getType();
        }

        if ($flexType !== 'roadmap-items') {
            return;
        }

        // Read current status from the saved object
        $status = null;
        if (method_exists($object, 'getProperty')) {
            $status = $object->getProperty('status');
        } elseif (method_exists($object, 'get')) {
            $status = $object->get('status');
        } elseif (isset($object['status'])) {
            $status = $object['status'];
        }

        if ($status !== self::RELEASE_STATUS) {
            return;
        }

        // Get the item key (storage key in the YAML map)
        $itemKey = null;
        if (method_exists($object, 'getStorageKey')) {
            $itemKey = $object->getStorageKey();
        } elseif (method_exists($object, 'getKey')) {
            $itemKey = $object->getKey();
        }

        if ($itemKey === null || $itemKey === '') {
            return;
        }

        // Load YAML data to check votes_released and perform atomic release
        $dataFile = $this->getDataFilePath();
        if (!file_exists($dataFile)) {
            return;
        }

        $items = $this->loadYaml($dataFile);
        if (!isset($items[$itemKey])) {
            return;
        }

        $item = $items[$itemKey];

        // Only release if there are active votes and they haven't been released yet
        $votes = $item['votes'] ?? [];
        $votesReleased = !empty($item['votes_released']);

        if (empty($votes) || $votesReleased) {
            return;
        }

        // Atomically release all votes: preserve history, clear active votes
        $items[$itemKey] = $this->releaseItemVotes($item);
        $this->saveYaml($dataFile, $items);
    }

    // -------------------------------------------------------------------------
    // Twig data injection (frontend /roadmap page)
    // -------------------------------------------------------------------------

    public function onTwigSiteVariables(): void
    {
        $page = $this->grav['page'] ?? null;
        if (!$page || $page->route() !== '/roadmap') {
            return;
        }

        $twig     = $this->grav['twig'];
        $dataFile = $this->getDataFilePath();
        $allItems = file_exists($dataFile) ? $this->loadYaml($dataFile) : [];

        // Separate published bugs and features; auto-assign display_id if missing
        $bugs     = [];
        $features = [];
        foreach ($allItems as $id => $item) {
            if (empty($item['published'])) {
                continue;
            }
            if (empty($item['display_id'])) {
                $item['display_id'] = '#' . strtoupper(substr(preg_replace('/[^0-9a-f]/i', '', $id), -4));
            }
            $item['_key'] = $id;
            if (($item['type'] ?? '') === 'bug') {
                $bugs[$id] = $item;
            } else {
                $features[$id] = $item;
            }
        }

        // Sort by vote_count descending, then by timestamp
        uasort($bugs, static function ($a, $b) {
            $vc = ($b['vote_count'] ?? 0) <=> ($a['vote_count'] ?? 0);
            return $vc !== 0 ? $vc : strcmp($b['timestamp'] ?? '', $a['timestamp'] ?? '');
        });
        uasort($features, static function ($a, $b) {
            $vc = ($b['vote_count'] ?? 0) <=> ($a['vote_count'] ?? 0);
            return $vc !== 0 ? $vc : strcmp($b['timestamp'] ?? '', $a['timestamp'] ?? '');
        });

        // Per-user vote state
        $user              = $this->grav['user'] ?? null;
        $bugBudget         = self::MAX_VOTES;
        $featureBudget     = self::MAX_VOTES;
        $userVotedItems    = [];

        if ($user && $user->authenticated && $user->authorized) {
            $username = $user->username;
            foreach ($allItems as $id => $item) {
                if (empty($item['published'])) {
                    continue;
                }
                $votes = $item['votes'] ?? [];
                if (isset($votes[$username])) {
                    $userVotedItems[] = $id;
                    if (($item['type'] ?? '') === 'bug') {
                        $bugBudget--;
                    } else {
                        $featureBudget--;
                    }
                }
            }
        }

        // Version/status from config
        $versionsConfig  = $this->grav['config']->get('versions', []);
        $platformVersion = $versionsConfig['platform']['version'] ?? '1.0.0';
        $platformStatus  = $versionsConfig['platform']['status'] ?? 'Operationel';

        // Inject into Twig
        $twig->twig_vars['roadmap_bugs']              = $bugs;
        $twig->twig_vars['roadmap_features']          = $features;
        $twig->twig_vars['roadmap_bug_budget']         = max(0, $bugBudget);
        $twig->twig_vars['roadmap_feature_budget']     = max(0, $featureBudget);
        $twig->twig_vars['roadmap_user_voted_items']   = $userVotedItems;
        $twig->twig_vars['platform_version']           = $platformVersion;
        $twig->twig_vars['platform_status']            = $platformStatus;
    }

    // -------------------------------------------------------------------------
    // Vote endpoint
    // -------------------------------------------------------------------------

    private function handleVote(): void
    {
        // Must be authenticated
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorized) {
            $this->sendJson(['error' => 'Ikke autoriseret. Log ind for at stemme.'], 401);
        }

        // CSRF nonce
        $nonce = $_POST['vote_nonce'] ?? '';
        if (!Utils::verifyNonce($nonce, 'roadmap-vote')) {
            $this->sendJson(['error' => 'Ugyldig sikkerhedstoken. Genindlæs siden og prøv igen.'], 403);
        }

        $itemId = trim($_POST['item_id'] ?? '');
        $action = trim($_POST['action'] ?? ''); // 'add' | 'remove'

        if ($itemId === '' || !in_array($action, ['add', 'remove'], true)) {
            $this->sendJson(['error' => 'Ugyldige parametre.'], 400);
        }

        $dataFile = $this->getDataFilePath();
        if (!file_exists($dataFile)) {
            $this->sendJson(['error' => 'Roadmap-database ikke fundet.'], 500);
        }

        $items = $this->loadYaml($dataFile);
        if (!isset($items[$itemId])) {
            $this->sendJson(['error' => 'Roadmap-element ikke fundet.'], 404);
        }

        $item     = $items[$itemId];
        $username = $user->username;
        $status   = $item['status'] ?? 'rapporteret';
        $type     = $item['type']   ?? 'bug';

        // Only published items are voteable
        if (empty($item['published'])) {
            $this->sendJson(['error' => 'Dette element er ikke tilgængeligt.'], 403);
        }

        // Safety net: auto-release votes if status is klar_til_implementation and votes haven't been released
        if ($status === self::RELEASE_STATUS && !empty($item['votes']) && empty($item['votes_released'])) {
            $items[$itemId] = $this->releaseItemVotes($item);
            $this->saveYaml($dataFile, $items);
            $items = $this->loadYaml($dataFile);
            $item  = $items[$itemId];
        }

        if ($action === 'add') {
            // Rule 3: locked status check
            if (in_array($status, self::LOCKED_STATUSES, true)) {
                $this->sendJson(['error' => 'Stemmeafgivelse er låst for dette element.'], 409);
            }

            // Rule 2: uniqueness check
            $votes = $item['votes'] ?? [];
            if (isset($votes[$username])) {
                $this->sendJson(['error' => 'Du har allerede stemt på dette element.'], 409);
            }

            // Rule 1: budget check
            $budget = $this->getUserBudget($items, $username, $type);
            if ($budget <= 0) {
                $this->sendJson(['error' => 'Du har ikke flere stemmer til rådighed i denne kategori.'], 409);
            }

            // Apply vote
            $items[$itemId]['votes'][$username]         = true;
            $items[$itemId]['vote_history'][$username]  = true;
            $items[$itemId]['vote_count']               = count($items[$itemId]['votes']);

        } else { // remove
            $votes = $item['votes'] ?? [];
            if (!isset($votes[$username])) {
                $this->sendJson(['error' => 'Du har ikke stemt på dette element.'], 409);
            }

            unset($items[$itemId]['votes'][$username]);
            $items[$itemId]['vote_count'] = count($items[$itemId]['votes']);
            // vote_history is NOT modified — history is preserved
        }

        if (!$this->saveYaml($dataFile, $items)) {
            $this->sendJson(['error' => 'Kunne ikke gemme stemme. Prøv igen.'], 500);
        }

        // Re-compute budgets after save
        $saved          = $this->loadYaml($dataFile);
        $newBugBudget   = $this->getUserBudget($saved, $username, 'bug');
        $newFeatBudget  = $this->getUserBudget($saved, $username, 'feature');
        $newVoteCount   = $saved[$itemId]['vote_count'] ?? 0;

        $this->sendJson([
            'success'          => true,
            'vote_count'       => $newVoteCount,
            'bug_budget'       => $newBugBudget,
            'feature_budget'   => $newFeatBudget,
        ]);
    }

    // -------------------------------------------------------------------------
    // Admin vote-release endpoint
    // -------------------------------------------------------------------------

    private function handleReleaseVotes(): void
    {
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorize('admin.super')) {
            $this->sendJson(['error' => 'Kun administratorer kan frigive stemmer.'], 401);
        }

        $nonce = $_POST['release_nonce'] ?? '';
        if (!Utils::verifyNonce($nonce, 'roadmap-release-votes')) {
            $this->sendJson(['error' => 'Ugyldig sikkerhedstoken.'], 403);
        }

        $itemId = trim($_POST['item_id'] ?? '');
        if ($itemId === '') {
            $this->sendJson(['error' => 'Manglende element-ID.'], 400);
        }

        $dataFile = $this->getDataFilePath();
        $items    = $this->loadYaml($dataFile);

        if (!isset($items[$itemId])) {
            $this->sendJson(['error' => 'Element ikke fundet.'], 404);
        }

        // Atomic: either all votes are released or none
        $items[$itemId] = $this->releaseItemVotes($items[$itemId]);

        if (!$this->saveYaml($dataFile, $items)) {
            $this->sendJson(['error' => 'Kunne ikke frigive stemmer. Prøv igen.'], 500);
        }

        $this->sendJson([
            'success'          => true,
            'released_count'   => count($items[$itemId]['vote_history'] ?? []),
        ]);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /**
     * Release all active votes on an item, preserving vote_history.
     * Returns the updated item array.
     */
    private function releaseItemVotes(array $item): array
    {
        $activeVotes  = $item['votes']        ?? [];
        $history      = $item['vote_history'] ?? [];

        // Merge active votes into history
        foreach ($activeVotes as $username => $v) {
            $history[$username] = true;
        }

        $item['vote_history']  = $history;
        $item['votes']         = [];
        $item['vote_count']    = 0;
        $item['votes_released'] = true;

        return $item;
    }

    /**
     * Compute how many votes a user has left in a given category.
     */
    private function getUserBudget(array $items, string $username, string $type): int
    {
        $used = 0;
        foreach ($items as $item) {
            if (($item['type'] ?? '') !== $type) {
                continue;
            }
            if (empty($item['published'])) {
                continue;
            }
            if (isset(($item['votes'] ?? [])[$username])) {
                $used++;
            }
        }
        return max(0, self::MAX_VOTES - $used);
    }

    private function getDataFilePath(): string
    {
        $dir = GRAV_ROOT . '/user/data/flex-objects';
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }
        return $dir . '/roadmap-items.yaml';
    }

    private function loadYaml(string $path): array
    {
        if (!file_exists($path)) {
            return [];
        }
        $content = file_get_contents($path);
        if ($content === false || trim($content) === '') {
            return [];
        }
        $parsed = \Symfony\Component\Yaml\Yaml::parse($content);
        return is_array($parsed) ? $parsed : [];
    }

    private function saveYaml(string $path, array $data): bool
    {
        $yaml = \Symfony\Component\Yaml\Yaml::dump(
            $data,
            6,
            2,
            \Symfony\Component\Yaml\Yaml::DUMP_MULTI_LINE_LITERAL_BLOCK
        );
        return file_put_contents($path, $yaml, LOCK_EX) !== false;
    }

    private function sendJson(array $data, int $status = 200): never
    {
        $body     = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        $response = new Response($status, ['Content-Type' => 'application/json; charset=utf-8'], $body);
        $this->grav->close($response);
    }
}
