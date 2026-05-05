# Debugging and Testing Steps

Follow these steps sequentially if you encounter issues during deployment or operation.

## Phase 1: Verify Host Configuration (Proxmox Node)
**Test:** Are the required kernel modules loaded?
* Run: `lsmod | grep binder`
* **Expected output:** You should see `binder_linux` listed.
* Run inside the LXC: `ls -l /dev/binder`
* **Expected output:** A character device with major/minor `10 236`. If missing, check your `lxc.hook.autodev` config in `/etc/pve/lxc/<vmid>.conf`.

## Phase 2: Verify Compositor & Display (Weston & VNC)
**Test:** Is the headless display server running?
* Run inside LXC: `systemctl status weston`
* **Expected output:** `active (running)`.
* **Debug:** If it failed, check logs with `journalctl -u weston -e`. Verify `/run/user/0` is created and has correct permissions.
**Test:** Is the web interface exposed?
* Run inside LXC: `systemctl status novnc`
* **Debug:** If the browser interface at port `6080` doesn't load, ensure your Proxmox Datacenter firewall allows incoming connections on port `6080`.

## Phase 3: Verify Waydroid Session
**Test:** Is Android booting?
* Run inside LXC: `./4-waydroid-tools/start-waydroid.sh`
* Run inside LXC: `waydroid status`
* **Expected output:** `Session: RUNNING`.
* **Debug:** If it says `STOPPED`, Weston might have crashed. Check logs via `waydroid log`. Software rendering heavily taxes the CPU; ensure the LXC is allocated at least 4 vCPUs.

## Phase 4: Test Device Spoofing
1. Stop Waydroid: `waydroid session stop`
2. Navigate to `4-waydroid-tools/` and run `./spoof-device.sh`
3. Select your desired profile from the menu.
4. Restart Waydroid: `./start-waydroid.sh`
5. Open the Android settings app inside your web UI and navigate to "About Phone" to verify the new identity.

## Phase 5: Test Fake GPS Injection
1. Inside the Android web UI, open an app that requires location (like a map app or browser).
2. From the LXC terminal, navigate to `4-waydroid-tools/`.
3. Run the wrapper script with coordinates: `./change-location.sh 48.8584 2.2945` (Coordinates for the Eiffel Tower).
4. Verify the location pin updates in real-time in the Android UI.
