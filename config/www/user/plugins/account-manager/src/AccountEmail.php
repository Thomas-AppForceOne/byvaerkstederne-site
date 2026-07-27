<?php
/**
 * AccountEmail — transactional mail for account self-service
 * (account_self_service_specification.md §6/§8), modeled on the login
 * plugin's Email class but living entirely in this plugin: templates under
 * templates/emails/account-manager/ (registered via onTwigTemplatePaths),
 * delivery through the email plugin's container service. No login/email
 * plugin PHP is touched.
 *
 * Callers wrap every send in try/catch: a failing mail must never abort a
 * decided mutation, and — for the no-enumeration contract — must never
 * differentiate the UI response.
 */

declare(strict_types=1);

namespace Grav\Plugin\AccountManager;

use Grav\Common\Grav;
use Grav\Common\User\Interfaces\UserInterface;
use Grav\Common\Utils;
use Symfony\Component\Yaml\Yaml;

final class AccountEmail
{
    private Grav $grav;

    public function __construct(Grav $grav)
    {
        $this->grav = $grav;
    }

    /** Confirmation link + expiry to the NEW address (the verify-first step). */
    public function sendEmailChangeConfirm(UserInterface $account, string $newAddress, string $token, int $ttlHours): void
    {
        $this->send('email-change-confirm', $newAddress, [
            'user' => $account,
            'confirm_link' => $this->confirmLink((string)$account->username, $token),
            'ttl_hours' => $ttlHours,
        ]);
    }

    /** Heads-up to the OLD address when a change is requested (hijack visibility). */
    public function sendEmailChangeNotice(UserInterface $account): void
    {
        $this->send('email-change-notice', (string)$account->email, [
            'user' => $account,
        ]);
    }

    /** Completion notice to the OLD address after the swap (hijack visibility). */
    public function sendEmailChangeComplete(string $oldAddress, UserInterface $account): void
    {
        $this->send('email-change-complete', $oldAddress, [
            'user' => $account,
        ]);
    }

    /**
     * Informational mail to the existing owner of a requested address —
     * the visible half of the no-enumeration contract (the requester sees
     * the neutral success-shaped response either way).
     */
    public function sendEmailChangeOccupied(string $address): void
    {
        $this->send('email-change-occupied', $address, []);
    }

    /**
     * Operational alert to the admin recipients — used by the fail-loud
     * paths (purge circuit breaker, missing scheduler heartbeat) where a
     * cron job's discarded output would otherwise hide a broken promise.
     */
    public function sendOpsAlert(string $alertSubject, string $alertBody): void
    {
        $this->sendToAdmins('ops-alert', [
            'alert_subject' => $alertSubject,
            'alert_body' => $alertBody,
        ]);
    }

    /**
     * Deletion-request confirmation to the member: the exact hard-delete
     * date and the sign-in-again reinstatement rule (§2.8). No email is
     * sent at hard delete itself — this mail IS the notice.
     */
    public function sendDeletionRequested(UserInterface $account, string $hardDeleteDate, int $windowDays): void
    {
        $this->send('deletion-requested', (string)$account->email, [
            'user' => $account,
            'hard_delete_date' => $hardDeleteDate,
            'window_days' => $windowDays,
        ]);
    }

    /** Reinstatement confirmation after a login inside the regret window. */
    public function sendAccountReinstated(UserInterface $account): void
    {
        $this->send('account-reinstated', (string)$account->email, [
            'user' => $account,
        ]);
    }

    /**
     * Privilege-escalation alert: an account was granted super-admin.
     *
     * Sent to every super on the tier — including the account that was just
     * promoted, since the recipients are resolved after the change. A rights
     * change made with server tooling is otherwise visible only in a log
     * nobody reads until something has already gone wrong.
     */
    public function sendSuperGrantedAlert(
        string $targetUsername,
        string $targetEmail,
        string $actor,
        string $occurredAt,
        string $source
    ): void {
        $this->sendToAdmins('super-granted', [
            'target_username' => $targetUsername,
            'target_email' => $targetEmail,
            'actor' => $actor,
            'occurred_at' => $occurredAt,
            'source' => $source,
        ]);
    }

    /**
     * Access-request notification to the admin recipients (§8). Granting
     * stays a manual super action in the admin panel — this mail is the
     * only automation.
     */
    public function sendAccessRequestAdmin(UserInterface $account, string $role, string $roleLabel, string $motivation, string $token = ''): void
    {
        $approve_link = '';
        $reject_link = '';
        if ($token !== '') {
            $approve_link = $this->accessRequestApproveLink((string)$account->username, $token);
            $reject_link = $this->accessRequestRejectLink((string)$account->username, $token);
        }

        $this->sendToAdmins('access-request-admin', [
            'user' => $account,
            'role' => $role,
            'role_label' => $roleLabel,
            'motivation' => $motivation,
            'approve_link' => $approve_link,
            'reject_link' => $reject_link,
        ]);
    }

    /** To the applicant: their access request was approved. */
    public function sendAccessRequestApproved(UserInterface $account, string $role, string $roleLabel): void
    {
        $this->send('access-request-approved', (string)$account->email, [
            'user' => $account,
            'role' => $role,
            'role_label' => $roleLabel,
        ]);
    }

    /** To the applicant: their access request was rejected. */
    public function sendAccessRequestRejected(UserInterface $account, string $role, string $roleLabel): void
    {
        $this->send('access-request-rejected', (string)$account->email, [
            'user' => $account,
            'role' => $role,
            'role_label' => $roleLabel,
        ]);
    }

    /** Public URL of the confirm endpoint (activation-link precedent). */
    public function confirmLink(string $username, string $token): string
    {
        $sep = (string)$this->grav['config']->get('system.param_sep', ':');
        // Utils::url($input, $domain, $fail_gracefully): $domain must be true
        // for an absolute URL - mail clients render root-relative hrefs as
        // file:/// links.
        return (string)Utils::url(
            '/konto/confirm-email-change/token' . $sep . $token . '/user' . $sep . $username,
            true,
            true
        );
    }

    /** Approval link for admin access request endpoints. */
    public function accessRequestApproveLink(string $username, string $token): string
    {
        return (string)Utils::url(
            '/konto/access-request/approve?token=' . urlencode($token) . '&username=' . urlencode($username),
            true,
            true
        );
    }

    /** Rejection link for admin access request endpoints. */
    public function accessRequestRejectLink(string $username, string $token): string
    {
        return (string)Utils::url(
            '/konto/access-request/reject?token=' . urlencode($token) . '&username=' . urlencode($username),
            true,
            true
        );
    }

    /**
     * Recipients for the two operator-facing mails (access requests, ops
     * alerts): every ENABLED account holding admin.super, by email address.
     *
     * Sourced from the accounts rather than a config key on purpose — the
     * people who can act on these mails are exactly the people who receive
     * them, and a tier can no longer route operator mail to an address
     * nobody reads just because a per-tier key was never filled in. That
     * silent fallback is what let a dev-tier access request go to the
     * association's contact address instead of the operator working on it.
     *
     * Enumerated by a read-only YAML sweep, the same shape PurgeService
     * uses for whole-directory work. AccountStore's confinement covers
     * $grav['accounts']->load(), whose freshness contract is about
     * read-modify-write; this is neither.
     *
     * @return list<string>
     */
    public function adminRecipients(): array
    {
        $found = [];
        $dir = $this->grav['locator']->findResource('account://');
        if (is_string($dir) && is_dir($dir)) {
            foreach (glob($dir . '/*.yaml') ?: [] as $path) {
                try {
                    $data = Yaml::parse((string)file_get_contents($path));
                } catch (\Throwable $e) {
                    // One malformed account must not silence the others.
                    continue;
                }
                if (!is_array($data)) {
                    continue;
                }
                $super = $data['access']['admin']['super'] ?? false;
                if ($super !== true && $super !== 1 && $super !== 'true' && $super !== '1') {
                    continue;
                }
                // A disabled super cannot act on the mail; Grav treats a
                // missing state as enabled.
                if ((string)($data['state'] ?? 'enabled') !== 'enabled') {
                    continue;
                }
                $email = trim((string)($data['email'] ?? ''));
                if ($email !== '') {
                    $found[$email] = true;
                }
            }
        }

        if ($found === []) {
            // No delivery fallback on purpose. The obvious candidate is the
            // association's public contact address, but whoever reads that
            // mailbox is not necessarily a super and cannot act on an access
            // request — sending there would look like a working notification
            // while quietly landing in the wrong hands. A tier with no
            // reachable super is a misconfiguration; it is logged as an
            // error, the send fails, and the caller tells the member to
            // contact the association so a human can escalate it.
            $this->grav['log']->error(
                'account-manager: no enabled super-admin with an email address — operator mail cannot be delivered'
            );
        }

        return array_keys($found);
    }

    /**
     * Send one operator mail to every admin recipient.
     *
     * One message per recipient, and one failure does not cancel the rest:
     * with several supers a single bad address must not stop the others
     * from being told. Only a total failure propagates, so the caller's
     * existing swallow-and-log still means "nobody was notified".
     *
     * @param array<string,mixed> $context
     */
    private function sendToAdmins(string $template, array $context): void
    {
        $recipients = $this->adminRecipients();
        if ($recipients === []) {
            throw new \RuntimeException('account-manager: no admin recipient resolved for ' . $template);
        }

        $sent = 0;
        $errors = [];
        foreach ($recipients as $to) {
            try {
                $this->send($template, $to, $context);
                $sent++;
            } catch (\Throwable $e) {
                $errors[] = $to . ': ' . $e->getMessage();
            }
        }

        if ($sent === 0) {
            throw new \RuntimeException(
                'account-manager: ' . $template . ' reached no admin (' . implode('; ', $errors) . ')'
            );
        }
        if ($errors !== []) {
            $this->grav['log']->warning(
                'account-manager: ' . $template . ' partially failed — ' . implode('; ', $errors)
            );
        }
    }

    /** @param array<string,mixed> $context */
    private function send(string $template, string $to, array $context): void
    {
        if ($to === '') {
            throw new \RuntimeException('account-manager: empty mail recipient');
        }

        $config = $this->grav['config'];
        $context += [
            'site_name' => (string)$config->get('site.title', 'Byværkstederne'),
            'site_host' => (string)$this->grav['uri']->host(),
        ];

        $params = [
            'to' => $to,
            'body' => '',
            'template' => "emails/account-manager/{$template}.html.twig",
        ];

        $email = $this->grav['Email'];
        $message = $email->buildMessage($params, $context);

        $failedRecipients = null;
        $email->send($message, $failedRecipients);
        if ($failedRecipients) {
            throw new \RuntimeException('account-manager: mail delivery failed for ' . $template);
        }
    }
}
