"""
Minimal API-key auth for the /api/* routes.

This app can execute real Android actions (currently GPS, potentially
more later - see actions/), so unlike a read-only status page it
shouldn't be reachable by anyone who can merely route a packet to it.
Rather than a full user/session system, every write action requires a
per-deployment random token, generated on first run and stored on disk
(mode 600) - the same "one bearer secret, no accounts" trade-off already
used elsewhere in this repo's spirit of documented, minimal-friction
security (see README "Security"). The token is printed by
install-webapp.sh and readable afterwards at TOKEN_FILE.
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
    Decorator for routes that mutate device state. Accepts the token via
    an 'X-API-Key' header (preferred) or an 'api_key' query parameter
    (convenience for quick curl testing) - the bundled web UI stores the
    key in the browser's localStorage after it's entered once and sends
    it as a header on every request.
    """

    @wraps(view)
    def wrapped(*args, **kwargs):
        supplied = request.headers.get("X-API-Key") or request.args.get("api_key")
        if not supplied or not secrets.compare_digest(supplied, API_TOKEN):
            return jsonify({"ok": False, "message": "Missing or invalid API key."}), 401
        return view(*args, **kwargs)

    return wrapped
