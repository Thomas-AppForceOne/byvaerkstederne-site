<?php
/**
 * `bin/plugin site-version read` — Grav CLI helper for the Sprint-3
 * shell probe.
 *
 * Boots Grav via Grav\Console\ConsoleCommand, instantiates the same
 * VersionReader the plugin's site_version() Twig function delegates
 * to, and prints the resulting struct as JSON. Used by
 * tests/version/run.sh as the canonical "bin/grav-driven" entry point
 * for site-version coverage (see the contract criterion
 * shell_probe_site_happy_path: "via a small Grav CLI command, a Twig
 * render via bin/grav, or by booting Grav and calling the plugin's
 * site_version() function").
 *
 * No production code path uses this command; it exists purely as a
 * test entry point. Keeping it inside the plugin means the test rig
 * doesn't have to bootstrap Grav by hand from raw PHP, which proved
 * fragile (UniformResourceLocator wants a fully-resolved theme://
 * locator that only the full Grav request lifecycle sets up).
 *
 * Output contract (single line of JSON to stdout):
 *
 *   {"version": "0.1.0", "build": "247"}
 *
 * Either key may be the JSON literal null when the corresponding file
 * is missing/empty/invalid. The exit code is 0 on success regardless
 * of whether either field is null — the probe asserts on the JSON
 * payload, not the exit code (the helper "succeeded" by reporting the
 * accurate state).
 *
 * Path resolution: identical to the runtime plugin — GRAV_ROOT first,
 * then dirname(__DIR__, 3) (the plugin's own /user/plugins/site-version
 * grandparent), then realpath(__DIR__) for the linuxserver/grav
 * symlink layout. No user input feeds the path.
 */

declare(strict_types=1);

namespace Grav\Plugin\Console;

use Grav\Console\ConsoleCommand;
use Grav\Plugin\SiteVersion\VersionReader;
use Symfony\Component\Console\Input\InputOption;

class ReadCommand extends ConsoleCommand
{
    protected function configure(): void
    {
        $this
            ->setName('read')
            ->setDescription('Print the current site_version() struct as JSON.')
            ->addOption(
                'pretty',
                null,
                InputOption::VALUE_NONE,
                'Pretty-print the JSON output (multi-line).'
            )
            ->setHelp(
                'Reads config/www/VERSION and config/www/BUILD via the same '
                . 'VersionReader the plugin\'s site_version() Twig function '
                . 'uses, and prints the resulting struct as JSON. Used by '
                . 'tests/version/run.sh; not part of any production code path.'
            );
    }

    protected function serve(): int
    {
        $root = $this->resolveVersionRoot();
        $reader = new VersionReader(
            $root . '/VERSION',
            $root . '/BUILD',
            null,           // no logger — the CLI doesn't need warnings on stdout
            'site-version-cli'
        );
        $struct = $reader->read();

        $flags = $this->input->getOption('pretty')
            ? (JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES)
            : JSON_UNESCAPED_SLASHES;
        $payload = json_encode($struct, $flags);
        if ($payload === false) {
            // Defensive: VersionReader returns a strict {?string, ?string}
            // struct that is always JSON-serialisable. Reaching this
            // branch would mean a future shape regression — fail loud.
            $this->output->writeln('<error>json_encode failed</error>');
            return 1;
        }
        $this->output->writeln($payload);
        return 0;
    }

    /**
     * Mirror SiteVersionPlugin::resolveVersionRoot() — same candidate
     * order, same is_readable() probe, same fall-back. Inlined here so
     * the CLI doesn't pull in the full plugin class (which subscribes
     * to Grav events and would re-register itself).
     */
    private function resolveVersionRoot(): string
    {
        $candidates = [];
        if (defined('GRAV_ROOT') && is_string(GRAV_ROOT) && GRAV_ROOT !== '') {
            $candidates[] = rtrim(GRAV_ROOT, '/');
        }
        // <grav-root>/user/plugins/site-version/cli/ReadCommand.php
        // → dirname(__DIR__, 4) is the grav root (/cli/ is one extra
        // level deeper than the plugin's main file, which uses
        // dirname(__DIR__, 3)).
        $candidates[] = dirname(__DIR__, 4);
        // Linuxserver/grav layout: user/ is a symlink to /config/www/user/.
        // Resolving __DIR__'s realpath dereferences that symlink and the
        // grandparent-of-grandparent lands on /config/www/, where
        // VERSION/BUILD actually live in this checkout's bind mount.
        $real = realpath(__DIR__);
        if (is_string($real) && $real !== '') {
            $candidates[] = dirname($real, 4);
        }
        $candidates = array_values(array_unique(array_filter($candidates)));

        foreach ($candidates as $c) {
            if (is_readable($c . '/VERSION')) {
                return $c;
            }
        }
        foreach ($candidates as $c) {
            if (is_readable($c . '/BUILD')) {
                return $c;
            }
        }
        return $candidates[0] ?? dirname(__DIR__, 3);
    }
}
