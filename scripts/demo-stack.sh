#!/usr/bin/env bash
# demo-stack.sh — the single documented entry point for the demo stack
# (docker-compose.demo.yml): server + dashboard + five simulated Pico units,
# one command, on a laptop, with a disposable data directory.
#
# Usage:
#   scripts/demo-stack.sh              # foreground (Ctrl+C stops it); after
#                                      # the stack is up, run the printed
#                                      # one-liner to verify the seed
#   scripts/demo-stack.sh -d           # detached; extra args pass through to
#                                      # `docker compose ... up`; the seed is
#                                      # verified before the script exits
#
# What it does: sources `.env` if present (optional — see below), validates
# the announce secret against the server's public-demo rules, generates
# .demo-mock-config.json for the mock container, ensures the demo data
# directory exists, then brings the stack up with
# `docker compose -f docker-compose.demo.yml up "$@"`. On the detached path
# (`-d`) it additionally verifies the mock's seed actually landed
# (verify_demo_seed) before reporting success.
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

# Generate the mock's config. Fixed values are shared with docker-compose.demo.yml:
#   - "mushpi" is the server service's DNS name on the mushpi-demo bridge;
#   - 172.28.0.10 is the mock container's fixed address (compose ipv4_address) —
#     units announce it so the server's 60s poll reaches them across the bridge
#     (mDNS multicast is dead there; the announced IP is the design);
#   - /data/app.sqlite matches the server's SQLITE_PATH inside the shared mount;
#   - five units on 5000-5004, matching the loopback port range compose publishes.
#
# The path below is hardcoded at the repo root because docker-compose.demo.yml
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
    { "handle": "mock-tent-1", "port": 5000 },
    { "handle": "mock-tent-2", "port": 5001 },
    { "handle": "mock-tent-3", "port": 5002 },
    { "handle": "mock-tent-4", "port": 5003 },
    { "handle": "mock-tent-5", "port": 5004 }
  ]
}
EOF
# Embeds the announce secret — owner-readable only, and gitignored.
chmod 600 .demo-mock-config.json

# Seed bookkeeping shared by the verifier and the foreground guidance. The
# default mirrors docker-compose.demo.yml's `${DEMO_SEED_DAYS:-15}` — keep the
# two in sync. 1440 = one reading per minute per unit.
SEED_DAYS="${DEMO_SEED_DAYS:-15}"
SEED_EXPECTED=$(( SEED_DAYS * 1440 ))

# The verification query as ONE js line, run by the mushpi container's own node
# against the image's own better-sqlite3 — no host-side sqlite3/jq dependency
# (`exec -T` makes it usable non-interactively). Identifiers (pico_unit,
# readings, pico_unit_id, handle) are confirmed against the server entities,
# its InitSchema migration, and an empirically synchronized database. The DB
# opens READ-ONLY ({readonly:true}): a verifier must never mutate demo state,
# and a missing file simply throws — the retry loop treats a failed exec as
# "not ready yet". node applies the threshold itself and exits 0/1, so bash
# only decides "still polling" vs "done". /data/app.sqlite is the server's
# SQLITE_PATH in docker-compose.demo.yml — keep the two in sync.
SEED_JS='const Database=require("better-sqlite3");const db=new Database("/data/app.sqlite",{readonly:true});const want=["mock-tent-1","mock-tent-2","mock-tent-3","mock-tent-4","mock-tent-5"];const counts={};for(const r of db.prepare("SELECT u.handle AS handle, COUNT(r.id) AS n FROM pico_unit u LEFT JOIN readings r ON r.pico_unit_id = u.id GROUP BY u.handle").all())counts[r.handle]=r.n;db.close();const expected='"$SEED_EXPECTED"';for(const h of want)console.log(h+"="+(counts[h]||0));process.exit(want.every(h=>(counts[h]||0)>=expected)?0:1);'

echo "demo-stack: dashboard will be at http://localhost:${MUSHPI_DEMO_PORT:-3000} once the server is healthy; the five units then announce and seed ${SEED_DAYS} day(s) of history (DEMO_SEED_DAYS=0 skips seeding)."

# ---------------------------------------------------------------------------
# verify_demo_seed — a silently-failing seed must not look like success.
# The mock writes the seed rows itself and nothing else checks them: if the
# seed step dies (SQLite contention with the server, a late announce, a mock
# crash after `up -d` reported the stack started), the dashboard comes up
# with empty charts and the script would exit 0 as if all is well. This polls
# via SEED_JS (above) inside the running mushpi container until all five
# mock-tent-* units hold at least seed_days x 1440 readings (one per minute),
# or ~30s elapse — then fails loudly with the per-unit counts so the script's
# exit code carries the verdict. Runs only on the detached path: the
# foreground path execs compose and never regains control.
verify_demo_seed() {
  if [ "$SEED_DAYS" = "0" ]; then
    echo "demo-stack: DEMO_SEED_DAYS=0 — seeding disabled, seed verification skipped."
    return 0
  fi
  echo "demo-stack: verifying the seed — expecting >= ${SEED_EXPECTED} readings per unit (${SEED_DAYS} day(s) x 1440/min) ..."
  local deadline=$(( $(date +%s) + 30 )) out=''
  while :; do
    if out=$(docker compose -f docker-compose.demo.yml exec -T mushpi node -e "$SEED_JS" 2>&1); then
      echo "demo-stack: seed VERIFIED — every one of the five units carries >= ${SEED_EXPECTED} readings:"
      printf '%s\n' "$out" | sed 's/^/  /'
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      break
    fi
    sleep 2
  done

  echo "demo-stack: SEED VERIFICATION FAILED — expected >= ${SEED_EXPECTED} readings per unit within 30s; last observed (per-unit counts, or the error that replaced them):" >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  echo "demo-stack: the seeder lives in the mock container — inspect it with: docker compose -f docker-compose.demo.yml logs mock" >&2
  echo "demo-stack: a \"database is locked\" line in those logs means the mock and the server contended for SQLite — the server does not enable WAL, so seed writes fail instead of queueing." >&2
  return 1
}

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
  # NOT `exec` — control must return here so verify_demo_seed can run after
  # the stack starts. `up -d` waits for mushpi to be healthy (the mock's
  # depends_on condition) before returning, so the seed has a live server to
  # announce against from the first poll.
  docker compose -f docker-compose.demo.yml up "$@"
  verify_demo_seed
else
  # Foreground: compose owns the terminal from here (exec replaces this
  # shell), so print the verifier's own command — pasteable as-is — for a
  # human to run from another shell once the stack is up. Inner double
  # quotes are shell-escaped so the pasted argument survives parsing.
  if [ "$SEED_DAYS" != "0" ]; then
    echo "demo-stack: foreground mode — once the stack is up, verify the seed from another shell (expect >= ${SEED_EXPECTED} readings per unit; the command exits 0 when seeded):"
    echo "  docker compose -f docker-compose.demo.yml exec -T mushpi node -e \"${SEED_JS//\"/\\\"}\""
  fi
  exec docker compose -f docker-compose.demo.yml up "$@"
fi
