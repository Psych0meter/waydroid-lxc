#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Downloads two unsigned third-party scripts from individual GitHub repos.
# Set SPOOF_REF / GPS_REF to pin a commit instead of tracking 'main'; review
# their content first if your threat model requires it.
#
# KNOWN ISSUE (verified 2026-08-26): the default GPS_REPO has no
# fake_gps.py at this path/ref - the download below will fail until
# GPS_REPO/GPS_REF point at a source that actually has the file. Device
# spoofing (SPOOF_REPO) is unaffected and works as-is.
set -euo pipefail

SPOOF_REPO="Quackdoc/waydroid-scripts"
SPOOF_REF="${SPOOF_REF:-main}"
GPS_REPO="ayasa520/waydroid_stuff"
GPS_REF="${GPS_REF:-main}"

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
  chmod +x "${dest}"
}

echo "Downloading Quackdoc's spoof-device.sh (ref: ${SPOOF_REF})..."
fetch "https://raw.githubusercontent.com/${SPOOF_REPO}/${SPOOF_REF}/spoof-device.sh" spoof-device.sh

echo "Downloading ayasa520's fake_gps.py (ref: ${GPS_REF})..."
fetch "https://raw.githubusercontent.com/${GPS_REPO}/${GPS_REF}/fake_gps.py" fake_gps.py

echo "Tools downloaded and ready!"
