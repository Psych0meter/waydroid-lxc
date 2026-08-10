#!/usr/bin/env bash
# Smoke test à exécuter DANS le conteneur LXC après déploiement, pour
# vérifier que la stack est fonctionnelle de bout en bout.
#
# Usage (depuis l'hôte Proxmox): pct exec <CTID> -- bash /opt/waydroid-lxc-deploy/tests/smoke-test.sh
# Usage (depuis l'intérieur du conteneur): ./tests/smoke-test.sh
set -uo pipefail

FAIL=0
pass()  { echo "  [OK]   $1"; }
fail()  { echo "  [FAIL] $1"; FAIL=1; }

echo "== Devices =="
[[ -e /dev/binder ]] && pass "/dev/binder présent" || fail "/dev/binder absent (voir 1-proxmox-host/)"

echo ""
echo "== Paquets =="
for bin in weston wayvnc websockify waydroid; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "binaire '$bin' trouvé"
  else
    fail "binaire '$bin' introuvable"
  fi
done

echo ""
echo "== Services systemd =="
for svc in weston wayvnc novnc waydroid-container; do
  if systemctl is-active --quiet "$svc"; then
    pass "service $svc actif"
  else
    fail "service $svc inactif (journalctl -u $svc -e)"
  fi
done
if systemctl is-enabled --quiet waydroid-session 2>/dev/null; then
  pass "waydroid-session activé au boot"
else
  fail "waydroid-session non activé"
fi

echo ""
echo "== Socket Wayland =="
SOCK="${XDG_RUNTIME_DIR:-/run/user/0}/${WAYLAND_DISPLAY:-wayland-1}"
[[ -S "$SOCK" ]] && pass "socket Wayland présent ($SOCK)" || fail "socket Wayland absent ($SOCK)"

echo ""
echo "== Ports en écoute =="
if command -v ss >/dev/null 2>&1; then
  ss -ltnp 2>/dev/null | grep -q ':5900' && pass "wayvnc écoute sur :5900" || fail "rien n'écoute sur :5900"
  ss -ltnp 2>/dev/null | grep -q ':6080' && pass "websockify écoute sur :6080" || fail "rien n'écoute sur :6080"
else
  echo "  ('ss' indisponible, étape ignorée — installez iproute2)"
fi

echo ""
echo "== État Waydroid =="
if command -v waydroid >/dev/null 2>&1; then
  STATUS_OUT="$(waydroid status 2>&1 || true)"
  echo "$STATUS_OUT" | sed 's/^/  /'
  echo "$STATUS_OUT" | grep -q "Session:.*RUNNING" && pass "session Waydroid RUNNING" || fail "session Waydroid non RUNNING (a-t-elle été démarrée ? 'systemctl start waydroid-session')"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  echo "=== SMOKE TEST: PASS ==="
else
  echo "=== SMOKE TEST: FAIL ==="
fi
exit "${FAIL}"
