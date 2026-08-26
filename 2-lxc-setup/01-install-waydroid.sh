#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en root dans le conteneur." >&2
  exit 1
fi

if [[ ! -e /dev/binder ]]; then
  echo "Erreur: /dev/binder est absent." >&2
  echo "Vérifiez que 1-proxmox-host/enable-binder.sh a été exécuté sur l'hôte" >&2
  echo "et que 1-proxmox-host/lxc-config-append.txt a été ajouté au .conf du CT" >&2
  echo "(puis que le conteneur a été redémarré)." >&2
  exit 1
fi

echo "Updating system..."
apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "Installing prerequisites..."
# NOTE: 'sway' (compositeur wlroots), pas 'weston' — wayvnc dépend de
# protocoles wlroots (virtual-pointer, xdg-output v3+) que Weston n'implémente
# pas. Voir docs/DEBUGGING_AND_TESTS.md pour le détail de cette incompatibilité.
apt-get install -y curl ca-certificates iptables dnsmasq sway wayvnc novnc websockify python3 git wget kmod nano procps lsb-release dbus dbus-daemon dbus-bin

# Le paquet dnsmasq s'auto-active comme service système au moment de son
# installation (comportement par défaut Debian) et écoute en --local-service
# sur toutes les interfaces locales. Il entre alors en conflit de port avec
# l'instance ad-hoc que /usr/lib/waydroid/data/scripts/waydroid-net.sh essaie
# de lancer sur le bridge waydroid0 (192.168.240.1:53), faisant échouer
# 'waydroid session start' avec "Address already in use". Waydroid gère son
# propre dnsmasq à la demande : le service système n'est pas nécessaire.
if systemctl is-enabled --quiet dnsmasq 2>/dev/null || systemctl is-active --quiet dnsmasq 2>/dev/null; then
  echo "Désactivation du service dnsmasq système (conflit avec le dnsmasq ad-hoc de waydroid-net.sh)..."
  systemctl disable --now dnsmasq
fi

echo "Installing Waydroid..."
if ! command -v waydroid >/dev/null 2>&1; then
  curl -s https://repo.waydro.id | bash
  apt-get install -y waydroid
else
  echo "Waydroid déjà installé, on passe."
fi

echo "Initializing Waydroid with GAPPS and software rendering..."
if [[ -d /var/lib/waydroid/images ]]; then
  echo "Waydroid déjà initialisé (/var/lib/waydroid/images existe), on ne relance pas 'waydroid init'."
else
  waydroid init -s GAPPS
fi

echo "Configuring properties for software rendering (since there is no GPU)..."
waydroid prop set ro.hardware.gralloc default
waydroid prop set ro.hardware.egl swiftshader

echo "Installation complete! Next, run the services script."
