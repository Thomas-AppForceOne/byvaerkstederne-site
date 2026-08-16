// @ts-check
'use strict';

/**
 * WI-5 — password/username policy parity.
 *
 * The repo pins the policy in four places that must agree:
 *   - system.yaml: pwd_regex / username_regex (server-side, Grav core)
 *   - register.md: the username field's validate.pattern (forms plugin)
 *   - register.html.twig: the client-side username regex literal and the
 *     imperative password .length check.
 *   - partials/register_overlay.html.twig: the SAME registration form rendered
 *     as a site-wide modal (included from base.html.twig), with its own copy of
 *     the client-side chain. It was missing from this file's coverage, and it
 *     drifted: it kept Grav's retired default (>=8 plus upper/lower/digit) while
 *     the form's help text already advertised the 12-char length-only rule, so a
 *     valid passphrase was rejected in the browser and never reached the server.
 *
 * The policy is LENGTH ONLY (>=12, no character classes) — see the rationale
 * in system.yaml. The guessable-word rule lives in a blocklist that a regex
 * cannot carry; its parity is structural rather than asserted, because the
 * client check is RENDERED from the same config the server reads. The last
 * test here pins that structure.
 *
 * These are pure-source + pure-logic checks (no Grav container, no creds), so
 * they run always. They fail if any artifact drifts — e.g. a pwd_regex that
 * drops the lowercase rule, or a username regex that diverges across files.
 */

const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const SYSTEM_YAML = path.join(REPO_ROOT, 'config/www/user/config/system.yaml');
const REGISTER_MD = path.join(REPO_ROOT, 'config/www/user/pages/09.opret-medlemskab/register.md');
const REGISTER_TWIG = path.join(
  REPO_ROOT,
  'config/www/user/themes/byvaerkstederne/templates/register.html.twig',
);
const REGISTER_OVERLAY_TWIG = path.join(
  REPO_ROOT,
  'config/www/user/themes/byvaerkstederne/templates/partials/register_overlay.html.twig',
);

/** Every template carrying a client-side copy of the registration policy. */
const CLIENT_SURFACES = {
  'register.html.twig': REGISTER_TWIG,
  'register_overlay.html.twig': REGISTER_OVERLAY_TWIG,
};

const EXPECTED_USERNAME_REGEX = '^[a-z0-9_-]{3,16}$';
const EXPECTED_PWD_REGEX = '.{12,}';

function read(file) {
  return fs.readFileSync(file, 'utf8');
}

/** Pull a single-quoted or double-quoted YAML scalar value for `key:`. */
function yamlScalar(content, key) {
  const re = new RegExp(`^${key}:\\s*['"]?([^'"\\n]+)['"]?\\s*$`, 'm');
  const m = content.match(re);
  return m ? m[1].trim() : null;
}

test.describe('Password & username policy parity (WI-5)', () => {
  test('system.yaml pins username_regex and pwd_regex to the expected values', () => {
    const sys = read(SYSTEM_YAML);
    expect(yamlScalar(sys, 'username_regex')).toBe(EXPECTED_USERNAME_REGEX);
    expect(yamlScalar(sys, 'pwd_regex')).toBe(EXPECTED_PWD_REGEX);
  });

  test('username_regex is string-equal across system.yaml / register.md / register.html.twig', () => {
    const sys = read(SYSTEM_YAML);
    const md = read(REGISTER_MD);
    const twig = read(REGISTER_TWIG);

    const sysVal = yamlScalar(sys, 'username_regex');
    // register.md: the username field's validate.pattern.
    const mdMatch = md.match(/pattern:\s*["']\^\[a-z0-9_-\]\{3,16\}\$["']/);
    // register.html.twig: the JS regex literal /^[a-z0-9_-]{3,16}$/.
    const twigMatch = twig.match(/\/\^\[a-z0-9_-\]\{3,16\}\$\//);

    expect(sysVal, 'system.yaml username_regex').toBe(EXPECTED_USERNAME_REGEX);
    expect(mdMatch, 'register.md username validate.pattern must equal the regex').not.toBeNull();
    expect(twigMatch, 'register.html.twig must contain the same username regex literal').not.toBeNull();
  });

  test('register.md pins the password pattern to the same value as pwd_regex', () => {
    const sys = read(SYSTEM_YAML);
    const md = read(REGISTER_MD);
    // The forms plugin enforces this one server-side, so a drift here would
    // let the page accept what Grav's own policy rejects (or the reverse).
    const mdPattern = md.match(/pattern:\s*"(\.\{12,\})"/);
    expect(yamlScalar(sys, 'pwd_regex')).toBe(EXPECTED_PWD_REGEX);
    expect(mdPattern, 'register.md password1 validate.pattern must equal pwd_regex').not.toBeNull();
  });

  test('every user-facing text states the length the regex actually enforces', () => {
    // The rule lives in five places a member can read. When the policy moved
    // from 8 to 12 the /konto hint and the change-password rejection were
    // left behind, telling members to satisfy a rule that no longer existed.
    // A wrong rejection message sends someone round in circles, so the text
    // is pinned to the regex here.
    const surfaces = {
      'register.md (help + placeholder)': path.join(
        REPO_ROOT,
        'config/www/user/pages/09.opret-medlemskab/register.md',
      ),
      'account.html.twig (change-password hint)': path.join(
        REPO_ROOT,
        'config/www/user/themes/byvaerkstederne/templates/account.html.twig',
      ),
      'AccountValidator.php (rejection)': path.join(
        REPO_ROOT,
        'config/www/user/plugins/account-manager/src/AccountValidator.php',
      ),
      'en.yaml (PLUGIN_LOGIN messages)': path.join(
        REPO_ROOT,
        'config/www/user/languages/en.yaml',
      ),
    };

    for (const [label, file] of Object.entries(surfaces)) {
      const text = read(file);
      expect(text, `${label} must state the 12-character minimum`).toMatch(/[Mm]indst 12 tegn/);
      // The old rule, in the shapes it was written in. "3-16 tegn" (username)
      // is untouched by this.
      expect(text, `${label} still states the retired 8-character rule`).not.toMatch(
        /mindst 8 tegn|8 tegn med/i,
      );
    }
  });

  test('the client blocklist is rendered from config, not duplicated as a literal', () => {
    // Structural parity: one source of truth. A hand-copied array here would
    // silently drift from what the server enforces — the exact failure this
    // whole file exists to prevent for the length rule.
    for (const [label, file] of Object.entries(CLIENT_SURFACES)) {
      const twig = read(file);
      expect(
        twig.includes("config.plugins['account-manager'].password.blocklist"),
        `${label} must render the blocklist from plugin config`,
      ).toBe(true);
      expect(
        /var BLOCKED = \[/.test(twig),
        `${label} must not hardcode the blocklist as an array literal`,
      ).toBe(false);
    }
  });

  test('no client surface enforces character classes the server does not', () => {
    // The regression this pins: the overlay kept Grav's retired default
    // (>=8 plus upper/lower/digit) after the policy moved to length-only.
    // The server accepted "en helt almindelig sætning"; the browser refused
    // to submit it, quoting a rule the form's own help text denied.
    for (const [label, file] of Object.entries(CLIENT_SURFACES)) {
      const twig = read(file);

      expect(
        /val(?:ue)?\.length\s*<\s*12|\.length\s*<\s*12/.test(twig),
        `${label} must enforce the 12-character minimum client-side`,
      ).toBe(true);

      // The retired character-class chain, in the shapes it was written in.
      expect(twig, `${label} must not require an uppercase letter`).not.toMatch(
        /\/\[A-Z\]\/\.test/,
      );
      expect(twig, `${label} must not require a digit`).not.toMatch(/\/\[0-9\]\/\.test/);
      expect(twig, `${label} must not require a lowercase letter`).not.toMatch(
        /\/\[a-z\]\/\.test/,
      );
      expect(twig, `${label} must not carry the retired 8-character minimum`).not.toMatch(
        /\.length\s*<\s*8\b/,
      );
    }
  });

  test('the username regex literal is identical across both client surfaces', () => {
    // The overlay renders the same form; a divergent username rule here would
    // reject in the modal what the page accepts.
    for (const [label, file] of Object.entries(CLIENT_SURFACES)) {
      const twig = read(file);
      expect(
        /\/\^\[a-z0-9_-\]\{3,16\}\$\//.test(twig),
        `${label} must contain the canonical username regex literal`,
      ).toBe(true);
    }
  });

  /**
   * Shared accept/reject truth table. Each row is fed to BOTH:
   *   - the server-side pwd_regex (as pinned in system.yaml), and
   *   - a faithful re-implementation of the client-side JS chain
   *     (.length>=12 — length only, no character classes), which both
   *     register.html.twig and register_overlay.html.twig must implement.
   * Both must produce the row's verdict. Divergence fails the test.
   */
  const TRUTH_TABLE = [
    { pw: 'en helt almindelig sætning', accept: true, why: 'a passphrase, no classes needed' },
    { pw: 'abcdefghijkl', accept: true, why: 'exactly 12, all lowercase — accepted by design' },
    { pw: 'Abcdefg1', accept: false, why: 'too short (8) even with every class' },
    { pw: 'abcdefghijk', accept: false, why: 'too short (11)' },
    { pw: '', accept: false, why: 'empty' },
  ];

  // Faithful copy of the register.html.twig client-side check.
  function clientAccepts(pw) {
    return pw.length >= 12;
  }

  for (const row of TRUTH_TABLE) {
    test(`pwd policy: "${row.pw}" -> ${row.accept ? 'accept' : 'reject'} (${row.why})`, () => {
      const sys = read(SYSTEM_YAML);
      const pwdRegexStr = yamlScalar(sys, 'pwd_regex');
      expect(pwdRegexStr, 'pwd_regex must be present in system.yaml').toBe(EXPECTED_PWD_REGEX);
      const serverRe = new RegExp(/** @type {string} */ (pwdRegexStr));

      const serverVerdict = serverRe.test(row.pw);
      const clientVerdict = clientAccepts(row.pw);

      // Both engines must agree with the fixture's verdict.
      expect(serverVerdict, `server pwd_regex verdict for "${row.pw}"`).toBe(row.accept);
      expect(clientVerdict, `client JS-chain verdict for "${row.pw}"`).toBe(row.accept);
      // And with each other (the equivalence the WI pins).
      expect(serverVerdict, `server/client divergence for "${row.pw}"`).toBe(clientVerdict);
    });
  }
});
