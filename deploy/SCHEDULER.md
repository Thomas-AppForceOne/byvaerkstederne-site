# Grav scheduler — cron wiring per tier

The account-manager plugin registers the first real Grav scheduler job in
this repo: `account-manager-purge` (daily, 03:00 UTC), which hard-deletes
accounts whose 30-day deletion window has lapsed and anonymizes their
footprint (`account_self_service` spec §7). Grav's scheduler only runs
when `bin/grav scheduler` is invoked — nothing happens without a cron
entry on the tier.

## How the scheduler is triggered — every tier

**All four tiers are driven the same way**: a token-gated HTTP endpoint called
by <https://cron-job.org>. One mechanism, one place to look when jobs stop,
one thing to learn.

The forcing reason was one.com: its plan has no cron and its SSH shell has no
`crontab`, so dev, test and staging could not use the classic entry at all —
every job sat at `Last Run: Never`, including Grav's own cache jobs. prod on
chosting *does* have cPanel cron, but running it differently from the other
three would mean two mechanisms, two failure modes and a difference that only
shows up when something is already wrong.

The endpoint:

```
https://<tier>/scheduler-trigger?token=<token>
```

The `scheduler-trigger` plugin answers `204` for a valid token and Grav's
ordinary themed `404` for anything else — a wrong token, no token, or a tier
where none is provisioned. That makes the endpoint indistinguishable from a
page that does not exist, so it cannot be found by probing.

### Provisioning a tier

```bash
make scheduler-token tier=dev            # generate/rotate; prints only a fingerprint
make scheduler-token tier=dev show=1     # print the full URL (run this yourself)
make scheduler-token tier=dev status=1   # is one provisioned? no secret printed
```

The token is generated **on the tier** and never crosses the wire, so
provisioning does not put the secret into a scrollback, a shell history or a
CI log. `show=1` is the deliberate exception, for the one moment you paste the
URL into the cron service.

It lives in the tier's live-state dir (`user/data/scheduler-trigger/token`),
so it survives every deploy and is never in the repo — same posture as the
per-tier `email.yaml`.

### The cron service

Create one job per tier — dev, test, staging AND prod — at
<https://cron-job.org> (free), calling that tier's URL **every minute**.

**Every minute, not every quarter.** Grav evaluates each job's cron
expression against the current minute and neither tolerates nor catches up
(`Job::isDue`). A caller that fires every 15 minutes only ever triggers jobs
whose minute happens to coincide — and the moment the service is a minute
late, a job scheduled at `0 3 * * *` misses that day entirely. Invoking every
minute is what Grav's own documentation prescribes for a cron entry, and it
makes the job expressions in the code mean what they say. The cost is one
short request a minute per tier.

Enable failure notifications: the service telling you it cannot reach the URL
is the only external signal that a tier's scheduled work has stopped.

Rotating a token invalidates the old URL immediately — update the cron job in
the same sitting, or the tier stops running its jobs silently.

### Why not GitHub Actions

It would be free on this public repo, but a scheduled workflow is disabled
after 60 days of repository inactivity — a watchdog that switches itself off
when the project goes quiet is precisely the wrong shape. The SSH-based
variant was rejected outright: it would put the hosting password, which opens
dev, test *and* staging, into repository secrets. The token can do exactly one
thing — make the site run its own housekeeping a little sooner.

## Appendix: the classic cron entry

Not used by any tier today — kept because chosting (prod) does offer cPanel
cron, so this is the fallback if cron-job.org is ever unavailable. Adopting it
would mean two mechanisms in play; prefer fixing the trigger.

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
