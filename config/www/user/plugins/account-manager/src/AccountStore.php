<?php
/**
 * AccountStore — serialized read-modify-write access to account files
 * (account_self_service_specification.md §4.2).
 *
 * Every mutation loads a FRESH account via the supported $grav['accounts']
 * API and saves through UserInterface::save() (which hashes any plaintext
 * `password`, strips forbidden fields, and clears the Flex user-accounts
 * cache). The whole load-mutate-save runs under an exclusive advisory lock
 * on a plugin-owned sidecar file, so the plugin's own writers — endpoint
 * handlers, the reinstatement login hook, and the purge job — can never
 * interleave and lose fields. Writers outside the plugin (admin panel)
 * are not covered, which matches the login plugin's own exposure today.
 */

declare(strict_types=1);

namespace Grav\Plugin\AccountManager;

use Grav\Common\Grav;
use Grav\Common\User\Interfaces\UserInterface;

final class AccountStore
{
    private const LOCK_FILENAME = '.account-write.lock';

    private Grav $grav;

    public function __construct(Grav $grav)
    {
        $this->grav = $grav;
    }

    /**
     * Fresh, unlocked read. Returns null for unknown accounts.
     *
     * "Fresh" is load-bearing: CompiledYamlFile keeps a per-request static
     * instance per path, and in an authenticated request that instance can
     * already hold a SESSION-EPOCH snapshot of the account (observed: a
     * token expiry backdated on disk being served with its original value).
     * Re-auth and token checks must reflect the on-disk file, so the shared
     * instance's cached content is freed and the account loaded again.
     */
    public function read(string $username): ?UserInterface
    {
        if ($username === '') {
            return null;
        }
        $accounts = $this->grav['accounts'];
        $user = $accounts->load($username);
        $file = $user->file();
        if ($file) {
            $file->free();
            $user = $accounts->load($username);
        }
        return $user->exists() ? $user : null;
    }

    /**
     * Locked read-modify-write: load fresh → $mutator($account) → save.
     *
     * @param callable(UserInterface):void $mutator
     * @throws \RuntimeException when the account is unknown or the lock
     *                           cannot be taken — callers surface a 500.
     */
    public function mutate(string $username, callable $mutator): void
    {
        $fh = fopen($this->lockPath(), 'c');
        if ($fh === false) {
            throw new \RuntimeException('account-manager: cannot open the account write lock');
        }
        try {
            if (!flock($fh, LOCK_EX)) {
                throw new \RuntimeException('account-manager: cannot acquire the account write lock');
            }
            try {
                $account = $this->read($username);
                if ($account === null) {
                    throw new \RuntimeException("account-manager: unknown account `{$username}`");
                }
                $mutator($account);
                $account->save();
            } finally {
                flock($fh, LOCK_UN);
            }
        } finally {
            fclose($fh);
        }
    }

    private function lockPath(): string
    {
        $dir = $this->grav['locator']->findResource('user-data://account-manager', true, true);
        if (!is_dir($dir)) {
            mkdir($dir, 0750, true);
        }
        return $dir . '/' . self::LOCK_FILENAME;
    }
}
