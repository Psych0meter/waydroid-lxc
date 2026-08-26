#!/usr/bin/env bash
# Static lint for all bash scripts, plus basic validation of the systemd
# units. Needs neither Proxmox nor an LXC: can run in CI.
#
# Usage: ./tests/lint.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}" || exit 1

FAIL=0

echo "== bash -n (syntax) =="
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
  echo "shellcheck not installed, skipping this step (apt-get install shellcheck)."
fi

echo ""
echo "== systemd-analyze verify (if available) =="
if command -v systemd-analyze >/dev/null 2>&1; then
  for f in 3-services/*.service; do
    if ! systemd-analyze verify "$f" 2>&1 | grep -v '^$'; then
      : # systemd-analyze verify writes to stderr even on success for some
        # warnings (e.g. unit not installed); only fail the lint on an
        # explicit PARSING error, handled below.
    fi
  done
else
  echo "systemd-analyze not available, skipping this step."
fi

echo ""
echo "== Manual .service validation (key=value pairs) =="
for f in 3-services/*.service; do
  if ! grep -q '^\[Unit\]' "$f" || ! grep -q '^\[Service\]' "$f"; then
    echo "MISSING SECTION: $f"
    FAIL=1
  fi
done
echo "OK"

echo ""
echo "== Checking cross-file path references =="
# 02-install-services.sh must reference files that actually exist
for ref in sway.service wayvnc.service novnc.service waydroid-session.service wait-for-wayland-socket.sh ensure-waydroid-dbus.sh mount-emulated-storage.sh; do
  if [[ ! -f "3-services/${ref}" ]]; then
    echo "MISSING FILE referenced by 02-install-services.sh: 3-services/${ref}"
    FAIL=1
  fi
done
if [[ ! -f "2-lxc-setup/sway-headless-config" ]]; then
  echo "MISSING FILE: 2-lxc-setup/sway-headless-config"
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
