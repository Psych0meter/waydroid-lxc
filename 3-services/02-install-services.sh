#!/usr/bin/env bash
set -e

echo "Copying weston.ini..."
mkdir -p /etc/xdg/weston
cp ../2-lxc-setup/weston.ini /etc/xdg/weston/weston.ini

echo "Installing systemd services..."
cp weston.service /etc/systemd/system/
cp wayvnc.service /etc/systemd/system/
cp novnc.service /etc/systemd/system/

echo "Reloading systemd and enabling services..."
systemctl daemon-reload

systemctl enable --now weston
sleep 2  # Give Weston a moment to create the Wayland socket
systemctl enable --now wayvnc
systemctl enable --now novnc

echo "Services installed and running! You can now access noVNC at http://<LXC_IP>:6080/vnc.html"
