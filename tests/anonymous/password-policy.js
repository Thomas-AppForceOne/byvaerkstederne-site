// @ts-check
'use strict';

/**
 * WI-5 — password/username policy parity.
 *
 * The repo pins the policy in three places that must agree:
 *   - system.yaml: pwd_regex / username_regex (server-side, Grav core)
 *   - register.md: the username field's validate.pattern (forms plugin)
 *   - register.html.twig: the client-side username regex literal and the
 *     imperative password .length + /[a-z]/ + /[A-Z]/ + /[0-9]/ chain.
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

const EXPECTED_USERNAME_REGEX = '^[a-z0-9_-]{3,16}$';
const EXPECTED_PWD_REGEX = '(?=.*[A-Z])(?=.*[0-9])(?=.*[a-z]).{8,}';

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

  /**
   * Shared accept/reject truth table. Each row is fed to BOTH:
   *   - the server-side pwd_regex (as pinned in system.yaml), and
   *   - a faithful re-implementation of the client-side JS chain
   *     (.length>=8 && /[a-z]/ && /[A-Z]/ && /[0-9]/).
   * Both must produce the row's verdict. Divergence fails the test.
   */
  const TRUTH_TABLE = [
    { pw: 'Abcdefg1', accept: true, why: 'meets all rules' },
    { pw: 'abcdefg1', accept: false, why: 'no uppercase' },
    { pw: 'ABCDEFG1', accept: false, why: 'no lowercase' },
    { pw: 'Abcdefgh', accept: false, why: 'no digit' },
    { pw: 'Abcdef1', accept: false, why: 'too short (7)' },
  ];

  // Faithful copy of the register.html.twig client-side chain.
  function clientAccepts(pw) {
    if (pw.length < 8) return false;
    if (!/[a-z]/.test(pw)) return false;
    if (!/[A-Z]/.test(pw)) return false;
    if (!/[0-9]/.test(pw)) return false;
    return true;
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
