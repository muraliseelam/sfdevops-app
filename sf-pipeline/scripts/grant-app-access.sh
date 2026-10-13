#!/usr/bin/env bash
# grant-app-access.sh <org-alias> <group> [username...]
#
# Assign a permission set group of the SF DevOps hub app to users (default: the CLI's own user
# for that org). Groups: CDO_Developer_Access, CDO_Release_Manager_Access,
# CDO_Pipeline_Admin_Access, CDO_Admin_Access. The hub's callback integration user needs
# CDO_Pipeline_Admin_Access.
#
# App visibility is a separate grant from tabs, objects and classes; the groups carry all of
# them, so a user holding only CDO_Developer_Access sees the app and every tab. Idempotent:
# an existing assignment is left alone. Waits for a freshly deployed group to finish
# recalculating, because a group that is not yet "Updated" cannot be assigned.
set -euo pipefail

org="${1:?usage: grant-app-access.sh <org-alias> <group> [username...]}"
group="${2:?usage: grant-app-access.sh <org-alias> <group> [username...]}"
shift 2
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then PY="$c"; break; fi
done
[[ -n "$PY" ]] || { echo "no working Python found" >&2; exit 1; }

q() {  # q <soql> -> JSON records on stdout
  sf data query --target-org "$org" --query "$1" --json | "$PY" -c "import json,sys; print(json.dumps((json.load(sys.stdin).get('result') or {}).get('records') or []))"
}
field() { "$PY" -c "import json,sys; r=json.load(sys.stdin); print(r[0]['$1'] if r else '')"; }

users=("$@")
if [[ ${#users[@]} -eq 0 ]]; then
  users=("$(sf org display --target-org "$org" --json | "$PY" -c "import json,sys; print(json.load(sys.stdin)['result']['username'])")")
fi

for attempt in $(seq 1 30); do
  status="$(q "SELECT Id, Status FROM PermissionSetGroup WHERE DeveloperName = '${group}'" | field Status)"
  [[ -n "$status" ]] || { echo "Permission set group ${group} does not exist in ${org}. Deploy the hub app first." >&2; exit 1; }
  [[ "$status" == "Updated" ]] && break
  echo "  ${group} is ${status}; waiting for Salesforce to finish recalculating..."
  sleep 10
done
gid="$(q "SELECT Id FROM PermissionSetGroup WHERE DeveloperName = '${group}'" | field Id)"

for u in "${users[@]}"; do
  uid="$(q "SELECT Id FROM User WHERE Username = '${u}'" | field Id)"
  [[ -n "$uid" ]] || { echo "No user ${u} in ${org}" >&2; exit 1; }
  existing="$(q "SELECT Id FROM PermissionSetAssignment WHERE AssigneeId = '${uid}' AND PermissionSetGroupId = '${gid}'" | field Id)"
  if [[ -n "$existing" ]]; then
    echo "  ${u} already has ${group}"
    continue
  fi
  sf data create record --target-org "$org" --sobject PermissionSetAssignment \
    --values "AssigneeId=${uid} PermissionSetGroupId=${gid}" --json >/dev/null
  echo "  assigned ${group} to ${u}"
done
