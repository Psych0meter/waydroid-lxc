#!/usr/bin/env bash
# Runs ON THE PROXMOX HOST (not inside the LXC).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en root." >&2
  exit 1
fi

echo "Loading kernel modules on Proxmox host..."

if ! modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/tmp/binder-modprobe.err; then
  echo "Erreur: impossible de charger binder_linux." >&2
  cat /tmp/binder-modprobe.err >&2
  echo "" >&2
  echo "Le noyau Proxmox actuel (uname -r: $(uname -r)) ne fournit peut-être pas" >&2
  echo "ce module (binder n'est pas toujours inclus dans le noyau pve-kernel)." >&2
  echo "Vérifiez 'modinfo binder_linux' ou installez un noyau qui l'embarque." >&2
  exit 1
fi
modprobe loop

echo "Ensuring modules load on boot..."
echo 'binder_linux devices="binder,hwbinder,vndbinder"' > /etc/modules-load.d/waydroid-binder.conf
echo 'loop' > /etc/modules-load.d/waydroid-loop.conf

echo "Host configuration complete."
