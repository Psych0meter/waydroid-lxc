#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Installs the webapp: a Python venv with Flask/gunicorn/requests, a
# vendored (no CDN, no API key) copy of Leaflet for the map UI, and the
# waydroid-webapp systemd service.
#
# By default (WEBAPP_UNIFY_VNC=yes) it also installs nginx as a single
# external gateway in front of BOTH the webapp AND noVNC, so only one
# port needs to be reachable/tunneled for everything - nginx proxies /
# to the webapp and /vnc/ + /websockify to noVNC (see
# nginx-waydroid-webapp.conf for exactly how, including why noVNC's
# websocket endpoint has to be its own top-level location - verified
# against the actual installed noVNC package source, not assumed).
# Doing this moves BOTH gunicorn and novnc.service to bind 127.0.0.1
# only, ALWAYS, regardless of any prior EXPOSE_LAN setting on
# novnc.service - nginx becomes the sole exposure point for both from
# here on, controlled by WEBAPP_EXPOSE_LAN below. Pass
# WEBAPP_UNIFY_VNC=no to skip all of this and keep the old two-port
# setup (webapp and noVNC each reachable/exposed independently, novnc's
# own EXPOSE_LAN toggle in 3-services/02-install-services.sh still
# applies as before).
#
# Usage: WEBAPP_EXPOSE_LAN=yes ./install-webapp.sh
#   WEBAPP_EXPOSE_LAN   yes/no - binds the externally-reachable listener
#                       (nginx's, or gunicorn's own if
#                       WEBAPP_UNIFY_VNC=no) on 0.0.0.0 instead of
#                       127.0.0.1. Left unset, a re-run PRESERVES
#                       whichever mode is already configured (mirrors
#                       02-install-services.sh's EXPOSE_LAN handling for
#                       novnc.service), defaulting to "no" only when
#                       there's nothing to preserve.
#   WEBAPP_PORT         The port you actually connect to (default 8088) -
#                       nginx's listen port when WEBAPP_UNIFY_VNC=yes,
#                       gunicorn's own port directly otherwise. Stable
#                       across both modes, so existing tunnel commands
#                       keep working if you toggle WEBAPP_UNIFY_VNC.
#   WEBAPP_UNIFY_VNC    yes/no (default yes) - see above.
#   WEBAPP_INTERNAL_PORT  Only used when WEBAPP_UNIFY_VNC=yes: the
#                       loopback-only port gunicorn itself binds, behind
#                       nginx (default 8089). Never reachable directly.
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
WEBAPP_INTERNAL_PORT="${WEBAPP_INTERNAL_PORT:-8089}"
WEBAPP_DATA_DIR="${WEBAPP_DATA_DIR:-/var/lib/waydroid-webapp}"
WEBAPP_UNIFY_VNC="${WEBAPP_UNIFY_VNC:-yes}"
NOVNC_UNIT="/etc/systemd/system/novnc.service"
NGINX_SITE="/etc/nginx/sites-available/waydroid-webapp"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/waydroid-webapp"

echo "Installing Python prerequisites..."
apt-get update
apt-get install -y python3 python3-venv python3-pip curl ca-certificates

if [[ "${WEBAPP_UNIFY_VNC}" == "yes" ]]; then
  if [[ ! -f "${NOVNC_UNIT}" ]]; then
    echo "Error: ${NOVNC_UNIT} not found." >&2
    echo "Run 3-services/02-install-services.sh first, or pass WEBAPP_UNIFY_VNC=no" >&2
    echo "to install the webapp without unifying it with noVNC." >&2
    exit 1
  fi
  echo "Installing nginx (unifies the webapp and noVNC behind one port)..."
  apt-get install -y nginx
fi

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

# Resolve WEBAPP_EXPOSE_LAN the same way 02-install-services.sh resolves
# EXPOSE_LAN for novnc.service: an explicit value always wins; left
# unset, preserve whatever's already configured (checking nginx's site
# config or gunicorn's own bind address, whichever this mode uses);
# default to "no" only when there's nothing to preserve (a fresh
# install, or a first switch into/out of WEBAPP_UNIFY_VNC).
if [[ -z "${WEBAPP_EXPOSE_LAN:-}" ]]; then
  if [[ "${WEBAPP_UNIFY_VNC}" == "yes" && -f "${NGINX_SITE}" ]] && grep -q '^\s*listen 0\.0\.0\.0:' "${NGINX_SITE}"; then
    WEBAPP_EXPOSE_LAN="yes"
    echo "WEBAPP_EXPOSE_LAN not specified - already exposed on the LAN, preserving that."
  elif [[ "${WEBAPP_UNIFY_VNC}" != "yes" && -f "${ENV_FILE}" ]] && grep -q '^GUNICORN_HOST=0\.0\.0\.0$' "${ENV_FILE}"; then
    WEBAPP_EXPOSE_LAN="yes"
    echo "WEBAPP_EXPOSE_LAN not specified - already exposed on the LAN, preserving that."
  else
    WEBAPP_EXPOSE_LAN="no"
  fi
fi

if [[ "${WEBAPP_UNIFY_VNC}" == "yes" ]]; then
  # nginx is the sole external gateway now - gunicorn only ever needs to
  # be reachable from nginx itself, never directly.
  GUNICORN_HOST="127.0.0.1"
  GUNICORN_PORT="${WEBAPP_INTERNAL_PORT}"
else
  if [[ "${WEBAPP_EXPOSE_LAN}" == "yes" ]]; then
    GUNICORN_HOST="0.0.0.0"
  else
    GUNICORN_HOST="127.0.0.1"
  fi
  GUNICORN_PORT="${WEBAPP_PORT}"
fi

echo "Creating data directory ${WEBAPP_DATA_DIR} (favorites.json)..."
mkdir -p "${WEBAPP_DATA_DIR}"
chmod 700 "${WEBAPP_DATA_DIR}"

echo "Writing ${ENV_FILE} (GUNICORN_HOST=${GUNICORN_HOST}, GUNICORN_PORT=${GUNICORN_PORT})..."
mkdir -p "${CONF_DIR}"
cat > "${ENV_FILE}" <<EOF
GUNICORN_HOST=${GUNICORN_HOST}
GUNICORN_PORT=${GUNICORN_PORT}
WAYDROID_TOOLS_DIR=${WAYDROID_TOOLS_DIR}
WEBAPP_DATA_DIR=${WEBAPP_DATA_DIR}
WEBAPP_UNIFY_VNC=${WEBAPP_UNIFY_VNC}
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
# silently NOT take effect until something else restarted it - the same
# class of bug 3-services/02-install-services.sh had for EXPOSE_LAN/
# novnc.service (see docs/DEBUGGING_AND_TESTS.md, Phase 6).
systemctl restart waydroid-webapp

if [[ "${WEBAPP_UNIFY_VNC}" == "yes" ]]; then
  echo "Forcing novnc.service to listen on 127.0.0.1 only (nginx is now the"
  echo "single exposure point for both the webapp and noVNC)..."
  sed -i 's|^ExecStart=.*|ExecStart=/usr/bin/websockify --web=/usr/share/novnc/ 127.0.0.1:6080 127.0.0.1:5900|' "${NOVNC_UNIT}"
  systemctl daemon-reload
  systemctl restart novnc

  if [[ "${WEBAPP_EXPOSE_LAN}" == "yes" ]]; then
    NGINX_LISTEN="0.0.0.0:${WEBAPP_PORT}"
  else
    NGINX_LISTEN="127.0.0.1:${WEBAPP_PORT}"
  fi

  echo "Writing nginx site config (listen ${NGINX_LISTEN})..."
  sed \
    -e "s|__LISTEN__|${NGINX_LISTEN}|g" \
    -e "s|__GUNICORN_PORT__|${WEBAPP_INTERNAL_PORT}|g" \
    "${SCRIPT_DIR}/nginx-waydroid-webapp.conf" > "${NGINX_SITE}"
  mkdir -p /etc/nginx/sites-enabled
  ln -sf "${NGINX_SITE}" "${NGINX_SITE_ENABLED}"
  # The stock Debian default site also listens on port 80 and would
  # otherwise sit there doing nothing useful for this deployment -
  # disabling it avoids an extra open port nobody asked for.
  rm -f /etc/nginx/sites-enabled/default

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
fi

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
if [[ "${WEBAPP_UNIFY_VNC}" == "yes" ]]; then
  if [[ "${WEBAPP_EXPOSE_LAN}" == "yes" ]]; then
    echo " Web UI:       http://<CONTAINER_IP>:${WEBAPP_PORT}/"
    echo " Remote screen: http://<CONTAINER_IP>:${WEBAPP_PORT}/vnc/vnc.html"
    echo " WARNING: exposed on the LAN. Neither page has its own login -"
    echo " the API key gates webapp actions only, treat it like a password,"
    echo " and noVNC has no authentication at all (same as before)."
  else
    echo " Everything (webapp + remote screen), via one SSH tunnel:"
    echo "   ssh -L ${WEBAPP_PORT}:127.0.0.1:${WEBAPP_PORT} root@<CONTAINER_IP>"
    echo "   then open http://127.0.0.1:${WEBAPP_PORT}/"
    echo "   (remote screen: http://127.0.0.1:${WEBAPP_PORT}/vnc/vnc.html)"
  fi
else
  if [[ "${WEBAPP_EXPOSE_LAN}" == "yes" ]]; then
    echo " Web UI: http://<CONTAINER_IP>:${WEBAPP_PORT}/"
    echo " WARNING: exposed on the LAN. The UI page itself has no login,"
    echo " only the API key gates actions - treat that key like a password."
  else
    echo " Web UI (via SSH tunnel, nothing exposed directly):"
    echo "   ssh -L ${WEBAPP_PORT}:127.0.0.1:${WEBAPP_PORT} root@<CONTAINER_IP>"
    echo "   then open http://127.0.0.1:${WEBAPP_PORT}/"
  fi
  echo " (WEBAPP_UNIFY_VNC=no: noVNC is still on its own port/exposure -"
  echo " see 3-services/02-install-services.sh's EXPOSE_LAN.)"
fi
echo "============================================================"
