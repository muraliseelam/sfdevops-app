#!/usr/bin/env bash
# promote.sh — the Copado-style promotion-branch algorithm.
#
#   promote.sh cut     Cut promotion/<WI>-to-<env> from the TARGET env branch and merge the
#                      feature branch(es) into it. HEAD is left at the result, and the
#                      deployable delta is `git diff <target_sha_at_cut> HEAD`.
#   promote.sh merge   After a SUCCESSFUL deploy, merge the promotion into the target, but only
#                      if the target has not moved since the cut. Tries a plain push first;
#                      if branch protection rejects it, opens a PR, marks the deployed head
#                      with the required commit status, and merges that PR pinned to the head.
#
# Why not a merge-base diff: Salesforce deploys whole files. If the target already has
# `L1-qa` in a file and the feature has `L3-feat` in the same file, the feature's own copy is
# `L1 / L2 / L3-feat`, and deploying it silently reverts `L1-qa`. The promotion merge produces
# `L1-qa / L2 / L3-feat`, which keeps both. sf-pipeline/tests/test_promotion_sim.sh proves it.
#
# Environment (cut):   TARGET_BRANCH, TARGET_ENV, WORK_ITEM, FEATURE_REFS (comma/space list of
#                      branches or commit SHAs), PROMOTION_PREFIX (promotion/), REMOTE (origin),
#                      CUT_SHA (optional: cut from this exact target commit instead of the
#                      target's current head; later jobs of one run use it to rebuild the
#                      identical tree the first job deployed or validated)
# Environment (merge): TARGET_BRANCH, TARGET_ENV, WORK_ITEM, TARGET_SHA_AT_CUT, DEPLOYED_SHA
#                      (default HEAD), PROMOTION_BRANCH (default current branch),
#                      MERGE_MODE (auto|push|pr, default auto), STATUS_CONTEXT
#                      (sfdevops/deploy), RUN_URL, GITHUB_REPOSITORY + GH_TOKEN (PR path),
#                      DELETE_PROMOTION_BRANCH (true)
#
# Exit codes: 0 ok (including "nothing to merge"), 1 usage or unexpected error,
#             10 merge conflict, 11 target moved (merge refused),
#             12 push rejected and the PR path was unavailable or failed.

set -euo pipefail

REMOTE="${REMOTE:-origin}"
PREFIX="${PROMOTION_PREFIX:-promotion/}"

emit() {
  local key="$1" value="$2"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    if [[ "$value" == *$'\n'* ]]; then
      local delim="EOF_${RANDOM}${RANDOM}${RANDOM}"
      printf '%s<<%s\n%s\n%s\n' "$key" "$delim" "$value" "$delim" >> "$GITHUB_OUTPUT"
    else
      printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    fi
  fi
  if [[ "$value" == *$'\n'* ]]; then
    printf '%s:\n%s\n' "$key" "$value"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

die() { echo "::error::$*"; exit 1; }

is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

strip_ref() {
  local r="$1"
  r="${r#refs/heads/}"
  r="${r#refs/remotes/${REMOTE}/}"
  r="${r#${REMOTE}/}"
  printf '%s' "$r"
}

fetch_branch() {
  # An explicit refspec: fetching anything outside the default namespace without one
  # silently leaves the remote-tracking ref missing.
  local b="$1"
  git fetch --no-tags --quiet "$REMOTE" "+refs/heads/${b}:refs/remotes/${REMOTE}/${b}"
}

ensure_identity() {
  if ! git config user.email >/dev/null 2>&1; then
    git config user.name "github-actions[bot]"
    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  fi
}

cmd_cut() {
  : "${TARGET_BRANCH:?TARGET_BRANCH is required}"
  : "${TARGET_ENV:?TARGET_ENV is required}"
  : "${WORK_ITEM:?WORK_ITEM is required}"
  : "${FEATURE_REFS:?FEATURE_REFS is required}"
  local target promo cut head r paths
  target="$(strip_ref "$TARGET_BRANCH")"
  promo="${PREFIX}${WORK_ITEM}-to-${TARGET_ENV}"
  ensure_identity

  local -a refs=()
  for r in ${FEATURE_REFS//,/ }; do
    [[ -n "$r" ]] && refs+=("$(strip_ref "$r")")
  done
  [[ ${#refs[@]} -gt 0 ]] || die "FEATURE_REFS names no branch"

  fetch_branch "$target"
  local -a commits=()
  for r in "${refs[@]}"; do
    if is_sha "$r"; then
      git cat-file -e "${r}^{commit}" 2>/dev/null || die "commit ${r} is not available locally (fetch-depth 0?)"
      commits+=("$r")
    else
      fetch_branch "$r" || die "feature branch '$r' does not exist on ${REMOTE}"
      commits+=("${REMOTE}/${r}")
    fi
  done

  if [[ -n "${CUT_SHA:-}" ]]; then
    git cat-file -e "${CUT_SHA}^{commit}" 2>/dev/null || die "CUT_SHA ${CUT_SHA} is not available locally"
    cut="$CUT_SHA"
  else
    cut="$(git rev-parse "${REMOTE}/${target}")"
  fi
  git checkout --quiet -B "$promo" "$cut"
  emit promotion_branch "$promo"
  emit target_sha_at_cut "$cut"

  local -a merged=()
  local i c
  for i in "${!refs[@]}"; do
    r="${refs[$i]}"
    c="${commits[$i]}"
    if git merge-base --is-ancestor "$c" HEAD; then
      echo "::notice::${r} is already contained in ${target}; nothing to merge from it"
      continue
    fi
    if ! git merge --no-ff --no-edit -m "Promote ${r} into ${target} (${WORK_ITEM})" "$c" >/dev/null 2>merge.err; then
      paths="$(git diff --name-only --diff-filter=U || true)"
      cat merge.err >&2 || true
      git merge --abort || true
      rm -f merge.err
      emit conflict true
      emit conflicting_ref "$r"
      emit conflict_paths "$paths"
      emit head_sha "$(git rev-parse HEAD)"
      echo "::error title=Merge conflict promoting ${WORK_ITEM} to ${TARGET_ENV}::${r} conflicts with ${target} in: $(echo "$paths" | paste -sd ',' - | sed 's/,/, /g')"
      exit 10
    fi
    rm -f merge.err
    merged+=("$r")
  done

  head="$(git rev-parse HEAD)"
  emit head_tree "$(git rev-parse 'HEAD^{tree}')"
  emit conflict false
  emit conflict_paths ""
  emit merged_refs "$(IFS=,; echo "${merged[*]:-}")"
  emit head_sha "$head"
  if [[ "$head" == "$cut" ]]; then
    emit no_op true
    echo "::notice::Every feature is already in ${target}; the promotion has no delta."
  else
    emit no_op false
  fi
}

refuse_moved() {
  local target="$1" cut="$2" now="$3"
  emit merged false
  emit merge_method none
  emit reason "target ${target} moved from ${cut:0:12} to ${now:0:12} during the run; merging would publish a tree that was never deployed"
  echo "::error title=Merge refused::${target} moved during the run (${cut:0:12} → ${now:0:12}). The org has the deployed tree; the branch was NOT merged. Re-run the promotion."
  exit 11
}

cmd_merge() {
  : "${TARGET_BRANCH:?TARGET_BRANCH is required}"
  : "${TARGET_SHA_AT_CUT:?TARGET_SHA_AT_CUT is required (output of promote.sh cut)}"
  local target cut head now mode promo out
  target="$(strip_ref "$TARGET_BRANCH")"
  cut="$TARGET_SHA_AT_CUT"
  head="$(git rev-parse HEAD)"
  if [[ -n "${DEPLOYED_SHA:-}" && "$DEPLOYED_SHA" != "$head" ]]; then
    die "HEAD (${head:0:12}) is not the deployed commit (${DEPLOYED_SHA:0:12}); refusing to merge something that was not deployed"
  fi
  promo="${PROMOTION_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
  mode="${MERGE_MODE:-auto}"

  fetch_branch "$target"
  now="$(git rev-parse "${REMOTE}/${target}")"
  [[ "$now" == "$cut" ]] || refuse_moved "$target" "$cut" "$now"

  if [[ "$head" == "$cut" ]]; then
    emit merged false
    emit merge_method none
    emit reason "nothing to merge: the promotion added no commits"
    exit 0
  fi

  if [[ "$mode" == "auto" || "$mode" == "push" ]]; then
    if out="$(git push "$REMOTE" "HEAD:refs/heads/${target}" 2>&1)"; then
      echo "$out"
      emit merged true
      emit merge_method push
      emit merge_sha "$head"
      emit reason ""
      return 0
    fi
    echo "$out" >&2
    if grep -qiE 'non-fast-forward|fetch first|stale info' <<<"$out"; then
      fetch_branch "$target"
      refuse_moved "$target" "$cut" "$(git rev-parse "${REMOTE}/${target}")"
    fi
    if [[ "$mode" == "push" ]]; then
      emit merged false
      emit merge_method none
      emit reason "push to ${target} was rejected (branch protection?) and MERGE_MODE=push forbids the PR path"
      echo "::error title=Merge failed::push to ${target} was rejected; the branch was NOT merged."
      exit 12
    fi
    echo "::notice::Direct push to ${target} rejected (protected branch); merging through a pull request instead."
  fi

  merge_via_pr "$target" "$cut" "$head" "$promo"
}

merge_via_pr() {
  local target="$1" cut="$2" head="$3" promo="$4"
  local repo="${GITHUB_REPOSITORY:-}" ctx="${STATUS_CONTEXT:-sfdevops/deploy}" num url merge_sha attempt
  if [[ -z "$repo" || -z "${GH_TOKEN:-}" ]] || ! command -v gh >/dev/null 2>&1; then
    emit merged false
    emit merge_method none
    emit reason "push rejected and the PR path needs gh, GH_TOKEN and GITHUB_REPOSITORY"
    echo "::error title=Merge failed::push to ${target} was rejected and no PR path is available; the branch was NOT merged."
    exit 12
  fi

  git push --quiet --force "$REMOTE" "HEAD:refs/heads/${promo}"
  gh api --silent -X POST "repos/${repo}/statuses/${head}" \
    -f state=success -f context="$ctx" \
    -f description="Deployed to ${TARGET_ENV:-$target}" \
    -f target_url="${RUN_URL:-https://github.com/${repo}/actions}"

  num="$(gh pr list --repo "$repo" --head "$promo" --base "$target" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [[ -z "$num" || "$num" == "null" ]]; then
    url="$(gh pr create --repo "$repo" --base "$target" --head "$promo" \
      --title "Promote ${WORK_ITEM:-$promo} to ${TARGET_ENV:-$target}" \
      --body "Automated promotion merge. The org was deployed from \`${head}\` (target cut at \`${cut}\`) before this PR was opened. Run: ${RUN_URL:-n/a}")"
    num="${url##*/}"
  fi
  url="https://github.com/${repo}/pull/${num}"
  emit pr_url "$url"

  # GitHub may need a moment to register the status before the PR becomes mergeable.
  for attempt in 1 2 3 4 5 6; do
    if gh pr merge "$num" --repo "$repo" --merge --match-head-commit "$head" \
        --subject "Promote ${WORK_ITEM:-$promo} to ${TARGET_ENV:-$target}" 2>merge.err; then
      rm -f merge.err
      merge_sha="$(gh pr view "$num" --repo "$repo" --json mergeCommit --jq '.mergeCommit.oid')"
      emit merged true
      emit merge_method pr
      emit merge_sha "$merge_sha"
      emit reason ""
      if [[ "${DELETE_PROMOTION_BRANCH:-true}" == "true" ]]; then
        git push --quiet "$REMOTE" --delete "$promo" 2>/dev/null || true
      fi
      return 0
    fi
    cat merge.err >&2
    fetch_branch "$target"
    if [[ "$(git rev-parse "${REMOTE}/${target}")" != "$cut" ]]; then
      rm -f merge.err
      refuse_moved "$target" "$cut" "$(git rev-parse "${REMOTE}/${target}")"
    fi
    sleep $((attempt * 5))
  done
  rm -f merge.err
  emit merged false
  emit merge_method none
  emit reason "pull request ${url} could not be merged; see the log"
  echo "::error title=Merge failed::${url} could not be merged; the branch was NOT merged."
  exit 12
}

case "${1:-}" in
  cut) cmd_cut ;;
  merge) cmd_merge ;;
  *) echo "usage: promote.sh cut|merge" >&2; exit 1 ;;
esac
