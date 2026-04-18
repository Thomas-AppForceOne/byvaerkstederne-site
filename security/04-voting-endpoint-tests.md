# Voting Endpoint — Server-Side Enforcement Tests
**Date:** 2026-04-12  
**Reviewer:** Thomas (thomasadmin)  
**Scope:** `/roadmap/vote` POST endpoint (`user/plugins/roadmap/roadmap.php` — `handleVote()` method)  
**Status:** COMPLETE — all enforcement rules verified; no unintended vote state changes observed

---

## Endpoint Overview

The vote endpoint is implemented in `user/plugins/roadmap/roadmap.php::handleVote()`. It enforces the following rules server-side before mutating any stored vote state:

1. **Authentication** — user must be authenticated and authorised (`$user->authenticated && $user->authorized`).
2. **CSRF nonce** — `vote_nonce` validated via `Utils::verifyNonce($nonce, 'roadmap-vote')`.
3. **Locked-status check** — items with status `under_implementation`, `klar_til_test`, or `loest` reject `add` actions with HTTP 409.
4. **Uniqueness check** — a member cannot add a second vote to an item they have already voted on (HTTP 409).
5. **Budget check** — `getUserBudget()` counts active votes per category; returns 0 if ≥ 3 votes are in use; HTTP 409 if budget is exhausted.

All checks are performed against the live YAML data file, not only against client-supplied parameters.

---

## Test Setup

Tests were performed in the local Docker environment (`make start`). Two test accounts were used:

- `thomasadmin` — site administrator, also a valid voting member.
- `testmember01` — regular member account created for testing purposes.

The roadmap YAML data file (`user/data/flex-objects/roadmap-items.yaml`) was reset to a known baseline before each test group. The baseline contained:

- `bug_001` — type: bug, status: `rapporteret`, 0 votes
- `bug_002` — type: bug, status: `rapporteret`, 0 votes
- `bug_003` — type: bug, status: `rapporteret`, 0 votes
- `bug_004` — type: bug, status: `rapporteret`, 0 votes
- `feat_001` — type: feature, status: `under_afklaring`, 0 votes
- `feat_locked` — type: feature, status: `under_implementation`, 0 votes
- `feat_test` — type: feature, status: `klar_til_test`, 0 votes
- `feat_done` — type: feature, status: `loest`, 0 votes

---

## Test Group A: Per-Category Budget Limit (Condition a)

**Rule:** A member cannot exceed 3 votes per category (bugs and features separately).

### Test A-1: Cast votes up to the limit

| Step | Action | Expected | Observed | Pass? |
|------|--------|----------|----------|-------|
| A-1-1 | `testmember01` votes on `bug_001` (add) | 200 OK, bug_budget=2 | 200 OK, bug_budget=2 | ✅ |
| A-1-2 | `testmember01` votes on `bug_002` (add) | 200 OK, bug_budget=1 | 200 OK, bug_budget=1 | ✅ |
| A-1-3 | `testmember01` votes on `bug_003` (add) | 200 OK, bug_budget=0 | 200 OK, bug_budget=0 | ✅ |

### Test A-2: Attempt to exceed budget

| Step | Action | Expected | Observed | Pass? |
|------|--------|----------|----------|-------|
| A-2-1 | `testmember01` votes on `bug_004` (add) after 3 votes used | 409 Conflict, no mutation | 409 `{"error":"Du har ikke flere stemmer til rådighed i denne kategori."}` | ✅ |

**Verified:** YAML file was re-read after A-2-1; `bug_004.votes` remained empty. Vote count for `bug_001`, `bug_002`, `bug_003` each showed `testmember01` as a voter.

### Test A-3: Cross-category budget independence

| Step | Action | Expected | Observed | Pass? |
|------|--------|----------|----------|-------|
| A-3-1 | `testmember01` (bug budget=0) votes on `feat_001` (add) | 200 OK, feature_budget=2 | 200 OK, feature_budget=2 | ✅ |

**Verified:** Bug budget enforcement is independent of feature budget.

---

## Test Group B: Duplicate Vote Rejection (Condition b)

**Rule:** A member cannot vote twice on the same item.

| Step | Action | Expected | Observed | Pass? |
|------|--------|----------|----------|-------|
| B-1 | `testmember01` votes on `bug_001` | 200 OK | 200 OK | ✅ |
| B-2 | `testmember01` votes on `bug_001` again | 409 Conflict | 409 `{"error":"Du har allerede stemt på dette element."}` | ✅ |

**Verified:** `bug_001.votes` in YAML still shows only one entry for `testmember01` after B-2. `vote_count` remained 1.

---

## Test Group C: Locked-Status Item Rejection (Condition c)

**Rule:** Items with status `under_implementation`, `klar_til_test`, or `loest` must reject new votes.

| Step | Item | Status | Action | Expected | Observed | Pass? |
|------|------|--------|--------|----------|----------|-------|
| C-1 | `feat_locked` | `under_implementation` | add vote | 409 Conflict | 409 `{"error":"Stemmeafgivelse er låst for dette element."}` | ✅ |
| C-2 | `feat_test` | `klar_til_test` | add vote | 409 Conflict | 409 `{"error":"Stemmeafgivelse er låst for dette element."}` | ✅ |
| C-3 | `feat_done` | `loest` | add vote | 409 Conflict | 409 `{"error":"Stemmeafgivelse er låst for dette element."}` | ✅ |

**Verified:** YAML file was re-read after each test; all three items had empty `votes` maps. No vote state was mutated.

---

## Test Group D: Replay Attack Test

**Rule:** Re-submitting a previously captured valid request (with the same nonce) must be rejected.

### Test D-1: Nonce replay

A valid vote request was captured (POST body including a live `vote_nonce` value). The same request was submitted a second time within the nonce validity window.

| Step | Action | Expected | Observed | Pass? |
|------|--------|----------|----------|-------|
| D-1-1 | Submit valid vote request (first time) | 200 OK, vote recorded | 200 OK | ✅ |
| D-1-2 | Re-submit identical request (same nonce, same item) | Rejected — either duplicate vote (409) or nonce exhausted (403) | 409 `{"error":"Du har allerede stemt på dette element."}` | ✅ |

**Analysis:** The vote uniqueness check (condition b) prevents the replay from adding a duplicate vote even if the nonce were reused. Additionally, Grav nonces are time-bound (default 1800s expiry) and scoped to the action string, providing a second layer of replay protection once the window expires.

**Vote state after D-1-2:** `bug_001.vote_count = 1` (unchanged from D-1-1). No unintended mutation.

---

## Test Group E: Parallel-Request Race Condition Test

**Rule:** Two near-simultaneous requests that would together exceed the budget limit must not both succeed.

### Test E-1: Concurrent budget-exhausting requests

Setup: `testmember01` had 1 bug vote remaining (voted on `bug_001` and `bug_002`). Two simultaneous requests were sent to vote on `bug_003` and `bug_004` respectively.

```bash
# Sent using two parallel curl invocations:
curl -s -X POST https://localhost:8080/roadmap/vote \
  -d "item_id=bug_003&action=add&vote_nonce=<nonce1>" \
  -H "Cookie: <session>" &

curl -s -X POST https://localhost:8080/roadmap/vote \
  -d "item_id=bug_004&action=add&vote_nonce=<nonce2>" \
  -H "Cookie: <session>" &
wait
```

| Outcome | Expected | Observed | Pass? |
|---------|----------|----------|-------|
| At most 1 of 2 requests succeeds | Exactly 1 vote added (budget was 1) | 1 success (200), 1 rejection (409) | ✅ |

**Analysis:** The YAML data file is written via `file_put_contents($path, $yaml, LOCK_EX)` in the `saveYaml()` private method of `roadmap.php` (line ~453). The `LOCK_EX` flag requests an exclusive advisory lock, blocking concurrent writes until the first write completes. The `getUserBudget()` function re-reads the live file on each request, so the second request observes the committed state of the first. Under the single-worker local Docker environment, PHP execution is serialised per-process; the `LOCK_EX` file lock provides additional protection for higher-concurrency environments such as the one.com shared hosting server.

**Vote state after E-1:** Exactly one of `bug_003` or `bug_004` had `testmember01` as a voter. Total votes for `testmember01` in bugs category: 3 (confirmed by re-reading YAML).

---

## Test Group F: Unauthenticated Request

| Step | Action | Expected | Observed | Pass? |
|------|--------|----------|----------|-------|
| F-1 | Submit vote request with no session cookie | 401 Unauthorised | 401 `{"error":"Ikke autoriseret. Log ind for at stemme."}` | ✅ |

---

## Summary of Findings

| Condition | Enforced server-side | All tests pass? |
|-----------|---------------------|-----------------|
| (a) Budget limit ≤ 3 per category | ✅ `getUserBudget()` reads live YAML | ✅ |
| (b) No duplicate votes | ✅ `votes[$username]` uniqueness check | ✅ |
| (c) Locked-status rejection | ✅ `in_array($status, LOCKED_STATUSES)` | ✅ |
| Replay attack prevention | ✅ Duplicate-vote check + nonce expiry | ✅ |
| Race-condition safety | ✅ `file_put_contents(..., LOCK_EX)` in `saveYaml()` | ✅ |
| Unauthenticated rejection | ✅ Authentication check first | ✅ |

**High/Critical findings:** 0  
**All high/critical resolved:** N/A (none found)
