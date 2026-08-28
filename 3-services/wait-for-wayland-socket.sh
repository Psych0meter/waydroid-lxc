#!/usr/bin/env bash
# Waits for the compositor's Wayland socket: systemd's After=/Requires=
# only orders unit starts, not the socket's asynchronous creation.
set -euo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/waydroid-wayland}"
DISPLAY_NAME="${WAYLAND_DISPLAY:-wayland-1}"
SOCKET_PATH="${RUNTIME_DIR}/${DISPLAY_NAME}"
TIMEOUT_SECONDS=30

for _ in $(seq 1 "${TIMEOUT_SECONDS}"); do
  [[ -S "${SOCKET_PATH}" ]] && exit 0
  sleep 1
done

echo "Error: ${SOCKET_PATH} never appeared after ${TIMEOUT_SECONDS}s." >&2
exit 1
