<?php
/**
 * PasswordPolicy — the rule that a regex cannot express.
 *
 * Length is pinned centrally in system.yaml (pwd_regex) because Grav applies
 * it to every flow it owns. What a regex cannot carry sensibly is a blocklist,
 * so it lives here and in config/plugins/account-manager.yaml.
 *
 * The list is deliberately short and specific rather than a 10k-entry dump:
 * the terms an attacker who has read this public repo would try first (the
 * association, the street, the workshops) plus the generic favourites. A
 * password manager's output passes every time; a human's "Byvaerkstederne2026"
 * does not.
 *
 * COVERAGE, stated honestly: registration (via the form-validation hook) and
 * the /konto password change go through here. Grav's own password-RESET form
 * is handled inside the login plugin and does not fire the forms plugin's
 * validation event, so a reset can still set a blocklisted password — the
 * length rule from system.yaml still applies there.
 */

declare(strict_types=1);

namespace Grav\Plugin\AccountManager;

use Grav\Common\Grav;

final class PasswordPolicy
{
    private Grav $grav;

    public function __construct(Grav $grav)
    {
        $this->grav = $grav;
    }

    /**
     * The configured blocklist, lowercased and cleaned.
     *
     * @return list<string>
     */
    public function blocklist(): array
    {
        $raw = (array)$this->grav['config']->get('plugins.account-manager.password.blocklist', []);
        $terms = [];
        foreach ($raw as $term) {
            // YAML turns bare digit strings into ints — cast before trimming.
            $term = mb_strtolower(trim((string)$term));
            if ($term !== '') {
                $terms[] = $term;
            }
        }
        return $terms;
    }

    /**
     * The blocked term a password contains, or null when it is acceptable.
     * Substring match: "Byvaerkstederne2026!" must fail, not just the bare
     * word.
     */
    public function blockedTerm(string $password): ?string
    {
        if ($password === '') {
            return null;
        }
        $candidate = mb_strtolower($password);
        foreach ($this->blocklist() as $term) {
            if (str_contains($candidate, $term)) {
                return $term;
            }
        }
        return null;
    }

    /** Danish rejection shown to the member. Never names the matched term. */
    public function rejectionMessage(): string
    {
        // Naming the term would confirm one guess at a time to anyone probing
        // with someone else's account — and the member does not need it to
        // pick a different password.
        return 'Adgangskoden indeholder et ord, der er for nemt at gætte '
            . '(f.eks. foreningens navn, stedet eller en årstid). Vælg noget andet — '
            . 'gerne en sætning, du kan huske.';
    }
}
