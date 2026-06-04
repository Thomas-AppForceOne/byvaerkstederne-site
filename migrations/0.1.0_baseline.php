<?php
/**
 * Baseline migration — establishes the explicit `0.1.0` marker.
 *
 * The runner treats a missing `data_version` (or a missing
 * `data-version.yaml`) as `0.1.0` by convention, so historical
 * backups stay restorable. This baseline migration is the deliberate
 * "stamp it" step: it ensures the file exists at
 * `$dataDir/config/www/user/data-version.yaml` and that it declares
 * `data_version: "0.1.0"`. Re-running against an already-stamped
 * tree is a no-op.
 *
 * Per the spec §Migration script format: the closure mutates only
 * inside $dataDir, performs no network calls, and finishes by
 * writing the new data_version into data-version.yaml.
 *
 * @param string $dataDir Absolute path to the data tree.
 * @return void           Throws on failure. Idempotent on success.
 */
return function (string $dataDir): void {
    if ($dataDir === '' || !is_dir($dataDir)) {
        throw new \RuntimeException(
            sprintf('baseline: dataDir %s is not a directory', $dataDir)
        );
    }

    $markerDir  = $dataDir . '/config/www/user';
    $markerPath = $markerDir . '/data-version.yaml';

    if (!is_dir($markerDir)) {
        if (!mkdir($markerDir, 0775, true) && !is_dir($markerDir)) {
            throw new \RuntimeException(
                sprintf('baseline: failed to create %s', $markerDir)
            );
        }
    }

    // Idempotent write: only rewrite if the file is missing or its
    // content doesn't match the canonical form. This keeps the
    // byte-comparison after a second run trivially equal.
    $desired = "data_version: \"0.1.0\"\n";
    $current = is_file($markerPath) ? file_get_contents($markerPath) : false;
    if ($current !== $desired) {
        if (file_put_contents($markerPath, $desired) === false) {
            throw new \RuntimeException(
                sprintf('baseline: failed to write %s', $markerPath)
            );
        }
    }
};
