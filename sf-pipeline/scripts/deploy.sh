#!/usr/bin/env bash
# deploy.sh — start a validate / deploy / quick deploy asynchronously, wait for it, then write
# the authoritative `sf project deploy report --json` for its job id.
#
# The CLI's exit code is not the truth in either direction: a rolled-back deploy piped through
# `| tail` reads as success, and a deploy the org accepted in full can exit non-zero because
# the client lost the connection while polling. The deploy id is the durable thing, so this
# script always ends by asking the org for that id's final state. deploy_report.py then reads
# the JSON and decides.
#
# Environment:
#   ALIAS            target org alias (authenticated by auth-jwt.sh)
#   MODE             validate | deploy | quick
#   PACKAGE_XML      manifest (validate/deploy)
#   DESTRUCTIVE_XML  post-destructive manifest, or empty to skip deletions
#   TEST_LEVEL       NoTestRun | RunSpecifiedTests | RunLocalTests | RunAllTestsInOrg
#   TESTS            comma-separated test classes (RunSpecifiedTests)
#   QUICK_ID         validated deploy id (quick)
#   WAIT_MINUTES     how long to wait (default 90)
#   IGNORE_WARNINGS  true to pass --ignore-warnings
#   OUT_JSON         where to write the final report (default deploy-result.json)
# Outputs: deploy_id, started (true/false)

set -euo pipefail

: "${ALIAS:?ALIAS is required}"
: "${MODE:?MODE is required (validate|deploy|quick)}"
OUT_JSON="${OUT_JSON:-deploy-result.json}"
WAIT="${WAIT_MINUTES:-90}"
PY="$(command -v python3 || command -v python || command -v py)"

emit() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; fi
  printf '%s=%s\n' "$1" "$2"
}

json_field() {
  # json_field <file> <dotted.path...> — first non-empty value among the paths
  "$PY" - "$@" <<'PYEOF'
import json, sys
path, keys = sys.argv[1], sys.argv[2:]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    print(""); sys.exit(0)
for key in keys:
    cur = data
    for part in key.split("."):
        cur = cur.get(part) if isinstance(cur, dict) else None
    if cur not in (None, ""):
        print(cur); sys.exit(0)
print("")
PYEOF
}

start_json="$(mktemp)"
trap 'rm -f "$start_json"' EXIT

case "$MODE" in
  validate|deploy)
    [[ -f "${PACKAGE_XML:-}" ]] || { echo "::error::PACKAGE_XML not found: ${PACKAGE_XML:-<unset>}"; exit 1; }
    level="${TEST_LEVEL:-NoTestRun}"
    args=(--manifest "$PACKAGE_XML" --target-org "$ALIAS" --test-level "$level" --async --json)
    if [[ -n "${DESTRUCTIVE_XML:-}" && -f "$DESTRUCTIVE_XML" ]]; then
      args+=(--post-destructive-changes "$DESTRUCTIVE_XML")
    fi
    if [[ "$level" == "RunSpecifiedTests" ]]; then
      [[ -n "${TESTS:-}" ]] || { echo "::error::RunSpecifiedTests needs at least one test class"; exit 1; }
      for t in ${TESTS//,/ }; do args+=(--tests "$t"); done
    fi
    if [[ "${IGNORE_WARNINGS:-false}" == "true" ]]; then args+=(--ignore-warnings); fi
    echo "sf project deploy ${MODE/deploy/start} ${args[*]}"
    if [[ "$MODE" == "validate" ]]; then
      sf project deploy validate "${args[@]}" > "$start_json" 2>/dev/null || true
    else
      sf project deploy start --ignore-conflicts "${args[@]}" > "$start_json" 2>/dev/null || true
    fi
    ;;
  quick)
    : "${QUICK_ID:?QUICK_ID is required for MODE=quick}"
    echo "sf project deploy quick --job-id $QUICK_ID --target-org $ALIAS --async"
    sf project deploy quick --job-id "$QUICK_ID" --target-org "$ALIAS" --async --json > "$start_json" 2>/dev/null || true
    ;;
  *)
    echo "::error::unknown MODE '$MODE'"; exit 1 ;;
esac

id="$(json_field "$start_json" result.id result.jobId result.deployId)"
if [[ -z "$id" ]]; then
  cp "$start_json" "$OUT_JSON"
  emit started false
  emit deploy_id ""
  echo "::error::The deploy did not start. CLI response:"
  cat "$start_json"
  exit 1
fi
emit started true
emit deploy_id "$id"
echo "Deploy job ${id} started; waiting up to ${WAIT} minutes."

# Wait. The exit code here is deliberately ignored; the report below is the truth.
sf project deploy resume --job-id "$id" --wait "$WAIT" --json > /dev/null 2>&1 || true

for attempt in 1 2 3 4 5; do
  sf project deploy report --job-id "$id" --target-org "$ALIAS" --json > "$OUT_JSON" 2>/dev/null || true
  done_flag="$(json_field "$OUT_JSON" result.done)"
  status="$(json_field "$OUT_JSON" result.status)"
  if [[ "$done_flag" == "True" || "$done_flag" == "true" ]]; then
    echo "Deploy ${id} finished with status ${status}."
    exit 0
  fi
  echo "Deploy ${id} not finished yet (status '${status:-unknown}'); checking again."
  sleep $((attempt * 20))
done
echo "::warning::Deploy ${id} did not report done; deploy_report.py will treat it as not succeeded."
exit 0
