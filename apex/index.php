<?php
/**
 * hackersbychoice.dk — non-prod tier selector landing page.
 *
 * Served at the apex docroot. Reads each tier's `version.json` (written
 * by deploy/deploy.sh on every deploy) and renders a short selector with
 * version metadata. No Grav, no DB — single self-contained file.
 *
 * NOT for ordinary users. Production lives at www.byvaerkstederne.dk
 * on a separate hosting account.
 */

declare(strict_types=1);

header('X-Robots-Tag: noindex, nofollow, noarchive');
header('Content-Type: text/html; charset=utf-8');

/**
 * Read a tier's `version.json`. Returns a normalised array even when the
 * file is missing or malformed, so the template never has to nullcheck.
 */
function readTierVersion(string $tier): array {
    $base = __DIR__;
    $path = $tier === 'apex' ? "$base/version.json" : "$base/$tier/version.json";

    if (!is_readable($path)) {
        return ['status' => 'missing'];
    }

    $raw = file_get_contents($path);
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        return ['status' => 'malformed'];
    }

    return [
        'status'       => 'ok',
        'tier'         => $data['tier']         ?? '?',
        'branch'       => $data['branch']       ?? '?',
        'sha_short'    => $data['sha_short']    ?? '?',
        'deployed_at'  => $data['deployed_at']  ?? '?',
    ];
}

/** GitHub branch URL — used by the "View commit history" link. */
function commitsUrl(string $branch): string {
    if ($branch === '?' || $branch === '') {
        return 'https://github.com/Thomas-AppForceOne/byvaerkstederne-site/commits';
    }
    return 'https://github.com/Thomas-AppForceOne/byvaerkstederne-site/commits/' . rawurlencode($branch);
}

$tiers = [
    [
        'key'   => 'dev',
        'name'  => 'Dev',
        'host'  => 'dev.hackersbychoice.dk',
        'url'   => 'https://dev.hackersbychoice.dk',
        'accent' => 'tertiary',
        'tagline' => 'Bleeding-edge work in progress',
        'description' => 'Code straight from <code>develop</code>, often with experimental features still being built. Expect rough edges, broken pages, and mid-flight refactors. Useful for developers verifying that something they just merged actually behaves end-to-end. Data is dummy/seed; nothing here is real.',
        'extras' => [],
        'version' => readTierVersion('dev'),
    ],
    [
        'key'   => 'test',
        'name'  => 'Test',
        'host'  => 'test.hackersbychoice.dk',
        'url'   => 'https://test.hackersbychoice.dk',
        'accent' => 'secondary',
        'tagline' => 'Ready for super-user testing',
        'description' => 'Code that has cleared dev review and is stable enough to be exercised by trained super users. Data is dummy/seed, but the site itself should look and behave like the real thing. Bugs found here block promotion to staging — please report what you see.',
        'extras' => [
            ['url' => '/test-instructions.html', 'label' => 'Test instructions'],
        ],
        'version' => readTierVersion('test'),
    ],
    [
        'key'   => 'staging',
        'name'  => 'Staging',
        'host'  => 'staging.hackersbychoice.dk',
        'url'   => 'https://staging.hackersbychoice.dk',
        'accent' => 'primary',
        'tagline' => 'Production rehearsal',
        'description' => 'Production-ready code, with a copy of (or production-shaped) real data. The last rehearsal before <code>www.byvaerkstederne.dk</code> updates. If something works correctly here, it should work correctly in production. If it does not, that is a release blocker.',
        'extras' => [],
        'version' => readTierVersion('staging'),
    ],
];

$apex = readTierVersion('apex');

/** Render an em-dash separator unless it's the first item, used inline. */
function fmtVersion(array $v): string {
    if ($v['status'] !== 'ok') {
        return '<em>' . htmlspecialchars($v['status']) . '</em>';
    }
    return sprintf(
        '<code>%s</code> · <span class="hbc-branch">%s</span> · %s',
        htmlspecialchars($v['sha_short']),
        htmlspecialchars($v['branch']),
        htmlspecialchars($v['deployed_at'])
    );
}

?><!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="robots" content="noindex, nofollow, noarchive">
    <title>hackersbychoice.dk — non-prod environments</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@300..700&family=Work+Sans:wght@300..700&display=swap" rel="stylesheet">
    <link rel="icon" type="image/svg+xml" href="/logo.svg">
    <link rel="stylesheet" href="/landing.css">
</head>
<body>
    <main class="hbc-shell">
        <header class="hbc-hero">
            <img src="/logo.svg" alt="" class="hbc-logo" width="64" height="64">
            <h1 class="hbc-title">hackersbychoice<span class="hbc-title-tld">.dk</span></h1>
            <p class="hbc-lede">
                Non-production environments for the Byværkstederne site. Pick a tier below.
            </p>
            <p class="hbc-warn">
                For developers and super users only.
                The public site lives at
                <a class="hbc-prod-link" href="https://www.byvaerkstederne.dk">www.byvaerkstederne.dk</a>.
            </p>
        </header>

        <section class="hbc-tiers">
            <?php foreach ($tiers as $tier): ?>
            <article class="hbc-card hbc-accent-<?= htmlspecialchars($tier['accent']) ?>">
                <div class="hbc-card-head">
                    <h2 class="hbc-card-title"><?= htmlspecialchars($tier['name']) ?></h2>
                    <p class="hbc-card-tagline"><?= htmlspecialchars($tier['tagline']) ?></p>
                </div>

                <p class="hbc-card-desc"><?= $tier['description'] /* hand-written, contains <code> */ ?></p>

                <dl class="hbc-meta">
                    <dt>Host</dt>
                    <dd><code><?= htmlspecialchars($tier['host']) ?></code></dd>
                    <dt>Version</dt>
                    <dd><?= fmtVersion($tier['version']) ?></dd>
                </dl>

                <div class="hbc-actions">
                    <a class="hbc-btn hbc-btn-primary" href="<?= htmlspecialchars($tier['url']) ?>">Open <?= htmlspecialchars($tier['name']) ?> →</a>
                    <a class="hbc-btn hbc-btn-outlined" href="<?= htmlspecialchars(commitsUrl($tier['version']['branch'] ?? '?')) ?>" rel="noopener">Commit history</a>
                    <?php foreach ($tier['extras'] as $extra): ?>
                    <a class="hbc-btn hbc-btn-outlined" href="<?= htmlspecialchars($extra['url']) ?>"><?= htmlspecialchars($extra['label']) ?></a>
                    <?php endforeach; ?>
                </div>
            </article>
            <?php endforeach; ?>
        </section>

        <footer class="hbc-foot">
            <p>This selector — <?= fmtVersion($apex) ?></p>
            <p class="hbc-foot-source">Source on <a href="https://github.com/Thomas-AppForceOne/byvaerkstederne-site" rel="noopener">GitHub</a>.</p>
        </footer>
    </main>
</body>
</html>
