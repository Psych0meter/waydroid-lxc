# Waydroid control webapp

A small Flask app that exposes GPS mock-location control and adb-based
screen control (view + tap/swipe/text) as an HTTP API plus a browser UI
(Leaflet map for GPS, live screenshot polling for the screen), driving
the existing `4-waydroid-tools/` scripts and the `adbutils` Python
library rather than reimplementing anything they already do.

## Install

Inside the container, after `4-waydroid-tools/setup-gps.sh` has run at
least once (the webapp calls `change-location.sh`, which needs the
mock-location app already installed) and `4-waydroid-tools/enable-adb.sh`
has run (so `adb`/adbutils can authenticate headlessly):

```bash
./install-webapp.sh
```

This creates a Python virtualenv (Flask, gunicorn, requests, adbutils),
vendors Leaflet locally (no CDN, no API key), installs the `adb` package
alongside it, installs the `waydroid-webapp` systemd service bound
directly to `WEBAPP_HOST:WEBAPP_PORT`, and prints the generated API key
plus how to reach the UI. Bound to `127.0.0.1` only unless
`WEBAPP_EXPOSE_LAN=yes` - see "Security" below.

Environment variables (all optional, all re-runnable):

| Variable                | Default                                    | Meaning |
|--------------------------|---------------------------------------------|---------|
| `WEBAPP_EXPOSE_LAN`      | preserves current setting, else `no`         | `yes` binds `0.0.0.0` instead of `127.0.0.1` |
| `WEBAPP_PORT`            | `8088`                                       | the port the webapp listens on |
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

The "Screen" panel below the map gives you a live view of the device:
click "Start screen" to begin polling screenshots (about once a second)
over adb, click/drag on the image to tap or swipe (drag distance under
15px counts as a tap), and use the text field or the Back/Home/Recents
buttons to send input - see "Screen: remote control" below for how this
works.

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

# Screen: current frame (binary PNG, not the usual JSON envelope)
curl http://127.0.0.1:8088/api/screen/screenshot -H "X-API-Key: <token>" -o frame.png

# Screen: tap / swipe / text / key
curl -X POST http://127.0.0.1:8088/api/screen/tap \
  -H "X-API-Key: <token>" -H "Content-Type: application/json" \
  -d '{"x": 500, "y": 900}'

curl -X POST http://127.0.0.1:8088/api/screen/swipe \
  -H "X-API-Key: <token>" -H "Content-Type: application/json" \
  -d '{"start_x": 500, "start_y": 1500, "end_x": 500, "end_y": 400, "duration_ms": 300}'

curl -X POST http://127.0.0.1:8088/api/screen/text \
  -H "X-API-Key: <token>" -H "Content-Type: application/json" \
  -d '{"text": "hello world"}'

curl -X POST http://127.0.0.1:8088/api/screen/key \
  -H "X-API-Key: <token>" -H "Content-Type: application/json" \
  -d '{"key": "back"}'
```

Every response is JSON: `{"ok": true, "message": "...", "data": {...}}`
on success, `{"ok": false, "message": "..."}` with a 4xx status on a
validation or execution failure - except `GET /api/screen/screenshot`,
which returns the raw PNG bytes directly (`Content-Type: image/png`) so
the browser can display it without a base64 round trip; the same
`X-API-Key` requirement still applies, which is why the frontend fetches
it with `fetch()` rather than a plain `<img src>` (a browser-set `src`
can't carry a custom header).

## Architecture

```
app.py            Flask app factory; registers one blueprint per action domain.
auth.py           API-key generation/check, shared by every mutating route.
actions/
  base.py         ActionResult / ActionError / run_script() / validate_number() - shared by every action.
  gps.py          Wraps 4-waydroid-tools/change-location.sh.
  geocode.py      Wraps OpenStreetMap Nominatim (address -> coordinates).
  favorites.py    Named saved locations (JSON file store); "apply" calls actions/gps.py's set_location().
  screen.py       Screenshot/tap/swipe/text/key, via adbutils talking to the device directly.
routes/
  gps.py          Blueprint: HTTP glue for actions/gps.py.
  geocode.py      Blueprint: HTTP glue for actions/geocode.py.
  favorites.py    Blueprint: HTTP glue for actions/favorites.py.
  screen.py       Blueprint: HTTP glue for actions/screen.py.
templates/, static/  Leaflet-based single-page UI (vendored Leaflet, no CDN) plus the Screen panel's JS/CSS.
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

## Screen: remote control

An earlier version of this repo screen-shared the container's Wayland
output over `wayvnc`/noVNC, fronted by nginx so it shared a port with
this webapp. That's gone: `actions/screen.py` talks to the device
directly over adb via the `adbutils` Python library instead, so there's
no separate screen-sharing service, no nginx gateway, and no unauthenticated
VNC view to worry about (every screen action goes through the same
API-key-gated routes as everything else).

* `GET /api/screen/screenshot` calls `AdbDevice.screenshot()` (adbutils
  wraps `adb exec-out screencap`) and returns the PNG bytes directly.
  The frontend polls this roughly once a second while the Screen panel
  is open, converting each response to a `Blob` URL and revoking the
  previous one so repeated polling doesn't leak memory.
* `POST /api/screen/tap` / `/swipe` call `AdbDevice.click()` /
  `AdbDevice.swipe()`. The frontend disambiguates a single
  pointerdown/pointerup pair by drag distance (in device-pixel space,
  scaled from the displayed image's `naturalWidth`/`naturalHeight` vs.
  its on-screen size): under 15px is a tap, otherwise a swipe.
* `POST /api/screen/text` calls `AdbDevice.send_keys()`; `POST
  /api/screen/key` calls `AdbDevice.keyevent()` for a small fixed set of
  named keys (`back`, `home`, `recents`, `enter`, `backspace`, `power`,
  `volume_up`, `volume_down`) rather than accepting arbitrary keycodes.
* Connection handling: `actions/screen.py` first checks
  `adbutils.adb.device_list()` (never raises, even with zero devices
  connected) and only runs `waydroid adb connect` (the same reconnect
  `4-waydroid-tools/change-location.sh` uses) when that list is empty -
  so the common case (device already connected) stays fast, while a
  container restart or dropped adb connection is recovered from
  automatically on the next request.

adbutils itself is pure Python, but it shells out to the real `adb`
binary to start the local adb server if one isn't already running -
that's why `install-webapp.sh` still installs the `adb` apt package
even though the webapp no longer needs `websockify`/`novnc`.

## Security

Same "documented trade-off, LAN-only trust boundary" posture as the rest
of this repo (see the top-level README's "Security" section):

* **API-key auth, not a full account system**: every `/api/*` route that
  mutates device state OR could expose something private (this includes
  `GET /api/favorites/list` - a saved "Home"/"Work" favorite is a real
  address - and `GET /api/screen/screenshot`, which shows whatever is on
  the device's screen) requires a random per-deployment token
  (`X-API-Key` header or `?api_key=` query param), generated on first run
  and stored at `/etc/waydroid-webapp/api-token` (mode 600). This is a
  security *improvement* over the old noVNC-based setup, where the
  remote screen had no authentication of its own at all - now the screen
  view is gated exactly like every other action. There's still no rate
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
  passed. Since there's no separate screen-sharing service anymore, this
  one bind is the entire external attack surface.
* **adb itself has no authentication once `ro.adb.secure=0` is set**
  (`4-waydroid-tools/enable-adb.sh`, applied by default) - but adbutils
  connects to the container's local adb server (`127.0.0.1:5037`), which
  only the webapp process and anyone with shell access to the container
  can reach; this doesn't add external exposure beyond what
  `enable-adb.sh` already documents in the top-level README.
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
