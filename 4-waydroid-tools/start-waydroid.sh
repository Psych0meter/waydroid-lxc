#!/usr/bin/env bash
# Manual Waydroid startup, as an alternative to
# 'systemctl start waydroid-session'.
set -euo pipefail
export XDG_RUNTIME_DIR=/run/waydroid-wayland
export WAYLAND_DISPLAY=wayland-1
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/waydroid-dbus/session"

if command -v /usr/local/bin/ensure-waydroid-dbus.sh >/dev/null 2>&1; then
  /usr/local/bin/ensure-waydroid-dbus.sh
else
  echo "Warning: /usr/local/bin/ensure-waydroid-dbus.sh not found (did 02-install-services.sh run?)." >&2
fi

echo "Starting Waydroid session..."
waydroid session start &
SESSION_PID=$!

for _ in $(seq 1 30); do
  if waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    break
  fi
  sleep 1
done

echo "Showing Waydroid UI..."
waydroid show-full-ui &

echo "Waydroid triggered (session PID ${SESSION_PID}). Check your noVNC web interface."
