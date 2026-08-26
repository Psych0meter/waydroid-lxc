#!/usr/bin/env bash
#
# 0-deploy-all.sh — Orchestrateur "clé en main" à exécuter sur l'hôte Proxmox.
#
# Ce script :
#   1. Prépare l'hôte (modules binder/loop) via 1-proxmox-host/enable-binder.sh
#   2. Crée un LXC Debian 13 PRIVILÉGIÉ via le script communautaire
#      community-scripts/ProxmoxVE (https://community-scripts.org/scripts/debian)
#   3. Injecte la configuration binder/apparmor/cgroup dans /etc/pve/lxc/<CTID>.conf
#   4. Redémarre le conteneur
#   5. Copie le dépôt dans le conteneur et exécute dans l'ordre :
#        2-lxc-setup/01-install-waydroid.sh
#        3-services/02-install-services.sh
#        4-waydroid-tools/03-setup-tools.sh
#
# IMPORTANT — Le script communautaire ct/debian.sh est un outil interactif
# (whiptail). Ce wrapper force le mode "Default Settings" en pré-remplissant
# les variables d'environnement var_* qu'il sait lire (cf. code source de
# misc/build.func). Si une future version de community-scripts change ce
# comportement, un dialogue whiptail peut malgré tout s'afficher : lancez
# alors ce script depuis une vraie console interactive (pas un cron/CI).
#
# Usage:
#   ./0-deploy-all.sh [--ctid ID] [--hostname NAME] [--ip dhcp|A.B.C.D/CIDR]
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Pré-requis et arguments
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CT_HOSTNAME="waydroid"
CT_ID=""
CT_NET="dhcp"
CT_CPU=4
CT_RAM=4096
CT_DISK=16
EXPOSE_LAN="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2 ;;
    --hostname) CT_HOSTNAME="$2"; shift 2 ;;
    --ip) CT_NET="$2"; shift 2 ;;
    --cpu) CT_CPU="$2"; shift 2 ;;
    --ram) CT_RAM="$2"; shift 2 ;;
    --disk) CT_DISK="$2"; shift 2 ;;
    --expose-lan) EXPOSE_LAN="yes"; shift 1 ;;
    -h|--help)
      echo "Usage: $0 [--ctid ID] [--hostname NAME] [--ip dhcp|A.B.C.D/CIDR] [--cpu N] [--ram MiB] [--disk GB] [--expose-lan]"
      echo ""
      echo "  --expose-lan  Expose noVNC/wayvnc sur 0.0.0.0 SANS authentification (déconseillé)."
      echo "                Par défaut, l'accès se fait via tunnel SSH (voir README)."
      exit 0
      ;;
    *) echo "Option inconnue: $1" >&2; exit 1 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit être exécuté en root sur le nœud Proxmox." >&2
  exit 1
fi

if ! command -v pct >/dev/null 2>&1; then
  echo "Erreur: 'pct' introuvable. Ce script doit tourner sur un hôte Proxmox VE." >&2
  exit 1
fi

echo "==> [1/5] Préparation de l'hôte Proxmox (modules binder/loop)"
bash "${SCRIPT_DIR}/1-proxmox-host/enable-binder.sh"

# ---------------------------------------------------------------------------
# 1. Création du conteneur via community-scripts (Debian 13, PRIVILÉGIÉ)
# ---------------------------------------------------------------------------
echo "==> [2/5] Création du LXC Debian via community-scripts/ProxmoxVE"

export var_hostname="${CT_HOSTNAME}"
export var_unprivileged=0   # Requis: le binder device et l'accès matériel nécessitent un CT privilégié
export var_cpu="${CT_CPU}"
export var_ram="${CT_RAM}"
export var_disk="${CT_DISK}"
export var_net="${CT_NET}"
export var_os=debian
export var_version=13
export var_tags="waydroid"
export var_nesting=1
# Requis pour le stockage "emulated" d'Android (FUSE) : sans ça, l'app
# Storage et le stockage interne peuvent mal fonctionner.
export var_fuse=yes
export var_verbose=no
[[ -n "${CT_ID}" ]] && export var_ctid="${CT_ID}"

# NEXTID est déterminé par le script lui-même si var_ctid n'est pas fourni.
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/debian.sh)"

# Retrouver le CTID effectivement créé (le plus récent conteneur portant le tag "waydroid"
# et le hostname demandé, au cas où var_ctid n'était pas fourni).
if [[ -n "${CT_ID}" ]]; then
  FOUND_CTID="${CT_ID}"
else
  FOUND_CTID="$(pct list | awk -v hn="${CT_HOSTNAME}" '$0 ~ hn {print $1}' | tail -n1)"
fi

if [[ -z "${FOUND_CTID}" ]] || ! pct config "${FOUND_CTID}" >/dev/null 2>&1; then
  echo "Erreur: impossible de déterminer le CTID du conteneur créé." >&2
  echo "Vérifiez avec 'pct list' puis relancez avec --ctid <ID> pour reprendre le déploiement." >&2
  exit 1
fi
CTID="${FOUND_CTID}"
echo "    -> Conteneur créé: CTID=${CTID}"

# Filet de sécurité : s'assurer que fuse=1 est bien dans les features du CT,
# au cas où var_fuse n'aurait pas été correctement appliqué à la création
# (nécessaire pour le stockage "emulated" d'Android).
CURRENT_FEATURES="$(pct config "${CTID}" | awk -F': ' '/^features:/ {print $2}')"
if [[ "${CURRENT_FEATURES}" != *fuse=1* ]]; then
  echo "    -> Ajout de fuse=1 aux features du CT (absent après création)"
  NEW_FEATURES="${CURRENT_FEATURES:+${CURRENT_FEATURES},}fuse=1"
  pct set "${CTID}" -features "${NEW_FEATURES}"
fi

# ---------------------------------------------------------------------------
# 2. Injection de la configuration binder / apparmor / cgroup
# ---------------------------------------------------------------------------
echo "==> [3/5] Application de la configuration LXC (binder device, apparmor)"

CONF_FILE="/etc/pve/lxc/${CTID}.conf"
if [[ ! -f "${CONF_FILE}" ]]; then
  echo "Erreur: ${CONF_FILE} introuvable." >&2
  exit 1
fi

# Idempotent: on ne réinjecte pas si déjà présent
if ! grep -q "lxc.hook.autodev" "${CONF_FILE}"; then
  {
    echo ""
    grep -v '^#' "${SCRIPT_DIR}/1-proxmox-host/lxc-config-append.txt"
  } >> "${CONF_FILE}"
  echo "    -> Configuration binder ajoutée à ${CONF_FILE}"
else
  echo "    -> Configuration binder déjà présente, on ne touche pas à ${CONF_FILE}"
fi

echo "==> Redémarrage du conteneur ${CTID}"
pct stop "${CTID}" >/dev/null 2>&1 || true
sleep 2
pct start "${CTID}"

echo "==> Attente de la disponibilité réseau du conteneur..."
for _ in $(seq 1 30); do
  if pct exec "${CTID}" -- true >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# ---------------------------------------------------------------------------
# 3. Copie du dépôt dans le conteneur et exécution du pipeline
# ---------------------------------------------------------------------------
echo "==> [4/5] Copie des scripts dans le conteneur et installation de Waydroid"

REMOTE_DIR="/opt/waydroid-lxc-deploy"
pct exec "${CTID}" -- mkdir -p "${REMOTE_DIR}"
# pct push ne gère qu'un fichier à la fois: on archive puis on extrait côté conteneur.
TMP_TAR="$(mktemp)"
tar -C "${SCRIPT_DIR}" -czf "${TMP_TAR}" \
  2-lxc-setup 3-services 4-waydroid-tools
pct push "${CTID}" "${TMP_TAR}" "${REMOTE_DIR}/payload.tar.gz"
rm -f "${TMP_TAR}"
pct exec "${CTID}" -- tar -C "${REMOTE_DIR}" -xzf "${REMOTE_DIR}/payload.tar.gz"

echo "    -> Installation de Waydroid (peut prendre plusieurs minutes)..."
pct exec "${CTID}" -- bash "${REMOTE_DIR}/2-lxc-setup/01-install-waydroid.sh"

echo "    -> Installation des services (weston/wayvnc/novnc)..."
pct exec "${CTID}" -- env "EXPOSE_LAN=${EXPOSE_LAN}" bash "${REMOTE_DIR}/3-services/02-install-services.sh"

echo "    -> Téléchargement des outils Waydroid (spoofing/GPS)..."
pct exec "${CTID}" -- bash -c "cd '${REMOTE_DIR}/4-waydroid-tools' && bash 03-setup-tools.sh"

echo "==> [5/5] Démarrage de la session Waydroid"
pct exec "${CTID}" -- systemctl enable --now waydroid-session.service

CT_IP="$(pct exec "${CTID}" -- hostname -I 2>/dev/null | awk '{print $1}')"

if [[ "${EXPOSE_LAN}" == "yes" ]]; then
  ACCESS_MSG="Accès noVNC : http://${CT_IP:-<IP_DU_CTID>}:6080/vnc.html
   ATTENTION : exposé sur le LAN SANS authentification (--expose-lan)."
else
  ACCESS_MSG="Accès noVNC (via tunnel SSH, aucun accès direct exposé) :
     ssh -L 6080:127.0.0.1:6080 root@${CT_IP:-<IP_DU_CTID>}
     puis ouvrez http://127.0.0.1:6080/vnc.html"
fi

cat <<EOF

============================================================
 Déploiement terminé.
   CTID           : ${CTID}
   ${ACCESS_MSG}
   Répertoire     : ${REMOTE_DIR} (dans le conteneur)

 Voir la section "Sécurité" du README (conteneur privilégié,
 apparmor unconfined, accès VNC) avant toute mise en production.
============================================================
EOF
