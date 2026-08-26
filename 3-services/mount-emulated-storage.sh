#!/usr/bin/env bash
# Forces the "emulated;0" volume (Android internal storage) to mount after
# the session starts.
#
# Observed in practice: on the GAPPS Waydroid image used by this repo, vold
# marks this volume UNMOUNTABLE at boot and never retries on its own,
# regardless of /dev/fuse's state. An explicit 'sm mount' call (the modern
# StorageManager tool - unlike 'vdc', whose raw text commands are no longer
# supported on recent Android versions) is enough to bring it to MOUNTED.
# Without this script, the Play Store and other apps wrongly report "Not
# enough storage space" even though /data has free space (visible via
# 'waydroid shell -- dumpsys mount': state=UNMOUNTABLE, while 'waydroid
# shell -- dumpsys diskstats' shows plenty of free space).
set -uo pipefail

for _ in $(seq 1 30); do
  if waydroid shell -- sm mount 'emulated;0' >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done

echo "Warning: could not mount the emulated;0 volume after several attempts (is the Android service actually running?)." >&2
exit 0
