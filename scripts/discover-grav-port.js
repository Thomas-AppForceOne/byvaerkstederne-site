#!/usr/bin/env node

// Discover which port the Grav container for a given worktree is bound to.
//
// Three-layer fallback:
//   1. GRAV_PORT environment variable (set by gan-up.sh) — fastest, primary.
//   2. .gan/port-registry.json inside the worktree — survives Claude restart.
//   3. docker ps query by container name — ultimate fallback if registry is
//      missing or corrupt.
//
// Usage (CLI):  node scripts/discover-grav-port.js [worktree-path]
//                 — prints the port to stdout on success, exits 1 with an
//                   explanatory message on stderr if no port can be found.
// Usage (lib):  const { discoverGravPort } = require('./scripts/discover-grav-port.js');

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { execSync } = require('child_process');

function containerNameFor(worktreeAbs) {
  const hash = crypto.createHash('sha256').update(worktreeAbs).digest('hex').slice(0, 8);
  return `grav-${hash}`;
}

function discoverGravPort(worktreePath = '.') {
  // Layer 1: environment variable (primary, fastest)
  if (process.env.GRAV_PORT) {
    const envPort = parseInt(process.env.GRAV_PORT, 10);
    if (Number.isInteger(envPort) && envPort > 0) {
      return envPort;
    }
  }

  // Resolve symlinks so the registry key matches what `cd && pwd -P`
  // writes in gan-up.sh. Without realpathSync, `/tmp/foo` (logical) would
  // miss a registry entry written as `/private/tmp/foo` (physical) on macOS
  // — and we'd silently fall through to the bare `grav` container.
  // If the path doesn't exist yet, fall back to path.resolve so the caller
  // still gets a sensible error message from layer 3.
  let worktreeAbs;
  try {
    worktreeAbs = fs.realpathSync(path.resolve(worktreePath));
  } catch (_) {
    worktreeAbs = path.resolve(worktreePath);
  }

  // Layer 2: port registry file
  const registryPath = path.join(worktreeAbs, '.gan', 'port-registry.json');
  if (fs.existsSync(registryPath)) {
    try {
      const registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
      const entry = registry.worktrees && registry.worktrees[worktreeAbs];
      if (entry && entry.status === 'running' && Number.isInteger(entry.port)) {
        return entry.port;
      }
    } catch (e) {
      console.warn(`Warning: Could not read port registry at ${registryPath}: ${e.message}`);
    }
  }

  // Layer 3: docker ps query. Try the deterministic hashed name first,
  // then fall back to the legacy bare "grav" container (used by
  // `make start` on the main repo before gan-up.sh existed).
  const portFromContainer = (name) => {
    try {
      const output = execSync(
        `docker ps --filter "name=^${name}$" --format "{{.Ports}}"`,
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }
      ).trim();
      if (output) {
        // Matches "0.0.0.0:8090->80/tcp" or "[::]:8090->80/tcp"
        const match = output.match(/:(\d+)->80\//);
        if (match) return parseInt(match[1], 10);
      }
    } catch (_) {
      // docker not available or command failed — caller will keep trying
    }
    return null;
  };

  for (const name of [containerNameFor(worktreeAbs), 'grav']) {
    const p = portFromContainer(name);
    if (p) return p;
  }

  throw new Error(
    `Cannot determine GRAV_PORT for ${worktreeAbs}\n` +
    `Solutions:\n` +
    `  1. Run: scripts/gan-up.sh ${worktreePath} [port]\n` +
    `  2. Set: export GRAV_PORT=<port>\n` +
    `  3. Check: docker ps | grep grav-`
  );
}

if (require.main === module) {
  try {
    const port = discoverGravPort(process.argv[2] || '.');
    process.stdout.write(String(port) + '\n');
    process.exit(0);
  } catch (e) {
    process.stderr.write(`ERROR: ${e.message}\n`);
    process.exit(1);
  }
}

module.exports = { discoverGravPort, containerNameFor };
