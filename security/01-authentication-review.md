# Authentication & Session Security Review
**Date:** 2026-04-12  
**Reviewer:** Thomas (thomasadmin)  
**Scope:** Grav Login plugin v3.8.0 — registration, login overlay, session handling, logout  
**Status:** COMPLETE — all findings resolved or accepted

---

## Summary

The Grav Login plugin provides the authentication backbone for Byværkstederne. This checklist covers every item required by the Sprint 4 security contract. Seven items were examined; findings are documented with severity and resolution status.

---

## Checklist

### Item 1: Brute-Force / Rate-Limiting Protection on the Login Endpoint

**Finding:** The Grav Login plugin implements a `RateLimiter` class (`classes/RateLimiter.php`). The site configuration (`user/config/plugins/login.yaml`) sets:
```yaml
max_login_count: 5
max_login_interval: 10
```
This means a maximum of 5 failed login attempts per IP within a 10-minute window before the account is locked from that IP. The `LoginCache` class persists attempt counts between requests.

**IPv6 handling:** `ipv6_subnet_size: 64` is configured, so IPv6 subnets are grouped to prevent trivial bypass by cycling addresses.

**Status:** PRESENT  
**Severity:** N/A — control is active  
**Resolution:** No action required. Rate limiting is correctly configured.

---

### Item 2: Session Cookie Flags (Secure, HttpOnly, SameSite)

**Finding:** Grav's session configuration does not explicitly set `secure`, `httponly`, or `samesite` flags in `user/config/system.yaml`. Grav relies on PHP's default session cookie settings.

PHP's defaults (as of PHP 7.x and 8.x):
- `session.cookie_httponly` defaults to `0` (OFF) unless configured in `php.ini`.
- `session.cookie_secure` defaults to `0` unless configured.
- `session.cookie_samesite` defaults to empty string.

The custom `php-local.ini` at `config/php/php-local.ini` does not currently set these session cookie flags.

**Action taken:** Added to `config/php/php-local.ini`:
```ini
session.cookie_httponly = 1
session.cookie_secure = 1
session.cookie_samesite = "Lax"
```
See commit: `security/fix-session-cookie-flags`

**Status:** FINDING → FIXED  
**Severity:** HIGH  
**Resolution:** Fixed — session cookie flags now set server-side in php-local.ini.

---

### Item 3: Session Fixation Prevention (New Session ID After Login)

**Finding:** The Grav Login plugin (`login.php`, line 1276) calls `$session->regenerateId()` on successful authentication. This regenerates the PHP session ID after login, preventing session fixation attacks where an attacker pre-sets a known session ID before the victim authenticates.

Code reference: `user/plugins/login/login.php:1276`
```php
$session->regenerateId();
```

**Status:** PRESENT  
**Severity:** N/A — control is active  
**Resolution:** No action required.

---

### Item 4: Account Enumeration Risk via Differential Error Messages or Response Timing

**Finding:** The Grav Login plugin returns a generic error message for both invalid username and invalid password cases. Reviewing `classes/Login.php` and the login flow, the plugin does not differentiate between "user not found" and "wrong password" in its user-facing messages. The login form at `/login` returns the same flash message for both failure modes.

However, **response timing** can still potentially leak username existence because the bcrypt comparison is only performed when a user record exists. This is a low-severity accepted risk for a community site of this size — a full timing-safe comparison would require a dummy hash compare, which is outside the Grav Login plugin's scope without forking it.

**Status:** PARTIAL  
**Severity:** LOW  
**Resolution:** ACCEPTED RISK — error messages are generic (no differential message). Timing side-channel is theoretical at this scale. Documented for future consideration if the platform scales significantly.

---

### Item 5: Password Minimum-Complexity Requirements Enforced Server-Side

**Finding:** The Grav Login plugin's `validateField()` method in `classes/Login.php` (line 379) uses a regex from `system.pwd_regex` to validate passwords server-side. The Grav default `pwd_regex` requires:
- Minimum 8 characters
- At least one uppercase letter
- At least one lowercase letter  
- At least one digit

This is enforced on the server regardless of client-side JavaScript. The registration template (`register.html.twig`) also includes client-side validation that mirrors these requirements, but the server-side enforcement is the authoritative check.

**Note:** The site's `user/config/plugins/login.yaml` has `validate_password1_and_password2: false` — this means there is only one password field in the registration form, which is acceptable as there is only one password input rendered.

**Status:** PRESENT  
**Severity:** N/A — control is active  
**Resolution:** No action required.

---

### Item 6: Session Invalidation on Logout (Server-Side Token Destruction, Not Only Cookie Deletion)

**Finding:** The Grav Login plugin calls `$session->invalidate()->start()` on logout (line 1311 of `login.php`). The `invalidate()` call destroys the server-side session data and regenerates a new session ID. This is correct — logout invalidates the session on the server, not merely by deleting the client cookie.

The logout link in the navigation template uses a nonce:
```twig
{% set logout_url = uri.addNonce(logout_path ~ '/task:login.logout', 'logout-form', 'logout-nonce') %}
```
This ensures logout cannot be triggered by CSRF.

**Status:** PRESENT  
**Severity:** N/A — control is active  
**Resolution:** No action required.

---

### Item 7: Remember-Me Token Handling

**Finding:** The plugin has `rememberme.enabled: true` with a 7-day timeout (604800 seconds). The remember-me implementation uses the `mober/rememberme` library (v1.0.5), which implements a secure token-based approach:
- A random token is stored in the browser cookie.
- A hashed version of the token is stored server-side in `user/data/rememberme/`.
- On each auto-login, the token is validated against the stored hash and a new token is issued (token rotation).
- If a stolen token is detected (old token reuse after rotation), all remember-me sessions for that user are invalidated.

The cookie name is `grav-rememberme`. This cookie should carry the `HttpOnly` and `Secure` flags — see Item 2 for the fix applied to PHP session cookies. However, the remember-me cookie is set by PHP's `setcookie()` in the library, **not** by the PHP session mechanism, so the `php.ini` flags do not apply to it automatically.

**Action taken:** Reviewed `user/plugins/login/vendor/mober/rememberme` cookie setting. The `Birke\Rememberme\Cookie` class sets the cookie with `httponly: true` and respects HTTPS when the `secure` parameter is passed. The Grav Login plugin passes `$secure = $this->grav['uri']->isSSL()` when creating the cookie — this means on production (HTTPS) the cookie will have the Secure flag set. On local HTTP development, the Secure flag will not be set, which is acceptable.

**Status:** PRESENT (with conditional Secure flag — correct for the environment)  
**Severity:** LOW (development-environment only gap, not a production issue)  
**Resolution:** ACCEPTED RISK — Secure flag is set in production HTTPS environment by design.

---

## Overall Assessment

| Item | Control Present | Severity | Resolution |
|------|----------------|----------|------------|
| 1. Brute-force rate limiting | ✅ Yes | — | No action required |
| 2. Session cookie flags | ⚠️ Missing | HIGH | **FIXED** in php-local.ini |
| 3. Session fixation prevention | ✅ Yes | — | No action required |
| 4. Account enumeration | ⚠️ Partial (timing) | LOW | Accepted risk |
| 5. Password complexity (server-side) | ✅ Yes | — | No action required |
| 6. Server-side session invalidation on logout | ✅ Yes | — | No action required |
| 7. Remember-me token handling | ✅ Yes | LOW | Accepted risk (dev only) |

**High/Critical findings:** 1  
**All high/critical resolved:** ✅ YES (Item 2 — fixed in php-local.ini)
