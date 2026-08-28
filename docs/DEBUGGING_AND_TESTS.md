# Debugging and Testing Steps

Two automated tools are available before working through the manual steps
below:

* `tests/lint.sh` - static, can run anywhere (dev machine, CI), no
  Proxmox/container needed: `bash -n` and shellcheck on every shell
  script, `systemd-analyze verify` (plus a manual key=value check) on
  every `.service` unit including the webapp's rendered template,
  cross-file path references between scripts, `py_compile` on every
  Python file, and the full `5-webapp` unit test suite
  (`python3 -m unittest discover`).
* `tests/smoke-test.sh` - dynamic, run **inside the container** after
  deployment (`pct exec <CTID> -- bash
  /opt/waydroid-lxc-deploy/tests/smoke-test.sh` if deployed via
  `0-deploy-all.sh`, or directly `./tests/smoke-test.sh` from inside the
  container): checks `/dev/binder`/`/dev/loop*`/`/dev/fuse`, installed
  packages, systemd services, the Wayland socket, listening ports, the
  dedicated Waydroid D-Bus bus, a conflicting system `dnsmasq`, and the
  Waydroid session state.

If `smoke-test.sh` fails somewhere, follow the matching phase below to dig
in.

## Phase 1: Verify Host Configuration (Proxmox Node)
**Test:** Are the required kernel modules loaded?
* Run: `lsmod | grep binder`
* **Expected output:** You should see `binder_linux` listed.
* If `1-proxmox-host/enable-binder.sh` fails with "could not load
  binder_linux", your current Proxmox kernel probably doesn't ship that
  module - check `modinfo binder_linux`.
* Run inside the LXC (after `waydroid-container.service` has started at
  least once): `ls -l /dev/binder`
* **Expected output:** A character device. Waydroid creates it itself via
  binderfs when `waydroid-container.service` starts - it does not come from
  an LXC `mknod` hook, so it won't exist beforehand. If it's still missing
  afterwards, check that the container is **privileged** (`unprivileged: 0`
  in the `.conf`) and that `1-proxmox-host/lxc-config-append.txt` was
  applied and the container restarted - `enable-binder.sh` on the host is
  what makes the `binder` filesystem type available for Waydroid's
  binderfs mount in the first place.

## Phase 2: Verify Compositor & Display (Sway)
**Test:** Is the headless compositor running?
* Run inside LXC: `systemctl status sway`
* **Expected output:** `active (running)`.
* **Debug:** If it failed, check logs with `journalctl -u sway -e`. Verify
  `/run/waydroid-wayland` was created with the right permissions. A
  `libseat: Backend 'seatd' failed to open seat, skipping` warning is normal
  and harmless in headless mode (`WLR_BACKENDS=headless` +
  `WLR_LIBINPUT_NO_DEVICES=1`: no physical DRM/input access is needed). If
  Sway still refuses to start over a seat error, install
  `apt-get install -y seatd && systemctl enable --now seatd`.
* **Harmless warnings** (service stays `active (running)`, safe to ignore):
  - `Failed to find any DRM render node` - no GPU in the LXC, the headless
    backend falls back to software rendering (pixman); consistent with the
    software rendering Waydroid already uses (`swiftshader`).
  - `swaybg: Could not find config for output HEADLESS-1` - the default
    wallpaper doesn't find a per-output config and falls back to defaults.
  - `swaybar/tray: Failed to connect to user bus` - no D-Bus in this
    minimal container, so the bar's system tray is simply unavailable
    (`bar { mode invisible }` hides it anyway).

**Test:** Can the webapp reach the device to show a screen?
* Run inside LXC: `systemctl status waydroid-webapp`, then
  `pct exec <CTID> -- curl -s -o /dev/null -w '%{http_code}\n'
  http://127.0.0.1:8088/api/screen/screenshot -H "X-API-Key: $(cat
  /etc/waydroid-webapp/api-token)"` (expect `200`).
* If the webapp is up but the Screen panel never shows an image, or this
  curl returns a 5xx, check `journalctl -u waydroid-webapp -e` for an
  `AdbError` - this almost always means adb can't reach the device yet
  (Android still booting, or `adb devices` shows nothing/`unauthorized`;
  see Phase 5's adb troubleshooting, which the webapp's `actions/screen.py`
  hits the same way `change-location.sh` does).

## Phase 3: Verify Waydroid Session
**Test:** Is waydroid-container.service (provided by the waydroid package) active?
* Run inside LXC: `systemctl status waydroid-container`
* This is a prerequisite for this repo's `waydroid-session.service`: the
  session can't start without it.

**Known issue**: `RuntimeError: Command failed: % .../waydroid-net.sh
start`, and digging further (`waydroid --details-to-stdout session start`
or `bash -x /usr/lib/waydroid/data/scripts/waydroid-net.sh start`) shows
`dnsmasq: failed to create listening socket for 192.168.240.1: Address
already in use`: the `dnsmasq` package auto-enables itself as a **system
service** on install (`systemctl status dnsmasq`) and already listens with
`--local-service` on all local interfaces, conflicting with the ad-hoc
instance Waydroid itself launches on the `waydroid0` bridge.
`01-install-waydroid.sh` disables this service in this repo, but if you
deployed before that fix (or installed `dnsmasq` some other way):
```bash
systemctl disable --now dnsmasq
waydroid session start
```
If the `waydroid0` bridge was left in an inconsistent state after a failed
attempt (check with `ip link show waydroid0`), clean it up before
retrying:
```bash
pkill -f 'dnsmasq.*waydroid0' 2>/dev/null
ip link delete waydroid0 2>/dev/null
rm -f /run/waydroid-lxc/dnsmasq.pid /run/waydroid-lxc/network_up
```

**Known issue**: `org.freedesktop.DBus.Error.NotSupported: Unable to
autolaunch a dbus-daemon without a $DISPLAY for X11`: Waydroid needs a
session D-Bus, which doesn't exist by default in a systemd service without
a login session. This repo's `waydroid-session.service` starts a dedicated
one (fixed address `unix:path=/run/waydroid-dbus/session`) before `waydroid
session start` - see the service definition for details if you still hit
this error.

**Known issue**: `RuntimeError: Command failed: % mount -o ro
/var/lib/waydroid/images/system.img /var/lib/waydroid/rootfs`: loop-mounting
the Android images fails if `/dev/loop*` and `/dev/loop-control` don't
exist in the container. The `loop` module loaded on the host
(`enable-binder.sh`) doesn't guarantee these device nodes physically exist
- this repo now creates them explicitly on the host and bind-mounts them
into the LXC via `lxc-config-append.txt`. If you deployed before this fix:
```bash
# On the Proxmox host
for i in $(seq 0 7); do [ -e /dev/loop$i ] || mknod -m 0660 /dev/loop$i b 7 $i; done
[ -e /dev/loop-control ] || mknod -m 0660 /dev/loop-control c 10 237
# then add the lxc.mount.entry lines (see 1-proxmox-host/lxc-config-append.txt)
# to /etc/pve/lxc/<CTID>.conf, and restart the container (pct stop/start).
```
Then check inside the container: `ls -l /dev/loop*` should list
`loop-control` and `loop0`...`loop7`.

**Known issue**: the `/run/user/0/wayland-1` socket (or whatever it's
named) never appears, even though `sway.service` is `active (running)`
with no fatal error in its logs, and `waydroid-session` keeps timing out
in `wait-for-wayland-socket.sh`: `/run/user/0` is managed by
**systemd-logind** (`user-runtime-dir@0.service`), which **remounts it as a
brand-new tmpfs** on every root session (dis/re)connection (typically an
SSH session), wiping out anything a system service had created there in
the meantime - including Sway's Wayland socket. Verify with `mount | grep
/run/user/0` and `systemctl status user-runtime-dir@0.service`. This is why
this repo runs the whole stack (Sway, waydroid-session) on a **dedicated**
runtime directory, `/run/waydroid-wayland`, never recycled by logind - not
`/run/user/0`. If you deployed before this fix, or copied old units
manually, replace every occurrence of `/run/user/0` with
`/run/waydroid-wayland` in `sway.service` and `waydroid-session.service`,
then:
```bash
mkdir -p /run/waydroid-wayland && chmod 0700 /run/waydroid-wayland
systemctl daemon-reload
systemctl restart sway waydroid-session
```

**Known issue**: `gbinder ERROR: Can't get binder version from /dev/binder:
Inappropriate ioctl for device` (looping), with `/var/lib/waydroid/waydroid.log`
showing `ln: failed to create symbolic link '/dev/binder': File exists`
just before it: Waydroid creates its own `/dev/binder` via **binderfs**
(`mount -t binder binder /dev/binderfs` followed by a symlink) on every
session start - a statically pre-created `/dev/binder` (via mknod) conflicts
with that mechanism and leaves Waydroid with an inconsistent device. This
repo therefore **no longer** creates `/dev/binder` itself (see
`1-proxmox-host/lxc-config-append.txt`): the `binder_linux` module loaded
on the host is enough to make the `binder` filesystem type available;
Waydroid handles the rest. If you added such a hook manually, remove it and
restart the container (`pct stop`/`pct start`, not just `systemctl
restart` - the hook only runs when the container itself (re)starts).

**Known issue**: Android shows `Not enough storage space` (sometimes with
the Settings "Storage" app crashing on open): first check `/dev/fuse`
inside the container (`ls -l /dev/fuse`). Without it, Android's "emulated"
storage (FUSE-based since Android 10+) doesn't initialize correctly. This
repo loads the `fuse` module on the host (`enable-binder.sh`) and enables
the Proxmox `fuse=1` container feature (`0-deploy-all.sh` / `pct set
-features ...,fuse=1`). If the message persists despite `/dev/fuse` being
present and `/data` genuinely having room (`waydroid shell -- dumpsys
diskstats`), see the entry right below - that's the most common case in
practice.

**Confirmed root cause**: `vold` marks the internal storage volume
(`emulated;0`) `UNMOUNTABLE` at boot and **never** retries on its own, even
once `/dev/fuse` is present - check with `waydroid shell -- dumpsys mount`
(look for `state=`). That's why `waydroid shell -- dumpsys diskstats` can
show 60% free space while the Play Store still says "Not enough storage
space": Android simply has no storage volume mounted to present to apps. An
explicit `sm mount 'emulated;0'` call (the modern, Binder-based `sm` tool -
not `vdc`, whose raw text commands are no longer supported on recent
Android versions) is enough to bring it to `MOUNTED`. This repo automates
that call via `3-services/mount-emulated-storage.sh`, launched in the
background by `waydroid-session.service` with its own retry loop (the
Android service takes a moment to be ready to answer `waydroid shell`). If
the message persists:
```bash
waydroid shell -- sm list-volumes all
waydroid shell -- sm mount 'emulated;0'   # note the quotes: ';' is a shell command separator
```
A narrower workaround also exists for a related bug specific to some Play
Store download paths ("Can't create file" errors in logcat rather than
"Not enough storage space" outright):
`4-waydroid-tools/fix-storage-scaffold.sh` - see
[waydroid/waydroid#530](https://github.com/waydroid/waydroid/issues/530).

**Test:** Is Android booting?
* Run inside LXC: `systemctl start waydroid-session` (if not already
  auto-started at boot), then `waydroid status`.
* **Expected output:** `Session: RUNNING`.
* **Debug:** If it says `STOPPED`, Sway may have crashed, or
  `waydroid-container.service` wasn't ready. Check logs via `waydroid log`
  and `journalctl -u waydroid-session -e`. Software rendering heavily taxes
  the CPU; ensure the LXC is allocated at least 4 vCPUs.
* Manual alternative (without systemd): `4-waydroid-tools/start-waydroid.sh`.

## Phase 4: Test Device Spoofing

`0-deploy-all.sh` applies this automatically by default (before Waydroid's
first boot, via `apply-spoof.sh` - pass `--skip-spoof` to opt out, or
`--device <profile>` to pick something other than the default Pixel 5).
This phase is for verifying it took effect, or for re-applying/rolling it
back/switching profiles by hand afterwards.

`apply-spoof.sh` appends a device profile's `ro.product.*`/`ro.build.*`
lines (`4-waydroid-tools/device-profiles/*.prop` - vendored in this repo,
see that directory's README for where the default Pixel 5 profile comes
from and how to add another device) to
`/var/lib/waydroid/waydroid_base.prop`. That file is only read when
Waydroid mounts the Android rootfs, which happens when the underlying
**container** (`waydroid-container.service`, from the waydroid package -
the nested LXC that holds the Android image) starts, not when a
**session** (`waydroid-session.service`, this repo's unit) starts. So
applying a spoof needs a container restart, not just a session restart.

Don't append a profile file to `waydroid_base.prop` by hand - doing that
twice duplicates every line, and offers no way back. Use
`4-waydroid-tools/apply-spoof.sh` instead:

1. Navigate to `4-waydroid-tools/` and run `./apply-spoof.sh` (add
   `--device <profile>` to pick a specific one, or `--list` to see what's
   available). The first time it runs, it snapshots the current
   `waydroid_base.prop` to `waydroid_base.prop.orig` before touching
   anything; every run (first or repeat) then appends the selected
   profile and deduplicates the file by property key, keeping the latest
   value - so re-running it, or switching to a different profile,
   replaces old values instead of piling up duplicates. Safe to run with
   Waydroid up or down - it only edits a file, read later.
2. Stop the session: `systemctl stop waydroid-session`
3. Restart the container so it re-reads `waydroid_base.prop`:
   `systemctl restart waydroid-container`
4. Start the session again: `systemctl start waydroid-session`
5. Open the Android settings app inside your web UI and navigate to "About
   Phone" to verify the new identity.

To go back to the pre-spoof configuration: `./apply-spoof.sh --rollback`,
then repeat steps 2-4 above to apply it. Note this restores whatever the
file looked like right before the *first* time `apply-spoof.sh` ran on
this container - if you already spoofed manually before this wrapper
existed, that snapshot reflects the already-spoofed state, not the true
`waydroid init` defaults; for a genuinely clean slate in that case,
re-run `waydroid init -f` instead.

* **Known issue**: device still reports as generic "WayDroid x86_64"
  after applying a spoof, with no error printed. Check that you restarted
  the **container**, not just the session (step 3 above) - the properties
  get written to `waydroid_base.prop` correctly either way, but nothing
  re-reads that file until the container itself remounts the rootfs.

## Phase 5: Test GPS Mock Location

`0-deploy-all.sh` installs and configures this automatically by default
(once the session is up - pass `--skip-gps-setup` to opt out). This phase
is for verifying it took effect, or for setting it up by hand afterwards.

`change-location.sh` drives the official Appium **Settings** app
(`io.appium.settings`, downloaded by `03-setup-tools.sh`) as a real,
standards-compliant Android mock-location provider. This is the same
mechanism the entire Appium/UiAutomator2 mobile-testing ecosystem uses to
set GPS locations on real and virtual Android devices.

**Important: `waydroid adb` is not a general adb proxy.** Its CLI only
implements two subactions, `connect` and `disconnect`
(`waydroid adb devices`/`install`/`shell` don't exist -
`waydroid adb: error: argument subaction: invalid choice: 'devices'
(choose from connect, disconnect)`). `waydroid adb connect` itself just
looks up the Android container's current IP from the `waydroid0` DHCP
lease file and shells out to a real `adb connect <ip>` - so a genuine
`adb` binary has to be installed in the LXC, and every other adb
operation (`devices`, `install`, `shell`) is the plain `adb` client
talking directly to that IP, not `waydroid adb`. `setup-gps.sh` and
`change-location.sh` both install `adb` (via `apt-get install -y adb`) if
it's missing, call `waydroid adb connect` in a retry loop first (the
container's IP can change across restarts, and reconnecting when already
connected is harmless), then use plain `adb` for everything else.

**Why not Waydroid's own `persist.waydroid.fake_gps` property:** setting
it directly (`waydroid prop set persist.waydroid.fake_gps
"Fix,gps,<lat>,<lng>,..."`) always succeeds and even round-trips correctly
through `waydroid prop get` - but it never actually affects Android: a
live `waydroid logcat` capture taken at the exact moment the property was
set shows **zero** GNSS/location-provider log activity, and that property
doesn't appear anywhere in Waydroid's own source (`waydroid/waydroid` on
GitHub) or in any independent documentation. Nothing in this Android image
reads that property, so the device reports "unknown"/no GPS despite the
command reporting success. The Appium Settings app, driven over real adb,
is the verifiable alternative this repo uses instead.

1. First-time setup (done automatically by `0-deploy-all.sh` unless
   `--skip-gps-setup` was passed): from `4-waydroid-tools/`, run
   `./setup-gps.sh`. This installs the `adb` client if needed, waits for
   `waydroid adb connect` to succeed (up to 3 minutes) and for `adb
   devices` to show the device as `device` (not `offline`), installs the
   Appium Settings APK, and grants it location permissions plus the
   `android:mock_location` app-op. Safe to re-run.
2. Inside the Android web UI, open an app that requires location (a map
   app or browser), and make sure Location is turned on in Android
   Settings (Settings > Location > mode "High accuracy" or "Device only").
3. From `4-waydroid-tools/`, run: `./change-location.sh 48.8584 2.2945`
   (coordinates for the Eiffel Tower). The app resends the fix roughly
   every 2 seconds until stopped.
4. Verify the location pin updates in the Android UI.
5. `./change-location.sh --stop` stops sending mock fixes.

**Verified end-to-end** (live container, `dumpsys location`): the mock
provider's `last location` updates correctly and instantly on every
`change-location.sh` call, and Google Play Services' own
`fused_location_provider`/`network_location_provider` listeners receive
each fix continuously (visible as repeating `passive provider delivered
location[...] to .../com.google.android.gms[...]` entries in the event
log) - the mock-location pipeline itself works correctly all the way
through Android's location stack.

* **Known behavior, not a bug**: after the first fix, Google Maps doesn't
  live-refresh its blue dot when `change-location.sh` jumps to a new,
  distant coordinate - `dumpsys location` confirms the new fix reaches
  Android/Play Services immediately, but Maps' own UI layer caches the
  last position it rendered and only re-reads location on a fresh start.
  Force-stop and relaunch Maps after each `change-location.sh` call to
  see the new position: `adb shell am force-stop
  com.google.android.apps.maps`, then relaunch it from the launcher (or
  `adb shell monkey -p com.google.android.apps.maps -c
  android.intent.category.LAUNCHER 1`). This is standard behavior for any
  mock-location "teleport" (as opposed to gradual simulated movement),
  not specific to this deployment.

* **Known issue**: `setup-gps.sh` times out after 3 minutes with
  `'waydroid adb connect' never succeeded`. Android's first boot can
  genuinely take that long on a CPU-constrained host (software rendering
  is heavy - see Phase 3), so first try again once `waydroid status`
  reports `Session: RUNNING`. If it still doesn't connect, try `waydroid
  adb connect` by hand and check its error output.
* **Known issue**: `setup-gps.sh` fails with `adb connected but no device
  is listed as ready yet`, and `adb devices` by hand shows `offline`:
  usually clears up within a few seconds on its own (the Android side is
  still finishing its handshake); re-run `setup-gps.sh` once it shows
  `device`.
* **Known issue, root cause confirmed**: `adb devices` shows
  `unauthorized` instead of `device`, indefinitely - this is normal
  Android adb behavior, not a bug: by default (`ro.adb.secure=1`, set by
  `waydroid init`), the **first** connection from any given host requires
  RSA-key authorization via an "Allow USB debugging from this computer?"
  popup, which (same as physical-device adb) has to be tapped on the
  Android side before the connection is trusted - `adb`/`waydroid adb
  connect` alone can never get past this on their own. In this headless
  deployment there's nowhere reliable for that tap to come from, so the
  connection stays `unauthorized` forever. `4-waydroid-tools/enable-adb.sh`
  fixes this **at the source** by setting `ro.adb.secure=0` in
  `waydroid_base.prop` before Waydroid's first boot - the same setting
  real Android emulators ship with by default, for the same reason - so
  adbd skips RSA authorization entirely and `adb devices` reports `device`
  immediately on connect. `0-deploy-all.sh` now runs this automatically,
  unconditionally (not tied to `--skip-spoof`), before every first boot.
  Like the Pixel 5 spoof, `ro.*` properties lock once Android has booted,
  so this only takes effect on the next **container** restart - see the
  hotfix commands below if you're fixing an already-deployed container.
* **Known issue** `WayDroid session is stopped` (or `waydroid shell`
  silently doing nothing) from a plain root shell, even though
  `waydroid-session.service` is `active (running)`: this service runs its
  own isolated D-Bus session bus at `unix:path=/run/waydroid-dbus/session`
  (see `waydroid-session.service` and Phase 3 above) rather than a default
  session bus, and an interactive shell has no `DBUS_SESSION_BUS_ADDRESS`
  pointing at it - so the `waydroid` CLI can't reach the running session
  and misreports it as stopped. `setup-gps.sh`, `change-location.sh` and
  `fix-storage-scaffold.sh` export it themselves; for any other manual
  `waydroid` command, either export it once per shell
  (`export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/waydroid-dbus/session`)
  or prefix the one-off command with it.

## Phase 6: Redeploying / re-running

The three in-container install scripts are safe to re-run directly against
an already-deployed container, and each guards its own expensive step:
`01-install-waydroid.sh` skips `waydroid init` if `/var/lib/waydroid/images`
already exists, `02-install-services.sh` always does a clean overwrite of
its systemd units and unconditionally `restart`s them, and `03-setup-tools.sh`
just re-downloads the GPS mock-location APK. For an existing container,
run them directly with `pct exec <CTID> -- ...` (see "Manual deployment"
in the README) rather than through `0-deploy-all.sh`.

**`WEBAPP_EXPOSE_LAN` and re-running `0-deploy-all.sh`**: the webapp's LAN
exposure is the only exposure switch in the repo. `0-deploy-all.sh` always
passes an explicit value for it (defaulting to `"no"`), so a plain re-run
with no flag reverts the webapp to tunnel-only rather than preserving
prior exposure. Run `install-webapp.sh` directly (not through
`0-deploy-all.sh`) if you want the "preserve whatever's currently
configured" behavior described below.

**`0-deploy-all.sh --ctid <existing ID>` is not fully idempotent.**
Only step 3 (LXC config injection) is actually idempotency-guarded - it
skips re-appending if `lxc.apparmor.profile: unconfined` is already in the
`.conf`. Step 2, the container-creation call to the third-party
`community-scripts/ProxmoxVE` `ct/debian.sh` script, runs **unconditionally
on every invocation**, including with `--ctid` set to an existing container.
That script isn't maintained by this repo, and its behavior when pointed at
an existing CTID (update in place vs. attempt to recreate) isn't verified
here. Don't rerun the full `0-deploy-all.sh` pipeline against a working
container just to change a setting like `--webapp-expose-lan` - use the
targeted commands below, or the manual per-step scripts above, instead.

**Toggling LAN exposure on an existing container's webapp**, without
touching the container itself otherwise - re-running `install-webapp.sh`
with an explicit `WEBAPP_EXPOSE_LAN` rewrites `webapp.env` and restarts
the service, so it's idempotent regardless of current state:
```bash
# On the Proxmox host - to EXPOSE the webapp on the LAN:
pct exec <CTID> -- env WEBAPP_EXPOSE_LAN=yes bash -c "cd /opt/waydroid-lxc-deploy/5-webapp && ./install-webapp.sh"

# To go back to SSH-tunnel-only:
pct exec <CTID> -- env WEBAPP_EXPOSE_LAN=no bash -c "cd /opt/waydroid-lxc-deploy/5-webapp && ./install-webapp.sh"
```
Leaving `WEBAPP_EXPOSE_LAN` unset on a direct `install-webapp.sh` run (as
opposed to going through `0-deploy-all.sh`, which always passes an
explicit value) preserves whatever's already configured - see
`5-webapp/README.md`. To check the current state at any time:
`pct exec <CTID> -- cat /etc/waydroid-webapp/webapp.env`.

**Enabling headless adb on an already-deployed container** (fixes `adb
devices` showing `unauthorized` forever - see Phase 5): push the current
`4-waydroid-tools/enable-adb.sh` if the container's copy predates it,
then run it and restart the container:
```bash
# On the Proxmox host
pct push <CTID> 4-waydroid-tools/enable-adb.sh /opt/waydroid-lxc-deploy/4-waydroid-tools/enable-adb.sh --perms 755
pct exec <CTID> -- bash -c "cd /opt/waydroid-lxc-deploy/4-waydroid-tools && ./enable-adb.sh"
pct exec <CTID> -- systemctl stop waydroid-session
pct exec <CTID> -- systemctl restart waydroid-container
pct exec <CTID> -- systemctl start waydroid-session
```
Then re-run `setup-gps.sh` (it will install `adb` if needed and connect
cleanly this time) and confirm with `pct exec <CTID> -- adb devices` -
it should show `device`, not `unauthorized`.

**Updating just the webapp from GitHub**, without touching anything
else in the deployment - run `update-webapp.sh` inside the container
(it needs outbound HTTPS to github.com):
```bash
pct exec <CTID> -- bash -c "cd /opt/waydroid-lxc-deploy/5-webapp && ./update-webapp.sh --check"
pct exec <CTID> -- bash -c "cd /opt/waydroid-lxc-deploy/5-webapp && ./update-webapp.sh"
```
It figures out the current install directory from the deployed
`waydroid-webapp.service` unit (so it still works if that ever differs
from the `/opt/waydroid-lxc-deploy/5-webapp` default), compares the
locally recorded version (`/etc/waydroid-webapp/installed-version`)
against the tracked ref's latest commit, and no-ops if they already
match - safe to run on a schedule (e.g. a cron job on the Proxmox host
wrapping the `pct exec` above) as well as by hand. A failed clone
usually means the container can't reach github.com (check
`pct exec <CTID> -- curl -fsSI https://github.com`); a failed update
after the clone succeeds (pip install, the post-restart health check)
rolls back automatically and leaves the previous install running - the
"Update failed during: ..." line names the step that failed, and
`journalctl -u waydroid-webapp` has the service's own logs. A
deployment installed via `0-deploy-all.sh` records the host checkout's
commit as installed (`WEBAPP_INSTALLED_VERSION`, passed through
automatically); a deployment installed by running `install-webapp.sh`
directly, without that variable set and from a directory that isn't
itself a git checkout, has no version tracked initially, so its first
`update-webapp.sh` run always applies (that's expected, not a bug) and
records a real version from then on.

**Some API requests randomly 401 even with the correct key** (most
visibly: the API key dialog appears to "not save" - typing the key and
clicking Save seems to work, then the very next action fails and the
dialog reopens with "API key missing or invalid") - this is a first-boot
race in gunicorn's 2 workers, fixed by running with `--preload`
(`5-webapp/waydroid-webapp.service`): without it, each worker imports
`auth.py` independently after forking, and if that happens before
`api-token` exists, both can generate a *different* random token, with
only one landing on disk - requests routed to the other worker then
401 forever, regardless of what key is actually saved/displayed. A
container deployed before this fix doesn't need reinstalling: the token
file already has a value on disk, so a plain restart is enough to get
both (freshly restarted, still non-`--preload`) workers reading the
same one consistently:
```bash
pct exec <CTID> -- systemctl restart waydroid-webapp
```
To pick up `--preload` itself (belt-and-suspenders against the same
class of race in general, not required for this specific symptom to go
away), re-run `install-webapp.sh` or `update-webapp.sh` to get the
current `waydroid-webapp.service` template.

**An in-UI update "restarts" but never reports success - the "Update"
button keeps showing the old commit as installed, and a retry says "An
update is already in progress"** - `update-webapp.sh` calls `systemctl
restart waydroid-webapp` on *itself* partway through applying an
update triggered from the UI (`actions/update.py` launches it as a
detached child of a gunicorn worker). With systemd's default
`KillMode=control-group`, that restart kills every process left in the
unit's cgroup, including the detached script - even though it survived
being reparented (`start_new_session=True`), it's still in the same
cgroup. So it dies right as it calls `systemctl restart`, before it
ever reaches the post-restart `/api/health` check or records the new
version, even though the restart itself (and the file sync before it)
already succeeded - the webapp is quietly running the new code the
whole time. Fixed by adding `KillMode=process` to
`5-webapp/waydroid-webapp.service`, so systemd only ever signals
gunicorn's own master process on restart/stop, leaving the detached
update script alone to finish the job. Companion fix in
`actions/update.py`: `apply_update()` now checks whether the pid
recorded alongside `"state": "running"` is still alive before refusing
a second run, instead of trusting that string forever - so a run that
died mid-flight for any reason (not just this one) doesn't leave every
future update permanently blocked.

To recover a container already stuck like this, without reinstalling
anything: run `update-webapp.sh` directly from a shell rather than
through the UI - since that invocation was never a child of the
service in the first place, it isn't in its cgroup either, so its own
`systemctl restart` call can't kill it regardless of `KillMode`. It
will re-detect the same update, re-sync (a no-op, since the files are
already current), restart the service, and this time actually reach
the health check and write the real installed version:
```bash
pct exec <CTID> -- bash -c "cd /opt/waydroid-lxc-deploy/5-webapp && ./update-webapp.sh"
```
That alone clears both symptoms (the version mismatch and the stuck
"already in progress" lock, since this run overwrites the status file
with its own real outcome) even before redeploying the fixed code. To
get `KillMode=process` itself, so a future in-UI update doesn't need
this manual step, redeploy or re-run `install-webapp.sh`/
`update-webapp.sh` to pick up the current `waydroid-webapp.service`
template.

**`journalctl -u waydroid-webapp` shows "Unit process ... remains
running after unit stopped" and "Found left-over process ... in
control group ... This usually indicates unclean termination of a
previous run, or service implementation deficiencies"** right after an
in-UI update - this is `KillMode=process` (above) working exactly as
intended, not a new problem: those left-over processes are
`update-webapp.sh` itself (`bash`) and the `systemctl restart` command
it just ran on itself (`systemctl`), both deliberately left alone by
that restart so they can finish writing the update's outcome. systemd
always logs any process still in a unit's cgroup after that unit
stops with this same generic, slightly alarming wording, whether it's
a genuine bug elsewhere or - as here - the whole point of the
`KillMode` we chose; it's informational and can be ignored for this
specific pair of processes. If `update-webapp.sh` (or a `systemctl`
it spawned) is still showing up as left-over minutes later rather than
clearing on the next restart, that's the actual problem worth chasing
(check `ps aux` for a hung update, and `/var/log/waydroid-webapp-update.log`
for where it stalled).

**The Screen panel freezes on one frame and `journalctl -u
waydroid-webapp` floods `screencap error: cannot identify image file
<_io.BytesIO object at ...>`, repeating every poll and surviving a
webapp restart** - this is `adb shell screencap -p` itself returning
bytes that aren't a valid PNG, not a webapp/Python exception (there's
no traceback - it's `adbutils` logging a warning and, since
`actions/screen.py` calls `screenshot(error_ok=False)`, turning it into
an `ActionError`/400 each time). Restarting `waydroid-webapp` doesn't
touch what's actually on the Android screen, so it does nothing here by
design. The trigger is always a `FLAG_SECURE` system surface - Android
intentionally blocks capture of anything credential-related, and under
Waydroid that comes back as malformed bytes instead of a clean black
frame. Two different screens trigger it, and they need different
recovery:

* **Settings -> Security -> Choose a screen lock -> PIN/Pattern/Password**
  (before one is actually set) is a regular settings screen - **Back**
  or **Home** in the Screen panel gets you off it immediately, since
  both go through `adb shell input keyevent`, not screencap, so they
  work even while the screenshot itself is failing.
* **The actual lock screen**, once a PIN/pattern/password is set and the
  device locks (manually or after idling), is a different, more
  restrictive surface - Back and Home are consumed by the keyguard
  itself and won't get you off it. This is the one that can leave you
  unable to see *or* dismiss anything. Since v1.0, the Screen panel has
  a dedicated "Unlock" field for this: it enters a PIN via digit
  KeyEvents (`AdbDevice.keyevent()`, not text injection) and `enter`, so
  it still reaches the keyguard's PIN pad with a completely broken
  screenshot - same as `POST /api/screen/unlock {"pin": "..."}` directly,
  or typing on the keyboard with the (blank) screen image focused. The
  "Lock: locked/unlocked" indicator next to it (`GET
  /api/screen/lock-status`) is a best-effort read of `dumpsys window`,
  not authoritative across every Android/Waydroid build - if it's ever
  wrong, trust what actually happens on unlock over what it says.
  If the webapp itself isn't reachable (down, mid-redeploy, ...), the
  equivalent directly over adb is:
  ```bash
  pct exec <CTID> -- bash -c "waydroid adb connect >/dev/null 2>&1; adb shell input text '<your-pin>'; adb shell input keyevent 66"
  ```
  `input text` (unlike the webapp's own text-entry route) is generally
  still accepted by AOSP's stock PIN pad, but if it silently does
  nothing, key events are the more universal fallback (`KEYCODE_0`-`9`
  = `7`-`16`, `KEYCODE_ENTER` = `66`) - e.g. for PIN `1234`:
  `adb shell input keyevent 8 9 10 11 66`.
* **Kill all apps** doesn't help against either of these - it
  deliberately only ever force-stops third-party packages, never system
  components, so it can't touch Settings/the keyguard either way. It's
  for a frozen or unresponsive *installed app* (and, since v1.0, also
  sends `home` afterward so the dead app's window actually clears
  instead of sitting there "killed but still open").
* Last resort, if input also stops responding entirely:
  `pct exec <CTID> -- systemctl restart waydroid-session`, or a full
  `pct reboot <CTID>`.

If you don't specifically need a device lock for what you're testing,
the simplest fix is to just leave it at **None** (the default) - a lock
screen actively works against remote automation (it locks you out after
the device idles), and this is the one part of the device this tool
can't fully see. If you do need one, the Screen panel's "Set PIN" field
(`POST /api/screen/set-pin {"pin": "...", "old_pin": "..."}` - `old_pin`
only needed when changing an existing PIN) sets it directly via adb,
bypassing the broken "Choose a screen lock" UI entirely - the same
`locksettings set-pin` command as running it by hand:
```bash
pct exec <CTID> -- bash -c "waydroid adb connect >/dev/null 2>&1; adb shell locksettings set-pin <your-pin>"
```
Not verified against every Android/Waydroid build - confirm it actually
takes effect before relying on it (see the "`waydroid adb` is not a
general adb proxy" note in Phase 5 for why this is `adb shell ...`, not
`waydroid adb shell ...`). `locksettings` reports a rejected change
(wrong/missing `--old`, policy violation) as plain text on stdout rather
than a nonzero exit code; `set_pin()` in `actions/screen.py` scans that
text for failure keywords and surfaces it as-is rather than assuming
success.
