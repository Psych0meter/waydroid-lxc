# Debugging and Testing Steps

Deux outils automatisés sont disponibles avant de suivre les étapes
manuelles ci-dessous :

* `tests/lint.sh` — statique, à lancer n'importe où (poste de dev, CI) :
  `bash -n` sur tous les scripts, `shellcheck`, vérification des fichiers
  référencés entre les scripts. Ne nécessite pas Proxmox.
* `tests/smoke-test.sh` — dynamique, à lancer **dans le conteneur** après
  déploiement (`pct exec <CTID> -- bash /opt/waydroid-lxc-deploy/tests/smoke-test.sh`
  si déployé via `0-deploy-all.sh`, ou directement `./tests/smoke-test.sh`
  depuis le conteneur) : vérifie `/dev/binder`, les binaires installés, les
  services systemd, le socket Wayland, les ports en écoute et l'état de la
  session Waydroid.

Si `smoke-test.sh` échoue quelque part, suivez la phase correspondante
ci-dessous pour creuser.

## Phase 1: Verify Host Configuration (Proxmox Node)
**Test:** Are the required kernel modules loaded?
* Run: `lsmod | grep binder`
* **Expected output:** You should see `binder_linux` listed.
* Si `1-proxmox-host/enable-binder.sh` échoue avec "impossible de charger
  binder_linux", votre noyau Proxmox actuel n'embarque probablement pas ce
  module — vérifiez `modinfo binder_linux`.
* Run inside the LXC: `ls -l /dev/binder`
* **Expected output:** A character device with major/minor `10 236`. If
  missing, check your `lxc.hook.autodev` config in `/etc/pve/lxc/<vmid>.conf`
  (voir `1-proxmox-host/lxc-config-append.txt`), et vérifiez que le
  conteneur est bien **privilégié** (`unprivileged: 0` dans le `.conf`).

## Phase 2: Verify Compositor & Display (Weston & VNC)
**Test:** Is the headless display server running?
* Run inside LXC: `systemctl status weston`
* **Expected output:** `active (running)`.
* **Debug:** If it failed, check logs with `journalctl -u weston -e`. Verify
  `/run/user/0` is created and has correct permissions.

**Test:** Is wayvnc up and listening?
* Run inside LXC: `systemctl status wayvnc`
* Si `wayvnc.service` échoue immédiatement après `weston.service`, vérifiez
  `journalctl -u wayvnc -e` : le `ExecStartPre` (`wait-for-wayland-socket.sh`)
  échoue si le socket Wayland n'apparaît jamais — dans ce cas le problème
  vient de Weston (voir ci-dessus), pas de wayvnc.

**Test:** Is the web interface exposed?
* Run inside LXC: `systemctl status novnc`
* Par défaut, noVNC/wayvnc n'écoutent que sur `127.0.0.1` — voir la section
  "Accès à l'interface" du README pour le tunnel SSH. Si vous avez déployé
  avec `--expose-lan`/`EXPOSE_LAN=yes` et que le navigateur ne charge pas
  `http://<LXC_IP>:6080/vnc.html`, vérifiez que le firewall Datacenter
  Proxmox autorise le port `6080` entrant.

## Phase 3: Verify Waydroid Session
**Test:** Is waydroid-container.service (fourni par le paquet waydroid) actif ?
* Run inside LXC: `systemctl status waydroid-container`
* C'est un pré-requis de `waydroid-session.service` (celui de ce dépôt) :
  sans lui, la session ne peut pas démarrer.

**Test:** Is Android booting?
* Run inside LXC: `systemctl start waydroid-session` (si pas déjà démarré
  automatiquement au boot), puis `waydroid status`.
* **Expected output:** `Session: RUNNING`.
* **Debug:** If it says `STOPPED`, Weston might have crashed, ou
  `waydroid-container.service` n'était pas prêt. Check logs via
  `waydroid log` et `journalctl -u waydroid-session -e`. Software rendering
  heavily taxes the CPU; ensure the LXC is allocated at least 4 vCPUs.
* Alternative manuelle (sans systemd) : `4-waydroid-tools/start-waydroid.sh`.

## Phase 4: Test Device Spoofing
1. Stop Waydroid: `systemctl stop waydroid-session` (ou `waydroid session stop`)
2. Navigate to `4-waydroid-tools/` and run `./spoof-device.sh`
3. Select your desired profile from the menu.
4. Restart Waydroid: `systemctl start waydroid-session`
5. Open the Android settings app inside your web UI and navigate to "About
   Phone" to verify the new identity.

## Phase 5: Test Fake GPS Injection
1. Inside the Android web UI, open an app that requires location (like a
   map app or browser).
2. From the LXC terminal, navigate to `4-waydroid-tools/`.
3. Run the wrapper script with coordinates:
   `./change-location.sh 48.8584 2.2945` (Coordinates for the Eiffel Tower).
4. Verify the location pin updates in real-time in the Android UI.

## Phase 6: Redéploiement / réexécution

Tous les scripts d'installation (`01-install-waydroid.sh`,
`02-install-services.sh`, `03-setup-tools.sh`) sont conçus pour être
ré-exécutés sans casser un déploiement existant (vérifications d'idempotence
sur `waydroid init`, écrasement propre des unités systemd). `0-deploy-all.sh`
peut être relancé avec `--ctid <ID existant>` pour reprendre un déploiement
interrompu après la création du conteneur (il ne recrée pas le conteneur si
la configuration binder est déjà présente dans le `.conf`).
