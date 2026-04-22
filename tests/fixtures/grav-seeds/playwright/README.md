# Seed: `playwright`

Provisions the two test accounts that the Playwright suite under `tests/` needs to exercise authenticated flows.

## Provisions

| Username         | Role(s)    | Access          | Password source                        |
|------------------|------------|-----------------|----------------------------------------|
| `pw-test-user`   | Member     | `site` login    | `$TEST_PASSWORD`                       |
| `pw-test-admin`  | Admin      | `site` + admin  | `$TEST_ADMIN_PASSWORD`                 |

Both accounts get emails at `@example.invalid` (RFC 2606) so they can never collide with real addresses.

## Prerequisites

- A running Grav container. By default the script targets `grav` (the primary dev container); pass a container name as `$1` to target a GAN run's container instead.
- `~/.gan-secrets/workshop-site.env` exists with both `TEST_PASSWORD` and `TEST_ADMIN_PASSWORD` set. If the file is missing, the script fails loudly — silent skips hide bugs.

## Apply

```sh
tests/fixtures/grav-seeds/playwright/apply.sh              # targets 'grav'
tests/fixtures/grav-seeds/playwright/apply.sh gan-xyz      # targets a GAN container
```

The script is idempotent — running it against a container that already has either account is a no-op for that account.

## What happens at test teardown

Playwright's `tests/global-teardown.js` removes both accounts after the suite finishes. If a run is interrupted and the accounts linger, `apply.sh` will notice they exist and skip; no action required. If you want a clean slate, delete `config/www/user/accounts/pw-test-*.yaml` on the host and rerun `apply.sh`.
