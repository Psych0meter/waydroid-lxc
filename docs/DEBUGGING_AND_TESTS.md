# Debugging and Testing Steps

Two automated tools are available before working through the manual steps
below:

* `tests/lint.sh` - static, can run anywhere (dev machine, CI): `bash -n` on
  every script, shellcheck, and checks that files referenced between
  scripts actually exist. Doesn't need Proxmox.
* `tests/smoke-test.sh` - dynamic, run **inside the container** after
  deployment (`pct exec <CTID> -- bash
  /opt/waydroid-lxc-deploy/tests/smoke-test.sh` if deployed via
  `0-deploy-all.sh`, or directly `./tests/smoke-test.sh` from inside the
  container): checks `/dev/binder`, installed binaries, systemd services,
  the Wayland socket, listening ports, and the Waydroid session state.

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

## Phase 2: Verify Compositor & Display (Sway & VNC)
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

**Test:** Is wayvnc up and listening?
* Run inside LXC: `systemctl status wayvnc`
* If `wayvnc.service` fails immediately after `sway.service`, check
  `journalctl -u wayvnc -e`: its `ExecStartPre`
  (`wait-for-wayland-socket.sh`) fails if the Wayland socket never appears -
  in that case the problem is Sway (see above), not wayvnc.
* **Known issue #1**: `ERROR: ../src/main.c: 2034: Failed to load config.
  Success`, restart-looping: `wayvnc` always tries to load a config file,
  even without `-C`, and crashes if none exists
  ([any1/wayvnc#10](https://github.com/any1/wayvnc/issues/10)) - even more
  likely here since `$HOME` isn't set for a systemd service launched
  without `User=`. This repo creates an empty `/etc/wayvnc/config` in
  `02-install-services.sh`, references it via `-C` in `wayvnc.service`, and
  also sets `Environment=HOME=/root`. If you still see this error:
  `mkdir -p /etc/wayvnc && touch /etc/wayvnc/config && systemctl restart wayvnc`.
* **Known issue #2**: `invalid version for global zxdg_output_manager_v1` /
  `Virtual Pointer protocol not supported by compositor` / `Failed to
  initialise wayland`: means the compositor on the other end isn't
  wlroots-based (typically if `weston` is running instead of `sway` - see
  "Architecture choice" in the README). `wayvnc` will never work with
  Weston, no matter the configuration. Check that `WAYLAND_DISPLAY`/
  `XDG_RUNTIME_DIR` match between `sway.service` and `wayvnc.service`, and
  that `sway.service` (not a leftover `weston.service`) is what's actually
  active: `systemctl list-units '*.service' | grep -Ei 'sway|weston'`.

**Test:** Is the web interface exposed?
* Run inside LXC: `systemctl status novnc`
* By default, noVNC/wayvnc only listen on `127.0.0.1` - see the README's
  "Accessing the interface" section for the SSH tunnel. If you deployed with
  `--expose-lan`/`EXPOSE_LAN=yes` and the browser can't reach
  `http://<LXC_IP>:6080/vnc.html`, check that the Proxmox Datacenter
  firewall allows inbound port `6080`.

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
with no fatal error in its logs, and `wayvnc`/`waydroid-session` keep
timing out in `wait-for-wayland-socket.sh`: `/run/user/0` is managed by
**systemd-logind** (`user-runtime-dir@0.service`), which **remounts it as a
brand-new tmpfs** on every root session (dis/re)connection (typically an
SSH session), wiping out anything a system service had created there in
the meantime - including Sway's Wayland socket. Verify with `mount | grep
/run/user/0` and `systemctl status user-runtime-dir@0.service`. This is why
this repo runs the whole stack (Sway, wayvnc, waydroid-session) on a
**dedicated** runtime directory, `/run/waydroid-wayland`, never recycled by
logind - not `/run/user/0`. If you deployed before this fix, or copied old
units manually, replace every occurrence of `/run/user/0` with
`/run/waydroid-wayland` in `sway.service`, `wayvnc.service` and
`waydroid-session.service`, then:
```bash
mkdir -p /run/waydroid-wayland && chmod 0700 /run/waydroid-wayland
systemctl daemon-reload
systemctl restart sway wayvnc waydroid-session
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
first boot, via `apply-spoof.sh` - pass `--skip-spoof` to opt out). This
phase is for verifying it took effect, or for re-applying/rolling it back
by hand afterwards.

`spoof-device.sh` (Quackdoc/waydroid-scripts) applies a single fixed
Pixel 5 profile - there is no menu or profile choice, despite what older
instructions may say. It works by **appending** `ro.product.*`/
`ro.build.*` lines to `/var/lib/waydroid/waydroid_base.prop`. That file is
only read when Waydroid mounts the Android rootfs, which happens when the
underlying **container** (`waydroid-container.service`, from the waydroid
package - the nested LXC that holds the Android image) starts, not when a
**session** (`waydroid-session.service`, this repo's unit) starts. So
applying a spoof needs a container restart, not just a session restart.

Don't run `spoof-device.sh` directly - it isn't idempotent (running it
twice appends the same block twice) and offers no way back. Use
`4-waydroid-tools/apply-spoof.sh` instead, which wraps it:

1. Navigate to `4-waydroid-tools/` and run `./apply-spoof.sh`. The first
   time it runs, it snapshots the current `waydroid_base.prop` to
   `waydroid_base.prop.orig` before touching anything; every run (first or
   repeat) then applies `spoof-device.sh` and deduplicates the file by
   property key, keeping the latest value - so re-running it (e.g. after
   `SPOOF_REF` picks up an upstream change) replaces old values instead of
   piling up duplicates. Safe to run with Waydroid up or down - it only
   edits a file, read later.
2. Stop the session: `systemctl stop waydroid-session`
3. Restart the container so it re-reads `waydroid_base.prop`:
   `systemctl restart waydroid-container`
4. Start the session again: `systemctl start waydroid-session`
5. Open the Android settings app inside your web UI and navigate to "About
   Phone" to verify the new identity.

To go back to the pre-spoof configuration: `./apply-spoof.sh --rollback`,
then repeat steps 2-4 above to apply it. Note this restores whatever the
file looked like right before the *first* time `apply-spoof.sh` ran on
this container - if you already spoofed manually (via `spoof-device.sh`
directly) before this wrapper existed, that snapshot reflects the
already-spoofed state, not the true `waydroid init` defaults; for a
genuinely clean slate in that case, re-run `waydroid init -f` instead.

* **Known issue**: device still reports as generic "WayDroid x86_64"
  after applying a spoof, with no error printed. Two independent causes,
  both handled by `apply-spoof.sh`/`03-setup-tools.sh` (as of this repo's
  current version) but worth knowing about if you deployed an older copy
  or a hand-downloaded script:
  - `sudo: command not found` on every line of the script's output: the
    upstream script unconditionally shells out to `sudo`, which isn't
    installed in this minimal container (everything here already runs as
    root, so elevation isn't actually needed). Since the script has no
    `set -e`, it still exits 0 with **none** of the properties actually
    written - `03-setup-tools.sh` now strips the `sudo ` prefix right after
    downloading it, so this shouldn't reoccur; if you hit it anyway, either
    `apt-get install -y sudo` or edit your local copy of `spoof-device.sh`
    to drop the `sudo ` prefix.
  - Only restarting `waydroid-session` (step 2-4 above) instead of also
    restarting `waydroid-container`: the properties get written to
    `waydroid_base.prop` correctly, but nothing re-reads that file until
    the container itself remounts the rootfs.

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
connected is harmless), then use plain `adb` for everything else. An
earlier version of these scripts (before this was discovered) tried
`waydroid adb devices`/`install`/`shell` directly and failed outright -
if you deployed that version, re-run `03-setup-tools.sh` and
`setup-gps.sh` to pick up the fix.

**This replaces an earlier, broken approach.** A previous version of this
repo set Waydroid's own `persist.waydroid.fake_gps` property directly
(`waydroid prop set persist.waydroid.fake_gps "Fix,gps,<lat>,<lng>,..."`)
without a download. The command always succeeded and even round-tripped
correctly through `waydroid prop get` - but it never actually affected
Android: a live `waydroid logcat` capture taken at the exact moment the
property was set showed **zero** GNSS/location-provider log activity, and
that property doesn't appear anywhere in Waydroid's own source
(`waydroid/waydroid` on GitHub) or in any independent documentation. Best
explanation: nothing in this Android image ever reads that property, so
every "fix" silently went nowhere - which is exactly why the device
reported "unknown"/no GPS despite the script reporting success every time.
The Appium Settings app is the corrected, independently-verifiable
replacement.

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
* **Known issue (legacy)**: `java.lang.NullPointerException` in
  `SettingsProvider.mutateGlobalSetting` from a command like `waydroid
  shell -- settings put global adb_enabled 1`. This came from an earlier
  version of `setup-gps.sh` that tried to flip `adb_enabled` via `waydroid
  shell` before realizing that command isn't attributed to a proper
  "shell" UID the way real `adb shell` is, which trips a null
  `getCallingPackage()` deep in `AppOpsService`. The current `setup-gps.sh`
  no longer does this at all - network ADB doesn't need to be toggled by
  hand, since `waydroid adb connect` already sets up an authenticated
  connection to the device. If you still see this error, you're running
  an old copy of the script.
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
its systemd units and unconditionally `restart`s them, so a re-run with a
different `EXPOSE_LAN` actually takes effect, and `03-setup-tools.sh` just
re-downloads `spoof-device.sh`. For an existing container, run them
directly with `pct exec <CTID> -- ...` (see "Manual deployment" in the
README) rather than through `0-deploy-all.sh`.

**Known issue (fixed): re-running `02-install-services.sh` silently
reverted `--expose-lan`.** `EXPOSE_LAN` used to default to `"no"` whenever
the variable wasn't explicitly set to `"yes"` - so re-running the script
for any unrelated reason (picking up a fix, redeploying with a newer copy
of the repo) without re-passing `--expose-lan`/`EXPOSE_LAN=yes` silently
regenerated `novnc.service` from the pristine tunnel-only template. Before
the `enable --now` -> `restart` fix above, this reset didn't actually apply
to an already-running `novnc.service`, which accidentally masked the bug;
once `restart` was introduced, the same silent reset started taking real
effect, breaking direct LAN access that had previously been enabled.
`02-install-services.sh` now resolves `EXPOSE_LAN` explicitly: `"yes"` or
`"no"` (env var, or `--expose-lan`/`--no-expose-lan` on `0-deploy-all.sh`)
is always honored, even on a re-run; left **unset**, it inspects the
*current* `novnc.service` on disk (if any) and preserves whatever mode is
already configured, defaulting to `"no"` only when there's nothing to
preserve (a fresh install). So a plain re-run with no flag now leaves
whatever exposure setting you already had alone.

**`0-deploy-all.sh --ctid <existing ID>` is not the same kind of safe.**
Only step 3 (LXC config injection) is actually idempotency-guarded - it
skips re-appending if `lxc.apparmor.profile: unconfined` is already in the
`.conf`. Step 2, the container-creation call to the third-party
`community-scripts/ProxmoxVE` `ct/debian.sh` script, runs **unconditionally
on every invocation**, including with `--ctid` set to an existing container.
That script isn't maintained by this repo, and its behavior when pointed at
an existing CTID (update in place vs. attempt to recreate) isn't verified
here. Don't rerun the full `0-deploy-all.sh` pipeline against a working
container just to change a setting like `--expose-lan` - use the targeted
commands below, or the manual per-step scripts above, instead.

**Toggling LAN exposure on an existing container**, without touching the
container itself (this rewrites the whole `ExecStart` line, so it's
idempotent regardless of the unit's current state):
```bash
# On the Proxmox host - to EXPOSE noVNC on the LAN:
pct exec <CTID> -- sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 0.0.0.0:6080 127.0.0.1:5900|' /etc/systemd/system/novnc.service
pct exec <CTID> -- systemctl daemon-reload
pct exec <CTID> -- systemctl restart novnc

# To go back to SSH-tunnel-only:
pct exec <CTID> -- sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 127.0.0.1:6080 127.0.0.1:5900|' /etc/systemd/system/novnc.service
pct exec <CTID> -- systemctl daemon-reload
pct exec <CTID> -- systemctl restart novnc
```
This is exactly what a re-run of `02-install-services.sh` with the
matching `EXPOSE_LAN` value now does, so it's equivalent to re-running
that one script but without going through `0-deploy-all.sh`'s
container-creation step. To check the current state at any time:
`pct exec <CTID> -- grep ExecStart /etc/systemd/system/novnc.service`.

**None of the above has any visible effect once the webapp is installed**
with its default `WEBAPP_UNIFY_VNC=yes` (`5-webapp/install-webapp.sh`,
run automatically by `0-deploy-all.sh` unless `--skip-webapp` was
passed) - it forces `novnc.service`'s `ExecStart` back to `127.0.0.1`
every time it runs, since nginx becomes the sole external gateway for
both. `WEBAPP_EXPOSE_LAN` / `--webapp-expose-lan` (on `install-webapp.sh`
or `0-deploy-all.sh`) is what controls exposure in that mode - see
`5-webapp/README.md`.

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
