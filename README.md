# Proxmox LXC Waydroid Deployment

Infrastructure-as-Code pour déployer un environnement Android headless
(Waydroid) dans un conteneur LXC Debian 13 sur Proxmox, avec accès distant
via navigateur (noVNC), spoofing d'identité d'appareil, et injection GPS.

## Déploiement en une commande (recommandé)

Sur l'hôte Proxmox, en root :

```bash
./0-deploy-all.sh --hostname waydroid --cpu 4 --ram 4096 --disk 16
```

Ce script :
1. Charge les modules noyau `binder`/`loop` sur l'hôte.
2. Crée le conteneur Debian 13 **privilégié** via le script communautaire
   [community-scripts/ProxmoxVE](https://community-scripts.org/scripts/debian).
3. Injecte la configuration binder/apparmor/cgroup dans `/etc/pve/lxc/<CTID>.conf`
   et redémarre le conteneur.
4. Copie ce dépôt dans le conteneur et exécute dans l'ordre l'installation
   de Waydroid, des services systemd, puis des outils de spoofing/GPS.
5. Active `waydroid-session.service` (démarrage automatique au boot).

Par défaut, **noVNC n'est accessible que via tunnel SSH** (voir "Sécurité"
ci-dessous). Pour l'exposer directement sur le LAN (sans mot de passe) :

```bash
./0-deploy-all.sh --expose-lan
```

`community-scripts/ProxmoxVE` est un projet tiers indépendant de ce dépôt ;
`0-deploy-all.sh` télécharge et exécute son script `ct/debian.sh` à chaque
lancement. Si vous préférez ne pas exécuter de code tiers automatiquement,
créez le conteneur manuellement (voir "Déploiement manuel" plus bas) puis
reprenez à partir de l'étape 3 avec `--ctid <ID>`.

## Déploiement manuel (étape par étape)

1. `1-proxmox-host/enable-binder.sh` sur l'hôte Proxmox.
2. Créer un LXC **privilégié** Debian 13 depuis l'UI Proxmox (ou via
   `community-scripts/ProxmoxVE`).
3. Ajouter le contenu de `1-proxmox-host/lxc-config-append.txt` (hors
   commentaires) à `/etc/pve/lxc/<VMID>.conf`, puis redémarrer le conteneur.
4. Dans le conteneur : `2-lxc-setup/01-install-waydroid.sh`
5. Puis : `EXPOSE_LAN=no 3-services/02-install-services.sh`
6. Puis : `4-waydroid-tools/03-setup-tools.sh`
7. `systemctl start waydroid-session`
8. Accès : voir le message affiché en fin d'installation, ou section
   "Accès à l'interface" ci-dessous.

## Accès à l'interface

Par défaut (sans `--expose-lan` / `EXPOSE_LAN=yes`), wayvnc et noVNC
n'écoutent que sur `127.0.0.1` **dans le conteneur**. Depuis votre poste :

```bash
ssh -L 6080:127.0.0.1:6080 root@<LXC_IP>
```

puis ouvrez `http://127.0.0.1:6080/vnc.html`.

## Structure du projet

* `0-deploy-all.sh` — Orchestrateur complet (hôte → conteneur → services).
* `1-proxmox-host/` — Scripts/config appliqués sur l'hôte Proxmox.
* `2-lxc-setup/` — Installation de Waydroid et dépendances dans le conteneur.
* `3-services/` — Unités systemd (Weston, WayVNC, noVNC, session Waydroid).
* `4-waydroid-tools/` — Spoofing d'appareil, GPS, wrapper de démarrage manuel.
* `tests/` — `lint.sh` (statique, sans Proxmox) et `smoke-test.sh` (à
  exécuter dans le conteneur après déploiement).
* `docs/` — Méthodologie de debug détaillée.

## Sécurité

Ce projet fait des compromis de sécurité **volontaires et documentés**,
nécessaires pour faire fonctionner Waydroid (accès au device binder) dans
un LXC sans recompiler de module noyau :

* **Conteneur privilégié + `apparmor unconfined` + `cgroup2.devices.allow: a`
  + `cap.drop` vide** (`1-proxmox-host/lxc-config-append.txt`) : le
  conteneur dispose d'un accès matériel et de capacités bien plus large
  qu'un LXC standard, ce qui réduit l'isolation vis-à-vis de l'hôte Proxmox.
  Ne déployez ce conteneur que sur un hôte/LAN de confiance.
* **noVNC/wayvnc sans authentification par défaut** : par choix de
  conception, ce dépôt les fait écouter sur `127.0.0.1` uniquement et
  recommande un tunnel SSH. Le flag `--expose-lan` / `EXPOSE_LAN=yes`
  lève cette restriction mais **n'ajoute aucune authentification** — à
  n'utiliser que sur un réseau local de confiance.
* **Outils tiers non signés** (`4-waydroid-tools/03-setup-tools.sh`) :
  `spoof-device.sh` et `fake_gps.py` sont téléchargés depuis des dépôts
  GitHub individuels (`main` par défaut). Définissez `SPOOF_REF`/`GPS_REF`
  pour figer un commit précis, et relisez leur contenu avant exécution si
  votre modèle de menace l'exige.
* **`curl | bash`** pour l'installeur officiel Waydroid
  (`repo.waydro.id`, dans `01-install-waydroid.sh`) : pratique standard de
  l'écosystème Waydroid, mais reste un risque de chaîne d'approvisionnement
  à connaître.

Voir `docs/DEBUGGING_AND_TESTS.md` pour la méthodologie de debug complète,
et `tests/` pour la validation automatisée.
