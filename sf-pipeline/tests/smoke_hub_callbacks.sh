#!/usr/bin/env bash
# smoke_hub_callbacks.sh <hub-org-alias> — live smoke test of integration contract #2.
#
# Creates one clearly labelled work item in the hub, then POSTs exactly the callback sequence a
# real change produces (through the same hub_payload.py + hub-callback.sh the workflows use):
#   Commit → Validation Running → Validation Success → entry-hop Deploy Running → Deploy Success
# and checks what the hub recorded: the commit and components, ONE validation row and ONE deploy
# row (the Running→Success pairs de-duplicate), the entry-hop promotion with its junction row,
# the work item moved to the entry stage, environment health, and audit events.
#
# It writes real records (labelled "[smoke]") into the hub; run it against a hub you test with.
# Needs: the org alias logged in to the sf CLI, a seeded hub (seed-pipeline.py).
set -euo pipefail

org="${1:?usage: smoke_hub_callbacks.sh <hub-org-alias>}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scripts="$here/../scripts"
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then PY="$c"; break; fi
done
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
check() { if [[ "$1" == "$2" ]]; then pass "$3 ($1)"; else fail "$3 (expected '$2', got '$1')"; fi; }
q() {  # q <soql> <python expression over `r` (records list)>
  sf data query --target-org "$org" --query "$1" --json | "$PY" -c "
import json, sys
r = (json.load(sys.stdin).get('result') or {}).get('records') or []
print($2)"
}

entry="$("$PY" "$scripts/plan.py" outputs | grep '^entry_name=' | cut -d= -f2 | tr -d '\r')"
project="$(q "SELECT Id FROM CDO_Project__c WHERE Active__c = true ORDER BY CreatedDate DESC, Id DESC LIMIT 1" "r[0]['Id'] if r else ''")"
[[ -n "$project" ]] || { echo "no project in the hub; run seed-pipeline.py first" >&2; exit 1; }
stamp="$(date -u +%Y%m%d%H%M%S)"
wid="$(sf data create record --target-org "$org" --sobject CDO_Work_Item__c \
  --values "Subject__c='[smoke] callback contract ${stamp}' Project__c='${project}' Source_Org_Alias__c='dev'" --json \
  | "$PY" -c "import json,sys; print(json.load(sys.stdin)['result']['id'])")"
wi="$(q "SELECT Name FROM CDO_Work_Item__c WHERE Id = '${wid}'" "r[0]['Name']")"
echo "Work item ${wi} (${wid}) in project ${project}; entry stage '${entry}'"

sha="$("$PY" -c "import hashlib; print(hashlib.sha1(b'${stamp}').hexdigest())")"
run_v="https://github.com/example/smoke/actions/runs/${stamp}1"
run_d="https://github.com/example/smoke/actions/runs/${stamp}2"
cat > "$work/components.json" <<EOF
[{"type":"ApexClass","name":"InvoiceService","action":"Modify","uniqueId":"ApexClass:InvoiceService","path":"force-app/main/default/classes/InvoiceService.cls","lastCommitDate":"2026-10-13T07:00:00Z","lastCommitSha":"${sha}"},
 {"type":"CustomField","name":"Invoice__c.Notes__c","action":"Add","uniqueId":"CustomField:Invoice__c.Notes__c","path":"force-app/main/default/objects/Invoice__c/fields/Notes__c.field-meta.xml","lastCommitDate":"2026-10-13T07:00:00Z","lastCommitSha":"${sha}"}]
EOF

post() {  # post <label> VAR=value ...
  local label="$1"; shift
  env "$@" "$PY" "$scripts/hub_payload.py" deploy > "$work/p.json"
  local out; out="$(HUB_ALIAS="$org" HUB_CALLBACK_STRICT=true bash "$scripts/hub-callback.sh" deploy-callback "$work/p.json" 2>&1)" \
    && pass "$label → $(grep -m1 '^HTTP status' <<<"$out")" || { fail "$label"; echo "$out"; }
}

post "Commit" WORK_ITEM="$wi" EVENT_TYPE=Commit STATUS=Success COMMIT_SHA="$sha" \
  COMPONENTS_JSON_FILE="$work/components.json" MESSAGE="[smoke] commit" RUN_URL="${run_v}0"
post "Validation Running" WORK_ITEM="$wi" EVENT_TYPE=Validation STATUS=Running CHECK_ONLY=true \
  ENVIRONMENT="$entry" COMMIT_SHA="$sha" RUN_URL="$run_v"
post "Validation Success" WORK_ITEM="$wi" EVENT_TYPE=Validation STATUS=Success CHECK_ONLY=true \
  ENVIRONMENT="$entry" COMMIT_SHA="$sha" RUN_URL="$run_v" COVERAGE_PERCENT=92.5 TESTS_PASSED=true \
  DEPLOY_ID=0Af000000000001AAA TEST_LEVEL=RunSpecifiedTests
post "Deploy Running (entry hop)" WORK_ITEM="$wi" EVENT_TYPE=Deploy STATUS=Running \
  ENVIRONMENT="$entry" COMMIT_SHA="$sha" RUN_URL="$run_d"
post "Deploy Success (entry hop)" WORK_ITEM="$wi" EVENT_TYPE=Deploy STATUS=Success \
  ENVIRONMENT="$entry" COMMIT_SHA="$sha" RUN_URL="$run_d" COVERAGE_PERCENT=92.5 TESTS_PASSED=true \
  DEPLOY_ID=0Af000000000002AAA PROMOTION_BRANCH="promotion/${wi}-to-${entry}"

echo "--- what the hub recorded"
check "$(q "SELECT COUNT(Id) n FROM CDO_Commit__c WHERE Work_Item__c = '${wid}'" "r[0]['n']")" "1" "one CDO_Commit__c"
check "$(q "SELECT COUNT(Id) n FROM CDO_Component__c WHERE Work_Item__c = '${wid}'" "r[0]['n']")" "2" "two CDO_Component__c"
check "$(q "SELECT COUNT(Id) n FROM CDO_Deployment__c WHERE Work_Item__c = '${wid}' AND Check_Only__c = true" "r[0]['n']")" "1" "ONE validation row for the Running→Success pair"
check "$(q "SELECT COUNT(Id) n FROM CDO_Deployment__c WHERE Work_Item__c = '${wid}' AND Check_Only__c = false" "r[0]['n']")" "1" "ONE deploy row for the Running→Success pair"
check "$(q "SELECT Status__c FROM CDO_Deployment__c WHERE Work_Item__c = '${wid}' AND Check_Only__c = false" "r[0]['Status__c'] if r else ''")" "Success" "deploy row is Success"
check "$(q "SELECT COUNT(Id) n FROM CDO_Promoted_Work_Item__c WHERE Work_Item__c = '${wid}'" "r[0]['n']")" "1" "entry-hop junction row written"
check "$(q "SELECT Promotion__r.Status__c FROM CDO_Promoted_Work_Item__c WHERE Work_Item__c = '${wid}'" "r[0]['Promotion__r']['Status__c'] if r else ''")" "Deployed" "entry-hop promotion Deployed"
check "$(q "SELECT Current_Stage__r.Pipeline_Key__c FROM CDO_Work_Item__c WHERE Id = '${wid}'" "r[0]['Current_Stage__r']['Pipeline_Key__c'] if r and r[0].get('Current_Stage__r') else ''")" "$entry" "work item moved to the entry stage"
check "$(q "SELECT Health_Status__c FROM CDO_Environment__c WHERE Pipeline_Key__c = '${entry}'" "r[0]['Health_Status__c'] if r else ''")" "Healthy" "entry environment Healthy"
n_audit="$(q "SELECT COUNT(Id) n FROM CDO_Audit_Event__c WHERE Work_Item__c = '${wid}'" "r[0]['n']")"
if [[ "$n_audit" -ge 5 ]]; then pass "audit events written (${n_audit})"; else fail "audit events (got ${n_audit}, expected >= 5)"; fi

echo
[[ "$fails" -eq 0 ]] && echo "Hub callback smoke test passed for ${wi}" || { echo "${fails} check(s) failed"; exit 1; }
