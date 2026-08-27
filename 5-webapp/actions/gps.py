"""
GPS mock-location action: a thin, validated wrapper around
4-waydroid-tools/change-location.sh (see that script and
docs/DEBUGGING_AND_TESTS.md, Phase 5, for how the underlying mechanism
works and its known limitations - notably that Google Maps needs to be
restarted to visually pick up a large jump, which this module can't do
anything about since it's a Maps UI quirk, not a location-pipeline bug).
"""
from __future__ import annotations

import os

from .base import ActionError, ActionResult, run_script

# Sourced from webapp.env by the systemd unit (see install-webapp.sh);
# defaults match a standard 0-deploy-all.sh deployment for running the
# app by hand outside systemd (e.g. during development).
TOOLS_DIR = os.environ.get(
    "WAYDROID_TOOLS_DIR", "/opt/waydroid-lxc-deploy/4-waydroid-tools"
)
CHANGE_LOCATION_SCRIPT = os.path.join(TOOLS_DIR, "change-location.sh")

_SCRIPT_TIMEOUT = 30  # change-location.sh does one 'adb shell' call and returns


def _validate_number(value: object, name: str, lo: float, hi: float) -> float:
    if isinstance(value, bool) or value is None:
        raise ActionError(f"{name} is required and must be a number.")
    try:
        parsed = float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        raise ActionError(f"{name} must be a number, got: {value!r}") from None
    if not (lo <= parsed <= hi):
        raise ActionError(f"{name} must be between {lo} and {hi}, got: {parsed}")
    return parsed


def set_location(
    latitude: object, longitude: object, altitude: object = 35.0
) -> ActionResult:
    """
    Sets a mock GPS fix. Raises ActionError on invalid coordinates or if
    change-location.sh itself fails (e.g. the mock-location app isn't
    installed yet - run setup-gps.sh first).
    """
    lat = _validate_number(latitude, "latitude", -90.0, 90.0)
    lng = _validate_number(longitude, "longitude", -180.0, 180.0)
    alt = _validate_number(altitude, "altitude", -1000.0, 100_000.0)

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
