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
