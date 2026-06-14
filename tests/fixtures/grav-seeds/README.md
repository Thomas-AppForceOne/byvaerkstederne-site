# Grav seed bundles

Test suites in this repo must not depend on pre-existing Grav state. Any Grav user, page, or flex record a test needs is **seeded by the test itself** before it runs, and cleaned up after. That's the test-independence rule.

Seed bundles are named, checked-in *recipes* that bring a Grav instance into the state a particular test suite requires. One bundle per requirement. If two test suites need different setups, they get two bundles.

## Layout

```
tests/fixtures/grav-seeds/
├── README.md                — this file
├── playwright/              — bundle consumed by tests/ (Playwright)
│   ├── README.md            — what this bundle provides + prerequisites
│   └── apply.sh             — idempotent: apply this seed to a running container
└── <next-bundle>/           — same shape
```

## Contract for a bundle

Every bundle must:

1. **Be idempotent.** Running `apply.sh` twice is a no-op on the second run. Don't fail if the thing already exists — check and skip.
2. **Take a target argument.** `apply.sh <container-name>` runs against the named Docker container (defaults to `grav` for the main dev instance). The GAN harness applies seeds to its run-scoped container on a different port.
3. **Source secrets from `~/.gan-secrets/workshop-site.env`** if passwords are needed. Never commit passwords. If the file is absent, fail loudly — a silent skip is how bugs hide.
4. **Document what it seeds** in its own `README.md`: users, roles, flex data, etc. Someone reading the test suite must be able to reason about pre-conditions without reverse-engineering shell.
5. **Live-state only, not code.** Seeds populate `config/www/user/accounts/`, `config/www/user/data/flex/`, `config/www/user/pages/` — things that are gitignored in the main repo. Seeds must not overwrite templates, plugin code, or committed pages.

## Why recipes instead of snapshots?

Checking in `accounts/*.yaml` with bcrypt hashes pins the seed to one specific password. Anyone rotating `$TEST_PASSWORD` locally would end up with mismatched hashes. A recipe that provisions via the Grav CLI at apply-time sidesteps this: the password is always whatever the current `~/.gan-secrets/workshop-site.env` says.

The tradeoff is that `apply.sh` needs a running Grav container. That's always true in our setup anyway.

## Using a bundle

```sh
# Against the main dev container (default):
tests/fixtures/grav-seeds/playwright/apply.sh

# Against a GAN run's container (example):
tests/fixtures/grav-seeds/playwright/apply.sh gan-my-worktree
```

## Adding a new bundle

1. Pick a name that says what the bundle is *for*, not what it contains — e.g. `playwright`, `roadmap-voting-load`, `bug-report-fixtures`.
2. Create the directory, write `README.md` (prerequisites + what's provisioned), write idempotent `apply.sh`.
3. Reference it from the test suite's setup so the bundle's role is obvious at the call site.

## Mail sink — Mailpit (WI-6, member auth hardening)

The auth tests (`tests/anonymous/registration.js`, `tests/anonymous/password-reset.js`)
verify email-bearing flows **end-to-end** against an API-queryable, non-delivering
sink — **Mailpit** — rather than mocking at the Grav layer. The real `login` +
`email` plugin path runs and sends over SMTP to Mailpit; the test reads the
captured message over Mailpit's REST API, extracts the activation/reset link,
and drives it to prove the token works.

```
Playwright ──drives──▶ Grav (worktree container) ──SMTP mailpit:1025──▶ Mailpit ◀──REST── Playwright
```

### Bring it up / tear it down

```sh
# Grav must already be running for this worktree (scripts/grav-up.sh . <port>).
scripts/mailpit-up.sh .            # default host ports 1025 (SMTP) / 8025 (API)
scripts/mailpit-up.sh . 1126 8126  # pick free host ports if those collide
# ... run the suite with MAILPIT_URL exported (the script prints it) ...
scripts/mailpit-down.sh .          # stop sink, restore committed config
```

`mailpit-up.sh`:
- starts the `mailpit` service (under the `test` compose profile, so it never
  runs under the plain dev `:8080` workflow) in this worktree's compose project,
  on the same network as Grav;
- points the running Grav's `config/plugins/email.yaml` at `mailpit:1025`
  (Grav 1.7's env-config merge does **not** apply per-host overrides to plugin
  configs, so the override targets the user config layer Grav actually reads);
- relaxes `session.secure` to `false` so authenticated tests can hold a session
  over the worktree container's plain HTTP (the committed `system.yaml` keeps
  `secure: true` for the TLS tiers — WI-4).

Both overrides are backed up to `.gan/` and restored by `mailpit-down.sh`; the
committed config files are never modified. `MAILPIT_URL` (default
`http://127.0.0.1:8025`) is what `tests/helpers/mail.js` queries; tests
skip-with-reason when the sink is unreachable.

The registration tests also need the `membership_signup` feature flag ON and
(for `/roadmap` reachability) the `roadmap` flag ON in the target container.
Both are OFF in the default local profile; enable them for the run.

### Coverage boundary

Mailpit proves **transport + token usability** (mail is generated, correctly
addressed/From'd, and the activation/reset code drives the real state change).
It does **not** prove real-world deliverability (SPF/DKIM/DMARC, spam-foldering),
because Mailpit accepts everything. Per-tier deliverability stays the manual
check in the spec's Prerequisites step 4. A green WI-6 run is not "prod mail
lands".
