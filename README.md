# Proxmox LXC Waydroid Deployment

Infrastructure-as-code to deploy a headless Android environment (Waydroid)
inside a Debian 13 LXC container on Proxmox, with browser-based remote
access (noVNC), device identity spoofing, and GPS injection.

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
   automatically **applying** the Pixel 5 device spoof (pass
   `--skip-spoof` to leave `spoof-device.sh` downloaded but unapplied)
   and always enabling headless adb authorization
   (`4-waydroid-tools/enable-adb.sh`, needed for GPS mock-location to
   work without a human clicking an "Allow USB debugging" popup in
   noVNC), then restarting the container before Waydroid's first boot,
   so About Phone already shows Pixel 5 the first time you open it.
5. Enables `waydroid-session.service` (auto-start on boot) and, once the
   session is up, installs and configures the GPS mock-location app
   automatically (pass `--skip-gps-setup` to leave it for later), then
   installs the GPS control webapp (`5-webapp/` - a browser UI plus API
   to drive `change-location.sh`, with noVNC unified behind the same
   port; pass `--skip-webapp` to leave it for later, see
   `5-webapp/README.md`).

By default, **noVNC and the webapp are each only reachable via an SSH
tunnel** (see "Security" below). To expose noVNC directly on the LAN
(without a password):

```bash
./0-deploy-all.sh --expose-lan
```

The webapp has its own, separate switch - `--webapp-expose-lan` - since
it sits behind an API key even when exposed (see "Accessing the
interface" below for how the two flags interact once the webapp is
installed).

`community-scripts/ProxmoxVE` is an independent third-party project;
`0-deploy-all.sh` downloads and runs its `ct/debian.sh` script **on every
run**, including when `--ctid` points at an already-existing container -
only the LXC config injection step (step 3) is actually guarded against
re-running. If you'd rather not run third-party code against an existing
container, or just want to change a setting like `--expose-lan` on an
already-deployed one, use the manual per-step scripts below instead of
rerunning `0-deploy-all.sh` (see `docs/DEBUGGING_AND_TESTS.md`, Phase 6, for
the targeted commands).

## Manual deployment (step by step)

1. Run `1-proxmox-host/enable-binder.sh` on the Proxmox host.
2. Create a **privileged** Debian 13 LXC from the Proxmox UI (or via
   `community-scripts/ProxmoxVE`).
3. Append the contents of `1-proxmox-host/lxc-config-append.txt` (minus
   comments) to `/etc/pve/lxc/<VMID>.conf`, then restart the container.
4. Inside the container: `2-lxc-setup/01-install-waydroid.sh`
5. Then: `EXPOSE_LAN=no 3-services/02-install-services.sh`
6. Then: `4-waydroid-tools/03-setup-tools.sh`
7. Optional, to spoof the device as a Pixel 5 before first boot (skip this
   step if you'd rather leave it stock, or review `spoof-device.sh` first):
   `4-waydroid-tools/apply-spoof.sh`
8. `4-waydroid-tools/enable-adb.sh` (sets `ro.adb.secure=0` before first
   boot - needed so `adb`/GPS mock-location can authenticate without a
   human clicking an authorization popup in noVNC; see "Security" below).
   Then, since this and/or the spoof step above only take effect on the
   Android container's next start: `systemctl stop waydroid-session &&
   systemctl restart waydroid-container`
9. `systemctl start waydroid-session`
10. Optional, to enable GPS mock locations (needs the session running,
    unlike the two steps above): `4-waydroid-tools/setup-gps.sh`, then
    `4-waydroid-tools/change-location.sh <lat> <lng>`.
11. Optional, for the GPS control webapp (needs `3-services/02-install-services.sh`
    already run - it unifies noVNC behind the webapp's own port by
    default): `5-webapp/install-webapp.sh`. See `5-webapp/README.md`.
12. Access: see the message printed at the end of installation, or the
    "Accessing the interface" section below.

## Accessing the interface

**If the webapp is installed** (the default via `0-deploy-all.sh`, or
manual step 11 above), it and noVNC are unified behind one port - see
`5-webapp/README.md`'s "Unified webapp + noVNC gateway" section for how.
The rest of this section describes noVNC's **own** exposure, which only
matters when the webapp is skipped (`--skip-webapp`) - once it's
installed, `--webapp-expose-lan` / `--no-webapp-expose-lan` control
external reachability for both instead, and noVNC's own port is always
forced back to loopback-only regardless of `--expose-lan` below.

By default (without `--expose-lan` / `EXPOSE_LAN=yes`), wayvnc and noVNC
only listen on `127.0.0.1` **inside the container**. From your machine:

```bash
ssh -L 6080:127.0.0.1:6080 root@<LXC_IP>
```

then open `http://127.0.0.1:6080/vnc.html`.

With `--expose-lan` / `EXPOSE_LAN=yes`, only **noVNC** (the web bridge, port
6080) is exposed on all interfaces; `wayvnc` (the raw VNC protocol, port
5900) always stays local - `websockify` connects to it internally, so
there's no need to expose it too for browser access. Handy if you already
reach your homelab over a VPN (the VPN then acts as the security perimeter,
since noVNC itself has no authentication):

```bash
./0-deploy-all.sh --expose-lan
```

then, from a machine connected to the VPN: `http://<LXC_IP>:6080/vnc.html`

Re-running `0-deploy-all.sh` (or `3-services/02-install-services.sh`
directly) against an existing container **without** `--expose-lan` /
`--no-expose-lan` **preserves** whichever mode is already configured -
it won't silently put an exposed deployment back behind a tunnel. Pass
`--no-expose-lan` explicitly to force tunnel-only access again.
`--webapp-expose-lan` doesn't preserve like this - it defaults to
tunnel-only on every run, so pass it again explicitly if you want it to
stick on a re-run.

## Project layout

* `0-deploy-all.sh` - Full orchestrator (host -> container -> services).
* `1-proxmox-host/` - Scripts/config applied on the Proxmox host.
* `2-lxc-setup/` - Installs Waydroid and its dependencies in the container.
* `3-services/` - systemd units (Sway headless, WayVNC, noVNC, Waydroid session).
* `4-waydroid-tools/` - Device spoofing, GPS, manual startup wrapper, Play
  Store emulated-storage workaround.
* `5-webapp/` - Flask webapp/API for GPS control (map UI, favorites), with
  noVNC unified behind its own port - see `5-webapp/README.md`.
* `tests/` - `lint.sh` (static, no Proxmox needed) and `smoke-test.sh` (run
  inside the container after deployment).
* `docs/` - Detailed debugging methodology.

## Architecture choice: Sway, not Weston

The Wayland compositor used is **Sway** (wlroots-based), in headless mode
(`WLR_BACKENDS=headless`, no `libinput` devices). This isn't arbitrary:
`wayvnc` depends on wlroots-specific protocols
(`zwlr_virtual_pointer_manager_v1` for remote keyboard/mouse, an
`xdg-output` revision Weston doesn't implement) - with Weston, `wayvnc`
consistently fails to start (`Failed to initialise wayland` / `invalid
version for global zxdg_output_manager_v1`). This is the combination
officially documented by the wayvnc project and the ArchWiki for headless
use.

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
* **noVNC/wayvnc unauthenticated by default**: by design, this repo binds
  them to `127.0.0.1` and recommends an SSH tunnel. The `--expose-lan` /
  `EXPOSE_LAN=yes` flag lifts that restriction but **adds no
  authentication** - only use it on a trusted local network. (Only
  applies when the webapp is skipped - see the next bullet.)
* **Webapp: API-key-gated, but the remote screen it links to still isn't**
  (`5-webapp/`, installed by default): the webapp itself requires a
  per-deployment API key for every action, but by unifying noVNC behind
  its own port (the default) it also becomes the thing controlling
  noVNC's external reachability - `--webapp-expose-lan` /
  `WEBAPP_EXPOSE_LAN=yes`, same trust model as `--expose-lan` above (no
  authentication on the VNC view itself). See `5-webapp/README.md`'s
  "Security" section for the full breakdown (favorites stored in plain
  JSON, Nominatim as a third-party geocoding dependency, etc.).
* **Unsigned third-party tool, applied automatically**
  (`4-waydroid-tools/03-setup-tools.sh` + `apply-spoof.sh`):
  `spoof-device.sh` is downloaded from an individual GitHub repo (`main`
  by default) and, by default, **run automatically** by `0-deploy-all.sh`
  before Waydroid's first boot. Set `SPOOF_REF` to pin a specific commit,
  and review `spoof-device.sh`'s content first if your threat model
  requires it - pass `--skip-spoof` to download it without running it.
  Either way, apply/re-apply it via `4-waydroid-tools/apply-spoof.sh`
  rather than running `spoof-device.sh` directly - the wrapper snapshots
  the pre-spoof configuration and makes re-applying it idempotent, and can
  roll the change back (see `docs/DEBUGGING_AND_TESTS.md`, Phase 4).
* **`ro.adb.secure=0`, applied automatically** (`4-waydroid-tools/enable-adb.sh`):
  disables Android's normal adb RSA-key authorization popup, the same way
  real emulators do by default, so `adb`/`waydroid adb connect` (and
  therefore GPS mock-location) work without a human clicking "Allow USB
  debugging" in noVNC at the exact moment Android boots. This means *any*
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
