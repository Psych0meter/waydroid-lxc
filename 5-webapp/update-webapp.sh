#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Checks GitHub for a newer commit of 5-webapp/ than what's currently
# installed and, if one exists, updates the running webapp in place:
# backs up the current install, clones the target ref, syncs its
# 5-webapp/ files in (preserving the locally-vendored static/vendor/ -
# it's .gitignore'd, not part of the repo, so a fresh clone never has
# it), reinstalls Python dependencies, regenerates the systemd unit,
# restarts the service, and verifies /api/health responds before
# declaring success. Rolls back to the previous install automatically
# if any step fails.
#
# Everything the webapp itself doesn't own - the API key
# (/etc/waydroid-webapp/api-token), favorites.json, device spoofing, GPS
# setup - lives outside 5-webapp/ and is untouched. This only updates
# the webapp; re-run 0-deploy-all.sh or the other per-step scripts for
# the rest of the deployment.
#
# Usage: ./update-webapp.sh [--check] [--ref <branch>] [--force]
#   --check         Report whether an update is available; don't apply it.
#   --ref <branch>  Git ref to track (default: main, or $WEBAPP_UPDATE_REF).
#   --force         Re-sync even if already on the latest commit.
#   WEBAPP_REPO_URL Repo to update from (default: this project's GitHub).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root inside the container." >&2
  exit 1
fi

REPO_URL="${WEBAPP_REPO_URL:-https://github.com/Psych0meter/waydroid-lxc.git}"
REF="${WEBAPP_UPDATE_REF:-main}"
CHECK_ONLY=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --ref) REF="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--check] [--ref <branch>] [--force]"
      exit 0
      ;;
    *) echo "Error: unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Locate the current install from the deployed systemd unit -------------
# install-webapp.sh renders __APP_DIR__/__VENV_DIR__ into this file, so it's
# the source of truth for where the running code actually lives - avoids
# hardcoding /opt/waydroid-lxc-deploy/5-webapp and silently updating the
# wrong copy if it was ever installed somewhere else.
UNIT_FILE="/etc/systemd/system/waydroid-webapp.service"
if [[ ! -f "${UNIT_FILE}" ]]; then
  echo "Error: ${UNIT_FILE} not found - the webapp isn't installed yet. Run install-webapp.sh first." >&2
  exit 1
fi
APP_DIR="$(grep -oP '(?<=^WorkingDirectory=).*' "${UNIT_FILE}")"
VENV_DIR="$(grep -oP '(?<=^ExecStart=)[^[:space:]]+(?=/bin/gunicorn)' "${UNIT_FILE}")"
if [[ -z "${APP_DIR}" || -z "${VENV_DIR}" || ! -d "${APP_DIR}" ]]; then
  echo "Error: couldn't determine the install directory from ${UNIT_FILE}." >&2
  exit 1
fi

CONF_DIR="/etc/waydroid-webapp"
VERSION_FILE="${CONF_DIR}/installed-version"
CURRENT_VERSION="$(cat "${VERSION_FILE}" 2>/dev/null || echo "unknown")"

echo "Checking ${REPO_URL} (${REF}) for updates..."
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

if ! git clone --quiet --depth 1 --branch "${REF}" "${REPO_URL}" "${TMP_DIR}/repo"; then
  echo "Error: failed to clone ${REPO_URL} (${REF}) - check network access and that the ref exists." >&2
  exit 1
fi
REMOTE_VERSION="$(git -C "${TMP_DIR}/repo" rev-parse HEAD)"

echo "Installed: ${CURRENT_VERSION}"
echo "Latest:    ${REMOTE_VERSION} (${REF})"

if [[ "${CURRENT_VERSION}" == "${REMOTE_VERSION}" && "${FORCE}" -eq 0 ]]; then
  echo "Already up to date."
  exit 0
fi

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
  if [[ "${CURRENT_VERSION}" == "unknown" ]]; then
    echo "Update available (installed version unknown - typically means this"
    echo "was deployed via 0-deploy-all.sh, which doesn't track a version;"
    echo "the next non-check run will record one)."
  else
    echo "Update available."
  fi
  exit 0
fi

NEW_APP_DIR="${TMP_DIR}/repo/5-webapp"
if [[ ! -d "${NEW_APP_DIR}" ]]; then
  echo "Error: ${REF} has no 5-webapp/ directory - refusing to update." >&2
  exit 1
fi

# --- Sync files, preserving what isn't part of the repo --------------------
sync_tree() {
  local src="$1" dst="$2"; shift 2
  local skip=("$@")
  mkdir -p "${dst}"
  local path name entry keep
  for path in "${src}"/* "${src}"/.[!.]*; do
    [[ -e "${path}" ]] || continue
    name="$(basename "${path}")"
    keep=0
    for entry in "${skip[@]}"; do
      [[ "${name}" == "${entry}" ]] && keep=1 && break
    done
    [[ "${keep}" -eq 1 ]] && continue
    rm -rf "${dst:?}/${name}"
    cp -a "${path}" "${dst}/"
  done
}

BACKUP_DIR="${APP_DIR}.prev"
echo "Backing up the current install to ${BACKUP_DIR}..."
rm -rf "${BACKUP_DIR}"
cp -a "${APP_DIR}" "${BACKUP_DIR}"

STAGE="starting"
rollback() {
  echo "Update failed during: ${STAGE}. Rolling back to the previous version..." >&2
  rm -rf "${APP_DIR}"
  mv "${BACKUP_DIR}" "${APP_DIR}"
  systemctl daemon-reload 2>/dev/null || true
  systemctl restart waydroid-webapp 2>/dev/null || true
}
trap rollback ERR

STAGE="syncing files into ${APP_DIR}"
echo "Syncing new files into ${APP_DIR}..."
sync_tree "${NEW_APP_DIR}" "${APP_DIR}" static
sync_tree "${NEW_APP_DIR}/static" "${APP_DIR}/static" vendor
find "${APP_DIR}" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

STAGE="reinstalling Python dependencies"
echo "Reinstalling Python dependencies..."
"${VENV_DIR}/bin/pip" install --upgrade -r "${APP_DIR}/requirements.txt" >/tmp/update-webapp-pip.log 2>&1

STAGE="regenerating the systemd unit"
echo "Regenerating the systemd unit..."
sed \
  -e "s|__APP_DIR__|${APP_DIR}|g" \
  -e "s|__VENV_DIR__|${VENV_DIR}|g" \
  "${APP_DIR}/waydroid-webapp.service" > "${UNIT_FILE}"
systemctl daemon-reload

STAGE="restarting waydroid-webapp"
echo "Restarting waydroid-webapp..."
systemctl restart waydroid-webapp

STAGE="waiting for /api/health after restart"
echo "Waiting for the webapp to come back up..."
WEBAPP_HOST="127.0.0.1"
WEBAPP_PORT="8088"
if [[ -f "${CONF_DIR}/webapp.env" ]]; then
  # shellcheck disable=SC1091
  source "${CONF_DIR}/webapp.env"
fi
HEALTHY=0
for _ in $(seq 1 15); do
  if curl -fsS "http://${WEBAPP_HOST}:${WEBAPP_PORT}/api/health" >/dev/null 2>&1; then
    HEALTHY=1
    break
  fi
  sleep 1
done
if [[ "${HEALTHY}" -ne 1 ]]; then
  echo "/api/health did not respond after restart (see: journalctl -u waydroid-webapp)." >&2
  false
fi

trap - ERR
echo "${REMOTE_VERSION}" > "${VERSION_FILE}"
rm -rf "${BACKUP_DIR}"
echo ""
echo "Updated ${CURRENT_VERSION} -> ${REMOTE_VERSION} (${REF})."
