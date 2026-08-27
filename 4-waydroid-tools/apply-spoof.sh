#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Wraps spoof-device.sh (downloaded by 03-setup-tools.sh) to make applying
# it idempotent and reversible. spoof-device.sh just appends a fixed block
# of "key=value" lines to /var/lib/waydroid/waydroid_base.prop - run
# directly, running it twice duplicates every line, and there's no way
# back to the configuration Waydroid generated at 'waydroid init' time.
# This script:
#   1. Snapshots the current file once, before the first-ever spoof, to
#      <file>.orig - never overwritten again.
#   2. Runs spoof-device.sh, then deduplicates the result by property key
#      (text before the first '='), keeping the LAST occurrence of each -
#      so re-running (e.g. after SPOOF_REF picks up an upstream change)
#      replaces old values instead of piling up duplicates.
#   3. '--rollback' restores the snapshot instead of spoofing.
#
# Either way, a container restart is required for the change to take
# effect - see docs/DEBUGGING_AND_TESTS.md, Phase 4.
set -euo pipefail

BASE_PROP="/var/lib/waydroid/waydroid_base.prop"
BACKUP="${BASE_PROP}.orig"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTART_HINT="systemctl stop waydroid-session && systemctl restart waydroid-container && systemctl start waydroid-session"

if [[ ! -f "${BASE_PROP}" ]]; then
  echo "Error: ${BASE_PROP} not found - has 'waydroid init' been run?" >&2
  exit 1
fi

if [[ "${1:-}" == "--rollback" ]]; then
  if [[ ! -f "${BACKUP}" ]]; then
    echo "Error: no backup at ${BACKUP} - nothing to roll back to." >&2
    echo "(A backup is only created the first time this script applies a spoof.)" >&2
    exit 1
  fi
  cp "${BACKUP}" "${BASE_PROP}"
  echo "Restored ${BASE_PROP} from ${BACKUP}."
  echo "Now restart the container: ${RESTART_HINT}"
  exit 0
fi

if [[ ! -f "${SCRIPT_DIR}/spoof-device.sh" ]]; then
  echo "Error: spoof-device.sh not found next to this script - run 03-setup-tools.sh first." >&2
  exit 1
fi

if [[ ! -f "${BACKUP}" ]]; then
  echo "No existing backup - snapshotting the current configuration to ${BACKUP}..."
  echo "(If a spoof was already applied by hand before this script existed, this"
  echo " snapshot reflects that state, not necessarily the true 'waydroid init'"
  echo " defaults - re-run 'waydroid init -f' for a genuinely clean slate.)"
  cp "${BASE_PROP}" "${BACKUP}"
fi

echo "Applying spoof-device.sh..."
( cd "${SCRIPT_DIR}" && ./spoof-device.sh )

echo "Deduplicating ${BASE_PROP} (keeping the last value for each key)..."
TMP_PROP="$(mktemp)"
tac "${BASE_PROP}" | awk -F'=' '!seen[$1]++' | tac > "${TMP_PROP}"
chmod 644 "${TMP_PROP}"
mv "${TMP_PROP}" "${BASE_PROP}"

echo "Done. ${BACKUP} holds the pre-spoof configuration for rollback (--rollback)."
echo "Restart the container to apply: ${RESTART_HINT}"
