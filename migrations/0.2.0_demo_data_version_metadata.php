<?php

use Symfony\Component\Yaml\Yaml;

/**
 * Demo migration — adds a `migrated_at` field to data-version.yaml.
 *
 * Rationale: gives the runner something non-trivial to chew on while
 * keeping the fixture-diff deterministic. The timestamp is read from
 * `$dataDir/.migrated-at-seed` when that file exists, so tests pin a
 * known value into the fixture. In production the seed file isn't
 * present and the migration uses the current UTC instant.
 *
 * Idempotence is achieved by only writing the field when it isn't
 * already set in `data-version.yaml`. A second run sees `migrated_at`
 * already present and leaves the file unchanged.
 *
 * Per the spec §Migration script format: the closure uses
 * Symfony\Yaml (loaded by the runner via migrations/composer.json),
 * touches only `$dataDir`, and finishes by writing the new
 * data_version into data-version.yaml.
 *
 * @param string $dataDir Absolute path to the data tree.
 * @return void           Throws on failure. Idempotent on success.
 */
return function (string $dataDir): void {
    if ($dataDir === '' || !is_dir($dataDir)) {
        throw new \RuntimeException(
            sprintf('demo: dataDir %s is not a directory', $dataDir)
        );
    }

    $markerDir  = $dataDir . '/config/www/user';
    $markerPath = $markerDir . '/data-version.yaml';

    if (!is_dir($markerDir)) {
        if (!mkdir($markerDir, 0775, true) && !is_dir($markerDir)) {
            throw new \RuntimeException(
                sprintf('demo: failed to create %s', $markerDir)
            );
        }
    }

    $current = is_file($markerPath)
        ? (Yaml::parseFile($markerPath) ?: [])
        : [];

    // Idempotence: do not rewrite migrated_at on subsequent runs.
    if (!array_key_exists('migrated_at', $current)) {
        $seedPath = $dataDir . '/.migrated-at-seed';
        if (is_file($seedPath)) {
            $current['migrated_at'] = trim((string) file_get_contents($seedPath));
        } else {
            $current['migrated_at'] = gmdate('Y-m-d\TH:i:s\Z');
        }
    }

    // Always advance the schema version to 0.2.0 — that's this
    // migration's whole point. If we've already written it, this is
    // a no-op-byte rewrite.
    $current['data_version'] = '0.2.0';

    // Render manually so the output is stable across Symfony YAML
    // versions and the data_version stays double-quoted (matching the
    // committed deploy bundle's shape: `data_version: "X.Y.Z"`).
    $lines = [];
    $lines[] = sprintf('data_version: "%s"', $current['data_version']);
    if (array_key_exists('migrated_at', $current)) {
        $lines[] = sprintf('migrated_at: "%s"', $current['migrated_at']);
    }
    // Append any other keys the input file carried — preserves the
    // "mutate only what you must" rule. For the fields we don't own,
    // delegate quoting to Symfony YAML.
    $extras = $current;
    unset($extras['data_version'], $extras['migrated_at']);
    if (!empty($extras)) {
        $lines[] = rtrim(Yaml::dump($extras, 2, 2));
    }
    $rendered = implode("\n", $lines) . "\n";
    if (file_put_contents($markerPath, $rendered) === false) {
        throw new \RuntimeException(
            sprintf('demo: failed to write %s', $markerPath)
        );
    }
};
