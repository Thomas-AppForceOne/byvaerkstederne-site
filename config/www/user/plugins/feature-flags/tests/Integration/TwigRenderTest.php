<?php
/**
 * Integration test: renders real Twig templates through a live Twig\Environment
 * with the feature_enabled and enabled_features functions registered. This is
 * NOT a Grav boot — we construct \Twig\Environment directly and register the
 * two TwigFunction instances exactly as the plugin does in onTwigInitialized.
 * That gives the same binding path without needing a container.
 *
 * All template source strings live under this tests/ tree (via ArrayLoader).
 * No file is written inside config/www/user/themes/byvaerkstederne/templates/.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags\Tests\Integration;

use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\TwigHelpers;
use Grav\Plugin\FeatureFlags\Tests\Support\ArrayLogger;
use PHPUnit\Framework\TestCase;
use Twig\Environment;
use Twig\Loader\ArrayLoader;
use Twig\TwigFunction;

final class TwigRenderTest extends TestCase
{
    /**
     * Build a Twig environment wired exactly like the plugin wires Grav's Twig.
     *
     * @param array<string,string> $templates
     * @param array<string,mixed>  $enabled
     */
    private function twigWith(array $templates, array $enabled, ?ArrayLogger &$logger = null): Environment
    {
        $logger = $logger ?? new ArrayLogger();
        $store = new FlagStore($enabled, $logger);
        $helpers = new TwigHelpers($store, $logger);

        $twig = new Environment(new ArrayLoader($templates), [
            'autoescape' => 'html',
            'strict_variables' => true,
        ]);

        $twig->addFunction(new TwigFunction(
            'feature_enabled',
            static fn (mixed $name): bool => $helpers->featureEnabled($name)
        ));
        $twig->addFunction(new TwigFunction(
            'enabled_features',
            static fn (): array => $helpers->enabledFeatures()
        ));

        return $twig;
    }

    public function testPromoBannerEnabledRendersThreeSpecSnippets(): void
    {
        $template = <<<'TWIG'
            {% if feature_enabled('promo_banner') %}BANNER{% endif %}|{{ feature_enabled('not_a_real_flag') ? 'T' : 'F' }}|{% for f in enabled_features() %}[{{ f }}]{% endfor %}
        TWIG;

        $logger = null;
        $twig = $this->twigWith(
            ['tpl' => $template],
            ['promo_banner' => 'true'],
            $logger
        );

        $out = $twig->render('tpl');
        $this->assertStringContainsString('BANNER', $out);
        $this->assertStringContainsString('|F|', $out);
        $this->assertStringContainsString('[promo_banner]', $out);

        // Ensure no other flag name leaked into the iteration output.
        foreach (['checkout_v2', 'pricing_experiment', 'partner_portal'] as $other) {
            $this->assertStringNotContainsString('[' . $other . ']', $out);
        }
    }

    public function testEmptyConfigProducesNoBannerAndEmptyIteration(): void
    {
        $template = <<<'TWIG'
            {% if feature_enabled('promo_banner') %}BANNER{% endif %}|{{ feature_enabled('not_a_real_flag') ? 'T' : 'F' }}|{% for f in enabled_features() %}[{{ f }}]{% else %}NONE{% endfor %}
        TWIG;

        $twig = $this->twigWith(['tpl' => $template], []);
        $out = $twig->render('tpl');

        $this->assertStringNotContainsString('BANNER', $out);
        $this->assertStringContainsString('|F|', $out);
        $this->assertStringContainsString('NONE', $out);
    }

    public function testUnknownFlagInTemplateDoesNotThrowAndLogsWarning(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore([], $logger);
        $helpers = new TwigHelpers($store, $logger);
        $twig = new Environment(new ArrayLoader([
            'tpl' => "{{ feature_enabled('not_a_real_flag') ? 'T' : 'F' }}",
        ]));
        $twig->addFunction(new TwigFunction(
            'feature_enabled',
            static fn (mixed $n): bool => $helpers->featureEnabled($n)
        ));

        $this->assertSame('F', $twig->render('tpl'));
        $this->assertCount(1, $logger->warnings());
    }

    public function testEnabledFlagBodyRendersIffTrue(): void
    {
        $tplSrc = "{% if feature_enabled('promo_banner') %}body{% endif %}";

        $enabledTwig = $this->twigWith(['tpl' => $tplSrc], ['promo_banner' => 'true']);
        $this->assertSame('body', $enabledTwig->render('tpl'));

        $disabledTwig = $this->twigWith(['tpl' => $tplSrc], ['promo_banner' => 'false']);
        $this->assertSame('', $disabledTwig->render('tpl'));

        $absentTwig = $this->twigWith(['tpl' => $tplSrc], []);
        $this->assertSame('', $absentTwig->render('tpl'));
    }

    /**
     * Error-page safety: render a minimal error-template clone through the
     * live Twig environment with the helpers invoked. Verifies no secondary
     * exception arises and output is produced. The snippet lives entirely
     * in ArrayLoader — the real theme error template is untouched.
     */
    public function testHelpersSafeOnErrorPageLikeTemplate(): void
    {
        $errorTplSrc = <<<'TWIG'
            <!doctype html><html><body><h1>Not Found</h1>
            {% if feature_enabled('promo_banner') %}<div class="promo"></div>{% endif %}
            <ul>{% for f in enabled_features() %}<li>{{ f }}</li>{% endfor %}</ul>
            </body></html>
        TWIG;

        $twig = $this->twigWith(['error' => $errorTplSrc], []);
        $out = $twig->render('error');
        $this->assertStringContainsString('Not Found', $out);
        $this->assertStringNotContainsString('class="promo"', $out);
        // ul exists, with no li entries.
        $this->assertMatchesRegularExpression('/<ul>\s*<\/ul>/', $out);
    }
}
