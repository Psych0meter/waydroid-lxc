#!/usr/bin/env bash
# Works around a known Waydroid limitation: the emulated filesystem
# (/storage/emulated/0) doesn't automatically create the standard
# Android/data, Android/obb, Android/media tree that the Play Store (and
# many apps) need to download/install. Without it, the Play Store wrongly
# shows "Free up space" even with plenty of room on /data.
# Reference: https://github.com/waydroid/waydroid/issues/530
#            https://github.com/waydroid/waydroid/issues/1911
#
# Re-run this after resetting Waydroid ('waydroid init -f'), or if a
# specific app still fails with a "Can't create
# file:///storage/emulated/0/Android/data/<pkg>/..." error in 'waydroid
# logcat': in that case, add a targeted mkdir -p for the exact path shown in
# the logcat.
set -euo pipefail

if ! command -v waydroid >/dev/null 2>&1; then
  echo "Error: 'waydroid' command not found." >&2
  exit 1
fi

echo "Creating the standard storage tree..."
waydroid shell -- mkdir -p /storage/emulated/0/Android/data
waydroid shell -- mkdir -p /storage/emulated/0/Android/obb
waydroid shell -- mkdir -p /storage/emulated/0/Android/media
waydroid shell -- chmod -R 777 /storage/emulated/0/Android

echo "Done. Retry the Play Store install."
