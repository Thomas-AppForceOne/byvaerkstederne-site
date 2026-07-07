<?php
/**
 * account-groups.php — grant/revoke a group in a Grav account YAML.
 *
 * Invoked by deploy/manage-groups.sh, piped over SSH into the TIER's own
 * PHP (`php -- <account-yaml> <group> <grant|revoke>`) with the tier dir as
 * CWD so vendor/autoload.php resolves. A real YAML parse + dump (Symfony
 * Yaml, same library Grav uses) — never sed — so flow-style lists, quoting
 * and every unrelated field (including hashed_password) survive intact.
 *
 * Prints exactly one status token on success:
 *   changed | already-member | not-a-member
 * Any failure prints "error: ..." and exits non-zero.
 */

declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit(1);
}

[$self, $file, $group, $action] = array_pad($argv, 4, null);

if (!$file || !$group || !in_array($action, ['grant', 'revoke'], true)) {
    fwrite(STDERR, "error: usage: php -- <account-yaml> <group> <grant|revoke>\n");
    exit(1);
}
if (!preg_match('/^[a-z0-9_-]+$/', $group)) {
    fwrite(STDERR, "error: unsafe group name\n");
    exit(1);
}
if (!is_file($file)) {
    fwrite(STDERR, "error: account file not found: {$file}\n");
    exit(1);
}
if (!is_file('vendor/autoload.php')) {
    fwrite(STDERR, "error: vendor/autoload.php not found — run from the tier's Grav root\n");
    exit(1);
}

require 'vendor/autoload.php';

use Symfony\Component\Yaml\Yaml;

try {
    $data = Yaml::parseFile($file);
} catch (\Throwable $e) {
    fwrite(STDERR, 'error: cannot parse account YAML: ' . $e->getMessage() . "\n");
    exit(1);
}
if (!is_array($data)) {
    fwrite(STDERR, "error: account YAML is not a map\n");
    exit(1);
}

$groups = array_values(array_filter((array)($data['groups'] ?? []), 'is_string'));

if ($action === 'grant') {
    if (in_array($group, $groups, true)) {
        echo "already-member\n";
        exit(0);
    }
    $groups[] = $group;
} else {
    $index = array_search($group, $groups, true);
    if ($index === false) {
        echo "not-a-member\n";
        exit(0);
    }
    unset($groups[$index]);
    $groups = array_values($groups);
}

if ($groups !== []) {
    $data['groups'] = $groups;
} else {
    unset($data['groups']);
}

// Atomic replace: full dump to a sibling tmp file, then rename.
$yaml = Yaml::dump($data, 6, 2);
$tmp = $file . '.tmp';
if (file_put_contents($tmp, $yaml) === false || !rename($tmp, $file)) {
    @unlink($tmp);
    fwrite(STDERR, "error: cannot write account YAML\n");
    exit(1);
}

echo "changed\n";
