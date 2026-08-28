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
# it downloaded but unconfigured) and the GPS control + screen-control
# webapp (5-webapp/, pass --skip-webapp to leave it for later - see its
# README for why there's no separate VNC service to also install: the
# webapp talks to the device directly over adb).
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
# Applies the Pixel 5 spoof automatically as part of deployment (see step
# 4 below) - pass --skip-spoof to leave the downloaded spoof-device.sh
# unapplied (e.g. if your threat model requires reviewing it first; see
# the "Security" section of the README).
SPOOF_DEVICE="yes"
# Installs and configures the GPS mock-location app automatically once the
# session is up - pass --skip-gps-setup to leave it installed manually
# later via 4-waydroid-tools/setup-gps.sh.
SETUP_GPS="yes"
# Installs the GPS control + screen-control webapp (5-webapp/) automatically
# - pass --skip-webapp to leave it for later via 5-webapp/install-webapp.sh.
INSTALL_WEBAPP="yes"
# This is the ONLY external-exposure switch left in this script - there's
# no separate noVNC/wayvnc to toggle anymore (see 5-webapp/README.md,
# "Screen: remote control"). Defaults to a fixed "no" (not "preserve
# current setting" the way the old EXPOSE_LAN worked) - a from-scratch
# deploy should come up tunnel-only unless asked otherwise.
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
    --skip-spoof) SPOOF_DEVICE="no"; shift 1 ;;
    --skip-gps-setup) SETUP_GPS="no"; shift 1 ;;
    --skip-webapp) INSTALL_WEBAPP="no"; shift 1 ;;
    --webapp-expose-lan) WEBAPP_EXPOSE_LAN="yes"; shift 1 ;;
    --no-webapp-expose-lan) WEBAPP_EXPOSE_LAN="no"; shift 1 ;;
    -h|--help)
      echo "Usage: $0 [--ctid ID] [--hostname NAME] [--ip dhcp|A.B.C.D/CIDR] [--cpu N] [--ram MiB] [--disk GB]"
      echo "          [--skip-spoof] [--skip-gps-setup]"
      echo "          [--skip-webapp] [--webapp-expose-lan|--no-webapp-expose-lan]"
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
      echo "  --skip-webapp         Don't install the webapp (GPS control + screen control) - by"
      echo "                        default this script installs it automatically once GPS setup is"
      echo "                        done. Use 5-webapp/install-webapp.sh manually afterwards. With"
      echo "                        no webapp installed there is no remote-screen UI at all - see"
      echo "                        5-webapp/README.md."
      echo "  --webapp-expose-lan   Expose the webapp on 0.0.0.0 - every action still requires its"
      echo "                        API key, but treat the key like a password on an open network."
      echo "  --no-webapp-expose-lan  Force tunnel-only webapp access (the default)."
      echo "  Unlike some older flags this repo used to have for noVNC, this always defaults to"
      echo "  tunnel-only on every run, including a re-run against an existing deployment - it does"
      echo "  not preserve a prior --webapp-expose-lan. Pass it again explicitly to keep it exposed."
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

echo "    -> Installing services (Sway headless compositor + Waydroid session)..."
pct exec "${CTID}" -- bash "${REMOTE_DIR}/3-services/02-install-services.sh"

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

WEBAPP_MSG="Skipped (--skip-webapp) - install with 5-webapp/install-webapp.sh"
if [[ "${INSTALL_WEBAPP}" == "yes" ]]; then
  echo "    -> Installing the webapp (GPS control + adb-based screen control)..."
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
  # Read the actual listen address/port and API key back from the
  # container rather than assuming WEBAPP_PORT=8088 (only a default, and
  # webapp.env is the source of truth for what install-webapp.sh actually
  # configured, including on a re-run that preserved a prior exposure).
  WEBAPP_TOKEN="$(pct exec "${CTID}" -- cat /etc/waydroid-webapp/api-token 2>/dev/null || true)"
  WEBAPP_HOST_ACTUAL="$(pct exec "${CTID}" -- bash -c "grep -oP '(?<=^WEBAPP_HOST=).*' /etc/waydroid-webapp/webapp.env 2>/dev/null" || true)"
  WEBAPP_PORT_ACTUAL="$(pct exec "${CTID}" -- bash -c "grep -oP '(?<=^WEBAPP_PORT=).*' /etc/waydroid-webapp/webapp.env 2>/dev/null" || true)"
  if [[ "${WEBAPP_HOST_ACTUAL}" == "0.0.0.0" ]]; then
    ACCESS_MSG="Webapp (GPS control + screen): http://${CT_IP:-<CTID_IP>}:${WEBAPP_PORT_ACTUAL:-8088}/
   API key: ${WEBAPP_TOKEN:-<check /etc/waydroid-webapp/api-token>}
   WARNING: exposed on the LAN (--webapp-expose-lan). Every action still
   requires the API key above - treat it like a password."
  else
    ACCESS_MSG="Webapp (GPS control + screen), via SSH tunnel:
     ssh -L ${WEBAPP_PORT_ACTUAL:-8088}:127.0.0.1:${WEBAPP_PORT_ACTUAL:-8088} root@${CT_IP:-<CTID_IP>}
     then open http://127.0.0.1:${WEBAPP_PORT_ACTUAL:-8088}/
   API key: ${WEBAPP_TOKEN:-<check /etc/waydroid-webapp/api-token>}"
  fi
else
  ACCESS_MSG="No remote screen/control UI installed (--skip-webapp) - install it with
   5-webapp/install-webapp.sh, or drive the device directly with 'adb'/
   'waydroid shell' (see 4-waydroid-tools/)."
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
 apparmor unconfined) before using this in production.
============================================================
EOF
