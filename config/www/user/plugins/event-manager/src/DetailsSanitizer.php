<?php
/**
 * DetailsSanitizer — the trust boundary for member-authored event details
 * (event_rsvp_specification.md §5). The rich `details` body is UNTRUSTED
 * input; this wraps HTML Purifier (LGPL, vendored under lib/htmlpurifier/) to
 * reduce it to a fixed allowlist before it is ever stored. The stored
 * `details_html` is therefore always sanitizer output, which is the ONLY
 * reason the templates may render it with |raw.
 *
 * Allowlist (everything else — scripts, styles, event handlers, iframes,
 * forms — is stripped):
 *   headings (h2–h4), p, br, strong/em/u, ul/ol/li, a[href] (http(s)/relative
 *   only, forced rel="noopener noreferrer"), img[src|alt] (src restricted to
 *   the event-image serving path), blockquote, and table basics.
 *
 * Sanitize on WRITE (EventValidator), never on read. A raw-size cap bounds the
 * work before purification.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager;

final class DetailsSanitizer
{
    /** Hard cap on raw input before purification (defense against unbounded payloads). */
    private const MAX_RAW_BYTES = 200 * 1024;

    /** <img src> is constrained to this same-origin serving path (§5.2 / Phase 6). */
    public const IMAGE_PATH_PREFIX = '/begivenheder/billede/';

    private static bool $loaded = false;

    /**
     * Reduce untrusted HTML to the allowlist. Returns '' for empty input.
     * The result is safe to store and later render with |raw.
     */
    public function sanitize(string $raw): string
    {
        if (trim($raw) === '') {
            return '';
        }
        if (strlen($raw) > self::MAX_RAW_BYTES) {
            // Truncate on a byte boundary; HTML Purifier repairs the resulting
            // malformed tail, so a mid-tag cut cannot produce unsafe output.
            $raw = substr($raw, 0, self::MAX_RAW_BYTES);
        }

        self::ensureLoaded();
        $purifier = new \HTMLPurifier($this->buildConfig());
        return trim((string)$purifier->purify($raw));
    }

    private function buildConfig(): \HTMLPurifier_Config
    {
        $config = \HTMLPurifier_Config::createDefault();
        // Every directive must be set BEFORE the first getDefinition() call,
        // which finalizes the config (further set() then throws).
        $config->set('Core.Encoding', 'UTF-8');
        // The allowlist. Anything not named here (script, style, iframe, form,
        // on* handlers, class/id/style attrs) is removed by construction.
        $config->set('HTML.Allowed',
            'h2,h3,h4,p,br,strong,em,u,ul,ol,li,a[href],blockquote,img[src|alt],table,thead,tbody,tr,th,td');
        // Only http(s) and relative hrefs; javascript:/data: schemes are dropped.
        $config->set('URI.AllowedSchemes', ['http' => true, 'https' => true]);
        $config->set('HTML.Nofollow', true);
        $config->set('AutoFormat.RemoveEmpty', true);
        // Every surviving link opens in a new context with rel="noopener
        // noreferrer" (§5.1) — TargetNoopener/TargetNoreferrer are on by
        // default and add the rel once TargetBlank sets target="_blank".
        $config->set('HTML.TargetBlank', true);
        $config->set('HTML.TargetNoopener', true);
        $config->set('HTML.TargetNoreferrer', true);
        // No writable serializer cache at runtime — the config is fixed and
        // save-time purification is infrequent, so rebuilding is cheap and
        // avoids any read-only-filesystem write.
        $config->set('Cache.DefinitionImpl', null);

        // <img src> must point at our own event-image serving path — no remote
        // or absolute images. EmbeddedURI is true only for img/embed src, so
        // <a href> is left to the scheme rules above.
        $uriDef = $config->getDefinition('URI', true);
        $uriDef->addFilter(new class (self::IMAGE_PATH_PREFIX) extends \HTMLPurifier_URIFilter {
            public $name = 'EventImageSrc';
            private string $prefix;
            public function __construct(string $prefix)
            {
                $this->prefix = $prefix;
            }
            public function filter(&$uri, $config, $context)
            {
                if ($context->get('EmbeddedURI', true) !== true) {
                    return true; // <a href> — handled by URI.AllowedSchemes
                }
                if ($uri->scheme !== null || $uri->host !== null) {
                    return false; // reject absolute/remote image sources
                }
                return strpos((string)$uri->path, $this->prefix) === 0;
            }
        }, $config);

        return $config;
    }

    private static function ensureLoaded(): void
    {
        if (self::$loaded) {
            return;
        }
        if (!class_exists('HTMLPurifier')) {
            require_once __DIR__ . '/../lib/htmlpurifier/library/HTMLPurifier.auto.php';
        }
        self::$loaded = true;
    }
}
