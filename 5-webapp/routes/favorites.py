from __future__ import annotations

from flask import Blueprint, jsonify, request

from actions.base import ActionError
from actions.favorites import (
    apply_favorite,
    delete_favorite,
    list_favorites,
    save_favorite,
)
from auth import require_api_key

favorites_bp = Blueprint("favorites", __name__)


@favorites_bp.get("/list")
@require_api_key
def get_list():
    # Favorites can hold real addresses (a saved "Home"/"Work" is exactly
    # the point), so listing them is gated the same as any action that
    # touches the device - not left open just because it's a GET.
    try:
        result = list_favorites(request.args.get("q"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@favorites_bp.post("/save")
@require_api_key
def post_save():
    body = request.get_json(silent=True) or {}
    try:
        result = save_favorite(
            name=body.get("name"),
            latitude=body.get("latitude"),
            longitude=body.get("longitude"),
            altitude=body.get("altitude", 35.0),
        )
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@favorites_bp.post("/<favorite_id>/apply")
@require_api_key
def post_apply(favorite_id: str):
    try:
        result = apply_favorite(favorite_id)
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@favorites_bp.delete("/<favorite_id>")
@require_api_key
def delete_one(favorite_id: str):
    try:
        result = delete_favorite(favorite_id)
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())
