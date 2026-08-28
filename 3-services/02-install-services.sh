#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Installs the headless Sway compositor Waydroid renders through (required
# - Android's SurfaceFlinger renders via Wayland/DMA-BUF, so Waydroid needs
# *some* compositor present even though nothing ever displays its output
# directly) and the waydroid-session auto-start unit. Screen viewing/control
# is the webapp's job now (5-webapp/, over adb - see its README "Screen:
# remote control"), not a service installed here - this script has no
# network-facing component and therefore no exposure setting of its own.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root inside the container." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Installing Sway headless config..."
mkdir -p /etc/sway
cp "${REPO_ROOT}/2-lxc-setup/sway-headless-config" /etc/sway/config-headless

echo "Installing helper scripts..."
install -m 0755 "${SCRIPT_DIR}/wait-for-wayland-socket.sh" /usr/local/bin/wait-for-wayland-socket.sh
install -m 0755 "${SCRIPT_DIR}/ensure-waydroid-dbus.sh" /usr/local/bin/ensure-waydroid-dbus.sh
install -m 0755 "${SCRIPT_DIR}/mount-emulated-storage.sh" /usr/local/bin/mount-emulated-storage.sh

echo "Installing systemd services..."
cp "${SCRIPT_DIR}/sway.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/waydroid-session.service" /etc/systemd/system/

echo "Reloading systemd and enabling services..."
systemctl daemon-reload

# 'restart', not 'enable --now': on a re-run against an already-running
# sway.service, --now alone is a no-op for units that are already active,
# so a changed config wouldn't take effect until something else restarted it.
systemctl enable sway waydroid-container.service
systemctl restart sway waydroid-container.service

# Not started here: Android's first boot can take minutes, better triggered
# explicitly once the rest is confirmed working.
systemctl enable waydroid-session.service

echo "Services installed. Start Waydroid with: systemctl start waydroid-session"
