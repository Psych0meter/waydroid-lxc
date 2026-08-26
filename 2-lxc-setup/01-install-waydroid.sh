#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root inside the container." >&2
  exit 1
fi

if [[ ! -e /dev/binder ]]; then
  echo "Error: /dev/binder is missing." >&2
  echo "Check that enable-binder.sh ran on the host, lxc-config-append.txt" >&2
  echo "was applied, and the container was restarted." >&2
  exit 1
fi

echo "Updating system..."
apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "Installing prerequisites..."
# sway, not weston: wayvnc needs wlroots protocols Weston doesn't implement
# (see README, "Architecture choice").
apt-get install -y curl ca-certificates iptables dnsmasq sway wayvnc novnc websockify python3 git wget kmod nano procps lsb-release dbus dbus-daemon dbus-bin

# dnsmasq auto-enables itself as a system service, conflicting with
# Waydroid's own dnsmasq on the waydroid0 bridge (see
# docs/DEBUGGING_AND_TESTS.md, Phase 3).
if systemctl is-enabled --quiet dnsmasq 2>/dev/null || systemctl is-active --quiet dnsmasq 2>/dev/null; then
  echo "Disabling the system dnsmasq service..."
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
  echo "Waydroid already initialized, skipping 'waydroid init'."
else
  waydroid init -s GAPPS
fi

echo "Configuring properties for software rendering (no GPU in the container)..."
waydroid prop set ro.hardware.gralloc default
waydroid prop set ro.hardware.egl swiftshader

echo "Installation complete! Next, run the services script."
