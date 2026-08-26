#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$#" -ne 2 ]]; then
  echo "Usage: $0 <latitude> <longitude>"
  echo "Example: $0 48.8584 2.2945"
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/fake_gps.py" ]]; then
  echo "Error: ${SCRIPT_DIR}/fake_gps.py not found." >&2
  echo "Run 03-setup-tools.sh first." >&2
  exit 1
fi

python3 "${SCRIPT_DIR}/fake_gps.py" "$1" "$2"
echo "Location updated to $1, $2."
