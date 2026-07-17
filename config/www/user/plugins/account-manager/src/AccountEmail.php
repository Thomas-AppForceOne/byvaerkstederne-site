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
        $this->send('ops-alert', $this->adminRecipient(), [
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

        $this->send('access-request-admin', $this->adminRecipient(), [
            'user' => $account,
            'role' => $role,
            'role_label' => $roleLabel,
            'motivation' => $motivation,
            'approve_link' => $approve_link,
            'reject_link' => $reject_link,
        ]);
    }

    /** Public URL of the confirm endpoint (activation-link precedent). */
    public function confirmLink(string $username, string $token): string
    {
        $sep = (string)$this->grav['config']->get('system.param_sep', ':');
        return (string)Utils::url(
            '/konto/confirm-email-change/token' . $sep . $token . '/user' . $sep . $username,
            null,
            true
        );
    }

    /** Approval link for admin access request endpoints. */
    public function accessRequestApproveLink(string $username, string $token): string
    {
        return (string)Utils::url(
            '/admin/access-request/approve?token=' . urlencode($token) . '&username=' . urlencode($username),
            null,
            true
        );
    }

    /** Rejection link for admin access request endpoints. */
    public function accessRequestRejectLink(string $username, string $token): string
    {
        return (string)Utils::url(
            '/admin/access-request/reject?token=' . urlencode($token) . '&username=' . urlencode($username),
            null,
            true
        );
    }

    /**
     * Admin notification recipient, resolved from per-tier email config —
     * never hardcoded. plugins.email.to lives in the gitignored env
     * email.yaml; site.author.email is the committed tier-agnostic fallback.
     */
    public function adminRecipient(): string
    {
        $config = $this->grav['config'];
        $to = (string)$config->get('plugins.email.to', '');
        if ($to !== '') {
            return $to;
        }
        return (string)$config->get('site.author.email', '');
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
