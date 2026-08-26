#!/usr/bin/env bash
# Makes sure a session D-Bus is available for Waydroid.
#
# Waydroid's Python client needs a valid DBUS_SESSION_BUS_ADDRESS. A systemd
# service without 'User=' (so no login session) doesn't have one by default,
# and dbus-python's auto-launch attempt fails with "Unable to autolaunch a
# dbus-daemon without a $DISPLAY for X11". This starts a dedicated
# 'dbus-daemon --session' at a fixed address, reused across service restarts
# as long as it's still responding.
set -euo pipefail

SOCK_DIR="/run/waydroid-dbus"
SOCK_PATH="${SOCK_DIR}/session"
ADDR="unix:path=${SOCK_PATH}"

mkdir -p "${SOCK_DIR}"

if [[ -S "${SOCK_PATH}" ]] && dbus-send --address="${ADDR}" --print-reply \
    --dest=org.freedesktop.DBus / org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
  exit 0
fi

rm -f "${SOCK_PATH}"
dbus-daemon --session --fork --address="${ADDR}"

for _ in $(seq 1 20); do
  [[ -S "${SOCK_PATH}" ]] && exit 0
  sleep 0.5
done

echo "Timeout: dbus-daemon never created ${SOCK_PATH}" >&2
exit 1
