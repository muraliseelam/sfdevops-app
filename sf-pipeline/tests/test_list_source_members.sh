#!/usr/bin/env bash
# Tests for list-source-members.sh with a stub `sf` that returns canned SourceMember rows.
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

T="$(new_tmp)"
BIN="$T/bin"
cat >"$T/rows.json" <<'EOF'
{
  "status": 0,
  "result": {
    "records": [
      {"attributes": {"type": "SourceMember"}, "MemberType": "ApexClass", "MemberName": "OldOne", "IsNameObsolete": false, "IsNewMember": false, "LastModifiedDate": "2026-10-10T08:00:00.000+0000", "LastModifiedBy": {"attributes": {"type": "User"}, "Name": "Dana Dev"}, "RevisionCounter": 3},
      {"attributes": {"type": "SourceMember"}, "MemberType": "CustomField", "MemberName": "Account.Region__c", "IsNameObsolete": false, "IsNewMember": true, "LastModifiedDate": "2026-10-12T09:30:00.000+0000", "LastModifiedBy": {"attributes": {"type": "User"}, "Name": "Ari Admin"}, "RevisionCounter": 7},
      {"attributes": {"type": "SourceMember"}, "MemberType": "ApexClass", "MemberName": "Removed", "IsNameObsolete": true, "IsNewMember": false, "LastModifiedDate": "2026-10-12T09:30:00.000+0000", "LastModifiedBy": null, "RevisionCounter": 9}
    ],
    "totalSize": 3,
    "done": true
  },
  "warnings": []
}
EOF
write_stub "$BIN" sf <<'EOF'
#!/usr/bin/env bash
# Stub sf: `sf data query` returns $STUB_ROWS (or an error) and records the query.
if [[ "${1:-} ${2:-}" == "data query" ]]; then
  printf '%s\n' "$*" >"$STUB_DIR/query.txt"
  if [[ "${STUB_FAIL:-false}" == "true" ]]; then
    echo '{"name":"INVALID_TYPE","message":"sObject type '"'"'SourceMember'"'"' is not supported.","status":1,"exitCode":1}'
    exit 1
  fi
  cat "$STUB_ROWS"
  exit 0
fi
exit 0
EOF

run_lsm() {
  OUTF="$T/out.$RANDOM"
  : >"$OUTF"
  RC=0
  OUT="$(cd "$T" && PATH="$BIN:$PATH" STUB_DIR="$T" STUB_ROWS="$T/rows.json" GITHUB_OUTPUT="$OUTF" "$@" 2>&1)" || RC=$?
}

section "list-source-members.sh"
run_lsm bash "$SCRIPTS_DIR/list-source-members.sh" sfp-dev "$T/members.json"
assert_eq 0 "$RC" "exits 0"
assert_contains "$OUT" "3 source member(s)" "prints the count"
assert_eq 3 "$(out_get "$OUTF" member_count)" "member_count output"
assert_eq "$T/members.json" "$(out_get "$OUTF" members_file)" "members_file output"
F="$T/members.json"
assert_eq 3 "$(json_get "$F" 'len(d)')" "writes a JSON array"
assert_eq "Removed" "$(json_get "$F" 'd[0]["name"]')" "newest first (ties broken by revision)"
assert_eq "Account.Region__c" "$(json_get "$F" 'd[1]["name"]')" "second newest"
assert_eq "OldOne" "$(json_get "$F" 'd[2]["name"]')" "oldest last"
assert_eq "Delete" "$(json_get "$F" 'd[0]["state"]')" "IsNameObsolete -> Delete"
assert_eq "Add" "$(json_get "$F" 'd[1]["state"]')" "IsNewMember -> Add"
assert_eq "Modify" "$(json_get "$F" 'd[2]["state"]')" "otherwise Modify"
assert_eq "Ari Admin" "$(json_get "$F" 'd[1]["lastModifiedBy"]')" "lastModifiedBy from LastModifiedBy.Name"
assert_eq "" "$(json_get "$F" 'd[0]["lastModifiedBy"]')" "a missing user is blank"
assert_eq "CustomField" "$(json_get "$F" 'd[1]["type"]')" "type from MemberType"
assert_eq "2026-10-12T09:30:00.000+0000" "$(json_get "$F" 'd[1]["lastModifiedDate"]')" "lastModifiedDate"
assert_eq '["lastModifiedBy", "lastModifiedDate", "name", "state", "type"]' "$(json_get "$F" 'sorted(d[0])')" "exactly the contract fields"
q="$(cat "$T/query.txt")"
assert_contains "$q" "--use-tooling-api" "queries through the Tooling API"
assert_contains "$q" "-o sfp-dev" "in the named org"
assert_contains "$q" "LastModifiedBy.Name" "selects the last-modified-by user name"
assert_contains "$q" "ORDER BY LastModifiedDate DESC" "orders newest first"

run_lsm bash "$SCRIPTS_DIR/list-source-members.sh" sfp-dev
assert_eq 0 "$RC" "default out file works"
assert_file "$T/.sgd/source-members.json" "defaults to .sgd/source-members.json"

run_lsm env STUB_FAIL=true bash "$SCRIPTS_DIR/list-source-members.sh" sfp-dev "$T/fail.json"
assert_eq 1 "$RC" "a failed query fails"
assert_contains "$OUT" "source tracking must be enabled" "explains that source tracking is needed"

run_lsm bash "$SCRIPTS_DIR/list-source-members.sh"
assert_eq 2 "$RC" "no alias is a usage error"

finish
