#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Downloads the official Appium "Settings" app (io.appium.settings), a
# signed, open-source APK used by the entire Appium/UiAutomator2
# ecosystem as a real, standards-compliant Android mock-location provider
# (not Waydroid's own fake_gps property - that one doesn't work, see
# docs/DEBUGGING_AND_TESTS.md Phase 5). GPS spoofing (change-location.sh)
# installs and drives it over 'waydroid adb'. MOCK_LOCATION_VERSION pins
# the GitHub release tag.
#
# Device identity spoofing doesn't need a download - see apply-spoof.sh
# and device-profiles/README.md.
set -euo pipefail

MOCK_LOCATION_REPO="appium/io.appium.settings"
MOCK_LOCATION_VERSION="${MOCK_LOCATION_VERSION:-v7.1.3}"
MOCK_LOCATION_ASSET="settings_apk-debug.apk"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# wget -q swallows HTTP errors and still creates an empty destination file,
# which would silently pass downstream "does the file exist" checks. Fail
# loudly instead and clean up any empty/partial file.
fetch() {
  local url="$1" dest="$2"
  if ! wget -qO "${dest}" "${url}" || [[ ! -s "${dest}" ]]; then
    rm -f "${dest}"
    echo "Error: failed to download ${dest} from ${url}" >&2
    exit 1
  fi
}

echo "Downloading the Appium Settings mock-location app (${MOCK_LOCATION_VERSION})..."
fetch "https://github.com/${MOCK_LOCATION_REPO}/releases/download/${MOCK_LOCATION_VERSION}/${MOCK_LOCATION_ASSET}" mock-location.apk

echo "Tools ready."
echo "  Device spoof: run ./apply-spoof.sh (--list shows available device"
echo "  profiles - see docs/DEBUGGING_AND_TESTS.md Phase 4 for details, a"
echo "  container restart is required, not just a session restart)."
echo "  GPS: run ./setup-gps.sh once the Waydroid session is up, then use"
echo "  ./change-location.sh <lat> <lng> (see docs/DEBUGGING_AND_TESTS.md Phase 5)."
