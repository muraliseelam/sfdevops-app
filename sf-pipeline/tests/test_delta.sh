#!/usr/bin/env bash
# Tests for delta.sh and story-manifest.sh against a throwaway git repo (with a bare origin)
# and the real sfdx-git-delta plugin. Skips cleanly when `sf sgd` is not installed.
set -uo pipefail
# shellcheck source=helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

if ! command -v sf >/dev/null 2>&1 || ! sf sgd source delta --help >/dev/null 2>&1; then
  echo "SKIP: test_delta.sh needs the sfdx-git-delta plugin (sf sgd source delta); install it with sf-pipeline/scripts/install-sf.sh"
  exit 0
fi

T="$(new_tmp)"
ORIGIN="$T/origin.git"
REPO="$T/work"
git init -q --bare "$ORIGIN"
git init -q -b main "$REPO" 2>/dev/null || { git init -q "$REPO" && git -C "$REPO" checkout -q -b main; }
g() { git -C "$REPO" -c user.name=Test -c user.email=test@example.com -c core.autocrlf=false "$@"; }
g remote add origin "$ORIGIN"

CLS_META='<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>66.0</apiVersion>
    <status>Active</status>
</ApexClass>'
LWC_META='<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>66.0</apiVersion>
    <isExposed>false</isExposed>
</LightningComponentBundle>'
add_class() { # add_class <root> <name> [body]
  local dir="$REPO/$1/main/default/classes"
  mkdir -p "$dir"
  printf '%s\n' "${3:-public with sharing class $2 {}}" >"$dir/$2.cls"
  printf '%s\n' "$CLS_META" >"$dir/$2.cls-meta.xml"
}

# ---- base commit ------------------------------------------------------------------------------
printf '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"66.0"}\n' >"$REPO/sfdx-project.json"
printf '# test forceignore\n**/IgnoredThing.cls*\n' >"$REPO/.forceignore"
add_class force-app Keep
add_class force-app Gone
add_class other-app Outside
mkdir -p "$REPO/force-app/main/default/lwc/widget"
printf 'import { LightningElement } from "lwc";\nexport default class Widget extends LightningElement {}\n' >"$REPO/force-app/main/default/lwc/widget/widget.js"
printf '<template></template>\n' >"$REPO/force-app/main/default/lwc/widget/widget.html"
printf '%s\n' "$LWC_META" >"$REPO/force-app/main/default/lwc/widget/widget.js-meta.xml"
g add -A
g commit -q -m base
BASE_SHA="$(g rev-parse HEAD)"
g push -q origin main

# ---- change commit ----------------------------------------------------------------------------
add_class force-app NewOne
add_class force-app Keep 'public with sharing class Keep { public Integer v = 1; }'
add_class force-app IgnoredThing
g rm -q force-app/main/default/classes/Gone.cls force-app/main/default/classes/Gone.cls-meta.xml
printf 'import { LightningElement } from "lwc";\nexport default class Widget extends LightningElement { n = 1; }\n' >"$REPO/force-app/main/default/lwc/widget/widget.js"
add_class other-app Outside 'public with sharing class Outside { public Integer x = 2; }'
add_class other-app OutsideNew
g add -A
g commit -q -m change
cp "$REPO/.forceignore" "$T/forceignore.orig"

run_delta() { # run_delta [VAR=value ...] - runs delta.sh in $REPO; sets RC, OUT, OUTF
  OUTF="$T/out.$RANDOM"
  : >"$OUTF"
  RC=0
  OUT="$(cd "$REPO" && env -u DELTA_FROM -u DELTA_TO -u DELTA_OUTPUT -u SOURCE_PATH -u FORCE_IGNORE \
    GITHUB_OUTPUT="$OUTF" "$@" bash "$SCRIPTS_DIR/delta.sh" 2>&1)" || RC=$?
}
o() { out_get "$OUTF" "$1"; }

section "delta.sh: default range origin/main..HEAD"
run_delta BASELINE_BRANCH=main
assert_eq 0 "$RC" "delta.sh exits 0"
[[ "$RC" -eq 0 ]] || echo "$OUT"
PKG="$REPO/.sgd/package/package.xml"
DESTR="$REPO/.sgd/destructiveChanges/destructiveChanges.xml"
assert_file "$PKG" "writes .sgd/package/package.xml"
assert_file "$DESTR" "writes .sgd/destructiveChanges/destructiveChanges.xml"
pkg="$(cat "$PKG" 2>/dev/null)"
destr="$(cat "$DESTR" 2>/dev/null)"
assert_contains "$pkg" "<members>NewOne</members>" "package has the added class"
assert_contains "$pkg" "<members>Keep</members>" "package has the modified class"
assert_contains "$pkg" "<members>widget</members>" "package has the changed LWC bundle"
assert_contains "$pkg" "<version>66.0</version>" "package uses SF_API_VERSION (default 66.0)"
assert_not_contains "$pkg" "Outside" "a class outside force-app is NOT in the package (source_path scoping)"
assert_not_contains "$pkg" "OutsideNew" "a new class outside force-app is NOT in the package"
assert_not_contains "$pkg" "IgnoredThing" ".forceignore is honoured by default"
assert_contains "$destr" "<members>Gone</members>" "the deleted class is in destructiveChanges.xml"
assert_not_contains "$pkg" "<members>Gone</members>" "the deleted class is not in package.xml"
assert_eq true "$(o has_changes)" "has_changes=true"
assert_eq true "$(o has_destructive)" "has_destructive=true"
assert_eq true "$(o has_apex)" "has_apex=true"
assert_eq true "$(o has_apex_destructive)" "has_apex_destructive=true"
assert_eq true "$(o has_lwc)" "has_lwc=true"
assert_eq false "$(o has_aura)" "has_aura=false"
assert_eq true "$(o has_js)" "has_js=true"
assert_eq false "$(o has_profiles)" "has_profiles=false"
assert_eq 3 "$(o component_count)" "component_count=3 (NewOne, Keep, widget)"
assert_eq 1 "$(o destructive_count)" "destructive_count=1"
assert_eq ".sgd/package/package.xml" "$(o package_xml)" "package_xml output"
assert_eq ".sgd/destructiveChanges/destructiveChanges.xml" "$(o destructive_xml)" "destructive_xml output"
changed="$(cat "$REPO/$(o changed_files_file)" 2>/dev/null)"
assert_contains "$changed" "force-app/main/default/classes/NewOne.cls" "changed files list the added class"
assert_contains "$changed" "force-app/main/default/lwc/widget/widget.js" "changed files list the LWC change"
assert_not_contains "$changed" "other-app/" "changed files are scoped to SOURCE_PATH"
assert_not_contains "$changed" "Gone.cls" "deleted files are not in the changed files list"
assert_eq "origin/main" "$(git -C "$REPO" rev-parse --abbrev-ref origin/main)" "origin/main was fetched"

section "delta.sh: FORCE_IGNORE=false"
run_delta BASELINE_BRANCH=main FORCE_IGNORE=false DELTA_OUTPUT=.sgd-nofi
assert_eq 0 "$RC" "delta.sh exits 0 with FORCE_IGNORE=false"
assert_contains "$(cat "$REPO/.sgd-nofi/package/package.xml" 2>/dev/null)" "<members>IgnoredThing</members>" \
  "a normally-ignored class is included when FORCE_IGNORE=false"
assert_eq "$(cat "$T/forceignore.orig")" "$(cat "$REPO/.forceignore")" ".forceignore is restored afterwards"
assert_eq "" "$(git -C "$REPO" status --porcelain -- .forceignore)" ".forceignore is unchanged in git"
assert_eq 4 "$(o component_count)" "component_count includes the ignored class"

run_delta BASELINE_BRANCH=main DELTA_TO=does-not-exist
assert_eq 1 "$RC" "an unknown DELTA_TO fails"
assert_contains "$OUT" "does-not-exist" "and names the ref"

# A regular file where the output directory should be: delta.sh fails after blanking .forceignore.
echo "not a directory" >"$REPO/blocked-output"
run_delta BASELINE_BRANCH=main FORCE_IGNORE=false DELTA_OUTPUT=blocked-output
assert_eq 1 "$RC" "a failure after .forceignore was blanked exits non-zero"
assert_contains "$OUT" "restored .forceignore" "the EXIT trap restores .forceignore"
assert_eq "$(cat "$T/forceignore.orig")" "$(cat "$REPO/.forceignore")" ".forceignore is restored even when delta.sh fails"
rm -f "$REPO/blocked-output"

section "delta.sh: explicit refs"
run_delta DELTA_FROM="$BASE_SHA" DELTA_TO=HEAD DELTA_OUTPUT=.sgd-sha
assert_eq 0 "$RC" "a local SHA as DELTA_FROM works without a fetch"
assert_eq 3 "$(o component_count)" "same delta from the SHA"

run_delta DELTA_FROM=HEAD DELTA_TO=HEAD DELTA_OUTPUT=.sgd-empty
assert_eq 0 "$RC" "an empty range exits 0"
assert_eq false "$(o has_changes)" "has_changes=false for an empty range"
assert_eq 0 "$(o component_count)" "component_count=0 for an empty range"
assert_eq false "$(o has_apex)" "has_apex=false for an empty range"

run_delta SOURCE_PATH=other-app DELTA_FROM="$BASE_SHA" DELTA_OUTPUT=.sgd-other
assert_contains "$(cat "$REPO/.sgd-other/package/package.xml" 2>/dev/null)" "<members>OutsideNew</members>" \
  "SOURCE_PATH picks the metadata root"
assert_not_contains "$(cat "$REPO/.sgd-other/package/package.xml" 2>/dev/null)" "NewOne" \
  "and leaves the other root out"

run_delta
assert_eq 1 "$RC" "no DELTA_FROM and no BASELINE_BRANCH is an error"
assert_contains "$OUT" "BASELINE_BRANCH" "the error names BASELINE_BRANCH"

section "story-manifest.sh"
g push -q origin main
g checkout -q -b feature/WI-0001 "$BASE_SHA"
add_class force-app StoryClass
g add -A
g commit -q -m "WI-0001 story"
g push -q origin feature/WI-0001
g checkout -q main
add_class force-app MainOnly
g add -A
g commit -q -m "baseline moves on"
g push -q origin main
OUTF="$T/out.story"
: >"$OUTF"
RC=0
OUT="$(cd "$REPO" && GITHUB_OUTPUT="$OUTF" BASELINE_BRANCH=main bash "$SCRIPTS_DIR/story-manifest.sh" WI-0001 2>&1)" || RC=$?
assert_eq 0 "$RC" "story-manifest.sh exits 0"
[[ "$RC" -eq 0 ]] || echo "$OUT"
story_pkg="$(cat "$REPO/.sgd-story/WI-0001/package/package.xml" 2>/dev/null)"
assert_contains "$story_pkg" "<members>StoryClass</members>" "the story manifest has the feature's class"
assert_not_contains "$story_pkg" "MainOnly" "the story manifest ignores later baseline changes"
assert_not_contains "$story_pkg" "NewOne" "the story manifest ignores changes made before the cut"
assert_eq "$BASE_SHA" "$(o merge_base)" "merge_base output"
assert_eq "feature/WI-0001" "$(o feature_branch)" "feature_branch output"
assert_eq ".sgd-story/WI-0001" "$(o story_dir)" "story_dir output"
assert_eq 1 "$(o component_count)" "delta outputs are passed through"

RC=0
OUT="$(cd "$REPO" && BASELINE_BRANCH=main bash "$SCRIPTS_DIR/story-manifest.sh" WI-9999 2>&1)" || RC=$?
assert_eq 1 "$RC" "a work item without a pushed feature branch fails"
assert_contains "$OUT" "feature/WI-9999" "and names the branch"

finish
