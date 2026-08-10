#!/usr/bin/env bash
# Démarrage manuel de Waydroid (alternative à 'systemctl start waydroid-session'
# si le service systemd n'est pas utilisé).
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY=wayland-1

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
