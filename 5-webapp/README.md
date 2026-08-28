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

## Updating

Once installed, check for and apply a newer version of the webapp
straight from GitHub, without redeploying the whole container:

```bash
./update-webapp.sh          # update if a newer commit is available
./update-webapp.sh --check  # just report whether one is, without applying it
```

It clones the target ref (`main` by default), backs up the current
install, syncs in the new `5-webapp/` files, reinstalls Python
dependencies, regenerates the systemd unit, restarts the service, and
verifies `/api/health` responds - rolling back to the previous version
automatically if any step fails. Everything outside `5-webapp/` (the API
key, `favorites.json`, the vendored Leaflet, device spoofing, GPS setup)
is untouched. Track a fork or another branch with `--ref <branch>` or
the `WEBAPP_REPO_URL`/`WEBAPP_UPDATE_REF` environment variables. The
installed version is recorded at
`/etc/waydroid-webapp/installed-version`; a deployment installed via
`0-deploy-all.sh` starts with no version tracked, so its first
`update-webapp.sh` run always applies (installing whatever's currently
at the tracked ref) and records a real version from then on.

### From the UI

The same mechanism is also wired into the web UI: the "Update" button in
the header checks GitHub and, on load and every hour after that, checks
automatically - if a newer commit is available, a dialog offers to
install it. Confirming calls `POST /api/update/apply`
(`actions/update.py`), which launches `update-webapp.sh` as a detached
background process and returns immediately, since applying the update
restarts the very service handling the request. The page then polls
`GET /api/update/status` - tolerating the brief connection drop while
the service restarts - until the script reports success or failure, and
reloads itself once the new version is confirmed up. A failed update
(rolled back automatically, same as the CLI) is reported in the dialog
without reloading. Only one update can run at a time; `apply` refuses a
second request while `/etc/waydroid-webapp/update-status.json` still
says `"state": "running"`.

## Using it

Open the UI (see the URL `install-webapp.sh` prints) and click "API key"
to paste in the key it printed (also readable afterwards at
`/etc/waydroid-webapp/api-token` on the container).

The "Screen" panel at the top gives you a live view of the device: click
"Start screen" to begin polling screenshots over adb, click/drag on the
image to tap or swipe (drag distance under 15px counts as a tap), use the
text field or the Back/Home/Recents buttons to send input, or click the
image once and just type on your own keyboard - it forwards keystrokes
directly (letters/digits/punctuation as typed text, plus
Backspace/Enter/Tab/Escape/Delete/arrows/Space as proper key events) to
whatever's focused on the device, the same as a keyboard plugged into it.
The image shows a highlighted border while it has this keyboard focus;
click anywhere else to release it back to normal page navigation.
"Stop screen" stops polling and clears the view, rather than leaving the
last frame frozen on screen. See "Screen: remote control" below for how
both of these work.

Below it, the "Location" panel controls GPS mock-location: click a point
on the map, drag the marker, or search an address - "Set location" calls
`change-location.sh` with the resulting coordinates. "Save favorite"
saves whatever's currently in the coordinate fields under a name of your
choice; the favorites list below it filters as you type and each entry
re-applies its saved location with one click.

The refresh rate is adaptive by default: it automatically speeds up to
4 polls/second for a few seconds after each tap/swipe/key/text, then
settles back down to an "idle" rate you control with the drag bar above
the image (0.2s-3s, default 1s) - so it feels closer to a live feed while
you're actually interacting, without polling that fast (and taxing
adb/the container) while you're just watching. For something closer to
an actual video feed regardless of activity, check "Real-time" next to
the drag bar - it polls continuously, back-to-back, as fast as the
container can produce and the browser can decode frames (the indicator
shows the achieved rate, e.g. "real-time (~8.0 fps)"); it's the most
CPU/adb load of any mode, by design, so it's off by default.

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
  -d '{"x1": 500, "y1": 1500, "x2": 500, "y2": 400, "duration_ms": 300}'

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
  update.py       Wraps update-webapp.sh - see "Updating" above. Not a run_script() action:
                  apply_update() launches a detached background process instead of waiting
                  for a result, since the update restarts this very process.
routes/
  gps.py          Blueprint: HTTP glue for actions/gps.py.
  geocode.py      Blueprint: HTTP glue for actions/geocode.py.
  favorites.py    Blueprint: HTTP glue for actions/favorites.py.
  screen.py       Blueprint: HTTP glue for actions/screen.py.
  update.py       Blueprint: HTTP glue for actions/update.py.
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

`actions/screen.py` talks to the device directly over adb via the
`adbutils` Python library - no separate screen-sharing service, no
reverse-proxy gateway, and no unauthenticated view: every screen action
goes through the same API-key-gated routes as everything else.

* `GET /api/screen/screenshot` calls `AdbDevice.screenshot()` (adbutils
  wraps `adb exec-out screencap`) and returns the PNG bytes directly. The
  frontend polls this at an adaptive rate while the Screen panel is open:
  a fast 250ms while you're actively tapping/swiping/typing (recent
  activity, tracked client-side), decaying after about 4 seconds of no
  input to an "idle" rate set by the drag bar (200ms-3000ms, default
  1000ms) - or, with the "Real-time" checkbox on, continuous back-to-back
  polling with no fixed delay at all (overrides both the boost and idle
  rates; falls back to the 250ms rate after a failed request instead of
  retrying in a tight error loop). Every fetched frame is converted to a
  `Blob` URL and the previous one revoked, so a long polling session
  doesn't leak one blob per screenshot.
* `POST /api/screen/tap` / `/swipe` call `AdbDevice.click()` /
  `AdbDevice.swipe()`. The frontend disambiguates a single
  pointerdown/pointerup pair by drag distance (in device-pixel space,
  scaled from the displayed image's `naturalWidth`/`naturalHeight` vs.
  its on-screen size): under 15px is a tap, otherwise a swipe.
* `POST /api/screen/text` calls `AdbDevice.send_keys()`; `POST
  /api/screen/key` calls `AdbDevice.keyevent()` for a fixed set of named
  keys (`back`, `home`, `recents`, `enter`, `backspace`, `power`,
  `volume_up`, `volume_down`, `tab`, `space`, `escape`, `delete`, `up`,
  `down`, `left`, `right`) rather than accepting arbitrary keycodes.
* **Host-keyboard passthrough**: clicking the screen image gives it
  `tabindex="0"` focus (shown by a highlighted border), which arms a
  `keydown` listener scoped to that element - so it only fires while the
  image itself is focused, never stealing keystrokes meant for the
  GPS/favorites fields or the API key dialog. Control keys (Backspace,
  Enter, Tab, Escape, Delete, arrows, Space) map to `/api/screen/key` by
  `event.code` (physical/layout-independent); anything else that
  produces a single printable character goes to `/api/screen/text` via
  `event.key`, which already reflects Shift/layout (e.g. Shift+1 -> `!`
  on a US layout) with no separate Shift-tracking needed. A single space
  goes through `/api/screen/key {"key": "space"}` rather than
  `/api/screen/text`, since that route intentionally rejects
  whitespace-only input (the guard against submitting a blank "Send
  text" field). Keystrokes are queued and sent one at a time - each
  waiting for the previous request to finish - so fast typing can't
  arrive at the device out of order. Browser/OS shortcuts (anything with
  Ctrl/Alt/Meta held) are left alone rather than intercepted.
* Connection handling: `actions/screen.py` first checks
  `adbutils.adb.device_list()` (never raises, even with zero devices
  connected) and only runs `waydroid adb connect` (the same reconnect
  `4-waydroid-tools/change-location.sh` uses) when that list is empty -
  so the common case (device already connected) stays fast, while a
  container restart or dropped adb connection is recovered from
  automatically on the next request.

adbutils itself is pure Python, but it shells out to the real `adb`
binary to start the local adb server if one isn't already running -
that's why `install-webapp.sh` also installs the `adb` apt package.

## Security

Same "documented trade-off, LAN-only trust boundary" posture as the rest
of this repo (see the top-level README's "Security" section):

* **API-key auth, not a full account system**: every `/api/*` route that
  mutates device state OR could expose something private (this includes
  `GET /api/favorites/list` - a saved "Home"/"Work" favorite is a real
  address - and `GET /api/screen/screenshot`, which shows whatever is on
  the device's screen) requires a random per-deployment token
  (`X-API-Key` header or `?api_key=` query param), generated on first run
  and stored at `/etc/waydroid-webapp/api-token` (mode 600) - the screen
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
  passed. This one bind is the entire external attack surface.
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
* **`update-webapp.sh` clones the repo over HTTPS from GitHub** (or
  `WEBAPP_REPO_URL`, if pointed at a fork) on every run, then reinstalls
  Python dependencies from the fetched `requirements.txt` via `pip` -
  same supply-chain trust model as the `curl | bash` Waydroid installer
  (see the top-level README's Security section): only point it at a
  ref/fork you trust.
* **`POST /api/update/apply` is API-key-gated like everything else, but
  it's a bigger action than the rest of the API**: anyone with the key
  can make it replace the webapp's own code (from the configured
  `WEBAPP_REPO_URL`/ref) and restart the service. This is the same
  capability `update-webapp.sh` already has when run by hand - the UI
  route doesn't add new exposure, it just makes that action reachable
  without a shell on the container, so the "treat the key like a
  password" guidance above applies here more than anywhere else.
