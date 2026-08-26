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
1. Stop Waydroid: `systemctl stop waydroid-session` (or `waydroid session stop`)
2. Navigate to `4-waydroid-tools/` and run `./spoof-device.sh`. Note: the
   upstream script (Quackdoc/waydroid-scripts) applies a single fixed
   Pixel 5 profile - there is no menu or profile choice, despite what
   older instructions may say.
3. Restart Waydroid: `systemctl start waydroid-session`
4. Open the Android settings app inside your web UI and navigate to "About
   Phone" to verify the new identity.
* **Known issue**: `sudo: command not found`. The upstream script
  unconditionally shells out to `sudo`, which isn't installed in this
  minimal container (everything here already runs as root, so elevation
  isn't actually needed). Fix with `apt-get install -y sudo`, or edit your
  local copy of `spoof-device.sh` to drop the `sudo ` prefix.

## Phase 5: Test Fake GPS Injection
1. Inside the Android web UI, open an app that requires location (like a
   map app or browser).
2. From the LXC terminal, navigate to `4-waydroid-tools/`.
3. Run the wrapper script with coordinates:
   `./change-location.sh 48.8584 2.2945` (Coordinates for the Eiffel Tower).
4. Verify the location pin updates in real-time in the Android UI.
* **Known issue**: `03-setup-tools.sh` fails to download `fake_gps.py` -
  the default `GPS_REPO` (`ayasa520/waydroid_stuff`) has no such file on
  `main`. GPS injection needs a working `GPS_REPO`/`GPS_REF` pointing at a
  source that actually hosts the script; until then, this phase can't be
  tested.

## Phase 6: Redeploying / re-running

All the install scripts (`01-install-waydroid.sh`, `02-install-services.sh`,
`03-setup-tools.sh`) are designed to be re-run without breaking an existing
deployment (idempotency checks on `waydroid init`, clean overwrite of
systemd units). `0-deploy-all.sh` can be rerun with `--ctid <existing ID>`
to resume an interrupted deployment after the container was created (it
won't recreate the container if the binder configuration is already present
in the `.conf`).
