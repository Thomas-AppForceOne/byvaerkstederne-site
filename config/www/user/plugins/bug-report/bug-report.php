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

        // Handle admin promote-to-roadmap action
        if ($path === '/admin/bug-report-promote' && ($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
            $this->handlePromote();
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

        // Build record
        $username = $user->username;
        $timestamp = gmdate('Y-m-d\TH:i:s\Z');
        $id = 'br_' . bin2hex(random_bytes(8));

        $record = [
            'username'    => htmlspecialchars($username, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'),
            'timestamp'   => $timestamp,
            'page_url'    => htmlspecialchars($pageUrl, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'),
            'browser_os'  => htmlspecialchars($browserOs, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'),
            'description' => htmlspecialchars($description, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'),
            'expected'    => htmlspecialchars($expected, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'),
            'steps'       => $steps,
            'image_path'  => $imagePath,
            'promoted'    => false,
            'promoted_item_id' => null,
            'title'       => mb_substr($description, 0, 80),
        ];

        // Persist record to Flex Object YAML store
        $saved = $this->saveReport($id, $record);
        if (!$saved) {
            $this->sendJson(['error' => 'Serverfejl: Kunne ikke gemme rapporten. Prøv igen.'], 500);
        }

        $this->sendJson(['success' => true, 'id' => $id]);
    }

    /**
     * Handle admin promote-to-roadmap AJAX action.
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

        // Check if already promoted
        if (!empty($report['promoted'])) {
            $existingId = $report['promoted_item_id'] ?? 'ukendt';
            $this->sendJson([
                'already_promoted' => true,
                'message' => "Rapporten er allerede fremmet til roadmap (ID: {$existingId}).",
                'item_id' => $existingId,
            ]);
        }

        // Create roadmap item
        $roadmapId = 'rm_' . bin2hex(random_bytes(8));
        $roadmapItem = [
            'published'          => false,
            'type'               => 'bug',
            'priority'           => 'middel',
            'status'             => 'rapporteret',
            'title'              => $report['description'] ?? '',
            'description'        => $report['description'] ?? '',
            'expected'           => $report['expected'] ?? '',
            'steps'              => $report['steps'] ?? [],
            'page_url'           => $report['page_url'] ?? '',
            'submitter_username' => $report['username'] ?? '',
            'source_report_id'   => $reportId,
            'timestamp'          => gmdate('Y-m-d\TH:i:s\Z'),
            'vote_count'         => 0,
            'votes'              => [],
        ];

        $roadmapSaved = $this->saveRoadmapItem($roadmapId, $roadmapItem);
        if (!$roadmapSaved) {
            $this->sendJson(['error' => 'Kunne ikke oprette roadmap-element. Promovering fejlede.'], 500);
        }

        // Update report as promoted
        $reports[$reportId]['promoted'] = true;
        $reports[$reportId]['promoted_item_id'] = $roadmapId;

        $yaml = \Symfony\Component\Yaml\Yaml::dump($reports, 6, 2);
        file_put_contents($dataFile, $yaml);

        $this->sendJson([
            'success'  => true,
            'item_id'  => $roadmapId,
            'message'  => "Rapport fremmet til roadmap som element {$roadmapId}.",
        ]);
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
     * Save a roadmap item to the YAML store.
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
     * Send a JSON response and halt Grav execution.
     */
    private function sendJson(array $data, int $status = 200): never
    {
        $body = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        $response = new Response($status, ['Content-Type' => 'application/json; charset=utf-8'], $body);
        $this->grav->close($response);
    }
}
