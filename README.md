# Proxmox LXC Waydroid Deployment

Infrastructure-as-code to deploy a headless Android environment (Waydroid)
inside a Debian 13 LXC container on Proxmox, with a browser-based control
webapp (screen view + tap/swipe/text, GPS mock-location), device identity
spoofing, and GPS injection.

## One-command deployment (recommended)

On the Proxmox host, as root:

```bash
./0-deploy-all.sh --hostname waydroid --cpu 4 --ram 4096 --disk 16
```

This script:
1. Loads the `binder`/`loop` kernel modules on the host.
2. Creates a **privileged** Debian 13 container via the
   [community-scripts/ProxmoxVE](https://community-scripts.org/scripts/debian)
   helper script.
3. Injects the binder/apparmor/cgroup configuration into
   `/etc/pve/lxc/<CTID>.conf` and restarts the container.
4. Copies this repo into the container and runs, in order, the Waydroid
   install, the systemd services, then the spoofing/GPS tools -
   automatically **applying** a device identity spoof (Pixel 5 by
   default; pass `--skip-spoof` to leave it unapplied, or `--device
   <profile>` / `--list-devices` to pick another - see
   `4-waydroid-tools/device-profiles/README.md`) and always enabling
   headless adb authorization
   (`4-waydroid-tools/enable-adb.sh`, needed for GPS mock-location and the
   webapp's screen control to work without a human clicking an "Allow USB
   debugging" popup), then restarting the container before Waydroid's
   first boot, so About Phone already shows Pixel 5 the first time you
   open it.
5. Enables `waydroid-session.service` (auto-start on boot) and, once the
   session is up, installs and configures the GPS mock-location app
   automatically (pass `--skip-gps-setup` to leave it for later), then
   installs the webapp (`5-webapp/` - a browser UI plus API for GPS
   control and adb-based screen control; pass `--skip-webapp` to leave it
   for later, see `5-webapp/README.md`).

By default, **the webapp is only reachable via an SSH tunnel** (see
"Security" below). To expose it directly on the LAN (every action still
requires its API key):

```bash
./0-deploy-all.sh --webapp-expose-lan
```

`community-scripts/ProxmoxVE` is an independent third-party project;
`0-deploy-all.sh` downloads and runs its `ct/debian.sh` script **on every
run**, including when `--ctid` points at an already-existing container -
only the LXC config injection step (step 3) is actually guarded against
re-running. If you'd rather not run third-party code against an existing
container, or just want to change a setting like `--webapp-expose-lan` on
an already-deployed one, use the manual per-step scripts below instead of
rerunning `0-deploy-all.sh` (see `docs/DEBUGGING_AND_TESTS.md`, Phase 6, for
the targeted commands).

## Manual deployment (step by step)

1. Run `1-proxmox-host/enable-binder.sh` on the Proxmox host.
2. Create a **privileged** Debian 13 LXC from the Proxmox UI (or via
   `community-scripts/ProxmoxVE`).
3. Append the contents of `1-proxmox-host/lxc-config-append.txt` (minus
   comments) to `/etc/pve/lxc/<VMID>.conf`, then restart the container.
4. Inside the container: `2-lxc-setup/01-install-waydroid.sh`
5. Then: `3-services/02-install-services.sh`
6. Then: `4-waydroid-tools/03-setup-tools.sh`
7. Optional, to spoof the device (Pixel 5 by default) before first boot
   - skip this step to leave it stock, or run `apply-spoof.sh --list` to
   see other options first: `4-waydroid-tools/apply-spoof.sh`
8. `4-waydroid-tools/enable-adb.sh` (sets `ro.adb.secure=0` before first
   boot - needed so `adb`/GPS mock-location/the webapp's screen control
   can authenticate without a human clicking an authorization popup; see
   "Security" below). Then, since this and/or the spoof step above only
   take effect on the Android container's next start: `systemctl stop
   waydroid-session && systemctl restart waydroid-container`
9. `systemctl start waydroid-session`
10. Optional, to enable GPS mock locations (needs the session running,
    unlike the two steps above): `4-waydroid-tools/setup-gps.sh`, then
    `4-waydroid-tools/change-location.sh <lat> <lng>`.
11. Optional, for the control webapp (GPS control + adb-based screen
    control): `5-webapp/install-webapp.sh`. See `5-webapp/README.md`.
12. Access: see the message printed at the end of installation, or the
    "Accessing the interface" section below.

## Accessing the interface

Everything - GPS control and the live screen view/tap/swipe/text control -
is served by the webapp on a single port, gated by a per-deployment API
key (generated on install, printed at the end of `install-webapp.sh` /
`0-deploy-all.sh`, and readable afterwards from
`/etc/waydroid-webapp/api-token` inside the container).

By default (without `--webapp-expose-lan` / `WEBAPP_EXPOSE_LAN=yes`), the
webapp only listens on `127.0.0.1` **inside the container**. From your
machine:

```bash
ssh -L 8088:127.0.0.1:8088 root@<LXC_IP>
```

then open `http://127.0.0.1:8088/` and enter the API key.

With `--webapp-expose-lan` / `WEBAPP_EXPOSE_LAN=yes`, the webapp listens on
all interfaces. Every action still requires the API key - treat it like a
password on an open network. Handy if you already reach your homelab over
a VPN (the VPN then acts as the security perimeter):

```bash
./0-deploy-all.sh --webapp-expose-lan
```

then, from a machine connected to the VPN: `http://<LXC_IP>:8088/`

`WEBAPP_EXPOSE_LAN` always defaults to tunnel-only on every run, including
a re-run against an existing deployment - it does not preserve a prior
`--webapp-expose-lan`. Pass it again explicitly to keep the webapp exposed.

## Project layout

* `0-deploy-all.sh` - Full orchestrator (host -> container -> services).
* `1-proxmox-host/` - Scripts/config applied on the Proxmox host.
* `2-lxc-setup/` - Installs Waydroid and its dependencies in the container.
* `3-services/` - systemd units (Sway headless compositor, Waydroid session).
* `4-waydroid-tools/` - Device spoofing, GPS, manual startup wrapper, Play
  Store emulated-storage workaround.
* `5-webapp/` - Flask webapp/API for GPS control (map UI, favorites) and
  adb-based screen control (view + tap/swipe/text) - see
  `5-webapp/README.md`. `5-webapp/update-webapp.sh` updates it in place
  from GitHub without redeploying the container.
* `tests/` - `lint.sh` (static, no Proxmox needed) and `smoke-test.sh` (run
  inside the container after deployment).
* `docs/` - Detailed debugging methodology.

## Architecture choice: Sway, not Weston

The Wayland compositor used is **Sway** (wlroots-based), in headless mode
(`WLR_BACKENDS=headless`, no `libinput` devices). Waydroid's Android
container needs *some* compositor present for SurfaceFlinger to render
through (see `waydroid-session.service`'s `Requires=`), even though
nothing displays its output directly - the webapp captures frames via
`adb shell screencap`/adbutils instead of reading the compositor's output.
Sway is a well-documented, low-overhead choice for running Waydroid
headless.

## Known limitations

* **Play Integrity / SafetyNet**: some apps (often banking, DRM,
  anti-cheat) refuse to start with a message like *"For security reasons,
  app will close as it does not support devices with modified system"*.
  This is **intentional** app behavior, not a bug in this deployment:
  Waydroid isn't a Google-certified Android device (no locked bootloader,
  no hardware attestation). `4-waydroid-tools/apply-spoof.sh` (spoofing
  system properties) may be enough for apps that only check "basic"
  integrity, but **no reliable workaround exists** for apps requiring
  "STRONG" integrity (real hardware attestation) - that's a fundamental
  limitation, not a configuration issue.

## Security

This project makes **deliberate, documented** security trade-offs, needed
to make Waydroid's binder device access work inside an LXC without
rebuilding a kernel module:

* **Privileged container + `apparmor unconfined` + `cgroup2.devices.allow: a`
  + empty `cap.drop`** (`1-proxmox-host/lxc-config-append.txt`): the
  container gets much broader hardware access and capabilities than a
  standard LXC, weakening isolation from the Proxmox host. Only deploy this
  container on a trusted host/LAN.
* **Webapp: every action, including the screen view, is API-key-gated**
  (`5-webapp/`, installed by default): by design, this repo binds it to
  `127.0.0.1` and recommends an SSH tunnel. `--webapp-expose-lan` /
  `WEBAPP_EXPOSE_LAN=yes` lifts that restriction, but **every** webapp
  action - including fetching a screenshot or sending a tap - requires the
  per-deployment API key, so exposing it on the LAN means trusting that
  key like a password, not handing out an open view. See
  `5-webapp/README.md`'s "Security" section for the full breakdown
  (favorites stored in plain JSON, Nominatim as a third-party geocoding
  dependency, etc.).
* **Device identity spoofing, applied automatically** (`4-waydroid-tools/apply-spoof.sh`
  + `device-profiles/`): appends a fixed block of `ro.product.*`/`ro.build.*`
  properties to `waydroid_base.prop` so About Phone reports a real device
  instead of "WayDroid x86_64" - by default, Pixel 5 (`--skip-spoof` to
  leave it unapplied). The property values are vendored in this repo
  (`4-waydroid-tools/device-profiles/pixel-5.prop`), not downloaded at
  install time - review them directly, and see
  `4-waydroid-tools/device-profiles/README.md` for where they come from
  (credit: [Quackdoc/waydroid-scripts](https://github.com/Quackdoc/waydroid-scripts))
  and how to add another device with `--device <profile>`. Apply/re-apply
  via `apply-spoof.sh`, not by hand - it snapshots the pre-spoof
  configuration, makes re-applying idempotent, and can roll the change
  back (see `docs/DEBUGGING_AND_TESTS.md`, Phase 4).
* **`ro.adb.secure=0`, applied automatically** (`4-waydroid-tools/enable-adb.sh`):
  disables Android's normal adb RSA-key authorization popup, the same way
  real emulators do by default, so `adb`/`waydroid adb connect` (and
  therefore GPS mock-location and the webapp's screen control) work
  without a human clicking "Allow USB debugging" at the exact moment
  Android boots. This means *any*
  host that can reach the container's `waydroid0` bridge IP can attach a
  full adb shell with no authentication - in practice that bridge is only
  reachable from inside the LXC itself, not the wider LAN, so the exposure
  is no broader than `waydroid shell` already has. Roll back with
  `4-waydroid-tools/apply-spoof.sh --rollback` (shares its backup/restore
  with the spoof step) followed by a container restart.
* **Signed third-party app, installed automatically** (GPS mock location):
  `4-waydroid-tools/setup-gps.sh` installs the official, open-source
  Appium **Settings** app (`io.appium.settings`, a signed release from the
  Appium project - the same mock-location provider used across the
  Appium/UiAutomator2 mobile-testing ecosystem) as the system's
  mock-location provider, then `change-location.sh` drives it over a real
  `adb` client connected via `waydroid adb connect` (see
  `docs/DEBUGGING_AND_TESTS.md`, Phase 5, for why it isn't `waydroid adb
  shell`/`install` - those don't exist). `0-deploy-all.sh` runs this
  automatically once the session is up; pass `--skip-gps-setup` to leave
  it for later. This
  replaces an earlier, non-functional approach that set Waydroid's own
  `persist.waydroid.fake_gps` property directly - that property isn't
  consumed by anything in this Android image (see
  `docs/DEBUGGING_AND_TESTS.md`, Phase 5, for how this was confirmed).
* **`curl | bash`** for the official Waydroid installer (`repo.waydro.id`,
  in `01-install-waydroid.sh`): standard practice in the Waydroid ecosystem,
  but still a supply-chain risk worth knowing about.

See `docs/DEBUGGING_AND_TESTS.md` for the full debugging methodology, and
`tests/` for automated validation.
