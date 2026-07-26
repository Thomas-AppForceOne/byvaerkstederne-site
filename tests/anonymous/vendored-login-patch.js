// @ts-check
'use strict';

/**
 * Invariant: the local patches that the welcome mail depends on are still
 * present in the VENDORED login plugin.
 *
 * The login plugin is committed to this repo, so it only changes when someone
 * deliberately updates it (`bin/gpm update login`) and commits the result.
 * That update overwrites plugin files wholesale and would silently drop:
 *
 *   1. The try/catch around sendWelcomeEmail() in login.php. Without it, a
 *      mail-transport failure during activation throws
 *      PLUGIN_LOGIN.EMAIL_SENDING_FAILURE out of a frame nobody catches — the
 *      member's account is already enabled and saved, but they see an error
 *      page instead of the activation confirmation.
 *   2. The 'emails/login/{template}.html.twig' key in classes/Email.php, which
 *      is what makes our theme override resolve at all. Rename it and members
 *      quietly get the stock English welcome mail.
 *
 * Neither failure shows up as a crash, and (2) still delivers a mail — so
 * without this guard a plugin update looks clean and ships broken behaviour.
 * If this test goes red after an update: re-apply the patch on the new plugin
 * version, do not delete the test.
 *
 * The behavioural counterpart lives in welcome-email.js; this file is a pure
 * source invariant and needs neither a browser nor the mail sink.
 */

const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const PLUGIN = path.join(REPO_ROOT, 'config/www/user/plugins/login');
const LOGIN_PHP = path.join(PLUGIN, 'login.php');
const EMAIL_PHP = path.join(PLUGIN, 'classes/Email.php');
const OVERRIDE = path.join(
  REPO_ROOT,
  'config/www/user/themes/byvaerkstederne/templates/emails/login/welcome.html.twig',
);

test.describe('Vendored login-plugin patches', () => {
  test('every sendWelcomeEmail() call site is wrapped in try/catch', () => {
    const src = fs.readFileSync(LOGIN_PHP, 'utf8');
    const calls = [...src.matchAll(/\$this->login->sendWelcomeEmail\(/g)];

    // Two call sites in the stock plugin: the activation handler and the
    // registration handler's no-activation branch. A different count means the
    // plugin was restructured — re-read it before touching this expectation.
    expect(calls.length, 'expected exactly 2 sendWelcomeEmail() call sites in login.php').toBe(2);

    for (const call of calls) {
      const at = /** @type {number} */ (call.index);
      const before = src.slice(Math.max(0, at - 600), at);
      const after = src.slice(at, at + 400);
      expect(before, `sendWelcomeEmail() at offset ${at} must sit inside a try block`).toMatch(
        /try\s*\{[^{}]*$/,
      );
      expect(after, `sendWelcomeEmail() at offset ${at} must be followed by a catch`).toMatch(
        /catch\s*\(\\?\w+/,
      );
    }
  });

  test('the email template key our theme override shadows is unchanged', () => {
    const src = fs.readFileSync(EMAIL_PHP, 'utf8');
    expect(
      src,
      "Email::sendEmail must still render 'emails/login/{$template}.html.twig' — " +
        'the theme override resolves on that exact key',
    ).toMatch(/emails\/login\/\{\$template\}\.html\.twig/);
  });

  test('the theme override for the welcome mail exists', () => {
    expect(fs.existsSync(OVERRIDE), `${OVERRIDE} must exist`).toBe(true);
    const tpl = fs.readFileSync(OVERRIDE, 'utf8');
    expect(tpl, 'override must extend the shared email base template').toMatch(
      /extends 'email\/base\.html\.twig'/,
    );
  });
});
