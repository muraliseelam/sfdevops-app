#!/usr/bin/env bash
# delta.sh - the deployable delta between two git refs, via sfdx-git-delta.
#
# Env
#   DELTA_FROM       ref to diff FROM (default origin/$BASELINE_BRANCH)
#   DELTA_TO         ref to diff TO   (default HEAD)
#   DELTA_OUTPUT     output directory (default .sgd)
#   SOURCE_PATH      metadata root the delta is scoped to (default force-app)
#   FORCE_IGNORE     true: honour .forceignore; false: blank it for this run (default true)
#   SF_API_VERSION   package.xml API version (default 66.0)
#   BASELINE_BRANCH  only used to default DELTA_FROM
#
# Runs, from the repository root:
#   sf sgd source delta --from FROM --to TO --output-dir DELTA_OUTPUT --source-dir SOURCE_PATH \
#     --api-version SF_API_VERSION [--ignore-file .forceignore]
# sfdx-git-delta does not read .forceignore by itself, so with FORCE_IGNORE=true the file is
# passed with --ignore-file. With FORCE_IGNORE=false the file is backed up, blanked and restored
# by an EXIT trap, so normally-ignored components are included.
#
# Produces $DELTA_OUTPUT/package/package.xml and
# $DELTA_OUTPUT/destructiveChanges/destructiveChanges.xml.
#
# Outputs: has_changes has_destructive has_apex has_apex_destructive has_lwc has_aura has_js
#   has_profiles component_count destructive_count package_xml destructive_xml
#   changed_files_file (added/modified/renamed paths under SOURCE_PATH, one per line, from
#   `git diff --name-only --diff-filter=d FROM TO -- SOURCE_PATH`; deletions are left out
#   because they are in destructiveChanges.xml and a scanner cannot read a deleted file)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

BASELINE_BRANCH="$(strip_ref "${BASELINE_BRANCH:-}")"
FROM="${DELTA_FROM:-}"
if [[ -z "$FROM" ]]; then
  [[ -n "$BASELINE_BRANCH" ]] || die "set DELTA_FROM, or BASELINE_BRANCH so DELTA_FROM can default to origin/<baseline>"
  FROM="origin/$BASELINE_BRANCH"
fi
TO="${DELTA_TO:-HEAD}"
OUTPUT="${DELTA_OUTPUT:-.sgd}"
OUTPUT="${OUTPUT%/}"
SOURCE_PATH="${SOURCE_PATH:-force-app}"
SOURCE_PATH="${SOURCE_PATH%/}"
SOURCE_PATH="${SOURCE_PATH#./}"
FORCE_IGNORE="${FORCE_IGNORE:-true}"
API_VERSION="${SF_API_VERSION:-66.0}"

require_cmd git sf
PY="$(find_python)" || die "python3 (3.10+) is required to read the generated manifests"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "delta.sh must run inside a git work tree"

# Bring an origin/<branch> ref up to date. The explicit refspec makes the remote-tracking ref
# move even on a shallow, single-branch checkout. A failed fetch is tolerated when the ref
# already exists locally (a local test repo, or a runner without network to origin).
fetch_origin_ref() {
  local ref="$1" branch
  [[ "$ref" == origin/* ]] || return 0
  branch="${ref#origin/}"
  echo "git fetch --no-tags --prune origin $branch"
  if ! git -C "$repo_root" fetch --no-tags --prune origin "+refs/heads/${branch}:refs/remotes/origin/${branch}"; then
    if git -C "$repo_root" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null; then
      warn "could not fetch '$branch' from origin; using the local $ref"
    else
      die "could not fetch '$branch' from origin, and $ref does not exist locally"
    fi
  fi
}

fetch_origin_ref "$FROM"
[[ "$TO" == "$FROM" ]] || fetch_origin_ref "$TO"

from_sha="$(git -C "$repo_root" rev-parse --verify --quiet "${FROM}^{commit}")" || die "DELTA_FROM '$FROM' does not resolve to a commit"
to_sha="$(git -C "$repo_root" rev-parse --verify --quiet "${TO}^{commit}")" || die "DELTA_TO '$TO' does not resolve to a commit"

if ! sf sgd source delta --help >/dev/null 2>&1; then
  die "the sfdx-git-delta plugin is not installed (run sf-pipeline/scripts/install-sf.sh)"
fi

# ---- .forceignore handling -------------------------------------------------------------------
forceignore="$repo_root/.forceignore"
forceignore_backup=""
restore_forceignore() {
  if [[ -n "$forceignore_backup" && -f "$forceignore_backup" ]]; then
    cp -p "$forceignore_backup" "$forceignore"
    rm -f "$forceignore_backup"
    forceignore_backup=""
    echo "restored .forceignore"
  fi
}
sgd_extra=()
if is_true "$FORCE_IGNORE"; then
  if [[ -f "$forceignore" ]]; then
    sgd_extra+=(--ignore-file "$forceignore")
  fi
elif [[ -f "$forceignore" ]]; then
  forceignore_backup="$(mktemp)"
  trap restore_forceignore EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cp -p "$forceignore" "$forceignore_backup"
  : >"$forceignore"
  notice "FORCE_IGNORE=false: .forceignore is blanked for this delta, so normally-ignored components are included"
fi

# ---- run sfdx-git-delta -----------------------------------------------------------------------
mkdir -p "$OUTPUT"
rm -rf "$OUTPUT/package" "$OUTPUT/destructiveChanges"
echo "Delta $FROM (${from_sha:0:12}) -> $TO (${to_sha:0:12}), scoped to $SOURCE_PATH, API $API_VERSION"

sgd_log="$(mktemp)"
rc=0
sf sgd source delta \
  --from "$from_sha" \
  --to "$to_sha" \
  --output-dir "$OUTPUT" \
  --repo-dir "$repo_root" \
  --source-dir "$SOURCE_PATH" \
  --api-version "$API_VERSION" \
  "${sgd_extra[@]}" \
  --json >"$sgd_log" 2>&1 || rc=$?
cat "$sgd_log"
rm -f "$sgd_log"
[[ "$rc" -eq 0 ]] || die "sf sgd source delta failed (exit $rc)"

package_xml="$OUTPUT/package/package.xml"
destructive_xml="$OUTPUT/destructiveChanges/destructiveChanges.xml"
[[ -f "$package_xml" ]] || die "sfdx-git-delta did not write $package_xml"
[[ -f "$destructive_xml" ]] || die "sfdx-git-delta did not write $destructive_xml"

restore_forceignore

# ---- changed files ----------------------------------------------------------------------------
changed_files_file="$OUTPUT/changed-files.txt"
git -C "$repo_root" -c core.quotepath=off diff --name-only --diff-filter=d "$from_sha" "$to_sha" -- "$SOURCE_PATH" >"$changed_files_file"

# ---- read the manifests ------------------------------------------------------------------------
info="$("$PY" - "$package_xml" "$destructive_xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

NS = "{http://soap.sforce.com/2006/04/metadata}"


def read(path):
    types = {}
    root = ET.parse(path).getroot()
    for node in root.iter(NS + "types"):
        name = (node.findtext(NS + "name") or "").strip()
        members = [m.text.strip() for m in node.findall(NS + "members") if m.text and m.text.strip()]
        if name and members:
            types.setdefault(name, []).extend(members)
    return types


pkg, destructive = read(sys.argv[1]), read(sys.argv[2])


def n(types, *names):
    return sum(len(types.get(t, [])) for t in names)


def b(value):
    return "true" if value else "false"


component_count = sum(len(v) for v in pkg.values())
destructive_count = sum(len(v) for v in destructive.values())
lwc = n(pkg, "LightningComponentBundle") > 0
aura = n(pkg, "AuraDefinitionBundle") > 0
print(f"has_changes={b(component_count + destructive_count > 0)}")
print(f"has_destructive={b(destructive_count > 0)}")
print(f"has_apex={b(n(pkg, 'ApexClass', 'ApexTrigger') > 0)}")
print(f"has_apex_destructive={b(n(destructive, 'ApexClass', 'ApexTrigger') > 0)}")
print(f"has_lwc={b(lwc)}")
print(f"has_aura={b(aura)}")
print(f"has_js={b(lwc or aura)}")
print(f"has_profiles={b(n(pkg, 'Profile', 'PermissionSet') > 0)}")
print(f"component_count={component_count}")
print(f"destructive_count={destructive_count}")
PY
)" || die "could not parse the generated manifests"

echo "---- package.xml ----"
cat "$package_xml"
echo
echo "---- destructiveChanges.xml ----"
cat "$destructive_xml"
echo
echo "---- outputs ----"
while IFS='=' read -r key value; do
  [[ -n "$key" ]] && gh_output "$key" "$value"
done <<<"$(printf '%s' "$info" | tr -d '\r')"
gh_output package_xml "$package_xml"
gh_output destructive_xml "$destructive_xml"
gh_output changed_files_file "$changed_files_file"
