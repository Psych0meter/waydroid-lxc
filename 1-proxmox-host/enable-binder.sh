#!/usr/bin/env bash
# Runs ON THE PROXMOX HOST (not inside the LXC).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: this script must be run as root." >&2
  exit 1
fi

echo "Loading kernel modules on Proxmox host..."

if ! modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/tmp/binder-modprobe.err; then
  echo "Error: could not load binder_linux." >&2
  cat /tmp/binder-modprobe.err >&2
  echo "Your kernel ($(uname -r)) may not ship this module - check 'modinfo binder_linux'." >&2
  exit 1
fi
modprobe loop
modprobe fuse   # required for Android's FUSE-based "emulated" storage

# Loading the module doesn't guarantee /dev/loopN exists (some kernels
# create it on demand via /dev/loop-control). Waydroid needs these nodes to
# loop-mount its images; create them here so they can be bind-mounted into
# the LXC (see lxc-config-append.txt).
for i in $(seq 0 7); do
  [[ -e "/dev/loop${i}" ]] || mknod -m 0660 "/dev/loop${i}" b 7 "${i}"
done
[[ -e /dev/loop-control ]] || mknod -m 0660 /dev/loop-control c 10 237   # 237 = LOOP_CTRL_MINOR, a fixed kernel constant
chown root:disk /dev/loop* 2>/dev/null || true

echo "Ensuring modules load on boot..."
echo 'binder_linux devices="binder,hwbinder,vndbinder"' > /etc/modules-load.d/waydroid-binder.conf
echo 'loop' > /etc/modules-load.d/waydroid-loop.conf
echo 'fuse' > /etc/modules-load.d/waydroid-fuse.conf

echo "Host configuration complete."
