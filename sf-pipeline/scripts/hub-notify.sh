#!/usr/bin/env bash
# hub-notify.sh <endpoint> <payload-kind>
#
# One call per workflow terminal state: authenticate to the hub (if configured), build the
# payload from environment variables with hub_payload.py, and POST it.
#
#   endpoint      deploy-callback | merge-status
#   payload-kind  deploy | merge   (see hub_payload.py for the variables each reads)
#
# The hub is optional. When the HUB_* secrets are absent the pipeline runs in GitHub-only mode:
# this prints a notice and exits 0. A callback that fails is a warning, not a failed deploy,
# unless HUB_CALLBACK_STRICT=true.
set -euo pipefail

endpoint="${1:?usage: hub-notify.sh <deploy-callback|merge-status> <deploy|merge>}"
kind="${2:?usage: hub-notify.sh <deploy-callback|merge-status> <deploy|merge>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${HUB_CONSUMER_KEY:-}" || -z "${HUB_USERNAME:-}" || -z "${HUB_JWT_KEY:-}" ]]; then
  echo "::notice::Hub callback skipped (${endpoint}): HUB_* secrets are not set; running in GitHub-only mode."
  exit 0
fi

if ! command -v sf >/dev/null 2>&1; then
  bash "$here/install-sf.sh" >/dev/null
fi
if ! sf org display -o hub >/dev/null 2>&1; then
  bash "$here/auth-hub.sh" >/dev/null || true
fi

payload="$(mktemp)"
trap 'rm -f "$payload"' EXIT
python3 "$here/hub_payload.py" "$kind" > "$payload"
echo "Hub ${endpoint} payload:"
cat "$payload"
bash "$here/hub-callback.sh" "$endpoint" "$payload"
