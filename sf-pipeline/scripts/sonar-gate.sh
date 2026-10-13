#!/usr/bin/env bash
# sonar-gate.sh - wait for the SonarQube quality gate and fail when it is ERROR.
#
# Env
#   SONAR_TOKEN, SONAR_HOST_URL  when either is empty the gate is skipped with a warning
#   SONAR_PROJECT_KEY            project key (read from the report task file when blank)
#   SONAR_TIMEOUT                seconds to wait (default 300)
#   SONAR_POLL_INTERVAL          seconds between polls (default 5)
#   SONAR_REPORT_TASK            scanner report file (default .scannerwork/report-task.txt)
#
# When the scanner's report-task.txt exists, the script first waits for that analysis (the
# compute-engine task) to finish and then reads the gate of THAT analysis, so it never reports
# the previous analysis's gate. Otherwise it polls
#   $SONAR_HOST_URL/api/qualitygates/project_status?projectKey=$SONAR_PROJECT_KEY
# until the status is OK, WARN or ERROR. The token is sent as a Bearer header from a private
# file and masked. Output: sonar_status (OK | WARN | ERROR | NONE | TIMEOUT | SKIPPED).
# Exit codes: 0 gate passed or skipped, 1 gate ERROR, timeout or API failure.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

if [[ -z "${SONAR_TOKEN:-}" || -z "${SONAR_HOST_URL:-}" ]]; then
  warn "SonarQube gate skipped: SONAR_TOKEN/SONAR_HOST_URL not set"
  gh_output sonar_status SKIPPED
  exit 0
fi

timeout_s="${SONAR_TIMEOUT:-300}"
interval="${SONAR_POLL_INTERVAL:-5}"
report_task="${SONAR_REPORT_TASK:-.scannerwork/report-task.txt}"
[[ "$timeout_s" =~ ^[0-9]+$ ]] || die "SONAR_TIMEOUT must be a whole number of seconds"
[[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || die "SONAR_POLL_INTERVAL must be a positive whole number"
host="${SONAR_HOST_URL%/}"
project_key="${SONAR_PROJECT_KEY:-}"

require_cmd curl
PY="$(find_python)" || die "python3 (3.10+) is required to read SonarQube responses"
mask "$SONAR_TOKEN"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
hdr="$workdir/headers"
(umask 077 && printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN" >"$hdr")
body="$workdir/body"

# api_get PATH_AND_QUERY - GET into $body; prints the HTTP status (000 on a connection error).
api_get() {
  local code
  code="$(curl -sS -o "$body" -w '%{http_code}' --connect-timeout 15 --max-time 60 \
    -H @"$hdr" -H 'Accept: application/json' "$host$1" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# json_get EXPR - evaluate a key path such as projectStatus.status against $body.
json_get() {
  "$PY" - "$body" "$1" <<'PY' | tr -d '\r'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        value = json.load(fh)
except (OSError, ValueError):
    value = None
for part in sys.argv[2].split("."):
    value = value.get(part) if isinstance(value, dict) else None
print("" if value is None else value)
PY
}

deadline=$((SECONDS + timeout_s))
status_query=""

# 1. Wait for this analysis to be processed, when the scanner left its report task behind.
if [[ -f "$report_task" ]]; then
  ce_task_id="$(sed -n 's/^ceTaskId=//p' "$report_task" | tr -d '\r' | head -n 1)"
  [[ -n "$project_key" ]] || project_key="$(sed -n 's/^projectKey=//p' "$report_task" | tr -d '\r' | head -n 1)"
  if [[ -n "$ce_task_id" ]]; then
    echo "Waiting for SonarQube analysis task $ce_task_id"
    while :; do
      code="$(api_get "/api/ce/task?id=$ce_task_id")"
      if [[ "$code" == "401" || "$code" == "403" ]]; then
        die "SonarQube returned HTTP $code for the analysis task: check SONAR_TOKEN and its permissions"
      fi
      task_status=""
      [[ "$code" == "200" ]] && task_status="$(json_get task.status)"
      case "$task_status" in
        SUCCESS)
          analysis_id="$(json_get task.analysisId)"
          [[ -n "$analysis_id" ]] && status_query="analysisId=$analysis_id"
          break
          ;;
        FAILED | CANCELED)
          gh_output sonar_status ERROR
          die "SonarQube analysis task $ce_task_id ended $task_status"
          ;;
      esac
      if ((SECONDS >= deadline)); then
        gh_output sonar_status TIMEOUT
        die "SonarQube analysis was not processed within ${timeout_s}s (last task status: ${task_status:-HTTP $code})"
      fi
      sleep "$interval"
    done
  fi
fi

if [[ -z "$status_query" ]]; then
  [[ -n "$project_key" ]] || die "SONAR_PROJECT_KEY is required (no report task file at $report_task)"
  status_query="projectKey=$project_key"
fi

# 2. Read the quality gate.
echo "Polling $host/api/qualitygates/project_status?$status_query"
gate=""
while :; do
  code="$(api_get "/api/qualitygates/project_status?$status_query")"
  case "$code" in
    200) gate="$(json_get projectStatus.status)" ;;
    401 | 403) die "SonarQube returned HTTP $code: check SONAR_TOKEN and its Browse permission on the project" ;;
    404) die "SonarQube returned HTTP 404: project '${project_key:-?}' or the analysis was not found" ;;
    *) gate="" ;;
  esac
  case "$gate" in
    OK | WARN | ERROR) break ;;
  esac
  if ((SECONDS >= deadline)); then
    gh_output sonar_status TIMEOUT
    die "SonarQube quality gate not available within ${timeout_s}s (last: ${gate:-HTTP $code})"
  fi
  sleep "$interval"
done

gh_output sonar_status "$gate"
if [[ "$gate" == "ERROR" ]]; then
  failed="$("$PY" - "$body" <<'PY' | tr -d '\r'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        conditions = json.load(fh).get("projectStatus", {}).get("conditions", [])
except (OSError, ValueError, AttributeError):
    conditions = []
for c in conditions:
    if c.get("status") == "ERROR":
        print(f"{c.get('metricKey')}: {c.get('actualValue')} (threshold {c.get('comparator', '')} {c.get('errorThreshold')})")
PY
)"
  [[ -n "$failed" ]] && printf 'Failed conditions:\n%s\n' "$failed"
  die "SonarQube quality gate failed (ERROR)"
fi
echo "SonarQube quality gate: $gate"
