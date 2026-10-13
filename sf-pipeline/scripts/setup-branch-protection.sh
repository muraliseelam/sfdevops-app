#!/usr/bin/env bash
# setup-branch-protection.sh [--dry-run] [--repo owner/name]
#
# Create any missing environment branches from the baseline and apply the protection rules to
# the production branch and every environment branch named in pipeline.config.yml:
#   - require a pull request (0 approvals: reviews happen on feature PRs; promotion PRs are
#     opened and merged by the pipeline after a successful deploy), dismiss stale reviews
#   - require the `sfdevops/deploy` commit status, with "branches up to date" (strict), so a
#     promotion whose target moved can never merge and a feature PR's merge button never works
#   - block force pushes and deletions
#   - enforce for admins on every branch except the entry environment's
#
# Run it LAST, after the final pipeline change has landed on the baseline: with admins
# enforced, refreshing pipeline files on environment branches means recreating them from the
# baseline (delete the protection, recreate the branch, re-run this) rather than pushing.
set -euo pipefail

dry=false
repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) dry=true; shift ;;
    --repo) repo="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then PY="$c"; break; fi
done
[[ -n "$PY" ]] || { echo "no working Python found" >&2; exit 1; }
repo="${repo:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

out="$(mktemp)"; trap 'rm -f "$out"' EXIT
GITHUB_OUTPUT="$out" "$PY" "$here/plan.py" outputs >/dev/null
get() { "$PY" "$here/ghout.py" "$out" "$1"; }
baseline="$(get baseline_branch)"
entry="$(get entry_branch)"
branches="$(get protected_branches)"

default="$(gh api "repos/${repo}" --jq .default_branch)"
if [[ "$default" != "$baseline" ]]; then
  echo "warning: the default branch is '${default}', not the baseline '${baseline}'. Scheduled workflows run only on the default branch; set it with:"
  echo "  gh api -X PATCH repos/${repo} -f default_branch=${baseline}"
fi

base_sha="$(gh api "repos/${repo}/git/ref/heads/${baseline}" --jq .object.sha)"
for b in $branches; do
  if ! gh api "repos/${repo}/git/ref/heads/${b}" --silent 2>/dev/null; then
    if $dry; then echo "[dry-run] would create ${b} from ${baseline} (${base_sha:0:12})"; else
      gh api -X POST "repos/${repo}/git/refs" -f ref="refs/heads/${b}" -f sha="$base_sha" --silent
      echo "created ${b} from ${baseline} (${base_sha:0:12})"
    fi
  fi
done

for b in $branches; do
  enforce=true
  [[ "$b" == "$entry" ]] && enforce=false
  body="$(cat <<EOF
{
  "required_status_checks": { "strict": true, "contexts": ["sfdevops/deploy"] },
  "enforce_admins": ${enforce},
  "required_pull_request_reviews": { "dismiss_stale_reviews": true, "required_approving_review_count": 0 },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": false,
  "required_conversation_resolution": false
}
EOF
)"
  if $dry; then
    echo "[dry-run] would protect ${b} (enforce_admins=${enforce})"
  else
    gh api -X PUT "repos/${repo}/branches/${b}/protection" --input - --silent <<<"$body"
    echo "protected ${b} (enforce_admins=${enforce})"
  fi
done
