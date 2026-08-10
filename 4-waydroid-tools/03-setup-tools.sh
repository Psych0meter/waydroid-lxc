#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# NOTE SÉCURITÉ (supply-chain) : ce script télécharge et rend exécutables
# deux scripts tiers non maintenus par ce dépôt. Ils sont largement utilisés
# par la communauté Waydroid, mais provenant de dépôts GitHub individuels
# (pas d'organisation, pas de signature). Pour figer une version précise
# plutôt que de suivre 'main' en continu, définissez SPOOF_REF / GPS_REF
# (commit SHA ou tag) avant d'exécuter ce script. Vérifiez le contenu des
# scripts avant toute exécution si vous ne faites pas confiance à la chaîne
# d'approvisionnement par défaut.
set -euo pipefail

SPOOF_REPO="Quackdoc/waydroid-scripts"
SPOOF_REF="${SPOOF_REF:-main}"
GPS_REPO="ayasa520/waydroid_stuff"
GPS_REF="${GPS_REF:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "Downloading Quackdoc's spoof-device.sh (ref: ${SPOOF_REF})..."
wget -qO spoof-device.sh "https://raw.githubusercontent.com/${SPOOF_REPO}/${SPOOF_REF}/spoof-device.sh"
chmod +x spoof-device.sh

echo "Downloading ayasa520's fake_gps.py (ref: ${GPS_REF})..."
wget -qO fake_gps.py "https://raw.githubusercontent.com/${GPS_REPO}/${GPS_REF}/fake_gps.py"
chmod +x fake_gps.py

echo "Tools downloaded and ready!"
