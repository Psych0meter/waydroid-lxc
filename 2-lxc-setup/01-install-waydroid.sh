#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root inside the container." >&2
  exit 1
fi

if [[ ! -e /dev/binder ]]; then
  echo "Error: /dev/binder is missing." >&2
  echo "Check that 1-proxmox-host/enable-binder.sh ran on the host and that" >&2
  echo "1-proxmox-host/lxc-config-append.txt was added to the CT's .conf" >&2
  echo "(then that the container was restarted)." >&2
  exit 1
fi

echo "Updating system..."
apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "Installing prerequisites..."
# NOTE: 'sway' (a wlroots compositor), not 'weston' - wayvnc depends on
# wlroots-specific protocols (virtual-pointer, xdg-output v3+) that Weston
# doesn't implement. See docs/DEBUGGING_AND_TESTS.md for details.
apt-get install -y curl ca-certificates iptables dnsmasq sway wayvnc novnc websockify python3 git wget kmod nano procps lsb-release dbus dbus-daemon dbus-bin

# The dnsmasq package auto-enables itself as a system service on install
# (default Debian behavior) and listens with --local-service on all local
# interfaces. That conflicts on port 53 with the ad-hoc instance that
# /usr/lib/waydroid/data/scripts/waydroid-net.sh starts on the waydroid0
# bridge, making 'waydroid session start' fail with "Address already in
# use". Waydroid manages its own dnsmasq on demand, so the system service
# isn't needed.
if systemctl is-enabled --quiet dnsmasq 2>/dev/null || systemctl is-active --quiet dnsmasq 2>/dev/null; then
  echo "Disabling the system dnsmasq service (conflicts with waydroid-net.sh's ad-hoc instance)..."
  systemctl disable --now dnsmasq
fi

echo "Installing Waydroid..."
if ! command -v waydroid >/dev/null 2>&1; then
  curl -s https://repo.waydro.id | bash
  apt-get install -y waydroid
else
  echo "Waydroid already installed, skipping."
fi

echo "Initializing Waydroid with GAPPS and software rendering..."
if [[ -d /var/lib/waydroid/images ]]; then
  echo "Waydroid already initialized (/var/lib/waydroid/images exists), skipping 'waydroid init'."
else
  waydroid init -s GAPPS
fi

echo "Configuring properties for software rendering (since there is no GPU)..."
waydroid prop set ro.hardware.gralloc default
waydroid prop set ro.hardware.egl swiftshader

echo "Installation complete! Next, run the services script."
