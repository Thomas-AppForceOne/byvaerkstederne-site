<?php
/**
 * bin/plugin account-manager watch-supers [--dry-run] [--env <tier-host>]
 *
 * Compares the tier's current super-admins against the recorded baseline and
 * alerts every super about anything that appeared. The scheduler runs the
 * same check daily (SuperWatch::runScheduled); this is the manual and
 * testable entry point.
 *
 * REMEMBER --env ON A TIER. Grav resolves its environment from the hostname,
 * which a CLI run does not have, so without it the tier's email.yaml is never
 * loaded and the alert would be composed and delivered nowhere. The command
 * refuses rather than pretend — see the transport guard below.
 */

declare(strict_types=1);

namespace Grav\Plugin\Console;

use Grav\Common\Grav;
use Grav\Console\ConsoleCommand;
use Grav\Plugin\AccountManager\SuperWatch;
use Symfony\Component\Console\Input\InputOption;

class WatchSupersCommand extends ConsoleCommand
{
    protected function configure(): void
    {
        $this
            ->setName('watch-supers')
            ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Report what would be alerted; write nothing, send nothing')
            ->setDescription('Detects super-admins that appeared or vanished since the last run and alerts the supers')
            ->setHelp('The site-side backstop for privilege escalation: it catches a new super however it was created — server tooling, a hand edit, a restored backup or the admin panel.');
    }

    protected function serve(): int
    {
        require_once __DIR__ . '/../src/SuperWatch.php';
        require_once __DIR__ . '/../src/AccountEmail.php';
        require_once __DIR__ . '/../src/AccountAuditLog.php';

        // Registers the email plugin's 'Email' service and the theme template
        // paths the mail extends; bin/plugin fires neither by default.
        $this->initializeThemes();

        $grav = Grav::instance();
        $dryRun = (bool)$this->input->getOption('dry-run');

        $config = $grav['config'];
        $engine = (string)$config->get('plugins.email.mailer.engine', '');
        $server = (string)$config->get('plugins.email.mailer.smtp.server', '');
        $transportOk = $config->get('plugins.email.enabled') === true && $engine !== ''
            && !($engine === 'smtp' && $server === '');
        if (!$transportOk && !$dryRun) {
            $this->output->writeln(
                '<red>watch-supers: no mail transport in this context — an alert would be delivered '
                . 'nowhere. Pass --env &lt;tier-host&gt; so the tier\'s email.yaml is loaded.</red>'
            );
            return 1;
        }

        $result = (new SuperWatch($grav))->check($dryRun);

        if ($result['first_run']) {
            $this->output->writeln(sprintf(
                '<info>watch-supers: baseline recorded for %d super-admin(s) — no alerts on a first run.</info>',
                count($result['current'])
            ));
            return 0;
        }

        foreach ($result['added'] as $username => $email) {
            $this->output->writeln("<yellow>NEW super-admin detected: {$username} ({$email})</yellow>");
        }
        foreach ($result['removed'] as $username => $email) {
            $this->output->writeln("<comment>super-admin no longer present: {$username}</comment>");
        }
        if ($result['added'] === [] && $result['removed'] === []) {
            $this->output->writeln(sprintf(
                '<info>watch-supers: unchanged — %d super-admin(s).</info>',
                count($result['current'])
            ));
        }

        return 0;
    }
}
