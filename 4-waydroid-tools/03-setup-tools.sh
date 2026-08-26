#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Downloads two unsigned third-party scripts from individual GitHub repos.
# Set SPOOF_REF / GPS_REF to pin a commit instead of tracking 'main'; review
# their content first if your threat model requires it.
set -euo pipefail

export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/waydroid-dbus/session}

SPOOF_REPO="Quackdoc/waydroid-scripts"
SPOOF_REF="${SPOOF_REF:-main}"
GPS_REPO="ayasa520/waydroid_stuff"
GPS_REF="${GPS_REF:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "Applying device spoofing (Pixel 5)..."
bash ./spoof-device.sh

echo "Downloading Quackdoc's spoof-device.sh (ref: ${SPOOF_REF})..."
wget -qO spoof-device.sh "https://raw.githubusercontent.com/${SPOOF_REPO}/${SPOOF_REF}/spoof-device.sh"
chmod +x spoof-device.sh

echo "Downloading ayasa520's fake_gps.py (ref: ${GPS_REF})..."
wget -qO fake_gps.py "https://raw.githubusercontent.com/${GPS_REPO}/${GPS_REF}/fake_gps.py"
chmod +x fake_gps.py

echo "Tools downloaded and ready!"
