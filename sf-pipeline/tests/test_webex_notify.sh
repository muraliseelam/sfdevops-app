#!/usr/bin/env bash
# Tests for webex-notify.sh with a stub `curl`. It must never fail the job.
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

T="$(new_tmp)"
BIN="$T/bin"
S="$T/stub"
mkdir -p "$S"
write_stub "$BIN" curl <<'EOF'
#!/usr/bin/env bash
# Stub curl: records the URL, payload and whether a bearer header file was sent.
out="" url="" data=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w | --connect-timeout | --max-time | -X) shift 2 ;;
    -H)
      if [[ "$2" == @* ]] && grep -q '^Authorization: Bearer fake-bot-token$' "${2#@}"; then echo yes >"$STUB/auth"; fi
      shift 2 ;;
    --data-binary) data="${2#@}"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >"$STUB/url"
cp "$data" "$STUB/payload.json"
code="$(cat "$STUB/code" 2>/dev/null || echo 200)"
if [[ "$code" == "000" ]]; then echo "curl: (6) Could not resolve host" >&2; printf '000'; exit 6; fi
echo '{"id":"msg1"}' >"$out"
printf '%s' "$code"
EOF

run_wx() { # run_wx "<message>" [VAR=value ...]
  local msg="$1"
  shift
  rm -f "$S/url" "$S/payload.json" "$S/auth"
  RC=0
  OUT="$(env -u NOTIFY_WEBEX -u WEBEX_WEBHOOK_URL -u WEBEX_BOT_TOKEN -u WEBEX_ROOM_ID -u GITHUB_ACTIONS \
    PATH="$BIN:$PATH" STUB="$S" "$@" bash "$SCRIPTS_DIR/webex-notify.sh" "$msg" 2>&1)" || RC=$?
}
MSG='**WI-0032** -> `qa`: success "quoted" & done'

section "webex-notify.sh: no-op paths"
run_wx "$MSG"
assert_eq 0 "$RC" "NOTIFY_WEBEX unset: exits 0"
assert_contains "$OUT" "::notice::" "NOTIFY_WEBEX unset: notice"
assert_no_file "$S/url" "NOTIFY_WEBEX unset: nothing is sent"
run_wx "$MSG" NOTIFY_WEBEX=true
assert_eq 0 "$RC" "no destination: exits 0"
assert_no_file "$S/url" "no destination: nothing is sent"
run_wx "$MSG" NOTIFY_WEBEX=true WEBEX_BOT_TOKEN=fake-bot-token
assert_no_file "$S/url" "a bot token without a room id sends nothing"

section "webex-notify.sh: webhook"
echo 204 >"$S/code"
run_wx "$MSG" NOTIFY_WEBEX=true WEBEX_WEBHOOK_URL=https://webexapis.com/v1/webhooks/incoming/fake
assert_eq 0 "$RC" "webhook: exits 0"
assert_eq "https://webexapis.com/v1/webhooks/incoming/fake" "$(cat "$S/url")" "posts to the webhook"
assert_eq "$MSG" "$(json_get "$S/payload.json" 'd["markdown"]')" "the payload carries the markdown, JSON-escaped"
assert_eq "false" "$(json_get "$S/payload.json" '"roomId" in d')" "no roomId for a webhook"
assert_contains "$OUT" "Webex notification sent" "reports success"

section "webex-notify.sh: bot"
echo 200 >"$S/code"
run_wx "$MSG" NOTIFY_WEBEX=true WEBEX_BOT_TOKEN=fake-bot-token WEBEX_ROOM_ID=room-123
assert_eq 0 "$RC" "bot: exits 0"
assert_eq "https://webexapis.com/v1/messages" "$(cat "$S/url")" "posts to the messages API"
assert_eq "room-123" "$(json_get "$S/payload.json" 'd["roomId"]')" "roomId in the payload"
assert_eq "yes" "$(cat "$S/auth" 2>/dev/null)" "sends the bot token as a Bearer header"
assert_not_contains "$OUT" "fake-bot-token" "the bot token is not printed"

echo 500 >"$S/code"
run_wx "$MSG" NOTIFY_WEBEX=true WEBEX_BOT_TOKEN=fake-bot-token WEBEX_ROOM_ID=room-123
assert_eq 0 "$RC" "HTTP 500 never fails the job"
assert_contains "$OUT" "::warning::Webex notification failed" "HTTP 500 warns"

echo 000 >"$S/code"
run_wx "$MSG" NOTIFY_WEBEX=true WEBEX_WEBHOOK_URL=https://webexapis.com/v1/webhooks/incoming/fake
assert_eq 0 "$RC" "a network error never fails the job"
assert_contains "$OUT" "::warning::" "a network error warns"

RC=0
OUT="$(bash "$SCRIPTS_DIR/webex-notify.sh" 2>&1)" || RC=$?
assert_eq 2 "$RC" "no message argument is a usage error"

finish
