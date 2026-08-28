"""
GPS mock-location action: a thin, validated wrapper around
4-waydroid-tools/change-location.sh. See that script and
docs/DEBUGGING_AND_TESTS.md for the underlying mechanism.
"""
from __future__ import annotations

import os

from .base import ActionError, ActionResult, run_script, validate_number

# Sourced from webapp.env by the systemd unit (see install-webapp.sh);
# defaults match a standard 0-deploy-all.sh deployment for running the
# app by hand outside systemd (e.g. during development).
TOOLS_DIR = os.environ.get(
    "WAYDROID_TOOLS_DIR", "/opt/waydroid-lxc-deploy/4-waydroid-tools"
)
CHANGE_LOCATION_SCRIPT = os.path.join(TOOLS_DIR, "change-location.sh")

_SCRIPT_TIMEOUT = 30  # change-location.sh does one 'adb shell' call and returns


def set_location(
    latitude: object, longitude: object, altitude: object = 35.0
) -> ActionResult:
    """
    Sets a mock GPS fix. Raises ActionError on invalid coordinates or if
    change-location.sh itself fails (e.g. the mock-location app isn't
    installed yet - run setup-gps.sh first).
    """
    lat = validate_number(latitude, "latitude", -90.0, 90.0)
    lng = validate_number(longitude, "longitude", -180.0, 180.0)
    alt = validate_number(altitude, "altitude", -1000.0, 100_000.0)

    result = run_script(
        [CHANGE_LOCATION_SCRIPT, str(lat), str(lng), str(alt)],
        timeout=_SCRIPT_TIMEOUT,
    )
    if result.returncode != 0:
        raise ActionError(
            (result.stderr or result.stdout or "change-location.sh failed").strip()
        )
    return ActionResult(
        ok=True,
        message=f"Location set to {lat}, {lng} (altitude {alt}).",
        data={"latitude": lat, "longitude": lng, "altitude": alt},
    )


def stop_location() -> ActionResult:
    """Stops sending mock fixes (change-location.sh --stop)."""
    result = run_script(
        [CHANGE_LOCATION_SCRIPT, "--stop"], timeout=_SCRIPT_TIMEOUT
    )
    if result.returncode != 0:
        raise ActionError(
            (result.stderr or result.stdout or "change-location.sh --stop failed").strip()
        )
    return ActionResult(ok=True, message="Mock location stopped.")
