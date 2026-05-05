#!/usr/bin/env bash
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY=wayland-1

echo "Starting Waydroid session..."
waydroid session start &
sleep 3

echo "Showing Waydroid UI..."
waydroid show-full-ui &

echo "Waydroid triggered. Check your noVNC web interface."
