#!/usr/bin/env bash
# demo-stack-local.sh — the demo stack's LOCAL BUILD entry point: one command
# builds mushpi:demo-local and mushpi-mock:demo-local on this machine from the
# developer's own working copies of mushpi-server, mushpi-client and mushpi-mock
# (uncommitted changes included) and runs the stack on http://localhost:3000.
#
# It is a thin wrapper: it checks the sibling layout, then hands everything to
# demo-stack.sh with MUSHPI_DEMO_LOCAL=1, which selects
# docker-compose.demo.base.yml + docker-compose.demo-local.yml instead of the
# published overlay. Secret resolution, mock-config generation, `up` and both
# verification passes are demo-stack.sh's — nothing here duplicates them, so the
# local and published modes cannot drift apart.
#
# No CI run and no registry are involved: nothing is pushed, and nothing is
# pulled. The images are local-only tags (unqualified names, so they resolve to
# no registry at all), and `up` reuses an existing tag without rebuilding —
# pass --build (or run `docker compose … build` first) to pick up edits to a
# working copy.
#
# Layout it requires: this repo sits directly beside the sub-repos it builds
# from, because the build context is the directory holding mushpi-ops:
#   <parent>/mushpi-ops   <parent>/mushpi-server   <parent>/mushpi-client
#   <parent>/mushpi-mock
#
# Usage: scripts/demo-stack-local.sh [-d] [extra docker compose up args…]
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"

# Fail fast, before generating any config, and name what is missing: a parent
# context with no sibling to build from is a confusing compose/COPY error deep
# in a build, not a readable one here.
cd "$dir/.."
missing=()
for repo in mushpi-server mushpi-client mushpi-mock; do
  [ -d "../$repo" ] || missing+=("../$repo")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "demo-stack-local: missing sibling working copies: ${missing[*]}" >&2
  echo "demo-stack-local: the local build reads these three as the Docker build inputs, so mushpi-ops must sit in the same directory as them (a clone of each is enough). Running the PUBLISHED demo needs none of them: scripts/demo-stack.sh." >&2
  exit 1
fi

MUSHPI_DEMO_LOCAL=1 exec "$dir/demo-stack.sh" "$@"
