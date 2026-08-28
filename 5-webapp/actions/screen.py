"""
Screen mirroring and remote control - screenshot, tap, swipe, text, key
events - over adb via the adbutils library (github.com/openatx/adbutils).
Reuses the same adb connection GPS control relies on
(4-waydroid-tools/change-location.sh's 'waydroid adb connect'), since
adbutils is just another client of the standard adb server (tcp:5037).
See 5-webapp/README.md, "Screen: remote control".
"""
from __future__ import annotations

import io
import subprocess
from contextlib import suppress

import adbutils

from .base import ActionError, ActionResult, validate_number

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
    # Used by the host-keyboard passthrough in static/js/app.js.
    "tab": 61,
    "space": 62,  # send_text() rejects whitespace-only input; see below
    "escape": 111,
    "delete": 112,  # forward delete, not backspace
    "up": 19,
    "down": 20,
    "left": 21,
    "right": 22,
    # Real KeyEvents, not text injection - unlike send_text()'s 'input
    # text', these still reach a lock-screen PIN pad (see the docstring
    # on send_text for why that distinction matters), so a PIN can be
    # entered entirely through named keys: "0".."9" then "enter".
    "0": 7,
    "1": 8,
    "2": 9,
    "3": 10,
    "4": 11,
    "5": 12,
    "6": 13,
    "7": 14,
    "8": 15,
    "9": 16,
}


def _reconnect() -> None:
    """
    Best-effort 'waydroid adb connect', mirroring change-location.sh: the
    container's IP can change across restarts. Only called when no device
    is visible, so the common case pays no extra latency.
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


def _device() -> adbutils.AdbDevice:
    """
    Returns the single connected adb device, reconnecting once if none is
    immediately visible. Raises ActionError, not adbutils.AdbError, so
    routes/screen.py only has to catch one exception type.
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


def _screen_size(device: adbutils.AdbDevice) -> tuple[int, int]:
    try:
        size = device.window_size()
    except adbutils.AdbError as exc:
        raise ActionError(f"Couldn't read screen size: {exc}") from exc
    return int(size.width), int(size.height)


def screenshot() -> bytes:
    """PNG bytes of the current screen."""
    device = _device()
    try:
        image = device.screenshot(error_ok=False)
    except adbutils.AdbError as exc:
        raise ActionError(f"Screenshot failed: {exc}") from exc
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def tap(x: object, y: object) -> ActionResult:
    """Simulates a tap at device pixel coordinates (x, y)."""
    device = _device()
    width, height = _screen_size(device)
    # Valid pixel coordinates are [0, width-1] / [0, height-1] - width/height
    # themselves are one past the last valid pixel in each dimension.
    xi = int(validate_number(x, "x", 0, width - 1))
    yi = int(validate_number(y, "y", 0, height - 1))
    try:
        device.click(xi, yi)
    except adbutils.AdbError as exc:
        raise ActionError(f"Tap failed: {exc}") from exc
    return ActionResult(ok=True, message="Tapped.")


def swipe(x1: object, y1: object, x2: object, y2: object, duration_ms: object = 300) -> ActionResult:
    """Simulates a swipe/drag from (x1, y1) to (x2, y2) over duration_ms."""
    device = _device()
    width, height = _screen_size(device)
    x1i = int(validate_number(x1, "x1", 0, width - 1))
    y1i = int(validate_number(y1, "y1", 0, height - 1))
    x2i = int(validate_number(x2, "x2", 0, width - 1))
    y2i = int(validate_number(y2, "y2", 0, height - 1))
    duration_s = validate_number(duration_ms, "duration_ms", 50, 5000) / 1000.0
    try:
        device.swipe(x1i, y1i, x2i, y2i, duration=duration_s)
    except adbutils.AdbError as exc:
        raise ActionError(f"Swipe failed: {exc}") from exc
    return ActionResult(ok=True, message="Swiped.")


def send_text(text: object) -> ActionResult:
    """
    Types `text` into whatever currently has focus (an Android EditText,
    a search box, ...) via 'input text' under the hood - there has to be
    a focused, editable field on screen already (tap one first). This is
    text *injection*, delivered straight to the focused view rather than
    as real hardware-style key presses - fine for a normal text field,
    but not reliable against a lock-screen PIN/pattern/password pad,
    which (unlike a plain EditText) often only responds to actual
    KeyEvents. send_key() with a digit ("0".."9") + "enter" is the one
    that reaches those.
    """
    if not isinstance(text, str) or not text.strip():
        raise ActionError("text is required.")
    device = _device()
    try:
        device.send_keys(text)
    except adbutils.AdbError as exc:
        raise ActionError(f"Sending text failed: {exc}") from exc
    return ActionResult(ok=True, message="Text sent.")


def send_key(key: object) -> ActionResult:
    """Sends a named key event - see _KEY_CODES for the supported names."""
    if not isinstance(key, str) or key.lower() not in _KEY_CODES:
        raise ActionError(f"key must be one of: {', '.join(sorted(_KEY_CODES))}")
    device = _device()
    try:
        device.keyevent(_KEY_CODES[key.lower()])
    except adbutils.AdbError as exc:
        raise ActionError(f"Key event failed: {exc}") from exc
    return ActionResult(ok=True, message="Key sent.")


def kill_all_apps() -> ActionResult:
    """
    Force-stops every third-party app ('pm list packages -3' - not
    system packages like Settings/SystemUI, which force-stopping is far
    riskier than helpful for), then sends Home. A recovery tool for a
    frozen or stuck foreground app: the adb equivalent of swiping every
    card away in Recents, but it doesn't depend on the screen actually
    working - unlike Recents itself, which needs a working
    screenshot/tap to use, the one thing this is often reached for. One
    stubborn package failing to stop doesn't block the rest; the final
    tally is whatever actually succeeded.

    The Home keyevent at the end matters: force-stop only kills the
    process, it doesn't dismiss whatever the window manager is still
    showing for it - without this, the now-dead app's last frame (or a
    blank/frozen surface) stays on screen, which reads as "killed but
    still open." Sent even when nothing was actually running, since a
    frozen screen with 0 killable apps is exactly when landing back on
    the launcher is most useful.
    """
    device = _device()
    try:
        listing = device.shell("pm list packages -3")
    except adbutils.AdbError as exc:
        raise ActionError(f"Couldn't list installed apps: {exc}") from exc

    packages = [
        line.split(":", 1)[1].strip()
        for line in listing.splitlines()
        if line.startswith("package:") and line.split(":", 1)[1].strip()
    ]
    stopped = []
    for package in packages:
        try:
            device.shell(["am", "force-stop", package])
            stopped.append(package)
        except adbutils.AdbError:
            continue  # best-effort - move on and report what did stop

    with suppress(adbutils.AdbError):
        device.keyevent(_KEY_CODES["home"])

    return ActionResult(
        ok=True,
        message=f"Force-stopped {len(stopped)} app(s).",
        data={"stopped": stopped},
    )
