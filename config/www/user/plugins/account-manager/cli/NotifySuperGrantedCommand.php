<?php
/**
 * bin/plugin account-manager notify-super-granted --user <username> [--actor <who>]
 *
 * Tells every super-admin on the tier that an account was granted super.
 * Invoked over SSH by deploy/manage-super.sh right after the rights change
 * lands, so a promotion made with server tooling reaches the people it
 * concerns instead of sitting in a log file until something goes wrong.
 *
 * Separate from the rights change itself on purpose: the YAML edit
 * (deploy/lib/account-super.php) must not depend on a working mailer, and a
 * mail failure must never leave a half-applied grant. This runs after, and
 * reports its own failure without undoing anything.
 */

declare(strict_types=1);

namespace Grav\Plugin\Console;

use Grav\Common\Grav;
use Grav\Console\ConsoleCommand;
use Grav\Plugin\AccountManager\AccountEmail;
use Symfony\Component\Console\Input\InputOption;

class NotifySuperGrantedCommand extends ConsoleCommand
{
    protected function configure(): void
    {
        $this
            ->setName('notify-super-granted')
            ->addOption('user', null, InputOption::VALUE_REQUIRED, 'Username that was granted super-admin')
            ->addOption('actor', null, InputOption::VALUE_REQUIRED, 'Who performed the change (operator@host)')
            ->addOption('source', null, InputOption::VALUE_REQUIRED, 'Tool that performed the change')
            ->setDescription('Alerts every super-admin that an account was granted super-admin rights')
            ->setHelp('Sent by deploy/manage-super.sh after a grant. Recipients are resolved from the accounts, so the newly promoted account is told too.');
    }

    protected function serve(): int
    {
        // The plugin's PSR-4 autoloader is not registered in the bin/plugin
        // context — load the service classes directly.
        require_once __DIR__ . '/../src/AccountEmail.php';

        $username = (string)($this->input->getOption('user') ?? '');
        if ($username === '' || !preg_match('/^[A-Za-z0-9._-]{1,64}$/', $username)) {
            $this->output->writeln('<red>notify-super-granted: --user is required and must be a plain username</red>');
            return 1;
        }
        $actor = (string)($this->input->getOption('actor') ?? '');
        if ($actor === '' || !preg_match('/^[A-Za-z0-9._@-]{1,64}$/', $actor)) {
            $actor = 'unknown';
        }
        $source = (string)($this->input->getOption('source') ?? '');
        if ($source === '' || !preg_match('#^[A-Za-z0-9._/-]{1,64}$#', $source)) {
            $source = 'deploy/manage-super.sh';
        }

        // The email plugin registers its 'Email' service on
        // onPluginsInitialized, which bin/plugin does NOT fire by default —
        // without this the send dies with 'Identifier "Email" is not defined'.
        // Themes too: the mail templates extend email/base.html.twig, and the
        // theme's template paths are only on the Twig loader once themes are
        // initialized.
        $this->initializeThemes();

        $grav = Grav::instance();

        // Read the address straight off the account file: this runs in a CLI
        // context where the Flex account index may be stale right after the
        // edit, and the address is only used to identify the account in the
        // mail.
        $targetEmail = '';
        $dir = $grav['locator']->findResource('account://');
        if (is_string($dir) && is_file($dir . '/' . $username . '.yaml')) {
            $parsed = \Symfony\Component\Yaml\Yaml::parseFile($dir . '/' . $username . '.yaml');
            if (is_array($parsed)) {
                $targetEmail = (string)($parsed['email'] ?? '');
            }
        }

        try {
            (new AccountEmail($grav))->sendSuperGrantedAlert(
                $username,
                $targetEmail,
                $actor,
                gmdate('Y-m-d H:i:s'),
                $source
            );
        } catch (\Throwable $e) {
            // Non-zero so the caller can surface it; the rights change stands.
            $this->output->writeln('<red>notify-super-granted: ' . $e->getMessage() . '</red>');
            return 1;
        }

        $this->output->writeln('<green>notify-super-granted: super-admins alerted about ' . $username . '</green>');
        return 0;
    }
}
