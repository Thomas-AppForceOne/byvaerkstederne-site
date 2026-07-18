# Specification — Admin approval of member access requests

Status: In Development
Owner: thomas@appforceone.dk
Scope: Reduce friction for admins approving member requests to become organizers (or other roles). Members request via `/konto` (account_self_service feature); admins currently get an email and must manually edit account YAML. This spec adds one-click approval/rejection links in the notification email, with audit trail and token-based security.

---

## 1. Goal

Today, when a member requests access to a role (e.g., "Arrangør"), the admin receives an email but must:
1. Log into the admin panel
2. Navigate to the account YAML file
3. Manually add the role to `groups:`
4. Find no audit trail of who approved what

Reduce this to **one click** from the email itself while maintaining:
- CSRF protection (token-based)
- Audit trail (who, when, action)
- Ability to reject (not just approve)
- Intentionality (no accidental bulk changes)

---

## 2. In scope

1. **Access request approval token**: when a member requests a role via `/konto/request-access`, generate a random one-time token stored on the account.
2. **Approval endpoint** `/admin/access-request/approve`: POST endpoint that accepts the token, verifies it, adds the member to the group, clears the request, and audits.
3. **Rejection endpoint** `/admin/access-request/reject`: POST endpoint that clears the pending request (member sees it gone, can re-request after cooldown).
4. **Email template change**: the `access_request` email now includes approval and rejection links with embedded tokens.
5. **Audit trail**: `account-audit.jsonl` records `approve_access_request` and `reject_access_request` actions with admin username, timestamp, role, and member username.

## Out of scope

- Admin dashboard / bulk approval UI (Phase 2)
- CLI tools (Phase 2)
- Self-service role revocation (separate feature)
- Email recipients config (assumed hardcoded or provided via existing email config; if missing, non-fatal WARN in logs)
- Token resend (one token per open request; new request invalidates the old token)

---

## 3. Boundaries

- **No `login`/`email` plugin changes** (same rule as account-manager itself).
- **Token security**: stored as hash only (SHA-256), never in plaintext.
- **One open request per member per role**: new request to the same role invalidates the old token.
- **No re-request spam**: member cannot request again until the current request is cleared (approved or rejected). Cooldown is 24 hours after clearing.

---

## 4. Architecture

### 4.1 Data model additions

Account YAML gains a transient field (already exists: `access_request`; we add `token_hash` and `token_expires_at`):

```yaml
access_request:
  role: organizers
  motivation: "Vil gerne arrangere workshops"
  requested_at: "2026-07-17T12:00:00Z"
  token_hash: "<sha256>"                        # ← NEW
  token_expires_at: "2026-07-18T12:00:00Z"      # ← NEW (24h from generation)
```

### 4.2 Endpoints

Both endpoints require admin login (gate at Grav's `AuthorizationGate` level — respond 403 if not admin).

| Endpoint | Method | CSRF | Params | Action |
|---|---|---|---|---|
| `/admin/access-request/approve` | POST | token-in-query (single-use) | `token`, `username`, `role` | add group, clear request, audit |
| `/admin/access-request/reject` | POST | token-in-query (single-use) | `token`, `username` | stamp `access_request_cleared_at`, audit |

- **Token validation**: SHA-256 hash-comparison against stored `access_request.token_hash`.
- **Idempotent on success**: approving twice with the same token is a no-op (member already in group, request already cleared).
- **Token expiry**: reject if `now > token_expires_at`.

### 4.3 Email template change

The `access_request` email (sent on `/konto/request-access`) now includes:

```
─── Godkend eller afvis ───
✅ Godkend:  https://example.dk/admin/access-request/approve?token=<TOKEN>&username=<USERNAME>&role=<ROLE>
❌ Afvis:     https://example.dk/admin/access-request/reject?token=<TOKEN>&username=<USERNAME>

Linket udløber i 24 timer.
```

(Danish UI per CLAUDE.md language rule.)

### 4.4 Audit log additions

`user/data/account-manager/account-audit.jsonl` gains two new action types:

```jsonl
{"timestamp":"2026-07-17T12:30:00Z","actor":"thomas_admin","action":"approve_access_request","username":"bob","role":"organizers"}
{"timestamp":"2026-07-17T12:31:00Z","actor":"thomas_admin","action":"reject_access_request","username":"bob"}
```

---

## 5. Security

- **Token**: random ≥128-bit, stored as SHA-256 hash, expires after 24 hours.
- **Single-use**: token invalidated after first use (whether approve or reject).
- **No enumeration**: if the username or role in the query string is invalid, respond with a generic "Anmodning blev behandlet" message (same pattern as email-change confirmation).
- **Admin-only**: both endpoints check Grav's `admin.super` permission; non-admins get 403.
- **User-Agent binding**: nonce (if added) binds to User-Agent per Grav convention (see CLAUDE.md vote-nonce gotcha).

---

## 6. Error handling

| Scenario | Response |
|---|---|
| Token expired | 404 (no enumeration) |
| Token invalid/not found | 404 (no enumeration) |
| Username not found | 404 (no enumeration) |
| Member already in group (approve) | 200 OK, "Anmodning blev behandlet" (no-op) |
| No pending request | 404 (no enumeration) |
| Approver not admin | 403 Forbidden |
| Member already in group + token valid | Approve: no-op ✅; Reject: clear the token, no-op ✅ |

---

## 7. Rollout & testing

1. **Playwright**: success path (approve + reject), failure paths (expired token, invalid token, non-admin, already granted).
2. **Manual testing on test tier**: request role, click approval link in Mailpit, verify group added and audit log entry.
3. **Email template change**: test that links render correctly and token is included.

---

## 8. Verification checklist

- [ ] Token generated on `/konto/request-access` POST
- [ ] Token stored as hash in account YAML
- [ ] Email includes approval/rejection links
- [ ] `/admin/access-request/approve` POSTs: validates token, adds group, clears request, audits
- [ ] `/admin/access-request/reject` POSTs: validates token, stamps cooldown, audits
- [ ] Tokens expire after 24 hours
- [ ] Non-admins get 403
- [ ] Audit entries in account-audit.jsonl
- [ ] Tests pass (Playwright + unit)
