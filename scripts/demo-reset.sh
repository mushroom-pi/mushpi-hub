#!/usr/bin/env bash
# demo-reset.sh — return the demo stack to a fresh, populated state.
#
# What "fresh" means here, and who does it: the SERVER's clean start
# (mushpi-server/src/common/utils/clean-start.ts) runs on every NODE_ENV=demo boot
# while TypeORM is not yet connected, and unlinks the database, its sidecars and
# the image tree of a volume carrying the demo-ownership marker — then SeedService
# re-seeds the roster, batches and reading history. So this script restarts and
# verifies; it deliberately does NOT wipe anything itself:
#   no external rm of the data dir  — that is clean-start's job, and deleting a
#                                    database file under an open SQLite handle is
#                                    how a wipe goes wrong
#   no `down`, no `demo-stack.sh -d` re-run — recreating containers would also
#                                    re-resolve images and re-run `up`'s work
#   no `docker compose pull`       — the reset restarts the image already pulled.
#                                    A surprise update must not land unattended at
#                                    03:00; pulling is the operator's decision
#                                    (see MAINTAINING.md for the release path).
#
# BOTH containers restart, not just the server. The clean start wipes the database,
# so the unit rows lose their announced `ip` until something re-announces; a
# server-only restart would leave every unit unaddressable until the mock's
# poll-aware re-announce watchdog fires (~180s). Restarting the mock re-announces
# immediately instead. Ordering is not a problem: the mock's boot announce is a
# retry ladder (4 attempts spanning ~45s, per mushpi-mock's announce.py), so the
# server has that window to finish booting and seeding, and the poll identity check
# below waits far longer than the ladder.
#
# Preconditions: the demo stack must already exist (be running, or at least have
# been created by scripts/demo-stack.sh). `restart` on a stack that was never
# brought up fails non-zero, which is the right outcome: nothing here creates a
# stack.
#
# Usage:
#   scripts/demo-reset.sh            # published-image demo (base + demo overlay)
#   scripts/demo-reset.sh --local    # local-build demo (base + demo-local overlay)
#   scripts/demo-reset.sh --help
#
# The compose file pair is hardcoded per mode, matching scripts/demo-stack.sh's
# modes (and the same internal switch, decided by the flag rather than by
# MUSHPI_DEMO_LOCAL, because the reset has to say which stack it is protecting
# before it can read the environment that describes it).
#
# Safety — the structural guard runs BEFORE any action and is what enforces "this
# never runs on a real hub". It renders the ACTIVE compose file pair and refuses
# unless the render carries both NODE_ENV: demo and a mock service, and unless the
# demo's data directory resolves to a different path from the hub's MUSHPI_DATA_DIR.
# It fails closed: an unrenderable config, an unresolvable path or a missing
# assertion is a non-zero exit, never a proceed. Each refusal names what was wrong.
#
# Verification (scripts/demo-verify.sh, the same checks scripts/demo-stack.sh runs
# after a detached `up`): seeded reading depth, the six-unit roster, batch
# placement, every mocked unit's announce/poll identity, and the demo-ownership
# marker that makes the next reset come back fresh. A failed verification exits
# non-zero, so systemd records the run as a failure and leaves the previous status
# file untouched.
#
# On success it writes an ISO8601 UTC timestamp to ./mushpi-demo-reset.status
# (gitignored; override with MUSHPI_DEMO_RESET_STATUS_FILE) and logs
# "reset complete at <ISO8601>".
#
# KNOWN LIMITATION: the reset reuses the existing .demo-mock-config.json — it does
# not regenerate it, which is scripts/demo-stack.sh's job (it validates the
# announce secret first). So after PICO_ANNOUNCE_SECRET changes, the mock would
# re-announce with the stale secret and the poll identity check would fail; run
# scripts/demo-stack.sh -d to regenerate the config, then the reset works again.
#
# Scheduled by systemd/mushpi-demo-reset.timer at 03:00 host local time. Nothing
# here is time-aware; the script is safe to run by hand at any hour.
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { echo "demo-reset: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/demo-reset.sh [--local] [--help]

Restart the demo stack so the server's clean start wipes and re-seeds it, verify
the demo profile came back as designed, and record the time of the reset.

  --local   reset the local-build demo (docker-compose.demo.base.yml +
            docker-compose.demo-local.yml) instead of the published-image pair
EOF
}

# ---------------------------------------------------------------------------
# MODE — which demo file pair the reset is acting on. Same two pairs as
# scripts/demo-stack.sh, chosen here by an explicit flag so a systemd unit says
# in its own command line which stack it is allowed to touch.
LOCAL=0
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $arg" ;;
  esac
done

if [ "$LOCAL" = 1 ]; then
  COMPOSE_FILES=(-f docker-compose.demo.base.yml -f docker-compose.demo-local.yml)
  MODE='LOCAL BUILD (mushpi:demo-local + mushpi-mock:demo-local, built from the working copies beside this repo)'
else
  COMPOSE_FILES=(-f docker-compose.demo.base.yml -f docker-compose.demo.yml)
  MODE='PUBLISHED images (ghcr.io/mushroom-pi/mushpi + mushpi-mock, no pull — the image already here is the image that restarts)'
fi
COMPOSE_CMD=(docker compose "${COMPOSE_FILES[@]}")

# `.env` is OPTIONAL, loaded exactly the way scripts/demo-stack.sh loads it:
# sourced AFTER the ambient environment, so a `.env` line wins over an exported
# one. The guard below needs the two data-directory variables at the same values
# compose will interpolate them at, or it would be guarding a different stack
# than the one it is about to restart.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

# ---------------------------------------------------------------------------
# STRUCTURAL GUARD — before any action, and fail-closed. Two independent reasons
# to refuse, each naming what was wrong:
#   1. the rendered config is not the demo profile (no NODE_ENV: demo, or no mock
#      service) — resetting anything else would restart a real hub whose data is
#      nobody's to wipe;
#   2. the demo's data directory resolves to the hub's MUSHPI_DATA_DIR — a demo
#      pointed at the hub's live state is a misconfiguration that must be refused
#      here rather than discovered by clean-start.
# The render is captured, never printed: `docker compose config` INLINES
# PICO_ANNOUNCE_SECRET into the `environment:` map, so a passing dump of it into a
# journald log would leak the demo's announce secret. Compose's own FAILURE text is
# safe to print — it names variables and paths, not values.
echo "demo-reset: mode — ${MODE}"
echo "demo-reset: structural guard — rendering the active compose config ..."
if ! RENDERED="$(docker compose "${COMPOSE_FILES[@]}" config 2>&1)"; then
  fail "the demo compose config did not render — refusing to reset. Compose said: ${RENDERED}"
fi
# The render is matched with a here-string, not a pipe: under `set -o pipefail`,
# `printf | grep -q` can make grep's early exit look like printf's SIGPIPE and fail
# a perfectly good config. Patterns tolerate a quoted or unquoted scalar value and
# any indentation, so a compose-version change in emission style cannot silently
# disarm the guard.
grep -qE '^[[:space:]]*NODE_ENV:[[:space:]]*"?[[:space:]]*demo[[:space:]]*"?$' <<< "$RENDERED" \
  || fail "the rendered config carries no NODE_ENV: demo — this file pair is not the demo profile. Refusing: only a demo boot wipes and re-seeds its volume, and a hub deployment must never be restarted through this script."
grep -qE '^[[:space:]]+mock:[[:space:]]*$' <<< "$RENDERED" \
  || fail "the rendered config declares no mock service — a stack without the simulated units is not the demo stack. Refusing."

# Data-directory collision check. `realpath -m` canonicalizes a path that does not
# exist yet (the hub's MUSHPI_DATA_DIR is legitimately absent on a demo-only
# machine); `readlink -f` would fail on it. Defaults mirror docker-compose.yml
# (./mushpi-data) and docker-compose.demo.base.yml (./mushpi-demo-data), and both
# resolve against this repo root — the same directory compose resolves a relative
# bind against. If neither path can be canonicalized, the guard cannot prove the
# two volumes are distinct, so it refuses: no proceed without a verdict.
command -v realpath >/dev/null 2>&1 \
  || fail "realpath is unavailable — cannot canonicalize the data directories, and the guard will not proceed on an unproven separation between the demo volume and the hub volume."
DEMO_DIR="$(realpath -m -- "${MUSHPI_DEMO_DATA_DIR:-./mushpi-demo-data}")" \
  || fail "cannot resolve MUSHPI_DEMO_DATA_DIR — refusing to reset."
HUB_DIR="$(realpath -m -- "${MUSHPI_DATA_DIR:-./mushpi-data}")" \
  || fail "cannot resolve MUSHPI_DATA_DIR — refusing to reset."
[ "$DEMO_DIR" != "$HUB_DIR" ] \
  || fail "MUSHPI_DEMO_DATA_DIR and MUSHPI_DATA_DIR both resolve to ${DEMO_DIR} — the demo volume IS the hub volume here. Refusing: a demo boot against that directory would let clean start wipe real data. Give the demo a directory of its own (docker-compose.demo.base.yml's MUSHPI_DEMO_DATA_DIR)."
echo "demo-reset: guard passed — demo profile rendered, and the demo volume ${DEMO_DIR} is distinct from the hub volume ${HUB_DIR}"

# ---------------------------------------------------------------------------
# RESTART — both services, no recreate, no pull.
echo "demo-reset: restarting both demo services (the server's clean start owns the wipe; the mock restarts so the units re-announce) ..."
"${COMPOSE_CMD[@]}" restart \
  || fail "docker compose restart failed — the demo stack did not restart. Is it brought up yet (scripts/demo-stack.sh -d creates it, and generates the .demo-mock-config.json this stack mounts)? Inspect: docker ps -a and ${COMPOSE_CMD[*]} ps -a"

# ---------------------------------------------------------------------------
# WAIT FOR HEALTHY — `up -d` handed scripts/demo-stack.sh a healthy server for
# free, because the mock's depends_on: service_healthy gate waits for the image's
# HEALTHCHECK (Dockerfile: interval=30s, timeout=5s, start-period=30s, retries=3),
# and demo seeding is an awaited onApplicationBootstrap hook — so by the time the
# healthcheck can pass, the history is already written. `docker compose restart`
# has no such gate and no --wait, so without this the verifier's 30s seed window
# would start against a cold container and a healthy reset would read as a failure.
# The wait rides that same image healthcheck rather than inventing a second
# liveness probe that could drift from it. 240s is ~8 probe intervals: enough for a
# Pi to stop the old container, boot, wipe, and re-seed 15 days x 1440 readings.
HEALTH_DEADLINE_S=240
wait_for_mushpi_healthy() {
  local deadline=$(( $(date +%s) + HEALTH_DEADLINE_S )) cid status
  while :; do
    cid="$(docker compose "${COMPOSE_FILES[@]}" ps -q mushpi 2>/dev/null || true)"
    if [ -z "$cid" ]; then
      status='no-container'
    else
      status="$(docker inspect --format '{{.State.Health.Status}}' "$cid" 2>/dev/null || echo 'no-healthcheck')"
    fi
    if [ "$status" = "healthy" ]; then
      echo "demo-reset: mushpi reports healthy — demo seeding completes before the healthcheck can pass, so the volume is re-populated"
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "demo-reset: HEALTH WAIT TIMED OUT after ${HEALTH_DEADLINE_S}s — the server never reported healthy (last status: ${status}). Nothing was verified and no reset was recorded. Look for the clean-start refusal, a boot config-validation error, or a missing image healthcheck in: ${COMPOSE_CMD[*]} logs mushpi" >&2
      return 1
    fi
    sleep 5
  done
}
wait_for_mushpi_healthy

# ---------------------------------------------------------------------------
# VERIFY — the identical checks the demo entry point runs, with the same deadlines:
# seed depth, roster, batch placement, announce/poll identity, demo-ownership
# marker. Its non-zero exit propagates through set -e, so systemd records the
# failed run instead of a silent half-reset.
DEMO_VERIFY_TAG=demo-reset scripts/demo-verify.sh "${COMPOSE_FILES[@]}"

# ---------------------------------------------------------------------------
# STATUS — only on success, so the file always reads as "the last reset that
# actually came back fresh". A failed run leaves the previous timestamp in place
# and the non-zero exit for journald/systemctl to report.
STAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
STATUS_FILE="${MUSHPI_DEMO_RESET_STATUS_FILE:-./mushpi-demo-reset.status}"
printf '%s\n' "$STAMP" > "$STATUS_FILE" \
  || fail "the reset and its verification succeeded, but the status file ${STATUS_FILE} could not be written — check the directory is writable by the user systemd runs this as."
echo "demo-reset: reset complete at ${STAMP}"
