#!/usr/bin/env bash
# Runs ON THE PROXMOX HOST (not inside the LXC).
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

echo "Loading kernel modules on Proxmox host..."

if ! modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/tmp/binder-modprobe.err; then
  echo "Error: could not load binder_linux." >&2
  cat /tmp/binder-modprobe.err >&2
  echo "" >&2
  echo "Your current Proxmox kernel (uname -r: $(uname -r)) may not ship" >&2
  echo "this module (binder isn't always included in the pve-kernel package)." >&2
  echo "Check 'modinfo binder_linux' or install a kernel that includes it." >&2
  exit 1
fi
modprobe loop
# Required for Android's "emulated" storage (MediaProvider/FUSE): without
# /dev/fuse, the Storage app and internal storage can misbehave (e.g. false
# "Not enough storage space" messages).
modprobe fuse

# Loading the module doesn't guarantee the /dev/loopN device nodes exist
# (some kernels only create them on demand via /dev/loop-control). Waydroid
# needs them to loop-mount its images (system.img, vendor.img) inside the
# container - create them explicitly here so they can be bind-mounted into
# the LXC (see lxc-config-append.txt).
echo "Ensuring /dev/loopN device nodes exist..."
for i in $(seq 0 7); do
  [[ -e "/dev/loop${i}" ]] || mknod -m 0660 "/dev/loop${i}" b 7 "${i}"
done
# 237 = LOOP_CTRL_MINOR, a fixed Linux kernel constant (include/linux/loop.h),
# not a dynamic allocation - safe to hardcode.
[[ -e /dev/loop-control ]] || mknod -m 0660 /dev/loop-control c 10 237
chown root:disk /dev/loop* 2>/dev/null || true

echo "Ensuring modules load on boot..."
echo 'binder_linux devices="binder,hwbinder,vndbinder"' > /etc/modules-load.d/waydroid-binder.conf
echo 'loop' > /etc/modules-load.d/waydroid-loop.conf
echo 'fuse' > /etc/modules-load.d/waydroid-fuse.conf

echo "Host configuration complete."
