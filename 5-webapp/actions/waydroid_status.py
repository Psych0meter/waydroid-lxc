"""
Waydroid platform status: the container, the Android session inside it,
and this host's adb connection to it - the three things that have to be
up before any other action in this webapp can work, and none of which
the rest of the app can recover on its own when they're the problem
(actions/screen.py's _reconnect() only fixes a stale adb link once the
container/session are already up). Surfaced in the header as a
red/green indicator, with restart() as the recovery action for when
they aren't.
"""
from __future__ import annotations

import os
import re
import subprocess

import adbutils

from .base import ActionError, ActionResult

# Same dedicated D-Bus bus waydroid-session.service runs on
# (3-services/waydroid-session.service) - a root/systemd context calling
# 'waydroid status' or 'waydroid adb connect' doesn't have this by
# default, and both commands silently misbehave without it. Mirrors
# 4-waydroid-tools/change-location.sh's own override.
_ENV = {
    **os.environ,
    "DBUS_SESSION_BUS_ADDRESS": os.environ.get(
        "DBUS_SESSION_BUS_ADDRESS", "unix:path=/run/waydroid-dbus/session"
    ),
}

_STATUS_TIMEOUT = 10  # 'systemctl is-active' / 'waydroid status' / 'adb connect' are all near-instant
_RESTART_TIMEOUT = 60  # 'systemctl restart' returns once the units start, not once Android finishes booting

_SESSION_RUNNING_RE = re.compile(r"^Session:\s*RUNNING", re.MULTILINE)

_CONTAINER_UNIT = "waydroid-container.service"
_SESSION_UNIT = "waydroid-session.service"


def _systemctl_is_active(unit: str) -> str:
    """
    Returns systemd's own state word ('active', 'inactive', 'failed',
    'activating', ...) rather than a bool - 'inactive' (stopped cleanly)
    and 'failed' (crashed) are both "not running" but worth telling
    apart in the UI. Never raises: a missing systemctl binary or an
    unknown unit both just read as 'unknown' rather than failing the
    whole status check over one part of it.
    """
    try:
        proc = subprocess.run(
            ["systemctl", "is-active", unit],
            capture_output=True,
            text=True,
            timeout=_STATUS_TIMEOUT,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return "unknown"
    return (proc.stdout or "").strip() or "unknown"


def _session_running() -> bool:
    """
    'waydroid status' reports the Android session's own state
    ("Session: RUNNING"), distinct from waydroid-session.service simply
    being active (the unit can be up while the session inside it is
    still booting or has wedged) - see 4-waydroid-tools/start-waydroid.sh
    and tests/smoke-test.sh, which parse it the same way.
    """
    try:
        proc = subprocess.run(
            ["waydroid", "status"],
            capture_output=True,
            text=True,
            timeout=_STATUS_TIMEOUT,
            env=_ENV,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return bool(_SESSION_RUNNING_RE.search(proc.stdout or ""))


def _adb_connected() -> bool:
    try:
        return bool(adbutils.adb.device_list())
    except adbutils.AdbError:
        return False


def get_status() -> ActionResult:
    """
    Best-effort snapshot of container/session/adb. 'healthy' is only
    true when all three check out - the header dot is red/green off of
    that single flag, with the individual states available for a
    detail view (see routes/waydroid.py).
    """
    container = _systemctl_is_active(_CONTAINER_UNIT)
    session_unit = _systemctl_is_active(_SESSION_UNIT)
    session_running = _session_running()
    adb_connected = _adb_connected()

    healthy = (
        container == "active"
        and session_unit == "active"
        and session_running
        and adb_connected
    )

    return ActionResult(
        ok=True,
        message="Healthy." if healthy else "Not healthy.",
        data={
            "healthy": healthy,
            "container": container,
            "session_unit": session_unit,
            "session_running": session_running,
            "adb_connected": adb_connected,
        },
    )


def restart() -> ActionResult:
    """
    Restarts the container and session systemd units together (one
    'systemctl restart' call, so systemd's own After=/Requires=
    ordering for waydroid-session after waydroid-container - see
    3-services/waydroid-session.service - still applies within the
    transaction), then makes a best-effort 'waydroid adb connect'
    afterward: harmless if the session isn't fully up yet, and saves a
    manual reconnect for the common case where adb was the only thing
    actually stale (the container's IP can change across a restart -
    same reasoning as change-location.sh's own unconditional reconnect).

    Returns as soon as the restart is triggered, not once Android
    itself finishes booting inside the container - that takes longer
    (~30-60s, per 'waydroid session start's own readiness log) - so the
    frontend polls get_status() afterward to see when it's actually
    back.
    """
    try:
        proc = subprocess.run(
            ["systemctl", "restart", _CONTAINER_UNIT, _SESSION_UNIT],
            capture_output=True,
            text=True,
            timeout=_RESTART_TIMEOUT,
            check=False,
        )
    except FileNotFoundError as exc:
        raise ActionError("systemctl not found.") from exc
    except subprocess.TimeoutExpired as exc:
        raise ActionError(
            f"Timed out after {_RESTART_TIMEOUT}s restarting Waydroid."
        ) from exc

    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "unknown error").strip()
        raise ActionError(f"Restart failed: {detail}")

    try:
        subprocess.run(
            ["waydroid", "adb", "connect"],
            capture_output=True,
            timeout=_STATUS_TIMEOUT,
            env=_ENV,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass  # best-effort - the next screen/gps action reconnects on its own anyway

    return ActionResult(
        ok=True,
        message="Restart triggered - Waydroid takes 30-60s to fully come back up.",
    )
