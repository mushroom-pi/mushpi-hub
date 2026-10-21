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
# .demo-mock-config.json for the mock container (five units on the
# server-seeded handles tent-one … tent-five), ensures the demo data
# directory exists, then brings the stack up with
# `docker compose -f docker-compose.demo.yml up "$@"`. On the detached path
# (`-d`) it additionally verifies the demo profile actually came up as designed
# (verify_demo_seed — seeded reading depth inside a window anchored to each
# unit's own data, the six-unit roster, and batch placement — then
# verify_poll_identity, that every mocked unit announced and is being polled)
# before reporting success.
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
# The handles are the server-seeded demo roster (tent-one … tent-five), NOT a
# mock-namespaced set: announcing an already-seeded handle makes the server's
# upsert-by-handle land on that unit, so the mock drives the roster the
# dashboard shows instead of adding a parallel row per unit. `tent-six` is
# deliberately absent — it is the roster's offline unit, and a mock that
# announced it would make it reachable.
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

# Seed bookkeeping shared by the verifier and the foreground guidance. Both
# values are the SERVER's demo-seeding knobs (the mock does not seed): the
# defaults mirror the `environment:` entries passed to mushpi in
# docker-compose.demo.yml — same variable NAMES, so one `.env` line retunes the
# container and the verifier together and the two cannot drift. 1440 = one
# reading per minute per unit. SEED_READINGS_DAYS has a server-side default of
# 14; compose pins 15 here and the demo's depth is expressed by that pin. The
# server refuses 0 and fractional day values at boot, so disabling seeding is
# SEED_ENABLED=false, never a day count of 0.
SEED_ENABLED="${SEED_ENABLED:-true}"
SEED_READINGS_DAYS="${SEED_READINGS_DAYS:-15}"
SEED_EXPECTED=$(( SEED_READINGS_DAYS * 1440 ))

# The verification query as ONE js line, run by the mushpi container's own node
# against the image's own better-sqlite3 — no host-side sqlite3/jq dependency
# (`exec -T` makes it usable non-interactively). Identifiers (pico_unit,
# readings, batch, pico_unit_id, handle, start_at, finish_at) are confirmed
# against the server entities, its InitSchema migration, and an empirically
# synchronized database. The DB opens READ-ONLY ({readonly:true}): a verifier
# must never mutate demo state, and a missing file simply throws — the retry
# loop treats a failed exec as "not ready yet". node applies the thresholds
# itself and exits 0/1, so bash only decides "still polling" vs "done".
# /data/app.sqlite is the server's SQLITE_PATH in docker-compose.demo.yml —
# keep the two in sync.
#
# Three assertions, all read-only, all against the server-seeded demo roster:
#   1. seed depth — every mocked handle (tent-one … tent-five) holds EXACTLY
#      seed_readings_days x 1440 readings *inside a window anchored to that
#      unit's own data*: lo = MIN(ts) for the handle, hi = lo + (expected-1)
#      minutes, inclusive at both ends, and COUNT inside [lo, hi] must equal
#      `expected`. The window is what makes an exact count usable at all — a
#      whole-table equality would flake on the 60s poll's later rows, which
#      sit strictly beyond hi (live poll rows are always later than the seed
#      start, and the seeded grid ends at the server's boot-frozen boundary,
#      so lo is the seed's own first row and hi is its last). The window is
#      NEVER derived from Date.now(): an earlier version recomputed a
#      wall-clock cutoff each attempt, and once the verifier ran in a LATER
#      minute than the seed boundary the window slid forward 60s, dropped the
#      oldest seeded row, and reported expected-1 for every unit — a healthy
#      seed flagged FAILED. A handle with no rows at all is an explicit
#      failure naming that handle (the seeding phase that never wrote it).
#   2. roster — pico_unit holds EXACTLY the six seeded handles. This is what
#      catches a mock announcing a handle the server never seeded (a rename
#      that only moved one side of the contract shows up here as a seventh
#      row, not as a missing one); a doubled reading history is what assertion
#      1's exact count catches, since overlay rows land inside the same window.
#   3. batch placement — in-progress batches sit on exactly the four live
#      units the demo seeds them on (tent-five's batch is planned, tent-six
#      gets none), so the dashboard's unit cards and batch views agree with
#      the roster.
# Batch "in progress" mirrors Batch.status: null-or-future finish_at with a
# start_at already past. TypeORM's SQLite driver writes datetimes as UTC
# `YYYY-MM-DD HH:MM:SS.mmm` (DateUtils.mixedDateToUtcDatetimeString), a fixed
# width string, so lexicographic comparison against the same shape is exact —
# no julianday() parsing or timezone interpretation needed.
SEED_JS='const Database=require("better-sqlite3");const db=new Database("/data/app.sqlite",{readonly:true});const want=["tent-one","tent-two","tent-three","tent-four","tent-five"];const roster=want.concat(["tent-six"]);const live=["tent-one","tent-two","tent-three","tent-four"];const slotMs=60000;const expected=Number('"$SEED_EXPECTED"');const fmt=d=>d.toISOString().replace("T"," ").slice(0,23);const parseTs=s=>new Date(s.replace(" ","T")+"Z").getTime();const nowStr=fmt(new Date());const handles=db.prepare("SELECT handle AS handle FROM pico_unit").all().map(r=>r.handle);const loStmt=db.prepare("SELECT MIN(r.ts) AS lo FROM readings r JOIN pico_unit u ON u.id = r.pico_unit_id WHERE u.handle = ?");const seedStmt=db.prepare("SELECT COUNT(r.id) AS n FROM readings r JOIN pico_unit u ON u.id = r.pico_unit_id WHERE u.handle = ? AND r.ts >= ? AND r.ts <= ?");const seeded={};const windows={};const empty=[];for(const h of want){const row=loStmt.get(h);if(row.lo===null){seeded[h]=null;empty.push(h);continue;}const lo=row.lo;const hi=fmt(new Date(parseTs(lo)+(expected-1)*slotMs));windows[h]=lo+".."+hi;seeded[h]=seedStmt.get(h,lo,hi).n;}const batched=db.prepare("SELECT DISTINCT u.handle AS handle FROM batch b JOIN pico_unit u ON u.id = b.pico_unit_id WHERE b.start_at <= ? AND (b.finish_at IS NULL OR b.finish_at > ?)").all(nowStr,nowStr).map(r=>r.handle);db.close();const seedOk=empty.length===0&&want.every(h=>seeded[h]===expected);const rosterOk=handles.length===roster.length&&roster.every(h=>handles.indexOf(h)>=0);const batchOk=batched.length===live.length&&live.every(h=>batched.indexOf(h)>=0)&&batched.indexOf("tent-six")<0;for(const h of want)console.log(h+"="+seeded[h]);const uniq=Array.from(new Set(want.filter(h=>windows[h]).map(h=>windows[h])));if(uniq.length===1)console.log("window="+uniq[0]);else for(const h of want)if(windows[h])console.log("window["+h+"]="+windows[h]);console.log("roster="+handles.sort().join(","));console.log("in-progress-batches="+batched.sort().join(","));if(seedOk===false){if(empty.length>0)console.log("FAILED seed: no readings at all for "+empty.join(", ")+" — the boot seeding never wrote rows for that unit");console.log("FAILED seed: expected exactly "+expected+" seeded readings per unit inside its data-anchored window (lo = the oldest reading of that unit, hi = lo + the (expected-1)-minute span; rows beyond hi belong to the live poll, not to seeding)");}if(rosterOk===false)console.log("FAILED roster: pico_unit must hold exactly "+roster.join(", ")+" but holds "+handles.sort().join(", ")+" — leftover rows from an older demo profile are not removed by an upsert, so wipe the demo data directory (down, then delete the disposable MUSHPI_DEMO_DATA_DIR) for a clean roster");if(batchOk===false)console.log("FAILED batch placement: expected in-progress batches on exactly "+live.join(", ")+" (tent-five is planned-only, tent-six has none) but found "+batched.sort().join(","));process.exit(seedOk&&rosterOk&&batchOk?0:1);'

# ---------------------------------------------------------------------------
# POLL_JS — the announce/poll identity assertion, run as its OWN verification
# step (verify_poll_identity) after the seed check, deliberately NOT folded
# into SEED_JS: a failed seed and a unit that never polled are different
# problems for the operator, and the two failure messages must stay tellable
# apart. For every mocked handle (tent-one … tent-five — never tent-six, the
# roster's intentionally-offline unit) the pico_unit row must carry a non-NULL
# ip AND at least one reading newer than now-150s (two 60s poll intervals plus
# slack; freshness is legitimately wall-clock — only the SEED window had to
# stop being clock-derived). End-to-end on purpose: the announce persists ip
# and port, then the server's 60s cron poll must actually REACH that ip:port
# to write the reading. A stale port on the row breaks polling exactly like a
# wrong ip would — the poll target is built from both — so the freshness of a
# live reading is the only reliable signal that the whole chain worked.
# Identifiers (ip) confirmed against pico-unit.entity.ts and the live demo
# database. Same read-only better-sqlite3 path; same "!"-free rule (this JS is
# also printed as a pasteable double-quoted one-liner on the foreground path).
POLL_JS='const Database=require("better-sqlite3");const db=new Database("/data/app.sqlite",{readonly:true});const want=["tent-one","tent-two","tent-three","tent-four","tent-five"];const pollMs=60000;const fmt=d=>d.toISOString().replace("T"," ").slice(0,23);const horizon=fmt(new Date(Date.now()-2*pollMs-30000));const stmt=db.prepare("SELECT u.ip AS ip, (SELECT MAX(r.ts) FROM readings r WHERE r.pico_unit_id = u.id) AS last FROM pico_unit u WHERE u.handle = ?");const bad=[];for(const h of want){const row=stmt.get(h);const ip=row===undefined||row.ip===null?"":String(row.ip);const last=row===undefined||row.last===null?"":String(row.last);const ok=ip.length>0&&last.length>0&&last>horizon;if(ok===false)bad.push(h);console.log(h+"=ip:"+ip+" last:"+last+(ok?"":" BAD"));}db.close();console.log("poll-horizon="+horizon);if(bad.length>0)console.log("FAILED poll: unit never polled — "+bad.join(", ")+" — needs a non-NULL ip on the pico_unit row and at least one reading beyond the poll horizon (live rows land from the server cron poll; this is an announce/poll problem, not a seeding problem)");process.exit(bad.length===0?0:1);'

echo "demo-stack: dashboard will be at http://localhost:${MUSHPI_DEMO_PORT:-3000} once the server is healthy; the SERVER seeds ${SEED_READINGS_DAYS} day(s) of history for the live roster on boot (SEED_ENABLED=false disables seeding), and the five units (tent-one … tent-five) announce onto it."

# ---------------------------------------------------------------------------
# verify_demo_seed — a silently-failing seed must not look like success.
# The server seeds the demo history itself during boot (SeedService, insert-
# only) and nothing else checks that it landed: if seeding comes up short —
# a profile misconfiguration, a boot-time seed failure swallowed by the
# server's try/catch, or a volume left over from an older demo roster — the
# dashboard comes up with empty or wrong charts and the script would exit
# 0 as if all is well. This polls via SEED_JS (above) inside the running
# mushpi container until the three demo-profile assertions hold — every
# mocked handle (tent-one … tent-five) carries EXACTLY SEED_READINGS_DAYS x
# 1440 readings (one per minute) inside the window anchored to that unit's
# OWN data (lo = MIN(ts) for the handle, hi = lo + (expected-1) minutes,
# inclusive at both ends — never derived from the wall clock, so a verifier
# running in a later minute than the seed boundary counts the same rows),
# the pico_unit roster is exactly the six seeded handles, and in-progress
# batches sit on the four live units the demo seeds them on — or ~30s
# elapse; then fails loudly with the per-unit counts and the failed
# assertion so the script's exit code carries the verdict. Runs only on the
# detached path: the foreground path execs compose and never regains
# control. The announce/poll freshness of the mocked units is NOT checked
# here — it gets its own step (verify_poll_identity below).
verify_demo_seed() {
  if [ "$SEED_ENABLED" = "false" ]; then
    echo "demo-stack: SEED_ENABLED=false — seeding disabled, seed verification skipped."
    return 0
  fi
  echo "demo-stack: verifying the demo seed — expecting exactly ${SEED_EXPECTED} readings per unit (${SEED_READINGS_DAYS} day(s) x 1440/min) inside the window anchored to each unit's own oldest reading, the six-unit seeded roster, and in-progress batches on tent-one … tent-four ..."
  local deadline=$(( $(date +%s) + 30 )) out=''
  while :; do
    if out=$(docker compose -f docker-compose.demo.yml exec -T mushpi node -e "$SEED_JS" 2>&1); then
      echo "demo-stack: seed VERIFIED — readings seeded, roster and batch placement match the demo profile:"
      printf '%s\n' "$out" | sed 's/^/  /'
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      break
    fi
    sleep 2
  done

  echo "demo-stack: SEED VERIFICATION FAILED — expected exactly ${SEED_EXPECTED} readings per unit inside its data-anchored window plus the seeded roster and batch placement within 30s; last observed (per-unit counts, the derived window, roster, batch placement, or the error that replaced them):" >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  echo "demo-stack: the seeder is the server itself — inspect it with: docker compose -f docker-compose.demo.yml logs mushpi" >&2
  echo "demo-stack: a short or absent seed means the server's boot seeding did not complete — look for the \"Demo seeding start — boundary …\" and \"Demo seeding complete\" lines in those logs; if a seed count there falls short of ${SEED_EXPECTED} per unit, or the completion line is missing (or a \"Demo seeding failed\" line replaced it), the boot seeding is the failing component." >&2
  return 1
}

# ---------------------------------------------------------------------------
# verify_poll_identity — a full seeded history proves the server booted and
# seeded; it does NOT prove the mocked units are actually online. A unit whose
# announce never persisted (ip still NULL) or whose poll target is unreachable
# still shows a complete chart, because SEED_JS's data-anchored window
# deliberately excludes the live rows — only the live tail would be missing,
# and nothing else looks at it. So freshness gets its own assertion (POLL_JS,
# above) and its own clearly-labelled verdict, kept OUT of the seed check on
# purpose: "the seed is short" and "the unit never polled" are different
# operator problems and the two messages must stay tellable apart. This is a
# genuinely wall-clock question (is the newest reading recent?), so unlike the
# seed window it uses the current time. Runs REGARDLESS of SEED_ENABLED —
# announce/poll identity does not depend on seeding. Timing: the cron polls
# every 60s (EVERY_MINUTE) and the stack can come up between ticks, so the
# first live poll can land up to ~60s after a detached `up` returns; allow
# ~150s (two poll intervals plus slack), retrying every 5s.
verify_poll_identity() {
  echo "demo-stack: verifying announce/poll identity — expecting a non-NULL ip and at least one reading newer than the last two poll intervals for each of tent-one … tent-five (tent-six is the offline unit and is not checked; up to ~150s for the first live poll) ..."
  local deadline=$(( $(date +%s) + 150 )) out=''
  while :; do
    if out=$(docker compose -f docker-compose.demo.yml exec -T mushpi node -e "$POLL_JS" 2>&1); then
      echo "demo-stack: announce/poll identity VERIFIED — every mocked unit announced and is being polled:"
      printf '%s\n' "$out" | sed 's/^/  /'
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      break
    fi
    sleep 5
  done

  echo "demo-stack: POLL IDENTITY VERIFICATION FAILED — within ~150s the units marked BAD below never showed a live poll; last observed (per-unit ip and newest reading, the poll horizon, or the error that replaced them):" >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  echo "demo-stack: this is an announce/poll failure, NOT a seeding failure — the announced IP/port was not persisted or the poll target is wrong (the poll URL is built from both, so a stale seeded port breaks polling exactly like a wrong ip). Look for \"Pico unit N unreachable (… tent-X.local …)\" lines in: docker compose -f docker-compose.demo.yml logs mushpi" >&2
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
  # NOT `exec` — control must return here so verify_demo_seed and
  # verify_poll_identity can run after the stack starts. `up -d` waits for
  # mushpi to be healthy (the mock's depends_on condition) before returning,
  # so the seed has a live server to announce against from the first poll.
  docker compose -f docker-compose.demo.yml up "$@"
  verify_demo_seed
  verify_poll_identity
else
  # Foreground: compose owns the terminal from here (exec replaces this
  # shell), so print the verifier's own command — pasteable as-is — for a
  # human to run from another shell once the stack is up. Inner double
  # quotes are shell-escaped so the pasted argument survives parsing.
  if [ "$SEED_ENABLED" != "false" ]; then
    echo "demo-stack: foreground mode — once the stack is up, verify the demo profile from another shell (expect exactly ${SEED_EXPECTED} readings per unit inside the window anchored to each unit's own oldest reading, the six-unit seeded roster, and in-progress batches on tent-one … tent-four; the command exits 0 when all three hold):"
    echo "  docker compose -f docker-compose.demo.yml exec -T mushpi node -e \"${SEED_JS//\"/\\\"}\""
  fi
  echo "demo-stack: then verify announce/poll identity from another shell (exits 0 when every mocked unit carries a non-NULL ip and at least one reading from the last two poll intervals; independent of SEED_ENABLED):"
  echo "  docker compose -f docker-compose.demo.yml exec -T mushpi node -e \"${POLL_JS//\"/\\\"}\""
  exec docker compose -f docker-compose.demo.yml up "$@"
fi
