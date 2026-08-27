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
generated API key plus how to reach the UI. By default (see "Unified
webapp + noVNC gateway" below) it also installs nginx as the single
external entry point for both the webapp and noVNC, bound to `127.0.0.1`
only unless `WEBAPP_EXPOSE_LAN=yes` - see "Security" below.

Environment variables (all optional, all re-runnable):

| Variable                | Default                                    | Meaning |
|--------------------------|---------------------------------------------|---------|
| `WEBAPP_EXPOSE_LAN`      | preserves current setting, else `no`         | `yes` binds `0.0.0.0` instead of `127.0.0.1` (on nginx's listener when `WEBAPP_UNIFY_VNC=yes`, on gunicorn's own otherwise) |
| `WEBAPP_PORT`            | `8088`                                       | the port you actually connect to - stable across both modes |
| `WEBAPP_UNIFY_VNC`       | `yes`                                        | `yes` fronts both the webapp and noVNC with nginx on one port; `no` keeps the old two-port setup |
| `WEBAPP_INTERNAL_PORT`   | `8089`                                       | only used when `WEBAPP_UNIFY_VNC=yes`: gunicorn's own loopback-only port, behind nginx, never reachable directly |
| `WAYDROID_TOOLS_DIR`     | `/opt/waydroid-lxc-deploy/4-waydroid-tools`  | where `change-location.sh` lives |
| `WEBAPP_DATA_DIR`        | `/var/lib/waydroid-webapp`                   | where `favorites.json` is stored |
| `LEAFLET_VERSION`        | `1.9.4`                                      | pinned Leaflet release to vendor |

## Using it

Open the UI (see the URL `install-webapp.sh` prints), click "API key" and
paste in the key it printed (also readable afterwards at
`/etc/waydroid-webapp/api-token` on the container), then either click a
point on the map, drag the marker, or search an address - "Set location"
calls `change-location.sh` with the resulting coordinates. "Save
favorite" saves whatever's currently in the coordinate fields under a
name of your choice; the favorites list below it filters as you type and
each entry re-applies its saved location with one click.

When `WEBAPP_UNIFY_VNC=yes` (the default), a "Remote screen" link appears
in the header next to "API key", opening noVNC at `/vnc/vnc.html` in a
new tab - see "Unified webapp + noVNC gateway" below.

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

# Favorites: save, list (optionally filtered), apply, delete
curl -X POST http://127.0.0.1:8088/api/favorites/save \
  -H "X-API-Key: <token>" -H "Content-Type: application/json" \
  -d '{"name": "Eiffel Tower", "latitude": 48.8584, "longitude": 2.2945}'

curl "http://127.0.0.1:8088/api/favorites/list?q=eiffel" -H "X-API-Key: <token>"

curl -X POST http://127.0.0.1:8088/api/favorites/<id>/apply -H "X-API-Key: <token>"

curl -X DELETE http://127.0.0.1:8088/api/favorites/<id> -H "X-API-Key: <token>"
```

Every response is JSON: `{"ok": true, "message": "...", "data": {...}}`
on success, `{"ok": false, "message": "..."}` with a 4xx status on a
validation or execution failure.

## Architecture

```
app.py            Flask app factory; registers one blueprint per action domain.
auth.py           API-key generation/check, shared by every mutating route.
actions/
  base.py         ActionResult / ActionError / run_script() / validate_number() - shared by every action.
  gps.py          Wraps 4-waydroid-tools/change-location.sh.
  geocode.py      Wraps OpenStreetMap Nominatim (address -> coordinates).
  favorites.py    Named saved locations (JSON file store); "apply" calls actions/gps.py's set_location().
routes/
  gps.py          Blueprint: HTTP glue for actions/gps.py.
  geocode.py      Blueprint: HTTP glue for actions/geocode.py.
  favorites.py    Blueprint: HTTP glue for actions/favorites.py.
templates/, static/  Leaflet-based single-page UI (vendored Leaflet, no CDN).
nginx-waydroid-webapp.conf  Template for the unified gateway's nginx site (installed when WEBAPP_UNIFY_VNC=yes) - see below.
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

`actions/favorites.py` is a real (not hypothetical) example of this same
pattern, with one addition worth knowing about: an action can call
another action directly - `apply_favorite()` just calls
`actions.gps.set_location()` with the favorite's saved coordinates
rather than reimplementing anything. Reach for that whenever a new
action is really "do an existing action, with different inputs" (a
scheduled/recurring version of an existing action, a batch variant,
etc.) instead of duplicating logic.

## Unified webapp + noVNC gateway

By default (`WEBAPP_UNIFY_VNC=yes`), `install-webapp.sh` installs nginx
as a single external gateway in front of both this webapp and noVNC, so
only one port needs to be reachable or tunneled for everything:

* `/` (and everything else not matched below) proxies to gunicorn, which
  now binds `127.0.0.1:${WEBAPP_INTERNAL_PORT}` (default `8089`) instead
  of being reachable directly.
* `/vnc/` proxies to websockify's static file server (`vnc.html`, its
  `app/`/`core/`/`vendor/` assets), with the `/vnc/` prefix stripped so
  the files resolve exactly as noVNC expects.
* `/websockify` proxies noVNC's websocket connection, as its own
  top-level location - **not** nested under `/vnc/`. This isn't
  arbitrary: the installed noVNC package (`app/ui.js`) hardcodes its
  websocket path setting to the literal string `websockify` and builds
  the connection URL as `ws(s)://<page's own host:port>/websockify` -
  root-absolute, regardless of what subpath `vnc.html` was itself loaded
  from. Nesting it under `/vnc/websockify` would silently break the
  connection, since the browser never asks for that path.

This also moves `novnc.service` to bind `127.0.0.1:6080`/`5900`
permanently - `install-webapp.sh` rewrites its `ExecStart=` on every run
- so `3-services/02-install-services.sh`'s own `EXPOSE_LAN` toggle for
noVNC stops being the thing that controls external reachability;
`WEBAPP_EXPOSE_LAN` (this script) is now the single switch for both
services, since nginx is the only remaining exposure point.

Pass `WEBAPP_UNIFY_VNC=no` to skip all of this and keep the old
two-port setup, where the webapp and noVNC are each reachable/exposed
independently and noVNC's own `EXPOSE_LAN` in `02-install-services.sh`
applies as before. Requires `3-services/02-install-services.sh` to have
already installed `novnc.service` (the script errors out early if it
hasn't, rather than installing a gateway with nothing behind half of it).

## Security

Same "documented trade-off, LAN-only trust boundary" posture as the rest
of this repo (see the top-level README's "Security" section):

* **API-key auth, not a full account system**: every `/api/*` route that
  mutates device state OR could expose something private (this now
  includes `GET /api/favorites/list` - a saved "Home"/"Work" favorite is
  a real address) requires a random per-deployment token (`X-API-Key`
  header or `?api_key=` query param), generated on first run and stored
  at `/etc/waydroid-webapp/api-token` (mode 600). There's no rate
  limiting or key rotation - treat the key like a password, and
  regenerate it by deleting that file and restarting the service if it
  leaks.
* **Favorites are stored in plain JSON**, unencrypted, at
  `/var/lib/waydroid-webapp/favorites.json` (mode 700 directory) -
  anyone with root on the container (or a backup of it) can read saved
  names/coordinates regardless of the API key. Fine for a personal
  convenience list; don't save anything there you wouldn't want visible
  to anyone who can already `pct exec` into this container.
* **The `/` page itself has no login** - it's just static HTML/JS; every
  action it triggers still goes through the API-key-gated endpoints, so
  loading the page alone can't control the device.
* **Bound to 127.0.0.1 by default** - use an SSH tunnel
  (`ssh -L 8088:127.0.0.1:8088 ...`) unless `WEBAPP_EXPOSE_LAN=yes` was
  passed. With `WEBAPP_UNIFY_VNC=yes` (the default) this single bind
  controls both the webapp and noVNC, since nginx is the only thing
  either is reachable through; gunicorn and `novnc.service` both bind
  `127.0.0.1` unconditionally, and the stock nginx default site (port
  80) is disabled so it doesn't sit there as an unused extra open port.
* **`/vnc/vnc.html` (noVNC) has no authentication of its own, unchanged
  from before** - unifying it behind nginx doesn't add a login to it;
  anyone who can reach the webapp's port can also reach the remote
  screen. The API key gates webapp *actions* only, not the VNC view -
  treat exposure of this port (`WEBAPP_EXPOSE_LAN=yes`) the same as you
  would have treated exposing noVNC directly.
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
