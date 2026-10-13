#!/usr/bin/env bash
# hub-callback.sh <endpoint> <json-file> - POST a callback to the hub's Apex REST API.
#
#   endpoint   deploy-callback | merge-status | source-members
#   json-file  the request body
#
# Uses the org alias `hub` (see auth-hub.sh). When it is not authenticated the script prints a
# notice and exits 0, so the pipeline runs without a hub. Otherwise it reads the access token
# and instance URL from `sf org display -o hub --json`, masks the token, and POSTs the file to
# $instance/services/apexrest/cdo/<endpoint>, retrying with backoff on HTTP 5xx or a
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

display_json=""
if ! display_json="$(sf org display -o "$alias_name" --json 2>/dev/null)"; then
  notice "hub callback '$endpoint' skipped: org alias '$alias_name' is not authenticated (hub callbacks disabled)"
  gh_output http_status ""
  exit 0
fi

PY="$(find_python)" || give_up "hub callback '$endpoint' not sent: python3 is required to read the hub session"

# The JSON travels on stdin, never on a command line.
token="$(printf '%s' "$display_json" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["result"].get("accessToken") or "")' 2>/dev/null || true)"
instance="$(printf '%s' "$display_json" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["result"].get("instanceUrl") or "")' 2>/dev/null || true)"
display_json=""
token="${token//$'\r'/}"
instance="${instance//$'\r'/}"
if [[ -z "$token" || -z "$instance" ]]; then
  give_up "hub callback '$endpoint' not sent: 'sf org display -o $alias_name' returned no access token or instance URL"
fi
mask "$token"

if ! "$PY" -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$json_file" 2>/dev/null; then
  give_up "hub callback '$endpoint' not sent: '$json_file' is not valid JSON"
fi

require_cmd curl
url="${instance%/}/services/apexrest/cdo/$endpoint"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
hdr="$workdir/headers"
resp="$workdir/body"
errf="$workdir/stderr"
# The bearer token goes into a private header file (printf is a builtin), so it never shows up
# in a process listing or in the log.
(umask 077 && printf 'Authorization: Bearer %s\n' "$token" >"$hdr")
token=""

attempts=$((retries + 1))
code="000"
for ((i = 1; i <= attempts; i++)); do
  : >"$resp"
  rc=0
  code="$(curl -sS -o "$resp" -w '%{http_code}' \
    --connect-timeout 15 --max-time 120 \
    -X POST -H @"$hdr" -H 'Content-Type: application/json' -H 'Accept: application/json' \
    --data-binary @"$json_file" "$url" 2>"$errf")" || rc=$?
  [[ -n "$code" ]] || code="000"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    break
  fi
  if [[ "$code" == "000" || "$code" =~ ^5[0-9][0-9]$ ]]; then
    reason="HTTP $code"
    [[ "$code" == "000" ]] && reason="connection error (curl exit $rc: $(tr -d '\r' <"$errf" | head -n 1))"
    if ((i < attempts)); then
      wait_s=$((backoff * (1 << (i - 1))))
      echo "hub callback '$endpoint' attempt $i/$attempts failed: $reason; retrying in ${wait_s}s"
      sleep "$wait_s"
      continue
    fi
  fi
  break
done

echo "hub callback '$endpoint' -> $url"
echo "HTTP status: $code"
echo "Response body:"
if [[ -s "$resp" ]]; then
  cat "$resp"
  echo
else
  echo "(empty)"
fi

if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
  gh_output http_status "$code"
  exit 0
fi
if [[ "$code" == "000" ]]; then
  give_up "hub callback '$endpoint' could not reach $url after $attempts attempt(s)" "$code"
fi
give_up "hub callback '$endpoint' returned HTTP $code" "$code"
