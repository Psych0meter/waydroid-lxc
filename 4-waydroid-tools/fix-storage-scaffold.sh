#!/usr/bin/env bash
# Contournement d'une limitation connue de Waydroid : le système de fichiers
# émulé (/storage/emulated/0) ne crée pas automatiquement l'arborescence
# standard Android/data, Android/obb, Android/media dont le Play Store (et
# beaucoup d'applications) ont besoin pour télécharger/installer. Sans ça,
# le Play Store affiche à tort "Free up space" / manque d'espace, même avec
# de la place disponible sur /data.
# Référence: https://github.com/waydroid/waydroid/issues/530
#            https://github.com/waydroid/waydroid/issues/1911
#
# À relancer après une réinitialisation de Waydroid ('waydroid init -f'),
# ou si une application précise échoue encore avec une erreur du type
# "Can't create file:///storage/emulated/0/Android/data/<pkg>/..." dans
# 'waydroid logcat' : dans ce cas, ajoutez un mkdir -p ciblé sur le chemin
# exact indiqué par le logcat.
set -euo pipefail

if ! command -v waydroid >/dev/null 2>&1; then
  echo "Erreur: commande 'waydroid' introuvable." >&2
  exit 1
fi

echo "Création de l'arborescence de stockage standard..."
waydroid shell -- mkdir -p /storage/emulated/0/Android/data
waydroid shell -- mkdir -p /storage/emulated/0/Android/obb
waydroid shell -- mkdir -p /storage/emulated/0/Android/media
waydroid shell -- chmod -R 777 /storage/emulated/0/Android

echo "Terminé. Retentez l'installation depuis le Play Store."
