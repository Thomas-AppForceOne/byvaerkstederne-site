# Local development container — PHP and Grav pinned INDEPENDENTLY.
#
# WHY THIS EXISTS
# ---------------
# The Grav core is not in this repo. Locally it came from
# lscr.io/linuxserver/grav; on a tier it comes from
# deploy/grav-admin-v<GRAV_VERSION>.zip. That image ships one PHP and one
# Grav, welded together, so the two could not be chosen separately:
#
#   * pulling a newer image to get a newer PHP dragged Grav 1.7.49.5 up to
#     2.0.20 — a CMS major ahead of every tier — silently, during work whose
#     whole purpose was removing that kind of divergence, and
#   * staying on the old image to keep Grav 1.7 pinned the local PHP at 8.3
#     while every tier served 8.5.
#
# Neither is acceptable, and there was no third option as long as one image
# decided both. So: take PHP from the base image, and lay this repo's
# declared Grav over the top.
#
# TWO PINS, TWO DECISIONS
# -----------------------
#   PHP_BASE      the digest below, chosen for the PHP it carries
#   GRAV_VERSION  deploy.sh's GRAV_VERSION — the same zip the tiers get
#
# Upgrading one no longer forces the other, and both are guarded:
# tests/deploy/unit-php-parity.sh and unit-grav-parity.sh compare what runs
# against what is declared.
#
# WHAT THE BASE IMAGE STILL PROVIDES
# ----------------------------------
# nginx, php-fpm, s6 and the init that symlinks user/, logs/, backup/ and
# robots.txt out to the bind-mounted /config/www. That init does NOT fetch
# or replace the Grav core — it is baked at build time — which is precisely
# what makes replacing it here safe.

# PHP 8.5.9 (Alpine 3.20). Re-pin to move PHP; GRAV_VERSION does not move
# with it.
ARG PHP_BASE=lscr.io/linuxserver/grav@sha256:e25293a61163bda5288830b38c99d28d29d206c01e4fea0359970229e6c92caf
FROM ${PHP_BASE}

# Must match deploy.sh's GRAV_VERSION, or the container runs a different CMS
# than the tiers. unit-grav-parity.sh fails the suite when they disagree,
# and scripts/grav-up.sh warns at the moment the container starts.
ARG GRAV_VERSION=1.7.52

# Replace the baked core with the version this repo deploys.
#
# The `user` entry is deliberately excluded from the wipe: on an already
# provisioned checkout it is a symlink to /config/www/user, and removing it
# would take the bind-mounted content with it. The unpacked core brings its
# own user/ which the image's init then reconciles.
RUN set -eux; \
    tmp="$(mktemp -d)"; \
    curl -fsSL -o "$tmp/grav.zip" \
      "https://github.com/getgrav/grav/releases/download/${GRAV_VERSION}/grav-admin-v${GRAV_VERSION}.zip"; \
    unzip -q "$tmp/grav.zip" -d "$tmp"; \
    test -f "$tmp/grav-admin/index.php"; \
    find /app/www/public -mindepth 1 -maxdepth 1 ! -name user -exec rm -rf {} +; \
    cp -a "$tmp/grav-admin/." /app/www/public/; \
    rm -rf "$tmp"; \
    chown -R abc:users /app/www/public; \
    grep -q "GRAV_VERSION', '${GRAV_VERSION}'" /app/www/public/system/defines.php
