#!/usr/bin/env bash
# webex-notify.sh "<markdown message>" - post a message to Webex. Never fails the job.
#
# Env
#   NOTIFY_WEBEX=true                        required, otherwise a notice and exit 0
#   WEBEX_WEBHOOK_URL                        incoming webhook (preferred when set), or
#   WEBEX_BOT_TOKEN + WEBEX_ROOM_ID          bot posting to https://webexapis.com/v1/messages
#   WEBEX_API_URL                            override of the messages endpoint (tests)
# Errors (no destination, HTTP failure, no network) are warnings. Exit code is always 0,
# except 2 for a missing message argument.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

if [[ $# -ne 1 ]]; then
  echo 'usage: webex-notify.sh "<markdown message>"' >&2
  exit 2
fi
message="$1"

if ! is_true "${NOTIFY_WEBEX:-false}"; then
  notice "Webex notification skipped: NOTIFY_WEBEX is not true"
  exit 0
fi
if [[ -z "$message" ]]; then
  warn "Webex notification skipped: the message is empty"
  exit 0
fi
mode=""
if [[ -n "${WEBEX_WEBHOOK_URL:-}" ]]; then
  mode=webhook
elif [[ -n "${WEBEX_BOT_TOKEN:-}" && -n "${WEBEX_ROOM_ID:-}" ]]; then
  mode=bot
else
  notice "Webex notification skipped: set WEBEX_WEBHOOK_URL, or WEBEX_BOT_TOKEN and WEBEX_ROOM_ID"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  warn "Webex notification not sent: curl is not installed"
  exit 0
fi
PY="$(find_python)" || {
  warn "Webex notification not sent: python3 is required to build the message"
  exit 0
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
payload="$workdir/payload.json"
resp="$workdir/response"

if ! WEBEX_MESSAGE="$message" WEBEX_MODE="$mode" "$PY" - "$payload" <<'PY'; then
import json
import os
import sys

body = {"markdown": os.environ["WEBEX_MESSAGE"]}
if os.environ["WEBEX_MODE"] == "bot":
    body = {"roomId": os.environ["WEBEX_ROOM_ID"], **body}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(body, fh)
PY
  warn "Webex notification not sent: could not build the payload"
  exit 0
fi

headers=(-H 'Content-Type: application/json')
if [[ "$mode" == "webhook" ]]; then
  url="$WEBEX_WEBHOOK_URL"
  mask "$url"
else
  url="${WEBEX_API_URL:-https://webexapis.com/v1/messages}"
  mask "$WEBEX_BOT_TOKEN"
  (umask 077 && printf 'Authorization: Bearer %s\n' "$WEBEX_BOT_TOKEN" >"$workdir/auth")
  headers+=(-H @"$workdir/auth")
fi

code="$(curl -sS -o "$resp" -w '%{http_code}' --connect-timeout 10 --max-time 30 \
  -X POST "${headers[@]}" --data-binary @"$payload" "$url" 2>"$workdir/err")" || true
code="${code:-000}"
if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
  echo "Webex notification sent ($mode, HTTP $code)."
else
  # On a connection error curl writes no response file, so every read here tolerates absence.
  detail="$(head -c 300 "$resp" 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "$code" == "000" ]]; then
    detail="$(head -n 1 "$workdir/err" 2>/dev/null | tr -d '\r' || true)"
  fi
  warn "Webex notification failed ($mode, HTTP $code): ${detail:-no response}"
fi
exit 0
