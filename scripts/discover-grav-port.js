#!/usr/bin/env node

// Resolve the Grav container + port for the current worktree.
//
// Every checkout (main repo or worktree) gets its own container named
// grav-<sha256_8 of absolute path>. `scripts/grav-up.sh` is the only
// supported way to bring one up; this script is the only supported way
// to find it. There is NO fallback to a bare "grav" container — if the
// worktree doesn't have its own container, we fail loud so tests stop
// rather than silently probing the wrong Grav.
//
// Resolution chain (port + container are resolved together so they
// cannot disagree):
//   1. GRAV_PORT + GRAV_CONTAINER environment variables — exported by
//      grav-up.sh, fastest path within the same shell.
//   2. .gan/port-registry.json inside the worktree — survives Claude
//      Desktop restarts and shell changes.
//   3. docker ps filtered by the worktree's deterministic container
//      name — ultimate truth if the registry is stale or missing.
//
// If none of these find a running container, throw with instructions.
//
// Usage (CLI):   node scripts/discover-grav-port.js [worktree-path]
//                  — prints the port on stdout; exits 1 with an
//                    explanatory message on stderr if nothing is found.
// Usage (lib):   const { discoverGravEnv, discoverGravPort,
//                        containerNameFor } = require('./scripts/discover-grav-port.js');

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execSync } = require('child_process');

function containerNameFor(worktreeAbs) {
  const hash = crypto.createHash('sha256').update(worktreeAbs).digest('hex').slice(0, 8);
  return `grav-${hash}`;
}

function resolveWorktreeAbs(worktreePath) {
  // Resolve symlinks so the registry key matches what `cd && pwd -P`
  // writes in grav-up.sh. Without realpathSync, `/tmp/foo` (logical)
  // would miss a registry entry written as `/private/tmp/foo`
  // (physical) on macOS.
  try {
    return fs.realpathSync(path.resolve(worktreePath));
  } catch (_) {
    return path.resolve(worktreePath);
  }
}

function containerIsRunning(name) {
  try {
    const output = execSync(
      `docker ps --filter "name=^${name}$" --format "{{.Names}}"`,
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
    ).trim();
    return output === name;
  } catch (_) {
    return false;
  }
}

function portFromDocker(name) {
  try {
    const output = execSync(
      `docker ps --filter "name=^${name}$" --format "{{.Ports}}"`,
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
    ).trim();
    if (!output) return null;
    // Matches "0.0.0.0:8090->80/tcp" or "[::]:8090->80/tcp"
    const match = output.match(/:(\d+)->80\//);
    return match ? parseInt(match[1], 10) : null;
  } catch (_) {
    return null;
  }
}

function notFoundError(worktreeAbs, expectedContainer) {
  return new Error(
    `No running Grav container for this worktree.\n` +
    `  Worktree:   ${worktreeAbs}\n` +
    `  Expected:   ${expectedContainer}\n` +
    `  Fix:        scripts/grav-up.sh ${worktreeAbs} [port]\n` +
    `  Legacy 'grav' container (if any) is intentionally NOT used — ` +
    `every worktree must have its own container so tests always probe the code under test.`
  );
}

function discoverGravEnv(worktreePath = '.') {
  const worktreeAbs = resolveWorktreeAbs(worktreePath);
  const expectedContainer = containerNameFor(worktreeAbs);

  // Layer 1: env vars (primary — set by grav-up.sh in-session)
  if (process.env.GRAV_PORT && process.env.GRAV_CONTAINER) {
    const envPort = parseInt(process.env.GRAV_PORT, 10);
    if (Number.isInteger(envPort) && envPort > 0 && process.env.GRAV_CONTAINER) {
      // Only trust the env if its container actually belongs to this
      // worktree — prevents a shell that leaked vars from another
      // worktree from pointing us at the wrong Grav.
      if (process.env.GRAV_CONTAINER === expectedContainer
          && containerIsRunning(expectedContainer)) {
        return { port: envPort, container: expectedContainer };
      }
    }
  }

  // Layer 2: port registry
  const registryPath = path.join(worktreeAbs, '.gan', 'port-registry.json');
  if (fs.existsSync(registryPath)) {
    try {
      const registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
      const entry = registry.worktrees && registry.worktrees[worktreeAbs];
      if (entry
          && entry.status === 'running'
          && Number.isInteger(entry.port)
          && entry.container === expectedContainer
          && containerIsRunning(expectedContainer)) {
        return { port: entry.port, container: expectedContainer };
      }
    } catch (e) {
      console.warn(`Warning: Could not read port registry at ${registryPath}: ${e.message}`);
    }
  }

  // Layer 3: docker ps by deterministic name (registry was stale/missing)
  if (containerIsRunning(expectedContainer)) {
    const p = portFromDocker(expectedContainer);
    if (p) return { port: p, container: expectedContainer };
  }

  throw notFoundError(worktreeAbs, expectedContainer);
}

// Back-compat shim for callers that only need the port.
function discoverGravPort(worktreePath = '.') {
  return discoverGravEnv(worktreePath).port;
}

if (require.main === module) {
  try {
    const { port } = discoverGravEnv(process.argv[2] || '.');
    process.stdout.write(String(port) + '\n');
    process.exit(0);
  } catch (e) {
    process.stderr.write(`ERROR: ${e.message}\n`);
    process.exit(1);
  }
}

module.exports = { discoverGravEnv, discoverGravPort, containerNameFor };
