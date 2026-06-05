<?php
/**
 * Standalone CLI probe — confirm feature_enabled / enabled_features are
 * registered as \Twig\TwigFunction instances on the live Grav Twig env.
 *
 * Run via: docker exec grav php /app/www/public/user/plugins/feature-flags/tests/probe_twig.php
 *
 * Not part of phpunit; not loaded by any production code path. Hard-refuses
 * to execute over HTTP to avoid becoming an accidental debug endpoint.
 */

declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit;
}

chdir('/app/www/public');
require '/app/www/public/vendor/autoload.php';

use Grav\Common\Grav;
use Grav\Common\Utils;

$grav = Grav::instance();
$grav['config']->init();
$grav['uri']->init();
$grav['plugins']->init();
$grav->fireEvent('onPluginsInitialized');
// Trigger theme init (required for twig path setup).
$grav['themes']->init();
$grav->fireEvent('onThemeInitialized');
// Twig::init() is what builds $this->twig AND fires onTwigInitialized.
$grav['twig']->init();

$twig = $grav['twig']->twig();
foreach (['feature_enabled', 'enabled_features'] as $name) {
    $fn = $twig->getFunction($name);
    if ($fn === false || $fn === null) {
        fwrite(STDERR, "MISSING: {$name}\n");
        exit(1);
    }
    if (!$fn instanceof \Twig\TwigFunction) {
        fwrite(STDERR, "WRONG TYPE: {$name} is " . get_class($fn) . "\n");
        exit(1);
    }
    echo "OK: {$name} is \\Twig\\TwigFunction\n";
}

// Also smoke-test invocation.
$result = $twig->createTemplate(
    "a={{ feature_enabled('roadmap') ? 'T' : 'F' }} "
    . "b={{ feature_enabled('not_a_real_flag') ? 'T' : 'F' }} "
    . "c=[{% for f in enabled_features() %}{{ f }}{% endfor %}]"
)->render([]);
echo "RENDER: {$result}\n";
