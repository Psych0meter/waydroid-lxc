#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Downloads two third-party tools without necessarily running them yet:
#   - spoof-device.sh (device identity spoofing), downloaded but NOT run
#     here - see apply-spoof.sh (SPOOF_REF pins a commit instead of
#     tracking 'main'; review its content first if your threat model
#     requires it - the only change made here is stripping the 'sudo'
#     calls it doesn't need).
#   - the official Appium "Settings" app (io.appium.settings), a signed,
#     open-source APK used by the entire Appium/UiAutomator2 ecosystem as
#     a real, standards-compliant Android mock-location provider. GPS
#     spoofing (change-location.sh) installs and drives it over
#     'waydroid adb'. MOCK_LOCATION_VERSION pins the GitHub release tag.
#
# (An earlier version of this repo tried waydroid's own
# persist.waydroid.fake_gps property directly; a live logcat capture
# showed zero GNSS/location-provider activity when setting it - nothing
# in this Android image actually consumes that property, despite the
# command succeeding silently. See docs/DEBUGGING_AND_TESTS.md, Phase 5.)
set -euo pipefail

SPOOF_REPO="Quackdoc/waydroid-scripts"
SPOOF_REF="${SPOOF_REF:-main}"

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

echo "Downloading Quackdoc's spoof-device.sh (ref: ${SPOOF_REF})..."
fetch "https://raw.githubusercontent.com/${SPOOF_REPO}/${SPOOF_REF}/spoof-device.sh" spoof-device.sh
chmod +x spoof-device.sh

# The upstream script unconditionally shells out to 'sudo', which isn't
# installed in this minimal container. Since everything here already runs
# as root, elevation is a no-op we can safely drop - without this, every
# line of the script fails with "sudo: command not found" and NONE of the
# device properties actually get written, silently (the script has no
# 'set -e' and still exits 0).
sed -i 's/\bsudo //g' spoof-device.sh

echo "Downloading the Appium Settings mock-location app (${MOCK_LOCATION_VERSION})..."
fetch "https://github.com/${MOCK_LOCATION_REPO}/releases/download/${MOCK_LOCATION_VERSION}/${MOCK_LOCATION_ASSET}" mock-location.apk

echo "Tools downloaded and ready."
echo "  Device spoof: run ./apply-spoof.sh (see docs/DEBUGGING_AND_TESTS.md Phase 4"
echo "  for details - a container restart is required, not just a session restart)."
echo "  GPS: run ./setup-gps.sh once the Waydroid session is up, then use"
echo "  ./change-location.sh <lat> <lng> (see docs/DEBUGGING_AND_TESTS.md Phase 5)."
