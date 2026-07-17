<?php
/**
 * Unit tests for DetailsSanitizer — the trust boundary for member-authored
 * event details (event_rsvp_specification.md §5). Asserts the dangerous
 * constructs are stripped, the allowlist survives, and the sanitizer is
 * idempotent on its own output.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager\Tests\Unit;

use Grav\Plugin\EventManager\DetailsSanitizer;
use PHPUnit\Framework\TestCase;

final class DetailsSanitizerTest extends TestCase
{
    private DetailsSanitizer $sanitizer;

    protected function setUp(): void
    {
        $this->sanitizer = new DetailsSanitizer();
    }

    // ── Dangerous constructs stripped ────────────────────────────────────

    public function testScriptTagIsStripped(): void
    {
        $out = $this->sanitizer->sanitize('<p>Hej</p><script>alert(1)</script>');
        $this->assertStringNotContainsString('<script', $out);
        $this->assertStringNotContainsString('alert(1)', $out);
        $this->assertStringContainsString('Hej', $out);
    }

    public function testOnerrorHandlerIsStripped(): void
    {
        $out = $this->sanitizer->sanitize('<img src="/begivenheder/billede/ev_a/x.png" onerror="alert(1)">');
        $this->assertStringNotContainsString('onerror', $out);
        $this->assertStringNotContainsString('alert(1)', $out);
    }

    public function testIframeIsStripped(): void
    {
        $out = $this->sanitizer->sanitize('<p>ok</p><iframe src="https://evil.example"></iframe>');
        $this->assertStringNotContainsString('<iframe', $out);
        $this->assertStringContainsString('ok', $out);
    }

    public function testJavascriptHrefIsStripped(): void
    {
        $out = $this->sanitizer->sanitize('<a href="javascript:alert(1)">klik</a>');
        $this->assertStringNotContainsString('javascript:', $out);
        // The link text survives even though the unsafe href is dropped.
        $this->assertStringContainsString('klik', $out);
    }

    public function testStyleAndClassAttributesAreStripped(): void
    {
        $out = $this->sanitizer->sanitize('<p class="x" style="color:red" id="y">tekst</p>');
        $this->assertStringNotContainsString('style=', $out);
        $this->assertStringNotContainsString('class=', $out);
        $this->assertStringNotContainsString('id=', $out);
        $this->assertStringContainsString('tekst', $out);
    }

    public function testStyleTagIsStripped(): void
    {
        $out = $this->sanitizer->sanitize('<style>body{display:none}</style><p>hej</p>');
        $this->assertStringNotContainsString('<style', $out);
        $this->assertStringNotContainsString('display:none', $out);
    }

    // ── Image src restriction ────────────────────────────────────────────

    public function testImageOnServingPathSurvives(): void
    {
        $out = $this->sanitizer->sanitize('<img src="/begivenheder/billede/ev_a/abc.png" alt="Foto">');
        $this->assertStringContainsString('/begivenheder/billede/ev_a/abc.png', $out);
        $this->assertStringContainsString('alt="Foto"', $out);
    }

    public function testRemoteImageIsRejected(): void
    {
        $out = $this->sanitizer->sanitize('<img src="https://evil.example/x.png">');
        $this->assertStringNotContainsString('evil.example', $out);
    }

    public function testImageOutsideServingPathIsRejected(): void
    {
        $out = $this->sanitizer->sanitize('<img src="/etc/passwd">');
        $this->assertStringNotContainsString('/etc/passwd', $out);
    }

    // ── Allowlist survives ───────────────────────────────────────────────

    public function testAllowlistedFormattingSurvives(): void
    {
        $in = '<h2>Titel</h2><p>Et <strong>vigtigt</strong> og <em>skråt</em> afsnit.</p>'
            . '<ul><li>Et</li><li>To</li></ul><blockquote>Citat</blockquote>';
        $out = $this->sanitizer->sanitize($in);
        foreach (['<h2>', '<strong>', '<em>', '<ul>', '<li>', '<blockquote>'] as $tag) {
            $this->assertStringContainsString($tag, $out, "expected $tag to survive");
        }
        $this->assertStringContainsString('vigtigt', $out);
        $this->assertStringContainsString('Citat', $out);
    }

    public function testTableBasicsSurvive(): void
    {
        $in = '<table><thead><tr><th>A</th></tr></thead><tbody><tr><td>1</td></tr></tbody></table>';
        $out = $this->sanitizer->sanitize($in);
        foreach (['<table>', '<tr>', '<th>', '<td>'] as $tag) {
            $this->assertStringContainsString($tag, $out, "expected $tag to survive");
        }
    }

    public function testHttpLinkSurvivesWithForcedRel(): void
    {
        $out = $this->sanitizer->sanitize('<a href="https://example.com">link</a>');
        $this->assertStringContainsString('href="https://example.com"', $out);
        $this->assertStringContainsString('noopener', $out);
        $this->assertStringContainsString('noreferrer', $out);
    }

    public function testRelativeLinkSurvives(): void
    {
        $out = $this->sanitizer->sanitize('<a href="/vaerkstedskalenderen">kalender</a>');
        $this->assertStringContainsString('href="/vaerkstedskalenderen"', $out);
    }

    // ── Robustness / invariants ──────────────────────────────────────────

    public function testEmptyInputReturnsEmpty(): void
    {
        $this->assertSame('', $this->sanitizer->sanitize(''));
        $this->assertSame('', $this->sanitizer->sanitize('   '));
    }

    public function testIdempotentOnOwnOutput(): void
    {
        $in = '<h2>Titel</h2><p>Tekst med <a href="https://example.com">link</a> og '
            . '<img src="/begivenheder/billede/ev_a/x.png" alt="x"></p>';
        $once = $this->sanitizer->sanitize($in);
        $twice = $this->sanitizer->sanitize($once);
        $this->assertSame($once, $twice);
    }

    public function testOversizeInputIsBoundedNotFatal(): void
    {
        // 500 KB of <p> spam — must return without exhausting memory/time and
        // still be clean (no <script> could survive even if appended).
        $big = str_repeat('<p>x</p>', 60000) . '<script>alert(1)</script>';
        $out = $this->sanitizer->sanitize($big);
        $this->assertStringNotContainsString('<script', $out);
        $this->assertNotSame('', $out);
    }
}
