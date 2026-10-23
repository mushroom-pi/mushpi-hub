#!/usr/bin/env bash
# demo-verify.sh — the demo profile's verification checks, in one place.
#
# Extracted from scripts/demo-stack.sh so that every entry point which needs to
# answer "is this demo stack actually up as designed?" runs the SAME assertions:
#   scripts/demo-stack.sh   — run mode after a detached `up -d`; print mode for
#                             the foreground path's pasteable one-liners
#   scripts/demo-reset.sh   — run mode after the nightly `docker compose restart`
# The checks themselves are unchanged by the move: a rewrite here would silently
# change what both entry points accept as "healthy demo".
#
# Usage (always with the caller's ACTIVE compose file pair — the base plus exactly
# one overlay; the two overlays are mutually exclusive and the base is never run
# alone):
#   scripts/demo-verify.sh -f docker-compose.demo.base.yml -f docker-compose.demo.yml
#   scripts/demo-verify.sh -f docker-compose.demo.base.yml -f docker-compose.demo-local.yml --print
#
# Every argument except --print is passed through to `docker compose` untouched,
# so the exec'd checks and the printed one-liners both talk to the stack that is
# actually running rather than defaulting back to the published file pair.
#
# Modes:
#   run (default)  four read-only assertions, each with its own clearly-labelled
#                  verdict, exiting non-zero on the first failure so the caller's
#                  exit code carries the result:
#                    1. verify_demo_seed     — seeded reading depth (per-unit
#                       data-anchored window), the six-unit roster, and in-progress
#                       batch placement; skipped (not failed) when SEED_ENABLED=false
#                    2. verify_poll_identity — every mocked unit announced and is
#                       being polled; independent of SEED_ENABLED
#                    3. verify_demo_owned    — the server's demo-ownership marker
#                       sits beside the database, which is what authorizes the
#                       clean start to wipe and re-seed this volume on the next boot
#   --print        emit the pasteable verifier one-liners instead of running
#                  anything (no stack needed). The marker assertion is NOT printed:
#                  the foreground guidance is unchanged by the move, and the marker
#                  matters to the automated paths, which run the check themselves.
#
# DEMO_VERIFY_TAG — the prefix on every message, so a caller can keep its own log
# identity (demo-stack.sh passes "demo-stack"; standalone and demo-reset.sh runs
# say "demo-verify"). Default: demo-verify.
#
# All three assertions open the database READ-ONLY through the mushpi container's
# own node + better-sqlite3 (no host-side sqlite3/jq dependency, and `exec -T`
# makes it usable non-interactively). Nothing here mutates demo state.
set -euo pipefail

cd "$(dirname "$0")/.."

TAG="${DEMO_VERIFY_TAG:-demo-verify}"

fail() { echo "$TAG: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# ARGUMENTS — --print selects the pasteable-one-liners mode; everything else is
# the active compose invocation (the -f pair), used verbatim.
PRINT=0
COMPOSE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --print) PRINT=1 ;;
    *) COMPOSE_ARGS+=("$arg") ;;
  esac
done
[ "${#COMPOSE_ARGS[@]}" -gt 0 ] \
  || fail "no compose files given — pass the active demo file pair: $0 -f docker-compose.demo.base.yml -f <docker-compose.demo.yml|docker-compose.demo-local.yml>"
COMPOSE_CMD=(docker compose "${COMPOSE_ARGS[@]}")

# `.env` is OPTIONAL and loaded exactly the way scripts/demo-stack.sh loads it:
# sourced AFTER the ambient environment, so a `.env` line wins over an exported
# one (same precedence the script has always had, and the reason the seed knobs
# below agree with the container's own). Compose reads the same file itself for
# interpolation. Note: .env is SOURCED by bash, so keep values simple.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

# Seed bookkeeping for the checks below. Both defaults mirror the SERVER's
# demo-seeding knobs — the values actually running are the `environment:`
# entries passed to mushpi in docker-compose.demo.base.yml (same variable
# NAMES, so one `.env` line retunes the container and this verifier together
# and the two cannot drift). 1440 = one reading per minute per unit.
# SEED_READINGS_DAYS has a server-side default of 14; compose pins 15 here and
# the demo's depth is expressed by that pin. The server refuses 0 and fractional
# day values at boot, so disabling seeding is SEED_ENABLED=false, never a day
# count of 0. scripts/demo-stack.sh mirrors these two defaults for its own
# informational line — change one, change the other in the same commit.
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
# /data/app.sqlite is the server's SQLITE_PATH in docker-compose.demo.base.yml —
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
# assertion so the script's exit code carries the verdict. Runs only in run
# mode: demo-stack.sh's foreground path execs compose and never regains
# control, so it delegates to --print instead. The announce/poll freshness of
# the mocked units is NOT checked here — it gets its own step
# (verify_poll_identity below).
verify_demo_seed() {
  if [ "$SEED_ENABLED" = "false" ]; then
    echo "$TAG: SEED_ENABLED=false — seeding disabled, seed verification skipped."
    return 0
  fi
  echo "$TAG: verifying the demo seed — expecting exactly ${SEED_EXPECTED} readings per unit (${SEED_READINGS_DAYS} day(s) x 1440/min) inside the window anchored to each unit's own oldest reading, the six-unit seeded roster, and in-progress batches on tent-one … tent-four ..."
  local deadline=$(( $(date +%s) + 30 )) out=''
  while :; do
    if out=$("${COMPOSE_CMD[@]}" exec -T mushpi node -e "$SEED_JS" 2>&1); then
      echo "$TAG: seed VERIFIED — readings seeded, roster and batch placement match the demo profile:"
      printf '%s\n' "$out" | sed 's/^/  /'
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      break
    fi
    sleep 2
  done

  echo "$TAG: SEED VERIFICATION FAILED — expected exactly ${SEED_EXPECTED} readings per unit inside its data-anchored window plus the seeded roster and batch placement within 30s; last observed (per-unit counts, the derived window, roster, batch placement, or the error that replaced them):" >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  echo "$TAG: the seeder is the server itself — inspect it with: ${COMPOSE_CMD[*]} logs mushpi" >&2
  echo "$TAG: a short or absent seed means the server's boot seeding did not complete — look for the \"Demo seeding start — boundary …\" and \"Demo seeding complete\" lines in those logs; if a seed count there falls short of ${SEED_EXPECTED} per unit, or the completion line is missing (or a \"Demo seeding failed\" line replaced it), the boot seeding is the failing component." >&2
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
# first live poll can land up to ~60s after a detached `up` returns — and after
# a `docker compose restart` (scripts/demo-reset.sh) it is measured from the
# server coming back healthy, since a restart wipes and re-seeds the volume and
# the mock re-announces from scratch. Allow ~150s (two poll intervals plus
# slack), retrying every 5s.
verify_poll_identity() {
  echo "$TAG: verifying announce/poll identity — expecting a non-NULL ip and at least one reading newer than the last two poll intervals for each of tent-one … tent-five (tent-six is the offline unit and is not checked; up to ~150s for the first live poll) ..."
  local deadline=$(( $(date +%s) + 150 )) out=''
  while :; do
    if out=$("${COMPOSE_CMD[@]}" exec -T mushpi node -e "$POLL_JS" 2>&1); then
      echo "$TAG: announce/poll identity VERIFIED — every mocked unit announced and is being polled:"
      printf '%s\n' "$out" | sed 's/^/  /'
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      break
    fi
    sleep 5
  done

  echo "$TAG: POLL IDENTITY VERIFICATION FAILED — within ~150s the units marked BAD below never showed a live poll; last observed (per-unit ip and newest reading, the poll horizon, or the error that replaced them):" >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  echo "$TAG: this is an announce/poll failure, NOT a seeding failure — the announced IP/port was not persisted or the poll target is wrong (the poll URL is built from both, so a stale seeded port breaks polling exactly like a wrong ip). Look for \"Pico unit N unreachable (… tent-X.local …)\" lines in: ${COMPOSE_CMD[*]} logs mushpi" >&2
  return 1
}

# ---------------------------------------------------------------------------
# DEMO_OWNED_MARKER_JS — the demo-ownership assertion.
#
# The server's clean start (mushpi-server/src/common/utils/clean-start.ts) runs on
# every NODE_ENV=demo boot, BEFORE TypeORM connects, and it is the only thing that
# returns the demo to a freshly populated state: marker present → the database
# (+ its sidecars) and the image tree are unlinked, then SeedService re-seeds;
# marker absent with data present → the boot REFUSES and fails closed. Nothing in
# this repo deletes anything, so that marker is load-bearing for
# scripts/demo-verify.sh's callers — above all scripts/demo-reset.sh, whose whole
# job is to restart into a wiped-and-re-seeded volume.
#
# Checked INSIDE the mushpi container at the fixed path /data/.demo-owned, because
# that is clean-start's own location — beside the database file SQLITE_PATH names,
# and /data is the demo volume in both image modes. A host-side check would have
# to re-resolve MUSHPI_DEMO_DATA_DIR through the script's .env precedence and
# could drift from where compose actually mounted the volume; the container path
# cannot drift. fs.existsSync only — a read-only check that mutates nothing.
DEMO_OWNED_MARKER_JS='const fs=require("fs");const p="/data/.demo-owned";const ok=fs.existsSync(p);console.log("marker="+p+(ok?" PRESENT":" MISSING"));process.exit(ok?0:1);'

# ---------------------------------------------------------------------------
# verify_demo_owned — an unmarked volume is the one state that turns a nightly
# reset into a downed demo. The marker goes missing only if someone deletes it
# while keeping the database (a hand-cleared data dir removes both, and the next
# boot simply adopts again), so this is a cheap guard against a half-cleaned
# volume rather than a routine diagnosis. It runs AFTER the other two checks:
# a passing seed and poll prove the server booted against this volume, so a
# missing marker here means the volume is not claimable for the NEXT boot — not
# that the container failed to come up. It is deliberately NOT gated by
# SEED_ENABLED: ownership is about wiping, not about seeding depth.
verify_demo_owned() {
  echo "$TAG: verifying the demo-ownership marker — the server's clean start only wipes and re-seeds a volume carrying /data/.demo-owned, so this is what makes the next reset come back fresh ..."
  local out=''
  if ! out=$("${COMPOSE_CMD[@]}" exec -T mushpi node -e "$DEMO_OWNED_MARKER_JS" 2>&1); then
    echo "$TAG: DEMO-OWNERSHIP VERIFICATION FAILED — the marker check did not pass. Last observed (or the error that replaced it):" >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    echo "$TAG: the marker lives beside the database in the demo volume — inspect it with: ${COMPOSE_CMD[*]} exec mushpi ls -la /data" >&2
    return 1
  fi
  echo "$TAG: demo-ownership marker VERIFIED — this volume is demo-owned, so a clean start wipes and re-seeds it on every boot:"
  printf '%s\n' "$out" | sed 's/^/  /'
  return 0
}

# ---------------------------------------------------------------------------
# --print: the foreground path of scripts/demo-stack.sh cannot verify (it execs
# compose and hands the terminal to the operator), so it delegates here for the
# same pasteable one-liners it printed before the move. Inner double quotes are
# shell-escaped so the pasted argument survives parsing, and the JS stays "!"-free
# for the same reason: a `!` inside a double-quoted pasted command fires interactive
# history expansion in the operator's shell.
if [ "$PRINT" = 1 ]; then
  if [ "$SEED_ENABLED" != "false" ]; then
    echo "$TAG: foreground mode — once the stack is up, verify the demo profile from another shell (expect exactly ${SEED_EXPECTED} readings per unit inside the window anchored to each unit's own oldest reading, the six-unit seeded roster, and in-progress batches on tent-one … tent-four; the command exits 0 when all three hold):"
    echo "  ${COMPOSE_CMD[*]} exec -T mushpi node -e \"${SEED_JS//\"/\\\"}\""
  fi
  echo "$TAG: then verify announce/poll identity from another shell (exits 0 when every mocked unit carries a non-NULL ip and at least one reading from the last two poll intervals; independent of SEED_ENABLED):"
  echo "  ${COMPOSE_CMD[*]} exec -T mushpi node -e \"${POLL_JS//\"/\\\"}\""
  exit 0
fi

# Run mode. Order is a diagnosis decision, not a dependency: the seed verdict
# first (the server's own boot work), then announce/poll (the mock's), then the
# ownership marker — which only means anything once the server is known to have
# booted against this volume.
verify_demo_seed
verify_poll_identity
verify_demo_owned
