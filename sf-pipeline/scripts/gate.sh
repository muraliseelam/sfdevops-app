#!/usr/bin/env bash
# gate.sh — repository-permission checks for the approval and bypass gates.
#
#   gate.sh role <login>              print the login's role on this repo
#                                     (admin | maintain | write | triage | read | none)
#   gate.sh is-admin <login>          exit 0 when the role is admin or maintain, else 1
#   gate.sh labeler <pr> <label>      print who most recently added <label> to <pr>
#   gate.sh drop-label <pr> <label> <message>
#                                     remove the label and comment why
#
# Permissions are always re-verified at run time through the GitHub API, never trusted from
# the event payload or from a cached value. Needs GH_TOKEN and GITHUB_REPOSITORY.
set -euo pipefail

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

role() {
  local login="$1"
  [[ -n "$login" ]] || { echo none; return; }
  gh api "repos/${repo}/collaborators/${login}/permission" --jq '.role_name // .permission' 2>/dev/null || echo none
}

case "${1:-}" in
  role)
    role "${2:?login}"
    ;;
  is-admin)
    r="$(role "${2:?login}")"
    echo "role of ${2} on ${repo}: ${r}"
    [[ "$r" == "admin" || "$r" == "maintain" ]]
    ;;
  labeler)
    pr="${2:?pr}"; label="${3:?label}"
    gh api "repos/${repo}/issues/${pr}/events?per_page=100" --paginate \
      --jq ".[] | select(.event == \"labeled\" and .label.name == \"${label}\") | .actor.login" | tail -1
    ;;
  drop-label)
    pr="${2:?pr}"; label="${3:?label}"; message="${4:?message}"
    gh api -X DELETE "repos/${repo}/issues/${pr}/labels/${label// /%20}" --silent 2>/dev/null || true
    gh pr comment "$pr" --repo "$repo" --body "$message" || echo "::warning::could not comment on PR #${pr}"
    ;;
  *)
    echo "usage: gate.sh role|is-admin|labeler|drop-label ..." >&2
    exit 2
    ;;
esac
