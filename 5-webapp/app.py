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

    from routes.geocode import geocode_bp
    from routes.gps import gps_bp

    app.register_blueprint(gps_bp, url_prefix="/api/gps")
    app.register_blueprint(geocode_bp, url_prefix="/api/geocode")

    @app.get("/")
    def index():
        return render_template("index.html")

    @app.get("/api/health")
    def health():
        return jsonify({"ok": True})

    return app


app = create_app()

if __name__ == "__main__":
    # Only used for local/manual runs (e.g. development) - the systemd
    # service (install-webapp.sh) runs this through gunicorn instead,
    # which reads the same WEBAPP_HOST/WEBAPP_PORT from webapp.env.
    host = os.environ.get("WEBAPP_HOST", "127.0.0.1")
    port = int(os.environ.get("WEBAPP_PORT", "8088"))
    app.run(host=host, port=port)
