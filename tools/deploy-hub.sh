#!/usr/bin/env bash
# deploy-hub.sh <org-alias> [--tests]
#
# Deploy the SF DevOps hub app to an org from source, in the only order that works
# (see tools/README.md "Deploy order"), checking every step by its deploy id rather than by
# the CLI's exit code. With --tests the Apex step runs the hub's test classes
# (RunSpecifiedTests); production orgs always need that.
#
# Scheduled Apex blocks redeploying every class it references ("This schedulable class has jobs
# pending or in progress"). Rather than switch on the org-wide "allow deployments with Apex jobs"
# setting, this pauses the promotion reconciler for the deploy and reschedules it afterwards.
#
# Run from the root of a checkout of branch platform/sfdevops-app, with the org logged in to the
# sf CLI. Afterwards: grant access (sf-pipeline/scripts/grant-app-access.sh) and seed the pipeline
# records (sf-pipeline/scripts/seed-pipeline.py) from the pipeline branch.
set -euo pipefail

org="${1:?usage: deploy-hub.sh <org-alias> [--tests]}"
run_tests=false
[[ "${2:-}" == "--tests" ]] && run_tests=true
D=sfdevops-app/main/default
RECONCILER="SF DevOps reconciler"
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then PY="$c"; break; fi
done
[[ -n "$PY" ]] || { echo "no working Python found" >&2; exit 1; }
[[ -d "$D/objects" ]] || { echo "run this from the root of the platform/sfdevops-app checkout" >&2; exit 1; }

TESTS=(CDO_Tests CDO_PromotionReconcilerTest CDOWorkItemCommandCenterTest StoryBoardControllerTest CDO_ControllerTests)

step() {  # step <label> <deploy args...>
  local label="$1"; shift
  local out; out="$(mktemp)"
  echo "==> ${label}"
  sf project deploy start --target-org "$org" --wait 60 --json "$@" > "$out" 2>/dev/null || true
  "$PY" - "$out" "$label" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
r = data.get("result") or {}
status = r.get("status") or "Failed"
print(f"    {sys.argv[2]}: {status} (deploy {r.get('id')}, {r.get('numberComponentsDeployed')} components, tests {r.get('numberTestsCompleted')}/{r.get('numberTestsTotal')})")
details = r.get("details") or {}
fails = details.get("componentFailures") or []
for f in fails if isinstance(fails, list) else [fails]:
    print(f"    ! {f.get('componentType')} {f.get('fullName')}: {f.get('problem')}")
tf = (details.get("runTestResult") or {}).get("failures") or []
for f in tf if isinstance(tf, list) else [tf]:
    print(f"    ! test {f.get('name')}.{f.get('methodName')}: {f.get('message')}")
if status != "Succeeded":
    if not r:
        print("    " + str(data.get("message", ""))[:500])
    sys.exit(1)
PY
  rm -f "$out"
}

apex() {  # apex <file>: run anonymous Apex, fail on a compile or runtime error
  sf apex run --file "$1" --target-org "$org" --json | "$PY" -c '
import json, sys
r = json.load(sys.stdin).get("result") or {}
if not r.get("success"):
    print(r.get("compileProblem") or r.get("exceptionMessage"))
    sys.exit(1)
'
}

work="$(mktemp -d)"
cat > "$work/pause.apex" <<APEX
for (CronTrigger ct : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE '${RECONCILER}%']) {
    System.abortJob(ct.Id);
}
APEX
cat > "$work/resume.apex" <<APEX
for (Integer m : new List<Integer>{ 0, 15, 30, 45 }) {
    System.schedule('${RECONCILER} :' + String.valueOf(m).leftPad(2, '0'), '0 ' + m + ' * * * ?',
        new CDO_PromotionReconciler.ReconcileJob());
}
APEX

paused="$(sf data query --target-org "$org" --json \
  --query "SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE '${RECONCILER}%'" 2>/dev/null \
  | "$PY" -c "import json,sys; print((json.load(sys.stdin).get('result') or {}).get('totalSize', 0))" 2>/dev/null || echo 0)"
resume() {
  if [[ "${paused:-0}" != "0" ]]; then
    echo "==> rescheduling the promotion reconciler"
    apex "$work/resume.apex" || echo "    ! could not reschedule; run seed-pipeline.py to schedule it again"
  fi
  rm -rf "$work"
}
trap resume EXIT
if [[ "${paused:-0}" != "0" ]]; then
  echo "==> pausing the promotion reconciler (${paused} scheduled job(s)) for the deploy"
  apex "$work/pause.apex"
fi

step "1/10 objects, custom setting, custom permissions, credentials" \
  --source-dir "$D/objects" --source-dir "$D/customPermissions" \
  --source-dir "$D/externalCredentials" --source-dir "$D/namedCredentials"
if $run_tests; then
  targs=(--test-level RunSpecifiedTests); for t in "${TESTS[@]}"; do targs+=(--tests "$t"); done
  step "2/10 Apex classes (with tests)" --source-dir "$D/classes" "${targs[@]}"
else
  step "2/10 Apex classes" --source-dir "$D/classes"
fi
step "3/10 Lightning web components" --source-dir "$D/lwc"
step "4/10 quick actions" --source-dir "$D/quickActions"
step "5/10 layouts" --source-dir "$D/layouts"
step "6/10 Lightning pages" --source-dir "$D/flexipages"
step "7/10 tabs" --source-dir "$D/tabs"
step "8/10 app" --source-dir "$D/applications"
step "9/10 permission sets" --source-dir "$D/permissionsets"
step "10/10 permission set groups" --source-dir "$D/permissionsetgroups"
echo "Hub app deployed to ${org}."
echo "Next: sf-pipeline/scripts/grant-app-access.sh ${org} CDO_Admin_Access   (from the pipeline branch)"
echo "      py sf-pipeline/scripts/seed-pipeline.py --org ${org}"
