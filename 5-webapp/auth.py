"""
Minimal API-key auth for the /api/* routes.

Every route that mutates device state or exposes private data (saved
favorites, screenshots) requires a per-deployment random token, generated
on first run and stored on disk (mode 600). See README, "Security".
"""
from __future__ import annotations

import os
import secrets
from functools import wraps
from typing import Callable

from flask import jsonify, request

TOKEN_FILE = os.environ.get("WEBAPP_TOKEN_FILE", "/etc/waydroid-webapp/api-token")


def load_or_create_token() -> str:
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
            existing = f.read().strip()
        if existing:
            return existing

    token = secrets.token_urlsafe(32)
    token_dir = os.path.dirname(TOKEN_FILE)
    if token_dir:
        os.makedirs(token_dir, exist_ok=True)
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        f.write(token + "\n")
    os.chmod(TOKEN_FILE, 0o600)
    return token


API_TOKEN = load_or_create_token()


def require_api_key(view: Callable) -> Callable:
    """
    Requires a valid token via the 'X-API-Key' header (used by the web
    UI) or an 'api_key' query parameter (for quick curl testing).
    """

    @wraps(view)
    def wrapped(*args, **kwargs):
        supplied = request.headers.get("X-API-Key") or request.args.get("api_key")
        if not supplied or not secrets.compare_digest(supplied, API_TOKEN):
            return jsonify({"ok": False, "message": "Missing or invalid API key."}), 401
        return view(*args, **kwargs)

    return wrapped
