#!/usr/bin/env bash
# Starts a dedicated session D-Bus for Waydroid: a systemd service without
# 'User=' has no session bus by default, and Waydroid's dbus-python client
# fails to auto-launch one without a $DISPLAY. Reused across restarts as
# long as it still responds.
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

echo "Error: dbus-daemon never created ${SOCK_PATH}" >&2
exit 1
