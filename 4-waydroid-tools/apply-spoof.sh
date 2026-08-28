#!/usr/bin/env bash
# Runs INSIDE the Debian 13 LXC.
#
# Applies a vendored device-identity spoof (device-profiles/*.prop - see
# device-profiles/README.md) to Waydroid's waydroid_base.prop, idempotently
# and reversibly:
#   1. Snapshots the current file once, before the first-ever spoof, to
#      <file>.orig - never overwritten again.
#   2. Appends the selected profile's properties, then deduplicates the
#      result by property key (text before the first '='), keeping the
#      LAST occurrence of each - so switching profiles or re-running
#      replaces old values instead of piling up duplicates.
#   3. '--rollback' restores the snapshot instead of spoofing.
#
# Either way, a container restart is required for the change to take
# effect - see docs/DEBUGGING_AND_TESTS.md, Phase 4.
#
# enable-adb.sh (headless adb authorization) edits the same file and
# shares this snapshot: whichever of the two scripts runs first on a
# given container captures it, and '--rollback' here undoes both changes
# at once.
#
# Usage: ./apply-spoof.sh [--device <profile>] [--list] [--rollback]
#   --device <profile>  Profile name from device-profiles/*.prop (default:
#                        pixel-5, or $SPOOF_DEVICE_PROFILE if set).
#   --list               Print the available profiles and exit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SCRIPT_DIR}/device-profiles"
BASE_PROP="/var/lib/waydroid/waydroid_base.prop"
BACKUP="${BASE_PROP}.orig"
RESTART_HINT="systemctl stop waydroid-session && systemctl restart waydroid-container && systemctl start waydroid-session"

list_profiles() {
  echo "Available device profiles:"
  local f name desc
  for f in "${PROFILES_DIR}"/*.prop; do
    [[ -e "${f}" ]] || continue
    name="$(basename "${f}" .prop)"
    desc="$(sed -n '2{s/^#[[:space:]]*//p}' "${f}")"
    printf '  %-10s %s\n' "${name}" "${desc}"
  done
}

DEVICE_PROFILE="${SPOOF_DEVICE_PROFILE:-pixel-5}"
DO_ROLLBACK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_PROFILE="$2"; shift 2 ;;
    --list) list_profiles; exit 0 ;;
    --rollback) DO_ROLLBACK=1; shift 1 ;;
    -h|--help)
      echo "Usage: $0 [--device <profile>] [--list] [--rollback]"
      echo ""
      list_profiles
      exit 0
      ;;
    *) echo "Error: unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ ! -f "${BASE_PROP}" ]]; then
  echo "Error: ${BASE_PROP} not found - has 'waydroid init' been run?" >&2
  exit 1
fi

if [[ "${DO_ROLLBACK}" -eq 1 ]]; then
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

PROFILE_FILE="${PROFILES_DIR}/${DEVICE_PROFILE}.prop"
if [[ ! -f "${PROFILE_FILE}" ]]; then
  echo "Error: no device profile named '${DEVICE_PROFILE}' (${PROFILE_FILE} not found)." >&2
  list_profiles >&2
  exit 1
fi

if [[ ! -f "${BACKUP}" ]]; then
  echo "No existing backup - snapshotting the current configuration to ${BACKUP}..."
  echo "(If a spoof was already applied by hand before this script existed, this"
  echo " snapshot reflects that state, not necessarily the true 'waydroid init'"
  echo " defaults - re-run 'waydroid init -f' for a genuinely clean slate.)"
  cp "${BASE_PROP}" "${BACKUP}"
fi

echo "Applying device profile '${DEVICE_PROFILE}' (${PROFILE_FILE})..."
grep -v '^[[:space:]]*#' "${PROFILE_FILE}" | grep -v '^[[:space:]]*$' >> "${BASE_PROP}"

echo "Deduplicating ${BASE_PROP} (keeping the last value for each key)..."
TMP_PROP="$(mktemp)"
tac "${BASE_PROP}" | awk -F'=' '!seen[$1]++' | tac > "${TMP_PROP}"
chmod 644 "${TMP_PROP}"
mv "${TMP_PROP}" "${BASE_PROP}"

echo "Done. ${BACKUP} holds the pre-spoof configuration for rollback (--rollback)."
echo "Restart the container to apply: ${RESTART_HINT}"
