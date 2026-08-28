#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Installs the webapp: a Python venv with Flask/gunicorn/requests/adbutils,
# a vendored (no CDN, no API key) copy of Leaflet for the map UI, and the
# waydroid-webapp systemd service, bound directly to WEBAPP_HOST:WEBAPP_PORT.
# The webapp talks to the device directly over adb (adbutils), so no
# reverse proxy or VNC session is needed in front of it.
#
# Usage: WEBAPP_EXPOSE_LAN=yes ./install-webapp.sh
#   WEBAPP_EXPOSE_LAN   yes/no - binds 0.0.0.0 instead of 127.0.0.1. Left
#                       unset, a re-run PRESERVES whichever mode is
#                       already configured, defaulting to "no" only when
#                       there's nothing to preserve.
#   WEBAPP_PORT         TCP port (default 8088).
#   WAYDROID_TOOLS_DIR  Where change-location.sh lives (default matches a
#                       standard 0-deploy-all.sh deployment).
#   WEBAPP_DATA_DIR     Where favorites.json is stored (default
#                       /var/lib/waydroid-webapp).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root inside the container." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="/opt/waydroid-webapp-venv"
CONF_DIR="/etc/waydroid-webapp"
ENV_FILE="${CONF_DIR}/webapp.env"
LEAFLET_VERSION="${LEAFLET_VERSION:-1.9.4}"
VENDOR_DIR="${SCRIPT_DIR}/static/vendor/leaflet"
WAYDROID_TOOLS_DIR="${WAYDROID_TOOLS_DIR:-/opt/waydroid-lxc-deploy/4-waydroid-tools}"
WEBAPP_PORT="${WEBAPP_PORT:-8088}"
WEBAPP_DATA_DIR="${WEBAPP_DATA_DIR:-/var/lib/waydroid-webapp}"

echo "Installing prerequisites..."
apt-get update
# adb: needed by adbutils (actions/screen.py) to talk to the Waydroid
# container - same package 4-waydroid-tools/setup-gps.sh installs, listed
# again here so the webapp's screen feature works even if GPS setup was
# skipped (--skip-gps-setup). Installing it twice is a harmless no-op.
apt-get install -y python3 python3-venv python3-pip curl ca-certificates adb

echo "Creating virtualenv at ${VENV_DIR}..."
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip >/dev/null
"${VENV_DIR}/bin/pip" install -r "${SCRIPT_DIR}/requirements.txt"

echo "Vendoring Leaflet ${LEAFLET_VERSION} (map UI, no API key needed)..."
mkdir -p "${VENDOR_DIR}/images"
fetch() {
  curl -fsSL "$1" -o "$2"
}
fetch "https://unpkg.com/leaflet@${LEAFLET_VERSION}/dist/leaflet.js" "${VENDOR_DIR}/leaflet.js"
fetch "https://unpkg.com/leaflet@${LEAFLET_VERSION}/dist/leaflet.css" "${VENDOR_DIR}/leaflet.css"
for img in marker-icon.png marker-icon-2x.png marker-shadow.png; do
  fetch "https://unpkg.com/leaflet@${LEAFLET_VERSION}/dist/images/${img}" "${VENDOR_DIR}/images/${img}"
done

# An explicit value always wins; left unset, preserve whatever is already
# configured (checking webapp.env's own prior bind address) rather than
# silently reverting an exposed deployment on an unrelated re-run;
# default to "no" only when there's nothing to preserve.
if [[ -z "${WEBAPP_EXPOSE_LAN:-}" ]]; then
  if [[ -f "${ENV_FILE}" ]] && grep -q '^WEBAPP_HOST=0\.0\.0\.0$' "${ENV_FILE}"; then
    WEBAPP_EXPOSE_LAN="yes"
    echo "WEBAPP_EXPOSE_LAN not specified - already exposed on the LAN, preserving that."
  else
    WEBAPP_EXPOSE_LAN="no"
  fi
fi

if [[ "${WEBAPP_EXPOSE_LAN}" == "yes" ]]; then
  WEBAPP_HOST="0.0.0.0"
else
  WEBAPP_HOST="127.0.0.1"
fi

echo "Creating data directory ${WEBAPP_DATA_DIR} (favorites.json)..."
mkdir -p "${WEBAPP_DATA_DIR}"
chmod 700 "${WEBAPP_DATA_DIR}"

echo "Writing ${ENV_FILE} (WEBAPP_HOST=${WEBAPP_HOST}, WEBAPP_PORT=${WEBAPP_PORT})..."
mkdir -p "${CONF_DIR}"
cat > "${ENV_FILE}" <<EOF
WEBAPP_HOST=${WEBAPP_HOST}
WEBAPP_PORT=${WEBAPP_PORT}
WAYDROID_TOOLS_DIR=${WAYDROID_TOOLS_DIR}
WEBAPP_DATA_DIR=${WEBAPP_DATA_DIR}
EOF

echo "Installing systemd service..."
sed \
  -e "s|__APP_DIR__|${SCRIPT_DIR}|g" \
  -e "s|__VENV_DIR__|${VENV_DIR}|g" \
  "${SCRIPT_DIR}/waydroid-webapp.service" > /etc/systemd/system/waydroid-webapp.service
systemctl daemon-reload
systemctl enable waydroid-webapp
# Unconditional restart, not 'enable --now': on a re-run against an
# already-running service, --now alone is a no-op for units that are
# already active, so a changed WEBAPP_EXPOSE_LAN/WEBAPP_PORT would
# silently NOT take effect until something else restarted it.
systemctl restart waydroid-webapp

echo "Waiting for the API token to be generated..."
TOKEN_FILE="${CONF_DIR}/api-token"
for _ in $(seq 1 15); do
  [[ -s "${TOKEN_FILE}" ]] && break
  sleep 1
done

echo ""
echo "============================================================"
if [[ -s "${TOKEN_FILE}" ]]; then
  echo " API key: $(cat "${TOKEN_FILE}")"
else
  echo " API key not generated yet - check: systemctl status waydroid-webapp"
  echo " and once it's up, read it from ${TOKEN_FILE}"
fi
if [[ "${WEBAPP_EXPOSE_LAN}" == "yes" ]]; then
  echo " Web UI: http://<CONTAINER_IP>:${WEBAPP_PORT}/"
  echo " WARNING: exposed on the LAN. The UI page itself has no login,"
  echo " only the API key gates actions - treat that key like a password."
else
  echo " Web UI (via SSH tunnel, nothing exposed directly):"
  echo "   ssh -L ${WEBAPP_PORT}:127.0.0.1:${WEBAPP_PORT} root@<CONTAINER_IP>"
  echo "   then open http://127.0.0.1:${WEBAPP_PORT}/"
fi
echo " Screen: click \"Start screen\" in the UI - live device control over"
echo " adb (screenshots + tap/swipe/text), no separate VNC session needed."
echo "============================================================"
