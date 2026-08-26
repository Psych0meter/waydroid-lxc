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
if ls /dev/loop0 /dev/loop-control >/dev/null 2>&1; then
  pass "/dev/loop* et /dev/loop-control présents"
else
  fail "/dev/loop* ou /dev/loop-control absents (voir 1-proxmox-host/lxc-config-append.txt)"
fi
[[ -e /dev/fuse ]] && pass "/dev/fuse présent" || fail "/dev/fuse absent (feature Proxmox 'fuse=1' manquante, voir 0-deploy-all.sh)"

echo ""
echo "== Paquets =="
for bin in sway wayvnc websockify waydroid; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "binaire '$bin' trouvé"
  else
    fail "binaire '$bin' introuvable"
  fi
done

echo ""
echo "== Services systemd =="
for svc in sway wayvnc novnc waydroid-container; do
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
SOCK="${XDG_RUNTIME_DIR:-/run/waydroid-wayland}/${WAYLAND_DISPLAY:-wayland-1}"
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
echo "== Bus D-Bus dédié Waydroid =="
if [[ -S /run/waydroid-dbus/session ]]; then
  if dbus-send --address="unix:path=/run/waydroid-dbus/session" --print-reply \
      --dest=org.freedesktop.DBus / org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
    pass "bus D-Bus dédié /run/waydroid-dbus/session répond"
  else
    fail "socket /run/waydroid-dbus/session présent mais ne répond pas"
  fi
else
  fail "/run/waydroid-dbus/session absent (waydroid-session a-t-il déjà démarré ?)"
fi

echo ""
echo "== Conflit dnsmasq système =="
if systemctl is-active --quiet dnsmasq 2>/dev/null; then
  fail "dnsmasq.service système actif — entrera en conflit avec le dnsmasq ad-hoc de waydroid-net.sh sur waydroid0 ('systemctl disable --now dnsmasq')"
else
  pass "dnsmasq.service système inactif (pas de conflit avec waydroid-net.sh)"
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
