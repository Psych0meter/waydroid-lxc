"""
Waydroid control webapp - Flask entrypoint.

Adding a new action (see README.md for the full walkthrough):
  1. actions/<name>.py   - plain functions, validate input, return an
                            ActionResult or raise ActionError.
  2. routes/<name>.py    - a Blueprint with the HTTP glue for those
                            functions, decorated with @require_api_key
                            for anything that mutates device state.
  3. Register the blueprint below.
No other file needs to change.
"""
from __future__ import annotations

import os

from flask import Flask, jsonify, render_template


def create_app() -> Flask:
    app = Flask(__name__)

    from routes.favorites import favorites_bp
    from routes.geocode import geocode_bp
    from routes.gps import gps_bp

    app.register_blueprint(gps_bp, url_prefix="/api/gps")
    app.register_blueprint(geocode_bp, url_prefix="/api/geocode")
    app.register_blueprint(favorites_bp, url_prefix="/api/favorites")

    @app.get("/")
    def index():
        # WEBAPP_UNIFY_VNC is written into webapp.env by install-webapp.sh
        # (default "yes"): when the unified nginx gateway is in place, noVNC
        # is reachable at /vnc/vnc.html on this same port, so show the link;
        # in legacy mode (WEBAPP_UNIFY_VNC=no) noVNC is a separate
        # port/service entirely and the webapp has no business linking to it.
        show_vnc_link = os.environ.get("WEBAPP_UNIFY_VNC", "yes") == "yes"
        return render_template("index.html", show_vnc_link=show_vnc_link)

    @app.get("/api/health")
    def health():
        return jsonify({"ok": True})

    return app


app = create_app()

if __name__ == "__main__":
    # Only used for local/manual runs (e.g. development) - the systemd
    # service (install-webapp.sh) runs this through gunicorn instead,
    # reading GUNICORN_HOST/GUNICORN_PORT from webapp.env directly in its
    # ExecStart. Read the same two names here so a manual `python3 app.py`
    # against an installed webapp.env picks up the configured bind address
    # instead of silently defaulting to 127.0.0.1:8088.
    host = os.environ.get("GUNICORN_HOST", "127.0.0.1")
    port = int(os.environ.get("GUNICORN_PORT", "8088"))
    app.run(host=host, port=port)
