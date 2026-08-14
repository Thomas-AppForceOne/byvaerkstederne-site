<?php
/**
 * bin/plugin account-manager purge-deleted [--dry-run]
 *
 * The operational entry point for the §7 hard-delete + anonymization job —
 * what the tests invoke and what an operator runs manually. The daily
 * scheduler job (onSchedulerInitialized → account-manager-purge) wraps the
 * same PurgeService.
 */

declare(strict_types=1);

namespace Grav\Plugin\Console;

use Grav\Common\Grav;
use Grav\Console\ConsoleCommand;
use Grav\Plugin\AccountManager\PurgeService;
use Symfony\Component\Console\Input\InputOption;

class PurgeDeletedCommand extends ConsoleCommand
{
    protected function configure(): void
    {
        $this
            ->setName('purge-deleted')
            ->addOption(
                'dry-run',
                null,
                InputOption::VALUE_NONE,
                'List the accounts whose regret window has lapsed without deleting anything'
            )
            ->addOption(
                'ignore-cap',
                null,
                InputOption::VALUE_NONE,
                'Proceed even when the lapsed count exceeds deletion.max_per_run (after a manual dry-run inspection)'
            )
            ->setDescription('Hard-deletes accounts whose 30-day deletion window has lapsed and anonymizes their footprint')
            ->setHelp('Runs the account_self_service §7 purge: removes lapsed accounts, rewrites every inventoried store to a per-account tombstone, and verifies the zero-hits completeness check.');
    }

    protected function serve(): int
    {
        // The plugin's PSR-4 autoloader is not registered in the bin/plugin
        // context — load the service classes directly.
        require_once __DIR__ . '/../src/PurgeService.php';
        require_once __DIR__ . '/../src/AccountAuditLog.php';

        // The per-run cap trips an ops alert (PurgeService::guardCap), and the
        // email plugin registers its 'Email' service on onPluginsInitialized —
        // which bin/plugin does not fire by default. Without this the alert
        // dies with 'Identifier "Email" is not defined', gets swallowed by its
        // own try/catch, and the loudest failure path in the purge job becomes
        // a line in error_log. Themes too: the mail templates extend
        // email/base.html.twig from the theme's template paths.
        $this->initializeThemes();

        $grav = Grav::instance();
        $service = new PurgeService($grav);

        $lapsed = $service->findLapsed(time());
        if ($lapsed === []) {
            $this->output->writeln('<info>No lapsed deletion requests — nothing to purge.</info>');
            return 0;
        }

        if ($this->input->getOption('dry-run')) {
            foreach ($lapsed as $username) {
                $this->output->writeln("<comment>[dry-run]</comment> would purge: {$username}");
            }
            return 0;
        }

        // Blast-radius circuit breaker (deletion.max_per_run) — same rule
        // the scheduled job enforces; --ignore-cap is the manual override.
        if (!$this->input->getOption('ignore-cap') && $service->capTripped(count($lapsed))) {
            $this->output->writeln('<error>Lapsed count exceeds deletion.max_per_run — nothing purged.</error>');
            $this->output->writeln('Inspect with --dry-run, then re-run with --ignore-cap to proceed deliberately.');
            return 1;
        }

        $failures = 0;
        foreach ($lapsed as $username) {
            $result = $service->purge($username);
            $this->output->writeln("purged: {$username} -> {$result['tombstone']}");
            if ($result['hits'] === []) {
                $this->output->writeln('  zero-hits check: <info>clean</info>');
            } else {
                $failures++;
                $this->output->writeln('  zero-hits check: <error>identifiers survived</error>');
                foreach ($result['hits'] as $hit) {
                    $this->output->writeln("    {$hit}");
                }
            }
        }

        return $failures === 0 ? 0 : 1;
    }
}
