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
# Nécessaire pour le stockage "emulated" d'Android (MediaProvider/FUSE) :
# sans /dev/fuse, l'app Storage et le stockage interne d'Android peuvent
# mal se comporter (ex: faux messages "Not enough storage space").
modprobe fuse

# Le module chargé ne garantit pas que les device nodes /dev/loopN existent
# (certains noyaux ne les créent qu'à la demande via /dev/loop-control).
# Waydroid en a besoin pour monter ses images (system.img, vendor.img) en
# loop device dans le conteneur — on les crée explicitement ici, sur l'hôte,
# pour pouvoir ensuite les bind-mounter dans le LXC (voir lxc-config-append.txt).
echo "Ensuring /dev/loopN device nodes exist..."
for i in $(seq 0 7); do
  [[ -e "/dev/loop${i}" ]] || mknod -m 0660 "/dev/loop${i}" b 7 "${i}"
done
# 237 = LOOP_CTRL_MINOR, constante fixe du noyau Linux (include/linux/loop.h),
# pas une allocation dynamique — sûr à coder en dur.
[[ -e /dev/loop-control ]] || mknod -m 0660 /dev/loop-control c 10 237
chown root:disk /dev/loop* 2>/dev/null || true

echo "Ensuring modules load on boot..."
echo 'binder_linux devices="binder,hwbinder,vndbinder"' > /etc/modules-load.d/waydroid-binder.conf
echo 'loop' > /etc/modules-load.d/waydroid-loop.conf
echo 'fuse' > /etc/modules-load.d/waydroid-fuse.conf

echo "Host configuration complete."
