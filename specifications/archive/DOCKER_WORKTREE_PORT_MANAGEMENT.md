# Docker Worktree Port Management Specification

**Status:** Specification (Ready for Implementation)  
**Date:** 2026-04-21  
**Scope:** Claude desktop `/gan` skill usage with git worktrees  
**Context:** Enable agents to reliably discover and use correct Docker port in any worktree

---

## Vision

Enable the `/gan` skill to work seamlessly with Grav CMS running in different git worktrees on different ports. Each worktree can have its own containerized Grav instance running on a unique port, and agents automatically discover which port to use for running tests.

---

## Problem Statement

### Current State
- Main branch: Grav runs on hardcoded port 8080
- Worktrees: Each has hardcoded docker-compose.yml with port 8080
- Result: Multiple worktrees can't run concurrently (port conflict)
- Tests: Hardcoded to port 8080 (fails if worktree uses different port)
- Claude restart: Port information is lost (agents don't know which port)

### Desired State
- Any worktree can use any port (configurable at startup)
- Multiple worktrees run concurrently on different ports
- Tests automatically discover which port their worktree uses
- Port info persists across Claude desktop restarts
- Clear error messages if something goes wrong

---

## Solution Overview

### Architecture

**Three-Layer Port Management:**

1. **Environment Variables (Primary)**
   - Set by `gan-up.sh` when starting Docker
   - Persist within Claude desktop session
   - Fastest, simplest mechanism
   - Lost if Claude app restarts

2. **Port Registry (Fallback)**
   - `.gan/port-registry.json` file
   - Survives Claude restart
   - Allows recovery of port after app closes
   - Single source of persistent truth

3. **Docker PS Query (Ultimate Fallback)**
   - Query running Docker containers
   - Works if registry is missing/corrupted
   - Slower but most reliable

**Flow:**
```
Agent needs port
    ↓
Check GRAV_PORT env var
    ↓ (not set)
Check .gan/port-registry.json
    ↓ (not found)
Query docker ps
    ↓ (fails)
Default to 8080 (with warning)
```

---

## Implementation

### Phase 1: Fix Worktree Docker Configuration

**File:** `.claude/worktrees/[worktree-name]/docker-compose.yml`

**Current (Hardcoded):**
```yaml
services:
  grav:
    image: lscr.io/linuxserver/grav:latest
    container_name: grav
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Copenhagen
    volumes:
      - ./config:/config
    ports:
      - "8080:80"
    restart: unless-stopped
```

**Updated (Dynamic):**
```yaml
services:
  grav:
    image: lscr.io/linuxserver/grav:latest
    container_name: ${GRAV_CONTAINER:-grav}
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Copenhagen
    volumes:
      - ${GRAV_ROOT:-./config}:/config
    ports:
      - "${GRAV_PORT:-8080}:80"
    restart: unless-stopped
```

**Changes:**
- `container_name: grav` → `${GRAV_CONTAINER:-grav}`
- `ports: - "8080:80"` → `"${GRAV_PORT:-8080}:80"`
- `volumes: - ./config:/config` → `${GRAV_ROOT:-./config}:/config`

**Why:** Allows docker-compose to use dynamic values from environment variables.

---

### Phase 2: Enhance gan-up.sh

**File:** `scripts/gan-up.sh`

Enhanced behavior:

1. Resolve worktree absolute path; derive deterministic container name from SHA256-8 of the path.
2. If registry already has an entry for this worktree, recover: reuse the registered port; if the container is still up, no-op and re-export the env vars.
3. Otherwise, validate the requested port is free (lsof / netstat / ss / docker ps).
4. Start the container via `docker compose up -d --remove-orphans` with `GRAV_PORT`, `GRAV_CONTAINER`, `GRAV_ROOT` exported.
5. Poll `http://127.0.0.1:<port>/` until it returns 2xx/3xx, with a clear error and logs dump on timeout.
6. Write `.gan/port-registry.json` with `{port, container, started_at, status:"running"}` keyed by the worktree's absolute path.
7. Export `GRAV_PORT`, `GRAV_CONTAINER`, `GRAV_ROOT` for the session.
8. Print a summary block with port/container/URL.

**Key Features:**
- Port conflict detection (netstat/ss/lsof)
- Recovery from registry on Claude restart
- Unique container names (SHA256 hash)
- Robust health check (/admin or / endpoint)
- Registry persistence
- Env var export
- Clear success/failure messages

---

### Phase 3: Enhance gan-down.sh

**File:** `scripts/gan-down.sh`

Tear down the container associated with the worktree (same hash derivation as gan-up, so identification is stable), then update the registry entry's `status` to `"stopped"`. Don't remove the entry — keep the port assignment as a historical record so the next gan-up can reuse it.

---

### Phase 4: Create Port Discovery Helper

**File:** `scripts/discover-grav-port.js`

Node helper usable both as a CLI (`node scripts/discover-grav-port.js`) and as a library (`require('./scripts/discover-grav-port.js').discoverGravPort`).

Discovery order:

1. `process.env.GRAV_PORT` if set.
2. `.gan/port-registry.json` under the worktree — return `entry.port` if `entry.status === 'running'`.
3. `docker ps --filter name=^grav-<hash>$` — parse the port mapping from `{{.Ports}}`. Fall back to `name=^grav$` so the legacy `make start` container on the main repo is still discoverable.
4. Throw with a three-option error message (`gan-up.sh` / `export GRAV_PORT=` / `docker ps`).

---

### Phase 5: Update Playwright Configuration

**File:** `playwright.config.js`

Resolve `baseURL` with a fallback chain:

1. `process.env.BASE_URL` if set.
2. `http://127.0.0.1:${GRAV_PORT}` if set.
3. `discoverGravPort('.')` — log the discovered port.
4. `http://127.0.0.1:8080` with a warning if all of the above fail.

Use `127.0.0.1` (not `localhost`) to avoid the macOS IPv6 vs Docker-IPv4 silent-failure trap.

---

### Phase 6: Update Makefiles

**Files:** `Makefile` (both main repo and worktree)

Test targets must discover port and fail loudly if not found.

Behavior for `test` / `test-headed` / `test-auth`:

- Prefer `$GRAV_PORT`; otherwise shell out to `node scripts/discover-grav-port.js`.
- If no port resolves, print `❌ Cannot determine GRAV_PORT` and exit 1.
- Hit the port once with curl before running; fail loudly if Grav isn't responding.
- Echo which port tests are being run against.
- Pass `GRAV_PORT=$$PORT` to the playwright invocation.

---

### Phase 7: Update CLAUDE.md Documentation

**File:** `CLAUDE.md`

Add a "Testing in worktrees" section covering: quick start (gan-up / gan-down / make test), the discovery chain, Claude restart recovery, multiple concurrent worktrees, port-conflict handling, and troubleshooting for common errors.

---

## Port Registry File Format

**File:** `.gan/port-registry.json`

**Structure:**
```json
{
  "worktrees": {
    "/Users/thomas/AppForceOne/projects/workshop-site/.claude/worktrees/agitated-greider-3ee665": {
      "port": 9000,
      "container": "grav-a1b2c3d4",
      "started_at": "2026-04-21T10:45:00Z",
      "status": "running"
    },
    "/Users/thomas/AppForceOne/projects/workshop-site": {
      "port": 8080,
      "container": "grav-main",
      "started_at": "2026-04-21T10:00:00Z",
      "status": "running"
    }
  },
  "last_updated": "2026-04-21T10:45:00Z"
}
```

**Scope:**
- Gitignored (not committed)
- Generated per-environment
- Survives Claude restart
- Updated by gan-up.sh and gan-down.sh

---

## Edge Case Coverage

| Edge Case | Solution |
|-----------|----------|
| Claude app restarts | Registry file persists; gan-up.sh detects existing port |
| Container already running | gan-up.sh checks registry + docker ps, reuses port |
| Port already in use | netstat/ss validation fails loudly before docker starts |
| Container name collision | Unique names using SHA256 hash of absolute path |
| Multiple concurrent worktrees | Each gets unique port, all tracked in registry |
| GRAV_PORT env var lost | Discovery chain: registry → docker ps → 8080 with warning |
| Registry file corrupted | Falls back to docker ps query |
| Docker not installed | docker-compose fails with clear error |
| Container failed to start | Health check waits, fails loudly if timeout |
| Tests silent fail on wrong port | Makefile echoes which port is being tested |
| Orphaned containers | `docker compose --remove-orphans` on startup |

---

## Files Changed

| File | Action | Reason |
|------|--------|--------|
| `.claude/worktrees/*/docker-compose.yml` | Modify | Use `${GRAV_PORT}`, `${GRAV_CONTAINER}`, `${GRAV_ROOT}` |
| `scripts/gan-up.sh` | Enhance | Port validation, registry, health check |
| `scripts/gan-down.sh` | Enhance | Registry cleanup |
| `scripts/discover-grav-port.js` | Create | Port discovery helper |
| `playwright.config.js` | Update | Use discovered port |
| `Makefile` (main) | Update | Discover port in test targets |
| `.claude/worktrees/*/Makefile` | Update | Discover port in test targets |
| `CLAUDE.md` | Update | Document worktree testing |
| `.gan/port-registry.json` | Generate | Persisted port tracking (gitignored) |

---

## Acceptance Criteria

**Docker Configuration:**
- [x] Worktree docker-compose.yml uses env vars instead of hardcoded values
- [x] Defaults exist (`${GRAV_PORT:-8080}`) for backward compatibility

**gan-up.sh:**
- [x] Detects port conflicts with netstat/ss/lsof
- [x] Checks registry for existing port (recovery)
- [x] Creates unique container names via SHA256
- [x] Validates container is healthy before returning
- [x] Writes port registry JSON file
- [x] Exports env vars for Claude session
- [x] Clear success/failure messages

**gan-down.sh:**
- [x] Stops Docker container
- [x] Updates registry to mark as stopped

**Port Discovery:**
- [x] discover-grav-port.js implements three-layer fallback
- [x] Works when GRAV_PORT not set
- [x] Works after Claude restart (via registry)
- [x] Works if registry missing (via docker ps)
- [x] Falls back to legacy bare `grav` container name for main-repo backward compat
- [x] Clear error if no port found

**Playwright Config:**
- [x] Automatically discovers port
- [x] Uses discovered port for tests
- [x] Warns if defaulting to 8080

**Makefiles:**
- [x] Test targets discover port
- [x] Fail loudly if port can't be found
- [x] Show which port is being tested
- [x] Pass port to test runner

**Documentation:**
- [x] CLAUDE.md documents full workflow
- [x] Examples for common scenarios
- [x] Troubleshooting guide
- [x] Edge case handling explained

---

## Success Metrics

1. Agents automatically discover correct port in any worktree
2. Port info persists across Claude app restart
3. No port collisions between concurrent worktrees
4. Tests fail loudly if port is wrong (no silent failures)
5. Single worktree can run on different ports
6. Main branch continues to work on port 8080 (default)
7. CLAUDE.md clearly documents the complete flow
8. No hardcoded port numbers in any code

---

## Summary

This specification enables the `/gan` skill to work reliably with Docker in any git worktree on any port. By combining environment variables (simple, fast) with persistent registry (robust across restarts), we enable agents to automatically discover the correct port and run tests successfully, whether in the main branch or a feature worktree.

The system is designed specifically for Claude desktop usage, where shell sessions persist within the app but may restart between user sessions. It handles edge cases gracefully and provides clear error messages when things go wrong.
