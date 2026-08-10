#!/usr/bin/env bash
# Attend que le socket Wayland créé par Weston existe avant de démarrer
# un client (wayvnc). systemd 'After=/Requires=' garantit seulement l'ordre
# de démarrage des UNITÉS, pas que le socket Wayland soit déjà présent sur
# le disque (Weston le crée de façon asynchrone) — d'où cette attente active,
# qui remplace le "sleep 2" manuel utilisé dans les instructions d'origine.
set -euo pipefail

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}"
DISPLAY_NAME="${WAYLAND_DISPLAY:-wayland-1}"
SOCKET_PATH="${RUNTIME_DIR}/${DISPLAY_NAME}"
TIMEOUT_SECONDS=30

for _ in $(seq 1 "${TIMEOUT_SECONDS}"); do
  [[ -S "${SOCKET_PATH}" ]] && exit 0
  sleep 1
done

echo "Timeout: ${SOCKET_PATH} n'est jamais apparu après ${TIMEOUT_SECONDS}s." >&2
exit 1
