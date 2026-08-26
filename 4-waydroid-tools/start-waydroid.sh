#!/usr/bin/env bash
# Démarrage manuel de Waydroid (alternative à 'systemctl start waydroid-session'
# si le service systemd n'est pas utilisé).
set -euo pipefail
export XDG_RUNTIME_DIR=/run/waydroid-wayland
export WAYLAND_DISPLAY=wayland-1
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/waydroid-dbus/session"

if command -v /usr/local/bin/ensure-waydroid-dbus.sh >/dev/null 2>&1; then
  /usr/local/bin/ensure-waydroid-dbus.sh
else
  echo "Attention: /usr/local/bin/ensure-waydroid-dbus.sh introuvable (02-install-services.sh a-t-il été exécuté ?)." >&2
  echo "Sans bus D-Bus de session, 'waydroid session start' échouera avec une erreur d'autolaunch." >&2
fi

echo "Starting Waydroid session..."
waydroid session start &
SESSION_PID=$!

# 'waydroid session start' tourne en premier plan tant que la session vit ;
# on attend qu'il ait fini son initialisation (waydroid status == RUNNING)
# plutôt qu'un délai fixe.
for _ in $(seq 1 30); do
  if waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    break
  fi
  sleep 1
done

echo "Showing Waydroid UI..."
waydroid show-full-ui &

echo "Waydroid triggered (session PID ${SESSION_PID}). Check your noVNC web interface."
