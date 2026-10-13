#!/usr/bin/env bash
# onboard-org.sh <org-alias> [baseline-ref]
#
# Bring a new (or refreshed) org into the pipeline: deploy the baseline branch's metadata in
# full, run every test class in the source tree so the org's coverage map (ApexCodeCoverage)
# exists for the test resolver, and print what the org now holds.
#
# The pipeline's invariant is "an environment branch describes its org". A brand-new org starts
# empty, so it must be brought to the baseline once before its first promotion; after that,
# promotions keep branch and org in step. Run it from a checkout of the repository, with the
# org already authenticated in the sf CLI (`sf org login web --alias <alias>` or JWT).
#
# Environment: SOURCE_PATH (default from pipeline.config.yml), WAIT_MINUTES (default 60).
set -euo pipefail

alias="${1:?usage: onboard-org.sh <org-alias> [baseline-ref]}"
ref="${2:-}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then PY="$c"; break; fi
done
[[ -n "$PY" ]] || { echo "::error::no working Python interpreter found"; exit 1; }
cd "$root"

src="${SOURCE_PATH:-$("$PY" "$here/plan.py" outputs | grep '^source_path=' | cut -d= -f2)}"
wait="${WAIT_MINUTES:-60}"

if [[ -n "$ref" ]]; then
  echo "Checking out ${ref} (detached) to deploy it."
  git fetch --quiet origin
  git checkout --quiet --detach "$ref"
fi

sf org display --target-org "$alias" >/dev/null || { echo "Org alias '$alias' is not authenticated in the sf CLI." >&2; exit 1; }

mapfile -t tests < <(grep -rlE '@[Ii][Ss][Tt][Ee][Ss][Tt]' "$src" --include='*.cls' 2>/dev/null | xargs -r -n1 basename | sed 's/\.cls$//' | sort -u)
args=(--source-dir "$src" --target-org "$alias" --wait "$wait" --json)
if [[ ${#tests[@]} -gt 0 ]]; then
  args+=(--test-level RunSpecifiedTests)
  for t in "${tests[@]}"; do args+=(--tests "$t"); done
  echo "Deploying ${src} to ${alias} with ${#tests[@]} test class(es): ${tests[*]}"
else
  args+=(--test-level NoTestRun)
  echo "Deploying ${src} to ${alias} (no Apex tests in the source tree)"
fi

out="$(mktemp)"
trap 'rm -f "$out"' EXIT
sf project deploy start "${args[@]}" > "$out" 2>/dev/null || true
"$PY" - "$out" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
r = data.get("result") or {}
status = r.get("status") or data.get("name") or "Unknown"
print(f"deploy id: {r.get('id')}  status: {status}  components: {r.get('numberComponentsDeployed')}  tests: {r.get('numberTestsCompleted')}/{r.get('numberTestsTotal')}")
details = r.get("details") or {}
fails = details.get("componentFailures") or []
fails = fails if isinstance(fails, list) else [fails]
for f in fails:
    print(f"  component failure: {f.get('componentType')} {f.get('fullName')}: {f.get('problem')}")
tf = ((details.get("runTestResult") or {}).get("failures")) or []
tf = tf if isinstance(tf, list) else [tf]
for f in tf:
    print(f"  test failure: {f.get('name')}.{f.get('methodName')}: {f.get('message')}")
if status != "Succeeded":
    print(data.get("message", ""))
    sys.exit(1)
PY

if [[ ${#tests[@]} -gt 0 ]]; then
  echo "Running the tests once more as a test run so the org's coverage map is populated..."
  sf apex run test --target-org "$alias" --class-names "$(IFS=,; echo "${tests[*]}")" --wait "$wait" --result-format human >/dev/null 2>&1 \
    || echo "warning: the coverage-map test run reported a problem; the deploy itself succeeded."
fi
echo "Org ${alias} now matches ${ref:-the current checkout} under ${src}."
