#!/usr/bin/env bash
# auth-jwt.sh <alias> - log in to one org and set it as the default org.
#
# Two ways, chosen from the secrets of the GitHub Environment the job runs in:
#
# 1. JWT bearer (first choice, used whenever all three are set)
#      SF_CONSUMER_KEY   Connected App consumer key
#      SF_USERNAME       integration username
#      SF_JWT_KEY        base64 of server.key, one line
#      SF_INSTANCE_URL   login / My Domain URL (default https://login.salesforce.com)
#    Runs exactly:
#      sf org login jwt --client-id "$SF_CONSUMER_KEY" --jwt-key-file <tmp> --username "$SF_USERNAME" \
#        --instance-url "${SF_INSTANCE_URL:-https://login.salesforce.com}" --alias "$ALIAS" --set-default
#
# 2. SFDX auth URL (for orgs that cannot create a Connected App)
#      SF_AUTH_URL       force://<clientId>:<clientSecret>:<refreshToken>@<instance>
#                        (from: sf org auth show-sfdx-auth-url --target-org <alias>)
#    Used only when one of the JWT secrets is empty. Runs:
#      sf org login sfdx-url --sfdx-url-file <tmp> --alias "$ALIAS" --set-default
#
# The key or URL is written to a private mktemp file (umask 077) that a trap removes on exit.
# It is never echoed. Exit codes: 0 logged in, 1 no usable secrets or login failure, 2 usage.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "usage: auth-jwt.sh <alias>" >&2
  exit 2
fi
ALIAS="$1"

missing=()
for var in SF_CONSUMER_KEY SF_USERNAME SF_JWT_KEY; do
  [[ -n "${!var:-}" ]] || missing+=("$var")
done

if [[ ${#missing[@]} -eq 0 ]]; then
  require_cmd sf base64
  SF_INSTANCE_URL="${SF_INSTANCE_URL:-https://login.salesforce.com}"
  echo "Authenticating to '$ALIAS' with JWT as $SF_USERNAME via $SF_INSTANCE_URL"
  if ! sf_jwt_login "$ALIAS" "$SF_CONSUMER_KEY" "$SF_USERNAME" "$SF_INSTANCE_URL" "$SF_JWT_KEY" true SF_JWT_KEY; then
    die "JWT login to '$ALIAS' failed. Check SF_CONSUMER_KEY, SF_USERNAME and SF_INSTANCE_URL on the GitHub Environment, that the Connected App holds the certificate for this key, and that the user's profile or permission set is pre-authorized on the app."
  fi
  echo "Authenticated: '$ALIAS' is now the default org."
  exit 0
fi

if [[ -n "${SF_AUTH_URL:-}" ]]; then
  require_cmd sf
  echo "Authenticating to '$ALIAS' with the SFDX auth URL in SF_AUTH_URL (JWT secrets not set: ${missing[*]})"
  if ! sf_url_login "$ALIAS" "$SF_AUTH_URL" true SF_AUTH_URL; then
    die "SFDX auth URL login to '$ALIAS' failed. Regenerate SF_AUTH_URL with 'sf org auth show-sfdx-auth-url --target-org <alias>' (the refresh token may have been revoked) and update the GitHub Environment secret."
  fi
  echo "Authenticated: '$ALIAS' is now the default org."
  exit 0
fi

error "No credentials for '$ALIAS'. Add secrets to the GitHub Environment this job runs in (Settings > Environments > <environment> > Environment secrets) and pass them to this step as env, either: (1) JWT: SF_CONSUMER_KEY, SF_USERNAME and SF_JWT_KEY (optionally SF_INSTANCE_URL) - missing: ${missing[*]}; or (2) SF_AUTH_URL, an SFDX auth URL from 'sf org auth show-sfdx-auth-url', for orgs that cannot create a Connected App."
exit 1
