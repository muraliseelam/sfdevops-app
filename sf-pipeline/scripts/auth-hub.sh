#!/usr/bin/env bash
# auth-hub.sh - log in to the hub org under the alias `hub` (never made the default org).
#
# Two ways, from repository secrets:
#   1. JWT (first choice, used whenever all three are set)
#        HUB_CONSUMER_KEY, HUB_USERNAME, HUB_JWT_KEY
#        HUB_INSTANCE_URL   default https://login.salesforce.com
#   2. SFDX auth URL (for hubs that cannot create a Connected App), used only when one of the
#      JWT secrets is empty
#        HUB_AUTH_URL       force://<clientId>:<clientSecret>:<refreshToken>@<instance>
#   HUB_CALLBACK_STRICT=true   make a failed login fail the step
#
# The hub is optional: when NEITHER set is present the script prints a notice and exits 0, so
# the pipeline runs without a hub (GitHub-only mode). The hub alias is NOT made the default org,
# so a deploy org authenticated earlier in the job stays the default. Secrets go through a
# private temp file removed by a trap, and are never echoed.
# Output: hub_available=true|false.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

missing=()
for var in HUB_CONSUMER_KEY HUB_USERNAME HUB_JWT_KEY; do
  [[ -n "${!var:-}" ]] || missing+=("$var")
done

method=""
if [[ ${#missing[@]} -eq 0 ]]; then
  method=jwt
elif [[ -n "${HUB_AUTH_URL:-}" ]]; then
  method=url
else
  notice "hub callbacks disabled: HUB_* secrets not set (set HUB_CONSUMER_KEY, HUB_USERNAME and HUB_JWT_KEY, or HUB_AUTH_URL; missing: ${missing[*]})"
  gh_output hub_available false
  exit 0
fi

require_cmd sf
ok=0
if [[ "$method" == "jwt" ]]; then
  require_cmd base64
  instance_url="${HUB_INSTANCE_URL:-https://login.salesforce.com}"
  echo "Authenticating to the hub with JWT as $HUB_USERNAME via $instance_url"
  sf_jwt_login hub "$HUB_CONSUMER_KEY" "$HUB_USERNAME" "$instance_url" "$HUB_JWT_KEY" false HUB_JWT_KEY || ok=$?
else
  echo "Authenticating to the hub with the SFDX auth URL in HUB_AUTH_URL"
  sf_url_login hub "$HUB_AUTH_URL" false HUB_AUTH_URL || ok=$?
fi

if [[ "$ok" -eq 0 ]]; then
  echo "Authenticated: alias 'hub' is ready for callbacks."
  gh_output hub_available true
  exit 0
fi

gh_output hub_available false
if is_true "${HUB_CALLBACK_STRICT:-false}"; then
  die "login to the hub failed (HUB_CALLBACK_STRICT=true). Check the HUB_* repository secrets."
fi
warn "login to the hub failed; hub callbacks are disabled for this run. Check the HUB_* repository secrets."
exit 0
