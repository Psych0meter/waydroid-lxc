#!/usr/bin/env bash
# Creates the standard Android/data, Android/obb, Android/media tree under
# /storage/emulated/0 that Waydroid doesn't scaffold automatically - without
# it, the Play Store wrongly reports low storage.
# Refs: waydroid/waydroid#530, waydroid/waydroid#1911
#
# Re-run after 'waydroid init -f', or if 'waydroid logcat' shows a
# "Can't create file:///storage/emulated/0/Android/data/<pkg>/..." error
# for a specific path.
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
