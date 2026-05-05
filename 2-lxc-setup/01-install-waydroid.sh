#!/usr/bin/env bash
set -e

echo "Updating system..."
apt-get update && apt-get upgrade -y

echo "Installing prerequisites..."
apt-get install -y curl ca-certificates iptables dnsmasq weston wayvnc novnc websockify python3 git wget kmod nano procps

echo "Installing Waydroid..."
curl -s https://repo.waydro.id | bash
apt-get install -y waydroid

echo "Initializing Waydroid with GAPPS and software rendering..."
waydroid init -s GAPPS

echo "Configuring properties for software rendering (since there is no GPU)..."
waydroid prop set ro.hardware.gralloc default
waydroid prop set ro.hardware.egl swiftshader

echo "Installation complete! Next, run the services script."
