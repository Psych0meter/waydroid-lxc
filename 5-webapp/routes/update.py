from __future__ import annotations

from flask import Blueprint, jsonify

from actions.base import ActionError
from actions.update import apply_update, check_update, get_status
from auth import require_api_key

update_bp = Blueprint("update", __name__)


@update_bp.get("/check")
@require_api_key
def get_check():
    try:
        result = check_update()
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@update_bp.post("/apply")
@require_api_key
def post_apply():
    try:
        result = apply_update()
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@update_bp.get("/status")
@require_api_key
def get_status_route():
    result = get_status()
    return jsonify(result.to_dict())
