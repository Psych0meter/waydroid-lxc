# Proxmox LXC Waydroid Deployment

This repository contains the full Infrastructure-as-Code scripts to deploy a headless Waydroid Android environment inside a Debian 13 LXC container on Proxmox. It features full remote access via browser (noVNC), device spoofing, and GPS injection.

## Project Structure
* `1-proxmox-host/` - Scripts and configurations applied to the Proxmox bare-metal host.
* `2-lxc-setup/` - Core installation scripts for Waydroid and dependencies inside the container.
* `3-services/` - Systemd service files to maintain Weston, WayVNC, and noVNC continuously.
* `4-waydroid-tools/` - Device spoofing, GPS manipulation scripts, and startup wrappers.
* `docs/` - Detailed debugging and testing methodology.

## Deployment Order:
1. Run `1-proxmox-host/enable-binder.sh` on your **Proxmox Node**.
2. Create a **Privileged** Debian 13 LXC in the Proxmox UI.
3. Append the contents of `1-proxmox-host/lxc-config-append.txt` to `/etc/pve/lxc/<VMID>.conf`.
4. Restart the LXC container.
5. Enter the LXC console and execute `2-lxc-setup/01-install-waydroid.sh`.
6. Execute `3-services/02-install-services.sh`.
7. Access the Android interface from your phone/browser at `http://<LXC_IP>:6080/vnc.html`.
8. Execute `4-waydroid-tools/03-setup-tools.sh` to download the spoofing and GPS Python/Bash scripts.

See `docs/DEBUGGING_AND_TESTS.md` for full troubleshooting procedures.
