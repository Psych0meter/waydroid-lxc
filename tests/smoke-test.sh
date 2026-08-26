#!/usr/bin/env bash
# Smoke test to run INSIDE the LXC container after deployment, to check
# that the stack works end to end.
#
# Usage (from the Proxmox host): pct exec <CTID> -- bash /opt/waydroid-lxc-deploy/tests/smoke-test.sh
# Usage (from inside the container): ./tests/smoke-test.sh
set -uo pipefail

FAIL=0
pass()  { echo "  [OK]   $1"; }
fail()  { echo "  [FAIL] $1"; FAIL=1; }

echo "== Devices =="
[[ -e /dev/binder ]] && pass "/dev/binder present" || fail "/dev/binder missing (see 1-proxmox-host/)"
if ls /dev/loop0 /dev/loop-control >/dev/null 2>&1; then
  pass "/dev/loop* and /dev/loop-control present"
else
  fail "/dev/loop* or /dev/loop-control missing (see 1-proxmox-host/lxc-config-append.txt)"
fi
[[ -e /dev/fuse ]] && pass "/dev/fuse present" || fail "/dev/fuse missing (Proxmox 'fuse=1' feature not set, see 0-deploy-all.sh)"

echo ""
echo "== Packages =="
for bin in sway wayvnc websockify waydroid; do
  if command -v "$bin" >/dev/null 2>&1; then
    pass "'$bin' binary found"
  else
    fail "'$bin' binary not found"
  fi
done

echo ""
echo "== systemd services =="
for svc in sway wayvnc novnc waydroid-container; do
  if systemctl is-active --quiet "$svc"; then
    pass "$svc service active"
  else
    fail "$svc service inactive (journalctl -u $svc -e)"
  fi
done
if systemctl is-enabled --quiet waydroid-session 2>/dev/null; then
  pass "waydroid-session enabled at boot"
else
  fail "waydroid-session not enabled"
fi

echo ""
echo "== Wayland socket =="
SOCK="${XDG_RUNTIME_DIR:-/run/waydroid-wayland}/${WAYLAND_DISPLAY:-wayland-1}"
[[ -S "$SOCK" ]] && pass "Wayland socket present ($SOCK)" || fail "Wayland socket missing ($SOCK)"

echo ""
echo "== Listening ports =="
if command -v ss >/dev/null 2>&1; then
  ss -ltnp 2>/dev/null | grep -q ':5900' && pass "wayvnc listening on :5900" || fail "nothing listening on :5900"
  ss -ltnp 2>/dev/null | grep -q ':6080' && pass "websockify listening on :6080" || fail "nothing listening on :6080"
else
  echo "  ('ss' not available, skipping this step - install iproute2)"
fi

echo ""
echo "== Dedicated Waydroid D-Bus bus =="
if [[ -S /run/waydroid-dbus/session ]]; then
  if dbus-send --address="unix:path=/run/waydroid-dbus/session" --print-reply \
      --dest=org.freedesktop.DBus / org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; then
    pass "dedicated D-Bus bus /run/waydroid-dbus/session responding"
  else
    fail "/run/waydroid-dbus/session socket present but not responding"
  fi
else
  fail "/run/waydroid-dbus/session missing (has waydroid-session started yet?)"
fi

echo ""
echo "== System dnsmasq conflict =="
if systemctl is-active --quiet dnsmasq 2>/dev/null; then
  fail "system dnsmasq.service active - will conflict with waydroid-net.sh's ad-hoc dnsmasq on waydroid0 ('systemctl disable --now dnsmasq')"
else
  pass "system dnsmasq.service inactive (no conflict with waydroid-net.sh)"
fi

echo ""
echo "== Waydroid state =="
if command -v waydroid >/dev/null 2>&1; then
  STATUS_OUT="$(waydroid status 2>&1 || true)"
  echo "$STATUS_OUT" | sed 's/^/  /'
  echo "$STATUS_OUT" | grep -q "Session:.*RUNNING" && pass "Waydroid session RUNNING" || fail "Waydroid session not RUNNING (was it started? 'systemctl start waydroid-session')"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  echo "=== SMOKE TEST: PASS ==="
else
  echo "=== SMOKE TEST: FAIL ==="
fi
exit "${FAIL}"
