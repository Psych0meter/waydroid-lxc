#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC, once the Waydroid session is up (this
# needs a live ADB connection to the Android container, unlike
# apply-spoof.sh which runs before first boot).
#
# Installs the official Appium "Settings" app (io.appium.settings,
# downloaded by 03-setup-tools.sh) as the system's mock-location provider
# - the standard, documented Android mechanism used by the entire
# Appium/UiAutomator2 test-automation ecosystem to inject GPS fixes.
# change-location.sh drives it afterwards. Safe to re-run (every step here
# is idempotent: 'adb install -r' reinstalls cleanly, 'pm grant'/'appops
# set' are no-ops when already granted).
#
# 'waydroid adb' only has two subactions, connect/disconnect - it doesn't
# proxy devices/install/shell like a real adb. 'waydroid adb connect' just
# looks up the container's IP (from the waydroid0 DHCP lease) and shells
# out to a real 'adb' binary to connect to it - so a real 'adb' has to be
# installed here, and every subsequent adb command below is the plain
# 'adb' client, not 'waydroid adb'.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK="${SCRIPT_DIR}/mock-location.apk"
PKG="io.appium.settings"

# waydroid-session.service runs its own isolated D-Bus session bus; an
# interactive shell doesn't have it by default (see docs/DEBUGGING_AND_TESTS.md, Phase 3).
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/waydroid-dbus/session}"

if ! command -v waydroid >/dev/null 2>&1; then
  echo "Error: 'waydroid' command not found." >&2
  exit 1
fi

if [[ ! -f "${APK}" ]]; then
  echo "Error: ${APK} not found - run 03-setup-tools.sh first." >&2
  exit 1
fi

if ! command -v adb >/dev/null 2>&1; then
  echo "Installing the 'adb' client (needed by 'waydroid adb connect')..."
  apt-get update
  apt-get install -y adb
fi

echo "Connecting adb to the Waydroid container (waits for its DHCP lease to appear, up to 3 minutes)..."
CONNECTED=0
for _ in $(seq 1 90); do
  if waydroid adb connect >/dev/null 2>&1; then
    CONNECTED=1
    break
  fi
  sleep 2
done

if [[ "${CONNECTED}" -ne 1 ]]; then
  echo "Error: 'waydroid adb connect' never succeeded after 3 minutes." >&2
  echo "Check 'waydroid status' (session must be RUNNING) and try 'waydroid adb connect' by hand." >&2
  exit 1
fi

if ! adb devices | grep -qE '\bdevice$'; then
  echo "Error: adb connected but no device is listed as ready yet." >&2
  echo "Check 'adb devices' by hand." >&2
  exit 1
fi

echo "Installing the mock-location app..."
adb install -r "${APK}"

echo "Granting location permissions and mock-location app-ops..."
adb shell pm grant "${PKG}" android.permission.ACCESS_FINE_LOCATION
adb shell pm grant "${PKG}" android.permission.ACCESS_COARSE_LOCATION
adb shell appops set "${PKG}" android:mock_location allow

echo "Done. Set a location with: ./change-location.sh <latitude> <longitude>"
