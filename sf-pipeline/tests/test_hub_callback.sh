#!/usr/bin/env bash
# Tests for hub-callback.sh and hub-workitem-callback.sh with a stub `sf`.
# Callbacks go through `sf api request rest`, so no access token is ever read or printed.
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

T="$(new_tmp)"
BIN="$T/bin"
STUB_DIR="$T/stub"
mkdir -p "$STUB_DIR"

write_stub "$BIN" sf <<'EOF'
#!/usr/bin/env bash
# Stub sf: `org display` answers the auth check; `api request rest` answers with the next HTTP
# code listed in $STUB_DIR/codes, records each call, and keeps a copy of the posted body.
if [[ "${1:-} ${2:-}" == "org display" ]]; then
  echo "org display $*" >>"$STUB_DIR/calls"
  if [[ "${STUB_HUB_AUTHED:-true}" != "true" ]]; then
    echo '{"status":1,"name":"NamedOrgNotFoundError","message":"No authorization information found for hub."}'
    exit 1
  fi
  echo '{"status":0,"result":{"accessToken":"[REDACTED]","instanceUrl":"https://hub.example.invalid","username":"ci@example.com"}}'
  exit 0
fi
if [[ "${1:-} ${2:-} ${3:-}" == "api request rest" ]]; then
  shift 3
  path="" body="" org=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method | -X) echo "method: $2" >>"$STUB_DIR/calls"; shift 2 ;;
      --header | -H) echo "header: $2" >>"$STUB_DIR/calls"; shift 2 ;;
      --body | -b) body="${2#@}"; shift 2 ;;
      --target-org | -o) org="$2"; shift 2 ;;
      --include | -i) shift ;;
      -*) shift ;;
      *) path="$1"; shift ;;
    esac
  done
  n=$(($(cat "$STUB_DIR/count" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$STUB_DIR/count"
  code="$(sed -n "${n}p" "$STUB_DIR/codes")"
  [[ -n "$code" ]] || code="$(tail -n 1 "$STUB_DIR/codes")"
  echo "path: $path org: $org" >>"$STUB_DIR/calls"
  [[ -n "$body" && -f "$body" ]] && cp "$body" "$STUB_DIR/last-body.json"
  if [[ "$code" == "000" ]]; then
    echo "Error (1): getaddrinfo ENOTFOUND hub.example.invalid"
    exit 1
  fi
  printf 'HTTP/1.1 %s\r\ncontent-type: application/json\r\nx-request-id: abc\r\n{"success":true,"deploymentId":"a0Bfake","code":"%s"}\r\n' "$code" "$code"
  exit 0
fi
exit 0
EOF

BODY="$T/body.json"
echo '{"workItem":"WI-0001","status":"Running","eventType":"Deploy"}' >"$BODY"
CLEAN=(env -u HUB_CALLBACK_STRICT -u GITHUB_ACTIONS -u HUB_ALIAS -u GITHUB_SERVER_URL -u GITHUB_REPOSITORY -u GITHUB_RUN_ID)

run_cb() { # run_cb "<codes>" [VAR=value ...] -- args...
  local codes="$1"
  shift
  printf '%s\n' $codes >"$STUB_DIR/codes"
  rm -f "$STUB_DIR/count" "$STUB_DIR/calls" "$STUB_DIR/last-body.json"
  touch "$STUB_DIR/calls"
  OUTF="$T/out.$RANDOM"
  : >"$OUTF"
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  RC=0
  OUT="$("${CLEAN[@]}" PATH="$BIN:$PATH" STUB_DIR="$STUB_DIR" GITHUB_OUTPUT="$OUTF" HUB_CALLBACK_BACKOFF=0 \
    "${envs[@]}" bash "$@" 2>&1)" || RC=$?
  CALLS="$(cat "$STUB_DIR/calls")"
  ATTEMPTS="$(cat "$STUB_DIR/count" 2>/dev/null || echo 0)"
}

section "hub-callback.sh: usage and skip paths"
run_cb "200" -- "$SCRIPTS_DIR/hub-callback.sh" nope "$BODY"
assert_eq 2 "$RC" "an unknown endpoint is a usage error"
run_cb "200" -- "$SCRIPTS_DIR/hub-callback.sh" deploy-callback
assert_eq 2 "$RC" "a missing json file argument is a usage error"
run_cb "200" STUB_HUB_AUTHED=false -- "$SCRIPTS_DIR/hub-callback.sh" deploy-callback "$BODY"
assert_eq 0 "$RC" "an unauthenticated hub exits 0"
assert_contains "$OUT" "::notice::" "and prints a notice"
assert_eq 0 "$ATTEMPTS" "and never posts"

section "hub-callback.sh: delivery"
run_cb "200" -- "$SCRIPTS_DIR/hub-callback.sh" deploy-callback "$BODY"
assert_eq 0 "$RC" "HTTP 200 exits 0"
assert_eq 200 "$(out_get "$OUTF" http_status)" "http_status=200"
assert_contains "$CALLS" "path: services/apexrest/cdo/deploy-callback org: hub" "posts to the Apex REST endpoint through the hub alias"
assert_contains "$CALLS" "method: POST" "uses POST"
assert_contains "$CALLS" "header: Content-Type:application/json" "sends Content-Type application/json"
assert_not_contains "$CALLS" "--verbose" "never asks the CLI for a session token"
assert_eq "$(cat "$BODY")" "$(cat "$STUB_DIR/last-body.json")" "posts the file unchanged"
assert_contains "$OUT" "HTTP status: 200" "prints the HTTP status"
assert_contains "$OUT" '"deploymentId":"a0Bfake"' "prints the response body"
assert_not_contains "$OUT" "REDACTED" "no session detail reaches the log"

run_cb "200" HUB_ALIAS=myhub -- "$SCRIPTS_DIR/hub-callback.sh" merge-status "$BODY"
assert_contains "$CALLS" "path: services/apexrest/cdo/merge-status org: myhub" "merge-status endpoint, HUB_ALIAS honoured"

run_cb "503 502 200" -- "$SCRIPTS_DIR/hub-callback.sh" source-members "$BODY"
assert_eq 0 "$RC" "5xx then 200 succeeds"
assert_eq 3 "$ATTEMPTS" "retries after each 5xx"

run_cb "000 000 000 000 000" -- "$SCRIPTS_DIR/hub-callback.sh" deploy-callback "$BODY"
assert_eq 0 "$RC" "a hub that cannot be reached is a warning (exit 0)"
assert_eq 4 "$ATTEMPTS" "1 attempt + 3 retries on connection errors"
assert_contains "$OUT" "::warning::" "warns when the hub cannot be reached"

run_cb "400 200" -- "$SCRIPTS_DIR/hub-callback.sh" deploy-callback "$BODY"
assert_eq 0 "$RC" "HTTP 400 is a warning (exit 0)"
assert_eq 1 "$ATTEMPTS" "4xx is not retried"
assert_contains "$OUT" "::warning::hub callback 'deploy-callback' returned HTTP 400" "warns with the status"
assert_eq 400 "$(out_get "$OUTF" http_status)" "http_status=400"

run_cb "400" HUB_CALLBACK_STRICT=true -- "$SCRIPTS_DIR/hub-callback.sh" deploy-callback "$BODY"
assert_eq 1 "$RC" "HUB_CALLBACK_STRICT=true turns a non-2xx into a failure"

echo 'not json' >"$T/bad.json"
run_cb "200" -- "$SCRIPTS_DIR/hub-callback.sh" deploy-callback "$T/bad.json"
assert_eq 0 "$RC" "an invalid JSON body is a warning"
assert_eq 0 "$ATTEMPTS" "an invalid JSON body is never posted"

section "hub-workitem-callback.sh"
COMP="$T/components.json"
echo '[{"type":"ApexClass","name":"Foo","action":"Modify","uniqueId":"ApexClass:Foo"}]' >"$COMP"
PAYLOAD="$T/payload.json"
run_cb "200" WORK_ITEM=WI-0032 EVENT_TYPE=Validation STATUS=Success ENVIRONMENT=int \
  COVERAGE_PERCENT=87.5 TESTS_PASSED=true CHECK_ONLY=false PULL_REQUEST_NUMBER=12 COMPONENT_COUNT=3 \
  PULL_REQUESTS_APPROVED=yes FAILING_METHODS=$'A.one: boom\nB.two: bang' MESSAGE="" DEPLOY_ID=0Af000000000001 \
  COMPONENTS_JSON_FILE="$COMP" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=acme/sf GITHUB_RUN_ID=99 \
  CALLBACK_OUT="$PAYLOAD" -- "$SCRIPTS_DIR/hub-workitem-callback.sh"
assert_eq 0 "$RC" "posts and exits 0"
assert_file "$PAYLOAD" "writes the payload to CALLBACK_OUT"
assert_eq WI-0032 "$(json_get "$PAYLOAD" 'd["workItem"]')" "workItem"
assert_eq Validation "$(json_get "$PAYLOAD" 'd["eventType"]')" "eventType"
assert_eq "87.5" "$(json_get "$PAYLOAD" 'd["coveragePercent"]')" "coveragePercent is a number"
assert_eq "float" "$(json_get "$PAYLOAD" 'type(d["coveragePercent"]).__name__')" "coveragePercent has a JSON number type"
assert_eq "int" "$(json_get "$PAYLOAD" 'type(d["pullRequestNumber"]).__name__')" "pullRequestNumber is an integer"
assert_eq "3" "$(json_get "$PAYLOAD" 'd["componentCount"]')" "componentCount"
assert_eq "true" "$(json_get "$PAYLOAD" 'd["testsPassed"]')" "testsPassed is a boolean"
assert_eq "false" "$(json_get "$PAYLOAD" 'd["checkOnly"]')" "checkOnly false is kept"
assert_eq "true" "$(json_get "$PAYLOAD" 'd["pullRequestsApproved"]')" "yes is read as true"
assert_eq "false" "$(json_get "$PAYLOAD" '"promotionId" in d')" "no promotionId (work-item scoped)"
assert_eq "false" "$(json_get "$PAYLOAD" '"message" in d')" "empty fields are omitted"
assert_eq "A.one: boom|B.two: bang" "$(json_get "$PAYLOAD" '"|".join(d["failingMethods"].splitlines())')" "multi-line failingMethods keeps its lines"
assert_eq "ApexClass:Foo" "$(json_get "$PAYLOAD" 'd["components"][0]["uniqueId"]')" "components array is embedded"
assert_eq "https://github.com/acme/sf/actions/runs/99" "$(json_get "$PAYLOAD" 'd["runUrl"]')" "runUrl defaults to this run"
assert_contains "$CALLS" "services/apexrest/cdo/deploy-callback" "posts to deploy-callback"
assert_eq "$(cat "$PAYLOAD")" "$(cat "$STUB_DIR/last-body.json")" "the posted body is the payload"

run_cb "200" WORK_ITEM=WI-1 EVENT_TYPE=Deploy COVERAGE_PERCENT=abc RUN_URL=https://example.invalid/run/1 \
  CALLBACK_OUT="$PAYLOAD" -- "$SCRIPTS_DIR/hub-workitem-callback.sh"
assert_eq 0 "$RC" "a bad number does not fail the callback"
assert_contains "$OUT" "::warning::COVERAGE_PERCENT='abc' is not a number" "warns about the bad number"
assert_eq "false" "$(json_get "$PAYLOAD" '"coveragePercent" in d')" "the bad number is omitted"
assert_eq "https://example.invalid/run/1" "$(json_get "$PAYLOAD" 'd["runUrl"]')" "an explicit RUN_URL wins"

run_cb "200" EVENT_TYPE=Deploy -- "$SCRIPTS_DIR/hub-workitem-callback.sh"
assert_eq 2 "$RC" "WORK_ITEM is required"

run_cb "200" WORK_ITEM=WI-1 EVENT_TYPE=Deploy STUB_HUB_AUTHED=false CALLBACK_OUT="$PAYLOAD" -- \
  "$SCRIPTS_DIR/hub-workitem-callback.sh"
assert_eq 0 "$RC" "without a hub the work item callback exits 0"
assert_eq 0 "$ATTEMPTS" "and posts nothing"

finish
