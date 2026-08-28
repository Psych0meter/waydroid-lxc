"""
Self-update: wraps update-webapp.sh so the webapp can check for and
apply a new version of itself from the UI.

check_update() runs the script synchronously (a bounded network call -
one shallow git clone) and returns its result directly. apply_update()
can't do the same: applying an update restarts the very systemd service
this process runs under, killing whatever request handler called it. So
it launches update-webapp.sh as a fully detached subprocess
(start_new_session=True - the equivalent of setsid) and returns
immediately; the script survives the restart it triggers and keeps
running in the background, writing its outcome to STATUS_FILE as it
goes. The frontend polls get_status() (routes/update.py) across the
restart to learn how it went.
"""
from __future__ import annotations

import json
import os
import subprocess
from typing import Any

from .base import ActionError, ActionResult

# Sibling of app.py - see waydroid-webapp.service (WorkingDirectory).
UPDATE_SCRIPT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "update-webapp.sh")

# Same default and override variable update-webapp.sh itself uses, so
# both sides always agree on where the status file lives without the
# webapp needing to know CONF_DIR separately.
STATUS_FILE = os.environ.get("WEBAPP_UPDATE_STATUS_FILE", "/etc/waydroid-webapp/update-status.json")
UPDATE_LOG_FILE = os.environ.get("WEBAPP_UPDATE_LOG_FILE", "/var/log/waydroid-webapp-update.log")

_CHECK_TIMEOUT = 60  # bounded by the shallow git clone update-webapp.sh does


def check_update() -> ActionResult:
    """
    Runs `update-webapp.sh --check --json` and returns its parsed
    result. Raises ActionError if the script itself couldn't run or
    didn't produce valid JSON (e.g. no network access to GitHub).
    """
    try:
        proc = subprocess.run(
            [UPDATE_SCRIPT, "--check", "--json"],
            capture_output=True,
            text=True,
            timeout=_CHECK_TIMEOUT,
            check=False,
        )
    except FileNotFoundError as exc:
        raise ActionError(f"update-webapp.sh not found at {UPDATE_SCRIPT}.") from exc
    except subprocess.TimeoutExpired as exc:
        raise ActionError(f"Timed out after {_CHECK_TIMEOUT}s checking for updates.") from exc

    try:
        payload = json.loads((proc.stdout or "").strip().splitlines()[-1])
    except (ValueError, IndexError) as exc:
        detail = (proc.stderr or proc.stdout or "no output").strip()
        raise ActionError(f"Update check failed: {detail}") from exc

    if "error" in payload:
        raise ActionError(payload["error"])

    return ActionResult(ok=True, message="Update check complete.", data=payload)


def apply_update() -> ActionResult:
    """
    Starts update-webapp.sh in the background and returns immediately -
    it does not wait for (or guarantee) an update actually happens; call
    check_update() first to know whether one is available. Refuses to
    start a second run while one is already in progress (per
    STATUS_FILE), since two concurrent updates would race on the same
    backup directory - but only when that run's process (tracked by
    pid, see _write_status below) is actually still alive.
    waydroid-webapp.service's KillMode=process is what normally keeps
    that process running across its own self-restart, but it isn't the
    only way a background run can die mid-flight (a host reboot, an OOM
    kill, `kill -9` by hand) - without this liveness check, any of those
    would leave STATUS_FILE stuck on "running" forever, permanently
    blocking every future update with this same error and requiring
    someone to notice and delete the file by hand.
    """
    status = _read_status()
    if status.get("state") == "running" and _pid_is_running(status.get("pid")):
        raise ActionError("An update is already in progress.")

    # Written here, synchronously, before the background process even
    # starts - otherwise a status poll landing in the gap between this
    # function returning and update-webapp.sh actually running (process
    # scheduling, not guaranteed instant) would read whatever STATUS_FILE
    # still held from the *previous* run (e.g. "success") and treat it as
    # this run's outcome. update-webapp.sh overwrites this with its own,
    # more detailed "running" entry moments later. pid is filled in right
    # after Popen returns (see below) - not knowable yet at this point.
    _write_status({"state": "running"})

    os.makedirs(os.path.dirname(UPDATE_LOG_FILE), exist_ok=True)
    log_fh = open(UPDATE_LOG_FILE, "a", encoding="utf-8")
    try:
        proc = subprocess.Popen(
            [UPDATE_SCRIPT],
            stdin=subprocess.DEVNULL,
            stdout=log_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,  # survives this process being killed by its own restart
            close_fds=True,
        )
    except FileNotFoundError as exc:
        raise ActionError(f"update-webapp.sh not found at {UPDATE_SCRIPT}.") from exc
    finally:
        log_fh.close()

    # Record the pid against the "running" state we already wrote, so a
    # later apply_update() call can tell a genuinely-in-progress run
    # apart from a stale one (see the liveness check above). update-
    # webapp.sh overwrites this whole file moments later with its own
    # richer "running" entry (from/to/ref/stage) that doesn't include a
    # pid - that's fine, by then the run is far enough along that a
    # concurrent apply_update() call would already see it via the file
    # actually existing and mtime moving, and once it reaches "success"
    # or "failed" the pid question no longer matters.
    _write_status({"state": "running", "pid": proc.pid})

    return ActionResult(ok=True, message="Update started - the webapp will restart shortly.")


def _pid_is_running(pid: Any) -> bool:
    """
    True if `pid` (as recorded in STATUS_FILE - see apply_update() and
    update-webapp.sh's write_status()) is a live process that is
    actually update-webapp.sh, not just some unrelated process that
    happens to have reused the same pid after the real one exited (pids
    wrap around and get reused - a stale STATUS_FILE could in principle
    be arbitrarily old). /proc/<pid>/cmdline is Linux-only, which this
    project already assumes throughout (systemd, adb, waydroid).
    """
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            cmdline = f.read()
    except FileNotFoundError:
        return False  # no such pid - definitely not running
    except OSError:
        # Some other reason /proc/<pid>/cmdline couldn't be read (e.g. a
        # permissions oddity) - fall back to a plain liveness check
        # rather than treating an unreadable-but-real process as stale.
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    return b"update-webapp.sh" in cmdline


def _write_status(data: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(STATUS_FILE), exist_ok=True)
    tmp = STATUS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, STATUS_FILE)


def _read_status() -> dict[str, Any]:
    if not os.path.exists(STATUS_FILE):
        return {"state": "idle"}
    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"state": "idle"}


def get_status() -> ActionResult:
    """Returns the outcome of the most recent apply_update() run, if any."""
    return ActionResult(ok=True, message="", data=_read_status())
