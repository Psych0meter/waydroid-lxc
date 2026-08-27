from __future__ import annotations

from flask import Blueprint, jsonify, request

from actions.base import ActionError
from actions.gps import set_location, stop_location
from auth import require_api_key

gps_bp = Blueprint("gps", __name__)


@gps_bp.post("/set")
@require_api_key
def post_set():
    body = request.get_json(silent=True) or {}
    try:
        result = set_location(
            latitude=body.get("latitude"),
            longitude=body.get("longitude"),
            altitude=body.get("altitude", 35.0),
        )
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@gps_bp.post("/stop")
@require_api_key
def post_stop():
    try:
        result = stop_location()
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())
