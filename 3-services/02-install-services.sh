#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# By default, wayvnc/websockify only listen on 127.0.0.1 (access via SSH
# tunnel only - see README "Security" section). To expose them directly on
# the LAN (without any VNC-side authentication!):
#   EXPOSE_LAN=yes ./02-install-services.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root inside the container." >&2
  exit 1
fi

EXPOSE_LAN="${EXPOSE_LAN:-no}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Installing Sway headless config..."
mkdir -p /etc/sway
cp "${REPO_ROOT}/2-lxc-setup/sway-headless-config" /etc/sway/config-headless

echo "Installing helper scripts..."
install -m 0755 "${SCRIPT_DIR}/wait-for-wayland-socket.sh" /usr/local/bin/wait-for-wayland-socket.sh
install -m 0755 "${SCRIPT_DIR}/ensure-waydroid-dbus.sh" /usr/local/bin/ensure-waydroid-dbus.sh
install -m 0755 "${SCRIPT_DIR}/mount-emulated-storage.sh" /usr/local/bin/mount-emulated-storage.sh

# wayvnc ALWAYS tries to load a config file, even without -C, and crashes
# ("Failed to load config. Success") if none exists - known upstream bug
# (https://github.com/any1/wayvnc/issues/10). Provide an empty one,
# referenced explicitly via -C in wayvnc.service so it doesn't depend on
# $HOME (unset by systemd for a root service without User=).
mkdir -p /etc/wayvnc
touch /etc/wayvnc/config

echo "Installing systemd services..."
cp "${SCRIPT_DIR}/sway.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/wayvnc.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/novnc.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/waydroid-session.service" /etc/systemd/system/

if [[ "${EXPOSE_LAN}" == "yes" ]]; then
  echo "!!! EXPOSE_LAN=yes: noVNC will listen on 0.0.0.0 WITHOUT AUTHENTICATION."
  # Only websockify (noVNC) needs to listen on the LAN: it connects to
  # wayvnc internally over 127.0.0.1, which stays local - no need to expose
  # the raw VNC protocol (port 5900) in addition to the web port (6080).
  sed -i 's/127\.0\.0\.1:6080 127\.0\.0\.1:5900/0.0.0.0:6080 127.0.0.1:5900/' /etc/systemd/system/novnc.service
fi

echo "Reloading systemd and enabling services..."
systemctl daemon-reload

systemctl enable --now sway
systemctl enable --now wayvnc
systemctl enable --now novnc

# waydroid-container.service is created/enabled by the 'waydroid' package
# itself in 01-install-waydroid.sh; make sure it's running.
systemctl enable --now waydroid-container.service

# waydroid-session.service is not started here: Android's first boot can
# take several minutes, and it's better to trigger it explicitly once
# everything else is confirmed working (see docs/DEBUGGING_AND_TESTS.md).
systemctl enable waydroid-session.service

echo "Services installed."
if [[ "${EXPOSE_LAN}" == "yes" ]]; then
  echo "noVNC reachable at http://<LXC_IP>:6080/vnc.html (NO password)"
else
  echo "noVNC only reachable locally. From your machine:"
  echo "  ssh -L 6080:127.0.0.1:6080 root@<LXC_IP>"
  echo "  then open http://127.0.0.1:6080/vnc.html"
fi
echo "Start Waydroid with: systemctl start waydroid-session"
