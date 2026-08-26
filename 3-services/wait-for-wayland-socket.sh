#!/usr/bin/env bash
# Waits for the Wayland socket created by the compositor (Sway) to exist
# before starting a client (wayvnc). systemd's 'After=/Requires=' only
# guarantees UNIT start order, not that the Wayland socket already exists on
# disk (the compositor creates it asynchronously) - hence this active wait,
# replacing the manual "sleep 2" from the original instructions.
set -euo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/waydroid-wayland}"
DISPLAY_NAME="${WAYLAND_DISPLAY:-wayland-1}"
SOCKET_PATH="${RUNTIME_DIR}/${DISPLAY_NAME}"
TIMEOUT_SECONDS=30

for _ in $(seq 1 "${TIMEOUT_SECONDS}"); do
  [[ -S "${SOCKET_PATH}" ]] && exit 0
  sleep 1
done

echo "Timeout: ${SOCKET_PATH} never appeared after ${TIMEOUT_SECONDS}s." >&2
exit 1
