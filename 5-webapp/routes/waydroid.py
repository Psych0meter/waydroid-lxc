from __future__ import annotations

from flask import Blueprint, jsonify

from actions.base import ActionError
from actions.waydroid_status import get_status, restart
from auth import require_api_key

waydroid_bp = Blueprint("waydroid", __name__)


@waydroid_bp.get("/status")
@require_api_key
def get_status_route():
    result = get_status()
    return jsonify(result.to_dict())


@waydroid_bp.post("/restart")
@require_api_key
def post_restart():
    try:
        result = restart()
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())
