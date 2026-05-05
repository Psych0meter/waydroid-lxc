#!/usr/bin/env bash
set -e
echo "Loading kernel modules on Proxmox host..."
modprobe binder_linux devices="binder,hwbinder,vndbinder"
modprobe loop

echo "Ensuring modules load on boot..."
echo 'binder_linux devices="binder,hwbinder,vndbinder"' > /etc/modules-load.d/waydroid-binder.conf
echo 'loop' > /etc/modules-load.d/waydroid-loop.conf

echo "Host configuration complete."
