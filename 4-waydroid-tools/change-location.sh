#!/usr/bin/env bash
# Injects a fake GPS fix directly via Waydroid's own GNSS property,
# persist.waydroid.fake_gps - applied live by the running session, no
# restart needed. No third-party script involved: an earlier version of
# this repo shelled out to a downloaded fake_gps.py, but that file turned
# out not to exist at its source repo (see docs/DEBUGGING_AND_TESTS.md,
# Phase 5) - this is the confirmed-working replacement.
set -euo pipefail

# waydroid-session.service runs its own isolated D-Bus session bus (see
# waydroid-session.service). An interactive shell doesn't have it by
# default, and 'waydroid prop' then wrongly reports the session as stopped
# (see docs/DEBUGGING_AND_TESTS.md, Phase 3).
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/waydroid-dbus/session}"

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
  echo "Usage: $0 <latitude> <longitude> [altitude]"
  echo "Example: $0 48.8584 2.2945        # Eiffel Tower"
  exit 1
fi

LAT="$1"
LNG="$2"
ALT="${3:-35.0}"

# Guards against the exact failure mode that motivated this check: passing
# a literal placeholder (e.g. "{lat}") copied from a doc example instead of
# a real number, which Android silently ignores.
NUMBER_RE='^-?[0-9]+(\.[0-9]+)?$'
for value in "${LAT}" "${LNG}" "${ALT}"; do
  if ! [[ "${value}" =~ ${NUMBER_RE} ]]; then
    echo "Error: '${value}' is not a plain decimal number (latitude/longitude/altitude)." >&2
    exit 1
  fi
done

if ! command -v waydroid >/dev/null 2>&1; then
  echo "Error: 'waydroid' command not found." >&2
  exit 1
fi

# Fix,provider,lat,lng,alt,speed,accuracy,bearing,satellites,horizontal_accuracy,vertical_accuracy,elapsed
FIX="Fix,gps,${LAT},${LNG},${ALT},0.0,5.0,0.0,0,1.0,90.0,0"

OUTPUT="$(waydroid prop set persist.waydroid.fake_gps "${FIX}" 2>&1)" || {
  echo "Error: 'waydroid prop set' failed:" >&2
  echo "${OUTPUT}" >&2
  exit 1
}
if grep -qi "session is stopped" <<<"${OUTPUT}"; then
  echo "Error: Waydroid reports the session is stopped - is waydroid-session running?" >&2
  echo "Check with: systemctl status waydroid-session" >&2
  exit 1
fi

echo "Location updated to ${LAT}, ${LNG} (fix: ${FIX})"
