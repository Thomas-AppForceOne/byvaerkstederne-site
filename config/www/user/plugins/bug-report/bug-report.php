<?php
namespace Grav\Plugin;

use Grav\Common\Plugin;
use Grav\Common\Utils;
use RocketTheme\Toolbox\Event\Event;
use Grav\Framework\Psr7\Response;

/**
 * Bug Report Plugin for Byværkstederne
 * Handles bug report submissions and promote-to-roadmap admin actions.
 */
class BugReportPlugin extends Plugin
{
    /** Accepted image MIME types (validated via magic bytes) */
    private const ALLOWED_MIME = [
        'image/jpeg' => true,
        'image/png'  => true,
        'image/gif'  => true,
        'image/webp' => true,
    ];

    /** Magic byte signatures for image validation */
    private const MAGIC_BYTES = [
        'image/jpeg' => "\xFF\xD8\xFF",
        'image/png'  => "\x89PNG\r\n\x1a\n",
        'image/gif'  => ['GIF87a', 'GIF89a'],
        'image/webp' => 'RIFF????WEBP', // special handling
    ];

    public static function getSubscribedEvents(): array
    {
        return [
            'onPluginsInitialized' => ['onPluginsInitialized', 0],
        ];
    }

    public function onPluginsInitialized(): void
    {
        if (!$this->config->get('plugins.bug-report.enabled')) {
            return;
        }

        /** @var \Grav\Common\Uri $uri */
        $uri = $this->grav['uri'];
        $path = $uri->path();

        // Handle AJAX bug report submission endpoint
        if ($path === '/bug-report-submit' && ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
            $this->handleSubmission();
            return; // handleSubmission calls $this->grav->close()
        }

        // Handle admin promote-to-roadmap action (both legacy path and canonical path)
        if (($path === '/bug-report/promote' || $path === '/admin/bug-report-promote') && ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
            $this->handlePromote();
            return;
        }

        // Handle admin image serving endpoint
        if (str_starts_with($path, '/admin/bug-report-image') && ($_SERVER['REQUEST_METHOD'] ?? '') === 'GET') {
            $this->handleImageServe();
            return;
        }

        // Register Twig variables for frontend
        if (!$this->isAdmin()) {
            $this->enable([
                'onTwigSiteVariables' => ['onTwigSiteVariables', 0],
            ]);
        }
    }

    /**
     * Make plugin status available to Twig templates.
     */
    public function onTwigSiteVariables(): void
    {
        $twig = $this->grav['twig'];
        $twig->twig_vars['bug_report_enabled'] = true;
    }

    /**
     * Handle AJAX bug report form submission.
     * Auto-creates a roadmap item with published: true in the same request.
     */
    private function handleSubmission(): void
    {
        // Verify user is authenticated
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorized) {
            $this->sendJson(['error' => 'Ikke autoriseret. Log ind for at indsende fejlrapporter.'], 401);
        }

        // Validate nonce (CSRF protection)
        $nonce = $_POST['bug_report_nonce'] ?? '';
        if (!Utils::verifyNonce($nonce, 'bug-report-form')) {
            $this->sendJson(['error' => 'Ugyldig formular-token. Genindlæs siden og prøv igen.'], 403);
        }

        // Duplicate-submission guard: each form render includes a unique one-time token.
        // If the same token is received twice (double-click / network retry), return 409.
        $submissionToken = trim($_POST['submission_token'] ?? '');
        if ($submissionToken !== '') {
            if ($this->isSubmissionTokenUsed($submissionToken)) {
                $this->sendJson([
                    'error'     => 'Duplikat indsendelse: denne rapport er allerede registreret.',
                    'duplicate' => true,
                ], 409);
            }
            $this->markSubmissionTokenUsed($submissionToken);
        }

        // Validate required fields
        $description = trim($_POST['description'] ?? '');
        $expected = trim($_POST['expected'] ?? '');
        $pageUrl = trim($_POST['page_url'] ?? '');
        $browserOs = trim($_POST['browser_os'] ?? 'Unknown');

        if ($description === '') {
            $this->sendJson(['error' => 'Feltet "Hvad skete der?" må ikke være tomt.'], 400);
        }
        if ($expected === '') {
            $this->sendJson(['error' => 'Feltet "Hvad forventede du ville ske?" må ikke være tomt.'], 400);
        }

        // Process reproduction steps (filter blank entries)
        $stepsRaw = $_POST['steps'] ?? [];
        if (is_string($stepsRaw)) {
            $stepsRaw = explode("\n", $stepsRaw);
        }
        $steps = [];
        foreach ((array)$stepsRaw as $step) {
            $step = trim($step);
            if ($step !== '') {
                $steps[] = htmlspecialchars($step, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
            }
        }

        // Handle image upload
        $imagePath = null;
        if (!empty($_FILES['image']['tmp_name'])) {
            $result = $this->handleImageUpload($_FILES['image']);
            if (isset($result['error'])) {
                $this->sendJson(['error' => $result['error']], 400);
            }
            $imagePath = $result['path'];
        }

        // Build basic fields
        $username = $user->username;
        $timestamp = gmdate('Y-m-d\TH:i:s\Z');
        $id = 'br_' . bin2hex(random_bytes(8));
        $roadmapId = 'rm_' . bin2hex(random_bytes(8));

        $descSanitized    = htmlspecialchars($description, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
        $expectedSanitized = htmlspecialchars($expected, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
        $pageUrlSanitized  = htmlspecialchars($pageUrl, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
        $browserOsSanitized = htmlspecialchars($browserOs, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
        $usernameSanitized = htmlspecialchars($username, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');

        // Attempt to write roadmap item first (with file lock to prevent duplicate display_ids)
        $roadmapResult = $this->saveRoadmapItemAtomic($roadmapId, function (array $existing) use (
            $id, $roadmapId, $descSanitized, $expectedSanitized, $pageUrlSanitized,
            $usernameSanitized, $steps, $timestamp
        ): array {
            $displayId = $this->computeNextDisplayId($existing, 'bug');

            $roadmapItem = [
                'published'          => true,
                'promoted'           => true,
                'roadmap_id'         => $roadmapId,
                'type'               => 'bug',
                'priority'           => 'middel',
                'status'             => 'rapporteret',
                'display_id'         => $displayId,
                'title'              => mb_substr($descSanitized, 0, 80),
                'description'        => $descSanitized,
                'expected'           => $expectedSanitized,
                'steps'              => $steps,
                'page_url'           => $pageUrlSanitized,
                'submitter_username' => $usernameSanitized,
                'source_report_id'   => $id,
                'source_suggestion_id' => '',
                'timestamp'          => $timestamp,
                'vote_count'         => 0,
                'votes'              => [],
                'vote_history'       => [],
                'votes_released'     => false,
            ];

            return ['item' => $roadmapItem, 'display_id' => $displayId];
        });

        if ($roadmapResult === null) {
            // Roadmap write failed — return 500, do NOT write bug report
            $this->sendJson(['error' => 'Serverfejl: Kunne ikke oprette roadmap-element. Rapporten er ikke gemt.'], 500);
        }

        ['display_id' => $displayId] = $roadmapResult;

        // Now build and save the bug report record.
        // roadmap_id is set to the human-readable display_id (e.g. #B003).
        // promoted_item_id retains the internal rm_xxx storage key for cross-reference.
        $record = [
            'username'           => $usernameSanitized,
            'timestamp'          => $timestamp,
            'page_url'           => $pageUrlSanitized,
            'browser_os'         => $browserOsSanitized,
            'description'        => $descSanitized,
            'expected'           => $expectedSanitized,
            'steps'              => $steps,
            'image_path'         => $imagePath,
            'promoted'           => true,
            'promoted_item_id'   => $roadmapId,
            'roadmap_id'         => $displayId,
            'display_id'         => $displayId,
            'title'              => mb_substr($descSanitized, 0, 80),
        ];

        $saved = $this->saveReport($id, $record);
        if (!$saved) {
            // Bug report save failed — rollback the roadmap item
            $this->rollbackRoadmapItem($roadmapId);
            $this->sendJson(['error' => 'Serverfejl: Kunne ikke gemme rapporten. Prøv igen.'], 500);
        }

        // Build roadmap anchor URL (display_id lowercased, # stripped → fragment)
        $fragment   = strtolower(ltrim($displayId, '#'));
        $roadmapUrl = '/roadmap#' . $fragment;

        $this->sendJson([
            'success'     => true,
            'id'          => $id,
            'roadmap_id'  => $roadmapId,
            'display_id'  => $displayId,
            'roadmap_url' => $roadmapUrl,
            'message'     => "Din fejlrapport ({$displayId}) er nu live på roadmappet.",
        ]);
    }

    /**
     * Handle admin promote-to-roadmap AJAX action.
     * Now returns 409 if already promoted (item was auto-published on submission).
     */
    private function handlePromote(): void
    {
        // Must be admin
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorize('admin.super')) {
            $this->sendJson(['error' => 'Ikke autoriseret.'], 401);
        }

        // Validate nonce
        $nonce = $_POST['promote_nonce'] ?? '';
        if (!Utils::verifyNonce($nonce, 'bug-report-promote')) {
            $this->sendJson(['error' => 'Ugyldig token.'], 403);
        }

        $reportId = trim($_POST['report_id'] ?? '');
        if (!$reportId) {
            $this->sendJson(['error' => 'Manglende rapport-ID.'], 400);
        }

        // Load the bug-reports YAML store
        $dataFile = $this->grav['locator']->findResource('user-data://flex-objects/bug-reports.yaml', true, true);
        if (!$dataFile || !file_exists($dataFile)) {
            $this->sendJson(['error' => 'Fejlrapport-databasen ikke fundet.'], 500);
        }

        $reports = \Symfony\Component\Yaml\Yaml::parseFile($dataFile) ?: [];
        if (!isset($reports[$reportId])) {
            $this->sendJson(['error' => 'Rapport ikke fundet.'], 404);
        }

        $report = $reports[$reportId];

        // Check if already promoted — return 409 Conflict
        if (!empty($report['promoted'])) {
            $existingId = $report['promoted_item_id'] ?? $report['roadmap_id'] ?? 'ukendt';
            $this->sendJson([
                'error'            => "Rapporten er allerede publiceret på roadmap (ID: {$existingId}). Brug Flex Objects admin til at redigere elementet.",
                'already_promoted' => true,
                'roadmap_id'       => $existingId,
            ], 409);
        }

        // Legacy path: item was submitted before auto-publish was implemented
        // Create roadmap item with published: true
        $roadmapId = 'rm_' . bin2hex(random_bytes(8));
        $timestamp = gmdate('Y-m-d\TH:i:s\Z');

        $roadmapResult = $this->saveRoadmapItemAtomic($roadmapId, function (array $existing) use (
            $report, $reportId, $roadmapId, $timestamp
        ): array {
            $displayId = $this->computeNextDisplayId($existing, 'bug');

            $roadmapItem = [
                'published'          => true,
                'promoted'           => true,
                'roadmap_id'         => $roadmapId,
                'type'               => 'bug',
                'priority'           => 'middel',
                'status'             => 'rapporteret',
                'display_id'         => $displayId,
                'title'              => mb_substr($report['description'] ?? '', 0, 80),
                'description'        => $report['description'] ?? '',
                'expected'           => $report['expected'] ?? '',
                'steps'              => $report['steps'] ?? [],
                'page_url'           => $report['page_url'] ?? '',
                'submitter_username' => $report['username'] ?? '',
                'source_report_id'   => $reportId,
                'source_suggestion_id' => '',
                'timestamp'          => $timestamp,
                'vote_count'         => 0,
                'votes'              => [],
                'vote_history'       => [],
                'votes_released'     => false,
            ];

            return ['item' => $roadmapItem, 'display_id' => $displayId];
        });

        if ($roadmapResult === null) {
            $this->sendJson(['error' => 'Kunne ikke oprette roadmap-element. Promovering fejlede.'], 500);
        }

        // Update report as promoted
        $reports[$reportId]['promoted']          = true;
        $reports[$reportId]['promoted_item_id']  = $roadmapId;
        $reports[$reportId]['roadmap_id']        = $roadmapId;

        $yaml = \Symfony\Component\Yaml\Yaml::dump($reports, 6, 2);
        file_put_contents($dataFile, $yaml);

        $this->sendJson([
            'success'    => true,
            'item_id'    => $roadmapId,
            'display_id' => $roadmapResult['display_id'],
            'message'    => "Rapport fremmet til roadmap som element {$roadmapId}.",
        ]);
    }

    /**
     * Compute the next display_id for a given type ('bug' → #B001, 'feature' → #F001).
     * Scans existing roadmap items, finds the max numeric suffix, and returns the next.
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

    /**
     * Save a roadmap item atomically using an exclusive file lock to prevent
     * duplicate display_ids under concurrent submissions.
     *
     * The $builder callback receives the current array of roadmap items and
     * must return ['item' => [...], 'display_id' => '...', ...extra].
     * Returns the builder result array on success, or null on failure.
     */
    private function saveRoadmapItemAtomic(string $id, callable $builder): ?array
    {
        $dataDir = $this->grav['locator']->findResource('user-data://flex-objects', true, true);
        if (!is_dir($dataDir)) {
            mkdir($dataDir, 0750, true);
        }

        $dataFile = $dataDir . '/roadmap-items.yaml';

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
            $yaml = \Symfony\Component\Yaml\Yaml::dump($existing, 6, 2);
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
     * Remove a roadmap item by ID (rollback on bug-report save failure).
     */
    private function rollbackRoadmapItem(string $id): void
    {
        $dataDir = $this->grav['locator']->findResource('user-data://flex-objects', true, true);
        $dataFile = $dataDir . '/roadmap-items.yaml';

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
            $yaml = \Symfony\Component\Yaml\Yaml::dump($existing, 6, 2);
            ftruncate($fh, 0);
            rewind($fh);
            fwrite($fh, $yaml);
            fflush($fh);
        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
    }

    /**
     * Validate and store an uploaded image file.
     *
     * @param array $file  $_FILES entry
     * @return array  ['path' => ..., 'url' => ...] on success, ['error' => ...] on failure
     */
    private function handleImageUpload(array $file): array
    {
        $maxSize = (int)$this->config->get('plugins.bug-report.max_image_size', 5242880);

        if ($file['error'] !== UPLOAD_ERR_OK) {
            $msg = match ($file['error']) {
                UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE => 'Billedet er for stort (maks. 5 MB).',
                UPLOAD_ERR_PARTIAL => 'Billedet blev kun delvist uploadet.',
                default => 'Upload-fejl. Prøv igen.',
            };
            return ['error' => $msg];
        }

        if ($file['size'] > $maxSize) {
            return ['error' => 'Billedet er for stort (maks. 5 MB).'];
        }

        // Validate via magic bytes (server-side, not Content-Type)
        $mime = $this->detectMimeType($file['tmp_name']);
        if (!$mime || !isset(self::ALLOWED_MIME[$mime])) {
            return ['error' => 'Ugyldig filtype. Kun JPEG, PNG, GIF og WebP er tilladt.'];
        }

        // Validate file extension too
        $originalName = $file['name'] ?? '';
        $ext = strtolower(pathinfo($originalName, PATHINFO_EXTENSION));
        $allowedExts = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
        if (!in_array($ext, $allowedExts, true)) {
            return ['error' => 'Ugyldig filtype. Kun JPEG, PNG, GIF og WebP er tilladt.'];
        }

        // Generate random filename
        $randomName = bin2hex(random_bytes(16)) . '.' . $ext;

        // Resolve storage directory
        $storageDir = $this->grav['locator']->findResource(
            $this->config->get('plugins.bug-report.image_storage', 'user://data/bug-report-images'),
            true,
            true
        );

        if (!is_dir($storageDir)) {
            if (!mkdir($storageDir, 0750, true)) {
                return ['error' => 'Serverfejl: Kan ikke oprette billedmappe.'];
            }
            // Write .htaccess to block PHP execution and direct access
            file_put_contents($storageDir . '/.htaccess',
                "Options -Indexes\n" .
                "php_flag engine off\n" .
                "<FilesMatch \".*\">\n" .
                "  Order Deny,Allow\n" .
                "  Deny from all\n" .
                "</FilesMatch>\n"
            );
            // Write empty index.html to prevent directory listing
            file_put_contents($storageDir . '/index.html', '');
        }

        $destPath = $storageDir . '/' . $randomName;
        if (!move_uploaded_file($file['tmp_name'], $destPath)) {
            return ['error' => 'Serverfejl: Kan ikke gemme billedet.'];
        }

        return ['path' => 'bug-report-images/' . $randomName];
    }

    /**
     * Detect actual MIME type via magic bytes.
     */
    private function detectMimeType(string $filePath): ?string
    {
        $handle = fopen($filePath, 'rb');
        if (!$handle) {
            return null;
        }
        $bytes = fread($handle, 12);
        fclose($handle);

        if ($bytes === false || strlen($bytes) < 3) {
            return null;
        }

        // JPEG: FF D8 FF
        if (substr($bytes, 0, 3) === "\xFF\xD8\xFF") {
            return 'image/jpeg';
        }

        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if (substr($bytes, 0, 8) === "\x89PNG\r\n\x1a\n") {
            return 'image/png';
        }

        // GIF: GIF87a or GIF89a
        if (substr($bytes, 0, 6) === 'GIF87a' || substr($bytes, 0, 6) === 'GIF89a') {
            return 'image/gif';
        }

        // WebP: RIFF????WEBP
        if (substr($bytes, 0, 4) === 'RIFF' && substr($bytes, 8, 4) === 'WEBP') {
            return 'image/webp';
        }

        return null;
    }

    /**
     * Save a bug report record to the YAML store.
     */
    private function saveReport(string $id, array $record): bool
    {
        $dataDir = $this->grav['locator']->findResource('user-data://flex-objects', true, true);
        if (!is_dir($dataDir)) {
            mkdir($dataDir, 0750, true);
        }

        $dataFile = $dataDir . '/bug-reports.yaml';
        $existing = [];
        if (file_exists($dataFile)) {
            $existing = \Symfony\Component\Yaml\Yaml::parseFile($dataFile) ?: [];
        }

        $existing[$id] = $record;

        $yaml = \Symfony\Component\Yaml\Yaml::dump($existing, 6, 2);
        return file_put_contents($dataFile, $yaml) !== false;
    }

    /**
     * Save a roadmap item to the YAML store (legacy non-atomic method, kept for compatibility).
     */
    private function saveRoadmapItem(string $id, array $record): bool
    {
        $dataDir = $this->grav['locator']->findResource('user-data://flex-objects', true, true);
        if (!is_dir($dataDir)) {
            mkdir($dataDir, 0750, true);
        }

        $dataFile = $dataDir . '/roadmap-items.yaml';
        $existing = [];
        if (file_exists($dataFile)) {
            $existing = \Symfony\Component\Yaml\Yaml::parseFile($dataFile) ?: [];
        }

        $existing[$id] = $record;

        $yaml = \Symfony\Component\Yaml\Yaml::dump($existing, 6, 2);
        return file_put_contents($dataFile, $yaml) !== false;
    }

    /**
     * Serve a bug-report image to authenticated admins only.
     * Route: GET /admin/bug-report-image?file=<randomname.ext>
     */
    private function handleImageServe(): never
    {
        // Must be authenticated admin
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorize('admin.super')) {
            http_response_code(403);
            echo 'Adgang nægtet.';
            exit;
        }

        $file = $_GET['file'] ?? '';
        // Sanitise: allow only basename with safe characters (hex + dot + extension)
        $file = basename($file);
        if (!preg_match('/^[0-9a-f]{32}\.(jpg|jpeg|png|gif|webp)$/i', $file)) {
            http_response_code(400);
            echo 'Ugyldig filnavn.';
            exit;
        }

        $storageDir = $this->grav['locator']->findResource(
            $this->config->get('plugins.bug-report.image_storage', 'user://data/bug-report-images'),
            true,
            true
        );

        $filePath = $storageDir . '/' . $file;
        if (!file_exists($filePath)) {
            http_response_code(404);
            echo 'Billede ikke fundet.';
            exit;
        }

        // Detect MIME type via magic bytes before serving
        $mime = $this->detectMimeType($filePath);
        if (!$mime || !isset(self::ALLOWED_MIME[$mime])) {
            http_response_code(400);
            echo 'Ugyldig filtype.';
            exit;
        }

        $size = filesize($filePath);
        header('Content-Type: ' . $mime);
        header('Content-Length: ' . $size);
        header('Content-Disposition: inline; filename="' . $file . '"');
        header('Cache-Control: private, no-store');
        header('X-Content-Type-Options: nosniff');
        readfile($filePath);
        exit;
    }

    /**
     * Check whether a submission token has already been used (duplicate-submission guard).
     * Tokens are stored in a small YAML file with timestamps; entries older than 5 minutes
     * are pruned on each check to prevent unbounded growth.
     */
    private function isSubmissionTokenUsed(string $token): bool
    {
        $file = $this->getTokenStorePath();
        if (!file_exists($file)) {
            return false;
        }
        $tokens = \Symfony\Component\Yaml\Yaml::parseFile($file) ?: [];
        $now    = time();
        foreach ($tokens as $t => $ts) {
            if ($t === $token && ($now - (int)$ts) < 300) {
                return true;
            }
        }
        return false;
    }

    /**
     * Mark a submission token as used (write timestamp to the token store).
     * Prunes tokens older than 5 minutes.
     */
    private function markSubmissionTokenUsed(string $token): void
    {
        $file   = $this->getTokenStorePath();
        $tokens = file_exists($file) ? (\Symfony\Component\Yaml\Yaml::parseFile($file) ?: []) : [];
        $now    = time();

        // Prune expired tokens
        foreach ($tokens as $t => $ts) {
            if (($now - (int)$ts) >= 300) {
                unset($tokens[$t]);
            }
        }

        $tokens[$token] = $now;
        $yaml = \Symfony\Component\Yaml\Yaml::dump($tokens, 2, 2);
        file_put_contents($file, $yaml, LOCK_EX);
    }

    /**
     * Returns the path to the shared submission-token store file.
     */
    private function getTokenStorePath(): string
    {
        $dataDir = $this->grav['locator']->findResource('user-data://flex-objects', true, true);
        if (!is_dir($dataDir)) {
            mkdir($dataDir, 0750, true);
        }
        return $dataDir . '/submission-tokens.yaml';
    }

    /**
     * Send a JSON response and halt Grav execution.
     */
    private function sendJson(array $data, int $status = 200): never
    {
        $body = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        $response = new Response($status, ['Content-Type' => 'application/json; charset=utf-8'], $body);
        $this->grav->close($response);
    }
}
