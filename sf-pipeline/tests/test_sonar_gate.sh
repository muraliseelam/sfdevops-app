#!/usr/bin/env bash
# Tests for sonar-gate.sh with a stub `curl` that answers SonarQube API calls from files.
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

T="$(new_tmp)"
BIN="$T/bin"
S="$T/stub"
mkdir -p "$S"
FAKE_TOKEN="squ_fake_token_for_tests"
write_stub "$BIN" curl <<'EOF'
#!/usr/bin/env bash
# Stub curl: routes by URL to $STUB/ce.json or $STUB/gate.json; HTTP code from $STUB/code.
out="" url=""
hdrs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w | --connect-timeout | --max-time | -X) shift 2 ;;
    -H) [[ "$2" == @* ]] && hdrs+=("${2#@}"); shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >>"$STUB/urls"
for f in "${hdrs[@]}"; do
  grep -q '^Authorization: Bearer squ_fake_token_for_tests$' "$f" && echo "bearer-ok" >>"$STUB/auth"
done
case "$url" in
  */api/ce/task*) cp "$STUB/ce.json" "$out" ;;
  *project_status*) cp "$STUB/gate.json" "$out" ;;
esac
printf '%s' "$(cat "$STUB/code" 2>/dev/null || echo 200)"
EOF

run_gate() { # run_gate [VAR=value ...]
  rm -f "$S/urls" "$S/auth"
  OUTF="$T/out.$RANDOM"
  : >"$OUTF"
  RC=0
  OUT="$(cd "$T" && env -u SONAR_TOKEN -u SONAR_HOST_URL -u SONAR_PROJECT_KEY -u GITHUB_ACTIONS \
    PATH="$BIN:$PATH" STUB="$S" GITHUB_OUTPUT="$OUTF" SONAR_POLL_INTERVAL=1 "$@" \
    bash "$SCRIPTS_DIR/sonar-gate.sh" 2>&1)" || RC=$?
}
gate_json() { printf '{"projectStatus":{"status":"%s","conditions":[{"status":"ERROR","metricKey":"new_coverage","comparator":"LT","errorThreshold":"80","actualValue":"41.0"}]}}' "$1" >"$S/gate.json"; }
CFG=(SONAR_TOKEN="$FAKE_TOKEN" SONAR_HOST_URL=https://sonar.example.invalid/ SONAR_PROJECT_KEY=acme_sf)

section "sonar-gate.sh: skipped"
run_gate
assert_eq 0 "$RC" "no token: exits 0"
assert_contains "$OUT" "::warning::SonarQube gate skipped: SONAR_TOKEN/SONAR_HOST_URL not set" "prints the skip warning"
assert_eq SKIPPED "$(out_get "$OUTF" sonar_status)" "sonar_status=SKIPPED"
run_gate SONAR_TOKEN="$FAKE_TOKEN"
assert_eq 0 "$RC" "no host URL: exits 0"

section "sonar-gate.sh: project status"
echo 200 >"$S/code"
gate_json OK
run_gate "${CFG[@]}"
assert_eq 0 "$RC" "OK passes"
assert_eq OK "$(out_get "$OUTF" sonar_status)" "sonar_status=OK"
assert_contains "$(cat "$S/urls")" "https://sonar.example.invalid/api/qualitygates/project_status?projectKey=acme_sf" "polls project_status by project key"
assert_contains "$(cat "$S/auth" 2>/dev/null)" "bearer-ok" "sends the token as a Bearer header"
assert_not_contains "$OUT" "$FAKE_TOKEN" "the token is not printed outside Actions"

gate_json WARN
run_gate "${CFG[@]}"
assert_eq 0 "$RC" "WARN passes"
assert_eq WARN "$(out_get "$OUTF" sonar_status)" "sonar_status=WARN"

gate_json ERROR
run_gate "${CFG[@]}"
assert_eq 1 "$RC" "ERROR fails"
assert_eq ERROR "$(out_get "$OUTF" sonar_status)" "sonar_status=ERROR"
assert_contains "$OUT" "new_coverage: 41.0" "prints the failed condition"

gate_json NONE
run_gate "${CFG[@]}" SONAR_TIMEOUT=0
assert_eq 1 "$RC" "no gate within the timeout fails"
assert_eq TIMEOUT "$(out_get "$OUTF" sonar_status)" "sonar_status=TIMEOUT"

echo 401 >"$S/code"
run_gate "${CFG[@]}"
assert_eq 1 "$RC" "HTTP 401 fails"
assert_contains "$OUT" "check SONAR_TOKEN" "explains the 401"
echo 200 >"$S/code"

gate_json OK
run_gate SONAR_TOKEN="$FAKE_TOKEN" SONAR_HOST_URL=https://sonar.example.invalid GITHUB_ACTIONS=true SONAR_PROJECT_KEY=acme_sf \
  SONAR_TIMEOUT=5
assert_contains "$OUT" "::add-mask::$FAKE_TOKEN" "inside Actions the token is masked"

section "sonar-gate.sh: analysis task from report-task.txt"
mkdir -p "$T/.scannerwork"
printf 'projectKey=from_report\nserverUrl=https://sonar.example.invalid\nceTaskId=AYTASK1\n' >"$T/.scannerwork/report-task.txt"
echo '{"task":{"id":"AYTASK1","status":"SUCCESS","analysisId":"AYANALYSIS9"}}' >"$S/ce.json"
gate_json OK
run_gate SONAR_TOKEN="$FAKE_TOKEN" SONAR_HOST_URL=https://sonar.example.invalid
assert_eq 0 "$RC" "waits for the analysis task, then reads its gate"
urls="$(cat "$S/urls")"
assert_contains "$urls" "/api/ce/task?id=AYTASK1" "polls the compute-engine task"
assert_contains "$urls" "project_status?analysisId=AYANALYSIS9" "reads the gate of that analysis"

echo '{"task":{"id":"AYTASK1","status":"FAILED"}}' >"$S/ce.json"
run_gate SONAR_TOKEN="$FAKE_TOKEN" SONAR_HOST_URL=https://sonar.example.invalid
assert_eq 1 "$RC" "a failed analysis task fails"
rm -rf "$T/.scannerwork"

run_gate SONAR_TOKEN="$FAKE_TOKEN" SONAR_HOST_URL=https://sonar.example.invalid
assert_eq 1 "$RC" "no project key and no report task is an error"
assert_contains "$OUT" "SONAR_PROJECT_KEY is required" "names SONAR_PROJECT_KEY"

finish
