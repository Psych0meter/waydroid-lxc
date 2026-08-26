#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# wayvnc/websockify listen on 127.0.0.1 by default (SSH tunnel access - see
# README "Security"). To expose them on the LAN (no VNC authentication!):
#   EXPOSE_LAN=yes ./02-install-services.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root inside the container." >&2
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

# wayvnc crashes without a config file, even without -C (upstream bug:
# any1/wayvnc#10). Provide an empty one, referenced explicitly so it
# doesn't depend on $HOME (unset for a root service without User=).
mkdir -p /etc/wayvnc
touch /etc/wayvnc/config

echo "Installing systemd services..."
cp "${SCRIPT_DIR}/sway.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/wayvnc.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/novnc.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/waydroid-session.service" /etc/systemd/system/

if [[ "${EXPOSE_LAN}" == "yes" ]]; then
  echo "!!! EXPOSE_LAN=yes: noVNC will listen on 0.0.0.0 WITHOUT AUTHENTICATION."
  # Only noVNC needs the LAN listener; it reaches wayvnc over 127.0.0.1
  # internally, so the raw VNC port (5900) stays local.
  sed -i 's/127\.0\.0\.1:6080 127\.0\.0\.1:5900/0.0.0.0:6080 127.0.0.1:5900/' /etc/systemd/system/novnc.service
fi

echo "Reloading systemd and enabling services..."
systemctl daemon-reload

systemctl enable --now sway
systemctl enable --now wayvnc
systemctl enable --now novnc
systemctl enable --now waydroid-container.service

# Not started here: Android's first boot can take minutes, better triggered
# explicitly once the rest is confirmed working.
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
