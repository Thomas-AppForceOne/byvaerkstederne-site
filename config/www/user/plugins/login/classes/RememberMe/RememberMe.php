<?php

/**
 * @package    Grav\Plugin\Login
 *
 * @copyright  Copyright (C) 2014 - 2021 RocketTheme, LLC. All rights reserved.
 * @license    MIT License; see LICENSE file for details.
 */

namespace Grav\Plugin\Login\RememberMe;

use Birke\Rememberme\Authenticator;
use Birke\Rememberme\Storage\StorageInterface;

/**
 * RememberMe
 *
 * Handles persistent cookie-storage (Remember Me)
 *
 * @author  Sommerregen <sommerregen@benjamin-regler.de>
 */
class RememberMe extends Authenticator
{
    /**
     * Gets storage interface
     *
     * @return StorageInterface
     */
    public function getStorage()
    {
        return $this->storage;
    }

    /**
     * Set storage interface
     *
     * @param StorageInterface $storage Storage interface
     */
    public function setStorage($storage)
    {
        $this->storage = $storage;
    }

    /**
     * BV-PATCH: race-safe remember-me login. The stock Authenticator::login()
     * rotates the single-use token on every cookie auto-login; two concurrent
     * requests carrying the same cookie (multi-tab session restore, prefetch)
     * make the loser present a now-stale token, get TRIPLET_INVALID, throw a 403
     * (REMEMBER_ME_STOLEN_COOKIE) and wipe the user's ENTIRE token store via
     * cleanAllTriplets — orphaning even the winner's cookie. Here we keep the
     * SAME token and only slide its expiry (idempotent, so racing requests
     * converge), and we treat a stale/tampered cookie as a quiet logout rather
     * than a "stolen cookie" — never setting lastLoginTokenWasInvalid, so the
     * 403 throw in login.php can no longer fire, and never calling
     * cleanAllTriplets, so one bad cookie can't nuke the user's other sessions.
     *
     * @return bool|string Credential string on success, false otherwise
     */
    public function login()
    {
        $cookieValues = $this->getCookieValues();
        if (!$cookieValues) {
            return false;
        }

        switch ($this->storage->findTriplet($cookieValues[0], $cookieValues[1] . $this->salt, $cookieValues[2] . $this->salt)) {
            case StorageInterface::TRIPLET_FOUND:
                // Sliding window: refresh the stored timestamp WITHOUT rotating
                // the token, then re-set the cookie with the SAME value and a
                // fresh expiry.
                $expire = time() + $this->expireTime;
                $this->storage->replaceTriplet($cookieValues[0], $cookieValues[1] . $this->salt, $cookieValues[2] . $this->salt, $expire);
                $this->cookie->setCookie($this->cookieName, implode('|', $cookieValues), $expire);

                return $cookieValues[0];

            case StorageInterface::TRIPLET_INVALID:
                // Stale/tampered cookie: drop it and fall through to anonymous.
                // Deliberately NO lastLoginTokenWasInvalid flag and NO
                // cleanAllTriplets — that pair was the destructive bug.
                $this->cookie->setCookie($this->cookieName, '', time() - $this->expireTime);

                return false;
        }

        return false;
    }
}
