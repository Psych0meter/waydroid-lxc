#!/usr/bin/env bash
# Forces the Android "emulated;0" storage volume to mount. vold marks it
# UNMOUNTABLE at boot on this image and never retries on its own; an
# explicit 'sm mount' brings it to MOUNTED. Without this, the Play Store
# and other apps wrongly report "Not enough storage space" (see
# docs/DEBUGGING_AND_TESTS.md, Phase 3).
set -uo pipefail   # no -e: failed attempts must fall through to the retry loop

for _ in $(seq 1 30); do
  if waydroid shell -- sm mount 'emulated;0' >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done

echo "Warning: could not mount emulated;0 after several attempts (is the Android service running?)." >&2
exit 0
