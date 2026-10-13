#!/usr/bin/env bash
# deploy-hub.sh <org-alias> [--tests]
#
# Deploy the SF DevOps hub app to an org from source, in the only order that works
# (see tools/README.md "Deploy order"), checking every step by its deploy id rather than by
# the CLI's exit code. With --tests the Apex step runs the hub's test classes
# (RunSpecifiedTests); production orgs always need that.
#
# Run from the root of a checkout of branch platform/sfdevops-app, with the org logged in to the
# sf CLI. Afterwards: grant access (sf-pipeline/scripts/grant-app-access.sh) and seed the pipeline
# records (sf-pipeline/scripts/seed-pipeline.py) from the pipeline branch.
set -euo pipefail

org="${1:?usage: deploy-hub.sh <org-alias> [--tests]}"
run_tests=false
[[ "${2:-}" == "--tests" ]] && run_tests=true
D=sfdevops-app/main/default
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
for f in (details.get("componentFailures") or []) if isinstance(details.get("componentFailures"), list) else [details.get("componentFailures")] if details.get("componentFailures") else []:
    print(f"    ! {f.get('componentType')} {f.get('fullName')}: {f.get('problem')}")
rt = details.get("runTestResult") or {}
fails = rt.get("failures") or []
for f in fails if isinstance(fails, list) else [fails]:
    print(f"    ! test {f.get('name')}.{f.get('methodName')}: {f.get('message')}")
if status != "Succeeded":
    if not r:
        print("    " + str(data.get("message", ""))[:500])
    sys.exit(1)
PY
  rm -f "$out"
}

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
