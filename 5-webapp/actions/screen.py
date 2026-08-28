"""
Screen mirroring/remote-control action - replaces wayvnc/noVNC. Talks
directly to the Waydroid container over adb via the adbutils Python
library (github.com/openatx/adbutils), reusing the same adb connection
GPS control already relies on (4-waydroid-tools/change-location.sh's
'waydroid adb connect' dance) rather than a separate VNC/websocket/nginx
stack. See README "Remote screen" for why this replaced noVNC.

adbutils talks to the standard adb server (tcp:5037, auto-started if not
already running - verified live: killing the server first and calling
adbutils.adb.device_list() from a bare Python process still works, no
'adb start-server' needed beforehand) - it's a second client of the same
server the 'adb'/'waydroid adb connect' CLI calls already use, not a
separate connection mechanism, so anything already connected (by
setup-gps.sh, change-location.sh, or a stale prior session) is visible
to it immediately.
"""
from __future__ import annotations

import io
import subprocess

import adbutils

from .base import ActionError, validate_number

_ADB_TIMEOUT = 10  # seconds - reconnect/status calls should be fast; screen actions use adbutils' own defaults

_KEY_CODES = {
    "back": 4,
    "home": 3,
    "recents": 187,
    "enter": 66,
    "backspace": 67,
    "power": 26,
    "volume_up": 24,
    "volume_down": 25,
    # Added for host-keyboard passthrough (static/js/app.js's keydown
    # handler on the focused screen image) - standard, stable Android
    # KeyEvent constants (unchanged since early API levels).
    "tab": 61,
    "space": 62,  # sent as a keyevent rather than through send_text(),
    # since send_text() rejects whitespace-only input (see its docstring/
    # test_send_text_requires_nonempty) - that guard is for the manual
    # "Send text" field, not a single space keystroke.
    "escape": 111,
    "delete": 112,  # forward delete, i.e. the dedicated 'Delete' key, not backspace
    "up": 19,
    "down": 20,
    "left": 21,
    "right": 22,
}


def _reconnect() -> None:
    """
    Best-effort 'waydroid adb connect', mirroring change-location.sh: the
    container's IP (and therefore the adb connection) can change across
    session/container restarts - reconnecting fixes a stale/offline
    registration. Only called when no device is already visible (see
    _device() below), so the common case (already connected) never pays
    this subprocess's latency on every tap/swipe.
    """
    try:
        subprocess.run(
            ["waydroid", "adb", "connect"],
            capture_output=True,
            timeout=_ADB_TIMEOUT,
            check=False,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass


def _device() -> "adbutils.AdbDevice":
    """
    Returns the single connected adb device, reconnecting once if none is
    immediately visible. Raises ActionError (not adbutils.AdbError) so
    routes/screen.py only has to catch one exception type, same as every
    other action module.
    """
    try:
        devices = adbutils.adb.device_list()
    except adbutils.AdbError as exc:
        raise ActionError(f"Can't reach the adb server: {exc}") from exc

    if not devices:
        _reconnect()
        try:
            devices = adbutils.adb.device_list()
        except adbutils.AdbError as exc:
            raise ActionError(f"Can't reach the adb server: {exc}") from exc

    if not devices:
        raise ActionError(
            "No adb device connected - run 4-waydroid-tools/setup-gps.sh "
            "(or 'waydroid adb connect') first."
        )
    if len(devices) > 1:
        raise ActionError(
            f"{len(devices)} adb devices connected, expected exactly one - "
            "disconnect the extra one(s) with 'adb disconnect <serial>'."
        )
    return devices[0]


def _screen_size(device: "adbutils.AdbDevice") -> tuple[int, int]:
    try:
        size = device.window_size()
    except adbutils.AdbError as exc:
        raise ActionError(f"Couldn't read screen size: {exc}") from exc
    return int(size.width), int(size.height)


def screenshot() -> bytes:
    """
    PNG bytes of the current screen. adbutils.AdbDevice.screenshot()
    already decodes adb's framebuffer dump into a PIL Image (verified
    live against a real adb server) - re-encoded to PNG here so the route
    can serve it directly with a stable content type regardless of what
    format adb itself produced it in.
    """
    device = _device()
    try:
        image = device.screenshot(error_ok=False)
    except adbutils.AdbError as exc:
        raise ActionError(f"Screenshot failed: {exc}") from exc
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def tap(x: object, y: object) -> None:
    """Simulates a tap at device pixel coordinates (x, y)."""
    device = _device()
    width, height = _screen_size(device)
    xi = int(validate_number(x, "x", 0, width))
    yi = int(validate_number(y, "y", 0, height))
    try:
        device.click(xi, yi)
    except adbutils.AdbError as exc:
        raise ActionError(f"Tap failed: {exc}") from exc


def swipe(x1: object, y1: object, x2: object, y2: object, duration_ms: object = 300) -> None:
    """Simulates a swipe/drag from (x1, y1) to (x2, y2) over duration_ms."""
    device = _device()
    width, height = _screen_size(device)
    x1i = int(validate_number(x1, "x1", 0, width))
    y1i = int(validate_number(y1, "y1", 0, height))
    x2i = int(validate_number(x2, "x2", 0, width))
    y2i = int(validate_number(y2, "y2", 0, height))
    duration_s = validate_number(duration_ms, "duration_ms", 50, 5000) / 1000.0
    try:
        device.swipe(x1i, y1i, x2i, y2i, duration=duration_s)
    except adbutils.AdbError as exc:
        raise ActionError(f"Swipe failed: {exc}") from exc


def send_text(text: object) -> None:
    """
    Types `text` into whatever currently has focus (an Android EditText,
    a search box, ...) via 'input text' under the hood - there has to be
    a focused, editable field on screen already (tap one first).
    """
    if not isinstance(text, str) or not text.strip():
        raise ActionError("text is required.")
    device = _device()
    try:
        device.send_keys(text)
    except adbutils.AdbError as exc:
        raise ActionError(f"Sending text failed: {exc}") from exc


def send_key(key: object) -> None:
    """Sends a named key event - see _KEY_CODES for the supported names."""
    if not isinstance(key, str) or key.lower() not in _KEY_CODES:
        raise ActionError(f"key must be one of: {', '.join(sorted(_KEY_CODES))}")
    device = _device()
    try:
        device.keyevent(_KEY_CODES[key.lower()])
    except adbutils.AdbError as exc:
        raise ActionError(f"Key event failed: {exc}") from exc
