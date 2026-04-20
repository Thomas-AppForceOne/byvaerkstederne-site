<?php
/**
 * Feature Suggestion Plugin
 *
 * Provides an authenticated page for members to submit feature suggestions.
 * Suggestions are stored as Flex Objects (YAML) under user/data/flex-objects/feature-suggestions.yaml.
 * On submission, a roadmap item is automatically created with published: true.
 * Admins can use handleApprove() to curate/adjust metadata; handleDecline() archives suggestions.
 */

namespace Grav\Plugin;

use Grav\Common\Plugin;
use Grav\Common\Utils;
use RocketTheme\Toolbox\Event\Event;

class FeatureSuggestionPlugin extends Plugin
{
    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    public static function getSubscribedEvents(): array
    {
        return [
            'onPluginsInitialized' => ['onPluginsInitialized', 0],
        ];
    }

    public function onPluginsInitialized(): void
    {
        $uri = $this->grav['uri'];

        if ($uri->path() === '/feature-suggestion/submit') {
            $this->enable([
                'onPageInitialized' => ['handleSubmit', 0],
            ]);
        }

        if ($uri->path() === '/feature-suggestion/approve') {
            $this->enable([
                'onPageInitialized' => ['handleApprove', 0],
            ]);
        }

        if ($uri->path() === '/feature-suggestion/decline') {
            $this->enable([
                'onPageInitialized' => ['handleDecline', 0],
            ]);
        }
    }

    // -------------------------------------------------------------------------
    // Submit Handler
    // -------------------------------------------------------------------------

    public function handleSubmit(): void
    {
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            $this->jsonResponse(405, ['error' => 'Method not allowed']);
            return;
        }

        // Authentication check — must be independent of nonce check
        $user = $this->grav['user'];
        if (!$user->authenticated || !$user->authorized) {
            $this->jsonResponse(403, ['error' => 'Ikke autoriseret. Log ind for at indsende et forslag.']);
            return;
        }

        // CSRF nonce validation
        if (!Utils::verifyNonce($_POST['fs_nonce'] ?? '', 'feature-suggestion-form')) {
            $this->jsonResponse(403, ['error' => 'Ugyldig sikkerhedstoken. Genindlæs siden og prøv igen.']);
            return;
        }

        // Duplicate-submission guard: one-time token prevents double-submit / network retry.
        $submissionToken = trim($_POST['submission_token'] ?? '');
        if ($submissionToken !== '') {
            if ($this->isSubmissionTokenUsed($submissionToken)) {
                $this->jsonResponse(409, [
                    'error'     => 'Duplikat indsendelse: dette forslag er allerede registreret.',
                    'duplicate' => true,
                ]);
                return;
            }
            $this->markSubmissionTokenUsed($submissionToken);
        }

        // Validate required fields (server-side — independent of client validation)
        $title          = trim($_POST['fs_title'] ?? '');
        $description    = trim($_POST['fs_description'] ?? '');
        $communityValue = trim($_POST['fs_community_value'] ?? '');

        if ($title === '') {
            $this->jsonResponse(400, ['error' => 'Feltet "Hvad er din idé?" må ikke være tomt.', 'field' => 'title']);
            return;
        }
        if ($description === '') {
            $this->jsonResponse(400, ['error' => 'Feltet "Beskrivelse af idéen" må ikke være tomt.', 'field' => 'description']);
            return;
        }
        if ($communityValue === '') {
            $this->jsonResponse(400, ['error' => 'Feltet "Værdi for fællesskabet" må ikke være tomt.', 'field' => 'community_value']);
            return;
        }

        // Store inputs raw; Twig autoescape (system.yaml: twig.autoescape: true)
        // handles HTML escaping on render. Pre-escaping here produced
        // double-escaped output ("&amp;lt;script&amp;gt;") in roadmap cards.

        // Build IDs and timestamp
        $timestamp    = gmdate('Y-m-d\TH:i:s\Z');
        $id           = 'suggestion_' . substr(bin2hex(random_bytes(8)), 0, 16);
        $roadmapId    = 'rm_' . bin2hex(random_bytes(8));
        $username     = $this->grav['user']->username;

        // Attempt to write roadmap item first (with file lock to prevent duplicate display_ids)
        $roadmapResult = $this->saveRoadmapItemAtomic($roadmapId, function (array $existing) use (
            $id, $roadmapId, $title, $description, $communityValue, $username, $timestamp
        ): array {
            $displayId = $this->computeNextDisplayId($existing, 'feature');

            $roadmapItem = [
                'published'            => true,
                'roadmap_id'           => $roadmapId,
                'type'                 => 'feature',
                'priority'             => 'nyhed',
                'status'               => 'rapporteret',
                'display_id'           => $displayId,
                'title'                => $title,
                'description'          => $description,
                'community_value'      => $communityValue,
                'source_username'      => $username,
                'source_suggestion_id' => $id,
                'source_report_id'     => '',
                'timestamp'            => $timestamp,
                'vote_count'           => 0,
                'votes'                => [],
                'vote_history'         => [],
                'votes_released'       => false,
            ];

            return ['item' => $roadmapItem, 'display_id' => $displayId];
        });

        if ($roadmapResult === null) {
            // Roadmap write failed — still persist the suggestion with status: pending
            // so the user's data is not lost. Return 500 to inform the user.
            $fallbackRecord = [
                'username'        => $username,
                'created_at'      => $timestamp,
                'title'           => $title,
                'description'     => $description,
                'community_value' => $communityValue,
                'status'          => 'pending',
                'roadmap_id'      => null,
                'display_id'      => null,
            ];
            $this->saveSuggestion($id, $fallbackRecord);
            $this->jsonResponse(500, ['error' => 'Forslaget er gemt, men kunne ikke publiceres på roadmappet med det samme. En administrator vil behandle det.']);
            return;
        }

        $displayId = $roadmapResult['display_id'];

        // Build feature suggestion record with status: approved and roadmap_id set at creation.
        // roadmap_id is the human-readable display_id (e.g. #F003); the internal rm_xxx key
        // is available on the roadmap item itself via source_suggestion_id cross-reference.
        $record = [
            'username'        => $username,
            'created_at'      => $timestamp,
            'title'           => $title,
            'description'     => $description,
            'community_value' => $communityValue,
            'status'          => 'approved',
            'roadmap_id'      => $displayId,
            'display_id'      => $displayId,
        ];

        // Persist suggestion to YAML data file
        $saveResult = $this->saveSuggestion($id, $record);
        if (!$saveResult) {
            // Suggestion save failed — rollback the roadmap item
            $this->rollbackRoadmapItem($roadmapId);
            $this->jsonResponse(500, ['error' => 'Forslaget kunne ikke gemmes. Prøv igen om et øjeblik.']);
            return;
        }

        // Build roadmap anchor URL: display_id lowercased, # stripped → fragment
        $fragment   = strtolower(ltrim($displayId, '#'));
        $roadmapUrl = '/roadmap#' . $fragment;

        $this->jsonResponse(200, [
            'success'     => true,
            'message'     => "Dit forslag ({$displayId}) er nu live på roadmappet.",
            'roadmap_id'  => $roadmapId,
            'display_id'  => $displayId,
            'roadmap_url' => $roadmapUrl,
        ]);
    }

    // -------------------------------------------------------------------------
    // Approve Handler
    // -------------------------------------------------------------------------

    public function handleApprove(): void
    {
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            $this->jsonResponse(405, ['error' => 'Method not allowed']);
            return;
        }

        $user = $this->grav['user'];
        if (!$user->authenticated || !$user->authorized) {
            $this->jsonResponse(401, ['error' => 'Ikke autoriseret.']);
            return;
        }

        // Admin only
        if (!$user->authorize('admin.super') && !$user->authorize('admin.pages')) {
            $this->jsonResponse(403, ['error' => 'Kun administratorer kan godkende forslag.']);
            return;
        }

        // Validate nonce
        if (!Utils::verifyNonce($_POST['approve_nonce'] ?? '', 'feature-suggestion-approve')) {
            $this->jsonResponse(403, ['error' => 'Ugyldig sikkerhedstoken.']);
            return;
        }

        $suggestionId = trim($_POST['suggestion_id'] ?? '');
        if ($suggestionId === '') {
            $this->jsonResponse(400, ['error' => 'Manglende forslags-ID.']);
            return;
        }

        // Load suggestions
        $dataFile = $this->getDataFilePath();
        if (!file_exists($dataFile)) {
            $this->jsonResponse(404, ['error' => 'Forslaget blev ikke fundet.']);
            return;
        }

        $data = $this->loadYaml($dataFile);
        if (!isset($data[$suggestionId])) {
            $this->jsonResponse(404, ['error' => 'Forslaget blev ikke fundet.']);
            return;
        }

        $suggestion = $data[$suggestionId];

        // Check if already approved — item was auto-published on submission.
        // Return 200 with already_approved flag (idempotent); do NOT create duplicate.
        if (($suggestion['status'] ?? '') === 'approved') {
            $existingRoadmapId = $suggestion['roadmap_id'] ?? null;
            $this->jsonResponse(200, [
                'success'          => true,
                'already_approved' => true,
                'status'           => 'approved',
                'message'          => 'Dette forslag er allerede godkendt og publiceret på roadmap.',
                'roadmap_id'       => $existingRoadmapId,
            ]);
            return;
        }

        // Legacy path: suggestion was submitted before auto-approve was implemented.
        // Create roadmap item (type: feature, published: true).
        $roadmapId = 'rm_' . bin2hex(random_bytes(8));
        $timestamp = gmdate('Y-m-d\TH:i:s\Z');

        $roadmapResult = $this->saveRoadmapItemAtomic($roadmapId, function (array $existing) use (
            $suggestion, $suggestionId, $roadmapId, $timestamp
        ): array {
            $displayId = $this->computeNextDisplayId($existing, 'feature');

            $roadmapRecord = [
                'published'            => true,
                'roadmap_id'           => $roadmapId,
                'type'                 => 'feature',
                'priority'             => 'nyhed',
                'status'               => 'rapporteret',
                'display_id'           => $displayId,
                'title'                => $suggestion['title'] ?? '',
                'description'          => $suggestion['description'] ?? '',
                'community_value'      => $suggestion['community_value'] ?? '',
                'source_username'      => $suggestion['username'] ?? '',
                'source_suggestion_id' => $suggestionId,
                'source_report_id'     => '',
                'timestamp'            => $timestamp,
                'vote_count'           => 0,
                'votes'                => [],
                'vote_history'         => [],
                'votes_released'       => false,
            ];

            return ['item' => $roadmapRecord, 'display_id' => $displayId];
        });

        if ($roadmapResult === null) {
            $this->jsonResponse(500, ['error' => 'Roadmap-elementet kunne ikke oprettes.']);
            return;
        }

        // Mark suggestion as approved — if this fails, roll back roadmap entry
        $data[$suggestionId]['status']     = 'approved';
        $data[$suggestionId]['roadmap_id'] = $roadmapId;
        if (!$this->saveYaml($dataFile, $data)) {
            // Rollback
            $this->rollbackRoadmapItem($roadmapId);
            $this->jsonResponse(500, ['error' => 'Godkendelsesstatus kunne ikke gemmes. Handlingen er fortrydt.']);
            return;
        }

        $this->jsonResponse(200, [
            'success'    => true,
            'status'     => 'approved',
            'roadmap_id' => $roadmapId,
            'display_id' => $roadmapResult['display_id'],
        ]);
    }

    // -------------------------------------------------------------------------
    // Decline Handler
    // -------------------------------------------------------------------------

    public function handleDecline(): void
    {
        if ($_SERVER['REQUEST_METHOD'] !== 'POST') {
            $this->jsonResponse(405, ['error' => 'Method not allowed']);
            return;
        }

        $user = $this->grav['user'];
        if (!$user->authenticated || !$user->authorized) {
            $this->jsonResponse(401, ['error' => 'Ikke autoriseret.']);
            return;
        }

        // Admin only
        if (!$user->authorize('admin.super') && !$user->authorize('admin.pages')) {
            $this->jsonResponse(403, ['error' => 'Kun administratorer kan afvise forslag.']);
            return;
        }

        // Validate nonce
        if (!Utils::verifyNonce($_POST['decline_nonce'] ?? '', 'feature-suggestion-decline')) {
            $this->jsonResponse(403, ['error' => 'Ugyldig sikkerhedstoken.']);
            return;
        }

        $suggestionId = trim($_POST['suggestion_id'] ?? '');
        if ($suggestionId === '') {
            $this->jsonResponse(400, ['error' => 'Manglende forslags-ID.']);
            return;
        }

        // Load suggestions
        $dataFile = $this->getDataFilePath();
        if (!file_exists($dataFile)) {
            $this->jsonResponse(404, ['error' => 'Forslaget blev ikke fundet.']);
            return;
        }

        $data = $this->loadYaml($dataFile);
        if (!isset($data[$suggestionId])) {
            $this->jsonResponse(404, ['error' => 'Forslaget blev ikke fundet.']);
            return;
        }

        // Update status to archived
        $data[$suggestionId]['status'] = 'archived';
        if (!$this->saveYaml($dataFile, $data)) {
            $this->jsonResponse(500, ['error' => 'Status kunne ikke opdateres.']);
            return;
        }

        $this->jsonResponse(200, ['success' => true]);
    }

    // -------------------------------------------------------------------------
    // Display ID Helper
    // -------------------------------------------------------------------------

    /**
     * Compute the next display_id for a given type ('bug' → #B001, 'feature' → #F001).
     * Scans existing roadmap items, finds the max numeric suffix for that type, increments.
     */
    private function computeNextDisplayId(array $existingItems, string $type): string
    {
        $prefix = ($type === 'bug') ? 'B' : 'F';
        $max = 0;

        foreach ($existingItems as $item) {
            if (!is_array($item)) {
                continue;
            }
            if (($item['type'] ?? '') !== $type) {
                continue;
            }
            $displayId = $item['display_id'] ?? '';
            if (preg_match('/^#' . $prefix . '(\d+)$/i', $displayId, $matches)) {
                $num = (int)$matches[1];
                if ($num > $max) {
                    $max = $num;
                }
            }
        }

        return '#' . $prefix . str_pad((string)($max + 1), 3, '0', STR_PAD_LEFT);
    }

    // -------------------------------------------------------------------------
    // Storage Helpers
    // -------------------------------------------------------------------------

    private function getDataFilePath(): string
    {
        $dir = GRAV_ROOT . '/user/data/flex-objects';
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }
        return $dir . '/feature-suggestions.yaml';
    }

    private function getRoadmapDataFilePath(): string
    {
        $dir = GRAV_ROOT . '/user/data/flex-objects';
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }
        return $dir . '/roadmap-items.yaml';
    }

    private function saveSuggestion(string $id, array $record): bool
    {
        $dataFile = $this->getDataFilePath();
        $data     = file_exists($dataFile) ? $this->loadYaml($dataFile) : [];
        $data[$id] = $record;
        return $this->saveYaml($dataFile, $data);
    }

    /**
     * Save a roadmap item atomically using an exclusive file lock to prevent
     * duplicate display_ids under concurrent submissions.
     *
     * The $builder callback receives the current array of roadmap items and
     * must return ['item' => [...], 'display_id' => '...', ...extra].
     * Returns the builder result array (minus 'item') on success, or null on failure.
     */
    private function saveRoadmapItemAtomic(string $id, callable $builder): ?array
    {
        $dataFile = $this->getRoadmapDataFilePath();

        // Open (or create) the file for reading + writing
        $fh = fopen($dataFile, 'c+');
        if ($fh === false) {
            return null;
        }

        // Acquire exclusive lock (blocks until available)
        if (!flock($fh, LOCK_EX)) {
            fclose($fh);
            return null;
        }

        try {
            // Read current content
            $content = stream_get_contents($fh);
            $existing = [];
            if ($content !== false && trim($content) !== '') {
                $parsed = \Symfony\Component\Yaml\Yaml::parse($content);
                if (is_array($parsed)) {
                    $existing = $parsed;
                }
            }

            // Let caller compute the item and any metadata (e.g. display_id)
            $result = $builder($existing);
            $item = $result['item'];

            // Add item to the store
            $existing[$id] = $item;

            // Write back
            $yaml = \Symfony\Component\Yaml\Yaml::dump($existing, 6, 2, \Symfony\Component\Yaml\Yaml::DUMP_MULTI_LINE_LITERAL_BLOCK);
            ftruncate($fh, 0);
            rewind($fh);
            $written = fwrite($fh, $yaml);
            fflush($fh);

            if ($written === false) {
                return null;
            }

            // Return the metadata from the builder (e.g. display_id)
            unset($result['item']);
            return $result;

        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
    }

    /**
     * Remove a roadmap item by ID (rollback on suggestion save failure).
     */
    private function rollbackRoadmapItem(string $id): void
    {
        $dataFile = $this->getRoadmapDataFilePath();
        if (!file_exists($dataFile)) {
            return;
        }

        $fh = fopen($dataFile, 'c+');
        if ($fh === false) {
            return;
        }

        if (!flock($fh, LOCK_EX)) {
            fclose($fh);
            return;
        }

        try {
            $content = stream_get_contents($fh);
            if ($content === false || trim($content) === '') {
                return;
            }
            $existing = \Symfony\Component\Yaml\Yaml::parse($content);
            if (!is_array($existing) || !isset($existing[$id])) {
                return;
            }

            unset($existing[$id]);
            $yaml = \Symfony\Component\Yaml\Yaml::dump($existing, 6, 2, \Symfony\Component\Yaml\Yaml::DUMP_MULTI_LINE_LITERAL_BLOCK);
            ftruncate($fh, 0);
            rewind($fh);
            fwrite($fh, $yaml);
            fflush($fh);
        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
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
        $yaml = \Symfony\Component\Yaml\Yaml::dump($data, 6, 2, \Symfony\Component\Yaml\Yaml::DUMP_MULTI_LINE_LITERAL_BLOCK);
        return file_put_contents($path, $yaml) !== false;
    }

    // -------------------------------------------------------------------------
    // Duplicate-Submission Token Helpers
    // -------------------------------------------------------------------------

    /**
     * Check whether a submission token has already been used.
     * Tokens are stored in a shared YAML file; entries older than 5 minutes are ignored.
     */
    private function isSubmissionTokenUsed(string $token): bool
    {
        $file = $this->getTokenStorePath();
        if (!file_exists($file)) {
            return false;
        }
        $tokens = $this->loadYaml($file);
        $now    = time();
        return isset($tokens[$token]) && ($now - (int)$tokens[$token]) < 300;
    }

    /**
     * Mark a submission token as used, pruning tokens older than 5 minutes.
     */
    private function markSubmissionTokenUsed(string $token): void
    {
        $file   = $this->getTokenStorePath();
        $tokens = file_exists($file) ? $this->loadYaml($file) : [];
        $now    = time();

        // Prune expired tokens
        foreach ($tokens as $t => $ts) {
            if (($now - (int)$ts) >= 300) {
                unset($tokens[$t]);
            }
        }

        $tokens[$token] = $now;
        $this->saveYaml($file, $tokens);
    }

    /**
     * Returns the path to the shared submission-token store file.
     */
    private function getTokenStorePath(): string
    {
        $dir = GRAV_ROOT . '/user/data/flex-objects';
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }
        return $dir . '/submission-tokens.yaml';
    }

    // -------------------------------------------------------------------------
    // JSON Response Helper
    // -------------------------------------------------------------------------

    private function jsonResponse(int $status, array $data): void
    {
        http_response_code($status);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode($data, JSON_UNESCAPED_UNICODE);
        exit;
    }
}
