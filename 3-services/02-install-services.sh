#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Par défaut, wayvnc/websockify n'écoutent que sur 127.0.0.1 (accès via
# tunnel SSH uniquement — voir README section "Sécurité"). Pour exposer
# directement sur le réseau local (sans authentification côté VNC !):
#   EXPOSE_LAN=yes ./02-install-services.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en root dans le conteneur." >&2
  exit 1
fi

EXPOSE_LAN="${EXPOSE_LAN:-no}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Copying weston.ini..."
mkdir -p /etc/xdg/weston
cp "${REPO_ROOT}/2-lxc-setup/weston.ini" /etc/xdg/weston/weston.ini

echo "Installing helper scripts..."
install -m 0755 "${SCRIPT_DIR}/wait-for-wayland-socket.sh" /usr/local/bin/wait-for-wayland-socket.sh

echo "Installing systemd services..."
cp "${SCRIPT_DIR}/weston.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/wayvnc.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/novnc.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/waydroid-session.service" /etc/systemd/system/

if [[ "${EXPOSE_LAN}" == "yes" ]]; then
  echo "!!! EXPOSE_LAN=yes : wayvnc et noVNC vont écouter sur 0.0.0.0 SANS AUTHENTIFICATION."
  sed -i 's/127\.0\.0\.1 5900/0.0.0.0 5900/' /etc/systemd/system/wayvnc.service
  sed -i 's/127\.0\.0\.1:6080 127\.0\.0\.1:5900/0.0.0.0:6080 127.0.0.1:5900/' /etc/systemd/system/novnc.service
fi

echo "Reloading systemd and enabling services..."
systemctl daemon-reload

systemctl enable --now weston
systemctl enable --now wayvnc
systemctl enable --now novnc

# waydroid-container.service est créé/activé par le paquet 'waydroid' lui-même
# lors de 01-install-waydroid.sh ; on s'assure qu'il est bien démarré.
systemctl enable --now waydroid-container.service

# waydroid-session.service n'est pas démarré ici : la première initialisation
# d'Android peut prendre plusieurs minutes et il vaut mieux la déclencher
# explicitement une fois le reste vérifié (voir docs/DEBUGGING_AND_TESTS.md).
systemctl enable waydroid-session.service

echo "Services installés."
if [[ "${EXPOSE_LAN}" == "yes" ]]; then
  echo "noVNC accessible sur http://<LXC_IP>:6080/vnc.html (SANS mot de passe)"
else
  echo "noVNC accessible en local uniquement. Depuis votre poste:"
  echo "  ssh -L 6080:127.0.0.1:6080 root@<LXC_IP>"
  echo "  puis ouvrez http://127.0.0.1:6080/vnc.html"
fi
echo "Démarrez Waydroid avec: systemctl start waydroid-session"
