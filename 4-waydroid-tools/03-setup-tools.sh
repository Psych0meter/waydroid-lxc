#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Downloads (but deliberately does NOT run) one unsigned third-party script
# (device spoofing) from an individual GitHub repo. Set SPOOF_REF to pin a
# commit instead of tracking 'main'; review its content first if your
# threat model requires it - the only change made here is stripping the
# 'sudo' calls it doesn't need. GPS spoofing needs no download - see
# change-location.sh, which uses Waydroid's own persist.waydroid.fake_gps
# property directly.
set -euo pipefail

SPOOF_REPO="Quackdoc/waydroid-scripts"
SPOOF_REF="${SPOOF_REF:-main}"

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

# The upstream script unconditionally shells out to 'sudo', which isn't
# installed in this minimal container. Since everything here already runs
# as root, elevation is a no-op we can safely drop - without this, every
# line of the script fails with "sudo: command not found" and NONE of the
# device properties actually get written, silently (the script has no
# 'set -e' and still exits 0).
sed -i 's/\bsudo //g' spoof-device.sh

echo "Tool downloaded and ready! Run ./spoof-device.sh, then see docs/DEBUGGING_AND_TESTS.md"
echo "Phase 4 for how to apply it (a container restart is required, not just a session restart)."
