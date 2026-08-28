"""
Named "favorite" GPS locations: save a point once, then re-apply it
later without re-entering coordinates.

apply_favorite() composes actions.gps.set_location() rather than talking
to change-location.sh directly (see "Adding a new action" in README.md).

Stored as a single JSON file. Every read-modify-write is done under an
exclusive flock on a sibling lock file, and writes are atomic
(write-to-temp + os.replace), so gunicorn's multiple worker processes
can't corrupt or lose an entry racing each other.
"""
from __future__ import annotations

import fcntl  # POSIX-only; this app only ever targets Linux containers
import json
import os
import secrets
import tempfile
from contextlib import contextmanager, suppress
from datetime import datetime, timezone
from typing import Any, Iterator

from .base import ActionError, ActionResult, validate_number
from .gps import set_location

# Sourced from webapp.env by the systemd unit (see install-webapp.sh).
# Application DATA (not config, unlike auth.py's token) - /var/lib
# mirrors where Waydroid itself keeps its own state.
DATA_DIR = os.environ.get("WEBAPP_DATA_DIR", "/var/lib/waydroid-webapp")
DATA_FILE = os.path.join(DATA_DIR, "favorites.json")
LOCK_FILE = DATA_FILE + ".lock"

_MAX_NAME_LENGTH = 100


@contextmanager
def _locked() -> Iterator[None]:
    os.makedirs(DATA_DIR, exist_ok=True)
    # 'a' rather than 'w': creates the lock file if missing, never
    # truncates or touches favorites.json itself - this file exists only
    # to be flock()'d.
    with open(LOCK_FILE, "a", encoding="utf-8") as lock_fh:
        fcntl.flock(lock_fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock_fh, fcntl.LOCK_UN)


def _read_all_locked() -> list[dict[str, Any]]:
    """Must be called from inside a `with _locked():` block."""
    if not os.path.exists(DATA_FILE):
        return []
    try:
        with open(DATA_FILE, "r", encoding="utf-8") as f:
            content = f.read().strip()
        return json.loads(content) if content else []
    except (json.JSONDecodeError, OSError):
        # A corrupted file shouldn't take down the whole feature - treat
        # it as empty rather than raising, same spirit as returning [].
        return []


def _write_all_locked(favorites: list[dict[str, Any]]) -> None:
    """Must be called from inside a `with _locked():` block."""
    os.makedirs(DATA_DIR, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=DATA_DIR, prefix=".favorites-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(favorites, f, indent=2)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, DATA_FILE)  # atomic on the same filesystem
    except Exception:
        with suppress(OSError):
            os.remove(tmp_path)
        raise


def _validate_name(name: object) -> str:
    if not isinstance(name, str):
        raise ActionError("name must be a string.")
    name = name.strip()
    if not name:
        raise ActionError("name must not be empty.")
    if len(name) > _MAX_NAME_LENGTH:
        raise ActionError(f"name must be at most {_MAX_NAME_LENGTH} characters.")
    return name


def list_favorites(query: object = None) -> ActionResult:
    """Lists all favorites, optionally filtered by a substring match on name."""
    with _locked():
        favorites = _read_all_locked()
    if query:
        needle = str(query).strip().lower()
        favorites = [f for f in favorites if needle in f["name"].lower()]
    favorites.sort(key=lambda f: f["name"].lower())
    return ActionResult(
        ok=True,
        message=f"{len(favorites)} favorite(s).",
        data={"favorites": favorites},
    )


def save_favorite(
    name: object, latitude: object, longitude: object, altitude: object = 35.0
) -> ActionResult:
    """Saves a new favorite. Names aren't required to be unique."""
    validated_name = _validate_name(name)
    lat = validate_number(latitude, "latitude", -90.0, 90.0)
    lng = validate_number(longitude, "longitude", -180.0, 180.0)
    alt = validate_number(altitude, "altitude", -1000.0, 100_000.0)

    favorite = {
        "id": secrets.token_hex(8),
        "name": validated_name,
        "latitude": lat,
        "longitude": lng,
        "altitude": alt,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    with _locked():
        favorites = _read_all_locked()
        favorites.append(favorite)
        _write_all_locked(favorites)
    return ActionResult(
        ok=True, message=f"Saved favorite '{validated_name}'.", data={"favorite": favorite}
    )


def delete_favorite(favorite_id: object) -> ActionResult:
    if not isinstance(favorite_id, str) or not favorite_id:
        raise ActionError("favorite id must be a non-empty string.")
    with _locked():
        favorites = _read_all_locked()
        remaining = [f for f in favorites if f["id"] != favorite_id]
        if len(remaining) == len(favorites):
            raise ActionError(f"No favorite with id: {favorite_id}")
        _write_all_locked(remaining)
    return ActionResult(ok=True, message="Favorite deleted.")


def apply_favorite(favorite_id: object) -> ActionResult:
    """Looks up a favorite by id and sets it as the current mock location."""
    if not isinstance(favorite_id, str) or not favorite_id:
        raise ActionError("favorite id must be a non-empty string.")
    with _locked():
        favorites = _read_all_locked()
    match = next((f for f in favorites if f["id"] == favorite_id), None)
    if match is None:
        raise ActionError(f"No favorite with id: {favorite_id}")

    result = set_location(match["latitude"], match["longitude"], match["altitude"])
    result.message = f"Applied favorite '{match['name']}': {result.message}"
    result.data["favorite"] = match
    return result
