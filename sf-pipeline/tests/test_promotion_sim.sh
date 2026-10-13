#!/usr/bin/env bash
# test_promotion_sim.sh — a pure-git simulation of the promotion-branch algorithm.
#
# Proves, before anyone trusts it with an org:
#   1. no clobber   the target's own change (L1-qa) survives a promotion of a feature that
#                   touches the same file (L3-feat); the merge-base payload would have lost it
#   2. conflict     a feature that edits the same line as the target aborts, lists the
#                   conflicting paths, leaves no half-merge behind, and exits non-zero
#   3. moved        if the target moves between the cut and the post-deploy merge, the merge
#                   is refused and the target is left untouched
#   4. merge        with the target unchanged, the promotion lands and the target's tree is
#                   exactly the deployed tree
#   5. protected    a push rejected by branch protection is reported as a failure, never as
#                   success (MERGE_MODE=push, i.e. no PR fallback available)
#   6. rebuild      a later job that re-cuts from the recorded CUT_SHA with the feature's
#                   commit SHA gets the identical tree, even after the target moved, so a
#                   validated tree and a deployed tree can be proven equal
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMOTE="$HERE/../scripts/promote.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILS=0

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '$2', got '$1')"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then pass "$3"; else fail "$3 (missing '$2')"; fi; }
assert_not_contains() { if ! grep -qF -- "$2" <<<"$1"; then pass "$3"; else fail "$3 (unexpected '$2')"; fi; }
out_val() { grep -E "^$2=" "$1" | tail -1 | cut -d= -f2-; }

git_q() { git -c init.defaultBranch=main -c core.autocrlf=false "$@"; }
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME=sim GIT_AUTHOR_EMAIL=sim@example.com
export GIT_COMMITTER_NAME=sim GIT_COMMITTER_EMAIL=sim@example.com

# --- origin with main (baseline/prod) and qa ---------------------------------
git_q init -q --bare "$WORK/origin.git"
git_q clone -q "$WORK/origin.git" "$WORK/dev" 2>/dev/null
cd "$WORK/dev"
git config user.name sim && git config user.email sim@example.com
mkdir -p force-app/main/default/classes
printf 'L1\nL2\nL3\n' > force-app/main/default/classes/Shared.cls
git add . && git commit -qm "baseline" && git push -q origin HEAD:main

git checkout -qb qa
printf 'L1-qa\nL2\nL3\n' > force-app/main/default/classes/Shared.cls
git commit -qam "qa-only change already in the QA org" && git push -q origin qa

# feature/WI-0001: cut from the BASELINE, edits L3
git checkout -q -b feature/WI-0001 origin/main
printf 'L1\nL2\nL3-feat\n' > force-app/main/default/classes/Shared.cls
git commit -qam "WI-0001 change" && git push -q origin feature/WI-0001

# feature/WI-0002: cut from the BASELINE, edits L1 (the same line qa changed)
git checkout -q -b feature/WI-0002 origin/main
printf 'L1-feat2\nL2\nL3\n' > force-app/main/default/classes/Shared.cls
git commit -qam "WI-0002 change" && git push -q origin feature/WI-0002

# --- 1. no clobber -------------------------------------------------------------
echo "== 1. no clobber"
OUT1="$WORK/out1"; : > "$OUT1"
GITHUB_OUTPUT="$OUT1" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0001 FEATURE_REFS=feature/WI-0001 \
  bash "$PROMOTE" cut >/dev/null
CUT1="$(out_val "$OUT1" target_sha_at_cut)"
PAYLOAD="$(git show HEAD:force-app/main/default/classes/Shared.cls)"
assert_eq "$(git rev-parse --abbrev-ref HEAD)" "promotion/WI-0001-to-qa" "promotion branch is named promotion/<WI>-to-<env>"
assert_eq "$CUT1" "$(git rev-parse origin/qa)" "target_sha_at_cut is the target's head at the cut"
assert_contains "$PAYLOAD" "L1-qa" "promotion payload keeps the target's own change (L1-qa)"
assert_contains "$PAYLOAD" "L3-feat" "promotion payload carries the feature's change (L3-feat)"
DELTA="$(git diff --name-only "$CUT1" HEAD)"
assert_eq "$DELTA" "force-app/main/default/classes/Shared.cls" "delta(target_sha_at_cut..HEAD) is exactly the changed file"
MB_PAYLOAD="$(git show origin/feature/WI-0001:force-app/main/default/classes/Shared.cls)"
assert_not_contains "$MB_PAYLOAD" "L1-qa" "the merge-base payload (feature's own file) WOULD have clobbered L1-qa"

# --- 2. conflict ---------------------------------------------------------------
echo "== 2. conflict"
git checkout -q --detach origin/main
OUT2="$WORK/out2"; : > "$OUT2"
set +e
GITHUB_OUTPUT="$OUT2" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0002 FEATURE_REFS=feature/WI-0002 \
  bash "$PROMOTE" cut >"$WORK/err2" 2>&1
CODE2=$?
set -e
assert_eq "$CODE2" "10" "a conflicting promotion exits 10 (fails the job)"
assert_eq "$(out_val "$OUT2" conflict)" "true" "conflict=true is reported"
assert_contains "$(cat "$OUT2")" "force-app/main/default/classes/Shared.cls" "conflict_paths names the conflicting file"
assert_contains "$(cat "$WORK/err2")" "Merge conflict promoting WI-0002 to qa" "an ::error:: annotation explains the conflict"
if [[ -e .git/MERGE_HEAD ]]; then fail "merge was aborted (MERGE_HEAD still present)"; else pass "merge was aborted (no MERGE_HEAD)"; fi
assert_eq "$(git status --porcelain)" "" "working tree is clean after the abort"

# --- 3. target moved during the run ---------------------------------------------
echo "== 3. target moved"
git checkout -q promotion/WI-0001-to-qa
DEPLOYED="$(git rev-parse HEAD)"
# Someone else's promotion lands on qa while this run was deploying.
git clone -q "$WORK/origin.git" "$WORK/other" 2>/dev/null
( cd "$WORK/other" && git checkout -q qa && echo "other" > force-app/main/default/classes/Other.cls \
  && git add . && git commit -qm "another promotion" && git push -q origin qa )
QA_BEFORE="$(git ls-remote "$WORK/origin.git" refs/heads/qa | cut -f1)"
OUT3="$WORK/out3"; : > "$OUT3"
set +e
GITHUB_OUTPUT="$OUT3" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0001 TARGET_SHA_AT_CUT="$CUT1" \
  DEPLOYED_SHA="$DEPLOYED" bash "$PROMOTE" merge >/dev/null 2>"$WORK/err3"
CODE3=$?
set -e
assert_eq "$CODE3" "11" "merge refuses with exit 11 when the target moved"
assert_eq "$(out_val "$OUT3" merged)" "false" "merged=false is reported"
assert_contains "$(out_val "$OUT3" reason)" "moved" "the reason says the target moved"
assert_eq "$(git ls-remote "$WORK/origin.git" refs/heads/qa | cut -f1)" "$QA_BEFORE" "the target branch was not touched"

# --- 4. merge with the target unchanged -----------------------------------------
echo "== 4. merge"
# Re-cut from the moved target and merge with nothing moving underneath.
OUT4="$WORK/out4"; : > "$OUT4"
GITHUB_OUTPUT="$OUT4" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0001 FEATURE_REFS=feature/WI-0001 \
  bash "$PROMOTE" cut >/dev/null
CUT4="$(out_val "$OUT4" target_sha_at_cut)"
DEPLOYED4="$(git rev-parse HEAD)"
TREE4="$(git rev-parse HEAD^{tree})"
OUT5="$WORK/out5"; : > "$OUT5"
GITHUB_OUTPUT="$OUT5" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0001 TARGET_SHA_AT_CUT="$CUT4" \
  DEPLOYED_SHA="$DEPLOYED4" bash "$PROMOTE" merge >/dev/null 2>&1
assert_eq "$(out_val "$OUT5" merged)" "true" "merge succeeds when the target did not move"
assert_eq "$(out_val "$OUT5" merge_method)" "push" "merge used a plain push (unprotected target)"
git fetch -q origin qa
assert_eq "$(git rev-parse origin/qa^{tree})" "$TREE4" "the target's tree is exactly the deployed tree"
FINAL="$(git show origin/qa:force-app/main/default/classes/Shared.cls)"
assert_contains "$FINAL" "L1-qa" "after the merge the target still has L1-qa"
assert_contains "$FINAL" "L3-feat" "after the merge the target has L3-feat"
assert_contains "$(git ls-tree -r --name-only origin/qa)" "Other.cls" "the other promotion's file is still there"

# --- 5. protected branch, no PR fallback ----------------------------------------
echo "== 5. protected"
cat > "$WORK/origin.git/hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
while read -r old new ref; do
  if [[ "$ref" == "refs/heads/qa" ]]; then
    echo "error: GH006: Protected branch update failed for refs/heads/qa." >&2
    exit 1
  fi
done
HOOK
chmod +x "$WORK/origin.git/hooks/pre-receive"
git checkout -q -b feature/WI-0003 origin/main
echo "x" > force-app/main/default/classes/Third.cls && git add . && git commit -qm "WI-0003" && git push -q origin feature/WI-0003
OUT6="$WORK/out6"; : > "$OUT6"
GITHUB_OUTPUT="$OUT6" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0003 FEATURE_REFS=feature/WI-0003 \
  bash "$PROMOTE" cut >/dev/null
OUT7="$WORK/out7"; : > "$OUT7"
set +e
GITHUB_OUTPUT="$OUT7" MERGE_MODE=push TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0003 \
  TARGET_SHA_AT_CUT="$(out_val "$OUT6" target_sha_at_cut)" bash "$PROMOTE" merge >/dev/null 2>"$WORK/err7"
CODE7=$?
set -e
assert_eq "$CODE7" "12" "a push rejected by protection fails the job (exit 12), it is not reported as success"
assert_eq "$(out_val "$OUT7" merged)" "false" "merged=false after a rejected push"
OUT8="$WORK/out8"; : > "$OUT8"
set +e
GITHUB_OUTPUT="$OUT8" MERGE_MODE=auto GITHUB_REPOSITORY="" GH_TOKEN="" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0003 \
  TARGET_SHA_AT_CUT="$(out_val "$OUT6" target_sha_at_cut)" bash "$PROMOTE" merge >/dev/null 2>&1
CODE8=$?
set -e
assert_eq "$CODE8" "12" "auto mode without a usable PR path also fails loudly (exit 12)"

# --- 6. deterministic rebuild from recorded SHAs -----------------------------------
echo "== 6. rebuild"
rm -f "$WORK/origin.git/hooks/pre-receive"
git checkout -q --detach origin/main
OUT9="$WORK/out9"; : > "$OUT9"
FEAT_SHA="$(git rev-parse origin/feature/WI-0003)"
GITHUB_OUTPUT="$OUT9" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0003 FEATURE_REFS="$FEAT_SHA"   bash "$PROMOTE" cut >/dev/null
CUT9="$(out_val "$OUT9" target_sha_at_cut)"
TREE9="$(out_val "$OUT9" head_tree)"
( cd "$WORK/other" && git pull -q origin qa && echo "moved" > force-app/main/default/classes/Moved.cls   && git add . && git commit -qm "qa moves again" && git push -q origin qa )
git checkout -q --detach origin/main
OUT10="$WORK/out10"; : > "$OUT10"
GITHUB_OUTPUT="$OUT10" CUT_SHA="$CUT9" TARGET_BRANCH=qa TARGET_ENV=qa WORK_ITEM=WI-0003 FEATURE_REFS="$FEAT_SHA"   bash "$PROMOTE" cut >/dev/null
assert_eq "$(out_val "$OUT10" target_sha_at_cut)" "$CUT9" "CUT_SHA pins the cut to the recorded target commit"
assert_eq "$(out_val "$OUT10" head_tree)" "$TREE9" "the rebuilt promotion tree is identical to the first job's tree"

echo
if [[ "$FAILS" -gt 0 ]]; then
  echo "$FAILS assertion(s) failed"
  exit 1
fi
echo "All promotion simulation assertions passed"
