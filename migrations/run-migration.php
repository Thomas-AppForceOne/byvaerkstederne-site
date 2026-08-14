<?php
/**
 * PHP bootstrap for deploy/migrate.sh.
 *
 * Usage:
 *   php migrations/run-migration.php <migration-file.php> <data-dir>
 *
 * Loads the runner's autoload (Symfony YAML and friends), `require`s
 * the migration file (which `return`s the closure), invokes the
 * closure with $dataDir, then re-reads
 * <data-dir>/user/data-version.yaml so the caller can
 * verify the post-condition.
 *
 * On success: exits 0, prints the post-migration data_version to
 *             stdout on a line shaped `POST_DATA_VERSION=<value>`.
 * On failure: prints the error to stderr and exits with a non-zero
 *             status code that the bash runner can distinguish from
 *             the no-op exit.
 */

declare(strict_types=1);

set_error_handler(static function (int $severity, string $message, string $file, int $line): bool {
    if (!(error_reporting() & $severity)) {
        return false;
    }
    throw new ErrorException($message, 0, $severity, $file, $line);
});

if ($argc !== 3) {
    fwrite(STDERR, "usage: run-migration.php <migration-file> <data-dir>\n");
    exit(64);
}

$migrationFile = $argv[1];
$dataDir       = $argv[2];

if (!is_file($migrationFile)) {
    fwrite(STDERR, sprintf("FATAL: migration file %s does not exist\n", $migrationFile));
    exit(65);
}
if (!is_dir($dataDir)) {
    fwrite(STDERR, sprintf("FATAL: data dir %s does not exist\n", $dataDir));
    exit(66);
}

$autoload = __DIR__ . '/vendor/autoload.php';
if (!is_file($autoload)) {
    fwrite(STDERR, "FATAL: migrations/vendor/autoload.php missing — run `composer install` inside migrations/\n");
    exit(67);
}
require $autoload;

$closure = require $migrationFile;
if (!$closure instanceof Closure) {
    fwrite(STDERR, sprintf(
        "FATAL: migration %s did not return a closure\n",
        $migrationFile
    ));
    exit(68);
}

try {
    $closure($dataDir);
} catch (Throwable $e) {
    fwrite(STDERR, sprintf(
        "MIGRATION_THROW: %s\n  in %s:%d\n",
        $e->getMessage(),
        $e->getFile(),
        $e->getLine()
    ));
    exit(70);
}

$markerPath = $dataDir . '/user/data-version.yaml';
if (!is_file($markerPath)) {
    fwrite(STDERR, sprintf(
        "POST_CONDITION_FAIL: migration finished without writing %s\n",
        $markerPath
    ));
    exit(71);
}

try {
    $parsed = \Symfony\Component\Yaml\Yaml::parseFile($markerPath);
} catch (Throwable $e) {
    fwrite(STDERR, sprintf(
        "POST_CONDITION_FAIL: %s is not valid YAML: %s\n",
        $markerPath,
        $e->getMessage()
    ));
    exit(72);
}

if (!is_array($parsed) || !array_key_exists('data_version', $parsed)) {
    fwrite(STDERR, sprintf(
        "POST_CONDITION_FAIL: %s has no `data_version` field\n",
        $markerPath
    ));
    exit(73);
}

$postVersion = (string) $parsed['data_version'];
fwrite(STDOUT, sprintf("POST_DATA_VERSION=%s\n", $postVersion));
exit(0);
