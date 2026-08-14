<?php
/**
 * account-password.php — set a new password hash in a Grav account YAML.
 *
 * Invoked by deploy/reset-password.sh: the script substitutes the
 * __PW_B64__ placeholder with the base64 of the new password LOCALLY and
 * pipes the result over SSH into the tier's PHP (`php -- <account-yaml>`).
 * The password therefore only ever travels inside the encrypted SSH stdin
 * channel — never as a process argument on either side, which the login
 * CLI's own -p help text warns is visible to anyone listing processes
 * (this runs on shared hosting).
 *
 * The hash is password_hash(PASSWORD_DEFAULT) — the same call Grav's
 * Authentication uses — and any plaintext `password` field or pending
 * `reset` token is dropped, so outstanding reset links die with the old
 * password. A real YAML parse + atomic rewrite, never sed.
 *
 * Prints exactly `changed` on success; failures print "error: ..." and
 * exit non-zero.
 */

declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit(1);
}

$file = $argv[1] ?? null;
$b64 = '__PW_B64__';

if (!$file) {
    fwrite(STDERR, "error: usage: php -- <account-yaml>\n");
    exit(1);
}
$password = base64_decode($b64, true);
if ($password === false || $password === '' || $b64 === '__PW' . '_B64__') {
    fwrite(STDERR, "error: no password was injected into the script\n");
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

$data['hashed_password'] = password_hash($password, PASSWORD_DEFAULT);
unset($data['password'], $data['reset']);

$yaml = Yaml::dump($data, 6, 2);
$tmp = $file . '.tmp';
if (file_put_contents($tmp, $yaml) === false || !rename($tmp, $file)) {
    @unlink($tmp);
    fwrite(STDERR, "error: cannot write account YAML\n");
    exit(1);
}

echo "changed\n";
