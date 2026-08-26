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

## Phase 2: Verify Compositor & Display (Sway & VNC)
**Test:** Is the headless compositor running?
* Run inside LXC: `systemctl status sway`
* **Expected output:** `active (running)`.
* **Debug:** If it failed, check logs with `journalctl -u sway -e`. Verify
  `/run/user/0` is created and has correct permissions. Un warning
  `libseat: Backend 'seatd' failed to open seat, skipping` est normal et sans
  conséquence en mode headless (`WLR_BACKENDS=headless` +
  `WLR_LIBINPUT_NO_DEVICES=1` : aucun accès DRM/input physique n'est requis).
  Si malgré tout Sway refuse de démarrer pour une raison de seat, installez
  `apt-get install -y seatd && systemctl enable --now seatd`.
* **Warnings sans conséquence** (service reste `active (running)`, à ignorer) :
  - `Failed to find any DRM render node` — pas de GPU dans le LXC, le backend
    headless retombe sur du rendu logiciel (pixman) ; cohérent avec le
    software rendering déjà utilisé par Waydroid (`swiftshader`).
  - `swaybg: Could not find config for output HEADLESS-1` — le fond d'écran
    par défaut ne trouve pas de config par-sortie spécifique et utilise ses
    valeurs par défaut.
  - `swaybar/tray: Failed to connect to user bus` — pas de D-Bus dans ce
    conteneur minimal, la tray système-icons de la barre est simplement
    indisponible (`bar { mode invisible }` la masque de toute façon).

**Test:** Is wayvnc up and listening?
* Run inside LXC: `systemctl status wayvnc`
* Si `wayvnc.service` échoue immédiatement après `sway.service`, vérifiez
  `journalctl -u wayvnc -e` : le `ExecStartPre` (`wait-for-wayland-socket.sh`)
  échoue si le socket Wayland n'apparaît jamais — dans ce cas le problème
  vient de Sway (voir ci-dessus), pas de wayvnc.
* **Erreur connue #1** `ERROR: ../src/main.c: 2034: Failed to load config. Success`
  en boucle de redémarrage : `wayvnc` essaie toujours de charger un fichier
  de config, même sans `-C`, et plante s'il n'existe pas
  ([any1/wayvnc#10](https://github.com/any1/wayvnc/issues/10)) — d'autant
  plus probable ici que `$HOME` n'est pas défini pour un service systemd
  lancé sans `User=`. Ce dépôt crée `/etc/wayvnc/config` (vide) lors de
  `02-install-services.sh`, le référence via `-C` dans `wayvnc.service`, et
  fixe `Environment=HOME=/root` en complément. Si vous voyez cette erreur
  malgré tout :
  `mkdir -p /etc/wayvnc && touch /etc/wayvnc/config && systemctl restart wayvnc`.
* **Erreur connue #2** `invalid version for global zxdg_output_manager_v1` /
  `Virtual Pointer protocol not supported by compositor` /
  `Failed to initialise wayland` : signifie que le compositeur en face n'est
  **pas** basé sur wlroots (typiquement si `weston` tourne à la place de
  `sway` — voir "Choix d'architecture" dans le README). `wayvnc` ne
  fonctionnera jamais avec Weston, quelle que soit la configuration. Vérifiez
  `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` cohérents entre `sway.service` et
  `wayvnc.service`, et que c'est bien `sway.service` (pas un reliquat
  `weston.service`) qui est actif : `systemctl list-units '*.service' | grep -Ei 'sway|weston'`.

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

**Erreur connue** `RuntimeError: Command failed: % .../waydroid-net.sh start`
avec, en creusant (`waydroid --details-to-stdout session start` ou
`bash -x /usr/lib/waydroid/data/scripts/waydroid-net.sh start`),
`dnsmasq: failed to create listening socket for 192.168.240.1: Address
already in use` : le paquet `dnsmasq` s'auto-active comme **service système**
à l'installation (`systemctl status dnsmasq`) et écoute déjà en
`--local-service` sur toutes les interfaces locales, entrant en conflit avec
l'instance ad-hoc que Waydroid lance lui-même sur le bridge `waydroid0`.
`01-install-waydroid.sh` désactive ce service dans ce dépôt, mais si vous
avez déployé avant ce correctif (ou installé `dnsmasq` autrement) :
```bash
systemctl disable --now dnsmasq
waydroid session start
```
Si le bridge `waydroid0` est resté dans un état incohérent après un essai
raté (visible via `ip link show waydroid0`), nettoyez avant de relancer :
```bash
pkill -f 'dnsmasq.*waydroid0' 2>/dev/null
ip link delete waydroid0 2>/dev/null
rm -f /run/waydroid-lxc/dnsmasq.pid /run/waydroid-lxc/network_up
```

**Erreur connue** `org.freedesktop.DBus.Error.NotSupported: Unable to
autolaunch a dbus-daemon without a $DISPLAY for X11` : Waydroid a besoin
d'un bus D-Bus de session, absent par défaut dans un service systemd sans
session de login. `waydroid-session.service` de ce dépôt en démarre un dédié
(adresse fixe `unix:path=/run/waydroid-dbus/session`) avant `waydroid
session start` — voir la définition du service pour le détail si vous
constatez malgré tout cette erreur.

**Erreur connue** `RuntimeError: Command failed: % mount -o ro
/var/lib/waydroid/images/system.img /var/lib/waydroid/rootfs` : le montage
en loop device des images Android échoue si `/dev/loop*` et
`/dev/loop-control` n'existent pas dans le conteneur. Le module `loop`
chargé sur l'hôte (`enable-binder.sh`) ne garantit pas que ces device nodes
existent physiquement — ce dépôt les crée désormais explicitement sur
l'hôte et les bind-monte dans le LXC via `lxc-config-append.txt`. Si vous
avez déployé avant ce correctif :
```bash
# Sur l'hôte Proxmox
for i in $(seq 0 7); do [ -e /dev/loop$i ] || mknod -m 0660 /dev/loop$i b 7 $i; done
[ -e /dev/loop-control ] || mknod -m 0660 /dev/loop-control c 10 237
# puis ajoutez les lignes lxc.mount.entry (voir 1-proxmox-host/lxc-config-append.txt)
# à /etc/pve/lxc/<CTID>.conf, et redémarrez le conteneur (pct stop/start).
```
Vérifiez ensuite dans le conteneur : `ls -l /dev/loop*` doit lister
`loop-control` et `loop0`…`loop7`.

**Erreur connue** le socket `/run/user/0/wayland-1` (ou tout autre nom de
socket) n'apparaît jamais, alors que `sway.service` est `active (running)`
sans erreur fatale dans ses logs, et que `wayvnc`/`waydroid-session`
timeoutent en boucle sur `wait-for-wayland-socket.sh` : `/run/user/0` est
géré par **systemd-logind** (`user-runtime-dir@0.service`), qui le
**remonte en tmpfs tout neuf** à chaque (dé/re)connexion de session pour
root (typiquement une session SSH), effaçant tout ce qu'un service système
y aurait créé entre-temps — y compris le socket Wayland de Sway. Vérifiable
via `mount | grep /run/user/0` et `systemctl status
user-runtime-dir@0.service`. C'est pour cette raison que ce dépôt fait
tourner toute la pile (Sway, wayvnc, waydroid-session) sur un répertoire
runtime **dédié**, `/run/waydroid-wayland`, jamais recyclé par logind — et
non `/run/user/0`. Si vous avez déployé avant ce correctif, ou avez copié
manuellement d'anciennes unités, remplacez toute occurrence de
`/run/user/0` par `/run/waydroid-wayland` dans `sway.service`,
`wayvnc.service` et `waydroid-session.service`, puis :
```bash
mkdir -p /run/waydroid-wayland && chmod 0700 /run/waydroid-wayland
systemctl daemon-reload
systemctl restart sway wayvnc waydroid-session
```

**Erreur connue** `gbinder ERROR: Can't get binder version from /dev/binder:
Inappropriate ioctl for device` (répétée en boucle), avec dans
`/var/lib/waydroid/waydroid.log` un `ln: failed to create symbolic link
'/dev/binder': File exists` juste avant : Waydroid crée son propre
`/dev/binder` via **binderfs** (`mount -t binder binder /dev/binderfs`
suivi d'un lien symbolique) à chaque démarrage de session — un
`/dev/binder` statique pré-créé par ailleurs (mknod) entre en conflit avec
ce mécanisme et laisse Waydroid utiliser un device incohérent. Ce dépôt ne
crée donc **plus** `/dev/binder` lui-même (voir
`1-proxmox-host/lxc-config-append.txt`) : le module `binder_linux` chargé
sur l'hôte suffit à rendre le filesystem `binder` disponible, Waydroid fait
le reste. Si vous avez ajouté un tel hook manuellement, retirez-le et
redémarrez le conteneur (`pct stop`/`pct start`, pas juste un `systemctl
restart` — le hook ne s'exécute qu'au (re)démarrage du conteneur).

**Erreur connue** `Not enough storage space` affiché dans Android (parfois
avec l'app "Storage" des paramètres qui plante à l'ouverture) : vérifiez
d'abord `/dev/fuse` dans le conteneur (`ls -l /dev/fuse`). Sans lui, le
stockage "emulated" d'Android (basé sur FUSE depuis Android 10+) ne
s'initialise pas correctement. Ce dépôt charge le module `fuse` sur l'hôte
(`enable-binder.sh`) et active la feature Proxmox `fuse=1` sur le
conteneur (`0-deploy-all.sh` / `pct set -features ...,fuse=1`). Si le
message persiste malgré `/dev/fuse` présent et que `/data` a réellement de
la place (`waydroid shell -- dumpsys diskstats`), voir l'entrée dédiée
juste en dessous — c'est le cas le plus fréquent en pratique.

**Confirmé (vraie cause racine)** : `vold` marque le volume de stockage
interne (`emulated;0`) `UNMOUNTABLE` au démarrage et ne retente **jamais**
de lui-même, même une fois `/dev/fuse` présent — vérifiable via
`waydroid shell -- dumpsys mount` (cherchez `state=`). C'est pour ça que
`waydroid shell -- dumpsys diskstats` peut afficher 60% d'espace libre
pendant que le Play Store affiche "Not enough storage space" : Android n'a
tout simplement aucun volume de stockage monté à présenter aux
applications. Un appel explicite à `sm mount 'emulated;0'` (l'outil
`sm`, moderne et basé sur Binder — pas `vdc`, dont les commandes texte
brutes ne sont plus supportées sur les versions récentes d'Android) suffit
à le faire passer à `MOUNTED`. Ce dépôt automatise cet appel via
`3-services/mount-emulated-storage.sh`, lancé en tâche de fond par
`waydroid-session.service` avec sa propre boucle de nouvelles tentatives
(le service Android met un peu de temps à être prêt à répondre à
`waydroid shell`). Si le message persiste malgré tout :
```bash
waydroid shell -- sm list-volumes all
waydroid shell -- sm mount 'emulated;0'   # noter les quotes : ';' est un séparateur de commande shell
```
Un contournement plus étroit existe aussi pour un bug voisin, spécifique à
certains chemins de téléchargement du Play Store (erreurs "Can't create
file" dans le logcat plutôt que "Not enough storage space" d'emblée) :
`4-waydroid-tools/fix-storage-scaffold.sh` — voir
[waydroid/waydroid#530](https://github.com/waydroid/waydroid/issues/530).

**Test:** Is Android booting?
* Run inside LXC: `systemctl start waydroid-session` (si pas déjà démarré
  automatiquement au boot), puis `waydroid status`.
* **Expected output:** `Session: RUNNING`.
* **Debug:** If it says `STOPPED`, Sway might have crashed, ou
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
