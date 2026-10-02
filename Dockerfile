# syntax=docker/dockerfile:1

###############################################################################
# Single-container image: mushpi-server (NestJS) + the built mushpi-client SPA.
#
# Build context = this repository's root (the mushpi-ops checkout). The sibling
# sub-repos mushpi-server/ and mushpi-client/ are materialized inside it by CI,
# or by transient local clones (recipe: REFERENCE.md). Self-hosters never build
# at all — they pull the published image.
###############################################################################

###############################################################################
# Stage 1 — Build the React client
#
# The generated API client (src/api/generated/*) is gitignored upstream, so we
# regenerate it from the server's committed spec/openapi.json before
# type-checking/bundling.
###############################################################################
FROM node:24-bookworm-slim AS client-build
WORKDIR /app

# Activate Corepack so `yarn` resolves to the project's pinned Yarn 4 (via the
# `packageManager` field), not the image's default Yarn 1 shim.
RUN corepack enable

# openapi-generator-cli (used by `yarn gen:client`) needs a JRE to run.
RUN apt-get update \
    && apt-get install -y --no-install-recommends default-jre-headless \
    && rm -rf /var/lib/apt/lists/*

# Install client dependencies (layer-cached on package.json/yarn.lock).
COPY mushpi-client/package.json mushpi-client/yarn.lock mushpi-client/.yarnrc.yml ./
RUN yarn install --immutable

COPY mushpi-client/ .

# Canonical OpenAPI spec (committed in mushpi-server/spec/openapi.json) →
# regenerate the gitignored API client before building.
COPY mushpi-server/spec/openapi.json ./openapi.json
# Release-bundle manifest (repo root) → baked into the SPA as __APP_RELEASE_VERSION__.
COPY release.json /app/release.json
RUN yarn gen:client && yarn gen:schemas

# Same-origin API base: the SPA calls the server on the same origin.
ARG VITE_API_BASE_URL=/
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL}
RUN yarn build

###############################################################################
# Stage 2 — Build the server
###############################################################################
FROM node:24-bookworm-slim AS server-build
WORKDIR /app

# Activate Corepack (see client-build stage note).
RUN corepack enable

COPY mushpi-server/package.json mushpi-server/yarn.lock mushpi-server/.yarnrc.yml ./
RUN yarn install --immutable

# Explicitly copy source + build config. NOT `COPY mushpi-server/ .` — that
# would keep the sibling mushpi-client/ out of the compile set and shift tsc's
# rootDir (breaking the package.json import and the dist/src/main.js entrypoint).
COPY mushpi-server/nest-cli.json mushpi-server/tsconfig.json mushpi-server/tsconfig.build.json ./
COPY mushpi-server/src ./src
COPY mushpi-server/docs ./docs
COPY mushpi-server/spec ./spec
# Branding assets (Swagger UI favicon) — served by ServeStaticModule at
# /public. Added to the explicit list above (not via `COPY mushpi-server/ .`).
COPY mushpi-server/public ./public
RUN yarn build

###############################################################################
# Stage 3 — Runtime
###############################################################################
FROM node:24-bookworm-slim AS runtime
WORKDIR /usr/src/app

ENV NODE_ENV=prod

# Activate Corepack (see client-build stage note).
RUN corepack enable

# Native-compile toolchain for better-sqlite3 (its install script tries a
# prebuilt binary first but falls back to `node-gyp rebuild`, needing Python +
# a C++ compiler; g++ pulls the rest), plus the container's own mDNS resolver:
# avahi-daemon resolves the growing units' `.local` names, libnss-mdns is the
# NSS client the server's lookups go through, and dumb-init is PID 1 so the
# daemonized resolver is reaped (see the ENTRYPOINT note below).
#
# policy-rc.d makes every invoke-rc.d call in this layer a no-op: the avahi
# package's post-install otherwise tries to start the daemon, which fails with
# no init system here and breaks the build. Removed again at the end of the
# same layer, so the final image carries no leftover service-start suppression.
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d \
    && chmod +x /usr/sbin/policy-rc.d \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        python3 make g++ \
        avahi-daemon libnss-mdns dumb-init \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d \
    && test -x /usr/bin/dumb-init

# Query-only resolver configuration, replacing the package default. The daemon
# answers `.local` lookups but announces nothing:
#   - enable-dbus=no   — nothing talks to it over D-Bus; the NSS client uses
#                        /run/avahi-daemon/socket directly, and avahi-resolve /
#                        avahi-browse (D-Bus tools) are not used for verification.
#   - use-ipv6=no      — the units are reached over IPv4 A records only.
#   - publishing off   — MANDATORY. The compose service runs network_mode: host,
#                        so this daemon shares the host's network namespace; a
#                        second responder claiming names would collide with the
#                        host's own mDNS stack. Never re-enable it.
#   - reflector off    — the container must not relay other segments' mDNS traffic.
RUN cat > /etc/avahi/avahi-daemon.conf <<'EOF'
[server]
enable-dbus=no
use-ipv4=yes
use-ipv6=no

[publish]
disable-publishing=yes
disable-user-service-publishing=yes

[reflector]
enable-reflector=no
EOF

# NSS wiring for the resolver. The full mdns4 plugin (not mdns4_minimal) plus
# /etc/mdns.allow listing `.local.` and `.local` makes `.local` authoritative
# for the plugin — the _minimal variant first sends an SOA query for `local` to
# the configured DNS server, adding latency and misbehaving when that server
# does not answer NXDOMAIN. Anything outside the allow-list skips mdns4 and
# falls through to dns.
#
# The `hosts:` line is rewritten UNCONDITIONALLY: relying on the package's
# post-install to have inserted a particular spelling risks a silent no-op,
# whose failure mode is the worst one here — resolver running, nothing resolves.
# The final grep is a build-time assertion of the exact resulting line.
RUN set -eux; \
    printf '.local.\n.local\n' > /etc/mdns.allow; \
    [ -f /etc/nsswitch.conf ] || : > /etc/nsswitch.conf; \
    sed -i 's/^hosts:.*/hosts: files mdns4 [NOTFOUND=return] dns/' /etc/nsswitch.conf; \
    grep -q '^hosts:' /etc/nsswitch.conf \
        || printf 'hosts: files mdns4 [NOTFOUND=return] dns\n' >> /etc/nsswitch.conf; \
    grep -Fqx 'hosts: files mdns4 [NOTFOUND=return] dns' /etc/nsswitch.conf

# Production dependencies only (builds the better-sqlite3 native binding).
COPY mushpi-server/package.json mushpi-server/yarn.lock mushpi-server/.yarnrc.yml ./
RUN yarn workspaces focus --all --production \
    && yarn cache clean

# Compiled server output + built client SPA.
COPY --from=server-build /app/dist ./dist
COPY --from=client-build /app/dist ./client

# Branding assets — build-time COPY, NOT a volume (contrast with the /data
# uploads dir below): ServeStaticModule resolves `public` against WORKDIR,
# so it must ship in the runtime image or the assets 404.
COPY --from=server-build /app/public ./public

# Data-directory guard + container mDNS resolver start + privilege drop — the
# container starts as root, this script creates /data and its images/logs
# subdirs, ensures node:node ownership, starts the query-only resolver baked in
# above (skipped with a warning when not root; a failed start is logged, never
# fatal — the server boots and the announced-IP fallback carries the polls),
# then drops to the `node` user with setpriv and execs the CMD. Fails loudly
# (with an operator-readable remedy) if it runs unprivileged and /data is not
# writable. See REFERENCE.md for the full behaviour.
COPY scripts/docker-entrypoint.sh /usr/src/app/docker-entrypoint.sh
RUN chmod +x /usr/src/app/docker-entrypoint.sh

# ServeStaticModule requires this absolute path in prod (Joi-enforced).
ENV CLIENT_DIST_DIR=/usr/src/app/client

# Single persisted volume: SQLite DB + uploaded images + logs. The chown keeps
# the no-volume smoke-test path working (the entrypoint fixes ownership on a
# bind-mount instead, so a fresh host dir needs no manual preparation).
RUN mkdir -p /data/logs /data/images \
    && chown -R node:node /data

# No USER directive: the entrypoint drops root → node via setpriv before
# exec'ing the server, so a root start can repair a daemon-created bind-mount
# source dir and start the resolver. Consequence: `docker exec` into a running
# container defaults to root, not `node` — pass `--user node` when checking
# anything the server itself does, including `.local` resolution.
EXPOSE 3000

# Liveness probe (Node built-in fetch — no curl/wget in -slim). APP_SECRET is
# optional and unset by default, so /ping needs no Authorization header.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/ping').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# dumb-init is PID 1: it reaps the daemonized avahi resolver (which double-forks
# out of the entrypoint's process and is reparented here) and forwards signals to
# the entrypoint script — which `exec`s, so node stays in dumb-init's direct
# line of succession rather than becoming an orphan.
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/src/app/docker-entrypoint.sh"]
CMD ["node", "dist/src/main.js"]
