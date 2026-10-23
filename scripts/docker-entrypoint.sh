#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT=/data
UID_NOW=$(id -u)
GID_NOW=$(id -g)
APP_USER=node
APP_GROUP=node
APP_UID=1000
APP_GID=1000
SETPRIV=/usr/bin/setpriv
AVAHI_USER=avahi
AVAHI_BIN_NAME=avahi-daemon
AVAHI_RUNTIME_DIR=/run/avahi-daemon

fail() {
  echo "ERROR: $1" >&2
  shift
  for line in "$@"; do
    echo "$line" >&2
  done
  exit 1
}

remedy_nonroot() {
  echo "Fix it on the HOST, then restart the container:" >&2
  echo "    sudo chown -R ${UID_NOW}:${GID_NOW} <MUSHPI_HUB_DATA_DIR>" >&2
  echo "(The host directory is whatever MUSHPI_HUB_DATA_DIR points at, default ./mushpi-data" >&2
  echo "beside the compose file. The Docker daemon creates a missing bind-mount source" >&2
  echo "directory as root, which this container cannot write into.)" >&2
}

ensure_dirs_writable_nonroot() {
  for subdir in "$DATA_ROOT" "$DATA_ROOT/images" "$DATA_ROOT/logs"; do
    if ! mkdir -p "$subdir" 2>/dev/null; then
      echo "ERROR: cannot create $subdir — $DATA_ROOT is not writable by UID $UID_NOW." >&2
      remedy_nonroot
      exit 1
    fi
  done

  if [ ! -w "$DATA_ROOT" ]; then
    echo "ERROR: $DATA_ROOT is not writable by UID $UID_NOW." >&2
    remedy_nonroot
    exit 1
  fi
}

warn() {
  echo "WARNING: $1" >&2
  shift
  for line in "$@"; do
    echo "$line" >&2
  done
}

# Start the container's own query-only mDNS resolver (config baked in the
# Dockerfile) so the server can reach units at http://<handle>.local:<port>
# without depending on the host's resolver. Requires network_mode: host, which
# is what lets its multicast reach the LAN (docker-compose.yml).
#
# NEVER fatal: the worst this can cost is `.local` resolution, and the
# announced-IP fallback carries the 60s polls. Nothing supervises the daemon —
# if it dies after start, resolution stops until the container restarts.
start_mdns_resolver() {
  local avahi_bin

  # Root only: it must create the daemon's runtime dir, and chowning that dir
  # to `avahi` is the only way the unprivileged `node` server can reach the
  # resolver socket afterwards.
  if ! id "$AVAHI_USER" >/dev/null 2>&1; then
    warn "mDNS resolver not started: user '${AVAHI_USER}' is missing." \
         "The image may be a custom build without avahi-daemon." \
         ".local unit names will not resolve; the announced-IP fallback carries the polls."
    return 0
  fi

  avahi_bin=$(command -v "$AVAHI_BIN_NAME" 2>/dev/null || true)
  [ -n "$avahi_bin" ] || avahi_bin=/usr/sbin/avahi-daemon
  if [ ! -x "$avahi_bin" ]; then
    warn "mDNS resolver not started: ${AVAHI_BIN_NAME} binary not found." \
         "The image may be a custom build without avahi-daemon." \
         ".local unit names will not resolve; the announced-IP fallback carries the polls."
    return 0
  fi

  # /run is a fresh tmpfs each boot, so the daemon's socket directory is created
  # here every start. Owned by `avahi` (what the package creates), world
  # readable/traversable so the socket inside is reachable after the setpriv drop.
  if ! mkdir -p "$AVAHI_RUNTIME_DIR" \
     || ! chown "${AVAHI_USER}:${AVAHI_USER}" "$AVAHI_RUNTIME_DIR" \
     || ! chmod 0755 "$AVAHI_RUNTIME_DIR"; then
    warn "mDNS resolver not started: cannot prepare ${AVAHI_RUNTIME_DIR}." \
         ".local unit names will not resolve; the announced-IP fallback carries the polls."
    return 0
  fi

  # --daemonize double-forks; dumb-init (PID 1) reaps it. --no-chroot skips the
  # daemon's default chroot of /var/run/avahi-daemon, which buys nothing in a
  # container and is a known friction point. avahi reports daemon-startup failure
  # through the exit code, and the socket check confirms it is really listening.
  if ! "$avahi_bin" --daemonize --no-chroot \
     || [ ! -S "${AVAHI_RUNTIME_DIR}/socket" ]; then
    warn "mDNS resolver failed to start — .local unit names will not resolve." \
         "This is not fatal: the server boots normally and the announced-IP fallback" \
         "carries the polls. A likely cause is a conflict binding UDP 5353, which is" \
         "possible under network_mode: host when the host runs its own mDNS responder."
    return 0
  fi

  echo "Started the container's query-only mDNS resolver (.local unit names resolve)." >&2
}

if [ "$UID_NOW" -eq 0 ]; then
  for subdir in "$DATA_ROOT" "$DATA_ROOT/images" "$DATA_ROOT/logs"; do
    if ! mkdir -p "$subdir"; then
      fail "cannot create $subdir as root." \
           "The bind-mounted filesystem may be read-only or the path may be invalid."
    fi

    if [ "$(stat -c '%u:%g' "$subdir")" != "${APP_UID}:${APP_GID}" ]; then
      if ! chown -R "${APP_USER}:${APP_GROUP}" "$subdir"; then
        fail "cannot chown $subdir to ${APP_USER}:${APP_GROUP}." \
             "This usually means the filesystem maps root to an unprivileged user" \
             "(NFS root_squash) or does not allow chown. Pre-create the directory" \
             "on the host as UID ${APP_UID} / GID ${APP_GID} and restart:" \
             "    sudo mkdir -p <MUSHPI_HUB_DATA_DIR>" \
             "    sudo chown -R ${APP_UID}:${APP_GID} <MUSHPI_HUB_DATA_DIR>"
      fi
    fi
  done

  if ! "$SETPRIV" --reuid="$APP_USER" --regid="$APP_GROUP" --clear-groups -- test -w "$DATA_ROOT"; then
    fail "$DATA_ROOT is not writable by ${APP_USER} (UID ${APP_UID})." \
         "The directory could not be made writable for the application user." \
         "Pre-create it on the host as UID ${APP_UID} / GID ${APP_GID} and restart:" \
         "    sudo mkdir -p <MUSHPI_HUB_DATA_DIR>" \
         "    sudo chown -R ${APP_UID}:${APP_GID} <MUSHPI_HUB_DATA_DIR>"
  fi

  # After the /data ownership work (so a repair failure still exits 1), before
  # the privilege drop (the daemon needs root to bind multicast and own its
  # runtime dir). Never fatal — see start_mdns_resolver().
  start_mdns_resolver

  exec "$SETPRIV" --reuid="$APP_USER" --regid="$APP_GROUP" --clear-groups -- "$@"
else
  ensure_dirs_writable_nonroot
  echo "mDNS resolver skipped: the container is not running as root" >&2
  echo "(started with --user?). .local unit names will not resolve inside it;" >&2
  echo "the announced-IP fallback carries the polls. Run without --user on a" >&2
  echo "network_mode: host deployment to get in-container .local resolution." >&2
  exec "$@"
fi
