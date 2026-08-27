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
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APK="${SCRIPT_DIR}/mock-location.apk"
PKG="io.appium.settings"

# waydroid-session.service runs its own isolated D-Bus session bus. An
# interactive shell doesn't have it by default, and 'waydroid' CLI
# commands then wrongly report the session as stopped (see
# docs/DEBUGGING_AND_TESTS.md, Phase 3).
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/waydroid-dbus/session}"

if ! command -v waydroid >/dev/null 2>&1; then
  echo "Error: 'waydroid' command not found." >&2
  exit 1
fi

if [[ ! -f "${APK}" ]]; then
  echo "Error: ${APK} not found - run 03-setup-tools.sh first." >&2
  exit 1
fi

# adbd is disabled by default on this (non-eng) build. Flip it on via the
# already-proven 'waydroid shell' path before touching 'waydroid adb' -
# this only needs to happen once, but is harmless to repeat.
echo "Enabling ADB debugging inside the Android container..."
waydroid shell -- settings put global adb_enabled 1

echo "Waiting for 'waydroid adb' to see a device (Android's first boot can take a few minutes)..."
CONNECTED=0
for _ in $(seq 1 90); do
  if waydroid adb devices 2>/dev/null | grep -qE '\bdevice$'; then
    CONNECTED=1
    break
  fi
  sleep 2
done

if [[ "${CONNECTED}" -ne 1 ]]; then
  echo "Error: 'waydroid adb devices' never showed a connected device after 3 minutes." >&2
  echo "Check 'waydroid status' (session must be RUNNING) and 'waydroid adb devices' by hand." >&2
  exit 1
fi

echo "Installing the mock-location app..."
waydroid adb install -r "${APK}"

echo "Granting location permissions and mock-location app-ops..."
waydroid adb shell pm grant "${PKG}" android.permission.ACCESS_FINE_LOCATION
waydroid adb shell pm grant "${PKG}" android.permission.ACCESS_COARSE_LOCATION
waydroid adb shell appops set "${PKG}" android:mock_location allow

echo "Done. Set a location with: ./change-location.sh <latitude> <longitude>"
