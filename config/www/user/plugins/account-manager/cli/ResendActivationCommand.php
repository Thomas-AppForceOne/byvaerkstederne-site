<?php
/**
 * bin/plugin account-manager resend-activation <username> [--dry-run]
 *
 * Re-sends the registration activation email to a member who never
 * completed sign-up.
 *
 * WHY THIS EXISTS
 * ---------------
 * There was no way to do this. Grav's login plugin sends the activation
 * mail during registration and never again; `resend` in this plugin covers
 * an email CHANGE, not activation. The only options for a member whose mail
 * was lost, filtered or expired were to activate their account by hand —
 * skipping the address verification the mail exists to provide — or to
 * delete it so they could register a second time.
 *
 * Found on 2026-08-29: a member registered on production, never activated,
 * and the account sat disabled with nothing an operator could do about it.
 *
 * WHY A CLI COMMAND AND NOT A SCRIPT
 * ----------------------------------
 * The activation mail needs a container that only a real request builds:
 * `user` (the mail template reads it), `Email` (registered by the email
 * plugin on onPluginsInitialized), the theme's template paths for
 * `theme://`, and `base_url` for the activation link. Reconstructing that by
 * hand fails one identifier at a time. ConsoleCommand::initializeThemes()
 * builds it properly — the same reason PurgeDeletedCommand calls it before
 * sending its alerts.
 *
 * ENVIRONMENT MATTERS ON A TIER
 * -----------------------------
 * Grav resolves per-tier config by hostname, and a CLI run resolves to the
 * `cli` environment, NOT the site's host. Without `--env` the SMTP block in
 * user/env/<host>/config/plugins/email.yaml is never loaded and the send
 * either fails or silently goes nowhere. Always pass it on a tier:
 *
 *     bin/plugin --env=www.byvaerkstederne.dk account-manager \
 *         resend-activation <username> --dry-run
 *
 * --dry-run prints the resolved transport so that can be confirmed BEFORE
 * anything is sent or mutated.
 *
 * THE OLD LINK DIES
 * -----------------
 * Login::sendActivationEmail() mints a fresh token and saves the user before
 * handing off to the mailer, so any previous activation link stops working
 * the moment this runs — including when the send then fails. That is why
 * --dry-run mutates nothing, and why the real run says so out loud.
 */

declare(strict_types=1);

namespace Grav\Plugin\Console;

use Grav\Common\Grav;
use Grav\Console\ConsoleCommand;
use Symfony\Component\Console\Input\InputArgument;
use Symfony\Component\Console\Input\InputOption;

class ResendActivationCommand extends ConsoleCommand
{
    protected function configure(): void
    {
        $this
            ->setName('resend-activation')
            ->addArgument(
                'username',
                InputArgument::REQUIRED,
                'The account to re-send the activation email to'
            )
            ->addOption(
                'dry-run',
                null,
                InputOption::VALUE_NONE,
                'Report what would be sent, and the resolved mail transport, without mutating or sending anything'
            )
            ->setDescription('Re-sends the registration activation email to an unactivated account')
            ->setHelp(
                "Mints a fresh activation token and re-sends the registration mail.\n\n"
                . "On a tier, pass --env=<host> or the per-tier SMTP settings are not loaded:\n"
                . "  bin/plugin --env=www.byvaerkstederne.dk account-manager resend-activation bob --dry-run\n\n"
                . "Any previous activation link stops working as soon as this runs."
            );
    }

    protected function serve(): int
    {
        require_once __DIR__ . '/../src/AccountAuditLog.php';
        require_once __DIR__ . '/../src/AccountStore.php';

        // Builds the container the mail path needs: plugins (so the email
        // plugin registers 'Email'), themes (so theme:// resolves for the
        // mail templates), and the rest of the request-shaped services.
        $this->initializeThemes();

        $grav = Grav::instance();
        $username = (string) $this->input->getArgument('username');
        $dryRun = (bool) $this->input->getOption('dry-run');

        // ── The account must exist and actually be waiting for activation ──
        //
        // Through AccountStore, never $grav['accounts']->load() directly:
        // CompiledYamlFile caches a per-path instance, so a bare load can hand
        // back a stale snapshot of the very token this command is about to
        // rotate. AccountStore::read() frees and re-reads. A source guard in
        // tests/anonymous/account-access.js enforces the rule.
        $store = new \Grav\Plugin\AccountManager\AccountStore($grav);
        $user = $store->read($username);
        if (!$user) {
            $this->output->writeln("<error>No account '{$username}'.</error>");
            return 1;
        }
        if (empty($user->email)) {
            $this->output->writeln("<error>'{$username}' has no email address — nothing to send to.</error>");
            return 1;
        }
        if (($user->state ?? '') === 'enabled') {
            $this->output->writeln("<error>'{$username}' is already enabled — there is nothing to activate.</error>");
            $this->output->writeln('    Use reset-password if they cannot get in.');
            return 1;
        }

        $this->output->writeln("account   : {$username} <{$user->email}>");
        $this->output->writeln('state     : ' . ($user->state ?? '(unset)'));

        // Report the transport. On a tier this is how an operator confirms
        // --env resolved the per-host SMTP block before anything is sent.
        $mailer = (array) ($grav['config']->get('plugins.email.mailer') ?? []);
        $engine = (string) ($mailer['engine'] ?? '(none)');
        $server = (string) ($mailer['smtp']['server'] ?? '(none)');
        $port = (string) ($mailer['smtp']['port'] ?? '(none)');
        $from = (string) ($grav['config']->get('plugins.email.from') ?? '(none)');
        $this->output->writeln("transport : {$engine} {$server}:{$port}");
        $this->output->writeln("from      : {$from}");

        if ($engine === 'smtp' && $server === '(none)') {
            $this->output->writeln('');
            $this->output->writeln('<error>The SMTP engine is selected but no server resolved.</error>');
            $this->output->writeln('    On a tier this almost always means --env=<host> was omitted, so');
            $this->output->writeln('    user/env/<host>/config/plugins/email.yaml was never loaded.');
            return 1;
        }

        // The activation LINK must come out absolute, or the mail is useless.
        //
        // Login\Email::sendActivationEmail() prefixes the route with
        // `plugins.login.site_host` and nothing else — Utils::url() alone
        // yields a bare path outside a request. Without it the mail ships
        // `/activate_user/token:…`, which no mail client can follow. Proven
        // locally: with site_host unset the link came out relative even with
        // custom_base_url set and the Uri rebuilt by hand.
        //
        // All four tiers pin site_host in their env login.yaml, so an empty
        // value here means the same thing as an empty SMTP server: --env was
        // omitted and the per-tier config was never loaded.
        //
        // Checked BEFORE sending, because sending mints a new token and kills
        // the member's previous link even when the mail is worthless.
        $siteHost = (string) ($grav['config']->get('plugins.login.site_host') ?? '');
        $this->output->writeln('link host : ' . ($siteHost !== '' ? $siteHost : '(none)'));
        if ($siteHost === '') {
            $this->output->writeln('');
            $this->output->writeln('<error>plugins.login.site_host is empty — the activation link would be a bare path.</error>');
            $this->output->writeln('    The mail would arrive with /activate_user/... and no host, which');
            $this->output->writeln('    nobody can click. Every tier pins site_host in its env login.yaml,');
            $this->output->writeln('    so this means --env=<host> was omitted.');
            return 1;
        }

        $currentToken = (string) ($user->activation_token ?? '');
        $expiry = str_contains($currentToken, '::') ? (int) explode('::', $currentToken, 2)[1] : 0;
        if ($expiry > 0) {
            $this->output->writeln(
                'old link  : ' . ($expiry < time() ? 'already expired' : 'valid until ' . gmdate('Y-m-d H:i', $expiry) . ' UTC')
            );
        }

        if ($dryRun) {
            $this->output->writeln('');
            $this->output->writeln('<comment>[dry-run]</comment> would mint a fresh token and send — nothing changed.');
            return 0;
        }

        // Login is a plain constructor; bin/plugin does not register the
        // 'login' service because that happens on the plugin's own
        // onPluginsInitialized, which is request-scoped.
        $login = isset($grav['login']) ? $grav['login'] : new \Grav\Plugin\Login\Login($grav);

        try {
            $login->sendActivationEmail($user);
        } catch (\Throwable $e) {
            // The token was already rotated and saved by this point — say so,
            // or the operator is left believing the old link still works.
            $this->output->writeln('');
            $this->output->writeln('<error>Send failed: ' . $e->getMessage() . '</error>');
            if ($prev = $e->getPrevious()) {
                $this->output->writeln('    caused by: ' . get_class($prev) . ': ' . $prev->getMessage());
            }
            $this->output->writeln('');
            $this->output->writeln('<comment>The activation token was rotated before the send was attempted,</comment>');
            $this->output->writeln('<comment>so any earlier link is now dead. Re-run once the transport works.</comment>');
            return 1;
        }

        try {
            (new \Grav\Plugin\AccountManager\AccountAuditLog($grav))
                ->append('resend_activation', $username, ['by' => 'cli']);
        } catch (\Throwable $e) {
            // Auditing must never turn a delivered mail into a failure.
            $this->output->writeln('<comment>note: audit log write failed: ' . $e->getMessage() . '</comment>');
        }

        $this->output->writeln('');
        $this->output->writeln("<info>Sent.</info> A fresh activation link is on its way to {$user->email}.");
        $this->output->writeln('Any earlier activation link has stopped working.');

        return 0;
    }
}
