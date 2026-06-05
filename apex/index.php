<?php
/**
 * hackersbychoice.dk — vælger til ikke-offentlige udgaver af Byværkstederne.
 *
 * Bemærk: målgruppen for denne side er super brugere uden teknisk baggrund,
 * ikke udviklere. Hold sproget på dansk og fri af jargon. Versioner vises
 * som SemVer (læst fra repoens VERSION-fil ved deploy), ikke som git-SHA.
 * branch/sha_short ligger fortsat i version.json til drift-fejlsøgning,
 * men landingssiden læser kun `version`, `build` og `deployed_at`.
 *
 * Apex-egne værdier:
 *   - apex/VERSION  — manuelt redigeret, committet
 *   - apex/BUILD    — auto-genereret af deploy/deploy.sh, ikke committet
 * Begge filer læses ved request-tid (ikke fra version.json) og valideres
 * mod samme regex som site-version-pluginet på Grav-siden. Logning sker
 * via PHP's error_log() — ingen Grav-stack tilgængelig her.
 */

declare(strict_types=1);

header('X-Robots-Tag: noindex, nofollow, noarchive');
header('Content-Type: text/html; charset=utf-8');

// VERSION/BUILD reader — extracted to apex/site_version.php so the
// Sprint-3 shell-level probe (tests/version/) can `require` it without
// rendering the full landing page. Behaviour preserved verbatim; this
// file just delegates.
require_once __DIR__ . '/site_version.php';

/**
 * Læs en udgaves version.json. Returnerer altid et normaliseret array
 * så templaten ikke skal nullchecke. Schema efter Sprint 1: { tier,
 * version, build, deployed_at, branch, sha_short }.
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

    // Validate version.json's `version` and `build` fields against the
    // same regex contract as the on-disk VERSION/BUILD files. A tier
    // whose manifest is missing/invalid for either field still surfaces
    // partial info if the other half is valid.
    $rawVersion = isset($data['version']) && is_string($data['version']) ? trim($data['version']) : '';
    $rawBuild   = isset($data['build'])   && is_string($data['build'])   ? trim($data['build'])   : '';
    $version = ($rawVersion !== '' && preg_match(APEX_VERSION_REGEX, $rawVersion)) ? $rawVersion : null;
    $build   = ($rawBuild   !== '' && preg_match(APEX_BUILD_REGEX,   $rawBuild))   ? $rawBuild   : null;

    return [
        'status'      => 'ok',
        'version'     => $version,
        'build'       => $build,
        'deployed_at' => isset($data['deployed_at']) && is_string($data['deployed_at']) ? $data['deployed_at'] : '',
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

/**
 * Render det kombinerede "Version X · build N" på et udgaveskort, plus
 * "Lagt op …" tidsstemplet under. Hvis tieren slet ikke har en
 * gyldig version.json (status != ok), eller hverken `version` eller
 * `build` kunne valideres, falder vi tilbage til den eksisterende
 * "endnu ikke udrullet"-fallback. Hvis kun den ene halvdel mangler,
 * viser vi den der findes plus <em>ukendt</em> for den manglende.
 *
 * U+00B7 (interpunkt) bruges som adskiller mellem version og build,
 * matchende formatet i Grav-sidens footer.
 */
function renderVersionLine(array $v): string {
    if ($v['status'] !== 'ok') {
        return '<em>endnu ikke udrullet</em>';
    }
    $version = $v['version'] ?? null;
    $build   = $v['build']   ?? null;
    if ($version === null && $build === null) {
        return '<em>endnu ikke udrullet</em>';
    }
    $vHtml = $version !== null ? htmlspecialchars($version) : '<em>ukendt</em>';
    $bHtml = $build   !== null ? htmlspecialchars($build)   : '<em>ukendt</em>';
    $deployedAt = $v['deployed_at'] ?? '';
    $deployedHtml = $deployedAt !== ''
        ? sprintf('<br><span class="hbc-deployed">Lagt op %s</span>',
            htmlspecialchars(formatDanishDateTime($deployedAt)))
        : '';
    // Literal U+00B7 interpunct between version and build halves,
    // matching the Grav-site footer.
    return sprintf(
        '<strong>Version %s · build %s</strong>%s',
        $vHtml,
        $bHtml,
        $deployedHtml
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

// Apex footer reads VERSION and BUILD directly from the on-disk files
// at request time (NOT from apex/version.json). The "opdateret <DATE>"
// timestamp continues to come from version.json — the deploy script is
// the only thing that knows when this commit was uploaded; the source
// tree itself doesn't carry deploy time.
$apexVersion = readApexSiteVersion();
$apexManifest = readTierVersion('apex');
$apexDeployedAt = ($apexManifest['status'] === 'ok' && !empty($apexManifest['deployed_at']))
    ? $apexManifest['deployed_at']
    : '';

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
            <?php
            // Robust footer: render the combined "Denne side — Version X · build N,
            // opdateret <DATE>" line when at least one of the apex VERSION/BUILD
            // values is present. If BOTH are missing/malformed, omit the entire
            // "Denne side" line rather than emit "Version ukendt · build ukendt".
            // The "opdateret <DATE>" half is preserved from the previous footer
            // and is sourced from apex/version.json's deployed_at field.
            $hasVersion = $apexVersion['version'] !== null;
            $hasBuild   = $apexVersion['build']   !== null;
            ?>
            <?php if ($hasVersion || $hasBuild): ?>
            <p><?php
                echo 'Denne side — Version ';
                echo $hasVersion ? htmlspecialchars($apexVersion['version']) : '<em>ukendt</em>';
                echo ' · build ';
                echo $hasBuild ? htmlspecialchars($apexVersion['build']) : '<em>ukendt</em>';
                if ($apexDeployedAt !== '') {
                    echo ', opdateret ' . htmlspecialchars(formatDanishDateTime($apexDeployedAt));
                }
                echo '.';
            ?></p>
            <?php elseif ($apexDeployedAt !== ''): ?>
            <p>Denne side — opdateret <?= htmlspecialchars(formatDanishDateTime($apexDeployedAt)) ?>.</p>
            <?php endif ?>
        </footer>
    </main>
</body>
</html>
