#!/usr/bin/env bash
# list-source-members.sh <alias> [out-file] - the components changed in a source-tracked org.
#
# Queries SourceMember through the Tooling API in <alias> and writes a JSON array, newest first:
#   [{"type", "name", "lastModifiedDate", "lastModifiedBy", "state"}]
# state: Add when IsNewMember, Delete when IsNameObsolete, else Modify.
# lastModifiedBy is LastModifiedBy.Name (the user relationship SourceMember exposes in API 66).
#
# Env: SOURCE_MEMBER_LIMIT (default 2000) caps the rows read.
# out-file defaults to .sgd/source-members.json. Prints the count.
# Outputs: member_count, members_file.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

if [[ $# -lt 1 || $# -gt 2 || -z "${1:-}" ]]; then
  echo "usage: list-source-members.sh <alias> [out-file]" >&2
  exit 2
fi
org="$1"
out="${2:-.sgd/source-members.json}"
limit="${SOURCE_MEMBER_LIMIT:-2000}"
[[ "$limit" =~ ^[0-9]+$ && "$limit" -gt 0 ]] || die "SOURCE_MEMBER_LIMIT must be a positive whole number"

require_cmd sf
PY="$(find_python)" || die "python3 (3.10+) is required to shape the SourceMember rows"

soql="SELECT MemberType, MemberName, IsNameObsolete, IsNewMember, LastModifiedDate, LastModifiedBy.Name, RevisionCounter FROM SourceMember WHERE MemberType != null ORDER BY LastModifiedDate DESC, RevisionCounter DESC LIMIT $limit"

raw="$(mktemp)"
trap 'rm -f "$raw"' EXIT
rc=0
sf data query --use-tooling-api --json -o "$org" -q "$soql" >"$raw" 2>/dev/null || rc=$?

mkdir -p "$(dirname "$out")"
count="$("$PY" - "$raw" "$out" "$rc" <<'PY'
import json
import sys

raw_path, out_path, rc = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    with open(raw_path, encoding="utf-8", errors="replace") as fh:
        data = json.load(fh)
except ValueError:
    data = {}
result = data.get("result") if isinstance(data, dict) else None
if rc != 0 or not isinstance(result, dict):
    message = (data.get("message") if isinstance(data, dict) else None) or "no JSON from sf data query"
    hint = ""
    if "SourceMember" in message or "INVALID_TYPE" in str(data.get("name", "")):
        hint = " (source tracking must be enabled: a scratch org or a sandbox with source tracking on)"
    sys.stderr.write(f"SourceMember query failed: {message.strip()}{hint}\n")
    sys.exit(1)


def state(rec):
    if rec.get("IsNameObsolete"):
        return "Delete"
    if rec.get("IsNewMember"):
        return "Add"
    return "Modify"


members = []
for rec in result.get("records") or []:
    by = rec.get("LastModifiedBy") or {}
    members.append({
        "type": rec.get("MemberType") or "",
        "name": rec.get("MemberName") or "",
        "lastModifiedDate": rec.get("LastModifiedDate") or "",
        "lastModifiedBy": (by.get("Name") if isinstance(by, dict) else "") or "",
        "state": state(rec),
        "_rev": rec.get("RevisionCounter") or 0,
    })
# The query orders newest first already; sort again so the contract holds whatever the source.
members.sort(key=lambda m: (m["lastModifiedDate"], m["_rev"]), reverse=True)
for m in members:
    m.pop("_rev")
with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
    json.dump(members, fh, indent=2)
    fh.write("\n")
print(len(members))
PY
)" || die "could not list SourceMember rows in '$org'"
count="${count//$'\r'/}"

echo "$count source member(s) in '$org' written to $out"
gh_output member_count "$count"
gh_output members_file "$out"
