from __future__ import annotations

from flask import Blueprint, Response, jsonify, request

from actions.base import ActionError
from actions.screen import (
    kill_all_apps,
    lock_screen,
    lock_status,
    screenshot,
    send_key,
    send_text,
    set_pin,
    swipe,
    tap,
    unlock_with_pin,
)
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
        result = tap(x=body.get("x"), y=body.get("y"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@screen_bp.post("/swipe")
@require_api_key
def post_swipe():
    body = request.get_json(silent=True) or {}
    try:
        result = swipe(
            x1=body.get("x1"),
            y1=body.get("y1"),
            x2=body.get("x2"),
            y2=body.get("y2"),
            duration_ms=body.get("duration_ms", 300),
        )
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@screen_bp.post("/text")
@require_api_key
def post_text():
    body = request.get_json(silent=True) or {}
    try:
        result = send_text(body.get("text"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@screen_bp.post("/key")
@require_api_key
def post_key():
    body = request.get_json(silent=True) or {}
    try:
        result = send_key(body.get("key"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@screen_bp.post("/kill-all")
@require_api_key
def post_kill_all():
    try:
        result = kill_all_apps()
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@screen_bp.get("/lock-status")
@require_api_key
def get_lock_status():
    try:
        result = lock_status()
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@screen_bp.post("/set-pin")
@require_api_key
def post_set_pin():
    body = request.get_json(silent=True) or {}
    try:
        result = set_pin(pin=body.get("pin"), old_pin=body.get("old_pin"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@screen_bp.post("/unlock")
@require_api_key
def post_unlock():
    body = request.get_json(silent=True) or {}
    try:
        result = unlock_with_pin(pin=body.get("pin"))
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())


@screen_bp.post("/lock")
@require_api_key
def post_lock():
    try:
        result = lock_screen()
    except ActionError as exc:
        return jsonify({"ok": False, "message": str(exc)}), 400
    return jsonify(result.to_dict())
