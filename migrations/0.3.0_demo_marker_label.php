<?php

use Symfony\Component\Yaml\Yaml;

/**
 * Demo migration — adds a `marker_label` field to data-version.yaml,
 * derived deterministically from `$dataDir/.marker-label-seed` (with
 * an "unspecified" fallback when the seed file is absent).
 *
 * Like the 0.2.0 demo, this migration's job is to give the runner
 * something non-trivial to walk through. It's expressly composable
 * with 0.2.0_demo_data_version_metadata: when the chain runs both,
 * the resulting data-version.yaml carries `data_version`,
 * `migrated_at`, and `marker_label`.
 *
 * Idempotence: only writes marker_label when it isn't already set.
 * The data_version field is unconditionally advanced to 0.3.0.
 *
 * @param string $dataDir Absolute path to the data tree.
 * @return void           Throws on failure. Idempotent on success.
 */
return function (string $dataDir): void {
    if ($dataDir === '' || !is_dir($dataDir)) {
        throw new \RuntimeException(
            sprintf('demo-0.3.0: dataDir %s is not a directory', $dataDir)
        );
    }

    $markerDir  = $dataDir . '/config/www/user';
    $markerPath = $markerDir . '/data-version.yaml';

    if (!is_dir($markerDir)) {
        if (!mkdir($markerDir, 0775, true) && !is_dir($markerDir)) {
            throw new \RuntimeException(
                sprintf('demo-0.3.0: failed to create %s', $markerDir)
            );
        }
    }

    $current = is_file($markerPath)
        ? (Yaml::parseFile($markerPath) ?: [])
        : [];

    if (!array_key_exists('marker_label', $current)) {
        $seedPath = $dataDir . '/.marker-label-seed';
        $current['marker_label'] = is_file($seedPath)
            ? trim((string) file_get_contents($seedPath))
            : 'unspecified';
    }

    $current['data_version'] = '0.3.0';

    // Manual rendering for deterministic, double-quoted output —
    // see 0.2.0_demo_data_version_metadata.php for rationale.
    $lines = [];
    $lines[] = sprintf('data_version: "%s"', $current['data_version']);
    if (array_key_exists('migrated_at', $current)) {
        $lines[] = sprintf('migrated_at: "%s"', $current['migrated_at']);
    }
    if (array_key_exists('marker_label', $current)) {
        $lines[] = sprintf('marker_label: "%s"', $current['marker_label']);
    }
    $extras = $current;
    unset($extras['data_version'], $extras['migrated_at'], $extras['marker_label']);
    if (!empty($extras)) {
        $lines[] = rtrim(Yaml::dump($extras, 2, 2));
    }
    $rendered = implode("\n", $lines) . "\n";
    if (file_put_contents($markerPath, $rendered) === false) {
        throw new \RuntimeException(
            sprintf('demo-0.3.0: failed to write %s', $markerPath)
        );
    }
};
