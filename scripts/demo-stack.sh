#!/usr/bin/env bash
# demo-stack.sh — the single documented entry point for the demo stack: server +
# dashboard + five simulated Pico units, one command, on a laptop, with a
# disposable data directory.
#
# Two image modes, chosen by the internal switch MUSHPI_DEMO_LOCAL — set by
# scripts/demo-stack-local.sh, an internal seam of that wrapper and not a user
# knob (see REFERENCE.md §Local demo stack) — both sharing
# docker-compose.demo.base.yml:
#   published (default)  base + docker-compose.demo.yml        — pulls GHCR images
#   local build          base + docker-compose.demo-local.yml  — builds them here
#                                                                      from ../mushpi-server,
#                                                                      ../mushpi-client and
#                                                                      ../mushpi-mock
# scripts/demo-stack-local.sh is the wrapper that sets the local mode; run it
# from the sibling layout it needs.
#
# Usage:
#   scripts/demo-stack.sh              # foreground (Ctrl+C stops it); after
#                                      # the stack is up, run the printed
#                                      # one-liner to verify the seed
#   scripts/demo-stack.sh -d           # detached; extra args pass through to
#                                      # `docker compose ... up`; the seed is
#                                      # verified before the script exits
#   scripts/demo-stack-local.sh        # same, but building the images from this
#                                      # machine's working copies (checks the
#                                      # sibling layout it needs first)
#
# What it does: sources `.env` if present (optional — see below), validates
# the announce secret against the server's public-demo rules, generates
# .demo-mock-config.json for the mock container (five units on the
# server-seeded handles tent-one … tent-five), ensures the demo data
# directory exists, then brings the stack up with `docker compose <the active
# mode's two -f files> up "$@"`. On the detached path
# (`-d`) it hands off to scripts/demo-verify.sh, which confirms the demo profile
# actually came up as designed before this script reports success — seeded
# reading depth inside a window anchored to each unit's own data, the six-unit
# roster, batch placement, every mocked unit's announce/poll identity, and the
# server's demo-ownership marker on the volume. The foreground path cannot
# verify (exec hands the terminal to compose), so it delegates to the same
# script with --print for the pasteable one-liners.
#
# Environment supply is decoupled from `.env`: PICO_ANNOUNCE_SECRET may come
# from a local `.env` (the laptop convention) OR from the ambient environment
# (hosted deployments that inject it). The demo compose file interpolates the
# secret from either source and deliberately carries no `env_file:` — the demo
# container never inherits unrelated hub keys from `.env`.
#
# Idempotent: every run regenerates the mock config from the current secret and
# reuses whatever state the demo data directory already holds. It never reads
# or writes the hub's docker-compose.yml or MUSHPI_DATA_DIR — the demo's live
# state is only ever the demo's own MUSHPI_DEMO_DATA_DIR.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "demo-stack: $*" >&2; exit 1; }

# `.env` is OPTIONAL now: load it only when it exists, and only for this
# script's own validation and config generation — the secret may instead come
# from the ambient environment. Compose reads the same file itself for
# interpolation. Note: .env is SOURCED by bash, so keep values simple
# (an openssl hex secret is; spaces/quotes would need shell quoting).
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

# ---------------------------------------------------------------------------
# IMAGE MODE — which compose files get merged. The two modes are mutually
# exclusive and share docker-compose.demo.base.yml, so the ONLY difference
# between a published run and a local one is where the two images come from and
# which host ports are published; everything below (secret resolution, mock
# config, seeding verification, poll identity) is mode-independent.
#   published (default)  base + docker-compose.demo.yml        — GHCR images
#   local build          base + docker-compose.demo-local.yml  — built here
# The switch is MUSHPI_DEMO_LOCAL, set by scripts/demo-stack-local.sh — an
# internal seam of that wrapper, not a knob to export by hand.
if [ "${MUSHPI_DEMO_LOCAL:-0}" = "1" ]; then
  COMPOSE_FILES=(-f docker-compose.demo.base.yml -f docker-compose.demo-local.yml)
  echo "demo-stack: LOCAL BUILD mode — images mushpi:demo-local and mushpi-mock:demo-local are built on this machine from the working copies at ../mushpi-server, ../mushpi-client and ../mushpi-mock, uncommitted changes included. No CI run, no registry: nothing here is ever pushed or pulled. A tag that already exists locally is NOT rebuilt by 'up', so pass --build to pick up edits to a working copy. The dashboard port collides with anything else on ${MUSHPI_DEMO_PORT:-3000} — set MUSHPI_DEMO_PORT, or stop the other listener."
else
  COMPOSE_FILES=(-f docker-compose.demo.base.yml -f docker-compose.demo.yml)
  echo "demo-stack: PUBLISHED mode — images come from ghcr.io/mushroom-pi (MUSHPI_IMAGE_TAG, MUSHPI_MOCK_IMAGE_TAG; both default latest). To build them from this machine's working copies instead, run scripts/demo-stack-local.sh — it checks the sibling layout it needs and selects the local mode."
fi
# The command as an array for execution, and as a single string (via [*]) for
# the one-liners printed for a human to paste — both spell the ACTIVE mode's
# file list, so a pasted verifier command talks to the stack that is actually
# running rather than defaulting back to the published files.
COMPOSE_CMD=(docker compose "${COMPOSE_FILES[@]}")

# Server-side rules being mirrored (config.schema.ts): PICO_ANNOUNCE_SECRET is
# required, min 6 chars, and a demo boot explicitly refuses the published dev
# default. Failing here gives a readable message instead of a crash-looping
# container.
: "${PICO_ANNOUNCE_SECRET:=}"
[ -n "$PICO_ANNOUNCE_SECRET" ] \
  || fail "PICO_ANNOUNCE_SECRET is unset — laptop: copy .env.example to .env and set it (openssl rand -hex 32); hosted: export PICO_ANNOUNCE_SECRET in the environment. The demo profile will not boot without it."
[ "${#PICO_ANNOUNCE_SECRET}" -ge 6 ] \
  || fail "PICO_ANNOUNCE_SECRET is shorter than 6 characters — the demo profile refuses to boot."
[ "$PICO_ANNOUNCE_SECRET" != "mushpi-dev-secret" ] \
  || fail "PICO_ANNOUNCE_SECRET is the published dev default — a demo boot refuses it. Generate one: openssl rand -hex 32"
case "$PICO_ANNOUNCE_SECRET" in
  *'"'*|*'\'*) fail "PICO_ANNOUNCE_SECRET contains a double quote or backslash — that cannot be embedded into the generated JSON config; pick a hex secret (openssl rand -hex 32)." ;;
esac

# Disposable demo state — its own directory, never the hub's MUSHPI_DATA_DIR.
# Relative paths resolve against this repo root, same as the compose bind.
DATA_DIR="${MUSHPI_DEMO_DATA_DIR:-./mushpi-demo-data}"
mkdir -p "$DATA_DIR"

# Generate the mock's config. Fixed values are shared with docker-compose.demo.base.yml:
#   - "mushpi" is the server service's DNS name on the mushpi-demo bridge;
#   - 172.28.0.10 is the mock container's fixed address (compose ipv4_address) —
#     units announce it so the server's 60s poll reaches them across the bridge
#     (mDNS multicast is dead there; the announced IP is the design);
#   - /data/app.sqlite matches the server's SQLITE_PATH inside the shared mount;
#   - five units on 5000-5004, matching the loopback port range compose publishes.
#
# The handles are the server-seeded demo roster (tent-one … tent-five), NOT a
# mock-namespaced set: announcing an already-seeded handle makes the server's
# upsert-by-handle land on that unit, so the mock drives the roster the
# dashboard shows instead of adding a parallel row per unit. `tent-six` is
# deliberately absent — it is the roster's offline unit, and a mock that
# announced it would make it reachable.
#
# The path below is hardcoded at the repo root because docker-compose.demo.base.yml
# mounts exactly that location (`./.demo-mock-config.json:/app/config.json:ro`).
# Where a containerised run of this script should write it is a
# deployment-target decision that needs BOTH halves changed together — making
# only the script's path injectable while the compose bind stays hardcoded
# would be half a solution, so neither moves yet.
MOCK_IP='172.28.0.10'
cat > .demo-mock-config.json <<EOF
{
  "server_url": "http://mushpi:3000",
  "hub_secret": "${PICO_ANNOUNCE_SECRET}",
  "announce_ip": "${MOCK_IP}",
  "db_path": "/data/app.sqlite",
  "units": [
    { "handle": "tent-one", "port": 5000 },
    { "handle": "tent-two", "port": 5001 },
    { "handle": "tent-three", "port": 5002 },
    { "handle": "tent-four", "port": 5003 },
    { "handle": "tent-five", "port": 5004 }
  ]
}
EOF
# Embeds the announce secret — owner-readable only, and gitignored.
chmod 600 .demo-mock-config.json

# Seed bookkeeping for the informational line below — the VERIFICATION lives in
# scripts/demo-verify.sh. Both values are the SERVER's demo-seeding knobs (the
# mock does not seed): the defaults mirror the `environment:` entries passed to
# mushpi in docker-compose.demo.base.yml — same variable NAMES, so one `.env`
# line retunes the container and this script together and the two cannot drift.
# 1440 = one reading per minute per unit. SEED_READINGS_DAYS has a server-side
# default of 14; compose pins 15 here and the demo's depth is expressed by that
# pin. The server refuses 0 and fractional day values at boot, so disabling
# seeding is SEED_ENABLED=false, never a day count of 0.
#
# scripts/demo-verify.sh mirrors these two defaults (and this file's `.env`
# precedence) instead of inheriting them, so it can be invoked on its own by
# scripts/demo-reset.sh. That is a deliberate two-places-must-agree coupling:
# change a default here, change it there in the same commit.
SEED_ENABLED="${SEED_ENABLED:-true}"
SEED_READINGS_DAYS="${SEED_READINGS_DAYS:-15}"

echo "demo-stack: dashboard will be at http://localhost:${MUSHPI_DEMO_PORT:-3000} once the server is healthy; the SERVER seeds ${SEED_READINGS_DAYS} day(s) of history for the live roster on boot (SEED_ENABLED=false disables seeding), and the five units (tent-one … tent-five) announce onto it."

# Detached (-d/--detach) is the only path that can verify after `up`: the
# foreground path execs compose below, which replaces this shell and owns the
# terminal until Ctrl+C. Detection is per-word — a bundled `--detach=false`
# would read as detached; pass plain -d/--detach only (a human running this
# script is the audience).
detach=0
for arg in "$@"; do
  case "$arg" in
    -d | --detach) detach=1 ;;
  esac
done

if [ "$detach" = 1 ]; then
  # NOT `exec` — control must return here so scripts/demo-verify.sh can run after
  # the stack starts. `up -d` waits for mushpi to be healthy (the mock's
  # depends_on condition) before returning, so the seed has a live server to
  # announce against from the first poll and the verifier starts against a
  # finished seeding. DEMO_VERIFY_TAG=demo-stack keeps the extracted checks'
  # message prefix exactly what this script printed before the move.
  "${COMPOSE_CMD[@]}" up "$@"
  DEMO_VERIFY_TAG=demo-stack scripts/demo-verify.sh "${COMPOSE_FILES[@]}"
else
  # Foreground: compose owns the terminal from here (exec replaces this shell),
  # so the verification guidance is printed by scripts/demo-verify.sh --print —
  # the same pasteable one-liners this script printed before the move, spelled
  # with the ACTIVE mode's file pair so a pasted command talks to the stack that
  # is actually running (their inner double quotes are shell-escaped by the
  # verifier so the pasted argument survives parsing). The verifier's
  # demo-ownership marker check is deliberately not part of this printed
  # guidance: it is a read-only container check the automated paths run
  # themselves.
  DEMO_VERIFY_TAG=demo-stack scripts/demo-verify.sh "${COMPOSE_FILES[@]}" --print
  exec "${COMPOSE_CMD[@]}" up "$@"
fi
