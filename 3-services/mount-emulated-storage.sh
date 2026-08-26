#!/usr/bin/env bash
# Force le montage du volume "emulated;0" (stockage interne Android) après
# le démarrage de la session.
#
# Constat (validé en conditions réelles) : sur l'image Waydroid GAPPS
# utilisée par ce dépôt, 'vold' marque ce volume UNMOUNTABLE au boot et ne
# retente JAMAIS de lui-même, quel que soit l'état de /dev/fuse. Un appel
# explicite via 'sm mount' (l'outil StorageManager moderne — à la
# différence de 'vdc', dont les commandes texte brutes ne sont plus
# supportées sur les versions récentes d'Android) suffit à le faire passer
# à l'état MOUNTED. Sans ce script : le Play Store et d'autres applications
# affichent à tort "Not enough storage space" alors que /data a
# effectivement de la place (visible via 'waydroid shell -- dumpsys mount'
# : state=UNMOUNTABLE, et 'waydroid shell -- dumpsys diskstats' qui montre
# pourtant de l'espace libre).
set -uo pipefail

for _ in $(seq 1 30); do
  if waydroid shell -- sm mount 'emulated;0' >/dev/null 2>&1; then
    exit 0
  fi
  sleep 2
done

echo "Avertissement: impossible de monter le volume emulated;0 après plusieurs tentatives (le service Android est-il bien démarré ?)." >&2
exit 0
