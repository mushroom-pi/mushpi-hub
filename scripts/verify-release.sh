#!/usr/bin/env bash
# Release consistency check — run before cutting a release tag:
#   ./scripts/verify-release.sh [vX.Y.Z]
# Verifies release.json against the committed component versions. Read-only.
# Requires: bash, git, jq, grep, sed, sort.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

err() { echo "verify-release: $*" >&2; exit 1; }

SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'

[ -f release.json ] || err "release.json not found"

release=$(jq -r .release release.json)
server=$(jq -r .server release.json)
client=$(jq -r .client release.json)
firmware=$(jq -r .firmware release.json)
mock=$(jq -r .mock release.json)
api_version=$(jq -r .api_version release.json)

# 1. shape: five plain SemVer strings + an integer api_version
for v in "$release" "$server" "$client" "$firmware" "$mock"; do
  [[ "$v" =~ $SEMVER ]] || err "invalid version '$v' (want MAJOR.MINOR.PATCH, no suffixes)"
done
[[ "$api_version" =~ ^[1-9][0-9]*$ ]] || err "api_version must be an integer >= 1"

# 2. optional tag must match the manifest's release field
if [ $# -ge 1 ]; then
  tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || err "tag must look like vX.Y.Z (got '$tag')"
  [ "${tag#v}" = "$release" ] || err "tag $tag does not match release.json release '$release'"
fi

# 3. never move a version backward (compare to the previous manifest on main)
if git show main:release.json >/dev/null 2>&1; then
  for f in release server client firmware mock; do
    prev=$(git show main:release.json | jq -r ".$f // empty")
    cur=$(jq -r ".$f" release.json)
    if [ -n "$prev" ] && [ "$prev" != "$cur" ]; then
      lowest=$(printf '%s\n%s\n' "$prev" "$cur" | sort -V | head -n1)
      [ "$lowest" = "$prev" ] || err "$f went backward: $prev -> $cur"
    fi
  done
fi

# 4. the manifest must match what is actually committed in each repo
srv_actual=$(git -C mushpi-server show HEAD:package.json | jq -r .version)
cli_actual=$(git -C mushpi-client show HEAD:package.json | jq -r .version)
fw_actual=$(git -C mushpi-grow show HEAD:app/state.py | grep -oP '_SOFTWARE_VERSION\s*=\s*"\K[^"]+')
mock_actual=$(git -C mushpi-mock show HEAD:src/mushpi_mock/VERSION | tr -d '[:space:]')

[ "$server"   = "$srv_actual" ] || err "release.json server '$server' != committed '$srv_actual'"
[ "$client"   = "$cli_actual" ] || err "release.json client '$client' != committed '$cli_actual'"
[ "$firmware" = "$fw_actual" ]  || err "release.json firmware '$firmware' != committed '$fw_actual'"
# The mock's own version is verified against the manifest's `mock` field, not
# against `firmware`: the mock may lead the firmware version it simulates
# (e.g. mock 0.9.1 impersonating firmware 0.9.0). That divergence is deliberate.
[ "$mock"     = "$mock_actual" ] || err "release.json mock '$mock' != committed '$mock_actual'"

# 5. spec info.version must match the component version
srv_spec=$(git -C mushpi-server show HEAD:spec/openapi.json | jq -r .info.version)
[ "$srv_spec" = "$srv_actual" ] || err "server spec info.version '$srv_spec' != package.json '$srv_actual'"

grow_spec=$(git -C mushpi-grow show HEAD:spec/openapi.yaml \
  | sed -n '/^info:/,/^[^ ]/ s/^  version:[[:space:]]*//p' | tr -d '"[:space:]')
[ "$grow_spec" = "$fw_actual" ] || err "grow spec info.version '$grow_spec' != _SOFTWARE_VERSION '$fw_actual'"

echo "OK — release $release is consistent"
