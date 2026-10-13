#!/usr/bin/env bash
# audit-append.sh - thin wrapper: passes every argument to audit.py.
#   audit-append.sh --event Deploy --status Success --env qa --work-item WI-0032 [...]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

PY="$(find_python)" || die "python3 (3.10+) is required for audit.py"
exec "$PY" "$here/audit.py" "$@"
