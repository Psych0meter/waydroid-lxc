# Waydroid control webapp

A small Flask app that exposes GPS mock-location control (and, later,
other Android/Waydroid interactions) as an HTTP API plus a Leaflet
map-based web UI, driving the existing `4-waydroid-tools/` scripts
rather than reimplementing anything they already do.

## Install

Inside the container, after `4-waydroid-tools/setup-gps.sh` has run at
least once (the webapp calls `change-location.sh`, which needs the
mock-location app already installed):

```bash
./install-webapp.sh
```

This creates a Python virtualenv, vendors Leaflet locally (no CDN, no API
key), installs the `waydroid-webapp` systemd service, and prints the
generated API key plus how to reach the UI. By default the service binds
`127.0.0.1` only - see "Security" below.

Environment variables (all optional, all re-runnable):

| Variable              | Default                                    | Meaning |
|------------------------|---------------------------------------------|---------|
| `WEBAPP_EXPOSE_LAN`    | preserves current setting, else `no`         | `yes` binds `0.0.0.0` instead of `127.0.0.1` |
| `WEBAPP_PORT`          | `8088`                                       | TCP port |
| `WAYDROID_TOOLS_DIR`   | `/opt/waydroid-lxc-deploy/4-waydroid-tools`  | where `change-location.sh` lives |
| `LEAFLET_VERSION`      | `1.9.4`                                      | pinned Leaflet release to vendor |

## Using it

Open the UI (see the URL `install-webapp.sh` prints), click "API key" and
paste in the key it printed (also readable afterwards at
`/etc/waydroid-webapp/api-token` on the container), then either click a
point on the map, drag the marker, or search an address - "Set location"
calls `change-location.sh` with the resulting coordinates.

Or drive the API directly:

```bash
# Set a location
curl -X POST http://127.0.0.1:8088/api/gps/set \
  -H "X-API-Key: <token>" -H "Content-Type: application/json" \
  -d '{"latitude": 48.8584, "longitude": 2.2945, "altitude": 35.0}'

# Stop sending mock fixes
curl -X POST http://127.0.0.1:8088/api/gps/stop -H "X-API-Key: <token>"

# Look up coordinates for an address (OpenStreetMap Nominatim)
curl -X POST http://127.0.0.1:8088/api/geocode/search \
  -H "X-API-Key: <token>" -H "Content-Type: application/json" \
  -d '{"address": "Eiffel Tower, Paris"}'
```

Every response is JSON: `{"ok": true, "message": "...", "data": {...}}`
on success, `{"ok": false, "message": "..."}` with a 4xx status on a
validation or execution failure.

## Architecture

```
app.py            Flask app factory; registers one blueprint per action domain.
auth.py           API-key generation/check, shared by every mutating route.
actions/
  base.py         ActionResult / ActionError / run_script() - shared by every action.
  gps.py          Wraps 4-waydroid-tools/change-location.sh.
  geocode.py      Wraps OpenStreetMap Nominatim (address -> coordinates).
routes/
  gps.py          Blueprint: HTTP glue for actions/gps.py.
  geocode.py      Blueprint: HTTP glue for actions/geocode.py.
templates/, static/  Leaflet-based single-page UI (vendored Leaflet, no CDN).
```

`actions/` holds plain functions with no Flask/HTTP knowledge: they take
already-validated-by-themselves arguments, return an `ActionResult`, or
raise `ActionError` on any expected failure (bad input, the wrapped
script exiting non-zero, a timeout). `routes/` is pure HTTP glue - parse
the request, call the action, turn `ActionError` into a 400 JSON body.
Keeping the split means an action stays testable and reusable (a CLI, a
test, a future non-HTTP entry point) without dragging Flask into it, and
adding a capability never means editing a shared file.

### Adding a new action

Say you want to add "launch an app" later:

1. `actions/app_control.py` - a `launch_app(package_name)` function that
   validates `package_name` and calls `run_script([...])` (from
   `actions/base.py`) to drive `adb shell am start ...` or a new
   `4-waydroid-tools/` script, exactly like `actions/gps.py` does for
   `change-location.sh`.
2. `routes/app_control.py` - a `Blueprint` with a `POST /launch` route,
   decorated `@require_api_key`, that reads the request body and calls
   `launch_app`, exactly like `routes/gps.py`.
3. In `app.py`: `app.register_blueprint(app_control_bp,
   url_prefix="/api/app")`.
4. Add a form/button to `templates/index.html` and a handler in
   `static/js/app.js` if it needs a UI, following the existing
   `coords-form`/`apiPost` pattern.

No existing file's logic needs to change - `auth.py`, `actions/base.py`
and the rest of the routing stay exactly as they are.

## Security

Same "documented trade-off, LAN-only trust boundary" posture as the rest
of this repo (see the top-level README's "Security" section):

* **API-key auth, not a full account system**: every `/api/*` POST route
  requires a random per-deployment token (`X-API-Key` header or
  `?api_key=` query param), generated on first run and stored at
  `/etc/waydroid-webapp/api-token` (mode 600). There's no rate limiting
  or key rotation - treat the key like a password, and regenerate it by
  deleting that file and restarting the service if it leaks.
* **The `/` page itself has no login** - it's just static HTML/JS; every
  action it triggers still goes through the API-key-gated endpoints, so
  loading the page alone can't control the device.
* **Bound to 127.0.0.1 by default** - use an SSH tunnel
  (`ssh -L 8088:127.0.0.1:8088 ...`) unless `WEBAPP_EXPOSE_LAN=yes` was
  passed, same as noVNC.
* **Nominatim (address search) is a public, unauthenticated third-party
  service** - subject to its usage policy (roughly 1 request/second,
  descriptive User-Agent, no heavy automated use); fine for occasional
  interactive use, not for bulk geocoding. See
  `actions/geocode.py` for the exact policy link.
* **`change-location.sh`/other wrapped scripts are always invoked as an
  argv list, never through a shell** (`actions/base.py`'s
  `run_script()`) - user-supplied values can't be interpreted as shell
  syntax no matter what characters they contain; input is additionally
  validated (numeric range checks, length limits) before it ever reaches
  a subprocess call.
