#!/usr/bin/env bash
# Tests for audit-append.sh (the bash wrapper around audit.py).
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

T="$(new_tmp)"
F="$T/audit/trail.jsonl"

section "audit-append.sh"
RC=0
OUT="$(env -u AUDIT_FILE GITHUB_ACTOR=octo-dev GITHUB_REPOSITORY=acme/sf bash "$SCRIPTS_DIR/audit-append.sh" \
  --event Deploy --status Success --env qa --work-item "WI-0032" --details "deployed 3 components" --file "$F" 2>&1)" || RC=$?
assert_eq 0 "$RC" "passes the arguments to audit.py and exits 0"
assert_file "$F" "creates the audit file and its directory"
assert_eq 1 "$(wc -l <"$F" | tr -d ' ')" "appends one line"
assert_eq Deploy "$(json_get "$F" 'd["event"]')" "event"
assert_eq "WI-0032" "$(json_get "$F" 'd["workItem"]')" "workItem"
assert_eq "deployed 3 components" "$(json_get "$F" 'd["details"]')" "details with spaces survive the wrapper"
assert_eq octo-dev "$(json_get "$F" 'd["actor"]')" "actor from GITHUB_ACTOR"
assert_contains "$OUT" '"status":"Success"' "prints the line"

RC=0
AUDIT_FILE="$F" bash "$SCRIPTS_DIR/audit-append.sh" --event Merge --status Failed >/dev/null 2>&1 || RC=$?
assert_eq 0 "$RC" "AUDIT_FILE is honoured"
assert_eq 2 "$(wc -l <"$F" | tr -d ' ')" "appends a second line"

RC=0
bash "$SCRIPTS_DIR/audit-append.sh" --status Success >/dev/null 2>&1 || RC=$?
assert_eq 2 "$RC" "audit.py's usage error comes through"

finish
