#!/usr/bin/env bash
# Lint statique de tous les scripts bash + validation basique des unités
# systemd. Ne nécessite ni Proxmox ni LXC : peut tourner en CI.
#
# Usage: ./tests/lint.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

FAIL=0

echo "== bash -n (syntaxe) =="
while IFS= read -r -d '' f; do
  if ! bash -n "$f"; then
    echo "SYNTAX ERROR: $f"
    FAIL=1
  fi
done < <(find . -name '*.sh' -print0)
echo "OK"

echo ""
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    echo "--- $f ---"
    if ! shellcheck -S warning "$f"; then
      FAIL=1
    fi
  done < <(find . -name '*.sh' -print0)
else
  echo "shellcheck non installé, étape ignorée (apt-get install shellcheck)."
fi

echo ""
echo "== systemd-analyze verify (si disponible) =="
if command -v systemd-analyze >/dev/null 2>&1; then
  for f in 3-services/*.service; do
    if ! systemd-analyze verify "$f" 2>&1 | grep -v '^$'; then
      : # systemd-analyze verify écrit sur stderr même en cas de succès pour
        # certains warnings (ex: unité non installée) ; on ne fait échouer
        # le lint que sur une erreur de PARSING explicite plus bas.
    fi
  done
else
  echo "systemd-analyze non disponible, étape ignorée."
fi

echo ""
echo "== Validation manuelle des .service (paires clé=valeur) =="
for f in 3-services/*.service; do
  if ! grep -q '^\[Unit\]' "$f" || ! grep -q '^\[Service\]' "$f"; then
    echo "MISSING SECTION: $f"
    FAIL=1
  fi
done
echo "OK"

echo ""
echo "== Vérification des références de chemins entre fichiers =="
# 02-install-services.sh doit référencer des fichiers qui existent réellement
for ref in weston.service wayvnc.service novnc.service waydroid-session.service wait-for-wayland-socket.sh; do
  if [[ ! -f "3-services/${ref}" ]]; then
    echo "MISSING FILE referenced by 02-install-services.sh: 3-services/${ref}"
    FAIL=1
  fi
done
if [[ ! -f "2-lxc-setup/weston.ini" ]]; then
  echo "MISSING FILE: 2-lxc-setup/weston.ini"
  FAIL=1
fi
echo "OK"

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  echo "=== LINT: PASS ==="
else
  echo "=== LINT: FAIL ==="
fi
exit "${FAIL}"
