<?php
/**
 * hackersbychoice.dk — vælger til ikke-offentlige udgaver af Byværkstederne.
 *
 * Bemærk: målgruppen for denne side er super brugere uden teknisk baggrund,
 * ikke udviklere. Hold sproget på dansk og fri af jargon. Versioner vises
 * som SemVer (læst fra repoens VERSION-fil ved deploy), ikke som git-SHA.
 * branch/sha_short ligger fortsat i version.json til drift-fejlsøgning,
 * men landingssiden læser kun `version` og `deployed_at`.
 */

declare(strict_types=1);

header('X-Robots-Tag: noindex, nofollow, noarchive');
header('Content-Type: text/html; charset=utf-8');

/**
 * Læs en udgaves version.json. Returnerer altid et normaliseret array
 * så templaten ikke skal nullchecke.
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
        'status'      => 'ok',
        'version'     => $data['version']     ?? '?',
        'deployed_at' => $data['deployed_at'] ?? '?',
    ];
}

/** Formatér ISO-tidsstempel som dansk dato + klokkeslæt i Europe/Copenhagen. */
function formatDanishDateTime(string $iso): string {
    $months = ['jan.', 'feb.', 'mar.', 'apr.', 'maj', 'jun.', 'jul.', 'aug.', 'sep.', 'okt.', 'nov.', 'dec.'];
    $ts = strtotime($iso);
    if ($ts === false) return $iso;
    $dt = (new DateTime('@' . $ts))->setTimezone(new DateTimeZone('Europe/Copenhagen'));
    return sprintf('%d. %s %d kl. %s',
        (int)$dt->format('d'),
        $months[(int)$dt->format('n') - 1],
        (int)$dt->format('Y'),
        $dt->format('H:i')
    );
}

/** Render version + tidspunkt for et kort, eller en pæn fallback. */
function renderVersionLine(array $v): string {
    if ($v['status'] !== 'ok') {
        return '<em>endnu ikke udrullet</em>';
    }
    return sprintf(
        '<strong>Version %s</strong><br><span class="hbc-deployed">Lagt op %s</span>',
        htmlspecialchars($v['version']),
        htmlspecialchars(formatDanishDateTime($v['deployed_at']))
    );
}

$tiers = [
    [
        'key'   => 'dev',
        'name'  => 'Udviklingsversion',
        'host'  => 'dev.hackersbychoice.dk',
        'url'   => 'https://dev.hackersbychoice.dk',
        'accent' => 'tertiary',
        'tagline' => 'Helt nye ting under opbygning',
        'description' => 'Den allernyeste kode, ofte med funktioner der stadig er ved at blive lavet. Forvent skæve kanter og sider der ikke virker. Bruges primært af udviklere til at se om noget gør hvad det skal. Indholdet er testdata — intet er rigtigt.',
        'extras' => [],
        'cta'   => 'Åbn udviklingsversionen',
        'version' => readTierVersion('dev'),
    ],
    [
        'key'   => 'test',
        'name'  => 'Testversion',
        'host'  => 'test.hackersbychoice.dk',
        'url'   => 'https://test.hackersbychoice.dk',
        'accent' => 'secondary',
        'tagline' => 'Klar til afprøvning af super brugere',
        'description' => 'Kode der har været igennem en første gennemgang og er stabil nok til at blive afprøvet af super brugere. Indholdet er testdata, men selve siden bør se ud og opføre sig som den rigtige. Find du fejl her, så meld dem — så undgår vi at de havner på den rigtige side.',
        'extras' => [
            ['url' => '/test-instructions', 'label' => 'Sådan tester du'],
        ],
        'cta'   => 'Åbn testversionen',
        'version' => readTierVersion('test'),
    ],
    [
        'key'   => 'staging',
        'name'  => 'Generalprøve',
        'host'  => 'staging.hackersbychoice.dk',
        'url'   => 'https://staging.hackersbychoice.dk',
        'accent' => 'primary',
        'tagline' => 'Sidste gennemgang før udgivelse',
        'description' => 'Kode der er klar til udgivelse, vist med rigtige eller virkelighedsnære data. Den allersidste prøve før <code>www.byvaerkstederne.dk</code> opdateres. Hvis det virker her, bør det også virke på den rigtige side.',
        'extras' => [],
        'cta'   => 'Åbn generalprøven',
        'version' => readTierVersion('staging'),
    ],
];

$apex = readTierVersion('apex');

?><!doctype html>
<html lang="da">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="robots" content="noindex, nofollow, noarchive">
    <title>hackersbychoice.dk — testudgaver af Byværkstederne</title>
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
                Her kan du se forskellige udgaver af Byværkstederne, før de lægges på den rigtige hjemmeside.
                Vælg en udgave nedenfor.
            </p>
            <p class="hbc-warn">
                Den rigtige hjemmeside for medlemmer og besøgende ligger på
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

                <p class="hbc-card-desc"><?= $tier['description'] /* hand-written, may contain inline <code> */ ?></p>

                <p class="hbc-card-prep">
                    Forbereder første udgivelse.
                </p>

                <div class="hbc-version">
                    <?= renderVersionLine($tier['version']) ?>
                </div>

                <div class="hbc-actions">
                    <a class="hbc-btn hbc-btn-primary" href="<?= htmlspecialchars($tier['url']) ?>" target="_blank" rel="noopener"><?= htmlspecialchars($tier['cta']) ?> →</a>
                    <?php foreach ($tier['extras'] as $extra): ?>
                    <a class="hbc-btn hbc-btn-outlined" href="<?= htmlspecialchars($extra['url']) ?>"><?= htmlspecialchars($extra['label']) ?></a>
                    <?php endforeach; ?>
                </div>
            </article>
            <?php endforeach; ?>
        </section>

        <footer class="hbc-foot">
            <p>
                Denne side —
                <?php if ($apex['status'] === 'ok'): ?>
                Version <?= htmlspecialchars($apex['version']) ?>,
                opdateret <?= htmlspecialchars(formatDanishDateTime($apex['deployed_at'])) ?>.
                <?php else: ?>
                <em>endnu ikke udrullet</em>.
                <?php endif; ?>
            </p>
        </footer>
    </main>
</body>
</html>
