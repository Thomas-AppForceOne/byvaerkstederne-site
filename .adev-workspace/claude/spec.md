# Bug Fix Specification: `CALL TO UNDEFINED METHOD GRAV\COMMON\SESSION::GET()`

## Product Overview

**Product:** Byværkstederne — a Grav CMS-based community platform featuring a public roadmap with a user voting system.

**Affected component:** `user/plugins/roadmap/roadmap.php` — the `handleVote()` method.

**Who is affected:** Any authenticated user who tries to add or remove a vote on a roadmap item (bug or feature request).

**Core value proposition:** Members can vote on bugs and feature requests (up to 3 votes per category) to influence the development priority of the platform. The voting system includes CSRF replay protection via session-stored, one-time-use nonce blacklisting.

---

## Root Cause

The `handleVote()` method stores a blacklist of used nonces in the Grav session to prevent CSRF replay attacks. It does so using `$session->get(...)` and `$session->set(...)` calls.

`Grav\Common\Session` extends `Grav\Framework\Session\Session`, which in turn extends `RocketTheme\Toolbox\Session\Session`. **None of these classes define `get()` or `set()` methods.** Session properties are accessed exclusively via PHP magic methods `__get()` and `__set()`, i.e. direct property access on the session object.

Because `get()` does not exist, PHP throws a fatal error the moment any authenticated user submits a vote request:

```
Call to undefined method Grav\Common\Session::get()
```

This crash occurs **before** the vote is recorded, so no data is corrupted — but voting is completely non-functional for all users.

---

## Tech Stack

This is an existing Grav CMS project. No stack changes are required.

- **CMS:** Grav (PHP), custom plugin `user/plugins/roadmap/roadmap.php`
- **Session layer:** `Grav\Common\Session` → `Grav\Framework\Session\Session` → `RocketTheme\Toolbox\Session\Session`
- **Data storage:** YAML flat-file (`user/data/flex-objects/roadmap-items.yaml`)
- **Frontend:** Twig templates, custom `byvaerkstederne` theme

---

## Design Language

No UI or design changes are required. This is a pure back-end bug fix.

---

## Feature List

### Feature 1 — Fix Session Access in `handleVote()`

**User story:** As an authenticated member, I want to cast or retract a vote on a roadmap item so that I can influence development priorities.

**High-level description:**

Replace the two incorrect method-call-style session accesses in `handleVote()` with direct property access, which is the correct API for `Grav\Common\Session`.

| Location | Current (broken) code | Replacement (correct) code |
|---|---|---|
| Reading the nonce blacklist (~line 271) | `$session->get('bv_used_vote_nonces') ?? []` | `$session->bv_used_vote_nonces ?? []` |
| Writing the nonce blacklist (~line 282) | `$session->set('bv_used_vote_nonces', $usedNonces)` | `$session->bv_used_vote_nonces = $usedNonces` |

No other logic changes are needed. The surrounding null-guard on `$session` (`$session ? ... : []`) and the 100-entry cap on the blacklist array remain correct and must be preserved.

**Sprint:** Sprint 1

---

## Sprint Plan

### Sprint 1 — Critical Bug Fix (this work)

**Theme:** Restore voting functionality.

**Scope:**
- Apply the two-line session property-access fix in `handleVote()` in `user/plugins/roadmap/roadmap.php`.
- Verify that an authenticated user can successfully add a vote (HTTP 200, `vote_count` incremented in YAML).
- Verify that the same user can successfully remove a vote (HTTP 200, `vote_count` decremented in YAML).
- Verify that the nonce replay protection still works correctly after the fix (a reused nonce must still be rejected — the blacklist must persist in the session across requests within the same session lifetime).
- Verify that all previously passing security tests (Groups A–F in `security/04-voting-endpoint-tests.md`) continue to pass.

**Independently testable:** Yes — the fix is isolated to a single method in a single file. No other plugin, template, or data file is modified.

**Effort:** Minimal (two-line code change, regression test run).
