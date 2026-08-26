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

echo "Installing Sway headless config..."
mkdir -p /etc/sway
cp "${REPO_ROOT}/2-lxc-setup/sway-headless-config" /etc/sway/config-headless

echo "Installing helper scripts..."
install -m 0755 "${SCRIPT_DIR}/wait-for-wayland-socket.sh" /usr/local/bin/wait-for-wayland-socket.sh
install -m 0755 "${SCRIPT_DIR}/ensure-waydroid-dbus.sh" /usr/local/bin/ensure-waydroid-dbus.sh
install -m 0755 "${SCRIPT_DIR}/mount-emulated-storage.sh" /usr/local/bin/mount-emulated-storage.sh

# wayvnc essaie TOUJOURS de charger un fichier de config, même sans -C, et
# plante ("Failed to load config. Success") si aucun n'existe — bug connu
# (https://github.com/any1/wayvnc/issues/10). On lui en fournit un vide,
# référencé explicitement via -C dans wayvnc.service pour ne pas dépendre
# de $HOME (non défini par systemd pour un service root sans User=).
mkdir -p /etc/wayvnc
touch /etc/wayvnc/config

echo "Installing systemd services..."
cp "${SCRIPT_DIR}/sway.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/wayvnc.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/novnc.service" /etc/systemd/system/
cp "${SCRIPT_DIR}/waydroid-session.service" /etc/systemd/system/

if [[ "${EXPOSE_LAN}" == "yes" ]]; then
  echo "!!! EXPOSE_LAN=yes : noVNC va écouter sur 0.0.0.0 SANS AUTHENTIFICATION."
  # Seul websockify (noVNC) a besoin d'écouter sur le LAN : il se connecte à
  # wayvnc en interne via 127.0.0.1, qui lui reste toujours en local — pas
  # besoin d'exposer le protocole VNC brut (port 5900) en plus du web (6080).
  sed -i 's/127\.0\.0\.1:6080 127\.0\.0\.1:5900/0.0.0.0:6080 127.0.0.1:5900/' /etc/systemd/system/novnc.service
fi

echo "Reloading systemd and enabling services..."
systemctl daemon-reload

systemctl enable --now sway
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
