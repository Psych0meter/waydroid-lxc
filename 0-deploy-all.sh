#!/usr/bin/env bash
#
# 0-deploy-all.sh - all-in-one orchestrator, run on the Proxmox host.
#
# Pipeline: prepares the host, creates a privileged Debian 13 LXC via
# community-scripts/ProxmoxVE, injects the binder/apparmor/cgroup config,
# restarts the container, then runs the install scripts inside it in order
# (2-lxc-setup -> 3-services -> 4-waydroid-tools), applying the Pixel 5
# device spoof (pass --skip-spoof to leave it downloaded but unapplied)
# and always enabling headless adb authorization (ro.adb.secure=0 - see
# 4-waydroid-tools/enable-adb.sh), then restarting the container before
# Waydroid's first boot, then - once the session is up - installing and
# configuring the GPS mock-location app (pass --skip-gps-setup to leave
# it downloaded but unconfigured) and the GPS control webapp (5-webapp/,
# pass --skip-webapp to leave it for later).
#
# ct/debian.sh from community-scripts is normally interactive (whiptail);
# this wrapper pre-fills its var_* environment variables to force
# "Default Settings" mode. Run from a real console (not cron/CI) in case a
# future version still shows a dialog.
#
# Usage:
#   ./0-deploy-all.sh [--ctid ID] [--hostname NAME] [--ip dhcp|A.B.C.D/CIDR]
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Defaults and argument parsing
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CT_HOSTNAME="waydroid"
CT_ID=""
CT_NET="dhcp"
CT_CPU=4
CT_RAM=4096
CT_DISK=16
# Left unset by default (not "no"): on a re-run against an existing
# container, 02-install-services.sh preserves whatever EXPOSE_LAN mode is
# already configured when this is unset, rather than silently reverting
# it - see that script for details. --expose-lan / --no-expose-lan force
# an explicit value either way.
EXPOSE_LAN=""
# Applies the Pixel 5 spoof automatically as part of deployment (see step
# 4 below) - pass --skip-spoof to leave the downloaded spoof-device.sh
# unapplied (e.g. if your threat model requires reviewing it first; see
# the "Security" section of the README).
SPOOF_DEVICE="yes"
# Installs and configures the GPS mock-location app automatically once the
# session is up - pass --skip-gps-setup to leave it installed manually
# later via 4-waydroid-tools/setup-gps.sh.
SETUP_GPS="yes"
# Installs the GPS control webapp (5-webapp/) automatically, behind its
# own nginx-fronted gateway (also unifying noVNC onto that same port) -
# pass --skip-webapp to leave it for later via 5-webapp/install-webapp.sh.
INSTALL_WEBAPP="yes"
# Unlike EXPOSE_LAN above, this defaults to a fixed "no" rather than
# "preserve current setting" - a fresh WEBAPP_EXPOSE_LAN=no start models
# this script's own "safe by default" posture for a from-scratch deploy.
# --webapp-expose-lan / --no-webapp-expose-lan force an explicit value.
WEBAPP_EXPOSE_LAN="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2 ;;
    --hostname) CT_HOSTNAME="$2"; shift 2 ;;
    --ip) CT_NET="$2"; shift 2 ;;
    --cpu) CT_CPU="$2"; shift 2 ;;
    --ram) CT_RAM="$2"; shift 2 ;;
    --disk) CT_DISK="$2"; shift 2 ;;
    --expose-lan) EXPOSE_LAN="yes"; shift 1 ;;
    --no-expose-lan) EXPOSE_LAN="no"; shift 1 ;;
    --skip-spoof) SPOOF_DEVICE="no"; shift 1 ;;
    --skip-gps-setup) SETUP_GPS="no"; shift 1 ;;
    --skip-webapp) INSTALL_WEBAPP="no"; shift 1 ;;
    --webapp-expose-lan) WEBAPP_EXPOSE_LAN="yes"; shift 1 ;;
    --no-webapp-expose-lan) WEBAPP_EXPOSE_LAN="no"; shift 1 ;;
    -h|--help)
      echo "Usage: $0 [--ctid ID] [--hostname NAME] [--ip dhcp|A.B.C.D/CIDR] [--cpu N] [--ram MiB] [--disk GB]"
      echo "          [--expose-lan|--no-expose-lan] [--skip-spoof] [--skip-gps-setup]"
      echo "          [--skip-webapp] [--webapp-expose-lan|--no-webapp-expose-lan]"
      echo ""
      echo "  --expose-lan     Expose noVNC/wayvnc on 0.0.0.0 WITHOUT authentication (not recommended)."
      echo "  --no-expose-lan  Force tunnel-only access (SSH tunnel, see README), even on a re-run"
      echo "                   against a container that currently has --expose-lan applied."
      echo "  Passing neither on a fresh container defaults to tunnel-only; re-running against an"
      echo "  existing container without either flag PRESERVES its current exposure setting."
      echo ""
      echo "  --skip-spoof     Download spoof-device.sh (device identity spoofing) but don't run"
      echo "                   it - by default this script applies it automatically, before the"
      echo "                   Waydroid session's first boot, so About Phone shows Pixel 5 right"
      echo "                   away. Use 4-waydroid-tools/apply-spoof.sh manually afterwards."
      echo ""
      echo "  --skip-gps-setup Download the GPS mock-location app but don't install/configure it -"
      echo "                   by default this script does so automatically once the session is up."
      echo "                   Use 4-waydroid-tools/setup-gps.sh manually afterwards."
      echo ""
      echo "  --skip-webapp         Don't install the GPS control webapp - by default this script"
      echo "                        installs it automatically once GPS setup is done. Use"
      echo "                        5-webapp/install-webapp.sh manually afterwards."
      echo "  --webapp-expose-lan   Expose the webapp (and noVNC, unified behind it) on 0.0.0.0,"
      echo "                        API-key-gated but WITHOUT authentication on the remote-screen"
      echo "                        view (not recommended)."
      echo "  --no-webapp-expose-lan  Force tunnel-only webapp access (the default)."
      echo "  Unlike --expose-lan/--no-expose-lan above, this always defaults to tunnel-only on"
      echo "  every run, including a re-run against an existing deployment - it does not preserve"
      echo "  a prior --webapp-expose-lan. Pass it again explicitly if you want it to stick."
      exit 0
      ;;
    *) echo "Error: unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root on the Proxmox node." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "Error: 'pct' not found. This script must run on a Proxmox VE host." >&2
  exit 1
fi

echo "==> [1/5] Preparing the Proxmox host (binder/loop kernel modules)"
bash "${SCRIPT_DIR}/1-proxmox-host/enable-binder.sh"

# ---------------------------------------------------------------------------
# 1. Container creation via community-scripts (Debian 13, PRIVILEGED)
# ---------------------------------------------------------------------------
echo "==> [2/5] Creating the Debian LXC via community-scripts/ProxmoxVE"

export var_hostname="${CT_HOSTNAME}"
export var_unprivileged=0   # Required: binder device and hardware access need a privileged CT
export var_cpu="${CT_CPU}"
export var_ram="${CT_RAM}"
export var_disk="${CT_DISK}"
export var_net="${CT_NET}"
export var_os=debian
export var_version=13
export var_tags="waydroid"
export var_nesting=1
export var_fuse=yes        # Required for Android's FUSE-based "emulated" storage
export var_verbose=no
[[ -n "${CT_ID}" ]] && export var_ctid="${CT_ID}"

# NEXTID is picked by the script itself when var_ctid isn't set.
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh)"

# Find the CTID that was actually created (most recent container with the
# "waydroid" tag and the requested hostname), in case var_ctid wasn't set.
if [[ -n "${CT_ID}" ]]; then
  FOUND_CTID="${CT_ID}"
else
  FOUND_CTID="$(pct list | awk -v hn="${CT_HOSTNAME}" '$0 ~ hn {print $1}' | tail -n1)"
fi

if [[ -z "${FOUND_CTID}" ]] || ! pct config "${FOUND_CTID}" >/dev/null 2>&1; then
  echo "Error: could not determine the CTID of the created container." >&2
  echo "Check with 'pct list', then rerun with --ctid <ID> to resume deployment." >&2
  exit 1
fi
CTID="${FOUND_CTID}"
echo "    -> Container created: CTID=${CTID}"

# Safety net in case var_fuse wasn't honored at creation time.
CURRENT_FEATURES="$(pct config "${CTID}" | awk -F': ' '/^features:/ {print $2}')"
if [[ "${CURRENT_FEATURES}" != *fuse=1* ]]; then
  echo "    -> Adding fuse=1 to the CT features (missing after creation)"
  NEW_FEATURES="${CURRENT_FEATURES:+${CURRENT_FEATURES},}fuse=1"
  pct set "${CTID}" -features "${NEW_FEATURES}"
fi

# ---------------------------------------------------------------------------
# 2. Injecting the binder / apparmor / cgroup configuration
# ---------------------------------------------------------------------------
echo "==> [3/5] Applying the LXC configuration (binder device, apparmor)"

CONF_FILE="/etc/pve/lxc/${CTID}.conf"
if [[ ! -f "${CONF_FILE}" ]]; then
  echo "Error: ${CONF_FILE} not found." >&2
  exit 1
fi

# Idempotent: skip re-injecting if a marker directive is already present.
if ! grep -q "lxc.apparmor.profile: unconfined" "${CONF_FILE}"; then
  {
    echo ""
    grep -v '^#' "${SCRIPT_DIR}/1-proxmox-host/lxc-config-append.txt"
  } >> "${CONF_FILE}"
  echo "    -> Binder configuration appended to ${CONF_FILE}"
else
  echo "    -> Binder configuration already present, leaving ${CONF_FILE} untouched"
fi

echo "==> Restarting container ${CTID}"
pct stop "${CTID}" >/dev/null 2>&1 || true
sleep 2
pct start "${CTID}"

echo "==> Waiting for the container's network to come up..."
for _ in $(seq 1 30); do
  if pct exec "${CTID}" -- true >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# 3. Copying the repo into the container and running the pipeline
# ---------------------------------------------------------------------------
echo "==> [4/5] Copying scripts into the container and installing Waydroid"

REMOTE_DIR="/opt/waydroid-lxc-deploy"
pct exec "${CTID}" -- mkdir -p "${REMOTE_DIR}"
# 'pct push' only handles one file at a time: archive first, extract inside the container.
TMP_TAR="$(mktemp)"
tar -C "${SCRIPT_DIR}" -czf "${TMP_TAR}" \
  --exclude='5-webapp/__pycache__' --exclude='5-webapp/static/vendor' \
  2-lxc-setup 3-services 4-waydroid-tools 5-webapp
pct push "${CTID}" "${TMP_TAR}" "${REMOTE_DIR}/payload.tar.gz"
rm -f "${TMP_TAR}"
pct exec "${CTID}" -- tar -C "${REMOTE_DIR}" -xzf "${REMOTE_DIR}/payload.tar.gz"

echo "    -> Installing Waydroid (this can take a few minutes)..."
pct exec "${CTID}" -- bash "${REMOTE_DIR}/2-lxc-setup/01-install-waydroid.sh"

echo "    -> Installing services (sway/wayvnc/novnc)..."
pct exec "${CTID}" -- env "EXPOSE_LAN=${EXPOSE_LAN}" bash "${REMOTE_DIR}/3-services/02-install-services.sh"

echo "    -> Fetching Waydroid tools (device spoofing/GPS)..."
pct exec "${CTID}" -- bash -c "cd '${REMOTE_DIR}/4-waydroid-tools' && bash 03-setup-tools.sh"

if [[ "${SPOOF_DEVICE}" == "yes" ]]; then
  echo "    -> Applying device spoof (Pixel 5) before Waydroid's first boot..."
  pct exec "${CTID}" -- bash -c "cd '${REMOTE_DIR}/4-waydroid-tools' && chmod +x apply-spoof.sh && ./apply-spoof.sh"
else
  echo "    -> --skip-spoof: spoof-device.sh downloaded but not applied (see 4-waydroid-tools/apply-spoof.sh)."
fi

echo "    -> Enabling headless adb authorization (ro.adb.secure=0) before Waydroid's first boot..."
pct exec "${CTID}" -- bash -c "cd '${REMOTE_DIR}/4-waydroid-tools' && chmod +x enable-adb.sh && ./enable-adb.sh"

# waydroid-session isn't running yet on a fresh deployment, but might be
# on a re-run against an existing container - stop it first (harmless if
# already stopped) so the container restart below is what actually
# applies the new waydroid_base.prop, not a no-op on an active session.
pct exec "${CTID}" -- systemctl stop waydroid-session >/dev/null 2>&1 || true
pct exec "${CTID}" -- systemctl restart waydroid-container

echo "==> [5/5] Starting the Waydroid session"
pct exec "${CTID}" -- systemctl enable --now waydroid-session.service

GPS_MSG="Skipped (--skip-gps-setup) - install with 4-waydroid-tools/setup-gps.sh"
if [[ "${SETUP_GPS}" == "yes" ]]; then
  echo "    -> Setting up the GPS mock-location app (waits for Android's first boot, up to 3 min)..."
  if pct exec "${CTID}" -- bash -c "cd '${REMOTE_DIR}/4-waydroid-tools' && chmod +x setup-gps.sh && ./setup-gps.sh"; then
    GPS_MSG="Ready - set a location with 4-waydroid-tools/change-location.sh <lat> <lng>"
  else
    GPS_MSG="FAILED (see the error above) - retry with: pct exec ${CTID} -- bash -c \"cd ${REMOTE_DIR}/4-waydroid-tools && ./setup-gps.sh\""
    echo "    -> Warning: GPS setup failed - this doesn't affect the rest of the deployment." >&2
  fi
fi

# install-webapp.sh's own default (WEBAPP_UNIFY_VNC=yes) forces
# novnc.service to bind 127.0.0.1 permanently, regardless of whatever
# EXPOSE_LAN set for it in step 2 above - the webapp's own gateway
# (controlled by WEBAPP_EXPOSE_LAN, not EXPOSE_LAN) becomes the only
# externally-reachable path to both. That's why the final access message
# below is computed AFTER this step, from the container's actual state,
# rather than trusting $EXPOSE_LAN.
WEBAPP_MSG="Skipped (--skip-webapp) - install with 5-webapp/install-webapp.sh"
if [[ "${INSTALL_WEBAPP}" == "yes" ]]; then
  echo "    -> Installing the GPS control webapp (unifies noVNC behind the same port)..."
  if pct exec "${CTID}" -- env "WEBAPP_EXPOSE_LAN=${WEBAPP_EXPOSE_LAN}" \
       bash -c "cd '${REMOTE_DIR}/5-webapp' && chmod +x install-webapp.sh && ./install-webapp.sh"; then
    WEBAPP_MSG="Ready"
  else
    WEBAPP_MSG="FAILED (see the error above) - retry with: pct exec ${CTID} -- env WEBAPP_EXPOSE_LAN=${WEBAPP_EXPOSE_LAN} bash -c \"cd ${REMOTE_DIR}/5-webapp && ./install-webapp.sh\""
    echo "    -> Warning: webapp install failed - this doesn't affect the rest of the deployment." >&2
  fi
fi

CT_IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"

if [[ "${WEBAPP_MSG}" == "Ready" ]]; then
  # The webapp's nginx gateway is now the sole externally-reachable path
  # to both it and noVNC - read its actual listen address/port and API
  # key back from the container rather than assuming WEBAPP_PORT=8088
  # (only a default, and never written to webapp.env for us to re-read).
  WEBAPP_TOKEN="$(pct exec "${CTID}" -- cat /etc/waydroid-webapp/api-token 2>/dev/null || true)"
  WEBAPP_LISTEN="$(pct exec "${CTID}" -- bash -c "grep -oP '(?<=listen ).*(?=;)' /etc/nginx/sites-available/waydroid-webapp 2>/dev/null" || true)"
  WEBAPP_PORT_ACTUAL="${WEBAPP_LISTEN##*:}"
  if [[ "${WEBAPP_LISTEN}" == 0.0.0.0:* ]]; then
    ACCESS_MSG="Webapp (GPS control + remote screen): http://${CT_IP:-<CTID_IP>}:${WEBAPP_PORT_ACTUAL:-8088}/
   Remote screen:  http://${CT_IP:-<CTID_IP>}:${WEBAPP_PORT_ACTUAL:-8088}/vnc/vnc.html
   API key:        ${WEBAPP_TOKEN:-<check /etc/waydroid-webapp/api-token>}
   WARNING: exposed on the LAN (--webapp-expose-lan). The API key gates
   webapp actions only - the remote screen has no authentication at all."
  else
    ACCESS_MSG="Webapp + remote screen, via one SSH tunnel:
     ssh -L ${WEBAPP_PORT_ACTUAL:-8088}:127.0.0.1:${WEBAPP_PORT_ACTUAL:-8088} root@${CT_IP:-<CTID_IP>}
     then open http://127.0.0.1:${WEBAPP_PORT_ACTUAL:-8088}/  (remote screen: .../vnc/vnc.html)
   API key: ${WEBAPP_TOKEN:-<check /etc/waydroid-webapp/api-token>}"
  fi
else
  # Webapp not installed (or failed) - fall back to noVNC's own direct
  # access, same as before the webapp existed. Query the container's
  # actual, resolved state rather than trusting the local $EXPOSE_LAN
  # variable: when left unset, 02-install-services.sh decides the real
  # value itself (preserving whatever was already configured on a
  # re-run) inside that separate pct exec invocation.
  ACTUAL_EXPOSE_LAN="$(pct exec "${CTID}" -- bash -c "grep -q '0\.0\.0\.0:6080' /etc/systemd/system/novnc.service 2>/dev/null && echo yes || echo no")"
  if [[ "${ACTUAL_EXPOSE_LAN}" == "yes" ]]; then
    ACCESS_MSG="noVNC access: http://${CT_IP:-<CTID_IP>}:6080/vnc.html
   WARNING: exposed on the LAN WITHOUT authentication (--expose-lan)."
  else
    ACCESS_MSG="noVNC access (via SSH tunnel, nothing exposed directly):
     ssh -L 6080:127.0.0.1:6080 root@${CT_IP:-<CTID_IP>}
     then open http://127.0.0.1:6080/vnc.html"
  fi
fi

if [[ "${SPOOF_DEVICE}" == "yes" ]]; then
  SPOOF_MSG="Applied (About Phone should show Pixel 5) - roll back with apply-spoof.sh --rollback"
else
  SPOOF_MSG="Skipped (--skip-spoof) - apply with 4-waydroid-tools/apply-spoof.sh"
fi

cat <<EOF

============================================================
 Deployment complete.
   CTID           : ${CTID}
   ${ACCESS_MSG}
   Device spoofing: ${SPOOF_MSG}
   GPS mock-location: ${GPS_MSG}
   Webapp         : ${WEBAPP_MSG}
   Directory      : ${REMOTE_DIR} (inside the container)

 See the "Security" section of the README (privileged container,
 apparmor unconfined, VNC access) before using this in production.
============================================================
EOF
