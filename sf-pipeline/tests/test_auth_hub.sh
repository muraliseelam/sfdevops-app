#!/usr/bin/env bash
# Tests for auth-hub.sh and auth-jwt.sh with a stub `sf` (no real org, fake key material).
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

T="$(new_tmp)"
BIN="$T/bin"
LOG="$T/sf.log"
write_stub "$BIN" sf <<'EOF'
#!/usr/bin/env bash
# Stub sf: records `sf org login jwt|sfdx-url` arguments (the secret file path, never its
# content) and what kind of secret the file held while sf ran.
if [[ "${1:-} ${2:-}" == "org login" && ( "${3:-}" == "jwt" || "${3:-}" == "sfdx-url" ) ]]; then
  echo "method: $3" >>"$STUB_LOG"
  shift 3
  secret=""
  args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jwt-key-file | --sfdx-url-file) secret="$2"; args+=("$1" "<file>"); shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  echo "args: ${args[*]}" >>"$STUB_LOG"
  echo "keyfile: $secret" >>"$STUB_LOG"
  if grep -q "BEGIN PRIVATE KEY" "$secret" 2>/dev/null; then echo "key: pem" >>"$STUB_LOG"; fi
  if grep -q "^force://" "$secret" 2>/dev/null; then echo "url: ok" >>"$STUB_LOG"; fi
  exit "${STUB_SF_EXIT:-0}"
fi
exit 0
EOF

FAKE_PEM=$'-----BEGIN PRIVATE KEY-----\nZmFrZS1rZXktZm9yLXRlc3RzLW9ubHk=\n-----END PRIVATE KEY-----\n'
FAKE_KEY_B64="$(printf '%s' "$FAKE_PEM" | base64 | tr -d '\n')"
FAKE_URL="force://PlatformCLI::5Aep861FakeRefreshTokenForTestsOnly@example.my.salesforce.com"
CLEAN=(env -u HUB_CONSUMER_KEY -u HUB_USERNAME -u HUB_INSTANCE_URL -u HUB_JWT_KEY -u HUB_AUTH_URL
  -u HUB_CALLBACK_STRICT -u SF_CONSUMER_KEY -u SF_USERNAME -u SF_INSTANCE_URL -u SF_JWT_KEY -u SF_AUTH_URL
  -u GITHUB_ACTIONS)

run_hub() { # run_hub [VAR=value ...] - runs auth-hub.sh, sets RC, OUT (stdout+stderr), OUTF
  OUTF="$T/out.$RANDOM"
  : >"$OUTF"
  : >"$LOG"
  RC=0
  OUT="$("${CLEAN[@]}" PATH="$BIN:$PATH" STUB_LOG="$LOG" GITHUB_OUTPUT="$OUTF" "$@" bash "$SCRIPTS_DIR/auth-hub.sh" 2>&1)" || RC=$?
}

section "auth-hub.sh: missing HUB_* secrets"
run_hub
assert_eq 0 "$RC" "no HUB_* secrets exits 0"
assert_eq false "$(out_get "$OUTF" hub_available)" "hub_available=false without secrets"
assert_contains "$OUT" "::notice::hub callbacks disabled: HUB_* secrets not set" "prints the notice"
assert_eq "" "$(cat "$LOG")" "sf is never called without secrets"

run_hub HUB_USERNAME=ci@example.com HUB_JWT_KEY="$FAKE_KEY_B64"
assert_eq 0 "$RC" "a partial set of HUB_* secrets exits 0"
assert_eq false "$(out_get "$OUTF" hub_available)" "hub_available=false with HUB_CONSUMER_KEY missing"
assert_contains "$OUT" "HUB_CONSUMER_KEY" "the notice names the missing secret"

section "auth-hub.sh: login"
run_hub HUB_CONSUMER_KEY=fake-consumer HUB_USERNAME=ci@example.com HUB_JWT_KEY="$FAKE_KEY_B64" \
  HUB_INSTANCE_URL=https://hub.example.invalid
assert_eq 0 "$RC" "successful login exits 0"
assert_eq true "$(out_get "$OUTF" hub_available)" "hub_available=true after login"
log="$(cat "$LOG")"
assert_contains "$log" "--alias hub" "logs in under alias hub"
assert_contains "$log" "--instance-url https://hub.example.invalid" "uses HUB_INSTANCE_URL"
assert_contains "$log" "--client-id fake-consumer" "uses HUB_CONSUMER_KEY"
assert_not_contains "$log" "--set-default" "the hub is never made the default org"
assert_contains "$log" "key: pem" "the decoded key file is a PEM key while sf runs"
keyfile="$(sed -n 's/^keyfile: //p' "$LOG")"
if [[ -n "$keyfile" ]]; then pass "sf received a key file path"; else fail "sf received a key file path"; fi
assert_no_file "$keyfile" "the key file is deleted afterwards"
assert_not_contains "$OUT" "ZmFrZS1rZXkt" "the key is never echoed"

run_hub HUB_CONSUMER_KEY=fake-consumer HUB_USERNAME=ci@example.com HUB_JWT_KEY="$FAKE_KEY_B64"
assert_contains "$(cat "$LOG")" "--instance-url https://login.salesforce.com" "HUB_INSTANCE_URL defaults to login.salesforce.com"

run_hub HUB_CONSUMER_KEY=fake-consumer HUB_USERNAME=ci@example.com HUB_JWT_KEY="$FAKE_KEY_B64" STUB_SF_EXIT=1
assert_eq 0 "$RC" "a failed login is a warning (exit 0)"
assert_eq false "$(out_get "$OUTF" hub_available)" "hub_available=false after a failed login"
assert_contains "$OUT" "::warning::" "a failed login warns"

run_hub HUB_CONSUMER_KEY=fake-consumer HUB_USERNAME=ci@example.com HUB_JWT_KEY="$FAKE_KEY_B64" STUB_SF_EXIT=1 \
  HUB_CALLBACK_STRICT=true
assert_eq 1 "$RC" "a failed login fails with HUB_CALLBACK_STRICT=true"

run_hub HUB_CONSUMER_KEY=fake-consumer HUB_USERNAME=ci@example.com HUB_JWT_KEY="not*base64!"
assert_eq false "$(out_get "$OUTF" hub_available)" "invalid base64 leaves the hub unavailable"
assert_contains "$OUT" "HUB_JWT_KEY is not valid base64" "names the bad secret"

section "auth-hub.sh: SFDX auth URL"
run_hub HUB_AUTH_URL="$FAKE_URL"
assert_eq 0 "$RC" "only HUB_AUTH_URL set: exits 0"
assert_eq true "$(out_get "$OUTF" hub_available)" "only HUB_AUTH_URL set: hub_available=true"
log="$(cat "$LOG")"
assert_contains "$log" "method: sfdx-url" "logs in with sf org login sfdx-url"
assert_contains "$log" "--sfdx-url-file <file> --alias hub" "passes the URL as a file, alias hub"
assert_not_contains "$log" "--set-default" "the hub is never made the default org"
assert_contains "$log" "url: ok" "the temp file holds the auth URL while sf runs"
urlfile="$(sed -n 's/^keyfile: //p' "$LOG")"
if [[ -n "$urlfile" ]]; then pass "sf received an auth URL file path"; else fail "sf received an auth URL file path"; fi
assert_no_file "$urlfile" "the auth URL file is deleted afterwards"
assert_not_contains "$OUT" "5Aep861FakeRefreshToken" "the auth URL is never echoed"

run_hub HUB_AUTH_URL="$FAKE_URL" HUB_CONSUMER_KEY=fake-consumer HUB_USERNAME=ci@example.com HUB_JWT_KEY="$FAKE_KEY_B64"
assert_contains "$(cat "$LOG")" "method: jwt" "JWT stays the first choice when its secrets are present"

run_hub HUB_AUTH_URL="$FAKE_URL" HUB_USERNAME=ci@example.com
assert_contains "$(cat "$LOG")" "method: sfdx-url" "a partial JWT set falls back to HUB_AUTH_URL"

run_hub HUB_AUTH_URL="$FAKE_URL" STUB_SF_EXIT=1
assert_eq 0 "$RC" "a failed auth URL login is a warning (exit 0)"
assert_eq false "$(out_get "$OUTF" hub_available)" "hub_available=false after a failed auth URL login"
assert_no_file "$(sed -n 's/^keyfile: //p' "$LOG")" "the auth URL file is deleted after a failed login"

run_hub HUB_AUTH_URL="https://not-an-auth-url.example.invalid"
assert_eq false "$(out_get "$OUTF" hub_available)" "a malformed HUB_AUTH_URL leaves the hub unavailable"
assert_contains "$OUT" "HUB_AUTH_URL does not look like an SFDX auth URL" "names the bad secret"
assert_not_contains "$OUT" "not-an-auth-url" "and does not echo it"
assert_eq "" "$(cat "$LOG")" "sf is not called with a malformed URL"

run_hub HUB_AUTH_URL=""
assert_eq 0 "$RC" "neither set (empty HUB_AUTH_URL): exits 0"
assert_eq false "$(out_get "$OUTF" hub_available)" "neither set: hub_available=false"
assert_contains "$OUT" "::notice::hub callbacks disabled: HUB_* secrets not set" "neither set: prints the notice"
assert_contains "$OUT" "HUB_AUTH_URL" "the notice names the auth URL option too"

section "auth-jwt.sh"
run_jwt() {
  OUTF="$T/out.$RANDOM"
  : >"$OUTF"
  : >"$LOG"
  RC=0
  OUT="$("${CLEAN[@]}" PATH="$BIN:$PATH" STUB_LOG="$LOG" GITHUB_OUTPUT="$OUTF" "$@" 2>&1)" || RC=$?
}
run_jwt bash "$SCRIPTS_DIR/auth-jwt.sh"
assert_eq 2 "$RC" "no alias is a usage error"

run_jwt SF_USERNAME=ci@example.com bash "$SCRIPTS_DIR/auth-jwt.sh" int
assert_eq 1 "$RC" "neither JWT nor auth URL secrets: fails"
assert_contains "$OUT" "SF_CONSUMER_KEY" "names SF_CONSUMER_KEY"
assert_contains "$OUT" "SF_JWT_KEY" "names SF_JWT_KEY"
assert_contains "$OUT" "SF_AUTH_URL" "names the SF_AUTH_URL alternative"
assert_contains "$OUT" "GitHub Environment" "points at the GitHub Environment secrets"
assert_eq "" "$(cat "$LOG")" "sf is never called without credentials"

run_jwt SF_CONSUMER_KEY=fake-consumer SF_USERNAME=ci@example.com SF_JWT_KEY="$FAKE_KEY_B64" \
  bash "$SCRIPTS_DIR/auth-jwt.sh" int
assert_eq 0 "$RC" "login succeeds with a stub sf"
log="$(cat "$LOG")"
assert_contains "$log" "--alias int --set-default" "sets the alias as the default org"
assert_contains "$log" "--instance-url https://login.salesforce.com" "instance URL defaults to login.salesforce.com"
assert_no_file "$(sed -n 's/^keyfile: //p' "$LOG")" "the key file is deleted afterwards"
assert_not_contains "$OUT" "ZmFrZS1rZXkt" "the key is never echoed"

run_jwt SF_CONSUMER_KEY=fake-consumer SF_USERNAME=ci@example.com SF_JWT_KEY="$FAKE_KEY_B64" STUB_SF_EXIT=1 \
  bash "$SCRIPTS_DIR/auth-jwt.sh" int
assert_eq 1 "$RC" "a failed login fails the step"
assert_no_file "$(sed -n 's/^keyfile: //p' "$LOG")" "the key file is deleted after a failed login"

section "auth-jwt.sh: SFDX auth URL"
run_jwt SF_AUTH_URL="$FAKE_URL" bash "$SCRIPTS_DIR/auth-jwt.sh" int
assert_eq 0 "$RC" "only SF_AUTH_URL set: login succeeds"
log="$(cat "$LOG")"
assert_contains "$log" "method: sfdx-url" "uses sf org login sfdx-url"
assert_contains "$log" "--sfdx-url-file <file> --alias int --set-default" "file, alias and default org"
assert_contains "$log" "url: ok" "the temp file holds the auth URL while sf runs"
assert_no_file "$(sed -n 's/^keyfile: //p' "$LOG")" "the auth URL file is deleted afterwards"
assert_not_contains "$OUT" "5Aep861FakeRefreshToken" "the auth URL is never echoed"

run_jwt SF_AUTH_URL="$FAKE_URL" SF_CONSUMER_KEY=fake-consumer SF_USERNAME=ci@example.com SF_JWT_KEY="$FAKE_KEY_B64" \
  bash "$SCRIPTS_DIR/auth-jwt.sh" int
assert_contains "$(cat "$LOG")" "method: jwt" "JWT stays the first choice when its secrets are present"

run_jwt SF_AUTH_URL="$FAKE_URL" SF_USERNAME=ci@example.com bash "$SCRIPTS_DIR/auth-jwt.sh" int
assert_contains "$(cat "$LOG")" "method: sfdx-url" "an incomplete JWT set falls back to SF_AUTH_URL"

run_jwt SF_AUTH_URL="$FAKE_URL" STUB_SF_EXIT=1 bash "$SCRIPTS_DIR/auth-jwt.sh" int
assert_eq 1 "$RC" "a failed auth URL login fails the step"
assert_no_file "$(sed -n 's/^keyfile: //p' "$LOG")" "the auth URL file is deleted after a failed login"

run_jwt SF_AUTH_URL="sfdx-url-without-scheme" bash "$SCRIPTS_DIR/auth-jwt.sh" int
assert_eq 1 "$RC" "a malformed SF_AUTH_URL fails"
assert_contains "$OUT" "SF_AUTH_URL does not look like an SFDX auth URL" "names the bad secret"

finish
