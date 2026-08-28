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
import re
import subprocess
import time
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

# Same signals Appium's own lock-state check greps 'dumpsys window' for -
# there's no single flag guaranteed present across every Android/Waydroid
# build, so this is a best-effort union, not a guarantee. If it ever
# reports the wrong thing, screenshot() failing (or not) is the stronger
# ground-truth signal - see the FLAG_SECURE note in
# docs/DEBUGGING_AND_TESTS.md.
_LOCK_INDICATOR_PATTERNS = (
    re.compile(r"mShowingLockscreen=true"),
    re.compile(r"mDreamingLockscreen=true"),
    re.compile(r"mCurrentFocus=.*Keyguard"),
    re.compile(r"mInputRestricted=true"),
)


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


def _is_locked(device: adbutils.AdbDevice) -> bool:
    try:
        output = device.shell(["dumpsys", "window"])
    except adbutils.AdbError as exc:
        raise ActionError(f"Couldn't read lock state: {exc}") from exc
    return any(pattern.search(output) for pattern in _LOCK_INDICATOR_PATTERNS)


def lock_status() -> ActionResult:
    """
    Best-effort keyguard detection - see _LOCK_INDICATOR_PATTERNS. Meant
    for the UI to show a "locked"/"unlocked" indicator and to decide
    whether unlock_with_pin() has anything to do; treat it as informative,
    not authoritative.
    """
    device = _device()
    locked = _is_locked(device)
    return ActionResult(
        ok=True,
        message="Locked." if locked else "Unlocked.",
        data={"locked": locked},
    )


def lock_screen() -> ActionResult:
    """
    Locks the device now by sending the power keyevent - the same as
    pressing the power button once. If a PIN/pattern/password is set,
    Android shows the keyguard as soon as the screen goes off, so this
    reads as "locked" immediately rather than waiting for the idle
    timeout (with no lock type set, it just turns the screen off).
    Mirrors unlock_with_pin()'s no-op-when-nothing-to-do behavior - does
    nothing but report if lock_status() already says locked - so the
    frontend can grey out "Lock" the same way it greys out "Unlock".
    """
    device = _device()
    if _is_locked(device):
        return ActionResult(ok=True, message="Already locked.", data={"locked": True})
    try:
        device.keyevent(_KEY_CODES["power"])
    except adbutils.AdbError as exc:
        raise ActionError(f"Lock failed: {exc}") from exc
    return ActionResult(ok=True, message="Locked.", data={"locked": True})


def set_pin(pin: object, old_pin: object = None) -> ActionResult:
    """
    Sets or changes the device's lock-screen PIN via 'locksettings
    set-pin <pin>' - the same shell command that already worked by hand.
    Pass old_pin when a PIN is already set: 'locksettings' reports a
    rejection (wrong/missing old credential, policy violation, ...) as
    text on stdout rather than a nonzero exit code, so that text is
    surfaced back as-is rather than guessed at.
    """
    if not isinstance(pin, str) or not pin.isdigit() or not (4 <= len(pin) <= 16):
        raise ActionError("pin must be 4-16 digits.")
    if old_pin not in (None, "") and (not isinstance(old_pin, str) or not old_pin.isdigit()):
        raise ActionError("old_pin must be numeric digits.")

    device = _device()
    cmd = ["locksettings", "set-pin"]
    if old_pin:
        cmd += ["--old", old_pin]
    cmd.append(pin)
    try:
        output = device.shell(cmd)
    except adbutils.AdbError as exc:
        raise ActionError(f"Setting PIN failed: {exc}") from exc

    output = (output or "").strip()
    if re.search(r"fail|error|doesn'?t match", output, re.IGNORECASE):
        raise ActionError(f"Setting PIN failed: {output or 'unknown error'}")

    return ActionResult(ok=True, message=output or "PIN set.")


def unlock_with_pin(pin: object) -> ActionResult:
    """
    Wakes the device if asleep, swipes up to dismiss the lock screen's
    curtain (the clock/notification view most stock Android keyguards
    show before the PIN pad itself - without this, a locked-but-awake
    or just-woken device may not have the PIN pad on screen at all yet
    to receive digit keyevents), then enters `pin` via digit KeyEvents
    and Enter - the same blind-entry mechanism as typing a PIN into the
    Screen panel (see send_text's docstring for why KeyEvents, not text
    injection, are what actually reaches a keyguard) - wrapped into one
    call that gets you from "locked, however that looks" to unlocked
    without ever needing to see the screen. Does nothing but report if
    lock_status() already says unlocked - sending digit keyevents (and
    swiping) blind when something else has focus (a text field, a
    game...) would just disrupt it.
    """
    if not isinstance(pin, str) or not pin.isdigit():
        raise ActionError("pin must be numeric digits.")
    device = _device()

    if not _is_locked(device):
        return ActionResult(ok=True, message="Already unlocked.", data={"locked": False})

    try:
        power_output = device.shell(["dumpsys", "power"])
    except adbutils.AdbError as exc:
        raise ActionError(f"Couldn't read power state: {exc}") from exc
    if re.search(r"mWakefulness=Asleep", power_output):
        with suppress(adbutils.AdbError):
            device.keyevent(_KEY_CODES["power"])
        time.sleep(0.3)  # give the wake/screen-on animation a moment

    # window_size() shells out to 'wm size', not screencap - it works
    # even on a FLAG_SECURE surface, so the swipe below can be aimed
    # correctly without ever needing a screenshot. Swiping up when the
    # PIN pad is already showing (no curtain to dismiss) is harmless on
    # a stock AOSP keyguard - so this always runs rather than trying to
    # detect which case we're in blind.
    width, height = _screen_size(device)
    try:
        device.swipe(width // 2, int(height * 0.8), width // 2, int(height * 0.2), duration=0.3)
    except adbutils.AdbError as exc:
        raise ActionError(f"Unlock failed: {exc}") from exc
    time.sleep(0.4)  # let the keyguard's own transition animation settle

    try:
        for digit in pin:
            device.keyevent(_KEY_CODES[digit])
        device.keyevent(_KEY_CODES["enter"])
    except adbutils.AdbError as exc:
        raise ActionError(f"Unlock failed: {exc}") from exc

    return ActionResult(ok=True, message="PIN entered.", data={"locked": False})


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
