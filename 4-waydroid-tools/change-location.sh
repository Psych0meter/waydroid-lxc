#!/usr/bin/env bash
# Sets (or clears) a mock GPS fix via the Appium Settings app
# (io.appium.settings), installed and configured by setup-gps.sh. This is
# the standard Android mock-location provider mechanism, driven over a
# real 'adb' client connected via 'waydroid adb connect' - 'waydroid adb'
# itself only has connect/disconnect subactions, it isn't a shell/install
# proxy the way 'waydroid adb shell'/'waydroid adb install' would imply.
# (Not Waydroid's own fake_gps property - that one doesn't work, see
# docs/DEBUGGING_AND_TESTS.md Phase 5.)
set -euo pipefail

PKG="io.appium.settings"

# waydroid-session.service runs its own isolated D-Bus session bus; an
# interactive shell doesn't have it by default (see docs/DEBUGGING_AND_TESTS.md, Phase 3).
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/waydroid-dbus/session}"

if ! command -v waydroid >/dev/null 2>&1; then
  echo "Error: 'waydroid' command not found." >&2
  exit 1
fi

if ! command -v adb >/dev/null 2>&1; then
  echo "Error: 'adb' command not found - run ./setup-gps.sh first." >&2
  exit 1
fi

# The container's IP (and therefore the adb connection) can change across
# session/container restarts - reconnecting is harmless when already
# connected, and fixes a stale/offline entry otherwise.
waydroid adb connect >/dev/null 2>&1 || true

if [[ "$#" -eq 1 && "$1" == "--stop" ]]; then
  adb shell am stopservice "${PKG}/.LocationService"
  echo "Mock location service stopped."
  exit 0
fi

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
  echo "Usage: $0 <latitude> <longitude> [altitude]"
  echo "       $0 --stop                          # stop sending mock fixes"
  echo "Example: $0 48.8584 2.2945        # Eiffel Tower"
  exit 1
fi

LAT="$1"
LNG="$2"
ALT="${3:-35.0}"

# Guards against the exact failure mode that motivated this check: passing
# a literal placeholder (e.g. "{lat}") copied from a doc example instead of
# a real number, which the service would otherwise silently misparse.
NUMBER_RE='^-?[0-9]+(\.[0-9]+)?$'
for value in "${LAT}" "${LNG}" "${ALT}"; do
  if ! [[ "${value}" =~ ${NUMBER_RE} ]]; then
    echo "Error: '${value}' is not a plain decimal number (latitude/longitude/altitude)." >&2
    exit 1
  fi
done

if ! adb shell pm list packages 2>/dev/null | grep -q "^package:${PKG}$"; then
  echo "Error: ${PKG} isn't installed - run ./setup-gps.sh first." >&2
  exit 1
fi

OUTPUT="$(adb shell am start-foreground-service --user 0 -n "${PKG}/.LocationService" \
  --es longitude "${LNG}" --es latitude "${LAT}" --es altitude "${ALT}" 2>&1)" || {
  echo "Error: failed to start the mock-location service:" >&2
  echo "${OUTPUT}" >&2
  exit 1
}

echo "Location updated to ${LAT}, ${LNG} (altitude ${ALT}) - updates every ~2s until ./change-location.sh --stop."
