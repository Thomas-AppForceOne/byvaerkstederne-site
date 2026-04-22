#!/usr/bin/env bash
set -euo pipefail

# Brings up the primary dev Grav container on :8080 against ./config.
# This is the container you keep running day-to-day. GAN evaluator runs
# use scripts/gan-up.sh instead — they never touch this one.

cd "$(dirname "$0")/.."

exec docker compose \
  -p grav-dev \
  up -d "$@"
