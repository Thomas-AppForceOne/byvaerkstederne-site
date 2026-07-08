<?php
/**
 * AccountValidator — server-side validation for the /konto endpoints
 * (account_self_service_specification.md §4.3), independent of any client
 * checks. Every validator returns ['value' => <normalized>, 'errors' =>
 * list<string>] with Danish, user-facing messages.
 *
 * Flash messages render |raw through partials/messages.html.twig, so no
 * user-controlled value may ever be interpolated into an error message.
 */

declare(strict_types=1);

namespace Grav\Plugin\AccountManager;

final class AccountValidator
{
    /**
     * Display name: trimmed, non-empty, length-bounded, and free of angle
     * brackets (mirrors the registration form's `^[^<>]{1,80}$` rule — the
     * name is rendered in the header chip and event author lines).
     *
     * @return array{value:string,errors:list<string>}
     */
    public static function fullname(string $raw, int $maxLength): array
    {
        $value = trim($raw);
        $errors = [];
        if ($value === '') {
            $errors[] = 'Navnet må ikke være tomt.';
        } elseif (mb_strlen($value) > $maxLength) {
            $errors[] = "Navnet må højst være {$maxLength} tegn.";
        }
        if ($value !== '' && preg_match('/[<>]/', $value)) {
            $errors[] = 'Navnet må ikke indeholde tegnene < eller >.';
        }
        return ['value' => $value, 'errors' => $errors];
    }

    /**
     * Email address for the verify-first change flow. Format-only — whether
     * the address is available is deliberately NOT validated here (the
     * no-enumeration contract answers identically either way).
     *
     * @return array{value:string,errors:list<string>}
     */
    public static function email(string $raw): array
    {
        $value = trim($raw);
        $errors = [];
        if ($value === '' || mb_strlen($value) > 254 || !filter_var($value, FILTER_VALIDATE_EMAIL)) {
            $errors[] = 'Indtast en gyldig e-mailadresse.';
        }
        return ['value' => $value, 'errors' => $errors];
    }

    /**
     * Optional access-request motivation: tags stripped, trimmed, bounded.
     * Rendered into the admin notification email (escaped there as well).
     *
     * @return array{value:string,errors:list<string>}
     */
    public static function motivation(string $raw, int $maxLength): array
    {
        $value = trim(strip_tags($raw));
        $errors = [];
        if (mb_strlen($value) > $maxLength) {
            $errors[] = "Motivationen må højst være {$maxLength} tegn.";
        }
        return ['value' => $value, 'errors' => $errors];
    }

    /**
     * New password entered twice, checked against the site policy regex
     * (`system.pwd_regex` — the same rule the registration form enforces).
     *
     * @return array{value:string,errors:list<string>}
     */
    public static function password(string $password1, string $password2, string $regex): array
    {
        $errors = [];
        if ($password1 === '') {
            $errors[] = 'Adgangskoden må ikke være tom.';
        } elseif ($password1 !== $password2) {
            $errors[] = 'De to adgangskoder er ikke ens.';
        } elseif ($regex !== '' && !preg_match('/' . $regex . '/', $password1)) {
            $errors[] = 'Adgangskoden skal være mindst 8 tegn og indeholde store og små bogstaver samt tal.';
        }
        return ['value' => $password1, 'errors' => $errors];
    }
}
