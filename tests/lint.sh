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
    systemd-analyze verify "$f" 2>&1 || true
  done
  # 5-webapp/waydroid-webapp.service is a template (__APP_DIR__/__VENV_DIR__
  # placeholders, filled in by install-webapp.sh) - verifying it as-is
  # would report a fatal "path is not absolute" error rather than the
  # informational "binary not found" warnings the other units get, so
  # render it with dummy paths first, the same way install-webapp.sh does.
  RENDERED_WEBAPP_UNIT="$(mktemp --suffix=.service)"
  sed \
    -e "s|__APP_DIR__|/opt/waydroid-lxc-deploy/5-webapp|g" \
    -e "s|__VENV_DIR__|/opt/waydroid-webapp-venv|g" \
    5-webapp/waydroid-webapp.service > "${RENDERED_WEBAPP_UNIT}"
  systemd-analyze verify "${RENDERED_WEBAPP_UNIT}" 2>&1 || true
  rm -f "${RENDERED_WEBAPP_UNIT}"
  echo "(informational only: the binaries/units these reference won't exist"
  echo " outside the target container, so warnings above are expected)"
else
  echo "systemd-analyze not available, skipping this step."
fi

echo ""
echo "== Manual .service validation (key=value pairs) =="
for f in 3-services/*.service 5-webapp/*.service; do
  if ! grep -q '^\[Unit\]' "$f" || ! grep -q '^\[Service\]' "$f"; then
    echo "MISSING SECTION: $f"
    FAIL=1
  fi
done
echo "OK"

echo ""
echo "== Checking cross-file path references =="
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
for ref in requirements.txt waydroid-webapp.service app.py auth.py \
           actions/base.py actions/gps.py actions/geocode.py actions/favorites.py \
           routes/gps.py routes/geocode.py routes/favorites.py templates/index.html; do
  if [[ ! -f "5-webapp/${ref}" ]]; then
    echo "MISSING FILE referenced by install-webapp.sh/app.py: 5-webapp/${ref}"
    FAIL=1
  fi
done
echo "OK"

echo ""
echo "== Python syntax (py_compile) =="
if command -v python3 >/dev/null 2>&1; then
  while IFS= read -r -d '' f; do
    if ! python3 -m py_compile "$f" 2>&1; then
      echo "SYNTAX ERROR: $f"
      FAIL=1
    fi
  done < <(find 5-webapp -name '*.py' -print0)
  echo "OK"
else
  echo "python3 not available, skipping this step."
fi

echo ""
echo "== Python unit tests (5-webapp) =="
if python3 -c "import flask, requests" >/dev/null 2>&1; then
  if ! python3 -m unittest discover -s 5-webapp/tests -t 5-webapp -v; then
    FAIL=1
  fi
else
  echo "flask/requests not importable, skipping (pip install -r 5-webapp/requirements.txt to run this step)."
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  echo "=== LINT: PASS ==="
else
  echo "=== LINT: FAIL ==="
fi
exit "${FAIL}"
