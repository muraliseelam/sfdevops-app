#!/usr/bin/env bash
# story-manifest.sh <work-item> [feature-branch] - the manifest of one work item.
#
# The story manifest is everything the feature branch changed since it left the baseline:
#   delta(merge-base(origin/<baseline>, origin/<feature>) .. origin/<feature>)
# written to .sgd-story/<work-item>/ by delta.sh (package/package.xml,
# destructiveChanges/destructiveChanges.xml, changed-files.txt).
#
# Env
#   BASELINE_BRANCH   required, e.g. main
#   FEATURE_PREFIX    default feature/ (feature branch = <prefix><work-item> when not given)
#   SOURCE_PATH       default force-app; FORCE_IGNORE / SF_API_VERSION pass through to delta.sh
# Outputs: every delta.sh output, plus work_item, feature_branch, merge_base, story_dir.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$here/lib.sh"

if [[ $# -lt 1 || $# -gt 2 || -z "${1:-}" ]]; then
  echo "usage: story-manifest.sh <work-item> [feature-branch]" >&2
  exit 2
fi
work_item="$1"
[[ "$work_item" =~ ^[A-Za-z0-9._-]+$ ]] || die "work item key '$work_item' may only contain letters, digits, '.', '_' and '-'"
baseline="$(strip_ref "${BASELINE_BRANCH:-}")"
[[ -n "$baseline" ]] || die "BASELINE_BRANCH is required (the branch feature branches are cut from)"
prefix="${FEATURE_PREFIX:-feature/}"
feature="$(strip_ref "${2:-${prefix}${work_item}}")"

require_cmd git
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "story-manifest.sh must run inside a git work tree"

refspecs=("+refs/heads/${baseline}:refs/remotes/origin/${baseline}"
  "+refs/heads/${feature}:refs/remotes/origin/${feature}")
echo "git fetch --no-tags origin $baseline $feature"
if ! git -C "$repo_root" fetch --no-tags origin "${refspecs[@]}"; then
  warn "could not fetch $baseline and $feature from origin; using the local remote-tracking refs"
fi
git -C "$repo_root" rev-parse --verify --quiet "origin/${baseline}^{commit}" >/dev/null || die "origin/$baseline does not exist"
git -C "$repo_root" rev-parse --verify --quiet "origin/${feature}^{commit}" >/dev/null || die "origin/$feature does not exist (is the work item's feature branch pushed?)"

merge_base="$(git -C "$repo_root" merge-base "origin/$baseline" "origin/$feature" 2>/dev/null || true)"
if [[ -z "$merge_base" && "$(git -C "$repo_root" rev-parse --is-shallow-repository)" == "true" ]]; then
  echo "shallow clone: fetching full history of $baseline and $feature to find the merge-base"
  git -C "$repo_root" fetch --no-tags --unshallow origin "${refspecs[@]}" ||
    git -C "$repo_root" fetch --no-tags --deepen=1000 origin "${refspecs[@]}" || true
  merge_base="$(git -C "$repo_root" merge-base "origin/$baseline" "origin/$feature" 2>/dev/null || true)"
fi
[[ -n "$merge_base" ]] || die "origin/$feature shares no history with origin/$baseline"

story_dir=".sgd-story/$work_item"
echo "Story manifest for $work_item: merge-base ${merge_base:0:12} .. origin/$feature -> $story_dir"
DELTA_FROM="$merge_base" DELTA_TO="origin/$feature" DELTA_OUTPUT="$story_dir" \
  bash "$here/delta.sh"

gh_output work_item "$work_item"
gh_output feature_branch "$feature"
gh_output merge_base "$merge_base"
gh_output story_dir "$story_dir"
