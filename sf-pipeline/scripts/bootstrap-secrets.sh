#!/usr/bin/env bash
# bootstrap-secrets.sh — run bootstrap_secrets.py with whichever Python works here.
# See bootstrap_secrets.py for what it does. On Windows PowerShell you can also run:
#   py sf-pipeline/scripts/bootstrap_secrets.py
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then
    exec "$c" "$here/bootstrap_secrets.py" "$@"
  fi
done
echo "No working Python 3 found. Install Python 3.10+ and re-run." >&2
exit 1
