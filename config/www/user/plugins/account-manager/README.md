# Account Manager

Member self-service on `/konto` (account_self_service spec): change email
(verify-new-address-first), change password, edit display name, view
roles, request access rights, and delete the account — soft delete with a
30-day regret window, then a scheduled GDPR hard delete + anonymization.

Everything server-side is flag-gated by **`account_self_service`** except
two deliberately unflagged pieces (see *Flag semantics* below). No
login/email plugin PHP is modified anywhere — the plugin consumes their
container services and events only.

## Endpoints

All under `/konto/` (the page itself is the Danish slug; endpoint segments
are developer-facing English). Every mutating action runs the contract:

```
flag → POST → authn → CSRF (per-action nonce) → re-auth (where marked)
     → validate → mutate → audit → PRG 303 back to /konto#section
```

| Endpoint | Method | Re-auth | Notes |
|---|---|---|---|
| `change-fullname` | POST | – | sanitized, length-bounded |
| `change-password` | POST | ✓ | new ×2, `system.pwd_regex` |
| `request-email-change` | POST | ✓ | throttled (per-IP + per-account); no-enumeration |
| `confirm-email-change/token:<t>/user:<u>` | GET | token | single-use, 24 h, hash-compared |
| `resend-email-change` | POST | – | re-mints (invalidates prior token) |
| `cancel-email-change` | POST | – | |
| `request-access` | POST | – | one open request; cooldown after clearing |
| `cancel-access-request` | POST | – | stamps `access_request_cleared_at` |
| `request-deletion` | POST | ✓ | + confirmation checkbox; kills session + remember-me |

Flag off ⇒ every endpoint answers a generic `404 Not Found` before any
parsing; the page 404s via its `feature:` frontmatter (PageGate).

## Data model — everything on the account YAML

Transient state lives on `user/accounts/<username>.yaml` so it travels
with the account and dies with it:

```yaml
pending_email:            # while an email change awaits confirmation
  address: new@example.dk
  token_hash: <sha256>    # the token itself is never stored
  expires_at: '…'
deletion_requested_at: '…'      # set → hard delete at +30 days
access_request:                  # at most one open request
  role: organizers
  motivation: '…'
  requested_at: '…'
access_request_cleared_at: '…'   # cancel stamps this; cooldown gate
```

Granted state is **derived**: membership of the group is the truth; a
leftover `access_request` is lazily cleared on the next `/konto` load.
The plugin never writes `groups:` — granting stays a manual super action.

Writes serialize through `AccountStore` (plugin-wide advisory lock +
`$grav['accounts']` save path). Reads for re-auth/token checks free the
shared `CompiledYamlFile` instance first — in authenticated requests it
can hold a session-epoch snapshot, and security checks must see the disk.

## Deletion lifecycle

1. `request-deletion` stamps `deletion_requested_at`, emails the member
   the exact hard-delete date, invalidates every remember-me token, and
   logs the session out.
2. **Signing in again before the deadline reinstates the account** (an
   `onUserLogin` subscriber clears the marker, flashes + emails). That is
   the whole regret mechanism.
3. The daily scheduler job `account-manager-purge` (or
   `bin/plugin account-manager purge-deleted`) hard-deletes lapsed
   accounts and anonymizes their footprint to a per-account random
   tombstone. Authored content stays. See `deploy/SCHEDULER.md` for cron
   wiring; the anonymization inventory is the constant block at the top
   of `src/PurgeService.php` — the single place to extend when a new
   store references accounts.

## Flag semantics

`account_self_service` gates the dropdown, the page, and every endpoint.
Two pieces run unflagged **by design**:

- the reinstatement login hook — otherwise turning the flag off while
  markers exist would strand members in unrecoverable pending-deletion
  while the purge still deletes them;
- the purge job — a member who consented to deletion must be deleted on
  schedule regardless of the surface's availability.

With the flag off on a clean tier both are exact no-ops, preserving the
byte-for-byte-today's-behaviour guarantee.

## Audit

`user/data/account-manager/account-audit.jsonl` (append-only, gitignored
live state): action, actor, timestamp — never addresses, tokens, or
password material. The purge rewrites actor fields to the tombstone and
logs `hard_delete` with the tombstone id only.
