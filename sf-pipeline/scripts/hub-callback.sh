#!/usr/bin/env bash
# hub-callback.sh <endpoint> <json-file> - POST a callback to the hub's Apex REST API.
#
#   endpoint   deploy-callback | merge-status | source-members
#   json-file  the request body
#
# Uses the org alias `hub` (see auth-hub.sh). When it is not authenticated the script prints a
# notice and exits 0, so the pipeline runs without a hub. Otherwise it POSTs the file to
# services/apexrest/cdo/<endpoint> with `sf api request rest`, which signs the request with the
# CLI's own session, so no access token is ever read, printed or put on a command line (recent
# CLIs redact the token in `sf org display` anyway). Retries with backoff on HTTP 5xx or a
# connection error. The HTTP status and response body are printed.
#
# Env
#   HUB_CALLBACK_STRICT=true   a non-2xx response fails the step (default: warn, exit 0)
#   HUB_CALLBACK_RETRIES       retries after the first attempt (default 3)
#   HUB_CALLBACK_BACKOFF       first backoff in seconds, doubled per retry (default 2)
#   HUB_ALIAS                  org alias of the hub (default hub)
# Output: http_status (blank when skipped).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

usage() {
  echo "usage: hub-callback.sh <deploy-callback|merge-status|source-members> <json-file>" >&2
  exit 2
}
[[ $# -eq 2 ]] || usage
endpoint="$1"
json_file="$2"
case "$endpoint" in
  deploy-callback | merge-status | source-members) ;;
  *)
    echo "hub-callback.sh: unknown endpoint '$endpoint'" >&2
    usage
    ;;
esac
[[ -s "$json_file" ]] || die "callback body '$json_file' does not exist or is empty"

strict=false
is_true "${HUB_CALLBACK_STRICT:-false}" && strict=true
retries="${HUB_CALLBACK_RETRIES:-3}"
backoff="${HUB_CALLBACK_BACKOFF:-2}"
alias_name="${HUB_ALIAS:-hub}"
[[ "$retries" =~ ^[0-9]+$ ]] || die "HUB_CALLBACK_RETRIES must be a whole number, got '$retries'"
[[ "$backoff" =~ ^[0-9]+$ ]] || die "HUB_CALLBACK_BACKOFF must be a whole number of seconds, got '$backoff'"

# A callback that cannot be delivered must not break the run unless strict mode asks for it.
give_up() {
  gh_output http_status "${2:-}"
  if [[ "$strict" == "true" ]]; then
    die "$1 (HUB_CALLBACK_STRICT=true)"
  fi
  warn "$1"
  exit 0
}

if ! command -v sf >/dev/null 2>&1; then
  notice "hub callback '$endpoint' skipped: the sf CLI is not installed, so alias '$alias_name' cannot be authenticated"
  gh_output http_status ""
  exit 0
fi

if ! sf org display -o "$alias_name" --json >/dev/null 2>&1; then
  notice "hub callback '$endpoint' skipped: org alias '$alias_name' is not authenticated (hub callbacks disabled)"
  gh_output http_status ""
  exit 0
fi

PY="$(find_python)" || give_up "hub callback '$endpoint' not sent: python3 is required to check the payload"
if ! "$PY" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$json_file" 2>/dev/null; then
  give_up "hub callback '$endpoint' not sent: '$json_file' is not valid JSON"
fi

path="services/apexrest/cdo/$endpoint"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
raw="$workdir/raw"

attempts=$((retries + 1))
code="000"
for ((i = 1; i <= attempts; i++)); do
  : >"$raw"
  sf api request rest "$path" --method POST --header "Content-Type:application/json" \
    --header "Accept:application/json" --body "@$json_file" --target-org "$alias_name" --include \
    >"$raw" 2>&1 || true
  code="$(tr -d '\r' <"$raw" | sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | head -n 1)"
  [[ -n "$code" ]] || code="000"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    break
  fi
  if [[ "$code" == "000" || "$code" =~ ^5[0-9][0-9]$ ]]; then
    reason="HTTP $code"
    [[ "$code" == "000" ]] && reason="no HTTP response ($(tr -d '\r' <"$raw" | grep -v '^\s*$' | head -n 1))"
    if ((i < attempts)); then
      wait_s=$((backoff * (1 << (i - 1))))
      echo "hub callback '$endpoint' attempt $i/$attempts failed: $reason; retrying in ${wait_s}s"
      sleep "$wait_s"
      continue
    fi
  fi
  break
done

echo "hub callback '$endpoint' -> $path (org alias $alias_name)"
echo "HTTP status: $code"
echo "Response body:"
# `--include` prints the status line and headers, then the body with no blank line between:
# the body starts at the first line that opens a JSON value.
body="$(tr -d '\r' <"$raw" | awk 'found || /^[[{]/ {found=1; print}')"
if [[ -n "$body" ]]; then
  printf '%s\n' "$body"
else
  echo "(empty)"
fi

if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
  gh_output http_status "$code"
  exit 0
fi
if [[ "$code" == "000" ]]; then
  give_up "hub callback '$endpoint' got no HTTP response after $attempts attempt(s)" "$code"
fi
give_up "hub callback '$endpoint' returned HTTP $code" "$code"
