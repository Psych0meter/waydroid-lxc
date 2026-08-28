from __future__ import annotations

from flask import Blueprint, jsonify, request

from actions.base import ActionError
from actions.geocode import geocode_address
from auth import require_api_key

geocode_bp = Blueprint("geocode", __name__)


@geocode_bp.post("/search")
@require_api_key
def post_search():
    body = request.get_json(silent=True) or {}
    try:
        result = geocode_address(body.get("address", ""), body.get("limit", 5))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())
