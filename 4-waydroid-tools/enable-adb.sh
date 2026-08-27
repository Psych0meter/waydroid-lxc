#!/usr/bin/env bash
# Sets ro.adb.secure=0 in waydroid_base.prop so 'adb'/'waydroid adb connect'
# can authenticate headlessly.
#
# Without this, Android's normal RSA-key authorization flow applies: the
# first connection from a given host shows an "Allow USB debugging from
# this computer?" popup that must be tapped to proceed, and until it is,
# 'adb devices' reports the connection as "unauthorized" forever. In this
# deployment there's no guarantee anyone is watching the noVNC session at
# the exact moment that popup appears, so setup-gps.sh/change-location.sh
# would otherwise be unreliable or require manual noVNC babysitting on
# every fresh deployment. ro.adb.secure=0 is the same mechanism real
# Android emulators use by default, for the same reason - it makes adbd
# skip RSA authentication entirely rather than working around the popup.
# See docs/DEBUGGING_AND_TESTS.md, Phase 5.
#
# ro.* properties are locked once Android has booted, so - like the
# device spoof in apply-spoof.sh - this only takes effect on the next
# CONTAINER restart (waydroid-container.service, not just the session),
# and is meaningless to apply after the fact via 'waydroid prop set'.
#
# Shares its one-time pre-change backup with apply-spoof.sh
# (waydroid_base.prop.orig): whichever of the two scripts runs first on a
# given container captures the pristine snapshot, and 'apply-spoof.sh
# --rollback' restores both changes at once. Idempotent: safe to re-run.
set -euo pipefail

BASE_PROP="/var/lib/waydroid/waydroid_base.prop"
BACKUP="${BASE_PROP}.orig"
RESTART_HINT="systemctl stop waydroid-session && systemctl restart waydroid-container && systemctl start waydroid-session"

if [[ ! -f "${BASE_PROP}" ]]; then
  echo "Error: ${BASE_PROP} not found - has 'waydroid init' been run?" >&2
  exit 1
fi

if [[ ! -f "${BACKUP}" ]]; then
  cp "${BASE_PROP}" "${BACKUP}"
fi

if grep -q '^ro\.adb\.secure=0$' "${BASE_PROP}"; then
  echo "ro.adb.secure=0 already set in ${BASE_PROP}, nothing to do."
else
  echo "ro.adb.secure=0" >> "${BASE_PROP}"
  TMP_PROP="$(mktemp)"
  tac "${BASE_PROP}" | awk -F'=' '!seen[$1]++' | tac > "${TMP_PROP}"
  chmod 644 "${TMP_PROP}"
  mv "${TMP_PROP}" "${BASE_PROP}"
  echo "Set ro.adb.secure=0 in ${BASE_PROP} - no RSA key authorization"
  echo "popup, 'adb connect' will show \"device\" directly."
fi

echo "Restart the container to apply: ${RESTART_HINT}"
