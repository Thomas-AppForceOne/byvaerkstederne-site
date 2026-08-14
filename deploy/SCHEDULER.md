# Grav scheduler — cron wiring per tier

The account-manager plugin registers the first real Grav scheduler job in
this repo: `account-manager-purge` (daily, 03:00 UTC), which hard-deletes
accounts whose 30-day deletion window has lapsed and anonymizes their
footprint (`account_self_service` spec §7). Grav's scheduler only runs
when `bin/grav scheduler` is invoked — nothing happens without a cron
entry on the tier.

## Cron entry

One line per tier, in the hosting panel's cron configuration (one.com for
dev/test/staging, chosting cPanel for prod — 15-minute granularity is
ample for a daily job):

```cron
*/15 * * * * cd <grav-root> && bin/grav scheduler --env <tier-host> 1>/dev/null 2>&1
```

`<grav-root>` is the tier's Grav document root (the directory containing
`bin/grav`). The scheduler is idempotent about granularity: each
registered job carries its own cron expression and only fires when due.

### `--env` is not optional — it decides whether mail is delivered

Grav resolves its environment config from the request HOSTNAME. A cron run
has none, so **without `--env` the tier's own
`user/env/<host>/config/plugins/email.yaml` is never merged**: the mailer
ends up with no transport, and the email plugin returns *successfully*
having sent nothing. Every alert a scheduled job raises — the purge
circuit-breaker (`PurgeService::guardCap`) and the privilege-escalation
watch (`SuperWatch::runScheduled`) — is then composed, reported as sent, and
delivered nowhere. This was observed on dev before the guard existed; it is
the quietest possible failure, because the only symptom is silence.

`<tier-host>` is the canonical host, matching `deploy.sh`'s `ENV_HOST`:

| tier | `--env` value |
|---|---|
| dev | `dev.hackersbychoice.dk` |
| test | `test.hackersbychoice.dk` |
| staging | `staging.hackersbychoice.dk` |
| prod | `www.byvaerkstederne.dk` |

The same applies to any manual `bin/plugin` run below that can send mail.

## Manual / operational runs

The purge job wraps `PurgeService`; the same service is exposed as a
plugin CLI for tests, dry runs, and manual execution:

```bash
# List lapsed accounts without deleting anything
bin/plugin account-manager purge-deleted --dry-run

# Execute (exits non-zero if the §7 zero-hits completeness check fails)
bin/plugin account-manager purge-deleted
```

Local/worktree form:

```bash
docker exec -u abc -w /app/www/public <container> bin/plugin account-manager purge-deleted --dry-run
```

## Verifying the scheduler sees the job

`bin/grav scheduler -j` should list `account-manager-purge` — but note the
scheduler command is entirely silent on the current Grav build (even
`-i`/`-j` print nothing while exiting 0). The reliable check is
functional: stamp a backdated `deletion_requested_at` on a throwaway
account and run

```bash
bin/grav scheduler -f   # force all due jobs — the account must be gone after
```

(the Playwright suite automates the same proof through the plugin CLI).

## Conventions

- The purge job runs **unflagged** (independent of `account_self_service`):
  a member who consented to deletion must be deleted on schedule even if
  the self-service surface was later turned off. With no deletion markers
  present the job is an exact no-op.
- Existing time-window sweeps (`deploy/cleanup-unverified-users.sh`,
  `deploy/throttle.sh`) remain externally-run deploy scripts; new
  *in-application* periodic work should follow the account-manager
  precedent (scheduler job + CLI wrapper around one idempotent service).
