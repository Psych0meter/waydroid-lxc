from __future__ import annotations

from flask import Blueprint, Response, jsonify, request

from actions.base import ActionError
from actions.screen import screenshot, send_key, send_text, swipe, tap
from auth import require_api_key

screen_bp = Blueprint("screen", __name__)


@screen_bp.get("/screenshot")
@require_api_key
def get_screenshot():
    # Binary image, not the usual {ok, message, data} JSON envelope - the
    # webapp fetches this with the API key header and turns it into an
    # object URL for an <img>, since a plain <img src=...> can't send one.
    try:
        png_bytes = screenshot()
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return Response(png_bytes, mimetype="image/png")


@screen_bp.post("/tap")
@require_api_key
def post_tap():
    body = request.get_json(silent=True) or {}
    try:
        tap(x=body.get("x"), y=body.get("y"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify({"ok": True, "message": "Tapped."})


@screen_bp.post("/swipe")
@require_api_key
def post_swipe():
    body = request.get_json(silent=True) or {}
    try:
        swipe(
            x1=body.get("x1"),
            y1=body.get("y1"),
            x2=body.get("x2"),
            y2=body.get("y2"),
            duration_ms=body.get("duration_ms", 300),
        )
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify({"ok": True, "message": "Swiped."})


@screen_bp.post("/text")
@require_api_key
def post_text():
    body = request.get_json(silent=True) or {}
    try:
        send_text(body.get("text"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify({"ok": True, "message": "Text sent."})


@screen_bp.post("/key")
@require_api_key
def post_key():
    body = request.get_json(silent=True) or {}
    try:
        send_key(body.get("key"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify({"ok": True, "message": "Key sent."})
