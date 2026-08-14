<?php
/**
 * account-super.php — grant/revoke super-admin in a Grav account YAML.
 *
 * Invoked by deploy/manage-super.sh, piped over SSH into the TIER's own PHP
 * (`php -- <account-yaml> <grant|revoke>`) with the tier dir as CWD so
 * vendor/autoload.php resolves. A real YAML parse + dump (Symfony Yaml, the
 * library Grav itself uses) — never sed — so flow-style lists, quoting and
 * every unrelated field (including hashed_password) survive intact.
 *
 * The right this sets is `access.admin.super: true` ON THE ACCOUNT, not via a
 * group. Two reasons: groups.yaml deliberately confers scoped capabilities
 * WITHOUT admin.login (least privilege — see its header), so a group that
 * granted full super would undermine that design; and the operator-mail
 * recipient resolver (account-manager AccountEmail::adminRecipients) reads
 * this exact field, so a super granted here is a super that gets notified.
 *
 * Revoke removes `admin.super` and prunes the `admin` map when it becomes
 * empty, rather than writing `super: false` — an explicit false and an absent
 * key authorize identically, and a leftover empty map is noise in a file
 * humans read.
 *
 * Prints exactly one status token on success:
 *   changed | already-super | not-super
 * Any failure prints "error: ..." and exits non-zero.
 */

declare(strict_types=1);

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit(1);
}

[$self, $file, $action, $actor] = array_pad($argv, 4, null);

if (!$file || !in_array($action, ['grant', 'revoke'], true)) {
    fwrite(STDERR, "error: usage: php -- <account-yaml> <grant|revoke> [actor]\n");
    exit(1);
}
$actor = (string)($actor ?? '');
if ($actor === '' || !preg_match('/^[A-Za-z0-9._@-]{1,64}$/', $actor)) {
    $actor = 'unknown';
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

$access = (array)($data['access'] ?? []);
$admin = (array)($access['admin'] ?? []);
$current = $admin['super'] ?? false;
$isSuper = $current === true || $current === 1 || $current === 'true' || $current === '1';

$grantedLogin = false;

if ($action === 'grant') {
    if ($isSuper) {
        echo "already-super\n";
        exit(0);
    }
    $admin['super'] = true;
    $access['admin'] = $admin;
    // A super still needs site login: without it the account cannot reach the
    // member surfaces the approval links live on (/konto/access-request/...).
    // Reported back to the caller rather than done silently — a right granted
    // invisibly is one nobody reviews.
    $site = (array)($access['site'] ?? []);
    if (!array_key_exists('login', $site)) {
        $site['login'] = true;
        $grantedLogin = true;
    }
    $access['site'] = $site;
} else {
    if (!$isSuper) {
        echo "not-super\n";
        exit(0);
    }
    unset($admin['super']);
    if ($admin === []) {
        unset($access['admin']);
    } else {
        $access['admin'] = $admin;
    }
}

$data['access'] = $access;

// Atomic replace: full dump to a sibling tmp file, then rename.
$yaml = Yaml::dump($data, 6, 2);
$tmp = $file . '.tmp';
if (file_put_contents($tmp, $yaml) === false || !rename($tmp, $file)) {
    @unlink($tmp);
    fwrite(STDERR, "error: cannot write account YAML\n");
    exit(1);
}

/**
 * Audit trail. In-app rights changes land in account-manager's audit log; a
 * tier-side change used to leave no trace at all beyond the operator's shell
 * history, which is exactly the wrong property for the one action that can
 * hand someone every member's data. Same file, same JSONL shape, so both
 * kinds of change read as one timeline.
 *
 * Best-effort: a failed audit write must not undo a completed rights change,
 * but it IS reported, so "no log entry" can never be mistaken for "nothing
 * happened".
 */
$auditDir = dirname($file, 2) . '/data/account-manager';
$record = [
    'ts' => gmdate('Y-m-d\TH:i:s\Z'),
    'actor' => 'cli:' . $actor,
    'action' => $action === 'grant' ? 'grant_super' : 'revoke_super',
    'target_username' => basename($file, '.yaml'),
    'source' => 'deploy/manage-super.sh',
];
if ($grantedLogin) {
    $record['also_granted'] = 'access.site.login';
}
$audited = false;
if (is_dir($auditDir) || @mkdir($auditDir, 0750, true) || is_dir($auditDir)) {
    $line = json_encode($record, JSON_UNESCAPED_UNICODE) . "\n";
    $fh = @fopen($auditDir . '/account-audit.jsonl', 'a');
    if ($fh !== false) {
        if (flock($fh, LOCK_EX)) {
            fwrite($fh, $line);
            fflush($fh);
            flock($fh, LOCK_UN);
            $audited = true;
        }
        fclose($fh);
    }
}
if (!$audited) {
    fwrite(STDERR, "warning: rights changed but the audit entry could not be written\n");
}

if ($grantedLogin) {
    echo "changed+login\n";
} else {
    echo "changed\n";
}
