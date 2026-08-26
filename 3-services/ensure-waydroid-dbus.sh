#!/usr/bin/env bash
# Garantit qu'un bus D-Bus de session est disponible pour Waydroid.
#
# Waydroid (côté client Python) a besoin d'un DBUS_SESSION_BUS_ADDRESS
# valide. Un service systemd sans 'User=' (donc sans session de login) n'en
# a pas par défaut, et la tentative d'auto-launch de dbus-python échoue avec
# "Unable to autolaunch a dbus-daemon without a $DISPLAY for X11". On
# démarre donc ici un dbus-daemon --session dédié, à adresse fixe, réutilisé
# entre redémarrages du service tant qu'il répond.
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

echo "Timeout: dbus-daemon n'a jamais créé ${SOCK_PATH}" >&2
exit 1
